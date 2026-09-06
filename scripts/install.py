#!/usr/bin/env python3
"""Install Spellless into a Rime user directory.

Copies the schema, the Lua modules and the generated dictionary/indexes, and
(unless --no-enable) adds the schema to `default.custom.yaml`.  Nothing outside
the Rime user directory is touched, no elevated privileges are needed, and
`default.custom.yaml` is backed up before it is edited.

    python3 scripts/install.py                 install and enable
    python3 scripts/install.py --dry-run       show what would happen
    python3 scripts/install.py --user-dir DIR  install somewhere specific
    python3 scripts/install.py --uninstall     remove what this script wrote

Run from WSL and it will find the Windows-side Weasel directory by itself.
"""

from __future__ import annotations

import argparse
import os
import platform
import re
import shutil
import subprocess
from datetime import datetime
import sys
import time
from pathlib import Path, PurePosixPath

REPO = Path(__file__).resolve().parent.parent

# Everything this script owns, as (source, destination-relative-to-user-dir).
PAYLOAD: list[tuple[str, str]] = [
    ("rime/spellless.schema.yaml", "spellless.schema.yaml"),
    ("rime/spellless.ico", "spellless.ico"),
    ("rime/lua/spellless.lua", "lua/spellless.lua"),
    ("rime/lua/spellless/", "lua/spellless/"),
    ("generated/", "spellless/"),
]

SCHEMA_ID = "spellless"

# A directory holding this file is left out of the automatic install.  The
# installer otherwise writes into every Rime user directory it can find, which
# is right when the two frontends should run the same build and wrong when one
# of them is deliberately somebody else's -- a stock Weasel kept for Chinese,
# say.  Without it, "uninstall from there" lasts until the next `make install`.
SKIP_MARKER = "spellless.skip"
SKIP_TEXT = (
    "# Spellless: scripts/install.py leaves this directory alone.\n"
    "# Delete this file to install here again.\n"
)


# ---------------------------------------------------------------------------
# finding the Rime user directory
# ---------------------------------------------------------------------------

def is_wsl() -> bool:
    try:
        return "microsoft" in Path("/proc/version").read_text().lower()
    except OSError:
        return False


def windows_env(name: str) -> str | None:
    """Read a Windows environment variable from inside WSL."""
    try:
        out = subprocess.run(["cmd.exe", "/c", f"echo %{name}%"],
                             capture_output=True, text=True, timeout=15,
                             cwd="/mnt/c" if Path("/mnt/c").exists() else None)
        value = out.stdout.strip()
        return value if value and not value.startswith("%") else None
    except (OSError, subprocess.SubprocessError):
        return None


def windows_registry_user_dir(reg_cmd: list[str], product: str = "Weasel") -> str | None:
    r"""A Weasel-family frontend stores its user directory in the registry.

    HKCU only, deliberately: Weasel's own `WeaselUserDataPath()` opens
    HKEY_CURRENT_USER and falls back to ``%APPDATA%\\Rime``, and never consults
    HKLM.  Reading HKLM too would let a stale machine-wide value send the
    install to a directory the IME does not load, and report success.

    `product` is the key under HKCU\Software\Rime.  The Spellless build of
    Weasel is a second, separately-branded frontend that registers itself as
    "Spellless" and defaults to %APPDATA%\Spellless -- see WeaselConstants.h in
    EricWay1024/spellless-weasel.  Both are real installs and a machine can run
    either, so both are looked up.
    """
    # reg.exe is not always on PATH under WSL; the absolute path always works.
    for cmd in (reg_cmd, ["/mnt/c/Windows/System32/reg.exe"]):
        try:
            out = subprocess.run(
                cmd + ["query", rf"HKCU\Software\Rime\{product}", "/v", "RimeUserDir"],
                capture_output=True, text=True, timeout=15)
        except (OSError, subprocess.SubprocessError):
            continue
        if out.returncode == 0:
            break
    else:
        return None
    m = re.search(r"RimeUserDir\s+REG_\w+\s+(.+)", out.stdout)
    return m.group(1).strip() if m and m.group(1).strip() else None


