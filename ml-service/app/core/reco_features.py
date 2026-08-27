"""
Frozen feature contract for the venue recommender  —  S.5 Wave A

WHAT THIS MODULE IS
The third frozen-contract module, after `core/features.py` (pricing) and
`core/text_norm.py` (sentiment), and it exists for the same single reason: the code
that turns a venue row into a vector must be THE SAME CODE at training time and at
serving time. `training/build_reco.py` imports this module; `routers/reco.py`
imports this module; `core/registry.py` refuses to serve an artifact whose stamped
fingerprint disagrees with the one this file computes now. There is no second
implementation for drift to live in.

WHAT IS FROZEN HERE AND WHAT IS FITTED FROM DATA
A content-based recommender has two halves, and confusing them is how a recommender
starts recommending the wrong thing after a data refresh:

  * FROZEN (this file): the block layout and its order, how an address becomes a
    zone, which JSONB keys count as which amenity, how a raw rating becomes a
    number, the user-vector weights, the recency half-life, and the match%
    display mapping. Changing any of these changes what a vector MEANS, so all of
    it is hashed into `reco_spec_fingerprint()` and a mismatch is a load-time
    `incompatible`, not a quiet accuracy drift.
  * FITTED (`VenueSpace`, built by the trainer, carried inside the artifact): the
    sport vocabulary, the four price-quantile cut points, the amenity vocabulary,
    the zone vocabulary, and the rating prior. These are properties of the
    CATALOGUE, they change when venues are added, and they are exactly why a
    retrain is a retrain and not an edit to this file.

WHY EACH BLOCK IS NORMALISED SEPARATELY
The wave spec says "normalize each block", and the reason is that cosine
similarity has no idea that fourteen amenity columns and one sport column are
different kinds of statement. Left raw, a venue with eight amenities would dominate
the similarity of every user who has ever booked anywhere, because eight ones
simply outweigh one one. Each block is therefore scaled to unit L2 norm, which
makes the blocks' contributions comparable and makes "equal weight per block" an
explicit, measurable default rather than an accident of how many columns each block
happens to have.

THE ONE BLOCK THAT IS NOT L2-NORMALISED, AND WHY
`rating` is a single column. L2-normalising a 1-dimensional block divides the value
by its own absolute value, so 4.9 stars and 2.1 stars both become exactly 1.0 — the
normalisation that protects the other blocks would DESTROY this one. So the rating
block is scaled to [0, 1] instead (shrunk rating / 5). Its maximum contribution is
1.0, the same ceiling a unit-norm one-hot block has, so it stays comparable; it just
keeps its ordering. `indoor/outdoor` avoids the identical trap by being encoded as a
2-column one-hot rather than a single 0/1 flag.

WHAT THE SCHEMA DOES NOT HAVE (stated here, not worked around silently)
The wave spec names four inputs this database does not store. None is invented, and
none is added by a migration — golden rule 1 forbids schema "improvements" outside
the wave, and golden rule 2 forbids ad-hoc DDL:

  * ZONE — there is no zone/area column. It is DERIVED from `venues.address` by
    `zone_of()` below, falling back to the city. A real derivation with a real
    failure mode ("Stadium Road" carries no area token and lands in the city
    bucket), which is why it is one auditable function and not an inline regex.
  * AMENITIES — `venues.amenities` is free-form JSONB whose values are booleans,
    strings ("Ball, Bibs", "grass") and numbers (4). `AMENITY_ALIASES` is the frozen
    canonicalisation, `amenity_flags()` the frozen truthiness rule, and keys with no
    canonical mapping are DROPPED and COUNTED — so extending the vocabulary is a
    deliberate act with evidence behind it rather than a surprise.
  * BUDGET FROM PROFILE — `player_profiles` has `sport_preferences`, `elo_rating`
    and `trust_score`. There is no budget. The stated-preference component is
    therefore SPORTS ONLY. Deriving a budget from the user's booking prices and
    calling it "stated" would have been easy, but the history component already
    carries exactly that signal, so a derived budget would double-count bookings
    while wearing the label of an independent statement. `spec()` publishes
    `statedBudget: null` so the gap is legible from outside Python.
  * FAVOURITES — no favourites/wishlist table exists in the schema. The wave spec's
    own wording ("favorited/highly-reviewed") supplies the alternative, so the 0.2
    affinity component is built from the user's OWN reviews with `rating >= 4`,
    filtered to `hidden = false` and `venue_id IS NOT NULL` per migration 017.

Missing components renormalise, per the spec: a user with no bookings and no high
reviews is not scored on a 0.3-weighted vector, they are scored on a fully weighted
stated-preference vector — and with nothing stated either they take the cold-start
path in `reco_model.py`, where the card says "Popular nearby" instead of "For you".
"""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from typing import Any, Iterable, Mapping, Sequence

import numpy as np

# ─────────────────────────────────────────────────────────────────────────────
# Contract version
# ─────────────────────────────────────────────────────────────────────────────

#: Bump this whenever a change here alters what an existing vector MEANS. The
#: registry compares it to the artifact's stamped value and refuses a mismatch.
RECO_SPEC_VERSION = "reco-features-v1"


class RecoFeatureError(ValueError):
    """A row cannot be vectorised.

    Raised, never swallowed — `routers/reco.py` turns it into a 422 and the trainer
    lets it abort the run. A recommender that silently drops the rows it could not
    parse reports lift over a baseline measured on different data.
    """


# ─────────────────────────────────────────────────────────────────────────────
# Block layout — FROZEN
# ─────────────────────────────────────────────────────────────────────────────

BLOCK_SPORT = "sport"
BLOCK_PRICE = "price_bucket"
BLOCK_RATING = "rating"
BLOCK_AMENITIES = "amenities"
BLOCK_ZONE = "zone"
BLOCK_INDOOR = "indoor_outdoor"

#: Concatenation order. This IS the vector layout; reordering it invalidates every
#: artifact, which is why it is hashed into the fingerprint.
BLOCK_ORDER: tuple[str, ...] = (
    BLOCK_SPORT,
    BLOCK_PRICE,
    BLOCK_RATING,
    BLOCK_AMENITIES,
    BLOCK_ZONE,
    BLOCK_INDOOR,
)

#: Blocks scaled to unit L2 norm. `rating` is absent on purpose — see the module
#: docstring: L2-normalising a 1-D block collapses it to a constant.
L2_BLOCKS = frozenset({BLOCK_SPORT, BLOCK_PRICE, BLOCK_AMENITIES, BLOCK_ZONE, BLOCK_INDOOR})

#: Number of price bins. 5 quantile bins, per the wave spec.
PRICE_BUCKETS = 5

#: Rating scale of `venues.rating` (DECIMAL(3,2), 1–5).
RATING_MAX = 5.0

