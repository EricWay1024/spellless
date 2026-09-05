-- The behavioural test: every hand-written case must hold, and the generated
-- sets must not regress.  bench/evaluate.lua prints the same numbers in more
-- detail and is the tool for tuning; this file is the tripwire.

local H = require("harness")
local Engine = require("spellless.engine")

local CASES = _G.SPELLLESS_ROOT .. "/tests/cases/"
local engine = assert(Engine.new{ data_dir = _G.SPELLLESS_ROOT .. "/generated" })

-- Hand-written files: every single case has to pass.
local STRICT = { "spec_examples.tsv", "common_typos.tsv", "skeletons.tsv",
                 "prefix.tsv", "ambiguity.tsv", "raw.tsv", "forms.tsv", "literal.tsv" }

-- Generated files: floors, a few points below what the shipped weights score,
-- so ordinary tuning does not trip the build but a real regression does.
local FLOORS = {
  ["generated_typos.tsv"]     = { top1 = 0.80, top5 = 0.94 },
  ["generated_skeletons.tsv"] = { top1 = 0.80, top5 = 0.95 },
}

local function evaluate(name)
  local cases = H.load_cases(CASES .. name)
  local top1, top5, failed = 0, 0, {}
  for _, case in ipairs(cases) do
    local pos = H.position(engine:suggest(case.input, 20), case)
    local ok
    if case.negate then
      ok = not pos or pos > case.rank
    else
      ok = pos and pos <= case.rank
      if pos == 1 then top1 = top1 + 1 end
      if pos and pos <= 5 then top5 = top5 + 1 end
    end
    if not ok then
      failed[#failed + 1] = ("%s:%d  %q wanted %s at<=%d, got %s"):format(
        name, case.line, case.input, table.concat(case.alts, "|"),
        case.rank, tostring(pos))
    end
  end
  return #cases, top1, top5, failed
end

for _, name in ipairs(STRICT) do
  H.suite("cases: " .. name)
  local n, _, _, failed = evaluate(name)
  H.eq(#failed, 0, ("%d/%d cases failed"):format(#failed, n))
  for _, line in ipairs(failed) do io.write("    ", line, "\n") end
end

for name, floor in pairs(FLOORS) do
  H.suite("cases: " .. name)
  local n, top1, top5 = evaluate(name)
  H.ok(top1 / n >= floor.top1,
       ("top-1 %.1f%% (floor %.0f%%)"):format(100 * top1 / n, 100 * floor.top1))
  H.ok(top5 / n >= floor.top5,
       ("top-5 %.1f%% (floor %.0f%%)"):format(100 * top5 / n, 100 * floor.top5))
end

H.suite("cases: latency")
-- Deliberately loose: this catches an accidental full-dictionary scan, not a
-- slow machine.
local clock, worst = os.clock, 0
for _, name in ipairs{ "spec_examples.tsv", "skeletons.tsv", "common_typos.tsv" } do
  for _, case in ipairs(H.load_cases(CASES .. name)) do
    local t = clock()
    engine:suggest(case.input, 20)
    local dt = (clock() - t) * 1000
    if dt > worst then worst = dt end
  end
end
H.ok(worst < 120, ("worst single query %.1f ms"):format(worst))
