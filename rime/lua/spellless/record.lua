-- An append-only record of what was typed and what happened to it.
--
-- docs/proposals/recording.md is the design; this is the half that writes.
-- Three documents ask for the artefact it produces -- ALGORITHM.md §2 lists
-- "no training data" among the constraints the matcher was built under, §8.2
-- says the weights are still fitted on the set they are scored on, and
-- DESIGN.md §10 item 7 asks for a real keystroke log by name -- and every
-- composition computes the tuple all three want before throwing it away.
--
-- Format: tab-separated, one record per line, the kind in the first column and
-- `ms` and `app` in the next two whatever the kind.  Not JSON: the personal
-- store is already a hand-editable tab-separated file with a leading mark for
-- the line kind, a log in that shape can be read with `grep` and counted with
-- `sort | uniq -c`, and a correct JSON writer -- escaping, UTF-8, surrogate
-- pairs -- is real work to do inside a keystroke for no gain.
--
--     session  ms  unix  version  build  digest  schema  app
--     commit   ms  app  input  text  rank  source  how  keys  bs  maxlen
--                       nav  dur  cands  scanned  checked  cues  qms
--     del      ms  app  what
--     bail     ms  app  how
--     forget   ms  app  word  outcome
--
-- `ms` is milliseconds since the session header, so no record needs a clock
-- that means anything outside this process, and the header's `unix` is the one
-- absolute time in the file.
--
-- **Three things this module may never do**, because it runs inside a
-- keystroke on somebody's real work, in a process with no way to show an
-- error:
--
--   * **raise.**  Every file operation is guarded; a full disk, a locked file
--     or a deleted directory stops the recording for the session and is
--     reported once by the caller.  A failed write is a dropped record, not a
--     lost keystroke.
--   * **open a file per keystroke.**  The whole of matching runs in 2.9 ms
--     mean (EVALUATION.md) and config.lua turns down a recall feature worth 96
--     points of reachability because it costs 27% of that.  Records go into a
--     buffer and reach the disk through a handle held open in append mode.
--   * **change what the input method does.**  The log exists to evaluate this
--     software, and a log that changed the behaviour cannot measure it.
--
-- One file, rotated by size, rather than one file per day.  A day per file
-- reads better and cannot be had: `io.open` will not create a directory, Lua
-- has no mkdir, and `os.execute("mkdir")` flashes a console window out of the
-- IME process on Windows.  Nothing is lost -- the day boundary is in the data,
-- in the session headers, and scripts/analyse_log.py splits on it.

local util = require("spellless.util")

local Record = {}
Record.__index = Record

-- One recorder per file, shared across engines, for the reason `UserDB.load`
-- gives at length: librime runs one Lua state per process but one engine per
-- input context, so two recorders on one path would hold two buffers and
-- interleave half-written lines.
--
-- Two *processes* writing one file is not guarded against, and does not
-- happen: the case this project actually has -- the two frontends, out of
-- `%APPDATA%\Rime` and `%APPDATA%\Spellless` -- resolves to two user
-- directories and therefore two logs.  See docs/DEPLOYING.md.
local cache = {}

--- Drop the memoised recorder for `path` (tests only).
function Record.forget(path)
  local self = cache[path]
  if self and self.fh then self.fh:close() end
  cache[path] = nil
end

local ESCAPE = { ["\\"] = "\\\\", ["\t"] = "\\t", ["\n"] = "\\n", ["\r"] = "\\r" }

--- One field, made safe for a tab-separated line.
---
--- An absent field is `-` rather than empty, so a line that was mis-parsed is
--- visible as a short line instead of reading as a present-but-blank column.
--- A field that is genuinely a hyphen is escaped, so the two round-trip.
local function encode(value)
  if value == nil or value == "" or value == false then return "-" end
  local kind = type(value)
  if kind == "number" then
    -- Integers, always.  Rime hands every configured number back as a double,
    -- and a "3.0" in a column the reader adds up is a bug in two languages.
    return string.format("%d", math.floor(value))
  end
  if kind == "boolean" then return "1" end
  local s = tostring(value):gsub("[\\\t\n\r]", ESCAPE)
  if s == "-" then return "\\-" end
  return s
end

