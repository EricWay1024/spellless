# Decoding lossy English input

**A self-contained description of the Spellless matching algorithm, the
constraints that shaped it, and the problems it has not solved.**

Written for someone who has never seen the codebase. Nothing here assumes
knowledge of Rime, Lua, or input methods. Everything measurable is measured;
where a number is a guess it says so. The last section is a list of open
problems, which is the reason this document exists.

Source: <https://github.com/EricWay1024/spellless>.
Reproduce every number with `make test && make bench`.

**Revised after review.** An expert read the first version and answered it;
that answer is in `prompt/expert-review.md`, verbatim, and four of its
suggestions were implemented and measured. Where this document now contradicts
the version they read, §5.1 and §8 say so. Two of their points corrected claims
made here, one of their proposals turned out not to work, and one of them
turned out to be worth ten points.

---

## 1. The problem

A person knows a word and cannot reliably produce its spelling at the speed
they think. They type an approximation. The system must return a short ranked
list containing the word they meant, fast enough that typing does not stutter.

**Formally.** A dictionary `D` of `N = 83,137` English words, each carrying a
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
| **Scale of the budget** | A naive weighted edit distance against all 83,137 words, *with* the budget and early abort, costs **165 ms per query**. The budget is therefore under 1/70th of a full scan. |
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
shorthand. **83,137 entries.**

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

| query | word | typo ≤1.35 | skeleton ≤1.30 | elastic ≤1.70 | cue ≤1.33 (2.44 †) |
| --- | --- | --- | --- | --- | --- |
| `teh` | the | **0.45** | 0.00 | 0.45 | — |
| `recieve` | receive | **0.45** | 0.00 | 0.45 | — |
| `commited` | committed | **0.55** | 0.55 | 0.55 | 0.66 |
| `dont` | don't | **0.15** | 0.15 | 0.15 | 0.22 |
| `mthmtcs` | mathematics | 2.80 | 0.00 | **0.40** | 0.34 |
| `mthmtcs` | mathematical | 4.50 | 1.00 | **1.10** | 1.47 † |
| `ppl` | people | 2.10 | 0.00 | **0.20** | 0.21 |
| `alghrith` | algorithm | 2.00 | 2.00 * | **1.00** | 1.79 † |
| `satfcatn` | stratification | 4.80 | 2.00 | 2.40 | **0.86** |
| `gvmnt` | government | 4.10 | 2.00 | 2.20 | **0.57** |
| `tnk` | think | 1.70 | 1.00 | 1.10 | **0.29** |
| `tnk` | tank | 0.70 | **0.00** | 0.10 | 0.12 |
| `mathe` | mouth | 2.15 | 0.00 | 1.60 | — |

The cue column is a log-likelihood in nats divided by a units constant (§4.5),
so it is not on the same scale as the other three; only its ordering within the
column means anything. It is shown in those units rather than in nats, which is
why the budget reads 1.33 rather than the 12 nats the configuration names —
`cue.align` divides by `cue_cost_scale = 9` before returning. To reproduce a
row:

```lua
package.path = "rime/lua/?.lua;" .. package.path
local cue, cfg = require("spellless.cue"), require("spellless.config").defaults
print(cue.align("gvmnt", "government", cfg.cue_budget, cfg))   --> 0.57
```

`—` means the channel cannot express the relationship at all: the query is not
a subsequence of the word, nor a subsequence with one character mistyped.
`†` marks the readings that need that slip, which is why they cost so much: a
slip is charged `cue_slip_cost = 10` nats *and* granted that much extra budget
(§4.5), so a slipped reading can be found up to 2.44 and still lands far below
anything clean. The skeleton column is a full skeleton-to-skeleton comparison;
`*` marks where the shipped code compares against a *prefix* of the word's
skeleton instead (§4.4), which is what brings `alghrith` inside budget for
generation — the elastic column is what then prices it.

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

The newest channel, and the one the review changed most.

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
word, in order**. So the query is aligned as a subsequence — and the question
becomes not what the skipped characters cost, but how likely a person was to
keep each one.

Every character of the word is either kept or dropped. Give each character
class a **keep probability**, charge `−log p` when the typist kept it and
`−log(1 − p)` when they dropped it, and the alignment cost is a log-likelihood
in nats that normalises itself over the word:

| Character of the word | Kept with probability | Because |
| --- | --- | --- |
| a vowel | 0.32 | nobody spells out the vowels |
| a consonant adjacent to another consonant | 0.76 | clusters, codas and doubled letters: the `h` of `think`, the `r` of `strat`, one `t` of `cattle` |
| a consonant between two vowels | 0.86 | that is a syllable's onset — the letter a shorthand typist keeps |

In English: *a shorthand typist types about a third of the vowels, three
consonants in four when they sit beside another consonant, and six in seven of
the consonants that begin a syllable.* Three numbers. No syllabifier, no
pronunciation dictionary, no codebook.

