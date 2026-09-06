# Design

> Treat spelling as a noisy encoding of intended English, and use an IME
> candidate interface to decode the intention.

Spellless is a Rime schema plus one Lua translator. It does not patch librime,
does not ship a compiled plugin, and does not need administrator rights.
Everything Rime already does well — composition, candidate selection, paging,
punctuation, committing raw text — is left to Rime; the only custom part is
deciding *which words to offer and in what order*.

There is one exception, and it is deliberately small. Three features need to
read the text in front of the caret and take a character of it back, and the
Rime API has no channel for either, because a commit is a string and what
happens to it afterwards belongs to the application. So they come from a
companion build of Weasel —
[spellless-weasel](https://github.com/EricWay1024/spellless-weasel) — which
adds those two conventions and nothing else (§5.6). They are off by default,
it installs beside a stock Weasel rather than replacing it, and everything
else here runs without it.

---

## 1. What current Rime gives us

Checked against the shipping code, not old blog posts (September 2026):

| Component | State |
| --- | --- |
| **Weasel** | 0.17.4 (June 2025) is the current release; nightly builds track master. 0.17.x bundles librime 1.13.1. `WeaselSetup.exe /userdir:<path>` sets the user directory. |
| **librime** | 1.17.0 (June 2026) upstream. |
| **librime-lua** | Built into every official librime release artefact. `.github/workflows/release-ci.yml` lists `rime_plugins: hchunhui/librime-lua lotem/librime-octagram rime/librime-predict`, and Weasel's `get-rime.ps1` downloads those artefacts. **A stock Weasel install already has Lua.** |
| **English schemas** | `easy_en` and rime-ice's `melt_eng` are `table_translator` over a `*.dict.yaml`. They give exact and prefix lookup and nothing else: a table dictionary is a trie keyed on the exact code, so a misspelling simply misses. |
| **Existing fuzzy work** | Rime's own "fuzzy pinyin" is a *spelling algebra* (`derive/xform` rules in the schema) that expands a syllable into alternative spellings before dictionary lookup. It is a good fit for a closed syllabary of ~400 pinyin syllables and a bad fit for English: covering arbitrary typos would mean generating millions of derived spellings, which the brief explicitly rules out. rime-ice's `corrector.lua` fixes a fixed hand-written list of confusions. Neither approach generalises. |

### librime-lua API actually used

Verified by reading `src/types.cc` and `src/lua_gears.cc` upstream rather than
inferring from examples:

* `lua_translator@*module` — `require`s `module` from `<user dir>/lua/?.lua`
  and calls `init(env)`, `func(input, seg, env)`, `fini(env)`.
  `env` carries exactly `engine` and `name_space`.
* `Candidate(type, start, end, text, comment)`, with a settable `quality`.
* `seg:has_tag(tag)`, `seg.start`, `seg._end`.
* `env.engine.schema.config` → a `Config` with `get_bool/get_int/get_double/get_string`.
* `env.engine.context.commit_notifier:connect(fn)` → a `Connection` with
  `disconnect()`. The notifier fires *before* the context is cleared, so
  `ctx:get_commit_text()` is valid inside it.
* `rime_api.get_user_data_dir()`, `get_shared_data_dir()`, `get_time_ms()`.
  On Windows these return native paths; the CRT accepts `/` in them, so path
  joining needs no platform branch.
* `package.path` is pre-seeded with `<user dir>/lua/?.lua`,
  `<user dir>/lua/?/init.lua` and the shared-directory equivalents.
  `rime.lua` is loaded from the **user** directory if it exists and from the
  shared one otherwise — only one of them, never both. Spellless therefore
  never touches `rime.lua`: an installation that overwrote it would silently
  break every other Lua-using schema the user has.

---

## 2. Where each responsibility lives

```
keystroke
   |
   +-- spellless        the `$` that ends an ASCII run          [Spellless]
   +-- ascii_composer   Caps Lock / ASCII mode                     [Rime]
   +-- recognizer       "sqlite3", "foo_bar", urls, emails         [Rime]
   +-- speller          builds the composition, a-z A-Z '          [Rime]
   +-- punctuator       , . ! ?                                    [Rime]
   +-- selector         number keys, paging                        [Rime]
   +-- spellless        spaces, capitals, punctuation, Enter   [Spellless]
   +-- express_editor   Space = confirm, Enter = commit raw input  [Rime]
                           (Enter first passes our processor, for the space)
              |
              v
        segment tagged "abc"
              |
              v
   lua_translator@*spellless                                    [Spellless]
        |
        +-- exact / prefix        binary search, alphabetical index
        +-- typo                  bounded scan + weighted edit distance
        +-- skeleton              skeleton index + scan, elastic alignment
        +-- cue                   first-letter buckets, syllabic subsequence
        +-- personal vocabulary   linear pass over what you have chosen
                     |
                     v
              one additive score
                     v
              ranked candidates + the literal input
                     v
              a leading space, if the commit history calls for one
```

Three consequences worth stating explicitly:

* **Enter always commits exactly what you typed.** This is not something
  Spellless implements. librime's `ExpressEditor` binds `Return` to
  `CommitRawInput` (`src/rime/gear/editor.cc`), which clears the non-confirmed
  composition and commits the input string. Using `express_editor` rather than
  `fluid_editor` — where `Return` commits the *selected candidate* — is a
  deliberate choice.
* **Nothing is ever replaced silently.** `speller/auto_select` is left off, so
  a lone candidate never commits itself, and the literal input is always among
  the candidates (§6).
* **A tap on Shift leaves the schema entirely.** `ascii_composer` toggles
  `ascii_mode` on a bare Shift press-and-release, and `commit_code` makes a tap
  mid-word commit what was typed, literally, before switching. This matters
  more than it looks: it is the general answer to LaTeX, shell commands,
  citation keys and anything with a digit in it, and it means the matcher does
  not have to be taught about them one class at a time. It is safe to bind
  because librime cancels the toggle if any other key arrives in between, or if
  Shift is held for more than 500 ms — so `Shift`+`M` cannot trip it.

### What the schema deliberately does *not* have

* **No `*.dict.yaml`.** A Rime table dictionary would only duplicate the exact
  and prefix lookup the Lua side already does, would double the memory, and
  would still contribute nothing to fuzzy matching. Rime is perfectly happy
  with a schema whose only content translator is a Lua one.
* **No spelling-algebra `derive` rules.** See the table above.
* **No regex lists of known misspellings.** The matcher is general; the case
  files in `tests/cases/` are expectations, not data the code reads.

---

## 3. Data and indexes

Built offline by `scripts/build_dictionary.py` and `scripts/build_indexes.py`,
shipped in `generated/` (about 1.3 MB in total):

| File | Size | What it is |
| --- | --- | --- |
| `spellless.words` | 756 kB | 83,151 words, newline separated, **most frequent first**. A word's id is its 1-based line number. |
| `spellless.weights` | 83 kB | one byte per word: log-frequency rescaled onto 0–255. Read straight out of the string with `string.byte`; no parsing, no scaling constants in the Lua. |
| `spellless.alpha` | 249 kB | word ids sorted alphabetically, 3 bytes each. Exact and prefix lookup. |
| `spellless.skel` | 249 kB | word ids sorted by consonant skeleton, 3 bytes each. Abbreviation lookup. |

The single most useful decision here is that **the word id is the frequency
rank**. Picking the best few entries out of an index range then needs no sort
and no frequency lookup: the smallest ids in the range are the most common
words, and a bounded "keep the n smallest" selector does it in one pass.

Two further structures are derived at load time because deriving them is
cheaper than shipping and parsing them (measured: about 60 ms of the 104 ms
load):

* a 26-bit letter-presence mask per word, and the same for its skeleton;
* word ids bucketed by `(length, first letter)` and by
  `(skeleton length, first letter)`, each bucket inheriting frequency order.

Sorting 83k strings inside Lua would cost hundreds of milliseconds, which is
why the two orderings *are* precomputed. Everything else is not.

Loading costs **104 ms and 13.9 MB, once per Lua state**. librime-lua runs a
single Lua state per process and `Corpus.load` memoises per directory, so
opening a second application window costs nothing.

---

## 4. Matching

### 4.1 A weighted edit distance, not a plain one

`spellless/distance.lua` implements Damerau-Levenshtein restricted to
non-overlapping adjacent transpositions (the OSA variant — the restriction is
irrelevant for single words and keeps the recurrence to three rolling rows).

Every edit has its own price, because fast-typing errors are not uniformly
likely:

| Edit | Cost | Why |
| --- | --- | --- |
| dropped apostrophe | 0.15 | `dont`, `its`, `id`. Leaving one out is a typographic shortcut, not a spelling error, so `don't`, `it's` and `I'd` stay adjacent to the words that were typed. |
| adjacent transposition | 0.45 | `theorme`, `recommned`, `teh` — the error class the brief singles out |
| miscounted double letter | 0.55 | `commited`, `harrass`, `refered`, `accomodate`. A character adjacent to a copy of itself is priced as a doubling slip rather than an invented character. |
| dropped or doubled vowel | 0.70 | `seperate`, `definately` |
| neighbouring key | 0.70 | `nirth` → `north`, from a QWERTY layout with real key offsets, so `d` neighbours both `e` and `r` |
| vowel for vowel | 0.75 | `definately` |
| anything else | 1.00 | |

The doubling rule was added because it was visibly the largest single class of
residual failures: `commited` reaches `commuted` for 0.70 (a neighbouring key)
but needed 1.00 to reach `committed`, so the wrong word won.

The DP is banded and aborts when **two consecutive** rows have every cell over
budget. Two, not one: a transposition reads the row *two* back, so a single row
can go over and the next still recover through it. Aborting on one row silently
discarded `ifnomration` → `information` (two transpositions, cost 0.90) — a
bug that survived three months and a hand-written reference-implementation
test, because no pair in that test's word list happened to need the recovery.
`tests/test_distance.lua` now corrupts 400 real corpus words instead.
The band is derived rather than guessed: reaching a cell *d* columns off the
diagonal when the strings differ in length by `delta` needs at least
`2d - delta` insertions or deletions, so
`band = floor((budget / cheapest_indel + delta) / 2)`, and the comparison is
abandoned if that band cannot reach the far corner at all.

The apostrophe is deliberately left out of `cheapest_indel`. At 0.15 it would
widen the band from one column to four for *every* comparison; instead each
apostrophe actually present in either string buys one extra column, which costs
nothing for the 99.9% of words that contain none.

### 4.2 Consonant skeletons

The skeleton of a word drops `a e i o u`, with two exceptions:

* **`y` is kept.** It is consonantal about as often as it is vocalic, and,
  decisively, a typist writing an abbreviation keeps it: `systm`, `tplgy`,
  `hmtpy`. Dropping it would turn `system` into `sstm`, which nobody types.
* **The first character is kept even when it is a vowel**, because nobody drops
  a leading vowel: `about` → `abt`, not `bt`.

That rule is written twice — `scripts/_common.py` and
`rime/lua/spellless/skeleton.lua` — because the Python side sorts the index and
the Lua side binary-searches it. `tests/test_skeleton.lua` walks the whole
shipped index and asserts the ordering is still monotone under the Lua
function, so the two cannot drift apart silently.

Because typists *do* drop a leading vowel sometimes, the matcher also probes
the index with each of the five vowels prepended, which is how `nvrnmnt`
reaches `environment`.

The index answers exact skeletons and their completions; a *mistyped* skeleton
needs a scan, and that scan compares the query's skeleton against a **prefix**
of the word's rather than all of it. An abbreviation with a slip in it is
usually also unfinished — `alghrith` is `algorithm` with an `h` for the `o` and
no `m` yet — and demanding the whole skeleton charges for the slip and the
missing tail at once, which no budget worth having can absorb. The elastic pass
below still prices the query against the real word, so this only widens who
gets considered; `alghrith` went from offering nothing at all to leading with
`algorithm`.

### 4.3 Elastic alignment: how skeleton candidates are priced

This is the part that took the most iteration.

The obvious approach — compare `skeleton(query)` with `skeleton(word)` — throws
away the vowels the user actually typed, so `mathe` (skeleton `mth`) matches
`mouth` exactly as well as `mthmtcs` matches `mathematics`. That is wrong:
those vowels are evidence.

Skeleton candidates are therefore scored by aligning the **original query**
against a **prefix of the word**, with an asymmetric cost profile:

* a vowel the typist *left out* costs 0.10 — that is what an abbreviation is;
* a vowel the typist *typed* costs 0.90 to delete — it is evidence;
* consonants cost full price either way.

Taking the minimum over the last DP row instead of its last cell gives "the
best alignment against any prefix", which is exactly what a completion is. So
`mthmt` aligns with the `mathemat` of `mathematics` for 0.30, and the rest of
the word is charged by the ranker as a completion rather than as edits.

The effect, measured:

| query | word | elastic cost | |
| --- | --- | --- | --- |
| `mthmtcs` | `mathematics` | 0.40 | four vowels skipped |
| `mthmt` | `mathematics` | 0.30 | three skipped, aligned against a prefix |
| `frm` | `from` | 0.10 | one skipped |
| `mthmtcs` | `mathematical` | 1.10 | one consonant wrong |
| `theorme` | `thermal` | 1.50 | two typed vowels have to go |
| `mathe` | `mouth` | 1.60 | likewise |

The last two are near the budget of 1.70 rather than comfortably inside it, and
at 19 points of score per unit of cost that is the difference between leading
the list and being nowhere near it: for `mathe` the first six candidates are
all prefix completions of `math-`, and `mouth` does not appear at all.

### 4.4 Syllable cues: shorthand nobody had to learn

Two channels above both assume the typist is *spelling* — either the whole word
with slips in it, or all of its consonants. Neither reaches what people
actually do with a long word, which is to say it to themselves and type one or
two letters per syllable:

    stratification  ->  strat-i-fi-ca-tion  ->  satfcatn

Every consonant that got dropped there costs a full 1.00 in the edit channel
(`satfcatn` → `stratification` is 2.40 against a budget of 1.70) and the
skeleton channel wants all eight of `strtfctn`. The word was simply
unreachable: before this channel existed, `satfcatn` offered nothing at all,
and `alghrith` — `algorithm` with an `h` for the `o` and no `m` yet — offered
nothing either.

What every such input does have is that **the letters typed appear in the word,
in order**. So `spellless/cue.lua` aligns the query as a *subsequence*, and the
entire question becomes what the skipped characters were worth:

| Skipped | Cost | Because |
| --- | --- | --- |
| a vowel | 0.04 | nobody spells out the vowels |
| a consonant beside another consonant | 0.35 | clusters, codas and doubled letters: the `h` of `think`, the `r` of `strat`, the `n` of `-nk`, one `t` of `cattle` |
| a consonant between two vowels | 0.60 | that is a syllable's onset — the one letter a shorthand typist does keep |

Those three prices are the whole model. There is no syllabifier, no
pronunciation dictionary and no codebook to learn: a consonant sitting between
two vowels begins an English syllable often enough to be worth pricing, and
being wrong about it costs a little score rather than a candidate. The user
instruction is "type what feels representative of each syllable", and nothing
more precise than that is needed.

Three details do the real work.

**The first letter must match.** It is the one character a shorthand typist
never drops, and requiring it is what stops a three-letter query proposing half
the dictionary.

**The tail is charged too.** Everything the query did not land on is priced,
*including* the characters past the last match. Shorthand runs to the end of a
word — nobody types cues syllable by syllable and then stops two syllables
early — so a word with an untouched tail is being *completed*, which is what
the prefix and skeleton channels are for. This one rule is what separates
`embarass` → `embarrass` (nothing left over) from `embarass` →
`embarrassed` (a whole syllable nobody typed); without it the second led, and
`common_typos.tsv` would not pass.

**A doubled letter gets no special price.** It was given one at first, on the
theory that `cattle` → `ctl` drops nothing real. But dropping *one* half of a
double while keeping the other is a misspelling, not shorthand, and at its own
low price the cue reading undercut the edit channel on its own ground:
`embarass` led with `embarrassed` and `adn` led with `adding` rather than
`and`. A doubled consonant is already the clearest case of "a consonant beside
a consonant" and needs no rule of its own.

Precision comes from the prices rather than from a filter. `tnk` aligns onto
`think`, `tank`, `thank` and `trunk` alike; which of them leads is a question
about English frequency, which the ranker already answers. In the ranking the
channel carries the same "does this input look consonantal?" signal the
skeleton channel uses, so a vowel-rich query like `mathe` gets its cue readings
pushed down and a consonantal one like `satfcatn` gets them pushed up. It has
its own knob for that (`cue_vowel_bonus`) because it is a different channel and
the tuner should be free to separate them; today the two agree at ±10, and a
first attempt that ran the cue slope much steeper turned out to be a worse way
of saying the same thing than simply raising `base_cue`.

Generation cannot use an index — a subsequence has no prefix to binary search,
and the skeleton permutation is exactly what these queries fail to match — so
it is a scan over the first-letter buckets, filtered by the same 26-bit letter
mask the other scans use. Here the test is a strict subset: every letter typed
must be somewhere in the word, `qmask & ~wordmask == 0`, which rejects all but
a few dozen of the words sharing the first letter at two integer operations
each. What survives that gets a leftmost-greedy subsequence check (one walk,
no table writes) before anything is priced. The channel is skipped entirely
when the query is itself a dictionary word — shorthand is what you write
*instead* of a word — which is also what keeps the common case free.

### 4.5 Keeping it interactive

Measuring edit distance against 83k words per keystroke is not affordable in
interpreted Lua (about 5 µs per comparison). Three things bring it down to a
couple of milliseconds:

This is about the typo and skeleton scans; the cue scan has a different shape
and pays for itself differently, described in §4.4.

**Anchored buckets.** The scan only visits words whose length is within 2 of
the query and whose first letter is the query's first *or second* letter — the
second covers a slip on the very first key. Neighbour letters are available
behind `scan_first_neighbours` but are off by default.

**Exact per-length bit budgets.** Each candidate carries a 26-bit letter mask.
Given the length difference, the *mandatory* insertions and deletions are
already paid for; whatever budget remains can only buy substitutions, and each
edit moves at most one letter into or out of the letter set. So a word two
characters shorter than the query may differ by exactly the two dropped letters
and nothing else. Two 13-bit popcount lookups per candidate reject most of the
bucket. This is what makes the ±2 length buckets cheap; a fixed tolerance of
"two letters either way" scanned about ten times as many candidates.

Note that a *doubling* slip does not change the letter set at all — the letter
is still there — so the profile distinguishes "cheapest indel" (for the band)
from "cheapest indel that changes the letter set" (for these budgets).

**A check ceiling.** At most `max_checks` (1200) distance evaluations per scan.
Lengths are visited most-plausible-first (0, −1, +1, −2, +2) and each bucket is
frequency ordered, so hitting the ceiling drops the least likely candidates
rather than an arbitrary slice.

The DP inner loop itself does array reads and arithmetic and never calls into
C: both strings are converted to byte arrays and per-character price arrays
before the loop, the query's arrays are cached across the whole scan, and
substitution costs come from a flat 128×128 table built once per profile.
Removing three `string.byte` calls per DP cell roughly halved the cost of a
comparison; forcing the band arithmetic to produce integers rather than floats
(so table keys need no normalisation) took another 20%.

---

## 4.6 Words the corpus cannot spell

The frequency list is lowercase throughout, and capitalisation is otherwise
reconstructed from how the input was typed (`Mathe` → `Mathematics`). That
covers everything except words with *no valid lowercase form*: you can never
mean a lowercase pronoun `i`.

`data/forms.txt` supplies the surface form for exactly that class, and the bar
for an entry is precisely that criterion — `march`/`March` does not qualify,
because demoting the verb would be worse than the capital is worth. The build
emits `generated/spellless.forms`, the corpus loads it, and `Engine:surface`
substitutes it. `apply_case` never lowercases, so the form survives whatever
capitalisation the input had.

---

## 5. Ranking

Every candidate gets one additive score. The per-source base values express
only the *broad* priority; frequency, edit cost, completion length and personal
history do the fine ordering, so a very common word reached by a cheap typo can
legitimately overtake a rare exact prefix completion — `teh` should give `the`,
not `tehran`.

```
score = base[source]
      + freq_weight  * corpus_log_frequency        (0..1)
      + user_weight  * personal_frequency          (0..1, log, saturating)
      - cost_weight  * weighted_edit_distance
      - extra_weight * how_much_longer_than_typed  (0..1)
      + skeleton_vowel_bonus * (2 * consonant_ratio - 1)   [skeleton only]
```

The last term is signed on purpose: a consonant-only input is strong evidence
for the abbreviation reading, and a vowel-rich one is evidence *against* it.
`mthmtcs` gets the full bonus, `mathe` gets none of it.

The weights in `config.lua` were chosen by coordinate descent
(`bench/tune.lua`) against `tests/cases/`, not by intuition; the objective is a
macro average over the case files so the 900 generated cases do not drown out
the hand-written ones.

---

## 5.5 Spaces and capitals

**Rime cannot retract committed text.** `key_binder`'s `send:` looks like a way
out and is not — it re-processes the key inside the engine and drops it if
nothing handles it, so a synthetic Backspace never reaches the application
(`key_binder.cc`, `PerformKeyBinding`). Every spacing rule therefore has to
avoid *writing* a space in the wrong place, because it can never remove one.

So the space rides on the word, and punctuation takes it back off:

| what you type | what is committed |
| --- | --- |
| `hello` then space or a number key | `hello ` — the space is in the candidate text, so whichever key commits the word brings it along |
| `you` then `.` | `you` **without** its space, then `. ` |

The processor sits between the speller and the punctuator. When punctuation
arrives while a word is composing it commits the selected candidate with the
trailing space stripped and clears the composition — but only when a single
segment covers the whole input, because `get_selected_candidate` returns the
*last* segment and clearing would otherwise throw away everything selected
before it.

Then what writes the punctuation depends on a setting that turns out to matter
enormously. **With `ascii_punct` on — which this schema sets, and which is what
anyone writing English wants — librime's punctuator returns `kNoop`
immediately and never creates a candidate at all** (`punctuator.cc`, 1.13.1).
So there is nothing for a filter to act on, and the processor writes the mark
itself; the punctuation is plain ASCII by definition, so that is faithful
rather than a reimplementation. With `ascii_punct` off, the processor stands
back and a filter on `punct` segments adds the space instead.

Either way the question is the same one `preceding.needs_space_after` asks
about the text behind a word: a full stop or comma yes, an opening bracket no.
Both paths ask it about the commit tail *plus* the mark, never the mark alone —
a lone `$` always reads as opening, so the closing one in `$X$` would never get
its following space.

Two earlier designs failed, and both failures are instructive:

* **A leading space on the next word.** Same final text, but the candidate list
  showed a space on every entry, and any commit that bypassed our candidates —
  a Shift tap mid-word, anything typed in plain-ASCII mode — lost it.
* **Committing the space when the next word starts.** That needed the processor
  ahead of `ascii_composer`, where nothing ever composes in ASCII mode — so
  "no composition" was true for *every* keystroke and it put a space before
  every letter.

What remains is the case no schema can reach: commit a word with the space bar
or a number key and *then* type punctuation, and the space is already in the
document. Within Rime that space has to be deleted by hand. Reaching it at all
means changing the frontend — see §5.6.

A third failure is worth recording because it was invisible from inside the
repository: the first version of this model stripped the word's space and left
the punctuation to a filter that, under `ascii_punct`, never ran. `hello , wrold`
came out as `Hello,world`. Nothing in the Lua could have shown that — it needed
reading the punctuator's source for the version actually installed.

The text behind the cursor is `context.commit_history`, which is more useful
than it first looks: librime pushes printable keys typed *outside* a
composition into it (so a space you type yourself is visible) and **clears** it
on Return and Backspace (so a new line or a correction starts clean).

Not the *newest record*, though — the last few, stitched back together.
Punctuation is committed on its own, so the newest record is frequently a bare
`"` or `$` or `\` with nothing around it to say whether it opens or closes.
Reading only that record turned `He said "no."` into `."the` and lost the
capital as well. `commit_tail` concatenates the last few records instead, which
restores exactly the context the record boundaries threw away.

`preceding.lua` then looks at the last character: opening brackets, joiners like
`-` `/` `_`, whitespace and anything non-ASCII suppress the space; letters,
digits and closing punctuation call for one. Quotes, `$` and backticks are
*paired* — they open when a space or bracket precedes them and close otherwise,
which is what makes `Let $` hug its formula while `Let $X$ be` does not. The
test is run-aware, because `$$` and ` `` ` are one delimiter written twice.

Sentence detection strips trailing space and closing marks *before* testing for
an abbreviation, not after. Testing first meant `(e.g.)` — much the commonest
way to write it — started a new sentence. A trailing `\` means a LaTeX control
sequence has begun, and the literal leads so that `\citep` does not become
`\cited`.

### 5.6 What the frontend can do and Rime cannot

A commit is a string. There is no channel in the Rime API for "and take one
character back", because once text has left the IME it belongs to the
application — which is why every rule above is built around never writing a
space in the wrong place rather than removing one.

The frontend is on the other side of that line. It holds a TSF composition
range, and extending that range backwards over text it has already committed
and replacing the result is ordinary TSF — the same mechanism reconversion
uses. So the fork adds exactly one convention, and nothing else:

> A commit string may begin with `U+0008`. Each one asks for one character
> immediately behind the insertion point to be replaced.

`CInsertTextEditSession::DoEditSession` strips them, calls
`ITfRange::ShiftStart` by that many characters, and lets the existing
`SetText` overwrite what it took. Two properties make it safe to ship:

* **It is verified.** The extended range is read back with `GetText`, and if it
  is not whitespace the shift is undone and the commit lands unchanged. The
  schema cannot see a click or an arrow key, so the caret may not be where the
  commit history says; the frontend checks rather than trusting.
* **It degrades.** An application that will not give up the range keeps its
  characters, and the text still goes in.

On the Lua side this is `reclaim_space`. It is **on by default**, which is
only safe because the schema can tell the two kinds of frontend apart: it asks
for nothing until one has set `surrounding_text`, and no stock build ever
does, so on stock Weasel the `U+0008` is never emitted rather than typed in
literally. Setting and honouring the two halves of the convention were added
to each fork in the same commit, which is what makes the first a sound proxy
for the second. `preceding.hugs_previous`
decides which marks earn it: sentence punctuation and closing brackets, and
deliberately not the paired marks, because with the space stripped `he said "`
and `"no." ` are indistinguishable from behind.

`commit_tail` resolves the backspaces when it reads the history back, so
everything downstream — spacing, capitalisation — sees the text the commit
produced rather than the request that produced it.

That is the write side. The fork answers the read side with a second
convention: it publishes the few characters in front of the caret as the
`surrounding_text` property, and `document_tail` prefers it to the commit
history whenever it is there. That is what stops the spacing and capitalisation
rules above from guessing — a click that moved the caret becomes visible — and
it is what `absorb_fragment` and `word_backspace` are built on, because both
delete text that is already in the document and a guess is not good enough to
delete on.

Those two conventions are the whole dependency. Everything else in Spellless
runs on stock Weasel, which is why the two are installed side by side rather
than one replacing the other: fresh TSF GUIDs, its own named pipe, its own
registry key and its own user directory, so the Chinese input method already
installed is untouched.

### Where a sentence starts

Capitalisation wants the same signal and cannot quite use it, because Rime
clears the commit history on **Return and Backspace alike** — a new line and a
correction look identical afterwards, and they want opposite answers.

So the processor, which sees every key, writes down which one happened in the
context's property map (the two gears get separate `env` tables but share the
input context):

