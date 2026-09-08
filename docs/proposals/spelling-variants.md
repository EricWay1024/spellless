# British and American spelling, as a switch

Written 2026-09-08, revised the same day after review. **A proposal; nothing is
built.** It describes a feature that hides the spellings of the variant you do
not write, and an implementation whose contact with the matcher is a single
widened predicate.

---

## 1. The problem, measured

Ask the matcher for `clr` today:

```
   1 clear
   2 color        ← American, ahead of the British form
   3 colour
   4 culture
   5 calendar
   6 clark
  .7 clr          ← the literal, in its usual slot
   8 colorado
```

A British writer typing a consonant skeleton is offered the American spelling
first. **The cause is our own tie-break, not the corpus.**

The vendored list treats variant pairs three different ways, and that
inconsistency is the real defect:

| in `frequency_dictionary_en_82_765.txt` | line | count | |
| --- | ---: | ---: | --- |
| `colour` | **2591** | 29,049,269 | one count, shared |
| `color` | 2592 | 29,049,269 | |
| `centre` | **789** | 97,258,243 | one count, shared |
| `center` | 790 | 97,258,243 | |
| `realize` | 4486 | 14,098,493 | two counts, unshared |
| `realise` | 11508 | 3,432,591 | |
| `favourite` | 2985 | 24,206,461 | merged onto one spelling |
| `favorite` | — | *absent* | |

1. **Shared count.** `colour`/`color` and `centre`/`center` carry *identical*
   counts, and the British form comes **first in the source file**. They ship
   the other way round because `scripts/build_dictionary.py:201` sorts by
   `(-count, word)` — ties break **alphabetically**, and American variants are
   systematically alphabetically earlier: `color` < `colour`, `center` <
   `centre`, `catalog` < `catalogue`, `favorite` < `favourite`. The dialect
   that leads is decided by an incidental tie-break in our build.
2. **Unshared count.** `realize`/`realise` are counted separately, 14.1M
   against 3.4M, so here the corpus really does decide, and decides American.
3. **Merged onto one spelling.** `favourite` carries 24.2M and `favorite` is
   absent entirely. 24.2M is not a British-corpus number; it is the pair's
   combined count wearing the British spelling.

Class 3 is why coverage is broken. Of 59 hand-checked pairs, 30 ship both
forms, **29 ship only the British form, and none ship only the American**:

> `colors`, `colored`, `favorite`, `neighbor`, `labor`, `humor`, `harbor`,
> `rumor`, `centers`, `theater`, `caliber`, `somber`, `analyze`, `paralyze`,
> `catalyze`, `offense`, `pretense`, `traveled`, `traveling`, `canceled`,
> `modeling`, `marvelous`, `catalog`, `aluminum`, `plow`, `jewelry`,
> `skeptical`, `mustache`, `pajamas`

So today a British writer is offered American spellings first *because of our
sort*, and an American writer cannot type several ordinary words *because of
the source*. Both are fixable at build time, and §5.0 does it.

## 2. What the feature is

**Hide, do not reorder.** With British on, `color` is not offered as a
candidate — not at position 2, not at position 8. A spelling you never write is
clutter wherever it sits.

Two cases, which differ only in what the literal is:

| you type | with British on |
| --- | --- |
| `clr` | `colour` is offered; **`color` appears nowhere**; slot 7 is `clr` |
| `color` | `colour` leads; `color` appears **only in slot 7**, because it is what you typed |

Slot 7 is a different guarantee — *"commit what I typed"* — and the feature
never touches it.

### 2.1 But reachability is not the guarantee at risk

The first draft of this proposal claimed slot 7 made the exact-hit case safe.
It does not, and `docs/ALGORITHM.md` §1.1 says why:

> Silently converting a deliberate token into an English word is the one
> failure that corrupts a document without the user noticing.

The words on this list are **disproportionately deliberate tokens**: `color` is
a CSS property, `center` an HTML and LaTeX environment, `analyze` and `catalog`
are function and API names, `labor` and `harbor` are proper nouns. A British
writer with the switch on types `color` in a code fragment, hits space out of
habit, and commits `colour`. The literal being reachable in slot 7 is no help,
because what failed was the space bar, not reachability.

**Two fixes, both reusing machinery that ships.**

*Make the conversion visible.* `confirm_literal` (`config.lua:541`) already
swallows the first space and commits on the second, for the case where nothing
in the dictionary fits. Give it a second trigger: when the input is **exactly**
a hidden word, the survivor still leads, but the first space is ignored. Return
still commits immediately, as it always did.

*Let the user overrule it.* Committing the hidden literal from slot 7 a small
number of times unhides that word for that user, written to the personal file
like every other learned preference. This is the project's existing
"explainable and undoable" contract, and it dissolves the open question about
learned entries: if commits can unhide, a word you have chosen is never hidden
from you.

## 3. What everyone else does

