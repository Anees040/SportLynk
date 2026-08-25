# SportLynk — Testing & QA Guide

How to prove this app works, how to prove it is not trivially exploitable, and how to
keep both true as more waves land. Written to be run by one person with two phones.

If you read only one thing: **§1 Preflight** is the cheap layer you run after every
change, **§6 Security** is the layer an FYP committee will actually probe, and
**§8 Working like a professional** is the habit set that makes the rest repeatable.

---

## 0. The testing pyramid, and why the order matters

Cheapest and fastest at the bottom. You always run bottom-up, because a failure at a
lower layer makes every result above it meaningless.

| Layer | What it catches | Cost | When |
|---|---|---|---|
| **Static** — `flutter analyze`, `node --check` | Typos, dead code, type errors, bad imports | seconds | Every save |
| **Unit** — `npm test` (ELO math) | Wrong formulas, wrong rounding, bad edge cases | seconds | Every backend change |
| **Integration** — `run_match_flow_check.js` | Broken multi-step flows, bad SQL, transaction bugs | ~30s | Before every commit |
| **Schema** — `verify_schema.js` | Drift between code's assumptions and the real DB | ~5s | After any migration |
| **Manual E2E** — two phones | Real UX, real timing, real race conditions | ~30 min | End of each wave |
| **Adversarial** — §6 | Vulnerabilities. Nothing above this line finds them | ~45 min | End of each sprint |

The mistake almost everyone makes is skipping straight to manual E2E because it *feels*
like real testing. It is the slowest and least repeatable layer. Earn the right to run
it by getting the four automated layers green first.

---

## 1. Preflight — run these before anything else

```bash
# ── Backend ────────────────────────────────────────────────
cd D:\sportlynk\backend

node --check src/routes/matches.js        # syntax only, no execution
node --check src/routes/teams.js
node --check src/utils/teamStats.js
node --check src/services/mlClient.js

npm test                                  # ELO unit tests   → expect 10/10
node src/scripts/verify_schema.js         # schema drift      → expect 113/113
node run_match_flow_check.js              # match E2E         → expect 69/69
node src/scripts/check_ml_service.js      # ML integration    → expect 0 FAILED

node src/server.js                        # expect a clean boot + 4 jobs, then Ctrl-C
```

```bash
# ── ML service (S.3 onward — OPTIONAL) ─────────────────────
# The backend does not need this running. check_ml_service.js passes either way:
# with the service down it skips the up-path checks and still proves degradation.
cd D:\sportlynk\ml-service
.\.venv\Scripts\Activate.ps1
python -c "from app.core import features; print(features.FEATURE_SPEC_VERSION, len(features.FEATURE_ORDER))"
.\run_dev.ps1                             # → http://127.0.0.1:8000, then Ctrl-C
```

```bash
# ── App ────────────────────────────────────────────────────
cd D:\sportlynk
flutter pub get
flutter analyze                           # expect: No issues found
```

**Interpreting failures.** A `node --check` failure is a typo — fix and rerun. A
`npm test` failure means the ELO math changed; never "fix" the test to match the code
without deciding which one is actually right. A `verify_schema` failure means a
migration did not run on Supabase. A `run_match_flow_check` failure prints the failing
check number — that number tells you the exact step in the match lifecycle that broke.
A `check_ml_service` failure names the check; `skip` lines are not failures, they mean
the ML service was not running, which is a supported state.

**Record the numbers.** `10/10 · 113/113 · 69/69 · analyze 0` is your green baseline.
Write it in the commit message. When something breaks three waves later, you will want
to know which commit last had all four green.

---

## 2. Environment & fixtures

- **Database:** Supabase is the only database (dev and demo). There is no separate local DB.
- **Timezone:** everything is stored in UTC and converted to PKT only in the Flutter layer.
  When a time looks 5 hours off, this is the first thing to check.
- **Money:** DECIMAL columns arrive from `pg` as **strings**. Any arithmetic must go
  through `asNum()`. A rupee value rendered as `"500.00500.00"` is string concatenation.

### Seeded accounts

| Role | Name | Use for |
|---|---|---|
| Player / captain A | **Bilal Raza** — team *E2E Falcons* | Challenger side |
| Player / captain B | **Hina Farooq** — team *E2E Titans* | Opponent side |
| Venue owner | **Ahmed Khan** | Booking approval, match verification |

Useful scripts: `seed.js`, `seed_venues.js`, `add_future_slots.js` (open bookable slots),
`push_booking_past.js` (make a booking look finished so you can test result submission
without waiting), `reconcile_wallets.js` (prove money invariants — see §7).

---

## 3. Feature tests — S1 (auth, venues, bookings, money)

Each row: do the action, confirm the expected result. A ✗ is a bug — log it per §8.

### 3.1 Auth & roles
1. Register a player → OTP → profile completes → lands on player home.
2. Register an owner → lands on **pending** screen, *not* the owner dashboard.
3. Admin approves the owner → owner can now reach the dashboard.
4. Log in as a player and try to open an owner-only screen → blocked.
5. Wrong password 5×+ → rate limit engages (§6.7).
6. Forgot password → reset → old password no longer works.

