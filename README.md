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
mthmtcs   →  mathematics       recieve       →  receive
brcrtc    →  bureaucratic      teh           →  the
satfcatn  →  stratification    exactlyright  →  exactly right
sth       →  something         dont          →  don't
```

`→` means "on the list", not always "at the top of it". **Every change is one
you picked**: the list appears, you choose, and <kbd>Enter</kbd> always commits
exactly what you typed.

It is a [Rime](https://rime.im) schema for Windows, macOS and Linux, and **the
word you meant is first 89.8% of the time, in the top five 99.3%** — measured
on ten fresh draws the tuning never saw, ± 0.6.

---

## Why Spellless?

Chinese input methods solved a version of this decades ago. You type an
approximation, the IME shows you candidates, you pick one. Hundreds of millions
of people write that way every day.

English never got the same treatment, because typing English assumes you can
spell it. Spelling stays a tax on thinking — a hundred small stumbles an hour,
each one pulling your attention off the sentence and onto the keyboard.

Spellless is that same arrangement, for English. It treats what you typed as
**a noisy encoding of a word you already know**, and decodes it. A
transposition is nearly free; vowels are cheap and consonants carry the word;
and you can drop consonants too — say the word to yourself and type a letter or
two a syllable, and `satfcatn`, `stfcatn` and `strtfctn` are all
`stratification`. Typo tolerance, incomplete spelling, consonant cues, how
common a word is and what you have chosen before all compete on one score, so a
common word reached by a cheap slip can beat a rare exact prefix.

### Why not autocorrect?

Autocorrect waits for you to write something wrong and then guesses, unseen,
which keeps it timid on purpose: every guess is applied without asking, so it
can risk a near-miss of an edit or two and no more. Spellless puts a list in
front of you instead, and that is what makes real ambition affordable.
Offering `mathematics` for `mthmtcs` means allowing a distance at which half
the dictionary is reachable — unthinkable if a machine must pick, and fine
here, because the answer is one of seven on the page, because what you typed is
always among them, and because <kbd>Enter</kbd> commits it verbatim. `kubectl`,
`argmax` and a name it has not met are left alone.

It also changes what the thing is *for*. There is a moment, several times an
hour, when you know you cannot spell a word *and you know that you know*:
`bureaucratic`, `liaison`, `diffeomorphism`. Autocorrect cannot help — you have
not written anything yet for it to fix, so you break off and look it up, or
settle for a duller word you can spell. Type the consonants instead and the
word is in front of you. That costs a beat the first time, and then it
compounds: you build muscle memory for the shorthand exactly as you once built
it for the spelling, until the vocabulary you can spell and the vocabulary you
can *write* start to converge. The second one is much bigger.

## What typing with it feels like

```
recieve       →  receive           an ordinary typo
mthmtcs       →  mathematics       the vowels are gone
brcrtc        →  bureaucratic      a word you could not have spelled
satfcatn      →  stratification    a letter or two a syllable
exactlyright  →  exactly right     run together
sth           →  something         your own shorthand
grthndck      →  Grothendieck      a name, after you have typed it once
kubectl       →  kubectl           left alone
```

Around that, the small things stop needing attention. Spaces appear between
words and never in front of a comma, sentences start with a capital, `eg`
becomes `e.g.` and `i` becomes `I`. A colleague's name is remembered after you
type it once, and a correction you make twice leads that input from then on.
When it does get something wrong, one key makes it forget. At speed you barely
read the list — the space bar goes on muscle memory and takes whatever is
first — so a word the dictionary has never seen takes **two** presses of it,
because the moment worth interrupting you is the moment you were about to
commit something it cannot vouch for.

---

## Install

Spellless is a Rime schema, so it needs a Rime frontend. Everything in it is
data and Lua: nothing to compile, no administrator rights. Grab the files from
[Releases](https://github.com/EricWay1024/spellless/releases).

| | the short way |
| --- | --- |
| **Windows** | Run `spellless-<version>-installer.exe`. It is the only download you need — the schema inside a Rime frontend, installed *beside* any Rime you already have. |
| **macOS** | Install `Spellless-Squirrel-<version>.pkg`, then unzip `spellless-<version>.zip` and run `python3 scripts/install.py`. |
| **Linux** | Install `ibus-rime` or `fcitx5-rime` from your distribution, then unzip `spellless-<version>.zip` and run `python3 scripts/install.py`. |

Then **redeploy**: the Weasel tray icon or the Squirrel menu-bar icon →
**Deploy**, or `ibus restart` / `fcitx5-remote -r`. Press <kbd>F4</kbd> and
choose **Spellless**.

**To check it took**, type `zzver` in any text box. It prints the build that is
actually running, the size of the dictionary, and what is switched on.

The installer needs Python 3.8+ and writes only inside your Rime user
directory, adding Spellless to the schema list rather than replacing it.

**Other setups** — a stock Weasel or Squirrel you would rather keep, the macOS
and Linux frontends, installer flags, settings —
[docs/INSTALL.md](docs/INSTALL.md). When a deploy does not take,
[docs/DEPLOYING.md](docs/DEPLOYING.md).

---

## What it can do

* **Fuzzy candidates.** Typos, transpositions, doubled and missing letters,
  and misspellings much worse than autocorrect would attempt.
* **Incomplete spellings.** Consonant skeletons (`mthmtcs`), syllabic shorthand
  (`satfcatn`), and completions from a prefix.
* **Words it has never seen.** Coinages get built from affixes (`resmplng` →
  `resampling`), and words run together come apart (`exactlyright`).
* **It learns.** A word you commit once is a candidate for ever, a correction
  you make twice leads the list from then on, and one key makes it forget.
* **Your own vocabulary.** A plain-text word list, a shortcut file, and eight
  importable packs — algebra, topology, software, philosophy and more.
* **Capitals you never think about.** Sentence capitals, acronyms, and spellings
  that resist both (`iPhone`, `LaTeX`, `arXiv`).
* **Literal typing, always.** What you typed is on the first page; a tapped
  <kbd>Shift</kbd> leaves Spellless entirely; `$` hands the keyboard to maths.
* **Windows, macOS and Linux**, on stock Rime or on the Spellless frontends.

[docs/USING.md](docs/USING.md) is the whole of it — every feature, every key,
and how the personal vocabulary files work.

## Design principles

**You stay in control.** Spellless never rewrites what you wrote: it offers,
you pick. <kbd>Enter</kbd> commits exactly what you typed, and the literal
input is always on the first page — which is the only reason the matching can
afford to be this aggressive.

**It should know when not to interfere.** Short input and notation commit as
themselves (`x`, `cm`, `PDE`, `4D`); a caret inside a word means plain typing;
a word it cannot vouch for asks before it goes in. Being wrong quietly is worse
than being absent.

**Your habits beat the corpus.** English frequency is a prior, not a verdict.
Anything you choose twice overrules it.

---

## Documentation

| | |
| --- | --- |
| [docs/USING.md](docs/USING.md) | every feature, the keys, and your own vocabulary |
| [docs/INSTALL.md](docs/INSTALL.md) | frontends, installer flags, settings |
| [DESIGN.md](DESIGN.md) | the architecture, and why each decision went that way |
| [docs/ALGORITHM.md](docs/ALGORITHM.md) | the matcher in full, with the evaluation |
| [docs/NOISY-CHANNEL.md](docs/NOISY-CHANNEL.md) | the same algorithm as a decision problem over noisy channels |
| [EVALUATION.md](EVALUATION.md) | accuracy and latency, and how to reproduce them |
| [docs/PIPELINE.md](docs/PIPELINE.md) | every step from keystroke to candidate, in pseudocode |
| [docs/DEPLOYING.md](docs/DEPLOYING.md) | how a build reaches the input method, and how to tell |
| [docs/SNIPPETS.md](docs/SNIPPETS.md) | writing maths with an editor's snippets |
| [docs/RELEASING.md](docs/RELEASING.md) | cutting the archive and the bundled installer |
| [data/README.md](data/README.md) | the corpus, its provenance and its weaknesses |

## Development

```bash
make            # dictionary + indexes + test set
make test       # 2,327 assertions
make bench      # accuracy and latency over tests/cases/
make install
```

The tests and benchmark need a `lua` binary (5.4) and exercise exactly the
modules Rime loads, including a stand-in for librime-lua built from its actual
API. Every generated file is byte-for-byte reproducible from `data/`, and
`generated/spellless.build.json` records the sources, their SHA-256 sums and
the parameters used.

The three frontend forks live in their own repositories:
[spellless-weasel](https://github.com/EricWay1024/spellless-weasel) (Windows),
[spellless-squirrel](https://github.com/EricWay1024/spellless-squirrel) (macOS)
and [spellless-fcitx5](https://github.com/EricWay1024/spellless-fcitx5)
(Linux, and the roughest of the three).

There is also a typing bench — [`docs/typing-bench.html`](docs/typing-bench.html),
open it in a browser, nothing to build — which scores six public-domain
passages by minimum edit distance and charges you for the time spent choosing a
candidate.

---

## Limitations

The ones you will meet in practice. [DESIGN.md §9](DESIGN.md#9-limitations-found-while-building-this)
has the full list and the reason behind each.

1. **One composition is one word.** `mthmtcs s hrd` is three commits, and a
   digit ends a word — type `Lean`, commit it, then `4`.
2. **The fuzzy readings do not compose.** `exactlyright` gives `exactly right`,
   but a run-together that is *also* misspelled does not, and shorthand with a
   slip inside it usually cannot be reached.
3. **Very short input is genuinely ambiguous**, and the ranking does not
   pretend otherwise: `frm` offers `from`, `form`, `firm`, `farm`, `forum`,
   `frame` in frequency order.
4. **On a stock frontend, spacing and capitals are inferred** from what the
   input method committed rather than from the document, so you will
   occasionally get a stray space or capital. Backspace re-syncs it, either can
   be turned off, and the Spellless frontends do not have to guess.

---

## Licence and data

Code: MIT. Dictionary: derived from the SymSpell frequency dictionary (MIT);
see [data/README.md](data/README.md) for provenance, preprocessing and counts.
