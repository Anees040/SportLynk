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
  X-API-Key auth. Loads all four models/*_latest.joblib (pricing, sentiment, reco, intent) ONCE at boot;
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
S.1, S.2 (A–D), S.3 (A–E), S.4 (A–D), S.5 (A–C) and S.6 (A–E) are all code-complete, and **S.7 Wave A (the
tournament module, SRS Module 6) is code-complete but NOT yet database-verified**: migration 019 has never been
applied to any Postgres, so the tournament check script, the demo seeder, the S.2/S.6 no-regression runs and the
generated `doc/tournament_evidence.md` are all still owed and TESTING.md §4.22 marks them ⛔ NOT YET RUN. The two
numbers that were observed are `npm test` **128/128** with the DB down and `flutter analyze` **0**. Applying 019
needs the user's explicit go-ahead — Supabase is the only database.

**S.6 Wave C landed on BOTH halves**: the v2 label contract + model #4 retrained to 23 intents (ml-service), and Scout's dialog
manager, action executor, chat persistence and the three FR8.15 service extractions (Node), verified live
at `PASS 326/326`. Wave D is the Flutter chat screen — built and `flutter analyze`-clean in a parallel
session, so that receipt is that session's and was not re-run here. Wave E is the honesty pass: no LLM in
the reply path (decided, not omitted), two dishonest badges corrected, the live HTTP surface proved at
`PASS 173/173`, a generated evidence pack, and the S.6 milestone checklist audited line by line in
TESTING.md §4.21. The ML tier is live end to
end: model #1 (dynamic pricing) is trained, gated, served, and on the owner's screen with
real confidence + a 72h demand chart, plus a reproducibility/evidence pack. Model #2
(sentiment) is trained, gated, served, and — as of S4-C — called by Node: every review with
text is scored by the classifier live at write time (backfill job for the rest). Model #3
(venue recommender) is trained, gated, served, and on the player's Find Venues screen — every
match% badge is a real cosine score and the fake client-side "AI Recommended" sort is gone. Model #4
(assistant intent classifier + rule entity extractor) is trained, gated and served at `POST /nlu/parse`,
and as of S6-C it understands **23 intents, not 15** — the assistant is named **Scout**, and its dialog
manager + action executor now SHIP: 27 actions, session state in `chat_channels type='assistant'`, a
six-value `answer.source` on every reply, and money executed through the same `bookingService` the REST
route uses. The chat screen shipped in Wave D, and S6-E audited the whole milestone against its own
acceptance list (TESTING.md §4.21) instead of declaring it done.
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
- Model #3: `reco-content-v1-20260827-0905`, a content-based VenueRecommender — NO learned weights:
  it fits a VenueSpace per venue (sport·price-bucket·rating·amenities·zone·indoor) and ranks by cosine
  vs a 0.5 recency-history + 0.3 stated-prefs + 0.2 review-affinity user profile; match% = round(55 +
  43×sim). Cold start = popularity-in-city + stated sports, labelled "Popular nearby" vs "For you".
  reco_features.py is the 3rd frozen ◆ contract (RECO_SPEC_VERSION reco-features-v1, fingerprint
  138790ba577ea0f0) — the estimator pickles app.core.reco_model.VenueRecommender BY REFERENCE, so the
  registry refuses a fingerprint mismatch exactly like pricing/sentiment. Reproduce: `python
  training/build_reco.py` (pulls a read-only Node snapshot; needs RECO_EXPORT_API_KEY).
- Model #3 evidence (S5-C): leave-last-out over 4 arms, `python training/eval_reco.py` (no backend or
  DB needed — reads the released joblib + the frozen synth CSV). Novel-venue cohort, n=89: HitRate@5
  0.461 vs cold-start-as-served 0.371 vs popularity 0.247 vs random 0.191 → **+24.2% over the baseline
  the app actually falls back to**. The 400-player synthetic population exists because the real corpus
  can only evaluate 2 users; both are published. reports/reco_eval.md + model_card_reco.md.
- Model #4: `intent-v2-20260828-2315`, the assistant's INTENT CLASSIFIER — word (1,2) TF-IDF ∪ char_wb
  (2,6) = 18,849 features → LinearSVC(C=0.5, balanced) → CalibratedClassifierCV(sigmoid, folds grouped by
  template_id), 6.6 MB, 10/10 gates. **23 intents in 8 groups** (`assistant-intents-v2` ·
  68396192ab4a87a4) — S6-C added `find_players`, `find_teams`, `navigate`, `contact_owner`, `app_help`,
  `elo_help`, `affirm`, `deny` and dropped NONE of v1's 15. Held-out phrasings 0.8086 / macro-F1 0.8042
  (0.8569 grouped); the sha-locked, re-locked **230-row** hand-written exam **0.6696** / 0.6608, 0.7652
  collapsed to the 8 groups, 95% CI [0.6087, 0.7261] (2000 resamples) vs a 0.0435 majority baseline — the
  gap is a WRITER gap, not a bug, and both numbers are published. `confidenceThreshold = 0.45` is stamped
  IN the artifact: val coverage 0.8662, accuracy on what it answers 0.8863, confident errors 103 → 53,
  ECE 0.1854 → 0.1788. Every one of those figures is in `reports/intent_metrics.json` — read them there,
  because a superseded same-spec candidate (`intent-v2-20260828-1329`) is still in `models/` and its
  numbers are close enough to look right when quoted from memory.
  Three abstain reasons on the wire (`low_confidence`, `no_evidence`, `no_known_terms`) and all five entity
  slots are returned even when it abstains — there is NO count, team or venue-name slot, so "need 2
  players" yields no 2. Entities are PURE RULES (`app/core/entities.py`, `nlu-entities-v1`) — stated
  plainly, not dressed up as learning. Reproduce: `cd ml-service && python training/train_intents.py` — no
  flags; seed 20260824 is DEFAULT_SEED, so that exact command produced the served artifact in 30.6 s.
  `POST /nlu/parse` p50 **20.9 ms** on a quiet box (v1 was 14.6 — 8 more labels cost +26% at the
  estimator: 9.41 ms vs 7.46 ms predict_proba, measured back to back in one interpreter), and the 50 ms
  budget is now close enough to real scheduler jitter that a CONTENDED laptop breaches it — see the S6-C
  wave-log entry.
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
- NEXT: **S.6 is DONE, A through E.** Model #4 serves 23 intents at `intent-v2-20260828-2315`, and Scout's
  Node half is built and live-verified: `POST /api/assistant/message`, 27 actions, slot-filling across turns,
  the chat drawer, the KB/escalation loop, and `PASS 326/326` from `check_assistant.js` inside a rolled-back
  transaction. **Wave D built the Flutter chat screen** against this fixed contract — it is the one to build to:
  `{text, chips[{label, action, args}], cards[{type, data}], answer:{source, ...}}` where `type` is one of
  venue · booking · slot_picker · confirm · player · team · tournament · map · wallet · stats · policy ·
  capabilities, EVERY action card carries buttons (there is no free-text-only dead end by design), and a chip tap
  posts `{action, args}` back — never re-typed prose, because a chip is one of only two doors allowed to move
  money. Show `answer.source` in the UI (a quiet badge): `live` is a DB read, `policy` is `global_settings` text
  with the numbers substituted from `escrow.POLICY` at render time, `model` is the classifier, `kb` is an
  owner-approved answer, `menu` is the capability fallback, `escalated` means a human owner was asked. The drawer
  is `GET /api/assistant/threads` (newest-activity first, cap 50) + `GET /api/assistant/threads/:id/messages`
  (paged with an opaque cursor — pass it back verbatim, do not build one client-side) + rename/archive/delete.
  Two things Wave D must NOT do: render a booking confirmation from client state (the confirm card's `args` are
  server-issued and must round-trip untouched), and retry a failed turn automatically (a turn that timed out may
  have already written a message). Then Wave E is Scout's evidence pass (transcript pack + the assistant's own
  numbers for the report). Still open from S.5: the operator chain has been run once (seed → `build_reco.py` →
  `POST /reco/refresh` → `--verify`: sport axis football/cricket, artifact `…-20260827-200702`, rails differ 4/5
  overlap), so what remains is the HUMAN in-app pass — two seeded accounts side by side, a brand-new account
  showing "Popular nearby" with no %, ml-service-down fallback (TESTING.md §4.16 steps 157-158) → commit +
  `tag s5-done`. Then S.7 tournaments/chat/admin dispute-UI/demo pack + deploy ml-service as a 2nd Render
  service. NOTHING IS COMMITTED YET across S.3–S.6; a commit of the assistant must include
  `ml-service/models/intent_latest.joblib` or the box that pulls it cannot boot 4/4.

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
- S5-A — venue recommender (model #3) trained, gated, served + the Find Venues rail is real (VERIFIED:
  build_reco RELEASED 3/3 gates, ml-service + backend boot clean, flutter analyze 0; real Supabase, 10
  venues / 8 users). Content-based, NO sklearn: VenueRecommender fits a VenueSpace per venue (sport·
  price-bucket·rating·amenities·zone·indoor) and scores cosine vs a 0.5 recency-history + 0.3 stated +
  0.2 review-affinity profile; match% = round(55 + 43×sim). "Training" snapshots the catalogue + user
  histories INTO the served object, so the estimator pickles app.core.reco_model.VenueRecommender BY
  REFERENCE (stable dotted path, same trick as proba.SoftmaxSVC) and reco_features.py is the 3rd frozen
  ◆ contract (fingerprint 138790ba577ea0f0; registry refuses a mismatch → incompatible). Serving is
  HONEST: source model|heuristic|unavailable in mlClient; the Sparkles + "N% match" chip render ONLY
  when source=='model' (heuristic carries no fake match_pct), and the old client-side "AI Recommended"
  sort is DELETED. Node GET /api/venues/recommended = 15-min TtlCache (model results only) + heuristic
  fallback (sport-preference sort). Data path is a NEW trust boundary: GET /api/internal/export/reco-data
  streams every player's booking history, so it uses a SEPARATE RECO_EXPORT_API_KEY (never ML_API_KEY,
  which is pending rotation), fails CLOSED (503) below 16 chars, and returns an identical 401 for
  missing==wrong. Eval = leave-one-out HitRate@3/@5 + MRR vs a popularity baseline (the recommender's own
  cold-start path, profile stripped); the seed corpus has only 2/8 users with ≥2 bookings, so the lift
  gate is WAIVED below 5 and the +0.0% lift is PUBLISHED not hidden (reco_eval.md caveats n; model_card_
  reco.md + reco_metrics.json complete the pack). main.py warm-up now covers reco too. Reproduce:
  `python training/build_reco.py`. VERIFIED LIVE: /health reco status=ready (modelVersion
  reco-content-v1-20260827-090526) and an authenticated GET /api/venues/recommended returned
  source=model with a real match_pct + reason chips.
- S5-B — player-for-team suggestions (FR2.8) + opponent re-ranking (FR5.3–5.5): a DETERMINISTIC
  weighted scorer, NOT model #4 — the weights are given literally, so nothing is trained (no joblib, no
  KNOWN_MODELS entry, and the two endpoints can never 503 model_not_loaded). Lives in app/core/reco_rank.py
  (RANK_SPEC_VERSION reco-rank-v1, fingerprint 1a6c5f39bf5a2c56), a 4th frozen ◆ contract that imports
  reco_features side-effect-free and does NOT edit it (Wave A's fingerprint is stamped in a RELEASED
  artifact — editing it would break serving). PLAYER = 0.40 sport-fit + 0.25 elo (team ELO, or trust as a
  proxy when teamless) + 0.20 activity + 0.15 zone; OPPONENT = 0.60 elo-proximity + 0.20 trust + 0.20
  activity. An absent component takes NEUTRAL_PRIOR 0.5 in the mean but stays NULL in the published
  components map — a cold start is not punished, and the breakdown bar says "not counted against them",
  never 0%. FR2.6 preserved: competitiveness == the composite match% when both teams are ranked, NULL when
  either is unranked, yet the candidate is STILL ranked (elo term → neutral). Schema gaps handled honestly,
  NO migration: no position column (fit = sport only, gaps.position:null), no player city/zone (derived
  from the venues a player actually books, zone_of), no player visibility flag (role='player' AND
  is_active). New wire value source:"ranked" — never badged as AI, because it is a published formula, not a
  trained model; pct band 5..99, half-up rounding, order key (-match_pct,-score,id) so the list is monotone
  in the printed number; fixed activity caps (players 8/30d, teams 4/30d). Node: POST /reco/players +
  /reco/opponents (ml-service), GET /api/teams/:id/suggested-players (admin-only), and GET
  /api/matches/opponents now enriched (matchPct/rankScore/components/reasons/matchesLast30d + a ranking{}
  block; the v1 |ΔELO| sort is KEPT as the fallback). mlClient breaker: a 4xx does NOT trip it (only
  5xx/network), an empty pool short-circuits with no round trip, and a fallback never carries a fabricated
  match_pct. Flutter: reco.dart + reco_widgets.dart (MatchPctBadge, the WhyThisMatch expander,
  SuggestedPlayersRail + PlayerSuggestionSheet, RankingSourceNote); the roster gains an admin-only
  "Suggested players" rail (match% + an invite shortcut that reuses the single-use link, tagged with a
  note), find_opponents gains the "Why this match?" breakdown + an attribution strip, and its band divider
  is now gated to the fallback path (on the ranked path order is by quality, so withinBand is only a
  per-row marker). VERIFIED: flutter analyze 0, node --check clean on all 4 touched JS files, backend boots
  clean. LIVE-VERIFIED (2026-08-27): ml-service restarted (--reload); /health.recoRankSpec + /reco/rank-spec
  return reco-rank-v1 · 1a6c5f39bf5a2c56, trained:false, full contract matches. Emulator E2E skipped; the
  per-request wire contract (envelope rankSpecVersion → mlClient → Node specVersion → Flutter) traced by
  inspection and consistent across all four layers.
- S5-C — "how do you know it works?" answered with an offline eval pack, plus the two things the
  milestone checklist still needed. NEW `ml-service/training/eval_reco.py` (does NOT touch the backend
  or the DB: it loads the RELEASED reco_latest.joblib and the frozen data/bookings_synth.csv, so the
  thing measured is the thing served). The n=2 problem from S5-A is solved WITHOUT regenerating the
  CSV: the script adds a simulated USER layer over the S.3 world (400 players from a seeded taste
  model, 204 with ≥3 bookings, 89 in the novel-venue cohort), and the real seeded corpus is still
  reported beside it from the users frozen inside the artifact. FOUR arms rank the same candidate set:
  random · popularity (0.7×log count + 0.3×rating) · **cold-start-as-served** (0.6 popularity + 0.4
  stated sport — the honest lift denominator, because that is what the app actually falls back to) ·
  content. Headline (novel venues, n=89): HitRate@5 random 0.191 · popularity 0.247 · cold-start 0.371
  · **content 0.461** = +86.4% over popularity, **+24.2% over cold-start**; gate MIN_LIFT_OVER_COLD_
  START=0.05 PASSES. Two leaks were found and closed: highReviews pointing AT the held-out venue
  (stripped in _trim) and repeat-visit inflation (the all-items cohort is 0.735 vs 0.461 novel —
  published side by side rather than quietly cited). Saturation avoided by blanking the synthetic
  users' city so all 4 arms rank all 20 venues (Lahore has 3, Karachi 2 → every arm would score 1.0);
  the real arm KEEPS the served prefilter. Pitfall answers are now evidence, not assurances: the
  match-% spread table (min 79 · median 89 · max 98, 20 distinct values over 1020 sampled) answers
  "is 97-99% fake?"; the weight sweep answers "why 0.5/0.3/0.2?" HONESTLY — the 7-row grid spans
  0.056 where the binomial SE at n=89 is ±0.053, so **every row is inside one SE of every other** and
  the shipped split is defended as insensitive-not-optimal (a grid row of exactly 0.00 would divide by
  zero inside blend_user_vector's renormalisation, so the grid floors at 0.01 — unreachable in
  production, all three shipped weights are non-zero). reco_features.py stays FROZEN: the sweep
  rebinds rf.COMPONENT_WEIGHTS in memory with a finally-restore. Cold-start guard is probed, not
  asserted (18 zero-signal users, all → profile cold_start). Reports: reports/reco_eval.md +
  model_card_reco.md now come from THIS script and say so — build_reco.py writes short versions of the
  same two names at train time, so the run order is build → eval, and both files carry a supersedes
  header. Pitfall 2 closed: NEW `POST /reco/refresh` (key-gated by the same middleware; drops the
  registry cache so a retrain is visible without restarting uvicorn — deliberately fails 503 with the
  registry's reason rather than serving a model whose file on disk was replaced). NEW
  `backend/seed_reco_demo.js` (seed · --verify · --undo): writes two CONTRASTING booking histories so
  two demo players get different rails, picking the contrast axis from the catalogue (sport when two
  sports have ≥3 venues each, else the price extremes), dating bookings 4/12/25 days ago via created_at
  because the profile is recency-weighted, and NEVER overwriting a player's existing sport_preferences.
  --verify calls /reco/venues for both players and prints the two rails with the overlap count, which
  is the evidence for the checklist item. VERIFIED: eval gate PASS, ml-service imports clean +
  /reco/refresh in the OpenAPI schema and returns ready/reco-content-v1-20260827-090526, node --check
  clean, flutter analyze 0 (no Flutter change this wave). seed_reco_demo.js is NOT run — it writes to
  the DB, so it is the user's to run, and the rails stay identical until build_reco + /reco/refresh.
- S6-A — the Model #4 (assistant NLU) corpus, and the instrument that will grade it, both shipped
  BEFORE any classifier exists. NEW `app/core/intent_spec.py` — the 4th frozen ◆ contract, and the
  first to publish TWO fingerprints: labels `assistant-intents-v1` · 7bb78a3ac94cbdef over the 15
  intents in `model.classes_` order, dataset `assistant-dataset-v1` · 0eb01bc58b4a040f over slot
  vocabulary/quotas/thresholds. Two, because adding a slot value invalidates a corpus while renaming
  an intent invalidates every model ever trained. NEW `training/gen_intents.py`: 464 hand-written
  templates → ≤12 pooled candidates each (seeded, deliberately NOT index-sorted) → water-filled
  allocation → split GROUPED by template_id → 40 named gates. 1,680 rows, **112 for each of the 15
  intents** (en 675 · ru 585 · mix 420; train 1,332 / val 348; 236 authored rows kept verbatim),
  sha256 c539b8fc…, byte-identical on replay. NEW `training/validate_intent_test.py`: 24 read-only
  checks over the 150-row hand-written exam → sha-lock in `assistant_test_meta.json`, which
  gen_intents then enforces as a HARD gate. GOTCHA: the gates found five real defects in the
  hand-authored inputs before a model could hide them — 6 out_of_scope patterns used
  {city}/{sport}/{date} (a slot spreads a "city ⇒ out_of_scope" association over dozens of rows;
  each became one literal), a space before "??" in au-164, a 2-char exam row (`ty` → `ty!`, fixed in
  the EXAM because it was not yet locked, rather than lowering MIN_TEXT_CHARS to fit one row), and a
  429-row capacity gap over 24 (intent,lang) cells — closed by authoring 152 more templates, NOT by
  relaxing TEMPLATE_CAPACITY_MARGIN=1.30 and NOT by giving up equal rows per intent. NEW
  `.gitattributes`: core.autocrlf=true with no attributes means a fresh clone gets CRLF copies of
  every sha-locked CSV and all three provenance gates fail on a machine where nothing is wrong.
  VERIFIED: 40 corpus gates green (39 PASS + 1 WARN) + 24/24 exam checks PASS, sha256 stable on replay, 0 exam
  rows leaked at the 0.80 near-dup threshold (max score seen 0.500), lang×intent Cramér's V = 0.000
  by construction, source×intent 0.0318. NOT trained yet — that is Wave B.

- S6-B — **model #4 exists**: the assistant's intent classifier, trained by this project, not called
  from an LLM API. NEW `training/train_intents.py` — word (1,2) TF-IDF ∪ char_wb (2,6) = 15,220
  features → LinearSVC(C=0.5, balanced) → CalibratedClassifierCV(sigmoid, folds GROUPED by
  template_id), 10 named release gates, the SERVED artifact written only if all ten pass (the
  timestamped twin is written either way). Released
  `intent-v1-20260828-0053` (3.9 MB): validation (348 unseen phrasings) 0.8678 / macro-F1 0.8662 /
  ECE 0.1854, sha-locked 150-row exam **0.6200** / 0.6129 / ECE 0.0829, grouped to the 6 intent groups
  0.6733, 95% CI [0.54, 0.70], vs a 0.0667 majority baseline. NEW `app/core/entities.py` — pure-rule
  extractor (5th frozen ◆ contract, `nlu-entities-v1` · 34aee7e75192e6fe, provenance-only so moving the
  "shaam" window cannot take the classifier offline): date/time/sport/area/budget in Asia/Karachi with
  Roman Urdu pre-mapped (kal·parso·somwar·jumma·shaam·baje·2 din baad·agle hafte), a 31-phrase area
  gazetteer seeded from `SLOT_VOCAB["area"]` (22 phrases, what the classifier was trained on) and extended
  by the reco artifact's venue snapshot to 31, and every slot reporting its own rule/source/text/span —
  except `sport`, which has neither span nor rule, and `budget`, which has a span but no rule. NEW `app/core/nlu_text.py` (`nlu-text-v1` · eca8d0423d2084b3 — GATED, because
  the artifact pickles `prep` by reference). NEW `app/routers/nlu.py`: `POST /nlu/parse` →
  `{intent, confidence, entities}` + abstention + provenance, `GET /nlu/spec` (the contract Node reads
  at startup — 15 intents with glosses, the 3 abstain reasons, limits; deliberately does NOT 503 when
  the model is missing), `POST /nlu/refresh`. NEW `training/test_nlu.py`: **63 tests, ≈2 s warm**, runs
  standalone AND under pytest, every date case against a frozen clock (2026-08-28 15:00 PKT).
  GOTCHA 1: the 0.45 floor cannot catch nonsense — gibberish scored `greeting` **0.5246**, ABOVE the
  floor, because char n-grams always find texture. Fixed with a measured third abstain reason
  `no_known_terms` (no token is a fitted word-vocabulary unigram): 0 firings on all 1,680 corpus + 150
  exam rows, 85 of 87 gibberish strings caught, 0.022 ms/call. That is also why the word half of the
  union stays despite the ablation (char_only val 0.8534 / exam 0.6467 ≈ word+char 0.8477 / 0.6467): a
  char_wb row is never empty **for Latin-script input** (a non-Latin script zeroes both halves), so the
  redundant half IS the OOV detector. GOTCHA 2: a pydantic field
  named `entities` shadows the `entities` MODULE for the rest of the class body — `entities.ENTITY_SPEC_VERSION`
  as a field default raised at import and the service would not boot; the three spec constants are now
  bound above the model. GOTCHA 3: `/nlu/refresh` reloads ARTIFACTS, not code — after editing the
  router you must restart uvicorn. VERIFIED: 10/10 gates RELEASED in 13.2 s at the default seed
  20260824 · 63/63 tests · `/health` 4/4 models ready (it publishes `registry.describe()`: no threshold,
  no labels — those are on `/nlu/spec`) · five slots extracted live
  from "kal shaam 6 baje f-11 me futsal ground chahiye 2500 tak" (2026-08-29 · 18:00 · futsal · F-11 ·
  max 2500 PKR) in 9.92 ms · 300 utterances over HTTP p50 14.6 / p95 18.9 / max 28.6 ms, **0/300 over
  the 50 ms budget** · all three refusal paths + 422s for empty/501-char/unknown-field · check_ml_service.js
  still **71/71**. The floor is priced, not asserted: coverage 0.8764, answeredAccuracy 0.9246,
  confident errors 46 → 23. Utterances are NEVER logged (intent/confidence/chars/sessionId only). No
  dialog manager, no session state, no Flutter screen — the manager and executor are Wave C, the screen
  is Wave D.
- S6-C (ml-service half) — **the label contract went v1 → v2 and model #4 was RETRAINED on it**, because
  Scout could not answer "find me players", "how do I get there", "how does ELO work" or "yes" with 15
  labels. CHANGED `app/core/intent_spec.py`: 23 intents in **8** groups (`dialog` = exactly `affirm` +
  `deny`), `INTENT_SPEC_VERSION` `assistant-intents-v2` · **68396192ab4a87a4**, `DATASET_SPEC_VERSION`
  `assistant-dataset-v2` · **339ad58af5ddb072**. The 8 NEW labels are `find_players`, `find_teams`,
  `navigate`, `contact_owner`, `app_help`, `elo_help`, `affirm`, `deny`; **none of v1's 15 was dropped**,
  and that is asserted, not asserted-by-hand — `test_nlu.py` derives the added set from the spec and fails
  if a label ships untested. Corpus regenerated to **2,576 rows** (112/intent, en 1035 · ru 897 · mix 644,
  624 templates of which 622 contributed, 382 authored, sha `64395ec8026c`); the exam grew to **230 rows**
  (10/intent, re-locked at sha `1f60b29cabad`) with v1's 150 rows kept **byte-identical** so the grids and
  the old numbers stay comparable. RELEASED `intent-v2-20260828-2315` at 10/10 gates in 30.6 s — the
  pre-fix candidate `intent-v2-20260828-1329` is still in `models/` and every figure below was recomputed
  off the RELEASED artifact in S6-E, because the wave was first written up from the candidate's numbers.
  THE FINDING — a **pre-existing v1 corpus defect**, not a model failure: "need 2 more players for
  tonights cricket match" returned `find_opponents` 0.77, and ablation showed the word "match" flipped it.
  3 templates + 3 authored rows had taught "we are N players short ⇒ find_opponents" — the least-wrong
  label in a v1 that had no `find_players`. `git diff --stat` proved they were v1's. Rewriting those 6 rows
  beat both candidate models outright and improved every metric at once, which is why the 1258-vs-1317-row
  question that dominated the middle of the wave became moot. GOTCHA 1: bumping the spec while a v1
  artifact is released makes `/health` report the intent model **`incompatible`** and `modelsReady 3/4` —
  the fingerprint is gated at load, so a retrain needs `POST /nlu/refresh` or a restart. GOTCHA 2: the
  **50 ms parse budget is no longer robust**. In-process the estimator costs 9.41 ms against v1's 7.46 in
  the same interpreter (+26% for 8 labels, 23 × 5 = 115 calibrated sub-estimators, 6.6 MB not 3.9), and a
  quiet sweep of 120 exam utterances over HTTP reads p50 **20.9 ms** with 2/120 over budget — but the same
  120 rows on a box shared with a second dev session read p50 **82.6 ms with 119/120 over**, and
  `test_a_warm_parse_stays_inside_the_fifty_millisecond_budget` fails there and passes when quiet. Treat a
  budget failure as a load signal first; the number to re-measure is `intentMs`, since `entityMs` stayed
  0.2 ms throughout. GOTCHA 3: `datasetSource` is published on `/health` and in the model card, and it was
  a **hardcoded v1 string** — the third dishonest receipt of this wave. It is now DERIVED from
  `intents_meta.json` and raises `SystemExit` rather than guess. VERIFIED: 10/10 gates · val 0.8086 /
  macro-F1 0.8042 / ECE **0.1788** (from 0.1854) · exam **0.6696** / 0.6608 / 0.7652 grouped / CI
  [0.6087, 0.7261] · floor 0.45 → coverage 0.8662, answeredAccuracy 0.8863, confident errors 103 → 53 ·
  0 exact exam collisions, max near-dup 0.7143 · **68/68 tests** (63 → 68, and two were repaired: one was
  silently SKIPPING because its pinned utterance had risen above the floor, one had a name that still said
  "fifteen classes") · `/health` 4/4 ready on `intent-v2-20260828-2315` · `/nlu/spec` 23 intents / 8 groups
  / threshold 0.45 / fallback `out_of_scope` / the three abstainReasons · all **8 new labels reachable over
  HTTP**, each beating its runner-up by ≥0.35 · `check_ml_service.js` still **71/71**. THE HONEST COST of
  8 more labels, recomputed in S6-E off the RELEASED artifact by `training/diff_intent_exam.py` (both models
  scored on the 150 exam rows whose gold predates v2, argmax of one `predict_proba` call): v1 got **93/150**,
  v2 gets **84/150** — **13 rows lost, 4 regained, net -9**. 6 of the 13 fall below the floor and abstain
  rather than lie; 1 is stale gold under a v2 gloss (at-139 `venue_info` → `navigate` 0.7801 — routes ARE
  `navigate` in v2), leaving **6 served regressions a user can actually see**: at-056 find_venue →
  find_players 0.5217, at-064 greeting → deny 0.7693, at-093 refund_policy → topup_help 0.4886, at-110
  team_stats → app_help 0.4748, at-118 topup_help → app_help 0.5112, at-123 tournament_list → find_teams
  0.4781. All 4 regained rows sit BELOW the floor, so they are argmax wins the user never sees. This entry
  first published **12 lost / 7 abstaining / 3 served** — that is the PRE-FIX candidate's diff, and the same
  script reproduces it with `--candidate intent_20260828-1329.joblib`, which is how the two were told apart.
  No threshold was moved to make any of this pass.
- S6-C (Node half) — **Scout exists.** `POST /api/assistant/message {text, threadId?}` → `dialogManager.handleTurn`
  → `/nlu/parse` → an action executor that answers with `{text, chips[], cards[], answer:{source, ...}}`, plus the
  whole chat drawer (`GET/POST /api/assistant/threads`, rename, archive, delete, `GET .../messages` paged) so Scout
  behaves like a real assistant and not a one-shot form. NEW: `routes/assistant.js`, `services/dialogManager.js`
  (session FSM), `services/assistantActions.js` (**27 actions** = the 23 model labels + 4 button-only:
  `confirm`, `cancel_confirm`, `pick_slot`, `capability_menu`), `services/assistantThreads.js`,
  `services/assistantKb.js`,
  `utils/assistantReply.js` (the two frozen enums), `utils/policyText.js`, migration **018** (`assistant_turns`,
  `assistant_kb`, `assistant_escalations`, `assistant_feedback`, + `chat_channels.session_state jsonb` /
  `archived_at` / `assistant_persona` and `chat_messages.assistant_payload`; 12 indexes, the KB's trigram one
  created conditionally so a database without `pg_trgm` still applies the migration and matches with `ILIKE`).
  DECIDED (the user delegated it): `answer.source` is the six-value enum `live | policy | model | kb | menu |
  escalated`, DB-enforced by `chk_assistant_turns_src` — every bubble can say WHERE it came from, which is what
  makes "the model answered" a claim a committee can audit instead of a vibe. FR8.15 forced three extractions and
  they are the load-bearing part of the wave: **`bookingService.js`** (`createBookingTx` / `cancelBookingTx` —
  money), **`rosterService.js`** (player + opponent ranking), **`discoveryService.js`** (venue search / detail /
  free slots / tournaments / team discovery). The REST routes now CALL those; Scout calls the same two money
  functions; nothing is reimplemented.
  GOTCHA 1 — **the money bug, found by writing the test that tried to break it.** `decide()` has three doors: a
  chip carries its own action, then a frozen affirm/deny LEXICON, then the model. The confirm gate originally
  accepted any of the three, so `"haan lekin 7 baje"` ("yes but make it 7") parsed `affirm` **0.6112** by MODEL and
  fired the armed confirm — booking the 8pm hour the user was in the middle of correcting. Money is now gated by
  doors 1 and 2 ONLY (`const decisive = decided.via === 'chip' || decided.via === 'lexicon'`); a model-affirm
  re-asks. The lexicon path records NULL confidence and NULL model_version, so the turn log never credits the
  classifier for a decision it did not make.
  GOTCHA 2 — **`created_at timestamptz DEFAULT now()` is the TRANSACTION's clock.** Scout writes the question and
  the answer in ONE transaction, so both rows got a byte-identical stamp and history order fell through to
  tiebreakers. `chatCore.insertMessage` now stamps `clock_timestamp()` itself (per-statement), and `history` sorts
  `created_at DESC, (kind='assistant') DESC, id DESC` with a row-tuple cursor comparing **the same three fields it
  sorts by** — a cursor that sorts on three and compares on one silently skips or repeats rows at the page seam.
  Team chat is unaffected (one message per transaction) but now benefits.
  GOTCHA 3 — **state-patch semantics are asymmetric on purpose**: `intent`/`slots` absent means KEEP, `pending`/
  `confirm` absent means CLEARED, so any unrelated turn DISARMS a pending confirm. A cleared slot is absent
  (`undefined`), never `null`. Also: `team_members.role` is `captain | vice_captain | member` — there is no
  `'admin'` role (that is `ADMIN_ROLES` in `teamAccess.js`), and a player who captains two teams must be ASKED
  which team, not guessed for.
  GOTCHA 4 — **`assistantActions.js` lost ~736 lines mid-wave** (cause never established; not a git operation).
  Every handler was rebuilt from the verified contracts and the registry is now BOOT-ASSERTED against the spec, so
  a missing handler fails at require-time instead of at 2am in a demo.
  PRODUCT FINDINGS, stated not hidden: there is no targeted-invite endpoint (Scout can rank players and open the
  roster screen, but the invite is the user's tap) and a challenge needs an existing booking, so `find_opponents`
  ends at "book a slot first". `tournaments` has rows: 0 and no REST route yet — `tournament_list` answers
  honestly and empty. Verification needs a seam: `handleTurn` accepts a caller-owned `client`, and with one, `TXN`
  degrades to `SAVEPOINT scout_turn` / `RELEASE` / `ROLLBACK TO SAVEPOINT`, so a check script's outer
  `BEGIN … ROLLBACK` survives 45 real turns.
  VERIFIED: `node src/scripts/check_assistant.js` → **PASS 326/326**, exit 0, **zero skips**, ~2m40s, inside one
  transaction that is ROLLED BACK (assistant threads/turns/escalations back to 0, bookings back to 40 — measured
  after the run). (The wave closed at 278 checks; S6-E's badge fix took it to 280 and its new sections to 326 —
  the script is one growing receipt, not one per wave.) It drives the LIVE classifier
  (`intent-v2-20260828-2315`, floor 0.45) through: a booking end to
  end with its ledger legs; a cancellation with refund + penalty and **money conserved across both wallets**; the
  four ways a confirm gate could leak money (model-affirm books nothing · stale confirm · model-deny · a chip
  positive control that DOES book); every read intent and every `answer_source`; escalation → owner answer → KB
  reuse delivered into the player's own thread; discovery + maps + the two-team disambiguation; the full chat
  drawer (new/rename/switch/archive/delete/paging/`MAX_THREADS`/cross-user 404s); and FR8.15 counted over 50
  source files — **`INSERT INTO bookings` appears in exactly one file** (`services/bookingService.js`) and Scout
  contains ZERO money primitives (`applyWallet`, `logTxn`, `penaltySplit`, `lockWallet`, `UPDATE slots SET status`
  — none). PRIVACY proved by column census: `assistant_turns` has 17 columns and not one free-text column that
  could hold what the user typed (`text_chars int` — length only). Second receipt, narrower and faster:
  `check_booking_service.js` **PASS 60/60** — it books and cancels for real and asserts the ledger against the
  table at the top of `escrow.js` (full refund ≥24h, 0.8/0.2 inside the window, `slot_taken`,
  `not_cancellable`, `insufficient_funds` leaving wallet and slot untouched), so the extraction is proved
  money-safe independently of Scout. `npm test` **85/85** with the DB down. The one thing this wave did NOT
  run was the live HTTP pass over the 16 endpoints (Express, JWT middleware, rate limiter) — TESTING.md §4.20
  steps 196/197/200 — and S6-E closed it: `check_assistant_http.js` → **PASS 173/173**, 0 skips.
- S6-E (the honesty pass) — **DECIDED: no LLM anywhere in Scout's reply path.** An `ASSISTANT_LLM=off|phrasing`
  layer (deterministic reply → external API → reworded reply) was designed and deliberately not built:
  rephrasing means transmitting wallet balances, booking times and opponent names to a third party, which
  reverses the `assistant_turns`-stores-no-free-text property proved in S6-C; golden rule 3's carve-outs leave
  only the greeting and the capability menu, which are the two lines that need it least; and it muddies the one
  claim worth defending — that routing is done by a classifier this project trained. Every sentence Scout speaks
  is composed in Node from a template or read from the database. Cost accepted and written down: the replies
  read like a well-built form. Recorded in PROGRESS.md (Wave S6-E) and in `model_card_intent.md`.
  Two badges corrected. (1) `"kal shaam football islamabad"` — the checklist's own utterance — parsed 0.364 and
  ABSTAINED, because the corpus taught `find_venue` in sentence form and almost never as bare keywords. Fixed at
  the CORPUS, not with a pre-classifier `if sport && city` rule that would have answered the checklist while
  leaving the model as weak as it was: keyword shapes added to `gen_intents.py`, retrained →
  **`intent-v2-20260828-2315`** (corpus 2,576, the sha-locked 230-row exam untouched), and that utterance now
  reads `find_venue` **0.8108** while `"kal shaam"` alone still abstains at 0.3172. KNOWN LIMITATION, kept
  rather than papered over: `"kal shaam cricket lahore"` → `find_players` 0.4764 — Lahore is in neither
  `CITY_ALIASES` nor `SLOT_VOCAB["city"]` because all ten seeded venues are in the twin cities, and teaching the
  classifier a city the booking half cannot serve would be the worse bug. (2) `find_players` /
  `find_opponents` no longer answer `source: 'model'`: `reco_rank.py` is a deterministic weighted scorer, so one
  flag became two — `scored` picks the sentence ("ranked by fit" vs "most recently active"), `modelBadge` picks
  the badge, and the three-state truth moved to `meta.ranking` (`ranked | heuristic | unavailable`).
  `find_venue` keeps `model` because model #3 is genuinely trained. `check_assistant.js` → **PASS 280/280**
  at that point, and **326/326** once this wave's own sections landed.
  NEW receipt, closing S6-C's dangling "NOT yet run": `src/scripts/check_assistant_http.js` (1,258 lines) →
  **PASS 173/173**, 0 skips — it attaches to a listening server or spawns `src/server.js` and kills only what it
  spawned, mints real JWTs, drives all 16 endpoints through Express, cleans up in a `finally`. TESTING.md §4.20
  steps 196/197/200 are green.
  NEW ARTIFACT — **`doc/scout_evidence.md` is generated, not written.** Both check scripts take `--evidence`
  and each owns one HTML-comment-delimited block in it (`service`, `http`), rewriting only its own, so either
  can be re-run alone; **a block that is absent was not run.** Each block carries what is needed to reproduce
  it — commit + uncommitted-path count, node, model version + threshold + threshold SOURCE, the label/dataset
  and entity/text fingerprints from the Python side, parse limits, registry census, database — then every
  assertion in order and the transcript of the real turns (45 service, 19 HTTP) with intent, confidence,
  `answer.source` and the `via` door. Shared writer: `src/scripts/lib/evidence.js`, a no-op unless the flag is
  passed, which is why the calls live permanently in `section`/`check`/`skip`/`note` and inside `api()` (one
  helper, not forty call sites). Deliberately NOT recorded: any credential, and not even `/health`'s
  `apiKeyFingerprint` — it is safe by construction but the file is committed and the key is awaiting rotation.
  GOTCHA — a pipe in a generated table cell must be `&#124;`, not `\|`: a backslash in a JS string written
  through a shell heredoc is one escaping round from being eaten, and in the first pack it was, giving
  five-column rows. Same family as the recorded `\n`-in-a-heredoc and `python - <<'PY'` cp1252 quirks.
  GOTCHA — **SEC-6 shuts the door before the doorman does.** Eight assertions failed `429` where `401` was
  expected: the anonymous quota is 20/min/IP and `identifyUser` counts a token that FAILS to verify as
  anonymous, so 4 logins + 16 probes had spent the bucket. Section A is now 4 bad headers + 16 endpoints =
  exactly 20, runs before any login, and mints its own token for the positive check; new section A2 spends
  request 21 on purpose, asserts the exact 429 sentence + `RateLimit-Policy: 20;w=60` + `Retry-After`, then
  sleeps the window out. Two of my own assertions were wrong and the code won both: a chip turn DOES carry an
  `nlu` block (`intent` is what the client renders) — what must be null is `confidence` and `modelVersion`, so a
  tap never enters measured accuracy; and the abstain reason is `nlu.reason` over the wire, not `abstainReason`.
  VERIFIED over HTTP, not argued from source: `"haan lekin 7 baje"` = affirm **0.5898 via model**, above the
  0.45 floor, and the census reads **bookings 27 → 27, balance 8300.00 unchanged** with the armed confirm gone
  and `slots.time` = `19:00`; the bare `haan` after it is `via: 'lexicon'` and still buys nothing; the 51st chat
  → `409`; a stranger reading another user's thread → `403`, not a 404 that would confirm it exists;
  `state.confirm` never appears in a response body; and — provable only after the delete — **19 telemetry rows
  survived their thread being deleted, `channel_id` nulled 19/19** (migration 018's `ON DELETE SET NULL`).
  AUDIT, not a victory lap: the S.6 milestone acceptance list is now walked line by line in TESTING.md
  §4.21 — six acceptance lines, five pitfalls, one limitation — and two of its lines could NOT be ticked as
  written, so they are recorded instead of quietly satisfied. `my_elo` cannot exist as an intent (SportLynk
  rates TEAMS, so it is `team_stats`; a per-player ELO answer could only invent a number), and pitfall 5
  ("keep the 15 labels") was not followed — v2 ships 23, with step 187's ≥0.35-margin reachability check as
  the compensating control. The audit also caught this file, PROGRESS.md and TESTING.md quoting the PRE-FIX
  candidate run: corpus sha `adbdd5d63a81` (real: `64395ec8026c`), 616/614 templates (real: 624/622), val
  0.8033 / exam 0.6652 (real: 0.8086 / 0.6696), 18,809 features (real: 18,849), and a "12 exam rows" cost
  that is 13 on the released artifact. All propagated, and the last one now has a script instead of a
  memory: `training/diff_intent_exam.py`.
- S7-A (the tournament module — SRS Module 6, FE-1…FE-8) — 013 created `tournaments`, `tournament_teams` and
  `fixtures` and **nothing had ever read them**; this wave adds migration 019, `utils/fixtures.js` (pure
  bracket/standings/waterfall math), `utils/fixtureSchedule.js` (the slot allocator), `services/tournamentService.js`
  (the only writer, 2.7k lines), `services/tournamentScheduler.js`, 12 routes at `/api/tournaments`,
  `jobs/tournamentJob.js` (6 background jobs now, not 4), three chip-only Scout actions, and the Flutter surface
  (browse · detail with a scrolling bracket · owner create with a LIVE economics preview · owner manage).
  DECISION — **the money model is a waterfall, not a percentage.** "Owner takes 30%" loses the owner money and
  the project's own numbers prove it: 8 × 2,000 = 16,000 of pool against ~7 hours of inventory worth ~14,000, so
  a 30% cut pays 4,800 for slots that would have sold for 14,000. So `venue_cost` (SUM of the fixtures' **real**
  `slots.price`, × `1 − venue_discount_percent`) is recovered FIRST, then `prize = surplus × prize_percent`
  (winner/runner-up 70/30) and the owner keeps `venue_cost + the rest`. PKR 4,000 × 8 over 7h@2,000 → owner
  **21,200 vs 14,000 for selling the same slots**, ~571/player. `POST /tournaments/preview` quotes it — including
  a recommended entry fee — before the tournament exists, and the **underwater guard** (pool < venue_cost → prize
  0, owner takes the pool) means money is never taken FROM the owner. Under `min_teams` 4 → cancel + refund all.
  DECISION — **a fixture reserves a slot, it does not create a booking.** Real `bookings` rows would drag in
  wallet holds and, fatally, `noShowJob` would sweep them and dock both captains' trust scores. So
  `fixtures.slot_id` + `status='blocked'`, and `PATCH /owner/slots/:id/unblock` now answers `409 fixture_reserved`.
  DECISION — **one ELO ladder, K by stakes** (friendly 32 · early 40 · semi 48 · final 56 · bye/walkover **0**).
  A second rating would seed the first bracket off all-1000s — brackets are seeded BY ELO — and 3 tournament
  matches make a meaningless rating. `applyResult` already took `kFactor` and `elo_history` already stored it, so
  this cost no refactor; "why does this count more" is `SELECT k_factor`. Four counters on `teams`
  (`tournament_played/wins/finals_reached/titles`) give the tournament record without a second number.
  AI, no retraining: ELO-seeded bracket + byes to top seeds (pure math), the Elo win-probability line (labelled
  as the formula, not as ML), and **trained model #1 re-used for scheduling** — `forecastDemand` puts early
  rounds in the owner's deadest hours and the final in the busiest, which lowers `venue_cost` (and so the entry
  fee) while protecting sellable peak inventory; `meta.scheduling.source = 'model' | 'chronological'` proves
  which ran. Scout gains 3 chip-only actions and **no new labels**, so model #4's 23-label release is untouched.
  THREE recon bugs fixed, not worked around: `tournament_teams.status` defaulted `registered` while
  `discoveryService` counted `accepted`, so **every capacity count in the app was 0**; `matches` had no
  `tournament_id` (added with `chk_matches_one_context` — a booking or a tournament, never both); and
  `MATCH_VIEW_FROM` reached venue/time through `bookings`, so tournament matches would have printed "Booking
  unavailable" on four screens — now COALESCEd from the fixture's slot.
  VERIFIED: `npm test` **128/128** with the DB down (42 new — the whole waterfall is a pure function on purpose)
  and `flutter analyze` **0**. NOT VERIFIED, and said so in TESTING.md §4.22 rather than ticked: **migration 019
  has never been applied** (needs the user's go-ahead; Supabase is the only DB), so `check_tournaments.js`,
  `seed_tournament_demo.js`, `verify_schema` 113→**174**, the S.2/S.6 no-regression runs, the scheduler A/B and
  the generated `doc/tournament_evidence.md` are all still owed. Steps 203-214 carry ⛔ NOT YET RUN with the
  blocker named. GOTCHA — `check_tournaments.js --evidence` WAS run once against Supabase before 019 existed,
  so `doc/tournament_evidence.md` exists as a **FAIL 2/3** stub carrying only its two rollback lines: proof the
  harness cleans up when it dies mid-way, not proof of a tournament. Regenerate it after 019; do not cite it
  until it reads `PASS n/n`.

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
