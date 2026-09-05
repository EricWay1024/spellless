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
H.eq(select(2, type_punct(".")), ". ", "off by default, the space just stays")

env.spellless.cfg.reclaim_space = true
mock.history:clear(); mock.history:push("exact", "you ")
H.eq(select(2, type_punct(".")), "\8. ", "on, the full stop asks for it back")

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
H.eq(spellless.processor.func(mock.key(XK_BackSpace), env), 1, "the second is handled")
H.eq(mock.committed[#mock.committed], string.rep("\8", 6), "and takes the whole word")

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

H.suite("adapter: Control+Shift+D forgets what was learned by accident")
local XK_D_ = string.byte("d")
env.spellless.user:set("wrold", 5, "wrold")
H.eq(env.spellless.user:count("wrold"), 5, "a typo has been learned")

mock.selected = { text = "wrold " }
env.engine.context.input = "wrold"
H.eq(spellless.processor.func(mock.key(XK_D_, { ctrl = true, shift = true }), env), 1,
     "the key is handled")
H.eq(env.spellless.user:count("wrold"), 0, "and the highlighted candidate is gone")
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
H.eq(mock.committed[#mock.committed], "hello", "committing what was typed")
H.eq(env.engine.context.input, "", "and the composition is finished")

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
