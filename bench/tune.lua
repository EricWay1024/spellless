-- Coordinate descent over the ranking weights.
--
--     lua bench/tune.lua [passes]
--
-- The objective is a macro average over the case files (2*top-1 + top-5 +
-- in-rank), so the hand-written files are not drowned out by the 900 generated
-- ones.  This is a tool for choosing defaults, not part of the build: copy the
-- winning values into rime/lua/spellless/config.lua by hand.

local root = arg[0]:match("^(.*)/bench/tune%.lua$") or "."
package.path = table.concat({
  root .. "/rime/lua/?.lua", root .. "/tests/?.lua", package.path }, ";")

local H = require("harness")
local Engine = require("spellless.engine")
local config = require("spellless.config")

local files = {}
do
  local pipe = io.popen("ls " .. root .. "/tests/cases/*.tsv")
  for line in pipe:lines() do files[#files + 1] = { path = line, cases = H.load_cases(line) } end
  pipe:close()
end

local function objective(overrides)
  local engine = assert(Engine.new{ data_dir = root .. "/generated", config = overrides })
  local total = 0
  for _, f in ipairs(files) do
    local top1, top5, pass = 0, 0, 0
    for _, case in ipairs(f.cases) do
      local pos = H.position(engine:suggest(case.input, 20), case)
      if case.negate then
        if not pos or pos > case.rank then pass = pass + 1 end
      else
        if pos == 1 then top1 = top1 + 1 end
        if pos and pos <= 5 then top5 = top5 + 1 end
        if pos and pos <= case.rank then pass = pass + 1 end
      end
    end
    local n = #f.cases
    total = total + (2 * top1 + top5 + pass) / n
  end
  return total / #files
end

-- Values to try for each weight, in the order coordinate descent visits them.
local GRID = {
  freq_weight       = { 14, 18, 22, 26, 30, 34 },
  cost_weight       = { 10, 13, 16, 19, 22, 26 },
  extra_weight      = { 4, 6, 8, 10, 12, 16 },
  base_prefix       = { 74, 77, 80, 83, 86 },
  base_typo         = { 66, 69, 72, 75, 78 },
  base_skeleton     = { 62, 66, 70, 74, 78 },
  skeleton_vowel_bonus = { 0, 5, 10, 14, 18, 24 },
  typo_budget       = { 1.35, 1.5, 1.65, 1.8 },
  elastic_budget    = { 1.4, 1.7, 2.0 },
  user_weight       = { 18, 26, 34 },
  confidence_cost   = { 1.0, 1.2, 1.35, 1.5 },
  confidence_floor  = { 62, 66, 70 },
}
local ORDER = { "freq_weight", "cost_weight", "extra_weight", "base_prefix", "base_typo",
                "base_skeleton", "skeleton_vowel_bonus", "typo_budget", "elastic_budget",
                "user_weight", "confidence_cost", "confidence_floor" }

local best = {}
for _, k in ipairs(ORDER) do best[k] = config.defaults[k] end
local best_score = objective(best)
print(("start %.4f"):format(best_score))

for pass = 1, tonumber(arg[1] or 2) do
  for _, key in ipairs(ORDER) do
    local keep, keep_score = best[key], best_score
    for _, v in ipairs(GRID[key]) do
      if v ~= best[key] then
        local trial = {}
        for k, x in pairs(best) do trial[k] = x end
        trial[key] = v
        local s = objective(trial)
        if s > keep_score then keep, keep_score = v, s end
      end
    end
    if keep ~= best[key] then
      print(("pass %d  %-22s %s -> %s   %.4f"):format(pass, key, tostring(best[key]), tostring(keep), keep_score))
      best[key], best_score = keep, keep_score
    end
  end
end

print(("\nbest %.4f"):format(best_score))
for _, k in ipairs(ORDER) do print(("  %-22s = %s"):format(k, tostring(best[k]))) end
