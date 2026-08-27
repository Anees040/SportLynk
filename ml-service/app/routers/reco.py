"""Recommendation HTTP contracts — venues (Wave A), players + opponents (Wave B).

TWO KINDS OF ENDPOINT LIVE HERE, AND THEY FAIL DIFFERENTLY.

`/reco/venues` is served by a TRAINED artifact out of the registry, so it can
answer 503 `model_not_loaded` when the joblib is missing or its feature
fingerprint no longer matches the code.

`/reco/players` and `/reco/opponents` are served by `core.reco_rank`, a
deterministic weighted scorer whose weights the wave specification states
literally. There is no artifact, so there is nothing to load, so those two
endpoints CANNOT return `model_not_loaded` — a 503 from them would mean the whole
process is down, which Node's circuit breaker already handles. Do not "improve"
this by registering a fake model just to make the three endpoints look alike.

WHY NODE SENDS THE CANDIDATES INSTEAD OF JUST AN ID
This process has no database connection, by design (see main.py's trust
boundary), and it is never reachable from a phone. So it cannot look up who is on
a roster or which teams are public. Node resolves the pool — public players in the
right city playing the right sport who are not already members; public teams in
the same sport — and posts the rows. This service scores and orders them. The
spec's `{team_id}` stays in the body as the subject of the request, and the pool
travels beside it.

`source` ON THE WIRE
Wave A's venue payload carries `source: "model"` and Flutter shows its sparkle
only for that value. Wave B's two endpoints carry `source: "ranked"` instead —
deliberately a different word, because these numbers come from a published
formula rather than a learned one, and a screen that says "AI" over a weighted
mean would be overclaiming to the person reading it. Node maps a transport or
breaker failure to `"heuristic"` / `"unavailable"` exactly as it does for venues.
"""
from typing import Any

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from ..core import reco_features, reco_rank
from ..core.registry import registry

router = APIRouter(tags=["recommendations"])

#: Ceiling on a posted pool. Node's own SQL already caps its candidate queries far
#: below this; the limit is here so a malformed or hostile caller cannot make the
#: service score an unbounded list, and so the failure is a clean 422 rather than a
#: slow request. Pydantic enforces it before any of our code runs.
MAX_CANDIDATES = 500


class VenueRecoRequest(BaseModel):
    user_id: str = Field(min_length=1)
    limit: int = Field(default=20, ge=1, le=100)


class PoolRequest(BaseModel):
    """`{team_id}` as the spec states it, plus the pool Node resolved for it.

    `team` and the candidate rows are untyped maps on purpose: reco_rank reads
    every key tolerantly (snake_case or camelCase, missing or null) because its
    two Node callers were written at different times, and a strict schema here
    would turn "this row had no zone" — an ordinary, expected, correctly-handled
    absence — into a 422 that hides the rail entirely.
    """

    team_id: str = Field(min_length=1)
    team: dict[str, Any] = Field(default_factory=dict)
    candidates: list[dict[str, Any]] = Field(default_factory=list, max_length=MAX_CANDIDATES)
    limit: int = Field(default=20, ge=1, le=100)


def _subject(body: PoolRequest) -> dict[str, Any]:
    """The team being recommended FOR. `team_id` wins: it is what was requested."""
    return {**(body.team or {}), "team_id": body.team_id}


def _envelope(result: dict[str, Any]) -> dict[str, Any]:
    """Attach the contract identity to every ranked response.

    The version and fingerprint travel with the DATA, not just on /health, so a
    stored or logged payload can be traced back to the exact weights that produced
    its percentages. Wave A does the same with `modelVersion`.
    """
    return {
        **result,
        "source": "ranked",
        "rankSpecVersion": reco_rank.RANK_SPEC_VERSION,
        "rankSpecFingerprint": reco_rank.rank_spec_fingerprint(),
    }


@router.post("/reco/venues")
def recommend_venues(body: VenueRecoRequest) -> dict[str, Any]:
    loaded = registry.get("reco")
    if not loaded.is_ready:
        raise HTTPException(status_code=503, detail={"message": loaded.reason, "code": "model_not_loaded"})
    result = loaded.estimator.recommend(body.user_id, body.limit)
    return {**result, "source": "model", "modelVersion": loaded.version}


@router.post("/reco/players")
def recommend_players(body: PoolRequest) -> dict[str, Any]:
    """FR2.8 — rank candidate players for a team's roster screen."""
    return _envelope(reco_rank.rank_players(_subject(body), body.candidates, body.limit))


@router.post("/reco/opponents")
def recommend_opponents(body: PoolRequest) -> dict[str, Any]:
    """FR5.3 — rank candidate opponents, replacing S.2's |ELO gap| sort.

    Each item carries its own `components` breakdown; the app renders it as the
    expandable "Why this match?" row. `competitiveness` is null whenever either
    side is unranked (FR2.6) even though the item still has a rank — see
    reco_rank.score_opponent.
    """
    return _envelope(reco_rank.rank_opponents(_subject(body), body.candidates, body.limit))


@router.get("/reco/spec")
def reco_spec() -> dict[str, Any]:
    return {"success": True, "data": reco_features.spec(), "message": "Venue recommender feature contract"}


@router.get("/reco/rank-spec")
def reco_rank_spec() -> dict[str, Any]:
    return {
        "success": True,
        "data": reco_rank.spec(),
        "message": "Player and opponent ranking contract (deterministic, not trained)",
    }


def warm() -> str:
    loaded = registry.get("reco")
    return loaded.status
