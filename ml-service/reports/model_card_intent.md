# Model Card -- SportLynk Assistant Intent Classifier (Model #4, NLU half)

- **Model key**: `intent`  
- **Version**: `intent-v1-20260828-0053`  
- **Trained (UTC)**: 2026-08-28T00:53:50+00:00  
- **Label contract**: `assistant-intents-v1` (`7bb78a3ac94cbdef`)  
- **Dataset contract**: `assistant-dataset-v1` (`0eb01bc58b4a040f`)  
- **Text contract**: `nlu-text-v1` (`eca8d0423d2084b3`)  
- **Entity contract (served alongside)**: `nlu-entities-v1` (`34aee7e75192e6fe`)  
- **Abstain floor**: `0.45` (stamped in the artifact; the router reads it from there)  
- **Released** (passed all 10 gates): **True**

Maps a raw utterance (English / Roman Urdu / code-switched) to one of 15 assistant intents with sigmoid-calibrated probabilities. The artifact accepts RAW text -- normalisation lives inside the pipeline, so training and serving run identical code. It is HALF of model #4: `app/core/entities.py` (rules) extracts date/time/sport/area/budget, and `POST /nlu/parse` returns both. Neither half acts on anything; the Node dialog manager owns every business rule, so a wrong intent costs a wrong menu, never a wrong booking.

## Headline

| split | n | accuracy | macro F1 |
|---|---|---|---|
| validation (template-disjoint, tuning) | 348 | 0.8678 | 0.8662 |
| **exam** (sha-locked, hand-written, never tuned on) | 150 | **0.6200** | 0.6129 |

Exam accuracy 95% CI (bootstrap, 2000 resamples): [0.5400, 0.7000] -- roughly +-0.08 on 150 rows. Every hyperparameter difference measured on the exam during development was INSIDE that interval, which is why the configuration was selected on validation and the exam was only ever read as a final report.

### Why validation is high and the exam is not

Not leakage -- gate 4 recomputes exact and near-duplicate overlap between all 1680 corpus rows and all 150 exam rows on every run (this run: 0 exact, max near-dup 0.5 < 0.8). The exam is a deliberate distribution shift: it is hand-written, 46% of its rows are tagged `boundary` (written to sit between two intents) and 31% `indirect`. The corpus teaches surface forms rendered from templates; the exam asks for paraphrase understanding.

Scored at intent-GROUP resolution the exam is 0.6733 (6 classes) against 0.6200 at intent resolution. That small gap is the important diagnostic: the residual errors are NOT near misses inside a group that a clarifying question would fix -- they cross groups.

## The 0.45 abstain floor (validated on validation, never on the exam)

Serving rule: `confidence < 0.45` -> reply `out_of_scope` and show the fallback menu. `out_of_scope` is also a trained label, and the two are different mechanisms: the label catches utterances that LOOK off-topic, the floor catches utterances the model cannot place.

| threshold | coverage | accuracy when it answers | served accuracy | confident errors |
|---|---|---|---|---|
| 0.00 | 1.0000 | 0.8678 | 0.8678 | 46 |
| 0.30 | 0.9741 | 0.8820 | 0.8621 | 40 |
| 0.35 | 0.9454 | 0.8997 | 0.8534 | 33 |
| 0.40 | 0.9195 | 0.9125 | 0.8477 | 28 |
| 0.45 **<- ships** | 0.8764 | 0.9246 | 0.8247 | 23 |
| 0.50 | 0.8305 | 0.9343 | 0.7902 | 19 |
| 0.55 | 0.7615 | 0.9472 | 0.7414 | 14 |
| 0.60 | 0.7011 | 0.9549 | 0.6983 | 11 |
| 0.70 | 0.5259 | 0.9891 | 0.5690 | 2 |

*served accuracy* scores what the user actually receives (an abstention IS the `out_of_scope` answer), which is why it is the honest serving number; counting every abstention as a miss instead gives 0.8103. The floor buys a smaller number of CONFIDENT wrong answers at the cost of abstaining on rows it would have got right -- a fallback menu costs the user one tap, a confident wrong intent cancels the wrong booking.

## Calibration: why sigmoid here when the sentiment model rejected it

| variant | val accuracy | coverage @0.45 | ECE (10-bin) |
|---|---|---|---|
| softmax | 0.8477 | 0.0029 | 0.6421 |
| sigmoid_random | 0.8621 | 0.8879 | 0.1736 |
| sigmoid_sgroup **<- ships** | 0.8678 | 0.8764 | 0.1854 |

