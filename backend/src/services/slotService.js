/**
 * slotService.js — the one place a venue's bookable hours are created.
 *
 * Why this file exists
 * Five call sites used to build the same grid by hand: admin owner-approval,
 * POST /owner/venues, autoGenerateVenueIfMissing, POST /owner/slots/generate and
 * scripts/add_future_slots.js. They disagreed on all three things that matter —
 * the horizon (14 days or 7), the hour window (18:00-22:00 hardcoded, or the
 * venue's own operating hours), and the clock (the Node process's local date, or
 * PKT) — so which hours a ground offered depended on which code path had last
 * touched it. The grid is defined once in utils/slotGrid.js, this file performs
 * the I/O, and those call sites are transport.
 *
 * The defect this fixes
 * Every one of those sites wrote a fixed-length window once, at the moment a
 * venue was created, and nothing ever extended it. A venue was therefore bookable
 * for exactly 14 days and then silently stopped: the slots did not disappear,
 * they aged into the past, discoveryService correctly filtered them out, and the
 * venue page painted "No slots available" on a ground whose rows were all still
 * there. The only cure was to run add_future_slots.js by hand, which made a
 * rolling window a human responsibility. jobs/slotMaintenanceJob.js now calls
 * ensureActiveVenueSlots on a schedule, so the window rolls forward on its own.
 *
 * Additive, and safe to run against live data
 * Nothing here updates or deletes a row; utils/slotGrid.js guards every insert
 * with a NOT EXISTS on (venue_id, slot_date, start_time). That is what makes a
 * repeating sweep acceptable on a database holding real bookings:
 *
 *   - a 'booked' hour keeps its booking, because the row already exists;
 *   - an hour an owner blocked stays blocked, for the same reason — PATCH
 *     /owner/slots/:id/block sets status, it does not delete the row, so there is
 *     no gap for this service to fill back in as available;
 *   - a live checkout hold (slots.locked_until) is untouched.
 */
const pool = require('../db/pool');
const grid = require('../utils/slotGrid');
const mlClient = require('./mlClient');

/** The columns the generator and the repricer need to decide a venue's window,
 *  base price, and the sport/city/rating the price model is asked about. */
const VENUE_COLUMNS = `id, name, city, sport_type, rating, price_per_hour, base_price,
                       operating_hours_from, operating_hours_to`;

/**
 * Fill the gaps in one venue's rolling window.
 *
 * `runner` is a pool or a checked-out client, so a caller already inside a
 * transaction (admin owner-approval) keeps its atomicity and a caller that is not
 * (the sweep) pays for no transaction it does not need.
 *
 * Returns `{ created, skipped, expected, skippedVenue, reason, fromHour, toHour }`.
 * A venue is skipped rather than failed when it has no usable price or no forward
 * hour range, because neither is this service's business to invent.
 */
async function ensureVenueSlots(runner, {
  venueId,
  venue = null,
  days = grid.HORIZON_DAYS,
  fromHour = null,
  toHour = null,
  price = null,
  dryRun = false,
} = {}) {
  const db = runner || pool;
  const id = String(venueId == null ? '' : venueId).trim();
  if (!id) throw new Error('ensureVenueSlots requires a venueId');

  const refuse = (reason) => ({
    created: 0, skipped: 0, expected: 0, skippedVenue: true, reason,
    fromHour: null, toHour: null,
  });

  // The venue's price and hours are read here only when the caller did not
  // already have the row, so a caller holding it does not pay for a second read.
  let row = venue;
  if (!row) {
    const r = await db.query(`SELECT ${VENUE_COLUMNS} FROM venues WHERE id = $1`, [id]);
    if (!r.rows.length) return refuse('venue not found');
    row = r.rows[0];
  }

  const hours = grid.resolveHours(row, {
    fromHour: fromHour == null ? undefined : fromHour,
    toHour: toHour == null ? undefined : toHour,
  });
  if (!hours.ok) return refuse(hours.reason);

  const rate = price != null && Number(price) > 0 ? Number(price) : grid.priceOf(row);
  if (!(rate > 0)) return refuse('no price set');

  const horizon = grid.clampDays(days);
  const expected = grid.gridSize(horizon, hours.fromHour, hours.toHour);
  const params = [id, rate, horizon, hours.fromHour, hours.toHour];

  let created = 0;
  if (dryRun) {
    const r = await db.query(`SELECT COUNT(*)::int AS c FROM (${grid.GRID_SQL}) g`, params);
    created = r.rows[0].c;
  } else {
    const r = await db.query(
      `INSERT INTO slots (venue_id, slot_date, start_time, end_time, price, status)
       ${grid.GRID_SQL}`,
      params,
    );
    created = r.rowCount;
  }

  return {
    created,
    skipped: Math.max(0, expected - created),
    expected,
    skippedVenue: false,
    reason: null,
    fromHour: hours.fromHour,
    toHour: hours.toHour,
  };
}

