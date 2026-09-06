"""Shared helpers for the offline build scripts.

The *only* piece of logic in here that must stay bit-identical with the Lua
runtime is `skeleton()`.  `generated/spellless.skel` is a permutation of word
ids sorted by the skeleton string, and the Lua side binary-searches that
permutation while recomputing skeletons on the fly.  If the two definitions
ever diverge the binary search silently returns wrong ranges, so
`tests/test_skeleton.lua` re-verifies the ordering against the generated file.
"""

from __future__ import annotations

import hashlib
import struct
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

VOWELS = frozenset("aeiou")


def skeleton(word: str) -> str:
    """Consonant skeleton of `word`.

    Rules (documented in DESIGN.md):
      * drop a e i o u
      * keep 'y' -- it is consonantal about as often as it is vocalic, and
        typists writing an abbreviation almost always keep it ("systm", "typlgy")
      * always keep the first character, even when it is a vowel, because
        people do not drop a leading vowel ("about" -> "abt", not "bt")
      * everything else (digits, apostrophes) is kept verbatim
    """
    if not word:
        return word
    tail = [c for c in word[1:] if c not in VOWELS]
    return word[0] + "".join(tail)


def pack_u24(values) -> bytes:
    """Little-endian 3-byte-per-entry array; word ids are 1-based."""
    out = bytearray()
    for v in values:
        if not 0 <= v < 1 << 24:
            raise ValueError(f"value {v} does not fit in u24")
        out += struct.pack("<I", v)[:3]
    return bytes(out)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def _report(path: Path) -> str:
    """How to name a written file in the build log.

    Relative to the repository when it is inside it, which is the usual case
    and much easier to read; absolute otherwise, because an output directory
    elsewhere (a held-out test set in a scratch directory, say) is legitimate
    and must not make the writer throw.
    """
    try:
        return str(path.relative_to(REPO))
    except ValueError:
        return str(path)


def write_bytes(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    print(f"  wrote {_report(path)}  ({len(data):,} bytes)")


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    # newline='\n' so the generated files are byte-identical on Windows.
    with path.open("w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
    print(f"  wrote {_report(path)}  ({path.stat().st_size:,} bytes)")
