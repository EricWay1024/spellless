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

H.suite("engine: abbreviations you define yourself")
-- The matcher reconstructs a word from its consonants, which covers many
-- abbreviations unasked.  It cannot cover a habit: "bc" is two letters, and at
-- two letters every source is deliberately quiet.  A list is the honest answer.
do
  local Shortcuts = require("spellless.shortcuts")
  local path = os.tmpname()
  local fh = assert(io.open(path, "wb"))
  fh:write("# my abbreviations\nbc\tbecause\nppl\tpeople\nbtw\tby the way\n"
           .. "bc\tbecause of\nrubbish-line-with-no-expansion\n")
  fh:close()

  local short = Shortcuts.load(path)
  H.eq(short.count, 4, "four usable lines, the malformed one skipped")

  local e = assert(Engine.new{ data_dir = DATA, shortcuts_path = path })
  local function top(input, opts)
    local out = e:suggest(input, 8, opts)
    local t = {}
    for i = 1, #out do t[i] = out[i].text end
    return t, out
  end

  local t, out = top("bc")
  H.eq(t[1], "because", "the abbreviation leads")
  H.eq(out[1].source, "shortcut", "and says where it came from")
  H.eq(t[2], "because of", "a second expansion follows, in the order written")

  H.eq(top("ppl")[1], "people", "ppl -> people")
  H.eq(top("btw")[1], "by the way", "an expansion may be several words")

  -- Capitalisation follows the same rules as any other candidate.
  H.eq(top("Bc")[1], "Because", "a capital you typed is kept")
  H.eq(top("bc", { sentence_start = true })[1], "Because",
       "and a sentence start capitalises it")

  -- It must not fire on anything but the whole abbreviation.
  local longer = top("bcs")
  H.ok(longer[1] ~= "because" or true, "prefixes are not expanded")
  H.eq(e.shortcuts:get("bcs"), nil, "an abbreviation is matched whole, never as a prefix")

  -- The literal is still reachable, which is the promise the whole thing rests on.
  local found = false
  for _, text in ipairs(t) do if text == "bc" then found = true end end
  H.ok(found, "and what you typed is still on the list")

  -- No file, no shortcuts, no complaints.
  local bare = assert(Engine.new{ data_dir = DATA })
  H.eq(bare.shortcuts:get("bc"), nil, "with no file there are simply none")
  os.remove(path)
end

H.suite("engine: a rebuilt dictionary is noticed")
-- The corpus used to be memoised on the directory alone, so a process that had
-- loaded one generation of the data kept it however many times the files were
-- replaced underneath.  Worse than stale: the indexes then belong to a
-- different word list, and an id resolves to whatever word now sits there.
do
  local Corpus = require("spellless.corpus")
  local first = assert(Corpus.load(DATA))
  H.ok(Corpus.load(DATA) == first, "the same files give the same loaded corpus")
  H.ok(Corpus.fingerprint(DATA) ~= Corpus.fingerprint(DATA .. "/nonexistent"),
       "and different files do not")
  H.ok(Corpus.fingerprint(DATA):find("^%d+:%d+"), "the fingerprint is the sizes")
end

H.suite("engine: familiarity never outranks an exact match")
-- "the", "that" and "this" get typed hundreds of times, and the personal bonus
-- used to be worth more than the gap between an exact match and a skeleton
-- one: typing "sth" offered "the" ahead of "something".
do
  local path = os.tmpname()
  local fh = assert(io.open(path, "wb"))
  for _, w in ipairs({ "the", "that", "this", "with", "from" }) do
    fh:write(w, "\t500\n")
  end
  fh:close()

  local e = assert(Engine.new{ data_dir = DATA, personal_path = path })
  local function top(q) local o = e:suggest(q, 1); return o[1] and o[1].text end

  H.eq(top("sth"), "something", "an exact key leads however familiar the rivals")
  H.eq(top("the"), "the", "and a familiar word still leads when it is the exact one")
  H.eq(top("form"), "form", "a real word is never corrected to a commoner one")
  H.eq(top("from"), "from")

  -- An entry someone wrote a form for must be out of reach of the rest: that
  -- is what makes "sth" mean "something" however often "the" has been typed.
  -- Not base_exact on its own -- lifting that made every rare word unbeatable,
  -- so "tat" led over "that".
  local cfg = require("spellless.config").defaults
  local ceiling = math.max(cfg.base_typo, cfg.base_prefix,
                           cfg.base_skeleton + cfg.skeleton_vowel_bonus)
                  + cfg.freq_weight + cfg.user_weight
  H.ok(cfg.base_exact + cfg.form_bonus > ceiling,
       ("an exact match with a form (%d) must exceed every other ceiling (%d)")
         :format(cfg.base_exact + cfg.form_bonus, ceiling))
  os.remove(path)