--- FNV-1a over the resolved configuration, so a line can always be traced to
--- the weights that produced it.
---
--- Without this the log is uninterpretable the first time a weight changes,
--- which will be the week after it is switched on -- the same discipline
--- `spellless.build.json` already applies to the dictionary.
function Record.digest(cfg)
  local keys = {}
  for key in pairs(cfg) do keys[#keys + 1] = key end
  table.sort(keys)
  local h = 2166136261
  for _, key in ipairs(keys) do
    local s = key .. "=" .. tostring(cfg[key]) .. ";"
    for i = 1, #s do
      h = (h ~ s:byte(i)) * 16777619 & 0xffffffff
    end
  end
  return string.format("%08x", h)
end

--- `path` is the log file itself; nil or "" means no recorder at all, which is
--- what every caller gets when `record` is off.
function Record.open(opts)
  local path = opts and opts.path
  if not path or path == "" then return nil end
  if cache[path] then return cache[path] end
  local self = setmetatable({
    path = path,
    now_ms = opts.now_ms or function() return 0 end,
    now = opts.now or os.time,
    flush_every = opts.flush_every or 32,
    flush_ms = opts.flush_ms or 10000,
    max_bytes = opts.max_bytes or (32 * 1024 * 1024),
    buf = {},
    pending = 0,
    events = 0,
    bytes = 0,
    fh = nil,
    header = nil,
    dead = false,
    err = nil,
  }, Record)
  self.started_ms = self.now_ms()
  self.last_flush = self.started_ms
  cache[path] = self
  return self
end

--- Milliseconds since the session header.
function Record:ms()
  return self.now_ms() - self.started_ms
end

--- Describe this session.  The header line is not written here: it is written
--- at the top of whatever file the first record lands in, and again after a
--- rotation, so that every file is readable on its own.
function Record:session(t)
  self.header = table.concat({
    "session", encode(0), encode(self.now()), encode(t.version),
    encode(t.build), encode(t.digest), encode(t.schema), encode(t.app),
  }, "\t") .. "\n"
  return self
end

local function put(self, line)
  if self.dead then return end
  self.buf[#self.buf + 1] = line
  self.pending = self.pending + 1
  self.events = self.events + 1
  if self.pending >= self.flush_every
     or (self.now_ms() - self.last_flush) >= self.flush_ms then
    self:flush()
  end
end

--- One composition, from its first keystroke to the moment its text reached
--- the document.  The unit the product is measured in, and the one that
--- answers most of the questions on its own.
function Record:commit(t)
  put(self, table.concat({
    "commit", encode(t.ms), encode(t.app),
    encode(t.input), encode(t.text), encode(t.rank), encode(t.source),
    encode(t.how), encode(t.keys), encode(t.bs), encode(t.maxlen),
    encode(t.nav), encode(t.dur), encode(t.cands),
    encode(t.scanned), encode(t.checked), encode(t.cues), encode(t.qms),
  }, "\t") .. "\n")
end

--- The three one-line kinds.  `del` is the raw material of post-commit repair,
--- `bail` is "I give up, let me type it myself", and `forget` is the rarest
--- and cleanest label in the log: a human saying outright that the answer was
--- wrong.  What links a `del` to the commit it undoes is not decided here; see
--- the design, §2 and §3.4.
function Record:note(kind, t)
  put(self, table.concat({
    kind, encode(t.ms), encode(t.app), encode(t.a), encode(t.b),
  }, "\t") .. "\n")
end

--- Open the file, rotating it first if it has grown past its cap.
--- Returns false once anything has gone wrong, for good.
local function ensure(self)
  if self.dead then return false end
  if self.fh and self.bytes < self.max_bytes then return true end
  if self.fh then
    self.fh:close()
    self.fh = nil
    -- Rotation is two files and no more.  `os.rename` over an existing file
    -- fails on Windows, so the older one goes first; if either call fails
    -- there is nothing useful to do but carry on appending to a file that is
    -- over its cap, which is better than losing the session.
    os.remove(self.path .. ".1")
    os.rename(self.path, self.path .. ".1")
    self.bytes = 0
  end
  local fh, err = io.open(self.path, "a")
  if not fh then
    self.dead, self.err = true, tostring(err)
    return false
  end
  self.fh = fh
  -- In append mode the handle already sits at the end, so this is the size of
  -- what is there rather than a seek that moves anything.
  self.bytes = fh:seek("end") or 0
  if self.header then
    fh:write(self.header)
    self.bytes = self.bytes + #self.header
  end
  return true
end

function Record:flush()
  self.last_flush = self.now_ms()
  if self.pending == 0 then return true end
  if not ensure(self) then
    -- Nothing can be written and nothing ever will be; drop what is held so a
    -- dead recorder does not also become a leak.
    self.buf, self.pending = {}, 0
    return false
  end
  local blob = table.concat(self.buf)
  self.buf, self.pending = {}, 0
  local ok, err = pcall(function()
    self.fh:write(blob)
    self.fh:flush()
  end)
  if not ok then
    self.dead, self.err = true, tostring(err)
    return false
  end
  self.bytes = self.bytes + #blob
  return true
end

function Record:close()
  self:flush()
  if self.fh then self.fh:close(); self.fh = nil end
end

--- One line for `zzver`, which is where a recorder that is running has to be
--- visible from.  A recorder you cannot see from inside the thing being
--- recorded is a recorder you will forget is on.
function Record:describe()
  if self.dead then
    return "recording failed: " .. tostring(self.err)
  end
  return ("recording %d events to %s"):format(self.events, self.path)
end

return Record
