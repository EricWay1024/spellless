-- The Spellless matching engine.
--
-- Pure Lua: it knows nothing about Rime, which is what lets tests/ and bench/
-- exercise exactly the code the IME runs.  `spellless.lua` is the thin adapter
-- that wires this to librime-lua.

local Corpus = require("spellless.corpus")
local UserDB = require("spellless.userdb")
local cue = require("spellless.cue")
local affix = require("spellless.affix")
local version = require("spellless.version")
local Shortcuts = require("spellless.shortcuts")
local Snippets = require("spellless.snippets")
local split = require("spellless.split")
local config = require("spellless.config")
local generate = require("spellless.generate")
local rank = require("spellless.rank")
local skeleton = require("spellless.skeleton")
local distance = require("spellless.distance")
local wordclass = require("spellless.wordclass")
local util = require("spellless.util")
local Variants = require("spellless.variants")

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

  -- Abbreviations the user defined.  Read once: it is a handful of lines that
  -- someone edits deliberately, and a redeploy picks up changes.
  self.shortcuts = Shortcuts.load(
      opts.shortcuts_path
      or (opts.user_dir and util.join(opts.user_dir, cfg.shortcuts_file)))
  -- Read once for the same reason: a handful of lines someone edits or
  -- generates deliberately, and a redeploy picks the changes up.
  self.snippets = Snippets.load(
      opts.snippets_path
      or (opts.user_dir and util.join(opts.user_dir, cfg.snippets_file)))
  return self
end

-- Nothing in the personal store is repaired on load, and the reason is worth
-- writing down, because two different repairs have looked obviously right and
-- both were wrong.
--
-- The first lowercased a stored spelling that differed only by a leading
-- capital on a word the dictionary knows -- "the -> The" -- on the argument
-- that automatic capitalisation is the only thing that puts one there, so
-- removing it destroys nothing anybody meant.  That argument held until
-- scripts/import_pack.py existed.  An imported pack writes exactly that shape
-- on purpose: `dijkstra -> Dijkstra` is a word the dictionary has, spelled
-- lower case, and the whole point of importing is to respell it.  The repair
-- silently ate every such entry, which is a far worse failure than a stale
-- row -- and by then it was cleaning nothing, because `learn` had already
-- refused to create the rows for long enough that a real store of 1,689 words
-- had none left.
--
-- The second would have lowercased ALL CAPS spellings too, and never shipped:
-- simulated against a real store it took `pc -> PC` and `vs -> VS` out along
-- with the accidents.  Nothing capitalises a whole word automatically, so one
-- in the store was typed that way, by a person, on purpose.
--
-- The corrections were never repaired at all, for the reason that now applies
-- to all three.  A correction is keyed by the lowercased input, so on disk
-- "> windows Windows 2" and "> but But 6" are the same shape: one is somebody
-- who typed a capital W and took the candidate by its number, the other is our
-- own sentence capital from before `learn_choice` guarded against it, and
-- nothing in the file tells them apart.  A fold that lowercases both destroys
-- `learned_capital`, permanently, on the next engine the process builds.
--
-- So the guards live where the information still exists -- at record time, in
-- `learn_choice` and `worth_remembering` -- and a row that is wrong is removed
-- the way any other unwanted row is: Ctrl+Shift+D on the candidate.

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

--- A spelling that opens in lower case and carries a capital later is
--- deliberate, and a sentence position does not get to overrule it: `iPhone`,
--- `eBay`, `macOS`, `arXiv`, `iOS`, `openSUSE`, `iCloud`.  Written out, the
--- rule is that the *shape* of the spelling is the statement -- nobody types a
--- capital in the middle of a word by accident, and nothing in this program
--- puts one there.
---
--- No marker needed, because the spelling already says it.  `don't` and `e.g.`
--- carry no capital and take one at the start of a sentence as they should,
--- and `LaTeX` is unaffected either way.
local function starts_lower_then_capital(word)
  return word:find("%u") ~= nil and word:sub(1, 1):match("%l") ~= nil
end

local function apply_case(word, style)
  if style == "upper" then return word:upper() end
  if style == "title" then
    if starts_lower_then_capital(word) then return word end
    return word:sub(1, 1):upper() .. word:sub(2)
  end
  return word
end
Engine.apply_case = apply_case

--- The variant groups for the mode in force, or nil when no mode is on.
---
--- `opts.variant_mode` is the F4 switch; `cfg.spelling_variant` is the setting
--- it starts from.  Off is the default, and off costs one table lookup.
function Engine:variants(opts)
  local mode = opts and opts.variant_mode
  if mode == nil then mode = self.cfg.spelling_variant end
  if not mode or mode == "off" then return nil end
  return Variants.load(self.corpus.dir, mode)
