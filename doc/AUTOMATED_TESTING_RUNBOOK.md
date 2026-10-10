# SportLynk — Automated Testing: Viva Runbook & Evidence Capture

The practical companion to `doc/AUTOMATED_TESTING.md`. That file is the **report**
(strategy, tools, environment, coverage map, test cases). **This file is the runbook**:
how to answer the committee's questions out loud, and the exact steps to produce the
screenshots and evidence they ask for.

Use it in three passes:
1. **Prepare** — run everything once, days before, and fix what is red (§5 first).
2. **Capture** — run again and screenshot, following §3, into `doc/evidence/`.
3. **Defend** — rehearse the answers in §1 and §2.

---

## 1. The 30-second answer (your opening)

Memorise this. It is the first thing you say when automated testing comes up.

> "We automated testing at four levels — static analysis, unit tests, integration /
> end-to-end tests, and machine-learning model evaluation. The app has around **3,400**
> Flutter widget and unit tests, the API has **360+** unit tests on Node's built-in test
> runner, and on top of that we wrote an integration harness that drives real booking,
> payment, chat and assistant flows against the live database and prints a pass/fail
> receipt for each one. The ML models are trained in-project and each has release gates
> and a model card. I can show the output for any of these."

Then stop and let them pick what to see. You have a screenshot ready for each claim (§3).

> Replace the two numbers with your **freshly re-run** counts (§5). Do not quote the
> `159/159` written in old docs — the suite has grown well past it.

---

## 2. Likely questions and how to answer

| They ask | You answer |
|---|---|
| **"Which testing tool / framework did you use?"** | "The native framework for each language: **`flutter_test`** for the Flutter app, **`node:test`** (Node's built-in runner) for the Express API, and **`pytest`** / standalone scripts for the Python ML service. End-to-end flows run through custom harness scripts that hit the real HTTP API and database." |
| **"Why not Selenium / Cypress / Java (JUnit)?"** | "Selenium and Cypress drive a web page's HTML **DOM**. Our client is a **Flutter** app that paints to a **canvas**, not a DOM, so their selectors can't address our widgets — they're the wrong tool for this stack, not a missing one. JUnit tests Java, and we have no Java application code. The equivalent discipline — unit, integration, E2E — is all present, in the frameworks native to Dart, Node and Python." |
| **"What is your testing strategy?"** | "A testing pyramid, run bottom-up: static analysis → unit tests → integration/E2E → ML evaluation → manual on-device checks. A failure at a lower layer makes the layers above it meaningless, so we always run cheapest-first." |
| **"What is your test environment?"** | "Windows, API on port 3000, ML service on 8000, Supabase PostgreSQL as the database. Unit tests run completely **offline**. Integration tests run against the real database but **inside a transaction that is rolled back**, so they prove the real flow and leave nothing behind." |
| **"You tested against your production database?"** | "Yes — there is one Supabase project — but safely. Every integration run is wrapped in `BEGIN … ROLLBACK`: it reads and writes real rows during the test, then discards all of it. Nothing persists." (This answer turns a worry into a strength — lead with it rather than wait for it.) |
| **"How do we know the ML is real and not an external AI API?"** | "All four models are trained in-project with scikit-learn and saved as artifacts; there is **no external AI API in the request path**. Each model must pass release gates to be published, and each has a model card recording its metrics against a baseline. The assistant's understanding is our own trained intent classifier, and every reply carries a `source` label." |
| **"Is the UI tested automatically?"** | "Individual screens and widgets are covered by offline widget tests. Full UI user-journeys are verified **on-device, by hand** — that is a deliberate boundary, because automated UI E2E on Flutter needs the `integration_test` driver, which is the next step if required." (Honest; do not claim automated UI E2E you do not have.) |
| **"How many tests / what coverage?"** | Give the fresh counts from §5. If pressed on %: "We can produce a coverage report with `flutter test --coverage`; our effort is concentrated on the high-risk logic — money, ELO, tournament brackets, parsers — which is near-fully unit-tested." |
| **"Show evidence it actually ran."** | Open a screenshot (§3) **and** a generated evidence pack (`doc/*_evidence.md`) — the pack names the commit, the model version, and lists every assertion with the real transcript. More auditable than a screenshot. |

