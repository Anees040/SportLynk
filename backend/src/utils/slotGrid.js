/**
 * slotGrid.js — what a venue's bookable hours are, with no database attached.
 *
 * The decisions that define a slot window are arithmetic: which minute a venue
 * opens, which minute it stops selling, how long one slot lasts, how many days
 * ahead the grid reaches, and what one day of it costs. They are separated from
 * services/slotService.js so they can be tested without a connection — requiring
 * db/pool.js opens one at module load, which would make a unit test of this
 * arithmetic depend on Supabase being reachable.
 *
 * Minutes, not hours
 * The grid was whole hours on the hour until owners needed three things it could
 * not express: a ground that opens at 14:30, a ground that sells 30- or 90-minute
 * slots, and a ground that runs past midnight. All three are the same change —
 * the unit of the window is a minute offset from midnight, and a slot is a
 * duration rather than an hour boundary. `operating_hours_from`/`_to` have always
 * been TIME columns with minute precision; it was this module that floored them.
 *
 * The grid is built in JavaScript and inserted with `unnest`
 * The previous version computed the whole grid inside one `generate_series`
 * statement, which was fast and set-based but could only be exercised against a
 * live database. Duration, start offset and the midnight wrap are too much
 * arithmetic to leave untestable, so `buildGrid` now produces three parallel
 * arrays and the SQL zips them back into rows. The insert is still one statement
 * per venue, and the NOT EXISTS guard still provides idempotency per slot.
 *
 * PKT, not the server's clock
 * `slots.slot_date` is a DATE and `start_time` a TIME: wall-clock values in the
 * venue's own timezone, which is Asia/Karachi. "Today" is therefore resolved by
 * the database rather than in Node, and `buildGrid` emits day *offsets* from it
 * rather than dates. Every generator this replaced used
 * `new Date().toLocaleDateString('en-CA')` or `new Date().toISOString()`, both of
 * which read the process's timezone — on Render that is UTC, and between 00:00
 * and 05:00 PKT UTC is still yesterday, so the first day of every generated
 * window landed in the past.
 */

/**
 * The horizon the player's date strip offers: today plus thirteen more.
 * lib/screens/player/venue_detail_screen.dart builds that strip with
 * `itemCount: 14`, so a shorter horizon here would leave a date the player can
 * tap with nothing on it. The two numbers are a contract; changing one without
 * the other reintroduces an empty day.
 */
const HORIZON_DAYS = 14;

/** Ceiling a caller cannot raise, so a bad argument cannot fill the table. */
const MAX_HORIZON_DAYS = 60;

/**
 * Used only where a venue has no operating_hours_from/to. Venues created before
 * migration 001 added those columns have them NULL, and 08:00-23:00 is the window
 * scripts/add_future_slots.js has always assumed for them.
 */
const FALLBACK_FROM_HOUR = 8;
const FALLBACK_TO_HOUR = 23;

/**
 * The slot lengths an owner may choose, and the length a venue has when it has
 * chosen none. The list is closed rather than free-form because every length has
 * to divide the day evenly enough to be predictable on the player's grid, and
 * because an arbitrary number (37 minutes) would produce a start time nobody can
 * read. All four divide 1440, so a window that opens on a multiple of its own
 * duration never produces a slot that straddles midnight.
 */
const ALLOWED_DURATIONS = Object.freeze([30, 60, 90, 120]);
const DEFAULT_DURATION_MINUTES = 60;

const MINUTES_PER_DAY = 1440;

/** Pakistan is UTC+5 with no DST, so one constant is the whole timezone story. */
const PKT_TIMEZONE = 'Asia/Karachi';

/** The database's own answer to "what is now in PKT", as SQL. */
const PKT_TODAY = `(NOW() AT TIME ZONE '${PKT_TIMEZONE}')::date`;
const PKT_NOW_TIME = `(NOW() AT TIME ZONE '${PKT_TIMEZONE}')::time`;

