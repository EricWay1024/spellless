# Spellless

**Stop spelling. Start writing.**

![Typing "cmplctd" and being offered "complicated"](docs/spellless.jpg)

You know the word. You have always known the word. What you cannot reliably do
at the speed you think is get its letters into the right order — and English
charges you for that, one keystroke after another.

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
sth              →  something            im             →  I'm
```

`→` means "on the list", not always "at the top of it". **Every change is one
you picked**: the list appears, you choose, and <kbd>Enter</kbd> always commits
exactly what you typed.

It is a [Rime](https://rime.im) schema for Windows, macOS and Linux, and **the
word you meant is first 89.8% of the time, in the top five 99.3%** — measured
on ten fresh draws the tuning never saw, ± 0.6. About 2.9 ms per keystroke.
2,327 assertions say it still behaves.

---

## Why this should exist

Chinese input methods solved a version of this decades ago. You type an
approximation, the IME shows you candidates, you pick one. Hundreds of millions
of people write that way every day.

English never got the same treatment, because typing English assumes you can
spell it. Spelling stays a tax on thinking — a hundred small stumbles an hour,
each one pulling your attention off the sentence and onto the keyboard.

Spellless is that same arrangement, for English. It treats what you typed as
**a noisy encoding of a word you already know**, and decodes it:

* **A transposition is nearly free.** `teh` is `the`. Your fingers arrived out
  of order, which says almost nothing about what you meant.
* **Vowels are cheap. Consonants carry the word.** `mthmtcs` is `mathematics`
  and `dffmrphsm` is `diffeomorphism`.
* **You can drop consonants too.** Say the word to yourself and type one or two
  letters a syllable — `satfcatn`, `stfcatn`, `strtfctn` are all
  `stratification`. The matcher prices the letters you *left out* rather than
  demanding the ones you kept, so whatever felt right will do.
* **Everything competes on one score** — frequency, edit cost, how much a
  completion adds, what you have chosen before — so a common word reached by a
  cheap slip can beat a rare exact prefix.

### Why not autocorrect?

There is a moment, several times an hour, when you know you cannot spell a word
*and you know that you know*. `bureaucratic`. `liaison`. `diffeomorphism`.
Autocorrect has to wait for you to write something wrong and then guess, so
what you do instead is break off, or settle for a duller word you can spell, or
go and look it up and lose the sentence you were holding. Here you type the
consonants and let the machine put the word in front of you: a dictionary
lookup that never takes your hands off the keyboard.

```
brcrtc      →  bureaucratic         liasn       →  liaison
dffmrphsm   →  diffeomorphism       accomodate  →  accommodate
```

That costs a beat, and the beat is real — the first time you fetch a word this
way you are slower than someone who simply knew it. **Then it compounds.** You
build muscle memory for the shorthand exactly as you once built it for the
spelling, and `dffmrphsm` stops being a lookup and becomes how you type that
word. The vocabulary you can spell and the vocabulary you can *write* start to
converge — and the second one is much bigger. Autocorrect's ceiling is the day
you install it; this has its floor there.

A candidate list also makes real ambition affordable. Autocorrect can only risk
a near-miss of an edit or two, because every guess is applied unseen. Offering
`mathematics` for `mthmtcs` means allowing a distance at which half the
dictionary is reachable — unthinkable if a machine must pick, and affordable
here because the answer is one of seven on the page, because what you typed is
always among them, and because <kbd>Enter</kbd> always commits it verbatim. It
leaves `kubectl`, `argmax` and a name it has not met alone.

At speed you barely read the list: the space bar goes on muscle memory and
takes whatever is first. Two things are designed around that. A word the
dictionary has never seen takes **two** presses of the space bar, because the
moment worth interrupting you is the moment you were about to commit something
it cannot vouch for. And a correction you make twice is promoted to first place
for that input, so the shorthand you are building is learned from your side as
well as guessed at from the dictionary's.

## What it feels like

You stop breaking off mid-sentence to work out a spelling. Spaces appear
between words and never in front of a comma, sentences start with a capital,
`eg` becomes `e.g.` and `i` becomes `I`. A colleague's name is remembered after
you type it once. And when it does get something wrong, one key makes it
forget.

```
mathe            →  mathematics · mathematical …
dont             →  don't          its       →  its · it's
youre            →  you're         id        →  id · I'd
noether's        →  Noether's      psdfnctr  →  pseudofunctor
```

In the screenshot above, `complicated` leads and `completed`, `complicate`,
`compacted`, `complicity` are the words a reasonable reader might have
suspected. That ranking falls out of a weighted edit distance, a
consonant-skeleton index, a syllable-cue alignment and one ranking function —
see [DESIGN.md](DESIGN.md), and [docs/ALGORITHM.md](docs/ALGORITHM.md) §5 for
the numbers, including the cases it gets wrong, why, and how much of the
training figure is optimism.

---

## Install

Everything here is data and Lua, so it runs wherever Rime does: **Weasel** on
Windows, **Squirrel** on macOS, `ibus-rime` or `fcitx5-rime` on Linux. Lua
support is already there — official librime release builds bundle
`librime-lua`, and every frontend above ships those builds — so there is
nothing to compile, no plugin to install and no administrator rights needed.
You need **Python 3.8+** to run the installer, and only for that.

### Step 1 — choose your frontend

Three features need the input method to reach into the document and take text
back out, which is further than any schema goes. That is the entire difference
between the two paths:

| | stock Weasel / Squirrel / `ibus-rime` / `fcitx5-rime` | **spellless-weasel** / **spellless-squirrel** |
| --- | :---: | :---: |
| everything under [Everything it does](#everything-it-does) | ✓ | ✓ |
| punctuation takes its space back — `you` <kbd>Space</kbd> `.` gives `you. `, not `you . ` | — | ✓ |
| a word you re-type is picked up — delete the space after `so`, type `oner`, get `sooner` | — | ✓ |
| <kbd>Backspace</kbd> twice deletes the whole word | — | ✓ |
| what you have to configure | `leading_space`, [step 4](#step-4--stock-rime-only-turn-on-leading_space) | nothing |

**The fork is the better experience, and it does not displace anything.**
[spellless-weasel](https://github.com/EricWay1024/spellless-weasel) is Weasel
with that one convention added, rebuilt to install *beside* the Weasel you
already have — its own GUIDs, pipe, registry key and user directory — so a
Chinese input method on the same machine carries on untouched and both appear
in the input-method list. It also carries the schema inside it, so on Windows
**it is the only download you need**: run it and go to step 3.
[spellless-squirrel](https://github.com/EricWay1024/spellless-squirrel) is the
same for macOS, built by GitHub Actions on a macOS runner, but ships the
frontend alone — install it, then do step 2.

Both are GPL-3.0, like the projects they fork; this repository is MIT. Both
ship unsigned, as upstream Squirrel's own releases do: right-click → **Open**
the first time.

**Staying on the Rime you already have** costs you those three rows and nothing
else. Do steps 2, 3 and 4.

Either way the schema install is the same, and the three features switch
themselves on when they find a frontend that can carry them — see
[the frontend fork](#the-other-half-a-frontend-that-can-edit-the-document).

### Step 2 — install the schema

Take a release archive from
[Releases](https://github.com/EricWay1024/spellless/releases) and run the
installer inside it, or clone this repository and run `make && make test`
first. Then:

```powershell
python scripts\install.py
```

or `python3 scripts/install.py` on macOS, Linux, and from WSL — where it finds
the Windows-side Rime directory by itself. It knows where each frontend keeps
its user directory: the registry on Windows, `~/Library/Rime` on macOS,
`~/.config/ibus/rime` or `~/.local/share/fcitx5/rime` on Linux.

| Flag | |
| --- | --- |
| `--dry-run` | print every action, change nothing |
| `--list-candidates` | show which Rime user directories were considered, and why |
| `--user-dir DIR` | install somewhere specific |
| `--skip-dir DIR` | leave that directory out of every future install — for a stock Weasel you keep for Chinese |
| `--no-enable` | copy the files, leave `default.custom.yaml` alone |
| `--uninstall` | remove the files this script wrote |

It writes into **every** Rime user directory it finds — `%APPDATA%\Rime` for
stock Weasel, `%APPDATA%\Spellless` for the fork — so both frontends end up
running the same build, and `--list-candidates` prints what it found and why.
`--skip-dir DIR` leaves a `spellless.skip` file behind and every later install
passes that directory by; `--uninstall --user-dir DIR` takes the schema out of
one it is already in.

It writes only inside those directories, and leaves `rime.lua` alone — only one
is ever loaded, so overwriting it would break other Lua schemas. It enables the
schema by appending one entry to `default.custom.yaml` with Rime's list-append
operator (`"schema_list/+"`), which **adds** to the schema list rather than
replacing it — important if you run a distribution like rime-ice. The file is
backed up first and only ever has lines inserted, so your comments survive; if
it already patches `schema_list`, the installer prints what to add rather than
guessing.

### Step 3 — redeploy, and check it took

Redeploy the frontend — the Weasel tray icon → **Deploy** (「重新部署」), the
Squirrel menu-bar icon → **Deploy**, or `ibus restart` — then press
<kbd>F4</kbd> and choose **Spellless**. On Windows the tray icon and the
language-bar button turn into an **S**, and tapping Shift into plain typing
brings back Weasel's **A**.

**Type `zzver` in any text box** to see which build is actually running, so
"am I testing what I just deployed, or what Rime loaded twenty minutes ago"
stops being a guess:

```
zzver  →  spellless 41223bf installed 2026-09-06 12:34
          83414 words, 809 forms, 3 shortcuts
          cue 70/9.0, slip 10.0, learn on
