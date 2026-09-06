-- Syllabic shorthand: one or two letters per syllable, and nothing else.
--
-- Typing "satfcatn" for "stratification" is not a misspelling and not quite an
-- abbreviation either.  It is what happens when someone says the word to
-- themselves and types whatever felt salient in each syllable -- strat-i-fi-
-- ca-tion -> s-a-t f c-a t-n -- picking different letters each time and never
-- following a rule they could state.  The edit-distance channel cannot reach
-- it (every dropped consonant is a full-price deletion) and the consonant
-- skeleton cannot either (it demands *all* the consonants, in order, with at
-- most one slip).
--
-- What every one of these inputs does have is that the letters typed appear in
-- the word, in order.  So the query is aligned as a *subsequence*, and the
-- whole question becomes how likely that particular subsequence was.
--
-- The model is one Bernoulli decision per character of the word: the typist
-- either keeps it or drops it, with a probability that depends only on what
-- kind of character it is.
--
--   a vowel                     rarely kept    nobody spells out the vowels
--   a consonant beside another  often kept     clusters, codas and doubled
--                                              letters: the "h" of "think",
--                                              the "r" of "strat", one "t" of
--                                              "cattle"
--   a consonant between vowels  nearly always  that is a syllable's onset,
--                                              the one letter a shorthand
--                                              typist does keep
--
-- Keeping a character costs -log(p) and dropping it costs -log(1-p), so the
-- alignment cost is a genuine negative log-likelihood: sum over all keep/drop
-- masks of P(mask) is 1, for every word, and the model normalises itself.
-- That is the whole difference from pricing only the drops.  Charging *both*
-- sides is what makes it a distribution, and it buys two things that used to
-- be separate hand-built rules:
--
--   * a long word no longer wins by having more subsequences.  Every extra
--     character it has to explain is charged, kept or dropped, so the tail of
--     a word nobody typed into is paid for by construction rather than by a
--     special case.
--   * a vowel-rich input can no longer pass itself off as shorthand.  Each
--     vowel the typist *did* type costs -log(p_vowel), which is expensive
--     precisely because vowels are what shorthand drops.  That is the
--     per-position version of the global vowel-ratio bonus in rank.lua.
--
-- The three probabilities are fitted, not guessed: the alignment says which
-- characters a known (shorthand, word) pair kept, so class-wise keep rates are
-- counts.  See the note in config.lua for the numbers and what they mean.
--
-- Costs come back divided by `cue_cost_scale`, because the ranker's
-- `cost_weight` is calibrated against edit distances, which are not
-- log-probabilities.  That divisor is this channel's points-per-nat and the
-- only unprincipled number left in it.
--
-- Precision comes from the prices, not from a filter.  "tnk" aligns onto
-- "think", "tank", "thank" and "trunk" alike, and which of them leads is then
-- a question about English frequency, which the ranker already answers.

local M = {}

local byte, huge, log = string.byte, math.huge, math.log

local VOWEL = {}
for i = 1, 5 do VOWEL[byte("aeiou", i)] = true end
-- An apostrophe is never a cue: "dont" for "don't" is the same shorthand.
VOWEL[byte("'")] = true

-- Scratch space, reused across calls.  A scan prices a few hundred words per
-- keystroke and none of these ever needs to grow.
local wb, wkeep, wskip, qb, f = {}, {}, {}, {}, {}
-- Where the query's prefixes can finish and its suffixes can start, for the
-- one-slip version of the subsequence test.
local lpos, rpos = {}, {}

-- The six prices derived from the three probabilities, cached against the
-- config table they came from: a scan re-derives them once, not once a word.
local priced_cfg
local KEEP_V, SKIP_V, KEEP_C, SKIP_C, KEEP_O, SKIP_O

--- Both -log(p) and -log(1-p) must be finite and positive for the row abort
--- below to be sound, so neither end is allowed all the way to certainty.
local function odds(p)
  if not (p > 1e-6) then p = 1e-6 elseif p > 1 - 1e-6 then p = 1 - 1e-6 end
  return p
end

local function prices(cfg)
  if cfg == priced_cfg then return end
  local pv, pc, po = odds(cfg.cue_keep_vowel), odds(cfg.cue_keep_cluster),
                     odds(cfg.cue_keep_onset)
  KEEP_V, SKIP_V = -log(pv), -log(1 - pv)
  KEEP_C, SKIP_C = -log(pc), -log(1 - pc)
  KEEP_O, SKIP_O = -log(po), -log(1 - po)
  priced_cfg = cfg
end

--- Price every character of `word`: what keeping it costs, and what dropping
--- it costs.  The classification is unchanged -- vowel, beside a consonant,
--- between vowels -- only what is charged for it is new.
local function price(word, m)
  for j = 1, m do wb[j] = byte(word, j) end
  -- The arrays outlive the call, so the two cells the neighbour test reads off
  -- each end must be cleared or a longer previous word answers for this one.
  wb[0], wb[m + 1] = nil, nil
  for j = 1, m do
    local c = wb[j]
    local before, after = wb[j - 1], wb[j + 1]
    if VOWEL[c] then wkeep[j], wskip[j] = KEEP_V, SKIP_V
    elseif (before and not VOWEL[before]) or (after and not VOWEL[after]) then
      wkeep[j], wskip[j] = KEEP_C, SKIP_C
    else wkeep[j], wskip[j] = KEEP_O, SKIP_O end
  end
end

-- `query` is the same string for every candidate in a scan.
local priced_q
local function price_q(query, n)
  if query == priced_q then return end
  for i = 1, n do qb[i] = byte(query, i) end
  priced_q = query
