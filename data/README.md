# Data sources

Everything in `generated/` is reproducible from this directory:

```bash
python3 scripts/build_dictionary.py   # -> spellless.words, spellless.weights
python3 scripts/build_indexes.py      # -> spellless.alpha, spellless.skel
```

`generated/spellless.build.json` records the exact inputs, their SHA-256 sums
and the parameters each run used.

---

## `sources/frequency_dictionary_en_82_765.txt`

| | |
| --- | --- |
| **Origin** | [SymSpell](https://github.com/wolfgarbe/SymSpell), `SymSpell/frequency_dictionary_en_82_765.txt` |
| **Licence** | MIT (the whole repository, data included) |
| **Upstream provenance** | word frequencies from the Google Books Ngram corpus, intersected with the SCOWL spelling lists |
| **Format** | `word <space> count`, most frequent first, UTF-8 with a BOM |
| **Entries as vendored** | 82,834 |
| **SHA-256** | `c604e1121e398ae7c7fbf777f11e0a0f2fa66eda932cb9fba1321466cf3acd7b` |

Chosen because it is the right size (large enough to cover ordinary English,
small enough that the top candidates are not obscure), carries real corpus
frequencies rather than a rank order, is already lowercased and cleaned, and
has an unambiguous permissive licence.

### Preprocessing

`scripts/build_dictionary.py`:

1. reads it as UTF-8-with-BOM;
2. keeps tokens matching `[a-z]+`, dropping single letters other than `a` and
   `i`;
3. keeps contractions `[a-z]+'[a-z]+` only when the part after the apostrophe
   is a real English contraction ending (`t s d ll re ve m clock`) — this
   removes the one truncated artefact in the file, `you'v` — which is right,
   and left a hole, because the corpus has no `you've` to fall back on. See
   `vocab/contractions.txt`;
4. merges the supplemental vocabulary (below), keeping the larger frequency
   when a word appears in both;
4b. floors every contraction at the frequency of the word at rank
   `--contraction-rank` (default 500). The corpus gives all 64 of them the same
   tail count, which is an artefact of how it was tokenised rather than a fact
   about English — `don't` is not really rarer than the 37,000th word. Without
   this, a dropped apostrophe finds nothing;
4c. adds the apostrophe-free spelling of a contraction whenever that spelling
   is not itself a word — `youll`, `dont`, `ive` — because the apostrophe is
   the key nobody reaches for at speed. `ive` resolves to `I've`, not `ive`;
5. sorts by descending frequency, so a word's line number is its frequency
   rank;
6. writes the words, and one byte per word holding
   `round(255 · (log f − log f_min) / (log f_max − log f_min))`.

Rejected: 1 entry. Result: **83,364 entries** (82,833 kept + 481 new from the
supplemental files + 50 apostrophe-free contraction spellings).

### Known weaknesses of this corpus

Google Books skews old and literary, and keeps proper nouns as ordinary
lowercase tokens. So `mathew`, `mather` and `mathews` are all reasonably
frequent and compete with `mathematics` for the input `mathe`. Blending in a
modern subtitle or web corpus, or demoting names at build time, is the single
highest-value data change available — see DESIGN.md § 10.

---

## `vocab/*.txt` — supplemental vocabulary

Plain text, one entry per line, merged into the dictionary at build time:

```
# a comment
bordism                 # gets the default supplemental frequency
diffeomorphism  1225495 # or an explicit corpus frequency
```

`--vocab-rank N` (default 20000) sets the default frequency: supplemental words
are given the frequency of the base corpus word at rank N, i.e. "about as
common as the 20,000th English word". Words already in the base list keep the
larger of the two frequencies, so listing a common word here can only promote
it.

An entry written **with capitals** is indexed under its lowercase form and
remembers the capitals, so `grthndck` gives back `Grothendieck` and `tqft`
gives `TQFT`.

**A capital never takes the lowercase reading away.** `RAM` is offered beside
`ram`, `React` beside `react`, `Bloom` beside `bloom` — both spellings, one
keystroke apart, ordered by what you typed. There is no marker to write and no
judgement to make about whether the lowercase "really means something".

It replaces only where there is nothing to replace: a key never written in
lower case anywhere. That is looked up, not decided — the key is in the base
corpus, or some entry writes it in lower case, or it is not a lowercase word at
all. So `TQFT`, `CLI`, `Coq` and `Grothendieck` simply are their spellings, and
`ml` gets its millilitres back by appearing as its own lowercase entry one line
above `ML`.

**A spelling that opens in lower case resists the sentence capital.** `iPhone`
at the start of a sentence is `iPhone`, not `IPhone`, and the same for `eBay`,
`macOS`, `iOS`, `arXiv`, `openSUSE`, `iCloud`. Nothing marks these either — the
shape of the spelling is the statement, since nobody types a capital in the
middle of a word by accident and nothing in the program puts one there. A
spelling with no capital of its own, like `don't` or `e.g.`, takes one as it
should.

The one thing the lookup gets wrong is **names**, because this corpus keeps
proper nouns as ordinary lowercase tokens: `africa` is its 1,500th word and
looks exactly like `ram` to that test. A file says so once:

```
#!capitals replace
```

`proper_nouns.txt` and `given_names.txt` carry it, and they were already
defined that way — "words only ever written with a capital". One declaration
per file, not a judgement per entry, and the difference is measurable:
treating those 400 names as ambiguous costs **three points of top-1**.

An earlier version made the author mark each additive entry with a trailing
`+`. It was wrong twice over. It is not needed — keeping both costs one
candidate and losing one costs a word — and the judgement it asked for is one
nobody makes reliably: twelve of the first sixty markers written were wrong.

The shipped files, and what each is for:

| file | what it holds |
| --- | --- |
| `proper_nouns.txt` | words only ever written with a capital |
| `given_names.txt` | first names, so a colleague is typeable |
| `technology.txt` | acronyms, platforms and libraries the corpus is too old for |
| `internet.txt` | the 2010s and 2020s: AI, being online, the pandemic |
| `brands.txt` | platforms and products whose names are not English words |
| `contractions.txt` | the ones the base list lost or misspelled |
| `interjections.txt` | `oh`, `ah`, `ok` — absent from the base list entirely |
| `abbreviations.txt` | `eg`, `ie`, typed without their dots |
| `shorthand.txt` | `sth`, `tmrw` — typed *instead of* the word |
| `phrases.txt` | word groups that behave as one word |
| `math_sample.txt` | ~300 words of pure mathematics, as a **sample** of the mechanism |

**The bar for a capitalised entry used to be sharper than it looks**, and
`technology.txt` still states the old reasoning at length because it is worth
knowing what changed. Giving a key a written form applied it *everywhere*, so
adding `RAM` cost you the animal, and that ruled out `REST`, `POP`, `CD`,
`ARM`, `CAD`, `Bash`, `React`, `Notion`, `Fedora` and `ML`. None of them are
ruled out now, and all of them are in.

Nothing in `rime/lua/` refers to any of these files, and deleting one changes
nothing but the dictionary contents.

---

## `packs/*.txt` — vocabulary that is **not** shipped

Same format, and deliberately left out of the build. A pack is a fact about the
person typing rather than about English: topology terminology is excellent if
you work on topology and clutter if you do not, and provinces of China and
British institutions are the same kind of thing. Shipping them would make every
user carry someone else's vocabulary.

```bash
python3 scripts/import_pack.py --list
python3 scripts/import_pack.py topology china
```

| pack | what it holds |
| --- | --- |
| `topology.txt` | names, objects and adjectives from topology and geometry |
| `software.txt` | computer science and software engineering, past what everyone needs |
| `britain.txt` | British institutions, mostly acronyms |
| `china.txt` | provinces, and words English borrowed |

The importer writes into `<rime user dir>/spellless_user.txt` — the same file
the matcher already writes what you teach it into, read at startup,
hand-editable, and never touched by an upgrade. It is idempotent, and a word
already there keeps whatever count it has earned: a pack must never undo your
own history. Words arrive with a starting familiarity of 4; the script's
docstring carries the measurement behind that number, including what it costs
ordinary English, which is nothing.

A capitalised entry in a pack **does not need a `+`**, and a pack may carry
`Bloom`, `Raft`, `Prim` and `Ford` without costing you the flower, the boat or
two ordinary words. A spelling you teach or import leads, and the dictionary's
own lowercase reading stays one keystroke behind it; picking that twice makes
it the default again, through the ordinary correction mechanism.

The rule is the same one `+` expresses, read off the dictionary instead of
written by hand: **a key keeps its lowercase reading unless the dictionary
issued it a spelling.** `latex`, `ok`, `pc`, `dijkstra` and `bloom` are read as
lowercase words and keep that reading; `tqft`, `macos` and `cli` were given a
form and have no second reading to lose, so they gain no companion candidate.
Nothing has to guess whether the lowercase is "really a word" — which is just
as well, because corpus rank cannot: `bloom` is the 8,858th token and `shannon`
the 8,139th, and `prim` at 27,141 is rarer than `turing` at 22,189.

Writing your own pack needs no tooling — it is a text file in this format, and
`import_pack.py` takes a path as readily as a name.

---

## `forms.txt` — surface forms

The corpus is lowercase throughout, and Spellless otherwise recovers
capitalisation from how you typed. This file covers the one class that cannot
work for: words with **no valid lowercase form**.

```
i	I
i'd	I'd
```

That criterion is the whole rule, and it is deliberately strict. `march`/`March`
and `may`/`May` must not be listed, because the lowercase word is a real one and
listing it would make the verb unreachable. The build warns about any key that
is not in the dictionary.

---

## Licences

* Spellless code: MIT.
* `sources/frequency_dictionary_en_82_765.txt`: MIT, © Wolf Garbe / SymSpell
  contributors.
* `vocab/math_sample.txt` and `packs/*.txt`: written for this project, MIT.
