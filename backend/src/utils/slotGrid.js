/**
 * slotGrid.js — what a venue's bookable hours are, with no database attached.
 *
 * The decisions that define a slot window are arithmetic: which hour a venue
 * opens, which hour it stops selling, how many days ahead the grid reaches, and
 * what one day of it costs. They are separated from services/slotService.js so
 * they can be tested without a connection — requiring db/pool.js opens one at
 * module load, which would make a unit test of this arithmetic depend on Supabase
 * being reachable.
 *
 * The SQL lives here too, as text. A query string is data, and keeping it beside
 * the numbers it interpolates is what stops the two from drifting.
 *
 * PKT, not the server's clock
 * `slots.slot_date` is a DATE and `start_time` a TIME: wall-clock values in the
 * venue's own timezone, which is Asia/Karachi. "Today" is therefore resolved by
 * the database rather than in Node. Every generator this replaced used
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

/** Pakistan is UTC+5 with no DST, so one constant is the whole timezone story. */
const PKT_TIMEZONE = 'Asia/Karachi';

/** The database's own answer to "what is now in PKT", as SQL. */
const PKT_TODAY = `(NOW() AT TIME ZONE '${PKT_TIMEZONE}')::date`;
const PKT_NOW_TIME = `(NOW() AT TIME ZONE '${PKT_TIMEZONE}')::time`;

const pad = (h) => String(h).padStart(2, '0');

/** An hour window as the string a log line or an owner-facing message prints. */
const describeWindow = (fromHour, toHour) => `${pad(fromHour)}:00-${pad(toHour)}:00`;

/**
 * The hour component of a TIME column, a 'HH:MM' string, or a number.
 *
 * node-postgres hands a TIME back as the string '08:00:00', so slicing the first
 * two characters is the whole parse. A venue open from 08:30 is treated as open
 * from 08:00 because slots are whole hours on the hour; rounding the other way
 * would hide an hour the owner sells.
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
 * Decide the hour window for one venue, and say so when there is none.
 *
 * A venue's own operating hours always win; the fallback exists for the NULL case
 * alone. `fromHour` is the first bookable hour and `toHour` is exclusive —
 * 08:00-23:00 means fifteen one-hour slots, the last of them 22:00-23:00.
 *
 * 24 is permitted as an end: a ground open "until midnight" sells the 23:00 hour,
 * whose end_time is the 24:00:00 end-of-day marker rather than a wrapped
 * 00:00:00, which would store an end earlier than its own start.
 *
 * Returning a reason rather than throwing keeps a single misconfigured venue from
 * aborting a sweep over all of them. That reason is also worth naming rather than
 * swallowing: "operating hours 23:00-08:00 are not a forward range" is an
 * owner-fixable fact, and a silent skip would leave that ground permanently
 * unbookable with nothing to show why.
 */
function resolveHours(venue = {}, overrides = {}) {
  const rawFrom = overrides.fromHour != null ? overrides.fromHour : venue.operating_hours_from;
  const rawTo = overrides.toHour != null ? overrides.toHour : venue.operating_hours_to;

  const from = Math.max(0, Math.min(23, hourOf(rawFrom, FALLBACK_FROM_HOUR)));
  const to = Math.max(1, Math.min(24, hourOf(rawTo, FALLBACK_TO_HOUR)));

  if (to <= from) {
    return {
      ok: false,
      fromHour: from,
      toHour: to,
      reason: `operating hours ${describeWindow(from, to)} are not a forward range`,
    };
  }
  return { ok: true, fromHour: from, toHour: to, reason: null };
}

/** Clamp a requested horizon into [1, MAX_HORIZON_DAYS]; anything unreadable is the default. */
function clampDays(days) {
  const n = Number(days);
  if (!Number.isFinite(n)) return HORIZON_DAYS;
  return Math.max(1, Math.min(MAX_HORIZON_DAYS, Math.floor(n)));
}

/** How many rows a complete grid holds — the denominator for "n already there". */
function gridSize(days, fromHour, toHour) {
  return clampDays(days) * Math.max(0, toHour - fromHour);
}

/**
 * The price a generated hour carries: the venue's hourly rate, base price second,
 * and 0 when it has neither. 0 is a refusal, not a price — a generator that
 * invented one would put a fake number on a real ground.
 */
function priceOf(venue = {}) {
  const n = Number(venue.price_per_hour ?? venue.base_price ?? 0);
  return Number.isFinite(n) && n > 0 ? n : 0;
}

/**
 * The grid, as one statement.
 *
 * Set-based on purpose. The call sites this replaced issued one round trip per
 * slot — 14 days x 15 hours is 210 requests to a remote Supabase pooler for a
 * single venue, and POST /owner/venues made the owner wait for all of them before
 * it answered. generate_series builds the whole grid inside Postgres, so one
 * venue costs one statement.
 *
 * `slots` has no unique constraint on (venue_id, slot_date, start_time), so
 * ON CONFLICT cannot express idempotency here and the NOT EXISTS below is what
 * provides it — per slot rather than per run, which is what makes a repeating
 * sweep safe against live data. Rows that already exist are simply not produced
 * by the SELECT, so a booked hour keeps its booking and an hour an owner blocked
 * stays blocked.
 *
 * $1 venue, $2 price, $3 days, $4 from hour, $5 to hour (exclusive).
 */
const GRID_SQL = `
  SELECT $1::uuid,
         (clock.today + d)::date,
         make_time(h, 0, 0),
         CASE WHEN h + 1 >= 24 THEN TIME '24:00:00'
              ELSE make_time(h + 1, 0, 0) END,
         $2::numeric,
         'available'::slot_status
    FROM (SELECT ${PKT_TODAY} AS today) AS clock,
         generate_series(0, $3::int - 1) AS d,
         generate_series($4::int, $5::int - 1) AS h
   WHERE NOT EXISTS (
         SELECT 1 FROM slots s
          WHERE s.venue_id = $1::uuid
            AND s.slot_date = (clock.today + d)::date
            AND s.start_time = make_time(h, 0, 0))`;

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
  resolveHours,
  clampDays,
  gridSize,
  priceOf,
  describeWindow,
  GRID_SQL,
  BOOKABLE_COUNT_SQL,
  REPRICE_SQL,
  HORIZON_DAYS,
  MAX_HORIZON_DAYS,
  FALLBACK_FROM_HOUR,
  FALLBACK_TO_HOUR,
  PKT_TIMEZONE,
};
