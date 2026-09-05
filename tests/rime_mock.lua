-- A stand-in for the librime-lua environment, so rime/lua/spellless.lua --
-- the one file real Rime loads and the test suite otherwise never touches --
-- is exercised too.
--
-- Everything here mirrors what librime-lua actually exposes (checked against
-- src/types.cc and src/lua_gears.cc): the globals `rime_api`, `Candidate`,
-- `log` and `yield`, a Config with typed getters, a Segment with has_tag, a
-- commit notifier whose connect() returns something with disconnect(), and a
-- commit history behaving like librime's -- including the detail that
-- Engine::CommitText pushes a {"raw", text} record of its own.

local M = {}

local function make_config(values)
  local function get(path) return values[path] end
  return {
    get_bool = function(_, path)
      local v = get(path); if type(v) == "boolean" then return v end
      return nil
    end,
    get_int = function(_, path)
      local v = get(path); if type(v) == "number" then return math.floor(v) end
      return nil
    end,
    get_double = function(_, path)
      local v = get(path); if type(v) == "number" then return v end
      return nil
    end,
    get_string = function(_, path)
      local v = get(path); if type(v) == "string" then return v end
      return nil
    end,
  }
end

function M.install(opts)
  opts = opts or {}
  M.logged = {}
  M.connections = 0

  _G.rime_api = {
    get_user_data_dir = function() return opts.user_dir or "." end,
    get_shared_data_dir = function() return opts.shared_dir or "." end,
    get_time_ms = function() return 0 end,
  }
  _G.log = setmetatable({}, { __index = function(_, level)
    return function(msg) M.logged[#M.logged + 1] = level .. ": " .. tostring(msg) end
  end })
  _G.Candidate = function(type_, start, _end, text, comment)
    return { type = type_, start = start, _end = _end, text = text,
             comment = comment, quality = 0 }
  end

  local history_records = {}
  local history
  history = {
    push = function(_, type_, text)
      history_records[#history_records + 1] = { type = type_, text = text }
      history.size = #history_records
    end,
    back = function() return history_records[#history_records] end,
    empty = function() return #history_records == 0 end,
    clear = function() history_records = {}; history.size = 0 end,
    latest_text = function()
      local last = history_records[#history_records]
      return last and last.text or ""
    end,
    -- librime returns the records oldest first
    to_table = function() return history_records end,
    size = 0,
  }
  M.history = history
  M.committed = {}
  M.segments = 1
  M.segment_end = nil

  local notifier = {
    connect = function(_, fn)
      M.connections = M.connections + 1
      M.commit_handler = fn
      return { disconnect = function() M.connections = M.connections - 1 end }
    end,
  }

  local env = {
    name_space = "*spellless",
    engine = {
      schema = { schema_id = "spellless", page_size = opts.page_size,
                 config = make_config(opts.config or {}) },
      context = {
        commit_notifier = notifier,
        commit_history = history,
        input = "",
        get_commit_text = function() return M.commit_text or "" end,
        is_composing = function(self) return self.input ~= "" end,
        clear = function(self) self.input = "" end,
        -- librime's per-context string map; get_property returns "" when unset
        properties = {},
        options = {},
        set_property = function(self, key, value) self.properties[key] = value end,
        get_property = function(self, key) return self.properties[key] or "" end,
        set_option = function(self, key, value) self.options[key] = value end,
        -- the highlighted candidate of the current segment
        get_selected_candidate = function(self) return M.selected end,
        -- librime-lua exposes Context::PushInput; the absorb processor uses it
        -- to put a word taken back out of the document into the composition.
        refresh_non_confirmed_composition = function(self)
          self.refreshed = (self.refreshed or 0) + 1
        end,
        push_input = function(self, text)
          self.input = (self.input or "") .. text
          return true
        end,
        -- One segment covering the whole input unless a test says otherwise.
        composition = {
          empty = function() return M.segments == 0 end,
          toSegmentation = function()
            return {
              size = M.segments or 1,
              get_current_end_position = function() return M.segment_end or 9999 end,
            }
          end,
        },
        get_option = function(self, key) return self.options[key] == true end,
      },
    },
  }
  env.engine.commit_text = function(_, text)
    M.committed[#M.committed + 1] = text
    -- librime's ConcreteEngine::CommitText records the text itself
    history:push("raw", text)
  end
  return env
end

--- A KeyEvent as librime-lua exposes it.
function M.key(keycode, opts)
  opts = opts or {}
  return {
    keycode = keycode,
    modifier = 0,
    release = function() return opts.release == true end,
    ctrl = function() return opts.ctrl == true end,
    alt = function() return opts.alt == true end,
    super = function() return opts.super == true end,
    shift = function() return opts.shift == true end,
  }
end

--- Run the translator the way librime-lua does: as a coroutine whose `yield`
--- emits candidates.
function M.translate(mod, input, seg, env)
  local out = {}
  local co = coroutine.create(function() mod.func(input, seg, env) end)
  _G.yield = coroutine.yield
  while true do
    local ok, cand = coroutine.resume(co)
    if not ok then error(cand) end
    if coroutine.status(co) == "dead" then break end
    out[#out + 1] = cand
  end
  return out
end

function M.segment(tags, start, _end)
  local set = {}
  for _, t in ipairs(tags) do set[t] = true end
  return {
    start = start or 0,
    _end = _end or 0,
    has_tag = function(_, t) return set[t] == true end,
  }
end


--- Run a lua_filter the way librime-lua does: a Translation the filter walks
--- with :iter(), yielding replacements.
function M.filter_candidates(mod, candidates, env)
  local i = 0
  local translation = {
    iter = function()
      return function()
        i = i + 1
        return candidates[i]
      end
    end,
  }
  local out = {}
  local co = coroutine.create(function() mod.filter.func(translation, env) end)
  _G.yield = coroutine.yield
  while true do
    local ok, cand = coroutine.resume(co)
    if not ok then error(cand) end
    if coroutine.status(co) == "dead" then break end
    out[#out + 1] = cand
  end
  return out
end

--- A candidate as the punct_translator would hand one over.
function M.candidate(text, type_)
  local c = { text = text, type = type_ or "punct", comment = "" }
  c.to_shadow_candidate = function(_, t, txt, comment)
    return { text = txt, type = t, comment = comment }
  end
  return c
end

return M
