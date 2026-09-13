#!/usr/bin/env python3
"""Read the Spellless input log, and say what it means.

    python3 scripts/analyse_log.py                      the report
    python3 scripts/analyse_log.py --days 7             the last week of it
    python3 scripts/analyse_log.py --repairs            what you deleted and retyped
    python3 scripts/analyse_log.py --to-cases FILE      a case file of your own typing
    python3 scripts/analyse_log.py --sqlite FILE        the whole log as a database
    python3 scripts/analyse_log.py --purge-before DATE  forget everything older
    python3 scripts/analyse_log.py --gzip               compress the rotated file

The log is written by `rime/lua/spellless/record.lua`, one tab-separated record
per line, and lives next to the personal vocabulary in the Rime user directory.
`docs/proposals/recording.md` is the design; §9 is the table of which question
each record answers.

This is the half where cleverness is affordable.  The Lua writes down facts and
nothing else, because it runs inside a keystroke and because a repair detector
written there would fix the definition of a repair for ever.  Everything
derived -- what a deletion undid, what a saving is net of, which pairs are
worth fitting weights on -- is worked out here, over a file that can be read
again next month under a better definition.

Standard library only, like the rest of scripts/.
"""

from __future__ import annotations

import argparse
import datetime as dt
import gzip
import io
import os
import shutil
import sqlite3
import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from install import resolve_user_dir  # noqa: E402  (same directory, same job)

LOG_NAME = "spellless_log.tsv"

# The columns record.lua writes, per kind.  Kept here rather than inferred,
# because a log written by an older build must stay readable: a short row is
# padded and a long one keeps its extra columns, so adding a field later does
# not invalidate what is already on disk.
COLUMNS = {
    "session": ["ms", "unix", "version", "build", "digest", "schema", "app"],
    "commit": ["ms", "app", "input", "text", "rank", "source", "how", "keys",
               "bs", "maxlen", "nav", "dur", "cands", "scanned", "checked",
               "cues", "qms"],
    "del": ["ms", "app", "a", "b"],
    "bail": ["ms", "app", "a", "b"],
    "forget": ["ms", "app", "a", "b"],
}
NUMERIC = {"ms", "unix", "rank", "keys", "bs", "maxlen", "nav", "dur", "cands",
           "scanned", "checked", "cues", "qms"}

UNESCAPE = {"\\\\": "\\", "\\t": "\t", "\\n": "\n", "\\r": "\r", "\\-": "-"}


def decode(field: str):
    """One field, as record.lua's `encode` left it."""
    if field == "-":
        return None
    if "\\" not in field:
        return field
    out, i = [], 0
    while i < len(field):
        pair = field[i:i + 2]
        if pair in UNESCAPE:
            out.append(UNESCAPE[pair])
            i += 2
        else:
            out.append(field[i])
            i += 1
    return "".join(out)


# ---------------------------------------------------------------------------
# reading
# ---------------------------------------------------------------------------

def log_files(path: Path) -> list[Path]:
    """The live log and whatever rotation and compression have left beside it.

    Oldest first, so a session that spans a rotation reads in order.
    """
    found = []
    for suffix in (".1.gz", ".1", ".gz", ""):
        candidate = Path(str(path) + suffix)
        if candidate.exists():
            found.append(candidate)
    return found


def open_text(path: Path) -> io.TextIOBase:
    if path.suffix == ".gz":
        return gzip.open(path, "rt", encoding="utf-8", errors="replace")
    return open(path, "r", encoding="utf-8", errors="replace")