end

--- Is `raw` a spelling this mode refuses to offer?
---
--- The one case where hiding can corrupt a document rather than tidy it.
--- `color` is a CSS property, `center` a LaTeX environment, `analyze` and
--- `catalog` are function names, and a British writer types them deliberately
--- inside code.  With the switch on the leader is `colour`, and the space bar
--- -- which is doing double duty as "pick this" and "separate the words" --
--- would commit it without the writer noticing.  ALGORITHM.md §1.1 calls
--- silently converting a deliberate token the one failure that corrupts a
--- document unseen, and slot 7 does not help: what failed is the space bar,
--- not reachability.
---
--- So the adapter asks once, exactly as it does for a word the dictionary has
--- never seen.  Return still commits immediately.
function Engine:variant_refuses(raw, opts)
  local v = self:variants(opts)
  if not v or not raw or raw == "" then return false end
  return v:hidden(raw:lower())
end

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
    -- A possessive inherits its stem's spelling, so "Milnor" makes "Milnor's"
    -- and "Milnors" makes "Milnors'".
    local stem, mark = word:match("^(.+)('s)$")
    if not stem then stem, mark = word:match("^(.+)(')$") end
    if stem then
      local base = self.user:surface(stem) or self.corpus.forms[stem]
      if base then form = base .. mark end
    end
  end
  return apply_case(form or word, style)
end

--- A capitalisation you have chosen for this word, twice, deliberately.
---
--- `worth_remembering` will not store "Windows" as the spelling of "windows",
--- and it is right not to: the dictionary explains the lowercase word, so the
--- capital is usually the start of a sentence and storing it would put a
--- capital in the middle of every later one.
---
--- But a correction you made twice is not a sentence position.  It is only
--- recorded when you typed the capital yourself and took the candidate by its
--- number, twice -- and at that point it says something the dictionary does
--- not know, which is that this word has a proper-noun reading you use.
---
--- Keyed on the *word*, so it follows the word rather than the keystrokes:
--- teaching it by typing "windows" also reaches it from "wndows".
function Engine:learned_capital(word)
  local choices = self.user:choices_for(word)
  if not choices then return nil end
  for i = 1, #choices do
    local c = choices[i]
    if c.count >= self.cfg.choice_confirm_count
       and c.text ~= word and c.text:lower() == word then
      return c.text
    end
  end
  return nil
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

--- Which possessive ending a word can actually take.
---
--- The apostrophe you typed says which you meant, and that was treated as the
--- end of the matter: whatever you typed was stuck onto every candidate.  But
--- it says something about the *stem you typed*, and the stem matches words of
--- both numbers -- so "mther's" offered `mothers's` at slot 2, "it's" offered
--- `its's` and `items's`, and "mthers'" offered `mother'`.  None of those is
--- ever the right spelling of anything.
---
--- A plural already ending in `s` takes a bare apostrophe and a singular takes
--- `'s`, so the ending is a property of the candidate and not of the input.
--- Recognising the plural is the trick `past_inflection` uses: `s` on the end
--- and the rest is a word -- two lookups, because "bosses" loses `es` where
--- "mothers" loses `s`.
---
--- It is not perfect and cannot be.  A singular ending in `s` whose stem is
--- also a word reads as plural: `physics'` rather than `physics's`, `its'`
--- rather than `its's`.  Both are wrong, one is less wrong, and the surname
--- plurals -- "the Williams's" -- are the case where the raw form was right;
--- they survive because `willia` and `willi` are not words.
local function possessive_of(self, word, typed)
  if typed ~= "'s" and typed ~= "'" then return typed or "" end
  local plural = word:sub(-1) == "s"
      and (self.corpus:lookup(word:sub(1, -2)) ~= nil
           or self.corpus:lookup(word:sub(1, -3)) ~= nil)
  return plural and "'" or "'s"
end

--- How a candidate should be capitalised.
--- An explicit capital in the input always wins: if you typed "mathe" at the
--- start of a sentence you meant a capital, but if you typed "MATHE" you meant
--- something else and we must not quietly undo it.
local function effective_style(style, sentence_start, forced)
  -- A style asked for outright beats everything.  It is the one case where
  -- the user has said what they want rather than implied it, and the whole
  -- point of asking is to overrule what would otherwise be inferred -- an
  -- automatic sentence capital most of all.
  if forced then return forced end
  if sentence_start and style == "lower" then return "title" end
  return style
end
Engine.effective_style = effective_style

