-- Every tunable number in one place.
--
-- The defaults were chosen by coordinate descent (bench/tune.lua) over
-- tests/cases/*.tsv, not by intuition; bench/evaluate.lua reports what any
-- change to them does.  See EVALUATION.md.
--
-- A Rime schema can override any of them under its `spellless:` key; see
-- spellless.lua, and tests/test_adapter.lua for the check that the shipped
-- schema and this file have not drifted apart.

local M = {}

M.defaults = {
  ---------------------------------------------------------------- generation
  -- How many candidates each source is allowed to contribute.
  max_prefix        = 12,
  max_skeleton      = 16,
  -- Ceiling on how much of a skeleton completion range to walk.  A two-letter
  -- skeleton has tens of thousands of completions and none of them is worth
  -- much, which is what min_skeleton_completion_len is really about.
  max_skeleton_range = 1500,
  max_typo          = 20,
  max_skeleton_fuzzy = 12,

  -- Edit budgets, in the weighted units of spellless.distance.
  typo_budget       = 1.35,   -- query vs word
  skeleton_budget   = 1.30,   -- query skeleton vs word skeleton
  elastic_budget    = 1.70,   -- query vs a prefix of the word, vowels cheap

  -- Shortest query for which each fuzzy source runs at all.  Below these
  -- lengths almost every dictionary word is "close", so the sources only add
  -- noise and cost.
  min_typo_len      = 2,
  -- Input longer than this is matched against nothing and simply offered back.
  -- The longest word in the corpus is 28 characters, so anything past this is
  -- a pasted line or a runaway identifier -- and both the personal pass and
  -- the elastic alignment cost grow with the square of the input length, so an
  -- unbounded query is a latency hole rather than a useful search.
  max_query_len     = 32,
  min_skeleton_len  = 2,
  min_skeleton_completion_len = 4,
  min_skeleton_fuzzy_len = 5,

  -- Scan shape.  The typo scan visits words whose length is within
  -- `len_window` of the query and whose first letter is the query's first or
  -- second letter (which covers a slip on the very first key), optionally
  -- extended to the first letter's keyboard neighbours.
  len_window        = 2,
  scan_first_neighbours = false,
  -- Hard ceiling on edit-distance evaluations per scan.  Buckets are visited
  -- most-plausible-length first and are frequency ordered inside, so hitting
  -- the ceiling drops the least likely words rather than an arbitrary slice.
  max_checks        = 1200,

  -------------------------------------------------------------------- ranking
  -- Base score per source.  The gaps encode the intended broad priority:
  -- exact > plausible completion > close typo > skeleton reconstruction.
  --
  base_exact        = 100,
  -- An exact match on a key that carries a *written form* is different in kind
  -- from an exact match on an ordinary word.  Someone put "sth -> something"
  -- and "im -> I'm" in a file on purpose; there is nothing to second-guess, and
  -- without this "sth" offered "the" first because "the" had been committed
  -- hundreds of times and familiarity was worth more than the gap.
  --
  -- Deliberately not a blanket lift of base_exact: that was tried, and it made
  -- every rare word unbeatable.  "tat" and "eys" then led over "that" and
  -- "eyes", which is the opposite failure and a worse one, because those are
  -- words you meant to have corrected.
  base_prefix       = 74,
  base_typo         = 75,
  base_skeleton     = 66,

  form_bonus        = 70,   -- exact match on an entry with a written form
  freq_weight       = 34,   -- x normalised corpus log-frequency, in [0,1]
  -- Personal history nudges, it does not decide.  The dictionary is measured
  -- English; the personal store is a handful of counts from whatever happened
  -- to be typed lately, including the mistakes committed while something was
  -- broken.  At 26 it was worth three quarters of the entire frequency range,
  -- so a word committed three times could lead over the word it was a
  -- misspelling of.  18 is the lowest value at which twenty selections still
  -- lift a word onto the first page, which is what learning is for.
  user_weight       = 18,   -- x normalised personal frequency, in [0,1]
  -- What a personal word absent from the dictionary is assumed to be worth.
  -- It has no measured frequency, and "middling" was too generous: it put an
  -- unknown three-letter string ahead of an ordinary English word.  Low enough
  -- to lose a close contest, high enough that a name you have committed still
  -- beats the noise.
  unknown_word_freq = 0.2,
  -- Charged to a candidate the dictionary has never heard of -- something that
  -- exists only because it was committed once.  Being typed exactly is not the
  -- same evidence from a word nobody has measured as it is from a word in the
  -- dictionary, and without this a mistake committed three times ("eys") led
  -- over the word it was a misspelling of ("eyes") for good.  Small enough
  -- that a name you have actually adopted still wins when nothing else fits.
  unknown_word_penalty = 25,
  cost_weight       = 19,   -- x weighted edit distance
  extra_weight      = 12,   -- x how much longer the completion is than the input

  -- A query with few vowels is far more likely to be an abbreviation than a
  -- misspelling, so skeleton candidates get up to this much extra when the
  -- input looks consonantal.
  skeleton_vowel_bonus = 14,

  -- When even the best candidate needed more repair than this, or scores below
  -- this, we are not confident enough to put it under the space bar; the
  -- literal input then leads instead of sitting in its usual slot.
  confidence_cost   = 1.50,
  confidence_floor  = 62,
  -- Below this many characters a candidate has to be a one-letter, no-repair
  -- completion to sit under the space bar, unless the input is itself a
  -- dictionary word.  Short input is variables, units and acronyms ("x", "cm",
  -- "ms", "CW") far more often than it is the start of a longer word.
  trust_min_len     = 3,

  ------------------------------------------------------------------ interface
  -- Put a space after each committed word, carried by the candidate itself so
  -- that whichever key picks the word -- space bar, a number, a click -- puts
  -- the space in too.  Punctuation ends the word without it and supplies the
  -- space that follows instead, so "you" + "." is "you. ".
  auto_space        = true,
  -- Take that space back when punctuation follows a word that was already
  -- committed, so "you " + "." is "you. " rather than "you . ".
  --
  -- Off by default because it needs a frontend that understands the request:
  -- the commit is prefixed with U+0008 BACKSPACE, which the Spellless build of
  -- Weasel turns into one reclaimed character (and only ever a space -- it
  -- checks) while stock Weasel would insert it literally.  Nothing else about
  -- Spellless needs the fork.
  reclaim_space     = false,
  -- Pick up a word you are part-way through re-typing.  Delete the space after
  -- "so", start typing again, and the "so" is taken back out of the document
  -- and into the composition, so the candidates are for "sooner" rather than
  -- for "oner".  Needs the same frontend as reclaim_space, and for the same
  -- reason: it has to remove characters that are already in the document, and
  -- it only ever acts on text the frontend has actually read back.
  absorb_fragment   = false,
  -- Backspace twice in a row, with nothing composing, to delete the whole word
  -- in front of the caret rather than one more character of it -- for when a
  -- word is wrong enough to start again.  Same frontend requirement.
  word_backspace    = false,
  -- Offer a capital on the first word of a sentence.  Only when you typed the
  -- word in lower case: an explicit capital of your own is never overridden.
  auto_capitalize   = true,
  -- When nothing in the dictionary fits and the only thing on offer is what
  -- you typed, the space bar asks before it commits: the first press is
  -- ignored, the second commits.
  --
  -- The space bar is doing two jobs -- pick this word, and separate it from
  -- the next -- and the second is so automatic that the first happens without
  -- being noticed.  That is fine when the candidate is a real word.  It is
  -- exactly wrong when the candidate is a misspelling, which is the one case
  -- where a moment's attention is worth having.  Return still commits
  -- immediately, and always did.
  confirm_literal   = true,
  limit             = 20,   -- candidates handed to Rime
  -- 1-based slot for the "commit exactly what I typed" candidate.  Defaults to
  -- the last slot of the first page so it is one keystroke away without ever
  -- displacing a useful suggestion.  Set to 1 to always offer it first.
  raw_candidate_index = 0,  -- 0 = use menu/page_size from the schema
  raw_comment       = "",
  show_debug_comments = false,

  ------------------------------------------------------------------- learning
  personal_file     = "spellless_user.txt",
  -- Abbreviations you define yourself, one "short<TAB>expansion" per line,
  -- in the Rime user directory.  See spellless/shortcuts.lua.
  shortcuts_file    = "spellless_shortcuts.txt",
  learn             = true,
  -- A word selected this many times reaches the top of the personal scale.
  user_saturation   = 12,
  -- How many personal words are compared against the query directly.  Every
  -- one costs two edit-distance evaluations, so a very long history is capped
  -- at the most recently used entries.
  personal_scan_limit = 400,
  -- Flush the personal file after this many commits, or this many ms.
  flush_every       = 4,
  flush_interval_ms = 5000,
}

--- Merge `overrides` (may be nil) onto the defaults.
---
--- An unknown key is an error rather than a silent no-op, because the only way
--- one gets here is a typo in code or on a benchmark command line.  (Schema
--- YAML cannot produce one: the adapter only ever reads keys that exist here.)
---
--- Values whose default is an integer are floored, because Rime's config
--- returns every number as a double and a float would leak into loop bounds
--- and table keys.
function M.build(overrides)
  local cfg = {}
  for k, v in pairs(M.defaults) do cfg[k] = v end
  if overrides then
    for k, v in pairs(overrides) do
      local default = cfg[k]
      if default == nil then
        error("spellless: unknown config key '" .. tostring(k) .. "'")
      end
      if math.type(default) == "integer" and math.type(v) == "float" then
        v = math.floor(v)
      end
      cfg[k] = v
    end
  end
  return cfg
end

return M
