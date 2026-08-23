/**
 * Match lifecycle plumbing  —  S.2 Wave C
 *
 * routes/matches.js owns the HTTP layer: parse, authorise, decide, answer. This
 * module owns everything that layer needs more than once — loading a match with
 * both teams attached, finding who a team's captains are, posting the chat pills,
 * shaping a row for the app, and the ER2.3 freeze check.
 *
 * WHY A SEPARATE FILE
 * Six endpoints plus a background sweep all need the same loads and the same
 * fan-out. Inlining them would put the state machine and the SQL in one file
 * where neither is readable, and the fan-out in particular has to be identical
 * everywhere: a "match accepted" pill worded or targeted differently from a
 * "match verified" pill is how a chat thread starts contradicting itself.
 *
 * THREE RULES THIS FILE ENFORCES
 *
 *   1. NOTHING HERE OPENS A TRANSACTION. Every function takes an already-open
 *      client and participates in the caller's transaction, for the same reason
 *      utils/elo.js does: a chat pill that committed separately could survive a
 *      rolled-back verification, leaving the thread claiming a result the
 *      matches table never recorded.
 *
 *   2. SIDE EFFECTS CANNOT FAIL THE MATCH. Chat pills go through a SAVEPOINT,
 *      mirroring utils/notify.js. A missing channel or a chat hiccup must never
 *      be the reason a result that two captains agreed on and an owner verified
 *      gets rolled back. The result is the durable fact; the pill is a courtesy.
 *
 *   3. LOCK THE MATCH ROW ALONE. lockMatch() deliberately does not join teams,
 *      because `FOR UPDATE` across a join locks the joined rows too, in whatever
 *      order the planner chose. utils/elo.lockBothTeams() takes the team locks
 *      afterwards in sorted id order; letting a join take them first would
 *      reintroduce exactly the A-B/B-A deadlock that sorting exists to prevent.
 */

const pool = require('../db/pool');
const bus = require('../realtime/bus');
const chat = require('./chatCore');
const { buildSystemMessage } = require('./chatSystemMessages');
const { notify } = require('./notify');
const elo = require('./elo');
const { PREVIEW_LABEL, buildPreview } = require('./matchPreview');

// ─── The state machine, as data ─────────────────────────────────────────────
//
// doc/API.md holds the authoritative diagram; chk_matches_status (migration 016)
// holds the same vocabulary in the database. This is the third copy and it is
// the one the code branches on, so it must agree with both.
//
//   challenge_sent ─(accept)──→ accepted ─(both results agree)──→ awaiting_owner
//         │                        │                                    │
//         │(reject / 48h)          │(results conflict)                  │(owner verifies)
//         ↓                        ↓                                    ↓
//   rejected | expired          disputed ←─(dispute within 24h)──── completed
//
const STATUS = Object.freeze({
  CHALLENGE_SENT: 'challenge_sent',
  ACCEPTED: 'accepted',
  REJECTED: 'rejected',
  EXPIRED: 'expired',
  AWAITING_RESULTS: 'awaiting_results',
  AWAITING_OWNER: 'awaiting_owner',
  COMPLETED: 'completed',
  DISPUTED: 'disputed',
});

/**
 * The statuses that hold a booking. Must match ux_matches_booking_live exactly:
 * if this list and the index disagree, either the pre-check rejects a challenge
 * the database would have accepted, or it waves one through to a raw 23505.
 */
const LIVE_STATUSES = Object.freeze([
  STATUS.CHALLENGE_SENT, STATUS.ACCEPTED, STATUS.AWAITING_RESULTS,
  STATUS.AWAITING_OWNER, STATUS.COMPLETED, STATUS.DISPUTED,
]);

/** Nothing further can happen to a match in one of these. */
const CLOSED_STATUSES = Object.freeze([STATUS.REJECTED, STATUS.EXPIRED]);

/** Slot dates/times are PKT wall-clock values (same convention as escrow.js). */
const TIMEZONE = 'Asia/Karachi';

