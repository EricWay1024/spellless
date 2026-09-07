# The pipeline, end to end

**What happens to one keystroke, in order, with the reason for each step.**

Written for someone who has never seen this program and wants to criticise its
design without reading four thousand lines of Lua. The spine is pseudocode; the
prose after each block says why it is that way and what broke when it was not.
Every function and constant name is the real one, so anything here can be
checked against the source.

Companion documents: `docs/ALGORITHM.md` is the algorithm as a decision problem,
with the evaluation; `DESIGN.md` is the input-method side; `data/README.md` is
the corpus. This document is the one that walks the whole path.

**Notation.** `←` is assignment, `=` is comparison, `[]` is a list, `//` starts
a comment. Indentation is block structure. `foo.lua:bar` is a source location.

**Measured today** (Lua 5.4, WSL2, one core), so the numbers below are
reproducible rather than remembered:

```
lua tests/run.lua      2316 checks, 0 failures
lua bench/evaluate.lua 1535 cases   top-1 91.1%   top-5 99.0%   in-rank 99.4%
                       latency mean 2.87 ms  median 2.12 ms  p95 7.55 ms  max 18.49 ms
                       typing nine words out: 2.28 ms mean over 86 keystrokes
                       17.7 MB resident after 1,535 queries
corpus                 83,414 words, 809 surface forms, 103 companion capitals
Corpus.load            73 ms, 14.1 MB
naive full scan        138 ms for one query against all 83,414 words
```

> **On the numbers.** This document was written against the tree, not against
> the other documents, and where it disagreed with them it was right: eleven of
> the twelve discrepancies in §G.6 have since been fixed, including one that
> changed shipped behaviour. The figures here are what the code does today.
> Quote **89.8% ± 0.6 top-1 held out**; the 91.1% printed by
> `lua bench/evaluate.lua` includes 335 cases the weights were written for.

---

## Contents