def read(path: Path):
    """Every record, as dicts, with the session it belongs to attached.

    A record before any session header belongs to no session -- which happens
    only to a hand-edited file -- and is carried with `session=None` rather
    than dropped, because dropping it silently is how a truncated file starts
    reading as a shorter day.
    """
    session = None
    seq = 0
    for file in log_files(path):
        with open_text(file) as fh:
            for lineno, line in enumerate(fh, 1):
                line = line.rstrip("\n")
                if not line or line.startswith("#"):
                    continue
                fields = line.split("\t")
                kind = fields[0]
                names = COLUMNS.get(kind)
                if names is None:
                    continue  # a kind this build does not know: a newer log
                row = {"kind": kind, "file": str(file), "line": lineno}
                for i, name in enumerate(names):
                    raw = fields[i + 1] if i + 1 < len(fields) else "-"
                    value = decode(raw)
                    if name in NUMERIC and value is not None:
                        try:
                            value = int(value)
                        except ValueError:
                            value = None
                    row[name] = value
                if kind == "session":
                    seq += 1
                    session = {"seq": seq, "unix": row.get("unix") or 0,
                               "build": row.get("build"),
                               "digest": row.get("digest"),
                               "version": row.get("version"),
                               "schema": row.get("schema")}
                row["session"] = session["seq"] if session else None
                row["at"] = ((session["unix"] if session else 0)
                             + (row.get("ms") or 0) / 1000.0)
                row["digest"] = row.get("digest") if kind == "session" else (
                    session["digest"] if session else None)
                yield row


def load(path: Path, days: int | None) -> sqlite3.Connection:
    """The log as a database, which is where every question below is a query."""
    db = sqlite3.connect(":memory:")
    db.row_factory = sqlite3.Row
    db.executescript("""
        CREATE TABLE event (
            kind TEXT, session INTEGER, at REAL, ms INTEGER, app TEXT,
            input TEXT, text TEXT, rank INTEGER, source TEXT, how TEXT,
            keys INTEGER, bs INTEGER, maxlen INTEGER, nav INTEGER,
            dur INTEGER, cands INTEGER, scanned INTEGER, checked INTEGER,
            cues INTEGER, qms INTEGER, a TEXT, b TEXT, digest TEXT);
        CREATE TABLE session (
            seq INTEGER PRIMARY KEY, unix INTEGER, version TEXT,
            build TEXT, digest TEXT, schema TEXT);
    """)
    cutoff = None
    if days is not None:
        cutoff = dt.datetime.now().timestamp() - days * 86400
    cols = ["kind", "session", "at", "ms", "app", "input", "text", "rank",
            "source", "how", "keys", "bs", "maxlen", "nav", "dur", "cands",
            "scanned", "checked", "cues", "qms", "a", "b", "digest"]
    sql = f"INSERT INTO event VALUES ({','.join('?' * len(cols))})"
    for row in read(path):
        if row["kind"] == "session":
            db.execute("INSERT OR REPLACE INTO session VALUES (?,?,?,?,?,?)",
                       (row["session"], row["unix"], row.get("version"),
                        row.get("build"), row.get("digest"), row.get("schema")))
            continue
        if cutoff is not None and row["at"] < cutoff:
            continue
        db.execute(sql, tuple(row.get(c) for c in cols))
    db.commit()
    return db


# ---------------------------------------------------------------------------
# the report
# ---------------------------------------------------------------------------

def pct(part: int, whole: int) -> str:
    return f"{100.0 * part / whole:5.1f}%" if whole else "    --"


def histogram(db, column: str, where: str = "kind='commit'", limit: int = 8):
    rows = db.execute(
        f"SELECT {column} AS k, COUNT(*) AS n FROM event WHERE {where} "
        f"AND {column} IS NOT NULL GROUP BY k ORDER BY n DESC LIMIT {limit}"
    ).fetchall()
    total = db.execute(
        f"SELECT COUNT(*) FROM event WHERE {where} AND {column} IS NOT NULL"
    ).fetchone()[0]
    return ", ".join(f"{r['k']} {pct(r['n'], total).strip()}" for r in rows)


def quantile(values: list[int], q: float) -> int:
    if not values:
        return 0
    values = sorted(values)
    return values[min(len(values) - 1, int(q * len(values)))]


