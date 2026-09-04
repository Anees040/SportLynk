# CLAUDE.md

Working agreement for this repo. Claude Code loads this file at the start of every
session; treat it as standing instructions that do not need to be repeated in the
prompt. If a rule here conflicts with a one-off request, follow the request and say
which rule it overrides.

## The system

SportLynk: venue booking, tournaments, matchmaking, chat, and an in-app assistant
("Scout"). Three processes, all started by hand during development.

| Part | Path | Port | Start |
| --- | --- | --- | --- |
| Flutter client | `lib/` | - | `flutter run` (see Run modes) |
| REST + Socket.IO API | `backend/` (Node, Express 5) | 3000 | `npm run dev` |
| ML service | `ml-service/` (FastAPI, 4 models) | 8000 | `.\run_dev.ps1` |

The database is Supabase Postgres. There is no local database and no staging
environment: **the development database is the production database.** Every query
written here runs against real rows.

The client reaches both transports through one define. `ApiConstants.baseUrl` comes
from `API_BASE_URL`, and `socketUrl` is derived from it by stripping a trailing
`/api`, because Socket.IO mounts at the root. Never introduce a second URL constant.

## Where the project is

Past the first build, in hardening. The features exist end to end but the finish is
uneven: some screens are visually rough, some flows are stubbed, some values are
hardcoded, and some paths are dev-mode shortcuts that must not survive to release.
Priorities, in order:

1. UI and UX correctness. This is the weakest part of the product.
2. Making stubbed, dummy, or partially working features genuinely work.
3. Performance, resilience, and release preparation.

Assume nothing is finished until it has been read. When asked about a screen or an
endpoint, open it before answering.

## Run modes

Four terminals. PowerShell paths are shown because that is the shell on this machine.
Start the two servers first; the client is useless without them.

**1. API, port 3000**

```powershell
cd D:\sportlynk\backend
npm run dev                      # nodemon, restarts on save
# verify: curl http://localhost:3000/api/health
```

**2. ML service, port 8000**

```powershell
cd D:\sportlynk\ml-service
.\run_dev.ps1                    # uvicorn, no --reload (watchfiles is not installed)
# verify: curl http://127.0.0.1:8000/health
```

`run_dev.ps1` takes `-Port` and `-LogLevel debug`. It does not watch files: after
editing anything under `ml-service/app/`, stop it with Ctrl-C and start it again.
If the port is changed, change `ML_SERVICE_URL` in `backend/.env` to match.

**3. Chrome at a Pixel 7 viewport - for UI work**

```powershell
cd D:\sportlynk
flutter run -d chrome --web-port=5000 --web-browser-flag="--window-size=412,915"
```

A Pixel 7 is 412 x 915 CSS pixels. The window flag sizes the browser once; for a
faithful frame use DevTools (F12) -> device toolbar (Ctrl+Shift+M) -> Pixel 7, which
also applies the correct device pixel ratio and touch emulation. Keep `--web-port`
fixed at 5000 so the URL never changes between restarts. No define is needed: on web
the client defaults to `http://localhost:3000/api`, and the API sends
`Access-Control-Allow-Origin: *`, so any port connects.

Chrome is for layout, spacing, colour, typography, and state rendering only. It is
not evidence that a feature works: web has no Firebase phone auth, no real push
notifications, no platform pickers, and different scroll physics.

**4. Physical phone - for anything functional**

```powershell
flutter devices                                  # copy the device id
adb reverse tcp:3000 tcp:3000                    # phone's localhost:3000 -> this PC
cd D:\sportlynk
flutter run -d <device-id> --dart-define=API_BASE_URL=http://localhost:3000/api
```

`adb reverse` is the reliable option: it survives changing Wi-Fi networks and works on
networks that block client-to-client traffic. It is not persistent - re-run it after
every unplug, phone reboot, or `adb kill-server`. If it is missing, every request
fails with a connection error that looks exactly like the API being down, so check it
first when the phone shows errors and Chrome does not.

The alternative, if the phone and PC are on the same Wi-Fi:

```powershell
ipconfig                                         # IPv4 address of the Wi-Fi adapter
flutter run -d <device-id> --dart-define=API_BASE_URL=http://192.168.1.x:3000/api
```

Plain HTTP works on the phone only because `android/app/src/debug/AndroidManifest.xml`
and `.../profile/AndroidManifest.xml` set `android:usesCleartextTraffic="true"`. The
main manifest deliberately does not, so a release APK cannot talk to a plain `http://`
API - the deployed backend must be HTTPS. Do not move that attribute into
`src/main/AndroidManifest.xml`.

