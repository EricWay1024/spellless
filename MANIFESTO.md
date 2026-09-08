# Why Spellless exists

Typing English on a desktop assumes you can spell. That assumption is wrong,
and it costs you something every minute you write.

## Two problems that are one problem

The first is that spelling fails at speed. Not from ignorance — you can produce
`bureaucracy` or `shenanigans` on demand — but because within any given minute
of real typing you permute letters, write `o` for `u`, or drop one entirely.

The second is that the words you most need are the longest. Writing
mathematics, or anything academic, means typing `diffeomorphism` and
`stratification` letter by letter, perhaps three times a line.

These look like different complaints. They are the same one: **what you typed
is an imperfect encoding of a word you already knew.** Once that is the
framing, one mechanism answers both.

## Why the existing tools do not

**Snippets** (`dffsm` → `diffeomorphism`) work, but you must decide in advance,
one word at a time, and remember which words you registered.

**Spell checkers** draw a red line under the mistake and stop. The correction
is usually the first item behind two clicks, which raises the obvious question
of why the machine will not simply apply what it already knows.

**Autocorrect** answers that question badly, by applying its guess without
asking. `I'm not ill` becomes `I'm not I'll`; `Tqft` becomes `Taft`. When it is
wrong you delete the word and type it again, sometimes to be mis-corrected
again, with no way to know how many rounds it will take.

The failure is structural. A machine that must pick unseen has to be timid: it
can risk an edit or two and no more, because every guess is applied silently.
Timidity is the correct policy for a system that does not show its work — and
it puts `mthmtcs` → `mathematics` permanently out of reach.

## Chinese input methods solved this decades ago

They had no choice. There are thousands of characters and no keyboard with
thousands of keys, so from day one the consensus was that **what you input is
not what you commit.** You type a pronunciation, the machine offers candidates,
you pick one. Hundreds of millions of people write this way every day.

What matters here is not the writing system. It is the habit the arrangement
produced: **nobody types the full spelling.** Full pinyin `zhongguo` gives
`中国`, but so does `zhguo`, and so does `zg`. You shorten as far as you guess
the list can still find it, glance, and pick — and the shortening is improvised
each time. The same person types `描述` as `msh` in one line and `mshu` in the
next, depending on how sure they feel.

| | English | 全拼, in full | 全拼, as people actually type it | 小鹤双拼 |
| --- | --- | --- | --- | --- |
| `描述` | `describe` (8) | `miaoshu` (7) | `msh` (3), `mshu` (4), `miaosh` (6) | `mnuu` (4) |
| `成功` | `successful` (10) | `chenggong` (9) | `cg` (2), `chg` (3) | `iggs` (4) |
| `理解` | `understanding` (13) | `lijie` (5) | `lj` (2), `lij` (3) | `lijp` (4) |

The last column is Xiaohe Shuangpin, which encodes every initial and every
final as a single letter — `zhong` is `vs`, `guo` is `go` — so any character is
exactly two keystrokes. It is a genuine gain bought with a genuine cost: a
mapping unrelated to how anything is spelled, learned up front, before it saves
you anything. Most people never learn one, and they do not need to. The
abbreviated column is already most of the benefit and costs nothing to start.

**Spellless is the abbreviated column, not the last one.** There is no scheme to
memorise and no official abbreviation for any word. You shorten as much as you
feel like, differently on different days — `satfcatn`, `stfcatn` and `strtfctn`
all reach `stratification` — and the machine ranks the candidates, shows you
the list, and learns the shortenings you keep choosing. That last part matters:
in an encoding scheme the abbreviation is fixed in advance and you adapt to it,
whereas here it is invented on the fly and the machine adapts to you.

English on a desktop never got any of this, because a full keyboard was taken
to mean you could spell perfectly and needed no help. That is simply not true.

## The arrangement

No spell check, no autocorrect, no snippets. Treat the input as a noisy signal,
infer the word, and **show a list**. Dropping letters, adding them and
permuting them are all the same operation to a decoder. The space bar takes the
first candidate. That is the whole interaction.

Formally, you intended $w$ and typed $q$, and the system inverts

$$P(w \mid q) \;\propto\; P(q \mid w) \cdot P(w),$$

with the prior $P(w)$ from corpus frequency and the channel $P(q \mid w)$
modelling the slips and abbreviations you actually make.
[docs/NOISY-CHANNEL.md](docs/NOISY-CHANNEL.md) states this properly;
[docs/ALGORITHM.md](docs/ALGORITHM.md) is the matcher in full.

## What showing the list buys

Ambition. Offering `mathematics` for `mthmtcs` means allowing a distance at
which half the dictionary is reachable — unthinkable if a machine must choose
unseen, and perfectly safe here, because the answer is one of seven on the
page, because what you typed is always among them, and because <kbd>Enter</kbd>
commits it verbatim. `kubectl`, `argmax` and a name it has never met are left
alone.

It also changes what the tool is *for*. Several times an hour you know you
cannot spell a word **and you know that you know**: `bureaucratic`, `liaison`,
`diffeomorphism`. Autocorrect cannot help, because you have not written
anything yet for it to fix — so you break off to look it up, or settle for a
duller word you can spell. Type the consonants instead and the word is in front
of you.

That costs a beat the first time and then compounds. You build muscle memory
for the shorthand exactly as you once built it for the spelling, until the
vocabulary you can spell and the vocabulary you can *write* begin to converge.
The second is much larger.

## Principles

**You stay in control.** Spellless never rewrites what you wrote: it offers,
you pick. <kbd>Enter</kbd> commits exactly what you typed, and the literal
input is always on the first page — which is the only reason the matching can
afford to be this aggressive.

**It should know when not to interfere.** Short input and notation commit as
themselves (`x`, `cm`, `PDE`, `4D`); a caret inside a word means plain typing;
a word it cannot vouch for asks before it goes in. Being wrong quietly is worse
than being absent.

**Your habits beat the corpus.** English frequency is a prior, not a verdict.
Anything you choose twice overrules it.

## The hard part is not the algorithm

Algorithm design is the part a competent model will now do for you. The
difficulty is getting every small interaction right, because an input method is
repeated thousands of times a day and any friction works directly against
muscle memory.

The space is the standing example. The obvious implementation puts the space
*before* each word, which is wrong: if you press space to select a candidate,
you expect the space to land after it. But a trailing space must be removable
again the moment you type punctuation — and stock Weasel cannot take back a
character it has already committed. The correct answer was not to accept the
leading space. It was to fork the frontend so that it can reach back into the
document, which is what
[spellless-weasel](https://github.com/EricWay1024/spellless-weasel),
[spellless-squirrel](https://github.com/EricWay1024/spellless-squirrel) and
[spellless-fcitx5](https://github.com/EricWay1024/spellless-fcitx5) exist to
do. Apostrophes, possessives, capitalisation, re-editing a committed word, and
`Hong Kong` counting as one word are all the same kind of work.

Where the frontend will not cooperate,
[`leading_space`](docs/INSTALL.md#leading_space-and-what-it-trades) is the
fallback, and it is off by default.

## What this is not

*Stop spelling. Start writing.* is a slogan, and it is too grand: you still
need a vague idea of what the word looks like before any of this works for you.

The honest formulation is that **writing should happen on the quotient space
modulo whatever the machine can safely infer.** Everything here is an argument
about where to put that "safely".