end

--- Cheapest syllabic alignment of `query` onto `word`, or nil when there is
--- none within `budget` nats.
---
---     f[i][j] = min( f[i][j-1] + skip(j),
---                    f[i-1][j-1] + keep(j)   when w[j] = q[i] )
---
--- with f[1][1] = keep(1) and the answer at f[n][m].  Every character of the
--- word is accounted for exactly once, kept or dropped, the ones past the last
--- match included -- which is why there is no separate rule charging the tail.
---
--- The first letter must match.  It is the one character a shorthand typist
--- does not drop, and requiring it is what keeps this from proposing half the
--- dictionary for a three-letter query.
---
--- One character of the query may be the wrong key, at `cue_slip_cost` nats on
--- top of what keeping that character costs:
---
---     f[i][j] = min( ..., f[i-1][j-1] + keep(j) + slip   when w[j] /= q[i] )
---
--- A slip inside an abbreviation is otherwise fatal -- the strict subsequence
--- test throws the word away before it is ever priced -- and "stfxctn" for
--- stratification then reaches nothing at all.  Nothing caps the number of
--- slips explicitly; the budget does, since two of them cost twice as much.
--- Below `min_cue_slip_len` characters it is switched off: three letters with
--- one of them wrong is not a mistyped abbreviation, it is a different word.
---
--- `budget` is in nats, which is what the DP works in; the cost handed back is
--- divided by `cue_cost_scale` to reach the ranker's units.
function M.align(query, word, budget, cfg)
  local n, m = #query, #word
  if m < n or n < 2 then return nil end
  if byte(query, 1) ~= byte(word, 1) then return nil end

  local slip = cfg.cue_slip_cost
  if slip <= 0 or n < cfg.min_cue_slip_len then slip = nil end

  price_q(query, n)
  -- Is the query a subsequence of the word at all?  A leftmost-greedy walk
  -- answers that, and most of what the letter-set filter admits fails it, so
  -- it is worth asking before pricing anything: that and the alignment below
  -- are perhaps twenty times the work.
  --
  -- `lpos[i]` is the earliest position at which the query's first i characters
  -- can be finished; `lmax` is how far the walk got.  The walk only ever moves
  -- forward, so it is one pass over the word however long the query is.
  local lmax = 1
  lpos[1] = 1
  do
    local j = 1
    for i = 2, n do
      local target, found = qb[i], nil
      for jj = j + 1, m do
        if byte(word, jj) == target then found = jj break end
      end
      if not found then break end
      j, lmax = found, i
      lpos[i] = j
    end
  end

  local clean = lmax == n
  if not clean then
    -- With one slip allowed the question becomes whether the query is a
    -- subsequence *apart from* one character.  Walking backwards for
    -- `rpos[i]`, the latest position at which the query's last n-i+1
    -- characters can start, settles it exactly: a slip fits at query position
    -- k when the prefix before it and the suffix after it leave a word
    -- position free in between.
    if not slip then return nil end
    local rmin, j2 = n + 1, m + 1
    rpos[n + 1] = m + 1
    for i = n, 2, -1 do
      local target, found = qb[i], nil
      for jj = j2 - 1, 2, -1 do
        if byte(word, jj) == target then found = jj break end
      end
      if not found then break end
      j2, rmin = found, i
      rpos[i] = j2
    end
    -- `k - 1 <= lmax` and `k + 1 >= rmin` are how the two walks say they got
    -- that far; without them the test would read a stale entry left by some
    -- earlier, longer query.
    local fits = false
    for k = 2, n do
      if k - 1 <= lmax and k + 1 >= rmin
         and lpos[k - 1] + 2 <= rpos[k + 1] then
        fits = true
        break
      end
    end
    if not fits then return nil end
  end
  -- A word that already explains every letter typed, in order, has no use for
  -- a mistyped one: the transition is switched off for it, which leaves the
  -- exact reading of every such word exactly what it was and keeps the cost of
  -- the inner loop off the overwhelming majority of alignments.  A word that
  -- does need a slip is allowed to spend one on top of the budget an exact
  -- reading gets, rather than widening that budget for everybody -- the
  -- ceiling on clean readings is what keeps the scan quick.
  if clean then slip = nil else budget = budget + slip end
  prices(cfg)
  price(word, m)

  -- f[i] = cheapest way to have explained every character of the word so far,
  -- having matched query[1..i].  f[n] at the far end is the answer.
  f[1] = wkeep[1]
  for i = 2, n do f[i] = huge end

  for j = 2, m do
    local c, skip, keep = wb[j], wskip[j], wkeep[j]
    -- Nothing past column j can have been reached yet.
    local top = n < j and n or j
    local row = huge
    for i = top, 2, -1 do
      local v = f[i] + skip
      if c == qb[i] then
        -- f[i - 1] is still the previous row's value: this loop runs
        -- downwards precisely so that it is.
        local matched = f[i - 1] + keep
        if matched < v then v = matched end
      elseif slip then
        local mistyped = f[i - 1] + keep + slip
        if mistyped < v then v = mistyped end
      end
      f[i] = v
      if v < row then row = v end
    end
    f[1] = f[1] + skip
    if f[1] < row then row = f[1] end
    -- Both prices are strictly positive, so every transition adds cost and the
    -- row minimum can only rise: once the whole row is over budget no later
    -- row can come back under it -- f[n] included.
    if row > budget then return nil end
  end

  local d = f[n]
  if d > budget then return nil end
  return d / cfg.cue_cost_scale
end

return M
