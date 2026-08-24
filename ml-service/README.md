# ml-service — SportLynk's model server

The third tier of SportLynk. Flutter talks to Node; Node talks to Postgres and, for
model-backed features, to this. It serves scikit-learn models trained by the scripts
in `training/`.

It holds no database connection, no session and no state. Given features, it returns
a prediction. That is what makes it safe to restart mid-demo and what will make it
safe to deploy as a second Render service in S.7.

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

## What exists right now (S.3 Wave A)

| endpoint | auth | status |
|---|---|---|
| `GET /health` | public | working — reports model inventory, feature spec, library versions |
| `GET /features/spec` | `X-API-Key` | working — publishes the frozen feature contract |
| `POST /predict/price` | `X-API-Key` | validates + builds features, then **503 `model_not_loaded`** |
| `POST /predict/demand` | `X-API-Key` | validates + builds features, then **503 `model_not_loaded`** |

The 503 is correct and expected until Wave B trains a model. The Node backend
degrades to its heuristic and labels the response `source: "heuristic"`, so nothing
in the app breaks.

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

---

## Layout

```
app/
  main.py              FastAPI app, API-key middleware, /health, error envelope
  core/config.py       env settings; fails fast when ML_API_KEY is missing
  core/features.py     THE FEATURE CONTRACT — imported by training and serving
  core/registry.py     loads models/*_latest.joblib, validates the feature spec
  routers/pricing.py   request/response models, /predict/price, /predict/demand
training/
  generate_bookings.py synthetic simulator   (design docstring; Wave B)
  train_pricing.py     training script       (design docstring; Wave B)
models/                *_latest.joblib is committed; timestamped runs are not
data/                  generated CSVs (gitignored — regenerate from the seed)
reports/               metrics.json, plots, model card — COMMITTED, this is the
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
