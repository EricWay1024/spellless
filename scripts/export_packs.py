#!/usr/bin/env python3
"""Export every pack entry to one file, one per line, for review.

    python3 scripts/export_packs.py --out packs-review.txt

Section comments from the packs are kept, so it can be skimmed a group at a
time rather than a word at a time. Delete the lines you *want*; whatever is
left is the list of entries to remove, which `--remove` then applies:

    python3 scripts/export_packs.py --remove packs-review.txt

`--remove` rewrites data/packs/*.txt in place, keeping their comments and
their order, and prints what it took out of each.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PACKS = REPO / "data" / "packs"


def entries(path: Path) -> list[tuple[int, str]]:
    """(line number, written form) for every entry in a pack."""
    out = []
    for i, line in enumerate(path.read_text(encoding="utf-8").splitlines()):
        text = line.split("#", 1)[0].strip()
        if text:
            out.append((i, text))
    return out


def do_export(out_path: Path) -> int:
    lines: list[str] = [
        "# Every entry in data/packs/, one per line.",
        "#",
        "# Delete the lines you want to keep.  Whatever is still here when you are",
        "# done is the list of entries to remove, and",
        "#     python3 scripts/export_packs.py --remove <this file>",
        "# applies it.  Lines starting with # are ignored either way, so the",
        "# section headings below are only there to skim by.",
        "",
    ]
    total = 0
    for path in sorted(PACKS.glob("*.txt")):
        body = path.read_text(encoding="utf-8").splitlines()
        count = len(entries(path))
        total += count
        lines += ["", f"# ============ {path.stem}  ({count} entries) ============", ""]
        for line in body:
            stripped = line.strip()
            if stripped.startswith("# ---"):          # a section heading: keep it
                lines.append(stripped)
            elif stripped.startswith("#") or not stripped:
                continue
            else:
                lines.append(line.split("#", 1)[0].strip())
    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"wrote {out_path}  ({total} entries from {len(list(PACKS.glob('*.txt')))} packs)")
    return 0


def do_remove(list_path: Path) -> int:
    wanted = {line.split("#", 1)[0].strip().lower()
              for line in list_path.read_text(encoding="utf-8").splitlines()}
    wanted.discard("")
    if not wanted:
        print("nothing listed to remove", file=sys.stderr)
        return 1
    removed_total = 0
    for path in sorted(PACKS.glob("*.txt")):
        kept, removed = [], []
        for line in path.read_text(encoding="utf-8").splitlines():
            text = line.split("#", 1)[0].strip()
            if text and text.lower() in wanted:
                removed.append(text)
            else:
                kept.append(line)
        if removed:
            # Drop a section heading whose whole section has gone.
            out, i = [], 0
            while i < len(kept):
                line = kept[i]
                if line.strip().startswith("# ---"):
                    j = i + 1
                    while j < len(kept) and not kept[j].strip().startswith("# ---"):
                        if kept[j].split("#", 1)[0].strip():
                            break
                        j += 1
                    else:
                        i += 1
                        continue
                    if j < len(kept) and not kept[j].split("#", 1)[0].strip():
                        i += 1
                        continue
                out.append(line)
                i += 1
            path.write_text("\n".join(out).rstrip("\n") + "\n", encoding="utf-8")
            removed_total += len(removed)
            print(f"  {path.stem}: removed {len(removed)} -- "
                  + ", ".join(removed[:10]) + (" ..." if len(removed) > 10 else ""))
    print(f"removed {removed_total} entries; {len(wanted) - removed_total} listed "
          f"lines matched nothing")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default="packs-review.txt", help="where to write the list")
    ap.add_argument("--remove", metavar="FILE",
                    help="remove every entry listed in FILE from the packs")
    args = ap.parse_args()
    return do_remove(Path(args.remove)) if args.remove else do_export(Path(args.out))


if __name__ == "__main__":
    raise SystemExit(main())
