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
- ml-service: `cd ml-service && python -m uvicorn app.main:app` — binds 127.0.0.1:8000,
  X-API-Key auth. Loads BOTH models/*_latest.joblib (pricing, sentiment) ONCE at boot;
  a retrain does NOT hot-swap (restart uvicorn, or registry.reload('<key>')). /health
  reports a models[] array so one bad artifact degrades one entry, not the whole report.
  The phone NEVER calls it — only Node does.

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
S.1, S.2 (A–D), S.3 (A–E) and S.4 (A–D) are all code-complete. The ML tier is live end to
end: model #1 (dynamic pricing) is trained, gated, served, and on the owner's screen with
real confidence + a 72h demand chart, plus a reproducibility/evidence pack. Model #2
(sentiment) is trained, gated, served, and — as of S4-C — called by Node: every review with
text is scored by the classifier live at write time (backfill job for the rest).
- Model: `pricing-v1-20260825-0041`, HistGradientBoostingClassifier, 374 KB, 12/12
  release gates. Binary classifier P(booked | features, price) — price is an INPUT
  (price_ratio), so one model serves BOTH the 72h forecast (ratio=1.0) and the price
  suggestion (argmax(price × P(book)) = expected revenue, never argmax of probability).
  ROC-AUC 0.7628 = 98.2% of the MEASURED 0.7770 Bayes ceiling; Brier 0.1680, skill 0.1668.
- Reproduce: `cd ml-service && python training/train_pricing.py --seed 42` — 42 is
  DEFAULT_SEED, so that exact command produced the served artifact, bit-for-bit, in ~68s.
- Model #2: `sentiment-wordchar-linsvc-softmax-20260826-1306`, LinearSVC(C=0.1) over a
  word ∪ char_wb TF-IDF union, 2.9 MB, 7/7 gates. 3-class (negative/neutral/positive) on
  RAW text — normalisation lives INSIDE the pipeline (`app/core/text_norm.py`, the ◆
  contract, imported by builder + trainer + router). Exam (`domain_test_200.csv`) accuracy
  0.8250, macro-F1 0.8247, 95% CI [0.7700, 0.8750] vs a 0.3400 majority baseline; the
  4,281-row validation split reads LOWER (0.6447) because it is 97% third-party
  open-domain text — the model is specialised, and both numbers are published.
  predict_proba = softmax(decision_function), declared UNCALIBRATED in the artifact.
  FR9.10 abuse flag = 32-term lexicon OR P(negative) ≥ 0.70, threshold MEASURED and read
  back from the artifact (a hardcoded 0.90 silently near-died when C moved 3.0 → 0.1 —
  softmax sharpness tracks margin width, so no absolute probability threshold is portable
  across retrains). Reproduce: `python training/train_sentiment.py` — no flags; the
  defaults ARE the shipped configuration. Re-tuning C requires re-measuring the threshold.
- OPEN at end of S.4, in order:
  - **live two-device E2E + backend smoke + seed run** (TESTING.md §4.13) — S4-D is
    code-complete and `flutter analyze` is 0, but the emulator run (rate → sentiment chip →
    abusive → admin queue → hide → two trust gauges move) + `npm start` boot + the 2 curl
    smokes + `seed_reviews_demo.js` were not executed this wave (code-execution classifier
    was down); they are the user's run-on-device steps, mapped turn-key in §4.13.
  - second-annotator κ on `domain_test_200.csv` — 200 rows are single-annotator; the one
    criticism of the 0.8250 headline that no gate can answer.
- OPEN at end of S.3, still open:
  - `tag s3-done` — needs a commit; NOTHING is committed yet. Do not commit unless asked.
  - judge reports/demand_patterns.png — Wave B's last human gate (owner's domain verdict
    on the curves; the Jummah dip is new supporting evidence).
  - no live authenticated HTTP test of the two Node owner routes (TESTING.md §4.8 test 87
    — another owner's venue id → 404, never a suggestion — must not be skipped).
  - npm test / verify_schema.js / run_match_flow_check.js not re-run since S2-C (no schema,
    ELO, or match change since) — expected untouched, not measured.
  - re-estimate elasticity from real bookings once data exists (pipeline is validated;
    ELASTICITY_PEAK 0.85 / OFFPEAK 2.20 are stated assumptions, not estimates).
- NEXT: wire sentiment into Node (S.4 trust/reviews) → S.5 recommender → S.6 NLU assistant
  → S.7 tournaments/chat/admin dispute-UI/demo pack + deploy ml-service as a 2nd Render
  service.

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
- S4-A — sentiment exam + corpus + the ◆ normalisation contract (NO model, deliberately: the measuring
  instrument ships BEFORE the classifier so the target can't be moved to meet a score). domain_test_200.csv
  = 200 hand-written/hand-labelled venue reviews (68/67/65), sha-locked in domain_test_meta.json and
  re-checked every training run; NEVER "fix" a row because the model got it wrong. text_norm.py is the
  2nd frozen contract and needs MORE than features.py's version string, because a FunctionTransformer
  pickles callables BY REFERENCE — editing prep_word after release silently changes how every shipped
  artifact normalises, with no mismatch and no exception → NORM_SPEC_VERSION + a source FINGERPRINT
  (b96e65df85f9692b) stamped into corpus meta AND every artifact, gate-compared, published by
  /sentiment/spec. train.csv 21,405 rows (RUSA 11,719 + TweetEval 8,996 + authored 690), sha256
  408b4c52…a068. TweetEval SAMPLED 3,000/label from 45,615 — taken whole, 45k English swamps 12k Roman
  Urdu and LANGUAGE becomes a proxy for LABEL (Cramér's V 0.1334 source~label / 0.1298 lang~label is the
  check that it didn't; χ² + effect size, deliberately no p-value — at n=21,405 significance is free).
  690 authored rows = 3% of corpus, up-weighted ×40 (only rows from the target distribution). Arithmetic
  reconciles: 21,957 − 539 dups − 12 empty − 1 exam near-dup = 21,405. .gitignore uses
  data/sentiment/* NOT sentiment/ — a directory ignore stops git descending and makes every ! line dead.
- S4-B — model #2 trained, gated, served (VERIFIED 7/7 gates, 49/49 smoke, 7 endpoints, /health both
  models). sentiment-wordchar-linsvc-softmax-20260826-1306, LinearSVC(C=0.1) on word(1-2, \S+) ∪
  char_wb(2-6), 2.9 MB. Exam 0.8250 / macro-F1 0.8247 / CI [0.7700, 0.8750] vs baseline 0.3400 — and the
  CI LOWER BOUND IS BELOW 0.80, published rather than hidden. Validation split reads LOWER (0.6447): it's
  97% third-party open-domain text, so the model is SPECIALISED and both numbers ship. predict_proba =
  softmax(decision_function) via SoftmaxSVC ⇒ argmax(proba) == predict EXACTLY (classScores can't
  contradict its own label); declared calibrated:false — these are ranked margins, not probabilities.
  BOTH branches ship because char_wb pads each word separately and CANNOT cross a word boundary, so
  Roman Urdu post-posed negation ("acha nahi tha") is unrepresentable in char — only prep_word's _neg
  scoping expresses it; an earlier char-only run outscored word+char and nearly settled it wrongly (C was
  tuned for ~50k features, the union is ~100k). ablation_exam_accuracy is NOT a config comparison — all
  rows are train-split-only at the shipped C, hence word+char 0.8100 there vs 0.8250 refit on full.
  The C sweep's hidden cost: softmax sharpness tracks margin width tracks C, so 3.0 → 0.1 moved max
  P(negative) 0.9811 → 0.9234 and a hardcoded 0.90 abuse threshold near-died while accuracy IMPROVED —
  no error, no warning. FR9.10 now = 32-term lexicon OR P(neg) ≥ 0.70, MEASURED, stored in the artifact
  and read back at serve time (MIN_NEG_THRESHOLD 0.50 floors it); 18/200 exam rows escalate. en 0.7600
  (38/50) is the weakest language row and the cause is NOT claimed (n=50, inside noise). 20-row error
  table lives INSIDE sentiment_metrics.json. Near-miss: the trainer first wrote a bare
  confusion_matrix.png — the name S.5 would reuse, in a COMMITTED dir, losing the evidence with no error;
  S3-E predicted exactly this and the convention caught it → confusion_matrix_sentiment.png. NOT DONE:
  no Node route calls the model (columns exist, endpoints exist, nothing joins them).
- S4-C — reviews backend + Trust Score 2.0 + sentiment wired LIVE + price cold-start fixed (VERIFIED:
  migration 017 clean+idempotent, schema 113/113, check_ml_service 71/71, backend boots clean; real
  Supabase, 16 users / 22 bookings / 0 reviews). Closes S4-B's open item — review text is scored at
  write time (score=+0.8238, source='model'). routes/reviews.js = 4 eps mounted at BARE /api with
  per-route auth (a router.use(auth) at /api would 401 /api/auth/login). Opponent reviews are
  CAPTAIN-TO-CAPTAIN; target reviewed_user_id is DERIVED as the opposing captain, never read from the
  body. Trust 2.0 = round(35·rating + 30·attendance + 20·dispute_free + 15·sentiment); an absent
  component = 0.5 neutral prior in the aggregate but NULL in its column; zero-signal user = exactly 50
  (new player_profiles.trust_score DEFAULT, was 100). Recomputed SYNCHRONOUSLY after review/no-show/
  dispute — the flat trust−10 no-show decrement DELETED at 3 sites (noShowJob/bookings/owner): recompute
  overwrites it, so −10 was dead code and its notification a lie (now "trust score has been updated").
  dispute_free_rate is a stated pre-S.7 proxy. review_flags table mirrors disputes (UNIQUE(review_id,
  flagged_by) = one report per user; status open|resolved|dismissed + a status index = the admin queue);
  reviews.flagged is a UNION of a manual /flag OR model auto-escalation (needsReview). Serve fix:
  pricing.warm()/sentiment.warm() in lifespan (non-fatal, takes the lazy registry.get path) → first
  /predict/price is model-served not heuristic → the 60-check suite that scored 56/60 COLD is now 71/71
  (+11 new sentiment checks). Sentiment is scored BEFORE the txn opens (no FOR UPDATE lock across the
  ≤2s call; an unauthorised request never reaches ml-service); a 422 (unscoreable text) does NOT trip the
  breaker (bad input ≠ outage); unavailable → NULLs stored honestly, sentimentBackfillJob (200/sweep,
  batch-422 → per-row fallback, terminal 'unscoreable' sentinel) fills them later; review TEXT is never
  logged (id/label/flags/length only). NOT DONE: no review UI (Wave D); no live HTTP POST /api/reviews
  smoke (0 reviews in DB) — DB rules proven by the migration probes, contracts by 71/71 + clean boot, but
  a human posting through the 4 eps is Wave D / manual QA.
- S4-D — Flutter review UI + Trust 2.0 screens + moderation (code-complete; analyze 0; ML acceptance
  re-confirmed read-only: domain_test_200 0.8250, confusion matrix + model card present). Closes S4-C's
  "review UI" open item. ZERO migration — the reputation question ("team or individual?") resolved
  CAPTAIN-ANCHORED, which is exactly what 013's schema already encodes: skill = team (teams.elo),
  conduct = individual (player_profiles.trust_*, no trust column on teams), opponent reviews land on the
  representative captain. 5 surfaces: M24 rate_experience (venue stars + captain-only opponent stars; the
  demo moment = SentimentChip animating in live from the model), M25 trust_score upgraded (full-ring
  TrustGauge + 4 live TrustMetricTiles rendering "No data yet" on NULL, never 0, + reviews ledger),
  venue_reviews (paginated, off a venue_detail summary sliver that loads independently of the slot grid),
  owner_venue_reviews (read + flag), admin_moderation (hide/restore/dismiss). One shared vocabulary in
  widgets/trust_widgets.dart (mirrors match_widgets.dart; does NOT touch the working semicircle painter).
  2 net-new admin eps, no migration (hidden/flagged from 013, review_flags from 017 already exist):
  GET /api/admin/reviews/flagged + PATCH /api/admin/reviews/:id (txn+FOR UPDATE; hide/restore then
  refreshVenueAggregate OR recomputeTrust since hiding moves the trust inputs). ml-service down → review
  still saves 201 with sentiment NULL, chip reads "Sentiment added shortly" (no invented label). Read-only
  TeamReputationStrip gives the team view from data already on MatchSide. seed_reviews_demo.js (idempotent,
  --undo) makes 2 captained teams + reviews across labels incl. 1 abusive→flagged + 1 un-reviewed match.
  NOT DONE: live boot/curl/seed + two-device E2E (classifier down → manual QA, §4.13); review text still
  never logged.

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