**Working both at once**

Start the phone build first and let Gradle finish, then start Chrome; both `flutter
run` sessions can stay alive together. After that, do not restart either one - press
`r` in the session's terminal for hot reload and `R` for a hot restart. Gradle only
costs minutes on the first build of a session or after touching `android/`,
`pubspec.yaml`, or a native plugin.

Emulator, for reference: the client defaults to `http://10.0.2.2:3000/api` with no
define, since `10.0.2.2` is the host loopback as seen from the emulator.

## How to work

### A reported bug

The user tests by hand on a phone and reports problems one at a time. For each one:

1. **Locate it before theorising.** Read the whole path: widget -> service -> route ->
   backend service -> query (and `mlClient` -> FastAPI where a model is involved).
   The symptom is almost never where the cause is.
2. **Name the root cause in one sentence** before editing anything. If that sentence
   cannot be written yet, keep reading. Ask for a screenshot, the exact steps, or the
   terminal output rather than guessing.
3. **Write the failing check first** where one can be expressed - a case in
   `backend/test/*.test.js`, a `check_*.js` assertion, or a Dart test. Confirm it fails
   for the stated reason. For purely visual bugs, state the before/after instead.
4. **Fix the cause, at the smallest scope that fixes it.** No `try/catch` that hides
   the error, no defensive null guard standing in for the real reason a value is null,
   no second code path added beside the broken one.
5. **Run the gates** below that cover what was touched.
6. **Report** what changed, what was verified and by which command, and what was not
   verified. If something still fails, say so and paste the output.

### Never ship a placeholder

No dummy data, fake success responses, hardcoded IDs, silent no-ops, or `TODO` stubs
in any path a user can reach. If a feature cannot be completed in the turn, finish
everything that can be finished, then say plainly which part is missing and why -
never fill the gap with something that looks like it works. When a pre-existing fake
is found while working nearby, name it in the report; do not quietly leave it.

### Scope

Change what was asked and nothing else. No drive-by renames, reformatting, or
refactors of adjacent code; no new dependency without saying so first; prefer what is
already in `pubspec.yaml` and `backend/package.json`. Other problems noticed along the
way go in a list at the end of the reply, unfixed.

### Definition of done

A feature is done when it works on the phone against the live API, shows something
sensible while loading and when empty, surfaces failures to the user instead of
logging them, has no hardcoded identifiers, and leaves the gates green.

## Gates

Run the ones that cover what was touched, not all of them every time. Report the
actual counts, never a summary like "tests pass".

**Flutter** (from the repo root)

```powershell
flutter analyze                  # must end with "No issues found"; takes ~2 minutes
flutter test
```

**API** (from `backend/`)

```powershell
npm test                         # node:test, unit + fixtures, no network
```

These need the API and the ML service running, and they read and write real Supabase
rows, so run them deliberately rather than as a habit:

```powershell
node src/scripts/check_notifications.js
node src/scripts/check_chat.js
node src/scripts/check_booking_service.js
node src/scripts/check_price_sanity.js
node src/scripts/check_ml_service.js
npm run check:scout              # assistant, in-process
npm run check:scout:http         # assistant, over HTTP; needs port 3000 up
```

`check_tournaments.js` currently fails 2 of 3 because the demo data has drifted; it
needs a re-seed before its result means anything. Do not treat its failure as a
regression without checking that first.

**ML service** (from `ml-service/`, using the venv interpreter)

```powershell
.\.venv\Scripts\python.exe -m compileall app training
.\.venv\Scripts\python.exe app\core\intent_spec.py --self-check
```

The intent self-check prints two fingerprints, `assistant-intents-v2` and
`assistant-dataset-v2`. If either changes, the label set or the corpus moved and the
released model no longer matches its spec - stop and report it rather than
regenerating anything.

## Hard rules

**Git.** The user commits, always. Do not run `git commit`, `git push`, `git reset
--hard`, `git checkout -- <file>`, `git clean`, or `git branch -D`. Reading status,
diffs, and log is fine. Leave changes in the working tree and describe them.

**Secrets.** `ML_API_KEY` must be byte-identical in `backend/.env` and
`ml-service/.env`. Compare them only through the `apiKeyFingerprint` (the first 8 hex
of its sha256) reported by `GET :8000/health`. Never print, echo, log, paste into a
reply, or commit the key itself - the same goes for the Supabase service key and the
Firebase credentials. When a `.env` needs a change, name the key and let the user
edit it.

