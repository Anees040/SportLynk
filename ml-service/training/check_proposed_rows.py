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
    # wallet_balance: the balance NUMBER, asked indirectly and without the word
    # "balance". Weakest intent on the exam -- recall 0.20, 8 of 68 errors.
    ("am i still in credit after the friday game",
     "wallet_balance", "en", "indirect;question",
     "in credit asks the balance number, not the topup procedure"),
    ("did the refund land or am i still short",
     "wallet_balance", "en", "indirect;boundary;run_on",
     "a refund is the context; the request is the current balance"),
    ("whats left on my account before i book anything",
     "wallet_balance", "en", "indirect;boundary;question",
     "booking is the motive, the balance is what is asked for"),
    ("is there anything held back from the last match or is it all free",
     "wallet_balance", "en", "indirect;boundary;run_on",
     "held funds are escrow, which the spec assigns to wallet_balance"),
    ("i thought i had 2000 in there, can you check",
     "wallet_balance", "en", "indirect;numeric",
     "a figure recalled wrongly is still a balance query"),
    ("do i need to load more or am i covered for tonight",
     "wallet_balance", "en", "indirect;boundary;run_on",
     "pairs with the topup row of the same wording; asks whether the balance suffices"),

    # topup_help: the minimal-pair counterpart -- the PROCEDURE, not the number.
    ("how do i load more before tonight",
     "topup_help", "en", "boundary;question",
     "same wording as the wallet pair, but asks the method rather than the amount"),
    ("whats the minimum i can add by easypaisa",
     "topup_help", "en", "boundary;numeric;question",
     "a numeric answer that is a rule of the topup procedure, not a balance"),
    ("can you walk me through getting money out",
     "topup_help", "en", "boundary;question",
     "withdrawal is part of the procedure intent per the spec gloss"),

    # my_bookings: the user's OWN bookings, asked without a booking keyword.
    # Recall 0.30 and precision 0.333 -- wrong in both directions.
    ("what have i got lined up this week",
     "my_bookings", "en", "indirect;question",
     "no booking noun at all; the possessive is the only signal"),
    ("am i playing anywhere on saturday or did i imagine that",
     "my_bookings", "en", "indirect;run_on",
     "pairs with the availability row for saturday; this one asks about own bookings"),
    ("remind me where we are meant to be at 7",
     "my_bookings", "en", "indirect;imperative;numeric",
     "an imperative that retrieves an existing booking rather than making one"),
    ("did that friday one actually go through",
     "my_bookings", "en", "indirect;boundary;ellipsis",
     "asks whether a booking exists, which is a lookup and not a booking act"),
    ("whats on my plate for the weekend",
     "my_bookings", "en", "indirect;slang;question",
     "idiom carrying no domain vocabulary; the exam's English rows read like this"),
    ("i have two games this week i think, which ones",
     "my_bookings", "en", "indirect;numeric;run_on",
     "a count plus a request to enumerate the user's own bookings"),

    # check_availability: the minimal-pair counterpart -- FREE slots, not mine.
    ("whats still open on saturday",
     "check_availability", "en", "boundary;short;question",
     "same day as the my_bookings pair, but the object is a free slot"),
    ("anything free at 7 or is it all gone",
     "check_availability", "en", "boundary;numeric;run_on",
     "same clock time as the my_bookings pair, but asks what is unbooked"),

    # cancel_booking: the ACT of cancelling, with no cancel verb in the row.
    # Recall 0.40, and it leaks into book_venue and my_bookings.
    ("something came up, we cant make tonight",
     "cancel_booking", "en", "indirect;negation",
     "states an inability, which in context is the instruction to cancel"),
    ("pull us out of the saturday game please",
     "cancel_booking", "en", "indirect;imperative;politeness",
     "withdrawal from a booked fixture, phrased without the verb cancel"),
    ("we are a man short so drop tomorrows slot",
     "cancel_booking", "en", "indirect;run_on",
     "a reason welded to the instruction; drop is the cancelling verb here"),
    ("the team bailed, get rid of the 9pm one",
     "cancel_booking", "en", "indirect;slang;numeric",
     "selects an existing booking by time and orders its removal"),
    ("i wont be needing friday after all",
     "cancel_booking", "en", "indirect;negation",
     "negation over an existing booking, not a refusal of a Scout proposal"),
    ("scrap it, we are not playing sunday",
     "cancel_booking", "en", "indirect;negation;short",
     "short and negated, but acts on a booking rather than answering Scout"),

    # refund_policy: the minimal-pair counterpart -- the RULES of cancelling.
    ("if we cant make tonight what do we lose",
     "refund_policy", "en", "boundary;indirect;question",
     "same premise as the cancel pair, but asks the rule and not for the act"),
    ("whats the cutoff for pulling out without losing the deposit",
     "refund_policy", "en", "boundary;question",
     "same wording as the cancel pair, but the object is the cancellation window"),
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
