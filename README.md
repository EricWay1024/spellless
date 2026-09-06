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
satfcatn         →  stratification       grthndck       →  Grothendieck
exactlyright     →  exactly right        thisday        →  this day
mther's          →  mother's             mthers'        →  mothers'
bc               →  because              im             →  I'm
```

**Nothing is ever corrected behind your back.** The list appears, you choose,
and <kbd>Enter</kbd> always commits exactly what you typed — because the one
thing worse than mistyping a word is a machine mistyping it for you,
confidently, while you look away.

## Why this should exist

Chinese input methods solved a version of this decades ago. You type an
approximation, the IME shows you candidates, you pick one. Hundreds of millions
of people write that way every day and nobody finds it remarkable.

English never got the same treatment, because typing English assumes you can
spell it. So spelling stays a tax on thinking — a hundred small stumbles an
hour, each one pulling your attention off the sentence and onto the keyboard.
You know the word. The machine is making you prove it, letter by letter, and
giving you nothing for the trouble.

Spellless is that same arrangement, for English. It treats what you typed as
**a noisy encoding of a word you already know**, and decodes it:

* **A transposition is nearly free.** `teh` is `the`. Your fingers arrived out
  of order, which says almost nothing about what you meant.
* **Vowels are cheap. Consonants carry the word.** `mthmtcs` is `mathematics`
  and `dffmrphsm` is `diffeomorphism`.
* **And you need not even keep all the consonants.** Say the word to yourself
  and type one or two letters a syllable — `satfcatn`, `stfcatn`, `strtfctn`
  are all `stratification`. There is no scheme to learn: the matcher prices
  the letters you *left out* rather than demanding the ones you kept.
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
list, and <kbd>Enter</kbd> always commits it verbatim.

Look again at the screenshot. `complicated` is first, and `completed`,
`complicate`, `compacted`, `complicity` are the words a reasonable reader might
have suspected. That is a ranking, not a lookup: nothing under `rime/lua/`
knows any of those words. They fall out of a weighted edit distance, a
consonant-skeleton index, a syllable-cue alignment and one ranking function.
See [DESIGN.md](DESIGN.md).

## What it feels like

You stop proofreading mid-sentence. Spaces appear between words and never in
front of a comma, sentences start with a capital, `eg` becomes `e.g.` and `i`
becomes `I`. A colleague's name is remembered after you type it once, and a
correction you make twice becomes the first thing offered ever after. A word
Spellless has never seen will not go in on one press of the space bar — it
takes two, because the moment worth interrupting you is the moment you were
about to be wrong. And when it does get something wrong, one key makes it
forget.

```
mathe            →  mathematics · mathematical …
dont             →  don't          its       →  its · it's
youre            →  you're         id        →  id · I'd
noether's        →  Noether's      psdfnctr  →  pseudofunctor
```

It is a [Rime](https://rime.im) schema for Windows, and **the word you meant is
first 89.9% of the time, on the first page 99.1%** — measured on cases the
tuning never saw. About 2.5 ms per keystroke over 83,095 words. 2,033
assertions say it still behaves. [EVALUATION.md](EVALUATION.md) has the
numbers, including the cases it gets wrong and why.

---

## Install

**Windows 11 with [Weasel](https://github.com/rime/weasel) 0.16 or newer**, and
**Python 3.8+** to run the installer (and only for that). Lua support is
already there — official librime release builds bundle `librime-lua`, and
Weasel ships those builds — so there is nothing to compile, no plugin to
install and no administrator rights needed.

```powershell
python scripts\install.py
```

From WSL, run `python3 scripts/install.py` instead — it finds the Windows-side
Rime directory itself. Then right-click the Weasel tray icon → **Deploy** (「重新部署」), press
<kbd>F4</kbd> and choose **Spellless**.

| Flag | |
| --- | --- |
| `--dry-run` | print every action, change nothing |
| `--list-candidates` | show which Rime user directories were considered, and why |
| `--user-dir DIR` | install somewhere specific |
| `--uninstall` | remove the files this script wrote |

The installer only ever writes inside your Rime user directory, and never
`rime.lua` — only one is ever loaded, so overwriting it would break other Lua
schemas. It enables the schema by appending one entry to `default.custom.yaml`
with Rime's list-append operator (`"schema_list/+"`), which **adds** to the
schema list rather than replacing it — important if you run a distribution like
rime-ice. The file is backed up first and only ever has lines inserted, so your
comments survive; if it already patches `schema_list`, the installer prints
what to add rather than guessing. `--no-enable` copies the files and leaves
that file alone.

If something misbehaves on first deploy, the candidate comments
(`spellless/show_debug_comments: true`) and `%APPDATA%\Rime\rime.log` are the
two places to look.

---

## Keys

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

**Tap Shift to get out of the way.** It switches to plain typing, and tapping
it again switches back — the tray icon shows which mode you are in. Tapped
mid-word it first commits exactly what you had typed, so it doubles as the
escape hatch when a word is clearly not going to be found: `\citep{Hat02}` is a
Shift tap away, rather than something the matcher has to be taught. It is safe
while typing capitals, because librime only toggles on a *bare*
press-and-release within 500 ms — <kbd>Shift</kbd>+<kbd>M</kbd> can never flip
the mode.

---

## What it does while you type

**Shorthand can be as rough as you like.** Drop the vowels and you get
abbreviation matching. Drop whatever you like and you still get the word: say
it to yourself, type one or two letters that feel right for each syllable, and
stop worrying about which ones.

```
stratification  ←  strtfctn  satfcatn  stfcatn
government      ←  gvrnmnt   gvmnt     govmnt
cohomology      ←  chmlgy    cohmlgy   chmolgy
```

There is no scheme to learn and no table to memorise, because the matcher
prices the letters you *left out* rather than demanding the ones you kept: a
vowel costs almost nothing to skip, a consonant next to another consonant a
little, and a consonant that begins a syllable rather more. That is the entire
model — no pronunciation dictionary, no syllabifier. `alghrith` reads as
`algorithm`, `tnk` puts `think` next to `tank`, and it works on your own words
too, so `gthndck` still finds `Grothendieck`.

**Spaces are automatic**, and they ride on the word: whichever key commits it —
space bar, a number — puts the space in too. Typing punctuation instead ends
the word *without* its space and puts one after the punctuation, so nothing
ever has to be un-typed.

```
hello  wrold.     →  Hello world.
you.   thats      →  You. That's
```

**Sentences start with a capital** — after `.`, `!`, `?`, on a new line, at the
start of an empty text box — but only if you typed the word in lower case, so
`MATHE` and `kubectl` are left alone. Your own capitals are kept: `Mathe` gives
`Mathematics`, `RECIEVE` gives `RECEIVE`.

**Dropped apostrophes are treated as typography, not spelling**, so `dont`
gives `don't`, `youre` gives `you're`, and `its` gives `its` with `it's` right
behind it. A bare `i` gives `I`, and `eg` gives `e.g.` — committing the
abbreviation whole is also what stops it being mistaken for the end of a
sentence. Add your own in `data/forms.txt`.

