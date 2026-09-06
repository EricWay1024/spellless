# Evaluation

Enough evidence to tune the implementation rather than pick weights by
intuition — not a publication benchmark.

Reproduce with:

```bash
lua bench/evaluate.lua                 # the table below
lua bench/evaluate.lua skeletons       # one file
SHOW_FAILURES=40 lua bench/evaluate.lua
lua bench/tune.lua 2                   # coordinate descent over the weights
lua bench/probe.lua                    # the two harsher probes below
```

Numbers below are from a single-threaded Lua 5.4.7 build on WSL2
(x86-64 laptop), dictionary of 83,151 words.

---

## The test set

1,535 cases in `tests/cases/`, in two kinds.

**Hand-written (335 cases).** What the brief asks for, plus the failure modes
worth guarding:

| file | what it pins down |
| --- | --- |
| `spec_examples.tsv` | every example in the brief, verbatim |
| `common_typos.tsv` | 63 well-known English misspellings, including 12 pure adjacent transpositions |
| `skeletons.tsv` | consonant-only input, including deliberately mistyped skeletons |
| `prefix.tsv` | ordinary correctly-spelled typing and completion |
| `ambiguity.tsv` | short input with several legitimate readings, and misspellings that are themselves words |
| `raw.tsv` | the literal input stays reachable, and leads when nothing is trustworthy |
| `rare_words.tsv` | a word you typed that is much rarer than one it completes, in both directions |
| `forms.tsv` | dropped apostrophes, the pronoun "I", and abbreviations typed without their dots |
| `literal.tsv` | short and capitalised input — variables, units and acronyms — leading with itself |
| `syllables.tsv` | syllabic shorthand: one or two letters per syllable, several different spellings of the same word |

**Generated (1,200 cases),** by `scripts/make_testset.py` with a fixed seed, from
words ranked 150–12,000 (what people actually type; deeper into the tail you
measure the corpus, not the matcher):

(The generated files are re-derived from the current dictionary, so changing
the dictionary reshuffles which words they sample. Compare runs across a
dictionary change with that in mind.)

* 500 typos — one plausible slip each: adjacent transposition, deletion,
  doubled letter, or a neighbouring-key substitution. Corruptions that are
  themselves dictionary words are excluded, because those are a different
  question (see `ambiguity.tsv`).
* 400 consonant skeletons of words ≥ 6 letters, excluding skeletons that are
  themselves words.
* 300 syllabic shorthands of words ≥ 6 letters: the word is cut into rough
  syllables and one or two letters are taken from each, biased towards the
  first. Two filters keep the set honest, and both are about ambiguity rather
  than difficulty. A word with a commoner word as a prefix is skipped, because
  shorthand for `productions` is shorthand for `product` too. And the shorthand
  itself is skipped unless the target is the **most frequent** word whose
  letters it appears in, in order — otherwise `untl` would be scored against
  `untitled` while `until` sits right there. Neither filter consults the
  matcher; both use only the property the generator guarantees.

`in-rank` is the per-case budget written in the file — some cases legitimately
allow rank 3 or 5 rather than 1, because the input does not carry enough
information for one answer.

---

## Results

```
file                          cases   top-1   top-5 in-rank
------------------------------------------------------------
ambiguity.tsv                    16   50.0%   93.8%  100.0%
common_typos.tsv                 68   97.1%  100.0%  100.0%
forms.tsv                        42   76.2%  100.0%  100.0%
generated_cues.tsv              300   86.0%   98.3%   98.3%
generated_skeletons.tsv         400   91.5%   99.5%   99.5%
generated_typos.tsv             500   90.2%   99.2%   99.2%
literal.tsv                      24  100.0%  100.0%  100.0%
prefix.tsv                       28   96.4%  100.0%  100.0%
rare_words.tsv                   39   89.7%  100.0%  100.0%
raw.tsv                          14   71.4%   78.6%  100.0%
skeletons.tsv                    31  100.0%  100.0%  100.0%
spec_examples.tsv                16   75.0%   87.5%  100.0%
syllables.tsv                    57   98.2%  100.0%  100.0%
------------------------------------------------------------
TOTAL                          1535   89.6%   98.9%   99.3%   <- shipped seed

held out, five fresh generator seeds:
                                      88.9%   98.9%
                                      91.1%   99.5%
                                      90.6%   99.6%
                                      90.4%   99.2%
                                      89.2%   99.1%
------------------------------------------------------------
TOTAL                          1535   90.0%   99.3%          <- held out, mean
```

**Top-1 90.0%, top-5 99.3%** — held out, and every one of the 335 hand-written
cases passes. The three generated rows swing two or three points against each
other from one seed to the next while the total does not, so read the total.

The generated sets come from a seeded generator, so a fresh seed is a free
held-out set; the second block is the mean of ten. On the seed the weights were
originally fitted to, the same table reads **89.6% / 99.0%** — *below* the
held-out mean, by less than a third of the seed-to-seed standard deviation.
There is no in-sample optimism left to correct for, which was not true when
this file was first written; docs/ALGORITHM.md §5.1 has what changed and why.
docs/ALGORITHM.md §5 is the short version of everything below.

