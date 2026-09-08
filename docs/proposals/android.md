# Spellless on Android

Written 2026-09-08. **Nothing here is started, and nothing should be started on
the strength of this document alone.** It exists to get the options and their
costs written down while they are cheap to change.

The question it answers is not "can we ship an Android keyboard" — we can — but
"which of three codebases do we build it out of, and is the gain worth it given
that Gboard exists".

---

## 1. The case against Gboard, stated honestly

Gboard is good, it is free, and everyone already has it. The argument for
building anything has to survive that.

**Where Gboard is genuinely weak.** It shows three candidates, and its
correction is conservative by construction: bounded edit distance plus prefix
completion. That model cannot reach `mathematics` from `mthmtcs`, and no amount
of tuning will make it, because the two strings are four insertions apart and
neither is a prefix of the other. Every consonant-skeleton input in
[MANIFESTO.md](../../MANIFESTO.md) is out of reach for the same reason. This is
not a quality gap, it is a model gap.

Spellless's matcher is not edit-distance-bounded. The skeleton and cue channels
in [ALGORITHM.md](../ALGORITHM.md) exist precisely to make `mthmtcs` reachable,
and the reason it can afford that is the reason in the manifesto: the list is
shown, the literal is always on it, and the person picks. That property is
platform-independent. It works on Android exactly as it works on a desktop.

**Where the gain is thinner than it looks.** For casual phone typing, Gboard's
three candidates plus swipe genuinely do solve most of the problem, and the
population that types `diffeomorphism` on a phone is small. The honest framing
is that this is *not* a better Gboard for everyone. It is a much better keyboard
for someone writing technical prose with their own vocabulary, and a personal
tool first. That is a reason to build it, but not a reason to expect adoption,
and the proposal should not pretend otherwise.

**Swipe is out of scope.** Not competing with it, not implementing it. Anyone
who relies on gesture typing is not the user of this.

---

## 2. Three codebases, and what each already gives us

### Path A — fork `osfans/trime`

