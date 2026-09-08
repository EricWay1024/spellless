# Installing Spellless

Six ways in — three platforms, and on each of them either **our frontend**
(recommended) or **the Rime you already have**. Find yours in the table below
and read that one section; each is self-contained.

When something does not work afterwards,
[TROUBLESHOOTING.md](TROUBLESHOOTING.md).

---

## Install our frontend

**Do this if you can.** Spellless is a Rime schema, and a schema cannot see the
document it is typing into — that is where Rime's API stops. Four things
therefore live in the frontend rather than the schema, and
**spellless-weasel**, **spellless-squirrel** and **spellless-fcitx5** are the
ordinary Rime frontends with the one convention added that lets a schema ask
for them:

| | stock Weasel / Squirrel / `ibus-rime` / `fcitx5-rime` | our frontend |
| --- | :---: | :---: |
| everything in [USING.md](USING.md) | ✓ | ✓ |
| punctuation takes its space back — `you` <kbd>Space</kbd> `.` gives `you. `, not `you . ` | — | ✓ |
| a caret inside a word means plain typing — `4D`, `p.m.`, `v1.2` get no candidate list | — | ✓ |
| a word you re-type is picked up — delete the space after `so`, type `oner`, get `sooner` | — | <kbd>F4</kbd> |
| <kbd>Backspace</kbd> twice deletes the whole word | — | <kbd>F4</kbd> |
| what you have to configure | `leading_space` | nothing |

The first two are on; the last two change what a key you already know does, or
move text you can see, so they are opinions rather than corrections and you
turn them on yourself in the <kbd>F4</kbd> menu, where all four are switches.

**It does not displace anything.** On Windows the fork installs *beside* the
Weasel you already have — its own GUIDs, pipe, registry key and user directory
— so a Chinese input method on the same machine carries on untouched and both
appear in the input-method list. On Windows it also carries the schema inside
it, which makes it a single download and nothing else to run.

Each is licensed as the project it forks — GPL-3.0 for Weasel and Squirrel,
GPL-2.0-or-later for `fcitx5-rime`; this repository is MIT. The Windows and
macOS builds ship unsigned, as upstream Squirrel's own releases do.

**Staying on the Rime you already have** costs you those four rows and nothing
else. Sections 4 to 6 are for that, and they work.

## Which section is yours

