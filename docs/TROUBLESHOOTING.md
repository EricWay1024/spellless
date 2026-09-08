# When something is wrong

Symptoms, most common first. [INSTALL.md](INSTALL.md) is how to install it;
[DEPLOYING.md](DEPLOYING.md) is the same ground from the build side, for
anyone working on Spellless itself.

**Start here.** Type `zzver` in any text box. If it prints five lines, the
schema is running and you know which build:

```
zzver  →  spellless 0.1.5 installed 2026-09-07 01:12
          83414 words, 809 forms, 3 shortcuts
          cue 70/9.0, slip 10.0, learn on
          reclaim on, absorb on, word-backspace on
          app com.apple.Notes, document readable, edits allowed
```

If it prints nothing, Spellless is not the schema serving your keystrokes —
which is the first three answers below. If it prints an older build than the
one you just installed, you are testing something else; see *changes have no
effect*.

---

## Spellless is not in the <kbd>F4</kbd> menu

The schema was installed but not enabled, or the frontend has not read it yet.

1. **Redeploy.** The Weasel tray icon → **Deploy** (「重新部署」), the Squirrel
   menu-bar icon → **Deploy**, `ibus restart`, or `fcitx5-remote -r`. Copying
   files updates the disk; only a redeploy makes the running process read them.
2. **Check it is enabled.** `default.custom.yaml` in your Rime user directory
   should contain a `"schema_list/+"` entry naming `spellless`. If the
   installer found an existing `schema_list` patch it will have printed what to
   add rather than guessing.
3. **Check it installed where the frontend looks.** `python3
   scripts/install.py --list-candidates` prints every directory it considered
   and why.

## `zzver` prints nothing, and no candidates ever appear

The schema is selected but produces nothing at all, which is what a Lua error
at load looks like from the outside.

* **On Linux, check librime-lua.** The distribution builds librime itself and
  packages the Lua plugin separately. `fcitx5-rime` and `ibus-rime` normally
  pull it in; if yours did not, nothing in Spellless can run. This is the first
  thing to check on Linux and never the problem on Windows or macOS, where the
  official builds bundle it.
* **Read the log.** `<rime user dir>/rime.log`, or the newest `rime.*.log`
  beside it — on Windows usually `%APPDATA%\Rime\rime.log`. Grep for
  `spellless`. A Lua error names the file and the line.
* **A stale or half-copied `generated/`.** Reinstall; the installer refuses to
  copy a build whose parts disagree, and the loader refuses to load half of one.

## Changes have no effect

You deployed, and the behaviour is the old behaviour. Compare the revision
`zzver` reports against the one you installed. If they differ:

* **The redeploy did not run**, or ran for a different frontend.
* **On Windows there may be two frontends.** Stock Weasel keeps its user
  directory at `%APPDATA%\Rime`; the Spellless fork keeps its own at
  `%APPDATA%\Spellless`, and each needs its own redeploy. `install.py` writes
  into every directory it finds precisely so the two cannot drift apart, and
  prints them. This has cost a working session before now.

**Do not delete `build/`** to force a rebuild. While that directory is missing,
Rime falls back to the schema list the frontend ships with and asks you to pick
a schema on every deploy. `install.py` marks the build stale instead.

## A space in front of the punctuation — `you . `

You committed the word first (with the space bar or a number key) and typed the
punctuation afterwards, so the word's trailing space was already in the
document. On the Spellless frontends punctuation takes that space back. On a
stock Weasel, Squirrel or Linux frontend it cannot, and the fix is
`leading_space` — [INSTALL.md step 4](INSTALL.md#step-4--stock-rime-only-turn-on-leading_space).

Typing the punctuation while the word is still being composed — the normal way
— is right either way.

## A stray space or capital somewhere else

On a stock frontend, spacing and capitals are inferred from what the input
method committed rather than from the document, so a mouse click that moved the
caret is invisible. Backspace re-syncs it. Either can be turned off:

```yaml
patch:
  spellless/auto_space: false
  spellless/auto_capitalize: false
```

## Punctuation, the caret, and word-backspace do nothing

Those four features need a frontend that can see and edit the document, and the
schema asks nothing of a frontend that has not shown it can answer. Line five of
`zzver` says whether *this* application is allowed them; line four says whether
they are switched on at all. Confusing the two has cost an evening.

* **On a stock Weasel or Squirrel** they are inert by design, whatever the
  configuration says. [INSTALL.md step 1](INSTALL.md#step-1--choose-your-frontend)
  has the frontends that carry them.
* **In VS Code and a few others** they are refused deliberately, because the
  editor and its integrated terminal are the same executable and the terminal
  cannot survive the edit. Press <kbd>F4</kbd> and turn on **edits document**
  while writing prose in one; it resets when you next deploy.
* **In a terminal** they will not work anywhere. A terminal has already
  forwarded what it was given.
* **On Linux** it is the *client* that has to offer surrounding text. GTK and
  Qt do, much of Chromium does not. Where a client will not answer you get
  stock behaviour, silently.

## A word I never type keeps winning

Some short, rare words are in the dictionary because English corpora contain
them, and typing one exactly is the strongest evidence the matcher has — `hae`
will beat `have` for ever if you let it.

Highlight it and press <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>D</kbd>. On a word
of your own that forgets it; on one of the dictionary's it means *never offer me
this one*, stored as a `- word` line in `spellless_user.txt`. The literal is
untouched, so nothing becomes untypeable, and committing the word again takes it
back.

## Edits to `spellless_user.txt` disappear

The running server owns that file and flushes its in-memory copy back over your
edit. Stop the frontend, edit, then start it again.
`spellless_shortcuts.txt` and `spellless_snippets.txt` are only ever read, so
those just need a redeploy.

## Still wrong

Turn on the candidate comments, which say where each candidate came from and
what it scored:

```yaml
patch:
  spellless/show_debug_comments: true
```

That plus the `zzver` output and the `rime.log` lines mentioning `spellless` is
what an [issue](https://github.com/EricWay1024/spellless/issues) needs.