// ─── Loads ──────────────────────────────────────────────────────────────────

/**
 * Lock one match row for the duration of a state transition.
 *
 * Every write in this flow is a state machine step, and a step is only safe if
 * concurrent writers are serialised: two captains submitting the last result at
 * the same instant would otherwise both read `count = 1`, both decide they are
 * not the second submitter, and both leave the match in `accepted` with two
 * results sitting in it and nobody to move it forward.
 */
async function lockMatch(client, matchId) {
  const { rows } = await client.query(
    `SELECT id, challenger_team, opponent_team, booking_id, sport, status,
            challenge_expires_at, winner_team, score_challenger, score_opponent,
            competitiveness, preview_text, elo_applied, results_locked,
            created_by, responded_at, verified_by, verified_at, created_at
       FROM matches WHERE id = $1 FOR UPDATE`,
    [matchId],
  );
  return rows[0] || null;
}

/**
 * Everything the app renders for a match: both teams, the linked slot, the venue
 * and its owner, and the ELO deltas the History tab shows (FR5.16).
 *
 * The two delta sub-selects read elo_history rather than recomputing from the
 * ratings, because the ratings have moved on since. A team that has played ten
 * matches since this one cannot have its delta for this one derived from its
 * current rating — the ledger row is the only place that number still exists.
 */
const MATCH_VIEW_COLUMNS = `
  m.id, m.challenger_team, m.opponent_team, m.booking_id, m.sport, m.status,
  m.challenge_expires_at, m.winner_team, m.score_challenger, m.score_opponent,
  m.competitiveness, m.preview_text, m.elo_applied, m.results_locked,
  m.created_by, m.responded_at, m.verified_by, m.verified_at, m.created_at,
  ct.name AS ct_name, ct.logo_url AS ct_logo, ct.elo AS ct_elo,
  ct.wins AS ct_wins, ct.losses AS ct_losses, ct.draws AS ct_draws,
  ct.elo_frozen AS ct_frozen, ct.city AS ct_city,
  ot.name AS ot_name, ot.logo_url AS ot_logo, ot.elo AS ot_elo,
  ot.wins AS ot_wins, ot.losses AS ot_losses, ot.draws AS ot_draws,
  ot.elo_frozen AS ot_frozen, ot.city AS ot_city,
  b.slot_date, b.start_time, b.end_time, b.status::text AS booking_status,
  b.player_id AS booking_player,
  v.id AS venue_id, v.name AS venue_name, v.city AS venue_city,
  v.owner_id AS venue_owner,
  ((b.slot_date::DATE + b.start_time::TIME) <= (NOW() AT TIME ZONE '${TIMEZONE}')) AS slot_started,
  (SELECT eh.elo_delta FROM elo_history eh
    WHERE eh.match_id = m.id AND eh.team_id = m.challenger_team LIMIT 1) AS ct_delta,
  (SELECT eh.elo_delta FROM elo_history eh
    WHERE eh.match_id = m.id AND eh.team_id = m.opponent_team LIMIT 1) AS ot_delta,
  (SELECT count(*)::int FROM match_results mr WHERE mr.match_id = m.id) AS results_in,
  -- Which teams have submitted, so shapeMatch can tell the VIEWER whether it was
  -- them. The count alone cannot: at results_in = 1 a captain has either already
  -- had their one shot (ER2.1) or is the one still owed, and offering "Submit
  -- result" to the first of those is offering a button that can only 409.
  (SELECT array_agg(mr.submitted_by_team::text)
     FROM match_results mr WHERE mr.match_id = m.id) AS submitted_teams`;

const MATCH_VIEW_FROM = `
  FROM matches m
  JOIN teams ct ON ct.id = m.challenger_team
  JOIN teams ot ON ot.id = m.opponent_team
  LEFT JOIN bookings b ON b.id = m.booking_id
  LEFT JOIN venues   v ON v.id = b.venue_id`;

