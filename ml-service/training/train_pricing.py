"""
train_pricing.py — train demand model #1                PLACEHOLDER: S.3 Wave B

STATUS
Not implemented. Wave A fixes the filename, the CLI contract, the artifact format
and the evaluation plan; Wave B writes the code. Golden rule 1: implement only the
wave in the prompt.

────────────────────────────────────────────────────────────────────────────────
WHAT IT TRAINS
────────────────────────────────────────────────────────────────────────────────
A binary probability classifier:

        P(slot is booked | slot features, offered price)

Price enters as `price_ratio` (candidate / venue base), which is what lets ONE model
serve both S.3 deliverables:

    72h forecast      hold price at the venue's current price (ratio = 1.0) and
                      walk the next 72 hourly slots.
    price suggestion  hold the slot fixed, sweep the price grid, take
                      argmax(price x P(book | price)) — expected revenue.

Not a regression on daily booking counts: a slot is the atomic observable event in
this schema (`slots.status` becomes 'booked' or it does not), so nothing has to be
aggregated and therefore nothing can be aggregated wrongly. And a demand-only model
cannot answer "what if I charge 2,300 instead of 2,000", which is the entire product.

────────────────────────────────────────────────────────────────────────────────
THE ONE RULE THIS SCRIPT MUST NOT BREAK
────────────────────────────────────────────────────────────────────────────────
It builds its features by calling app.core.features.build_frame(). It does not
compute `is_peak`, `lead_days` or `price_ratio` itself, not even "just for
training". The moment a second definition of any feature exists, train/serve skew
becomes possible, and skew does not announce itself — the service keeps returning
confident numbers that are wrong. One builder, imported by both sides, is the only
version of this guarantee that survives someone editing one of the two files a
month from now.

The artifact then carries `features.FEATURE_SPEC_VERSION`, and
app/core/registry.py refuses to serve an artifact whose stamp does not match the
running code. Discipline plus a mechanical check, because discipline alone has a
known failure rate.

────────────────────────────────────────────────────────────────────────────────
MODEL AND VALIDATION PLAN (Wave B)
────────────────────────────────────────────────────────────────────────────────
  * PIPELINE, not a bare estimator:
        ColumnTransformer(
            numeric      -> SimpleImputer(median)      # venue_rating is nullable
            categorical  -> OneHotEncoder(handle_unknown='ignore')
        ) -> HistGradientBoostingClassifier
    Preprocessing lives INSIDE the saved object, so the artifact is
    self-contained and the service cannot forget a step. `handle_unknown='ignore'`
    matters in production: a venue in a city the model never saw must yield a
    prediction, not a crash — Karachi and Islamabad venues will sign up.

  * BASELINE FIRST. Fit LogisticRegression too and report both. A gradient-boosted
    model that cannot beat a logistic regression is not worth the artifact size,
    and "we compared against a baseline" is the first thing a supervisor asks. The
    baseline's coefficients also sanity-check the simulator: a positive coefficient
    on `price_ratio` would mean demand rises with price, i.e. a sign error.

  * SPLIT BY TIME, NOT AT RANDOM. Train on earlier dates, test on later ones. A
    random split leaks: two slots from the same venue-week land on both sides and
    the model scores far better than it will in production, where it always predicts
    forward. This is the single most common way an ML result gets overstated.

  * METRICS, all written to reports/metrics.json:
        ROC-AUC          ranking quality
        PR-AUC           informative when the booked class is imbalanced
        Brier score      CALIBRATION — the one that actually matters here, because
                         the price sweep multiplies the probability by a rupee
                         amount. A model that ranks perfectly but is systematically
                         overconfident will recommend the wrong price.
        log loss
        calibration curve (plot)     predicted vs observed, 10 bins
        confusion matrix at 0.5      for the report
    Plus permutation importance, which is the evidence that `price_ratio` and
    `is_peak` are doing the work and the model has not latched onto something silly.

  * SANITY CHECK THE PRICE RESPONSE. Hold a slot fixed, sweep the grid, assert
    P(book) is MONOTONICALLY NON-INCREASING in price. If a trained model says demand
    rises with price, the pricing engine built on it would recommend charging more
    forever. This assertion is not a metric, it is a release gate — the script should
    refuse to write `pricing_latest.joblib` when it fails, and say so.

  * MODEL CARD, reports/model_card.md: intended use, training data (synthetic, and
    why — see generate_bookings.py), features, excluded features, metrics, known
    limitations, and the retraining trigger. This is the AI evidence trail the
    milestone asks for. Written by the script, not by hand, so it cannot go stale.

────────────────────────────────────────────────────────────────────────────────
ARTIFACT FORMAT — must match app/core/registry.py's contract exactly
────────────────────────────────────────────────────────────────────────────────
    joblib.dump({
        "model":              Pipeline,
        "featureSpecVersion": features.FEATURE_SPEC_VERSION,
        "featureOrder":       list(features.FEATURE_ORDER),
        "modelVersion":       "pricing-v1-<UTC timestamp>",
        "trainedAt":          ISO-8601 UTC,
        "metrics":            {...},
        "libraries":          {"sklearn": ..., "numpy": ..., "pandas": ..., "python": ...},
        "dataset":            {"rows": ..., "source": "synthetic", "seed": ...,
                               "file": "data/bookings_synth.csv"},
    }, "models/pricing_<timestamp>.joblib")

Then copy to `models/pricing_latest.joblib` — the timestamped file is the provenance
record, `_latest` is what the service serves. `dataset.source` is in the contract so
that "this model was trained on simulated data" travels WITH the model and surfaces
in /health, where it cannot be quietly dropped from a slide.

CLI CONTRACT (fixed now, implemented in Wave B)
    python training/train_pricing.py [--data data/bookings_synth.csv]
                                     [--seed 42] [--no-write]
                                     [--models-dir models] [--reports-dir reports]
"""

from __future__ import annotations

import sys

MESSAGE = """
training/train_pricing.py is not implemented yet.

  It is scheduled for S.3 Wave B. This file currently holds the training design —
  the module docstring specifies the pipeline, the time-based split, the metrics
  (including the Brier score and the monotonic price-response release gate), and
  the exact joblib artifact format app/core/registry.py already validates against.

  Wave A shipped: app/core/features.py (the frozen feature contract), the FastAPI
  service, and backend/src/services/mlClient.js with its heuristic fallback.

  Until an artifact exists, /predict/* answers 503 model_not_loaded and the Node
  backend serves heuristic prices labelled source='heuristic'.
"""


def main() -> None:
    raise SystemExit(MESSAGE)


if __name__ == "__main__":
    main()
    sys.exit(0)  # pragma: no cover - unreachable
