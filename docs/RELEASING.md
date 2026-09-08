# Releasing Spellless

Three products, in two repositories and a half.

| | what it is | platforms |
| --- | --- | --- |
| **`spellless-<version>.zip`** | the schema, the matcher, the dictionary and the installer | Windows, macOS, Linux |
| **`spellless-<version>-installer.exe`** | the same, inside a Rime frontend, as one installer | Windows |
| **`Spellless-Squirrel-<version>.pkg`** | the frontend half for macOS | macOS |

The first is this repository. The other two are frontends, and each is built
in its own fork's tree:

* [spellless-weasel](https://github.com/EricWay1024/spellless-weasel) — Weasel
  with the document convention added, and the schema bundled inside the
  installer, so one download is the whole thing;
* [spellless-squirrel](https://github.com/EricWay1024/spellless-squirrel) —
  Squirrel with the same convention, built by GitHub Actions on a macOS
  runner. It does **not** bundle the schema: pair it with the zip.

---

## The one convention both frontends implement

A schema cannot take back text an application has already been given, and
three features need to — punctuation reclaiming its automatic space, a
half-typed word being picked up, Backspace deleting a whole word. So the
frontend does it, and the contract is small enough to state here:

1. it sets the Rime property `surrounding_text` to the characters immediately
   before the composition, on every keystroke;
2. it reads a leading run of U+0008 in a commit as "extend backwards over this
   many characters and replace them".

On Windows that costs `ITfComposition::ShiftStart`, a synchronous edit session
and an IPC hop between two processes. On macOS
`insertText(_:replacementRange:)` is the same thing in one call — except when
there is nothing to insert, where an empty insert is widely ignored and empty
*marked* text over the range is what works.

**The schema finds out which frontend it has rather than being told.** Nothing
is asked of one until it has set `surrounding_text` at least once, and no
stock build ever does, so the three features ship on and are simply inert on
stock Weasel or stock Squirrel. There is no configuration that can make them
corrupt a document.

## What the schema archive needs

A Rime frontend built with **librime-lua**, which the official builds all are:
`rime/librime`'s `release-ci.yml` builds
`hchunhui/librime-lua lotem/librime-octagram rime/librime-predict` into the
macOS and Windows artefacts, and Weasel and Squirrel ship those artefacts.
Linux distributions package the plugin separately; `fcitx5-rime` and
`ibus-rime` normally pull it in.

If it is missing, the schema loads and produces no candidates at all, and
`rime.log` says `error creating translator: 'lua_translator'`. That is worth
knowing because it looks exactly like a broken install.

---

## Cutting the schema archive

```bash
make release VERSION=0.1.0
```

which is `make && make test` and then `scripts/package.py`. It refuses a dirty
tree and a missing `generated/`, because an archive nobody can reproduce is
worse than no archive. `--allow-dirty` overrides that for a test build.

The result is `dist/spellless-0.1.0.zip`, about 0.9 MB, laid out exactly like
the repository so that `scripts/install.py` runs out of it unmodified:

```
spellless-0.1.0/
  README.md            what to install it into, and how
  LICENSE
  scripts/install.py
  rime/…               schema, icon, Lua
  generated/…          dictionary, indexes, forms
```

`version.lua` is rewritten with the release version, so `zzver` in a text box
reports `spellless 0.1.0` rather than a git hash nobody can look up. The
installer leaves that alone when it cannot find git — which is how it knows it
is running from an archive rather than a checkout.

**Check it before publishing.** Unpack somewhere else and install into a
scratch directory:

```bash
cd /tmp && unzip -q ~/spellless/dist/spellless-0.1.0.zip
python3 spellless-0.1.0/scripts/install.py --user-dir /tmp/scratch-rime
```

The last line of the stamp should say `0.1.0`, not `unknown`.

---

## Cutting the bundled Windows installer

This one is built in the fork's tree, on Windows, and needs the fork already
built — MSVC with ATL, Boost, and NSIS for the packaging step.

**Use NSIS 3.10 or newer.** The fork's `install_nsis.bat` pins 3.08, whose
`WinVer.nsh` has no `AtLeastWin11`, so `${If} ${AtLeastWin11}` expands to a
bare `${If}` and the compile dies with `macro "_If" requires 4 parameter(s),
passed 2`. Edit the version in that script, or fetch 3.10 the same way it
does.

```bash
# from this repository, on the WSL side
python3 scripts/package.py --version 0.1.0 --weasel /mnt/c/Users/you/spellless-weasel
```

That copies the payload into the fork's `output/data/` — its **shared** data
directory, not a user directory, so a fresh install works before the user has
one — stamps the version, and adds `spellless` to the top of the bundled
`default.yaml` schema list. It is idempotent and it does not build anything.

`output/data/` is untracked in the fork (`/output/data/*.yaml` is in its
`.gitignore`), so this leaves nothing to commit there.

Then, on Windows, in the fork:

```
build.bat installer
```

which writes `output/archives/spellless-<version>-installer.exe`.

Note that `build.bat installer` **also rebuilds Weasel**: none of `weasel`,
`boost`, `data`, `opencc` or `rime` was requested, and the script's fallback
then sets `build_weasel=1`. When `output/` is already current, calling NSIS
directly is minutes rather than a full MSVC pass — from a `.bat` file, because
`cmd.exe /c` through WSL mangles the quoting around `%ProgramFiles(x86)%`:

```bat
@echo off
cd /d C:\Users\you\spellless-weasel
"%ProgramFiles(x86)%\NSIS\Bin\makensis.exe" ^
  /DWEASEL_VERSION=0.17.4 /DWEASEL_BUILD=0 /DPRODUCT_VERSION=0.1.0 ^
  output\install.nsi
```

Nine `no files found` warnings are expected on an x64-only build — six ARM
binaries, `data\*.gram`, and two OpenCC lines — and every one of them is
`/nonfatal`.

**Check the payload before publishing**, because the failure mode is an
installer that works and an input method that offers nothing:

```bash
cd <fork>/output && ./7z.exe l archives/spellless-0.1.0-installer.exe \
  | grep -E 'data.(lua|spellless)'
```

That should list 18 files under `data\lua\` — the adapter and 17 modules — and
six under `data\spellless\`. If it
lists only `data\spellless.schema.yaml`, the `File /r "data\lua\*.*"` lines
have gone missing again — `File "data\*.yaml"` takes the schema and nothing
else.

### The shared directory is why this works at all

librime-lua puts *both* data directories on `package.path` —
`<user>/lua/?.lua` first, then `<shared>/lua/?.lua` (see `src/modules.cc`) —
so `require("spellless.engine")` resolves out of the bundle, and
`find_data_dir` in the adapter looks in the user directory first and the shared
one second for the same reason. A user who later runs `scripts/install.py`
gets their own copy in front, which is what you want: the bundle is the floor,
not the ceiling.

---

## Cutting the macOS frontend

No Mac required, which is the point: GitHub's macOS runners are real ones, and
the fork's `.github/workflows/spellless-build.yml` uses the same shape as
upstream Squirrel's own release CI.

```bash
git -C <squirrel-fork> push origin spellless     # any push to that branch
gh run watch <id> --exit-status
gh run download <id> -n Squirrel-Spellless -D dist/mac
```

The workflow runs the reclaim rules through plain `swiftc` first — they live in
`SpelllessRules.swift` with no InputMethodKit import precisely so that they
can — and only then builds the `.app` and wraps it in a `.pkg`. A rule that is
wrong is wrong in every application, and there is no point building the rest to
find that out.

Two things the artifact needs before it is a release:

* **rename it.** The workflow ships upstream's `Squirrel-<version>.pkg`; call
  it `Spellless-Squirrel-<version>.pkg` so nobody installs it thinking it is
  stock Squirrel.
* **it carries no schema.** Unlike the Windows installer, this is the frontend
  only. Say in the notes to pair it with the zip.

### It is not signed, and does not need to be

Upstream Squirrel's release CI publishes `package/Squirrel-*.pkg` straight from
Actions with **no codesign or notarise step anywhere**. So an unsigned build
asks nothing of a macOS user that the thing it is based on does not already:
right-click → **Open**, or `xattr -d com.apple.quarantine <file>`. No Apple
Developer account, no $99.

### What CI cannot tell you

Whether an application honours a backwards replacement range. That is a
property of its `NSTextInputClient`, and it is where both real bugs have been:
VS Code's terminal replaying its buffer on Windows, and `absorb_fragment`
silently doing nothing on macOS because an empty `insertText` is ignored.
Neither was visible in the source. Both took a person typing.

So a macOS release is not finished until somebody has typed into TextEdit,
Notes, Safari, Chrome, Mail, Terminal.app, iTerm2 and VS Code, watching for a
**duplicated line**. Whatever misbehaves goes into `commit_only_apps` by bundle
identifier — `osascript -e 'id of app "Whatever"'` gives you that.

---

### Licensing

Spellless is MIT; Weasel, Squirrel and both forks are GPL-3.0. Distributing
the schema and a frontend as one installer is fine — MIT is GPL-compatible —
but **the combined Windows installer is GPL-3.0** and has to carry the fork's
source offer, and so is the macOS `.pkg`. The schema archive on its own stays
MIT. Do not let the two get muddled in the release notes.

---

## Publishing

```bash
git tag -a v0.1.0 -m "Spellless 0.1.0"
git push origin v0.1.0
gh release create v0.1.0 dist/spellless-0.1.0.zip --title "Spellless 0.1.0"
```

Attach the Windows installer to the same release from the fork's build output.
Say in the notes which of the two a reader wants:

- **already using Rime** → the zip, on any platform;
- **on Windows and not using Rime** → the installer;
- **on macOS and not using Rime** → install Squirrel, then the zip.

Note that `scripts/install.py`'s version stamp uses
`git describe --always --dirty --exclude '*'`, which deliberately ignores tags:
a checkout should report the commit it is on, not the last release near it.
The tag only names the archive.
