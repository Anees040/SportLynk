r"""
Exam audit  —  S.4 Wave B integrity + error diagnosis

TWO QUESTIONS, ONE SCRIPT, BECAUSE THE FIRST ONE GATES THE SECOND

1. CONTAMINATION, AT A LOWER THRESHOLD THAN THE BUILD GATE
   `build_sentiment_corpus.py` drops authored rows that are >= 0.80 Jaccard-similar
   to any exam row. That gate is doing its job and reports 0 removals. But a gate
   answers "is anything over the line", and the question that matters for an FYP
   defence is "what does the DISTRIBUTION of similarity look like".

   The reason to ask: this exam row and this authored row coexist today --

       exam      lights hain magar ghaas thori kam thi
       batch3    lights chal rahi thin magar ghaas thori kam thi

   Jaccard 0.60, so the gate correctly let it through. In a domain with a vocabulary
   of maybe 200 words (ground, turf, lights, slot, washroom, parking, theek, acha)
   coincidental overlap that high is entirely expected, and a single pair proves
   nothing. What WOULD be evidence of exam-aware authoring is a cluster of rows
   piled up just under the threshold -- a generator that knew where the line was.
   So this prints the top matches per source and the full histogram, and lets a
   human decide. It never deletes anything.

2. THE FULL ERROR SET, NOT THE FIRST 20
   `reports/sentiment_metrics.json` caps `error_analysis` at 20 rows, and those 20
   happen to be all `ru`/`mixed` -- so they cannot explain why English is the weakest
   cell at 0.72. This re-runs the served pipeline over all 200 exam rows and breaks
   the errors down by language and by confusion direction, with the model's own
   score on each, so the next data decision is made from the actual failures rather
   than from a truncated sample.

`domain_test_200.csv` is opened READ-ONLY. It is the final REL-8 exam set and this
script must never write to it.

Run:
    cd ml-service
    .\.venv\Scripts\python.exe training\audit_exam.py
"""

from __future__ import annotations

import csv
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

import joblib

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

DATA = ROOT / "data" / "sentiment"
EXAM = DATA / "domain_test_200.csv"
MODELS = ROOT / "models"

#: The build gate's threshold. Printed as a reference line on the histogram so the
#: shape of the distribution can be read against the rule that was applied.
GATE_THRESHOLD = 0.80

_RE_WORD = re.compile(r"[a-z0-9]+")


def words(text: str) -> set[str]:
    """Bag of lowercase alphanumeric tokens -- the same shape the build gate uses."""
    return set(_RE_WORD.findall(text.lower()))


def printable(text: str) -> str:
    """Make a review safe to print on a Windows console (cp1252 vs Urdu script).

    The exam deliberately contains Urdu-script rows. Printing one raises
    UnicodeEncodeError and would abort the audit halfway through its table -- losing
    the whole report because one diagnostic line could not be rendered. Only a human
    reads this text; nothing downstream parses it.
    """
    encoding = getattr(sys.stdout, "encoding", None) or "ascii"
    return text.encode(encoding, errors="replace").decode(encoding, errors="replace")


def jaccard(a: set[str], b: set[str]) -> float:
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8-sig", newline="") as fh:
        return list(csv.DictReader(fh))


