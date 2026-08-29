/**
 * fixtureSchedule.js — which hour each fixture is played in. Pure, like fixtures.js.
 *
 * WHY THIS IS A SEPARATE FILE
 * ---------------------------
 * `utils/fixtures.js` decides the SHAPE of a tournament (who plays whom, who
 * advances where). This file decides WHEN, which is a different problem with
 * different inputs: the venue's free hours, the rest a squad needs between
 * rounds, and — the interesting part — how much each of those hours is worth to
 * the owner if they sold it instead.
 *
 * It is still pure: no database, no clock, no ml-service. The candidate slots
 * arrive already filtered by the service (available, not on a checkout hold,
 * still in the future) and the demand scores arrive already fetched by
 * `services/tournamentScheduler.js`. That keeps the allocation testable with the
 * database down and the ml-service off, and it keeps the "which hour?" decision
 * out of an HTTP call's error path.
 *
 * THE THREE RULES
 * ---------------
 * 1. ROUNDS ARE ORDERED IN TIME. Round 2 cannot be played before round 1 has
 *    produced the teams that play in it — that is not a preference, it is
 *    causality. The separation is expressed by TWO settings, because they answer
 *    two different questions and collapsing them into one is a real bug:
 *
 *      `round_gap_days`     (default 1) is a CALENDAR rule: round r+1 is played
 *                           at least this many dates after round r's last date.
 *      `round_rest_minutes` (default 60) is a CLOCK rule: round r+1 starts at
 *                           least this long after round r's last slot ENDS.
 *
 *    Measuring the calendar rule on the clock — "24 hours after the final
 *    whistle" — looks equivalent and is not: round 1 finishing at 20:00 would
 *    push round 2 past 20:00 the next day, round 2 past 22:00 the day after, and
 *    a three-round bracket would run out of evening and fail to schedule. A day
 *    of rest means "tomorrow", so the calendar cursor is midnight of the target
 *    date and the clock rule only bites when both rounds share a date.
 *
 * 2. NO TEAM PLAYS TWICE AT ONCE. Within a round every team appears exactly once
 *    (a property of the bracket and of the circle method), so ordering the rounds
 *    is sufficient: a team's next match is always after its previous one with at
 *    least the configured rest in between. Set `round_gap_days` to 0 for a
 *    one-day cup and `round_rest_minutes` is what keeps a squad from being asked
 *    to play two matches in the same hour.
 *
 * 3. THE FINAL TAKES THE BEST WINDOW, THE EARLY ROUNDS TAKE THE DEAD ONES.
 *    Candidate hours are ranked by P(booked) from trained model #1, and early
 *    rounds are placed in the LOWEST-demand windows while the final is placed in
 *    the HIGHEST. This is not decoration:
 *
 *      - the owner's sellable peak inventory stays sellable. A tournament that
 *        eats every Saturday 6pm slot costs the owner the customers who would
 *        have paid retail for them.
 *      - `venue_cost` is the SUM of the chosen slots' real prices, so when an
 *        owner prices peak hours higher (most do), off-peak placement lowers what
 *        every round except the final costs the pool — and therefore lowers the
 *        entry fee teams have to pay. Price is the secondary sort for exactly this
 *        reason, so the benefit appears even at a venue with flat pricing.
 *      - the final gets the crowd, and deliberately BUYS one peak hour to do it.
 *        So the claim this file's tests actually make is the precise one: every
 *        round but the final costs no more than a chronological schedule would,
 *        and the final takes the busiest hour of its date on purpose.
 *
 * WHAT THIS FILE WILL NOT DO
 * --------------------------
 * Partially schedule. If the venue does not have enough free hours for every
 * fixture, `allocate` reports the shortfall and assigns NOTHING — a bracket with
 * three of its seven fixtures placed would compute a `venue_cost` for three
 * hours and pay the owner for three hours while consuming seven. The service
 * refuses generation instead and tells the owner how many hours to open.
 */

const fx = require('./fixtures');

/** Pakistan is UTC+5 with no DST. `slots.slot_date` / `start_time` are PKT wall clock. */
const PKT_SUFFIX = '+05:00';

