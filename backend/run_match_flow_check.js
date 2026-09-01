/**
 * S.2 Wave C acceptance harness — the whole match lifecycle over real HTTP.
 *
 * `npm test` covers the ELO arithmetic in isolation (test/elo.test.js, no
 * database). This is the other half: it drives the actual Express routes with
 * actual JWTs against the live database, because every bug worth finding in this
 * wave lives in the seams the unit tests cannot reach — the authority checks, the
 * state machine, the transaction boundaries, and the ELO exchange landing in the
 * same commit as the status change.
 *
 * What it proves
 *   Happy path      challenge → accept → two agreeing results → owner verifies →
 *                   ratings move, two elo_history rows, W/L recorded
 *   Conflict path   two disagreeing results → disputed, a SYSTEM dispute row with
 *                   raised_by_team NULL (so ER2.3 counts it against nobody), and
 *                   verification refused afterwards
 *   Dispute path    a captain disputes inside the 24h window (FR5.17)
 *   Authority       non-captains cannot challenge or submit; a stranger owner
 *                   cannot verify; the body cannot override the caller's identity
 *   Idempotency     no double submission, no double verification, no second
 *                   challenge on a booking that already has a live match
 *
 * It also seeds. Running it leaves two real public teams with captains, chat
 * channels and confirmed bookings behind — which is exactly the fixture needed
 * for the two-phone manual test, so that setup does not have to be done by hand.
 *
 * USAGE
 *   1. node src/server.js          (in another terminal — this drives it over HTTP)
 *   2. node run_match_flow_check.js
 *
 * Safe to re-run: seeding is idempotent on the team names below, and every match
 * it creates is new.
 */

require('dotenv').config();
const jwt = require('jsonwebtoken');
const pool = require('./src/db/pool');
const chat = require('./src/utils/chatCore');

const BASE = process.env.SL_CHECK_BASE || 'http://localhost:3000/api';
const TEAM_A_NAME = 'E2E Falcons';
const TEAM_B_NAME = 'E2E Titans';

// Reporting
const results = [];
let failed = 0;

function check(label, condition, detail = '') {
  const pass = condition === true;
  if (!pass) failed++;
  results.push({ ok: pass ? 'PASS' : 'FAIL', label, detail: String(detail).slice(0, 120) });
  console.log(`  ${pass ? '✅' : '❌'} ${label}${detail && !pass ? `  → ${detail}` : ''}`);
  return pass;
}

function section(title) {
  console.log(`\n── ${title} ${'─'.repeat(Math.max(0, 62 - title.length))}`);
}