def report(db, out=sys.stdout) -> None:
    sessions = db.execute("SELECT * FROM session ORDER BY seq").fetchall()
    commits = db.execute("SELECT * FROM event WHERE kind='commit'").fetchall()
    say = lambda *a: print(*a, file=out)

    if not commits:
        say("Nothing recorded yet.")
        say("The log is written only when `spellless/record` is on in the "
            "schema; docs/proposals/recording.md §7 is what that means.")
        return

    span = (min(c["at"] for c in commits), max(c["at"] for c in commits))
    fmt = lambda t: dt.datetime.fromtimestamp(t).strftime("%Y-%m-%d %H:%M")
    builds = {s["digest"] for s in sessions if s["digest"]}
    say(f"spellless log  {fmt(span[0])} to {fmt(span[1])}")
    total = db.execute("SELECT COUNT(*) FROM event").fetchone()[0]
    plural = lambda n, word: f"{n:,} {word}" + ("" if n == 1 else "s")
    say(f"  {plural(len(sessions), 'session')}, {plural(total, 'record')}"
        + (f", {len(builds)} distinct settings" if len(builds) > 1 else ""))
    if len(builds) > 1:
        say("  NOTE: the settings changed inside this window, so the rates")
        say("        below average over more than one ranker.  --days narrows it.")
    say("")

    # What it is for: keystrokes that did not have to be typed.  Net of the
    # keys spent choosing, which is the number the marketing version never is.
    chars = sum(len(c["text"] or "") for c in commits)
    keys = sum(c["keys"] or 0 for c in commits)
    say("  words committed      {:>8,}".format(len(commits)))
    say("  characters written   {:>8,}".format(chars))
    say("  keys spent on them   {:>8,}   (letters, backspaces, choosing)".format(keys))
    say("  net saving           {:>8,}   {:.2f} characters per key".format(
        chars - keys, chars / keys if keys else 0))
    say("")

    # The claim on the front page of the README, on real typing.
    ranked = [c["rank"] for c in commits if c["rank"] is not None]
    top1 = sum(1 for r in ranked if r == 1)
    top5 = sum(1 for r in ranked if 1 <= r <= 5)
    missing = sum(1 for r in ranked if r == 0)
    say("  where the word was   top-1 {}   top-5 {}   not in the list {}".format(
        pct(top1, len(ranked)), pct(top5, len(ranked)), pct(missing, len(ranked))))
    say("  how it was taken     " + histogram(db, "how"))
    say("  which mechanism      " + histogram(db, "source"))
    say("")

    bails = db.execute(
        "SELECT a, COUNT(*) n FROM event WHERE kind='bail' GROUP BY a").fetchall()
    left = sum(r["n"] for r in bails if r["a"] == "on")
    maths = sum(r["n"] for r in bails if (r["a"] or "").startswith("delim"))
    dels = db.execute("SELECT COUNT(*) FROM event WHERE kind='del'").fetchone()[0]
    words = db.execute(
        "SELECT COUNT(*) FROM event WHERE kind='del' AND a='word'").fetchone()[0]
    forgets = db.execute("SELECT COUNT(*) FROM event WHERE kind='forget'").fetchall()
    per_k = lambda n: f"{1000.0 * n / len(commits):.1f}"
    say(f"  bailed out           {left:>8,}   {per_k(left)} per 1,000 words")
    say(f"  maths runs           {maths // 2:>8,}   keyboard handed over by a delimiter")
    say(f"  deletions            {dels:>8,}   of which whole words {words:,}")
    say(f"  forgotten by hand    {len(forgets):>8,}")

    qms = [c["qms"] for c in commits if c["qms"] is not None]
    if qms:
        say("  slowest query        {:>8,} ms   p95 {} ms, median {} ms".format(
            max(qms), quantile(qms, 0.95), quantile(qms, 0.5)))
    say("")

    # The tables that turn into files you edit by hand.
    # Only where a candidate was actually taken.  Return commits the letters
    # you typed, which is a refusal to choose between readings rather than a
    # disagreement with the ordering, and the raw candidate sitting at rank 2
    # is not the list being wrong about anything.
    corrected = db.execute("""
        SELECT input, text, COUNT(*) n FROM event
        WHERE kind='commit' AND rank > 1 AND source != 'raw'
          AND how IN ('space','pick','arrow','punct')
        GROUP BY input, text ORDER BY n DESC LIMIT 10""").fetchall()
    if corrected:
        say("  inputs that were not first")
        for r in corrected:
            say(f"     {r['input']:<16} {r['text']:<20} {r['n']:>4}")
        say("")

    literal = db.execute("""
        SELECT text, COUNT(*) n FROM event
        WHERE kind='commit' AND source='raw' GROUP BY text
        ORDER BY n DESC LIMIT 10""").fetchall()
    if literal:
        say("  committed literally -- words the dictionary does not have")
        say("     " + ", ".join(f"{r['text']} {r['n']}" for r in literal))
        say("")

    # An abbreviation you have already invented: one input, always the same
    # much longer word, typed often enough to be worth a line in the shortcuts
    # file.  The saving is what it is already earning you, per use.
    shortcuts = db.execute("""
        SELECT input, text, COUNT(*) n FROM event
        WHERE kind='commit' AND LENGTH(text) > LENGTH(input) + 3
        GROUP BY input, text HAVING n >= 5 ORDER BY n * (LENGTH(text) - LENGTH(input))
        DESC LIMIT 10""").fetchall()
    if shortcuts:
        say("  worth a line in spellless_shortcuts.txt")
        for r in shortcuts:
            saved = r["n"] * (len(r["text"]) - len(r["input"]))
            say(f"     {r['input']:<16} {r['text']:<20} {r['n']:>4}"
                f"   {saved:,} characters so far")
        say("")


