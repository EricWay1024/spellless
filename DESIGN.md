# Design

> Treat spelling as a noisy encoding of intended English, and use an IME
> candidate interface to decode the intention.

Spellless is a Rime schema plus one Lua translator. It does not fork Weasel or
librime, does not ship a compiled plugin, and does not need administrator
rights. Everything Rime already does well — composition, candidate selection,
paging, punctuation, committing raw text — is left to Rime; the only custom
part is deciding *which words to offer and in what order*.

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
   +-- ascii_composer   Caps Lock / ASCII mode                     [Rime]
   +-- recognizer       "sqlite3", "foo_bar", urls, emails         [Rime]
   +-- speller          builds the composition, a-z A-Z '          [Rime]
   +-- punctuator       , . ! ?                                    [Rime]
   +-- selector         number keys, paging                        [Rime]
   +-- spellless        Enter, when a leading space is due     [Spellless]
   +-- express_editor   Space = confirm, Enter = commit raw input  [Rime]
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
| `spellless.words` | 754 kB | 82,880 words, newline separated, **most frequent first**. A word's id is its 1-based line number. |
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

### 4.4 Keeping it interactive

Measuring edit distance against 83k words per keystroke is not affordable in
interpreted Lua (about 5 µs per comparison). Three things bring it down to
around 2 ms:

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

## 4.5 Words the corpus cannot spell

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

### 5.6 Reclaiming the space: the one thing Rime cannot do

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

On the Lua side this is `reclaim_space`, and it is **off by default** — on
stock Weasel the `U+0008` would be typed in literally. `preceding.hugs_previous`
decides which marks earn it: sentence punctuation and closing brackets, and
deliberately not the paired marks, because with the space stripped `he said "`
and `"no." ` are indistinguishable from behind.

`commit_tail` resolves the backspaces when it reads the history back, so
everything downstream — spacing, capitalisation — sees the text the commit
produced rather than the request that produced it.

This is the whole dependency on the fork. Everything else in Spellless runs on
stock Weasel, which is why the two are installed side by side rather than one
replacing the other: fresh TSF GUIDs, its own named pipe, its own registry key
and its own user directory, so the Chinese input method already installed is
untouched.

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
abbreviation typed dot by dot. Backspace re-syncs the first. The second is why
`data/forms.txt` maps `eg` → `e.g.` and `ie` → `i.e.`: `.` is not in the
speller's alphabet, so typing it would end the composition anyway, and
committing the abbreviation as one candidate means the whole of it is there to
recognise. `Corpus.abbreviations` collects every form ending in a full stop,
and `ends_sentence` consults it first.

### Enter, and what the processor actually owns

Enter needs no special handling: `express_editor` commits the raw input, which
fires the commit notifier, which learns it. It commits the input literally, so
no trailing space — Enter is the "exactly what I typed" escape and stays that
way. An earlier version intercepted Return to prepend a space, which then had
to be careful not to swallow Shift+Return (the soft newline in Slack and
Zulip); that whole branch is gone.

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

And, independently of both, `Enter` commits the raw input natively (§2).

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

See `README.md` § Limitations.
