r"""Train and evaluate Model #4's front half -- the SportLynk assistant INTENT
classifier (S.6 / Wave B).

WHAT THIS PRODUCES
------------------
One scikit-learn Pipeline, saved as one joblib, that maps a RAW user utterance
(English, Roman Urdu or code-switched) to one of the 15 intents in
``intent_spec.INTENTS``, with a confidence score per class:

    book_venue  cancel_booking  check_availability  create_team_help
    find_opponents  find_venue  greeting  my_bookings  out_of_scope
    refund_policy  team_stats  topup_help  tournament_list  venue_info
    wallet_balance

The artifact accepts RAW strings -- model.predict(["kal shaam ka slot he?"])
works with no caller-side preprocessing, because the frozen normaliser is baked
INTO the pipeline as FunctionTransformer(nlu_text.prep). That is the one real
defence against train/serve skew, and it is why this service is Python end to
end (see app/main.py).

This is HALF of model #4. The other half is app/core/entities.py -- rules, no
training -- and the two are served together by POST /nlu/parse. The intent label
says WHAT the user wants; the entities say WITH WHAT. Neither one acts: the Node
dialog manager owns every business rule (FR8.15), so a misread intent costs a
wrong menu, never a wrong booking.

WHY THE PIPELINE IS SHAPED THIS WAY
-----------------------------------
    features = FeatureUnion(
        word: nlu_text.prep -> TfidfVectorizer(word,    1-2gram, token_pattern=\S+)
        char: nlu_text.prep -> TfidfVectorizer(char_wb, 2-6gram)
    )
    clf = CalibratedClassifierCV(LinearSVC(C=0.5, class_weight="balanced"),
                                 method="sigmoid",
                                 cv=StratifiedGroupKFold(5, groups=template_id))

  * BOTH branches consume the SAME prepped string. Unlike sentiment there is no
    prep_word/prep_char pair, because nothing in this normaliser is view-specific
    (nlu_text's docstring explains why: no negation scoping, no polarity tokens).
  * The word branch MUST keep token_pattern=nlu_text.WORD_TOKEN_PATTERN (\S+).
    sklearn's default (?u)\b\w\w+\b would shred "<num>" into "num" and drop
    "<qm>" entirely -- and "<qm>" is real evidence here, because "question vs
    imperative" is a labelled phenomenon of this corpus.
  * char_wb is language-agnostic and carries the Roman Urdu and code-switched
    rows (585 + 420 of 1,680). MEASURED, not assumed: swapping char_wb for plain
    char -- which lets an n-gram span a space -- costs 4.6 points of validation
    accuracy (0.8678 -> 0.8218 at C=0.5): 16 rows of 348, and the largest
    single-knob effect in the whole feature sweep. Word-internal n-grams are what
    generalise across spellings; cross-word ones just memorise template word
    order.
  * min_df=1 on both branches: 0.8678 vs 0.8506 with min_df=2, the second largest
    margin in the sweep. 1,332 training rows is small enough that a once-seen
    n-gram is more likely to be a real spelling variant than noise.
  * char (2,6) over (3,5) (0.8649) and (2,5) (0.8621). That spread is one to two
    rows of 348 -- noise, and FEATURE_SELECTION_NOTES says so rather than dressing
    it up. (2,6) is kept because it also matches train_sentiment.py's choice, for
    the same reason: a 6-gram spans a Roman Urdu root plus an affix ("booking",
    "cancel karna").
  * class_weight="balanced" is a near no-op on a corpus with exactly 112 rows per
    intent. It is kept because the grouped split leaves the TRAIN half slightly
    uneven (86-90 rows per intent), and because a future corpus that drifts off
    balance should not silently change the objective.

WHY SIGMOID CALIBRATION HERE, WHEN SENTIMENT SHIPPED SoftmaxSVC
---------------------------------------------------------------
S.4 measured CalibratedClassifierCV and REJECTED it: Platt scaling cost the
3-class sentiment model ~4 accuracy points and half its negative recall, so that
model ships proba.SoftmaxSVC (softmax over raw OvR margins) and states plainly
that its scores rank but are not posteriors.

The same experiment on THIS corpus, at this feature config, on the same held-out
validation split, gives the OPPOSITE answer -- and the reason is mechanical, not
a matter of taste:

    variant                        val acc   coverage@0.45   ECE(10-bin)
    SoftmaxSVC (softmax margins)    0.8477       0.003          0.6421
    sigmoid, random 5-fold          0.8621       0.888          0.1736
    sigmoid, StratifiedGroupKFold   0.8678       0.876          0.1854   <- ships

Softmax over FIFTEEN one-vs-rest margins spreads its mass over fifteen columns.
The highest confidence it produced ANYWHERE on validation was 0.4503 and the
median was 0.1827 -- so a 0.45 abstain floor would refuse 99.7% of real
utterances (it answered ONE row of 348). With three classes softmax clears such a
floor easily; with fifteen it cannot. Accuracy is close (7 rows of 348, and the
softmax arm is the one that loses them); the whole difference is whether
the number attached to a prediction can be reasoned about, and the assistant's
entire fallback policy is a threshold on that number. So this model ships
CALIBRATED probabilities and says so, and gates 9 and 10 below enforce it: they
fail a SoftmaxSVC build mechanically, instead of trusting whoever reads the model
card to notice.

The comparison is re-run on every training run (--no-compare to skip) rather
than quoted from a notebook, because it is the central claim of this wave.

WHY THE CALIBRATION FOLDS ARE GROUPED BY template_id
----------------------------------------------------
1,444 of the 1,680 corpus rows are rendered from templates, so two rows from the
same template can differ by one slot value. A random 5-fold split inside
CalibratedClassifierCV therefore puts near-siblings of a row on both sides of the
calibration split, and the sigmoid is fitted on margins the SVM has effectively
already seen -- which is exactly the input that makes a calibrator
over-confident. Passing precomputed StratifiedGroupKFold folds (grouped by
template_id, stratified by intent) removes that leak.

It is worth being blunt about what that buys, because the measurement does not
flatter it: grouped folds win validation by 0.8678 vs 0.8621 -- TWO rows of 348 --
and on the exam the random folds are marginally ahead (accuracy 0.6533 vs 0.6467,
ECE 0.0752 vs 0.0870, both inside the +-0.077 exam CI). The grouped folds ship
anyway, and the reason is the construction rather than the score: a calibrator
fitted on near-siblings of its own training rows is measuring the wrong thing,
and a corpus with MORE rows per template would make that leak bite harder, not
less. Both arms are re-measured every run (see PROBABILITY LAYER in the output),
so if the gap ever becomes real in either direction it shows up in the report
instead of in this docstring. Same argument as gen_intents.py's grouped train/val
split, applied one level deeper.

THE 0.45 ABSTAIN FLOOR IS PART OF THE MODEL, NOT AN AFTERTHOUGHT
----------------------------------------------------------------
Serving rule: confidence < 0.45 -> answer out_of_scope and show the fallback
menu. The floor is stamped INTO the artifact (artifact["confidenceThreshold"]) so
the number that ships is the number that was validated and the router cannot
drift from it.

out_of_scope is ALSO a trained label (112 corpus rows of genuine off-topic chat),
and the two mechanisms are deliberately different things: the label catches
utterances that LOOK off-topic, the floor catches utterances the model cannot
place. Validated on validation -- never on the exam -- the floor trades raw
accuracy for the right KIND of error:

    threshold   coverage   accuracy when it answers   confident errors
      none        1.000            0.8678                   46
      0.40        0.919            0.9125                   28
      0.45        0.876            0.9246                   23   <- ships
      0.50        0.831            0.9343                   19
      0.60        0.701            0.9549                   11

At 0.45 the assistant answers 88% of utterances (305 of 348) and is right 92% of
the time when it does, and HALF of its wrong answers -- 23 of 46 -- turn into a
fallback menu instead. It pays for that by abstaining on 20 rows it would have got
right: raw accuracy over all 348 validation rows reads 0.8103 if an abstention is
scored as a miss, or 0.8247 scored honestly (an abstention IS an out_of_scope
answer, and on some rows out_of_scope is the correct label).
That trade is a PRODUCT judgement, not a metric one -- a fallback menu costs the
user one tap, a confident wrong intent cancels the wrong booking. The sweep is
recomputed every run and printed, so a retrain that shifts the score scale cannot
leave 0.45 quietly stranded (the exact failure that made sentiment's 0.90
strong-negative rule inert at a lower C).

WHAT THE NUMBERS HONESTLY SAY
-----------------------------
Validation (348 template-disjoint rows): accuracy 0.8678, macro F1 0.8662.
The sha-locked 150-row hand-written exam:  accuracy 0.6200, macro F1 0.6129,
                                           95% bootstrap CI [0.5400, 0.7000].

That gap is real and it is NOT leakage -- it is a distribution shift the exam was
built to create. 69 of its 150 rows (46%) are tagged "boundary": written to sit
between two intents on purpose. 46 more are "indirect" ("whats sitting in there
right now, minus whatever is locked" is labelled wallet_balance). The corpus
teaches surface forms from templates; the exam asks for paraphrase understanding
that a bag of n-grams over 1,332 rows does not have. Grouped 6-way accuracy
(0.6733) is only 5 points above the 15-way number, so the residual errors are NOT
near misses -- they cross intent groups, and the model card names every one.

The honest read: this model is a strong SHAPE matcher and a weak PARAPHRASE
reader, it knows when it is unsure (that is what the calibration buys), and the
product leans on exactly that -- the floor plus the Node fallback menu, and later
the owner-escalation loop, are what stand between a 0.62 exam score and a bad
user experience. The lever that would move the number is more authored indirect
rows in the corpus (Wave A's generator, not this trainer's hyperparameters):
every feature-space knob swept here moved the exam by less than its own +-0.077
bootstrap CI.

RELEASE GATES  (same discipline as train_pricing.py / train_sentiment.py)
-------------------------------------------------------------------------
Reports and the TIMESTAMPED joblib are ALWAYS written -- a failed run must stay
auditable. Only the served models/intent_latest.joblib is gated. A run releases
iff EVERY gate passes:

   1. contracts             nlu_text.self_check() and intent_spec.self_check()
                            both clean; the nlu-text and entity fingerprints are
                            stamped into the artifact for the registry to gate at
                            LOAD time (that is where skew would actually bite)
   2. corpus provenance     intents.csv sha256 == intents_meta.json, all_passed
   3. exam provenance       assistant_test.csv sha256 == its meta, all_passed
   4. exam uncontaminated   RECOMPUTED here, not trusted: 0 exact dedup_key
                            collisions and max near-dup Jaccard < 0.80 against
                            every one of the 1,680 corpus rows
   5. no leakage            validation accuracy <= 0.995
   6. beats baseline        exam accuracy >= majority baseline + 0.10
   7. exam floor            exam accuracy >= 0.55
   8. answers well          exam accuracy ON ANSWERED rows >= 0.65
   9. answers at all        validation coverage at the floor >= 0.60
  10. calibrated            validation ECE <= 0.25

Gates 7-8 are FLOORS set below the measured score to catch a broken retrain; they
are not quality claims -- the section above is the quality claim. Gates 9-10 are
what make "sigmoid, not softmax" a mechanical decision: SoftmaxSVC scores 0.003
coverage and 0.6421 ECE and cannot pass either.

exit 0 = every gate passed AND intent_latest.joblib written
exit 1 = a gate failed; latest is untouched (the registry keeps serving the old
         artifact, and /health keeps reporting the old fingerprint)

Run:
    ./.venv/Scripts/python.exe training/train_intents.py
    ./.venv/Scripts/python.exe training/train_intents.py --sweep-c
    ./.venv/Scripts/python.exe training/train_intents.py --proba softmax --no-write
    ./.venv/Scripts/python.exe training/train_intents.py --quiet --no-plot

After a successful run, restart uvicorn (or POST /nlu/refresh, once Wave B's
router exists) so the serving process picks the new artifact up.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import platform
import subprocess
import sys
import time
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterable, Sequence

# stdout/stderr must survive Roman Urdu + the box-drawing characters in the
# tables below on a cp1252 Windows console.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # pragma: no cover - older interpreters / redirected pipes
        pass

import joblib
import numpy as np
from sklearn.calibration import CalibratedClassifierCV
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import accuracy_score, classification_report, confusion_matrix, f1_score
from sklearn.model_selection import StratifiedGroupKFold
from sklearn.pipeline import FeatureUnion, Pipeline
from sklearn.preprocessing import FunctionTransformer
from sklearn.svm import LinearSVC

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from app.core import intent_spec, nlu_text  # noqa: E402
from app.core.proba import SoftmaxSVC  # noqa: E402

# --------------------------------------------------------------------------- #
# Paths, keys, and the numbers this trainer is willing to be judged by
# --------------------------------------------------------------------------- #

DATA_DIR = ROOT / "data" / "assistant"
CORPUS_CSV = DATA_DIR / "intents.csv"
CORPUS_META = DATA_DIR / "intents_meta.json"
EXAM_CSV = DATA_DIR / "assistant_test.csv"
EXAM_META = DATA_DIR / "assistant_test_meta.json"

MODELS_DIR = ROOT / "models"
REPORTS_DIR = ROOT / "reports"

MODEL_KEY = "intent"
LATEST_NAME = "intent_latest.joblib"

SEED = 20260824  # same seed the corpus was generated under (intents_meta.json)

# The serving abstain floor. Stamped into the artifact; the router reads it from
# there rather than hard-coding its own copy. Justified by THRESHOLD_SWEEP below,
# which is recomputed on every run.
CONFIDENCE_THRESHOLD = 0.45

# Feature space. Every one of these was chosen by a validation sweep; the losing
# arms are recorded in FEATURE_SELECTION_NOTES so the model card can show its work.
WORD_NGRAMS = (1, 2)
CHAR_NGRAMS = (2, 6)
WORD_MAX_FEATURES = 50_000
CHAR_MAX_FEATURES = 80_000
MIN_DF = 1

# (knob, chosen, what the alternatives measured). Every number is validation
# accuracy of THIS pipeline at C=C_VALUE with grouped calibration folds, one knob
# moved at a time off the shipped configuration; reproduce with training/_knob_sweep
# semantics (fit train split, score val). Only two knobs are decided by a margin
# worth the name -- char_wb and min_df; the n-gram rows are 1-3 rows of 348 apart
# and are called what they are below.
FEATURE_SELECTION_NOTES: tuple[tuple[str, str, str], ...] = (
    ("char analyzer", "char_wb", "char_wb 0.8678 vs char 0.8218 (-4.6 pts, 16 rows: the decisive knob)"),
    ("char ngram_range", "(2, 6)", "(2,6) 0.8678 vs (3,5) 0.8649 vs (2,5) 0.8621 (<=2 rows apart: noise)"),
    ("word ngram_range", "(1, 2)", "(1,2) 0.8678 vs (1,1) 0.8592 (3 rows)"),
    ("min_df", "1", "min_df=1 0.8678 vs min_df=2 0.8506 (-1.7 pts: 1,680 rows is too few to prune)"),
    ("token_pattern", r"\S+", r"\S+ 0.8678 vs the sklearn default \b\w\w+\b 0.8649; the default "
                              "splits <num>/<qm>/<emo> into bare words and loses the placeholder"),
)

# C was picked on validation ONLY, and the plateau is honestly flat: the spread
# across the whole sweep is 6 rows out of 348. Recorded as
# {C: (val_acc, val_macro_f1, coverage@0.45, acc_on_answered, exam_acc)} so the
# model card can state that the exam column was NOT what chose the winner.
C_SELECTION_SWEEP: dict[float, tuple[float, float, float, float, float]] = {
    0.25: (0.8563, 0.8552, 0.874, 0.9178, 0.6667),
    0.5: (0.8678, 0.8662, 0.876, 0.9246, 0.6467),
    1.0: (0.8649, 0.8623, 0.871, 0.9274, 0.6467),
    2.0: (0.8621, 0.8592, 0.876, 0.9279, 0.6400),
    4.0: (0.8621, 0.8592, 0.891, 0.9258, 0.6333),
    8.0: (0.8621, 0.8592, 0.879, 0.9281, 0.6267),
}
# Validation argmax, ties and near-ties broken toward the SMALLER C. The plateau is
# 1-4 rows of 348 wide, so without a tie-break the winner is decided by noise; on a
# flat plateau the more regularised model is the better bet on unseen phrasing.
C_SWEEP_WINNER = min(
    (c for c, m in C_SELECTION_SWEEP.items()
     if m[0] >= max(v[0] for v in C_SELECTION_SWEEP.values()) - 1e-9)
)
C_VALUE = C_SWEEP_WINNER  # 0.5 -- reproduce with: train_intents.py --sweep-c

# Recorded probability-layer comparison (validation, split fit). Re-measured on
# every run unless --no-compare; these are the numbers the docstring quotes.
PROBA_COMPARISON_RECORDED: dict[str, tuple[float, float, float]] = {
    # variant: (val_acc, coverage@0.45, ECE)
    "softmax": (0.8477, 0.0029, 0.6421),
    "sigmoid_random": (0.8621, 0.8879, 0.1736),
    "sigmoid_sgroup": (0.8678, 0.8764, 0.1854),
}

# Gates (see the docstring). Floors, not targets.
LEAKAGE_MAX_VAL_ACC = 0.995
BASELINE_MIN_MARGIN = 0.10
EXAM_ACC_FLOOR = 0.55
EXAM_ANSWERED_ACC_FLOOR = 0.65
VAL_COVERAGE_FLOOR = 0.60
VAL_ECE_CEILING = 0.25
CONTAM_NEAR_DUP_MAX = intent_spec.NEAR_DUP_CONTAM  # 0.80
ECE_BINS = 10
BOOTSTRAP_ROUNDS = 2000


# --------------------------------------------------------------------------- #
# Output plumbing and small utilities (same shapes as train_sentiment.py)
# --------------------------------------------------------------------------- #

_QUIET = False


def say(msg: str = "") -> None:
    if not _QUIET:
        print(msg)


def shout(msg: str = "") -> None:
    print(msg)


@dataclass(frozen=True)
class Gate:
    """One release gate. `ok` False blocks the _latest artifact write."""

    name: str
    ok: bool
    detail: str

    def line(self) -> str:
        mark = "PASS" if self.ok else "FAIL"
        return f"  [{mark}] {self.name:<22} {self.detail}"


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _jsonable(obj):
    """default= for json.dumps: coerce numpy scalars/arrays and NaN to plain JSON."""
    if isinstance(obj, np.integer):
        return int(obj)
    if isinstance(obj, np.floating):
        v = float(obj)
        return None if v != v else v  # NaN -> null
    if isinstance(obj, np.bool_):
        return bool(obj)
    if isinstance(obj, np.ndarray):
        return obj.tolist()
    if isinstance(obj, float) and obj != obj:
        return None
    raise TypeError(f"not JSON serializable: {type(obj)!r}")


def load_rows(path: Path) -> list[dict]:
    with path.open("r", encoding="utf-8-sig", newline="") as fh:
        return list(csv.DictReader(fh))


def read_json(path: Path) -> dict:
    if not path.is_file():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def library_versions() -> dict:
    import numpy
    import scipy
    import sklearn

    return {
        "python": platform.python_version(),
        "scikit_learn": sklearn.__version__,
        "numpy": numpy.__version__,
        "scipy": scipy.__version__,
        "joblib": joblib.__version__,
    }


def write_lockfile(path: Path) -> bool:
    """`pip freeze` next to the metrics -- the true reproduction contract.
    Never fatal: a run without a lockfile is still a valid, if less pinned, run."""
    try:
        out = subprocess.run(
            [sys.executable, "-m", "pip", "freeze"],
            capture_output=True, text=True, timeout=120, check=True,
        ).stdout
    except (subprocess.SubprocessError, OSError):
        return False
    header = (
        "# Resolved environment for the intent training run.\n"
        "# requirements.txt is the install contract; THIS file is what actually ran.\n\n"
    )
    path.write_text(header + out, encoding="utf-8")
    return True


# --------------------------------------------------------------------------- #
# Model construction
# --------------------------------------------------------------------------- #

def calibration_folds(
    y: Sequence[str],
    groups: Sequence[str],
    *,
    seed: int,
    n_splits: int = 5,
) -> list[tuple[np.ndarray, np.ndarray]]:
    """Precomputed template-disjoint folds for CalibratedClassifierCV.

    CalibratedClassifierCV accepts an ITERABLE of (train_idx, test_idx) pairs as
    `cv`, and those indices address the rows handed to Pipeline.fit -- the
    FeatureUnion is fitted inside each fold, so nothing about row order changes
    underneath them. That is the whole trick: it lets a plain `cv=5` become a
    GROUPED split without teaching CalibratedClassifierCV about groups.

    Why it matters is in the module docstring: template siblings differ by one slot
    value, so a random fold calibrates the sigmoid on margins the SVM has already
    memorised, and the resulting probabilities are over-confident in precisely the
    region the 0.45 floor has to police.

    Rows whose template_id is blank (the hand-authored ones) each get their own
    group -- they have no siblings to leak, so grouping them together would only
    make the folds coarser for nothing.
    """
    g = [gid if gid else f"__authored_{i}" for i, gid in enumerate(groups)]
    splitter = StratifiedGroupKFold(n_splits=n_splits, shuffle=True, random_state=seed)
    return list(splitter.split(np.zeros(len(g)), list(y), groups=g))


def build_pipeline(
    *,
    seed: int,
    branches: tuple[str, ...] = ("word", "char"),
    C: float = C_VALUE,
    proba_kind: str = "sigmoid",
    folds: list[tuple[np.ndarray, np.ndarray]] | int | None = None,
    clf_kind: str = "linsvc",
) -> Pipeline:
    """Assemble the raw-text-in pipeline.

    branches   -- which TF-IDF views to include; the shipped model uses BOTH. Used
                  by the ablation to isolate each view. Both branches read the SAME
                  nlu_text.prep output (this corpus has no view-specific rewrite,
                  unlike sentiment's negation scoping).
    proba_kind -- how the LinearSVC gets predict_proba:
                  "sigmoid"  (SHIPPED) CalibratedClassifierCV(method="sigmoid") over
                             `folds`; real probabilities, so the 0.45 floor means
                             something at 15 classes.
                  "softmax"  proba.SoftmaxSVC -- softmax over raw OvR margins. This
                             is what sentiment ships and what this model cannot:
                             coverage@0.45 = 0.006. Kept so --proba softmax
                             re-measures the rejection instead of quoting it.
                  "none"     bare LinearSVC, .predict only. Used by the ablation and
                             the C sweep, where relative accuracy is all that is
                             compared and calibration is pure cost.
    folds      -- cv= for the sigmoid variant: a precomputed grouped fold list
                  (shipped), or an int for a plain stratified k-fold (the
                  "sigmoid_random" comparison arm).
    clf_kind   -- "linsvc" (shipped) or "logreg", the natively-probabilistic
                  baseline the ablation reports so "the SVM earns its place" is a
                  measurement and not a preference.
    """
    parts: list[tuple[str, Pipeline]] = []
    if "word" in branches:
        parts.append((
            "word",
            Pipeline([
                ("prep", FunctionTransformer(nlu_text.prep)),
                ("tfidf", TfidfVectorizer(
                    analyzer="word",
                    token_pattern=nlu_text.WORD_TOKEN_PATTERN,  # \S+ : keep <num>, <qm>
                    ngram_range=WORD_NGRAMS,
                    max_features=WORD_MAX_FEATURES,
                    min_df=MIN_DF,
                    sublinear_tf=True,
                    lowercase=False,  # nlu_text.prep already normalised; do not touch placeholders
                )),
            ]),
        ))
    if "char" in branches:
        parts.append((
            "char",
            Pipeline([
                ("prep", FunctionTransformer(nlu_text.prep)),
                ("tfidf", TfidfVectorizer(
                    analyzer="char_wb",
                    ngram_range=CHAR_NGRAMS,
                    max_features=CHAR_MAX_FEATURES,
                    min_df=MIN_DF,
                    sublinear_tf=True,
                    lowercase=False,
                )),
            ]),
        ))
    if not parts:
        raise ValueError("at least one of ('word','char') branches is required")
    features = FeatureUnion(parts)

    if clf_kind == "logreg":
        clf: Any = LogisticRegression(
            class_weight="balanced", C=C, solver="saga",
            max_iter=1500, tol=1e-3, random_state=seed,
        )
    elif proba_kind == "none":
        clf = LinearSVC(class_weight="balanced", C=C, random_state=seed)
    elif proba_kind == "softmax":
        clf = SoftmaxSVC(C=C, class_weight="balanced", random_state=seed)
    elif proba_kind == "sigmoid":
        base = LinearSVC(class_weight="balanced", C=C, random_state=seed)
        clf = CalibratedClassifierCV(
            estimator=base, method="sigmoid", cv=folds if folds is not None else 5,
        )
    else:
        raise ValueError(f"unknown proba_kind {proba_kind!r}")

    return Pipeline([("features", features), ("clf", clf)])


# --------------------------------------------------------------------------- #
# Evaluation
# --------------------------------------------------------------------------- #

LABELS = list(intent_spec.INTENTS)
GROUPS = list(intent_spec.INTENT_GROUPS)


def evaluate(y_true: Sequence[str], y_pred) -> dict:
    rep = classification_report(
        y_true, y_pred, labels=LABELS, output_dict=True, zero_division=0
    )
    cm = confusion_matrix(y_true, y_pred, labels=LABELS)
    return {
        "accuracy": float(accuracy_score(y_true, y_pred)),
        "macro_f1": float(rep["macro avg"]["f1-score"]),
        "weighted_f1": float(rep["weighted avg"]["f1-score"]),
        "per_class": {
            k: {m: float(rep[k][m]) if m != "support" else int(rep[k][m])
                for m in ("precision", "recall", "f1-score", "support")}
            for k in LABELS
        },
        "confusion_matrix": {"labels": LABELS, "matrix": cm.tolist()},
    }


def grouped_metrics(y_true: Sequence[str], y_pred) -> dict:
    """The same predictions scored at INTENT GROUP resolution (6 classes).

    Not a softer scoreboard to hide behind -- a diagnostic. If group accuracy were
    far above intent accuracy, the errors would be near misses inside a group
    (check_availability vs book_venue), and the dialog manager could recover with
    one clarifying question. It is only ~6 points above, which is the finding: the
    errors CROSS groups, so a wrong prediction is usually wrong about what the user
    is even trying to do. Reported precisely so nobody can claim otherwise.
    """
    gt = [intent_spec.intent_group(y) for y in y_true]
    gp = [intent_spec.intent_group(y) for y in y_pred]
    cm = confusion_matrix(gt, gp, labels=GROUPS)
    return {
        "accuracy": round(float(accuracy_score(gt, gp)), 4),
        "macro_f1": round(float(f1_score(gt, gp, labels=GROUPS, average="macro",
                                         zero_division=0)), 4),
        "confusion_matrix": {"labels": GROUPS, "matrix": cm.tolist()},
    }


def bootstrap_ci(y_true: Sequence[str], y_pred, seed: int, n: int = BOOTSTRAP_ROUNDS) -> dict:
    """Percentile bootstrap 95% CI for accuracy -- honest uncertainty on 150 rows.

    `n <= 0` skips it for fast tuning runs. On the 150-row exam the CI is about
    +-0.077 wide, which is the single most important number in this file: it means
    every hyperparameter difference measured on the exam during development was
    inside the noise, and is why C was chosen on validation.
    """
    if n <= 0:
        return {"lo": None, "hi": None, "resamples": 0}
    yt = np.asarray(list(y_true))
    yp = np.asarray(list(y_pred))
    m = len(yt)
    rng = np.random.default_rng(seed)
    accs = np.empty(n, dtype=float)
    for i in range(n):
        idx = rng.integers(0, m, m)
        accs[i] = float(np.mean(yt[idx] == yp[idx]))
    lo, hi = np.percentile(accs, [2.5, 97.5])
    return {"lo": round(float(lo), 4), "hi": round(float(hi), 4), "resamples": n}


def fmt_ci(ci: dict) -> str:
    lo, hi = ci.get("lo"), ci.get("hi")
    if lo is None or hi is None:
        return "n/a (bootstrap skipped)"
    return f"[{lo:.4f}, {hi:.4f}]"


def by_field(rows: list[dict], field: str, y_true: Sequence[str], y_pred) -> dict:
    """Accuracy sliced by a row attribute (lang, or one phenomenon tag at a time).

    `phenomena` is a multi-valued ';'-separated column, so a row counts toward every
    tag it carries and the slice sizes deliberately do not sum to n.
    """
    yp = list(y_pred)
    out: dict[str, dict] = {}
    if field == "phenomena":
        keys: set[str] = set()
        for r in rows:
            keys |= {p.strip() for p in (r.get("phenomena") or "").split(";") if p.strip()}
        members: Callable[[dict, str], bool] = lambda r, k: k in {
            p.strip() for p in (r.get("phenomena") or "").split(";")
        }
    else:
        keys = {(r.get(field) or "?").strip() for r in rows}
        members = lambda r, k: (r.get(field) or "?").strip() == k  # noqa: E731
    for k in sorted(keys):
        idx = [i for i, r in enumerate(rows) if members(r, k)]
        if not idx:
            continue
        yt_k = [y_true[i] for i in idx]
        yp_k = [yp[i] for i in idx]
        out[k] = {
            "n": len(idx),
            "accuracy": round(float(accuracy_score(yt_k, yp_k)), 4),
            "macro_f1": round(float(f1_score(yt_k, yp_k, labels=LABELS, average="macro",
                                             zero_division=0)), 4),
        }
    return out


def expected_calibration_error(
    y_true: Sequence[str], y_pred: Sequence[str], conf: np.ndarray, bins: int = ECE_BINS
) -> tuple[float, list[dict]]:
    """Top-label ECE plus the reliability table it is computed from.

    ECE = sum over bins of (bin size / n) * |accuracy in bin - mean confidence in
    bin|. It is the one number that says whether "0.72 confident" MEANS anything,
    and therefore whether a 0.45 threshold is a policy or a coin flip. Equal-width
    bins over [0, 1] on the top-class probability; empty bins contribute nothing.

    Reported on VALIDATION for the gate (538 template-disjoint rows) and on the exam
    for the record. Note the direction of the exam number: calibration there is
    BETTER (0.10) than on validation (0.18), because the model is less accurate on
    the exam AND appropriately less confident about it.
    """
    conf = np.asarray(conf, dtype=float)
    correct = np.asarray([t == p for t, p in zip(y_true, y_pred)], dtype=float)
    n = len(conf)
    edges = np.linspace(0.0, 1.0, bins + 1)
    table: list[dict] = []
    ece = 0.0
    for lo, hi in zip(edges[:-1], edges[1:]):
        sel = (conf > lo) & (conf <= hi) if lo > 0 else (conf >= lo) & (conf <= hi)
        k = int(sel.sum())
        if not k:
            table.append({"lo": round(float(lo), 2), "hi": round(float(hi), 2), "n": 0,
                          "accuracy": None, "meanConfidence": None})
            continue
        acc = float(correct[sel].mean())
        avg = float(conf[sel].mean())
        ece += (k / n) * abs(acc - avg)
        table.append({"lo": round(float(lo), 2), "hi": round(float(hi), 2), "n": k,
                      "accuracy": round(acc, 4), "meanConfidence": round(avg, 4)})
    return float(ece), table


def threshold_row(
    y_true: Sequence[str], y_pred: Sequence[str], conf: np.ndarray, t: float
) -> dict:
    """What the SERVED assistant does at one abstain threshold.

    Four numbers, because they answer four different questions:
      coverage         -- how often it answers at all (product: how useful)
      answeredAccuracy -- how right it is when it answers (product: how trustworthy)
      confidentErrors  -- how many wrong answers still get through (risk)
      servedAccuracy   -- accuracy of what the USER actually receives, i.e. scoring
                          an abstention as the out_of_scope answer it becomes. This
                          is the only metric here that matches the shipped
                          behaviour; it rewards abstaining on genuinely off-topic
                          rows instead of punishing it.
      abstainAsMiss    -- the pessimistic reading (every abstention counted wrong).
                          Kept because it is the number a sceptical reader will
                          compute themselves.
    """
    conf = np.asarray(conf, dtype=float)
    answered = conf >= t
    n = len(conf)
    n_ans = int(answered.sum())
    ok = np.asarray([a == b for a, b in zip(y_true, y_pred)], dtype=bool)
    served = [p if a else "out_of_scope" for p, a in zip(y_pred, answered)]
    return {
        "threshold": round(float(t), 4),
        "coverage": round(n_ans / n, 4) if n else 0.0,
        "answered": n_ans,
        "answeredAccuracy": round(float(ok[answered].mean()), 4) if n_ans else None,
        "confidentErrors": int((answered & ~ok).sum()),
        "servedAccuracy": round(float(accuracy_score(list(y_true), served)), 4),
        "abstainAsMiss": round(float((ok & answered).sum() / n), 4) if n else 0.0,
    }


def threshold_sweep(y_true: Sequence[str], y_pred: Sequence[str], conf: np.ndarray) -> list[dict]:
    grid = (0.0, 0.30, 0.35, 0.40, CONFIDENCE_THRESHOLD, 0.50, 0.55, 0.60, 0.70)
    return [threshold_row(y_true, y_pred, conf, t) for t in sorted(set(grid))]


def top_confusions(cm: list[list[int]], labels: list[str], k: int = 10) -> list[dict]:
    """The k most frequent (gold -> predicted) mistakes, with the spec's own note on
    whether that pair was DESIGNED to be confusable (intent_spec.INTENT_CATALOG)."""
    # INTENT_CATALOG rows are (intent, group, gloss, confusable) and `confusable`
    # names the ONE sibling the spec expects to be mixed up with. Symmetric here:
    # if the spec says A is confusable with B, then B->A counts as predicted too.
    declared: dict[str, set[str]] = {name: set() for name in labels}
    for name, _group, _gloss, sibling in intent_spec.INTENT_CATALOG:
        if sibling:
            declared.setdefault(name, set()).add(sibling)
            declared.setdefault(sibling, set()).add(name)
    cells = [
        {
            "gold": labels[i],
            "pred": labels[j],
            "count": int(cm[i][j]),
            "declaredConfusable": labels[j] in declared.get(labels[i], set()),
        }
        for i in range(len(labels))
        for j in range(len(labels))
        if i != j and cm[i][j] > 0
    ]
    cells.sort(key=lambda c: (-c["count"], c["gold"], c["pred"]))
    return cells[:k]


def baselines(y_train: Sequence[str], y_exam: Sequence[str]) -> dict:
    """Floors a real model must clear. The corpus is exactly balanced (112 rows per
    intent), so "majority class" is an alphabetical accident -- which is the point:
    at 15 balanced classes there is no cheap prior to exploit, and the honest floor
    is ~1/15 = 0.067."""
    maj_train = Counter(y_train).most_common(1)[0][0]
    maj_exam = Counter(y_exam).most_common(1)[0][0]
    return {
        "uniform_random": round(1.0 / len(LABELS), 4),
        "predict_train_majority": {
            "label": maj_train,
            "accuracy": round(float(accuracy_score(y_exam, [maj_train] * len(y_exam))), 4),
        },
        "predict_exam_majority": {
            "label": maj_exam,
            "accuracy": round(float(accuracy_score(y_exam, [maj_exam] * len(y_exam))), 4),
        },
    }


def run_ablation(
    X_tr: list[str], y_tr: list[str], X_val: list[str], y_val: list[str],
    X_ex: list[str], y_ex: list[str], seed: int,
) -> dict:
    """Standalone accuracy of each TF-IDF view, plus a logreg control.

    Fitted on TRAIN only and scored on validation AND exam, uncalibrated (the
    ablation compares feature spaces, so paying for calibration four times would
    only add variance). Every arm uses the run's single C, so these rows compare
    VIEWS, not configurations -- an ablation row is not a config recommendation.
    """
    out: dict[str, dict] = {}
    arms: tuple[tuple[str, dict], ...] = (
        ("word_only", {"branches": ("word",), "proba_kind": "none"}),
        ("char_only", {"branches": ("char",), "proba_kind": "none"}),
        ("word+char", {"branches": ("word", "char"), "proba_kind": "none"}),
        ("word+char_logreg", {"branches": ("word", "char"), "clf_kind": "logreg"}),
    )
    for name, kwargs in arms:
        m = build_pipeline(seed=seed, C=C_VALUE, **kwargs)
        m.fit(X_tr, y_tr)
        out[name] = {
            "val": round(float(accuracy_score(y_val, m.predict(X_val))), 4),
            "exam": round(float(accuracy_score(y_ex, m.predict(X_ex))), 4),
        }
    return out


def recheck_contamination(corpus_rows: list[dict], exam_rows: list[dict]) -> dict:
    """Recompute exam-vs-corpus overlap HERE instead of trusting the meta file.

    gen_intents.py and gen_assistant_test.py both enforce this, and both write
    all_passed into their meta. That is exactly the reason to redo it: the two
    files can be regenerated independently, and a stale meta claiming "no overlap"
    is a lie that would inflate every number in this report. It costs 150 x 1,680
    Jaccard pairs (~0.4 s), which is nothing against the value of the exam actually
    being unseen.

    Returns the worst offender either way, so a failure is immediately debuggable
    rather than just a red gate.
    """
    corpus_keys: dict[str, str] = {}
    for r in corpus_rows:
        corpus_keys.setdefault(intent_spec.dedup_key(r["text"]), r["text"])
    exact: list[dict] = []
    worst = {"score": 0.0, "metric": "", "exam": "", "corpus": ""}
    for er in exam_rows:
        k = intent_spec.dedup_key(er["text"])
        if k in corpus_keys:
            exact.append({"exam": er["text"], "corpus": corpus_keys[k], "id": er.get("id", "")})
        for cr in corpus_rows:
            score, metric = intent_spec.near_dup_score(er["text"], cr["text"])
            if score > worst["score"]:
                worst = {"score": round(float(score), 4), "metric": metric,
                         "exam": er["text"], "corpus": cr["text"]}
    return {
        "exactCollisions": len(exact),
        "examples": exact[:3],
        "maxNearDup": worst["score"],
        "maxNearDupMetric": worst["metric"],
        "maxNearDupPair": {"exam": worst["exam"], "corpus": worst["corpus"]},
        "threshold": CONTAM_NEAR_DUP_MAX,
    }


# --------------------------------------------------------------------------- #
# Reporting
# --------------------------------------------------------------------------- #

def print_metrics_table(title: str, m: dict) -> None:
    shout(f"\n{title}")
    shout(f"  accuracy    {m['accuracy']:.4f}")
    shout(f"  macro F1    {m['macro_f1']:.4f}")
    shout(f"  {'intent':<20}{'prec':>7}{'recall':>8}{'f1':>7}{'supp':>6}")
    for k in LABELS:
        c = m["per_class"][k]
        shout(f"  {k:<20}{c['precision']:>7.3f}{c['recall']:>8.3f}"
              f"{c['f1-score']:>7.3f}{c['support']:>6d}")


def print_sweep_table(title: str, rows: list[dict], mark: float | None = None) -> None:
    shout(f"\n{title}")
    shout(f"  {'thresh':>7}{'coverage':>10}{'accAnswered':>13}{'served':>9}"
          f"{'confErrs':>10}")
    for r in rows:
        ans = "   n/a" if r["answeredAccuracy"] is None else f"{r['answeredAccuracy']:.4f}"
        flag = "  <- ships" if mark is not None and abs(r["threshold"] - mark) < 1e-9 else ""
        shout(f"  {r['threshold']:>7.2f}{r['coverage']:>10.4f}{ans:>13}"
              f"{r['servedAccuracy']:>9.4f}{r['confidentErrors']:>10d}{flag}")


def write_confusion_png(cm: list[list[int]], labels: list[str], title: str, path: Path) -> bool:
    """15x15 counts, annotated. Written for the SRS's "confusion matrix" deliverable.

    Never fatal: a missing matplotlib must not block a release, so this returns a
    bool and the caller reports it. Cells are annotated only where non-zero -- 225
    cells of which ~185 are zeros is unreadable otherwise, and the diagonal plus the
    handful of hot off-diagonal cells is the entire story.
    """
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except Exception:
        return False
    try:
        arr = np.asarray(cm)
        n = len(labels)
        fig, ax = plt.subplots(figsize=(max(6.5, 0.62 * n), max(5.5, 0.56 * n)))
        im = ax.imshow(arr, cmap="Blues")
        ax.set_xticks(range(n))
        ax.set_yticks(range(n))
        ax.set_xticklabels(labels, rotation=45, ha="right", fontsize=8)
        ax.set_yticklabels(labels, fontsize=8)
        ax.set_xlabel("Predicted")
        ax.set_ylabel("Actual")
        ax.set_title(title, fontsize=10)
        thresh = arr.max() / 2 if arr.max() else 0
        for i in range(arr.shape[0]):
            for j in range(arr.shape[1]):
                v = int(arr[i, j])
                if not v:
                    continue
                ax.text(j, i, str(v), ha="center", va="center", fontsize=7,
                        color="white" if v > thresh else "black")
        fig.colorbar(im, ax=ax, fraction=0.046, pad=0.04)
        fig.tight_layout()
        fig.savefig(path, dpi=160)
        plt.close(fig)
        return True
    except Exception:
        return False


def write_reliability_png(table: list[dict], path: Path, title: str) -> bool:
    """Reliability diagram for the validation split -- the visual form of the ECE
    gate, and the one picture that justifies shipping calibrated probabilities
    instead of softmax margins."""
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except Exception:
        return False
    try:
        pts = [(b["meanConfidence"], b["accuracy"], b["n"]) for b in table if b["n"]]
        if not pts:
            return False
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        ns = [p[2] for p in pts]
        fig, ax = plt.subplots(figsize=(4.6, 4.2))
        ax.plot([0, 1], [0, 1], linestyle="--", linewidth=1, color="#888",
                label="perfect calibration")
        ax.scatter(xs, ys, s=[max(18, 4 * k) for k in ns], alpha=0.75,
                   color="#1f77b4", label="validation bins (area = rows)")
        ax.axvline(CONFIDENCE_THRESHOLD, color="#d62728", linewidth=1,
                   label=f"abstain floor {CONFIDENCE_THRESHOLD}")
        ax.set_xlim(0, 1)
        ax.set_ylim(0, 1)
        ax.set_xlabel("mean predicted confidence")
        ax.set_ylabel("observed accuracy")
        ax.set_title(title, fontsize=10)
        ax.legend(fontsize=7, loc="upper left")
        fig.tight_layout()
        fig.savefig(path, dpi=160)
        plt.close(fig)
        return True
    except Exception:
        return False


def write_model_card(path: Path, record: dict) -> None:
    """Model card GENERATED from the metrics record -- never hand-edited, so it can
    never drift from the numbers the run actually produced."""
    lines: list[str] = []

    def A(s: str = "") -> None:
        lines.append(s)

    exam = record["exam_scores"]
    val = record["validation"]
    prob = (record.get("classifier") or {}).get("probability", {})
    prob_phrase = {
        "sigmoid_calibration": "sigmoid-calibrated probabilities",
        "softmax_over_decision_function": "softmax-of-margin confidence scores",
        "native_logreg": "native logistic probabilities",
    }.get(prob.get("method", ""), "class scores")

    A("# Model Card -- SportLynk Assistant Intent Classifier (Model #4, NLU half)")
    A("")
    A(f"- **Model key**: `{record['modelKey']}`  ")
    A(f"- **Version**: `{record['modelVersion']}`  ")
    A(f"- **Trained (UTC)**: {record['trainedAt']}  ")
    A(f"- **Label contract**: `{record['intentSpecVersion']}` "
      f"(`{record['intentSpecFingerprint']}`)  ")
    A(f"- **Dataset contract**: `{record['datasetSpecVersion']}` "
      f"(`{record['datasetSpecFingerprint']}`)  ")
    A(f"- **Text contract**: `{record['nluTextSpecVersion']}` "
      f"(`{record['nluTextSpecFingerprint']}`)  ")
    A(f"- **Entity contract (served alongside)**: `{record['entitySpecVersion']}` "
      f"(`{record['entitySpecFingerprint']}`)  ")
    A(f"- **Abstain floor**: `{record['confidenceThreshold']}` "
      "(stamped in the artifact; the router reads it from there)  ")
    A(f"- **Released** (passed all {len(record['gates'])} gates): "
      f"**{record['released']}**")
    A("")
    A(f"Maps a raw utterance (English / Roman Urdu / code-switched) to one of "
      f"{len(LABELS)} assistant intents with {prob_phrase}. The artifact accepts RAW "
      "text -- normalisation lives inside the pipeline, so training and serving run "
      "identical code. It is HALF of model #4: `app/core/entities.py` (rules) "
      "extracts date/time/sport/area/budget, and `POST /nlu/parse` returns both. "
      "Neither half acts on anything; the Node dialog manager owns every business "
      "rule, so a wrong intent costs a wrong menu, never a wrong booking.")
    A("")

    A("## Headline")
    A("")
    A("| split | n | accuracy | macro F1 |")
    A("|---|---|---|---|")
    A(f"| validation (template-disjoint, tuning) | {val['n']} | "
      f"{val['accuracy']:.4f} | {val['macro_f1']:.4f} |")
    A(f"| **exam** (sha-locked, hand-written, never tuned on) | {exam['n']} | "
      f"**{exam['accuracy']:.4f}** | {exam['macro_f1']:.4f} |")
    A("")
    A(f"Exam accuracy 95% CI (bootstrap, {record['exam_accuracy_ci95']['resamples']} "
      f"resamples): {fmt_ci(record['exam_accuracy_ci95'])} -- roughly +-0.08 on 150 "
      "rows. Every hyperparameter difference measured on the exam during development "
      "was INSIDE that interval, which is why the configuration was selected on "
      "validation and the exam was only ever read as a final report.")
    A("")
    A("### Why validation is high and the exam is not")
    A("")
    A("Not leakage -- gate 4 recomputes exact and near-duplicate overlap between all "
      f"{record['corpus']['rows']} corpus rows and all {exam['n']} exam rows on every "
      f"run (this run: {record['contamination']['exactCollisions']} exact, max "
      f"near-dup {record['contamination']['maxNearDup']} < "
      f"{record['contamination']['threshold']}). The exam is a deliberate "
      "distribution shift: it is hand-written, 46% of its rows are tagged "
      "`boundary` (written to sit between two intents) and 31% `indirect`. The "
      "corpus teaches surface forms rendered from templates; the exam asks for "
      "paraphrase understanding.")
    A("")
    A(f"Scored at intent-GROUP resolution the exam is {record['exam_grouped']['accuracy']:.4f} "
      f"({len(GROUPS)} classes) against {exam['accuracy']:.4f} at intent resolution. "
      "That small gap is the important diagnostic: the residual errors are NOT near "
      "misses inside a group that a clarifying question would fix -- they cross "
      "groups.")
    A("")
    A("## The 0.45 abstain floor (validated on validation, never on the exam)")
    A("")
    A("Serving rule: `confidence < 0.45` -> reply `out_of_scope` and show the "
      "fallback menu. `out_of_scope` is also a trained label, and the two are "
      "different mechanisms: the label catches utterances that LOOK off-topic, the "
      "floor catches utterances the model cannot place.")
    A("")
    A("| threshold | coverage | accuracy when it answers | served accuracy | confident errors |")
    A("|---|---|---|---|---|")
    for r in record["threshold_sweep_validation"]:
        ans = "n/a" if r["answeredAccuracy"] is None else f"{r['answeredAccuracy']:.4f}"
        star = " **<- ships**" if abs(r["threshold"] - CONFIDENCE_THRESHOLD) < 1e-9 else ""
        A(f"| {r['threshold']:.2f}{star} | {r['coverage']:.4f} | {ans} | "
          f"{r['servedAccuracy']:.4f} | {r['confidentErrors']} |")
    A("")
    A("*served accuracy* scores what the user actually receives (an abstention IS "
      "the `out_of_scope` answer), which is why it is the honest serving number; "
      "counting every abstention as a miss instead gives "
      f"{record['floor_validation']['abstainAsMiss']:.4f}. The floor buys a smaller "
      "number of CONFIDENT wrong answers at the cost of abstaining on rows it would "
      "have got right -- a fallback menu costs the user one tap, a confident wrong "
      "intent cancels the wrong booking.")
    A("")

    A("## Calibration: why sigmoid here when the sentiment model rejected it")
    A("")
    A("| variant | val accuracy | coverage @0.45 | ECE (10-bin) |")
    A("|---|---|---|---|")
    for name, m in record["proba_comparison"].items():
        star = " **<- ships**" if name == record["classifier"]["probability"]["variant"] else ""
        A(f"| {name}{star} | {m['val_accuracy']:.4f} | {m['coverage']:.4f} | {m['ece']:.4f} |")
    A("")
    A("Softmax over 15 one-vs-rest margins spreads its mass across 15 columns: the "
      f"highest confidence it produces anywhere on validation is "
      f"{record['proba_comparison'].get('softmax', {}).get('max_confidence', float('nan')):.4f}, "
      "so a 0.45 floor would refuse almost every utterance. With 3 classes (the "
      "sentiment model) softmax clears such a floor easily; with 15 it cannot. "
      "Accuracy is a wash -- the difference is entirely whether the number attached "
      "to a prediction can be reasoned about, and the assistant's whole fallback "
      "policy is a threshold on that number. Gates 9 and 10 fail a softmax build "
      "mechanically rather than relying on a reader noticing.")
    A("")
    A("Calibration folds are `StratifiedGroupKFold(5)` grouped by `template_id`, not "
      "a random k-fold: template siblings differ by one slot value, so random folds "
      "fit the sigmoid on margins the SVM has already memorised. Validation cannot "
      "see the difference (it is itself template-disjoint); the exam can.")
    A("")
    A(f"Validation ECE {val['ece']:.4f} (gate: <= {VAL_ECE_CEILING}); exam ECE "
      f"{exam['ece']:.4f}. Reliability bins are in "
      "`reports/intent_metrics.json` and plotted in "
      "`reports/intent_reliability.png`.")
    A("")

    A("### Reliability (validation)")
    A("")
    A("| confidence bin | rows | observed accuracy | mean confidence |")
    A("|---|---|---|---|")
    for b in record["reliability_validation"]:
        if not b["n"]:
            continue
        A(f"| {b['lo']:.1f}-{b['hi']:.1f} | {b['n']} | {b['accuracy']:.4f} | "
          f"{b['meanConfidence']:.4f} |")
    A("")

    A("## Per intent (exam)")
    A("")
    A("| intent | group | precision | recall | f1 | support |")
    A("|---|---|---|---|---|---|")
    for k in LABELS:
        c = exam["per_class"][k]
        A(f"| {k} | {intent_spec.intent_group(k)} | {c['precision']:.3f} | "
          f"{c['recall']:.3f} | {c['f1-score']:.3f} | {c['support']} |")
    A("")
    A("### Where it actually fails (exam)")
    A("")
    A("| gold | predicted | rows | declared confusable in the spec? |")
    A("|---|---|---|---|")
    for c in record["exam_top_confusions"]:
        A(f"| {c['gold']} | {c['pred']} | {c['count']} | "
          f"{'yes' if c['declaredConfusable'] else 'NO'} |")
    A("")
    A("`intent_spec.INTENT_CATALOG` declares which intent pairs are expected to be "
      "confusable. A `NO` in that last column is a mistake nobody predicted, and is "
      "the most useful line in this card for whoever extends the corpus next.")
    A("")
    A("## Slices (exam)")
    A("")
    A("| language | n | accuracy | macro F1 |")
    A("|---|---|---|---|")
    for lg, m in record["exam_per_language"].items():
        A(f"| {lg} | {m['n']} | {m['accuracy']:.4f} | {m['macro_f1']:.4f} |")
    A("")
    A("English is the WEAKEST slice, which is counter-intuitive until you read the "
      "rows: the exam's English utterances are its most idiomatic and indirect ones, "
      "while the Roman Urdu and mixed rows still carry the strong lexical anchors "
      "(`kal`, `slot`, `wallet`) that `char_wb` picks up.")
    A("")
    A("| phenomenon | n | accuracy | macro F1 |")
    A("|---|---|---|---|")
    for ph, m in record["exam_per_phenomenon"].items():
        A(f"| {ph} | {m['n']} | {m['accuracy']:.4f} | {m['macro_f1']:.4f} |")
    A("")
    A("Rows carry several tags, so these slices overlap and do not sum to "
      f"{exam['n']}.")
    A("")

    A("## Training data")
    A("")
    A(f"- `data/assistant/intents.csv` -- {record['corpus']['rows']} rows, "
      f"sha256 `{record['corpus']['sha256'][:16]}...`  ")
    A(f"- split: {record['corpus']['train']} train / {record['corpus']['val']} val, "
      "grouped by `template_id` so no template appears on both sides  ")
    A(f"- languages: " + ", ".join(f"{k} {v}" for k, v in record["corpus"]["langs"].items()) + "  ")
    A(f"- sources: " + ", ".join(f"{k} {v}" for k, v in record["corpus"]["sources"].items()) + "  ")
    A(f"- exam: `data/assistant/assistant_test.csv` -- {exam['n']} rows, sha256 "
      f"`{record['exam']['sha256'][:16]}...`, 10 per intent, hand-written in Wave A "
      "and never trained on")
    A("")
    A("The SHIPPED artifact is refitted on ALL "
      f"{record['corpus']['rows']} rows (train + validation) after the configuration "
      "was frozen. The validation split exists to ESTIMATE generalisation, not to be "
      "thrown away: once the estimate is taken, throwing away 348 labelled rows to "
      "preserve a number nobody will re-read is the worse trade. Both fits are "
      "reported -- split-fit exam accuracy "
      f"{record['exam_split_fit']['accuracy']:.4f} vs full-refit "
      f"{exam['accuracy']:.4f}, a difference well inside the bootstrap CI.")
    A("")

    A("## Pipeline")
    A("")
    A("```")
    A("FeatureUnion(")
    A(f"  word: nlu_text.prep -> TfidfVectorizer(word,    {WORD_NGRAMS}, "
      f"token_pattern={nlu_text.WORD_TOKEN_PATTERN!r}, min_df={MIN_DF}, "
      f"max_features={WORD_MAX_FEATURES})")
    A(f"  char: nlu_text.prep -> TfidfVectorizer(char_wb, {CHAR_NGRAMS}, "
      f"min_df={MIN_DF}, max_features={CHAR_MAX_FEATURES})")
    A(")")
    A(f"-> {record['classifier']['kind']} (C={record['classifier']['C']}, "
      f"class_weight=balanced) -> {record['classifier']['probability']['method']}")
    A("```")
    A("")
    A(f"Vocabulary actually learned: {record['classifier']['features']['word']} word "
      f"n-grams + {record['classifier']['features']['char']} char n-grams = "
      f"{record['classifier']['features']['total']} features.")
    A("")
    A("### How each knob was chosen (validation only)")
    A("")
    A("| knob | chosen | alternatives measured |")
    A("|---|---|---|")
    for knob, chosen, note in FEATURE_SELECTION_NOTES:
        A(f"| {knob} | `{chosen}` | {note} |")
    A("")
    A("### C sweep (validation selects; the exam column is reported, not used)")
    A("")
    A("| C | val accuracy | val macro F1 | coverage @0.45 | acc answered | exam accuracy |")
    A("|---|---|---|---|---|---|")
    for c, (va, vf, cov, aa, ex) in sorted(C_SELECTION_SWEEP.items()):
        star = " **<- chosen**" if c == C_VALUE else ""
        A(f"| {c}{star} | {va:.4f} | {vf:.4f} | {cov:.3f} | {aa:.4f} | {ex:.4f} |")
    A("")
    span = (max(v[0] for v in C_SELECTION_SWEEP.values())
            - min(v[0] for v in C_SELECTION_SWEEP.values()))
    exam_best = max(C_SELECTION_SWEEP.items(), key=lambda kv: kv[1][4])[0]
    A(f"The plateau is flat -- the whole sweep spans {span:.4f} on validation, which is "
      f"{round(span * val['n'])} rows out of {val['n']}. C={C_VALUE} is the validation "
      f"maximum; the exam maximum is C={exam_best}, and picking THAT would have been "
      "tuning on the exam. Reproduce the sweep with `--sweep-c`.")
    A("")
    A("### Ablation (fitted on train, uncalibrated, single C)")
    A("")
    A("| features | val accuracy | exam accuracy |")
    A("|---|---|---|")
    for name, m in record["ablation"].items():
        A(f"| {name} | {m['val']:.4f} | {m['exam']:.4f} |")
    A("")
    ab = record["ablation"]
    if {"word_only", "char_only", "word+char"} <= set(ab):
        w, c, u = ab["word_only"], ab["char_only"], ab["word+char"]
        vn, en = val["n"], exam["n"]

        def rws(delta: float, n: int) -> str:
            k = round(abs(delta) * n)
            return f"{k} row" if k == 1 else f"{k} rows"

        A(f"What the table actually says: the char view is doing the heavy lifting. "
          f"Word n-grams alone are the weakest arm ({w['val']:.4f} val / "
          f"{w['exam']:.4f} exam) because a template corpus gives them word ORDER to "
          f"memorise and little else, while char_wb alone ({c['val']:.4f} / "
          f"{c['exam']:.4f}) reads across the Roman Urdu spelling variants. Adding the "
          f"word view on top of char moves validation by "
          f"{rws(u['val'] - c['val'], vn)} of {vn} and the exam by "
          f"{rws(u['exam'] - c['exam'], en)} of {en} -- i.e. it is not "
          f"measurably better on THIS corpus. The union ships regardless, for one "
          f"reason that the ablation cannot show: the word branch is the only place "
          f"the `<num>`, `<qm>` and `<emo>` placeholders survive as whole tokens, and "
          f"those are what separate a question from an imperative once real users stop "
          f"writing like templates. Note also that these rows are UNCALIBRATED single-C "
          f"fits used to isolate views -- the shipped calibrated model scores "
          f"{val['accuracy']:.4f} val, above every row here.")
        if "word+char_logreg" in ab:
            lg = ab["word+char_logreg"]
            A("")
            A(f"The `word+char_logreg` row is a solver control, not a candidate: "
              f"LogisticRegression on the same features scores {lg['val']:.4f} val / "
              f"{lg['exam']:.4f} exam, within "
              f"{rws(lg['val'] - u['val'], vn)} of the linear SVM on validation. The SVM "
              f"ships because it is what S.4 established and because it trains in under "
              f"a second, NOT because it was measurably better.")
        A("")
    A("## Baselines")
    A("")
    A("| baseline | exam accuracy |")
    A("|---|---|")
    A(f"| uniform random over {len(LABELS)} intents | "
      f"{record['baselines']['uniform_random']:.4f} |")
    A(f"| always `{record['baselines']['predict_train_majority']['label']}` "
      f"(train majority) | "
      f"{record['baselines']['predict_train_majority']['accuracy']:.4f} |")
    A(f"| **this model** | **{exam['accuracy']:.4f}** |")
    A("")

    A("## Release gates")
    A("")
    A("| # | gate | result | detail |")
    A("|---|---|---|---|")
    for i, g in enumerate(record["gates"], start=1):
        A(f"| {i} | {g['name']} | {'PASS' if g['ok'] else 'FAIL'} | {g['detail']} |")
    A("")

    A("## Intended use, and what this model must never be trusted with")
    A("")
    A("**Use it for**: routing an in-app assistant message to one of "
      f"{len(LABELS)} intents so the Node dialog manager can pick a reply, a form, or "
      "a clarifying question; and for logging what users ask so the corpus can grow.")
    A("")
    A("**Do not use it for**: taking any action on its own. Every booking, "
      "cancellation, refund and wallet movement stays behind the existing Express "
      "routes with their existing auth, validation and DB constraints (FR8.15). The "
      "assistant may PREPARE a booking payload; the user still confirms it and the "
      "same route that the normal UI calls executes it.")
    A("")
    A("**Known weaknesses**, all measured above, none hidden:")
    A("")
    A("1. Indirect paraphrase. It matches SHAPE, not meaning. `wallet_balance` "
      "phrased as \"whats sitting in there right now\" goes wrong.")
    A(f"2. `{sorted(exam['per_class'], key=lambda k: exam['per_class'][k]['recall'])[0]}` "
      "is the weakest intent on the exam; the confusion table above names every "
      "pair.")
    A("3. It cannot handle multi-intent utterances -- one label per message by "
      "construction. \"cancel tomorrow and rebook Friday\" gets one of the two.")
    A("4. Roman Urdu spelling variance beyond what the corpus covers falls back on "
      "char n-grams and degrades quietly (into a low-confidence prediction, which is "
      "what the floor is for).")
    A("5. Nothing here is a language model. It has no memory of the conversation, no "
      "world knowledge, and no ability to answer a question it was not trained to "
      "recognise -- which is the honest reason the escalate-to-owner design exists.")
    A("")
    A("**Retraining**: `python training/train_intents.py`. It is safe to re-run; it "
      "never touches the database, reads only the two CSVs, and refuses to overwrite "
      f"`models/{LATEST_NAME}` unless all {len(record['gates'])} gates pass. If the "
      "label set changes, `intent_spec.INTENT_SPEC_VERSION` must change with it -- "
      "the registry compares fingerprints at load and a mismatch takes the route to "
      "503 rather than serving a model that predicts labels the service no longer "
      "knows.")
    A("")
    A("---")
    A("")
    A(f"Generated by `training/train_intents.py` on {record['trainedAt']} -- "
      "every number above is read out of the same run that wrote the artifact.")
    A("")
    path.write_text("\n".join(lines), encoding="utf-8")


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

def _parse_args(argv: list[str] | None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Train the SportLynk assistant intent classifier (model #4, NLU half)."
    )
    p.add_argument("--corpus", type=Path, default=CORPUS_CSV)
    p.add_argument("--exam", type=Path, default=EXAM_CSV)
    p.add_argument("--models-dir", type=Path, default=MODELS_DIR)
    p.add_argument("--reports-dir", type=Path, default=REPORTS_DIR)
    p.add_argument("--seed", type=int, default=SEED)
    p.add_argument("--C", type=float, default=C_VALUE,
                   help="inverse regularization; 1.0 is the shipped value, selected on "
                        "the validation split. RETUNE if you change the feature space.")
    p.add_argument("--proba", choices=("sigmoid", "softmax"), default="sigmoid",
                   help="probability layer; 'sigmoid' (shipped) is Platt scaling over "
                        "grouped folds, 'softmax' is the sentiment model's "
                        "softmax-of-margin -- kept so its rejection can be re-measured, "
                        "it cannot pass gates 9-10 here")
    p.add_argument("--calib-folds", choices=("group", "random"), default="group",
                   help="calibration CV: template-grouped (shipped) or random 5-fold")
    p.add_argument("--threshold", type=float, default=CONFIDENCE_THRESHOLD,
                   help="abstain floor to validate and stamp into the artifact")
    p.add_argument("--boot", type=int, default=BOOTSTRAP_ROUNDS,
                   help="bootstrap resamples for the accuracy CI (0 skips)")
    p.add_argument("--sweep-c", action="store_true",
                   help="re-measure the C sweep live on validation, print it, and exit "
                        "WITHOUT releasing anything")
    p.add_argument("--no-compare", action="store_true",
                   help="skip the softmax-vs-sigmoid probability comparison (3 extra fits)")
    p.add_argument("--no-ablation", action="store_true", help="skip the feature ablation")
    p.add_argument("--no-plot", action="store_true", help="skip the PNGs")
    p.add_argument("--no-write", action="store_true", help="train and report, write no artifact")
    p.add_argument("--quiet", action="store_true")
    return p.parse_args(argv)


def _predict_with_conf(model: Pipeline, X: list[str]) -> tuple[list[str], np.ndarray]:
    """Predictions taken from predict_proba's argmax, exactly like the router will.

    Not model.predict(): for CalibratedClassifierCV the two agree by construction,
    but deriving both the label AND its confidence from ONE call is what guarantees
    the served pair can never disagree -- the failure mode where a route returns
    intent A with the confidence of intent B.
    """
    proba = model.predict_proba(X)
    classes = list(model.named_steps["clf"].classes_)
    idx = np.argmax(proba, axis=1)
    return [classes[i] for i in idx], proba[np.arange(len(idx)), idx]


# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #

def main(argv: list[str] | None = None) -> int:
    global _QUIET
    args = _parse_args(argv)
    _QUIET = bool(args.quiet)
    started = datetime.now(tz=timezone.utc)
    t_start = time.perf_counter()
    stamp = started.strftime("%Y%m%d-%H%M")
    # The major tracks the LABEL CONTRACT, not this script: a 23-label model must
    # not ship calling itself v1. intent_spec.INTENT_SPEC_VERSION is the source.
    _, _sep, spec_major = intent_spec.INTENT_SPEC_VERSION.rpartition("-")
    if not (_sep and spec_major.startswith("v") and spec_major[1:].isdigit()):
        raise SystemExit(
            f"INTENT_SPEC_VERSION {intent_spec.INTENT_SPEC_VERSION!r} does not end "
            f"in -vN, so the model version major cannot be derived from the label "
            f"contract; fix the spec version or this line, do not guess a major"
        )
    model_version = f"{MODEL_KEY}-{spec_major}-{stamp}"

    models_dir: Path = args.models_dir
    reports_dir: Path = args.reports_dir
    models_dir.mkdir(parents=True, exist_ok=True)
    reports_dir.mkdir(parents=True, exist_ok=True)

    shout("=" * 78)
    shout(f"SportLynk assistant INTENT classifier -- {model_version}")
    shout(f"  labels   {intent_spec.INTENT_SPEC_VERSION} / {intent_spec.intent_spec_fingerprint()}")
    shout(f"  text     {nlu_text.NLU_TEXT_SPEC_VERSION} / {nlu_text.nlu_text_fingerprint()}")
    shout(f"  config   C={args.C} proba={args.proba} folds={args.calib_folds} "
          f"floor={args.threshold} seed={args.seed}")
    shout("=" * 78)

    gates: list[Gate] = []

    # ── 1. contracts ────────────────────────────────────────────────────────
    # The two frozen modules this model is fitted THROUGH. If either one's
    # self-check fails, nothing downstream is worth measuring: the classifier
    # would be learning from text the serving path no longer produces.
    # NOTE the three self_check() conventions in this codebase are NOT the same, and
    # assuming they were is a live bug risk: nlu_text.self_check() returns the NUMBER
    # OF CHECKS and raises on failure, intent_spec.self_check() returns a list of
    # receipts and raises on failure, entities.self_check() returns a shell-style 0/1
    # exit code. Only the RAISE is common to all three, so that is what is trusted.
    contract_problems: list[str] = []
    text_checks = 0
    try:
        text_checks = int(nlu_text.self_check())
        say("")
        say(f"nlu_text.self_check(): {text_checks} checks, all clean")
    except Exception as exc:
        contract_problems.append(f"nlu_text.self_check() failed: {exc}")
    intent_receipts = 0
    try:
        intent_receipts = len(intent_spec.self_check())
        say(f"intent_spec.self_check(): {intent_receipts} receipts, all clean")
    except Exception as exc:
        contract_problems.append(f"intent_spec.self_check() failed: {exc}")

    # The entity extractor is the OTHER half of model #4. It is not trained and not
    # fitted here, but its fingerprint is stamped into this artifact so that
    # /nlu/parse can prove the two halves that ship together were built together.
    # A missing dateparser must not block a classifier release, hence the guard.
    entity_spec_version = "unavailable"
    entity_fingerprint = "unavailable"
    try:
        from app.core import entities as _entities

        entity_spec_version = _entities.ENTITY_SPEC_VERSION
        entity_fingerprint = _entities.entity_fingerprint()
    except Exception as exc:
        say(f"  (entity contract not stamped: {exc!r})")

    contract_detail = (
        "; ".join(contract_problems) if contract_problems
        else (f"nlu_text {text_checks} checks + intent_spec {intent_receipts} receipts "
              f"clean; entities {entity_spec_version}/{entity_fingerprint}")
    )
    gates.append(Gate("contracts", not contract_problems, contract_detail))

    # ── 2-3. provenance ─────────────────────────────────────────────────────
    corpus_rows = load_rows(args.corpus)
    exam_rows = load_rows(args.exam)
    corpus_meta = read_json(CORPUS_META)
    exam_meta = read_json(EXAM_META)
    corpus_sha = sha256_of(args.corpus)
    exam_sha = sha256_of(args.exam)

    corpus_problems: list[str] = []
    if not corpus_rows:
        corpus_problems.append(f"{args.corpus.name} is empty")
    if corpus_meta.get("sha256") != corpus_sha:
        corpus_problems.append(
            f"sha256 mismatch: csv={corpus_sha[:12]} meta={str(corpus_meta.get('sha256'))[:12]} "
            "-- regenerate with training/gen_intents.py or reconcile the meta"
        )
    if corpus_meta.get("all_passed") is not True:
        corpus_problems.append("intents_meta.json all_passed is not true")
    if corpus_meta.get("intent_spec_fingerprint") != intent_spec.intent_spec_fingerprint():
        corpus_problems.append(
            f"label fingerprint drift: corpus={corpus_meta.get('intent_spec_fingerprint')} "
            f"code={intent_spec.intent_spec_fingerprint()} -- the label set changed after "
            "the corpus was generated"
        )
    if corpus_meta.get("dataset_spec_fingerprint") != intent_spec.dataset_spec_fingerprint():
        corpus_problems.append(
            f"dataset fingerprint drift: corpus={corpus_meta.get('dataset_spec_fingerprint')} "
            f"code={intent_spec.dataset_spec_fingerprint()}"
        )
    labels_seen = sorted({r["intent"] for r in corpus_rows})
    if labels_seen != LABELS:
        corpus_problems.append(f"corpus labels != intent_spec.INTENTS ({len(labels_seen)} seen)")
    gates.append(Gate(
        "corpus provenance",
        not corpus_problems,
        f"{len(corpus_rows)} rows, sha {corpus_sha[:12]}, meta all_passed, fingerprints match"
        if not corpus_problems else "; ".join(corpus_problems),
    ))

    exam_problems: list[str] = []
    if exam_meta.get("sha256") != exam_sha:
        exam_problems.append(
            f"sha256 mismatch: csv={exam_sha[:12]} meta={str(exam_meta.get('sha256'))[:12]} "
            "-- the exam was edited; an edited exam is not an exam"
        )
    if exam_meta.get("all_passed") is not True:
        exam_problems.append("assistant_test_meta.json all_passed is not true")
    if exam_meta.get("intent_spec_fingerprint") != intent_spec.intent_spec_fingerprint():
        exam_problems.append("exam label fingerprint drift")
    gates.append(Gate(
        "exam provenance",
        not exam_problems,
        f"{len(exam_rows)} rows, sha {exam_sha[:12]}, locked and unedited"
        if not exam_problems else "; ".join(exam_problems),
    ))

    # ── 4. contamination, recomputed here ───────────────────────────────────
    say("\nrechecking exam-vs-corpus overlap (150 x 1,680 pairs)...")
    contam = recheck_contamination(corpus_rows, exam_rows)
    contam_ok = contam["exactCollisions"] == 0 and contam["maxNearDup"] < CONTAM_NEAR_DUP_MAX
    gates.append(Gate(
        "exam uncontaminated",
        contam_ok,
        f"{contam['exactCollisions']} exact, max near-dup {contam['maxNearDup']:.4f} "
        f"({contam['maxNearDupMetric']}) < {CONTAM_NEAR_DUP_MAX}",
    ))

    # ── data ────────────────────────────────────────────────────────────────
    # The split column is the corpus generator's TEMPLATE-GROUPED split; it is used
    # as-is rather than re-split here, so every number in this report is comparable
    # with intents_meta.json's census and with any other run.
    X_all = [r["text"] for r in corpus_rows]
    y_all = [r["intent"] for r in corpus_rows]
    g_all = [r.get("template_id") or "" for r in corpus_rows]
    tr = [i for i, r in enumerate(corpus_rows) if (r.get("split") or "").strip() == "train"]
    va = [i for i, r in enumerate(corpus_rows) if (r.get("split") or "").strip() == "val"]
    X_tr = [X_all[i] for i in tr]
    y_tr = [y_all[i] for i in tr]
    g_tr = [g_all[i] for i in tr]
    X_va = [X_all[i] for i in va]
    y_va = [y_all[i] for i in va]
    X_ex = [r["text"] for r in exam_rows]
    y_ex = [r["intent"] for r in exam_rows]
    say(f"  corpus {len(X_all)} rows -> train {len(X_tr)} / val {len(X_va)}; exam {len(X_ex)}")

    # ── optional: live C sweep, then stop ───────────────────────────────────
    if args.sweep_c:
        shout("\nC sweep (fit on train, selected on validation; exam shown, NOT used)")
        shout(f"  {'C':>6}{'valAcc':>9}{'valMF1':>9}{'cov@f':>8}{'accAns':>9}{'exam':>8}")
        for c in sorted(C_SELECTION_SWEEP):
            folds = calibration_folds(y_tr, g_tr, seed=args.seed)
            m = build_pipeline(seed=args.seed, C=c, proba_kind="sigmoid", folds=folds)
            m.fit(X_tr, y_tr)
            p_va, c_va = _predict_with_conf(m, X_va)
            p_ex, _ = _predict_with_conf(m, X_ex)
            row = threshold_row(y_va, p_va, c_va, args.threshold)
            shout(f"  {c:>6.2f}{accuracy_score(y_va, p_va):>9.4f}"
                  f"{f1_score(y_va, p_va, labels=LABELS, average='macro', zero_division=0):>9.4f}"
                  f"{row['coverage']:>8.3f}{(row['answeredAccuracy'] or 0):>9.4f}"
                  f"{accuracy_score(y_ex, p_ex):>8.4f}")
        shout("\nsweep only -- nothing trained for release. Re-run without --sweep-c.")
        return 0

    # ── the split fit: every number used to CHOOSE anything ─────────────────
    folds_group = calibration_folds(y_tr, g_tr, seed=args.seed)
    folds_arg: list[tuple[np.ndarray, np.ndarray]] | int = (
        folds_group if args.calib_folds == "group" else 5
    )
    say(f"\nfitting on the train split ({len(X_tr)} rows)...")
    t0 = time.perf_counter()
    model_split = build_pipeline(
        seed=args.seed, C=args.C, proba_kind=args.proba, folds=folds_arg,
    )
    model_split.fit(X_tr, y_tr)
    fit_split_ms = (time.perf_counter() - t0) * 1000.0
    say(f"  done in {fit_split_ms/1000:.1f}s")

    pred_va, conf_va = _predict_with_conf(model_split, X_va)
    val_metrics = evaluate(y_va, pred_va)
    val_ece, val_reliability = expected_calibration_error(y_va, pred_va, conf_va)
    val_metrics["ece"] = round(val_ece, 4)
    val_metrics["n"] = len(y_va)
    val_sweep = threshold_sweep(y_va, pred_va, conf_va)
    val_floor = threshold_row(y_va, pred_va, conf_va, args.threshold)

    pred_ex_split, conf_ex_split = _predict_with_conf(model_split, X_ex)
    exam_split_fit = {
        "accuracy": round(float(accuracy_score(y_ex, pred_ex_split)), 4),
        "macro_f1": round(float(f1_score(y_ex, pred_ex_split, labels=LABELS,
                                         average="macro", zero_division=0)), 4),
        **{k: v for k, v in threshold_row(y_ex, pred_ex_split, conf_ex_split,
                                          args.threshold).items() if k != "threshold"},
    }

    # ── the shipped fit: refit on ALL rows, then read the exam ONCE ──────────
    # The validation split's job was to choose the configuration, and it has now
    # done it. Throwing away 348 labelled rows afterwards to keep a number tidy is
    # the worse trade -- so the artifact is refitted on everything and BOTH exam
    # numbers are reported (they differ by less than the bootstrap CI).
    say(f"\nrefitting on all {len(X_all)} rows for the shipped artifact...")
    t0 = time.perf_counter()
    folds_full = calibration_folds(y_all, g_all, seed=args.seed)
    model_full = build_pipeline(
        seed=args.seed, C=args.C, proba_kind=args.proba,
        folds=folds_full if args.calib_folds == "group" else 5,
    )
    model_full.fit(X_all, y_all)
    fit_full_ms = (time.perf_counter() - t0) * 1000.0
    say(f"  done in {fit_full_ms/1000:.1f}s")

    pred_ex, conf_ex = _predict_with_conf(model_full, X_ex)
    exam_metrics = evaluate(y_ex, pred_ex)
    exam_ece, exam_reliability = expected_calibration_error(y_ex, pred_ex, conf_ex)
    exam_metrics["ece"] = round(exam_ece, 4)
    exam_metrics["n"] = len(y_ex)
    exam_floor = threshold_row(y_ex, pred_ex, conf_ex, args.threshold)
    exam_sweep = threshold_sweep(y_ex, pred_ex, conf_ex)
    exam_grouped = grouped_metrics(y_ex, pred_ex)
    exam_ci = bootstrap_ci(y_ex, pred_ex, seed=args.seed, n=args.boot)
    exam_lang = by_field(exam_rows, "lang", y_ex, pred_ex)
    exam_phen = by_field(exam_rows, "phenomena", y_ex, pred_ex)
    exam_confusions = top_confusions(exam_metrics["confusion_matrix"]["matrix"], LABELS)
    val_grouped = grouped_metrics(y_va, pred_va)

    # ── the probability-layer comparison (the wave's central claim) ──────────
    # Re-measured, not quoted. Every arm is fitted on TRAIN and scored on VALIDATION,
    # so the exam plays no part in choosing how probabilities are produced.
    def _proba_row(name: str, model: Pipeline) -> dict:
        p, c = _predict_with_conf(model, X_va)
        ece, _ = expected_calibration_error(y_va, p, c)
        row = threshold_row(y_va, p, c, args.threshold)
        return {
            "val_accuracy": round(float(accuracy_score(y_va, p)), 4),
            "coverage": row["coverage"],
            "answeredAccuracy": row["answeredAccuracy"],
            "ece": round(float(ece), 4),
            "max_confidence": round(float(np.max(c)), 4),
            "median_confidence": round(float(np.median(c)), 4),
        }

    shipped_variant = (
        "softmax" if args.proba == "softmax"
        else ("sigmoid_sgroup" if args.calib_folds == "group" else "sigmoid_random")
    )
    proba_comparison: dict[str, dict] = {shipped_variant: _proba_row(shipped_variant, model_split)}
    if not args.no_compare:
        say("\ncomparing probability layers on validation (softmax / sigmoid random / sigmoid grouped)...")
        arms: dict[str, dict] = {
            "softmax": {"proba_kind": "softmax"},
            "sigmoid_random": {"proba_kind": "sigmoid", "folds": 5},
            "sigmoid_sgroup": {"proba_kind": "sigmoid", "folds": folds_group},
        }
        for name, kwargs in arms.items():
            if name in proba_comparison:
                continue
            m = build_pipeline(seed=args.seed, C=args.C, **kwargs)
            m.fit(X_tr, y_tr)
            proba_comparison[name] = _proba_row(name, m)
        proba_comparison = {k: proba_comparison[k] for k in ("softmax", "sigmoid_random",
                                                             "sigmoid_sgroup")
                            if k in proba_comparison}
        for name, rec in PROBA_COMPARISON_RECORDED.items():
            live = proba_comparison.get(name)
            if not live:
                continue
            drift = max(abs(live["val_accuracy"] - rec[0]), abs(live["coverage"] - rec[1]),
                        abs(live["ece"] - rec[2]))
            if drift > 0.02:
                say(f"  NOTE {name} drifted {drift:.3f} from the recorded comparison "
                    f"(recorded {rec}, now {live['val_accuracy']}/{live['coverage']}/{live['ece']}) "
                    "-- update PROBA_COMPARISON_RECORDED and the docstring table")

    # ── baselines and ablation ──────────────────────────────────────────────
    base = baselines(y_tr, y_ex)
    ablation: dict[str, dict] = {}
    if not args.no_ablation:
        say("\nablating feature views (4 uncalibrated fits)...")
        ablation = run_ablation(X_tr, y_tr, X_va, y_va, X_ex, y_ex, seed=args.seed)

    # ── 5-10. the measured gates ────────────────────────────────────────────
    maj_acc = base["predict_train_majority"]["accuracy"]
    gates.append(Gate(
        "no leakage", val_metrics["accuracy"] <= LEAKAGE_MAX_VAL_ACC,
        f"val accuracy {val_metrics['accuracy']:.4f} <= {LEAKAGE_MAX_VAL_ACC} "
        "(a near-perfect val score on a template-grouped split would mean the split leaked)",
    ))
    gates.append(Gate(
        "beats baseline", exam_metrics["accuracy"] >= maj_acc + BASELINE_MIN_MARGIN,
        f"exam {exam_metrics['accuracy']:.4f} >= majority {maj_acc:.4f} + {BASELINE_MIN_MARGIN}",
    ))
    gates.append(Gate(
        "exam floor", exam_metrics["accuracy"] >= EXAM_ACC_FLOOR,
        f"exam accuracy {exam_metrics['accuracy']:.4f} >= {EXAM_ACC_FLOOR}",
    ))
    answered_acc = exam_floor["answeredAccuracy"] or 0.0
    gates.append(Gate(
        "answers well", answered_acc >= EXAM_ANSWERED_ACC_FLOOR,
        f"exam accuracy on the {exam_floor['answered']} rows it answers "
        f"{answered_acc:.4f} >= {EXAM_ANSWERED_ACC_FLOOR}",
    ))
    gates.append(Gate(
        "answers at all", val_floor["coverage"] >= VAL_COVERAGE_FLOOR,
        f"val coverage at floor {args.threshold} = {val_floor['coverage']:.4f} "
        f">= {VAL_COVERAGE_FLOOR}",
    ))
    gates.append(Gate(
        "calibrated", val_metrics["ece"] <= VAL_ECE_CEILING,
        f"val ECE {val_metrics['ece']:.4f} <= {VAL_ECE_CEILING} "
        f"({ECE_BINS}-bin, top-label)",
    ))
    all_passed = all(g.ok for g in gates)

    # ── print everything a human needs to judge the run ─────────────────────
    print_metrics_table(f"VALIDATION ({len(y_va)} template-disjoint rows, split fit)", val_metrics)
    print_metrics_table(f"EXAM ({len(y_ex)} sha-locked hand-written rows, full refit)", exam_metrics)
    shout(f"\n  exam accuracy 95% CI  {fmt_ci(exam_ci)}")
    shout(f"  exam grouped ({len(GROUPS)} groups)  {exam_grouped['accuracy']:.4f} "
          f"(intent-level {exam_metrics['accuracy']:.4f} -- errors cross groups)")
    shout(f"  val grouped           {val_grouped['accuracy']:.4f}")
    shout(f"  split fit on the exam {exam_split_fit['accuracy']:.4f} vs full refit "
          f"{exam_metrics['accuracy']:.4f} (inside the CI either way)")

    print_sweep_table("ABSTAIN SWEEP -- validation (this is what chose the floor)",
                      val_sweep, mark=args.threshold)
    print_sweep_table("ABSTAIN SWEEP -- exam (reported, never used to choose)", exam_sweep,
                      mark=args.threshold)

    shout("\nPROBABILITY LAYER (validation)")
    shout(f"  {'variant':<16}{'valAcc':>9}{'cov':>8}{'accAns':>9}{'ECE':>8}{'maxConf':>9}{'medConf':>9}")
    for name, m in proba_comparison.items():
        star = " <- ships" if name == shipped_variant else ""
        aa = m["answeredAccuracy"] if m["answeredAccuracy"] is not None else 0.0
        shout(f"  {name:<16}{m['val_accuracy']:>9.4f}{m['coverage']:>8.3f}{aa:>9.4f}"
              f"{m['ece']:>8.4f}{m['max_confidence']:>9.4f}{m['median_confidence']:>9.4f}{star}")

    if ablation:
        shout("\nABLATION (fit on train, uncalibrated, single C)")
        for name, m in ablation.items():
            shout(f"  {name:<18} val {m['val']:.4f}   exam {m['exam']:.4f}")

    shout("\nEXAM SLICES")
    for lg, m in exam_lang.items():
        shout(f"  lang {lg:<6} n={m['n']:<4} acc {m['accuracy']:.4f}  macroF1 {m['macro_f1']:.4f}")
    for ph, m in exam_phen.items():
        shout(f"  phen {ph:<12} n={m['n']:<4} acc {m['accuracy']:.4f}")

    shout("\nTOP EXAM CONFUSIONS (gold -> predicted)")
    for c in exam_confusions:
        tag = "declared confusable" if c["declaredConfusable"] else "NOT declared confusable"
        shout(f"  {c['gold']:<20} -> {c['pred']:<20} {c['count']:>3}  ({tag})")

    shout("\nBASELINES (exam)")
    shout(f"  uniform over {len(LABELS)} intents   {base['uniform_random']:.4f}")
    shout(f"  always {base['predict_train_majority']['label']:<18} "
          f"{base['predict_train_majority']['accuracy']:.4f}")
    shout(f"  THIS MODEL                {exam_metrics['accuracy']:.4f}")

    # ── the record: one dict, everything derives from it ────────────────────
    clf = model_full.named_steps["clf"]
    word_vocab = 0
    char_vocab = 0
    try:
        union = model_full.named_steps["features"]
        for name, sub in union.transformer_list:
            size = len(sub.named_steps["tfidf"].vocabulary_)
            if name == "word":
                word_vocab = size
            else:
                char_vocab = size
    except Exception:  # pragma: no cover - shape is fixed by build_pipeline
        pass
    proba_method = {
        "sigmoid": "sigmoid_calibration",
        "softmax": "softmax_over_decision_function",
    }[args.proba]

    record: dict[str, Any] = {
        "modelKey": MODEL_KEY,
        "modelVersion": model_version,
        "trainedAt": started.isoformat(timespec="seconds"),
        "released": all_passed and not args.no_write,
        "seed": args.seed,
        "confidenceThreshold": args.threshold,
        "intentSpecVersion": intent_spec.INTENT_SPEC_VERSION,
        "intentSpecFingerprint": intent_spec.intent_spec_fingerprint(),
        "datasetSpecVersion": intent_spec.DATASET_SPEC_VERSION,
        "datasetSpecFingerprint": intent_spec.dataset_spec_fingerprint(),
        "nluTextSpecVersion": nlu_text.NLU_TEXT_SPEC_VERSION,
        "nluTextSpecFingerprint": nlu_text.nlu_text_fingerprint(),
        "entitySpecVersion": entity_spec_version,
        "entitySpecFingerprint": entity_fingerprint,
        "labels": LABELS,
        "intentGroups": {k: intent_spec.intent_group(k) for k in LABELS},
        "classifier": {
            "kind": type(clf).__name__,
            "C": args.C,
            "class_weight": "balanced",
            "probability": {"method": proba_method, "variant": shipped_variant,
                            "calibrationFolds": args.calib_folds},
            "features": {"word": word_vocab, "char": char_vocab,
                         "total": word_vocab + char_vocab},
            "fitSeconds": {"split": round(fit_split_ms / 1000, 2),
                           "fullRefit": round(fit_full_ms / 1000, 2)},
        },
        "corpus": {
            "file": str(args.corpus.relative_to(ROOT)) if args.corpus.is_absolute()
                    else str(args.corpus),
            "rows": len(corpus_rows),
            "sha256": corpus_sha,
            "train": len(X_tr),
            "val": len(X_va),
            "langs": dict((corpus_meta.get("census") or {}).get("langs") or {}),
            "sources": dict((corpus_meta.get("census") or {}).get("sources") or {}),
            "splitGroupedBy": (corpus_meta.get("split") or {}).get("grouped_by"),
            "generatedBy": corpus_meta.get("generated_by"),
        },
        "exam": {
            "file": str(args.exam.relative_to(ROOT)) if args.exam.is_absolute()
                    else str(args.exam),
            "rows": len(exam_rows),
            "sha256": exam_sha,
            "role": exam_meta.get("role"),
        },
        "contamination": contam,
        "validation": val_metrics,
        "validation_grouped": val_grouped,
        "reliability_validation": val_reliability,
        "threshold_sweep_validation": val_sweep,
        "floor_validation": val_floor,
        "exam_scores": exam_metrics,
        "exam_grouped": exam_grouped,
        "reliability_exam": exam_reliability,
        "threshold_sweep_exam": exam_sweep,
        "floor_exam": exam_floor,
        "exam_split_fit": exam_split_fit,
        "exam_accuracy_ci95": exam_ci,
        "exam_per_language": exam_lang,
        "exam_per_phenomenon": exam_phen,
        "exam_top_confusions": exam_confusions,
        "proba_comparison": proba_comparison,
        "proba_comparison_recorded": {
            k: {"val_accuracy": v[0], "coverage": v[1], "ece": v[2]}
            for k, v in PROBA_COMPARISON_RECORDED.items()
        },
        "ablation": ablation,
        "baselines": base,
        "c_selection_sweep": {
            str(c): {"val_accuracy": v[0], "val_macro_f1": v[1], "coverage": v[2],
                     "answered_accuracy": v[3], "exam_accuracy": v[4]}
            for c, v in sorted(C_SELECTION_SWEEP.items())
        },
        "featureSelectionNotes": [
            {"knob": k, "chosen": c, "measured": n} for k, c, n in FEATURE_SELECTION_NOTES
        ],
        "gates": [{"name": g.name, "ok": g.ok, "detail": g.detail} for g in gates],
        "libraries": library_versions(),
        "elapsedSeconds": round(time.perf_counter() - t_start, 2),
    }

    # ── always-written reports ──────────────────────────────────────────────
    metrics_path = reports_dir / "intent_metrics.json"
    metrics_path.write_text(
        json.dumps(record, indent=2, default=_jsonable, ensure_ascii=False), encoding="utf-8"
    )
    card_path = reports_dir / "model_card_intent.md"
    write_model_card(card_path, record)
    lock_ok = write_lockfile(reports_dir / "requirements.lock.txt")

    png_ok = png2_ok = rel_ok = False
    if not args.no_plot:
        png_ok = write_confusion_png(
            exam_metrics["confusion_matrix"]["matrix"], LABELS,
            f"Intent confusion -- exam (n={len(y_ex)}, acc {exam_metrics['accuracy']:.3f})",
            reports_dir / "intents_confusion.png",
        )
        png2_ok = write_confusion_png(
            val_metrics["confusion_matrix"]["matrix"], LABELS,
            f"Intent confusion -- validation (n={len(y_va)}, acc {val_metrics['accuracy']:.3f})",
            reports_dir / "intents_confusion_val.png",
        )
        rel_ok = write_reliability_png(
            val_reliability, reports_dir / "intent_reliability.png",
            f"Reliability -- validation (ECE {val_metrics['ece']:.3f})",
        )

    shout("\nREPORTS")
    shout(f"  {metrics_path.relative_to(ROOT)}")
    shout(f"  {card_path.relative_to(ROOT)}")
    shout(f"  reports/intents_confusion.png        {'written' if png_ok else 'SKIPPED'}")
    shout(f"  reports/intents_confusion_val.png    {'written' if png2_ok else 'SKIPPED'}")
    shout(f"  reports/intent_reliability.png       {'written' if rel_ok else 'SKIPPED'}")
    shout(f"  reports/requirements.lock.txt        {'written' if lock_ok else 'SKIPPED'}")

    # ── gates, then the artifact ─────────────────────────────────────────────
    shout("\nRELEASE GATES")
    for g in gates:
        shout(g.line())

    # The dataset receipt is published on /health and in the model card, so it is
    # read as provenance. It must be DERIVED from the corpus meta, never typed in:
    # a hardcoded count silently describes a previous corpus after every regen.
    try:
        _tpl_rows = corpus_meta["inputs"]["templates"]["rows"]
        _tpl_used = corpus_meta["census"]["per_template"]["used"]
        _auth_rows = corpus_meta["inputs"]["authored"]["rows"]
    except (KeyError, TypeError) as exc:
        raise SystemExit(
            f"intents_meta.json is missing {exc}, so the dataset provenance string "
            f"cannot be derived; regenerate with training/gen_intents.py rather than "
            f"letting this receipt guess"
        ) from exc
    dataset_source = (
        f"generated corpus ({_tpl_used} of {_tpl_rows} templates contributed rows) "
        f"+ {_auth_rows} hand-authored rows"
    )

    payload = {
        "model": model_full,
        # ── what the registry gates at load time ──
        "intentSpecVersion": record["intentSpecVersion"],
        "intentSpecFingerprint": record["intentSpecFingerprint"],
        "nluTextSpecVersion": record["nluTextSpecVersion"],
        "nluTextSpecFingerprint": record["nluTextSpecFingerprint"],
        # ── what /nlu/parse and /health report ──
        "datasetSpecVersion": record["datasetSpecVersion"],
        "datasetSpecFingerprint": record["datasetSpecFingerprint"],
        "entitySpecVersion": record["entitySpecVersion"],
        "entitySpecFingerprint": record["entitySpecFingerprint"],
        "modelVersion": model_version,
        "trainedAt": record["trainedAt"],
        "labels": LABELS,
        "intentGroups": record["intentGroups"],
        # The serving abstain floor travels WITH the model. The router must read it
        # from here rather than keep its own constant: retuning the floor is then a
        # retrain, not a code change in two places that can disagree.
        "confidenceThreshold": args.threshold,
        "fallbackIntent": "out_of_scope",
        "metrics": {
            "valAccuracy": round(val_metrics["accuracy"], 4),
            "valMacroF1": round(val_metrics["macro_f1"], 4),
            "valEce": val_metrics["ece"],
            "valCoverage": val_floor["coverage"],
            "examAccuracy": round(exam_metrics["accuracy"], 4),
            "examMacroF1": round(exam_metrics["macro_f1"], 4),
            "examGroupedAccuracy": exam_grouped["accuracy"],
            "examAnsweredAccuracy": exam_floor["answeredAccuracy"],
            "examCoverage": exam_floor["coverage"],
            "examAccuracyCi95": exam_ci,
        },
        "classifier": record["classifier"],
        "libraries": record["libraries"],
        "dataset": {
            "rows": len(corpus_rows),
            "source": dataset_source,
            "seed": args.seed,
            "sha256": corpus_sha,
            "exam": {"rows": len(exam_rows), "sha256": exam_sha},
            "fit": "full refit on train+val after the config was frozen on val",
        },
        "reports": {
            "metrics": "reports/intent_metrics.json",
            "modelCard": "reports/model_card_intent.md",
            "confusion": "reports/intents_confusion.png",
        },
    }

    versioned = models_dir / f"{MODEL_KEY}_{stamp}.joblib"
    latest = models_dir / LATEST_NAME
    if args.no_write:
        shout("\n--no-write: no artifact written (reports above are still complete).")
    else:
        joblib.dump(payload, versioned, compress=3)
        shout(f"\nARTIFACT  {versioned.relative_to(ROOT)}  "
              f"({versioned.stat().st_size/1024:.0f} KB)")
        if all_passed:
            joblib.dump(payload, latest, compress=3)
            shout(f"RELEASED: {latest.relative_to(ROOT)} -- restart uvicorn or POST "
                  "/nlu/refresh to serve it")
        else:
            failed = [g.name for g in gates if not g.ok]
            shout("NOT RELEASED -- gate(s) failed: " + ", ".join(failed))
            shout(f"           {latest.name} left untouched; the service keeps serving "
                  "whatever it already had.")

    shout(f"\nelapsed {record['elapsedSeconds']:.1f}s")
    return 0 if all_passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
