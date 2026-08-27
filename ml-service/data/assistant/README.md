# S.6 assistant intent datasets

Provenance record for the Model #4 corpus -- the intent classifier behind the
SportLynk assistant. **Most of this directory is gitignored** -- `.gitignore` uses
`ml-service/data/assistant/*` with named exceptions, so a generated or scratch file
added later is ignored by default rather than committed by accident. What *is*
committed: this file, the three hand-written inputs, the exam's sha256 lock, and
the corpus metadata.

---

## `assistant_test.csv` -- the exam. Do not touch it.

150 utterances written and labelled by hand, across all 15 intents: **10 rows each,
and inside every intent 4 Roman Urdu / 3 code-mixed / 3 English**. Not one row is
template-generated, because the exam's job is to ask questions the generator could
not have asked.

It is never trained on, and that is enforced rather than promised:

* `validate_intent_test.py` runs **24 checks** over it and writes
  `assistant_test_meta.json` -- sha256 `f99691aa…158b6`, the full census, and every
  check receipt.
* `gen_intents.py` re-checks that sha256 on every run (`exam_lock`) and refuses to
  build if the file has moved.
* every corpus row is tested against all 150 exam rows, and a row that duplicates
  the exam is dropped **from the corpus** -- never from the exam.

Never regenerate it, never re-balance it, and in particular **never "fix" a row
because the model got it wrong** -- at that moment the exam stops measuring
anything and the confusion matrix becomes a picture of itself.

The lock is on raw bytes, so line endings are part of it: `.gitattributes` pins
`*.csv` to `eol=lf`, because this machine has `core.autocrlf=true` and a CRLF
checkout would break every recorded sha256 on a machine where nothing is wrong.

## The shipped corpus

`intents.csv` -- **1,680 rows**, sha256 `c539b8fc…cbb92`, recorded in
`intents_meta.json` and re-verified by the gate ledger on every run.

| | rows | |
|---|---|---|
| **by intent** | 112 for each of the 15, exactly | |
| **by source** | template 1,444 · authored 236 | |
| **by language** | English 675 · Roman Urdu 585 · code-mixed 420 | |
| **by split** | train 1,332 · val 348 | |

Every intent carries the same 112 rows and the same 45/39/28 language mix. That is
a deliberate cost: `greeting` and `out_of_scope` needed 40-odd hand-written English
phrasings each to reach parity, and the alternative -- letting the easy classes
have 200 rows and `refund_policy` have 60 -- buys a better headline accuracy by
making the model better at exactly the intents that matter least.

## The three inputs, and why each one is committed

**`templates.csv`** -- 464 patterns (`{sport} ground {area} me`), sha256
`793ac7a5…6c28`. Hand-written, per `(intent, lang)`, each tagged with the phenomena
it exercises. Our own work and unreproducible, so it travels in git.

**`authored_intents.csv`** -- 236 rows written by hand, kept verbatim, sha256
`878d465e…68f3`. 14% of the corpus. These are the rows a template cannot produce:
run-on typing, ellipsis, a misspelt venue, a sentence that switches language
mid-clause. The templates teach the pattern; these teach what people actually type.

**`assistant_test.csv`** -- read by the builder for **exclusion only**, never mixed
into the corpus. `intents_meta.json` records it as an input anyway, because "the
exam was consulted and 0 rows overlapped" is a claim that needs its own receipt.

**`intents.csv` itself is not committed.** The generator plus the seed is the
reproducibility story: same seed, byte-identical file, verified on every run by
replaying the whole build and comparing row signatures (`determinism`). What
travels is `intents_meta.json` -- the sha256s, the census, the allocation ledger
and all 40 gate receipts -- which is what lets a fresh clone *verify* the corpus it
rebuilds instead of trusting a blob in git history.

## Rebuilding it

```powershell
cd D:\sportlynk\ml-service
.\.venv\Scripts\python.exe training\validate_intent_test.py   # pin the exam first
.\.venv\Scripts\python.exe training\gen_intents.py
```

Defaults need no flags. To override: `--seed`, `--per-intent`, `--out`, `--meta`,
`--no-write` (run every gate, write nothing), `--quiet`.