| note | meaning |
| --- | --- |
| `"1"` | a Return landed outside a composition: a new line |
| `"0"` | a Backspace did: we are somewhere inside existing text |
| `""` | nothing since the last commit, so the commit history knows best |

The note is cleared on every commit *and* stamped with the size of the commit
history when it was written, so it never outlives the one keystroke it
describes. Both are needed: without the stamp, tapping Shift into plain typing,
writing a whole sentence and tapping back left a Backspace from before the
excursion still insisting we were mid-sentence — ASCII-mode keystrokes reach
the commit history but never reach this processor. With the note cleared, an
*empty* history unambiguously means a context nobody has typed in yet, which is
a sentence start. Everything else falls to `preceding.ends_sentence`, which steps back over closing quotes and
brackets looking for `.`, `!` or `?`.

An explicit capital in the input always wins: `mathe` at a sentence start
becomes `Mathematics`, but `MATHE` is left as `MATHEMATICS` and `kubectl` — the
literal candidate — is never touched at all.

Two things this cannot know about: a mouse click that moves the caret, and an
abbreviation typed dot by dot. Backspace re-syncs the first, and on the fork
the question does not arise (§5.6). The second is why
`data/forms.txt` maps `eg` → `e.g.` and `ie` → `i.e.`: `.` is not in the
speller's alphabet, so typing it would end the composition anyway, and
committing the abbreviation as one candidate means the whole of it is there to
recognise. `Corpus.abbreviations` collects every form ending in a full stop,
and `ends_sentence` consults it first.