-- ---------------------------------------------------------------------------
-- the user's own vocabulary
-- ---------------------------------------------------------------------------

--- The words you have taught it, searched exactly like the ones that shipped.
---
--- This used to be a second matcher: a linear pass over the most-used 400
--- entries, three alignments each, with its own hand-rolled copies of the
--- exact, prefix, typo, skeleton and cue tests.  It was slower per word than
--- the real one by two orders of magnitude -- 400 personal words cost 4 ms
--- against 3 ms for 83,364 dictionary words -- and the cap was load-bearing
--- because of it.  A cap on a personal store is a promise the software cannot
--- keep: `reidemeister`, learned and spelled correctly and sitting in the
--- file with a count of 3, was unreachable from every shorthand of it, because
--- 400 other words were used more often.
---
--- So there is one matcher.  `Corpus.of_words` gives the personal list the
--- same masks, buckets and range searches the dictionary has, and the same
--- `generate.generate` runs over it -- no cap, and the whole store searched
--- for less than the old 400 cost.
---
--- Ids from that index address the personal list, so each is mapped back to a
--- dictionary id (or nil, for a word the dictionary has never heard of, which
--- is most of why the store exists).
local function generate_personal(self, query, out)
  local index = self:personal_index()
  if index.n == 0 then return end
  local corpus, n = self.corpus, #out
  local found = generate.generate(index, query, self.cfg, nil)
  for i = 1, #found do
    local item = found[i]
    local word = index.words[item.id]
    n = n + 1
    out[n] = { word = word, id = corpus:lookup(word), source = item.source,
               cost = item.cost, extra = item.extra }
  end
end

--- The personal index, rebuilt when the set of words in the store changes.
---
--- Counts change constantly and do not affect it; the word set changes a few
--- times a session.  Rebuilding is a sort and one pass, ~2 ms for a store of a
--- couple of thousand.
function Engine:personal_index()
  local order = self.user.order
  if self.personal and self.personal_words == #order then return self.personal end
  local words, n = {}, 0
  for i = 1, #order do
    -- A hand-edited file can hold anything, and the bucket key assumes a
    -- lowercase first letter.
    if order[i]:find("^%a[%a']*$") then n = n + 1; words[n] = order[i] end
  end
  self.personal = Corpus.of_words(words)
  self.personal_words = #order
  return self.personal
end

-- ---------------------------------------------------------------------------
-- context
-- ---------------------------------------------------------------------------

--- What the word before this one predicts about the class of this one, or nil.
---
--- Gated three ways, and every gate is there to make the term silent rather
--- than wrong:
---
---   * the feature is off unless `context_class` is set;
---   * the previous word must be one the dictionary knows.  A token nobody has
---     measured says nothing about what follows, and a closed-class word -- the
---     only kind this table has an opinion about -- is always in the dictionary,
---     so the gate costs one binary search and rejects noise;
---   * the class table itself is small, so most previous words return nil.
---
--- The caller is responsible for the other half of the gate: `previous_word`
--- must be a word that was cleanly separated from this one by exactly one
--- space.  `preceding.previous_word` is what works that out from the text
--- behind the caret.
function Engine:context_class(previous_word)
  if not self.cfg.context_class then return nil end
  if not previous_word or previous_word == "" then return nil end
  local w = previous_word:lower()
  if not self.corpus:lookup(w) then return nil end
  return wordclass.context_of(w)
end

-- ---------------------------------------------------------------------------
-- the query itself
-- ---------------------------------------------------------------------------

--- Ranked suggestions for `raw` as typed.
---
--- `opts.sentence_start` says the text before this word ended a sentence, so
--- candidates should lead with a capital.  `opts.literal_first` says the text
--- before it means we must not guess at all -- a LaTeX control sequence, say.
--- `opts.previous_word` is the word immediately before this one, when there was
--- one and it was cleanly separated (`preceding.previous_word`); it is read only
--- for its part of speech, and only when `context_class` is on.
--- Working all three out is the adapter's job; everything here stays independent
--- of Rime.
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

