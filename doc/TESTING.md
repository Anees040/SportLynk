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
| **Unit** — `npm test` (ELO, escrow, brackets, the tournament waterfall) | Wrong formulas, wrong rounding, bad edge cases | seconds | Every backend change |
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

npm test                                  # unit suites      → expect 128/128
node src/scripts/verify_schema.js         # schema drift      → expect 174/174 (113 before 019)
node run_match_flow_check.js              # match E2E         → expect 69/69
node src/scripts/check_ml_service.js      # ML integration    → expect 0 FAILED

node src/server.js                        # expect a clean boot + 6 jobs, then Ctrl-C
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
`npm test` failure means one of the pure-math layers changed — ELO, escrow rounding, the
fixture bracket or the tournament money waterfall; never "fix" the test to match the code
without deciding which one is actually right. A `verify_schema` failure means a
migration did not run on Supabase. A `run_match_flow_check` failure prints the failing
check number — that number tells you the exact step in the match lifecycle that broke.
A `check_ml_service` failure names the check; `skip` lines are not failures, they mean
the ML service was not running, which is a supported state.

**Record the numbers.** `128/128 · 174/174 · 69/69 · analyze 0` is your green baseline
(it was `10/10 · 113/113` when this section was written at S.2; the unit suites grew with
every wave, and `verify_schema` grew by 61 objects when S.7 Wave A added migration 019).
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

## 4. Feature tests — S2 · S3 · S4 (teams, chat, matchmaking, ELO, ML tier)

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
>
> **And once Wave D has been run, test 53's 501 becomes a 200** with a real price
> suggestion — that branch no longer exists. Test 54's 422 still stands: a malformed body
> is rejected by the schema before any model is consulted, which is exactly why it was
> written against the schema and not against the model. See §4.8.

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
`/predict/price` was Wave D's job, so the correct outcome of *this* section is a valid
artifact on disk and *no visible product change*. (Wave D has since landed — steps 83–84
carry superseded notes, and §4.8 is the section that expects the app to change.)

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
    > **Superseded by §4.8 (Wave D has landed).** The 501 is gone: both endpoints now run
    > inference and answer 200 with a real suggestion. Run this step only when reproducing
    > Wave C's state from a checkout at that commit.
84. Open the Flutter app and confirm **nothing changed** — a third time. No price
    suggestion, no chart, no new screen. If something did change, something is wired ahead
    of its wave.
    > **Superseded by §4.8.** Wave D is the wave that changes the app. Expect a live price
    > card on the owner dashboard and a 72-hour chart on the venue screen.

**What these tests cannot tell you.** Every gate can pass on a model that will be wrong
about the real market, because the gates check *internal validity* — no leakage, honest
calibration, a sane price response — and nothing can check external validity against a
market with 22 bookings and one price per venue in it. Read the metrics as evidence that
the **pipeline** is correct, and the model card's limitations as the honest statement of
what the numbers do not cover.

---

### 4.8 Pricing served + on screen (S.3 Wave D)

Wave D is the wave where the model stops being a file and starts being something an owner
reads and acts on. So the tests below are less about "does it return 200" and more about
**can any number on that card be wrong without anyone noticing.** The whole design premise
is that every figure is measured rather than asserted — confidence, the "why" chips, the
caption's AUC, the bar colours — and each test below picks at one of those claims.

**Endpoint naming, recorded once so it is not a surprise later.** The wave brief writes the
FastAPI routes as `POST /pricing/suggest` and `POST /pricing/forecast`. They ship as
**`POST /predict/price`** and **`POST /predict/demand`** — the names frozen in the Wave A
contract that `mlClient.js` and `check_ml_service.js` were both built against. Renaming
them would break a working client and a working harness for zero behavioural gain.

```bash
cd D:\sportlynk\ml-service ; .\run_dev.ps1        # terminal 1
cd D:\sportlynk\backend    ; npm run dev          # terminal 2
```

85. **The harness first — it is the cheapest 60 seconds in this section.**
    `node src/scripts/check_ml_service.js` (from `D:\sportlynk\backend`).
    Expect **`60/60 checks passed`** with the service up (**71/71** if you run this today — S4-C
    added 11 sentiment checks; see step 115), and **`31/31 passed, 4 skipped`**
    with it down. Both are passes; the second is the more important one, because it is the
    state a real outage puts you in.
    The 501s from test 83 are now **200s** — the not-implemented branch is gone. Read the
    two summary lines it prints: `source='model' PKR 2600 (+30%)` and
    `forecast source='model' 72 points` with a `demand mix` that is **not** all one level.
86. **`GET /api/owner/venues/:id/pricing`** as a logged-in owner (Postman or the app).
    Confirm `source: "model"`, a `suggestedPrice` inside 0.70×–1.50× of your
    `price_per_hour`, a `confidence` strictly between 0.05 and 0.95, and a `topFactors`
    array. Then **call it twice** and check the second response has `cached: true` and
    comes back instantly — the suggestion is cached for one hour, keyed on venue + date +
    hour + the current PKT hour.
87. **The ownership check is the one that matters.** Call the same endpoint with
    *another owner's* venue id → **404 "Venue not found or unauthorized"**, never 403 and
    never a suggestion. A wrong id and someone else's id must be indistinguishable in the
    response; ownership is in the SQL `WHERE`, not an `if` after the read. Same for
    `/forecast` and the `PATCH .../slots/price`. (This is §6.2 applied to Wave D — do it
    here rather than trusting that it was done there.)
88. **Stop uvicorn and reload the dashboard.** The card must still appear, with a
    **`RULE-BASED`** badge instead of `AI MODEL`, **no confidence bar**, a single chip
    carrying **no number**, no caption — and **no Apply button**. That last one is the
    point: a rule of thumb is shown for information, and the app will not write it to a
    slot. Restart uvicorn, pull to refresh, and the model card must come back within one
    request — a degraded answer is served but never cached, so the recovery is immediate
    rather than up to an hour later.
89. **Read the "why" chips against the slot you asked about.** A Saturday 20:00 football
    slot should chip `Peak hour` and `Weekend`; a Sunday 07:00 cricket slot should chip
    `Off-peak hour` and `Weekend` — the model surfacing the cricket dawn peak through a
    counterfactual rather than a rule. A neutral Wednesday 15:00 slot should show **no
    chips at all**, and that is correct: nothing about it deviates from neutral.
    There is deliberately **no rating chip and no sport/city chip**. Written, measured,
    removed: on a 4.5-star venue the rating counterfactual reported P(book) *falling*
    0.052, opposite in sign to the generator's causal effect (+0.01) and five times its
    size, because with six venue profiles in training `venue_rating` is very nearly a
    venue ID. The reasoning is in the comment block in `app/routers/pricing.py` — read it
    before anyone asks why reputation is missing from the explanation.
90. **The caption under the card.** It must read the served artifact's own scores —
    `Model pricing-v1-… · AUC 0.76 · 98% of ceiling`. The brief suggested a hardcoded
    `AUC 0.84`; this model scores **0.7628**. If the caption ever shows a number that is
    not in `reports\pricing_metrics.json`, that is the single most quotable defect in the
    project, so check it against the file once with your own eyes.
91. **Apply — FR4.17, the owner keeps control.** Tap **Apply to slots…**. The sheet opens
    on the date the suggestion was computed for, with that hour pre-selected and nothing
    else. Confirm booked, held and past slots are **shown, greyed, with the reason** and
    cannot be selected. Select two available slots → Apply → the snackbar reports the
    server's own count, and the slot prices in the Schedule tab change to match.
92. **Now the partial case, which is the one that breaks in production.** Select a mix
    including a slot you have already applied this price to, and one that a second device
    booked while the sheet was open. Expect `applied to N of M` plus a skip reason
    (`already at this price`, `already booked`). Nothing may be silently dropped, and the
    booked slot's price **must not move** — a booked price is what a player already agreed
    to pay.
93. **Verify the cache is actually invalidated by an Apply.** After a successful apply,
    the next `/pricing` call for that venue must be recomputed (`cached: false`) — the
    suggestion was computed against the old price, so serving the cached one would show a
    delta against a price that no longer exists.
94. **The forecast chart** (venue management screen, under the price field). 72 bars, three
    day labels, y-axis fixed at 0–100%. Tap a bar: the tooltip must name the PKT hour and
    the demand word. Check the axis is **not** scaled to the series maximum — a quiet week
    must *look* quiet. Confirm the legend's thresholds match the dashed gridlines; both
    come from the `levels` block the server sends beside the series, so they cannot
    disagree.
95. **Ask the chart to be wrong.** Point the app at a venue with no `price_per_hour` (or
    stop uvicorn) → the section must say **"Forecast unavailable"** with the server's own
    sentence and a retry, and draw **nothing**. A row of zero-height bars would read as
    "we predict no demand", which is a claim the model never made.
96. **Timezone sanity, the mistake that hides until deploy.** Every timestamp on the wire
    ends in `+05:00`, and the cache key contains the PKT hour. Set your *device* to UTC and
    reload: the day labels (`Today`, `Tomorrow`) must not shift, because they are relative
    to the first day in the series, not the device clock. On the server side the day comes
    from `(NOW() AT TIME ZONE 'Asia/Karachi')`, not from container-local time — a Node
    container in UTC would otherwise roll over at 05:00 PKT and serve yesterday's
    lead-day arithmetic all morning.

**What this section cannot tell you.** That the suggested prices are *right*. The model is
trained on simulated demand, so these tests prove the pipeline is honest end to end —
calibrated probabilities, attributable explanations, an owner who must consent — and prove
nothing at all about what a Lahore futsal court should charge on a Saturday. That answer
only exists after real bookings at more than one price per venue, which is the retraining
trigger the model card names.

---

### 4.9 The retrain demo and the price-sanity probe (S.3 Wave E)

Wave E's headline is a claim a supervisor will make you demonstrate: **"the model is
reproducible"**. Tests 97–100 check that claim in the order a demo would, and
97–99 are runnable before any UI is open.

```bash
cd D:\sportlynk\ml-service ; .\.venv\Scripts\python.exe training\train_pricing.py --seed 42
```

97. **Reproducibility, the demo itself.** The command above exits 0 in **≈68 s**, prints
    the three-column metrics table (logistic baseline · this model · Bayes-optimal
    ceiling), then the 12 gate rows, then writes the artifact. Run it twice into
    `.rehearsal\` (`--models-dir` / `--reports-dir`) and diff the two
    `pricing_metrics.json` files — **they must be byte-identical**: nine metrics to six
    decimals, same winning hyperparameters, same `csvSha256`, same gate verdicts. A
    single differing byte breaks the "seed 42 reproduces the artifact" claim, which is
    the whole point of the command you just demoed. (For the live demo itself, train
    straight into `reports\` — the artifact is written only if every gate passes, so a
    failing run cannot take the served model down with it.)
98. **The metrics table is not decoration.** `--quiet` must still print it (it uses the
    same channel as the gate verdicts, which are how you know the run succeeded). The
    logistic-baseline column exists so the boosted model has to earn its complexity;
    the ceiling column converts "is 0.76 good?" into "is 0.76 near the best any model
    could score on these rows?" — the answer, 98.2%, is the sentence to say out loud.
99. **A retrain does not hot-swap the served model.** After the live retrain, before
    restarting uvicorn, `/health` still reports the **previous** `model_version`.
    Restart, and it moves. The printed success message now says exactly this —
    read that message during the demo, it is on-message.
100. **The price-sanity probe — `node src/scripts/check_price_sanity.js`** (from
     `D:\sportlynk\backend`, both servers running). It is the acceptance checklist
     turned into an executable: **20 required checks** — Friday 20:00 beats Tuesday
     03:00 in price *and* in P(book), the rating signal never *inverts* (weak form: on
     these synthetic six profiles a strict `hi > lo` would fail wherever the +30% cap
     pins both venues to the same rupee, and gating on that would make a correct system
     look broken — read the comment block before judging the gate), the demand curve
     measured **from the forecast** (not from `suggestPrice`, whose `demand` is P(book)
     at the *suggested* price and differs every hour), the price ladder inside
     0.75×–1.30×, whole rupees, 72 contiguous `+05:00` points, not one flat level.
     Exit code 0 and a line like `ALL 20 REQUIRED CHECKS PASSED — pricing-v1-…`.
     It writes `ml-service\reports\price_sanity.json` — an evidence artifact, committed.
     `source: "heuristic"` anywhere in it is a **hard failure**: a green tick earned by
     the fallback is worse than a red one.
101. The observations in that file are deliberately **not** verdicts — read them, and
     repeat them in your own words before the committee does. The biggest: **"low-rated
     venue < high-rated" is only partially true**, because the guardrail cap binds
     before the rating signal at peak. At 03:00 the model *does* price the 2.0★ venue
     below the 4.8★ (PKR 1600 vs 1500); at Friday 20:00 both are pinned at +30% and
     equal. The rating effect is real at peak (P(book) 0.6384 vs 0.5963 on identical
     slots) but the +30% cap binds first. Saying "the gradient is monotonic everywhere"
     is the one claim in the evidence pack that will not survive a push — the file
     writes down the honest version.

**What this section still cannot tell you.** Nothing here validates the *numbers*:
the probe checks the pipeline, not the economics. Same caveat as §4.8 — the
retraining trigger is real bookings.

---

### 4.10 Sentiment — the exam and the corpus (S.4 Wave A)

This wave shipped no model, so there is nothing to click. What there *is* to check is
whether the **measuring instrument** is still trustworthy — and every one of these is a
five-second command, because a corrupted exam is the single failure that would make every
number in §4.11 meaningless while everything still looked green.

```bash
cd D:\sportlynk\ml-service
.\.venv\Scripts\python.exe -c "import hashlib,pathlib; p=pathlib.Path('data/sentiment/domain_test_200.csv'); print(hashlib.sha256(p.read_bytes()).hexdigest())"
```

102. **The exam's sha256 must equal the one in `data/sentiment/domain_test_meta.json`**
     (`7e388c84…bd46`). If it differs, *stop* — someone edited the test set, and the only
     honest response is to find out which rows and why. `train_sentiment.py` checks this
     itself on every run and refuses to release on a mismatch, so the practical way to
     fail this test is to notice the trainer refusing.
103. **The exam is 200 rows, 68 negative / 67 neutral / 65 positive**, and **no row of it
     appears in `train.csv`**. The corpus builder enforces the second half (0 exact
     matches, 1 authored near-duplicate removed at Jaccard ≥ 0.8) and records the result
     in `train.meta.json` under `contamination_gate`. Read that block rather than trusting
     the sentence.
104. **The rule that is a discipline, not a check: never edit an exam row because the model
     got it wrong.** There is no test for this — it is the one thing in the whole ML tier
     that only integrity enforces. The moment a row is "fixed" to match a prediction, the
     0.8250 headline becomes a number about itself. If a row genuinely *is* mislabelled,
     fix it, re-hash, re-record, and say so in the wave log — the crime is the silent fix.
105. **The normalisation fingerprint must match in three places** — the corpus metadata,
     the served artifact, and `GET /sentiment/spec`: `sentiment-norm-v1` /
     `b96e65df85f9692b`. This is not ceremony. `app/core/text_norm.py` is pickled into the
     pipeline **by reference**, so editing `prep_word` changes how every already-released
     artifact normalises text at serve time — with no version mismatch, no exception and no
     failing test. The fingerprint is the only thing that turns that silent failure into a
     loud one, and a release gate compares it.
106. **Corpus provenance.** `train.csv` is 21,405 rows at sha256 `408b4c52…a068`, and the
     arithmetic in `train.meta.json` reconciles exactly: 21,957 loaded − 539 exact
     duplicates − 12 empty-after-normalisation − 1 exam near-duplicate. A gate re-checks
     the sha on every training run. `train.csv` is **gitignored** (13 MB of third-party
     licensed text); the metadata is committed, which is what lets a fresh clone *verify*
     a rebuilt corpus instead of trusting it.
107. **The shortcut test worth understanding.** If Roman Urdu rows were mostly negative and
     English rows mostly positive, a model could score well by detecting *language* and
     never learn sentiment at all. `train.meta.json` reports Cramér's V **0.1334**
     (source~label) and **0.1298** (lang~label) — weak association, which is the passing
     result. It reports χ² and effect size and deliberately **no p-value**: at n = 21,405
     significance is free, so only the effect size answers the question.

---

### 4.11 Sentiment model #2 — trained, gated, served (S.4 Wave B)

Tests 108–113 are runnable with no UI, because **no screen shows sentiment yet**. That is
the honest state of this wave and test 113 exists to keep it from being overstated.

```bash
cd D:\sportlynk\ml-service
.\.venv\Scripts\python.exe training\train_sentiment.py          # no flags — see below
.\.venv\Scripts\python.exe training\smoke_sentiment_api.py      # 49 checks, released artifact
```

108. **Retrain with no flags.** The defaults *are* the shipped configuration
     (`--branches both --C 0.1 --upweight-authored 40 --seed 42`), so the bare command is
     what produced the served artifact. It must print **7/7 gates ok** and release:
     contract self-check (12 receipts) · corpus provenance (sha + norm fingerprint) · exam
     provenance · `predict_proba` present · no leakage · beats baseline · domain ≥ 0.80.
     The artifact is written **only if every gate passes**, so a failing run cannot take
     the served model down. For a rehearsal, add `--no-write --no-plot`: the gates still
     run and the released artifact is never touched. That form also re-derives the
     published metrics **exactly** (0.8250 / 0.8247, per-language 0.7600 · 0.8286 · 0.8625,
     ablations 0.7800 · 0.7650 · 0.8100, CI [0.7700, 0.8750]) — the reproducibility demo
     for model #2, the same claim test 97 makes for pricing.
109. **The headline: exam accuracy ≥ 0.80.** Recorded run **0.8250**, macro-F1 0.8247,
     95% CI **[0.7700, 0.8750]** over 2,000 bootstrap resamples, against a majority
     baseline of 0.3400. Say the CI out loud: **its lower bound is below the target.** On
     200 rows "we cleared 0.80" is a point estimate, not a proven inequality, and a
     committee that spots you hiding that has found something worse than a low score.
110. **The validation split reads *lower*, and that is not a bug.** 0.6447 on 4,281
     held-out corpus rows against 0.8250 on the exam. They measure different
     distributions: the split is 97% third-party open-domain text (tweets, RUSA sentences)
     where 3-class sentiment is genuinely ambiguous and the labels are somebody else's; the
     exam is 200 venue reviews in the register this app receives. The model is
     **specialised**, both numbers are published, and quoting only one of them is the
     failure mode in either direction.
111. **The probabilities are not calibrated, and the artifact says so.**
     `predict_proba = softmax(decision_function)`, recorded as
     `{"method":"softmax_over_decision_function","calibrated":false}`. Two things follow.
     `argmax(proba) == predict` **exactly**, so `classScores` can never disagree with the
     label shipped beside it — `smoke_sentiment_api.py` asserts this on every probe. And
     0.9 means "well inside the margin", **not** "90% of such reviews are negative"; do
     not read these as frequencies in a demo.
112. **The abuse flag (FR9.10) reads its threshold from the artifact.** 32-term lexicon
     **or** P(negative) ≥ **0.70** → escalate; 18 of the 200 exam rows escalate; the smoke
     test prints `threshold came from the artifact -- 0.7`. **Never hardcode this number.**
     Softmax sharpness tracks margin width, which tracks `C`: moving C from 3.0 to 0.1
     moved max P(negative) on the exam from 0.9811 to 0.9234, which silently near-killed a
     hardcoded 0.90 threshold *while accuracy improved*. Nothing failed and nothing warned.
     If you ever re-tune C, the threshold must be re-measured — that is the whole reason it
     travels inside the artifact. `MIN_NEG_THRESHOLD = 0.50` in the router floors what any
     artifact is allowed to ask for.
113. **`/health` reports both models, and Node calls only one of them.** (Two models at S.4 time; four
     after S6-B — see step 171.) The health payload
     is a `models[]` array — `pricing` and `sentiment`, each with its own status and
     metrics, so one broken artifact degrades one entry instead of the whole report. Seven
     paths are served (`/predict/sentiment`, `/predict/sentiment/batch`, `/sentiment/spec`
     are the new three). **`reviews.sentiment_score` and `reviews.sentiment_label` exist in
     the schema and no Node route calls the model** — the only sentiment reference in
     `backend/src/` is a column check in `verify_schema.js`. Do not demo this as a
     closed loop; it is an endpoint with a passing smoke test, and the wiring is next.

**What this section cannot tell you.** Whether the model is right about a *real* review.
The exam is 200 rows written by one annotator — second-annotator κ is still open — and no
real user review has ever been scored. Every number above is a claim about 200 rows we
wrote ourselves, which is a much smaller claim than "the model understands reviews".

### 4.12 Reviews, trust & sentiment wiring (S.4 Wave C)

This is the wave that makes the platform *use* the sentiment model and the `reviews`
table for the first time, adds Trust Score 2.0, and warms the price model so the first
call stops timing out. It is **backend-only** — there is no review screen yet — so every
test here is HTTP or SQL. Prerequisites: the two-team fixture from `run_match_flow_check.js`
(§4.3), a **checked-in** booking for a player (take one through QR check-in, §4.8), and a
**completed** match between the two teams (challenge → both results → owner verify, §4.3).

```bash
cd D:\sportlynk\backend
node run_migration_017.js                 # test 114
node src/scripts/check_ml_service.js      # test 115 (ml-service must be running)
# then the review endpoints, against a running backend:
BASE=http://127.0.0.1:3000/api
```

114. **Migration 017 applies clean, is idempotent, and its constraints actually
     constrain.** First run creates `review_flags`, the four review indexes, the
     `chk_review_flags_status` CHECK, and flips `player_profiles.trust_score` DEFAULT from
     100 to 50. **Run it a second time — every line must be a no-op** (`IF NOT EXISTS`,
     guarded CHECK, idempotent `SET DEFAULT`) and the report stays green. The runner does
     more than a `\d` dump: it refuses to apply if two live reviews already share
     `(booking_id, reviewer_id, review_type)` (it prints the offending rows — deciding
     which review to keep is a human's call), then runs **functional probes** inside a
     rolled-back transaction — a second venue review by the same author on the same booking
     is rejected `23505`; an *opponent* review by that same author on that same booking is
     **allowed** (venue + opponent are two legitimate reviews); a double-flag is `23505`; a
     `status='pending'` flag is `23514`. A constraint that exists but does not constrain is
     worse than none, so the probes prove enforcement, not just presence.
115. **`check_ml_service.js` reaches 71/71 — and the price checks inside it are the cold-start fix.**
     Before this wave the first `/predict/price` paid ~1.9 s (load joblib → first
     `predict_proba` through an untouched sklearn Pipeline → first pandas frame) and tripped
     the client's 2 s ceiling, so the four model-served price asserts ran against a
     *heuristic* answer and the then-60-check run scored **56/60**. `main.py`'s lifespan now
     calls `pricing.warm()` and `sentiment.warm()` best-effort at boot — the ml-service log
     shows `warm-up: pricing warmed (…)` — so the first real call is already warm and the
     price section is deterministically model-served (`source='model'`, PKR 2600 at +30% on
     the peak-hour probe). Wiring Node to the sentiment model added 11 checks to the suite,
     so a green warm run is now **71/71** (was 60 checks pre-sentiment). The same run also proves the
     **sentiment up-path**: `/sentiment/spec` label set + `normSpecVersion` match Node's
     `SENTIMENT_LABELS`; `analyzeSentiment('great venue…')` returns `source:'model'`, a
     label in the set, `score ∈ [-1,1]`, `confidence ∈ [0,1]`, boolean `flagged`/`toxic`/
     `strongNegative`, a `modelVersion`, and is not flagged; and junk text comes back
     `available:false, clientError:true` **without** tripping the breaker (`breakerState().
     open === false`) — a 422 is bad input, not an outage. With the service **down**, the
     two sentiment up-path checks skip (like the price up-path already does) and the run
     still proves degradation.
116. **Venue review — the booker who attended.** `POST /reviews {booking_id, review_type:
     'venue', stars: 5, text: 'great pitch, well maintained'}` as the player who owns a
     **`checked_in`** booking → **201**. Confirm in the DB: one `reviews` row with
     `review_type='venue'`, `reviewed_user_id NULL`, and — because the text was supplied —
     `sentiment_label='positive'` with a `sentiment_score`. The venue's denormalised
     `venues.rating` / `total_reviews` must also refresh (those columns are already shown in
     listings; leaving them stale would make existing screens lie). A non-participant, or a
     booking that never reached `checked_in`, is refused — authority is the booking row, not
     the body.
117. **Opponent review is captain-to-captain, and the target is *derived*.** After a
     **completed** match, the caller must be a `role='captain'` member of one side; `POST
     /reviews {booking_id, review_type:'opponent', stars, text}` stores a row whose
     `reviewed_user_id` is the **opposing team's captain**, computed server-side
     (`representativeCaptain`) — there is no target field in the body to forge. Both
     captains reviewing each other → **two** rows, and **both** users' `trust_score`
     recompute synchronously inside the same transaction (ER2.5's 60 s rule). A non-captain
     member filing an opponent review → refused.
118. **One review per `(booking, author, type)`.** Re-`POST` test 116 verbatim → **409**
     (`ux_reviews_one_per_author`, mapped by `friendlyDbError`). This is a UNIQUE index, not
     a JS pre-check, because two fast taps on Submit both read "no review yet" and both
     insert. The *type* is in the key on purpose: the captain in test 117 may still leave a
     venue review on the same booking.
119. **Trust Score 2.0 — the composite, the cold start, and the no-show path.**
     `trust = round(35·rating + 30·attendance + 20·dispute_free + 15·sentiment)`, each
     component normalised to 0..1, each **absent** component contributing a neutral **0.5
     prior** to the aggregate (but stored `NULL` in its `trust_*` column, so a UI can say
     "no data yet"). A brand-new user therefore scores exactly **50**
     (`round(35·.5+30·.5+20·.5+15·.5)`), which is the migration's new DEFAULT and what
     `auth.js`/`users.js` insert. **The old flat `trust_score − 10` per no-show is gone:**
     force a no-show (§4.3, or the owner's manual button, or the sweep) and confirm the
     score is *recomputed* from the four signals, not decremented — and the player's
     notification now says "your trust score has been updated", not "−10" (which recompute
     would have made a lie). `GET /users/:id/reviews` returns the stored breakdown so you can
     read each component back.
120. **Flag a review → the moderation queue.** `POST /reviews/:id/flag {reason}` as any
     participant of that review's booking/match → **201**, inserts a `review_flags` row
     (`status='open'`) and sets `reviews.flagged=true`. The same user flagging the same
     review again → **409** (`UNIQUE(review_id, flagged_by)` — one report per user). The
     table is the ledger *behind* the fast `reviews.flagged` bit, mirroring `disputes`; the
     admin resolve UI is S.7.
121. **The read paths return aggregates, canonical labels only.** `GET /venues/:id/reviews`
     is paginated, `WHERE hidden=false`, and returns rows plus `avgStars` and a
     `sentimentDistribution {positive, neutral, negative}` (the three canonical labels — the
     `unscoreable` sentinel and NULLs never appear as a bucket). `GET /users/:id/reviews`
     returns the reviews a user has **received** (the trust ledger) plus their stored trust
     breakdown.
122. **The sentiment backfill job, and the promise that review text is never logged.** On
     boot the backend logs the backfill job's start line; every sweep it scores up to 200
     reviews whose `comment IS NOT NULL AND sentiment_label IS NULL` via
     `analyzeSentimentBatch`, and on a batch `422` falls back to per-row scoring so one bad
     row can't wedge the queue (a row that even single-scoring rejects gets a terminal
     `sentiment_label='unscoreable'` sentinel, excluded from reads and never re-selected).
     **Watch the logs while a review is scored: you must see the review's id, label, flags
     and text *length* — never the text itself.** Read it back at `ml-service`'s side too;
     the service enforces the same rule.

**What this section cannot tell you.** Whether a *human* agrees with a score or a flag.
There is still no review UI, so every test here is an API contract, not a user seeing the
result; the Flutter surface (a review sheet, the trust ledger screen, the moderation queue)
is a later wave. And the trust `dispute_free_rate` is an explicit **pre-S.7 proxy** — fault
in a dispute is not adjudicated until an admin resolves it, so today it only counts
"disputes the *other* side filed on a match your team played", never your own objections.

### 4.13 Review UI, Trust 2.0 screens & moderation (S.4 Wave D)

This is the wave that gives §4.12's backend a face, so — unlike every test above it — these
are **on-device** steps, run on the emulator against a live backend + ml-service, not curl.
S4-D added no schema and no new model; it wired five Flutter surfaces to the four Wave C
review endpoints plus two net-new admin endpoints. The point of this section is the
**acceptance checklist** the wave was signed off against, mapped to concrete taps.

**Verified before this section even starts** (done at wave end, not on-device): `flutter
analyze` → *No issues found!* across the whole app; ML acceptance re-confirmed read-only —
`reports/sentiment_metrics.json` shows `domain_test_200` **0.8250 ≥ 0.80**, with
`confusion_matrix_sentiment.png` and `model_card_sentiment.md` present and all 7 gates
`ok=true` (the model was **not** retrained). What is **not** yet verified, and is exactly
what this section exists to drive, is a human doing the loop end-to-end on two devices — the
code-execution classifier was down the wave it was built, so the boot/curl/seed steps
(123–124) and the two-device E2E (125–134) were deferred here rather than claimed green.

**Acceptance checklist → test.** ① live sentiment chip on submit → **125**; ② Roman-Urdu
positive scored positive → **126**; ③ abusive → flagged → admin queue → hide → gone + trust
recomputes → **127**; ④ two captains review each other, both trust gauges move within seconds,
M25 tiles match the stored components → **128**; ⑤ only participants may review, duplicates
blocked (409) → **133** (authority already proven server-side in 116–118); ⑥ ml-service down →
review still saves, no crash, backfill later → **132**; ⑦ venue detail histogram + sentiment
summary → **130**; ⑧ owner reads + flags → **131**; plus the "No data yet" NULL rule → **129**
and the read-only team view → **134**.

Prerequisites: the §4.3 two-team fixture, a **`checked_in`** booking (§4.8 QR), a **completed**
captained match, backend on `10.0.2.2:3000`, ml-service up. `seed_reviews_demo.js` (test 123)
provides all of this except the emulator itself.

```bash
cd D:\sportlynk\backend
node --check src/routes/admin.js && node --check seed_reviews_demo.js   # test 123 (static)
node seed_reviews_demo.js                 # test 123 (creates demo content; re-run = no-op)
node seed_reviews_demo.js --undo          # test 123 (reverses it, FK-safe)
npm start                                 # test 124 (boots clean WITH admin routes)
# with an admin token, against the running backend:
BASE=http://127.0.0.1:3000/api
curl -H "Authorization: Bearer $ADMIN" $BASE/admin/reviews/flagged            # test 124
curl -X PATCH -H "Authorization: Bearer $ADMIN" -H "Content-Type: application/json" \
     -d '{"action":"hide"}' $BASE/admin/reviews/<flagged_review_id>            # test 124