### 3.2 Venues & slots
7. Owner adds a venue → appears in their venue list.
8. Owner adds slots → visible to players in find-venues.
9. Player filters/searches venues → results are correct and the empty state is honest
   (a real "no venues match", not a spinner forever).
10. Venue detail shows correct price, images, and available slots in **PKT**.

### 3.3 Bookings & escrow — the money path
11. Player books a slot → pays **20% deposit** → booking is `pending`.
12. Owner approves → booking `confirmed`; **full price is frozen in escrow** at the
    price captured at booking time (a later venue price change must not move it).
13. Player cancels **more than 24h** before start → refund per policy.
14. Player cancels **less than 24h** before → deposit forfeited per policy.
15. Player never shows → after the **30-minute** no-show window, `noShowJob` resolves it.
16. Owner never responds → `autoApproveJob` resolves it.
17. Withdrawal request → `withdrawalJob` processes it.
18. **Double-book race:** two phones tap the same slot at the same instant → exactly one
    succeeds, the other gets a clean error. Never two confirmed bookings on one slot.

> Jobs are the easiest thing to forget to test because they are invisible. Confirm all
> four register at boot (`autoApprove`, `noShow`, `withdrawal`, `matchExpiry`), then use
> `push_booking_past.js` to trigger their conditions on demand instead of waiting.

---

## 4. Feature tests — S2 · S3 (teams, chat, matchmaking, ELO, ML tier)

### 4.1 Teams & membership (Wave A)
19. Create a team → creator is captain.
20. Generate an invite link → **expires after 48h**, and is **single-use**.
21. Second player joins via the link → appears in the roster.
22. Captain promotes a member to vice-captain → membership row changes.
23. Captain removes a member → they lose access, including to the team chat.
24. A **non-captain** attempts promote/remove → refused **by the server**, not just
    hidden in the UI (§6.2 — this is the one that matters).
25. Private team: a non-member opening its profile → 403, not a silent empty screen.

### 4.2 Team chat (Wave A)
26. Two phones, same team → messages arrive live, no refresh.
27. Send an image → renders for both.
28. Delete for everyone → the message body/media is **gone from the payload**, not just
    hidden client-side. Verify in the DB: `body`, `media_url`, `media_mime`, `waveform`
    should all be NULL.
29. Removed member can no longer read or post.
30. Membership system lines (joined / promoted / visibility changed) appear in the thread.

### 4.3 Matchmaking & ELO (Waves B–C)
31. Find opponents → suggestions render with real form/ELO, not placeholders.
32. Challenge a team **without** a confirmed booking → refused.
33. Challenge **with** a confirmed booking → opponent captain sees it.
34. Leave a challenge unanswered **48h** → it reads as expired (computed on read).
35. Both captains submit the **same** score → owner sees a verification task.
36. Owner verifies → **ELO moves for both teams**, `elo_history` rows are written, and a
    notification row is created — all in one transaction.
37. Both captains submit **conflicting** scores → match becomes `disputed`, **ELO frozen**,
    no rating movement.
38. A captain tries to submit **twice** → blocked by the DB UNIQUE constraint.
39. Dispute-ratio rule engages for a team that disputes repeatedly.

### 4.4 Rankings, stats & chart (Wave D)
40. Leaderboard lists **only teams with ≥1 played match** — a brand-new team must not
    appear at rank 1 with the 1000 seed.
41. An unranked team shows **"Unranked"**, never `1000`.
42. **Your team is highlighted** and marked `YOUR TEAM` (FR5.13).
43. Set a **City** on both teams (captain → team → Edit → City) → the city chip row
    appears; tapping a chip filters the board. "Lahore" and "lahore" must be **one** chip.
44. Rank **movement** vs 7 days ago: a brand-new entrant shows `NEW`, not `0`. `0` means
    genuinely unchanged. Up = green arrow, down = red.
45. Team profile shows **W/L/D and win rate** (FR5.15).
46. **ELO chart** (FR5.14): last 10 matches; **solid green dot = verified**, **hollow red
    dot = disputed**. A frozen-but-verified point is hollow grey. Fewer than 2 points →
    an honest "not enough history" state, not an empty box.
47. **Match history** (FR5.16): opponent name, `Won 2–1`, date, `+18 ELO`. A disputed row
    shows *No change*, not `+0`.
48. Pull-to-refresh and the offline/error state both behave (§5).

### 4.5 ML tier — service, key gate, degradation (S.3 Wave A)

Wave A ships **no model and no screen**. There is nothing to tap: the tests below are
service-level, and their whole purpose is to prove the plumbing is honest *before* a
model exists. Two terminals — `uvicorn` in `ml-service/`, `node src/server.js` in
`backend/`.

