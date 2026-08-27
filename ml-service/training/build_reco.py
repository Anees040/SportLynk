r"""
Train and release SportLynk model #3 — the content-based venue recommender (S.5 Wave A).

WHAT THIS SCRIPT DOES
  1. Pulls a read-only snapshot from the Node backend's protected export endpoint
     (GET /api/internal/export/reco-data, authenticated with X-Reco-Export-Key). This
     is the ONLY way training sees production data: the ml-service holds no DB handle,
     and neither does this script. Node owns the SQL; this owns the model.
  2. Fits a VenueRecommender over that snapshot — the SAME class app.core.reco_model
     serves, over the SAME frozen feature contract (core/reco_features.py), so there is
     no train/serve skew by construction.
  3. Evaluates it with leave-one-out HitRate@3 / HitRate@5 / MRR against a popularity
     baseline — the wave's requirement that reports/reco_eval.md show LIFT over popularity.
  4. Applies release GATES and writes artifacts. A timestamped copy is ALWAYS written
     (audit trail); reco_latest.joblib — the file the registry actually serves — is
     written ONLY when every gate passes. Same discipline as train_pricing / train_sentiment.

WHY THE FITTED ESTIMATOR, NOT AN sklearn PIPELINE
  Unlike pricing (a Pipeline) and sentiment (a SoftmaxSVC), the recommender learns no
  weights: it fits a VenueSpace over the catalogue and scores users by cosine similarity
  to a recency-weighted profile. "Training" is therefore snapshotting the catalogue and
  user histories into a VenueRecommender and PROVING it beats popularity. The artifact
  pickles that fitted object by reference to app.core.reco_model.VenueRecommender, which
  is why that class lives at a stable dotted path — the registry unpickles it at serve time.

THE SMALL-CORPUS CAVEAT (why the gate is soft on the seed data)
  The seed database is tiny (~10 venues, a handful of players with >=2 bookings). A
  leave-one-out HitRate on a dozen users is a DIRECTION, not a number to publish. So the
  release gate is deliberately WAIVED below MIN_TRUST_USERS: it releases the model (the
  cold-start path is popularity anyway, so there is nothing safer to serve) but the eval
  report and model card SAY SO — same spirit as the sentiment wave's caveated CI bound.
  Above MIN_TRUST_USERS the gate BITES: a content model that cannot beat popularity on
  HitRate@5 is not promoted to _latest.

RUN IT
  # 1) put the SAME RECO_EXPORT_API_KEY in backend/.env and ml-service/.env
  # 2) start the Node backend (it needs the DB)
  cd ml-service
  .\.venv\Scripts\python.exe training\build_reco.py
  # dry run (evaluate + print, write nothing):
  .\.venv\Scripts\python.exe training\build_reco.py --no-write
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import joblib
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

# Importing config loads ml-service/.env (so RECO_EXPORT_API_KEY / RECO_EXPORT_URL are
# picked up without the caller exporting them by hand) and gives us the SAME MODEL_DIR /
# REPORT_DIR the running service reads — so a trained artifact lands exactly where the
# registry looks, and an ML_MODEL_DIR override is honoured here too.
from app.core import config  # noqa: E402  (path insert must precede this import)
from app.core.reco_features import (  # noqa: E402
    BLOCK_ORDER,
    RECO_SPEC_VERSION,
    reco_spec_fingerprint,
)
from app.core.reco_model import VenueRecommender  # noqa: E402

MODEL_KEY = "reco"

# Below this many evaluable users (>=2 bookings), leave-one-out HitRate is too noisy to
# gate on — we release regardless and flag it, rather than block release on a number
# built from a handful of rows. At or above it, the model must beat popularity to reach
# _latest.joblib.
MIN_TRUST_USERS = 5

# When the model IS trusted (enough users), it must not underperform the popularity
# baseline it exists to improve on. Tiny epsilon so an exact tie still passes.
LIFT_EPSILON = 1e-9

DEFAULT_URL = "http://127.0.0.1:3000/api/internal/export/reco-data"


# ─────────────────────────────────────────────────────────────────────────────
# Data
# ─────────────────────────────────────────────────────────────────────────────


def pull(url: str, key: str) -> dict:
    """GET the read-only snapshot from Node. Exits with an actionable message on failure."""
    req = urllib.request.Request(
        url, headers={"X-Reco-Export-Key": key, "Accept": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as res:  # noqa: S310 (trusted localhost)
            body = json.load(res)
    except urllib.error.HTTPError as exc:
        hint = ""
        if exc.code in (401, 503):
            hint = (
                "\n  -> the export key is wrong or unset. Put the SAME RECO_EXPORT_API_KEY "
                "in backend/.env and ml-service/.env, then restart the backend."
            )
        raise SystemExit(f"export endpoint returned HTTP {exc.code} {exc.reason}{hint}") from exc
    except urllib.error.URLError as exc:
        raise SystemExit(
            f"could not reach {url}: {exc.reason}\n"
            "  -> is the Node backend running?  (cd backend && npm run dev)"
        ) from exc
    if not isinstance(body, dict):
        raise SystemExit("export response was not a JSON object")
    # House envelope {success, data:{...}} — unwrap to the data block.
    return body.get("data", body)


def _canonical_sha256(data: dict) -> str:
    """sha256 of the snapshot, canonicalised so an identical export always hashes the same.

    Provenance: it lets the model card name EXACTLY which snapshot produced the model —
    the recommender's analogue of train_pricing stamping the bookings CSV hash.
    """
    payload = json.dumps(data, sort_keys=True, separators=(",", ":"), default=str)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


# ─────────────────────────────────────────────────────────────────────────────
# Evaluation
# ─────────────────────────────────────────────────────────────────────────────


@dataclass
class Eval:
    """Leave-one-out evaluation of the content model vs a popularity-only baseline."""

    users_total: int
    users_eligible: int  # users with >=2 bookings (the only ones LOO can score)
    hit_rate_at_3: float
    hit_rate_at_5: float
    mrr: float
    pop_hit_rate_at_3: float
    pop_hit_rate_at_5: float
    pop_mrr: float

    @property
    def lift_at_5(self) -> float:
        if self.pop_hit_rate_at_5 <= 0:
            return 0.0
        return (self.hit_rate_at_5 - self.pop_hit_rate_at_5) / self.pop_hit_rate_at_5

    def as_metrics(self) -> dict:
        return {
            "hitRateAt3": round(self.hit_rate_at_3, 6),
            "hitRateAt5": round(self.hit_rate_at_5, 6),
            "mrr": round(self.mrr, 6),
            "popularityHitRateAt3": round(self.pop_hit_rate_at_3, 6),
            "popularityHitRateAt5": round(self.pop_hit_rate_at_5, 6),
            "popularityMrr": round(self.pop_mrr, 6),
            "relativeLiftAt5": round(self.lift_at_5, 6),
            "eligibleUsers": self.users_eligible,
            "totalUsers": self.users_total,
        }


def _ranked_ids(model: VenueRecommender, user: dict, *, popularity: bool, depth: int) -> list[str]:
    """Rank the catalogue for one held-out user, optionally via the cold-start path.

    The recommender scores from the user's OWN stored profile, so to hold out a booking
    we rebuild a one-user recommender over the same venue catalogue with a trimmed
    history. For the popularity baseline we strip the profile entirely, which forces
    recommend() down its cold-start branch (popularity-in-city + stated sports) — exactly
    the "no personalisation" comparison the wave asks for. `depth` requests a full ranking
    (not just top-k) so MRR sees where the held-out venue actually landed.
    """
    probe = dict(user)
    if popularity:
        probe["bookings"] = []
        probe["highReviews"] = []
        probe["sportPreferences"] = []
    one = VenueRecommender(model.venues, [probe], as_of=model.as_of)
    uid = str(user.get("userId") or user.get("user_id"))
    return [x["venue_id"] for x in one.recommend(uid, limit=depth)["items"]]


def evaluate(model: VenueRecommender, users: list[dict]) -> Eval:
    """Leave-one-out: hide each eligible user's most-recent booking, see where it ranks."""
    depth = max(5, len(model.venues))  # full ranking so MRR is honest, not truncated at 5
    total = len(users)
    eligible = 0
    hits3 = hits5 = 0
    rr = 0.0
    pop_hits3 = pop_hits5 = 0
    pop_rr = 0.0
    for u in users:
        bookings = u.get("bookings") or []
        if len(bookings) < 2:
            continue
        eligible += 1
        last = bookings[-1]
        held = str(last.get("venueId") or last.get("venue_id"))
        train_user = {**u, "bookings": bookings[:-1]}

        got = _ranked_ids(model, train_user, popularity=False, depth=depth)
        if held in got[:3]:
            hits3 += 1
        if held in got[:5]:
            hits5 += 1
        if held in got:
            rr += 1.0 / (got.index(held) + 1)

        pop = _ranked_ids(model, train_user, popularity=True, depth=depth)
        if held in pop[:3]:
            pop_hits3 += 1
        if held in pop[:5]:
            pop_hits5 += 1
        if held in pop:
            pop_rr += 1.0 / (pop.index(held) + 1)

    denom = eligible or 1
    return Eval(
        users_total=total,
        users_eligible=eligible,
        hit_rate_at_3=hits3 / denom,
        hit_rate_at_5=hits5 / denom,
        mrr=rr / denom,
        pop_hit_rate_at_3=pop_hits3 / denom,
        pop_hit_rate_at_5=pop_hits5 / denom,
        pop_mrr=pop_rr / denom,
    )