const pad = (n) => String(n).padStart(2, '0');

/** A minute offset as the 'HH:MM' a log line or an owner-facing message prints. */
function hhmm(minutes) {
  const m = ((Math.round(minutes) % MINUTES_PER_DAY) + MINUTES_PER_DAY) % MINUTES_PER_DAY;
  // 1440 is midnight at the END of a day and must not print as 00:00, which would
  // read as the start of one.
  if (Math.round(minutes) === MINUTES_PER_DAY) return '24:00';
  return `${pad(Math.floor(m / 60))}:${pad(m % 60)}`;
}

/**
 * A minute offset as the TIME literal the column stores.
 *
 * 1440 becomes the 24:00:00 end-of-day marker rather than a wrapped 00:00:00,
 * which would store an end earlier than its own start.
 */
function hhmmss(minutes) {
  const n = Math.round(minutes);
  if (n === MINUTES_PER_DAY) return '24:00:00';
  const m = ((n % MINUTES_PER_DAY) + MINUTES_PER_DAY) % MINUTES_PER_DAY;
  return `${pad(Math.floor(m / 60))}:${pad(m % 60)}:00`;
}

/**
 * An open window as the string an owner reads, with the day roll made explicit.
 *
 * `endMin` is measured from midnight of the opening day, so a window that runs to
 * 02:00 the next morning arrives here as 1560 and prints as "18:00-02:00 (+1
 * day)". Saying so matters: "18:00-02:00" alone is the one window an owner could
 * reasonably read backwards.
 */
function describeWindow(startMin, endMin) {
  const rolls = endMin > MINUTES_PER_DAY;
  return `${hhmm(startMin)}-${hhmm(endMin)}${rolls ? ' (+1 day)' : ''}`;
}

/**
 * The hour component of a TIME column, a 'HH:MM' string, or a number.
 *
 * Retained for callers that still reason in whole hours — the price model is
 * asked per hour-of-day, and REPRICE_SQL joins on EXTRACT(HOUR). A venue open
 * from 08:30 reports hour 8 here, which is what the repricer wants: the price for
 * the 08:00 hour applies to the 08:30 slot inside it.
 */
function hourOf(value, fallback) {
  if (value == null || value === '') return fallback;
  if (typeof value === 'number') {
    return Number.isFinite(value) ? Math.floor(value) : fallback;
  }
  const h = parseInt(String(value).trim().slice(0, 2), 10);
  return Number.isFinite(h) ? h : fallback;
}

/**
 * Minutes since midnight from a TIME column, an 'HH:MM[:SS]' string, or a number.
 *
 * node-postgres hands a TIME back as the string '08:30:00'. A bare number is read
 * as an hour, because that is what the `fromHour`/`toHour` overrides have always
 * passed and a caller asking for "10" means 10:00, not 00:10.
 */
function minuteOf(value, fallbackMinutes) {
  if (value == null || value === '') return fallbackMinutes;
  if (typeof value === 'number') {
    return Number.isFinite(value) ? Math.round(value * 60) : fallbackMinutes;
  }
  const m = /^(\d{1,2}):(\d{2})/.exec(String(value).trim());
  if (!m) {
    const asHour = Number(String(value).trim());
    return Number.isFinite(asHour) ? Math.round(asHour * 60) : fallbackMinutes;
  }
  return Number(m[1]) * 60 + Number(m[2]);
}

/** Clamp a minute offset into the day, including the 24:00 end marker. */
const clampMinute = (m) => Math.max(0, Math.min(MINUTES_PER_DAY, Math.round(m)));

/**
 * The slot length for one venue: the owner's choice, or 60 minutes.
 *
 * Anything outside ALLOWED_DURATIONS falls back rather than throwing. A venue row
 * written before migration 034 has the column NULL, and a single unreadable value
 * must not abort a sweep over every venue.
 */