// HTTP
async function call(method, path, { token, body } = {}) {
  const res = await fetch(`${BASE}${path}`, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  let json = null;
  try { json = await res.json(); } catch { /* non-JSON body */ }
  return { status: res.status, ok: res.ok, body: json };
}

const sign = (u) => jwt.sign(
  { id: u.id, role: u.role, phone: u.phone || null },
  process.env.JWT_SECRET,
  { expiresIn: '1h' },
);

// Seeding

/** A public football team captained by `userId`, with its chat channel wired. */
async function ensureTeam(client, name, userId) {
  const found = await client.query('SELECT id FROM teams WHERE name = $1', [name]);
  let teamId = found.rows[0]?.id;
  if (!teamId) {
    const ins = await client.query(
      `INSERT INTO teams (name, sport, visibility, city, captain_id)
       VALUES ($1, 'football', 'public', 'Islamabad', $2) RETURNING id`,
      [name, userId],
    );
    teamId = ins.rows[0].id;
  } else {
    // Re-runs: reset the ladder state so assertions about deltas are meaningful
    // rather than dependent on how many times this script has run before.
    await client.query(
      `UPDATE teams SET elo = 1000, elo_rating = 1000, wins = 0, losses = 0, draws = 0,
              elo_frozen = FALSE, elo_frozen_reason = NULL, elo_frozen_at = NULL,
              captain_id = $2
        WHERE id = $1`,
      [teamId, userId],
    );
    await client.query('DELETE FROM elo_history WHERE team_id = $1', [teamId]);
  }
  await client.query(
    `INSERT INTO team_members (team_id, user_id, role)
     VALUES ($1, $2, 'captain')
     ON CONFLICT (team_id, user_id) DO UPDATE SET role = 'captain'`,
    [teamId, userId],
  );
  const { rows } = await client.query('SELECT id, name, logo_url, captain_id FROM teams WHERE id = $1', [teamId]);
  const channelId = await chat.ensureTeamChannel(client, rows[0]);
  await chat.syncTeamMember(client, channelId, userId, 'captain');
  return { id: teamId, name, channelId };
}

/** A plain member (not a captain) — the negative-authority subject. */
async function ensureMember(client, teamId, userId, channelId) {
  await client.query(
    `INSERT INTO team_members (team_id, user_id, role)
     VALUES ($1, $2, 'member')
     ON CONFLICT (team_id, user_id) DO UPDATE SET role = 'member'`,
    [teamId, userId],
  );
  await chat.syncTeamMember(client, channelId, userId, 'member');
}

/** A confirmed booking `hoursAhead` from now, owned by `playerId`. */
async function makeBooking(client, { playerId, venueId, price, hoursAhead }) {
  const { rows } = await client.query(
    `INSERT INTO bookings
       (player_id, venue_id, slot_date, start_time, end_time,
        base_price, security_deposit, total_amount, status, notes)
     SELECT $1, $2,
            (d)::date, (d)::time, ((d) + interval '1 hour')::time,
            $3, ROUND($3 * 0.20, 2), $3, 'confirmed', 'S2 Wave C acceptance fixture'
       FROM (SELECT date_trunc('hour', (NOW() AT TIME ZONE 'Asia/Karachi') + ($4 || ' hours')::interval) AS d) s
     RETURNING id, slot_date, start_time`,
    [playerId, venueId, price, String(hoursAhead)],
  );
  return rows[0];
}

/// Simulate the slot having been played, so results become submittable.
///
/// `checked_in_at` is set along with the dates, and not merely to stop the
/// no-show sweep charging a deposit for a slot this script back-dated: a match
/// whose result two captains are about to submit is by definition one where the
/// teams turned up, so an un-checked-in played slot would be the dishonest state.
async function pushBookingIntoPast(client, bookingId) {
  await client.query(
    `UPDATE bookings
        SET slot_date = ((NOW() AT TIME ZONE 'Asia/Karachi') - interval '3 hours')::date,
            start_time = ((NOW() AT TIME ZONE 'Asia/Karachi') - interval '3 hours')::time,
            end_time = ((NOW() AT TIME ZONE 'Asia/Karachi') - interval '2 hours')::time,
            checked_in_at = COALESCE(checked_in_at, now())
      WHERE id = $1`,
    [bookingId],
  );
}

async function seed() {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    const players = (await client.query(
      "SELECT id, name, role, phone FROM users WHERE role = 'player' ORDER BY created_at LIMIT 3",
    )).rows;
    if (players.length < 3) throw new Error('need at least 3 player accounts to seed');

    const venue = (await client.query(
      `SELECT v.id, v.name, v.owner_id, v.base_price
         FROM venues v WHERE v.is_active AND lower(v.sport_type) = 'football'
        ORDER BY v.created_at LIMIT 1`,
    )).rows[0];
    if (!venue) throw new Error('need one active football venue to seed');

    const owner = (await client.query(
      'SELECT id, name, role, phone FROM users WHERE id = $1', [venue.owner_id],
    )).rows[0];

    // A different owner, to prove the verify gate is per-venue and not per-role.
    const otherOwner = (await client.query(
      "SELECT id, name, role, phone FROM users WHERE role = 'owner' AND id <> $1 LIMIT 1",
      [venue.owner_id],
    )).rows[0];

    const teamA = await ensureTeam(client, TEAM_A_NAME, players[0].id);
    const teamB = await ensureTeam(client, TEAM_B_NAME, players[1].id);
    await ensureMember(client, teamA.id, players[2].id, teamA.channelId);

    const price = Number(venue.base_price) || 2000;
    const bHappy = await makeBooking(client, {
      playerId: players[0].id, venueId: venue.id, price, hoursAhead: 5,
    });
    const bConflict = await makeBooking(client, {
      playerId: players[0].id, venueId: venue.id, price, hoursAhead: 30,
    });
    const bSpare = await makeBooking(client, {
      playerId: players[0].id, venueId: venue.id, price, hoursAhead: 55,
    });

    await client.query('COMMIT');
    return {
      captainA: players[0], captainB: players[1], memberA: players[2],
      owner, otherOwner, venue, teamA, teamB,
      bookings: { happy: bHappy, conflict: bConflict, spare: bSpare },
    };
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    throw e;
  } finally {
    client.release();
  }
}

