-- What one previous word, read as a coarse part of speech, is actually worth.
--
--     lua bench/context.lua
--     lua bench/context.lua -- context_weight=8 context_margin=20
--
-- Three measurements, in increasing order of how much they should be believed:
--
--   1. bench/context_cases.tsv -- forty morphological-sibling failures with a
--      previous word written by hand, plus controls.  Hand-written contexts
--      measure the author's intuitions about English at least as much as they
--      measure the feature; see the header of that file for what was done to
--      limit that, and read the number with suspicion regardless.
--
--   2. The battery: every case in tests/cases/*.tsv, run again under each of
--      six fixed previous words.  Nothing here is chosen, so nothing here can
--      be gamed.  Many of the resulting contexts are absurd for the word in
--      question, which overstates the damage -- which is the right direction
--      for a number whose job is to decide whether the thing ships.
--
--   3. Latency, with the flag off and on.
--
-- The flag is off by default, so `lua bench/evaluate.lua` is unaffected by any
-- of this and is the number that still governs.
--
-- The verdict, at the shipped constants: the hand-written cases fix 5 of 40
-- sibling failures and demote none of 37 controls, which looks like a small
-- win; the battery fixes 9 and breaks 29 after "the", and is net negative for
-- every previous word at every weight and margin tried.  Believe the battery.
-- The difference between the two numbers is the difference between contexts
-- chosen for the words and words chosen for the contexts.

local root = arg[0]:match("^(.*)/bench/context%.lua$") or "."
package.path = table.concat({
  root .. "/rime/lua/?.lua", root .. "/tests/?.lua", package.path }, ";")

local H = require("harness")
local Engine = require("spellless.engine")
local preceding = require("spellless.preceding")

local overrides, after_dashes = {}, false
for i = 1, #arg do
  local a = arg[i]
  if a == "--" then after_dashes = true
  elseif after_dashes then
    local k, v = a:match("^([%w_]+)=(.+)$")
    if not k then error("cannot parse override " .. a) end
    overrides[k] = tonumber(v) or (v == "true") or (v ~= "false" and v or false)
  end
end
overrides.context_class = true

local engine = assert(Engine.new{ data_dir = root .. "/generated", config = overrides })
local plain = assert(Engine.new{ data_dir = root .. "/generated" })

--- `_` stands for a space and `-` for nothing, so the file stays a clean TSV.
local function behind_text(field)
  if field == "-" then return "" end
  return (field:gsub("_", " "))
end

local function rank_of(cands, want)
  for i = 1, #cands do
    if want == "=raw" then
      if cands[i].raw or cands[i].text == want then return i end
    elseif cands[i].text == want then
      return i
    end
  end
  return nil
end

local function same_list(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i].text ~= b[i].text or a[i].score ~= b[i].score
       or a[i].source ~= b[i].source then return false end
  end
  return true
end

-- ---------------------------------------------------------------------------
-- 1. the hand-written cases
-- ---------------------------------------------------------------------------
local rows = {}
for line in io.lines(root .. "/bench/context_cases.tsv") do
  line = line:gsub("#.*$", ""):gsub("%s+$", "")
  if line ~= "" then
    local kind, behind, input, want = line:match("^(%a+)\t(%S+)\t(%S+)\t(%S+)$")
    assert(kind, "cannot parse " .. line)
    rows[#rows + 1] = { kind = kind, behind = behind, input = input, want = want }
  end
end

print("1. hand-written contextual cases")
print(("   %-10s %-12s %-14s %-16s %s"):format(
      "behind", "input", "wanted", "prev word", "rank  no-ctx -> ctx"))

local tally = {}
local function bump(k) tally[k] = (tally[k] or 0) + 1 end
local notes = {}

for _, r in ipairs(rows) do
  local text = behind_text(r.behind)
  local prev = preceding.previous_word(text)
  local before = plain:suggest(r.input, 20)
  local after = engine:suggest(r.input, 20, { previous_word = prev })

  if r.want == "=same" then
    local ok = same_list(before, after)
    bump(ok and "null_ok" or "null_broken")
    if not ok then
      notes[#notes + 1] = ("   NULL BROKEN  %-10s %-12s prev=%s")
                          :format(r.behind, r.input, tostring(prev))
    end
  else
    local a, b = rank_of(before, r.want), rank_of(after, r.want)
    local verdict
    if b == 1 and a ~= 1 then verdict = "FIXED"
    elseif a == 1 and b ~= 1 then verdict = "BROKEN"
    elseif a == b then verdict = "same"
    elseif b and a and b < a then verdict = "up"
    else verdict = "down" end
    bump(r.kind .. "_" .. verdict)
    if verdict ~= "same" or r.kind == "fix" then
      print(("   %-10s %-12s %-14s %-16s %s -> %s  %s"):format(
            r.behind, r.input, r.want, tostring(prev),
            tostring(a), tostring(b), verdict == "same" and "" or verdict))
    end
  end
end
for _, n in ipairs(notes) do print(n) end

local function count(k) return tally[k] or 0 end
print()
print(("   fix   : %d of %d sibling failures now lead  (%d moved up, %d unchanged, %d worse)")
      :format(count("fix_FIXED"),
              count("fix_FIXED") + count("fix_up") + count("fix_same")
              + count("fix_down") + count("fix_BROKEN"),
              count("fix_up"), count("fix_same"),
              count("fix_down") + count("fix_BROKEN")))
print(("   keep  : %d demoted from first, %d still first, %d other movement")
      :format(count("keep_BROKEN"), count("keep_same"),
              count("keep_up") + count("keep_down") + count("keep_FIXED")))
print(("   null  : %d of %d contexts left the list untouched")
      :format(count("null_ok"), count("null_ok") + count("null_broken")))

-- ---------------------------------------------------------------------------
-- 2. the battery
-- ---------------------------------------------------------------------------
local BATTERY = { "the", "a", "of", "to", "very", "and" }

local files = {}
local pipe = io.popen("ls " .. root .. "/tests/cases/*.tsv 2>/dev/null")
for line in pipe:lines() do files[#files + 1] = line end
pipe:close()
table.sort(files)

local cases = {}
for _, path in ipairs(files) do
  for _, case in ipairs(H.load_cases(path)) do
    if not case.negate then cases[#cases + 1] = case end
  end
end

print()
print(("2. battery: all %d cases under each of six fixed previous words"):format(#cases))
print(("   %-6s %8s %8s %8s %8s"):format("prev", "fixed", "broken", "net", "top-1"))

local baseline_top1 = 0
local base_pos = {}
for i, case in ipairs(cases) do
  local pos = H.position(plain:suggest(case.input, 20), case)
  base_pos[i] = pos
  if pos == 1 then baseline_top1 = baseline_top1 + 1 end
end
print(("   %-6s %8s %8s %8s %7.1f%%"):format("none", "-", "-", "-",
      100 * baseline_top1 / #cases))

local worst = { name = nil, broken = -1 }
for _, prev in ipairs(BATTERY) do
  local fixed, broken, top1 = 0, 0, 0
  for i, case in ipairs(cases) do
    local pos = H.position(engine:suggest(case.input, 20, { previous_word = prev }), case)
    if pos == 1 then top1 = top1 + 1 end
    if pos == 1 and base_pos[i] ~= 1 then fixed = fixed + 1 end
    if pos ~= 1 and base_pos[i] == 1 then broken = broken + 1 end
  end
  if broken > worst.broken then worst = { name = prev, broken = broken } end
  print(("   %-6s %8d %8d %8d %7.1f%%"):format(
        prev, fixed, broken, fixed - broken, 100 * top1 / #cases))
end

-- ---------------------------------------------------------------------------
-- 3. latency
-- ---------------------------------------------------------------------------
-- Alternating rounds, best of four, because a single pass puts all of the
-- cache warm-up on whichever arm runs first and that is worth more than the
-- effect being measured.
local arms = {
  { "flag off               ", plain, nil },
  { "flag on, no prev word  ", engine, {} },
  { "flag on, prev = elephant", engine, { previous_word = "elephant" } },
  { "flag on, prev = the    ", engine, { previous_word = "the" } },
}
local best = {}
for _ = 1, 4 do
  for i, arm in ipairs(arms) do
    local t = os.clock()
    for _, case in ipairs(cases) do arm[2]:suggest(case.input, 20, arm[3]) end
    local ms = (os.clock() - t) * 1000 / #cases
    if not best[i] or ms < best[i] then best[i] = ms end
  end
end

print()
print("3. latency, mean ms per query, best of four alternating rounds")
for i, arm in ipairs(arms) do
  print(("   %s  %.3f ms  (%+.1f%%)")
        :format(arm[1], best[i], 100 * (best[i] / best[1] - 1)))
end
print("   -- the whole effect is one wordclass.of() per candidate within the")
print("      margin, at most 20 of them, and on an ordinary machine it does not")
print("      clear the noise floor of about 5%.  Read a negative number as 0.")