function durationOf(venue = {}, override = null) {
  const raw = override != null ? override : venue.slot_duration_minutes;
  const n = Math.round(Number(raw));
  return ALLOWED_DURATIONS.includes(n) ? n : DEFAULT_DURATION_MINUTES;
}

/** Clamp a requested horizon into [1, MAX_HORIZON_DAYS]; anything unreadable is the default. */
function clampDays(days) {
  const n = Number(days);
  if (!Number.isFinite(n)) return HORIZON_DAYS;
  return Math.max(1, Math.min(MAX_HORIZON_DAYS, Math.floor(n)));
}

/**
 * Decide the open window and slot length for one venue, and say so when there is
 * none usable.
 *
 * A venue's own operating hours always win; the fallback exists for the NULL case
 * alone. `startMin` is the first bookable minute and `endMin` is exclusive, both
 * measured from midnight of the opening day — so a window closing after midnight
 * reports an `endMin` above 1440 and `wraps: true`.
 *
 * A closing time earlier than the opening time is read as running past midnight,
 * not as an error. That is the whole point of the change: 18:00-02:00 is how a
 * late-night futsal ground actually trades, and the previous version refused it,
 * leaving the ground permanently unbookable. The one case still refused is a
 * closing time equal to the opening time, which could mean a closed venue or a
 * 24-hour one and must not be guessed at.
 *
 * Returning a reason rather than throwing keeps a single misconfigured venue from
 * aborting a sweep over all of them. That reason is also worth naming rather than
 * swallowing: "a 90-minute slot does not fit in 08:00-09:00" is an owner-fixable
 * fact, and a silent skip would leave that ground unbookable with nothing to show
 * why.
 */
function resolveWindow(venue = {}, overrides = {}) {
  const rawFrom = overrides.from != null ? overrides.from
    : (overrides.fromHour != null ? overrides.fromHour : venue.operating_hours_from);
  const rawTo = overrides.to != null ? overrides.to
    : (overrides.toHour != null ? overrides.toHour : venue.operating_hours_to);
  const durationMin = durationOf(venue, overrides.durationMin);

  const startMin = clampMinute(minuteOf(rawFrom, FALLBACK_FROM_HOUR * 60));
  const closeMin = clampMinute(minuteOf(rawTo, FALLBACK_TO_HOUR * 60));

  const refuse = (reason) => ({
    ok: false,
    startMin,
    endMin: closeMin,
    spanMin: 0,
    durationMin,
    wraps: false,
    slotsPerDay: 0,
    hours: [],
    window: describeWindow(startMin, closeMin),
    reason,
  });

  if (closeMin === startMin) {
    return refuse(`operating hours ${hhmm(startMin)}-${hhmm(closeMin)} describe no window`
      + ' — set a closing time different from the opening time');
  }

  const wraps = closeMin < startMin;
  const spanMin = wraps ? closeMin + MINUTES_PER_DAY - startMin : closeMin - startMin;

  if (spanMin < durationMin) {
    return refuse(`a ${durationMin}-minute slot does not fit in `
      + `${describeWindow(startMin, startMin + spanMin)}`);
  }

  const { slots } = buildWindowSlots(startMin, spanMin, durationMin);
  if (!slots.length) {
    return refuse(`no ${durationMin}-minute slot fits inside a single day of `
      + `${describeWindow(startMin, startMin + spanMin)}`);
  }

  // The distinct hours-of-day a generated slot starts in, ascending. The price
  // model is asked once per entry (see slotService.repriceVenueSlots), so this is
  // what keeps a wrapped window's small hours priced rather than skipped.
  const hours = [...new Set(slots.map((s) => Math.floor(s.startMin / 60)))]
    .sort((a, b) => a - b);

  return {
    ok: true,
    startMin,
    endMin: startMin + spanMin,
    spanMin,
    durationMin,
    wraps,
    slotsPerDay: slots.length,
    hours,
    window: describeWindow(startMin, startMin + spanMin),
    reason: null,
  };
}

