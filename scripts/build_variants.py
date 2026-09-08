#!/usr/bin/env python3
"""Derive the spelling-variant groups from VarCon.

    python3 scripts/build_variants.py   # -> generated/spellless.variants

VarCon tags every spelling of a word with the dialects that prefer it.  This
reads those tags, applies VarCon's own inheritance rules, and writes one line
per variant group naming, for each member, the modes in which it is the
spelling you would actually write.

The runtime hides a member in a mode when that mode is absent from its list,
and offers the member that does carry the mode in its place.  A word that is
correct everywhere -- `program`, `advertise`, `practice` -- carries every mode
and is therefore never hidden; see docs/proposals/spelling-variants.md §4.

Output format, one group per line, members separated by tabs:

    10<TAB>color|us<TAB>colour|gb-ise,gb-ize

The leading field is VarCon's SCOWL level for the group: 10 is the commonest
band and 95 the rarest.  It is the quality signal that keeps rarities out of
the dictionary when a missing member is added.

Nothing here decides frequency; that is scripts/build_dictionary.py.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VARCON = ROOT / "data" / "sources" / "varcon.txt"
FREQ = ROOT / "data" / "sources" / "frequency_dictionary_en_82_765.txt"
VOCAB_DIR = ROOT / "data" / "vocab"
OUT = ROOT / "generated" / "spellless.variants"

# A tag is a spelling category with an optional variant indicator.  The
# categories we use are A (American), B (British -ise) and Z (British -ize /
# OED); C and D are Canadian and Australian, parsed so that the inheritance
# rules below can see them, but not yet exposed as modes.
TAG_RE = re.compile(r"^([ABZCD_])([.vV\-x]?)$")

# Only a bare tag, or the "equal" indicator, means "this is what you write".
# v/V/-/x are variants of decreasing respectability and are all hideable.
PREFERRED = ("", ".")

CATEGORY_MODE = {"A": "us", "B": "gb-ise", "Z": "gb-ize"}
MODES = ("us", "gb-ise", "gb-ize")


def parse_line(line: str) -> list[tuple[str, dict[str, str]]]:
    """One varcon line -> [(word, {category: indicator})].  [] if not a mapping."""
    line = line.split("|", 1)[0]                  # drop sense/column markers
    line = re.split(r"\s#", line, maxsplit=1)[0].strip()   # drop trailing notes
    if not line:
        return []
    out: list[tuple[str, dict[str, str]]] = []
    for part in line.split(" / "):
        if ": " not in part:
            return []
        tags_str, word = part.split(": ", 1)
        word = word.strip()
        if not word:
            return []
        tags: dict[str, str] = {}
        for tok in tags_str.split():
            if tok.isdigit():                      # a column number, not a tag
                continue
            m = TAG_RE.match(tok)
            if not m:
                return []
            cat, ind = m.group(1), m.group(2)
            # Keep the best indicator seen for a category on this line.
            if cat not in tags or _rank(ind) < _rank(tags[cat]):
                tags[cat] = ind
        out.append((word, tags))
    return out


def _rank(ind: str) -> int:
    return {"": 0, ".": 1, "v": 2, "V": 3, "-": 4, "x": 5}.get(ind, 9)


def apply_inheritance(entries: list[tuple[str, dict[str, str]]]) -> None:
    """VarCon README: no Z on the line => B implies Z; no C => Z implies C;
    no D => B implies D.  Mutates the tag dicts in place."""
    present = {cat for _, tags in entries for cat in tags}
    for _, tags in entries:
        if "Z" not in present and "B" in tags:
            tags["Z"] = tags["B"]
    present = {cat for _, tags in entries for cat in tags}
    for _, tags in entries:
        if "C" not in present and "Z" in tags:
            tags["C"] = tags["Z"]
        if "D" not in present and "B" in tags:
            tags["D"] = tags["B"]


class Union:
    """Union-find over words, so that the noun and verb lines of `program`
    end up in one group."""

    def __init__(self) -> None:
        self.parent: dict[str, str] = {}

    def find(self, x: str) -> str:
        self.parent.setdefault(x, x)
        while self.parent[x] != x:
            self.parent[x] = self.parent[self.parent[x]]
            x = self.parent[x]
        return x

    def union(self, a: str, b: str) -> None:
        ra, rb = self.find(a), self.find(b)
        if ra != rb:
            self.parent[rb] = ra


def known_words() -> set[str]:
    """Everything the dictionary could contain, so that groups about words we
    do not ship are left out."""
    words: set[str] = set()
    with FREQ.open(encoding="utf-8-sig") as fh:
        for line in fh:
            tok = line.split(" ", 1)[0].strip().lower()
            if tok:
                words.add(tok)
    for path in sorted(VOCAB_DIR.glob("*.txt")):
        for line in path.read_text(encoding="utf-8").splitlines():
            tok = line.split("#", 1)[0].strip().lower()
            if tok:
                words.add(tok.split("\t", 1)[0])
    return words


def main() -> int:
    known = known_words()
    uf = Union()
    # word -> set of modes in which it is the preferred spelling
    used: dict[str, set[str]] = {}

    level_of: dict[str, int] = {}
    level = 99
    for raw in VARCON.read_text(encoding="latin-1").splitlines():
        if raw.startswith("#"):
            m = re.search(r"\(level (\d+)\)", raw)
            level = int(m.group(1)) if m else 99
            continue
        if not raw:
            continue
        entries = parse_line(raw)
        if len(entries) < 2:
            continue
        apply_inheritance(entries)
        words = [w for w, _ in entries]
        for w in words[1:]:
            uf.union(words[0], w)
        for word, tags in entries:
            level_of[word] = min(level_of.get(word, 99), level)
            slot = used.setdefault(word, set())
            for cat, ind in tags.items():
                if cat in CATEGORY_MODE and ind in PREFERRED:
                    slot.add(CATEGORY_MODE[cat])

    groups: dict[str, set[str]] = {}
    for word in used:
        groups.setdefault(uf.find(word), set()).add(word)

    lines: list[str] = []
    for members in groups.values():
        # A group is only interesting if we ship one of its members and the
        # members actually differ in where they are written; otherwise nothing
        # would ever be hidden.
        if not any(w in known for w in members):
            continue
        tagged = {w: used.get(w, set()) for w in members}
        if len({frozenset(v) for v in tagged.values()}) < 2:
            continue
        if not any(v for v in tagged.values()):
            continue
        fields = [
            f"{w}|{','.join(m for m in MODES if m in tagged[w]) or '-'}"
            for w in sorted(members)
        ]
        lvl = min(level_of.get(w, 99) for w in members)
        lines.append(f"{lvl:02d}\t" + "\t".join(fields))

    lines.sort(key=lambda s: s.split("\t", 1)[1])
    OUT.write_text(
        "# Spelling-variant groups, from data/sources/varcon.txt.\n"
        "# One group per line: SCOWL level, then word|modes-where-it-is-written.\n"
        "# A member is hidden in a mode absent from its list; '-' means it is\n"
        "# the preferred spelling nowhere and is hidden in every mode.\n"
        "# Generated by scripts/build_variants.py -- do not edit.\n"
        + "\n".join(lines)
        + "\n",
        encoding="utf-8",
    )
    print(f"variant groups:\n  wrote {OUT}  ({len(lines)} groups)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
