"""Snapshot-backed content recommender for venue suggestions."""
from __future__ import annotations

from datetime import datetime, timezone
from typing import Any, Mapping, Sequence

import numpy as np

from .reco_features import (
    BLOCK_SPORT, COLD_W_POPULARITY, COLD_W_SPORT, LABEL_COLD_START,
    LABEL_HISTORY, POP_W_BOOKINGS, POP_W_RATING, PROFILE_COLD_START,
    PROFILE_HISTORY, VenueSpace, blend_user_vector, build_reasons,
    canon_sports, cosine_scores, match_pct, recency_weight,
    stated_vector, venue_matrix, venue_vector, weighted_mean,
)


class VenueRecommender:
    """Fitted venue catalogue plus frozen user-history snapshot."""

    def __init__(self, venues: Sequence[Mapping[str, Any]], users: Sequence[Mapping[str, Any]], *, as_of: str | None = None):
        self.venues = [dict(v) for v in venues]
        self.users = {str(u.get("userId") or u.get("user_id")): dict(u) for u in users}
        self.as_of = as_of or datetime.now(timezone.utc).isoformat()
        self.space = VenueSpace.fit(self.venues)
        self.matrix, self.norms = venue_matrix(self.venues, self.space)
        self.ids = [str(v.get("venueId") or v.get("id")) for v in self.venues]
        self.id_to_index = {venue_id: i for i, venue_id in enumerate(self.ids)}
        counts = np.asarray([float(v.get("bookingCount") or v.get("booking_count") or 0) for v in self.venues])
        ratings = np.asarray([float(v.get("rating") or 0) / 5.0 for v in self.venues])
        count_score = np.log1p(counts) / max(float(np.log1p(counts).max()), 1.0)
        self.popularity = POP_W_BOOKINGS * count_score + POP_W_RATING * ratings

    def _profile(self, user_id: str):
        user = self.users.get(str(user_id), {})
        history_vecs, history_weights = [], []
        for row in user.get("bookings", []):
            idx = self.id_to_index.get(str(row.get("venueId") or row.get("venue_id")))
            if idx is None:
                continue
            history_vecs.append(self.matrix[idx])
            raw_date = row.get("bookedAt") or row.get("created_at")
            try:
                booked = datetime.fromisoformat(str(raw_date).replace("Z", "+00:00"))
                anchor = datetime.fromisoformat(str(self.as_of).replace("Z", "+00:00"))
                days_ago = max(0.0, (anchor - booked).total_seconds() / 86400.0)
            except (TypeError, ValueError):
                days_ago = 0.0
            history_weights.append(recency_weight(days_ago))
        history = weighted_mean(history_vecs, history_weights)
        affinity_vecs = []
        for row in user.get("highReviews", user.get("high_reviews", [])):
            idx = self.id_to_index.get(str(row.get("venueId") or row.get("venue_id")))
            if idx is not None:
                affinity_vecs.append(self.matrix[idx])
        affinity = np.mean(affinity_vecs, axis=0) if affinity_vecs else None
        stated = stated_vector(user.get("sportPreferences", user.get("sport_preferences", [])), self.space)
        vector, weights = blend_user_vector({"history": history, "stated": stated, "affinity": affinity})
        return user, vector, weights, bool(history_vecs or affinity_vecs)

    def recommend(self, user_id: str, limit: int = 20) -> dict[str, Any]:
        user, vector, weights, has_activity = self._profile(user_id)
        city = str(user.get("city") or "").strip().lower()
        city_mask = np.asarray([not city or str(v.get("city") or "").strip().lower() == city for v in self.venues])
        active_mask = np.asarray([v.get("isActive", v.get("is_active", True)) is not False for v in self.venues])
        if has_activity and vector.size:
            scores = cosine_scores(self.matrix, self.norms, vector)
            profile, label = PROFILE_HISTORY, LABEL_HISTORY
        else:
            sports = set(canon_sports(user.get("sportPreferences", user.get("sport_preferences", []))))
            sport_scores = np.asarray([1.0 if str(v.get("sportType") or v.get("sport_type") or "").lower() in sports else 0.0 for v in self.venues])
            scores = COLD_W_POPULARITY * self.popularity + COLD_W_SPORT * sport_scores if sports else self.popularity.copy()
            profile, label = PROFILE_COLD_START, LABEL_COLD_START
        scores = np.where(city_mask & active_mask, scores, -1.0)
        order = np.argsort(-scores, kind="stable")[: max(1, min(int(limit), 100))]
        items = []
        for idx in order:
            if scores[idx] < 0:
                continue
            venue_sport = str(self.venues[idx].get("sportType") or self.venues[idx].get("sport_type") or "").strip().title()
            reasons = build_reasons(self.venues[idx], self.matrix[idx], vector, self.space) if profile == PROFILE_HISTORY else ([venue_sport] if sports and venue_sport else ["Popular nearby"])
            items.append({"venue_id": self.ids[idx], "score": round(float(scores[idx]), 6), "match_pct": match_pct(scores[idx]), "reasons": reasons})
        return {"items": items, "profile": profile, "label": label, "componentWeights": weights}