/**
 * Fill the gaps for every active venue — what the sweep calls.
 *
 * Active only, and deliberately: a venue awaiting admin approval is
 * `is_active = false` and invisible to players, so there is nothing to keep
 * bookable yet. Nothing special has to happen when it is approved either — the
 * next sweep sees it and fills its window, which is what makes this process
 * convergent rather than event-driven, and what makes a narrow window written by
 * whichever route created the venue harmless.
 *
 * One statement per venue rather than one for all of them. A single INSERT across
 * every venue would be fewer round trips, but one venue with unusable data would
 * then have to be excluded in SQL instead of reported by name, and the per-venue
 * counts that make the log readable would be gone.
 *
 * A venue whose statement throws is recorded and the loop continues. This is not
 * a swallowed error — the reason is carried out in `results` for the caller to
 * log, and the same discipline as jobs/matchExpiryJob.js applies: a failure costs
 * one venue, which the next sweep retries. Letting it propagate would mean one
 * unreachable row stopped every venue alphabetically after it from being filled,
 * turning a single bad record into a platform-wide outage of the booking grid.
 */
async function ensureActiveVenueSlots({
  days = grid.HORIZON_DAYS,
  venueId = null,
  dryRun = false,
  runner = null,
} = {}) {
  const db = runner || pool;
  const venues = await db.query(
    `SELECT ${VENUE_COLUMNS}
       FROM venues
      WHERE is_active = true
        ${venueId ? 'AND id = $1' : ''}
      ORDER BY name`,
    venueId ? [venueId] : [],
  );

  const results = [];
  let created = 0;
  let skipped = 0;
  for (const v of venues.rows) {
    try {
      const r = await ensureVenueSlots(db, { venueId: v.id, venue: v, days, dryRun });
      created += r.created;
      skipped += r.skipped;
      results.push({ id: v.id, name: v.name, ...r });
    } catch (e) {
      results.push({
        id: v.id, name: v.name, created: 0, skipped: 0, expected: 0,
        skippedVenue: true, failed: true, reason: e.message,
        fromHour: null, toHour: null,
      });
    }
  }
  return { venues: venues.rows.length, created, skipped, results };
}

/** What a player can book right now, across the whole platform. */
async function countBookable(runner = null) {
  const db = runner || pool;
  const { rows } = await db.query(grid.BOOKABLE_COUNT_SQL);
  return rows[0].c;
}

/**
 * One representative future date (PKT tomorrow) prices every day of the horizon, so
 * a slot's price varies by hour-of-day and not by date — intra-day dynamic pricing.
 * Day-of-week variation is deliberately out of scope (see the plan). PKT is UTC+5,
 * no DST, so the offset is a constant.
 */
function pricingDate() {
  const PKT_OFFSET_MS = 5 * 60 * 60 * 1000;
  return new Date(Date.now() + PKT_OFFSET_MS + 24 * 60 * 60 * 1000)
    .toISOString()
    .slice(0, 10);
}

/**
 * Price one venue's future, available, system-owned slots by the model — varied by
 * hour, so a peak evening costs more than a quiet afternoon. This is what makes the
 * trained price model (model #1) visible to players rather than an owner-dashboard
 * suggestion nobody applied.
 *
 * The model is asked once per distinct open hour on a representative date (~15
 * calls, not one per slot), in parallel, and the per-hour result is applied across
 * the whole horizon by hour-of-day via grid.REPRICE_SQL.
 *
 * NEVER call this inside a transaction. mlClient.suggestPrice makes a network call
 * to ml-service, and holding a DB client open across it is the latency trap
 * bookingService exists to avoid. Callers use the pool, after any booking/approval
 * txn has committed, or fire-and-forget after responding.
 *
 * Degrades honestly: mlClient never throws and falls back to the peak-hour heuristic
 * (prices still vary, each slot stamped price_source='heuristic') when ml-service is
 * unreachable. The only throw is the UPDATE itself — most likely the price_source
 * column missing before migration 030 is applied — which is caught and reported so a
 * sweep or a venue-create is never broken by it.
 */
