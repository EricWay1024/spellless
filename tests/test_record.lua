-- The input log: that it writes what it says it writes, from every route a
-- commit can arrive by, and that it is invisible when it is off.
--
-- The invariant worth the most here is the dullest: **every commit route
-- produces exactly one record**.  Commits arrive by two entirely separate
-- paths -- `Context::Commit` fires the notifier the translator connected, and
-- `Engine::CommitText` does not fire it at all -- and a log wired to one of
-- them loses half of everything, non-uniformly, and looks fine.

local H = require("harness")
local mock = require("rime_mock")
local util = require("spellless.util")
local Record = require("spellless.record")

local DATA = _G.SPELLLESS_ROOT .. "/generated"
local XK_Return, XK_KP_Enter, XK_BackSpace = 0xff0d, 0xff8d, 0xff08
local XK_Shift_L = 0xffe1

-- A scratch *directory* that exists: the adapter joins the log's name onto the
-- user directory, and os.tmpname gives a path in one Lua can rely on.
local scratch = os.tmpname()
os.remove(scratch)
local dir, stem = scratch:match("^(.*)[/\\]([^/\\]+)$")
local log_path = util.join(dir, stem .. ".log")

local clock = 0
local env = mock.install{
  user_dir = dir,
  page_size = 7,
  config = {
    ["spellless/data_dir"] = DATA,
    ["spellless/learn"] = true,
    ["spellless/record"] = true,
    ["spellless/record_file"] = stem .. ".log",
    ["spellless/personal_file"] = stem .. ".user",
  },
}
-- A clock that moves, so `dur` and `ms` are something other than zero.  It has
-- to be in place before init: `Engine.new` takes the function by reference.
_G.rime_api.get_time_ms = function() return clock end

package.loaded["spellless"] = nil
Record.forget(log_path)
os.remove(log_path)
local spellless = require("spellless")
spellless.init(env)
spellless.processor.init(env)
spellless.absorb.init(env)
spellless.handover.init(env)
local ctx = env.engine.context

H.suite("record: off is off, and on is visible")
H.ok(env.spellless ~= nil, "the engine came up: " .. table.concat(mock.logged, "; "))
H.ok(env.spellless.recorder ~= nil, "and it has a recorder")
H.ok(not util.exists(log_path),
     "nothing on disk yet: a session that records nothing creates no file")

