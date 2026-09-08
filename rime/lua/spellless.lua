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

local Corpus = require("spellless.corpus")
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
local XK_Delete = 0xffff
local XK_space = 0x20

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
-- Set while the last key was a Backspace with nothing composing.
local BACKSPACE = "spellless_backspace"
-- Set once the space bar has been offered a literal candidate and declined it.
local LITERAL = "spellless_literal"
-- Which delimiter opened the ASCII run we are inside, "" when we did not open
-- it.  A tapped Shift can leave ASCII mode on without one.
local DELIMITER = "spellless_delimiter"
-- Set while a candidate is being taken by its number key.  A correction is
-- only learned from one of those: see the commit notifier.
local PICKED = "spellless_picked"
-- The style a command asked for, held on the context until the word is
-- committed.  A property rather than a local because the gear that reads it is
-- the translator and the gear that sets it is a processor, and they get
-- separate `env` tables.
local FORCED_CASE = "spellless_case"
-- Set while the keyboard has been handed to ASCII mode for the rest of a word
-- the caret was already sitting inside.  See `ascii_fragment`.
local ASCII_WORD = "spellless_ascii_word"
-- Set while the composition was started by taking a word back out of the
-- middle of the document, where whatever followed that word -- a space, a
-- comma -- is still sitting there.  The word then commits without the
-- automatic trailing space, because the separator it needs is already in the
-- document and a second one would show as a gap.
local RESUMED = "spellless_resumed"
-- Set while the composition ends in the `qq` prefix and the next key may be a
-- command.  Stamped with the input it was armed on, so an arming cannot
-- outlive the word that caused it.
local ARMED = "spellless_armed"
local SENTENCE_YES, SENTENCE_NO = "1", "0"

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
  -- The generation of the data as well as the directory: an engine holds the
  -- corpus it loaded, so keying on the directory alone means a rebuilt
  -- dictionary is deployed, redeployed, and never actually used.
  local parts = { dir, Corpus.fingerprint(dir) }
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
    local committed = ctx:get_commit_text()
    engine:learn(committed)
    -- Remember what the input meant, but only when a candidate was actually
    -- selected.  librime fires this notifier before it clears the context, so
    -- the input is still here to be read -- and get_selected_candidate is nil
    -- exactly when Return committed the raw input, which is a refusal to choose
    -- rather than a choice.
    if ctx:get_selected_candidate() and ctx:get_property(PICKED) == "1" then
      engine:learn_choice(ctx.input, committed)
    end
    -- Something was just committed, so whatever the last Return or Backspace
    -- implied is stale; the text behind the cursor is authoritative again.
    ctx:set_property(SENTENCE, "")
    -- A case asked for with `qq` applies to the word it was asked for and to
    -- nothing after it.  Here rather than anywhere else because a composition
    -- can end several ways -- committed, cleared, abandoned -- and this is the
    -- one of them that means "that word is done".
    ctx:set_property(FORCED_CASE, "")
    ctx:set_property(ARMED, "")
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

--- The text in front of the caret, as the document actually holds it.
---
--- The Spellless build of Weasel reads it and hands it over as a property on
--- every keystroke (WeaselTSF/SurroundingText.cpp).  When it is there it is
--- simply the truth, and every guess below can be skipped.
---
--- Returns nil when there is none: on stock Weasel, or in an application that
--- will not grant a read, or before the first key of a session.
local SURROUNDING = "surrounding_text"

--- Has the frontend ever told us what is in the document?
---
--- Setting `surrounding_text` and honouring a U+0008 prefix were added to each
--- of the two forks in the same commit, and no stock frontend does either, so
--- the first is a reliable sign of the second.  That is worth having because
--- the alternative is asking the user: the three document-editing features
--- would be dangerous to switch on by default without it -- on a frontend that
--- has never heard of the convention the backspaces arrive as text -- and a
--- feature nobody switches on is a feature nobody has.
---
--- A latch rather than a per-keystroke test, and deliberately so.  Which
--- frontend is running is a fact about the process, not about the application
--- being typed into, and plenty of applications refuse a read while the
--- frontend behind them is perfectly capable.  One cooperative window is
--- enough to establish it for the session; until then the features simply do
--- not act, which is exactly what they did before.
---
--- Module scope because librime runs one Lua state per process and the
--- frontend is a property of the process.  It is never cleared: a frontend
--- cannot become a different frontend without the process restarting.
local FRONTEND_READS = false

local function document_tail(context)
  local text = context:get_property(SURROUNDING)
  if text == nil or text == "" then return nil end
  FRONTEND_READS = true
  return text
end

--- Tests only: forget what the frontend has proved, and ask whether it has.
--- A running input method has no use for either -- there is one frontend and
--- it does not change -- but the safety property that lets these features ship
--- on is exactly "nothing is asked of a frontend that has not answered", and
--- that has to be assertable.
function M.forget_frontend()
  FRONTEND_READS = false
end

function M.frontend_reads()
  return FRONTEND_READS
end

--- The text behind the cursor, from the document if the frontend can say and
--- from Rime's own commit history otherwise.
---
--- The history is a record of what *this input method* committed, which is a
--- different thing: librime clears it on Return and Backspace, it never hears
--- about a click or an arrow key, and it cannot see anything typed while
--- another input method was active.  It is a decent guess and it was all
--- there was; it is not the document.
local function text_behind(context)
  return document_tail(context) or commit_tail(context.commit_history)