### `$` hands the keyboard over

Maths is not English, and a candidate list in front of `\frac{a}{b}` is in the
way. Typing a character in `ascii_delimiters` (just `$` for now) writes it and
turns ASCII mode on; typing the same character again writes it and turns ASCII
mode off. Between the two, every keystroke is the typist's.

The two halves live in different places, and have to. The opening `$` is
ordinary punctuation: the branch below ends the word, works out the spacing and
writes the mark, and all that is added is the switch and a note of which
character opened the run. The closing one arrives in ASCII mode, where
`ascii_composer` rejects printable keys where it stands — first in the
processor list — so nothing behind it runs. Hence `lua_processor@*spellless*delimiter`,
in front of it, which answers for one character in one state and returns
`kNoop` for everything else.

Only the delimiter that opened a run closes it. ASCII mode reached by tapping
Shift has no delimiter, so `$PATH` in a terminal is a dollar sign followed by a
word, which is what a terminal needs it to be. Leaving ASCII mode by any other
route — Shift, F4, `Control+Shift+A` — makes the note stale, and the next key
seen in Spellless mode clears it rather than the gear trying to recognise every
way the mode can change.

The space after the closing `$` is decided rather than measured: everything
typed inside the run went straight to the application, so the commit history
still reads as it did before the run opened and `needs_space_after` has nothing
to work with. A closing delimiter takes a space for the same reason a word
does, and punctuation takes it back on the frontend that can (§5.6).

