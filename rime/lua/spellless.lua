-- Rime adapter for Spellless.
--
-- Wire it into a schema as
--     translators:
--       - lua_translator@*spellless
-- and librime-lua will `require("spellless")` from <rime user dir>/lua/ and
-- call init(env) once, func(input, seg, env) per composition update, and
-- fini(env) when the engine goes away.
--
-- Everything interesting lives in spellless/*.lua, which is plain Lua with no
-- Rime dependency; this file only translates between the two worlds.

local Engine = require("spellless.engine")
local config = require("spellless.config")
local preceding = require("spellless.preceding")
local util = require("spellless.util")

-- librime's ProcessResult, which a lua_processor returns as a number.
local kRejected, kAccepted, kNoop = 0, 1, 2
local XK_Return, XK_KP_Enter, XK_BackSpace = 0xff0d, 0xff8d, 0xff08
local XK_Shift_L, XK_Shift_R = 0xffe1, 0xffe2
local XK_a, XK_A = 0x61, 0x41
local XK_d, XK_D = 0x64, 0x44

--- Does a single segment cover the whole input?
---
--- `get_selected_candidate` returns the *last* segment's candidate, so the
--- punctuation shortcut below is only safe when there is nothing else in the
--- composition to lose.
local function single_segment(context)
  local composition = context.composition
  if not composition or composition:empty() then return false end
  local segmentation = composition:toSegmentation()
  return segmentation.size == 1
      and segmentation:get_current_end_position() >= #context.input
end

--- Printable ASCII that is neither a letter nor a digit: punctuation.
--- The speller has already had its chance at anything it wants, and the
--- recognizer at identifiers, so whatever reaches us is genuinely punctuation.
local function is_punctuation(code)
  if code <= 0x20 or code >= 0x7f then return false end
  if code >= 0x30 and code <= 0x39 then return false end
  if code >= 0x41 and code <= 0x5a then return false end
  if code >= 0x61 and code <= 0x7a then return false end
  return true
end

-- Where the two gears leave notes for each other.  They get separate `env`
-- tables, but they share the input context, and Rime's per-context property
-- map is exactly the right size for one flag.
--
-- The note is stamped with the size of the commit history when it was written.
-- Without that it outlives its keystroke: tap Shift into plain typing, write a
-- whole sentence, tap back, and a Backspace from before the excursion would
-- still be insisting we are mid-sentence.
local SENTENCE = "spellless_sentence"
local SENTENCE_YES, SENTENCE_NO = "1", "0"

local function write_note(context, value)
  context:set_property(SENTENCE, value .. ":" .. tostring(context.commit_history.size))
end

--- The note, if it still describes the text we are looking at.
local function read_note(context)
  local value, stamp = context:get_property(SENTENCE):match("^([01]):(%d+)$")
  if value and tonumber(stamp) == context.commit_history.size then return value end
  return nil
end

local M = {}

-- ---------------------------------------------------------------------------
-- configuration
-- ---------------------------------------------------------------------------

--- Read `spellless/*` out of the schema, typed by what the default looks like.
--- Unknown keys in the schema are simply not read; unknown keys passed to
--- config.build would raise, which is the behaviour we want for typos in code
--- but not for a stray comment in someone's YAML.
local function schema_overrides(schema_config)
  local out = {}
  for key, default in pairs(config.defaults) do
    local path = "spellless/" .. key
    local value
    if type(default) == "boolean" then
      value = schema_config:get_bool(path)
    elseif type(default) == "number" then
      value = schema_config:get_double(path)
    else
      value = schema_config:get_string(path)
    end
    if value ~= nil then out[key] = value end
  end
  return out
end

--- Where the generated dictionary and indexes live.
--- Checked in the user directory first so a personal rebuild wins over a
--- system-wide install, exactly like Rime's own data lookup.
local function find_data_dir(schema_config)
  local explicit = schema_config:get_string("spellless/data_dir")
  local candidates = {}
  if explicit and explicit ~= "" then candidates[#candidates + 1] = explicit end
  candidates[#candidates + 1] = util.join(rime_api.get_user_data_dir(), "spellless")
  candidates[#candidates + 1] = util.join(rime_api.get_shared_data_dir(), "spellless")
  for _, dir in ipairs(candidates) do
    if util.exists(util.join(dir, "spellless.words")) then return dir end
  end
  return nil, "no spellless.words under " .. table.concat(candidates, " or ")
end

-- ---------------------------------------------------------------------------
-- lifecycle
-- ---------------------------------------------------------------------------

-- One matcher per (data directory, settings), shared by every gear and every
-- input context.  Everything it holds -- the corpus, the config, the personal
-- store -- is already shared or memoised, and the processor needs the same
-- instance as the translator so that what it commits gets learned.
--
-- Keyed on the settings as well as the directory: two schemas can both use
-- Spellless with different `spellless/*` values, and handing the second one
-- the first one's configuration would be a silent, baffling bug.
local engines = {}

local function settings_key(dir, overrides)
  local keys = {}
  for key in pairs(overrides) do keys[#keys + 1] = key end
  table.sort(keys)
  local parts = { dir }
  for _, key in ipairs(keys) do
    parts[#parts + 1] = key .. "=" .. tostring(overrides[key])
  end
  return table.concat(parts, "\0")
end

local function acquire(env)
  local schema_config = env.engine.schema.config
  local dir, why = find_data_dir(schema_config)
  if not dir then return nil, why end

  local overrides = schema_overrides(schema_config)
  if (overrides.raw_candidate_index or 0) < 1 then
    -- Default the literal-input slot to the last one on the first page: one
    -- predictable keystroke, and it never displaces a real suggestion.
    -- schema.page_size already resolves menu/page_size through default.yaml.
    overrides.raw_candidate_index =
        env.engine.schema.page_size or schema_config:get_int("menu/page_size") or 7
  end

  local key = settings_key(dir, overrides)
  if engines[key] then return engines[key] end

  local engine, err = Engine.new{
    data_dir = dir,
    user_dir = rime_api.get_user_data_dir(),
    config = overrides,
    now_ms = rime_api.get_time_ms,
  }
  if not engine then return nil, err end
  engines[key] = engine
  return engine
end

function M.init(env)
  local engine, err = acquire(env)
  if not engine then
    log.error("spellless: " .. tostring(err))
    return
  end
  env.spellless = engine

  -- Rime's own user dictionary learns (code, text) pairs emitted by a
  -- dictionary-backed translator.  Our candidates are synthesised in Lua, so
  -- there is nothing for it to record; we watch commits ourselves instead.
  -- See DESIGN.md, "Why not the native user dictionary".
  --
  -- Connected unconditionally: `learn: false` must switch off the personal
  -- store, not the sentence bookkeeping that also lives here.
  env.commit_connection = env.engine.context.commit_notifier:connect(function(ctx)
    engine:learn(ctx:get_commit_text())
    -- Something was just committed, so whatever the last Return or Backspace
    -- implied is stale; the text behind the cursor is authoritative again.
    ctx:set_property(SENTENCE, "")
  end)
end

function M.fini(env)
  if env.commit_connection then
    env.commit_connection:disconnect()
    env.commit_connection = nil
  end
  if env.spellless then env.spellless:flush() end
end

-- ---------------------------------------------------------------------------
-- reading the text that came before
-- ---------------------------------------------------------------------------

--- The last `want` characters or so of what has been committed.
---
--- Not just the newest record: punctuation is committed on its own, so the
--- newest record is frequently a bare `"` or `$` or `\` with nothing around
--- it to say whether it opens or closes, and `He said "no."` would lose both
--- its space and its capital.  Stitching the last few records back together
--- restores the context that the record boundaries threw away.
local TAIL_CHARS, TAIL_RECORDS = 16, 6

local function commit_tail(history)
  if history:empty() then return "" end
  local records = history:to_table()
  local parts, length = {}, 0
  for i = #records, math.max(1, #records - TAIL_RECORDS + 1), -1 do
    local text = records[i].text
    table.insert(parts, 1, text)
    length = length + #text
    if length >= TAIL_CHARS then break end
  end
  local tail = table.concat(parts)

  -- A commit may carry U+0008 to reclaim a character already in the document
  -- (see `reclaim_space` in the processor).  The history records the request;
  -- what we want here is the text it left behind, so apply the erasures.  A
  -- backspace with nothing in front of it inside this window erased something
  -- older than the window, and simply drops.
  if tail:find("\8", 1, true) then
    local n
    repeat tail, n = tail:gsub("[^\8]\8", "") until n == 0
    tail = tail:gsub("\8", "")
  end
  return tail
end

--- Everything the text behind the cursor implies for the next word.
---
--- Rime's commit history is the only thing that knows what landed in the
--- document.  It also records printable keys typed outside a composition, and
--- Rime clears it on Return and Backspace, so a hand-typed space, a new line
--- or a correction all do the right thing.
local function read_behind(engine, context)
  local cfg = engine.cfg
  local tail = commit_tail(context.commit_history)
  local out = {
    literal_first = preceding.expects_literal(tail),
    sentence_start = false,
  }
  if not cfg.auto_capitalize then return out end

  -- The commit history alone cannot say whether a sentence just ended,
  -- because Rime clears it on Return *and* on Backspace -- a new line and a
  -- correction look identical afterwards, and they want opposite answers.  So
  -- the processor writes down which of the two happened, and that note is
  -- read first:
  --   "1"  a Return landed outside a composition: a new line
  --   "0"  a Backspace did: we are somewhere inside existing text
  --   ""   nothing since the last commit, so the tail knows best -- and an
  --        empty tail now means a context nobody has typed in yet
  local note = read_note(context)
  if note == SENTENCE_YES then
    out.sentence_start = true
  elseif note ~= SENTENCE_NO then
    out.sentence_start = preceding.starts_fresh(tail)
        or preceding.ends_sentence(tail, engine.corpus.abbreviations)
  end
  return out
end

-- ---------------------------------------------------------------------------
-- translation
-- ---------------------------------------------------------------------------

--- One-entry memo.  Rime re-queries a segment whenever the composition is
--- refreshed (paging, option changes), and repeating the search for input we
--- just answered is pure waste.
---
--- Keyed on the engine as well as the input, because librime creates one
--- engine per input context but shares a single Lua state; and on the personal
--- store's change counter, so a commit invalidates it.
local cache = { engine = nil, input = nil, result = nil, stamp = -1, key = nil }

local function suggest(engine, input, behind)
  local key = tostring(behind.sentence_start) .. tostring(behind.literal_first)
  if cache.engine == engine and cache.input == input and cache.key == key
     and cache.stamp == engine.user.dirty_stamp then
    return cache.result
  end
  local result = engine:suggest(input, nil, behind)
  cache.engine, cache.input, cache.result, cache.stamp, cache.key =
      engine, input, result, engine.user.dirty_stamp, key
  return result
end

function M.func(input, seg, env)
  local engine = env.spellless
  if not engine then return end
  -- Ordinary alphabetic composition, plus the identifier segments the
  -- recognizer hands us so that "sqlite3" or "foo_bar" still shows the literal
  -- text as a selectable candidate.  Everything else (punctuation, urls,
  -- emails) keeps Rime's default handling.
  if not (seg:has_tag("abc") or seg:has_tag("ident")
          or seg:has_tag("ident_caps")) then return end

  local context = env.engine.context
  local behind = read_behind(engine, context)
  local candidates = suggest(engine, input, behind)
  local debug_comments = engine.cfg.show_debug_comments
  local raw_comment = engine.cfg.raw_comment
  -- The space rides along with the word, so whichever key commits it -- space
  -- bar, a number, a click -- puts the space in too.
  local trail = engine.cfg.auto_space and " " or ""

  for i = 1, #candidates do
    local c = candidates[i]
    local comment = c.raw and raw_comment or ""
    if debug_comments then
      comment = ("%s %s %.1f"):format(comment, c.source, c.score)
    end
    local cand = Candidate(c.source, seg.start, seg._end, c.text .. trail, comment)
    -- Rime merges translations from several translators by quality; keeping
    -- ours strictly descending preserves the order we ranked them in.
    cand.quality = 1000 - i
    yield(cand)
  end
end

-- ---------------------------------------------------------------------------
-- filter: the space after punctuation
-- ---------------------------------------------------------------------------

--- Wire in as `lua_filter@*spellless*filter@punct_spacer`.
---
--- "you" + "." should come out as "you. ".  The word gives up its own trailing
--- space so that "you." is right; the punctuation supplies the one that
--- follows.  Which marks deserve one is the same question `preceding` already
--- answers for the text behind a word: a full stop or a comma yes, an opening
--- bracket no.
M.filter = {}

function M.filter.init(env)
  env.spellless = acquire(env)
end

function M.filter.func(translation, env)
  local engine = env.spellless
  local spacing = engine and engine.cfg.auto_space
  -- Judge the mark against what is already behind it, not on its own: a lone
  -- `$` always reads as opening, so `$X$` would never get its following space.
  local behind = spacing and commit_tail(env.engine.context.commit_history) or ""
  for candidate in translation:iter() do
    local text = candidate.text
    -- Digits mean a number separator ("1.5"), which the punctuation translator
    -- also produces and which must not be spaced apart.
    if spacing and #text > 0 and not text:find("%d")
       and preceding.needs_space_after(behind .. text) then
      yield(candidate:to_shadow_candidate(candidate.type, text .. " ", candidate.comment))
    else
      yield(candidate)
    end
  end
end

-- ---------------------------------------------------------------------------
-- processor
-- ---------------------------------------------------------------------------

--- Wire in as `lua_processor@*spellless*processor`, before express_editor.
---
--- Return already commits the raw input -- that is express_editor's own
--- binding, and it is the promise that you can always commit exactly what you
--- typed.  The one thing it cannot know about is the automatic space, so this
--- processor handles Return only when a leading space is due, and otherwise
--- gets out of the way and lets the editor do exactly what it did before.
--- It also owns the spaces between words, and watches Return and Backspace
--- outside a composition -- the only way to tell a new line from a correction
--- after Rime has cleared its commit history for both.
---
--- The space is committed when the *next word starts*, not when the previous
--- one ends.  Rime cannot retract committed text -- `key_binder`'s `send:`
--- re-processes a key inside the engine and drops it if nothing handles it, so
--- a synthetic Backspace never reaches the application -- which rules out
--- committing a trailing space and deleting it before punctuation.  Deferring
--- it by one keystroke gets the same result without needing to: punctuation
--- simply never triggers the space, because only a letter does.
M.processor = {}

function M.processor.init(env)
  -- Shares the translator's matcher rather than building its own, so that what
  -- this processor commits is learned by the same personal store.  It does not
  -- connect a commit notifier: the translator owns that, and a second one
  -- would count every word twice.
  env.spellless = acquire(env)
end

function M.processor.func(key, env)
  local code = key.keycode
  local context = env.engine.context

  -- A Shift tap switches to plain typing and back, and nothing we do runs in
  -- between.  Whatever the last Return or Backspace implied about sentence
  -- position cannot survive that, and the history-size stamp alone would not
  -- notice: a Return typed in ASCII mode clears the history back to the size
  -- the note was stamped with, making a stale note authoritative again.
  if code == XK_Shift_L or code == XK_Shift_R then
    context:set_property(SENTENCE, "")
    return kNoop
  end
  if key:release() then return kNoop end

  -- Control+Shift+D: forget the highlighted candidate.
  --
  -- Learning is otherwise a one-way door.  Commit a typo literally once, or
  -- pick the wrong word in a hurry, and it leads the list from then on with no
  -- way back short of editing the personal file by hand.  This is that way
  -- back: highlight the entry that should not be there and it is gone from the
  -- personal store, immediately and on disk.
  --
  -- The dictionary is untouched -- an ordinary English word goes on being an
  -- ordinary English word, it merely stops being *yours*.  With nothing
  -- composing it forgets the word last committed, which is the case where you
  -- notice the mistake one keystroke too late.
  if key:ctrl() and key:shift() and (code == XK_d or code == XK_D) then
    local engine = env.spellless
    if not engine then return kNoop end
    local word
    if context:is_composing() then
      local chosen = context:get_selected_candidate()
      word = chosen and chosen.text
    else
      word = context.commit_history:latest_text()
    end
    if word then engine:forget(word) end
    return kAccepted
  end

  -- Control+Shift+A: the deliberate version of the Shift tap.  Handled here
  -- rather than by key_binder, because `toggle: ascii_mode` on its own leaves
  -- the composition open and then appends plain ASCII to it -- so the one case
  -- it is advertised for, escaping mid-word, was the one it did not do.
  if key:ctrl() and key:shift() and (code == XK_a or code == XK_A) then
    if context:is_composing() then
      local text = context.input
      env.engine:commit_text(text)
      if env.spellless then env.spellless:learn(text) end
      context:clear()
    end
    context:set_property(SENTENCE, "")
    context:set_option("ascii_mode", not context:get_option("ascii_mode"))
    return kAccepted
  end

  if key:ctrl() or key:alt() or key:super() then return kNoop end
  local composing = context:is_composing()
  local engine = env.spellless

  -- Return's two forgotten cousins.
  --
  -- express_editor binds Return alone, and librime's key binding falls back
  -- from Shift to Control -- so Shift+Return resolved to Control+Return,
  -- "commit script text", which swallowed the newline and bypassed both the
  -- commit history and learning.  Keypad Enter it never bound at all, so the
  -- composition simply sat there while the key went to the application.
  if composing and (code == XK_KP_Enter
                    or (code == XK_Return and key:shift())) then
    local text = context.input
    env.engine:commit_text(text)
    if engine then engine:learn(text) end
    context:set_property(SENTENCE, "")
    context:clear()
    -- Keypad Enter *is* Enter: commit and stop.  Shift+Return is the soft
    -- newline in Slack and Zulip, so the word is committed and the key goes on
    -- to the application, which is what it was asking for all along.
    if code == XK_KP_Enter then return kAccepted end
    return kNoop
  end

  -- A number our own spacing would otherwise split.  "3" then "." commits
  -- ". " -- correctly, since nothing yet says a digit is coming -- and the
  -- digit that follows says so.  Taking the space back then is the only way
  -- to get "3.14" without either guessing ahead or leading spaces.
  -- Covers "1,000", "12:30" and "Smith:2020" as well.
  if engine and engine.cfg.auto_space and engine.cfg.reclaim_space
     and not composing and code >= 0x30 and code <= 0x39
     and not key:shift() then
    local behind = commit_tail(context.commit_history)
    if behind:match("%d[%.,:] $") then
      env.engine:commit_text("\8" .. string.char(code))
      return kAccepted
    end
  end

  -- Punctuation ends the word *without* its trailing space, so "you" + "." is
  -- "you." and not "you .", and then carries the space that follows it.
  --
  -- With `ascii_punct` on -- which this schema sets, and which is what anyone
  -- writing English wants -- librime's punctuator returns kNoop immediately
  -- and never creates a punct candidate at all, so the filter below never
  -- runs.  The punctuation is then plain ASCII by definition, so writing it
  -- here is faithful rather than a reimplementation of the punctuator.
  if engine and engine.cfg.auto_space and is_punctuation(code) then
    local ascii_punct = context:get_option("ascii_punct")
    if composing then
      local text
      if single_segment(context) then
        -- get_selected_candidate() returns the *last* segment's candidate, so
        -- it is only the whole answer when one segment covers the whole input.
        local chosen = context:get_selected_candidate()
        text = chosen and chosen.text or context.input
        -- The word gives up its trailing space so the mark sits flush against
        -- it -- unless the mark opens something, where `see (the)` is right
        -- and `see(the)` is not.
        if not preceding.opens_after_word(string.char(code)) then
          text = text:gsub(" $", "")
        end
      else
        -- Several segments, or a caret parked mid-word.  Returning kNoop here
        -- looks safe and is not: express_editor then commits only the segment
        -- the caret sits in and the rest of the input is gone -- `hello`,
        -- Left, `,` came out as `Hell ,`.  Commit every character instead.
        text = context.input
      end
      env.engine:commit_text(text)
      engine:learn(text)
      context:set_property(SENTENCE, "")
      context:clear()
    end
    if not ascii_punct then
      return kNoop  -- the punctuator will write it, and the filter will space it
    end
    local mark = string.char(code)
    -- Judge the mark against the text it is landing on rather than on its own:
    -- a lone `$` always reads as opening, so the closing one in `$X$` would
    -- never get the space that follows it.  Any word above has already been
    -- committed, so the history is current.
    local behind = commit_tail(context.commit_history)

    -- Punctuation typed after a word that was already committed -- picked with
    -- the space bar or a number -- arrives with our automatic space in front of
    -- it.  Ask the frontend for it back, if the schema says the frontend can
    -- do that.  See `reclaim_space`; on stock Weasel the U+0008 would be
    -- inserted literally, which is why this is off by default.
    local reclaim = ""
    if engine.cfg.reclaim_space and preceding.hugs_previous(mark) then
      local stripped = behind:match("^(.-) $")
      if stripped then reclaim, behind = "\8", stripped end
    end

    local space = preceding.needs_space_after(behind .. mark) and " " or ""
    env.engine:commit_text(reclaim .. mark .. space)
    return kAccepted
  end

  if key:shift() then return kNoop end

  if not composing then
    -- Rime is about to clear its commit history for either of these, taking
    -- the size to zero, so stamp the note with what it will be, not what it is.
    if code == XK_Return or code == XK_KP_Enter then
      context:set_property(SENTENCE, SENTENCE_YES .. ":0")
    elseif code == XK_BackSpace then
      context:set_property(SENTENCE, SENTENCE_NO .. ":0")
    end
    return kNoop
  end

  -- Return needs no special handling: express_editor commits the raw input,
  -- which fires the commit notifier, which learns it.
  return kNoop
end

return M