---

## 3. Evidence-capture runbook

Run each block, confirm the output matches "What you'll see", then screenshot and save
under the given name. Put every file in `doc/evidence/`.

### 3.0 Preconditions

- Two terminals for the server-dependent steps: **API** (`cd backend; npm run dev`) and
  **ML service** (`cd ml-service; .\run_dev.ps1`). Start them before §3.2–3.3.
- Make the terminal font large and the window wide enough that the **command and the
  summary line are in one frame**. A screenshot that doesn't show the command proves
  nothing.

### 3.1 Offline gates — safe, fast, no servers needed

```powershell
# Flutter static analysis (repo root)
flutter analyze
```
*What you'll see:* `No issues found! (ran in Xs)` — **screenshot** → `01_flutter_analyze.png`

```powershell
# Flutter unit + widget tests (repo root)
flutter test
```
*What you'll see:* a stream of `+N` counters ending in `+NNNN: All tests passed!` (green).
If it ends `+NNNN -M: Some tests failed`, **stop** — go to §5. **screenshot** →
`02_flutter_test.png`

```powershell
# API unit tests (backend/)
npm test
```
*What you'll see:* a summary block —
```
ℹ tests 362
ℹ pass 362
ℹ fail 0
```
**screenshot** → `03_npm_test.png`

```powershell
# ML service static + contract self-check (ml-service/, venv interpreter)
.\.venv\Scripts\python.exe -m compileall app training
.\.venv\Scripts\python.exe app\core\intent_spec.py --self-check
.\.venv\Scripts\python.exe training\test_nlu.py
```
*What you'll see:* `compileall` lists compiled files with no error; the self-check prints
two fingerprints (`assistant-intents-v2`, `assistant-dataset-v2`); `test_nlu.py` ends with
a pass count (~68). **screenshot** → `04_ml_selfcheck.png`

### 3.2 Integration gates — need both servers + the live DB (rolled back)

```powershell
# from backend/, with API + ML service running
node run_match_flow_check.js             # match lifecycle E2E
node src/scripts/check_booking_service.js   # money path: book/cancel/refund
node src/scripts/check_ml_service.js     # ML up-path AND down-path
npm run check:scout                      # the assistant, end to end
```
*What you'll see:* each ends with a line like `PASS n/n` (and `check_ml_service` passes
both with the service up and down). **screenshot each** →
`05_match_flow.png`, `06_check_booking.png`, `07_check_ml.png`, `08_check_scout.png`

> `check_tournaments.js` can read `FAIL 2/3` on drifted demo data — **re-seed before
> trusting or screenshotting it** (see §5). Do not present its red as a result.

### 3.3 Regenerate the evidence packs (do this — the committed ones are old)

```powershell
# backend/, both servers running
npm run evidence                                   # doc/scout_evidence.md
node src/scripts/check_tournaments.js --evidence   # doc/tournament_evidence.md
node src/scripts/check_chat.js --evidence          # doc/chat_evidence.md
node src/scripts/check_notifications.js --evidence # doc/notification_evidence.md
node src/scripts/check_admin.js --evidence         # doc/admin_evidence.md
```
These rewrite `doc/*_evidence.md` with the **current** commit hash, model version, and
every assertion. Copy them into `doc/evidence/10_evidence_packs/`. You can screenshot the
top of each (the `PASS n/n` header + provenance table) for slides.

### 3.4 ML reports and figures (already on disk — just collect)

Copy these into `doc/evidence/09_ml_figures/` and reference them directly:
- Model cards: `ml-service/reports/model_card_{pricing,sentiment,reco,intent}.md`
- Metrics JSON: `ml-service/reports/{pricing,sentiment,intent}_metrics.json`, `reco_eval_metrics.json`
- Figures (open and screenshot, or copy the PNGs): `calibration_pricing.png`,
  `confusion_matrix_sentiment.png`, `intents_confusion.png`, `intent_reliability.png`,
  `demand_patterns.png`

### 3.5 The full test-case list (for the appendix)

