"""
Pricing endpoints  —  contract frozen in S.3 Wave A, inference landed in Wave D

WHAT THESE TWO ENDPOINTS ARE
`POST /predict/price` sweeps the allowed price band for one slot and returns the
revenue-maximising point — `argmax(price x P(book | price))`, never
`argmax(P(book))`, which on a monotone-decreasing price response would recommend
charging as little as policy allows, forever.

`POST /predict/demand` scores the next N hourly slots at the venue's current price
(`price_ratio == 1.0` throughout), which is what makes it a demand forecast rather
than a pricing what-if.

Both answer 503 `model_not_loaded` when no valid artifact is on disk. Neither
invents a number.

ONE MODEL, BOTH ANSWERS
There is no separate "forecast model". `price_ratio` is an input feature, so a single
calibrated P(book | features, price) serves the forecast (hold the ratio at 1.0 and
vary the clock) and the price suggestion (hold the clock and vary the ratio). That is
why calibration, not ranking, is the headline metric: the optimizer MULTIPLIES the
probability by a rupee amount, so being well-ordered is not enough — see
reports/README.md.

THE NUMBERS ON THE WIRE ARE MEASURED, NOT ASSERTED
`confidence` is derived from how sharply expected revenue identifies one price,
discounted for a boundary optimum and for the model's own attainment against its
measured ceiling (see _confidence). `topFactors` are per-request counterfactuals
rebuilt through the shared feature builder (see _factor_probes). `modelMetrics` is
lifted straight out of the served joblib, so the owner-facing "Model v1 - AUC x.xx"
caption is a property of the artifact rather than a constant in Dart that can drift
away from the model that produced the price beside it.

WHY THIS SERVICE HAS NO FALLBACK OF ITS OWN
It would be three lines to make `/predict/price` return `base * 1.15` on a peak
hour and call it a day. That is refused deliberately.

The Node client reports `source: "model" | "heuristic"` to the owner dashboard, and
that field is the honesty mechanism for the whole feature — a supervisor is
entitled to ask "is this number from your trained model?" and get a true answer. If
the ML service quietly substituted a rule of its own, every response would arrive
labelled `source: "model"` and the label would be a lie. So the rule lives in
exactly one place, backend/src/services/mlClient.js, on the far side of a failed
call, where its use is unambiguous and self-reporting.

The same reasoning is already written down in backend/src/utils/matchPreview.js
("WHY THE UI LABEL IS 'Preview' AND NOT 'AI PREDICTION'"). This is that principle
applied to the pricing path.

WHY 503 AND NOT 200-WITH-A-NULL
503 is a service-unavailable signal a client can act on mechanically: mlClient.js
treats any non-2xx as "degrade to heuristic", so the missing-model case and the
process-is-down case take the same code path and are therefore tested by the same
harness. A 200 carrying `{"suggestedPrice": null}` would need its own branch on the
Node side — a branch that would exist purely to handle a state the model path is
not in, and which nothing would exercise once an artifact is present.

WIRE FORMAT
camelCase in both directions, because every other SportLynk API is camelCase and
the Flutter models parse that. `populate_by_name` also accepts the snake_case field
names so Python tests and training scripts can pass the same dicts features.py
takes. `extra="forbid"`: both sides of this call live in one repo, so a field name
the server does not recognise is a bug to surface immediately, not a value to
silently drop.

The route paths stay `/predict/price` and `/predict/demand`. The Wave D brief writes
them as `/pricing/suggest` and `/pricing/forecast`; renaming would break the client
and the harness that were built against the Wave A contract for no behavioural gain,
so the names are unchanged and the mapping is recorded in doc/PROGRESS.md.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import date, timedelta
from typing import Any

import numpy as np
import pandas as pd
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, ConfigDict, Field
from pydantic.alias_generators import to_camel

from ..core import features
from ..core.registry import STATUS_READY, registry

log = logging.getLogger("sportlynk.ml.pricing")

router = APIRouter(tags=["pricing"])

#: Registry key for model #1.
MODEL_KEY = "pricing"

#: Cap on a forecast request. 72 is the milestone's window; the ceiling stops a
#: caller from asking for a year of hourly predictions and turning one HTTP
#: request into 8,760 predict_proba calls on a 2-second client timeout.
MAX_FORECAST_HOURS = 168

#: Points on the price sweep. Mirrors SWEEP_STEPS in training/train_pricing.py:
#: over the 0.70-1.50 band that is 0.05 increments, which at a 2,000 PKR base is
#: 100 PKR apart. Finer is below the resolution an owner would act on, and every
#: extra point is another row through predict_proba on the request path.
SWEEP_STEPS = 17

#: Half-width of the "as good as the best" revenue band used to score how sharply
#: the optimum is identified. 2% of expected revenue on a 2,000 PKR slot is ~40
#: PKR of modelled difference -- below what anyone would call a distinguishable
#: recommendation, so points inside it count as ties rather than as rivals.
REVENUE_TIE_TOLERANCE = 0.02

#: Multiplier applied to confidence when the revenue optimum lands on either end
#: of the allowed band. A boundary optimum means the true optimum may well sit
#: OUTSIDE the band we are permitted to quote, so the recommendation is the best
#: available answer rather than a located one. Honest to discount it.
BOUNDARY_CONFIDENCE_PENALTY = 0.85

#: Confidence is never 0 and never 1. A 1.0 would claim certainty no statistical
#: model has, and a 0.0 would render as an empty bar that reads like a bug.
CONFIDENCE_FLOOR = 0.05
CONFIDENCE_CEILING = 0.95

#: A factor is only shown to the owner if moving it to its neutral value moves
#: P(book) by at least this much. Below one probability point the chip would be
#: noise dressed as an explanation.
MIN_FACTOR_IMPACT = 0.01

#: How many "why" chips the response carries. Three fits the card and forces the
#: ranking to mean something.
MAX_FACTORS = 3

#: Neutral values for the counterfactual explanation. Each is the boring middle of
#: its own feature: 15:00 is outside [PEAK_START_HOUR, PEAK_END_HOUR], Wednesday is
#: mid-week, and a week of lead time is neither a last-minute booking nor a
#: months-out one.
NEUTRAL_HOUR = 15
NEUTRAL_WEEKDAY = 2  # Wednesday; features.dow is 0=Monday
NEUTRAL_LEAD_DAYS = 7

#: Owner-facing day names, indexed by features.dow (0=Monday). Used only for chip
#: labels on non-weekend slots -- see the day_of_week probe.
WEEKDAY_NAMES = ("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")


class CamelModel(BaseModel):
    """Base: camelCase on the wire, snake_case in Python."""

    model_config = ConfigDict(
        alias_generator=to_camel,
        populate_by_name=True,
        extra="forbid",
        str_strip_whitespace=True,
        # `model_version` and `model_status` are fields we genuinely want on the
        # wire, and both sit in pydantic's protected `model_` namespace. Depending
        # on the pydantic version fastapi resolves, declaring them emits a
        # UserWarning at class-definition time — i.e. on import, i.e. in the boot
        # log, where a warning reads as a broken service and gets ignored once
        # people learn to ignore it. Cleared explicitly rather than left to the
        # resolved version's default, because requirements.txt pins fastapi but
        # pydantic arrives as a transitive dependency and can move underneath us.
        protected_namespaces=(),
    )


# ─────────────────────────────────────────────────────────────────────────────
# Requests
# ─────────────────────────────────────────────────────────────────────────────


class SlotContext(CamelModel):
    """
    One slot, described the way `venues` + `slots` describe it.

    Field-by-field this mirrors the columns the Node side already has in hand when
    it renders the owner dashboard, so no extra query is needed to call this:
        base_price   ← venues.price_per_hour
        sport        ← venues.sport_type
        city         ← venues.city
        venue_rating ← venues.rating       (NULL until the venue has reviews)
        slot_date    ← slots.slot_date     (DATE,  naive PKT)
        start_time   ← slots.start_time    (TIME,  naive PKT)
    """

    sport: str = Field(min_length=1, max_length=40, description="venues.sport_type")
    city: str = Field(min_length=1, max_length=80, description="venues.city")
    base_price: float = Field(gt=0, le=1_000_000, description="venues.price_per_hour, PKR")
    slot_date: str = Field(min_length=8, max_length=32, description="YYYY-MM-DD, PKT")
    start_time: str = Field(min_length=1, max_length=16, description="HH:MM[:SS], PKT")

    venue_rating: float | None = Field(
        default=None,
        ge=0,
        le=5,
        description="venues.rating; null when the venue has no reviews yet",
    )
    candidate_price: float | None = Field(
        default=None,
        gt=0,
        le=1_000_000,
        description="price to evaluate; defaults to basePrice (price_ratio = 1.0)",
    )
    as_of: str | None = Field(
        default=None,
        description="reference date for leadDays; defaults to today in PKT",
    )
    #: Echoed in the response and written to the log line, never used as a feature.
    #: A model keyed on venue_id cannot price a venue that signed up this morning —
    #: see the exclusion list in core/features.py.
    venue_id: str | None = Field(default=None, max_length=64)

    def to_feature_context(self) -> dict[str, Any]:
        """Hand off to the SHARED builder. No feature is derived in this module."""
        return {
            "slot_date": self.slot_date,
            "start_time": self.start_time,
            "base_price": self.base_price,
            "sport": self.sport,
            "city": self.city,
            "candidate_price": self.candidate_price,
            "venue_rating": self.venue_rating,
            "as_of": self.as_of,
        }


class DemandRequest(CamelModel):
    """
    A forecast over the next `hours` hourly slots for one venue.

    The venue is described once and the clock supplies the rest, so the caller does
    not have to enumerate 72 slot rows — and cannot get the enumeration subtly
    wrong (a DST-style off-by-one, a missed midnight rollover). features.forecast_slots
    owns that walk.
    """

    sport: str = Field(min_length=1, max_length=40)
    city: str = Field(min_length=1, max_length=80)
    base_price: float = Field(gt=0, le=1_000_000)
    venue_rating: float | None = Field(default=None, ge=0, le=5)
    hours: int = Field(default=72, ge=1, le=MAX_FORECAST_HOURS)
    open_from: int | None = Field(
        default=None, ge=0, le=23, description="venues.operating_hours_from"
    )
    open_to: int | None = Field(
        default=None, ge=0, le=23, description="venues.operating_hours_to"
    )
    venue_id: str | None = Field(default=None, max_length=64)


# ─────────────────────────────────────────────────────────────────────────────
# Responses — declared now, returned from Wave C
# ─────────────────────────────────────────────────────────────────────────────
#
# Declared in Wave A on purpose: this is what makes /docs a contract the Node and
# Flutter work can be written against before the model exists, and it is what
# mlClient.js's own response shape was designed to mirror.


class PricePoint(CamelModel):
    """One point on the price sweep: what the model expects at this price."""

    price: float
    price_ratio: float
    book_probability: float = Field(ge=0, le=1)
    expected_revenue: float


class TopFactor(CamelModel):
    """
    One reason the model gave this slot the probability it did.

    Measured, not asserted. `impact` is the change in P(book) when this one input
    is moved to its neutral value and everything else is held fixed, so a chip
    reading "Peak hour +0.14" means the model itself puts 14 probability points on
    this slot being in the evening block. That is a per-request counterfactual, not
    the global permutation importance in reports/importance_pricing.png -- the
    global number cannot say why THIS slot is expensive.
    """

    key: str = Field(description="stable identifier, safe to switch on")
    label: str = Field(description="owner-facing text, e.g. 'Peak hour'")
    direction: str = Field(description='"up" or "down" -- which way it moves demand')
    impact: float = Field(ge=0, le=1, description="absolute change in P(book)")


class ModelMetrics(CamelModel):
    """
    The served artifact's own measured test-set scores, straight from the joblib.

    On the wire because the owner dashboard prints a "Model v1 - AUC x.xx" caption,
    and a caption hardcoded in Dart is a number that can drift from the model that
    produced the price beside it. Shipping it with the prediction makes the caption
    a property of the artifact instead of a claim about it -- retrain and the UI
    follows, with no Dart edit and no chance of quoting a score the model never got.

    `rocAucCeiling` is the measured Bayes-optimal ceiling on the training data (see
    reports/README.md). It is what makes the AUC interpretable: 0.76 against a
    ceiling of 0.78 is a strong model, and without the ceiling 0.76 looks weak.
    """

    roc_auc: float | None = None
    pr_auc: float | None = None
    brier: float | None = None
    brier_skill: float | None = None
    roc_auc_ceiling: float | None = None
    test_rows: int | None = None
    trained_at: str | None = None
    dataset_source: str | None = None


class PriceSuggestionResponse(CamelModel):
    """
    The answer to "what should I charge for this slot".

    `suggestedPrice` is argmax of expected revenue (price x P(book)) over the swept
    grid, NOT argmax of probability — the cheapest price always wins on probability,
    which would make the engine recommend zero. The grid never leaves
    [PRICE_RATIO_MIN, PRICE_RATIO_MAX] x basePrice, so a suggestion is always
    interpolation inside the trained band rather than extrapolation beyond it.
    """

    source: str = Field(default="model", description='always "model" from this service')
    model_version: str | None = None
    feature_spec_version: str = features.FEATURE_SPEC_VERSION
    base_price: float
    suggested_price: float
    delta_pct: float
    book_probability: float = Field(ge=0, le=1)
    expected_revenue: float
    confidence: float | None = Field(
        default=None,
        ge=0,
        le=1,
        description="how sharply expected revenue identifies one price; see _confidence()",
    )
    curve: list[PricePoint] = Field(default_factory=list)
    reason: str | None = None
    top_factors: list[TopFactor] = Field(default_factory=list)
    model_metrics: ModelMetrics | None = None
    at_policy_cap: bool = Field(
        default=False,
        description="the optimum sits on the policy ceiling, so it is bounded by policy",
    )
    policy_max_ratio: float | None = Field(
        default=None, description="the served band's upper bound, from the artifact"
    )


class DemandPoint(CamelModel):
    slot_date: str
    hour: int
    book_probability: float = Field(ge=0, le=1)


class DemandForecastResponse(CamelModel):
    source: str = "model"
    model_version: str | None = None
    feature_spec_version: str = features.FEATURE_SPEC_VERSION
    hours: int
    points: list[DemandPoint] = Field(default_factory=list)
    model_metrics: ModelMetrics | None = None


# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────


def _require_model() -> Any:
    """
    The loaded pricing estimator, or a 503 that says exactly what is wrong.

    Three distinct not-ready states, three distinct reasons — never trained, trained
    against a different feature spec, or a corrupt artifact. They need different
    fixes (train it / retrain it / investigate it), so collapsing them into one
    "unavailable" would cost real debugging time. The registry has already worked
    out which it is; this only forwards it.
    """
    entry = registry.get(MODEL_KEY)
    if entry.status != STATUS_READY:
        raise HTTPException(
            status_code=503,
            detail={
                "code": "model_not_loaded",
                "message": (
                    f"pricing model unavailable ({entry.status}): "
                    f"{entry.reason or 'no reason recorded'}"
                ),
                "modelStatus": entry.status,
            },
        )
    return entry


def _feature_error(exc: features.FeatureError) -> HTTPException:
    """
    A bad request is a 422, not a 500.

    features.py raises rather than emitting NaN for a missing non-nullable input,
    precisely so this distinction survives: the caller sent something unusable and
    needs to know which field, instead of receiving a confident price built on an
    imputed guess.
    """
    return HTTPException(
        status_code=422, detail={"code": "invalid_features", "message": str(exc)}
    )


def _positive_class_index(estimator: Any) -> int:
    """
    Which `predict_proba` column means "booked".

    scikit-learn sorts `classes_` ascending, so for 0/1 labels this is column 1 —
    but reading it costs nothing and closes a silent failure mode: the day the
    label becomes True/False or "booked"/"free", a hardcoded `[:, 1]` would invert
    every probability in the app and nothing would raise.
    """
    classes = list(getattr(estimator, "classes_", [0, 1]))
    for candidate in (1, True, "1", "booked"):
        if candidate in classes:
            return classes.index(candidate)
    return len(classes) - 1


def _probabilities(entry: Any, frame: pd.DataFrame) -> np.ndarray:
    """
    P(book) for every row of `frame`, in ONE `predict_proba` call.

    Batched on purpose. The price sweep is 13-17 rows and the forecast is 72; per-row
    calls would pay the pipeline's ColumnTransformer setup cost that many times over
    inside a 2-second client timeout. One call, one matrix.

    A failure here is a 503, not a 500: the request was valid and the features built
    cleanly, so the fault is the served artifact's — which is exactly the condition
    mlClient.js's circuit breaker exists to absorb by degrading to the heuristic.
    Only the exception TYPE reaches the client (Golden Rule 5); the traceback goes
    to the log.
    """
    if frame.empty:
        return np.zeros(0, dtype=float)
    try:
        proba = np.asarray(entry.estimator.predict_proba(frame), dtype=float)
    except Exception as exc:  # noqa: BLE001 - deliberately broad; see docstring
        log.exception("predict_proba failed on %d row(s)", len(frame))
        raise HTTPException(
            status_code=503,
            detail={
                "code": "inference_failed",
                "message": (
                    "the pricing model failed to score this request "
                    f"({type(exc).__name__})"
                ),
                "modelStatus": entry.status,
            },
        ) from exc
    return np.clip(proba[:, _positive_class_index(entry.estimator)], 0.0, 1.0)


def _model_metrics(entry: Any) -> ModelMetrics | None:
    """
    Lift the artifact's own test scores out of the joblib meta.

    Written by training/train_pricing.py into `payload["metrics"]`, so these are the
    numbers the release gates were evaluated against — not a copy maintained
    somewhere else. `None` when an older artifact carries no metrics block, which the
    UI must render as no caption rather than as a zero.
    """
    meta = entry.meta or {}
    scores = meta.get("metrics") or {}
    if not scores:
        return None

    def num(key: str) -> float | None:
        value = scores.get(key)
        return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else None

    rows = scores.get("testRows")
    dataset = meta.get("dataset") or {}
    return ModelMetrics(
        roc_auc=num("rocAuc"),
        pr_auc=num("prAuc"),
        brier=num("brier"),
        brier_skill=num("brierSkill"),
        roc_auc_ceiling=num("rocAucCeiling"),
        test_rows=int(rows) if isinstance(rows, (int, float)) and not isinstance(rows, bool) else None,
        trained_at=meta.get("trainedAt"),
        dataset_source=dataset.get("source"),
    )


def _attainment(metrics: ModelMetrics | None) -> float:
    """
    Fraction of the measured Bayes-optimal ceiling this model reached, in [0, 1].

    This is the term that stops `confidence` from being a statement about the price
    curve alone. A sweep can identify one price very sharply *and* be built on a
    weak model; multiplying by attainment means the number on the owner's card can
    never claim more certainty than the artifact earned on its test set.

    Plain ratio (auc / ceiling), matching the "98.2% of attainable" figure already
    recorded in reports/README.md, the model card and doc/TESTING.md. The stricter
    chance-corrected form, (auc - 0.5) / (ceiling - 0.5), is arguably the better
    statistic — but it would put a different number on the wire than every document
    in the repo quotes, and one number in two places is worth more here than the
    marginally better one. 1.0 when there is no ceiling to compare against: real
    production data will never have one, and in that case confidence is honestly a
    statement about the curve only.
    """
    if metrics is None or not metrics.roc_auc or not metrics.roc_auc_ceiling:
        return 1.0
    if metrics.roc_auc_ceiling <= 0.5:
        return 1.0
    return min(1.0, max(0.0, metrics.roc_auc / metrics.roc_auc_ceiling))


def _confidence(revenues: np.ndarray, best_idx: int, *, at_bound: bool, attainment: float) -> float:
    """
    How sharply expected revenue identifies ONE price. Derived, never decorative.

        identification = 1 - (grid points within REVENUE_TIE_TOLERANCE of the max)
                             / (grid points)
        boundary       = BOUNDARY_CONFIDENCE_PENALTY when the optimum sits on either
                         end of the allowed band, else 1
        confidence     = clamp(identification x boundary x attainment, 0.05, 0.95)

    Each term answers a question a supervisor can ask out loud:

    *identification* — if a flat revenue curve makes twelve of seventeen prices
    equally good, the model has not really chosen one, and saying "92%" about that
    would be false precision. This is the term the old hardcoded `0.92` was
    pretending to be.

    *boundary* — an optimum on the edge of [PRICE_RATIO_MIN, policy cap] means the
    true optimum may sit OUTSIDE the band we are allowed to quote, so the answer is
    the best available rather than a located one. With ELASTICITY_PEAK < 1 that is
    the expected case for peak slots (revenue rises monotonically to the cap — a
    theorem about the generator, see doc/PROGRESS.md), so the discount fires often
    and it is meant to.

    *attainment* — see _attainment().

    Never 0 (renders as an empty bar that reads like a bug) and never 1 (no
    statistical model is certain).
    """
    if revenues.size == 0:
        return CONFIDENCE_FLOOR
    best = float(revenues[best_idx])
    if best <= 0:
        return CONFIDENCE_FLOOR
    ties = int(np.count_nonzero(revenues >= best * (1.0 - REVENUE_TIE_TOLERANCE)))
    identification = 1.0 - ties / float(revenues.size)
    score = identification * (BOUNDARY_CONFIDENCE_PENALTY if at_bound else 1.0) * attainment
    return round(min(max(score, CONFIDENCE_FLOOR), CONFIDENCE_CEILING), 3)


def _policy_max_ratio(entry: Any) -> float:
    """
    The upper bound the served artifact was gate-tested over.

    Read from the joblib rather than from features.PRICE_RATIO_MAX so that a model
    trained under a tighter policy cannot have suggestions quoted above the band its
    monotonicity gate actually validated. Clamped into the feature module's band as
    a floor/ceiling on a value that arrives from a file.
    """
    policy = (entry.meta or {}).get("policy") or {}
    raw = policy.get("policyMaxRatio")
    if not isinstance(raw, (int, float)) or isinstance(raw, bool):
        return features.PRICE_RATIO_MAX
    return float(min(max(float(raw), features.PRICE_RATIO_MIN), features.PRICE_RATIO_MAX))


@dataclass(frozen=True)
class _Sweep:
    """Result of one price sweep. `points` is the curve the card plots."""

    points: list[PricePoint]
    best: PricePoint
    cap: float
    at_floor: bool
    at_cap: bool
    confidence: float


def _sweep(entry: Any, payload: SlotContext, *, attainment: float) -> _Sweep:
    """
    Walk the price grid once and pick the revenue-maximising point.

    `argmax(price x P(book))`, NOT `argmax(P(book))` — the latter always returns the
    cheapest price on a monotone-decreasing response, i.e. it would recommend
    charging as little as policy allows, forever.

    Ties break to the CHEAPEST price, which is what `np.argmax` does with its
    first-maximum rule. That is the deliberate choice: two prices with the same
    modelled revenue are not equally good to an owner, because the cheaper one fills
    the slot more often, and a filled slot is a customer who might come back.

    `price_ratio` is read back out of the built frame instead of being recomputed
    here, so the ratio reported to the owner is provably the one the model scored.
    """
    base = float(payload.base_price)
    cap = _policy_max_ratio(entry)
    grid = features.price_grid(base, steps=SWEEP_STEPS)
    # 1e-9 absorbs the float error in base * (MIN + span * i/(steps-1)); without it
    # the grid point that IS the cap can fall outside its own bound.
    prices = [p for p in grid if p <= base * cap + 1e-9]
    if len(prices) < 2:
        prices = grid[:2]

    ctx = payload.to_feature_context()
    frame = features.build_frame({**ctx, "candidate_price": price} for price in prices)
    features.validate_frame(frame)
    probs = _probabilities(entry, frame)

    prices_arr = np.asarray(prices, dtype=float)
    revenues = prices_arr * probs
    best_idx = int(np.argmax(revenues))

    ratios = [float(r) for r in frame["price_ratio"].to_numpy()]
    points = [
        PricePoint(
            price=round(float(price), 2),
            price_ratio=round(ratio, 4),
            book_probability=round(float(prob), 4),
            expected_revenue=round(float(rev), 2),
        )
        for price, ratio, prob, rev in zip(prices_arr, ratios, probs, revenues, strict=True)
    ]
    at_floor = best_idx == 0
    at_cap = best_idx == len(points) - 1
    return _Sweep(
        points=points,
        best=points[best_idx],
        cap=cap,
        at_floor=at_floor,
        at_cap=at_cap,
        confidence=_confidence(
            revenues, best_idx, at_bound=at_floor or at_cap, attainment=attainment
        ),
    )


@dataclass(frozen=True)
class _FactorProbe:
    """One counterfactual: a label for the fact, and the context with it removed."""

    key: str
    label: str
    context: dict[str, Any]


def _iso_date(value: str | None) -> date | None:
    """
    Best-effort ISO date. `None` on anything else, and the caller drops the probe.

    features.py accepts several date spellings via its private `_as_date`; the
    explanation path needs real date ARITHMETIC (shift a week, hold lead_days), and
    an unparseable date here costs a chip, not a price. Degrade, do not raise.
    """
    if not value:
        return None
    try:
        return date.fromisoformat(str(value)[:10])
    except ValueError:
        return None


def _factor_probes(payload: SlotContext, row: pd.Series, price: float) -> list[_FactorProbe]:
    """
    Build the counterfactual contexts for this one slot.

    Three rules make these defensible rather than decorative:

    1. **Every probe is a CONTEXT, rebuilt through features.build_frame.** Nothing
       edits the feature matrix. Poking `frame['is_peak'] = 0` would produce a row
       that cannot exist — 21:00 with is_peak false — and the model has never seen
       one, so its answer would be meaningless. Moving the clock to 15:00 and
       rebuilding produces a row from the same distribution as training.

    2. **Every probe changes exactly one FACT about the slot**, which is not always
       one column. Moving the hour moves `hour` and `is_peak` together, because they
       are one fact ("when is this slot"), not two independent inputs. The weekday
       probe shifts `slot_date` and `as_of` by the same number of days so `lead_days`
       is preserved EXACTLY, and prefers the shift that stays inside the same
       calendar month so `month` is not contaminated either.

    3. **Every probe is a WITHIN-venue contrast.** Each of the three compares this
       venue against itself at another time, so every venue in the training data
       supplies rows on both sides of it. The probes that failed that test were
       removed — see the block at the end of this function, which is worth reading
       before adding a fourth.

    `month` deliberately has no probe. Isolating it requires moving the date by ~28
    days, which either changes lead_days or compares against "a month from now"
    rather than against a neutral value — a claim that needs a paragraph of caveat to
    read correctly. Three measurable factors beat four with one that misleads.

    A slot with nothing unusual about it — mid-afternoon, midweek, a week out —
    correctly yields NO probes and therefore no chips. That is the honest answer, and
    the reason mlClient.js supplies a demand-level chip of its own so the card is
    never blank.

    Probes are evaluated at the SUGGESTED price, not the list price, so the chips
    explain the demand behind the number actually being recommended.
    """
    ctx = {**payload.to_feature_context(), "candidate_price": price}
    hour = int(row["hour"])
    dow = int(row["dow"])
    probes: list[_FactorProbe] = []

    if hour != NEUTRAL_HOUR:
        probes.append(
            _FactorProbe(
                key="time_of_day",
                label="Peak hour" if features.is_peak_hour(hour) else "Off-peak hour",
                context={**ctx, "start_time": f"{NEUTRAL_HOUR:02d}:00"},
            )
        )

    slot_day = _iso_date(payload.slot_date)
    as_of_day = _iso_date(payload.as_of) or features.today_pkt()

    if slot_day is not None and dow != NEUTRAL_WEEKDAY:
        forward = (NEUTRAL_WEEKDAY - dow) % 7
        # Prefer a shift that keeps the same month; among those, the smallest move.
        delta = min(
            (forward, forward - 7),
            key=lambda d: ((slot_day + timedelta(days=d)).month != slot_day.month, abs(d)),
        )
        probes.append(
            _FactorProbe(
                key="day_of_week",
                # "Weekend" for Sat/Sun, because that is the fact the model keyed on
                # and the word an owner uses. For a weekday the DAY NAME, not the
                # word "Weekday" — the neutral it is being compared against is a
                # Wednesday, so a chip reading "Weekday, down" would be comparing a
                # weekday against a weekday and saying nothing.
                label=WEEKDAY_NAMES[dow] if int(row["is_weekend"]) == 0 else "Weekend",
                context={
                    **ctx,
                    "slot_date": (slot_day + timedelta(days=delta)).isoformat(),
                    "as_of": (as_of_day + timedelta(days=delta)).isoformat(),
                },
            )
        )

    lead = int(row["lead_days"])
    if slot_day is not None and lead != NEUTRAL_LEAD_DAYS:
        probes.append(
            _FactorProbe(
                key="lead_time",
                label="Short notice" if lead < NEUTRAL_LEAD_DAYS else "Booked far ahead",
                context={
                    **ctx,
                    "as_of": (slot_day - timedelta(days=NEUTRAL_LEAD_DAYS)).isoformat(),
                },
            )
        )

    # NO venue_rating PROBE, AND NO sport/city PROBE. This is a measured decision,
    # not an oversight.
    #
    # "Unrated" is the correct neutral on paper: generate_bookings.py gives an
    # unrated venue an odds multiplier of exactly 1.00, the same as a venue sitting
    # on RATING_PIVOT = 4.4. So the probe was written, run, and then removed,
    # because of what it returned. On a 4.5-star venue it reported P(book) FALLING
    # by 0.052 -- opposite in sign to the generator's causal effect
    # (exp(0.55 * 0.1) = 1.06x odds, i.e. a rise of about 0.01) and five times its
    # size.
    #
    # The model is not wrong; the counterfactual is unattributable. The training set
    # has six distinct venue profiles, so `venue_rating` is very nearly a venue ID,
    # and the model legitimately uses it to recover that venue's random effect, its
    # price tier and its operating window. Moving 4.5 to NaN therefore does not ask
    # "what if this venue had no reviews" -- it asks "what if this venue were the
    # other venue", and the answer is dominated by everything except reputation.
    # `sport` and `city` are venue proxies for the same reason (one city, one sport
    # per venue) and are excluded on the same grounds.
    #
    # The three probes above survive because each is a WITHIN-venue contrast: the
    # same venue at 15:00 instead of 20:00, on a Wednesday instead of a Saturday,
    # booked a week out instead of tomorrow. Every venue in the data supplies rows
    # on both sides of those comparisons, so the model has something real to have
    # learned and the number can be defended. If this ever trains on hundreds of
    # live venues, the rating probe becomes attributable and should come back --
    # with a mid-band neutral, not NaN, so it stops doubling as a venue switch.

    return probes


def _top_factors(
    entry: Any, payload: SlotContext, row: pd.Series, price: float, base_probability: float
) -> list[TopFactor]:
    """
    Measure each probe, keep the three that moved P(book) most.

    `impact = P(book | as-is) - P(book | fact removed)`, so a positive impact means
    the fact is RAISING demand for this slot. `direction` carries that sign and
    `label` names the fact, which keeps the two independent — the model is free to
    tell the owner that a weekend slot is *below* a Wednesday for their venue, and
    the chip will say "Weekend, down" rather than a contradiction.

    All probes go through in one batched predict, and a FeatureError anywhere returns
    an empty list: the price is already decided by this point, so a broken
    explanation must never cost the owner their suggestion.
    """
    probes = _factor_probes(payload, row, price)
    if not probes:
        return []
    try:
        frame = features.build_frame(probe.context for probe in probes)
        features.validate_frame(frame)
    except features.FeatureError as exc:
        log.warning("top-factor probes rejected (%s); serving the price with no chips", exc)
        return []

    neutral = _probabilities(entry, frame)
    factors = [
        TopFactor(
            key=probe.key,
            label=probe.label,
            direction="up" if base_probability - float(p) > 0 else "down",
            impact=round(abs(base_probability - float(p)), 4),
        )
        for probe, p in zip(probes, neutral, strict=True)
        if abs(base_probability - float(p)) >= MIN_FACTOR_IMPACT
    ]
    factors.sort(key=lambda f: f.impact, reverse=True)
    return factors[:MAX_FACTORS]


# ─────────────────────────────────────────────────────────────────────────────
# Routes
# ─────────────────────────────────────────────────────────────────────────────


@router.get("/features/spec", summary="The frozen feature contract")
def feature_spec() -> dict[str, Any]:
    """
    Publish core/features.py's contract over HTTP.

    This exists to solve a real duplication problem rather than for documentation.
    backend/src/services/mlClient.js needs PEAK_START_HOUR/PEAK_END_HOUR and the
    price-ratio band for its heuristic and its guardrail clamp, and Node cannot
    import a Python module — so those numbers are necessarily duplicated in
    JavaScript. A comment saying "keep these in sync" is a hope. This endpoint lets
    backend/src/scripts/check_ml_service.js ASSERT they are in sync, which turns
    the hope into a check that fails in CI.
    """
    return {"success": True, "data": features.spec()}


@router.post(
    "/predict/price",
    response_model=PriceSuggestionResponse,
    summary="Suggest a price for one slot (503 when no model is loaded)",
)
def predict_price(payload: SlotContext) -> PriceSuggestionResponse:
    """
    Validate, sweep the price band, return the revenue-maximising point plus the
    evidence for it.

    Ordering matters. The features are built and validated BEFORE the model check, so
    a malformed request is a 422 whether or not a model happens to be loaded — the
    Node client's error handling therefore behaves identically in both states, and
    cannot be written against one and surprised by the other.

    That first row is not thrown away: its derived columns (hour, dow, lead_days,
    is_weekend) are what decide which counterfactual probes are worth running, so the
    explanation is driven by the same derivation the prediction is.

    Left as `def`, not `async def`, on purpose: predict_proba is CPU-bound and
    releases no event loop, so FastAPI running it in its threadpool is what keeps a
    72-row forecast from stalling every other request in the process.
    """
    try:
        frame = features.build_row(payload.to_feature_context())
        features.validate_frame(frame)
    except features.FeatureError as exc:
        raise _feature_error(exc) from exc

    entry = _require_model()
    metrics = _model_metrics(entry)

    try:
        sweep = _sweep(entry, payload, attainment=_attainment(metrics))
    except features.FeatureError as exc:
        # Reachable only through price_grid/build_frame on a base_price pydantic
        # accepted but features.py will not derive from. Still the caller's fault.
        raise _feature_error(exc) from exc

    best = sweep.best
    factors = _top_factors(entry, payload, frame.iloc[0], best.price, best.book_probability)

    reason = (
        f"expected revenue peaks at {best.price_ratio:.2f}x the list price "
        f"(P(book) {best.book_probability:.2f})"
    )
    if sweep.at_cap:
        reason += f"; bounded by the {sweep.cap:.2f}x policy cap"
    elif sweep.at_floor:
        reason += "; sits on the floor of the allowed band"

    log.info(
        "price suggestion venue=%s slot=%s %s ratio=%.2f p=%.3f conf=%.2f factors=%d",
        payload.venue_id or "-",
        payload.slot_date,
        payload.start_time,
        best.price_ratio,
        best.book_probability,
        sweep.confidence,
        len(factors),
    )

    return PriceSuggestionResponse(
        model_version=entry.version,
        base_price=round(float(payload.base_price), 2),
        suggested_price=best.price,
        delta_pct=round((best.price / float(payload.base_price) - 1.0) * 100.0, 2),
        book_probability=best.book_probability,
        expected_revenue=best.expected_revenue,
        confidence=sweep.confidence,
        curve=sweep.points,
        reason=reason,
        top_factors=factors,
        model_metrics=metrics,
        at_policy_cap=sweep.at_cap,
        policy_max_ratio=round(sweep.cap, 4),
    )


def warm() -> str:
    """
    Prime the price path at boot so the FIRST real request doesn't pay the one-off
    cost. Called best-effort from main.py's lifespan; returns a one-line status for
    the boot log and never raises.

    The cold `/predict/price` measured ~1.9s, spent almost entirely on things that
    happen exactly once per process: loading the joblib, the first `predict_proba`
    through an untouched sklearn Pipeline, and pandas building its first frame. 1.9s
    trips mlClient's 2s ceiling, so the first owner to open the dashboard after a
    deploy would see a heuristic price — correctly labelled `source:"heuristic"`,
    but degraded — from a service that is actually up. Running the whole predict_price
    path once here moves every one of those costs off the first real call.

    It stays best-effort by design. A model that isn't on disk is not an error to
    warm (there is simply nothing to prime — a real request will get its own honest
    503), and a warm-up that threw must not be what stops the service booting: the
    lazy-load contract (see lifespan) is that a bad artifact 503s ONE endpoint, never
    the process. So warm() cannot regress boot, only speed up the first request.

    The synthetic slot is deliberately peak-hour, short-notice and a couple of days
    out (20:00, +2d) so the counterfactual probes run too, not just the sweep — the
    full code path the first real call could hit is exercised, not a cheap subset.
    """
    entry = registry.get(MODEL_KEY)
    if entry.status != STATUS_READY:
        # Nothing loaded — matches the lifespan banner; the endpoint will 503 honestly.
        return f"pricing not warmed — model {entry.status}"
    try:
        ctx = SlotContext(
            sport="football",
            city="lahore",
            base_price=2000.0,
            slot_date=(features.today_pkt() + timedelta(days=2)).isoformat(),
            start_time="20:00",
            venue_rating=4.2,
            venue_id="__warmup__",
        )
        result = predict_price(ctx)
        return f"pricing warmed (model {result.model_version}, {len(result.curve)} sweep points)"
    except Exception as exc:  # noqa: BLE001 — warm-up must never break boot
        log.warning("pricing warm-up failed (non-fatal): %s", exc)
        return f"pricing warm-up skipped ({type(exc).__name__})"


@router.post(
    "/predict/demand",
    response_model=DemandForecastResponse,
    summary="72-hour demand forecast (503 when no model is loaded)",
)
def predict_demand(payload: DemandRequest) -> DemandForecastResponse:
    """
    P(book) for each of the next `hours` hourly slots, at the venue's CURRENT price.

    `candidate_price` is left unset for every row, so `price_ratio == 1.0` throughout.
    That is what makes this a demand forecast and not a pricing what-if: the only
    things varying across the 72 rows are hour, day-of-week, weekend, peak and lead
    time. Mixing a price sweep into it would produce a chart whose bars differ for two
    reasons at once, which is unreadable.

    `hour` and `slot_date` are echoed from the built frame and the slot walk rather
    than re-derived here, so the x-axis the owner sees is the x-axis the model scored.
    Demand LEVELS (low/medium/high) are not assigned here — that is a presentation
    threshold, and it lives with the other business rules in mlClient.js so the model
    path and the heuristic path colour the same chart the same way.
    """
    slots = features.forecast_slots(
        hours=payload.hours, open_from=payload.open_from, open_to=payload.open_to
    )
    try:
        frame = features.build_frame(
            {
                **slot,
                "base_price": payload.base_price,
                "sport": payload.sport,
                "city": payload.city,
                "venue_rating": payload.venue_rating,
            }
            for slot in slots
        )
        if not frame.empty:
            features.validate_frame(frame)
    except features.FeatureError as exc:
        raise _feature_error(exc) from exc

    entry = _require_model()
    probs = _probabilities(entry, frame)
    hours_col = [int(h) for h in frame["hour"].to_numpy()] if not frame.empty else []

    points = [
        DemandPoint(
            slot_date=slot["slot_date"].isoformat()
            if isinstance(slot["slot_date"], date)
            else str(slot["slot_date"]),
            hour=hour,
            book_probability=round(float(prob), 4),
        )
        for slot, hour, prob in zip(slots, hours_col, probs, strict=True)
    ]

    log.info(
        "demand forecast venue=%s asked=%dh served=%d points",
        payload.venue_id or "-",
        payload.hours,
        len(points),
    )

    return DemandForecastResponse(
        model_version=entry.version,
        hours=payload.hours,
        points=points,
        model_metrics=_model_metrics(entry),
    )


__all__ = (
    "router",
    "MODEL_KEY",
    "MAX_FORECAST_HOURS",
    "SWEEP_STEPS",
    "SlotContext",
    "DemandRequest",
    "TopFactor",
    "ModelMetrics",
    "PricePoint",
    "PriceSuggestionResponse",
    "DemandPoint",
    "DemandForecastResponse",
)
