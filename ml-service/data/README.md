# data/

Training datasets. Generated, not collected — and gitignored, because the generator
plus its seed *is* the reproducibility story.

```powershell
python training/generate_bookings.py --seed 42     # writes bookings_synth.csv + meta
```

| file | contents |
|---|---|
| `bookings_synth.csv` | one row per offered slot, with the `booked` label |
| `bookings_meta.json` | seed, generator parameters, row count, solved intercept, every self-check result, library versions, csv sha256 |

`*.csv` is ignored by the root `.gitignore`; `bookings_meta.json` is small and is
committed, so the exact parameters that produced a model are in version control even
though the data is not.

---

## Reproducibility — how to get the same file twice

Everything random in the generator is drawn from **one** `numpy.random.Generator`
seeded from `--seed`. There is no `Date.now()`, no unseeded `random`, no dependence on
dict ordering, and the default window is a **fixed** date range rather than "the last
12 months" — a rolling window would mean the same command produced a different file
every day, which is not reproducibility, it is a moving target.

So this holds, and `bookings_meta.json` records the sha256 that proves it:

```powershell
python training/generate_bookings.py --seed 42     # run twice
# -> byte-identical bookings_synth.csv, identical csv_sha256 in the meta
```

| flag | default | what it does |
|---|---|---|
| `--seed` | `42` | the only source of randomness. Same seed + same code = same bytes. |
| `--start` | `2025-08-01` | first slot date. Fixed, not "today". |
| `--days` | `365` | window length. 365 gives one full seasonal cycle. |
| `--rows` | *(none)* | optional cap; subsamples uniformly for a fast smoke run. Refuses below 1000. |
| `--out` | `data/bookings_synth.csv` | output path. On check failure, writes `*.rejected.csv` instead. |
| `--no-plot` | off | skip `reports/demand_patterns.png`. |
| `--quiet` | off | suppress the per-check log. |

Two details that are easy to get wrong and are therefore deliberate:

- **The self-checks draw from a separate RNG stream** (`seed + 1_000_003`). If they
  shared the dataset's stream, adding a thirteenth check would shift every subsequent
  draw and change the CSV's sha256 — a validation change silently invalidating the
  data it validates.
- **A failed run does not overwrite a good CSV.** It writes `*.rejected.csv` and
  exits non-zero. Nothing in the pipeline reads `*.rejected.csv`, so a broken dataset
  cannot be trained on by accident.

The default window is not arbitrary. `2025-08-01 .. 2026-07-31` contains Independence
Day 2025, Milad-un-Nabi, Iqbal Day, Quaid Day, Kashmir Day, the **whole** of Ramadan
1447, Eid al-Fitr, Pakistan Day (three days after Eid — a real and awkward overlap
worth having in the data), Labour Day, Eid al-Adha and Ashura. Every calendar effect
in the parameter table is actually exercised by the default run.

---

## Why this data is synthetic

Measured against the live Supabase database on 2026-08-24:

```
bookings                                    22 rows   (12 confirmed, 6 no_show,
                                                       3 cancelled, 1 rejected)
slots WHERE status = 'booked'                 0 rows
slots                                     3,825 rows
venues                                       10       (2 cities, 2 sports,
                                                       PKR 1,500–4,000)
SELECT count(DISTINCT price) FROM slots
  GROUP BY venue_id                           1       for EVERY venue
```

That last line is the one that decides it. Every slot at a venue is priced at that
venue's `price_per_hour`. There is **not one observation** anywhere in the data of
the same slot offered at two different prices — so the data contains **no price
elasticity signal at all**.

This is not "too few rows". It is a structural absence: no model, of any
sophistication, can learn how demand responds to price from data in which price never
varied. And a dynamic *price* suggestion is exactly what this milestone ships.

So there were two options, and only one of them is honest:

1. Train on 22 rows with no price variation and present the output as a learned
   market model. That is a fabricated result, and it collapses on the first question.