/** One day, in the minutes this file counts everything in. */
const DAY_MINUTES = 1440;

/** Default calendar separation: one date per round. */
const DEFAULT_ROUND_GAP_DAYS = 1;

/** Default clock rest between rounds, which only bites when they share a date. */
const DEFAULT_ROUND_REST_MINUTES = 60;

/** Fallback slot length when a candidate row carries no `end_time`. */
const DEFAULT_SLOT_MINUTES = 60;

/**
 * How a round picks from its window.
 *   EARLY — chronological. The fallback when no demand scores arrived, and the
 *           rule for a one-day cup, where fitting the rounds into the day is a
 *           harder constraint than which hour was quiet.
 *   CHEAP — lowest demand first (dead hours). Early rounds.
 *   PEAK  — highest demand first (crowd). The final.
 */
const PICK = { EARLY: 'early', CHEAP: 'cheap', PEAK: 'peak' };

const asNum = fx.asNum;
const round2 = fx.round2;

/**
 * A calendar date as a day number, so two dates can be compared and subtracted
 * without constructing a Date in the server's timezone.
 *
 * Accepts what the service actually has: the `to_char(slot_date,'YYYY-MM-DD')`
 * string it should be selecting, a plain 'YYYY-MM-DD', or — as a last resort —
 * the JS Date node-postgres hands back for a DATE column, which is LOCAL
 * midnight, so its local components are the correct read. Using `toISOString()`
 * on that Date is the bug this function exists to avoid: one hour west of PKT it
 * reports the previous day.
 */
function dateKey(raw) {
  const s = dateString(raw);
  if (!s) return null;
  const [y, m, d] = s.split('-').map(Number);
  return Math.round(Date.UTC(y, m - 1, d) / 86400000);
}

/** The same input, normalised to a 'YYYY-MM-DD' string (or null). */
function dateString(raw) {
  if (raw == null) return null;
  if (raw instanceof Date) {
    if (Number.isNaN(raw.getTime())) return null;
    const p = (n) => String(n).padStart(2, '0');
    return `${raw.getFullYear()}-${p(raw.getMonth() + 1)}-${p(raw.getDate())}`;
  }
  const s = String(raw).trim();
  const m = /^(\d{4}-\d{2}-\d{2})/.exec(s);
  return m ? m[1] : null;
}

/** A day number back to 'YYYY-MM-DD'. */
function keyToDate(key) {
  return new Date(key * 86400000).toISOString().slice(0, 10);
}

/** 'HH:MM' or 'HH:MM:SS' → minutes since midnight. Anything else → null. */
function timeMinutes(raw) {
  const m = /^(\d{1,2}):(\d{2})(?::(\d{2}))?$/.exec(String(raw == null ? '' : raw).trim());
  if (!m) return null;
  const h = Number(m[1]);
  const min = Number(m[2]);
  if (h > 23 || min > 59) return null;
  return h * 60 + min;
}

/** Minutes since midnight → 'HH:MM:SS', wrapping past midnight into the day after. */
function minutesTime(mins) {
  const p = (n) => String(n).padStart(2, '0');
  const within = ((mins % DAY_MINUTES) + DAY_MINUTES) % DAY_MINUTES;
  return `${p(Math.floor(within / 60))}:${p(within % 60)}:00`;
}

/**
 * A PKT wall-clock date + time as an offset-qualified ISO string.
 *
 * `fixtures.scheduled_at` is a timestamptz, so the offset has to be IN the value.
 * Handing Postgres '2026-09-01T18:00:00' would store 6pm in whatever timezone the
 * session happens to be in; '2026-09-01T18:00:00+05:00' stores the instant the
 * players are actually expected at the ground, wherever the server sits.
 */
function pktIso(date, minutes) {
  const d = dateString(date);
  if (!d) return null;
  const dayShift = Math.floor(asNum(minutes, 0) / DAY_MINUTES);
  const day = dayShift ? keyToDate(dateKey(d) + dayShift) : d;
  return `${day}T${minutesTime(minutes)}${PKT_SUFFIX}`;
}