### Editor snippets

`xdm` means a display-maths block to VS Code's HyperSnips and nothing at all to
English. It only means it if those three letters reach the document, which
under an input method they never do — the composition offers words and whatever
commits it adds a space. So `spellless_snippets.txt` lists the editor's
triggers and the same processor gives those letters back: committed verbatim
the moment the composition equals a trigger, with no space and no capital.
Being in front of the speller is what makes it possible; a processor behind it
never sees a letter at all.

A trigger marked `ascii` hands the keyboard over as `$` does, because what
follows it is maths. The theorem environments do not: what follows `xthm` is a
sentence of English. Triggers are refused outside `snippet_apps` (`code.exe`) and the `$` pair
above outside `delimiter_apps` (`code.exe,typora.exe`) — two questions with two
answers, since a trigger is meaningless where nothing expands it while a `$` is
maths in any editor that renders it and a price in a chat window. Both
directions of the `$` are gated together: gating only the way back leaves an
application one keystroke from ASCII mode and none back out.
[docs/SNIPPETS.md](docs/SNIPPETS.md) is the whole scheme, including why every
trigger starts with `x`.

### Enter, and what the processor actually owns

`express_editor` commits the raw input, which is what makes Enter the "exactly
what I typed" escape, and it commits the letters alone — a schema-level editor
knows nothing about our spacing. So the processor takes Return over for one
reason: to add the trailing space every other commit carries (`enter_space`,
which needs `auto_space`). The letters are still exactly the ones typed; only
the separator that follows them is new, and a word finished with Enter needs it
as much as one picked with the space bar.

