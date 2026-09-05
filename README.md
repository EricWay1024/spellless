# Spellless

**Stop spelling. Start writing.**

![Typing "cmplctd" and being offered "complicated"](docs/spellless.jpg)

You know the word. You have always known the word. What you cannot reliably do
at the speed you think is get its letters into the right order — and English
charges you for that, hour after hour, and gives you nothing back.

Spellless takes your approximate spelling and offers you the word you meant.
Drop the vowels. Get the letters out of order. Run two words together. Then
glance, pick, and keep going.

```
recieve          →  receive              teh            →  the
recommnedation   →  recommendation       cmplctd        →  complicated
mthmtcs          →  mathematics          dffmrphsm      →  diffeomorphism
strtfctn         →  stratification       grthndck       →  Grothendieck
exactlyright     →  exactly right        thisday        →  this day
mther's          →  mother's             mthers'        →  mothers'
bc               →  because              im             →  I'm
```

**Nothing is ever corrected behind your back.** The list appears, you choose,
and `Enter` always commits exactly what you typed. It never quietly decides you
meant something else — because the one thing worse than mistyping a word is a
machine mistyping it for you, confidently, while you look away.

## Why this should exist

Chinese input methods solved a version of this decades ago. You type an
approximation, the IME shows you candidates, you pick one. Hundreds of millions
of people write that way every day and nobody finds it remarkable.

English never got the same treatment, because typing English assumes you can
spell it. So spelling stays a tax on thinking — a hundred small stumbles an
hour, each one pulling your attention off the sentence and onto the keyboard.

Spellless treats what you typed as **a noisy encoding of a word you already
know**, and decodes it:

* **A transposition is nearly free.** `teh` is `the`. Your fingers arrived out
  of order, which says almost nothing about what you meant.
* **Vowels are cheap. Consonants carry the word.** `mthmtcs` is `mathematics`
  and `dffmrphsm` is `diffeomorphism`.
* **Everything competes on one score** — frequency, edit cost, how much a
  completion adds, what you have chosen before — so a common word reached by a
  cheap slip can beat a rare exact prefix.

### Why not autocorrect?

Autocorrect has to choose. One guess, no way to say *I am not sure*, applied to
text you have already written. When it is right you never notice; when it is
wrong you often do not either, and you find out when a reader does. The
keystroke it saved was never the expensive part — the expensive part is no
longer trusting the sentence without re-reading it. A candidate list is not a
smaller version of that. It is the opposite arrangement: the machine proposes,
you dispose, nothing lands that you did not choose.

That also makes far more ambition affordable. Autocorrect can only risk a
near-miss of an edit or two, because every guess is applied unseen. Offering
`mathematics` for `mthmtcs` means allowing a distance at which half the
dictionary is reachable — unthinkable if a machine must pick, perfectly safe
when a human is looking at seven options. And it never fights you over
`kubectl`, `argmax` or a name it has not met: what you typed is always on the
list, and `Enter` always commits it verbatim.

Look again at the screenshot. `complicated` is first, and `completed`,
`complicate`, `compacted`, `complicity` are the words a reasonable reader might
have suspected. That is a ranking, not a lookup: nothing under `rime/lua/`
knows any of those words. They fall out of a weighted edit distance, a
consonant-skeleton index and one ranking function. See [DESIGN.md](DESIGN.md).

## What it feels like

You stop proofreading mid-sentence. Spaces appear between words and never in
front of a comma, sentences start with a capital, `eg` becomes `e.g.` and `i`
becomes `I`. A colleague's name is remembered after you type it once. A word
Spellless has never seen will not go in on one press of the space bar — it
takes two, because the moment worth interrupting you is the moment you were
about to be wrong. And when it does get something wrong, one key makes it
forget.

```
mathe            →  mathematics · mathematical · mathematician …
dont             →  don't          its       →  its · it's
youre            →  you're         id        →  id · I'd
noether's        →  Noether's      psdfnctr  →  pseudofunctor
```

**The word you meant is first 88.3% of the time, and on the first page 98.4%.**
About 2 ms per keystroke over 83,095 words. 1844 assertions say it still
behaves. [EVALUATION.md](EVALUATION.md) has the numbers, including the cases it
gets wrong and why.

---

## The other half: [spellless-weasel](https://github.com/EricWay1024/spellless-weasel)

