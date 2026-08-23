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
  chat are LIVE as of S2-A (real backend, was UI-only). ELO + matchmaking are LIVE
  as of S2-B/S2-C — teams challenge each other on a confirmed booking, both
  captains report, the venue owner verifies, ratings move. Rankings, team stats
  and the ELO history chart are LIVE as of S2-D. **S.2 (A-D) is complete.**
- REMAINING in order: S.3 ml-service + pricing model → S.4 sentiment + trust →
  S.5 recommender → S.6 NLU assistant → S.7 tournaments/chat/admin/demo pack.
  (S.7 owns the admin dispute-resolution UI; the backend rule blocking ELO on a
  disputed match is already in place.)
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
  - S2-B done — ELO engine + global settings. src/utils/elo.js has NO database
    import on purpose: expected() / newRating() / rate() / competitiveness() are
    provable without a connection, and applyResult() takes a client instead of
    opening one so the exchange runs INSIDE the caller's transaction. A verified
    result writes both teams' elo (+ legacy elo_rating in lockstep), W/L/D, and
    exactly two elo_history rows netting to zero — same commit as the status change.
    A team is Unranked until ≥1 verified match (FR2.6): the API sends ranked:false
    and displayElo:null and the UI prints "Unranked", never the seed 1000 — on a
    fresh install that is EVERY team, so it is the common path, not an edge case.
    globalSettings.js is the first reader of the global_settings table 013 created
    and nothing used: cached, never throws, falls back to DEFAULTS (base 1000,
    k 32, 48h TTL, 24h dispute window, 30%/min-3 freeze) so policy is a row you
    edit, while a malformed row can never take matches offline. test/elo.test.js =
    10 tests via `npm test` (node --test, no new dep): symmetric exchange, upset
    pays more, draw moves toward the lower-rated side, K respected, 400 = 10:1,
    outcomeFor THROWS on a team not in the match (a silent 0.5 there would rate the
    wrong pairing). Writing the tests found a real bug: applyResult shared one
    placeholder between elo and elo_rating → 42P08, every verification would have
    failed. 10/10 pass.
  - S2-C done — matchmaking end to end. migration 016 (applied, 25/25 verify
    checks): the invariants a JS pre-check cannot hold live in the DB —
    ux_matches_booking_live is a PARTIAL unique index (one live match per booking,
    so two simultaneous challenges on one slot can't both win),
    match_results_match_id_submitted_by_team_key (013's inline UNIQUE, so Postgres
    named it) enforces one submission per team (ER2.1), chk_matches_
    status is the state machine's third copy (doc/API.md is authoritative,
    matchCore.STATUS is the code's — all three must agree). routes/matches.js = 11
    endpoints under four rules: the body is never authority (the team you may act
    for is re-read from team_members inside the locked txn — a forged
    challengerTeam gets 403); lock then decide (without lockMatch, two captains
    submitting in the same instant both conclude they are not the second and leave
    the match stuck in `accepted` with two results and nobody to advance it); a
    return never leaves an open transaction (finally releases, early exits bail());
    emit after COMMIT (a socket fired inside the txn tells the client to re-read a
    row that isn't durable, and it reads the old one). matchCore.js holds the shared
    view/lock/shape/fan-out layer so the route reads as the state machine only.
    Competitiveness = round(100 − (min(|Δ|,400)/400)×95), snapshotted at challenge
    time, and NULL — not 50, not 0 — when either side is unranked. matchPreview.js
    is template NLG over real features (gap, last-5 form, streak, win rates), pure,
    and the honest label ships from the SERVER (previewLabel:'Preview') so a future
    screen can't quietly upgrade it to "AI prediction". matchExpiryJob is the 4th
    sweep; expiry is ALSO enforced on read, because a late job must never decide
    whether a transition is valid. Conflicting submissions → disputed + a SYSTEM
    dispute row with raised_by_team NULL so it counts against neither team's ratio;
    >30% over ≥3 matches freezes a rating platform-wide (ER2.3) — the match still
    completes and records W/L, but no points move and the response says so. The
    venue owner has NO score field: ownership is checked in SQL (v.owner_id=$1) and
    verify only confirms what two captains already agreed; adjudication is S.7's,
    and an override here would make the agreement gate decorative. match:update
    carries only ids — one emit reaches both rosters AND the owner, whose read
    permissions differ, so every client re-reads through the gated endpoint and the
    socket can't become a way around a read gate. Flutter: models/match.dart +
    services/match_service.dart, widgets/match_widgets.dart (one home for every
    match visual so a competitiveness bar can't read green on one screen and amber
    on the next — gauge is real CustomPaint, a zero ELO delta reads "Frozen"/"No
    change" never "+0"), find_opponents rewritten to the real endpoint (sport chips
    gone because the endpoint is pairing-relative and the backend refuses
    cross-sport — WHICH of my teams plays now picks the sport; defaults to a team I
    captain, since canChallenge is captain-only and a screen of disabled buttons
    reads as broken), match_challenge_screen (VS + gauge + comparison + preview +
    the booking picker, which is the RULE not a convenience), match_center_screen
    (Challenges/Upcoming/History with countdowns, ±ELO and the 24h dispute flag —
    reached from a team row and the chat header, not a global tab that would have to
    ask "which team?"), match_result_dialog (scores held challenger-first in the
    match's own orientation even though drawn viewer-first, so the two submissions
    are comparable in the DB), owner_match_verify_screen + a "Match results to
    verify" card on the owner dashboard that appears live and hides when empty.
    Gap found while wiring Upcoming: the list shipped resultsIn (a count) but
    nothing viewer-scoped, so at resultsIn==1 the app offered a Submit button that
    could only 409 — matchCore now aggregates submitted_teams and shapeMatch
    derives iSubmitted, which answers ONLY whether my side is still owed one, so it
    never leaks the opponent's submission. run_match_flow_check.js = 69/69 over real
    HTTP (happy path, conflict, dispute, authority, idempotency, 48h sweep releasing
    the booking) and it SEEDS the two-phone fixture. flutter analyze 0 issues;
    npm test 10/10; server boots clean with all four jobs.
  - S2-D done — rankings, team stats, ELO history chart. ZERO schema: every column
    read here was created by 013/016 and is already written by the verify path.
    src/utils/teamStats.js (own file — teams.js was already the biggest route file)
    holds three reads. GET /teams/rankings is ranked-only (FR2.6): it used to list
    every public team ordered by elo, i.e. brand-new teams on the board at the
    untouched 1000 seed, and the ≥1-verified-match threshold is now bound as a query
    PARAMETER read from elo.RANKED_MIN_MATCHES so the board and a profile can't
    disagree about who counts. Rank movement is COMPUTED, not stored — no snapshot
    table, no nightly job to rot: elo_history.elo_before of a team's oldest change in
    the 7-day window IS the rating it held then, so a second row_number() over that
    column reconstructs the old position in one statement; movement NULL ("not on the
    board then") is kept distinct from 0 ("held its place") so the UI draws NEW
    instead of inventing a climb. City chips come from the SAME query as the rows and
    are deliberately NOT city-filtered, so a chip can't collapse the row you tapped
    or lead to an empty screen — teams.city is still mostly NULL, so it degrades to
    no chip row rather than to dead chips. is_mine is answered by the SERVER because
    only the server knows the viewer; the screen had been inferring it from a `role`
    field this endpoint never sent, so FR5.13's highlight could never appear. GET
    /teams/:id gained stats + eloHistory (added to the existing read, so opening a
    team is still ONE request); profileStats() reuses matchCore.teamFeatures() for
    the last-5 form rather than re-deriving it, and is the single point where the two
    live casing conventions meet (teams.js snake_case ← matchCore camelCase).
    eloSeries() drives off `matches` LEFT JOINing elo_history, not the reverse: a
    disputed match has no history row by design, so reading history alone would drop
    exactly the points FR5.14 wants drawn in red; unrated points carry the last known
    rating forward (zero would read as a collapse) and ship rated:false separately
    from disputed, so a frozen team is never mislabelled. Flutter: models/
    team_stats.dart (RatingDisplay mixin spells "Unranked" once; headline gives
    FR5.16's `Won 2–1`; deltaLabel returns null, never "+0"), widgets/
    team_stat_widgets.dart (RatingText is the ONLY widget allowed to print a rating —
    reading team.elo directly is exactly how the board ended up showing the seed —
    plus MovementBadge/FormRow/StatTile/EloHistoryChart/MatchHistoryTile),
    team_rankings_screen rebuilt (city chips styled from find_venues_screen, YOU
    highlight, movement per row, freeze snowflake, tap through to the profile; hero/
    medals/subtitle kept — a rebuild of the data, not the look), team_roster_screen is
    now a profile (win rate FR5.15, form + 30d activity, chart, match history
    NEWEST-first because a list reads from the top and a chart from the left).
    FR5.14's dots are literal — solid green verified, hollow red disputed — plus a
    third the data demands: hollow grey for verified-but-frozen, so ER2.3 isn't
    redrawn as a dispute. rankings() returns RankingsPage? where NULL = request
    failed and empty = board genuinely empty; the first version returned an empty
    page for both, which would have printed "No ranked teams yet" during every
    outage. Fixed the last FR2.6 seed leak (roster header printed ELO 1000 for a team
    that never played) and gated Leave-team + the role==null auto-pop, since the
    board can now open a team you don't belong to. fl_chart ^0.69.0 is the one new
    dep; the chart compiles on 0.69 AND 1.x (tooltipRoundedRadius→tooltipBorderRadius
    is the only renamed property used, so it's left at default) because the local pub
    cache has 1.1.1/1.2.0 but not 0.69.0. Also closed a silent data loss found while
    checking the chips: PATCH /teams/:id validated bio/visibility/logo only and dropped
    the city the Dart client was already sending, so the city filter could never have
    data — now written via `city = CASE WHEN $4::boolean THEN $5 ELSE city END` (absent
    key keeps, '' clears) with a CITY field in the captain's edit sheet, and rankedCities
    groups by lower(btrim(city)) so "Lahore"/"lahore" is one chip. VERIFIED: flutter pub
    get resolved fl_chart 0.69.2 and flutter analyze = 0 issues (fixed a dangling library
    doc comment and unnecessary_underscores to get there). NOT VERIFIED: node --check,
    server boot, npm test, run_match_flow_check.js — the shell refused every backend
    invocation. Those were verified by reading ($1..$6 alignment, route order: /rankings
    is declared before /:id, GROUP BY/aggregate pairing). Backend code-complete and
    read-verified, not test-verified — those four are in the user's manual-steps list.

## Docs
- PROGRESS.md = historical changelog, append per wave. API.md / DATABASE.md =
  refresh at milestone end.
- Known-stale docs, fix only when touched: README deposit wording
  ("full deposit"), any 12h-cancellation references.