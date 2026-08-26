# reports/

**Committed to git, deliberately.** This directory is the AI evidence trail.

`models/` holds a binary nobody can inspect and `data/` is regenerable and ignored.
This is the only place where the *claims* about the model live in a form a supervisor,
an external examiner, or a future maintainer can read and check. Written by the
training scripts themselves — `training/train_pricing.py` and
`training/train_sentiment.py` — on every run, so a report cannot go stale relative to
the artifact it describes.

**Two models write here now**, so every filename carries a `_<model>` suffix and no
file is shared between them except the environment lock. See the suffix note below.

| file | written by | contents |
|---|---|---|
| `demand_patterns.png` | `generate_bookings.py` → `demand_plots.py` | five panels: hour-of-day curves by sport, day-of-week bars, month seasonality, hour × day heatmap, indexed price response. **The accept criterion for the dataset.** |
| `pricing_metrics.json` | `train_pricing.py` | every number quoted anywhere else: ROC-AUC, PR-AUC, Brier + Brier skill, log loss, confusion matrix, the **measured Bayes-optimal ceiling**, split sizes, calibration bins, permutation importance, slice metrics, the full hyperparameter search, and all release-gate results |
| `model_card_pricing.md` | `train_pricing.py` | intended use, training data + its limitations, features **and the deliberate exclusions**, metrics against the ceiling, the price optimizer's contract, retraining trigger. Script-written, so it cannot drift from the artifact it describes |
| `calibration_pricing.png` | `train_pricing.py` | three panels: reliability (predicted vs observed, 10 quantile bins), where the predictions sit split by outcome, and predicted vs **true** probability |
| `price_response_pricing.png` | `train_pricing.py` | two panels on one shared x-axis: P(book) across the swept band, then expected revenue indexed to the list price with the recommendation circled and the policy cap marked |
| `importance_pricing.png` | `train_pricing.py` | permutation importance over the eleven contract columns, measured as **Brier** damage — 5 repeats, with error bars |
| `price_sanity.json` | `backend/src/scripts/check_price_sanity.js` | the served model answered through the real Node path: Friday 20:00 vs Tuesday 03:00, the rating pairs, a 24-hour demand curve, and the observations that are **recorded without a verdict** because the effect is smaller than the model's resolution |
| `sentiment_metrics.json` | `train_sentiment.py` | every number quoted anywhere else: validation and **domain-exam** accuracy / macro-F1 / per-class tables, both confusion matrices, the bootstrap CI on the exam, **per-language** breakdown (en / ru / code-mixed), the feature-branch ablation, two majority-class baselines, corpus composition + sha256, the abuse lexicon's hash, and all 7 release-gate verdicts. Also holds **`error_analysis` — the 20-row error table**, so there is no separate file to look for |
| `model_card_sentiment.md` | `train_sentiment.py` | intended use, the corpus and its licence-bound limits, the frozen normalisation contract, why the probabilities are **declared uncalibrated**, the abuse flag's contract, **how `C` was chosen** (the recorded validation sweep), and the retraining trigger. Script-written, so it cannot drift from the artifact |
| `confusion_matrix_sentiment.png` | `train_sentiment.py` | two panels: the 4,281-row validation split and the 200-row in-domain exam, side by side. Read them **together** — the gap between them is the finding, not a defect (see below) |
| `requirements.lock.txt` | `pip freeze` at train time | the FULL resolved environment, transitives included. **Shared** — whichever trainer ran last wrote it. Both run in the same `.venv`, so that is not a conflict, but it does mean the file is dated to the last run of *either* model |

### If you were sent here looking for `calibration.png` or `feature_importance.png`

The S.3 milestone lists the evidence pack by generic name. On disk the two plots
carry a `_pricing` suffix:

| asked for | on disk |
|---|---|
| `calibration.png` | `calibration_pricing.png` |
| `feature_importance.png` | `importance_pricing.png` |

`demand_patterns.png`, `pricing_metrics.json` and `model_card_pricing.md` are
exactly as listed. The suffix is not tidiness — every model after this one writes its
own evidence into this same committed directory, and a bare `calibration.png` would be
silently overwritten by whichever training script ran last. Every filename here is
`<what>_<model>` so that collision cannot happen, and so a reader can tell from the
filename alone which model a plot is evidence *for*. The names are literals in
`train_pricing.py` (≈ line 2407) rather than derived from a variable — a convention, so
each later model has to honour it deliberately. Keep the `_<model>` suffix.

