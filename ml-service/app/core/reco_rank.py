"""
Player-for-team and opponent ranking  —  S.5 Wave B
═══════════════════════════════════════════════════════════════════════════════

WHAT THIS IS, AND WHAT IT IS NOT
This module is a DETERMINISTIC WEIGHTED SCORER. It is not model #4, and nothing
here is trained. The wave specification supplies the weights literally —
0.4/0.25/0.2/0.15 for player-for-team and 0.6/0.2/0.2 for opponents — so there is
no free parameter left to learn: any "training" would be a script that read those
numbers back out of a file it had just written. Saying so plainly is the point.
There is no joblib artifact, no entry in registry.KNOWN_MODELS, no eval report,
and `/reco/players` and `/reco/opponents` NEVER answer 503 model_not_loaded,
because there is no model to fail to load.

WHY IT LIVES IN THE ML SERVICE AT ALL
Two reasons, neither of them "because it sounds like ML":

  * ONE COPY OF THE FORMULA. The alternative is Node computing it, and then Dart
    re-deriving the same percentage to draw a bar. Wave A already established the
    seam — the venue match% mapping lives here and Node/Dart only render it — and
    a second scoring implementation is exactly where the two would drift apart.
  * THE SAME FINGERPRINT DISCIPLINE. Seven weights and two saturation caps are the
    shape of thing that gets "tuned" in a demo week and silently changes every
    percentage on screen. `rank_spec_fingerprint()` hashes all of them, `/health`
    publishes it, and check_ml_service.js can assert it.

WHY IT IS A NEW MODULE AND NOT AN ADDITION TO reco_features.py
reco_features.py is FROZEN. Its fingerprint (138790ba577ea0f0) is stamped inside
the RELEASED reco_latest.joblib, and registry.py refuses an artifact whose
fingerprint no longer matches — so appending one constant to that file would take
the venue recommender from `ready` to `incompatible` and break a shipped feature.
Wave B therefore gets its own contract with its own version and its own hash. It
IMPORTS the reusable helpers (canon_sport, zone_label, …) freely: importing does
not change what the other module hashes.

ABSENT COMPONENTS GET A NEUTRAL 0.5 PRIOR, NOT A ZERO, AND NOT A RENORMALISATION
Every score here is a weighted mean of components that can genuinely be missing —
a teamless player has no team rating, a player who has never booked has no zone.
Three options existed and the choice matters:

  * ZERO. Rejected: it reads "no data" as "worst possible", the cold-start
    injustice ER2.5 exists to avoid. A new player would rank below everyone.
  * RENORMALISE over present components only. Rejected for a subtler reason: it
    puts candidates on DIFFERENT scales. A player scored on four components and
    one scored on two would both be able to reach 100%, and the list would then be
    sorted by a number that does not mean the same thing in two adjacent rows.
  * A NEUTRAL 0.5 PRIOR, which is what backend/src/utils/trustScore.js already
    does for the same problem. Every candidate is scored on the same denominator,
    an unknown component neither rewards nor punishes, and the published
    `components` map still carries NULL — never the prior — so the UI can print
    "no data" instead of drawing a misleading half-full bar. That is the rule here.

WHAT THE SCHEMA CANNOT PROVIDE (published, not papered over)
The spec asks for "sport/position fit", "same city", and "zone proximity".
player_profiles is (user_id, sport_preferences, elo_rating, trust_score, trust_*).
There is no position column, no city column, and no zone column anywhere in the
player tables. So:

  * POSITION does not exist. The 0.4 block is sport fit alone, and `spec()`
    publishes `"position": null` with the reason. Inventing a column here would
    mean inventing the data in it.
  * CITY and ZONE are DERIVED BY NODE from the venues a player actually books
    (see the route), the same way Wave A derives a venue's zone from its address
    because venues has no zone column either. A player who has never booked has
    zone `None`, which is an absent component, not a zero.

INPUT SHAPE
Node resolves the candidate pool and passes it in. This process has no database
connection (main.py's trust boundary), so it cannot look a player up — it scores
what it is given. Keys are read tolerantly (snake_case or camelCase) through
reco_features._pick, because Node's two callers were written months apart.
"""

from __future__ import annotations

