#!/usr/bin/env python3
"""Build the lookup permutations Spellless needs at runtime.

Sorting 80k strings inside Lua at every schema load would cost hundreds of
milliseconds, so the two orderings are precomputed here and shipped as flat
u24 arrays of word ids.  Everything else (length buckets, letter bitmasks) is
cheap enough for the Lua side to derive at load time.

Outputs (all under generated/):
    spellless.alpha   word ids sorted by (word)              -> prefix / exact lookup
    spellless.skel    word ids sorted by (skeleton, id)      -> consonant-skeleton lookup

Usage:
    python3 scripts/build_indexes.py
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _common import REPO, pack_u24, skeleton, write_bytes, write_text  # noqa: E402

OUT = REPO / "generated"


def load_words() -> list[str]:
    path = OUT / "spellless.words"
    if not path.exists():
        raise SystemExit("generated/spellless.words is missing; run build_dictionary.py first")
    return path.read_text(encoding="utf-8").split("\n")[:-1]


def main() -> int:
    words = load_words()
    n = len(words)
    print(f"indexing {n:,} words")

    # ids are 1-based line numbers, already in descending-frequency order, so
    # sorting by id as the secondary key keeps each bucket frequency-ordered.
    ids = range(1, n + 1)

    alpha = sorted(ids, key=lambda i: (words[i - 1], i))
    write_bytes(OUT / "spellless.alpha", pack_u24(alpha))

    skels = [skeleton(w) for w in words]
    skel = sorted(ids, key=lambda i: (skels[i - 1], i))
    write_bytes(OUT / "spellless.skel", pack_u24(skel))

    distinct = len(set(skels))
    print(f"  {distinct:,} distinct skeletons "
          f"({n / distinct:.2f} words per skeleton on average)")

    manifest_path = OUT / "spellless.build.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["indexes"] = {
        "alpha": {"entries": n, "encoding": "u24le"},
        "skel": {"entries": n, "encoding": "u24le", "distinct_skeletons": distinct},
    }
    write_text(manifest_path, json.dumps(manifest, indent=2) + "\n")
    print("done")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