#: Pseudo-count for the rating shrinkage. A 5.0 from one review is not evidence of a
#: better venue than a 4.6 from forty; shrinking toward the catalogue mean with a
#: weight of five reviews says so in arithmetic. Frozen, because changing it changes
#: every venue's rating component.
RATING_PRIOR_WEIGHT = 5.0

#: Used only when the catalogue has no rated venue at all to average — a fresh
#: install. 3.5/5 is deliberately mid-scale and not flattering.
RATING_PRIOR_FALLBACK = 3.5

# ─────────────────────────────────────────────────────────────────────────────
# User-vector weights — FROZEN (the wave spec's numbers)
# ─────────────────────────────────────────────────────────────────────────────

#: 0.5 recency-weighted booking history · 0.3 stated preferences · 0.2 affinity
#: (highly-reviewed venues). Each component is unit-normalised BEFORE the blend, so
#: these weights mean what they say: without that step a component that happens to
#: populate five blocks would outweigh one that populates two regardless of weight.
W_HISTORY = 0.5
W_STATED = 0.3
W_AFFINITY = 0.2

COMPONENT_HISTORY = "history"
COMPONENT_STATED = "stated"
COMPONENT_AFFINITY = "affinity"

#: Iterated in this order wherever a blend is reported, so the metrics JSON and the
#: model card list components the same way every run.
COMPONENT_ORDER: tuple[str, ...] = (COMPONENT_HISTORY, COMPONENT_STATED, COMPONENT_AFFINITY)

COMPONENT_WEIGHTS: dict[str, float] = {
    COMPONENT_HISTORY: W_HISTORY,
    COMPONENT_STATED: W_STATED,
    COMPONENT_AFFINITY: W_AFFINITY,
}

#: Exponential recency decay on booking history: a booking this many days old counts
#: half as much as one today. 90 days is one behavioural season and matches the
#: horizon the booking data actually spans; a shorter half-life on a corpus this
#: sparse would leave most users with one effective booking.
RECENCY_HALF_LIFE_DAYS = 90.0

# ─────────────────────────────────────────────────────────────────────────────
# Display mapping — FROZEN
# ─────────────────────────────────────────────────────────────────────────────

#: `match% = round(55 + 43 x sim)`, straight from the wave spec. The point of the
#: floor and the span is honesty: cosine similarity on non-negative vectors lives in
#: [0, 1], so the badge spans 55–98 and NEVER shows 100%. A 100% match is a claim no
#: content-based model can support, and a badge that shows it teaches the user to
#: distrust the ones that are real.
MATCH_PCT_BASE = 55
MATCH_PCT_SPAN = 43

#: Machine-readable provenance of the user vector. Flutter switches the rail label on
#: this, not on the human string below, so UI copy stays in the UI.
PROFILE_HISTORY = "history"
PROFILE_COLD_START = "cold_start"

#: Convenience copy, published so Node, the model card and the app agree on wording.
LABEL_HISTORY = "For you"
LABEL_COLD_START = "Popular nearby"

#: Cold start (no bookings AND no high reviews): popularity in the user's city
#: blended with their stated sports, per the wave spec. The weights renormalise when
#: nothing is stated, which leaves pure popularity.
COLD_W_POPULARITY = 0.6
COLD_W_SPORT = 0.4

#: Popularity itself is demand AND satisfaction. Booking count alone would rank a
#: brand-new 4.8-star venue below every mediocre one on a corpus this sparse, and a
#: "popular nearby" rail that means "booked at least once" is not useful to a new
#: user. Both halves are reported separately in the metrics so the blend is auditable.
POP_W_BOOKINGS = 0.7
POP_W_RATING = 0.3

#: A reason chip is shown only if its block contributed at least this share of the
#: similarity. Without a floor the third chip is noise — a block that moved the score
#: by 0.4% presented in the same typeface as one that moved it by 40%.
REASON_MIN_SHARE = 0.05

#: At most three chips fit the card, and three is about as many reasons as a person
#: reads off a tile.
REASON_MAX = 3

# ─────────────────────────────────────────────────────────────────────────────
# Sport canonicalisation — FROZEN
# ─────────────────────────────────────────────────────────────────────────────

#: `venues.sport_type` is free VARCHAR(50) and `player_profiles.sport_preferences` a
#: free TEXT[] filled by the app, so the same sport arrives spelled several ways.
#: Aliases apply AFTER `_slug()`, so only genuine synonyms need to appear here —
#: case, spaces and hyphens are already handled.
SPORT_ALIASES: dict[str, str] = {
    "soccer": "football",
    "foot_ball": "football",
    "football_11": "football",
    "football_5": "futsal",
    "cricket_hardball": "cricket",
    "cricket_tapeball": "cricket",
    "badminton_singles": "badminton",
    "badminton_doubles": "badminton",
}

# ─────────────────────────────────────────────────────────────────────────────
# Amenity canonicalisation — FROZEN
# ─────────────────────────────────────────────────────────────────────────────

#: Every JSONB key the platform recognises, mapped to its canonical amenity. A key
#: not listed here is DROPPED and counted (see `amenity_flags`), which is the whole
#: reason this is a whitelist rather than a pass-through: `pitch: "grass"` is a
#: surface descriptor, not an amenity, and folding it in as one would put a
#: meaningless column into every vector. The trainer reports the dropped-key
#: histogram so this table gets extended on evidence instead of on a hunch.
AMENITY_ALIASES: dict[str, str] = {
    "lights": "lights",
    "floodlights": "lights",
    "flood_lights": "lights",
    "lighting": "lights",
    "night_lights": "lights",
    "parking": "parking",
    "car_parking": "parking",
    "free_parking": "parking",
    "washroom": "washroom",
    "washrooms": "washroom",
    "toilet": "washroom",
    "toilets": "washroom",
    "restroom": "washroom",
    "water": "water",
    "drinking_water": "water",
    "water_cooler": "water",
    "seating": "seating",
    "spectator_seating": "seating",
    "stands": "seating",
    "cafe": "cafe",
    "cafeteria": "cafe",
    "canteen": "cafe",
    "food": "cafe",
    "lockers": "lockers",
    "locker": "lockers",
    "locker_room": "lockers",
    "changing_room": "changing_room",
    "changing_rooms": "changing_room",
    "dressing_room": "changing_room",
    "showers": "changing_room",
    "equipment": "equipment",
    "gear": "equipment",
    "kit": "equipment",
    "balls": "equipment",
    "coaching": "coaching",
    "coach": "coaching",
    "trainer": "coaching",
    "academy": "coaching",
    "pavilion": "pavilion",
    "nets": "nets",
    "practice_nets": "nets",
    "bowling_machine": "bowling_machine",
    "ac": "ac",
    "air_conditioning": "ac",
    "air_conditioned": "ac",
    "first_aid": "first_aid",
    "medical": "first_aid",
    "wifi": "wifi",
    "internet": "wifi",
}

