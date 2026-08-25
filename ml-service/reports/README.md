# reports/

**Committed to git, deliberately.** This directory is the AI evidence trail.

`models/` holds a binary nobody can inspect and `data/` is regenerable and ignored.
This is the only place where the *claims* about the model live in a form a supervisor,
an external examiner, or a future maintainer can read and check. Written by
`training/train_pricing.py` on every run, so it cannot go stale relative to the
artifact it describes.

| file | written by | contents |
|---|---|---|
| `demand_patterns.png` | `generate_bookings.py` → `demand_plots.py` | five panels: hour-of-day curves by sport, day-of-week bars, month seasonality, hour × day heatmap, indexed price response. **The accept criterion for the dataset.** |
| `pricing_metrics.json` | `train_pricing.py` | every number quoted anywhere else: ROC-AUC, PR-AUC, Brier + Brier skill, log loss, confusion matrix, the **measured Bayes-optimal ceiling**, split sizes, calibration bins, permutation importance, slice metrics, the full hyperparameter search, and all release-gate results |
| `model_card_pricing.md` | `train_pricing.py` | intended use, training data + its limitations, features **and the deliberate exclusions**, metrics against the ceiling, the price optimizer's contract, retraining trigger. Script-written, so it cannot drift from the artifact it describes |
| `calibration_pricing.png` | `train_pricing.py` | three panels: reliability (predicted vs observed, 10 quantile bins), where the predictions sit split by outcome, and predicted vs **true** probability |
| `price_response_pricing.png` | `train_pricing.py` | two panels on one shared x-axis: P(book) across the swept band, then expected revenue indexed to the list price with the recommendation circled and the policy cap marked |
| `importance_pricing.png` | `train_pricing.py` | permutation importance over the eleven contract columns, measured as **Brier** damage — 5 repeats, with error bars |
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

It runs over **24 representative slot profiles**, not one — six venues (cheapest,
dearest, median tier, an unrated one, one per sport) crossed with four scenarios
(weekend peak, weekday peak, weekday off-peak, weekend shoulder). One hand-picked slot
passing is weak evidence; a model can be well-behaved on the evening block and inverted
at 10:00 on a Tuesday.

And it checks **two** conditions, because either alone is gameable: no single 5% step may
rise by more than a small tolerance, *and* the end-to-end fall across the band must
exceed a floor. A perfectly flat curve is monotonically non-increasing and is not a
price response — it is a model that ignored the price feature, which would make every
suggestion identical.

Eleven other gates sit beside it — twelve in total — and are listed in both
`pricing_metrics.json` and the
model card. The ones worth knowing about: the CSV's sha256 must still match
`bookings_meta.json` (a card that names a dataset it wasn't trained on is worse than no
card); the logistic baseline's `price_ratio` coefficient must be **negative** (a signed,
readable number that sign-checks the entire premise — a gradient-boosted tree would fit
an inverted price response in silence); and not every profile may pin to the floor of the
band, because "charge the least you are allowed to" is monotone, well-calibrated, and
commercially useless.

## Why a near-perfect score would be bad news

Training data is synthetic (see `data/README.md` for the measurement that forces
that). The labels are drawn stochastically from the latent demand, so a model
**cannot** reach ROC-AUC ≈ 1.0 by inverting the generator. If a run reports 0.99,
the correct conclusion is that a feature is leaking the label — not that the model is
excellent. A committee that has seen this before will ask.

## Why there is a "ceiling" column, and why it is the strongest thing in the report

Because the data is simulated, the generator recorded `latent_p` — the true probability
each label was drawn from. Scoring `latent_p` *itself* against the realised labels
measures **the best score any model could possibly achieve on those rows**. That number
is computed on every run and reported beside the model's own.

It changes what the headline metrics mean. "ROC-AUC 0.78" is a number nobody can judge.
"ROC-AUC 0.78 against a measured ceiling of 0.80 — 97% of what is attainable" is a
statement about whether the model is still underfitting or has extracted nearly all the
available signal, and it is checkable. It also converts the wave's arbitrary `> 0.80`
target into a *measured* one: if the ceiling on this dataset sits below 0.80, then a
score above 0.80 is not an achievement, it is proof of a leak — so `train_pricing.py`
gates on attainment against the ceiling and says in the model card that it did.

`latent_p` is used for **evaluation only**. It is never a feature: the matrix is built
by `features.build_frame`, which by construction can only see the eleven contract
columns. There is no `df.drop` anywhere in the pipeline, which is what makes that
guarantee structural rather than a promise.

Real production data will never come with a ceiling — that is precisely why it is worth
measuring now, while the pipeline is being validated.

---

## Why `demand_patterns.png` is a human gate, not decoration