```

If something misbehaves on first deploy, the candidate comments
(`spellless/show_debug_comments: true`) and `%APPDATA%\Rime\rime.log` are the
two places to look. [docs/DEPLOYING.md](docs/DEPLOYING.md) has how a build
reaches the input method and the ways it silently does not.

### Step 4 — stock Rime only: turn on `leading_space`

The automatic space rides on the word, which is right — stop typing anywhere
and the text is finished. It costs exactly one thing, and only where the
frontend cannot take a character back: punctuation after a word you have
*already* committed leaves the space stranded, so picking `you` by number and
then ending the sentence gives `you .`

Put this in `spellless.custom.yaml` in your Rime user directory and redeploy:

```yaml
patch:
  spellless/leading_space: true
```

The space now goes in front of the *next* word, where punctuation never has to
argue with it:

```
                        stock frontend, default   with leading_space
typing "hello. world."   Hello . World .           Hello. World.
```

It is off by default because the trade goes the other way once your frontend
*can* reclaim: leave the caret after a word and there is no space behind it
until you type again, so a line you stop in the middle of ends flush. While you
are typing it looks the same — the space is written on the first letter of the
next word rather than carried by the candidate, so the candidate list never
shows a leading space either. `reclaim_space` and `enter_space` become
redundant rather than wrong when it is on; they simply never have a space to
act on.

---

## Everything it does

**Finding the word**

| | |
| --- | --- |
| Drop the vowels | `mthmtcs` → mathematics, `dffmrphsm` → diffeomorphism |
| Mistype it | `recieve` → receive, `teh` → the — transposed, wrong, missing or extra letters |
| Finish it for you | `neighbo` → neighbourhood |
| Syllabic shorthand | `satfcatn` → stratification, `alghrith` → algorithm even with a slip in it |
| Words run together | `exactlyright` → exactly right, any number of them |
| Words built out of parts | `resampling`, `matrixwise` — coined, not looked up |
| Possessives | `mther's` → mother's, `mthers'` → mothers', and the ending follows the word |
| Dropped apostrophes | `dont` → don't, `im` → I'm, `ive` → I've |
| Abbreviations without dots | `eg` → e.g., committed whole so it does not end a sentence |
| Your own shorthand | `sth` → something, and a file for your own habits |