#: Values that read as "this amenity is absent" even though the key is present.
#: `amenities` is hand-edited JSONB, so `"parking": "no"` genuinely occurs, and
#: treating any non-empty string as truthy would turn it into a selling point.
AMENITY_FALSEY_STRINGS = frozenset({"", "no", "none", "false", "0", "n_a", "na", "nil", "absent"})

#: Human labels for the reason chips. Anything absent falls back to the canonical key
#: with underscores turned into spaces and the first letter capitalised.
AMENITY_LABELS: dict[str, str] = {
    "lights": "Floodlights",
    "parking": "Parking",
    "washroom": "Washrooms",
    "water": "Drinking water",
    "seating": "Spectator seating",
    "cafe": "Cafe on site",
    "lockers": "Lockers",
    "changing_room": "Changing rooms",
    "equipment": "Equipment provided",
    "coaching": "Coaching",
    "pavilion": "Pavilion",
    "nets": "Practice nets",
    "bowling_machine": "Bowling machine",
    "ac": "Air conditioned",
    "first_aid": "First aid",
    "wifi": "Wi-Fi",
}

# ─────────────────────────────────────────────────────────────────────────────
# Zone derivation — FROZEN
# ─────────────────────────────────────────────────────────────────────────────

#: Named housing schemes, checked BEFORE the sector regex because a scheme name is a
#: far more reliable area signal than a bare letter-digit pair — "DHA Phase 2" and
#: "Phase 4, Bahria Town" have no sector token at all, and an address like
#: "Block C 12, Gulberg" would otherwise be filed under C-12 rather than Gulberg.
#:
#: `PHASE n` is deliberately NOT part of the key, for the same granularity reason as
#: sub-sectors below: Bahria Town Phase 4 and Phase 7 are the same part of town as
#: far as a venue recommendation goes, and a one-hot block in which every venue is
#: alone carries no similarity signal whatsoever.
ZONE_SCHEMES: tuple[tuple[str, str], ...] = (
    ("bahria town", "BAHRIA-TOWN"),
    ("bahria", "BAHRIA-TOWN"),
    ("dha", "DHA"),
    ("gulberg greens", "GULBERG"),
    ("gulberg", "GULBERG"),
    ("blue area", "BLUE-AREA"),
    ("satellite town", "SATELLITE-TOWN"),
    ("chaklala", "CHAKLALA"),
    ("saddar", "SADDAR"),
)

#: Islamabad-style sector token: F-11, G-6, G-8/2, I-9. Letters are restricted to
#: A–I, which is the range the twin cities' sectors actually use; opening it to A–Z
#: buys nothing and starts matching street numbers. The optional `/n` sub-sector is
#: MATCHED so it cannot break the token, then DISCARDED — at this catalogue size
#: sub-sector granularity would give almost every venue its own zone.
_RE_SECTOR = re.compile(r"\b([A-I])[-\s]?(\d{1,2})(?:\s*/\s*\d{1,2})?\b")

#: Area component used when an address yields no recognisable area. The zone is still
#: city-scoped, so these venues cluster with each other rather than with everything.
ZONE_AREA_ANY = "*"

#: City component when even the city is missing. Kept explicit so an unknown zone is
#: visible in the fitted vocabulary rather than looking like a real place.
ZONE_CITY_UNKNOWN = "UNKNOWN"

# ─────────────────────────────────────────────────────────────────────────────
# Indoor / outdoor — FROZEN
# ─────────────────────────────────────────────────────────────────────────────

#: `venues.ground_type` VARCHAR(20) DEFAULT 'turf'. Anything not known to be indoors
#: is treated as outdoors, which is the right default for this schema: the column's
#: own default value is an outdoor surface.
INDOOR_GROUND_TYPES = frozenset({"indoor", "indoors", "hall", "futsal_indoor", "covered", "dome"})
OUTDOOR_GROUND_TYPES = frozenset(
    {"turf", "grass", "astro", "astroturf", "clay", "open", "outdoor", "mud", "concrete"}
)

INDOOR_LABEL = "Indoor"
OUTDOOR_LABEL = "Outdoor"

#: Block index within the 2-column indoor/outdoor one-hot.
INDOOR_INDEX = 0
OUTDOOR_INDEX = 1


# ─────────────────────────────────────────────────────────────────────────────
# Coercion helpers — permissive about WIRE FORMAT, strict about VALUE
# ─────────────────────────────────────────────────────────────────────────────
# Same doctrine as `features.py`: the export endpoint sends camelCase JSON, a psql
# dump used for debugging sends snake_case, and `pg` returns DECIMAL columns as
# STRINGS (golden rule 6). All three must vectorise identically, so the readers below
# accept any of them and the value checks happen once, here.

_RE_NON_WORD = re.compile(r"[^a-z0-9]+")


def _as_text(value: Any) -> str:
    """Anything to a stripped string. None becomes empty, never the text "None"."""
    if value is None:
        return ""
    if isinstance(value, str):
        return value.strip()
    return str(value).strip()


def _slug(value: Any) -> str:
    """Lower-case, separator-collapsed key. `"F-11 Markaz"` -> `"f_11_markaz"`."""
    return _RE_NON_WORD.sub("_", _as_text(value).lower()).strip("_")


def _pick(row: Mapping[str, Any], *names: str, default: Any = None) -> Any:
    """First non-null value among `names`.

    This is what lets one vectoriser read `pricePerHour` from the export endpoint and
    `price_per_hour` from a hand-run SQL query without a translation layer in
    between — and a translation layer is precisely where train/serve skew lives.
    """
    for name in names:
        if name in row and row[name] is not None:
            return row[name]
    return default


def _as_float(value: Any) -> float | None:
    """Finite float, or None. Handles the DECIMAL-as-string case (golden rule 6)."""
    if value is None or isinstance(value, bool):
        return None
    try:
        out = float(value)
    except (TypeError, ValueError):
        return None
    if out != out or out in (float("inf"), float("-inf")):  # NaN / inf
        return None
    return out


def _as_int(value: Any, default: int = 0) -> int:
    out = _as_float(value)
    return default if out is None else int(out)


# ─────────────────────────────────────────────────────────────────────────────
# Frozen derivations
# ─────────────────────────────────────────────────────────────────────────────


def canon_sport(value: Any) -> str:
    """Canonical sport key, or `""` when there is nothing to canonicalise."""
    slug = _slug(value)
    if not slug:
        return ""
    return SPORT_ALIASES.get(slug, slug)