> **Once Wave C has been run, three of these expectations change — by design, not by
> regression.** With `models/pricing_latest.joblib` on disk the registry loads it, so:
> test 51 reports `modelsReady: 1` and the boot log says `pricing=loaded` with no warning;
> test 53 returns **`501 not_implemented`** instead of `503 model_not_loaded`, because the
> router now gets past `_require_model()` and reaches the inference branch Wave D writes;
> test 54 is unaffected and must **still** return 422, which is the whole point of writing
> it that way. To re-run §4.5 exactly as specified, move the artifact aside
> (`ren models\pricing_latest.joblib pricing_latest.joblib.bak`) and restart `uvicorn`.

49. `python -c "from app.core import features; print(features.FEATURE_SPEC_VERSION, len(features.FEATURE_ORDER))"`
    → `pricing-features-v1 11`. If this import fails, nothing below can be trusted.
50. `.\run_dev.ps1` → boots, and the log says `pricing=not_loaded` plus a **loud warning**
    that no model is loaded. A service that boots silently while unable to predict is the
    failure this line exists to catch.
51. `GET /health` with **no** key → **200** (it is deliberately public, so a monitor can
    reach it). Body carries `modelsReady: 0`, `modelsTotal: 1` and an `apiKeyFingerprint`.
    Grep the response for your key — it must **not** be in there.
52. `POST /predict/price` with **no** key → **401**. With a **wrong** key → **401**, and
    the two responses must be **byte-identical**: a different message for "missing" vs
    "wrong" tells an attacker their key format was accepted (§6.11).
53. With the **real** key and a valid body → **503 `model_not_loaded`**. Not a price. The
    ML service has **no heuristic of its own** — if it invented one, `source:'model'`
    would be a lie for the rest of the project's life.
54. With the real key and a **broken** body (negative price, `hour: 99`) → **422**, *not*
    503. Validation must not depend on a model being present, or Wave C silently changes
    which errors clients see.
55. `GET /features/spec` → `peakHours` and `priceRatioRange` match the constants in
    `mlClient.js`. Node cannot import Python, so those numbers are duplicated; this is the
    check that stops the two definitions of "peak" from drifting apart.
56. `node src/scripts/check_ml_service.js` with the service **UP** → `0 FAILED`.
57. Same script with the service **DOWN** → still `0 FAILED`. It builds its own failure
    conditions (a closed port for connection-refused, a socket that accepts and never
    answers for the timeout), so this path needs no second terminal and cannot be skipped.
    It proves: refused → heuristic price, timeout aborts **at** the 2s ceiling rather than
    hanging, and the breaker opens after 3 consecutive failures then short-circuits in
    <50 ms.
58. `node src/server.js` boots clean with the two `ML_*` lines set **and** with them
    commented out. The ML tier is optional by design — the API must not gain a hard
    dependency on a Python process.
59. Open the Flutter app and confirm **nothing changed**: no price suggestion, no forecast
    chart, no new spinner. If any of those appear, something got wired a wave early.

---

### 4.6 Demand simulator — the dataset and its figure (S.3 Wave B)

Wave B ships **no model, no endpoint and no screen**. It ships a dataset, the script that
writes it, and one figure. So these are not "does the app still work" tests — they are
*can somebody else reproduce this file, and is what it claims plausible?* One terminal:

```bash
cd D:\sportlynk\ml-service
.\.venv\Scripts\Activate.ps1
```

60. **Smoke first, always:**
    `python training\generate_bookings.py --rows 6000 --no-plot --out data\smoke.csv`
    → seconds, not minutes. A typo or a bad column name surfaces here instead of after a
    full 12-month simulate. Delete `data\smoke.csv` afterwards — it is not the dataset, and
    a 6000-row file left lying next to the real one will eventually get trained on.
61. `python training\generate_bookings.py` → writes `data\bookings_synth.csv`,
    `data\bookings_meta.json` and `reports\demand_patterns.png`, and prints **twelve check
    lines, all PASS**. On any FAIL the CSV is written to `*.rejected.csv` and the exit code
    is non-zero. A rejected file must **never** be renamed into place; the check that failed
    is telling you the dataset does not mean what the README says it means.
62. Run it again with no flags. `bookings_meta.json`'s `csv_sha256` must be **identical**.
    Reproducibility is the one property a synthetic dataset must have — it is the only
    reason to believe the model described in `reports/model_card_pricing.md` was trained on the
    file `data/README.md` describes.
63. `python training\generate_bookings.py --seed 7` → a **different** sha256, twelve PASS
    again. A generator that only passes on its lucky seed is a generator whose parameters
    were quietly tuned until the checks went green.
64. Read the `price_independence` check line. It reports the correlation between
    `price_ratio` and every demand driver; the largest absolute value must be near zero.
    **This is the most important line in the run.** `seed_venues.js:381` prices peak slots
    at 1.2× base; if the simulator reproduced that correlation, the model would learn
    "price up → bookings up" and Wave C's revenue maximiser would push every price to the
    1.50 ceiling — while still passing a monotonic-response gate on the training data.
65. Read `no_leak`. It asserts `latent_p`, `booked_gross` and `cancelled` are absent from
    `features.FEATURE_ORDER`. Those columns are in the CSV deliberately — Wave C measures
    calibration against ground truth with `latent_p` — and this check is the thing standing
    between them and the model.
