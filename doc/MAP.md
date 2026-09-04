# MAP.md — the orientation file

Read this once at the start of a session, instead of rediscovering the tree with a
dozen searches. It answers "where does this live" and nothing else: the rules are in
`CLAUDE.md`, the wave history and model receipts are in `doc/CLAUDE.md`, the money and
ML rationale is in `doc/ARCHITECTURE.md`.

Two things it deliberately does not do. It does not describe whether a screen is
finished — the project is mid-hardening and only reading the file answers that. And it
does not restate `CLAUDE.md`: run modes, gates, and hard rules are there, current, and
not duplicated here.

A line marked ◇ was verified by reading the file. A line without the mark was taken
from the file listing and the route table, which name a screen but do not prove what is
inside it. Promote a ◇ when the file is read; never trust an unmarked line as evidence.

---

## 1. The client's entry path

```
main()                            ◇ lib/main.dart
  Firebase.initializeApp          (try/caught; a phone without Play Services still boots)
  PushService().init()            parks a tray tap taken on a killed app
  runApp(SportLynkApp)
    MultiProvider                 Auth · Venue · Booking · Notification
    MaterialApp
      navigatorKey  DeepLink.navigatorKey
      theme         AppTheme.light
      routes        AppRoutes.map
      home          AuthWrapper
```

`AuthWrapper` ◇ `lib/screens/auth_wrapper.dart` is the whole of the in-app splash. It
calls `AuthProvider.loadUser()` in a post-frame callback and, while `isLoading`, draws
the logo + wordmark + spinner on `AppColors.primary`. There is no `splash_screen.dart`
and no route to one. It then branches on role:

| `auth` state | lands on |
| --- | --- |
| `isLoading` | the inline splash described above |
| authenticated, `role == 'admin'` | `AdminHomeScreen` |
| authenticated, `role == 'owner'` | `OwnerHomeScreen` |
| authenticated, anything else | `PlayerHomeScreen` |
| not authenticated | `WelcomeScreen` |

Before that frame there is a second, native splash — `flutter_native_splash.yaml`
(colour `#0A1F13`, `assets/images/logo.png`) generated into
`android/app/src/main/res/drawable{,-v21}/launch_background.xml` ◇. Editing the XML by
hand is overwritten by the next `dart run flutter_native_splash:create`; edit the YAML.
So the cold-start sequence is **native splash → AuthWrapper splash → Welcome or a home**,
and a complaint about "the splash" can mean either of the first two.

## 2. Shell and navigation

Both player and owner homes are `IndexedStack` shells with a hand-rolled bottom bar
(`_buildNav()`), not `BottomNavigationBar`. Tab bodies are full screens, so a screen is
reachable either as a tab or as a named route, and a few are both.

- **Player** ◇ 5 tabs: Home · Bookings · Teams · Wallet · Profile.
  `ScoutFab` rides the shell and is hidden on Teams and Profile.
  `_bookingsKey` is a `GlobalKey<BookingsScreenState>` so a booking made inside Scout
  can refresh the live Bookings tab.
- **Owner** ◇ 5 tabs: Dashboard · Bookings · Schedule · Venues · Profile.
- **Admin** ◇ a `TabController(length: 5)` with a `TabBar` in the app bar, no bottom bar.

`AppRoutes.map` ◇ `lib/routes/app_routes.dart` is the only route table. Two contracts
run through it, both mechanically checked, so it is not a file to reorganise casually:

1. Every route `backend/src/utils/notificationTypes.js` can emit must exist in it.
   `backend/src/scripts/check_notifications.js` asserts this by string-matching the
   file. A notification whose route is missing renders, buzzes, and taps nowhere.
2. A route reachable by more than one role carries no `requiredRole`, because
   `AuthGuard` answers a mismatch with `pushNamedAndRemoveUntil` — which would throw
   away the screen a notification tap just opened. `/wallet` resolves per role instead.

## 3. Screens, by role

