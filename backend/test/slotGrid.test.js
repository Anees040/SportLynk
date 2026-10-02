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
 * The rest of the properties, in the order they are tested:
 *   - a venue's own operating hours always beat the fallback, and NULL hours take
 *     the fallback rather than producing an empty window;
 *   - a backwards hour range is refused with a reason an owner can act on, never
 *     silently skipped;
 *   - the exclusive end means 08:00-23:00 is fifteen hours, and a ground open to
 *     midnight sells the 23:00 hour;
 *   - a horizon argument cannot be coaxed below 1 or above the ceiling;
 *   - a venue with no price yields no slots, because a generated price would be a
 *     fake number on a real ground;
 *   - the SQL carries the PKT clock and the per-slot NOT EXISTS guard, which are
 *     the two things that make a repeating sweep safe on live data.
 */
const test = require('node:test');
const assert = require('node:assert/strict');

const grid = require('../src/utils/slotGrid');

/** The player's date strip: lib/screens/player/venue_detail_screen.dart, itemCount. */
const PLAYER_DATE_STRIP_DAYS = 14;

/** What jobs/slotMaintenanceJob.js asks for each sweep, restated independently. */
const SWEEP_HORIZON_DAYS = grid.HORIZON_DAYS + 1;

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
  const r = grid.resolveHours({
    operating_hours_from: '06:00:00',
    operating_hours_to: '23:00:00',
  });
  assert.equal(r.ok, true);
  assert.equal(r.fromHour, 6);
  assert.equal(r.toHour, 23);
  // The regression: four call sites hardcoded 18:00-22:00 and ignored the column
  // entirely, so a ground open from 06:00 sold five evening hours and nothing else.
  assert.notEqual(r.fromHour, 18);
});

test('NULL operating hours take the fallback window, not an empty one', () => {
  const r = grid.resolveHours({ operating_hours_from: null, operating_hours_to: null });
  assert.equal(r.ok, true);
  assert.equal(r.fromHour, grid.FALLBACK_FROM_HOUR);
  assert.equal(r.toHour, grid.FALLBACK_TO_HOUR);
  assert.ok(grid.gridSize(1, r.fromHour, r.toHour) > 0);
});

test('an explicit override beats both the venue and the fallback', () => {
  const r = grid.resolveHours(
    { operating_hours_from: '06:00:00', operating_hours_to: '23:00:00' },
    { fromHour: 10, toHour: 14 },
  );
  assert.deepEqual([r.fromHour, r.toHour], [10, 14]);
});

test('a backwards hour range is refused with an owner-actionable reason', () => {
  const r = grid.resolveHours({
    operating_hours_from: '23:00:00',
    operating_hours_to: '08:00:00',
  });
  assert.equal(r.ok, false);
  assert.match(r.reason, /not a forward range/);
  assert.match(r.reason, /23:00-08:00/);
});

test('equal open and close hours produce no window rather than a full day', () => {
  const r = grid.resolveHours({
    operating_hours_from: '09:00:00',
    operating_hours_to: '09:00:00',
  });
  assert.equal(r.ok, false);
});

test('the end hour is exclusive, so 08:00-23:00 is fifteen hours', () => {
  assert.equal(grid.gridSize(1, 8, 23), 15);
  assert.equal(grid.gridSize(grid.HORIZON_DAYS, 8, 23), 14 * 15);
  // What the old hardcoded evening strip produced, for contrast.
  assert.equal(grid.gridSize(1, 18, 22), 4);
});

test('a ground open to midnight keeps the 23:00 hour and is not wrapped', () => {
  const r = grid.resolveHours({
    operating_hours_from: '18:00:00',
    operating_hours_to: '24:00:00',
  });
  assert.equal(r.ok, true);
  assert.equal(r.toHour, 24);
  assert.equal(grid.gridSize(1, r.fromHour, r.toHour), 6);
  // make_time(24,0,0) is out of range in Postgres, so the grid has to reach the
  // end-of-day marker by literal. An end of 00:00:00 would store end < start.
  assert.match(grid.GRID_SQL, /TIME '24:00:00'/);
});

test('hour parsing reads a TIME column, a HH:MM string and a number', () => {
  assert.equal(grid.hourOf('08:00:00', 0), 8);
  assert.equal(grid.hourOf('18:30', 0), 18);
  assert.equal(grid.hourOf(7, 0), 7);
  assert.equal(grid.hourOf(null, 9), 9);
  assert.equal(grid.hourOf('', 9), 9);
  assert.equal(grid.hourOf('not a time', 9), 9);
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

test('the grid is guarded per slot, so a repeating sweep cannot disturb live rows', () => {
  // Without this guard the sweep would double every slot on each run: `slots` has
  // no unique constraint on (venue_id, slot_date, start_time), so ON CONFLICT
  // cannot express idempotency and NOT EXISTS is the only thing that does.
  assert.match(grid.GRID_SQL, /NOT EXISTS/);
  assert.match(grid.GRID_SQL, /s\.venue_id = \$1::uuid/);
  assert.match(grid.GRID_SQL, /s\.slot_date = \(clock\.today \+ d\)::date/);
  assert.match(grid.GRID_SQL, /s\.start_time = make_time\(h, 0, 0\)/);
  // Additive only. An UPDATE or DELETE here would reach booked and blocked rows.
  assert.doesNotMatch(grid.GRID_SQL, /\b(UPDATE|DELETE|TRUNCATE|DROP)\b/i);
});

test('both generated and bookable SQL resolve the date in PKT, not the server clock', () => {
  // The regression: generators used new Date().toLocaleDateString('en-CA') and
  // new Date().toISOString(), both of which read the process timezone. On Render
  // that is UTC, where between 00:00 and 05:00 PKT the date is still yesterday —
  // so the first day of every generated window landed in the past.
  for (const sql of [grid.GRID_SQL, grid.BOOKABLE_COUNT_SQL]) {
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

test('a window is described the way a log line and an owner message print it', () => {
  assert.equal(grid.describeWindow(8, 23), '08:00-23:00');
  assert.equal(grid.describeWindow(18, 24), '18:00-24:00');
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
