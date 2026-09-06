-- The Spellless matching engine.
--
-- Pure Lua: it knows nothing about Rime, which is what lets tests/ and bench/
-- exercise exactly the code the IME runs.  `spellless.lua` is the thin adapter
-- that wires this to librime-lua.

local Corpus = require("spellless.corpus")
local UserDB = require("spellless.userdb")
local cue = require("spellless.cue")
local Shortcuts = require("spellless.shortcuts")
local split = require("spellless.split")
local config = require("spellless.config")
local generate = require("spellless.generate")
local rank = require("spellless.rank")
local skeleton = require("spellless.skeleton")
local distance = require("spellless.distance")
local util = require("spellless.util")

local Engine = {}
Engine.__index = Engine

--- opts:
---   data_dir       directory holding the generated/ files        (required)
---   user_dir       directory for the personal vocabulary file    (optional)
---   personal_path  full path to it, overriding user_dir          (optional)
---   config         table of overrides for spellless.config       (optional)
---   now_ms         function returning a millisecond clock        (optional)
function Engine.new(opts)
  local cfg = config.build(opts.config)
  local corpus, err = Corpus.load(opts.data_dir)
  if not corpus then return nil, err end

  local self = setmetatable({
    cfg = cfg,
    corpus = corpus,
    now_ms = opts.now_ms or function() return 0 end,
  }, Engine)

  local personal = opts.personal_path
      or (opts.user_dir and util.join(opts.user_dir, cfg.personal_file))
  -- With no path at all the personal store still exists, it just never loads
  -- or saves; that keeps every other code path free of nil checks.
  self.user = UserDB.load(personal or "", cfg)
  self.user.path = personal
  self.last_flush = 0
  self:repair_personal()

  -- Abbreviations the user defined.  Read once: it is a handful of lines that
  -- someone edits deliberately, and a redeploy picks up changes.
  self.shortcuts = Shortcuts.load(
      opts.shortcuts_path
      or (opts.user_dir and util.join(opts.user_dir, cfg.shortcuts_file)))
  return self
end

--- Drop stored spellings that only differ by a leading capital on a word the
--- dictionary already knows.
---
--- Those are not preferences, they are sentence positions: automatic
--- capitalisation used to hand "The" to the learner, which then insisted on
--- "The" in the middle of every later sentence.  `learn` no longer creates
--- them; this clears out any that an earlier version wrote to the file.
function Engine:repair_personal()
  local user = self.user
  for word, spelling in pairs(user.surfaces) do
    if spelling == word:sub(1, 1):upper() .. word:sub(2) and self:dictionary_explains(word) then
      user:forget_surface(word)
    end
  end
end

-- ---------------------------------------------------------------------------
-- capitalisation
-- ---------------------------------------------------------------------------

--- Classify how the user capitalised their input so candidates can follow.
--- Matching itself is always done on the lowercased form.
local function case_style(raw)
  if raw:find("%u") == nil then return "lower" end
  if raw:upper() == raw and #raw >= 2 then return "upper" end
  if raw:sub(1, 1):find("%u") and raw:sub(2):find("%u") == nil then return "title" end
  return "mixed"
end
Engine.case_style = case_style

local function apply_case(word, style)
  if style == "upper" then return word:upper() end
  if style == "title" then return word:sub(1, 1):upper() .. word:sub(2) end
  return word
end
Engine.apply_case = apply_case

--- The text to actually show and commit for a matched word.
---
--- A few words have no valid lowercase spelling -- you can never mean a
--- lowercase pronoun "i" -- and the corpus, being lowercase throughout, cannot
--- say so.  generated/spellless.forms supplies those; note that `apply_case`
--- never lowercases, so a form survives however the input was capitalised.
function Engine:surface(word, style)
  -- How you write it yourself outranks the shipped form, which outranks the
  -- corpus's lowercase spelling.
  local form = self.user:surface(word) or self.corpus.forms[word]
  if not form then
    -- A possessive inherits its stem's spelling, so "Milnor" makes "Milnor's".
    local stem = word:match("^(.+)'s$")
    if stem then
      local base = self.user:surface(stem) or self.corpus.forms[stem]
      if base then form = base .. "'s" end
    end
  end
  return apply_case(form or word, style)