/**
 * One day's worth of slots for a window, as offsets inside the day it opens.
 *
 * Each entry is `{ offsetDays, startMin, endMin }` where the two minute values are
 * times of day and `offsetDays` is 0 or 1 — 1 for the part of a wrapped window
 * that falls after midnight, which belongs to the next calendar date because
 * `slot_date` plus `start_time` is wall-clock.
 *
 * A slot that would straddle midnight is dropped rather than stored. `slots` holds
 * one `slot_date` with a start and an end TIME, so such a row would carry an
 * `end_time` earlier than its own `start_time` and would misread on every screen
 * that renders it. At most one slot per day can straddle, it only happens when the
 * opening minute is not a multiple of the duration (23:30 with 90-minute slots),
 * and it costs less than one slot of unsold time — all three of which are better
 * than a row that lies about when it ends. The count is returned so a caller can
 * report it instead of quietly losing an hour.
 */
function buildWindowSlots(startMin, spanMin, durationMin) {
  const slots = [];
  let skipped = 0;
  const count = Math.floor(spanMin / durationMin);
  for (let i = 0; i < count; i += 1) {
    const from = startMin + i * durationMin;
    const to = from + durationMin;
    if (Math.floor(from / MINUTES_PER_DAY) !== Math.floor((to - 1) / MINUTES_PER_DAY)) {
      skipped += 1;
      continue;
    }
    slots.push({
      offsetDays: Math.floor(from / MINUTES_PER_DAY),
      startMin: from % MINUTES_PER_DAY,
      // (to - 1) % 1440 + 1 keeps a slot that ends exactly at midnight at 1440,
      // which hhmmss renders as the 24:00:00 marker, instead of wrapping to 0.
      endMin: ((to - 1) % MINUTES_PER_DAY) + 1,
    });
  }
  return { slots, skipped };
}

/**
 * The whole grid for one venue, as the three parallel arrays GRID_SQL zips.
 *
 * `offsets` are days from PKT today, which the database adds to its own clock, so
 * no date is ever computed in Node. A wrapped window's final night reaches one day
 * past the horizon — the night of day 13 genuinely continues into day 14 — and
 * that tail is kept rather than clipped, because clipping it would make the last
 * evening of the strip the only one that stops at midnight.
 */
function buildGrid({ days = HORIZON_DAYS, startMin, spanMin, durationMin } = {}) {
  const horizon = clampDays(days);
  const { slots, skipped } = buildWindowSlots(startMin, spanMin, durationMin);
  const offsets = [];
  const starts = [];
  const ends = [];
  for (let d = 0; d < horizon; d += 1) {
    for (const s of slots) {
      offsets.push(d + s.offsetDays);
      starts.push(hhmmss(s.startMin));
      ends.push(hhmmss(s.endMin));
    }
  }
  return {
    offsets,
    starts,
    ends,
    days: horizon,
    perDay: slots.length,
    total: offsets.length,
    skippedCrossingMidnight: skipped * horizon,
  };
}

/**
 * The price a generated slot carries: the venue's hourly rate pro-rated to the
 * slot's length, base price second, and 0 when it has neither. 0 is a refusal, not
 * a price — a generator that invented one would put a fake number on a real
 * ground.
 *
 * Pro-rating is what makes a 30-minute slot cost half an hour rather than a full
 * one. `price_per_hour` is the column's own claim about its unit, so a 90-minute
 * slot at PKR 2,000/hour is PKR 3,000 and not PKR 2,000.
 */
function priceOf(venue = {}, durationMin = DEFAULT_DURATION_MINUTES) {
  const n = Number(venue.price_per_hour ?? venue.base_price ?? 0);
  if (!(Number.isFinite(n) && n > 0)) return 0;
  const minutes = ALLOWED_DURATIONS.includes(durationMin) ? durationMin : DEFAULT_DURATION_MINUTES;
  return Math.round(n * (minutes / 60) * 100) / 100;
}