**Schema.** Every change is a new `backend/migrations/0XX_*.sql` plus its runner,
applied once. Never run `backend/schema.sql` against Supabase; it is the from-scratch
definition and would destroy live tables. Because the development database holds real
data, ask before applying any migration, and never write a `DROP`, `TRUNCATE`, or
unfiltered `DELETE`/`UPDATE` without explicit confirmation in the same turn.

**Training data.** Do not re-run `ml-service/training/generate_bookings.py`. A fresh
CSV gets a different sha256 and fails the provenance gate that ties the pricing model
to its training set. Do not retrain, replace, or delete a released model artifact
unless asked for exactly that.

**Process.** No subagents, workflows, or deep research unless the user asks for them.
No background servers left running that the user did not start.

## Conventions

**Comments** are formal, third person, and explain intent, constraint, or a decision
and its reason - never narration of what the next line does and never guide voice
("we", "let's", "you can"). No hedging ("just", "simply", "really"), no shouting in
caps, no emoji. The whole tree was normalised to this register; match it.

**Dart.** One widget per concern; `const` constructors wherever possible; no
`print` - and no business logic in a `build` method. Files stay under ~600 lines;
`lib/widgets/tournament_widgets.dart` and `lib/models/tournament.dart` are known
oversized exceptions awaiting a split, not a precedent.

**Node.** Routes validate input and stay thin; logic lives in `src/services/`;
queries live in the service that owns the table. Errors return a real status code
and a message the client can show.

## UI work

Colours come from `AppColors` in `lib/constants/colors.dart`, and the app's single
`ThemeData` lives in `lib/constants/app_theme.dart`. No literal `Color(0xFF...)` in a
screen or widget: if a shade is missing, add it to `AppColors` and use it by name.
`lib/constants/app_colors.dart` is a dead duplicate with no importers - do not use or
edit it. There is currently only a light theme.

There is no spacing scale yet. Use multiples of 4 (4, 8, 12, 16, 24, 32) and stay
consistent within a screen rather than inventing one-off values.

Every list, and every widget that waits on the network, needs four visible states:
loading, empty, error with a retry, and loaded. A spinner that never resolves and a
blank screen where an error happened are both bugs; report them when found. Any tap
target is at least 48 x 48 logical pixels, text scales with the system setting without
clipping, and every icon-only button has a semantics label.

Match the screens that are already good rather than introducing a new visual language;
when a redesign is asked for, describe the change in a sentence before writing it.

## Known state, deliberately

Facts worth knowing before "fixing" them:

- `AppConfig.devMode` is `true` in `lib/constants/app_config.dart`. While it is, the
  phone field skips OTP entirely and reports `devFirebaseUid` as a verified phone, so
  anyone can sign in as that identity. It must be `false` in any build that leaves this
  machine. Its only caller is `lib/widgets/phone_field.dart:63`.
- `backend/src/server.js:31` sets `cors({ origin: "*" })`. Convenient for development
  on any web port; it needs an allowlist before release.
- `lib/models/slot.dart` and `lib/screens/owner/owner_venue_screen.dart` have no
  importers, like `app_colors.dart` above. They are pending deletion, not references.
- `doc/PROJECT.md`, `doc/FEATURES.md`, and `ml-service/README.md` are stale. Read the
  code, not those, when they disagree.
- `README.md` has no "Run modes" section even though `lib/constants/api_constants.dart`
  points at one. This file is the reference until that is written.

## Layout

`lib/screens/` by role (player, owner, admin) - `lib/widgets/` - `lib/services/` (API
clients) - `lib/models/` - `lib/constants/`. Backend: `src/routes/` -> `src/services/`
-> Supabase, with `src/middleware/` for auth and rate limiting, `src/realtime/` for
Socket.IO, `src/scripts/` for seeds and checks, and `migrations/` for schema. ML
service: `app/routers/` -> `app/core/`, with `training/` for the offline pipeline and
model artifacts released under `models/`.

## Reporting a problem

The most useful report names the screen, the steps, what was expected, what happened,
and where it was seen. When a report is missing the part that decides where to look,
ask for that one thing rather than guessing:

```
Screen:     Player > Find Venues
Steps:      open the screen, pull to refresh
Expected:   the venue list reloads
Actual:     the spinner stays forever, nothing appears
Seen on:    phone (Chrome is fine) | both | Chrome only
Terminal:   <any red lines from the backend or flutter run>
```

"Seen on" is the highest-value line in the template: a fault on the phone but not in
Chrome is almost always connectivity (`adb reverse`), platform permissions, or a native
plugin, while a fault in both is application logic.
