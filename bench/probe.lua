-- Two probes that are harsher than the case files, and what each channel is
-- worth on them.
--
--     lua bench/probe.lua
--     lua bench/probe.lua --seed 7
--
-- The case files are built from *plausible* input: a slip a typist would
-- actually make, an abbreviation a typist would actually write.  That is the
-- right thing to fit weights on and the wrong thing to answer "what happens
-- when the input is worse than that".  These two probes answer the second
-- question, which is why they live here and not in tests/cases.
--
-- 1. **Two letters deleted at random** from a word of seven letters or more.
--    Nothing about the result is a plausible abbreviation -- the deletions do
--    not respect syllables, and either one can take a consonant the skeleton
--    channel needs.  Run with the cue channel off and on.
--
-- 2. **A corrupted abbreviation**: an input from generated_cues.tsv -- a
--    plausible syllabic shorthand, which the matcher handles well -- with one
--    letter then replaced by a keyboard neighbour.  This is what slip
--    tolerance (§4.5) exists for, and it is the class the case files cannot
--    contain, because a generator that produced them would be generating
--    noise.  Run with `cue_slip_cost` off and on.
--
-- Both draw from the same rank window as make_testset.py -- words ranked
-- 150-12,000, which is what people type -- and both are seeded, so the numbers
-- in ALGORITHM.md §5.2 and §5.3 can be reproduced rather than believed.

local root = arg[0]:match("^(.*)/bench/probe%.lua$") or "."
package.path = table.concat({
  root .. "/rime/lua/?.lua", root .. "/tests/?.lua", package.path }, ";")

local Engine = require("spellless.engine")

local seed = 20260906
local i = 1
while i <= #arg do
  if arg[i] == "--seed" then i = i + 1; seed = tonumber(arg[i]) or seed
  else error("unknown option " .. arg[i]) end
  i = i + 1
end
math.randomseed(seed)

local MIN_RANK, MAX_RANK = 150, 12000

-- Keyboard neighbours, the same map the typo generator uses: a slip is a
-- finger landing one key over, not a random letter.
local NEIGHBOURS = {
  a = "qwsz", b = "vghn", c = "xdfv", d = "serfcx", e = "wsdr", f = "drtgvc",
  g = "ftyhbv", h = "gyujnb", i = "ujko", j = "huikmn", k = "jiolm",
  l = "kop", m = "njk", n = "bhjm", o = "iklp", p = "ol", q = "wa",
  r = "edft", s = "awedxz", t = "rfgy", u = "yhji", v = "cfgb", w = "qase",
  x = "zsdc", y = "tghu", z = "asx",
}

local function words(engine)
  local out = {}
  for id = MIN_RANK, math.min(MAX_RANK, engine.corpus.n) do
    local w = engine.corpus.words[id]
    if w and w:find("^%a+$") then out[#out + 1] = w end
  end
  return out
end

--- Delete two characters of `word` at random, never the first.
local function delete_two(word)
  local chars = {}
  for c in word:gmatch(".") do chars[#chars + 1] = c end
  for _ = 1, 2 do
    local k = math.random(2, #chars)
    table.remove(chars, k)
  end
  return table.concat(chars)
end

--- Replace one character of `query` with a keyboard neighbour, never the
--- first: the cue channel requires the first letter, and a first-letter slip
--- is a different failure with a different answer (§8.9).
local function corrupt(query)
  if #query < 3 then return nil end
  for _ = 1, 8 do
    local k = math.random(2, #query)
    local n = NEIGHBOURS[query:sub(k, k)]
    if n then
      local r = n:sub(math.random(#n), math.random(#n))
      if r ~= "" then
        return query:sub(1, k - 1) .. r:sub(1, 1) .. query:sub(k + 1)
      end
    end
  end
  return nil
end

local function score(cases, config)
  local engine = assert(Engine.new{ data_dir = root .. "/generated",
                                    config = config })
  local none, first, page = 0, 0, 0
  for _, case in ipairs(cases) do
    local cands = engine:suggest(case.input, 20)
    local pos
    for k = 1, #cands do
      if cands[k].text:gsub("%s+$", "") == case.want then pos = k break end
    end
    -- The literal is always offered, so "nothing offered" means nothing but
    -- the literal: no reading of the input at all.
    if #cands <= 1 then none = none + 1 end
    if pos == 1 then first = first + 1 end
    if pos and pos <= 5 then page = page + 1 end
  end
  local n = #cases
  return { none = 100 * none / n, first = 100 * first / n, page = 100 * page / n }
end

local function report(title, cases, columns)
  print(("\n%s  (%d cases, seed %d)"):format(title, #cases, seed))
  local head = ("  %-26s"):format("")
  for _, c in ipairs(columns) do head = head .. ("%18s"):format(c.name) end
  print(head)
  local results = {}
  for k, c in ipairs(columns) do results[k] = score(cases, c.config) end
  for _, row in ipairs{ { "nothing offered at all", "none" },
                        { "right word first", "first" },
                        { "right word on page 1", "page" } } do
    local line = ("  %-26s"):format(row[1])
    for k = 1, #columns do
      line = line .. ("%17.1f%%"):format(results[k][row[2]])
    end
    print(line)
  end
end

local engine = assert(Engine.new{ data_dir = root .. "/generated" })
local pool = words(engine)

-- Probe 1: two deletions.
local deletions = {}
while #deletions < 261 do
  local w = pool[math.random(#pool)]
  if #w >= 7 then
    deletions[#deletions + 1] = { input = delete_two(w), want = w }
  end
end
report("Two letters deleted at random from a word of 7+ letters", deletions, {
  { name = "cue off", config = { cue_budget = 0, cue_slip_cost = 0 } },
  { name = "cue on",  config = {} },
})

-- Probe 2: a corrupted abbreviation.  The population is the cue case file
-- itself, so the only difference from a case the matcher answers at 88% is the
-- one wrong letter.
local corrupted = {}
for line in io.lines(root .. "/tests/cases/generated_cues.tsv") do
  if line ~= "" and line:sub(1, 1) ~= "#" then
    local input, want = line:match("^([^\t]+)\t([^\t]+)")
    if input and #input >= 5 then
      local bad = corrupt(input)
      if bad and bad ~= input then
        corrupted[#corrupted + 1] = { input = bad, want = want }
      end
    end
  end
end
report("A plausible shorthand with one letter mistyped", corrupted, {
  { name = "slip off", config = { cue_slip_cost = 0 } },
  { name = "slip on",  config = {} },
})
print()
