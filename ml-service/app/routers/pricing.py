"""
Pricing endpoints  —  S.3 Wave A

WHAT SHIPS IN THIS WAVE
The wire contract, the request validation, and the shared feature build. NOT a
prediction: no model exists yet (Wave B trains it), so both predict endpoints
answer 503 `model_not_loaded`.

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
Node side — a branch that would exist purely to handle a state that only occurs
between Wave A and Wave B, and which nothing would exercise afterwards.

WIRE FORMAT
camelCase in both directions, because every other SportLynk API is camelCase and
the Flutter models parse that. `populate_by_name` also accepts the snake_case field
names so Python tests and training scripts can pass the same dicts features.py
takes. `extra="forbid"`: both sides of this call live in one repo, so a field name
the server does not recognise is a bug to surface immediately, not a value to
silently drop.
"""

from __future__ import annotations

import logging
from typing import Any

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
        description="model-derived, from ensemble spread; never a fabricated constant",
    )
    curve: list[PricePoint] = Field(default_factory=list)
    reason: str | None = None


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


def _not_implemented(endpoint: str) -> HTTPException:
    """
    A model is loaded, but the inference path is still Wave C's.

    This branch is reachable the moment Wave B's training script writes
    `pricing_latest.joblib`: _require_model() starts passing, and without this the
    request would fall off the end of the handler into the catch-all 500 handler.
    "Internal server error" is the wrong answer to "I just trained a model and the
    endpoint broke" — it sends you reading tracebacks for a state that is expected
    and correct. 501 says implemented-elsewhere-not-here, and it is distinguishable
    from the 503 that means no-model-yet, so the two waves cannot be confused for
    each other in a log.
    """
    return HTTPException(
        status_code=501,
        detail={
            "code": "not_implemented",
            "message": (
                f"{endpoint} inference lands in S.3 Wave C. The model loaded fine — "
                "features, validation and the response schema are already in place; "
                "only the predict-and-sweep step is missing."
            ),
        },
    )


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
    summary="Suggest a price for one slot (503 until a model is trained)",
)
def predict_price(payload: SlotContext) -> PriceSuggestionResponse:
    """
    Wave A: validates the request, builds the features through the shared builder,
    then 503s because no model is loaded.

    The features are built BEFORE the model check even though they are then thrown
    away. That ordering is the point: it means a malformed request is a 422 in Wave
    A exactly as it will be in Wave C, so the Node client's error handling is
    exercised against its final behaviour now rather than being written blind and
    discovering in Wave C that a 422 was arriving where a 503 was expected.
    """
    try:
        frame = features.build_row(payload.to_feature_context())
        features.validate_frame(frame)
    except features.FeatureError as exc:
        raise _feature_error(exc) from exc

    _require_model()  # raises 503 in this wave
    raise _not_implemented("/predict/price")


@router.post(
    "/predict/demand",
    response_model=DemandForecastResponse,
    summary="72-hour demand forecast (503 until a model is trained)",
)
def predict_demand(payload: DemandRequest) -> DemandForecastResponse:
    """
    Wave A: builds the forecast frame, then 503s.

    Price is held at the venue's current price for every point (candidate_price is
    left unset, so price_ratio == 1.0). That is what makes this a demand forecast
    rather than a pricing what-if: the only things varying across the 72 rows are
    hour, day-of-week, weekend, peak and lead time.
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

    _require_model()  # raises 503 in this wave
    raise _not_implemented("/predict/demand")


__all__ = (
    "router",
    "MODEL_KEY",
    "MAX_FORECAST_HOURS",
    "SlotContext",
    "DemandRequest",
    "PriceSuggestionResponse",
    "DemandForecastResponse",
)