def safe_is_dir(path: Path) -> bool:
    """Path.is_dir() that survives another Windows user's locked-down profile."""
    try:
        return path.is_dir()
    except OSError:
        return False


def to_wsl_path(win_path: str) -> Path | None:
    """C:\\Users\\me\\AppData\\Roaming\\Rime  ->  /mnt/c/Users/me/..."""
    m = re.match(r"^([A-Za-z]):[\\/](.*)$", win_path)
    if not m:
        return None
    drive, rest = m.group(1).lower(), m.group(2).replace("\\", "/")
    return Path("/mnt") / drive / PurePosixPath(rest)


# Weasel-family frontends, and the directory each defaults to.  Spellless first:
# a machine that has it is running it, and it is the build the document-reading
# features need.  Both are installed side by side on purpose.
PRODUCTS = [("Spellless", "Spellless"), ("Weasel", "Rime")]


def candidate_user_dirs() -> list[tuple[Path, str]]:
    """Plausible Rime user directories, best guess first, with a label."""
    out: list[tuple[Path, str]] = []
    system = platform.system()

    if system == "Windows":
        for product, default in PRODUCTS:
            reg = windows_registry_user_dir(["reg"], product)
            if reg:
                out.append((Path(reg), f"{product} registry RimeUserDir"))
            appdata = os.environ.get("APPDATA")
            if appdata:
                out.append((Path(appdata) / default,
                            f"{product} default (%APPDATA%\\{default})"))
    elif is_wsl():
        for product, default in PRODUCTS:
            reg = windows_registry_user_dir(["reg.exe"], product)
            if reg:
                p = to_wsl_path(reg)
                if p:
                    out.append((p, f"{product} registry RimeUserDir, via /mnt"))
            appdata = windows_env("APPDATA")
            if appdata:
                p = to_wsl_path(appdata)
                if p:
                    out.append((p / default,
                                f"{product} default (%APPDATA%\\{default}), via /mnt"))
        # Fall back to scanning /mnt/*/Users/*/AppData if cmd.exe was unavailable.
        # Other people's profiles are unreadable from WSL; skip them quietly.
        try:
            drives = sorted(Path("/mnt").glob("[a-z]"))
        except OSError:
            drives = []
        for drive in drives:
            try:
                users = sorted((drive / "Users").glob("*"))
            except OSError:
                continue
            for user in users:
                guess = user / "AppData" / "Roaming" / "Rime"
                if safe_is_dir(guess):
                    out.append((guess, "found by scanning /mnt"))
    elif system == "Darwin":
        out.append((Path.home() / "Library" / "Rime", "Squirrel default"))
    else:
        out.append((Path.home() / ".local" / "share" / "fcitx5" / "rime", "fcitx5-rime"))
        out.append((Path.home() / ".config" / "ibus" / "rime", "ibus-rime"))

    # de-duplicate, keeping order
    seen, unique = set(), []
    for path, why in out:
        key = str(path)
        if key not in seen:
            seen.add(key)
            unique.append((path, why))
    return unique


def resolve_user_dir(explicit: str | None) -> tuple[Path, str]:
    if explicit:
        return Path(explicit).expanduser(), "given on the command line"
    candidates = candidate_user_dirs()
    for path, why in candidates:
        if safe_is_dir(path):
            return path, why
    if candidates:
        return candidates[0][0], candidates[0][1] + " (does not exist yet)"
    raise SystemExit(
        "Could not work out where Rime keeps its user directory.\n"
        "Pass it explicitly, e.g.  --user-dir '/mnt/c/Users/you/AppData/Roaming/Rime'")


# ---------------------------------------------------------------------------
# copying
# ---------------------------------------------------------------------------