**S.4 was the first test of that convention, and it very nearly lost.** The sentiment
model's plot is a confusion matrix, and `train_sentiment.py` originally wrote it as a
bare `confusion_matrix.png` — a name S.5's recommender would have had every reason to
reuse, at which point the sentiment evidence would have disappeared with no error and no
failing test. It is `confusion_matrix_sentiment.png` now. Nothing had broken yet; that
is exactly when the name is cheap to change.

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

## Sentiment (S.4): why the headline is the 200-row exam, not the 4,281-row validation split

The model reports two accuracies that look like they disagree:

| measured on | rows | accuracy | macro-F1 |
|---|---|---|---|
| validation split of the training corpus | 4,281 | 0.6447 | 0.6384 |
| `domain_test_200.csv` — held out, in-domain | 200 | **0.8250** | 0.8247 |

Scoring *higher* on the unseen set is the classic shape of a leak, so it is worth
stating plainly why it is not one here: **the two sets are not samples of the same
distribution.** The training corpus is 21,405 rows, of which **20,715 are third-party
open-domain text** (RUSA Roman-Urdu sentiment, TweetEval English) and only **690 are
hand-written venue reviews**. The exam is 200 hand-labelled venue reviews. So the
validation number answers *"can it label arbitrary tweets in two languages"* — a harder
and genuinely noisier task, with annotator disagreement baked into the labels it was
trained on — while the exam answers the question the feature is actually deployed to
answer. The exam is what the release gate reads, and the leakage gate asserts validation
≤ 0.995 in the other direction, so an implausibly *high* validation score cannot slip
through unremarked either.

**But 200 rows is 200 rows.** That is why the bootstrap CI is reported and belongs in
any sentence that quotes the headline: **[0.7700, 0.8750]** over 2,000 resamples. The
lower bound sits *below* the 0.80 target. The defensible claim is "0.825 measured, true
in-domain accuracy somewhere around 0.77–0.88", not "this model is 82.5% accurate". A
later retrain reading 0.81 or 0.84 has not changed anything real, and should not be
described as an improvement or a regression.

## The per-language rows, weakest first

| exam subset | rows | accuracy |
|---|---|---|
| English | 50 | **0.7600** |
| code-mixed | 70 | 0.8286 |
| Roman Urdu | 80 | 0.8625 |

English is the **worst** of the three, on a corpus that contains 9,295 English training
rows. The cause is not established here — it could be that TweetEval's open-domain
English is a poor proxy for a short venue review, and it could be sample size, since
0.7600 is 38 of 50 and two rows move it four points. Nothing in this report measures
which, so nothing in this report claims to know.

It is listed first deliberately. Quoting 0.8625 for Roman Urdu is the flattering
reading, and the weakest subset is the one that tells a maintainer where the next
annotation effort should go.

## Why the report declares the probabilities uncalibrated

`classifier.probability.calibrated` is `false`, and the API echoes that to every caller.
The estimator is a `LinearSVC` whose `decision_function` is pushed through a softmax, so
the three numbers sum to 1 and rank correctly, but they are **not** frequencies — a 0.77
does not mean "77 of 100 such reviews are positive".

That is an acceptable trade *for this model* and would not have been for the pricing
one. The pricing engine multiplies its probability by a rupee amount, so absolute
correctness is the whole product (hence the Brier section above). Sentiment uses the
probability only to rank and to threshold, both of which a monotone transform preserves:
`argmax(predict_proba)` equals `predict()` exactly, and the smoke suite asserts that
equality against the released artifact on every probe. Saying so out loud is what stops
a later feature — a "94% confident" badge in the owner dashboard, say — from being built
on a number that was never a frequency.

## Why the abuse flag's threshold is a measured number rather than a round one

The FR9.10 escalation fires when `P(negative)` clears a threshold. That constant shipped
at **0.90** and had gone very nearly dead: on the 200-row exam it fired **twice**. Every
release gate passed, the smoke suite passed (it only asserts the threshold is a float),
and the model card still described the feature in the present tense. Nothing anywhere
reported that a shipped rule had quietly stopped working.

