/**
 * slotGrid.test.js — the arithmetic that decides whether a ground is bookable.
 *
 * Same discipline as test/fixtureSchedule.test.js: no database, no ml-service, no
 * clock. utils/slotGrid.js is deliberately free of db/pool so these cases can run
 * without Supabase being reachable, and a failure here is a failure of the grid
 * rules and never of the environment.
 *
 * The defect these cases exist to prevent
 * Every slot generator in the project used to write a fixed window once, at the
 * moment a venue was created, and nothing extended it. Fourteen days later every
 * slot had aged into the past and the venue page showed "No slots available" on a
 * ground whose rows were all still in the table. Two properties below are what
 * make that unrepeatable: the horizon must cover every date the player's strip
 * can reach, and the sweep must stay strictly ahead of that horizon so the far
 * edge is filled before it becomes reachable at PKT midnight.
 *
 * What the owner-slot-shape change added, and why each property is pinned
 *   - a slot is a duration, not an hour boundary, so 30/90/120-minute grids and a
 *     14:30 opening offset are expressible at all;
 *   - a closing time below the opening time runs past midnight instead of being
 *     refused, which is how a late-night ground actually trades;
 *   - a slot that would straddle midnight is dropped rather than stored, because
 *     one `slot_date` with a start and end TIME cannot hold an end on the next
 *     date without reading as an end before its own start;
 *   - the grid is built here and inserted with `unnest`, so every one of those
 *     rules is provable without a connection;
 *   - the retire statement is the only destructive SQL in the module, and the five
 *     things it refuses to touch are asserted one by one.
 */
const test = require('node:test');
const assert = require('node:assert/strict');

const grid = require('../src/utils/slotGrid');

/** The player's date strip: lib/screens/player/venue_detail_screen.dart, itemCount. */
const PLAYER_DATE_STRIP_DAYS = 14;

/** What jobs/slotMaintenanceJob.js asks for each sweep, restated independently. */
const SWEEP_HORIZON_DAYS = grid.HORIZON_DAYS + 1;

/** A window in minutes, so the expectations below read as times rather than sums. */
const at = (h, m = 0) => h * 60 + m;

test('horizon covers every date the player date strip can reach', () => {
  // The bug this guards: a horizon shorter than the strip leaves a date the
  // player can tap with nothing on it, which renders as "No slots available" on
  // a working venue.
  assert.ok(
    grid.HORIZON_DAYS >= PLAYER_DATE_STRIP_DAYS,
    `horizon ${grid.HORIZON_DAYS} must cover the ${PLAYER_DATE_STRIP_DAYS}-day strip`,
  );
});

test('the sweep stays strictly ahead of the reachable horizon', () => {
  // At PKT midnight the strip gains a day. Generating exactly HORIZON_DAYS would
  // leave that new far edge empty until the next sweep ran.
  assert.ok(
    SWEEP_HORIZON_DAYS > grid.HORIZON_DAYS,
    'the sweep must generate at least one day beyond the reachable horizon',
  );
  assert.ok(SWEEP_HORIZON_DAYS <= grid.MAX_HORIZON_DAYS);
});

test("a venue's own operating hours beat the fallback", () => {
  const r = grid.resolveWindow({
    operating_hours_from: '06:00:00',
    operating_hours_to: '23:00:00',
  });
  assert.equal(r.ok, true);
  assert.equal(r.startMin, at(6));
  assert.equal(r.endMin, at(23));
  // The regression: four call sites hardcoded 18:00-22:00 and ignored the column
  // entirely, so a ground open from 06:00 sold five evening hours and nothing else.
  assert.notEqual(r.startMin, at(18));
});

test('NULL operating hours take the fallback window, not an empty one', () => {
  const r = grid.resolveWindow({ operating_hours_from: null, operating_hours_to: null });
  assert.equal(r.ok, true);
  assert.equal(r.startMin, grid.FALLBACK_FROM_HOUR * 60);
  assert.equal(r.endMin, grid.FALLBACK_TO_HOUR * 60);
  assert.ok(r.slotsPerDay > 0);
});

test('an explicit override beats both the venue and the fallback', () => {
  const r = grid.resolveWindow(
    { operating_hours_from: '06:00:00', operating_hours_to: '23:00:00' },
    { fromHour: 10, toHour: 14 },
  );
  assert.deepEqual([r.startMin, r.endMin], [at(10), at(14)]);
});

