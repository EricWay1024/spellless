local H = require("harness")
local Engine = require("spellless.engine")

local DATA = _G.SPELLLESS_ROOT .. "/generated"

H.suite("engine: capitalisation")
H.eq(Engine.case_style("mathe"), "lower")
H.eq(Engine.case_style("Mathe"), "title")
H.eq(Engine.case_style("MATHE"), "upper")
H.eq(Engine.case_style("MaThE"), "mixed")
H.eq(Engine.apply_case("mathematics", "title"), "Mathematics")
H.eq(Engine.apply_case("mathematics", "upper"), "MATHEMATICS")
H.eq(Engine.apply_case("mathematics", "lower"), "mathematics")

local engine = assert(Engine.new{ data_dir = DATA })

local function texts(input, n)
  local out = {}
  for i, c in ipairs(engine:suggest(input, n or 8)) do out[i] = c.text end
  return out
end

H.suite("engine: capitalisation flows through to candidates")
H.eq(texts("Mathe")[1] ~= nil and texts("Mathe")[1]:sub(1, 1), "M",
     "a capitalised query yields capitalised candidates")
local upper = texts("RECIEVE")
local found_upper = false
for _, t in ipairs(upper) do if t == "RECEIVE" then found_upper = true end end
H.ok(found_upper, "an all-caps query yields all-caps candidates")

H.suite("engine: words with no lowercase form")
-- generated/spellless.forms carries the surface form of words the lowercase
-- corpus cannot spell.  The pronoun "I" is the whole of that class.
H.eq(texts("i")[1], "I", "a bare i is the pronoun")
H.eq(engine:surface("i", "lower"), "I")
H.eq(engine:surface("i'd", "lower"), "I'd")
H.eq(engine:surface("i", "title"), "I", "a form is not re-lowercased")
H.eq(engine:surface("mathematics", "lower"), "mathematics", "everything else is untouched")
H.eq(engine:surface("mathematics", "title"), "Mathematics")

H.suite("engine: abbreviations typed without their dots")
H.eq(texts("eg")[1], "e.g.", "eg gives e.g.")
H.eq(texts("ie")[1], "i.e.", "ie gives i.e.")
H.eq(texts("egg")[1], "egg", "and ordinary words are untouched")
local has_raw = false
for _, c in ipairs(engine:suggest("eg", 20)) do if c.text == "eg" then has_raw = true end end
H.ok(has_raw, "the bare letters are still available")
H.ok(engine.corpus.abbreviations["e.g."], "and it is registered as an abbreviation")

H.suite("engine: dropped apostrophes")
local function has(input, want)
  for i, c in ipairs(engine:suggest(input, 6)) do
    if c.text == want then return i end
  end
  return nil
end
for _, pair in ipairs{ { "dont", "don't" }, { "its", "it's" }, { "id", "I'd" },
                       { "ive", "I've" }, { "youre", "you're" }, { "thats", "that's" } } do
  H.ok(has(pair[1], pair[2]) ~= nil,
       ("%q offers %q"):format(pair[1], pair[2]))
end
H.eq(texts("its")[1], "its", "but a real word still comes first")

H.suite("engine: short and capitalised input keeps the literal in front")
-- Variables, units and acronyms are what one and two characters usually are,
-- and completing them buries what was actually typed.
for _, input in ipairs{ "x", "f", "n", "cm", "ms", "CW", "PDE", "TQFT" } do
  H.eq(engine:suggest(input, 8)[1].text, input,
       ("%q leads with itself"):format(input))
end
-- ... but a word means itself, and a one-letter no-repair completion is still
-- worth trusting.
H.eq(texts("i")[1], "I")
H.eq(texts("an")[1], "an")
H.eq(texts("th")[1], "the")
H.eq(texts("mathe")[1], "mathematics", "and ordinary input is unaffected")

H.suite("engine: possessives are productive")
H.eq(texts("student's")[1], "student's")
H.eq(texts("cat's")[1], "cat's")
H.eq(texts("noether's")[1], "Noether's", "and they inherit the stem's spelling")

H.suite("engine: the literal input is always reachable")
for _, input in ipairs{ "mathe", "recieve", "mthmtcs", "spellless", "qwertyuiop", "the" } do
  local seen = false
  for _, c in ipairs(engine:suggest(input, 20)) do
    if c.text == input then seen = true end
  end
  H.ok(seen, ("the literal %q is offered"):format(input))
end