import hashlib
import math
from typing import Any, Iterable, Mapping, Sequence

from .reco_features import (
    ZONE_AREA_ANY,
    ZONE_CITY_UNKNOWN,
    _as_float,
    _pick,
    _slug,
    canon_sport,
    canon_sports,
    sport_label,
    zone_label,
    zone_of,
)

# The frozen contract

#: Bumped whenever any number below changes meaning. The fingerprint catches the
#: case where someone changes one and forgets to bump this.
RANK_SPEC_VERSION = "reco-rank-v1"

#: Component keys. Published as ordered tuples so the "Why this match?" breakdown
#: renders in the same order on every screen and in /reco/rank-spec.
C_FIT = "fit"
C_ELO = "elo"
C_ACTIVITY = "activity"
C_ZONE = "zone"
C_TRUST = "trust"

PLAYER_COMPONENT_ORDER: tuple[str, ...] = (C_FIT, C_ELO, C_ACTIVITY, C_ZONE)
OPPONENT_COMPONENT_ORDER: tuple[str, ...] = (C_ELO, C_TRUST, C_ACTIVITY)

#: FR2.8 — player-for-team suggestion weights, exactly as the wave specifies.
PLAYER_WEIGHTS: dict[str, float] = {
    C_FIT: 0.40,       # sport fit (position has no column — see the module docstring)
    C_ELO: 0.25,       # ELO proximity of the candidate's teams; trust proxies it when teamless
    C_ACTIVITY: 0.20,  # bookings in the last 30 days, saturating
    C_ZONE: 0.15,      # derived zone proximity
}

#: FR5.3 — opponent ranking weights. Replaces the v1 |ELO gap| sort as the number
#: on the card; utils/elo.js keeps the v1 formula as the fallback when this service
#: is unreachable, so the bar never goes blank because Python is down.
OPPONENT_WEIGHTS: dict[str, float] = {
    C_ELO: 0.60,
    C_TRUST: 0.20,
    C_ACTIVITY: 0.20,
}

#: The rating gap at which two sides are as mismatched as the score can express.
#: 400 is not a new number: it is backend/src/utils/elo.js COMP_GAP_CAP and
#: PREFERRED_ELO_BAND, and one ELO class in the standard logistic curve. If these
#: ever disagree the app would draw a "well matched" border around a row whose
#: percentage says otherwise.
ELO_GAP_CAP = 400.0

#: trust_score is already 0..100 (ER2.5), so normalising is a division.
TRUST_MAX = 100.0

#: Activity saturation. Bookings/matches are counted over the same 30-day window
#: teamStats.ACTIVITY_WINDOW_DAYS uses, then divided by these caps and clipped.
#:
#: a fixed cap, deliberately, not a pool-relative max. Normalising against the
#: busiest candidate in the list would make one player's percentage depend on who
#: else happens to be in it — the same player would score 78% in one team's rail
#: and 41% in another's, and neither number could be explained to them. A fixed
#: cap is stable, reproducible, and means "active enough", which is what the
#: component is asking.
PLAYER_ACTIVITY_CAP = 8.0   # 8 bookings in 30 days ≈ twice a week
TEAM_ACTIVITY_CAP = 4.0     # 4 terminal matches in 30 days ≈ one a week
ACTIVITY_WINDOW_DAYS = 30

#: What an absent component contributes to the aggregate. Never to the published
#: component value, which stays null. Mirrors trustScore.js NEUTRAL_PRIOR.
NEUTRAL_PRIOR = 0.5

#: Zone proximity, which is a three-state answer and not a distance: the derived
#: zones match, only the cities match, or neither. There are no coordinates for a
#: player (bookings carry a venue, venues carry an address), so a kilometre
#: distance would be fabricated precision.
ZONE_SAME = 1.0
ZONE_SAME_CITY = 0.5
ZONE_DIFFERENT = 0.0

#: Percentage band. The floor exists for the reason elo.js gives for COMP_MIN: a
#: "0%" reads as missing data, while "5%" is an honest way to say "badly matched".
#: The ceiling is 99 rather than 100 because these components are proxies — a
#: derived zone and a saturating booking count — and a flat 100% would claim a
#: certainty the inputs cannot support.
PCT_MIN = 5
PCT_MAX = 99

