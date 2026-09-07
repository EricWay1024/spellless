#!/usr/bin/env python3
"""Build the Spellless word list from the vendored frequency corpus.

Outputs (all under generated/):
    spellless.words     newline-separated words, most frequent first.
                        The 1-based line number is the word id used everywhere else.
    spellless.weights   one byte per word: log-frequency quantised into 0..255.
    spellless.forms     `word <TAB> surface form` for the handful of words the
                        lowercase corpus cannot spell (the pronoun "I").
    spellless.build.json  provenance: sources, hashes, counts, parameters.

Usage:
    python3 scripts/build_dictionary.py [--limit N] [--vocab-rank R]
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _common import REPO, sha256_file, write_bytes, write_text  # noqa: E402

SOURCE = REPO / "data" / "sources" / "frequency_dictionary_en_82_765.txt"
VOCAB_DIR = REPO / "data" / "vocab"
FORMS = REPO / "data" / "forms.txt"
OUT = REPO / "generated"

WORD_RE = re.compile(r"^[a-z]+$")
CONTRACTION_RE = re.compile(r"^[a-z]+'([a-z]+)$")
# Suffixes that make a real English contraction.  The corpus contains a couple
# of truncated artefacts ("you'v") that this rejects.
CONTRACTION_TAILS = {"t", "s", "d", "ll", "re", "ve", "m", "clock"}


def parse_frequency_list(path: Path) -> dict[str, int]:
    """Read `word <space> count` lines, keeping only plausible English tokens."""
    freqs: dict[str, int] = {}
    rejected = 0
    # utf-8-sig: the upstream file starts with a BOM.
    with path.open(encoding="utf-8-sig") as fh:
        for line in fh:
            parts = line.split()
            if len(parts) != 2:
                continue
            word, count = parts[0], int(parts[1])
            if not accept(word):
                rejected += 1
                continue
            freqs[word] = max(freqs.get(word, 0), count)
    print(f"  {path.name}: {len(freqs):,} accepted, {rejected} rejected")
    return freqs


def accept(word: str) -> bool:
    if WORD_RE.match(word):
        # Single letters other than the two real English ones are noise.
        return len(word) > 1 or word in ("a", "i")
    m = CONTRACTION_RE.match(word)
    return bool(m and m.group(1) in CONTRACTION_TAILS)


def parse_vocab_file(
    path: Path, default_freq: int, ranked: list[tuple[str, int]] | None = None
) -> tuple[dict[str, int], dict[str, str], set[str], bool]:
    """Read a supplemental plain-text vocabulary file.

    An entry written with capitals -- "Grothendieck", "TQFT" -- is indexed
    under its lowercase form and remembers the capitals as a surface form, so
    typing "grthndck" gives back "Grothendieck" rather than "grothendieck".

    The same rule carries multi-word entries.  The lookup key is the letters
    alone, so "Hong Kong" is typed as "hongkong" and "in front of" as
    "infrontof", and what lands in the document is the entry as written.  Rime
    commits a candidate whole, so a phrase costs exactly one selection -- and
    it goes through the same fuzzy matching as any other word, which is the
    point: "hongkong" is a thing you can misspell.

    A capitalised entry followed by "+" -- `RAM +`, `React +` -- keeps *both*
    spellings instead of replacing the lowercase one.  Use it whenever the
    lowercase word means something on its own: `ram` is an animal, `react` is a
    verb, and taking either away to gain an acronym is a bad trade.  Without
    the marker the capitals replace, which is what a name wants: nobody means
    `grothendieck` or `tqft`.

    The build cannot decide this for you and should not try.  Corpus rank
    looks like it would work -- `ram` is the 3,032nd word and `tqft` is absent
    -- but this corpus keeps proper nouns as ordinary lowercase tokens, so
    `africa` is the 1,500th word and would be classified alongside `ram`.
    """
    freqs: dict[str, int] = {}
    forms: dict[str, str] = {}
    lowercase: set[str] = set()
    file_freq = default_freq
    replaces = False
    with path.open(encoding="utf-8") as fh:
        for line in fh:
            # `#!rank N` says how common this file's words are, as a rank in the
            # base corpus.  Without it every supplemental word arrives at rank
            # 20,000, which is far too prominent for a list of place names: they
            # then outrank the ordinary words they are competing with, and the
            # cost lands on everything else being corrected.
            # `#!capitals replace` says every capital in this file is the only
            # spelling its key has.  For a file of names that is true by
            # definition, and the lowercase tokens the corpus holds for them
            # are an artefact of how it was built, not a reading anybody means.
            if re.match(r"^#!\s*capitals\s+replace\s*$", line.strip()):
                replaces = True
                continue
            directive = re.match(r"^#!\s*rank\s+(\d+)\s*$", line.strip())
            if directive and ranked:
                index = min(int(directive.group(1)), len(ranked)) - 1
                file_freq = ranked[index][1]
                continue
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split("\t")
            written = parts[0].strip()
            # The key is what you type: letters and apostrophes only, so spaces
            # and dots in the written form simply close up.
            word = re.sub(r"[^a-z']", "", written.lower())
            if not accept(word):
                print(f"    skipping unsupported entry {written!r} in {path.name}")
                continue
            freq = int(parts[1]) if len(parts) > 1 and parts[1].strip() else file_freq
            freqs[word] = max(freqs.get(word, 0), freq)
            if written != word:
                forms[word] = written
            elif not replaces:
                lowercase.add(word)
    return freqs, forms, (set() if replaces else lowercase), replaces


def _build_time() -> datetime:
    stamp = os.environ.get("SOURCE_DATE_EPOCH")
    if stamp and stamp.isdigit():
        return datetime.fromtimestamp(int(stamp), timezone.utc)
    return datetime.now(timezone.utc)


def parse_forms(path: Path) -> list[tuple[str, str]]:
    """Read `lookup key <TAB> surface form` lines."""
    if not path.exists():
        return []
    out = []
    with path.open(encoding="utf-8") as fh:
        for line in fh:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            key, _, display = line.partition("\t")
            key, display = key.strip().lower(), display.strip()
            if key and display:
                out.append((key, display))
    return out


def quantise_weights(freqs: list[int]) -> bytes:
    """Map log-frequency onto 0..255 so the Lua side needs no scaling constants."""
    logs = [math.log(f) for f in freqs]
    lo, hi = min(logs), max(logs)
    span = (hi - lo) or 1.0
    return bytes(min(255, max(0, round(255 * (v - lo) / span))) for v in logs)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--limit", type=int, default=0,
                    help="keep only the N most frequent words (0 = keep all)")
    ap.add_argument("--vocab-rank", type=int, default=20000,
                    help="supplemental words with no explicit frequency are given the "
                         "frequency of the base corpus word at this rank (default 20000)")
    ap.add_argument("--contraction-rank", type=int, default=500,
                    help="floor the frequency of apostrophe contractions at the frequency "
                         "of the base corpus word at this rank (default 2000); the corpus "
                         "under-counts them badly, see data/README.md")
    args = ap.parse_args()

    if not SOURCE.exists():
        print(f"missing {SOURCE}; run scripts/fetch_sources.py first", file=sys.stderr)
        return 1

    print("reading base corpus")
    freqs = parse_frequency_list(SOURCE)

    ranked = sorted(freqs.items(), key=lambda kv: (-kv[1], kv[0]))
    # Base-corpus ranks, before a single supplemental word is merged in.  Used
    # only to check the "+" markers below, never to infer them: this corpus
    # keeps proper nouns as lowercase tokens, so `africa` looks exactly as
    # common as `ram` and inferring from rank marks 371 entries, Africa among
    # them.  See data/README.md.
    base_rank = {w: i + 1 for i, (w, _) in enumerate(ranked)}
    default_freq = ranked[min(args.vocab_rank, len(ranked)) - 1][1]
    print(f"  supplemental default frequency = {default_freq:,} (rank {args.vocab_rank})")

    print("reading supplemental vocabulary")
    vocab_files = sorted(VOCAB_DIR.glob("*.txt"))
    added, promoted = 0, 0
    vocab_forms: dict[str, str] = {}
    written_lower: set[str] = set()
    replacing: set[str] = set()
    for path in vocab_files:
        extra, extra_forms, extra_lower, file_replaces = parse_vocab_file(
            path, default_freq, ranked)
        vocab_forms.update(extra_forms)
        written_lower |= extra_lower
        if file_replaces:
            replacing |= set(extra_forms)
        for word, freq in extra.items():
            if word in freqs:
                if freq > freqs[word]:
                    freqs[word] = freq
                    promoted += 1
            else:
                freqs[word] = freq
                added += 1
        print(f"  {path.name}: {len(extra)} entries")
    # A capital joins the lowercase reading wherever there is one to join, and
    # replaces only where the key has never been written in lower case at all.
    # Looked up, not judged: `ram` and `africa` and `bloom` are base-corpus
    # tokens, `ml` is written as its own entry, and `tqft` is neither.
    additive = {k for k in vocab_forms
                if (k in base_rank or k in written_lower) and k not in replacing}
    print(f"  {added} new words, {promoted} promoted, "
          f"{len(vocab_forms)} carrying capitals "
          f"({len(additive)} of them beside a lowercase reading, "
          f"{len(vocab_forms) - len(additive)} replacing one that never existed)")

    # The corpus gives every contraction the same floor count, an artefact of
    # how it was tokenised rather than a fact about English: "don't" cannot
    # really be rarer than the 37,000th word.  Lift them to a plausible rank so
    # a dropped apostrophe finds them.
    ranked = sorted(freqs.items(), key=lambda kv: (-kv[1], kv[0]))
    contraction_floor = ranked[min(args.contraction_rank, len(ranked)) - 1][1]
    lifted = 0
    for word in freqs:
        if "'" in word and freqs[word] < contraction_floor:
            freqs[word] = contraction_floor
            lifted += 1
    print(f"  lifted {lifted} contractions to the rank-{args.contraction_rank} frequency "
          f"({contraction_floor:,})")

    # A contraction typed without its apostrophe, as an entry in its own right.
    #
    # Dropping the apostrophe is priced at 0.15 by the matcher, which is enough
    # on its own when nothing competes -- "dont" has only one reading.  It is
    # not enough when something does: "youll" is two dropped letters from "you",
    # and "you" is common enough, and selected often enough, to win.  Making the
    # bare spelling a real key settles it, because an exact match on an entry
    # that carries a written form is the strongest evidence this ranker has.
    #
    # Only where the bare spelling is not already a word.  "cant", "its",
    # "hes", "were", "wont", "ill" are all ordinary English, and turning them
    # into contractions would be the mistake data/forms.txt exists to warn
    # about -- the lowercase reading has to stay reachable.
    bare_added = 0
    bare_of: dict[str, str] = {}
    for word in list(freqs):
        if "'" not in word:
            continue
        bare = word.replace("'", "")
        if bare and bare not in freqs:
            freqs[bare] = freqs[word]
            bare_of[bare] = word
            bare_added += 1
    print(f"  {bare_added} contractions also reachable without the apostrophe")

    ranked = sorted(freqs.items(), key=lambda kv: (-kv[1], kv[0]))
    if args.limit:
        ranked = ranked[: args.limit]

    words = [w for w, _ in ranked]
    counts = [c for _, c in ranked]

    OUT.mkdir(exist_ok=True)
    write_text(OUT / "spellless.words", "\n".join(words) + "\n")
    write_bytes(OUT / "spellless.weights", quantise_weights(counts))

    known = set(words)
    # data/forms.txt is explicit and wins over capitals inferred from a vocab
    # entry, so it goes in last.
    surface = dict(vocab_forms)
    explicit = set()
    for key, display in parse_forms(FORMS):
        explicit.add(key)
    for key, display in parse_forms(FORMS):
        if key not in known:
            print(f"    warning: forms.txt lists {key!r}, which is not in the dictionary")
            continue
        surface[key] = display
    # Resolved last, so a bare contraction shows whatever its apostrophe form
    # finally shows: "ive" commits "I've", not "i've".
    for bare, word in bare_of.items():
        surface[bare] = surface.get(word, word)

    # "key <TAB> spelling" replaces the lowercase reading; a third field "+"
    # says to offer both.  Only vocabulary capitals can be additive: forms.txt
    # is by definition the list of words with no valid lowercase spelling, and
    # a bare contraction resolves to whatever its apostrophe form shows.
    forms = [f"{k}\t{surface[k]}" + ("\t+" if k in additive and k not in explicit
                                     and k not in bare_of else "")
             for k in sorted(surface) if k in known]
    write_text(OUT / "spellless.forms", "\n".join(forms) + "\n")

    manifest = {
        # SOURCE_DATE_EPOCH makes the manifest byte-reproducible too; the data
        # files themselves already are, with or without it.
        "generated_at": _build_time().isoformat(timespec="seconds"),
        "generator": "scripts/build_dictionary.py",
        "entries": len(words),
        "parameters": {"limit": args.limit, "vocab_rank": args.vocab_rank,
                       "supplemental_default_frequency": default_freq,
                       "contraction_rank": args.contraction_rank,
                       "contraction_floor_frequency": contraction_floor},
        "sources": [
            {
                "path": str(SOURCE.relative_to(REPO)),
                "sha256": sha256_file(SOURCE),
                "origin": "https://github.com/wolfgarbe/SymSpell"
                          " (SymSpell/frequency_dictionary_en_82_765.txt)",
                "licence": "MIT",
            },
            *[
                {"path": str(p.relative_to(REPO)), "sha256": sha256_file(p),
                 "origin": "this repository", "licence": "MIT"}
                for p in [*vocab_files, *( [FORMS] if FORMS.exists() else [] )]
            ],
        ],
    }
    write_text(OUT / "spellless.build.json", json.dumps(manifest, indent=2) + "\n")
    print(f"done: {len(words):,} entries")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