function intOrNull(v) {
  if (v === null || v === undefined) return null;
  const n = typeof v === 'number' ? v : Number.parseInt(String(v), 10);
  return Number.isFinite(n) ? n : null;
}

function int0(v) {
  return intOrNull(v) ?? 0;
}

/** One side of a match, as the app wants it. `p` is 'challenger' | 'opponent'. */
function shapeSide(row, p, base) {
  const k = p === 'challenger' ? 'ct' : 'ot';
  const stats = {
    wins: int0(row[`${k}_wins`]),
    losses: int0(row[`${k}_losses`]),
    draws: int0(row[`${k}_draws`]),
  };
  const ranked = elo.isRanked(stats);
  const rating = int0(row[`${k}_elo`]) || base;
  return {
    id: p === 'challenger' ? row.challenger_team : row.opponent_team,
    name: row[`${k}_name`],
    logoUrl: row[`${k}_logo`] || null,
    city: row[`${k}_city`] || null,
    elo: rating,
    // FR2.6 — the app must be able to print "Unranked" without inferring it from
    // a rating that looks like a real one.
    ranked,
    displayElo: ranked ? rating : null,
    played: stats.wins + stats.losses + stats.draws,
    ...stats,
    eloFrozen: row[`${k}_frozen`] === true,
    eloDelta: intOrNull(row[`${k}_delta`]),
  };
}

/**
 * Turn a MATCH_VIEW row into the JSON the Flutter model reads.
 *
 * Nested rather than flat, and camelCase rather than the raw snake_case rows the
 * older endpoints return. A match is genuinely two teams plus a booking, and a
 * flat row would make the client re-derive that structure by string-prefix from
 * `ct_name`/`ot_name` — a parsing step that exists only because the wire format
 * refused to say what it meant.
 *
 * `viewerTeamIds` lets one payload serve both sides: the app needs to know which
 * side is "us" to colour the scoreline and to decide whether Accept is even a
 * button, and computing that here means neither screen has to.
 */
function shapeMatch(row, { viewerTeamIds = [], viewerUserId = null, base = 1000 } = {}) {
  const mine = new Set((viewerTeamIds || []).map(String));
  const challenger = shapeSide(row, 'challenger', base);
  const opponent = shapeSide(row, 'opponent', base);
  const myTeamId = mine.has(String(challenger.id)) ? challenger.id
    : (mine.has(String(opponent.id)) ? opponent.id : null);

  return {
    id: row.id,
    status: row.status,
    sport: row.sport,
    challenger,
    opponent,
    competitiveness: intOrNull(row.competitiveness),
    previewText: row.preview_text || null,
    // Shipped with the payload so no screen can relabel this a prediction.
    previewLabel: PREVIEW_LABEL,
    challengeExpiresAt: row.challenge_expires_at,
    winnerTeam: row.winner_team || null,
    isDraw: row.status === STATUS.COMPLETED && row.winner_team === null,
    scoreChallenger: intOrNull(row.score_challenger),
    scoreOpponent: intOrNull(row.score_opponent),
    eloApplied: row.elo_applied === true,
    resultsLocked: row.results_locked === true,
    resultsIn: int0(row.results_in),
    respondedAt: row.responded_at,
    verifiedAt: row.verified_at,
    verifiedBy: row.verified_by || null,
    createdAt: row.created_at,
    createdBy: row.created_by || null,
    slotStarted: row.slot_started === true,
    booking: row.booking_id ? {
      id: row.booking_id,
      slotDate: row.slot_date,
      startTime: row.start_time,
      endTime: row.end_time,
      status: row.booking_status,
      venueId: row.venue_id || null,
      venueName: row.venue_name || null,
      venueCity: row.venue_city || null,
    } : null,
    // Viewer-relative facts, so the screens do not each re-derive them.
    myTeamId,
    iAmChallenger: myTeamId !== null && String(myTeamId) === String(challenger.id),
    // Has MY team already had its one submission? Never leaks the opponent's —
    // only whether the viewer's own side is still owed one.
    iSubmitted: myTeamId !== null
      && (row.submitted_teams || []).map(String).includes(String(myTeamId)),
    iAmVenueOwner: viewerUserId !== null && row.venue_owner !== null
      && String(row.venue_owner) === String(viewerUserId),
  };
}