end

--- Is "<stem>'s" a word, because <stem> is one?
--- Personal vocabulary counts: names you have committed once -- Awodey, Riehl,
--- a collaborator, a package -- are exactly what possessives get attached to,
--- and without this the matcher reads "awodey's" as "Awodey" plus a typo and
--- quietly drops the possessive.
function Engine:possessive_stem(query)
  local stem = query:match("^(.+)'s$")
  if not stem then return nil end
  local id = self.corpus:lookup(stem)
  if id then return stem, self.corpus:weight(id) end
  if self.user:count(stem) > 0 then return stem, nil end
  return nil
end

--- English possessives are productive, and no word list can contain them all.
--- "<stem>'s" inherits the stem's frequency, and through `Engine:surface` its
--- spelling, so it ranks and reads like the name it is built from.
local function generate_possessive(self, query, out)
  local stem, weight = self:possessive_stem(query)
  if not stem then return end
  out[#out + 1] = { word = stem .. "'s", source = "exact", cost = 0, extra = 0,
                    freq = weight }
end

--- How a candidate should be capitalised.
--- An explicit capital in the input always wins: if you typed "mathe" at the
--- start of a sentence you meant a capital, but if you typed "MATHE" you meant
--- something else and we must not quietly undo it.
local function effective_style(style, sentence_start)
  if sentence_start and style == "lower" then return "title" end
  return style
end
Engine.effective_style = effective_style

-- ---------------------------------------------------------------------------
-- the user's own vocabulary
-- ---------------------------------------------------------------------------

