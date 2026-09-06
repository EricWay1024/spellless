#!/usr/bin/env python3
"""Tests for the offline half: the installer and the build outputs.

    python3 tests/test_install.py

`scripts/install.py` writes into a live Rime directory and edits a file the
user owns, and it had no coverage at all until an audit found two ways it could
corrupt a valid `default.custom.yaml`.  These run it against a scratch
directory instead.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

FAILURES: list[str] = []
CHECKS = 0


def check(condition: bool, what: str) -> None:
    global CHECKS
    CHECKS += 1
    if not condition:
        FAILURES.append(what)
        print(f"  FAIL {what}")


def run_installer(user_dir: Path, *extra: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(REPO / "scripts" / "install.py"),
         "--user-dir", str(user_dir), *extra],
        capture_output=True, text=True, cwd=REPO)


def load_yaml(text: str):
    try:
        import yaml
    except ImportError:
        return "no-pyyaml"
    return yaml.safe_load(text)


# ---------------------------------------------------------------------------

print("install: default.custom.yaml shapes")

SHAPES = {
    # name: (existing content, keys that must survive)
    "absent": (None, []),
    "empty": ("", []),
    "comments only": ("# nothing yet\n", []),
    "normal": ("# mine\npatch:\n  menu/page_size: 9\n", ["menu/page_size"]),
    # A file ending in a bare `patch:` with no trailing newline: appending on
    # that same line produced invalid YAML.
    "bare patch, no newline": ("patch:", []),
    # A comment after the key used to miss the regex, which appended a *second*
    # top-level `patch:` -- and yaml-cpp keeps the last one, so the user's
    # settings vanished.
    "patch with comment": ("patch: # my settings\n  ascii_composer/good_old_caps_lock: true\n",
                           ["ascii_composer/good_old_caps_lock"]),
    "no patch key": ("switcher:\n  caption: hi\n", []),
    # A byte-order mark, a quoted key, and four-space indentation are all legal
    # and all used to miss the regex, sending the edit to the append branch --
    # which wrote a second top-level `patch:` that yaml-cpp resolves in favour
    # of the last one, silently discarding the user's settings.
    "byte-order mark": ("\ufeffpatch:\n  menu/page_size: 9\n", ["menu/page_size"]),
    "quoted key": ('"patch":\n  menu/page_size: 9\n', ["menu/page_size"]),
    "four-space indent": ("patch:\n    menu/page_size: 9\n", ["menu/page_size"]),
}

for name, (content, survivors) in SHAPES.items():
    with tempfile.TemporaryDirectory() as tmp:
        user_dir = Path(tmp)
        target = user_dir / "default.custom.yaml"
        if content is not None:
            target.write_text(content, encoding="utf-8")
        run_installer(user_dir)
        text = target.read_text(encoding="utf-8-sig")
        parsed = load_yaml(text)
        if parsed == "no-pyyaml":
            continue
        check(isinstance(parsed, dict) and "patch" in parsed,
              f"{name}: result is a mapping with a patch key")
        patch = parsed.get("patch") if isinstance(parsed, dict) else None
        check(isinstance(patch, dict) and "schema_list/+" in patch,
              f"{name}: the schema was appended, not assigned")
        import re as _re
        check(len(_re.findall(r"""^["']?patch["']?:""", text, _re.M)) <= 1,
              f"{name}: exactly one top-level patch key")
        for key in survivors:
            check(isinstance(patch, dict) and key in patch,
                  f"{name}: kept the user's {key}")

print("install: a file it should not touch")
with tempfile.TemporaryDirectory() as tmp:
    user_dir = Path(tmp)
    target = user_dir / "default.custom.yaml"
    original = "patch:\n  schema_list:\n    - schema: luna_pinyin\n"
    target.write_text(original, encoding="utf-8")
    result = run_installer(user_dir)
    check(target.read_text(encoding="utf-8") == original,
          "an existing schema_list patch is left exactly as it was")
    check("by hand" in result.stdout, "and it says what to add instead")

print("install: the icon the schema names is one it copies")
with tempfile.TemporaryDirectory() as tmp:
    user_dir = Path(tmp)
    run_installer(user_dir)
    schema = (REPO / "rime" / "spellless.schema.yaml").read_text(encoding="utf-8")
    named = [line.split(":", 1)[1].strip().strip('"')
             for line in schema.splitlines() if line.strip().startswith("icon:")]
    check(len(named) == 1, "the schema names exactly one icon")
    # Weasel resolves schema/icon against the user directory, so a schema that
    # names a file the installer does not write shows Weasel's own icon and
    # says nothing about why.
    for name in named:
        check((user_dir / name).is_file(), f"{name} is installed where Weasel looks")
        check((user_dir / name).read_bytes()[:4] == b"\x00\x00\x01\x00",
              f"{name} is an .ico Weasel can load")

