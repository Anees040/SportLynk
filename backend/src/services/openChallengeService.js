/**
 * openChallengeService.js — the Live Challenge Feed ("Open Cards", item 9 / FR5.x).
 *
 * A captain with a confirmed booking posts it to a public board with no named
 * opponent; any other captain can claim it. A claim creates a normal `accepted`
 * match between the two teams, pinned to the poster's booking, and opens the
 * captains' prep room — exactly what a direct challenge+accept produces. This file
 * does NOT reimplement the match: it reuses utils/matchCore (deriveCompAndPreview,
 * teamFeatures, leadIdsOf, fanOut, emitAfterCommit) and chatCore.ensureCaptainChannel,
 * the same primitives routes/matches.js uses, so a claimed open card and a direct
 * challenge are the same fixture by the time either reaches the apps.
 *
 * The table (open_challenges) and the relaxed ux_matches_booking_live are migration
 * 041 (041_multi_challenge.sql). First claim wins: the accepted-match insert trips
 * that unique index, so a second simultaneous claim 409s rather than double-booking
 * the slot. A card dies at slot start; the board filters open + unexpired lazily (no
 * sweep job), and claim re-checks the booking is still confirmed and in the future.
 *
 * The functions take a `client` already inside a transaction (same contract as
 * bookingService); `*Tx` wrappers own BEGIN/COMMIT/ROLLBACK and flush the match's
 * socket/chat emits strictly after commit.
 */
const pool = require('../db/pool');
const mc = require('../utils/matchCore');
const chat = require('../utils/chatCore');
const access = require('../utils/teamAccess');

const TZ = mc.TIMEZONE;

function fail(status, code, message) {
  return { ok: false, status, code, message, data: null };
}
function done(status, data, message = null) {
  return { ok: true, status, code: 'ok', message, data };
}

/** slot_date arrives from pg as a Date; bookings store PKT wall-clock text. */
function localDateStr(v) {
  return v instanceof Date ? v.toLocaleDateString('en-CA') : v;
}

/**
 * The shortest notice a slot may be posted with. A card lives only until its slot
 * starts (`expires_at`), so posting one that begins in minutes would offer an
 * opponent a slot they cannot realistically accept, travel to and play. Refusing it
 * here rather than letting the poster learn from an empty card is the difference
 * between a rule and a guess.
 *
 * It is deliberately the ONLY new constraint in this file. The claim window changes
 * nothing about which bookings are postable beyond this floor, so a poster's
 * exposure stays exactly what it was: their own confirmed booking, cancellable
 * under the ordinary policy until an opponent claims it.
 */
const MIN_NOTICE_HOURS = 2;

/**
 * Is the open_challenges table present (migration 041)? Guard the whole feature so
 * it degrades to a clean 503 rather than a raw 42P01 on a database where the
 * concurrent session's migration has not been applied yet.
 *
 * A POSITIVE answer is cached for the life of the process, because a table cannot
 * disappear. A NEGATIVE answer is not, because it can become stale: the API is
 * routinely left running (`npm run dev`) while a migration is applied underneath it,
 * and caching the miss would park the whole feature behind a "not available yet"
 * until someone happened to restart the server. `slotService.venueColumns` handles
 * the same problem the same way.
 */
let tablePresent = false;
async function hasTable(client) {
  if (tablePresent) return true;
  const { rows } = await client.query("SELECT to_regclass('public.open_challenges') AS t");
  tablePresent = Boolean(rows[0] && rows[0].t);
  return tablePresent;
}

/**
 * Post one of the caller's confirmed bookings to the open board. Mirrors the booking
 * validation in routes/matches.js POST /challenge: the booking must be the caller's
 * own, confirmed, still upcoming, for the team's sport, and not already locked to a
 * match. The unique partial index (one open card per booking) makes a duplicate a 409.
 */