Taking it over pays for a second thing. The arrow keys are how you disagree
with the ranking without counting lines, and having disagreed, Return is the
key already under the finger — where committing the raw input would throw the
choice away and hand back the letters that were wrong enough to go looking. So
with `segment.selected_index > 0` Return calls `Context:commit()`, the same
call `express_editor` makes for the space bar, which takes the highlighted
candidate and the space it carries. The test is the highlight rather than a
note that an arrow key was pressed: a fresh composition and one arrowed back to
the top are the same thing, so the literal reading stays one press of Return
away. It counts as a deliberate choice, unlike the space bar (§7) — two keys
aimed at one line cannot be muscle memory.

Taking the key over means doing by hand what the editor did for free: the
commit is ours, so the notifier never fires, so the word is counted here. It is
counted and no more — committing the raw input is a refusal to choose between
readings rather than a choice, so no input-to-word pair is stored (§7).
Shift+Return keeps the bare word: it is the soft newline in Slack and Zulip,
and a space in front of a line break separates nothing. Keypad Enter is Enter
and carries the space. With `enter_space` off the branch is skipped entirely
and `express_editor` does exactly what it did before.

What the processor does own is small: ending a word when punctuation arrives,
the sentence note below, and `Control+Shift+A`. That last one commits the composition before
toggling, which `key_binder`'s `toggle: ascii_mode` does not — it leaves an
open composition and then appends plain ASCII to it, failing at exactly the
mid-word escape it exists for. `engine:commit_text` does not fire the commit
notifier, so that path learns explicitly.

