# S.4 sentiment datasets

Provenance and licence record for the sentiment corpus. **Most of this directory is
gitignored** — `.gitignore` uses `ml-service/data/sentiment/*` with named exceptions, so a
raw third-party download added later is ignored by default rather than committed by
accident. What *is* committed: this file, the exam, the hand-authored rows, and the
sha256 metadata.

---

## `domain_test_200.csv` — the exam. Do not touch it.

200 hand-written and hand-labelled sports-booking reviews (English, Roman Urdu, and
code-switched), balanced across negative / neutral / positive: **68 / 67 / 65**.

It is never trained on, and that is enforced rather than promised. `train_sentiment.py`
re-checks its sha256 against `domain_test_meta.json` on every run and refuses to release
if it has changed; `build_sentiment_corpus.py` removes any corpus row that duplicates it.

Never regenerate it, never re-balance it, and in particular **never "fix" a row because
the model got it wrong** — at that moment the exam stops measuring anything and the
0.8250 headline becomes a number about itself.

## The shipped corpus

`train.csv` — **21,405 rows**, sha256 `408b4c52…a068`, recorded in `train.meta.json` and
re-verified by a release gate on every training run.

| | rows | |
|---|---|---|
| **by source** | RUSA 11,719 · TweetEval 8,996 · authored 690 | |
| **by language** | Roman Urdu 11,891 · English 9,295 · code-mixed 219 | |
| **by label** | neutral 9,030 · positive 6,881 · negative 5,494 | |

The 690 authored rows are 3% of the corpus and are up-weighted ×40 at fit time
(`--upweight-authored`), because they are the only rows drawn from the actual target
distribution — venue reviews. The other 20,715 rows teach the language; these teach the
domain.

## Sources, and what may be redistributed

**Roman Urdu — RUSA.** The *Roman Urdu Data Set* from the UCI Machine Learning
Repository (Sharf et al.), on disk as `Roman Urdu DataSet.csv`. UCI publishes its
datasets under **CC BY 4.0**; confirm on the dataset page before redistributing, and cite
it in the report either way.

**English — TweetEval.** The sentiment split of the `cardiffnlp/tweeteval` benchmark, on
disk as `raw/tweeteval/{train_text.txt,train_labels.txt,mapping.txt}`. Its rows originate
in **SemEval-2017 Task 4A** Twitter data, so redistribution is constrained by the
upstream platform's terms as well as the benchmark's own licence — **verify both before
any redistribution.**

**In-domain — `authored*.csv`.** 693 rows written by hand for this project across five
files. Our own work, unreproducible, and therefore committed. `.backup_authored_batch2.csv`
is the pre-strip copy kept so the "85 template clones removed" claim stays auditable; it
is dot-prefixed so `AUTHORED_GLOB = "authored*.csv"` cannot pick it up as an input.

**Neither third-party corpus is committed, and the licence question is therefore moot for
this repository.** What is committed is `train.meta.json` — the sha256s, the row counts
and the per-source load ledger — which is what lets a fresh clone *verify* the corpus it
rebuilds instead of trusting it. That is the reproducibility story: the metadata travels,
the 9 MB of someone else's licensed text does not.

## Rebuilding it

```powershell
cd D:\sportlynk\ml-service
.\.venv\Scripts\python.exe training\build_sentiment_corpus.py
```

Defaults point at the layout above, so no flags are needed once both downloads are in
place. To override: `--rusa <csv>`, `--tweeteval-dir <dir>`, `--tweeteval-per-label`
(default 3000), `--authored-glob`.

The row arithmetic reconciles exactly, and `train.meta.json` records every step:

| stage | rows |
|---|---|
| RUSA read | 12,377 seen → 12,264 kept (113 empty after normalisation) |
| TweetEval read | 45,615 seen → 9,000 sampled (3,000 per label) |
| authored read | 693 seen → 693 kept |
| **loaded** | **21,957** |
| exact duplicates dropped | −539 |
| empty after normalisation | −12 |
| removed as near-duplicates of the exam | −1 |
| **`train.csv`** | **21,405** |

TweetEval is *sampled* per label rather than taken whole — 9,000 of 45,615 — so that
45k rows of open-domain English cannot swamp 12k rows of Roman Urdu and turn language
into a proxy for label.

## The two checks worth knowing about

**Exam contamination.** Every corpus row is tested against all 200 exam rows: 0 exact
matches, and **1 authored row removed** as a near-duplicate (word-set Jaccard ≥ 0.8).
The honest limit, also recorded in the metadata: exhaustive near-duplicate matching runs
against the *authored* rows only. RUSA and TweetEval get exact-match treatment, because
they are open-domain text that could not plausibly restate a hand-written venue review.

**Language/source independence.** If Roman Urdu rows were mostly negative and English
rows mostly positive, the model could score well by detecting *language* and never learn
sentiment. Measured: Cramér's V **0.1334** for source-vs-label and **0.1298** for
language-vs-label — weak association, which is the intended result.

Read that as a magnitude, not a verdict. The metadata reports the χ² statistic and
Cramér's V and **deliberately not a p-value** — not because it could not be computed, but
because at n = 21,405 the null is rejected by associations far too weak to matter, so a
p-value would read as evidence while carrying none. The effect size answers the question
actually being asked: how *strong* is the shortcut? (χ² is hand-rolled in stdlib —
`build_sentiment_corpus.py` runs before any model is fit and should not pull in a numerics
dependency to divide two sums. scipy is present in the venv only as a scikit-learn
transitive; it is not in `requirements.txt`.)

## Normalisation lives in code, not here

`app/core/text_norm.py` is the single definition — casefolding, URL and emoji tokens,
elongation collapse, Roman Urdu spelling variants, and the negation scoping. It is
imported by the corpus builder, by `train_sentiment.py`, and by `app/routers/sentiment.py`,
so there is exactly one copy.

Restating the rules in this file is how a document starts lying, so it is deliberately not
done. `NORM_SPEC_VERSION` is `sentiment-norm-v1`, fingerprint `b96e65df85f9692b`; both
are stamped into `train.meta.json` and into every artifact, and `GET /sentiment/spec`
publishes them.

## Files here that are *not* inputs

Left over from an earlier fallback attempt, before the real RUSA and TweetEval downloads
landed. Ignored by git, unread by the builder, and safe to delete:

`rusa.csv` · `rusa.zip` · `rusa_extract/` · `english_reviews.csv` ·
`rusa_real.csv` (a byte-identical copy of `Roman Urdu DataSet.csv`)

The shipped corpus was built from `Roman Urdu DataSet.csv`, `raw/tweeteval/`, and
`authored*.csv`. Nothing else.
