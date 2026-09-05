# Evaluation

Enough evidence to tune the implementation rather than pick weights by
intuition — not a publication benchmark.

Reproduce with:

```bash
lua bench/evaluate.lua                 # the table below
lua bench/evaluate.lua skeletons       # one file
SHOW_FAILURES=40 lua bench/evaluate.lua
lua bench/tune.lua 2                   # coordinate descent over the weights
```

Numbers below are from a single-threaded Lua 5.4.7 build on WSL2
(x86-64 laptop), dictionary of 82,880 words.

---

## The test set

1,056 cases in `tests/cases/`, in two kinds.

**Hand-written (208 cases).** What the brief asks for, plus the failure modes
worth guarding:

| file | what it pins down |
| --- | --- |
| `spec_examples.tsv` | every example in the brief, verbatim |
| `common_typos.tsv` | 63 well-known English misspellings, including 12 pure adjacent transpositions |
| `skeletons.tsv` | consonant-only input, including deliberately mistyped skeletons |
| `prefix.tsv` | ordinary correctly-spelled typing and completion |
| `ambiguity.tsv` | short input with several legitimate readings, and misspellings that are themselves words |
| `raw.tsv` | the literal input stays reachable, and leads when nothing is trustworthy |
| `forms.tsv` | dropped apostrophes, the pronoun "I", and abbreviations typed without their dots |
| `literal.tsv` | short and capitalised input — variables, units and acronyms — leading with itself |

**Generated (900 cases),** by `scripts/make_testset.py` with a fixed seed, from
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

`in-rank` is the per-case budget written in the file — some cases legitimately
allow rank 3 or 5 rather than 1, because the input does not carry enough
information for one answer.

---

## Results

```
file                          cases   top-1   top-5 in-rank
------------------------------------------------------------
ambiguity.tsv                    16   50.0%  100.0%  100.0%
common_typos.tsv                 63   96.8%  100.0%  100.0%
forms.tsv                        32   65.6%  100.0%  100.0%
literal.tsv                      20  100.0%  100.0%  100.0%
generated_skeletons.tsv         400   87.5%   98.5%   98.5%
generated_typos.tsv             500   89.8%   98.4%   98.4%
prefix.tsv                       16   93.8%  100.0%  100.0%
raw.tsv                          14   71.4%   85.7%  100.0%
skeletons.tsv                    31   96.8%  100.0%  100.0%
spec_examples.tsv                16   68.8%   87.5%  100.0%
------------------------------------------------------------
TOTAL                          1108   88.0%   98.4%   98.7%
```

**Top-1 88.0%, top-5 98.4%, every case within its budget 98.7%** — and every
one of the 208 hand-written cases passes.

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
  transpose                     120   96.7%  100.0%     <- the class the brief singles out
  insert  (doubled letter)      135   97.8%  100.0%
  substitute (neighbour key)    123   91.1%  100.0%
  delete                        122   68.9%   95.1%
```

Deletion is much the hardest, and unavoidably so: dropping a letter makes the
input shorter *and* moves it closer to other real words, so `sho` (from `shoe`)
sits behind `show`, `shop`, `should`. There is no evidence in the input that
would justify ranking `shoe` first.

### By skeleton length

```
                              cases   top-1   top-5
  4 consonants                  120   72.5%   94.2%
  5                             122   86.9%  100.0%
  6                              95   91.6%  100.0%
  7                              36   97.2%  100.0%
  8                              22   90.9%  100.0%
  9                               5  100.0%  100.0%
```

Abbreviations become reliable from about five consonants — which matches how
people actually abbreviate. The four-consonant cases are frequently ambiguous
by construction (`clss` is `class` as much as it is `closes`).

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
over all 1,085 evaluation queries
  mean 2.15 ms   median 1.45 ms   p95 5.86 ms

typing nine words out, one keystroke at a time (86 keystrokes)
  mean 1.44 ms
  by input length (ms)
    1: 1.8   2: 0.8   3: 0.8   4: 0.9   5: 1.3   6: 1.0   7: 1.4
    8: 2.6   9: 3.0  10: 2.2  11: 1.6  12: 1.7  13: 1.6  14: 0.9

startup   104 ms, once per process (memoised across engines)
memory    13.9 MB after loading, 16.8 MB steady state
```

The second block is the number that matters: it is what a keystroke costs while
a word is actually being typed. The peak around 8–9 characters is where the
length buckets are fullest and both the typo scan and the skeleton scan run.

For scale: running just the typo source naively — weighted edit distance
against all 82,880 words, no buckets, no prefilter — measures **105–115 ms per
query** in the same Lua build (`bench/naive.lua`). The bucketing and prefilters
described in DESIGN.md §4.4 do that work *and* the skeleton search in about
2 ms, roughly a 50× reduction with no measured loss of recall.

---

## How the weights were chosen

`bench/tune.lua` runs coordinate descent over the ranking weights and edit
budgets, maximising a macro average of `2·top-1 + top-5 + in-rank` across the
case files. Macro rather than micro, so the 900 generated cases do not drown
out the 156 hand-written ones.

Two rounds moved the objective from 3.4896 to 3.6002 and changed:

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

`tests/run.lua` runs 1668 assertions, and `tests/test_install.py` another 32, including every hand-written case at its
stated budget and accuracy floors a few points below the numbers above for the
generated sets. Ordinary tuning does not trip it; a real regression does.