```

**Pre-typed demo reviews** (paste these verbatim so the demo is deterministic — the first two
must come back `positive`, the third must flag):

1. **Positive, English:** `Great pitch, floodlights were perfect and the turf was well maintained. Booking again next week.`
2. **Positive, Roman-Urdu:** `Boht acha ground tha, staff friendly the aur maintenance top class. Zaroor dobara aayenge.`
3. **Abusive → flags:** `Absolute garbage venue. The owner is a stupid scammer and an idiot, total trash, worst experience ever.`

123. **The demo seed is idempotent and reversible.** `node seed_reviews_demo.js` creates two
     captained teams (Demo United, Demo Rovers), five venue reviews spanning the sentiment
     labels **including one abusive that lands flagged**, opponent reviews on both captains, a
     no-show, and **one completed match left un-reviewed** for the live rating demo. It never
     creates users or venues — it needs ≥2 active players + 1 active venue already present.
     **Run it a second time — every line is a no-op** (teams matched by name, bookings by a
     `SEED_REVIEWS_DEMO/<tag>` note, reviews by `ON CONFLICT`; trust is recomputed through the
     real `recomputeTrust`, never hand-set). `--undo` reverses everything FK-safe. `node
     --check` on both `admin.js` and the seed script parses clean.
124. **Backend boots with the admin routes, and both moderation endpoints answer.** `npm
     start` logs clean (no route-collision or missing-handler warning). `GET
     /api/admin/reviews/flagged` with an **admin** token returns the queue — each row carries
     `reviewedUserName`, `venueName`, `openFlagCount`, `flags[]`, sorted `hidden ASC,
     created_at DESC`; a non-admin token → **403**. `PATCH /api/admin/reviews/:id
     {action:'hide'}` → **200**, and re-`GET` shows the row now `hidden:true`; an unknown
     `action` → **400**, a non-UUID id → **400/404**. This is the same contract the admin
     screen (127) drives — proving it by curl first isolates UI bugs from API bugs.
125. **THE demo moment — submit a venue review, the trained model's chip animates in.** As the
     player who owns the **checked-in** booking (seeded in 123), open the booking → **Rate
     Experience**, tap 5 stars on *Rate the Venue*, paste demo review **#1**, Submit. Within
     ~2 s a `SentimentChip` animates in reading **😊 Positive (…%)** — the score comes from
     the live classifier, not a heuristic. This is the wave's headline: a genuinely-trained
     model reacting to text a user just typed, on screen.
126. **Roman-Urdu is scored, not mangled.** Repeat 125 on a *different* booking with demo
     review **#2** (Roman-Urdu). The chip must read **positive** — the normalisation contract
     (`text_norm.py`) is inside the served pipeline, so transliterated Urdu is handled the same
     on-device as it was on the exam (per-language `ru`/`mixed` accuracy is the highest of the
     three, §4.11).
127. **Abusive → flagged chip → admin queue → Hide → gone + trust recomputes.** Submit demo
     review **#3**. The chip returns **amber "Flagged for review"** (lexicon hit OR P(negative)
     ≥ measured threshold). Switch to the **admin** account → dashboard shows a **flag badge**
     with the open count → **Moderation** screen lists that review with its reason and venue
     context → tap **Hide**: optimistic update + success snackbar, the row drops off the badge
     (still listed, sorted last, so it can be **Restored**), and it **disappears from the
     venue's public reviews** (reads are `WHERE hidden=false`). Confirm the reviewed user's /
     venue aggregate moved — hide calls `refreshVenueAggregate`/`recomputeTrust`, so hiding a
     1-star rant nudges the average back up. **Dismiss** on a different flagged row clears the
     flag without hiding.
128. **Two captains, two gauges, seconds apart.** From a completed match, captain A opens
     **Rate Experience** → *Rate Opponent Sportsmanship (Captain Only)* is visible (a
     non-captain never sees this section), rate + submit; captain B does the same. Open each
     captain's **Trust profile (M25)**: both `TrustGauge`s reflect the new review **within
     seconds** (recompute is synchronous inside the write txn), and the four `TrustMetricTile`s
     read back the **stored** `trust_*` components — the tiles must equal what `GET
     /users/:id/reviews` returns, not a client re-derivation.
129. **"No data yet" is never a zero.** Open the Trust profile of a **brand-new** user (no
     reviews, no matches): the gauge reads exactly **50** (migration 017 DEFAULT), and each
     `TrustMetricTile` whose component is `NULL` renders **"No data yet"** — never `0`, never a
     punishing empty bar. A component only shows a number once real signal exists. The
     "TEAM CAPTAIN" chip shows in the header only for a captain.
130. **Venue detail surfaces reviews without breaking the slot grid.** Open a seeded venue's
     detail: a **Reviews** summary sliver shows the average, a `StarsHistogram` (5→1), a
     `SentimentSummaryBar`, the top 3 `ReviewCard`s, and **View all** → the paginated
     `VenueReviewsScreen` (pull-to-refresh, `MatchEmptyState` when empty). Kill the reviews
     endpoint (or point at a venue with none): the sliver shows empty/'—' **but the bookable
     slot grid still loads** — the two load independently on purpose.
131. **Owner reads and flags, cannot moderate.** As the venue **owner**, open Manage venue →
     the AppBar **Reviews** action → `OwnerVenueReviewsScreen` lists that venue's reviews
     read-only with a **flag** affordance (owner reporting a review routes into the same
     `review_flags` queue an admin then works in 127). The owner has **no** hide/restore —
     moderation is admin-only.
132. **ml-service down → the review still saves, and the UI says so honestly.** **Stop
     ml-service**, then submit a venue review. It still returns **201** and the review appears;
     the chip reads a subtle **"Sentiment added shortly"** — *not* a fake score and *not* a
     crash. Nothing in the UI invents a label. Bring ml-service back: the next
     `sentimentBackfillJob` sweep fills `sentiment_label` and the chip is correct on reload.
     This is §4.12's degradation contract made visible on the phone.
133. **Duplicate review blocked, surfaced as a message not a crash.** Re-submit the same review
     (same booking + type) from the app → the server's **409** (`ux_reviews_one_per_author`)
     comes back as a clean `SnackbarUtil` error ("you've already reviewed…"), never an
     exception or a spinner that hangs. The *type* is in the key, so a captain who left an
     opponent review can still leave a venue review on the same booking.
134. **The team view is read-only, and reflects the reputation decision.** Where an opponent is
     shown (match card / rate flow), a `TeamReputationStrip` shows **ELO + W/L/D + the
     captain's trust band** — no stars to tap, no per-member trust. This is the
     captain-anchored model made visible: skill is the team's (ELO), conduct is the captain's
     (trust), and nobody rates five individuals. Built from data already on `MatchSide`; no
     endpoint added.

**What this section cannot tell you.** Whether the *label a human would give* matches the
model's — the on-device chip proves the model is wired and reacts live, not that it is right
about any particular real review (the exam is still 200 rows one person wrote, second-annotator
κ still open; §4.11). And because these steps are manual and were **not** run the wave they were
written (classifier down), a green result here is a claim about *this* run on *your* devices —
record the build + emulator + backend commit alongside it, the way the numbered green baseline
(`analyze 0 · npm test · verify_schema · run_match_flow_check · check_ml_service 71/71`) is
recorded for the automated suites.

### 4.14 Venue recommender — model #3 on Find Venues (S.5 Wave A)

135. **The rail is the model, and it says so.** Open **Find Venues** as a player with ≥1 past
     booking. The recommended rail loads from `GET /api/venues/recommended`; each card shows a
     **"N% match"** chip in the 55–98 band with a ✨ Sparkles icon and one or more **reason chips**
     ("You play futsal", "Top-rated nearby"). Confirm the number is *served*, not computed on the
     phone: it must equal `match_pct` from the endpoint, and there is **no** client-side re-sort —
     the order the server returns is the order shown. (The old "AI Recommended" client sort is gone.)
136. **Cold start is labelled honestly.** Open the rail as a **brand-new** player (no bookings): the
     header reads **"Popular nearby"**, not "For you"; the cards still rank sensibly
     (popularity-in-city + any stated sport); and because this is the model's own cold-start path
     (`source == 'model'`) the match chip and Sparkles still show. A warm user with history sees the
     header flip to **"For you"**.
137. **ml-service down → the rail degrades, it does not lie or blank.** **Stop ml-service** and
     reopen Find Venues. The rail still populates (Node's heuristic fallback: sport-preference +
     rating), but every card now shows **no match chip and no Sparkles** — the heuristic carries
     `match_pct:null`, so nothing invents a score. Bring ml-service back, pull-to-refresh: the chips
     return. This is the `source: model|heuristic|unavailable` contract made visible.
138. **The 15-minute cache serves the model, not the fallback.** Load the rail warm (`source=model`)
     — a second load inside 15 min is instant. Now stop ml-service and force a cache miss (a fresh
     user key, or wait out the TTL): the heuristic result comes back but is **not** cached
     (`shouldCache` only keeps `source=='model'`), so the first call after ml-service returns serves
     fresh model results rather than a stale heuristic.
139. **A recommendation only reflects new data after a snapshot.** Make a booking, reopen the rail —
     the order does **not** change (the served model is a point-in-time snapshot). Re-run `python
     training/build_reco.py` and restart ml-service; now the new booking shifts the profile. This is
     the documented snapshot-staleness limit, not a bug — verify the UI never claims freshness it
     doesn't have.

**What this section cannot tell you.** Whether the ranking is *good* — with only 2 of 8 users
eligible for leave-one-out (see the model card) the offline lift is +0.0%, so the on-device rail
proves the model is wired and honest, not that its order beats a human's judgement. Re-measure once
the platform carries ≥5 users with ≥2 bookings each. As with §4.13 these steps are manual and were
not run the wave they were written (classifier down this side); record build + emulator + backend
commit with any green result.

---

### 4.15 Player & opponent recommenders — the deterministic scorer (S.5 Wave B)

**Restart ml-service first.** The scorer is a new module (`app/core/reco_rank.py`); a uvicorn started
before this wave will not have it. Confirm with `GET /health` → `data.recoRankSpec.specVersion ==
"reco-rank-v1"` and `.specFingerprint == "1a6c5f39bf5a2c56"`, and `GET /reco/rank-spec` returns the two
weight tables. If `/health` has no `recoRankSpec`, the restart did not take. This wave trains **nothing**
— the weights are given literally — so there is no artifact, no `KNOWN_MODELS` entry, and the two
endpoints can never 503 `model_not_loaded`.

140. **Suggested players is admin-only and says what ranked it.** Open a team **you captain** → roster.
     Between the invite console and Form, a **"Suggested players"** rail loads from
     `GET /api/teams/:id/suggested-players`. Each card shows a match % badge, sports, a trust chip and a
     recent-activity line; the attribution strip reads **"SportLynk ranking"** (never "AI" — it is a
     published formula). Open the same team as a **non-admin member**: the rail is absent and the
     endpoint returns 403.
141. **The breakdown adds up and never fakes a bar.** Tap a card → the sheet opens the **"Why this
     match?"** breakdown expanded, listing the blocks in the server's `componentOrder` (sport-fit 40% ·
     level 25% · activity 20% · same-area 15%) with a bar each. A block with no input (a teamless
     player's level, a player with no bookings' area) shows **"not counted against them"**, italic, with
     no fill — confirm it is drawn as *unknown*, not a 0% bar.
142. **The invite shortcut mints the real single-use link.** Tap **Invite** on a suggestion (or "Create
     invite link" in the sheet): the standard invite dialog appears with a `sportlynk://` link, and the
     pending-invites list now shows an entry whose `note` names the player. There is no per-user invite —
     this is the same 48 h link, tagged.
143. **Opponent list is re-ranked, with the breakdown inline.** Open **Find opponents** as a captain of a
     **ranked** team. The list orders by match quality (not `|ΔELO|`), the competitiveness bar prints the
     composite score, and each card has an inline **"Why this match?"** row (level 60% · trust 20% ·
     activity 20%). The top strip reads "SportLynk ranking".
144. **FR2.6 survives the re-rank.** Point at (or create) an **unranked** opponent — no verified match.
     Its card still appears (ranked on trust + activity), but the competitiveness bar reads **"Unranked"**
     with no number, and in its breakdown the level block is the unknown "not counted against them" row.
     The printed number is never derived from a placeholder rating.
145. **ml-service down → the opponent list degrades to v1, honestly.** **Stop ml-service**, pull-to-
     refresh Find opponents. The list still populates via the v1 `|ΔELO|`-ascending sort; the attribution
     strip shows the **fallback note** (not "SportLynk ranking"), the **"OUTSIDE YOUR ±N RANGE"** divider
     reappears (it is only meaningful on the |gap| sort), and **no** card shows a "Why this match?" row or
     an invented match %. On the roster, the suggested-players rail shows its own fallback sentence. Bring
     ml-service back, refresh: ranking + breakdowns return.