The row arithmetic reconciles exactly, and `intents_meta.json` records every step:

| stage | rows |
|---|---|
| templates read | 464 patterns |
| candidates rendered into pools | 2,579 (at most 12 per template) |
| drawn by the allocator | 1,444 |
| authored rows kept | 236 |
| removed as near-duplicates of the exam | 0 |
| **`intents.csv`** | **1,680** |

Each template renders its candidates **once**, into a pool of at most 12 drawn from
its full combination space in seeded order -- deliberately *not* index-sorted,
because a prefix of a sorted pool takes the first few values of the slowest-varying
slot and would ship "today, tomorrow, tonight" forever and never "Saturday". The
allocator then water-fills across a cell's templates, so 464 patterns contribute
1,444 rows at a mean of **3.1 rows each** and a maximum of **8** (cap 12). One
template went unused; that is reported, not hidden.

## The checks worth knowing about

**Exam contamination.** Every corpus row is tested against all 150 exam rows: 0
exact matches on the dedup key and **0 near-duplicates** at the 0.80 threshold, with
the highest score seen anywhere at **0.500**. The metric is
`max(char-4-shingle Jaccard, word-set Jaccard)`: shingles miss word reordering,
word sets miss spelling drift, and reporting *which* one fired is what makes a
dropped row auditable.

**The split is grouped by `template_id`.** A random split over template-expanded
rows puts "book Rawal FC for kal" in train and "book Rawal FC for parso" in val,
reports 0.99, and has measured slot-value memorisation. Grouping means no
validation phrasing was seen at fit time -- and the two sources are drawn
independently, so every intent's val set mixes authored rows with at least two
unseen templates instead of being all-generated. **127 of 348** val rows contain a
token that never appears in train.

**One text under two intents is fatal, not deduplicated.** It is a labelling
contradiction: no threshold makes it acceptable, and silently dropping one side
hides a bad template. All 1,680 rows are distinct utterances carrying one label.

**Shortcut checks.** If English rows were mostly `find_venue` and Roman Urdu rows
mostly `greeting`, the model could score well by detecting *language*. Measured as
Cramér's V: language-vs-intent **0.000** (exactly, by construction -- every intent
has the same language mix), source-vs-intent **0.0318**, split-vs-intent **0.0230**.

Read those as magnitudes, not verdicts. The metadata reports χ² and Cramér's V and
**deliberately not a p-value** -- not because it could not be computed, but because
at n = 1,680 the null is rejected by associations far too weak to matter, so a
p-value would read as evidence while carrying none. χ² is hand-rolled in stdlib:
the corpus builder runs before any model is fit and should not pull in a numerics
dependency to divide two sums.

**`out_of_scope` is not identified by absence.** 3 of its 112 rows mention a sport
or a venue word on purpose. A fallback class trained only on rows with no domain
vocabulary learns "no keywords ⇒ out of scope", and then answers "cricket ka score
kya hua" with a venue list.

## Two fingerprints, not one

`intent_spec.py` publishes two: `assistant-intents-v1` / `7bb78a3ac94cbdef` over the
**label contract** (the 15 intents and their order, which is `model.classes_`), and
`assistant-dataset-v1` / `0eb01bc58b4a040f` over the **generation tables** (slot
vocabulary, quotas, thresholds). They have different lifetimes: adding a slot value
invalidates a corpus, renaming an intent invalidates every model ever trained. Both
are stamped into `intents_meta.json` and `assistant_test_meta.json`.

## Normalisation and judging live in code, not here

`app/core/intent_spec.py` is the single definition of `tidy()` (repairs generated
text), `text_problems()` (judges hand-written text and never rewrites it),
`dedup_key()` and `near_dup_score()`. Restating those rules in this file is how a
document starts lying, so it is deliberately not done -- read the module, or run
`python -m app.core.intent_spec --self-check`.

The two are not interchangeable. Running `tidy()` over an authored row would
silently rewrite a deliberate "kahan gaye??" into something the author did not
write; judging a generated row instead of repairing it would fail the build over a
double space the generator itself introduced.