---

## 6. Never being trapped in the dictionary

Two distinct promises, and they are not the same one:

* **The literal input is always on the first page.** It is inserted at a fixed
  slot (`raw_candidate_index`, default: the last slot of the first page) unless
  it is already there as a real candidate. A fixed slot means the keystroke
  that commits it is predictable.
* **When nothing we found is trustworthy, the literal input leads**, so the
  space bar cannot turn an identifier into a random English word.

"Trustworthy" (`Engine:trustworthy`) is four tests, and the last two exist
because a *perfect* completion can still be no evidence at all:

| test | rejects |
| --- | --- |
| `best.cost <= 1.5` | expensive repairs |
| `best.score >= 62` | repairs onto obscure words — `librime` → `librium` |
| not typed in capitals, unless the input is itself a word | `PDE`, `TQFT`, `CW`, `DOI`, and two-letter `QF`, `DP`, `GH`. Typing an acronym in capitals is deliberate. |
| at least 3 characters, unless the input is itself a word | `x` → `xxx`, `cm` → `come`, `ms` → `mas`. One or two characters are variables, units and acronyms far more often than the start of a longer word, and completing them buries what was actually typed. A one-letter, no-repair completion is still allowed, so `th` → `the` survives. |

The order of those last two matters and was wrong once: with the length test
first, its one-letter exception returned before the capitals test ever ran, and
`QF` became `QFT`.

