<div align="center">

# SportLynk

**A sports venue booking and competitive team-matchmaking platform for Pakistan.**

Escrow-protected payments · ELO-rated match ladder · tournament brackets · real-time chat
· four machine-learning models trained in-house

[![Flutter](https://img.shields.io/badge/Flutter-Android-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.10-0175C2?logo=dart&logoColor=white)](https://dart.dev)
[![Node.js](https://img.shields.io/badge/Node.js-20+-339933?logo=nodedotjs&logoColor=white)](https://nodejs.org)
[![Express](https://img.shields.io/badge/Express-5.x-000000?logo=express&logoColor=white)](https://expressjs.com)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-Supabase-4169E1?logo=postgresql&logoColor=white)](https://www.postgresql.org)
[![Python](https://img.shields.io/badge/Python-3.14-3776AB?logo=python&logoColor=white)](https://www.python.org)
[![FastAPI](https://img.shields.io/badge/FastAPI-0.141-009688?logo=fastapi&logoColor=white)](https://fastapi.tiangolo.com)
[![scikit-learn](https://img.shields.io/badge/scikit--learn-1.9-F7931E?logo=scikitlearn&logoColor=white)](https://scikit-learn.org)
[![Socket.IO](https://img.shields.io/badge/Socket.IO-realtime-010101?logo=socketdotio&logoColor=white)](https://socket.io)

</div>

---

## Contents

- [Overview](#overview)
- [System architecture](#system-architecture)
- [Feature set](#feature-set)
- [Machine learning](#machine-learning)
- [Engineering highlights](#engineering-highlights)
- [Technology stack](#technology-stack)
- [Quality assurance](#quality-assurance)
- [Repository layout](#repository-layout)
- [Getting started](#getting-started)
- [API surface](#api-surface)
- [Documentation](#documentation)
- [Project context](#project-context)
- [Licence](#licence)

---

## Overview

Booking a cricket or futsal ground in Pakistan is still arranged over WhatsApp and settled in
cash. There is no record of who paid, no protection when a booking is abandoned, and no
reliable way to find an opponent of comparable ability.

SportLynk replaces that with one system:

- **Players** discover venues, hold a slot, pay into escrow, and check in by QR code.
- **Venue owners** approve requests, manage slot inventory, host tournaments, and withdraw
  earnings — with a machine-learned price suggestion on the dashboard.
- **Teams** are rated on a single ELO ladder, matched by a competitiveness score, and settle
  contested results through an administrative ruling that corrects the ladder rather than
  double-applying to it.
- **Administrators** rule on disputes, suspend accounts with a full cascade, change platform
  policy live, and export reconciled financial CSVs.

The product is three independent processes — a Flutter client, a Node/Express API and a
Python model server — over one PostgreSQL database.

| | |
|---|---|
| **Scale** | ~134,000 lines — 56k Dart, 48k JavaScript, 27k Python, 3.3k SQL · 56 mobile screens · 150+ REST endpoints · 37 tables · 22 forward-only migrations |
| **Money** | Escrow ledger with a complete transaction history, settled inside SQL transactions under `FOR UPDATE` |
| **Machine learning** | Four models trained from scratch — no third-party AI API anywhere in the product path — each released only through automated gates |
| **Verification** | ~2,200 automated assertions, including suites that execute real money movements against the live schema inside a rolled-back transaction |

<!--
  SCREENSHOTS — the highest-impact addition still missing from this file.
  Add 4-6 PNGs under doc/screenshots/ (venue discovery, booking checkout, owner
  pricing dashboard, live tournament bracket, Scout chat, admin dispute ruling)
  and replace this comment with a table of them.
-->

---

## System architecture

Three processes over one database. The mobile client never reaches the model server; only the
API does.

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  FLUTTER (Android)                                    lib/ · 56 screens      │
│  Player · Owner · Admin surfaces · Provider state · Socket.IO client         │
└───────────────────────────────┬──────────────────────────────────────────────┘
                                │  HTTPS REST · Authorization: Bearer <JWT>
                                │  WebSocket — chat, match and notification events
                                ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│  NODE / EXPRESS  :3000                       backend/src · 150+ endpoints    │
│                                                                              │
│  routes/       21 routers — auth, venues, bookings, wallet, teams, matches,  │
│                tournaments, chat, notifications, reviews, assistant, admin   │
│  services/     bookingService (sole writer of bookings) · tournamentService  │
│                dialogManager · mlClient · pushService · suspensionService    │
│  utils/        escrow policy · ELO engine · trust score · CSV · settings     │
│  jobs/         7 background workers — no-show sweep, auto-approve, payouts,  │
│                match expiry, sentiment backfill, tournaments, push outbox    │
│  middleware/   JWT + database-backed role resolution · RBAC · rate limiting  │
└───────────┬──────────────────────────────────────────┬───────────────────────┘
            │ pg pool, parameterised SQL               │ HTTP · X-API-Key
            │ owner_id / user_id in every WHERE        │ 2 s timeout · breaker
            ▼                                          ▼  127.0.0.1:8000 only
┌───────────────────────────────┐   ┌──────────────────────────────────────────┐
│  POSTGRESQL (Supabase)        │   │  ML-SERVICE  FastAPI + uvicorn           │
│                               │   │                                          │
│  users · venues · slots       │   │  core/features.py       ★ contract       │
│  bookings · transactions      │   │  core/text_norm.py      ◆ contract       │
│  wallets · withdrawals        │   │  core/reco_features.py  ◆ contract       │
│  teams · matches · elo_history│   │  core/intent_spec.py    ◆ contract       │
│  tournaments · fixtures       │   │  core/registry.py — validates the        │
│  chat_channels · messages     │   │      stamped fingerprint of every        │
│  reviews · disputes           │   │      artifact before it serves a request │
│  notifications · admin_audit  │   │  routers/  pricing · sentiment · reco ·  │
│  assistant_turns              │   │            nlu                           │
└───────────────────────────────┘   └────────────────────┬─────────────────────┘
                                                         │ joblib.load, once, at boot
                                                         ▼
                                     models/{pricing,sentiment,reco,intent}_latest.joblib
                                                         ▲
                                                         │ written only if every gate passes
                                     training/  reproducible scripts → reports/
                                                (metrics, plots, model cards)
```

Three properties of that diagram are deliberate decisions rather than layering for its own
sake.

**The model server is stateless and optional.** It holds no database connection, no session
and no user model. When it is unreachable, `services/mlClient.js` opens a circuit breaker and
answers from a documented heuristic, labelling the response `source: "heuristic"` — so no
number is ever presented as model-derived when it is not.

**Feature engineering exists exactly once.** Each `★`/`◆` module is imported by both its
training script and its request handler, and its version plus a hash of the specification
itself is stamped into the artifact and re-checked at load. A contract change marks the model
`incompatible` and returns 503 rather than predicting on misaligned inputs — the classic
train/serve skew failure, closed mechanically instead of by comment.

**The shared secret never reaches a client.** The model server binds loopback, ships no CORS
middleware, compares its key with `hmac.compare_digest` rather than `==`, refuses to start
without a key, and returns an identical 401 for a missing and for a wrong one.

---

## Feature set

### Player

| Area | Capability |
|---|---|
| Discovery | Search and filter by sport, price, rating and city; personalised recommendation rail driven by a trained content-based model |
| Booking | Five-minute checkout hold on a slot, escrow-funded confirmation, owner approval or automatic approval after two hours, QR check-in |
| Wallet | Top-up, itemised frozen-balance breakdown, per-transaction receipts, withdrawal requests with a one-pending-request constraint |
| Cancellation | Full refund at 24 hours or more before start; inside the window, 80% refunded and 20% released to the owner |
| Teams | Create teams, hashed single-use invite links, captain and vice-captain authority, roster management, join requests |
| Competition | Challenge an opponent, submit results, contested submissions escalate to a dispute, ELO ladder and city rankings |
| Tournaments | Browse, register, pay entry fees, follow a live bracket through to podium |
| Reputation | Reviews with model-scored sentiment, and a four-component trust score |
| Chat | Team rooms, booking rooms with the venue owner, captain-to-captain coordination rooms, read receipts and presence |
| Assistant | Scout — an in-app assistant that answers questions and completes bookings and cancellations through the same money path as the REST API |

### Venue owner

| Area | Capability |
|---|---|
| Dashboard | Revenue today, pending request count, upcoming bookings, and a machine-learned price suggestion with a derived confidence figure |
| Pricing | 72-hour hourly demand forecast, and an apply action that writes the suggested price back to the affected slots under policy guardrails |
| Inventory | Month-view slot calendar, block and unblock, bulk future-slot generation |
| Requests | Approve or reject with the requesting player's trust score in view; a rejection refunds automatically |
| Check-in | QR scanner that releases escrow to the owner wallet on scan; no-show marking after a 30-minute grace period |
| Tournaments | Create with a live economics preview, seed the bracket, verify results, advance rounds |
| Reporting | Revenue trends, review moderation, and a financial CSV export |

### Administrator

| Area | Capability |
|---|---|
| Disputes | Rule on a contested match; the ruling reuses the verified settlement path and corrects ELO by writing a reversal plus a new exchange, so a rating is never double-applied |
| Accounts | Suspend and reinstate with a full transactional cascade — bookings cancelled and refunded, challenges withdrawn, tournament registrations withdrawn, owner venues deactivated; reinstatement restores only what the suspension took down |
| Policy | 26 platform settings validated so that write bounds are a subset of read clamps, applied live with no restart |
| Moderation | Review queue fed by flags and by model auto-escalation |
| Audit | Every administrative action recorded in an append-only audit table |
| Export | Platform-wide financial CSV with per-owner commission, reconciled against the transaction ledger |

### Platform services

- **Real-time layer** — Socket.IO rooms for chat, match events and notifications, with
  two-watermark read receipts and presence.
- **Notifications** — 45 notification types mapped to 9 deep-link routes by a server-owned
  registry that is asserted at boot; push delivery runs as a transactional outbox so a
  notification is atomic with the money that caused it.
- **Background workers** — no-show sweep, auto-approval, withdrawal settlement, match expiry,
  sentiment backfill, tournament progression and push drain.

---

## Machine learning

Four models, all trained inside this repository from data this project owns. No external AI
API is called anywhere in the product path.

Every model is released by a training script that must pass a fixed set of named gates before
the served artifact is written — a failing run leaves the previous artifact in place, so a bad
retrain cannot take the application down with it.

| # | Model | Approach | Headline result | Gates |
|---|---|---|---|---|
| 1 | **Dynamic pricing** | `HistGradientBoostingClassifier` with a monotonic constraint on price, modelling `P(booked ǀ features, price)`. Price is an input, so one model serves both the 72-hour demand forecast and the price suggestion — the latter as `argmax(price × P(book))`, expected revenue rather than probability | ROC-AUC **0.7628**, which is **98.2% of a measured Bayes ceiling** of 0.7770; Brier 0.1680 | 12/12 |
| 2 | **Review sentiment** | `LinearSVC` over a word ∪ character-n-gram TF-IDF union, with a softmax over the decision function so the reported class scores can never contradict the predicted label | **0.8250** accuracy, 0.8247 macro-F1 on a 200-row hand-labelled in-domain exam, against a 0.3400 majority baseline | 7/7 |
| 3 | **Venue recommender** | Content-based ranking — a fitted vector space per venue, scored by cosine against a recency-weighted user profile. No learned weights, and documented as such | HitRate@5 **0.461** against **0.371** for the cold-start path the application actually falls back to: a **+24.2%** improvement | 3/3 |
| 4 | **Assistant intent** | `LinearSVC` with sigmoid calibration over 18,849 word and character features, cross-validation folds grouped by source template to prevent phrasing leakage | **0.8086** accuracy / 0.8042 macro-F1 on unseen phrasings across **23 intents**; 0.6696 on a hash-locked 230-row hand-written exam, against a 0.0435 majority baseline | 10/10 |

Four practices in this tier are worth singling out, because they are what makes the numbers
above checkable rather than merely stated:

- **Reproducibility.** Each training script reproduces its served artifact bit-for-bit from a
  documented default seed. `training/train_pricing.py --seed 42` produced the released pricing
  model and reproduces all nine of its metrics to six decimal places in roughly 68 seconds.
- **Published evidence.** `ml-service/reports/` is committed: metrics JSON, calibration and
  confusion plots, and a model card per model — including the results that are unflattering.
  The sentiment model scores 0.8250 on in-domain review text and 0.6447 on an open-domain
  validation split, and both figures are published, because the second one is what shows the
  model is specialised rather than general.
- **Measured thresholds.** The abuse-escalation threshold and the intent-confidence floor are
  measured against held-out data, written into the artifact and read back at serve time. An
  earlier hard-coded probability threshold silently stopped working when regularisation
  changed, which is the reason this is now a property of the artifact rather than a constant.
- **Honest abstention.** The intent classifier declines to answer through three measured
  reasons — low confidence, no evidence, and no recognised vocabulary. Character n-grams will
  always find texture in nonsense, so a confidence floor alone is not enough: the third reason
  catches 85 of 87 gibberish probes at 0.022 ms per call.

---

## Engineering highlights

The decisions below are the ones most worth discussing in a technical interview.

**Money is settled in SQL, not in application code.** Every balance change happens inside a
transaction that has already taken `FOR UPDATE` on the rows it will modify, and writes a
ledger row for each leg. Across the request-serving code, `INSERT INTO bookings` appears in
exactly one file — `services/bookingService.js` — and the REST routes, the assistant and
administrative rulings all go through it, so they cannot drift into three different
definitions of what a booking costs. Seed and verification scripts insert fixture rows
directly; nothing that serves a user does.

**A contested result is corrected, never re-applied.** When two captains submit conflicting
scores, the match escalates to a dispute instead of trusting whoever submitted first. An
administrator's ruling then reuses the same settlement function the normal path uses, and
repairs the ladder by writing an explicit reversal row followed by a fresh exchange — so
`elo_history` stays a replayable audit trail and no rating is ever counted twice.

**Authorisation is resolved against the database, not the token.** The JWT proves identity
only. Role and account status are read from `users` on each request behind a 30-second cache
that is invalidated the moment an administrator suspends an account, so a suspension takes
effect immediately rather than whenever the token happens to expire.

**Concurrency is closed at the row, not in the service layer.** A checkout hold is a real row
with a five-minute expiry; a partial unique index makes a double-booked slot unrepresentable
rather than merely unlikely; and the push outbox is drained under `FOR UPDATE SKIP LOCKED`, so
two workers can never deliver the same notification twice.

**The schema is forward-only and asserted, not assumed.** 22 numbered migrations, each applied
by its own runner which then probes what that migration was supposed to change — including the
failure it exists to remove and the guard it must not have removed along with it.
`verify_schema.js` independently checks 233 properties — tables, columns, types, constraints,
indexes and triggers — against the live database. A migration counts as applied when those
scripts say so, not when the SQL appears to have succeeded.

---

## Technology stack

| Layer | Technology |
|---|---|
| **Mobile** | Flutter (Android) · Dart 3.10 · Provider · `socket_io_client` · `mobile_scanner` · `qr_flutter` · `table_calendar` · `fl_chart` · `google_fonts` |
| **API** | Node.js 20+ · Express 5 · `pg` with a pooled, fully parameterised query layer · Socket.IO 4 · `jsonwebtoken` · `bcrypt` · `helmet` · `express-rate-limit` |
| **Database** | PostgreSQL on Supabase — 37 tables, 22 forward-only migrations, triggers and partial unique indexes doing real work |
| **Models** | Python 3.14 · FastAPI 0.141 · uvicorn · scikit-learn 1.9 · pandas 3.0 · NumPy 2.5 · joblib · matplotlib, all version-pinned exactly |
| **Push** | Firebase Cloud Messaging through `firebase-admin`, behind a transactional outbox; the platform runs with push dormant if no service account is configured |
| **Media** | Cloudinary, uploaded directly from the client through an unsigned preset |
| **Verification** | `node:test` · purpose-built check scripts that execute against the live schema · `flutter analyze` |

---

## Quality assurance

Roughly 2,200 assertions run across thirteen suites. The counts below are the figures those
scripts print, not estimates.

| Suite | Assertions | Scope |
|---|---|---|
| `check_tournaments.js` | 441 | Bracket generation, seeding, the prize waterfall, slot reservation, round advancement |
| `check_assistant.js` | 342 | All 30 assistant actions, the money doors, abstention, session state |
| `check_admin.js` | 275 | Dispute rulings, the suspension cascade and its reinstatement, settings validation, audit rows, CSV export |
| `verify_schema.js` | 233 | 233 schema properties checked against the live Supabase database |
| `check_assistant_http.js` | 173 | The same assistant flows over real HTTP with real JWTs |
| `check_notifications.js` | 169 | 45 types mapped to 9 routes, outbox state transitions, badge arithmetic |
| `npm test` (`node:test`) | 159 | Escrow policy, ELO arithmetic, validators, utilities |
| `check_chat.js` | 120 | Channel authority, two-watermark read receipts, presence |
| `check_ml_service.js` | 71 | Contract fingerprints, key handling, the circuit breaker, heuristic fallback |
| `run_match_flow_check.js` | 69 | Challenge → result → dispute → ruling, end to end |
| `test_nlu.py` | 68 | Intent parsing, slot extraction, the three abstention reasons |
| `check_booking_service.js` | 60 | Hold expiry, escrow release, refund splits, the cancellation window |
| `check_price_sanity.js` | 20 | Monotonicity and policy guardrails on served prices |
| **Total** | **2,200** | plus `flutter analyze` — **0 issues** across 139 Dart files |

Several of these are deliberately not unit tests. `check_admin.js`,
`check_booking_service.js` and `run_match_flow_check.js` open a transaction against the live
database, execute genuine bookings, refunds, suspensions and ELO exchanges, assert the ledger
rows that result, and then roll back. Mocks cannot show that the money math holds under the
actual constraints, triggers and indexes; this can.

---

## Repository layout

```
sportlynk/
├── lib/                      Flutter client — 139 files, 56 screens
│   ├── screens/              player · owner · admin · auth · chat · scout
│   ├── providers/            Provider state containers
│   ├── services/             typed REST + Socket.IO clients
│   ├── models/               request and response models
│   ├── widgets/              shared components
│   └── constants/  utils/    theme, routes and formatting helpers
├── backend/
│   ├── src/
│   │   ├── routes/           21 routers
│   │   ├── services/         booking · tournament · dialog manager · ML client · push
│   │   ├── middleware/       auth · RBAC · rate limiting · error handling
│   │   ├── jobs/             7 background workers
│   │   ├── utils/            escrow · ELO · trust score · CSV · settings
│   │   └── scripts/          seeds and the verification suites
│   ├── migrations/           22 forward-only SQL migrations, one runner each
│   └── test/                 node:test suites
├── ml-service/
│   ├── app/core/             frozen feature contracts + the artifact registry
│   ├── app/routers/          pricing · sentiment · reco · nlu
│   ├── training/             reproducible training scripts
│   ├── models/               released .joblib artifacts
│   └── reports/              metrics, plots and model cards
└── doc/                      architecture, API, database and feature references
```

---

## Getting started

Requires Node.js 20+, the Flutter SDK with Dart 3.10+, Python 3.14, and a PostgreSQL
database. Supabase is what this project uses, in development and for the demo.

### 1 · API

```bash
cd backend
npm install
cp .env.example .env      # DATABASE_URL and JWT_SECRET are the only required values
npm run dev               # nodemon; `npm start` for plain node
```

`.env.example` is the committed contract — every variable the backend reads is listed and
explained there. The schema is applied one migration at a time (`node run_migration_022.js`)
and then confirmed against the live database:

```bash
node src/scripts/verify_schema.js    # prints 233/233 when the database matches the code
curl http://localhost:3000/api/health
```

### 2 · Model server (optional)

```bash
cd ml-service
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
Copy-Item .env.example .env          # then set ML_API_KEY
.\run_dev.ps1                        # 127.0.0.1:8000
```

`ML_API_KEY` must be byte-identical to the value in `backend/.env`. Compare the fingerprints
rather than the keys: `/health` publishes `apiKeyFingerprint`, and
`node src/scripts/check_ml_service.js` prints the same digest from the Node side — equal
fingerprints mean equal keys, and neither secret is ever printed. The API runs perfectly well
without this service; pricing, sentiment and recommendations simply report
`source: "heuristic"` and the demand forecast is withheld.

### 3 · Mobile client

The app reads its API address from one build-time variable, `API_BASE_URL`. Nothing else in
the client hard-codes a host.

| Target | Command |
|---|---|
| Android emulator | `flutter run` — `10.0.2.2` is the emulator's alias for the host machine |
| Physical device, same Wi-Fi | `flutter run --dart-define=API_BASE_URL=http://<host-LAN-IP>:3000/api` |
| Physical device, USB | `adb reverse tcp:3000 tcp:3000`, then `flutter run` |
| Deployed API | `flutter run --dart-define=API_BASE_URL=https://<host>/api` |

```bash
flutter build apk --release --dart-define=API_BASE_URL=https://<host>/api
```

A physical device always needs `--dart-define`; plain `flutter run` targets `10.0.2.2`, which
resolves only inside an emulator.

### 4 · Demo data (optional)

```bash
cd backend && npm run seed:venues
```

This removes the first owner account's existing venues, slots, bookings and their transaction
rows before inserting ten demo venues. It prints what it is about to delete and waits five
seconds. User accounts and wallet balances are not touched.

---

## API surface

Every response uses one envelope, so the client has a single success path and a single error
path:

```json
{ "success": true,  "data": { } }
{ "success": false, "message": "Human-readable reason" }
```

Authentication is `Authorization: Bearer <JWT>`. Role and account status are resolved from the
database on each request, not read out of the token.

| Mount | Responsibility |
|---|---|
| `/api/auth` | Registration, login, phone verification, token refresh |
| `/api/venues` · `/api/slots` | Discovery, search and filtering, slot availability, recommendations |
| `/api/bookings` | Checkout hold, escrow-funded confirmation, cancellation, QR check-in |
| `/api/wallet` | Balance and frozen breakdown, top-up, transactions, withdrawal requests |
| `/api/player` · `/api/users` | Profiles, trust score, booking history, saved venues |
| `/api/owner` | Dashboard, requests, slot inventory, price suggestion and demand forecast, revenue reporting, CSV export |
| `/api/teams` | Teams, invite links, roster and join requests, ELO standings |
| `/api/matches` | Challenges, result submission, disputes, ladder and city rankings |
| `/api/tournaments` | Creation, registration, brackets, fixtures, verification, advancement |
| `/api/chat` | Channels, message history, read watermarks |
| `/api/notifications` | Feed, unread badge, read and read-all, device token registration |
| `/api/assistant` | Scout — one conversational endpoint plus session state |
| `/api/admin` | Disputes, accounts and suspensions, platform settings, moderation, audit, export |
| `/api/reviews` | Reviews with model-scored sentiment, flags, owner responses |
| `/api/internal` | Service-to-service only; a separate key from the model-server key |
| `/api/health` | Liveness, plus whether the database connection is up |

Full request and response shapes for all 150+ endpoints are in
[`doc/API.md`](doc/API.md).

---

## Documentation

| Document | Contents |
|---|---|
| [`doc/ARCHITECTURE.md`](doc/ARCHITECTURE.md) | Layer boundaries, the ML trust boundary, request lifecycle |
| [`doc/DATABASE.md`](doc/DATABASE.md) | All 37 tables, every migration, and how the schema is verified |
| [`doc/API.md`](doc/API.md) | Endpoint reference with request and response bodies |
| [`doc/FEATURES.md`](doc/FEATURES.md) | Feature-by-feature functional detail |
| [`doc/CODING_STANDARDS.md`](doc/CODING_STANDARDS.md) | Conventions this codebase follows |
| [`doc/TESTING.md`](doc/TESTING.md) | What each suite covers and how to run it |
| `doc/*_evidence.md` | Recorded verification transcripts for Scout, tournaments, notifications, chat and admin |
| [`doc/PROJECT.md`](doc/PROJECT.md) | Scope, module breakdown, academic context |
| [`doc/DEPLOY_GUIDE.md`](doc/DEPLOY_GUIDE.md) | Deployment and demo-day walkthrough |
| [`ml-service/README.md`](ml-service/README.md) | Model server: contracts, registry, key handling |
| [`ml-service/reports/`](ml-service/reports/) | Metrics, plots and a model card for each of the four models |

---

## Project context

SportLynk is a final-year project at COMSATS University Islamabad, developed across two
semesters against a written requirements specification. It is a working system rather than a
prototype: the money paths, the ladder and all four models are exercised against the live
schema by the suites listed above.

| | |
|---|---|
| Developer | **Mudassar Akram** — SP23-BSE-028 |
| Developer | **Muhammad Anees** — SP23-BSE-030 |
| Supervisor | Miss Ayesha Hussain |
| Institution | COMSATS University Islamabad |

Two points belong in the open rather than left for a reader to infer:

- **The behavioural data is synthetic.** There are no real players or venues yet, so the
  pricing and recommender models are trained on generated booking histories built to a
  documented distribution, and the recommender's +24.2% is measured on simulated users. The
  sentiment and intent models are instead evaluated on hand-written, hand-labelled exam sets —
  which is why those two report human-labelled accuracy and the other two report ranking and
  calibration metrics.
- **What remains.** The model server has yet to be deployed behind a public URL, with the
  shared key rotated as part of that step. Everything else described above runs today.

---

## Licence

This repository carries no licence file, so all rights are reserved. Please get in touch before
reusing any part of it.