#: A component has to be at least this strong before it is worth naming in the
#: "Why this match?" row. Below it the sentence would be noise dressed as a reason.
REASON_MIN = 0.55
REASON_MAX = 3


class RankInputError(ValueError):
    """A candidate row that cannot be scored at all (no id). Never a bad value."""


# Component maths


def _clip01(value: float) -> float:
    return 0.0 if value < 0.0 else (1.0 if value > 1.0 else value)


def elo_proximity(elo_a: Any, elo_b: Any) -> float | None:
    """1 − min(|Δ|, 400)/400. `None` when either rating is missing.

    This is the v1 competitiveness curve's own core term, unscaled: v1 published
    `round(100 − gap/400 × 95)`, which is this value mapped onto 5..100. Keeping
    the shared term identical is what lets the new score be described as "v1's
    rating term, plus trust and activity" rather than as a different opinion about
    what a close match is.
    """
    a = _as_float(elo_a)
    b = _as_float(elo_b)
    if a is None or b is None:
        return None
    gap = min(abs(a - b), ELO_GAP_CAP)
    return _clip01(1.0 - gap / ELO_GAP_CAP)


def trust_norm(trust: Any) -> float | None:
    """trust_score / 100. `None` when the row carries no score at all."""
    value = _as_float(trust)
    return None if value is None else _clip01(value / TRUST_MAX)


def activity_norm(count: Any, cap: float) -> float | None:
    """min(count, cap) / cap. `None` only when the caller could not count.

    A count of ZERO is a measurement, not an absence: a player who booked nothing
    in 30 days is genuinely inactive, and that has to score 0.0 rather than take
    the neutral prior. Node therefore sends 0, and sends null only if it did not
    ask the question.
    """
    value = _as_float(count)
    if value is None or cap <= 0:
        return None
    return _clip01(value / cap)


def sport_fit(candidate_sports: Any, team_sport: Any) -> float | None:
    """Does this player play the team's sport?

    1.0 when the team's sport is among their stated preferences, 0.0 when they
    have stated preferences and it is not among them, `None` when they have stated
    none. The third case is the honest one and it is why this is not a bool: an
    empty sport_preferences array is a profile nobody filled in, not a refusal to
    play cricket, and scoring it 0.0 would bury every new account.

    The 0.4 weight is the spec's "sport/position fit". There is no position column
    in player_profiles, so this is the sport half alone — published as
    `"position": null` in spec() rather than silently reweighted.
    """
    wanted = canon_sport(team_sport)
    stated = canon_sports(candidate_sports)
    if not wanted:
        return None
    if not stated:
        return None
    return 1.0 if wanted in stated else 0.0


def _zone_parts(value: Any) -> tuple[str | None, str | None]:
    """Split Wave A's `"<CITY>:<AREA>"` key, mapping its two sentinels to None.

    `zone_of()` yields `UNKNOWN` for a city it could not slug and `*` for an
    address with no recognisable area token, and both mean "not known". Treating
    them as literal values would match every unknown player to every other one and
    call it a neighbourhood.
    """
    text = str(value or "").strip()
    if not text:
        return (None, None)
    city, _, area = text.partition(":")
    city_key = city.strip().upper() or None
    if city_key == ZONE_CITY_UNKNOWN:
        city_key = None
    area_key = area.strip().upper() or None
    if area_key == ZONE_AREA_ANY:
        area_key = None
    return (city_key, area_key)


def _city_key(zone: Any, city: Any) -> str | None:
    """A city to compare on, from the zone key if present, else from free text.

    Slugged through reco_features' own `_slug` so a raw `"Islamabad"` from the
    teams table compares equal to the `ISLAMABAD` baked into a derived zone key.
    """
    from_zone, _ = _zone_parts(zone)
    if from_zone:
        return from_zone
    slug = _slug(city).upper()
    return slug or None


