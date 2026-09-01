"""Synthetic booking history for SportLynk's demand/pricing model.

READ THIS FIRST — THE HONEST CLAIM
----------------------------------
This dataset is SIMULATED. No row in it describes a booking a real person made.
It exists because the production database cannot train a model, and the reason is
measured, not assumed:

  [MEASURED 2026-08]  22 bookings exist in total (12 confirmed, 6 no_show,
                      3 cancelled, 1 rejected).
  [MEASURED 2026-08]  `slots WHERE status='booked'` = 0, across 3,825 slots.
                      There is no positive class to learn from at slot level.
  [MEASURED 2026-08]  `count(DISTINCT price)` per venue = 1. Every slot a venue
                      ever offered carried that venue's `price_per_hour`.

The third measurement is the decisive one and it is worth being blunt about: the
real data contains **zero price variation**, so it carries **zero information
about price elasticity**. No model, however good, can learn how demand responds
to price from data in which price never moved. A dynamic-pricing feature trained
on the production table would be a random-number generator with a confidence
score attached.

So the simulator is not a shortcut taken because 22 rows was inconvenient. It is
the only honest way to build this feature, and the model card must say so in
these words. What the model demonstrably learns is the structure encoded below;
what it does NOT do is discover facts about Pakistani sports demand. Those facts
are INPUTS here, sourced and confidence-labelled, not outputs.

Anyone reviewing this project should be able to draw exactly that line, which is
why every parameter carries one of:

  [MEASURED]    Read out of this repository or its database. Auditable.
  [INFERRED]    Derived from repository evidence (the seeder, the routes, the
                schema). The evidence is named at the parameter.
  [ASSUMPTION]  Domain knowledge about Pakistan. Defensible, unverified, and the
                first thing to challenge. These are the parameters that make the
                curves look real, and they are the ones a viva should attack.

WHAT THE MODEL WILL LEARN FROM THIS
-----------------------------------
P(slot booked | features, price). Price is an INPUT (`price_ratio`), so one model
answers both of S.3's questions: the 72-hour forecast holds price at ratio 1.0
and sweeps hours; the price suggestion sweeps a price grid and takes
argmax(price x P(book|price)) — expected revenue, never argmax of probability,
because the cheapest price always wins on probability alone.

------------------------------------------------------------------------------
DESIGN DECISION 1 — DEMAND IS BUILT ON THE LOG-ODDS SCALE
------------------------------------------------------------------------------
The obvious construction multiplies probabilities:

    p = base_rate * hour_mult * dow_mult * season_mult * price_mult
    p = min(p, 1.0)                                   # <-- the bug

With any realistic parameters this overflows constantly: 0.35 * 2.5 (evening
peak) * 1.6 (weekend) = 1.4, clipped to 1.0. And a clipped slot is a slot where
**price has no effect at all** — moving `price_mult` changes a number that gets
clipped away. The dataset would then contain no elasticity signal at precisely
the peak weekend evenings where a pricing engine earns its money, and the model
would correctly learn that peak demand is price-insensitive. That is a fabricated
conclusion produced by an arithmetic artifact.

So demand is assembled additively in log-odds and squashed once:

    logit(p) = intercept
             + ln(hour_mult) + ln(dow_mult) + ln(month_mult) + ln(lead_mult)
             + ln(rating_mult) + ln(calendar_mult) + ln(weather_mult)
             - elasticity * ln(price_ratio)
             + venue_effect + slot_noise
    p = sigmoid(logit(p))

Consequences, all of them improvements:
  * p is in (0, 1) by construction. No clipping, ever, so no dead zones.
  * Price stays effective everywhere, including at p = 0.94.
  * P(book) is monotonically non-increasing in price BY CONSTRUCTION (sigmoid is
    monotone and the price term is negative), so Wave C's monotonic-price-response
    release gate is testing the MODEL's fidelity to the data rather than fighting
    an artifact of the data.
  * The data-generating process is now exactly logistic in its main effects,
    which means a logistic-regression baseline is *correctly specified* — Wave C
    gets a principled floor to beat rather than an arbitrary one.

The multipliers keep their intuitive "x2.5" reading, but they are **odds ratios,
not probability ratios**. This must be stated wherever they are quoted: x2.5 on
odds moves p from 0.20 to 0.38, not to 0.50. Near saturation the same x2.5 moves
p from 0.90 to 0.96. That saturation is realistic — a slot already almost certain
to sell cannot become much more certain — and it is the behaviour probability
multiplication had to fake with a clip.

------------------------------------------------------------------------------
DESIGN DECISION 2 — PRICE IS RANDOMISED, AND THAT IS THE WHOLE BALLGAME
------------------------------------------------------------------------------
This is the single most important line in the file.

  [MEASURED]  `backend/src/scripts/seed_venues.js:381-382` prices slots like this:
                  const isPeak = hour >= 17 && hour <= 21;
                  const slotPrice = isPeak ? Math.round(v.price * 1.2) : v.price;

Production therefore prices peak slots ABOVE base. If the simulator copied that,
`price_ratio` would be 1.2 exactly when demand drivers are strongest and 1.0
otherwise — price would be positively correlated with demand. A model fit to that
data would learn **"higher price => higher booking probability"**, which is not
merely wrong, it is catastrophically actionable: Wave C's `argmax(price x P(book))`
would find its maximum at the top of the grid for every slot, and the owner
dashboard would recommend charging the 1.50 ceiling forever. The feature would
ship, look confident, and destroy the venue's occupancy.

This is the classic identification problem — observational price data cannot
identify a demand curve when price responds to demand — and there is exactly one
clean answer: **randomise price independently of every demand driver.** So
`price_ratio` here is drawn without reference to hour, day, month, venue, lead
time or rating. The dataset is a simulated price EXPERIMENT.

Two honest caveats, both recorded in `data/README.md`:
  * A randomised design gives an unbiased elasticity but a price distribution
    that does not match production. The model is being asked a causal question
    ("what if I charged X") and randomisation is what makes that question
    answerable, so this trade is deliberate, not accidental.
  * `check_price_independence()` below ASSERTS the independence numerically. It
    is not a comment claiming a property; it is a gate. If a future edit
    accidentally conditions price on demand, the generator exits non-zero and
    refuses to write the CSV.

------------------------------------------------------------------------------
DESIGN DECISION 3 — WHERE THIS DELIBERATELY DEPARTS FROM THE WAVE PROMPT
------------------------------------------------------------------------------
Each departure is a correction, not a convenience.

  (a) "weekends (Fri/Sat/Sun x1.6)" — WRONG FOR PAKISTAN, and the frozen feature
      contract already knows it. `features.is_weekend()` returns Sat/Sun only,
      with this docstring: "Friday is a working day with a long Jummah break, so
      it is NOT folded in here." Friday is genuinely different: its DAYTIME
      collapses around Jummah and its NIGHT is the biggest of the week. Folding
      Friday into a weekend flag would average those two opposite effects into
      one lukewarm number. Encoded instead as a day-of-week multiplier plus an
      explicit Friday x hour adjustment.

  (b) "seasonality (sine wave over the year)" — a single sine has ONE peak.
      Pakistani outdoor sport has TWO: March-April and September-October, split
      by the summer heat trough and the monsoon. One sine cannot express that, so
      seasonality is an explicit 12-month table where every month's value has a
      stated reason. Conceptually it is the sum of an annual and a semi-annual
      harmonic; written as a table because a table can be argued with.

  (c) "holidays (Eid, 14 Aug) x1.8" — the sign is wrong for Eid. Eid days
      EMPTY a venue: families visit, nobody plays football on Eid morning. The
      lift comes in the DAYS AFTER, when everyone is off work and cousins are in
      town. Applying x1.8 to Eid itself would make the emptiest days of the year
      look like the busiest. Split into a holiday multiplier, an Eid suppression,
      an Eid rebound window, and a separate Ashura suppression (a day of
      mourning, not a festival).

  (d) `is_peak` stays 18..22. The true football peak is nearer 20:00-22:00, but
      `PEAK_START_HOUR`/`PEAK_END_HOUR` are frozen — duplicated into
      `mlClient.js` and asserted by `check_ml_service.js`'s 37 checks via
      `GET /features/spec`. Moving them is a v2 change. The real shape is carried
      by the `hour` feature, which is strictly more expressive than the flag, so
      nothing is lost.

  (e) Column names follow the SCHEMA, not the prompt. The prompt asks for
      `zone`/`rating`/`days_until_slot`; the frozen contract calls them
      `city`/`venue_rating`/`lead_days`, and the CSV is read back through
      `features.build_feature_dict`, whose key names are the contract. Emitting
      the prompt's names would force a translation layer between training and
      serving, which is the exact train/serve skew Wave A built the shared
      feature module to prevent. Mapping table in `data/README.md`.

  (f) `--rows` becomes an optional CAP. The Wave A placeholder published
      `--rows 40000 --days 240`; this wave's spec says 12 months x 20 venues,
      which enumerates to ~81K rows and lands inside the prompt's 80-120K band
      naturally. Full enumeration is the normal path; `--rows` subsamples for a
      fast smoke run and the cap is recorded in the metadata so a capped dataset
      can never be mistaken for a complete one.

------------------------------------------------------------------------------
DESIGN DECISION 4 — WHAT IS GENERATED BUT HIDDEN FROM THE MODEL
------------------------------------------------------------------------------
`is_holiday`, `is_ramadan`, `ramadan_phase`, `ground_type`, the day-of-month
payday effect and a per-venue random effect all move demand here, and NONE of
them is in `FEATURE_ORDER`. That is on purpose, twice over:

  * It is what makes the metrics honest. A model that could see every generative
    driver would score near-perfectly, and a near-perfect AUC on synthetic data
    is evidence of a leak, not of quality. Hiding real drivers creates genuine
    irreducible noise, so the reported numbers describe a model doing real work.
  * It is what the production system can actually supply. Node has no hijri
    calendar at serve time, so `is_ramadan` could not be filled for a live
    prediction even if the model wanted it. Training on a feature that serving
    cannot provide is the most common way an ML feature dies in production.

`ground_type` is the strongest v2 candidate: it is already a column on `venues`,
already populated ('turf' / 'indoor'), and the monsoon effect below hits outdoor
venues only — so the excluded driver is both available and materially predictive.
Recorded here rather than acted on, because adding a feature means bumping
`FEATURE_SPEC_VERSION` to v2, updating `spec()`, `mlClient.js` and the harness's
"11 features" assertion, and this wave does not get to break a verified 37/37.

CLI
---
    python training/generate_bookings.py [--seed 42] [--start 2025-08-01]
                                         [--days 365] [--rows N] [--out PATH]
                                         [--no-plot] [--quiet]

Default window is FIXED (2025-08-01 .. 2026-07-31), not "the last 12 months",
so `--seed 42` alone reproduces the dataset byte-for-byte forever. A rolling
default would silently change the data every day it was run.

OUTPUT
------
    data/bookings_synth.csv     one row per (venue, date, hour, offered price)
    data/bookings_meta.json     seed, every parameter, row count, check results,
                                library versions, and the CSV's sha256
    reports/demand_patterns.png the accept-criterion figure

WHAT THIS MUST NOT DO
---------------------
  * Not touch the database. The venue distribution it needs is recorded as
    constants below, measured once.
  * Not import anything under `app/routers/`. Training must not depend on the web
    layer. The shared surface is `app/core/features.py` (the frozen contract) and
    `app/core/pk_calendar.py` (domain dates) — both standard-library-or-numpy
    pure modules with no web imports and no connections.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from dataclasses import dataclass
from datetime import date, timedelta
from pathlib import Path

# sys.path bootstrap.
#
# `python training/generate_bookings.py` puts `training/` on sys.path[0], not the
# ml-service root, so `from app.core import features` would raise ImportError.
# The documented command in data/README.md and in this file's CLI contract is the
# plain script invocation, so the script has to make that command work rather
# than demanding `python -m training.generate_bookings` and quietly breaking
# every doc that says otherwise.
_ML_ROOT = Path(__file__).resolve().parent.parent
if str(_ML_ROOT) not in sys.path:
    sys.path.insert(0, str(_ML_ROOT))

import numpy as np  # noqa: E402  (after the bootstrap, deliberately)
import pandas as pd  # noqa: E402

from app.core import features, pk_calendar  # noqa: E402

# Section 1 — VENUE population
#
# 20 venues. The first ten are the real seeded population, copied field by field
# from backend/src/scripts/seed_venues.js so the simulated market has the same
# price tiers, sports mix, ground types and operating windows as the one the
# model will serve. The last ten extend it, because ten venues in two
# cities cannot teach a `city` feature anything and cannot give `venue_rating`
# enough spread to be usable (the real ten are all 4.3-4.9).
#
# `open_to` is EXCLUSIVE, mirroring seed_venues.js:380
#     for (let hour = startHr; hour < endHr; hour++)
# so a venue listed [16, 23] offers hours 16..22. Getting this off by one would
# silently add or drop ~7% of all rows.
#
# The football/cricket split in operating hours is real and is the most
# interesting learnable structure in the population:
#   [measured] football venues open late  (10:00-23:00)
#   [measured] cricket venues open early  (06:00-20:00)
# Cricket is a morning game in Pakistan; futsal is a night game. `sport` is a
# categorical feature, so the model can learn a genuine sport x hour interaction
# rather than one averaged daily curve.


@dataclass(frozen=True)
class Venue:
    venue_id: str
    sport: str
    city: str
    base_price: int
    ground_type: str
    rating: float | None
    """None means genuinely unrated — a young platform's common case.

    It reaches the feature matrix as NaN, never 0. `features._as_optional_rating`
    is explicit about why: "0 means 'no reviews yet' everywhere in this schema
    ... and 'unrated' is not the same statement as 'rated zero'." Collapsing them
    would teach the model that every new venue is a bad venue.
    """

    open_from: int
    open_to: int  # EXCLUSIVE
    provenance: str  # 'measured' | 'extension'


VENUES: tuple[Venue, ...] = (
    # The real ten  [measured]
    Venue("v01", "football", "Islamabad", 2000, "turf", 4.8, 16, 23, "measured"),
    Venue("v02", "football", "Islamabad", 2500, "indoor", 4.5, 8, 22, "measured"),
    Venue("v03", "football", "Islamabad", 3000, "turf", 4.9, 10, 23, "measured"),
    Venue("v04", "football", "Rawalpindi", 1800, "turf", 4.3, 14, 22, "measured"),
    Venue("v05", "football", "Islamabad", 2200, "indoor", 4.6, 12, 23, "measured"),
    Venue("v06", "cricket", "Islamabad", 3500, "turf", 4.8, 6, 18, "measured"),
    Venue("v07", "cricket", "Islamabad", 2800, "indoor", 4.4, 9, 21, "measured"),
    Venue("v08", "cricket", "Rawalpindi", 1500, "indoor", 4.6, 10, 22, "measured"),
    Venue("v09", "cricket", "Rawalpindi", 2200, "turf", 4.5, 7, 19, "measured"),
    Venue("v10", "cricket", "Islamabad", 4000, "turf", 4.9, 6, 20, "measured"),
    # The extension ten  [ASSUMPTION]
    # Chosen to widen three things the real ten cannot teach:
    #   Rating spread  the real ten are 4.3-4.9, i.e. nearly constant. Four
    #                  unrated venues and four in the 3.6-4.2 band give the
    #                  feature real variance and exercise the pipeline's imputer.
    #   City spread    'Lahore' and 'Karachi' already appear as literals in the
    #                  repo. Training on four cities rather than two means the
    #                  encoder has seen a plausible expansion market, and the
    #                  model does not meet its third city for the first time in
    #                  production.
    #   PRICE spread   1500-4000 kept, with more mass at the ends so
    #                  `base_price` is not effectively categorical.
    Venue("v11", "football", "Rawalpindi", 1600, "turf", None, 15, 23, "extension"),
    Venue("v12", "football", "Islamabad", 2800, "indoor", 4.1, 9, 23, "extension"),
    Venue("v13", "football", "Lahore", 2400, "turf", 4.7, 16, 23, "extension"),
    Venue("v14", "football", "Lahore", 1900, "turf", None, 14, 22, "extension"),
    Venue("v15", "football", "Karachi", 2600, "turf", 4.2, 17, 23, "extension"),
    Venue("v16", "cricket", "Rawalpindi", 1800, "turf", 3.9, 6, 19, "extension"),
    Venue("v17", "cricket", "Lahore", 3200, "turf", 4.6, 6, 20, "extension"),
    Venue("v18", "cricket", "Karachi", 2500, "indoor", None, 8, 21, "extension"),
    Venue("v19", "cricket", "Islamabad", 1900, "indoor", 3.6, 10, 22, "extension"),
    Venue("v20", "football", "Islamabad", 3400, "indoor", None, 10, 23, "extension"),
)

# Section 2 — the parameter table
#
# Every value below is an odds multiplier (see design DECISION 1). 1.00 means
# "no effect". They are relative to hour 17, Thursday, an average month, a
# same-day decision, a 4.4-rated venue, at list price.

# Target occupancy. [ASSUMPTION]
#
# The intercept is not a hand-tuned constant. It is solved at run time so the
# realised booked share matches this target (see `_solve_intercept`). That
# inversion is worth the twenty lines it costs:
#   * the knob becomes a business quantity an owner would recognise — "about a
#     third of offered hours sell" — instead of a magic number in log-odds;
#   * every other parameter stays interpretable as a pure relative effect,
#     because changing one no longer silently moves the overall rate;
#   * adding a new effect later cannot accidentally drift the class balance and
#     invalidate a Brier score comparison against an earlier run.
#
# 0.34 is a plausible annual average for a turf that is nearly full at 21:00 and
# nearly empty at 11:00. Asserted afterwards to land in [0.25, 0.50] — a rate
# outside that band would make the classification problem either trivial or
# degenerate.
TARGET_BOOKED_RATE = 0.34

# Hour of day. [ASSUMPTION, shape corroborated by measured operating hours]
#
# Reference hour is 17 (= 1.00). Two curves, because the two sports genuinely
# differ, and the operating windows in seed_venues.js corroborate it: cricket
# venues open at 06:00 and shut by 20:00; football venues do not open until
# 09:00-17:00 and run to 23:00. Nobody builds a 06:00 football pitch.
#
# Football / futsal — one sharp night peak.
#   06-15  dead. Work, school, and from May to September it is 35-42 C.
#   16     schools out; the first real trade of the day.
#   17     after-work start. The reference.
#   18-19  filling fast.
#   20-22  the rush. 21:00 is the single busiest hour of the week.
#   23     last slot; still busy in summer, thin in winter (see COLD_NIGHT).
#
# Cricket — bimodal: a dawn peak and an evening peak.
#   06-08  real, and specific to cricket. Morning nets and early ground
#          bookings before the heat; a genuine Pakistani pattern.
#   09-15  falls away.
#   17-20  evening peak, softer and earlier than football's, because most
#          cricket venues have no lights past 20:00.
#
# 00-05 is near-zero for both. Almost no seeded venue is open then, so these
# entries mostly guard against a future venue with a midnight window rather than
# generating rows today.
HOUR_MULT: dict[str, tuple[float, ...]] = {
    #        00    01    02    03    04    05    06    07    08    09    10    11
    #        12    13    14    15    16    17    18    19    20    21    22    23
    "football": (
        0.05, 0.04, 0.03, 0.03, 0.04, 0.08, 0.15, 0.15, 0.16, 0.16, 0.20, 0.20,
        0.18, 0.15, 0.15, 0.25, 0.55, 1.00, 1.90, 2.60, 3.20, 3.40, 2.80, 1.60,
    ),
    "cricket": (
        0.05, 0.04, 0.03, 0.03, 0.05, 0.35, 1.60, 1.90, 1.70, 1.20, 0.80, 0.55,
        0.35, 0.30, 0.30, 0.45, 0.80, 1.00, 1.70, 2.20, 2.40, 2.10, 1.30, 0.70,
    ),
}

# Day of week. [ASSUMPTION]
#
# Indexed 0=Monday..6=Sunday to match `date.weekday()`, which is what
# `features.build_feature_dict` writes into `dow` — confirmed at features.py:370.
# An off-by-one here would rotate the entire week and quietly invert the weekend.
#
#   Mon 0.80  the deadest day; the weekend's sport is out of everyone's legs.
#   Tue 0.85
#   Wed 0.90
#   Thu 1.00  reference.
#   Fri 1.35  weekend eve. See FRIDAY_* for the daytime/night split.
#   Sat 1.55  the busiest day, all day. Pakistan's weekend is Sat+Sun.
#   Sun 1.30  busy, but below Saturday and it tails off after ~20:00 because
#             Monday is a working day. Modelled via SUNDAY_LATE_ADJ.
DOW_MULT: tuple[float, ...] = (0.80, 0.85, 0.90, 1.00, 1.35, 1.55, 1.30)

FRIDAY_DOW = 4
SUNDAY_DOW = 6

# Friday daytime, around Jummah. [ASSUMPTION]
# Congregational prayer plus the long institutional break empties the middle of
# the Friday afternoon far harder than the DOW multiplier suggests. This is
# exactly the effect that a "Fri/Sat/Sun x1.6" weekend flag would erase.
FRIDAY_JUMMAH_HOURS = range(12, 16)  # 12:00-15:59
FRIDAY_JUMMAH_ADJ = 0.35

# Friday night. [ASSUMPTION]
# The biggest night of the week — tomorrow is a holiday and the working week is
# over. Applied on top of Friday's 1.35.
FRIDAY_NIGHT_HOURS = range(20, 24)
FRIDAY_NIGHT_ADJ = 1.20

# Sunday evening. [ASSUMPTION]
# The mirror of Friday night: the weekend is ending and Monday is work, so the
# late slots thin out even though the day overall is busy.
SUNDAY_LATE_HOURS = range(21, 24)
SUNDAY_LATE_ADJ = 0.70

# Month of year — the bimodal season. [ASSUMPTION]
#
# Islamabad / Rawalpindi (Potohar plateau). Two peaks, not one:
#
#   Jan 0.70  cold. Daily highs ~17 C but 21:00-23:00 drops near 4-6 C, and the
#             late slots that carry a turf's revenue are the ones that suffer.
#   Feb 0.85  warming.
#   Mar 1.25  the spring peak begins. Close to perfect playing weather.
#   Apr 1.30  the best month of the first half.
#   May 1.00  35-40 C afternoons kill daytime play; evenings hold up.
#   Jun 0.80  peak heat, 40 C+. Only the night slots survive.
#   Jul 0.70  monsoon arrives. Rain cancels outdoor play outright.
#   Aug 0.75  monsoon continues; humid but slightly better than July.
#   Sep 1.15  the autumn peak opens as the rain stops.
#   Oct 1.30  the best month of the year: dry, warm days, mild nights.
#   Nov 1.10  cooling, still good.
#   Dec 0.75  cold again.
#
# Two peaks (Mar-Apr, Sep-Oct) and two troughs (Jun-Jul, Dec-Jan) is why the
# wave prompt's single sine wave was replaced with a table — see design
# DECISION 3(b). Index 0 is unused so the month number indexes directly.
MONTH_MULT: tuple[float, ...] = (
    0.00,  # index 0 unused — months are 1-based
    0.70, 0.85, 1.25, 1.30, 1.00, 0.80, 0.70, 0.75, 1.15, 1.30, 1.10, 0.75,
)

# Winter late-night collapse — a month x hour interaction. [ASSUMPTION]
#
# The wave prompt asks for a "winter dip for late-night slots" and it is right to
# separate it: a flat winter month multiplier cannot express it, because winter
# afternoons in Islamabad are pleasant (17-20 C) while winter nights are not.
# Folding both into MONTH_MULT would wrongly suppress the 15:00 slot and wrongly
# spare the 22:00 one.
COLD_MONTHS = (12, 1, 2)
COLD_NIGHT_FROM_HOUR = 21
COLD_NIGHT_ADJ = 0.55
COLD_LATE_FROM_HOUR = 22  # compounds with the above
COLD_LATE_ADJ = 0.80

# Monsoon, outdoor only — the strongest argument for a v2 feature. [ASSUMPTION]
#
# July-August rain stops play on turf and does nothing to an indoor arena. In
# fact it helps indoor venues: the demand does not evaporate, it relocates.
#
# `ground_type` is not a model feature, so this is deliberate irreducible noise
# — and it is the single most persuasive item on the v2 list, because the column
# already exists on `venues`, is already populated, and is materially predictive
# for two months of the year.
MONSOON_MONTHS = (7, 8)
MONSOON_OUTDOOR_ADJ = 0.72
MONSOON_INDOOR_ADJ = 1.18

# Public holidays and the Islamic calendar. [ASSUMPTION on magnitude,
# dates from app/core/pk_calendar.py with their own confidence labels]
#
# The prompt's single "holidays x1.8" is replaced by four separate effects,
# because they do not share a sign — see design DECISION 3(c).
#
#   HOLIDAY_MULT 1.60
#       A gazetted day off behaves like a weekend day dropped onto a weekday.
#       Calibrated against the DOW table rather than picked: Saturday is 1.55
#       against Thursday's 1.00, so a holiday should land near there. The
#       prompt's 1.80 is in the right region and slightly hot; 1.60 keeps it
#       consistent with the weekend the table already describes.
#
#   EID_MULT 0.35
#       Eid empties venues. Three gazetted days of family visits. The prompt's
#       x1.8 would have made the three emptiest days of the year the busiest.
#
#   EID_REBOUND_MULT 1.45
#       The four days after Eid. Everyone is off, cousins are in town, and turf
#       bookings spike. Model only the suppression and the annual Eid effect
#       comes out with the right sign and the wrong volume.
#
#   ASHURA_MULT 0.45
#       9-10 Muharram is mourning, with processions and widespread closures. A
#       "public holiday" flag alone would have read it as festive.
HOLIDAY_MULT = 1.60
EID_MULT = 0.35
EID_REBOUND_MULT = 1.45
ASHURA_MULT = 0.45
ASHURA_NAMES = ("9 Muharram", "10 Muharram (Ashura)")

# Ramadan, by intraday phase. [ASSUMPTION]
#
# The user asked for this explicitly and it is the largest single reshaping of
# the year. Phase boundaries come from `pk_calendar.ramadan_phase()`.
#
#   fasting     0.06   06:00-15:00. Nobody plays football while fasting in
#                      February daylight. Near-total collapse, not a dip.
#   pre_iftar   0.03   16:00-17:00. Deader still — everyone is travelling home.
#   iftar       0.02   18:00. This hour is not negotiable.
#   post_iftar  0.30   19:00. Eating, then Maghrib.
#   taraweeh    0.55   20:00-21:00. Prayers; some play before going.
#   late_night  1.85   22:00-02:00. The Ramadan window. Post-Taraweeh futsal and
#                      cricket tournaments are a national fixture, and demand
#                      here is higher than an ordinary night, not lower. This is
#                      the one multiplier above 1.0 in the table and it is the
#                      whole point of modelling Ramadan at all.
#   sehri       0.08   03:00-05:00. Awake, but eating, not playing.
#
# The seeded venues shut at 22:00 or 23:00, so the dataset captures the leading
# edge of the late-night surge rather than its peak. That is a property of the
# venue population, not of this table, and the accept-criterion plot should show
# it rather than hide it.
RAMADAN_PHASE_MULT: dict[str, float] = {
    "none": 1.00,
    "sehri": 0.08,
    "fasting": 0.06,
    "pre_iftar": 0.03,
    "iftar": 0.02,
    "post_iftar": 0.30,
    "taraweeh": 0.55,
    "late_night": 1.85,
}

# Payday. [ASSUMPTION]
#
# Pakistani salaries land in the first few days of the month. Discretionary
# spending — which a turf booking is — follows. Not in the feature matrix
# (`day_of_month` is not a feature), so this is more honest irreducible noise.
PAYDAY_DAYS = 7
PAYDAY_MULT = 1.12
MONTH_END_FROM_DAY = 22
MONTH_END_MULT = 0.88

# Lead time. [ASSUMPTION]
#
# Two distinct things, and conflating them is a classic simulator bug:
#
#  (1) LEAD_MULT — the effect. A decision taken 60 days out is less likely to
#      convert than one taken today; casual sport is an impulse purchase.
#      Bounded below at LEAD_FLOOR so a 120-day lead is unlikely, not impossible.
#
#  (2) The lead-day distribution — how often each lead time is even observed.
#      Heavily short-notice, with bumps at 7 and 14 days from people booking
#      "next Friday" and "the Friday after".
#
# Sampled independently of hour. Real peak slots do book further ahead — Friday
# 21:00 is gone before the day itself — but encoding that here would make
# lead time both a cause and a consequence of peak demand, double-counting the
# peak effect and leaving the model an inconsistent story to fit. Recorded as a
# known simplification in data/README.md rather than smuggled in.
LEAD_DECAY_DAYS = 20.0
LEAD_FLOOR = 0.25
LEAD_SAMPLE_SCALE = 6.0
LEAD_BUMPS = ((7, 0.28), (14, 0.16), (21, 0.06))
LEAD_BUMP_WIDTH = 1.2

# Venue rating. [ASSUMPTION]
#
# exp(RATING_SLOPE * (rating - RATING_PIVOT)) in odds. At the pivot the effect is
# 1.00; a 4.9 venue gets ~1.32x the odds of a 4.4 one, and a 3.6 venue ~0.65x.
#
# Unrated venues get exactly 1.00 — the neutral centre, not a penalty. An unrated
# venue is a new venue, and new venues are a mix of good and bad, so the neutral
# effect plus the per-venue random effect is the right representation. Reaching
# the model as NaN, this also gives the pipeline's imputer something real to do.
RATING_PIVOT = 4.4
RATING_SLOPE = 0.55

# Price elasticity. [ASSUMPTION — and the most consequential number in the file]
#
# Applied as  -elasticity * ln(price_ratio)  in log-odds.
#
# Asymmetric by design. A Tuesday 11:00 player is shopping; a Friday 20:00 team
# wants that specific slot at that specific venue and will pay for it. Uniform
# elasticity would make the pricing engine equally timid everywhere and throw
# away the one genuinely valuable thing it could tell an owner: that the peak has
# room to move and the off-peak does not.
#
# The switch is keyed on the FROZEN `is_peak` indicator (18..22), not on latent
# demand. That is deliberate and it matters: `is_peak` is a model feature, so the
# interaction is representable and a tree can split on it. Keying the switch on
# latent demand instead would encode an interaction the feature matrix cannot
# express, and the model would look permanently miscalibrated for a reason no
# amount of tuning could fix.
#
# The wave prompt specifies a single exponent of 1.2; these two bracket it, and
# the row-weighted mean lands near it. The prompt's intent is preserved, its
# uniformity is not.
ELASTICITY_PEAK = 0.85
ELASTICITY_OFFPEAK = 2.20

# Price randomisation. See design DECISION 2 — this is the load-bearing block.
#
# PRICE_AT_LIST_PROB: the share of rows offered at exactly the list price. Real
# venues do not experiment on every slot, so a point mass at ratio 1.00 keeps the
# distribution plausible; the remaining rows sweep the whole band so elasticity
# is identified across it, including at the edges Wave C's grid will search.
#
# Offered prices are rounded to PKR 50 to match `mlClient.js`'s PRICE_ROUND_TO,
# so training data lives on the same lattice the price sweep will search. Then
# re-clamped, because rounding a boundary can cross it: base 1010 -> min 707 ->
# rounds to 700, which is below the floor. That is the exact bug found and fixed
# in mlClient.js's guardrail during Wave A, and it is the same arithmetic here.
PRICE_AT_LIST_PROB = 0.30
PRICE_ROUND_TO = 50  # mirrors backend/src/services/mlClient.js:121

# Noise. [ASSUMPTION]
#
# VENUE_EFFECT_SD  a per-venue log-odds offset for everything the features cannot
#                  see: parking, pitch quality, the owner's WhatsApp
#                  responsiveness, whether a good team has a standing Tuesday
#                  booking. Drawn once per venue, held for the whole year, which
#                  is what makes it a venue effect rather than extra slot noise.
#                  `venue_id` is deliberately not a feature (cold start), so this
#                  is permanently unlearnable — exactly the point.
# SLOT_NOISE_SD    per-row log-odds noise: who happened to be free that night.
# CANCEL_RATE      5% of gross bookings flip to not-booked. The wave prompt asks
#                  for it, and it also keeps the label from being a deterministic
#                  function of p.
VENUE_EFFECT_SD = 0.35
SLOT_NOISE_SD = 0.30
CANCEL_RATE = 0.05

# Default window. Fixed, not rolling — see the CLI section of the docstring.
#
# 2025-08-01 .. 2026-07-31 is a complete year that happens to contain an unusually
# rich calendar: Independence Day 2025, Milad, Iqbal Day, Quaid Day, Kashmir Day,
# the whole of Ramadan 1447, Eid al-Fitr, Pakistan Day (three days after Eid —
# a genuinely awkward overlap worth having in the data), Labour Day, Eid al-Adha
# and Ashura. Every calendar effect in the parameter table gets exercised.
DEFAULT_START = date(2025, 8, 1)
DEFAULT_DAYS = 365
DEFAULT_SEED = 42
DEFAULT_OUT = Path("data/bookings_synth.csv")

# Column bookkeeping.
#
# The CSV is a superset of the feature contract: the columns
# `build_feature_dict` consumes, plus the target, plus diagnostics.
#
# Why extra columns are safe: training builds its matrix through
# `features.build_frame(rows)`, which constructs each record from
# `build_feature_dict` and therefore reads only the keys the contract names. A
# diagnostic column is structurally incapable of reaching the model — there is no
# `df.drop(target)` anywhere in the pipeline, and Wave C must not introduce one.
# That rule is restated in data/README.md as a must.
#
# LEAKY_COLUMNS are the ones that would be catastrophic: they encode the answer.
# `latent_p` is the true probability each label was drawn from — invaluable for
# measuring calibration against ground truth, which almost no real project can
# do, and fatal as an input.
FEATURE_SOURCE_COLUMNS = (
    "venue_id",
    "sport",
    "city",
    "venue_rating",
    "slot_date",
    "start_time",
    "base_price",
    "candidate_price",
    "as_of",
)

DIAGNOSTIC_COLUMNS = (
    "ground_type",
    "hour",
    "dow",
    "is_weekend",
    "is_peak",
    "month",
    "lead_days",
    "price_ratio",
    "day_of_month",
    "is_holiday",
    "holiday_name",
    "is_ramadan",
    "ramadan_day",
    "ramadan_phase",
    "is_eid",
    "is_eid_rebound",
)

LEAKY_COLUMNS = frozenset({"latent_p", "booked_gross", "cancelled"})

CSV_COLUMNS = (
    *FEATURE_SOURCE_COLUMNS,
    features.TARGET,
    *DIAGNOSTIC_COLUMNS,
    "latent_p",
    "booked_gross",
    "cancelled",
)


# Section 3 — the MODEL


def _sigmoid(x: np.ndarray) -> np.ndarray:
    """Numerically stable logistic.

    `1/(1+exp(-x))` overflows to a warning for x around -750. The dataset should
    never produce log-odds that extreme, but a warning in a training log teaches
    people to ignore training logs, so it is prevented rather than tolerated.
    """
    out = np.empty_like(x, dtype=np.float64)
    pos = x >= 0
    out[pos] = 1.0 / (1.0 + np.exp(-x[pos]))
    ex = np.exp(x[~pos])
    out[~pos] = ex / (1.0 + ex)
    return out


def _solve_intercept(logit_without_intercept: np.ndarray, target: float) -> float:
    """Find the intercept that makes mean(sigmoid(logit + c)) == target.

    mean(sigmoid(.)) is continuous and strictly increasing in c, so bisection is
    exact to float precision and cannot fail to converge. 60 iterations reduce a
    24-wide bracket below 1e-17 — far past float64's useful precision — so this
    is deterministic and needs no tolerance argument.
    """
    lo, hi = -12.0, 12.0
    for _ in range(60):
        mid = (lo + hi) / 2.0
        if _sigmoid(logit_without_intercept + mid).mean() < target:
            lo = mid
        else:
            hi = mid
    return (lo + hi) / 2.0


def _lead_day_pmf() -> np.ndarray:
    """Discrete distribution over lead days, LEAD_DAYS_MIN..LEAD_DAYS_MAX.

    Exponential decay (most bookings are short-notice) plus narrow Gaussian bumps
    at one, two and three weeks out, where "next Friday" bookings cluster.
    """
    days = np.arange(features.LEAD_DAYS_MIN, features.LEAD_DAYS_MAX + 1, dtype=np.float64)
    weight = np.exp(-days / LEAD_SAMPLE_SCALE)
    for centre, height in LEAD_BUMPS:
        weight += height * np.exp(-0.5 * ((days - centre) / LEAD_BUMP_WIDTH) ** 2)
    return weight / weight.sum()


def _rating_multiplier(rating: float | None) -> float:
    """Odds multiplier for a venue rating; 1.00 (neutral) when unrated."""
    if rating is None:
        return 1.0
    return float(np.exp(RATING_SLOPE * (rating - RATING_PIVOT)))


# Section 4 — Simulation


@dataclass
class Dataset:
    frame: pd.DataFrame
    intercept: float
    seed: int
    start: date
    days: int
    row_cap: int | None


def simulate(seed: int, start: date, days: int, row_cap: int | None) -> Dataset:
    """Generate the dataset.

    Structure: enumerate rows in Python (cheap, clear, ~81K iterations), then do
    every probability computation in vectorised numpy. Mixing the two would make
    the parameter table hard to read for no speed gain.
    """
    rng = np.random.default_rng(seed)
    calendar = pk_calendar.build_calendar(start, days)
    all_days = sorted(calendar)

    # Per-day lookups, computed once and indexed by day offset
    day_dow = np.array([d.weekday() for d in all_days], dtype=np.int16)
    day_month = np.array([d.month for d in all_days], dtype=np.int16)
    day_of_month = np.array([d.day for d in all_days], dtype=np.int16)
    day_is_ramadan = np.array([calendar[d].is_ramadan for d in all_days], dtype=bool)
    day_ramadan_day = np.array([calendar[d].ramadan_day for d in all_days], dtype=np.int16)
    day_is_holiday = np.array([calendar[d].is_public_holiday for d in all_days], dtype=bool)
    day_is_eid = np.array([calendar[d].is_eid for d in all_days], dtype=bool)
    day_is_rebound = np.array([calendar[d].is_eid_rebound for d in all_days], dtype=bool)
    day_holiday_name = [calendar[d].holiday_name for d in all_days]
    day_is_ashura = np.array(
        [calendar[d].holiday_name in ASHURA_NAMES for d in all_days], dtype=bool
    )

    # Cross-check the weekend definition against the frozen contract rather than
    # trusting that `weekday() >= 5` still means what features.py means by it.
    contract_weekend = np.array([features.is_weekend(d) for d in all_days], dtype=np.int8)
    if not np.array_equal(contract_weekend, (day_dow >= 5).astype(np.int8)):
        raise SystemExit(
            "features.is_weekend() no longer agrees with dow>=5. The generator "
            "derives is_weekend from dow for speed; that shortcut is only valid "
            "while the contract agrees. Fix the generator, not this check."
        )

    # Enumerate (venue, day, hour)
    venue_idx: list[int] = []
    day_idx: list[int] = []
    hours: list[int] = []
    for v_i, venue in enumerate(VENUES):
        open_hours = range(venue.open_from, venue.open_to)  # open_to EXCLUSIVE
        for d_i in range(len(all_days)):
            for hour in open_hours:
                venue_idx.append(v_i)
                day_idx.append(d_i)
                hours.append(hour)

    v_arr = np.array(venue_idx, dtype=np.int32)
    d_arr = np.array(day_idx, dtype=np.int32)
    h_arr = np.array(hours, dtype=np.int16)
    n_full = v_arr.size

    # Optional cap
    # Subsample without replacement and sort, so a capped run is a random
    # subset of the same dataset rather than a different one. Recorded in the
    # metadata so a capped CSV can never be mistaken for a complete one.
    if row_cap is not None and row_cap < n_full:
        keep = np.sort(rng.choice(n_full, size=row_cap, replace=False))
        v_arr, d_arr, h_arr = v_arr[keep], d_arr[keep], h_arr[keep]
    n = v_arr.size

    # Per-row venue attributes
    sports = np.array([v.sport for v in VENUES])
    cities = np.array([v.city for v in VENUES])
    ground = np.array([v.ground_type for v in VENUES])
    base_prices = np.array([v.base_price for v in VENUES], dtype=np.float64)
    ratings = np.array([np.nan if v.rating is None else v.rating for v in VENUES])
    rating_mults = np.array([_rating_multiplier(v.rating) for v in VENUES])

    # One draw per venue, held for the whole year — that is what makes it a
    # venue effect rather than more slot noise.
    venue_effect = rng.normal(0.0, VENUE_EFFECT_SD, size=len(VENUES))

    row_sport = sports[v_arr]
    row_city = cities[v_arr]
    row_ground = ground[v_arr]
    row_base = base_prices[v_arr]
    row_rating = ratings[v_arr]
    row_dow = day_dow[d_arr]
    row_month = day_month[d_arr]
    row_dom = day_of_month[d_arr]
    row_is_weekend = (row_dow >= 5).astype(np.int8)
    row_is_peak = (
        (h_arr >= features.PEAK_START_HOUR) & (h_arr <= features.PEAK_END_HOUR)
    ).astype(np.int8)

    # Price: sampled independently of everything above
    # Nothing in this block reads row_dow, row_month, h_arr or v_arr. That is the
    # identification design, and check_price_independence() enforces it.
    ratio_raw = rng.uniform(features.PRICE_RATIO_MIN, features.PRICE_RATIO_MAX, size=n)
    at_list = rng.random(n) < PRICE_AT_LIST_PROB
    ratio_raw = np.where(at_list, 1.0, ratio_raw)

    offered = np.round(row_base * ratio_raw / PRICE_ROUND_TO) * PRICE_ROUND_TO
    # Re-clamp onto the 50-grid inside the band. Rounding can cross a boundary.
    floor_price = np.ceil(row_base * features.PRICE_RATIO_MIN / PRICE_ROUND_TO) * PRICE_ROUND_TO
    ceil_price = np.floor(row_base * features.PRICE_RATIO_MAX / PRICE_ROUND_TO) * PRICE_ROUND_TO
    offered = np.clip(offered, floor_price, ceil_price)
    price_ratio = offered / row_base

    # Lead time: also independent
    pmf = _lead_day_pmf()
    lead_days = rng.choice(
        np.arange(features.LEAD_DAYS_MIN, features.LEAD_DAYS_MAX + 1), size=n, p=pmf
    ).astype(np.int32)

    # Assemble log-odds
    hour_tables = {s: np.array(HOUR_MULT[s], dtype=np.float64) for s in HOUR_MULT}
    hour_mult = np.empty(n, dtype=np.float64)
    for sport, table in hour_tables.items():
        mask = row_sport == sport
        hour_mult[mask] = table[h_arr[mask]]

    dow_mult = np.array(DOW_MULT, dtype=np.float64)[row_dow]

    # Friday and Sunday hour adjustments.
    is_friday = row_dow == FRIDAY_DOW
    dow_mult = np.where(
        is_friday & np.isin(h_arr, list(FRIDAY_JUMMAH_HOURS)), dow_mult * FRIDAY_JUMMAH_ADJ, dow_mult
    )
    dow_mult = np.where(
        is_friday & np.isin(h_arr, list(FRIDAY_NIGHT_HOURS)), dow_mult * FRIDAY_NIGHT_ADJ, dow_mult
    )
    dow_mult = np.where(
        (row_dow == SUNDAY_DOW) & np.isin(h_arr, list(SUNDAY_LATE_HOURS)),
        dow_mult * SUNDAY_LATE_ADJ,
        dow_mult,
    )

    month_mult = np.array(MONTH_MULT, dtype=np.float64)[row_month]

    # Winter nights.
    cold = np.isin(row_month, COLD_MONTHS)
    month_mult = np.where(cold & (h_arr >= COLD_NIGHT_FROM_HOUR), month_mult * COLD_NIGHT_ADJ, month_mult)
    month_mult = np.where(cold & (h_arr >= COLD_LATE_FROM_HOUR), month_mult * COLD_LATE_ADJ, month_mult)

    # Monsoon, outdoor vs indoor.
    monsoon = np.isin(row_month, MONSOON_MONTHS)
    outdoor = row_ground == "turf"
    weather_mult = np.ones(n, dtype=np.float64)
    weather_mult = np.where(monsoon & outdoor, MONSOON_OUTDOOR_ADJ, weather_mult)
    weather_mult = np.where(monsoon & ~outdoor, MONSOON_INDOOR_ADJ, weather_mult)

    # Calendar: holiday / Eid / rebound / Ashura. Order matters — Eid wins over
    # the generic holiday lift, and Ashura overrides both.
    row_is_holiday = day_is_holiday[d_arr]
    row_is_eid = day_is_eid[d_arr]
    row_is_rebound = day_is_rebound[d_arr]
    row_is_ashura = day_is_ashura[d_arr]

    calendar_mult = np.ones(n, dtype=np.float64)
    calendar_mult = np.where(row_is_holiday, HOLIDAY_MULT, calendar_mult)
    calendar_mult = np.where(row_is_rebound, EID_REBOUND_MULT, calendar_mult)
    calendar_mult = np.where(row_is_eid, EID_MULT, calendar_mult)
    calendar_mult = np.where(row_is_ashura, ASHURA_MULT, calendar_mult)

    # Ramadan by phase. Given that a day is in Ramadan the phase depends only on
    # the hour, so two 24-wide lookups cover the whole effect: one for the
    # multiplier, one for the phase name that goes in the diagnostic column.
    phase_by_hour = [pk_calendar.ramadan_phase(h) for h in range(24)]
    ramadan_hour_mult = np.array(
        [RAMADAN_PHASE_MULT[p] for p in phase_by_hour], dtype=np.float64
    )
    phase_name_by_hour = np.array(phase_by_hour)
    row_is_ramadan = day_is_ramadan[d_arr]
    ramadan_mult = np.where(row_is_ramadan, ramadan_hour_mult[h_arr], 1.0)
    row_ramadan_phase = np.where(
        row_is_ramadan, phase_name_by_hour[h_arr], pk_calendar.NOT_RAMADAN
    )

    # Payday.
    payday_mult = np.ones(n, dtype=np.float64)
    payday_mult = np.where(row_dom <= PAYDAY_DAYS, PAYDAY_MULT, payday_mult)
    payday_mult = np.where(row_dom >= MONTH_END_FROM_DAY, MONTH_END_MULT, payday_mult)

    # Lead-time effect.
    lead_mult = LEAD_FLOOR + (1.0 - LEAD_FLOOR) * np.exp(-lead_days / LEAD_DECAY_DAYS)

    # Rating and the per-venue effect.
    rating_mult = rating_mults[v_arr]
    row_venue_effect = venue_effect[v_arr]

    # Price: the only term with a negative sign, which is what guarantees
    # monotonicity of P(book) in price by construction.
    elasticity = np.where(row_is_peak == 1, ELASTICITY_PEAK, ELASTICITY_OFFPEAK)
    price_term = -elasticity * np.log(price_ratio)

    slot_noise = rng.normal(0.0, SLOT_NOISE_SD, size=n)

    logit_wo_intercept = (
        np.log(hour_mult)
        + np.log(dow_mult)
        + np.log(month_mult)
        + np.log(weather_mult)
        + np.log(calendar_mult)
        + np.log(ramadan_mult)
        + np.log(payday_mult)
        + np.log(lead_mult)
        + np.log(rating_mult)
        + price_term
        + row_venue_effect
        + slot_noise
    )

    intercept = _solve_intercept(logit_wo_intercept, TARGET_BOOKED_RATE)
    latent_p = _sigmoid(logit_wo_intercept + intercept)

    # Labels
    booked_gross = (rng.random(n) < latent_p).astype(np.int8)
    cancelled = ((booked_gross == 1) & (rng.random(n) < CANCEL_RATE)).astype(np.int8)
    booked = (booked_gross & (1 - cancelled)).astype(np.int8)

    # Dates
    slot_dates = np.array([all_days[i].isoformat() for i in d_arr])
    as_of = np.array(
        [(all_days[i] - timedelta(days=int(ld))).isoformat() for i, ld in zip(d_arr, lead_days)]
    )
    start_times = np.array([f"{h:02d}:00:00" for h in h_arr])

    frame = pd.DataFrame(
        {
            "venue_id": np.array([v.venue_id for v in VENUES])[v_arr],
            "sport": row_sport,
            "city": row_city,
            "venue_rating": row_rating,
            "slot_date": slot_dates,
            "start_time": start_times,
            "base_price": row_base.astype(np.int32),
            "candidate_price": offered.astype(np.int32),
            "as_of": as_of,
            features.TARGET: booked,
            "ground_type": row_ground,
            "hour": h_arr.astype(np.int16),
            "dow": row_dow,
            "is_weekend": row_is_weekend,
            "is_peak": row_is_peak,
            "month": row_month,
            "lead_days": lead_days,
            "price_ratio": price_ratio,
            "day_of_month": row_dom,
            "is_holiday": row_is_holiday.astype(np.int8),
            "holiday_name": np.array(day_holiday_name)[d_arr],
            "is_ramadan": row_is_ramadan.astype(np.int8),
            "ramadan_day": day_ramadan_day[d_arr],
            # Computed above, next to the multiplier it labels, so the name in the
            # CSV and the number applied to the odds can never describe different
            # hours.
            "ramadan_phase": row_ramadan_phase,
            "is_eid": row_is_eid.astype(np.int8),
            "is_eid_rebound": row_is_rebound.astype(np.int8),
            "latent_p": latent_p,
            "booked_gross": booked_gross,
            "cancelled": cancelled,
        }
    )[list(CSV_COLUMNS)]

    return Dataset(
        frame=frame,
        intercept=float(intercept),
        seed=seed,
        start=start,
        days=days,
        row_cap=row_cap if (row_cap is not None and row_cap < n_full) else None,
    )


# Section 5 — Mechanical self-checks
#
# These are the reason to trust the dataset. A comment claiming "price is
# independent of demand" is worth nothing; a check that exits non-zero when it
# stops being true is worth something.
#
# Every check answers a question that, answered wrongly, would silently poison
# Wave C. They run before the CSV is accepted. On failure the data is written to
# `<out>.rejected.csv` instead — debuggable, but impossible to train on by
# accident, because nothing in the pipeline looks for that name.


@dataclass
class CheckResult:
    name: str
    passed: bool
    detail: str

    def line(self) -> str:
        return f"  [{'PASS' if self.passed else 'FAIL'}] {self.name}: {self.detail}"


# Drivers that price must not correlate with. This tuple is the identification
# argument from design DECISION 2, written as something executable.
INDEPENDENCE_DRIVERS = (
    "hour",
    "dow",
    "is_weekend",
    "is_peak",
    "month",
    "lead_days",
    "base_price",
    "venue_rating",
    "day_of_month",
    "is_holiday",
    "is_ramadan",
)


def _independence_threshold(n: int) -> float:
    """Correlation tolerance, scaled to the sample size.

    Under true independence a sample correlation has SE ~= 1/sqrt(n), so a fixed
    threshold is wrong at the wrong n: at 81K rows SE is 0.0035 and 0.03 is a
    comfortable 8.5 sigma, but a `--rows 5000` smoke run has SE 0.014, where 0.03
    is barely 2 sigma and would fail roughly one run in twenty for no reason at
    all. A check that fails at random is a check people learn to re-run until it
    passes, which is strictly worse than having no check.
    """
    return max(0.03, 4.0 / np.sqrt(max(n, 1)))


def check_price_independence(frame: pd.DataFrame) -> CheckResult:
    """The load-bearing check. See DESIGN DECISION 2.

    If this fails, the dataset has a confounded price, and any elasticity learned
    from it is a correlation masquerading as a causal effect. Every downstream
    price recommendation would then be wrong, confidently, and in the direction
    that loses the venue money.
    """
    limit = _independence_threshold(len(frame))
    worst_name, worst_val = "", 0.0
    offenders = []
    for driver in INDEPENDENCE_DRIVERS:
        # pandas .corr drops NaN pairwise, which is exactly what venue_rating needs.
        corr = float(frame["price_ratio"].corr(frame[driver].astype("float64")))
        if corr != corr:  # a constant column in a tiny sample -> NaN, not a failure
            continue
        if abs(corr) > abs(worst_val):
            worst_name, worst_val = driver, corr
        if abs(corr) > limit:
            offenders.append(f"{driver}={corr:+.4f}")
    if offenders:
        return CheckResult(
            "price_independence",
            False,
            f"price_ratio correlates with demand drivers (limit {limit:.4f}): "
            + ", ".join(offenders)
            + ". The randomised price design is broken and elasticity is not identified.",
        )
    return CheckResult(
        "price_independence",
        True,
        f"max |corr(price_ratio, driver)| = {abs(worst_val):.4f} on {worst_name!r} "
        f"(limit {limit:.4f}, n={len(frame):,})",
    )


# Monotonicity check tuning.
#
# The same lesson as _independence_threshold, and it had to be learned twice: a
# fixed tolerance is a sample-size bug wearing a disguise. The true step between
# adjacent 0.10-wide price bins is ~0.03. On a 6,000-row smoke run each bin holds
# ~525 rows, so the binomial standard error of a bin-to-bin difference is ~0.028
# -- the noise is the same size as the signal. A fixed tol=0.01 therefore failed
# this check on roughly half of all valid smoke runs, which is exactly the failure
# mode check_ramadan_reached_data's docstring warns about: a check that cries wolf
# on good data teaches people to ignore checks, and that is worse than no check.
#
# So each comparison is made against its own noise level rather than a constant.
MONOTONE_MIN_BIN = 100  # below this a bin says nothing; it is skipped
MONOTONE_SIGMA = 3.0  # adjacent-pair slack, in SDs of the difference
MONOTONE_TOL_FLOOR = 0.01  # floor, so a huge sample cannot make this absurdly strict
MONOTONE_END_SIGMA = 3.0  # the end-to-end drop must clear this many SDs


def _binom_se_diff(p1: float, n1: int, p2: float, n2: int) -> float:
    """Standard error of the difference between two independent binomial rates."""
    return float(np.sqrt(p1 * (1.0 - p1) / max(n1, 1) + p2 * (1.0 - p2) / max(n2, 1)))


def check_price_monotone(frame: pd.DataFrame) -> CheckResult:
    """Booking rate must fall as price rises — empirically, not just in theory.

    Fixed-width 0.10 bins across [0.70, 1.50] rather than quantiles: 30% of rows
    sit at exactly ratio 1.00, and qcut on a distribution with a 30% point mass
    produces degenerate edges and an uninterpretable bin. Fixed bins also make
    the printed table directly readable as a demand curve.

    This check is only MEANINGFUL because check_price_independence passed:
    independence is what makes the observed marginal relationship the causal one.
    Read the two as a pair.

    WHAT THIS IS ACTUALLY GUARDING. Monotonicity is true BY CONSTRUCTION -- the
    price term is `-elasticity * log(price_ratio)` with elasticity strictly
    positive, so latent_p is mathematically strictly decreasing in price. This
    check cannot therefore "discover" that demand falls with price. What it can
    catch is a CODE regression that breaks the construction: a flipped sign, an
    elasticity lookup indexed by the wrong mask, a price column overwritten after
    the log-odds were assembled. That is a narrow target, and it is why the test
    is built for POWER against that failure rather than for strictness.

    Hence two tests, not one:

    1. END-TO-END (the primary). The cheapest surviving bin must book measurably
       MORE than the dearest, by at least MONOTONE_END_SIGMA standard errors. This
       uses the full width of the price band where the effect is largest, so it has
       real power even on a 6,000-row smoke run (~7 sigma there), and a sign flip or
       a collapsed elasticity cannot survive it.
    2. ADJACENT PAIRS (local sanity). No neighbouring pair may RISE by more than
       MONOTONE_SIGMA SDs of its own difference. This catches a localised defect --
       one mangled bin -- that the end-to-end test would average away.

    A rise of +0.011 between two 525-row bins is 0.4 sigma: a coin flip, and not
    evidence of anything. A rise of +0.03 between two 7,000-row bins is ~4 sigma:
    a real defect. Only the second should stop a release, and only the second does.
    """
    edges = np.arange(0.70, 1.5001, 0.10)
    codes = np.clip(np.digitize(frame["price_ratio"].to_numpy(), edges) - 1, 0, len(edges) - 2)
    rates: list[float] = []
    counts: list[int] = []
    labels: list[str] = []
    for b in range(len(edges) - 1):
        mask = codes == b
        n_bin = int(mask.sum())
        if n_bin < MONOTONE_MIN_BIN:  # too thin to say anything about
            continue
        rates.append(float(frame.loc[mask, features.TARGET].mean()))
        counts.append(n_bin)
        labels.append(f"{edges[b]:.2f}-{edges[b + 1]:.2f}:{rates[-1]:.3f}")

    if len(rates) < 2:
        return CheckResult(
            "price_monotone",
            True,
            f"SKIPPED: only {len(rates)} price bin(s) had >= {MONOTONE_MIN_BIN} rows "
            "-- too few to test a trend (raise --rows)",
        )

    # 1. End-to-end, the high-power test
    se_end = _binom_se_diff(rates[0], counts[0], rates[-1], counts[-1])
    drop = rates[0] - rates[-1]
    z_end = drop / se_end if se_end > 0 else 0.0
    if z_end < MONOTONE_END_SIGMA:
        return CheckResult(
            "price_monotone",
            False,
            f"price signal MISSING end-to-end: cheapest bin {labels[0]} vs dearest "
            f"{labels[-1]} is a drop of {drop:+.3f} = {z_end:.1f} sigma "
            f"(need >= {MONOTONE_END_SIGMA:.0f}). Demand is not falling with price -- "
            "suspect a sign flip on price_term or a broken elasticity mask.",
        )

    # 2. Adjacent pairs, noise-aware
    breaks = []
    for i in range(len(rates) - 1):
        se = _binom_se_diff(rates[i], counts[i], rates[i + 1], counts[i + 1])
        tol = max(MONOTONE_TOL_FLOOR, MONOTONE_SIGMA * se)
        rise = rates[i + 1] - rates[i]
        if rise > tol:
            breaks.append(
                f"{labels[i]} -> {labels[i + 1]} (+{rise:.3f}, "
                f"{rise / se if se > 0 else 0.0:.1f} sigma)"
            )
    if breaks:
        return CheckResult(
            "price_monotone",
            False,
            f"booking rate RISES beyond {MONOTONE_SIGMA:.0f}-sigma noise at: "
            + "; ".join(breaks),
        )

    return CheckResult(
        "price_monotone",
        True,
        f"falls with price across {len(rates)} bins: end-to-end {drop:+.3f} "
        f"({z_end:.1f} sigma, need {MONOTONE_END_SIGMA:.0f}), no adjacent pair rising "
        f"beyond {MONOTONE_SIGMA:.0f} sigma | " + " ".join(labels),
    )


def check_booked_rate(frame: pd.DataFrame) -> CheckResult:
    """Class balance. Outside [0.25, 0.50] the metrics stop meaning much.

    Too low and "always predict no" beats the model on accuracy, so a Brier
    improvement over the base rate becomes hard to read; too high and the same
    happens in reverse. Since the intercept is SOLVED to hit TARGET_BOOKED_RATE,
    this is really a check that the solver landed.
    """
    rate = float(frame[features.TARGET].mean())
    ok = 0.25 <= rate <= 0.50
    return CheckResult(
        "booked_rate",
        ok,
        f"{rate:.4f} (target {TARGET_BOOKED_RATE:.2f}, band 0.25-0.50)"
        + ("" if ok else " -- intercept solve did not land; check the parameter table"),
    )


def check_latent_bounds(frame: pd.DataFrame) -> CheckResult:
    """Labels must stay STOCHASTIC where it matters — at the TOP of the range.

    If latent_p reached 1.0 anywhere, those rows would be deterministic: the model
    could nail them, inflating AUC, and -- far worse -- the price term would stop
    moving the label, which is precisely the failure that probability-space clipping
    caused and that DESIGN DECISION 1 exists to prevent. `max < 0.97` is therefore
    the load-bearing half of this check.

    The bottom is NOT the mirror image, and deliberately is not bounded the same
    way. A 13:00 football slot in Ramadan, offered at 1.5x price 60 days out in a
    heat month, is genuinely close to unbookable: latent_p ~ 1e-5 is the CORRECT
    answer there, and it is what the deadzone asked for once it is expressed on the
    log-odds scale instead of by clipping. A floor on the single minimum would fail
    a correct dataset -- an easy mistake, because the two ends look symmetric and
    are not. What WOULD be a real defect is the parameter table collapsing so that
    much of the corpus is dead, which is a property of the SHARE of rows, not of the
    minimum, so that is what is measured.
    """
    lo, hi = float(frame["latent_p"].min()), float(frame["latent_p"].max())
    dead_share = float((frame["latent_p"] < 1e-4).mean())
    ok = hi < 0.97 and dead_share < 0.10
    return CheckResult(
        "latent_bounds",
        ok,
        f"latent_p in [{lo:.2e}, {hi:.4f}]; {dead_share:.2%} of rows below 1e-4 "
        "(need max<0.97 so no label is deterministic, and <10% effectively dead)",
    )


def check_no_holes(frame: pd.DataFrame) -> CheckResult:
    """No NaN in any column that feeds a non-nullable feature."""
    holes = {}
    for col in FEATURE_SOURCE_COLUMNS:
        n = int(frame[col].isna().sum())
        if n and col != "venue_rating":  # venue_rating is the one legal NaN
            holes[col] = n
    rated = int(frame["venue_rating"].notna().sum())
    if holes:
        return CheckResult("no_holes", False, f"unexpected NaN: {holes}")
    return CheckResult(
        "no_holes",
        True,
        f"no NaN outside venue_rating; {rated:,}/{len(frame):,} rows rated "
        f"({100 * (1 - rated / len(frame)):.1f}% unrated -> NaN, exercising the imputer)",
    )


def _context_from_row(row: pd.Series) -> dict:
    """A CSV row -> the ctx mapping `build_feature_dict` expects.

    Deliberately built from the SAME keys a live FastAPI request carries, with the
    same types (ISO date strings, `None` for an absent rating), so this round-trip
    exercises the serving path rather than a training-only shortcut. That is the
    whole point: if the CSV cannot be replayed through the serving feature
    builder, then the dataset and the model disagree about what a row IS, and
    that disagreement is train/serve skew.
    """
    rating = row["venue_rating"]
    return {
        "slot_date": row["slot_date"],
        "start_time": row["start_time"],
        "base_price": float(row["base_price"]),
        "candidate_price": float(row["candidate_price"]),
        "sport": row["sport"],
        "city": row["city"],
        "venue_rating": None if pd.isna(rating) else float(rating),
        "as_of": row["as_of"],
    }


def _check_sample(frame: pd.DataFrame, rng: np.random.Generator, n_random: int = 500) -> list[int]:
    """A random sample UNIONED with deliberate edge cases.

    500 random rows would almost certainly miss the extremes, and the extremes are
    where coercion breaks: the earliest and latest hour, lead_days 0 and 120, the
    cheapest and dearest slot, an unrated venue, and at least one row of every
    sport, city, venue and Ramadan phase so the categorical path is covered.
    Pushing all 81K rows through a Python-level builder would take minutes and add
    no coverage at all.
    """
    idx = set(rng.choice(len(frame), size=min(n_random, len(frame)), replace=False).tolist())
    for col in ("hour", "lead_days", "price_ratio", "base_price", "venue_rating"):
        series = frame[col]
        if series.notna().any():
            idx.add(int(series.idxmin()))
            idx.add(int(series.idxmax()))
    unrated = frame.index[frame["venue_rating"].isna()]
    if len(unrated):
        idx.add(int(unrated[0]))
    for col in ("sport", "city", "venue_id", "ramadan_phase"):
        for _value, group in frame.groupby(col, observed=True):
            idx.add(int(group.index[0]))
    return sorted(idx)


def check_contract_roundtrip(frame: pd.DataFrame, rng: np.random.Generator) -> CheckResult:
    """The CSV must survive `build_frame` + `validate_frame` unchanged.

    This is the train/serve skew tripwire. If it fails, the generator and the
    frozen feature contract have drifted apart, and a model trained on this CSV
    would be handed differently-shaped rows in production.
    """
    idx = _check_sample(frame, rng)
    rows = [_context_from_row(frame.loc[i]) for i in idx]
    try:
        built = features.build_frame(rows)
        features.validate_frame(built)
    except features.FeatureError as exc:
        return CheckResult("contract_roundtrip", False, f"validate_frame rejected the CSV: {exc}")
    except Exception as exc:  # noqa: BLE001 - any coercion failure here is a real failure
        return CheckResult(
            "contract_roundtrip",
            False,
            f"{type(exc).__name__} building features from the CSV: {exc}",
        )
    if tuple(built.columns) != features.FEATURE_ORDER:
        return CheckResult(
            "contract_roundtrip", False, f"column order drifted: {list(built.columns)}"
        )
    return CheckResult(
        "contract_roundtrip",
        True,
        f"{len(rows)} rows (random + edge cases) rebuilt through build_frame and validated "
        f"against {features.FEATURE_SPEC_VERSION}",
    )


def check_diagnostics_agree(frame: pd.DataFrame, rng: np.random.Generator) -> CheckResult:
    """Diagnostic columns must equal what the CONTRACT derives, not what I derived.

    The generator computes `hour`, `dow`, `is_weekend`, `is_peak`, `month`,
    `lead_days` and `price_ratio` itself, vectorised, for speed.
    `build_feature_dict` computes them again from the raw date/time/price columns.
    If the two ever disagree, the plots and the metadata describe a dataset the
    model is not actually seeing — the most insidious class of bug available here,
    because everything still runs and every number still looks plausible.
    """
    idx = _check_sample(frame, rng)
    rows = [_context_from_row(frame.loc[i]) for i in idx]
    built = features.build_frame(rows)
    mismatches = []
    for col in ("hour", "dow", "is_weekend", "is_peak", "month", "lead_days", "price_ratio"):
        mine = frame.loc[idx, col].to_numpy(dtype=np.float64)
        theirs = built[col].to_numpy(dtype=np.float64)
        differs = np.abs(mine - theirs) > 1e-9
        bad = int(differs.sum())
        if bad:
            first = int(np.argmax(differs))
            mismatches.append(
                f"{col}: {bad} rows differ (row {idx[first]}: mine={mine[first]} "
                f"contract={theirs[first]})"
            )
    if mismatches:
        return CheckResult("diagnostics_agree", False, "; ".join(mismatches))
    return CheckResult(
        "diagnostics_agree",
        True,
        "generator-derived hour/dow/is_weekend/is_peak/month/lead_days/price_ratio match "
        f"build_feature_dict exactly on {len(rows)} rows",
    )


def check_no_leak() -> CheckResult:
    """No leaky column may be a feature name.

    `latent_p` IS the answer. If it ever appeared in FEATURE_ORDER the model would
    score ~1.0 AUC and be worthless. Cheap to check, catastrophic to miss, and it
    also documents the invariant for whoever adds a v2 feature later.
    """
    overlap = set(features.FEATURE_ORDER) & LEAKY_COLUMNS
    if overlap:
        return CheckResult(
            "no_leak", False, f"LEAKY columns are in FEATURE_ORDER: {sorted(overlap)}"
        )
    return CheckResult(
        "no_leak",
        True,
        f"{sorted(LEAKY_COLUMNS)} are disjoint from FEATURE_ORDER "
        f"({len(features.FEATURE_ORDER)} features); diagnostics cannot reach the model",
    )


def check_peak_signal(frame: pd.DataFrame) -> CheckResult:
    """The headline signal must actually be in the data.

    If peak slots do not book more than off-peak ones, the parameter table never
    reached the labels — a sign error or an indexing bug upstream — and every plot
    in the report would be wrong while looking fine.
    """
    peak = float(frame.loc[frame["is_peak"] == 1, features.TARGET].mean())
    off = float(frame.loc[frame["is_peak"] == 0, features.TARGET].mean())
    ok = peak > off + 0.05
    return CheckResult(
        "peak_signal",
        ok,
        f"peak(18-22h) {peak:.3f} vs off-peak {off:.3f} (lift {peak - off:+.3f}, need >+0.05)",
    )


def check_ramadan_reached_data(frame: pd.DataFrame) -> CheckResult:
    """Ramadan's late-night inversion must be visible, not merely coded.

    RAMADAN_PHASE_MULT['late_night'] = 1.85 is the only multiplier above 1.0 and
    the most distinctive domain claim in the file. It is also the easiest to lose
    to an off-by-one in the phase boundaries, and it would fail silently. So the
    claim is tested against the labels: during Ramadan, hour 22+ must book BETTER
    than hour 22+ outside Ramadan, and Ramadan daytime must collapse.

    Skipped rather than failed when the window contains no Ramadan — a short
    `--days` run legitimately might not, and a check that fails on a valid smoke
    run teaches people to ignore checks.
    """
    ram = frame["is_ramadan"] == 1
    if not bool(ram.any()):
        return CheckResult(
            "ramadan_reached_data", True, "SKIPPED: window contains no Ramadan days"
        )
    late = frame["hour"] >= pk_calendar.TARAWEEH_END_HOUR
    day = frame["hour"].between(8, 15)
    r_late = float(frame.loc[ram & late, features.TARGET].mean())
    n_late = float(frame.loc[~ram & late, features.TARGET].mean())
    r_day = float(frame.loc[ram & day, features.TARGET].mean())
    n_day = float(frame.loc[~ram & day, features.TARGET].mean())
    ok = r_late > n_late and r_day < n_day
    return CheckResult(
        "ramadan_reached_data",
        ok,
        f"late-night(22h+) ramadan {r_late:.3f} vs normal {n_late:.3f} (must be HIGHER); "
        f"daytime(8-15h) ramadan {r_day:.3f} vs normal {n_day:.3f} (must be LOWER)",
    )


def check_elasticity_asymmetry(frame: pd.DataFrame) -> CheckResult:
    """Off-peak demand must be measurably more price-sensitive than peak demand.

    DESIGN DECISION 3 (ELASTICITY_OFFPEAK 2.20 > ELASTICITY_PEAK 0.85), verified
    in the labels rather than trusted from the constant. Measured as the drop in
    booking rate from the cheap end of the band to the dear end RELATIVE to each
    segment's own base rate: an absolute drop would be dominated by peak's much
    higher base rate and could report the opposite of the truth.
    """
    cheap = frame["price_ratio"] <= 0.85
    dear = frame["price_ratio"] >= 1.35
    out = {}
    for label, mask in (("peak", frame["is_peak"] == 1), ("offpeak", frame["is_peak"] == 0)):
        lo = float(frame.loc[mask & cheap, features.TARGET].mean())
        hi = float(frame.loc[mask & dear, features.TARGET].mean())
        out[label] = (lo - hi) / lo if lo > 0 else 0.0
    ok = out["offpeak"] > out["peak"]
    return CheckResult(
        "elasticity_asymmetry",
        ok,
        "relative booking-rate drop from ratio<=0.85 to >=1.35: off-peak "
        f"{out['offpeak']:.1%} vs peak {out['peak']:.1%} (off-peak must be steeper; "
        f"coded {ELASTICITY_OFFPEAK} vs {ELASTICITY_PEAK})",
    )


def check_row_count(frame: pd.DataFrame, capped: bool) -> CheckResult:
    """The wave specifies 80-120K rows. Report rather than fail on a capped run."""
    n = len(frame)
    if capped:
        return CheckResult("row_count", True, f"{n:,} rows (CAPPED run -- not the full dataset)")
    ok = 80_000 <= n <= 120_000
    return CheckResult(
        "row_count",
        ok,
        f"{n:,} rows from {len(VENUES)} venues x open hours x days (wave target 80,000-120,000)",
    )


def run_checks(ds: Dataset, seed: int) -> list[CheckResult]:
    """Every check, ordered by how much a reader should care."""
    # A separate RNG stream, so adding or removing a check cannot shift the
    # dataset's own random draws. Sampling for verification must never perturb the
    # thing being verified, or the CSV's sha256 would change whenever a check did.
    rng = np.random.default_rng(seed + 1_000_003)
    f = ds.frame
    return [
        check_no_leak(),
        check_price_independence(f),
        check_price_monotone(f),
        check_contract_roundtrip(f, rng),
        check_diagnostics_agree(f, rng),
        check_booked_rate(f),
        check_latent_bounds(f),
        check_no_holes(f),
        check_peak_signal(f),
        check_ramadan_reached_data(f),
        check_elasticity_asymmetry(f),
        check_row_count(f, ds.row_cap is not None),
    ]


# Section 6 — output


def _library_versions() -> dict[str, str]:
    versions = {
        "python": sys.version.split()[0],
        "numpy": np.__version__,
        "pandas": pd.__version__,
    }
    try:  # scikit-learn is Wave C's dependency; recorded here if already present
        import sklearn

        versions["scikit-learn"] = sklearn.__version__
    except ImportError:
        versions["scikit-learn"] = "not installed"
    return versions


def _parameter_snapshot() -> dict:
    """Every parameter, as data.

    The metadata file is the audit trail, so it READS the numbers out of the
    module rather than re-stating them. A hand-maintained copy of a parameter
    table is a lie waiting to happen.
    """
    return {
        "target_booked_rate": TARGET_BOOKED_RATE,
        "hour_mult": {sport: list(table) for sport, table in HOUR_MULT.items()},
        "dow_mult_mon_to_sun": list(DOW_MULT),
        "friday": {
            "jummah_hours": list(FRIDAY_JUMMAH_HOURS),
            "jummah_adj": FRIDAY_JUMMAH_ADJ,
            "night_hours": list(FRIDAY_NIGHT_HOURS),
            "night_adj": FRIDAY_NIGHT_ADJ,
        },
        "sunday_late": {"hours": list(SUNDAY_LATE_HOURS), "adj": SUNDAY_LATE_ADJ},
        "month_mult_jan_to_dec": list(MONTH_MULT[1:]),
        "cold_night": {
            "months": list(COLD_MONTHS),
            "from_hour": COLD_NIGHT_FROM_HOUR,
            "adj": COLD_NIGHT_ADJ,
            "late_from_hour": COLD_LATE_FROM_HOUR,
            "late_adj": COLD_LATE_ADJ,
        },
        "monsoon": {
            "months": list(MONSOON_MONTHS),
            "outdoor_adj": MONSOON_OUTDOOR_ADJ,
            "indoor_adj": MONSOON_INDOOR_ADJ,
        },
        "calendar": {
            "holiday_mult": HOLIDAY_MULT,
            "eid_mult": EID_MULT,
            "eid_rebound_mult": EID_REBOUND_MULT,
            "ashura_mult": ASHURA_MULT,
        },
        "ramadan_phase_mult": dict(RAMADAN_PHASE_MULT),
        "payday": {
            "first_days": PAYDAY_DAYS,
            "first_days_mult": PAYDAY_MULT,
            "month_end_from_day": MONTH_END_FROM_DAY,
            "month_end_mult": MONTH_END_MULT,
        },
        "lead": {
            "decay_days": LEAD_DECAY_DAYS,
            "floor": LEAD_FLOOR,
            "sample_scale": LEAD_SAMPLE_SCALE,
            "bumps": [list(b) for b in LEAD_BUMPS],
            "bump_width": LEAD_BUMP_WIDTH,
        },
        "rating": {"pivot": RATING_PIVOT, "slope": RATING_SLOPE},
        "elasticity": {"peak": ELASTICITY_PEAK, "offpeak": ELASTICITY_OFFPEAK},
        "price": {
            "at_list_prob": PRICE_AT_LIST_PROB,
            "round_to": PRICE_ROUND_TO,
            "ratio_min": features.PRICE_RATIO_MIN,
            "ratio_max": features.PRICE_RATIO_MAX,
        },
        "noise": {
            "venue_effect_sd": VENUE_EFFECT_SD,
            "slot_noise_sd": SLOT_NOISE_SD,
            "cancel_rate": CANCEL_RATE,
        },
    }


def write_outputs(ds: Dataset, checks: list[CheckResult], out: Path) -> Path:
    """Write the CSV and its metadata. Returns the path actually written."""
    passed = all(c.passed for c in checks)
    # A rejected dataset is kept for debugging but renamed, so nothing downstream
    # can pick it up by accident. Nothing in the pipeline reads *.rejected.csv.
    target = out if passed else out.with_suffix(".rejected.csv")
    target.parent.mkdir(parents=True, exist_ok=True)

    # float_format keeps latent_p and price_ratio readable and the file small;
    # 6 significant figures is far more precision than any downstream use needs.
    ds.frame.to_csv(target, index=False, float_format="%.6g")

    frame = ds.frame
    digest = hashlib.sha256(target.read_bytes()).hexdigest()
    meta = {
        "generator": "training/generate_bookings.py",
        "wave": "S.3 Wave B",
        "synthetic": True,
        "why_synthetic": (
            "Production holds 22 bookings, 0 slots with status='booked', and exactly one "
            "distinct price per venue -- so the real data contains no price variation and "
            "therefore no elasticity signal at all. See this file's module docstring."
        ),
        "accepted": passed,
        "seed": ds.seed,
        "window": {
            "start": ds.start.isoformat(),
            "end": (ds.start + timedelta(days=ds.days - 1)).isoformat(),
            "days": ds.days,
        },
        "row_cap": ds.row_cap,
        "rows": int(len(frame)),
        "solved_intercept": round(ds.intercept, 6),
        "realized": {
            "booked_rate": round(float(frame[features.TARGET].mean()), 6),
            "gross_booked_rate": round(float(frame["booked_gross"].mean()), 6),
            "cancelled_share_of_gross": round(
                float(frame["cancelled"].sum() / max(int(frame["booked_gross"].sum()), 1)), 6
            ),
            "mean_latent_p": round(float(frame["latent_p"].mean()), 6),
        },
        "feature_spec_version": features.FEATURE_SPEC_VERSION,
        "calendar_version": pk_calendar.CALENDAR_VERSION,
        "columns": {
            "feature_source": list(FEATURE_SOURCE_COLUMNS),
            "target": features.TARGET,
            "diagnostic_not_features": list(DIAGNOSTIC_COLUMNS),
            "leaky_never_features": sorted(LEAKY_COLUMNS),
            "model_features": list(features.FEATURE_ORDER),
        },
        "parameters": _parameter_snapshot(),
        "venues": [
            {
                "venue_id": v.venue_id,
                "sport": v.sport,
                "city": v.city,
                "base_price": v.base_price,
                "ground_type": v.ground_type,
                "rating": v.rating,
                "open_from": v.open_from,
                "open_to_exclusive": v.open_to,
                "provenance": v.provenance,
            }
            for v in VENUES
        ],
        "checks": [{"name": c.name, "passed": c.passed, "detail": c.detail} for c in checks],
        "libraries": _library_versions(),
        "csv_sha256": digest,
        "reproduce": (
            f"python training/generate_bookings.py --seed {ds.seed} "
            f"--start {ds.start.isoformat()} --days {ds.days}"
        ),
    }
    # The metadata filename tracks the CSV's fate for the same reason the CSV is
    # renamed: a rejected run must not overwrite the record describing an ACCEPTED
    # dataset that is still sitting in this directory. If it did, `csv_sha256` would
    # name the rejected file while the good CSV stayed in place -- the exact
    # provenance failure this whole file exists to prevent.
    meta_name = "bookings_meta.json" if passed else "bookings_meta.rejected.json"
    meta_path = target.parent / meta_name
    meta_path.write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
    return target


# Section 7 — CLI


def _parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Generate SportLynk's synthetic booking history (S.3 Wave B).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "The default window is FIXED, not rolling, so --seed alone reproduces the\n"
            "dataset byte-for-byte. Every parameter and the resulting sha256 are written\n"
            "to data/bookings_meta.json."
        ),
    )
    p.add_argument("--seed", type=int, default=DEFAULT_SEED, help="RNG seed (reproducibility)")
    p.add_argument(
        "--start",
        type=date.fromisoformat,
        default=DEFAULT_START,
        help=f"first slot date, YYYY-MM-DD (default {DEFAULT_START})",
    )
    p.add_argument(
        "--days", type=int, default=DEFAULT_DAYS, help=f"days to cover (default {DEFAULT_DAYS})"
    )
    p.add_argument(
        "--rows",
        type=int,
        default=None,
        help="OPTIONAL cap for a fast smoke run. Subsamples the same dataset and is "
        "recorded in the metadata, so a capped CSV is never mistaken for a full one.",
    )
    p.add_argument("--out", type=Path, default=DEFAULT_OUT, help=f"CSV path (default {DEFAULT_OUT})")
    p.add_argument("--no-plot", action="store_true", help="skip reports/demand_patterns.png")
    p.add_argument("--quiet", action="store_true", help="print only failures and the summary")
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv if argv is not None else sys.argv[1:])
    if args.days <= 0:
        raise SystemExit("--days must be positive")
    if args.rows is not None and args.rows < 1000:
        # Below ~1000 rows the checks become statistically meaningless and would
        # report failures that are pure sampling noise. Refusing is kinder than
        # printing a red wall of text that means nothing.
        raise SystemExit("--rows below 1000 makes the self-checks meaningless; use >= 1000")

    say = (lambda *a: None) if args.quiet else print

    say(f"generate_bookings  seed={args.seed}  window={args.start} +{args.days}d")
    say(
        f"  feature contract : {features.FEATURE_SPEC_VERSION} "
        f"({len(features.FEATURE_ORDER)} features)"
    )
    say(f"  calendar         : {pk_calendar.CALENDAR_VERSION}")

    ds = simulate(seed=args.seed, start=args.start, days=args.days, row_cap=args.rows)
    say(f"  rows             : {len(ds.frame):,}")
    say(f"  solved intercept : {ds.intercept:+.4f}  (target booked rate {TARGET_BOOKED_RATE:.2f})")

    say("\nself-checks:")
    checks = run_checks(ds, args.seed)
    for c in checks:
        if args.quiet and c.passed:
            continue
        print(c.line())

    written = write_outputs(ds, checks, args.out)
    failed = [c.name for c in checks if not c.passed]

    if failed:
        print(f"\nFAILED {len(failed)}/{len(checks)}: {', '.join(failed)}")
        print(f"data written to {written} for inspection ONLY -- do not train on it.")
        print(f"diagnosis in {written.parent / 'bookings_meta.rejected.json'}")
        print("Nothing in the pipeline reads *.rejected.csv, so it cannot be used by accident.")
        return 1

    print(f"\nOK  {len(checks)}/{len(checks)} checks passed")
    print(f"  {written}  ({written.stat().st_size / 1e6:.1f} MB)")
    print(f"  {written.parent / 'bookings_meta.json'}")

    if not args.no_plot:
        # Imported lazily: matplotlib is needed only for the figure, and a missing
        # plotting library must not stop the dataset from being generated.
        try:
            from training import demand_plots

            meta_path = written.parent / "bookings_meta.json"
            png = demand_plots.render(
                ds.frame,
                Path("reports/demand_patterns.png"),
                # Read back the record write_outputs just wrote rather than
                # rebuilding seed/window here. The figure's stats line then quotes
                # the same provenance file data/README.md points at, so the two
                # cannot drift -- and "seed ?" can never appear on a figure whose
                # own footer promises the seed is recorded.
                meta=json.loads(meta_path.read_text(encoding="utf-8")),
            )
            print(f"  {png}")
        except Exception as exc:  # noqa: BLE001 -- deliberately broad; see below
            # Not fatal, on purpose. By this line the dataset is written, hashed and
            # check-passed: it is the deliverable, and a plotting failure must not
            # make a good 12-month run exit non-zero and read as a rejected dataset.
            # It must also never pass silently, because the figure is a human gate --
            # so this prints loudly and names the fix, which re-reads the CSV and
            # needs no re-simulate. ImportError lands here too (missing matplotlib),
            # with the module name in the message.
            print(f"\n  PLOT FAILED ({type(exc).__name__}: {exc})")
            print("  The dataset above is VALID -- every check passed and it is written.")
            print("  Regenerate the figure alone: python training/demand_plots.py")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
