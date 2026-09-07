#!/usr/bin/env python3
"""Generate reproducible evaluation cases from the shipped dictionary.

Hand-written cases (tests/cases/*.tsv) say what the brief asks for; these
generated ones say how the matcher behaves across a few hundred words we did
not choose, which is what makes the accuracy numbers in EVALUATION.md mean
anything.  The seed is fixed, so re-running this produces the same file.

The seed is also the only thing standing between the shipped weights and a
held-out set: the weights were fitted on the seed below, so generating the
same three files with a different --seed into a different --out directory and
evaluating the unchanged weights on them is a genuine out-of-sample
measurement (see bench/evaluate.lua --cases).

Usage:
    python3 scripts/make_testset.py [--typos N] [--skeletons N] [--seed S]
    python3 scripts/make_testset.py --seed 12345 --out /tmp/seed-12345
"""

from __future__ import annotations

import argparse
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _common import REPO, skeleton, write_text  # noqa: E402

CASES = REPO / "tests" / "cases"
KEYBOARD_ROWS = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]


def neighbours() -> dict[str, list[str]]:
    """QWERTY adjacency, mirroring rime/lua/spellless/distance.lua."""
    keys = []
    for row, (letters, x0) in enumerate(zip(KEYBOARD_ROWS, (0.0, 0.25, 0.75))):
        for i, ch in enumerate(letters):
            keys.append((ch, x0 + i, row))
    out: dict[str, list[str]] = {c: [] for c, _, _ in keys}
    for a, ax, ay in keys:
        for b, bx, by in keys:
            if a != b and abs(ay - by) <= 1 and abs(ax - bx) <= 1.0:
                out[a].append(b)
    return out


NEIGHBOURS = neighbours()

SYLLABLE_VOWELS = set("aeiouy")


def syllabify(word: str) -> list[str]:
    """Cut a word into rough syllables, orthographically.

    Not linguistics: no pronunciation is consulted and "y" is simply treated as
    a vowel.  It only has to be good enough to *generate* plausible shorthand,
    and the matcher it is testing has no syllabifier at all -- see
    rime/lua/spellless/cue.lua.
    """
    runs, i, n = [], 0, len(word)
    while i < n:
        if word[i] in SYLLABLE_VOWELS:
            j = i
            while j < n and word[j] in SYLLABLE_VOWELS:
                j += 1
            runs.append((i, j))
            i = j
        else:
            i += 1
    if len(runs) <= 1:
        return [word]
    cuts = []
    for (_, end), (start, _) in zip(runs, runs[1:]):
        # One consonant between the vowels joins the next syllable (a-go);
        # two or more split, the first staying behind (gov-ern, al-go).
        cuts.append(end if start - end <= 1 else end + 1)
    parts, prev = [], 0
    for c in cuts:
        parts.append(word[prev:c])
        prev = c
    parts.append(word[prev:])
    return [p for p in parts if p]


def shorthand(word: str, rng: random.Random) -> str:
    """One or two letters per syllable, chosen the way a typist might.

    The first letter of a syllable is nearly always what gets typed; the second
    cue, when there is one, is whatever else in that syllable felt salient.
    Every letter comes from the word in order, which is the only property
    spellless.cue relies on.
    """
    out = []
    for k, part in enumerate(syllabify(word)):
        # A middle syllable occasionally gets nothing at all.
        if k > 0 and len(part) > 1 and rng.random() < 0.12:
            continue
        out.append(part[0])
        rest = part[1:]
        if rest and rng.random() < 0.45:
            out.append(rng.choice(rest))
    return "".join(out)


def corrupt(word: str, rng: random.Random) -> tuple[str, str]:
    """Apply one plausible fast-typing slip.  Returns (typo, kind)."""
    kinds = ["transpose", "delete", "insert", "substitute"]
    for _ in range(20):
        kind = rng.choice(kinds)
        if kind == "transpose" and len(word) >= 3:
            i = rng.randrange(len(word) - 1)
            if word[i] == word[i + 1]:
                continue
            return word[:i] + word[i + 1] + word[i] + word[i + 2:], kind
        if kind == "delete" and len(word) >= 4:
            i = rng.randrange(1, len(word))
            return word[:i] + word[i + 1:], kind
        if kind == "insert":
            i = rng.randrange(1, len(word) + 1)
            return word[:i] + word[i - 1] + word[i:], kind  # doubled letter
        if kind == "substitute" and len(word) >= 3:
            i = rng.randrange(1, len(word))
            opts = NEIGHBOURS.get(word[i])
            if not opts:
                continue
            return word[:i] + rng.choice(opts) + word[i + 1:], kind
    return word, "none"


