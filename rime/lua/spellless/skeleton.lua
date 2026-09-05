-- Consonant skeleton of an English word.
--
-- MUST stay identical to `skeleton()` in scripts/_common.py -- the generated
-- `spellless.skel` permutation is sorted with the Python version and binary
-- searched with this one.  tests/test_skeleton.lua re-checks that invariant
-- against the shipped index.
--
-- Rules:
--   * drop a e i o u
--   * keep 'y': it is consonantal about as often as it is vocalic, and typists
--     writing an abbreviation keep it ("systm", "tplgy", "hmtpy")
--   * always keep the first character even when it is a vowel, because nobody
--     drops a leading vowel ("about" -> "abt", not "bt")

local M = {}

--- Skeleton of `word` (assumed already lowercased).
function M.of(word)
  if #word < 2 then return word end
  local head = word:sub(1, 1)
  local tail = word:sub(2):gsub("[aeiou]", "")
  return head .. tail
end

--- Fraction of `word` (after the first character) that is a vowel.
--- Used as a "did the user mean this as an abbreviation?" signal: a query with
--- almost no vowels is far more likely to be a skeleton than a misspelling.
function M.vowel_ratio(word)
  if #word < 2 then return 0.5 end
  local tail = word:sub(2)
  local _, vowels = tail:gsub("[aeiou]", "")
  return vowels / #tail
end

return M