The cause is mechanical, and it generalises. These probabilities are
`softmax(decision_function)`, so their sharpness tracks the margin width, which tracks
`C`. Retuning `C` from 3.0 to 0.1 — a change made for accuracy, on validation evidence,
and correct on its own terms — pulled the maximum P(negative) on the exam from 0.9811
down to 0.9234. The threshold never moved; the scale underneath it did. **An absolute
probability threshold is a property of one trained model's score scale, not a portable
definition of "very negative."** Retuning any hyperparameter that widens or narrows the
margins silently revalues every such constant.

`training/validate_neg_threshold.py` exists to make that visible. It opens the exam
read-only, prints the P(negative) distribution, warns loudly if the shipped value sits
above the observed maximum (a provably dead rule), and tabulates precision and recall
across candidates. It decides nothing — a human reads the table and picks the constant:

| threshold | escalated | correct | precision | recall of true negatives |
|---|---|---|---|---|
| 0.60 | 30 | 29 | 0.9667 | 0.4265 |
| **0.70** | **18** | **18** | **1.0000** | **0.2647** |
| 0.80 | 5 | 5 | 1.0000 | 0.0735 |
| 0.90 | 2 | 2 | 1.0000 | 0.0294 |
| 0.95 | 0 | 0 | — | 0.0000 |

**0.70 ships.** Precision is read first: this flag asks a venue owner to look *now*, so a
false escalation spends their attention, whereas a missed one is still carried by the
ordinary negative label on the review itself. Recall of 0.2647 is therefore not the
failure it resembles — the rule is a "read this one first" queue, not a classifier, and
the 18 rows it surfaces are withheld refunds, unlit pitches, and a fraud complaint.

Two things now guard the constant. `train_sentiment.py` counts the exam escalations on
every run, **warns** when fewer than five fire, and records the count in
`sentiment_metrics.json` (`toxicity.examEscalations`, currently 18 of 200) so the number
lives in the evidence trail instead of in someone's memory. The warning is deliberately
not a gate: a genuinely quieter model may ship, it simply may not ship *silently*. And
`app/routers/sentiment.py` reads the threshold from the artifact's own metadata rather
than a constant, so a retrain carries its own value forward. The router's hardcoded
fallback applies only to an artifact with no metadata and is set **loose** on purpose —
an over-eager escalation is visible and gets reported, while one that never fires looks
exactly like a well-behaved quiet feature.

## Reading `ablation_exam_accuracy` — it is not a configuration comparison

| view | exam accuracy |
|---|---|
| word branch only | 0.7800 |
| char branch only | 0.7650 |
| word + char | 0.8100 |
| **shipped model** | **0.8250** |

Two traps in four rows.

**Every ablation is fitted at the run's own `C`** (here 0.1), because an ablation should
vary one thing. That means the rows compare *feature views at one regularisation
setting* — not what each view would score if tuned for itself. At `C=3.0` the char-only
row outranked the union; at `C=0.1` it does not. Neither ordering is a recommendation,
and the reason is that regularisation strength scales with feature-space size: char-only
is ≈50k features and wanted `C=3.0`, the union is ≈100k and wants `C=0.1`.

**`word+char` is the shipped feature set yet reads 0.8100, not 0.8250.** Not a
contradiction: the ablations fit on the 17,124-row train split so their scores stay
comparable to each other, while the shipped artifact is refitted on the full 21,405-row
corpus once the split has done its job. The gap is 4,281 extra training rows, not a
different model.

## Why both branches ship, when char-only once scored higher

Because `char_wb` **cannot cross a word boundary** — scikit-learn pads each word
separately — and Roman Urdu post-poses its negation across two words: *"acha nahi tha"*
(good / not / was). That phrase is literally unrepresentable in the char branch, no
matter how many n-grams it is given. Only the word branch, where negation scoping can
attach `_neg` to the following tokens, can express it.

The ablation table is a snapshot at one `C` and will reorder again. The mechanism is why
both branches are in the pipeline.

## Right now (end of S.4 Wave B)

The served artifact is **`sentiment-wordchar-linsvc-softmax-20260826-1306`** — exam
accuracy 0.8250 (CI 0.77–0.88) against a majority-class baseline of 0.3400, all **7**
release gates passed, normalisation contract `sentiment-norm-v1` fingerprint
`b96e65df85f9692b`. Every number is in `sentiment_metrics.json`; nothing here is typed
by hand.