```powershell
# backend test case titles
Select-String -Path "backend/test/*.test.js" -Pattern "^\s*(test|it)\(" | ForEach-Object { $_.Line.Trim() } > doc/evidence/11_backend_cases.txt
# flutter test case titles
Select-String -Path "test/**/*_test.dart" -Pattern "(testWidgets|test)\(" | ForEach-Object { $_.Line.Trim() } > doc/evidence/11_flutter_cases.txt
```
Each test title *is* a test-case description — this is your "every automated test case"
appendix, generated instead of transcribed.

---

## 4. Requirement → evidence map

Tick each committee bullet against the artifact that satisfies it.

| Committee requirement | Where it is satisfied |
|---|---|
| Automated tests for the core functionality | §4 coverage table in `AUTOMATED_TESTING.md`; the suites in §3.1–3.2 here |
| State the **testing strategy** | §1 of `AUTOMATED_TESTING.md` (the pyramid); §1–§2 here |
| State the **automation tool / framework** | §2 of `AUTOMATED_TESTING.md`; the Q&A row here |
| State the **testing environment** | §3 of `AUTOMATED_TESTING.md`; the Q&A row here |
| **Automated test cases** documented | §5 of `AUTOMATED_TESTING.md` + the generated list (§3.5 here) |
| **Evidence of execution** | terminal screenshots `01–08` (§3.1–3.2) |
| **Test results** | the `PASS n/n` lines; model cards + metrics JSON (§3.4) |
| **Screenshots** | the shot list in §5 |

---

## 5. Before you capture anything — the honesty pre-flight

Do these a few days early. The whole submission's credibility rests on the numbers being
real; one stale or red screenshot presented as green is the fastest way to lose trust.

1. **Run `flutter test` and resolve every failure.** The last full run was **not** confirmed
   green — it had a cluster of failures, and one layout fix was never runtime-verified. Run
   it, fix or annotate each red test, and only screenshot it once it genuinely passes. If a
   test is red for a reason you understand and accept, be ready to say so — don't hide it.
2. **Regenerate the evidence packs (§3.3).** The committed copies carry August commit
   hashes against code that has changed since. Present current ones.
3. **Re-seed before `check_tournaments.js`.** It fails on drifted demo data by default;
   that red is a data problem, not a test result.
4. **Do not quote stale or unverified numbers.** Not the old `npm test 159/159`, and not a
   bare ML accuracy headline — the served models were retrained since their cards and one
   figure looked abnormally high. Quote the **methodology** (gates, baselines, confidence
   intervals) and re-run the eval to confirm any number you say out loud.
5. **Count what you'll claim.** Run `npm test` and `flutter test` once and write the real
   totals into §1's opening and your slides.

---

## 6. If you must run tests live

Order matters — run the cheap, safe, fast things live; have the slow/server-dependent
evidence pre-captured.

1. **Live, on screen:** `flutter analyze`, then `npm test` (seconds, offline, impossible to
   embarrass you). Optionally `flutter test` if you have ~1–2 minutes.
2. **Pre-captured, shown as screenshots / packs:** everything in §3.2–3.3 — they need both
   servers and the live DB and take longer; run them before, show the receipts.
3. **If demoing against the hosted (Render) backend:** open `/health` once a minute before,
   to wake the free-tier services (cold start is 30–50s) so nothing times out on stage.

---

## 7. One paragraph for your slide / document

> SportLynk is tested with a four-level automated strategy — static analysis, unit tests,
> integration/end-to-end tests, and ML model evaluation — using each stack's native
> framework: `flutter_test` for the app, Node's built-in `node:test` for the API, and
> `pytest` for the Python ML service, with a custom harness for end-to-end flows. Unit
> tests run offline; integration tests run against the live Supabase database inside a
> rolled-back transaction, so real booking, payment, chat and assistant flows are proven
> without leaving test data behind. The four ML models are trained in-project, gated on
> release, and documented in model cards — no external AI API is in the request path.
> Selenium and Cypress are not used because they drive a web DOM, whereas a Flutter client
> renders to a canvas; the equivalent coverage is provided by widget tests and on-device
> verification. Every run emits a reproducible evidence pack recording the commit, model
> version and each assertion.
