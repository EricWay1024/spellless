local H = require("harness")
local P = require("spellless.preceding")

H.suite("preceding: when the next word needs a leading space")
local yes = { "hello", "hello,", "hello.", "hello!", "hello?", "hello;", "hello:",
              "word)", "word]", "1", "100%", "it's",
              -- the set is about the *last* character, so a word that merely
              -- contains a joiner still gets its space
              "@name", "#tag", "well-known" }
local no  = { "", " ", "hello ", "\t", "\n", "(", "[", "{", "<",
              "well-", "path/", "@", "#", "under_" }
for _, p in ipairs(yes) do
  H.ok(P.needs_space_after(p), ("a space belongs after %q"):format(p))
end
for _, p in ipairs(no) do
  H.ok(not P.needs_space_after(p), ("no space after %q"):format(p))
end
H.ok(not P.needs_space_after(nil), "nothing committed yet")

H.suite("preceding: CJK brings its own conventions")
H.ok(not P.needs_space_after("。"), "no Latin space after a full-width stop")
H.ok(not P.needs_space_after("，"), "nor after a full-width comma")
H.ok(not P.needs_space_after("中文"), "nor after Han characters")

H.suite("preceding: quotes open or close depending on what is behind them")
H.ok(not P.needs_space_after('he said "'), "an opening quote hugs the next word")
H.ok(not P.needs_space_after('("'), "even after a bracket")
H.ok(P.needs_space_after('no."'), "a closing quote does not")
H.ok(P.needs_space_after("dogs'"), "nor does a possessive apostrophe")

H.suite("preceding: where a sentence ends")
for _, s in ipairs{ "Hello.", "Hello!", "Hello?", "Hello. ", 'He said "no."',
                    "Really?)", "Done.\n" } do
  H.ok(P.ends_sentence(s), ("%q ends a sentence"):format(s))
end
for _, s in ipairs{ "", "hello", "hello,", "3.14", "hello;", "and", "(" } do
  H.ok(not P.ends_sentence(s), ("%q does not"):format(s))
end
H.ok(not P.ends_sentence(nil), "nothing committed yet")
H.suite("preceding: known abbreviations are not sentence ends")
-- Committing "e.g." as one candidate rather than five keystrokes is what makes
-- this possible: the whole abbreviation is there to recognise.
local abbrev = { ["e.g."] = true, ["i.e."] = true }
H.ok(not P.ends_sentence("e.g.", abbrev), "e.g. does not end a sentence")
H.ok(not P.ends_sentence(" e.g.", abbrev), "even with the automatic leading space")
H.ok(not P.ends_sentence("i.e.", abbrev))
H.ok(P.ends_sentence("hello.", abbrev), "an ordinary full stop still does")
H.ok(P.ends_sentence("etc.", abbrev), "and so does one that is not in the set")
H.ok(P.ends_sentence("e.g."), "without a set, it reads as a sentence end")

H.suite("preceding: inline maths delimiters are paired")
H.ok(not P.needs_space_after("Let $"), "an opening dollar hugs the formula")
H.ok(P.needs_space_after("Let $X$"), "a closing one does not")
H.ok(not P.needs_space_after("$"), "a bare dollar reads as opening")

H.suite("preceding: which marks reclaim the space in front of them")
-- The dual question, asked only when a word has already been committed with
-- its automatic space and punctuation follows.
H.ok(P.hugs_previous("."), "a full stop belongs to the word before it")
H.ok(P.hugs_previous(","), "so does a comma")
H.ok(P.hugs_previous(")"), "and a closing bracket")
H.ok(P.hugs_previous("-"), "a hyphen builds a compound word: well-known")
H.ok(P.hugs_previous("/"), "so does a slash: and/or")
H.ok(P.hugs_previous("_"), "and an underscore")
H.ok(not P.hugs_previous("("), "an opening bracket does not")
H.ok(not P.hugs_previous("="), "nor an equals sign, which wants its spaces")
H.ok(not P.hugs_previous("+"), "nor a plus")
H.ok(not P.hugs_previous('"'), "a quote is too ambiguous once the space is gone")
H.ok(not P.hugs_previous("$"), "and so is a dollar")
H.ok(not P.hugs_previous(""), "nothing to decide about nothing")
-- Sentence punctuation reclaims the space and then supplies one of its own;
-- a joiner reclaims it and supplies none, which is the point of joining.
for mark in (".,;:!?)]}"):gmatch(".") do
  H.ok(P.needs_space_after("word" .. mark),
       ("%s takes the space back and then supplies one"):format(mark))