Three files deserve a footnote, because their low top-1 is the *intended*
result. `spec_examples.tsv` asks for `mathematics`, `mathematical` **and**
`mathematician` from the same input `mathe`, so at most one of the three can be
first. Half of `raw.tsv` asks for the literal input to be on the first page
while a correction leads. And most of `forms.tsv` is inputs like `its`,
`were`, `cant` and `lets` that are real words in their own right: those must
come first, with the contraction immediately behind — both halves of that are
asserted.

### By error class

```
                              cases   top-1   top-5
  transpose                     117   95.7%  100.0%     <- the class the brief singles out
  insert  (doubled letter)      126   96.8%  100.0%
  substitute (neighbour key)    130   94.6%   98.5%
  delete                        127   81.9%   97.6%
```

Deletion is still the hardest, and unavoidably so: dropping a letter makes the
input shorter *and* moves it closer to other real words, so `sho` (from `shoe`)
sits behind `show`, `shop`, `should`. There is no evidence in the input that
would justify ranking `shoe` first.

It is also the class the syllable-cue channel helps most, because a dropped
letter *is* a one-letter shorthand. Switching the channel off leaves deletion
at 70.1% / 96.9% and lifts each of the other three rows by a point or so
(insert 97.6%, substitute 96.2%, transpose 96.6%) — the trade is deliberate,
and worth taking at eleven points against three.

### By skeleton length

```
                              cases   top-1   top-5
  4 consonants                   94   84.0%  100.0%
  5                             128   91.4%  100.0%
  6                             106   98.1%  100.0%
  7                              43  100.0%  100.0%
  8                              19  100.0%  100.0%
  9                              10  100.0%  100.0%
```

Abbreviations become reliable from about five consonants — which matches how
people actually abbreviate. The four-consonant cases are frequently ambiguous
by construction (`clss` is `class` as much as it is `closes`).

### Syllabic shorthand

This is the channel added last, and the only fair way to judge it is against
the same matcher without it. Both columns are the current build; the left one
sets `min_cue_len` beyond any query, which switches the channel off and changes
nothing else.

```
                        without cues        with cues
  generated_cues (300)  36.7% / 45.0%    88.0% /  99.3%     top-1 / top-5
  syllables      (57)   59.6% / 77.2%    98.2% / 100.0%
```

A harsher probe, because the case files are built from plausible shorthand
rather than desperate shorthand: take 261 corpus words of seven letters or
more and delete two letters at random. `lua bench/probe.lua`, seeded, so it can
be re-run rather than believed.

```
                        without cues        with cues
  nothing offered at all      8.8%             0.0%
  right word first           23.8%            68.2%
  right word on page 1       45.2%            93.1%
```

The same script's second probe takes the cue case file — input the matcher
answers at 88% — and mistypes one letter of each, which is the class slip
tolerance exists for:

```
                        slip off            slip on
  nothing offered at all     27.3%             0.0%
  right word first           20.0%            22.4%
  right word on page 1       28.3%            85.4%
```

The first row is the one that changed the project. An input that offers
*nothing* is not a ranking failure, it is a dead end: the only thing under the
space bar is the misspelling you just typed, and if you commit it the learner
remembers it. `alghrith` used to be exactly that.

Nothing else regressed. No hand-written file moved down, and the two
non-syllabic generated files went **up** — typos 90.0% → 92.2%, skeletons
84.5% → 93.0% in the two columns above — because a dropped letter is itself a
one-letter shorthand, and because the skeleton scan now compares against a
*prefix* of the word's skeleton, so a half-typed abbreviation with a slip in it
still finds its word (DESIGN.md §4.2).

Case by case across those 900, the channel takes 53 cases from *not* first to
first and 8 the other way. All eight of the losses land at rank 2, to a rival
that is a fair reading of the input:

```
  importt  wanted import,   got important
  slovka   wanted slovak,   got Slovakia
  rabd     wanted rand,     got rabid
  hassls   wanted hassle,   got hassles
  mtns     wanted motions,  got meetings
  bnss     wanted bonuses,  got business
  wrrnts   wanted warrants, got warranties
  flng     wanted filing,   got feeling
```

That is the shape of the trade: a looser reading occasionally puts a commoner
word in front of the one that was meant, and never further than one keystroke
away.

### Negative and ambiguity cases

These are in `ambiguity.tsv`, and passing them means *not* being over-confident:

* `frm` → `from`, `form`, `firm`, `farm`, `forum`, `forms` — six live readings,
  ordered by frequency, all on the first page.
* `form` and `from` are both real words and each is its own first candidate;
  neither displaces the other, and the alternative is still nearby.
* `their` / `there` likewise.

---

## Latency

