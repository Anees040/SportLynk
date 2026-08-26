r"""
Is the FR9.10 strong-negative threshold a real rule?  —  S.4 Wave B

WHY THIS SCRIPT EXISTS
`train_sentiment.py` ships `NEG_PROB_THRESHOLD = 0.90`, and that number reaches
serving through the artifact and the model card. It was chosen as "conservative"
before any model existed. Shipping it unmeasured has two distinct failure modes,
and only one of them is obvious:

  1. TOO LOW  -- the flag fires on ordinary mild complaints, an owner learns the
     escalation means nothing, and the feature is worse than absent.
  2. TOO HIGH -- and this is the one that hides. The shipped estimator scores with
     softmax OVER decision_function on UNCALIBRATED margins. Softmax of a margin is
     not a posterior: its sharpness depends on the magnitude of the margins, which
     depends directly on C. Heavy regularization (small C) shrinks every margin
     toward zero, which pushes softmax toward uniform 1/3. So a 0.90 cutoff that is
     comfortably reachable at C=3 can be UNREACHABLE at C=0.1 -- the rule then
     silently escalates nothing, the demo shows no strong-negative flags ever, and
     the FR is dead code that still appears satisfied in the model card.

     No test catches this. `smoke_sentiment_api.py` asserts the threshold is present
     and is a float, which it is. The model card asserts the rule exists, which it
     does. Both pass while the rule never fires.

WHAT IT REPORTS
For each candidate threshold, over the 200 exam rows: how many rows escalate, and
of those how many are TRULY negative (precision) plus what share of all true
negatives got caught (recall). Precision is the figure that matters here -- the
signal's job is to earn an owner's attention, and a signal that cries wolf loses it.
Also printed: the observed P(negative) distribution, so "is 0.90 even reachable"
is answered by data rather than by argument.

THIS SCRIPT DECIDES NOTHING. It prints a table; a human picks the constant. It does
not write an artifact, does not retrain, and opens `domain_test_200.csv` READ-ONLY
-- it is the final REL-8 exam set.

Run:
    cd ml-service
    .\.venv\Scripts\python.exe training\validate_neg_threshold.py
"""

from __future__ import annotations

import csv
import sys
from pathlib import Path

import joblib

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

EXAM = ROOT / "data" / "sentiment" / "domain_test_200.csv"
MODELS = ROOT / "models"

#: Coarse enough to see the shape, fine enough to choose between neighbours.
CANDIDATES = (0.50, 0.60, 0.70, 0.75, 0.80, 0.85, 0.90, 0.95)


def printable(text: str) -> str:
    """Make a review safe to print on a Windows console.

    The exam deliberately contains Urdu-script rows, and this terminal's stdout is
    cp1252 -- printing one raises UnicodeEncodeError and kills the run partway
    through the table. Substituting the unencodable characters is right rather than
    merely convenient: the script's job is to report a threshold, and losing that
    report because a diagnostic line could not be rendered would be the tail wagging
    the dog. Nothing downstream reads this text; only a human reading the console does.
    """
    encoding = getattr(sys.stdout, "encoding", None) or "ascii"
    return text.encode(encoding, errors="replace").decode(encoding, errors="replace")


def newest_artifact() -> Path | None:
    released = MODELS / "sentiment_latest.joblib"
    if released.is_file():
        return released
    builds = sorted(MODELS.glob("sentiment_*.joblib"))
    return builds[-1] if builds else None


def main() -> int:
    path = newest_artifact()
    if path is None:
        print("no sentiment artifact on disk -- train first", file=sys.stderr)
        return 1
    if not EXAM.is_file():
        print(f"no exam file at {EXAM}", file=sys.stderr)
        return 1

    payload = joblib.load(path)
    model = payload["model"]
    shipped = (payload.get("toxicity") or {}).get("negativeProbabilityThreshold")
    classes = list(model.classes_)
    neg_index = classes.index("negative")

    with EXAM.open("r", encoding="utf-8-sig", newline="") as fh:
        exam = list(csv.DictReader(fh))

    texts = [row["text"] for row in exam]
    actual = [row["label"] for row in exam]
    p_neg = [float(row[neg_index]) for row in model.predict_proba(texts)]
    true_negatives = sum(1 for label in actual if label == "negative")

    print(f"artifact : {path.name}  ({payload.get('modelVersion')})")
    print(f"shipped  : NEG_PROB_THRESHOLD = {shipped}")
    print(f"exam     : {len(exam)} rows, {true_negatives} truly negative (read-only)\n")

    ordered = sorted(p_neg, reverse=True)
    print("P(negative) distribution over the exam:")
    print(f"  max      {ordered[0]:.4f}")
    print(f"  p95      {ordered[int(len(ordered) * 0.05)]:.4f}")
    print(f"  median   {ordered[len(ordered) // 2]:.4f}")
    print(f"  min      {ordered[-1]:.4f}")

    # The headline check: softmax over shrunken margins may never reach the cutoff.
    if shipped is not None and ordered[0] < float(shipped):
        print(
            f"\n  *** DEAD RULE: no exam row reaches {float(shipped):.2f}. The highest "
            f"P(negative) the model ever emits here is {ordered[0]:.4f}, so the "
            "strong-negative escalation can never fire. Lower the constant."
        )

    print("\n  thresh   escalated   correct   precision   recall(of true neg)")
    for threshold in CANDIDATES:
        hits = [i for i, p in enumerate(p_neg) if p > threshold]
        correct = sum(1 for i in hits if actual[i] == "negative")
        precision = correct / len(hits) if hits else float("nan")
        recall = correct / true_negatives if true_negatives else float("nan")
        mark = "  <-- shipped" if shipped is not None and abs(threshold - float(shipped)) < 1e-9 else ""
        print(
            f"  {threshold:.2f}     {len(hits):4d}       {correct:4d}      "
            f"{precision:9.4f}   {recall:9.4f}{mark}"
        )

    print(
        "\n  Read precision first. This flag asks an owner to look NOW, so a wrong\n"
        "  escalation costs more than a missed one -- recall is already covered by\n"
        "  the ordinary negative label on the review itself."
    )

    print("\n  Rows that would escalate at the shipped threshold:")
    if shipped is None:
        print("    (artifact carries no threshold)")
    else:
        shown = sorted(
            ((p, actual[i], texts[i]) for i, p in enumerate(p_neg) if p > float(shipped)),
            reverse=True,
        )
        if not shown:
            print("    (none -- see the dead-rule warning above)")
        for p, label, text in shown[:15]:
            flag = " " if label == "negative" else "!"
            print(f"    {flag} {p:.4f} true={label:8s} | {printable(text)[:58]}")
        if len(shown) > 15:
            print(f"    ... and {len(shown) - 15} more")
        print("    ('!' marks an escalation on a row that is NOT truly negative)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
