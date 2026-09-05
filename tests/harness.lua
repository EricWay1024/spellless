-- A very small test runner: no dependencies, readable failures.
local H = { failures = 0, checks = 0, current = "?" }

local function fail(msg, level)
  H.failures = H.failures + 1
  io.write(("  FAIL [%s] %s\n"):format(H.current, msg))
  if level then io.write(debug.traceback("", level + 1), "\n") end
end

function H.suite(name) H.current = name; io.write(name, "\n") end

function H.ok(cond, msg)
  H.checks = H.checks + 1
  if not cond then fail(msg or "expected true", 2) end
end

function H.eq(got, want, msg)
  H.checks = H.checks + 1
  if got ~= want then
    fail(("%s: got %s, want %s"):format(msg or "values differ",
         tostring(got), tostring(want)), 2)
  end
end

function H.near(got, want, tol, msg)
  H.checks = H.checks + 1
  if got == nil or math.abs(got - want) > (tol or 1e-9) then
    fail(("%s: got %s, want %s +/- %s"):format(msg or "values differ",
         tostring(got), tostring(want), tostring(tol)), 2)
  end
end

function H.finish()
  io.write(("\n%d checks, %d failures\n"):format(H.checks, H.failures))
  os.exit(H.failures == 0 and 0 or 1)
end

--- Read a `tests/cases/*.tsv` file.
--- Columns: input <TAB> expected <TAB> max_rank [<TAB> group]
--- `group` is an optional label used to break the results down by error kind.
--- `expected` may list alternatives separated by '|'; the literal `=raw`
--- means "the untouched input must be the candidate at that rank"; a leading
--- '!' means "must NOT appear at or above that rank".
function H.load_cases(path)
  local cases = {}
  local fh = assert(io.open(path, "r"), "cannot open " .. path)
  local lineno = 0
  for line in fh:lines() do
    lineno = lineno + 1
    line = line:gsub("#.*$", ""):gsub("%s+$", "")
    if line ~= "" then
      local input, expected, rank, group =
          line:match("^([^\t]+)\t([^\t]+)\t*(%d*)\t?([%w_]*)$")
      assert(input, ("%s:%d: cannot parse %q"):format(path, lineno, line))
      local negate = expected:sub(1, 1) == "!"
      if negate then expected = expected:sub(2) end
      local alts = {}
      for alt in expected:gmatch("[^|]+") do alts[#alts + 1] = alt end
      cases[#cases + 1] = {
        input = input, alts = alts, negate = negate,
        rank = tonumber(rank) or 1, group = (group ~= "" and group or nil),
        file = path, line = lineno,
      }
    end
  end
  fh:close()
  return cases
end

--- Position of the first accepted answer in `candidates`, or nil.
function H.position(candidates, case)
  for i = 1, #candidates do
    local text = candidates[i].text
    for _, alt in ipairs(case.alts) do
      if alt == "=raw" then
        if candidates[i].raw or text == case.input then return i end
      elseif text == alt then
        return i
      end
    end
  end
  return nil
end

return H
