r"""
Inter-annotator agreement on the REL-8 exam

WHY THIS EXISTS
`domain_test_200.csv` is the only number in this project that is allowed to be called
an accuracy. Every gate, every headline, every claim in the model card resolves to it.
But it was labelled by ONE person, and a one-annotator gold set has no measured
reliability -- "hand-labelled" is a description of effort, not evidence of correctness.

If two competent annotators only agree on 85% of these rows, then a model scoring 85%
has hit the ceiling of the label noise and the remaining 15% is not a modelling
failure at all. Without kappa you cannot tell those two situations apart, and you will
spend later work trying to fix rows that were never unambiguous.

WHAT IT DOES NOT DO
It never writes to `domain_test_200.csv`. The exam is opened read-only and its labels
are the reference column, not a candidate for revision. A disagreement is REPORTED for
human adjudication, never resolved automatically -- the moment a script edits the exam
on the basis of a second opinion, the exam stops being a fixed measuring instrument.

Run:
    cd ml-service
    .\.venv\Scripts\python.exe training\annotator_agreement.py
    .\.venv\Scripts\python.exe training\annotator_agreement.py --show-disagreements
    .\.venv\Scripts\python.exe training\annotator_agreement.py --with-model
"""

from __future__ import annotations

import argparse
import csv
import random
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

EXAM = ROOT / "data" / "sentiment" / "domain_test_200.csv"
ANNOTATOR2 = ROOT / "data" / "sentiment" / "domain_test_200_annotator2.csv"

FORM = ROOT / "data" / "sentiment" / "domain_test_200_blind_form.csv"

LABELS = ("negative", "neutral", "positive")
BOOTSTRAP_RESAMPLES = 2000
SEED = 20260826
FORM_SHUFFLE_SEED = 8112026


def make_blind_form(path: Path = FORM) -> None:
    """Write the form a second annotator can actually work from.

    Two properties make it blind, and BOTH are load-bearing:

      1. It carries `text` and an EMPTY `label`. The exam's own label column is not
         written. This is the property the first attempt lacked -- a file of
         `id,label` with no text cannot be labelled by a human at all, so whoever
         fills it in must have read the exam itself, labels included.

      2. Row order is SHUFFLED. `domain_test_200.csv` is stored in nine contiguous
         label blocks (27 negative, then 27 neutral, then 26 positive, and so on), so
         an annotator working it in file order would see runs of seventeen to
         twenty-seven identical answers in a row. That is an anchor even for someone
         who never sees a label: after fifteen negatives the sixteenth needs no
         thought. Shuffling with a fixed seed removes the anchor and stays
         reproducible.

    `annotator_agreement.py` joins on `id`, so the shuffled order costs nothing at
    scoring time and no answer key has to be kept anywhere.
    """
    exam = load_exam()
    ids = sorted(exam)
    random.Random(FORM_SHUFFLE_SEED).shuffle(ids)
    with path.open("w", encoding="utf-8", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["id", "text", "label"])
        for rid in ids:
            w.writerow([rid, exam[rid]["text"], ""])
    print(f"wrote {path}  ({len(ids)} rows, shuffled, label column empty)")
    print()
    print("Hand this file to the second annotator with these instructions:")
    print("  - Fill the `label` column with exactly one of: negative, neutral, positive")
    print("  - Judge the REVIEWER's attitude to the venue, not whether the event went well")
    print("  - neutral means factual or mixed with no clear lean -- it is not a dustbin")
    print("  - Do not open domain_test_200.csv, the repo, or any file but this one")
    print("  - Do not skip rows; if genuinely torn, pick the closer one and move on")
    print()
    print("Then score it:")
    print(f"  .\\.venv\\Scripts\\python.exe training\\annotator_agreement.py "
          f"--annotator data\\sentiment\\{path.name}")


def load_exam() -> dict[str, dict[str, str]]:
    """Read-only. Returns id -> row."""
    with EXAM.open(encoding="utf-8-sig", newline="") as fh:
        rows = list(csv.DictReader(fh))
    return {r["id"].strip(): r for r in rows}


def load_annotator(path: Path) -> tuple[dict[str, str], list[str]]:
    """Returns (id -> label, problems). Tolerates BOM and stray whitespace/case."""
    problems: list[str] = []
    out: dict[str, str] = {}
    with path.open(encoding="utf-8-sig", newline="") as fh:
        reader = csv.DictReader(fh)
        cols = [c.strip().lower() for c in (reader.fieldnames or [])]
        if "id" not in cols or "label" not in cols:
            problems.append(f"header must contain id,label -- got {reader.fieldnames}")
            return out, problems
        for n, raw in enumerate(reader, start=2):
            rid = (raw.get("id") or "").strip()
            lab = (raw.get("label") or "").strip().lower()
            if not rid:
                problems.append(f"line {n}: empty id")
                continue
            if rid in out:
                problems.append(f"line {n}: duplicate id {rid}")
                continue
            if lab not in LABELS:
                problems.append(f"line {n}: id {rid} has label {lab!r}, not one of {LABELS}")
                continue
            out[rid] = lab
    return out, problems