async function postChallenge(client, { userId, teamId, bookingId }) {
  if (!(await hasTable(client))) {
    return fail(503, 'not_available', 'The open challenge board is not available yet.');
  }
  if (!access.isUuid(teamId)) return fail(400, 'bad_team', 'Choose which of your teams is posting.');
  if (!access.isUuid(bookingId)) return fail(400, 'bad_booking', 'Choose one of your confirmed bookings.');

  // Authority: the caller must be a captain of the posting team. requireRole locks
  // the team row and reads the role from team_members inside this transaction.
  const gate = await access.requireRole(client, teamId, userId, 'captain');
  if (gate.error) return fail(gate.error.status, 'forbidden', gate.error.message);

  const features = await mc.teamFeatures(client, [teamId]);
  const team = features.get(String(teamId));
  if (!team) return fail(404, 'team_not_found', 'Your team no longer exists.');

  const { rows: bRows } = await client.query(
    `SELECT b.id, b.slot_date, b.start_time, b.status::text AS status,
            lower(v.sport_type) AS venue_sport,
            ((b.slot_date::DATE + b.start_time::TIME) > (NOW() AT TIME ZONE $3)) AS is_future,
            (EXTRACT(EPOCH FROM
               (((b.slot_date::DATE + b.start_time::TIME) AT TIME ZONE $3) - NOW())
             ) / 3600.0) AS hours_until
       FROM bookings b
       JOIN venues v ON v.id = b.venue_id
      WHERE b.id = $1 AND b.player_id = $2`,
    [bookingId, userId, TZ],
  );
  const booking = bRows[0];
  if (!booking) return fail(404, 'booking_not_found', 'Booking not found.');
  if (booking.status !== 'confirmed') {
    return fail(409, 'not_confirmed', 'Only a confirmed booking can be posted to the board.');
  }
  if (booking.is_future !== true) {
    return fail(409, 'slot_past', 'That slot has already started. Pick an upcoming booking.');
  }
  // This is also the exact notice the board's `expires_at` gives the card, so the
  // floor is not an extra rule bolted on: it is the same number read back.
  if (Number(booking.hours_until) < MIN_NOTICE_HOURS) {
    return fail(409, 'too_soon',
      `That slot starts in under ${MIN_NOTICE_HOURS} hours, which is not enough notice for `
      + 'another team to accept it. Pick a later booking.');
  }
  if (['football', 'cricket'].includes(booking.venue_sport)
      && booking.venue_sport !== team.sport) {
    return fail(400, 'sport_mismatch', 'That venue is not for this sport.');
  }

  const { rows: locked } = await client.query(
    `SELECT 1 FROM matches WHERE booking_id = $1 AND status = ANY($2::text[]) LIMIT 1`,
    [bookingId, mc.LOCKED_STATUSES],
  );
  if (locked.length) return fail(409, 'slot_locked', 'That slot is already locked to a match.');

  let ins;
  try {
    ({ rows: ins } = await client.query(
      `INSERT INTO open_challenges (booking_id, challenger_team, sport, status, expires_at, created_by)
       SELECT $1, $2, $3, 'open',
              ((b.slot_date::DATE + b.start_time::TIME) AT TIME ZONE $4), $5
         FROM bookings b WHERE b.id = $1
       RETURNING id`,
      [bookingId, teamId, team.sport, TZ, userId],
    ));
  } catch (e) {
    if (e.code === '23505') {
      return fail(409, 'already_open', 'This slot is already on the open board.');
    }
    throw e;
  }
  return done(201, { id: ins[0].id },
    'Your slot is on the open board. The first team to accept locks the match.');
}

/**
 * The board: open, unexpired cards, soonest slot first, optionally filtered by sport.
 * Read-only, so it accepts the pool directly. `mine` flags a card the viewer's own
 * team posted (the claim path refuses a self-claim), so the client can hide its
 * Accept button without a second request.
 */
