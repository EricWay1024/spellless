local H = require("harness")
local mock = require("rime_mock")

local DATA = _G.SPELLLESS_ROOT .. "/generated"
local XK_Return, XK_BackSpace = 0xff0d, 0xff08
local personal = os.tmpname()

H.suite("adapter: init / func / fini against a mocked librime-lua")
-- user_dir points at a scratch directory: the adapter derives the personal
-- vocabulary path from it, and the test suite must not write into the repo.
local scratch = os.tmpname()
os.remove(scratch)
local env = mock.install{
  user_dir = scratch,
  page_size = 7,
  config = { ["spellless/data_dir"] = DATA, ["spellless/learn"] = true },
}
-- require after the globals exist, the way librime-lua loads the module
package.loaded["spellless"] = nil
local spellless = require("spellless")

spellless.init(env)
H.ok(env.spellless ~= nil, "the engine came up: " .. table.concat(mock.logged, "; "))

-- This mock stands in for a frontend that reads the document, so say so once.
-- The three document-editing features refuse to act until one has answered --
-- see FRONTEND_READS -- and every suite below that exercises them assumes a
-- capable frontend.  The suite at the end of this file is the other half: it
-- forgets this and checks that nothing is asked of a frontend that has not
-- proved it can answer.
local function frontend_can_read(module)
  -- One translate is enough: document_tail sets the latch when it sees text.
  env.engine.context:set_property("surrounding_text", "ready ")
  mock.translate(module, "a", mock.segment({ "abc" }, 0, 1), env)
  env.engine.context:set_property("surrounding_text", "")
  return module.frontend_reads()
end
H.ok(frontend_can_read(spellless), "and it has seen the document")

H.eq(mock.connections, 1, "one commit notifier connection")
H.eq(env.spellless.cfg.raw_candidate_index, 7, "the literal slot follows menu/page_size")

