"""
Shared feature builder for the dynamic-pricing model

THIS MODULE IS THE FEATURE CONTRACT. Training imports it, serving imports it, and
neither is allowed its own copy of any derivation below. Train/serve skew — the
model being fed columns in a different order, or an `is_peak` computed with a
different peak window, or a price expressed in rupees at train time and as a ratio
at serve time — is the single most common way a working ML service silently starts
returning confident nonsense. There is exactly one way to make that class of bug
impossible rather than merely unlikely: one function, imported by both sides.

WHAT THE MODEL PREDICTS
    P(slot gets booked | slot features, candidate price)

A binary classifier over slots, not a regression over daily booking counts. Three
reasons, all of which matter downstream:

  1. A slot is the atomic observable event in this schema — `slots.status` becomes
     'booked' or it does not. Nothing has to be aggregated, so nothing can be
     aggregated wrongly.
  2. PRICE IS AN INPUT FEATURE. That is what makes one model answer both questions
     the pricing model needs:
         72-hour forecast   → hold price at the venue's current price, walk the
                              next 72 hourly slots.
         price suggestion   → hold the slot fixed, sweep a price grid, and take
                              argmax(price x P(book | price)) = expected revenue.
     A model that only predicts demand cannot answer "what happens if I charge
     2,300 instead of 2,000", which is the entire purpose of a pricing engine.
  3. It degrades honestly. A probability has a meaning an owner can check against
     their own experience ("7 in 10 Friday nights sell out"); a synthetic
     "demand index" does not.

WHY THE TRAINING DATA IS SYNTHETIC, AND WHY THAT IS NOT A SHORTCUT
The live database holds 22 bookings, and every slot's price equals its venue's
`price_per_hour` — `SELECT count(DISTINCT price) FROM slots GROUP BY venue_id`
returns 1 for every venue. So the real data contains no elasticity signal at all:
there is not one observation of the same slot offered at two prices. No model,
however good, can learn a price response from data that never varied the price.
training/generate_bookings.py therefore simulates the demand process
explicitly, and reports/model_card.md must say so in those words. The honest claim
is "the model recovers the elasticity the simulator encodes, and generalises across
hour/day/lead-time/venue-tier", not "the model learned Pakistani market demand".

TIME IS NAIVE PKT HERE, DELIBERATELY
`slots.slot_date` is a DATE and `slots.start_time` is a TIME, both written as local
Pakistan wall-clock: routes/venues.js builds `pktNow` by adding 5 hours to UTC and
compares it straight against those two columns, and the slot seeders insert literal
hours 18..22. Golden rule 4 ("store timestamps UTC") governs `timestamptz` columns;
these two are not that. So every date and hour computation in this file is naive
PKT, and `as_of` is normalised into PKT before any subtraction. Getting this wrong
would shift `hour` by 5 and move the entire peak window — which the model would
happily learn, and which nobody would notice until a supervisor asked why 1pm is
the most valuable slot of the day.

FEATURES DELIBERATELY EXCLUDED
  venue_id     — high cardinality, and a model keyed on it cannot price a venue
                 that just signed up. The venue is described by its attributes
                 (sport, city, rating, base_price) so cold start still works.
  is_ramadan   — genuinely reshapes evening sports demand in Pakistan (games move
                 to post-Taraweeh), but there is no hijri calendar in this repo and
                 inventing one would be a data source, not a feature. Future work.
  weather      — no source. Future work; would need a real feed, not a guess.
  competitor
  pricing      — would need other venues' prices at the same hour. Computable from
                 our own `venues` table later; out of scope for model #1.
"""

from __future__ import annotations

from datetime import date, datetime, time, timedelta, timezone
from typing import Any, Iterable, Mapping, Sequence

import pandas as pd

# The contract

#: Bumped whenever the feature list, their order, or any derivation below
#: changes. train_pricing.py stamps this into the joblib artifact; the registry
#: refuses to serve an artifact whose stamp does not match this constant. That
#: turns "we remembered to retrain" from a habit into a mechanical check.
FEATURE_SPEC_VERSION = "pricing-features-v1"

#: Pakistan Standard Time. No DST, so a fixed offset is correct and a tz database
#: is not needed.
PKT = timezone(timedelta(hours=5))