146. **A 4xx does not open the breaker; an empty pool costs no round trip.** (Backend log check.) A team
     with an empty candidate pool (a sport no other local player plays) returns `suggestions:[]` with
     `ranking.available:true` and **no** ml-service call logged. A malformed request to the scorer (4xx)
     is logged but does **not** trip the circuit breaker; only 5xx/network failures (3 in a row → 30 s
     open) do, and a fallback never carries a fabricated `match_pct`.

**What this section cannot tell you.** Whether the *weights* are right. They are the numbers the spec
handed down, not learned values, so these steps prove the scorer is wired, deterministic and honest
(absent inputs neutral-not-zero, FR2.6 preserved, never badged AI) — not that `0.60/0.20/0.20` beats a
captain's own eye. Manual, and not run the wave they were written (classifier intermittently down this
side); record build + emulator + backend commit with any green result.

---

### 4.16 Offline evaluation, the model card & the two-rails demo (S.5 Wave C)

**Run order is `build_reco.py` → `eval_reco.py`, never the reverse.** The trainer writes short
train-time versions of `reports/reco_eval.md` and `reports/model_card_reco.md`; the evaluator overwrites
them with the detailed ones. Run them backwards and you silently publish the thin report over the full
one. This wave trains nothing and touches no Dart, so the artifact fingerprint and `flutter analyze`
should both come out unchanged.

147. **The eval runs and reproduces digit for digit.** From `ml-service/`:
     `.venv\Scripts\python.exe training\eval_reco.py`
     Expect: the artifact identity line naming the **released** `reco-content-v1-…` (it loads
     `models/reco_latest.joblib`, so the thing measured is the thing served), spec fingerprint
     `138790ba577ea0f0`, `20 venues · 81,395 slots (26,391 booked)`, `400 simulated players · 204
     eligible`, a four-arm table, and **`gate: … PASS`**. Run it twice — every number must be identical
     (seed `20260828`). If the fingerprint differs from `138790ba577ea0f0`, `reco_features.py` was edited
     and the released artifact no longer matches the code; stop and reconcile before reading any table.
148. **The headline is the novel cohort, and the lift is over the right baseline.** Open
     `reports/reco_eval.md`. The headline table must be **"novel venues only"** (n = 89): random 0.191 ·
     popularity 0.247 · cold-start-as-served 0.371 · content **0.461**, with **+24.2% over
     cold-start-as-served** as the claim. The all-items cohort (0.735) must appear *below* it, labelled as
     including repeat visits. A report whose headline is the all-items number is over-claiming — the
     evaluator prints them in this order deliberately.
149. **The match-% spread is visible, not a wall of 97-99%.** Same file, "Are the percentages honest?":
     min 79 · p10 82 · median 89 · p90 95 · max 98 over 1,020 sampled top-5 rows, ≥ 15 distinct values.
     If min and max are within a few points of each other the badge carries no information and the rail
     should not print it. Read the floor correctly — this samples the **top 5 rows only**, so it is not the
     distribution over the whole catalogue.
150. **The cold-start guard is measured, not assumed.** Same file, "Cold-start guard": a non-zero count of
     zero-signal players (currently 18 — no bookings, no high reviews, no stated sport) and every probed
     one reporting `profile: cold_start` with a full rail. A count of 0 means the guard was never
     exercised and the section proves nothing.
151. **The model card answers the committee's four questions.** `reports/model_card_reco.md` must name the
     six normalised feature blocks and their weights, the renormalisation rule when a block is absent, the
     cold-start policy, and — verbatim in Known limitations — **"No collaborative filtering — future
     work."** The gates block should show `lift_over_popularity` **WAIVED** with its reason (too few
     evaluable real users), not silently passed.
152. **"Why 0.5/0.3/0.2?" is answered with the table, and the answer is honest.** The sweep section must
     show the shipped row mid-table with the binomial-SE verdict — every row inside one standard error of
     every other at n = 89, i.e. *insensitive to this blend*, not *optimal*. If a future run has the
     shipped row winning outside the noise, update the claim; if a different row wins outside the noise,
     ship that row instead. The sweep rebinds the weights in memory only: after any run,
     `GET /reco/spec` must still report `138790ba577ea0f0`.

153. **`POST /reco/refresh` picks up a new artifact without a restart.** With ml-service up:
     `curl -X POST -H "X-API-Key: <ML_API_KEY>" http://127.0.0.1:8000/reco/refresh` → 200 with
     `data.version`, `data.venues` and `data.asOf`. Then check the two failure directions: **without** the
     header it must be 401 (the middleware exempts only `/health` and the docs — a phone must not be able
     to reach this), and with `models/reco_latest.joblib` temporarily renamed it must return **503
     `model_not_loaded`** *and* `/reco/venues` must then 503 as well. That second one is intended: the old
     object is dropped before the replacement is validated, because serving a model whose file has been
     swapped for an incompatible one is a worse lie than an outage with a reason. Restore the file, refresh
     again, confirm 200.
154. **Seed the two contrasting histories.** From `backend/`: `node seed_reco_demo.js`. It writes 3
     bookings + one 5-star review for each of the first two active players, on opposite ends of the
     catalogue, and prints the **contrast axis** it chose (sport if the catalogue has two sports with ≥3
     venues each, otherwise the price extremes). It creates no users and no venues — register the players
     and approve the venues first. Re-running is a no-op (bookings keyed on a `SEED_RECO_DEMO/` marker,
     reviews on the `(booking, author, type)` index). `node seed_reco_demo.js --undo` removes exactly what
     it wrote and recomputes the venue ratings it inflated.
155. **Retrain and refresh, or the rails will be identical.** The seeded rows are invisible to a frozen
     snapshot. In order: `node seed_reco_demo.js` → `.venv\Scripts\python.exe training\build_reco.py` →
     `curl -X POST … /reco/refresh` → `.venv\Scripts\python.exe training\eval_reco.py` (to restore the full
     reports the trainer just overwrote). Skipping either middle step looks exactly like a broken model and
     is really a stale artifact.
156. **Two players, two different rails — the demo beat.** `node seed_reco_demo.js --verify` prints both
     top-5 rails side by side with their percentages and reasons, the overlap count, and a verdict. Expect
     **✅ different rankings**; an ❌ identical pair means either the artifact predates the seed (go back to
     155) or both players fell to the cold-start branch (check the `profile:` value printed above the
     rail). It calls ml-service directly on purpose — going through Node would need a JWT per player and
     would hide whether the difference came from the model or from Node's fallback.
157. **The same difference is visible in the app.** Log in as player 1 → Home/Find Venues → the
     **"Recommended for you"** rail. Log in as player 2 → the same rail, **different order and different
     percentages**. This is the checklist item; the CLI verdict in 156 is its evidence, the two screens are
     its demonstration.
158. **A brand-new account gets "Popular nearby", no crash and no fake %.** Register a fresh player and
     open the same screen without booking anything. The rail is titled **"Popular nearby"**, carries **no**
     match percentages and **no** model badge, and the response reports `profile: cold_start`. A new
     account showing personalised percentages means the zero-vector branch was bypassed.



**What this section cannot tell you.** Whether the recommendations are *good*. The lift is measured on a
**simulated** user layer over the frozen S.3 world — venue attributes, per-venue demand and booking dates
are real to that world, but the players' tastes are generated, and the report says so. The real corpus is
still n = 2 with an empty novel cohort. So these steps prove the ranking function beats its own fallback
on a population whose ground truth is known, that the percentages vary, that the cold-start branch holds,
and that two histories produce two rails — not that a Pakistani player would have booked what the rail put
first. That is an online question the platform has no traffic for yet.

Steps 154-158 write to the real database and need a running emulator; **not run the wave they were
written**. Record backend + ml-service + build commits with any green result.

### 4.17 The assistant intent corpus and its exam (S.6 Wave A)

**Nothing is trained in this wave, so nothing here measures a model.** These steps prove the *data* and
the *instrument*: that the 15-label contract is intact, that the 150-row exam is what the metadata says
it is, that the 1,680-row corpus rebuilds byte-for-byte from the generator plus a seed, and that the two
are disjoint. Run order is **exam first, corpus second** — `gen_intents.py` reads
`assistant_test_meta.json` and only enforces the exam sha256 as a hard gate once that file exists. All
commands from `ml-service/`.

159. **The label contract self-checks, and publishes two fingerprints.**
     `.venv\Scripts\python.exe -m app.core.intent_spec --self-check`
     Expect `PASS 14 checks`, 15 intents, and both fingerprints: labels `assistant-intents-v1` ·
     `7bb78a3ac94cbdef`, dataset `assistant-dataset-v1` · `0eb01bc58b4a040f`. If the **labels**
     fingerprint moves, every model ever trained against it is invalid — that is not a metadata fix, it
     is a retrain. If only the **dataset** one moves, the corpus is stale but trained models stand.
160. **The exam validates 24/24, and that is what locks it.**
     `.venv\Scripts\python.exe training\validate_intent_test.py`
     Expect `24/24 PASS`, 150 rows, exactly 10 per intent with ru 4 / mix 3 / en 3, and the written
     `data/assistant/assistant_test_meta.json` carrying sha256 `f99691aa1129…`. The 15 × 3 grid is
     *derived* from the contract, not restated in the script, so a quota change cannot drift silently.
     A failure here means an exam row was edited. **Never repair a row because the model got it wrong** —
     that is the one edit that turns the instrument into a mirror.
161. **The corpus generator passes 40 gates, with exactly one WARN — dry-run it first.**
     `.venv\Scripts\python.exe training\gen_intents.py --no-write`
     Expect `RESULT: PASS -- 1680 rows, 1332 train / 348 val, 150 exam rows excluded and untouched`, and
     one WARN only: `templates_used` reporting `greeting-en-41` contributed no rows (unused capacity is
     slack working as designed). The `exam_lock` gate must read *matches* `assistant_test_meta.json`
     (`f99691aa1129…`) — if it says "no metadata yet", step 160 was skipped and the exam is unguarded.
162. **A rebuild is byte-identical, which is the reproducibility claim.**
     `.venv\Scripts\python.exe training\gen_intents.py --seed 20260824 --per-intent 112`
     then `sha256sum data/assistant/intents.csv` (git-bash) or `certutil -hashfile
     data\assistant\intents.csv SHA256`. Expect `c539b8fc4057…` — the value in `intents_meta.json`. Run
     it twice and compare the hashes, not the row count: the generator draws from *unsorted* pooled
     candidates, so an unseeded shuffle would still produce 1,680 valid rows with a different sha256.
163. **The corpus is gitignored by design; the metadata is not.**
     `git check-ignore -v ml-service/data/assistant/intents.csv` must print the matching `.gitignore`
     rule (`ml-service/data/assistant/*`). Then run `git check-ignore` over `README.md`,
     `templates.csv`, `authored_intents.csv`, `assistant_test.csv`, `assistant_test_meta.json` and
     `intents_meta.json` — every one must be **un**ignored (exit 1, no output). Drop the `-v` for that
     second half: with `-v` a negated rule is *reported* (`!ml-service/data/assistant/README.md`) and the
     exit code is 0, which reads like a failure when it is the opposite. A 200 KB generated CSV
     does not belong in git; the generator, the seed and the sha256 do, and together they reproduce it.
164. **The sha-locked CSVs are line-ending-normalised, or three provenance gates break on a fresh clone.**
     `git check-attr text eol -- ml-service/data/assistant/assistant_test.csv` must report `text: set`
     and `eol: lf`; same for `ml-service/data/sentiment/domain_test_200.csv` and
     `ml-service/data/bookings_synth.csv`. After the first commit, `git ls-files --eol` on those three
     must show `i/lf w/lf`. This exists because `core.autocrlf=true` with no `.gitattributes` hands a
     fresh clone CRLF copies and every byte-hashed gate then fails on a machine where nothing is wrong.
     If one ever does fail, fix the checkout — **do not re-record the hash**, which retires a working check.

**What this section cannot tell you.** Whether the classifier will work, or even whether the 15 intents
are the right 15. There is no model yet. The corpus is 86% template-generated, so its diversity is the
diversity of 464 hand-written patterns and their slot vocabulary — not of real users, who nobody has
observed typing at this app. What the steps do establish is that the training data is reproducible from
source, that the exam is hand-written and independent of it (0 rows leaked at the 0.80 near-duplicate
threshold, max score seen 0.500), that the validation split is grouped by template so unseen *phrasings*
are being scored, and that language carries no label signal by construction (lang × intent Cramér's V =
0.000). Wave B's confusion matrix is the first number about the model itself.

Steps 159-164 are read-only, touch no database and need no emulator; **all six run green as written**.

### 4.18 Model #4 — the intent classifier, the entity extractor and `/nlu/parse` (S.6 Wave B)

**This is the wave with a model in it.** §4.17 proved the corpus and the exam; these steps prove the
classifier trained on them, the rule-based extractor beside it, and the one endpoint Wave C's Node dialog
manager will call. Read them in order — a drifted contract fingerprint makes every later number
meaningless, so the self-checks come first, then the training run, then the unit suite, then the live
service. All commands from `ml-service/`, PowerShell, with `.venv` activated or the full interpreter path
as written.

165. **The three frozen contracts self-check — 17 + 73 + 14 checks.**
     `.venv\Scripts\python.exe -m app.core.nlu_text --self-check` → `PASS 17 checks`, `nlu-text-v1` ·
     `eca8d0423d2084b3`.
     `.venv\Scripts\python.exe -m app.core.entities --self-check` → `PASS 73 checks`, `nlu-entities-v1` ·
     `34aee7e75192e6fe`, and a line reporting `31 area phrases` and whether `dateparser` is importable.
     `.venv\Scripts\python.exe -m app.core.intent_spec --self-check` → `PASS 14 checks` with Wave A's two
     fingerprints unchanged (`7bb78a3ac94cbdef`, `0eb01bc58b4a040f`).
     Only **two** of these four fingerprints are gated when the artifact loads: the intent **labels** and
     `nlu-text`. If either moves, the served model's classes or its features stop meaning what they meant
     when it was fitted and the registry refuses the file — that is a **retrain**, not a metadata fix. The
     dataset and entity fingerprints are provenance: they are stamped into the artifact and printed, but a
     change to a rule table does not invalidate a trained classifier. `dateparser MISSING (fallback disabled)` is not
     a failure either — the extractor resolves every date form the corpus and the exam contain in its own
     rules, and this self-check passes with the library uninstalled.
166. **Train it: ten gates, ~13 s, and the SERVED artifact is written only if all ten pass.**
     `.venv\Scripts\python.exe training\train_intents.py`
     Expect `RELEASED` and 10/10 PASS: contracts · corpus provenance (`c539b8fc4057…`) · exam provenance
     (`f99691aa1129…`) · exam uncontaminated (0 exact matches, max near-duplicate 0.500 < 0.80) · no
     leakage (val 0.8678 ≤ 0.995) · beats baseline (exam 0.6200 ≥ 0.0667 + 0.10) · exam floor (0.6200 ≥
     0.55) · answers well (0.7368 ≥ 0.65 on the 114 exam rows it answers) · answers at all (val coverage
     0.8764 ≥ 0.60) · calibrated (val ECE 0.1854 ≤ 0.25). Writes `models/intent_latest.joblib` (3,872,007
     bytes) and a timestamped twin, `reports/intent_metrics.json`, `reports/model_card_intent.md`, two
     confusion PNGs, `reports/intent_reliability.png`, and refreshes `reports/requirements.lock.txt`.
     **The bare command is the reproducible one** — seed 20260824 is the default, so this run *is* what
     produced the served artifact; `--seed` anything else and the numbers below are no longer the ones to
     compare against. `--no-write` measures without releasing, `--sweep-c` re-runs the C sweep and exits,
     `--boot N` changes the bootstrap resample count. A failed gate prints `NOT RELEASED` and leaves
     `intent_latest.joblib` untouched, which is the behaviour to want: a bad retrain must not become a bad
     deploy. The **timestamped twin is written either way** (only `--no-write` suppresses it), so a failed
     run is still inspectable on disk — "the artifact is gated" means the *served* file, not every file.
167. **Read the two confusion matrices, in this order.** `reports/intents_confusion_val.png` — 348 held-out
     *phrasings*, accuracy 0.8678 / macro-F1 0.8662. Then `reports/intents_confusion.png` — the 150-row
     hand-written exam, 0.6200 / 0.6129. **The gap between them is this wave's honest headline, not a
     bug.** The validation rows come from templates the model never saw; the exam rows come from a
     different writer, and 0.62 is what generalising across writers actually costs. On the exam matrix,
     expect the diagonal to run from `create_team_help` 10/10 and `greeting` 9/10 (distinct vocabulary)
     down to `cancel_booking` 4/10, `my_bookings` 4/10 and `wallet_balance` 2/10 — the account/booking
     block is where the errors live, and `exam_top_confusions` in the metrics JSON names them pairwise, 2
     rows each and every one **one-directional** (`wallet_balance → my_bookings`, `cancel_booking →
     my_bookings`, `my_bookings → check_availability`, `check_availability → venue_info`,
     `wallet_balance → topup_help`). Cross-check `exam_grouped` in the same file: collapsed to the 6 intent
     groups the accuracy is **0.6733**, so **8 of the 57 exam errors** (5.3 points) are confusion *inside* a
     group — an error Wave C's slot filling can often absorb, unlike a cross-group one. Be precise about
     which: only **two of the ten named pairs are intra-group** (`cancel_booking → my_bookings` in
     booking, `wallet_balance → topup_help` in account). `my_bookings → check_availability` reads like a
     near-miss but crosses booking → discovery, so slot filling cannot absorb it. Two more views worth a look before drawing any
     conclusion about the language: `exam_per_language` reads mix 0.7778 (45) · ru 0.5833 (60) · en 0.5111
     (45), and `exam_per_phenomenon` reads `indirect` 0.4565 (46) and `negation` 0.3636 (11) against
     `code_switch` 0.7941 (34). **Do not read that ordering as "English is hardest" — it is a
     phenomenon-mix artefact.** English has the *largest* training slice, not the smallest
     (`intent_spec.LANG_BUDGET` en 0.40 · ru 0.35 · mix 0.25, realised 675 · 585 · 420 rows), and the exam's
     own tags explain the ranking: **76% of the `mix` rows are `code_switch`**, the model's best
     phenomenon, while `indirect`, its worst, covers **42% of `ru`** and **33% of `en`** against **13% of
     `mix`**. Cross-tab `lang` against `phenomena` in `data/assistant/assistant_test.csv` to see it. At
     45–60 rows a slice, the per-language CIs are wider than the gaps between them anyway.
168. **The abstain floor is measured, not asserted.** `reports/intent_reliability.png` is the calibration
     curve for **validation only** — its title says so (`Reliability -- validation (ECE 0.185)`); the exam's
     bins are in `reliability_exam` in the metrics JSON, not in any PNG. Read the two ECEs together (exam
     0.0829 against validation 0.1854): the model is better calibrated on the harder set because it is
     less confident there. Then in `reports/intent_metrics.json`: `floor_validation` must read
     coverage 0.8764 / answered 305 / answeredAccuracy 0.9246 / confidentErrors 23, and `floor_exam`
     coverage 0.76 / answered 114 / answeredAccuracy 0.7368 / confidentErrors 30. Read the pair together —
     at 0.45 the model answers 88% of validation and is right 92% of the time when it does, and **half of
     the wrong answers it would otherwise have given confidently become a fallback menu instead of a wrong
     action**. The cost is in the same block: 20 validation rows it would have got right are abstained on.
     Before proposing to move the number, read `threshold_sweep_validation` — 0.60 buys answeredAccuracy
     0.9549 for coverage 0.7011, 0.70 buys 0.9891 for 0.5259 — and remember the floor is stamped **into
     the artifact** as `confidenceThreshold`, so changing it is a retrain, not a serving-side edit.
169. **The unit suite: 63 tests, ≈2 s warm, no pytest required.**
     `.venv\Scripts\python.exe training\test_nlu.py` → `63 passed`. `-k date` filters by substring, `-q`
     prints failures only, and `python -m pytest training\test_nlu.py -q` works if pytest is ever
     installed (it is deliberately not in `requirements.txt`, so the suite is written to run both ways).
     Nine sections: the frozen contracts, dates, times, sports, areas, budgets, combined utterances, the
     classifier's behaviour, and the endpoint. Every date and time assertion is made against a **frozen
     clock** (`entities.FIXED_NOW` = Friday 2026-08-28 15:00 Asia/Karachi) — that is what makes "kal is
     tomorrow" a test instead of something that passes today and fails on Saturday. The classifier tests
     assert *contract and behaviour* (probabilities over 15 labels summing to 1, `predict` == argmax, the
     floor applied with `topIntent` preserved, three off-domain utterances landing on `out_of_scope`) and
     never assert a specific accuracy: accuracy is the trainer's job, and a test that pins it would fail
     on every legitimate retrain. **Run this before every commit** that touches `app/core/entities.py`,
     `app/core/nlu_text.py`, `app/core/intent_spec.py` or `app/routers/nlu.py`. Warm it takes **2.4 s**; the
     first run after a reboot took **20.2 s**, because the suite loads the released artifact through
     `registry.get` and pays the sklearn import plus the unpickle off a cold file cache — slow, not hung.
