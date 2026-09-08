# British and American spelling, as a switch

Written 2026-09-08. **A proposal; nothing is built.** It describes a feature
that hides the spellings of the variant you do not write, and an implementation
whose whole footprint is one new module, one new data file, one new switch and
one changed predicate.

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
first. The cause is corpus frequency, and the margin is nothing at all:

| | rank | | rank |
| --- | ---: | --- | ---: |
| `color` | 2716 | `colour` | 2717 |
| `center` | 913 | `centre` | 914 |
| `realize` | 4613 | `realise` | 11640 |

One rank apart. The vendored frequency list is Google Books ∩ SCOWL, and Google
Books is American-dominated, so **which dialect leads is decided by corpus
noise rather than by anything about the person typing.**

The same corpus fails the other dialect harder. Of 59 hand-checked variant
pairs, 30 ship both forms, **29 ship only the British form, and none ship only
the American**:

> `colors`, `colored`, `favorite`, `neighbor`, `labor`, `humor`, `harbor`,
> `rumor`, `centers`, `theater`, `caliber`, `somber`, `analyze`, `paralyze`,
> `catalyze`, `offense`, `pretense`, `traveled`, `traveling`, `canceled`,
> `modeling`, `marvelous`, `catalog`, `aluminum`, `plow`, `jewelry`,
> `skeptical`, `mustache`, `pajamas`

These are absent from the vendored SymSpell list itself, not lost in our
preprocessing. So the position today is bad in both directions at once: a
British writer is offered American spellings first, and an American writer
cannot type several ordinary words at all.

## 2. What the feature is

**Hide, do not reorder.** With British on, `color` is not offered as a
candidate — not at position 2, not at position 8. Demotion is the wrong answer:
a spelling you never write is clutter wherever it sits on the page.

Two cases, which differ only in what the literal is:

| you type | with British on |
| --- | --- |
| `clr` | `colour` is offered; **`color` appears nowhere**; slot 7 is `clr` |
| `color` | `colour` leads; `color` appears **only in slot 7**, because it is what you typed |

Slot 7 is not an exception to this feature. It is a different guarantee —
*"commit what I typed"*, `docs/USING.md` §"The literal text you typed is always
on the first page" — and the feature never touches it.

One thing worth stating plainly, because it is a first for this project: with
the switch on, **an exact dictionary hit is deliberately overruled**. Typing
`color` in British mode means "treat this as a misspelling of `colour`". That is
what a British spell checker does, and slot 7 keeps it honest, but it is the
only place the matcher lets a non-exact reading beat an exact one.

## 3. What everyone else does