#: Evening peak window, inclusive of both ends, in PKT hours.
#:
#: This is a stated ASSUMPTION, not a measurement: hours 18–22 are when the slot
#: seeders create "prime" inventory and when adult amateur football/cricket is
#: played here. It is used two ways, and the distinction matters:
#:   * as the `is_peak` feature — a domain prior the tree model is free to ignore
#:     but a logistic baseline needs to be competitive at all;
#:   * as the peak window in backend/src/services/mlClient.js's heuristic
#:     fallback, which must mean the same thing as this or the two pricing paths
#:     would disagree about which slots are valuable.
#: Node cannot import Python, so that file re-declares these two numbers and
#: names this module as the source of truth. If they change here, they change
#: there in the same commit.
PEAK_START_HOUR = 18
PEAK_END_HOUR = 22

#: The price band the model is trained on, expressed as a multiple of the venue's
#: own `price_per_hour`. One band, three consumers, on purpose:
#:   * generate_bookings.py samples offered prices inside it;
#:   * the price sweep searches inside it;
#:   * mlClient.js clamps any suggestion into it.
#: Because they are the same band, a suggestion can never be an extrapolation —
#: the model is never asked about a price it has no evidence for.
PRICE_RATIO_MIN = 0.70
PRICE_RATIO_MAX = 1.50

#: Booking lead time is clamped into this range. Slots exist up to ~4 months out,
#: but a request for a slot in the past (negative lead) is a caller bug, and the
#: model has no evidence beyond the horizon it was trained on. Clamping lands on
#: the nearest in-distribution value instead of extrapolating.
LEAD_DAYS_MIN = 0
LEAD_DAYS_MAX = 120

#: Numeric features, in order. `venue_rating` may be NaN (see NULLABLE_FEATURES).
NUMERIC_FEATURES: tuple[str, ...] = (
    "hour",          # 0–23, PKT
    "dow",           # 0=Monday … 6=Sunday
    "is_weekend",    # 1 on Sat/Sun (Pakistan's official weekend)
    "is_peak",       # 1 inside [PEAK_START_HOUR, PEAK_END_HOUR]
    "lead_days",     # slot_date − as_of, clamped
    "month",         # 1–12, carries seasonality (monsoon, winter)
    "venue_rating",  # 0–5, NaN when the venue has no reviews yet
    "base_price",    # the venue's price_per_hour — its market tier
    "price_ratio",   # candidate_price / base_price
)

#: Categorical features, in order. Both are low cardinality today (2 sports,
#: 2 cities), so one-hot inside the model pipeline stays small.
CATEGORICAL_FEATURES: tuple[str, ...] = (
    "sport",
    "city",
)

#: The frozen column order handed to the model. sklearn's ColumnTransformer
#: selects by name, so order is not strictly required for correctness — it is
#: required for the artifact to be auditable and for a diff of two feature frames
#: to be readable.
FEATURE_ORDER: tuple[str, ...] = NUMERIC_FEATURES + CATEGORICAL_FEATURES

#: The only feature allowed to arrive missing. `venues.rating` is NULL until a
#: venue has reviews, which today is most of them. It is emitted as NaN, never as
#: 0 — a 0 would be read by the model as "rated terribly" rather than "not rated",
#: and imputation belongs in the saved pipeline where it becomes part of the
#: artifact instead of a habit.
NULLABLE_FEATURES = frozenset({"venue_rating"})

#: Column name of the training label: 1 if the slot was booked, else 0.
TARGET = "booked"

#: The one feature a price sweep varies. Everything else describes the slot, so
#: holding them fixed and moving only this is what makes a sweep a comparison of
#: prices rather than of unrelated scenarios.
PRICE_FEATURE = "price_ratio"


class FeatureError(ValueError):
    """
    A feature could not be built from the supplied context.

    Raised, never swallowed. A missing `base_price` must not become a NaN that
    the model quietly imputes into a confident price recommendation — the caller
    passed a bad request and needs a 422, not a number.
    """


# Coercion helpers — permissive about the wire format, strict about the value
#
# Postgres via node-postgres, a CSV read by pandas, and a JSON body all spell the
# same date three different ways ('2026-08-25', a datetime, a pandas Timestamp).
# These accept all of them and then enforce the value is sane, so callers do not
# each invent their own parsing.


def _as_date(value: Any, field: str) -> date:
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, date):
        return value
    if isinstance(value, pd.Timestamp):  # pragma: no cover - pandas passthrough
        return value.date()
    if isinstance(value, str):
        text = value.strip()
        if not text:
            raise FeatureError(f"{field} is empty")
        try:
            return date.fromisoformat(text[:10])
        except ValueError as exc:
            raise FeatureError(f"{field}: not an ISO date ({value!r})") from exc
    raise FeatureError(f"{field}: expected a date, got {type(value).__name__}")


