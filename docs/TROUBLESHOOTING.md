# When something is wrong

Symptoms, most common first. [INSTALL.md](INSTALL.md) is how to install it;
[DEPLOYING.md](DEPLOYING.md) is the same ground from the build side, for
anyone working on Spellless itself.

**Start here.** Type `zzver` in any text box. If five lines come back,
Spellless is running and you know which version:

```
zzver  →  spellless 0.1.5 installed 2026-09-07 01:12
          83414 words, 809 forms, 3 shortcuts
          cue 70/9.0, slip 10.0, learn on
          reclaim on, absorb on, word-backspace on
          app com.apple.Notes, document readable, edits allowed
```

If nothing comes back, Spellless is not what is serving your keystrokes — which
is the first two answers below. If the version is older than the one you just
installed, you are testing something else; see *changes have no effect*.

---

## Spellless is not in the list when I press <kbd>F4</kbd>

The files are installed, but Rime has not been told to offer them, or has not
looked since.

1. **Deploy.** Right-click the tray icon → **Deploy** (「重新部署」) on
   Windows, the menu-bar icon → **Deploy** on macOS, `ibus restart` or
   `fcitx5-remote -r` on Linux. Copying files updates the disk; only a Deploy
   makes the running program read them.
2. **Check it was switched on.** `default.custom.yaml`, in Rime's settings
   folder, should have an entry naming `spellless`. If the installer found one
   there already it will have printed what to add by hand rather than guessing.
3. **Check it went where Rime is looking.** `python3 scripts/install.py
   --list-candidates` prints every folder it considered, and why.

## `zzver` prints nothing, and no words are ever offered

Spellless is selected but produces nothing at all — which is what a crash while
loading looks like from the outside.

* **On Linux, check the Lua plug-in.** Spellless is written in Lua, and on
  Linux the plug-in that lets Rime run Lua is packaged separately from Rime
  itself. `ibus-rime` and `fcitx5-rime` normally pull it in; if yours did not,
  nothing in Spellless can run. This is never the problem on Windows or macOS,
  where the official builds always include it.
* **Read the log.** `rime.log`, or the newest `rime.*.log` beside it, in Rime's
  settings folder — on Windows usually `%APPDATA%\Rime\rime.log`. Search it for
  `spellless`. An error names the file and the line.
* **A half-copied install.** Run the installer again; it refuses to copy a
  half-built dictionary, and Rime refuses to load one.

## Changes have no effect

You installed, you deployed, and the behaviour is the old behaviour. Compare
the version `zzver` reports against the one you installed. If they differ:

* **The Deploy did not run**, or ran for a different copy of Rime.
* **On Windows there may be two.** The standard Weasel keeps its settings in
  `%APPDATA%\Rime`; our build keeps its own in `%APPDATA%\Spellless`, and each
  needs its own Deploy. The installer writes into every folder it finds
  precisely so the two cannot drift apart, and prints them. This has cost a
  working session before now.

**Do not delete the `build/` folder** to force a rebuild. While it is missing,
Rime falls back to the list it shipped with and asks you to choose an input
style on every Deploy. The installer marks that folder stale instead.

## A space in front of the punctuation — `you . `

You finished the word first (with the space bar or a number key) and typed the
punctuation afterwards, so the word's trailing space was already in the
document. Our build of Rime takes that space back. The standard build cannot,
and the fix is one setting —
[`leading_space`](INSTALL.md#leading_space-and-what-it-trades).

Typing the punctuation while the word is still underlined — the normal way —
is right either way.

## A stray space or capital somewhere else

On the standard Rime, Spellless can see what it typed but not the document it
typed into, so it infers where it is — and a click that moves the cursor is
invisible to it. Backspace re-syncs it. Either can be turned off, in
`spellless.custom.yaml`:

```yaml
patch:
  spellless/auto_space: false
  spellless/auto_capitalize: false
```

## The four extra features do nothing

Punctuation tidying up its space, typing in the middle of a word, picking a
re-typed word up, and word-backspace all need Rime to be able to read and edit
the text around your cursor — and Spellless asks for none of it until Rime has
shown it can answer. Line five of `zzver` says whether *this* program is
allowed them; line four says whether they are switched on at all. Confusing the
two has cost an evening.

* **On the standard Weasel or Squirrel** they do nothing by design, whatever
  the settings say. [INSTALL.md](INSTALL.md#install-our-build-of-rime) has our
  builds, and why they are the recommended way in.
* **In VS Code and a few others** they are refused deliberately: the editor and
  its built-in terminal are the same program, and the terminal cannot survive
  the edit. Press <kbd>F4</kbd> and turn on **edits document** while writing
  prose in one; it resets at the next Deploy.
* **In a terminal** they will not work anywhere. A terminal has already passed
  on what it was given.
* **On Linux** it is the *program you are typing into* that has to answer. GTK
  and Qt programs do, much of Chromium does not.

## A word I never type keeps winning

Some short, rare words are in the dictionary because English books contain
them, and typing one exactly is the strongest evidence there is — `hae` will
beat `have` for ever if you let it.

Highlight it and press <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>D</kbd>. On a word
of your own that forgets it; on one from the dictionary it means *never offer
me this one*, stored as a `- word` line in `spellless_user.txt`. What you
literally typed is untouched, so nothing becomes untypeable, and typing the
word again takes it back.

## Edits to `spellless_user.txt` disappear

Rime owns that file while it is running, and writes its own copy back over your
edit. Quit it, edit, start it again. `spellless_shortcuts.txt` and
`spellless_snippets.txt` are only ever read, so those just need a Deploy.

## Still wrong

Turn on the notes beside each word, which say where it came from and what it
scored:

```yaml
patch:
  spellless/show_debug_comments: true
```

That, the `zzver` output, and the lines mentioning `spellless` in `rime.log`
are what an [issue](https://github.com/EricWay1024/spellless/issues) needs.