def canon_sports(values: Any) -> tuple[str, ...]:
    """Canonicalise a `sport_preferences` TEXT[] (or a single string), de-duplicated.

    Order is preserved rather than sorted: it costs nothing and keeps a user's own
    stated ordering visible in the metrics dump when a profile is being debugged.
    """
    if values is None:
        return ()
    if isinstance(values, str):
        raw: Iterable[Any] = [values]
    elif isinstance(values, Mapping):
        raw = values.keys()
    elif isinstance(values, Sequence):
        raw = values
    else:
        raw = [values]
    out: list[str] = []
    for item in raw:
        sport = canon_sport(item)
        if sport and sport not in out:
            out.append(sport)
    return tuple(out)


def sport_label(sport: Any) -> str:
    """`"football"` -> `"Football"`; a chip label, not a key."""
    slug = canon_sport(sport)
    return slug.replace("_", " ").title() if slug else "Any sport"


def _amenity_present(value: Any) -> bool:
    """The frozen truthiness rule for one JSONB amenity value.

    `bool` is checked before `int` on purpose: in Python `True` IS an `int`, and
    falling through to the numeric branch would work by accident today and break the
    day someone writes `0.0`.
    """
    if value is None:
        return False
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0          # `nets: 4` is four nets; `nets: 0` is no nets
    if isinstance(value, str):
        return _slug(value) not in AMENITY_FALSEY_STRINGS
    if isinstance(value, (Mapping, Sequence)):
        return len(value) > 0
    return True


def amenity_flags(amenities: Any) -> tuple[frozenset[str], tuple[str, ...]]:
    """`(canonical amenities present, raw keys with no canonical mapping)`.

    The second element is the reason this returns a tuple rather than just a set: the
    trainer aggregates it into a dropped-key histogram and prints it, so a vocabulary
    gap is a line of output rather than a column that quietly never appears.

    Accepts every shape this column has been seen to hold: a JSONB object (the
    schema's `DEFAULT '{}'`), a JSON array of amenity names, and a string — either
    JSON text from a driver that did not parse it, or a comma-separated list.
    """
    if amenities is None:
        return frozenset(), ()

    if isinstance(amenities, str):
        text = amenities.strip()
        if not text:
            return frozenset(), ()
        try:
            amenities = json.loads(text)
        except (ValueError, TypeError):
            amenities = [part for part in text.split(",") if part.strip()]

    pairs: list[tuple[Any, Any]]
    if isinstance(amenities, Mapping):
        pairs = list(amenities.items())
    elif isinstance(amenities, (list, tuple, set, frozenset)):
        # A bare list means "these are present" — there is no value to test.
        pairs = [(item, True) for item in amenities]
    else:
        return frozenset(), ()

    present: set[str] = set()
    dropped: list[str] = []
    for raw_key, raw_value in pairs:
        key = _slug(raw_key)
        if not key:
            continue
        canonical = AMENITY_ALIASES.get(key)
        if canonical is None:
            dropped.append(key)
            continue
        if _amenity_present(raw_value):
            present.add(canonical)
    return frozenset(present), tuple(dropped)


def amenity_label(canonical: str) -> str:
    """Chip label for a canonical amenity."""
    if canonical in AMENITY_LABELS:
        return AMENITY_LABELS[canonical]
    pretty = canonical.replace("_", " ").strip()
    return pretty[:1].upper() + pretty[1:] if pretty else "Amenity"


def area_token(address: Any) -> str | None:
    """The area part of an address, or None when nothing recognisable is in it.

    Schemes first, then the sector regex — see `ZONE_SCHEMES` for why the order is
    not arbitrary.
    """
    text = _as_text(address)
    if not text:
        return None
    lowered = text.lower()
    for needle, zone in ZONE_SCHEMES:
        if needle in lowered:
            return zone
    match = _RE_SECTOR.search(text.upper())
    if match:
        return f"{match.group(1)}-{int(match.group(2))}"
    return None


def zone_of(address: Any, city: Any) -> str:
    """`"<CITY>:<AREA>"` — the derived zone key.

    City-scoped on purpose. "City area" in the wave spec means an area WITHIN a city,
    and prefixing keeps two cities' identically-named blocks apart while giving the
    zone block a useful side effect: because a user's history is concentrated in one
    city, this block quietly encodes "near where you already play" as well as "the
    part of town you already play in".
    """
    city_key = _slug(city).upper() or ZONE_CITY_UNKNOWN
    area = area_token(address)
    return f"{city_key}:{area or ZONE_AREA_ANY}"


def zone_label(zone: Any) -> str:
    """Chip label for a zone key. `"ISLAMABAD:F-11"` -> `"F-11 area"`."""
    text = _as_text(zone)
    if not text:
        return "Nearby"
    city, _, area = text.partition(":")
    if not area or area == ZONE_AREA_ANY:
        return city.replace("_", " ").title() if city and city != ZONE_CITY_UNKNOWN else "Nearby"
    if re.fullmatch(r"[A-I]-\d{1,2}", area):
        return f"{area} area"
    return area.replace("-", " ").title()


def indoor_kind(ground_type: Any) -> str:
    """`"indoor"` or `"outdoor"`. Unknown surfaces read as outdoor — see the set."""
    key = _slug(ground_type)
    if key in INDOOR_GROUND_TYPES:
        return "indoor"
    return "outdoor"


def indoor_label(kind: Any) -> str:
    return INDOOR_LABEL if _slug(kind) == "indoor" else OUTDOOR_LABEL


def shrunk_rating(rating: Any, total_reviews: Any, prior_mean: float) -> float:
    """Rating on 0–1, shrunk toward the catalogue mean by `RATING_PRIOR_WEIGHT`.

    `rating` of NULL **or 0** is treated as UNRATED, following the precedent set in
    `features.py::_as_optional_rating`: 0 means "no reviews yet" everywhere in this
    schema, and "unrated" is not the same statement as "rated zero". An unrated venue
    therefore sits at the catalogue mean — neither rewarded nor punished for having no
    history — which is also what stops a brand-new venue from being unrecommendable.

    A rating with `total_reviews = 0` is a data inconsistency rather than a category:
    it is counted as one review, so the value is heavily shrunk but not discarded.
    """
    prior = float(prior_mean) if _as_float(prior_mean) is not None else RATING_PRIOR_FALLBACK
    value = _as_float(rating)
    if value is None or value <= 0:
        return max(0.0, min(1.0, prior / RATING_MAX))
    n = max(_as_int(total_reviews, 0), 1)
    blended = (value * n + prior * RATING_PRIOR_WEIGHT) / (n + RATING_PRIOR_WEIGHT)
    return max(0.0, min(1.0, blended / RATING_MAX))


def recency_weight(days_ago: Any) -> float:
    """`0.5 ** (days / RECENCY_HALF_LIFE_DAYS)`, clamped so the future cannot amplify.

    A booking dated tomorrow (a real thing — bookings are made in advance) would
    otherwise get a weight above 1 and count for more than a booking made today.
    """
    days = _as_float(days_ago)
    if days is None or days < 0:
        days = 0.0
    return float(0.5 ** (days / RECENCY_HALF_LIFE_DAYS))