2. Write the demand assumptions down explicitly, in code, with the reasoning for each
   number; generate data from them; train a real model; and state plainly that the
   model recovers the simulator's structure.

`training/generate_bookings.py` is option 2, and `reports/model_card.md` states the
limitation in those words. The training script does not change when real bookings
eventually accumulate — only the input CSV does.

This is declared in the SRS as **LI-7**: the ML features bootstrap from synthetic
data. It is a disclosed limitation, not a hidden one.

---

## How demand is constructed — and one thing you must read before trusting a number

Each row's probability is built on the **log-odds** scale:

```
logit(p) = intercept
         + ln(hour_mult) + ln(dow_mult) + ln(month_mult) + ln(calendar_mult)
         + ln(ramadan_mult) + ln(payday_mult) + ln(lead_mult) + ln(rating_mult)
         − elasticity · ln(price_ratio)
         + venue_effect + slot_noise
p        = sigmoid(logit(p))
booked   = Bernoulli(p) AND NOT Bernoulli(CANCEL_RATE)
```

**Every multiplier in the tables below is therefore an ODDS RATIO, not a probability
multiplier.** This changes what the numbers mean and it must not be misread:

> `HOUR_MULT = 2.5` does **not** move a 20% slot to 50%. It multiplies the *odds*
> 0.25 → 0.625, which is p = 0.20 → **0.38**.

The reason for the log-odds scale is the defect it avoids. Multiplying probabilities
directly — the obvious implementation, and what the wave prompt describes — overflows:
`0.35 × 2.5 × 1.6 = 1.4`, which must then be clipped to 1.0. And at a clipped slot,
**price has no effect whatsoever**, because the clip has already discarded it. The
model would learn *zero elasticity at exactly the peak slots where a pricing decision
is worth money* — the single most valuable thing it is supposed to know. Three further
properties follow for free:

- `p` is in (0, 1) by construction, so no clipping and no lost signal anywhere.
- P(book) is **monotonically non-increasing in price** by construction, for every
  row — which is exactly the release gate `train_pricing.py` asserts.
- A logistic regression is now *correctly specified* for this data-generating
  process, so Wave C's baseline is a fair baseline rather than a straw man.

### The intercept is solved, not chosen

`intercept` is found by bisection so that the realized booked share equals
`TARGET_BOOKED_RATE = 0.34`. This matters for interpretability: because the intercept
absorbs the overall level, every other parameter is a **pure relative effect**. You can
change `HOLIDAY_MULT` from 1.60 to 1.70 and reason about it locally, without also
having moved the dataset's class balance. The solved value is recorded in
`bookings_meta.json` as `solved_intercept`.

0.34 is a deliberate choice, not a default. A booked share near 0.5 makes a Brier
score look impressive for free; one near 0.02 makes "predict never booked" a 98%
accurate model. A third of offered slots booked is both plausible for a turf and
awkward enough that the metrics have to be earned.

---

## Every distribution

Confidence labels are on every constant in the source too: `[MEASURED]` (from the
database or `seed_venues.js`), `[INFERRED]` (derived from something measured), and
`[ASSUMPTION]` (domain judgement about Pakistan, defensible but not sourced). Almost
everything below is `[ASSUMPTION]` — that is the honest label for a simulator, and
saying so is the point.

### Hour of day — `HOUR_MULT`, per sport

The headline signal, and the one a Pakistani reader will check first.

| hour | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| football | 0.05 | 0.04 | 0.03 | 0.03 | 0.04 | 0.08 | 0.15 | 0.15 | 0.16 | 0.16 | 0.20 | 0.20 |
| cricket | 0.05 | 0.04 | 0.03 | 0.03 | 0.05 | 0.35 | **1.60** | **1.90** | 1.70 | 1.20 | 0.80 | 0.55 |

