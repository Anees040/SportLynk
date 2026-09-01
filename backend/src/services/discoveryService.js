/**
 * discoveryService.js — the read queries Scout and the screens must agree on.
 *
 * Why this file exists
 * FR8.15 again, but for reads rather than money. Scout answers `find_venue`,
 * `check_availability`, `venue_info`, `find_teams` and `tournament_list`, and if
 * it typed its own SQL for any of them it would quietly disagree with the app:
 *
 *   - the verification gate. GET /api/venues hides venues whose owner is not
 *     approved (`op.verification_status = 'approved' OR IS NULL`). An assistant
 *     that skipped it would recommend grounds the browse screen refuses to show,
 *     and the first demo question would be "why can I not find it in the list?".
 *   - the checkout hold. A slot on hold keeps status='available' and only
 *     `locked_until` says otherwise, so "is 6pm free?" is a derived answer. Two
 *     derivations means Scout offering a slot the booking route then refuses.
 *   - the PKT clock. Today's slots are filtered against now+5h, and a venue page
 *     that hides 4pm while Scout still offers it is a bug the committee can see.
 *
 * So those three rules live here once, and routes/venues.js is transport.
 *
 * What is *not* here
 * Money and ranking. Booking goes through services/bookingService.js, player and
 * opponent suggestion through services/rosterService.js, venue ranking through
 * services/mlClient.js. This file only finds things.
 *
 * Tournaments have no route yet
 * `listTournaments` is the first reader of the `tournaments` table (013). It is
 * written here rather than in the assistant so that when S.7 adds the tournament
 * screens they call this function instead of starting a second opinion about what
 * "open for registration" means.
 */
const pool = require('../db/pool');
const access = require('../utils/teamAccess');

/** Pakistan is UTC+5 with no DST, so one constant is the whole timezone story. */
const PKT_OFFSET_MS = 5 * 60 * 60 * 1000;

/** Slots per page, and the ceiling a caller cannot raise. */
const VENUE_LIMIT = 20;
const VENUE_MAX = 100;

/**
 * A checkout hold (routes/slotLock.js) is a `locked_until` in the future and
 * nothing else — `status` stays 'available' the whole time. Every question about
 * whether a slot is free therefore has to say so in SQL, and this is that string.
 */
const HOLD_IS_LIVE = '(s.locked_until IS NOT NULL AND s.locked_until > NOW())';

/**
 * The four derived slot columns the venue page paints.
 *
 * SRS colour code: Green available · Amber booked · Red blocked · Blue locked.
 * `userParam` is the placeholder ($3, $4, …) carrying the caller's id, so a player
 * can still pick the slot they are holding themselves.
 */
const slotColumns = (userParam) => `s.*,
        (s.status = 'available' AND ${HOLD_IS_LIVE}) AS is_locked,
        (${HOLD_IS_LIVE} AND s.locked_by = ${userParam}) AS locked_by_me,
        CASE WHEN s.status = 'available' AND ${HOLD_IS_LIVE} THEN 'locked'
             ELSE s.status::text END AS effective_status`;

/** "Now" in Pakistan, as the two strings the slot queries compare against. */
function pktNow() {
  const p = new Date(Date.now() + PKT_OFFSET_MS).toISOString();
  return { date: p.split('T')[0], time: p.split('T')[1].split('.')[0] };
}

/** A caller-supplied YYYY-MM-DD, or today in PKT. Anything else is today. */
function normDate(raw) {
  const s = String(raw == null ? '' : raw).trim();
  return /^\d{4}-\d{2}-\d{2}$/.test(s) ? s : pktNow().date;
}

const num = (v, dflt = null) => {
  const n = Number(v);
  return Number.isFinite(n) ? n : dflt;
};
const clampLimit = (v, dflt, max) => Math.max(1, Math.min(num(v, dflt) || dflt, max));

// VENUES