def check_payload() -> str | None:
    """Refuse to install a half-built or mismatched `generated/`.

    The Lua side validates the same invariant at load time, but by then the
    files are already in the live Rime directory and the failure shows up as a
    schema with no candidates.
    """
    gen = REPO / "generated"
    expected = ["spellless.words", "spellless.weights", "spellless.alpha",
                "spellless.skel", "spellless.forms", "spellless.build.json"]
    missing = [name for name in expected if not (gen / name).is_file()]
    if missing:
        return "missing " + ", ".join(missing)
    words = (gen / "spellless.words").read_text(encoding="utf-8").count("\n")
    sizes = {
        "weights": (gen / "spellless.weights").stat().st_size,
        "alpha": (gen / "spellless.alpha").stat().st_size // 3,
        "skel": (gen / "spellless.skel").stat().st_size // 3,
    }
    wrong = {k: v for k, v in sizes.items() if v != words}
    if wrong:
        return f"{words} words but " + ", ".join(f"{v} {k}" for k, v in wrong.items())
    return None


def copy_payload(user_dir: Path, dry_run: bool) -> list[Path]:
    written = []
    for src_rel, dst_rel in PAYLOAD:
        src = REPO / src_rel
        dst = user_dir / dst_rel
        if src_rel.endswith("/"):
            if not src.is_dir():
                raise SystemExit(f"missing {src}; run the build scripts first")
            for item in sorted(src.iterdir()):
                if item.is_file():
                    target = dst / item.name
                    print(f"  {item.relative_to(REPO)} -> {target}")
                    if not dry_run:
                        target.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(item, target)
                    written.append(target)
        else:
            if not src.is_file():
                raise SystemExit(f"missing {src}; run the build scripts first")
            print(f"  {src.relative_to(REPO)} -> {dst}")
            if not dry_run:
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, dst)
            written.append(dst)
    stamp = stamp_version(user_dir, dry_run)
    if stamp:
        written.append(stamp)
    return written