--- What is actually running, as candidates.
---
--- Typing the word answers one question -- "am I testing the build I just
--- deployed, or the one Rime loaded twenty minutes ago" -- which from outside
--- the process is otherwise unanswerable, and has more than once cost an
--- afternoon.  The first line comes from a module the installer overwrites, so
--- it reports what this process *loaded*; the rest is read from the live
--- corpus and the live configuration, so it cannot be stale by construction.
function Engine:describe(opts)
  local cfg, corpus = self.cfg, self.corpus
  local built = version.revision or "?"
  if version.installed then built = built .. " installed " .. version.installed
  else built = built .. " (not installed -- running from the working tree)" end

  local forms = 0
  for _ in pairs(corpus.forms) do forms = forms + 1 end

  local slip = cfg.cue_slip_cost > 0 and ("slip " .. cfg.cue_slip_cost) or "slip off"
  local out = {
    "spellless " .. built,
    ("%d words, %d forms, %d shortcuts"):format(corpus.n, forms, self.shortcuts.count),
    ("cue %s/%s, %s, learn %s"):format(cfg.base_cue, cfg.cue_cost_scale, slip,
                                       cfg.learn and "on" or "off"),
  }
  -- The three features that edit text already in the document, and whether
  -- each is switched on.  They ship off and are turned on in a custom YAML, so
  -- "I turned it on and nothing happened" is nearly always "the patch is not
  -- being read" -- which this line settles in one keystroke instead of an
  -- afternoon.  `edit_document` is a different question and the line below
  -- answers that one: it overrules the refusal list, it does not switch
  -- anything on.
  -- As the F4 switches have them, when the caller could say -- which is the
  -- half a configuration file cannot show you, and the reason this line exists:
  -- "I turned it on and nothing happened" is nearly always "that is not what
  -- is on".  `absorb` has three states rather than two, because the switch can
  -- replace it with the ASCII hand-over.
  local now = (opts and opts.features) or cfg
  local absorb = now.absorb_fragment and "on" or "OFF"
  if now.ascii_fragment then absorb = "plain typing" end
  local spelling = (opts and opts.variant_mode) or cfg.spelling_variant or "off"
  out[#out + 1] = ("reclaim %s, absorb %s, word-backspace %s, spelling %s"):format(
      now.reclaim_space and "on" or "OFF", absorb,
      now.word_backspace and "on" or "OFF", spelling)
  -- What the matcher can actually see about the application it is typing into,
  -- which is not always what the configuration implies -- and when the two
  -- disagree, this line is the one that is true.
  if opts and opts.may_edit ~= nil then
    local app = opts.client_app
    if app == nil or app == "" then app = "(frontend reports none)" end
    out[#out + 1] = ("app %s, document %s, edits %s"):format(
        app, opts.readable and "readable" or "unreadable",
        opts.may_edit and "allowed" or "refused")
  end
  return out
end

--- The query read as an affix plus a word, when it is not a word itself.
---
--- Every reading is tried and the best-scoring one wins, rather than the first
--- that finds anything.  Taking the first was wrong in a way worth recording:
--- "mtrxws" is `meta` + `rxws` before it is `mtrx` + `wise`, and `rxws` does
--- find "rows", so it offered "metarows" and never looked further.  What
--- decides is how well the stem matched, which is the only evidence there is.
---
--- The stem is matched by the whole matcher, recursively -- a coined word is
--- only useful if you can misspell it too, and "resmplng" reaches "sampling"
--- through the syllable channel, not through an exact lookup.  One level only:
--- "unresampling" is not worth the second search.
function Engine:find_affix(query, style)
  local cfg = self.cfg
  if not cfg.affix_words or self.peeling then return nil end
  -- A word the dictionary knows is a word, not a coinage.  This is what keeps
  -- "reading", "region", "coder" and "nonsense" out of it entirely, and it is
  -- doing far more work than the affix lists are.
  if self.corpus:lookup(query) then return nil end
  if #query < cfg.min_affix_len then return nil end

  self.peeling = true
  local found, tried = nil, 0
  for _, part in ipairs(affix.peel(query, cfg.min_affix_stem)) do
    if tried < cfg.max_affix_tries then
      tried = tried + 1
      local inner = self:suggest(part.stem, 3, { literal_first = false })
      local best = inner[1]
      if best and not best.raw then
        local stem = best.text:gsub("%s+$", "")
        -- Only a plain word.  A split ("re" + "sam pling") or a phrase is not
        -- something to glue an affix onto.
        if stem:find("^%a[%a']*$") and (not found or best.score > found.score) then
          found = { text = affix.join(part, stem:lower()), score = best.score,
                    cost = best.cost }
        end
      end
    end
  end
  self.peeling = nil
  if not found then return nil end
  found.text = apply_case(found.text, style)
  return found
end