| hour | 12 | 13 | 14 | 15 | 16 | 17 | 18 | 19 | 20 | 21 | 22 | 23 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| football | 0.18 | 0.15 | 0.15 | 0.25 | 0.55 | 1.00 | 1.90 | 2.60 | 3.20 | **3.40** | 2.80 | 1.60 |
| cricket | 0.35 | 0.30 | 0.30 | 0.45 | 0.80 | 1.00 | 1.70 | 2.20 | **2.40** | 2.10 | 1.30 | 0.70 |

Football is unimodal and peaks at **21:00**. Cricket is **bimodal** — a dawn peak at
07:00 and a night peak at 20:00 — because cricket here is genuinely a morning game as
well as an evening one, and a single shared hour curve would have erased that.

Note that the frozen `is_peak` flag covers 18–22, while football's true peak sits at
its **far end**. That disagreement is intentional and visible in
`reports/demand_patterns.png`: `is_peak` is a coarse indicator the serving path can
compute without a calendar, and `hour` is the feature that carries the real shape.

### Day of week — `DOW_MULT`, 0 = Monday

| Mon | Tue | Wed | Thu | Fri | Sat | Sun |
|---|---|---|---|---|---|---|
| 0.80 | 0.85 | 0.90 | 1.00 (ref) | 1.35 | **1.55** | 1.30 |

Plus three `dow × hour` interactions, which is the part a weekend flag cannot express:

| effect | hours | adj | why |
|---|---|---|---|
| `FRIDAY_JUMMAH_ADJ` | Fri 12–15 | **0.35** | Congregational prayer plus the long institutional break empties Friday afternoon. |
| `FRIDAY_NIGHT_ADJ` | Fri 20–23 | **1.20** | The biggest night of the week — the working week is over. |
| `SUNDAY_LATE_ADJ` | Sun 21–23 | **0.70** | The mirror image: the weekend is ending and Monday is work. |

**Pakistan's weekend is Saturday–Sunday. Friday is a working day.** The wave prompt's
"Fri/Sat/Sun ×1.6" is wrong in an interesting way: Friday *is* one of the busiest days,
but only at night, and its daytime is the emptiest weekday block of the week. One flat
weekend multiplier gets Friday's average roughly right by cancelling two large opposite
errors — and a model trained on that learns neither.

`is_weekend` in the feature contract is Saturday/Sunday only (`dow >= 5`), and the
generator **cross-asserts** `features.is_weekend()` against `dow >= 5` on every day in
the window before generating a single row. If those ever disagree the run aborts.

### Month of year — `MONTH_MULT`

| Jan | Feb | Mar | Apr | May | Jun | Jul | Aug | Sep | Oct | Nov | Dec |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0.70 | 0.85 | 1.25 | **1.30** | 1.00 | 0.80 | 0.70 | 0.75 | 1.15 | **1.30** | 1.10 | 0.75 |

**Bimodal — two peaks and two troughs**, which is why the wave prompt's single sine
wave was replaced by a table. Islamabad/Rawalpindi has a spring peak (Mar–Apr), a
summer-heat trough (Jun, 40 °C+), a monsoon trough (Jul–Aug), an autumn peak (Sep–Oct,
the best month of the year) and a winter dip (Dec–Jan). A single sine has one hump; it
cannot represent this, and forcing it would put the annual minimum in the wrong season.

Two month-conditional interactions on top:

| effect | when | adj | why |
|---|---|---|---|
| `COLD_NIGHT_ADJ` | Dec/Jan/Feb, hour ≥ 21 | 0.55 | Winter *afternoons* in Islamabad are pleasant (17–20 °C); winter *nights* drop to 4–6 °C. A flat monthly multiplier would wrongly punish the 15:00 slot and wrongly spare the 22:00 one. |
| `COLD_LATE_ADJ` | Dec/Jan/Feb, hour ≥ 22 | 0.80 | Compounds with the above. |
| `MONSOON_OUTDOOR_ADJ` | Jul–Aug, outdoor | 0.72 | Rain stops play on turf. |
| `MONSOON_INDOOR_ADJ` | Jul–Aug, indoor | 1.18 | Demand does not evaporate, it **relocates**. |