66. Round-trip the CSV through the **serving** feature builder:
    ```bash
    python -c "import sys, pandas as pd; sys.path.insert(0,'.'); from app.core import features; d=pd.read_csv('data/bookings_synth.csv'); f=features.build_frame(d.to_dict('records')); features.validate_frame(f); print(f.shape, list(f.columns))"
    ```
    → `(<rows>, 11)` and the 11 names of `FEATURE_ORDER`. Train/serve skew begins the day
    there are two feature builders; this proves there is one, and that the file on disk
    satisfies it. If it raises, the dataset is unusable regardless of how good the figure looks.
67. Confirm the generator is offline by construction:
    `findstr /n "supabase psycopg asyncpg requests httpx app.routers" training\generate_bookings.py`
    → no hits. A training script that can reach the database is a training script that can
    train on production data by accident.
68. **Open `reports\demand_patterns.png` and actually look at it.** This is a *human* gate,
    not an assertion — `reports/README.md` lists the one claim each panel exposes. The
    twelve checks prove the dataset is internally consistent; none of them can prove it is
    plausible. You have booked a turf in this country, so you are the instrument here.

    *If the figure predates the plot fixes, re-render first:* `python training\demand_plots.py`.
    That reads the existing `data\bookings_synth.csv` and `data\bookings_meta.json` — it does
    **not** re-simulate, so `csv_sha256` is unchanged and the run above stays valid.

    Look for: football peaking at **20:00–21:00** (observed 20:00 · 64%); cricket **bimodal**
    with a dawn peak (07:00 · 45%); Ramadan **inverting** the night — dead afternoon, alive
    after Taraweeh (flat near 0% by day, **71% at 22:00**); Friday **daytime** notched at
    Jummah while Friday **night** is the week's biggest; **Sat ahead of both Sun and Fri**
    (39% / 35.5% / 34% — note Sunday outranks Friday, because the Jummah dip costs Friday
    more than its night bonus returns); **two** seasonal peaks, spring + autumn, read off the
    month panel's **Ramadan-excluded** line, not the raw one (the raw line puts March at the
    annual low, which is Ramadan 1447 sitting inside it, not a seasonal fact); and both price
    lines falling with off-peak falling **faster** (100→38 vs 100→79).
69. If a curve looks wrong, that is a real finding — and the fix is the labelled constant
    block in `training/generate_bookings.py`, never the plot. Every multiplier sits beside
    a comment stating why it has that value. Change the constant, rerun, and the sha256
    changes. That is the point: this dataset is a **stated set of assumptions**, not a
    measurement, and it should be easy to argue with.
70. Open the Flutter app and confirm **nothing changed** — again. Wave B is invisible to the
    product. No new screen, no price suggestion, no chart.

**What these tests cannot tell you.** Twelve passing checks and a plausible figure still
describe *simulated* demand. Every number a Wave C model produces inherits the assumptions
in §"Every distribution" of `data/README.md`. The first real bookings that land in
`bookings` are worth more than the entire synthetic corpus, and the retraining trigger in
the model card exists for exactly that moment.

---

### 4.7 Pricing model #1 — training, gates and the artifact (S.3 Wave C)

Wave C ships **no endpoint and no screen either.** It ships a trained model, the script
that trains it, and the evidence that the model is worth serving. Wiring inference into
`/predict/price` is Wave D, so the correct outcome of this section is a valid artifact on
disk and *no visible product change*.

**Recorded green baseline** (compare a future run against this, and treat a large move in
either direction as something to explain): `pricing-v1-20260825-0041`, **ALL 12 GATES
PASSED**, ROC-AUC **0.7628** against the measured ceiling **0.7770** = **98.2% of
attainable**, Brier **0.1680**, Brier skill **0.1668**; skew gate `7 columns agree on all
81,395 rows (worst deviation 4.92e-06)`; monotone gate `24 profiles; worst step +0.0000,
smallest fall 0.1791`; `suggested ratios 0.75x .. 1.30x, 7/24 hit the 1.3x policy cap`.
A markedly *higher* AUC is not good news — read tests 77 and 79 before celebrating it.

```bash
cd D:\sportlynk\ml-service
.\.venv\Scripts\Activate.ps1
```

71. **Do NOT run `generate_bookings.py` first.** The dataset is already validated and
    `train_pricing.py` re-checks its sha256 against `data\bookings_meta.json` as a release
    gate. Regenerating it writes a new hash, which fails that gate on every subsequent
    training run until the recorded hash is reconciled. If you genuinely need a
    reproducibility check, send it somewhere harmless:
    `python training\generate_bookings.py --seed 7 --out data\_seed7_check.csv`.
72. **Dry run first:** `python training\train_pricing.py --no-write --no-plot`
    → fits everything, prints the metrics and the full gate table, writes **nothing**. This
    is the cheap way to find out whether a gate fails before any artifact is touched.