def cohen_kappa(a: list[str], b: list[str]) -> tuple[float, float, float]:
    """Cohen's kappa, hand-rolled. Returns (kappa, p_observed, p_expected).

    Hand-rolled rather than imported so the arithmetic is visible in the repo: kappa is
    the one statistic in this project that a committee is most likely to ask to see
    derived. It is cross-checked against sklearn below, so this is transparency, not
    a re-implementation nobody verified.
    """
    n = len(a)
    if n == 0:
        return float("nan"), float("nan"), float("nan")
    p_o = sum(1 for x, y in zip(a, b) if x == y) / n
    ca, cb = Counter(a), Counter(b)
    p_e = sum((ca[k] / n) * (cb[k] / n) for k in LABELS)
    kappa = 1.0 if p_e == 1.0 else (p_o - p_e) / (1.0 - p_e)
    return kappa, p_o, p_e


def bootstrap_ci(a: list[str], b: list[str], resamples: int = BOOTSTRAP_RESAMPLES):
    """Percentile CI on kappa. Same method and resample count as the exam accuracy CI."""
    rng = random.Random(SEED)
    n = len(a)
    stats: list[float] = []
    for _ in range(resamples):
        idx = [rng.randrange(n) for _ in range(n)]
        ka, _, _ = cohen_kappa([a[i] for i in idx], [b[i] for i in idx])
        if ka == ka:  # not NaN
            stats.append(ka)
    stats.sort()
    lo = stats[int(0.025 * len(stats))]
    hi = stats[int(0.975 * len(stats)) - 1]
    return lo, hi


