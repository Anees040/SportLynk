# data/

Training datasets. Generated, not collected — and gitignored, because the generator
plus its seed *is* the reproducibility story.

```powershell
python training/generate_bookings.py --seed 42     # writes bookings_synth.csv + meta
```

| file | contents |
|---|---|
| `bookings_synth.csv` | one row per offered slot, with the `booked` label |
| `bookings_meta.json` | seed, generator parameters, row count, generated_at |

`*.csv` is ignored by the root `.gitignore`; `bookings_meta.json` is small and is
committed, so the exact parameters that produced a model are in version control even
though the data is not.

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

---

## What must never happen here

- **No real user data.** Not a dump, not an export, not "anonymised" bookings. This
  directory is regenerable by design and is not a place where anything requiring
  protection should ever land.
- **No hand-edited CSVs.** A row edited by hand is a result nobody can reproduce, and
  it will not be noticed until someone tries.