The generator's twelve self-checks prove the dataset is internally *consistent* — price
is independent of demand, the feature contract round-trips, nothing leaks, the price
response is monotone. None of them can prove it is **plausible**. "Is a 21:00 football
peak of 3.4× against a 15:00 baseline realistic for Islamabad?" is not a question a
correlation coefficient can answer; it needs somebody who has booked a turf here.

So that figure exists to be **disagreed with**. Each panel is built so a domain expert
can falsify one specific claim at a glance:

| panel | the claim it exposes |
|---|---|
| hour-of-day, by sport | football peaks late (21:00); cricket is **bimodal** with a dawn peak; Ramadan **inverts** the night |
| day-of-week | Sat leads, Mon is dead — Pakistan's weekend is Sat–Sun. Sunday sits **above** Friday despite a lower `DOW_MULT`, because Friday's ×0.35 Jummah penalty outweighs its ×1.20 night bonus |
| month | seasonality is **bimodal** (spring + autumn), not one sine wave — read the **Ramadan-excluded** line for that claim (see below) |
| hour × day heatmap | the interactions: the Friday-Jummah notch, the weekend night block |
| price response, indexed | both segments fall, and **off-peak falls faster** — the evidence the data can teach pricing at all |

If a curve looks wrong, that is a finding about the *assumptions*, and every assumption
is one labelled block in `training/generate_bookings.py` with a stated reason. The
figure carries its own "SYNTHETIC — no row describes a real booking" footer, because it
will end up in a slide deck separated from this README.

**One caveat to hold while reading the hour panel.** Venues have real operating windows
(cricket grounds open 06:00, several football venues not until 16:00–17:00), so the set of
venues contributing to a given hour *changes across the x-axis*. A low football rate at
09:00 is partly "only three venues even offer 09:00", not purely "nobody wants 09:00".
This is honest — it is what a real market looks like, and it is why the panel plots the
booked *share* of offered slots rather than a count — but it means the far-left end of each
line rests on fewer venues than the peak does. The curve is still falsifiable where it
matters: the evening block is offered by every venue.

**The month panel plots two lines, and the reason is a finding.** On the first render
it carried one line, and that line put **March at the year's low (23%)** — even though
`MONTH_MULT[3] = 1.25` declares March the opening of the spring peak. Nothing was
broken. Ramadan 1447 runs **19 Feb – 19 Mar 2026**, and Ramadan collapses daytime
demand (0.017 booked vs 0.185 on ordinary days), so a raw monthly rate is not
seasonality — it is `MONTH_MULT × Ramadan`. Left alone, the panel invited a reader to
conclude the seasonal table was wrong.

The fix was to plot the Ramadan-excluded line beside it and band the affected months,
which makes the panel's claim stronger rather than weaker: the bimodal season is
genuinely present, **and Ramadan is a larger swing than any month multiplier in the
table**. Read the orange line for seasonality and the gap between the lines for
Ramadan's size. The band is computed from the data, not hardcoded, because the Hijri
window slides ~11 days earlier each solar year and a literal "Feb–Mar" would silently
lie for any other `--start`.

One honest limit on that line: it excludes **Ramadan**, not Eid. Eid al-Fitr 1447 falls
on **20 Mar 2026** — the day *after* Ramadan ends — so March keeps its ×0.35 Eid-day dip
and the ×1.45 rebound days that follow. Those two roughly offset in a monthly mean, which
is why the corrected March reads as a spring peak, but the orange line is "Ramadan
removed", not "every calendar effect removed".

The price-response panel is **indexed to each segment's cheapest price bin = 100**
rather than plotting raw booking rates. Peak and off-peak sit at very different levels,
and raw rates would make the off-peak line look flat purely because it is lower —
visually contradicting the true finding. Indexing to a common base is the correct
single-axis fix; a second y-axis would be the wrong one.

---

## Right now

Everything in the file table is written. `demand_patterns.png` came from Wave B; the
`train_pricing.py` outputs landed in Wave C.

Regenerate the model outputs alone (the dataset is untouched):

```
cd ml-service
python training/train_pricing.py
```

Two things to know about that run:

- **`models/pricing_latest.joblib` is written only if every gate passes.** On a failure
  the reports and a timestamped `models/pricing_<stamp>.joblib` are still written — so the
  failure is auditable and loadable rather than invisible — but the artifact the service
  actually reads is left alone. Exit code 1.
- **Once it succeeds, `/predict/price` and `/predict/demand` return `501 not_implemented`
  instead of `503 model_not_loaded`.** That is the correct and expected transition: the
  registry can now load a valid artifact, and wiring the inference path is Wave D. Both
  responses are passes in `backend/src/scripts/check_ml_service.js`.

Do **not** re-run `training/generate_bookings.py` to "refresh" anything. It would write a
new CSV with a new sha256, which invalidates the provenance recorded in
`data/bookings_meta.json`, in `pricing_metrics.json`, and in the model card — and the
dataset-provenance gate would then fail every subsequent training run until the
recorded hash is reconciled.
