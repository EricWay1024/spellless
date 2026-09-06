# Writing maths: Spellless and an editor's snippets

Two systems have to agree for a maths paper to be typed this way. VS Code's
[HyperSnips](https://marketplace.visualstudio.com/items?itemName=draivin.hsnips)
expands `xdm` into a display-maths block the moment those letters appear in the
document. Spellless is what stops them appearing: `xdm` is a composition, the
candidate list offers words, and whichever key commits it adds a space — so the
editor sees `xdm ` if it sees anything, and by then the moment has passed.

So Spellless keeps a list of the editor's triggers and gives those letters
straight back. Typing one commits exactly those characters — no space, no
capital, no candidate list — and the expansion happens as though the letters
had been typed on a bare keyboard.

## The `x` convention

Every trigger begins with `x`, because no English word does. That is the whole
reason for the letter: a trigger is committed the instant it is complete, so it
has to be something the matcher would never mistake for the start of a word.
`dm` cannot be — it is two letters that could open plenty of words — and the
first time you meant one of them you would get a display-maths block instead.

The tails are the ones LaTeX taught: `mk` and `dm` for maths, and the
`b`-environments with their first letter swapped, so `blem` becomes `xlem`.

| trigger | expands to | keyboard afterwards |
| --- | --- | --- |
| `xmk` | `$…$` — inline maths | ASCII |
| `xdm` | `$ … $` — display maths | ASCII |
| `xthm` `xlem` `xpro` `xcor` | `#theorem[…]`, `#lemma[…]`, … | Spellless |
| `xdef` `xrmk` `xeg` `xobs` `xclm` `xpf` | `#definition[…]`, `#remark[…]`, … | Spellless |
| `xnthm` `xndef` | `#theorem("…")[…]`, named | Spellless |

**Maths hands the keyboard over; a theorem does not.** What follows `xdm` is
`\frac`, `sum` and `epsilon.alt`, where a matcher trained on English is in the
way, so ASCII mode goes on and every keystroke is yours. What follows `xthm` is
a sentence of English, which is the matcher's whole subject, so it stays on.
The trigger says which it is: the second column of the list is `ascii` or
nothing.

Coming back out of maths is deliberate — tap <kbd>Shift</kbd>, or type the
closing `$`, which Spellless takes as the end of the run it opened. The editor
decides when a snippet is finished and does not tell us, so guessing would be
worse than asking.

## The two halves, and keeping them in step

| | where | what it holds |
| --- | --- | --- |
| the expansion | `%APPDATA%\Code\User\hsnips\typst.hsnips` | what `xdm` turns into |
| the letters | `%APPDATA%\Spellless\spellless_snippets.txt` | which letters to commit, and whether maths follows |

Adding a trigger means adding it in both. The Spellless list is plain text:

```
# trigger   ascii?   note
xdm         ascii    display maths
xthm                 theorem
```

`#` starts a comment, the first field is the trigger, an `ascii` in the second
asks for ASCII mode, and anything after that is a note. Triggers are matched
exactly and case-sensitively against the *whole* composition: `xdm` fires,
`xdmn` does not, and neither does an `xdm` inside a longer word — which is
HyperSnips' own word-boundary rule, arrived at from the other side. Redeploy
after editing; the list is read once, like the shortcuts file.

## Only where each one makes sense

| | default | asks |
| --- | --- | --- |
| `spellless/snippet_apps` | `code.exe` | where does something expand a trigger? |
| `spellless/delimiter_apps` | `code.exe,typora.exe` | where is a `$` maths? |

Two questions with two answers. A trigger is meaningless where nothing expands
it — in an application with no snippet engine, `xdm` would commit two-and-a-bit
letters of nonsense and turn the matcher off. A `$`, meanwhile, is still maths
in Typora, which has no snippet engine at all; and it is still a price in a
chat window, where the automatic switch would be a trap you have to tap Shift
to get out of. An empty list means everywhere.

Both directions of the `$` are gated together, which matters more than it
sounds: gating only the way back would leave a chat window one keystroke from
ASCII mode and no keystroke back out.

VS Code is `code.exe` for its editor and its integrated terminal alike, and the
terminal is unaffected: ASCII mode is already on there, and a `$` in ASCII mode
that Spellless did not open is an ordinary dollar sign, so `$PATH` still works.

## Where the maths-mode snippets went

Nowhere. `sr`, `tp`, `pp`, `lim`, `veps` and the regex ones in `typst.hsnips`
are marked `m` — HyperSnips only fires them inside maths, which is where ASCII
mode already is. Spellless never sees those keystrokes and needs to know
nothing about them.

## Typst, not LaTeX

The expansions are Typst and follow the `ctheorems` conventions the notes
already use (`#theorem[…]`, `#theorem("Sperner's Lemma")[…]`). The trigger
names are LaTeX's because that is what the fingers know; the bodies are what
the document needs.