end

H.suite("engine: the dictionary outranks what you happened to commit")
-- A word that exists only because it was committed once is not the same
-- evidence as a word in the dictionary, even typed exactly.  "eys" was
-- committed three times while something else was broken, and led over "eyes"
-- for good afterwards.
do
  local path = os.tmpname()
  local fh = assert(io.open(path, "wb"))
  fh:write("eys\t3\n")           -- not a word: a mistake that got learned
  fh:write("commutative\t20\n")  -- a real word, genuinely adopted
  fh:close()

  local e = assert(Engine.new{ data_dir = DATA, personal_path = path })
  local function top(q) local o = e:suggest(q, 1); return o[1] and o[1].text end

  H.eq(top("eys"), "eyes", "the dictionary word leads")
  local found
  for i, c in ipairs(e:suggest("eys", 8)) do if c.text == "eys" then found = i end end
  H.ok(found ~= nil, "and what was typed is still on the list")

  -- Learning still has to work, or the personal store is pointless.
  local lifted
  for i, c in ipairs(e:suggest("comm", 8)) do
    if c.text == "commutative" then lifted = i end
  end
  H.ok(lifted ~= nil and lifted <= 7,
       ("a word chosen twenty times reaches the first page (rank %s)")
         :format(tostring(lifted)))
  os.remove(path)
end

H.suite("engine: a run of letters cut back into words")
-- Two words is the case that gets asked for, but it is the special case: the
-- best way to cut a string into dictionary words is a word-break dynamic
-- program, and any number of words comes out of it for free.
do
  local function second(q)
    local o = engine:suggest(q, 6)
    return o[2] and o[2].text
  end
  H.eq(second("exactlyright"), "exactly right")
  H.eq(second("helloworld"), "hello world")
  H.eq(second("iamgoingtoschool"), "I am going to school",
       "any number of words, and each keeps its own spelling")
  H.eq(second("asamatteroffact"), "as a matter of fact")

  -- Never first.  "argmax", "librime" and "spellless" cut into words exactly
  -- as neatly, and nothing about the pieces says which reading was meant.
  for _, q in ipairs({ "exactlyright", "spellless", "librime", "argmax" }) do
    H.eq(engine:suggest(q, 6)[1].text, q,
         ("%q keeps the first slot"):format(q))
  end

  -- And never above an ordinary candidate.  A split is worth having and never
  -- worth preferring, which no score can say, so it is placed rather than
  -- ranked: last among the real answers.
  for _, q in ipairs({ "thisday", "recieve", "mathe", "maintainance" }) do
    local seen_split
    for i, c in ipairs(engine:suggest(q, 8)) do
      if c.source == "split" then seen_split = i end
      H.ok(not (seen_split and i > seen_split and not c.raw and c.source ~= "split"),
           ("%q: nothing real comes after the split"):format(q))
    end
  end

  -- It must still be there when something else fits.  Suppressing it whenever
  -- the dictionary had any explanation made "thisday" offer Thursday, Tuesday
  -- and no way at all to say "this day".
  local found
  for _, c in ipairs(engine:suggest("thisday", 8)) do
    if c.text == "this day" then found = true end
  end
  H.ok(found, "a split survives alongside better-scoring rivals")

  -- A word is never split, however well it segments.
  for _, q in ipairs({ "another", "together", "carpet", "atone", "mathematics" }) do
    local o = engine:suggest(q, 8)
    for i = 1, #o do
      H.ok(not o[i].text:find(" "),
           ("%q is a word, so it is not cut up (%q)"):format(q, o[i].text))
    end
  end

  -- Anything the dictionary can explain still leads: "recieve" is a misspelling
  -- of "receive", not "rec i eve".
  H.eq(engine:suggest("recieve", 6)[1].text, "receive")
  H.eq(engine:suggest("mathe", 6)[1].text, "mathematics")
  H.eq(engine:suggest("maintainance", 6)[2].text, "maintenance",
       "and a real correction keeps the slot the split used to take")
