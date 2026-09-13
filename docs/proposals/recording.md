# Recording what happens: an input log

A design, written 2026-09-13, for keeping a local record of what is typed into
Spellless and what Spellless does about it.

**Phase 1 is built** (§11); phases 2 to 4 are not. The point of writing the
whole thing down first was to settle what a record has to contain before
anything wrote one, because a log is the one feature you cannot fix
retrospectively: a field left out is a month of typing that does not have it.

    spellless/record: true          in spellless.custom.yaml, and nowhere else

Off by default, and §7 is what turning it on means.

---

## 0. The one-sentence version

Every composition already produces, inside this process, exactly the tuple the
benchmark is made of — *what you typed, what was offered, in what order, and
which one you took* — and at present every one of them is thrown away.

---

## 1. What this is for

Four uses, strongest first. The first one alone justifies the feature.

### 1.1 The project's own documents call this the missing piece

`docs/ALGORITHM.md` §2 lists the constraints the matcher was built under, and
one of them is not a constraint of the problem, it is an accident of never
having collected anything:

> **No training data.** There is no keystroke log. No corpus of (what a person
> typed, what they meant) exists for this task. Every weight was fitted on
> constructed cases.

§8.2 is blunter, after two rounds of making the scoring function more
principled:

> **What remains is the real one: there is still no data.** The weights are
> fitted on the same cases they are scored on, and while §5.1 now bounds the
> damage, bounding is not fixing.
>
> **Get real data.** A keystroke log of (what was typed, what was committed)
> turns this into ordinary learning-to-rank.

And `DESIGN.md` §10 has it as item 7 of what to do next:

> **Learn the cost profile from data.** The edit weights came from coordinate
> descent over ~1000 cases; fitting them to a real keystroke log would do
> better, and `bench/tune.lua` already provides the loop.

Three documents, one missing artefact, and it is the artefact this process
throws away several times a minute. Nine hundred of the cases the weights were
fitted on are *generated* — typos synthesised by rule, skeletons made by
deleting vowels programmatically. They are a model of a typist, and the model
was written by the same person who wrote the matcher, which is the oldest way
there is to be confidently wrong.

The fix is nearly free, because the format already exists.
`tests/cases/*.tsv` is

```
input <TAB> expected <TAB> max_rank [<TAB> group]
```

and a commit record (§3.1) contains all four columns. So

```
python3 scripts/analyse_log.py --to-cases tests/cases/personal.tsv
```

gives a case file of *your* typing, `make bench` scores the ranker against it,
and `lua bench/tune.lua --exclude personal` gives the honest held-out number
§5.1 says the project does not currently have.

The methodological caveat is real and is in §12.1: what you committed is partly
a product of what was offered first, so committed text is a weak label, and the
strong labels are the failures (§3.4) rather than the successes.

### 1.2 The shipped claims have never been checked in the wild

`README.md` says the word is first 89.8% of the time and in the top five
99.3%, ± 0.6 — on ten fresh draws of a synthetic test set. `EVALUATION.md`
gives latency against `bench/`: 2.9 ms mean, 2.2 ms median, 7.8 ms at p95.
`config.lua` asserts that two corrections make a reading lead, that a pause on
an unknown word is worth the keystroke it costs, that scanning the first
letter's keyboard neighbours is not worth 27% of the per-keystroke budget.

Each of those is a number this log measures directly, on the only test set that
matters, which is the document you are actually writing. §9 is the table of
which record answers which claim.

`ALGORITHM.md` §5.1 makes the sharper version of the point: every case in the
suite is a *transcription*, an input given and the answer known. Writing is not
that — "when you are composing, the spelling is the thing you do not have,
which is the entire reason this project exists". A log of real composition is
the only measurement of this software that is not a transcription test.

### 1.3 Finding what to delete