function Engine:suggest(raw, limit, opts)
  local cfg = self.cfg
  local stats = {}
  if raw == "" then return {}, stats end
  -- Before anything else, and never as a guess: an exact match on the whole
  -- input or nothing.  The word is not English and is not in the dictionary,
  -- so nothing else can reach this branch by accident.
  if cfg.version_query ~= "" and raw:lower() == cfg.version_query then
    local out = {}
    for i, line in ipairs(self:describe(opts)) do
      out[i] = { text = line, source = "version", score = 0, cost = 0 }
    end
    out[#out + 1] = { text = raw, source = "raw", score = 0, cost = 0, raw = true }
    stats.candidates = #out
    return out, stats
  end
  local style = effective_style(case_style(raw), opts and opts.sentence_start,
                                opts and opts.force_style)
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
      --
      -- The written form has to be consulted, not just the key.  Half the
      -- contractions are keyed without their apostrophe -- "dont", "itd",
      -- "thats" -- precisely so they can be typed without one, and testing the
      -- key alone let every one of them straight through: "it's" offered
      -- "it'd's" and "it'll's" on the first page.
      local kept = {}
      for i = 1, #items do
        local word = items[i].word
        local form = self.user:surface(word) or self.corpus.forms[word]
        if not (word:find("'") or (form and form:find("'"))) then
          kept[#kept + 1] = items[i]
        end
      end
      items = kept
    end
    -- There is no `else` here, and there is no second way to build a
    -- possessive.  One used to sit here, generating "<stem>'s" as a word of
    -- its own for a query the stem split had not taken -- and it could never
    -- run: the guard above requires the query to match ^[a-z][a-z']*$, so a
    -- query ending in "'s" always leaves a stem matching it too, and `stem` is
    -- never nil when it matters.  Everything productive is the split.
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
    previous_class = self:context_class(opts and opts.previous_word),
    -- After a modal, prefer the bare form -- unless the typist typed the `d`.
    --
    -- That escape is what makes the rule safe rather than merely cheap.  A
    -- consonant skeleton keeps the `d` of an -ed ending, so somebody who means
    -- "would have called" writes `clld` and not `cll`; over 427,000 words of
    -- real prose, all twelve genuine -ed forms following a modal had a
    -- shorthand ending in `d`, so all twelve would have been left alone.  The
    -- rule can therefore only act where the input itself is silent about it.
    prefer_bare = (opts and opts.prefer_bare) == true
        and search:sub(-1) ~= "d",
    -- An -ed *inflection*, not a word that merely ends in those letters:
    -- `called` yes, `need` and `proceed` and `indeed` no.  Two lookups, and
    -- without them the rule demotes "will need", which is most of what follows
    -- a modal that ends in `ed` at all.
    past_inflection = function(item)
      local w = item.word
      if not w or w:sub(-2) ~= "ed" then return false end
      return corpus:lookup(w:sub(1, -2)) ~= nil
          or corpus:lookup(w:sub(1, -3)) ~= nil
    end,
  }
  -- Words you have said you never write, taken out before anything is ranked
  -- so that `leader` -- which decides whether the list is trustworthy at all
  -- -- is the leader of what you will actually be shown.
  --
  -- The literal is placed later and is untouched: "commit what I typed" holds
  -- for a suppressed word exactly as it does for `kubectl`, so nothing here
  -- can make a string untypeable.  Committing it again lifts the suppression,
  -- which is the same undo `learn` already has for a spelling.
  --
  -- A spelling variant you do not write is the same thing said in bulk: with
  -- `gb-ise` on, `color` is not a word you are choosing between, so it leaves
  -- here rather than being demoted.  Where the surviving spelling is too far
  -- from the input to be generated on its own -- `plough` to `plow` is 2.70
  -- against a typo budget of 1.35 -- it is substituted in place instead, so
  -- hiding never leaves the query with nothing.
  local hidden = self:variants(opts)
  if self.user:has_suppressions() or hidden then
    local present
    if hidden then
      present = {}
      for i = 1, #items do present[items[i].word] = true end
    end
    local kept = {}
    for i = 1, #items do
      local item = items[i]
      local drop = self.user:is_suppressed(item.word)
      if not drop and hidden and hidden:hidden(item.word) then
        local instead = hidden:survivor(item.word)
        if not instead or present[instead] then
          -- The surviving spelling is already here on its own evidence, so
          -- this one just goes.
          drop = true
        else
          -- Keep the evidence, change the answer.  The rewrite waits until
          -- after ranking, because the score belongs to the spelling that was
          -- actually matched: re-scoring `realize` against `rls` throws away
          -- the skeleton hit `realise` earned and drops it ten places.
          item.variant_to = instead
        end
      end
      if not drop then kept[#kept + 1] = item end
    end
    items = kept
  end
  local ranked = rank.rank(items, search, cfg, ctx)

  -- The spelling that was matched has been ranked; now say the one this mode
  -- writes.  Group members were levelled to one frequency at build time, so
  -- swapping the id here cannot move anything.  Guarded, because with no mode
  -- on there is nothing to rewrite and this would be a scan of every candidate
  -- on every keystroke for nothing.
  if hidden then
    for i = 1, #ranked do
      local instead = ranked[i].variant_to
      if instead then
        local id = corpus:lookup(instead)
        if id then ranked[i].word, ranked[i].id = instead, id end
      end
    end
  end

  -- Two dictionary entries can commit the same text -- "tmrw" and "tomorrow"
  -- both show "tomorrow" -- and a list that offers the same word twice wastes
  -- a slot and makes the user read it twice to see they are the same.
  local out, already = {}, {}
  for i = 1, #ranked do
    if #out >= limit then break end
    local item = ranked[i]
    local entry = {
      -- The whole possessive, not the stem with an ending stuck on it.  You
      -- write "McDonald's" far more often than you write "McDonald", so that
      -- is the spelling the store has; asking for the stem alone found
      -- nothing and gave back "mcdonald's".  `surface` falls back to the
      -- stem's own spelling when the possessive has none of its own.
      text = self:surface(item.word .. possessive_of(self, item.word, suffix), style),
      source = item.source,
      score = item.score,
      cost = item.cost,
    }
    -- Both capitalisations, and the input decides which leads.  "Windows" must
    -- be reachable from "wndows" and not only from typing it out; and
    -- "windows" must stay reachable, or you could never open one again.  One
    -- keystroke apart either way, so neither can displace the other.
    --
    -- Three ways a word ends up with two spellings, and none of them may lose
    -- one.  A spelling you taught or imported *replaces* the dictionary's, and
    -- for a while that was accepted as the price of a personal store -- which
    -- is why the pack could not carry `Bloom` without costing you the flower.
    -- It is not a price, it is a missing candidate.
    --
    -- The dictionary has already said which keys have a lowercase reading
    -- worth protecting, and it said it by whether it gives the key a form:
    -- `latex`, `ok`, `pc`, `dijkstra`, `bloom` are read as lowercase words and
    -- keep that reading, while `tqft` and `macos` were issued a spelling and
    -- have no second reading to lose.  So the test is `corpus.forms`, not a
    -- guess about English -- and unlike corpus rank, which cannot separate
    -- `bloom` (8,858th) from `shannon` (8,139th), it is a decision somebody
    -- actually made.
    local capital, capital_leads
    local taught = self.user:surface(item.word)
    if taught and taught ~= item.word
       and self.corpus:lookup(item.word) and not self.corpus.forms[item.word] then
      -- `entry` already carries your spelling, via `surface`.  What goes
      -- beside it is the reading the dictionary would have given.
      capital = item.word
    else
      -- The other direction: `entry` is the plain word and the capital goes
      -- behind it -- one you chose twice yourself, or one the dictionary ships
      -- beside a word that also means something in lower case.
      capital = self:learned_capital(item.word) or self.corpus.capitals[item.word]
      capital_leads = capital ~= nil and capital == raw
    end
    local capital_text = capital
        and (apply_case(capital, style) .. (suffix or ""))
    -- Typing the capital out is the clearest statement of intent there is, and
    -- `apply_case` cannot act on it: "LaTeX" is neither title case nor upper
    -- case, so the plain reading comes back "latex".  Decided here rather than
    -- by reordering afterwards, because `limit` may cut the list between the
    -- two and the one that survives should be the one that was asked for.
    local first, second = entry, nil
    if capital_text then
      second = { text = capital_text, source = "capital",
                 score = item.score - 0.5, cost = item.cost }
      if capital_leads then
        first, second = second, entry
        first.score, second.score = item.score, item.score - 0.5
      end
    end
    for _, candidate in ipairs(second and { first, second } or { first }) do
      if not already[candidate.text] and #out < limit then
        already[candidate.text] = true
        out[#out + 1] = candidate
      end
    end
  end

  -- A correction you have made before, and made *again*.
  --
  -- One selection is not evidence: half of what anyone picks is picked once by
  -- accident, and a store that led on a single choice would fill with them.
  -- The second selection is different in kind -- it says the first was not a
  -- slip -- and it is the only signal here that comes from the person rather
  -- than from a measurement of English.  So it is placed rather than scored:
  -- confirmed means first, and no amount of frequency argues with it.
  --
  -- Except against the input itself.  Type a word you also use as a shorthand
  -- for another -- "were" for `we're`, "its" for `it's`, "windows" for
  -- `window` -- and both readings end up confirmed, at which point the tally
  -- is a race between two things you meant on different days: `its` leads
  -- `it's` 8 to 7 here and one keystroke turns that over, after which every
  -- "its" you type comes out apostrophised.  A count that close is not
  -- evidence about English, and the two readings are not equally reachable:
  -- `it's` is one apostrophe away and `its` typed as `its` has no other
  -- spelling to ask for.  So when you have confirmed both, the reading that is
  -- what you actually typed leads and the other follows it.
  --
  -- Only when both are confirmed.  Where you have said one thing and one thing
  -- only -- "dont" for `don't`, "diff" for `different` -- nothing competes and
  -- the correction still leads, which is what the store is for.
  local promoted = nil
  local choices = not (opts and opts.literal_first) and self.user:choices_for(query)
  if choices then
    local confirmed, own = 0, nil
    for i = 1, #choices do
      -- Sorted by descending count, so the confirmed ones are exactly the
      -- first `confirmed` entries and `own` is somewhere among them.
      if choices[i].count >= cfg.choice_confirm_count then
        confirmed = confirmed + 1
        if not own and choices[i].text:lower() == query then own = i end
      end
    end
    if confirmed > 1 and own then
      table.insert(choices, 1, table.remove(choices, own))
    end
    for i = #choices, 1, -1 do
      local choice = choices[i]
      if choice.count >= cfg.choice_confirm_count then
        -- Through surface(), so the capital follows the input you just typed
        -- rather than the one you happened to type the day it was learned.
        --
        -- No `suffix` here, unlike everywhere else in this function: the store
        -- is keyed by the whole input, apostrophe and all, so what came back
        -- for "mther's" is already "mother's" and adding the ending again
        -- would place "mother's's" at rank 1.
        local text = self:surface(choice.text, style)
        for j = #out, 1, -1 do
          if out[j].text == text then table.remove(out, j) end
        end
        table.insert(out, 1, { text = text, source = "chosen",
                               score = cfg.base_exact + choice.count, cost = 0 })
        promoted = text
      end
    end
    while #out > limit do table.remove(out) end
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
  trusted = trusted or promoted ~= nil
  trusted = trusted or (not (opts and opts.literal_first)
      and self:trustworthy(ranked.leader or ranked[1], query, has_exact,
                           typed_style, opts and opts.after_digit))
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
  -- A coinage sits with the split, among the readings that are worth having
  -- and never worth preferring: both are things the dictionary cannot contain,
  -- and both would be wrong to put in front of a word it does.
  -- Only when nothing ordinary was worth putting under the space bar.
  --
  -- Peeling costs a whole extra search per reading tried, which is far too
  -- much to spend on every keystroke -- it put the 95th percentile over the
  -- 10 ms this project holds itself to.  But a coinage is by definition a word
  -- the dictionary does not have, so the case where it is wanted is exactly
  -- the case where the ordinary channels came back with nothing trustworthy,
  -- and `trusted` has already been worked out a few lines above.  Typing an
  -- ordinary word now pays nothing at all for this.
  local coined = not trusted and not (opts and opts.literal_first)
      and self:find_affix(search, style)
  if coined then
    local text = coined.text .. (suffix or "")
    local seen = false
    for j = 1, #out do if out[j].text == text then seen = true break end end
    if not seen then
      -- Placed rather than appended, and it displaces the last entry when the
      -- list is already full.  A coinage is the only reading of a coinage; the
      -- twentieth guess at what else the letters might have been is not worth
      -- the slot, and leaving this to "if there is room" made it appear or not
      -- according to how many rivals a query happened to attract.
      local slot = #out + 1
      if slot > limit then slot = limit end
      table.insert(out, slot, { text = text, source = "coined",
                                score = coined.score, cost = coined.cost })
      while #out > limit do table.remove(out) end
    end
  end

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
function Engine:trustworthy(best, query, has_exact, typed_style, after_digit)
  if not best then return false end
  if best.cost > self.cfg.confidence_cost then return false end
  if best.score < self.cfg.confidence_floor then return false end
  if has_exact then return true end
  -- Capitals first: an all-capitals input is deliberate whatever its length,
  -- and checking it after the short-input rule below let "QF" become "QFT".
  if typed_style == "upper" then return false end
  if #query < self.cfg.trust_min_len then
    -- A letter or two hard against a digit is notation, not a word: 4D, 3D,
    -- 4th, 5km, L2, H1.  The digit went straight into the document, so all
    -- the matcher sees is "D" -- which adds one letter to reach "Do" and is
    -- therefore trusted, putting "Do" in front of the D that was typed.
    --
    -- Nothing else in the language makes a letter follow a digit with no
    -- space, so the test is the space and not a list of suffixes; `4days` is
    -- taken literally too, and a missing space is what that was.
    if after_digit then return false end
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
--- Neither shape of capital counts, when the dictionary already knows the word.
---
--- A *leading* capital is overwhelmingly a sentence position -- ours, in fact,
--- since automatic capitalisation put it there -- and storing it made "The"
--- come back in the middle of every later sentence.
---
--- *All* capitals are the same mistake wearing a different hat, and cost the
--- same afternoon to find: write MATHEMATICS once, in a heading or for
--- emphasis, and `mathe` offered MATHEMATICS and nothing else from then on.
--- The ordinary word was not merely demoted, it was gone -- the two spellings
--- deduplicate to one candidate and the stored one wins.  Shouting a word once
--- is not a statement about how it is spelled.
---
--- Anything else is real evidence: "Grothendieck" (unknown to the dictionary),
--- "TQFT" and "MacLane" (not explained by it either), "MacOS" (mixed, so
--- neither branch below).
---
--- What remains for the deliberate case is the route that asks for evidence
--- rather than inferring it: pick the capitalised candidate by its number
--- twice and `learned_capital` offers it thereafter, `choices_for` promotes it
--- once confirmed, and both spellings stay reachable throughout.
function Engine:worth_remembering(text, word)
  if text == word then return false end
  if text == word:sub(1, 1):upper() .. word:sub(2)
     or text == word:upper() then
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
  local word = text:lower()
  local gone = self.user:forget_word(word)
  -- And every correction that produced it.  Forgetting the word but keeping
  -- "this is what you meant by cli" would leave it leading the list for ever,
  -- which is exactly what the key is for undoing.
  for typed in pairs(self.user.choices) do
    if self.user:forget_choice(typed, text) then gone = true end
  end
  -- Nothing personal to forget, and the word is the dictionary's own: then
  -- the key means the other thing it could mean.  `hae` is Scots for `have`
  -- and is in the dictionary because English corpora contain it; it is not in
  -- yours, and typing "hae" will otherwise put it in front of `have` for ever,
  -- because you typed it exactly and that is the strongest evidence there is.
  --
  -- Not something the ranking can fix.  `aback`, `abut`, `agog` and a couple
  -- of thousand others sit in exactly the same place -- a rare word with a
  -- much commoner near neighbour -- and every one of them must keep winning
  -- when it is typed.  Which of the two a given word is depends on who is
  -- typing, so it is answered by the person typing, one keystroke at a time.
  if not gone and self.corpus:lookup(word) then
    gone = self.user:suppress(word)
  end
  if gone then
    self.user:flush()
    self.last_flush = self.now_ms()
  end
  return gone
end

--- Record that `text` is what `typed` meant.
---
--- Only ever called when a candidate was actually selected.  Committing the
--- raw input with Return is not a choice between readings -- it is a refusal to
--- choose -- and counting it would fill the store with the misspellings this
--- exists to correct.
function Engine:learn_choice(typed, text)
  if not self.cfg.learn or not typed or not text then return end
  typed = typed:match("^%s*(.-)%s*$")
  text = text:match("^%s*(.-)%s*$")
  if typed == "" or text == "" then return end
  -- The version query is a diagnostic, not a word, and its answer is a
  -- sentence about the running process.  Taking one of those lines by its
  -- number is how you read it, so without this the store fills up with
  -- "> zzver app code.exe, document readable, edits allowed".
  if self.cfg.version_query ~= "" and typed:lower() == self.cfg.version_query then
    return
  end

  -- A capital you did not type is ours, not yours.
  --
  -- Sentence-initial capitalisation is applied by this software, so recording
  -- the result as "what you chose" learns our own output and then insists on
  -- it: six commits of "But" at the start of a sentence and "but" leads with a
  -- capital in the middle of every later one.  The word store has guarded
  -- against this since the day it was written -- see worth_remembering -- and
  -- the lesson did not get carried across when this store was added.
  --
  -- Only a plain Title Case word is stripped, so "CLI" and "TQFT" keep their
  -- capitals: those are how the word is written, not where it sat in a
  -- sentence.  Nothing is lost by stripping, because the text is rendered back
  -- through Engine:surface, which knows the spellings and the forms.
  if typed == typed:lower() then
    local lower = text:lower()
    if text == lower:sub(1, 1):upper() .. lower:sub(2) then text = lower end
  end
  typed = typed:lower()
  if not typed:find("^[a-z][a-z']*$") then return end
  local n = self.user:record_choice(typed, text)
  if n >= self.cfg.flush_every then self:flush() end
  return n
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

  -- Committing it is the plainest possible statement that you do write it,
  -- and the undo for a key pressed on the wrong candidate.
  self.user:release(word)

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