```
over all 1,535 evaluation queries
  mean 2.9 ms   median 2.2 ms   p95 7.8 ms

typing nine words out, one keystroke at a time (86 keystrokes)
  mean 2.3 ms
  by input length (ms)
    1: 0.9   2: 0.8   3: 0.9   4: 1.9   5: 4.7   6: 2.3   7: 2.2
    8: 3.6   9: 4.1  10: 3.5  11: 2.5  12: 2.5  13: 2.5  14: 1.5

startup   104 ms, once per process (memoised across engines)
memory    13.9 MB after loading, 17.6 MB steady state
```

The second block is the number that matters: it is what a keystroke costs while
a word is actually being typed. The peak around 8–9 characters is where the
length buckets are fullest and every scan runs at once.

The syllable-cue channel costs less than it looks: 1.57 ms per keystroke
without it against 1.71 ms with, on a tighter repeated-prefix benchmark. It
is a scan over whole first-letter buckets rather than a narrow length window,
so it is bounded instead by a strict letter-set test, a length ratio, and being
skipped entirely whenever the query is itself a word — which is most of what
anyone types.

For scale: running just the typo source naively — weighted edit distance
against all 83,151 words, no buckets, no prefilter — measures **105–115 ms per
query** in the same Lua build (`bench/naive.lua`). The bucketing and prefilters
described in DESIGN.md §4.5 do that work *and* the skeleton and cue searches in
about 2.5 ms, roughly a 40× reduction with no measured loss of recall.

---

## How the weights were chosen

`bench/tune.lua` runs coordinate descent over the ranking weights and edit
budgets, maximising a macro average of `2·top-1 + top-5 + in-rank` across the
case files. Macro rather than micro, so the 1,200 generated cases do not drown
out the 335 hand-written ones.

The first round, before the syllable-cue channel existed, moved the objective
from 3.4896 to 3.6002 and changed:

| parameter | from | to | effect |
| --- | --- | --- | --- |
| `freq_weight` | 26 | 34 | `teh` → `the` instead of `tehran`: a very common word reached by a cheap repair should beat a rare exact prefix |
| `cost_weight` | 15 | 19 | accuracy of the repair matters more than the popularity of the result |
| `base_prefix` | 80 | 74 | prefix completions were monopolising short inputs |
| `base_typo` | 72 | 75 | |
| `base_skeleton` | 70 | 66 | |
| `typo_budget` | 1.8 | 1.35 | a tighter budget removed noise without losing recall (top-5 rose) |
| `confidence_cost` | 1.0 | 1.5 | how much repair is believed before the literal input is demoted from first place |
| `confidence_floor` | 70 | 62 | |

Adding the cue channel and its two new case files changed what the shared
weights should be, so the same descent was re-run over all thirteen files. It
moved the objective from 3.6382 to 3.6854 and changed:

| parameter | from | to | effect |
| --- | --- | --- | --- |
| `base_cue` | 58 | 70 | a cue reading is worth more than the first guess allowed |
| `cue_vowel_bonus` | 30 | 10 | with the base that much higher, the "is this consonantal?" signal does not need to carry it |
| `cue_skip_vowel` | 0.08 | 0.04 | skipped vowels are worth even less than assumed |
| `cue_skip_onset` | 0.85 | 0.60 | |
| `cost_weight` | 19 | 16 | the cue channel measures cost on its own scale, so the shared multiplier had to come down |
| `extra_weight` | 12 | 8 | |
| `base_skeleton` | 66 | 62 | some of what it was carrying is now the cue channel's work |
| `skeleton_vowel_bonus` | 14 | 10 | likewise |

A third pass found one more move — `cost_weight` 16 → 13, worth 0.005 — and it
was not taken. It leaves top-1 exactly where it is and simply trades typo
accuracy for shorthand accuracy (typos 92.2% → 91.0%, syllabic 85.7% → 88.0%),
which is a judgement about what people type rather than something the case
files can settle.

Changes found by *hand* mattered considerably more than the tuning itself:

* pricing a **miscounted double letter** at 0.55 rather than 1.00
  (`commited` → `committed`, `harrass` → `harass`) — this was the largest
  single class of residual failures;
* scoring skeleton candidates by an **asymmetric elastic alignment against the
  original query** rather than skeleton-to-skeleton, so typed vowels count as
  evidence (DESIGN.md §4.3). Before this, `mathe` matched `mouth` and
  `theorme` matched `thermal` as cheaply as `mthmtcs` matched `mathematics`;
* pricing a **dropped apostrophe** at 0.15, and lifting the corpus's absurd
  contraction frequencies (§ data/README.md). Together these take `dont` →
  `don't` from unreachable to rank 1, and cost nothing elsewhere;
* refusing to trust a completion of one or two characters, or of capitals
  (`literal.tsv`). An adversarial audit found `x` → `xxx`, `cm` → `come` and
  `CW` → `COW` sitting under the space bar, which is the one failure mode that
  corrupts a document silently.

## Regression protection

`tests/run.lua` runs 2130 assertions, and `tests/test_install.py` another 50, including every hand-written case at its
stated budget and accuracy floors a few points below the numbers above for the
generated sets. Ordinary tuning does not trip it; a real regression does.