Softmax over 15 one-vs-rest margins spreads its mass across 15 columns: the highest confidence it produces anywhere on validation is 0.4503, so a 0.45 floor would refuse almost every utterance. With 3 classes (the sentiment model) softmax clears such a floor easily; with 15 it cannot. Accuracy is a wash -- the difference is entirely whether the number attached to a prediction can be reasoned about, and the assistant's whole fallback policy is a threshold on that number. Gates 9 and 10 fail a softmax build mechanically rather than relying on a reader noticing.

Calibration folds are `StratifiedGroupKFold(5)` grouped by `template_id`, not a random k-fold: template siblings differ by one slot value, so random folds fit the sigmoid on margins the SVM has already memorised. Validation cannot see the difference (it is itself template-disjoint); the exam can.

Validation ECE 0.1854 (gate: <= 0.25); exam ECE 0.0829. Reliability bins are in `reports/intent_metrics.json` and plotted in `reports/intent_reliability.png`.

### Reliability (validation)

| confidence bin | rows | observed accuracy | mean confidence |
|---|---|---|---|
| 0.2-0.3 | 9 | 0.3333 | 0.2663 |
| 0.3-0.4 | 19 | 0.3684 | 0.3451 |
| 0.4-0.5 | 31 | 0.7097 | 0.4495 |
| 0.5-0.6 | 45 | 0.8222 | 0.5504 |
| 0.6-0.7 | 61 | 0.8525 | 0.6557 |
| 0.7-0.8 | 75 | 0.9733 | 0.7440 |
| 0.8-0.9 | 75 | 1.0000 | 0.8493 |
| 0.9-1.0 | 33 | 1.0000 | 0.9194 |

## Per intent (exam)

| intent | group | precision | recall | f1 | support |
|---|---|---|---|---|---|
| book_venue | booking | 0.556 | 0.500 | 0.526 | 10 |
| cancel_booking | booking | 1.000 | 0.400 | 0.571 | 10 |
| check_availability | discovery | 0.500 | 0.600 | 0.545 | 10 |
| create_team_help | team | 0.909 | 1.000 | 0.952 | 10 |
| find_opponents | team | 0.556 | 0.500 | 0.526 | 10 |
| find_venue | discovery | 0.800 | 0.800 | 0.800 | 10 |
| greeting | social | 0.750 | 0.900 | 0.818 | 10 |
| my_bookings | booking | 0.364 | 0.400 | 0.381 | 10 |
| out_of_scope | social | 0.389 | 0.700 | 0.500 | 10 |
| refund_policy | info | 0.615 | 0.800 | 0.696 | 10 |
| team_stats | team | 0.727 | 0.800 | 0.762 | 10 |
| topup_help | account | 0.500 | 0.600 | 0.545 | 10 |
| tournament_list | info | 0.857 | 0.600 | 0.706 | 10 |
| venue_info | info | 0.625 | 0.500 | 0.556 | 10 |
| wallet_balance | account | 0.667 | 0.200 | 0.308 | 10 |

### Where it actually fails (exam)

| gold | predicted | rows | declared confusable in the spec? |
|---|---|---|---|
| book_venue | out_of_scope | 2 | NO |
| cancel_booking | my_bookings | 2 | NO |
| check_availability | venue_info | 2 | NO |
| find_opponents | greeting | 2 | NO |
| my_bookings | check_availability | 2 | yes |
| my_bookings | out_of_scope | 2 | NO |
| tournament_list | my_bookings | 2 | NO |
| wallet_balance | my_bookings | 2 | NO |
| wallet_balance | topup_help | 2 | yes |
| book_venue | check_availability | 1 | yes |

`intent_spec.INTENT_CATALOG` declares which intent pairs are expected to be confusable. A `NO` in that last column is a mistake nobody predicted, and is the most useful line in this card for whoever extends the corpus next.

## Slices (exam)

| language | n | accuracy | macro F1 |
|---|---|---|---|
| en | 45 | 0.5111 | 0.4691 |
| mix | 45 | 0.7778 | 0.7743 |
| ru | 60 | 0.5833 | 0.5569 |

English is the WEAKEST slice, which is counter-intuitive until you read the rows: the exam's English utterances are its most idiomatic and indirect ones, while the Roman Urdu and mixed rows still carry the strong lexical anchors (`kal`, `slot`, `wallet`) that `char_wb` picks up.