def zone_for(row: Mapping[str, Any]) -> str | None:
    """The row's zone key: taken as given, or derived from `address` + `city`.

    Node sends the RAW address and city of the venue a player (or a team's roster)
    books most often, not a zone key, because `zone_of()` — the one definition of
    "which part of town is this" — lives in reco_features.py. Deriving the key in
    SQL or in JavaScript would be a second implementation of the sector regex and
    the scheme table, and the two would disagree the first time either changed.
    """
    given = _pick(row, "zone")
    if given:
        return str(given)
    address = _pick(row, "address")
    city = _pick(row, "city")
    if address or city:
        return zone_of(address, city)
    return None


def zone_proximity(candidate_zone: Any, team_zone: Any, candidate_city: Any, team_city: Any) -> float | None:
    """Same derived area → 1.0, same city → 0.5, different city → 0.0.

    `None` when either side's city is unknown, which is the ordinary case for a
    player who has never booked anything — there is nothing to compare, so the
    component is absent and takes the neutral prior rather than a zero.

    A three-state answer rather than a distance, because there are no coordinates
    for a player: bookings carry a venue and venues carry a street address, so any
    figure in kilometres would be fabricated precision.
    """
    city_a = _city_key(candidate_zone, candidate_city)
    city_b = _city_key(team_zone, team_city)
    if not city_a or not city_b:
        return None
    if city_a != city_b:
        return ZONE_DIFFERENT
    _, area_a = _zone_parts(candidate_zone)
    _, area_b = _zone_parts(team_zone)
    if area_a and area_b and area_a == area_b:
        return ZONE_SAME
    # Same city, different or unknown part of town — still nearer than two cities.
    return ZONE_SAME_CITY


def aggregate(components: Mapping[str, float | None], weights: Mapping[str, float]) -> float:
    """Weighted mean over `weights`, substituting NEUTRAL_PRIOR for a null.

    The denominator is the FULL weight sum, always, so two candidates measured on
    different component sets remain directly comparable — the reason stated in the
    module docstring.
    """
    total = sum(weights.values()) or 1.0
    acc = 0.0
    for name, weight in weights.items():
        value = components.get(name)
        acc += weight * (NEUTRAL_PRIOR if value is None else _clip01(float(value)))
    return acc / total


def to_pct(score: Any) -> int:
    """0..1 score → the 5..99 band the UI prints. See PCT_MIN/PCT_MAX.

    HALF-UP, not `round()`. Python rounds a tie to the nearest EVEN integer, and a
    weighted mean of tenths lands on an exact .5 constantly (0.725 → 72, while
    0.735 → 74). Two candidates a hair apart in score would then print percentages
    a whole point apart in the wrong direction. `floor(x + 0.5)` is the rounding a
    reader expects, and it is monotone, which is what actually matters here.
    """
    value = _as_float(score)
    if value is None:
        return PCT_MIN
    return max(PCT_MIN, min(PCT_MAX, math.floor(_clip01(value) * 100 + 0.5)))


def _round6(value: float | None) -> float | None:
    return None if value is None else round(float(value), 6)


def _order_key(id_field: str):
    """Sort by the PRINTED percentage first, then the raw score, then the id.

    Percentage first because a list must never show a lower number above a higher
    one: two scores that differ in the twelfth decimal can round to different
    integers, and a rail whose order visibly contradicts its own labels reads as
    broken. The raw score then breaks percentage ties, and the id breaks the rest —
    a stable order matters for a surface behind pull-to-refresh.
    """
    def key(item: Mapping[str, Any]) -> tuple[int, float, str]:
        return (-int(item["match_pct"]), -float(item["score"]), str(item[id_field]))

    return key


# Reasons — the "Why this match?" row


def _reasons(pairs: Iterable[tuple[str | None, float | None]]) -> list[str]:
    """Keep the strongest few sentences whose component actually earned them.

    Ordered by component strength rather than by weight, because the answer to
    "why this one?" is whichever signal is unusual about it, and a null component
    can never produce a sentence — a reason derived from the neutral prior would be
    the model explaining itself with a number it made up.
    """
    scored = [(text, value) for text, value in pairs if text and value is not None and value >= REASON_MIN]
    scored.sort(key=lambda item: -item[1])
    return [text for text, _ in scored[:REASON_MAX]]


# Player-for-team  (FR2.8)