- [A. Setting](#a-setting)
- [B. Data and the build](#b-data-and-the-build)
- [C. The query pipeline](#c-the-query-pipeline)
- [D. Interaction](#d-interaction)
- [E. Learning](#e-learning)
- [F. Edge cases, and what motivates each](#f-edge-cases-and-what-motivates-each)
- [G. Known weaknesses and open questions](#g-known-weaknesses-and-open-questions)

---

## A. Setting

### A.1 The problem

A person knows a word and cannot produce its spelling at the speed they think.
They type an approximation — `recieve`, `mthmtcs`, `satfcatn`, `exactlyright` —
and the system returns a short ranked list containing the word they meant, fast
enough that typing does not stutter.

This is not spelling correction. `mthmtcs` is not a misspelling of
`mathematics`; it is a lossy encoding the typist chose, and under any uniform
edit metric the two are four deletions apart — further than `mathematics` is
from dozens of unrelated words. The interesting queries are *not* in the
low-distance neighbourhood of their answer.

It is also not autocorrect. The user is in the loop, so the loss function is
asymmetric: the system may propose seven readings and be wrong about six,
provided the seventh is there. Recall at 5 is cheap to buy and expensive to
lose.

### A.2 What a Rime schema is

[Rime](https://rime.im) is an input-method engine. A *schema* is a YAML file
naming an ordered list of **processors** (see a key first), **segmentors** (cut
the input into segments), **translators** (turn a segment into candidates) and
**filters** (rewrite the candidate list). librime-lua lets any of those four be
a Lua module.

Spellless ships no dictionary file, no spelling-algebra rules and no regex lists
of known misspellings. It is one schema plus five Lua gears:

```
rime/spellless.schema.yaml   engine:
  processors:
    lua_processor@*spellless*handover     [1]  M.handover    the $ that ends an ASCII
                                                             run; editor snippets; qq
    ascii_composer                             Rime          Caps Lock / ASCII mode
    recognizer                                 Rime          foo_bar, urls, emails
    key_binder                                 Rime
    lua_processor@*spellless*absorb       [2]  M.absorb      pick up a word already in
                                                             the document; PICKED note
    speller                                    Rime          builds the composition
    lua_processor@*spellless*processor    [3]  M.processor   spaces, punctuation,
                                                             Return, Backspace, modes
    punctuator                                 Rime
    selector                                   Rime          number keys, paging
    navigator                                  Rime
    express_editor                             Rime          Return = commit raw input
  segmentors:
    ascii_segmentor, matcher, abc_segmentor, punct_segmentor, fallback_segmentor
  translators:
    punct_translator                           Rime
    lua_translator@*spellless             [4]  M.func        the candidate list
  filters:
    uniquifier                                 Rime
    lua_filter@*spellless*filter@punct_spacer
                                          [5]  M.filter      the space after punctuation
```

The positions are all load-bearing:

* **[1] before `ascii_composer`.** In ASCII mode that processor rejects every
  printable key *where it stands* and nothing behind it runs — so a `$` that
  should bring us back out of maths would never be seen by anything later.
  Being before the speller matters too: the speller consumes letters and returns
  `kAccepted`, so a snippet trigger has to be recognised in front of it.
* **[2] before the `speller`**, same reason: it is the only gear that sees
  *every* key, which is why the "was the last key a Backspace" flag is kept
  there and nowhere else.
* **[3] after the speller** (so it never sees a letter) **and before the
  punctuator** (so it can end the word before the mark is written).
* **[5]** only fires with `ascii_punct` **off**. With it on — which this schema
  sets, and which is what anyone writing English wants — librime's punctuator
  returns `kNoop` and never creates a candidate at all, so gear [3] writes the
  mark itself.

`rime/lua/spellless.lua` is the whole of the Rime dependency. Everything under
`rime/lua/spellless/` is plain Lua that has never heard of an input method,
which is why `tests/` and `bench/` exercise exactly the code the IME runs.

### A.3 Invariants any replacement must preserve

From `docs/ALGORITHM.md` §8.0, stated up front because they rule out otherwise
attractive designs:

1. **The literal input is always reachable**, in a predictable slot, and leads
   when nothing is trustworthy. No design may make it hard to type `kubectl`.
2. **Nothing commits without the user choosing it.** No auto-selection
   (`speller/auto_select` is deliberately off), no silent replacement.
3. **Recall at 5 is worth nearly as much as precision at 1.** Trading three
   points of top-5 for one of top-1 is a bad trade here, though it would be a
   good one for autocorrect.
4. **Under 10 ms at p95, in interpreted Lua, with no compiled dependency.** The
   last clause is what makes it installable by a non-programmer on Windows
   without administrator rights.
5. **Explainable and undoable.** A user must be able to see why a candidate is
   there and remove anything the system learned by accident.

There is a sixth, added later and enforced by a test
(`tests/test_engine.lua`, "after a modal, the bare verb comes forward"):

6. **Whether the matcher trusts its own answer is a question about the input
   alone.** A context feature may reorder the page; it may never decide whether
   the literal leads. See §C.7.

### A.4 The budget

| | |
| --- | --- |
| Latency | 2.28 ms mean while a word is actually being typed; p95 7.55 ms over the whole evaluation set, against a self-imposed 10 ms |
| Scale | a naive weighted edit distance against all 83,414 words, *with* the budget and early abort, costs 138 ms. The budget is under 1/60th of a full scan |
| Memory | 14.1 MB to load, 17.7 MB steady state, once per process |
| Startup | 73 ms, memoised per data directory *and* generation of the files in it |
| Shipped data | ~1.3 MB in `generated/` |
| Dependencies | none. Pure Lua 5.4, no JIT, no compiled extension, no network |

---

## B. Data and the build

### B.1 The five shipped files

Built offline by `scripts/build_dictionary.py` and `scripts/build_indexes.py`,
shipped in `generated/`:

| file | size | what it holds |
| --- | --- | --- |
| `spellless.words` | 758 kB | 83,414 words, newline separated, **most frequent first** |
| `spellless.weights` | 83 kB | one byte per word: `round(255·(log f − log f_min)/(log f_max − log f_min))` |
| `spellless.alpha` | 250 kB | word ids sorted alphabetically, u24 little-endian |
| `spellless.skel` | 250 kB | word ids sorted by consonant skeleton, u24 |
| `spellless.forms` | 14 kB | `key <TAB> spelling [<TAB> +]`, 912 lines |

**The single most useful decision here is that a word's id is its frequency
rank** — the 1-based line number in `spellless.words`. Picking the best few
entries out of an index range then needs no sort and no frequency lookup: the
smallest ids in the range are the commonest words, and `util.top(n)`, a bounded
"keep the n smallest" selector, does it in one pass. Every bucket built at load
time inherits that ordering for free, which is why hitting a check ceiling drops
the *least likely* words rather than an arbitrary slice.

The weights are read straight out of the string with `string.byte`, so there is
no parsing and no scaling constant anywhere in the Lua
(`corpus.lua:Corpus:weight`).

### B.2 What is derived at load, and why it is not shipped

```
Corpus.load(dir):                                        // corpus.lua:157
    key ← dir .. "\0" .. Corpus.fingerprint(dir)
    if cache[key] exists: return it
    words ← split(slurp(dir/spellless.words), "[^\r\n]+")
    weights, alpha_blob, skel_blob ← slurp(the three blobs)
    if #weights ≠ n or #alpha_blob ≠ 3n or #skel_blob ≠ 3n:
        return nil, "generated files disagree"
    derive(self)
    forms, capitals, abbreviations ← parse spellless.forms
    cache[key] ← self

derive(self):                                            // corpus.lua:51
    for id in 1 .. n:
        w ← words[id]
        mask  ← 26-bit letter-presence bitmask of w
        smask ← mask without vowel bits, plus w[1] if w[1] is a vowel
        wbuckets[bucket_key(#w, w[1])]  append id        // (length, first letter)
        slen  ← #w − (vowels after the first) [+1 if w[1] is a vowel]
        sbuckets[bucket_key(slen, w[1])] append id       // (skeleton length, first letter)

bucket_key(len, first_byte) = min(len, 31) * 32 + (first_byte − 96)
```

Sorting 83k strings inside Lua would cost hundreds of milliseconds, so the two
*orderings* are precomputed and shipped. The masks and buckets are one pass over
the word list — measured at about 55 ms for 83k words, cheaper than shipping and
parsing them — so they are derived. `Corpus:skeleton(id)` is lazier still: it is
computed on demand and remembered, and the cache is dropped rather than grown
past `SKELETON_CACHE_LIMIT = 30000`, because only the few thousand words a
session actually scans ever need one.

Three guards in that block are each a bug that happened:

* **`[^\r\n]+`, not `[^\n]+`.** This file ships to Windows, where a checkout
  with `core.autocrlf` on turns every line ending into CRLF. Keeping the
  carriage return made exact lookup fail and put a `\r` inside every committed
  word.
* **Exact sizes, not minimums.** A *longer* stale index passes a minimum check
  and then hands out word ids past the end of the list, which surfaces much
  later as a nil comparison deep in a binary search.
* **`Corpus.fingerprint` is the sizes of all five files**, and it is part of the
  memo key. Keying on the directory alone meant a process that had loaded one
  generation of the data kept it however many times the files were replaced
  underneath — and worse than stale, because the word list and the indexes are
  then a matched pair of the *wrong* generation, so an id resolves to whatever
  word now sits at that position rather than to nothing.

The two range searches over the permutations are written against a *predicate*
rather than a sentinel string:

```
partition_point(self, key_at, is_before):                // corpus.lua:262
    lo, hi ← 1, n+1
    while lo < hi:
        mid ← (lo + hi) // 2
        if is_before(key_at(self, mid)) then lo ← mid+1 else hi ← mid
    return lo

Corpus:lookup(word)                = exact hit at partition_point(k < word)
Corpus:each_prefix(prefix, fn)     = [partition_point(k < prefix),
                                      partition_point(k < prefix or k starts with prefix) − 1]
Corpus:each_skeleton_exact(s, fn)  = the contiguous group whose skeleton is exactly s
Corpus:each_skeleton_completion(s, cap, fn)
                                   = the group whose skeleton strictly extends s, capped
```

Bounding a prefix range with `"\0"` and `"\255"` would make the result depend on
how the host collates them, and Lua compares strings with `strcoll`. With a
predicate every bound is `<` between two real words plus an exact prefix test,
both of which mean the same thing everywhere. `each_skeleton_exact` bounds the
group without ever walking the completion range that follows it, which for a
two-letter skeleton is tens of thousands of entries.

### B.3 The vocabulary files, and how a capital joins or replaces

`data/vocab/*.txt` is merged into the dictionary at build time. One entry per
line; an entry written with capitals is indexed under its lowercase key and
remembers the capitals.

```
build_dictionary.main():                                 // scripts/build_dictionary.py:173
    freqs ← parse_frequency_list(SOURCE)          // [a-z]+, plus real contractions
    base_rank ← {word → rank}                     // BEFORE any supplemental word
    default_freq ← frequency of the base word at rank --vocab-rank (20000)

    for path in sorted(data/vocab/*.txt):
        // two file-level directives, read as they are encountered
        //   #!rank N            every later entry in this file gets the frequency
        //                       of the base corpus word at rank N
        //   #!capitals replace  every capital in this file is the only spelling
        //                       its key has
        merge entries, keeping the LARGER frequency where a word already exists
        remember its written form when written ≠ key
        remember `key` as having a lowercase reading when written = key

    additive ← { k in vocab_forms
                 | (k in base_rank or k written in lower case somewhere)
                 and k not in a `#!capitals replace` file }

    floor every apostrophe contraction at the rank-500 frequency
    for each contraction: add its apostrophe-free spelling, IF that spelling
                          is not already a word
    sort by descending frequency          // line number becomes frequency rank
    write spellless.words, spellless.weights
    write spellless.forms:  "key<TAB>spelling"  or  "key<TAB>spelling<TAB>+"
```

At load, `corpus.lua:197` splits that last file in two:

```
for each line "key <TAB> display [<TAB> flag]":
    if flag = "+":  capitals[key]   ← display    // both readings; the capital is a companion
    else:           forms[key]      ← display    // the capital replaces
                    if display ends with ".": abbreviations[lower(display)] ← true
```

Today that is **809 replacing forms and 103 companion capitals**, and exactly
two abbreviations (`e.g.`, `i.e.`).

**The rule is looked up, not judged.** A capital joins the lowercase reading
wherever there is one to join, and replaces only where the key has never been
written in lower case at all. `ram`, `africa`, `bloom`, `latex`, `pc`,
`dijkstra` are base-corpus tokens, so `RAM`, `Bloom`, `LaTeX` sit beside them,
one keystroke away. `tqft`, `macos`, `cli` are neither in the base corpus nor
written in lower case by any entry, so their spelling simply is the entry.

Two things this replaced, both worth knowing:

* **An author-written `+` marker per entry.** It was wrong twice over: it is not
  needed — keeping both spellings costs one candidate slot and losing one costs
  a word — and the judgement it asked for is one nobody makes reliably. Twelve
  of the first sixty markers written were wrong.
* **Inferring "does the lowercase really mean something" from corpus rank.** It
  cannot be done. This corpus keeps proper nouns as ordinary lowercase tokens,
  so `africa` is its 1,500th word and looks exactly like `ram`; `bloom` is the
  8,858th token and `shannon` the 8,139th; `prim` at 27,141 is rarer than
  `turing` at 22,189. `#!capitals replace` is the escape: `proper_nouns.txt` and
  `given_names.txt` carry it, they were already defined as "words only ever
  written with a capital", and treating those ~400 names as ambiguous instead
  costs **three points of top-1**.

`#!rank` exists because without it every supplemental word arrives at rank
20,000, which is far too prominent for a list of place names — they then outrank
the ordinary words they compete with, and the cost lands on everything else
being corrected. It may appear more than once in a file
(`data/vocab/interjections.txt` uses six bands).

Two corpus repairs are worth naming because they change what is reachable:

* **All 64 contractions carry the same tail count** in the source, an artefact
  of how it was tokenised rather than a fact about English — `don't` is not
  really rarer than the 37,000th word. They are floored at the frequency of rank
  500. Without that, a dropped apostrophe finds nothing at all.
* **The apostrophe-free spelling is added as a key in its own right** (`dont`,
  `youll`, `ive`) — but only where that spelling is not already a word. `cant`,
  `its`, `hes`, `were`, `wont`, `ill` are ordinary English and must keep their
  lowercase reading. `ive` resolves to `I've`; `its` stays `its` with `it's`
  right behind it.

`data/forms.txt` is the strictest of the three sources of capitals: words with
**no valid lowercase form**, of which the pronoun `I` is essentially the whole
class. `march`/`March` and `may`/`May` must not be listed, because listing them
would make the verb unreachable. The build warns about any key it names that is
not in the dictionary.

`data/packs/*.txt` uses the same format and is deliberately **not** built in — a
pack is a fact about the person typing rather than about English.
`scripts/import_pack.py` writes it into `spellless_user.txt` with a starting
count of 4, chosen by measurement: over the topology pack, counts of 1/2/4/8 put
106/120/126/131 of its 155 longer words first from their own skeleton, while
costing 258 ordinary English cases exactly nothing at any of them. 4 is where
the pack's own curve flattens.

---

## C. The query pipeline

### C.0 One keystroke, end to end

```
key arrives
  ├─ M.handover.func(key, env)        [before ascii_composer, before the speller]
  │     · in ASCII mode: is this the delimiter that opened the run? then close it
  │     · else: clear a stale DELIMITER note
  │            handle_magic  — `qq` arms, the next key runs a command
  │            snippet trigger? commit the prefix, kRejected on the last letter
  ├─ ascii_composer / recognizer / key_binder                                [Rime]
  ├─ M.absorb.func(key, env)          [before the speller]
  │     · clear BACKSPACE / LITERAL notes; set the PICKED note
  │     · nothing composing + a letter + a word fragment in the document?
  │       commit U+0008 × #fragment, push_input(fragment), kNoop
  ├─ speller                          builds the composition                 [Rime]
  ├─ M.processor.func(key, env)       [after the speller, before the punctuator]
  │     · Shift, Ctrl+Shift+D, Ctrl+Shift+A, Return, Shift+Return, KP_Enter,
  │       digit-after-punctuation, the second space over a literal, punctuation,
  │       Return/Backspace outside a composition (the sentence note)
  ├─ punctuator / selector / navigator / express_editor                      [Rime]
  ├─ segmentors → a segment tagged "abc"                                     [Rime]
  ├─ M.func(input, seg, env)          the translator
  │     behind ← read_behind(engine, context, input)                   §C.1
  │     candidates ← suggest(engine, input, behind)   // one-entry memo   §C.2
  │       └─ Engine:suggest(raw, nil, behind)                           §C.3
  │            ├─ generate.generate(corpus, search, cfg, stats)         §C.4
  │            ├─ generate.generate(personal index, search, cfg, nil)
  │            ├─ rank.rank(items, search, cfg, ctx)                    §C.5
  │            ├─ placements: chosen, shortcut, coined, split, literal   §C.6
  │            └─ surface + case + companion capital                    §C.8
  │     for i, c: yield Candidate(c.source, seg.start, seg._end, c.text .. trail)
  │                with quality ← 1000 − i
  ├─ uniquifier                                                              [Rime]
  └─ M.filter.func (punct segments only, and only with ascii_punct off)
```

### C.1 What the adapter reads before the matcher runs

```
read_behind(engine, context, input) → behind:            // spellless.lua:436
    tail     ← text_behind(context)      // the document if it can be read, else
                                         // the stitched commit history
    document ← document_tail(context)    // nil unless the frontend published one

    behind.literal_first ← preceding.expects_literal(tail)     // trailing backslash
    behind.after_digit   ← tail ends with a digit
    behind.prefer_bare   ← preceding.expects_bare_verb(tail)
    behind.force_style   ← context[FORCED_CASE] if it is not ""
    behind.fragment      ← trailing word of `document`, if cfg.absorb_fragment

    if input = cfg.version_query:            // "zzver", asked once a session
        behind.client_app ← context["client_app"]
        behind.may_edit   ← may_edit_document(context, engine)
        behind.readable   ← document ≠ nil

    if not cfg.auto_capitalize: return behind

    if document:                             // the text is right there
        behind.sentence_start ← preceding.starts_fresh(tail)
                             or preceding.ends_sentence(tail, corpus.abbreviations)
        return behind

    note ← read_note(context)                // the sentence state machine, §D.3
    if note = "1":            behind.sentence_start ← true
    elif note ≠ "0":          behind.sentence_start ← starts_fresh or ends_sentence
    return behind
```

**`text_behind` versus `document_tail` is the central distinction in the whole
adapter.** Rime's `context.commit_history` is a record of what *this input
method committed*, which is a different thing from the document: librime clears
it on Return **and** on Backspace, it never hears about a mouse click or an
arrow key, and it cannot see anything typed while another input method was
active. It is a decent guess and it was all there was. A companion build of the
frontend publishes the few characters in front of the caret as the
`surrounding_text` property, and when that is there it is simply the truth.

Three consequences:

* `sentence_start` takes a **completely different path** depending on which
  source answered. With the document, one string test settles it. Without it,
  the note written by the processor is consulted first, because the commit
  history cannot tell a new line from a correction (§D.3).
* `fragment` is only ever read from the document, never from the history —
  absorbing a fragment means *deleting* it, and a guess is not good enough to
  delete on. (This field is in fact never read; see §G.6.)
* `prefer_bare` deliberately reads the same `tail` as everything else, so the
  bare-verb rule works from the commit history alone and does not wait on a
  frontend that can read the document.

The three diagnostic fields cost an application-name lookup and a list scan.
Paying for them on every keystroke to answer a question asked once a session is
the wrong trade, so they are gathered only when the input *is* the version
query — which is why `input` is passed to this function at all.

**`force_style` is set below rather than in the table literal.** `get_property`
returns `""` for unset and `""` is truthy in Lua, so assigning it straight
across would silently defeat every automatic capital there is.

**`commit_tail` stitches, it does not read the newest record.**

```
commit_tail(history):                                    // spellless.lua:250
    take the last TAIL_RECORDS (6) records, newest first, until
        the accumulated text reaches TAIL_CHARS (16)
    tail ← concat(them, oldest first)
    if tail contains U+0008:
        repeat  tail ← tail with every "<char>\8" pair removed  until stable
        drop any leading \8 that had nothing to erase inside this window
    return tail
```

Punctuation is committed on its own, so the newest record is frequently a bare
`"` or `$` or `\` with nothing around it to say whether it opens or closes.
Reading only that record turned `He said "no."` into `."the` and lost the
capital as well. And a commit may carry U+0008 to reclaim a character already in
the document (§D.10); the history records the *request*, so the erasures are
applied here and everything downstream sees the text the request produced.

### C.2 The one-entry memo

```
cache ← { engine, input, result, stamp, key }            // spellless.lua:516

suggest(engine, input, behind):
    key ← concat(behind.sentence_start, behind.literal_first, behind.client_app,
                 behind.force_style, behind.prefer_bare, behind.after_digit)
    if cache.engine = engine and cache.input = input and cache.key = key
       and cache.stamp = engine.user.dirty_stamp:
        return cache.result
    result ← engine:suggest(input, nil, behind)
    cache ← { engine, input, result, engine.user.dirty_stamp, key }
    return result
```

Rime re-queries a segment whenever the composition is refreshed — paging, an
option change, `refresh_non_confirmed_composition` — and repeating the search
for input just answered is pure waste.

**Everything that feeds the answer belongs in the key, and the lesson was
expensive.** `force_style` was left out once, and `qqc` did nothing at all: the
pre-command answer for the same letters was still sitting in the cache, so the
command ran, the composition refreshed, and the same stale list came back with
no way to tell. The key also carries the engine (librime creates one engine per
input context but shares one Lua state) and `user.dirty_stamp` (so a commit,
a `forget`, or a learned choice invalidates it).

### C.3 `Engine:suggest`, step by step

```
Engine:suggest(raw, limit, opts) → candidates, stats     // engine.lua:455

 0  if raw = "": return []
    if lower(raw) = cfg.version_query:                  // "zzver"
        return one candidate per line of Engine:describe(opts), plus the literal

 1  style ← effective_style(case_style(raw), opts.sentence_start, opts.force_style)
        case_style: no upper → "lower"; all upper and ≥2 chars → "upper";
                    only the first upper → "title"; anything else → "mixed"
        effective_style: a forced style wins outright; else a sentence start
                    lifts "lower" to "title"; else the typed style stands
    query ← lower(raw)
    limit ← limit or cfg.limit                          // 20

 2  // possessive split: the apostrophe you typed is the statement
    if query ends "'s":  stem, suffix ← query[1..−3], "'s"
    elif query ends "'": stem, suffix ← query[1..−2], "'"
    if stem does not match ^[a-z][a-z']*$: stem, suffix ← nil, nil
    search ← stem or query

 3  if #search ≤ cfg.max_query_len (32) and search matches ^[a-z][a-z']*$:
        has_exact ← corpus:lookup(query) or user:count(query) > 0
                    or Engine:possessive_stem(query)
        items ← generate.generate(corpus, search, cfg, stats)      §C.4
        for each item: item.word ← corpus.words[item.id]
                       item.has_form ← corpus.forms[item.word] ≠ nil
        generate_personal(self, search, items)                     §C.3.1
        if stem:
            drop every item whose WORD or whose SURFACE FORM contains "'"
        // no else: a second possessive generator lived here and could never
        // run — the guard above forces the query to match ^[a-z][a-z']*$, so a
        // query ending in "'s" always leaves a matching stem.  Removed; see §G.6.

 4  ctx ← { text, freq, user, tiebreak, previous_class,
            prefer_bare  ← opts.prefer_bare and search does not end in "d",
            past_inflection }
    ranked ← rank.rank(items, search, cfg, ctx)                    §C.5

 5  // dedupe by committed text, and attach the companion capital       §C.8
    for item in ranked while #out < limit:
        entry ← { text = Engine:surface(item.word .. suffix, style), ... }
        work out `capital`, `capital_leads`
        append entry and its companion, skipping any text already present

 6  // placements, in this order — each inserts at a FIXED position       §C.6
    promoted   ← a correction confirmed cfg.choice_confirm_count (2) times → slot 1
    expansions ← a user-written shortcut                                 → slot 1
    trusted    ← expansions or promoted or Engine:trustworthy(ranked.leader, …)
    coined     ← (not trusted) and Engine:find_affix(search, style)      → min(#out+1, limit)
    split      ← find_split(self, search)                                → last
    Engine:insert_raw(out, raw, limit, trusted)                          → cfg.raw_candidate_index,
                                                                            or slot 1 if not trusted
 7  return out, stats
```

**Step 2, the possessive, is the clearest example of "the input already answered
the question".** A trailing `'s` is a statement of intent and the only one
available: `teachers`, `students`, `mothers` are ordinary plurals far more often
than they are possessives, so guessing from a bare `s` would put a wrong
candidate under every plural. An apostrophe you actually typed cannot be
anything else — so the *stem* is matched on its own and every candidate comes
back possessive. `mther's` → `mother's`, which is the whole point: the stem is
what you might misspell. Both endings are honoured, and the one you typed is the
one you get back (`mthers'` → `mothers'`); which is right depends on whether the
noun is plural, and your apostrophe already said so. Contractions come out right
for free: `it's` is stem `it` plus `'s`.

**The apostrophe filter has to consult the written form, not just the key.**
Half the contractions are keyed *without* their apostrophe — `dont`, `itd`,
`thats` — precisely so they can be typed without one. Testing the key alone let
every one of them straight through, and `it's` offered `it'd's` and `it'll's` on
the first page. Plain trailing `s` is left alone, because `boss's` and `class's`
are perfectly good.

**Step 5 looks up the whole possessive, not the stem plus an ending.** You write
`McDonald's` far more often than you write `McDonald`, so that is the spelling
the personal store ends up holding; asking for the stem alone found nothing and
handed back `mcdonald's`. `Engine:surface` falls back to the stem's own spelling
when the possessive has none of its own, so `Milnor` makes `Milnor's` and
`Milnors` makes `Milnors'`.

#### C.3.1 The personal store, searched by the same matcher

```
Engine:personal_index():                                 // engine.lua:267
    if self.personal exists and self.personal_words = #user.order: return it
    words ← [ w in user.order | w matches ^%a[%a']*$ ]   // a hand-edited file can hold anything
    self.personal ← Corpus.of_words(words)               // same masks, buckets, permutations
    return self.personal

generate_personal(self, query, out):                     // engine.lua:248
    index ← Engine:personal_index()
    found ← generate.generate(index, query, cfg, nil)    // the SAME function
    for item in found:
        word ← index.words[item.id]
        append { word, id = corpus:lookup(word), source, cost, extra }
```

This used to be a second matcher: a linear pass over the most-used **400**
entries, three alignments each, with hand-rolled copies of the exact, prefix,
typo, skeleton and cue tests. It was slower per word than the real one by two
orders of magnitude — 400 personal words cost 4 ms against 3 ms for the whole
dictionary — and the cap was load-bearing because of it.

**A cap on a store the user fills themselves is a promise the software cannot
keep.** `reidemeister`, learned and spelled correctly and sitting in the file
with a count of 3, was unreachable from every shorthand of it, because 400 other
words were used more often. `Corpus.of_words` gives the personal list the same
structures the dictionary has, so there is one matcher, no cap, and the whole
store is searched for less than the old 400 cost.

`Corpus.of_words` shadows three methods on the instance so the shipped corpus
keeps reading its packed blobs and pays nothing for it: `alpha_at` and `skel_at`
index in-memory permutations, and `weight` returns a flat **0.5**. There is no
frequency data because there is none to have; a flat weight leaves the ordering
to `cost` and to the personal counts, which is what should decide between two
words you chose yourself.

The index is rebuilt only when the *set* of words changes (`#user.order`), not
when a count changes. Counts change constantly; the word set changes a few times
a session, and rebuilding is a sort plus one pass — about 2 ms for a store of a
couple of thousand.

Ids from that index address the personal list, so each is mapped back to a
dictionary id, or to `nil` for a word the dictionary has never heard of — which
is most of why the store exists, and which is what makes
`unknown_word_penalty` apply to it in §C.5.

### C.4 Generation: four channels, one pool

```
generate.generate(corpus, query, cfg, stats) → items     // generate.lua:362
    emit(id, source, cost, extra):
        items append { id, source, cost, extra or (#words[id] − #query) }

    exact_id ← add_exact_and_prefix(corpus, query, cfg, emit)
               add_typos      (corpus, query, cfg, emit, exact_id, stats)
               add_skeletons  (corpus, query, cfg, emit, exact_id, stats)
               add_cues       (corpus, query, cfg, emit, exact_id, stats)
    return items          // duplicates across sources are left in for the ranker
```

`extra` defaults to how much longer the word is than the query, which is what a
completion adds. A cue match overrides it with 0: the letters it skipped
*inside* the word are already paid for in `cost`, and charging them twice would
rank `think` for `tnk` below a word half as likely.

#### The shared scan

Three of the four channels need to visit "words that could plausibly be within
budget" without touching 83k of them. That is one function.

```
scan(masks, buckets, qlen, qmask, letters, window, budget, profile,
     max_checks, verify, stats):                         // generate.lua:111
    for step in 0 .. 2*window:
        delta ← (step+1)//2, negated on odd steps        // 0, −1, +1, −2, +2
        len   ← qlen − delta
        (qb, wb) ← bit_budgets(delta, budget, profile)
        if len > 0 and (qb, wb) exist:
            for c in letters:
                for id in buckets[bucket_key(len, c)]:   // already frequency ordered
                    x ← qmask & ~masks[id]               // typed, but not in the word
                    if popcount(x) ≤ qb:
                        y ← masks[id] & ~qmask           // in the word, but not typed
                        if popcount(y) ≤ wb:
                            checked ← checked + 1
                            if checked > max_checks: return
                            verify(id)

bit_budgets(delta, budget, p):                           // generate.lua:95
    n    ← |delta|
    left ← budget − n · p.min_indel_any
    if left < 0: return none                             // the length gap alone is unaffordable
    subs ← floor(left / p.min_sub)
    if delta > 0: return (n + subs, subs)  else: return (subs, n + subs)

anchor_letters(q, cfg) = q[1], q[2],
                         [+ QWERTY neighbours of q[1] if cfg.scan_first_neighbours]
```

**The bit budgets are exact rather than a fixed tolerance, and that is what
makes the ±2 length window affordable.** The length difference forces at least
`|delta|` insertions or deletions, already paid for at `min_indel_any` each;
whatever budget is left can only buy substitutions, and every edit moves at most
one letter into or out of the letter set. So a word two characters shorter than
the query may differ by exactly the two dropped letters and nothing else. Two
13-bit popcount lookups (`util.POPCOUNT`, 8,192 slots, ~70 kB, filled once in
about a millisecond) reject most of a bucket in five arithmetic operations with
no branches. Measured effect: 1,000–17,000 words visited by the prefilter per
query, 50–700 surviving to an actual distance evaluation.

A subtlety: a **doubling** slip changes no letters at all, so the profile
distinguishes `min_indel_any` — the cheapest indel of any *letter*, used here and
for the DP band — from `min_indel_gate`, which includes the apostrophe and is
used only for the length gate. At 0.15 an apostrophe would widen the band from
one column to four for *every* comparison; instead each apostrophe actually
present buys one extra column, which costs nothing for the 99.9% of words that
contain none.

Lengths are visited most-plausible-first and each bucket is frequency ordered,
so hitting `max_checks` (1200) drops the least likely candidates rather than an
arbitrary slice.

**`anchor_letters` covers `q[1]` and `q[2]`** — the second covering a slip on,
an insertion before, or a deletion of the very first key. The QWERTY neighbours
of `q[1]` are behind `scan_first_neighbours`, which is **off**: it takes that
input class from 1.6% to 98.2% reachable on the first page, the largest single
recall gain available anywhere in the configuration, and it costs 27% of the
per-keystroke budget on *every* query. See §G.4.

#### Channel 1: exact and prefix

```
add_exact_and_prefix(corpus, query, cfg, emit):          // generate.lua:155
    exact_id ← corpus:lookup(query)
    if exact_id: emit(exact_id, "exact", 0)
    top ← util.top(cfg.max_prefix)                       // 12
    corpus:each_prefix(query, λ id → if id ≠ exact_id: top:push(id, id))
    top:each(λ id → emit(id, "prefix", 0))
    return exact_id
```

The shortlist is keyed on the id, which *is* the frequency rank, so "the twelve
commonest completions" costs one pass over the range and no sort.

#### Channel 2: typos — a bounded scan against a weighted OSA distance

```
add_typos(corpus, query, cfg, emit, exact_id, stats):    // generate.lua:166
    if #query < cfg.min_typo_len (2): return
    shortlist ← util.top(cfg.max_typo)                   // 20
    scan(corpus.masks, corpus.wbuckets, #query, letter_mask(query),
         anchor_letters(query, cfg), cfg.len_window (2), cfg.typo_budget (1.35),
         TYPO_PROFILE, cfg.max_checks (1200),
         λ id →
            if id = exact_id: skip
            d ← distance.distance(query, words[id], budget, TYPO_PROFILE)
            if d and d > 0:
                cost_of[id] ← d
                shortlist:push(d · 1e7 + id, id)         // cheapest first, rank as tiebreak
         )
    shortlist:each(λ id → emit(id, "typo", cost_of[id]))
```

The distance is Damerau–Levenshtein restricted to non-overlapping adjacent
transpositions (OSA — the restriction is irrelevant for single words and keeps
the recurrence to three rolling rows). Every edit has its own price, because
English fast-typing errors are not uniformly likely:

| edit | cost | example |
| --- | --- | --- |
| dropped apostrophe | 0.15 | `dont`, `its`, `id` — typography, not spelling |
| adjacent transposition | 0.45 | `teh`, `theorme`, `recommned` |
| miscounted double letter | 0.55 | `commited`, `harrass`, `accomodate` |
| dropped or doubled vowel | 0.70 | `seperate`, `definately` |
| neighbouring key | 0.70 | `nirth` → `north` |
| vowel for vowel | 0.75 | |
| anything else | 1.00 | |

The doubling rule was worth more than any other single change: `commited`
reaches `commuted` for 0.70 (a neighbouring key) but needed 1.00 to reach
`committed`, so the wrong word won.

The QWERTY layout is real geometry, not a hand-written adjacency list: three
rows with x offsets 0.00 / 0.25 / 0.75, and two keys are neighbours when their
centres are within one key width — which is why `d` neighbours both `e` and `r`
(`distance.lua:build_neighbours`).

This is the hot loop of the whole project — the scan calls it a few thousand
times per keystroke — so both strings are turned into byte arrays and
per-character price arrays before the DP starts, the query's arrays are cached
across the whole scan (`price_a` memoises on the string *and* the profile), and
substitution costs come from a flat 128×128 table built once per profile. The
inner loop does array reads and arithmetic and never calls into C.

Two properties of the DP that are easy to get wrong:

```
band_width(budget, delta, p) = floor((floor(budget / p.min_indel_any) + delta) / 2)
band = band_width(...) + (apostrophes in a) + (apostrophes in b)
if delta > band: return nil          // the answer cell (n,m) is unreachable
```

* **The band is derived, not guessed.** Reaching a cell `d` columns off the
  diagonal when the strings differ in length by `δ` needs at least `2d − δ`
  indels. And the comparison is abandoned outright if the band cannot reach the
  far corner — otherwise reading `r1[m]` gives a *stale cell* from a wider
  earlier call rather than a distance. (`r2[hi+1] ← nil` after every row, for
  the same reason.)
* **The abort needs two consecutive over-budget rows, not one.** A transposition
  reads the row *two* back, so a row can exceed the budget and the next still
  recover through it. The bound: no cell of the next row can beat
  `min(this row's minimum, previous row's minimum + transpose)`. Aborting on one
  row silently discarded `ifnomration → information` (two transpositions, total
  0.90) — a bug that survived a hand-written reference-implementation test,
  because no pair in that test's word list happened to need the recovery.
  `tests/test_distance.lua` now corrupts 400 real corpus words instead.
* **Column zero belongs in the row minimum.** It means deleting the whole typed
  prefix, and leaving it out made the abort fire on a value no cell actually had
  — rejecting alignments that fit, `aathe → the` among them.

#### Channel 3: consonant skeletons

`skeleton.of(w)` drops `a e i o u`, with two exceptions: `y` is kept (it is
consonantal about as often as it is vocalic, and typists abbreviating keep it —
`systm`, `tplgy`, `hmtpy`), and the first character is kept even when it is a
vowel (nobody writes `bt` for `about`). This rule is written **twice** —
`scripts/_common.py` sorts the index and `spellless/skeleton.lua` binary
searches it — and `tests/test_skeleton.lua` walks the whole shipped index
asserting the ordering is still monotone under the Lua function, so the two
cannot drift apart silently.

```
add_skeletons(corpus, query, cfg, emit, exact_id, stats): // generate.lua:197
    qskel ← skeleton.of(query)
    if #qskel < cfg.min_skeleton_len (2): return
    pool ← []

    collect(prefix):
        // leg 1: the exact skeleton group
        top ← util.top(cfg.max_skeleton (16))
        corpus:each_skeleton_exact(prefix, push) ; top:each(offer)
        // leg 2: completions of a half-typed abbreviation
        if #qskel ≥ cfg.min_skeleton_completion_len (4):
            top ← util.top(cfg.max_skeleton)
            corpus:each_skeleton_completion(prefix, cfg.max_skeleton_range (1500), push)
            top:each(offer)

    collect(qskel)
    if qskel does not start with a vowel:
        for v in "aeiou": collect(v .. qskel)             // five more binary searches

    // leg 3: a mistyped abbreviation
    if #qskel ≥ cfg.min_skeleton_fuzzy_len (5):
        top ← util.top(cfg.max_skeleton_fuzzy (12))
        scan(corpus.smasks, corpus.sbuckets, #qskel, letter_mask(qskel),
             anchor_letters(qskel, cfg), window = 1, cfg.skeleton_budget (1.30),
             SKELETON_PROFILE, cfg.max_checks,
             λ id → d ← distance.prefix_distance(qskel, corpus:skeleton(id),
                                                 budget, SKELETON_PROFILE)
                    if d: top:push(d·1e7 + id, id))
        top:each(offer)

    // every leg is priced the same way: the ORIGINAL query against a prefix of
    // the WORD, with cheap missing vowels
    for id in pool:
        d ← distance.prefix_distance(query, words[id], cfg.elastic_budget (1.70),
                                     ELASTIC_PROFILE)
        if d: emit(id, "skeleton", d)
```

Three things here are the result of iteration rather than design:

**The five vowel probes.** The skeleton rule keeps a leading vowel
(`environment` → `envrnmnt`) but a typist abbreviating often drops it
(`nvrnmnt`). Five extra index probes recover that; the elastic pass then charges
the missing vowel.

**Leg 3 compares against a *prefix* of the word's skeleton.** An abbreviation
with a slip in it is usually also unfinished — `alghrith` is `algorithm` with an
`h` for the `o` and no `m` yet — and demanding the whole skeleton charges for
the slip and the missing tail at once, which no budget worth having can absorb.
The elastic pass still prices the query against the real word, so this only
widens who gets considered; `alghrith` went from offering nothing at all to
leading with `algorithm`.

**The re-pricing is against the original query, and the ELASTIC profile is
asymmetric on purpose.** A vowel the typist *left out* costs 0.10 to insert,
because that is what an abbreviation is; a vowel they *actually typed* costs
0.90 to delete, because it is evidence. `prefix_distance` takes the minimum over
the *final row* rather than its last cell — "the best alignment against any
prefix" — so `mthmt` aligns with the `mathemat` of `mathematics` for 0.30 and
the rest is charged by the ranker as a completion rather than as edits.

Without that asymmetry, comparing skeleton to skeleton, `mathe` (skeleton `mth`)
matches `mouth` exactly as cheaply as `mthmtcs` matches `mathematics`. With it,
`mouth` costs 1.60 — inside the budget, so it *is* generated, and it does not
appear because 1.60 of cost is 25.6 points of score, which puts it below twenty
better readings. **Generation is deliberately loose; the ranking is where
precision comes from.**

Cheap vowel indels make the useful band too wide to be worth maintaining, so
`prefix_distance` walks full rows over the first `#a + max_drift` (10) characters
of `b` and leans on the row-minimum abort instead.

#### Channel 4: syllable cues

The observation: for a long word, people neither spell it nor write all its
consonants. They say it to themselves and type one or two letters that feel
salient in each syllable.

```
stratification  →  strat-i-fi-ca-tion  →  satfcatn
```

`satfcatn → stratification` is 4.80 under the edit model and 2.40 under elastic,
both far outside budget, and the skeleton channel wants all eight consonants of
`strtfctn`. Before this channel existed, `satfcatn` returned nothing at all.

What every such input *does* have is that the letters typed appear in the word,
**in order**. So the query is aligned as a subsequence, and the question becomes
how likely that particular subsequence was.

```
cue.align(query, word, budget, cfg) → nats / cue_cost_scale   // cue.lua:150
    if #word < #query or #query < 2: return nil
    if query[1] ≠ word[1]: return nil                  // the letter nobody drops

    slip ← cfg.cue_slip_cost if it is > 0 and #query ≥ cfg.min_cue_slip_len (5)

    // is the query a subsequence at all?  leftmost-greedy, one pass, no allocation
    lpos, lmax ← greedy forward walk
    clean ← (lmax = #query)
    if not clean:
        if no slip allowed: return nil
        rpos, rmin ← greedy BACKWARD walk
        // a slip fits at query position k when the prefix before it and the
        // suffix after it leave a word position free in between
        if no k with (k−1 ≤ lmax) and (k+1 ≥ rmin) and lpos[k−1] + 2 ≤ rpos[k+1]:
            return nil
    if clean: slip ← nil  else: budget ← budget + slip

    // one Bernoulli decision per character of the WORD
    for j in 1..#word:
        class(j) ← VOWEL          if word[j] is a vowel or an apostrophe
                   CLUSTER        if a neighbour is a consonant
                   ONSET          otherwise (a consonant between vowels)
        keep(j) ← −log p[class],  skip(j) ← −log(1 − p[class])

    f[1] ← keep(1);  f[i>1] ← ∞
    for j in 2 .. #word:
        for i in min(#query, j) down to 2:      // descending, so f[i−1] is row j−1
            v ← f[i] + skip(j)
            if word[j] = query[i]: v ← min(v, f[i−1] + keep(j))
            elif slip:             v ← min(v, f[i−1] + keep(j) + slip)
            f[i] ← v
        f[1] ← f[1] + skip(j)
        if min(f) > budget: return nil          // both prices > 0, so the row min only rises
    return f[#query] / cfg.cue_cost_scale
```

| character of the word | kept with probability | because |
| --- | --- | --- |
| a vowel | `cue_keep_vowel` 0.32 | nobody spells out the vowels |
| a consonant beside another | `cue_keep_cluster` 0.76 | clusters, codas, doubled letters: the `h` of `think`, the `r` of `strat`, one `t` of `cattle` |
| a consonant between vowels | `cue_keep_onset` 0.86 | that is a syllable's onset — the letter a shorthand typist keeps |

**Charging both sides is what makes it a distribution.** Sum over all keep/drop
masks of `P(mask)` is 1, for every word, and the model normalises itself. That
buys two things that used to be separate hand-built rules: a long word no longer
wins by having more subsequences (every extra character it has to explain is
charged, kept or dropped, so the untouched tail is paid for by construction);
and a vowel-rich input can no longer pass itself off as shorthand (each vowel the
typist *did* type costs `−log 0.32`, which is expensive precisely because vowels
are what shorthand drops).

**And the three numbers are counted, not chosen.** The alignment itself says
which characters each known (shorthand, word) pair kept, so class-wise keep
rates are closed-form counts. Hard EM over the 342 pairs in
`tests/cases/syllables.tsv` and `generated_cues.tsv` converges in two iterations
to 0.39 / 0.68 / 0.89; coordinate descent then moves them to the shipped values
and gains 0.002 of objective doing it — which is to say the maximum-likelihood
numbers were already right.

**`cue_cost_scale = 9` is the one number in the channel with no probabilistic
meaning**, and it is the most consequential dial in it. Raise it and the cost
term flattens so frequency decides and a commoner longer word wins; lower it and
an exact-skeleton reading wins. Held out over ten fresh generator seeds, the two
move against each other about two to one and the aggregate is flat:

```
  cue_cost_scale      5      7      9     10     12
  generated_cues   69.8   83.4   88.5   90.1   91.9
  generated_skels  91.6   90.6   89.3   88.5   87.6
  TOTAL top-1      85.8   88.7   89.5   89.6   89.6
```

The aggregate does not choose, so the setting is a statement about who is
typing. It ships at 9, favouring the skeleton reading, because at 12 the
exact-skeleton cases were visibly losing (`wrkr` gave *workers* before *worker*,
`mlcl` *molecular* before *molecule*). It costs 0.24 points of held-out top-1.

**One letter may be the wrong key**, at `cue_slip_cost = 10` nats on top of what
keeping it costs, with the letter-set filter relaxed from "every letter appears"
to "at most one does not". Without it a slip *inside* an abbreviation is fatal
rather than merely expensive — the letters no longer appear in order, so nothing
is offered at all, and `stfxctn` reaches nothing. Measured today by
`lua bench/probe.lua`, over 227 plausible shorthands with one letter corrupted:

```
                         slip off   slip on
  nothing offered at all    24.2%      0.4%
  right word first          20.3%     19.8%
  right word on page 1      26.9%     80.2%
```

Note which row moves. A corrupted abbreviation is genuinely ambiguous and the
matcher is right not to be confident about it; what the feature buys is the
first page, from a quarter to four in five. That is the shape of a recall
feature. **No case file can see any of it** — not one of them contains a
corrupted shorthand — so §5 of ALGORITHM.md is blind to a feature that costs
about 0.35 ms per keystroke.

Two guards keep that cost bounded: a word that already explains every letter in
order gets the slip transition switched **off** (so the exact reading of every
such word is unchanged, and the inner loop's extra branch is skipped on the
overwhelming majority of alignments); and a word that does need a slip is
allowed to spend one *on top of* the clean budget rather than widening the
budget for everybody.

```
add_cues(corpus, query, cfg, emit, exact_id, stats):     // generate.lua:283
    if #query < cfg.min_cue_len (3) or exact_id: return  // ← the whole common case
    last ← min(#query + cfg.cue_max_extra (12), floor(#query · cfg.cue_max_ratio (3.0)), 31)
    for len in #query .. last:                           // shortest first
        for id in wbuckets[bucket_key(len, query[1])]:
            x ← qmask & ~masks[id]
            if x = 0:                                    // every letter typed is in the word
                checked ← checked + 1
                if checked > cfg.cue_max_checks (900): stop
                run ← true
            elif slip and (x & (x−1)) = 0:               // exactly one letter missing
                slipped ← slipped + 1
                run ← slipped ≤ cfg.cue_slip_checks (400)
            if run:
                d ← cue.align(query, words[id], cfg.cue_budget (12.0 nats), cfg)
                if d: shortlist:push(cfg.cost_weight·d − cfg.freq_weight·weight(id), id)
    shortlist:each(λ id → emit(id, "cue", cost_of[id], extra = 0))
```

Four things about that scan:

* **`exact_id` skips the whole channel.** Shorthand is what you write *instead*
  of a word, so a string the dictionary already knows is not it — the same
  reasoning that stops `another` being cut into `a not her`. It is also what
  keeps the common case free: every correctly spelled word you type would
  otherwise pay for a scan that could only offer a stretch. Cost when it does
  run: 0.14 ms per keystroke (1.57 ms without the channel against 1.71 ms with,
  on a repeated-prefix benchmark).
* **There is no index to use.** A subsequence has no prefix to binary search on,
  and the skeleton permutation is exactly what these queries fail to match. What
  they do have is a first letter and a letter *set*, and `x & (x−1) = 0` — "at
  most one bit set" — is two more integer operations than the strict test rather
  than the two 13-bit popcount lookups a real popcount would take on every word.
* **The relaxed test gets its own ceiling.** It admits five to ten times as many
  words per bucket, and without `cue_slip_checks` they would crowd out the words
  that *do* contain every letter, which are much likelier to be right.
* **The shortlist is keyed by what the ranker will do, not by cost alone.**
  Every other source is narrow enough that cheapest-first is close enough to
  best-first; this one is not. `tnk` aligns onto a dozen rare words at nearly no
  cost — `tonkin`, `tankers` — and cost order dropped `think` off the end of the
  list before the ranker ever saw it.

Two bounds on the word length, and the tighter wins: the *ratio* matters for
short input (three letters is not shorthand for a seventeen-letter word,
whatever the absolute gap) and the *absolute gap* matters for long input, where
the ratio stops constraining anything.

There is deliberately **no fourth class for a doubled letter**. It was given one
at first, on the theory that `cattle → ctl` drops nothing real; but dropping one
half of a double while keeping the other is a misspelling, not shorthand, and at
its own low price the cue reading undercut the typo channel on its own ground —
`embarass` led with `embarrassed`, `adn` with `adding`.

#### A worked cost table

The clearest statement of why there are four cost models rather than one. Bold
is the model that actually finds the word.

| query | word | typo ≤1.35 | skeleton ≤1.30 | elastic ≤1.70 | cue ≤1.33 (2.44 †) |
| --- | --- | --- | --- | --- | --- |
| `teh` | the | **0.45** | 0.00 | 0.45 | — |
| `commited` | committed | **0.55** | 0.55 | 0.55 | 0.66 |
| `dont` | don't | **0.15** | 0.15 | 0.15 | 0.22 |
| `mthmtcs` | mathematics | 2.80 | 0.00 | **0.40** | 0.34 |
| `ppl` | people | 2.10 | 0.00 | **0.20** | 0.21 |
| `alghrith` | algorithm | 2.00 | 2.00 * | **1.00** | 1.79 † |
| `satfcatn` | stratification | 4.80 | 2.00 | 2.40 | **0.86** |
| `gvmnt` | government | 4.10 | 2.00 | 2.20 | **0.57** |
| `tnk` | think | 1.70 | 1.00 | 1.10 | **0.29** |
| `tnk` | tank | 0.70 | **0.00** | 0.10 | 0.12 |
| `mathe` | mouth | 2.15 | 0.00 | 1.60 | — |

`—` means the channel cannot express the relationship at all. `†` marks readings
that need the slip. `*` marks where the shipped code compares against a prefix of
the word's skeleton instead. The cue column is nats divided by
`cue_cost_scale`, so only its ordering *within the column* means anything.

### C.5 Ranking

Everything is a single additive score rather than a fixed source ordering, so a
very common word reached by a cheap typo can legitimately overtake a rare exact
prefix completion — `teh` should give `the`, not `tehran`.

```
rank.rank(items, query, cfg, ctx):                       // rank.lua:219
 1  ctx.abbreviation_likeness ← 1 − skeleton.vowel_ratio(query)
 2  ctx.best_cost ← min over items of item.cost   (0 if there are none)
 3  for item: item.score ← rank.score(item, cfg, ctx)
       keep the best-scoring entry PER COMMITTED TEXT (ctx.text = item.word)
 4  rank.hold_exact(out)
 5  rank.apply_context(out, cfg, ctx)          // no-op unless context_class is on
 6  sort by descending score, ties broken by corpus rank (ctx.tiebreak)
 7  out.leader ← out[1]                        // BEFORE the reorder below
 8  rank.defer_inflections(out, cfg, ctx)
    return out
```

```
rank.score(item, cfg, ctx):                              // rank.lua:33
    base ← cfg["base_" .. item.source]                   // exact/prefix/typo/skeleton/cue
    if no base: return −∞                                // everything else is PLACED
    excess ← item.cost − ctx.best_cost
    familiarity ← (excess ≤ cfg.user_cost_margin) ? cfg.user_weight · ctx.user(item) : 0
    s ← base
        + cfg.freq_weight  · ctx.freq(item)              // normalised log-frequency, [0,1]
        + familiarity                                    // log(1+count)/log(1+12), clamped
        − cfg.cost_weight  · item.cost
        − cfg.extra_weight · clamp(item.extra / 10, 0, 1)
    if item has no corpus id and item.source ≠ "split":
        s ← s − cfg.unknown_word_penalty
    if item.has_form and item.source = "exact":
        s ← s + cfg.form_bonus
    if item.source = "skeleton": s ← s + cfg.skeleton_vowel_bonus · (2α − 1)
    if item.source = "cue":      s ← s + cfg.cue_vowel_bonus      · (2α − 1)
    return s
```

| constant | value | what it is worth |
| --- | --- | --- |
| `base_exact` | 84 | an exact dictionary hit |
| `base_typo` | 75 | a repair |
| `base_prefix` | 74 | a completion |
| `base_cue` | 70 | a syllabic shorthand reading |
| `base_skeleton` | 62 | a consonant-skeleton reading |
| `form_bonus` | 70 | exact hit on a key someone deliberately wrote down |
| `freq_weight` | 34 | × normalised corpus log-frequency ∈ [0,1] |
| `user_weight` | 18 | × normalised personal frequency ∈ [0,1] |
| `cost_weight` | 16 | × weighted edit cost |
| `extra_weight` | 8 | × how much longer the completion is, /10, clamped |
| `unknown_word_penalty` | 25 | the dictionary has never heard of this word |
| `unknown_word_freq` | 0.2 | the frequency assumed for such a word |
| `skeleton_vowel_bonus` | 10 | × (2α − 1), signed |
| `cue_vowel_bonus` | 10 | × (2α − 1), signed |
| `user_cost_margin` | 1.0 | how much worse than the best reading familiarity still reaches |
| `user_saturation` | 12 | selections to reach the top of the personal scale |

α = `1 − vowel_ratio(query)`, "how consonantal does this input look". **The last
two bonuses are signed**: a consonant-only input is evidence *for* the
abbreviation reading, a vowel-rich one is evidence *against* it. Two knobs rather
than one because they are two channels and the tuner should be able to move them
apart; that both landed on 10 is a result, not an assumption. Leaving cues out of
it meant `tnk` ranked the exact skeleton of a rare word above a common word one
dropped letter away.

**What the units mean.** The dictionary's log-frequency range is 14.41 nats, so
`freq_weight` buys 2.36 points per nat and one unit of edit cost is priced at
6.78 nats, about 880:1. But that is not the number that governs anything: a
repair also has to cross `base_exact − base_typo = 9`, so 25 points is 10.6 nats
against a corpus whose entire dynamic range is 14.4 — a full-price repair *can*
in principle beat an exact dictionary match, and needs a word about 40,000 times
commoner to do it. In the rank band people actually type the whole frequency
spread available is 4.7 nats: enough to overturn a cost gap of 0.69, never a
whole edit.

**`base_exact = 84` is where the design stopped being a veto.** It was 100, which
put the gap to `base_prefix` at 26 points — 11 nats, three quarters of the entire
corpus range — so no completion could ever overtake a word you had actually
typed, however rare that word and however common the completion. That is too
strong for a matcher whose users drop trailing letters all day and land on tail
words: `sear`, `firs`, `hel`, `trave`, `jus`, `phon`, `syst`, `pleas`, `foll`,
`wit`, `fro`, `numb` and `contras` all led over the words they complete, which
are between 13 and 900 times commoner. At 84, 23 of 27 known blockers are
corrected, no word in the top 5,000 stops giving itself back, and three in ranks
5,000–20,000 do (`rae`, `cit`, `ina`, none of them English). At 82 it starts
costing real words — `compute`, `heal`, `plea`, `boa`, `gall`.

**`form_bonus` is deliberately not a blanket lift of `base_exact`.** Raising
`base_exact` was tried and made every rare word unbeatable: `tat` and `eys` then
led over `that` and `eyes`, which is the opposite failure and a worse one,
because those are words you meant to have corrected. Restricting the bonus to
keys that carry a written form says the narrower thing that is actually true —
somebody put `sth → something` and `im → I'm` in a file on purpose, and there is
nothing to second-guess.

**The familiarity margin is the newest term and the best-documented sweep in the
codebase.** Familiarity is evidence about the *word*; cost is evidence about the
*reading*. That you write `instead` sixteen times a day is a reason to prefer it
among readings that explain the input equally well, and no reason at all to
accept a reading that explains it much worse. It was accepted: `immsn` put the
literal first and `immersion` third, because `instead` came back at cost 1.55 and
eighteen points of familiarity covered the 16.5 that the extra cost had taken
off, winning by 0.1 over a cost-0.52 reading — and then, the leader being that
loose, nothing was trustworthy and the literal was promoted over the good answer
sitting behind it.

The fix is a margin against the *best reading on offer*, not against an absolute
threshold. Swept against a real personal store of 566 recorded corrections:

```
  margin   1.0  0.8  0.6  0.5  0.4  0.3  0.2
  lost       0    1    1    3    4    6   11
```

so 1.0 is not a compromise, it is the whole plateau. Testing the absolute cost
instead is what does not work: a flat threshold at `confidence_cost` lost nine,
`buracitc → bureaucratic` among them, because a hard repair with no rival is
exactly what familiarity is *for*.

#### `hold_exact` — familiarity may not overturn an exact match

```
rank.hold_exact(out):                                    // rank.lua:166
    ceiling ← max score among items with source = "exact"
    if none: return
    for item with source ≠ "exact":
        if item.score > ceiling and (item.score − item.familiarity) ≤ ceiling:
            item.held  ← item.score − ceiling
            item.score ← ceiling − 1e−9
```

`sth` must mean `something` however many hundreds of times `the` has been
committed. That guarantee used to rest on `base_exact` standing far enough above
every other base to outrun `user_weight` at saturation; it is stated here
instead, which is both the honest place for it and what lets `base_exact` be set
on the evidence it is actually about. **Only the bonus is held back, never the
frequency**: a rival that beats the exact match on measured English alone still
wins, which is exactly the case this is not about.

#### `defer_inflections` — the bare-verb rule

```
rank.defer_inflections(out, cfg, ctx):                   // rank.lua:202
    if not ctx.prefer_bare: return
    window ← min(cfg.bare_verb_window (5), #out)
    if window < 2: return
    partition out[1..window] STABLY into (not past_inflection) then (past_inflection)
    // nothing leaves the window; nothing below it moves at all
```

with, from `engine.lua:538`:

```
ctx.prefer_bare ← opts.prefer_bare and search does not end in "d"
ctx.past_inflection(item) ← item.word ends "ed"
                            and (corpus:lookup(word[1..−2]) or corpus:lookup(word[1..−3]))
```

Where English *requires* a bare infinitive, an `-ed` reading of the next word is
not unlikely — it is ungrammatical. That is a different kind of claim from a
statistical preference, and it behaves differently. Three parts, and every one of
them is what the abandoned part-of-speech table lacked:

* **The trigger is grammatical and closed** (`preceding.expects_bare_verb`).
  Nine modals and their negations; `to` when the word in front licenses an
  infinitive; any adverbs in between, up to `ADVERB_CHAIN = 3`. Measured over
  427,498 words of the prose this is for:

  ```
    slot                          n        -ed     -ing      -s
    a modal                   2,598       0.5%     0.1%    3.8%
    modal + adverbs             518       0.8%     0.0%    2.9%
    `to`, licensed              856       0.1%     0.1%    0.8%
    ---------------------------------------------------------- the line
    `to`, unlicensed          5,670       1.4%     1.9%    7.9%
    have / has / had          1,296       6.6%     1.3%   11.4%
    an                        2,631       5.8%     5.9%    1.1%
    a                        14,675       5.3%     2.4%    5.1%
  ```

  The rows under the line are not near misses, they are the rule's opposite:
  `have` and `is` take a past participle, and what follows `a`/`an` is a
  participial adjective all day long. The licensing test on `to` takes that slot
  from 1.4% to 0.1%, cleaner than the modals themselves. The adverb chain stops
  of its own accord in exactly the right place — `be` and `have` are not
  adverbs, so "would be related" and "would have related" are never reached.
  The multi-word adjuncts are a closed list of 24 phrases rather than a parse: a
  right-to-left scan recognising prepositional phrases *by shape* reaches 5.6%
  more slots and **doubles** the error rate, because it cannot tell "to some
  extent" from "for the reasons expressed" and lands on a modal governing
  nothing. The phrase list reaches 1% more slots and adds no errors.
* **The input overrules it.** A consonant skeleton keeps every consonant, so an
  `-ed` inflection *always* has a `d` in its shorthand: somebody who means "would
  have called" types `clld`, not `cll`. Across every trigger family measured, all
  1,118 genuine `-ed` inflections keep their `d`. The rule can only act in the
  gap where the input said nothing.
* **It reorders one page and cannot reach past it.** This is where the first
  attempt was wrong: an 8-point penalty — small by the standards of the table
  above — moved `related` from first to *fourteenth*, because the field around a
  three-letter skeleton is dense enough that eight points spans a dozen words.
  That is removal wearing the clothes of a demotion. A stable partition says what
  grammar knows (which readings are wrong here) and nothing about what it does
  not (how much better `result` is than `reality`), and bounds the loss at four
  places.

Run over 374,090 real slots with their real left context, the shipped predicate
fires on **about 3,990** (`config.lua` says 3,979, `ALGORITHM.md` §8.1 says
3,994 — see §G.6), and on the 473 distinct (shorthand, word) pairs that produces
**11 improve and 0 regress** — `gnrlz → generalize`, `ddc → deduce`,
`imps → impose`, `endw → endow`, `rlt → relate`. It costs 5 µs a keystroke.

**And `out.leader` is captured before the partition, deliberately.** Whether the
matcher believes its own answer is a question about the input, and it must not
acquire an opinion about the word before it. `allsg` reads as `alleged`,
comfortably trusted; demoting it after a modal put a below-floor candidate in
first place and made the literal `allsg` lead. One skeleton in 8,646 — which is
what a rare violation of an invariant looks like from the outside.

#### `apply_context` — the term that ships off

`rank.apply_context` adds `context_weight · PMI(class(previous), class(candidate))`
to every candidate within `context_margin` of the leader. It is **off**
(`context_class = false`), and the shape of the failure is the useful part.

It was measured. `lua bench/context.lua` scores the whole case set under six
fixed previous words, and at every weight and margin tried it breaks more answers
than it fixes: 13 fixed against 31 broken after `the`, 11 against 37 after `of`,
11 against 108 after `very`, and exactly 0/0 after `and` — the neutral row,
behaving as designed. The only weight that does not lose is zero.

The diagnosis generalises beyond the feature. **Two classifiers were involved and
only one was ever measured.** The PMI table was written about parts of speech;
the suffix rules select *endings*. "VERB" here means *ends in -ed, -ing or -ate*,
and `P(that | "the")` is nothing like `P(verb | "the")` — "the building", "the
greeting", "the finished draft". So `DET→VERB = −1.50` demotes precisely the
words determiners most often precede.

The scaffolding survives its own test and ships disabled, which is worth
something: zero-centred so an unknown previous word contributes exactly nothing;
a margin derived from the data rather than guessed (every morphological sibling
in the case files sits within 9.8 points of the word that beat it, every *exact*
match that beat its sibling leads by at least 19.7, and 12 is the gap between
those two facts); and points-per-nat matched to the frequency term. Note that
**the adapter half is not wired either** — nothing puts `previous_word` into the
options `Engine:suggest` receives, so turning the flag on in a schema changes
nothing at all. Anyone reviving this has two halves to build.

### C.6 Placements rather than scores

Eight decisions in the pipeline are *positions*, not points. This is a design
stance, and the reasoning is the same each time: **there is no score that means
"worth having, never worth preferring".**

| what | where it goes | why not a score |
| --- | --- | --- |
| a confirmed correction (`chosen`) | slot 1 | the only evidence that comes from the person rather than from a measurement of English; no amount of frequency argues with it |
| a user-written shortcut | slot 1 | the one place in the matcher with no guessing to do — they said what they meant |
| a coinage (`coined`) | `min(#out+1, limit)`, displacing the last | the twentieth guess at what else the letters might have been is not worth the slot; "if there is room" made it appear or not according to how many rivals a query happened to attract |
| a word split | last among the real answers | scored high it displaced real corrections; scored low it vanished exactly when wanted — `thisday` offered Thursday and Tuesday and no way to say "this day" |
| the literal | `raw_candidate_index` (slot 7), or slot 1 when nothing is trusted | a fixed slot means the keystroke that commits it is predictable |
| the companion capital | immediately beside its sibling, score ± 0.5 | one keystroke apart either way, so neither can displace the other |
| `defer_inflections` | a stable partition of the first 5 | see above: 8 points was a disappearance |
| `hold_exact` | a clamp to `ceiling − 1e−9` | a bound on what familiarity may do, not a price for it |

The split is placed **last**, below the literal's own reasoning, because the
literal has to stay where it is: it leads when nothing else is trustworthy, and
putting the split above it there would hand first place to `spell less` over
`spellless`.

Two of these run their own searches, and both are gated on `trusted`:

```
Engine:find_affix(query, style):                         // engine.lua:422
    if not cfg.affix_words or self.peeling: return nil    // one level only
    if corpus:lookup(query): return nil                   // ← doing more work than the lists
    if #query < cfg.min_affix_len (6): return nil
    self.peeling ← true
    for part in affix.peel(query, cfg.min_affix_stem (4)), at most max_affix_tries (4):
        inner ← Engine:suggest(part.stem, 3, {literal_first=false})   // the WHOLE matcher
        best  ← inner[1]
        if best and not best.raw and best.text is a plain word:
            keep the reading with the HIGHEST best.score
    self.peeling ← nil
    return affix.join(part, stem) with apply_case

find_split(self, query):                                 // engine.lua:331
    if not cfg.split_words or corpus:lookup(query): return nil
    found ← split.best(corpus, query, cfg)               // word-break DP, MAX_WORD 24
    each part carries its own surface form                // "I am going to school"
    score ← the WEAKEST part's corpus weight
```

**`corpus:lookup(query)` is doing far more work than either affix list.** It is
what keeps `reading`, `region`, `coder`, `nonsense` out of the coinage path
entirely, and `another`/`together` out of the split path. A word the dictionary
knows is a word, not a coinage and not a run-together.

**`find_split` consults the dictionary only, never the personal store.** A word
committed once is not the language saying it is a word — it is a record of
something typed, quite possibly the very run-together this would fix.
`exactlyright` got committed while there was no other option, and that alone
stopped it being split ever after.

**Every affix peeling is tried and the best-scoring stem wins**, rather than the
first that finds anything. Taking the first was wrong in a way worth recording:
`mtrxws` is `meta` + `rxws` before it is `mtrx` + `wise`, and `rxws` does find
`rows`, so it offered `metarows` and never looked further. What decides is how
well the stem matched, which is the only evidence there is. The stem is matched
by the whole matcher recursively, because a coined word is only useful if you can
misspell it too — `resmplng` reaches `sampling` through the syllable channel, not
through an exact lookup.

**The `not trusted` gate is a latency decision, and it is nearly free.** Peeling
costs a whole extra search per reading tried, which put the 95th percentile over
the 10 ms this project holds itself to. But a coinage is by definition a word the
dictionary does not have, so the case where it is wanted is exactly the case
where the ordinary channels came back with nothing trustworthy — and `trusted`
has already been computed. Typing an ordinary word pays nothing at all for this.

`affix.peel` recognises an affix by its **consonants as well as its spelling**,
because somebody who writes `smplng` for `sampling` writes `nn` for `non` and
`psd` for `pseudo` in the same breath — and then writes it out in full, so you
get `nonfunctor`, not `nnfunctor`. The lists are longest-first so `pseudo` is
tried before `pse`-anything and `counter` before `co`.

### C.7 Trust, and when the literal leads

```
Engine:trustworthy(best, query, has_exact, typed_style, after_digit):  // engine.lua:782
    if not best: return false
    if best.cost  > cfg.confidence_cost  (1.50): return false
    if best.score < cfg.confidence_floor (62):   return false
    if has_exact: return true
    if typed_style = "upper": return false                  // ← BEFORE the length test
    if #query < cfg.trust_min_len (3):
        if after_digit: return false
        return best.cost = 0 and best.extra ≤ 1
    return true

Engine:insert_raw(out, raw, limit, trusted):             // engine.lua:811
    slot ← trusted ? cfg.raw_candidate_index : 1
    if the literal is already in `out`:
        if its position ≤ slot: return                   // leave it alone
        else move it to slot, marking it .raw
    else insert it at min(slot, #out+1), trimming to `limit`
```

The literal sits in a fixed slot — the last of the first page, resolved from
`menu/page_size` (7) when `raw_candidate_index` is 0 — so the keystroke that
commits it is predictable, *unless* nothing found is trustworthy, in which case
it leads.

**Both short-input rules exist because a *perfect* completion can still be no
evidence at all.** Before them, an adversarial audit found `x → xxx`,
`cm → come` and `CW → COW` sitting under the space bar — the one failure mode
that corrupts a document silently.

* **Capitals are tested first, and the order was wrong once.** With the length
  test first, its one-letter exception returned before the capitals test ever
  ran, and `QF` became `QFT`.
* **`after_digit` is the newest guard.** `4D`, `3D`, `4th`, `5km`, `L2`, `H1` —
  the digit goes straight into the document (digits end a word; see §D.7), so
  all the matcher sees is `D`, which adds one letter to reach `Do` and is
  therefore trusted, putting `Do` in front of the D that was typed. Nothing else
  in the language makes a letter follow a digit with no space, so the test is
  *the absence of a space* and not a list of suffixes: `4days` is taken
  literally too, and a missing space is exactly what that was.
* **`has_exact` overrides everything below it**, so `i`, `eg`, `is`, `an` mean
  themselves.
* **The one-letter, zero-cost exception survives**: `th → the` is worth trusting
  where `cm → come` and `x → xxx` are not.

`insert_raw` **moves** an existing literal rather than returning early. Returning
because it existed *somewhere* let a learned `get` outrank a literal-first `git`,
and buried literals as far down as rank 10.

Confirmed today:

```
spellless → spellless           kubectl → kubectl        x  → x, xxx, xii …
cm → cm, come, com …            QF → QF, QFT             th → the, that, this …
4D: "D" → D, Do, Day …          plain "D" → Do, Day, De …
```

### C.8 Surface, case, and the companion capital

```
Engine:surface(word, style):                             // engine.lua:141
    form ← user:surface(word)  or  corpus.forms[word]
    if not form and word ends "'s" or "'":
        base ← user:surface(stem) or corpus.forms[stem]
        if base: form ← base .. the ending you typed
    return apply_case(form or word, style)

apply_case(word, style):                                 // engine.lua:125
    if style = "upper": return upper(word)
    if style = "title":
        if starts_lower_then_capital(word): return word  // iPhone, eBay, macOS, arXiv
        return upper(word[1]) .. word[2..]
    return word                                          // never lowercases
```

Precedence: **how you write it yourself** outranks **the shipped form**, which
outranks **the corpus's lowercase spelling**.

`apply_case` never lowercases, so a form survives however the input was
capitalised. And a spelling that **opens in lower case and carries a capital
later is deliberate**, so a sentence position does not get to overrule it:
`iPhone` at the start of a sentence is `iPhone`, not `IPhone`, and the same for
`eBay`, `macOS`, `iOS`, `arXiv`, `openSUSE`, `iCloud`. No marker is needed
because the *shape* of the spelling is the statement — nobody types a capital in
the middle of a word by accident, and nothing in this program puts one there.
`don't` and `e.g.` carry no capital and take one at the start of a sentence as
they should; `LaTeX` is unaffected either way.

```
// for each ranked item, in Engine:suggest step 5           // engine.lua:609
taught ← user:surface(item.word)
if taught and taught ≠ item.word
   and corpus:lookup(item.word) and not corpus.forms[item.word]:
    capital ← item.word                  // YOUR spelling leads; the dictionary's follows
else:
    capital ← Engine:learned_capital(item.word) or corpus.capitals[item.word]
    capital_leads ← (capital = raw)      // you typed it out exactly

first, second ← entry, nil
if capital:
    second ← { text = apply_case(capital, style) .. suffix, source = "capital",
               score = item.score − 0.5 }
    if capital_leads: swap them; the leader keeps item.score, the other item.score − 0.5
append first, then second, skipping any text already in `out`
```

Three ways a word ends up with two spellings, and **none of them may lose one**.
A spelling you taught or imported used to *replace* the dictionary's, and for a
while that was accepted as the price of a personal store — which is why a pack
could not carry `Bloom` without costing you the flower. It is not a price, it is
a missing candidate.

The test is `corpus.forms`, not a guess about English: the dictionary has already
said which keys have a lowercase reading worth protecting, and it said it by
whether it gives the key a form (§B.3).

**The decision is made here rather than by reordering afterwards** because
`limit` may cut the list between the two, and the one that survives should be the
one that was asked for. And `capital_leads` compares against `raw`, not against a
style, because `apply_case` cannot act on it: `LaTeX` is neither title case nor
upper case, so the plain reading would come back `latex`.

Confirmed today:

```
ram   → ram[exact] RAM[capital] ramp[prefix] …
RAM   → RAM[capital] RAMP[prefix] …
latex → latex[exact] LaTeX[capital] later[typo] …
LaTeX → LaTeX[capital] latex[exact] later[typo] …
```

---

## D. Interaction

Everything in this section lives in `rime/lua/spellless.lua`. The governing
constraint is one sentence:

> **Rime cannot retract committed text.** `key_binder`'s `send:` looks like a way
> out and is not — it re-processes the key *inside the engine* and drops it if
> nothing handles it, so a synthetic Backspace never reaches the application.

So every spacing rule is built around never *writing* a space in the wrong place,
because it can never remove one. The only exception is §D.10.

### D.1 The trailing space rides on the word

```
M.func: trail ← cfg.auto_space ? " " : ""
        every candidate is yielded as  c.text .. trail
```

Whichever key commits the word — space bar, a number key, a click — puts the
space in too. Punctuation is the exception that needs no retraction: it ends the
word *before* the space is written and supplies the one that follows itself.

Two earlier designs failed, and both failures are instructive:

* **A leading space on the next word.** Same final text, but the candidate list
  showed a space on every entry, and any commit that bypassed our candidates — a
  Shift tap mid-word, anything typed in plain-ASCII mode — lost it.
* **Committing the space when the next word starts.** That needed the processor
  ahead of `ascii_composer`, where nothing ever composes in ASCII mode — so "no
  composition" was true for *every* keystroke and it put a space before every
  letter.

### D.2 Punctuation, and the space it takes back

```
// M.processor.func, spellless.lua:915
if cfg.auto_space and is_punctuation(code):
    if composing:
        if single_segment(context):
            text ← selected candidate's text (or context.input)
            if not preceding.opens_after_word(mark): strip the trailing space
        else:
            text ← context.input          // EVERY character, see below
        commit_text(text); engine:learn(text); clear SENTENCE; context:clear()
    if not ascii_punct: return kNoop      // the punctuator writes it, the filter spaces it
    behind ← commit_tail(history)         // the word above has just been committed
    reclaim ← ""
    if cfg.reclaim_space and preceding.hugs_previous(mark) and may_edit_document():
        if behind ends with " ": reclaim ← "\8"; strip that space from `behind`
    space ← preceding.needs_space_after(behind .. mark) ? " " : ""
    commit_text(reclaim .. mark .. space)
    if mark is in cfg.ascii_delimiters and app_allows(delimiter_apps) and not ascii_mode:
        DELIMITER ← mark; SENTENCE ← ""; ascii_mode ← true
    return kAccepted
```

**`single_segment` is a guard against losing text.** `get_selected_candidate`
returns the *last* segment's candidate, so it is only the whole answer when one
segment covers the whole input. Returning `kNoop` in the other case looks safe
and is not: `express_editor` then commits only the segment the caret sits in and
the rest of the input is gone — `hello`, Left, `,` came out as `Hell ,`.
Committing every character instead is the conservative answer.

**The mark is judged against the text it is landing on, never on its own.** A
lone `$` always reads as opening, so the closing one in `$X$` would never get its
following space (`preceding.needs_space_after` on `behind .. mark`). The
`opens`-test is run-aware, because `$$` and ` `` ` are single delimiters written
twice: looking only at the character before the last `$` would see another `$`,
call it closing, and put a space inside `$$ x $$`.

**Which marks reclaim, and which do not** (`preceding.HUGS_PREVIOUS`): sentence
punctuation and closing brackets `.,;:!?)]}`, plus the joiners `-` `/` `_` that
build compound words — `well-known`, `and/or`, `foo_bar` are the overwhelmingly
common reading after a word, and a spaced dash is not what someone types a hyphen
for. Deliberately absent: `=` `+` `*` `~`, which are arithmetic and LaTeX where
the spaces are wanted; and the **paired** marks `"` `'` `$` `` ` ``, because with
the space stripped `he said "` and `"no." ` are indistinguishable from behind.
Guessing would either weld an opening quote to the previous word or pull a
closing one out of its own sentence.

`M.filter` (`punct_spacer`) is the other half, and it only runs with
`ascii_punct` **off**. It skips any candidate containing a digit, because that is
a number separator (`1.5`) that the punctuation translator also produces.

There is a third case, and it is the one no schema can reach without the
frontend: commit a word with the space bar or a number key and *then* type
punctuation. The space is already in the document. That is what `reclaim_space`
and §D.10 are for.

### D.3 Where a sentence starts

Rime clears the commit history on **Return and Backspace alike** — a new line and
a correction look identical afterwards, and they want opposite answers. So the
processor, which sees every key, writes down which one happened.

```
properties on the shared input context:
  SENTENCE   "1:<n>"  a Return landed outside a composition: a new line
             "0:<n>"  a Backspace did: we are somewhere inside existing text
             ""       nothing since the last commit — the tail knows best,
                      and an EMPTY tail then means a context nobody has typed in yet

M.processor.func, with nothing composing:               // spellless.lua:985
    if Return or KP_Enter: SENTENCE ← "1:0";  BACKSPACE ← ""
    elif BackSpace:        SENTENCE ← "0:0";  BACKSPACE ← "1"; (word-backspace, §D.5)

read_note(context):                                      // spellless.lua:87
    (value, stamp) ← SENTENCE matched against "^([01]):(%d+)$"
    return value only if stamp = context.commit_history.size

the commit notifier clears SENTENCE, FORCED_CASE and ARMED on every commit
a Shift press (either) clears SENTENCE
```

**The stamp is written as `:0` because Rime is *about* to clear the history**,
taking the size to zero — so the note is stamped with what it will be, not what
it is.

**Both the stamp and the Shift clear are needed, and each was a bug.** Without
the stamp: tap Shift into plain typing, write a whole sentence, tap back, and a
Backspace from before the excursion is still insisting we are mid-sentence,
because ASCII-mode keystrokes reach the commit history but never reach this
processor. Without the Shift clear: a Return typed in ASCII mode clears the
history back to the size the note was stamped with, making a stale note
authoritative again.

`preceding.ends_sentence` steps back over trailing space and closing marks
**before** testing for an abbreviation, not after; testing first meant `(e.g.)` —
much the commonest way to write it — started a new sentence. Openers are stepped
over too, so `no. (the` is still a new sentence while `Hello (the` correctly is
not. Abbreviations are matched as a case-insensitive *suffix*, because the caller
passes a tail of several commits and an abbreviation at the start of a sentence
has already been capitalised to `E.g.`.

Two things this cannot know about: a mouse click that moves the caret, and an
abbreviation typed dot by dot. Backspace re-syncs the first, and on a frontend
that reads the document the whole state machine is bypassed (§C.1). The second is
why `data/forms.txt` maps `eg → e.g.` — `.` is not in the speller's alphabet, so
typing it would end the composition anyway, and committing the abbreviation as
one candidate means the whole of it is there to recognise.

### D.4 Return and its forgotten cousins

```
// all inside M.processor.func
Shift+Return or KP_Enter, composing:                     // spellless.lua:803
    text  ← context.input
    trail ← (KP_Enter and auto_space and enter_space) ? " " : ""
    commit_text(text .. trail); engine:learn(text); SENTENCE ← ""; context:clear()
    return KP_Enter ? kAccepted : kNoop          // Shift+Return goes on to the app

Return, composing, and the highlight has moved:          // spellless.lua:841
    if composition:back().selected_index > 0:
        PICKED ← "1"; context:commit(); return kAccepted

Return, composing, auto_space and enter_space:           // spellless.lua:864
    commit_text(context.input .. " "); engine:learn(context.input)
    SENTENCE ← ""; context:clear(); return kAccepted

otherwise: kNoop  →  express_editor commits the raw input, as it always did
```

**`express_editor` owns Return**, and committing the raw input is the promise that
you can always commit exactly what you typed. This processor takes it over for
one reason: to add the trailing space every other commit carries, which a
schema-level editor knows nothing about. With `enter_space` or `auto_space` off
the branch is skipped entirely.

**Shift+Return resolved to Control+Return.** librime's key binding falls back
from Shift to Control, so the un-bound Shift+Return became "commit script text",
which swallowed the newline and bypassed both the commit history and learning.
It is the soft newline in Slack and Zulip, so the word is committed and the key
goes on to the application — and it takes no space, because a space in front of
a line break separates nothing from nothing. **Keypad Enter was never bound at
all**, so the composition simply sat there while the key went to the
application; it *is* Enter, so it commits and carries the space.

**Return on a candidate you arrowed to commits that candidate.** The arrow keys
are how you disagree with the ranking without counting lines, and having
disagreed, Return is the key already under the finger — where committing the raw
input would throw the choice away and hand back the letters that were wrong
enough to go looking. The test is the *highlight* (`selected_index > 0`) rather
than "was an arrow key pressed", because a fresh composition and one you arrowed
back to the top of look the same because they are the same, and the literal
reading stays one press of Return away. It counts as a deliberate choice, unlike
the space bar: two keys aimed at one line cannot be muscle memory.

Taking the key over means doing by hand what the editor did for free.
`engine:commit_text` does **not** fire the commit notifier, so these paths call
`engine:learn(text)` explicitly — and they call `learn` and not `learn_choice`,
because committing the raw input is a refusal to choose between readings rather
than a choice (§E).

### D.5 The space bar, Backspace, and word-backspace

```
// the space bar over a literal candidate                 spellless.lua:897
if composing and cfg.confirm_literal and code = XK_space and no modifiers:
    chosen ← context:get_selected_candidate()
    if chosen.type = "raw" and LITERAL ≠ "1":
        LITERAL ← "1"; return kAccepted            // swallow the first press
// M.absorb clears LITERAL on any key that is not the space bar

// Backspace outside a composition                        spellless.lua:991
repeated ← (BACKSPACE = "1")
SENTENCE ← "0:0"; BACKSPACE ← "1"
if repeated and cfg.word_backspace and may_edit_document():
    word ← trailing word of document_tail(context)
    if word and #word > 1:
        commit_text("\8" × (#word − 1))            // ONE SHORT
        BACKSPACE ← ""
return kNoop                                       // the key itself deletes the last one
```

**The space bar asks once over a misspelling.** Reaching that branch means
nothing in the dictionary was worth putting under the space bar, so the candidate
is the raw input — a word the dictionary does not have, which is usually a
misspelling rather than a decision. The space bar is doing two jobs, pick this
word and separate it from the next, and the second is so automatic that the first
happens without being noticed. That is fine when the candidate is a real word and
exactly wrong when it is a misspelling. Anything else typed in between cancels
it, because the reason to pause was that the word was wrong. Return still commits
immediately, and always did.

**Word-backspace asks for one character short, and the key supplies the last.**
Asking for the whole word and swallowing the keystroke was a trap: the request is
a commit, and a commit is only a *request* — if the frontend will not or cannot
carry it out, nothing is deleted and the press is simply gone. Alternating with
ordinary presses, that reads as "Backspace deletes a character every other time",
which is a far worse bug than the feature is a feature. Leaving the last one to
the key means the failure is ordinary.

Discoverability is designed in: the first Backspace is an ordinary Backspace, so
you delete the space, see the word, and hit it again.

**The BACKSPACE flag lives in `M.absorb`** (`spellless.lua:641`) and nowhere
else, because that gear runs before the speller and is therefore the only one
that sees every key — a letter is consumed by the speller and never reaches the
processor below.

### D.6 Absorbing a word already in the document

```
M.absorb.func(key, env):                                 // spellless.lua:632
    ... note-keeping (BACKSPACE, LITERAL, PICKED) ...
    if not cfg.absorb_fragment: return kNoop
    if not may_edit_document(context, engine): return kNoop
    if modifiers, or not a letter, or already composing: return kNoop
    document ← document_tail(context)                    // NEVER the commit history
    fragment ← document's trailing ^[%a][%a']*$
    if not fragment: return kNoop
    commit_text("\8" × #fragment)                        // take it out of the document
    context:push_input(fragment)                         // put it in the composition
    return kNoop                                         // the speller then appends the letter
```

Delete the space after `so`, realise you meant `sooner`, and type `oner`: Rime
starts a fresh composition and offers you `one`. The `so` is right there in front
of the caret and belongs to the word being typed. Taking it back makes everything
downstream an ordinary word from there on — the preedit, the candidates, the
commit — with no special case anywhere.

Only from the document, because absorbing means *deleting*, and Rime's own commit
history is a guess — cleared by the very Backspace that creates this situation.

### D.7 Digit selection, the `PICKED` note, and notation

```
// M.absorb.func, on every key                            spellless.lua:661
page ← min(env.engine.schema.page_size or 9, 9)
picked ← context:is_composing()
      and 0x31 ≤ key.keycode ≤ 0x30 + page
      and no ctrl/alt/super
PICKED ← picked ? "1" : ""
```

`PICKED` is read by the commit notifier and is what gates `learn_choice` (§E).
**The space bar is not a choice.** At speed nobody reads the list — the space bar
goes on muscle memory and whatever is first goes in — so counting it as "this is
the word I meant" teaches the list to insist on its own first guess, and a wrong
one entrenches itself the second time you fail to notice it. A number key is
aimed at a particular line and means what it says.

Only the digits that actually select something: the page holds seven candidates,
so `8` and `9` name nothing, and whatever the frontend then does with those
keystrokes must not be recorded as a choice of the line that happened to be
highlighted at the time.

Digits also **end a word**, and that is a genuine conflict resolved in favour of
selection. librime's `recognizer` runs *before* the selector, so any pattern that
let `Lean4` compose as one token would swallow the `2` in `Mathe2` and break
candidate selection after every capitalised word. So `ident` triggers on an
underscore only (`^[A-Za-z]+_[-_.0-9A-Za-z']*$`), and the schema documents a
looser `ident_caps` pattern you can swap in at exactly that cost. The consequence
is §C.7's `after_digit`, and one more branch:

```
// a number our own spacing would otherwise split         spellless.lua:879
if auto_space and reclaim_space and not composing and the key is a digit
   and no shift and may_edit_document():
    if commit_tail(history) matches "%d[%.,:] $":
        commit_text("\8" .. the digit); return kAccepted
```

`3` then `.` commits `". "` — correctly, since nothing yet says a digit is coming
— and the digit that follows says so. Taking the space back then is the only way
to get `3.14` without either guessing ahead or leading spaces. It covers
`1,000`, `12:30` and `Smith:2020` too.

### D.8 The `qq` command mode

```
handle_magic(key, context, engine):                      // spellless.lua:1064
    prefix ← cfg.magic_prefix ("qq");  if "": return nil
    if ARMED = context.input and context.input ends with prefix:
        ARMED ← ""
        command ← MAGIC[lower(char(keycode))]
        if command:
            context:pop_input(#prefix)          // the prefix was never part of the word
            if command.case:   FORCED_CASE ← command.case
            elif command.forget: engine:forget(selected candidate's text)
            context:refresh_non_confirmed_composition()
            return kAccepted
        return nil                              // not a command: the key is text, and so was `qq`
    // arm, consuming nothing
    typed ← context.input .. char(keycode)
    arm   ← (typed ends with prefix) ? typed : ""
    if arm ≠ ARMED: ARMED ← arm                 // only written when it CHANGES
    return nil

MAGIC = { c → case "upper",   f → case "title",
          l → case "lower",   d → forget }
```

| | |
| --- | --- |
| `wndows` `qqf` | **W**indows — for a name the dictionary reads as an ordinary word |
| `api` `qqc` | API — for an acronym |
| `but` `qql` | but — defeating an automatic sentence capital |
| `qqd` | forget the highlighted candidate |

Capitalisation is otherwise *inferred* — from what you typed, from whether a
sentence just ended, from what you have chosen before — and inference is right
most of the time and unarguable-with when it is not. **These are the argument.**

`qq` because English does not contain it: one word in 83,414 does (`sqq`, at rank
65,608), and that one is a corpus artefact — so it can be typed mid-word without
ever being mistaken for part of one.

**Nothing is committed to arming, and that is the whole safety argument.** The
`qq` stays in the composition and the candidate list goes on answering it, so
nothing is lost if the next key turns out to be a letter; anything unrecognised
disarms and carries on as ordinary text, so `zzxxqq` is still `zzxxqq`. The one
cost of the feature is that `qqc` cannot be typed literally.

Two details: the arming is **stamped with the input it was armed on**, because
without that an arming survives a commit and the first letter of the next word
runs a command nobody asked for. And the property is **only written when it
changes** — this runs on every printable key of every word, and the
overwhelmingly common case is `"" → ""`, which is a write to librime's property
map and a notification for nothing.

`FORCED_CASE` is a property rather than a local because the gear that reads it is
the *translator* and the gear that sets it is a *processor*, and they get separate
`env` tables. It is cleared by the commit notifier, because a composition can end
several ways — committed, cleared, abandoned — and that is the one of them that
means "that word is done".

### D.9 ASCII mode, `$`, and editor snippets

```
M.handover.func(key, env):                               // spellless.lua:1120
    if not ascii_mode:
        if DELIMITER ≠ "": DELIMITER ← ""        // the run ended by some other route
        magic ← handle_magic(...);  if magic ≠ nil: return magic
        if snippets.count > 0 and app_allows(cfg.snippet_apps):
            typed ← context.input .. char(keycode)
            if snippets:get(typed):              // exact, case-sensitive, WHOLE composition
                if #typed > 1: commit_text(typed[1..−2])
                SENTENCE ← ""; context:clear()
                if snippet.ascii: ascii_mode ← true
                return kRejected                 // ← the last letter goes to the APPLICATION
        return kNoop
    // in ASCII mode
    if cfg.ascii_delimiters = "" or not app_allows(cfg.delimiter_apps): return kNoop
    if char(keycode) ≠ DELIMITER: return kNoop
    commit_text(mark .. (auto_space ? " " : ""))
    DELIMITER ← ""; SENTENCE ← ""; ascii_mode ← false
    return kAccepted
```

**The two halves live in different places and have to.** The opening `$` is
ordinary punctuation (§D.2): that branch ends the word, works out the spacing and
writes the mark, and all that is added is the switch plus a note of which
character opened the run. The closing one arrives in ASCII mode, where
`ascii_composer` rejects printable keys where it stands — first in the processor
list — so nothing behind it runs. Hence a gear in front of it.

**Only the delimiter that opened a run closes it.** ASCII mode reached by tapping
Shift has no delimiter, so `$PATH` in a terminal is a dollar sign followed by a
word, which is what a terminal needs it to be. Leaving ASCII mode by any other
route — Shift, F4, Control+Shift+A — makes the note stale, and the next key seen
in Spellless mode clears it, rather than the gear trying to recognise every way
the mode can change. That ignorance is the only way it can be right about all of
them.

**The space after the closing `$` is decided, not measured.** Everything typed
inside the run went straight to the application, so the commit history still
reads as it did before the run opened and `needs_space_after` has nothing to work
with. A closing delimiter takes a space for the same reason a word does.

**Both directions are gated together**: gating only the way back would leave an
application one keystroke from ASCII mode and no keystroke back out of it. And
the two lists are asked separately — `snippet_apps` (`code.exe`) is "where a
trigger is expanded", `delimiter_apps` (`code.exe,typora.exe`) is "where `$` is
maths". Typora has no snippet engine and every `$` in it is still maths; a chat
window where `$5` is a price wants neither.

**`kRejected` on the last letter is the strangest line in the codebase and it is
correct.** HyperSnips expands an automatic snippet from a document-change event
and drops any change that is not exactly one character long — its own comment
says "let's try to detect only events that come from keystrokes", which is a fair
guard against expanding on paste, and which a commit fails. `xthm` arrives as one
four-character change and expands nothing.

Committing the letters one at a time does **not** help, and it is worth writing
down why so nobody tries it twice: librime accumulates the commits of a single
keystroke into one string (`commit_text_ += …` in `service.cc`) which the frontend
reads once. Four calls and one call put exactly the same four characters in the
document, in one change.

But the guard only looks at the change that just arrived; how the text before it
got there is not its business. So the prefix is committed and the final letter is
**rejected**, which in librime means "do the OS default processing" — the key
reaches the application as itself, the change is one character long, and the
context it lands in is the whole trigger.

A trigger is the whole composition and nothing else, which is where HyperSnips'
word-boundary rule ends up when you arrive at it from this side: `dm` fires,
`dmn` does not, and neither does the `dm` inside `midmost`. Every shipped trigger
starts with `x` because no English word does. A trigger marked `ascii` hands the
keyboard over because what follows it is maths; `xthm` does not, because what
follows *that* is a sentence of English, which is the matcher's whole subject.

`Control+Shift+A` is the deliberate version of the Shift tap, and it is handled
in the processor rather than by `key_binder` because a plain `toggle: ascii_mode`
leaves the composition open and then appends plain ASCII to it — failing at
exactly the mid-word escape it exists for. It commits the composition first, and
learns it explicitly, because `engine:commit_text` does not fire the notifier.

### D.10 The frontend capability latch and the U+0008 protocol

Three features — `reclaim_space`, `absorb_fragment`, `word_backspace` — need the
input method to take text back out of the document, which is further than any
schema reaches. A companion build of the frontend adds exactly one convention:

> A commit string may begin with `U+0008`. Each one asks for one character
> immediately behind the insertion point to be replaced.

On Windows that is `ITfRange::ShiftStart` inside the existing edit session; on
macOS it is `insertText(_:replacementRange:)`. Two properties make it safe to
ship: the extended range is **read back** and the shift undone if it is not what
was expected, and it **degrades** — an application that will not give up the
range keeps its characters and the text still goes in.

```
FRONTEND_READS ← false                                   // MODULE scope, never cleared

document_tail(context):                                  // spellless.lua:307
    text ← context:get_property("surrounding_text")
    if text = nil or "": return nil
    FRONTEND_READS ← true
    return text

may_edit_document(context, engine):                      // spellless.lua:382
    if not FRONTEND_READS:               return false    // ← what lets all three ship ON
    if context:get_option("commit_only"): return false
    if context:get_option("edit_document"): return true  // the human overrules the list
    return not app_listed(context, cfg.commit_only_apps)
```

**Setting `surrounding_text` and honouring the U+0008 prefix were added to each
fork in the same commit, and no stock frontend does either — so the first is a
sound proxy for the second.** That is what lets the features ship *on*: on stock
Weasel or stock Squirrel the latch never trips, the U+0008 is never emitted, and
nothing can arrive as literal text. There is no configuration that makes them
corrupt a document.

**A latch rather than a per-keystroke test, and deliberately so.** Which frontend
is running is a fact about the *process*, not about the application being typed
into, and plenty of applications refuse a read while the frontend behind them is
perfectly capable — gating per keystroke would take the features away from those.
One cooperative window establishes it for the session. Module scope, because
librime runs one Lua state per process and a frontend cannot become a different
frontend without a restart. `M.forget_frontend()` and `M.frontend_reads()` exist
for the tests alone, because "nothing is asked of a frontend that has not
answered" is the safety property and it has to be assertable.

**The refusal list is by name, and the name is all there is.** Some applications
cannot survive the edit, and VS Code's integrated terminal is one: its text lives
in a hidden textarea that xterm.js re-sends to the pty whenever it changes, so
touching the composition backwards does not correct anything — it *replays the
buffer*. Typing `Hello`, space, `.` produces `Hello Hello.`, and after deleting
that and typing `Hey` it produces `Hey Hello. Hey.`.

Two things were tried before this and both were wrong, which is worth recording
because both look right:

* **Reading the document back does not help.** The read succeeds there, it just
  returns the buffer rather than the line — so "can I read it" answers a
  different question from "can I edit it".
* **Verifying what is about to be taken does not help either.** At the first
  `Hello ` the buffer and our own history agree exactly, and the replay happens
  anyway. The damage is in the edit itself, not in getting the target wrong, so
  there is nothing to verify that would prevent it.

VS Code is two applications under one executable — an editor that takes the edit
and a terminal that cannot — and nothing reaching that function can separate
them. Refusing both is the answer that cannot corrupt a line, and the person
typing is allowed to overrule it with the `edit_document` switch in the F4 menu.
That switch **resets every session**, because leaving it on in the wrong window
is the failure it exists to avoid.

`commit_only_apps` holds Windows executable names and macOS bundle identifiers in
one list, because they cannot collide — nothing is called both `code.exe` and
`com.microsoft.VSCode` — so the schema needs no platform branch. The Windows
entries were each earned; **the macOS half is a prediction, not a measurement**.
Being on the list wrongly costs a cosmetic space; being off it wrongly corrupts a
line, so they start on it.

Two asymmetric helpers, and the asymmetry is deliberate: `app_listed` with an
empty list matches **nothing** (a refusal list nobody wrote refuses nobody), and
`app_allows` with an empty list matches **everything** (`snippet_apps` and
`delimiter_apps` are permissions, and a permission nobody wrote is not a
refusal).

---

## E. Learning

Rime's own user dictionary learns `(code, text)` pairs emitted by a
dictionary-backed translator. Spellless candidates are synthesised in Lua and are
not dictionary phrases, so there is nothing for `Memory::memorize` to record.
Making them dictionary phrases *is* possible via librime-lua's `Memory` and
`Phrase`, but it would mean shipping a compiled Rime dictionary purely as a
backing store for codes (`rcmmndtn → recommendation`) that do not exist in it,
plus a `Memory` object per engine — a lot of machinery, coupled to a
less-travelled corner of the API, to store a word and a count.

So the store is a plain text file, `<rime user dir>/spellless_user.txt`, which has
the side benefit of being the same format as a hand-written supplemental
vocabulary list:

```
# word <TAB> count
# word <TAB> how you write it <TAB> count
# > what you typed <TAB> what you chose <TAB> count
> cli	CLI	3
grothendieck	Grothendieck	12
perverse	5
Hausdorff
```

A leading `>` cannot begin a word, so the two kinds of line share a file without
a guess. A one-column entry written with capitals is its own spelling. The file
is rewritten sorted by descending count, corrections first because they are the
interesting half and the word list below can be thousands of lines.

### E.1 What is recorded, and when

```
// the commit notifier, connected UNCONDITIONALLY in M.init   spellless.lua:206
on commit(ctx):
    committed ← ctx:get_commit_text()
    engine:learn(committed)                                   // always
    if ctx:get_selected_candidate() and ctx:get_property(PICKED) = "1":
        engine:learn_choice(ctx.input, committed)             // only a deliberate pick
    ctx[SENTENCE] ← ""; ctx[FORCED_CASE] ← ""; ctx[ARMED] ← ""
```

Two conditions have to hold before a *correction* is recorded, and the second
matters more than it looks.

* **A candidate must actually have been selected.** librime fires this notifier
  *before* it clears the context, so the input is still there to be read — and
  `get_selected_candidate` is nil exactly when Return committed the raw input,
  which is a refusal to choose rather than a choice.
* **It must have been taken by its number** (§D.7).

The notifier is connected **unconditionally**: `learn: false` must switch off the
personal store, not the sentence bookkeeping that also lives here. The gearing on
`cfg.learn` is inside `Engine:learn` and `Engine:learn_choice`.

```
Engine:learn(text):                                      // engine.lua:953
    if not cfg.learn: return
    text ← trim(text)                                    // ← the automatic space is OURS
    if text does not match ^%a[%a']*$: return
    word ← lower(text)
    if Engine:worth_remembering(text, word): surface ← text
    elif text = word:                        surface ← false   // clears a stored spelling
    dirty ← user:record(word, surface)
    if dirty ≥ cfg.flush_every (4) or now − last_flush ≥ cfg.flush_interval_ms (5000):
        user:flush()

Engine:worth_remembering(text, word):                    // engine.lua:865
    if text = word: return false
    if text = Titlecase(word) or text = UPPER(word):
        return not Engine:dictionary_explains(word)
    return true                                          // an inner capital, or an unknown word

Engine:dictionary_explains(word):
    corpus:lookup(word) or (word ends "'s" and corpus:lookup(stem))
```

**Trim first.** Without it, nothing after the first word of a sentence was ever
learned — which is to say, almost nothing.

**Neither shape of capital counts when the dictionary already knows the word.** A
*leading* capital is overwhelmingly a sentence position — ours, in fact, since
automatic capitalisation put it there — and storing it made `The` come back in
the middle of every later sentence. *All* capitals are the same mistake wearing a
different hat, and cost the same afternoon to find: write `MATHEMATICS` once in a
heading and `mathe` offered MATHEMATICS and nothing else from then on. The
ordinary word was not merely demoted, it was **gone** — the two spellings
deduplicate to one candidate and the stored one wins. Shouting a word once is not
a statement about how it is spelled.

Anything else is real evidence: `Grothendieck` (unknown to the dictionary),
`TQFT` and `MacLane` (not explained by it either), `MacOS`, `LaTeX`, `arXiv`
(mixed, so neither branch fires). A possessive is answered by its stem, because
that is how it is produced — without it, `Theorem's` at the start of a sentence
was stored as a preference and came back capitalised in the middle of every later
one.

**Committing the plain lowercase form clears a stored spelling**, so "how you
write it" stays honest and the store can be corrected by using it.

```
Engine:learn_choice(typed, text):                        // engine.lua:916
    if not cfg.learn: return
    trim both; refuse empties
    if lower(typed) = cfg.version_query: return          // ← "> zzver  app code.exe, …"
    if typed = lower(typed):                             // you typed no capital
        if text = Titlecase(lower(text)): text ← lower(text)   // so this capital is OURS
    typed ← lower(typed)
    if typed does not match ^[a-z][a-z']*$: return
    n ← user:record_choice(typed, text)
    if n ≥ cfg.flush_every: Engine:flush()
```

**A capital you did not type is ours, not yours.** Recording the result as "what
you chose" learns our own output and then insists on it: six commits of `But` at
the start of a sentence and `but` leads with a capital in the middle of every
later one. The word store has guarded against this since the day it was written;
the lesson did not get carried across when the correction store was added. Only a
plain Title Case word is stripped, so `CLI` and `TQFT` keep their capitals —
those are how the word is written, not where it sat in a sentence. Nothing is
lost by stripping, because the text is rendered back through `Engine:surface`.

The version query is excluded because taking one of its lines by its number is
how you *read* it, and without the guard the store fills up with
`> zzver  app code.exe, document readable, edits allowed`.

### E.2 How the store is read back

```
Engine:learned_capital(word):                            // engine.lua:172
    for c in user:choices_for(word):
        if c.count ≥ cfg.choice_confirm_count (2)
           and c.text ≠ word and lower(c.text) = word:
            return c.text

// in Engine:suggest, step 6
choices ← (not opts.literal_first) and user:choices_for(query)
for choice in choices, weakest first:
    if choice.count ≥ cfg.choice_confirm_count:
        text ← Engine:surface(choice.text, style)     // NO suffix: the store is keyed
                                                      // by the WHOLE input, apostrophe and all
        remove any duplicate further down; insert at slot 1
        promoted ← text
```

**One selection is not evidence.** Half of what anyone picks is picked once by
accident, and a store that led on a single choice would fill with them. The
second selection is different in kind — it says the first was not a slip — and it
is the only signal in the whole matcher that comes from the person rather than
from a measurement of English. So it is **placed** rather than scored: confirmed
means first, and no amount of frequency argues with it.

`learned_capital` is keyed on the *word*, so it follows the word rather than the
keystrokes: teaching it by typing `windows` also reaches it from `wndows`. Both
readings stay reachable throughout, because you still have to be able to open a
window.

The promotion is rendered back through `surface(choice.text, style)` so the
capital follows the input you just typed rather than the one you happened to type
the day it was learned. And **no `suffix` is re-appended here**, unlike everywhere
else in that function: the store is keyed by the whole input, so what came back
for `mther's` is already `mother's`, and adding the ending again would place
`mother's's` at rank 1.

Familiarity itself is logarithmic and saturating:

```
UserDB:score(word, saturation) = min(1, log(1 + count) / log(1 + 12))
```

so the first couple of selections move a word a lot and the hundredth barely
moves it at all. `user_weight = 18` is the lowest value at which twenty
selections still lift a word onto the first page, which is what learning is for;
at 26 it was worth three quarters of the entire frequency range, so a word
committed three times could lead over the word it was a misspelling of.

The saturation and the flush policy are passed in by the caller and deliberately
**not stored on `UserDB`**: the store is shared between engines (one per input
context, one Lua state per process), and keeping one engine's policy on it would
silently apply that policy to every other engine. The same sharing is why
`UserDB.load` memoises per path — two applications would otherwise get two
in-memory copies of the same file, and whichever flushed last would silently drop
what the other had learned.

### E.3 Undo

```
Engine:forget(text):                                     // engine.lua:892
    gone ← user:forget_word(lower(trim(text)))
    for typed in user.choices:                           // AND every correction
        if user:forget_choice(typed, text): gone ← true  // that produced it
    if gone: user:flush()                                // immediately
```

Learning is otherwise a one-way door. Commit a typo literally once, or pick the
wrong word in a hurry, and it leads the list from then on with no way back short
of editing the file by hand. `Control+Shift+D` (or `Shift+Delete`, or
`Control+Delete` — Rime's own convention, reachable when an application eats the
first) is that way back, as is `qqd`. With nothing composing it forgets the word
*last committed*, which is the case where you notice the mistake one keystroke
too late.

The dictionary is untouched — an ordinary English word goes on being an ordinary
English word, it merely stops being *yours*. The corrections go with the word,
because forgetting the word but keeping "this is what you meant by `cli`" would
leave it leading the list for ever, which is exactly what the key is for undoing.
It flushes immediately, because the point of forgetting is that it has actually
happened; it logs, because without that the whole thing was invisible — the key
was swallowed, the menu was never re-queried, and the list looked exactly as it
had a moment earlier, indistinguishable from a shortcut that had never arrived;
and it calls `refresh_non_confirmed_composition` so the reordering is on screen
at once.

### E.4 Nothing in the store is repaired on load

This is stated as a rule, at `engine.lua:64`, **because three repairs have looked
obviously right and all three were wrong.**

1. **Lowercasing a stored spelling that differs only by a leading capital on a
   word the dictionary knows** — `the → The` — on the argument that automatic
   capitalisation is the only thing that puts one there, so removing it destroys
   nothing anybody meant. That argument held until `scripts/import_pack.py`
   existed. An imported pack writes exactly that shape *on purpose*:
   `dijkstra → Dijkstra` is a word the dictionary has, spelled lower case, and
   the whole point of importing is to respell it. The repair silently ate every
   such entry — and by then it was cleaning nothing, because `learn` had already
   refused to create those rows for long enough that a real store of 1,689 words
   had none left.
2. **Lowercasing ALL CAPS spellings too.** Never shipped: simulated against a
   real store it took `pc → PC` and `vs → VS` out along with the accidents.
   Nothing capitalises a whole word automatically, so one in the store was typed
   that way, by a person, on purpose.
3. **Folding the corrections.** A correction is keyed by the lowercased input, so
   on disk `> windows  Windows  2` and `> but  But  6` are the same shape: one is
   somebody who typed a capital W and took the candidate by its number, the other
   is our own sentence capital from before `learn_choice` guarded against it, and
   nothing in the file tells them apart. A fold that lowercases both destroys
   `learned_capital`, permanently, on the next engine the process builds.

**So the guards live where the information still exists** — at record time, in
`learn_choice` and `worth_remembering` — and a row that is wrong is removed the
way any other unwanted row is: `Control+Shift+D` on the candidate.

---

## F. Edge cases, and what motivates each

Every row is a guard in the shipped code. The right-hand column is the input,
string or situation that put it there.

### F.1 The distance DP (`distance.lua`)

| guard | motivated by |
| --- | --- |
| abort needs **two** consecutive over-budget rows | `ifnomration → information` — two transpositions, 0.90 total, silently discarded |
| column zero included in the row minimum | `aathe → the` — the abort fired on a value no cell had |
| `if delta > band: return nil` | otherwise `r1[m]` is a stale cell from a wider earlier call, not a distance |
| `r2[hi+1] ← nil` after each row | same, one row later |
| apostrophes excluded from `min_indel_any`, included in `min_indel_gate` | at 0.15 an apostrophe widens the band from one column to four for *every* word; but the length gate must accept `dont → don't` |
| a doubling slip does not change the letter set | so the mask budgets need a different "cheapest indel" from the band |
| `price_a` memoises on string **and** profile | three profiles run over the same query in one keystroke |

### F.2 The cue channel (`cue.lua`)

| guard | motivated by |
| --- | --- |
| `wb[0], wb[m+1] ← nil` | the scratch arrays outlive the call; a longer previous word answers for this one |
| `k−1 ≤ lmax and k+1 ≥ rmin` in the slip test | without them the test reads a stale `lpos`/`rpos` left by an earlier, longer query |
| the slip transition is off for a `clean` word | keeps the exact reading of every such word unchanged, and the branch off the vast majority of alignments |
| a slipped word gets `budget + slip`, not a wider budget for all | the ceiling on clean readings is what keeps the scan quick |
| first letter must match | otherwise a three-letter query proposes half the dictionary |
| apostrophe classed as a vowel | `dont` for `don't` is the same shorthand |
| no fourth class for a doubled letter | `embarass → embarrassed`, `adn → adding` |
| the tail is charged | deleting it costs 1.6 points of top-1 and puts `embarass` back behind `embarrassed` |
| `min_cue_slip_len = 5` | `tnk` with one letter wrong could be shorthand for anything, and letting it be turns a three-letter query back into a dictionary scan |
| `cue_slip_checks` is its own ceiling | the relaxed filter admits 5–10× as many words; they must not crowd out the clean ones |
| the shortlist is keyed by `cost_weight·d − freq_weight·freq` | `tnk` aligns onto `tonkin`, `tankers` cheaply, and cost order dropped `think` before the ranker saw it |

### F.3 The corpus and the build

| guard | motivated by |
| --- | --- |
| `[^\r\n]+` when splitting the word list | a Windows checkout with `core.autocrlf` put a `\r` inside every committed word |
| exact size checks, not minimums | a *longer* stale index hands out ids past the end of the list |
| `Corpus.fingerprint` in the memo key | a redeployed dictionary was loaded once and kept for the life of the process, with the indexes of the wrong generation |
| `partition_point` takes a predicate | sentinel bytes would depend on `strcoll` |
| `each_skeleton_completion(cap)` | a two-letter skeleton has tens of thousands of completions |
| skeleton cache dropped at 30,000 | rather than hold a second copy of the corpus |
| contractions floored at rank 500 | all 64 share a tail count in the source; without the floor a dropped apostrophe finds nothing |
| bare contraction spellings added only where not already a word | `cant`, `its`, `hes`, `were`, `wont`, `ill` are ordinary English |
| `you'v` rejected by `CONTRACTION_TAILS` | one truncated artefact in the source; the hole it left is filled by `vocab/contractions.txt` |
| single letters other than `a` and `i` dropped | noise |
| `#!capitals replace` is per **file** | corpus rank cannot tell `africa` from `ram`; treating 400 names as ambiguous costs 3 points of top-1 |
| forms.txt warns about a key not in the dictionary | a typo there is otherwise silent |
| `march`/`May` may not be listed in forms.txt | the lowercase word is a real one and listing it makes the verb unreachable |

### F.4 The matcher

| guard | motivated by |
| --- | --- |
| apostrophe filter tests the **written form**, not just the key | `it's` offered `it'd's` and `it'll's`, because `dont`/`itd`/`thats` are keyed without apostrophes |
| the whole possessive is looked up before the stem | `McDonald's` was in the store and came back `mcdonald's` |
| no `suffix` re-appended to a promoted choice | `mother's's` at rank 1 |
| `find_split` refuses a dictionary word | `another → a not her`, `together → to get her` |
| `find_split` ignores the personal store | `exactlyright` committed once stopped it being split ever after |
| `find_affix` refuses a dictionary word | `reading`, `region`, `coder`, `nonsense`, `unit` |
| all affix peelings tried, best stem wins | `mtrxws` is `meta`+`rxws` before `mtrx`+`wise`, and `rxws` finds `rows` → `metarows` |
| `self.peeling` allows one level | `unresampling` is not worth the second search |
| coining gated on `not trusted` | it put p95 over the 10 ms budget |
| `insert_raw` **moves** an existing literal | a learned `get` outranked a literal-first `git`; literals were buried at rank 10 |
| capitals tested before length in `trustworthy` | `QF → QFT` |
| `after_digit` | `4D` gave `4Do`; `D` reaches `Do` by adding one letter |
| `unknown_word_penalty` | `eys`, committed three times, led over `eyes` for good |
| `hold_exact` | `sth` offered `the`, which had been committed hundreds of times |
| `user_cost_margin` | `immsn` put the literal first and `immersion` third |
| `defer_inflections` is a partition, not points | 8 points sent `related` from first to fourteenth |
| `past_inflection` requires the stem to be a word | otherwise the rule demotes `need`, `proceed`, `indeed` |
| `out.leader` captured before the reorder | `allsg → alleged` demoted after a modal made the literal lead |
| `prefer_bare` stands down on a trailing `d` | `clld` means `called`; all 1,118 measured `-ed` shorthands keep their `d` |
| `case_style` requires `#raw ≥ 2` for "upper" | so a bare `I` is title case, not upper |
| `starts_lower_then_capital` | `iPhone` at a sentence start came out `IPhone`; also `eBay`, `macOS`, `iOS`, `arXiv`, `openSUSE`, `iCloud` |
| personal index filters on `^%a[%a']*$` | a hand-edited file can hold anything, and the bucket key assumes a lowercase first letter |
| `max_query_len = 32` | the personal pass and the elastic alignment both grow with the square of the input length |

### F.5 The adapter

| guard | motivated by |
| --- | --- |
| `single_segment` before using `get_selected_candidate` | `hello`, Left, `,` came out as `Hell ,` |
| `commit_tail` stitches 6 records / 16 chars | `He said "no."` became `."the` and lost the capital |
| `commit_tail` resolves U+0008 | the history records the *request*; downstream wants the text |
| the sentence note is stamped with the history size | a Shift excursion left a stale Backspace insisting we were mid-sentence |
| a Shift press clears the note outright | a Return in ASCII mode clears the history back to the stamped size |
| the note is stamped `:0` | Rime is *about* to clear the history |
| `ARMED` stamped with the input | an arming survived a commit and the next word's first letter ran a command |
| `ARMED` written only when it changes | it runs on every printable key of every word |
| `PICKED` limited to `1..page_size`, no modifiers | `8` and `9` name nothing on a seven-candidate page |
| `page > 9 → 9` | there are only nine digit keys |
| `BACKSPACE` kept in `M.absorb` | it is the only gear that sees every key |
| word-backspace asks for `#word − 1` | a swallowed keystroke made Backspace work every other press wherever the request went unanswered |
| absorb reads only the document | the very Backspace that creates the situation clears the history |
| the closing `$` only closes a run *we* opened | `$PATH` in a terminal |
| `DELIMITER` cleared on any return to Spellless mode | Shift, F4 and Ctrl+Shift+A all leave ASCII mode silently |
| both `$` directions gated on `delimiter_apps` | gating only the way back left an application one keystroke from ASCII mode and none back |
| `kRejected` on a snippet's last letter | HyperSnips drops any document change that is not one character long |
| snippet trigger must be the whole composition | the `dm` inside `midmost` |
| the punct filter skips text containing a digit | `1.5` is a number separator, not a sentence |
| `opens_after_word` | `see (the)`, never `see(the)` |
| digit-after-punctuation reclaim | `3.14`, `1,000`, `12:30`, `Smith:2020` |
| `may_edit_document` decided by name | VS Code's terminal replays its buffer; neither reading the document nor verifying the target detects it |
| `edit_document` resets every session | left on in the wrong window it is the failure it exists to avoid |
| `FRONTEND_READS` latch | a stock frontend would insert the U+0008 literally |
| `app_listed("") = false` but `app_allows("") = true` | one is a refusal list, the other a permission list |
| `key_binder` states its own bindings, no preset | the preset gives `minus`/`equal`/`comma`/`period` to paging, and it runs *before* our processor — so those four could not be typed at all |
| `recognizer/uppercase: ""` | Rime's preset sends anything starting with a capital straight through as literal text, defeating capitalised input |

### F.6 `preceding.lua`

| guard | motivated by |
| --- | --- |
| the `opens` test is run-aware | `$$` and ` `` ` are one delimiter written twice; a space would land inside `$$ x $$` |
| closers **and openers** stripped before the abbreviation test | `(e.g.)` — much the commonest way to write it — started a new sentence |
| abbreviations matched as a case-insensitive suffix | the caller passes a tail of several commits, and `E.g.` has already been capitalised |
| nothing outside ASCII gets a Latin space | CJK brings its own spacing conventions |
| paired marks excluded from `HUGS_PREVIOUS` | with the space gone, `he said "` and `"no." ` are indistinguishable from behind |
| `previous_word` rejects two spaces, punctuation, a trailing apostrophe | it is read for its part of speech, and a wrong reading is worse than none |
| `expects_bare_verb` clips at `[^.!?;:]*$` | "we could. However, related work…" walked back over the full stop |
| typographic `’` normalised to `'` | a frontend that substitutes it must not hide `wouldn't` |
| the gap after each token must match `^[%s,]*$` | `would-relate`, `would (`, `would 3 ` are not bare-verb slots |
| `LY_VERB` exception list | `apply`, `imply`, `rely` all turn up in the verb slot in the sample |
| adverbial phrases are a closed list of 24 | a shape-based scan reaches 5.6% more slots and doubles the error rate |
| `in` and `to` not skippable alone | "interested in related work" is not a bare-verb slot |
| `ADVERB_CHAIN = 3`, `LOOKBACK = 96` | this runs on every keystroke |

---

## G. Known weaknesses and open questions

This section exists to be argued with. Nothing in it is rhetorical.

### G.1 The scoring function is linear, hand-designed, and fitted on the set it is scored on

**There is no data, and that is the root of it.** No keystroke log of (what was
typed, what was committed) exists for this task, so every weight was fitted on
constructed cases by coordinate descent (`bench/tune.lua`) over the same
`tests/cases/*.tsv` it is scored on.

The damage is *bounded* rather than fixed. The generated portion comes from a
seeded generator, so a fresh seed is a free held-out set, and there is no
measurable optimism left on any file — every gap is inside one standard deviation
of the seed-to-seed spread, and about half of ten fresh draws beat the shipped
seed on each file. What removed the optimism was not a better fitting procedure
but **abandoning the fit**: the shorthand channel's five free constants were
replaced by a normalised generative model whose three probabilities are *counted*
(§C.4), and its held-out mean rose from 78.0% to 88.1% while the shipped seed's
own reading rose only 85.7 → 88.0. Five free constants over 300 cases were buying
about eight points of nothing.

Three things this still does not answer:

* **Does the generator's model of how people abbreviate resemble how people
  actually abbreviate?** A fresh seed re-samples from the same generator against
  the same dictionary. It says nothing about this.
* **The 335 hand-written cases have no held-out version and cannot have one.**
* **Every case is a transcription.** An input is given and the word it stands for
  is known. Writing is not that: when you are composing, the spelling is the
  thing you do not have — which is the entire reason this project exists — and
  when you are copying it is in front of you. Measuring the thing that matters
  needs a test where the words come out of the typist's own head, and nobody has
  built one.

Two structural facts about the score itself:

* **There is an exact one-parameter gauge freedom.** Multiply every constant in
  §C.5 by any λ and the evaluation is identical to six decimal places, because a
  score is only ever compared with another score. The single exception is
  `confidence_floor`, which is the only place in the codebase a score meets a
  constant rather than another score — scale everything but it and what breaks is
  precisely the literal-input guarantee. Thirteen real degrees of freedom, not
  fifteen, and the tuner searches nine.
* **The tuner has a blind spot that is doing useful work by accident.** Its grid
  omits `base_exact`, `form_bonus` and `unknown_word_penalty`, which pins the
  gauge freedom — that is *why* the descent converges rather than drifting along
  a flat direction. But it also means the tuner cannot express "everything
  matters more relative to `base_exact`" except as a simultaneous move of eleven
  coordinates, which coordinate descent cannot make.

Two hypotheses were implemented and measured and both came back negative: a
cost–frequency interaction `w_c · cost · (1 + β(1−f))` (the predicted direction
is monotonically *wrong*; β = +1.0 costs 30 cases at rank 1, and the shallow
optimum at −0.45 turns out to be `cost_weight` in disguise) and recalibrating
`cost_weight` to its measured optimum of 13 (raises the training objective, worth
−0.12 ± 0.15 held out).

### G.2 The benchmark cannot see most of the program

This is the sharpest thing to know before reading any accuracy number.

`lua bench/evaluate.lua -- affix_words=false` returns **bit-identical** accuracy,
because no case file contains a coined word. Slip-tolerant shorthand is the same
shape: not one case file contains a corrupted shorthand. So are the correction
store, the companion capitals, the possessive path, and *every single thing in
section D*. The 1,535 cases measure the four matching channels and nothing else.

`bench/probe.lua` covers two of those blind spots. The rest have only unit tests,
and unit tests do not tell you whether a feature is worth its latency.

### G.3 The corpus is the weakest part of the system

Google Books skews old and literary and keeps proper nouns as ordinary lowercase
tokens, so `mathew`, `mather` and `mathews` all compete with `mathematics` for
the input `mathe`. `wordfreq` (subtitles, web, Wikipedia, news) and the
OpenSubtitles frequency lists are both open and both fix this directly, because
names are rare in speech-like text. Blend in the log or Zipf domain rather than in
counts, and treat capitalised-in-corpus tokens as their own *class* rather than
demoting them — those tokens are exactly what somebody typing a surname wants.

This is probably worth more top-1 than any further weight tuning, and it is a
data problem rather than an algorithm problem, which also means it is easy to
make worse.

The frequency term uses a *normalised log* in [0,1], which compresses rank 100
against rank 10,000 into very little score. That is deliberate — a linear-in-count
term would make `the` unbeatable — and the cost is now measurable: across the
band people type, the entire frequency spread is 4.7 nats, which cannot buy a
single full-price edit. Using Zipf units directly and letting the points-per-nat
calibration set the weight is the principled version.

### G.4 What is arbitrary or hand-set, named

* **`cue_cost_scale = 9`.** The one number in the shorthand channel with no
  probabilistic meaning, and by measurement the most consequential dial in it.
  The aggregate is flat over 5–12, so the data does not choose; the setting is a
  statement about who is typing.
* **The five base scores and `form_bonus`.** These are mixture weights over
  channels dressed as additive constants. A principled treatment would normalise
  *across* channels, which means `max` becomes a sum and the bases become real
  mixture weights.
* **`split_word_penalty = 0.8`.** Bounded by observation from both sides — at 1.4
  `as a matter of fact` starts losing to `asa matter of fact`, at 0 everything
  shatters — but nothing says 0.8 rather than 1.0.
* **`bare_verb_window = 5`** is "a page", and `context_margin = 12` is the gap
  between two measured facts (9.8 and 19.7) rather than a fitted value.
* **The QWERTY neighbour model** is one keyboard, ignores hand alternation and
  finger travel, and is not learned from anything.
* **`unknown_word_freq = 0.2`** was "middling" and was too generous; the current
  value is "low enough to lose a close contest, high enough that a name you have
  committed still beats the noise", which is a description, not a measurement.
* **`user_saturation = 12`, `choice_confirm_count = 2`, `flush_every = 4`,
  `import_pack` count 4** — the last has a measured curve behind it; the first
  three do not.
* **The macOS half of `commit_only_apps` is a prediction.** None of those bundle
  identifiers has been typed into.

### G.5 Structural limits that are open

* **The fuzzy readings do not compose.** Splitting is exact only: `exactlyright`
  works, `exctlyrght` finds nothing, because every part would need the full fuzzy
  search at every split point. There is a reuse trick that makes it tractable —
  align a dictionary word against the query with the *query* as the DP's row
  index, and the final column gives the cost of that word explaining every prefix
  `q[1..i]` at once, so one DP per candidate yields all its split points — and
  the gate in §C.6 already exists. Not built.
* **Consecutive keystrokes re-search from scratch.** Restricting the next scan to
  the previous candidate set plus one edit should cut typical latency several
  fold, and that is the headroom every other item on this list needs. The
  non-monotonicity is real for the budget-cut set but not for a *slack* set,
  which is the way through.
* **The gate that two features are waiting for.** Twice now the answer to "this
  is real recall at a cost on every keystroke" has been the same, and nobody has
  built it:

  | feature | what it buys | what it costs |
  | --- | --- | --- |
  | `scan_first_neighbours` | a wrong first key, 1.6% → 98.2% on page 1 | +27% per keystroke, p95 over budget |
  | slip-tolerant shorthand | corrupted shorthand, 27% → 80% on page 1 | +0.35 ms per keystroke |

  The second is on, spending about a third of the remaining p95 headroom; the
  first is off and would spend the rest. Both would be free almost all the time
  if they ran as a **second pass gated on `Engine:trustworthy`** — a predicate
  that already exists and is already computed.
* **Context.** One previous word is worth about 0.4 points of top-1, and the
  class-bigram version loses at every weight (§C.5). What survives is the
  bare-verb rule, and the lesson is that the lever is not a better classifier —
  it is finding the places where English has no choice. The same shape could go
  to `an` (which constrains the *first* letter, where the search is widest),
  determiner–number agreement, and `have`/`is` with the sign flipped. None of
  them reaches the largest remaining failure class, **vowel identity**
  (`motions`/`meetings`, `blocks`/`blacks`), which is noun against noun and needs
  a word bigram.
* **The word on the right.** Most of the remaining sibling evidence lives there,
  and an input method could in principle see it, since the user types it a moment
  later. Nobody has tried.

Where it fails, from the full sweep recorded in `docs/ALGORITHM.md` §6 — taken
when the total read 89.6% rather than today's 91.1% training / 89.8% held out,
so treat the shape rather than the counts: 159 of 1,535 cases (10.4%) did not lead; of those, 61% were at
rank 2, 28% at rank 3–5, 10% at rank 6–20, and **one was not offered at all**
(`coa`, wanted for `coca`). 62% of the residual is ordering between two readings
that are both defensible. The classes are morphological siblings
(`rgulator → regulator` where `regulatory` was wanted), vowel-identity loss
(`mtns → meetings` where `motions` was wanted), short input (`frm` legitimately
offers from/form/firm/farm/forum), and deliberate ties (`its`/`it's`).

### G.6 Things I found while reading that look wrong

**Eleven of these twelve have been fixed since.** They are kept in full rather
than deleted, because the *class* of each is the useful part for a critic: what
kind of mistake this codebase makes, and which of its guards did not catch it.
Where a fix exists it is named. Only finding 12 is still open, and it is an
observation rather than a defect.

**1. The shipped schema turns off the three features that config, README and
DESIGN all say now ship on.** Commit `7214c78` flipped `reclaim_space`,
`absorb_fragment` and `word_backspace` to `true` in `config.lua` and rewrote the
prose accordingly, but did not touch `rime/spellless.schema.yaml`, which still
has: **Fixed in `64fb607`.**

```yaml
spellless:
  reclaim_space: false
  absorb_fragment: false
  word_backspace: false
```

`schema_overrides` (`spellless.lua:103`) reads every key whose default is a
boolean with `get_bool`, and `false` is not `nil`, so these become overrides. On
a real install all three are **off**, whatever the documentation says, and the
schema's own comments still carry the superseded reasoning ("Needs the Spellless
build of Weasel… Leave it false on a stock install"). `scripts/package.py`'s
generated release README says the same. The test that guards this file only
checks that each key *exists* in `config.lua`, not that the values agree.

**2. The same drift silently disables the macOS half of `commit_only_apps`.**
`config.lua` lists ten bundle identifiers (`com.apple.terminal`,
`com.googlecode.iterm2`, `com.microsoft.vscode`, …); the schema's
`commit_only_apps` line stops at `putty.exe`. Because the schema value overrides
the default, a Squirrel fork typing into Terminal.app would not be refused
document edits. Today that is masked by finding 1 — but fixing finding 1 without
also fixing this one would expose it. **Fixed in `64fb607`.**

**3. `generate_possessive` is unreachable.** It is called only from the `else`
branch of `if stem then` in `Engine:suggest`, i.e. only when the query does *not*
split into stem + `'s`/`'` — but `Engine:possessive_stem` requires the query to
end in `'s`. An exhaustive search over every string of length ≤ 7 over
`{a, s, '}` finds the branch reachable only for inputs whose stem begins with an
apostrophe (`'a's`), which the speller's `initials` cannot produce and for which
no dictionary lookup can succeed anyway. The productive possessive is delivered
entirely by the stem/suffix split at the top of `suggest`. (`possessive_stem`
itself is still live, via `has_exact`.) **Removed in `ab8b561`.**

**4. `read_behind` computes `out.fragment` and nothing reads it.** `M.absorb`
computes its own fragment from the document. The field costs one pattern match
per keystroke whenever `absorb_fragment` is on and the document is readable. **Removed in `ab8b561`.**

**5. `write_note` (`spellless.lua:82`) is dead**, because both writers inline
`SENTENCE_YES .. ":0"` — they need to stamp with 0 rather than the current size.
`UserDB:forget_surface` is referenced nowhere at all; `UserDB:words()` and
`util.popcount26` are used only by tests. **`write_note` and `forget_surface` removed in `ab8b561`; `UserDB:words()` is live (the personal index calls it) and `popcount26` is kept as the reference the masks are tested against.**

**6. `config.lua`'s `cost_weight` comment is arithmetically stale.** It says "a
repair also has to cross `base_exact - base_typo = 25`, and 41 points is 17.4
nats… a full-price repair *never* beats an exact dictionary match at any
frequency — it is a veto, not a price". With `base_exact = 84` and
`base_typo = 75` that gap is **9**, so the total is 25 points ≈ 10.6 nats and a
full-price repair *can* in principle win. `docs/ALGORITHM.md` §4.8 has the
corrected version; the code comment does not. **Fixed in `ab8b561`.**

**7. Every long-form document is a dictionary behind.** `docs/ALGORITHM.md`,
`EVALUATION.md`, `DESIGN.md` and `data/README.md` all say **83,364 entries**;
`generated/spellless.build.json` says **83,414**. ALGORITHM.md and EVALUATION.md
report **89.6% / 98.9%** top-1/top-5 on the shipped seed; `lua bench/evaluate.lua`
prints **91.1% / 99.0%** today. README.md's `zzver` example shows `83137 words,
622 forms`; it is 83,414 words and 809 forms. **Fixed in `ab8b561` and `849376f`.**

**8. Three sections of the long-form docs describe code that no longer exists.**
ALGORITHM.md §4.7 and its §4 diagram, and DESIGN.md §7 "How it is used", all
describe the personal store as "a linear pass over the ≤400 most-used entries"
capped by `personal_scan_limit` — the design that commit `bf30bc7` replaced with
`Corpus.of_words` precisely because the cap was a promise the software could not
keep. DESIGN.md §7 also names `repair_personal`, which was removed by `7baac34`
along with the whole idea of repairing the store on load. DESIGN.md §5.6 and
§“`$` hands the keyboard over” name the gear `lua_processor@*spellless*delimiter`;
it is `*spellless*handover`. DESIGN.md §10 lists "remember the input, not just
the word" as the top next step; it shipped. **Fixed in `ab8b561`.**

**9. `scripts/build_dictionary.py:parse_vocab_file`'s docstring describes the
`+` marker system that was replaced.** It says at length that "a capitalised
entry followed by `+` … keeps *both* spellings" and that "without the marker the
capitals replace". The function no longer parses a `+` at all; `additive` is
derived in `main()` from base-corpus membership and `#!capitals replace`. The
docstring even carries the reasoning for why the build "cannot decide this for
you and should not try", which is now exactly what it does. **Fixed in `ab8b561`.**

**10. ALGORITHM.md contradicts itself about slip tolerance.** §8.4 says it
"ships off for latency (§8.9)"; §8.9 says "The second is now **on**". The code
ships it on (`cue_slip_cost = 10.0`). **Fixed in `ab8b561`; §8.4 now says on.**

**11. The bare-verb measurement is quoted twice with two different numbers.**
`config.lua` (`bare_verb_window`) says the predicate "fires on 3,979" of 374,090
slots; `docs/ALGORITHM.md` §8.1 says "it fires on **3,994**". Both then report 11
improvements against 0 regressions, so one of the two counts is stale. **Fixed in `ab8b561`; 3,994 is right, 3,979 predated the phrase list.**

**12. Two smaller inconsistencies that each have a defence, but are worth a
second opinion.** `M.filter` judges the space after punctuation against
`commit_tail` alone, never `document_tail`, so on a frontend that can read the
document the filter is working from the weaker source (this path only runs with
`ascii_punct` off, so it is rarely exercised). And the digit-reclaim branch at
`spellless.lua:882` likewise reads `commit_tail` rather than `text_behind`; here
the justification given elsewhere in the file — "any word above has already been
committed, so the history is current" — does not obviously apply, because no word
was committed on that path. **Still open.**

---

## Reproducing everything here

```bash
make                                   # dictionary, indexes, generated test sets
lua tests/run.lua                      # 2,316 checks
lua bench/evaluate.lua                 # the accuracy and latency tables
lua bench/probe.lua                    # the two harsher probes
lua bench/try.lua --debug mthmtcs satfcatn tnk    # ask it anything
lua bench/context.lua                  # score a replacement class table
lua bench/tune.lua 3                   # the coordinate descent

python3 scripts/make_testset.py --seed 12345 --out /tmp/fresh
lua bench/evaluate.lua --cases /tmp/fresh          # a free held-out set
```

Typing `zzver` into the input method reports the running build. The first line
comes from `spellless/version.lua`, a module the installer *overwrites*, rather
than from a data file — so it names what the process actually loaded, which is
the only version of the question worth asking. The rest is read from the live
corpus and the live configuration and so cannot be stale by construction.

Most of what is worth knowing about a constant is written next to it in
`rime/lua/spellless/config.lua`, including the sweeps that were run and not acted
on.