--- Match the query against the user's own vocabulary directly.
---
--- This is a plain linear pass rather than an index lookup.  The list is small
--- by construction, and going through it every time is what guarantees that a
--- word you have actually chosen before is always in the running -- it cannot
--- be squeezed out of a corpus-frequency shortlist by commoner neighbours.
local function generate_personal(self, query, out)
  local cfg = self.cfg
  local words = self.user:words(cfg.personal_scan_limit)
  if #words == 0 then return end
  local corpus = self.corpus
  local qskel = skeleton.of(query)
  local qlen = #query
  local n = #out
  local function emit(word, source, cost, extra)
    n = n + 1
    out[n] = { word = word, id = corpus:lookup(word), source = source,
               cost = cost or 0, extra = extra or (#word - qlen) }
  end
  local longest = qlen + generate.ELASTIC_PROFILE.max_drift
  for i = 1, #words do
    local w = words[i]
    -- A hand-edited personal file can hold anything; a word far longer than
    -- the query cannot match and would cost a full n*m alignment to find that
    -- out.
    if #w > longest then
      -- skip
    elseif w == query then
      emit(w, "exact", 0)
    elseif w:sub(1, qlen) == query then
      emit(w, "prefix", 0)
    else
      local d = distance.distance(query, w, cfg.typo_budget, generate.TYPO_PROFILE)
      if d then emit(w, "typo", d) end
      if #qskel >= cfg.min_skeleton_len and #w >= qlen - 1 then
        local ds = distance.prefix_distance(query, w, cfg.elastic_budget, generate.ELASTIC_PROFILE)
        if ds then emit(w, "skeleton", ds) end
      end
      -- A name you have adopted deserves shorthand too: this is the same
      -- syllabic reading the dictionary scan does, and the list is short
      -- enough that every entry can simply be tried.
      if qlen >= cfg.min_cue_len then
        local dc = cue.align(query, w, cfg.cue_budget, cfg)
        if dc then emit(w, "cue", dc, 0) end
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- the query itself
-- ---------------------------------------------------------------------------

--- Ranked suggestions for `raw` as typed.
---
--- `opts.sentence_start` says the text before this word ended a sentence, so
--- candidates should lead with a capital.  `opts.literal_first` says the text
--- before it means we must not guess at all -- a LaTeX control sequence, say.
--- Working both out is the adapter's job; everything here stays independent of
--- Rime.
---
--- Returns a list of { text, source, score, cost, raw } and a stats table.
--- Offer the query cut back into words, when it is not a word itself.
---
--- The guard is the whole feature: "another" segments perfectly well into "a
--- not her", and "together" into "to get her".  A string that is already in
--- the dictionary is not a run of words that need separating -- it is a word,
--- and this project does not second-guess those.
local function find_split(self, query)
  local cfg = self.cfg
  if not cfg.split_words then return nil end
  -- The dictionary only.  A word committed once is not the language saying
  -- this is a word -- it is a record of something typed, quite possibly the
  -- very run-together this would fix.  "exactlyright" got committed while
  -- there was no other option, and that alone stopped it being split ever
  -- after.
  if self.corpus:lookup(query) then return nil end


  local found = split.best(self.corpus, query, cfg)
  if not found then return nil end

  -- Each part carries its own spelling, so "iamgoingtoschool" comes back as
  -- "I am going to school" rather than with a lowercase pronoun.
  local words, weakest = {}, 1
  for i, part in ipairs(found.parts) do
    words[i] = self:surface(part, "lower")
    local w = self.corpus:weight(found.ids[i])
    if w < weakest then weakest = w end
  end

  return {
    text = table.concat(words, " "),
    source = "split",
    cost = 0,
    score = weakest,
  }
end

function Engine:suggest(raw, limit, opts)
  local cfg = self.cfg
  local stats = {}
  if raw == "" then return {}, stats end
  local style = effective_style(case_style(raw), opts and opts.sentence_start)
  local query = raw:lower()
  limit = limit or cfg.limit

  -- A trailing "'s" is a statement of intent, and the only one available.
  -- "teachers", "students", "mothers" are ordinary plurals far more often than
  -- they are possessives, so guessing from a bare "s" would put a wrong
  -- candidate under every plural.  An apostrophe you actually typed cannot be
  -- anything else -- so the stem is matched on its own, and *every* candidate
  -- comes back possessive.  "mther's" is then "mother's", which is the whole
  -- point: the stem is what you might misspell.
  --
  -- Both endings, and the one you typed is the one you get back: "mther's" is
  -- "mother's" and "mthers'" is "mothers'".  Which is right depends on whether
  -- the noun is plural, and the apostrophe you placed already says so -- there
  -- is nothing here for the matcher to work out, and it should not try.
  --
  -- Contractions come out right for free: "it's" is stem "it" plus "'s".
  local stem, suffix
  if query:sub(-2) == "'s" then
    stem, suffix = query:sub(1, -3), "'s"
  elseif query:sub(-1) == "'" then
    stem, suffix = query:sub(1, -2), "'"
  end
  if stem and not stem:find("^[a-z][a-z']*$") then stem, suffix = nil, nil end
  local search = stem or query

  local typed_style = case_style(raw)
  local items, has_exact = {}, false
  if #search <= cfg.max_query_len and search:find("^[a-z][a-z']*$") then
    has_exact = self.corpus:lookup(query) ~= nil or self.user:count(query) > 0
        or self:possessive_stem(query) ~= nil
    items = generate.generate(self.corpus, search, cfg, stats)
    for i = 1, #items do
      local item = items[i]
      item.word = self.corpus.words[item.id]
      -- A written form means somebody decided what this key stands for.
      item.has_form = self.corpus.forms[item.word] ~= nil
    end
    generate_personal(self, search, items)
    if stem then
      -- A stem that already carries an apostrophe cannot take another: "it'd",
      -- "it's" and "mother's" would come back as "it'd's".  Plain trailing "s"
      -- is left alone, because "boss's" and "class's" are perfectly good, and
      -- so is "mothers'" once the apostrophe says which was meant.
      local kept = {}
      for i = 1, #items do
        if not items[i].word:find("'") then kept[#kept + 1] = items[i] end
      end
      items = kept
    else
      generate_possessive(self, query, items)
    end
  end

  local corpus, user = self.corpus, self.user
  local ctx = {
    text = function(item) return item.word end,
    -- A personal word absent from the corpus has no measured frequency; treat
    -- it as middling so its personal count, not a guess, does the ranking.
    freq = function(item)
      return item.freq or (item.id and corpus:weight(item.id))
          or cfg.unknown_word_freq
    end,
    user = function(item) return user:score(item.word, cfg.user_saturation) end,
    tiebreak = function(item) return item.id or (corpus.n + 1) end,
  }
  local ranked = rank.rank(items, search, cfg, ctx)

  -- Two dictionary entries can commit the same text -- "tmrw" and "tomorrow"
  -- both show "tomorrow" -- and a list that offers the same word twice wastes
  -- a slot and makes the user read it twice to see they are the same.
  local out, already = {}, {}
  for i = 1, #ranked do
    if #out >= limit then break end
    local item = ranked[i]
    local entry = {
      text = self:surface(item.word, style) .. (suffix or ""),
      source = item.source,
      score = item.score,
      cost = item.cost,
    }
    if not already[entry.text] then
      already[entry.text] = true
      out[#out + 1] = entry
    end
  end

  -- An abbreviation the user wrote down beats anything inferred, and goes to
  -- the very top.  It is the one place in the whole matcher where there is no
  -- guessing to do: they said what they meant.
  local expansions = not (opts and opts.literal_first) and self.shortcuts:get(query)
  if expansions then
    for i = #expansions, 1, -1 do
      local text = apply_case(expansions[i], style)
      -- Drop the same word further down rather than offering it twice.
      for j = #out, 1, -1 do
        if out[j].text == text then table.remove(out, j) end
      end
      table.insert(out, 1, {
        text = text,
        source = "shortcut",
        score = cfg.base_exact + 100,
        cost = 0,
      })
    end
    while #out > limit do table.remove(out) end
  end

  -- The literal candidate stays exactly literal: "commit what I typed" must
  -- not quietly capitalise "kubectl".
  local trusted = expansions ~= nil and expansions ~= false
  trusted = trusted or (not (opts and opts.literal_first)
      and self:trustworthy(ranked[1], query, has_exact, typed_style))
  -- The split goes last among the real answers, and the literal is placed
  -- after that as usual.
  --
  -- Ranking it against the others was wrong twice over.  Scored high it
  -- displaced real corrections; scored low, or suppressed whenever anything
  -- else fitted at all, it vanished exactly when it was wanted -- "thisday"
  -- offered Thursday and Tuesday and no way at all to say "this day".  There
  -- is no score that means "worth having, never worth preferring".  A fixed
  -- place does.
  --
  -- Last, rather than above the literal, because the literal has to stay where
  -- it is: it leads when nothing else is trustworthy, and putting the split
  -- above it there would hand first place to "spell less" over "spellless".
  local found = find_split(self, search)
  if found and #out < limit then
    out[#out + 1] = {
      text = self:surface(found.text, style) .. (suffix or ""),
      source = found.source,
      score = found.score,
      cost = found.cost,
    }
  end

  self:insert_raw(out, raw, limit, trusted)
  stats.candidates = #out
  return out, stats
end

--- Is the best candidate good enough to sit under the space bar?
---
--- Cheap repair onto a reasonably common word is believed.  Beyond that there
--- are two cases where a *perfect* prefix completion is still not evidence of
--- anything, and both are everyday input for anyone writing technical prose:
---
---   * one or two characters -- "x", "f", "cm", "ms", "CW" are variables,
---     units and acronyms far more often than they are the start of a longer
---     word, and completing them buries the thing that was actually typed;
---   * capitals -- typing "PDE" or "TQFT" in upper case is deliberate, and no
---     dictionary word is a better guess than what the user just spelled out.
---
--- An exact dictionary hit overrides both: "i", "eg", "is", "an" mean
--- themselves.
function Engine:trustworthy(best, query, has_exact, typed_style)
  if not best then return false end
  if best.cost > self.cfg.confidence_cost then return false end
  if best.score < self.cfg.confidence_floor then return false end
  if has_exact then return true end
  -- Capitals first: an all-capitals input is deliberate whatever its length,
  -- and checking it after the short-input rule below let "QF" become "QFT".
  if typed_style == "upper" then return false end
  if #query < self.cfg.trust_min_len then
    -- One or two characters is not much to go on, but a candidate that needed
    -- no repair and adds a single letter is still evidence: "th" -> "the" is
    -- worth trusting where "cm" -> "come" and "x" -> "xxx" are not.
    return best.cost == 0 and best.extra <= 1
  end
  return true
end

--- Make sure the literal input is always reachable.
--- It goes into a fixed slot so the keystroke that commits it is predictable,
--- except when nothing we found is trustworthy, in which case it leads.
function Engine:insert_raw(out, raw, limit, trusted)
  local slot = self.cfg.raw_candidate_index
  if slot == nil or slot < 1 then slot = 7 end
  if not trusted then slot = 1 end

  -- The literal may already be here as an ordinary candidate -- a learned word
  -- spelled exactly the same, say.  Move it rather than leaving it wherever
  -- ranking put it: returning early because it existed *somewhere* let a
  -- learned "get" outrank a literal-first "git", and buried literals as far
  -- down as rank 10.
  local existing
  for i = 1, #out do
    if out[i].text == raw then existing = i break end
  end
  if existing then
    if existing <= slot then return end
    local item = table.remove(out, existing)
    item.raw = true
    table.insert(out, math.min(slot, #out + 1), item)
    return
  end

  if slot > #out + 1 then slot = #out + 1 end
  table.insert(out, slot, { text = raw, source = "raw", score = 0, cost = 0, raw = true })
  while #out > limit do table.remove(out) end
end

-- ---------------------------------------------------------------------------
-- learning
-- ---------------------------------------------------------------------------

--- Is the way `text` is capitalised worth remembering as a preference?
---
--- A leading capital on a word the dictionary already knows is not one.  It is
--- overwhelmingly a sentence position -- ours, in fact, since automatic
--- capitalisation put it there -- and storing it made "The" come back in the
--- middle of every later sentence.  Anything else is real evidence:
--- "Grothendieck" (unknown to the dictionary), "TQFT", "MacLane".
function Engine:worth_remembering(text, word)
  if text == word then return false end
  if text == word:sub(1, 1):upper() .. word:sub(2) then
    return not self:dictionary_explains(word)
  end
  return true
end

--- Can the shipped data already account for this word, capital and all?
--- A possessive is answered by its stem, because that is how it is produced:
--- without this, "Theorem's" at the start of a sentence was stored as a
--- preference and came back capitalised in the middle of every later one.
function Engine:dictionary_explains(word)
  if self.corpus:lookup(word) then return true end
  local stem = word:match("^(.+)'s$")
  return stem ~= nil and self.corpus:lookup(stem) ~= nil
end

--- Record that the user committed `text`.  Unknown words are remembered too,
--- so typing a new term once makes it a candidate afterwards, and a spelling
--- worth keeping is kept so "Grothendieck" comes back capitalised.
--- Undo what `learn` recorded for `text`.
---
--- Takes the same shapes `learn` accepts, so the caller can hand it a
--- candidate or a commit without knowing which.  Flushes immediately: the
--- point of forgetting is that it has actually happened.
function Engine:forget(text)
  if not text then return false end
  text = text:match("^%s*(.-)%s*$")
  if text == "" then return false end
  local gone = self.user:forget_word(text:lower())
  if gone then
    self.user:flush()
    self.last_flush = self.now_ms()
  end
  return gone
end

function Engine:learn(text)
  if not self.cfg.learn or not text then return end
  -- Trim first: the automatic leading space is ours, and without this every
  -- commit after the first word of a sentence would fail the check below.
  text = text:match("^%s*(.-)%s*$")
  if not text:find("^%a[%a']*$") then return end
  local word = text:lower()
  local surface
  if self:worth_remembering(text, word) then
    surface = text
  elseif text == word then
    -- Committing the plain lowercase form is how you take back a spelling the
    -- store got wrong, so "how you write it" stays honest.
    surface = false
  end

  local cfg, now = self.cfg, self.now_ms()
  local dirty = self.user:record(word, surface)
  if dirty >= cfg.flush_every or (now - self.last_flush) >= cfg.flush_interval_ms then
    self.user:flush()
    self.last_flush = now
  end
end

function Engine:flush()
  self.last_flush = self.now_ms()
  return self.user:flush()
end

return Engine
