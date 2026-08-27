"""Venue recommendation HTTP contract."""
from typing import Any
from fastapi import APIRouter
from pydantic import BaseModel, Field
from ..core.registry import registry
from ..core import reco_features

router = APIRouter(tags=["recommendations"])

class VenueRecoRequest(BaseModel):
    user_id: str = Field(min_length=1)
    limit: int = Field(default=20, ge=1, le=100)

@router.post("/reco/venues")
def recommend_venues(body: VenueRecoRequest) -> dict[str, Any]:
    loaded = registry.get("reco")
    if not loaded.is_ready:
        from fastapi import HTTPException
        raise HTTPException(status_code=503, detail={"message": loaded.reason, "code": "model_not_loaded"})
    result = loaded.estimator.recommend(body.user_id, body.limit)
    return {**result, "source": "model", "modelVersion": loaded.version}

@router.get("/reco/spec")
def reco_spec() -> dict[str, Any]:
    return {"success": True, "data": reco_features.spec(), "message": "Venue recommender feature contract"}

def warm() -> str:
    loaded = registry.get("reco")
    return loaded.status

