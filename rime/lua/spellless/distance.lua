-- Weighted optimal string alignment distance.
--
-- This is Damerau-Levenshtein restricted to non-overlapping adjacent
-- transpositions (the "OSA" variant).  The restriction is irrelevant for
-- single-word typing and it keeps the recurrence to three rolling rows.
--
-- Every edit has its own price because English fast-typing errors are not
-- uniformly likely:
--
--   leaving out an apostrophe       very likely  ("dont", "its", "id")
--   swapping two adjacent letters   very likely  ("theorme", "recommned")
--   mis-counting a double letter    very likely  ("commited", "harrass")
--   dropping / doubling a vowel     likely       ("seperate", "definately")
--   hitting a neighbouring key      likely       ("nirth" for "north")
--   getting a consonant wrong       unlikely
--
-- The DP is banded and aborts as soon as every cell in the current row exceeds
-- the caller's budget, so a non-match costs a few cells rather than n*m.
--
-- This is the hot loop of the whole project: the scan calls it a few thousand
-- times per keystroke.  Both strings are therefore turned into byte arrays and
-- per-character price arrays before the DP starts, and substitution costs come
-- from a flat table built once per profile, so the inner loop does array reads
-- and arithmetic and never calls into C.

local M = {}

local byte, huge = string.byte, math.huge

-- ---------------------------------------------------------------------------
-- letter classes
-- ---------------------------------------------------------------------------

local VOWEL = {}
for i = 1, 5 do VOWEL[byte("aeiou", i)] = true end
M.VOWEL = VOWEL

local APOSTROPHE = byte("'")

-- QWERTY physical layout.  Two keys are neighbours when their centres are
-- within one key width of each other; the staggered rows are modelled by the x
-- offsets below, which is why 'd' neighbours both 'e' and 'r'.
local LAYOUT = {
  { keys = "qwertyuiop", x0 = 0.00 },
  { keys = "asdfghjkl",  x0 = 0.25 },
  { keys = "zxcvbnm",    x0 = 0.75 },
}

local NEIGHBOUR = {}  -- packed key: a * 128 + b + 1

local function pack(a, b) return a * 128 + b + 1 end
M.pack = pack