# ---------------------------------------------------------------------------
# repairs, derived
# ---------------------------------------------------------------------------

def repairs(db, window: float = 20.0):
    """Commits that were deleted and typed again.

    The definition, and it lives here rather than in the Lua precisely so that
    it can be changed: a commit A, then one or more deletions with no commit
    between them, then a commit B within `window` seconds.  Three outcomes,
    and they are different evidence:

      same input, different text   the ranking was wrong and you re-picked.
                                   The strong label: you looked and disagreed.
      different input              you retyped it differently.  Which of your
                                   approximate spellings actually work.
      same text                    deleted for some other reason.  Dropped.
    """
    rows = db.execute(
        "SELECT * FROM event WHERE kind IN ('commit','del') ORDER BY session, at"
    ).fetchall()
    out = []
    last, deletions = None, []
    for row in rows:
        if row["kind"] == "del":
            if last is not None:
                deletions.append(row)
            continue
        if last is not None and deletions and row["at"] - last["at"] <= window:
            if row["text"] != last["text"]:
                kind = ("repick" if row["input"] == last["input"] else "retype")
                out.append({
                    "kind": kind,
                    "at": last["at"],
                    "app": last["app"],
                    "was_input": last["input"], "was": last["text"],
                    "now_input": row["input"], "now": row["text"],
                    "rank": row["rank"],
                    "deleted": len(deletions),
                    "gap": round(row["at"] - last["at"], 1),
                })
        last, deletions = row, []
    return out


def print_repairs(items, out=sys.stdout) -> None:
    say = lambda *a: print(*a, file=out)
    if not items:
        say("No repairs found.  Either the ranking is doing well or the log is "
            "short; --report says which.")
        return
    counts = Counter(i["kind"] for i in items)
    say(f"{len(items)} repair{'' if len(items) == 1 else 's'}: "
        f"{counts['repick']} re-picked, {counts['retype']} retyped differently")
    say("")
    say("  re-picked -- the same input, a different word.  The strong label.")
    for i in items:
        if i["kind"] == "repick":
            say(f"     {i['was_input']:<16} {i['was']:<18} -> {i['now']:<18}"
                f" rank {i['rank']}  {i['gap']}s")
    say("")
    say("  retyped -- a different approximate spelling of the same intention.")
    for i in items:
        if i["kind"] == "retype":
            say(f"     {i['was_input']:<16} -> {i['now_input']:<16} {i['now']}")