def _as_hour(value: Any, field: str) -> int:
    """
    Hour of day from a TIME string ('19:00:00', '19:00'), a `time`, or an int.

    Minutes are dropped on purpose: inventory is hourly (`slots` are 1-hour rows
    starting on the hour), so an hour is the full resolution of the signal. A
    feature with more resolution than the data has is noise the model will
    happily fit.
    """
    if isinstance(value, bool):
        raise FeatureError(f"{field}: expected an hour, got a bool")
    if isinstance(value, time):
        return value.hour
    if isinstance(value, datetime):
        return value.hour
    if isinstance(value, int):
        hour = value
    elif isinstance(value, float):
        hour = int(value)
    elif isinstance(value, str):
        text = value.strip()
        if not text:
            raise FeatureError(f"{field} is empty")
        head = text.split(":")[0]
        try:
            hour = int(head)
        except ValueError as exc:
            raise FeatureError(f"{field}: not a time ({value!r})") from exc
    else:
        raise FeatureError(f"{field}: expected a time, got {type(value).__name__}")

    if not 0 <= hour <= 23:
        raise FeatureError(f"{field}: hour {hour} out of range 0–23")
    return hour


def _as_positive_float(value: Any, field: str) -> float:
    """
    A money amount. pg returns DECIMAL as a string, so '2000.00' must work — the
    Node side has the same trap and solves it with asNum() (utils/num_util.dart).
    """
    if value is None:
        raise FeatureError(f"{field} is required")
    try:
        number = float(value)
    except (TypeError, ValueError) as exc:
        raise FeatureError(f"{field}: not a number ({value!r})") from exc
    if not number > 0:
        raise FeatureError(f"{field}: must be greater than 0 (got {number})")
    if number != number or number in (float("inf"), float("-inf")):  # NaN / inf
        raise FeatureError(f"{field}: not finite")
    return number


def _as_optional_rating(value: Any) -> float:
    """`venues.rating` → 0–5, or NaN when unrated. Out-of-band values become NaN."""
    if value is None or value == "":
        return float("nan")
    try:
        rating = float(value)
    except (TypeError, ValueError):
        return float("nan")
    if rating != rating or not 0.0 <= rating <= 5.0:
        return float("nan")
    # 0 means "no reviews yet" everywhere in this schema (venues.rating default
    # NULL, but the owner auto-provision path in routes/owner.js writes 0), and
    # "unrated" is not the same statement as "rated zero".
    if rating == 0.0:
        return float("nan")
    return rating


def _as_text(value: Any, field: str) -> str:
    if value is None:
        raise FeatureError(f"{field} is required")
    text = str(value).strip().lower()
    if not text:
        raise FeatureError(f"{field} is empty")
    return text


def _clamp(value: float, low: float, high: float) -> float:
    return low if value < low else high if value > high else value


# Derivations — the only place each feature is defined


def now_pkt() -> datetime:
    """Current wall-clock time in Pakistan, tz-aware."""
    return datetime.now(tz=PKT)


def today_pkt() -> date:
    """
    Today's date in Pakistan.

    Not `date.today()`: the server may run in UTC (Render does), and between
    19:00 UTC and midnight UTC the Pakistani date is already tomorrow. A
    `lead_days` that is off by one on every evening request would be invisible in
    testing and wrong in production.
    """
    return now_pkt().date()


def is_weekend(day: date) -> int:
    """
    Pakistan's official weekend is Saturday and Sunday.

    Friday is a working day with a long Jummah break, so it is NOT folded in here
    — `dow` is also a feature, and a tree can learn a Friday-evening effect on its
    own if the data shows one. Encoding a guess about Friday into a binary flag
    would hide that finding instead of letting the model report it.
    """
    return 1 if day.weekday() >= 5 else 0


def is_peak_hour(hour: int) -> int:
    """1 inside the inclusive evening peak window, else 0."""
    return 1 if PEAK_START_HOUR <= hour <= PEAK_END_HOUR else 0


def lead_days_between(slot_day: date, as_of: date) -> int:
    """Whole days from `as_of` to the slot, clamped into the trained range."""
    return int(_clamp((slot_day - as_of).days, LEAD_DAYS_MIN, LEAD_DAYS_MAX))