def score_player(candidate: Mapping[str, Any], team: Mapping[str, Any]) -> dict[str, Any]:
    """One candidate, scored against one team. Pure; no ordering, no filtering.

    The pool itself — public players, same city, right sport, not already on the
    roster — is Node's job, because it is a database question and this process has
    no database. What arrives here has already passed those gates.
    """
    user_id = _pick(candidate, "userId", "user_id", "id")
    if not user_id:
        raise RankInputError("candidate has no userId")

    team_sport = _pick(team, "sport")
    fit = sport_fit(_pick(candidate, "sports", "sportPreferences", "sport_preferences"), team_sport)

    # The spec's "ELO-proximity of their teams (or trust as proxy if teamless)".
    # FR2.6 extends "teamless" to "unranked": a team that has never played carries
    # the 1000 placeholder, and a proximity computed from it would be arithmetic on
    # a number that means "unknown". Both cases fall through to trust, and
    # `eloSource` records which one happened so the breakdown can say so.
    candidate_elo = _pick(candidate, "teamElo", "team_elo", "elo")
    ranked = _pick(candidate, "teamRanked", "team_ranked", "ranked", default=None)
    if candidate_elo is not None and ranked is not False:
        proximity = elo_proximity(candidate_elo, _pick(team, "elo"))
        elo_source = "team_elo"
    else:
        proximity = None
        elo_source = "trust_proxy"
    if proximity is None:
        proximity = trust_norm(_pick(candidate, "trustScore", "trust_score"))
        elo_source = "trust_proxy"

    activity = activity_norm(
        _pick(candidate, "bookings30d", "bookings_30d", default=None), PLAYER_ACTIVITY_CAP
    )
    candidate_zone = zone_for(candidate)
    team_zone = zone_for(team)
    zone = zone_proximity(
        candidate_zone, team_zone,
        _pick(candidate, "city"), _pick(team, "city"),
    )

    components = {C_FIT: fit, C_ELO: proximity, C_ACTIVITY: activity, C_ZONE: zone}
    score = aggregate(components, PLAYER_WEIGHTS)

    zone_text = zone_label(candidate_zone) if zone == ZONE_SAME else None
    reasons = _reasons((
        (f"Plays {sport_label(team_sport)}" if fit else None, fit),
        ("Similar rating" if elo_source == "team_elo" else "Well reviewed", proximity),
        ("Playing regularly", activity),
        (f"Nearby · {zone_text}" if zone_text else "Same city", zone),
    ))

    return {
        "user_id": str(user_id),
        "score": round(float(score), 6),
        "match_pct": to_pct(score),
        "components": {name: _round6(components[name]) for name in PLAYER_COMPONENT_ORDER},
        "elo_source": elo_source,
        "reasons": reasons,
    }


def rank_players(
    team: Mapping[str, Any], candidates: Sequence[Mapping[str, Any]], limit: int = 20
) -> dict[str, Any]:
    """Score every candidate, best first, and say how many were considered.

    `considered` ships because a rail of three names out of a pool of three is a
    different fact from three out of ninety, and the roster screen should be able
    to tell the captain which one it is showing them.

    Ties break on user_id so two identical candidates do not swap places between
    two requests — a rail that reshuffles on every pull-to-refresh looks broken.
    """
    scored: list[dict[str, Any]] = []
    for row in candidates or ():
        try:
            scored.append(score_player(row, team))
        except RankInputError:
            continue  # a row Node could not identify is dropped, not guessed at
    scored.sort(key=_order_key("user_id"))
    return {
        "items": scored[: max(1, min(int(limit or 20), 100))],
        "considered": len(scored),
        "weights": dict(PLAYER_WEIGHTS),
        "componentOrder": list(PLAYER_COMPONENT_ORDER),
    }


# Opponent ranking  (FR5.3 – FR5.5, upgrading S.2's deterministic sort)


