# CLAUDE.md — SportLynk (FYP sprint)

## Project
Sports venue booking + team matchmaking app for Pakistan. Flutter (Android-first)
+ Node/Express + PostgreSQL on Supabase + (from S.3) Python FastAPI ml-service
with scikit-learn models. Final-year project: the committee requires GENUINELY
trained ML models — never replace them with external AI API calls.

## Run
- Backend: cd backend && npm install && node src/server.js → GET /api/health.
  Env in backend/.env (see .env.example).
- DB: Supabase is the ONLY database (dev + demo). DATABASE_URL = session-pooler
  URI + sslmode=require.
- App: flutter pub get → adb reverse tcp:3000 tcp:3000 →
  flutter run --dart-define=API_BASE_URL=http://127.0.0.1:3000/api
  (emulator: http://10.0.2.2:3000/api).

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

## Status
- DONE pre-sprint: OTP auth + profiles, venue search/detail/booking, QR check-in
  escrow, wallet + top-up, owner dashboard/slot calendar/scanner/analytics,
  admin approvals. NOTE: teams screens exist but are UI-ONLY (zero backend).
- REMAINING in order: S.1 stabilize+deploy → S.2 teams/ELO/matchmaking →
  S.3 ml-service + pricing model → S.4 sentiment + trust → S.5 recommender →
  S.6 NLU assistant → S.7 tournaments/chat/admin/demo pack.
- Wave log (append one line per completed wave):
  - (example: S1-A done — ledger unified 20%/24h, noShowJob + autoApproveJob)
  - S1-A done — escrow ledger unified (20% deposit / 24h window / 30-min no-show),
    src/utils/escrow.js + notify.js, migration 010, noShowJob rewritten +
    autoApproveJob added, ledger table in ARCHITECTURE.md, UI copy fixed.
  - B done — checkout slot locks revived (ER1.5/FR3.7): migration 011 adds
    slots.locked_by/locked_until, POST+DELETE /api/slots/:id/lock (5-min TTL,
    refresh on re-tap, 409 to others), LAZY expiry so no sweep job, derived
    effective_status paints Blue "held" in the player grid + owner calendar,
    player grid auto-refreshes every 30s.

## Docs
- PROGRESS.md = historical changelog, append per wave. API.md / DATABASE.md =
  refresh at milestone end.
- Known-stale docs, fix only when touched: README deposit wording
  ("full deposit"), any 12h-cancellation references.