| phenomenon | n | accuracy | macro F1 |
|---|---|---|---|
| boundary | 69 | 0.6232 | 0.6383 |
| code_switch | 34 | 0.7941 | 0.6410 |
| ellipsis | 21 | 0.6667 | 0.5914 |
| imperative | 4 | 0.7500 | 0.1778 |
| indirect | 46 | 0.4565 | 0.3924 |
| misspelled_venue | 2 | 1.0000 | 0.1333 |
| multi_slot | 12 | 0.7500 | 0.1111 |
| negation | 11 | 0.3636 | 0.1378 |
| numeric | 21 | 0.6190 | 0.4048 |
| plain | 1 | 0.0000 | 0.0000 |
| politeness | 2 | 1.0000 | 0.0667 |
| question | 59 | 0.7288 | 0.7067 |
| run_on | 38 | 0.5526 | 0.4870 |
| short | 28 | 0.6429 | 0.5904 |
| slang | 11 | 0.4545 | 0.2311 |
| sms_speak | 5 | 0.8000 | 0.2000 |
| typo | 7 | 0.7143 | 0.2444 |

Rows carry several tags, so these slices overlap and do not sum to 150.

## Training data

- `data/assistant/intents.csv` -- 1680 rows, sha256 `c539b8fc4057cfe6...`  
- split: 1332 train / 348 val, grouped by `template_id` so no template appears on both sides  
- languages: en 675, mix 420, ru 585  
- sources: authored 236, template 1444  
- exam: `data/assistant/assistant_test.csv` -- 150 rows, sha256 `f99691aa112957a5...`, 10 per intent, hand-written in Wave A and never trained on

The SHIPPED artifact is refitted on ALL 1680 rows (train + validation) after the configuration was frozen. The validation split exists to ESTIMATE generalisation, not to be thrown away: once the estimate is taken, throwing away 348 labelled rows to preserve a number nobody will re-read is the worse trade. Both fits are reported -- split-fit exam accuracy 0.6467 vs full-refit 0.6200, a difference well inside the bootstrap CI.

## Pipeline

```
FeatureUnion(
  word: nlu_text.prep -> TfidfVectorizer(word,    (1, 2), token_pattern='\\S+', min_df=1, max_features=50000)
  char: nlu_text.prep -> TfidfVectorizer(char_wb, (2, 6), min_df=1, max_features=80000)
)
-> CalibratedClassifierCV (C=0.5, class_weight=balanced) -> sigmoid_calibration
```

Vocabulary actually learned: 5232 word n-grams + 9988 char n-grams = 15220 features.

### How each knob was chosen (validation only)

| knob | chosen | alternatives measured |
|---|---|---|
| char analyzer | `char_wb` | char_wb 0.8678 vs char 0.8218 (-4.6 pts, 16 rows: the decisive knob) |
| char ngram_range | `(2, 6)` | (2,6) 0.8678 vs (3,5) 0.8649 vs (2,5) 0.8621 (<=2 rows apart: noise) |
| word ngram_range | `(1, 2)` | (1,2) 0.8678 vs (1,1) 0.8592 (3 rows) |
| min_df | `1` | min_df=1 0.8678 vs min_df=2 0.8506 (-1.7 pts: 1,680 rows is too few to prune) |
| token_pattern | `\S+` | \S+ 0.8678 vs the sklearn default \b\w\w+\b 0.8649; the default splits <num>/<qm>/<emo> into bare words and loses the placeholder |

### C sweep (validation selects; the exam column is reported, not used)

| C | val accuracy | val macro F1 | coverage @0.45 | acc answered | exam accuracy |
|---|---|---|---|---|---|
| 0.25 | 0.8563 | 0.8552 | 0.874 | 0.9178 | 0.6667 |
| 0.5 **<- chosen** | 0.8678 | 0.8662 | 0.876 | 0.9246 | 0.6467 |
| 1.0 | 0.8649 | 0.8623 | 0.871 | 0.9274 | 0.6467 |
| 2.0 | 0.8621 | 0.8592 | 0.876 | 0.9279 | 0.6400 |
| 4.0 | 0.8621 | 0.8592 | 0.891 | 0.9258 | 0.6333 |
| 8.0 | 0.8621 | 0.8592 | 0.879 | 0.9281 | 0.6267 |

The plateau is flat -- the whole sweep spans 0.0115 on validation, which is 4 rows out of 348. C=0.5 is the validation maximum; the exam maximum is C=0.25, and picking THAT would have been tuning on the exam. Reproduce the sweep with `--sweep-c`.

### Ablation (fitted on train, uncalibrated, single C)