`4250885` removed the variant pause and the method that existed for it. That
decision was made by argument. The candidate `source` field — `exact`,
`split`, `coined`, `shortcut`, `capital`, `chosen`, `letter`, `raw` — says
which mechanism produced each committed word, so after a month the question
"does the affix builder ever actually win?" has a count instead of an opinion.
A mechanism that produced 0.02% of your commits and 300 lines of Lua is a
mechanism to delete, and this is how you find out.

### 1.4 The personal report

The thing you asked for, and the least important of the four, but the one you
will actually look at:

* net keystrokes saved, per day and per application;
* the words you most often get wrong, and what you type instead of them;
* the abbreviations you have invented without noticing — inputs you have typed
  forty times that always mean the same long word, which is a
  `spellless_shortcuts.txt` entry waiting to be written;
* words you committed literally because the dictionary does not have them,
  which is a personal vocabulary list waiting to be written;
* how often you gave up and tapped Shift.

---

## 2. The principle: record facts, derive stories offline

The Lua side records only what it observed, one line per event, with no
interpretation. Everything interesting — "this was a repair of that", "these
two inputs are the same word", "you saved 4.2 keystrokes a word" — is computed
afterwards by a Python script over the log.

Three reasons, and they all matter:

1. **The interesting analyses are the ones you have not thought of yet.** A
   repair detector written in Lua today fixes the definition of a repair
   forever; one written in Python over a raw log can be rewritten next month
   and re-run over the same six months of data.
2. **Cost.** Recording a fact is a table update and a buffered write. Linking a
   deletion to the commit it undoes means holding a window of state and
   comparing strings, inside a keystroke, against a 2.9 ms mean.
3. **It keeps the recorder honest.** A recorder that only appends cannot change
   what the input method does, and §8's invariant — *the log is read-only with
   respect to the running input method* — is the only reason the log can be
   used to evaluate it.

---

## 3. What to record

Five kinds of record. The first is the core and the fourth is the interesting
one.

### 3.1 The episode: one line per commit

One composition, from its first keystroke to the moment its text reached the
document. This is the unit that answers most of §9 on its own, because it is
the unit the product is measured in: a word.

| field | what | why it is there |
| --- | --- | --- |
| `ms` | milliseconds since the session header | wall clock without a clock read per record |
| `app` | `client_app` as the frontend reports it | everything differs between a thesis and a chat window, and the switchable features already key off it |
| `input` | the composition input, exactly | the first column of a case file |
| `text` | what was committed, trailing space stripped | the second column |
| `rank` | 1-based position of the committed candidate, `0` when it was not in the list at all | **the accuracy number**. A Return commit gets the position of the *raw* candidate rather than a zero, which is the honest answer; `how` is what says it was a refusal to choose |
| `source` | the candidate's `source` tag | §1.3 |
| `how` | `space`, `pick`, `return`, `arrow`, `punct`, `kp`, `soft`, `ascii` | which key ended it, which is not the same question as which candidate won |
| `keys` | key presses in this composition | the denominator of "keystrokes saved" |
| `bs` | backspaces inside the composition | in-composition repair (§3.4) |
| `maxlen` | longest the input ever got | with `#input`, says you backed up and retyped |
| `nav` | arrow and page keys used | going hunting is a cost even when it ends in the right word |
| `dur` | first keystroke to commit, ms | hesitation (§9) |
| `cands` | how many candidates were offered | |
| `work` | `scanned`/`checked`/`cues` from the existing `stats` table | free: `generate.lua` already counts them |
| `qms` | slowest single query in this composition, ms | catches the pathological query; see §8 on resolution |

Two subtleties that will otherwise cost a day each:

**Every commit route must produce exactly one record.** Commits arrive by two
completely separate paths. `Context::Commit` fires the commit notifier the
translator connects in `M.init` — that is the space bar, a number key, and
Return on a moved highlight. `env.engine:commit_text(...)` does **not** fire it
at all, which is precisely why `M.processor.func` calls `engine:learn(text)` by
hand at four separate sites: punctuation ending a word, Return carrying the
automatic space, Shift+Return and keypad Enter, and Control+Shift+A. A recorder
wired to only the notifier silently loses about half of everything, and loses
it non-uniformly — it would lose every word ended with a full stop.

