/**
 * tournamentScheduler.js — where trained model #1 chooses the tournament's hours.
 *
 * WHAT THIS FILE IS FOR
 * --------------------
 * `utils/fixtureSchedule.js` knows how to place fixtures on hours but is pure: it
 * cannot read the venue's free slots and it cannot call the ml-service. This file
 * is the impure half. It does three things and nothing else:
 *
 *   1. reads the venue's genuinely free hours, using the SAME "is this slot free?"
 *      predicate the browse screen and the booking route use, so the scheduler can
 *      never place a fixture on an hour a player is midway through paying for;
 *   2. asks model #1 (`POST /predict/demand`, the released booking-probability
 *      model) for P(booked) on those hours, cached for the PKT hour;
 *   3. hands both to `fixtureSchedule.allocate` and stamps the result with
 *      `meta.scheduling.source` — 'model' when the forecast was used, and
 *      'chronological' when it was not.
 *
 * WHY THE PROVENANCE STAMP MATTERS
 * -------------------------------
 * The demo has to be able to prove which path ran. `source: 'model'` with a
 * `modelVersion` and a coverage count is a checkable claim; a schedule that
 * silently looks the same whether or not the ml-service was up would let anyone
 * say "the AI placed these" about a plain chronological list. So the fallback is
 * loud, and `utils/fixtureSchedule.js` deliberately makes the fallback LOOK
 * different (PICK.EARLY, chronological) rather than quietly ranking on price.
 *
 * This is model REUSE, not a new model. Nothing is trained here, no artifact is
 * touched, and the released `booking-demand` model keeps its fingerprint. What is
 * new is the question being asked of it: the owner dashboard asks "which hours
 * will sell?" to draw a chart, and this file asks the same model the inverse —
 * "which hours will NOT sell?" — because those are the hours a tournament should
 * consume. Same model, same weights, opposite end of the ranking.
 *
 * WHEN THE MODEL IS UNREACHABLE
 * -----------------------------
 * The schedule is still produced, chronologically. That asymmetry with
 * `mlClient.forecastDemand` — which refuses to invent a forecast — is deliberate
 * and the reasoning is the same: a fabricated probability CURVE would be a lie
 * drawn as a chart, but "play the earliest free hours" is not a fabricated
 * forecast, it is the obvious default a human would pick, and it is labelled as
 * such. A tournament whose deadline has passed must be generated either way.
 */
const mlClient = require('./mlClient');
const discovery = require('./discoveryService');
const plan = require('../utils/fixtureSchedule');
const { TtlCache, ONE_HOUR_MS } = require('../utils/ttlCache');

/** Provenance values for `meta.scheduling.source`. */
const SOURCE = { MODEL: 'model', CHRONOLOGICAL: 'chronological' };

/** The ml-service's own ceiling (routers/pricing.py MAX_FORECAST_HOURS). */
const MAX_FORECAST_HOURS = 168;

/** How far ahead a tournament may reach for free hours. */
const DEFAULT_HORIZON_DAYS = 21;
const MAX_HORIZON_DAYS = 60;

/** A bound on the candidate scan, so a venue with a year of open slots is safe. */
const SLOT_SCAN_LIMIT = 400;

/**
 * One forecast per venue per PKT hour, exactly as routes/owner.js caches the
 * dashboard chart. Generation happens once per tournament, but the create screen
 * calls `preview` on every keystroke-ish change, and each preview would otherwise
 * be a fresh 168-point model call.
 */
const demandCache = new TtlCache({ name: 'tournament-demand', ttlMs: ONE_HOUR_MS, maxEntries: 100 });

/** '08:00:00' | 8 → 8, or NaN. Same tolerance as routes/owner.js. */
function hourFromTime(value) {
  if (value === null || value === undefined) return NaN;
  if (typeof value === 'number') return Number.isInteger(value) ? value : NaN;
  const hour = parseInt(String(value).split(':')[0], 10);
  return Number.isInteger(hour) && hour >= 0 && hour <= 23 ? hour : NaN;
}