**And they are counted, not chosen.** The alignment itself says which
characters each known (shorthand, word) pair kept, so class-wise keep rates are
closed-form counts. Hard EM over the 342 pairs in the case files converges in
two iterations to 0.39 / 0.68 / 0.89; coordinate descent then moves them to the
shipped values and gains 0.002 of objective doing it — which is to say the
maximum-likelihood numbers were already right.

That is the part worth taking away, and it is not the accuracy. **These three
numbers are countable from one user's own committed pairs.** The store §8.7
wants for learning is the training data §8.2 says does not exist — per typist,
a table of counts, therefore inspectable and undoable.

The recurrence, with `c(j)` the class of `w[j]`:

```
require w[1] = q[1],   f[1] = −log p_{c(1)},   f[i>1] = ∞
for j = 2 … m:
    for i = min(n,j) … 2:                      # descending, so f[i-1] is row j-1
        f[i] ← min( f[i] + −log(1 − p_{c(j)}) ,          drop w[j]
                    f[i-1] + −log p_{c(j)}  if w[j] = q[i] )   keep it
    f[1] ← f[1] + −log(1 − p_{c(j)})
    abort if min(f) > budget
answer = f[n] / cue_cost_scale
```

Both prices are strictly positive, so the row minimum is non-decreasing and the
early abort stays sound. That is asserted rather than argued: 6,000 random
(word, subsequence) pairs, checking that no budget ever changes the cost
reported or refuses what a smaller budget afforded.

**Three things this model does not fix.**

*The tail still has to be charged*, and now it is, structurally — every
character is kept or dropped, including the ones past the last match, so there
is no special case any more. But it is not *unnecessary*: forcing the model to
stop charging past the last match still costs 1.6 points of top-1 and puts
`embarass` back behind `embarrassed`. The hand-won rule was the correct
normaliser, and the model absorbs it rather than replacing it.

*A doubled letter still gets no class of its own*, for the same reason as
before: dropping one half of a double while keeping the other is a misspelling,
not shorthand.

*And the units are still hand-set.* `cue_cost_scale` — nats per unit of the
ranker's `cost` — is the one number in the channel with no probabilistic
meaning, and the normalised model does **not** beat the hand-tuned prices
without it. At the naive calibration it scores *below* the old model. This is
the "consistent units" half of the diagnosis and the model does not answer it.

It is also, in practice, the dial between this channel and the consonant
skeleton: raise it and the cost term flattens so frequency decides and a
commoner longer word wins; lower it and an exact-skeleton reading wins. Held
out over ten fresh generator seeds the two move against each other about two to
one, and the aggregate is flat:

```
  cue_cost_scale      5      7      9     10     12
  generated_cues   69.8   83.4   88.5   90.1   91.9
  generated_skels  91.6   90.6   89.3   88.5   87.6
  TOTAL top-1      85.8   88.7   89.5   89.6   89.6
```

The aggregate is flat, so the data does not choose and the setting is a
statement about who is typing. It ships at **9**, favouring the skeleton
reading, because at 12 the exact-skeleton cases were visibly losing — `wrkr`
gave *workers* before *worker*, `mlcl` *molecular* before *molecule* — and a
consonant skeleton is the commoner way to type here. It costs 0.24 points of
held-out top-1.

