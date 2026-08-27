# Venue recommender — evaluation (model #3)

- **Model:** `reco-content-v1-20260827-090526`
- **Trained:** 2026-08-27T09:05:26.936208+00:00
- **Feature spec:** `reco-features-v1` (fingerprint `138790ba577ea0f0`)
- **Snapshot:** 10 venues, 8 users, sha256 `2a0d3aba33dcb5de...`
- **Method:** leave-one-out — hide each eligible user's most-recent confirmed booking, rank the full catalogue from the remaining profile, and check where the held-out venue lands.

> **Small-corpus caveat.** Only **2** user(s) had the >=2 bookings that leave-one-out needs (of 8 players in the snapshot). At this n the HitRate/MRR figures are a sanity check on the model's DIRECTION, not a number to quote — one user flips HitRate@5 by ~50 points. The release gate is waived below 5 evaluable users; the model is released anyway because the cold-start path is popularity, so there is nothing safer to serve.

| metric | content model | popularity baseline |
|---|---|---|
| HitRate@3 | **1.000** | 1.000 |
| HitRate@5 | **1.000** | 1.000 |
| MRR | **1.000** | 1.000 |

**Relative lift @5:** +0.0%  ·  eligible users: 2/8

The popularity baseline is the recommender's OWN cold-start path with the user's profile
stripped (popularity-in-city blended with stated sports) — the same ranking a brand-new
user sees. Lift is therefore precisely the value a user's booking history adds on top of
"what's popular near you".