def venue_price(venue: Mapping[str, Any]) -> float | None:
    """The price this venue is vectorised on, or None when it has no usable price.

    `price_per_hour` first (it is what the app displays and what the player pays per
    hour), then `base_price`, then `current_price`. Zero and negative are treated as
    absent: `price_per_hour DECIMAL(10,2) DEFAULT 0` means an unpriced row exists in
    this schema, and bucketing it as "cheapest" would advertise a venue as a bargain
    on the strength of a missing field.
    """
    for key in ("pricePerHour", "price_per_hour", "basePrice", "base_price", "currentPrice", "current_price"):
        value = _as_float(_pick(venue, key))
        if value is not None and value > 0:
            return value
    return None


def price_bucket_of(price: Any, edges: Sequence[float]) -> int | None:
    """Quantile bucket index in `[0, PRICE_BUCKETS)`, or None for an unusable price.

    `side="right"` so a price sitting exactly on a cut point falls in the upper
    bucket, consistently. Duplicate edges (which a catalogue with repeated prices
    produces — two venues at 2200 collapse a quantile) simply leave a bucket empty;
    the trainer reports the per-bucket counts so an empty bucket is visible rather
    than mistaken for a modelling bug.
    """
    value = _as_float(price)
    if value is None or value <= 0:
        return None
    idx = int(np.searchsorted(np.asarray(edges, dtype=float), value, side="right"))
    return max(0, min(idx, PRICE_BUCKETS - 1))


# ─────────────────────────────────────────────────────────────────────────────
# The fitted space
# ─────────────────────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class VenueSpace:
    """The fitted half of the contract: vocabularies and cut points.

    Frozen as a dataclass so nothing can mutate a vocabulary after the venue matrix
    has been built against it — a silent off-by-one in a one-hot block is the kind of
    bug that produces plausible recommendations for the wrong reasons.

    Round-trips through `to_dict()`/`from_dict()` as plain JSON types, which is what
    lets the metrics report publish the whole space for a viva without anyone having
    to unpickle an artifact to read it.
    """

    sports: tuple[str, ...]
    price_edges: tuple[float, ...]
    amenities: tuple[str, ...]
    zones: tuple[str, ...]
    rating_prior: float

    # ── layout ──────────────────────────────────────────────────────────────
    @property
    def widths(self) -> dict[str, int]:
        return {
            BLOCK_SPORT: len(self.sports),
            BLOCK_PRICE: PRICE_BUCKETS,
            BLOCK_RATING: 1,
            BLOCK_AMENITIES: len(self.amenities),
            BLOCK_ZONE: len(self.zones),
            BLOCK_INDOOR: 2,
        }

    @property
    def slices(self) -> dict[str, slice]:
        out: dict[str, slice] = {}
        widths = self.widths
        cursor = 0
        for block in BLOCK_ORDER:
            width = widths[block]
            out[block] = slice(cursor, cursor + width)
            cursor += width
        return out

    @property
    def dim(self) -> int:
        return sum(self.widths.values())

    def column_names(self) -> tuple[str, ...]:
        """One name per dimension. Published in the metrics so the vector is readable."""
        names: list[str] = []
        names.extend(f"{BLOCK_SPORT}={s}" for s in self.sports)
        names.extend(f"{BLOCK_PRICE}=q{i}" for i in range(PRICE_BUCKETS))
        names.append(BLOCK_RATING)
        names.extend(f"{BLOCK_AMENITIES}={a}" for a in self.amenities)
        names.extend(f"{BLOCK_ZONE}={z}" for z in self.zones)
        names.append(f"{BLOCK_INDOOR}=indoor")
        names.append(f"{BLOCK_INDOOR}=outdoor")
        return tuple(names)

    # ── fitting ─────────────────────────────────────────────────────────────
    @classmethod
    def fit(cls, venues: Sequence[Mapping[str, Any]]) -> "VenueSpace":
        """Build the vocabularies from a venue snapshot.

        Sorted vocabularies, deliberately: two runs over the same snapshot must
        produce byte-identical column orders, and a set's iteration order is not a
        promise. S3-E's reproducibility demo turns on exactly this kind of detail.
        """
        if not venues:
            raise RecoFeatureError("cannot fit a VenueSpace on an empty venue list")

        sports = sorted({canon_sport(_pick(v, "sportType", "sport_type")) for v in venues} - {""})
        zones = sorted(
            {zone_of(_pick(v, "address"), _pick(v, "city")) for v in venues}
        )

        amenity_set: set[str] = set()
        for venue in venues:
            present, _ = amenity_flags(_pick(venue, "amenities"))
            amenity_set |= present
        amenities = sorted(amenity_set)

        prices = [p for p in (venue_price(v) for v in venues) if p is not None]
        if prices:
            quantiles = [i / PRICE_BUCKETS for i in range(1, PRICE_BUCKETS)]
            edges = tuple(float(x) for x in np.quantile(np.asarray(prices, dtype=float), quantiles))
        else:
            # No priced venue in the catalogue. Every venue's price block is then
            # zeros (venue_price returns None), so the edges are never consulted —
            # but they must still exist and be deterministic.
            edges = tuple(0.0 for _ in range(PRICE_BUCKETS - 1))

        rated = [
            r
            for r in (_as_float(_pick(v, "rating")) for v in venues)
            if r is not None and r > 0
        ]
        rating_prior = float(np.mean(rated)) if rated else RATING_PRIOR_FALLBACK

        return cls(
            sports=tuple(sports),
            price_edges=edges,
            amenities=tuple(amenities),
            zones=tuple(zones),
            rating_prior=rating_prior,
        )

    # ── serialisation ───────────────────────────────────────────────────────
    def to_dict(self) -> dict[str, Any]:
        return {
            "sports": list(self.sports),
            "priceEdges": [float(x) for x in self.price_edges],
            "amenities": list(self.amenities),
            "zones": list(self.zones),
            "ratingPrior": float(self.rating_prior),
            "dim": self.dim,
        }

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "VenueSpace":
        try:
            return cls(
                sports=tuple(payload["sports"]),
                price_edges=tuple(float(x) for x in payload["priceEdges"]),
                amenities=tuple(payload["amenities"]),
                zones=tuple(payload["zones"]),
                rating_prior=float(payload["ratingPrior"]),
            )
        except (KeyError, TypeError, ValueError) as exc:
            raise RecoFeatureError(f"malformed VenueSpace payload: {exc}") from exc


# ─────────────────────────────────────────────────────────────────────────────
# Vectorisation
# ─────────────────────────────────────────────────────────────────────────────