def score_opponent(candidate: Mapping[str, Any], me: Mapping[str, Any]) -> dict[str, Any]:
    """One candidate opponent, scored against my team.

    FR2.6 IS PRESERVED IN WHAT IS *DISPLAYED*. When either side has no verified
    match its rating is a placeholder, so `competitiveness` — the percentage the
    card prints — comes back NULL exactly as v1's elo.competitivenessFor() returns
    null, and the UI keeps drawing "Unranked". The candidate is still RANKED, on
    trust and activity with the rating term taking the neutral prior, because the
    alternative is dropping every new team to the bottom of every list and giving
    them nobody to play. v1 did the same thing less visibly: it ordered by
    `abs(COALESCE(t.elo, 1000) - myElo)`, i.e. it also sorted unranked teams by the
    placeholder while refusing to print a number derived from it.
    """
    team_id = _pick(candidate, "teamId", "team_id", "id")
    if not team_id:
        raise RankInputError("candidate has no teamId")

    both_ranked = _pick(candidate, "ranked", default=None) is not False and _pick(me, "ranked", default=None) is not False
    proximity = elo_proximity(_pick(candidate, "elo"), _pick(me, "elo")) if both_ranked else None
    trust = trust_norm(_pick(candidate, "trustScore", "trust_score"))
    activity = activity_norm(
        _pick(candidate, "matches30d", "matches_30d", default=None), TEAM_ACTIVITY_CAP
    )

    components = {C_ELO: proximity, C_TRUST: trust, C_ACTIVITY: activity}
    score = aggregate(components, OPPONENT_WEIGHTS)

    reasons = _reasons((
        ("Evenly matched rating", proximity),
        ("Reliable opponent", trust),
        ("Playing regularly", activity),
    ))

    return {
        "team_id": str(team_id),
        "score": round(float(score), 6),
        "match_pct": to_pct(score),
        # NULL when FR2.6 says the rating is not a measurement. This is the number
        # the card prints, and it is the only field allowed to be null-for-honesty.
        "competitiveness": to_pct(score) if proximity is not None else None,
        "components": {name: _round6(components[name]) for name in OPPONENT_COMPONENT_ORDER},
        "ranked": bool(proximity is not None),
        "reasons": reasons,
    }


def rank_opponents(
    me: Mapping[str, Any], candidates: Sequence[Mapping[str, Any]], limit: int = 60
) -> dict[str, Any]:
    """Score and order candidate opponents, best first, ties broken on team_id."""
    scored: list[dict[str, Any]] = []
    for row in candidates or ():
        try:
            scored.append(score_opponent(row, me))
        except RankInputError:
            continue
    scored.sort(key=_order_key("team_id"))
    return {
        "items": scored[: max(1, min(int(limit or 60), 200))],
        "considered": len(scored),
        "weights": dict(OPPONENT_WEIGHTS),
        "componentOrder": list(OPPONENT_COMPONENT_ORDER),
    }


# Published contract


def rank_spec_fingerprint() -> str:
    """sha256 (16 hex) over every weight, cap and band above.

    Same mechanism and same motivation as reco_spec_fingerprint(): these are seven
    weights and five thresholds that decide every percentage two screens draw, and
    "someone nudged 0.6 to 0.7 during demo week" must not be an invisible change.
    Deliberately INDEPENDENT of reco_features' fingerprint — this contract backs no
    pickled artifact, so a change here is a version bump, not an `incompatible`
    model.
    """
    digest = hashlib.sha256()

    def feed(label: str, value: object) -> None:
        digest.update(f"{label}={value}\n".encode("utf-8"))

    feed("version", RANK_SPEC_VERSION)
    for name in PLAYER_COMPONENT_ORDER:
        feed("player_weight", f"{name}>{PLAYER_WEIGHTS[name]}")
    for name in OPPONENT_COMPONENT_ORDER:
        feed("opponent_weight", f"{name}>{OPPONENT_WEIGHTS[name]}")
    feed("elo_gap_cap", ELO_GAP_CAP)
    feed("trust_max", TRUST_MAX)
    feed("player_activity_cap", PLAYER_ACTIVITY_CAP)
    feed("team_activity_cap", TEAM_ACTIVITY_CAP)
    feed("activity_window_days", ACTIVITY_WINDOW_DAYS)
    feed("neutral_prior", NEUTRAL_PRIOR)
    feed("zone_same", ZONE_SAME)
    feed("zone_same_city", ZONE_SAME_CITY)
    feed("zone_different", ZONE_DIFFERENT)
    feed("pct_min", PCT_MIN)
    feed("pct_max", PCT_MAX)
    feed("reason_min", REASON_MIN)
    feed("reason_max", REASON_MAX)
    return digest.hexdigest()[:16]


