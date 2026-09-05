-- Small helpers shared by the Spellless modules.  Nothing in here touches the
-- Rime API, so the whole matching core stays testable under a plain `lua`.

local M = {}

--- Read a whole file as a byte string, or return nil plus a message.
function M.slurp(path)
  local fh, err = io.open(path, "rb")
  if not fh then return nil, err end
  local data = fh:read("a")
  fh:close()
  return data
end

--- Join path fragments.  Windows accepts '/' in every CRT call we make, so we
--- do not need to care which separator `rime_api.get_user_data_dir()` returned.
function M.join(...)
  local parts = { ... }
  local out = parts[1] or ""
  for i = 2, #parts do
    out = out:gsub("[/\\]+$", "") .. "/" .. parts[i]
  end
  return out
end

function M.exists(path)
  local fh = io.open(path, "rb")
  if fh then fh:close() return true end
  return false
end

-- Population count for the 26-bit letter masks, as two 13-bit table lookups.
-- 8192 array slots cost about 70 kB and roughly a millisecond to fill, and it
-- turns the scan prefilter into five arithmetic operations with no branches.
local POPCOUNT = {}
for i = 0, 8191 do
  local n, v = 0, i
  while v ~= 0 do n = n + 1; v = v & (v - 1) end
  POPCOUNT[i] = n
end

--- Number of set bits in a 26-bit mask.
function M.popcount26(x)
  return POPCOUNT[x & 8191] + POPCOUNT[x >> 13]
end
M.POPCOUNT = POPCOUNT

--- Bounded "keep the n smallest" selector.
--- Push items with a numeric key, then walk them with `each` (unordered).
--- Used to pull the most frequent words out of a big index range without
--- sorting the range: word ids are frequency ranks, so smaller is better.
local Top = {}
Top.__index = Top

function M.top(n)
  return setmetatable({ n = math.max(1, n), size = 0, keys = {}, vals = {},
                        worst = math.huge }, Top)
end

function Top:push(key, val)
  if self.size < self.n then
    self.size = self.size + 1
    self.keys[self.size], self.vals[self.size] = key, val
    if self.size == self.n then
      self.worst = -math.huge
      for i = 1, self.size do
        if self.keys[i] > self.worst then self.worst = self.keys[i] end
      end
    end
    return true
  end
  if key >= self.worst then return false end
  -- Replace the current worst.  n is a dozen or so, so one linear pass that
  -- also tracks the runner-up beats any heap bookkeeping.
  local wi, worst, second = 1, -math.huge, -math.huge
  for i = 1, self.size do
    local k = self.keys[i]
    if k > worst then wi, worst, second = i, k, worst
    elseif k > second then second = k end
  end
  self.keys[wi], self.vals[wi] = key, val
  self.worst = key > second and key or second
  return true
end

function Top:each(fn)
  for i = 1, self.size do fn(self.vals[i], self.keys[i]) end
end

return M
