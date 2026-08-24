# reports/

**Committed to git, deliberately.** This directory is the AI evidence trail.

`models/` holds a binary nobody can inspect and `data/` is regenerable and ignored.
This is the only place where the *claims* about the model live in a form a supervisor,
an external examiner, or a future maintainer can read and check. Written by
`training/train_pricing.py` on every run, so it cannot go stale relative to the
artifact it describes.

| file | written by | contents |
|---|---|---|
| `metrics.json` | `train_pricing.py` | ROC-AUC, PR-AUC, Brier, log loss, confusion matrix, split sizes, feature importances |
| `model_card.md` | `train_pricing.py` | intended use, training data + its limitations, features, exclusions, metrics, retraining trigger |
| `calibration_pricing.png` | `train_pricing.py` | predicted vs observed probability, 10 bins |
| `price_response_pricing.png` | `train_pricing.py` | P(book) across the swept price band for a sample slot |
| `requirements.lock.txt` | `pip freeze` at train time | the FULL resolved environment, transitives included |

---

## Why the Brier score is the headline number, not ROC-AUC

ROC-AUC measures *ranking* — whether the model puts likely-booked slots above
unlikely ones. That is not what this model is used for.

The price engine computes `argmax(price × P(book | price))`. It **multiplies the
probability by a rupee amount**, so the probability has to be right in absolute
terms, not merely well-ordered. A model with ROC-AUC 0.90 that is systematically
overconfident will recommend the wrong price with complete conviction.

The Brier score and the calibration plot are what catch that. Both are reported, and
the model card leads with calibration.

## Why a monotonic price response is a release gate, not a metric

`train_pricing.py` holds a slot fixed, sweeps the price grid, and asserts P(book) is
monotonically non-increasing in price. If a trained model says demand *rises* with
price, a pricing engine built on it recommends charging more, forever.

That check refuses to write `pricing_latest.joblib` when it fails. It is not a number
in a table; it is a gate.

## Why a near-perfect score would be bad news

Training data is synthetic (see `data/README.md` for the measurement that forces
that). The labels are drawn stochastically from the latent demand, so a model
**cannot** reach ROC-AUC ≈ 1.0 by inverting the generator. If a run reports 0.99,
the correct conclusion is that a feature is leaking the label — not that the model is
excellent. A committee that has seen this before will ask.

---

## Right now

Empty except this file. Wave B populates it.
