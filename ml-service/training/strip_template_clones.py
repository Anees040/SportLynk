"""
Drop mechanically-cloned rows from a sentiment CSV  —  S.4 Wave B data hygiene

THE PROBLEM THIS SOLVES
`authored_batch2.csv` was produced by a generator that emitted every sentence
twice: once bare, and once with a venue name appended.

    turf ghatiya aur lights band thin                    <- base
    turf ghatiya aur lights band thin at city turf       <- clone

The clone carries no new linguistic evidence. It is the same clause with a
trailing prepositional phrase, so the word branch sees three extra tokens and the
char branch sees a handful of extra n-grams that all belong to a venue name the
model must NOT key on. On its own that would merely be wasteful. It is worse than
wasteful here because authored rows are upweighted (`--upweight-authored`, default
40) to close the domain gap: at x40 a base/clone pair puts x80 of effective weight
behind ONE sentence pattern, on a corpus whose authored slice already outweighs
every real row combined. That is memorisation pressure, not generalisation, and it
is exactly the failure mode the domain exam exists to catch.

WHY THE FILTER IS PREFIX-BASED AND NOT A VENUE LIST
A hardcoded list of the ten venue names would work today and rot silently the
first time the generator's vocabulary changes. Instead a row is a clone only if
some OTHER row in the same file is a strict prefix of it, with the remainder
reading " at <a few words>". That makes the rule self-validating: it cannot fire
unless the base sentence is genuinely present, so it can never delete an original.

The distinction that makes this safe is worth stating, because it looks fragile
and is not:

    "The slot started at the advertised time"                -> KEPT
        the longest " at " split yields "The slot started", which is not a row in
        this file, so nothing is dropped.

    "The slot started at the advertised time at club field"  -> DROPPED
        the split yields "The slot started at the advertised time", which IS a
        row, so this is provably a clone of it.

Splitting on the LAST " at " rather than the first is what makes the second case
resolve; a first-match split would compare against "The slot started" and keep the
clone.

WHAT THIS IS NOT
Not a deduplicator. `build_sentiment_corpus.py` already drops exact duplicates and
near-duplicates of the exam; this removes a *templating artifact* that survives
both of those checks because a clone is neither an exact duplicate of its base nor
similar enough to any exam row to trip the contamination gate.

Usage:
    python training/strip_template_clones.py IN.csv OUT.csv [--report]

Exit code is 0 even when nothing is dropped -- "already clean" is a success.
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
from pathlib import Path

#: Longest suffix (in words, excluding the "at") that may be treated as a venue
#: tag. Belt-and-braces only: the prefix-existence test below is the real guard.
#: A cap keeps the rule readable -- it says "a short trailing tag", which is what
#: the generator appended, rather than "any amount of extra text".
MAX_TAG_WORDS = 4

#: The separator the generator used. Spaces on both sides on purpose: it must not
#: match "attendance" or a sentence-initial "At".
SEP = " at "

_RE_WS = re.compile(r"\s+")


def _key(text: str) -> str:
    """Whitespace- and case-insensitive identity for prefix comparison.

    The generator was consistent, so exact matching would work. Normalising anyway
    costs nothing and means a hand-edit that changes "  at " to " At " does not
    quietly turn a clone back into an original.
    """
    return _RE_WS.sub(" ", text).strip().lower()


def split_clone(text: str, known: set[str]) -> str | None:
    """Return the base sentence if `text` is a clone of a row in `known`, else None.

    Walks candidate splits from the LAST " at " backwards, so the longest possible
    base is tested first -- see the docstring for why first-match is wrong.
    """
    parts = text.split(SEP)
    if len(parts) < 2:
        return None
    for cut in range(len(parts) - 1, 0, -1):
        base = SEP.join(parts[:cut])
        tag = SEP.join(parts[cut:])
        if len(tag.split()) > MAX_TAG_WORDS:
            continue
        if _key(base) in known:
            return base
    return None


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="python training/strip_template_clones.py",
        description="Remove '<sentence> at <venue>' template clones from a corpus CSV.",
    )
    ap.add_argument("src", type=Path, help="input CSV (must have a 'text' column)")
    ap.add_argument("dst", type=Path, help="output CSV (same columns, clones removed)")
    ap.add_argument(
        "--report", action="store_true", help="print every dropped row and its base"
    )
    args = ap.parse_args(argv)

    if not args.src.is_file():
        print(f"FAIL  no such file: {args.src}", file=sys.stderr)
        return 1

    with args.src.open("r", encoding="utf-8-sig", newline="") as fh:
        reader = csv.DictReader(fh)
        if reader.fieldnames is None or "text" not in reader.fieldnames:
            print(
                f"FAIL  {args.src.name} has no 'text' column "
                f"(found: {reader.fieldnames})",
                file=sys.stderr,
            )
            return 1
        fields = list(reader.fieldnames)
        rows = list(reader)

    known = {_key(r.get("text") or "") for r in rows}
    known.discard("")

    kept: list[dict[str, str]] = []
    dropped: list[tuple[str, str]] = []
    for row in rows:
        text = row.get("text") or ""
        base = split_clone(text, known)
        if base is None:
            kept.append(row)
        else:
            dropped.append((text, base))

    args.dst.parent.mkdir(parents=True, exist_ok=True)
    with args.dst.open("w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        writer.writerows(kept)

    if args.report:
        for text, base in dropped:
            print(f"  drop  {text!r}\n        <- {base!r}")

    print(
        f"ok    {args.src.name}: {len(rows)} rows -> {len(kept)} kept, "
        f"{len(dropped)} template clones removed  ->  {args.dst.name}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
