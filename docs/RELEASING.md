# Releasing Spellless

Two products, because they answer different questions, and one combination
that does not exist.

| | what it is | platforms |
| --- | --- | --- |
| **`spellless-<version>.zip`** | the schema, the matcher, the dictionary and the installer | Windows, macOS, Linux |
| **`spellless-weasel-<version>-installer.exe`** | the same, inside a Rime frontend, as one installer | Windows only |

---

## Why there is no bundled macOS build

The bundle is [spellless-weasel](https://github.com/EricWay1024/spellless-weasel),
a fork of **Weasel**, which is Rime's Windows frontend: MSVC, and a Windows
Text Services Framework text service. macOS uses a different frontend
(**Squirrel**, Swift and InputMethodKit) with different APIs, and the three
features the fork exists for are written against TSF —
`ITfComposition::ShiftStart` and `SetText` to take back characters the
application has already been given. There is no port and porting it is a
project, not a build step.

That is the *only* thing missing on macOS. The schema archive works there in
full, because everything in it is data and Lua.

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
built — MSVC with ATL, Boost, and NSIS for the packaging step
(`install_nsis.bat` in the fork fetches it).

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

which writes `output/archives/weasel-<version>-installer.exe`.

### The shared directory is why this works at all

librime-lua puts *both* data directories on `package.path` —
`<user>/lua/?.lua` first, then `<shared>/lua/?.lua` (see `src/modules.cc`) —
so `require("spellless.engine")` resolves out of the bundle, and
`find_data_dir` in the adapter looks in the user directory first and the shared
one second for the same reason. A user who later runs `scripts/install.py`
gets their own copy in front, which is what you want: the bundle is the floor,
not the ceiling.

### Licensing

Spellless is MIT; Weasel and the fork are GPL-3.0. Distributing them as one
installer is fine — MIT is GPL-compatible — but **the combined installer is
GPL-3.0**, and it has to carry the fork's source offer. The schema archive on
its own stays MIT. Do not let the two get muddled in the release notes.

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
