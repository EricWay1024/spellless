# Deploying Spellless

How a build gets from the repository into the input method, how to check that
it actually did, and the ways it silently does not.

Development happens in WSL; the input method runs on Windows. Nothing here can
be tested end to end from inside WSL — the matcher can (`make test`), but the
input method cannot.

---

## The short version

```bash
make                 # rebuild dictionary, indexes and test sets
make test            # must pass before you deploy anything
python3 scripts/install.py     # copy into every frontend it finds
```

Then **redeploy the frontend** — right-click its tray icon and choose the
redeploy entry (Chinese builds: 「重新部署」), or run its deployer directly —
and then, in any text box, **type `zzver`**:

```
zzver  →  spellless 0848769 installed 2026-09-06 12:10
          83151 words, 622 forms, 3 shortcuts
          cue 70/9.0, slip 10.0, learn on
```

If the revision is not the one you just built, you are testing something else.
Stop and find out why before you conclude anything about the change.

---

## There may be two frontends, and that is the trap

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

## Building the fork

See the [spellless-weasel](https://github.com/EricWay1024/spellless-weasel)
repository. In outline: it needs Visual Studio Build Tools with **ATL** (the
`Microsoft.VisualStudio.Component.VC.ATL` component), and Boost, both of which
its own scripts fetch. The build products land in `output/`, and
`WeaselSetup.exe` from there registers the fork as a separate text service.

Its identity — product name, module base, registry key, default user directory,
CLSID and profile GUID — all come from `include/WeaselConstants.h`. That is what
makes it installable alongside stock Weasel rather than on top of it, and it is
the first place to look if the two ever start fighting over a directory.
