#!/usr/bin/env python3
"""Import a vocabulary pack into your personal word list.

    python3 scripts/import_pack.py topology china
    python3 scripts/import_pack.py --list
    python3 scripts/import_pack.py path/to/anything.txt --to /tmp/words.txt

Packs live in data/packs/ and are deliberately *not* built into the shipped
dictionary.  Topology terminology is excellent if you work on topology and
clutter if you do not; the same is true of provinces of China, of British
institutions, and of anything else that is a fact about the person typing
rather than about English.

The destination is `spellless_user.txt` in your Rime user directory -- the
same file the matcher already writes what you teach it into, read at startup,
hand-editable, and never overwritten by an upgrade.

Imported words arrive with a count of 4.  The count is what the matcher reads
as familiarity, and importing is a statement of intent -- more than "I typed
this once by accident", less than a habit.  It matters because names are short
and short names collide with ordinary English.  Measured over the topology
pack, counting how many of its 155 longer words lead the list when typed as
their own consonant skeleton, against what the same store costs 258 ordinary
English cases from tests/cases:

    count 1   106 first, 12 not on the first two pages    English 224/258
    count 2   120               10                                224/258
    count 4   126                7                                224/258
    count 8   131                5                                224/258

4 is where the pack's own curve flattens, and no count tested costs the
English anything at all -- these words do not compete with it.  The ones still
missing at 8 are genuinely ambiguous: `flr` is `floor` far more often than
`Floer`, whoever you are.  Use them and they climb, which is the whole job of
the personal store; `--count` if you disagree.

Importing is idempotent.  A word already in the file keeps whatever count it
has earned, because a pack should never undo your own history.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from install import resolve_user_dir  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
PACKS = REPO / "data" / "packs"
GENERATED = REPO / "generated"
STORE = "spellless_user.txt"


def dictionary_words() -> set[str]:
    """The shipped word list, or an empty set if it has not been built."""
    path = GENERATED / "spellless.words"
    return set(path.read_text(encoding="utf-8").split()) if path.exists() else set()


def respells(words: list[str], known: set[str]) -> list[str]:
    """Entries whose capitals change how a dictionary word is spelled.

    Reported, not refused, and no longer dangerous: the dictionary's own
    lowercase reading stays on the list one keystroke behind, so importing
    `Bloom` no longer costs you the flower.  Worth saying out loud all the
    same, because it changes what leads.
    """
    out = []
    for w in words:
        key = re.sub(r"[^a-z']", "", w.lower())
        if w != key and key in known and len(key) > 2:
            out.append(w)
    return out


def read_pack(path: Path) -> list[str]:
    """The written form of every entry, in file order.

    Understands the data/vocab format, which is what the packs are written in:
    `#` comments, a `#!rank` directive that means nothing here, an optional
    frequency column that does too -- a personal store counts selections, not
    corpus occurrences, and importing a frequency as a count would put a pack
    word above everything you have actually chosen.  A trailing `+` marks a
    capital that joins the lowercase word rather than replacing it; in a
    personal file that distinction does not exist, so it is dropped.
    """
    out: list[str] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        written = line.split("\t")[0].strip()
        if written.endswith("+"):
            written = written[:-1].strip()
        # The key is what you type: letters and apostrophes, so a phrase closes
        # up exactly as it does in the dictionary build.
        if not re.sub(r"[^a-z']", "", written.lower()):
            continue
        out.append(written)
    return out


def existing_words(store: Path) -> set[str]:
    if not store.exists():
        return set()
    keys = set()
    for line in store.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line or line.startswith("#") or line.startswith(">"):
            continue
        word = line.split("\t")[0].strip()
        if word:
            keys.add(re.sub(r"[^a-z']", "", word.lower()))
    return keys


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("packs", nargs="*", help="pack names, or paths to a word list")
    ap.add_argument("--list", action="store_true", help="show the packs available")
    ap.add_argument("--to", help="write here instead of the Rime user directory")
    ap.add_argument("--user-dir", help="Rime user directory, if it cannot be found")
    ap.add_argument("--count", type=int, default=4,
                    help="starting familiarity for imported words (default 4)")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    available = sorted(p.stem for p in PACKS.glob("*.txt"))
    if args.list or not args.packs:
        print("packs in data/packs/:")
        for name in available:
            entries = len(read_pack(PACKS / f"{name}.txt"))
            first = (PACKS / f"{name}.txt").read_text(encoding="utf-8").splitlines()
            note = next((l.lstrip("# ").strip() for l in first
                         if l.startswith("#") and not l.startswith("#!")), "")
            print(f"  {name:<12} {entries:>4} entries   {note}")
        print("\nimport one with: python3 scripts/import_pack.py <name>")
        return 0

    sources: list[Path] = []
    for name in args.packs:
        path = PACKS / f"{name}.txt"
        if not path.exists():
            path = Path(name)
        if not path.exists():
            print(f"no pack called {name!r}; try --list", file=sys.stderr)
            return 1
        sources.append(path)

    if args.to:
        store = Path(args.to)
        where = str(store)
    else:
        user_dir, how = resolve_user_dir(args.user_dir)
        store = user_dir / STORE
        where = f"{store}   ({how})"
    print(f"importing into {where}")

    known = dictionary_words()
    have = existing_words(store)
    lines: list[str] = []
    added = skipped = 0
    for path in sources:
        words = read_pack(path)
        new = [w for w in words if re.sub(r"[^a-z']", "", w.lower()) not in have]
        for w in new:
            have.add(re.sub(r"[^a-z']", "", w.lower()))
        # "word <TAB> count", or "word <TAB> spelling <TAB> count" when the
        # entry carries capitals -- the same two shapes the matcher writes.
        if new:
            lines.append(f"# --- {path.stem} ({len(new)} words)")
            for w in new:
                key = re.sub(r"[^a-z']", "", w.lower())
                lines.append(f"{key}\t{w}\t{args.count}" if w != key
                             else f"{key}\t{args.count}")
        added += len(new)
        skipped += len(words) - len(new)
        print(f"  {path.name}: {len(new)} new, {len(words) - len(new)} already there")
        changed = respells(new, known)
        if changed:
            print(f"    {len(changed)} of them respell a word the dictionary "
                  f"already has: " + ", ".join(changed[:8])
                  + (" ..." if len(changed) > 8 else ""))
            print("    They lead from now on; the dictionary's own reading is still")
            print("    there, one keystroke behind, and picking it twice makes it the")
            print("    default again.")

    if not lines:
        print("nothing to do")
        return 0
    if args.dry_run:
        print(f"would add {added} words")
        return 0

    store.parent.mkdir(parents=True, exist_ok=True)
    body = store.read_text(encoding="utf-8", errors="replace") if store.exists() else ""
    if body and not body.endswith("\n"):
        body += "\n"
    store.write_text(body + "\n".join(lines) + "\n", encoding="utf-8")
    print(f"added {added} words, left {skipped} alone")
    print("\nRestart the input method to pick them up, or they arrive at the next start.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