```
cd ml-service
python training/train_sentiment.py
```

**No flags.** That is deliberate and it is a claim worth checking: the defaults in
`train_sentiment.py` *are* the shipped configuration (`--branches both`, `--C 0.1`,
`--upweight-authored 40`, `--seed 42`), so a bare invocation reproduces the released
model rather than some nearby variant. A tuned model whose reproduction command carries
four flags nobody recorded is not reproducible in practice.

Three things to know:

- **`models/sentiment_latest.joblib` is written only if the exam clears 0.80.** On a
  failure the reports and a timestamped `models/sentiment_<stamp>.joblib` are still
  written, so the failure is auditable, but the served artifact is left alone.
- **`C` is tuned to the current feature set.** Change `--branches` or
  `--upweight-authored` and `C=0.1` stops being the right value — the recorded
  validation sweep in the model card is what to re-run, and the sweep's shape matters:
  0.1 is an *interior* maximum (0.6447, falling off on both sides), which is what a real
  regularisation optimum looks like. A best value sitting at the edge of the swept range
  would only mean the range was too narrow.
- **A retrain does not hot-swap the served model.** Restart uvicorn or call
  `registry.reload('sentiment')`, or `/health` keeps reporting the previous
  `modelVersion`.

`data/sentiment/domain_test_200.csv` is the exam. Never train on it, never regenerate
it, and never "fix" a row because the model got it wrong — at that point the 0.8250 stops
measuring anything. Its sha256 is recorded in `domain_test_meta.json` and a release gate
re-checks it on every run, which is what makes that instruction enforceable rather than
aspirational.

---

## Right now — pricing (end of S.3)

Everything in the file table is written. `demand_patterns.png` came from Wave B; the
`train_pricing.py` outputs landed in Wave C; `price_sanity.json` in Wave E.

The served artifact is **`pricing-v1-20260825-0041`** — ROC-AUC 0.7628 against a
measured Bayes ceiling of 0.7770, Brier 0.1680 (skill +0.1668), 6,244 held-out rows,
all 12 gates passed. Every one of those numbers is in `pricing_metrics.json`; nothing
in this directory is typed by hand.

Regenerate the model outputs alone (the dataset is untouched):

```
cd ml-service
python training/train_pricing.py --seed 42
```

**68 seconds** end to end. `--seed 42` is not an example — it is the run that
produced the artifact above, and re-running it is **bit-for-bit reproducible**: nine
metrics to six decimal places, the same winning hyperparameters, the same
`csvSha256`, the same 12 gate verdicts. That is the reproducibility claim in the S.3
milestone, and it is checkable in one command.

It ends by printing a metrics table — this model beside a plain `LogisticRegression`
on the same split, beside the Bayes-optimal ceiling. Read that ordering as intended:
the baseline column is there so the boosted model has to earn its complexity, and
the ceiling column turns "is 0.76 good?" (unanswerable) into "is 0.76 near the best
any model could score on these rows?" (98.2% — yes).

Three things to know about that run:

- **`models/pricing_latest.joblib` is written only if every gate passes.** On a failure
  the reports and a timestamped `models/pricing_<stamp>.joblib` are still written — so the
  failure is auditable and loadable rather than invisible — but the artifact the service
  actually reads is left alone. Exit code 1.
- **It overwrites this directory.** To rehearse the command — before a demo, say —
  send both outputs somewhere disposable so the committed evidence is never at risk:

  ```
  python training/train_pricing.py --seed 42 `
    --models-dir .rehearsal\models --reports-dir .rehearsal\reports
  ```

  That exercises the full path, plots and `joblib.dump` included, and takes the same
  68 s. (`--no-write` is faster at 61 s but skips the write, so it rehearses less.)
- **A retrain does not hot-swap the served model.** A running `ml-service` holds its
  artifact in memory from boot. Restart uvicorn, or the owner dashboard keeps
  reporting the previous `model_version` — which is a bad thing to discover while
  pointing at the screen.

Do **not** re-run `training/generate_bookings.py` to "refresh" anything. It would write a
new CSV with a new sha256, which invalidates the provenance recorded in
`data/bookings_meta.json`, in `pricing_metrics.json`, and in the model card — and the
dataset-provenance gate would then fail every subsequent training run until the
recorded hash is reconciled.
