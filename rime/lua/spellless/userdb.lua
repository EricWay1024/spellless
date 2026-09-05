-- The user's personal vocabulary and selection history.
--
-- Rime's own user dictionary learns (code, text) pairs produced by a
-- dictionary-backed translator.  Our candidates are synthesised in Lua and are
-- not dictionary phrases, so there is nothing for `Memory:memorize` to record
-- (see DESIGN.md, "Why not the native user dictionary").  Instead we keep a
-- plain text file next to the schema, which has the side benefit of being the
-- same format as a hand-written supplemental vocabulary list.
--
-- Format, one entry per line:
--     word <TAB> count
--     word <TAB> surface form <TAB> count
--
-- The middle column remembers how you actually wrote it, so committing
-- "Grothendieck" once means "grthndck" gives it back capitalised rather than
-- as "grothendieck".  Two-column lines are still read, so an older file and a
-- hand-written one both work; '#' comments and count-less lines too.  The file
-- is rewritten sorted by descending count.

local util = require("spellless.util")

local UserDB = {}
UserDB.__index = UserDB

local log = math.log

-- One store per file, shared across engines.
--
-- librime runs one Lua state per process but one engine per input context, so
-- typing in two applications would otherwise give two in-memory copies of the
-- same file -- and whichever flushed last would silently drop what the other
-- had learned.
local cache = {}

--- Drop the memoised store for `path` (tests only).
function UserDB.forget(path)
  cache[path] = nil
end

--- `cfg` is accepted for symmetry with the other modules but deliberately not
--- stored: the store is shared between engines, and keeping one engine's
--- saturation or flush policy on it would silently apply that policy to every
--- other engine.  Both are passed in by the caller instead.
function UserDB.load(path, cfg)
  if path and path ~= "" and cache[path] then return cache[path] end
  local self = setmetatable({
    path = path,
    counts = {},
    surfaces = {},
    order = {},
    dirty = 0,
    -- Bumped on every change so callers can invalidate caches cheaply.
    dirty_stamp = 0,
  }, UserDB)

  local blob = path and path ~= "" and util.slurp(path) or nil
  if blob then
    for line in blob:gmatch("[^\r\n]+") do
      if line:sub(1, 1) ~= "#" then
        local fields = {}
        for field in (line .. "\t"):gmatch("([^\t]*)\t") do
          fields[#fields + 1] = field:match("^%s*(.-)%s*$")
        end
        local word = fields[1]
        if word and word ~= "" then
          local surface, count
          if fields[3] and fields[3] ~= "" then
            surface, count = fields[2], tonumber(fields[3])
          else
            count = tonumber(fields[2])
            -- A one-column entry written with capitals is its own spelling --
            -- "Hausdorff" in a hand-edited file means Hausdorff, exactly as it
            -- does in data/vocab/.
            if word ~= word:lower() then surface = word end
          end
          self:set(word:lower(), count or 1, surface)
        end
      end
    end
  end
  if path and path ~= "" then cache[path] = self end
  return self
end

--- `surface`: a string to remember, false to forget one, nil to leave it be.
function UserDB:set(word, count, surface)
  if self.counts[word] == nil then self.order[#self.order + 1] = word end
  self.counts[word] = count
  if surface == false then
    self.surfaces[word] = nil
  elseif surface and surface ~= "" and surface ~= word then
    self.surfaces[word] = surface
  end
  self.dirty_stamp = self.dirty_stamp + 1
  self.selection = nil
end

--- Drop a word from the store completely: its count, its spelling, and its
--- place in the scan order.
---
--- This is the undo for learning.  A word learned by accident -- a typo
--- committed literally, a name that was really a mistake -- otherwise leads
--- the list for good, and there would be no way back except editing the file
--- by hand.  Returns true if there was anything to forget.
function UserDB:forget_word(word)
  if self.counts[word] == nil then return false end
  self.counts[word] = nil
  self.surfaces[word] = nil
  for i = 1, #self.order do
    if self.order[i] == word then
      table.remove(self.order, i)
      break
    end
  end
  self.dirty = self.dirty + 1
  self.dirty_stamp = self.dirty_stamp + 1
  self.selection = nil
  return true
end

--- Forget how a word is spelled, keeping its count.
function UserDB:forget_surface(word)
  if self.surfaces[word] then
    self.surfaces[word] = nil
    self.dirty = self.dirty + 1
    self.dirty_stamp = self.dirty_stamp + 1
  end
end

--- How the user last wrote this word, if that was not simply lower case.
function UserDB:surface(word)
  return self.surfaces[word]
end

function UserDB:count(word)
  return self.counts[word] or 0
end

--- Personal frequency on a 0..1 scale.  Logarithmic so the first couple of
--- selections move a word a lot and the hundredth barely moves it at all.
--- `saturation` is the caller's, for the reason given on `UserDB.load`.
function UserDB:score(word, saturation)
  local c = self.counts[word]
  if not c or c <= 0 then return 0 end
  local s = log(1 + c) / log(1 + saturation)
  return s > 1 and 1 or s
end

--- Remember that the user chose `word`, written as `surface`.
--- `surface` of nil leaves any stored spelling alone; false clears it.
--- Returns how many changes are now unsaved, so the caller can apply its own
--- flush policy.
function UserDB:record(word, surface)
  self:set(word, self:count(word) + 1, surface)
  self.dirty = self.dirty + 1
  return self.dirty
end

--- The words the matcher compares every query against, capped at `limit`.
---
--- The matcher runs a small linear pass over these on every query.  That
--- covers two things at once: words the static corpus has never heard of
--- become candidates as soon as they are committed once, and words the corpus
--- does know cannot be crowded out of a frequency-ranked shortlist by more
--- common but unwanted neighbours.
---
--- When there are more than `limit`, the ones kept are those chosen most
--- often.  Taking the tail of insertion order instead would be actively
--- perverse: the file is written back sorted by descending count, so after a
--- restart the tail is the words you have used *least*.
function UserDB:words(limit)
  local n = #self.order
  if not limit or n <= limit then return self.order end
  if self.selection and self.selection.limit == limit then return self.selection.words end

  local ranked = {}
  for i = 1, n do ranked[i] = self.order[i] end
  local counts = self.counts
  table.sort(ranked, function(a, b)
    if counts[a] ~= counts[b] then return counts[a] > counts[b] end
    return a < b
  end)
  local out = table.move(ranked, 1, limit, 1, {})
  self.selection = { limit = limit, words = out }
  return out
end

function UserDB:flush()
  if self.dirty == 0 then return true end
  if not self.path or self.path == "" then self.dirty = 0 return true end
  local words = {}
  for i = 1, #self.order do words[i] = self.order[i] end
  table.sort(words, function(a, b)
    local ca, cb = self.counts[a], self.counts[b]
    if ca ~= cb then return ca > cb end
    return a < b
  end)

  local fh, err = io.open(self.path, "wb")
  if not fh then return false, err end
  fh:write("# spellless personal vocabulary\n")
  fh:write("#   word <TAB> times selected\n")
  fh:write("#   word <TAB> how you write it <TAB> times selected\n")
  fh:write("# Edit freely; unknown words listed here become candidates.\n")
  for i = 1, #words do
    local word = words[i]
    local surface = self.surfaces[word]
    if surface then
      fh:write(word, "\t", surface, "\t", tostring(self.counts[word]), "\n")
    else
      fh:write(word, "\t", tostring(self.counts[word]), "\n")
    end
  end
  fh:close()
  self.dirty = 0
  return true
end

return UserDB