`spellless`, `kubectl`, `argmax`, `x`, `cm` and `PDE` all lead with themselves;
`recieve`, `mthmtcs`, `i`, `eg` and `th` do not.

And, independently of both, `Enter` commits the raw input (§5.5).

snake_case identifiers get a third mechanism. librime's `recognizer` processor
pushes a character into the input whenever `input + char` matches one of its
patterns, regardless of the speller's alphabet, so
`ident: "^[A-Za-z]+_[-_.0-9A-Za-z']*$"` takes the whole token literally as soon
as an underscore appears.

It deliberately stops there. An earlier version also triggered on digits, so
that `sqlite3` would compose as one token — and because the recognizer runs
*before* the selector, that pattern matched `mathe2` and swallowed the `2`,
breaking candidate selection by number key for every word. Digits therefore end
a word. This is the one place where the "never trap me" goal and ordinary IME
selection genuinely conflict, and selection has to win.

---

## 7. Personal vocabulary

### Why not the native user dictionary

Rime's user dictionary learns `(code, text)` pairs emitted by a
dictionary-backed translator: `Memory::memorize` receives the `DictEntry`
objects behind the committed candidates. Spellless candidates are synthesised
in Lua and are not dictionary phrases, so there is nothing for it to record.

Making them dictionary phrases *is* possible — librime-lua exposes
`Memory(engine, schema, ns)` and `Phrase(memory, type, start, end, entry)` —
but it would mean shipping a compiled Rime dictionary purely as a backing store
for entries whose codes (`rcmmndtn` → `recommendation`) do not exist in it,
plus a `Memory` object per engine. That is a lot of machinery, and coupling to
a less-travelled corner of the Lua API, to store a word and a count.

So Spellless keeps its own store: `<rime user dir>/spellless_user.txt`, either
`word <TAB> count` or `word <TAB> how you write it <TAB> count`, rewritten
sorted by count. It is watched via `context.commit_notifier`, which fires
before the context is cleared, so `get_commit_text()` still holds the committed
word. The same format doubles as the hand-written supplemental vocabulary file
the brief asks for — drop words in it (count optional) and they are matched
immediately, no rebuild.

Three details that are easy to get wrong, and were:

* the committed text carries the automatic leading space, so `learn` trims
  before validating. Without that, nothing after the first word of a sentence
  was ever learned — which is to say, almost nothing;
* the middle column keeps the capitals. Storing only the lowercase key means
  `grthndck` can never give back `Grothendieck`, and personal vocabulary is
  precisely the mechanism that is supposed to supply missing names;
* but **not every capital is a preference**. Automatic capitalisation puts one
  on the first word of every sentence, and feeding that back through the
  learner taught the store that `the` is spelled `The` — permanently, in the
  middle of every later sentence, and written to disk. `worth_remembering`
  keeps a spelling only when the dictionary cannot already account for it: an
  inner capital, an acronym, or a word the corpus has never heard of. A plain
  lowercase commit clears one, so the store can be corrected by using it, and
  `repair_personal` drops any that an earlier version wrote.

### How it is used

Personal words are matched by a **linear pass over the whole list** rather than
through the indexes. That is deliberate: it means a word you have actually
chosen before is always in the running and cannot be squeezed out of a
frequency-ranked shortlist by commoner neighbours, and it makes a word the
static corpus has never heard of a candidate the moment it is committed once.
The list is capped at `personal_scan_limit` (400) so a long history cannot slow
the matcher down. The cap keeps the words chosen *most often*: the file is
written back sorted by descending count, so taking the tail of insertion order
would keep exactly the words you have used least.

A separate mechanism handles vocabulary you know about in advance:
`data/vocab/*.txt` is merged into the main dictionary at build time
(`data/vocab/math_sample.txt` is a sample, not something the algorithm knows
about).

---

## 8. Installation flow on Weasel

`scripts/install.py` writes only inside the Rime user directory:

```
<rime user dir>/
├── spellless.schema.yaml
├── lua/spellless.lua
├── lua/spellless/*.lua
├── spellless/            <- generated/ verbatim
└── default.custom.yaml   <- one entry appended, after a backup
```

Finding that directory: on Windows, the `RimeUserDir` value under
`HKCU\Software\Rime\Weasel` if Weasel has been pointed somewhere else,
otherwise `%APPDATA%\Rime`. Run from WSL it reads the same registry key through
`reg.exe`, asks `cmd.exe` for `%APPDATA%`, translates `C:\…` to `/mnt/c/…`, and
falls back to scanning `/mnt/*/Users/*/AppData/Roaming/Rime`. macOS and Linux
front ends are handled too. `--list-candidates` shows the reasoning.

Enabling the schema is the only edit to a file the user owns, and it uses
Rime's list-append operator:

```yaml
patch:
  "schema_list/+":
    - schema: spellless
```

Writing `schema_list:` instead would **replace** the list from `default.yaml`
and hide every other schema — a real hazard for anyone running a distribution
like rime-ice. The file is backed up first, only ever has lines inserted (so
comments survive), and if it already patches `schema_list` the installer prints
what to add instead of guessing.

---

## 9. Limitations found while building this

The ones a user meets in practice are summarised in `README.md`; this is the
full list, with the reason each one is where it is.

1. **Digits end a word.** The number keys select candidates, and Rime's
   recognizer runs *before* the selector — so any pattern that let `Lean4`
   compose as one token would swallow the `2` in `Mathe2` and break candidate
   selection after every capitalised word. Digits therefore commit the current
   word: type `Lean`, press Enter or a candidate key, then `4`. Underscores are
   fine (`foo_bar`), and so is a second capital (`TQFT2`, `ArXiv2`), because
   neither can be confused with prose. `spellless.schema.yaml` documents a
   looser one-capital pattern you can swap in if you write far more identifiers
   than prose. For a run of them, tap Shift.