**One letter of the shorthand may be the wrong key**, at a fixed extra cost —
a substitution transition in the same DP, with the letter-set filter relaxed
from "every letter appears" to "at most one does not". It takes 252 corrupted
shorthands from 28% to 85% on the first page, for about 0.35 ms per keystroke. Note
that **no case file can see this at all** — not one of them contains a
corrupted shorthand — so it is a feature whose entire value sits outside the
benchmark, which is worth remembering when reading §5.

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
base_exact 100   base_typo 75    base_cue    70    form_bonus       70
base_prefix 74   base_skeleton 62                  unknown_penalty  25
w_f 34   w_u 18   w_c 16   w_e 8   V_skeleton 10   V_cue 10
```

**Two of those are not really there.** The score has an exact one-parameter
gauge freedom: multiply every constant above by any λ and the evaluation is
identical to six decimal places, because a score is only ever compared with
another score. The single exception is `confidence_floor` (§4.9), which is the
only place in the codebase a score meets a constant rather than another score —
scale everything but it and what breaks is precisely the literal-input
guarantee. And a fifteenth constant, a base score for the word split, was dead:
a split is *placed* rather than ranked (§4.6) and never reaches this function at
all, so setting it to 0 or to 1000 left every case file bit-identical. It has
been removed. **Thirteen real degrees of freedom, not fifteen** — and the tuner
searches nine of them.

**What the units mean.** The dictionary's log-frequency range is 14.41 nats, so
`w_f` buys 2.36 points per nat and one unit of edit cost is priced at 6.78 nats,
about 880:1. But that is not the number that governs anything. A repair must
also cross `base_exact − base_typo = 25`, and 41 points is 17.4 nats against a
corpus whose entire dynamic range is 14.4 — so **a full-price repair never beats
an exact dictionary match at any frequency.** It is a veto, not a price, and
checking the 2,500 commonest words confirms the exact reading leads in every
one. In the rank band people actually type, the whole frequency spread available
is 4.7 nats: enough to overturn a cost gap of 0.69, never a whole edit.

Three of the constants encode a principle rather than a tuning result:

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

### 5.1 Method, and what is wrong with it

1,484 cases in `tests/cases/*.tsv`, each a triple *(input, expected, max rank)*.

**Hand-written (284).** Every example in the original brief; 68 well-known
English misspellings; consonant-only input including deliberately mistyped
skeletons; ordinary correct typing; short ambiguous input; the literal-input
guarantees; dropped apostrophes and abbreviations; 57 syllabic shorthands.

**Generated (1,200)**, from a fixed seed, over words ranked 150–12,000 (what
people actually type; deeper into the tail one measures the corpus, not the
matcher): 500 single plausible slips, 400 consonant skeletons, 300 syllabic
shorthands.

**Three filters keep the generated sets honest**, and all three ask about the
strings and the frequency list only — none consults the matcher, which is what
makes discarding a case defensible rather than a way of raising the score.

1. A target with a *commoner word as a prefix* is skipped: shorthand for
   `productions` is shorthand for `product` too.
2. A shorthand is skipped unless its target is the **most frequent** word whose
   letters it contains in order — otherwise `untl` is scored against `untitled`
   while `until` sits right there.
3. A shorthand is skipped when some word explains it **better**: if there is a
   `w'` with `q ⊆ w' ⊂ w`, then `w'` skips strictly fewer characters under any
   pricing whatsoever. This one was added after review, and it was catching a
   real fault — `rgulator` had stood as a case for `regulatory` when
   `regulator` is that string with one letter put back, and `amrc` demanded
   `american` over `america`. It moves the generated top-1 up 2.8 points on the
   shorthand set and 1.2 on the skeleton set. The rank bound matters: without
   it the corpus tail does the dominating (`brach` over `breach`) and 7% of the
   skeleton set disappears for no reason anyone would recognise.

**The weights are fitted on these same cases.** That is the largest
methodological problem here and it is a consequence of having no real data
(§2). But the generated portion comes from a *seeded* generator, so a fresh
seed is a free held-out set, and it can be asked directly how optimistic the
shipped number is:

```
                        shipped seed   10 fresh draws    gap    draws ≥ shipped
  generated_typos           91.4%      91.0% ± 0.9      +0.4        5 / 10
  generated_skeletons       88.5%      89.8% ± 1.9      −1.3        7 / 10
  generated_cues            88.0%      88.1% ± 2.7      −0.1        6 / 10
  TOTAL top-1               89.6%      89.9% ± 0.9      −0.3        7 / 10
  TOTAL top-5               99.0%      99.3% ± 0.3      −0.3
```

**There is no measurable optimism left, on any file.** Every gap is inside one
standard deviation of the seed-to-seed spread, the shipped seed sits *below*
the held-out mean overall, and about half the fresh draws beat it on each file
— which is what a set of weights that has not been fitted to a particular draw
looks like.

It did not read that way when this section was first written, and how it
changed is the useful part. The measurement then was:

```
                        shipped seed    25 fresh draws    gap
  generated_typos           92.2%           92.0%        +0.2
  generated_skeletons       93.0%           92.2%        +0.8
  generated_cues            85.7%           78.0%        +7.7      ← all of it
```

The entire overfit lived in the syllabic shorthand set, whose five constants
had been fitted by coordinate descent on those 300 cases. What removed it was
not a better fitting procedure but **abandoning the fit**: the channel was
rewritten as a normalised generative model (§4.5), its keep probabilities were
set from what the letter classes mean rather than from a sweep, and
`cue_cost_scale` was then set by hand — a single dial, chosen on how the
candidate lists read, not on this file's score. The cue set's accuracy on the
shipped seed fell 85.7 → 88.0 by the seed's own reckoning while the held-out
mean rose 78.0 → 88.1. The lesson is worth keeping: five free constants over
300 cases were buying about eight points of nothing.

Two things this does *not* measure, and they are the larger uncertainties. A
fresh seed re-samples from the same generator against the same dictionary, so
it says nothing about whether `make_testset.py`'s model of how people abbreviate
resembles how people actually abbreviate. And the 284 hand-written cases have no
held-out version and cannot have one.

There is a third, and it is worth stating because the obvious way to answer it
does not. **Every case here is a transcription**: an input is given and the
word it stands for is known. Writing is not that. When you are composing, the
spelling is the thing you do not have — which is the entire reason this project
exists — and when you are copying, it is in front of you. A typing test built
on this repository (`docs/typing-bench.html`) makes the gap plain: with the
model line visible, a good score means you copy quickly and says very little
about whether the matcher helps you *write*. Measuring that needs a test where
the words come out of the typist's own head, and nobody has built one. It is
the same shape of gap as §8.2's missing keystroke log, and probably the same
fix: real data from real composition.

### 5.2 Current results

The shipped seed, which is what `lua bench/evaluate.lua` prints, with the
held-out mean beside the generated files. §5.1 has the reason the two columns
now agree.

```
file                          cases   top-1   top-5      held out (10 seeds)
------------------------------------------------------------
ambiguity.tsv                    16   50.0%   93.8%      hand-written, no held-out set
common_typos.tsv                 68   97.1%  100.0%      hand-written, no held-out set
forms.tsv                        42   76.2%  100.0%      hand-written, no held-out set
generated_cues.tsv              300   88.0%   99.3%      88.1% / 99.0%
generated_skeletons.tsv         400   88.5%   99.2%      89.8% / 99.8%
generated_typos.tsv             500   91.4%   99.2%      91.0% / 98.9%
literal.tsv                      24  100.0%  100.0%      hand-written, no held-out set
prefix.tsv                       16   93.8%  100.0%      hand-written, no held-out set
raw.tsv                          14   71.4%   78.6%      hand-written, no held-out set
skeletons.tsv                    31  100.0%  100.0%      hand-written, no held-out set
spec_examples.tsv                16   75.0%   87.5%      hand-written, no held-out set
syllables.tsv                    57   98.2%  100.0%      hand-written, no held-out set
------------------------------------------------------------
TOTAL                          1484   89.6%   99.0%      shipped seed
                                      89.9%   99.3%      mean of 10 fresh seeds
```

**Top-1 ≈ 89.9% held out, top-5 ≈ 99.3%**, and the shipped seed reads 89.6% —
*below* the held-out mean, by less than a third of the seed-to-seed standard
deviation. There is no gap left to correct for.

Three files have a deliberately low top-1. `spec_examples.tsv` asks for
`mathematics`, `mathematical` **and** `mathematician` from the same input, so
at most one can be first. Half of `raw.tsv` asks for the literal to be on the
first page *while a correction leads* — its "top-5 misses" are the literal
sitting in slot 7, which is exactly where the design puts it. Most of
`forms.tsv` is inputs like `its`, `were`, `cant` that are real words in their
own right: those must come first, with the contraction immediately behind, and
both halves are asserted.

By error class, on the shipped seed:

```
                              cases   top-1   top-5
  transpose                     123   94.3%  100.0%
  insert (doubled letter)       127   97.6%  100.0%
  substitute (neighbour key)    129   95.3%  100.0%
  delete                        121   77.7%   96.7%
```

Deletion is the hard class and always has been: a deleted letter leaves less
information than any of the others, and a query that is a subsequence of its
target is a subsequence of several.

Two harsher probes than the case files, since those are built from *plausible*
input. Both are `lua bench/probe.lua`, seeded, so they can be re-run rather
than believed; the figures move a couple of points between seeds and the
conclusions do not.

Take 261 corpus words of seven letters or more and delete two letters at
random. Nothing about the result respects a syllable, so this is the shorthand
channel working outside the model it was built on.

```
                        cue channel off      cue channel on
  nothing offered at all      8.8%                0.0%
  right word first           23.8%               68.2%
  right word on page 1       45.2%               93.1%
```

Then take the cue case file — inputs the matcher answers at 88% — and mistype
one letter of each. This is the class slip tolerance (§4.5) exists for, and the
one the case files cannot contain, because a generator that produced them would
be generating noise rather than shorthand.

```
                        slip tolerance off   slip tolerance on
  nothing offered at all     27.3%                0.0%
  right word first           20.0%               22.4%
  right word on page 1       28.3%               85.4%
```

Note which row moves. Slip tolerance barely changes what leads — a corrupted
abbreviation is genuinely ambiguous and the matcher is right not to be
confident about it — and takes the first page from a third to six in seven.
That is the shape of a recall feature, and it is why it is judged on top-5.

### 5.3 Latency

```
over all 1,484 evaluation queries
  mean 2.9 ms   median 2.2 ms   p95 7.8 ms

typing nine words out, one keystroke at a time (86 keystrokes)
  mean 2.3 ms

startup   ~100 ms, once per process (memoised across engines)
memory    13.9 MB after loading, 17.6 MB steady state
```

The second block is what a keystroke costs while a word is actually being
typed, and it is the number that matters. Against 165 ms for a naive full scan,
the bucketing and prefilters do that work *and* three other searches in about
2.3 ms.

Two features that improve recall have the same shape: they cost a fifth to a
quarter of the per-keystroke budget, paid on *every* query, for an input class
that is rare. Slip-tolerant shorthand is **on** and takes corrupted
abbreviations from 28% to 85% on the first page; `scan_first_neighbours` is **off** and
would take a wrong first key from 1.6% to 98.2% on the first page. There is not
room for both. See §8.9.

**A warning about reading the table above.** Three shipped features are
invisible to it. `lua bench/evaluate.lua -- affix_words=false` returns
bit-identical accuracy, because no case file contains a coined word; slip
tolerance and the correction store are the same shape. So the 1,484 cases
measure the four matching channels and nothing else, and a change that only
touches the rest can be neither validated nor caught here. `bench/probe.lua`
covers two of the three; the correction store has only its unit tests.

### 5.4 How the weights were chosen, and why that is a weakness

`bench/tune.lua` runs coordinate descent over the ranking weights and edit
budgets, maximising a macro average of `2·top-1 + top-5 + in-rank` across the
case files. Macro rather than micro, so the 1,200 generated cases do not drown
out the 284 hand-written ones.

**How much of that is real?** Starting the descent from the middle of every
grid — the point someone would pick knowing only the plausible ranges — and
scoring on fresh seeds:

```
                        train      held-out    surviving
  untuned start         79.7%        79.5%
  one descent pass      89.9%        88.0%        84%
```

**84% of the tuning gain survives on unseen cases.** The tuning does real work,
and the 1.65 points that did not survive were all the shorthand channel —
whose five fitted constants have since been replaced by a model with none
(§4.5), which is why §5.1 can no longer measure any optimism at all. Coordinate
descent alone does not reproduce the shipped weights — one pass from a neutral
start lands 1.0 points worse held out and breaks two `forms.tsv` cases — so the
shipped values carry hand judgement as well.

Changes found by *hand* have consistently mattered more than the tuning:
pricing a miscounted double letter at 0.55; scoring skeleton candidates by an
asymmetric elastic alignment against the original query; pricing a dropped
apostrophe at 0.15; charging the tail in the shorthand channel. Each moved more
than any weight sweep.

And the tuner has a structural blind spot worth naming. Its grid omits four
constants (`base_exact`, `form_bonus`, `unknown_word_penalty`, and a split base
that turned out to be dead and has since been deleted), which accidentally pins
the gauge freedom of
§4.8 — that is *why* the descent converges at all rather than drifting along a
flat direction. But it also means the tuner cannot express "everything matters
more relative to `base_exact`" except as a simultaneous move of eleven
coordinates, which coordinate descent cannot make. Making that move by hand is
worth more objective than two full passes found — and it is not taken, because
what it buys is three `forms.tsv` cases where the objective's `2·top-1`
weighting exploits an asymmetry, and it costs `inform` → `information`, which
is a real regression the objective cannot see.

## 6. Where it fails now

Almost every remaining loss is a real ambiguity rather than a search failure.
Across all 1,484 cases, 155 (10.4%) do not lead, and of those:

```
  intended word at rank 2       102   66% of misses
                  at rank 3–5    38   25%
                  at rank 6–20   14    9%
                  not offered     1    1%
```

**Almost nothing is ever missing** — one case in 1,484, and it is worth naming
because it used to be zero: `lan`, wanted for `lawn`, which is three letters
against a page of commoner words that explain them. That is the price of a
fuller candidate list, and it is one case.

The rest of the residual is ordering, and 62% of it is ordering between two
readings that are both defensible. In 24% of misses the winning word shares a
four-character prefix with the target — a morphological sibling. **That number
looks more actionable than it is; §8.1 has the measurement.** The classes, from
a full sweep of the case files:

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
every part would need the full fuzzy search at every split point. The missing
capability is running a fuzzy search inside a fuzzy segmentation.

Shorthand used to have the same limit from the other end — the cue channel
requires every letter typed to appear in the word, in order — and slip
tolerance (§4.5) closed it: `stfxctn` now finds `stratification` at rank 3.
That is one wrong letter, not two, and not a wrong first letter; the general
case is still open (§8.9).

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

Four more, added after the review, each of which was implemented and measured
before being abandoned:

- **A cost–frequency interaction**, `w_c · cost · (1 + β(1−f(w)))`, on the
  theory that a large repair to a common word is more believable than the same
  repair to a rare one. The predicted direction is monotonically *wrong* —
  `β = +1.0` costs 30 cases at rank 1 — and the shallow optimum at `β = −0.45`
  turns out to be `w_c` in disguise: it vanishes once `w_c` is 13. Coordinate
  descent leaves it at −0.15, worth one case in 1,484. **They do not interact.**
- **A part-of-speech class bigram** on the previous word (§8.1). Loses on every
  previous word it has an opinion about.
- **Deleting the tail charge** from the shorthand channel once the model was
  normalised, on the theory that the normaliser made it redundant. It did not:
  1.6 points of top-1.
- **Recalibrating `w_c` to the measured optimum** (16 → 13). Raises the
  training objective and is worth −0.12 ± 0.15 points held out. Left alone.

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

### 8.1 Context — and why it is worth less than it looks

This was listed first, as "the single biggest lever". **It was built and
measured, and the honest answer is that one previous word is worth about 0.4
points of top-1.** The reasoning that got it wrong is worth spelling out,
because the same mistake is easy to make about the rest of this list.

The chain was: morphological siblings are 24% of misses → siblings differ in
part of speech → the previous word predicts part of speech. Each link leaks:

```
  36 of 155 misses are morphological siblings           23% of misses
  ... that differ in part of speech at all              ~9   25% of those
  ... decidable from the word on the LEFT               ~5   14% of those
```

The first drop is a bad classifier: most "siblings" differ by *number*
(`effects`/`effect`), by *tense* (`observed`/`observe`), or not at all
(`calendar`/`calender`). The second drop is **structural and no classifier
fixes it**: a determiner precedes an adjective exactly as happily as a noun.
"The regulatory framework" and "the regulator" are both ordinary English, so
every determiner-ambiguous pair is undecidable from one *preceding* word,
however good the table. What survives is noun/verb pairs that `to` versus `the`
separates, and degree adverbs.

The prototype confirms it. A class function (closed-class list plus 44 suffix
rules), a zero-centred `w_ctx · PMI(c(w); c(prev))` term, gated on the previous
token being a dictionary word, applied only within a margin of the leader.
Scored over all 1,484 cases under six fixed previous words — nothing chosen
after the fact:

```
  prev    fixed  broken   net
  the        13      31   −18
  of         11      37   −26
  very       11     108   −97
  and         0       0     0     ← the NEUTRAL row, behaving as designed
```

Sweeping the weight and the margin does not rescue it; the only weight that
does not lose is zero.

**The diagnosis generalises beyond this feature.** Two classifiers were
involved and only one of them was ever measured. The PMI table was written
about parts of speech; the suffix rules select *endings*. "VERB" here means
*ends in -ed, -ing or -ate*, and `P(that | "the")` is nothing like
`P(verb | "the")` — "the building", "the greeting", "the finished draft". So
`DET→VERB = −1.50` demotes precisely the words determiners most often precede,
and about two thirds of the breaks after "the" are an `-ed`/`-ing` word losing
to an `-s`/`-er`/`-or` noun.

The scaffolding survives its own test and ships disabled: zero-centred so an
unknown previous word contributes exactly nothing, a margin derived from the
data rather than guessed (every sibling sits within 9.8 points of the word that
beat it; every *exact* match that beat its sibling leads by at least 19.7), and
points-per-nat matched to the frequency term. `lua bench/context.lua` scores a
replacement table in one command.

**So what is still open.** A counted class table from a tagged lexicon, which
would fix the classifier half. A real word bigram, which is the only thing that
touches the vowel-identity class (`motions`/`meetings`, `blocks`/`blacks`) —
those are noun against noun and no class model can help. And the word on the
*right*, which is where most of the remaining sibling evidence actually lives
and which an input method could in principle see, since the user types it a
moment later.

### 8.2 The scoring function is linear, hand-designed, and fitted on the set it is scored on

Two of the three questions here now have answers, and both were negative.

**Do cost and frequency interact?** No — see §7. One constant, swept and then
put through coordinate descent, lands at zero. The linear form was fine.

**Are the units consistent?** No, and it matters more than the interaction did.
§4.8 has the numbers: the exact-versus-repair decision is decided by a gap
larger than the corpus's whole dynamic range, so it is a veto rather than a
price; and the score has an exact gauge freedom with `confidence_floor` as its
only anchor. Neither was visible before someone asked what a point was worth in
nats.

**What remains is the real one: there is still no data.** The weights are
fitted on the same cases they are scored on, and while §5.1 now bounds the
damage, bounding is not fixing. Two directions:

- **Get real data.** A keystroke log of (what was typed, what was committed)
  turns this into ordinary learning-to-rank. §4.5 is a proof that this works at
  small scale: three of the shorthand channel's numbers are now *counted* from
  known pairs rather than chosen, and coordinate descent agrees with the counts.
  The same trick does not obviously extend to the base scores, which are
  mixture weights over channels and need pairs labelled by which channel was
  right.
- **A fully probabilistic form.** §4.5 shows what this buys and what it does
  not. Normalising one channel removed two hand-built rules and gained ten
  points of held-out accuracy on its own file — but it needed a units constant
  with no probabilistic meaning to beat the hand-tuned version at all, and that
  constant then turned out to be the most consequential dial in the channel.
  A principled treatment has to normalise *across* channels too, which means
  the base scores become real mixture weights and `max` becomes a sum.

### 8.3 One generation model instead of five channels

Generation is currently five hand-built searches with hand-set budgets, tuned
so their unions cover the input space. That is why they do not compose (§6):
each is a separate index strategy.

Is there a single index and a single search that covers exact, prefix, typo,
skeleton and subsequence readings? Some candidates:

- **The alphabetical permutation is already an implicit trie**, which is the
  cheapest version of this idea: the words extending a prefix form a contiguous
  range, and extending the prefix by one character is a binary search that
  narrows it. A best-first search over states `(range, DP column, cost so far)`
  is a Levenshtein automaton without the automaton, in *zero* extra memory, and
  it subsumes exact, prefix and typo in one pass with the cost profile as a
  parameter. (Building an actual trie in Lua tables would blow the memory
  budget at ~100 bytes a node — this avoids that entirely.)
- It is unlikely to reach the shorthand channel, though: with vowel skips that
  cheap the search fans out over every vowel of every word, and a bucketed scan
  with a letter-set test is the honest structure for subsequence matching.
- **A learned or hashed sketch** — SymSpell-style deletion neighbourhoods, or
  an LSH over character n-grams — as a recall stage feeding an exact re-ranking
  stage. The current bit-mask prefilter is a crude version of exactly this, and
  there is a cheap sharpening available: **per-first-letter bitsets**, 26 of
  them over each bucket, one per letter, saying which words contain it. Lua 5.4
  has 64-bit integers, so a 3,000-word bucket is ~50 integers per letter and
  the whole structure is tens of kilobytes. The letter-set test becomes `|q|`
  ANDs of 50 integers instead of a 3,000-word walk — which is also what would
  make relaxing the first-letter requirement affordable.
- Note the asymmetry that makes standard techniques awkward. In plain
  Levenshtein terms the intended answers sit at distance 6 (`satfcatn` →
  stratification), 5 (`gvmnt` → government), 4 (`mthmtcs` → mathematics) — well
  outside the radius any deletion-neighbourhood or BK-tree index can afford on
  83k words. The whole point of the four cost models is that these are *not*
  distance-6 errors under the right metric; they are distance-0.86 shorthands.
  Any recall structure keyed on small *uniform* edit distance fails on exactly
  the inputs that matter most.

### 8.4 Fuzzy composition

Two things were hiding in this item and **one of them is now done**. A slip
*inside* shorthand needed only a substitution transition in the subsequence DP
and a letter-set test relaxed from "every letter appears" to "at most one does
not" — same scan, same budget structure. It takes corrupted shorthands from
28% to 85% on the first page and ships off for latency (§8.9), not because it does not
work.

Fuzzy *segmentation* is the expensive half and is still open: `exctlyrght` →
`exactly right`. The obvious formulation is a lattice — run the fuzzy search at
every split point, take the best path — and the obvious problem is that the
current word-break DP does an O(1) dictionary lookup per (position, length)
pair, and a bounded fuzzy search is several hundred times that.

There is a reuse trick that makes it tractable. Align a dictionary word against
the query with the *query* as the DP's row index, and the final column gives the
cost of that word explaining every prefix `q[1..i]` **at once** — so one DP per
candidate word yields all of its split points. A two-word lattice then needs one
bounded search from position 1 plus one from each surviving split point, gated
on the single-word channels having found nothing trustworthy, which §4.9 already
computes. Most keystrokes never pay.

### 8.5 Better frequency data

The corpus is Google-Books-derived: it skews old and literary and keeps proper
nouns as ordinary lowercase tokens, so `mathew`, `mather` and `mathews` all
compete with `mathematics` for the input `mathe`. `wordfreq` (a blend of subtitles, web,
Wikipedia and news) and the OpenSubtitles frequency lists are both open and both
fix this directly, because names are rare in speech-like text. Blend in the log
or Zipf domain rather than in counts, so scale differences do not matter. And
treat capitalised-in-corpus tokens as their own *class* rather than demoting
them — those tokens are exactly what somebody typing a surname wants. This is
probably worth more top-1 than any further weight tuning, but it is a data
problem, not an algorithm problem, and it is easy to make worse.

A related question that now has half an answer: the frequency term uses a
*normalised log* frequency in [0,1], which compresses rank 100 against rank
10,000 into very little score. That is deliberate — a linear-in-count term
would make `the` unbeatable — and §4.8 shows what the compression actually
costs: across the band people type, the entire frequency spread is 4.7 nats,
which cannot buy a single full-price edit. Using Zipf units directly and letting
the points-per-nat calibration set the weight is the principled version.

### 8.6 Incremental search

Consecutive keystrokes re-search from scratch. Restricting the next scan to the
previous candidate set plus one edit should cut typical latency several-fold —
and that is now the headroom that §8.9, §8.4 and any use of §8.1 all need.

The non-monotonicity noted here originally is real for the *budget-cut* set but
not for a **slack** set, which is the way through. Appending one character
changes a word's alignment cost by at most one edit's worth, `Δ`, so every word
inside budget for `q + c` was inside `budget + Δ` for `q` — *provided it was
visited at all*, and that proviso is the only real work: widen the length window
by one at generation time, keep the slack pool along with its DP rows, extend
every kept row by one character per keystroke, and re-generate only for the
newly admissible length bucket. For the shorthand channel it is cleaner still,
since both the subsequence property and the letter-set test are monotone in `q`
— the pool only ever shrinks, apart from the growing length ceiling.

### 8.7 Remember the input, not just the word

Store `(typed, committed)` pairs and score an exact match on the typed form
highly. Every correction the user makes once becomes permanent. This is a
contained change and probably the cheapest real win on the list.

The design every CJK input method converged on answers the "one accident
becomes permanent" worry without asking the user to press anything: store
`(typed, committed, count, last used)`, treat an exact match on `typed` as a
source with a high base, but let it **lead** only once `count` reaches 2. One
selection earns a bonus that cannot overturn the leader; the second promotes
it. Decrement when the stored candidate is shown and not chosen, and cap the
file by least-recently-used. It also removes the `eys`/`eyes` pathology from
the general vocabulary term, because the misspelling is then tied to the input
that produced it rather than raised everywhere.

And it is the same store §4.5 needs: the pairs it holds are exactly what the
shorthand channel's keep probabilities are counted from, which makes this the
one item on this list that two others depend on.

### 8.8 A tagged lexicon, or any counted table

Three separate items above (§8.1's class table, §8.5's name class, §8.3's
sketch) are blocked on the same thing: a source of word-level annotation that
is not somebody's intuition. §8.1 is the cautionary tale — a hand-written table
of 44 suffix rules produced a classifier whose classes did not mean what the
table assumed, and *both halves came from the same head*, which is the honest
reason to distrust anything positive it could have reported.

### 8.9 The gate that two features are waiting for

Twice now the answer to "this is real recall at a cost on every keystroke" has
been the same, and nobody has built it:

| feature | what it buys | what it costs |
| --- | --- | --- |
| `scan_first_neighbours` | a wrong first key, 1.6% → 98.2% on page 1 | +27% per keystroke, p95 over budget |
| slip-tolerant shorthand | corrupted shorthand, 28% → 85% on page 1 | +0.35 ms per keystroke |

The second is now **on**, which spends about a third of the remaining p95
headroom on it; the first is still off, and would spend the rest. Both would be free
almost all the time if they ran as a **second pass, gated on
`Engine:trustworthy` finding nothing worth putting under the space bar** — a
predicate that already exists and is already computed (§4.9). The common
keystroke, where the first pass succeeds, would pay nothing at all.

This is a small piece of work with two features behind it, and §8.6 would make
it cheaper still.

---

## 9. Reproducing everything here

```bash
git clone https://github.com/EricWay1024/spellless && cd spellless
make            # rebuild dictionary, indexes and generated test sets
make test       # 2,125 assertions, including every hand-written case
make bench      # the accuracy and latency tables in §5
lua bench/try.lua --debug mthmtcs satfcatn tnk     # ask it anything

# the held-out measurement of §5.1 -- the generator is seeded, so this is free
python3 scripts/make_testset.py --seed 12345 --out /tmp/fresh
lua bench/evaluate.lua --cases /tmp/fresh

lua bench/tune.lua 3                        # the coordinate descent of §5.4
lua bench/tune.lua 1 --start midgrid        # ... from a neutral start
lua bench/tune.lua 1 --exclude generated_cues   # ... leave-one-file-out
lua bench/context.lua                       # score a class table (§8.1)
lua bench/probe.lua                         # the harsher probes of §5.2
```

Typing `zzver` into the input method itself reports the running build — the
revision, the install time, the loaded dictionary and the live configuration.
The first line comes from a module the installer rewrites rather than a data
file, so it names what the *process* loaded rather than what is on disk, which
is the only version of the question worth asking.

The matcher is pure Lua with no dependencies and knows nothing about the input
method: `rime/lua/spellless/` is the algorithm, `rime/lua/spellless.lua` is the
adapter that wires it to Rime, and `tests/` and `bench/` exercise exactly the
code the IME runs.

`DESIGN.md` covers the input-method side — spacing, capitalisation, what the
frontend can do that a schema cannot. `EVALUATION.md` is the long-form version
of §5. `data/README.md` documents the corpus and its preprocessing.
`prompt/expert-review.md` is the review this document was revised against.

Most of what is worth knowing about a constant is written next to it in
`rime/lua/spellless/config.lua`, including the sweeps that were run and not
acted on.