### Public holidays and the Islamic calendar

Dates come from `app/core/pk_calendar.py`, which carries its own
`[GAZETTED]`/`[OBSERVED]`/`[ESTIMATE]` label on every entry. Magnitudes:

| effect | adj | why |
|---|---|---|
| `HOLIDAY_MULT` | **1.60** | A gazetted day off behaves like a weekend day dropped onto a weekday. Calibrated against `DOW_MULT` rather than picked — Saturday is 1.55 against Thursday's 1.00. |
| `EID_MULT` | **0.35** | Eid **empties** venues. Three gazetted days of family visiting. |
| `EID_REBOUND_MULT` | **1.45** | The four days after. Everyone is off, cousins are in town, turf bookings spike. |
| `ASHURA_MULT` | **0.45** | 9–10 Muharram is mourning, with processions and widespread closures. |

The wave prompt's blanket "holidays ×1.8" would have made **Eid the busiest time of the
year — exactly backwards**, and it would have read a day of mourning as festive. Four
effects with different signs, not one.

### Ramadan, by intraday phase — `RAMADAN_PHASE_MULT`

The largest single reshaping of the sporting year in Pakistan.

| phase | hours | mult | |
|---|---|---|---|
| `sehri` | 03–05 | 0.08 | awake, but eating |
| `fasting` | 06–15 | 0.06 | near-total collapse, not a dip |
| `pre_iftar` | 16–17 | 0.03 | deader still — everyone is travelling home |
| `iftar` | 18 | 0.02 | this hour is not negotiable |
| `post_iftar` | 19 | 0.30 | eating, then Maghrib |
| `taraweeh` | 20–21 | 0.55 | prayers; some play before going |
| `late_night` | 22–02 | **1.85** | post-Taraweeh futsal and cricket tournaments — a national fixture |

`late_night` is **the only multiplier above 1.0 in the entire Ramadan table**, and it
is the whole reason for modelling Ramadan rather than just suppressing the month.
Ramadan demand at 22:00 is *higher* than an ordinary night, not lower.

The seeded venues shut at 22:00 or 23:00, so the dataset captures the **leading edge**
of that surge, not its peak. That is a property of the venue population, not of the
table, and `demand_patterns.png` shows it rather than hiding it.

### Lead time, payday, rating, noise

| parameter | value | meaning |
|---|---|---|
| `LEAD_DECAY_DAYS` / `LEAD_FLOOR` | 20.0 / 0.25 | conversion decays with lead time; casual sport is an impulse purchase. Bounded below so a 120-day lead is unlikely, not impossible. |
| `LEAD_SAMPLE_SCALE` | 6.0 | the lead-day *distribution* — heavily short-notice. |
| `LEAD_BUMPS` | 7d: 0.28, 14d: 0.16, 21d: 0.06 | people book "next Friday" and "the Friday after". |
| `PAYDAY_MULT` | 1.12, days 1–7 | Pakistani salaries land in the first week; discretionary spend follows. |
| `MONTH_END_MULT` | 0.88, day ≥ 22 | the other end of the same effect. |
| `RATING_PIVOT` / `RATING_SLOPE` | 4.4 / 0.55 | `exp(0.55 × (rating − 4.4))` in odds. A 4.9 venue gets ~1.32× the odds of a 4.4; a 3.6 venue ~0.65×. **Unrated → exactly 1.00**, the neutral centre, not a penalty — an unrated venue is a new venue, and new venues are a mix. |
| `VENUE_EFFECT_SD` | 0.35 | per-venue log-odds offset for what the features cannot see: parking, pitch quality, whether the owner answers WhatsApp. Drawn **once per venue** and held all year. |
| `SLOT_NOISE_SD` | 0.30 | per-row noise: who happened to be free that night. |
| `CANCEL_RATE` | 0.05 | 5% of gross bookings flip to not-booked. |