**Capitals, which nobody should have to think about**

| | |
| --- | --- |
| Sentences start with one | but `MATHE` and `kubectl` are left alone |
| Both spellings of a word that has two | `ram`/`RAM`, `react`/`React`, `latex`/`LaTeX` — one keystroke apart |
| Spellings that resist it | `iPhone` starts a sentence as `iPhone`, never `IPhone` |
| Spellings you teach it | `LaTeX`, `arXiv`, `PyTorch`, `McDonald's` — kept, and reachable from any shorthand |
| A capital you chose twice | becomes the default, and picking the lowercase twice undoes it |

**Reading the sentence you are in**

| | |
| --- | --- |
| After a modal, the bare verb | `would rlt` prefers relate over related — but `rlted` still gives related |
| Through adverbs and adjuncts | `would not`, `may in fact`, `can thus to some extent` |
| After an infinitive `to` | `want to`, `in order to` — but not `isomorphic to` |
| A letter against a digit is notation | `4D`, `3D`, `4th`, `5km` commit as themselves |
| Punctuation knows what it follows | `$x$` closes, `don't` does not open a quote, `e.g.` is not a full stop |

**Learning**

| | |
| --- | --- |
| A word you commit once | is a candidate from then on, capitals and all |
| A correction you make twice | leads the list, and only deliberate choices count |
| <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>D</kbd> | forgets anything learned by accident |
| No size limit | your list is searched by exactly the machinery that searches the dictionary |