/**
 * A candidate slot row → the internal shape the allocator sorts and compares.
 *
 * `startAt` / `endAt` are ABSOLUTE minutes (day number × 1440 + minutes past
 * midnight) so "does round 2 start after round 1 finished?" is one subtraction
 * whether the two rounds are on the same date or a fortnight apart.
 *
 * A row missing an id, a date or a start time is unusable rather than an error:
 * it is dropped and counted in `dropped`, because one malformed slot must not
 * stop a tournament that has six perfectly good ones.
 */
function normaliseSlot(row, { slotMinutes = DEFAULT_SLOT_MINUTES } = {}) {
  if (!row || typeof row !== 'object') return null;
  const id = row.id == null ? null : String(row.id);
  const date = dateString(row.slot_date_str || row.slotDateStr || row.slot_date || row.slotDate || row.date);
  const start = timeMinutes(row.start_time || row.startTime);
  if (!id || !date || start == null) return null;

  const key = dateKey(date);
  const rawEnd = timeMinutes(row.end_time || row.endTime);
  const span = asNum(slotMinutes, DEFAULT_SLOT_MINUTES) || DEFAULT_SLOT_MINUTES;
  // An end time before the start means the slot crosses midnight (23:00 → 00:00).
  const end = rawEnd == null ? start + span : (rawEnd > start ? rawEnd : rawEnd + DAY_MINUTES);

  return {
    id,
    date,
    dateKey: key,
    startTime: minutesTime(start),
    endTime: minutesTime(end),
    startMinutes: start,
    startAt: key * DAY_MINUTES + start,
    endAt: key * DAY_MINUTES + end,
    price: round2(asNum(row.price, 0)),
    pBooked: null,
    row,
  };
}

/**
 * Attach P(booked) from the caller's demand lookup.
 *
 * The lookup may be a Map, a plain object keyed by slot id, or a function — the
 * scheduler service builds whichever is convenient and this file does not care.
 * A slot the model could not score keeps `pBooked = null` and is treated as
 * neutral (0.5) when ranking, so a partial model response degrades one slot at a
 * time instead of poisoning the whole allocation.
 */
function readDemand(lookup, slot) {
  if (!lookup) return null;
  let v;
  if (typeof lookup === 'function') v = lookup(slot.id, slot);
  else if (typeof lookup.get === 'function') v = lookup.get(slot.id);
  else v = lookup[slot.id];
  if (v != null && typeof v === 'object') v = v.pBooked != null ? v.pBooked : v.p_booked;
  const n = Number(v);
  if (!Number.isFinite(n)) return null;
  return Math.max(0, Math.min(1, n));
}

const NEUTRAL_DEMAND = 0.5;
const demandOf = (s) => (s.pBooked == null ? NEUTRAL_DEMAND : s.pBooked);

/** Chronological, and stable on ties via the slot id. */
function byTime(a, b) {
  return a.startAt - b.startAt || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
}

/**
 * The ranking that puts model #1's opinion to work.
 *
 * CHEAP (early rounds): least sellable hour first — lowest P(booked), then
 * cheapest, then earliest. Both tiebreaks matter. Price is second so the entry
 * fee benefit survives a venue whose model scores are flat, and time is third so
 * the result is deterministic, which is what makes the check script's assertions
 * possible.
 *
 * PEAK (the final): the mirror image — busiest hour first, then the pricier slot,
 * then the earliest. The final is the one fixture that should cost the pool a
 * peak hour, because a crowd is the point of a final.
 *
 * EARLY: chronological, full stop. With no model there is no demand to rank on,
 * and ranking on price instead would quietly make the fallback a cost optimiser
 * that the docs and `meta.scheduling.source` both claim it is not.
 */
function rankSlots(slots, pick) {
  if (pick === PICK.EARLY) return slots.slice().sort(byTime);
  const dir = pick === PICK.PEAK ? -1 : 1;
  return slots.slice().sort((a, b) => (
    dir * (demandOf(a) - demandOf(b))
    || dir * (a.price - b.price)
    || byTime(a, b)
  ));
}