local function build_neighbours()
  for i = 1, 128 * 128 do NEIGHBOUR[i] = false end
  local keys = {}
  for r, row in ipairs(LAYOUT) do
    for i = 1, #row.keys do
      keys[#keys + 1] = { c = byte(row.keys, i), x = row.x0 + (i - 1), y = r }
    end
  end
  for i = 1, #keys do
    for j = i + 1, #keys do
      local a, b = keys[i], keys[j]
      local dx, dy = a.x - b.x, a.y - b.y
      if dx < 0 then dx = -dx end
      if dy < 0 then dy = -dy end
      if dy <= 1 and dx <= 1.0 then
        NEIGHBOUR[pack(a.c, b.c)] = true
        NEIGHBOUR[pack(b.c, a.c)] = true
      end
    end
  end
end
build_neighbours()

M.NEIGHBOUR = NEIGHBOUR

--- Are two characters adjacent on a QWERTY keyboard?
function M.are_neighbours(a, b)
  return NEIGHBOUR[pack(byte(a), byte(b))] == true
end

-- ---------------------------------------------------------------------------
-- cost profiles
-- ---------------------------------------------------------------------------

--- Build a cost profile.  `t` overrides any of the defaults below.
---   extra_*   : a character the typist added that the word does not have
---   missing_* : a character of the word the typist did not type
---   *_double  : that character sits next to a copy of itself, i.e. the typist
---               got a double letter wrong rather than inventing a character
---   *_apostrophe : an apostrophe.  Skipping one is a typographic shortcut
---               rather than a spelling error -- "dont", "its", "id" -- so it
---               is priced accordingly and "don't", "it's", "I'd" stay close.
---   sub_*     : the typist hit the wrong key
---   transpose : the typist swapped two adjacent characters
function M.profile(t)
  t = t or {}
  local p = {
    extra_vowel     = t.extra_vowel     or 0.70,
    extra_other     = t.extra_other     or 1.00,
    extra_double    = t.extra_double    or 0.55,
    extra_apostrophe = t.extra_apostrophe or 0.15,
    missing_vowel   = t.missing_vowel   or 0.70,
    missing_other   = t.missing_other   or 1.00,
    missing_double  = t.missing_double  or 0.55,
    missing_apostrophe = t.missing_apostrophe or 0.15,
    sub_neighbour   = t.sub_neighbour   or 0.70,
    sub_vowel_vowel = t.sub_vowel_vowel or 0.75,
    sub_other       = t.sub_other       or 1.00,
    transpose       = t.transpose       or 0.45,
    -- how far past the end of `a` a prefix alignment may look (see
    -- `prefix_distance`); 10 covers "strtfctn" -> "stratification".
    max_drift       = t.max_drift       or 10,
  }
  -- Cheapest indel of any *letter*: bounds how far the alignment can stray
  -- from the diagonal, so the DP knows how wide a band to keep.  Apostrophes
  -- are excluded and accounted for separately, because they are much cheaper
  -- and letting them widen the band for every word would cost real time.
  p.min_indel_any = math.min(p.extra_vowel, p.extra_other, p.extra_double,
                             p.missing_vowel, p.missing_other, p.missing_double)
  -- The length gate needs the cheapest indel of *any* kind, apostrophes
  -- included, or it rejects "dont" -> "don't" at a small budget.  It is kept
  -- apart from min_indel_any because using it for the band would widen every
  -- comparison from three columns to nine.
  p.min_indel_gate = math.min(p.min_indel_any, p.extra_apostrophe, p.missing_apostrophe)
  -- Cheapest substitution: with the length difference already paid for, this
  -- is what the remaining budget can buy.  spellless.generate uses both of
  -- these to size its letter-mask prefilter.
  p.min_sub = math.min(p.sub_neighbour, p.sub_vowel_vowel, p.sub_other)

  -- Flat substitution table so the inner loop is one array read.
  local sub = {}
  for x = 0, 127 do
    local base = x * 128 + 1
    local vx = VOWEL[x]
    for y = 0, 127 do
      local cost
      if x == y then cost = 0
      elseif NEIGHBOUR[base + y] then cost = p.sub_neighbour
      elseif vx and VOWEL[y] then cost = p.sub_vowel_vowel
      else cost = p.sub_other end
      sub[base + y] = cost
    end
  end
  p.sub = sub
  return p
end

-- ---------------------------------------------------------------------------
-- scratch space, reused across calls
-- ---------------------------------------------------------------------------

local r0, r1, r2 = {}, {}, {}
local abyte, bbyte = {}, {}
local acost, bcost = {}, {}

--- Split `s` into a byte array and a per-character indel price.
---
--- A character next to a copy of itself is priced as a double-letter slip.
--- Marking both copies when the second one is seen keeps this to a single
--- `string.byte` per position.
--- Returns how many apostrophes `s` holds, which the caller adds to the band.
local function price(bytes, prices, s, n, cheap, vowel, other, apostrophe)
  local prev, apostrophes = -1, 0
  for i = 1, n do
    local c = byte(s, i)
    bytes[i] = c
    if c == APOSTROPHE then
      prices[i] = apostrophe
      apostrophes = apostrophes + 1
    elseif c == prev then
      prices[i] = cheap
      prices[i - 1] = cheap
    elseif VOWEL[c] then prices[i] = vowel
    else prices[i] = other end
    prev = c
  end
  return apostrophes
end

-- `a` is the same string for every candidate in a scan, so its byte array and
-- prices are computed once and reused until the query or the profile changes.
local priced_a, priced_p, priced_apostrophes

local function price_a(a, n, p)
  if a == priced_a and p == priced_p then return priced_apostrophes end
  priced_apostrophes =
      price(abyte, acost, a, n, p.extra_double, p.extra_vowel, p.extra_other,
            p.extra_apostrophe)
  priced_a, priced_p = a, p
  return priced_apostrophes
end

local function price_b(b, m, p)
  return price(bbyte, bcost, b, m, p.missing_double, p.missing_vowel,
               p.missing_other, p.missing_apostrophe)
end

--- Widest the alignment can stray from the diagonal and still fit `budget`.
--- Reaching a cell d columns off the diagonal when the strings differ in
--- length by `delta` needs at least 2d - delta indels.
---
--- `math.floor` rather than `//`: the costs are floats, and a float loop bound
--- would make every DP table access go through float-key normalisation.
local function band_width(budget, delta, p)
  return math.floor((math.floor(budget / p.min_indel_any) + delta) / 2)
end

-- ---------------------------------------------------------------------------

--- Weighted OSA distance between `a` (what was typed) and `b` (a dictionary
--- word), or nil when the distance provably exceeds `budget`.
function M.distance(a, b, budget, p)
  local n, m = #a, #b
  local delta = n - m
  if delta < 0 then delta = -delta end
  if delta * p.min_indel_gate > budget then return nil end
  if n == 0 then return m == 0 and 0 or nil end

  -- An apostrophe indel is far cheaper than the band formula assumes, so each
  -- one buys the alignment one extra column of freedom.
  local band = band_width(budget, delta, p) + price_a(a, n, p) + price_b(b, m, p)
  -- The answer lives at (n, m); if the band cannot reach that far the strings
  -- are too different in length for this budget, and reading r1[m] would give
  -- a stale cell rather than a distance.
  if delta > band then return nil end
  local sub, transpose = p.sub, p.transpose

  -- Row 0 is the cost of turning "" into b[1..j].  Only the cells the first
  -- row of the band can reach are ever read; computing the whole row would be
  -- wasted work on every candidate.
  local seed = band + 1
  if seed > m then seed = m end
  r1[0] = 0
  for j = 1, seed do r1[j] = r1[j - 1] + bcost[j] end
  r1[seed + 1] = nil
  local previous_best = 0

  for i = 1, n do
    local ai = abyte[i]
    local arow = ai * 128 + 1
    local extra_ai = acost[i]
    local prev_ai = abyte[i - 1]
    local lo, hi = i - band, i + band
    if lo < 1 then lo = 1 end
    if hi > m then hi = m end

    -- Column zero is reachable when the band still includes it: it means
    -- deleting the whole typed prefix.  Leaving it out of the row minimum made
    -- the abort reason from a value no cell actually had, and reject
    -- alignments that fit -- "aathe" -> "the" among them.
    local zero = (lo == 1) and (r1[0] + extra_ai) or huge
    r2[lo - 1] = zero
    local best = zero
    for j = lo, hi do
      local bj = bbyte[j]
      local cost = r1[j - 1] + sub[arow + bj]
      -- b[j] is a character of the word the typist did not type
      local via_missing = r2[j - 1] + bcost[j]
      if via_missing < cost then cost = via_missing end
      -- a[i] is a character the typist added that the word does not have
      local above = r1[j]
      if above then
        above = above + extra_ai
        if above < cost then cost = above end
      end
      if ai == bbyte[j - 1] and prev_ai == bj then
        local via_swap = r0[j - 2]
        if via_swap then
          via_swap = via_swap + transpose
          if via_swap < cost then cost = via_swap end
        end
      end
      r2[j] = cost
      if cost < best then best = cost end
    end
    -- Cells outside the band are unreachable within budget; blank the first
    -- one so the next row does not read a stale value from a wider call.
    r2[hi + 1] = nil
    -- One over-budget row is not enough to stop.  A transposition reads the
    -- row *two* back, so a row can exceed the budget and the next still
    -- recover through it -- which is how "ifnomration" -> "information" (two
    -- transpositions, 0.90) was being thrown away.
    --
    -- The bound: no cell of the next row can beat
    --     min(this row's minimum, the previous row's minimum + transpose)
    -- because those are the only two rows it derives from, and nothing else is
    -- free.  Once that exceeds the budget it stays exceeded, by induction.
    if best > budget and previous_best + transpose > budget then return nil end
    previous_best = best

    r0, r1, r2 = r1, r2, r0
  end

  local d = r1[m]
  if d == nil or d > budget then return nil end
  return d
end

--- Best weighted alignment of `a` against *any prefix* of `b`.
---
--- This is what makes consonant input work: "mthmt" should align with the
--- "mathemat" of "mathematics" at the price of a few skipped vowels, and the
--- rest of the word is then charged as a completion by the ranker rather than
--- as edits.  Taking the minimum over the final row instead of its last cell
--- is the whole difference from `distance`.
---
--- Cheap vowel indels make the useful band too wide to be worth maintaining,
--- so this variant walks full rows over the first `#a + max_drift` characters
--- of `b` and leans on the row-minimum abort instead.
function M.prefix_distance(a, b, budget, p)
  local n, m = #a, #b
  if n == 0 then return 0 end
  if m > n + p.max_drift then m = n + p.max_drift end

  price_a(a, n, p)
  price_b(b, m, p)
  local sub, transpose = p.sub, p.transpose

  r1[0] = 0
  for j = 1, m do r1[j] = r1[j - 1] + bcost[j] end
  local previous_best = 0

  for i = 1, n do
    local ai = abyte[i]
    local arow = ai * 128 + 1
    local extra_ai = acost[i]
    local prev_ai = abyte[i - 1]
    r2[0] = r1[0] + extra_ai
    local best = r2[0]
    for j = 1, m do
      local bj = bbyte[j]
      local cost = r1[j - 1] + sub[arow + bj]
      local via_missing = r2[j - 1] + bcost[j]
      if via_missing < cost then cost = via_missing end
      local via_extra = r1[j] + extra_ai
      if via_extra < cost then cost = via_extra end
      if ai == bbyte[j - 1] and prev_ai == bj then
        local via_swap = r0[j - 2] + transpose
        if via_swap < cost then cost = via_swap end
      end
      r2[j] = cost
      if cost < best then best = cost end
    end
    -- See `distance` for why one over-budget row is not enough to stop.
    if best > budget and previous_best + transpose > budget then return nil end
    previous_best = best
    r0, r1, r2 = r1, r2, r0
  end

  -- r1 now holds the final row; the best prefix of b is its cheapest cell.
  local d = r1[0]
  for j = 1, m do
    if r1[j] < d then d = r1[j] end
  end
  if d > budget then return nil end
  return d
end

return M
