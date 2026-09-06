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
-- whole question becomes what the skipped characters were worth:
--
--   a vowel                     ~free    nobody spells out the vowels
--   a consonant beside another  cheap    clusters, codas and doubled letters:
--                                        the "h" of "think", the "r" of "strat",
--                                        the "n" of "-nk", one "t" of "cattle"
--   a consonant between vowels  dear     that is a syllable's onset, the one
--                                        letter a shorthand typist does keep
--
-- Those three prices are the entire model.  There is no syllabifier, no
-- pronunciation dictionary and no codebook: a consonant sitting between two
-- vowels is where an English syllable starts often enough to be worth pricing,
-- and being wrong about it costs a bit of score rather than a candidate.
--
-- Precision comes from the prices, not from a filter.  "tnk" aligns onto
-- "think", "tank", "thank" and "trunk" alike, and which of them leads is then
-- a question about English frequency, which the ranker already answers.

local M = {}

local byte, huge = string.byte, math.huge

local VOWEL = {}
for i = 1, 5 do VOWEL[byte("aeiou", i)] = true end
-- An apostrophe is never a cue: "dont" for "don't" is the same shorthand.
VOWEL[byte("'")] = true

-- Scratch space, reused across calls.  A scan prices a few hundred words per
-- keystroke and none of these ever needs to grow.
local wb, wcost, qb, f = {}, {}, {}, {}

--- Price every character of `word` by what skipping it would cost.
local function price(word, m, cfg)
  local vowel = cfg.cue_skip_vowel
  local cluster, onset = cfg.cue_skip_cluster, cfg.cue_skip_onset
  for j = 1, m do wb[j] = byte(word, j) end
  -- The arrays outlive the call, so the two cells the neighbour test reads off
  -- each end must be cleared or a longer previous word answers for this one.
  wb[0], wb[m + 1] = nil, nil
  for j = 1, m do
    local c = wb[j]
    local before, after = wb[j - 1], wb[j + 1]
    if VOWEL[c] then wcost[j] = vowel
    elseif (before and not VOWEL[before]) or (after and not VOWEL[after]) then
      wcost[j] = cluster
    else wcost[j] = onset end
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
--- none within `budget`.
---
--- Every character of the word that the query did not land on is charged,
--- including the ones past the last match.  Shorthand runs to the end of the
--- word: someone typing cues syllable by syllable does not stop two syllables
--- early, so a word whose tail went untouched is being *completed*, which is
--- what the prefix and skeleton channels are for.  Charging the tail at the
--- same prices is what separates "embarass" -> "embarrass" (nothing left over)
--- from "embarass" -> "embarrassed" (a whole syllable nobody typed).
---
--- The first letter must match.  It is the one character a shorthand typist
--- does not drop, and requiring it is what keeps this from proposing half the
--- dictionary for a three-letter query.
function M.align(query, word, budget, cfg)
  local n, m = #query, #word
  if m < n or n < 2 then return nil end
  if byte(query, 1) ~= byte(word, 1) then return nil end

  price_q(query, n)
  -- A leftmost-greedy pass answers "is this a subsequence at all?" in one
  -- walk of the word with no table writes, and most of what the letter-set
  -- filter admits fails it.  Pricing and the alignment below are perhaps
  -- twenty times the work, so it is worth asking first.
  do
    local i = 2
    for j = 2, m do
      if byte(word, j) == qb[i] then
        i = i + 1
        if i > n then goto ordered end
      end
    end
    do return nil end
    ::ordered::
  end
  price(word, m, cfg)

  -- f[i] = cheapest way to have matched query[1..i] and skipped everything
  -- else in the word so far.  f[n] at the far end is the answer.
  f[1] = 0
  for i = 2, n do f[i] = huge end

  for j = 2, m do
    local c, skip = wb[j], wcost[j]
    -- Nothing past column j can have been reached yet.
    local top = n < j and n or j
    local row = huge
    for i = top, 2, -1 do
      local v = f[i] + skip
      if c == qb[i] then
        -- f[i - 1] is still the previous row's value: this loop runs
        -- downwards precisely so that it is.
        local matched = f[i - 1]
        if matched < v then v = matched end
      end
      f[i] = v
      if v < row then row = v end
    end
    f[1] = f[1] + skip
    if f[1] < row then row = f[1] end
    -- Costs only ever accumulate, so once the whole row is over budget no
    -- later row can come back under it -- f[n] included.
    if row > budget then return nil end
  end

  local d = f[n]
  if d > budget then return nil end
  return d
end

return M
