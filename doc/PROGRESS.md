# Daily Progress Log

## Day 1
Completed:
- [x] PostgreSQL local installed
- [x] Supabase project created
- [x] Both databases have schema
- [x] Node.js backend initialized
- [x] Flutter project created
- [x] 7 context MD files created
- [x] Auth backend (register + login) working
- [x] Auth Flutter screens (Welcome, Register, Login) working

## Day 2
Completed:
- [x] Database migration v2 (email nullable, phone_verified, owner_profiles expanded, OTP log)
- [x] Firebase Auth integrated (mock OTP service for demo, real implementation ready)
- [x] Backend auth routes completely rewritten:
  - POST /api/auth/register/player (phone-verified registration)
  - POST /api/auth/register/owner (3-step with CNIC/ground/docs)
  - POST /api/auth/login (phone OR email identifier)
  - POST /api/auth/verify-phone
  - POST /api/auth/forgot-password/send-otp
  - POST /api/auth/forgot-password/reset
  - GET /api/auth/me (updated with avatar_url)
- [x] Flutter foundation layer created:
  - AppColors with full palette (inputFill, warning, border, success)
  - SportTextField reusable input widget
  - PasswordStrengthBar (6-criteria, animated)
  - PhoneField (Pakistani validation, OTP verification flow)
- [x] All auth screens built:
  - WelcomeScreen (dark gradient + white bottom sheet, Player/Owner buttons)
  - LoginScreen (curved header, phone/email identifier, forgot password)
  - PlayerRegisterScreen (avatar, phone OTP, password strength, all validators)
  - OwnerRegisterScreen (3-step: Personal → Ground → Documents)
  - OtpScreen (6-digit input, countdown, auto-advance)
  - OwnerPendingScreen (animated icon, status checklist)
  - ForgotPasswordScreen (phone → OTP → new password)
- [x] AuthProvider updated (registerPlayer, registerOwner, login with pending status)
- [x] AuthService updated (all new endpoints)
- [x] ApiConstants updated (all new routes)
- [x] main.dart routes updated
- [x] Old register_screen.dart deleted
- [x] flutter analyze: 0 issues

## Day 3
Completed:
- [x] Prompt C — WelcomeScreen fully rewritten:
  - Scaffold bg: AppColors.primary
  - Top 55% dark section with CircleAvatar (white bg, sports_soccer icon)
  - RichText "Sport" + "Lynk" branding
  - Bottom 45% white sheet (AppColors.background) with 32px radius
  - CustomButton "🏃  I am a Player" → /register/player
  - CustomButton "🏟️  I own a Venue" → /register/owner (outlined)
  - GestureDetector "Log In" link → /login