Counts are files on disk; the line count is the size signal, not a quality signal.

**Auth** (7) — `welcome` ◇ · `login` ◇ · `player_register` · `owner_register` · `otp` ·
`forgot_password` · `owner_pending`.

**Player** (23) — `player_home` ◇ · `find_venues` · `venue_detail` (827) ·
`confirm_booking` · `bookings` · `player_booking_detail` · `wallet` · `wallet_history` ·
`player_profile` · `trust_score` · `teams` · `create_team` · `team_roster` (1052) ·
`team_rankings` · `find_opponents` · `match_challenge` · `match_center` ·
`tournaments` · `tournament_detail` (2252, the largest file in the tree) · `assistant` ·
`rate_experience` · `venue_reviews` · `help_support`.

**Owner** (15) — `owner_home` ◇ · `owner_my_venues` · `owner_add_venue` ·
`owner_venue_management` · `owner_slot_calendar` · `owner_booking_requests` ·
`owner_qr_scanner` · `owner_match_verify` · `owner_wallet` · `owner_tournaments` ·
`owner_create_tournament` (1292) · `owner_reports` (also serves the admin platform
report via a `platform` flag) · `owner_venue_reviews` · `owner_profile` ·
`owner_venue_screen` (**no importers, pending deletion**).

**Admin** (7) — `admin_home` ◇ · `admin_users` · `admin_disputes` ·
`admin_dispute_detail` (1001) · `admin_moderation` · `admin_settings` (989) ·
`admin_registration_detail`.

**Shared** (4) — `chats` · `chat_thread` · `notifications` · `notification_prefs`.

## 4. Client layers

**Providers** `lib/providers/` — `auth_provider` ◇, `venue_provider`,
`booking_provider`, `notification_provider` are registered in `MultiProvider`.
`assistant_controller` and `chat_controller` are screen-scoped, not app-wide.