def load_words() -> list[str]:
    path = REPO / "generated" / "spellless.words"
    if not path.exists():
        raise SystemExit("run scripts/build_dictionary.py first")
    return path.read_text(encoding="utf-8").split("\n")[:-1]


def load_forms() -> dict[str, str]:
    """What each word is actually committed as.

    The dictionary key is lowercase, but a word with a form commits as that
    form -- "thursday" commits as "Thursday".  The expected column has to be
    the form, or every proper noun that gets added reads as a regression when
    it is nothing of the sort.

    A third field "+" means the capital is offered *beside* the lowercase
    reading rather than instead of it, and then the lowercase reading is what
    leads -- `messenger` before `Messenger`.  So those are deliberately not
    collected: the expected text is the key itself, which is what `.get(word,
    word)` falls back to.  Reading the third field as part of the display is
    what happened before this was written, and it wrote `Messenger\t+` into the
    expected column, which the case parser rejects outright.
    """
    path = REPO / "generated" / "spellless.forms"
    if not path.exists():
        return {}
    forms = {}
    for line in path.read_text(encoding="utf-8").split("\n"):
        fields = line.split("\t")
        if len(fields) >= 2 and fields[0] and fields[1] and "+" not in fields[2:]:
            forms[fields[0]] = fields[1]
    return forms


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--typos", type=int, default=500)
    ap.add_argument("--skeletons", type=int, default=400)
    ap.add_argument("--cues", type=int, default=300)
    ap.add_argument("--seed", type=int, default=20260904)
    # Words this common are what people actually type; going deeper into the
    # tail measures the corpus, not the matcher.
    ap.add_argument("--from-rank", type=int, default=150)
    ap.add_argument("--to-rank", type=int, default=12000)
    # Where the three files land.  The default is the set the build ships and
    # the test suite reads; anything else is a held-out draw, which is what
    # --seed is for.
    ap.add_argument("--out", type=Path, default=CASES,
                    help="directory to write the three .tsv files into "
                         "(default: tests/cases)")
    args = ap.parse_args()
    out = args.out

    words = load_words()
    forms = load_forms()
    vocabulary = set(words)
    pool = words[args.from_rank - 1: args.to_rank]
    rng = random.Random(args.seed)

    typo_lines, seen = [], set()
    candidates = [w for w in pool if len(w) >= 4 and w.isalpha()]
    rng.shuffle(candidates)
    for word in candidates:
        if len(typo_lines) >= args.typos:
            break
        typo, kind = corrupt(word, rng)
        # A "typo" that is itself a word is a different question (see
        # tests/cases/ambiguity.tsv), so leave those out of the accuracy set.
        if kind == "none" or typo == word or typo in vocabulary or typo in seen:
            continue
        seen.add(typo)
        typo_lines.append(f"{typo}\t{forms.get(word, word)}\t5\t{kind}")

    # ---------------------------------------------------------------------
    # Ambiguity filters, shared by the skeleton and shorthand sets.
    #
    # All three ask about the strings and the frequency list only; none of them
    # consults the matcher.  That is what makes dropping a case defensible
    # rather than a way of raising the score.
    # ---------------------------------------------------------------------
    rank = {w: i for i, w in enumerate(words)}

    def has_commoner_stem(word: str) -> bool:
        mine = rank[word]
        return any(word[:k] in rank and rank[word[:k]] < mine
                   for k in range(3, len(word)))

    by_letter: dict[str, list[str]] = {}
    for w in words:
        if w[:1].isalpha():
            by_letter.setdefault(w[0], []).append(w)

    def is_subsequence(cue: str, word: str) -> bool:
        it = iter(word)
        return all(c in it for c in cue)

    def commonest_reading(cue: str, word: str) -> bool:
        """Is `word` the most frequent word this shorthand could be?

        Not a use of the matcher -- only of the one property the generator
        guarantees, that the letters appear in order.  A cue that fits a
        commoner word just as well ("untl" for "untitled", when "until" is
        right there) is ambiguous by construction and measures nothing.
        """
        limit = 2 * len(cue) + 2
        for other in by_letter.get(cue[0], ()):
            if other == word:
                return True          # frequency ordered: nothing commoner left
            if len(other) <= limit and is_subsequence(cue, other):
                return False
        return True

    def has_better_reading(cue: str, word: str) -> bool:
        """Does a shorter word explain this shorthand with strictly fewer
        skipped letters?

        `commonest_reading` asks whether anything *commoner* fits as well.
        This asks whether anything fits *better*, which is a different
        question, and the one that let "rgulator" stand as a case for
        "regulatory" when "regulator" is that string with one letter put back.

        No cost model is consulted, and none is needed: if the cue is a
        subsequence of `other` and `other` is a proper subsequence of `word`,
        then `other` skips strictly fewer characters than `word` does under
        *any* pricing whatsoever.  The case is ambiguous as a matter of the
        strings alone, and asking for `word` measures nothing.

        Bounded by --to-rank, the same window the targets themselves are drawn
        from, so this is not a new knob.  Without it the corpus tail does the
        dominating -- "brach" over "breach", "terran" over "terrain" -- which
        is a fact about Google Books, not an ambiguity anybody would meet.
        """
        for other in by_letter.get(cue[0], ()):
            if rank[other] > args.to_rank:
                break            # frequency ordered; everything later is rarer
            if (other != word and len(other) < len(word)
                    and is_subsequence(cue, other)
                    and is_subsequence(other, word)):
                return True
        return False


    skel_lines, seen = [], set()
    candidates = [w for w in pool if len(w) >= 6 and w.isalpha()]
    rng.shuffle(candidates)
    for word in candidates:
        if len(skel_lines) >= args.skeletons:
            break
        s = skeleton(word)
        # Skip skeletons that are ordinary words: those inputs are exact
        # matches first and abbreviations second, which is the right behaviour
        # but not what this file is measuring.
        if len(s) < 4 or s in vocabulary or s in seen:
            continue
        # A skeleton can be dominated in exactly the same way: "spcs" is the
        # skeleton of "species", but "specs" is a word that the same letters
        # spell with nothing skipped at all.
        if has_better_reading(s, word):
            continue
        seen.add(s)
        skel_lines.append(f"{s}\t{forms.get(word, word)}\t5\tlen{min(len(s), 9)}")

    cue_lines, seen = [], set()
    # Six letters up: shorthand for a short word is not shorthand, it is a typo,
    # and tests/cases/generated_typos.tsv already measures those.
    candidates = [w for w in pool
                  if len(w) >= 6 and w.isalpha() and not has_commoner_stem(w)]
    rng.shuffle(candidates)
    for word in candidates:
        if len(cue_lines) >= args.cues:
            break
        cue = shorthand(word, rng)
        # Under half the letters is not shorthand, it is a guess.
        if len(cue) < 4 or len(cue) * 2 < len(word):
            continue
        if cue == word or cue in vocabulary or cue in seen:
            continue
        if not commonest_reading(cue, word):
            continue
        if has_better_reading(cue, word):
            continue
        seen.add(cue)
        syllables = len(syllabify(word))
        cue_lines.append(f"{cue}\t{forms.get(word, word)}\t5\tsyl{min(syllables, 5)}")

    header = ("# Generated by scripts/make_testset.py -- do not edit by hand.\n"
              f"# seed={args.seed} ranks {args.from_rank}..{args.to_rank}\n"
              "# input <TAB> expected <TAB> max_rank <TAB> group\n")
    write_text(out / "generated_typos.tsv", header + "\n".join(typo_lines) + "\n")
    write_text(out / "generated_skeletons.tsv", header + "\n".join(skel_lines) + "\n")
    write_text(out / "generated_cues.tsv", header + "\n".join(cue_lines) + "\n")
    print(f"done: {len(typo_lines)} typo cases, {len(skel_lines)} skeleton cases, "
          f"{len(cue_lines)} syllabic cases")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
