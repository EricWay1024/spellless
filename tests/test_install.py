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