**Lead time is sampled independently of hour.** Real peak slots *do* book further ahead
— you cannot get Friday 21:00 on the day — but encoding that would make lead time both
a cause and a consequence of peak demand, double-counting the peak effect and leaving
the model an inconsistent story to fit. Recorded here as a known simplification rather
than smuggled in.

### Price elasticity — asymmetric, and the most consequential number in the file

Applied as `− elasticity × ln(price_ratio)` in log-odds.

| segment | elasticity |
|---|---|
| peak (`is_peak`, hours 18–22) | **0.85** |
| off-peak | **2.20** |

A Tuesday 11:00 player is shopping on price. A Friday 20:00 team wants *that* slot at
*that* venue and will pay for it. Uniform elasticity would make the pricing engine
equally timid everywhere and throw away the one genuinely useful thing it can tell an
owner: **the peak has room to move and the off-peak does not.**

The switch is keyed on the **frozen `is_peak` indicator**, not on latent demand. That is
deliberate: `is_peak` *is* a model feature, so the interaction is representable and a
tree can split on it. Keying it on latent demand would encode an interaction the feature
matrix cannot express, and the model would look permanently miscalibrated for a reason
no amount of tuning could fix.

The wave prompt specifies a single exponent of 1.2; these two bracket it and the
row-weighted mean lands near it. The prompt's intent is kept; its uniformity is not.

---

## The randomised price experiment — the load-bearing design decision

`price_ratio` is sampled **independently of every demand driver**: hour, day, month,
lead time, venue, rating, base price. 30% of rows sit at exactly the list price
(`PRICE_AT_LIST_PROB`, because real venues do not experiment on every slot); the rest
sweep the whole `[0.70, 1.50]` band so elasticity is identified across it, including at
the edges Wave C's price grid will search.

**Why this is not optional.** `backend/src/scripts/seed_venues.js:381` prices peak slots
at 1.2× base:

```js
const isPeak = hour >= 17 && hour <= 21;
const slotPrice = isPeak ? Math.round(v.price * 1.2) : v.price;
```

If the simulator reproduced that, `price_ratio` would correlate **positively** with the
demand drivers. The model would learn "price up → bookings up", and Wave C's
`argmax(price × P(book|price))` would push every price to the 1.50 ceiling with a
confident-looking probability attached. That is not a hypothetical failure mode; it is
the default outcome of training a pricing model on observational price data where price
was set *because* demand was high.

So the generator asserts the independence mechanically. `check_price_independence`
correlates `price_ratio` against eleven demand drivers and fails the run if any
|r| exceeds `max(0.03, 4/√n)`. The threshold scales with sample size so a `--rows 5000`
smoke run does not fail at random — a check that fails randomly is a check people learn
to re-run until it passes.

Offered prices are rounded to **PKR 50** to match `mlClient.js`'s `PRICE_ROUND_TO`, so
the training data lives on the same lattice the price sweep will search, then
**re-clamped** — because rounding a boundary can cross it (base 1010 → min 707 → rounds
to 700, below the 0.70 floor). That is the same clamp→round→re-clamp ordering as the
Wave A guardrail in `mlClient.js`.

**The honest limitation:** a model trained on randomised prices and deployed against
non-randomised real prices faces a covariate shift. It is the *right* trade — the
alternative is a model with the sign of the price effect inverted — but it is a
limitation, and `reports/model_card.md` names it.

---

## Column dictionary

The CSV is a **superset** of the feature contract. Three classes, and the class is what
determines whether a column may ever be read by training:

**1. Feature-source columns** — the raw fields `features.build_feature_dict` consumes.
These mirror the shape of a real `slots ⋈ venues` row, so the same builder works on the
database at serving time.