test('a minute-precision opening time survives instead of being floored to the hour', () => {
  // The regression this closes: operating_hours_from has been a TIME since
  // migration 001, and the generator read only its first two characters — so a
  // ground opening at 14:30 was generated as opening at 14:00 and sold half an
  // hour it was not open for.
  const r = grid.resolveWindow({
    operating_hours_from: '14:30:00',
    operating_hours_to: '18:00:00',
  });
  assert.equal(r.ok, true);
  assert.equal(r.startMin, at(14, 30));
  const { slots } = grid.buildWindowSlots(r.startMin, r.spanMin, r.durationMin);
  // 14:30 open with 60-minute slots gives 14:30, 15:30, 16:30 — the half-hour
  // remaining before 18:00 is not sold as a whole slot.
  assert.deepEqual(slots.map((s) => grid.hhmm(s.startMin)), ['14:30', '15:30', '16:30']);
});

test('a closing time below the opening time runs past midnight rather than failing', () => {
  // Previously refused as "not a forward range", which left every late-night
  // ground permanently unbookable with nothing to show why.
  const r = grid.resolveWindow({
    operating_hours_from: '18:00:00',
    operating_hours_to: '02:00:00',
  });
  assert.equal(r.ok, true);
  assert.equal(r.wraps, true);
  assert.equal(r.spanMin, 8 * 60);
  assert.equal(r.slotsPerDay, 8);
  assert.equal(r.window, '18:00-02:00 (+1 day)');
});

test('the small hours of a wrapped window land on the next calendar date', () => {
  // slot_date plus start_time is wall-clock, so 01:00 after a Monday evening is
  // Tuesday 01:00. Storing it on Monday would put a slot on the player's Monday
  // strip that the venue is not open for on Monday.
  const r = grid.resolveWindow({
    operating_hours_from: '18:00:00',
    operating_hours_to: '02:00:00',
  });
  const { slots, skipped } = grid.buildWindowSlots(r.startMin, r.spanMin, r.durationMin);
  assert.equal(skipped, 0);
  assert.deepEqual(
    slots.map((s) => `${s.offsetDays}@${grid.hhmm(s.startMin)}`),
    ['0@18:00', '0@19:00', '0@20:00', '0@21:00', '0@22:00', '0@23:00', '1@00:00', '1@01:00'],
  );
  // The 23:00 slot ends at the end-of-day marker, not at a wrapped 00:00 that
  // would store an end earlier than its own start.
  assert.equal(grid.hhmmss(slots[5].endMin), '24:00:00');
});

test('a wrapped window is priced across the hours it actually covers', () => {
  // The repricer asks the model once per entry. A `for (h = from; h < to)` loop
  // cannot express 18..23 plus 00..01, so those two hours would never be priced.
  const r = grid.resolveWindow({
    operating_hours_from: '18:00:00',
    operating_hours_to: '02:00:00',
  });
  assert.deepEqual(r.hours, [0, 1, 18, 19, 20, 21, 22, 23]);
});

test('a slot that would straddle midnight is dropped, not stored backwards', () => {
  // 22:00-02:00 in 90-minute slots: 22:00-23:30 fits, 23:30-01:00 does not. The
  // alternative is a row whose end_time is earlier than its start_time, which
  // misreads on every screen that renders it.
  const r = grid.resolveWindow({
    operating_hours_from: '22:00:00',
    operating_hours_to: '02:00:00',
    slot_duration_minutes: 90,
  });
  assert.equal(r.ok, true);
  assert.equal(r.slotsPerDay, 1);
  const { slots, skipped } = grid.buildWindowSlots(r.startMin, r.spanMin, r.durationMin);
  assert.equal(skipped, 1);
  assert.deepEqual(slots.map((s) => grid.hhmm(s.startMin)), ['22:00']);
});

test('equal open and close times are refused rather than guessed at', () => {
  // Could mean a closed venue or a 24-hour one. Guessing either would be wrong
  // for the other, so the owner is asked.
  const r = grid.resolveWindow({
    operating_hours_from: '09:00:00',
    operating_hours_to: '09:00:00',
  });
  assert.equal(r.ok, false);
  assert.match(r.reason, /describe no window/);
  assert.match(r.reason, /09:00-09:00/);
});

test('a slot longer than the whole window is refused with an owner-actionable reason', () => {
  const r = grid.resolveWindow({
    operating_hours_from: '08:00:00',
    operating_hours_to: '09:00:00',
    slot_duration_minutes: 120,
  });
  assert.equal(r.ok, false);
  assert.match(r.reason, /120-minute slot does not fit/);
  assert.match(r.reason, /08:00-09:00/);
});

