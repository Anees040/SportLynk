# ml-service — SportLynk's model server

The third tier of SportLynk. Flutter talks to Node; Node talks to Postgres and, for
model-backed features, to this. It serves scikit-learn models trained by the scripts
in `training/`.

It holds no database connection, no session and no state. Given features, it returns
a prediction. That is what makes it safe to restart mid-demo and what will make it
safe to deploy as a second Render service in S.7.

**Two models are served.** Pricing (S.3) takes eleven contract columns and returns a
revenue-optimal price; sentiment (S.4) takes **raw review text** and returns a 3-class
label plus an abuse verdict. They share the registry, the API-key middleware and the
error envelope, and nothing else — each owns its own frozen contract module, its own
gates and its own evidence in `reports/`.

---

## Architecture

Four processes. Only one of them is allowed to talk to this one.

```
┌────────────────────────────────────────────────────────────────────────────┐
│ FLUTTER  (lib/)                                                            │
│   owner_home_screen ............... suggested-price card, Apply button     │
│   owner_venue_management_screen ... 72-hour demand chart                   │
└─────────────────────────────────┬──────────────────────────────────────────┘
                                  │ HTTPS · Authorization: Bearer <JWT>
                                  ▼
┌────────────────────────────────────────────────────────────────────────────┐
│ NODE / EXPRESS  :3000  (+ Socket.IO for chat and match events)             │
│   routes/owner.js ....... GET :id/pricing · GET :id/forecast               │
│   routes/venues.js ...... PATCH :id/slots/price  ← what Apply calls        │
│   services/mlClient.js .. timeout · breaker · guardrails · FALLBACK        │
│   utils/ttlCache.js ..... 1 h TTL, keyed on venue + PKT hour               │
└──────────┬───────────────────────────────────────────┬─────────────────────┘
           │ pg — owner_id in every WHERE              │ POST · X-API-Key
           ▼                                           ▼ 127.0.0.1:8000 only
┌──────────────────────────┐   ┌─────────────────────────────────────────────┐
│ SUPABASE POSTGRES        │   │ ML-SERVICE  FastAPI + uvicorn               │
│   venues · slots         │   │   app/main.py ......... key mw, envelope    │
│   bookings · reviews     │   │   app/core/features.py  ★ THE CONTRACT      │
│   reviews.sentiment_*    │   │   app/core/text_norm.py ◆ NORM CONTRACT     │
│   (schema ready, unused) │   │   app/core/registry.py  loads *_latest      │
│   (no ML tables — the    │   │   app/routers/pricing.py price sweep, why   │
│    service is stateless) │   │   app/routers/sentiment.py 3-class + abuse  │
└──────────────────────────┘   └───────────────────┬─────────────────────────┘
                                                   │ joblib.load, once, at boot
                                                   ▼
                               models/pricing_latest.joblib          374 KB
                                                   ▲
                                                   │ written only if 12 gates pass
                               training/train_pricing.py ──► reports/  (plots,
                                        ▲                    metrics, model card)
                                        │ imports the SAME features.py  ★
                               data/bookings_synth.csv   seeded, sha256-pinned

                               models/sentiment_latest.joblib        2.9 MB
                                                   ▲
                                                   │ written only if 7 gates pass
                               training/train_sentiment.py ─► reports/ (confusion
                                        ▲                     matrix, metrics, card)
                                        │ imports the SAME text_norm.py  ◆
                               data/sentiment/train.csv  sha256-pinned, rebuildable
```

Five edges in that diagram carry the design; the rest is plumbing.

**Flutter never reaches this service.** There is no route from the app to port
8000, and the app has never held `ML_API_KEY`. That is not layering for its own
sake: the key is a *shared secret*, so any client that could send it would also
be shipping it. Node is the only holder, and this process binds loopback so the
question cannot arise in development either.

**The ★ and ◆ arrows are each the same file, twice.** `app/core/features.py` is
imported by `training/train_pricing.py` and by `app/routers/pricing.py`;
`app/core/text_norm.py` is imported by `training/train_sentiment.py` and by
`app/routers/sentiment.py`. Neither side of either pair owns a copy of any
derivation. One is a feature contract and the other a text-normalisation contract,
but the failure they exist to prevent is the same one — see "`app/core/features.py`
is the important file" below, and the norm-fingerprint note that follows it.

**The FALLBACK edge is the honest one.** Kill uvicorn mid-demo and
`mlClient.js` still answers HTTP 200 — with `source: "heuristic"` in the body and
`confidence: null`, which the owner card renders as a plainly different caption.
Nothing throws, nothing retries in a loop, and no number is presented as
model-derived when it isn't. The circuit breaker then stops calling a dead
service for 30 s rather than paying the timeout on every request.