def spec() -> dict[str, Any]:
    """The contract, camelCase, for `/reco/rank-spec` and `/health`.

    Published for the same reason as the other three specs: Node and Dart both hold
    a copy of the percentage band and the component names, neither can import
    Python, and check_ml_service.js has to be able to ASSERT they agree instead of
    assuming it. The `gaps` block is part of the contract, not a footnote — a
    reviewer reading this endpoint should learn that "position fit" scored on sport
    alone before they learn it from the code.
    """
    return {
        "rankSpecVersion": RANK_SPEC_VERSION,
        "rankSpecFingerprint": rank_spec_fingerprint(),
        "trained": False,
        "trainedNote": (
            "deterministic weighted scorer — the wave specifies the weights literally, "
            "so there is nothing to learn, no artifact, and no registry entry"
        ),
        "players": {
            "weights": {name: PLAYER_WEIGHTS[name] for name in PLAYER_COMPONENT_ORDER},
            "componentOrder": list(PLAYER_COMPONENT_ORDER),
            "activityCap": PLAYER_ACTIVITY_CAP,
        },
        "opponents": {
            "weights": {name: OPPONENT_WEIGHTS[name] for name in OPPONENT_COMPONENT_ORDER},
            "componentOrder": list(OPPONENT_COMPONENT_ORDER),
            "activityCap": TEAM_ACTIVITY_CAP,
        },
        "eloGapCap": ELO_GAP_CAP,
        "trustMax": TRUST_MAX,
        "activityWindowDays": ACTIVITY_WINDOW_DAYS,
        "neutralPrior": NEUTRAL_PRIOR,
        "absentComponentPolicy": (
            "an absent component contributes the neutral prior to the aggregate and stays "
            "null in the published components map, so every candidate shares one denominator"
        ),
        "zone": {"same": ZONE_SAME, "sameCity": ZONE_SAME_CITY, "different": ZONE_DIFFERENT},
        "matchPct": {
            "min": PCT_MIN,
            "max": PCT_MAX,
            "formula": "clamp(floor(100 * score + 0.5), 5, 99)  # half-up, not banker's",
            "note": (
                "no cosmetic remap — unlike the venue recommender's 55 + 43*cosine band, "
                "these components are already 0..1, so the score IS the percentage"
            ),
        },
        "reasons": {"min": REASON_MIN, "max": REASON_MAX},
        "gaps": {
            "position": None,
            "positionNote": (
                "player_profiles has no position column; the 0.4 block is sport fit alone "
                "and is documented as such rather than reweighted"
            ),
            "playerCity": "derived from the city of the venue the player books most often",
            "playerZone": (
                "derived here by reco_features.zone_of() from the address Node sends for "
                "that venue; players and teams have no zone column"
            ),
            "competitiveness": (
                "null whenever either team is unranked (FR2.6), matching v1's "
                "elo.competitivenessFor(); the candidate is still ranked"
            ),
        },
    }


__all__ = (
    "RANK_SPEC_VERSION",
    "RankInputError",
    "C_FIT",
    "C_ELO",
    "C_ACTIVITY",
    "C_ZONE",
    "C_TRUST",
    "PLAYER_COMPONENT_ORDER",
    "OPPONENT_COMPONENT_ORDER",
    "PLAYER_WEIGHTS",
    "OPPONENT_WEIGHTS",
    "ELO_GAP_CAP",
    "TRUST_MAX",
    "PLAYER_ACTIVITY_CAP",
    "TEAM_ACTIVITY_CAP",
    "ACTIVITY_WINDOW_DAYS",
    "NEUTRAL_PRIOR",
    "ZONE_SAME",
    "ZONE_SAME_CITY",
    "ZONE_DIFFERENT",
    "PCT_MIN",
    "PCT_MAX",
    "elo_proximity",
    "trust_norm",
    "activity_norm",
    "sport_fit",
    "zone_for",
    "zone_proximity",
    "aggregate",
    "to_pct",
    "score_player",
    "rank_players",
    "score_opponent",
    "rank_opponents",
    "rank_spec_fingerprint",
    "spec",
)
