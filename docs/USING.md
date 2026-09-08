# Using Spellless

Everything Spellless does once it is installed: what it will decode, which
keys do what, and how it learns your own words.

[INSTALL.md](INSTALL.md) is how to get it running.
[../DESIGN.md](../DESIGN.md) and [ALGORITHM.md](ALGORITHM.md) are why any of
it works.

---

## Everything it does

**Finding the word**

| | |
| --- | --- |
| Drop the vowels | `mthmtcs` → mathematics, `dffmrphsm` → diffeomorphism |
| Mistype it | `recieve` → receive, `teh` → the — transposed, wrong, missing or extra letters |
| Finish it for you | `neighbo` → neighbourhood |
| Syllabic shorthand | `satfcatn` → stratification, `alghrith` → algorithm even with a slip in it |
| Words run together | `exactlyright` → exactly right, any number of them |
| Words built out of parts | `resampling`, `matrixwise` — coined, not looked up |
| Possessives | `mther's` → mother's, `mthers'` → mothers', and the ending follows the word |
| Dropped apostrophes | `dont` → don't, `im` → I'm, `ive` → I've |
| Abbreviations without dots | `eg` → e.g., committed whole so it does not end a sentence |
| Your own shorthand | `sth` → something, and a file for your own habits |

**Capitals, which nobody should have to think about**

| | |
| --- | --- |
| Sentences start with one | but `MATHE` and `kubectl` are left alone |
| Both spellings of a word that has two | `ram`/`RAM`, `react`/`React`, `latex`/`LaTeX` — one keystroke apart |
| Spellings that resist it | `iPhone` starts a sentence as `iPhone`, never `IPhone` |
| Spellings you teach it | `LaTeX`, `arXiv`, `PyTorch`, `McDonald's` — kept, and reachable from any shorthand |
| A capital you chose twice | becomes the default, and picking the lowercase twice undoes it |

**Reading the sentence you are in**

| | |
| --- | --- |
| After a modal, the bare verb | `would rlt` prefers relate over related — but `rlted` still gives related |
| Through adverbs and adjuncts | `would not`, `may in fact`, `can thus to some extent` |
| After an infinitive `to` | `want to`, `in order to` — but not `isomorphic to` |
| A letter against a digit is notation | `4D`, `3D`, `4th`, `5km` commit as themselves |
| Punctuation knows what it follows | `$x$` closes, `don't` does not open a quote, `e.g.` is not a full stop |

**Learning**

| | |
| --- | --- |
| A word you commit once | is a candidate from then on, capitals and all |
| A correction you make twice | leads the list, and only deliberate choices count |
| <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>D</kbd> | forgets anything learned by accident |
| No size limit | your list is searched by exactly the machinery that searches the dictionary |

**Typing, not just matching**

| | |
| --- | --- |
| The space rides on the word | never in front of it, and punctuation takes it back |
| <kbd>Enter</kbd> commits what you typed | <kbd>Shift</kbd>+<kbd>Enter</kbd> commits and adds the newline |
| Space bar asks before a misspelling | double-tap to insist |
| A caret inside a word | means plain typing until the next space — `4D`, `p.m.` |
| <kbd>Backspace</kbd> twice | deletes the whole word, not one letter (<kbd>F4</kbd>) |
| `qq` mid-word is a command | `qqc` capitals, `qqf` first letter, `qql` lower case, `qqd` forget |
| Editor snippets | `xthm` expands in VS Code, through your own snippet file |
| Tapping Shift gets out of the way | and `$` does it by itself, for maths |

**Vocabulary**

| | |
| --- | --- |
| 83,414 words | plus technology, the 2020s internet, contractions, interjections, names |
| Eight importable packs | algebra, topology, software, philosophy, culture, europe, china, britain |
| Your own list | plain text, hand-editable, never overwritten by an upgrade |

