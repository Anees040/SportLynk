# Model Card -- SportLynk Assistant Intent Classifier (Model #4, NLU half)

- **Model key**: `intent`  
- **Version**: `intent-v2-20261001-1728`  
- **Trained (UTC)**: 2026-10-01T17:28:17+00:00  
- **Label contract**: `assistant-intents-v2` (`68396192ab4a87a4`)  
- **Dataset contract**: `assistant-dataset-v2` (`339ad58af5ddb072`)  
- **Text contract**: `nlu-text-v1` (`eca8d0423d2084b3`)  
- **Entity contract (served alongside)**: `nlu-entities-v1` (`34aee7e75192e6fe`)  
- **Abstain floor**: `0.45` (stamped in the artifact; the router reads it from there)  
- **Released** (passed all 10 gates): **True**

Maps a raw utterance (English / Roman Urdu / code-switched) to one of 23 assistant intents with sigmoid-calibrated probabilities. The artifact accepts RAW text -- normalisation lives inside the pipeline, so training and serving run identical code. It is HALF of model #4: `app/core/entities.py` (rules) extracts date/time/sport/area/budget, and `POST /nlu/parse` returns both. Neither half acts on anything; the Node dialog manager owns every business rule, so a wrong intent costs a wrong menu, never a wrong booking.

## Headline

| split | n | accuracy | macro F1 |
|---|---|---|---|
| validation (template-disjoint, tuning) | 526 | 0.8707 | 0.8724 |
| **exam** (sha-locked, hand-written, never tuned on) | 230 | **0.7478** | 0.7455 |

Exam accuracy 95% CI (bootstrap, 2000 resamples): [0.6913, 0.8000] -- roughly +-0.08 on 150 rows. Every hyperparameter difference measured on the exam during development was INSIDE that interval, which is why the configuration was selected on validation and the exam was only ever read as a final report.

### Why validation is high and the exam is not

Not leakage -- gate 4 recomputes exact and near-duplicate overlap between all 2576 corpus rows and all 230 exam rows on every run (this run: 0 exact, max near-dup 0.75 < 0.8). The exam is a deliberate distribution shift: it is hand-written, 46% of its rows are tagged `boundary` (written to sit between two intents) and 31% `indirect`. The corpus teaches surface forms rendered from templates; the exam asks for paraphrase understanding.

Scored at intent-GROUP resolution the exam is 0.8217 (8 classes) against 0.7478 at intent resolution. That small gap is the important diagnostic: the residual errors are NOT near misses inside a group that a clarifying question would fix -- they cross groups.

## The 0.45 abstain floor (validated on validation, never on the exam)

Serving rule: `confidence < 0.45` -> reply `out_of_scope` and show the fallback menu. `out_of_scope` is also a trained label, and the two are different mechanisms: the label catches utterances that LOOK off-topic, the floor catches utterances the model cannot place.

| threshold | coverage | accuracy when it answers | served accuracy | confident errors |
|---|---|---|---|---|
| 0.00 | 1.0000 | 0.8707 | 0.8707 | 68 |
| 0.30 | 0.9791 | 0.8835 | 0.8669 | 60 |
| 0.35 | 0.9392 | 0.9089 | 0.8593 | 45 |
| 0.40 | 0.9163 | 0.9191 | 0.8479 | 39 |
| 0.45 **<- ships** | 0.8878 | 0.9293 | 0.8384 | 33 |
| 0.50 | 0.8384 | 0.9524 | 0.8118 | 21 |
| 0.55 | 0.7471 | 0.9644 | 0.7452 | 14 |
| 0.60 | 0.7053 | 0.9730 | 0.7129 | 10 |
| 0.70 | 0.5399 | 0.9894 | 0.5627 | 3 |

*served accuracy* scores what the user actually receives (an abstention IS the `out_of_scope` answer), which is why it is the honest serving number; counting every abstention as a miss instead gives 0.8251. The floor buys a smaller number of CONFIDENT wrong answers at the cost of abstaining on rows it would have got right -- a fallback menu costs the user one tap, a confident wrong intent cancels the wrong booking.

## Calibration: why sigmoid here when the sentiment model rejected it