/** One match, hydrated. Read-only, so it takes a client OR the pool. */
async function fetchMatchView(clientOrPool, matchId) {
  const { rows } = await (clientOrPool || pool).query(
    `SELECT ${MATCH_VIEW_COLUMNS} ${MATCH_VIEW_FROM} WHERE m.id = $1`,
    [matchId],
  );
  return rows[0] || null;
}

// ─── Who is who ─────────────────────────────────────────────────────────────

/**
 * The caller's role in a team, or null. Read inside the caller's transaction so
 * a demotion cannot slip between the check and the write it authorises.
 *
 * team_members.role is the authority for captaincy, NOT teams.captain_id: FR2.10
 * allows more than one captain, and captain_id can only ever name one of them.
 */
async function roleInTeam(client, teamId, userId) {
  const { rows } = await client.query(
    'SELECT role FROM team_members WHERE team_id = $1 AND user_id = $2',
    [teamId, userId],
  );
  return rows[0]?.role || null;
}

/** Which of these teams the caller belongs to — the basis for every read gate. */
async function myTeamsAmong(client, teamIds, userId) {
  const ids = (teamIds || []).filter(Boolean);
  if (!ids.length) return [];
  const { rows } = await client.query(
    `SELECT team_id, role FROM team_members
      WHERE user_id = $1 AND team_id = ANY($2::uuid[])`,
    [userId, ids],
  );
  return rows;
}

/**
 * Captains of each of these teams, as teamId → [userId].
 *
 * Notifications go to captains rather than the whole roster for the actionable
 * moments (a challenge to answer, a result to submit): only a captain can act on
 * them, so alerting twenty members produces nineteen dead ends. The chat pill is
 * what tells everyone else.
 */
async function captainIdsOf(client, teamIds) {
  const ids = (teamIds || []).filter(Boolean);
  const out = new Map(ids.map((id) => [String(id), []]));
  if (!ids.length) return out;
  const { rows } = await client.query(
    `SELECT team_id, user_id FROM team_members
      WHERE team_id = ANY($1::uuid[]) AND role = 'captain'`,
    [ids],
  );
  for (const r of rows) out.get(String(r.team_id))?.push(r.user_id);
  return out;
}

/** Every member of these teams, deduped — the socket fan-out list. */
async function memberIdsOf(client, teamIds) {
  const ids = (teamIds || []).filter(Boolean);
  if (!ids.length) return [];
  const { rows } = await client.query(
    'SELECT DISTINCT user_id FROM team_members WHERE team_id = ANY($1::uuid[])',
    [ids],
  );
  return rows.map((r) => r.user_id);
}

/** teamId → chat channel id, for the pills. Teams created before chat exist. */
async function channelIdsOf(client, teamIds) {
  const ids = (teamIds || []).filter(Boolean);
  const out = new Map();
  if (!ids.length) return out;
  const { rows } = await client.query(
    `SELECT ref_id, id FROM chat_channels
      WHERE type = 'team' AND ref_id = ANY($1::uuid[])`,
    [ids],
  );
  for (const r of rows) out.set(String(r.ref_id), r.id);
  return out;
}

// ─── Features and the derived numbers ───────────────────────────────────────

/**
 * Ratings, records, last-5 form and roster trust for a set of teams, in one round
 * trip.
 *
 * The LATERAL is worth the density: form is "the outcome of your five most
 * recent completed matches, most recent first", which is a per-team ordered
 * window. Doing it per team in JS would be N+1 queries on the challenge screen,
 * which is opened far more often than a challenge is actually sent.
 *
 * Trust (FR5.5) is the roster AVERAGE, not the captain's own score. A team is the
 * people who turn up: judging it by one account would let a captain with a clean
 * record front a squad that no-shows, and would also punish a good squad whose
 * captain took one no-show penalty. COALESCE to 100 because a team whose members
 * have no player_profiles row yet has not earned distrust — 100 is the column
 * default, i.e. the score every new player starts from.
 */