print("install: a directory can be left out of the sweep")
with tempfile.TemporaryDirectory() as tmp:
    import install as installer
    kept, skipped = Path(tmp) / "kept", Path(tmp) / "skipped"
    kept.mkdir(); skipped.mkdir()
    result = subprocess.run(
        [sys.executable, str(REPO / "scripts" / "install.py"), "--skip-dir", str(skipped)],
        capture_output=True, text=True, cwd=REPO)
    marker = skipped / installer.SKIP_MARKER
    check(result.returncode == 0 and marker.is_file(), "--skip-dir writes the marker")
    check("Delete this file" in marker.read_text(encoding="utf-8"),
          "and the marker says how to undo it")
    # Named on the command line it is still installed into: the marker keeps
    # the automatic sweep out, rather than arguing with someone who typed the
    # path.
    run_installer(skipped)
    check((skipped / "spellless.schema.yaml").is_file(),
          "an explicit --user-dir overrules the marker")

print("install: it is idempotent")
with tempfile.TemporaryDirectory() as tmp:
    user_dir = Path(tmp)
    run_installer(user_dir)
    first = (user_dir / "default.custom.yaml").read_text(encoding="utf-8")
    run_installer(user_dir)
    check((user_dir / "default.custom.yaml").read_text(encoding="utf-8") == first,
          "running it twice changes nothing the second time")

print("install: it refuses an incomplete build")
with tempfile.TemporaryDirectory() as tmp:
    import shutil
    fake = Path(tmp) / "repo"
    shutil.copytree(REPO, fake, ignore=shutil.ignore_patterns(".git", "__pycache__"))
    (fake / "generated" / "spellless.alpha").write_bytes(b"too short")
    user_dir = Path(tmp) / "rime"
    user_dir.mkdir()
    result = subprocess.run(
        [sys.executable, str(fake / "scripts" / "install.py"), "--user-dir", str(user_dir)],
        capture_output=True, text=True, cwd=fake)
    check(result.returncode != 0, "a mismatched generated/ is a hard error")
    check(not (user_dir / "spellless.schema.yaml").exists(),
          "and nothing was copied into the Rime directory")

print("package: a release archive installs without git")
# The archive is what someone else actually gets, and it differs from a
# checkout in the one way that matters here: no git.  The version stamp has to
# survive that, or `zzver` -- whose entire job is saying what is running --
# reports "unknown" to every user who did not clone the repository.
import zipfile

with tempfile.TemporaryDirectory() as tmp:
    out = Path(tmp) / "dist"
    result = subprocess.run(
        [sys.executable, str(REPO / "scripts" / "package.py"),
         "--version", "9.9.9", "--out", str(out), "--allow-dirty"],
        capture_output=True, text=True, cwd=REPO)
    check(result.returncode == 0, f"package.py runs: {result.stderr[-300:]}")
    archive = out / "spellless-9.9.9.zip"
    check(archive.exists(), "it writes the archive it says it does")

    if archive.exists():
        unpacked = Path(tmp) / "unpacked"
        with zipfile.ZipFile(archive) as zf:
            names = zf.namelist()
            zf.extractall(unpacked)
        for needed in ("spellless-9.9.9/scripts/install.py",
                       "spellless-9.9.9/rime/spellless.schema.yaml",
                       "spellless-9.9.9/generated/spellless.words",
                       "spellless-9.9.9/README.md",
                       "spellless-9.9.9/LICENSE"):
            check(needed in names, f"the archive carries {needed}")

        root = unpacked / "spellless-9.9.9"
        stamped = (root / "rime/lua/spellless/version.lua").read_text(encoding="utf-8")
        check('"9.9.9"' in stamped, "and version.lua names the release")

        # No git here: the archive is not a repository, and the temp directory
        # it is unpacked into is not inside one either.
        user_dir = Path(tmp) / "rime"
        user_dir.mkdir()
        result = subprocess.run(
            [sys.executable, str(root / "scripts" / "install.py"),
             "--user-dir", str(user_dir)],
            capture_output=True, text=True, cwd=tmp)
        check(result.returncode == 0, f"it installs: {result.stderr[-300:]}")
        installed = user_dir / "lua" / "spellless" / "version.lua"
        text = installed.read_text(encoding="utf-8") if installed.exists() else ""
        check('"9.9.9"' in text,
              f"and the release version survives the install: {text!r}")
        check("unknown" not in text, "rather than being overwritten with 'unknown'")

print("package: a checkout without git still admits it does not know")
import install as installer
check(installer.read_stamped_version(REPO / "rime/lua/spellless/version.lua") is None,
      "the repository's own version.lua is not mistaken for a release")

print("build: the shipped generated/ is internally consistent")
gen = REPO / "generated"
words = gen / "spellless.words"
if words.exists():
    n = words.read_text(encoding="utf-8").count("\n")
    check((gen / "spellless.weights").stat().st_size == n, "one weight byte per word")
    check((gen / "spellless.alpha").stat().st_size == n * 3, "one alpha entry per word")
    check((gen / "spellless.skel").stat().st_size == n * 3, "one skeleton entry per word")
    check(b"\r" not in words.read_bytes(), "the word list has no carriage returns")

print(f"\n{CHECKS} checks, {len(FAILURES)} failures")
sys.exit(1 if FAILURES else 0)
