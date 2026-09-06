-- Accuracy and latency of the matcher over tests/cases/*.tsv.
--
--     lua bench/evaluate.lua                 all case files
--     lua bench/evaluate.lua skeletons       only files matching a pattern
--     lua bench/evaluate.lua -- freq_weight=30 extra_weight=6
--     lua bench/evaluate.lua --cases DIR     case files from somewhere else
--
-- Everything after `--` overrides spellless.config, which is how the shipped
-- weights were chosen; see EVALUATION.md.
--
-- `--cases DIR` is what makes a held-out measurement possible at all: the
-- weights were fitted on the seed-20260904 draw in tests/cases, so pointing
-- this at a directory written by `make_testset.py --seed S --out DIR` for some
-- other S scores the unchanged weights on cases they have never seen.

local root = arg[0]:match("^(.*)/bench/evaluate%.lua$") or "."
package.path = table.concat({
  root .. "/rime/lua/?.lua", root .. "/tests/?.lua", package.path }, ";")

local H = require("harness")
local Engine = require("spellless.engine")

-- ---------------------------------------------------------------------------
-- arguments
-- ---------------------------------------------------------------------------
local filter, overrides, after_dashes = nil, {}, false
local cases_dir = root .. "/tests/cases"
local i = 1
while i <= #arg do
  local a = arg[i]
  if a == "--" then after_dashes = true
  elseif after_dashes then
    local k, v = a:match("^([%w_]+)=(.+)$")
    if not k then error("cannot parse override " .. a) end
    overrides[k] = tonumber(v) or (v == "true") or (v ~= "false" and v or false)
  elseif a == "--cases" then
    i = i + 1
    cases_dir = arg[i] or error("--cases needs a directory")
  else
    local dir = a:match("^%-%-cases=(.+)$")
    if dir then cases_dir = dir
    elseif a:sub(1, 2) == "--" then error("unknown option " .. a)
    else filter = a end
  end
  i = i + 1
end
cases_dir = cases_dir:gsub("/+$", "")

-- ---------------------------------------------------------------------------
-- case files
-- ---------------------------------------------------------------------------
local function case_files()
  local out = {}
  -- io.popen keeps this portable enough for a dev-machine benchmark; the test
  -- runner uses an explicit list instead.
  local pipe = io.popen("ls " .. cases_dir .. "/*.tsv 2>/dev/null")
  for line in pipe:lines() do
    if not filter or line:find(filter, 1, true) then out[#out + 1] = line end
  end
  pipe:close()
  table.sort(out)
  return out
end

local engine = assert(Engine.new{ data_dir = root .. "/generated", config = overrides })

local clock = os.clock
local function percentile(t, p)
  table.sort(t)
  return t[math.max(1, math.ceil(#t * p))] or 0
end

local totals = { n = 0, top1 = 0, top5 = 0, pass = 0 }
local latencies = {}
local groups, group_order = {}, {}

if cases_dir ~= root .. "/tests/cases" then print("cases from " .. cases_dir) end
print(("%-28s %6s %7s %7s %7s"):format("file", "cases", "top-1", "top-5", "in-rank"))
print(("-"):rep(60))

local failures = {}
for _, path in ipairs(case_files()) do
  local cases = H.load_cases(path)
  local n, top1, top5, pass = 0, 0, 0, 0
  for _, case in ipairs(cases) do
    local t = clock()
    local cands = engine:suggest(case.input, 20)
    latencies[#latencies + 1] = (clock() - t) * 1000
    local pos = H.position(cands, case)
    n = n + 1
    if case.group then
      local g = groups[case.group]
      if not g then
        g = { n = 0, top1 = 0, top5 = 0 }
        groups[case.group] = g
        group_order[#group_order + 1] = case.group
      end
      g.n = g.n + 1
      if pos == 1 then g.top1 = g.top1 + 1 end
      if pos and pos <= 5 then g.top5 = g.top5 + 1 end
    end
    if not case.negate then
      if pos == 1 then top1 = top1 + 1 end
      if pos and pos <= 5 then top5 = top5 + 1 end
      if pos and pos <= case.rank then pass = pass + 1
      else failures[#failures + 1] = { case = case, pos = pos, cands = cands } end
    else
      if not pos or pos > case.rank then pass = pass + 1
      else failures[#failures + 1] = { case = case, pos = pos, cands = cands } end
    end
  end
  totals.n = totals.n + n; totals.top1 = totals.top1 + top1
  totals.top5 = totals.top5 + top5; totals.pass = totals.pass + pass
  print(("%-28s %6d %6.1f%% %6.1f%% %6.1f%%"):format(
        path:match("[^/]+$"), n, 100 * top1 / n, 100 * top5 / n, 100 * pass / n))
end

print(("-"):rep(60))
print(("%-28s %6d %6.1f%% %6.1f%% %6.1f%%"):format("TOTAL", totals.n,
      100 * totals.top1 / totals.n, 100 * totals.top5 / totals.n,
      100 * totals.pass / totals.n))

if #group_order > 0 then
  table.sort(group_order)
  print("\nby group")
  for _, name in ipairs(group_order) do
    local g = groups[name]
    print(("%-28s %6d %6.1f%% %6.1f%%"):format(
          "  " .. name, g.n, 100 * g.top1 / g.n, 100 * g.top5 / g.n))
  end
end

local sum = 0
for _, v in ipairs(latencies) do sum = sum + v end
print(("\nlatency  mean %.2f ms   median %.2f ms   p95 %.2f ms   max %.2f ms  (n=%d)")
      :format(sum / #latencies, percentile(latencies, 0.5),
              percentile(latencies, 0.95), percentile(latencies, 1.0), #latencies))

-- The number that actually matters: what one keystroke costs while a word is
-- being typed out, prefix by prefix, which is how the IME is really used.
do
  local words = { "the", "mathematics", "recommendation", "theorem", "receive",
                  "separate", "topology", "diffeomorphism", "stratification" }
  local by_len, total, count = {}, 0, 0
  for _, w in ipairs(words) do
    for i = 1, #w do
      local t = clock()
      engine:suggest(w:sub(1, i), 20)
      local dt = (clock() - t) * 1000
      total, count = total + dt, count + 1
      by_len[i] = by_len[i] or { sum = 0, n = 0 }
      by_len[i].sum = by_len[i].sum + dt
      by_len[i].n = by_len[i].n + 1
    end
  end
  print(("\ntyping %d words out, one keystroke at a time: %.2f ms mean over %d keystrokes")
        :format(#words, total / count, count))
  local parts = {}
  for i = 1, 14 do
    if by_len[i] then parts[#parts + 1] = ("%d:%.1f"):format(i, by_len[i].sum / by_len[i].n) end
  end
  print("  mean ms by input length -- " .. table.concat(parts, "  "))
end

collectgarbage("collect")
print(("\nresident after %d queries: %.1f MB"):format(#latencies, collectgarbage("count") / 1024))

if os.getenv("SHOW_FAILURES") then
  print("\nfailures:")
  for i = 1, math.min(#failures, tonumber(os.getenv("SHOW_FAILURES")) or 30) do
    local f = failures[i]
    local got = {}
    for j = 1, math.min(#f.cands, 6) do got[j] = f.cands[j].text end
    print(("  %-18s want %-24s at<=%d, got %s | %s"):format(
          f.case.input, table.concat(f.case.alts, "|"), f.case.rank,
          tostring(f.pos), table.concat(got, " ")))
  end
end