def contamination_audit(exam: list[dict[str, str]]) -> None:
    print("\n" + "=" * 78)
    print("1. SIMILARITY OF AUTHORED ROWS TO THE EXAM  (gate is >= %.2f)" % GATE_THRESHOLD)
    print("=" * 78)

    exam_bags = [(row["text"], words(row["text"])) for row in exam]
    buckets: Counter[str] = Counter()
    worst: dict[str, list[tuple[float, str, str]]] = defaultdict(list)

    for path in sorted(DATA.glob("authored*.csv")):
        for row in read_csv(path):
            text = row.get("text") or ""
            bag = words(text)
            best, match = 0.0, ""
            for exam_text, exam_bag in exam_bags:
                score = jaccard(bag, exam_bag)
                if score > best:
                    best, match = score, exam_text
            buckets[f"{int(best * 10) / 10:.1f}"] += 1
            worst[path.name].append((best, text, match))

    print("\nHistogram of each authored row's BEST similarity to any exam row:")
    for bucket in sorted(buckets):
        bar = "#" * min(60, buckets[bucket])
        flag = "  <-- gate drops these" if float(bucket) >= GATE_THRESHOLD else ""
        print(f"  {bucket}-{float(bucket) + 0.1:.1f}  {buckets[bucket]:4d}  {bar}{flag}")

    print("\nClosest 3 rows per authored file:")
    for name in sorted(worst):
        print(f"\n  {name}")
        for score, text, match in sorted(worst[name], reverse=True)[:3]:
            print(f"    {score:.2f}  authored: {printable(text)[:66]}")
            print(f"          exam:     {printable(match)[:66]}")

    over = sum(count for bucket, count in buckets.items() if float(bucket) >= GATE_THRESHOLD)
    near = buckets.get("0.6", 0) + buckets.get("0.7", 0)
    total = sum(buckets.values())
    print(f"\n  {total} authored rows;  {over} at/over the gate;  {near} in the 0.6-0.8 band")
    print(
        "  Read the band, not the max: a CLUSTER just under 0.80 would suggest\n"
        "  exam-aware authoring. A thin tail is ordinary vocabulary overlap."
    )


def newest_artifact() -> Path | None:
    released = MODELS / "sentiment_latest.joblib"
    if released.is_file():
        return released
    builds = sorted(MODELS.glob("sentiment_*.joblib"))
    return builds[-1] if builds else None


def error_audit(exam: list[dict[str, str]]) -> None:
    print("\n" + "=" * 78)
    print("2. FULL EXAM ERROR BREAKDOWN")
    print("=" * 78)

    path = newest_artifact()
    if path is None:
        print("  no sentiment artifact on disk -- skipped")
        return
    payload = joblib.load(path)
    model = payload["model"]
    classes = list(model.classes_)
    print(f"  artifact: {path.name}  ({payload.get('modelVersion')})")

    texts = [row["text"] for row in exam]
    proba = model.predict_proba(texts)
    predicted = [classes[int(row.argmax())] for row in proba]

    by_lang: dict[str, list[int]] = defaultdict(list)
    confusion: Counter[str] = Counter()
    errors: list[tuple[float, str, str, str, str]] = []

    for index, row in enumerate(exam):
        lang = row.get("lang") or "?"
        actual, guess = row["label"], predicted[index]
        by_lang[lang].append(1 if actual == guess else 0)
        if actual != guess:
            confusion[f"{actual} -> {guess}"] += 1
            confidence = float(proba[index].max())
            errors.append((confidence, lang, actual, guess, row["text"]))

    print("\n  Accuracy by language:")
    for lang in sorted(by_lang):
        hits = by_lang[lang]
        print(
            f"    {lang:6s} n={len(hits):3d}  acc={sum(hits) / len(hits):.4f}  "
            f"errors={len(hits) - sum(hits)}"
        )

    print("\n  Confusion directions (all %d errors):" % len(errors))
    for direction, count in confusion.most_common():
        print(f"    {count:3d}  {direction}")

    print("\n  Errors by language x direction:")
    pairs = Counter((lang, f"{actual}->{guess}") for _, lang, actual, guess, _ in errors)
    for (lang, direction), count in pairs.most_common():
        print(f"    {count:3d}  {lang:6s} {direction}")

    print("\n  CONFIDENT errors (model was sure and wrong) -- these are the real bugs:")
    for confidence, lang, actual, guess, text in sorted(errors, reverse=True)[:12]:
        print(f"    {confidence:.2f} {lang:6s} {actual:8s}->{guess:8s} | {printable(text)[:60]}")

    print("\n  BORDERLINE errors (model was unsure) -- mostly genuine ambiguity:")
    for confidence, lang, actual, guess, text in sorted(errors)[:12]:
        print(f"    {confidence:.2f} {lang:6s} {actual:8s}->{guess:8s} | {printable(text)[:60]}")


def main() -> int:
    if not EXAM.is_file():
        print(f"FAIL  no exam file at {EXAM}", file=sys.stderr)
        return 1
    exam = read_csv(EXAM)
    print(f"exam: {len(exam)} rows (opened read-only)")
    contamination_audit(exam)
    error_audit(exam)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