/**
 * The days a round is allowed to look at: the earliest eligible date, plus as
 * many following dates as it takes to reach `need` slots.
 *
 * WHY A WINDOW AND NOT THE WHOLE POOL
 * -----------------------------------
 * Ranking every free hour the venue has by demand and taking the quietest ones
 * would schedule round 1 across three different weeks, because the quietest
 * hours of a month are scattered. A tournament has to feel like an event. So the
 * calendar decision is made first and stays boring — the earliest date that can
 * hold the whole round — and the model then chooses WITHIN that date, where its
 * opinion is both useful and cheap to check: of the hours available on Saturday,
 * take the ones nobody was going to buy.
 *
 * ONE DATE PER ROUND, WHEN THE VENUE ALLOWS IT
 * -------------------------------------------
 * A round split across two dates gives one half of the draw a day less rest than
 * the other before they meet, so the first pass looks for a single date with
 * enough free hours even if that means skipping an earlier date with one hour
 * spare (which the owner can then still sell). Only when no single date can hold
 * the round — a round-robin matchday of three fixtures at a venue with two free
 * hours a day — does it fall back to accumulating consecutive dates, and the
 * round then reports `spansDays` so the response can say so out loud.
 */
function dayWindow(eligible, need) {
  const byDay = new Map();
  for (const s of eligible) {
    if (!byDay.has(s.dateKey)) byDay.set(s.dateKey, []);
    byDay.get(s.dateKey).push(s);
  }
  const days = [...byDay.keys()].sort((a, b) => a - b);

  for (const d of days) {
    const day = byDay.get(d);
    if (day.length >= need) return { window: day, dates: [keyToDate(d)], split: false };
  }

  const out = [];
  const used = [];
  for (const d of days) {
    out.push(...byDay.get(d));
    used.push(keyToDate(d));
    if (out.length >= need) break;
  }
  return { window: out, dates: used, split: used.length > 1 };
}

/** `notBefore` in any of the shapes a caller has → absolute minutes (or null). */
function notBeforeMinutes(raw) {
  if (raw == null || raw === '') return null;
  if (typeof raw === 'number') return Number.isFinite(raw) ? raw : null;
  if (typeof raw === 'object' && !(raw instanceof Date)) {
    const k = dateKey(raw.date);
    if (k == null) return null;
    const m = timeMinutes(raw.time);
    return k * DAY_MINUTES + (m == null ? 0 : m);
  }
  const s = raw instanceof Date ? raw.toISOString() : String(raw).trim();
  const k = dateKey(s);
  if (k == null) return null;
  const t = /[T ](\d{1,2}:\d{2}(?::\d{2})?)/.exec(s);
  return k * DAY_MINUTES + (t ? timeMinutes(t[1]) : 0);
}

/** The identity of a fixture inside its tournament: 019's UNIQUE (tournament_id, round, position). */
const keyOf = (round, position) => `${asNum(round, 0)}:${asNum(position, 0)}`;

/**
 * allocate — put every playable fixture on a real venue hour, or refuse.
 *
 * @param {object[]} fixtures  nodes from `fixtures.buildFixtures` (or rows read
 *        back from the table — `normaliseFixture` shapes are accepted).
 * @param {object[]} slots     candidate venue slots. The SERVICE is responsible
 *        for these being genuinely free: status 'available', no live checkout
 *        hold, still in the future. This file trusts the list and only decides
 *        which of them to take.
 * @param {*} demand           Map, object or function → P(booked) per slot id.
 *        Omit it and the allocation is plain chronological, which is the
 *        documented fallback when ml-service is down.
 * @param {number} roundGapDays      calendar dates between rounds (default 1).
 * @param {number} roundRestMinutes  clock rest between rounds (default 60), which
 *        only matters when two rounds share a date.
 * @param {*} notBefore        earliest instant a fixture may be scheduled at —
 *        normally the registration deadline, so nothing is ever scheduled before
 *        the teams are known.
 * @param {string} format      knockout or round_robin. Only a knockout gets the
 *        peak-hour final; a round-robin's last matchday is several fixtures at
 *        once and taking three peak hours for it would cost the pool more than
 *        the occasion is worth.
 *
 * Returns ok:false with a `shortfall` and NO assignments when the venue cannot
 * host the whole bracket — see the file header for why a partial schedule is
 * worse than no schedule.
 */
