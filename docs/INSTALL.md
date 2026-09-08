# Installing Spellless

The [README](../README.md) has the one-paragraph version. This is everything
else: the choice of frontend, what the installer does, how to check it took,
and the settings worth knowing about.

If a build does not reach the input method, [DEPLOYING.md](DEPLOYING.md) is
the file for that.

---

## What it needs

Everything in Spellless is data and Lua, so it runs wherever Rime does:
**Weasel** on Windows, **Squirrel** on macOS, `ibus-rime` or `fcitx5-rime` on
Linux. You need **Python 3.8+** to run the installer, and only for that.

Lua support is already there on Windows and macOS: official librime release
builds bundle `librime-lua`, and Weasel and Squirrel ship those builds, so
there is nothing to compile and no administrator rights needed. On Linux the
distribution builds librime itself and packages the plugin separately —
`fcitx5-rime` and `ibus-rime` normally pull it in, and if Spellless loads no
candidates at all that is the first thing to check.

---

## Step 1 — choose your frontend

Four features need the input method to see the document, and three of them to
reach in and take text back out — which is further than any schema goes. That
is the entire difference between the two paths:

| | stock Weasel / Squirrel / `ibus-rime` / `fcitx5-rime` | **spellless-weasel** / **spellless-squirrel** / **spellless-fcitx5** |
| --- | :---: | :---: |
| everything in [USING.md](USING.md) | ✓ | ✓ |
| punctuation takes its space back — `you` <kbd>Space</kbd> `.` gives `you. `, not `you . ` | — | ✓ |
| a caret inside a word means plain typing — `4D`, `p.m.`, `v1.2` get no candidate list | — | ✓ |
| a word you re-type is picked up — delete the space after `so`, type `oner`, get `sooner` | — | <kbd>F4</kbd> |
| <kbd>Backspace</kbd> twice deletes the whole word | — | <kbd>F4</kbd> |
| what you have to configure | `leading_space`, [step 4](#step-4--stock-rime-only-turn-on-leading_space) | nothing |

The first two are on; the last two change what a key you already know does, or
move text you can see, so they are opinions rather than corrections and you
turn them on yourself. All four are switches in the <kbd>F4</kbd> menu.

**The fork is the better experience, and it does not displace anything.**

[spellless-weasel](https://github.com/EricWay1024/spellless-weasel) is Weasel
with that one convention added, rebuilt to install *beside* the Weasel you
already have — its own GUIDs, pipe, registry key and user directory — so a
Chinese input method on the same machine carries on untouched and both appear
in the input-method list. It also carries the schema inside it, so on Windows
**it is the only download you need**: run it and go to step 3.

[spellless-squirrel](https://github.com/EricWay1024/spellless-squirrel) is the
same for macOS, built by GitHub Actions on a macOS runner, but ships the
frontend alone — install it, then do step 2.

[spellless-fcitx5](https://github.com/EricWay1024/spellless-fcitx5) is
`fcitx5-rime` with the same convention, and is **newer and rougher than the
other two**. Build it from source — there are no packages yet — and note two
things before you do. It tracks upstream `fcitx5-rime`, which needs
fcitx5 ≥ 5.1.22, so Arch, Fedora 41+ and Tumbleweed are fine and Ubuntu 24.04
LTS is not; and on Linux it is the *client* that has to offer surrounding
text, which GTK and Qt do, much of Chromium does not, and no terminal does.
Where a client will not answer you get stock behaviour, silently — the right
failure, but it does mean these four features are not everywhere. Everything
in [USING.md](USING.md) works regardless.

Each is licensed as the project it forks — GPL-3.0 for Weasel and Squirrel,
GPL-2.0-or-later for `fcitx5-rime`; this repository is MIT. The Windows and
macOS builds ship unsigned, as upstream Squirrel's own releases do:
right-click → **Open** the first time.

**Staying on the Rime you already have** costs you those four rows and nothing
else. Do steps 2, 3 and 4.

Either way the schema install is the same, and the two that ship on switch
themselves on when they find a frontend that can carry them — see
[DESIGN.md §5.6](../DESIGN.md#56-what-the-frontend-can-do-and-rime-cannot).

---

## Step 2 — install the schema

Take a release archive from
[Releases](https://github.com/EricWay1024/spellless/releases) and run the
installer inside it, or clone this repository and run `make && make test`
first. Then:

```powershell
python scripts\install.py
```

or `python3 scripts/install.py` on macOS, Linux, and from WSL — where it finds
the Windows-side Rime directory by itself. It knows where each frontend keeps
its user directory: the registry on Windows, `~/Library/Rime` on macOS,
`~/.config/ibus/rime` or `~/.local/share/fcitx5/rime` on Linux.

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

---

## Step 3 — redeploy, and check it took

Redeploy the frontend — the Weasel tray icon → **Deploy** (「重新部署」), the
Squirrel menu-bar icon → **Deploy**, `ibus restart` or `fcitx5-remote -r` —
then press <kbd>F4</kbd> and choose **Spellless**. On Windows the tray icon and
the language-bar button turn into an **S**, and tapping Shift into plain typing
brings back Weasel's **A**.

**Type `zzver` in any text box** to see which build is actually running, so
"am I testing what I just deployed, or what Rime loaded twenty minutes ago"
stops being a guess:

```
zzver  →  spellless 41223bf installed 2026-09-06 12:34
          83414 words, 809 forms, 3 shortcuts
          cue 70/9.0, slip 10.0, learn on
```

If something misbehaves on first deploy, [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
lists the symptoms and what each one usually is. The two places to look yourself
are the candidate comments (`spellless/show_debug_comments: true`) and
`%APPDATA%\Rime\rime.log`; [DEPLOYING.md](DEPLOYING.md) has how a build reaches
the input method and the ways it silently does not.

---

## Step 4 — stock Rime only: turn on `leading_space`

The automatic space rides on the word, which is right — stop typing anywhere
and the text is finished. It costs exactly one thing, and only where the
frontend cannot take a character back: punctuation after a word you have
*already* committed leaves the space stranded, so picking `you` by number and
then ending the sentence gives `you .`

Put this in `spellless.custom.yaml` in your Rime user directory and redeploy:

```yaml
patch:
  spellless/leading_space: true
```

The space now goes in front of the *next* word, where punctuation never has to
argue with it:

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

---

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

---

## Uninstalling

```bash
python3 scripts/install.py --uninstall
```

It removes the files it wrote, and prints the two things it deliberately does
not touch: the schema entry in `default.custom.yaml`, which you take out by
hand, and `spellless_user.txt`, which is your vocabulary rather than its.