H.suite("adapter: candidates reach Rime")
-- Mid-sentence, so this is about candidate generation rather than the capital
-- a fresh context would otherwise add.
mock.history:push("exact", "hello")
local seg = mock.segment({ "abc" }, 0, 5)
local cands = mock.translate(spellless, "mathe", seg, env)
H.ok(#cands > 3, ("got %d candidates"):format(#cands))
H.eq(cands[1].start, 0, "candidates span the segment")
H.eq(cands[1]._end, 5)
H.ok(cands[1].quality > cands[2].quality, "quality is strictly descending")
local texts = {}
for i, c in ipairs(cands) do texts[i] = c.text end
H.ok(table.concat(texts, " "):find("mathematics", 1, true) ~= nil,
     "mathematics is offered: " .. table.concat(texts, " ", 1, math.min(#texts, 8)))

H.suite("adapter: the space rides on the word")
-- Rime cannot retract committed text, so a space written before punctuation
-- could never be taken back.  Instead it is never written there: the word
-- carries its own space, and punctuation ends the word without one.
mock.history:clear(); mock.history:push("exact", "hello")
local worded = mock.translate(spellless, "mathe", mock.segment({ "abc" }, 0, 5), env)
H.eq(worded[1].text, "mathematics ", "whatever key commits the word brings the space")
H.ok(worded[2].text:sub(-1) == " ", "every candidate, so a number key works too")

H.suite("adapter: punctuation ends the word without its space")
spellless.processor.init(env)
local ctx0 = env.engine.context
ctx0:set_option("ascii_punct", true)   -- what the shipped schema sets

local function type_punct(ch)
  local before = #mock.committed
  local rc = spellless.processor.func(mock.key(string.byte(ch)), env)
  local written = {}
  for i = before + 1, #mock.committed do written[#written + 1] = mock.committed[i] end
  return rc, table.concat(written)
end

mock.selected = { text = "you " }
ctx0.input = "you"
local rc, written = type_punct(".")
-- With ascii_punct on, librime's punctuator returns kNoop and never makes a
-- candidate, so the processor writes the mark itself.
H.eq(rc, 1, "the processor handles it end to end")
H.eq(written, "you. ", 'giving "you. " -- no space before, one after')
H.eq(ctx0.input, "", "and the composition is finished")

mock.selected = { text = "hello " }
ctx0.input = "hello"
H.eq(select(2, type_punct(",")), "hello, ", "same for a comma")

mock.selected = { text = "see " }
ctx0.input = "see"
H.eq(select(2, type_punct("(")), "see (", "a word keeps its space before an opening bracket")

mock.selected = { text = "well " }
ctx0.input = "well"
H.eq(select(2, type_punct("-")), "well-", "nor a hyphen")

H.suite("adapter: punctuation with nothing composing still gets its space")
ctx0.input = ""
mock.selected = nil
H.eq(select(2, type_punct(".")), ". ", "so a full stop after a committed word spaces the next one")

H.suite("adapter: an ambiguous mark is judged against the text behind it")
-- A lone `$` always reads as opening, so the mark cannot be judged on its own.
mock.history:clear()
mock.history:push("exact", "Let")
mock.history:push("punct", "$")
mock.history:push("raw", "X")
H.eq(select(2, type_punct("$")), "$ ", "the closing dollar of $X$ carries a space")
mock.history:clear()
mock.history:push("exact", "Let ")
H.eq(select(2, type_punct("$")), "$", "the opening one hugs the formula")

H.suite("adapter: punctuation reclaims the automatic space")
-- Only with a frontend that can take a character back, so the schema has to
-- ask for it; see `reclaim_space`.
mock.history:clear(); mock.history:push("exact", "you ")
H.eq(select(2, type_punct(".")), "\8. ", "the full stop asks for the space back")

env.spellless.cfg.reclaim_space = false
mock.history:clear(); mock.history:push("exact", "you ")
H.eq(select(2, type_punct(".")), ". ", "and switched off, the space just stays")
env.spellless.cfg.reclaim_space = true

mock.history:clear(); mock.history:push("exact", "see ")
H.eq(select(2, type_punct("(")), "(", "an opening bracket keeps the space it was given")

mock.history:clear(); mock.history:push("exact", "no")
H.eq(select(2, type_punct("?")), "? ", "and with no space behind, nothing is reclaimed")

mock.history:clear(); mock.history:push("exact", "hello ")
mock.selected = { text = "you " }
ctx0.input = "you"
H.eq(select(2, type_punct(".")), "you. ",
     "a word still being composed gives up its own space instead")
ctx0.input = ""
mock.selected = nil

-- The history records the request, backspace and all; everything that reads it
-- must see the text that request produced.
mock.history:clear(); mock.history:push("exact", "you ")
type_punct(".")
mock.translate(spellless, "zzz", mock.segment({ "abc" }, 0, 3), env)  -- evict the memo
local reclaimed = mock.translate(spellless, "mathe", mock.segment({ "abc" }, 0, 5), env)
H.eq(reclaimed[1].text, "Mathematics ", "so the reclaimed full stop still ends a sentence")

H.suite("adapter: a terminal never has text taken back out of it")
-- The three document-editing features all work by removing characters the
-- application has already been given, and a terminal has already forwarded
-- them down the pty.  The frontend's replacement then arrives as *more* input
-- and the line duplicates -- which is what happens in VS Code's integrated
-- terminal, where this was found.
do
  local function reclaims(app)
    ctx0:set_property("client_app", app)
    mock.history:clear(); mock.history:push("exact", "you ")
    local written = select(2, type_punct("."))
    return written:find("\8", 1, true) ~= nil
  end
  H.ok(reclaims("notepad.exe"), "an ordinary text field still gets it")
  H.ok(not reclaims("code.exe"), "a suspect application with no readable document does not")
  H.ok(not reclaims("WindowsTerminal.exe"), "and the match ignores case")
  H.ok(reclaims(""), "an unknown application is given the benefit of the doubt")

  -- Being able to *read* the document does not mean it can be edited, and the
  -- distinction cost an afternoon: VS Code's terminal reads back perfectly
  -- well -- it just returns the hidden textarea's buffer rather than the
  -- visible line, and editing that replays it.  So a readable document buys
  -- the application nothing here.
  ctx0:set_property("surrounding_text", "you ")
  H.ok(not reclaims("code.exe"),
       "a readable document does not make a suspect application safe")
  ctx0:set_property("surrounding_text", "")

  -- The option is the per-application escape hatch, for anything the shipped
  -- list has not heard of: Weasel's app_options can set it by name.
  ctx0:set_property("client_app", "notepad.exe")
  ctx0:set_option("commit_only", true)
  mock.history:clear(); mock.history:push("exact", "you ")
  H.ok(not (select(2, type_punct(".")):find("\8", 1, true)),
       "and commit_only switches it off without touching the list")
  ctx0:set_option("commit_only", false)
  ctx0:set_property("client_app", "")
end

env.spellless.cfg.reclaim_space = false
mock.history:clear()

H.suite("adapter: a multi-segment composition keeps every character")
-- get_selected_candidate returns only the last segment.  Handing the key on
-- with kNoop looked safe and was not: express_editor then commits just the
-- segment the caret sits in, and the rest of the input is lost.
mock.segments = 2
mock.selected = { text = "world " }
ctx0.input = "helloworld"
local rc2, written2 = type_punct("!")
H.eq(rc2, 1, "the processor handles it rather than passing it on")
H.eq(written2, "helloworld! ", "committing the whole input, not one segment of it")
H.eq(ctx0.input, "", "and the composition is finished")
mock.segments = 1
ctx0.input = ""

H.suite("adapter: punctuation carries the space that follows it")
local function filtered(text)
  return mock.filter_candidates(spellless, { mock.candidate(text) }, env)[1].text
end
spellless.filter.init(env)
H.eq(filtered("."), ". ", "a full stop is followed by a space")
H.eq(filtered("1.5"), "1.5", "a number separator is left alone")
H.eq(filtered(","), ", ")
H.eq(filtered("?"), "? ")
H.eq(filtered(")"), ") ")
H.eq(filtered("("), "(", "an opening bracket is not")
H.eq(filtered("-"), "-", "nor a hyphen")
H.eq(filtered("\u{3002}"), "\u{3002}", "nor CJK punctuation, which spaces itself")

H.suite("adapter: capitals at the start of a sentence")
local ctx = env.engine.context
local function first_for(input)
  ctx:set_property("spellless_sentence", "")
  local out = mock.translate(spellless, input, mock.segment({ "abc" }, 0, #input), env)
  -- the trailing space rides on every word; this suite is about the capital
  return (out[1].text:gsub(" $", ""))
end

mock.history:clear()
H.eq(first_for("mathe"), "Mathematics", "a context nobody has typed in yet")

mock.history:push("exact", "hello")
H.eq(first_for("mathe"), "mathematics", "mid-sentence")

mock.history:clear(); mock.history:push("punct", ".")
H.eq(first_for("mathe"), "Mathematics", "after a full stop")

mock.history:clear(); mock.history:push("punct", "?")
H.eq(first_for("mathe"), "Mathematics", "after a question mark")

mock.history:clear(); mock.history:push("exact", "hello,")
H.eq(first_for("mathe"), "mathematics", "a comma does not end a sentence")

mock.history:clear(); mock.history:push("exact", " e.g.")
H.eq(first_for("mathe"), "mathematics",
     "a known abbreviation is not the end of a sentence")

mock.history:clear(); mock.history:push("punct", ".")
ctx:set_property("spellless_sentence", "")
local caps = mock.translate(spellless, "kubectl", mock.segment({ "abc" }, 0, 7), env)
H.eq(caps[#caps].text:gsub(" $", ""), "kubectl",
     "but the literal candidate is never capitalised")

H.suite("adapter: telling a new line from a correction")
-- Rime clears its commit history for Return and for Backspace alike, so the
-- processor has to record which one happened.
spellless.processor.init(env)
ctx.input = ""
mock.history:clear()

spellless.processor.func(mock.key(0xff0d), env)          -- Return on empty input
H.ok(ctx:get_property("spellless_sentence"):match("^1:"), "Return notes a new line")
local out = mock.translate(spellless, "mathe", mock.segment({ "abc" }, 0, 5), env)
H.eq((out[1].text:gsub(" $", "")), "Mathematics", "so the next word is capitalised")

ctx.input = ""
spellless.processor.func(mock.key(XK_BackSpace), env)
H.ok(ctx:get_property("spellless_sentence"):match("^0:"), "Backspace notes a correction")
out = mock.translate(spellless, "mathe", mock.segment({ "abc" }, 0, 5), env)
H.eq((out[1].text:gsub(" $", "")), "mathematics", "so the next word is not")

mock.commit_text = "hello"
mock.commit_handler(ctx)
H.eq(ctx:get_property("spellless_sentence"), "", "a commit makes the note stale again")
mock.history:clear()

H.suite("adapter: the commit tail restores what record boundaries threw away")
-- Punctuation is committed on its own, so the newest record is often a bare
-- quote or dollar with nothing around it to say whether it opens or closes.
mock.history:clear()
mock.history:push("exact", "no.")
mock.history:push("punct", "\"")
local out = mock.translate(spellless, "the", mock.segment({ "abc" }, 0, 3), env)
H.eq(out[1].text, "The ", 'He said "no." The ... still gets its capital')

mock.history:clear()
mock.history:push("thru", " ")
mock.history:push("punct", "$")
out = mock.translate(spellless, "x", mock.segment({ "abc" }, 0, 1), env)
-- The word carries a space; typing the closing $ takes it back off again,
-- which is what the punctuation branch above is for.
H.eq(out[1].text, "x ", "an opening dollar hugs the formula")

mock.history:clear()
mock.history:push("exact", "Let")
mock.history:push("punct", "$")
mock.history:push("raw", "X")
mock.history:push("punct", "$")
out = mock.translate(spellless, "be", mock.segment({ "abc" }, 0, 2), env)
H.eq(out[1].text, "be ", "and the word carries its own trailing space")

H.suite("adapter: a LaTeX control sequence is left alone")
mock.history:clear()
mock.history:push("punct", "\\")
out = mock.translate(spellless, "citep", mock.segment({ "abc" }, 0, 5), env)
H.eq(out[1].text, "citep ", "\\citep is not corrected to \\cited")
H.ok(out[1].comment ~= nil, "and it is still a normal candidate")

H.suite("adapter: segments it must not touch")
H.eq(#mock.translate(spellless, "!!", mock.segment({ "punct" }), env), 0,
     "punctuation is left to punct_translator")
local ident = mock.translate(spellless, "sqlite3", mock.segment({ "ident" }, 0, 7), env)
H.eq(#ident, 1, "an identifier gets exactly its own text back")
H.eq(ident[1].text:gsub(" $", ""), "sqlite3")

H.suite("adapter: repeated queries are answered from the cache")
local a = mock.translate(spellless, "recieve", mock.segment({ "abc" }, 0, 7), env)
local b = mock.translate(spellless, "recieve", mock.segment({ "abc" }, 0, 7), env)
H.eq(#a, #b, "same number of candidates")
H.eq(a[1].text, b[1].text, "same first candidate")

H.suite("adapter: committing teaches the engine")
env.spellless.user.path = personal
mock.commit_text = "diffeomorphism"
mock.commit_handler(env.engine.context)
H.eq(env.spellless.user:count("diffeomorphism"), 1, "the commit was counted")
mock.commit_text = "!"
mock.commit_handler(env.engine.context)
H.eq(env.spellless.user:count("!"), 0, "punctuation is not vocabulary")

H.suite("adapter: picking up a word already in the document")
-- Delete the space after "so", type "oner", and the candidates should be for
-- "sooner".  Only ever from the document: absorbing means deleting, and Rime's
-- own history is cleared by the very Backspace that creates this situation.
spellless.absorb.init(env)
local ctxA = env.engine.context
env.spellless.cfg.absorb_fragment = true

ctxA.input = ""
ctxA:set_property("surrounding_text", "I think so")
local before_absorb = #mock.committed
H.eq(spellless.absorb.func(mock.key(string.byte("o")), env), 2,
     "the letter still goes on to the speller")
H.eq(mock.committed[#mock.committed], "\8\8", "the fragment is taken out of the document")
H.eq(ctxA.input, "so", "and pushed into the composition")

-- Nothing to pick up.
ctxA.input = ""
ctxA:set_property("surrounding_text", "I think so ")
local n = #mock.committed
H.eq(spellless.absorb.func(mock.key(string.byte("o")), env), 2, "passed through")
H.eq(#mock.committed, n, "a space behind means a new word, nothing to absorb")
H.eq(ctxA.input, "", "and nothing pushed")

-- Without the document there is nothing to absorb from, however tempting the
-- commit history looks.
ctxA:set_property("surrounding_text", "")
mock.history:clear(); mock.history:push("exact", "so")
n = #mock.committed
H.eq(spellless.absorb.func(mock.key(string.byte("o")), env), 2, "passed through")
H.eq(#mock.committed, n, "the commit history is not good enough to delete on")
env.spellless.cfg.absorb_fragment = false
ctxA:set_property("surrounding_text", "")
mock.history:clear()

H.suite("adapter: Backspace twice deletes the whole word")
env.spellless.cfg.word_backspace = true
ctxA.input = ""
ctxA:set_property("surrounding_text", "I think sooner")
n = #mock.committed
spellless.absorb.func(mock.key(XK_BackSpace), env)
H.eq(spellless.processor.func(mock.key(XK_BackSpace), env), 2, "the first one is ordinary")
H.eq(#mock.committed, n, "nothing committed")
spellless.absorb.func(mock.key(XK_BackSpace), env)
H.eq(spellless.processor.func(mock.key(XK_BackSpace), env), 2,
     "the second passes the key through as well")
H.eq(mock.committed[#mock.committed], string.rep("\8", 5),
     "having asked for all but the last character of the word")
-- The key supplies that last one, so a frontend that ignores the request
-- still deletes a character.  Swallowing the keystroke instead made Backspace
-- work every other press wherever the request went unanswered.
ctxA:set_property("surrounding_text", "I think a")
spellless.absorb.func(mock.key(XK_BackSpace), env)
spellless.processor.func(mock.key(XK_BackSpace), env)
n = #mock.committed
spellless.absorb.func(mock.key(XK_BackSpace), env)
H.eq(spellless.processor.func(mock.key(XK_BackSpace), env), 2, "a one-letter word too")
H.eq(#mock.committed, n, "which asks for nothing and lets the key do it all")

-- A key in between makes the next Backspace ordinary again.
ctxA:set_property("surrounding_text", "I think sooner")
spellless.absorb.func(mock.key(XK_BackSpace), env)
spellless.processor.func(mock.key(XK_BackSpace), env)
spellless.absorb.func(mock.key(string.byte("h")), env)   -- a letter, which the
spellless.processor.func(mock.key(string.byte("!")), env) -- speller would eat
n = #mock.committed
spellless.absorb.func(mock.key(XK_BackSpace), env)
H.eq(spellless.processor.func(mock.key(XK_BackSpace), env), 2,
     "not a repeat, so ordinary")
H.eq(#mock.committed, n, "nothing deleted")
env.spellless.cfg.word_backspace = false
ctxA:set_property("surrounding_text", "")
mock.history:clear()

H.suite("adapter: the space bar asks before committing a misspelling")
-- The space bar picks the word and separates it from the next, and the second
-- job is so automatic that the first happens unnoticed.  Fine over a real
-- word; exactly wrong over one the dictionary does not have.
local ctxS = env.engine.context
env.spellless.cfg.confirm_literal = true
ctxS.input = "qwertyx"
ctxS:set_property("spellless_literal", "")
mock.selected = { text = "qwertyx ", type = "raw" }
local n0 = #mock.committed
H.eq(spellless.processor.func(mock.key(0x20), env), 1, "the first space is swallowed")
H.eq(#mock.committed, n0, "nothing committed")
H.eq(ctxS.input, "qwertyx", "and the word is still there to be corrected")
H.eq(spellless.processor.func(mock.key(0x20), env), 2,
     "the second space goes through to Rime, which commits as usual")

-- A real word is never held up.
ctxS:set_property("spellless_literal", "")
mock.selected = { text = "mathematics ", type = "exact" }
H.eq(spellless.processor.func(mock.key(0x20), env), 2,
     "a dictionary word commits on the first space")

-- Typing something else cancels it: the reason to pause was that it was wrong.
ctxS:set_property("spellless_literal", "")
mock.selected = { text = "qwertyx ", type = "raw" }
spellless.processor.func(mock.key(0x20), env)
spellless.absorb.func(mock.key(string.byte("a")), env)
H.eq(ctxS:get_property("spellless_literal"), "", "a letter cancels the pending ask")
env.spellless.cfg.confirm_literal = false
ctxS.input = ""
mock.selected = nil

H.suite("adapter: Control+Shift+D forgets what was learned by accident")
local XK_D_ = string.byte("d")
env.spellless.user:set("wrold", 5, "wrold")
H.eq(env.spellless.user:count("wrold"), 5, "a typo has been learned")

mock.selected = { text = "wrold " }
env.engine.context.input = "wrold"
H.eq(spellless.processor.func(mock.key(XK_D_, { ctrl = true, shift = true }), env), 1,
     "the key is handled")
H.eq(env.spellless.user:count("wrold"), 0, "and the highlighted candidate is gone")
H.ok((env.engine.context.refreshed or 0) > 0,
     "the menu is re-queried, so the reordering shows immediately")

-- Shift+Delete and Control+Delete do the same thing: Rime's own convention for
-- dropping a candidate, and reachable when an application eats Control+Shift+D.
env.spellless.user:set("teh2", 4)
mock.selected = { text = "teh2 " }
env.engine.context.input = "teh2"
H.eq(spellless.processor.func(mock.key(0xffff, { shift = true }), env), 1,
     "Shift+Delete is handled")
H.eq(env.spellless.user:count("teh2"), 0, "and forgets too")
H.ok(env.spellless.user:surface("wrold") == nil, "spelling and all")

-- With nothing composing it forgets the last commit, for when you notice one
-- keystroke too late.
mock.selected = nil
env.engine.context.input = ""
env.spellless.user:set("teh", 3)
mock.history:clear(); mock.history:push("exact", "teh ")
H.eq(spellless.processor.func(mock.key(XK_D_, { ctrl = true, shift = true }), env), 1,
     "handled with nothing composing")
H.eq(env.spellless.user:count("teh"), 0, "the last committed word is forgotten")

-- Forgetting a word the corpus knows must not remove it from the dictionary.
env.spellless.user:set("mathematics", 9)
mock.history:clear(); mock.history:push("exact", "mathematics ")
spellless.processor.func(mock.key(XK_D_, { ctrl = true, shift = true }), env)
H.eq(env.spellless.user:count("mathematics"), 0, "the personal count goes")
local still = mock.translate(spellless, "mathematics", mock.segment({ "abc" }, 0, 11), env)
H.eq(still[1].text, "mathematics ", "but the word is still an English word")
mock.history:clear()

H.suite("adapter: Shift+Return commits the word and passes the newline on")
-- It is the soft newline in Slack and Zulip.  express_editor looked like it
-- had no binding for it, but librime falls back from Shift to Control, so it
-- resolved to Control+Return -- "commit script text" -- which swallowed the
-- newline and bypassed both the commit history and learning.
mock.history:clear()
mock.history:push("exact", "previous")
env.engine.context.input = "hello"
local before_commits = #mock.committed
H.eq(spellless.processor.func(mock.key(XK_Return, { shift = true }), env), 2,
     "the key still reaches the application")
H.eq(mock.committed[#mock.committed], "hello", "but the word is committed first")
H.eq(#mock.committed, before_commits + 1, "exactly once")
H.eq(env.engine.context.input, "", "and the composition is finished")

H.suite("adapter: keypad Enter is Enter")
mock.history:clear()
env.engine.context.input = "hello"
H.eq(spellless.processor.func(mock.key(0xff8d), env), 1, "handled, not passed on")
H.eq(mock.committed[#mock.committed], "hello ", "committing what was typed, spaced")
H.eq(env.engine.context.input, "", "and the composition is finished")

H.suite("adapter: Return commits what was typed and separates it from the next")
-- The letters are exactly the ones typed -- that is the promise -- and the
-- space is the same one every other commit carries, so the word after it does
-- not have to be un-run-together by hand.
mock.history:clear()
env.engine.context.input = "kubectl"
local counted = env.spellless.user:count("kubectl")
H.eq(spellless.processor.func(mock.key(XK_Return), env), 1, "handled here, not by the editor")
H.eq(mock.committed[#mock.committed], "kubectl ", "exactly what was typed, plus the space")
H.eq(env.engine.context.input, "", "and the composition is finished")
H.eq(env.spellless.user:count("kubectl"), counted + 1,
     "counted, because our own commit never reaches the notifier")
-- A refusal to choose between readings is not a choice: nothing is recorded
-- about what this input meant.
H.eq(env.spellless.user:choices_for("kubectl"), nil, "and no input-to-word pair is stored")

H.suite("adapter: Return on a candidate you arrowed to commits that candidate")
-- Having disagreed with the ranking by moving the highlight, Return is the key
-- under the finger; committing the letters that sent you looking would throw
-- the choice away.
mock.history:clear()
env.engine.context.input = "recieve"
mock.selected = { text = "receive ", type = "typo" }
mock.selected_index = 2
local before = #mock.committed
H.eq(spellless.processor.func(mock.key(XK_Return), env), 1, "handled here")
H.eq(mock.committed[#mock.committed], "receive ", "the highlighted candidate, with its space")
H.eq(#mock.committed, before + 1, "committed once")
H.eq(env.engine.context.get_property(env.engine.context, "spellless_picked"), "1",
     "and counted as the deliberate choice it is")
H.eq(env.spellless.user:choices_for("recieve")[1].text, "receive",
     "so the input-to-word pair is stored")

H.suite("adapter: on the first candidate Return is still the literal escape")
-- The promise survives the feature above: a fresh composition and one arrowed
-- back to the top are the same thing, and both commit what was typed.
mock.history:clear()
env.engine.context.input = "kubectl"
mock.selected = { text = "kubectl ", type = "raw" }
mock.selected_index = 0
H.eq(spellless.processor.func(mock.key(XK_Return), env), 1, "handled here")
H.eq(mock.committed[#mock.committed], "kubectl ", "exactly what was typed")
H.eq(env.spellless.user:choices_for("kubectl"), nil, "and no choice is recorded")
mock.selected = nil
mock.selected_index = 0

H.suite("adapter: Return without the automatic space is express_editor's again")
env.spellless.cfg.enter_space = false
mock.history:clear()
env.engine.context.input = "kubectl"
local before = #mock.committed
H.eq(spellless.processor.func(mock.key(XK_Return), env), 2, "passed on")
H.eq(#mock.committed, before, "committing nothing itself")
H.eq(env.engine.context.input, "kubectl", "and leaving the composition alone")
env.spellless.cfg.enter_space = true

H.suite("adapter: a number is not split by its own spacing")
-- "3" then "." commits ". " because nothing yet says a digit is coming.  The
-- digit that follows says so, and takes the space back.
env.spellless.cfg.reclaim_space = true
mock.history:clear(); mock.history:push("raw", "3"); mock.history:push("raw", ". ")
env.engine.context.input = ""
local n = #mock.committed
H.eq(spellless.processor.func(mock.key(string.byte("1")), env), 1, "handled")
H.eq(mock.committed[#mock.committed], "\0081", "the space is reclaimed before the digit")
mock.history:clear(); mock.history:push("exact", "hello. ")
H.eq(spellless.processor.func(mock.key(string.byte("1")), env), 2,
     "but a digit after a real sentence end is left alone")
env.spellless.cfg.reclaim_space = false
env.engine.context.input = ""

H.suite("adapter: a dollar hands the keyboard over, and takes it back")
-- Both halves of the handover are for an editor, so they ask which one is in
-- front of the caret before they do anything at all.
env.engine.context:set_property("client_app", "code.exe")
-- Maths is not English.  `$` opens it, and everything until the closing `$`
-- belongs to the typist.
spellless.handover.init(env)
local ctx = env.engine.context
ctx:set_option("ascii_mode", false)
ctx:set_property("spellless_delimiter", "")
mock.history:clear(); mock.history:push("exact", "let ")
mock.selected = nil
ctx.input = ""
H.eq(spellless.processor.func(mock.key(string.byte("$")), env), 1, "the dollar is handled")
H.eq(mock.committed[#mock.committed], "$", "written where it was typed, opening so unspaced")
H.ok(ctx:get_option("ascii_mode"), "and ASCII mode is on")
H.eq(ctx:get_property("spellless_delimiter"), "$", "with the delimiter that opened it remembered")

-- In ASCII mode nothing behind ascii_composer runs, so this gear is in front.
H.eq(spellless.handover.func(mock.key(string.byte("x")), env), 2, "ordinary keys pass through")
H.eq(spellless.handover.func(mock.key(string.byte("$")), env), 1, "the closing dollar is taken")
H.eq(mock.committed[#mock.committed], "$ ", "and carries the space the next word needs")
H.ok(not ctx:get_option("ascii_mode"), "ASCII mode is off again")
H.eq(ctx:get_property("spellless_delimiter"), "", "and nothing is left open")

H.suite("adapter: an editor snippet trigger is handed straight to the editor")
-- "xdm" means a display maths block to HyperSnips and nothing to English.  It
-- has to arrive in the document as those three letters -- no space, no capital,
-- no candidate list -- or the expansion never fires.
--
-- The last letter is not committed with the rest.  HyperSnips expands an
-- automatic snippet from a document-change event and drops any change that is
-- not exactly one character long -- a guard against expanding on paste, which
-- a whole-word commit fails.  It only inspects the change that just arrived,
-- though, so the prefix is committed and the final key is *rejected*: librime
-- passes a rejected key to the application, where it lands as a genuine
-- one-character keystroke with the whole trigger behind it.
--
-- Committing the letters one at a time instead does not work and the reason is
-- worth keeping: librime concatenates every commit of a single keystroke into
-- one string (`commit_text_ += ...`, service.cc), so four calls and one call
-- reach the document identically.
env.spellless.snippets = require("spellless.snippets").parse(
    "xdm ascii display maths\nxthm theorem\n")
ctx:set_option("ascii_mode", false)
ctx.input = "xd"
H.eq(spellless.handover.func(mock.key(string.byte("m")), env), 0,
     "the last key is rejected, so the editor sees a keystroke")
H.eq(mock.committed[#mock.committed], "xd", "and only the prefix is committed")
H.eq(ctx.input, "", "the composition is finished")
H.ok(ctx:get_option("ascii_mode"), "and the maths that follows is typed, not guessed at")

-- A theorem is opened the same way and hands nothing over: what goes inside it
-- is English, which is the matcher's whole subject.
ctx:set_option("ascii_mode", false)
ctx.input = "xth"
H.eq(spellless.handover.func(mock.key(string.byte("m")), env), 0, "the trigger is taken")
H.eq(mock.committed[#mock.committed], "xth", "prefix committed, last letter passed through")
H.ok(not ctx:get_option("ascii_mode"), "but the matcher stays on for the prose inside")

-- The whole composition, or nothing: a trigger inside a word is a word.
ctx:set_option("ascii_mode", false)
ctx.input = "mixd"
local untouched = #mock.committed
H.eq(spellless.handover.func(mock.key(string.byte("m")), env), 2, "mixdm is not a trigger")
H.eq(#mock.committed, untouched, "so nothing is committed")
H.ok(not ctx:get_option("ascii_mode"), "and the mode is left alone")
ctx.input = ""

H.suite("adapter: a dollar in an ASCII run nobody opened is a dollar")
-- Tapping Shift into ASCII mode to type `$PATH` in a terminal must not be
-- flipped back out by the dollar sign itself.
ctx:set_option("ascii_mode", true)
ctx:set_property("spellless_delimiter", "")
local before_dollar = #mock.committed
H.eq(spellless.handover.func(mock.key(string.byte("$")), env), 2, "passed through")
H.eq(#mock.committed, before_dollar, "committing nothing")
H.ok(ctx:get_option("ascii_mode"), "and staying in ASCII mode")

H.suite("adapter: a run left by another route is not closed later")
-- Shift, F4 and Control+Shift+A all leave ASCII mode without a closing dollar.
ctx:set_option("ascii_mode", false)
ctx:set_property("spellless_delimiter", "$")
spellless.handover.func(mock.key(string.byte("a")), env)
H.eq(ctx:get_property("spellless_delimiter"), "", "the stale delimiter is forgotten")
ctx:set_option("ascii_mode", false)
ctx.input = ""

H.suite("adapter: nothing is handed over outside an editor")
-- `$5` in a chat window is a price, and a snippet trigger is meaningless where
-- nothing expands it.
ctx:set_property("client_app", "chrome.exe")
ctx:set_option("ascii_mode", false)
ctx.input = "xd"
local elsewhere = #mock.committed
H.eq(spellless.handover.func(mock.key(string.byte("m")), env), 2, "the trigger is just letters")
H.eq(ctx.input, "xd", "left to the speller")
-- The opening dollar has to be refused in the same places as the closing one.
-- Gating only the way back left a chat window one keystroke from ASCII mode
-- and no keystroke back out of it.
mock.history:clear(); mock.history:push("exact", "costs ")
ctx.input = ""
H.eq(spellless.processor.func(mock.key(string.byte("$")), env), 1, "the dollar is still written")
H.ok(not ctx:get_option("ascii_mode"), "but it opens nothing")
ctx:set_option("ascii_mode", true)
ctx:set_property("spellless_delimiter", "$")
H.eq(spellless.handover.func(mock.key(string.byte("$")), env), 2, "and closes nothing")
H.eq(#mock.committed, elsewhere + 1, "only the dollar itself was committed")
ctx:set_property("client_app", "code.exe")
ctx:set_property("spellless_delimiter", "")
ctx:set_option("ascii_mode", false)
ctx.input = ""

H.suite("adapter: maths is opened where maths is written, snippets where they expand")
-- Typora has no snippet engine and every `$` in it is still maths, so the two
-- lists are asked separately.
ctx:set_property("client_app", "typora.exe")
mock.history:clear(); mock.history:push("exact", "let ")
H.eq(spellless.processor.func(mock.key(string.byte("$")), env), 1, "the dollar is handled")
H.ok(ctx:get_option("ascii_mode"), "and opens maths in Typora too")
H.eq(spellless.handover.func(mock.key(string.byte("$")), env), 1, "the closing one is taken")
H.ok(not ctx:get_option("ascii_mode"), "and hands the keyboard back")
ctx.input = "xd"
H.eq(spellless.handover.func(mock.key(string.byte("m")), env), 2,
     "while a snippet trigger is left alone, having nothing there to expand it")
ctx:set_property("client_app", "code.exe")
ctx.input = ""

H.suite("adapter: Control+Shift+A escapes mid-word")
-- key_binder's `toggle: ascii_mode` leaves an open composition alone and then
-- appends plain ASCII to it, so this is handled in the processor instead.
mock.history:clear()
env.engine.context.input = "kube"
H.eq(spellless.processor.func(mock.key(0x41, { ctrl = true, shift = true }), env), 1,
     "handled")
H.eq(mock.committed[#mock.committed], "kube", "committing what was typed, literally")
H.eq(env.engine.context.input, "", "and clearing the composition")
H.eq(env.engine.context:get_option("ascii_mode"), true, "before switching to plain typing")
H.eq(spellless.processor.func(mock.key(0x41, { ctrl = true, shift = true }), env), 1)
H.eq(env.engine.context:get_option("ascii_mode"), false, "and it toggles back")

H.suite("adapter: the sentence note does not outlive its keystroke")
-- Tap out to plain typing, write a sentence, tap back: the note from before
-- the excursion must not override what the commit history now says.
mock.history:clear()
env.engine.context.input = ""
spellless.processor.func(mock.key(XK_BackSpace), env)          -- "not a sentence start"
mock.history:push("thru", "\\citep{Foo}. ")                     -- typed in ASCII mode
local resumed = mock.translate(spellless, "teh", mock.segment({ "abc" }, 0, 3), env)
H.eq(resumed[1].text, "The ", "the newer history wins over the stale note")
mock.history:clear()
env.engine.context:set_property("spellless_sentence", "")

H.suite("adapter: leaving for plain typing forgets the sentence note")
-- ASCII-mode keystrokes never reach this processor, and a Return typed there
-- clears the history back to the size the note was stamped with -- which made
-- a stale note authoritative again.
mock.history:clear()
env.engine.context.input = ""
spellless.processor.func(mock.key(XK_BackSpace), env)
H.ok(env.engine.context:get_property("spellless_sentence"):match("^0:"), "note written")
spellless.processor.func(mock.key(0xffe1), env)   -- a Shift tap
H.eq(env.engine.context:get_property("spellless_sentence"), "", "and dropped on the way out")

H.suite("adapter: learn:false switches off learning, not the sentence note")
local quiet = mock.install{
  user_dir = scratch,
  page_size = 7,
  config = { ["spellless/data_dir"] = DATA, ["spellless/learn"] = false },
}
package.loaded["spellless"] = nil
local mute = require("spellless")
mute.init(quiet)
H.eq(mock.connections, 1, "the commit notifier is still connected")
quiet.engine.context:set_property("spellless_sentence", "1")
mock.commit_text = "unlearnable"
mock.commit_handler(quiet.engine.context)
H.eq(quiet.engine.context:get_property("spellless_sentence"), "",
     "so a commit still clears the note")
H.eq(quiet.spellless.user:count("unlearnable"), 0, "and nothing was learned")
package.loaded["spellless"] = nil
spellless = require("spellless")
-- A fresh module has a fresh latch, and every suite below this line assumes a
-- frontend that reads the document.
frontend_can_read(spellless)

H.suite("adapter: fini releases the connection")
spellless.fini(env)
H.eq(mock.connections, 0, "disconnected")

H.suite("adapter: a missing data directory is reported, not fatal")
local broken = mock.install{ user_dir = "/nonexistent", shared_dir = "/nonexistent" }
package.loaded["spellless"] = nil
local fresh = require("spellless")
fresh.init(broken)
H.eq(broken.spellless, nil, "no engine")
H.ok(#mock.logged > 0 and mock.logged[1]:find("spellless"), "and it said why")
H.eq(#mock.translate(fresh, "mathe", mock.segment({ "abc" }), broken), 0,
     "and translating is a no-op rather than an error")

H.suite("schema: the way out is still wired up")
-- Not behaviour we can execute here -- it is pure Rime configuration -- but it
-- is the escape hatch, and a silent edit that turned it off would be found by
-- nobody.  Read the values back out of the shipped schema.
do
  local text = assert(io.open(_G.SPELLLESS_ROOT .. "/rime/spellless.schema.yaml")):read("a")
  local block = text:match("switch_key:\n(.-)\n%S")
  H.ok(block ~= nil, "the schema has an ascii_composer/switch_key block")
  for key, want in pairs{ Shift_L = "commit_code", Shift_R = "commit_code" } do
    H.eq(block and block:match(key .. ":%s*([%w_]+)"), want,
         ("a tap on %s leaves Spellless"):format(key))
  end
  H.ok(text:find("Control%+Shift%+A", 1) ~= nil, "and the deliberate binding is there too")
  -- express_editor must keep Return, or "commit exactly what I typed" goes away
  H.ok(text:find("express_editor", 1, true) ~= nil, "express_editor is still the editor")
end

H.suite("schema: punctuation keys are not bound to paging")
-- Rime's default preset gives minus/equal/comma/period to Page_Up/Page_Down.
-- key_binder runs before our processor, so while candidates are showing those
-- keys never arrive and the punctuation cannot be typed at all -- which is
-- exactly what happened the first time Spellless ran on stock Weasel data.
do
  local fh = assert(io.open(_G.SPELLLESS_ROOT .. "/rime/spellless.schema.yaml"))
  local text = fh:read("a")
  fh:close()
  local bindings = text:match("\nkey_binder:\n(.-)\n%S") or ""
  H.ok(bindings:find("bindings:", 1, true) ~= nil,
       "the schema states its own bindings rather than taking the preset's")
  for _, key in ipairs({ "minus", "equal", "comma", "period" }) do
    H.ok(not bindings:find("accept: " .. key, 1, true),
         key .. " is punctuation here, not a paging key")
  end
end

H.suite("adapter: the schema and config.lua have not drifted apart")
-- Every key the shipped schema sets under `spellless:` must exist in
-- config.lua, otherwise it is silently ignored at runtime.  A crude line
-- reader is enough: this is our own file, in a format we control.
do
  local defaults = require("spellless.config").defaults
  -- read separately by the adapter, so it is legitimately not a config key
  local extra = { data_dir = true }
  local fh = assert(io.open(_G.SPELLLESS_ROOT .. "/rime/spellless.schema.yaml"))
  local inside, checked = false, 0
  for line in fh:lines() do
    if line:match("^spellless:%s*$") then
      inside = true
    elseif inside then
      if line:match("^%S") then
        inside = false
      else
        local key = line:match("^  ([%w_]+):")
        if key then
          checked = checked + 1
          H.ok(defaults[key] ~= nil or extra[key],
               ("schema sets spellless/%s, which config.lua does not define"):format(key))
        end
      end
    end
  end
  fh:close()
  H.ok(checked > 0, "found the spellless block in the schema")
end

os.remove(personal)

H.suite("adapter: only a number key is a choice")
-- Two things have to be true before a correction is recorded, and the second
-- one matters more than it looks.  A candidate must have been confirmed --
-- Return commits the raw input and librime clears the non-confirmed
-- composition to do it, so get_selected_candidate is nil exactly then.  And it
-- must have been taken by its *number*: at speed the space bar goes on muscle
-- memory and whatever is first goes in, so counting that teaches the list to
-- insist on its own first guess.
do
  -- Its own environment: mock.install rebinds the commit handler, so the one
  -- left over from an earlier suite belongs to an earlier engine.
  local scratch = os.tmpname()
  os.remove(scratch)
  local own = mock.install{
    user_dir = scratch, page_size = 7,
    config = { ["spellless/data_dir"] = DATA, ["spellless/learn"] = true },
  }
  package.loaded["spellless"] = nil
  local sp = require("spellless")
  sp.init(own)
  local ctx = own.engine.context
  local store = own.spellless.user

  H.eq(store:choices_for("mathe"), nil, "nothing remembered for this input yet")

  ctx.input = "mathe"
  mock.selected = nil                        -- Return: no candidate confirmed
  mock.commit_text = "mathe"
  mock.commit_handler(ctx)
  H.eq(store:choices_for("mathe"), nil,
       "committing the raw input records no correction")

  -- The space bar: a candidate is confirmed, but nobody aimed at it.
  mock.selected = { text = "mathematics " }
  mock.commit_text = "mathematics "
  sp.absorb.func(mock.key(0x20), own)
  mock.commit_handler(ctx)
  H.eq(store:choices_for("mathe"), nil,
       "and neither does the space bar taking whatever was first")

  -- A number key, which is aimed.
  ctx.input = "mathe"
  sp.absorb.func(mock.key(0x32), own)
  mock.commit_handler(ctx)
  local got = store:choices_for("mathe")
  H.ok(got ~= nil, "taking a candidate by its number does")
  if got then
    H.eq(got[1].text, "mathematics", "and the trailing space is not part of it")
    H.eq(got[1].count, 1, "counted once, which is not yet enough to lead")
  end

  -- A digit past the end of the page selects nothing, so whatever the frontend
  -- does with it is not a choice of the line that happened to be highlighted.
  ctx.input = "mathe"
  mock.selected = { text = "mathematical " }
  mock.commit_text = "mathematical "
  sp.absorb.func(mock.key(0x38), own)          -- "8", with a page of seven
  mock.commit_handler(ctx)
  local after = store:choices_for("mathe")
  H.eq(#after, 1, "a digit past the end of the page is not aimed at anything")

  sp.fini(own)
  mock.selected, mock.commit_text = nil, nil
  -- Put the module and the environment the rest of the file uses back.
  package.loaded["spellless"] = spellless
end

H.suite("adapter: the person typing can overrule the list")
-- The list cannot tell VS Code's editor from VS Code's terminal.  Nothing
-- reaching the matcher can, so the switch exists to let a human say which.
do
  env.spellless.cfg.reclaim_space = true
  ctx0:set_property("client_app", "code.exe")
  local function asks()
    mock.history:clear(); mock.history:push("exact", "you ")
    return select(2, type_punct(".")):find("\8", 1, true) ~= nil
  end
  H.ok(not asks(), "refused by the list to begin with")
  ctx0:set_option("edit_document", true)
  H.ok(asks(), "and allowed when the switch says so")
  ctx0:set_option("edit_document", false)
  H.ok(not asks(), "and refused again when it is turned back off")

  -- commit_only is the flat refusal and outranks it, so an application that
  -- says "never" cannot be talked round by a switch left on by accident.
  ctx0:set_option("edit_document", true)
  ctx0:set_option("commit_only", true)
  H.ok(not asks(), "commit_only still wins")
  ctx0:set_option("commit_only", false)
  ctx0:set_option("edit_document", false)
  ctx0:set_property("client_app", "")
  env.spellless.cfg.reclaim_space = false
  mock.history:clear()
end

H.suite("adapter: the version query reports what the matcher can actually see")
-- The three fields behind this line are gathered only for `zzver`, because
-- they cost an application-name lookup and a list scan and would otherwise be
-- paid on every keystroke to answer a question asked once a session. That
-- makes them exactly the kind of thing that can stop being gathered at all
-- without any other test noticing.
do
  local function version_lines(app)
    ctx0:set_property("client_app", app)
    local out = {}
    for _, c in ipairs(mock.translate(spellless, "zzver",
                                      mock.segment({ "abc" }, 0, 5), env)) do
      out[#out + 1] = c.text:gsub("%s+$", "")
    end
    return table.concat(out, "\n")
  end

  local refused = version_lines("code.exe")
  H.ok(refused:find("^spellless "), "it still leads with the build")
  H.ok(refused:find("app code.exe", 1, true),
       "and names the application the frontend reported: " .. refused)
  H.ok(refused:find("edits refused", 1, true),
       "and says the document is off limits there")

  local allowed = version_lines("notepad.exe")
  H.ok(allowed:find("app notepad.exe", 1, true) and
       allowed:find("edits allowed", 1, true),
       "and says so the other way round elsewhere: " .. allowed)

  H.ok(version_lines(""):find("frontend reports none", 1, true),
       "an application the frontend cannot name is said to be unnamed")

  -- Ordinary input must not pay for any of it.
  ctx0:set_property("client_app", "code.exe")
  local ordinary = mock.translate(spellless, "mathe",
                                  mock.segment({ "abc" }, 0, 5), env)
  H.ok(#ordinary > 1 and not ordinary[1].text:find("^app "),
       "and a real word is unaffected")
  ctx0:set_property("client_app", "")
end

H.suite("adapter: a frontend that cannot read the document is asked for nothing")
-- This is what lets reclaim_space, absorb_fragment and word_backspace ship
-- *on*.  They work by committing U+0008, which a frontend that has never
-- heard of the convention inserts as literal text -- so the schema waits until
-- one has proved it can answer before it asks for anything.
--
-- Setting `surrounding_text` and honouring the backspaces were added to each
-- of the two forks in the same commit, and no stock frontend does either, so
-- the first is a sound proxy for the second.
do
  spellless.forget_frontend()
  H.ok(not spellless.frontend_reads(), "a fresh process has been told nothing")

  ctx0:set_property("client_app", "")
  env.spellless.cfg.reclaim_space = true
  mock.history:clear(); mock.history:push("exact", "you ")
  local written = select(2, type_punct("."))
  H.eq(written, ". ", "so the space stays and no backspace is committed")
  H.ok(not written:find("\8", 1, true),
       "which is the whole point: a stock frontend would print it")

  -- Backspace-twice likewise asks for nothing it cannot get.
  mock.history:clear()
  ctx0.input = ""
  local before = #mock.committed
  spellless.absorb.func(mock.key(XK_BackSpace), env)
  spellless.absorb.func(mock.key(XK_BackSpace), env)
  H.eq(#mock.committed, before, "and Backspace deletes one character, as always")

  -- One cooperative window is enough, and it holds for the session -- the
  -- frontend is a property of the process, not of the window.
  H.ok(frontend_can_read(spellless), "then the frontend answers once")
  mock.history:clear(); mock.history:push("exact", "you ")
  H.eq(select(2, type_punct(".")), "\8. ", "and from then on the space is reclaimed")
end