/** The PKT hour a cache entry may not outlive: 'YYYY-MM-DDTHH'. */
function pktHourStamp(now = new Date()) {
  return new Date(now.getTime() + discovery.PKT_OFFSET_MS).toISOString().slice(0, 13);
}

const clampDays = (v, dflt) => {
  const n = Number(v);
  if (!Number.isFinite(n)) return dflt;
  return Math.max(1, Math.min(Math.round(n), MAX_HORIZON_DAYS));
};

/**
 * candidateSlots — the venue hours a tournament is allowed to consume.
 *
 * The predicate is deliberately the same three-part one `discoveryService.freeSlots`
 * uses for the slot picker: status 'available', not under a live checkout hold, and
 * still ahead of the clock. `HOLD_IS_LIVE` is imported rather than retyped, because
 * a second opinion about what "on hold" means is exactly the class of bug that puts
 * a fixture on an hour a player is midway through paying for.
 *
 * Two conditions are this file's own:
 *   - `NOT EXISTS (fixtures …)` — belt and braces over `uq_fixtures_slot_id`. The
 *     unique index is the guarantee; this keeps a second tournament from even
 *     considering an hour the first one is standing on, so the refusal is a clear
 *     "not enough hours" instead of a constraint violation mid-generation.
 *   - the horizon. Without it a venue with a year of open slots would hand the
 *     allocator thousands of rows to rank, and the tournament could be scheduled
 *     six months out because that week happened to be quiet.
 */
async function candidateSlots(client, {
  venueId, notBefore = null, horizonDays = DEFAULT_HORIZON_DAYS, limit = SLOT_SCAN_LIMIT,
} = {}) {
  const now = discovery.pktNow();
  const floorDate = discovery.normDate(plan.dateString(notBefore) || now.date);
  const floorTime = (() => {
    if (floorDate !== now.date) {
      const m = /[T ](\d{1,2}:\d{2}(?::\d{2})?)/.exec(String(notBefore == null ? '' : notBefore));
      return m ? (m[1].length === 5 ? `${m[1]}:00` : m[1]) : '00:00:00';
    }
    return now.time;
  })();
  const days = clampDays(horizonDays, DEFAULT_HORIZON_DAYS);
  const until = plan.keyToDate(plan.dateKey(floorDate) + days);

  const { rows } = await client.query(
    `SELECT s.id,
            to_char(s.slot_date, 'YYYY-MM-DD') AS slot_date_str,
            s.start_time, s.end_time, s.price
       FROM slots s
      WHERE s.venue_id = $1
        AND s.status = 'available'
        AND NOT ${discovery.HOLD_IS_LIVE}
        AND (s.slot_date > $2::date OR (s.slot_date = $2::date AND s.start_time >= $3::time))
        AND s.slot_date <= $4::date
        AND NOT EXISTS (
              SELECT 1 FROM fixtures f
               WHERE f.slot_id = s.id AND f.status <> 'cancelled')
      ORDER BY s.slot_date, s.start_time
      LIMIT $5`,
    [venueId, floorDate, floorTime, until, Math.max(1, Math.min(Number(limit) || SLOT_SCAN_LIMIT, SLOT_SCAN_LIMIT))],
  );
  return { slots: rows, from: floorDate, fromTime: floorTime, until, horizonDays: days };
}

/**
 * demandFor — P(booked) per candidate slot, from the released demand model.
 *
 * The forecast is a series of (date, hour) points starting from now, so the join
 * back to slot ids is on `${slotDate}#${hour}`. Hours the series does not reach —
 * anything past the ml-service's 168-hour ceiling — simply have no score, and
 * `fixtureSchedule` treats an unscored hour as neutral. That degrades one hour at
 * a time instead of discarding the whole forecast, and `coverage` reports it so
 * the response can say "48 of 60 candidate hours scored" rather than implying the
 * model had an opinion about all of them.
 *
 * A consequence worth naming: the ceiling is seven days, and the candidates start
 * at the registration deadline. Generation happens AT that deadline, so the model
 * covers it; a `preview` for a deadline three weeks out is outside the forecast's
 * reach and legitimately falls back to chronological with `reason` saying why. That
 * is the right answer rather than a defect — nobody can forecast a Tuesday in
 * October — and it is why the preview quotes venue cost from real `slots.price`
 * instead of from the model.
 */
