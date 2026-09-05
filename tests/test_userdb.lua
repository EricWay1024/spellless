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

H.suite("userdb: the scan window keeps what you use most")
-- The file is written back sorted by descending count, so taking the tail of
-- insertion order after a reload would keep the words used *least*.
UserDB.forget(path)
local many = UserDB.load(path, cfg)
many:set("topterm", 1000)
for i = 1, 20 do many:set(("w%02d"):format(i), 1) end
local window = many:words(5)
H.eq(#window, 5, "capped")
local kept = false
for _, w in ipairs(window) do if w == "topterm" then kept = true end end
H.ok(kept, "and the most-used word is in it")

H.suite("userdb: enumerating the personal vocabulary")
H.eq(#edited:words(), 2, "both words")
H.eq(#edited:words(1), 1, "capped to the most recent")
H.eq(edited:words(1)[1], "diffeomorphism")

os.remove(path)