2. **Rime cannot retract committed text**, so every spacing rule has to avoid
   writing a space rather than remove one. (`key_binder`'s `send:`
   re-processes a key inside the engine and drops it if nothing handles it — a
   synthetic Backspace never reaches the application.) Two consequences:
   *commit a word with the space bar or a number key and then type
   punctuation* gives `mathew .`, because the word's space was already
   written; and a run like `...` gives `. . .`. Typing the punctuation while
   the word is still being composed — the normal way — is right. So is
   deleting the odd stray space.

   The frontend is not bound by this, and the Spellless builds of Weasel and
   Squirrel lift it: `spellless/reclaim_space` is on, and punctuation takes
   that space back. See §5.6. On a stock install it stays inert -- not by
   configuration but because the schema never asks a frontend that has not
   shown it can answer.
3. **No space goes in front of opening punctuation**, so `Let $X$` needs the
   space after `Let` typed by hand. Adding one before `(`, `[` and `$` would
   turn `f(x)` into `f (x)`; the two are indistinguishable from inside the IME,
   so Spellless does not guess.
4. **No multi-word input.** One composition is one word. `mthmtcs s hrd`
   requires three commits. Rime's `octagram` (bundled) would give sentence
   context, but that needs a real dictionary-backed translator; see *Next*.
5. **The fuzzy channels do not compose.** Splitting is exact only:
   `exactlyright` gives `exactly right`, but a run-together that is *also*
   misspelled does not, since every part would need the full search at every
   split point. Shorthand has the same shape of limit — §4.4 requires every
   letter typed to appear in the word, in order, so a slip *inside* an
   abbreviation (`stfxctn` for `stratification`) drops back to the edit and
   skeleton channels, which cannot usually span that far. One missing
   capability, met twice: running a fuzzy search inside a fuzzy segmentation.
6. **Learning remembers the word, not the input that found it.** Selecting
   `recommendation` for `rcmmndtn` raises `recommendation` everywhere; it does
   not remember that *this* abbreviation meant *that* word. Storing the pair
   would be a small change to `userdb.lua` and is still the highest-value next
   step.
7. **Proper nouns from the corpus sit among short prefixes.** The frequency
   list is Google-Books-derived, so `mathe` offers `mathew` and `mathews`
   alongside `mathematics`. Better data, or a name-demotion pass at build time,
   would clear them out.
8. **First-letter errors are only partly covered.** The scan is anchored on the
   query's first *or second* letter, so `nirth`→`north` works but a query whose
   first letter is a wrong key and whose second is also wrong will miss.
   `spellless/scan_first_neighbours: true` widens this at roughly double the
   scan cost.
9. **Very short input is genuinely ambiguous** and the ranking does not
   pretend otherwise: `frm` offers `from`, `form`, `firm`, `farm`, `forum`,
   `frame` in frequency order. One and two characters go further and lead with
   the literal, so `cm` stays `cm`. A shorthand listed in `data/forms.txt` is
   the exception — `im` gives `I'm` — because someone wrote it down on purpose.
10. **Typing latency is Lua-bound.** About 2.5 ms per keystroke while typing an
    ordinary word, 9 ms at the 95th percentile across the whole evaluation set,
    with a ceiling on how many candidates are examined. It is comfortably
    interactive, but there is no headroom for, say, a 500k-word dictionary
    without a different index.
11. **On a stock Weasel, spacing and capitals are inferred.** Rime's commit
    history is a record of what the input method committed, not of the
    document: it is cleared on Return and Backspace, and a mouse click that
    moves the caret is invisible. So you will occasionally get a stray space or
    capital; Backspace re-syncs it, and `spellless/auto_space` /
    `spellless/auto_capitalize` turn either off. With
    [spellless-weasel](https://github.com/EricWay1024/spellless-weasel) this
    stops being guesswork — the frontend reads the text in front of the caret
    and hands it over. An abbreviation typed dot by dot is still
    indistinguishable from a full stop either way.
12. **Capitalisation comes from three places, none of them the corpus.** The
    frequency list is lowercase throughout, so capitals come from how you typed
    the word, from `data/forms.txt` and capitalised `data/vocab/` entries
    (`Grothendieck`, `TQFT`), or from what you have committed before. A name in
    none of those still comes out lowercase until you commit it once.
13. **The first composition after a deploy pays about 100 ms** to load the
    dictionary. Once per process, not once per word.

---

## 10. Next improvements, in order of expected impact

1. **Remember the input, not just the word.** Store `(typed, committed)` pairs
   in `spellless_user.txt` and score an exact match on the typed form highly.
   Every correction you make once becomes permanent. Contained change to
   `userdb.lua` and `rank.lua`.
2. **A better frequency list.** The Google-Books-derived corpus over-weights
   archaic words and proper nouns. Blending in a modern subtitle or web corpus,
   or demoting capitalised-in-corpus tokens at build time, would raise the
   top-1 rate more than any further weight tuning.
3. **Score against the previous word.** A bigram context would disambiguate the
   `frm`-class inputs where the remaining top-1 losses are concentrated.
   `librime-octagram` is bundled and could supply the model.
4. **Fuzzy splitting**, so `exctlyrght` finds `exactly right`, and a slip
   inside shorthand stops being fatal. Every part needs the full search at
   every split point, so it wants tight budgets and a gate.
5. **LaTeX context.** `\emph{co}homology` gains a space after the `}`, and
   `\cite{...}` arguments get prose spacing. Tracking control sequences and
   brace depth would fix a class of irritation for anyone writing maths.
6. **Recognised URLs and emails swallow trailing punctuation**, and commit
   without their own space.
7. **Learn the cost profile from data.** The edit weights came from coordinate
   descent over ~1000 cases; fitting them to a real keystroke log would do
   better, and `bench/tune.lua` already provides the loop.
8. **Incremental search.** Consecutive keystrokes re-search from scratch;
   restricting the next scan to the previous candidate set plus one edit would
   cut typical latency several-fold.
