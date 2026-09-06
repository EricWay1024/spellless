local H = require("harness")
local cue = require("spellless.cue")
local config = require("spellless.config")

local cfg = config.build()
local BIG = 99

--- Alignment cost, or nil.  Unbudgeted unless a budget is given.
local function cost(query, word, budget)
  return cue.align(query, word, budget or BIG, cfg)
end

H.suite("cue: the letters typed must appear in the word, in order")
H.eq(cost("tnk", "think") ~= nil, true, "tnk is a subsequence of think")
H.eq(cost("tkn", "think"), nil, "tkn is not: the order is wrong")
H.eq(cost("tnkx", "think"), nil, "a letter the word does not have")
H.eq(cost("hnk", "think"), nil, "the first letter has to match")
H.eq(cost("think", "think"), 0, "and a word is its own shorthand, for free")
H.eq(cost("thinking", "think"), nil, "longer than the word")

H.suite("cue: what the skipped letters cost")
-- The prices themselves live in config.lua; what this pins down is which
-- price each skipped character is charged, because that is the whole model.
H.near(cost("tank", "tank"), 0, 1e-9)
H.near(cost("tnk", "tank"), cfg.cue_skip_vowel, 1e-9, "a skipped vowel is nearly free")
H.near(cost("tnk", "think"), cfg.cue_skip_cluster + cfg.cue_skip_vowel, 1e-9,
       "the h of th is a cluster, the i a vowel")
H.near(cost("ctl", "cattle"), cfg.cue_skip_cluster + 2 * cfg.cue_skip_vowel, 1e-9,
       "one t of a double is a consonant beside a consonant")
H.near(cost("mtl", "material"), cfg.cue_skip_onset + 4 * cfg.cue_skip_vowel, 1e-9,
       "the r of mate-rial starts a syllable, and skipping that is not free")

H.suite("cue: the tail is charged too")
-- Shorthand runs to the end of the word.  A word whose last syllable nobody
-- typed is a completion, which other channels answer; charging its tail is
-- what stops "embarass" reading as "embarrassed".
H.ok(cost("embarass", "embarrassed") > cost("embarass", "embarrass"),
     "a word with two letters left over costs more than one with none")
H.ok(cost("tnk", "thinking") > cost("tnk", "think"),
     "and so does a completion of it")

H.suite("cue: the worked examples")
for _, case in ipairs({
  { "satfcatn", "stratification" }, { "stfcatn", "stratification" },
  { "dfmrphsm", "diffeomorphism" }, { "hmtpy", "homotopy" },
  { "gvmnt", "government" }, { "ppl", "people" },
}) do
  H.ok(cost(case[1], case[2]) ~= nil,
       ("%q aligns onto %q"):format(case[1], case[2]))
end

H.suite("cue: the budget is honoured")
H.eq(cost("tnk", "think", 0.1), nil, "too expensive to report")
H.ok(cost("tnk", "think", 1.0) ~= nil, "affordable at a real budget")

H.suite("cue: scratch space does not leak between calls")
-- The byte and price arrays outlive each call, so a long word followed by a
-- short one used to see the long one's characters off the end of the short.
local long_first = cost("aaz", "aardvarkz")
H.ok(long_first ~= nil, "a long word first")
H.near(cost("tnk", "tank"), cfg.cue_skip_vowel, 1e-9, "then a short one, unaffected")
H.near(cost("aaz", "aardvarkz"), long_first, 1e-9, "and back again")