test('the slot length is the one the owner chose, and anything else is the default', () => {
  assert.equal(grid.durationOf({ slot_duration_minutes: 30 }), 30);
  assert.equal(grid.durationOf({ slot_duration_minutes: 90 }), 90);
  assert.equal(grid.durationOf({ slot_duration_minutes: '120' }), 120);
  // A venue row read before migration 034 has no such column at all.
  assert.equal(grid.durationOf({}), grid.DEFAULT_DURATION_MINUTES);
  // Out-of-range values fall back rather than throwing: one unreadable venue must
  // not abort a sweep over every venue.
  assert.equal(grid.durationOf({ slot_duration_minutes: 45 }), grid.DEFAULT_DURATION_MINUTES);
  assert.equal(grid.durationOf({ slot_duration_minutes: 0 }), grid.DEFAULT_DURATION_MINUTES);
  assert.equal(grid.durationOf({ slot_duration_minutes: null }), grid.DEFAULT_DURATION_MINUTES);
});

test('every allowed slot length divides the day, so an aligned window never straddles midnight', () => {
  // The property that keeps the dropped-slot case rare: it can only happen when
  // the opening minute is not a multiple of the duration.
  for (const d of grid.ALLOWED_DURATIONS) {
    assert.equal(grid.MINUTES_PER_DAY % d, 0, `${d} must divide ${grid.MINUTES_PER_DAY}`);
  }
});

test('the closing time is exclusive, so 08:00-23:00 is fifteen hours', () => {
  const counts = {};
  for (const d of grid.ALLOWED_DURATIONS) {
    counts[d] = grid.buildWindowSlots(at(8), at(23) - at(8), d).slots.length;
  }
  assert.equal(counts[60], 15);
  assert.equal(counts[30], 30);
  assert.equal(counts[90], 10);
  // 900 minutes holds seven two-hour slots with 60 minutes left over, which is not
  // sold as a short slot.
  assert.equal(counts[120], 7);
});

test('a ground open to midnight keeps the 23:00 hour and is not treated as wrapped', () => {
  const r = grid.resolveWindow({
    operating_hours_from: '18:00:00',
    operating_hours_to: '24:00:00',
  });
  assert.equal(r.ok, true);
  assert.equal(r.wraps, false);
  assert.equal(r.slotsPerDay, 6);
  assert.equal(r.window, '18:00-24:00');
});

test('the grid spans the horizon, and a wrapped window keeps its final night', () => {
  const r = grid.resolveWindow({
    operating_hours_from: '18:00:00',
    operating_hours_to: '02:00:00',
  });
  const plan = grid.buildGrid({ days: 3, startMin: r.startMin, spanMin: r.spanMin, durationMin: r.durationMin });
  assert.equal(plan.days, 3);
  assert.equal(plan.perDay, 8);
  assert.equal(plan.total, 24);
  assert.equal(plan.offsets.length, plan.starts.length);
  assert.equal(plan.starts.length, plan.ends.length);
  // Day 2's evening runs into day 3's small hours. Clipping that tail would make
  // the last night of the strip the only one that stops at midnight.
  assert.equal(Math.max(...plan.offsets), 3);
  assert.equal(Math.min(...plan.offsets), 0);
});

test('hour parsing reads a TIME column, a HH:MM string and a number', () => {
  assert.equal(grid.hourOf('08:00:00', 0), 8);
  assert.equal(grid.hourOf('18:30', 0), 18);
  assert.equal(grid.hourOf(7, 0), 7);
  assert.equal(grid.hourOf(null, 9), 9);
  assert.equal(grid.hourOf('', 9), 9);
  assert.equal(grid.hourOf('not a time', 9), 9);
});

test('minute parsing keeps the minutes a TIME column carries', () => {
  assert.equal(grid.minuteOf('08:00:00', 0), at(8));
  assert.equal(grid.minuteOf('14:30:00', 0), at(14, 30));
  assert.equal(grid.minuteOf('18:45', 0), at(18, 45));
  assert.equal(grid.minuteOf('24:00:00', 0), at(24));
  // A bare number is an hour: the fromHour/toHour overrides have always passed one,
  // and a caller asking for 10 means 10:00 rather than 00:10.
  assert.equal(grid.minuteOf(10, 0), at(10));
  assert.equal(grid.minuteOf(null, at(9)), at(9));
  assert.equal(grid.minuteOf('', at(9)), at(9));
  assert.equal(grid.minuteOf('not a time', at(9)), at(9));
});

test('a minute offset renders as the TIME literal the column stores', () => {
  assert.equal(grid.hhmmss(at(8)), '08:00:00');
  assert.equal(grid.hhmmss(at(14, 30)), '14:30:00');
  // The end-of-day marker, not a wrapped 00:00:00. make_time(24,0,0) is out of
  // range in Postgres, so the grid reaches midnight by literal.
  assert.equal(grid.hhmmss(grid.MINUTES_PER_DAY), '24:00:00');
  assert.equal(grid.hhmm(grid.MINUTES_PER_DAY), '24:00');
});

