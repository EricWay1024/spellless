-- The coarse part-of-speech class, the PMI table, and the two properties that
-- make the context term safe to have in the tree at all: it is exactly zero
-- whenever either side has nothing to say, and with the flag off it does not
-- run.
--
-- These are contract tests, not accuracy tests.  What the feature is actually
-- worth is bench/context.lua, and the answer there is "less than nothing with
-- the hand-written table", which is why config.context_class is false.

local H = require("harness")
local W = require("spellless.wordclass")
local Engine = require("spellless.engine")

H.suite("wordclass: suffix morphology")
local classes = {
  regulatory = W.ADJ, regulator = W.NOUN,
  generation = W.NOUN, generate = W.VERB,
  litigation = W.NOUN, litigate = W.VERB,
  quickly = W.ADV, happiness = W.NOUN, argument = W.NOUN,
  dangerous = W.ADJ, hopeless = W.ADJ, running = W.VERB, walked = W.VERB,
}
for word, want in pairs(classes) do
  H.eq(W.of(word), want, ("class of %q"):format(word))
end

H.suite("wordclass: nothing fires means nothing is said")
-- A default of NOUN would be an opinion, and the whole design rests on the
-- term being able to say nothing.
for _, word in ipairs{ "house", "cat", "grothendieck", "kubectl", "", "x" } do
  H.eq(W.of(word), nil, ("no class for %q"):format(word))
end
H.eq(W.of(nil), nil, "no class for nothing")
-- Apostrophes and spaces are dropped, so a surface form is judged on letters.
H.eq(W.of("don't"), W.of("dont"), "an apostrophe changes nothing")

H.suite("wordclass: the length floors stop short words matching")
H.eq(W.of("for"), "PREP", "'for' is closed class, not an -or noun")
H.eq(W.of("red"), nil, "'red' is not an -ed verb")
H.eq(W.of("her"), "DET", "'her' is closed class, not an -er noun")

H.suite("wordclass: what the previous word predicts")
H.eq(W.context_of("the"), "DET")
H.eq(W.context_of("The"), "DET", "case is irrelevant")
H.eq(W.context_of("of"), "PREP")
H.eq(W.context_of("to"), "TO", "'to' gets a row of its own: it is both")
H.eq(W.context_of("very"), "DEG")
H.eq(W.context_of("and"), "NEUTRAL", "named, and deliberately empty")
H.eq(W.context_of("elephant"), nil, "most of English has no row")
H.eq(W.context_of(nil), nil)

H.suite("wordclass: PMI is zero-centred")
H.eq(W.pmi(nil, W.NOUN), 0, "no previous word, no opinion")
H.eq(W.pmi("DET", nil), 0, "no candidate class, no opinion")
H.eq(W.pmi(nil, nil), 0)
H.eq(W.pmi("NEUTRAL", W.NOUN), 0, "'and' predicts what came before it, unseen")
H.eq(W.pmi("DET", "PRON"), 0, "a class the table has no column for")
H.ok(W.pmi("DET", W.NOUN) > 0, "a determiner favours a noun")
H.ok(W.pmi("DET", W.VERB) < 0, "and disfavours a verb")
H.ok(W.pmi("TO", W.VERB) > 0, "'to' leans to the infinitive")
H.ok(W.pmi("TO", W.NOUN) > -0.5, "without condemning 'to school'")
H.ok(W.pmi("DEG", W.ADJ) > 0, "'very' favours an adjective")
-- Bounded, which is what stops one hand-written prior from being worth more
-- than the evidence in the input.
for _, row in pairs(W.PMI) do
  for cls, v in pairs(row) do
    H.ok(math.abs(v) <= 1.5, ("PMI %s is bounded"):format(cls))
  end
end

H.suite("wordclass: the flag is off, and off means untouched")
local engine = assert(Engine.new{ data_dir = _G.SPELLLESS_ROOT .. "/generated" })
H.eq(engine.cfg.context_class, false, "off by default")
H.eq(engine:context_class("the"), nil, "and the class is not even looked up")

local function texts(list)
  local out = {}
  for i = 1, #list do out[i] = list[i].text .. ":" .. ("%.4f"):format(list[i].score) end
  return table.concat(out, " ")
end
for _, q in ipairs{ "gnert", "rgulator", "mathe", "teh", "mthmtcs" } do
  H.eq(texts(engine:suggest(q, 20, { previous_word = "the" })),
       texts(engine:suggest(q, 20)),
       ("a previous word changes nothing while the flag is off: %q"):format(q))
end

H.suite("wordclass: with the flag on, the gates still silence it")
local on = assert(Engine.new{ data_dir = _G.SPELLLESS_ROOT .. "/generated",
                              config = { context_class = true } })
H.eq(on:context_class("zzzqx"), nil, "not a dictionary word")
H.eq(on:context_class("elephant"), nil, "a dictionary word with no row")
H.eq(on:context_class(nil), nil, "no previous word at all")
H.eq(on:context_class("the"), "DET", "and a classified one does come through")
for _, prev in ipairs{ "zzzqx", "elephant", "and" } do
  H.eq(texts(on:suggest("gnert", 20, { previous_word = prev })),
       texts(on:suggest("gnert", 20)),
       ("%q says nothing, so the list is unchanged"):format(prev))
end
-- And when it does fire, it fires: this is the one case in tests/cases that the
-- hand-written table settles.
H.eq(on:suggest("gnert", 20, { previous_word = "the" })[1].text, "generation",
     "'the gnert' does reach generation")
H.eq(on:suggest("gnert", 20)[1].text, "generate",
     "and without the context it does not")

H.suite("wordclass: the margin keeps an exact match out of reach")
-- "inform" is an exact dictionary hit and leads "information" by 19.7 points;
-- no previous word may overturn that, which is what context_margin is for.
H.eq(on:suggest("inform", 20, { previous_word = "the" })[1].text, "inform",
     "an exact match survives a determiner")
H.eq(on:suggest("the", 20, { previous_word = "of" })[1].text, "the",
     "and so does the commonest word in English")