`venue_id`, `sport`, `city`, `venue_rating`, `slot_date`, `start_time`, `base_price`,
`candidate_price`, `as_of`

**2. The target** — `booked` (0/1).

**3. Diagnostic columns** — derived or hidden effects, for analysis and plots only.

`ground_type`, `hour`, `dow`, `is_weekend`, `is_peak`, `month`, `lead_days`,
`price_ratio`, `day_of_month`, `is_holiday`, `holiday_name`, `is_ramadan`,
`ramadan_day`, `ramadan_phase`, `is_eid`, `is_eid_rebound`

**4. Leaky columns — never inputs, under any circumstance.**

`latent_p`, `booked_gross`, `cancelled`

`latent_p` is the true probability each label was drawn from. It is emitted on purpose:
it lets Wave C measure **calibration against ground truth**, which almost no real
project can do. It is also instantly fatal as an input, which is why it is named in
`LEAKY_COLUMNS` and why the next section is a MUST rather than a suggestion.

### Wave-prompt column names → schema column names

The wave prompt names its columns after itself; this project already has a frozen
feature contract. The contract wins, and here is the mapping so the prompt is still
auditable against the artifact:

| wave prompt | this dataset | why |
|---|---|---|
| `venue_id` | `venue_id` | — |
| `zone` | `city` + `sport` | there is no `zone` in the schema. `venues` has `city` and `sport`, and both are in `FEATURE_ORDER`. |
| `rating` | `venue_rating` | the contract's name; `rating` alone is ambiguous next to a *user* rating. |
| `date` | `slot_date` | matches `slots.slot_date`. |
| `hour` | `hour` (+ `start_time`) | `start_time` is the raw `slots.start_time` the builder parses; `hour` is the derived diagnostic. |
| `dow`, `is_weekend`, `is_holiday` | same | `is_holiday` is a diagnostic, **not** a feature — see below. |
| `days_until_slot` | `lead_days` | the contract's name, and `as_of` is the raw decision date it derives from. |
| `offered_price` | `candidate_price` | matches the request field the Node client sends to `/predict`. |
| `base_price` | `base_price` | — |
| `booked(0/1)` | `booked` | `features.TARGET`. |

---

## What is generated but deliberately hidden from the model

These effects are real in the data and **absent from the feature matrix**:

`is_holiday` · `is_ramadan` · `ramadan_phase` · `ramadan_day` · `is_eid` ·
`is_eid_rebound` · `ground_type` · `day_of_month` (payday) · the per-venue random effect

This is not an oversight, it is the point. A model that could see every generative
driver would score near-perfectly, and a near-perfect AUC on synthetic data is not a
triumph — it is the signature of a leak, and any examiner who has seen this before will
say so. Excluding real drivers leaves **irreducible noise**, so the reported metrics
describe a model doing genuine work on incomplete information, which is the situation it
will actually be in.

Adding them would also need a `FEATURE_SPEC_VERSION` bump, and the serving path has no
hijri calendar in Node — so `is_ramadan` as a *feature* is a v2 change with a real
dependency, not a one-line addition.

**The strongest v2 candidate is `ground_type`**: the column already exists on `venues`,
is already populated, needs no calendar, and is materially predictive for two months of
the year through the monsoon substitution effect.

---

## The twelve self-checks

The generator validates its own output before writing it. Every check has a docstring
saying what breaks if it fails. Results are logged and recorded in
`bookings_meta.json`; **any failure means no CSV at the real path and a non-zero exit.**

