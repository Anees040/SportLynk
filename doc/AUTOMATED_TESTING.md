# SportLynk — Automated Testing Report

Committee-facing summary of the project's automated testing: the strategy, the tools
and frameworks, the environment, the test cases, and the evidence of execution. It is
written to answer the four things the evaluation asks for, in order:

1. A clearly stated **testing strategy** (§1).
2. The **automation tools, frameworks and environment** used (§2, §3).
3. **Automated test cases** mapped to the core functionality (§4, §5).
4. **Evidence of execution** — how the results and screenshots are produced and where
   they live (§6).

This file is a report and an index. It does not restate the exhaustive QA guide in
`doc/TESTING.md` (2,900+ lines: per-wave manual steps, the adversarial security suite,
data-integrity SQL); it points at it. §7 is the honesty section — what is automated,
what is deliberately manual, and what must be regenerated before it is presented.

> One instruction before anything is captured. **Every recorded number in this repo is
> a snapshot that drifts.** `doc/CLAUDE.md` records `npm test 159/159` from end-of-S.7;
> the suite has since grown past 300. The committed evidence packs (`doc/*_evidence.md`)
> carry commit hashes from August 2026 against code that has moved every week since.
> So: **re-run the gates and regenerate the evidence packs against the current tree, and
> report those fresh numbers** — never the ones already written down. §6 is the procedure.

---

## 1. Testing strategy

### 1.1 The shape of it

Testing is layered, cheapest-first, and run bottom-up — a failure low down makes every
result above it meaningless. This pyramid is the strategy, and it is already in force in
the repo (`doc/TESTING.md` §0).

| Layer | What it proves | Tool | Cost | Lives in |
|---|---|---|---|---|
| **Static** | No syntax, type, or import errors; no dead code | `flutter analyze`, `node --check`, `compileall` | seconds | every file |
| **Unit** | Pure logic is correct: money math, ELO, brackets, parsers, model/DTO mapping | `node --test`, `flutter test` | seconds | `backend/test/`, `test/` |
| **Contract** | Frozen ML specs (feature order, label set, text normaliser) have not silently moved | `intent_spec.py --self-check`, fingerprint gates | seconds | `ml-service/app/core/` |
| **Integration / E2E** | Multi-step flows across route → service → DB (and → ML) behave, and money is conserved | `check_*.js`, `run_match_flow_check.js` | ~30s each | `backend/src/scripts/`, `backend/` |
| **ML evaluation** | A trained model beats its baseline and is not leaking | release gates, `eval_reco.py`, `test_nlu.py` | varies | `ml-service/training/` |
| **Manual E2E** | Real UX, real device, real timing | two phones / emulator | ~30 min | human, logged in `TESTING.md` |

### 1.2 The principles the suite is built on

These are the sentences to say in a viva; each is enforced somewhere in the code, not
just aspired to.

- **Test what you ship.** The thing measured is the thing served. ML eval scripts load
  the *released* `*_latest.joblib`, not a fresh fit. Integration scripts drive the
  *same* service functions the REST routes call.
- **Isolation without a second database.** There is no staging DB — development runs
  against the live Supabase project. Automated tests stay safe in two ways: unit tests
  run **with the database down** (no network at all), and every integration script wraps
  its work in a single `BEGIN … ROLLBACK` transaction, so nothing it writes survives the
  run. (The assistant harness degrades its `TXN` to a `SAVEPOINT` so an outer
  rollback still swallows 45 real turns.) This is the honest answer to "how do you test
  bookings and payments against the production database."
- **Assert the rows, not the reply.** Evidence scripts read the database rows an action
  produced (the booking, the ledger legs, the escrow balance) rather than trusting the
  text a service returned. The reply is the thing under test, not the proof.
- **Money is conserved.** Booking and cancellation tests assert that nothing was minted
  or burned across both wallets — the invariant, not just the happy path.