| approach | who | fit for us |
| --- | --- | --- |
| **A dictionary per variant** | Hunspell (`en_GB-ise`, `en_GB-ize`, `en_GB-large`, `en_US`), Gboard/iOS/macOS locale packs, cSpell | The "make it disappear" model. SCOWL's defaults ship **one spelling per word** to encourage consistency, `-large` carries both — the same choice this proposal makes |
| **One lexicon, variant tags** | [VarCon](https://wordlist.aspell.net/varcon-readme), now the [English Speller Database](https://github.com/en-wl/wordlist) | The data layer the others are built from, and our source |
| **Flag, do not hide** | LanguageTool, Word (language per text run) | Wrong shape — there is no candidate list to prune |
| **Convert on output** | Rime's `simplifier` + OpenCC, `s2tw`/`s2twp`, driven by a schema switch | The closest analogue on our own platform, but it rewrites a candidate rather than removing one |
| **Hard drop** | Rime `charset_filter` | The one mainstream Rime mechanism that makes candidates vanish |

## 4. Five traps, which are all data problems

1. **`-ise`/`-ize` is not the GB/US axis.** Oxford spelling is British *and*
   uses `-ize`; it is the house style for academic writing. So British is two
   modes. Further: **Oxford keeps `-yse`** — `analyse`, `paralyse`, `catalyse`
   — so `analyze` is hidden under **both** British modes, while `realize` is
   hidden under `gb-ise` only. And a third class is `-ise` in every dialect:
   `advertise`, `surprise`, `exercise`, `compromise`, `supervise`. These must
   be absent from the table entirely, which no ending rule can get right.
2. **Pairs are not symmetric.** `programme` is British-only, but `program` is
   correct in both. `program` must never be hidden.
3. **Spelling is not vocabulary.** `lorry`/`truck`, `pavement`/`sidewalk` are
   lexical and understood everywhere. Orthographic variants only.
4. **Some pairs are part-of-speech distinctions, not variants.** `licence`/
   `practise` are both British, split by part of speech, so neither is hidden
   in a British mode. **They are hidden in `us` mode**, because American uses
   `license` and `practice` for both parts of speech.
5. **Proper nouns are spelled the way they are spelled.** `colorado` is at
   position 8 for `clr`; `labor`, `harbor`, `center` all appear in names. An
   ending rule catches these. VarCon does not.

---

## 5. Implementation

### 5.0 Prerequisite — fix the frequencies at build time

This is the largest change and it is not optional, because it is what makes
everything downstream a simple post-filter.

For each variant group, `build_dictionary.py` should:

* **add any missing member**, from a new `data/vocab/variants_us.txt` merged by
  the existing step 4;
* **give every member the group's frequency**, so a supplemented `favorite`
  inherits `favourite`'s 24.2M rather than whatever default a `vocab/*.txt`
  entry receives. Without this, an American writer typing `fvrt` **with the
  switch off** sees `favourite` far above `favorite` — a worse version of the
  bug being fixed;
* **break the tie deliberately.** Ties currently fall to alphabetical order,
  which silently favours American. Replace that with an explicit default
  dialect in the group table, so that which form leads with the switch off is a
  decision somebody made.

**Consequence to measure, not wave through.** Levelling `realise` to
`realize`'s count moves it from rank 11508 to about 4486, which changes its
ranking against *unrelated* words for everyone, switch off included. That is
defensible — the split is a corpus artefact and the pair is one word for
frequency purposes — but it is a real change and `make bench` has to show what
it costs.

This step also removes the need for any runtime frequency override, which is
what keeps §5.3 to one contact point.

### 5.1 Data — groups with mode tags, not a hide list

A per-word "hidden in" column throws away the pairing, and three things need
it: frequency inheritance (§5.0), pair-max scoring (§5.0), and aliasing (§5.2).
So each line is a **group**, which is VarCon's own shape:

```
# members                     tags                default
colour        color           B Z / A             colour
programme     program         B / A B             programme     # program is both
realise       realize         B / A Z             realise
analyse       analyze         B Z / A             analyse        # -yse survives Oxford
plough        plow            B Z / A             plough
licence       license         B Z / A             licence        # part-of-speech in GB
```

Words correct everywhere — `advertise`, `surprise`, `program`, `colorado`,
`practice` — are simply absent. **Absence remains the safe default.**

Source: **VarCon 2020.12.07**, © Kevin Atkinson and Benjamin Titze. Its main
file tags each spelling `A` American, `B` British `-ise`, `Z` British `-ize`/OED,
`C` Canadian, `D` Australian, plus variant markers — a one-to-one map onto our
four modes and the two future ones. The licence permits use, copy, modify,
distribute and sell for any purpose provided the copyright and permission
notice appear, so vendoring is fine **with attribution recorded in
`data/README.md`** alongside the frequency list, and its SHA-256 in
`generated/spellless.build.json`.

**First-pass rule:** hide only entries tagged as the plain other-dialect
spelling; leave anything tagged as a variant *within* the target dialect alone.
That is what encodes trap 2 — `program` is tagged both `A` and `B`.

### 5.2 Aliases, for the pairs the matcher cannot cross

Measured against `typo_budget = 1.35`:

| pair | distance | |
| --- | ---: | --- |
| `centre` → `center` | 0.45 | reachable |
| `colour` → `color` | 0.70 | reachable |
| `encyclopaedia` → `encyclopedia` | 0.70 | reachable |
| `pyjamas` → `pajamas` | 1.00 | reachable |
| `jewellery` → `jewelry` | 1.25 | reachable |
| `programme` → `program` | 1.25 | reachable |
| `catalogue` → `catalog` | **1.40** | **stranded** |
| `plough` → `plow` | **2.70** | **stranded** |

Most pairs are well inside the budget, so hiding alone suffices. The stranded
few need the group to act as an alias: when a hidden member is generated,
offer the surviving member in its place, at no extra search — which the group
file makes free. The review's worry was right; the affected set is smaller than
feared, and `jewellery`/`jewelry` in particular is reachable at 1.25.

### 5.3 A new module, and one predicate

`rime/lua/spellless/variants.lua` loads the group file lazily and exposes
`hidden(word, mode)` and `survivor(word, mode)`. With `mode = off` — the
default — nothing loads and `hidden` is always false.

`engine.lua:607–613` already filters candidates before ranking, for the
personal *"never offer me this one"* list from 0.1.5:

```lua
if self.user:has_suppressions() then
  local kept = {}
  for i = 1, #items do
    if not self.user:is_suppressed(items[i].word) then kept[#kept + 1] = items[i] end
  end
  items = kept
end
```

Widen the predicate to `is_suppressed(w) or variants.hidden(w, mode)`, enter
the block when either has something to say, and substitute the survivor for a
stranded pair. **That is the whole contact with the matcher**, and it sits
directly under the comment *"The literal is placed later and is untouched"*, so
slot 7 needs no special case.

**Why one contact point is enough.** Candidate generation truncates before this
filter — `max_prefix = 12` completions, bounded skeleton completions,
`max_checks = 1200` evaluations over frequency-ordered buckets — so filtering
afterwards could in principle leave nothing, if the hidden form made the cut
and the survivor did not. Buckets are ordered by id and id is rank, so a
*runtime* frequency override could not reorder them. **§5.0 is what makes this
a non-issue:** once both members carry the group frequency, they sit at
adjacent ranks in the shipped data, so either both clear a ceiling or neither
does. The fix belongs at build time precisely so the runtime stays a
post-filter.

Residual, to be documented rather than fixed: the matcher's other "is the query
a dictionary word" gates — which skip the cue channel and the splitter — still
fire for a hidden exact hit, because the matcher is not being told about
variants. That is intended. The survivor is always reachable by the typo path
or, for the stranded pairs, the alias.

### 5.4 The switch

```yaml
  - options: [ spelling_off, spelling_gb_ise, spelling_gb_ize, spelling_us ]
    states:  [ "both spellings", "British -ise", "British -ize (Oxford)", "American" ]
    reset: 0
```

Ships **off**. Rime radio options are ordinary booleans with exactly one set, so
add the names to `SWITCHED` in `rime/lua/spellless.lua:376` and read them
through the existing `feature()` path. `zzver` reports the active mode.

### 5.5 Tests and measurement

* `tests/cases/variants.tsv`: `clr → colour` under `gb-ise`, `clr → color`
  under `us`, `program` unhidden in both, `realize` present under `gb-ize` and
  hidden under `gb-ise`, `analyze` hidden under **both** British modes,
  `advertise` never hidden, `colorado` present in every mode.
* **An added American form inherits its group's frequency with the switch
  off** — `fvrt` must not put `favourite` above `favorite`.
* **A stranded pair is reachable through the alias** in each mode — `plough`
  under `us` must reach `plow`.
* **A hidden exact input does not commit its survivor on one space** — typing
  `color` under `gb-ise` and pressing space once commits nothing.
* The literal still reaches slot 7 for `color` under `gb-ise`.
* `make bench` twice: switch off, to price §5.0's frequency levelling; and
  switch on, to show the feature's own cost.

### 5.6 What is deliberately not touched

Ranking and scoring; the alpha and skeleton indexes; slot 7; `userdb`'s
suppression semantics. No word leaves `generated/spellless.words`, so changing
mode never needs a rebuild.

### 5.7 Why this is self-contained

Off by default and off costs one comparison. One new module with no
dependencies. One new generated file, loaded lazily. One widened predicate at a
filter site that already exists. Removal is deletion — nothing else has learned
about variants.

The build-time half (§5.0) is *not* self-contained, and should not pretend to
be: it changes shipped frequencies for everyone. It is also worth doing on its
own account, before any switch exists, because `analyze` and `theater` should
be typeable today.

---

## 6. Open questions

* **Australian and Canadian.** VarCon carries both (`C`, `D`). More modes in
  the same switch, no new mechanism, but each is a curation job that needs
  somebody who writes that way to check it.
* **How far §5.0's levelling moves the benchmark.** If it costs measurable
  accuracy on the default path, the fallback is to level frequencies only
  within a mode and accept the §5.3 truncation risk — which reopens the
  question of whether the matcher needs a second contact point.
* **Whether `off` stays the default.** It is the conservative choice. The
  argument against is that with §5.0 in place the tie-break becomes deliberate,
  at which point defaulting to a dialect is a decision rather than an accident.