def _l2_normalise_inplace(vector: np.ndarray, span: slice) -> None:
    """Scale one block to unit L2 norm. An all-zero block is left alone."""
    block = vector[span]
    if block.size == 0:
        return
    norm = float(np.linalg.norm(block))
    if norm > 0.0:
        block /= norm


def venue_vector(venue: Mapping[str, Any], space: VenueSpace) -> np.ndarray:
    """One venue row to its block-normalised feature vector.

    A block whose value is absent or out of vocabulary is left as ZEROS rather than
    forced into an arbitrary bucket. That is the right degradation for cosine
    similarity: a zero block contributes nothing to any similarity, so an unpriced
    venue is judged on its other blocks instead of being advertised as cheap. The
    trainer counts these so "how much of the catalogue is missing which block" is a
    published number, not a guess.
    """
    if not isinstance(venue, Mapping):
        raise RecoFeatureError(f"venue row must be a mapping, got {type(venue).__name__}")

    spans = space.slices
    vector = np.zeros(space.dim, dtype=np.float64)

    sport = canon_sport(_pick(venue, "sportType", "sport_type"))
    if sport in space.sports:
        vector[spans[BLOCK_SPORT].start + space.sports.index(sport)] = 1.0

    bucket = price_bucket_of(venue_price(venue), space.price_edges)
    if bucket is not None:
        vector[spans[BLOCK_PRICE].start + bucket] = 1.0

    vector[spans[BLOCK_RATING].start] = shrunk_rating(
        _pick(venue, "rating"),
        _pick(venue, "totalReviews", "total_reviews"),
        space.rating_prior,
    )

    present, _ = amenity_flags(_pick(venue, "amenities"))
    amenity_start = spans[BLOCK_AMENITIES].start
    for amenity in present:
        if amenity in space.amenities:
            vector[amenity_start + space.amenities.index(amenity)] = 1.0

    zone = zone_of(_pick(venue, "address"), _pick(venue, "city"))
    if zone in space.zones:
        vector[spans[BLOCK_ZONE].start + space.zones.index(zone)] = 1.0

    indoor_start = spans[BLOCK_INDOOR].start
    kind = indoor_kind(_pick(venue, "groundType", "ground_type"))
    vector[indoor_start + (INDOOR_INDEX if kind == "indoor" else OUTDOOR_INDEX)] = 1.0

    for block in L2_BLOCKS:
        _l2_normalise_inplace(vector, spans[block])
    return vector


def venue_matrix(
    venues: Sequence[Mapping[str, Any]], space: VenueSpace
) -> tuple[np.ndarray, np.ndarray]:
    """`(matrix, row_norms)` for a whole catalogue.

    The norms are precomputed because they are needed on every request and never
    change between retrains: `cosine_scores` then costs one matrix-vector product.
    """
    if not venues:
        return np.zeros((0, space.dim), dtype=np.float64), np.zeros(0, dtype=np.float64)
    matrix = np.vstack([venue_vector(v, space) for v in venues])
    norms = np.linalg.norm(matrix, axis=1)
    return matrix, norms


def stated_vector(sports: Any, space: VenueSpace) -> np.ndarray:
    """The stated-preference component: SPORTS ONLY, and the docstring says why.

    `player_profiles` stores no budget, so the wave spec's "sports + budget from
    profile" is half-supportable. The half that exists is built here; the half that
    does not is reported as `statedBudget: null` in `spec()` rather than back-filled
    from booking prices, which the history component already covers — see the module
    docstring.

    Multi-hot then unit-normalised WITHIN the block, so a player who states three
    sports does not out-shout one who states a single sport.
    """
    vector = np.zeros(space.dim, dtype=np.float64)
    span = space.slices[BLOCK_SPORT]
    matched = [s for s in canon_sports(sports) if s in space.sports]
    if not matched:
        return vector
    for sport in matched:
        vector[span.start + space.sports.index(sport)] = 1.0
    _l2_normalise_inplace(vector, span)
    return vector


def unit(vector: np.ndarray) -> np.ndarray:
    """Unit-length copy. An all-zero vector is returned unchanged, not divided by 0."""
    array = np.asarray(vector, dtype=np.float64)
    norm = float(np.linalg.norm(array))
    return array / norm if norm > 0.0 else array.copy()


def weighted_mean(vectors: Sequence[np.ndarray], weights: Sequence[float]) -> np.ndarray | None:
    """Recency-weighted mean of a user's venue vectors, or None when there are none."""
    if not len(vectors):
        return None
    stacked = np.vstack(vectors)
    w = np.asarray(weights, dtype=np.float64)
    total = float(w.sum())
    if total <= 0.0:
        # Every weight decayed to zero (a history older than ~50 half-lives). An
        # unweighted mean is a better answer than no profile at all, and it is
        # honest: the recency signal is simply exhausted.
        return stacked.mean(axis=0)
    return (stacked * w[:, None]).sum(axis=0) / total


def blend_user_vector(
    components: Mapping[str, np.ndarray | None]
) -> tuple[np.ndarray, dict[str, float]]:
    """`(user vector, weights actually applied)`.

    Two things happen here, and the wave spec asks for both:

    1. EACH COMPONENT IS UNIT-NORMALISED FIRST. Without it, 0.5/0.3/0.2 would be
       multiplied by whatever magnitude each component happened to have, and a
       stated-preference vector that populates one block would be quietly worth far
       less than its 0.3.
    2. MISSING COMPONENTS RENORMALISE. A user with no reviews is scored on
       0.625 history + 0.375 stated (0.5 and 0.3 over their sum), not on a vector
       that is 20% shorter for no reason. The applied weights are returned so the
       response and the metrics can show which components a user actually had.
    """
    present: dict[str, np.ndarray] = {}
    for name in COMPONENT_ORDER:
        vector = components.get(name)
        if vector is None:
            continue
        normalised = unit(vector)
        if float(np.linalg.norm(normalised)) > 0.0:
            present[name] = normalised

    if not present:
        return np.zeros(0, dtype=np.float64), {}

    total = sum(COMPONENT_WEIGHTS[name] for name in present)
    applied = {name: COMPONENT_WEIGHTS[name] / total for name in present}
    dim = next(iter(present.values())).shape[0]
    blended = np.zeros(dim, dtype=np.float64)
    for name, vector in present.items():
        blended += applied[name] * vector
    return blended, applied


# ─────────────────────────────────────────────────────────────────────────────
# Scoring
# ─────────────────────────────────────────────────────────────────────────────