**Words run together come apart**, any number of them, because cutting a string
into dictionary words is a word-break search. Each part keeps its own spelling,
hence the capital `I`.

```
exactlyright      →  exactly right       iamgoingtoschool  →  I am going to school
```

A word is never split (`another` is not `a not her`), and a split is placed
rather than ranked — last among the real candidates, so it can neither displace
a correction nor be crowded out by a mediocre one. `spellless` and `argmax`
keep the first slot; `this day` is there when you want it.

**Possessives follow the stem.** Type the apostrophe and the whole list comes
back possessive: `mther's` → `mother's`, `mthers'` → `mothers'`. The stem is
matched — that is the part you misspell — and the ending you typed is put back
untouched, because only your apostrophe knows whether the noun was plural.
Nothing guesses a possessive from a bare `s`.

**Short and capitalised input leads with itself.** `x`, `cm`, `ms`, `PDE`,
`TQFT` commit as themselves, because one or two characters are variables and
units far more often than the start of a longer word, and an acronym typed in
capitals is deliberate. A real word still means itself (`i`, `an`, `eg`), and a
one-letter completion of a short stem is still trusted (`th` → `the`).
**snake_case identifiers** (`foo_bar`, `max_iter2`) are taken literally as soon
as the underscore appears.

**The literal text you typed is always on the first page** — in slot 7 by
default, or first when nothing plausible was found — so pressing space on
`kubectl` or `argmax` cannot turn it into an English word. A word Spellless has
never seen also takes two presses of the space bar rather than one, because the
moment worth interrupting you is the moment you were about to be wrong.

**Type `zzver` to see which build you are running.** The candidate list answers
with the revision, when it was installed, how many words it loaded and how it
is configured — so "am I testing what I just deployed, or what Rime loaded
twenty minutes ago" stops being a guess.

```
zzver  →  spellless 41223bf installed 2026-09-06 12:34
          83095 words, 580 forms, 3 shortcuts
          cue 70/9.0, slip 10.0, learn on
```

---

## Your own vocabulary