# ---------------------------------------------------------------------------
# a case file of your own typing
# ---------------------------------------------------------------------------

def plain(typed: str, text: str) -> str:
    """Drop a capital this software applied rather than the typist.

    Sentence-initial capitalisation is inferred by Spellless, so recording
    "But" as what a lowercase `but` meant and then fitting weights on it
    teaches the ranker its own output.  `Engine:learn_choice` guards the
    personal store against exactly this, with exactly this rule, and for the
    same reason: only a plain Title Case word is lowered, so `CLI` and `TQFT`
    keep their capitals -- those are how the word is written, not where it sat
    in a sentence.
    """
    if typed != typed.lower():
        return text
    lower = text.lower()
    return lower if text == lower[:1].upper() + lower[1:] else text


def to_cases(db, path: Path, strong_only: bool = False) -> int:
    """Write `tests/cases/`-format rows: input <TAB> expected <TAB> 1 <TAB> group.

    The `group` column is the evidence class, and it is the whole reason this
    is safe to fit anything on.  What you committed is partly a product of what
    was offered first -- a ranker fitted to rank-1 space-bar commits is fitted
    to its own output -- so the class says how much each row is worth:

        strong   you looked at the list and disagreed with it: a number key or
                 an arrow, on something that was not already first.
        weak     you took what was in front of you.  A true (input, word) pair,
                 and no evidence at all about the ordering.

    The harness already breaks its results down by group, so `make bench`
    scores the two separately without anything else having to change.
    """
    rows = db.execute("""
        SELECT input, text, rank, how, COUNT(*) n FROM event
        WHERE kind='commit' AND input IS NOT NULL AND text IS NOT NULL
          AND rank > 0
        GROUP BY input, text, rank, how""").fetchall()

    readings: dict[str, Counter] = defaultdict(Counter)
    strength: dict[tuple[str, str], str] = {}
    for r in rows:
        if not r["input"].isalpha() or not r["text"]:
            continue
        key = r["input"].lower()
        readings[key][plain(key, r["text"])] += r["n"]
        strong = r["how"] in ("pick", "arrow") and r["rank"] > 1
        word = plain(key, r["text"])
        if strong or (key, word) not in strength:
            strength[(key, word)] = "strong" if strong else "weak"

    lines, kept = [], 0
    for typed in sorted(readings):
        counts = readings[typed]
        best, top = counts.most_common(1)[0]
        # Genuinely ambiguous input -- `frm` is `from` and `form` and means
        # both -- is written as alternatives rather than as a majority verdict
        # it does not have.  Twice the runner-up is the line between the two.
        runner = counts.most_common(2)[1][1] if len(counts) > 1 else 0
        if runner and top < 2 * runner:
            expected = "|".join(w for w, _ in counts.most_common())
            group = "weak"
        else:
            expected = best
            group = strength.get((typed, best), "weak")
        if strong_only and group != "strong":
            continue
        lines.append(f"{typed}\t{expected}\t1\t{group}")
        kept += 1

    header = [
        "# Your own typing, as a case file.  Written by scripts/analyse_log.py",
        f"# from the input log on {dt.date.today().isoformat()}; regenerate it,",
        "# do not edit it.",
        "#",
        "# Columns: input <TAB> expected <TAB> max_rank <TAB> evidence class.",
        "#   strong  a number key or an arrow, on something not already first:",
        "#           you read the list and disagreed with it.",
        "#   weak    you took what was in front of you.  A true pair, and no",
        "#           evidence about the ordering -- a ranker fitted to these",
        "#           alone is fitted to its own output.",
        "# An input with two readings and no clear majority keeps both, joined",
        "# by '|': `frm` really is `from` and `form`.",
        "#",
        "# This is one person's typing (docs/proposals/recording.md §12.2).  It",
        "# is held-out evidence that the shipped defaults generalise; it is not",
        "# a replacement for tests/cases/.",
    ]
    path.write_text("\n".join(header + lines) + "\n", encoding="utf-8")
    return kept


