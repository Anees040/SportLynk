# CLAUDE.md — SportLynk (FYP sprint)

## Project
Sports venue booking + team matchmaking app for Pakistan. Flutter (Android-first)
+ Node/Express + PostgreSQL on Supabase + (from S.3) Python FastAPI ml-service
with scikit-learn models. Final-year project: the committee requires GENUINELY
trained ML models — never replace them with external AI API calls.

## Run
- Backend: `cd backend && npm install && node src/server.js` → GET /api/health.
  Env in backend/.env (see .env.example). `.env` is gitignored and MUST stay so —
  it holds the DB password and the JWT signing secret.
- DB: Supabase is the ONLY database (dev + demo). DATABASE_URL = session-pooler
  URI; `?sslmode=require` is optional — pool.js strips `sslmode` before pg parses
  it, because pg 8.20 reads `require` as `verify-full`, which OVERRIDES
  rejectUnauthorized:false → "self-signed certificate in certificate chain".
- App: `flutter pub get` → `adb reverse tcp:3000 tcp:3000` →
  `flutter run --dart-define=API_BASE_URL=http://127.0.0.1:3000/api`
  (emulator: http://10.0.2.2:3000/api). A PHYSICAL phone ALWAYS needs the
  --dart-define set to the laptop's LAN IP; the 10.0.2.2 default is emulator-only.
- ml-service: `cd ml-service && python -m uvicorn app.main:app` — binds
  127.0.0.1:8000, X-API-Key auth. Loads models/pricing_latest.joblib ONCE at boot;
  a retrain does NOT hot-swap (restart uvicorn). The phone NEVER calls it — only Node does.

## Golden rules
1. Implement ONLY the wave pasted in the prompt. No unrequested refactors,
   renames, dependency bumps, or schema "improvements".
2. Schema changes ONLY via backend/migrations/0XX_*.sql + runner script
   (follow the existing pattern).
3. Business policy source of truth (SRS): deposit = 20% of price; cancellation
   window = 24h (≥24h before slot: full refund; <24h: 80% back, 20% to owner);
   no-show auto-forfeits 30 min after slot start; escrow = full price frozen at
   booking, transferred to owner on QR check-in. Where code disagrees, the CODE
   is wrong.
4. Money math inside SQL transactions with FOR UPDATE. Store timestamps UTC;
   convert to PKT only in Flutter.
5. API errors always { success:false, message } — never leak SQL/stack traces.
6. pg returns DECIMAL as strings — parse with asNum() before math or
   toStringAsFixed.
7. Done per wave: app waves → flutter analyze = 0; backend waves → server boots
   clean. Then STOP and report — do not start the next wave.

## Security (persistent — do not violate)
- ML_API_KEY must be byte-identical in backend/.env and ml-service/.env; compare by
  the /health apiKeyFingerprint (sha256[:8]) — NEVER print, log, or commit the key.
  The dev value was pasted in cleartext in an early session (inert: binds 127.0.0.1,
  gates nothing user-facing) — ROTATE both files before S.7 puts ml-service on a public URL.
- Do NOT re-run training/generate_bookings.py: a new CSV = a new sha256, and the
  provenance gate then fails every training run until bookings_meta.json is reconciled.
  data/bookings_synth.csv is validated at sha256 `72bf468…8720f1f0`.
- generate_bookings.py must NOT touch the DB and must NOT import from app/routers/.

## Status
S.1, S.2 (A–D) and S.3 (A–E) are all code-complete. The ML tier is live end to end:
model #1 (dynamic pricing) is trained, gated, served, and on the owner's screen with
real confidence + a 72h demand chart, plus a reproducibility/evidence pack.
- Model: `pricing-v1-20260825-0041`, HistGradientBoostingClassifier, 374 KB, 12/12
  release gates. Binary classifier P(booked | features, price) — price is an INPUT
  (price_ratio), so one model serves BOTH the 72h forecast (ratio=1.0) and the price
  suggestion (argmax(price × P(book)) = expected revenue, never argmax of probability).
  ROC-AUC 0.7628 = 98.2% of the MEASURED 0.7770 Bayes ceiling; Brier 0.1680, skill 0.1668.
- Reproduce: `cd ml-service && python training/train_pricing.py --seed 42` — 42 is
  DEFAULT_SEED, so that exact command produced the served artifact, bit-for-bit, in ~68s.
- OPEN at end of S.3, in order:
  - `tag s3-done` — needs a commit; NOTHING is committed yet. Do not commit unless asked.
  - judge reports/demand_patterns.png — Wave B's last human gate (owner's domain verdict
    on the curves; the Jummah dip is new supporting evidence).
  - no live authenticated HTTP test of the two Node owner routes (TESTING.md §4.8 test 87
    — another owner's venue id → 404, never a suggestion — must not be skipped).
  - npm test / verify_schema.js / run_match_flow_check.js not re-run since S2-C (no schema,
    ELO, or match change since) — expected untouched, not measured.
  - re-estimate elasticity from real bookings once data exists (pipeline is validated;
    ELASTICITY_PEAK 0.85 / OFFPEAK 2.20 are stated assumptions, not estimates).
- NEXT: S.4 sentiment + trust → S.5 recommender → S.6 NLU assistant → S.7
  tournaments/chat/admin dispute-UI/demo pack + deploy ml-service as a 2nd Render service.

## Wave log (one entry per completed wave: what shipped · the gotcha · verified)
- S1-A — escrow ledger unified (20% deposit / 24h window / 30-min no-show); escrow.js +
  notify.js, migration 010, noShowJob rewritten + autoApproveJob added.
- S1-B — checkout slot locks (migration 011: slots.locked_by/locked_until, POST+DELETE
  /api/slots/:id/lock, 5-min TTL, LAZY expiry no sweep, Blue "held" in grids, 30s refresh).
- S1-C — backend hardening: rateLimit.js (100/min user, 20/min anon IP, health exempt),
  morgan, JSON envelope on unknown routes + malformed JSON (were HTML/500), migration 012 indexes.
- S1-D — FYP-2 schema, migration 013: 12 tables for S.2–S.7 + columns + 14 indexes. Spec's
  int keys → UUID (all PKs are UUID); notifications ALTERed not recreated. NOT added:
  users.suspended (is_active is the flag, auth.js:164) / notifications.read (is_read).
  Deleted dead src/controllers/. global_settings seeded but wired to nothing; escrow.js is money truth.
- S1-F — client plumbing: central ApiClient (JWT + readable errors, 45s→10s timeout),
  num_util asNum() replaced 11 parsers. Migration 014 withdrawals (the one exception past 013;
  one-pending = PARTIAL UNIQUE INDEX 23505→409; money leaves at REQUEST time). Shared txn sheets
  fixed live label/icon + PKT .toLocal() bugs. SL_TEST_* env demoes timed rules in 1 min (timings only).
- S1-E — cloud demo deploy. api_constants baseUrl → --dart-define or 10.0.2.2 (phone needs the
  define). pool.js TLS also from sslmode/host; seed_venues fixed (wrong dir + its own Pool);
  Supabase is only DB so deploy step VERIFIES, never re-runs schema. trust proxy=1 behind Render.
  DEPLOY_GUIDE.md + S1_ACCEPTANCE.md. Render free tier sleeps (~30-50s cold, sweeps stop asleep).
- post-E/F fixes (first run vs REAL Supabase) — `?sslmode=require` BROKE connect (stripSslMode);
  seed_venues stranded PKR 11,100 escrow (now releases with a refund row first; reconcile_wallets.js
  repairs, dry-run default); /wallet/frozen itemises escrow_held not total_amount; add_future_slots.js
  (all slots were PAST → nothing bookable) created 2,100 / 1,990 bookable. analyze 0.
- S2-A — teams (create/roster/invites/roles/join) + WhatsApp-style group chat. migration 015
  (ux_teams_name_sport, chat_channel_members, chat_messages media/reply cols, reactions,
  last_seen_at + backfill). team_members.role is captaincy authority (NOT teams.captain_id — >1
  captain allowed). Invite tokens hashed sha256, single-use FOR UPDATE. routes/teams.js (16 eps)
  + chat.js (7 eps): BEGIN→work→COMMIT, authority re-read inside the locked txn. Socket.IO rooms
  u:/c:, ticks = 2 watermarks (MIN across others). Voice notes + reply-to DEFERRED (schema ready).
- S2-B — ELO engine + global settings. utils/elo.js has NO db import (provable; applyResult takes
  a client so it runs in the caller's txn). A verified result writes both elos + W/L/D + 2
  elo_history rows netting to zero. Team Unranked until ≥1 verified match (ranked:false, never seed
  1000). globalSettings.js caches global_settings, never throws, falls to DEFAULTS. test/elo.test.js
  10/10 (writing them found a real 42P08 shared-placeholder bug).
- S2-C — matchmaking end to end. migration 016 (25/25 verify): ux_matches_booking_live PARTIAL
  unique (one live match/booking), one-submission-per-team, chk_matches_status. routes/matches.js
  (11 eps): body never authority (team re-read from team_members in the locked txn), lock-then-decide,
  emit after COMMIT. Competitiveness snapshotted, NULL when either unranked. matchPreview.js = template
  NLG, server ships previewLabel:'Preview'. Conflicting submits → disputed + SYSTEM dispute (raised_by
  NULL). >30% over ≥3 → rating frozen platform-wide (match still records W/L, no points move).
  run_match_flow_check.js 69/69 over real HTTP (and it seeds the two-team fixture).
- S2-D — rankings, team stats, ELO history chart. ZERO schema. teamStats.js 3 reads. /rankings is
  ranked-only (RANKED_MIN_MATCHES bound as a query param). Rank movement COMPUTED from elo_history
  (no snapshot table; movement NULL≠0). is_mine answered by the SERVER. /teams/:id gained
  stats+eloHistory in the existing read (still ONE request). eloSeries drives off matches LEFT JOIN
  elo_history (disputed has no history row). fl_chart ^0.69.0 (the one new dep; compiles on 0.69 AND
  1.x). Fixed PATCH /teams/:id silently dropping city. VERIFIED analyze 0; backend read-verified only
  (shell refused — those 4 baseline checks are in the user's manual-steps list).
- S3-A — ML tier scaffold: ml-service/ (FastAPI :8000) + mlClient.js. NO MODEL — ships the contract,
  the trust boundary and the degradation path. features.py IS the deliverable (11 features, order
  frozen, FEATURE_SPEC_VERSION stamped + re-checked at load → mismatch = 503). venue_id EXCLUDED (cold
  start is our common case); venue_rating nullable → NaN never 0. main.py SystemExit 78 without
  ML_API_KEY at import; hmac.compare_digest; binds 127.0.0.1, no CORS. ml-service has NO heuristic (503)
  — the heuristic lives in mlClient.js so the source label can't lie. Circuit breaker 3 fails→30s;
  forecastDemand has NO fallback (available:false). GET /features/spec lets check_ml_service.js assert
  Node's peak/band copies match Python. VERIFIED 37/37, 0 skipped; the two .env fingerprints matched.
- S3-B — synthetic training corpus (RAN GREEN 12/12 on 81,395 rows). pk_calendar.py (stdlib, dates
  labelled [GAZETTED]/[OBSERVED]/[ESTIMATE]), generate_bookings.py, demand_plots.py. Built on LOG-ODDS
  (multiplied probabilities would clip to 1.0 and kill elasticity at peak). price_ratio sampled
  INDEPENDENTLY (else the revenue maximiser pins to the ceiling forever — the identification trap).
  6 documented departures from the prompt (Friday≠weekend + Jummah dip; Eid EMPTIES turfs; bimodal
  seasonality; Ramadan is a phase-of-clock effect). Elasticity ASYMMETRIC 0.85 peak / 2.20 off-peak.
  csv_sha256 recorded in bookings_meta.json. demand_patterns.png is a HUMAN GATE (still open).
  Reproduce: `--seed 42 --start 2025-08-01 --days 365`.
- S3-C — pricing model #1 (train_pricing.py; GREEN after 3 runs). Time-split on slot_date (strictly
  stronger than an as_of split — both asserted mechanically, fails the run not warns). CEILING measured
  from latent_p turns "AUC>0.80" into an attainment %. 12 RELEASE GATES (not metrics): baseline price
  coef MUST be negative; MONOTONE price across 24 profiles; CSV sha must match bookings_meta.json. Two
  viva lessons: (1) HGB needs monotonic_cst={'price_ratio':-1} — a tree fits a rising step from noise
  silently — which needs set_output('pandas') + verbose_feature_names_out=False; (2) the monotone gate
  was SILENTLY under-covering at 16 profiles while 3 docs said 24 (dedup overlap, no backfill) → fixed
  to 6-venue coverage. The +23.96% uplift is a THEOREM not a finding (ELASTICITY_PEAK 0.85<1 ⇒ revenue
  rises to the cap) and is MODELLED, not measured. Skew-gate tolerance DERIVED from the "%.6g" serialiser
  (1e-5). Result pricing-v1-20260825-0041, 12/12.
- S3-D — serving the model to the owner's screen (VERIFIED 60/60 up, 31/31+4 skipped down, analyze 0).
  501 is GONE — /predict/price + /predict/demand run inference. Endpoint names keep the Wave-A frozen
  contract (override the prompt's /pricing/*). Deleted the hardcoded 92% CONFIDENCE → DERIVED confidence =
  identification(revenue-peak sharpness) × boundary(0.85 when optimum on band edge) × attainment(rocAuc/
  ceiling), clamp [0.05,0.95]. top_factors = per-request counterfactual occlusion (venue_rating/sport/city
  occluded as unattributable venue proxies — a 27-line evidence comment). Caption reads the artifact (AUC
  0.76 · 98% of ceiling), not the prompt's fake 0.84. ttlCache.js 1h (only source='model' cached — else a
  blink = 60-min heuristic; in-flight dedupe; invalidatePrefix on Apply). DEMAND_BASE_RATE gated to
  metrics.test.baseRate 0.280109. Fixed demandLevel(null)→'low' bug (Number(null)===0). Apply sheet
  enforces FR4.17 in 3 places; server re-enforces every rule inside the txn.
- S3-E — evidence pack + reproducibility demo (VERIFIED 20/20 required, retrain bit-for-bit, analyze 0).
  No model/endpoint/screen change; features.py + joblib byte-identical. `--seed 42` retrains identically
  twice into scratch (rocAuc 0.762774…, ~68s). print_metrics_table() adds a 3-column table (logistic ·
  THIS MODEL · measured ceiling) through shout so --quiet can't hide it. Deleted a stale 501 line from the
  success message + added the DOES-NOT-HOT-SWAP warning. check_price_sanity.js = 20 required checks through
  mlClient (NOT curl): Fri 20:00 PKR 2600 / P(book) 0.6257 > Tue 03:00 PKR 1600 / 0.2248; source:'heuristic'
  is a HARD FAILURE; rating gate is WEAK (hi≥lo — the +30% cap pins both at peak); demand curve MEASURED
  FROM forecastDemand not suggestPrice (the transferable bug — a comparison is valid only if exactly one
  thing varies). Finding: low<high rating holds only where the guardrail leaves room (off-peak gaps are
  noise → [OBSERVE], never tests). The Jummah dip survived training into a served forecast. Writes
  reports/price_sanity.json.

## Docs
- PROGRESS.md = historical changelog, append per wave (the detailed rationale for a viva;
  read on demand, not every session). API.md / DATABASE.md = refresh at milestone end.
- TESTING.md = the QA guide: preflight gates, per-wave feature steps, the adversarial/security
  suite, data-integrity SQL, and the Definition of Done. Add this wave's feature steps + any new
  security case when a wave lands, and keep the green-numbers baseline (analyze 0 · npm test ·
  verify_schema · run_match_flow_check) in the commit message.
- Known-stale docs, fix only when touched: README deposit wording ("full deposit"), any
  12h-cancellation references.
- Doc cadence going forward (keep it tight): CLAUDE.md ≈ one wave-log line per wave; PROGRESS.md
  ≈ 30 lines per wave. The full retelling is a cost paid every session — write the relevant thing.