Wire both, and make it a test (§11). While doing so it is worth folding those
four call sites into one `learn_committed(engine, context, text)` helper, which
is where the recording call then also goes, once.

**`rank` is knowable and nearly free.** The translator already memoises its
last answer in the one-entry `cache`, keyed on engine, input and the personal
store's change stamp. At commit time the input is unchanged and the memo holds
the list, so the rank and the source are a scan of at most `page_size` entries
over a list that is already in memory.

### 3.2 The candidate list, at commit

Optional, one line per commit, `record_candidates = 5` by default and `0` to
turn it off:

```
cands <TAB> input <TAB> text₁ score₁ source₁ ; text₂ score₂ source₂ ; ...
```

The episode says the answer was third. This says what the first two were, and
with what scores, which is the difference between knowing the ranker is wrong
and being able to fix it. It is the actual training signal for §1.1: coordinate
descent needs to know what it beat the right answer with, and `ALGORITHM.md`
§8.2's "pairs labelled by which channel was right" is exactly this line.

Only at commit, never per keystroke — one line per word, not per letter.

### 3.3 The keystroke stream

Opt-in, `record_keys = false`. One line per key press:

```
key <TAB> ms <TAB> class <TAB> code <TAB> composing
```

`class` is `letter`, `bs`, `space`, `digit`, `punct`, `nav`, `shift`, `other`.
It buys three things the episode cannot give you:

* **Inter-key timing**, so you can tell typing from thinking, and a pause
  before a selection key is a list that was not obvious even when it was right.
* **The input trajectory** inside a composition, exactly — `mthmt`, `mthmtc`,
  `mthmt`, `mthmtcs` — which is in-composition repair at full resolution.
* **What happens between words**, which is where post-commit repair lives.

It roughly doubles the log. Note honestly that it buys **no additional privacy
exposure** over §3.1: the episode already records `input` and `text` in full,
so the letters are on disk either way. The argument for leaving it off by
default is volume, not secrecy.

`M.absorb` is where it goes. That gear runs before the speller and is, as its
own comment says, "the only one that sees every key" — a letter is consumed by
the speller and never reaches `M.processor`.

### 3.4 The failure signals — the interesting half

Successes are cheap and slightly circular. The failures are the data nobody
has, and each of these is one unambiguous line:

| record | when | what it means |
| --- | --- | --- |
| `del` | Backspace with nothing composing, and the `word_backspace` double-tap firing | the raw material of post-commit repair |
| `forget` | Control+Shift+D, Control+Delete, or `qqd` | **"you got this wrong"**, stated deliberately by a human. The cleanest label in the whole log, and the rarest |
| `suppress` | a word pushed onto the never-offer list | the dictionary is wrong about you, specifically |
| `bail` | `ascii_mode` changed at all: a Shift tap, Control+Shift+A, an F4 switch, a `$`, an application the frontend puts there | **"I give up, let me type it myself"** — the single best one-number summary of whether the thing is working. Recorded by *sampling the mode* rather than by watching for the keys that change it, because Shift held for a capital and Shift tapped to escape are the same two events in the same order |
| `bail delim-on` | the same transition, where `DELIMITER` says a `$` caused it | not a bail-out at all: it is maths, and it was asked for. Separated where the answer is still known rather than guessed apart afterwards, so the `bail` number above stays worth trusting — and it already measures how much of a thesis the matcher is switched off for |
| `ask` | the `confirm_literal` pause fired, and whether the second space followed or you changed your mind | measures a feature that costs a keystroke every time it is right |
| `abandon` | composition cleared without committing | the word you could not get at all |
| `magic` | `qqc`/`qqf`/`qql` | the capital was inferred wrongly, and you said so |

**Post-commit repair is derived, not recorded.** That is the §2 principle at
work. Given the commit stream and the `del` stream, the analysis defines: a
commit A, then deletions with no commit in between, then a commit B within some
window, where A's and B's inputs are close. Three outcomes, and they mean
different things:

* `B.input == A.input`, `B.text ≠ A.text` — **the ranking was wrong and you
  re-picked.** This is the strong label §1.1 needs, and the log lets you check
  whether the `> typed <TAB> chosen` rows actually stopped it happening a third
  time.
* `B.input ≠ A.input` — **you retyped it differently.** Which of your
  approximate spellings work, measured, which is the input `cue.lua`'s
  keep/drop probabilities have never had. `ALGORITHM.md` §4.5 already counted
  three of that channel's numbers from known pairs rather than choosing them;
  this is where the rest of the pairs come from.
* `B.text == A.text` — you deleted for some other reason. Discard.

Writing that detector in Lua would fix those three definitions forever. Writing
it in Python means the fourth case, discovered in November, is a re-run.

### 3.5 The session header

One header line per process start, and this is not optional bookkeeping — it is
what stops six months of log silently mixing three different tunings:

```
session <TAB> unix_seconds <TAB> spellless_version <TAB> build_sha <TAB> config_digest <TAB> schema <TAB> app
```

`build_sha` from `generated/spellless.build.json`, which already records the
sources, their SHA-256 sums and the parameters that produced the dictionary;
`config_digest` a hash of the resolved `cfg` table, so a log line can always be
traced to the weights that produced it. Without these the log is
uninterpretable the first time you change a weight, which will be the week
after it is switched on.

Phase 2 adds an `app` record whenever `client_app` changes, which is cheap —
one string compare against the last one — and which is what makes the
per-context half of §9 cost nothing to answer. Until then every record carries
its own `app`, so the question is answerable already; the record only saves
repeating it.

---

## 4. What is deliberately not recorded

* **The surrounding document.** `document_tail` can read the text around the
  caret on the forked frontends. That is somebody's entire paragraph, and it is
  not needed for a single question in §9. The commit and the input are.
* **Anything typed in ASCII mode.** Inside `$…$`, and after a Shift tap, the
  matcher is not running and there are no compositions — so the log simply has
  a gap there, marked at both ends by `delim` or `bail`. That gap is
  informative (§9) and it is not a hole to be filled: filling it would mean
  recording raw keys with no composition around them, which is a keylogger in
  the sense this document is otherwise careful not to be.
* **Anything outside the input method.** Rime sees keys routed to it. Keys in a
  password field, in a game, in another keyboard layout are not ours, and
  nothing here goes looking for them.
* **Anything that leaves the machine.** §7.

---

## 5. The format

Tab-separated lines, one record per line, `kind` in the first column. Not JSON.

The reason is the one this project keeps arriving at: `spellless_user.txt` is a
tab-separated file with a leading `>` or `-` to mark the line kind, and it is
hand-editable on purpose — "Edit freely", says the header it writes. A log in
the same shape can be read with `grep`, counted with `sort | uniq -c`, and
edited with a text editor when you want a sentence gone. A correct JSON
*writer* — escaping, UTF-8, surrogate pairs — is real work to do inside a
keystroke, for no gain over a format the project already uses twice.

Tabs inside a field cannot happen for `input` (letters only) and are escaped as
`\t` for `text`. A field is never empty; `-` is the empty value, so a
mis-parsed line is visible rather than silently short.

**SQLite is the analysis's business, not the recorder's.** `scripts/` already
does the heavy lifting in Python — the dictionary, the indexes, the test set.
`scripts/analyse_log.py` loads the text log into SQLite (stdlib, no
dependency), and then the whole of §9 is a query. The Lua stays a thing that
appends lines.

---

## 6. Where it lives

```
<rime user dir>/spellless_log.tsv      and  spellless_log.tsv.1
```

Next to `spellless_user.txt`, and resolved against
`rime_api.get_user_data_dir()` the same way, never against a path in the
configuration. Two frontends run side by side out of `%APPDATA%\Rime` and
`%APPDATA%\Spellless` (`docs/DEPLOYING.md`), and a configured path would
sooner or later be written by both.