/**
 * The grid, as one statement.
 *
 * `slots` has no unique constraint on (venue_id, slot_date, start_time), so
 * ON CONFLICT cannot express idempotency here and the NOT EXISTS below is what
 * provides it — per slot rather than per run, which is what makes a repeating
 * sweep safe against live data. Rows that already exist are simply not produced
 * by the SELECT, so a booked hour keeps its booking and an hour an owner blocked
 * stays blocked.
 *
 * $1 venue, $2 price, $3 day offsets int[], $4 start times time[], $5 end times time[].
 */
const GRID_SQL = `
  SELECT $1::uuid,
         (clock.today + g.off)::date,
         g.st,
         g.et,
         $2::numeric,
         'available'::slot_status
    FROM (SELECT ${PKT_TODAY} AS today) AS clock,
         unnest($3::int[], $4::time[], $5::time[]) AS g(off, st, et)
   WHERE NOT EXISTS (
         SELECT 1 FROM slots s
          WHERE s.venue_id = $1::uuid
            AND s.slot_date = (clock.today + g.off)::date
            AND s.start_time = g.st)`;

/**
 * Retire the slots a changed window no longer contains, as one statement.
 *
 * Every predicate here is a thing that must not be destroyed, and each is listed
 * because the development database is the production database:
 *
 *   - `status = 'available'` — a booked or blocked hour is never deleted. An owner
 *     who narrows their hours still owes the bookings they already sold, so those
 *     rows stay exactly where they are and are reported to the owner instead.
 *   - no live checkout hold — a player is mid-checkout on that slot right now.
 *   - no `bookings` row — a cancelled booking returns its slot to 'available'
 *     while still referencing it, and `bookings.slot_id` has no ON DELETE clause,
 *     so deleting that slot would either fail on the foreign key or orphan a
 *     receipt. The booking history is the record of money that moved.
 *   - no live `fixtures` row — a tournament fixture reserves an hour without
 *     creating a booking (see the unblock route), so this is the only guard that
 *     stops a reshape from freeing an hour a bracket is scheduled on.
 *   - future in PKT — a past slot is history and is left alone.
 *   - not in the new grid — the point of the statement.
 *
 * $1 venue, $2 day offsets int[], $3 start times time[].
 */
const STALE_PREDICATE = `
         s.venue_id = $1::uuid
     AND s.status = 'available'
     AND (s.locked_until IS NULL OR s.locked_until <= NOW())
     AND (s.slot_date > clock.today
      OR (s.slot_date = clock.today AND s.start_time > ${PKT_NOW_TIME}))
     AND NOT EXISTS (SELECT 1 FROM bookings b WHERE b.slot_id = s.id)
     AND NOT EXISTS (SELECT 1 FROM fixtures f
                      WHERE f.slot_id = s.id AND f.status <> 'cancelled')
     AND NOT EXISTS (
           SELECT 1 FROM unnest($2::int[], $3::time[]) AS g(off, st)
            WHERE s.slot_date = (clock.today + g.off)::date
              AND s.start_time = g.st)`;

const STALE_SQL = `
  DELETE FROM slots s
   USING (SELECT ${PKT_TODAY} AS today) AS clock
   WHERE ${STALE_PREDICATE}`;

/**
 * The same set, counted rather than deleted, so a dry run can report what a real
 * reshape would retire. The predicate is shared with STALE_SQL rather than
 * restated: two copies of a destructive predicate is exactly how a dry run comes
 * to disagree with the thing it is previewing.
 */
const STALE_COUNT_SQL = `
  SELECT COUNT(*)::int AS c
    FROM slots s, (SELECT ${PKT_TODAY} AS today) AS clock
   WHERE ${STALE_PREDICATE}`;

/**
 * How many future slots a changed window strands: rows outside the new grid that
 * STALE_SQL deliberately kept because they are booked, blocked or reserved.
 *
 * Counted so the owner's "hours updated" message can name them. A narrowed window
 * that silently leaves eleven sold hours standing outside it is the kind of thing
 * an owner should be told once, not discover from a player turning up.
 *
 * $1 venue, $2 day offsets int[], $3 start times time[].
 */