/**
 * searchVenues — GET /api/venues, and Scout's `find_venue`.
 *
 * The filter list is unchanged from the route: sport, city, free text, price
 * floor/ceiling, rating floor, and the five sorts. Two things are worth naming:
 *
 *   - the LEFT JOIN to owner_profiles plus `verification_status = 'approved' OR
 *     IS NULL` is the gate described in the file header. NULL passes on purpose:
 *     a venue whose owner never filled a profile predates verification and is
 *     grandfathered rather than hidden.
 *   - `search` is one term matched against four columns, which is why it burns
 *     four placeholders instead of one. It stays that way because the browse
 *     screen's results must not change shape in this move.
 */
async function searchVenues(client, {
  sport = null, city = null, search = null, sort = null,
  minPrice = null, maxPrice = null, minRating = null,
  limit = VENUE_LIMIT, offset = 0,
} = {}) {
  const runner = client || pool;
  const conditions = ['v.is_active = true'];
  const params = [];
  const add = (sql, ...vals) => {
    conditions.push(sql.replace(/\$#(\d)/g, (_, k) => `$${params.length + Number(k)}`));
    params.push(...vals);
  };
  if (sport) add('LOWER(v.sport_type) = LOWER($#1)', String(sport));
  if (city) add('v.city ILIKE $#1', `%${city}%`);
  if (search) {
    const t = `%${search}%`;
    add('(v.name ILIKE $#1 OR v.address ILIKE $#2 OR v.city ILIKE $#3 OR v.sport_type ILIKE $#4)',
      t, t, t, t);
  }
  if (minPrice != null && num(minPrice) != null) add('v.price_per_hour >= $#1', num(minPrice));
  if (maxPrice != null && num(maxPrice) != null) add('v.price_per_hour <= $#1', num(maxPrice));
  if (minRating != null && num(minRating) != null) add('COALESCE(v.rating, 0) >= $#1', num(minRating));

  const ORDERS = {
    price_low: 'v.price_per_hour ASC NULLS LAST',
    price_high: 'v.price_per_hour DESC NULLS LAST',
    rating: 'v.rating DESC NULLS LAST',
    newest: 'v.created_at DESC',
    reviews: 'v.total_reviews DESC NULLS LAST',
  };
  const orderBy = ORDERS[String(sort || '')] || 'v.rating DESC NULLS LAST';

  const n = clampLimit(limit, VENUE_LIMIT, VENUE_MAX);
  const off = Math.max(0, num(offset, 0) || 0);
  params.push(n, off);
  const { rows } = await runner.query(
    `SELECT v.*,
            COALESCE(v.venue_photos[1], null) AS cover_photo,
            v.venue_photos,
            u.name AS owner_name
       FROM venues v
       LEFT JOIN users u ON u.id = v.owner_id
       LEFT JOIN owner_profiles op ON op.user_id = v.owner_id
      WHERE ${conditions.join(' AND ')}
        AND (op.verification_status = 'approved' OR op.verification_status IS NULL)
      ORDER BY ${orderBy}
      LIMIT $${params.length - 1} OFFSET $${params.length}`,
    params,
  );
  return rows;
}

/**
 * venueDetail — GET /api/venues/:id, and Scout's `venue_info` /
 * `check_availability`.
 *
 * The slot window is the rule worth protecting: a future date shows every slot,
 * today shows only slots that have not started yet in PKT, and a past date shows
 * none at all rather than an error. Scout asks the same question the venue page
 * asks, so it gets the same three branches.
 */
async function venueDetail(client, { venueId, userId, date = null } = {}) {
  const runner = client || pool;
  if (!access.isUuid(String(venueId || '').trim().toLowerCase())) {
    return { ok: false, status: 400, code: 'bad_venue', message: 'Which ground did you mean?', data: null };
  }
  const venue = await runner.query(
    `SELECT v.*, u.name AS owner_name, u.phone AS owner_phone
       FROM venues v LEFT JOIN users u ON u.id = v.owner_id
      WHERE v.id = $1 AND v.is_active = true`,
    [venueId],
  );
  if (!venue.rows.length) {
    return { ok: false, status: 404, code: 'venue_not_found', message: 'Venue not found', data: null };
  }

  const slotDate = normDate(date);
  const now = pktNow();
  let slots = { rows: [] };
  if (slotDate > now.date) {
    slots = await runner.query(
      `SELECT ${slotColumns('$3')} FROM slots s
        WHERE s.venue_id = $1 AND s.slot_date = $2 ORDER BY s.start_time`,
      [venueId, slotDate, userId],
    );
  } else if (slotDate === now.date) {
    slots = await runner.query(
      `SELECT ${slotColumns('$4')} FROM slots s
        WHERE s.venue_id = $1 AND s.slot_date = $2 AND s.start_time > $3
        ORDER BY s.start_time`,
      [venueId, slotDate, now.time, userId],
    );
  }
  return { ok: true, status: 200, code: 'ok', message: null,
    data: { ...venue.rows[0], slots: slots.rows }, slotDate };
}

/**
 * freeSlots — the slot_picker card's rows, and the only list Scout is allowed to
 * offer as bookable.
 *
 * A slot qualifies when it is 'available', not on someone else's live hold, and
 * still in the future in PKT. That is the same predicate createBooking re-checks
 * under a row lock, so the picker cannot show a chip the booking then refuses —
 * except in the genuine race, which bookingService answers with `slot_taken`.
 *
 * `time` is an optional preference ("shaam 6 baje"): rather than filter to an
 * exact match and come back empty, it ORDERS by distance from the asked hour, so
 * "6pm" with nothing at 6 offers 5pm and 7pm instead of a dead end.
 */
async function freeSlots(client, {
  venueId, userId = null, date = null, time = null, limit = 6,
} = {}) {
  const runner = client || pool;
  const slotDate = normDate(date);
  const now = pktNow();
  if (slotDate < now.date) return { slots: [], slotDate, past: true };

  const params = [venueId, slotDate, userId];
  let cutoff = '';
  if (slotDate === now.date) {
    params.push(now.time);
    cutoff = ` AND s.start_time > $${params.length}`;
  }
  let order = 's.start_time';
  if (/^\d{1,2}:\d{2}(:\d{2})?$/.test(String(time || ''))) {
    params.push(String(time).length === 5 ? `${time}:00` : String(time));
    order = `abs(extract(epoch from (s.start_time - $${params.length}::time))), s.start_time`;
  }
  params.push(clampLimit(limit, 6, 24));
  const { rows } = await runner.query(
    `SELECT ${slotColumns('$3')} FROM slots s
      WHERE s.venue_id = $1 AND s.slot_date = $2
        AND s.status = 'available'
        AND NOT (${HOLD_IS_LIVE} AND (s.locked_by IS DISTINCT FROM $3))${cutoff}
      ORDER BY ${order}
      LIMIT $${params.length}`,
    params,
  );
  return { slots: rows, slotDate, past: false };
}
/**
 * slotById — the one slot a confirm card is allowed to quote a price for.
 *
 * The picker hands back an id, and between painting that card and the user saying
 * "haan" anything can happen to the row: another player books it, the owner blocks
 * it, someone starts a checkout hold on it, or the hour simply passes. So the
 * confirm step re-reads the slot through this function instead of trusting the
 * price it printed a minute ago, and `bookable` is the same three-part predicate
 * freeSlots filters on — available, not on a FOREIGN hold, still ahead in PKT.
 *
 * It reports why a slot is unbookable rather than just refusing, because "that 6pm
 * just got booked" is a far better sentence than "nothing free". The authority is
 * still bookingService.createBooking, which re-checks all of it under a row lock;
 * this is only the read that lets Scout ask a truthful question first.
 *
 * `slot_date` is cast in SQL. node-postgres hands a date column back as a JS Date
 * in the server's timezone, and "2026-08-30" one hour west of PKT stringifies as
 * the 29th — which would put the wrong day on a confirmation the user is about to
 * pay for.
 */
async function slotById(client, { slotId, userId = null } = {}) {
  const runner = client || pool;
  const id = String(slotId == null ? '' : slotId).trim().toLowerCase();
  if (!access.isUuid(id)) {
    return { ok: false, status: 400, code: 'bad_slot',
      message: 'Which time slot did you mean?', data: null };
  }
  const { rows } = await runner.query(
    `SELECT ${slotColumns('$2')},
            to_char(s.slot_date, 'YYYY-MM-DD') AS slot_date_str,
            v.name AS venue_name, v.sport_type, v.city, v.address,
            v.latitude, v.longitude, v.is_active AS venue_active
       FROM slots s JOIN venues v ON v.id = s.venue_id
      WHERE s.id = $1`,
    [id, userId],
  );
  if (!rows.length) {
    return { ok: false, status: 404, code: 'slot_not_found',
      message: 'That time slot no longer exists.', data: null };
  }
  const s = rows[0];
  const now = pktNow();
  const past = s.slot_date_str < now.date
    || (s.slot_date_str === now.date && String(s.start_time) <= now.time);
  let reason = null;
  if (!s.venue_active) reason = 'venue_inactive';
  else if (past) reason = 'past';
  else if (s.status !== 'available') reason = (s.status === 'booked' ? 'taken' : 'blocked');
  else if (s.is_locked && !s.locked_by_me) reason = 'held';
  return {
    ok: true, status: 200, code: 'ok', message: null,
    data: { ...s, slotDate: s.slot_date_str, bookable: reason === null, reason },
  };
}


// Tournaments  (013: status open|active|completed|cancelled)

/**
 * listTournaments — Scout's `tournament_list` and `GET /api/tournaments` (FE-2).
 *
 * "Open" is a compound fact, not just a status: a tournament is joinable while
 * status='open', the registration deadline has not passed, and it is not already
 * full. The count of teams holding a spot is therefore part of the row rather than
 * something a caller works out afterwards, so `spotsLeft` and `isFull` cannot
 * disagree between the assistant and a screen.
 *
 * Why `teams_in` counts 'registered' as well as 'accepted'
 * `tournament_teams.status` defaults to 'registered' (013) and only becomes
 * 'accepted' once the organiser approves — and on a tournament with
 * `requires_approval = false` that approval never happens, because payment is the
 * acceptance. Counting only 'accepted' therefore reported 0 of 8 spots taken for
 * every open tournament and would have let a ninth team pay into a full bracket.
 * A team whose entry fee is frozen pending approval is occupying a spot, so it is
 * counted; `teams_accepted` is published alongside for screens that need the
 * confirmed subset.
 *
 * FE-2's filters (sport, city, start date) are all applied in SQL rather than by
 * the caller, so `limit` means "10 matching tournaments" and not "10 rows, some of
 * which you will throw away".
 */
async function listTournaments(client, {
  sport = null, city = null, startFrom = null, status = null, q = '',
  venueId = null, ownerId = null, openOnly = true, limit = 10,
} = {}) {
  const runner = client || pool;
  const params = [];
  const where = ['1 = 1'];
  if (sport) { params.push(String(sport)); where.push(`LOWER(t.sport) = LOWER($${params.length})`); }
  if (city) { params.push(`%${access.squash(city)}%`); where.push(`v.city ILIKE $${params.length}`); }
  if (startFrom) { params.push(String(startFrom)); where.push(`t.start_date >= $${params.length}::date`); }
  if (status) { params.push(String(status)); where.push(`t.status = $${params.length}`); }
  if (venueId) { params.push(String(venueId)); where.push(`t.venue_id = $${params.length}`); }
  if (ownerId) { params.push(String(ownerId)); where.push(`t.owner_id = $${params.length}`); }
  const term = access.squash(q || '');
  if (term) { params.push(`%${term}%`); where.push(`t.name ILIKE $${params.length}`); }
  if (openOnly) where.push("t.status = 'open'", 't.registration_deadline > NOW()');
  params.push(clampLimit(limit, 10, 50));
  const { rows } = await runner.query(
    `SELECT t.id, t.name, t.description, t.sport, t.format, t.entry_fee,
            t.max_teams, t.min_teams, t.requires_approval,
            t.registration_deadline, t.start_date, t.status, t.rounds,
            t.prize_percent, t.winner_percent, t.runnerup_percent,
            t.pool_amount, t.prize_amount, t.owner_id,
            v.name AS venue_name, v.city AS venue_city, v.id AS venue_id,
            u.name AS organiser_name,
            wt.name AS winner_name,
            (SELECT count(*)::int FROM tournament_teams tt
              WHERE tt.tournament_id = t.id
                AND tt.status IN ('registered','accepted')) AS teams_in,
            (SELECT count(*)::int FROM tournament_teams tt
              WHERE tt.tournament_id = t.id AND tt.status = 'accepted') AS teams_accepted
       FROM tournaments t
       LEFT JOIN venues v ON v.id = t.venue_id
       LEFT JOIN users u ON u.id = t.owner_id
       LEFT JOIN teams wt ON wt.id = t.winner_team
      WHERE ${where.join(' AND ')}
      ORDER BY t.registration_deadline ASC, t.start_date ASC NULLS LAST
      LIMIT $${params.length}`,
    params,
  );
  return rows.map((r) => ({
    ...r,
    entry_fee: Number(r.entry_fee || 0),
    spotsLeft: Math.max(0, Number(r.max_teams || 0) - Number(r.teams_in || 0)),
    isFull: Number(r.teams_in || 0) >= Number(r.max_teams || 0),
  }));
}

// TEAMS

/**
 * discoverTeams — GET /api/teams/discover, and Scout's `find_teams`.
 *
 * Public teams the caller is not already in, strongest first. The two exclusions
 * are the whole privacy story of the endpoint: `visibility='public'` keeps private
 * squads out of a stranger's list, and the NOT EXISTS keeps "find me a team" from
 * offering the user the team they captain.
 */
async function discoverTeams(client, { userId, sport = null, q = '', limit = 60 } = {}) {
  const runner = client || pool;
  const params = [userId];
  let where = `t.visibility = 'public'
      AND NOT EXISTS (SELECT 1 FROM team_members m WHERE m.team_id = t.id AND m.user_id = $1)`;
  if (sport) {
    const s = access.validateSport(sport);
    if (!s.ok) return { ok: false, status: 400, code: 'bad_sport', message: s.message, data: null };
    params.push(s.value);
    where += ` AND t.sport = $${params.length}`;
  }
  const term = access.squash(q || '');
  if (term) { params.push(`%${term}%`); where += ` AND t.name ILIKE $${params.length}`; }
  params.push(clampLimit(limit, 60, 100));
  const { rows } = await runner.query(
    `SELECT ${access.TEAM_COLUMNS},
            (SELECT count(*)::int FROM team_members m WHERE m.team_id = t.id) AS member_count
       FROM teams t WHERE ${where}
      ORDER BY t.elo DESC, lower(t.name)
      LIMIT $${params.length}`,
    params,
  );
  return { ok: true, status: 200, code: 'ok', message: null, data: rows };
}

module.exports = {
  PKT_OFFSET_MS, VENUE_LIMIT, VENUE_MAX, HOLD_IS_LIVE, slotColumns,
  pktNow, normDate,
  searchVenues, venueDetail, freeSlots, slotById, listTournaments, discoverTeams,
};
