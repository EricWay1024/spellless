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
| the expansion | the editor's `hsnips/typst.hsnips` | what `xdm` turns into |
| the letters | the Rime user directory's `spellless_snippets.txt` | which letters to commit, and whether maths follows |

**Find the first one with the editor, not from memory.** HyperSnips has a
command — <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>P</kbd>, "HyperSnips: Open
snippet file" — and it opens the copy that is actually being read, which is the
only one that matters. VS Code has more than one user directory and which it
uses depends on how it was started: `%APPDATA%\Code\User` on Windows,
`~/.config/Code/User` on Linux, and a remote window reads the remote side's.
Editing the wrong one is silent — the snippets simply never fire — and it cost
a whole round of "why is nothing expanding" here. If you keep two, make one a
symlink to the other rather than two files.

**Keep the files LF.** HyperSnips compiles each one into a single JavaScript
function, emitting every body line as `_result.push("…")`. A carriage return
that survives the line split lands inside that string literal, where it is a
line terminator, so the string never closes and the parse dies at the next
thing it sees — `missing ) after argument list`, naming no file and no line.
Current HyperSnips splits on `/\r?\n/` and is immune; a file that has been
through a Windows editor and an older extension build is not. A
`.gitattributes` with `*.hsnips text eol=lf` settles it.

Adding a *prose* trigger means adding it in both. A maths-mode snippet — `m`
in its HyperSnips flags, firing only inside `$…$` — belongs in the editor's
file alone: Spellless is not composing there, so there is nothing for it to
hand over. The Spellless list is plain text:

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

## Why the last letter is not committed with the rest

A trigger is committed as `xth` plus a *rejected* `m`, and that asymmetry is
the whole reason any of this works.

HyperSnips expands an automatic snippet from a document-change event, and drops
anything that does not look like typing:

```js
// Let's try to detect only events that come from keystrokes.
if (mainChange.text.length != 1) return;
```

An input method's commit is one four-character change, so `xthm` landed in the
document and expanded nothing — while the same letters in ASCII mode, arriving
as four separate keystrokes, expanded fine.

**Committing the letters one at a time does not fix it**, and that is worth
knowing because it is the obvious first idea. librime concatenates every commit
of a single keystroke into one string — `commit_text_ += commit_text` in
`service.cc` — which the frontend reads once. Four calls and one call reach the
document identically.

What the guard actually inspects is only the change that just arrived; how the
text in front of it got there is not its business. So the prefix is committed
and the final key returns `kRejected`, which librime defines as *"do the OS
default processing"* — the key reaches the application as itself, one character
long, with the whole trigger behind it. That is the same thing ASCII mode was
doing, arranged deliberately.

The cost is one keystroke's worth of asymmetry in `handover.func`, and the
alternative was dropping the `A` flag and confirming every trigger from the
suggest widget.

---

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

Nowhere. `sr`, `tp`, `pp`, `lim`, `veps`, `xx`, `inn`, `iso` and the regex ones
in `typst.hsnips` are marked `m` — HyperSnips only fires them inside maths,
which is where ASCII mode already is. Spellless never sees those keystrokes and
needs to know nothing about them.

That flag is also the test for whether a snippet has to be renamed. `dm` had to
become `xdm` because it fires in prose, where Spellless is composing and `dm`
is two letters of a word; `xx` did not, because it only ever fires between
dollar signs. When a trigger stops working under Spellless, look at its flags
first.

## Typst, not LaTeX

The expansions are Typst and follow the `ctheorems` conventions the notes
already use (`#theorem[…]`, `#theorem("Sperner's Lemma")[…]`). The trigger
names are LaTeX's because that is what the fingers know; the bodies are what
the document needs.