function allocate({
  fixtures = [],
  slots = [],
  demand = null,
  roundGapDays = null,
  roundRestMinutes = null,
  notBefore = null,
  slotMinutes = DEFAULT_SLOT_MINUTES,
  format = fx.FORMATS.KNOCKOUT,
  peakFinal = null,
} = {}) {
  const gapDays = Math.max(0, Math.round(asNum(
    roundGapDays == null ? DEFAULT_ROUND_GAP_DAYS : roundGapDays, DEFAULT_ROUND_GAP_DAYS)));
  const restMinutes = Math.max(0, asNum(
    roundRestMinutes == null ? DEFAULT_ROUND_REST_MINUTES : roundRestMinutes,
    DEFAULT_ROUND_REST_MINUTES));

  // ---- slots -------------------------------------------------------------
  const pool = [];
  const seen = new Set();
  let dropped = 0;
  for (const row of Array.isArray(slots) ? slots : []) {
    const s = normaliseSlot(row, { slotMinutes });
    if (!s || seen.has(s.id)) { dropped += 1; continue; }
    seen.add(s.id);
    s.pBooked = readDemand(demand, s);
    pool.push(s);
  }
  pool.sort(byTime);
  const demandUsed = pool.some((s) => s.pBooked != null);

  // ---- fixtures ----------------------------------------------------------
  const playable = [];
  const byes = [];
  for (const raw of Array.isArray(fixtures) ? fixtures : []) {
    const f = fx.normaliseFixture(raw);
    if (!f || f.status === fx.FIXTURE_STATUS.CANCELLED) continue;
    // `label` and `id` are not part of normaliseFixture's derivation shape, so
    // they are read off the raw row — the same word in both spellings.
    const node = {
      round: asNum(f.round, 1),
      position: asNum(f.position, 1),
      label: raw.label == null ? null : String(raw.label),
      fixtureId: raw.id == null ? null : String(raw.id),
      isBye: !!f.isBye,
    };
    // A bye consumes no hour: nobody turns up, so the venue is not booked for it.
    if (node.isBye) byes.push(node); else playable.push(node);
  }
  playable.sort((a, b) => a.round - b.round || a.position - b.position);

  const rounds = [...new Set(playable.map((f) => f.round))].sort((a, b) => a - b);
  const lastRound = rounds.length ? rounds[rounds.length - 1] : 0;
  const wantPeakFinal = peakFinal == null
    ? String(format) !== fx.FORMATS.ROUND_ROBIN
    : !!peakFinal;

  /**
   * Which strategy a round uses, in priority order:
   *   no demand scores at all      → EARLY, the documented chronological fallback
   *   the final of a knockout      → PEAK, the crowd's hour
   *   a one-day cup's other rounds → EARLY, because the day has to fit
   *   otherwise                    → CHEAP, the dead hour
   */
  const pickFor = (round) => {
    if (!demandUsed) return PICK.EARLY;
    if (round === lastRound && wantPeakFinal) return PICK.PEAK;
    if (gapDays === 0) return PICK.EARLY;
    return PICK.CHEAP;
  };

  // ---- round by round ----------------------------------------------------
  const assignments = [];
  const roundMeta = [];
  const consumed = new Set();
  let cursor = notBeforeMinutes(notBefore);

  for (const round of rounds) {
    const inRound = playable.filter((f) => f.round === round);
    const need = inRound.length;
    const eligible = pool.filter((s) => !consumed.has(s.id)
      && (cursor == null || s.startAt >= cursor));

    if (eligible.length < need) {
      return {
        ok: false,
        code: 'not_enough_slots',
        message: shortfallMessage(round, need, eligible.length, round !== rounds[0]),
        assignments: [], byes, rounds: roundMeta,
        slotTotal: 0, slotsUsed: 0,
        need: playable.length, available: pool.length, dropped,
        shortfall: { round, need, available: eligible.length },
        firstAt: null, lastAt: null, demandUsed,
      };
    }

    const pick = pickFor(round);
    const { window, dates, split } = dayWindow(eligible, need);
    const chosen = rankSlots(window, pick).slice(0, need).sort(byTime);

    // Chronological slots meet position-ordered fixtures, so the bracket reads
    // top to bottom in time and fixture 1 is the first match of the day.
    inRound.forEach((f, i) => {
      const s = chosen[i];
      consumed.add(s.id);
      assignments.push({
        round: f.round,
        position: f.position,
        key: keyOf(f.round, f.position),
        fixtureId: f.fixtureId,
        label: f.label,
        slotId: s.id,
        slotDate: s.date,
        startTime: s.startTime,
        endTime: s.endTime,
        scheduledAt: pktIso(s.date, s.startMinutes),
        price: s.price,
        pBooked: s.pBooked,
        pick,
      });
    });

    // Evidence, not decoration: the demo can show that round 1 took hours the
    // model scored at 0.21 while the day's average was 0.48, which is the whole
    // claim of the demand-aware scheduler in one line of the response.
    roundMeta.push({
      round,
      label: inRound[0] ? inRound[0].label : null,
      pick,
      count: need,
      date: chosen[0].date,
      dates: [...new Set(chosen.map((s) => s.date))],
      windowDates: dates,
      spansDays: split || new Set(chosen.map((s) => s.dateKey)).size > 1,
      slotIds: chosen.map((s) => s.id),
      total: round2(chosen.reduce((t, s) => t + s.price, 0)),
      meanPBooked: demandUsed ? meanDemand(chosen) : null,
      meanWindowPBooked: demandUsed ? meanDemand(window) : null,
    });

    // Causality, both ways round: the clock rule from this round's last whistle,
    // the calendar rule from midnight of the target date, and the later of the
    // two wins. See header rule 1 for why one number cannot do this job.
    const lastEnd = Math.max(...chosen.map((s) => s.endAt));
    const lastDay = Math.max(...chosen.map((s) => s.dateKey));
    cursor = Math.max(lastEnd + restMinutes, (lastDay + gapDays) * DAY_MINUTES);
  }

  const used = assignments.length;
  const last = roundMeta.length ? roundMeta[roundMeta.length - 1] : null;
  return {
    ok: true, code: 'ok', message: null,
    assignments, byes, rounds: roundMeta,
    slotTotal: round2(assignments.reduce((t, a) => t + a.price, 0)),
    slotsUsed: used,
    need: playable.length, available: pool.length, dropped,
    shortfall: null,
    firstAt: used ? assignments[0].scheduledAt : null,
    lastAt: used ? assignments[used - 1].scheduledAt : null,
    startDate: roundMeta.length ? roundMeta[0].date : null,
    endDate: last ? last.dates[last.dates.length - 1] : null,
    demandUsed,
  };
}