Four of the rows above — punctuation taking its space back, the caret inside a
word, picking a word up out of the line, and word-backspace — need a frontend
that can edit the document. [INSTALL.md](INSTALL.md#step-1--choose-your-frontend)
says which frontends those are.

---

## The few that need more than a line

**Shorthand can be as rough as you like.** The matcher prices the letters you
*left out* rather than demanding the ones you kept: a vowel costs almost
nothing to skip, a consonant next to another consonant a little, and a
consonant that begins a syllable rather more. That is the entire model — no
pronunciation dictionary, no syllabifier, nothing to memorise. It works on your
own words too, so `gthndck` still finds `Grothendieck`.

```
stratification  ←  strtfctn  satfcatn  stfcatn
government      ←  gvrnmnt   gvmnt     govmnt
cohomology      ←  chmlgy    cohmlgy   chmolgy
```

**Words you coin get built.** `re-`, `non-`, `pseudo-`, `over-`, `-wise`,
`-less` and two dozen more attach to any word, so no dictionary can hold the
results. When nothing ordinary fits, the affix comes off, the rest is matched
on its own, and the word is put back together — and the affix is recognised by
its consonants too, because someone who writes `smplng` writes `nn` for `non`.
The dictionary settles it first, which is what keeps `reading`, `region`,
`nonsense` and `coder` whole. Hyphenated compounds need none of this: type
`catch-me-if-you-can` straight through and the hyphens close up on their own.

```
resmplng    →  resampling        nnfnctr     →  nonfunctor
qscohrnt    →  quasicoherent     mtrxws      →  matrixwise
```

**Where English requires a bare verb, the list prefers one.** `would rlt` puts
`relate` ahead of `related`, because there is no "would related". The trigger
is a closed class and nothing else in the sentence is looked at: the nine
modals and their negations (`would could should must may might shall will
can`, `wouldn't`, `won't`, `can't`, `cannot`), with any adverbs in between; and
`to` when the word in front of it makes it an infinitive — `want to`, `in order
to`, `able to` — but not when it is a preposition, which is what `to` mostly is
in mathematics: `isomorphic to`, `due to`, `restricts to`. `would be related`
and `would have related` are good English and are never touched, because `be`
and `have` end the chain. And if you did mean the past tense, type its `d`:
`rlted` still gives `related`, so the rule only acts where your input said
nothing either way. Nothing is removed and nothing moves off the first page.

**Words run together come apart**, any number of them, because cutting a string
into dictionary words is a word-break search — and each part keeps its own
spelling, hence the capital `I` in `iamgoingtoschool` → `I am going to school`.
A split is placed rather than ranked: last among the real candidates, so it can
neither displace a correction nor be crowded out by a mediocre one. A word is
never split, so `another` stays `another`, and `spellless` and `argmax` keep
the first slot.

**Both spellings of a word that has two.** `ram` gives you the animal with
`RAM` behind it; `RAM` gives you the acronym. Same for `react`/`React`,
`windows`/`Windows`, `python`/`Python`, `cd`/`CD`, `latex`/`LaTeX` — one
keystroke apart, ordered by what you typed, and typing `LaTeX` exactly leads
with `LaTeX`, which is the only way to ask for a spelling that is neither title
nor upper case. Nothing is taken away to gain an acronym, and a spelling you
teach it never costs you the dictionary's.

**Short or notational input leads with itself.** `x`, `cm`, `ms`, `PDE`,
`TQFT` commit as themselves, because one or two characters are variables and
units far more often than the start of a longer word, and an acronym typed in
capitals is deliberate. A letter hard against a digit is notation, so `4D`,
`3D`, `4th`, `5km`, `L2` go straight in — without this `4D` gives you `4Do`.
A space turns it back off: `in 4 days` is ordinary text. snake_case identifiers
(`foo_bar`, `max_iter2`) are taken literally as soon as the underscore appears.

**The literal text you typed is always on the first page** — in slot 7 by
default, or first when nothing plausible was found — so pressing space on
`kubectl` or `argmax` cannot turn it into an English word.

---

## Keys

| Key | |
| --- | --- |
| <kbd>1</kbd>…<kbd>7</kbd> | select a candidate |
| <kbd>Space</kbd> | commit the highlighted candidate — twice, if it is a word the dictionary does not have |
| <kbd>Enter</kbd> | **commit exactly what you typed**, at once, with the automatic space after it |
| <kbd>↑</kbd> / <kbd>↓</kbd> | move the highlight — <kbd>Enter</kbd> then commits *that* candidate |
| <kbd>Esc</kbd> | cancel the composition |
| <kbd>PgUp</kbd> / <kbd>PgDn</kbd> | page through candidates |
| <kbd>Shift</kbd> (tapped on its own) | leave Spellless and type straight through; tap again to come back |
| <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>A</kbd> | the same, deliberately — also commits the word first |
| <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>D</kbd> or <kbd>Shift</kbd>+<kbd>Del</kbd> | forget the highlighted candidate |
| <kbd>F4</kbd> | schema menu |

Punctuation keys are punctuation: `,` `.` `-` `=` type themselves, where Rime's
preset would page.

**`qq` mid-word, then a key, is an instruction.** Capitalisation is otherwise
inferred — from what you typed, from whether a sentence just ended, from what
you have chosen before — and inference is right most of the time and
unarguable-with when it is not. This is the argument:

| | |
| --- | --- |
| `wndows` `qqf` | **W**indows — the first letter, for a name the dictionary reads as an ordinary word |
| `api` `qqc` | API — all caps, for an acronym |
| `but` `qql` | but — lower case, defeating an automatic sentence capital |
| `qqd` | forget the highlighted candidate, as <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>D</kbd> does |

`qq` because no English word contains it. Arming costs nothing — the letters
stay in the composition until a key that *is* a command arrives, so `zzxxqq`
is still `zzxxqq`, and anything unrecognised is just text.

**Tap Shift to get out of the way.** It switches to plain typing, and tapping
it again switches back — the tray icon shows which mode you are in. Tapped
mid-word it first commits exactly what you had typed, so it doubles as the
escape hatch when a word is clearly not going to be found: `\citep{Hat02}` is a
Shift tap away, rather than something the matcher has to be taught. It is safe
while typing capitals, because librime only toggles on a *bare*
press-and-release within 500 ms — <kbd>Shift</kbd>+<kbd>M</kbd> can never flip
the mode.

**Typing `$` gets out of the way on its own.** It writes the dollar and
switches to plain typing; the closing `$` writes itself and switches back, so
`$\frac{a}{b}$` goes in without a candidate list in front of it. Only the
delimiter that opened a run closes it, so a `$` in plain typing you reached by
tapping Shift is an ordinary dollar sign and `$PATH` in a terminal still works.
`spellless/ascii_delimiters` is the list, and `$` is all that is in it; it
works where maths gets written — VS Code and Typora — rather than in a chat
window where `$5` is a price.

**Editor snippets are handed back to the editor.** VS Code expands `xdm` into
a display-maths block the moment those letters land in the document, and under
an input method they never land — `xdm` is a composition, and whatever commits
it adds a space. So the triggers you list in `spellless_snippets.txt` commit
verbatim the instant they are complete, with no space and no capital, and the
ones that open maths hand the keyboard to plain typing as well. Every trigger
starts with `x` because no English word does. [SNIPPETS.md](SNIPPETS.md) has
the scheme and the two files it lives in.

---

## Your own vocabulary

**Learned as you go.** Every word you commit is counted in
`<rime user dir>/spellless_user.txt`, and words you pick often rise. A word the
dictionary has never heard of becomes a candidate as soon as you commit it
once: press Enter on `Grothendieck` and afterwards `grthndck` gives it back,
capitals and all; commit `pytest` once and `pytst` finds it thereafter. *How*
you write a word is stored only when the dictionary cannot already explain it,
so a capital that came from the start of a sentence is never mistaken for a
preference — and committing the plain lowercase form takes a stored spelling
back. Your personal list has no size limit and is searched by exactly the
machinery that searches the dictionary.

**A correction you make twice is a correction you meant.** Pick the same
candidate for the same input a second time and it leads that input from then
on — placed rather than scored, so English frequency cannot argue with it. Once
is not enough on purpose: a good deal of what anyone picks is picked once by
accident.

```
cli   →  click  client  clip  clips ...      before
cli   →  CLI    click   client  clip         after picking CLI twice
```

Only a **number key** counts, because at speed the space bar takes whatever is
first and counting it would teach the list to insist on its own guess.
<kbd>Enter</kbd> commits exactly what you typed, which is a refusal to choose
rather than a choice, so it teaches nothing either.

**A capital you type yourself is learned the same way.** `Windows` is the case
the dictionary cannot settle — the lowercase word is ordinary English, so a
capital on it is usually just the start of a sentence. Pick it deliberately
twice and it is offered beside the plain word from then on, reachable from a
misspelling too. Both readings, always, because you still have to be able to
open a window. A capital that came from the start of a sentence stays
unlearned — that one is ours, not yours.

```
windows  →  Windows · windows · window …
wndows   →  windows · Windows · window …
window   →  window · windows · Windows …
```

That file is plain text and safe to edit by hand. A one-column entry written
with capitals is its own spelling, so `Hausdorff` needs no second column:

```
# word <TAB> count
# word <TAB> how you write it <TAB> count
# > what you typed <TAB> what you chose <TAB> count
perverse	5
grothendieck	Grothendieck	12
Hausdorff
```

**Abbreviations you decide on yourself** go in `spellless_shortcuts.txt`, in
the same directory. An exact match on the left puts the text on the right at
the top, ahead of everything the matcher inferred; the expansion is free text,
so several words are fine. Redeploy after editing.

```
bc      because
ppl     people
btw     by the way
```

You will need fewer of these than you expect: the matcher already rebuilds a
word from its consonants, so `ppl` would find `people` unaided. What a list is
for is the cases where the information is not in the input at all — `bc` is two
letters, and at two letters almost every word in the language is a plausible
completion. That is a habit, and a habit has to be written down.

**Vocabulary you can import.** Specialist word lists live in `data/packs/` and
are deliberately not shipped, because topology terminology is excellent if you
work on topology and clutter if you do not:

```bash
python3 scripts/import_pack.py --list
python3 scripts/import_pack.py topology algebra
```

| pack | entries | |
| --- | --- | --- |
| `algebra` | 151 | Algebra, arithmetic geometry, and writing mathematics |
| `britain` | 28 | British institutions, mostly acronyms |
| `china` | 42 | Chinese provinces, and words English borrowed |
| `culture` | 231 | Literature, film, art and music: the names people mention |
| `europe` | 136 | Travelling in Europe: airports by name, airlines, railways, cities, regions |
| `philosophy` | 216 | Philosophers, positions, and the terms of art |
| `software` | 176 | Computer science and software engineering, past what everyone needs |
| `topology` | 197 | Topology and geometric topology |

They merge into your own word list, never overwrite a count you have earned,
and a text file of your own words works just as well as a named pack. Each was
checked against the dictionary before being written: a candidate the dictionary
already spells correctly is left out. Where a name is also an ordinary word —
`Bloom`, `Lie`, `Mill`, `Stephen King` — it appears with enough of the name to
be unambiguous, so importing one never costs you the everyday word.

**For a larger, permanent vocabulary**, add a `.txt` file to `data/vocab/` and
run `make`. This puts the words in the main dictionary with a real corpus
frequency rather than in your personal history; an entry written with capitals
(`Grothendieck`, `TQFT`) is indexed lowercase and remembers its spelling, so
only write capitals where the lowercase form would be wrong. Shipped there:
`proper_nouns.txt` and `given_names.txt`, for words only ever written with a
capital — which is why `March`, `May`, `Polish`, `Bill` and `Grace` are
deliberately absent; `phrases.txt`, for groups that behave as one word
(`infrontof` → `in front of`, and `hngkng` finds `Hong Kong` too); and
`math_sample.txt`, around 300 words of mathematics as a sample.

[../data/README.md](../data/README.md) has the file formats and where the
corpus came from.
