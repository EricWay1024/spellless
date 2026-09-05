-- Candidate generation.
--
-- Three sources feed one ranking pass:
--
--   exact / prefix   binary search of the alphabetical permutation
--   typo             bounded scan + weighted edit distance on the spelling
--   skeleton         binary search of the skeleton permutation, widened by a
--                    bounded scan, then scored by a vowel-elastic alignment
--
-- The scans are what keeps this interactive.  Rather than measure edit
-- distance against all 83k words we only visit words that could plausibly be
-- within budget -- right length, right first letter, overlapping letter sets --
-- and reject everything else with two integer operations.

local distance = require("spellless.distance")
local skeleton = require("spellless.skeleton")
local Corpus = require("spellless.corpus")
local util = require("spellless.util")

local M = {}

local byte = string.byte

-- Spelling errors: transpositions and vowel slips are cheap, a wrong consonant
-- is not.
local TYPO_PROFILE = distance.profile()

-- Skeleton-vs-skeleton comparison; both sides are already vowel-free, so the
-- vowel discounts are switched off and only consonant edits matter.
local SKELETON_PROFILE = distance.profile{
  extra_vowel = 1.00, missing_vowel = 1.00, sub_vowel_vowel = 1.00,
}

-- Query-vs-word comparison for skeleton candidates.  The asymmetry is the
-- point: a vowel the typist *left out* is nearly free, because that is what an
-- abbreviation is, but a vowel the typist actually typed is evidence and
-- deleting it costs real money.  Without that asymmetry "theorme" reaches
-- "thermal" as cheaply as "mthmtcs" reaches "mathematics".
local ELASTIC_PROFILE = distance.profile{
  missing_vowel = 0.10, extra_vowel = 0.90, sub_vowel_vowel = 0.60,
}

M.TYPO_PROFILE, M.SKELETON_PROFILE, M.ELASTIC_PROFILE =
  TYPO_PROFILE, SKELETON_PROFILE, ELASTIC_PROFILE

--- 26-bit letter-presence mask of a string.
local function letter_mask(q)
  local m = 0
  for i = 1, #q do
    local c = byte(q, i)
    if c >= 97 and c <= 122 then m = m | (1 << (c - 97)) end
  end
  return m
end
M.letter_mask = letter_mask

