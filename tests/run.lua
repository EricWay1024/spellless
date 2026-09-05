-- Test entry point.  Run from the repository root:
--     lua tests/run.lua
local root = arg[0]:match("^(.*)/tests/run%.lua$") or "."
package.path = table.concat({
  root .. "/rime/lua/?.lua",
  root .. "/tests/?.lua",
  package.path,
}, ";")
_G.SPELLLESS_ROOT = root

local H = require("harness")
local suites = { "test_distance", "test_preceding", "test_skeleton", "test_userdb", "test_engine", "test_adapter", "test_cases" }
for _, name in ipairs(suites) do
  require(name)
end
H.finish()
