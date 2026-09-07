# Deploying Spellless

How a build gets from the repository into the input method, how to check that
it actually did, and the ways it silently does not.

Development happens in WSL; the input method runs on Windows, and on macOS
through [spellless-squirrel](https://github.com/EricWay1024/spellless-squirrel).
Nothing here can be tested end to end from the development machine — the
matcher can (`make test`), but the input method cannot.

---

## The short version

```bash
make                 # rebuild dictionary, indexes and test sets
make test            # must pass before you deploy anything
python3 scripts/install.py     # copy into every frontend it finds
```

Then **redeploy the frontend** — the table below says how on each platform,
and `install.py` prints it too — and then, in any text box, **type `zzver`**:

```
zzver  →  spellless 0.1.3 installed 2026-09-07 01:12
          83169 words, 630 forms, 3 shortcuts
          cue 70/9.0, slip 10.0, learn on
          reclaim on, absorb on, word-backspace on
          app com.apple.Notes, document readable, edits allowed
```

Five lines, and each answers a different question. The build, the dictionary,
the matching constants, whether the three document features are switched on at
all, and whether *this* application is allowed to have them. The last two are
easy to confuse and the distinction has cost an evening: `edit_document` on the
<kbd>F4</kbd> menu moves the fifth line and not the fourth.

If the revision is not the one you just built, you are testing something else.
Stop and find out why before you conclude anything about the change.

---

## Where each platform keeps its user directory

`install.py` knows all of these and prints which it chose:

| | user directory | redeploy |
| --- | --- | --- |
| Windows | the registry's `RimeUserDir`, else `%APPDATA%\Rime` or `%APPDATA%\Spellless` | tray icon → Deploy, or `WeaselDeployer.exe /deploy` |
| macOS | `~/Library/Rime` | menu-bar icon → Deploy |
| Linux | `~/.config/ibus/rime` or `~/.local/share/fcitx5/rime` | `ibus restart`, or `fcitx5-remote -r` |

The three document-editing features need a frontend that understands the
U+0008 convention — the Spellless builds of Weasel and Squirrel — but they are
no longer configured. The schema waits until a frontend has set
`surrounding_text` once and then switches itself on, so a stock build gets
stock behaviour and there is nothing to remember. `zzver` reports which it
found.

---

## On Windows there may be two frontends, and that is the trap

Spellless can run on stock Weasel, and it can run on
[spellless-weasel](https://github.com/EricWay1024/spellless-weasel), a fork
that adds three things a schema cannot do (see DESIGN.md §5.6). The fork is
built to install *beside* stock Weasel rather than replace it, so a machine can
have both — with **separate user directories**:

| | stock Weasel | the Spellless fork |
| --- | --- | --- |
| user directory | `%APPDATA%\Rime` | `%APPDATA%\Spellless` |
| registry | `HKCU\Software\Rime\Weasel` | `HKCU\Software\Rime\Spellless` |
| deployer | `WeaselDeployer.exe` in its install directory | `WeaselDeployer.exe` in the fork's build output |

Both read a `spellless.schema.yaml` and a `lua/spellless/`, and **installing
into one leaves the other running whatever it had before.** This is not
hypothetical: it happened for an entire working session, during which every
change appeared to have no effect because the frontend being typed into was
running a build from the previous day.

`scripts/install.py` therefore installs into **every** directory it finds, and
prints them:

```
Installing into:
  /mnt/c/Users/.../AppData/Roaming/Spellless   (Spellless registry RimeUserDir, via /mnt)
  /mnt/c/Users/.../AppData/Roaming/Rime        (Weasel registry RimeUserDir, via /mnt)
```

`--user-dir DIR` restricts it to one. `--list-candidates` shows what it
considered without changing anything.

**Each frontend needs its own redeploy.** Copying files updates the disk;
only a redeploy makes the running process read them.

---

## Verifying, in order of how much you should trust it

1. **`zzver` in a real text box.** The only check that involves the process
   actually serving your keystrokes. The revision comes from a Lua module the
   installer rewrites, so it reports what the process *loaded* — not what is on
   disk, which is always fresh because the installer just wrote it.
2. **`<user dir>/build/spellless.schema.yaml` has a recent timestamp.** Proves
   the redeploy ran and the schema compiled. Does not prove the process reloaded.
3. **The files under `<user dir>/lua/spellless/` match the repository.** Proves
   the copy happened. Proves nothing about the frontend.

A `-dirty` suffix on the revision means the tree had uncommitted changes when
it was installed. That is normal mid-session and useful: it distinguishes "the
build I just made" from "the build I committed".

---

## When nothing appears

`<user dir>/rime.log`, or the newest `rime.*.log` beside it, and grep for
`spellless`. Common causes, in order of likelihood:

- **The redeploy did not run**, or ran for the other frontend.
- **A Lua error at load.** The whole schema then produces no candidates. The
  log names the file and line.
- **`generated/` is stale or incomplete.** `make` rebuilds it; the corpus
  refuses to load half a build and says so.
- **The schema is not in `schema_list`.** `install.py` appends it with Rime's
  `"schema_list/+"` operator, which adds rather than replaces. Writing a bare
  `schema_list:` would hide every other schema — never do that by hand.

### Do not delete `build/`

It is tempting, and it makes things worse: while the directory is missing, Rime
falls back to the schema list that ships with the frontend and asks you to pick
a schema on every deploy. `install.py` marks the build stale instead, by
touching the timestamps Rime compares.

---

## WSL specifics

- The Windows user directory is reachable at `/mnt/c/Users/<you>/AppData/Roaming/...`.
  `install.py` finds it through the registry (`reg.exe`, absolute path as a
  fallback — it is not always on `PATH`), then `%APPDATA%`, then by scanning
  `/mnt/*/Users/*/AppData/Roaming`.
- Deployers and servers are Windows executables and run directly from WSL:
  `cd <dir> && ./WeaselDeployer.exe /deploy`.
- Line endings matter. `generated/spellless.words` is read with `[^\r\n]+`
  precisely because a checkout with `core.autocrlf` on would otherwise put a
  carriage return inside every committed word.
- **The personal vocabulary is written by the running server.** Editing
  `spellless_user.txt` while the frontend is running achieves nothing — it
  flushes its in-memory copy back over your edit. Stop the server first.

---

## Building the frontends

**macOS** needs no Mac: push to the `spellless` branch of
[spellless-squirrel](https://github.com/EricWay1024/spellless-squirrel) and
GitHub Actions builds the `.pkg` on a `macos-26` runner. `docs/RELEASING.md`
has the details, including the one thing CI cannot check — whether a given
application survives having text taken back out of it.

**Windows** is the [spellless-weasel](https://github.com/EricWay1024/spellless-weasel)
repository, and does need Windows. In outline: it needs Visual Studio Build Tools with **ATL** (the
`Microsoft.VisualStudio.Component.VC.ATL` component), and Boost, both of which
its own scripts fetch. The build products land in `output/`, and
`WeaselSetup.exe` from there registers the fork as a separate text service.

Its identity — product name, module base, registry key, default user directory,
CLSID and profile GUID — all come from `include/WeaselConstants.h`. That is what
makes it installable alongside stock Weasel rather than on top of it, and it is
the first place to look if the two ever start fighting over a directory.
