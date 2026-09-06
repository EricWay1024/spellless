-- Letter combinations that belong to the editor rather than to English.
--
-- VS Code's HyperSnips expands `xdm` into a display-maths block the moment the
-- letters appear in the document.  Under Spellless they never appear: `xdm` is
-- a composition, the candidate list offers words, and whichever key commits it
-- adds a space -- so the editor sees `xdm ` if it sees anything at all, and by
-- then the moment has passed.
--
-- So these letters are given back to the editor.  Typing a trigger commits
-- exactly those characters, with no space and no capital, and the editor's own
-- expansion takes it from there.  A trigger marked `ascii` also hands the
-- keyboard over to ASCII mode, because what follows it is maths; the ones that
-- open a theorem environment do not, because what follows those is English.
--
-- Format, one trigger per line.  An optional second field of `ascii` asks for
-- ASCII mode; anything after that is a note:
--
--     xdm     ascii   display maths
--     xthm            theorem
--
-- `#` starts a comment.  Triggers are matched exactly, case and all, against
-- the whole composition -- `xdm` fires, `xdmn` does not, and neither does the
-- `xdm` inside a longer word, which is HyperSnips' own word-boundary rule
-- arrived at from the other side.  See docs/SNIPPETS.md.

local Snippets = {}
Snippets.__index = Snippets

--- Parse `text`.  Never fails: a line that makes no sense is skipped, because
--- this is a file people edit by hand and a generator writes.
function Snippets.parse(text)
  local self = setmetatable({ map = {}, count = 0, longest = 0 }, Snippets)
  if not text then return self end
  for line in text:gmatch("[^\r\n]+") do
    local body = line:match("^%s*(.-)%s*$")
    if body ~= "" and body:sub(1, 1) ~= "#" then
      local trigger, rest = body:match("^(%S+)%s*(.*)$")
      -- Only what the speller can compose.  A trigger holding a character that
      -- never reaches a composition could not be typed as one, and silently
      -- never firing is worse than not being in the list at all.
      if trigger and trigger:match("^[%a']+$") and not self.map[trigger] then
        self.map[trigger] = { ascii = rest:match("^ascii%f[%s\0]") ~= nil }
        self.count = self.count + 1
        self.longest = math.max(self.longest, #trigger)
      end
    end
  end
  return self
end

function Snippets.load(path)
  if not path or path == "" then return Snippets.parse(nil) end
  local fh = io.open(path, "rb")
  if not fh then return Snippets.parse(nil) end
  local text = fh:read("a")
  fh:close()
  return Snippets.parse(text)
end

--- The entry for `text`, or nil.  Exact and case-sensitive: `xdm` and `XDM`
--- are different keystrokes, and HyperSnips treats them as different snippets.
function Snippets:get(text)
  if not text or text == "" or #text > self.longest then return nil end
  return self.map[text]
end

return Snippets