| features | val accuracy | exam accuracy |
|---|---|---|
| word_only | 0.7356 | 0.6000 |
| char_only | 0.8534 | 0.6467 |
| word+char | 0.8477 | 0.6467 |
| word+char_logreg | 0.8448 | 0.6400 |

What the table actually says: the char view is doing the heavy lifting. Word n-grams alone are the weakest arm (0.7356 val / 0.6000 exam) because a template corpus gives them word ORDER to memorise and little else, while char_wb alone (0.8534 / 0.6467) reads across the Roman Urdu spelling variants. Adding the word view on top of char moves validation by 2 rows of 348 and the exam by 0 rows of 150 -- i.e. it is not measurably better on THIS corpus. The union ships regardless, for one reason that the ablation cannot show: the word branch is the only place the `<num>`, `<qm>` and `<emo>` placeholders survive as whole tokens, and those are what separate a question from an imperative once real users stop writing like templates. Note also that these rows are UNCALIBRATED single-C fits used to isolate views -- the shipped calibrated model scores 0.8678 val, above every row here.

The `word+char_logreg` row is a solver control, not a candidate: LogisticRegression on the same features scores 0.8448 val / 0.6400 exam, within 1 row of the linear SVM on validation. The SVM ships because it is what S.4 established and because it trains in under a second, NOT because it was measurably better.

## Baselines

| baseline | exam accuracy |
|---|---|
| uniform random over 15 intents | 0.0667 |
| always `find_opponents` (train majority) | 0.0667 |
| **this model** | **0.6200** |

## Release gates

| # | gate | result | detail |
|---|---|---|---|
| 1 | contracts | PASS | nlu_text 17 checks + intent_spec 14 receipts clean; entities nlu-entities-v1/34aee7e75192e6fe |
| 2 | corpus provenance | PASS | 1680 rows, sha c539b8fc4057, meta all_passed, fingerprints match |
| 3 | exam provenance | PASS | 150 rows, sha f99691aa1129, locked and unedited |
| 4 | exam uncontaminated | PASS | 0 exact, max near-dup 0.5000 (word_set) < 0.8 |
| 5 | no leakage | PASS | val accuracy 0.8678 <= 0.995 (a near-perfect val score on a template-grouped split would mean the split leaked) |
| 6 | beats baseline | PASS | exam 0.6200 >= majority 0.0667 + 0.1 |
| 7 | exam floor | PASS | exam accuracy 0.6200 >= 0.55 |
| 8 | answers well | PASS | exam accuracy on the 114 rows it answers 0.7368 >= 0.65 |
| 9 | answers at all | PASS | val coverage at floor 0.45 = 0.8764 >= 0.6 |
| 10 | calibrated | PASS | val ECE 0.1854 <= 0.25 (10-bin, top-label) |

## Intended use, and what this model must never be trusted with

**Use it for**: routing an in-app assistant message to one of 15 intents so the Node dialog manager can pick a reply, a form, or a clarifying question; and for logging what users ask so the corpus can grow.

**Do not use it for**: taking any action on its own. Every booking, cancellation, refund and wallet movement stays behind the existing Express routes with their existing auth, validation and DB constraints (FR8.15). The assistant may PREPARE a booking payload; the user still confirms it and the same route that the normal UI calls executes it.

**Known weaknesses**, all measured above, none hidden:

1. Indirect paraphrase. It matches SHAPE, not meaning. `wallet_balance` phrased as "whats sitting in there right now" goes wrong.
2. `wallet_balance` is the weakest intent on the exam; the confusion table above names every pair.
3. It cannot handle multi-intent utterances -- one label per message by construction. "cancel tomorrow and rebook Friday" gets one of the two.
4. Roman Urdu spelling variance beyond what the corpus covers falls back on char n-grams and degrades quietly (into a low-confidence prediction, which is what the floor is for).
5. Nothing here is a language model. It has no memory of the conversation, no world knowledge, and no ability to answer a question it was not trained to recognise -- which is the honest reason the escalate-to-owner design exists.

**Retraining**: `python training/train_intents.py`. It is safe to re-run; it never touches the database, reads only the two CSVs, and refuses to overwrite `models/intent_latest.joblib` unless all 10 gates pass. If the label set changes, `intent_spec.INTENT_SPEC_VERSION` must change with it -- the registry compares fingerprints at load and a mismatch takes the route to 503 rather than serving a model that predicts labels the service no longer knows.

---

Generated by `training/train_intents.py` on 2026-08-28T00:53:50+00:00 -- every number above is read out of the same run that wrote the artifact.