end

--- Is the application in front of the caret one of `list`?
---
--- Comma separated, matched on the whole name and case-blind, which is how
--- both lists that use it are written by hand.  An empty list matches nothing
--- -- the two callers read that as "everywhere" and "nowhere" respectively,
--- and each says so where it asks.
local function app_listed(context, list)
  local app = context:get_property("client_app")
  if not app or app == "" or not list or list == "" then return false end
  app = app:lower():gsub("^%s+", ""):gsub("%s+$", "")
  for name in list:lower():gmatch("[^,]+") do
    if name:gsub("^%s+", ""):gsub("%s+$", "") == app then return true end
  end
  return false
end

--- The four features the F4 menu can turn on and off while you type.
---
--- `spellless/<name>` in the schema is the *setting*: what this feature does
--- unless somebody says otherwise, and the only place to say it permanently.
--- The switch of the same name is a session-long override of that setting, for
--- deciding whether you want it at all -- which is a question about how it
--- feels to type with, and cannot be answered by editing a file and redeploying
--- between every comparison.
---
--- A Rime option is a plain boolean with no third "unset" state, so a switch
--- cannot start anywhere but off by itself, and `reset:` in the schema would
--- be a second place to write the default down and a second thing to drift.
--- The options are set from the settings instead, once, the first time a
--- context is used: the menu then opens showing what is actually true, a flip
--- lasts as long as the context that heard it, and there is exactly one place
--- a permanent answer is written.
local SWITCHED = { "reclaim_space", "absorb_fragment",
                   "ascii_fragment", "word_backspace" }
--- Stamped on a context whose switches have been given their starting values,
--- with the settings they were given.  A stamp rather than a flag so that the
--- invariant is the honest one -- the switches follow the settings, unless you
--- have flipped one since the settings last changed -- rather than "whatever
--- happened to be read first wins".  In a running input method the settings
--- change only when a schema is loaded, which brings a new context with it, so
--- this costs one comparison and never fires; it is what makes the rule
--- statable at all.
local SWITCHES_SET = "spellless_switches"

--- A switch flipped in the F4 menu belongs to the context that heard it, and
--- Rime gives each application its own.  So a flip is for the window you are
--- in and the setting is for everywhere -- the same division `edit_document`
--- has, and the reason a permanent answer goes in the schema.
local function feature(context, engine, name)
  local cfg = engine.cfg
  local mark = (cfg.reclaim_space and "1" or "0")
      .. (cfg.absorb_fragment and "1" or "0")
      .. (cfg.ascii_fragment and "1" or "0")
      .. (cfg.word_backspace and "1" or "0")
  if context:get_property(SWITCHES_SET) ~= mark then
    for _, key in ipairs(SWITCHED) do
      context:set_option(key, cfg[key] and true or false)
    end
    context:set_property(SWITCHES_SET, mark)
  end
  return context:get_option(name)
end

--- The features that answer to an F4 switch, for the drift test.  A feature
--- the schema forgets to declare a switch for is configurable only by editing
--- a file, and nothing else would ever say so.
M.switched = SWITCHED

--- May we ask the frontend to take text back out of the document?
---
--- `reclaim_space`, `absorb_fragment` and `word_backspace` all work the same
--- way: the commit is prefixed with U+0008 and the frontend extends the
--- composition backwards over characters the application has already been
--- given, then rewrites the range.
---
--- Some applications cannot survive that, and VS Code's integrated terminal is
--- one.  Its text lives in a hidden textarea that xterm.js re-sends to the pty
--- whenever it changes, so touching the composition backwards does not correct
--- anything -- it replays the buffer.  Typing "Hello", space, "." produces
--- "Hello Hello.", and after deleting that and typing "Hey" it produces
--- "Hey Hello. Hey.".  The old content is still in the textarea and comes back.
---
--- Two things were tried before this and both were wrong, which is worth
--- recording because both look right.  Reading the document back does not
--- help: the read succeeds there, it just returns the buffer rather than the
--- line, so "can I read it" answers a different question from "can I edit it".
--- And verifying what is about to be taken does not help either: at the first
--- "Hello " the buffer and our own history agree exactly, and the replay
--- happens anyway.  The damage is in the edit itself, not in getting the
--- target wrong, so there is nothing to verify that would prevent it.
---
--- So this is decided by name, and the name is all there is.  VS Code is two
--- applications under one executable -- an editor that takes the edit and a
--- terminal that cannot -- and nothing reaching this function can separate
--- them.  Refusing both is the answer that cannot corrupt a line.
local function may_edit_document(context, engine)
  if not engine then return false end
  -- Nothing is asked of a frontend that has not shown it can answer.  This is
  -- what lets the three features ship *on*: on stock Weasel or stock Squirrel
  -- the latch never trips, so the U+0008 is never emitted and nothing can
  -- arrive as literal text.  See FRONTEND_READS.
  if not FRONTEND_READS then return false end
  if context:get_option("commit_only") then return false end
  -- The list cannot tell VS Code's editor from VS Code's terminal, so the
  -- person typing is allowed to.  `edit_document` is a switch in the F4 menu:
  -- turn it on while writing prose in an application the list distrusts, and
  -- off again before going back to its terminal.  It resets every session,
  -- because leaving it on in the wrong window is the failure it exists to
  -- avoid.
  if context:get_option("edit_document") then return true end
  return not app_listed(context, engine.cfg.commit_only_apps)