/** Mean P(booked) over a slot list, 2dp, treating an unscored slot as neutral. */
function meanDemand(list) {
  if (!list.length) return null;
  return round2(list.reduce((t, s) => t + demandOf(s), 0) / list.length);
}

/**
 * The refusal an owner actually reads. It names the round, the hours it needed
 * and the hours that were open, because "cannot generate fixtures" leaves them
 * with nothing to do about it.
 */
function shortfallMessage(round, need, available, afterPrevious) {
  const hrs = (n) => `${n} free hour${n === 1 ? '' : 's'}`;
  return `Round ${round} needs ${hrs(need)} at this venue`
    + `${afterPrevious ? ' after the previous round' : ''}, but ${hrs(available)}`
    + `${available === 1 ? ' is' : ' are'} open. Open more slots at the venue`
    + ' or start the tournament later.';
}

module.exports = {
  PKT_SUFFIX, DAY_MINUTES, DEFAULT_ROUND_GAP_DAYS, DEFAULT_ROUND_REST_MINUTES,
  DEFAULT_SLOT_MINUTES,
  NEUTRAL_DEMAND, PICK,
  dateKey, dateString, keyToDate, timeMinutes, minutesTime, pktIso,
  normaliseSlot, readDemand, rankSlots, dayWindow, notBeforeMinutes, keyOf,
  meanDemand, allocate,
};