async function teamFeatures(client, teamIds) {
  const ids = (teamIds || []).filter(Boolean);
  if (!ids.length) return new Map();
  const { rows } = await client.query(
    `SELECT t.id, t.name, t.logo_url, t.city, t.sport::text AS sport, t.visibility,
            t.elo, t.wins, t.losses, t.draws, t.elo_frozen, t.captain_id,
            COALESCE(f.form, '') AS form,
            COALESCE(tr.trust, 100) AS trust_score,
            COALESCE(tr.members, 0) AS member_count
       FROM teams t
       LEFT JOIN LATERAL (
         SELECT string_agg(
                  CASE WHEN r.winner_team IS NULL THEN 'D'
                       WHEN r.winner_team = t.id  THEN 'W'
                       ELSE 'L' END, '' ORDER BY r.ord) AS form
           FROM (
             SELECT winner_team,
                    row_number() OVER (ORDER BY COALESCE(verified_at, created_at) DESC) AS ord
               FROM matches
              WHERE status = '${STATUS.COMPLETED}'
                AND (challenger_team = t.id OR opponent_team = t.id)
              ORDER BY COALESCE(verified_at, created_at) DESC
              LIMIT 5
           ) r
       ) f ON TRUE
       LEFT JOIN LATERAL (
         SELECT round(avg(pp.trust_score))::int AS trust,
                count(*)::int AS members
           FROM team_members m
           LEFT JOIN player_profiles pp ON pp.user_id = m.user_id
          WHERE m.team_id = t.id
       ) tr ON TRUE
      WHERE t.id = ANY($1::uuid[])`,
    [ids],
  );
  const out = new Map();
  for (const r of rows) {
    out.set(String(r.id), {
      id: r.id,
      name: r.name,
      logoUrl: r.logo_url || null,
      city: r.city || null,
      sport: r.sport,
      visibility: r.visibility,
      captainId: r.captain_id || null,
      elo: int0(r.elo),
      wins: int0(r.wins),
      losses: int0(r.losses),
      draws: int0(r.draws),
      eloFrozen: r.elo_frozen === true,
      form: r.form || '',
      trustScore: intOrNull(r.trust_score) ?? 100,
      memberCount: int0(r.member_count),
    });
  }
  return out;
}

/**
 * FR5.5 — the trust badge, banded once so every screen agrees.
 *
 * Banded on the server rather than in Dart because the opponent list, the
 * challenge screen and the match centre all draw this badge; three independent
 * threshold ladders would eventually disagree, and a team shown as "Trusted" on
 * one screen and "Mixed" on the next is worse than no badge at all.
 *
 * The raw number ships alongside the band — the badge is the honest summary, but
 * a captain deciding who to play deserves to see the actual score.
 */
const TRUST_BANDS = Object.freeze([
  { min: 90, band: 'excellent', label: 'Highly trusted' },
  { min: 75, band: 'good', label: 'Trusted' },
  { min: 50, band: 'fair', label: 'Mixed record' },
  { min: 0, band: 'low', label: 'Low trust' },
]);

function trustBadge(score) {
  const n = Math.max(0, Math.min(100, intOrNull(score) ?? 100));
  const hit = TRUST_BANDS.find((b) => n >= b.min) || TRUST_BANDS[TRUST_BANDS.length - 1];
  return { trustScore: n, trustBand: hit.band, trustLabel: hit.label };
}

/**
 * The two numbers a challenge is created with: competitiveness (FR5.4) and the
 * preview sentence (FR5.10).
 *
 * Both are SNAPSHOTS and are stored on the row. They describe the two teams as
 * they were when the challenge was sent; recomputing them later from current
 * ratings would silently rewrite the challenge card after the fact, so that a
 * card a captain is looking at changes while they read it.
 */
