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
  base_exact        = 100,
  base_prefix       = 74,
  base_typo         = 75,
  base_skeleton     = 66,

  freq_weight       = 34,   -- x normalised corpus log-frequency, in [0,1]
  user_weight       = 26,   -- x normalised personal frequency, in [0,1]
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