def cosine_scores(matrix: np.ndarray, row_norms: np.ndarray, user_vector: np.ndarray) -> np.ndarray:
    """Cosine similarity of one user vector against every venue row.

    Computed explicitly rather than by pre-normalising the matrix, so ONE
    representation of a venue vector exists — the block-normalised one. Two
    representations would mean two things to keep in sync, and the block structure is
    needed intact for `block_contributions` to add up to this number.
    """
    if matrix.size == 0:
        return np.zeros(0, dtype=np.float64)
    user = np.asarray(user_vector, dtype=np.float64)
    user_norm = float(np.linalg.norm(user))
    if user_norm <= 0.0:
        return np.zeros(matrix.shape[0], dtype=np.float64)
    denom = np.asarray(row_norms, dtype=np.float64) * user_norm
    with np.errstate(divide="ignore", invalid="ignore"):
        sims = np.where(denom > 0.0, (matrix @ user) / denom, 0.0)
    # Every component is non-negative, so a similarity outside [0, 1] can only be
    # float noise on the boundary. Clipped rather than trusted, because this number
    # goes straight into a percentage the user reads.
    return np.clip(np.nan_to_num(sims, nan=0.0), 0.0, 1.0)


def match_pct(similarity: Any) -> int:
    """`round(55 + 43 x sim)` — the wave spec's display mapping, clamped to 55–98."""
    value = _as_float(similarity)
    value = 0.0 if value is None else max(0.0, min(1.0, value))
    return int(round(MATCH_PCT_BASE + MATCH_PCT_SPAN * value))


MATCH_PCT_MIN = MATCH_PCT_BASE
MATCH_PCT_MAX = MATCH_PCT_BASE + MATCH_PCT_SPAN


def block_contributions(
    venue_vec: np.ndarray, user_vec: np.ndarray, space: VenueSpace
) -> dict[str, float]:
    """Per-block share of the cosine similarity. The values SUM to the similarity.

    That identity is what makes the reason chips defensible rather than decorative:
    "Football · Your budget · High rated" is the three largest addends of the number
    on the badge, not a separately-invented explanation of it.
    """
    venue = np.asarray(venue_vec, dtype=np.float64)
    user = np.asarray(user_vec, dtype=np.float64)
    denom = float(np.linalg.norm(venue)) * float(np.linalg.norm(user))
    if denom <= 0.0:
        return {block: 0.0 for block in BLOCK_ORDER}
    spans = space.slices
    return {
        block: float(np.dot(venue[spans[block]], user[spans[block]]) / denom)
        for block in BLOCK_ORDER
    }


def _top_shared_amenity(
    venue_vec: np.ndarray, user_vec: np.ndarray, space: VenueSpace
) -> str | None:
    """The amenity contributing most to the amenity block, for a specific chip.

    "Amenities" as a chip says nothing; "Floodlights" says why this venue is in the
    rail. Both operands are consulted, so the chip names an amenity the venue HAS and
    the user's own history shows they use.
    """
    span = space.slices[BLOCK_AMENITIES]
    if span.stop <= span.start:
        return None
    products = np.asarray(venue_vec[span], dtype=np.float64) * np.asarray(
        user_vec[span], dtype=np.float64
    )
    if products.size == 0 or float(products.max()) <= 0.0:
        return None
    return space.amenities[int(np.argmax(products))]


def build_reasons(
    venue: Mapping[str, Any],
    venue_vec: np.ndarray,
    user_vec: np.ndarray,
    space: VenueSpace,
) -> list[str]:
    """Up to `REASON_MAX` chips: the top contributing feature groups, as text.

    A block below `REASON_MIN_SHARE` of the similarity is dropped rather than padded
    into third place — an explanation that did not explain anything is worse than one
    fewer chip, because the user cannot tell them apart.
    """
    contributions = block_contributions(venue_vec, user_vec, space)
    total = sum(v for v in contributions.values() if v > 0.0)
    if total <= 0.0:
        return []

    ordered = sorted(
        ((block, value) for block, value in contributions.items() if value > 0.0),
        key=lambda pair: pair[1],
        reverse=True,
    )

    reasons: list[str] = []
    for block, value in ordered:
        if len(reasons) >= REASON_MAX or value / total < REASON_MIN_SHARE:
            break
        if block == BLOCK_SPORT:
            reasons.append(sport_label(_pick(venue, "sportType", "sport_type")))
        elif block == BLOCK_PRICE:
            reasons.append("Your budget")
        elif block == BLOCK_RATING:
            reasons.append("High rated")
        elif block == BLOCK_AMENITIES:
            amenity = _top_shared_amenity(venue_vec, user_vec, space)
            if amenity:
                reasons.append(amenity_label(amenity))
        elif block == BLOCK_ZONE:
            reasons.append(zone_label(zone_of(_pick(venue, "address"), _pick(venue, "city"))))
        elif block == BLOCK_INDOOR:
            reasons.append(indoor_label(indoor_kind(_pick(venue, "groundType", "ground_type"))))
    return reasons


# ─────────────────────────────────────────────────────────────────────────────
# Published contract
# ─────────────────────────────────────────────────────────────────────────────


def reco_spec_fingerprint() -> str:
    """sha256 (16 hex chars) over every frozen table, constant and regex above.

    `features.py` gets away with a bare version string because its derivations are a
    short list a reviewer reads in full. This module carries ~60 amenity aliases, a
    scheme table, a sector regex and eleven weights: exactly the shape of thing that
    gets extended without a version bump. Hashing the CONTENTS turns "someone added
    an alias and forgot" from unexplained ranking drift into a load-time
    `incompatible` status — the same mechanism `text_norm.norm_spec_fingerprint()`
    exists to provide, and for the same reason.
    """
    digest = hashlib.sha256()

    def feed(label: str, value: object) -> None:
        digest.update(f"{label}={value}\n".encode("utf-8"))

    feed("version", RECO_SPEC_VERSION)
    feed("blocks", "|".join(BLOCK_ORDER))
    feed("l2_blocks", "|".join(sorted(L2_BLOCKS)))
    feed("price_buckets", PRICE_BUCKETS)
    feed("rating_max", RATING_MAX)
    feed("rating_prior_weight", RATING_PRIOR_WEIGHT)
    feed("rating_prior_fallback", RATING_PRIOR_FALLBACK)
    feed("w_history", W_HISTORY)
    feed("w_stated", W_STATED)
    feed("w_affinity", W_AFFINITY)
    feed("half_life", RECENCY_HALF_LIFE_DAYS)
    feed("match_base", MATCH_PCT_BASE)
    feed("match_span", MATCH_PCT_SPAN)
    feed("cold_pop", COLD_W_POPULARITY)
    feed("cold_sport", COLD_W_SPORT)
    feed("pop_bookings", POP_W_BOOKINGS)
    feed("pop_rating", POP_W_RATING)
    feed("reason_min_share", REASON_MIN_SHARE)
    feed("reason_max", REASON_MAX)
    for key in sorted(SPORT_ALIASES):
        feed("sport_alias", f"{key}>{SPORT_ALIASES[key]}")
    for key in sorted(AMENITY_ALIASES):
        feed("amenity_alias", f"{key}>{AMENITY_ALIASES[key]}")
    feed("amenity_falsey", "|".join(sorted(AMENITY_FALSEY_STRINGS)))
    for key in sorted(AMENITY_LABELS):
        feed("amenity_label", f"{key}>{AMENITY_LABELS[key]}")
    for needle, zone in ZONE_SCHEMES:
        feed("zone_scheme", f"{needle}>{zone}")
    feed("sector_pattern", _RE_SECTOR.pattern)
    feed("zone_area_any", ZONE_AREA_ANY)
    feed("zone_city_unknown", ZONE_CITY_UNKNOWN)
    feed("indoor_types", "|".join(sorted(INDOOR_GROUND_TYPES)))
    feed("outdoor_types", "|".join(sorted(OUTDOOR_GROUND_TYPES)))
    feed("profiles", f"{PROFILE_HISTORY}|{PROFILE_COLD_START}")
    return digest.hexdigest()[:16]


