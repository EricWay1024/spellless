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
  max_cue           = 16,

  -- Edit budgets, in the weighted units of spellless.distance.
  typo_budget       = 1.35,   -- query vs word
  skeleton_budget   = 1.30,   -- query skeleton vs word skeleton
  elastic_budget    = 1.70,   -- query vs a prefix of the word, vowels cheap

  -- Syllabic shorthand: how much of a word a person types.  One probability
  -- per character class -- the chance the typist *keeps* a character of that
  -- kind -- and nothing else; keeping costs -log(p) and dropping costs
  -- -log(1-p), so the alignment cost is a real log-likelihood and the model
  -- normalises itself over the word.  See spellless/cue.lua.
  --
  -- Fitted rather than guessed, which is the point of writing it this way: the
  -- alignment says which characters each known (shorthand, word) pair kept, so
  -- class-wise keep rates are counts.  Over the 342 pairs in
  -- tests/cases/syllables.tsv and generated_cues.tsv, re-estimated until the
  -- alignments stop moving, that is 0.39 / 0.68 / 0.89; coordinate descent
  -- then moved them a little way to what is here, and gained 0.002 of
  -- objective doing it, which is to say the maximum-likelihood numbers were
  -- already right.
  --
  -- In English: a shorthand typist types about a third of the vowels, three
  -- consonants in four when they sit next to another consonant, and six in
  -- seven of the consonants that begin a syllable.
  --
  -- Unlike the other budgets this one is in nats -- how much surprise a
  -- reading may carry before it stops being a reading -- because that is the
  -- unit the alignment works in.
  cue_budget        = 12.0,
  cue_keep_vowel    = 0.32,   -- nobody spells out the vowels
  cue_keep_cluster  = 0.76,   -- a consonant beside another: "think", "strat"
  cue_keep_onset    = 0.86,   -- a consonant between vowels starts a syllable
  -- Nats per unit of `cost`.  The ranker's cost_weight is calibrated against
  -- edit distances, which are not log-probabilities; this divisor is what puts
  -- this channel's log-likelihood on the same scale, and it is the one number
  -- here with no probabilistic meaning.
  --
  -- It is also, in practice, the dial between this channel and the consonant
  -- skeleton: raise it and the cost term flattens, so frequency decides and a
  -- commoner longer word wins; lower it and an exact-skeleton reading wins.
  -- Held out over ten fresh generator seeds, shorthand and skeleton accuracy
  -- move against each other about two to one and the aggregate is flat --
  -- 5: 69.8/91.6, 7: 83.4/90.6, 9: 88.5/89.3, 10: 90.1/88.5, 12: 91.9/87.6,
  -- for a top-1 total of 85.8, 88.7, 89.5, 89.6, 89.6.  A promising +0.13 of
  -- top-5 at 10 did not replicate on ten further seeds held back for exactly
  -- that check, so 12 stands: the difference is where the accuracy sits, not
  -- how much of it there is.
  cue_cost_scale    = 9.0,
  -- One letter of the shorthand may be the wrong key, at this many nats on top
  -- of what keeping it costs.  Without it a slip *inside* an abbreviation is
  -- fatal rather than merely expensive: the letters no longer appear in the
  -- word in order, so nothing at all is offered, and "stfxctn" reaches nothing.
  -- Nothing counts the slips -- two cost twice as much and the budget refuses
  -- them -- which is the same structure as every other channel here.
  --
  -- **On**, at the value the sweep chose; 8 buys more recall for three
  -- case-file regressions.  Over 252 shorthands with one letter corrupted it
  -- takes top-5 from 25.4% to 89.7%, and eleven of a dozen hand-built cases
  -- lead: "algrthn" gives algorithm, "gvrnmxt" government, "mthmxcs"
  -- mathematics.  The case files cannot see any of that -- not one of them
  -- contains a corrupted shorthand -- so the accuracy table is unmoved either
  -- way, and this is a feature whose whole value is outside the benchmark.
  --
  -- It costs about 0.35 ms per keystroke and 0.5 ms at p95, affordable here
  -- only because cue_cost_scale came down to 9 at the same time and gave some
  -- of that back: p95 sits at 9.3-9.8 ms against the 10 ms this project holds
  -- itself to.  Set it to 0 on a machine with less headroom; that is a
  -- supported configuration and tests/test_cue.lua asserts it.
  --
  -- The shape that would make it free is the one scan_first_neighbours wants
  -- too: a second pass, run only when Engine:trustworthy says the first found
  -- nothing worth putting under the space bar.  Twice now the answer to "real
  -- recall at a cost on every query" has been that same gate, and nobody has
  -- built it.
  cue_slip_cost     = 10.0,
  -- Below this length a wrong letter is not a slip, it is a different word:
  -- "tnk" with one letter wrong could be shorthand for anything, and letting
  -- it be turns a three-letter query back into a scan of the dictionary.
  min_cue_slip_len  = 5,
  -- Alignments per keystroke spent on words that are *not* a clean subsequence
  -- of the query.  Its own ceiling rather than a share of cue_max_checks: the
  -- relaxed letter-set test admits five to ten times as many words, and
  -- without a separate bound they would crowd out the exact readings, which
  -- are much likelier to be right.
  cue_slip_checks   = 400,
  -- There is deliberately no fourth class for a doubled letter.  A double is
  -- the clearest case of a consonant beside a consonant, and giving it a
  -- keep probability of its own let the cue reading undercut the typo channel
  -- on its own ground: dropping *one* half of a double is a misspelling, not
  -- shorthand, and "embarass" led with "embarrassed", "adn" with "adding".
  --
  -- How long a word the query may be shorthand for.  Two letters a syllable is
  -- about the least anyone types and five characters a syllable about the most
  -- English offers, so the ratio bounds short input and the absolute gap bounds
  -- long input, where a ratio stops constraining anything.  Past either, the
  -- word the alignment found is a coincidence.
  cue_max_extra     = 12,
  cue_max_ratio     = 3.0,
  -- Alignments per keystroke, after the letter-set filter.
  cue_max_checks    = 900,

  -- Splitting a run of letters back into words.  Charged per word beyond the
  -- first, so a string is not shredded into the many short words English is
  -- full of: at 1.4 "as a matter of fact" starts losing to "asa matter of
  -- fact", and at 0 everything shatters.
  split_words       = true,
  split_word_penalty = 0.8,
  -- How good an ordinary explanation has to be before splitting is abandoned.
  split_max_rival_cost = 1.6,
  -- Below this there is not enough string for two words worth having.  It can
  -- afford to be short because a split never competes: it sits one above the
  -- literal, so a short identifier that happens to segment costs a slot near
  -- the bottom of the list and nothing else.
  min_split_len     = 5,
  -- Above this the search is quadratic and the input is not prose anyway.
  max_split_len     = 28,

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
  -- Two letters is not shorthand for anything, it is a prefix.
  min_cue_len       = 3,

  -- Scan shape.  The typo scan visits words whose length is within
  -- `len_window` of the query and whose first letter is the query's first or
  -- second letter (which covers a slip on the very first key), optionally
  -- extended to the first letter's keyboard neighbours.
  len_window        = 2,
  -- Also scan the QWERTY neighbours of the first letter, for a first key that
  -- was simply the wrong key.  Off, and measured rather than assumed: it takes
  -- that input class from 1.6% reachable to 98.2% on the first page, which is
  -- the largest single recall gain available anywhere in this file -- and it
  -- costs 27% of the per-keystroke budget on *every* query, pushing p95 over
  -- 10 ms on a busy machine, for the slip type that is plausibly rarest (the
  -- first key is typed after a pause, and it is what the whole lookup is
  -- anchored on).  It also loses three cases to the extra rivals it admits.
  --
  -- The shape that would earn it is a second pass, run only when
  -- Engine:trustworthy says the first pass found nothing worth putting under
  -- the space bar -- a predicate that already exists.  Then the common
  -- keystroke pays nothing.  Not built.
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
  base_skeleton     = 62,
  -- Syllable cues.  This is the loosest reading of an input there is, and it
  -- started well below the other sources on that reasoning -- but its job is to
  -- make sure a real word is *on offer* for input the stricter channels cannot
  -- reach at all, and a candidate nobody can see does not do that job.
  -- Coordinate descent put it here, above the skeleton reading it generalises,
  -- and every hand-written case still passes.
  base_cue          = 70,

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
  cost_weight       = 16,   -- x weighted edit distance
  -- Calibration, since these two are the units of the whole score.  The
  -- dictionary's log-frequency range is 14.41 nats, so freq_weight buys 2.36
  -- points per nat and one unit of edit cost is priced at 6.78 nats, about
  -- 880:1.  But that is not the number that governs anything: a repair also
  -- has to cross base_exact - base_typo = 25, and 41 points is 17.4 nats,
  -- while the entire dynamic range of the corpus is 14.4.  So a full-price
  -- repair never beats an exact dictionary match at any frequency -- it is a
  -- veto, not a price -- and in the rank band people actually type, the whole
  -- frequency spread available is 4.7 nats, enough to overturn a cost gap of
  -- 0.69 but never a whole edit.
  --
  -- A sweep says the optimum is cost_weight 13-14 rather than 16, worth 0.005
  -- of tuning objective, three or four cases in 1,484 against a standard error
  -- of eleven.  Not enough to move a shipped constant on the set that fitted
  -- it.
  --
  -- The cost-frequency interaction the design notes wondered about --
  -- cost_weight * cost * (1 + b(1 - freq)), so that a big repair to a common
  -- word is cheaper than the same repair to a rare one -- was implemented and
  -- swept.  The predicted direction is monotonically wrong (b = +1.0 costs 30
  -- cases at rank 1), and the shallow optimum at b = -0.45 turns out to be
  -- cost_weight in disguise: it vanishes once cost_weight is 13.  Coordinate
  -- descent leaves b at -0.15, worth one case.  They do not interact; the
  -- linear form is right.
  extra_weight      = 8,    -- x how much longer the completion is than the input

  ---------------------------------------------------------------- context
  -- One previous word, read as a coarse part-of-speech class.  Off, and while
  -- it is off nothing below is consulted and the ranking is bit-for-bit what it
  -- was -- verified over all 16,429 candidate rows the case files produce.
  --
  -- Off because it was measured and it loses: `lua bench/context.lua` reports 9
  -- answers fixed against 29 broken after "the", and worse after every other
  -- previous word the table has an opinion about.  spellless/wordclass.lua says
  -- why, and it is not something the two constants below can repair.
  context_class     = false,
  -- Points per nat of PMI between the previous word's class and the
  -- candidate's.  The other log-ratio in the score is the frequency term, which
  -- spans 34 points over the whole dictionary, so 5 says one nat of contextual
  -- evidence is worth about a seventh of that -- enough to settle the median
  -- sibling pair, which sits 3.8 points apart, and not enough to move anything
  -- that is 15 points clear.
  --
  -- Swept, so nobody has to sweep it again: with the hand-written table the net
  -- effect after "the" is -1 at weight 1, -3 at 2, -9 at 3, -20 at 5 and -42 at
  -- 8, and the margin below changes none of it.  The only value that does not
  -- lose is zero, which is what the flag being off amounts to.
  context_weight    = 5,
  -- Only candidates within this many points of the leader are re-scored, so the
  -- term can reorder near-ties and cannot reach down the list.  Every
  -- morphological sibling in tests/cases sits within 9.8 points of the word
  -- that beat it; every *exact* match that beat its sibling leads by at least
  -- 19.7, because of form_bonus.  12 is the gap between those two facts.
  context_margin    = 12,

  -- A query with few vowels is far more likely to be an abbreviation than a
  -- misspelling, so skeleton candidates get up to this much extra when the
  -- input looks consonantal.
  skeleton_vowel_bonus = 10,
  -- The same signal for syllable cues.  A separate knob because they are a
  -- separate channel and the tuner should be able to move them apart; that it
  -- landed on the same number is a result, not an assumption.
  cue_vowel_bonus   = 10,

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
  -- Applications that may not have text taken back out of them, by name, comma
  -- separated.  The three features below all work by removing characters the
  -- application has already been given, and that only works where the text is
  -- still in a document the input method can revise.
  --
  -- A terminal is the case where it is not.  Committed text has already been
  -- forwarded to the process on the other end of the pty, and there is nothing
  -- left to revise -- so the frontend's replacement arrives as *more* input and
  -- the line duplicates.  VS Code's integrated terminal (code.exe) is where
  -- this was found; the same is true of every console and terminal emulator,
  -- and Weasel's own shipped config already gives cmd.exe and conhost.exe
  -- special treatment for related reasons.
  --
  -- Matched against the `client_app` property, which the frontend sets to the
  -- executable name of the window being typed into.  Setting the `commit_only`
  -- option -- through Weasel's `app_options`, say -- does the same thing for
  -- one application without editing this list.
  --
  -- The cost of being on this list is small and cosmetic: punctuation after a
  -- committed word reads "you . " instead of "you. ".  The cost of being off it
  -- wrongly is a corrupted line.
  commit_only_apps  = "code.exe,conhost.exe,cmd.exe,powershell.exe,pwsh.exe," ..
                      "windowsterminal.exe,wt.exe,openconsole.exe,mintty.exe," ..
                      "alacritty.exe,wezterm-gui.exe,putty.exe",
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
  -- Type this and the candidate list says which build is running, which words
  -- it loaded and how it is configured.  Nothing else answers that question
  -- from outside the process, and "am I testing the build I just deployed"
  -- has cost more time on this project than any bug in it.
  --
  -- Not English, not in the dictionary, and matched on the whole input only,
  -- so it cannot fire by accident.  Set to "" to remove it.
  version_query     = "zzver",
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
  -- How many times you have to pick the same reading of the same input before
  -- it leads the list.  One selection is not evidence -- a good deal of what
  -- anyone picks is picked once by accident -- and the second is different in
  -- kind: it says the first was not a slip.  Corrections are kept in the
  -- personal file as "> typed <TAB> chosen <TAB> times".
  --
  -- Only selections count.  Committing the raw input with Return is a refusal
  -- to choose between readings rather than a choice, and counting it would
  -- fill the store with the misspellings this exists to correct.
  choice_confirm_count = 2,
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