def build_feature_dict(ctx: Mapping[str, Any]) -> dict[str, Any]:
    """
    One context → one row of features. THE single derivation path.

    Expected keys (snake_case; the HTTP layer is responsible for translating its
    own camelCase wire format into these before calling):

        slot_date        date | 'YYYY-MM-DD'            required
        start_time       time | 'HH:MM[:SS]' | int      required
        base_price       number | numeric string        required, > 0
        sport            str                            required
        city             str                            required
        candidate_price  number                         optional, default base_price
        venue_rating     number | None                  optional, NaN when absent
        as_of            date | datetime | None         optional, default today PKT

    `candidate_price` defaulting to `base_price` means "price it as it is priced
    today", which gives price_ratio == 1.0 — the neutral point of the sweep and
    the correct setting for the 72-hour forecast.
    """
    if not isinstance(ctx, Mapping):
        raise FeatureError("context must be a mapping")

    slot_day = _as_date(ctx.get("slot_date"), "slot_date")
    hour = _as_hour(ctx.get("start_time"), "start_time")
    base_price = _as_positive_float(ctx.get("base_price"), "base_price")

    candidate_raw = ctx.get("candidate_price")
    candidate_price = (
        base_price
        if candidate_raw is None or candidate_raw == ""
        else _as_positive_float(candidate_raw, "candidate_price")
    )

    as_of_raw = ctx.get("as_of")
    as_of = today_pkt() if as_of_raw is None or as_of_raw == "" else _as_date(as_of_raw, "as_of")

    return {
        "hour": hour,
        "dow": slot_day.weekday(),
        "is_weekend": is_weekend(slot_day),
        "is_peak": is_peak_hour(hour),
        "lead_days": lead_days_between(slot_day, as_of),
        "month": slot_day.month,
        "venue_rating": _as_optional_rating(ctx.get("venue_rating")),
        "base_price": base_price,
        # Not clamped here. features.py reports what was asked for; clamping the
        # price band is a business guardrail and lives in one place on the Node
        # side (mlClient.js) so the same rule applies to the model path and the
        # heuristic path. Silently clamping here would make the service answer a
        # question it was not asked, and the caller would never know.
        "price_ratio": candidate_price / base_price,
        "sport": _as_text(ctx.get("sport"), "sport"),
        "city": _as_text(ctx.get("city"), "city"),
    }


# Frame builders — what training and serving call


def build_frame(rows: Iterable[Mapping[str, Any]]) -> pd.DataFrame:
    """
    Many contexts → a model-ready DataFrame with FEATURE_ORDER columns.

    Used by training over the generated CSV, by the 72-hour forecast (72 rows,
    one per hour), and by the price sweep (one row per candidate price). Batch and
    single-row therefore cannot diverge, because single-row is implemented as a
    batch of one.

    dtypes are pinned rather than inferred. A column that arrives as `object`
    because one value was a numeric string will be one-hot encoded as if it were
    categorical — 400 useless columns and a model that trains without complaint.
    """
    records = [build_feature_dict(row) for row in rows]
    if not records:
        # An empty frame still has to carry the schema, or the caller's
        # `df[FEATURE_ORDER]` raises KeyError instead of returning nothing.
        return pd.DataFrame({name: pd.Series(dtype="float64") for name in FEATURE_ORDER})

    frame = pd.DataFrame.from_records(records, columns=list(FEATURE_ORDER))
    for name in NUMERIC_FEATURES:
        frame[name] = pd.to_numeric(frame[name], errors="coerce").astype("float64")
    for name in CATEGORICAL_FEATURES:
        frame[name] = frame[name].astype("string")
    return frame


def build_row(ctx: Mapping[str, Any]) -> pd.DataFrame:
    """One context → a 1-row DataFrame. The serving entry point."""
    return build_frame([ctx])


def validate_frame(frame: pd.DataFrame) -> None:
    """
    Assert a frame really is what the model was trained on.

    Called by training before fitting and available to serving as a cheap
    tripwire. It checks the three things that go wrong in practice — a missing
    column, a reordered column set, and a NaN in a feature that is not allowed to
    be missing — and it names the offender, because "shapes (1, 10) and (1, 11)
    are not aligned" is a genuinely awful thing to debug at 2am.
    """
    actual = tuple(frame.columns)
    if actual != FEATURE_ORDER:
        missing = [c for c in FEATURE_ORDER if c not in actual]
        extra = [c for c in actual if c not in FEATURE_ORDER]
        raise FeatureError(
            "feature frame does not match "
            f"{FEATURE_SPEC_VERSION}: missing={missing} extra={extra} order={list(actual)}"
        )

    for name in FEATURE_ORDER:
        if name in NULLABLE_FEATURES:
            continue
        holes = int(frame[name].isna().sum())
        if holes:
            raise FeatureError(f"feature {name!r} has {holes} missing value(s) and is not nullable")