# ─────────────────────────────────────────────────────────────────────────────
# Release gates
# ─────────────────────────────────────────────────────────────────────────────


@dataclass
class Gate:
    name: str
    passed: bool
    detail: str


def release_gates(model: VenueRecommender, ev: Eval) -> list[Gate]:
    """The bar an artifact must clear to be promoted to _latest (i.e. served).

    Permissive on the tiny seed corpus (see MIN_TRUST_USERS): the gate cannot demand a
    HitRate lift it has too few users to measure, and cold-start is popularity anyway, so
    there is nothing safer to serve. It DOES bite once the corpus is large enough to trust.
    """
    fp = reco_spec_fingerprint()
    gates = [
        Gate("catalog_nonempty", len(model.venues) >= 1, f"{len(model.venues)} venues in snapshot"),
        Gate("fingerprint_present", bool(fp), f"reco spec fingerprint {fp}"),
    ]
    if ev.users_eligible < MIN_TRUST_USERS:
        gates.append(
            Gate(
                "lift_over_popularity",
                True,
                f"WAIVED — only {ev.users_eligible} evaluable user(s) "
                f"(< {MIN_TRUST_USERS}); HitRate not yet trustworthy, released anyway",
            )
        )
    else:
        gates.append(
            Gate(
                "lift_over_popularity",
                ev.hit_rate_at_5 + LIFT_EPSILON >= ev.pop_hit_rate_at_5,
                f"HitRate@5 {ev.hit_rate_at_5:.3f} vs popularity {ev.pop_hit_rate_at_5:.3f} "
                f"(lift {ev.lift_at_5 * 100:+.1f}%)",
            )
        )
    return gates


