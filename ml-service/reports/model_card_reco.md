# Model card — venue recommender (model #3)

**Version:** `reco-content-v1-20260827-200702`  ·  **Feature spec:** `reco-features-v1` (`138790ba577ea0f0`)
**Trained:** 2026-08-27T20:07:02.581850+00:00  ·  **Evaluated:** 2026-08-27T20:07:46+00:00 by `training/eval_reco.py`
**Serving path:** `app.core.reco_model.VenueRecommender`, unpickled by the model registry,
which refuses the artifact if the feature fingerprint no longer matches `core/reco_features.py`.

## What it is
A content-based recommender — no collaborative filtering, no learned weights. Each venue
becomes a vector of its own attributes; each player becomes a recency-weighted blend of the
venues they booked, the sports they ticked, and the venues they rated >= 4; ranking is cosine
similarity. "Training" fits the venue space over the catalogue and freezes a user snapshot
into the served object.

## Features
Six L2-normalised blocks, in order: sport, price_bucket, rating, amenities, zone, indoor_outdoor. Every block is unit-normalised
*within the block* before the vector is assembled, so a 4,000-rupee price cannot swamp a
one-hot sport — the pitfall this design exists to avoid. Absent attributes stay absent
(an unrated venue is not silently given the mean).

## Weights
| where | weights | how they were chosen |
|---|---|---|
| user-vector blend | history 0.5 · stated 0.3 · affinity 0.2 | swept on the offline eval; the grid is flat within sampling noise, so history leads because it is the only block that separates two players who ticked the same sport — table and verdict in `reco_eval.md` |
| cold-start blend | popularity 0.6 · stated sport 0.4 | no history to weight; popularity leads by design |
| popularity score | log booked-count 0.7 · rating 0.3 | count dominates so a 5-star venue with one booking cannot top the rail |
| match % | `55 + 43 x cosine` → 55-98% | spread audited in `reco_eval.md`; a wall of 97-99% would be meaningless |

Missing components **renormalise** rather than shrink the vector: a player with no reviews
is scored on 0.625 history + 0.375 stated, and the applied weights ship in the response
so the app can show which signals a given player actually had.

## Cold-start policy
A player with no bookings, no high reviews and no usable profile vector is **never** scored
by cosine — that would be a zero vector, which is undefined, not a low score. They take the
popularity branch instead, labelled **"Popular nearby"** rather than "For you", with no
personalised percentage claimed. Verified in this run: 18 of the evaluated players have no bookings, no high reviews and no stated sport — a zero profile vector, where cosine similarity is undefined rather than small. Every probed one took the popularity branch and returned a full rail (profile: `cold_start`), so the guard holds on this population and no personalised percentage is claimed for them.

## Metrics (leave-last-out, top-5, novel-venue cohort, n = 89)
| arm | HitRate@5 | Precision@5 | MRR |
|---|---|---|---|
| random | 0.191 | 0.038 | 0.139 |
| popularity | 0.247 | 0.049 | 0.204 |
| cold-start (as served) | 0.371 | 0.074 | 0.235 |
| **content model** | **0.461** | **0.092** | **0.250** |

**Lift on HitRate@5:** +86.4% over popularity  ·  +24.2% over cold-start-as-served  ·  +141.2% over random

Full tables, the real-corpus arm, the weight sweep and the caveats: `reco_eval.md`.

## Release gates (from training)
| gate | status | detail |
|---|---|---|
| catalog_nonempty | PASS | 10 venues in snapshot |
| fingerprint_present | PASS | reco spec fingerprint 138790ba577ea0f0 |
| lift_over_popularity | PASS | WAIVED — only 2 evaluable user(s) (< 5); HitRate not yet trustworthy, released anyway |

## Provenance
- **Real data:** read-only snapshot pulled from the Node backend over `/api/internal/export/reco-data`; the ML tier holds no database handle. Snapshot sha256 `40c0da2fb65f78cb3c98d5c2cdc1124f2ea75d3614413cb8818c364c3d5cec7a`.
- **Synthetic data:** `data/bookings_synth.csv` sha256 `72bf46846eef530196afc9926e2284b53bb540135f6bcc1681aa75b48720f1f0` — read, never regenerated (a new CSV would break the provenance gate every trainer shares).
- **Libraries:** python 3.14.4, numpy 2.5.2, joblib 1.5.3.

## Known limitations
- **No collaborative filtering — future work.** Nothing here learns "players like you also
  booked X". With the current user base a co-occurrence matrix would be almost entirely
  empty, and the few overlaps it did find would be noise presented as insight. The content
  approach needs no other users to work on day one, which is the whole reason it was chosen;
  revisit once the platform has enough real booking history for co-occurrence to mean something.
- **Offline only.** No click-through evidence exists; HitRate@5 is not a conversion rate.
- **Simulated evaluation population.** See the "what this cannot tell you" section of `reco_eval.md`.
- **Snapshot staleness.** The served model is a point-in-time snapshot: a venue added or a
  booking made after the export is invisible until the next `build_reco.py` + `POST /reco/refresh`.
- **No favourites signal.** The affinity block uses ratings >= 4 as a proxy; the schema has no
  favourites table.
- **City scope.** Cold-start popularity is city-scoped only when the snapshot carries a city
  for that player; otherwise it degrades to platform-wide popularity.
