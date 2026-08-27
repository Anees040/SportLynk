# Model card — venue recommender (model #3)

**Version:** `reco-content-v1-20260827-090526`  ·  **Released to `_latest`:** yes
**Trained:** 2026-08-27T09:05:26.936208+00:00
**Feature spec:** `reco-features-v1`  ·  **fingerprint:** `138790ba577ea0f0`

## What it is
A content-based recommender. It builds a vector per venue from that venue's own
attributes (sport, price_bucket, rating, amenities, zone, indoor_outdoor) and a vector per user from their recency-weighted booking history,
stated sport preferences, and highly-reviewed venues, then ranks venues by cosine
similarity. `match% = round(55 + 43 x similarity)`. It learns no weights and stores no
gradients — "training" fits the venue space over the current catalogue and freezes the
user-history snapshot into the served object. Users with no history in the snapshot fall
to a cold-start ranking (popularity-in-city + stated sports), labelled *Popular nearby*
instead of *For you*.

## Data
- **Source:** read-only snapshot from the Node backend (`node-read-only-snapshot`), pulled over the authenticated `/api/internal/export/reco-data` endpoint. The ML tier never touches Postgres.
- **Exported at:** 2026-08-27T09:05:28.464Z
- **Snapshot sha256:** `2a0d3aba33dcb5de6aa5253da363786bcb15a86616796a2d783f995663e6f3b4`
- **Size:** 10 venues, 8 players (2 with >=2 bookings).

## Metrics
Leave-one-out on the most-recent booking; see `reco_eval.md` for the full table and the
small-corpus caveat. HitRate@5 **1.000** vs popularity 1.000
(lift +0.0%); MRR **1.000**.

## Release gates
| gate | status | detail |
|---|---|---|
| catalog_nonempty | PASS | 10 venues in snapshot |
| fingerprint_present | PASS | reco spec fingerprint 138790ba577ea0f0 |
| lift_over_popularity | PASS | WAIVED — only 2 evaluable user(s) (< 5); HitRate not yet trustworthy, released anyway |

## Provenance
- **Libraries:** python 3.14.4, numpy 2.5.2, joblib 1.5.3.
- **Served by:** `app.core.reco_model.VenueRecommender`, unpickled by the model registry, which refuses the artifact if `recoSpecFingerprint` no longer matches `core/reco_features.py`.

## Known limitations
- **Tiny corpus.** See the caveat in `reco_eval.md`; the headline numbers are directional until the platform accrues more booking history.
- **Snapshot staleness.** The served model is a point-in-time snapshot; a venue added or a booking made after the export is invisible until the next `build_reco.py` run.
- **City scope.** Cold-start popularity is scoped to the user's city only when the snapshot carries a city for that user; otherwise it degrades to platform-wide popularity.
- **No favourites signal.** The affinity term uses highly-reviewed venues (rating >= 4) as a proxy; the schema has no dedicated favourites table.
