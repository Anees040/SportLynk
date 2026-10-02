"""Pre-flight gate for hand-written candidate rows, before any file is changed.

Task 2 of the intent-quality work proposes authored rows for the starved intents.
A proposal is only worth reading if it already satisfies the two conditions the
build would enforce later: :func:`intent_spec.text_problems` must accept every
row, and no row may duplicate or near-duplicate the sha-locked exam (release
gate 4: 0 exact matches, max near-duplicate score below
:data:`intent_spec.NEAR_DUP_CONTAM`).

This script writes nothing. It exists so the numbers in the proposal are measured
rather than asserted, and so a row that would have been rejected is found while it
is still a candidate. :mod:`append_proposed_rows` imports :data:`PROPOSED` from
here and re-runs :func:`main` immediately before writing, so the rows that reach
the corpus are exactly the rows this gate passed.
"""

from __future__ import annotations

import csv
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from app.core import intent_spec as spec  # noqa: E402

EXAM = ROOT / "data" / "assistant" / "assistant_test.csv"
CORPUS = ROOT / "data" / "assistant" / "intents.csv"

# (text, intent, lang, phenomena, note). Candidates only -- nothing here is
# committed to the corpus by this script.
#
# The set is built as minimal pairs: each starved intent receives rows, and the
# intent it leaks into receives a near-identical counterpart. A pair differs in
# the discriminating feature alone, so the fit has to separate them on that
# feature rather than on topic vocabulary, which is what the exam's `indirect`
# and `boundary` rows punish.
PROPOSED: tuple[tuple[str, str, str, str, str], ...] = (
    # Empty on purpose. Every vetted batch (minimal pairs, the Roman-Urdu how-to fix,
    # robustness rounds A-C, and the support batch) is already appended to
    # authored_intents.csv. Stage the next batch here, run this gate, then append.
)


def read_texts(path: Path) -> list[str]:
    with path.open(newline="", encoding="utf-8") as handle:
        return [row["text"] for row in csv.DictReader(handle)]


def main() -> int:
    exam = read_texts(EXAM)
    corpus = read_texts(CORPUS)
    exam_keys = {spec.dedup_key(t) for t in exam}
    corpus_keys = {spec.dedup_key(t) for t in corpus}

    print(f"text length window : [{spec.MIN_TEXT_CHARS}, {spec.MAX_TEXT_CHARS}]")
    print(f"near-dup threshold  : {spec.NEAR_DUP_CONTAM}")
    print(f"exam rows           : {len(exam)}")
    print(f"corpus rows         : {len(corpus)}")
    print(f"proposed rows       : {len(PROPOSED)}")
    print()

    bad_text = 0
    exact_exam = 0
    exact_corpus = 0
    bad_label = 0
    bad_phen = 0
    bad_note = 0
    worst = 0.0
    worst_row = ""
    worst_against = ""

    print(f"{'intent':<20}{'maxNearDup':>11}  {'verdict':<8} text")
    print(f"{'-' * 20}{'-' * 11:>11}  {'-' * 8:<8} {'-' * 40}")

    for text, intent, lang, phenomena, note in PROPOSED:
        problems = spec.text_problems(text)
        if problems:
            bad_text += 1
        if intent not in spec.INTENTS:
            bad_label += 1
            problems.append(f"unknown intent {intent!r}")
        if lang not in spec.LANGS:
            problems.append(f"unknown lang {lang!r}")
        tags = [t for t in phenomena.split(";") if t]
        unknown = [t for t in tags if t not in spec.PHENOMENA]
        if unknown or not tags:
            bad_phen += 1
            problems.append(f"bad phenomena {unknown or 'empty'}")
        if not note.strip():
            bad_note += 1
            problems.append("empty note")

        key = spec.dedup_key(text)
        if key in exam_keys:
            exact_exam += 1
            problems.append("EXACT MATCH against the exam")
        if key in corpus_keys:
            exact_corpus += 1
            problems.append("exact match against the existing corpus")

        top = 0.0
        against = ""
        for other in exam:
            score, _metric = spec.near_dup_score(text, other)
            if score > top:
                top, against = score, other
        if top > worst:
            worst, worst_row, worst_against = top, text, against

        flag = "OK" if not problems and top < spec.NEAR_DUP_CONTAM else "REJECT"
        print(f"{intent:<20}{top:>11.4f}  {flag:<8} {text}")
        for problem in problems:
            print(f"{'':<20}{'':>11}  {'':<8}   -> {problem}")

    print()
    print("---- gate 4 equivalent, proposed rows vs the 230 exam rows ----")
    print(f"exact matches against the exam      : {exact_exam}   (needs 0)")
    print(f"max near-duplicate score            : {worst:.4f}   "
          f"(needs < {spec.NEAR_DUP_CONTAM})")
    print(f"  worst row                         : {worst_row}")
    print(f"  closest exam row                  : {worst_against}")
    print()
    print(f"rows rejected by text_problems      : {bad_text}   (needs 0)")
    print(f"rows with an unknown intent         : {bad_label}   (needs 0)")
    print(f"rows with a bad phenomena tag       : {bad_phen}   (needs 0)")
    print(f"rows with an empty note             : {bad_note}   (needs 0)")
    print(f"exact matches against the corpus    : {exact_corpus}   (needs 0)")

    clean = (exact_exam == 0 and bad_text == 0 and bad_label == 0
             and bad_phen == 0 and bad_note == 0 and exact_corpus == 0
             and worst < spec.NEAR_DUP_CONTAM)
    print()
    print("VERDICT: " + ("all proposed rows are admissible"
                         if clean else "at least one row must be rewritten"))
    return 0 if clean else 1


if __name__ == "__main__":
    raise SystemExit(main())