--- The first letters worth scanning for a typo of `q`.
--- q[1] covers the overwhelmingly common case of a correct first key; q[2]
--- covers a swap, an inserted or a dropped first key; the keyboard neighbours
--- of q[1] cover a mis-hit first key but multiply the work, so they are opt-in.
local function anchor_letters(q, cfg)
  local seen, out = {}, {}
  local function add(c)
    if c and c >= 97 and c <= 122 and not seen[c] then seen[c] = true; out[#out + 1] = c end
  end
  add(byte(q, 1))
  add(byte(q, 2))
  if cfg.scan_first_neighbours then
    local q1 = byte(q, 1)
    for k = 97, 122 do
      if distance.NEIGHBOUR[distance.pack(q1, k)] then add(k) end
    end
  end
  return out
end
M.anchor_letters = anchor_letters

--- How many distinct letters may differ in each direction, for a candidate
--- whose length differs from the query's by `delta` (query minus word).
---
--- The length difference forces at least `|delta|` insertions or deletions,
--- which are already paid for at `min_indel_any` each; whatever budget is left
--- can only buy substitutions or further indel *pairs*, and substitutions are
--- the cheaper way to change a letter.  Since every edit moves at most one
--- letter into or out of the letter set, a word two characters shorter than
--- the query can differ by at most the two dropped letters and nothing else.
---
--- That is much sharper than a fixed tolerance, and it is what makes the +/-2
--- length buckets cheap.  Note a doubling slip changes no letters at all, so
--- these bounds are over-estimates in exactly the direction that keeps them
--- safe.
local function bit_budgets(delta, budget, p)
  local n = delta < 0 and -delta or delta
  local left = budget - n * p.min_indel_any
  if left < 0 then return nil end
  local subs = math.floor(left / p.min_sub)
  if delta > 0 then return n + subs, subs end
  return subs, n + subs
end
M.bit_budgets = bit_budgets

--- Scan the (length, first letter) buckets around a query, running `verify(id)`
--- on everything that survives the letter-mask prefilter.
---
--- Lengths are visited most-plausible-first and each bucket is already ordered
--- by corpus frequency, so `max_checks` degrades by dropping the least likely
--- candidates rather than an arbitrary slice.
local function scan(masks, buckets, qlen, qmask, letters, window, budget, profile,
                    max_checks, verify, stats)
  local popcount, scanned, checked = util.POPCOUNT, 0, 0
  local qlow, qhigh = qmask & 8191, qmask >> 13
  for step = 0, window * 2 do
    -- 0, -1, +1, -2, +2, ...
    local delta = (step + 1) // 2
    if step % 2 == 1 then delta = -delta end
    local len = qlen - delta
    local qb, wb = bit_budgets(delta, budget, profile)
    if len > 0 and qb then
      for i = 1, #letters do
        local bucket = buckets[Corpus.bucket_key(len, letters[i])]
        if bucket then
          local size = #bucket
          scanned = scanned + size
          for k = 1, size do
            local id = bucket[k]
            local wm = masks[id]
            local x = qmask & ~wm
            if popcount[x & 8191] + popcount[x >> 13] <= qb then
              local ylow, yhigh = wm & 8191 & ~qlow, (wm >> 13) & ~qhigh
              if popcount[ylow] + popcount[yhigh] <= wb then
                checked = checked + 1
                if checked > max_checks then goto done end
                verify(id)
              end
            end
          end
        end
      end
    end
  end
  ::done::
  if stats then
    stats.scanned = (stats.scanned or 0) + scanned
    stats.checked = (stats.checked or 0) + checked
  end
end

-- ---------------------------------------------------------------------------
-- individual sources
-- ---------------------------------------------------------------------------

local function add_exact_and_prefix(corpus, query, cfg, emit)
  local exact_id = corpus:lookup(query)
  if exact_id then emit(exact_id, "exact", 0) end
  local top = util.top(cfg.max_prefix)
  corpus:each_prefix(query, function(id)
    if id ~= exact_id then top:push(id, id) end
  end)
  top:each(function(id) emit(id, "prefix", 0) end)
  return exact_id
end

local function add_typos(corpus, query, cfg, emit, exact_id, stats)
  if #query < cfg.min_typo_len then return end
  local shortlist = util.top(cfg.max_typo)
  local cost_of = {}
  local budget = cfg.typo_budget
  local words = corpus.words
  scan(corpus.masks, corpus.wbuckets, #query, letter_mask(query),
       anchor_letters(query, cfg), cfg.len_window, budget, TYPO_PROFILE,
       cfg.max_checks, function(id)
    if id == exact_id then return end
    local d = distance.distance(query, words[id], budget, TYPO_PROFILE)
    if d and d > 0 then
      cost_of[id] = d
      -- shortlist key: cheapest repair first, corpus rank as the tiebreak
      shortlist:push(d * 1e7 + id, id)
    end
  end, stats)
  shortlist:each(function(id) emit(id, "typo", cost_of[id]) end)
end

--- Skeleton candidates.
---
--- Generation is two-legged: the precomputed skeleton permutation gives every
--- word whose skeleton starts with the query's skeleton (exact abbreviations
--- and their completions), and a bounded scan over skeleton-length buckets
--- picks up abbreviations the typist got slightly wrong.
---
--- Both legs are then priced the same way, by aligning the *original query*
--- against a prefix of the word with cheap vowel indels.  Scoring against the
--- query rather than against the skeleton is what keeps a vowel-rich input
--- from matching every word with the same consonants.
local function add_skeletons(corpus, query, cfg, emit, exact_id, stats)
  local qskel = skeleton.of(query)
  if #qskel < cfg.min_skeleton_len then return end

  local seen = {}
  local pool, npool = {}, 0
  local function offer(id)
    if id ~= exact_id and not seen[id] then
      seen[id] = true
      npool = npool + 1
      pool[npool] = id
    end
  end

  -- An exact skeleton hit is the strong signal; completions of a half-typed
  -- abbreviation are weaker and only worth collecting once the skeleton is
  -- long enough to mean something.
  local function collect(prefix)
    local exact_top = util.top(cfg.max_skeleton)
    corpus:each_skeleton_exact(prefix, function(id) exact_top:push(id, id) end)
    exact_top:each(offer)
    if #qskel >= cfg.min_skeleton_completion_len then
      local comp_top = util.top(cfg.max_skeleton)
      corpus:each_skeleton_completion(prefix, cfg.max_skeleton_range,
        function(id) comp_top:push(id, id) end)
      comp_top:each(offer)
    end
  end

  collect(qskel)

  -- The skeleton rule keeps a leading vowel ("environment" -> "envrnmnt") but
  -- a typist abbreviating often drops it ("nvrnmnt").  Five more index probes
  -- recover that; the elastic scoring below then charges the missing vowel.
  if not qskel:find("^[aeiou]") then
    for v in ("aeiou"):gmatch(".") do collect(v .. qskel) end
  end

  if #qskel >= cfg.min_skeleton_fuzzy_len then
    local fuzzy_top = util.top(cfg.max_skeleton_fuzzy)
    local budget = cfg.skeleton_budget
    scan(corpus.smasks, corpus.sbuckets, #qskel, letter_mask(qskel),
         anchor_letters(qskel, cfg), 1, budget, SKELETON_PROFILE,
         cfg.max_checks, function(id)
      local d = distance.distance(qskel, corpus:skeleton(id), budget, SKELETON_PROFILE)
      if d then fuzzy_top:push(d * 1e7 + id, id) end
    end, stats)
    fuzzy_top:each(offer)
  end

  local budget = cfg.elastic_budget
  local words = corpus.words
  for i = 1, npool do
    local id = pool[i]
    local d = distance.prefix_distance(query, words[id], budget, ELASTIC_PROFILE)
    if d then emit(id, "skeleton", d) end
  end
end

-- ---------------------------------------------------------------------------

--- Generate candidates for `query` (already lowercased).
--- Returns a list of { id, source, cost, extra }; duplicates across sources are
--- left in and resolved by the ranker.
function M.generate(corpus, query, cfg, stats)
  local out, n = {}, 0
  local words = corpus.words
  local qlen = #query
  local function emit(id, source, cost)
    n = n + 1
    out[n] = { id = id, source = source, cost = cost or 0, extra = #words[id] - qlen }
  end

  local exact_id = add_exact_and_prefix(corpus, query, cfg, emit)
  add_typos(corpus, query, cfg, emit, exact_id, stats)
  add_skeletons(corpus, query, cfg, emit, exact_id, stats)
  return out
end

return M
