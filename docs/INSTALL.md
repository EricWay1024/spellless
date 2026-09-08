# Installing Spellless

Spellless joins the list of input methods in your keyboard menu, the way a
Chinese or Japanese one does. You pick it once and it is there in every program
you type in.

Two pieces make that happen. One is [Rime](https://rime.im) — a free,
open-source input method, called **Weasel** on Windows, **Squirrel** on macOS,
and `ibus-rime` or `fcitx5-rime` on Linux — which is what actually puts an
entry in your keyboard menu. The other is Spellless itself: the word list and
the matching that decides what to offer you. Installing means getting both.

**Six routes**, because there are three systems and two builds of Rime to run
this on. Find yours in the table below and read that one section; each is
complete on its own.

When something does not work afterwards,
[TROUBLESHOOTING.md](TROUBLESHOOTING.md).

---

## Install our build of Rime

**Do this if you can.** We publish our own build of Rime for each system. It is
the ordinary program with four small additions, because there are four things
Spellless cannot do from inside an input method — once text has been sent to a
program, it belongs to that program, and only Rime itself is still holding on
to it:

| | the standard Rime | our build |
| --- | :---: | :---: |
| everything in [USING.md](USING.md) | ✓ | ✓ |
| punctuation tidies up the space in front of it — `you` <kbd>Space</kbd> `.` gives `you. `, not `you . ` | — | ✓ |
| typing in the middle of a word leaves that word alone — `4D`, `p.m.`, `v1.2` arrive as typed | — | ✓ |
| a word you go back and re-type is picked up — delete the space after `so`, type `oner`, get `sooner` | — | <kbd>F4</kbd> |
| <kbd>Backspace</kbd> twice deletes the whole word | — | <kbd>F4</kbd> |
| anything to set up | one line to add | nothing |

The first two are on. The last two change what a key you already know does, or
move text you can see, so they are opinions rather than corrections and you
switch them on yourself — all four are in the <kbd>F4</kbd> menu.

**What happens to the Rime you already have** depends on the system. On
**Windows**, nothing: ours installs *beside* it, with its own settings folder
and its own entry in your keyboard menu, so a Weasel you keep for another
language is untouched — and the installer writes Spellless into both, so
whichever you are typing in runs the same build. On **macOS**, ours goes in as
ordinary Squirrel and takes its place; it reads the same settings, so every
input method you already have keeps working, and macOS will ask you to log out
and back in. On **Linux** you build it yourself, and section 3 has what that
involves.

Windows is also the one where ours has Spellless already inside it, which makes
the whole install a single file and nothing else to run.

Each is licensed as the project it is built from — GPL-3.0 for Weasel and
Squirrel, GPL-2.0-or-later for `fcitx5-rime`; this repository is MIT. The
Windows and macOS builds are unsigned, as Squirrel's own releases are.

**Keeping the Rime you already have** costs you those four rows and nothing
else. Sections 4 to 6 are for that, and they work.

## Which section is yours

| | our build of Rime (recommended) | the Rime you already have |
| --- | --- | --- |
| **Windows** | [1. Windows, with our Weasel](#1-windows-with-our-weasel) | [4. Windows, on the standard Weasel](#4-windows-on-the-standard-weasel) |
| **macOS** | [2. macOS, with our Squirrel](#2-macos-with-our-squirrel) | [5. macOS, on the standard Squirrel](#5-macos-on-the-standard-squirrel) |
| **Linux** | [3. Linux, with our fcitx5-rime](#3-linux-with-our-fcitx5-rime) | [6. Linux, on ibus-rime or fcitx5-rime](#6-linux-on-ibus-rime-or-fcitx5-rime) |

Nothing here is ever compiled and no administrator rights are needed. Five of
the six need **Python 3.8+**, and only to run the installer.

---

## 1. Windows, with our Weasel

The shortest route there is: one file, which has Spellless inside it.

1. Download **`spellless-<version>-installer.exe`** from
   [Releases](https://github.com/EricWay1024/spellless/releases).
2. Run it. It is unsigned, so Windows will object — **More info** →
   **Run anyway**. It installs alongside any Weasel already on the machine.
3. Right-click the tray icon → **Deploy** (「重新部署」). That is Rime's word
   for "pick up what was just installed".
4. Press <kbd>F4</kbd>. That is Rime's list of what it can type; choose
   **Spellless**. The tray icon and the language-bar button turn into an **S**,
   and tapping Shift into plain typing brings back the **A**.
5. Type **`zzver`** in any text box. Five lines back means it is running.

Nothing to set up. If you also keep a standard Weasel for another language,
note that the two have separate settings folders —
[TROUBLESHOOTING.md](TROUBLESHOOTING.md#changes-have-no-effect) says what that
means when an update seems to do nothing.

## 2. macOS, with our Squirrel

Two files: our Squirrel does not carry Spellless inside it.

1. Download **`Spellless-Squirrel-<version>.pkg`** and
   **`spellless-<version>.zip`** from
   [Releases](https://github.com/EricWay1024/spellless/releases).
2. Install the `.pkg`. It is unsigned: right-click → **Open** the first time.
   It goes in as ordinary Squirrel, so it takes the place of a Squirrel you
   already have rather than sitting beside it. Everything you already type on
   Rime keeps working — it reads the same settings — and macOS will ask you to
   log out and back in.
3. Unzip the other file and run the installer inside it:

   ```bash
   python3 scripts/install.py
   ```

4. Menu-bar icon → **Deploy** — Rime's word for "pick up what was just
   installed".
5. Press <kbd>F4</kbd>. That is Rime's list of what it can type; choose
   **Spellless**.
6. Type **`zzver`** in any text box. Five lines back means it is running.

Nothing to set up.

## 3. Linux, with our fcitx5-rime

**Newer and rougher than the other two**, and the only one you have to build
yourself.

1. Check your fcitx5 is **≥ 5.1.22**. Ours tracks upstream `fcitx5-rime`, so
   Arch, Fedora 41+ and Tumbleweed are fine and Ubuntu 24.04 LTS is not.
2. Build and install
   [spellless-fcitx5](https://github.com/EricWay1024/spellless-fcitx5) from
   source — there are no packages yet.
3. Download **`spellless-<version>.zip`** from
   [Releases](https://github.com/EricWay1024/spellless/releases), unzip it, and
   run the installer inside it:

   ```bash
   python3 scripts/install.py
   ```

4. `fcitx5-remote -r`
5. Press <kbd>F4</kbd>. That is Rime's list of what it can type; choose
   **Spellless**.
6. Type **`zzver`** in any text box. Five lines back means it is running.

One caveat particular to Linux: those four extra features need the *program you
are typing into* to answer a question about the text around your cursor. GTK
and Qt programs do, much of Chromium does not, and no terminal does. Where a
program will not answer you quietly get the standard behaviour — the right
failure, but it does mean the four are not everywhere. Everything in
[USING.md](USING.md) works regardless.

## 4. Windows, on the standard Weasel

1. If you do not have Weasel, install it from [rime.im](https://rime.im).
2. Download **`spellless-<version>.zip`** from
   [Releases](https://github.com/EricWay1024/spellless/releases) and unzip it.
3. Run the installer inside it:

   ```powershell
   python scripts\install.py
   ```

   From WSL, `python3 scripts/install.py` finds the Windows side by itself.
4. Right-click the tray icon → **Deploy** (「重新部署」). That is Rime's word
   for "pick up what was just installed".
5. Press <kbd>F4</kbd>. That is Rime's list of what it can type; choose
   **Spellless**.
6. Type **`zzver`** in any text box. Five lines back means it is running.
7. **Add one setting.** The standard Weasel cannot take a character back once
   it has been typed, so punctuation after a word you have *already* finished
   leaves its space stranded — `you .` Create or edit
   `spellless.custom.yaml` in Rime's settings folder (`%APPDATA%\Rime`, unless
   you have moved it), put this in it, and Deploy again:

   ```yaml
   patch:
     spellless/leading_space: true
   ```

   [What it trades](#leading_space-and-what-it-trades) is one paragraph, below.

## 5. macOS, on the standard Squirrel

1. If you do not have Squirrel, install it from [rime.im](https://rime.im).
2. Download **`spellless-<version>.zip`** from
   [Releases](https://github.com/EricWay1024/spellless/releases) and unzip it.
3. Run the installer inside it:

   ```bash
   python3 scripts/install.py
   ```

4. Menu-bar icon → **Deploy** — Rime's word for "pick up what was just
   installed".
5. Press <kbd>F4</kbd>. That is Rime's list of what it can type; choose
   **Spellless**.
6. Type **`zzver`** in any text box. Five lines back means it is running.
7. **Add one setting.** The standard Squirrel cannot take a character back once
   it has been typed, so punctuation after a word you have *already* finished
   leaves its space stranded — `you .` Create or edit `spellless.custom.yaml`
   in `~/Library/Rime`, put this in it, and Deploy again:

   ```yaml
   patch:
     spellless/leading_space: true
   ```

   [What it trades](#leading_space-and-what-it-trades) is one paragraph, below.

## 6. Linux, on ibus-rime or fcitx5-rime

1. Install `ibus-rime` or `fcitx5-rime` from your distribution — **and check
   that its Lua plug-in came too.** Spellless is written in Lua, and without
   the plug-in Rime cannot run a word of it. Both packages normally pull it in;
   Linux is the only place it can be missing, because the Windows and macOS
   builds always include it.
2. Download **`spellless-<version>.zip`** from
   [Releases](https://github.com/EricWay1024/spellless/releases) and unzip it.
3. Run the installer inside it:

   ```bash
   python3 scripts/install.py
   ```

4. `ibus restart`, or `fcitx5-remote -r`.
5. Press <kbd>F4</kbd>. That is Rime's list of what it can type; choose
   **Spellless**.
6. Type **`zzver`** in any text box. Five lines back means it is running.
7. **Add one setting.** The standard build cannot take a character back once it
   has been typed, so punctuation after a word you have *already* finished
   leaves its space stranded — `you .` Create or edit `spellless.custom.yaml`
   in Rime's settings folder (`~/.config/ibus/rime` or
   `~/.local/share/fcitx5/rime`), put this in it, and reload again:

   ```yaml
   patch:
     spellless/leading_space: true
   ```

   [What it trades](#leading_space-and-what-it-trades) is one paragraph, below.

---

# Reference

## What `zzver` tells you

Typing `zzver` in a text box asks Spellless which version of itself is actually
running, so "am I testing what I just installed, or what Rime loaded twenty
minutes ago" stops being a guess:

```
zzver  →  spellless 0.1.5 installed 2026-09-07 01:12
          83414 words, 809 forms, 3 shortcuts
          cue 70/9.0, slip 10.0, learn on
          reclaim on, absorb on, word-backspace on
          app com.apple.Notes, document readable, edits allowed
```

Five lines, each answering a different question: which build, how many words,
the matching constants, whether the four extra features are switched on at all,
and whether *this* program is allowed to have them.

## `leading_space`, and what it trades

Normally the automatic space rides on the word, which is right — stop typing
anywhere and the text is finished. It costs exactly one thing, and only where
Rime cannot take a character back: punctuation after a word you have already
finished leaves the space stranded, so picking `you` by number and then ending
the sentence gives `you .`

With `leading_space` on, the space goes in front of the *next* word instead,
where punctuation never has to argue with it:

```
                        standard Rime, default   with leading_space
typing "hello. world."   Hello . World .          Hello. World.
```

It is off by default because the trade goes the other way once Rime *can* take
that character back: leave the cursor after a word and there is no space behind
it until you type again, so a line you stop in the middle of ends flush. While
you are typing it looks the same — the space is written on the first letter of
the next word rather than carried by the candidate, so the list never shows a
leading space either.

## What the installer touched

For anyone who wants to know exactly. It finds where Rime keeps its settings —
the registry on Windows, `~/Library/Rime` on macOS, `~/.config/ibus/rime` or
`~/.local/share/fcitx5/rime` on Linux — and writes only inside that folder. Run
from WSL it finds the Windows-side folder by itself.

| Flag | |
| --- | --- |
| `--dry-run` | print every action, change nothing |
| `--list-candidates` | show which settings folders were considered, and why |
| `--user-dir DIR` | install somewhere specific |
| `--skip-dir DIR` | leave that folder out of every future install — for a standard Weasel you keep for another language |
| `--no-enable` | copy the files, leave `default.custom.yaml` alone |
| `--uninstall` | remove the files this script wrote |

It writes into **every** settings folder it finds — `%APPDATA%\Rime` for the
standard Weasel, `%APPDATA%\Spellless` for ours — so both end up running the
same build, and `--list-candidates` prints what it found and why. `--skip-dir
DIR` leaves a `spellless.skip` file behind and every later install passes that
folder by; `--uninstall --user-dir DIR` takes Spellless out of one it is
already in.

It refuses to copy a half-built `generated/`, because Rime would otherwise
catch that only once the files were live, and the symptom would be an input
method offering no words at all.

It leaves `rime.lua` alone — only one is ever loaded, so overwriting it would
break other people's Lua. It switches Spellless on by appending a single entry
to `default.custom.yaml`, Rime's own settings file, using the operator that
**adds** to the list of things Rime can type rather than replacing it —
important if you run a collection like rime-ice. That file is backed up first
and only ever has lines inserted, so your comments survive; if it already
edits the same list, the installer prints what to add rather than guessing.

**Installing from a clone** rather than a downloaded archive works the same
way; run `make && make test` first.

## Everything you can change

Any of the settings in `rime/lua/spellless/config.lua` can be overridden. Put
them in `spellless.custom.yaml` in Rime's settings folder and Deploy again.

```yaml
patch:
  spellless/leading_space: true        # standard Rime: put the space before the next word
  spellless/raw_candidate_index: 1     # put what you literally typed first, always
  spellless/raw_comment: "literal"     # and mark it, so it is obvious which it is
  spellless/show_debug_comments: true  # where each word came from, and what it scored
  spellless/learn: false               # stop learning
  spellless/auto_space: false          # type your own spaces
  spellless/enter_space: false         # or keep them, except after Enter
  spellless/ascii_delimiters: "$`"     # characters that switch to plain typing and back
  spellless/snippet_apps: "code.exe"   # where a snippet trigger is handed to the editor
  spellless/delimiter_apps: "code.exe,typora.exe"  # where `$` opens maths
  spellless/auto_capitalize: false     # and your own capitals
  menu/page_size: 9                    # a longer list (the literal slot follows it)
```

## Uninstalling

```bash
python3 scripts/install.py --uninstall
```

It removes the files it wrote, and prints the two things it deliberately does
not touch: the Spellless entry in `default.custom.yaml`, which you take out by
hand, and `spellless_user.txt`, which is your vocabulary rather than its.
