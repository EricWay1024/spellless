# Why is that candidate first?

One question, answered end to end: you typed some letters, a list came back,
and something is at the top of it. This document says what put it there.

It is a synthesis rather than a new account — the implementation detail lives in
[PIPELINE.md](PIPELINE.md) §C and §E, and the mathematics in
[ALGORITHM.md](ALGORITHM.md) §4 and [NOISY-CHANNEL.md](NOISY-CHANNEL.md).
What is here is the *order of authority*: which mechanism gets to overrule which,
and why.

---

## The short answer

Five layers, each able to overrule the one below it:

| | layer | decides |
| --- | --- | --- |
| 1 | **What you wrote down** | a shortcut you typed into `spellless_shortcuts.txt` |
| 2 | **What you spelled right** | an exact dictionary hit — *the guard* |
| 3 | **What you taught it** | a correction you confirmed twice |
| 4 | **What English says** | one additive score over five generation channels |
| 5 | **What you actually typed** | the literal, in a fixed slot, or first when nothing is trusted |

Layers 1, 2, 3 and 5 are **placements** — positions in the list, not points on a
score. Only layer 4 is arithmetic. That distinction is the design stance of the
whole matcher, and the reason is always the same: *there is no score that means
"worth having, never worth preferring"*.

---

## Layer 4 first: the score

Everything that is not placed is scored by one additive function and sorted
(`rank.lua`, `M.score`):

```
score =  base[source]                    what kind of match this is
       + 34 · freq(word)                 corpus log-frequency, normalised to [0,1]
       + 18 · user(word)                 your own history, [0,1], saturating at 12 commits
       − 16 · cost                       what the reading had to assume you got wrong
       −  8 · extra                      how much longer the completion is, /10, capped
       − 25 · [word not in the dictionary]
       + 70 · [exact hit on a key with a written form]
       ± 10 · [skeleton or cue] · (2·consonantness − 1)
```

with per-source bases `exact 84`, `typo 75`, `prefix 74`, `cue 70`,
`skeleton 62`.

The bases express only a **broad** priority. They are deliberately close
together so that frequency and cost do the fine ordering: a very common word
reached by a cheap typo can and should overtake a rare exact prefix completion.
That is why `base_exact` is 84 and not 120 — at a large gap, no completion could
ever overtake a word you had actually typed, and `contras` beat `contrast`,
`sear` beat `search`, `wit` beat `with`.

### Three parts of the score that are arguments, not tunings

**`user_weight = 18`, and withdrawn from a bad reading.** Familiarity is
evidence about the *word*; cost is evidence about the *reading*. That you write
"instead" sixteen times a day is a reason to prefer it among readings that
explain the input equally well, and no reason at all to accept a reading that
explains it much worse. It once was: `immsn` gave the literal first and
`immersion` third, because "instead" came back at cost 1.55 and eighteen points
of familiarity covered the 16.5 the extra cost had taken off — winning by 0.1
over a cost-0.52 reading. So the bonus is withdrawn from a reading more than
`user_cost_margin = 1.0` worse than **the best on offer**. Not from a poor
reading as such: a flat absolute threshold was swept over a real store and lost
nine recorded corrections, `buracitc` → bureaucratic among them, which are
exactly the hard repairs familiarity exists to rescue.

**`unknown_word_penalty = 25`.** Being typed exactly is not the same evidence
from a word nobody has measured as it is from a word in the dictionary. Without
it, a mistake committed three times (`eys`) led over the word it was a
misspelling of (`eyes`), permanently.

**`form_bonus = 70`.** An exact match on a key somebody deliberately wrote down
(`sth` → something) differs in kind from an exact match on an ordinary word.
Raising `base_exact` instead was tried and made every rare word unbeatable.

### Two guards inside the ranking

`hold_exact` — **familiarity may not overturn an exact match.** A rival that
beats the exact hit on measured English alone still wins; a rival that only beats
it because of your personal counts is clamped to `ceiling − 1e−9`. "sth" must
mean `something` however many hundreds of times "the" has been committed.

`defer_inflections` — after a modal, `-ed` readings sink to the back of the first
page. A **stable partition**, not a penalty: eight points off `related` once
moved it from first to *fourteenth*, because the field around a three-letter
skeleton is dense enough that eight points spans a dozen words. That is removal
wearing the clothes of a demotion. A partition says what grammar knows — these
readings are wrong here — and nothing about how much better `result` is than
`reality`. Ships disabled.