**Reads are cached, writes are not.** The two `GET` routes go through a 1-hour
TTL cache keyed on venue + PKT hour, because a price suggestion that changes
between two pulls of the same screen looks broken. `PATCH :id/slots/price` —
the Apply button — bypasses all of it: a normal authenticated Node route,
ownership checked in SQL, no ML process in the path. **This service never
writes to Postgres**, and holds no connection to it.

**The model files are the only state.** `registry.py` loads each
`models/*_latest.joblib` once at boot and validates its stamped contract before
serving a single request — `FEATURE_SPEC_VERSION` for pricing, the normalisation
fingerprint for sentiment. A retrain therefore does *not* hot-swap the live model:
restart uvicorn (or call `registry.reload('<key>')`), or `/health` and the owner
dashboard keep reporting the previous `model_version`.

---

## Run it

```powershell
cd D:\sportlynk\ml-service

# first time only
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
Copy-Item .env.example .env
python -c "import secrets; print(secrets.token_hex(32))"   # paste into .env AND backend\.env

# every time
.\run_dev.ps1                 # == uvicorn app.main:app --host 127.0.0.1 --port 8000
```

Then, in a second terminal:

```powershell
curl.exe -s http://127.0.0.1:8000/health
```

`/docs` gives the interactive OpenAPI page. Keep two terminals open during
development: one for `node src/server.js`, one for this.

---

## What exists right now (S.4 Wave B — sentiment trained and served)

| endpoint | auth | status |
|---|---|---|
| `GET /health` | public | reports model inventory, feature spec, **norm spec**, library versions |
| `GET /features/spec` | `X-API-Key` | publishes the frozen feature contract |
| `POST /predict/price` | `X-API-Key` | **serving** — sweeps the price band, returns the revenue-optimal ratio, confidence and `top_factors` |
| `POST /predict/demand` | `X-API-Key` | **serving** — 72 hourly `P(book)` points at `price_ratio = 1.0` |
| `GET /sentiment/spec` | `X-API-Key` | publishes the frozen normalisation contract: label set, `normSpecVersion`, fingerprint |
| `POST /predict/sentiment` | `X-API-Key` | **serving** — one review → label, signed polarity, class scores, abuse verdict, `needsReview` |
| `POST /predict/sentiment/batch` | `X-API-Key` | **serving** — up to 200 reviews in one `predict_proba` call, metrics on the envelope not per row |

Served pricing artifact `pricing-v1-20260825-0041`: ROC-AUC **0.7628** against a
measured Bayes ceiling of 0.7770 (98.2% of it), Brier 0.1680, 6,244 held-out rows. All
12 training gates passed.

Served sentiment artifact `sentiment-wordchar-linsvc-softmax-20260826-1306`: **0.8250**
accuracy (macro-F1 0.8247, CI 0.77–0.88) on the 200-row held-out in-domain exam, against
a majority-class baseline of 0.3400. All 7 training gates passed. Trained on 21,405 rows
of English + Roman Urdu + code-mixed text; it takes **raw text**, not features, because
the normalisation lives inside the pipeline.

Numbers, plots and limitations for both: `reports/`.

**One boundary worth being explicit about.** The sentiment endpoints are live and
directly smoke-tested (`training/smoke_sentiment_api.py`, 49 checks against the released
artifact), and `reviews.sentiment_score` / `reviews.sentiment_label` already exist in the
schema — but **no Node route calls them yet**. Nothing in `backend/src/` references this
model. Wiring it into the review-submission path, and the moderation queue that
`needsReview` is meant to feed, is the next wave's work, not something this one quietly
half-did.

The prediction endpoints answered **503 `model_not_loaded`** before their models existed,
and that was correct. If you see a 503 today it means the relevant `*_latest.joblib` is
missing or its stamped contract no longer matches the module that serves it — a
`FEATURE_SPEC_VERSION` drift for pricing, a norm-fingerprint drift for sentiment. The
registry refuses to predict through a changed contract rather than guess. For pricing,
the Node backend then degrades to its heuristic and labels the response
`source: "heuristic"`, so nothing in the app breaks.

---

## Retrain it

### Pricing

```powershell
cd D:\sportlynk\ml-service
.\.venv\Scripts\python.exe training\train_pricing.py --seed 42
```

68 seconds end to end on a dev laptop. It prints a metrics table (this model vs a
plain logistic baseline vs the Bayes-optimal ceiling), runs 12 gates, and writes
the artifact plus every plot and the model card. **Bit-for-bit reproducible** —
`--seed 42` is the run that produced the served artifact, and re-running it
reproduces all nine metrics to six decimal places.

The gates are the point: the model is only written if it passes them. A failing
run leaves `models/pricing_latest.joblib` untouched, so a bad retrain cannot take
the demo down with it. To rehearse without touching committed evidence, redirect
both outputs:

```powershell
.\.venv\Scripts\python.exe training\train_pricing.py --seed 42 `
  --models-dir .rehearsal\models --reports-dir .rehearsal\reports
```

### Sentiment

```powershell
.\.venv\Scripts\python.exe training\train_sentiment.py
```

**No flags, deliberately.** The defaults *are* the shipped configuration
(`--branches both --C 0.1 --upweight-authored 40 --seed 42`), so a bare invocation
reproduces the released model rather than a nearby variant. A tuned model whose
reproduction command carries four flags nobody wrote down is not reproducible in
practice, only in principle.

It runs 7 gates and writes `reports/sentiment_metrics.json`,
`model_card_sentiment.md` and `confusion_matrix_sentiment.png`. It releases only if
the 200-row exam clears **0.80**. Two things it will refuse to do: train on
`data/sentiment/domain_test_200.csv` (a provenance gate re-checks the exam's sha256
every run), and ship a model whose normalisation fingerprint disagrees with
`app/core/text_norm.py`.

`--models-dir` / `--reports-dir` work here too, so the same rehearsal trick applies.

**If you change `--branches` or `--upweight-authored`, `C = 0.1` stops being the right
value** — it was selected against the current ~100k-feature union, and regularisation
strength scales with feature-space size. The model card records the validation sweep to
re-run. Then re-check the abuse threshold, because it is a property of this model's score
scale rather than a portable constant:

```powershell
.\.venv\Scripts\python.exe training\validate_neg_threshold.py   # precision/recall table
.\.venv\Scripts\python.exe training\audit_exam.py               # the 20 worst errors
.\.venv\Scripts\python.exe training\smoke_sentiment_api.py      # 49 API checks
```

The first two open the exam **read-only** and decide nothing — they print a table for a
human to read. `reports/README.md` explains why that threshold needs re-checking at all,
and what went wrong the one time it was left alone.

### Either model

A retrain does not hot-swap the running model. Restart uvicorn afterwards (or call
`registry.reload('pricing' | 'sentiment')`), or `/health` and the owner card keep
reporting the previous `model_version`.

---

## The API key

Every request except `/health` must carry `X-API-Key`. The service **refuses to
start** without `ML_API_KEY` set — an unauthenticated pricing engine is not a
degraded service, it is an open one.

Three details that are deliberate:

- The comparison is `hmac.compare_digest`, not `==`. Python's `==` on strings short
  circuits at the first differing byte, so response timing leaks the key one byte at
  a time. The fix is one import, so there is no reason not to.
- **Missing key and wrong key return the same 401 with the same body.** Telling a
  caller "your key is wrong" rather than "you sent no key" confirms that a key
  exists and that it merely has the wrong one — free information for an attacker,
  and no help to a developer, who has `/health` to check against.
- The key is never logged. `/health` reports `apiKeyFingerprint`, the first 8 hex
  chars of its sha256 — enough to prove `backend/.env` and `ml-service/.env` match
  without either process printing a secret.

It binds `127.0.0.1`. There is no CORS middleware, because a browser calling this
directly would mean the shared secret had been shipped to a client.

---

## Why there is no heuristic in here

It would be three lines to answer `base * 1.15` on a peak hour instead of a 503.
That is refused on purpose.

The Node client reports `source: "model" | "heuristic"` to the owner dashboard, and
that field is the honesty mechanism for the whole feature — a supervisor is entitled
to ask "is this number from your trained model?" and get a true answer. If this
service quietly substituted a rule of its own, every response would arrive labelled
`source: "model"` and the label would be a lie.

So the fallback lives in exactly one place, `backend/src/services/mlClient.js`, on
the far side of a failed call, where its use is unambiguous and self-reporting. Same
principle as `backend/src/utils/matchPreview.js` ("WHY THE UI LABEL IS 'Preview' AND
NOT 'AI PREDICTION'").

---

## `app/core/features.py` is the important file

It is the **feature contract**: the list, the order, the dtypes, and every
derivation. Training imports it and serving imports it, and neither is allowed its
own copy of any derivation.

Train/serve skew — the model being fed columns in a different order, or an `is_peak`
computed with a different peak window — is the most common way a working ML service
silently starts returning confident nonsense. One function imported by both sides is
the only version of that guarantee that survives someone editing one of the two
files a month from now.

Backing it up mechanically:

- `FEATURE_SPEC_VERSION` is stamped into every artifact at train time and re-checked
  at load. Mismatch → the model is marked `incompatible` and never served (503),
  rather than predicting on misaligned columns.
- `PEAK_START_HOUR` / `PEAK_END_HOUR` and the price band are duplicated in
  `mlClient.js` because Node cannot import Python — so `GET /features/spec` exists
  for `check_ml_service.js` to **assert** the two copies agree, instead of a comment
  hoping they do.
- All date maths is **naive PKT**. `slots.slot_date` and `slots.start_time` are
  local wall-clock columns (`routes/venues.js` builds `pktNow` by adding 5h to UTC
  and compares it straight against them). Golden rule 4's "store UTC" governs
  `timestamptz` columns; these two are not that. Getting it wrong would shift every
  hour by 5 and move the entire peak window.

### `app/core/text_norm.py` is the same idea, and needs a stronger mechanism

Sentiment's contract is not a column list — it is the text normalisation itself:
casefolding, elongation collapse (*"boohoot achaaa"*), emoji handling, and the negation
scoping that lets *"acha nahi tha"* mean the opposite of *"acha tha"*. Training and
serving import the one module, for the same reason pricing does.

But this contract needs a **fingerprint**, not just a version string, because of how
joblib works: `FunctionTransformer` pickles a callable **by reference**. The artifact
does not contain the normalisation code — it contains a pointer to
`text_norm.prep_word`. Edit that function and every previously-released artifact
silently starts normalising text the *new* way at serve time. No version mismatch fires,
no exception is raised, and the model is simply fed inputs it was never trained on. This
is a nastier failure than a column reorder, because a reordered column usually produces
obvious nonsense while a subtly different tokeniser just quietly costs accuracy.

So `NORM_SPEC_VERSION` (`sentiment-norm-v1`) is paired with `norm_spec_fingerprint()`
(`b96e65df85f9692b`), a hash over the spec itself. It is stamped at train time,
re-checked at load, and published by both `GET /sentiment/spec` and `/health`. The
publishing is what makes it assertable from the Node side the way
`GET /features/spec` already is for pricing — `check_ml_service.js` does not check it
yet, because nothing in `backend/src/` calls this model yet.

One smaller decision in the same file: `LABELS` is `("negative", "neutral",
"positive")` — **alphabetical, to match scikit-learn's `classes_` ordering**. The router
indexes `predict_proba` columns by position, and a hand-chosen order like
`(negative, positive, neutral)` would transpose two classes with no error anywhere. The
smoke suite closes that loop by asserting `argmax(classScores)` equals the estimator's
own `predict()` on every probe.

---

## Layout

```
app/
  main.py              FastAPI app, API-key middleware, /health, error envelope
  core/config.py       env settings; fails fast when ML_API_KEY is missing
  core/features.py     THE FEATURE CONTRACT — imported by training and serving
  core/text_norm.py    THE NORM CONTRACT — the same, for sentiment's raw text
  core/proba.py        SoftmaxSVC — softmax over an SVM's decision_function
  core/toxicity.py     abuse-lexicon match; orthogonal to the sentiment label
  core/pk_calendar.py  Ramadan / Eid windows used by the pricing features
  core/registry.py     loads models/*_latest.joblib, validates each contract
  routers/pricing.py   request/response models, /predict/price, /predict/demand
  routers/sentiment.py /predict/sentiment[/batch], /sentiment/spec
training/
  generate_bookings.py synthetic simulator — DO NOT re-run, the CSV is sha-pinned
  train_pricing.py     training + 12 gates + plots + model card
  train_sentiment.py   training + 7 gates + confusion matrix + model card
  build_sentiment_corpus.py
                       rebuilds data/sentiment/train.csv from its sources
  validate_neg_threshold.py, audit_exam.py, smoke_sentiment_api.py
                       read-only checks: the threshold table, the 20 worst
                       errors, and 45 assertions against the RELEASED artifact
models/                *_latest.joblib is committed; timestamped runs are not
data/                  generated CSVs (gitignored — regenerate from the seed)
data/sentiment/        default-DENY in .gitignore, because the corpus is ~9 MB of
                       third-party licensed text. The exam, the hand-authored
                       rows and the sha256 metadata are explicit exceptions
reports/               metrics.json, plots, model cards — COMMITTED, this is the
                       AI evidence trail
```

---

## Why a separate Python process rather than ONNX in Node

The alternative removes a moving part, and was still rejected:

- The FYP needs a defensible training story — a reproducible script, metrics, a
  model card. Training is Python. Keeping training and serving in one language means
  the **same** feature code runs in both; an ONNX export would re-implement feature
  building in JavaScript, and that second implementation is where drift would live.
- A joblib artifact of an sklearn `Pipeline` carries its own preprocessing. An ONNX
  graph of the estimator alone does not, so encoders and imputers would have to be
  reproduced by hand in Node.
- The failure mode is already handled. `mlClient.js` degrades to a heuristic when
  this process is unreachable, so "extra moving part" costs a label change on the
  dashboard, not an outage.
