# Decoding lossy English input

**A self-contained description of the Spellless matching algorithm, the
constraints that shaped it, and the problems it has not solved.**

Written for someone who has never seen the codebase. Nothing here assumes
knowledge of Rime, Lua, or input methods. Everything measurable is measured;
where a number is a guess it says so. The last section is a list of open
problems, which is the reason this document exists.

Source: <https://github.com/EricWay1024/spellless>.
Reproduce every number with `make test && make bench`.

---

## 1. The problem

A person knows a word and cannot reliably produce its spelling at the speed
they think. They type an approximation. The system must return a short ranked
list containing the word they meant, fast enough that typing does not stutter.

**Formally.** A dictionary `D` of `N = 83,095` English words, each carrying a
normalised log-frequency `f(w) ∈ [0,1]`. A query `q ∈ Σ*` where
`Σ = {a…z, '}`. Return an ordered list `C = (c₁ … c_k)`, `k ≤ 20`, of strings,
with `q` itself guaranteed to appear somewhere in it. Maximise

- **P(intended = c₁)** — top-1, the primary objective, and
- **P(intended ∈ c₁…c₅)** — top-5, a close second.

Top-5 matters almost as much as top-1 because the user is looking at the list.
A wrong first candidate costs one glance and one digit key. A *missing*
candidate costs the entire interaction: the user must abandon the word, retype
it letter by letter, or commit a misspelling.

### 1.1 What makes this different from spelling correction

**The noise is deliberate and structured, not accidental.** `mthmtcs` is not a
misspelling of `mathematics`; it is a lossy encoding the user chose. Under any
uniform edit metric the two are four deletions apart, which is further than
`mathematics` is from dozens of unrelated words. The interesting queries are
*not* in the low-distance neighbourhood of their answer.

**The user is in the loop, so the loss function is not symmetric.** Autocorrect
must be right or silent, because a wrong guess lands in the document unseen.
This system may propose seven readings and be wrong about six of them, provided
the seventh is there. That inverts the usual precision/recall trade: recall at
5 is cheap to buy and expensive to lose.

**The literal must always be reachable.** `kubectl`, `argmax`, `TQFT`, a
surname, a variable name — the system must never make it hard to commit exactly
what was typed, and must lead with it when nothing else is trustworthy.
Silently converting a deliberate token into an English word is the one failure
that corrupts a document without the user noticing.

### 1.2 What makes it different from an ordinary IME

A Chinese input method decodes pinyin: a **complete and lossless** phonetic
encoding, with a dictionary keyed by that encoding, and a large body of users
who all encode the same way. Shuangpin layouts compress it, but they are
*codebooks* — learned once, applied consistently.

Here there is no encoding and no codebook. The user decides, per word and per
occasion, how much of the spelling to type, and they are not consistent with
themselves. The same person writes `strtfctn` one day and `satfcatn` the next.
Any design that requires them to be consistent has changed the problem into an
easier one they did not ask for.

---

## 2. Constraints

These are not incidental. They are most of what makes this a problem rather
than an application of a known technique.

| | |
| --- | --- |
| **Latency** | Runs on every keystroke inside the IME process. ~2.5 ms mean, under 10 ms at p95. Single-threaded interpreted Lua 5.4, no JIT. |
| **Scale of the budget** | A naive weighted edit distance against all 83,095 words, *with* the budget and early abort, costs **144 ms per query**. The budget is therefore about 1/60th of a full scan. |
| **Memory** | ~17 MB resident, ~100 ms to load, once per process. |
| **Dependencies** | None. Pure Lua, no compiled extension, no network, no GPU. The shipped data is 1.3 MB. |
| **No context** | One composition is one word. The preceding word is available only as an unreliable string of what the IME itself last committed — a mouse click that moves the caret is invisible. There is no sentence, no document, no application state. |
| **No training data** | There is no keystroke log. No corpus of (what a person typed, what they meant) exists for this task. Every weight was fitted on constructed cases. |
| **Inspectability** | A wrong answer must be explainable to the user, and learning must be undoable with one keystroke. |

The no-context and no-training-data constraints are the interesting ones. They
rule out the two techniques that would obviously help — a language model over
the sentence, and a discriminative model trained on real user behaviour — and
what remains is a search problem with a hand-built scoring function.

---

## 3. Data

**Dictionary.** The SymSpell English frequency list (Google Books Ngram ∩
SCOWL, MIT-licensed, 82,834 entries as vendored), filtered to `[a-z]+` plus
genuine contractions, merged with 771 hand-added entries — technical
vocabulary, proper nouns, given names, multi-word phrases, deliberate
shorthand. **83,095 entries.**

One preprocessing step is worth noting because it is a general hazard: the
corpus gives all 64 contractions the same tail count, which is an artefact of
how it was tokenised rather than a fact about English (`don't` is not really
rarer than the 37,000th word). They are floored at the frequency of rank 500.
Without that, a dropped apostrophe finds nothing at all.