async function listBoard(clientOrPool, { userId, sport = null, limit = 50 } = {}) {
  const runner = clientOrPool || pool;
  if (!(await hasTable(runner))) return done(200, { challenges: [] });

  const params = [TZ, userId];
  let sportFilter = '';
  if (sport && String(sport).trim()) {
    params.push(String(sport).toLowerCase());
    sportFilter = `AND oc.sport = $${params.length}`;
  }
  params.push(Math.max(1, Math.min(Number(limit) || 50, 100)));

  const { rows } = await runner.query(
    `SELECT oc.id, oc.booking_id, oc.challenger_team, oc.sport, oc.expires_at, oc.created_at,
            t.name AS team_name, t.logo_url AS team_logo, t.city AS team_city,
            t.elo AS team_elo, t.wins AS team_wins, t.losses AS team_losses, t.draws AS team_draws,
            b.slot_date, b.start_time, b.end_time,
            v.name AS venue_name, v.city AS venue_city,
            EXISTS (SELECT 1 FROM team_members tm
                     WHERE tm.team_id = oc.challenger_team AND tm.user_id = $2) AS mine
       FROM open_challenges oc
       JOIN teams t    ON t.id = oc.challenger_team
       JOIN bookings b ON b.id = oc.booking_id
       JOIN venues v   ON v.id = b.venue_id
      WHERE oc.status = 'open' AND oc.expires_at > NOW()
        ${sportFilter}
      ORDER BY oc.expires_at ASC
      LIMIT $${params.length}`,
    params,
  );

  const challenges = rows.map((r) => ({
    id: r.id,
    sport: r.sport,
    expiresAt: r.expires_at,
    createdAt: r.created_at,
    mine: r.mine === true,
    team: {
      id: r.challenger_team,
      name: r.team_name,
      logoUrl: r.team_logo || null,
      city: r.team_city || null,
      elo: mc.int0(r.team_elo),
      wins: mc.int0(r.team_wins),
      losses: mc.int0(r.team_losses),
      draws: mc.int0(r.team_draws),
    },
    booking: {
      id: r.booking_id,
      slotDate: localDateStr(r.slot_date),
      startTime: r.start_time,
      endTime: r.end_time,
      venueName: r.venue_name,
      venueCity: r.venue_city || null,
    },
  }));
  return done(200, { challenges });
}

/**
 * Claim an open card: lock it, validate the claiming captain and sport, re-check the
 * booking, then create the accepted match (first claim wins via ux_matches_booking_live)
 * and open the prep room. The fan-out is the same match-accept fan-out routes/matches.js
 * sends, so the poster is notified "accepted your challenge" exactly as a direct accept
 * would, with no new notification type.
 */
async function claimChallenge(client, { userId, openId, teamId }) {
  if (!(await hasTable(client))) {
    return fail(503, 'not_available', 'The open challenge board is not available yet.');
  }
  if (!access.isUuid(openId)) return fail(404, 'not_found', 'That open challenge no longer exists.');
  if (!access.isUuid(teamId)) return fail(400, 'bad_team', 'Choose which of your teams is claiming.');

  const { rows: cRows } = await client.query(
    `SELECT id, booking_id, challenger_team, status, expires_at
       FROM open_challenges WHERE id = $1 FOR UPDATE`,
    [openId],
  );
  const card = cRows[0];
  if (!card) return fail(404, 'not_found', 'That open challenge no longer exists.');
  if (card.status !== 'open') {
    return fail(409, 'already_decided', 'That slot has already been claimed or withdrawn.');
  }
  if (new Date(card.expires_at).getTime() <= Date.now()) {
    return fail(409, 'expired', 'That slot window has already passed.');
  }
  if (String(teamId) === String(card.challenger_team)) {
    return fail(400, 'own_card', 'You cannot claim your own team\'s challenge.');
  }

  const gate = await access.requireRole(client, teamId, userId, 'captain');
  if (gate.error) return fail(gate.error.status, 'forbidden', gate.error.message);

  const features = await mc.teamFeatures(client, [card.challenger_team, teamId]);
  const challenger = features.get(String(card.challenger_team));
  const opponent = features.get(String(teamId));
  if (!challenger || !opponent) return fail(404, 'team_not_found', 'One of the teams no longer exists.');
  if (challenger.sport !== opponent.sport) {
    return fail(400, 'sport_mismatch', 'Your team plays a different sport.');
  }

  // The poster could have cancelled the booking after posting; re-check under the lock.
  const { rows: bRows } = await client.query(
    `SELECT b.status::text AS status,
            ((b.slot_date::DATE + b.start_time::TIME) > (NOW() AT TIME ZONE $2)) AS is_future
       FROM bookings b WHERE b.id = $1`,
    [card.booking_id, TZ],
  );
  const b = bRows[0];
  if (!b || b.status !== 'confirmed' || b.is_future !== true) {
    return fail(409, 'slot_unavailable', 'That slot is no longer available.');
  }

  const { competitiveness, previewText } = mc.deriveCompAndPreview({
    challenger, opponent, seed: `${card.challenger_team}:${teamId}:${card.booking_id}`,
  });

  let matchId;
  try {
    const { rows: ins } = await client.query(
      `INSERT INTO matches
         (challenger_team, opponent_team, booking_id, sport, status,
          competitiveness, preview_text, created_by, responded_at, updated_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, now(), now())
       RETURNING id`,
      [card.challenger_team, teamId, card.booking_id, challenger.sport, mc.STATUS.ACCEPTED,
        competitiveness, previewText, userId],
    );
    matchId = ins[0].id;
  } catch (e) {
    // ux_matches_booking_live — another team's claim (or a direct challenge) locked
    // the slot a moment earlier.
    if (e.code === '23505') return fail(409, 'slot_taken', 'Another team just claimed this slot.');
    throw e;
  }

  await client.query(
    `UPDATE open_challenges
        SET status = 'claimed', claimed_by_team = $2, claimed_match_id = $3, decided_at = now()
      WHERE id = $1`,
    [openId, teamId, matchId],
  );

  // Prep room + the match-accept fan-out, mirroring routes/matches.js respond-accept.
  const leads = await mc.leadIdsOf(client, [card.challenger_team, teamId]);
  const coordChannelId = await chat.ensureCaptainChannel(client, {
    matchId,
    title: `${challenger.name} vs ${opponent.name}`,
    memberIds: leads,
  });
  const { pills, memberIds } = await mc.fanOut(client, {
    matchId,
    coord: { event: 'match_coordinate', channelId: coordChannelId },
    sides: [
      {
        teamId: card.challenger_team,
        event: 'match_accepted',
        otherTeamName: opponent.name,
        notify: {
          type: 'match_accepted',
          title: `${opponent.name} accepted your open challenge`,
          body: 'Your match is confirmed. Submit the result once the slot is over.',
          extra: { opponentTeam: teamId },
        },
      },
      {
        teamId,
        event: 'match_accepted',
        otherTeamName: challenger.name,
        notify: {
          type: 'match_accepted',
          title: `Match confirmed vs ${challenger.name}`,
          body: 'You claimed an open slot. Coordinate in the captains\' room.',
          extra: { opponentTeam: card.challenger_team },
        },
      },
    ],
  });

  const result = done(201, { matchId, openChallengeId: openId },
    `Match locked against ${challenger.name}. Coordinate in the captains' room.`);
  result._matchEmit = { matchId, pills, memberIds, extra: { event: 'accepted' } };
  return result;
}

