-- Ask the matcher what it would offer, without deploying anything.
--
--     lua bench/try.lua mathe recommned mthmtcs
--     lua bench/try.lua --sentence mathe        # as the first word of a sentence
--     lua bench/try.lua --n 12 --debug frm
--     echo "teh\nrecieve" | lua bench/try.lua   # one query per line
--
-- The literal-input candidate is marked with a dot.

local root = arg[0]:match("^(.*)/bench/try%.lua$") or "."
package.path = root .. "/rime/lua/?.lua;" .. package.path

local Engine = require("spellless.engine")

local queries, opts, n, debug_scores = {}, {}, 8, false
local i = 1
while i <= #arg do
  local a = arg[i]
  if a == "--sentence" then opts.sentence_start = true
  elseif a == "--debug" then debug_scores = true
  elseif a == "--n" then i = i + 1; n = tonumber(arg[i])
  else queries[#queries + 1] = a end
  i = i + 1
end
if #queries == 0 then
  for line in io.lines() do
    line = line:match("^%s*(.-)%s*$")
    if line ~= "" then queries[#queries + 1] = line end
  end
end

local engine = assert(Engine.new{ data_dir = root .. "/generated" })

for _, q in ipairs(queries) do
  local t = os.clock()
  local out = engine:suggest(q, n, opts)
  local ms = (os.clock() - t) * 1000
  io.write(("%-18s %5.1f ms\n"):format(q, ms))
  for j, c in ipairs(out) do
    local mark = c.raw and "." or " "
    if debug_scores then
      io.write(("  %s%d %-22s %-9s score %6.1f  cost %.2f\n")
               :format(mark, j, c.text, c.source, c.score, c.cost))
    else
      io.write(("  %s%d %s\n"):format(mark, j, c.text))
    end
  end
end