170. **Boot it and read the warm-up line — the cold cost is paid before the first user, on purpose.**
     `.\run_dev.ps1`, then look for `nlu warmed (model intent-v1-20260828-0053, 9.71ms first parse);
     entities 31 areas, dateparser=True in 108.4ms` in the startup log. That line is a *feature*: in a
     process where the warm-up is skipped, the first parse measures **945 ms** and logs
     `nlu parse over budget` — sklearn's imports and the unpickle of a 3.9 MB joblib land on whoever asks
     first, and `main.py`'s lifespan makes that the boot, not a user. `nlu not warmed — intent model
     not_loaded` instead means step 166 was never run (or its gates failed): the service still boots, and
     `/nlu/parse` will return an honest **503** naming the reason rather than a guess.
171. **`GET /health` now reports four models.** `curl http://127.0.0.1:8000/health` (one of **six** unkeyed
     paths — `main.py`'s `PUBLIC_PATHS` also exempts `/`, `/docs`, `/docs/oauth2-redirect`, `/redoc` and
     `/openapi.json`) → `{success, data}` with `data.models` carrying **pricing, sentiment, reco and
     intent**, all `ready`. On the intent entry check `modelVersion` (`intent-v1-<date>-<hhmm>`),
     `specVersion: "assistant-intents-v1"`, `artifact: "intent_latest.joblib"`, and that the metrics it
     echoes are the ones from step 166 — `/health` reads the artifact's own stamped block, so a mismatch
     between this and `intent_metrics.json` means uvicorn is serving an older file than the one you just
     trained. **`/health` carries no `threshold` and no `labels` field**, and the version key is
     `modelVersion`, not `version`: the entry is exactly `registry.describe()`. The floor and the label
     count live on `GET /nlu/spec` (step 174) and in `POST /nlu/refresh`'s reply (step 176).
     `apiKeyFingerprint` must be identical here and in Node's startup log; **never print the key itself.**
172. **One parse, five slots, `< 50 ms`.**
     `curl -s -X POST http://127.0.0.1:8000/nlu/parse -H "X-API-Key: <ML_API_KEY>" -H "Content-Type:
     application/json" -d "{\"text\":\"kal shaam 6 baje f-11 me futsal ground chahiye 2500 tak\"}"`
     Expect `intent: "find_venue"`, `confidence ≈ 0.78`, `intentGroup: "discovery"`, three
     `alternatives` best-first (`find_venue` 0.78 · `book_venue` 0.15 · `find_opponents` 0.02), and all
     five slots filled: `date.iso 2026-08-29` (`rule: relative:kal`), `time.start "18:00"`
     (`clock:baje` — "6 baje" with "shaam" resolves to 18:00, not 06:00), `sport.value "futsal"`,
     `area.area "F-11"` (`gazetteer:slot-vocab`), `budget {op:"max", amount:2500, currency:"PKR"}`. Every
     slot carries its own `text`, and `date`/`time`/`area`/`budget` also carry a `span` — which is how Wave
     C will highlight what it understood. Two asymmetries to code against: `sport` returns only
     `{value, text, source}` (plus `variant`) with **no `span` and no `rule`**, and `budget` has a `span`
     but no `rule`. A highlighter that assumes all five slots are uniform will throw on `sport`.
     `elapsedMs` was **9.92** on this box (intent 9.69, entity 0.20); the endpoint's budget is 50 ms and it
     logs a warning at every breach, so an empty log is itself the assertion. Measured over **300 corpus
     utterances** through HTTP: server p50 **14.6 ms**, p95 18.9, p99 21.8, max 28.6, **0/300 over
     budget** (round-trip including Windows loopback and JSON: p50 30.2 ms, max 49.1). Add
     `"sessionId":"t172"` and confirm the log line reads `intent=… conf=… abstained=… chars=… session=t172`
     — **the utterance itself is never logged**, here or anywhere (same rule as review text, §6).
173. **The three refusal paths, which are the assistant's whole safety story.** Same command, three
     bodies, and the important field is `abstainReason`:
     * `"???"` → `abstained: true`, `abstainReason: "no_evidence"`, `confidence: 0.0`, `alternatives: []`.
       Nothing but punctuation survived normalisation, so **the estimator is never called** (`intentMs`
       0.02) — it would have answered, and that answer would be a reading of punctuation dressed as a
       calibrated probability. Node re-asks the pending slot.
     * `"asdkjh qweqwe zxcvb"` → `"no_known_terms"`, `confidence 0.0`. Real words, none of them in the
       word vocabulary. This guard exists because the floor cannot do its job here: gibberish scored
       `greeting` **0.5246** — comfortably *above* 0.45 — and the fix is evidence, not a higher threshold.
       Measured before it was written: 0 firings on all 1,680 corpus and 150 exam rows, 85 of 87 gibberish
       strings caught, 0.022 ms per call — but that sweep was a one-off during Wave B and **its 87-string
       list is not committed**, so the only assertions you can reproduce from this repo are the two in
       `test_nlu.py` (`test_gibberish_is_refused_even_though_the_floor_cannot_catch_it` and
       `test_a_typo_is_not_treated_as_gibberish`).
     * `"mera match kab hai"` → `"low_confidence"`, `intent: "out_of_scope"` but `topIntent:
       "find_opponents"` at `topConfidence 0.4107`, with `alternatives` `find_opponents` 0.41 ·
       `my_bookings` 0.29 · `out_of_scope` 0.19. **This is the did-you-mean menu**, and `topIntent` is why
       an abstention is auditable: "it said out_of_scope" and "it thought find_opponents at 0.41" call for
       different fixes.
     Then confirm the rule that makes slot-filling work: **abstention never withholds entities.**
     `"2 din baad shaam 7 se 9 g-8 cricket 4000 se 6000"` abstains at 0.439 and *still* returns date
     2026-08-30, time 19:00→21:00, sport cricket, area G-8, budget 4000–6000. Node can keep the slots and
     ask only for the verb.