def git(*args: str) -> str | None:
    """Run git in the repository, or None if it is not available."""
    try:
        out = subprocess.run(["git", "-C", str(REPO), *args],
                             capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    return out.stdout.strip() if out.returncode == 0 else None


def stamp_version(user_dir: Path, dry_run: bool) -> Path | None:
    """Overwrite the deployed version.lua with what this build actually is.

    Deliberately a Lua module rather than a data file.  A data file would be
    re-read on demand and would report the version on disk; a module reports
    the version the running process loaded, which is the only one that answers
    "am I testing what I think I am testing".  See rime/lua/spellless/version.lua.
    """
    revision = git("describe", "--always", "--dirty", "--exclude", "*") or "unknown"
    built = git("log", "-1", "--format=%cs") or "unknown"
    installed = datetime.now().strftime("%Y-%m-%d %H:%M")
    text = (
        "-- Generated by scripts/install.py.  Do not edit; see the copy in the\n"
        "-- repository for why this is a module and not a data file.\n"
        "return {\n"
        f"  revision  = {revision!r},\n"
        f"  built     = {built!r},\n"
        f"  installed = {installed!r},\n"
        "}\n"
    ).replace("'", '"')
    dst = user_dir / "lua" / "spellless" / "version.lua"
    print(f"  stamping {revision} installed {installed} -> {dst}")
    if not dry_run:
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_text(text, encoding="utf-8")
    return dst


# ---------------------------------------------------------------------------
# enabling the schema
# ---------------------------------------------------------------------------

TEMPLATE = """# Rime user settings
# Created by Spellless (scripts/install.py).

patch:
  # "/+" appends to the schema list that default.yaml already defines.
  # Writing `schema_list:` instead would REPLACE it and hide your other
  # schemas, which is why this file uses the append form.
  "schema_list/+":
    - schema: spellless
"""

SNIPPET = """patch:
  "schema_list/+":
    - schema: spellless
"""

PATCH_ENTRY = '  "schema_list/+":\n    - schema: spellless\n'


def _looks_empty(text: str) -> bool:
    return all(not line.strip() or line.lstrip().startswith("#")
               for line in text.splitlines())


TIMESTAMP_LINE = re.compile(r"^(\s+[A-Za-z0-9_.]+:\s*)([0-9]+)\s*$")


def invalidate_build(user_dir: Path, dry_run: bool) -> int:
    """Mark the compiled config stale so the next deploy rebuilds it.

    Rime skips rebuilding a schema whose recorded source timestamps still match,
    and it records them inside the built file itself.  Editing a source is
    therefore not always enough -- a deploy can report success and rebuild
    nothing.

    The obvious workaround, deleting `build/`, is a trap: while it is missing a
    running Rime falls back to the *shared* default.yaml, finds every schema
    that ships with Weasel, and asks the user to pick one.  Zeroing the recorded
    timestamps instead means the tree is never without a schema list.
    """
    build = user_dir / "build"
    if not build.is_dir():
        return 0
    touched = 0
    for path in sorted(build.glob("*.yaml")):
        text = path.read_text(encoding="utf-8", errors="replace")
        out, inside, changed = [], False, False
        for line in text.splitlines():
            if line.strip() == "timestamps:":
                inside = True
            elif inside and not line.startswith(" "):
                inside = False
            if inside:
                m = TIMESTAMP_LINE.match(line)
                if m and m.group(2) != "0":
                    line = m.group(1) + "0"
                    changed = True
            out.append(line)
        if changed:
            touched += 1
            print(f"  marking stale: {path.name}")
            if not dry_run:
                _write(path, "\n".join(out) + "\n")
    return touched


def pin_schema(user_dir: Path, dry_run: bool) -> None:
    """Record Spellless as the chosen schema.

    Without this the choice is only made the first time, and any moment when
    the schema list looks different -- a half-finished deploy, a stale build --
    puts the schema menu in front of the user again.
    """
    path = user_dir / "user.yaml"
    text = path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""
    if re.search(r"^\s*previously_selected_schema:\s*spellless\s*$", text, re.M):
        return
    print(f"  pinning spellless in {path.name}")
    if dry_run:
        return
    if re.search(r"^\s*previously_selected_schema:", text, re.M):
        text = re.sub(r"^(\s*previously_selected_schema:).*$",
                      r"\1 spellless", text, flags=re.M)
    elif re.search(r"^var:\s*$", text, re.M):
        text = re.sub(r"^var:\s*$", "var:\n  previously_selected_schema: spellless",
                      text, count=1, flags=re.M)
    else:
        text = (text.rstrip("\n") + "\n" if text.strip() else "")
        text += "var:\n  previously_selected_schema: spellless\n"
    _write(path, text)


def enable_schema(user_dir: Path, dry_run: bool) -> None:
    """Add the schema to default.custom.yaml without disturbing anything else.

    Rewriting the file through a YAML library would silently drop the user's
    comments and formatting, so this only ever inserts lines -- and when the
    file has a shape we are not confident about, it prints what to add instead
    of guessing.  The entry uses Rime's "/+" append operator so an existing
    schema_list in default.yaml keeps all of its entries.
    """
    path = user_dir / "default.custom.yaml"

    if not path.exists() or _looks_empty(path.read_text(encoding="utf-8")):
        print(f"  writing {path}")
        if not dry_run:
            if path.exists():
                _backup(path, dry_run)
            _write(path, TEMPLATE)
        return

    text = path.read_text(encoding="utf-8-sig")
    if re.search(rf"^\s*-\s*schema:\s*{SCHEMA_ID}\s*$", text, re.M):
        print(f"  {path} already lists the schema")
        return

    if re.search(r"^\s+[\"']?schema_list", text, re.M):
        print(f"\n  {path} already patches schema_list, so it is left untouched.")
        print("  Add this entry to that list by hand:\n")
        print("      - schema: spellless\n")
        return

    # A trailing comment is legal after the key, and missing it used to send us
    # down the append branch below -- which produced a *second* top-level
    # `patch:`, and yaml-cpp keeps the last one, silently discarding whatever
    # the user had configured.
    # A BOM, or a quoted key, still means `patch`.  Missing either sent us to
    # the append branch, which wrote a *second* top-level key -- and yaml-cpp
    # keeps the last one, silently discarding the user's settings.
    m = re.search(r"""^["']?patch["']?:[ \t]*(#.*)?$""", text, re.M)
    if m:
        insert_at = m.end()
        # Match the file's own indentation: a four-space mapping would
        # otherwise end up with a two-space sibling, which is not valid YAML.
        following = re.search(r"^(\s+)\S", text[insert_at:], re.M)
        indent = following.group(1).lstrip("\n") if following else "  "
        entry = f'{indent}"schema_list/+":\n{indent}{indent}- schema: {SCHEMA_ID}\n'
        # Do not assume a newline follows: a file ending in a bare "patch:"
        # would otherwise get the entry appended to that same line.
        if text[insert_at:insert_at + 1] == "\n":
            insert_at += 1
            new_text = text[:insert_at] + entry + text[insert_at:]
        else:
            new_text = text[:insert_at] + "\n" + entry + text[insert_at:]
    elif re.search(r"""^["']?patch\b""", text, re.M):
        print(f"\n  {path} has a `patch` key this script cannot safely edit.")
        print("  Add this entry to it by hand:\n")
        print('      "schema_list/+":\n        - schema: spellless\n')
        return
    else:
        sep = "" if text.endswith("\n") else "\n"
        new_text = text + sep + "\n" + SNIPPET

    if not _parses(new_text, text):
        print(f"\n  editing {path} would not have produced valid YAML, so it was")
        print("  left alone.  Add this by hand:\n")
        print("      " + SNIPPET.replace("\n", "\n      ").rstrip())
        return

    print(f"  adding the schema to {path}")
    if not dry_run:
        _backup(path, dry_run)
        _write(path, new_text)


def _write(path: Path, text: str) -> None:
    """Write with LF endings.  Path.write_text grew `newline` only in 3.10."""
    with path.open("w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)


def _parses(text: str, before: str | None = None) -> bool:
    """Check the edit produced valid YAML that kept everything it started with.

    PyYAML is not a dependency; when it is absent we fall back to a structural
    check, because "no validator available" must not mean "any edit allowed".
    """
    # Whether or not a parser is available: never leave two top-level patch keys.
    if len(re.findall(r"""^["']?patch["']?:""", text, re.M)) > 1:
        return False
    try:
        import yaml
    except ImportError:
        return True
    try:
        loaded = yaml.safe_load(text)
    except yaml.YAMLError:
        return False
    if loaded is not None and not isinstance(loaded, dict):
        return False
    if before is not None:
        try:
            old = yaml.safe_load(before)
        except yaml.YAMLError:
            return True
        if isinstance(old, dict) and isinstance(old.get("patch"), dict):
            kept = (loaded or {}).get("patch")
            if not isinstance(kept, dict):
                return False
            for key in old["patch"]:
                if key not in kept:
                    return False
    return True


def _backup(path: Path, dry_run: bool) -> None:
    backup = path.with_suffix(path.suffix + f".bak-{time.strftime('%Y%m%d-%H%M%S')}")
    print(f"  backup: {backup}")
    if not dry_run:
        shutil.copy2(path, backup)


def uninstall(user_dir: Path, dry_run: bool) -> None:
    for _, dst_rel in PAYLOAD:
        dst = user_dir / dst_rel
        if dst_rel.endswith("/"):
            if dst.is_dir():
                print(f"  removing {dst}")
                if not dry_run:
                    shutil.rmtree(dst)
        elif dst.is_file():
            print(f"  removing {dst}")
            if not dry_run:
                dst.unlink()
    print("\nLeft alone on purpose:")
    print(f"  {user_dir / 'default.custom.yaml'}   (remove the schema entry by hand)")
    print(f"  {user_dir / 'spellless_user.txt'}    (your learned vocabulary)")


# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--user-dir", help="Rime user directory (auto-detected otherwise)")
    ap.add_argument("--dry-run", action="store_true", help="print actions, change nothing")
    ap.add_argument("--skip-dir", metavar="DIR",
                    help=f"write {SKIP_MARKER} into DIR so future installs "
                         "leave it alone, then stop")
    ap.add_argument("--no-enable", action="store_true",
                    help="do not touch default.custom.yaml")
    ap.add_argument("--uninstall", action="store_true")
    ap.add_argument("--list-candidates", action="store_true",
                    help="show every directory that was considered")
    args = ap.parse_args()

    if args.list_candidates:
        for path, why in candidate_user_dirs():
            state = "[exists] " if safe_is_dir(path) else "[missing]"
            if (path / SKIP_MARKER).is_file():
                state = "[skipped]"
            print(f"{state} {path}   ({why})")
        return 0

    if args.skip_dir:
        target = Path(args.skip_dir).expanduser()
        if not safe_is_dir(target):
            print(f"{target} is not a directory.")
            return 1
        marker = target / SKIP_MARKER
        if args.dry_run:
            print(f"would write {marker}")
        else:
            marker.write_text(SKIP_TEXT, encoding="utf-8")
            print(f"wrote {marker}")
        print("Future installs will leave that directory alone; --user-dir still works.")
        return 0

    # Every directory that exists, not just the best guess.
    #
    # This machine runs two Weasel-family frontends side by side, each with its
    # own user directory, and installing into only the first one silently left
    # the other running a build from the previous day -- for a whole session,
    # while both of us read the changes as having no effect.  Keeping them in
    # sync costs a directory copy; not keeping them in sync costs an afternoon.
    if args.user_dir:
        targets = [(Path(args.user_dir).expanduser(), "given on the command line")]
    else:
        targets = [(p, why) for p, why in candidate_user_dirs() if safe_is_dir(p)]
        # Named explicitly, a skipped directory is still installed into: the
        # marker is there to keep the *automatic* sweep out, not to argue with
        # someone who typed the path.
        skipped = [(p, why) for p, why in targets if (p / SKIP_MARKER).is_file()]
        targets = [(p, why) for p, why in targets if (p, why) not in skipped]
        for path, _ in skipped:
            print(f"Skipping {path}   ({SKIP_MARKER} is there)")
        if skipped:
            print()

    if not targets:
        path, why = resolve_user_dir(None)
        print(f"No Rime user directory found (best guess: {path}, {why}).")
        print("Start Weasel once (or pass --user-dir) so the directory is created.")
        return 1

    print("Installing into:")
    for path, why in targets:
        print(f"  {path}   ({why})")
    print()

    if args.uninstall:
        for path, _ in targets:
            uninstall(path, args.dry_run)
        return 0

    problem = check_payload()
    if problem:
        print(f"generated/ is not a complete build: {problem}")
        print("Run `make` (or scripts/build_dictionary.py then build_indexes.py) first.")
        return 1

    for user_dir, why in targets:
        print(f"=== {user_dir} ===")
        print("Copying:")
        copy_payload(user_dir, args.dry_run)

        if not args.no_enable:
            print("\nEnabling the schema:")
            enable_schema(user_dir, args.dry_run)

        print("\nPreparing the next deploy:")
        pin_schema(user_dir, args.dry_run)
    if not invalidate_build(user_dir, args.dry_run):
        print("  nothing built yet, so nothing to mark stale")

    print("""
Next:
  1. Right-click the Weasel tray icon and choose the redeploy entry
     (Chinese builds: 「重新部署」), or run WeaselDeployer.exe /deploy.
  2. Press F4 (or Control+grave) and pick "Spellless".

Do not delete the `build` directory to force a rebuild: while it is gone,
Rime falls back to the schema list that ships with Weasel and asks you to
choose one.  This script marks the build stale instead.

If no candidates appear, open %APPDATA%\\Rime\\rime.log (or the newest
rime.*.log next to it) and look for lines mentioning "spellless".""")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