73. `python training\train_pricing.py` → a few minutes (14 fits: a logistic baseline, 12
    validation fits across the capacity grid, and the final refit). It must end with
    **`ALL <n> GATES PASSED`** and exit code 0. Check it:
    `echo $LASTEXITCODE` → `0`.
74. Read the gate table, not the metrics. It is the last thing on screen for a reason — a
    `FAIL` on any line means `models\pricing_latest.joblib` was **not** written or replaced,
    and the exit code is 1. The reports and a timestamped `models\pricing_<stamp>.joblib` are
    still written on failure, deliberately: a failed run should be loadable and auditable,
    not invisible. Never copy a timestamped joblib over `pricing_latest.joblib` by hand —
    that is the one action the whole gate system exists to prevent.
75. Read **`price response is negative`** — the logistic baseline's `price_ratio`
    coefficient. **This is the most important line in the run**, and it is the counterpart to
    test 64 on the generator side. It must be negative. A gradient-boosted tree will happily
    fit an inverted price response and report a fine Brier score while doing it; a linear
    coefficient is a signed, readable number that cannot hide. If it comes out positive, the
    dataset is wrong and every price this project ever suggests is built on sand.
76. Read **`monotone price response`** — 24 slot profiles, six venues × four scenarios. It
    checks both that no 5% step raises P(book) and that the end-to-end fall clears a floor,
    because a perfectly flat curve is technically monotone and is really a model that
    ignored the price feature.
    **Check the profile count on the `sweeping ... representative slot profiles` line
    above it — it must say `24` and `6 venues x 4 scenarios`.** Run #1 said 16, because the
    venue picker deduped without backfilling and its targeted picks overlapped, so the gate
    silently ran on four venues while three documents claimed six. If a `NOTE: expected 24
    profiles, got N` line appears, coverage fell short again and the gate is weaker than it
    reads — that NOTE exists so the failure can never be silent twice.
    This gate is also now the **regression test for `monotonic_cst`**. It caught P(book)
    *rising* +0.0622 on a peak profile in run #1, which is why the classifier is fitted with
    `monotonic_cst={'price_ratio': -1}`. If it ever fails on the rise branch again, the
    constraint has been removed or bypassed — do not widen the tolerance to make it pass.
    A **`flat response`** failure is the opposite finding and is worth reporting rather than
    patching: a monotone constraint *permits* a flat curve, so it would mean the constrained
    model stopped using price at all.
77. Read the **ROC-AUC vs the ceiling** line. `train_pricing.py` scores `latent_p` itself
    against the realised labels to measure the best result *any* model could achieve on the
    test rows, then reports the model as a percentage of that. Two things follow, and both
    matter for the viva:
    - A headline ROC-AUC in the **0.7s is the correct outcome here**, not a disappointment,
      if it sits close to the ceiling. Ramadan, holidays, `ground_type`, payday and a
      per-venue random effect all move demand and are all deliberately *not* features — that
      residual is irreducible by construction. See `reports/README.md`.
    - **A near-1.0 AUC is a bug report.** There is a gate for it in both directions.
78. Read **`diagnostics match the contract`** — Wave B's mirror check re-run at train time
    on **100% of rows**, the strongest single guard against train/serve skew. It proves the
    `hour` the simulator applied its multiplier to is the `hour` the serving path extracts.
    It must PASS, and the line now ends with `(worst deviation N.NNe-NN)`.
    **The magnitude of that number is the whole diagnostic**, so read it, don't just read
    PASS/FAIL. Around `1e-6` or smaller is expected and harmless: the generator writes the
    CSV with `float_format="%.6g"`, so its *diagnostic* `price_ratio` column keeps six
    significant figures while the contract recomputes the ratio from the two **integer**
    price columns at full precision. Run #1 failed here on 34,281 rows against an
    `atol=1e-9`, which looked like catastrophic skew and was really a lossy serialiser
    versus an exact-equality comparison — the model trains on the full-precision value and
    Wave D serves that same division. A worst deviation near **1.0** is the opposite story
    and is a genuine bug (a flipped `is_peak` boundary, an off-by-one `hour`, a `lead_days`
    sign error): real errors differ by a whole unit, six orders of magnitude above the
    `2e-6` tolerance. Only `price_ratio` gets that tolerance; the six integer mirrors are
    still compared with **exact** equality.
79. Confirm `latent_p` never became a feature — the gate is called `no leaky column is a
    feature`, and independently:
    `findstr /n "drop( latent_p booked_gross cancelled" training\train_pricing.py`
    → hits only in comments, the `LEAKY_COLUMNS` constant, and the evaluation-only ceiling
    code. There must be **no `df.drop`** anywhere. `build_matrix` hands
    `features.build_frame` only the nine feature-source columns, so a leak is structurally
    impossible rather than merely absent.
80. Verify the artifact satisfies the registry contract *without* starting the service:
    ```bash
    python -c "import sys, joblib; sys.path.insert(0,'.'); from app.core import features, registry; p=joblib.load('models/pricing_latest.joblib'); print(p['modelVersion'], p['featureSpecVersion']==features.FEATURE_SPEC_VERSION, tuple(p['featureOrder'])==features.FEATURE_ORDER, hasattr(p['model'],'predict_proba'))"
    ```
    → a version string and **three `True`s**. Those are exactly the checks
    `app/core/registry.py::_load` runs; if any is `False` the service reports
    `incompatible` and keeps serving the heuristic instead of a mismatched model. Nothing
    raises either way — that is the design.