end

--- Is a feature that names `list` allowed in the application we are typing
--- into?  An empty list means everywhere: `snippet_apps` and `delimiter_apps`
--- are both permissions, and a permission nobody wrote is not a refusal.
local function app_allows(context, list)
  return list == "" or app_listed(context, list)
end

-- ---------------------------------------------------------------------------
-- commands typed mid-word
-- ---------------------------------------------------------------------------

--- What each command key does.
---
--- Three of them set a case, which is the case this whole mechanism was asked
--- for.  Capitalisation is otherwise *inferred* -- from what you typed, from
--- whether a sentence just ended, from what you have chosen before -- and
--- inference is right most of the time and unarguable with when it is not.
--- These are the argument: `qqc` for an acronym, `qqf` for a name the
--- dictionary reads as an ordinary word, `qql` for a word at the start of a
--- sentence that should not have been capitalised.
---
--- The fourth undoes a mistake in the other direction, and is Control+Shift+D
--- without the chord.
local MAGIC = {
  c = { case = "upper" },   -- CANDIDATES
  f = { case = "title" },   -- Candidates
  l = { case = "lower" },   -- candidates, defeating an automatic capital
  d = { forget = true },    -- take the highlighted one out of the personal store
}

--- Everything the text behind the cursor implies for the next word.
---
--- `input` is only used to recognise the version query.  It is worth passing
--- for that alone: the three diagnostic fields below cost an application-name
--- lookup and a list scan, and paying for them on every keystroke to answer a
--- question asked once a session is the wrong trade.
local function read_behind(engine, context, input)
  local cfg = engine.cfg
  local tail = text_behind(context)
  local document = document_tail(context)
  local out = {
    literal_first = preceding.expects_literal(tail),
    sentence_start = false,
    -- A digit hard against the caret: what follows is notation, not a word.
    -- "4" goes straight into the document rather than into a composition, so
    -- by the time "D" is typed the matcher has no idea a 4 is in front of it
    -- unless this says so.
    after_digit = tail ~= nil and tail:match("%d$") ~= nil,
    -- "would relate", never "would related".  Read from the same tail as
    -- everything else here, so it works from the commit history alone and does
    -- not wait on a frontend that can read the document.
    prefer_bare = preceding.expects_bare_verb(tail),
    -- Asked for outright with `qq`, and therefore beating everything the rest
    -- of this function infers.  Set below rather than here: get_property
    -- returns "" for unset and "" is truthy in Lua, so assigning it straight
    -- across would silently defeat every automatic capital there is.
    force_style = nil,
  }
  if cfg.version_query ~= "" and input and input:lower() == cfg.version_query then
    -- Read back by the version query, which is the one place that has to
    -- report what the matcher can actually see rather than what the
    -- configuration says it should.
    out.client_app = context:get_property("client_app")
    out.may_edit = may_edit_document(context, engine)
    out.readable = document ~= nil
    -- As the switches have them now, which is the half a configuration file
    -- cannot show you.
    out.features = {}
    for _, key in ipairs(SWITCHED) do
      out.features[key] = feature(context, engine, key)
    end
  end
  local forced = context:get_property(FORCED_CASE)
  if forced ~= "" then out.force_style = forced end

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
  if document then
    -- No note needed: the text is right there.
    out.sentence_start = preceding.starts_fresh(tail)
        or preceding.ends_sentence(tail, engine.corpus.abbreviations)
    return out
  end

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
  -- Every input to the answer belongs in this key.  A field left out is a
  -- stale list served with no way to tell: `force_style` was omitted once and
  -- `qqc` did nothing at all, because the pre-command answer for the same
  -- letters was still sitting here.
  local key = tostring(behind.sentence_start) .. tostring(behind.literal_first)
      .. tostring(behind.client_app) .. tostring(behind.force_style)
      .. tostring(behind.prefer_bare) .. tostring(behind.after_digit)
      .. tostring(behind.ascii_fragment)
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
  local behind = read_behind(engine, context, input)
  local candidates = suggest(engine, input, behind)
  local debug_comments = engine.cfg.show_debug_comments
  local raw_comment = engine.cfg.raw_comment
  -- The space rides along with the word, so whichever key commits it -- space
  -- bar, a number, a click -- puts the space in too.  Unless `leading_space`
  -- is on, in which case the next word brings its own and this one goes bare;
  -- see the note in the processor.
  -- A word taken back out of the middle of a line is the exception: its
  -- separator is still in the document.  See RESUMED.
  local trail = (engine.cfg.auto_space and not engine.cfg.leading_space
                 and context:get_property(RESUMED) ~= "1") and " " or ""

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
      and not engine.cfg.leading_space
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
-- processor: picking up a word already in the document
-- ---------------------------------------------------------------------------

--- Wire in as `lua_processor@*spellless*absorb`, *before* the speller.
---
--- Delete the space after "so", realise you meant "sooner", and type "oner":
--- Rime starts a fresh composition and offers you "one".  The "so" is right
--- there in front of the caret and belongs to the word being typed.
---
--- So take it back: remove it from the document and push it into the
--- composition, which then reads "so" + whatever you type next.  Everything
--- downstream is an ordinary word from there on -- the preedit, the
--- candidates, the commit -- with no special case anywhere.
---
--- This has to run before the speller, because the speller consumes the letter
--- and returns kAccepted, and a processor after it never sees the key at all.
M.absorb = {}