[Trime](https://github.com/osfans/trime) is Rime for Android, actively
maintained (v3.3.12, 2026-09-01, nightlies current). Verified in its source:

* **It bundles librime-lua.** `app/src/main/jni/cmake/Rime.cmake` sets
  `RIME_PLUGINS librime-lua librime-octagram librime-predict` — the same three
  plugins as upstream librime's release CI. The schema would load and run
  unmodified.
* **Same two-directory layout** as desktop — `DataManager.sharedDataDir` and
  `userDataDir` — so `require("spellless.engine")` resolves the way
  [RELEASING.md](../RELEASING.md) describes.
* **The convention's primitives are already present.**
  `TrimeInputMethodService.kt` already calls `ic.getTextBeforeCursor(...)` and
  `ic.deleteSurroundingText(1, 0)`. It never sets `surrounding_text`, so the
  four features are inert today — but implementing them is two hooks against an
  API that hands you both halves directly. No TSF edit session, no IPC hop, no
  empty-`insertText` quirk. **This is the easiest of the four frontends**, not
  the hardest.

What it costs: Trime's UI is a Chinese IME's UI. It is themeable, but it is not
Gboard, and the muscle-memory requirement in §3 is the binding constraint on
this whole project.

What it gives for free: the real matcher, the whole schema, and Shuangpin — a
double-pinyin schema is stock Rime, so "English plus Shuangpin in one keyboard"
is configuration rather than work.

### Path B — extend the `typelessless` Android IME

`EricWay1024/typelessless` already contains a working Android IME under
`android/`: `TypelesslessImeService.kt` (32 KB), `LatinKeyboardView.kt`, a
QWERTY layout in `res/xml/qwerty.xml`, and the Soniox/Claude voice pipeline
wired to a mic key. It is Gboard-shaped already, and the voice half is a
feature no Rime frontend has.

Its suggestion side is the problem. `SuggestionEngine.kt` is Norvig
edit-1/edit-2 plus prefix completion over a bundled `words_en.txt`, ranked by
frequency, `.take(3)`. **That is the Gboard model, reimplemented** — same
bounded-edit-distance ceiling, same three slots, same inability to reach
`mthmtcs`. Replacing it is the entire point of this path.

Replacing it means getting the Spellless matcher onto Android without Rime. The
matcher is pure Lua 5.4 with no dependencies, which makes this tractable —
bundle Lua 5.4 through the NDK and call the existing modules over JNI — but it
means owning a second delivery path for the schema, separate from Rime, and
keeping the two in step. It also means reimplementing everything Rime gives us
for nothing: deployment, user dictionary persistence, schema switching.

### Path C — Trime's core, a Gboard-shaped keyboard

Fork Trime for the engine and the convention, and replace the keyboard view
with a Gboard-shaped one, borrowing the layout and key geometry from
`typelessless/android`. Keeps the matcher, the schema, deployment and Shuangpin
from A; keeps the interface constraint from B satisfiable.

**This is the recommendation.** The expensive parts (matcher, dictionary,
learning, deployment, Shuangpin) come from Rime, and the part that has to be
right for muscle memory is the part we write.

---

## 3. The constraint that decides everything: muscle memory

The keyboard has to be laid out **exactly** like Gboard — key positions, sizes,
long-press behaviour, the space bar, the punctuation row. A keyboard that is
5% different is worse than one that is 100% different, because the existing
reflex fires and misses. This is the same argument as
[MANIFESTO.md](../../MANIFESTO.md) §"The hard part is not the algorithm": friction
repeated thousands of times a day is the whole game.

Practical consequence: the candidate strip is the only part of the interface
allowed to differ, and the layout below it should be copied rather than
designed.

---

## 4. Two Android-specific problems the desktop model does not have

### 4.1 Neighbouring-key errors

Touch typing on glass substitutes adjacent keys — `mathematics` typed as
`nathematics`, `t` for `r`. The desktop channel model treats substitution as
uniform, which under-weights the adjacent case and over-weights the distant one.

This is a good fit for the existing architecture rather than a challenge to it.
The matcher is already a noisy channel — $P(w \mid q) \propto P(q \mid w)P(w)$ —
so a touch model is **a new substitution cost keyed on QWERTY geometry, not a
new architecture**. It slots in beside the existing channels and is tunable by
the machinery in `bench/tune.lua`.

Worth noting the direction of the effect: consonant-skeleton input means *fewer
keystrokes*, and fewer keystrokes means fewer chances to hit the wrong key. The
shorthand may turn out to be more robust on a touchscreen than full spelling,
not less. That is a measurable claim and should be measured before it is
believed.

### 4.2 Seven candidates do not fit

Gboard shows three because three is what fits across a phone at a readable
size. Showing six or seven needs an actual answer, and the options are all
trade-offs: smaller type, a horizontally scrolling strip, a two-row strip that
costs vertical space, or a strip that expands on demand. On a tablet or with a
hardware keyboard the problem disappears.

No recommendation here — this needs to be tried on a real device, and it is the
one part of the design that cannot be settled on paper.

---

## 5. What is not decided

* Whether the candidate strip can carry six or seven items on a phone at all
  (§4.2), which is prior to everything else.
* Whether to keep the voice pipeline. It is the one thing `typelessless` has
  that nothing else does, and folding it in makes part of an offline, free
  keyboard depend on API keys, a network round trip and per-utterance cost.
  That tension is real and is not resolved by putting both in one binary.
* Whether the schema-on-stock-Trime case works at all. **This is the cheapest
  experiment and it has not been run**: install the current schema into Trime's
  user directory on a device and see whether it deploys and produces
  candidates. It settles the librime-lua question in practice rather than from
  a CMake file, and it costs nothing.

---

## 6. Assessment

The engineering is smaller than it looks: Path C is a keyboard view and two
`InputConnection` hooks on top of a maintained Rime frontend that already ships
the matcher's only hard dependency.

The product question is the open one. This is a personal tool that might
generalise, and it should be built in that order — the version that is better
than Gboard *for its author*, on a tablet with a hardware keyboard and a
technical vocabulary, before any version that argues with Gboard on its own
ground.

Run the §5 experiment first.