81. Open the three figures in `reports\` and look at them:
    - `calibration_pricing.png` — the reliability line should track the diagonal. Middle
      panel: the two outcome histograms must **separate**; a well-calibrated model whose
      predictions all huddle at the base rate would look fine on the left panel and be
      useless for pricing. Right panel is the one no real project can draw — predicted
      versus the *true* probability.
    - `price_response_pricing.png` — both curves fall, and the revenue peak is circled. Two
      panels sharing one x-axis, never a second y-axis (a probability and a rupee amount on
      twin axes lets the crossing point be moved by choosing the scales).
    - `importance_pricing.png` — `price_ratio`, `is_peak`/`hour` and `base_price` should
      lead. A near-zero bar is a feature the model chose not to use, not a bug.
82. Read `reports\model_card_pricing.md` end to end once. It is script-written, so it cannot
    drift from the artifact, and it is the document an external examiner will actually read.
    Confirm the limitations section still says **"trained on simulated data; it retrains on
    live data"** and that the retraining trigger names *price variation* as the binding
    constraint — not row count. More rows at one price per venue create no elasticity signal
    no matter how many there are.
83. **Now the behaviour change to expect.** With `pricing_latest.joblib` in place, restart
    `uvicorn` and call the endpoints:
    ```bash
    node src/scripts/check_ml_service.js     # from D:\sportlynk\backend
    ```
    `/predict/price` and `/predict/demand` now return **`501 not_implemented`** where they
    previously returned `503 model_not_loaded`. **That is correct and expected.** The
    registry can now load a valid artifact, so the routers get past `_require_model()` and
    reach the not-yet-written inference branch. Wave D removes it. `check_ml_service.js`
    treats a model suggestion and an honest fallback as equal passes, so it should still
    report `0 FAILED` — and the backend still serves prices from the heuristic, which is why
    the Flutter app is unchanged.
84. Open the Flutter app and confirm **nothing changed** — a third time. No price
    suggestion, no chart, no new screen. If something did change, something is wired ahead
    of its wave.

**What these tests cannot tell you.** Every gate can pass on a model that will be wrong
about the real market, because the gates check *internal validity* — no leakage, honest
calibration, a sane price response — and nothing can check external validity against a
market with 22 bookings and one price per venue in it. Read the metrics as evidence that
the **pipeline** is correct, and the model card's limitations as the honest statement of
what the numbers do not cover.

---

## 5. Non-functional tests

- **Responsiveness:** run on a small phone (~5") and a tablet. Nothing clipped, no
  horizontal scroll, no overflowing rank badges. Rotate to landscape.
- **Slow network:** enable throttling. Spinners must resolve, and a timeout must produce
  a **retryable** error, never a permanent blank screen.
- **Offline:** kill wifi mid-action. The app must say so and let you retry. On reconnect,
  sockets must resume without an app restart.
- **Empty states:** every list needs a real empty state — no teams, no matches, no
  bookings, no ranked teams.
- **Back-button / navigation:** no screen you can get stuck on. Leaving a team must not
  strand you on a dead profile.
- **Large text / accessibility:** bump system font size to max; check nothing truncates
  into meaninglessness.
- **Cold start:** measure time to first meaningful screen. Note it; regressions here are
  usually a sync call added to `main()`.

---

## 6. Security & vulnerability tests

This is the section that separates a demo from a project. Run each of these and record
the outcome — a committee asking "did you test for X" wants a specific answer.

Set up once:
```bash
BASE=http://<your-host>:<port>/api
TOKEN_A=<Bilal's JWT>     # captain of Falcons
TOKEN_B=<Hina's JWT>      # captain of Titans
```

### 6.1 Broken authentication
- Call any protected endpoint with **no** `Authorization` header → 401.
- Tamper with one character of a valid JWT → 401, not a 500.
- Change the JWT payload's user id and re-sign with a wrong secret → 401.
- Use an expired token → 401.

### 6.2 IDOR / horizontal privilege escalation — the highest-value test
The rule this project enforces: **authority is never read from the request body.** It is
derived from the JWT user plus the membership row, re-read inside a locked transaction.

- With `TOKEN_B`, try to `PATCH` **Falcons** (Hina is not its captain) → 403.
- With `TOKEN_B`, try to remove a **Falcons** member → 403.
- Submit a match result for a team you are not a captain of → 403.
- As a player, verify a match (owner-only action) → 403.
- As an owner, verify a match at a venue **you do not own** → 403. Ownership is checked
  in SQL (`v.owner_id = $1`), so a forged body field must not help.
- Read another user's wallet or booking by id → 403/404, never their data.

### 6.3 Mass assignment
Send extra fields the endpoint never promised and confirm they are ignored:
```bash
curl -X PATCH "$BASE/teams/<id>" -H "Authorization: Bearer $TOKEN_A" \
  -H 'Content-Type: application/json' \
  -d '{"bio":"hi","elo":9999,"wins":500,"visibility":"public","captain_id":"<someone-else>"}'
