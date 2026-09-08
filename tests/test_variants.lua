local H = require("harness")
local Engine = require("spellless.engine")
local Variants = require("spellless.variants")

local DATA = _G.SPELLLESS_ROOT .. "/generated"

--- One engine per mode, built once.  `spelling_variant` is the setting the
--- switch starts from, so setting it is the same as flipping the switch.
local engines = {}
local function eng(mode)
  if not engines[mode] then
    engines[mode] = assert(Engine.new{ data_dir = DATA,
                                       config = { spelling_variant = mode } })
  end
  return engines[mode]
end

local function words(mode, query, n)
  local out = eng(mode):suggest(query, n or 8, {})
  local names = {}
  for i, c in ipairs(out) do names[i] = c.text or c.word end
  return names
end

local function has(list, word)
  for _, w in ipairs(list) do if w == word then return true end end
  return false
end

local function position(list, word)
  for i, w in ipairs(list) do if w == word then return i end end
  return nil
end

-- ---------------------------------------------------------------------------

H.suite("variants: the groups say where each spelling is written")

local gb = assert(Variants.load(DATA, "gb-ise"))
local us = assert(Variants.load(DATA, "us"))
local ox = assert(Variants.load(DATA, "gb-ize"))

H.eq(Variants.load(DATA, "off"), nil, "off loads nothing at all")
H.eq(Variants.load(DATA, "klingon"), nil, "an unknown mode loads nothing")

H.eq(gb:hidden("color"), true, "color is not written in British")
H.eq(gb:hidden("colour"), false, "colour is")
H.eq(us:hidden("colour"), true, "and the other way round")

-- Trap 2: a word correct in both dialects is never hidden, in either.
H.eq(gb:hidden("program"), false, "program is British too, so it stays")
H.eq(us:hidden("program"), false, "and American")
H.eq(us:hidden("programme"), true, "only programme is dialect-locked")

-- Trap 4: licence/practise are British part-of-speech pairs, not variants, so
-- they survive a British mode -- and American uses one spelling for both.
H.eq(gb:hidden("licence"), false, "licence is British; keep it")
H.eq(gb:hidden("license"), false, "so is license, as the verb")
H.eq(us:hidden("licence"), true, "American writes license for both")
H.eq(gb:hidden("practise"), false, "practise is the British verb")
H.eq(us:hidden("practise"), true, "American writes practice for both")

-- Trap 1: Oxford keeps -ize *and* -yse, so the two axes part company.
H.eq(ox:hidden("realise"), true, "Oxford writes realize")
H.eq(ox:hidden("realize"), false, "and keeps it")
H.eq(gb:hidden("realize"), true, "-ise British does not")
H.eq(ox:hidden("analyze"), true, "but Oxford still writes analyse")
H.eq(ox:hidden("analyse"), false, "-yse survives the -ize rule")
H.eq(gb:hidden("analyze"), true, "as it does under -ise")

-- Trap 1, third class: -ise in every dialect is not a variant at all.
for _, w in ipairs({ "advertise", "surprise", "exercise", "compromise", "supervise" }) do
  H.eq(us:hidden(w), false, w .. " is -ise everywhere, including American")
  H.eq(ox:hidden(w), false, w .. " survives Oxford too")
end

-- Trap 5: a proper noun is spelled the way it is spelled.
H.eq(gb:hidden("colorado"), false, "colorado is not an American spelling of anything")

H.suite("variants: a hidden spelling is not offered at all")

local clr_gb = words("gb-ise", "clr")
H.eq(has(clr_gb, "colour"), true, "clr offers colour under British")
H.eq(has(clr_gb, "color"), false, "and never color, at any position")
H.eq(has(clr_gb, "colorado"), true, "while colorado is untouched")

local clr_us = words("us", "clr")
H.eq(has(clr_us, "color"), true, "the mirror image under American")
H.eq(has(clr_us, "colour"), false, "colour is gone")

local clr_off = words("off", "clr")
H.eq(has(clr_off, "color") and has(clr_off, "colour"), true,
     "and with the switch off both are there, as they always were")

H.suite("variants: the surviving spelling keeps the place the hidden one earned")

-- `rls` is an exact skeleton hit for `realise` and not for `realize`, so
-- re-scoring the survivor against the query would drop it ten places.  The
-- swap happens after ranking for exactly this reason.
local rls_off = words("off", "rls")
local rls_us = words("us", "rls")
H.eq(position(rls_off, "realise"), position(rls_us, "realize"),
     "realize lands where realise did")

H.suite("variants: a pair too far apart to match is substituted")

-- plough -> plow is 2.70 against a typo budget of 1.35, so without the
-- substitution an American writer typing `plgh` gets nothing they want.
local plgh_us = words("us", "plgh")
H.eq(has(plgh_us, "plow"), true, "plgh reaches plow under American")
H.eq(has(plgh_us, "plough"), false, "and not plough")
H.eq(has(words("gb-ise", "plgh"), "plough"), true, "British keeps plough")

H.suite("variants: what you typed is still yours")

-- The literal is placed after this filter runs, so a refused spelling stays
-- reachable; and `variant_refuses` is what makes the space bar ask first.
H.eq(has(words("gb-ise", "color"), "color"), true,
     "typing color under British still offers color itself")
H.eq(eng("gb-ise"):variant_refuses("color", {}), true,
     "and the adapter is told to ask before committing colour")
H.eq(eng("gb-ise"):variant_refuses("colour", {}), false,
     "a spelling this mode writes needs no question")
H.eq(eng("off"):variant_refuses("color", {}), false,
     "and with no mode on, nothing is refused")

H.suite("variants: the coverage the corpus lost")

-- The whole point of levelling: these could not be typed at all before,
-- because the corpus merged each pair onto one spelling.
local corpus = eng("off").corpus
for _, w in ipairs({ "analyze", "theater", "traveled", "catalog", "aluminum",
                     "favorite", "colors", "colored", "plow", "jewelry",
                     "agonise", "amortise", "alphabetise" }) do
  H.eq(corpus:lookup(w) ~= nil, true, w .. " is in the dictionary")
end

-- Levelling put every member of a group on one frequency, which is what lets
-- the runtime stay a post-filter: adjacent ranks clear the same ceilings.
for _, pair in ipairs({ { "color", "colour" }, { "realize", "realise" },
                        { "favorite", "favourite" } }) do
  local a, b = corpus:lookup(pair[1]), corpus:lookup(pair[2])
  H.eq(math.abs(a - b) <= 1, true,
       pair[1] .. " and " .. pair[2] .. " are ranked side by side")
end