---

## Layer 2: the guard

> **You typed an English word, spelled correctly. That word leads.**

This is the only rule in the list a typist can see from outside, and it now
outranks everything the personal store has learned.

The failure that produced it: typing `start` offered `started`, because `started`
had been picked twice and a confirmed choice was placed at slot 1 regardless of
score. `start` was an exact hit scoring 121.7 against its 86.0 and still came
second.

An earlier rule tried to prevent this by asking whether **both** readings had
been confirmed. It got `its` and `were` right, where the literal had been picked
often enough to prove itself, and left `start` losing on one pick fewer — a
threshold nobody typing can see, deciding something they can. Whether the input
is a word is not a threshold.

### What the guard does not catch

**A capital is the same word.** `OK` for "ok" is what you typed, spelled the way
you taught it. The test is `lower(choice) = query`, which catches exactly the
readings differing from the input by case alone, and they keep slot 1.

**An input that is not a word has nothing to guard.** `teh`, `mthmtcs`,
`nbhood`, `pcutation` — the confirmed correction leads, which is what the store
is for. Eighteen of the thirty-four confirmed corrections in the live store are
of this kind and none of them moves.

### Why there is no list of exceptions

The obvious objection is `dont` → `don't`. Those bare spellings *are* in the
dictionary — it is built from measured English text, and people write
apostrophe-less forms constantly — so a naive reading of the guard hands them
back unapostrophised. It does not, because the dictionary already separates the
two cases:

| | the dictionary entry | so the exact hit is |
| --- | --- | --- |
| `dont`, `im` | a **key** whose *form* is `don't` / `I'm` | the contraction, at 176.1 and 158.7 — nothing to configure |
| `cant`, `hes`, `ill`, `lets`, `whats`, `wont` | words in their own right — hypocrisy, a habit | the bare word; the contraction arrives through the typo channel at 0.15, the cost of its apostrophe |

For the second row, the escape hatch is the forget key.

---

## Layer 3: the personal store

Three kinds of row in `spellless_user.txt`, and they do different jobs:

```
word            <TAB> count            you have committed this word
word <TAB> form <TAB> count            and this is how you write it
> typed <TAB> chosen <TAB> count       this is what you meant by that input
- word                                 never offer me this one
```

**A count is a score** — it feeds `user(word)` in layer 4, saturating at 12.

**A confirmed choice is a placement.** One selection is not evidence: half of
what anyone picks is picked once by accident, and a store that led on a single
choice would fill with them. The second selection says the first was not a slip,
and it is the only signal in the matcher that comes from the person rather than
from a measurement of English. So at `choice_confirm_count = 2` it is placed —
behind the `exact` entry if there is one (layer 2), at slot 1 otherwise.

Only a **deliberate** pick is recorded. The space bar is not one: at speed
nobody reads the list, the space bar goes on muscle memory, and counting it
would teach the list to insist on its own first guess. A number key, or an arrow
key followed by Return, is aimed at a line and means what it says.

Nothing from a formula reaches the store at all — 310 of the 567 harvested maths
names are also ordinary English words.

**A suppression is a removal.** `- word` takes the word out of *your* dictionary
for **every input, not just the one in front of you**, before anything is ranked.
The literal is untouched, so nothing here can make a string untypeable.

---

## The forget key, and what it means

`Control+Shift+D`, `Shift+Delete`, or `qqd` on the highlighted candidate. With
nothing composing it forgets the word last committed. What it does depends on
what there is to forget:

| there is | the key means | scope |
| --- | --- | --- |
| a count, or a confirmed choice | **undo** — the entry goes, ranking reverts to what the dictionary says | that word |
| nothing personal, and it is a dictionary word | **this is not a word I write** — it leaves your dictionary | every input |

The second is the one to be careful with. It is right for `cant`, `wont` and
`hae` — words you are never reaching for — and wrong for a word you do write:
forget `want` to get it out of the way of `wont`, and `wnt` stops offering it
too. Committing the word once brings it back.

There is no scoring answer to this. `hae` is Scots for *have* and is in the
dictionary because English corpora contain it; `aback`, `abut` and `agog` sit in
exactly the same place — a rare word with a much commoner near neighbour — and
every one of them must keep winning when it is typed. Which of the two a given
word is depends on who is typing, so it is answered by the person typing, one
keystroke at a time.

