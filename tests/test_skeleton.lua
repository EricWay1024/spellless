local H = require("harness")
local S = require("spellless.skeleton")
local Corpus = require("spellless.corpus")

H.suite("skeleton: documented rules")
H.eq(S.of("mathematics"), "mthmtcs", "the worked example")
H.eq(S.of("recommendation"), "rcmmndtn", "double letters survive")
H.eq(S.of("stratification"), "strtfctn")
H.eq(S.of("diffeomorphism"), "dffmrphsm")
H.eq(S.of("bordism"), "brdsm")
H.eq(S.of("triangulation"), "trngltn")
H.eq(S.of("about"), "abt", "a leading vowel is kept")
H.eq(S.of("system"), "systm", "y is kept")
H.eq(S.of("topology"), "tplgy")
H.eq(S.of("i"), "i", "single characters pass through")
H.eq(S.of(""), "", "empty input")

H.suite("skeleton: vowel ratio")
H.near(S.vowel_ratio("mthmtcs"), 0, 1e-9, "no vowels at all")
H.near(S.vowel_ratio("aeiou"), 1, 1e-9, "all vowels after the first")

H.suite("skeleton: Lua and Python agree on the shipped index")
-- generated/spellless.skel was sorted with scripts/_common.py:skeleton().  If
-- this module disagreed, the ordering would not be monotone and every binary
-- search over the skeleton index would silently return the wrong range.
local corpus, err = Corpus.load(_G.SPELLLESS_ROOT .. "/generated")
H.ok(corpus, "corpus loads: " .. tostring(err))
if corpus then
  local prev, breaks = "", 0
  for i = 1, corpus.n do
    local s = corpus:skeleton(corpus:skel_at(i))
    if s < prev then breaks = breaks + 1 end
    prev = s
  end
  H.eq(breaks, 0, "skeleton index is sorted under the Lua skeleton function")

  H.suite("corpus: derived structures agree with the word list")
  local mismatched_bucket, mismatched_mask = 0, 0
  for id = 1, corpus.n, 37 do
    local w = corpus.words[id]
    local key = Corpus.bucket_key(#S.of(w), string.byte(w, 1))
    local found = false
    for _, x in ipairs(corpus.sbuckets[key] or {}) do
      if x == id then found = true break end
    end
    if not found then mismatched_bucket = mismatched_bucket + 1 end
    local m = 0
    for c in S.of(w):gmatch("%a") do m = m | (1 << (string.byte(c) - 97)) end
    if m ~= corpus.smasks[id] then mismatched_mask = mismatched_mask + 1 end
  end
  H.eq(mismatched_bucket, 0, "skeleton length buckets")
  H.eq(mismatched_mask, 0, "skeleton letter masks")

  H.suite("corpus: a mismatched generated/ is refused, not half-loaded")
-- A *longer* stale index used to pass a minimum-size check and then hand out
-- word ids past the end of the list, surfacing much later as a nil comparison
-- inside a binary search.
do
  local util = require("spellless.util")
  local real = util.slurp
  local root = _G.SPELLLESS_ROOT .. "/generated/"
  util.slurp = function(path)
    local name = path:match("([^/]+)$")
    local data = real(root .. name)
    -- present only the first 100 words, with the full-size indexes
    if data and name == "spellless.words" then
      local out, count = {}, 0
      for line in data:gmatch("[^\n]+") do
        count = count + 1; out[count] = line
        if count == 100 then break end
      end
      return table.concat(out, "\n") .. "\n"
    end
    return data
  end
  local truncated, why = Corpus.load("truncated-words")
  util.slurp = real
  H.eq(truncated, nil, "loading is refused")
  H.ok(why and why:find("disagree"), "with a message naming the mismatch: " .. tostring(why))
end

H.suite("corpus: a CRLF checkout does not poison every word")
do
  local util = require("spellless.util")
  local real = util.slurp
  local root = _G.SPELLLESS_ROOT .. "/generated/"
  util.slurp = function(path)
    local name = path:match("([^/]+)$")
    local data = real(root .. name)
    if data and (name == "spellless.words" or name == "spellless.forms") then
      data = data:gsub("\n", "\r\n")
    end
    return data
  end
  local crlf = Corpus.load("crlf")
  util.slurp = real
  H.ok(crlf ~= nil, "it still loads")
  if crlf then
    H.ok(crlf:lookup("the") ~= nil, "and exact lookup still works")
    H.eq(crlf.words[crlf:lookup("the")], "the", "with no carriage return attached")
    H.eq(crlf.forms["i"], "I", "forms too")
  end
end

H.suite("corpus: index range searches")
  local hits = {}
  corpus:each_skeleton_exact("mthmtcs", function(id) hits[#hits + 1] = corpus.words[id] end)
  H.eq(table.concat(hits, " "), "mathematics", "exact skeleton group")
  -- "mthmtcs" has no strict extensions -- "mathematical" is "mthmtcl", a
  -- sibling, not a completion -- so use the half-typed "mthmt" here.
  hits = {}
  corpus:each_skeleton_completion("mthmt", 100, function(id) hits[#hits + 1] = corpus.words[id] end)
  H.ok(#hits >= 3, ("completions of mthmt: %d"):format(#hits))
  local joined = " " .. table.concat(hits, " ") .. " "
  H.ok(joined:find(" mathematics ", 1, true) ~= nil, "mathematics completes mthmt")
  H.ok(joined:find(" mathematical ", 1, true) ~= nil, "so does mathematical")
  hits = {}
  corpus:each_skeleton_exact("mthmt", function() hits[#hits + 1] = 1 end)
  H.eq(#hits, 0, "and nothing has mthmt as its whole skeleton")
  hits = {}
  corpus:each_skeleton_completion("mthmt", 2, function() hits[#hits + 1] = 1 end)
  H.eq(#hits, 2, "the completion cap is honoured")
  hits = {}
  corpus:each_prefix("mathematic", function(id) hits[#hits + 1] = corpus.words[id] end)
  table.sort(hits)
  H.eq(hits[1], "mathematic", "prefix range includes the exact word")
  H.ok(#hits >= 5, ("prefix range size %d"):format(#hits))
  H.eq(corpus:each_prefix("zzzzzzq", function() end), 0, "an empty prefix range")
  H.eq(corpus:each_skeleton_exact("zzzzzzq", function() end), 0, "an empty skeleton group")
end
