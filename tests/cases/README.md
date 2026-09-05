# Evaluation cases

Each `*.tsv` file holds one case per line:

```
input <TAB> expected <TAB> max_rank
```

* `expected` may offer alternatives separated by `|`; any of them satisfies the
  case.  The literal `=raw` means "the untouched input must appear here".
* A leading `!` inverts the case: the word must **not** appear at or above
  `max_rank`.
* `max_rank` defaults to 1.

`generated_*.tsv` are produced by `scripts/make_testset.py` from the shipped
dictionary with a fixed seed; the others are written by hand.