#: Canonical amenities this contract RECOGNISES — distinct from the fitted vocabulary
#: inside an artifact, which lists only the ones some venue actually has. `water` is
#: recognised here and named in the wave spec, but no seed venue carries a water key,
#: so it will not appear in a fitted space until an owner adds one. Publishing both
#: lists is what makes that difference visible instead of looking like a bug.
RECOGNISED_AMENITIES: tuple[str, ...] = tuple(sorted(set(AMENITY_ALIASES.values())))


def spec() -> dict[str, Any]:
    """The frozen contract, camelCase, for `/reco/spec` and `/health`.

    Serves the same non-documentation purpose as `/features/spec` and
    `/sentiment/spec`: the match% mapping and the source labels are duplicated in
    `mlClient.js` and in Dart, Node cannot import a Python module, and this endpoint
    lets `check_ml_service.js` ASSERT the two agree rather than hope.
    """
    return {
        "recoSpecVersion": RECO_SPEC_VERSION,
        "recoSpecFingerprint": reco_spec_fingerprint(),
        "blockOrder": list(BLOCK_ORDER),
        "l2Blocks": sorted(L2_BLOCKS),
        "priceBuckets": PRICE_BUCKETS,
        "ratingMax": RATING_MAX,
        "ratingPriorWeight": RATING_PRIOR_WEIGHT,
        "componentWeights": {name: COMPONENT_WEIGHTS[name] for name in COMPONENT_ORDER},
        "recencyHalfLifeDays": RECENCY_HALF_LIFE_DAYS,
        "matchPct": {
            "base": MATCH_PCT_BASE,
            "span": MATCH_PCT_SPAN,
            "min": MATCH_PCT_MIN,
            "max": MATCH_PCT_MAX,
            "formula": "round(55 + 43 * cosine)",
        },
        "profiles": [PROFILE_HISTORY, PROFILE_COLD_START],
        "labels": {PROFILE_HISTORY: LABEL_HISTORY, PROFILE_COLD_START: LABEL_COLD_START},
        "coldStart": {
            "popularityWeight": COLD_W_POPULARITY,
            "sportWeight": COLD_W_SPORT,
            "popularity": {"bookingsWeight": POP_W_BOOKINGS, "ratingWeight": POP_W_RATING},
        },
        "reasons": {"minShare": REASON_MIN_SHARE, "max": REASON_MAX},
        "recognisedAmenities": list(RECOGNISED_AMENITIES),
        "zone": {
            "source": "venues.address",
            "fallback": "venues.city",
            "sectorPattern": _RE_SECTOR.pattern,
            "schemes": [zone for _, zone in ZONE_SCHEMES],
            "note": "no zone column exists in the schema; the zone is derived",
        },
        "indoorOutdoor": {
            "source": "venues.ground_type",
            "indoor": sorted(INDOOR_GROUND_TYPES),
            "outdoor": sorted(OUTDOOR_GROUND_TYPES),
            "unknownReadsAs": "outdoor",
        },
        # The two gaps, published rather than papered over. See the module docstring.
        "statedBudget": None,
        "statedBudgetNote": (
            "player_profiles has no budget column; the stated component is sports only, "
            "because the history component already carries the user's price behaviour"
        ),
        "favouritesSource": "reviews.rating >= 4 (hidden = false, venue_id IS NOT NULL)",
        "favouritesNote": "no favourites table exists in the schema",
    }


__all__ = (
    "RECO_SPEC_VERSION",
    "RecoFeatureError",
    "BLOCK_SPORT",
    "BLOCK_PRICE",
    "BLOCK_RATING",
    "BLOCK_AMENITIES",
    "BLOCK_ZONE",
    "BLOCK_INDOOR",
    "BLOCK_ORDER",
    "L2_BLOCKS",
    "PRICE_BUCKETS",
    "RATING_MAX",
    "RATING_PRIOR_WEIGHT",
    "RATING_PRIOR_FALLBACK",
    "W_HISTORY",
    "W_STATED",
    "W_AFFINITY",
    "COMPONENT_HISTORY",
    "COMPONENT_STATED",
    "COMPONENT_AFFINITY",
    "COMPONENT_ORDER",
    "COMPONENT_WEIGHTS",
    "RECENCY_HALF_LIFE_DAYS",
    "MATCH_PCT_BASE",
    "MATCH_PCT_SPAN",
    "MATCH_PCT_MIN",
    "MATCH_PCT_MAX",
    "PROFILE_HISTORY",
    "PROFILE_COLD_START",
    "LABEL_HISTORY",
    "LABEL_COLD_START",
    "COLD_W_POPULARITY",
    "COLD_W_SPORT",
    "POP_W_BOOKINGS",
    "POP_W_RATING",
    "REASON_MIN_SHARE",
    "REASON_MAX",
    "SPORT_ALIASES",
    "AMENITY_ALIASES",
    "AMENITY_LABELS",
    "RECOGNISED_AMENITIES",
    "ZONE_SCHEMES",
    "ZONE_AREA_ANY",
    "INDOOR_GROUND_TYPES",
    "OUTDOOR_GROUND_TYPES",
    "VenueSpace",
    "canon_sport",
    "canon_sports",
    "sport_label",
    "amenity_flags",
    "amenity_label",
    "area_token",
    "zone_of",
    "zone_label",
    "indoor_kind",
    "indoor_label",
    "shrunk_rating",
    "recency_weight",
    "venue_price",
    "price_bucket_of",
    "venue_vector",
    "venue_matrix",
    "stated_vector",
    "unit",
    "weighted_mean",
    "blend_user_vector",
    "cosine_scores",
    "match_pct",
    "block_contributions",
    "build_reasons",
    "reco_spec_fingerprint",
    "spec",
)
