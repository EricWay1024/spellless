-- A property test for spellless.distance.
--
-- `distance` and `prefix_distance` are banded and they abort early, which is
-- the only reason the scan fits in the latency budget -- and both of those are
-- optimisations that can silently *lose* a valid alignment rather than fail
-- loudly.  That has happened: aborting on a single over-budget row threw away
--
--     ifnomration -> information     two transpositions, total cost 0.90
--
-- for months, because a transposition reads the row *two* back and a row can
-- therefore go over budget and the next still recover through it.  It was
-- found by accident.  A hand-written list of pairs did not catch it, and could
-- not have: whether a row goes over budget and comes back is a property of the
-- particular pair, not of anything a person thinks to write down.
--
-- So this file does not check answers.  It checks the two implementations
-- against a plain O(n*m) reference of the same weighted OSA recurrence -- no
-- band, no abort, no rolling rows -- over a few hundred generated pairs:
-- corpus words, corrupted corpus words, junk strings, and strings carrying the
-- two things that make the pricing non-uniform (apostrophes and doubled
-- letters).  It runs against all three shipped cost profiles at six budgets.
--
-- The generator is a fixed-seed PRNG of its own rather than math.random, so
-- the pairs are the same on every machine and every Lua build, and a failure
-- is reproducible from the seed printed with it.

local H = require("harness")
local D = require("spellless.distance")
local Generate = require("spellless.generate")
local Corpus = require("spellless.corpus")

local byte, sub = string.byte, string.sub
local APOSTROPHE = byte("'")

-- ---------------------------------------------------------------------------
-- deterministic PRNG (xorshift64*), so the case list never moves
-- ---------------------------------------------------------------------------
-- Fixed, so `make test` runs the same 400 pairs every time and a failure can
-- be reproduced from the seed printed with it.  Both are overridable from the
-- environment, which is not for the test suite but for soaking: a few hundred
-- pairs is enough to catch a systematic error like the one-row abort, and a
-- few hundred thousand is what it takes to be confident about the corners.
--     SPELLLESS_PROPERTY_SEED=7 SPELLLESS_PROPERTY_PAIRS=20000 lua tests/run.lua
local SEED = tonumber(os.getenv("SPELLLESS_PROPERTY_SEED")) or 20260906
local NPAIRS = tonumber(os.getenv("SPELLLESS_PROPERTY_PAIRS")) or 400
local state = SEED ~ 0x9E3779B97F4A7C15

local function next_bits()
  state = state ~ (state << 13)
  state = state ~ (state >> 7)
  state = state ~ (state << 17)
  return state
end
for _ = 1, 8 do next_bits() end