def one_vs_rest_kappa(a: list[str], b: list[str], label: str) -> float:
    ka, _, _ = cohen_kappa(
        [label if x == label else "other" for x in a],
        [label if y == label else "other" for y in b],
    )
    return ka


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--annotator", type=Path, default=ANNOTATOR2)
    ap.add_argument("--show-disagreements", action="store_true")
    ap.add_argument("--with-model", action="store_true",
                    help="also score the released model on agreed vs contested rows")
    ap.add_argument("--make-form", action="store_true",
                    help="write a blind annotation form (text, empty label, shuffled) and exit")
    args = ap.parse_args()

    if args.make_form:
        make_blind_form()
        return 0

    exam = load_exam()
    ann, problems = load_annotator(args.annotator)

    # A file with no `text` column cannot have been labelled from itself, so whoever
    # filled it in read the exam -- which carries the answers. Refusing to compute is
    # the point: a kappa of 0.99 from a non-blind pass is worse than no kappa, because
    # it looks like evidence.
    with args.annotator.open(encoding="utf-8-sig", newline="") as fh:
        ann_cols = [c.strip().lower() for c in (csv.DictReader(fh).fieldnames or [])]
    blind_ok = "text" in ann_cols

    print("=" * 74)
    print("Inter-annotator agreement -- REL-8 exam")
    print("=" * 74)
    print(f"exam        {EXAM.name}  ({len(exam)} rows, read-only)")
    print(f"annotator2  {args.annotator.name}  ({len(ann)} rows)")
    print()

    print("1. Validation")
    if problems:
        for p in problems:
            print(f"   FAIL  {p}")
    missing = sorted(set(exam) - set(ann))
    extra = sorted(set(ann) - set(exam))
    print(f"   {'ok  ' if not problems else 'FAIL'}  every label is one of {LABELS}")
    print(f"   {'ok  ' if not missing else 'FAIL'}  every exam id is annotated"
          f"{'' if not missing else f' -- missing {len(missing)}: ' + ', '.join(missing[:8])}")
    print(f"   {'ok  ' if not extra else 'FAIL'}  no ids that are not in the exam"
          f"{'' if not extra else f' -- extra {len(extra)}: ' + ', '.join(extra[:8])}")
    print(f"   {'ok  ' if len(ann) == len(exam) else 'FAIL'}  row count matches "
          f"({len(ann)} vs {len(exam)})")
    if blind_ok:
        print("   ok    the form carried the review text, so it could be labelled blind")
    else:
        print("   WARN  this file has NO `text` column, only "
              f"{ann_cols} -- 200 reviews cannot be")
        print("         labelled from it, so the labels were read off an exam copy that")
        print("         also carries the answers. Agreement below is reported for")
        print("         completeness and is NOT a reliability statistic. Regenerate a")
        print("         blind form with --make-form and have a second person fill it in.")
    if problems or missing or extra:
        print("\nValidation failed -- not computing agreement on a broken file.")
        return 1

    ids = sorted(exam)
    a = [exam[i]["label"].strip().lower() for i in ids]
    b = [ann[i] for i in ids]

    print()
    print("2. Marginals")
    ca, cb = Counter(a), Counter(b)
    print(f"   {'label':<10}{'exam':>8}{'annot2':>9}{'delta':>8}")
    for lab in LABELS:
        print(f"   {lab:<10}{ca[lab]:>8}{cb[lab]:>9}{cb[lab] - ca[lab]:>+8}")

    kappa, p_o, p_e = cohen_kappa(a, b)
    lo, hi = bootstrap_ci(a, b)
    disagreements = [(i, x, y) for i, x, y in zip(ids, a, b) if x != y]

    print()
    print("3. Agreement")
    print(f"   raw agreement        {p_o:.4f}   ({len(ids) - len(disagreements)}/{len(ids)} rows)")
    print(f"   disagreements        {len(disagreements)}")
    print(f"   expected by chance   {p_e:.4f}")
    print(f"   Cohen's kappa        {kappa:.4f}   95% CI [{lo:.4f}, {hi:.4f}]"
          f"  ({BOOTSTRAP_RESAMPLES} resamples)")

    try:
        from sklearn.metrics import cohen_kappa_score
        sk = cohen_kappa_score(a, b, labels=list(LABELS))
        agree = abs(sk - kappa) < 1e-9
        print(f"   {'ok  ' if agree else 'FAIL'}  cross-checked against sklearn "
              f"({sk:.4f}){'' if agree else ' -- MISMATCH'}")
    except Exception as exc:  # pragma: no cover
        print(f"   skip  sklearn cross-check unavailable ({exc})")

    band = ("slight" if kappa < 0.20 else "fair" if kappa < 0.40 else
            "moderate" if kappa < 0.60 else "substantial" if kappa < 0.80 else
            "almost perfect")
    print(f"   Landis-Koch band     {band}")

    print()
    print("4. Confusion matrix  (rows = exam, cols = annotator2)")
    print(f"   {'':<12}" + "".join(f"{lab[:8]:>10}" for lab in LABELS) + f"{'total':>10}")
    for r in LABELS:
        cells = [sum(1 for x, y in zip(a, b) if x == r and y == c) for c in LABELS]
        print(f"   {r:<12}" + "".join(f"{v:>10}" for v in cells) + f"{sum(cells):>10}")
    print(f"   {'total':<12}" + "".join(
        f"{sum(1 for y in b if y == c):>10}" for c in LABELS) + f"{len(ids):>10}")

    print()
    print("5. Per-label agreement (one-vs-rest kappa)")
    for lab in LABELS:
        both = sum(1 for x, y in zip(a, b) if x == lab and y == lab)
        print(f"   {lab:<10} kappa {one_vs_rest_kappa(a, b, lab):.4f}"
              f"   agreed on {both}/{ca[lab]} of the exam's {lab} rows")

    if disagreements:
        print()
        print(f"6. The {len(disagreements)} contested rows"
              + ("" if args.show_disagreements else "  (--show-disagreements for text)"))
        pairs = Counter((x, y) for _, x, y in disagreements)
        for (x, y), n in pairs.most_common():
            print(f"   exam={x:<9} annot2={y:<9} {n}")
        if args.show_disagreements:
            print()
            for rid, x, y in disagreements:
                print(f"   {rid}  exam={x:<9} annot2={y:<9} lang={exam[rid].get('lang','?')}")
                print(f"      {exam[rid]['text'][:150]}")

    if args.with_model:
        print()
        print("7. Model vs the human ceiling")
        from app.core.registry import registry
        entry = registry.get("sentiment")
        texts = [exam[i]["text"] for i in ids]
        pred = list(entry.estimator.predict(texts))
        agreed_idx = [k for k, (x, y) in enumerate(zip(a, b)) if x == y]
        contested_idx = [k for k, (x, y) in enumerate(zip(a, b)) if x != y]
        overall = sum(1 for k in range(len(ids)) if pred[k] == a[k]) / len(ids)
        on_agreed = (sum(1 for k in agreed_idx if pred[k] == a[k]) / len(agreed_idx)
                     if agreed_idx else float("nan"))
        on_contested = (sum(1 for k in contested_idx if pred[k] == a[k]) / len(contested_idx)
                        if contested_idx else float("nan"))
        print(f"   artifact                     {entry.meta.get('modelVersion')}")
        print(f"   accuracy, all {len(ids)} rows      {overall:.4f}")
        print(f"   on the {len(agreed_idx)} agreed rows      {on_agreed:.4f}")
        print(f"   on the {len(contested_idx)} contested rows    {on_contested:.4f}")
        print(f"   human-human raw agreement    {p_o:.4f}   <- the ceiling")
        print()
        print("   Read this as a ceiling, not a licence: a model at or near the")
        print("   human-human rate has reached the point where the remaining errors")
        print("   are on rows two people also read differently. It does NOT mean the")
        print("   model is right about them.")

    print()
    if not blind_ok:
        print("REMINDER: the input was not blind (no `text` column), so the kappa above")
        print("measures transcription, not reliability. Do not cite it.")
    print("The exam was not modified. Disagreements are for human adjudication only.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
