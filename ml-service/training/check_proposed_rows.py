"""Pre-flight gate for hand-written candidate rows, before any file is changed.

Task 2 of the intent-quality work proposes authored rows for the starved intents.
A proposal is only worth reading if it already satisfies the two conditions the
build would enforce later: :func:`intent_spec.text_problems` must accept every
row, and no row may duplicate or near-duplicate the sha-locked exam (release
gate 4: 0 exact matches, max near-duplicate score below
:data:`intent_spec.NEAR_DUP_CONTAM`).

This script writes nothing. It exists so the numbers in the proposal are measured
rather than asserted, and so a row that would have been rejected is found while it
is still a candidate.
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

# (text, intent, lang, phenomena). Candidates only -- nothing here is committed
# to the corpus by this script.
PROPOSED: tuple[tuple[str, str, str, str], ...] = (
    # wallet_balance: the balance NUMBER, asked indirectly and without the
    # word "balance". Weakest intent on the exam (recall 0.20).
    ("am i still in credit after the friday game",
     "wallet_balance", "en", "indirect;question"),
    ("did the refund land or am i still short",
     "wallet_balance", "en", "indirect;boundary;run_on"),
    ("whats left on my account before i book anything",
     "wallet_balance", "en", "indirect;boundary;question"),
    ("is there anything held back from the last match or is it all free",
     "wallet_balance", "en", "indirect;boundary;run_on"),
    ("i thought i had 2000 in there, can you check",
     "wallet_balance", "en", "indirect;numeric"),
    ("do i need to load more or am i covered for tonight",
     "wallet_balance", "en", "indirect;boundary;run_on"),

    # topup_help: the minimal-pair counterpart -- the PROCEDURE, not the number.
    ("how do i load more before tonight",
     "topup_help", "en", "boundary;question"),
    ("whats the minimum i can add by easypaisa",
     "topup_help", "en", "boundary;numeric;question"),
    ("can you walk me through getting money out",
     "topup_help", "en", "boundary;question"),

    # my_bookings: the user's OWN bookings, asked without a booking keyword.
    # Recall 0.30 and precision 0.333 -- wrong in both directions.
    ("what have i got lined up this week",
     "my_bookings", "en", "indirect;question"),
    ("am i playing anywhere on saturday or did i imagine that",
     "my_bookings", "en", "indirect;run_on"),
    ("remind me where we are meant to be at 7",
     "my_bookings", "en", "indirect;imperative;numeric"),
    ("did that friday one actually go through",
     "my_bookings", "en", "indirect;boundary;ellipsis"),
    ("whats on my plate for the weekend",
     "my_bookings", "en", "indirect;slang;question"),
    ("i have two games this week i think, which ones",
     "my_bookings", "en", "indirect;numeric;run_on"),

    # check_availability: the minimal-pair counterpart -- FREE slots, not mine.
    ("whats still open on saturday",
     "check_availability", "en", "boundary;short;question"),
    ("anything free at 7 or is it all gone",
     "check_availability", "en", "boundary;numeric;run_on"),

    # cancel_booking: the ACT of cancelling, with no cancel verb in the row.
    # Recall 0.40, and it leaks into book_venue and my_bookings.
    ("something came up, we cant make tonight",
     "cancel_booking", "en", "indirect;negation"),
    ("pull us out of the saturday game please",
     "cancel_booking", "en", "indirect;imperative;politeness"),
    ("we are a man short so drop tomorrows slot",
     "cancel_booking", "en", "indirect;run_on"),
    ("the team bailed, get rid of the 9pm one",
     "cancel_booking", "en", "indirect;slang;numeric"),
    ("i wont be needing friday after all",
     "cancel_booking", "en", "indirect;negation"),
    ("scrap it, we are not playing sunday",
     "cancel_booking", "en", "indirect;negation;short"),

    # refund_policy: the minimal-pair counterpart -- the RULES of cancelling.
    ("if we cant make tonight what do we lose",
     "refund_policy", "en", "boundary;indirect;question"),
    ("whats the cutoff for pulling out without losing the deposit",
     "refund_policy", "en", "boundary;question"),
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
    worst = 0.0
    worst_row = ""
    worst_against = ""

    print(f"{'intent':<20}{'maxNearDup':>11}  {'verdict':<8} text")
    print(f"{'-' * 20}{'-' * 11:>11}  {'-' * 8:<8} {'-' * 40}")

    for text, intent, lang, phenomena in PROPOSED:
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
    print(f"exact matches against the corpus    : {exact_corpus}   (needs 0)")

    clean = (exact_exam == 0 and bad_text == 0 and bad_label == 0
             and bad_phen == 0 and exact_corpus == 0
             and worst < spec.NEAR_DUP_CONTAM)
    print()
    print("VERDICT: " + ("all proposed rows are admissible"
                         if clean else "at least one row must be rewritten"))
    return 0 if clean else 1


if __name__ == "__main__":
    raise SystemExit(main())