### The apostrophe reading inherits the guard

Take `cant` out of your dictionary and what is left is `can't`. It would
otherwise lead as the best thing that survived — a repair, charged the cost of
an apostrophe. It is not a repair. With the bare spelling gone there is exactly
one word those letters spell, and the apostrophe is punctuation you cannot type
without ending the composition. So it is marked as the exact reading and takes
what one has: `hold_exact` keeps familiarity off it, and a confirmed correction
for some *other* word goes behind it rather than on top.

```
wont → won't[exact]    cant → can't[exact]    hes → he's[exact]
ill  → I'll[exact]     lets → let's[exact]    whats → what's[exact]
```

Keyed on the suppression, not on the shape of the word — so it says nothing
about `its`, `were` or `windows` while those are still yours.

---

## Layers 1 and 5: the ends of the list

**A shortcut goes to slot 1.** `spellless_shortcuts.txt` is the one place in the
matcher with no guessing to do: they said what they meant.

**The literal sits at `raw_candidate_index`** — slot 7, the last of the first
page — so the keystroke that commits it is predictable. *Unless nothing found is
trustworthy*, in which case it leads. `Engine:trustworthy` is: cost ≤ 1.50, score
≥ 62, and either an exact dictionary hit, or not all-capitals and at least three
characters. Before those rules existed an audit found `x → xxx`, `cm → come` and
`CW → COW` sitting under the space bar — the one failure mode that corrupts a
document silently. When the literal leads, the space bar asks twice.

Two more placements sit between: a **coinage** (`resmplng` → resampling) at
`min(#out+1, limit)`, and a **word split** (`exactlyright` → exactly right)
last among the real answers, below the literal's own reasoning so that
`spellless` is not overtaken by `spell less`.

---

## Worked examples

`lua bench/try.lua --debug <input>` prints the source label in brackets, which
names the mechanism that placed each candidate. Two columns, because half the
point is what the personal store changes and what it does not — the left is an
empty store, the right is one real store after a year of typing:

| you type | empty store | a real store | what decided the second column |
| --- | --- | --- | --- |
| `start` | `start`[exact] | `start`[exact] | **2** — the guard. `started` is confirmed twice and sits behind it |
| `its` | `its`[exact] | `its`[chosen] | **3** agreeing with **2** — the confirmed reading *is* the query's own, so it takes slot 1 as itself |
| `ok` | `ok`[exact] | `OK`[chosen] | **3** — a taught capital is the same word, not a rival, so it keeps slot 1 |
| `dont` | `don't`[exact] | `don't`[chosen] | **2** would have done it alone: the exact hit *is* the contraction |
| `cant` | `cant`[exact] | `can't`[chosen] | the **forget key** — `cant` was put aside, after which `can't` is the exact reading |
| `nbhood` | `neighborhood`[cue] | `neighbourhood`[chosen] | **3** — not a word, so the confirmed correction leads, spelling and all |
| `taht` | `that`[typo] | `that`[chosen] | **4** already had it right; **3** only makes it certain |
| `mthmtcs` | `mathematics`[cue] | `mathematics`[cue] | **4** — score alone, nothing personal involved |
| `kubectl` | `kubectl`[raw] | `kubectl`[raw] | **5** — nothing found is trustworthy, so the literal leads |

The `start` row is the whole document in one line: an exact hit at 106.3 keeps
its place against a correction confirmed twice, and the correction is still one
keystroke away.

---

## Where this is weak

Honestly stated in [ALGORITHM.md](ALGORITHM.md) §8.2 and
[PIPELINE.md](PIPELINE.md) §G.1, and not repeated here except for the headline:
**the scoring function is linear, hand-designed, and fitted on the set it is
scored on.** The bases and weights came from coordinate descent over
`tests/cases/*.tsv`, and the in-sample benchmark draws from the same generator.
**The number to quote is 89.8% ± 0.6 top-1 held out, 99.3% ± 0.2 top-5** — ten
fresh seeds the tuning never saw; see EVALUATION.md. The in-sample total reads
about a point and a half higher and is not the number worth believing.

The placements are not fitted at all. They are arguments, and every one of them
is written down beside the code that implements it — which is the only defence a
hand-designed rule has.