- **Degradation is a tested state, not an afterthought.** The ML integration script is
  run twice — service **up** and service **down** — and both are passes; the down-path
  (heuristic fallback, circuit breaker, honest "unavailable") is the one a real outage
  produces, so it is the more important of the two.
- **Provenance over vibes.** Every ML answer carries a source label; every evidence pack
  records the commit, the model version, and the threshold it ran against. "The model
  answered" is an auditable claim, not a feeling.
- **Honest numbers.** A confidence interval whose lower bound is below target is
  published, not hidden. A known-failing or drifted check is named, not quietly dropped.

---

## 2. Tools, frameworks and libraries

No third-party test runner is introduced anywhere — each stack uses its platform's
built-in testing tools, which is the right choice for an examiner to audit.

| Stack | Purpose | Tool / framework | Notes |
|---|---|---|---|
| **Flutter (client)** | Static analysis | `flutter analyze` | Gate is "No issues found"; ~2 min. |
| | Unit + widget tests | `flutter test` (`package:flutter_test`, `package:test`) | Built-in. Custom helpers: `test/widgets/widget_harness.dart`, `test/services/http_seam.dart` (injects fake API responses so screens are tested offline). |
| | Coverage (optional) | `flutter test --coverage` → `coverage/lcov.info` | Not currently wired into a report; available if the committee wants a coverage %. |
| **Node (API)** | Static check | `node --check <file>` | Syntax only, no execution. |
| | Unit tests | `node --test` (`node:test` + `node:assert`) | Built into Node ≥ 20. `npm test` runs `test/**/*.test.js`; **network-free (DB down)**. |
| | Integration / E2E + evidence | custom harness: `src/scripts/check_*.js`, `run_match_flow_check.js`, shared writer `src/scripts/lib/evidence.js` | Real `pg` pool + real HTTP + rolled-back transactions. `--evidence` emits a committed report. |
| | Coverage (optional) | `node --test --experimental-test-coverage` | Available; not wired to a report. |
| **Python (ML service)** | Static check | `python -m compileall app training` | Byte-compiles everything. |
| | Contract self-check | `python app/core/intent_spec.py --self-check` | Prints two fingerprints; a change means the label set or corpus moved. |
| | ML unit tests | `training/test_nlu.py` (standalone **and** under `pytest`) | ~68 tests, dates frozen to a fixed clock. |
| | ML smoke test | `training/smoke_sentiment_api.py` | ~49 checks against the released sentiment artifact. |
| | Release gates | built into `train_pricing.py` (12), `train_sentiment.py` (7), `train_intents.py` (10), `build_reco.py` (3) | Gate output is the evidence; **do not re-run training** (CLAUDE.md — breaks the provenance sha). |
| | Offline evaluation | `eval_reco.py`, `diff_intent_exam.py`, `validate_*` | Load released artifacts; no DB. |

**Languages / runtimes:** Dart + Flutter (client), Node ≥ 20 + Express 5 (API),
Python 3 + FastAPI + scikit-learn (ML). **Database:** Supabase PostgreSQL 17.

---

## 3. Test environment

| Component | Setting |
|---|---|
| OS / shell | Windows 11, PowerShell |
| API | Node ≥ 20, Express 5, `http://localhost:3000` — `npm run dev` |
| ML service | FastAPI + Uvicorn, `http://127.0.0.1:8000`, `X-API-Key` auth, loads 4 models at boot — `.\run_dev.ps1` |
| Database | Supabase PostgreSQL 17 (session pooler). **The development database is the production database** — there is no separate test DB; see the isolation rule in §1.2 |
| ML models under test | `pricing`, `sentiment`, `reco`, `intent` — `ml-service/models/*_latest.joblib` |
| Client — UI | Chrome at a Pixel 7 viewport (412×915), for layout/state only |
| Client — functional | Physical Android phone via `adb reverse tcp:3000 tcp:3000`, or emulator (`10.0.2.2:3000`) |
| Hosted (for a live demo) | Backend + ML service both deployed on Render (Docker); free tier cold-starts ~30–50 s, so wake `/health` before a demo |