**Frequencies.** One byte per word:
`round(255 · (log f − log f_min)/(log f_max − log f_min))`. Word ids are
1-based line numbers in descending frequency order, so **a word's id is its
frequency rank** and any set of ids can be ranked without a sort.

**Precomputed indexes** (u24 arrays of word ids, 249 kB each):

- `alpha` — ids sorted alphabetically → exact and prefix lookup by binary search
- `skel` — ids sorted by consonant skeleton → abbreviation lookup

**Derived at load** (~90 ms, cheaper than shipping and parsing):

- a 26-bit letter-presence mask per word
- buckets by `(word length, first letter)` and by `(skeleton length, first
  letter)`, each already in frequency order

**Surface forms.** A separate table mapping a lowercase dictionary key to what
should actually be committed: `i → I`, `dont → don't`, `eg → e.g.`,
`hongkong → Hong Kong`, `infrontof → in front of`, `sth → something`. This is
how a lowercase, letters-only dictionary can commit capitals, apostrophes, dots
and spaces. Keys never contain spaces, so a phrase is a single token to the
matcher.

The corpus is the weakest part of the system and is discussed again in §8.

---

## 4. The algorithm

Two stages. **Generate** a few dozen candidates from five sources plus the
user's own vocabulary, then **score** them all with one additive function. No
source has priority by construction; the ranking decides.

```
query
  │
  ├── exact / prefix ──────── binary search of the alphabetical index
  ├── typo ───────────────── bucketed scan + weighted edit distance
  ├── skeleton ───────────── skeleton index + scan, then elastic re-pricing
  ├── syllable cue ───────── first-letter buckets + subsequence alignment
  ├── personal vocabulary ── linear pass over what you have committed
  ├── word split ─────────── word-break dynamic program        (placed, not ranked)
  └── shortcuts ──────────── your own abbreviation file        (placed, not ranked)
                │
                ▼
        one additive score
                │
                ▼
     ranked list + the literal input
```

### 4.1 The cost model: a weighted OSA distance

Everything numeric rests on one function: Damerau–Levenshtein restricted to
non-overlapping adjacent transpositions (the OSA variant — the restriction is
irrelevant for single words and keeps the recurrence to three rolling rows).

Every edit has its own price, because English fast-typing errors are not
uniformly likely:

| Edit | Cost | Example |
| --- | --- | --- |
| dropped apostrophe | 0.15 | `dont`, `its`, `id` — a typographic shortcut, not a spelling error |
| adjacent transposition | 0.45 | `teh`, `theorme`, `recommned` |
| miscounted double letter | 0.55 | `commited`, `harrass`, `accomodate` |
| dropped or doubled vowel | 0.70 | `seperate`, `definately` |
| neighbouring key | 0.70 | `nirth` → `north`, from a QWERTY layout with real key offsets |
| vowel for vowel | 0.75 | |
| anything else | 1.00 | |

The doubling rule was worth more than any other single change: `commited`
reaches `commuted` for 0.70 (a neighbouring key) but needed 1.00 to reach
`committed`, so the wrong word won.

Two implementation notes that matter for anyone re-deriving this:

- **The band is derived, not guessed.** Reaching a cell `d` columns off the
  diagonal when the strings differ in length by `δ` requires at least `2d − δ`
  insertions or deletions, so
  `band = ⌊(budget / cheapest_indel + δ)/2⌋`, and the comparison is abandoned
  outright if that band cannot reach the far corner.
- **The abort needs two consecutive over-budget rows, not one.** A
  transposition reads the row *two* back, so a row can exceed the budget and
  the next still recover through it. Aborting on one row silently discarded
  `ifnomration → information` (two transpositions, total cost 0.90) — a bug
  that survived a hand-written reference-implementation test, because no pair
  in that test's word list happened to need the recovery.

Three profiles instantiate the same DP:

- **TYPO** — the table above.
- **SKELETON** — vowel discounts switched off, because both sides are already
  vowel-free.
- **ELASTIC** — deliberately asymmetric: a vowel the typist *omitted* costs
  0.10 to insert, a vowel they *actually typed* costs 0.90 to delete. Used with
  `prefix_distance`, which takes the minimum over the *final row* of the DP
  rather than its last cell — that is, "the best alignment of the query against
  any prefix of the word".

The asymmetry in ELASTIC is load-bearing. Without it, `mathe` (skeleton `mth`)
matches `mouth` exactly as cheaply as `mthmtcs` matches `mathematics`: the
vowels the user typed are evidence, and deleting them has to cost real money.

### 4.2 A worked cost table

The clearest statement of why there are four cost models rather than one. Each
column is the same pair of strings under a different one, against that model's
budget; the bold figure is the one that actually finds the word.

