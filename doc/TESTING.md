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
    Expect **`60/60 checks passed`** with the service up, and **`31/31 passed, 4 skipped`**
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
113. **`/health` reports both models, and Node calls only one of them.** The health payload
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
[ ] check_ml_service.js .......... 60/60 up · 31/31+4 skipped down   (S.3+)
[ ] check_price_sanity.js ........ 20/20 required, source='model'    (S.3+)
[ ] train_sentiment.py ........... 7/7 gates, exam >= 0.80           (S.4+)
[ ] smoke_sentiment_api.py ....... 49/49 vs released artifact        (S.4+)
[ ] server boots, 4 jobs registered
[ ] this wave's feature steps (§3/§4)
[ ] IDOR spot-check (§6.2)
[ ] mass-assignment spot-check (§6.3)
[ ] data-integrity queries (§7) all return 0 rows
[ ] docs updated
[ ] committed with green numbers
```
