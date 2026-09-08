# Spellless

**Stop spelling. Start writing.**

![Typing "cmplctd" and being offered "complicated"](docs/spellless.jpg)

Spellless takes your approximate spelling and offers you the word you meant.
Drop the vowels. Get the letters out of order. Run two words together. Then
glance, pick, and keep going.

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

`→` means "on the list", not always "at the top of it". **Every change is one
you picked**: the list appears, you choose, and <kbd>Enter</kbd> always commits
exactly what you typed.

It becomes one of the input methods in your keyboard menu, on Windows, macOS
and Linux, so it is there in every program you type in. **The word you meant is
first 89.8% of the time, and in the top five 99.3%** — measured on ten fresh
draws the tuning never saw, ± 0.6.

Around that, the small things stop needing attention. Spaces appear between
words and never in front of a comma, sentences start with a capital, `eg`
becomes `e.g.` and `i` becomes `I`. A colleague's name is remembered after you
type it once, and a correction you make twice leads that input from then on.
When it does get something wrong, one key makes it forget. The space bar takes
whatever is first, and a word the dictionary has never seen takes **two**
presses of it.

Why this is an input method and not a spell checker:
[MANIFESTO.md](MANIFESTO.md).

---

## Install

For the best experience, use the Spellless builds of [Rime](https://rime.im)
below. They add a few small integration features that stock Rime cannot
provide.

Already use Rime and want to keep it? Spellless works there too —
[docs/INSTALL.md](docs/INSTALL.md) has all six routes in, and what each one
trades.

| | **recommended** |
| --- | --- |
| **Windows** | **One file.** Download `spellless-<version>-installer.exe` and run it — Spellless is already inside. |
| **macOS** | Install `Spellless-Squirrel-<version>.pkg`, log out and back in, and add **Squirrel - Simplified** in System Settings → Keyboard → Text Input (it is filed under *Chinese*, not English). Then unzip `spellless-<version>.zip` and run `python3 scripts/install.py` inside it. |
| **Linux** | Build [spellless-fcitx5](https://github.com/EricWay1024/spellless-fcitx5), then unzip `spellless-<version>.zip` and run `python3 scripts/install.py` inside it. |

The downloads are on
[Releases](https://github.com/EricWay1024/spellless/releases). Afterwards,
click **Deploy** in the Rime icon's menu, then press <kbd>F4</kbd> and choose
**Spellless** from the list. Type `zzver` anywhere to confirm it is running.

Python 3.8+ runs the installer, and on Windows you do not need even that.

If something does not work,
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

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
  <kbd>Shift</kbd> leaves Spellless entirely; a caret inside a word means plain
  typing; `$` hands the keyboard to maths.
* **Short input and notation commit as themselves**: `x`, `cm`, `PDE`, `4D`.

[docs/USING.md](docs/USING.md) is the whole of it — every feature, every key,
and how the personal vocabulary files work.

---

## Documentation

| | |
| --- | --- |
| [MANIFESTO.md](MANIFESTO.md) | what problem this is, and why it is shaped this way |
| [docs/USING.md](docs/USING.md) | every feature, the keys, and your own vocabulary |
| [docs/INSTALL.md](docs/INSTALL.md) | the six routes in, and everything you can change |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | symptoms, and what each one usually is |
| [DESIGN.md](DESIGN.md) | the architecture, and why each decision went that way |
| [docs/ALGORITHM.md](docs/ALGORITHM.md) | the matcher in full, with the evaluation |
| [docs/NOISY-CHANNEL.md](docs/NOISY-CHANNEL.md) | the same algorithm as a decision problem over noisy channels |
| [EVALUATION.md](EVALUATION.md) | accuracy and latency, and how to reproduce them |
| [docs/PIPELINE.md](docs/PIPELINE.md) | every step from keystroke to candidate, in pseudocode |
| [docs/DEPLOYING.md](docs/DEPLOYING.md) | how a build reaches the input method, and the ways it silently does not |
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

The tests and benchmark need a `lua` binary (5.4).
`generated/spellless.build.json` records the sources, their SHA-256 sums and
the parameters used.

Our builds of Rime live in their own repositories:
[spellless-weasel](https://github.com/EricWay1024/spellless-weasel) (Windows),
[spellless-squirrel](https://github.com/EricWay1024/spellless-squirrel) (macOS)
and [spellless-fcitx5](https://github.com/EricWay1024/spellless-fcitx5)
(Linux, and the roughest of the three).

There is also a typing bench — [`docs/typing-bench.html`](docs/typing-bench.html),
open it in a browser, nothing to build — which scores six public-domain
passages by minimum edit distance.

---

## Limitations

The ones you will meet in practice. [DESIGN.md §9](DESIGN.md#9-limitations-found-while-building-this)
has the full list and the reason behind each.

1. **One composition is one word.** `mthmtcs s hrd` is three commits, and a
   digit ends a word — type `Lean`, commit it, then `4`.
2. **The fuzzy readings do not compose.** `exactlyright` gives `exactly right`,
   but a run-together that is *also* misspelled does not, and shorthand with a
   slip inside it usually cannot be reached.
3. **Very short input is genuinely ambiguous**: `frm` offers `from`, `form`,
   `firm`, `farm`, `forum`, `frame` in frequency order.
4. **On the standard Rime, spacing and capitals are guesswork.** A click that
   moves the cursor is invisible to Spellless, so you will occasionally get a
   stray space or capital. Backspace re-syncs it, either can be turned off, and
   our own build does not have to guess.

---

## Licence and data

Code: MIT. Dictionary: derived from the SymSpell frequency dictionary (MIT);
see [data/README.md](data/README.md) for provenance, preprocessing and counts.