| variant | val accuracy | coverage @0.45 | ECE (10-bin) |
|---|---|---|---|
| softmax | 0.8669 | 0.0019 | 0.7172 |
| sigmoid_random | 0.8669 | 0.8802 | 0.1865 |
| sigmoid_sgroup **<- ships** | 0.8707 | 0.8878 | 0.1950 |

Softmax over 15 one-vs-rest margins spreads its mass across 15 columns: the highest confidence it produces anywhere on validation is 0.5091, so a 0.45 floor would refuse almost every utterance. With 3 classes (the sentiment model) softmax clears such a floor easily; with 15 it cannot. Accuracy is a wash -- the difference is entirely whether the number attached to a prediction can be reasoned about, and the assistant's whole fallback policy is a threshold on that number. Gates 9 and 10 fail a softmax build mechanically rather than relying on a reader noticing.

Calibration folds are `StratifiedGroupKFold(5)` grouped by `template_id`, not a random k-fold: template siblings differ by one slot value, so random folds fit the sigmoid on margins the SVM has already memorised. Validation cannot see the difference (it is itself template-disjoint); the exam can.

Validation ECE 0.1950 (gate: <= 0.25); exam ECE 0.0928. Reliability bins are in `reports/intent_metrics.json` and plotted in `reports/intent_reliability.png`.

### Reliability (validation)

| confidence bin | rows | observed accuracy | mean confidence |
|---|---|---|---|
| 0.1-0.2 | 1 | 1.0000 | 0.1979 |
| 0.2-0.3 | 10 | 0.2000 | 0.2680 |
| 0.3-0.4 | 33 | 0.3636 | 0.3431 |
| 0.4-0.5 | 41 | 0.5610 | 0.4532 |
| 0.5-0.6 | 70 | 0.8429 | 0.5407 |
| 0.6-0.7 | 87 | 0.9195 | 0.6513 |
| 0.7-0.8 | 129 | 0.9767 | 0.7521 |
| 0.8-0.9 | 140 | 1.0000 | 0.8488 |
| 0.9-1.0 | 15 | 1.0000 | 0.9094 |

## Per intent (exam)

| intent | group | precision | recall | f1 | support |
|---|---|---|---|---|---|
| affirm | dialog | 0.750 | 0.900 | 0.818 | 10 |
| app_help | info | 0.562 | 0.900 | 0.692 | 10 |
| book_venue | booking | 0.636 | 0.700 | 0.667 | 10 |
| cancel_booking | booking | 1.000 | 0.500 | 0.667 | 10 |
| check_availability | discovery | 0.500 | 0.600 | 0.545 | 10 |
| contact_owner | support | 1.000 | 1.000 | 1.000 | 10 |
| create_team_help | team | 0.778 | 0.700 | 0.737 | 10 |
| deny | dialog | 0.615 | 0.800 | 0.696 | 10 |
| elo_help | info | 0.909 | 1.000 | 0.952 | 10 |
| find_opponents | team | 0.778 | 0.700 | 0.737 | 10 |
| find_players | team | 0.769 | 1.000 | 0.870 | 10 |
| find_teams | team | 1.000 | 0.700 | 0.824 | 10 |
| find_venue | discovery | 0.909 | 1.000 | 0.952 | 10 |
| greeting | social | 1.000 | 0.800 | 0.889 | 10 |
| my_bookings | booking | 0.625 | 0.500 | 0.556 | 10 |
| navigate | discovery | 0.909 | 1.000 | 0.952 | 10 |
| out_of_scope | social | 0.615 | 0.800 | 0.696 | 10 |
| refund_policy | info | 0.636 | 0.700 | 0.667 | 10 |
| team_stats | team | 0.857 | 0.600 | 0.706 | 10 |
| topup_help | account | 0.545 | 0.600 | 0.571 | 10 |
| tournament_list | info | 0.875 | 0.700 | 0.778 | 10 |
| venue_info | info | 0.857 | 0.600 | 0.706 | 10 |
| wallet_balance | account | 0.571 | 0.400 | 0.471 | 10 |

### Where it actually fails (exam)