| query | word | typo ≤1.35 | skeleton ≤1.30 | elastic ≤1.70 | cue ≤2.10 |
| --- | --- | --- | --- | --- | --- |
| `teh` | the | **0.45** | 0.00 | 0.45 | — |
| `recieve` | receive | **0.45** | 0.00 | 0.45 | — |
| `commited` | committed | **0.55** | 0.55 | 0.55 | 0.35 |
| `dont` | don't | **0.15** | 0.15 | 0.15 | 0.04 |
| `mthmtcs` | mathematics | 2.80 | 0.00 | **0.40** | 0.16 |
| `mthmtcs` | mathematical | 4.50 | 1.00 | **1.10** | — |
| `ppl` | people | 2.10 | 0.00 | **0.20** | 0.12 |
| `alghrith` | algorithm | 2.00 | 2.00 * | **1.00** | — |
| `satfcatn` | stratification | 4.80 | 2.00 | 2.40 | **0.86** |
| `gvmnt` | government | 4.10 | 2.00 | 2.20 | **0.82** |
| `tnk` | think | 1.70 | 1.00 | 1.10 | **0.39** |
| `tnk` | tank | 0.70 | **0.00** | 0.10 | 0.04 |
| `mathe` | mouth | 2.15 | 0.00 | 1.60 | — |

`—` means the channel cannot express the relationship at all: the query is not
a subsequence of the word. The skeleton column is a full skeleton-to-skeleton
comparison; `*` marks where the shipped code compares against a *prefix* of the
word's skeleton instead (§4.4), which is what brings `alghrith` inside budget
for generation — the elastic column is what then prices it.

The last row is the instructive one. `mathe` and `mouth` have the same
skeleton, so a skeleton-to-skeleton comparison calls them a perfect match, and
the elastic cost of 1.60 is *inside* the budget: `mouth` is generated. It does
not appear because 1.60 of cost is 25.6 points of score, which puts it below
twenty better readings. Generation is deliberately loose; the ranking is where
precision comes from.

### 4.3 Sources 1–3: exact, prefix, typo

Exact and prefix are binary searches of the alphabetical permutation; at most
12 prefix completions are kept, chosen by frequency.

The typo source is a bounded scan. Rather than measure edit distance against
83k words, it visits only words that could plausibly be within budget:

**Anchored buckets.** Length within ±2 of the query; first letter equal to the
query's first *or second* letter (the second covers a slip on the very first
key). Lengths are visited most-plausible-first (0, −1, +1, −2, +2) and each
bucket is frequency-ordered, so a check ceiling degrades by dropping the least
likely words rather than an arbitrary slice.

**Exact per-length bit budgets.** Each word carries a 26-bit letter mask. Given
the length difference, the *mandatory* insertions and deletions are already
paid for; whatever budget remains can only buy substitutions, and every edit
moves at most one letter into or out of the letter set. So a word two
characters shorter than the query may differ by exactly the two dropped letters
and nothing else. Two 13-bit popcount lookups per candidate reject most of the
bucket. This is much sharper than a fixed tolerance, and it is what makes the
±2 length window affordable.