const KEPT_OUTSIDE_SQL = `
  SELECT COUNT(*)::int AS c
    FROM slots s, (SELECT ${PKT_TODAY} AS today) AS clock
   WHERE s.venue_id = $1::uuid
     AND s.status <> 'available'
     AND (s.slot_date > clock.today
      OR (s.slot_date = clock.today AND s.start_time > ${PKT_NOW_TIME}))
     AND NOT EXISTS (
           SELECT 1 FROM unnest($2::int[], $3::time[]) AS g(off, st)
            WHERE s.slot_date = (clock.today + g.off)::date
              AND s.start_time = g.st)`;

/**
 * What a player can book right now, as SQL.
 *
 * Mirrors the predicate discoveryService.freeSlots filters on — available, and
 * still ahead on the PKT clock — so the number reported is the number the app
 * will show rather than a row count that merely looks healthy. A non-zero total
 * of `slots` with a zero here is exactly the aged-out window this module exists
 * to prevent, and the two figures side by side name it immediately.
 */
const BOOKABLE_COUNT_SQL = `
  SELECT COUNT(*)::int AS c
    FROM slots
   WHERE status = 'available'
     AND (slot_date > ${PKT_TODAY}
      OR (slot_date = ${PKT_TODAY} AND start_time > ${PKT_NOW_TIME}))`;

/**
 * Apply a per-hour price plan to one venue's future, bookable, system-owned slots.
 *
 * The plan arrives as three parallel arrays — hours, their prices, and the source
 * that set each ($2/$3/$4) — zipped by `unnest` into one row per hour, then joined
 * to the slots by hour-of-day. One statement reprices the whole horizon.
 *
 * Three predicates decide which slots are touched, and each matters:
 *   - `price_source <> 'owner'` (NULL included) — an owner's hand-set price is a
 *     deliberate choice; a repricing sweep must never overwrite it. NULL is legacy
 *     flat pricing, which has no owner intent and is adopted.
 *   - `status = 'available'` — a booked slot's price is what the player agreed to
 *     (and `bookings` keeps its own copy anyway); only a sellable slot is repriced.
 *   - future in PKT — a past slot cannot be sold, so repricing it is wasted work
 *     and would churn history.
 *
 * $1 venue, $2 hours int[], $3 prices numeric[], $4 sources text[].
 */
const REPRICE_SQL = `
  UPDATE slots s
     SET price = p.price,
         price_source = p.src
    FROM unnest($2::int[], $3::numeric[], $4::text[]) AS p(hour, price, src)
   WHERE s.venue_id = $1::uuid
     AND EXTRACT(HOUR FROM s.start_time)::int = p.hour
     AND s.status = 'available'
     AND (s.price_source IS NULL OR s.price_source <> 'owner')
     AND (s.slot_date > ${PKT_TODAY}
      OR (s.slot_date = ${PKT_TODAY} AND s.start_time > ${PKT_NOW_TIME}))`;

module.exports = {
  hourOf,
  minuteOf,
  durationOf,
  resolveWindow,
  buildWindowSlots,
  buildGrid,
  clampDays,
  priceOf,
  describeWindow,
  hhmm,
  hhmmss,
  GRID_SQL,
  STALE_SQL,
  STALE_COUNT_SQL,
  KEPT_OUTSIDE_SQL,
  BOOKABLE_COUNT_SQL,
  REPRICE_SQL,
  HORIZON_DAYS,
  MAX_HORIZON_DAYS,
  FALLBACK_FROM_HOUR,
  FALLBACK_TO_HOUR,
  ALLOWED_DURATIONS,
  DEFAULT_DURATION_MINUTES,
  MINUTES_PER_DAY,
  PKT_TIMEZONE,
};