One file, rotated by size, keeping one older file beside it. A file per day
reads better and cannot be had: `io.open` will not create a directory, Lua has
no mkdir, and `os.execute("mkdir")` flashes a console window out of the IME
process on Windows. Nothing is lost — the day boundary is in the data, in the
session headers and the `ms` offsets, and `analyse_log.py` splits on it.
`--gzip` compresses the rotated file; Lua cannot compress without a dependency,
Python can, and there is no hurry.

Volume, on a heavy day of about 5,000 words and 30,000 keys: roughly 600 kB of
episodes, 750 kB of candidate lists, 750 kB of keystrokes. Call it 1–2 MB a
day, 50 MB a month, a few MB a month once gzipped. `record_max_bytes` defaults
to 32 MB, which is about two months of heavy writing per file and four across
the pair — long enough to fit weights on, short enough to stay a diagnostic
rather than an archive.

---

## 7. Privacy: this is a keylogger, and the document should say so

Every word you type, in every application, with timestamps, in a plain text
file. That is not a side effect of the design, it *is* the design — §1.1 needs
the words. So:

1. **Off by default.** `record = false` ships false and the file is never
   created. Every machine that installs Spellless and never reads this document
   records nothing, ever.
2. **Local only, and no network code anywhere near it.** `ALGORITHM.md` §2
   lists "no network" among the dependencies this project does not have, and
   this feature does not change that.
3. **An allowlist, not a blocklist**, when you do turn it on: `record_apps =
   "code.exe"` records your thesis and nothing else. It reuses `app_allows`,
   which `snippet_apps` and `delimiter_apps` already go through. A blocklist is
   a promise you have to keep updating; an allowlist fails closed.
4. **A redacted mode.** `record_words = false` keeps every field in §3.1 except
   `input`, `text` and the candidate list, replacing them with lengths and
   character classes. That kills §1.1 entirely and keeps §1.2 and §1.4 intact,
   which is a reasonable trade for someone who wants the report and not their
   prose on disk.
5. **Visible.** `zzver` gains a last line: whether a recorder is running, how
   many records it has written, and where. A recorder you cannot see from
   inside the thing being recorded is a recorder you will forget is on — and
   one more line on a diagnostic that already exists is the right amount of
   surface for that, where a second magic word would have been a second thing
   to keep out of the personal store. The line appears only when recording is
   on; "recording off" on every machine that never turned it on is noise.
6. **Erasable.** It is a text file: open it and delete a line.
   `analyse_log.py --purge-before DATE` and `--forget WORD` for the rest.

---

## 8. Cost, and the one invariant

**The recorder must never raise, never block, and never change what the input
method does.** This runs inside a keystroke, on somebody's real work, in a
process that has no way to show an error.

Concretely:

* **No `io.open` per keystroke.** The whole of matching runs in 2.9 ms mean and
  7.8 ms at p95 (`EVALUATION.md`), and `config.lua` rejects a recall feature
  worth 96 points of reachability because it costs 27% of that. A file open per
  keystroke is not in the same budget conversation. Records are formatted into
  a buffer and appended through a handle held open in append mode, flushed on
  the existing `flush_every` / `flush_interval_ms` policy and on `fini`.
* **A failed write is a dropped record, not a lost keystroke.** Every file
  operation is wrapped; a full disk, a locked file or a deleted directory turns
  recording off for the session and says so once through `log.error`.
* **Per-composition state goes in the context property map**, encoded as one
  short string, exactly as `SENTENCE`, `BACKSPACE`, `LITERAL`, `RESUMED` and
  `HIGHLIGHT` already do. Not in a module-level table: `absorb`, the processor
  and the translator get separate `env` tables and share only the context, and
  two windows typed in alternately would interleave their counters into each
  other's episodes. This is the same hazard `userdb.lua`'s cache comment is
  about — "whichever flushed last would silently drop what the other had
  learned" — and the property map is the shape this project already solved it
  in.
