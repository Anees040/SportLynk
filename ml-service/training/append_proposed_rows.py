"""Append the validated candidate rows to ``authored_intents.csv``, or take them out.

The pre-flight gate in :mod:`check_proposed_rows` runs first and the append is
abandoned unless every candidate is admissible, so the file can only ever grow by
rows that have already been measured against the sha-locked exam.

Three properties are deliberate. The append is idempotent -- a second run finds the
ids already present and exits without writing, so a repeated invocation cannot
duplicate the corpus. The write is LF-terminated regardless of platform, because
``.gitattributes`` pins ``*.csv`` to ``eol=lf`` and every recorded sha256 is taken
over raw bytes: a CRLF append would break provenance on a machine where nothing is
otherwise wrong. And ``--revert`` truncates at the first appended id rather than
rewriting the file, so the rows that were already there keep their exact original
bytes instead of being re-quoted by a different CSV writer than wrote them.

The corpus quota is untouched (``ROWS_PER_INTENT_TARGET`` stays 112), so these rows
displace template rows inside their own intents rather than enlarging the corpus.
Neither published fingerprint is a function of row content, so neither moves;
``intents.csv``'s sha256 does, and is re-recorded by ``gen_intents.py``.
"""

from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import check_proposed_rows as gate  # noqa: E402

AUTHORED = ROOT / "data" / "assistant" / "authored_intents.csv"
FIELDS = ("id", "text", "intent", "lang", "phenomena", "note")


def existing(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        if tuple(reader.fieldnames or ()) != FIELDS:
            raise SystemExit(
                f"unexpected header {reader.fieldnames!r}; expected {list(FIELDS)}"
            )
        return list(reader)


def next_index(rows: list[dict[str, str]]) -> int:
    """One past the highest ``au-NNN`` in the file.

    Derived rather than assumed: the file is hand-edited, so the last row is not
    reliably the highest id.
    """
    highest = 0
    for row in rows:
        identifier = row["id"]
        if not identifier.startswith("au-"):
            raise SystemExit(f"unexpected id {identifier!r}; expected au-NNN")
        highest = max(highest, int(identifier[3:]))
    return highest + 1


def append() -> int:
    print("=" * 72)
    print("PRE-FLIGHT GATE")
    print("=" * 72)
    if gate.main() != 0:
        print("\nrefusing to append: the gate rejected at least one row")
        return 1

    rows = existing(AUTHORED)
    start = next_index(rows)
    new_ids = [f"au-{start + offset:03d}" for offset in range(len(gate.PROPOSED))]

    print()
    print("=" * 72)
    print("APPEND")
    print("=" * 72)
    print(f"file            : {AUTHORED.relative_to(ROOT)}")
    print(f"rows before     : {len(rows)}")
    print(f"next free id    : {new_ids[0]}")

    present = {row["id"] for row in rows}
    already = sorted(present & set(new_ids))
    if already:
        print(f"\nnothing to do: {len(already)} of the target ids already exist "
              f"({already[0]}..{already[-1]})")
        return 0

    texts = {gate.spec.dedup_key(row["text"]) for row in rows}
    collisions = [t for t, *_ in gate.PROPOSED if gate.spec.dedup_key(t) in texts]
    if collisions:
        print("\nrefusing to append: these already exist in the authored file")
        for text in collisions:
            print(f"  {text}")
        return 1

    raw = AUTHORED.read_bytes()
    if b"\r\n" in raw:
        print("\nrefusing to append: the file already contains CRLF line endings")
        return 1
    if not raw.endswith(b"\n"):
        print("\nrefusing to append: the file does not end with a newline")
        return 1

    with AUTHORED.open("a", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle, lineterminator="\n")
        for identifier, (text, intent, lang, phenomena, note) in zip(
            new_ids, gate.PROPOSED
        ):
            writer.writerow([identifier, text, intent, lang, phenomena, note])

    after = existing(AUTHORED)
    crlf = b"\r\n" in AUTHORED.read_bytes()
    print(f"rows after      : {len(after)}  (+{len(after) - len(rows)})")
    print(f"ids written     : {new_ids[0]}..{new_ids[-1]}")
    print("CRLF introduced : "
          + ("YES -- the sha256 lock is byte-exact, investigate" if crlf else "no"))

    by_intent: dict[str, int] = {}
    for _text, intent, *_rest in gate.PROPOSED:
        by_intent[intent] = by_intent.get(intent, 0) + 1
    print()
    print("added per intent:")
    for intent in sorted(by_intent):
        before = sum(1 for row in rows if row["intent"] == intent)
        print(f"  {intent:<20} {before:>3} -> {before + by_intent[intent]:>3}")
    return 0


def revert() -> int:
    """Truncate the appended block, restoring the file to its previous bytes.

    Truncation rather than a rewrite: re-emitting the surviving rows through a CSV
    writer would re-quote fields that the file's original author quoted differently,
    changing bytes in rows this script never added.
    """
    print("=" * 72)
    print("REVERT")
    print("=" * 72)

    rows = existing(AUTHORED)
    proposed_keys = {gate.spec.dedup_key(t) for t, *_ in gate.PROPOSED}
    appended = [r for r in rows if gate.spec.dedup_key(r["text"]) in proposed_keys]

    print(f"file            : {AUTHORED.relative_to(ROOT)}")
    print(f"rows before     : {len(rows)}")
    print(f"candidate rows  : {len(appended)} of {len(gate.PROPOSED)} found")

    if not appended:
        print("\nnothing to do: none of the candidate rows are in the file")
        return 0
    if len(appended) != len(gate.PROPOSED):
        print("\nrefusing to revert: only part of the block is present, so a "
              "truncation would also remove rows this script did not add")
        return 1

    # The block must be contiguous and final for truncation to be equivalent to
    # removing exactly those rows.
    tail = rows[-len(appended):]
    if [r["id"] for r in tail] != [r["id"] for r in appended]:
        print("\nrefusing to revert: the candidate rows are not the final block")
        return 1

    first_id = tail[0]["id"]
    raw = AUTHORED.read_bytes()
    marker = b"\n" + first_id.encode("ascii") + b","
    cut = raw.find(marker)
    if cut < 0 or raw.find(marker, cut + 1) >= 0:
        print(f"\nrefusing to revert: {first_id} does not start exactly one line")
        return 1

    AUTHORED.write_bytes(raw[: cut + 1])

    after = existing(AUTHORED)
    print(f"truncated at    : {first_id}")
    print(f"rows after      : {len(after)}  (-{len(rows) - len(after)})")
    print(f"last id         : {after[-1]['id']}")
    print(f"bytes removed   : {len(raw) - (cut + 1)}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revert", action="store_true",
                        help="remove the appended block instead of adding it")
    args = parser.parse_args()
    return revert() if args.revert else append()


if __name__ == "__main__":
    raise SystemExit(main())