// The run
async function main() {
  console.log('SportLynk — S.2 Wave C acceptance check');
  console.log(`Target: ${BASE}\n`);

  // Fail fast and clearly if the server is not up, rather than 20 confusing FAILs.
  try {
    const ping = await fetch(`${BASE}/health`).catch(() => null);
    if (!ping || !ping.ok) throw new Error('no response');
  } catch {
    console.error('❌ Cannot reach the API. Start it first:  node src/server.js');
    process.exit(1);
  }

  const s = await seed();
  const tokA = sign(s.captainA);
  const tokB = sign(s.captainB);
  const tokMember = sign(s.memberA);
  const tokOwner = sign(s.owner);
  const tokOther = s.otherOwner ? sign(s.otherOwner) : null;

  console.log(`Seeded: ${s.teamA.name} (captain ${s.captainA.name}) vs ${s.teamB.name} (captain ${s.captainB.name})`);
  console.log(`Venue:  ${s.venue.name} — owner ${s.owner.name}`);

  // Reads that feed the screens
  section('Opponent discovery (FR5.3 – FR5.5)');
  const opp = await call('GET', `/matches/opponents?teamId=${s.teamA.id}`, { token: tokA });
  check('GET /opponents returns 200', opp.status === 200, JSON.stringify(opp.body).slice(0, 160));
  const oppList = opp.body?.data?.opponents || [];
  const titans = oppList.find((o) => o.id === s.teamB.id);
  check('the other public team is listed', Boolean(titans), `got ${oppList.length} opponents`);
  check('trust badge present (FR5.5)', Boolean(titans?.trustBand), `band=${titans?.trustBand} score=${titans?.trustScore}`);
  check('rating gap + band flag present (FR5.3)',
    titans?.eloGap === 0 && titans?.withinBand === true, `gap=${titans?.eloGap}`);
  check('unranked team reports competitiveness null (FR2.6/FR5.4)',
    titans?.competitiveness === null && titans?.ranked === false,
    `comp=${titans?.competitiveness} ranked=${titans?.ranked}`);
  check('captain may challenge', opp.body?.data?.canChallenge === true);

  const oppAsMember = await call('GET', `/matches/opponents?teamId=${s.teamA.id}`, { token: tokMember });
  check('a plain member sees the list but canChallenge is false',
    oppAsMember.status === 200 && oppAsMember.body?.data?.canChallenge === false,
    `status=${oppAsMember.status} canChallenge=${oppAsMember.body?.data?.canChallenge}`);

  const oppStranger = await call('GET', `/matches/opponents?teamId=${s.teamB.id}`, { token: tokA });
  check('cannot list opponents for a team you are not in', oppStranger.status === 403,
    `status=${oppStranger.status}`);

  section('Preview + venue picker (FR5.10, FR5.11)');
  const prev = await call('GET',
    `/matches/preview?challengerTeam=${s.teamA.id}&opponentTeam=${s.teamB.id}`, { token: tokA });
  check('GET /preview returns 200', prev.status === 200);
  check('preview text is generated', (prev.body?.data?.previewText || '').length > 30,
    prev.body?.data?.previewText);
  check('preview is labelled "Preview", not a prediction',
    prev.body?.data?.previewLabel === 'Preview', prev.body?.data?.previewLabel);

  const link = await call('GET', `/matches/linkable-bookings?teamId=${s.teamA.id}`, { token: tokA });
  const linkable = link.body?.data || [];
  check('confirmed future bookings are offered', linkable.length >= 3, `got ${linkable.length}`);
  check('the happy-path booking is among them',
    linkable.some((b) => b.id === s.bookings.happy.id));

  const linkB = await call('GET', `/matches/linkable-bookings?teamId=${s.teamB.id}`, { token: tokB });
  check('another captain does not see my bookings',
    (linkB.body?.data || []).every((b) => b.id !== s.bookings.happy.id));

  // Happy path
  section('Challenge (FR5.8 – FR5.12)');
  const asMember = await call('POST', '/matches/challenge', {
    token: tokMember,
    body: { challengerTeam: s.teamA.id, opponentTeam: s.teamB.id, bookingId: s.bookings.happy.id },
  });
  check('a non-captain cannot challenge', asMember.status === 403, `status=${asMember.status}`);

  const stolen = await call('POST', '/matches/challenge', {
    token: tokB,
    body: { challengerTeam: s.teamA.id, opponentTeam: s.teamB.id, bookingId: s.bookings.happy.id },
  });
  check('cannot challenge on behalf of a team you do not captain', stolen.status === 403,
    `status=${stolen.status}`);

  const created = await call('POST', '/matches/challenge', {
    token: tokA,
    body: { challengerTeam: s.teamA.id, opponentTeam: s.teamB.id, bookingId: s.bookings.happy.id },
  });
  check('challenge created', created.status === 200 && created.body?.success === true,
    JSON.stringify(created.body).slice(0, 160));
  const matchId = created.body?.data?.id;
  check('status is challenge_sent', created.body?.data?.status === 'challenge_sent');
  check('expiry is set and in the future (FR5.12)',
    Boolean(created.body?.data?.challengeExpiresAt)
      && new Date(created.body.data.challengeExpiresAt) > new Date(),
    created.body?.data?.challengeExpiresAt);

  const dup = await call('POST', '/matches/challenge', {
    token: tokA,
    body: { challengerTeam: s.teamA.id, opponentTeam: s.teamB.id, bookingId: s.bookings.happy.id },
  });
  check('a booking cannot host two live matches', dup.status === 409, `status=${dup.status}`);

  const self = await call('POST', '/matches/challenge', {
    token: tokA,
    body: { challengerTeam: s.teamA.id, opponentTeam: s.teamA.id, bookingId: s.bookings.spare.id },
  });
  check('a team cannot challenge itself', self.status === 400, `status=${self.status}`);

  section('Match Center buckets (FR5.16)');
  const listB = await call('GET', `/matches?team_id=${s.teamB.id}`, { token: tokB });
  check('challenged team sees it as incoming',
    (listB.body?.data?.challenges?.incoming || []).some((m) => m.id === matchId));
  const listA = await call('GET', `/matches?team_id=${s.teamA.id}`, { token: tokA });
  check('challenger sees it as outgoing',
    (listA.body?.data?.challenges?.outgoing || []).some((m) => m.id === matchId));
  check('dispute window is published to the client (FR5.17)',
    Number(listA.body?.data?.disputeWindowHours) > 0, `${listA.body?.data?.disputeWindowHours}h`);

  section('Respond (FE-4)');
  const wrongResponder = await call('PATCH', `/matches/${matchId}/respond`, {
    token: tokA, body: { action: 'accept' },
  });
  check('the challenger cannot accept their own challenge', wrongResponder.status === 403,
    `status=${wrongResponder.status}`);

  const accepted = await call('PATCH', `/matches/${matchId}/respond`, {
    token: tokB, body: { action: 'accept' },
  });
  check('opponent captain accepts', accepted.status === 200 && accepted.body?.data?.status === 'accepted',
    JSON.stringify(accepted.body).slice(0, 140));

  const reAccept = await call('PATCH', `/matches/${matchId}/respond`, {
    token: tokB, body: { action: 'reject' },
  });
  check('cannot answer twice', reAccept.status === 409, `status=${reAccept.status}`);

  section('Result submission (ER2.1)');
  const tooEarly = await call('POST', `/matches/${matchId}/result`, {
    token: tokA, body: { scoreChallenger: 3, scoreOpponent: 1 },
  });
  check('cannot submit before the slot starts', tooEarly.status === 409, `status=${tooEarly.status}`);

  // The slot is now "played".
  const c1 = await pool.connect();
  try { await pushBookingIntoPast(c1, s.bookings.happy.id); } finally { c1.release(); }

  const badScore = await call('POST', `/matches/${matchId}/result`, {
    token: tokA, body: { scoreChallenger: '3abc', scoreOpponent: 1 },
  });
  check('a non-numeric score is rejected, not coerced', badScore.status === 400,
    `status=${badScore.status}`);

  const mismatchPicker = await call('POST', `/matches/${matchId}/result`, {
    token: tokA, body: { scoreChallenger: 3, scoreOpponent: 1, winnerTeam: s.teamB.id },
  });
  check('winner must agree with the score', mismatchPicker.status === 400,
    `status=${mismatchPicker.status}`);

  const memberResult = await call('POST', `/matches/${matchId}/result`, {
    token: tokMember, body: { scoreChallenger: 3, scoreOpponent: 1 },
  });
  check('a non-captain cannot submit a result', memberResult.status === 403,
    `status=${memberResult.status}`);

  const r1 = await call('POST', `/matches/${matchId}/result`, {
    token: tokA, body: { scoreChallenger: 3, scoreOpponent: 1, winnerTeam: s.teamA.id },
  });
  check('first submission accepted, still waiting',
    r1.status === 200 && r1.body?.data?.outcome === 'waiting',
    `${r1.status} ${r1.body?.data?.outcome}`);

  const r1again = await call('POST', `/matches/${matchId}/result`, {
    token: tokA, body: { scoreChallenger: 3, scoreOpponent: 1 },
  });
  check('the same team cannot submit twice', r1again.status === 409, `status=${r1again.status}`);

  const r2 = await call('POST', `/matches/${matchId}/result`, {
    token: tokB, body: { scoreChallenger: 3, scoreOpponent: 1 },
  });
  check('agreeing second submission moves it to awaiting_owner',
    r2.status === 200 && r2.body?.data?.status === 'awaiting_owner',
    `${r2.status} ${r2.body?.data?.status}`);
  check('results are frozen once both are in (ER2.1)', r2.body?.data?.resultsLocked === true);

  section('Owner verification (ER2.2)');
  const pending = await call('GET', '/matches/owner/pending', { token: tokOwner });
  const mine = (pending.body?.data || []).find((m) => m.id === matchId);
  check('match appears in the owner queue', Boolean(mine),
    `queue=${(pending.body?.data || []).length}`);
  check('the owner sees BOTH submissions', (mine?.submissions || []).length === 2,
    `submissions=${(mine?.submissions || []).length}`);

  if (tokOther) {
    const otherQueue = await call('GET', '/matches/owner/pending', { token: tokOther });
    check('a different owner does not see this match',
      (otherQueue.body?.data || []).every((m) => m.id !== matchId));
    const otherVerify = await call('PATCH', `/matches/${matchId}/verify`, { token: tokOther });
    check('a different owner cannot verify it', otherVerify.status === 403,
      `status=${otherVerify.status}`);
  }

  const captainVerify = await call('PATCH', `/matches/${matchId}/verify`, { token: tokA });
  check('a captain cannot verify their own match', captainVerify.status === 403,
    `status=${captainVerify.status}`);

  const verified = await call('PATCH', `/matches/${matchId}/verify`, { token: tokOwner });
  check('owner verifies', verified.status === 200 && verified.body?.data?.status === 'completed',
    JSON.stringify(verified.body?.message || verified.body).slice(0, 140));

  const ex = verified.body?.data?.elo;
  check('winner gained points', Number(ex?.challenger?.delta) > 0, `delta=${ex?.challenger?.delta}`);
  check('the exchange is zero-sum',
    Number(ex?.challenger?.delta) === -Number(ex?.opponent?.delta),
    `${ex?.challenger?.delta} vs ${ex?.opponent?.delta}`);
  check('even ratings + a win means exactly +K/2',
    Number(ex?.challenger?.delta) === 16, `delta=${ex?.challenger?.delta} k=${ex?.kFactor}`);

  const reVerify = await call('PATCH', `/matches/${matchId}/verify`, { token: tokOwner });
  check('verification is idempotent (no double rating)', reVerify.status === 409,
    `status=${reVerify.status}`);

  section('Ledger and history');
  const c2 = await pool.connect();
  try {
    const hist = await c2.query(
      'SELECT team_id, elo_before, elo_after, elo_delta, k_factor, reason FROM elo_history WHERE match_id = $1 ORDER BY elo_delta DESC',
      [matchId],
    );
    check('exactly two elo_history rows were written', hist.rows.length === 2,
      `rows=${hist.rows.length}`);
    check('history deltas net to zero',
      hist.rows.length === 2 && hist.rows.reduce((a, r) => a + Number(r.elo_delta), 0) === 0);
    check('reason is recorded',
      hist.rows.length === 2 && hist.rows.every((r) => r.reason === 'match_verified'));

    const teams = await c2.query(
      'SELECT id, elo, elo_rating, wins, losses, draws FROM teams WHERE id = ANY($1::uuid[])',
      [[s.teamA.id, s.teamB.id]],
    );
    const ta = teams.rows.find((t) => t.id === s.teamA.id);
    const tb = teams.rows.find((t) => t.id === s.teamB.id);
    check('winner rating stored', Number(ta.elo) === 1016, `elo=${ta.elo}`);
    check('loser rating stored', Number(tb.elo) === 984, `elo=${tb.elo}`);
    check('legacy elo_rating kept in lockstep', Number(ta.elo_rating) === Number(ta.elo),
      `${ta.elo_rating} vs ${ta.elo}`);
    check('W/L counters moved', Number(ta.wins) === 1 && Number(tb.losses) === 1,
      `A wins=${ta.wins} B losses=${tb.losses}`);
  } finally { c2.release(); }

  const histA = await call('GET', `/matches?team_id=${s.teamA.id}`, { token: tokA });
  const done = (histA.body?.data?.history || []).find((m) => m.id === matchId);
  check('completed match appears in History with its ±ELO delta (FR5.16)',
    done?.challenger?.eloDelta === 16, `delta=${done?.challenger?.eloDelta}`);
  check('both teams now read as ranked (FR2.6)',
    done?.challenger?.ranked === true && done?.opponent?.ranked === true);

  section('Dispute inside the 24h window (FR5.17)');
  const badReason = await call('POST', `/matches/${matchId}/dispute`, {
    token: tokB, body: { reason: 'no' },
  });
  check('a too-short reason is rejected', badReason.status === 400, `status=${badReason.status}`);

  const disputed = await call('POST', `/matches/${matchId}/dispute`, {
    token: tokB,
    body: { reason: 'The final score was 2-1, not 3-1. The last goal was after the whistle.' },
  });
  check('captain can dispute a fresh result',
    disputed.status === 200 && disputed.body?.data?.status === 'disputed',
    `${disputed.status} ${disputed.body?.data?.status}`);

  const disputeAgain = await call('POST', `/matches/${matchId}/dispute`, {
    token: tokB, body: { reason: 'Filing this a second time to check the unique constraint.' },
  });
  check('one dispute per team per match', disputeAgain.status === 409, `status=${disputeAgain.status}`);

  // Conflict path
  section('Conflicting results (ER2.1 → disputed)');
  const m2 = await call('POST', '/matches/challenge', {
    token: tokA,
    body: { challengerTeam: s.teamA.id, opponentTeam: s.teamB.id, bookingId: s.bookings.conflict.id },
  });
  const id2 = m2.body?.data?.id;
  check('second challenge created', m2.status === 200 && Boolean(id2), `status=${m2.status}`);
  await call('PATCH', `/matches/${id2}/respond`, { token: tokB, body: { action: 'accept' } });
  const c3 = await pool.connect();
  try { await pushBookingIntoPast(c3, s.bookings.conflict.id); } finally { c3.release(); }

  await call('POST', `/matches/${id2}/result`, {
    token: tokA, body: { scoreChallenger: 4, scoreOpponent: 0 },
  });
  const conflict = await call('POST', `/matches/${id2}/result`, {
    token: tokB, body: { scoreChallenger: 0, scoreOpponent: 4 },
  });
  check('disagreeing submissions produce a dispute',
    conflict.status === 200 && conflict.body?.data?.status === 'disputed',
    `${conflict.status} ${conflict.body?.data?.status}`);

  const verifyDisputed = await call('PATCH', `/matches/${id2}/verify`, { token: tokOwner });
  check('a disputed match cannot be rated — the S.7 backstop', verifyDisputed.status === 409,
    `status=${verifyDisputed.status}`);

  const c4 = await pool.connect();
  try {
    const d = await c4.query(
      'SELECT raised_by_team, status FROM disputes WHERE match_id = $1', [id2],
    );
    check('the conflict logs a SYSTEM dispute', d.rows.length === 1, `rows=${d.rows.length}`);
    check('raised_by_team is NULL so ER2.3 counts it against neither team',
      d.rows[0]?.raised_by_team === null, `raised_by=${d.rows[0]?.raised_by_team}`);
    const eh = await c4.query('SELECT count(*)::int n FROM elo_history WHERE match_id = $1', [id2]);
    check('no rating was written for the disputed match', eh.rows[0].n === 0, `rows=${eh.rows[0].n}`);
  } finally { c4.release(); }

  // Expiry sweep
  section('48h expiry sweep (FR5.12)');
  const m3 = await call('POST', '/matches/challenge', {
    token: tokA,
    body: { challengerTeam: s.teamA.id, opponentTeam: s.teamB.id, bookingId: s.bookings.spare.id },
  });
  const id3 = m3.body?.data?.id;
  check('third challenge created', Boolean(id3), `status=${m3.status}`);
  const c5 = await pool.connect();
  try {
    await c5.query(
      "UPDATE matches SET challenge_expires_at = now() - interval '1 minute' WHERE id = $1", [id3],
    );
  } finally { c5.release(); }

  const staleList = await call('GET', `/matches?team_id=${s.teamB.id}`, { token: tokB });
  check('an expired-but-unswept challenge is not offered as accept-able',
    (staleList.body?.data?.challenges?.incoming || []).every((m) => m.id !== id3));

  const lateAccept = await call('PATCH', `/matches/${id3}/respond`, {
    token: tokB, body: { action: 'accept' },
  });
  check('accepting after expiry is refused', lateAccept.status === 409, `status=${lateAccept.status}`);

  const { processExpiredChallenges } = require('./src/jobs/matchExpiryJob');
  await processExpiredChallenges();
  const c6 = await pool.connect();
  try {
    const st = await c6.query('SELECT status FROM matches WHERE id = $1', [id3]);
    check('the sweep settles it as expired', st.rows[0]?.status === 'expired',
      `status=${st.rows[0]?.status}`);
    const released = await c6.query(
      `SELECT count(*)::int n FROM matches
        WHERE booking_id = $1 AND status = ANY($2::text[])`,
      [s.bookings.spare.id, require('./src/utils/matchCore').LIVE_STATUSES],
    );
    check('the booking is released for reuse', released.rows[0].n === 0, `live=${released.rows[0].n}`);
  } finally { c6.release(); }

  const reuse = await call('POST', '/matches/challenge', {
    token: tokA,
    body: { challengerTeam: s.teamA.id, opponentTeam: s.teamB.id, bookingId: s.bookings.spare.id },
  });
  check('the freed slot can be challenged again', reuse.status === 200, `status=${reuse.status}`);

  // Leave a usable fixture
  // The run ends by design with disputes filed and — once it has been run a few
  // times — E2E Titans frozen by ER2.3. Both are proven above, but leaving them
  // in place would mean the manual two-phone test starts with a team whose rating
  // cannot move, and that looks like a bug rather than a passed assertion.
  const c7 = await pool.connect();
  try {
    await c7.query(
      `DELETE FROM disputes
        WHERE raised_by_team = ANY($1::uuid[])
           OR match_id IN (SELECT id FROM matches
                            WHERE challenger_team = ANY($1::uuid[])
                               OR opponent_team = ANY($1::uuid[]))`,
      [[s.teamA.id, s.teamB.id]],
    );
    await c7.query(
      `UPDATE teams SET elo_frozen = FALSE, elo_frozen_reason = NULL, elo_frozen_at = NULL
        WHERE id = ANY($1::uuid[])`,
      [[s.teamA.id, s.teamB.id]],
    );
  } finally { c7.release(); }

  // Summary
  console.log(`\n${'═'.repeat(68)}`);
  const passed = results.length - failed;
  console.log(`  ${passed}/${results.length} checks passed`);
  if (failed) {
    console.log('\n  Failures:');
    for (const r of results.filter((x) => x.ok === 'FAIL')) {
      console.log(`   ❌ ${r.label}  ${r.detail}`);
    }
  }
  console.log(`${'═'.repeat(68)}\n`);
  console.log('Fixture left behind for the two-phone test (ratings unfrozen):');
  console.log(`  ${s.teamA.name}  — log in as ${s.captainA.name} (captain)`);
  console.log(`  ${s.teamB.name}  — log in as ${s.captainB.name} (captain)`);
  console.log(`  Owner account    — ${s.owner.name} (owns ${s.venue.name})\n`);

  await pool.end();
  process.exit(failed ? 1 : 0);
}

main().catch(async (e) => {
  console.error('\n❌ Harness crashed:', e.message);
  console.error(e.stack);
  await pool.end().catch(() => {});
  process.exit(1);
});