| check | asserts |
|---|---|
| `check_no_leak` | no leaky column name appears in `features.FEATURE_ORDER` |
| `check_price_independence` | \|corr(`price_ratio`, driver)\| below threshold for 11 drivers |
| `check_price_monotone` | booked share falls across the `price_ratio` band — a statistically significant end-to-end drop (≥3σ), and no adjacent bin rising beyond 3σ of its own binomial noise |
| `check_contract_roundtrip` | a sample of rows survives `build_frame` + `validate_frame` |
| `check_diagnostics_agree` | the diagnostic `hour`/`dow`/`is_peak`/`lead_days`/`price_ratio` equal what the *contract* computes from the raw columns |
| `check_booked_rate` | realized booked share inside 0.25–0.50 |
| `check_latent_bounds` | `latent_p` max < 0.97 and min > 0.0005 — nothing saturated |
| `check_no_holes` | no missing values in any non-nullable column |
| `check_peak_signal` | peak hours book at least 5 points above off-peak |
| `check_ramadan_reached_data` | Ramadan late-night is **higher** and Ramadan daytime **lower** than normal (skips cleanly if the window contains no Ramadan) |
| `check_elasticity_asymmetry` | the *relative* drop across the price band is steeper off-peak than on-peak |
| `check_row_count` | 80–120K rows, as the wave specifies (passes with a note when `--rows` caps it) |

`check_diagnostics_agree` is the one that earns its keep: it is the only thing standing
between this dataset and a **train/serve skew** bug, because it verifies that the `hour`
the simulator applied its multiplier to is the same `hour` the frozen builder will
extract from `start_time` at serving time.

---

## Rules for Wave C (training) — these are MUSTs

**1. Build the feature matrix through `features.build_frame(rows)`. Never
`df.drop(columns=[TARGET])`.**

This CSV contains `latent_p`. A `drop(target)` picks up every diagnostic *and every
leaky* column, and a model handed `latent_p` will report a near-perfect score that means
nothing. `build_frame` constructs each record from `build_feature_dict`, which reads
**only** the keys the contract names — so a diagnostic column is *structurally* incapable
of reaching the model. There is no `drop` anywhere in the pipeline today. Do not add one.

**2. Split on time, not at random.** Rows are indexed by both a slot date and an `as_of`
decision date. A random split puts the same venue-day either side of the boundary and
leaks the venue random effect; sort by `as_of` and hold out the tail.

**3. Lead with calibration.** Brier score and the calibration curve, not ROC-AUC — the
price engine multiplies the probability by a rupee amount, so it must be right in
absolute terms, not merely well-ordered. See `reports/README.md`.

**4. Treat a near-1.0 AUC as a bug report.** The labels are a Bernoulli draw and several
real drivers are hidden, so the ceiling is well below perfect. 0.99 means a leak.

**5. `venue_rating` is nullable → NaN, never 0.** "Unrated" is not "rated zero". The
pipeline's imputer is there to handle it, and four of the twenty venues are unrated
specifically so that path is exercised.

---

## Known simplifications, stated plainly

- Lead time is independent of hour (see above).
- Iftar/sehri hours are held **constant** per Ramadan window. Real sunset drifts ~30
  min across 30 days; the simulator's unit is the whole hour.
- Future lunar dates are `[ESTIMATE]` — Pakistan sets them by local moon sighting, so
  assume ±1 day. This shifts ~1/30th of one month's rows and cannot change a conclusion.
  It would **not** be acceptable for anything a user sees, and `pk_calendar.py` says so.
- Weather is a monthly average, not daily. There is no rain-on-Tuesday.
- Venues never close for maintenance and no slot is ever blocked by an owner.
- Ten of the twenty venues are `seed_venues.js` verbatim; ten are extensions that widen
  the rating, city and price spread so those features have variance to learn from. Each
  venue's `provenance` is recorded in `bookings_meta.json`.

---

## What must never happen here

- **No real user data.** Not a dump, not an export, not "anonymised" bookings. This
  directory is regenerable by design and is not a place where anything requiring
  protection should ever land.
- **No hand-edited CSVs.** A row edited by hand is a result nobody can reproduce, and
  it will not be noticed until someone tries.
- **No committing `bookings_synth.csv`.** The generator plus the seed is smaller, more
  reviewable, and cannot silently diverge from the code that made it.