H.suite("engine: the literal leads when nothing is trustworthy")
H.eq(engine:suggest("qwertyuiop", 8)[1].text, "qwertyuiop")
H.eq(engine:suggest("zzxxqq", 8)[1].text, "zzxxqq")
H.ok(engine:suggest("recieve", 8)[1].text ~= "recieve",
     "but a confident correction still leads")

H.suite("engine: non-alphabetic input is passed through untouched")
local ident = engine:suggest("sqlite3", 8)
H.eq(#ident, 1, "one candidate")
H.eq(ident[1].text, "sqlite3")

H.suite("engine: personal vocabulary")
local path = os.tmpname()
local fh = assert(io.open(path, "w"))
fh:write("quasicoherent\t3\nspellless\t1\n")
fh:close()
require("spellless.userdb").forget(path)
local learner = assert(Engine.new{ data_dir = DATA, personal_path = path })
local function rank_of(input, want)
  for i, c in ipairs(learner:suggest(input, 20)) do
    if c.text == want then return i end
  end
  return nil
end
H.eq(rank_of("quasicoherent", "quasicoherent"), 1, "a personal word matches exactly")
H.ok(rank_of("quasicohrent", "quasicoherent") ~= nil, "a personal word tolerates a typo")
H.ok(rank_of("qscohrnt", "quasicoherent") ~= nil, "a personal word answers its skeleton")

H.suite("engine: learning survives the automatic leading space")
-- The translator prefixes the space, so the commit text carries it; without
-- trimming, nothing after the first word of a sentence would ever be learned.
require("spellless.userdb").forget(path)
local spaced = assert(Engine.new{ data_dir = DATA, personal_path = path })
spaced:learn(" cobordism")
H.eq(spaced.user:count("cobordism"), 1, "a leading space does not block learning")
spaced:learn(" Awodey")
H.eq(spaced.user:surface("awodey"), "Awodey",
     "capitals on a word the dictionary does not know are kept")
spaced:learn("!")
H.eq(spaced.user:count("!"), 0, "punctuation is still not vocabulary")

H.suite("engine: a sentence capital is not a preference")
-- Automatic capitalisation used to feed itself back through the learner, so
-- one sentence-initial "The" made every later mid-sentence "the" capitalised.
local capital = spaced:suggest("teh", 3, { sentence_start = true })[1].text
H.eq(capital, "The")
spaced:learn(capital)
H.eq(spaced.user:surface("the"), nil, "a leading capital on a known word is not stored")
H.eq(spaced:suggest("teh", 3)[1].text, "the", "so mid-sentence is unaffected")
-- ... but capitals the dictionary cannot explain still are
spaced:learn("MacLane")
H.eq(spaced.user:surface("maclane"), "MacLane", "an inner capital is real evidence")
spaced:learn("TQFT")
H.eq(spaced.user:surface("tqft"), "TQFT", "so is an acronym")
spaced:learn("awodey")
H.eq(spaced.user:surface("awodey"), nil,
     "and committing the plain lowercase form takes a spelling back")

H.suite("engine: repairing a store an older version contaminated")
do
  local path2 = os.tmpname()
  local fh2 = assert(io.open(path2, "w"))
  fh2:write("the\tThe\t9\nawodey\tAwodey\t3\nmaclane\tMacLane\t2\n")
  fh2:close()
  require("spellless.userdb").forget(path2)
  local repaired = assert(Engine.new{ data_dir = DATA, personal_path = path2 })
  H.eq(repaired.user:surface("the"), nil, "a sentence capital on a known word is dropped")
  H.eq(repaired.user:surface("awodey"), "Awodey", "a name is kept")
  H.eq(repaired.user:surface("maclane"), "MacLane", "so is an inner capital")
  H.eq(repaired.user:count("the"), 9, "and the counts are untouched")
  os.remove(path2)
end

H.suite("engine: learning promotes a word")
local before = rank_of("comm", "committee")
for _ = 1, 20 do learner:learn("commutative") end
local after = rank_of("comm", "commutative")
H.ok(after ~= nil, "a freshly learned word becomes a candidate")
H.ok(after == 1 or (before and after and after < before),
     ("selection history lifts it (rank %s)"):format(tostring(after)))
learner:flush()
require("spellless.userdb").forget(path)
local reloaded = assert(Engine.new{ data_dir = DATA, personal_path = path })
H.ok(reloaded.user:count("commutative") >= 20, "the count survived a restart")
os.remove(path)