# ---------------------------------------------------------------------------
# housekeeping
# ---------------------------------------------------------------------------

def purge_before(path: Path, date: str) -> int:
    """Drop whole sessions that started before `date`.  Sessions, because a
    record's time is an offset from its header and means nothing without it."""
    cutoff = dt.datetime.strptime(date, "%Y-%m-%d").timestamp()
    removed = 0
    for file in log_files(path):
        if file.suffix == ".gz":
            continue
        keep, dropping = [], False
        with open_text(file) as fh:
            for line in fh:
                if line.startswith("session\t"):
                    fields = line.rstrip("\n").split("\t")
                    unix = int(fields[2]) if len(fields) > 2 and fields[2].isdigit() else 0
                    dropping = unix < cutoff
                if dropping:
                    removed += 1
                else:
                    keep.append(line)
        tmp = Path(str(file) + ".new")
        tmp.write_text("".join(keep), encoding="utf-8")
        tmp.replace(file)
    return removed


def gzip_rotated(path: Path) -> list[str]:
    done = []
    rotated = Path(str(path) + ".1")
    if rotated.exists():
        target = Path(str(rotated) + ".gz")
        with open(rotated, "rb") as src, gzip.open(target, "wb") as dst:
            shutil.copyfileobj(src, dst)
        rotated.unlink()
        done.append(str(target))
    return done


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--user-dir", help="where Rime keeps its user files")
    ap.add_argument("--log", help="the log file itself, overriding --user-dir")
    ap.add_argument("--days", type=int, help="only the last N days")
    ap.add_argument("--repairs", action="store_true",
                    help="what was deleted and typed again")
    ap.add_argument("--to-cases", metavar="FILE",
                    help="write a tests/cases-format file of your own typing")
    ap.add_argument("--strong-only", action="store_true",
                    help="with --to-cases: only rows you read the list for")
    ap.add_argument("--sqlite", metavar="FILE",
                    help="also write the whole log out as a database")
    ap.add_argument("--purge-before", metavar="YYYY-MM-DD",
                    help="delete every session that started before this date")
    ap.add_argument("--gzip", action="store_true",
                    help="compress the rotated log beside the live one")
    args = ap.parse_args()

    if args.log:
        path = Path(args.log).expanduser()
        why = "given on the command line"
    else:
        user_dir, why = resolve_user_dir(args.user_dir)
        path = user_dir / LOG_NAME

    if args.purge_before:
        n = purge_before(path, args.purge_before)
        print(f"dropped {n} records from before {args.purge_before}")
        return 0
    if args.gzip:
        done = gzip_rotated(path)
        print("compressed " + ", ".join(done) if done else "nothing to compress")
        return 0

    if not log_files(path):
        print(f"No log at {path}  ({why})")
        print("Recording is off unless `spellless/record: true` is in the "
              "schema; see docs/proposals/recording.md §7.")
        return 1

    db = load(path, args.days)
    if args.sqlite:
        target = sqlite3.connect(args.sqlite)
        db.backup(target)
        target.close()
        print(f"wrote {args.sqlite}")
    if args.to_cases:
        n = to_cases(db, Path(args.to_cases), args.strong_only)
        print(f"wrote {n} cases to {args.to_cases}")
        return 0
    if args.repairs:
        print_repairs(repairs(db))
        return 0
    report(db)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
