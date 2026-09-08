local H = require("harness")
local UserDB = require("spellless.userdb")
local config = require("spellless.config")

local cfg = config.build{ flush_every = 2 }
local path = os.tmpname()

H.suite("userdb: one store per file")
UserDB.forget(path)
H.ok(UserDB.load(path, cfg) == UserDB.load(path, cfg),
     "two engines share a store, so neither flush clobbers the other")

H.suite("userdb: counting and scoring")
UserDB.forget(path)
local db = UserDB.load(path, cfg)
H.eq(db:count("bordism"), 0, "unknown word")
H.eq(db:score("bordism", 12), 0, "unknown word scores zero")
db:record("bordism")
H.eq(db:count("bordism"), 1)
H.ok(db:score("bordism", 12) > 0, "one selection is already a signal")
for _ = 1, 40 do db:record("bordism") end
H.near(db:score("bordism", 12), 1, 1e-9, "the personal scale saturates")

H.suite("userdb: scoring policy belongs to the caller, not the shared store")
-- Two engines share one store; keeping one engine's saturation on it would
-- silently apply that engine's learning strength to the other.
H.ok(db:score("bordism", 1000) < db:score("bordism", 2),
     "a larger saturation means a smaller score for the same count")

H.suite("userdb: round trip through the file")
db:flush()
UserDB.forget(path)
local again = UserDB.load(path, cfg)
H.eq(again:count("bordism"), 41, "counts survive a reload")

H.suite("userdb: hand-editable format")
local fh = assert(io.open(path, "w"))
fh:write("# a comment\n\ncobordism\ndiffeomorphism\t7\n")
fh:close()
UserDB.forget(path)
local edited = UserDB.load(path, cfg)
H.eq(edited:count("cobordism"), 1, "a bare word counts once")
H.eq(edited:count("diffeomorphism"), 7, "an explicit count is honoured")

H.suite("userdb: remembering how you write a word")
UserDB.forget(path)
local cased = UserDB.load(path, cfg)
cased:record("grothendieck", "Grothendieck")
cased:record("tqft", "TQFT")
cased:record("plain", "plain")
H.eq(cased:surface("grothendieck"), "Grothendieck")
H.eq(cased:surface("tqft"), "TQFT")
H.eq(cased:surface("plain"), nil, "a plain lowercase commit says nothing worth storing")
cased:record("tqft", false)
H.eq(cased:surface("tqft"), nil, "and `false` takes a stored spelling back")
cased:record("tqft", "TQFT")
cased:flush()
UserDB.forget(path)
H.eq(UserDB.load(path, cfg):surface("grothendieck"), "Grothendieck",
     "and it survives a restart")

H.suite("userdb: enumerating the personal vocabulary")
H.eq(#edited:words(), 2, "both words")
-- Every one of them, always: the matcher indexes this list rather than
-- walking it, so there is nothing to cap and nothing that may go missing.

os.remove(path)

H.suite("userdb: words you have said you never write")
do
  local path = os.tmpname()
  UserDB.forget(path)
  local db = UserDB.load(path)
  H.ok(not db:has_suppressions(), "nothing suppressed to begin with")
  H.ok(db:suppress("Hae"), "suppressing is a change")
  H.ok(not db:suppress("hae"), "and is recorded case-blind, so twice is once")
  H.ok(db:is_suppressed("hae") and db:has_suppressions(), "the word is on the list")
  db:flush()

  local blob = assert(io.open(path)):read("a")
  H.ok(blob:find("\n%- hae\n"), "written as a line a person can read and edit")
  UserDB.forget(path)
  H.ok(UserDB.load(path):is_suppressed("hae"), "and read back again")

  H.ok(db:release("hae"), "releasing is a change")
  H.ok(not db:release("hae"), "and only the first time")
  H.ok(not db:is_suppressed("hae"), "the word is offered again")
  os.remove(path)
end

H.suite("userdb: what you chose, for what you typed")
do
  local path = os.tmpname()
  UserDB.forget(path)
  local db = UserDB.load(path, cfg)
  H.eq(db:choices_for("cli"), nil, "nothing remembered to begin with")
  H.eq(db:record_choice("cli", "CLI"), 1, "one selection")
  H.eq(db:record_choice("cli", "CLI"), 2, "and a second counts up")
  db:record_choice("cli", "client")
  local got = db:choices_for("cli")
  H.eq(#got, 2, "both readings are kept")
  H.eq(got[1].text, "CLI", "commonest first")
  H.eq(got[1].count, 2)
  H.eq(got[2].text, "client")

  db:flush()
  UserDB.forget(path)
  local back = UserDB.load(path, cfg)
  local again = back:choices_for("cli")
  H.eq(#again, 2, "and they survive a round trip through the file")
  H.eq(again[1].text .. ":" .. again[1].count, "CLI:2")

  -- A hand-edited file is the same file; the two kinds of line coexist because
  -- ">" cannot begin a word.
  H.ok(back:count("grothendieck") == 0, "word lines still parse as words")
  H.eq(back:forget_choice("cli", "client"), true, "one reading can be dropped")
  H.eq(#back:choices_for("cli"), 1)
  H.eq(back:forget_choice("cli"), true, "or all of them")
  H.eq(back:choices_for("cli"), nil)
  os.remove(path)
end