end
for mark in ("-/_"):gmatch(".") do
  H.ok(not P.needs_space_after("word" .. mark),
       ("%s joins, so no space follows it"):format(mark))
end

H.suite("preceding: openers and where a sentence starts")
H.ok(P.opens_after_word("("), "a word keeps its space before an opening bracket")
H.ok(not P.opens_after_word("."), "but not before a full stop")
H.ok(P.starts_fresh(""), "nothing behind is a fresh sentence")
H.ok(P.starts_fresh("("), "and so is a lone opening bracket")
H.ok(P.starts_fresh('  "'), "or a quote after whitespace")
H.ok(not P.starts_fresh("hello "), "a word behind is not")
H.ok(P.ends_sentence("no. (", nil), "a bracket after a full stop still ends it")
H.ok(not P.ends_sentence("hello (", nil), "a bracket after a word does not")

H.suite("preceding: a LaTeX control sequence must not be guessed at")
H.ok(P.expects_literal("\\\\"), "a trailing backslash")
H.ok(P.expects_literal("see \\\\"), "even with text before it")
H.ok(not P.expects_literal("hello"), "ordinary text is fair game")
H.ok(not P.expects_literal(nil))

H.suite("preceding: the word before the caret, when it is clean enough to read")
-- Read only for its part of speech (spellless/wordclass.lua), where a wrong
-- reading is worse than none, so every ambiguous shape is rejected outright.
local word = {
  ["the "] = "the", ["of the "] = "the", ["don't "] = "don't",
  ["Hello there "] = "there", ["a "] = "a",
}
for tail, want in pairs(word) do
  H.eq(P.previous_word(tail), want, ("previous word of %q"):format(tail))
end
local no_word = { "", " ", "the", "the  ", "the, ", "(the) ", "the.  ", "3 ",
                  "the- ", "x' ", "  " }
for _, tail in ipairs(no_word) do
  H.eq(P.previous_word(tail), nil, ("no readable word before %q"):format(tail))
end
H.eq(P.previous_word(nil), nil, "nothing behind at all")

H.suite("preceding: abbreviations match as a suffix, in any case")
local ab = { ["e.g."] = true }
H.ok(not P.ends_sentence("see e.g.", ab), "in the middle of a tail")
H.ok(not P.ends_sentence("Hello. E.g.", ab), "capitalised at a sentence start")
H.ok(P.ends_sentence("Hello.", ab), "and an ordinary stop is unaffected")

H.suite("preceding: a modal calls for the bare form of the verb after it")
for _, tail in ipairs({ "you would ", "we could", "it should  ", "I will ",
                        "they might ", "that can ", "one must " }) do
  H.ok(P.expects_bare_verb(tail), ("a bare verb follows %q"):format(tail))
end
-- The closed class stops where the grammar does.  After `is/are` an -ed word
-- is the passive and perfectly ordinary -- 16% of the time in real prose --
-- and after `have` it is the participle, so neither belongs here.
for _, tail in ipairs({ "it is ", "they have ", "we are ", "he had ",
                        "the ", "to ", "", "should not ", "would have " }) do
  H.ok(not P.expects_bare_verb(tail), ("but not after %q"):format(tail))
end
H.ok(not P.expects_bare_verb(nil), "and not with nothing behind at all")