test('the horizon cannot be driven below one day or above the ceiling', () => {
  assert.equal(grid.clampDays(0), 1);
  assert.equal(grid.clampDays(-5), 1);
  assert.equal(grid.clampDays(1000), grid.MAX_HORIZON_DAYS);
  assert.equal(grid.clampDays('7'), 7);
  assert.equal(grid.clampDays(7.9), 7);
  assert.equal(grid.clampDays(undefined), grid.HORIZON_DAYS);
  assert.equal(grid.clampDays('not a number'), grid.HORIZON_DAYS);
});

test('a venue with no price yields no price, never an invented one', () => {
  assert.equal(grid.priceOf({ price_per_hour: 2500 }), 2500);
  assert.equal(grid.priceOf({ price_per_hour: null, base_price: 1800 }), 1800);
  assert.equal(grid.priceOf({ price_per_hour: '2000' }), 2000);
  assert.equal(grid.priceOf({}), 0);
  assert.equal(grid.priceOf({ price_per_hour: 0 }), 0);
  assert.equal(grid.priceOf({ price_per_hour: -100 }), 0);
});

test('a short slot costs a fraction of the hour, because the column is per hour', () => {
  // price_per_hour is the column's own claim about its unit. A 30-minute slot
  // charged a full hourly rate would overcharge by 100%, and a 90-minute slot
  // charged one hour would undercharge by a third.
  assert.equal(grid.priceOf({ price_per_hour: 2000 }, 30), 1000);
  assert.equal(grid.priceOf({ price_per_hour: 2000 }, 60), 2000);
  assert.equal(grid.priceOf({ price_per_hour: 2000 }, 90), 3000);
  assert.equal(grid.priceOf({ price_per_hour: 2000 }, 120), 4000);
  // An unrecognised duration is priced as an hour rather than as a guess.
  assert.equal(grid.priceOf({ price_per_hour: 2000 }, 45), 2000);
});

test('the grid is guarded per slot, so a repeating sweep cannot disturb live rows', () => {
  // Without this guard the sweep would double every slot on each run: `slots` has
  // no unique constraint on (venue_id, slot_date, start_time), so ON CONFLICT
  // cannot express idempotency and NOT EXISTS is the only thing that does.
  assert.match(grid.GRID_SQL, /NOT EXISTS/);
  assert.match(grid.GRID_SQL, /s\.venue_id = \$1::uuid/);
  assert.match(grid.GRID_SQL, /s\.slot_date = \(clock\.today \+ g\.off\)::date/);
  assert.match(grid.GRID_SQL, /s\.start_time = g\.st/);
  // Additive only. An UPDATE or DELETE here would reach booked and blocked rows.
  assert.doesNotMatch(grid.GRID_SQL, /\b(UPDATE|DELETE|TRUNCATE|DROP)\b/i);
});

test('the grid zips day offsets and times, so no date is computed in Node', () => {
  assert.match(grid.GRID_SQL, /unnest\(\$3::int\[\], \$4::time\[\], \$5::time\[\]\)/);
  assert.match(grid.GRID_SQL, /clock\.today \+ g\.off/);
});

test('both generated and bookable SQL resolve the date in PKT, not the server clock', () => {
  // The regression: generators used new Date().toLocaleDateString('en-CA') and
  // new Date().toISOString(), both of which read the process timezone. On Render
  // that is UTC, where between 00:00 and 05:00 PKT the date is still yesterday —
  // so the first day of every generated window landed in the past.
  for (const sql of [grid.GRID_SQL, grid.BOOKABLE_COUNT_SQL, grid.STALE_SQL, grid.KEPT_OUTSIDE_SQL]) {
    assert.match(sql, /AT TIME ZONE 'Asia\/Karachi'/);
    assert.doesNotMatch(sql, /CURRENT_DATE|CURRENT_TIME/);
  }
  assert.equal(grid.PKT_TIMEZONE, 'Asia/Karachi');
});

test('the bookable predicate matches what the venue page shows', () => {
  // discoveryService shows a future date in full and today only from now on. A
  // count that disagreed would report a healthy platform while players saw none.
  assert.match(grid.BOOKABLE_COUNT_SQL, /status = 'available'/);
  assert.match(grid.BOOKABLE_COUNT_SQL, /slot_date >/);
  assert.match(grid.BOOKABLE_COUNT_SQL, /start_time >/);
});

