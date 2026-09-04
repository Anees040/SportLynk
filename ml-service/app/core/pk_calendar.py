"""Pakistan calendar facts that move sports-venue demand.

WHY THIS FILE EXISTS
--------------------
The pricing model needs a synthetic booking history that a viva committee will
believe. "Evening slots are busier" is not enough: in Pakistan the single largest
reshaping of evening sports demand in the year is RAMADAN, and the second largest
is the Eid week that follows it. A simulator that ignores both produces a tidy
sine wave that anybody who has ever booked a turf in Islamabad will recognise as
fake.

So the calendar is domain DATA, and it lives in its own module rather than being
buried in the generator, for three reasons:

  1. It is the only part of the simulator that is a claim about the real world
     rather than a modelling choice. Isolating it means the honest-vs-invented
     boundary is a file boundary, and every date below can be audited without
     reading a single line of probability code.
  2. `features.py` deliberately EXCLUDES `is_ramadan` today, with this reason
     recorded in its docstring: Ramadan "genuinely reshapes evening sports demand
     in Pakistan (games move to post-Taraweeh), but there is no hijri calendar in
     this repo and inventing one would be a data source, not a feature."
     This module IS that data source. It does not add the feature — that needs a
     FEATURE_SPEC_VERSION bump, which is out of scope here — but it
     removes the reason the feature could not exist, so v2 becomes a small change
     instead of a new dependency.
  3. When v2 does add it, the SERVING path needs the same table. A calendar that
     lived under `training/` would have to be moved on the day it became useful,
     and a moved module is a module that gets forked.

AMENDMENT TO AN EARLIER NOTE
-------------------------------------
`training/generate_bookings.py` says "the ONLY shared code is app/core/features.py".
That is now inaccurate by the letter and unchanged in substance. The invariant that
was worth protecting is: **training must not depend on the web layer, and must not
touch the database.** Both still hold — this module imports nothing but the standard
library, opens no connection, and knows nothing about FastAPI. The shared surface is
`app/core/{features,pk_calendar}.py`; `app/routers/` remains off-limits to training.

CONFIDENCE LABELS — read these before trusting a number
-------------------------------------------------------
Every constant below carries one of:

  [GAZETTED]  A fixed-date federal public holiday in Pakistan. Same date every
              year, not subject to moon sighting.
  [OBSERVED]  A lunar date that has already happened, so the sighting is history.
  [ESTIMATE]  A lunar date still in the future at the time of writing. Pakistan's
              Ruet-e-Hilal Committee sets these by LOCAL MOON SIGHTING, typically
              one day after Saudi Arabia, and cannot be predicted exactly. Assume
              +/- 1 day, occasionally +/- 2.

Why an estimate is acceptable here, stated plainly so nobody has to wonder: this
calendar feeds a DEMAND SIMULATOR, not a prayer-time app and not a booking rule.
The Ramadan effect is a smooth month-long reshaping of the daily curve; sliding
its boundary by one day changes roughly 1/30th of one month's rows and cannot
change any conclusion drawn from the dataset. If this module is ever used to
decide something a user sees — a "closed for Eid" banner, a holiday price — the
dates must be replaced with a gazetted source first. That is a hard line, and it
is why the labels exist rather than being implied.

Clock times (iftar, sehri, Taraweeh) are Islamabad-region approximations held
CONSTANT across each Ramadan window. Real sunset drifts about 30 minutes across
30 days; the simulator works in whole hours, so a constant is not a simplification
it needs to apologise for.

NOT IN THIS MODULE, DELIBERATELY
--------------------------------
  * Prayer times to the minute. That is a solved problem with real libraries and
    a real ephemeris; a hand-rolled approximation would be worse than useless.
  * Provincial holidays. Sindh, Punjab, KP and Balochistan each gazette extras,
    and the seeded venues are Islamabad/Rawalpindi (federal + Punjab). Adding a
    provincial layer would be inventing precision the venue distribution cannot use.
  * The hijri calendar as arithmetic. A tabular hijri conversion would LOOK more
    rigorous while being wrong by a day or two in exactly the same way as the
    table below, and it would hide that fact behind an algorithm. An explicit,
    labelled table is more honest and easier to correct.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, timedelta

# Version. Stamped into bookings_meta.json alongside FEATURE_SPEC_VERSION so a
# dataset can be traced to the calendar that produced it. Bump when any date
# below changes, because the dataset is no longer byte-reproducible if it does.
CALENDAR_VERSION = "pk-calendar-v1"

# Fixed-date federal public holidays.                            [gazetted]
#
# Keyed (month, day). These do not move. Iqbal Day was dropped as a public
# holiday for some years and reinstated in 2022; it is included because the
# dataset window is 2025-2026.
#
# Not included, and why: 1 January (widely observed, not a gazetted federal
# holiday), 11 September (Quaid's death anniversary — a day of observance, banks
# and offices largely stay open), and Christmas is folded into 25 December below
# since it coincides with Quaid-e-Azam Day.
FIXED_HOLIDAYS: dict[tuple[int, int], str] = {
    (2, 5): "Kashmir Solidarity Day",
    (3, 23): "Pakistan Day",
    (5, 1): "Labour Day",
    (8, 14): "Independence Day",
    (11, 9): "Iqbal Day",
    (12, 25): "Quaid-e-Azam Day / Christmas",
}

# Ramadan windows, inclusive of both ends (first fast .. last fast).
#
# Keyed by hijri year for traceability. Eid al-Fitr is the day after the last
# fast and is listed separately below, not inside the window — during Eid nobody
# is fasting, and the demand shape is completely different, so folding them
# together would smear two opposite effects into one flag.
#
#   1446 AH -> 2 Mar 2025 .. 30 Mar 2025    [observed]
#   1447 AH -> 19 Feb 2026 .. 19 Mar 2026   [estimate] +/- 1 day
#   1448 AH -> 8 Feb 2027 .. 9 Mar 2027     [estimate] +/- 2 days
RAMADAN_WINDOWS: dict[int, tuple[date, date]] = {
    1446: (date(2025, 3, 2), date(2025, 3, 30)),
    1447: (date(2026, 2, 19), date(2026, 3, 19)),
    1448: (date(2027, 2, 8), date(2027, 3, 9)),
}

# Eid al-Fitr, day 1. Pakistan gazettes three days.
#   1446 -> 31 Mar 2025  [observed]
#   1447 -> 20 Mar 2026  [estimate]
#   1448 -> 10 Mar 2027  [estimate]
EID_AL_FITR: dict[int, date] = {
    1446: date(2025, 3, 31),
    1447: date(2026, 3, 20),
    1448: date(2027, 3, 10),
}

# Eid al-Adha (10 Dhul-Hijjah), day 1. Pakistan gazettes three days.
#   1446 -> 7 Jun 2025   [observed]
#   1447 -> 27 May 2026  [estimate]
#   1448 -> 17 May 2027  [estimate]
EID_AL_ADHA: dict[int, date] = {
    1446: date(2025, 6, 7),
    1447: date(2026, 5, 27),
    1448: date(2027, 5, 17),
}

# Ashura — 9 and 10 Muharram are both public holidays in Pakistan. Stored as
# the 10th; the 9th is derived, so the pair can never drift apart.
#   1447 -> 6 Jul 2025   [observed]
#   1448 -> 26 Jun 2026  [estimate]
#   1449 -> 15 Jun 2027  [estimate]
ASHURA_10TH: dict[int, date] = {
    1447: date(2025, 7, 6),
    1448: date(2026, 6, 26),
    1449: date(2027, 6, 15),
}

# Eid Milad-un-Nabi (12 Rabi al-Awwal). One gazetted day.
#   1447 -> 5 Sep 2025   [observed]
#   1448 -> 26 Aug 2026  [estimate]
#   1449 -> 15 Aug 2027  [estimate]
MILAD_UN_NABI: dict[int, date] = {
    1447: date(2025, 9, 5),
    1448: date(2026, 8, 26),
    1449: date(2027, 8, 15),
}

# Eid runs three gazetted days: the day itself and the two after it.
EID_HOLIDAY_DAYS = 3

# Ramadan clock anchors, Islamabad region, held constant per window.
#
# Islamabad sunset across the 1447 window (19 Feb - 19 Mar 2026) runs roughly
# 17:55 -> 18:25, and across 1446 (2 - 30 Mar 2025) roughly 18:15 -> 18:35. An
# iftar hour of 18 is within ~30 minutes throughout both, and the simulator's
# unit is the whole hour, so a single constant is exact at this resolution.
#
# Fajr/sehri in the same windows runs roughly 05:40 -> 05:00 (it moves earlier
# as the window advances). Hour 5 covers it.
#
# Taraweeh follows Isha; in Pakistan that customarily puts it around 20:30-22:00,
# which is why the post-Taraweeh sports window opens at 22:00.
IFTAR_HOUR = 18
SEHRI_HOUR = 5
TARAWEEH_END_HOUR = 22


@dataclass(frozen=True)
class DayContext:
    """Everything the simulator needs to know about one calendar day.

    Frozen because it is cached in a dict keyed by date and handed to the row
    loop; a mutable value there would let one row's adjustment leak into the
    next row that happens to share a day.
    """

    day: date
    is_public_holiday: bool
    holiday_name: str
    """Empty string, never None, when there is no holiday.

    The generator writes this straight into a CSV column. `None` would become
    the literal string "None" through csv/pandas round-tripping in some paths
    and an empty cell in others; picking one representation here means the
    column has exactly one meaning for "no holiday".
    """

    is_ramadan: bool
    ramadan_day: int
    """1..30 during Ramadan, 0 otherwise.

    Kept as a day NUMBER, not just a flag, because the last ten days of Ramadan
    behave differently from the first ten (Laylat al-Qadr, Itikaf, and a general
    shift of energy away from recreation). The generator may or may not use the
    gradient; recording it costs nothing and inventing it later would cost a
    regeneration.
    """

    is_eid: bool
    eid_name: str
    """Empty string when not an Eid day."""

    is_eid_rebound: bool
    """The four days after the three gazetted Eid days.

    Eid itself suppresses bookings — families visit, venues sit empty. The week
    that follows does the opposite: people are off work, cousins are in town, and
    turf bookings spike. Modelling only the suppression would get the sign of the
    Eid effect right and its total volume badly wrong.
    """


def _ramadan_year(day: date) -> int | None:
    """Return the hijri year whose Ramadan contains `day`, or None."""
    for hijri, (start, end) in RAMADAN_WINDOWS.items():
        if start <= day <= end:
            return hijri
    return None


def _eid_lookup(day: date) -> tuple[str, bool, bool]:
    """Classify `day` against every Eid and Ashura window.

    Returns (name, is_eid_day, is_rebound). `name` is "" when the day is neither.

    Ashura is included as a public holiday but NOT as an Eid: it is a day of
    mourning, and treating it as festive would push demand in exactly the wrong
    direction. Its effect on bookings is suppression with no rebound.
    """
    for table, label in ((EID_AL_FITR, "Eid al-Fitr"), (EID_AL_ADHA, "Eid al-Adha")):
        for start in table.values():
            for offset in range(EID_HOLIDAY_DAYS):
                if day == start + timedelta(days=offset):
                    return (f"{label} day {offset + 1}", True, False)
            # The rebound window opens the day after the gazetted holidays end.
            rebound_from = start + timedelta(days=EID_HOLIDAY_DAYS)
            if rebound_from <= day <= rebound_from + timedelta(days=3):
                return ("", False, True)
    return ("", False, False)


def _fixed_or_lunar_holiday(day: date) -> str:
    """Name the public holiday falling on `day`, or "" if none.

    Order matters: a lunar holiday is checked first, because when Eid collides
    with a fixed date the Eid is what changes behaviour. In the dataset window
    Pakistan Day (23 Mar 2026) lands three days after Eid al-Fitr 1447, which is
    a real and slightly awkward overlap — the Eid classification wins, and the
    fixed name is not also emitted, so `holiday_name` stays single-valued.
    """
    eid_name, is_eid, _ = _eid_lookup(day)
    if is_eid:
        return eid_name

    for tenth in ASHURA_10TH.values():
        if day == tenth:
            return "10 Muharram (Ashura)"
        if day == tenth - timedelta(days=1):
            return "9 Muharram"

    for milad in MILAD_UN_NABI.values():
        if day == milad:
            return "Eid Milad-un-Nabi"

    return FIXED_HOLIDAYS.get((day.month, day.day), "")


def day_context(day: date) -> DayContext:
    """Build the calendar context for one day.

    Pure and cheap; the generator still caches it per date because the row loop
    visits each day ~12 times (once per open hour per venue) and recomputing a
    dozen membership tests per row is waste for no gain in clarity.
    """
    hijri = _ramadan_year(day)
    if hijri is None:
        ramadan_day = 0
    else:
        start, _end = RAMADAN_WINDOWS[hijri]
        ramadan_day = (day - start).days + 1

    eid_name, is_eid, is_rebound = _eid_lookup(day)
    holiday_name = _fixed_or_lunar_holiday(day)

    return DayContext(
        day=day,
        is_public_holiday=bool(holiday_name),
        holiday_name=holiday_name,
        is_ramadan=hijri is not None,
        ramadan_day=ramadan_day,
        is_eid=is_eid,
        eid_name=eid_name,
        is_eid_rebound=is_rebound,
    )


def build_calendar(start: date, days: int) -> dict[date, DayContext]:
    """Precompute contexts for [start, start + days)."""
    if days <= 0:
        raise ValueError("days must be positive")
    return {
        (d := start + timedelta(days=offset)): day_context(d)
        for offset in range(days)
    }


# Ramadan intraday phases.
#
# This is the part of the module that carries the most domain weight, so it is
# spelled out rather than expressed as arithmetic on IFTAR_HOUR.
#
# A Pakistani Ramadan day, from a turf owner's point of view:
#
#   03-05  sehri        People are awake and eating, not playing.
#   06-15  fasting      Dead. Nobody plays football on an empty stomach in
#                       February daylight; cricket nets lose their morning trade.
#   16-17  pre_iftar    Deader still. Everyone is home or on the road; the roads
#                       themselves are famously chaotic in the last hour.
#   18     iftar        Zero. This hour is not negotiable.
#   19     post_iftar   Eating, Maghrib. Still very low.
#   20-21  taraweeh     Prayers. Low, but not zero — some play before going.
#   22-02  late_night   the Ramadan window. Post-Taraweeh futsal and cricket
#                       tournaments are a genuine national fixture, and demand
#                       in these hours is higher than a normal night, not lower.
#
# The seeded venues close at 22 or 23, so the dataset captures the leading edge
# of the late-night surge (hour 22) rather than its peak. That is a property of
# the venue population, not of this table, and it is exactly the kind of thing
# the accept-criterion plot should make visible instead of hiding.
RAMADAN_PHASES = (
    "sehri",
    "fasting",
    "pre_iftar",
    "iftar",
    "post_iftar",
    "taraweeh",
    "late_night",
)

NOT_RAMADAN = "none"


def ramadan_phase(hour: int) -> str:
    """Name the Ramadan phase for an hour of the day.

    Assumes the caller has already established that the day IS in Ramadan; it
    takes only the hour so it stays trivially testable. Returning a phase for a
    non-Ramadan day would be a silent bug factory, so the caller checks first
    and this function never sees a reason to guess.
    """
    if not 0 <= hour <= 23:
        raise ValueError(f"hour out of range: {hour}")
    if SEHRI_HOUR - 2 <= hour <= SEHRI_HOUR:  # 03-05
        return "sehri"
    if hour <= 2 or hour >= TARAWEEH_END_HOUR:  # 22-23, 00-02
        return "late_night"
    if hour <= IFTAR_HOUR - 3:  # 06-15
        return "fasting"
    if hour <= IFTAR_HOUR - 1:  # 16-17
        return "pre_iftar"
    if hour == IFTAR_HOUR:  # 18
        return "iftar"
    if hour == IFTAR_HOUR + 1:  # 19
        return "post_iftar"
    return "taraweeh"  # 20-21


def phase_for(ctx: DayContext, hour: int) -> str:
    """Ramadan phase, or "none" outside Ramadan. The generator's entry point."""
    return ramadan_phase(hour) if ctx.is_ramadan else NOT_RAMADAN