async function demandFor(venue, slots) {
  const total = slots.length;
  const none = (reason) => ({
    demand: null, source: SOURCE.CHRONOLOGICAL, modelVersion: null, modelMetrics: null,
    coverage: { scored: 0, total }, reason, cached: false,
  });
  if (!total) return none('No candidate slots to score');

  const basePrice = Number(venue && (venue.price_per_hour ?? venue.base_price));
  if (!Number.isFinite(basePrice) || basePrice <= 0) {
    return none('Venue has no base price, so the demand model cannot be asked');
  }

  // Ask for exactly as far ahead as the candidates reach, capped at the
  // ml-service's own ceiling. Asking for 168 when the tournament is tomorrow
  // would make the model do a week of work for one day of answers.
  const now = discovery.pktNow();
  const nowAt = plan.dateKey(now.date) * plan.DAY_MINUTES + plan.timeMinutes(now.time);
  const lastAt = slots.reduce((max, row) => {
    const s = plan.normaliseSlot(row);
    return s && s.startAt > max ? s.startAt : max;
  }, nowAt);
  const hours = Math.max(1, Math.min(Math.ceil((lastAt - nowAt) / 60) + 1, MAX_FORECAST_HOURS));

  const openFrom = hourFromTime(venue.operating_hours_from);
  const openTo = hourFromTime(venue.operating_hours_to);
  const key = `${venue.id}:tournament:${hours}:${pktHourStamp()}`;

  let cached = true;
  const forecast = await demandCache.getOrSet(
    key,
    async () => {
      cached = false;
      return mlClient.forecastDemand({
        basePrice,
        sport: venue.sport_type,
        city: venue.city,
        venueRating: Number(venue.rating) > 0 ? Number(venue.rating) : null,
        hours,
        openFrom: Number.isInteger(openFrom) ? openFrom : null,
        openTo: Number.isInteger(openTo) ? openTo : null,
        venueId: venue.id,
      });
    },
    // Only a real forecast is worth an hour of memory: caching the unavailable
    // answer would keep a tournament on the chronological path for an hour after
    // the ml-service came back, and mlClient's own breaker already makes the
    // retry cheap.
    { shouldCache: (value) => value && value.available === true },
  );

  if (!forecast || forecast.available !== true) {
    return { ...none(forecast && forecast.reason ? forecast.reason : 'Demand forecast unavailable'), cached: false };
  }

  const byHour = new Map();
  for (const p of forecast.points) byHour.set(`${p.slotDate}#${Number(p.hour)}`, p.bookProbability);

  const demand = new Map();
  for (const row of slots) {
    const s = plan.normaliseSlot(row);
    if (!s) continue;
    const p = byHour.get(`${s.date}#${Math.floor(s.startMinutes / 60)}`);
    if (p != null) demand.set(s.id, p);
  }

  if (!demand.size) {
    return none('The forecast did not reach any of the candidate hours');
  }
  return {
    demand,
    source: SOURCE.MODEL,
    modelVersion: forecast.modelVersion || null,
    modelMetrics: forecast.modelMetrics || null,
    coverage: { scored: demand.size, total },
    reason: null,
    cached,
  };
}

const VENUE_COLUMNS = `id, name, sport_type, city, price_per_hour, base_price, rating,
            operating_hours_from, operating_hours_to`;

/** The venue's demand context. Same columns owner.js loads, without the ownership test. */
async function loadVenue(client, venueId) {
  const r = await client.query(`SELECT ${VENUE_COLUMNS} FROM venues WHERE id = $1`, [venueId]);
  return r.rows[0] || null;
}