/** Withdraw an open card. Only a captain of the posting team may. */
async function cancelChallenge(client, { userId, openId }) {
  if (!(await hasTable(client))) {
    return fail(503, 'not_available', 'The open challenge board is not available yet.');
  }
  if (!access.isUuid(openId)) return fail(404, 'not_found', 'That open challenge no longer exists.');

  const { rows: cRows } = await client.query(
    'SELECT id, challenger_team, status FROM open_challenges WHERE id = $1 FOR UPDATE',
    [openId],
  );
  const card = cRows[0];
  if (!card) return fail(404, 'not_found', 'That open challenge no longer exists.');
  if (card.status !== 'open') return fail(409, 'already_decided', 'That challenge is no longer open.');

  const gate = await access.requireRole(client, card.challenger_team, userId, 'captain');
  if (gate.error) return fail(gate.error.status, 'forbidden', gate.error.message);

  await client.query(
    "UPDATE open_challenges SET status = 'cancelled', decided_at = now() WHERE id = $1",
    [openId],
  );
  return done(200, { id: openId }, 'Open challenge withdrawn.');
}

/**
 * The only place BEGIN/COMMIT/ROLLBACK is written for the write paths. A claim's
 * match emits (socket pings + chat pills) flush strictly after COMMIT, mirroring
 * routes/matches.js — emitting inside the transaction tells a client to re-fetch a
 * row it cannot see yet.
 */
async function runInTx(fn) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const result = await fn(client);
    if (result && result.ok) await client.query('COMMIT');
    else await client.query('ROLLBACK');
    if (result && result.ok && result._matchEmit) {
      await mc.emitAfterCommit(pool, result._matchEmit);
    }
    return result;
  } catch (e) {
    try { await client.query('ROLLBACK'); } catch { /* connection already gone */ }
    throw e;
  } finally {
    client.release();
  }
}

const postChallengeTx = (input) => runInTx((c) => postChallenge(c, input));
const claimChallengeTx = (input) => runInTx((c) => claimChallenge(c, input));
const cancelChallengeTx = (input) => runInTx((c) => cancelChallenge(c, input));

module.exports = {
  MIN_NOTICE_HOURS,
  postChallenge,
  postChallengeTx,
  listBoard,
  claimChallenge,
  claimChallengeTx,
  cancelChallenge,
  cancelChallengeTx,
  runInTx,
};
