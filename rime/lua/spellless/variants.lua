--- British and American spelling, as a set of words not to offer.
---
--- `generated/spellless.variants` groups the spellings of one word and says,
--- for each, the modes in which it is the spelling you would actually write.
--- In a mode, a member that does not carry that mode is not offered, and the
--- member that does carry it is offered in its place.
---
--- Nothing here reorders or rescores anything.  The frequencies were levelled
--- across each group at build time (scripts/build_dictionary.py), so the
--- survivor already sits beside the member being hidden and needs no help.
---
--- The file is read only when a mode is on.  With the switch off -- which is
--- the default -- this module never opens anything and `Variants.load` returns
--- nil, so the caller pays one comparison.

local util = require("spellless.util")

local Variants = {}
Variants.__index = Variants

--- The modes a schema switch can select.  `off` is not here: it is the absence
--- of a mode, and is handled by returning nil.
Variants.MODES = { ["us"] = true, ["gb-ise"] = true, ["gb-ize"] = true }

local cache = {}

local function fingerprint(dir)
  local fh = io.open(util.join(dir, "spellless.variants"), "rb")
  if not fh then return "-1" end
  local size = fh:seek("end") or -1
  fh:close()
  return tostring(size)
end

--- Load the groups for one mode.  Returns nil when the mode is off or
--- unknown, or when the file is missing -- an older `generated/` should
--- degrade to "no hiding" rather than to an error.
---
--- Memoised per directory, file generation and mode, so a redeploy is picked
--- up the way the corpus is.
function Variants.load(dir, mode)
  if not mode or not Variants.MODES[mode] then return nil end
  local key = dir .. "\0" .. fingerprint(dir) .. "\0" .. mode
  local hit = cache[key]
  if hit ~= nil then
    if hit == false then return nil end
    return hit
  end

  local blob = util.slurp(util.join(dir, "spellless.variants"))
  if not blob then
    cache[key] = false
    return nil
  end

  local self = setmetatable({ mode = mode, hide = {}, instead = {} }, Variants)

  -- [^\r\n]+ rather than [^\n]+, for the same reason the corpus does it: this
  -- file reaches Windows, where a checkout can turn every ending into CRLF.
  for line in blob:gmatch("[^\r\n]+") do
    if line:sub(1, 1) ~= "#" then
      local members, survivor = {}, nil
      for field in line:gmatch("[^\t]+") do
        local word, modes = field:match("^([^|]+)|(.*)$")
        if word then
          local carries = false
          if modes ~= "-" then
            for m in modes:gmatch("[^,]+") do
              if m == mode then carries = true break end
            end
          end
          members[#members + 1] = { word = word, carries = carries }
          if carries and not survivor then survivor = word end
        end
      end
      -- Only hide when something survives to be offered instead.  A group in
      -- which no member is written in this mode is left alone entirely:
      -- removing every reading of a word is never the right answer.
      if survivor then
        for _, m in ipairs(members) do
          if not m.carries then
            self.hide[m.word] = true
            self.instead[m.word] = survivor
          end
        end
      end
    end
  end

  cache[key] = self
  return self
end

--- Is `word` a spelling this mode does not use?
function Variants:hidden(word)
  return self.hide[word] == true
end

--- The spelling this mode uses instead of `word`, or nil.
---
--- Most pairs are within the typo budget of each other, so the survivor is
--- reached by ordinary matching once the hidden form is gone.  A few are not
--- -- `plough` to `plow` costs 2.70 against a budget of 1.35 -- and for those
--- this is the only way across.
function Variants:survivor(word)
  return self.instead[word]
end

return Variants