```
Expected: `bio`/`visibility` change; **`elo`, `wins`, `captain_id` do not.** Then confirm
in the DB. Silent acceptance of `elo` would let anyone top the leaderboard.

### 6.4 Injection
- Team name / bio / city / chat message: `'; DROP TABLE teams;--` → stored as literal
  text, no error. All queries are parameterised, so this should be boring.
- `?sport=` with a bogus value → clean 400, **not** a Postgres enum error (`22P02`) and
  never a leaked stack trace. `sport` is a DB enum, so unvalidated input would surface
  as a 500 — that is why it is validated before it reaches SQL.
- `?city=` with a 10,000-character value → rejected, not a slow scan.
- `?limit=99999999` and `?limit=-1` → clamped, not honoured.

### 6.5 Stored XSS / text hygiene
- Team name: `<script>alert(1)</script>` → rendered as literal text everywhere it appears
  (roster, leaderboard, chat header, notifications).
- Insert zero-width and right-to-left override characters in a team name → stripped.
  These are the characters used to spoof names that *look* identical to another team's.

### 6.6 Media & upload abuse
- `PATCH` a team logo with `{"logo":"http://evil.com/x.png"}` → rejected. Media is pinned
  to `res.cloudinary.com` over **https only**.
- Try a `javascript:` or `data:` URL → rejected.
- Try a >500-character URL → rejected.

### 6.7 Rate limiting & brute force
- 20 rapid failed logins → limiter engages, and the response does **not** reveal whether
  the email exists.
- Hammer invite-generation and message-send → limiter engages, server stays responsive.

### 6.8 Invite token abuse
- Use the same invite link **twice** → the second attempt fails (single-use, enforced
  under a row lock).
- Use an invite **49 hours** after creation → fails.
- Guess a random invite token → fails. Tokens are stored **hashed** (sha256); the raw
  value is returned exactly once, so a database leak does not hand over working invites.

### 6.9 Race conditions & money integrity
Run these with two phones tapping simultaneously, or two `curl` calls in parallel:
- Two players book the same slot → exactly one confirmed booking.
- Two withdrawal requests draining the same balance → total withdrawn never exceeds the
  balance. Money paths use `FOR UPDATE` row locks inside a transaction.
- Both captains submit results at the same instant → one match row, one result per team.
- Owner verifies the same match twice → ELO applies **once** (`elo_applied` guard).

### 6.10 Error hygiene
Trigger deliberate failures (bad UUID, missing body, nonexistent id) and confirm every
response is `{success:false, message:"..."}` with **no SQL fragment, no stack trace, no
file path**. Leaked internals are how an attacker maps your schema.

### 6.11 ML service trust boundary (S.3 onward)
`ml-service` holds no user data and does no authorisation — it trusts whatever the backend
sends it. That makes the key gate and the bind address the *entire* boundary, so both get
tested rather than assumed.

- **No key / wrong key → identical 401.** Two different messages would confirm to an
  attacker that their key *shape* was accepted, which is a free bit of information.
  Comparison uses `hmac.compare_digest`, not `==`, so response time does not leak how many
  leading characters were right.
- **Service refuses to start with `ML_API_KEY` unset** (exit 78). An ML service that boots
  open because someone forgot a variable is worse than one that does not boot.
- **Bound to `127.0.0.1`.** From a second machine on the same wifi,
  `curl http://<your-lan-ip>:8000/health` must **fail to connect**. If it answers, the bind
  address was widened to `0.0.0.0` and an unauthenticated `/health` is now on the network.
- **The key never appears in a log, a response, or an error.** `check_ml_service.js` and
  `/health` compare a **sha256 fingerprint** instead, which is how you diagnose a
  key mismatch between the two `.env` files without ever printing either secret.
- **The backend never forwards a client-supplied key.** `ML_API_KEY` is read from the
  environment only; nothing on `/api/*` can influence which key is sent, so a user cannot
  make the backend authenticate as something else.
- **A hostile ML response cannot reach an owner unchecked.** Point `ML_SERVICE_URL` at a
  stub returning `{"suggestedPrice": 190000}` → the dashboard must show a price inside
  `[base×0.70, base×1.50]` with `clamped:true`. The guardrail in `mlClient.js` is what
  stops a bad model — or a compromised service — from quoting a real owner PKR 190,000.

---

## 7. Data-integrity checks (run in the Supabase SQL editor)

Features can look right while the data rots underneath. These queries should each return
**zero rows**. Run them after a heavy manual session.