**Typing, not just matching**

| | |
| --- | --- |
| The space rides on the word | never in front of it, and punctuation takes it back |
| <kbd>Enter</kbd> commits what you typed | <kbd>Shift</kbd>+<kbd>Enter</kbd> commits and adds the newline |
| Space bar asks before a misspelling | double-tap to insist |
| <kbd>Backspace</kbd> twice | deletes the whole word, not one letter |
| `qq` mid-word is a command | `qqc` capitals, `qqf` first letter, `qql` lower case, `qqd` forget |
| Editor snippets | `xthm` expands in VS Code, through your own snippet file |
| Tapping Shift gets out of the way | and `$` does it by itself, for maths |

**Vocabulary**

| | |
| --- | --- |
| 83,414 words | plus technology, the 2020s internet, contractions, interjections, names |
| Eight importable packs | algebra, topology, software, philosophy, culture, europe, china, britain |
| Your own list | plain text, hand-editable, never overwritten by an upgrade |

### The few that need more than a line

**Shorthand can be as rough as you like.** The matcher prices the letters you
*left out* rather than demanding the ones you kept: a vowel costs almost
nothing to skip, a consonant next to another consonant a little, and a
consonant that begins a syllable rather more. That is the entire model — no
pronunciation dictionary, no syllabifier, nothing to memorise. It works on your
own words too, so `gthndck` still finds `Grothendieck`.

```
stratification  ←  strtfctn  satfcatn  stfcatn
government      ←  gvrnmnt   gvmnt     govmnt
cohomology      ←  chmlgy    cohmlgy   chmolgy
```

**Words you coin get built.** `re-`, `non-`, `pseudo-`, `over-`, `-wise`,
`-less` and two dozen more attach to any word, so no dictionary can hold the
results. When nothing ordinary fits, the affix comes off, the rest is matched
on its own, and the word is put back together — and the affix is recognised by
its consonants too, because someone who writes `smplng` writes `nn` for `non`.
The dictionary settles it first, which is what keeps `reading`, `region`,
`nonsense` and `coder` whole. Hyphenated compounds need none of this: type
`catch-me-if-you-can` straight through and the hyphens close up on their own.

```
resmplng    →  resampling        nnfnctr     →  nonfunctor
qscohrnt    →  quasicoherent     mtrxws      →  matrixwise
```

**Where English requires a bare verb, the list prefers one.** `would rlt` puts
`relate` ahead of `related`, because there is no "would related". The trigger
is a closed class and nothing else in the sentence is looked at: the nine
modals and their negations (`would could should must may might shall will
can`, `wouldn't`, `won't`, `can't`, `cannot`), with any adverbs in between; and
`to` when the word in front of it makes it an infinitive — `want to`, `in order
to`, `able to` — but not when it is a preposition, which is what `to` mostly is
in mathematics: `isomorphic to`, `due to`, `restricts to`. `would be related`
and `would have related` are good English and are never touched, because `be`
and `have` end the chain. And if you did mean the past tense, type its `d`:
`rlted` still gives `related`, so the rule only acts where your input said
nothing either way. Nothing is removed and nothing moves off the first page.

**Words run together come apart**, any number of them, because cutting a string
into dictionary words is a word-break search — and each part keeps its own
spelling, hence the capital `I` in `iamgoingtoschool` → `I am going to school`.
A split is placed rather than ranked: last among the real candidates, so it can
neither displace a correction nor be crowded out by a mediocre one. A word is
never split, so `another` stays `another`, and `spellless` and `argmax` keep
the first slot.

