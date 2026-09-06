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

Rejected: 1 entry. Result: **83,169 entries** (82,833 kept + 286 new from the
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
remembers the capitals as a surface form, so `grthndck` gives back
`Grothendieck` and `tqft` gives `TQFT`. Only write capitals where the lowercase
spelling would be wrong — `Noether` yes, `manifold` no, and `latex` and
`noetherian` deliberately not, because their lowercase readings are real.

`vocab/math_sample.txt` is a **sample**, provided to demonstrate the mechanism.
It contains around 300 words of pure mathematics, its working vocabulary and
the names that go with it. Nothing in `rime/lua/` refers to it, and deleting it
changes nothing but the dictionary contents.

For vocabulary you want to add without rebuilding, use the personal file
instead — `<rime user dir>/spellless_user.txt`, same format, read at startup.

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
* `vocab/math_sample.txt`: written for this project, MIT.