* **One recorder per file, shared across engines**, for that same reason:
  `UserDB.load`'s memo table is the pattern to copy.
* **Timing resolution.** `rime_api.get_time_ms` is the clock `acquire` already
  passes in, and 1 ms is coarse against a 2.2 ms median. So `qms` is not for
  measuring the distribution — `bench/` does that properly, with `os.clock` and
  repeated runs — it is for catching the query that took 40 ms on a busy
  machine, which 1 ms resolution catches perfectly well.

---

## 9. The questions, and the claims they test

| question | records | what it tests |
| --- | --- | --- |
| Live top-1 and top-5 | `rank` | README's 89.8 / 99.3, on real typing rather than a synthetic draw |
| Net keystrokes saved | `keys` vs `#text` | the premise of the whole project, net of the keys spent choosing — which the marketing number never is |
| My commonest mistakes | rank ≥ 2 commits, and derived repairs | a personal typo table, and the input to `data/vocab/shorthand.txt` |
| Abbreviations I already have | repeated `input`→`text` pairs | shortcut file entries you have not written yet |
| Which mechanism earns its keep | `source` distribution | §1.3 — what to delete |
| Most used shortcut | `source=shortcut` | |
| Does the literal pause pay | `ask`, and whether the second space followed | a feature that costs one keystroke every time it is right |
| Does learning work | `rank` against occurrence index for a repeated input | `choice_confirm_count = 2` — does a reading that led once keep leading |
| Words the dictionary lacks | `source=raw` commits | a vocabulary list, written by your typing |
| Am I bailing out | `bail` per 1,000 words | the health metric |
| How much is maths | `delim`, and the gap between the pair | how much of a thesis this software is switched off for — and therefore what a maths vocabulary would be worth |
| Does the application matter | everything, split by `app` | whether `reclaim_space`, `word_backspace` and friends are on in the places that need them |
| Hesitation | `dur` minus typing time from the key stream | a list that is right but not obvious is not free |
| Is latency ever pathological | `qms`, `work` | `EVALUATION.md`'s p95, in the wild rather than on `bench/` |
| Better weights | `cands` lines | §1.1 |

---

## 10. The analysis side

```
scripts/analyse_log.py                        # the report
scripts/analyse_log.py --days 7               # the last week of it
scripts/analyse_log.py --repairs              # what was deleted and typed again
scripts/analyse_log.py --to-cases tests/cases/personal.tsv
scripts/analyse_log.py --to-cases FILE --strong-only
scripts/analyse_log.py --sqlite log.db        # the whole thing as a database
scripts/analyse_log.py --purge-before 2026-07-01
scripts/analyse_log.py --gzip
```

Standard library only, like the rest of `scripts/`; it finds the Rime user
directory with `install.py`'s own `resolve_user_dir`, so it works from WSL
against the Windows-side installation without being told where anything is. The
SQLite database is a build artefact — derived from the log, deletable, rebuilt
in seconds — which is why it is an option rather than the store.

---

## 11. Phases

| | what | why in this order |
| --- | --- | --- |
| **1** ✅ | session header, episodes, `del`, `bail` (including `delim-*`), `forget`; the four `engine:learn` call sites folded into `learn_committed`; `analyse_log.py` with the report, `--repairs` and `--to-cases` | this is already §1.1, §1.2 and most of §1.4 |
| **2** | candidate lists, `ask`, `abandon`, `magic`, the `app` record | completes the tuning input and the feature-level questions |
| **3** | the keystroke stream, and the repair detector run over it rather than over `del` alone | the timing questions, and the highest-resolution version of the thing you most want to see |
| **4** | `record_words = false`, gzip on a schedule | the parts that only matter once there is a lot of data |

What phase 1 came to:

| | |
| --- | --- |
| `rime/lua/spellless/record.lua` | the writer: encoding, the buffer, rotation, the config digest |
| `rime/lua/spellless/config.lua` | six settings, all off or unused until `record` is true |
| `rime/lua/spellless.lua` | the counters in `absorb`, the mode watcher in `handover`, `record_commit` and `learn_committed`, and the session header in `M.init` |
| `rime/lua/spellless/engine.lua` | the recorder's lifetime, and the `zzver` line |
| `scripts/analyse_log.py` | the reader: the report, the repair detector, `--to-cases` |
| `tests/test_record.lua` | eleven suites, 53 assertions |

The tests use the existing `tests/rime_mock.lua`, which already exercises
`rime/lua/spellless.lua` itself: every commit route produces exactly one
episode and no route produces two; an unwritable path never raises and never
swallows a key; `record = false` creates no file; and a fixed key sequence
commits the same text with recording on and off, which is §8's invariant made
executable.

---

## 12. Where this could go wrong

### 12.1 Committed text is a weak label

You commit what was offered first partly *because* it was offered first. A case
file built from rank-1 space-bar commits therefore tells the tuner to keep
doing what it already does, and a ranker fitted to it would be fitted to its
own output — which is the same circularity `ALGORITHM.md` §5.1 already warns
about, arrived at from the other side. The honest treatment:

* rank-1 commits taken with the space bar are **weak** evidence — "at speed
  nobody reads the list", as the `absorb` gear puts it where it explains why
  only a number key is counted as a deliberate pick;
* rank ≥ 2 commits taken with a number key are **strong** — you looked, and
  disagreed;
* derived repairs and `forget` records are **strongest** — you said so twice.

`--to-cases` writes the evidence class into the `group` column the harness
already breaks its results down by, so `make bench` scores the two separately
without anything else having to change, and `--strong-only` keeps just the
rows you read the list for. The file says how it was made in a comment at the
top: a case file that does not is one that will be trusted for the wrong reason
in March.

It also drops a capital it did not have to earn. Sentence-initial
capitalisation is applied by this software, so recording "But" as what a
lowercase `but` meant and then fitting weights on it teaches the ranker its own
output — the trap `Engine:learn_choice` already guards the personal store
against, with the same rule, lowering only a plain Title Case word so that
`CLI` and `TQFT` keep their capitals.

### 12.2 One user is one user

Every number this produces is about one person typing mathematics. That is the
right population for tuning *your* weights and the wrong one for shipping a
default. The two must not be confused, and the shipped `config.lua` defaults
should go on being fitted to `tests/cases/` — with `personal.tsv` as held-out
evidence that the defaults generalise, which is more valuable than using it as
training data anyway.

### 12.3 The observer effect on you, not the code

Knowing the log exists changes how you type — you will start noticing bail-outs
and avoiding them. Worth remembering when the first week's numbers look better
than the second's.

### 12.4 The log must not become an input

The temptation, once there is a log, is to feed it back: promote words you type
often, tune weights automatically. That is a different feature with a different
risk profile, and it destroys the evaluation — a log that changed the behaviour
cannot measure the behaviour. §8's invariant is a hard line for v1.

---

## 13. If the editor bridge lands

`proposals/vscode-typst-profile` adds `spellless/editor.lua` and
`spellless/profile.lua`: the editor says which of a `.typ` file's three
languages the caret is in, and which vocabulary profiles apply. Nothing in this
document depends on that branch, and it should be built on `main` without it.

But two things are worth reserving now, because both are free today and
expensive to retrofit:

* **A `ctx` column in the episode**, written as `-` until there is a bridge to
  fill it, and holding `mode` plus the active profile names afterwards. A
  column added later means the analysis has to handle two record shapes for
  ever.
* **`delim` distinguishing who opened the run** — a `$` you typed from one the
  editor reported. On `main` it is always the former, so the field is a
  constant; it stops being one the day the bridge lands.

With those two fields present, the bridge turns §9 into a genuine A/B on one
user with no switch to flip: the same person, the same prose, `rank` split by
whether a profile was active. That is the cleanest evidence the profile feature
is ever going to get, and it only exists if the log predates it.