function M.absorb.init(env)
  env.spellless = acquire(env)
end

local function is_word_char(code)
  return (code >= 0x41 and code <= 0x5a) or (code >= 0x61 and code <= 0x7a)
end

function M.absorb.func(key, env)
  local engine = env.spellless
  if key:release() then return kNoop end
  local context = env.engine.context

  -- This gear runs before the speller, so it is the only one that sees every
  -- key: a letter is consumed by the speller and never reaches the processor
  -- below.  That makes it the only place the "was the last key a Backspace"
  -- flag can honestly be kept.
  --
  -- Read before it is cleared: it is the only evidence available about *why*
  -- the caret is sitting flush against a word, and the answer decides whether
  -- the word will need a space after it.  See RESUMED below.
  local after_backspace = context:get_property(BACKSPACE) == "1"
  if key.keycode ~= XK_BackSpace then
    context:set_property(BACKSPACE, "")
  end
  -- A composition that has ended takes its note with it.  Here rather than in
  -- the commit notifier because a composition can also end by being committed
  -- from this file -- punctuation, Return -- and those never reach it.
  if not context:is_composing() then context:set_property(RESUMED, "") end
  if key.keycode ~= XK_space then
    context:set_property(LITERAL, "")
  end

  -- Was this key a deliberate pick of a candidate by its number?
  --
  -- The space bar is not.  At speed nobody reads the list -- the space bar
  -- goes on muscle memory and whatever is first goes in -- so counting it as
  -- "this is the word I meant" teaches the list to insist on its own first
  -- guess, and a wrong one entrenches itself the second time you fail to
  -- notice it.  A number key is aimed at a particular line and means what it
  -- says.
  --
  -- Only the digits that actually select something: the page holds seven
  -- candidates, so `8` and `9` name nothing, and whatever the frontend then
  -- does with the keystroke must not be recorded as a choice of the line that
  -- happened to be highlighted at the time.
  local page = env.engine.schema.page_size or 9
  if page > 9 then page = 9 end
  local picked = context:is_composing()
      and key.keycode >= 0x31 and key.keycode <= 0x30 + page
      and not (key:ctrl() or key:alt() or key:super())
  context:set_property(PICKED, picked and "1" or "")

  -- Two answers to one situation, and the schema picks which.  `ascii_fragment`
  -- wins where both are on: it is the more conservative of the two, and
  -- somebody who turned it on asked for it.
  if not engine then return kNoop end
  -- The switch is how it gets tried: F4, flip it, type for a day.  Reading it
  -- as an override rather than as the setting keeps the schema key meaning
  -- what every other schema key means -- this is what happens unless you say
  -- otherwise -- and matches `edit_document`, the other switch that turns
  -- something on for the window you are in.
  local handover_ascii = feature(context, engine, "ascii_fragment")
  if not (handover_ascii or feature(context, engine, "absorb_fragment")) then
    return kNoop
  end
  -- Absorbing *deletes* from the document and so needs a frontend that will
  -- let it; handing the keyboard over deletes nothing, and works anywhere the
  -- document can be read -- a terminal, an application on `commit_only_apps`.
  if not handover_ascii and not may_edit_document(context, engine) then
    return kNoop
  end
  if key:ctrl() or key:alt() or key:super() then return kNoop end
  if not is_word_char(key.keycode) then return kNoop end
  if context:is_composing() then return kNoop end

  -- Only from the document.  Absorbing means deleting, and Rime's own commit
  -- history is a guess -- it is cleared by the very Backspace that creates
  -- this situation.
  local document = document_tail(context)
  if not document then return kNoop end
  local fragment = document:match("([%a][%a']*)$")
  if not fragment then return kNoop end

  -- The other answer: do not take the word anywhere, just stop being an input
  -- method until it is finished.
  --
  -- The reasoning behind absorbing is that the letters in front of the caret
  -- belong to the word being typed, so the composition should hold them.  That
  -- is true, and it still asks the matcher to guess at a word whose boundary
  -- nobody knows: the letters after the caret are invisible from here, and
  -- every rule downstream -- the trailing space, the sentence capital, what
  -- the candidates even are -- is answering a question about a word it can
  -- only see half of.
  --
  -- So: hand the keyboard to ASCII mode and let the letters land as letters.
  -- No candidates, no capital, no space, nothing to undo.  `handover` gives it
  -- back at the first key that is not part of a word, which is where the word
  -- was going to end anyway.
  --
  -- kRejected rather than kNoop, because ascii_composer has already run for
  -- this key -- it sits ahead of this gear -- and would not see the mode we
  -- just set.  Rejecting means librime does the default processing and the
  -- letter reaches the application as itself, which is the same trick the
  -- snippet triggers use.
  if handover_ascii then
    context:set_option("ascii_mode", true)
    context:set_property(ASCII_WORD, "1")
    context:set_property(SENTENCE, "")
    return kRejected
  end

  -- Take it out of the document and put it in the composition.  kNoop, so the
  -- speller then appends the letter that started all this.
  --
  -- Only the letters come out; whatever separated the word from what follows
  -- it is untouched.  So if the caret was put here by a click or an arrow key
  -- -- the middle of a line, a word being corrected in place -- the space
  -- after that word is still there, and the one every candidate carries would
  -- make two.  Say so, and the translator sends the word back bare.
  --
  -- A Backspace is the exception, and it is the case this feature was written
  -- for: delete the space after "so" and start typing again, and there is
  -- nothing after the caret to separate the word from.  Then the space is due
  -- as usual.
  --
  -- The evidence is the key before this one and that is all it is: Backspace
  -- somewhere else, then a click, then a letter still reads as the first case.
  -- Nothing here can see past the caret -- the frontend reads the text in
  -- front of it and no further -- so this is the honest end of what is
  -- knowable, and the cost of being wrong is one space either way.
  context:set_property(RESUMED, after_backspace and "" or "1")
  env.engine:commit_text(string.rep("\8", #fragment))
  context:push_input(fragment)
  return kNoop
end

-- ---------------------------------------------------------------------------
-- processor
-- ---------------------------------------------------------------------------

--- Wire in as `lua_processor@*spellless*processor`, before express_editor.
---
--- express_editor owns Return -- committing the raw input is the promise that
--- you can always commit exactly what you typed -- and this processor takes it
--- over only to add the automatic space, which a schema-level editor knows
--- nothing about.  With `enter_space` or `auto_space` off it gets out of the
--- way and the editor does exactly what it did before.
---
--- It also owns the spaces between words, and watches Return and Backspace
--- outside a composition -- the only way to tell a new line from a correction
--- after Rime has cleared its commit history for both.
---
--- A word carries its own trailing space, so whichever key commits it puts the
--- space in too.  Punctuation is the exception that needs no retraction: it
--- ends the word before the space is ever written and supplies the following
--- one itself.  Rime cannot take committed text back -- `key_binder`'s `send:`
--- re-processes a key inside the engine and drops it if nothing handles it, so
--- a synthetic Backspace never reaches the application -- which is why the
--- frontend fork exists for the cases where something has to come back.
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
  local forget_key = (key:ctrl() and key:shift() and (code == XK_d or code == XK_D))
      or (code == XK_Delete and (key:ctrl() or key:shift()))
  if forget_key then
    local engine = env.spellless
    if not engine then return kNoop end
    local composing = context:is_composing()
    local word
    if composing then
      local chosen = context:get_selected_candidate()
      word = chosen and chosen.text
    else
      word = context.commit_history:latest_text()
    end
    local gone = word and engine:forget(word)
    -- Say so.  Without this the whole thing was invisible: the key was
    -- swallowed, the menu was never re-queried, and the list looked exactly as
    -- it had a moment earlier -- indistinguishable from a shortcut that had
    -- never arrived.
    log.info(("spellless: forget %q -> %s"):format(tostring(word),
             gone and "removed" or "was not in the personal store"))
    if composing then
      -- Re-run the translation so the reordering is on screen at once.
      context:refresh_non_confirmed_composition()
    end
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

  -- The space in front of the word, for frontends that cannot take one back.
  --
  -- Everything else here puts the automatic space *after* the word, which is
  -- what you want: stop typing anywhere and the text is finished.  It costs
  -- one thing, and only one -- when punctuation follows a word that has
  -- already been committed, "you " + "." has to become "you." by asking the
  -- frontend to take the space back.  Stock Rime cannot, so on it that comes
  -- out as "you ."  It is not rare: it is every time you pick a candidate by
  -- number and then end the sentence.
  --
  -- With `leading_space` on, the word commits bare and the space is put in by
  -- the *next word* instead, at the moment it starts.  Punctuation then needs
  -- nothing taken back because there is nothing behind it to take, and so do
  -- "3.14", "1,000" and "12:30", which are the other half of what
  -- `reclaim_space` exists for.
  --
  -- Off by default, because the trade is real and goes the other way for
  -- anyone whose frontend can reclaim: leave the caret after a word and there
  -- is no space after it until you type again, so a line you stop in the
  -- middle of ends flush.
  --
  -- Written here, on the first letter of the next word, rather than as a
  -- leading space on the candidate itself.  A candidate carrying its own
  -- space shows the space in the candidate list, and shows it against every
  -- reading, which looks like a bug and is read as one.  This way the list is
  -- exactly what it always was and the document gets the space at the same
  -- moment it would have got the trailing one.
  if engine and engine.cfg.auto_space and engine.cfg.leading_space
     and not composing and not key:shift()
     and ((code >= 0x61 and code <= 0x7a) or (code >= 0x41 and code <= 0x5a)) then
    if preceding.needs_space_after(text_behind(context)) then
      env.engine:commit_text(" ")
    end
  end

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
    -- Keypad Enter is Enter, so it carries the automatic space with it.
    -- Shift+Return does not: a space in front of a line break separates
    -- nothing from nothing.
    local trail = (code == XK_KP_Enter and engine and engine.cfg.auto_space
                   and engine.cfg.enter_space
                   and not engine.cfg.leading_space) and " " or ""
    env.engine:commit_text(text .. trail)
    if engine then engine:learn(text) end
    context:set_property(SENTENCE, "")
    context:clear()
    -- Keypad Enter *is* Enter: commit and stop.  Shift+Return is the soft
    -- newline in Slack and Zulip, so the word is committed and the key goes on
    -- to the application, which is what it was asking for all along.
    if code == XK_KP_Enter then return kAccepted end
    return kNoop
  end

  -- Return on a candidate you moved to: commit that candidate.
  --
  -- The arrow keys are how you disagree with the ranking without counting
  -- lines, and having disagreed, Return is the key already under the finger.
  -- Committing the raw input there would throw the choice away and give back
  -- the letters that were wrong enough to go looking -- so with the highlight
  -- moved, Return does what the space bar does: `Context:commit()`, the same
  -- call express_editor makes, which takes the highlighted candidate with the
  -- space it carries.
  --
  -- On the first candidate Return still commits exactly what you typed.  That
  -- is the promise, and it is why the test is the highlight rather than "was
  -- an arrow key pressed": a fresh composition and one you arrowed back to the
  -- top of look the same because they are the same, and the literal reading is
  -- always one press of Return away.
  --
  -- Counted as a deliberate choice, which the space bar is not: the space bar
  -- takes whatever is first on muscle memory, and this took two keys aimed at
  -- one line.
  if composing and code == XK_Return and not key:shift() then
    local segment = context.composition and context.composition:back()
    if segment and (segment.selected_index or 0) > 0 then
      context:set_property(PICKED, "1")
      context:commit()
      return kAccepted
    end
  end

  -- Return, carrying the automatic space.
  --
  -- express_editor commits the raw input, which is the promise that you can
  -- always commit exactly what you typed -- and it commits the letters alone,
  -- because a schema-level editor knows nothing about our spacing.  A word
  -- finished with Return is as finished as one picked with the space bar
  -- though, and the next word has to be separated from it either way, so the
  -- space rides along here as it does on every candidate.  The letters are
  -- still exactly the ones typed.
  --
  -- Handled here rather than left to the editor, and learned by hand: this
  -- commit is ours, so the notifier the translator connected never sees it.
  -- It is a refusal to choose between readings rather than a choice, so the
  -- word is counted and no input-to-word pair is recorded.
  if composing and code == XK_Return and engine
     and engine.cfg.auto_space and engine.cfg.enter_space
     and not engine.cfg.leading_space then
    local text = context.input
    env.engine:commit_text(
        text .. (context:get_property(RESUMED) == "1" and "" or " "))
    engine:learn(text)
    context:set_property(SENTENCE, "")
    context:clear()
    return kAccepted
  end

  -- A number our own spacing would otherwise split.  "3" then "." commits
  -- ". " -- correctly, since nothing yet says a digit is coming -- and the
  -- digit that follows says so.  Taking the space back then is the only way
  -- to get "3.14" without either guessing ahead or leading spaces.
  -- Covers "1,000", "12:30" and "Smith:2020" as well.
  if engine and engine.cfg.auto_space and feature(context, engine, "reclaim_space")
     and not composing and code >= 0x30 and code <= 0x39
     and not key:shift() and may_edit_document(context, engine) then
    local behind = commit_tail(context.commit_history)
    if behind:match("%d[%.,:] $") then
      env.engine:commit_text("\8" .. string.char(code))
      return kAccepted
    end
  end

  -- The space bar over a literal candidate: ask once.
  --
  -- Reaching here means nothing in the dictionary was worth putting under the
  -- space bar, so the candidate is the raw input -- a word the dictionary does
  -- not have, which is usually a misspelling rather than a decision.  The
  -- first space is swallowed and the composition stays on screen; the second
  -- commits.  Anything else typed in between cancels it, because the reason to
  -- pause was that the word was wrong.
  if composing and engine and engine.cfg.confirm_literal and code == XK_space
     and not key:ctrl() and not key:alt() and not key:super() then
    local chosen = context:get_selected_candidate()
    if chosen and chosen.type == "raw"
       and context:get_property(LITERAL) ~= "1" then
      context:set_property(LITERAL, "1")
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
    if feature(context, engine, "reclaim_space") and preceding.hugs_previous(mark)
       and may_edit_document(context, engine) then
      local stripped = behind:match("^(.-) $")
      if stripped then reclaim, behind = "\8", stripped end
    end

    -- With `leading_space` the next word brings its own, so the mark goes in
    -- bare and the rule stays "a space is put in by whatever follows it".
    local space = (not engine.cfg.leading_space)
        and preceding.needs_space_after(behind .. mark) and " " or ""
    env.engine:commit_text(reclaim .. mark .. space)
    -- `$` opens maths, and maths is not English: hand the keyboard over.  The
    -- mark itself has just been written by the ordinary punctuation path, with
    -- the spacing that path works out -- opening marks keep the space in front
    -- of them and take none after -- so all that is left is the switch.  The
    -- delimiter is remembered because only the one that opened a run closes
    -- it; see `delimiter` below, which is the half that has to run in ASCII
    -- mode.
    if engine.cfg.ascii_delimiters:find(mark, 1, true)
       and app_allows(context, engine.cfg.delimiter_apps)
       and not context:get_option("ascii_mode") then
      context:set_property(DELIMITER, mark)
      context:set_property(SENTENCE, "")
      context:set_option("ascii_mode", true)
    end
    return kAccepted
  end

  if key:shift() then return kNoop end

  if not composing then
    -- Rime is about to clear its commit history for either of these, taking
    -- the size to zero, so stamp the note with what it will be, not what it is.
    if code == XK_Return or code == XK_KP_Enter then
      context:set_property(SENTENCE, SENTENCE_YES .. ":0")
      context:set_property(BACKSPACE, "")
    elseif code == XK_BackSpace then
      -- Twice in a row takes the whole word, for when it is wrong enough to
      -- start again rather than pick at.  The first one is an ordinary
      -- Backspace, which is what makes this discoverable: you delete the
      -- space, see the word, and hit it again.
      local repeated = context:get_property(BACKSPACE) == "1"
      context:set_property(SENTENCE, SENTENCE_NO .. ":0")
      context:set_property(BACKSPACE, "1")
      -- Only with nothing composing: while a word is being typed, Backspace
      -- belongs to the composition.
      if repeated and engine and feature(context, engine, "word_backspace")
         and may_edit_document(context, engine) then
        local document = document_tail(context)
        local word = document and document:match("([%a][%a']*)$")
        if word then
          -- One short, and the key itself supplies the last character.
          --
          -- Asking for the whole word and swallowing the keystroke was a trap:
          -- the request is a commit, and a commit is only a request -- if the
          -- frontend will not or cannot carry it out, nothing is deleted and
          -- the press is simply gone.  Alternating with ordinary presses that
          -- reads as "Backspace deletes a character every other time", which
          -- is a far worse bug than the feature is a feature.
          --
          -- Leaving the last one to the key means the failure is ordinary: the
          -- word goes if the frontend obliges, and one character goes if it
          -- does not, which is what Backspace was going to do anyway.
          if #word > 1 then
            env.engine:commit_text(string.rep("\8", #word - 1))
          end
          context:set_property(BACKSPACE, "")
        end
      end
    end
    return kNoop
  end

  -- Return with the space turned off needs no handling: express_editor commits
  -- the raw input, which fires the commit notifier, which learns it.
  return kNoop
end

-- ---------------------------------------------------------------------------
-- processor: handing the keyboard to the editor
-- ---------------------------------------------------------------------------

--- Wire in as `lua_processor@*spellless*handover`, *first* -- before
--- `ascii_composer`, and therefore before the speller too.
---
--- Two ways out of English, both of which have to be seen before anything else
--- gets the key.
---
--- **The closing delimiter.** Typing `$` hands the keyboard over to ASCII mode
--- (see the punctuation branch above), and the closing `$` has to hand it
--- back.  Nothing behind `ascii_composer` can: in ASCII mode it rejects
--- printable keys where it stands, first in the list, and no processor after
--- it ever sees them.  Only the delimiter that opened a run closes it, and a
--- run nobody opened is not closed at all -- a `$` in ASCII mode you reached
--- by tapping Shift is an ordinary dollar sign, which is what typing `$PATH`
--- in a terminal needs it to be.
---
--- **An editor snippet trigger.** `dm` is two letters that mean a display
--- maths block to VS Code and nothing at all to English, so they are committed
--- verbatim the moment they are complete -- no space, no capital, no candidate
--- list -- and the keyboard goes to ASCII mode for the maths that follows.
--- This has to be in front of the speller, which consumes letters and returns
--- kAccepted; a processor behind it never sees one.  See snippets.lua.
--- Run a command if one was asked for, and say whether the key was used.
---
--- Returns a ProcessResult when the key belonged to this mechanism, and nil
--- when it did not -- so the caller carries on and the key is ordinary text.
--- That distinction is the whole safety argument: arming costs nothing and
--- disarms on anything unrecognised, so `zzxxqq` is still `zzxxqq`.
local function handle_magic(key, context, engine)
  local prefix = engine.cfg.magic_prefix
  if prefix == "" then return nil end
  local code = key.keycode
  local input = context.input

  -- Armed by the previous keystroke, and still on the same word?  The stamp
  -- matters: without it an arming survives a commit and the first letter of
  -- the next word runs a command nobody asked for.
  if context:get_property(ARMED) == input and input:sub(-#prefix) == prefix then
    context:set_property(ARMED, "")
    local command = code > 0x20 and code < 0x7f
        and MAGIC[string.char(code):lower()]
    if command then
      -- The prefix was never part of the word, so it goes before anything
      -- else happens.  pop_input rather than rewriting `input`, because the
      -- composition is the speller's and it knows how to shorten itself.
      context:pop_input(#prefix)
      if command.case then
        context:set_property(FORCED_CASE, command.case)
      elseif command.forget then
        local chosen = context:get_selected_candidate()
        local word = chosen and chosen.text:gsub("%s+$", "")
        local gone = word and word ~= "" and engine:forget(word)
        log.info(("spellless: qq-forget %q -> %s"):format(tostring(word),
                 gone and "removed" or "was not in the personal store"))
      end
      context:refresh_non_confirmed_composition()
      return kAccepted
    end
    return nil          -- not a command: the key is text, and so was the `qq`
  end

  -- Arm, without consuming anything.  The prefix stays in the composition and
  -- the candidate list goes on answering it, so nothing is lost if the next
  -- key turns out to be a letter.
  --
  -- Only written when it changes.  This runs on every printable key of every
  -- word, and the overwhelmingly common case is "" -> "", which is a write to
  -- librime's property map and a notification for nothing.
  if code > 0x20 and code < 0x7f then
    local typed = input .. string.char(code)
    local arm = typed:sub(-#prefix) == prefix and typed or ""
    if arm ~= context:get_property(ARMED) then
      context:set_property(ARMED, arm)
    end
  end
  return nil
end

M.handover = {}

function M.handover.init(env)
  env.spellless = acquire(env)
end

function M.handover.func(key, env)
  local engine = env.spellless
  if not engine then return kNoop end
  if key:release() or key:ctrl() or key:alt() or key:super() then return kNoop end
  local context = env.engine.context
  if not context:get_option("ascii_mode") then
    -- Back in Spellless mode by some other route -- a tapped Shift, F4,
    -- Control+Shift+A -- so the run is over however it ended, and the next `$`
    -- opens rather than closes.  Forgetting it here rather than watching for
    -- the Shift tap keeps this gear ignorant of how the mode changed, which is
    -- the only way it can be right about all the ways it can.
    if context:get_property(DELIMITER) ~= "" then
      context:set_property(DELIMITER, "")
    end
    if context:get_property(ASCII_WORD) ~= "" then
      context:set_property(ASCII_WORD, "")
    end

    -- A command typed into the middle of a word.
    --
    -- `qq` arms; the next key runs.  Both halves are here, in the gear that
    -- runs before the speller, because the speller consumes letters and a
    -- processor behind it never sees one.
    local magic = handle_magic(key, context, engine)
    if magic ~= nil then return magic end

    -- A trigger is the whole composition and nothing else, which is where
    -- HyperSnips' word-boundary rule ends up when you arrive at it from this
    -- side: `dm` fires, `dmn` does not, and neither does the `dm` inside
    -- `midmost`.  The letters go in exactly as typed -- a capital from the
    -- start of a sentence would be a different snippet, or none.
    local code = key.keycode
    if code > 0x20 and code < 0x7f and engine.snippets.count > 0
       and app_allows(context, engine.cfg.snippet_apps) then
      local typed = context.input .. string.char(code)
      local snippet = engine.snippets:get(typed)
      if snippet then
        -- Commit all but the last letter, and let the last one through as a
        -- real keystroke.
        --
        -- HyperSnips expands an automatic snippet from a document-change event
        -- and drops any change that is not exactly one character long -- its
        -- own comment says "let's try to detect only events that come from
        -- keystrokes", which is a fair guard against expanding on paste and
        -- which a commit fails.  `xthm` arrives as one four-character change
        -- and expands nothing; the same letters typed in ASCII mode arrive as
        -- four one-character changes and expand fine.
        --
        -- Committing them one at a time does not help, and it is worth writing
        -- down why so nobody tries it twice: librime accumulates the commits
        -- of a single keystroke into one string -- `commit_text_ += ...` in
        -- service.cc -- which the frontend reads once.  Four calls and one
        -- call put exactly the same four characters in the document, in one
        -- change.
        --
        -- But the guard only looks at the change that just arrived.  How the
        -- text before it got there is not its business.  So the prefix is
        -- committed and the final letter is rejected, which in librime means
        -- "do the OS default processing" -- the key reaches the application as
        -- itself, the change is one character long, and the context it lands
        -- in is the whole trigger.
        if #typed > 1 then
          env.engine:commit_text(typed:sub(1, #typed - 1))
        end
        context:set_property(SENTENCE, "")
        context:clear()
        -- `xdm` opens maths and `xthm` opens a theorem, whose body is English
        -- and wants the matcher on.  The trigger says which it is.
        if snippet.ascii then context:set_option("ascii_mode", true) end
        return kRejected
      end
    end
    return kNoop
  end

  -- A word we handed over ends at the first key that is not part of a word,
  -- and that is the whole rule: the mode was borrowed for one word and the
  -- word is over.  The key itself is not consumed -- it goes on to be a space,
  -- a full stop, a Return, in English again, with all the spacing and
  -- capitalisation that implies.
  --
  -- Backspace is part of the word.  Correcting the thing you came here to
  -- correct must not drop you back into the matcher half way through it, where
  -- a composition would start from whatever letters were left.
  --
  -- Nothing here watches the caret, so clicking away in the middle of such a
  -- word leaves the mode on until the next non-letter.  A tap on Shift is the
  -- way out of that, as it is out of every other ASCII run.
  if context:get_property(ASCII_WORD) == "1" then
    local code = key.keycode
    if not (is_word_char(code) or code == 0x27 or code == XK_BackSpace) then
      context:set_property(ASCII_WORD, "")
      context:set_option("ascii_mode", false)
    end
    return kNoop
  end

  -- The two halves are configured apart: a list of snippet triggers is useful
  -- with no delimiters at all, in an application that has no snippet engine
  -- but plenty of maths.
  if engine.cfg.ascii_delimiters == "" then return kNoop end
  if not app_allows(context, engine.cfg.delimiter_apps) then return kNoop end
  local code = key.keycode
  if code <= 0x20 or code >= 0x7f then return kNoop end
  local mark = string.char(code)
  if context:get_property(DELIMITER) ~= mark then return kNoop end

  -- The space after it is ours to decide, and the usual test cannot help:
  -- everything typed inside the run went straight to the application, so the
  -- commit history still reads as it did before the run opened.  A closing
  -- delimiter is followed by a space for the same reason a word is -- the next
  -- word has to be separated from it -- and punctuation takes it back on the
  -- frontend that can (§5.6), exactly as it does after a word.
  local space = (engine.cfg.auto_space and not engine.cfg.leading_space)
      and " " or ""
  env.engine:commit_text(mark .. space)
  context:set_property(DELIMITER, "")
  context:set_property(SENTENCE, "")
  context:set_option("ascii_mode", false)
  return kAccepted
end

return M