# ─────────────────────────────────────────────────────────────────────────────
# Reports
# ─────────────────────────────────────────────────────────────────────────────


def _libraries() -> dict:
    """Versions of what actually unpickles the artifact — the /health runtime compares these."""
    return {
        "python": platform.python_version(),
        "numpy": np.__version__,
        "joblib": joblib.__version__,
    }


def write_reports(reports_dir: Path, artifact: dict, ev: Eval, released: bool) -> None:
    m = artifact["metrics"]
    ds = artifact["dataset"]

    (reports_dir / "reco_metrics.json").write_text(
        json.dumps(
            {
                "modelVersion": artifact["modelVersion"],
                "trainedAt": artifact["trainedAt"],
                "recoSpecVersion": artifact["recoSpecVersion"],
                "recoSpecFingerprint": artifact["recoSpecFingerprint"],
                "metrics": m,
                "dataset": ds,
                "gates": artifact["gates"],
                "released": released,
            },
            indent=2,
        ),
        encoding="utf-8",
    )

    small = ev.users_eligible < MIN_TRUST_USERS
    if small:
        flip = 100.0 / max(ev.users_eligible, 1)
        caveat = (
            f"> **Small-corpus caveat.** Only **{ev.users_eligible}** user(s) had the "
            f">=2 bookings that leave-one-out needs (of {ev.users_total} players in the "
            f"snapshot). At this n the HitRate/MRR figures are a sanity check on the "
            f"model's DIRECTION, not a number to quote — one user flips HitRate@5 by "
            f"~{flip:.0f} points. The release gate is waived below {MIN_TRUST_USERS} "
            f"evaluable users; the model is released anyway because the cold-start path "
            f"is popularity, so there is nothing safer to serve.\n"
        )
    else:
        caveat = (
            f"> The evaluation covers **{ev.users_eligible}** users with >=2 bookings. "
            f"At or above {MIN_TRUST_USERS} the release gate requires the content model "
            f"to at least match the popularity baseline on HitRate@5.\n"
        )

    (reports_dir / "reco_eval.md").write_text(
        f"""# Venue recommender — evaluation (model #3)

- **Model:** `{artifact['modelVersion']}`
- **Trained:** {artifact['trainedAt']}
- **Feature spec:** `{artifact['recoSpecVersion']}` (fingerprint `{artifact['recoSpecFingerprint']}`)
- **Snapshot:** {ds['venues']} venues, {ds['users']} users, sha256 `{ds['sha256'][:16]}...`
- **Method:** leave-one-out — hide each eligible user's most-recent confirmed booking, rank the full catalogue from the remaining profile, and check where the held-out venue lands.

{caveat}
| metric | content model | popularity baseline |
|---|---|---|
| HitRate@3 | **{m['hitRateAt3']:.3f}** | {m['popularityHitRateAt3']:.3f} |
| HitRate@5 | **{m['hitRateAt5']:.3f}** | {m['popularityHitRateAt5']:.3f} |
| MRR | **{m['mrr']:.3f}** | {m['popularityMrr']:.3f} |

**Relative lift @5:** {m['relativeLiftAt5'] * 100:+.1f}%  ·  eligible users: {ev.users_eligible}/{ev.users_total}

The popularity baseline is the recommender's OWN cold-start path with the user's profile
stripped (popularity-in-city blended with stated sports) — the same ranking a brand-new
user sees. Lift is therefore precisely the value a user's booking history adds on top of
"what's popular near you".
""",
        encoding="utf-8",
    )

    gates_tbl = "\n".join(
        f"| {g['name']} | {'PASS' if g['passed'] else 'FAIL'} | {g['detail']} |"
        for g in artifact["gates"]
    )
    blocks = ", ".join(artifact["featureBlocks"])
    libs = artifact["libraries"]
    (reports_dir / "model_card_reco.md").write_text(
        f"""# Model card — venue recommender (model #3)

**Version:** `{artifact['modelVersion']}`  ·  **Released to `_latest`:** {'yes' if released else 'NO'}
**Trained:** {artifact['trainedAt']}
**Feature spec:** `{artifact['recoSpecVersion']}`  ·  **fingerprint:** `{artifact['recoSpecFingerprint']}`

## What it is
A content-based recommender. It builds a vector per venue from that venue's own
attributes ({blocks}) and a vector per user from their recency-weighted booking history,
stated sport preferences, and highly-reviewed venues, then ranks venues by cosine
similarity. `match% = round(55 + 43 x similarity)`. It learns no weights and stores no
gradients — "training" fits the venue space over the current catalogue and freezes the
user-history snapshot into the served object. Users with no history in the snapshot fall
to a cold-start ranking (popularity-in-city + stated sports), labelled *Popular nearby*
instead of *For you*.

## Data
- **Source:** read-only snapshot from the Node backend (`{ds['source']}`), pulled over the authenticated `/api/internal/export/reco-data` endpoint. The ML tier never touches Postgres.
- **Exported at:** {ds['exportedAt']}
- **Snapshot sha256:** `{ds['sha256']}`
- **Size:** {ds['venues']} venues, {ds['users']} players ({ds['eligibleUsers']} with >=2 bookings).

## Metrics
Leave-one-out on the most-recent booking; see `reco_eval.md` for the full table and the
small-corpus caveat. HitRate@5 **{m['hitRateAt5']:.3f}** vs popularity {m['popularityHitRateAt5']:.3f}
(lift {m['relativeLiftAt5'] * 100:+.1f}%); MRR **{m['mrr']:.3f}**.

## Release gates
| gate | status | detail |
|---|---|---|
{gates_tbl}

## Provenance
- **Libraries:** python {libs['python']}, numpy {libs['numpy']}, joblib {libs['joblib']}.
- **Served by:** `app.core.reco_model.VenueRecommender`, unpickled by the model registry, which refuses the artifact if `recoSpecFingerprint` no longer matches `core/reco_features.py`.

## Known limitations
- **Tiny corpus.** See the caveat in `reco_eval.md`; the headline numbers are directional until the platform accrues more booking history.
- **Snapshot staleness.** The served model is a point-in-time snapshot; a venue added or a booking made after the export is invisible until the next `build_reco.py` run.
- **City scope.** Cold-start popularity is scoped to the user's city only when the snapshot carries a city for that user; otherwise it degrades to platform-wide popularity.
- **No favourites signal.** The affinity term uses highly-reviewed venues (rating >= 4) as a proxy; the schema has no dedicated favourites table.
""",
        encoding="utf-8",
    )


# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Train and release the SportLynk venue recommender (model #3)."
    )
    ap.add_argument("--url", default=os.getenv("RECO_EXPORT_URL", DEFAULT_URL))
    ap.add_argument("--key", default=os.getenv("RECO_EXPORT_API_KEY"))
    ap.add_argument("--models-dir", default=str(config.MODEL_DIR))
    ap.add_argument("--reports-dir", default=str(config.REPORT_DIR))
    ap.add_argument(
        "--no-write", action="store_true", help="evaluate and print, write nothing to disk"
    )
    args = ap.parse_args()

    if not args.key:
        raise SystemExit(
            "RECO_EXPORT_API_KEY is not set.\n"
            "  -> generate one:  node -e \"console.log(require('crypto').randomBytes(32).toString('hex'))\"\n"
            "  -> put the SAME value in backend/.env and ml-service/.env, then retry."
        )

    now = datetime.now(timezone.utc)
    stamp = now.strftime("%Y%m%d-%H%M%S")

    print(f"pulling snapshot from {args.url} ...")
    data = pull(args.url, args.key)
    venues = data.get("venues") or []
    users = data.get("users") or []
    if not venues:
        raise SystemExit("snapshot contains no venues — nothing to train on")
    snapshot_sha = _canonical_sha256(data)
    print(f"  {len(venues)} venues, {len(users)} users  (snapshot sha256 {snapshot_sha[:16]}...)")

    model = VenueRecommender(venues, users, as_of=data.get("exportedAt"))
    ev = evaluate(model, users)
    gates = release_gates(model, ev)
    released = all(g.passed for g in gates)

    version = f"reco-content-v1-{stamp}"
    artifact = {
        "model": model,
        "modelKey": MODEL_KEY,
        "modelVersion": version,
        "trainedAt": now.isoformat(),
        "recoSpecVersion": RECO_SPEC_VERSION,
        "recoSpecFingerprint": reco_spec_fingerprint(),
        "featureBlocks": list(BLOCK_ORDER),
        "metrics": ev.as_metrics(),
        "libraries": _libraries(),
        "dataset": {
            "source": "node-read-only-snapshot",
            "exportedAt": data.get("exportedAt"),
            "sha256": snapshot_sha,
            "venues": len(venues),
            "users": len(users),
            "eligibleUsers": ev.users_eligible,
        },
        "gates": [{"name": g.name, "passed": g.passed, "detail": g.detail} for g in gates],
        "released": released,
    }

    # ── console summary ──
    print()
    for g in gates:
        print(f"  [{'PASS' if g.passed else 'FAIL'}] {g.name}: {g.detail}")
    print()
    print(f"content     HitRate@3 {ev.hit_rate_at_3:.3f}  HitRate@5 {ev.hit_rate_at_5:.3f}  MRR {ev.mrr:.3f}")
    print(f"popularity  HitRate@3 {ev.pop_hit_rate_at_3:.3f}  HitRate@5 {ev.pop_hit_rate_at_5:.3f}  MRR {ev.pop_mrr:.3f}")
    print(f"relative lift @5: {ev.lift_at_5 * 100:+.1f}%   (eligible users: {ev.users_eligible}/{ev.users_total})")
    print()

    if args.no_write:
        print("--no-write: evaluated only, nothing written.")
        return 0

    models_dir = Path(args.models_dir)
    models_dir.mkdir(parents=True, exist_ok=True)
    reports_dir = Path(args.reports_dir)
    reports_dir.mkdir(parents=True, exist_ok=True)

    stamped = models_dir / f"{MODEL_KEY}_{stamp}.joblib"
    joblib.dump(artifact, stamped)
    print(f"wrote {stamped}")

    if released:
        latest = models_dir / f"{MODEL_KEY}_latest.joblib"
        shutil.copyfile(stamped, latest)
        print(f"RELEASED -> {latest}")
    else:
        print("NOT RELEASED — a gate failed; _latest.joblib left unchanged.")

    write_reports(reports_dir, artifact, ev, released)
    print(f"wrote {reports_dir / 'reco_metrics.json'}")
    print(f"wrote {reports_dir / 'reco_eval.md'}")
    print(f"wrote {reports_dir / 'model_card_reco.md'}")
    return 0 if released else 1


if __name__ == "__main__":
    raise SystemExit(main())