test('retiring a stale slot refuses every row that is not safe to delete', () => {
  // This is the only destructive statement in the module and it runs against a
  // database holding real bookings, so each guard is pinned individually.
  assert.match(grid.STALE_SQL, /\bDELETE FROM slots\b/);
  // Sold or withheld inventory is never deleted — an owner who narrows their hours
  // still owes the bookings they already took.
  assert.match(grid.STALE_SQL, /s\.status = 'available'/);
  // A player mid-checkout holds the slot.
  assert.match(grid.STALE_SQL, /s\.locked_until IS NULL OR s\.locked_until <= NOW\(\)/);
  // A cancelled booking still references its slot, and bookings.slot_id has no
  // ON DELETE clause: deleting the slot would fail the key or orphan a receipt.
  assert.match(grid.STALE_SQL, /FROM bookings b WHERE b\.slot_id = s\.id/);
  // A tournament fixture reserves an hour with no booking row behind it.
  assert.match(grid.STALE_SQL, /FROM fixtures f\s+WHERE f\.slot_id = s\.id AND f\.status <> 'cancelled'/);
  // Past slots are history.
  assert.match(grid.STALE_SQL, /s\.slot_date > clock\.today/);
  // And it only reaches rows the new grid does not contain.
  assert.match(grid.STALE_SQL, /unnest\(\$2::int\[\], \$3::time\[\]\)/);
});

test('the dry run counts exactly what the real retire would delete', () => {
  // Two copies of a destructive predicate is how a preview comes to disagree with
  // the thing it previews, so the count shares the predicate rather than restating
  // it. Asserted by comparing the WHERE bodies.
  const whereOf = (sql) => sql.slice(sql.indexOf('WHERE') + 5).trim();
  assert.equal(whereOf(grid.STALE_COUNT_SQL), whereOf(grid.STALE_SQL));
  assert.match(grid.STALE_COUNT_SQL, /^\s*SELECT COUNT/);
  assert.doesNotMatch(grid.STALE_COUNT_SQL, /\b(DELETE|UPDATE|DROP|TRUNCATE)\b/i);
});

test('the stranded count reports only the rows the retire deliberately kept', () => {
  // What an owner is told after narrowing their hours: how many sold, blocked or
  // reserved slots now stand outside the window.
  assert.match(grid.KEPT_OUTSIDE_SQL, /s\.status <> 'available'/);
  assert.match(grid.KEPT_OUTSIDE_SQL, /^\s*SELECT COUNT/);
  assert.doesNotMatch(grid.KEPT_OUTSIDE_SQL, /\b(DELETE|UPDATE|DROP|TRUNCATE)\b/i);
});

test('a window is described the way a log line and an owner message print it', () => {
  assert.equal(grid.describeWindow(at(8), at(23)), '08:00-23:00');
  assert.equal(grid.describeWindow(at(18), at(24)), '18:00-24:00');
  // The day roll is stated: "18:00-02:00" alone is the one window an owner could
  // reasonably read backwards.
  assert.equal(grid.describeWindow(at(18), at(26)), '18:00-02:00 (+1 day)');
});

test('repricing never overwrites an owner-set price, and only touches sellable future slots', () => {
  // The guarantee dynamic pricing rests on: a sweep reprices model/heuristic/legacy
  // slots but must leave a price an owner chose by hand exactly as it is.
  assert.match(grid.REPRICE_SQL, /price_source IS NULL OR s\.price_source <> 'owner'/);
  // Only an available slot is repriced — a booked slot's price is what the player
  // agreed to, and the booking keeps its own copy regardless.
  assert.match(grid.REPRICE_SQL, /s\.status = 'available'/);
  // Future only, in PKT — repricing a past slot is wasted work and churns history.
  assert.match(grid.REPRICE_SQL, /AT TIME ZONE 'Asia\/Karachi'/);
  assert.match(grid.REPRICE_SQL, /s\.slot_date >/);
});

test('repricing zips three parallel arrays into one row per hour, joined by hour-of-day', () => {
  // hours int[], prices numeric[], sources text[] — one UPDATE for the whole horizon.
  assert.match(grid.REPRICE_SQL, /unnest\(\$2::int\[\], \$3::numeric\[\], \$4::text\[\]\)/);
  assert.match(grid.REPRICE_SQL, /EXTRACT\(HOUR FROM s\.start_time\)::int = p\.hour/);
  // It is an UPDATE of price/price_source — never a destructive statement.
  assert.match(grid.REPRICE_SQL, /\bUPDATE slots\b/);
  assert.doesNotMatch(grid.REPRICE_SQL, /\b(DELETE|DROP|TRUNCATE|INSERT)\b/i);
});