--- Uniform in [0,1).  The top 53 bits, because an xorshift's low bits are the
--- weakest and the choices here are all small integers.
local function rnd() return (next_bits() >> 11) * (2 ^ -53) end
local function rint(a, b) return a + math.floor(rnd() * (b - a + 1)) end
local function pick(t) return t[rint(1, #t)] end

-- ---------------------------------------------------------------------------
-- the reference: weighted OSA, whole table, no band, no abort
-- ---------------------------------------------------------------------------

--- What one character of `s` costs to insert or delete, exactly as
--- distance.price computes it: an apostrophe is a typographic shortcut, a
--- character next to a copy of itself is a miscounted double, a vowel is a
--- vowel.
local function indel(s, i, prof, kind)
  local c = byte(s, i)
  if c == APOSTROPHE then return prof[kind .. "_apostrophe"] end
  if c == byte(s, i - 1) or c == byte(s, i + 1) then return prof[kind .. "_double"] end
  if D.VOWEL[c] then return prof[kind .. "_vowel"] end
  return prof[kind .. "_other"]
end

local function sub_cost(ai, bj, prof)
  if ai == bj then return 0 end
  if D.NEIGHBOUR[D.pack(ai, bj)] then return prof.sub_neighbour end
  if D.VOWEL[ai] and D.VOWEL[bj] then return prof.sub_vowel_vowel end
  return prof.sub_other
end

-- Reused across calls so a few thousand references do not allocate a few
-- thousand tables; the test has to stay well inside a second.
local ref = {}
for i = 0, 64 do ref[i] = {} end

--- Full weighted OSA table.  Returns d[n][m] and the final row.
local function reference(a, b, prof)
  local n, m = #a, #b
  local d = ref
  d[0][0] = 0
  for i = 1, n do d[i][0] = d[i - 1][0] + indel(a, i, prof, "extra") end
  for j = 1, m do d[0][j] = d[0][j - 1] + indel(b, j, prof, "missing") end
  for i = 1, n do
    local ai = byte(a, i)
    local extra_ai = indel(a, i, prof, "extra")
    local prev_ai = byte(a, i - 1)
    local row, above = d[i], d[i - 1]
    for j = 1, m do
      local bj = byte(b, j)
      local best = above[j - 1] + sub_cost(ai, bj, prof)
      local v = row[j - 1] + indel(b, j, prof, "missing")
      if v < best then best = v end
      v = above[j] + extra_ai
      if v < best then best = v end
      if i > 1 and j > 1 and ai == byte(b, j - 1) and prev_ai == bj then
        v = d[i - 2][j - 2] + prof.transpose
        if v < best then best = v end
      end
      row[j] = best
    end
  end
  return d[n][m], d[n]
end

--- The same reference read the way `prefix_distance` reads it: `b` truncated
--- to what the drift allows, and the minimum over the final row rather than
--- its last cell.
local function prefix_reference(a, b, prof)
  local m = #b
  if m > #a + prof.max_drift then m = #a + prof.max_drift end
  local _, last = reference(a, sub(b, 1, m), prof)
  local best = last[0]
  for j = 1, m do
    if last[j] < best then best = last[j] end
  end
  return best
end

-- ---------------------------------------------------------------------------
-- generators
-- ---------------------------------------------------------------------------
local corpus = assert(Corpus.load(_G.SPELLLESS_ROOT .. "/generated"))
local NWORDS = math.min(#corpus.words, 40000)

local LETTERS = "abcdefghijklmnopqrstuvwxyz"
local VOWELS = "aeiou"

local function word() return corpus.words[rint(1, NWORDS)] end
local function letter() return sub(LETTERS, rint(1, 26), rint(1, 26)) end

local NEIGHBOURS_OF = {}
for i = 1, 26 do
  local c = sub(LETTERS, i, i)
  local list = {}
  for j = 1, 26 do
    local o = sub(LETTERS, j, j)
    if o ~= c and D.are_neighbours(c, o) then list[#list + 1] = o end
  end
  NEIGHBOURS_OF[c] = list
end

--- One plausible slip.  `only` restricts the kind, which is how the
--- two-transposition case that broke the abort is generated on purpose.
local function slip(w, only)
  local n = #w
  if n < 2 then return w .. letter() end
  local kind = only or pick{ "transpose", "delete", "insert", "substitute",
                             "neighbour", "apostrophe", "double" }
  local i = rint(1, n - 1)
  if kind == "transpose" then
    return sub(w, 1, i - 1) .. sub(w, i + 1, i + 1) .. sub(w, i, i) .. sub(w, i + 2)
  elseif kind == "delete" then
    return sub(w, 1, i - 1) .. sub(w, i + 1)
  elseif kind == "insert" or kind == "double" then
    return sub(w, 1, i) .. sub(w, i, i) .. sub(w, i + 1)
  elseif kind == "apostrophe" then
    return sub(w, 1, i) .. "'" .. sub(w, i + 1)
  elseif kind == "neighbour" then
    local opts = NEIGHBOURS_OF[sub(w, i, i)]
    if not opts or #opts == 0 then return w end
    return sub(w, 1, i - 1) .. pick(opts) .. sub(w, i + 1)
  end
  return sub(w, 1, i - 1) .. letter() .. sub(w, i + 1)
end

local function corrupt(w, edits, only)
  for _ = 1, edits do w = slip(w, only) end
  return w
end

--- A string over the actual alphabet, biased so that doubled letters and
--- apostrophes -- the two characters with their own prices -- turn up often
--- enough to be exercised.
local function junk(len)
  local out = {}
  for i = 1, len do
    local r = rnd()
    if r < 0.10 then out[i] = "'"
    elseif r < 0.22 and i > 1 then out[i] = out[i - 1]
    elseif r < 0.55 then out[i] = sub(VOWELS, rint(1, 5), rint(1, 5))
    else out[i] = letter() end
  end
  return table.concat(out)
end

--- The pair list.  Every entry is (what was typed, a dictionary word) in the
--- direction the matcher actually uses, plus a few that are neither.
local function make_pairs(n)
  local pairs_out = {}
  while #pairs_out < n do
    local kind = rint(1, 8)
    local a, b
    if kind == 1 then
      b = word(); a = b                                   -- identical
    elseif kind == 2 then
      b = word(); a = corrupt(b, rint(1, 3))               -- ordinary typing slips
    elseif kind == 3 then
      -- Two or three *separated* transpositions: the class that made a row go
      -- over budget and come back, and the only reason this file exists.
      b = word()
      if #b >= 7 then a = corrupt(b, rint(2, 3), "transpose") else a = corrupt(b, 2, "transpose") end
    elseif kind == 4 then
      b = word(); a = corrupt(b, rint(1, 2), "double")     -- miscounted doubles
    elseif kind == 5 then
      b = word(); a = corrupt(b, 1, "apostrophe")          -- apostrophes both ways
      if rnd() < 0.5 then a, b = b, a end
    elseif kind == 6 then
      a = junk(rint(1, 12)); b = word()                    -- junk against a word
    elseif kind == 7 then
      a = junk(rint(1, 10)); b = junk(rint(0, 10))         -- junk against junk
    else
      a = word(); b = word()                               -- two unrelated words
    end
    -- `a` is never empty: `distance` answers nil for an empty query by
    -- deliberate shortcut rather than by the recurrence, which the reference
    -- has no way to know about.  It is asserted separately below, and the
    -- engine cannot produce one anyway -- an empty composition returns early,
    -- and the only other route to an empty search string, the possessive stem
    -- of "'s", is rejected by the `^[a-z]` guard before any search runs.
    --
    -- The reference is O(n*m) and the DP tables above are sized for 64; the
    -- matcher never sees anything longer than max_query_len anyway.
    if #a >= 1 and #a <= 28 and #b <= 28 then pairs_out[#pairs_out + 1] = { a, b } end
  end
  return pairs_out
end

-- ---------------------------------------------------------------------------
-- the property
-- ---------------------------------------------------------------------------
local PROFILES = {
  { name = "typo",     p = Generate.TYPO_PROFILE },
  { name = "skeleton", p = Generate.SKELETON_PROFILE },
  { name = "elastic",  p = Generate.ELASTIC_PROFILE },
}
local BUDGETS = { 0.5, 0.9, 1.35, 1.7, 2.1, 3.0 }

H.suite("distance: banded, aborted DP agrees with an unbanded reference")
do
  local cases = make_pairs(NPAIRS)
  local mismatches, checked, reported = 0, 0, 0

  local function complain(fmt, ...)
    reported = reported + 1
    if reported <= 6 then io.write(("    " .. fmt .. "\n"):format(...)) end
  end

  for _, pr in ipairs(cases) do
    local a, b = pr[1], pr[2]
    for _, prof in ipairs(PROFILES) do
      local want = reference(a, b, prof.p)
      local want_prefix = prefix_reference(a, b, prof.p)
      for _, budget in ipairs(BUDGETS) do
        -- A reference cost sitting exactly on the budget is a float-equality
        -- coin toss, not a bug; skip those rather than assert about them.
        if math.abs(want - budget) > 1e-9 then
          checked = checked + 1
          local got = D.distance(a, b, budget, prof.p)
          if want < budget then
            if got == nil or math.abs(got - want) > 1e-9 then
              mismatches = mismatches + 1
              complain("distance(%q,%q) %s budget %.2f: got %s, reference %.4f",
                       a, b, prof.name, budget, tostring(got), want)
            end
          elseif got ~= nil then
            mismatches = mismatches + 1
            complain("distance(%q,%q) %s budget %.2f: got %.4f, reference %.4f is over budget",
                     a, b, prof.name, budget, got, want)
          end
        end
        if math.abs(want_prefix - budget) > 1e-9 then
          checked = checked + 1
          local got = D.prefix_distance(a, b, budget, prof.p)
          if want_prefix < budget then
            if got == nil or math.abs(got - want_prefix) > 1e-9 then
              mismatches = mismatches + 1
              complain("prefix_distance(%q,%q) %s budget %.2f: got %s, reference %.4f",
                       a, b, prof.name, budget, tostring(got), want_prefix)
            end
          elseif got ~= nil then
            mismatches = mismatches + 1
            complain("prefix_distance(%q,%q) %s budget %.2f: got %.4f, reference %.4f is over budget",
                     a, b, prof.name, budget, got, want_prefix)
          end
        end
      end
    end
  end
  if reported > 6 then io.write(("    ... and %d more\n"):format(reported - 6)) end
  H.eq(mismatches, 0,
       ("%d comparisons over %d pairs, seed %d"):format(checked, #cases, SEED))
end

H.suite("distance: the empty query, which the recurrence does not describe")
-- The one place where `distance` is deliberately not the reference: an empty
-- query is answered nil whatever the budget, rather than "the cost of deleting
-- the whole word".  Pinned here so that the exclusion above is a stated
-- contract rather than a gap in the generator.
do
  local p = Generate.TYPO_PROFILE
  H.eq(D.distance("", "the", 99, p), nil, "an empty query matches nothing")
  H.eq(D.distance("", "'", 99, p), nil, "not even at a price the reference would pay")
  H.near(D.distance("", "", 99, p), 0, 1e-9, "two empty strings are still identical")
end

H.suite("distance: the alignment that the one-row abort used to lose")
-- Kept by name as well, because it is the pair that cost the months.  The
-- property test above generates its class; this asserts the instance.
do
  local p = Generate.TYPO_PROFILE
  H.near(D.distance("ifnomration", "information", 1.35, p), 2 * p.transpose, 1e-9,
         "two transpositions, and a row that goes over budget in between")
  H.near(reference("ifnomration", "information", p), 2 * p.transpose, 1e-9,
         "and the reference says the same")
end

return H