- [x] Prompt C — LoginScreen fully rewritten:
  - Stack with 200px gradient header (#0A1F13 → #166534, rounded bottom 32)
  - Semi-transparent CircleAvatar with soccer icon
  - "Welcome Back" / "Sign in to continue" text
  - Layer 2 white card at top:160
  - Phone/Email field + Password field with visibility toggle
  - Forgot Password link → /forgot-password
  - Consumer<AuthProvider> inline login with isPendingOwner check
  - RichText "Don't have an account? Sign Up" link
- [x] Prompt D — OtpScreen fully rewritten:
  - 6-digit OTP boxes with auto-advance
  - Auto-submit on last digit
  - 60-second countdown timer with Resend OTP
  - Masked phone display (+92-XXX-XXXX...)
  - FirebaseOtpService integration
  - SnackBar error handling
- [x] Prompt D — PlayerRegisterScreen fully rewritten:
  - Avatar picker with camera overlay (ImagePicker gallery)
  - "Player Account" chip
  - Inline phone field + Verify button → OTP screen
  - Verified state with green checkmark chip
  - Full Name, Email (optional), Password, Confirm Password fields
  - PasswordStrengthBar integrated
  - All validators complete per spec
  - Consumer<AuthProvider> create account (disabled until phone verified)
  - Warning text "Verify your phone number first"
  - "Already have account? Log In" link
- [x] flutter analyze: 0 issues

## Day 4
Completed:
- [x] Hardened Auth Flow: Implemented `devMode` for OTP bypass during testing.
- [x] Cloudinary Integration: Upload player avatars and owner documents to Cloudinary, saving secure URLs to DB.
- [x] Fixed `player_register_screen.dart` confirm password real-time validation and visibility toggle.
- [x] Professional UI redesign for PhoneField (removed disabled grey background, inline verified badge).
- [x] Modern UI redesign for LoginScreen (centered, clean white layout, logo focus, removed heavy gradient).
- [x] Redirect `/login` after successful player registration.
- [x] Resolved all compile errors and `cloudinary_public` versioning issues.
- [x] flutter analyze: 0 issues (only minor unused import/print warnings fixed).

## Day 5
Completed:
- [x] Context built (notes saved at .agent_notes.md)
- [x] Fixed backend pool.js destructuring bug in users/wallet/bookings/venues/player routes
- [x] Added backend POST /api/users/me/change-password (bcrypt verify+rehash)
- [x] Updated PATCH /api/users/me/update to accept avatarUrl
- [x] Added migration 001_fix_schema.sql to ensure venues columns + bilal wallet seed
- [x] Restricted sports to Football+Cricket in profile + home + register
- [x] Redesigned player_profile_screen: Insta-style edit, avatar pick+upload, change password section
- [x] Updated home QuickActions: Football, Cricket, My Bookings, Wallet (no badminton/all)
- [x] Implemented find_venues_screen per PROMPT_3
- [x] Implemented venue_detail_screen per PROMPT_3
- [x] Implemented confirm_booking_screen per PROMPT_3
- [x] Replaced bookings_screen with cancel + refund per PROMPT_4
- [x] Replaced wallet_screen with topup sheet + history link per PROMPT_4
- [x] Implemented wallet_history_screen per PROMPT_4
- [x] Added User.copyWith avatarUrl + auth_provider updateLocalUser avatarUrl
- [x] Ran flutter analyze - 0 errors
- [x] Updated md docs: API.md, DATABASE.md, PROJECT.md, FEATURES.md, PROGRESS.md, ARCHITECTURE.md, CODING_STANDARDS.md.

## Day 6 (Phase 2 Finalization)
Completed:
- [x] Fixed backend `venues.js` SQL param bug that broke filtering.
- [x] Fixed backend `users.js` profile save 500 error (email uniqueness logic).
- [x] Fixed `venue_detail_screen` crash (`toStringAsFixed` on String via PostgreSQL `DECIMAL`).
- [x] Fixed `confirm_booking_screen` wallet balance parsing bug.
- [x] Fixed web splash screen to use SportLynk logo instead of default Flutter logo.
- [x] Redesigned `find_venues_screen` with advanced filter bottom sheet (price range, minimum rating, sort by).
- [x] Redesigned `venue_detail_screen` with gradient hero, animated date/slot selection, and professional cards.
- [x] Implemented Teams feature (UI Only) via 5 new screens: `teams_screen.dart`, `create_team_screen.dart`, `team_roster_screen.dart`, `find_opponents_screen.dart`, `team_rankings_screen.dart`.
- [x] Wired Teams feature into `player_home_screen.dart`.
- [x] Resolved unused imports; `flutter analyze` shows 0 issues.

## Day 7 (Phase 4 Finalization)
Completed:
- [x] Backend migration: Added `amenities` (JSONB) to venues and `temporarily_locked` to slots enum.
- [x] Database seed updated: 20 synthetic venues with random slot statuses, peak pricing, and amenities.
- [x] Escrow Payment Logic: `bookingController.js` updated so 30% deposit is deducted from player and added to owner's `frozen_balance`.
- [x] Performance: Optimized Flutter web splash screen initialization.
- [x] UI Redesign (Home): Converted `player_home_screen` to a professional 2x2 grid layout.
- [x] UI Redesign (Find Venues): Horizontal AI-Recommended scrolling cards and structured nearby venue lists.
- [x] UI Redesign (Venue Details): Horizontal Image Gallery (PageView), Amenities check grid, 12-hour AM/PM time formatting, and dynamic color-coded slot statuses.
- [x] UI Fixes: Patched substring null-safety crashes in `confirm_booking_screen` and aligned UI deposit calculation with backend (30%).
- [x] `flutter analyze`: 0 issues.

## Day 8 (Phase 5 — Full Functional Overhaul)
Completed:
- [x] Backend: Unified slot management on the `slots` table, deprecating `venue_slots`.
- [x] Backend: Implemented real-time slot locking via `slotLock.js` with 5-minute TTL.
- [x] Backend: Implemented true Escrow flow (30% deposit freeze in owner's wallet) in `bookings.js`.
- [x] Backend: Rewrote `seed_venues.js` with professional Unsplash photo sets, dynamic operating hours, and realistic amenities.
- [x] Flutter: Redesigned `venue_detail_screen` with a functional PageView gallery, better badge positioning, and integrated slot locking logic.
- [x] Flutter: Updated `confirm_booking_screen` to reflect the 30% deposit-only payment flow with accurate balance calculations and breakdowns.
- [x] Flutter: Implemented AI recommendations in `find_venues_screen` based on player sport preferences.
- [x] Flutter: Fixed navigation routes in `main.dart` for Tournaments, Find Opponents, and Team Rankings.
- [x] Flutter: Created `tournaments_screen.dart` with professional "Coming Soon" UI.
- [x] Cleanup: Deleted 6 legacy prompt and duplicate files (~170KB removed).
- [x] Documentation: Updated `DATABASE.md`, `API.md`, and `FEATURES.md` with escrow and locking details.
- [x] `flutter analyze`: 0 issues.

## Day 9 (Finalizing Player Interface & Stabilization)
Completed:
- [x] UI UI: Perfected `player_home_screen` search bar to securely overlap the header grid.
- [x] Backend: Fixed `bookings.js` cancellation timestamp math to flawlessly enforce the 12-hour penalty policy without UTC date shifts.
- [x] Backend: Reset and debugged DB `wallets` table to fix double-money frozen_balance mismatches.
- [x] Backend: Upgraded `venues.js` to dynamically filter out passed slots using PKT time checking.
- [x] Flutter: Repaired `bookings_screen`, `player_home_screen`, and `confirm_booking_screen` to correctly format ISO dates without offsetting the day in local time.
- [x] Documents: Initiated massive rewrite of MD guides for transitioning into Phase 5 (Owner screens).
- [x] `flutter analyze`: 0 issues.

## Day 10 (Phase 5 Complete — Owner Interface + System Stabilization)
Completed:
- [x] Backend: Completely overhauled `owner.js` with all required endpoints: dashboard, bookings (with trust_score), approve/reject with refund, slots, block/unblock, scan-qr (atomic escrow transfer), no-show penalty, venue details, analytics.
- [x] Backend: Fixed `bookings.js` — removed slot locking, changed booking status to `pending`, added `owner_id` column, used `FOR UPDATE` for atomic race-condition handling.
- [x] Backend: Created and auto-ran migration `007_owner_booking_updates.sql` (escrow enum types, bookings columns backfill).
- [x] Backend: Auto-migration runner script `run_migration_007.js` created and executed successfully (8/8 statements).
- [x] Flutter: Full Owner Interface — 6 screens: `owner_home_screen`, `owner_booking_requests_screen`, `owner_slot_calendar_screen`, `owner_qr_scanner_screen`, `owner_venue_screen`, `owner_profile_screen`.
- [x] Flutter: Owner Home Dashboard — dark gradient, greeting, stats row (revenue/bookings/pending), AI price suggestion card, wallet card with frozen balance, next bookings list.
- [x] Flutter: Booking Requests — 3 tabs (Pending/Confirmed/Rejected), trust score badges, auto-approve notice, approve/reject actions.
- [x] Flutter: Slot Calendar — month grid, slot status rendering (AVAILABLE/BOOKED/BLOCKED/PAST), block/unblock toggle.
- [x] Flutter: QR Scanner — dark theme, live camera, 30-min countdown timer, manual entry mode, success dialog with payment receipt, no-show flow.
- [x] Flutter: Venue Operations — revenue chart (bar graph), image gallery, venue details, financials.
- [x] Flutter: Player Booking Detail — status banner, QR code display (grey when checked_in), pending approval info, cancel button.
- [x] Flutter: Removed slot locking from `venue_detail_screen` — instant selection, no timer, no lock API calls.
- [x] Flutter: Booking cards now tap-navigable to `/booking-detail`.
- [x] Flutter: Redesigned Player Home — clean header (no overlap), icon-based quick actions (no missing image assets), stats strip (bookings/balance/trust score), separated search bar.
- [x] Flutter: Fixed change password validation — same-as-current check, uppercase requirement, number requirement.
- [x] Flutter: Fixed AppBar headers — all screens use `AppColors.primary` background with `Colors.white` text.
- [x] Created `lib/constants/app_colors.dart` (re-exports `colors.dart` for compatibility).
- [x] Deleted 13 useless files (debug scripts, old migrations, one-time prompt files, agent notes).
- [x] Updated all 7 MD documentation files.
- [x] `flutter analyze`: 0 issues.

## Wave S1-A (Money & policy alignment — escrow ledger unified)
Completed:
- [x] Backend: New `src/utils/escrow.js` — the single source of truth for money policy (`DEPOSIT_PERCENT=20`, `CANCELLATION_WINDOW_HOURS=24`, `NO_SHOW_GRACE_MINUTES=30`, `NO_SHOW_TRUST_PENALTY=10`, `AUTO_DECIDE_AFTER_HOURS=2`) plus `asNum`/`round2`/`depositFor`/`penaltySplit`/`hoursUntilSlot`/`isLateCancellation` and the shared `lockWallet`/`applyWallet`/`logTxn` primitives.
- [x] Backend: New `src/utils/notify.js` — writes `notifications` rows inside a `SAVEPOINT`, so a notification failure can never abort a money transaction.
- [x] Backend: Migration `010_escrow_policy_alignment.sql` + `run_migration_010.js` — adds `bookings.deposit_amount` (backfilled to 20% of price), `no_show_processed`, `no_show_at`, `approved_at`, `auto_decided_at`; adds the `rejected` value to the `booking_status` enum; creates the `notifications` table; sets `venues.upfront_percent` to 20; adds two sweep indexes. The runner splits on `-- @@SPLIT@@` because `ALTER TYPE ... ADD VALUE` cannot share a multi-command string.
- [x] Backend: Deposit is now 20% of price **everywhere** and is computed server-side only — `PATCH /api/owner/venues/:id` no longer accepts `upfront_percent` from the client.
- [x] Backend: `bookings.js` — `POST /` escrows the full slot price (no more `paymentType`/discount branches); `PATCH /:id/cancel` uses the 24h window (≥24h full refund, <24h 80/20 split with an owner credit + notification); `POST /:id/resolve` no longer double-pays an already-checked-in booking.
- [x] Backend: `owner.js` — approve/reject/scan-qr/no-show all run in one transaction with `FOR UPDATE OF b` and locked wallets; reject sets the new `rejected` status with a full refund; the rejected tab lists `rejected` + `cancelled`; analytics counts a no-show as the 20% deposit only.
- [x] Backend: `noShowJob.js` rewritten — 5-minute sweep for `confirmed` bookings whose slot started >30 min ago with no check-in → 80/20 ledger + `trust_score -10` + notifications for both parties, guarded by `no_show_processed`. The owner's manual button remains an early trigger for the identical move.
- [x] Backend: New `autoApproveJob.js` (FR4.10) — 5-minute sweep: pending >2h with the slot still >2h away → auto-confirm (no money moves); slot starting within 2h and still unapproved → auto-reject + full refund. Registered in `server.js`; both jobs log every sweep.
- [x] Flutter: `confirm_booking_screen` — removed the 30%-upfront payment selector (it disagreed with the server), replaced with a "Payment (held in escrow)" breakdown (slot price / amount escrowed / 20% at-risk deposit) and 24h cancellation copy.
- [x] Flutter: `player_booking_detail_screen` — 24h + 80/20 cancel dialog copy, `rejected` status colour/icon/title/subtitle, "Amount Held in Escrow" label.
- [x] Flutter: `bookings_screen` — `rejected` bookings now land in the Past tab and get a status colour.
- [x] Flutter: `help_support_screen` — escrow + 24h cancellation FAQ rewritten.
- [x] Flutter: `owner_venue_management_screen` — the editable "Upfront Booking Percentage" field is replaced by a read-only escrow-policy note (deposit is platform policy, not owner-configurable).
- [x] Docs: `ARCHITECTURE.md` now carries the authoritative 7-row escrow ledger table + the policy-constant table; `DATABASE.md` escrow flow refreshed to 20%/24h/30-min; `README.md` cancellation wording fixed.
- [x] `flutter analyze`: 0 issues.

## Wave B (Checkout slot locks — SRS ER1.5, FR3.7)
Completed:
- [x] Backend: Migration `011_slot_locks.sql` + `run_migration_011.js` — adds `slots.locked_by UUID` and `slots.locked_until TIMESTAMPTZ`, releases any legacy `temporarily_locked` rows back to `available`, and adds a partial index on `locked_until`. (Migration `010` was already shipped in Wave S1-A, so this is `011` rather than folded into it.)
- [x] Backend: A checkout hold lives **only** in `locked_by`/`locked_until` — `slots.status` stays `'available'` for the whole hold. So every pre-existing `WHERE status='available'` path (booking claim, owner block/unblock, slot generation) keeps working untouched, and expiry is **lazy**: a hold whose `locked_until` has passed is indistinguishable from free, costing zero writes. No sweep job was added because none is needed, and a crashed client can never strand a slot.
- [x] Backend: `src/routes/slotLock.js` revived — `POST /api/slots/:id/lock` takes a 5-minute hold inside a transaction with `SELECT … FOR UPDATE`; 404 if the slot is gone, 409 if it is already booked/blocked, 409 if another player is mid-checkout. The same player re-tapping **refreshes** the hold instead of being refused, and taking a hold releases that player's other holds at the same venue (one checkout at a time). Returns `{ slotId, lockedUntil, expiresInSeconds }`.
- [x] Backend: `DELETE /api/slots/:id/lock` — releases the caller's own hold. Best-effort by design: "there was nothing to release" is a success (`released:false`), because the client fires this on the way out of checkout and must never be blocked by it.
- [x] Backend: `venues.js` — `GET /api/venues/:id` derives the paint state per request via a shared `slotColumns()` helper: `is_locked`, `locked_by_me` (so a player can still select the slot they are holding), and `effective_status` (`'locked'` when available-but-held). Replaced the old 2-minute `temporarily_locked` sweep that ran inside the read.
- [x] Backend: `owner.js` — `GET /api/owner/slots` exposes the same `is_locked` / `effective_status` so the owner calendar can show a slot as held while a player is in checkout.
- [x] Backend: `bookings.js` — the slot claim now uses `FOR UPDATE OF s` and returns 409 `"Another player is checking out this slot."` when the hold belongs to someone else; creating a booking clears the hold, and cancelling frees the slot with the hold cleared too. The row lock is still what actually settles simultaneous bookings — the hold is the courtesy layer on top.
- [x] Flutter: `venue_detail_screen` — slot selection now round-trips through the lock API (tap = take hold, tap again = release), guarded against double-taps with a per-tile spinner. Grid keys off `effective_status`, so an expired hold needs no client-side clock. The tile turns **Blue "HELD"** per the SRS colour code (Green available · Amber booked · Red blocked · Blue held); legend renamed from "Temp Locked" to "Held".
- [x] Flutter: `venue_detail_screen` — FR3.7 auto-refresh: `Timer.periodic` every 30s while the grid is open, cancelled in `dispose()` and paused while the confirm-booking screen is on top. If a refresh reveals the held slot was taken, the selection is dropped and the player is told. Leaving the screen releases the hold best-effort (`dispose()` uses a token cached in `initState` so it never reads a provider off a dead `context`).
- [x] Flutter: `owner_slot_calendar_screen` — held slots render Blue "HELD" with a "PLAYER IN CHECKOUT" row label, and are deliberately not blockable until the hold clears.
- [x] Acceptance (two accounts, 29/29 assertions): A holds → B's grid read returns `effective_status:'locked'`/`is_locked:true`/`locked_by_me:false` while A's returns `locked_by_me:true` → B gets 409 on both booking and lock-stealing → A re-tapping pushes `locked_until` out → an expired hold reads `available` again with no writes → `DELETE /lock` releases (and is a no-op success when repeated or called by a non-holder) → booking clears the hold → cancelling frees the slot with wallets net zero.
- [x] `flutter analyze`: 0 issues. Server boots clean.

## Wave C (Backend hardening — SEC-6, USE-3)
Completed:
- [x] Backend: New `src/middleware/rateLimit.js` (SEC-6) — `express-rate-limit` with two tiers in one limiter: **100 req/min per authenticated user**, **20 req/min per anonymous IP**. Because the limiter runs before `authMiddleware`, it peeks at the bearer token itself (memoised on the request, so `jwt.verify` runs once) to pick the bucket and the quota. Counting logged-in traffic per user rather than per IP matters in Pakistan specifically: a whole team on one café's Wi-Fi shares an IP and would otherwise be locked out together. A token that fails verification counts as anonymous, so a brute-forcer gets 20/min, not 100.
- [x] Backend: `/api/health` is exempt from the limiter — throttling it would make the API look down exactly when someone (or the S.7 admin health panel) is checking whether it is. IPv6 keys go through `ipKeyGenerator`, which collapses to a /56 so a client can't rotate through its own address range to reset the counter. `standardHeaders: 'draft-7'` on (`RateLimit`, `RateLimit-Policy`), legacy `X-RateLimit-*` off.
- [x] Backend: `server.js` — `morgan('dev')` request logging, mounted **above** the limiter so throttled requests still appear as 429s (those lines are the signal a client is misbehaving). The limiter itself sits **before** `express.json()`, so a flood costs no body parsing.
- [x] Backend: Error envelope audit (USE-3). Every route's `catch` already funnelled to `next(e)` → the generic handler, so no route leaked SQL. Two real gaps were closed: an **unknown path** returned Express's default **HTML error page** (now `404 {success:false,message:'Route not found'}`), and a **malformed JSON body** returned **500** (now `400 'Malformed JSON body'`). The global handler now also honours `err.status` instead of forcing 500, and maps `entity.too.large` → 413; the full error (SQL text, constraint names, stack) is logged server-side only and the client only ever receives one of a fixed set of sentences — nothing derived from `err.message` crosses the wire.
- [x] Backend: Migration `012_hardening_indexes.sql` + `run_migration_012.js`. Three of the four requested indexes already existed, so only **`bookings(venue_id, slot_id)`** was actually created; `bookings(player_id, status)` and `transactions(user_id, created_at DESC)` were already present under the exact requested definitions, and `slots(venue_id, slot_date)` is already covered by the wider `(venue_id, slot_date, status)` whose leading columns are exactly the requested pair. All four are restated `IF NOT EXISTS` **under the names they already carry**, so re-running is a genuine no-op and no duplicate index is created under a second name. The runner diffs `pg_indexes` before/after and reports created vs. already-present.
- [x] Backend: `.env.example` committed and every variable documented — `DATABASE_URL` (Supabase session pooler + `sslmode=require`, with a note on why the pooler host and not `db.<ref>`), `JWT_SECRET` (with the generate-one command), `PORT`, `NODE_ENV`, `ML_SERVICE_URL` + `ML_API_KEY` (S.3, not read yet), `FIREBASE_PROJECT_ID`/`FIREBASE_CLIENT_EMAIL`/`FIREBASE_PRIVATE_KEY` (Admin SDK placeholders — phone OTP is still client-side only), plus the five legacy local-Postgres `DB_*` vars marked as unused. Confirmed `.env.example` is not gitignored and `.env` still is.
- [x] Verification (34/34 assertions): user A allowed exactly 100 then 429 while user B is unaffected; anonymous IP allowed exactly 20; 40/40 health probes pass while both buckets are exhausted; forged and expired tokens fall to the anonymous tier; a real pg `22P02` surfaces as `500 'Internal server error'` with no SQL/driver/stack text in the response; morgan logs 200/400/404/429/500 with timings; all four indexes exist and `EXPLAIN` (with `enable_seqscan=off`, since `bookings` has only 9 rows and rightly seq-scans today) confirms the planner can use each one for its intended predicate.
- [x] Server boots clean, no middleware warnings.

## Wave D (FYP-2 foundation schema — migration 013)
Completed:
- [x] Backend: `migrations/013_fyp2_foundation.sql` + `run_migration_013.js`. Lands every table milestones S.2 → S.7 need in one pass, so those waves only write code, never schema. **12 new tables** — `team_invites`, `team_join_requests`, `matches`, `match_results`, `disputes`, `elo_history`, `tournaments`, `tournament_teams`, `fixtures`, `chat_channels`, `chat_messages`, `global_settings` — plus new columns on `teams`, `reviews`, `player_profiles`, `venues`, `users` and `notifications`. Nothing reads any of it yet; that is deliberate.
- [x] Backend: **The wave spec could not be applied as written.** It declared every key as `int`/`serial`, but every primary key in this database is `UUID` (`schema.sql`: `users:23`, `venues:51`, `bookings:151`, `teams:210`, …), so `team_id int REFERENCES teams(id)` is rejected outright by Postgres — *"foreign key constraint cannot be implemented: incompatible types integer and uuid"* — on the **first** `CREATE TABLE`, meaning nothing after it would have run. All 40 key columns are `UUID`; only genuine integers (scores, `round`, `position`, `elo`, `max_teams`, `booking_window_days`) stayed `int`. The runner asserts `data_type = 'uuid'` on every one of them, so this class of mistake cannot silently return.
- [x] Backend: Renumbered **010 → 013**. The spec named the file `010_fyp2_foundation.sql`, but `010_escrow_policy_alignment.sql` is already applied (011 = slot locks, 012 = hardening indexes). Two migrations sharing a number is how a schema quietly diverges between machines.
- [x] Backend: `notifications` is **extended, not recreated**. The spec's `CREATE TABLE IF NOT EXISTS notifications (…)` would have hit the table migration `010:45` already created and **silently skipped it** — leaving S.7 code to fail at runtime against columns that were never added. 013 only runs `ALTER TABLE notifications ADD COLUMN IF NOT EXISTS payload jsonb`, and the runner hard-fails up front if migration 010 has not been applied. One table, one definition.
- [x] Backend: Restored the two foreign keys the spec omitted — `matches.winner_team` and `match_results.winner_team` now carry `REFERENCES teams(id)`. `fixtures.winner` does carry it three lines later in the same spec, so the omission was an oversight, not a design choice. Both stay nullable, so a draw is still expressible.
- [x] Backend: **14 indexes** on the new tables — the spec shipped none, and six of the new tables use `ON DELETE CASCADE`, where Postgres does *not* auto-index the referencing column, so deleting one team or tournament would sequentially scan every child table. Four candidate indexes were deliberately **skipped** because an existing `UNIQUE` constraint already provides a leading-column index (`team_join_requests`, `match_results`, `tournament_teams`, `team_invites(token)`), and `notifications` is already covered by `010:55`. Those skips are documented in the migration so the next reader doesn't "fix" the gap with a duplicate — the same trap migration 012 was written to avoid.
- [x] Backend: `global_settings` created and seeded (`elo`, `commission_pct`, `deposit_pct`, `sports_enabled`) but **wired to nothing**. Its `deposit_pct: 20` duplicates `POLICY.DEPOSIT_PERCENT` in `src/utils/escrow.js`, which per golden rule 3 (SRS) is the source of truth for money. Seeding the row is harmless; silently making it authoritative would be a money bug. Nothing should read it until a wave explicitly moves that authority across.
- [x] Verification, **run twice** (9/9 assertions green both times, applied to Supabase): 12 tables created (**27 total** in `public`), all **40** key columns confirmed `uuid`, added columns on `teams`/`reviews`/`player_profiles`/`venues`/`users`/`notifications` all correct, `users.suspended` and `notifications.read` confirmed **absent**, both `winner_team` FKs present, all 4 `global_settings` seed keys, all 14 indexes present. `teams` is empty (0 rows), so the `elo`/`visibility` backfills had nothing to convert — the guards are in place but are untested against real rows, which matters only if a team row is ever created directly in SQL before S.2 ships.
- [x] **Idempotent.** The second run reported `27 tables present` at pre-flight, re-applied the whole file, and printed `Created this run: none (idempotent re-run)` with all 9 assertions still green — so every `CREATE TABLE`/`ADD COLUMN`/`CREATE INDEX` is a true no-op and the two `teams` backfills correctly declined to fire again. Re-running 013 on a database that already has it is safe.
- [x] Server boots clean after the migration — both jobs start, `Database connected`, and **no** `[notify] notifications table missing` warning.


### Wave D schema notes (read these before S.2 / S.4 / S.7)

Four deliberate deviations from the pasted spec. They are recorded here *and* in the migration header, because these are exactly the decisions that get re-litigated three waves later.

- **`users.suspended` was NOT added — `users.is_active` is the suspension flag.** It already exists and is already enforced: `src/routes/auth.js:164` returns `403 "Account suspended."` when it is false. Two flags for one fact means an admin panel could set `suspended = true` while the login path kept checking `is_active`, and the suspended user would still log in. **S.7's admin suspend action must toggle `is_active`.**
- **`notifications.read` was NOT added — `is_read` is the read flag.** Created by `010:52`, written by `src/utils/notify.js`, and already indexed as `idx_notifications_user(user_id, is_read, created_at DESC)`. `payload jsonb` was the only genuinely new column.
- **`teams.elo` and `teams.visibility` WERE added** even though `elo_rating DECIMAL` and `is_public BOOLEAN` already exist, and were backfilled from them (`ROUND(elo_rating)`, `is_public=false → 'private'`). This is the opposite call to the two above, on purpose: `teams` has **zero backend code** (no `/api/teams` route in `server.js`, and no query anywhere reads either legacy column), so nothing can drift. `int` is also the right type for Elo, and `text` visibility leaves room for `invite_only`. **Treat `elo_rating` and `is_public` as legacy-unread; write S.2 against `elo` and `visibility`.**
- **`player_profiles.trust_score INT` stays as the aggregate.** The four new `trust_*` numeric columns are the per-signal components S.4 will compose it from — they do not replace it. `trust_score` is what the app already displays and what the no-show path already decrements (`src/routes/bookings.js:462`, `src/routes/owner.js:659`).

### Wave C follow-ups closed
- [x] Deleted the dead `backend/src/controllers/` directory — `authController.js`, `bookingController.js`, `ownerController.js`, `venueController.js`. Confirmed unreachable: grep for `controllers/`, `require(…Controller)` and each filename returns **zero** matches repo-wide. They also queried a `venue_slots` table nothing else uses, and `bookingController.js:77` still returned `err.message` straight to the client — the exact USE-3 leak Wave C closed everywhere else, sitting in a file that only looked like live code.
- [x] Migration numbering drift resolved by using `013` (see above).
- [x] The two informational flags needed no action: only one of Wave C's four requested indexes was genuinely missing, and `slots(venue_id, date)` → `slot_date` — both already handled inside migration 012.

## Wave F (Client plumbing, withdrawals, bug sweep)
Completed:
- [x] Flutter: `lib/services/api_service.dart` — one central `ApiClient`. Attaches the JWT (per-call `token:` still works; a static `ApiClient.authToken` is the fallback), decodes the envelope, and turns every failure into a sentence a user can act on instead of a raw `SocketException`/`FormatException`. **Timeout is two-stage: 45 s until the first successful response of the app session, 10 s after** — the spec asked for a flat 10 s, which would fail *every* first request of a demo against a sleeping Render free-tier container (~30 s cold start, Pitfall 3). `typedef ApiService = ApiClient;` keeps the old name compiling, so the 38 existing call sites in 22 files were not touched: the spec said migrate opportunistically, not big-bang.
- [x] Flutter: `lib/utils/num_util.dart` — `asNum(dynamic, {fallback})` and `asNumOrNull(dynamic)` (golden rule 6). `pg` returns every `DECIMAL` as a **string**, so `wallet['balance'] as double` throws and `.toStringAsFixed(2)` on a `String` throws. There were **11 hand-rolled copies** of this parser across screens and models, three of them subtly different in null handling.
- [x] Backend: `migrations/014_withdrawals.sql` + `run_migration_014.js`. **A deliberate, single, reviewed exception to Pitfall 4 ("don't extend the schema beyond 013")** — recorded as such in the migration header. A withdrawal needs a durable `pending` state that survives a restart; faking it with a `transactions` row would mean re-deriving "is there a request in flight?" by scanning the ledger on every wallet load. All keys `UUID` (the Wave D lesson). No new enum type — `CHECK (status IN (…))` avoids an `ALTER TYPE` path in the runner for no benefit.
- [x] Backend: **"One pending withdrawal at a time" is enforced by the database, not by an if-statement** — `CREATE UNIQUE INDEX uq_withdrawals_one_pending ON withdrawals (user_id) WHERE status = 'pending'`. A JS check reads the table, decides, then inserts; two fast taps on a slow connection both read "none pending" and both insert. The partial unique index makes the second insert fail with `23505`, which the route maps to `409 "You already have a withdrawal in progress."`
- [x] Backend: `POST /api/wallet/withdraw`, `GET /api/wallet/withdrawals`, `DELETE /api/wallet/withdraw/:id`, `GET /api/wallet/frozen` in `src/routes/wallet.js`. All money inside one `BEGIN … COMMIT` holding `FOR UPDATE` on the wallet row, reusing `lockWallet`/`applyWallet`/`logTxn`/`round2` from `escrow.js` (Pitfall 1 — no read-modify-write in JS). Min PKR 200 (`POLICY.WITHDRAWAL_MIN_AMOUNT`, FR7.4/ER1.6). `DELETE` was **added beyond the spec on purpose**: without it one test withdrawal locks the feature for a full 24 h settle window, mid-sprint.
- [x] Backend: **Money timing — the debit happens at request time, not at settlement.** Request: `balance -= amount`, one `withdrawal` ledger row, status `pending`. Settlement (24 h job): **no money moves**, status → `completed`. Cancel/fail: `balance += amount` and a *new* `refund` row — the ledger is append-only, so the audit trail keeps both halves rather than reversing the original. Rationale: you must not be able to spend money you have already asked to withdraw. The hold is a plain balance debit and **not** `frozen_balance`, because `frozen_balance` means *booking escrow* and `GET /frozen` itemises it per booking — mixing withdrawal holds in would make that breakdown disagree with its own total.

  | Event | Wallet | Ledger | `withdrawals.status` |
  |---|---|---|---|
  | Request | `balance -= amount` | 1 row `withdrawal`, `-amount` | `pending` |
  | Settles (24 h job) | **nothing moves** | none | `completed` |
  | Cancelled / failed | `balance += amount` | 1 row `refund` | `cancelled` / `failed` |

- [x] Backend: `src/jobs/withdrawalJob.js` — third background sweep, structured exactly like `noShowJob` (`_running` re-entrancy guard, candidate scan *outside* the money transaction, per-row `FOR UPDATE` inside it, `setTimeout(…, 5000)` before the first run so it never races the pool at boot). Mounted in `server.js` beside the other two. Exports `processWithdrawals()` so a test can force a sweep.
- [x] Backend: `GET /api/wallet/frozen` (FR7.2) returns `{items, itemsTotal, walletFrozen, delta}` — one row per booking that is actually holding escrow, computed **server-side** rather than filtered in Flutter so `itemsTotal` can be compared against `wallets.frozen_balance` and any mismatch **shown**. A non-zero `delta` means legacy rows escrowed under the pre-Wave-A 30% rule; surfacing it beats a breakdown that quietly disagrees with the headline number.
- [x] Backend: **Test-timing overrides** in `escrow.js` — `SL_TEST_AUTO_DECIDE_MINUTES`, `SL_TEST_NO_SHOW_MINUTES`, `SL_TEST_SETTLE_MINUTES`, `SL_TEST_SWEEP_SECONDS`. The S1 checklist asks for the 2 h auto-approve rule to be tested "with a 1-min override constant"; a hand-edited constant works once and then risks being committed, so the override reads from the environment and absent ⇒ the SRS defaults byte-for-byte. **No override can change how much money moves** — `DEPOSIT_PERCENT`, `CANCELLATION_WINDOW_HOURS` and `NO_SHOW_TRUST_PENALTY` are deliberately not overridable, so a test run can never produce a split production wouldn't. `AUTO_DECIDE_AFTER_MINUTES` replaced the old `_HOURS` key so a 1-minute override doesn't push a fraction into `('x hours')::INTERVAL`, and `describeDelay()` was added so the notification says "1 min" rather than "0.0167h". `server.js` prints a loud multi-line `⚠️ TEST TIMING OVERRIDES ACTIVE` banner at boot — a silently sped-up sweep is worse than no override.
- [x] Backend: `escrow.js` `logTxn` now ends `RETURNING id` and returns it, so `withdrawals.txn_id` can point at its ledger row. All 6 existing callers ignore the return value — additive, nothing broke.
- [x] Backend: **`app.set("trust proxy", 1)` in `server.js`, guarded to `RENDER || NODE_ENV === 'production'`.** `middleware/rateLimit.js` had documented this as a deploy-time requirement and it had never been done. Behind Render's proxy `req.ip` is the *proxy's* address, so all anonymous traffic on the internet shares **one** 20-req/min bucket and two phones can 429 each other — which is precisely Wave E's acceptance criterion. `1`, not `true`: Express then reads the hop Render appended, which a client cannot forge, whereas `true` takes the leftmost client-supplied `X-Forwarded-For` entry and hands anyone a way past the limiter.
- [x] Flutter: three shared widgets, so the vocabulary exists once — `widgets/withdraw_sheet.dart` (amount + method + account fields, min 200, capped at available balance; renders the **pending request and a Cancel button** instead of the form when one is in flight), `widgets/frozen_balance_sheet.dart` (FR7.2 — per-booking venue/date/time/amount/status, total, and a note row when `delta != 0`), `widgets/transaction_detail_sheet.dart` (FR7.9 — needs **no new endpoint**: `GET /wallet/transactions` already returns `t.*` plus `venue_name`/`slot_date`/`start_time`/`end_time`).
- [x] Flutter: `transaction_detail_sheet.dart` also exports the shared `txnLabel` / `txnIcon` / `isCreditTxn` / `fmtTxnDate` / `fmtSlotDate` / `fmtSlotTime` helpers, and all three wallet screens now use them. **This fixed two live bugs.** (1) Both `wallet_history_screen` and `owner_wallet_screen` had private label/icon maps **missing `escrow_release` and `escrow_received`** — and `escrow_received` is how a check-in pays an owner, i.e. the most common row in an owner's ledger, rendering as a bare "Transaction" with a generic arrow. (2) Both `_fmtDate` copies read `.hour`/`.minute` straight off `DateTime.parse` of a `Z`-suffixed string, which is **UTC** — every timestamp in the app displayed **5 hours behind PKT**. The shared formatter calls `.toLocal()` first (Pitfall 2: store UTC, convert only in Flutter).
- [x] Flutter: **two screens were lying about failure.** `wallet_history_screen` swallowed every error into an empty list, so a 401 or a dead server both rendered "No transactions found". `owner_wallet_screen` caught every failure and left `_wallet` null, which renders as **"PKR 0"** — an owner seeing zero after a network hiccup had no way to tell that from actually losing money. Both now surface the server's `message` with a Retry button. `owner_wallet_screen` also now loads wallet + transactions in one `Future.wait`.
- [x] Flutter: the owner's **"Withdraw Funds" button was a stub** that showed `'Withdrawals will be available after launch.'`. The plan had owner withdrawals out of scope; this is a deliberate, documented override — the endpoint and `WithdrawSheet` are role-agnostic, and **owners are the party that actually accumulates money** (check-in moves 100% of every booking to them), so a dead button there is worse than in the player wallet. Its help text was also wrong ("Wallet balance is used to book venues. Top up via the button below.") and now describes earnings and escrow.
- [x] Flutter: deleted **four dead classes** from `owner_wallet_screen.dart` — `_TopUpSheet`, `_TopUpSheetState`, `_PaymentSimulationDialog`, `_PaymentSimulationDialogState`: copy-pasted from the player wallet, never referenced (the file contains no `showModalBottomSheet` at all). Unreferenced *private* declarations are exactly what `flutter analyze` flags as `unused_element`, so this was blocking golden rule 7. The player `wallet_screen.dart` genuinely uses its own copies (lines 57, 87) — only the dead ones went. Net: the owner screen went 401 → 277 lines.

## Wave E (Cloud demo deploy — Render + Supabase)
Completed:
- [x] Flutter: `lib/constants/api_constants.dart` — `baseUrl` is now `bool.hasEnvironment('API_BASE_URL') ? String.fromEnvironment('API_BASE_URL') : (kIsWeb ? 'http://localhost:3000/api' : 'http://10.0.2.2:3000/api')`. `bool.hasEnvironment` rather than `String.fromEnvironment(...).isEmpty`, because `.isEmpty` is not const-evaluable and this has to stay `const`. **Behaviour change worth knowing:** the default flipped from the hard-coded LAN IP `192.170.0.110` to the emulator alias, so a physical phone now *always* needs `--dart-define`. That is what the spec asked for, and a LAN IP baked into a release APK is a demo that dies the moment the laptop sleeps.
- [x] Backend: **`src/db/pool.js` rewritten — blocker 3.** SSL was gated on `NODE_ENV === 'production'` alone, so one forgotten dashboard variable produced `no pg_hba.conf entry … no encryption`, which reads like a Supabase problem and is not. TLS is now derived from **three independent signals**: an explicit `sslmode=` in the URL (honoured including `disable`), `NODE_ENV`, or the host simply not being `localhost`. Also: `ssl: false` must be passed explicitly for local Postgres, because setting it to `false` **overrides** `pg`'s own parsing of `sslmode` from the connection string. Boot now prints `✅ Database connected (TLS on/off)`, and a connection failure is mapped to one of four specific hints (add `?sslmode=require` / wrong password or the `[YOUR-PASSWORD]` placeholder still in the URI / host not found → recopy from Supabase Connect / timeout → use the Session pooler, not the IPv6-only direct host).
- [x] Backend: **`src/scripts/seed_venues.js` — blocker 2.** It loaded `.env` from `D:\sportlynk\.env` (**wrong directory** — the file is in `backend/`) and built its **own** `Pool` from `DB_USER`/`DB_HOST`/`DB_NAME` defaulting to **localhost postgres with no SSL**. It could never have reached Supabase, which is the only database this project has. Now `require('../db/pool')`. Seeding logic untouched, except the log line that said `14 * (endHr - startHr)` slots when the loop runs `day = 0; day <= 14` (15 days), and a missing `process.exitCode = 1` on failure.
- [x] Backend: **`seed_venues.js` destructive pre-flight.** The script `DELETE`s that owner's venues, slots, bookings *and* the transaction rows for those bookings. It now counts all four first and prints them, warns specifically when any of those bookings are `confirmed`/`completed` (*"Deleting them destroys the escrow trail your acceptance tests check"*), and waits 5 seconds for `Ctrl-C` — skippable with `--yes`/`SL_SEED_YES=1` for scripted use. Wave E's spec said "seed Supabase" as if it were additive; it is not.
- [x] Backend: `package.json` — `"engines": {"node": ">=20"}` so Render doesn't select a Node version with no prebuilt `bcrypt ^6` binary and fall through to a `node-gyp` source build. Also `main` pointed at a nonexistent `index.js` (now `src/server.js`), `description` was empty, and `seed:venues` was not a script.
- [x] Backend: `.env.example` — documented all four `SL_TEST_*` overrides with their real POLICY keys and defaults, a PowerShell usage line, and *"never set these on Render"*. `PORT` now warns that Render injects its own. The legacy `DB_*` note now correctly says only `run_migration_009.js` still reads them.
- [x] Docs: `README.md` — a **run-modes table** (emulator / phone on Wi-Fi / phone over `adb reverse` / cloud) with the exact command for each, the release-APK line, and the `--dart-define` warning. Also fixed the stale Tech Stack row that still claimed "PostgreSQL 16 (local) + Supabase (cloud)", added a Hosting row, and replaced the Documentation table's dangling `RUN_GUIDE.md` link with the files that actually exist.
- [x] Docs: **`doc/DEPLOY_GUIDE.md`** — 11 numbered steps, every one with a "what you should see", written for copy-paste: pre-flight (lockfile tracked, no `.env` staged), the git commands, the Render service form field-by-field (root dir `backend`, `npm ci`, `npm start`, health path `/api/health`, Singapore region for latency from Pakistan), the three env vars with where each value comes from, Supabase **verify-don't-re-run**, seeding, the phone build, the warm-up ritual, and a 15-row troubleshooting table. Also answers "will the backend still work when I disconnect my phone?" with the four cases.
- [x] Docs: **`doc/S1_ACCEPTANCE.md`** — the pasted S1 checklist audited row by row (status / where it lives / who verifies / how), plus the manual scripts: escrow spine, both cancels, two-account slot lock, the three 1-minute override tests, and the withdrawal 400→201→409→refund→settle contract. Records three stale wordings in the original checklist: there is no local database (migrations are 001–014 on Supabase), the "1-min override constant" is an env var not an edited constant, and the `s1-done` tag does not exist yet.

### Wave E deployment notes (read before the demo)
- **Render free tier sleeps after ~15 min of no traffic** (Pitfall 3). Two consequences, and the second is the one people miss. (1) The first request takes 30–50 s — absorbed by `ApiClient`'s 45 s cold-start timeout, but still 45 s of spinner, so warm `/api/health` twice before presenting. (2) **A sleeping process runs no `setInterval`, so all three sweeps stop.** The money math stays correct (the jobs compare real timestamps, so they do the right thing for the right rows whenever they *do* run) but the moment of firing drifts: a pending booking auto-approves at the first sweep after the container next wakes, not on the stroke of 2 h. For a live demo of a timed feature, run the backend locally with `SL_TEST_*` instead of relying on Render.
- **One database, not two.** A local backend and the Render backend both point at the same Supabase instance. Never paste `schema.sql` into the Supabase SQL editor — the spec's step 2 ("run schema.sql + migrations 001–010") predates Supabase becoming the only database, and following it would drop the real accounts. Migration 014 is applied by running its runner locally; that *is* applying it to Supabase.
- **`lib/constants/app_config.dart` is gitignored**, so a fresh clone cannot build the Flutter app. Harmless for Render (which only builds `backend/`), but back that file up outside the repo.
- **Release APK signs with the debug keystore** (`android/app/build.gradle.kts`), which is why `flutter build apk --release` needs no keystore setup and why Firebase phone OTP keeps working (same SHA-1). Fine for the FYP; a real keystore is only needed to publish.