| approach | who | fit for us |
| --- | --- | --- |
| **A dictionary per variant** | Hunspell (`en_GB-ise`, `en_GB-ize`, `en_GB-large`, `en_US`), Gboard/iOS/macOS locale packs, cSpell | The "make it disappear" model. SCOWL's defaults deliberately ship **one spelling per word** to encourage consistency, with `-large` carrying both — the same choice this proposal makes |
| **One lexicon, variant tags** | [VarCon](https://wordlist.aspell.net/varcon-readme/), now the [English Speller Database](https://github.com/en-wl/wordlist) | The data layer the others are built from. Our dictionary is already SCOWL-derived, so this is the natural join |
| **Flag, do not hide** | LanguageTool, Word (language per text run) | Wrong shape — there is no candidate list to prune |
| **Convert on output** | Rime's own `simplifier` + OpenCC, `s2tw`/`s2twp`, driven by a schema switch; `s2twp` converts regional *vocabulary* (软件 → 軟體) | The closest analogue in our own platform, but it rewrites a candidate rather than removing one |
| **Hard drop** | Rime `charset_filter` | The one mainstream Rime mechanism that makes candidates vanish |

## 4. Five traps, which are all data problems

These decide the contents of the table, not the code.

1. **`-ise`/`-ize` is not the GB/US axis.** Oxford spelling is British *and*
   uses `-ize`, and it is the house style for academic writing. Hunspell ships
   three British dictionaries for exactly this. British must therefore be two
   settings, or the feature deletes `realize` from an Oxford thesis.
2. **Pairs are not symmetric.** `programme` is British-only, but `program` is
   correct in both — British uses it for software. `program` must never be
   hidden. A symmetric pair list cannot express this; the table must say, per
   word, which mode hides it.
3. **Spelling is not vocabulary.** `lorry`/`truck`, `pavement`/`sidewalk` are
   lexical and understood everywhere. Hiding `truck` from a British writer is
   absurd. Orthographic variants only.
4. **Some British pairs are not variants at all.** `licence`/`license` and
   `practise`/`practice` are both British, distinguished by part of speech.
   Hiding either breaks British writing outright.
5. **Proper nouns are spelled the way they are spelled.** `colorado` is at
   position 8 for `clr`; `labor` (Labor Party), `harbor` (Pearl Harbor),
   `center` (World Trade Center). A rule over word endings would catch these.
   VarCon does not. **This is why the table is vendored data and not a regex.**

---

## 5. Implementation

The design goal is that this feature can be added, and removed, without
touching the matcher. It reuses a suppression path that already ships.

### 5.0 Prerequisite — close the coverage gap

**You cannot hide one variant until both exist.** Add the 29 missing American
forms (and whatever a full VarCon pass finds beyond them) through the existing
supplement mechanism: a new `data/vocab/variants_us.txt`, merged by
`scripts/build_dictionary.py` step 4 like every other `vocab/*.txt` file.

This is worth doing on its own account, before any switch exists. It is a
straight bug fix: `analyze` and `theater` should be typeable today.

### 5.1 Data — one vendored table, one generated file

Vendor a curated table derived from VarCon at `data/sources/varcon-pairs.txt`,
with its origin, licence and SHA-256 recorded in `data/README.md` exactly as
the frequency list is, so `generated/spellless.build.json` keeps it
reproducible. **Check the licence before vendoring** and record the terms; the
repository documents provenance for every source and this must not be the
exception.

The build emits `generated/spellless.variants` — one line per word, naming the
modes that hide it, which is what trap 2 requires:

```
# word        hidden in
color         gb
colors        gb
colour        us
programme     us
realize       gb-ise        # British -ise only; correct under Oxford spelling
realise       us
```

Words correct everywhere — `program`, `colorado`, `practice`, `license` — are
simply absent from the file. Absence is the safe default.

Order of magnitude: a few thousand lines, tens of kilobytes, loaded only when a
variant mode is on.

### 5.2 A new module — `rime/lua/spellless/variants.lua`

The only new code of consequence. It loads `spellless.variants` lazily on first
use, keeps one set per mode, and exposes:

```lua
variants.load(data_dir)        -- lazy; a no-op when the mode is off
variants.hidden(word, mode)    -- true if `word` is not written in `mode`
```

`mode` is one of `off`, `gb-ise`, `gb-ize`, `us`. With `off` — the default —
nothing is loaded and `hidden` is always false, so the feature costs a single
comparison and no memory until somebody turns it on.

### 5.3 The matcher — one predicate, at a site that already exists

`engine.lua:607–613` already filters the candidate list before ranking, for the
personal *"never offer me this one"* list that shipped in 0.1.5:

```lua
if self.user:has_suppressions() then
  local kept = {}
  for i = 1, #items do
    if not self.user:is_suppressed(items[i].word) then kept[#kept + 1] = items[i] end
  end
  items = kept
end
```

The change is to widen that predicate to
`is_suppressed(w) or variants.hidden(w, mode)`, and to enter the block when
either source has something to say. **That is the entire contact with the
matcher.**

It lands in the right place for free. The comment immediately above it reads
*"The literal is placed later and is untouched: 'commit what I typed' holds"* —
so slot 7 needs no special case, and the `clr` case and the `color` case both
come out correct from the same filter. Ranking, scoring, the indexes and
`userdb` are untouched.

### 5.4 The switch

A radio switch in `rime/spellless.schema.yaml`, beside the four that already
exist:

```yaml
  - options: [ spelling_off, spelling_gb_ise, spelling_gb_ize, spelling_us ]
    states:  [ "both spellings", "British -ise", "British -ize (Oxford)", "American" ]
    reset: 0
```

`reset: 0` means it ships **off**, and an existing user sees no change until
they choose otherwise. Rime radio options are ordinary boolean options with
exactly one set, so the adapter reads them the way it reads the others: add the
names to `SWITCHED` in `rime/lua/spellless.lua:376`, and read them through the
existing `feature()` path.

`zzver` should report the active mode, for the reason the other switches are
reported — *"I turned it on and nothing happened"* is nearly always *"that is
not what is on"*.

### 5.5 Tests and measurement

* `tests/cases/variants.tsv`, in the existing case-file format: `clr → colour`
  under `gb-ise`, `clr → color` under `us`, `program` unhidden in both,
  `realize` present under `gb-ize` and hidden under `gb-ise`, `colorado`
  present in all modes.
* A regression that the literal still reaches slot 7 for `color` under `gb-ise`.
* `make bench` with the switch off, to show the default path is unchanged —
  this is the number that proves the feature is inert until asked for.

### 5.6 What is deliberately not touched

Ranking and scoring; the alpha and skeleton indexes; slot 7; `userdb`'s own
suppression semantics; the dictionary weights. No word is removed from
`generated/spellless.words` — hiding is a runtime decision, so switching modes
takes effect without a rebuild.

### 5.7 Why this is self-contained

* **Off by default**, and off costs one comparison.
* **One new module**, `variants.lua`, with no dependencies on the rest.
* **One new generated file**, loaded lazily, never rebuilt for a mode change.
* **One widened predicate** at a filter site that already exists for another
  feature.
* **Removal is deletion**: drop the module, the data file, the switch, and
  restore the predicate to its current form. Nothing else has learned about
  variants.

---

## 6. Open questions

* **Which VarCon edition, and under what licence.** Prerequisite to 5.1, and
  the one thing that could change the whole approach if it turns out
  unvendorable.
* **How wide the pairs go.** Most are within one or two edits — `colour`/`color`
  is a deletion, `centre`/`center` a transposition — so the matcher already
  crosses them. `programme`/`program`, `plough`/`plow`, `jewellery`/`jewelry`,
  `encyclopaedia` are wider. Once hiding is in, measure whether the surviving
  form is actually reachable from the input a person would type; if not, those
  few pairs need an explicit alias and nothing else does.
* **Australian and Canadian.** VarCon carries both. They are more modes in the
  same switch and no new mechanism, but each is a curation job, and neither
  should be shipped without somebody who writes that way checking the table.
* **Whether `off` is the right default.** It is the conservative choice and the
  one this proposal makes. The argument for defaulting to a dialect is that the
  corpus is already making the choice, badly, and silently.