async function repriceVenueSlots(runner, { venueId, venue = null, dryRun = false } = {}) {
  const db = runner || pool;
  const id = String(venueId == null ? '' : venueId).trim();
  if (!id) throw new Error('repriceVenueSlots requires a venueId');

  let row = venue;
  if (!row) {
    const r = await db.query(`SELECT ${VENUE_COLUMNS} FROM venues WHERE id = $1`, [id]);
    if (!r.rows.length) return { ok: false, repriced: 0, reason: 'venue not found' };
    row = r.rows[0];
  }

  const hours = grid.resolveHours(row);
  if (!hours.ok) return { ok: false, repriced: 0, reason: hours.reason };
  const basePrice = grid.priceOf(row);
  if (!(basePrice > 0)) return { ok: false, repriced: 0, reason: 'no price set' };

  const slotDate = pricingDate();
  const venueRating = Number(row.rating) > 0 ? Number(row.rating) : null;
  const hourList = [];
  for (let h = hours.fromHour; h < hours.toHour; h += 1) hourList.push(h);

  const plan = await Promise.all(
    hourList.map((h) => mlClient.suggestPrice({
      basePrice,
      slotDate,
      startTime: `${String(h).padStart(2, '0')}:00:00`,
      sport: row.sport_type,
      city: row.city,
      venueRating,
      venueId: id,
    }).then((s) => ({ hour: h, price: s.suggestedPrice, source: s.source }))),
  );

  const bySource = { model: 0, heuristic: 0 };
  for (const p of plan) bySource[p.source] = (bySource[p.source] || 0) + 1;

  if (dryRun) {
    return { ok: true, repriced: 0, dryRun: true, bySource, plan, hours: hourList.length };
  }

  try {
    const res = await db.query(grid.REPRICE_SQL, [
      id,
      plan.map((p) => p.hour),
      plan.map((p) => p.price),
      plan.map((p) => p.source),
    ]);
    return { ok: true, repriced: res.rowCount, bySource, hours: hourList.length };
  } catch (e) {
    // A missing price_source column (migration 030 not yet applied) lands here. The
    // slots still exist and are bookable at their flat price; only the dynamic
    // pricing is deferred until the migration runs.
    return { ok: false, repriced: 0, reason: e.message, bySource };
  }
}

/** Reprice every active venue — what the maintenance sweep calls after ensuring slots. */
async function repriceActiveVenues({ venueId = null, dryRun = false, runner = null } = {}) {
  const db = runner || pool;
  const venues = await db.query(
    `SELECT ${VENUE_COLUMNS}
       FROM venues
      WHERE is_active = true
        ${venueId ? 'AND id = $1' : ''}
      ORDER BY name`,
    venueId ? [venueId] : [],
  );

  const results = [];
  let repriced = 0;
  const bySource = { model: 0, heuristic: 0 };
  for (const v of venues.rows) {
    try {
      const r = await repriceVenueSlots(db, { venueId: v.id, venue: v, dryRun });
      repriced += r.repriced || 0;
      if (r.bySource) {
        bySource.model += r.bySource.model || 0;
        bySource.heuristic += r.bySource.heuristic || 0;
      }
      results.push({ id: v.id, name: v.name, ...r });
    } catch (e) {
      results.push({ id: v.id, name: v.name, ok: false, repriced: 0, reason: e.message });
    }
  }
  return { venues: venues.rows.length, repriced, bySource, results };
}

module.exports = {
  ensureVenueSlots,
  ensureActiveVenueSlots,
  repriceVenueSlots,
  repriceActiveVenues,
  countBookable,
  // Re-exported so a caller can state the window without importing both modules.
  HORIZON_DAYS: grid.HORIZON_DAYS,
  PKT_TIMEZONE: grid.PKT_TIMEZONE,
  clampDays: grid.clampDays,
  describeWindow: grid.describeWindow,
  FALLBACK_FROM_HOUR: grid.FALLBACK_FROM_HOUR,
  FALLBACK_TO_HOUR: grid.FALLBACK_TO_HOUR,
};