**Both spellings of a word that has two.** `ram` gives you the animal with
`RAM` behind it; `RAM` gives you the acronym. Same for `react`/`React`,
`windows`/`Windows`, `python`/`Python`, `cd`/`CD`, `latex`/`LaTeX` — one
keystroke apart, ordered by what you typed, and typing `LaTeX` exactly leads
with `LaTeX`, which is the only way to ask for a spelling that is neither title
nor upper case. Nothing is taken away to gain an acronym, and a spelling you
teach it never costs you the dictionary's.

**Short or notational input leads with itself.** `x`, `cm`, `ms`, `PDE`,
`TQFT` commit as themselves, because one or two characters are variables and
units far more often than the start of a longer word, and an acronym typed in
capitals is deliberate. A letter hard against a digit is notation, so `4D`,
`3D`, `4th`, `5km`, `L2` go straight in — without this `4D` gives you `4Do`.
A space turns it back off: `in 4 days` is ordinary text. snake_case identifiers
(`foo_bar`, `max_iter2`) are taken literally as soon as the underscore appears.

**The literal text you typed is always on the first page** — in slot 7 by
default, or first when nothing plausible was found — so pressing space on
`kubectl` or `argmax` cannot turn it into an English word.

---

## Keys

| Key | |
| --- | --- |
| <kbd>1</kbd>…<kbd>7</kbd> | select a candidate |
| <kbd>Space</kbd> | commit the highlighted candidate — twice, if it is a word the dictionary does not have |
| <kbd>Enter</kbd> | **commit exactly what you typed**, at once, with the automatic space after it |
| <kbd>↑</kbd> / <kbd>↓</kbd> | move the highlight — <kbd>Enter</kbd> then commits *that* candidate |
| <kbd>Esc</kbd> | cancel the composition |
| <kbd>PgUp</kbd> / <kbd>PgDn</kbd> | page through candidates |
| <kbd>Shift</kbd> (tapped on its own) | leave Spellless and type straight through; tap again to come back |
| <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>A</kbd> | the same, deliberately — also commits the word first |
| <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>D</kbd> or <kbd>Shift</kbd>+<kbd>Del</kbd> | forget the highlighted candidate |
| <kbd>F4</kbd> | schema menu |

Punctuation keys are punctuation: `,` `.` `-` `=` type themselves, where Rime's
preset would page.

**`qq` mid-word, then a key, is an instruction.** Capitalisation is otherwise
inferred — from what you typed, from whether a sentence just ended, from what
you have chosen before — and inference is right most of the time and
unarguable-with when it is not. This is the argument:

| | |
| --- | --- |
| `wndows` `qqf` | **W**indows — the first letter, for a name the dictionary reads as an ordinary word |
| `api` `qqc` | API — all caps, for an acronym |
| `but` `qql` | but — lower case, defeating an automatic sentence capital |
| `qqd` | forget the highlighted candidate, as <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>D</kbd> does |

`qq` because no English word contains it. Arming costs nothing — the letters
stay in the composition until a key that *is* a command arrives, so `zzxxqq`
is still `zzxxqq`, and anything unrecognised is just text.

**Tap Shift to get out of the way.** It switches to plain typing, and tapping
it again switches back — the tray icon shows which mode you are in. Tapped
mid-word it first commits exactly what you had typed, so it doubles as the
escape hatch when a word is clearly not going to be found: `\citep{Hat02}` is a
Shift tap away, rather than something the matcher has to be taught. It is safe
while typing capitals, because librime only toggles on a *bare*
press-and-release within 500 ms — <kbd>Shift</kbd>+<kbd>M</kbd> can never flip
the mode.

**Typing `$` gets out of the way on its own.** It writes the dollar and
switches to plain typing; the closing `$` writes itself and switches back, so
`$\frac{a}{b}$` goes in without a candidate list in front of it. Only the
delimiter that opened a run closes it, so a `$` in plain typing you reached by
tapping Shift is an ordinary dollar sign and `$PATH` in a terminal still works.
`spellless/ascii_delimiters` is the list, and `$` is all that is in it; it
works where maths gets written — VS Code and Typora — rather than in a chat
window where `$5` is a price.