function deriveCompAndPreview({ challenger, opponent, seed }) {
  const competitiveness = elo.competitivenessFor(challenger, opponent);
  const previewText = buildPreview({
    challenger: {
      name: challenger.name, elo: challenger.elo,
      wins: challenger.wins, losses: challenger.losses, draws: challenger.draws,
      form: challenger.form,
    },
    opponent: {
      name: opponent.name, elo: opponent.elo,
      wins: opponent.wins, losses: opponent.losses, draws: opponent.draws,
      form: opponent.form,
    },
    competitiveness,
    seed,
  });
  return { competitiveness, previewText };
}

// ─── Side effects ───────────────────────────────────────────────────────────

/**
 * Post a grey pill into a team's chat, and return the message id so the caller
 * can emit it AFTER COMMIT.
 *
 * SAVEPOINT-wrapped for the reason in the file header: a team whose channel row
 * is missing (created before chat existed, or hand-deleted) must not be able to
 * fail a verified match result. Returns null when it could not post, and the
 * caller simply has nothing to emit.
 */
async function announceToTeam(client, channelId, event, opts) {
  if (!channelId) return null;
  await client.query('SAVEPOINT sl_match_pill');
  try {
    const { message } = await chat.postSystemMessage(
      client, channelId, buildSystemMessage(event, opts),
    );
    await client.query('RELEASE SAVEPOINT sl_match_pill');
    return message.id;
  } catch (e) {
    await client.query('ROLLBACK TO SAVEPOINT sl_match_pill');
    console.warn(`[match] chat pill (${event}) skipped:`, e.message);
    return null;
  }
}

/**
 * Fan a lifecycle change out to both teams at once: a pill in each team's chat,
 * a notification row per captain, and the list of member ids to socket-ping
 * after commit.
 *
 * `sides` is one entry per team, each carrying the wording FOR THAT TEAM. The
 * two teams genuinely need different sentences — "you challenged them" and "they
 * challenged you" are different facts — and passing both in explicitly is what
 * keeps that asymmetry visible at the call site instead of hidden in a flag.
 *
 * Returns `{ pills: [{channelId, messageId}], memberIds }`. Nothing is emitted
 * here: emitting inside the transaction would tell a client to re-fetch a row
 * that is not committed yet, and it would read the old one.
 */
async function fanOut(client, { matchId, sides }) {
  const teamIds = sides.map((s) => s.teamId);
  const [channels, captains, memberIds] = await Promise.all([
    channelIdsOf(client, teamIds),
    captainIdsOf(client, teamIds),
    memberIdsOf(client, teamIds),
  ]);

  const pills = [];
  for (const side of sides) {
    const channelId = channels.get(String(side.teamId)) || null;
    if (side.event) {
      const messageId = await announceToTeam(client, channelId, side.event, {
        actorId: side.actorId || null,
        actorName: side.actorName || null,
        value: side.otherTeamName || null,
        matchId,
        detail: side.detail || null,
      });
      if (messageId) pills.push({ channelId, messageId });
    }
    if (side.notify) {
      const recipients = side.notifyAll
        ? await memberIdsOf(client, [side.teamId])
        : (captains.get(String(side.teamId)) || []);
      for (const userId of recipients) {
        await notify(client, {
          userId,
          type: side.notify.type,
          title: side.notify.title,
          body: side.notify.body || null,
          payload: { matchId, teamId: side.teamId, ...(side.notify.extra || {}) },
        });
      }
    }
  }
  return { pills, memberIds };
}

/**
 * Emit everything a completed transition should tell the apps about. Called
 * strictly AFTER COMMIT.
 *
 * `match:update` carries only ids — the client re-fetches. Pushing the whole
 * match down a socket would mean two code paths producing the payload the
 * screens render, and they would drift.
 */