**Preconditions for the integration layer.** The `check_*.js` scripts need the API
running, and most need the ML service running too; they read and write real Supabase
rows inside a rolled-back transaction. Start both servers by hand first, then run the
script. The two-team fixture used by the match/chat/tournament scripts is seeded by
`run_match_flow_check.js` (captains **Usman Ali** / **Hina Farooq**, owner **Ahmed
Khan**, F-11 Markaz Football Arena).

---

## 4. Automated coverage of the core functionality

Each core module and the automated suites that cover it. "Unit" = offline logic tests;
"Integration" = live rolled-back run against the DB (and ML where noted); "Evidence
pack" = a committed, regenerable `doc/*_evidence.md` report.

| Core functionality | Unit tests | Integration / evidence |
|---|---|---|
| **Auth, roles, password reset** | `backend/test/passwordReset.test.js`, `backend/test/userService.test.js`; Flutter: `test/screens/auth/*`, `test/widgets/auth_guard_test.dart` | role/suspension gate exercised in `check_admin.js` |
| **Venues, slots, search** | `backend/test/slotGrid.test.js`, `backend/test/geo_distance.test.js`; Flutter: `test/screens/player/find_venues_screen_test.dart`, `venue_detail_screen_test.dart` | `check_slots.js`, `check_booking_service.js` |
| **Bookings, escrow, wallet (money path)** | `backend/test/slotGroup.test.js`; Flutter wallet/booking screen + widget tests | `check_booking_service.js` (books/cancels for real, asserts the ledger; **60/60** last recorded), `check_booking_race.js`, `check_price_sanity.js` |
| **Teams, roster, invites** | `backend/test/requests.test.js`; Flutter: `test/screens/player/team_*`, `create_team_screen_test.dart` | covered within `run_match_flow_check.js` fixture |
| **Matchmaking + ELO** | `backend/test/elo.test.js`, `backend/test/fixtures.test.js`; Flutter: `match_*` tests | `run_match_flow_check.js` (**69/69** last recorded) |
| **Tournaments** | `backend/test/fixtures.test.js`, `backend/test/fixtureSchedule.test.js` (bracket + waterfall math) | `check_tournaments.js` → `doc/tournament_evidence.md` (**441/441** last recorded) |
| **Chat (team / booking / captain / assistant)** | `backend/test/chat.test.js`, `backend/test/chatReceipts.test.js`, `backend/test/mediaUrl.test.js`; Flutter: `test/widgets/chat/*`, `test/screens/shared/chat*` | `check_chat.js` → `doc/chat_evidence.md` (**120/120** last recorded) |
| **Reviews, Trust Score 2.0** | `backend/test/booking_disputes.test.js`; Flutter: `review_*`, `trust_*` tests | review flow proven by migration 017 probes + `check_ml_service.js` sentiment path |
| **Notifications** | Flutter: `test/screens/shared/notifications_screen_test.dart`, `notification_bell_test.dart` | `check_notifications.js` → `doc/notification_evidence.md` (**169/169** last recorded) |
| **Admin (disputes, suspension, settings, CSV export)** | Flutter: `test/screens/admin/*` | `check_admin.js` → `doc/admin_evidence.md` (**275/275** last recorded) |
| **Scout assistant (dialog, actions, threads)** | `backend/test/assistant.test.js`; Flutter: `test/widgets/assistant/*`, `assistant_screen_test.dart` | `check_assistant.js` + `check_assistant_http.js` → `doc/scout_evidence.md` (**326/326** + **173/173** last recorded); `check:scout:kb`, `check:scout:ctx` |
| **ML — pricing (model #1)** | — | release gates (12), `check_price_sanity.js`, `reports/model_card_pricing.md` + `pricing_metrics.json` |
| **ML — sentiment (model #2)** | — | release gates (7), `smoke_sentiment_api.py` (~49), `reports/model_card_sentiment.md` |
| **ML — venue recommender (model #3)** | — | release gates (3), `eval_reco.py`, `reports/model_card_reco.md` + `reco_eval.md` |
| **ML — intent classifier (model #4)** | `ml-service/training/test_nlu.py` (~68) | `intent_spec.py --self-check`, `reports/model_card_intent.md` + `intent_metrics.json` |

**Last-recorded suite sizes** (verify by re-running — see §6): backend `npm test`
~**360+** cases across 14 files; Flutter `flutter test` ~**3,400** cases across 130+
files. These grew well past the figures written in `doc/CLAUDE.md`.

**Known coverage gaps (deliberately manual, with the reason).** These are not automated
because the automation cost is higher than the risk, or because the platform makes them
un-automatable on a dev box — state them plainly rather than imply full automation:

- Firebase phone-auth OTP, locked-screen push banners, native media/camera pickers —
  no Firebase on web/CI, GUI-driven; covered by the on-device steps in `TESTING.md`.
- Pure visual polish (spacing, colour, typography) — judged by eye in Chrome.
- Live two-device chat and the admin by-hand pass — the final manual gates in
  `TESTING.md` §4.21–4.26.

---

## 5. Automated test cases

### 5.1 How a test case is recorded

Each automated test's **name is its specification**. A row in a test-case table is:

| Field | Source |
|---|---|
| ID | your numbering (e.g. `TC-BOOK-03`) |
| Title / description | the `test('…')` or `testWidgets('…')` string |
| Type | unit / integration / contract / ML-eval |
| Suite (file) | the file path |
| Precondition | fixture or server state (none, for offline unit tests) |
| Expected result | the assertion |
| Actual / status | filled from the run output (§6) |

The **complete** catalogue is therefore the list of every test title in `backend/test/`,
`test/`, and the ML test files. That list can be generated mechanically rather than typed
by hand (see §6.4) — which is the honest way to produce "every test case" for an appendix
without transcription error.

### 5.2 Representative cases (grounded in real assertions)

A starter sample across the core, drawn from assertions the suites actually make. Use it
as the format; expand it with §6.4.

| ID | Title | Type | Suite | Expected result |
|---|---|---|---|---|
| TC-ELO-01 | A verified match moves both teams' ELO and writes two history rows netting to zero | unit | `backend/test/elo.test.js` | both ratings updated; `elo_history` deltas sum to 0 |
| TC-ELO-02 | A disputed match freezes rating — no points move | unit | `backend/test/elo.test.js` | W/L recorded, no ELO change, no history row |
| TC-BOOK-01 | Cancel ≥ 24h before start → full refund | integration | `check_booking_service.js` | player credited 100%, escrow released, money conserved |
| TC-BOOK-02 | Cancel < 24h before start → 80% refund, 20% to owner | integration | `check_booking_service.js` | split matches `escrow.js`; both wallets reconcile |
| TC-BOOK-03 | Double-book race → exactly one booking succeeds | integration | `check_booking_race.js` | one confirmed, the other a clean error; never two on one slot |
| TC-TOUR-01 | Prize waterfall: venue cost recovered before any prize | unit | `backend/test/fixtures.test.js` | `prize = surplus × prize_percent`; owner never underwater |
| TC-TOUR-02 | Full tournament played out and audited | integration | `check_tournaments.js` | bracket advances; `k_factor` reads 40/48/56; no row for a bye |
| TC-CHAT-01 | A room opens on state change, not on a button | integration | `check_chat.js` | booking/captain channel created idempotently after approve/accept |
| TC-SCOUT-01 | A confident model-affirm cannot spend money | integration | `check_assistant.js` / `_http.js` | bookings unchanged, wallet unchanged; only chip/lexicon arms money |
| TC-SCOUT-02 | Deleting a chat keeps its telemetry, loses its text | integration | `check_assistant_http.js` | `assistant_turns` rows survive with `channel_id` nulled |
| TC-ML-01 | Price model served vs. heuristic fallback are both honest | integration | `check_ml_service.js` | up → `source:model`; down → `source:heuristic`, breaker opens, no fake score |
| TC-ML-02 | Intent contract fingerprints are stable | contract | `intent_spec.py --self-check` | prints `assistant-intents-v2` / `assistant-dataset-v2` unchanged |
| TC-ML-03 | Recommender beats the cold-start baseline it falls back to | ML-eval | `eval_reco.py` | HitRate@5 lift over cold-start ≥ gate; published with n caveat |

### 5.3 Model-behaviour test cases (ML)

ML "test cases" are the release gates and the exam/eval scores recorded in the model
cards (`ml-service/reports/model_card_*.md`) and metrics JSON. Present the **model card
as the test specification** and the metrics JSON as the result. Two cautions in §7.3
apply before any accuracy number is quoted.

---

## 6. Evidence of execution

The committee asks for evidence of test execution, test results, and screenshots. The
evidence is produced in four forms: **terminal output** (screenshot it), **generated
evidence packs** (committed `.md` files), **ML reports** (model cards, metrics JSON,
figures), and **the test-case list** (§6.4). Produce all of it against the *current*
tree.

### 6.1 Run the gates and screenshot the output

Run each from the stated directory and capture the final summary line.

```powershell
# Flutter (repo root) — screenshot the "No issues found" and the passed/failed tally
flutter analyze
flutter test
flutter test --coverage          # optional: produces coverage/lcov.info

# API (backend/) — screenshot the node:test summary (tests/pass/fail counts)
npm test

# API integration — START the API (npm run dev) and ML service (.\run_dev.ps1) first.
# Each prints "PASS n/n"; screenshot that line. These touch the live DB in a rolled-back txn.
node run_match_flow_check.js
node src/scripts/check_booking_service.js
node src/scripts/check_ml_service.js
npm run check:scout
npm run check:scout:http

# ML service (ml-service/, venv interpreter) — screenshot the output
.\.venv\Scripts\python.exe -m compileall app training
.\.venv\Scripts\python.exe app\core\intent_spec.py --self-check
.\.venv\Scripts\python.exe training\test_nlu.py
```

> `check_tournaments.js` has historically failed 2/3 on drifted demo data — re-seed
> before trusting it, and do not present a red result as a regression without checking
> that first (CLAUDE.md).

### 6.2 Regenerate the evidence packs

These write a human-readable, reproducible report (commit hash, model version, every
assertion, the real transcript) into `doc/`. **Regenerate them — the committed copies
are from August 2026.**

```powershell
# backend/, with both servers running
npm run evidence                           # → doc/scout_evidence.md (service + http blocks)
node src/scripts/check_tournaments.js --evidence   # → doc/tournament_evidence.md
node src/scripts/check_chat.js --evidence          # → doc/chat_evidence.md
node src/scripts/check_notifications.js --evidence # → doc/notification_evidence.md
node src/scripts/check_admin.js --evidence         # → doc/admin_evidence.md
```

An evidence pack is first-class committee material on its own: it names the commit it ran
against, lists every assertion in order, and reproduces the exact transcript — more
auditable than a screenshot. Include them in the appendix *and* screenshot the terminal
summary.

### 6.3 ML reports already on disk

Point the committee at these directly (regenerate figures only via the documented
re-render, never by retraining):

- Model cards: `ml-service/reports/model_card_{pricing,sentiment,reco,intent}.md`
- Metrics: `ml-service/reports/{pricing,sentiment,intent}_metrics.json`,
  `reco_eval_metrics.json`, `price_sanity.json`
- Figures (screenshot-ready PNGs): `calibration_pricing.png`, `price_response_pricing.png`,
  `importance_pricing.png`, `confusion_matrix_sentiment.png`, `intents_confusion.png`,
  `intent_reliability.png`, `demand_patterns.png`

### 6.4 Produce the full test-case appendix

The complete list of test cases is the list of all test titles. Generate it rather than
transcribe it (read-only; add it to the appendix):

```powershell
# Backend — every test case title
Select-String -Path "backend/test/*.test.js" -Pattern "^\s*(test|it)\(" 

# Flutter — every test case title
Select-String -Path "test/**/*_test.dart" -Pattern "(testWidgets|test)\("
```

### 6.5 Suggested evidence appendix layout

```
doc/evidence/
  01_flutter_analyze.png          02_flutter_test.png
  03_npm_test.png                 04_match_flow_check.png
  05_check_ml_service_up.png      06_check_ml_service_down.png
  07_check_scout.png              08_intent_self_check.png
  09_ml_figures/                  (the PNGs from §6.3)
  10_evidence_packs/              (copies of the regenerated doc/*_evidence.md)
  11_test_case_catalogue.md       (output of §6.4)
```

---

## 7. Honesty notes — read before presenting

The strongest thing in this submission is that it is honest; keep it that way.

### 7.1 Regenerate, do not quote stale numbers
`doc/CLAUDE.md` says `npm test 159/159`; the real figure is now higher. The evidence
packs are August-2026 commits against October code. **Re-run everything (§6) and quote
the fresh output.** Mixing a current claim with a stale number is the one defect an
examiner will find fastest.

### 7.2 `flutter test` is not confirmed green right now
The last recorded full run (~3,400 cases) had a known cluster of failures that were being
triaged (several screen tests updated to assert new offline-error behaviour, a
`find_venues` layout crash fixed but **not yet runtime-verified**). **Run `flutter test`
yourself, resolve or annotate every failure, and only then screenshot it.** Do not label
it green until it is. (You can run it directly; the only tool that has trouble with it is
this assistant's own sandbox, not your terminal.)

### 7.3 ML accuracy numbers need re-verification before quoting
The served models have been retrained since the model cards were written, so a card's
headline (e.g. pricing ROC-AUC 0.7628) may not match the currently-served artifact, and
one recent served pricing figure looked abnormally high in a way that can indicate data
leakage and has **not** been verified. Before quoting any ML accuracy to the committee:
re-run the eval/self-check against the served artifact, confirm the number, and quote the
model card's *methodology* (gates, baselines, confidence intervals) rather than a bare
headline. The methodology is defensible; an unverified number is not.

### 7.4 What is manual, and why
Push notifications, phone-auth OTP, native pickers, live two-device chat, and visual
polish are tested by hand (§4, last block). This is a legitimate testing strategy — state
it as a deliberate boundary, not a gap.

---

## 8. Scope of assistance — what is done vs. what you capture

Honest division of labour for finishing the committee deliverable.

| Task | Status |
|---|---|
| This report: strategy, tools, environment, coverage map | **Done** (this file) |
| Representative test-case table + the format | **Done** (§5); full catalogue is one command (§6.4) |
| Writing new automated tests for an uncovered feature | Possible on request — a separate task, needs code changes |
| Running the **offline** gates to capture counts (`npm test`, `compileall`, `intent_spec --self-check`, `test_nlu.py`) | Can be run on request to capture current numbers |
| Running the **live** gates (`check_*.js`, `check_ml_service.js`, evidence packs) | **You run these** — they need the two servers you start by hand and write to the production DB |
| `flutter analyze` / `flutter test` | **You run these** — reliable in your terminal; capture the screenshots there |
| **Screenshots** of any terminal, app, or figure | **You capture** — a GUI action no tool here can perform |
| On-device / two-phone E2E evidence | **You capture** — physical devices |
| Committing the regenerated packs and this doc | **You commit** — this repo's rule is that you own every commit |

**In one line:** the written deliverable — strategy, tools, environment, the coverage
map, the test-case catalogue, and the exact run-and-capture procedure — is complete here;
the execution screenshots and the live/on-device evidence are yours to capture, because
they are GUI actions and some touch the production database and the servers you control.