# Self-description. `python -m app.core.pk_calendar 2025-08-01 365` prints every
# non-ordinary day in a window.
#
# This exists because the dates above are the module's factual claims, and a
# claim that cannot be inspected in one command is a claim nobody checks. It is also
# the fastest way to answer "did the dataset window actually contain a Ramadan?"
# without opening the CSV.
def _main(argv: list[str]) -> int:
    start = date.fromisoformat(argv[1]) if len(argv) > 1 else date(2025, 8, 1)
    days = int(argv[2]) if len(argv) > 2 else 365

    cal = build_calendar(start, days)
    print(f"{CALENDAR_VERSION}  window {start} .. {start + timedelta(days=days - 1)}  ({days} days)")

    ramadan_days = sum(1 for c in cal.values() if c.is_ramadan)
    holidays = sum(1 for c in cal.values() if c.is_public_holiday)
    eid_days = sum(1 for c in cal.values() if c.is_eid)
    rebound = sum(1 for c in cal.values() if c.is_eid_rebound)
    print(
        f"ramadan days {ramadan_days} | public holidays {holidays} | "
        f"eid days {eid_days} | eid rebound days {rebound}"
    )

    print("\nnotable days:")
    for day in sorted(cal):
        ctx = cal[day]
        tags = []
        if ctx.is_ramadan:
            tags.append(f"ramadan d{ctx.ramadan_day}")
        if ctx.is_public_holiday:
            tags.append(f"HOLIDAY: {ctx.holiday_name}")
        if ctx.is_eid_rebound:
            tags.append("eid rebound")
        # Print Ramadan only at its boundaries; 30 identical lines is noise.
        interesting = ctx.is_public_holiday or ctx.is_eid_rebound or ctx.ramadan_day in (1, 30)
        if interesting and tags:
            print(f"  {day} {day.strftime('%a')}  {' | '.join(tags)}")

    print("\nramadan phase map (hour -> phase):")
    print("  " + "  ".join(f"{h:02d}:{ramadan_phase(h)[:4]}" for h in range(24)))
    return 0


if __name__ == "__main__":
    import sys

    raise SystemExit(_main(sys.argv))