**Editor snippets are handed back to the editor.** VS Code expands `xdm` into
a display-maths block the moment those letters land in the document, and under
an input method they never land — `xdm` is a composition, and whatever commits
it adds a space. So the triggers you list in `spellless_snippets.txt` commit
verbatim the instant they are complete, with no space and no capital, and the
ones that open maths hand the keyboard to plain typing as well. Every trigger
starts with `x` because no English word does.
[docs/SNIPPETS.md](docs/SNIPPETS.md) has the scheme and the two files it lives
in.

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
back. Your personal list has no size limit and is searched by exactly the
machinery that searches the dictionary.

**A correction you make twice is a correction you meant.** Pick the same
candidate for the same input a second time and it leads that input from then
on — placed rather than scored, so English frequency cannot argue with it. Once
is not enough on purpose: a good deal of what anyone picks is picked once by
accident.

```
cli   →  click  client  clip  clips ...      before
cli   →  CLI    click   client  clip         after picking CLI twice
```

Only a **number key** counts, because at speed the space bar takes whatever is
first and counting it would teach the list to insist on its own guess.
<kbd>Enter</kbd> commits exactly what you typed, which is a refusal to choose
rather than a choice, so it teaches nothing either.

**A capital you type yourself is learned the same way.** `Windows` is the case
the dictionary cannot settle — the lowercase word is ordinary English, so a
capital on it is usually just the start of a sentence. Pick it deliberately
twice and it is offered beside the plain word from then on, reachable from a
misspelling too. Both readings, always, because you still have to be able to
open a window. A capital that came from the start of a sentence stays
unlearned — that one is ours, not yours.

```
windows  →  Windows · windows · window …
wndows   →  windows · Windows · window …
window   →  window · windows · Windows …
```

That file is plain text and safe to edit by hand. A one-column entry written
with capitals is its own spelling, so `Hausdorff` needs no second column:

```
# word <TAB> count
# word <TAB> how you write it <TAB> count
# > what you typed <TAB> what you chose <TAB> count
perverse	5
grothendieck	Grothendieck	12
Hausdorff
```

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
completion. That is a habit, and a habit has to be written down.

**Vocabulary you can import.** Specialist word lists live in `data/packs/` and
are deliberately not shipped, because topology terminology is excellent if you
work on topology and clutter if you do not:

```bash
python3 scripts/import_pack.py --list
python3 scripts/import_pack.py topology algebra
```

| pack | entries | |
| --- | --- | --- |
| `algebra` | 151 | Algebra, arithmetic geometry, and writing mathematics |
| `britain` | 28 | British institutions, mostly acronyms |
| `china` | 42 | Chinese provinces, and words English borrowed |
| `culture` | 231 | Literature, film, art and music: the names people mention |
| `europe` | 136 | Travelling in Europe: airports by name, airlines, railways, cities, regions |
| `philosophy` | 216 | Philosophers, positions, and the terms of art |
| `software` | 176 | Computer science and software engineering, past what everyone needs |
| `topology` | 197 | Topology and geometric topology |

They merge into your own word list, never overwrite a count you have earned,
and a text file of your own words works just as well as a named pack. Each was
checked against the dictionary before being written: a candidate the dictionary
already spells correctly is left out. Where a name is also an ordinary word —
`Bloom`, `Lie`, `Mill`, `Stephen King` — it appears with enough of the name to
be unambiguous, so importing one never costs you the everyday word.

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
  spellless/leading_space: true        # stock Rime: put the space before the next word
  spellless/raw_candidate_index: 1     # put the literal input first, always
  spellless/raw_comment: "literal"     # and mark it, so it is obvious which it is
  spellless/show_debug_comments: true  # where each candidate came from, and what it scored
  spellless/learn: false               # stop learning
  spellless/auto_space: false          # type your own spaces
  spellless/enter_space: false         # or keep them, except after Enter
  spellless/ascii_delimiters: "$`"     # characters that switch to plain typing and back
  spellless/snippet_apps: "code.exe"   # where a trigger is given back to the editor
  spellless/delimiter_apps: "code.exe,typora.exe"  # where `$` opens maths
  spellless/auto_capitalize: false     # and your own capitals
  menu/page_size: 9                    # a bigger window (the literal slot follows it)