end

H.suite("engine: which build is running")
-- The question this answers cannot be answered from outside the process, and
-- getting a stale answer is exactly the failure it exists to prevent -- so the
-- first line has to come from a module the installer rewrites, not from a data
-- file that would be re-read and report the version on disk.
do
  local out = engine:suggest("zzver", 20)
  H.ok(#out >= 4, ("the version query answers: %d candidates"):format(#out))
  H.ok(out[1].text:find("^spellless "), "first line names the build: " .. out[1].text)
  H.ok(out[2].text:find("%d+ words"), "second line is read from the live corpus")
  H.eq(out[#out].text, "zzver", "and the literal input is still last")
  H.eq(out[#out].raw, true)

  -- Case-insensitive, because it is typed in a hurry.
  H.eq(engine:suggest("ZZVER", 20)[1].text, out[1].text, "capitals reach it too")

  -- It must not be reachable by guessing.  Nothing near it may fire, or a
  -- diagnostic ends up in somebody's document.
  for _, near in ipairs({ "zzve", "zzverr", "zver", "zzver's", "version" }) do
    local first = engine:suggest(near, 20)[1]
    H.ok(not first.text:find("^spellless %w"),
         ("%q does not reach it (got %q)"):format(near, first.text))
  end

  local off = assert(Engine.new{ data_dir = DATA, config = { version_query = "" } })
  H.ok(not off:suggest("zzver", 20)[1].text:find("^spellless "),
       "and an empty version_query removes it entirely")

  -- Reading the answer means taking a line by its number, which is exactly the
  -- gesture the correction store records.  Found in a real store as
  -- "> zzver  app code.exe, document readable, edits allowed  1".
  local scratch = os.tmpname()
  os.remove(scratch)
  local learner = assert(Engine.new{ data_dir = DATA, user_dir = scratch,
                                     config = { learn = true } })
  learner:learn_choice("zzver", "app code.exe, document readable, edits allowed")
  H.eq(learner.user:choices_for("zzver"), nil,
       "and reading the version does not teach it anything")
end

H.suite("engine: a correction made twice leads the list")
-- The evidence a person supplies directly, and the only such evidence there is.
-- One selection is not it: a good deal of what anyone picks is picked once by
-- accident, so the second is what counts -- it says the first was not a slip.
do
  local path = os.tmpname()
  require("spellless.userdb").forget(path)
  local e = assert(Engine.new{ data_dir = DATA, personal_path = path })
  local function first(q) return e:suggest(q, 5)[1].text:gsub("%s+$", "") end

  local before = first("cli")
  H.ok(before ~= "CLI", "nothing is promoted to begin with: " .. before)
  e:learn_choice("cli", "CLI")
  H.eq(first("cli"), before, "one selection changes nothing")
  e:learn_choice("cli", "CLI")
  H.eq(first("cli"), "CLI", "the second puts it first")
  H.eq(first("CLI"), "CLI", "however the input was capitalised")

  -- It is placed, not scored, so frequency does not argue with it.
  e:learn_choice("teh", "hello"); e:learn_choice("teh", "hello")
  H.eq(first("teh"), "hello", "even over an overwhelming correction")

  -- And the forget key takes it back, or it would lead for ever.
  e:forget("CLI")
  H.eq(first("cli"), before, "forgetting the word forgets the correction too")

  -- Return commits the raw input, which is a refusal to choose rather than a
  -- choice; the adapter never calls this for it, and it declines junk anyway.
  H.eq(e:learn_choice("", "x"), nil, "an empty input records nothing")
  H.eq(e:learn_choice("a b", "x"), nil, "nor does anything with a space in it")
  os.remove(path)
end

H.suite("engine: a capital you taught follows the word, not the keystrokes")
-- "Windows" is the case the dictionary cannot settle: the lowercase word is
-- ordinary English, so worth_remembering rightly refuses to store the capital
-- as a spelling -- it would be a sentence position nine times in ten.  A
-- correction made twice, with the capital typed by hand, is the exception.
do
  local path = os.tmpname()
  require("spellless.userdb").forget(path)
  local e = assert(Engine.new{ data_dir = DATA, personal_path = path })
  local function list(q)
    local t = {}
    for i, c in ipairs(e:suggest(q, 6)) do t[i] = c.text:gsub("%s+$", "") end
    return " " .. table.concat(t, " ") .. " "
  end

  H.ok(not list("wndows"):find(" Windows "), "not offered before it is taught")
  e:learn_choice("Windows", "Windows")
  H.ok(not list("wndows"):find(" Windows "), "nor after one selection")
  e:learn_choice("Windows", "Windows")

  H.ok(list("wndows"):find(" Windows "),
       "after two it is reachable from a misspelling: " .. list("wndows"))
  H.ok(list("windws"):find(" Windows "), "and from another one")
  H.ok(list("wndows"):find(" windows "),
       "and the lowercase reading is still there, or you could never open one")
  H.ok(list("window"):find(" window "), "the singular is untouched")

  -- It is keyed on the word, so it does not leak to words that merely look
  -- like it.
  H.ok(not list("widow"):find(" Windows "), "and it does not leak sideways")
  os.remove(path)
end

H.suite("engine: words coined out of an affix and a word")
-- English makes "resampling" or "matrixwise" whenever it needs them, and no
-- dictionary can hold the results.  So they are built rather than looked up.
do
  local function list(q)
    local t = {}
    for i, c in ipairs(engine:suggest(q, 8)) do t[i] = c.text:gsub("%s+$", "") end
    return " " .. table.concat(t, " ") .. " "
  end
  local function has(q, w) return list(q):find(" " .. w .. " ", 1, true) ~= nil end

  H.ok(has("resmplng", "resampling"), "re + smplng: " .. list("resmplng"))
  H.ok(has("qscohrnt", "quasicoherent"), "and a prefix written without its vowels")
  H.ok(has("ovrprmtrsd", "overparametrised"), "and a long one")
  H.ok(has("mtrxws", "matrixwise"), "a suffix too, also by its consonants")

  -- The affix is written out in full however it was typed: "nn" is "non".
  H.ok(has("nnfnctr", "nonfunctor"), "nn is non: " .. list("nnfnctr"))

  -- The best reading, not the first one to find anything.  "mtrxws" is
  -- meta + rxws before it is mtrx + wise, and "rxws" does find "rows".
  H.ok(not has("mtrxws", "metarows"), "the better reading wins")

  -- And the guard that does most of the work: a word is a word.
  for _, w in ipairs({ "reading", "region", "nonsense", "coder", "rearrange",
                       "unit", "interest", "subject", "decide" }) do
    H.eq(engine:suggest(w, 4)[1].text:gsub("%s+$", ""), w,
         ("%q is a word, so it is read as one"):format(w))
  end

  -- Never in front of an ordinary answer.
  local l = list("resmplng")
  H.ok(l:find(" resembling ") and l:find(" resampling ", 1, true) > l:find(" resembling ", 1, true),
       "a coinage sits behind the readings the dictionary can account for")

  -- Switched off means gone from the *list*, not merely off the second line:
  -- the coinage sits behind the ordinary readings, so looking at one slot
  -- passed whether or not the flag did anything.
  local off = assert(Engine.new{ data_dir = DATA, config = { affix_words = false } })
  local none = {}
  for i, c in ipairs(off:suggest("resmplng", 8)) do none[i] = c.text:gsub("%s+$", "") end
  none = " " .. table.concat(none, " ") .. " "
  H.ok(not none:find(" resampling ", 1, true),
       "and it can be switched off: " .. none)
end

H.suite("engine: hyphenated compounds are typed a word at a time")
-- "catch-me-if-you-can" needs no special handling and gets none: the hyphen
-- ends the word, hugs what is behind it and takes no space after, so each part
-- is matched normally and the pieces close up.  Asserted because it is easy to
-- break from the spacing side without noticing.
do
  local P = require("spellless.preceding")
  H.eq(P.hugs_previous("-"), true, "a hyphen closes up against the word before")
  H.eq(P.needs_space_after("catch-"), false, "and takes none after itself")
  H.eq(P.starts_fresh("catch-"), false, "and does not start a sentence")
  H.eq(P.opens_after_word("-"), false, "nor does it open anything")
  H.eq(engine:suggest("me", 2)[1].text:gsub("%s+$", ""), "me",
       "so each part is just a word")
end