**Learned as you go.** Every word you commit is counted in
`<rime user dir>/spellless_user.txt`, and words you pick often rise. A word the
dictionary has never heard of becomes a candidate as soon as you commit it
once: press Enter on `Grothendieck` and afterwards `grthndck` gives it back,
capitals and all; commit `pytest` once and `pytst` finds it thereafter. *How*
you write a word is stored only when the dictionary cannot already explain it,
so a capital that came from the start of a sentence is never mistaken for a
preference — and committing the plain lowercase form takes a stored spelling
back.

**A correction you make twice is a correction you meant.** Pick the same
candidate for the same input a second time and it leads that input from then
on — placed, not scored, so nothing about English frequency argues with it.
Once is not enough on purpose: a good deal of what anyone picks is picked once
by accident.

```
cli   →  click  client  clip  clips ...      before
cli   →  CLI    click   client  clip         after picking CLI twice
```

Only selections count. <kbd>Enter</kbd> commits exactly what you typed, which
is a refusal to choose between the readings rather than a choice among them, so
it teaches nothing. Control+Shift+D takes a correction back along with the word.

That file is plain text and safe to edit by hand:

```
# word <TAB> count
# word <TAB> how you write it <TAB> count
# > what you typed <TAB> what you chose <TAB> count
perverse	5
grothendieck	Grothendieck	12
Hausdorff
```

A one-column entry written with capitals is its own spelling, so `Hausdorff`
needs no second column.

**Abbreviations you decide on yourself** go in `spellless_shortcuts.txt`, in
the same directory. An exact match on the left puts the text on the right at
the top, ahead of everything the matcher inferred; the expansion is free text,
so several words are fine. Redeploy after editing.

```
bc      because
ppl     people
btw     by the way
```

You will need fewer of these than you expect: the matcher already rebuilds a
word from its consonants, so `ppl` would find `people` unaided. What a list is
for is the cases where the information is not in the input at all — `bc` is two
letters, and at two letters almost every word in the language is a plausible
completion. No tuning fixes that. It is a habit, and a habit has to be written
down.

**For a larger, permanent vocabulary**, add a `.txt` file to `data/vocab/` and
run `make`. This puts the words in the main dictionary with a real corpus
frequency rather than in your personal history; an entry written with capitals
(`Grothendieck`, `TQFT`) is indexed lowercase and remembers its spelling, so
only write capitals where the lowercase form would be wrong. Shipped there:
`proper_nouns.txt` and `given_names.txt`, for words only ever written with a
capital — which is why `March`, `May`, `Polish`, `Bill` and `Grace` are
deliberately absent; `phrases.txt`, for groups that behave as one word
(`infrontof` → `in front of`, and `hngkng` finds `Hong Kong` too); and
`math_sample.txt`, around 300 words of mathematics as a sample.

---

## Configuration

Anything in `rime/lua/spellless/config.lua` can be overridden per schema. Edit
`spellless.custom.yaml` in your Rime user directory and redeploy.

```yaml
patch:
  spellless/raw_candidate_index: 1     # put the literal input first, always
  spellless/raw_comment: "literal"     # and mark it, so it is obvious which it is
  spellless/show_debug_comments: true  # where each candidate came from, and what it scored
  spellless/learn: false               # stop learning
  spellless/auto_space: false          # type your own spaces
  spellless/auto_capitalize: false     # and your own capitals
  menu/page_size: 9                    # a bigger window (the literal slot follows it)
```

---

## Limitations

The ones you will meet in practice; [DESIGN.md](DESIGN.md) §9 has the full list
and the reasons behind each.

1. **Digits end a word.** The number keys select candidates and Rime's
   recognizer runs before the selector, so any pattern letting `Lean4` compose
   as one token would break candidate selection after every capitalised word.
   Type `Lean`, commit it, then `4`. Underscores are fine (`foo_bar`), and so
   is a second capital (`TQFT2`). For a run of identifiers, tap Shift.
2. **One composition is one word.** `mthmtcs s hrd` is three commits.
3. **The fuzzy readings do not compose.** `exactlyright` gives `exactly right`,
   but a run-together that is *also* misspelled does not (`exctlyrght` finds
   nothing) — and shorthand with a slip in it (`stfxctn` for `stratification`)
   falls back to ordinary matching, which usually cannot reach that far.
4. **Very short input is genuinely ambiguous**, and the ranking does not
   pretend otherwise: `frm` offers `from`, `form`, `firm`, `farm`, `forum`,
   `frame` in frequency order.
5. **Learning remembers the word, not the input that found it.** Picking
   `recommendation` for `rcmmndtn` raises `recommendation` everywhere, but does
   not remember that *this* abbreviation meant *that* word.
