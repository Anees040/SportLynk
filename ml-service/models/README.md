# models/

Trained model artifacts. `app/core/registry.py` reads this directory.

## Naming

```
pricing_latest.joblib          <- what the service loads and serves
pricing_20260824-1830.joblib   <- provenance: every training run keeps its own file
```

The registry loads `<key>_latest.joblib` only. `pricing_latest.joblib` therefore
registers under the key `pricing`.

## Git policy

`*_latest.joblib` is **committed**; timestamped runs are **ignored** (see the
`ml-service/` block in the root `.gitignore`).

The reason for the split: a fresh clone must be able to serve a real model without
first running a training pipeline — that is what makes the demo reliable and what
lets a supervisor check out the repo and see the feature work. But keeping every
historical artifact in git would bloat it for no benefit, since any of them can be
reproduced from `training/train_pricing.py` plus its recorded seed.

The timestamped files are the audit trail on the training machine. They answer
"which exact model produced the screenshot in the report", which for an FYP is the
difference between evidence and a claim.

## Artifact format

A dict, never a bare estimator — a bare estimator cannot tell you what it was
trained on:

```python
{
  "model":              Pipeline,        # preprocessing INSIDE it
  "featureSpecVersion": "pricing-features-v1",
  "featureOrder":       [...],
  "modelVersion":       "pricing-v1-20260824-1830",
  "trainedAt":          "2026-08-24T18:30:00Z",
  "metrics":            {"rocAuc": ..., "brier": ..., ...},
  "libraries":          {"sklearn": ..., "numpy": ..., "pandas": ..., "python": ...},
  "dataset":            {"rows": ..., "source": "synthetic", "seed": 42, "file": ...},
}
```

`featureSpecVersion` is re-checked against `app/core/features.py` at load. If they
differ the model is marked `incompatible` and **never served** — the alternative is
predicting on misaligned columns, which does not crash and produces confident
garbage.

`dataset.source` travels with the artifact and surfaces in `/health`, so "this model
was trained on simulated data" cannot be quietly dropped from a slide.

## Right now

`pricing_latest.joblib` — **`pricing-v1-20260825-0041`**, 374 KB, all 12 training gates
passed, ROC-AUC 0.7628 (98.2% of the measured Bayes ceiling). It is committed, so a fresh
clone serves predictions without training first. Beside it sit the timestamped provenance
copies of the three runs it took to get there; only `*_latest.joblib` is ever loaded.

Two behaviours worth knowing before you touch anything here:

- **The service loads this file once, at boot.** A retrain does not hot-swap it — restart
  `uvicorn` or the owner dashboard keeps reporting the previous `model_version`.
- **If it is missing, or its `FEATURE_SPEC_VERSION` no longer matches
  `app/core/features.py`,** `/predict/*` answers `503 model_not_loaded` and the Node
  backend serves heuristic prices labelled `source: "heuristic"`. That is the designed
  degradation, not an outage — but it is also what a mid-sprint `features.py` edit looks
  like, so check `/health` first.