async function emitAfterCommit(client, { matchId, pills, memberIds, extra = {} }) {
  for (const p of pills || []) {
    await chat.emitPersistedMessage(client, p.channelId, p.messageId).catch(() => {});
  }
  if (memberIds && memberIds.length) {
    bus.emitToUsers(memberIds, 'match:update', { matchId, ...extra });
  }
}

// ─── ER2.3 — platform-wide ELO freeze ───────────────────────────────────────

/**
 * A team that disputes more than 30% of its matches (minimum 3) gets its ELO
 * frozen platform-wide.
 *
 * WHY THE RATIO AND NOT A FLAT COUNT
 * A team that has played fifty matches and disputed four is arguing about 8% of
 * its results, which is plausible. A team that has played four and disputed
 * three is using the dispute button as a way to refuse every loss. A flat count
 * punishes the first and a flat ratio punishes a team whose first ever match
 * genuinely went wrong, which is why ER2.3 has both a ratio and a floor.
 *
 * WHY ONLY DISPUTES THE TEAM ITSELF RAISED
 * `raised_by_team` is the filter. A conflict between two submitted results
 * creates a system dispute with `raised_by_team = NULL`, and it must not count
 * against either side: neither of them filed it, and an honest team on the wrong
 * end of an opponent's mis-typed scoreline would otherwise be frozen for it.
 *
 * Idempotent — a team already frozen is left alone, so the reason and timestamp
 * keep pointing at the moment the threshold was actually crossed.
 */
async function applyDisputeFreeze(client, teamId, { ratio, min }) {
  const { rows } = await client.query(
    `SELECT
       (SELECT count(*)::int FROM disputes d WHERE d.raised_by_team = $1) AS disputed,
       (SELECT count(*)::int FROM matches m
         WHERE (m.challenger_team = $1 OR m.opponent_team = $1)
           AND m.status IN ('${STATUS.COMPLETED}', '${STATUS.DISPUTED}')) AS played,
       (SELECT elo_frozen FROM teams WHERE id = $1) AS already`,
    [teamId],
  );
  const { disputed, played, already } = rows[0] || {};
  if (already === true) return { frozen: true, changed: false, disputed, played };
  if (!disputed || disputed < min || !played) {
    return { frozen: false, changed: false, disputed, played };
  }
  if (disputed / played <= ratio) return { frozen: false, changed: false, disputed, played };

  const reason = `Disputed ${disputed} of ${played} matches (over ${Math.round(ratio * 100)}%).`;
  await client.query(
    `UPDATE teams
        SET elo_frozen = TRUE, elo_frozen_reason = $2, elo_frozen_at = NOW()
      WHERE id = $1 AND elo_frozen = FALSE`,
    [teamId, reason],
  );
  return { frozen: true, changed: true, disputed, played, reason };
}

// ─── Small shared formatting ────────────────────────────────────────────────

/** "+16" / "-16" / "0" — the string the ER2.2 notification puts in its body. */
function signed(n) {
  const v = intOrNull(n) ?? 0;
  return v > 0 ? `+${v}` : String(v);
}

/** "3 – 1", or "no score" when a submission somehow lacks one. */
function scoreline(a, b) {
  const x = intOrNull(a);
  const y = intOrNull(b);
  return x === null || y === null ? 'no score' : `${x} – ${y}`;
}

module.exports = {
  STATUS,
  LIVE_STATUSES,
  CLOSED_STATUSES,
  TIMEZONE,
  MATCH_VIEW_COLUMNS,
  MATCH_VIEW_FROM,
  lockMatch,
  fetchMatchView,
  shapeMatch,
  roleInTeam,
  myTeamsAmong,
  captainIdsOf,
  memberIdsOf,
  channelIdsOf,
  teamFeatures,
  trustBadge,
  deriveCompAndPreview,
  announceToTeam,
  fanOut,
  emitAfterCommit,
  applyDisputeFreeze,
  signed,
  scoreline,
  intOrNull,
  int0,
};