**Services** `lib/services/` — every HTTP call should go through `ApiClient` ◇
(`api_service.dart`; `ApiService` is a `typedef` kept for old imports). It owns the base
URL, the JWT, a cold/warm timeout pair (45s until the first success, then 10s, because
Render's free tier sleeps), and the translation of every failure into
`{success: false, message: <sentence>}`. **It never throws**, so a caller's error
handling is one `if (data['success'] != true)`. Migration to it is opportunistic —
direct `http.get` calls still exist elsewhere.

The rest: `auth_service` · `admin_service` · `assistant_service` · `chat_service` ·
`cloudinary_service` · `firebase_otp_service` · `match_service` ·
`notification_service` · `pricing_service` · `push_service` · `realtime_service` ·
`report_service` (the CSV bypasses `ApiClient`, since it answers `text/csv` rather than
the envelope) · `review_service` · `team_service` · `tournament_service`.

**Endpoint names** live in `ApiConstants` ◇ `lib/constants/api_constants.dart`, grouped
by feature and commented with the server-side quirk that forced each name. It is the
fastest way to find which endpoint a screen wants. `socketUrl` is derived from `baseUrl`
by stripping a trailing `/api`, because Socket.IO mounts at the root — never add a
second URL constant.

## 5. Design system

- `AppColors` ◇ `lib/constants/colors.dart` — 15 colours, that is the whole palette:
  `primary 0xFF0A1F13` · `accent 0xFF22C55E` · `accentLight` · `background 0xFFF8FAFC` ·
  `cardBg` · `inputFill` · `textPrimary` · `textSecondary` · `error` · `warning` ·
  `disabled` · `border` · `divider` · `success` · `white`.
  A shade that is missing gets added here by name, never inlined in a screen.
- `AppTheme.light` ◇ `lib/constants/app_theme.dart` — Material 3, seeded from
  `primary`, `GoogleFonts.poppinsTextTheme()`, a dark centred `AppBarTheme`. Light only;
  there is no dark theme. `NoScrollbarBehavior` lives in the same file.
- `lib/constants/app_colors.dart` is a 2-line dead duplicate with no importers. Do not
  use or edit it.
- Shared primitives: `CustomButton` ◇ (filled and `variant: 'outlined'`, both 52 high
  and radius 28, with a built-in `isLoading` spinner) · `SportTextField` ◇ (optional
  label above, `prefixIcon`, radius 12, accent focus border) · `custom_loader` ·
  `password_strength_bar` · `phone_field` (its `AppConfig.devMode` branch at :63 is the
  OTP bypass) · `header_actions` (the wordmark plus chat and bell badges) ·
  `notification_bell` · `in_app_banner` · `snackbar_util`.
- Vocabulary widgets, one per feature, worth reading before adding a component:
  `trust_widgets` (911) · `match_widgets` · `pricing_widgets` · `reco_widgets` ·
  `team_stat_widgets` · `tournament_widgets` (1784, a known oversized exception) ·
  `widgets/chat/*` (7 files) · `widgets/assistant/*` (9 files, with `scout_theme.dart`
  holding Scout's own tokens).
- Two literal-colour habits are already in the tree and are the most common thing to
  correct while working nearby: slate greys (`0xFF64748B`, `0xFF94A3B8`, `0xFFCBD5E1`)
  in `sport_text_field` ◇, and a gradient plus a repeated `Color(0xFFF8FAFC)` in
  `login_screen` ◇. Neither is in `AppColors`.

## 6. Backend

`backend/src/server.js` ◇ is the whole wiring: `cors({origin: '*'})` (needs an allowlist
before release), `helmet`, `morgan`, then `apiRateLimit` **above** `express.json` so a
flood costs no parsing. `assertNotificationTypes()` runs at load and throws on an
inconsistent registry, so a bad deep link fails the boot rather than one user's tap.
A 404 handler and a global error handler close the file; the error handler logs
everything and returns one of six fixed sentences, so no SQL text ever crosses the wire.

Mounts, in order (declaration order matters — `/mine` and `/preview` are declared before
`/:id` inside their routers):

```
/api/auth  /api/venues  /api/bookings  /api/owner  /api/admin  /api/wallet
/api/player  /api/users  /api/slots  /api/teams  /api/chat  /api/notifications
/api/matches  /api/tournaments  /api/internal  /api/assistant
/api            ← reviews, mounted at the bare root, per-route auth, last
```

`src/routes/` validate and stay thin (21 files, including `adminUsers`,
`adminDisputes`, `adminSettings` under the one `/api/admin` gate) → `src/services/`
holds the logic (`bookingService` is the **only** file containing `INSERT INTO bookings`;
also `tournamentService`, `tournamentScheduler`, `discoveryService`, `rosterService`,
`disputeService`, `suspensionService`, `reportService`, `pushService`, `mlClient`,
`dialogManager`, `assistantActions`, `assistantThreads`, `assistantKb`) → Supabase via
`src/db/pool.js`. Alongside: `src/middleware/` (auth with a 30s TTL role cache, roles,
rate limit), `src/realtime/` (Socket.IO on the same port), `src/utils/` (`escrow.js` is
the money truth), `src/jobs/` (7: noShow · autoApprove · withdrawal · matchExpiry ·
sentimentBackfill · tournament · push), `src/scripts/` (seeds and the `check_*.js`
receipts), `migrations/` (022 is the latest applied).

`ml-service/` is four models behind one `X-API-Key`, called only by Node, and every
call has a heuristic fallback in `mlClient.js` so a dead Python process is never an
outage. `app/routers/` (pricing · sentiment · reco · nlu) → `app/core/`. The details,
including why the heuristic must not live in Python, are in `doc/ARCHITECTURE.md`.

## 7. The manual pass

The project is past development and in a by-hand pass, screen by screen, starting at
the beginning. Record it here — one line per screen, appended as it is walked, so the
next session knows what has been looked at rather than guessing from git.

| Screen | Verdict | Note |
| --- | --- | --- |
| — | — | nothing walked yet |
