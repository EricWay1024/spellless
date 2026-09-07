-- Candidate generation.
--
-- Three sources feed one ranking pass:
--
--   exact / prefix   binary search of the alphabetical permutation
--   typo             bounded scan + weighted edit distance on the spelling
--   skeleton         binary search of the skeleton permutation, widened by a
--                    bounded scan, then scored by a vowel-elastic alignment
--   cue              first-letter buckets filtered to words that contain every
--                    letter typed, then a syllabic subsequence alignment
--
-- The scans are what keeps this interactive.  Rather than measure edit
-- distance against all 83k words we only visit words that could plausibly be
-- within budget -- right length, right first letter, overlapping letter sets --
-- and reject everything else with two integer operations.

local cue = require("spellless.cue")
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

  -- Not when the query is already a word.  `add_cues` has made this argument
  -- since it was written -- "a string the dictionary knows is not shorthand" --
  -- and it is stronger here: this leg looks for a *mistyped* abbreviation, and
  -- a mistyped abbreviation of a word you have just spelled correctly is not a
  -- thing that happens.
  --
  -- It is also where the time goes.  Typing 65,306 keystrokes of real prose,
  -- 44% of them land on a dictionary word, and on those this leg was the whole
  -- cost: p95 4.21 -> 1.64 ms, and for words of six letters or more mean
  -- 2.77 -> 0.95 with the worst case 24.9 -> 7.8.  Overall p95 4.80 -> 3.99.
  --
  -- Nothing worth having goes with it.  Across 4,451 queries -- every case file
  -- plus the 3,000 commonest words typed correctly -- 711 lists change and the
  -- leader changes in none of them.  103 candidates leave rank 2 and they are
  -- `always -> airways`, `spanish -> punished`, `could've -> coolidge`,
  -- `company -> companies`: noise, or a word you would simply have typed.
  --
  -- The benchmark cannot see any of this.  Its cases are misspellings, so
  -- almost none of them is an exact hit, which is why the 1,535-case latency
  -- table barely moves while ordinary typing halves.  See ALGORITHM.md 8.2.
  if #qskel >= cfg.min_skeleton_fuzzy_len and not exact_id then
    local fuzzy_top = util.top(cfg.max_skeleton_fuzzy)
    local budget = cfg.skeleton_budget
    scan(corpus.smasks, corpus.sbuckets, #qskel, letter_mask(qskel),
         anchor_letters(qskel, cfg), 1, budget, SKELETON_PROFILE,
         cfg.max_checks, function(id)
      -- Against a *prefix* of the word's skeleton, not all of it.  An
      -- abbreviation with a slip in it is usually also unfinished -- "alghrith"
      -- is "algorithm" with an "h" for the "o" and no "m" yet -- and demanding
      -- the whole skeleton charges for the slip and the missing tail at once,
      -- which no budget worth having can absorb.  The elastic pass below still
      -- prices the query against the real word, so this only widens who gets
      -- considered, and "alghrith" went from offering nothing to leading with
      -- "algorithm".
      local d = distance.prefix_distance(qskel, corpus:skeleton(id), budget,
                                         SKELETON_PROFILE)
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

--- Syllabic shorthand candidates: see spellless.cue.
---
--- Generation is a scan rather than an index lookup because there is no index
--- to use.  A subsequence has no prefix to binary search on, and the skeleton
--- permutation is exactly what these queries fail to match.  What they do have
--- is a first letter and a letter *set*: every character typed is somewhere in
--- the word, so `qmask & ~wordmask` must be empty, and that test rejects all
--- but a few dozen of the words sharing the first letter with two integer
--- operations each.
---
--- Length buckets are walked shortest first, so hitting the ceiling drops the
--- longest words -- the ones that were the biggest stretch anyway.
---
--- Skipped entirely when the query is itself a word.  Shorthand is what you
--- write *instead* of a word, so a string the dictionary already knows is not
--- it -- the same reasoning that stops "another" being cut into "a not her".
--- It is also what keeps the common case free: every correctly spelled word
--- you type would otherwise pay for a scan that could only offer a stretch.
local function add_cues(corpus, query, cfg, emit, exact_id, stats)
  local qlen = #query
  if qlen < cfg.min_cue_len or exact_id then return end
  local first = byte(query, 1)
  if first < 97 or first > 122 then return end

  local qmask = letter_mask(query)
  local budget = cfg.cue_budget
  local masks, buckets, words = corpus.masks, corpus.wbuckets, corpus.words
  -- The shortlist is keyed by what the ranker will do with the candidate, not
  -- by alignment cost alone.  Every other source is narrow enough that cheapest
  -- first is close enough to best first; this one is not.  "tnk" aligns onto a
  -- dozen rare words at nearly no cost -- "tonkin", "tankers" -- and cost order
  -- dropped "think" off the end of the list before the ranker ever saw it.
  local shortlist = util.top(cfg.max_cue)
  local cost_of = {}
  local checked, slipped = 0, 0
  -- With one mistyped letter allowed, a word no longer has to contain every
  -- letter of the query: it may be missing exactly the one that was slipped.
  -- That is "the missing-letter set has at most one member", and `x & (x-1)`
  -- clears the lowest set bit, so the whole test is `x & (x-1) == 0` -- two
  -- more integer operations than the strict one, rather than the two
  -- thirteen-bit table lookups a popcount would take on every word walked.
  --
  -- It admits five to ten times as many words per bucket, so those are counted
  -- against their own ceiling and never take checks away from the words that
  -- do contain every letter, which are much likelier to be right.
  local slip = cfg.cue_slip_cost > 0 and qlen >= cfg.min_cue_slip_len
  local slip_max = cfg.cue_slip_checks
  -- Two bounds on how long the word may be, and the tighter one wins.  The
  -- ratio is what matters for short input -- three letters is not shorthand
  -- for a seventeen-letter word, whatever the absolute gap -- and the absolute
  -- gap is what matters for long input, where the ratio stops constraining
  -- anything.
  local last = qlen + cfg.cue_max_extra
  local ratio = math.floor(qlen * cfg.cue_max_ratio)
  if ratio < last then last = ratio end
  if last > 31 then last = 31 end

  for len = qlen, last do
    local bucket = buckets[Corpus.bucket_key(len, first)]
    if bucket then
      for k = 1, #bucket do
        local id = bucket[k]
        if id ~= exact_id then
          local x = qmask & ~masks[id]
          local run = false
          if x == 0 then
            checked = checked + 1
            if checked > cfg.cue_max_checks then goto done end
            run = true
          elseif slip and (x & (x - 1)) == 0 then
            slipped = slipped + 1
            run = slipped <= slip_max
          end
          if run then
            local d = cue.align(query, words[id], budget, cfg)
            if d then
              cost_of[id] = d
              shortlist:push(cfg.cost_weight * d
                             - cfg.freq_weight * corpus:weight(id), id)
            end
          end
        end
      end
    end
  end
  ::done::
  if stats then stats.cues = (stats.cues or 0) + checked + slipped end
  -- No length penalty on top: the letters this reading skipped are all priced
  -- in `cost` already, the ones past the last match included.
  shortlist:each(function(id) emit(id, "cue", cost_of[id], 0) end)
end

-- ---------------------------------------------------------------------------

--- Generate candidates for `query` (already lowercased).
--- Returns a list of { id, source, cost, extra }; duplicates across sources are
--- left in and resolved by the ranker.
function M.generate(corpus, query, cfg, stats)
  local out, n = {}, 0
  local words = corpus.words
  local qlen = #query
  -- `extra` defaults to how much longer the word is than the query, which is
  -- what a completion adds.  A cue match overrides it: the letters it skipped
  -- *inside* the word are already paid for in `cost`, and charging them twice
  -- would rank "think" for "tnk" below a word half as likely.
  local function emit(id, source, cost, extra)
    n = n + 1
    out[n] = { id = id, source = source, cost = cost or 0,
               extra = extra or (#words[id] - qlen) }
  end

  local exact_id = add_exact_and_prefix(corpus, query, cfg, emit)
  add_typos(corpus, query, cfg, emit, exact_id, stats)
  add_skeletons(corpus, query, cfg, emit, exact_id, stats)
  add_cues(corpus, query, cfg, emit, exact_id, stats)
  return out
end

return M
