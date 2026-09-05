local H = require("harness")
local D = require("spellless.distance")

H.suite("distance: keyboard adjacency")
H.ok(D.are_neighbours("e", "r"), "e and r are adjacent")
H.ok(D.are_neighbours("d", "e"), "d sits under e/r")
H.ok(D.are_neighbours("d", "r"), "d sits under e/r")
H.ok(D.are_neighbours("n", "m"), "n and m are adjacent")
H.ok(not D.are_neighbours("q", "p"), "q and p are far apart")
H.ok(not D.are_neighbours("a", "l"), "a and l are far apart")
H.ok(D.are_neighbours("a", "z"), "a is above z")

H.suite("util: the pieces the scan leans on")
local util = require("spellless.util")
H.eq(util.popcount26(0), 0)
H.eq(util.popcount26(1 | (1 << 13) | (1 << 25)), 3, "bits above and below the split")
H.eq(util.popcount26((1 << 26) - 1), 26, "a full 26-bit mask")

local top = util.top(3)
for _, k in ipairs{ 50, 10, 40, 5, 30, 60 } do top:push(k, k) end
local kept = {}
top:each(function(v) kept[#kept + 1] = v end)
table.sort(kept)
H.eq(table.concat(kept, ","), "5,10,30", "keeps the three smallest keys")

H.suite("distance: weighted OSA")
local p = D.profile()
H.near(D.distance("the", "the", 3, p), 0, 1e-9, "identical")
H.near(D.distance("teh", "the", 3, p), p.transpose, 1e-9, "adjacent transposition")
H.near(D.distance("recommned", "recommend", 3, p), p.transpose, 1e-9, "transposition mid-word")
H.near(D.distance("mathe", "math", 3, p), p.extra_vowel, 1e-9, "extra trailing vowel")
H.near(D.distance("math", "mathe", 3, p), p.missing_vowel, 1e-9, "omitted trailing vowel")
H.near(D.distance("nirth", "north", 3, p), p.sub_neighbour, 1e-9, "neighbour key substitution")
H.near(D.distance("nurth", "north", 3, p), p.sub_vowel_vowel, 1e-9, "vowel-for-vowel substitution")
H.near(D.distance("commited", "committed", 3, p), p.missing_double, 1e-9,
       "under-typed double letter")
H.near(D.distance("harrass", "harass", 3, p), p.extra_double, 1e-9,
       "over-typed double letter")
H.ok(p.missing_double < p.missing_other, "a double-letter slip beats a random omission")
H.near(D.distance("dont", "don't", 3, p), p.missing_apostrophe, 1e-9, "dropped apostrophe")
H.near(D.distance("its", "it's", 3, p), p.missing_apostrophe, 1e-9, "its -> it's")
H.near(D.distance("id", "i'd", 3, p), p.missing_apostrophe, 1e-9, "id -> i'd")
H.ok(p.missing_apostrophe < p.missing_vowel,
     "and it is cheaper than any real spelling error")
H.eq(D.distance("cat", "dog", 1.0, p), nil, "far apart, over budget")
H.eq(D.distance("a", "abcdefgh", 1.0, p), nil, "length gate rejects early")

H.suite("distance: banded result matches an unbanded reference")
-- Reference implementation: plain O(n*m) weighted OSA with no band and no
-- early abort.  If the two ever disagree the band is too narrow.
local function indel(s, i, prof, kind)
  local c = string.byte(s, i)
  if c == string.byte("'") then
    return prof[kind .. "_apostrophe"]
  elseif c == string.byte(s, i - 1) or c == string.byte(s, i + 1) then
    return prof[kind .. "_double"]
  elseif D.VOWEL[c] then return prof[kind .. "_vowel"]
  else return prof[kind .. "_other"] end
end

local function reference(a, b, prof)
  local n, m = #a, #b
  local d = {}
  for i = 0, n do d[i] = {} end
  d[0][0] = 0
  for i = 1, n do d[i][0] = d[i - 1][0] + indel(a, i, prof, "extra") end
  for j = 1, m do d[0][j] = d[0][j - 1] + indel(b, j, prof, "missing") end
  for i = 1, n do
    for j = 1, m do
      local ai, bj = string.byte(a, i), string.byte(b, j)
      local sub
      if ai == bj then sub = 0
      elseif D.NEIGHBOUR[D.pack(ai, bj)] then sub = prof.sub_neighbour
      elseif D.VOWEL[ai] and D.VOWEL[bj] then sub = prof.sub_vowel_vowel
      else sub = prof.sub_other end
      local best = d[i - 1][j - 1] + sub
      local v = d[i][j - 1] + indel(b, j, prof, "missing")
      if v < best then best = v end
      v = d[i - 1][j] + indel(a, i, prof, "extra")
      if v < best then best = v end
      if i > 1 and j > 1 and ai == string.byte(b, j - 1) and string.byte(a, i - 1) == bj then
        v = d[i - 2][j - 2] + prof.transpose
        if v < best then best = v end
      end
      d[i][j] = best
    end
  end
  return d[n][m], d[n]
end

local words = { "the", "there", "theorem", "receive", "mathematics", "form", "from",
                "separate", "occurrence", "bordism", "a", "an", "stratification",
                "committed", "commited", "harrass", "harass", "bookkeeper",
                "dont", "don't", "its", "it's", "id", "i'd", "were", "we're" }
local budget = 2.5
for _, a in ipairs(words) do
  for _, b in ipairs(words) do
    local want = reference(a, b, p)
    local got = D.distance(a, b, budget, p)
    if want <= budget then
      H.near(got, want, 1e-9, ("distance(%q,%q)"):format(a, b))
    else
      H.eq(got, nil, ("distance(%q,%q) should exceed the budget"):format(a, b))
    end
  end
end

H.suite("distance: the band and the abort agree with the reference at scale")
-- A hand-picked word list is not enough: "ifnomration" -> "information" (two
-- transpositions, cost 0.9) was silently rejected for months because no pair
-- in the list above needed a row to go over budget and come back through the
-- transposition recurrence.  Sample the real corpus and corrupt it instead.
do
  local Corpus = require("spellless.corpus")
  local corpus = assert(Corpus.load(_G.SPELLLESS_ROOT .. "/generated"))
  math.randomseed(20260905)
  local function corrupt(w, edits)
    for _ = 1, edits do
      local i = math.random(1, math.max(1, #w - 1))
      if #w > 2 then w = w:sub(1, i - 1) .. w:sub(i + 1, i + 1) .. w:sub(i, i) .. w:sub(i + 2) end
    end
    return w
  end
  local mismatches, checked = 0, 0
  for trial = 1, 400 do
    local word = corpus.words[math.random(1, 20000)]
    local typo = corrupt(word, 1 + trial % 3)
    for _, budget in ipairs{ 1.35, 1.8, 2.5 } do
      local want = reference(typo, word, p)
      local got = D.distance(typo, word, budget, p)
      checked = checked + 1
      if want <= budget then
        if got == nil or math.abs(got - want) > 1e-9 then
          mismatches = mismatches + 1
          if mismatches <= 3 then
            io.write(("    %q vs %q budget %.2f: got %s, reference %.2f\n")
                     :format(typo, word, budget, tostring(got), want))
          end
        end
      elseif got ~= nil then
        mismatches = mismatches + 1
      end
    end
  end
  H.eq(mismatches, 0, ("%d corrupted-corpus comparisons"):format(checked))
end

H.suite("distance: prefix alignment")
local e = D.profile{ missing_vowel = 0.12, extra_vowel = 0.90, sub_vowel_vowel = 0.60 }
H.near(D.prefix_distance("mthmtcs", "mathematics", 3, e), 4 * 0.12, 1e-9,
       "skeleton skips four vowels")
H.near(D.prefix_distance("mthmt", "mathematics", 3, e), 3 * 0.12, 1e-9,
       "partial skeleton aligns with a prefix")
H.near(D.prefix_distance("frm", "from", 3, e), 0.12, 1e-9, "frm -> from")
H.ok(D.prefix_distance("theorme", "thermal", 1.6, e) == nil
     or D.prefix_distance("theorme", "thermal", 1.6, e) > 1.0,
     "typed vowels are evidence: theorme is not a cheap abbreviation of thermal")

for _, a in ipairs(words) do
  for _, b in ipairs(words) do
    local _, last_row = reference(a, b, e)
    local want = math.huge
    for j = 0, math.min(#b, #a + e.max_drift) do
      if last_row[j] < want then want = last_row[j] end
    end
    local got = D.prefix_distance(a, b, 99, e)
    H.near(got, want, 1e-9, ("prefix_distance(%q,%q)"):format(a, b))
  end
end

return H