174. **`GET /nlu/spec` is the contract Wave C reads at startup.** `curl -H "X-API-Key: <ML_API_KEY>"
     http://127.0.0.1:8000/nlu/spec` → the envelope's `data` carries `model` (status, version, trainedAt,
     `threshold` **and `thresholdSource: "artifact"`** — "router default" means the served joblib predates
     the stamped floor), `intents` (all 15 with `group`, `gloss` and `confusableWith`), `groups` (6),
     `entities`, `text`, `corpus` (Wave A's row budgets, near-duplicate ceilings and exam quotas),
     `abstainReasons` (the three ids from step 173, each with its one-line meaning) and `limits`
     (`maxTextChars` 500, `alternatives` 3, `latencyBudgetMs` 50). Two properties to verify rather than
     assume: it **does not 503 when the model is missing** (it answers "what contract does this service
     implement", and reports the model's state as a field — which is what lets Node validate its label
     mapping before anything is trained), and its `threshold` equals the `threshold` field on a live parse.
     A label in Node's router that is absent from this list must be a loud mismatch, never a silent
     `default:` branch.
175. **The request contract, including the parts that must be refused.** Four calls to `/nlu/parse`:
     `{"text":""}` → **422** `{"success":false, "message":"Invalid request: …", "code":"invalid_request"}`;
     a 501-character text → **422** (`maxTextChars` 500 is a DoS bound, not a UX one); `{"text":"kal",
     "sport":"futsal"}` → **422** (unknown fields are rejected, so a typo in Node's payload fails loudly
     at integration time instead of being silently dropped); and no `X-API-Key` header → **401**. Then the
     one field that exists for testing: `{"text":"kal","now":"2026-12-25T10:00:00+05:00"}` → `date.iso`
     **2026-12-26**, not tomorrow. Every date rule resolves against `now` if it is supplied, which is what
     makes the frozen-clock tests in step 169 possible and what will let Wave C replay a stored
     conversation without the answers drifting by a day.
176. **`POST /nlu/refresh` picks up a retrain without restarting uvicorn — and fails loudly by design.**
     `curl -X POST -H "X-API-Key: <ML_API_KEY>" http://127.0.0.1:8000/nlu/refresh` → 200 with the new
     `modelVersion`, `labels: 15` and `threshold`. Two things to understand before trusting it: it drops
     the cached object **before** validating the replacement, so if `models/intent_latest.joblib` is
     missing or its label/normaliser fingerprints no longer match this code, refresh returns **503 with
     the registry's reason and `/nlu/parse` starts returning 503 too** — an outage that says why, chosen
     over silently serving a model whose file on disk was swapped for an incompatible one. And it reloads
     **artifacts, not code**: after editing `app/routers/nlu.py` or `app/core/entities.py` you must restart
     the process, and a refresh that "did not pick up the change" is almost always this.
177. **Nothing downstream moved.** From `D:\sportlynk\backend`: `node src/scripts/check_ml_service.js` →
     **`71/71 checks passed`** with ml-service up. The §9 line already reads 71/71: the suite was 60 checks
     until **S4-C** wired sentiment into the review write path and added 11 of its own. The forecast
     checks were already inside the 60 (`check_ml_service.js:617-661`), so do not attribute the +11 to
     Wave D. The fourth model must be invisible to it: the harness asserts `Array.isArray(h.models)`
     rather than a count, which is exactly why adding a model to `/health` is not a breaking change for
     Node. One expected diff to
     ignore: step 166 rewrites `reports/requirements.lock.txt`, which `train_pricing.py` and
     `train_sentiment.py` also write (S.5's `build_reco.py`/`eval_reco.py` do not). That
     file records the environment, not the model — the rewrite is the point of it.

**What this section cannot tell you.** Whether the assistant *works*. There is no dialog manager yet: no
session state, no slot filling across turns, no action executed, no Flutter screen — the dialog manager
and action executor are **Wave C**, the chat screen is **Wave D** — and none of these steps touch Postgres
or a JWT. What they establish is narrower and worth stating
precisely. The classifier scores **0.62 on 150 utterances written by one person who is not a user of this
app**, and 0.87 on held-out phrasings of the templates it was trained on; the truth for real traffic is
very likely between those two numbers and closer to the first, because the exam writer at least knew the
domain. The 0.45 floor converts about half of the model's confident mistakes into a menu, which is the
single most important number in the wave for a demo — a wrong booking is a support ticket, a menu is a
click. The entity extractor is **pure rules and is meant to be**: every form in this section is a form
someone wrote a rule for — but state the limits precisely, because two of them are narrower than they
look. `4k tak` **does** parse to 4,000 (`_RE_AMOUNT_K`; `entities.py:1294` pins `3k tak ka ground
chahiye` — 3,000 as a self-check case); what fails is the
**spaced** `2 k tak`, because `nlu_text`'s synonym fold rewrites a standalone `k` to `ke` before the amount
rule runs, and `4k budget` with no quantifier resolves `op: "qualitative"` off the word "budget" rather
than the number. Sports outside the platform's five (padel, snooker) resolve to `null` by design. And an
area outside the gazetteer is not always missed: a sector-shaped token like `g-13` or `i-10` is resolved by
`_RE_SECTOR` with `rule: "sector"`, `area: "G-13"` and `zone: "UNKNOWN:G-13"` — canonical value, no city —
so only non-sector place names outside the gazetteer come back `null`. Those are documented limitations, not
regressions, and the rule tables are fingerprinted precisely so that "fixing" one is a visible, deliberate
act. Nothing here measures how a human feels about the answer, and no amount of it substitutes for the
first ten real users.

Steps 165-177 are read-only with respect to the database and need no emulator; steps 165-169 need only the
venv, 170-177 need uvicorn running. **All thirteen run green as written.**

---

### 4.19 Scout — the v2 label contract and model #4 retrained (S.6 Wave C, ml-service half)

**Read §4.18 first; these steps replace its numbers, they do not add to them.** Wave C moved the label
contract from 15 intents to **23** and refitted model #4 on it, so every figure in §4.18 now describes a
**superseded** artifact (`intent-v1-20260828-0053`). Nothing in §4.18's *method* changed — the same gates,
the same self-checks, the same abstain policy — so what follows is the delta plus the two things that only
break on a version bump: the load-time fingerprint check and the label-reachability sweep. The Node half of
this wave (Scout's dialog manager, `POST /api/assistant/message`, the KB and escalation) is documented from
**step 190** onward. All commands from `ml-service/`, PowerShell, `.venv` activated or the full interpreter
path as written.

178. **The contract self-check must now print v2 — and BOTH fingerprints must have moved.**
     `.venv\Scripts\python.exe -m app.core.intent_spec --self-check` → `PASS 14 checks`,
     `assistant-intents-v2 / 68396192ab4a87a4` **+** `assistant-dataset-v2 / 339ad58af5ddb072`, and a line
     confirming the two are **distinct**. If either still reads v1 you are looking at an unmodified checkout
     and every number below will disagree with you. `nlu_text` (`PASS 17`, `eca8d0423d2084b3`) and
     `entities` (`PASS 73`, `34aee7e75192e6fe`) must be **unchanged** — the feature normaliser and the rule
     tables were deliberately not touched in a wave that retrains, so that the only moving part is the
     label set. Expect 23 intents in **8** groups; the 8th is `dialog`, and it contains exactly `affirm`
     and `deny`.
179. **Validate the exam BEFORE regenerating the corpus — this order is not cosmetic.**
     `.venv\Scripts\python.exe training\validate_intent_test.py` → 24 read-only checks over
     `data/assistant/assistant_test.csv`, now **230 rows** (10 per intent, ru 4 / mix 3 / en 3 per intent),
     re-locking `assistant_test_meta.json` at sha **1f60b29cabad**. `gen_intents.py` then enforces that
     lock as a HARD gate and uses the exam for **exclusion only**, so validating second means generating
     against a stale hash and failing for a reason that has nothing to do with what you changed. v1's
     original 150 rows are **byte-identical** inside the 230 — that is what keeps the v1-vs-v2 comparison
     in PROGRESS honest, and a diff that touches them invalidates it.
180. **Regenerate the corpus and check the receipt, not just the exit code.**
     `.venv\Scripts\python.exe training\gen_intents.py` → `data/assistant/intents.csv` **2,576 rows**, sha
     **64395ec8026c**, `all_passed true` in `intents_meta.json`. Expect **112 rows per intent** (equal by
     construction, not by luck), en 1035 · ru 897 · mix 644, and `census.per_template` reading
     `624 templates · 622 used · 2 unused` — the two unused ids are `greeting-en-40` and `greeting-en-41`,
     and they are named in the meta rather than silently absent. Re-run it: the sha must be **identical**,
     because the corpus is a seeded draw and a drifting sha means the provenance gate in step 181 is about
     to fail for a reason nobody can reproduce.
181. **Train it: 10/10 gates, ~28 s, and v1 stays released if any gate fails.**
     `.venv\Scripts\python.exe training\train_intents.py` → `RELEASED`,
     `models/intent_latest.joblib` **6,610,141 bytes**, `intent-v2-20260828-2315`. All ten gates, with the
     numbers to expect: contracts · corpus provenance (2,576 rows, `64395ec8026c`) · exam provenance
     (230 rows, `1f60b29cabad`, "locked and unedited") · exam uncontaminated (**0 exact**, max near-dup
     **0.7143** word_set < 0.80) · no leakage (val 0.8086 ≤ 0.995) · beats baseline (exam 0.6696 ≥ 0.0435 +
     0.10) · exam floor (0.6696 ≥ 0.55) · answers well (**0.7735** on the 181 rows it answers ≥ 0.65) ·
     answers at all (val coverage 0.8662 ≥ 0.60) · calibrated (val ECE **0.1788** ≤ 0.25). Read those
     numbers off `gates[].detail` in `reports/intent_metrics.json` rather than off this page — the released
     run is `intent-v2-20260828-2315` and an earlier `intent-v2-20260828-1329` exists in `models/`, so a
     figure quoted from memory has a plausible-looking wrong twin. The artifact is
     **1.71× larger** than v1's for 1.53× the labels, and the fit takes 30.6 s rather than 13.2 — 23 classes
     × 5 grouped calibration folds = 115 sub-estimators. **The rule this wave was held to: a gate v1 passed
     that v2 fails means v2 does not ship and v1 stays released, and no threshold is lowered to make a model
     pass.** All ten passed unmodified; `confidenceThreshold` is still 0.45 and still stamped in the
     artifact.
182. **The exam is 230 rows now, so re-read both matrices against the new denominators — and check which
     *fit* each PNG is drawn from.** `reports/intents_confusion_val.png` — titled **"validation (n=538,
     acc 0.809)"**: 538 held-out phrasings, **0.8086** / macro-F1 **0.8042** (v1 read 0.8678 over 348 — the
     drop is 8 more classes to be wrong in, on 23 rather than 15 columns). Then
     `reports/intents_confusion.png` — titled **"exam (n=230, acc 0.670)"**, which is the **full-refit**
     model that actually ships: `exam_scores` **0.6696** / **0.6608**, up from v1's 0.6200 on its 150. Do
     not quote `exam_split_fit` **0.6652** / 0.6566 for this picture — that is the train-split-only model
     reported beside it as a leakage control, the two differ by 0.0044 (well inside the CI, and the model
     card says so at line 161), but they are two different fits and only the first one is in the PNG and in
     the joblib. Collapsed to the 8 groups the exam reads **0.7652** (`exam_grouped`): same 230 rows, **22**
     of them (a tenth of the exam, 29% of its 76 errors) wrong only in *which sibling of the right group*
     won. The rows to look at first are the ones the new labels pressure: `contact_owner` 10/10 and
     `elo_help` 10/10 (distinct vocabulary, nothing else claims it), `navigate` 9/10, `find_players` 8/10 —
     against `wallet_balance` 2/10, `my_bookings` 3/10 and `venue_info` 5/10, which is the same
     account/booking block §4.18 flagged and which the new labels did **not** make worse. On validation the
     two weakest rows are different ones — `out_of_scope` recall **0.409** (it leaks to `app_help` 4 and
     `topup_help` 3, i.e. a vague complaint reads as a help request) and `venue_info` **0.417** (7 to
     `navigate`, 5 to `refund_policy`) — so the exam and the validation split do not agree on where the
     model is weakest, which is itself the argument for keeping both. `exam_per_language` now reads mix
     **0.8261** (69) · ru **0.6087** (92) · en **0.5942** (69), and the §4.18 warning still applies: that
     ordering is a **phenomenon-mix artefact**, not evidence about English — `exam_per_phenomenon` has
     `indirect` at **0.4909** (55 rows) against `code_switch` at **0.8621** (58), so a language slice's
     score mostly reports which phenomena happened to be written in it.
183. **The floor's price changed with the label count — read it before quoting the old numbers.** In
     `reports/intent_metrics.json`: `floor_validation` must read coverage **0.8662** / answered **466** /
     answeredAccuracy **0.8863** / confidentErrors **53**, and `floor_exam` coverage **0.7870** / answered
     **181** / answeredAccuracy **0.7735** / confidentErrors **41**. Both answered-accuracies are lower than
     v1's (0.9246 val) and that is expected: 8 more labels means 8 more ways to be confidently wrong. What
     matters for the product is unchanged — at 0.45 the model answers **87%** of validation, is right
     **89%** of the time when it does, and **confident errors fall 103 → 53**: the threshold silences
     roughly half of every mistake the argmax would have made. The cost is in the same block and is worth
     stating as rows rather than rates — **22 validation rows and 14 exam rows** that the argmax got right
     are refused instead (0.8086×538 − 0.8863×466 = 22; 0.6696×230 − 0.7735×181 = 14). And
     `threshold_sweep_validation` is still there for anyone who wants to argue the number.
184. **The unit suite is 68 now, and one of its tests is a load sensor.**
     `.venv\Scripts\python.exe training\test_nlu.py` → **68 passed, 0 skipped**. `0 skipped` is part of the
     assertion: `test_the_abstain_floor_is_actually_applied` used to **skip silently** because the single
     vague utterance it pinned had risen above 0.45 as the corpus grew, and a skipped floor test is
     indistinguishable from a floor that is not applied. Five tests are new — the v1-subset property, the
     reachability of all 8 added labels, `dialog` == {`affirm`, `deny`}, every intent having a group and a
     gloss, and the squad-short regression in three languages. **The one test that fails for reasons that
     are not the code** is `test_a_warm_parse_stays_inside_the_fifty_millisecond_budget`: it failed three
     times in a row at 63–95 ms median while a second dev session was running Node and Postgres on this box,
     and passed three times in a row immediately afterwards. If it fails, check the load before you check
     the model — and confirm with step 188, which measures the same thing through HTTP with an
     intent-vs-entity split.
185. **The version bump breaks a running service on purpose — this is the trap to walk into deliberately
     once.** With uvicorn already up on the v1 artifact, `curl http://127.0.0.1:8000/health` after step 181
     reports the intent entry **`incompatible`** ("artifact was trained on 'assistant-intents-v1' but this
     service builds 'assistant-intents-v2'") and `modelsReady` **3/4** — the label fingerprint is checked at
     load, so a retrain that changes the label set is a *deploy* event, not a file swap.
     `curl -X POST -H "X-API-Key: <ML_API_KEY>" http://127.0.0.1:8000/nlu/refresh` → 200 with
     `modelVersion: "intent-v2-20260828-1329"`, `labels: 23`, `threshold: 0.45`; then `/health` reads
     **4/4 ready** with `specVersion: "assistant-intents-v2"`. That timestamp is the run that was current
     when this step was written; `intent_latest.joblib` on disk is now the released
     **`intent-v2-20260828-2315`**, so assert the **`intent-v2-`** prefix, `labels: 23` and `threshold:
     0.45` — never the timestamp. A restart does the same thing. Not doing
     either leaves `/nlu/parse` returning 503 with the registry's reason, which is the correct behaviour and
     is not a bug to work around.
186. **`GET /nlu/spec` is the contract Scout reads at boot, and every count in it moved.**
     `curl -H "X-API-Key: <ML_API_KEY>" http://127.0.0.1:8000/nlu/spec` → inside `data`: `intents` **23**
     each with `group`, `gloss` and `confusableWith`; `groups` **8**; `model.threshold` 0.45 with
     `thresholdSource: "artifact"`; `corpus.intentSpecVersion` **assistant-intents-v2**; `abstainReasons`
     exactly `low_confidence` · `no_evidence` · `no_known_terms`; fallback intent **`out_of_scope`**. Three
     integration facts to verify here rather than discover in Node: **`/nlu/spec` and `/nlu/refresh` are
     enveloped as `{success, data}` but `/nlu/parse` is NOT** — it returns the flat object, so a uniform
     `.data` unwrap in `mlClient` breaks on parse; **`modelVersion`'s major tracks the label contract**, so
     `intent-v1-*` → `intent-v2-*` and nothing may parse it except for display (read
     `corpus.intentSpecVersion` instead); and the endpoint still **does not 503** when no model is loaded,
     which is what lets Node validate its label mapping before anything is trained.
187. **Prove all 8 new labels are reachable over HTTP — a label that never wins is dead code in a
     contract.** `POST /nlu/parse` with each of: "we are 3 players short for the game" → `find_players` ·
     "kisi team me jagah hai to bata do main join karunga" → `find_teams` · "how do i get to centaurus from
     blue area" → `navigate` · "i want to talk to the owner of this ground" → `contact_owner` · "app me
     profile kaise edit karun" → `app_help` · "elo kaise barhta hai" → `elo_help` · "haan bilkul kar do" →
     `affirm` · "nahi rehne do abhi" → `deny`. Each must win by **≥0.35 over its runner-up** (measured:
     +0.80 to +0.93). These same eight are pinned in `test_nlu.py`, so this step is the live confirmation,
     not the only guard. Then check the two things Scout must build around: `affirm`/`deny` come back with
     `intentGroup: "dialog"` and **no object** — acting on a bare "haan" with no pending proposal in session
     state confirms a booking the user never saw — and the entity block is still only
     `{date, time, sport, area, budget}`, so "need 2 players" yields **no 2** and `navigate` /
     `contact_owner` yield **no venue name**. Those must be resolved from `area` plus the database or from
     thread context; the extractor was deliberately not changed in this wave.
188. **Re-measure the 50 ms budget, and read a breach as a load signal first.** Sweep the 230 exam rows (or
     a 120-row sample) through `/nlu/parse` and read the server's own `elapsedMs` / `intentMs` / `entityMs`.
     On a quiet box: p50 **20.9 ms**, p95 32.9, max 114.0, **2/120 over budget** — against v1's p50 14.6 and
     0/300. The model genuinely got slower (**9.41 ms** median `predict_proba` vs v1's **7.46 ms**, measured
     back to back in one interpreter on the same utterances: +26% for 8 labels), but it did not get slow.
     On a box shared with a second dev session the same 120 rows read **p50 82.6 ms with 119/120 over
     budget**, while `entityMs` never moved off **0.2 ms**. So: `entityMs` flat + `intentMs` inflated =
     contention, not regression. The budget is still 50 ms and the endpoint still logs a warning on every
     breach; what changed is that the margin is now thin enough that a busy laptop trips it, and that is
     recorded rather than papered over by raising the budget.
189. **Nothing downstream moved.** From `D:\sportlynk\backend`: `node src/scripts/check_ml_service.js` →
     **`71/71 checks passed`** with ml-service up, unchanged across a label-contract bump — the harness
     asserts `Array.isArray(h.models)` and a list of keys, never a count or a version string, which is
     exactly why this was not a breaking change for Node. Re-run it *after* step 185, not before: against an
     `incompatible` intent model the health assertions still pass (they check the four keys are present),
     which is a good reminder that `71/71` is not a statement about model #4's health — `modelsReady 4` is.

**What this half of the wave cannot tell you.** Whether Scout works. There is still no dialog manager in
these steps, no session state, no confirmation gate, no action executed and no Flutter screen: this is a
classifier that now understands 23 intents instead of 15, verified over HTTP, and nothing more. Two limits
worth stating precisely because they will shape the Node half. **The exam is 230 rows written by one person
who is not a user of this app**, so 0.6696 is a writer-generalisation score, and the 95% CI
**[0.6087, 0.7261]** (2000 bootstrap resamples) cannot distinguish it from v1's 0.6200 on 150 — the case for
v2 is not that it scores higher, it is that it can express eight things v1 could not say at all, with 0 of
v1's 15 labels dropped and a confidently-wrong *rate* that did not worsen: **41/230 = 17.8%** of exam rows
against v1's 30/150 = 20.0%. Compare those as rates and never as raw counts — the denominators differ, and
"41 confident errors against v1's 30" read straight off two different exams is the easiest number in this
document to misquote. And **the abstain region is invisible to users**: raw accuracy scores the argmax even
below 0.45 while the service abstains there, so any accuracy comparison that ignores coverage is measuring
something the product never shows. The numbers that matter for Scout are answered-count, accuracy-on-answered
and confidently-wrong count — all three are in `floor_exam` and `floor_validation`.

Steps 178-184 need only the venv; 185-189 need uvicorn running, and 189 needs Node. **All twelve run green
as written**, with the one caveat named in steps 184 and 188: the latency assertion is load-sensitive and
must be measured on an otherwise-idle box.

### 4.20 Scout — dialog manager, actions, chat history and the money gate (S.6 Wave C, Node half)

**This is the half a viva panel will actually click on.** §4.19 proved the classifier; these steps prove the
thing that uses it: slot-filling across turns, a booking written through the *same* service the REST route
uses, a refund preview, chat history, the KB/escalation loop, and the two doors that are allowed to move
money. One script does almost all of it. Read step 192 before running anything else, because that script is
the gate the whole wave is judged by. `ml-service` must be up (`/health` 4/4) or every intent abstains, and
all Node commands run from `D:\sportlynk\backend`.

190. **Migration 018 — four tables, two altered, twelve indexes.**
     `node run_migration_018.js` → idempotent (`IF NOT EXISTS` throughout), safe to re-run. Then confirm in
     the Supabase SQL editor:
     ```sql
     SELECT table_name FROM information_schema.tables
      WHERE table_name LIKE 'assistant%' ORDER BY 1;
     -- assistant_escalations · assistant_feedback · assistant_kb · assistant_turns
     SELECT column_name FROM information_schema.columns
      WHERE table_name='chat_channels' AND column_name IN ('session_state','archived_at','assistant_persona');
     SELECT conname FROM pg_constraint WHERE conname='chk_assistant_turns_src';
     ```
     `pg_trgm` is created **conditionally** — if the extension is unavailable the migration still applies and
     the KB matches with `ILIKE` instead (`assistantKb.hasTrgm()` probes `pg_extension` once and caches). To
     see which path this database is on: `SELECT 1 FROM pg_extension WHERE extname='pg_trgm';`
191. **The unit suite, with the database DOWN.** `npm test` → **85/85**. Turning the database off is the
     point: these tests cover `escrow`, `elo`, `policyText` placeholder resolution and the reply/card enums,
     none of which may need a connection. `test/assistant.test.js` asserts that **every placeholder in every
     policy template resolves** against the real `escrow.POLICY` — that is what stops `PKR undefined` from
     ever reaching a user's chat.
192. **THE GATE: `node src/scripts/check_assistant.js` → `PASS 326/326`, exit 0, zero skips, **~2m40s**.**
     It drives Scout through 45 real turns as seeded demo users, against the **live** classifier, with real
     money, inside one `BEGIN … ROLLBACK`. Expect exactly this shape:
     ```
     0  preflight — registry, model #4, migration 018                                 3
     A  find a ground → see times → pick → confirm → booked                          42
     B  cancel it → refund preview → confirmed → wallet and ledger agree             33
     C  a yes that is really a correction must NOT spend money                       11
     C2 stale confirms, model denials, and the button that must still work           11
     D  reads: wallet · bookings · policy · tournaments · team rating · help · oos   47
     E  escalation → the owner answers → the next ask is free                        28
     F  discovery: ground info · directions · players · opponents · teams            28
     G  threads: new · switch · rename · archive · delete · ownership                53
     H  FR8.15 — one implementation of every rule, shared by route and Scout         40
     I  the milestone utterance — "kal shaam football islamabad" → a booked row      30
                                                                           PASS 326/326
     the transaction was rolled back — the database is exactly as it was.
     ```
     Reading a failure: a `SKIP` line is **not** green — it is printed and counted separately precisely so a
     run that quietly avoided the money path cannot look like a pass. `no free slot at <venue>` means the
     fixture venue has no bookable hour left today (run `node src/scripts/add_future_slots.js` and re-run).
     A preflight failure naming a fingerprint means ml-service is serving an artifact this code does not
     expect — that is §4.19 step 185, not a Scout bug. Redirect the output to a file if you want to read it
     twice; piping it through a pager loses the tail.
193. **Read the transcript it prints, not just the count.** The last block of the run dumps all 45 turns with
     the user text, Scout's reply, the card types and `totalMs`. That transcript is the demo script: if a
     sentence in it reads like a robot, fix the copy before the viva. It is also the only place the per-turn
     latency is recorded — Scout's response time is not asserted anywhere, because the parse budget is
     load-sensitive (§4.19 step 188).
194. **Prove it really rolled back.** After the run:
     ```sql
     SELECT count(*) FROM chat_channels WHERE type='assistant';   -- unchanged (0 on a fresh demo DB)
     SELECT count(*) FROM assistant_turns;                        -- unchanged
     SELECT count(*) FROM assistant_escalations;                  -- unchanged
     SELECT count(*) FROM bookings;                               -- unchanged (40 on the seeded demo DB)
     ```
     If any of these grew, the harness lost its transaction — stop and read `handleTurn`'s `client` seam
     before trusting a later run.
195. **The money extraction, on its own, against the escrow table: `node src/scripts/check_booking_service.js`
     → `PASS 60/60`.** Also always rolled back. Where step 192 proves *Scout* books correctly, this proves the
     **extraction** did not change what booking means — it books and cancels for real and asserts the ledger
     line by line against the table at the top of `utils/escrow.js`: full refund ≥24h out, `+0.8P / +0.2P`
     inside the window (`the ledger sums to -440`), double-book refused (`slot_taken`), double-cancel refused
     (`not_cancellable`), a broke player refused (`insufficient_funds`) **with the wallet and the slot left
     exactly as they were**, plus `missing_args` and `slot_not_found`. Every refusal carries a machine code
     next to the human sentence, deliberately, so the dialog manager never string-matches English. Run this
     one whenever anything in `escrow.js`, `bookingService.js` or `routes/bookings.js` is touched — it is
     faster than 192 and it is the one that catches a refactor that loses PKR 200 a cancellation.
196. **The endpoints over real HTTP — the part the scripts do NOT cover.** Steps 192 and 195 call the services
     directly with a rolled-back client, which is what makes them affordable; they never touch Express, the
     JWT middleware or the rate limiter. **These writes are real** — do them as the demo player and delete the
     thread at the end. `npm start` in one terminal, then:
     ```bash
     BASE=http://localhost:3000/api   # PORT defaults to 3000 (server.js:131)
     TOKEN=<login as the demo player>                         # POST $BASE/auth/login
     curl -s -X POST $BASE/assistant/message -H "Authorization: Bearer $TOKEN" \
          -H "Content-Type: application/json" \
          -d '{"text":"rawalpindi mein cricket ground chahiye"}'
     # → data.reply.cards[] of type "venue", data.reply.source "live"|"model",
     #   data.threadId (save it), data.nlu.intent "find_venue", data.nlu.confidence
     curl -s $BASE/assistant/threads -H "Authorization: Bearer $TOKEN"
     curl -s "$BASE/assistant/threads/<threadId>/messages?limit=10" -H "Authorization: Bearer $TOKEN"
     curl -s -X PATCH $BASE/assistant/threads/<threadId> -H "Authorization: Bearer $TOKEN" \
          -H "Content-Type: application/json" -d '{"title":"Pindi plans"}'
     curl -s $BASE/assistant/capabilities -H "Authorization: Bearer $TOKEN"
     curl -s -X DELETE $BASE/assistant/threads/<threadId> -H "Authorization: Bearer $TOKEN"
     ```
     Four things to check while you are in here: the body field may be `session_id`, `sessionId`, `threadId`
     or `thread_id` (all four are accepted on purpose — Wave D should not 400 over a naming preference);
     omitting it entirely is legal and means "newest chat, or a new one"; a chip is posted as
     `{"action":"pick_slot","args":{...}}` with **no text**; and the `messages` cursor must be passed back
     **verbatim** — it is an opaque row tuple, not a page number.
197. **The security cases, all four with a token in hand.** No `Authorization` header → **401** (the router
     is behind `router.use(auth)`, so every one of the 16 endpoints is covered by one line). Another user's
     thread id on `GET /threads/:id/messages` and on `POST /message` → **404 `thread_not_found`**, never a
     403 and never a leaked title. A non-uuid thread id → 404, not a 500. A 501-character `text` → Scout
     answers with the capability menu (`abstainReason: text_too_long`, refused in `mlClient` **before** the
     HTTP call, because the parser's own limit is 500 and a 422 is not something a chat screen can render).
     Then the 51st thread → **`too_many_threads`** (`MAX_THREADS = 50`).
198. **FR8.15 by hand, in one grep.** From `backend/`:
     ```bash
     grep -rn "INSERT INTO bookings" src/ --include=*.js | grep -v /scripts/
     # → exactly ONE hit: src/services/bookingService.js
     grep -rln "applyWallet(\|logTxn(\|penaltySplit(\|lockWallet(\|UPDATE slots SET status" \
          src/services/assistant* src/services/dialogManager.js src/routes/assistant.js
     # → NOTHING. Scout owns no money primitive.
     ```
     Step 192's section H does this over all 50 files of `src/` and fails the run if either answer changes.
199. **Privacy, as a column census rather than a promise.**
     ```sql
     SELECT column_name, data_type FROM information_schema.columns
      WHERE table_name='assistant_turns' ORDER BY ordinal_position;
     ```
     17 columns, and the only length-ish one is `text_chars int`. There is **no column that can hold what the
     user typed** — the utterance lives only in the user's own chat thread, which they can delete. Deleting a
     chat cascades its messages while `assistant_turns.channel_id` is `ON DELETE SET NULL`, so the evidence
     that model #4 answered *n* turns at *m*% abstention survives a deletion that removes the conversation.
     Confirm the enum is enforced, not merely documented:
     ```sql
     INSERT INTO assistant_turns (answer_source) VALUES ('gpt');   -- user_id is nullable
     -- → violates check constraint "chk_assistant_turns_src"   (expected; roll it back)
     ```
200. **Owner side.** As a venue owner: `GET /api/assistant/owner/questions` lists escalations for **their**
     venues only, `POST .../:id/answer` delivers the answer into the asking player's own thread as a Scout
     message and optionally stores it in `assistant_kb`, `POST .../:id/decline` closes it without one, and
     `GET /api/assistant/owner/stats` reports what Scout has been telling players about their ground. The
     next player asking the same question must get `source: "kb"` — that round trip is step 192's section E,
     and it is worth doing once by hand because it is the wave's most demo-able feature.

201. **THE SECOND GATE, and the answer to steps 196-197-200: `node src/scripts/check_assistant_http.js` →
     `PASS 173/173`, 0 skipped, ~2m40s.** Steps 196, 197 and 200 above are the by-hand version of this; this
     script is the same surface driven end to end, so the gap those three used to leave is closed by running
     one command. It needs a listening API — it attaches to an already-running `npm start` if it finds one
     on `/api/health` and **spawns `src/server.js` itself if it does not**, printing which it did — plus
     ml-service up for model #4. It logs in as three real users (a player, a stranger, an owner with a
     ground), signs **real JWTs with the real secret**, and deletes its residue in a `finally`. What the 173
     cover, in run order:
     ```
          0  preflight — the server, the model, and a cast to act with                       5
          A  the door — four bad headers, then all sixteen endpoints with none at all        11
          A2 the anonymous quota — SEC-6, over the wire                                      3
          B  a turn through Express — the envelope, the cards, the parse                    11
          B2 the milestone utterances — Roman Urdu in, real data out                        10
          C  the request body — four spellings, one omission, a chip, a cursor               9
          C2 the transcript cursor — verbatim, or it silently drops a message               10
          D  new chat → rename → archive → restore → thumbs → delete                        13
          D2 feedback — changeable, not stuffable, and never on a stranger message           8
          E  a stranger chat — 404 and nothing else                                          9
          F  a 501-character message, and the 500-character boundary                         9
          F2 the role gate — the owner half is not a player URL                              1
          H  the capability list — one source for help sheet and abstain menu                8
          I  escalate → the owner answers → the next ask is free (source: kb)                8
          I2 the answer — one transaction, delivered into the asker's own chat              12
          I3 the payoff — the same question, answered free, owner not disturbed             11
          I4 KB upkeep, a decline that teaches nothing, policy that never escalates          9
          J  the confirm gate — a confident model affirm may not spend PKR                  18
          G  the 51st chat — a named 409, not a silent 50-chat ceiling                       4
          K  residue — what a live run leaves in the database                                2
          L  after the delete — the telemetry the FK was written to keep                     2
                                                                             PASS 173/173
     ```
     Three of those are worth watching go by rather than trusting: **A2** spends the anonymous quota on
     purpose, then **sleeps 62s** for the window to reset (that sleep is most of the runtime — do not read a
     long pause as a hang), and it asserts `RateLimit-Policy: 20;w=60` and `Retry-After: 60`, the two headers
     a client would otherwise have to guess. **J** re-proves the money gate over the wire, not in-process:
     `haan lekin 7 baje` parsed `affirm` at **0.5898 via `model`** — *above* the 0.45 threshold — with a
     booking armed, and the census either side of that turn is bookings 27→27, balance 8300.00→8300.00.
     **L** is the only claim that can be made *after* the delete: the thread is deleted through the API and
     all **19/19** of its `assistant_turns` rows survive with `channel_id` nulled — migration 018's
     `ON DELETE SET NULL`, i.e. a user clearing their history does not erase the corpus the next model
     trains on. If A or A2 fails with 429 where you expected 401, read step 196 again: the logins above them
     can spend the quota first, and that ordering bug was found by this script failing.
202. **`npm run evidence` — both gates, and a document you can hand over.**
     `node src/scripts/check_assistant.js --evidence && node src/scripts/check_assistant_http.js --evidence`
     (≈**5m20s** together) regenerates `doc/scout_evidence.md`: every assertion in the order it was made,
     each block stamped with its own count, timestamp, node version, model version and the **short commit
     hash plus a count of uncommitted paths** — so a stale page is visible as a stale page. The two halves
     write into `<!-- scout-evidence:service -->` and `<!-- scout-evidence:http -->` markers and **upsert
     only their own block**, so either script can be run alone without blanking the other's evidence; the
     `&&` means a red service gate stops the HTTP one from overwriting a good block with a half-run. Current
     file: **326/326 + 173/173, 0 skipped, ≈750 lines**. This is the artefact to bring to the viva — not
     because it proves anything the two scripts do not, but because it proves it *with the timestamps and
     the commit hash attached*.

Steps 190-195, 198-199 and **201-202 all run green as written**, and 201 executes over real HTTP exactly
what 196, 197 and 200 describe by hand — so the gap this section used to name ("278 checks pass" vs "the
HTTP surface is proven") is closed: **326/326 in-process, 173/173 over Express, 85/85 unit, 60/60 on the
money extraction**. Steps 196, 197 and 200 are still worth doing by hand once before the viva, for the
different reason that a panel will ask you to click, not to run a script; nothing in them should surprise
you if 192 and 201 are green. The one thing no step here proves is the Flutter side: Wave D's screens were
built and verified in a separate session and **no step in this document covers them** — §4.21 records that
as an explicit gap rather than an assumption.

### 4.21 The S.6 milestone acceptance checklist, audited line by line (S.6 Wave E)

**Nothing in this section is new testing.** It is the map from the wave spec's own acceptance checklist to
the steps that already prove it, written because a panel will read the checklist and not 200 numbered steps.
Every line gets either a **step number and a count** or the word **gap** — there is no third category, and
in particular there is no "looks fine". Two lines came back with something other than a tick, and both are
written up here rather than quietly satisfied: one asked for an intent that **cannot exist in this data
model**, and one asked for 30 unit tests where the repo has 68.

#### The six acceptance lines

1. **"USE-6 flow: `kal shaam football islamabad` → venues → slot pick → confirm → real booking created
   (ledger correct)"** — **PROVEN, step 192 section I, 30 checks**, and it is the only section written to be
   read as a single sentence. One utterance in: the model answers `find_venue` at **0.8108** (via `model`,
   not a chip — asserted, because a chip would prove the buttons work and nothing about the NLU), the
   extractor fills `sport=football`, `date=`tomorrow-in-PKT, `time=18:00`, `area≈islamabad`; three football
   cards come back; "see times" opens the picker on **2026-08-30**; a slot pick proposes **F-11 Markaz
   Football Arena at 6:00 PM for PKR 2,000**; a chip `confirm` writes the row. The ledger half is asserted,
   not eyeballed: wallet **5660 → 3660**, frozen **+2000**, `balance + frozen` conserved across the turn, and
   **exactly one** `booking_payment` row at −2000 — then the whole transaction is rolled back, so the
   database after the run is byte-identical to before it (step 194). Over real HTTP the same utterance is
   step 201 **section B2** (10 checks), which is where to point if someone objects that section I calls
   services directly.
2. **"Roman Urdu date/time parsing works (`kal shaam` → tomorrow 18:00–21:00 PKT)"** — **PROVEN twice, and
   the two proofs are deliberately different.** In the ml-service: `training/test_nlu.py` → **68 passed, 0
   skipped** (step 184), which pins the window against a **frozen clock** — `entities.py:1280
   FIXED_NOW = datetime(2026, 8, 28, 15, 0, KARACHI)` — so the test cannot rot as the real date moves.
   `entities.py:577` maps `"shaam"` to the pair `("18:00", "21:00")` and `entities.py:133` sets
   `TZ_NAME = "Asia/Karachi"`; the slot receives the **window start**, 18:00, because a booking needs one
   time and not a range. In Node, section I asserts the *product* of that parse rather than the parse:
   `slots.date == ctx.tomorrow` where `ctx.tomorrow` is computed independently in PKT by the harness, and
   then — the assertion that actually matters — the **written booking row's `slot_date` equals the same
   day**. A UTC bug survives the first check and dies on the second, which is why both are there.
3. **"`my_elo`, `wallet_balance`, `my_bookings`, `cancel_booking`, `tournament_list` all answer with real
   data"** — **four of five PROVEN as written; the fifth does not exist and must not.** `my_elo` is not an
   intent in this app and adding one would be a bug, because **SportLynk rates teams, not players** (FR2.6):
   there is no player Elo column to read, so a `my_elo` action could only ever answer with something it made
   up. The label that carries the question is **`team_stats`**, and it is proven in step 192 section D with
   **16 checks**: `"hamari team ki rating kitni hai"` → `team_stats` at **0.8772**, the card cross-checked
   **field by field** against `teamStats.profileStats` (`matchesPlayed`, `wins`, `losses`, `elo`, `isRanked`,
   `displayElo` — Demo United, **1185**, 8W–3L–2D from 13 played), plus the two branches a demo will hit by
   accident: **below `ranked_min_matches`** the reply must show `display_elo === null` and say *unranked*, and
   it is asserted that the string **`1000` never appears** (FR2.6 forbids showing a provisional rating as if
   it were real), and **a player in no team** gets *"You are not in a team yet, so there is no rating to
   show."* rather than a zero. The other four: `wallet_balance` **0.7896**, `my_bookings` **0.9363**,
   `tournament_list` **0.8659** all in section D against live rows, and `cancel_booking` **0.6455** is not
   answered with a sentence at all — it runs the real refund path in **section B, 33 checks** (preview →
   confirm → wallet and ledger agree), re-proved against the escrow table on its own by step 195's
   `check_booking_service.js` → **60/60**. If a panel asks for "my Elo", the correct answer is to show
   `team_stats` and say why the player-level version is absent; a screenshot of it working would be a
   screenshot of invented data.
4. **"`order me a pizza` → graceful capability menu (no hallucinated answer)"** — **PROVEN, both surfaces.**
   The model reads it `out_of_scope` at **0.8790** and the reply is sourced **`menu`**, not `live` and not
   `model`: section D asserts *"a question outside SportLynk lands on the menu"* and, one line above it, the
   stricter claim that **every item on the menu is an action Scout can actually run** — a capability list is
   only graceful if it does not offer things that do not work. Over HTTP, step 201 records
   `POST /message "order me a pizza"` → **200, not a 400**: a decline is a successful turn, and answering it
   with an error code would be the same dead end the spec is trying to prevent. The weaker sibling worth
   knowing about is `"mausam kaisa hai aaj"` at **0.6985** → same menu: still correct, but 0.28 closer to the
   floor, which is where the abstain path (rather than the `out_of_scope` label) starts doing the work.
5. **"Intent test-set accuracy reported + confusion matrix saved; 30 NLU unit tests green"** — **PROVEN, and
   over-delivered on the unit half.** Accuracy is reported in `reports/intent_metrics.json` and read back in
   §4.19 steps 182–183; the matrices are `reports/intents_confusion.png` (exam, n=230, **acc 0.670**) and
   `reports/intents_confusion_val.png` (validation, n=538, **acc 0.809**), both saved as files rather than
   printed. The number to quote is the **exam** one, **0.6696** with 95% CI **[0.6087, 0.7261]**, because the
   exam is 230 rows the model never saw from a writer whose phrasings are not in the corpus — validation's
   0.8086 shares templates and flatters it. Grouped to the 8 intent groups the exam is **0.7652**, and at the
   0.45 floor the product-facing triple is coverage **0.787** / answered-accuracy **0.7735** / **41**
   confidently-wrong rows. On unit tests the checklist asked for **30** and the repo runs **68** (step 184),
   `0 skipped` asserted as part of the pass because a silently-skipped floor test reads identical to a floor
   that was never applied. Node's own suite is separate and is **85/85** (step 191, database down).
6. **"Whole demo runs with `ASSISTANT_LLM=off` · `flutter analyze` 0 · `tag s6-done`"** — **one satisfied by
   construction, one verified elsewhere, one still open.**
   - **`ASSISTANT_LLM=off`: satisfied, and more strongly than the flag would.** There is no `ASSISTANT_LLM`
     flag, because the LLM phrasing layer of Wave E part 1 was **not built** — the decision record is in
     PROGRESS.md under S6-E. Every sentence Scout says comes from `utils/assistantReply.js` and
     `utils/policyText.js`, so "the demo runs with the LLM off" is not a configuration to check but a
     property of the tree: `grep -ri "gemini\|openai\|anthropic" backend/src` returns nothing. This is the
     stronger claim of the two — a flag can be flipped by accident, an absent dependency cannot.
   - **`flutter analyze` 0: verified, but not by any step in this document.** Wave D built the Flutter Scout
     screens in a **separate session** and reported analyze-clean there. Nothing in §4.19–4.21 touches Dart,
     and this section will not launder that result into a receipt it did not earn — re-run
     `flutter analyze` in `frontend/` before the viva and treat *that* as the evidence.
   - **`tag s6-done`: OPEN, and deliberately not done here.** Tagging is a claim that the wave is finished
     and committed; S.3–S.6 are still uncommitted in this tree (the evidence block's provenance line says
     so, in the count of uncommitted paths). Tag after the commit, not before — see the open list at the end
     of this section.
#### The five pitfalls, audited not acknowledged

Each pitfall is written here as **the bug it would have been**, then **the thing that would have caught it**.
A pitfall that is only quoted back has not been audited.

1. **"Never let the assistant bypass booking validations — extract a shared `bookingService.createBooking()`
   and use it in both routes."** *The bug:* Scout grows its own insert, and six months later a validation
   added to `POST /api/bookings` — a double-book guard, a minimum-notice rule, a wallet check — silently
   does not apply to anything booked by chat. *The catch:* `bookingService.js` was extracted first and
   **step 198's grep is the invariant** — `INSERT INTO bookings` has **exactly one** hit in all of `src/`
   outside `/scripts/`, and `src/services/assistant*`, `dialogManager.js` and `routes/assistant.js` contain
   **no** money primitive (`applyWallet(`, `logTxn(`, `penaltySplit(`, `lockWallet(`, `UPDATE slots SET
   status`). That grep is not documentation: step 192 **section H (40 checks)** re-runs it across all 50
   files of `src/` and **fails the run** if either answer changes, so the day someone adds a second insert
   the gate goes red rather than the rule going stale. Step 195 (**60/60**) then tests the extracted service
   on its own against the escrow table, which is the half a shared-service refactor usually leaves untested.
2. **"Store session state server-side; client sends only `session_id` + `text`."** *The bug:* slots ride in
   the request body, and a replayed or edited payload confirms a booking the user never saw. *The catch:* the
   documented body is exactly `{text?, action?, args?, session_id?, client_id?}` (`routes/assistant.js:83`)
   and **there is no slot field to send** — state lives in `chat_channels.session_state jsonb` (migration
   018), one thread = one state machine. Step 201 **section C (9 checks)** attacks the contract from the
   client side: four accepted spellings of the id (`session_id` · `sessionId` · `threadId` · `thread_id`),
   the omission case, a chip post and a cursor. The positive proof is two turns composing: the
   See-times chip posts `{action: "check_availability", args: {venueId}}` — **a venue id and nothing else**,
   no date, no time, no sport — and section I then asserts the slot picker comes back for **`ctx.tomorrow`,
   not for today**. There is nowhere that date could have come from except the server's session state.
3. **"Confidence threshold too high = everything falls back; too low = wrong actions — tune on the test
   file."** *The bug:* 0.45 chosen because it looked round. *The catch:* it was chosen from
   `threshold_sweep_validation` and both costs are quantified in the artifact rather than argued — too high
   is the **refusal** column (at 0.45, **22 validation rows and 14 exam rows** the argmax got right are
   refused; step 183 shows the arithmetic), too low is the **confidently-wrong** column (**53** on
   validation out of 103 argmax errors, **41** on the exam). And the tuning was done on **validation**, never
   on the exam: `exam_scores` is read once, at release, which is what keeps the CI honest. The product-side
   consequence is that raw accuracy is the wrong headline — coverage **0.787** and answered-accuracy
   **0.7735** are what a user experiences, and §4.19 says so in the "what this half cannot tell you" note.
4. **"Timezone: resolve `kal` in `Asia/Karachi`, not UTC (classic bug)."** *The bug:* at 20:00 PKT the server
   is already on tomorrow in UTC, so `kal` books the day after tomorrow — and it only misfires in the
   evening, which is exactly when a demo happens. *The catch:* `entities.py:133 TZ_NAME = "Asia/Karachi"` is
   the only clock the extractor has, `test_nlu.py` pins the arithmetic against a **frozen** PKT now
   (`FIXED_NOW`, so the test is date-proof), and section I asserts the day **twice** — once on
   `slots.date` against a PKT tomorrow the Node harness computes for itself, and once on the **written
   row's `slot_date`**. A UTC-vs-PKT slip that survived the parse would still have to survive an
   independently computed date and a database read.
5. **"Scope discipline: 15 intents done well beats 30 half-working."** *The honest audit:* **this one was not
   followed as written** — the label set went from 15 to **23**. What was kept is the intent behind it, and
   it is worth stating plainly rather than claiming compliance. Every added label had to earn its place
   over HTTP before the wave closed: step 187 requires each of the 8 new ones to **win by ≥0.35 over its
   runner-up** (measured +0.80 to +0.93), and `test_nlu.py` pins the same eight so a future retrain cannot
   quietly kill one. Nothing was half-wired: all 23 are model-reachable and the 27-action registry is
   enumerated in step 201 **section H**, which asserts every menu item maps to an action that runs. And the
   weak rows are published rather than hidden — `wallet_balance` **2/10** and `my_bookings` **3/10** on the
   exam are in step 182, in the model card, and in the confusion PNG. The committee-breaks-it scenario the
   pitfall is really about (two or three questions, not thirty) is the 12-utterance probe below.

#### The one limitation this audit found, recorded rather than fixed

`"kal shaam cricket lahore"` — the milestone utterance with the sport and the city swapped — **misreads**.
Re-measured today against the released artifact, the 12-utterance probe is **11/12**:

```
find_venue       0.8108   [Islamabad]   "kal shaam football islamabad"   <- the milestone line
find_players     0.4764   [no city]     "kal shaam cricket lahore"       <- the miss
out_of_scope     0.8790                 "order me a pizza"
out_of_scope     0.6985                 "mausam kaisa hai aaj"
wallet_balance   0.7896                 "wallet mein kitna hai"
my_bookings      0.9363                 "meri bookings dikhao"
cancel_booking   0.6455                 "booking cancel karni hai"
tournament_list  0.8659                 "tournament kaunse chal rahe hain"
team_stats       0.8772                 "hamari team ki rating kitni hai"
refund_policy    0.9235                 "refund policy kya hai"
app_help         0.7592                 "app kaise use karun"
affirm           0.5898                 "haan lekin 7 baje"
```

Two separate things go wrong and they should not be blamed on each other. **The intent is wrong** —
`find_players` instead of `find_venue` — and it is wrong at **0.4764**, which clears the 0.45 floor by 0.026,
so the abstain menu does **not** catch it: this is a textbook member of the 41 confidently-wrong rows step 183
counts, seen in the wild. **And no city is extracted at all**, which is not a model fault: the extractor is
**rules, not a model**, and `entities.py:889 CITY_ALIASES` covers **only the twin cities** — `islamabad, isb,
isl, isd, capital, rawalpindi, pindi, rwp, rpi`. The string `lahore` appears nowhere in `entities.py` or
`intent_spec.py`. So this is a **frozen-vocabulary, out-of-coverage-city case**, not a bug: SportLynk's venue
data is Islamabad/Rawalpindi, the corpus was authored for those cities, and a city the app has no grounds in
is out of coverage by design. It is written down here because the honest failure mode matters — asked about a
city we do not serve, Scout does not say "no grounds in Lahore", it confidently answers a different question.
The fix is a corpus and alias change (add the city, re-author the rows, retrain, re-run the exam), **not** a
rule bolted on in Node, and it is out of scope for S.6. If a panel tries a third city, this is the answer to
give them — with the probe above on screen.

#### What this audit leaves open

Everything below is a **manual step**, not a missing test. None of it is blocked on code.

| # | Open item | Why it is not done here |
|---|---|---|
| 1 | `flutter analyze` in `frontend/` → expect 0 | Wave D ran in a separate session; no step in this document touches Dart, and its result is not re-verified here (acceptance line 6). |
| 2 | Steps 196 · 197 · 200 clicked by hand once | Step 201 proves the same surface **173/173** over real HTTP; the by-hand pass is for the different purpose of rehearsing what a panel will click. |
| 3 | Commit S.3–S.6, then `git tag s6-done` | The tag asserts the wave is committed. Commit **`ml-service/models/intent_20260828-2315.joblib` alongside `intent_latest.joblib`** (the pointer alone loses provenance), and delete the scratch files first: `doc/WAVE_C_PLAN.md` and the eight `backend/_*.txt`. |
| 4 | §4.13 two-device E2E, §4.16 steps 157–158 (S.5 in-app), blind second-annotator κ, judge `reports/demand_patterns.png`, tags `s3-done` / `s5-done` | Carried over from earlier waves, unchanged by S.6. The κ figure in particular **must not be quoted as-is**: the second annotator was not blind. |
| 5 | **Rotate `ML_API_KEY`** in both `backend/.env` and `ml-service/.env` | Required before S.7 puts ml-service on a public URL. Compare the two by `/health`'s `apiKeyFingerprint` (sha256[:8]) — never print or commit the key itself. |

And two things this section deliberately does **not** claim. It does not claim the assistant is accurate:
**0.6696 on the exam means roughly one utterance in three is misread at the argmax**, and the product is
usable anyway because the 0.45 floor converts most of those into a menu instead of a wrong action — that
trade is the design, and coverage/answered-accuracy/confident-errors is the triple to argue about. And it
does not claim the money path is safe because Scout is accurate; the money path is safe because
**`decisive = via === 'chip' || via === 'lexicon'`** means the model is **never** one of the two doors that
can spend PKR (step 192 section C/C2, step 201 section J, where a `model` affirm at 0.5898 — above threshold,
with a booking armed — moved bookings 27→27 and the balance 8300.00→8300.00).

### 4.22 Tournaments — the owner's cup, the waterfall and the automated bracket (S.7 Wave A)

**Read this paragraph before running anything. It has been rewritten — the section it introduces was
written while migration 019 was still unapplied, and 019 was applied on 2026-08-30.** The scripted steps are
now observed rather than expected: 205 (019 applied, `verify_schema.js` → **174/174**), 207
(`check_tournaments.js` → **PASS 441/441**, 1 skipped), 208 (the evidence pack regenerated over the
**FAIL 2/3** stub), 209 and 210. What is still **NOT RUN** is every step a human has to perform by hand:
211's `--verify` podium (the demo cup exists on Supabase, but nobody has played it out), 212's HTTP security
probes, and 214's screen-by-screen Flutter pass. The original FAIL 2/3 is still *described* in step 208
rather than deleted, because how a gate behaves when it is fired too early is worth keeping.

The history is worth one sentence, because it is the reason this sprint changed its own rules: Wave A shipped
on `npm test` plus `flutter analyze` **with its schema unapplied**, and the consequence was that nothing in
the module answered when it was first tried by hand. Every wave after it — §4.23 through §4.25 — is gated on
the migration landing **first**. All Node commands run from `D:\sportlynk\backend`.

What the section proves, in the order a panel would ask for it: the money is arithmetic and not a promise
(the waterfall, to the paisa), the bracket is generated rather than typed, a fixture *reserves* venue hours
rather than booking them, a result moves ratings **harder** for a final than for a friendly, and every rupee
that goes in comes out.

203. **The unit suite, with the database DOWN — `npm test` → 128/128.** ✅ **observed.**
     42 of those are new: `test/fixtures.test.js` (22) and `test/fixtureSchedule.test.js` (20). Running them
     with Postgres off is the whole point — seeding, bracket shape, byes, round-robin scheduling, standings
     with tie-breaks, `kFactorFor`, `winProbability` and **`splitPool` (the entire economic waterfall)** are
     pure functions in `src/utils/fixtures.js` and `src/utils/fixtureSchedule.js`. A money split that needs a
     database to be checked is a money split nobody checks.
     ```
     cd backend && npm test
     # ✔ 128 pass  0 fail   (elo · assistant · fixtures · fixtureSchedule)
     ```
204. **`flutter analyze` → "No issues found!"** ✅ **observed**, whole project, after the last Dart change.
     Wave A's Flutter surface is `models/tournament.dart`, `services/tournament_service.dart`,
     `widgets/tournament_widgets.dart`, `screens/player/tournaments_screen.dart` (the hardcoded
     "Ramadan Futsal Cup" mock is **gone**), `screens/player/tournament_detail_screen.dart`,
     `screens/owner/owner_create_tournament_screen.dart`, `screens/owner/owner_tournaments_screen.dart`,
     the three new types in `widgets/transaction_detail_sheet.dart`, and the `MatchTournament` façade on
     `models/match.dart` that stopped four match screens printing "Booking unavailable" over a tournament
     fixture that had a perfectly good venue and time.
205. **Apply migration 019 — 38 columns, 16 constraints, 7 indexes, 3 enum values, 1 settings row.**
     ✅ **APPLIED to Supabase, 2026-08-30** — the decision that unblocked the rest of this section.
     `node run_migration_019.js`. It is idempotent (`ADD COLUMN IF NOT EXISTS`, guarded
     `DO $$` blocks for every constraint, `CREATE INDEX IF NOT EXISTS`) and creates **no new table** — 013
     already made `tournaments`, `tournament_teams` and `fixtures` as bare shells that nothing ever read.
     The three `ALTER TYPE txn_type ADD VALUE` statements are split out on `-- @@SPLIT@@` because an enum
     add cannot share a transaction with the statements that use the new value.
     Then the census: `node src/scripts/verify_schema.js`, whose 019 block asserts the 38 new columns, the
     7 new indexes and the **16 named constraints** by name — so the whole file should go from
     `113/113` to **`174/174`** — which is exactly what it reported. (It reads **233/233** today; migration
     020 in §4.24 added its own census.) Any number in between names exactly which object the runner missed.
     The two highest-signal constraints to eyeball:
     ```sql
     -- the power-of-2 rule a knockout bracket cannot exist without
     SELECT conname FROM pg_constraint WHERE conname = 'chk_tournaments_max_teams';
     -- "a match belongs to a booking or a tournament, never both"
     SELECT conname FROM pg_constraint WHERE conname = 'chk_matches_one_context';
     -- and the three new enum values
     SELECT unnest(enum_range(NULL::txn_type));
     ```
     **Check the host before trusting the ticks** — see the caveat in `DATABASE.md`; 013's runner was twice
     reported as "applied to Supabase" while `DATABASE_URL` still pointed at localhost.
206. **A note on what 019 makes load-bearing.** `src/utils/teamAccess.js`'s `TEAM_COLUMNS` now selects the
     four counters (`tournament_played`, `tournament_wins`, `finals_reached`, `titles`), so
     `routes/teams.js` (4 call sites) and `discoveryService` are 019-dependent too. Before 205, a team read
     failed on the missing column — which is what "nothing was working" looked like from the outside, and it
     is why 205 is numbered before every step that follows rather than filed as a chore at the end.
207. **THE GATE: `node src/scripts/check_tournaments.js` → `PASS 441/441`, exit 0, rolled back.**
     ✅ **observed** (`doc/tournament_evidence.md`, 2026-08-30 01:26 PKT), 1 skipped. It had been fired once at
     Supabase *before* 019 was applied and died on the first missing column at **2/3** — the correct behaviour,
     and the reason 205 is numbered before it. After 205 the same command with no changes to it returned
     441 assertions green. One `BEGIN … ROLLBACK`, real money through the real service — no
     HTTP, no mocks — then it proves the rollback by re-reading outside the transaction. Ten blocks:
     ```
     Block 1  configuration refusals (FE-1)          non-power-of-2 knockout, round robin over the cap,
                                                     a venue the caller does not own, bad percentages
     Block 2  the economics quote (FE-1)             venue cost from REAL slots.price, the recommended
                                                     entry fee, and the same waterfall the draw will run
     Block 3  entry fees, refusals, refunds          insufficient balance · wrong sport · double register ·
              (FE-3/4/5)                             capacity full · deadline passed · someone else's team
                                                     (403) · withdraw → refunded in full · organiser
                                                     rejects → refunded in full
     Block 4  under the minimum field (FE-4)         3 teams at the deadline → cancelled, every entry back
     Block 5  the draw, the reservation, the          8-team bracket shape, seeds 1 v 8, slots flipped to
              waterfall (FE-6)                       'blocked' and NOT booked, pool = venue_cost + prize
                                                     + margin to the paisa, owner_earning >= venue_cost
     Block 6  results, K by stake, advancement,      a win, a draw, a rout, a walkover; K = 40 / 48 / 56
              the podium (FE-7)                      by round and K = 0 for the walkover; the winner lands
                                                     in the next round's TBD; champion AND runner-up paid
     Block 7  a five-team field                      padding to 8, byes to the TOP seeds, resolved at once
     Block 8  round robin                            circle method, 3/1/0, goal difference, head-to-head,
                                                     a champion read off the table
     Block 9  the match-flow door                    the S.2 captains' path: a match row with
                                                     booking_id NULL, authority from tournaments.owner_id,
                                                     one ELO exchange, advanceAfterMatch idempotent
     Block 10 the closing ledger audit               every wallet, every transaction: the money sums to zero
     The rollback                                    not one row this run wrote still exists
     ```
     A `SKIP` is printed **beside** the pass count and never inside it — a case the seeded data could not
     supply is a case that did not run. `--verify-clean` re-checks that nothing was left behind;
     `--evidence` regenerates `doc/tournament_evidence.md`.
     If the run stops on "no venue qualifies": the economics are denominated in `slots.price`, so it needs a
     real, priced, owned venue with enough genuinely free hours for a 7-fixture bracket spread over several
     days. Run `node src/scripts/add_future_slots.js --days 10` and try again — the script refuses to invent
     inventory rather than quietly test against fake prices.
208. **`doc/tournament_evidence.md` is a GENERATED file. It was a FAILED run; it has been regenerated.**
     ✅ **now `PASS 441/441`**, produced 2026-08-30 01:26 PKT. The paragraph below describes the stub it
     replaced, and is kept because the failure is instructive: it is what a gate fired at the wrong schema
     looks like, and it is the shape of the mistake this whole sprint was re-sequenced to prevent. `node src/scripts/check_tournaments.js --evidence` writes it:
     every assertion in the order it was made, stamped with timestamp, node version and the short commit
     hash plus a count of uncommitted paths, so a stale page is visible as a stale page. The file on disk
     was produced **2026-08-29 22:35 PKT** against a database that does **not** have 019, and it says so
     itself: `**FAIL 2/3**`, and the only assertions it managed to record are the two rollback lines —
     *"after ROLLBACK not one captain this run created still exists"* and *"and not one tournament"*. So the
     one thing that page currently proves is that the harness connects, opens a transaction and **cleans up
     after itself when it dies mid-way**, which is worth knowing and is not the module working. Treat it as
     a stub: it had to be regenerated after 205, and until it read `PASS n/n` it could not be cited as
     evidence of anything except its own rollback. It now reads `PASS 441/441` and can be.
209. **No regression in S.2 or S.6 — the two suites Wave A reached into.**
     ✅ **observed** after 205, and again in the S.7 sweep at §4.26 step 239 (`check_assistant.js` now
     **342/342**). Wave A edited `routes/matches.js` (tournament authority when
     `booking_id IS NULL`, plus the `advanceAfterMatch` call inside the existing verify transaction) and
     `utils/matchCore.js` (COALESCE the fixture's slot and the cup name into the match view). Both are
     surgical, and both are exactly the kind of edit that breaks something else:
     ```
     node run_match_flow_check.js                   # S.2 — the match lifecycle end to end
     node src/scripts/check_assistant.js            # S.6 — 326/326 + conversation J's tournament chips
     ```
     `check_assistant.js` matters here for a second reason: Wave A added three **chip-only** Scout actions
     (`tournament_detail`, `tournament_register`, `my_tournaments`) with **no new trained labels**, so
     model #4's 23 labels and its fingerprint must come back **byte-identical**. If that script's preflight
     reports a different fingerprint, the cause is ml-service serving another artifact (§4.19 step 185), not
     this wave.
210. **The scheduler's provenance, proved by an A/B rather than asserted.**
     ✅ **the model half is observed** inside step 207 with ml-service up — the evidence pack's header records
     `scheduler | model · pricing-v1-20260825-0041 · scored 75/75 candidate hours`, and its Block 5 asserts that
     the demand model's version is stamped on the schedule and that **the final takes a busier hour than round
     1**. ⛔ The explicit side-by-side against `--no-model` was **not** run as a separate A/B, so the
     `'chronological'` fallback is asserted by the unit tests and by its own code path, not by a paired run. Trained model #1 (demand) places early
     rounds in the venue's **lowest**-P(booked) hours and the final in the **highest** one. That is not
     cosmetic: `venue_cost` is the sum of the chosen slots' real prices, so off-peak placement lowers the
     entry fee teams pay *and* protects the owner's sellable peak inventory.
     ```
     # ml-service up (uvicorn, /health 4/4):
     POST /api/tournaments/:id/generate            {}                  → meta.scheduling.source = 'model'
     # ml-service stopped, or forced:
     POST /api/tournaments/:id/generate            {"useModel": false} → meta.scheduling.source = 'chronological'
     ```
     Both must **succeed**. A scheduler that fails when the model is down would make a trained model a
     single point of failure for a cup eight teams have already paid into; `meta.scheduling.reason` carries
     why the fallback ran. Compare `venue_cost_amount` between the two runs on the same field — the model
     path should be the cheaper one, and if it is not, say so rather than claiming the feature works.
211. **The acceptance run — the one to demo.** ⚠️ **PARTLY RUN.** The demo cup is on Supabase right now:
     `SportLynk Invitational (demo)`, seeded 2026-08-30 01:32 PKT, status **active**, with its **7 fixtures
     drawn** — so steps 1–2 below and the job's automatic draw are observed. Nobody has played it out, so
     `--verify` (bracket → standings → money → audit → podium) is **still to be done**, and it is the single
     most demo-worthy command in the project. `node seed_tournament_demo.js --undo` removes the cup and its
     eight seeded captains when you want the shared database clean again.
     ```
     # 1. start the server with a fast sweep, or the 5-minute default means 5 minutes of staring
     $env:SL_TEST_SWEEP_SECONDS=20 ; npm run dev      # look for "[TournamentJob] Started — sweeps every 20s"
     # 2. eight funded captains, eight teams on descending ELO, a 2-minute deadline
     node seed_tournament_demo.js
     # 3. watch the job draw the bracket by itself. Then:
     node seed_tournament_demo.js --verify            # bracket, standings, money, audit
     ```
     It **commits** (it is a demo seed, not a check) and is idempotent — captains keyed on an email prefix,
     teams on a marker in `teams.bio`, the cup on its name. `--generate` skips the wait by drawing through
     the organiser's endpoint path; `--play` settles every unplayed fixture; `--fee=` and `--deadline=`
     override the quote and the clock; **`--undo` removes exactly what it created.** The entry fee is
     **quoted by `POST /api/tournaments/preview`**, not picked out of the air, which is the point: the
     economics screen is what stops an owner setting a fee that loses them money.
     The deadline is moved to two minutes out **after** the eight registrations, because `register` correctly
     refuses once the deadline has passed and a two-minute deadline set at creation would race the last
     captains into `deadline_passed`.
     What to show a panel, in this order: the capacity bar filling → the job's log line drawing the bracket →
     the bracket screen with seeds 1 v 8 and the Elo odds per tie → one result entered through the **owner's**
     verify flow → the winner appearing in the next round's TBD → the final → the champion and runner-up
     credited → and the owner's earning printed next to what the same slots would have fetched if sold.
212. **The security cases, all with a token in hand.** ⛔ **NOT RUN over HTTP** — no longer blocked, just not
     done; every one of them is already asserted in-process by step 207 (which is green), doing them over HTTP once is worth it because a panel will
     ask "what stops a player doing this?", and the answer is a status code.

     | # | Attempt | Expect |
     |---|---|---|
     | 1 | No `Authorization` header on any `/api/tournaments` route | **401** — `router.use(auth)` is the first line |
     | 2 | **Player** token → `POST /api/tournaments` | **403** — `checkRole('owner')`; only venue owners run cups |
     | 3 | **Owner A** posts a tournament at **owner B's** venue | **403** `not_your_venue` — read from `venues.owner_id` in SQL, never from the body |
     | 4 | Captain of team X registers **team Y** (`{"teamId": Y}`) | **403** `not_captain` — `teams.captain_id` is re-read inside the locked transaction |
     | 5 | Register the same team twice, twice at once | **409** `already_registered` — counted under `FOR UPDATE`, so two simultaneous POSTs cannot both win |
     | 6 | Register a 9th team into an 8-team cup | **409** `full` — the count includes `registered` **and** `accepted`, so an approval-gated cup with 8 pending teams is full, not empty |
     | 7 | Register with `balance` < entry fee | **409** `insufficient_funds` — on the locked wallet row |
     | 8 | Register after the deadline | **409** `deadline_passed` — FE-4 enforced on read, not only by the job |
     | 9 | A **non-organiser owner** calls `/generate`, `/cancel`, `/teams/:id`, `/fixtures/:fid/result` | **403** `not_organiser` — `tournaments.owner_id`, same transaction as the write |
     | 10 | `/generate` twice | **409** `already_generated`; `uq_fixtures_slot` is the backstop if the latch is ever raced |
     | 11 | `PATCH /api/owner/slots/:id/unblock` on an hour a live fixture stands on | **409** `fixture_reserved` — the ground cannot be freed from under a fixture |
     | 12 | Withdraw after the bracket is drawn | **409** `too_late` — the fee is in the pool and a slot is reserved |
     | 13 | Ask Scout to register a team by **typing** it | the money door stays **chip + confirm only** (`decisive = via === 'chip' \|\| via === 'lexicon'`), unchanged from S.6 |
     | 14 | Read `GET /api/tournaments/:id` as a stranger | **200** — a tournament page is public reading (FE-8); `organiser` comes back `null`, and withdrawn/rejected entries are not listed |
213. **The economics assertions, spelled out, because this is the argument the wave rests on.**
     ✅ **observed** — all four are asserted by step 207, which is green at `PASS 441/441`.
     - `pool_amount = venue_cost_amount + prize_amount + margin`, **to the paisa**, where
       `margin = owner_earning_amount − venue_cost_amount`.
     - `owner_earning_amount >= venue_cost_amount` — **never underwater.** If the pool cannot cover the venue
       hours, prize = 0 and the owner takes the whole pool; money is never taken *from* the owner.
     - `winner_share + runnerup_share = prize_amount`, and both land in the **captains'** wallets while the
       hold came out of the organiser's **frozen** balance.
     - `k_factor` in `elo_history` is **56** for the final, **48** for a semi, **40** earlier, and there is
       **no `elo_history` row at all** for a bye or a walkover.
     Worked example to sanity-check the numbers against (PKR 4,000 entry, 8 teams, 7 hours @ 2,000):
     pool 32,000 − venue 14,000 = 18,000 surplus → prize 10,800 (winner 7,560 · runner-up 3,240), owner
     14,000 + 7,200 = **21,200, against 14,000 for selling the same slots**. Print both figures from real
     rows in step 211 rather than quoting this paragraph.
214. **The Flutter pass, by hand.** ⛔ **NOT RUN** — no longer blocked; the API answers now, so this is a
     sitting-down-with-the-app job.
     `flutter run`, then: browse (filter by sport and city, watch the countdown and the capacity bar) →
     open a cup → register a team from the sheet, which shows **per-player cost and the prize on the table**
     before the fee is confirmed → the bracket tab scrolls horizontally with TBD placeholders and the Elo
     odds per tie → the standings tab for a round-robin cup → as the **owner**: the create screen's live
     economics preview ("you earn X vs Y for selling these slots", and the recommended entry fee), then
     approve · remove · enter a result. Check the wallet screens too: the three new transaction types must
     read "Tournament Entry" (held, not spent), "Tournament Earnings" and "Prize Money" — and a tournament
     match in Match Center must show a **venue and a time**, plus a tappable stage line ("Ramadan Cup ·
     Semi-final") that opens the bracket.

#### What this section leaves open

| # | Open item | Why it is not done here |
|---|---|---|
| 1 | ~~Apply migration 019 (step 205)~~ | **Done, 2026-08-30.** Kept in the table because it is the item that unblocked everything else, and because the row above it in every other wave now reads "migration first". |
| 2 | ~~Steps 207–210 run green~~ | **Done** — 207 at `PASS 441/441`, 208 regenerated, 209 and 210 as noted. What is still open is 211's podium, 212 over HTTP and 214 by hand: three human passes, no longer three blocked ones. |
| 3 | ~~`doc/tournament_evidence.md`~~ | **Regenerated** at 2026-08-30 01:26 PKT and now reads `PASS 441/441` · 1 skipped. The FAIL 2/3 stub it replaced is described in step 208 rather than forgotten. |
| 4 | The explicit `--no-model` A/B (step 210) | The model half ran with ml-service up and is in the evidence pack. The paired run against `--no-model`, which is what would *demonstrate* the fallback rather than assert it, was never done. |
| 4b | The demo cup is **sitting in Supabase** | `SportLynk Invitational (demo)`, active, 7 fixtures, seeded 2026-08-30 01:32 PKT. It is real data in a shared database. `node seed_tournament_demo.js --undo` removes it and its eight seeded captains. |
| 5 | Round-robin at scale | `n(n−1)/2` means 8 teams = 28 fixtures ≈ 28 venue hours, four times a knockout's cost. `max_round_robin_teams` is capped at **6** (15 fixtures) in the create validation and the preview endpoint surfaces the cost immediately — but no step here has played a 6-team league end to end. |
| 6 | **Rotate `ML_API_KEY`** in both `backend/.env` and `ml-service/.env` | Carried over from §4.21 and now urgent: S.7 is the sprint that puts ml-service on a public URL. Compare the two by `/health`'s `apiKeyFingerprint` (sha256[:8]) — never print or commit the key. |

**What this section can and cannot claim, restated now that 019 is applied.** It *can* claim that the escrow
moves, the bracket draws itself, K rises with the stage, the podium pays out and the ledger sums to zero — all
441 of those assertions ran against the real database and were rolled back, and the file that records them is
generated rather than typed. It *cannot* claim that a human has watched a cup play out end to end in the app:
the demo cup is drawn but unplayed, and the Flutter pass (step 214) has not been done. The distance between
those two sentences is exactly three commands, and they are steps 211, 212 and 214.

The original closing paragraph said the opposite — that nothing here had ever met a database and the one
attempt ended in `FAIL 2/3`. That was true when it was written and it is kept in step 208, because a project
that overwrites its own failed runs has no way to show that it learned anything from them. This one did: it is
why every wave after Wave A applies its migration first.

### 4.23 Chat — the two rooms nobody created, the inbox, and FR8.10 reply suggestions (S.7 Wave B)

**Read this paragraph before running anything.** Unlike §4.22, every number in this section **was observed**,
because migration 019 was applied first (see §4.22 step 205, now done) and the gate ran against the live
database. The one thing this section does *not* prove is two humans on two phones talking to each other; that
is the manual pass in step 221 and it is marked as such. All Node commands run from `D:\sportlynk\backend`.

What the wave actually was: the Socket.IO server, the JWT handshake, the flood limiter, presence, the
✓/✓✓/blue ticks and the whole team-chat REST surface were already shipped in S.2. `chat_channels`'
CHECK constraint has allowed `type IN ('team','booking','captain','assistant')` since 013 — and **nothing on
earth ever created a `booking` or a `captain` row**. So the test burden here is not "does chat work", it is
"do the two missing rooms get opened by every path that should open them, exactly once, and can a user find
them" — which is why Block 7 below is a *source-level* assertion over the six call sites rather than a happy
path through one of them.

215. **THE GATE: `node src/scripts/check_chat.js` → `PASS 120/120`, exit 0, rolled back.** ✅ **observed**
     (`doc/chat_evidence.md`, 2026-08-30 03:21 PKT). One `BEGIN … ROLLBACK`, real rows through the real
     `chatCore`/`chatList`/`quickReplies` functions — no HTTP, no mocks — then it re-reads outside the
     transaction to prove the cleanup. Seven blocks:
     ```
     cd backend && node src/scripts/check_chat.js --evidence
     ```
     | Block | What it establishes |
     |---|---|
     | 1 | A confirmed booking becomes a room: two members (player + venue owner), and the opening pill reads **"Booking confirmed — chat with the venue here"** |
     | 2 | Confirming **twice** does not open a second room — `ON CONFLICT (type, ref_id)` is the idempotency, not a `SELECT` first |
     | 3 | An accepted challenge opens the captains' room with captains **and** vice-captains, carrying **"Challenge accepted — coordinate here"** (FR8.5, verbatim) |
     | 4 | One shared room, **one neutral sentence per lifecycle event** (6 of them) — per-team wording in a shared room is a bug, not a nicety |
     | 5 | The inbox: 3 types for one person, ordered on the same expression the cursor pages on, a booking subtitle carrying live status + PKT slot time, unread = the hand-computed **7**, my own and deleted messages excluded, mute dropping a room out of the **badge** but not out of the **list**, two-page cursor with no repeat and no gap, and Scout invisible to both |
     | 6 | FR8.10: 3 role-aware replies, `source:'model'` off the frozen 23-label classifier, and the keyword table answering with `confidence 0` when ml-service is down |
     | 7 | Every confirm/cancel/no-show/accept path calls the opener, and all four emit **after COMMIT** |
216. **The unread count uses an index, proved by `EXPLAIN` rather than asserted.** ✅ **observed** — Block 5's
     last three assertions read `Index Scan using idx_chat_messages_channel`. This matters more than it looks:
     the inbox's unread column is a LATERAL `count(*)` **per row**, so a sequential scan there is not a slow
     query, it is a slow query multiplied by the number of rooms you are in.
     **The plan was wrong about this and the correction is recorded in `DATABASE.md`:** it called for a new
     `idx_chat_messages_channel_created`, and recon found `idx_chat_messages_channel` (013) is *already*
     `(channel_id, created_at DESC)`. A second index over the same two columns under a different name would
     have cost a write on every message sent, forever, to duplicate an index that already existed.
217. **`npm test` → 159/159** ✅ **observed**, with the database **down**. 31 of those are new
     (`test/chat.test.js`): the inbox row shaping, the per-type `context` sentence, the cursor round-trip, the
     mute clamp (floored at 1 hour, capped at 8760 = one year) and the quick-reply lexicon — all of it pure
     functions, so a chat list that needs Postgres to be checked is a chat list nobody checks.
     ```
     cd backend && npm test
     # 159 pass  0 fail   (elo · assistant · fixtures · fixtureSchedule · chat)
     ```
218. **`flutter analyze` → "No issues found!"** ✅ **observed**, whole project. Wave B's Dart:
     `screens/shared/chats_screen.dart` (the sectioned inbox), `screens/shared/chat_thread_screen.dart`
     (today's team-only `ChatScreen` generalised — `channelId` required, `teamId` optional, header and actions
     per type), the header rework on `player_home_screen.dart` and `owner_home_screen.dart`, and
     `services/chat_service.dart` + `constants/api_constants.dart` for the six new paths. `ChatController`
     needed **no change at all** — it was already generic over `channelId`, which is the payoff of the
     DB-backed room model.
219. **The entry points, by hand.** ⛔ **NOT RUN as a scripted step** — these are four taps and they are part
     of step 221: "Message venue" on `player_booking_detail_screen.dart`, "Message player" on
     `owner_booking_requests_screen.dart`, "Coordinate" on `match_center_screen.dart`, and the existing team
     chat button (unchanged). Each resolves its channel through `GET /api/chat/booking/:id` or
     `/match/:id` rather than constructing an id, so a room that does not exist yet returns 404 and the
     button can say so instead of opening an empty screen.
220. **Security cases for the new surface.** ✅ **observed** inside Block 5/6 rather than as separate HTTP
     probes: a non-member gets nothing from the inbox (it is a join over `chat_channel_members`, so
     membership *is* the filter — there is no room-id path that skips it), a `messageId` from a **different
     channel** is refused by quick-replies, suggesting a reply to your **own** message is refused, and Scout
     threads are excluded from both the list and the badge. The mute endpoint writes `muted_until` scoped to
     `(channel_id, user_id)`, so muting cannot mute anyone else.
221. **The two-account manual pass.** ⛔ **NOT RUN — needs two accounts and two devices.** Owner approves a
     booking → the player's inbox grows a Bookings row with the pill in it → both open it and talk, live,
     with ticks going grey → ✓ → blue → the owner taps an AI chip and it **fills the composer without
     sending**. Then accept a challenge from the other account and watch the Matches row appear by itself.
     Fixture ready for it: **E2E Falcons** (captain Usman Ali) vs **E2E Titans** (captain Hina Farooq), owner
     **Ahmed Khan** at F-11 Markaz Football Arena.

### 4.24 Notifications — the registry, the collapse, the feed and the push outbox (S.7 Wave C)

**Read this paragraph before running anything.** The starting state was not "notifications need push". It was
that `notifications` was a **write-only table**: ~33 call sites inserted into it and **nothing read it**, the
bell on `player_home_screen.dart` was a decorative `Icon` with no `onTap`, and there was no
`/api/notifications` route of any kind. So this section tests a feature that was built in this wave, not one
that was extended — and the first thing it tests is the registry, because an unregistered type renders as a
blank icon and a dead tap, which is precisely the class of silent breakage that made "nothing was working"
true.

Push ships **dormant** by design: `FIREBASE_SERVICE_ACCOUNT` is unset, so `pushService.isConfigured()` is
false and the boot banner says `FCM OFF`. Everything below except the tray banner itself is observed in that
state — which is the point of the outbox design, and is why step 229 can be done later with no code change.

222. **THE GATE: `node src/scripts/check_notifications.js` → `PASS 169/169`, exit 0, rolled back.**
     ✅ **observed** (`doc/notification_evidence.md`, 2026-08-30 22:28 PKT). Eleven blocks; the five that
     carry the wave:
     ```
     cd backend && node src/scripts/check_notifications.js --evidence
     ```
     | Block | What it establishes |
     |---|---|
     | 1 · the registry | Every one of the **45** types resolves to a category the CHECK allows, a priority, an icon and a route; **31 types scraped from live `notify()` call sites are all registered**; the 14 registered-but-not-yet-emitted are named in the evidence as Wave D call sites, *not* as defects; `system` is not mutable — a suspension cannot be opted out of |
     | 3 · the collapse | Three chat messages become **one row reading "3 new messages"** — `group_count` bumped by the `ON CONFLICT` upsert on `ux_notifications_group`, not three rows and not a lost update |
     | 4/5 · the feed | Paging on the opaque cursor, category filter, a hand-computed unread count, and **three distinct states — unread, read, dismissed — where dismissed is not deleted** |
     | 7 · quiet hours | A 22:00→07:00 window is quiet **across midnight** and loud again at 07:00, checked at 7 instants in `Asia/Karachi`; a zero-length window reads as **off**, not as always-quiet; an empty prefs object means everything **on**, so a category added later is never silently muted |
     | 8 · the outbox | A row is **claimed once** (`FOR UPDATE SKIP LOCKED`), stamped with `pushed_at` or a `push_error` reason, and **the in-app badge is emitted regardless** — prefs and quiet hours suppress the *push*, never the row |
223. **Every deep link resolves to a route that exists in `lib/main.dart`.** ✅ **observed** — Block 10 is a
     string-match assertion from the server's registry into the Dart route table: **45 types → 9 routes**, all
     9 present. This is the guard against the exact failure the user hit by hand ("the tap does nothing"), and
     it is the reason `deep_link` is computed server-side and stored on the row rather than inferred by the
     client from `type`.
224. **`created_at` is `timestamptz`, and Block 11 proves it on the live database.** ✅ **observed** — the 020
     census asserts the converted type along with all 25 added columns, both new tables and all 11 indexes.
     Migration 010 stored it as a bare `TIMESTAMP`; every "2 hours ago" in the app was wrong by the server's
     UTC offset until 020 converted it `USING created_at AT TIME ZONE 'UTC'`. A relative timestamp is the one
     thing in a notification feed a user *checks against their own memory*, so this was a correctness bug and
     not a schema tidy-up.
225. **`node src/scripts/verify_schema.js` → 233/233.** ✅ **observed** (was 174/174 after 019). The 020
     census adds the 59 objects above to the file's own count, so any number in between names exactly which
     object the runner missed rather than "the migration failed".
226. **The server boots clean, and the banner is the assertion.** ✅ **observed**:
     ```
     PORT=3111 node src/server.js
     # Notifications: 45 types → 9 routes
     # ✅ Database connected (TLS on)
     # 7 jobs running   (noShow · autoApprove · withdrawal · matchExpiry · sentimentBackfill · tournament · push)
     # FCM OFF (FIREBASE_SERVICE_ACCOUNT not set)
     ```
     `assertNotificationTypes()` runs **at boot** and names any unregistered type, so a type added to a
     `notify()` call without a registry entry fails the boot instead of shipping a blank row. **7 jobs** is
     the count to check after this wave — 6 before it.
227. **Prefs and quiet hours are enforced in the job, server-side, and that is tested as such.** ✅ Block 6/7.
     A toggle the client honours is not a preference, it is a suggestion — so the *only* code that reads
     `notification_prefs` is `pushJob`, and the tests drive the job rather than the screen. The corollary is
     also asserted: `inApp: false` never suppresses the row or the badge, because a user who muted email-style
     noise did not ask to lose their history.
228. **`flutter analyze` → "No issues found!"** ✅ **observed**. Wave C's Dart: `services/notification_service.dart`,
     `services/push_service.dart`, `providers/notification_provider.dart`,
     `screens/shared/notifications_screen.dart`, `screens/shared/notification_prefs_screen.dart`,
     `utils/deep_link.dart` (the single route map, with a **cold-start replay after auth resolves** so a tray
     tap on a killed app still lands), `widgets/in_app_banner.dart`, and the live bell + badge on the player,
     owner **and** admin home screens.
     **One deviation from the plan, deliberate:** `flutter_local_notifications` was **not** added. The
     foreground banner is `widgets/in_app_banner.dart` (an in-app overlay), and the tray channel
     `sportlynk_default` at `IMPORTANCE_HIGH` is created in ~20 lines of Kotlin in `MainActivity.kt`. That is
     one fewer plugin, one fewer Gradle surface, and it is the half of the plugin's job we actually needed.
229. **THE PUSH E2E.** ⛔ **NOT RUN — needs the Firebase key and a real Android device.** Firebase console →
     Project settings → Service accounts → Generate new private key, save it **outside git** (or a gitignored
     path), set `FIREBASE_SERVICE_ACCOUNT=<path>` in `backend/.env`, restart. Then: owner approves a booking on
     one phone → the *locked* player phone shows a tray banner within ~4 s → tapping it opens booking detail.
     An emulator cannot show a locked-screen banner convincingly for a demo, which is the only reason a real
     device is on this list. Until then `sent_push` stays false with `push_error` naming the reason, and
     **everything else in the feature works** — that is what the dormant design bought.

### 4.25 Admin — rulings, suspension, live settings and the financial export (S.7 Wave D)

**Read this paragraph before running anything.** The **web dashboard half of the wave prompt is deliberately
not built** — the user's call, quoted in the plan's scope guard. Everything here is the backend plus the
Flutter admin screens; every endpoint is dashboard-ready when that comes back. Two things in this section are
not what the plan said, and both are recorded as deviations rather than smoothed over: a ruling on an
already-rated match **corrects** it instead of refusing (step 232), and that required migration **022**.

The starting state: the dispute *raise* flow existed (`routes/matches.js:1104` and `:1438` insert into
`disputes`) and **nothing read or ruled on it**; `users.is_active` was checked at login only, so a suspended
user's existing token kept working; `global_settings` had an `invalidate()` hook and no endpoint to call it;
and `grep` for `text/csv` across the whole repo returned nothing.

230. **THE GATE: `node src/scripts/check_admin.js` → `PASS 275/275`, exit 0, rolled back.** ✅ **observed**
     (`doc/admin_evidence.md`, 2026-08-31 01:55 PKT). Eleven blocks. Block 8 is the exception to the rollback
     rule and says so in its own title — it **commits**, because the thing under test is whether a *previously
     issued* JWT is rejected on its next request, and a token check that reads uncommitted data proves nothing;
     it deletes its own rows afterwards.
     ```
     cd backend && node src/scripts/check_admin.js --evidence
     ```
     | Block | What it establishes |
     |---|---|
     | 0/1/2 | The settings catalogue holds together; a write is **refused at the edge for anything the accessor would silently clamp** (written bounds are a subset of read clamps, so the admin gets an error instead of a lie); and a change is **live on the very next operation** — no restart, per FR10.11 |
     | 3 | The queue and the case file — including the **captain-channel chat archive** that FR10.6 asks for, which is why Wave B was sequenced first |
     | 4 | A ruling rates the match **once**: 1200→1216 vs 1200→1184 at K=32, on a dispute the queue scored at **16 ELO at stake** |
     | 5 | An already-rated match is **CORRECTED, not double-applied**: challenger 1216→1184, opponent 1184→1216 |
     | 6 | A ruling on a **tournament fixture** advances the bracket — semi-final settled at **K=48**, winner in the final, in the same transaction |
     | 7 | Suspension unwinds what the account was holding: **1 booking cancelled, PKR 2000 refunded, slot released** |
     | 8 | A suspended account is rejected on its **next** request with a previously-valid token |
     | 9 | The export **escapes a formula** and **reconciles with the ledger** |
     | 10 | The wiring the sources must state, read from disk rather than from a request |
231. **The severity cursor and why the queue is sorted at all.** ✅ Block 3. `severity_elo` is computed with
     the existing pure `elo.rate()` at the live K, so the admin triages **what is actually at stake** first
     rather than what is oldest — 16 points off a friendly and 48 off a final are not the same dispute. The
     list cursor is therefore a `"<severityElo>~<createdAt>~<id>"` **triple**; building one client-side pages
     wrong, which is why `API.md` documents it as opaque.
232. **The deviation: a ruling can be OVERTURNED.** ✅ Block 5, and it is the one place this wave departs from
     the approved plan, which said *refuse if `elo_applied` is already true*. That is the right rule for a
     double-**apply** and the wrong rule for a **correction** — an admin who rules the wrong way once would
     otherwise have no path back, and the ratings would stay wrong forever. So the ruling path reverses the
     prior exchange and applies the new one in the same transaction, both legs written to `elo_history` with
     their own reasons. That needed migration **021** (`chk_elo_history_reason` recreated with
     `admin_reversal` and `admin_ruling`) and **022** (`ux_elo_history_team_match` → `…_team_match_reason`,
     so one team can hold two history rows for one match: the original and its reversal).
     **The limit is asserted too:** a ruling cannot rewrite a bracket that has already advanced — that returns
     `code:'already_settled'`, because un-playing a final nobody can un-play is worse than a wrong semi-final.
233. **The security fix, tested the only way that means anything.** ✅ Block 8. `middleware/authMiddleware.js`
     was 43 lines of pure `jwt.verify` with **no database read**, so suspension was cosmetic until the token
     expired. It now carries a **30 s-TTL in-process cache** of `(id → {is_active, role})`, invalidated
     immediately on suspend, and — following `globalSettings.js`'s NEVER-THROW rule — **a database error falls
     back to the token's claims rather than locking every user out**. The test issues a real token, suspends
     the account through the service, and asserts the *same* token now gets `403`.
234. **The suspension cascade, and what it deliberately leaves alone.** ✅ Block 7. In one transaction:
     upcoming bookings cancelled with refunds through the existing `bookingService.cancelBooking` **core**
     function (so it joins this transaction rather than opening its own), open challenges withdrawn, upcoming
     tournament registrations withdrawn, the user notified. For a suspended **owner**: venues go
     `is_active = false` and pending requests are rejected+refunded, because otherwise players keep paying into
     a dead venue. **Not** unwound: a booking for a match already played. Reinstate restores exactly the venues
     *that* suspension took down, read back out of its own `admin_audit` row — so a venue the owner had closed
     themselves stays closed.
235. **The CSV injection case, which is the one non-obvious correctness item in the export.** ✅ Block 9. A
     venue named `=1+1` (or one starting `+`, `-`, `@`, tab, CR) **executes** when the file opens in Excel;
     every such field is prefixed with an apostrophe and quotes are doubled. The same block asserts the money
     comes from the **ledger** (`transactions`, the shapes `escrow.logTxn` writes) rather than being recomputed
     from prices, so the export reconciles with the wallet instead of merely agreeing with itself.
236. **`flutter analyze` → "No issues found! (ran in 31.0s)"** ✅ **observed**, whole project, after the last
     Dart change. Wave D's screens: `admin_disputes_screen.dart`, `admin_dispute_detail_screen.dart`
     (side-by-side submissions, the chat archive, four ruling actions behind a confirm dialog),
     `admin_users_screen.dart`, `admin_settings_screen.dart` (1037 lines — sectioned form, per-key
     default/override chip, save-diff confirm), `owner_reports_screen.dart` (786 lines), plus six routes and
     five imports in `main.dart` under the existing `AuthGuard(requiredRole: 'admin')`, four desk tiles and a
     live dispute count on `admin_home_screen.dart`, and a full-width Earnings Report tile on
     `owner_home_screen.dart`. **One reports screen serves both scopes** through a `platform` flag
     (`/owner-reports`, `/admin-reports`) — the payload is identical, only the route and the scope differ.
237. **What the reports screen shows, so nobody reads it as the whole file.** The preview renders at most **40**
     of the server's 500-row JSON page, and the JSON page is itself capped while the **totals are always for
     the whole range** — `truncated: true` says so on screen. The CSV is the complete document. The export has
     **no Court column** (a booking references a slot, and the court name is not on the ledger row), owner
     scoping is by `venues.owner_id`, and bookings and tournament payouts share **one flat table with a `Type`
     column** rather than two tables, because a reconciliation you have to add up across two tables is a
     reconciliation nobody does.
238. **The admin manual pass.** ⛔ **NOT RUN.** Rule a disputed match from the admin app and watch: both
     teams' Elo moves once, the bracket advances if it was a fixture, both captains get a notification **and**
     see the neutral pill in the room they argued in. Then suspend a player and make a request with their old
     token. Then change commission % and book something. Then export a CSV and open it in Excel on Windows —
     the UTF-8 BOM is there so Urdu venue names and em dashes render instead of mojibake.
     **Two rows remain in `admin_audit`** from the smoke test of this screen. They are left there on purpose:
     deleting audit rows was refused as audit tampering, which is the correct answer, and an audit log with a
     hole in it is worth less than an audit log with two test rows in it.

### 4.26 The no-regression sweep after S.7 B/C/D

Every wave in this sprint reached into code the earlier ones own — Wave B into `routes/owner.js`,
`autoApproveJob`, `noShowJob` and `matchCore.fanOut`; Wave C into `utils/notify.js`, which 33 call sites use;
Wave D into `authMiddleware` (every authenticated request in the app) and into the same Elo path
`matches.js` verifies through. So the sweep is not a formality here; three of those five are load-bearing for
money or for auth.

239. **The full sweep, all green.** ✅ **observed** after the last Wave D change:
     | Command | Result |
     |---|---|
     | `node src/scripts/verify_schema.js` | **233/233** (019 + 020 censuses) |
     | `node src/scripts/check_booking_service.js` | **60/60** — the escrow path, because suspension now cancels bookings through it |
     | `node src/scripts/check_chat.js` | **120/120** — Wave B still green after C and D |
     | `node src/scripts/check_notifications.js` | **169/169** — Wave C still green after D added 14 emitters |
     | `node src/scripts/check_assistant.js` | **342/342** — Scout untouched, and quick replies reuse its frozen model |
     | `node src/scripts/check_admin.js` | **275/275** |
     | `cd backend && npm test` | **159/159**, database down |
     | `flutter analyze` | **0 issues**, whole project |
     | `PORT=3111 node src/server.js` | boots clean, `45 types → 9 routes`, **7 jobs**, `FCM OFF` |
240. **Migrations 019-022 are all applied to Supabase** (019 and 020 on 2026-08-30, 021 and 022 on
     2026-08-31). ✅ 022 is **required** for the overturn branch in step 232; without it the second
     `elo_history` row for a team collides with the old unique index. `DATABASE.md`'s migration history
     records all four with what each one contains.
241. **What the sweep does not cover.** ⛔ The three manual passes above (steps 221, 229, 238), the tray
     push itself (dormant until the Firebase key lands), and `source:'model'` quick replies whenever ml-service
     is down — the lexicon fallback is asserted, so the check still passes without `uvicorn`, but the model
     path needs it up (4/4 models, `intent-v2-20260828-2315`, `/health` fingerprint `517c9b43`).
     Also still open and now urgent: **rotate `ML_API_KEY`** in both `.env` files before ml-service goes on a
     public URL, and note that `/health` is unauthenticated and leaks `modelDir` plus model versions.

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
- **Reviews (S.4 Wave C).** `POST /reviews` for a `booking_id` you did not book (venue
  review) or a match you are not a **captain** of (opponent review) → 403, no row written.
  The reviewer is `req.user`, never a body field, and the opponent review's target
  (`reviewed_user_id`) is the opposing captain **derived server-side** — there is no target
  field to point at a stranger. `POST /reviews/:id/flag` on a review whose booking/match you
  had no part in → 403.
- **Suggested players (S.5 Wave B).** `GET /teams/:id/suggested-players` for a team where
  you are a **member but not admin** → 403; for a team you are **not in** → 403. The role is
  re-read server-side (`requireRole(..., 'admin')`), so the endpoint never leaks a candidate
  list — names, avatars, activity — to someone without captain/vice authority over that team.

### 6.3 Mass assignment
Send extra fields the endpoint never promised and confirm they are ignored:
```bash
curl -X PATCH "$BASE/teams/<id>" -H "Authorization: Bearer $TOKEN_A" \
  -H 'Content-Type: application/json' \
  -d '{"bio":"hi","elo":9999,"wins":500,"visibility":"public","captain_id":"<someone-else>"}'
```
Expected: `bio`/`visibility` change; **`elo`, `wins`, `captain_id` do not.** Then confirm
in the DB. Silent acceptance of `elo` would let anyone top the leaderboard.

For **reviews**, the fields that decide identity and trust are all server-derived, so
forging them must do nothing:
```bash
curl -X POST "$BASE/reviews" -H "Authorization: Bearer $TOKEN_A" \
  -H 'Content-Type: application/json' \
  -d '{"booking_id":"<your-checked-in-booking>","review_type":"venue","stars":5,
       "text":"ok","reviewer_id":"<someone-else>","reviewed_user_id":"<victim>",
       "sentiment_label":"positive","sentiment_score":1,"flagged":false,"hidden":true}'
```
Expected: the row is written with `reviewer_id` = **your** id, `reviewed_user_id` = NULL
(venue review), and `sentiment_*`/`flagged` set by the **model**, not the body — a caller
must not be able to paint their own review positive or hide someone else's. `stars` outside
1–5 → 400.

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

**Sentiment additions (S.4).** The sentiment endpoints take *free text*, which the pricing
endpoints never did — a new attack surface, and the first place in this service where the
size of a request body is attacker-controlled.

- **Text and batch size limits are enforced server-side and both are tested over HTTP.**
  `MAX_TEXT_CHARS = 4000` and `MAX_BATCH_ITEMS = 200` in `app/routers/sentiment.py`. A
  char 2–6 n-gram vectoriser is superlinear in input length, so an unbounded batch of long
  strings is a CPU-exhaustion vector on a free-tier dyno. `smoke_sentiment_api.py` posts
  201 items → 422, exactly 4,000 characters → **200**, 4,001 → 422, and an over-long row
  inside an otherwise-valid batch → 422. The boundary is pinned in both directions on
  purpose: "very long text is rejected" would pass just as happily on a cap of 40, so the
  caps' absolute values are asserted separately from the boundary behaviour.
- **No review text is logged.** A review is user content and may contain abuse, names or
  phone numbers. The per-review log line in `app/routers/sentiment.py` records
  `len(request.text)` — the *length* — alongside the review id, label, score, confidence
  and flags, and never the string itself. Grep the format string before believing this
  sentence: escalation *decisions* are safe to log, escalation *text* is not.
- **The abuse verdict is advisory, never an authorisation.** `escalate:true` must not by
  itself hide a review, suspend a user or block a booking. It is a flag for a human, and a
  model with 0.84 precision on the exam's negative class is nowhere near a basis for
  automated punishment — an FR9.10 escalation that silently bans someone is the worst
  failure this model can cause.
- **A hostile sentiment response cannot act on its own.** The same rule as pricing: when
  Node is eventually wired up, an out-of-range score or an unknown label must be rejected
  by the caller, not written to `reviews.sentiment_label`. Only the three values in
  `LABELS` (`negative` / `neutral` / `positive`) are ever valid.

### 6.12 Recommender data export (S.5)
The recommender trains on a read-only snapshot pulled over `GET /api/internal/export/reco-data` —
the single largest disclosure of player data in the app (every user's booking history in one
response). It is the one internal route that gets its own secret and its own fail-closed test,
separate from the ML service key.

- **Separate secret, never `ML_API_KEY`.** The route authenticates on the `X-Reco-Export-Key`
  header checked against `RECO_EXPORT_API_KEY`, a *different* variable from `ML_API_KEY`. Reusing
  the ML key here would widen its blast radius from "prices" to "every player's history"; the two
  secrets are generated independently and are expected to differ.
- **Fails closed when unconfigured.** With `RECO_EXPORT_API_KEY` unset or shorter than 16 chars the
  route returns **503 `export_not_configured`** — it refuses to serve rather than fall open. An
  export that answered with data because someone forgot a variable would leak the whole user table;
  this is the pricing "refuse to boot open" rule applied to a route.
- **Missing key and wrong key are indistinguishable.** Both return an identical **401
  `invalid_api_key`**; comparison is `crypto.timingSafeEqual` after a length guard, so neither the
  message nor the response time tells an attacker whether their key was even the right *shape*.
- **The phone can never reach it.** It lives under `/api/internal/*`, is on no player route, and
  takes no user-supplied key — a client cannot influence the header the trainer sends. Only
  `build_reco.py`, run by a developer holding the secret, calls it.
- **The response is read-only and minimal.** Four `SELECT`s, no writes, ratings limited to `>=4 AND
  NOT hidden`; it exposes booking history and stated prefs for modelling but no passwords, tokens,
  wallet balances, or contact details beyond what the model consumes.

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
[ ] npm test ..................... 128/128 (DB may be down)                (S.7-A: was 85/85)
[ ] verify_schema.js ............. 174/174                                 (S.7-A: 113 + 61 for 019)
[ ] run_match_flow_check.js ...... 69/69
[ ] check_ml_service.js .......... 71/71 up · 31/31+4 skipped down   (S.3+)
[ ] check_price_sanity.js ........ 20/20 required, source='model'    (S.3+)
[ ] train_sentiment.py ........... 7/7 gates, exam >= 0.80           (S.4+)
[ ] smoke_sentiment_api.py ....... 49/49 vs released artifact        (S.4+)
[ ] build_reco.py ................ 3/3 gates, RELEASED               (S.5+)
[ ] eval_reco.py ................. gate PASS, lift over cold-start   (S.5-C+, run AFTER build_reco)
[ ] ml /health.recoRankSpec ...... reco-rank-v1 · 1a6c5f39bf5a2c56  (S.5-B+, RESTART ml first)
[ ] gen_intents.py ............... 2,576 rows, sha 64395ec8026c      (S.6-C+, validate exam FIRST)
[ ] train_intents.py ............. 10/10 gates, RELEASED, exam 0.6696 (S.6-C+, 23 labels)
[ ] test_nlu.py .................. 68/68 + 0 skipped, before commit  (S.6-C+)
[ ] ml /health.models ............ 4 ready, intent spec = ...-v2     (S.6-C+, /nlu/refresh first)
[ ] /nlu/parse ................... 5 slots, p50 ~21 ms on IDLE box   (S.6-C+, load-sensitive)
[ ] /nlu/spec .................... 23 intents / 8 groups / 3 reasons  (S.6-C+)
[ ] check_assistant.js ........... PASS 326/326, 0 skips, rolled back (S.6-C+, ml-service UP)
[ ] check_booking_service.js ..... PASS 60/60, ledger matches escrow  (S.6-C+, any money change)
[ ] check_assistant_http.js ...... PASS 173/173, 0 skips, residue gone (S.6-C+, API + ml UP; ~2m40s)
[ ] npm run evidence ............. scout_evidence.md 326/326 + 173/173 (S.6-E+, before the viva)
[ ] check_tournaments.js ......... PASS n/n, 0 skips, rolled back      (S.7-A+, needs migration 019)
[ ] tournament_evidence.md ....... regenerated, reads PASS n/n         (S.7-A+, on disk it is FAIL 2/3)
[ ] /tournaments/:id/generate .... meta.scheduling.source model | chronological (S.7-A+, A/B both must pass)
[ ] server boots, 6 jobs registered                                    (S.7-A added tournamentJob)
[ ] this wave's feature steps (§3/§4)
[ ] IDOR spot-check (§6.2)
[ ] mass-assignment spot-check (§6.3)
[ ] data-integrity queries (§7) all return 0 rows
[ ] docs updated
[ ] committed with green numbers
```
