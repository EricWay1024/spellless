-- Words coined on the spot, out of a productive affix and a word.
--
-- English lets you make `resampling`, `nonabelian`, `overparametrised` or
-- `matrixwise` whenever you need them, and no dictionary can hold the results:
-- the whole point of a productive affix is that the list is open.  So the
-- matcher has to build them rather than look them up.
--
-- The rule is the one the user described: match what was typed *as typed*
-- first, and only then offer the reading where an affix is peeled off and the
-- rest is matched on its own.  `resmplng` finds nothing convincing whole, so
-- `re` comes off, `smplng` finds `sampling`, and `resampling` is offered.
--
-- Two guards keep `reading` out of it, and they matter more than the lists:
--
--   * a word the dictionary already knows is never peeled.  `reading` is a
--     word, so it is read as one, and so are `region`, `unit`, `coder`,
--     `nonsense` and every other word that merely begins with these letters.
--   * what is left has to be long enough to be a word.  Two or three letters
--     after the affix is not a stem, it is a coincidence.
--
-- The affix is recognised by its consonants as well as its spelling, because
-- somebody who writes `smplng` for `sampling` writes `nn` for `non` and `psd`
-- for `pseudo` in the same breath.  It is then written out in full: you get
-- `nonfunctor`, not `nnfunctor`.

local M = {}

local skeleton = require("spellless.skeleton")

-- Prefixes that attach to an ordinary word and make another one.  Longest
-- first, so `pseudo` is tried before `pse`-anything and `counter` before `co`.
M.PREFIXES = {
  "counter", "pseudo", "quasi", "hyper", "inter", "intra", "trans", "super",
  "under", "multi", "micro", "macro", "ultra", "proto", "semi", "anti",
  "over", "post", "self", "auto", "mono", "poly", "meta", "mini",
  "non", "pre", "sub", "mis", "dis", "neo", "mid", "bi", "tri",
  "un", "re", "de", "co", "ex",
}

-- Suffixes, the same idea from the other end: `matrixwise`, `functorless`,
-- `sheaflike`.  A shorter list, because English suffixes change the stem's
-- spelling far more often than prefixes do -- `-ness` on `happy` is `happiness`
-- -- and this does not attempt that.
M.SUFFIXES = {
  "worthy", "esque", "wise", "like", "less", "ness", "ful", "ish", "able",
  "hood", "ship", "ism", "ist",
}

--- Every way `query` could be an affix plus something else.
---
--- Returned longest-affix first, which is the order worth trying: `pseudo` is
--- a better account of `pseudofnctr` than `pse` would be, and the first
--- reading that finds a word is the one to offer.
---
--- Nothing here consults the dictionary; the caller decides whether the query
--- is already a word, and what the remainder turns out to be.
--- The spellings of `affix` worth looking for at the edge of a query: the
--- affix itself, and its consonant skeleton when that is different and still
--- long enough to mean something.  One letter is not an affix, it is a letter.
local function written_as(affix)
  local skel = skeleton.of(affix)
  if skel == affix or #skel < 2 then return { affix } end
  return { affix, skel }
end

function M.peel(query, min_stem)
  min_stem = min_stem or 4
  local out = {}
  for _, prefix in ipairs(M.PREFIXES) do
    for _, form in ipairs(written_as(prefix)) do
      if #query > #form + min_stem - 1 and query:sub(1, #form) == form then
        out[#out + 1] = { kind = "prefix", affix = prefix,
                          stem = query:sub(#form + 1) }
      end
    end
  end
  for _, suffix in ipairs(M.SUFFIXES) do
    for _, form in ipairs(written_as(suffix)) do
      if #query > #form + min_stem - 1 and query:sub(-#form) == form then
        out[#out + 1] = { kind = "suffix", affix = suffix,
                          stem = query:sub(1, #query - #form) }
      end
    end
  end
  return out
end

--- Put a coinage back together.
function M.join(part, stem)
  if part.kind == "prefix" then return part.affix .. stem end
  return stem .. part.affix
end

return M