--- Everything in the log so far, as a list of column lists.
local function records()
  env.spellless:flush()
  local out = {}
  for line in (util.slurp(log_path) or ""):gmatch("[^\n]+") do
    local row = {}
    for field in (line .. "\t"):gmatch("([^\t]*)\t") do row[#row + 1] = field end
    out[#out + 1] = row
  end
  return out
end

local function of_kind(kind)
  local out = {}
  for _, row in ipairs(records()) do
    if row[1] == kind then out[#out + 1] = row end
  end
  return out
end

--- Run `fn` and return the records it produced, so "exactly one" is a length.
---
--- Session headers are not counted: one is written at the top of whatever file
--- the first record lands in, and again after a rotation, so it arrives in the
--- same flush as somebody else's record without being one.
local function produced(fn)
  local before = #records()
  fn()
  local all = records()
  local out = {}
  for i = before + 1, #all do
    if all[i][1] ~= "session" then out[#out + 1] = all[i] end
  end
  return out
end

-- Type a word into the composition the way the gears see it: absorb runs
-- before the speller, so it is called with the input as it was *before* the
-- letter landed.
local function type_word(word)
  ctx.input = ""
  for i = 1, #word do
    spellless.absorb.func(mock.key(word:byte(i)), env)
    ctx.input = word:sub(1, i)
    clock = clock + 120
  end
end

H.suite("record: the space bar, end to end")
mock.history:clear(); mock.history:push("exact", "hello")
type_word("mathe")
-- The translator fills the memo the commit reads the rank out of, exactly as
-- it does in the running input method.
mock.translate(spellless, "mathe", mock.segment({ "abc" }, 0, 5), env)
mock.selected = { text = "mathematics " }
local rows = produced(function() ctx:commit() end)
H.eq(#rows, 1, "one record, and only one")
local r = rows[1]
H.eq(r[1], "commit", "it is a commit record")
H.eq(r[4], "mathe", "the input, exactly as typed")
H.eq(r[5], "mathematics", "the text, without the space this software added")
H.ok(tonumber(r[6]) >= 1, "a rank was found in the list: " .. r[6])
H.ok(r[7] ~= "-", "and the mechanism that produced it: " .. r[7])
H.eq(r[8], "space", "the space bar is not a deliberate choice")
H.eq(r[9], "5", "five keys went into it")
H.eq(r[11], "5", "the longest the input ever got")
H.ok(tonumber(r[13]) >= 480, "and it took some time: " .. r[13] .. " ms")

H.suite("record: the session header comes first")
local all = records()
H.eq(all[1][1], "session", "the first line of the file describes the session")
H.eq(all[1][7], "spellless", "naming the schema")
H.ok(all[1][6]:match("^%x%x%x%x%x%x%x%x$") ~= nil,
     "and a digest of the settings that produced everything below it")

H.suite("record: one record from every route a commit arrives by")

-- A number key: absorb is what decides a digit was a deliberate pick.
type_word("mathe")
mock.translate(spellless, "mathe", mock.segment({ "abc" }, 0, 5), env)
spellless.absorb.func(mock.key(0x32), env)
rows = produced(function() ctx:commit() end)
H.eq(#rows, 1, "number key: one record")
H.eq(rows[1][8], "pick", "and it counts as a choice")

-- Return on a highlight moved by the arrow keys.
type_word("mathe")
mock.selected_index = 1
rows = produced(function() spellless.processor.func(mock.key(XK_Return), env) end)
mock.selected_index = 0
H.eq(#rows, 1, "arrow then Return: one record")
H.eq(rows[1][8], "arrow", "which is different evidence from either of the above")

-- Return committing the raw input, carrying the automatic space.  This one
-- goes through Engine::CommitText and the notifier never sees it.
type_word("kubectl")
rows = produced(function() spellless.processor.func(mock.key(XK_Return), env) end)
H.eq(#rows, 1, "Return: one record")
H.eq(rows[1][8], "return", "a refusal to choose between readings")
H.eq(rows[1][5], "kubectl", "committing exactly what was typed")

-- Punctuation ending a word: the route that would be missing entirely if the
-- log were wired only to the commit notifier.
ctx:set_option("ascii_punct", true)
type_word("you")
mock.selected = { text = "you " }
rows = produced(function() spellless.processor.func(mock.key(string.byte(".")), env) end)
H.eq(#rows, 1, "a full stop ending a word: one record")
H.eq(rows[1][8], "punct")
H.eq(rows[1][5], "you", "the word, without the mark and without the space")

-- Shift+Return and keypad Enter.
type_word("draft")
rows = produced(function()
  spellless.processor.func(mock.key(XK_Return, { shift = true }), env)
end)
H.eq(#rows, 1, "Shift+Return: one record")
H.eq(rows[1][8], "soft")

type_word("draft")
rows = produced(function() spellless.processor.func(mock.key(XK_KP_Enter), env) end)
H.eq(#rows, 1, "keypad Enter: one record")
H.eq(rows[1][8], "kp")

-- Control+Shift+A, the deliberate escape.
type_word("sqlite")
rows = produced(function()
  spellless.processor.func(mock.key(0x61, { ctrl = true, shift = true }), env)
end)
H.ok(#rows >= 1, "Control+Shift+A: the word is not lost")
H.eq(rows[1][8], "ascii", "and it is recorded as the escape it is")

H.suite("record: what a commit is not")
-- Punctuation committed on its own has no word in it, and a case file made of
-- those would be noise.
ctx.input = ""
mock.selected = nil
rows = produced(function()
  mock.commit_text = ","
  ctx.input = ","
  mock.commit_handler(ctx)
  ctx.input = ""
end)
H.eq(#rows, 0, "a commit with no letters in it is not a word")

H.suite("record: the failure signals")
ctx.input = ""
rows = produced(function() spellless.processor.func(mock.key(XK_BackSpace), env) end)
H.eq(#rows, 1, "a Backspace outside a composition is recorded")
H.eq(rows[1][1], "del")
H.eq(rows[1][4], "key")

mock.history:clear(); mock.history:push("exact", "recieve")
ctx.input = ""
mock.selected = nil
rows = produced(function()
  spellless.processor.func(mock.key(0x64, { ctrl = true, shift = true }), env)
end)
H.eq(#rows, 1, "Control+Shift+D is recorded")
H.eq(rows[1][1], "forget")
H.eq(rows[1][4], "recieve", "naming the word it was asked to forget")

H.suite("record: the matcher being switched off")
-- The first key only establishes what the mode was; a window that opens in
-- ASCII mode has not bailed out of anything.
ctx:set_option("ascii_mode", false)
rows = produced(function() spellless.handover.func(mock.key(0x78), env) end)
H.eq(#rows, 0, "the first sample is not a transition")
ctx:set_option("ascii_mode", true)
rows = produced(function() spellless.handover.func(mock.key(0x78), env) end)
H.eq(#rows, 1, "switching the matcher off is recorded")
H.eq(rows[1][1], "bail")
H.eq(rows[1][4], "on")
ctx:set_option("ascii_mode", false)
rows = produced(function() spellless.handover.func(mock.key(0x78), env) end)
H.eq(rows[1][4], "off", "and switching it back on")
-- A run the `$` opened is maths, not a bail-out, and says so.
ctx:set_property("spellless_delimiter", "$")
ctx:set_option("ascii_mode", true)
rows = produced(function() spellless.handover.func(mock.key(0x78), env) end)
H.eq(rows[1][4], "delim-on", "a run the delimiter opened is told apart")
ctx:set_property("spellless_delimiter", "")
ctx:set_option("ascii_mode", false)
spellless.handover.func(mock.key(0x78), env)

H.suite("record: a recorder that cannot write never raises")
-- The one thing this module may not do.  A directory that does not exist is
-- the ordinary shape of it: a user directory renamed, a disk unmounted.
local doomed = Record.open{
  path = util.join(scratch, "no", "such", "place.tsv"),
  now_ms = function() return 0 end,
  flush_every = 1,
}
local ok = pcall(function()
  doomed:session{ version = "source", schema = "spellless" }
  doomed:commit{ ms = 0, input = "mathe", text = "mathematics", rank = 1 }
  doomed:note("del", { ms = 1, a = "key" })
  doomed:flush()
  doomed:close()
end)
H.ok(ok, "writing to a path that cannot be opened raises nothing")
H.ok(doomed.dead, "the recorder stops, once, and says why: " .. tostring(doomed.err))
H.ok(doomed.describe(doomed):find("failed") ~= nil, "and zzver would say so")

H.suite("record: fields round-trip")
local escaped = Record.open{ path = log_path .. ".esc", now_ms = function() return 0 end }
escaped:commit{ ms = 0, app = "a\tb", input = "x", text = "-", rank = 0 }
escaped:close()
local line = (util.slurp(log_path .. ".esc") or ""):match("^[^\n]*")
H.ok(line:find("a\\tb", 1, true) ~= nil, "a tab inside a field cannot split a line")
H.ok(line:find("\t\\-\t", 1, true) ~= nil, "and a field that is a hyphen is not absence")
os.remove(log_path .. ".esc")

H.suite("record: the digest follows the settings")
local a = Record.digest{ freq_weight = 34, learn = true }
local b = Record.digest{ freq_weight = 34, learn = true }
local c = Record.digest{ freq_weight = 35, learn = true }
H.eq(a, b, "the same settings hash the same")
H.ok(a ~= c, "and a changed weight is a changed digest")

H.suite("record: recording changes nothing about what is committed")
-- The invariant the whole feature rests on: a log that changed the behaviour
-- could not be used to measure it.  The same keys, twice, with the recorder
-- on and off.
local function run_sequence(record_on, suffix)
  local e = mock.install{
    user_dir = dir,
    page_size = 7,
    config = {
      ["spellless/data_dir"] = DATA,
      ["spellless/learn"] = false,
      ["spellless/record"] = record_on,
      ["spellless/record_file"] = stem .. suffix .. ".log",
      ["spellless/personal_file"] = stem .. suffix .. ".user",
    },
  }
  _G.rime_api.get_time_ms = function() return clock end
  package.loaded["spellless"] = nil
  local mod = require("spellless")
  mod.init(e)
  mod.processor.init(e)
  mod.absorb.init(e)
  local c = e.engine.context
  c:set_option("ascii_punct", true)
  mock.history:clear()
  mock.committed = {}
  c.input = ""
  for i = 1, #"mathe" do
    mod.absorb.func(mock.key(("mathe"):byte(i)), e)
    c.input = ("mathe"):sub(1, i)
  end
  mock.selected = { text = "mathematics " }
  mod.processor.func(mock.key(string.byte(".")), e)
  local out = table.concat(mock.committed, "|")
  if e.spellless then e.spellless:flush() end
  os.remove(util.join(dir, stem .. suffix .. ".log"))
  os.remove(util.join(dir, stem .. suffix .. ".user"))
  return out
end
local off = run_sequence(false, ".off")
local on = run_sequence(true, ".on")
H.eq(on, off, "the same keys commit the same text either way: " .. off)

os.remove(log_path)
os.remove(util.join(dir, stem .. ".user"))
