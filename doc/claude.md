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
  URI; `?sslmode=require` is optional — pool.js strips `sslmode` before pg parses
  it, because pg 8.20 reads `require` as `verify-full` and that OVERRIDES
  rejectUnauthorized:false → "self-signed certificate in certificate chain".
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
  admin approvals. Teams: create/roster/invites/roles/join + WhatsApp-style group
  chat are LIVE as of S2-A (real backend, was UI-only). ELO + matchmaking are the
  remaining S.2 waves — teams do not yet play matches.
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
  - C done — backend hardening: middleware/rateLimit.js (SEC-6 — 100/min per
    authenticated user, 20/min per anonymous IP, health exempt), morgan 'dev'
    logging, envelope closed on unknown routes (was HTML) + malformed JSON (was
    500), migration 012 indexes (only bookings(venue_id,slot_id) was missing),
    .env.example committed.
  - D done — FYP-2 foundation schema, migration 013 (spec said 010; 010 is taken).
    12 new tables for S.2-S.7 (team_invites/join_requests, matches/match_results/
    disputes/elo_history, tournaments/tournament_teams/fixtures, chat_channels/
    chat_messages, global_settings) + columns on teams/reviews/player_profiles/
    venues/users/notifications, 14 indexes. Spec's int/serial keys rewritten to
    UUID (all PKs here are UUID — it would have failed on the first CREATE TABLE);
    notifications ALTERed not recreated (CREATE IF NOT EXISTS would have silently
    skipped 010's table). NOT added: users.suspended (is_active is the flag,
    enforced auth.js:164) and notifications.read (is_read is the flag) — see
    PROGRESS.md "Wave D schema notes". global_settings seeded but wired to
    nothing; escrow.js stays the money source of truth. Also deleted the dead
    src/controllers/ directory (4 files, zero references, held a USE-3 leak).
  - F done — client plumbing + withdrawals + bug sweep. Central ApiClient
    (services/api_service.dart) attaches the JWT and maps every failure to a
    readable sentence; timeout is 45s until the first success of the session then
    10s, because a flat 10s fails every Render cold start. utils/num_util.dart
    asNum() replaces 11 hand-rolled DECIMAL parsers. Migration 014 adds
    `withdrawals` — a DELIBERATE single exception to "no schema past 013", since a
    pending request needs durable state; "one pending at a time" is a PARTIAL
    UNIQUE INDEX (23505 → 409), not a JS check. POST/GET/DELETE /api/wallet/
    withdraw(als) + GET /wallet/frozen (FR7.2, returns delta vs frozen_balance),
    withdrawalJob.js as the third sweep. Money leaves balance at REQUEST time;
    settlement moves nothing; cancel refunds with a NEW append-only row.
    SL_TEST_{AUTO_DECIDE,NO_SHOW,SETTLE}_MINUTES + SL_TEST_SWEEP_SECONDS make the
    timed rules demoable in 1 min — timings only, never money, loud boot banner.
    Shared withdraw/frozen/transaction-detail sheets; the shared txnLabel/txnIcon/
    fmtTxnDate fixed two live bugs (escrow_release + escrow_received had NO label
    or icon in either wallet screen, and every timestamp displayed 5h behind PKT
    for want of .toLocal()). Also: two screens lied about failure (empty list /
    "PKR 0" on error), the owner's Withdraw button was a stub, and 4 dead private
    classes in owner_wallet_screen were blocking flutter analyze.
  - E done — cloud demo deploy. api_constants.dart baseUrl now
    bool.hasEnvironment('API_BASE_URL') ? String.fromEnvironment(...) :
    10.0.2.2 — a physical phone ALWAYS needs --dart-define now (was a baked-in
    LAN IP). Three Wave-E spec blockers fixed: pool.js derived TLS from NODE_ENV
    alone (now also from sslmode= in the URL and from the host not being
    localhost, + 4 mapped connection-failure hints); seed_venues.js loaded .env
    from the WRONG DIR and built its own localhost/no-SSL Pool so it could never
    reach Supabase (now require('../db/pool'), plus a destructive pre-flight that
    counts and warns before it DELETEs that owner's venues/slots/bookings/txns);
    and the spec's "run schema.sql + migrations 001-010 in the SQL editor" would
    have DROPPED the live accounts — Supabase is the only DB, so step 2 verifies,
    never re-runs. package.json engines >=20 (bcrypt native build). server.js now
    sets trust proxy=1 behind Render, which rateLimit.js had asked for and nobody
    had done — without it all anonymous traffic shares one 20/min bucket.
    New docs: DEPLOY_GUIDE.md (11 steps, each with "what you should see", 15-row
    troubleshooting table) and S1_ACCEPTANCE.md (checklist audited row by row +
    manual test scripts). Render free tier sleeps: cold start ~30-50s AND all
    three setInterval sweeps stop while asleep — demo timed features locally.
  - post-E/F fixes (2026-08-21), against the REAL Supabase for the first time —
    .env had still been on localhost. pool.js: `?sslmode=require` BROKE the
    connection (pg-connection-string reads it as verify-full and that overrides
    ssl:{rejectUnauthorized:false}); stripSslMode() removes it after needsSsl()
    reads it, and the old hint "add ?sslmode=require" — which caused the error —
    is gone. This was a latent Render deploy blocker, since the guide told you to
    paste that flag into the dashboard. seed_venues.js deleted bookings without
    unwinding the escrow they held, stranding PKR 11,100 across 2 wallets and
    making /wallet/frozen's `delta` permanently non-zero; it now releases escrow
    with a `refund` row (booking_id NULL so the txn delete can't take it) BEFORE
    deleting, and reconcile_wallets.js repairs damage already done (dry-run
    default, recomputes drift INSIDE the txn under FOR UPDATE, never auto-fixes
    under-frozen). /wallet/frozen now itemises security_deposit as `escrow_held`
    (+ `slot_price`), not total_amount — total_amount showed 3,000 frozen when 900
    was. add_future_slots.js (new): all 1,725 slots were PAST so nothing was
    bookable and no acceptance script could run; set-based generate_series insert,
    idempotent via NOT EXISTS (slots has no unique key on venue/date/start),
    PKT-aware, non-destructive — 2,100 created, 1,990 bookable. Ledger now reads
    frozen 0.00 / owed 0.00 / delta 0.00. flutter analyze: 0 issues.
  - S2-A done — teams (create/roster/invites/roles/join) + WhatsApp-style group
    chat. migration 015 adds ONLY what 013 missed: ux_teams_name_sport (FR2.1,
    23505→409), idx_team_members_user (/mine was a seq scan), chat_channel_members
    (roles + the two tick watermarks), chat_messages media/reply/edit/delete/
    client_id columns, chat_reactions, users.last_seen_at, + a backfill giving every
    old team its channel. team_members.role is now authoritative for captaincy (NOT
    teams.captain_id — FR2.10 allows >1 captain; same call as elo_rating→elo).
    Invite tokens HASHED at rest (sha256, raw returned once), single-use under
    FOR UPDATE. routes/teams.js (16 eps) + routes/chat.js (7 eps): every mutating
    handler connect→BEGIN→work→COMMIT, finally-release, early exits ROLLBACK via
    bail(); authority re-read from team_members inside the locked txn
    (requireRole→lockTeam FOR UPDATE) so a forged {role} body is never trusted and
    the ≥1-captain rule can't be raced. Auth: create=any (cap MAX_TEAMS, 429),
    edit=captain, invites+requests=admin(captain|vice), role/remove=CAPTAIN, leave=
    any member. New utils: teamAccess.js (validateMediaUrl pins media to
    res.cloudinary.com+https ≤500 chars; squash strips control/bidi chars),
    chatCore.js (all writes go through it so denormalised last-message cols + socket
    fan-out can't drift; ensureTeamChannel idempotent under ux_chat_channels_type_ref),
    chatSystemMessages.js (structured system_meta, not frozen English). realtime/
    = Socket.IO on the existing HTTP server, rooms u:<id>/c:<id>, emits team:update/
    team:request/chat:message/receipt, consumes typing/message:read. Ticks = two
    per-member watermarks (last_read/delivered_at), group tick = MIN across OTHER
    members — marks, not O(msgs×members) receipt rows. delete-for-everyone STRIPS
    payload (body/media_url/media_mime/waveform→NULL), not a client-trusted hide.
    Flutter: models/team.dart + services/team_service.dart (asNum), 5 team screens
    wired to real backend, full chat (chat_screen/chat_controller/widgets/chat/ —
    day separators, ticks, typing, reactions, image via Cloudinary, optimistic
    reconcile by clientId, group-info one tap deeper like WhatsApp). find_opponents
    Challenge is an HONEST "arrives with matchmaking" snackbar, not a fake success.
    Acceptance passed live (2 accounts, full A-creates→invites→B-joins→promote→leave
    loop in the server log). DEFERRED as clean follow-ups: voice notes (kind:'audio'
    → "coming soon"; duration_ms/waveform already in schema) and reply-to
    (reply_to_id exists, no UI). flutter analyze: 0 issues; server boots clean.

## Docs
- PROGRESS.md = historical changelog, append per wave. API.md / DATABASE.md =
  refresh at milestone end.
- Known-stale docs, fix only when touched: README deposit wording
  ("full deposit"), any 12h-cancellation references.