def spec() -> dict[str, Any]:
    """
    The contract as JSON, for `/health`, the model card, and the trainers to read
    instead of hard-coding. camelCase because it goes on the wire, where every
    other SportLynk API is camelCase.
    """
    return {
        "featureSpecVersion": FEATURE_SPEC_VERSION,
        "featureOrder": list(FEATURE_ORDER),
        "numeric": list(NUMERIC_FEATURES),
        "categorical": list(CATEGORICAL_FEATURES),
        "nullable": sorted(NULLABLE_FEATURES),
        "target": TARGET,
        "priceFeature": PRICE_FEATURE,
        "peakHours": [PEAK_START_HOUR, PEAK_END_HOUR],
        "priceRatioRange": [PRICE_RATIO_MIN, PRICE_RATIO_MAX],
        "leadDaysRange": [LEAD_DAYS_MIN, LEAD_DAYS_MAX],
        "timezone": "UTC+05:00 (PKT, naive wall-clock)",
    }


def price_grid(base_price: float, steps: int = 17) -> list[float]:
    """
    Candidate prices spanning the trained band, inclusive of both ends.

    Lives here rather than in the router because the band it walks is this
    module's constant. `steps=17` over 0.70–1.50 lands on 0.05 increments, which
    at a 2,000 PKR base is 100 PKR apart — finer than that is below the
    resolution any owner would act on, and every extra point is another
    predict_proba call on the request path.
    """
    if steps < 2:
        raise FeatureError("price_grid needs at least 2 steps")
    base = _as_positive_float(base_price, "base_price")
    span = PRICE_RATIO_MAX - PRICE_RATIO_MIN
    return [base * (PRICE_RATIO_MIN + span * i / (steps - 1)) for i in range(steps)]


def forecast_slots(
    *,
    hours: int = 72,
    start: datetime | None = None,
    open_from: int | None = None,
    open_to: int | None = None,
) -> list[dict[str, Any]]:
    """
    The next `hours` hourly slot starts in PKT, as partial contexts.

    Returns `{'slot_date', 'start_time'}` dicts only — the caller merges in the
    venue's sport/city/base_price/rating, because those are per-venue and this
    function is per-clock. Hours outside a venue's operating window are dropped
    when `open_from`/`open_to` are supplied (`venues.operating_hours_from/_to`),
    since forecasting demand for 04:00 at a venue that opens at 08:00 would put
    a run of structural zeros on the owner's chart and make it look broken.
    """
    anchor = (start or now_pkt()).astimezone(PKT).replace(minute=0, second=0, microsecond=0)
    out: list[dict[str, Any]] = []
    for step in range(1, hours + 1):
        moment = anchor + timedelta(hours=step)
        if open_from is not None and open_to is not None and open_from != open_to:
            inside = (
                open_from <= moment.hour <= open_to
                if open_from <= open_to
                # A window that wraps midnight (open 20:00, close 02:00).
                else moment.hour >= open_from or moment.hour <= open_to
            )
            if not inside:
                continue
        out.append(
            {
                "slot_date": moment.date(),
                "start_time": moment.hour,
            }
        )
    return out


__all__: Sequence[str] = (
    "FEATURE_SPEC_VERSION",
    "FEATURE_ORDER",
    "NUMERIC_FEATURES",
    "CATEGORICAL_FEATURES",
    "NULLABLE_FEATURES",
    "TARGET",
    "PRICE_FEATURE",
    "PEAK_START_HOUR",
    "PEAK_END_HOUR",
    "PRICE_RATIO_MIN",
    "PRICE_RATIO_MAX",
    "LEAD_DAYS_MIN",
    "LEAD_DAYS_MAX",
    "PKT",
    "FeatureError",
    "build_feature_dict",
    "build_frame",
    "build_row",
    "validate_frame",
    "spec",
    "price_grid",
    "forecast_slots",
    "is_weekend",
    "is_peak_hour",
    "lead_days_between",
    "now_pkt",
    "today_pkt",
)