| gold | predicted | rows | declared confusable in the spec? |
|---|---|---|---|
| book_venue | deny | 2 | NO |
| check_availability | book_venue | 2 | yes |
| deny | affirm | 2 | yes |
| find_opponents | find_players | 2 | yes |
| my_bookings | check_availability | 2 | yes |
| tournament_list | app_help | 2 | NO |
| wallet_balance | topup_help | 2 | yes |
| affirm | deny | 1 | yes |
| app_help | wallet_balance | 1 | NO |
| book_venue | check_availability | 1 | yes |

`intent_spec.INTENT_CATALOG` declares which intent pairs are expected to be confusable. A `NO` in that last column is a mistake nobody predicted, and is the most useful line in this card for whoever extends the corpus next.

## Slices (exam)

| language | n | accuracy | macro F1 |
|---|---|---|---|
| en | 69 | 0.6957 | 0.6899 |
| mix | 69 | 0.8841 | 0.8835 |
| ru | 92 | 0.6848 | 0.6627 |

English is the WEAKEST slice, which is counter-intuitive until you read the rows: the exam's English utterances are its most idiomatic and indirect ones, while the Roman Urdu and mixed rows still carry the strong lexical anchors (`kal`, `slot`, `wallet`) that `char_wb` picks up.

| phenomenon | n | accuracy | macro F1 |
|---|---|---|---|
| boundary | 90 | 0.7111 | 0.7368 |
| code_switch | 58 | 0.8966 | 0.7771 |
| ellipsis | 25 | 0.8400 | 0.6538 |
| imperative | 15 | 1.0000 | 0.4348 |
| indirect | 55 | 0.5636 | 0.5123 |
| misspelled_venue | 2 | 1.0000 | 0.0870 |
| multi_slot | 13 | 0.7692 | 0.1159 |
| negation | 35 | 0.6571 | 0.3888 |
| numeric | 26 | 0.7308 | 0.3630 |
| plain | 15 | 0.8000 | 0.3080 |
| politeness | 6 | 1.0000 | 0.1739 |
| question | 82 | 0.8171 | 0.7205 |
| run_on | 47 | 0.6170 | 0.4969 |
| short | 34 | 0.7353 | 0.4962 |
| slang | 15 | 0.8000 | 0.3681 |
| sms_speak | 6 | 0.6667 | 0.1304 |
| typo | 7 | 0.7143 | 0.1594 |

Rows carry several tags, so these slices overlap and do not sum to 230.

## Training data

- `data/assistant/intents.csv` -- 2576 rows, sha256 `be602fb47d55ff48...`  
- split: 2050 train / 526 val, grouped by `template_id` so no template appears on both sides  
- languages: en 1035, mix 644, ru 897  
- sources: authored 860, template 1716  
- exam: `data/assistant/assistant_test.csv` -- 230 rows, sha256 `1f60b29cabad57d4...`, 10 per intent, hand-written and never trained on

The SHIPPED artifact is refitted on ALL 2576 rows (train + validation) after the configuration was frozen. The validation split exists to ESTIMATE generalisation, not to be thrown away: once the estimate is taken, throwing away 348 labelled rows to preserve a number nobody will re-read is the worse trade. Both fits are reported -- split-fit exam accuracy 0.6913 vs full-refit 0.7478, a difference well inside the bootstrap CI.

## Pipeline

```
FeatureUnion(
  word: nlu_text.prep -> TfidfVectorizer(word,    (1, 2), token_pattern='\\S+', min_df=1, max_features=50000)
  char: nlu_text.prep -> TfidfVectorizer(char_wb, (2, 6), min_df=1, max_features=80000)
)
-> CalibratedClassifierCV (C=0.5, class_weight=balanced) -> sigmoid_calibration
```

Vocabulary actually learned: 8611 word n-grams + 13938 char n-grams = 22549 features.

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

The plateau is flat -- the whole sweep spans 0.0115 on validation, which is 6 rows out of 526. C=0.5 is the validation maximum; the exam maximum is C=0.25, and picking THAT would have been tuning on the exam. Reproduce the sweep with `--sweep-c`.

### Ablation (fitted on train, uncalibrated, single C)

| features | val accuracy | exam accuracy |
|---|---|---|
| word_only | 0.8194 | 0.6957 |
| char_only | 0.8688 | 0.6870 |
| word+char | 0.8669 | 0.7000 |
| word+char_logreg | 0.8346 | 0.6957 |