```

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
5. **Frequency learning is keyed on the word.** Picking `recommendation` for
   `rcmmndtn` raises `recommendation` everywhere; the pairing of *this*
   abbreviation with *that* word takes hold only once you have picked it a
   second time, as above.
6. **On a stock frontend, spacing and capitals are inferred** from what the
   input method committed rather than from the document — a mouse click that
   moves the caret is invisible — so you will occasionally get a stray space or
   capital. Backspace re-syncs it, and either can be turned off.
7. **Rime cannot retract committed text.** Commit a word with the space bar or
   <kbd>Enter</kbd> and *then* type punctuation and you get `mathew .`, because
   the word's space was already written. Typing the punctuation while the word
   is still being composed — the normal way — is right.

The last two are limits of where a schema sits, and the fork lifts both.

---

## The other half: a frontend that can edit the document

The three features in [step 1](#step-1--choose-your-frontend) all exist because
a commit is a string: once it has left the input method the text belongs to the
application. The frontend is on the other side of that line — it holds a handle
on the document, so it can read the few characters in front of the caret and
hand them over, and it can take a character back. On Windows that handle is a
TSF range; on macOS it is an `IMKTextInput`, where
`insertText(_:replacementRange:)` does in one call what TSF needs an edit
session for.

They work where the document is a document; a terminal has already forwarded
what it was given, so the attempt replays its buffer instead of correcting it.
They are refused in the applications listed under `commit_only_apps`,
`code.exe` among them, because VS Code's editor and its terminal are the same
executable. That list holds executable names and macOS bundle identifiers
together — nothing is called both `code.exe` and `com.microsoft.VSCode`, so
they cannot collide and the schema needs no platform branch. Press <kbd>F4</kbd>
and turn on **edits document** while writing prose in one of those; it resets
when you next deploy.

The schema finds out which frontend it is talking to rather than being told:
nothing is asked of a frontend until it has set `surrounding_text` at least
once, and no stock build ever does. So the three ship **on** and are simply
inert on a stock Weasel or Squirrel, whatever the configuration says.
`spellless/reclaim_space`, `spellless/absorb_fragment` and
`spellless/word_backspace` turn them off again if you would rather.

---

## Building it yourself

```bash
make            # dictionary + indexes + test set
make test       # 2,327 assertions
make bench      # accuracy and latency over tests/cases/
make install
```

```
spellless/
├── DESIGN.md      architecture, and why each decision went that way
├── EVALUATION.md  accuracy and latency, and how to reproduce them
├── docs/PIPELINE.md  every step from keystroke to candidate, in pseudocode
├── rime/          the schema, its icon, the Rime adapter, and the matcher
├── scripts/       dictionary build, index build, test-set build, icon, installer
├── data/          vendored corpus, supplemental vocabulary, surface forms
├── generated/     build output (1.3 MB) — what gets deployed
├── tests/         2,327 assertions + the evaluation cases
├── bench/         evaluate.lua, tune.lua, probe.lua, naive.lua
└── docs/          the algorithm in full, deployment, editor snippets, the bench
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

**A typing bench, as a bonus.**
[`docs/typing-bench.html`](docs/typing-bench.html) — open it in a browser,
nothing to build. Six public-domain passages one line at a time, scored by
**minimum edit distance** so a dropped letter costs one edit rather than making
the rest of the line read as wrong. The clock starts on your first keystroke,
so the time spent choosing a candidate is charged to you, and what it credits
is the text that arrived — the only way an input method can be compared with a
keyboard fairly. It measures transcription, though: with the model line in
front of you the spelling is already solved, which is the one problem Spellless
exists to fix, so read a good score as "I copy quickly".

**Further reading.** [DESIGN.md](DESIGN.md) — architecture and the reasons.
[docs/ALGORITHM.md](docs/ALGORITHM.md) — the algorithm in full, with the
evaluation. [docs/NOISY-CHANNEL.md](docs/NOISY-CHANNEL.md) — the same algorithm
as a decision problem over a family of noisy channels, for a reader who would
rather see the decomposition stated than described.
[docs/DEPLOYING.md](docs/DEPLOYING.md) — how a build reaches the input method
and how to tell whether it did. [docs/RELEASING.md](docs/RELEASING.md) — how to
cut the schema archive and the bundled Windows installer.

---

## Licence and data

Code: MIT. Dictionary: derived from the SymSpell frequency dictionary (MIT);
see [data/README.md](data/README.md) for provenance, preprocessing and counts.