```sql
-- 1. No team's W/L/D disagrees with its verified match count.
SELECT t.id, t.name, t.wins + t.losses + t.draws AS wld,
       (SELECT count(*) FROM matches m
         WHERE m.status = 'completed'
           AND (m.challenger_team = t.id OR m.opponent_team = t.id)) AS completed
  FROM teams t
 WHERE t.wins + t.losses + t.draws <>
       (SELECT count(*) FROM matches m
         WHERE m.status = 'completed'
           AND (m.challenger_team = t.id OR m.opponent_team = t.id));

-- 2. Every completed+rated match wrote exactly two elo_history rows.
SELECT m.id, count(eh.id) AS rows
  FROM matches m LEFT JOIN elo_history eh ON eh.match_id = m.id
 WHERE m.status = 'completed' AND m.elo_applied = true
 GROUP BY m.id HAVING count(eh.id) <> 2;

-- 3. ELO history is internally consistent (before + delta = after).
SELECT id, team_id, elo_before, elo_delta, elo_after
  FROM elo_history
 WHERE round(elo_before + elo_delta) <> round(elo_after);

-- 4. No disputed match ever moved a rating.
SELECT m.id FROM matches m
  JOIN elo_history eh ON eh.match_id = m.id
 WHERE m.status = 'disputed' AND eh.elo_delta <> 0;

-- 5. Nobody has a negative balance or negative frozen amount.
SELECT * FROM wallets WHERE balance < 0 OR frozen_balance < 0;

-- 6. No two live bookings on the same slot.
SELECT slot_id, count(*) FROM bookings
 WHERE status IN ('pending','confirmed')
 GROUP BY slot_id HAVING count(*) > 1;
```

Also run `node src/scripts/reconcile_wallets.js` — it proves wallet balances match the
transaction ledger. Money that does not reconcile is the single worst class of bug here.

---

## 8. Working like a professional

The part that carries into every future wave.

### 8.1 Definition of Done
A wave is not done when the code exists. It is done when:
1. `flutter analyze` = 0 **and** `npm test`, `verify_schema`, `run_match_flow_check` all green.
2. The manual tests for that wave's features pass on two devices.
3. The relevant §6 security tests for anything new pass.
4. `PROGRESS.md`, `API.md` and `claude.md` reflect what actually shipped.
5. It is committed with the green numbers in the message.

If one item is missing, say so explicitly rather than rounding up to "done". A wave
reported as complete that is not complete costs more than a wave reported as 90%.

### 8.2 Log every bug, even the ones you fix immediately
Keep `doc/BUGS.md`. One entry per bug:

```markdown
### BUG-014 · Leaderboard shows 1000 for unranked teams
- Severity:  S2 (wrong data shown to user)
- Found in:  Wave D manual test, step 41
- Repro:     Create a team, play 0 matches, open leaderboard
- Expected:  "Unranked"   Actual: "1000"
- Cause:     Screen read team.elo directly instead of the rating widget
- Fix:       RatingText is now the only widget allowed to print a rating
- Verified:  flutter analyze 0 + re-ran step 41
```

Severity scale: **S1** money/security/data loss · **S2** wrong data or broken core flow ·
**S3** cosmetic or edge case. Fix S1 before writing anything new. This log is also the
single most convincing artefact in a viva — it shows you tested rather than hoped.

### 8.3 Regression discipline
The rule: **a bug you fix gets a permanent test.** ELO bug → a case in `npm test`.
Flow bug → a check in `run_match_flow_check.js` (that is why it is 69 checks and not 5).
UI bug → a numbered step in §3/§4 of this file. Otherwise the same bug returns in wave 7
and you will not know when it came back.

### 8.4 Git hygiene
- One wave per branch, one logical change per commit. Never mix a refactor with a feature —
  when something breaks you must be able to tell which half did it.
- Commit message: what changed, why, and the green numbers.
- Tag milestones (`s2-done`) so you can always get back to a known-good build.
- Never commit `.env`. When pasting logs anywhere, **mask `DATABASE_URL` and `JWT_SECRET`.**

### 8.5 Before you refactor for performance
1. Get a green baseline first. Without it you cannot tell a regression from a pre-existing bug.
2. **Measure, don't guess.** Slow-feeling UI is usually one bad query or one image, not
   "the code needs cleaning".
3. Change one thing, re-run the gates, commit. A 12-file refactor that fails one test
   gives you no information about which of the 12 caused it.
4. Refactors must be behaviour-preserving by construction — move code, don't rewrite it.

### 8.6 Demo day
Rehearse the happy path end-to-end at least twice on the real devices. Have the seeded
fixture ready, `BUGS.md` open, and the four green gate numbers on screen. Expect to be
asked "what happens if a user does X maliciously" — §6 is your prepared answer.

---

## 9. Quick regression checklist (copy per wave)

```
Wave: ____            Date: ____

[ ] flutter analyze .............. 0 issues
[ ] npm test ..................... 10/10
[ ] verify_schema.js ............. 113/113
[ ] run_match_flow_check.js ...... 69/69
[ ] server boots, 4 jobs registered
[ ] this wave's feature steps (§3/§4)
[ ] IDOR spot-check (§6.2)
[ ] mass-assignment spot-check (§6.3)
[ ] data-integrity queries (§7) all return 0 rows
[ ] docs updated
[ ] committed with green numbers
```