Everything above works on a stock [Weasel](https://github.com/rime/weasel).
Three features do not, because no schema can reach them — they need the
frontend, so there is a companion repository:

**[EricWay1024/spellless-weasel](https://github.com/EricWay1024/spellless-weasel)**
— Weasel, rebuilt to install *beside* the one you already have.

| | |
| --- | --- |
| punctuation takes its space back | `you` space `.` gives `you. `, not `you . ` |
| a word being re-typed is picked up | delete the space after `so`, type `oner`, get `sooner` |
| Backspace twice | deletes the whole word |

All three exist because Rime cannot see or retract what it has committed: a
commit is a string, and once it has left the input method the text belongs to
the application. The frontend is on the other side of that line. It holds a TSF
range, so it can read the few characters in front of the caret and hand them
over, and it can take a character back. That fork adds one convention and
nothing else.

It installs alongside your existing Weasel — its own GUIDs, pipe, registry key
and user directory — so a Chinese input method already on the machine carries
on untouched. It is GPL-3.0, like Weasel. This repository is MIT.

---

## Requirements

* **Windows 11 with [Weasel](https://github.com/rime/weasel) 0.16 or newer.**
  Lua support is already there: official librime release builds bundle
  `librime-lua`, and Weasel ships those builds. Nothing to install, no plugin
  to compile, no administrator rights.
* **Python 3.8+** to run the installer (and only for that). No third-party
  packages; PyYAML is used if present, to double-check an edit before it is
  written, and skipped if not.

### What has and has not been verified

The matcher, the ranking and the Rime adapter are exercised by 1844 assertions
under a real Lua 5.4 (`make test`), including `tests/test_adapter.lua`, which
drives `rime/lua/spellless.lua` against a stand-in for librime-lua built from
its actual API (`tests/rime_mock.lua`). The schema and the librime behaviour it
relies on — `express_editor` binding Return to *commit raw input*, the
`recognizer` accepting characters outside the speller's alphabet, `"schema_list/+"`
appending rather than replacing — were checked against librime's source, and
the installer's directory detection was dry-run against a live Weasel 0.17.4 /
librime 1.13.1 install with rime-ice.

What has **not** happened is a keystroke going through Weasel itself: that
needs a Windows session. If something misbehaves on first deploy, the candidate
comments (`spellless/show_debug_comments: true`) and `%APPDATA%\Rime\rime.log`
are the two places to look.

---

## Install

This installs into your Rime user directory and touches nothing else. It works
on a stock Weasel; the three features that need
[spellless-weasel](https://github.com/EricWay1024/spellless-weasel) stay off
until you have it.

From Windows:

```powershell
python scripts\install.py
```

From WSL (the installer finds the Windows-side directory itself):

```bash
python3 scripts/install.py
```

Then:

1. Right-click the Weasel tray icon → **Deploy** (「重新部署」).
2. Press <kbd>F4</kbd> (or <kbd>Ctrl</kbd>+<kbd>`</kbd>) and choose
   **Spellless**.

Useful flags:

| Flag | |
| --- | --- |
| `--dry-run` | print every action, change nothing |
| `--list-candidates` | show which Rime user directories were considered, and why |
| `--user-dir DIR` | install somewhere specific |
| `--no-enable` | copy the files but leave `default.custom.yaml` alone |
| `--uninstall` | remove the files this script wrote |

The installer only ever writes inside your Rime user directory. It appends one
entry to `default.custom.yaml` using Rime's list-append operator
(`"schema_list/+"`), which **adds** to the schema list from `default.yaml`
rather than replacing it — important if you run a distribution like rime-ice.
The file is backed up first, only ever has lines inserted so your comments
survive, and if it already patches `schema_list` the installer prints what to
add rather than guessing.

### The files it deploys

```
<rime user dir>/
├── spellless.schema.yaml
├── lua/spellless.lua
├── lua/spellless/{config,corpus,distance,engine,generate,rank,skeleton,userdb,util}.lua
└── spellless/{spellless.words,spellless.weights,spellless.alpha,spellless.skel,spellless.build.json}
```

Nothing else is touched. In particular `rime.lua` is never written: only one
`rime.lua` is ever loaded, so overwriting it would break other Lua schemas.

---

## Using it

| Key | |
| --- | --- |
| <kbd>1</kbd>…<kbd>7</kbd> | select a candidate |
| <kbd>Space</kbd> | commit the highlighted candidate — twice, if it is a word the dictionary does not have |
| <kbd>Enter</kbd> | **commit exactly what you typed**, at once |
| <kbd>Esc</kbd> | cancel the composition |
| <kbd>PgUp</kbd> / <kbd>PgDn</kbd> | page through candidates |
| <kbd>Shift</kbd> (tapped on its own) | leave Spellless and type straight through; tap again to come back |
| <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>A</kbd> | the same, deliberately — also commits the word first |
| <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>D</kbd> or <kbd>Shift</kbd>+<kbd>Del</kbd> | forget the highlighted candidate |
| <kbd>F4</kbd> | schema menu |

Punctuation keys are punctuation. Rime's preset binds `,` `.` `-` `=` to
paging; this schema does not, because they are a comma and a full stop.

**Tap Shift to get out of the way.** It switches to plain typing, and tapping it
again switches back — the tray icon shows which mode you are in. Tapped
mid-word it commits exactly what you had typed, literally, and then switches,
so it doubles as the escape hatch when a word is clearly not going to be found.
That is the answer for LaTeX, shell commands and anything with digits in it:
`\citep{Hat02}` is a Shift tap away, rather than something the matcher has to
be taught.

This is safe while typing capitals. librime only toggles on a *bare*
press-and-release: any other key in between cancels it, and it must be released
within 500 ms, so <kbd>Shift</kbd>+<kbd>M</kbd> can never flip the mode. If you
still manage to trip it, set `Shift_L`/`Shift_R` to `noop` in
`spellless.schema.yaml`.

**Spaces are automatic**, and they ride on the word: whichever key commits it —
space bar, a number — puts the space in too. Typing punctuation instead ends
the word *without* its space and puts one after the punctuation, so

```
hello  wrold.     →  Hello world.
you.   thats      →  You. That's
```

Nothing ever has to be un-typed. Turn it off with
`spellless/auto_space: false`.

**Sentences start with a capital.** After `.`, `!`, `?`, on a new line, and at
the start of an empty text box, candidates lead with a capital — but only if
you typed the word in lower case, so `MATHE` and `kubectl` are left alone. Turn
it off with `spellless/auto_capitalize: false`.

**Dropped apostrophes are treated as typography, not spelling**, so `dont`
gives `don't`, `youre` gives `you're`, and `its` gives `its` first with `it's`
right behind it. A bare `i` gives `I`, and `eg` gives `e.g.` — the dots would
otherwise end the composition, and committing the abbreviation whole is also
what stops it being mistaken for the end of a sentence. Add your own in
`data/forms.txt`.

**Short and capitalised input leads with itself.** `x`, `f`, `cm`, `ms`, `CW`,
`PDE`, `TQFT` commit as themselves, because one or two characters are variables
and units far more often than the start of a longer word, and typing an acronym
in capitals is deliberate. A real word still means itself (`i`, `an`, `eg`), and
a one-letter completion of a short stem is still trusted (`th` → `the`).

**The literal text you typed is always on the first page** — in slot 7 by
default, or first when nothing plausible was found, so pressing space on
`kubectl` or `argmax` cannot turn it into an English word.

**Capitals work.** `Mathe` gives `Mathematics`, `RECIEVE` gives `RECEIVE`.

**snake_case identifiers** (`foo_bar`, `max_iter2`) are taken literally as soon
as the underscore appears. Digits are *not* treated that way, because the
number keys select candidates — see Limitations.

---

## Your own vocabulary

Two ways, and you probably want both.

**Learned automatically.** Every word you commit is counted in
`<rime user dir>/spellless_user.txt`, and words you pick often rise. It stores
*how* you wrote a word only when the dictionary cannot already explain it —
`MacLane`, `TQFT`, a surname — so a capital that came from the start of a
sentence is never mistaken for a preference. Committing the plain lowercase
form takes a stored spelling back. A word the
dictionary has never heard of becomes a candidate as soon as you commit it
once — commit `Grothendieck` by pressing Enter, and afterwards `grthndck` gives
it back, capitals and all. This is the answer for tool and package names:
commit `pytest` once and `pytst` finds it thereafter.

**Written by hand.** That same file is plain text and safe to edit:

```
# word <TAB> count
# word <TAB> how you write it <TAB> count
perverse	5
grothendieck	Grothendieck	12
Hausdorff
```

A one-column entry written with capitals is its own spelling, so `Hausdorff`
above needs no second column.

For a larger, permanent vocabulary, add a `.txt` file to `data/vocab/` and
rebuild — this puts the words in the main dictionary with a real corpus
frequency rather than in your personal history. An entry written with capitals
(`Grothendieck`, `TQFT`) is indexed lowercase and remembers its spelling, so
only write capitals where the lowercase form would be wrong.
`data/vocab/math_sample.txt` ships around 300 words of pure mathematics and its
working vocabulary; it is a sample, not something the matcher knows about.

---

## Capitals, place names and phrases

`English`, `Mexico`, `Thursday`, `Oxford`, `Eric` — words only ever written
with a capital — live in `data/vocab/proper_nouns.txt` and
`data/vocab/given_names.txt`, and commit that way however you type them. The
bar for adding one is that the lowercase spelling is wrong in *every* context,
which is why `March`, `May`, `Polish`, `Bill` and `Grace` are deliberately
absent.

`data/vocab/phrases.txt` holds groups that behave as one word:

```
infrontof  ->  in front of        hongkong       ->  Hong Kong
eachother  ->  each other         withrespectto  ->  with respect to
```

The key is the letters alone, and the entry commits as written, spaces
included. They are ordinary dictionary entries, so `hngkng` finds `Hong Kong`
too. Typing the words separately still works.

Both files rebuild the dictionary with `make`. A file may open with `#!rank N`
to say how common its words are.

---

## Words run together

```
exactlyright      ->  exactly right
helloworld        ->  hello world
iamgoingtoschool  ->  I am going to school
asamatteroffact   ->  as a matter of fact
```

Any number of words, not just two — cutting a string into dictionary words is a
word-break search, so the count falls out of it. Each part keeps its own
spelling, hence the capital `I`.

A word is never split (`another` is not `a not her`), and a split is placed
rather than ranked: last among the real candidates, so it can neither displace
a correction nor be crowded out by a mediocre one. `spellless` and `argmax`
keep the first slot; `this day` is there when you want it.

Not done: a run-together that is *also* misspelled, so `exctlyrght` would find
`exactly right`.

---

## Possessives

```
mther's  ->  mother's        mthers'   ->  mothers'
milnor's ->  Milnor's        students' ->  students'
```

Type the apostrophe and the whole list comes back possessive. The stem is
matched — that is the part you misspell — and the ending you typed is put back
untouched, because whether it takes `'s` or a bare `'` depends on the noun
being plural and your apostrophe already says so.

Nothing guesses a possessive from a bare `s`: `teachers` and `students` are
ordinary plurals far more often.

---

## Your own abbreviations

`spellless_shortcuts.txt`, in the same directory:

```
bc      because
ppl     people
btw     by the way
```

An exact match on the left puts the text on the right at the top, ahead of
everything the matcher inferred; the expansion is free text, so several words
are fine, and `#` starts a comment. Redeploy after editing.

You will need fewer of these than you expect. The matcher already rebuilds a
word from its consonants, so `mthmtcs` finds `mathematics` and `ppl` would find
`people` unaided. What a list is for is the cases where the information is not
in the input at all: `bc` is two letters, and at two letters almost every word
in the language is a plausible completion, which is why the skeleton sources
stay quiet there (`min_skeleton_completion_len`). No tuning fixes that. It is a
habit, and a habit has to be written down.

---

## Configuration

Anything in `rime/lua/spellless/config.lua` can be overridden per schema. Edit
`spellless.custom.yaml` in your Rime user directory:

```yaml
patch:
  # put the literal input first, always
  spellless/raw_candidate_index: 1
  # mark it, so it is obvious which one it is
  spellless/raw_comment: "literal"
  # show where every candidate came from and what it scored
  spellless/show_debug_comments: true
  # stop learning
  spellless/learn: false
  # type your own spaces and capitals
  spellless/auto_space: false
  spellless/auto_capitalize: false
  # only on the Spellless build of Weasel: let punctuation take back the space
  # after a word you already committed, so "you " + "." is "you. "
  spellless/reclaim_space: true
  # a bigger candidate window (the literal-input slot follows page_size)
  menu/page_size: 9
```

Redeploy afterwards.

---

## Rebuilding

```bash
make            # dictionary + indexes + test set
make test       # 1844 assertions
make bench      # accuracy and latency over tests/cases/
make install
```

or, without `make`:

```bash
python3 scripts/build_dictionary.py     # generated/spellless.words, .weights
python3 scripts/build_indexes.py        # generated/spellless.alpha, .skel
python3 scripts/make_testset.py         # tests/cases/generated_*.tsv
lua tests/run.lua
python3 tests/test_install.py
lua bench/evaluate.lua
```

Every generated file is byte-for-byte reproducible from `data/`, and
`generated/spellless.build.json` records the sources, their SHA-256 sums and
the parameters used. The manifest also records the build time, so set
`SOURCE_DATE_EPOCH` if you want that reproducible too. `install.py` refuses to
copy a `generated/` whose parts disagree with each other. Sources and licences: [data/README.md](data/README.md).

The tests and benchmark need a `lua` binary (5.4). They exercise exactly the
modules Rime loads — the matching core is plain Lua with no Rime dependency.

---

## Layout

```
spellless/
├── DESIGN.md              architecture, and why each decision went that way
├── EVALUATION.md          accuracy and latency, and how to reproduce them
├── docs/spellless.jpg     the screenshot at the top
├── rime/
│   ├── spellless.schema.yaml
│   └── lua/
│       ├── spellless.lua          Rime adapter + the Return processor
│       └── spellless/             the matcher, no Rime dependency
│           ├── config.lua         every tunable number, in one place
│           ├── corpus.lua         dictionary + the two index permutations
│           ├── distance.lua       weighted Damerau-Levenshtein, banded
│           ├── generate.lua       candidate generation: exact/prefix/typo/skeleton
│           ├── rank.lua           the single additive score
│           ├── skeleton.lua       the consonant-skeleton rule
│           ├── preceding.lua      what the text behind the cursor implies
│           ├── userdb.lua         personal vocabulary and learning
│           ├── engine.lua         orchestration, capitalisation, literal input
│           └── util.lua
├── scripts/               dictionary build, index build, test-set build, installer
├── data/                  vendored corpus, supplemental vocabulary, surface forms
├── generated/             build output (1.3 MB) — what gets deployed
├── tests/                 1844 assertions + the evaluation cases
└── bench/                 evaluate.lua, tune.lua, naive.lua
```

---

## Limitations

Found while building this, not guessed at.

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

   The frontend is not bound by this, and the Spellless build of Weasel lifts
   it: set `spellless/reclaim_space: true` and punctuation takes that space
   back. See DESIGN §5.6 and
   [EricWay1024/spellless-weasel](https://github.com/EricWay1024/spellless-weasel).
   It stays off on a stock install, where the request would be typed in
   literally.
3. **No space goes in front of opening punctuation**, so `Let $X$` needs the
   space after `Let` typed by hand. Adding one before `(`, `[` and `$` would
   turn `f(x)` into `f (x)`; the two are indistinguishable from inside the IME,
   so Spellless does not guess.
4. **No multi-word input.** One composition is one word. `mthmtcs s hrd`
   requires three commits. Rime's `octagram` (bundled) would give sentence
   context, but that needs a real dictionary-backed translator; see *Next*.
5. **Splitting is exact only.** `exactlyright` gives `exactly right`, but a
   run-together that is *also* misspelled does not: `exctlyrght` finds nothing.
   Every part would need the full fuzzy search at every split point.
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
10. **Typing latency is Lua-bound.** About 1.7 ms per keystroke while typing an
   ordinary word, 8 ms at the 95th percentile across the whole evaluation set,
   with a ceiling on how many candidates are examined. It is comfortably
   interactive, but there is no headroom for, say, a 500k-word dictionary
   without a different index.
11. **On a stock Weasel, spacing and capitals are inferred.** Rime's commit
   history is a record of what the input method committed, not of the document:
   it is cleared on Return and Backspace, and a mouse click that moves the
   caret is invisible. So you will occasionally get a stray space or capital;
   Backspace re-syncs it, and `spellless/auto_space` /
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

## Next improvements, in order of expected impact

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
4. **Fuzzy splitting**, so `exctlyrght` finds `exactly right`. Every part needs
   the full search at every split point, so it wants tight budgets and a gate.
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

---

## Licence and data

Code: MIT. Dictionary: derived from the SymSpell frequency dictionary (MIT);
see [data/README.md](data/README.md) for provenance, preprocessing and counts.
