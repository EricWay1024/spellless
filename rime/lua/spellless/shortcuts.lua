-- Abbreviations you define yourself: "bc" -> "because", "ppl" -> "people".
--
-- The matcher already reconstructs a word from its consonants, which covers a
-- great many abbreviations without being told: "ppl" finds "people" because
-- that *is* people's skeleton.  What it cannot do is honour a habit.  "bc" is
-- two letters, and at two letters almost every word in the language is a
-- plausible completion, so the skeleton sources deliberately stay quiet -- see
-- min_skeleton_completion_len.  No amount of tuning fixes that, because the
-- information simply is not in the input.  It is in your head.
--
-- So this is a list, and a list is the honest answer: an exact match on the
-- left gives the text on the right, at the top, ahead of everything the
-- matcher inferred.
--
-- Format, one per line, tab or whitespace separated:
--
--     bc      because
--     ppl     people
--     wrt     with respect to
--
-- `#` starts a comment.  The same abbreviation may appear more than once and
-- the expansions are offered in the order written.  The expansion is free
-- text, so "btw" -> "by the way" works as well as a single word.

local util = require("spellless.util")

local Shortcuts = {}
Shortcuts.__index = Shortcuts

--- Parse `text`.  Never fails: a line that makes no sense is skipped, because
--- this is a file people edit by hand and one fat-fingered line should not
--- cost them the other fifty.
function Shortcuts.parse(text)
  local self = setmetatable({ map = {}, count = 0 }, Shortcuts)
  if not text then return self end
  for line in text:gmatch("[^\r\n]+") do
    local body = line:match("^%s*(.-)%s*$")
    if body ~= "" and body:sub(1, 1) ~= "#" then
      -- Split on the first run of whitespace: the key cannot contain any, and
      -- the expansion may contain plenty.
      local key, expansion = body:match("^(%S+)%s+(.-)%s*$")
      if key and expansion and expansion ~= "" then
        key = key:lower()
        local list = self.map[key]
        if not list then
          list = {}
          self.map[key] = list
        end
        list[#list + 1] = expansion
        self.count = self.count + 1
      end
    end
  end
  return self
end

function Shortcuts.load(path)
  if not path or path == "" then return Shortcuts.parse(nil) end
  local fh = io.open(path, "rb")
  if not fh then return Shortcuts.parse(nil) end
  local text = fh:read("a")
  fh:close()
  return Shortcuts.parse(text)
end

--- The expansions for `query`, or nil.  Exact matches only: an abbreviation
--- is a whole word you typed, not a prefix of one.
function Shortcuts:get(query)
  if not query or query == "" then return nil end
  return self.map[query]
end

return Shortcuts