| | our frontend (recommended) | the Rime you already have |
| --- | --- | --- |
| **Windows** | [1. Windows, with spellless-weasel](#1-windows-with-spellless-weasel) | [4. Windows, on stock Weasel](#4-windows-on-stock-weasel) |
| **macOS** | [2. macOS, with spellless-squirrel](#2-macos-with-spellless-squirrel) | [5. macOS, on stock Squirrel](#5-macos-on-stock-squirrel) |
| **Linux** | [3. Linux, with spellless-fcitx5](#3-linux-with-spellless-fcitx5) | [6. Linux, on ibus-rime or fcitx5-rime](#6-linux-on-ibus-rime-or-fcitx5-rime) |

Everything in Spellless is data and Lua, so nothing is ever compiled and no
administrator rights are needed. Five of the six need **Python 3.8+** to run
the installer, and only for that.

---

## 1. Windows, with spellless-weasel

The shortest path there is. One download, and it carries the schema.

1. Download **`spellless-<version>-installer.exe`** from
   [Releases](https://github.com/EricWay1024/spellless/releases).
2. Run it. It is unsigned, so SmartScreen will object: **More info** →
   **Run anyway**. It installs alongside any Weasel already on the machine.
3. Right-click the tray icon → **Deploy** (「重新部署」).
4. Press <kbd>F4</kbd> and choose **Spellless**. The tray icon and the
   language-bar button turn into an **S**; tapping Shift into plain typing
   brings back the **A**.
5. Type **`zzver`** in any text box. Five lines means it is running.

Nothing to configure. If you also keep a stock Weasel for Chinese, note that
the two have separate user directories — see
[TROUBLESHOOTING.md](TROUBLESHOOTING.md#changes-have-no-effect).

## 2. macOS, with spellless-squirrel

Two downloads: the frontend carries no schema.

1. Download **`Spellless-Squirrel-<version>.pkg`** and
   **`spellless-<version>.zip`** from
   [Releases](https://github.com/EricWay1024/spellless/releases).
2. Install the `.pkg`. It is unsigned: right-click → **Open** the first time.
   It installs under the ordinary Squirrel bundle identifier, so it *upgrades*
   a Squirrel you already have rather than sitting beside it, and it will ask
   you to log out and back in.
3. Unzip the archive and run the installer inside it:

   ```bash
   python3 scripts/install.py
   ```

4. Menu-bar icon → **Deploy**.
5. Press <kbd>F4</kbd> and choose **Spellless**.
6. Type **`zzver`** in any text box. Five lines means it is running.

Nothing to configure.

## 3. Linux, with spellless-fcitx5

**Newer and rougher than the other two**, and the only one you have to build
yourself.

1. Check your fcitx5 is **≥ 5.1.22** — it tracks upstream `fcitx5-rime`, so
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
5. Press <kbd>F4</kbd> and choose **Spellless**.
6. Type **`zzver`** in any text box. Five lines means it is running.

One caveat particular to Linux: it is the *client* that has to offer
surrounding text. GTK and Qt do, much of Chromium does not, and no terminal
does. Where a client will not answer you get stock behaviour, silently — the
right failure, but it does mean those four features are not everywhere.
Everything in [USING.md](USING.md) works regardless.

## 4. Windows, on stock Weasel

1. If you do not have Weasel, install it from [rime.im](https://rime.im).
2. Download **`spellless-<version>.zip`** from
   [Releases](https://github.com/EricWay1024/spellless/releases) and unzip it.
3. Run the installer inside it:

   ```powershell
   python scripts\install.py
   ```

   From WSL, `python3 scripts/install.py` finds the Windows-side Rime
   directory by itself.
4. Right-click the tray icon → **Deploy** (「重新部署」).
5. Press <kbd>F4</kbd> and choose **Spellless**.
6. Type **`zzver`** in any text box. Five lines means it is running.
7. **Turn on `leading_space`.** A stock frontend cannot take a character back,
   so punctuation typed after a word you have *already* committed leaves its
   space stranded — `you .` Put this in `spellless.custom.yaml` in your Rime
   user directory (`%APPDATA%\Rime`, unless you have moved it) and redeploy:

   ```yaml
   patch:
     spellless/leading_space: true
   ```

   [What it costs](#leading_space-and-what-it-trades) is one line, below.

## 5. macOS, on stock Squirrel

1. If you do not have Squirrel, install it from [rime.im](https://rime.im).
2. Download **`spellless-<version>.zip`** from
   [Releases](https://github.com/EricWay1024/spellless/releases) and unzip it.
3. Run the installer inside it:

   ```bash
   python3 scripts/install.py
   ```

4. Menu-bar icon → **Deploy**.
5. Press <kbd>F4</kbd> and choose **Spellless**.
6. Type **`zzver`** in any text box. Five lines means it is running.
7. **Turn on `leading_space`.** A stock frontend cannot take a character back,
   so punctuation typed after a word you have *already* committed leaves its
   space stranded — `you .` Put this in `spellless.custom.yaml` in
   `~/Library/Rime` and redeploy:

   ```yaml
   patch:
     spellless/leading_space: true
   ```

   [What it costs](#leading_space-and-what-it-trades) is one line, below.

## 6. Linux, on ibus-rime or fcitx5-rime

1. Install `ibus-rime` or `fcitx5-rime` from your distribution — **and check
   that librime-lua came with it.** On Linux the distribution builds librime
   itself and packages the Lua plugin separately; both frontends normally pull
   it in, and without it nothing in Spellless can run. (This is never the
   problem on Windows or macOS, where the official builds bundle it.)
2. Download **`spellless-<version>.zip`** from
   [Releases](https://github.com/EricWay1024/spellless/releases) and unzip it.
3. Run the installer inside it:

   ```bash
   python3 scripts/install.py
   ```

4. `ibus restart`, or `fcitx5-remote -r`.
5. Press <kbd>F4</kbd> and choose **Spellless**.
6. Type **`zzver`** in any text box. Five lines means it is running.
7. **Turn on `leading_space`.** A stock frontend cannot take a character back,
   so punctuation typed after a word you have *already* committed leaves its
   space stranded — `you .` Put this in `spellless.custom.yaml` in your Rime
   user directory (`~/.config/ibus/rime` or `~/.local/share/fcitx5/rime`) and
   redeploy:

   ```yaml
   patch:
     spellless/leading_space: true
   ```

   [What it costs](#leading_space-and-what-it-trades) is one line, below.

---

# Reference

## What `zzver` tells you

Typing `zzver` in a text box asks the schema which build is actually running,
so "am I testing what I just deployed, or what Rime loaded twenty minutes ago"
stops being a guess:

```
zzver  →  spellless 0.1.5 installed 2026-09-07 01:12
          83414 words, 809 forms, 3 shortcuts
          cue 70/9.0, slip 10.0, learn on
          reclaim on, absorb on, word-backspace on
          app com.apple.Notes, document readable, edits allowed
```

Five lines, each answering a different question: the build, the dictionary, the
matching constants, whether the four document features are switched on at all,
and whether *this* application is allowed to have them.

## `leading_space`, and what it trades

The automatic space normally rides on the word, which is right — stop typing
anywhere and the text is finished. It costs exactly one thing, and only where
the frontend cannot take a character back: punctuation after a word you have
already committed leaves the space stranded, so picking `you` by number and
then ending the sentence gives `you .`

With `leading_space` on, the space goes in front of the *next* word instead,
where punctuation never has to argue with it:

```
                        stock frontend, default   with leading_space
typing "hello. world."   Hello . World .           Hello. World.
```

It is off by default because the trade goes the other way once your frontend
*can* reclaim: leave the caret after a word and there is no space behind it
until you type again, so a line you stop in the middle of ends flush. While you
are typing it looks the same — the space is written on the first letter of the
next word rather than carried by the candidate, so the candidate list never
shows a leading space either. `reclaim_space` and `enter_space` become
redundant rather than wrong when it is on; they simply never have a space to
act on.

## What the installer does

It knows where each frontend keeps its user directory: the registry on Windows,
`~/Library/Rime` on macOS, `~/.config/ibus/rime` or
`~/.local/share/fcitx5/rime` on Linux. Run from WSL it finds the Windows-side
directory by itself.

| Flag | |
| --- | --- |
| `--dry-run` | print every action, change nothing |
| `--list-candidates` | show which Rime user directories were considered, and why |
| `--user-dir DIR` | install somewhere specific |
| `--skip-dir DIR` | leave that directory out of every future install — for a stock Weasel you keep for Chinese |
| `--no-enable` | copy the files, leave `default.custom.yaml` alone |
| `--uninstall` | remove the files this script wrote |

It writes into **every** Rime user directory it finds — `%APPDATA%\Rime` for
stock Weasel, `%APPDATA%\Spellless` for the fork — so both frontends end up
running the same build, and `--list-candidates` prints what it found and why.
`--skip-dir DIR` leaves a `spellless.skip` file behind and every later install
passes that directory by; `--uninstall --user-dir DIR` takes the schema out of
one it is already in.

It refuses to copy a `generated/` whose parts disagree with each other, because
the Lua side would otherwise catch that only once the half-build was already
live and the symptom would be a schema with no candidates at all.

It writes only inside those directories, and leaves `rime.lua` alone — only one
is ever loaded, so overwriting it would break other Lua schemas. It enables the
schema by appending one entry to `default.custom.yaml` with Rime's list-append
operator (`"schema_list/+"`), which **adds** to the schema list rather than
replacing it — important if you run a distribution like rime-ice. The file is
backed up first and only ever has lines inserted, so your comments survive; if
it already patches `schema_list`, the installer prints what to add rather than
guessing.

**Installing from a clone** rather than a release archive works the same way;
run `make && make test` first.

## Configuration

Anything in `rime/lua/spellless/config.lua` can be overridden per schema. Edit
`spellless.custom.yaml` in your Rime user directory and redeploy.

```yaml
patch:
  spellless/leading_space: true        # stock Rime: put the space before the next word
  spellless/raw_candidate_index: 1     # put the literal input first, always
  spellless/raw_comment: "literal"     # and mark it, so it is obvious which it is
  spellless/show_debug_comments: true  # where each candidate came from, and what it scored
  spellless/learn: false               # stop learning
  spellless/auto_space: false          # type your own spaces
  spellless/enter_space: false         # or keep them, except after Enter
  spellless/ascii_delimiters: "$`"     # characters that switch to plain typing and back
  spellless/snippet_apps: "code.exe"   # where a trigger is given back to the editor
  spellless/delimiter_apps: "code.exe,typora.exe"  # where `$` opens maths
  spellless/auto_capitalize: false     # and your own capitals
  menu/page_size: 9                    # a bigger window (the literal slot follows it)
```

## Uninstalling

```bash
python3 scripts/install.py --uninstall
```

It removes the files it wrote, and prints the two things it deliberately does
not touch: the schema entry in `default.custom.yaml`, which you take out by
hand, and `spellless_user.txt`, which is your vocabulary rather than its.