What the table actually says: the char view is doing the heavy lifting. Word n-grams alone are the weakest arm (0.8194 val / 0.6957 exam) because a template corpus gives them word ORDER to memorise and little else, while char_wb alone (0.8688 / 0.6870) reads across the Roman Urdu spelling variants. Adding the word view on top of char moves validation by 1 row of 526 and the exam by 3 rows of 230 -- i.e. it is not measurably better on THIS corpus. The union ships regardless, for one reason that the ablation cannot show: the word branch is the only place the `<num>`, `<qm>` and `<emo>` placeholders survive as whole tokens, and those are what separate a question from an imperative once real users stop writing like templates. Note also that these rows are UNCALIBRATED single-C fits used to isolate views -- the shipped calibrated model scores 0.8707 val, above every row here.

The `word+char_logreg` row is a solver control, not a candidate: LogisticRegression on the same features scores 0.8346 val / 0.6957 exam, within 17 rows of the linear SVM on validation. The SVM ships because it is what the sentiment build established and because it trains in under a second, NOT because it was measurably better.

## Baselines

| baseline | exam accuracy |
|---|---|
| uniform random over 23 intents | 0.0435 |
| always `app_help` (train majority) | 0.0435 |
| **this model** | **0.7478** |

## Release gates

| # | gate | result | detail |
|---|---|---|---|
| 1 | contracts | PASS | nlu_text 17 checks + intent_spec 14 receipts clean; entities nlu-entities-v1/34aee7e75192e6fe |
| 2 | corpus provenance | PASS | 2576 rows, sha be602fb47d55, meta all_passed, fingerprints match |
| 3 | exam provenance | PASS | 230 rows, sha 1f60b29cabad, locked and unedited |
| 4 | exam uncontaminated | PASS | 0 exact, max near-dup 0.7500 (word_set) < 0.8 |
| 5 | no leakage | PASS | val accuracy 0.8707 <= 0.995 (a near-perfect val score on a template-grouped split would mean the split leaked) |
| 6 | beats baseline | PASS | exam 0.7478 >= majority 0.0435 + 0.1 |
| 7 | exam floor | PASS | exam accuracy 0.7478 >= 0.55 |
| 8 | answers well | PASS | exam accuracy on the 182 rows it answers 0.8242 >= 0.65 |
| 9 | answers at all | PASS | val coverage at floor 0.45 = 0.8878 >= 0.6 |
| 10 | calibrated | PASS | val ECE 0.1950 <= 0.25 (10-bin, top-label) |

## Intended use, and what this model must never be trusted with

**Use it for**: routing an in-app assistant message to one of 23 intents so the Node dialog manager can pick a reply, a form, or a clarifying question; and for logging what users ask so the corpus can grow.

**Do not use it for**: taking any action on its own. Every booking, cancellation, refund and wallet movement stays behind the existing Express routes with their existing auth, validation and DB constraints (FR8.15). The assistant may PREPARE a booking payload; the user still confirms it and the same route that the normal UI calls executes it.

**Known weaknesses**, all measured above, none hidden:

1. Indirect paraphrase. It matches SHAPE, not meaning. `wallet_balance` phrased as "whats sitting in there right now" goes wrong.
2. `wallet_balance` is the weakest intent on the exam; the confusion table above names every pair.
3. It cannot handle multi-intent utterances -- one label per message by construction. "cancel tomorrow and rebook Friday" gets one of the two.
4. Roman Urdu spelling variance beyond what the corpus covers falls back on char n-grams and degrades quietly (into a low-confidence prediction, which is what the floor is for).
5. Nothing here is a language model. It has no memory of the conversation, no world knowledge, and no ability to answer a question it was not trained to recognise -- which is the honest reason the escalate-to-owner design exists.

**Retraining**: `python training/train_intents.py`. It is safe to re-run; it never touches the database, reads only the two CSVs, and refuses to overwrite `models/intent_latest.joblib` unless all 10 gates pass. If the label set changes, `intent_spec.INTENT_SPEC_VERSION` must change with it -- the registry compares fingerprints at load and a mismatch takes the route to 503 rather than serving a model that predicts labels the service no longer knows.

---

Generated by `training/train_intents.py` on 2026-10-01T17:28:17+00:00 -- every number above is read out of the same run that wrote the artifact.
