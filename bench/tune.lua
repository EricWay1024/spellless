-- Coordinate descent over the ranking weights.
--
--     lua bench/tune.lua [passes]
--     lua bench/tune.lua 1 --exclude generated_cues   leave one file out
--     lua bench/tune.lua 1 --start midgrid --out /tmp/w.txt
--
-- The objective is a macro average over the case files (2*top-1 + top-5 +
-- in-rank), so the hand-written files are not drowned out by the 900 generated
-- ones.  This is a tool for choosing defaults, not part of the build: copy the
-- winning values into rime/lua/spellless/config.lua by hand.
--
-- The three options exist to measure the tuner rather than to use it.
--   --cases DIR    fit against case files from somewhere else
--   --exclude S    drop every case file whose path contains S from the
--                  objective, so it can be scored afterwards as held-out data
--                  (leave-one-file-out); repeatable
--   --start midgrid  begin from the middle of every grid instead of the
--                  shipped defaults, which is the only way to see how much of
--                  the shipped numbers coordinate descent is responsible for
--   --out FILE     write the winning values as `key=value` words, ready to
--                  paste after `--` on a bench/evaluate.lua command line

local root = arg[0]:match("^(.*)/bench/tune%.lua$") or "."
package.path = table.concat({
  root .. "/rime/lua/?.lua", root .. "/tests/?.lua", package.path }, ";")

local H = require("harness")
local Engine = require("spellless.engine")
local config = require("spellless.config")

local passes, cases_dir, excludes, start_at, out_path = 2, root .. "/tests/cases", {}, "defaults", nil
do
  local i = 1
  while i <= #arg do
    local a = arg[i]
    if a == "--cases" then i = i + 1; cases_dir = assert(arg[i], "--cases needs a directory")
    elseif a == "--exclude" then i = i + 1; excludes[#excludes + 1] = assert(arg[i], "--exclude needs a name")
    elseif a == "--start" then i = i + 1; start_at = assert(arg[i], "--start needs defaults|midgrid")
    elseif a == "--out" then i = i + 1; out_path = assert(arg[i], "--out needs a path")
    elseif tonumber(a) then passes = tonumber(a)
    else error("unknown argument " .. a) end
    i = i + 1
  end
  assert(start_at == "defaults" or start_at == "midgrid",
         "--start takes defaults or midgrid, not " .. start_at)
end

local files = {}
do
  local pipe = io.popen("ls " .. cases_dir .. "/*.tsv")
  for line in pipe:lines() do
    local skip = false
    for _, s in ipairs(excludes) do if line:find(s, 1, true) then skip = true end end
    if skip then print("held out: " .. line)
    else files[#files + 1] = { path = line, cases = H.load_cases(line) } end
  end
  pipe:close()
end
assert(#files > 0, "no case files in " .. cases_dir)

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
  base_cue          = { 46, 52, 58, 64, 70 },
  skeleton_vowel_bonus = { 0, 5, 10, 14, 18, 24 },
  cue_vowel_bonus   = { 0, 10, 20, 26, 30, 36 },
  cue_skip_vowel    = { 0.04, 0.08, 0.14, 0.22 },
  cue_skip_cluster  = { 0.20, 0.28, 0.35, 0.45, 0.60 },
  cue_skip_onset    = { 0.60, 0.75, 0.85, 1.00, 1.20 },
  cue_budget        = { 1.6, 1.9, 2.1, 2.4, 2.8 },
  typo_budget       = { 1.35, 1.5, 1.65, 1.8 },
  elastic_budget    = { 1.4, 1.7, 2.0 },
  user_weight       = { 18, 26, 34 },
  confidence_cost   = { 1.0, 1.2, 1.35, 1.5 },
  confidence_floor  = { 62, 66, 70 },
}
local ORDER = { "freq_weight", "cost_weight", "extra_weight", "base_prefix", "base_typo",
                "base_skeleton", "base_cue", "skeleton_vowel_bonus", "cue_vowel_bonus",
                "cue_skip_vowel", "cue_skip_cluster", "cue_skip_onset", "cue_budget",
                "typo_budget", "elastic_budget",
                "user_weight", "confidence_cost", "confidence_floor" }

local best = {}
for _, k in ipairs(ORDER) do
  if start_at == "midgrid" then
    -- The middle of each grid: the point someone would pick knowing only the
    -- range they thought plausible, and nothing about the cases.
    best[k] = GRID[k][math.ceil(#GRID[k] / 2)]
  else
    best[k] = config.defaults[k]
  end
end
local best_score = objective(best)
print(("start %.4f  (%s, %d files)"):format(best_score, start_at, #files))

for pass = 1, passes do
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

if out_path then
  local words = {}
  for _, k in ipairs(ORDER) do words[#words + 1] = ("%s=%s"):format(k, tostring(best[k])) end
  local fh = assert(io.open(out_path, "w"))
  fh:write(table.concat(words, " "), "\n")
  fh:close()
  print("\nwrote " .. out_path)
end