/**
 * schedule — place a bracket's fixtures on real venue slots.
 *
 * The one impure entry point: it reads the venue, reads its free slots, asks the
 * model which of those hours will sell, and hands all of it to the pure allocator.
 * Everything that decides *where a fixture lands* lives in fixtureSchedule.js, so
 * this function contains no scheduling policy of its own — which is what makes the
 * allocator testable with the database down.
 *
 * Returns the allocation verbatim plus `meta.scheduling`, the provenance record:
 * which path ran, which model version, how many candidate hours it actually scored,
 * and why it fell back when it did. `POST /api/tournaments/:id/generate` echoes
 * that block, so the demo can prove the model ran instead of asserting it.
 */
async function schedule(client, {
  venue = null,
  venueId = null,
  fixtures = [],
  format = 'knockout',
  notBefore = null,
  slotMinutes = plan.DEFAULT_SLOT_MINUTES,
  roundGapDays = plan.DEFAULT_ROUND_GAP_DAYS,
  roundRestMinutes = plan.DEFAULT_ROUND_REST_MINUTES,
  horizonDays = DEFAULT_HORIZON_DAYS,
  slots = null,
  peakFinal = true,
  useModel = true,
} = {}) {
  const row = venue || (venueId ? await loadVenue(client, venueId) : null);
  if (!row) {
    return {
      ok: false, code: 'venue_not_found', message: 'Venue not found', assignments: [],
      meta: { scheduling: { source: SOURCE.CHRONOLOGICAL, reason: 'Venue not found' } },
    };
  }

  const days = clampDays(horizonDays, DEFAULT_HORIZON_DAYS);
  const scan = slots
    ? { slots, from: null, fromTime: null, until: null, horizonDays: days }
    : await candidateSlots(client, { venueId: row.id, notBefore, horizonDays: days });

  // A venue with no open hours is not a model problem, and asking the model about
  // an empty set would spend a forecast to learn nothing.
  const demandInfo = (useModel && scan.slots.length)
    ? await demandFor(row, scan.slots)
    : {
      demand: null, source: SOURCE.CHRONOLOGICAL, modelVersion: null, modelMetrics: null,
      coverage: { scored: 0, total: scan.slots.length }, cached: false,
      reason: useModel ? 'No open slots to score' : 'Demand model not requested',
    };

  const allocation = plan.allocate({
    fixtures,
    slots: scan.slots,
    demand: demandInfo.demand,
    roundGapDays,
    roundRestMinutes,
    notBefore,
    slotMinutes,
    format,
    peakFinal,
  });

  return {
    ...allocation,
    venue: { id: row.id, name: row.name, sportType: row.sport_type, city: row.city },
    meta: {
      scheduling: {
        // 'model' only when a forecast actually scored candidate hours. Anything
        // else — ml-service down, breaker open, forecast past its 168-hour horizon,
        // no base price — is 'chronological', and `reason` says which.
        source: demandInfo.source,
        modelVersion: demandInfo.modelVersion,
        modelMetrics: demandInfo.modelMetrics,
        cached: demandInfo.cached,
        reason: demandInfo.reason,
        coverage: demandInfo.coverage,
        candidates: scan.slots.length,
        scanFrom: scan.from,
        scanFromTime: scan.fromTime,
        scanUntil: scan.until,
        horizonDays: scan.horizonDays,
        picks: (allocation.rounds || []).map((r) => ({
          round: r.round, label: r.label, pick: r.pick, date: r.date,
          total: r.total, meanPBooked: r.meanPBooked, meanWindowPBooked: r.meanWindowPBooked,
        })),
        slotMinutes,
        roundGapDays,
        roundRestMinutes,
        peakFinal,
      },
    },
  };
}

module.exports = {
  SOURCE,
  MAX_FORECAST_HOURS,
  DEFAULT_HORIZON_DAYS,
  MAX_HORIZON_DAYS,
  SLOT_SCAN_LIMIT,
  VENUE_COLUMNS,
  demandCache,
  hourFromTime,
  clampDays,
  loadVenue,
  candidateSlots,
  demandFor,
  schedule,
};
