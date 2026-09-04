r"""
Intent exam diff  —  what v2's eight extra labels cost, row by row

WHY THIS EXISTS

The retrain that took model #4 from 15 labels to 23 published a one-line cost:
"12 exam rows v1 got right and v2 gets wrong". The number was true of the
candidate artifact that was current when the sentence was written
(`intent-v2-20260828-1329`) and it was never recomputed after the corpus fix
and the release refit, so `intent-v2-20260828-2315` — the artifact actually
served — shipped with a cost figure measured on a different model. A figure
like that has no receipt: it cannot be checked from `intent_metrics.json`,
which scores one artifact at a time and never compares two.

So this script is the receipt. It loads two artifacts, scores both on the exam
rows they can BOTH be graded on, and prints every row the newer one lost.

WHICH ROWS ARE COMPARABLE

The v2 exam is 230 rows; v1's exam was 150 and was kept byte-identical inside
it. Rather than trust a row range, the comparable set is derived: a row is
comparable when its gold label is not one of the eight labels v2 added, because
a 15-label model cannot be right about `find_players` however good it is. That
derivation lands on exactly 150 rows, which is the independent check that the
"kept byte-identical" claim held.

HOW A PREDICTION IS TAKEN

`argmax(predict_proba)`, the same one call the router makes and the same way
`train_intents._predict_with_conf` measured every number in the model card —
never `predict()` plus a second scoring call, which can disagree with it.

A lost row is split by the served threshold: below it the model abstains and
offers the menu, which is a degraded answer but not a wrong one, and at or
above it the model states the wrong thing confidently. Only the second kind is
a regression a user can see.

Read-only. Touches no CSV, writes no artifact, moves no threshold.

Run:
    cd ml-service
    .venv\Scripts\python.exe training\diff_intent_exam.py
    .venv\Scripts\python.exe training\diff_intent_exam.py --baseline intent_20260828-0053.joblib
"""
from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path

import joblib
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

EXAM = ROOT / "data" / "assistant" / "assistant_test.csv"
MODELS = ROOT / "models"

#: The labels v2 added. A row whose gold is one of these is not gradeable
#: against a 15-label baseline, so it is excluded from the comparison rather
#: than counted as a baseline error.
V2_ONLY_LABELS = frozenset({
    "find_players", "find_teams", "navigate", "contact_owner",
    "app_help", "elo_help", "affirm", "deny",
})


def load(name: str):
    """An artifact's pipeline plus the version string stamped inside it."""
    payload = joblib.load(MODELS / name)
    if not isinstance(payload, dict) or "model" not in payload:
        raise SystemExit(f"{name} is not the expected dict {{model, modelVersion, ...}}")
    return payload["model"], payload.get("modelVersion", "?"), payload.get(
        "confidenceThreshold", 0.45)


def predict(model, texts: list[str]) -> tuple[list[str], np.ndarray]:
    """Label and its confidence from ONE predict_proba call (see the docstring)."""
    proba = model.predict_proba(texts)
    classes = list(model.named_steps["clf"].classes_)
    idx = np.argmax(proba, axis=1)
    return [classes[i] for i in idx], proba[np.arange(len(idx)), idx]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1].strip())
    ap.add_argument("--baseline", default="intent_20260828-0053.joblib",
                    help="the 15-label artifact to compare against (default: v1 as released)")
    ap.add_argument("--candidate", default="intent_latest.joblib",
                    help="the artifact under test (default: whatever is served)")
    args = ap.parse_args()

    all_rows = list(csv.DictReader(EXAM.open(encoding="utf-8")))
    rows = [r for r in all_rows if r["intent"] not in V2_ONLY_LABELS]
    texts = [r["text"] for r in rows]
    gold = [r["intent"] for r in rows]

    base, base_v, _ = load(args.baseline)
    cand, cand_v, floor = load(args.candidate)
    base_labels = list(base.named_steps["clf"].classes_)
    p_base, _ = predict(base, texts)
    p_cand, c_cand = predict(cand, texts)

    hits_base = sum(a == b for a, b in zip(p_base, gold))
    hits_cand = sum(a == b for a, b in zip(p_cand, gold))
    lost = [i for i in range(len(gold)) if p_base[i] == gold[i] and p_cand[i] != gold[i]]
    gained = [i for i in range(len(gold)) if p_base[i] != gold[i] and p_cand[i] == gold[i]]
    abstained = [i for i in lost if c_cand[i] < floor]
    served = [i for i in lost if c_cand[i] >= floor]

    print(f"baseline   {base_v}  ({len(base_labels)} labels)")
    print(f"candidate  {cand_v}  (floor {floor:.2f} from the artifact)")
    print(f"comparable exam rows: {len(rows)} of {len(all_rows)} "
          f"-- gold not in the {len(V2_ONLY_LABELS)} labels v2 added")
    print(f"  baseline  {hits_base}/{len(rows)} = {hits_base / len(rows):.4f}")
    print(f"  candidate {hits_cand}/{len(rows)} = {hits_cand / len(rows):.4f}")
    print(f"  lost {len(lost)}  gained {len(gained)}  net {hits_cand - hits_base:+d}")
    print(f"  of the {len(lost)} lost: {len(abstained)} abstain below the floor, "
          f"{len(served)} are served wrong")

    for title, idxs in (("SERVED WRONG -- a user sees these", served),
                        ("ABSTAINED -- degraded to the menu, not a lie", abstained)):
        print(f"\n{title}")
        if not idxs:
            print("  (none)")
        for i in idxs:
            print(f"  {rows[i]['id']}  {gold[i]:>16s} -> {p_cand[i]:<14s} {c_cand[i]:.4f}  "
                  f"| {rows[i]['text']}")

    if gained:
        print("\nGAINED -- wrong under the baseline, right now")
        for i in gained:
            print(f"  {rows[i]['id']}  {gold[i]:>16s}   was {p_base[i]:<14s} "
                  f"now {c_cand[i]:.4f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