6. **On a stock Weasel, spacing and capitals are inferred** from what the input
   method committed rather than from the document — a mouse click that moves
   the caret is invisible — so you will occasionally get a stray space or
   capital. Backspace re-syncs it, and either can be turned off.
7. **Rime cannot retract committed text.** Commit a word with the space bar and
   *then* type punctuation and you get `mathew .`, because the word's space was
   already written. Typing the punctuation while the word is still being
   composed — the normal way — is right.

The last two are not limits of the schema but of where a schema sits, and the
fork below lifts both.

---

## The other half: [spellless-weasel](https://github.com/EricWay1024/spellless-weasel)

Everything above works on a stock Weasel. Three features do not, because no
schema can reach them:

These need the input method to take text back out of the document, which is
only possible where the document is one — a terminal has already forwarded what
it was given, so the attempt replays its buffer instead of correcting it. They
are refused in the applications listed under `commit_only_apps`, `code.exe`
among them, because VS Code's editor and its terminal are the same executable.
Press <kbd>F4</kbd> and turn on **edits document** while writing prose in one of
those; it resets when you next deploy.

| | |
| --- | --- |
| punctuation takes its space back | `you` space `.` gives `you. `, not `you . ` |
| a word being re-typed is picked up | delete the space after `so`, type `oner`, get `sooner` |
| Backspace twice | deletes the whole word |

All three exist because Rime cannot see or retract what it has committed: a
commit is a string, and once it has left the input method the text belongs to
the application. The frontend is on the other side of that line — it holds a
TSF range, so it can read the few characters in front of the caret and hand
them over, and it can take a character back.

**[EricWay1024/spellless-weasel](https://github.com/EricWay1024/spellless-weasel)**
is Weasel with that one convention added, rebuilt to install *beside* the one
you already have: its own GUIDs, pipe, registry key and user directory, so a
Chinese input method already on the machine carries on untouched. Turn the
three on with `spellless/reclaim_space`, `spellless/absorb_fragment` and
`spellless/word_backspace`. It is GPL-3.0, like Weasel; this repository is MIT.

---

## A typing bench, as a bonus

[`docs/typing-bench.html`](docs/typing-bench.html) — open it in a browser,
nothing to build. Six public-domain passages one line at a time, the model
above and your writing on the rule below, scored by **minimum edit distance**
so a dropped letter costs one edit rather than making the rest of the line read
as wrong. The clock starts on your first keystroke, so the time spent choosing
a candidate is charged to you, and what it credits is the text that arrived —
which is the only way an input method can be compared with a keyboard fairly.

It measures transcription, though, not writing. With the model line in front of
you the spelling is already solved, which is the one problem Spellless exists
to fix. Read a good score as "I copy quickly", not as "the matcher helps".

---

## Deploying and checking it took

[docs/DEPLOYING.md](docs/DEPLOYING.md) — how a build reaches the input method,
how to tell whether it actually did, and the ways it silently does not. Short
version: `make && make test && python3 scripts/install.py`, redeploy the
frontend, then type `zzver` and check the revision.

---

## Building it yourself

```bash
make            # dictionary + indexes + test set
make test       # 1977 assertions
make bench      # accuracy and latency over tests/cases/
make install
```

```
spellless/
├── DESIGN.md      architecture, and why each decision went that way
├── EVALUATION.md  accuracy and latency, and how to reproduce them
├── rime/          the schema, the Rime adapter, and the matcher (no Rime dependency)
├── scripts/       dictionary build, index build, test-set build, installer
├── data/          vendored corpus, supplemental vocabulary, surface forms
├── generated/     build output (1.3 MB) — what gets deployed
├── tests/         1977 assertions + the evaluation cases
└── bench/         evaluate.lua, tune.lua, naive.lua
```

The tests and benchmark need a `lua` binary (5.4) and exercise exactly the
modules Rime loads, including `tests/test_adapter.lua`, which drives
`rime/lua/spellless.lua` against a stand-in for librime-lua built from its
actual API. The librime behaviour the schema relies on was checked against
librime's source, and the installer's directory detection dry-run against a
live Weasel 0.17.4 / librime 1.13.1 install with rime-ice.

Every generated file is byte-for-byte reproducible from `data/`, and
`generated/spellless.build.json` records the sources, their SHA-256 sums and
the parameters used; `install.py` refuses to copy a `generated/` whose parts
disagree with each other.

---

## Licence and data

Code: MIT. Dictionary: derived from the SymSpell frequency dictionary (MIT);
see [data/README.md](data/README.md) for provenance, preprocessing and counts.