(A subtlety: a *doubling* slip changes no letters at all, so the profile has to
distinguish "cheapest indel" — for the band — from "cheapest indel that changes
the letter set" — for these budgets.)

**A check ceiling** of 1200 distance evaluations per scan.

Measured effect: 1,000–17,000 words visited by the prefilter per query,
50–700 surviving to an actual edit-distance evaluation.

### 4.4 Source 4: consonant skeleton

`skeleton(w)` drops `a e i o u`, with two exceptions: `y` is kept (it is
consonantal about as often as it is vocalic, and typists abbreviating keep it —
`systm`, `tplgy`, `hmtpy`), and the first character is kept even when it is a
vowel (nobody writes `bt` for `about`).

Three legs feed one pool:

1. the exact skeleton group from the index;
2. skeleton *completions* — words whose skeleton extends the query's — bounded,
   and only once the query skeleton is long enough to mean something;
3. a fuzzy leg: a bucket scan over skeleton lengths ±1, comparing the query's
   skeleton against a **prefix** of the word's within 1.30.

Leg 3 compares against a prefix rather than the whole skeleton because an
abbreviation with a slip in it is usually also unfinished: `alghrith` is
`algorithm` with an `h` for the `o` and no `m` yet, and demanding the whole
skeleton charges for the slip and the missing tail at once, which no useful
budget absorbs.

Because typists sometimes *do* drop a leading vowel, the index is also probed
with each of the five vowels prepended — five extra binary searches, and how
`nvrnmnt` reaches `environment`.

Everything in the pool is then re-priced by ELASTIC `prefix_distance` against
the **original query**, not against its skeleton. That second stage is what
keeps precision: generation may be loose, but scoring sees the vowels.

### 4.5 Source 5: syllable cues

This is the newest channel and the one most worth attacking.

The observation: for a long word, people neither spell it nor write all its
consonants. They say it to themselves and type one or two letters that feel
salient in each syllable.

```
stratification  →  strat-i-fi-ca-tion  →  satfcatn
```

`satfcatn → stratification` costs 4.80 under the edit model and 2.40 under
elastic, both far outside budget; and the skeleton channel wants all eight
consonants of `strtfctn`. Before this channel existed, `satfcatn` returned
nothing at all.

What every such input *does* have is that **the letters typed appear in the
word, in order**. So the query is aligned as a subsequence, and the whole
question becomes what the skipped characters were worth:

| Skipped character | Cost | Because |
| --- | --- | --- |
| a vowel | 0.04 | nobody spells out the vowels |
| a consonant adjacent to another consonant | 0.35 | clusters, codas and doubled letters: the `h` of `think`, the `r` of `strat`, the `n` of `-nk`, one `t` of `cattle` |
| a consonant between two vowels | 0.60 | that is a syllable's onset — the one letter a shorthand typist keeps |

Three prices. **No syllabifier, no pronunciation dictionary, no codebook.** A
consonant sitting between two vowels begins an English syllable often enough
to be worth pricing, and being wrong about it costs a little score rather than
a candidate. The user-facing instruction is "type what feels representative of
each syllable", and nothing more precise than that is needed.

The alignment is a straightforward DP over `f[i] =` cheapest way to have
matched `q[1..i]` and skipped everything else in `w[1..j]` so far:

```
require w[1] = q[1],  f[1] = 0,  f[i>1] = ∞
for j = 2 … m:
    for i = min(n,j) … 2:                     # descending, so f[i-1] is row j-1
        f[i] ← min( f[i] + skip(w,j),
                    f[i-1]  if w[j] = q[i] )
    f[1] ← f[1] + skip(w,j)
    abort if min(f) > budget                  # costs only accumulate
answer = f[n]
```

Three design decisions do the real work, and each was arrived at by getting it
wrong first:

**The first letter must match.** It is the one character a shorthand typist
does not drop, and requiring it is what stops a three-letter query proposing
half the dictionary.

**The tail is charged too** — everything the query did not land on, *including*
the characters past the last match. Shorthand runs to the end of a word; nobody
types cues syllable by syllable and then stops two syllables early. So a word
with an untouched tail is being *completed*, which other channels answer. This
single rule is what separates `embarass → embarrass` (0.35, nothing left over)
from `embarass → embarrassed` (0.99, a whole syllable nobody typed). Without
it the second led.

**A doubled letter gets no cheap rule of its own.** It had one at first, on the
theory that `cattle → ctl` drops nothing real. But dropping *one* half of a
double while keeping the other is a misspelling, not shorthand, and at a cheap
price the cue reading undercut the edit channel on its own ground: `embarass`
led with `embarrassed` and `adn` led with `adding` rather than `and`.

**Generation** cannot use an index — a subsequence has no prefix to binary
search on, and the skeleton permutation is exactly what these queries fail to
match. So it is a scan over first-letter buckets, bounded by:

- a strict letter-set test, `qmask & ~wordmask == 0`: every letter typed must
  be somewhere in the word (two integer operations, rejects all but a few dozen
  of the words sharing the first letter);
- a leftmost-greedy subsequence check before anything is priced (one walk of
  the word, no allocation);
- a length ceiling, `min(|q| + 12, 3|q|)`;
- **being skipped entirely when the query is itself a dictionary word** —
  shorthand is what you write *instead* of a word — which is also what keeps
  the common case free, since most of what anyone types is spelled correctly.

Cost: 0.14 ms per keystroke — 1.57 ms without the channel against 1.71 ms with,
on a repeated-prefix benchmark.

### 4.6 Word splitting

`exactlyright → exactly right`. A word-break dynamic program over the
dictionary: `score[i]` is the best segmentation of the first `i` characters,
scored by summed log-frequency minus a fixed penalty (0.8) per word beyond the
first. The penalty is what stops a string being shredded into the many short
words English is full of; at 1.4, `as a matter of fact` starts losing to
`asa matter of fact`, and at 0 everything shatters.

It is never offered for a string that is itself a dictionary word — `another`
segments perfectly well into `a not her` — and it is **placed rather than
ranked**: fixed at the last position among the real candidates. Ranking it was
wrong twice over. Scored high it displaced real corrections; scored low it
vanished exactly when it was wanted (`thisday` offered Thursday and Tuesday and
no way at all to say "this day"). There is no score that means "worth having,
never worth preferring". A fixed place does.

### 4.7 Personal vocabulary

A plain text file of `word → count`, plus optionally the surface form the user
actually wrote. Every query runs a linear pass over the ≤400 most-used entries,
applying the same alignments to each. It is a linear pass rather than an index
lookup on purpose: it guarantees that a word the user has actually chosen is
always in the running, and cannot be squeezed out of a frequency-ranked
shortlist by commoner neighbours.

This is also how unknown words enter the system: commit `Grothendieck` once and
`grthndck`, `gthndck` and `grtdck` all find it afterwards, capitalised.

### 4.8 Ranking

Every candidate from every source is scored by the same function and sorted.

```
score(c) =  base[source(c)]
          + w_f · f(w)                        frequency, normalised log, [0,1]
          + w_u · u(w)                        personal history, [0,1]
          − w_c · cost(c)                     the alignment cost above
          − w_e · pen(extra(c))               how much a completion adds
          − P_unk · [w ∉ D]                   the dictionary has never heard of it
          + B_form · [exact ∧ w has a surface form]
          + V · (2α(q) − 1) · [source ∈ {skeleton, cue}]
```

with `pen(x) = clamp(x/10, 0, 1)`, `u(w) = log(1+count)/log(1+12)` clamped to 1,
and `α(q) = 1 − vowel_ratio(q)` — "how consonantal does this input look".
The last term is signed: a consonant-only input is evidence *for* the
abbreviation reading, a vowel-rich one is evidence *against* it. `P_unk` is
charged to anything the dictionary has never heard of, which in practice means
a word the user committed once; a word split is exempt, since it is made
entirely of dictionary words.

Current constants:

```
base_exact 100   base_typo 75    base_split  70    form_bonus       70
base_prefix 74   base_skeleton 62  base_cue  70    unknown_penalty  25
w_f 34   w_u 18   w_c 16   w_e 8   V_skeleton 10   V_cue 10
```

Three of these encode a principle rather than a tuning result:

- **`w_u = 18`, deliberately small.** The dictionary is measured English; the
  personal store is a handful of counts from whatever was typed lately,
  including mistakes committed while something was broken. At 26 it was worth
  three-quarters of the entire frequency range, and a word committed three
  times could lead over the word it was a misspelling of.
- **`unknown_penalty = 25`.** Being typed exactly is not the same evidence from
  a word nobody has measured as it is from a word in the dictionary. Without
  it, a mistake committed three times (`eys`) led over the word it was a
  misspelling of (`eyes`) for good.
- **`form_bonus = 70`.** An exact match on a key someone deliberately wrote
  down (`sth → something`) is different in kind from an exact match on an
  ordinary word. Raising `base_exact` instead was tried and made every rare
  word unbeatable — `tat` and `eys` then led over `that` and `eyes`, which is
  the opposite failure and a worse one.

### 4.9 Confidence, and when the literal leads

The literal input sits in a fixed slot (last on the first page) so the keystroke
that commits it is predictable — *unless* nothing found is trustworthy, in
which case it leads. "Trustworthy" is: repair cost ≤ 1.50, score ≥ 62, and
either an exact dictionary hit or

- not all-capitals (`PDE`, `TQFT` typed in capitals are deliberate), and
- at least 3 characters, or a zero-cost completion adding a single letter
  (`th → the` is worth trusting; `cm → come` and `x → xxx` are not).

Before those rules existed, an adversarial audit found `x → xxx`, `cm → come`
and `CW → COW` sitting under the space bar — the one failure mode that corrupts
a document silently.

When the literal leads, the space bar also asks twice: the first press is
swallowed, the second commits. The space bar is doing two jobs — pick this
word, and separate it from the next — and the second is so automatic that the
first happens without being noticed. That is fine when the candidate is a real
word and exactly wrong when it is a misspelling.

---

## 5. Evaluation

### 5.1 Method

1,484 cases in `tests/cases/*.tsv`, each a triple *(input, expected, max rank)*.

**Hand-written (284).** Every example in the original brief; 68 well-known
English misspellings; consonant-only input including deliberately mistyped
skeletons; ordinary correct typing; short ambiguous input; the literal-input
guarantees; dropped apostrophes and abbreviations; 57 syllabic shorthands.

**Generated (1,200)**, from a fixed seed, over words ranked 150–12,000 (what
people actually type; deeper into the tail one measures the corpus, not the
matcher):

- 500 single plausible slips — transposition, deletion, doubling, neighbouring
  key. Corruptions that are themselves dictionary words are excluded.
- 400 consonant skeletons of words ≥ 6 letters, excluding skeletons that are
  themselves words.
- 300 syllabic shorthands: the word is cut into rough syllables orthographically
  and one or two letters taken from each, biased towards the first.

The 300 syllabic cases carry two ambiguity filters, and both matter for the
honesty of the number. A word with a commoner word as a prefix is skipped —
shorthand for `productions` is shorthand for `product` too. And a shorthand is
skipped unless its target is the **most frequent** word whose letters it
appears in, in order; otherwise `untl` would be scored against `untitled` while
`until` sits right there. Neither filter consults the matcher: both use only
the property the generator guarantees.

### 5.2 Current results

```
file                          cases   top-1   top-5 in-rank
------------------------------------------------------------
ambiguity.tsv                    16   50.0%  100.0%  100.0%
common_typos.tsv                 68   97.1%  100.0%  100.0%
forms.tsv                        42   76.2%  100.0%  100.0%
generated_cues.tsv              300   85.7%   98.3%   98.3%
generated_skeletons.tsv         400   93.0%  100.0%  100.0%
generated_typos.tsv             500   92.2%   99.0%   99.0%
literal.tsv                      24  100.0%  100.0%  100.0%
prefix.tsv                       16   93.8%  100.0%  100.0%
raw.tsv                          14   71.4%   85.7%  100.0%
skeletons.tsv                    31  100.0%  100.0%  100.0%
spec_examples.tsv                16   75.0%   87.5%  100.0%
syllables.tsv                    57   93.0%  100.0%  100.0%
------------------------------------------------------------
TOTAL                          1484   90.4%   99.1%   99.3%
```

Three files have a deliberately low top-1. `spec_examples.tsv` asks for
`mathematics`, `mathematical` **and** `mathematician` from the same input, so
at most one can be first. Half of `raw.tsv` asks for the literal to be on the
first page *while a correction leads*. Most of `forms.tsv` is inputs like
`its`, `were`, `cant` that are real words in their own right: those must come
first, with the contraction immediately behind, and both halves are asserted.

By error class:

```
                              cases   top-1   top-5
  transpose                     117   95.7%  100.0%
  insert (doubled letter)       126   96.8%  100.0%
  substitute (neighbour key)    130   94.6%   98.5%
  delete                        127   81.9%   97.6%
```

A harsher probe than the case files, since those are built from *plausible*
shorthand: take 261 corpus words of seven letters or more and delete two
letters at random.

```
                        cue channel off      cue channel on
  nothing offered at all      9.2%                0.0%
  right word first           28.4%               73.2%
  right word on page 1       43.7%               93.5%
```

### 5.3 Latency

```
over all 1,484 evaluation queries
  mean 3.13 ms   median 2.03 ms   p95 9.15 ms

typing nine words out, one keystroke at a time (86 keystrokes)
  mean 2.45 ms
  by input length (ms)
    1: 1.0   2: 1.0   3: 1.2   4: 3.4   5: 1.9   6: 1.6   7: 2.2
    8: 5.0   9: 5.0  10: 3.4  11: 2.9  12: 2.7  13: 3.0  14: 2.0
```

The second block is the number that matters: it is what a keystroke costs while
a word is actually being typed. The peak at 8–9 characters is where the length
buckets are fullest and every scan runs at once. Against 144 ms for a naive
full scan, the bucketing and prefilters do that work *and* three other searches
in about 2.5 ms.

### 5.4 How the weights were chosen, and why that is a weakness

`bench/tune.lua` runs coordinate descent over the ranking weights and edit
budgets, maximising a macro average of `2·top-1 + top-5 + in-rank` across the
case files (macro rather than micro, so 1,200 generated cases do not drown out
284 hand-written ones).

**There is no held-out set.** The weights are fitted on the same 1,484 cases
that report the accuracy above. The generated portion is re-derived from a
fixed seed and was never inspected case by case, which limits the damage, but
the numbers in §5.2 should be read as *training* accuracy. This is the largest
methodological weakness in the project and it is entirely a consequence of
having no real data (§2).

Changes found by *hand* have consistently mattered more than the tuning:
pricing a miscounted double letter at 0.55; scoring skeleton candidates by an
asymmetric elastic alignment against the original query rather than
skeleton-to-skeleton; pricing a dropped apostrophe at 0.15; charging the tail
in the cue channel. Each of those moved more than any weight sweep.

---

## 6. Where it fails now

Almost every remaining loss is a real ambiguity rather than a search failure.
Across all 1,484 cases, 143 (9.6%) do not lead, and of those:

```
  intended word at rank 2        89   62% of misses
                  at rank 3–5    40   28%
                  at rank 6–20   14   10%
                  not offered     0    0%
```

**Nothing is ever missing.** The whole residual is ordering, and 62% of it is
ordering between two readings that are both defensible. In 27% of misses the
winning word shares a four-character prefix with the target — a morphological
sibling. The classes, from a full sweep of the case files:

**Morphological siblings — the largest class.** The input under-determines the
suffix, and the commoner sibling wins.

```
  rgulator  → regulator   (wanted regulatory)     gnert  → generate  (wanted generation)
  vegtal    → vegetable   (wanted vegetables)     amrc   → America   (wanted American)
  hbit      → habit       (wanted habitat)        accor  → according (wanted accord)
```

**Vowel-identity loss.** Consonant-only input genuinely erases the
distinguishing letter. Nothing in the query can settle these.

```
  mtns → meetings (wanted motions)     blcks → blocks (wanted blacks)
  lthr → leather  (wanted luther)      rmndr → reminder (wanted remainder)
  amnts → amounts (wanted amenities)   frfx  → firefox (wanted fairfax)
```

**Short input.** Three characters or fewer carry too little information;
`frm` legitimately offers from, form, firm, farm, forum. The system does not
pretend otherwise, and these cases are asserted as *lists*, not as single
answers.

**Deliberate ties.** `its` / `it's`, `were` / `we're`, `mathe` →
mathematics / mathematical / mathematician. Only one can be first.

And two structural gaps:

**The fuzzy readings do not compose.** Splitting is exact only:
`exactlyright → exactly right` works, but `exctlyrght` finds nothing, because
every part would need the full fuzzy search at every split point. Shorthand has
the same shape of limit — the cue channel requires every letter typed to appear
in the word, in order, so a slip *inside* an abbreviation (`stfxctn` for
`stratification`) falls back to channels that cannot span that far. One missing
capability, met twice: running a fuzzy search inside a fuzzy segmentation.

**Learning remembers the word, not the input that found it.** Selecting
`recommendation` for `rcmmndtn` raises `recommendation` everywhere; it does not
record that *this* abbreviation meant *that* word.

---

## 7. Things that were tried and did not work

Recorded because they are the obvious first ideas.

- **Skeleton-to-skeleton scoring.** Comparing `skeleton(query)` with
  `skeleton(word)` throws away the vowels the user actually typed, so `mathe`
  matches `mouth` as well as `mthmtcs` matches `mathematics`. Replaced by the
  asymmetric elastic alignment (§4.1).
- **Raising `base_exact` to protect deliberate entries.** Made every rare word
  unbeatable: `tat` and `eys` led over `that` and `eyes`. Replaced by a bonus
  restricted to entries carrying a surface form.
- **Ranking the word split rather than placing it.** No score means "worth
  having, never worth preferring" (§4.6).
- **A cheap price for skipping one half of a doubled letter** in the cue
  channel. It let the loosest channel undercut the strictest one on its own
  ground (§4.5).
- **A steeper vowel-ratio slope for cue candidates** instead of a higher base.
  Coordinate descent preferred the higher base at the same slope, and it scored
  better on every file.
- **Rime's native user dictionary** for learning. It records `(code, text)`
  pairs produced by a dictionary-backed translator; candidates here are
  synthesised, so there is nothing for it to memorise.

---

## 8. Open problems

Roughly in order of expected value. Each is stated with what is already known,
so that a reader can skip the parts that have been ruled out.

### 8.0 What any replacement has to preserve

Stated up front because they rule out otherwise attractive designs:

1. **The literal input is always reachable**, in a predictable slot, and leads
   when nothing is trustworthy. No design may make it hard to type `kubectl`.
2. **Nothing commits without the user choosing it.** No auto-selection, no
   silent replacement. The whole safety argument in §1.1 depends on this.
3. **Recall at 5 is worth nearly as much as precision at 1.** A design that
   trades three points of top-5 for one of top-1 is a bad trade here, even
   though it would be a good one for autocorrect.
4. **Under 10 ms at p95, in interpreted Lua, with no compiled dependency.**
   The last clause is not fussiness: it is what makes the thing installable by
   a non-programmer on Windows without administrator rights.
5. **Explainable and undoable.** A user must be able to see why a candidate is
   there and remove anything the system learned by accident.

### 8.1 Context

**The single biggest lever, and currently unavailable.** A bigram or trigram
over the preceding words would settle both of the largest failure classes in
§6: `wanted regulatory` and `wanted motions` are decidable from context and
from nothing else in the input.

What blocks it is not modelling but plumbing: one composition is one word, and
the IME cannot reliably see the document. A companion frontend build now reads
32 characters in front of the caret, which makes the *previous word* available
as a string. So the question is: what is the best use of one previous word,
under 1 ms, with no training corpus of this task's inputs, and no model larger
than a few megabytes? A count-based bigram over a public corpus is the obvious
answer; whether it is affordable, and how to combine `log P(w | prev)` with an
additive score whose other terms are not log-probabilities, is not obvious.

### 8.2 The scoring function is linear, hand-designed, and fitted without a held-out set

Fifteen constants, chosen by coordinate descent over the same 1,484 cases it is
evaluated on (§5.4). Two directions:

- **Get real data.** A keystroke log of (what was typed, what was committed)
  would turn this into an ordinary learning-to-rank problem. Collecting it is a
  product question — the data is intimate — but even one consenting user
  produces thousands of pairs a day.
- **Replace the linear form.** The terms are not obviously additive. Cost and
  frequency plausibly interact: a large repair to a very common word is
  believable, a large repair to a rare one is not, and the current form cannot
  say that. Is there a principled probabilistic formulation — a noisy-channel
  model `P(w | q) ∝ P(q | w) P(w)` where `P(q | w)` is a generative model of
  how a person abbreviates — that both fits the constraints and beats the
  hand-tuned linear score? The five channels would become five mixture
  components of `P(q | w)`, which is intellectually much more satisfying, but
  it needs the data from the previous bullet to fit.

### 8.3 One generation model instead of five channels

Generation is currently five hand-built searches with hand-set budgets, tuned
so their unions cover the input space. That is why they do not compose (§6):
each is a separate index strategy.

Is there a single index and a single search that covers exact, prefix, typo,
skeleton and subsequence readings? Some candidates:

- **An FST / trie with edit-distance-bounded traversal**, where the cost model
  varies by position and character class. This subsumes typo and prefix
  naturally, and skeleton and cue become cost profiles rather than separate
  channels. Cost: 83k words in a trie, in Lua, within 17 MB and 2.5 ms.
- **A learned or hashed sketch** — SymSpell-style deletion neighbourhoods, or
  an LSH over character n-grams — as a recall stage feeding an exact re-ranking
  stage. The current bit-mask prefilter is a crude version of exactly this.
- Note the asymmetry that makes standard techniques awkward. In plain
  Levenshtein terms the intended answers sit at distance 6 (`satfcatn` →
  stratification), 5 (`gvmnt` → government), 4 (`mthmtcs` → mathematics) — well
  outside the radius any deletion-neighbourhood or BK-tree index can afford on
  83k words. The whole point of the four cost models is that these are *not*
  distance-6 errors under the right metric; they are distance-0.86 shorthands.
  Any recall structure keyed on small *uniform* edit distance fails on exactly
  the inputs that matter most.

### 8.4 Fuzzy composition

Make `exctlyrght → exactly right` work, and make a slip inside shorthand
non-fatal. The obvious formulation is a lattice: run the fuzzy search at every
split point and find the best path. The obvious problem is cost — the current
split is a word-break DP with an O(1) dictionary lookup per (position, length)
pair, and replacing that lookup with a bounded fuzzy search multiplies it by
several hundred. Tight budgets and a gate would be needed. Whether there is a
formulation that shares work between overlapping searches is open.

### 8.5 Better frequency data

The corpus is Google-Books-derived: it skews old and literary and keeps proper
nouns as ordinary lowercase tokens, so `mathew`, `mather` and `mathews` all
compete with `mathematics` for the input `mathe`. Blending in a modern subtitle
or web corpus, or demoting capitalised-in-corpus tokens at build time, is
probably worth more top-1 than any further weight tuning — but it is a data
problem, not an algorithm problem, and it is easy to make worse.

A related question with no good answer yet: the frequency term uses a
*normalised log* frequency in [0,1], which compresses the difference between
rank 100 and rank 10,000 into very little score. That is deliberate (a
linear-in-count term would make `the` unbeatable) but it is not principled.

### 8.6 Incremental search

Consecutive keystrokes re-search from scratch. Restricting the next scan to the
previous candidate set plus one edit should cut typical latency several-fold,
which would buy the headroom that §8.1 and §8.4 both need. The complication is
that the candidate set for `mathe` is not a superset of the candidate set for
`math` under any of the four cost models — a cheap alignment can become
expensive when one more character arrives, and vice versa.

### 8.7 Remember the input, not just the word

Store `(typed, committed)` pairs and score an exact match on the typed form
highly. Every correction the user makes once becomes permanent. This is a
contained change and probably the cheapest real win on the list — the open part
is how to age and bound the store, and how not to let one accident become
permanent (there is an explicit "forget" key, but relying on the user to press
it is a poor design).

---

## 9. Reproducing everything here

```bash
git clone https://github.com/EricWay1024/spellless && cd spellless
make            # rebuild dictionary, indexes and generated test sets
make test       # 1,868 assertions, including every hand-written case
make bench      # the accuracy and latency tables in §5
lua bench/tune.lua 3            # the coordinate descent in §5.4
lua bench/try.lua --debug mthmtcs satfcatn tnk     # ask it anything
```

The matcher is pure Lua with no dependencies and knows nothing about the input
method: `rime/lua/spellless/` is the algorithm, `rime/lua/spellless.lua` is the
adapter that wires it to Rime, and `tests/` and `bench/` exercise exactly the
code the IME runs.

`DESIGN.md` covers the input-method side — spacing, capitalisation, what the
frontend can do that a schema cannot. `EVALUATION.md` is the long-form version
of §5. `data/README.md` documents the corpus and its preprocessing.
