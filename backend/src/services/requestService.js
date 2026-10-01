/**
 * requestService.js — direct player-to-player "let's play" requests (module 8c).
 *
 * The gap this fills
 * Team↔team pairing already exists as the challenge flow, and it is a COMMITMENT:
 * it needs a booking, a slot and both captains. What SportLynk had no path for was
 * the INTRODUCTION — one player finding another and asking to play — and the private
 * thread the two of them use once the other agrees. This service owns that ask and
 * its small state machine; the room it opens is an ordinary `direct` chat channel
 * (chatCore.ensureDirectChannel), so once created it sends, reads and notifies
 * through exactly the same machinery every other chat type does.
 *
 * The shape mirrors routes/teams.js's request handling on purpose: every function
 * takes an OPEN transaction `client`, returns `{ ok, status, code, message, data }`
 * rather than writing to `res`, and never opens or commits anything itself — the
 * thin route owns the transaction and the post-commit socket emits.
 *
 * Notifications
 *   • create  → the target is pinged `play_request` (NORMAL: a social ask, not a
 *               deadline). Tapping it opens the request inbox.
 *   • accept  → the requester is pinged `play_request_accepted`, carrying the new
 *               channel so the tap lands straight in the room.
 *   • decline → silent. Telling someone they were turned down is a needless sting;
 *               the requester sees the state change in their own outgoing list.
 */
const access = require('../utils/teamAccess');
const chat = require('../utils/chatCore');
const { notify } = require('../utils/notify');

// Bookings that count as activity, the same two statuses rosterService and the reco
// export treat as real. `status::text = ANY(...)` because bookings.status is an ENUM.
const BOOKED_STATUSES = ['confirmed', 'checked_in'];

// How long a pending ask stays live before it reads as stale. A fortnight is long
// enough that a slow reply is not lost and short enough that a dormant ask does not
// sit in an inbox for a season. Nothing sweeps this yet; expires_at is advisory and
// the UI can grey a past-due row — the column is here so that sweep needs no schema.
const REQUEST_TTL_DAYS = 14;

const err = (status, code, message) => ({ ok: false, status, code, message, data: null });

// One request row → the camelCase card the inbox renders. `other_*` is the OTHER
// party as the calling side sees it (the requester on an incoming row, the target on
// an outgoing one), resolved by the query's join so the same shape serves both tabs.
// Kept in one place so incoming() and outgoing() cannot drift.
const mapRow = (r) => ({
  id: String(r.id),
  sport: r.sport,
  message: r.message,
  status: r.status,
  channelId: r.channel_id ? String(r.channel_id) : null,
  createdAt: r.created_at,
  decidedAt: r.decided_at,
  expiresAt: r.expires_at,
  otherUserId: r.other_user_id ? String(r.other_user_id) : null,
  otherName: r.other_name || null,
  otherAvatar: r.other_avatar || null,
  trustScore: r.trust_score,
});


/**
 * Create a request from `requesterId` to `targetUserId`.
 *
 * The target must be an active player and not the requester. A second pending ask in
 * the same direction is blocked by ux_play_requests_pending (23505) and returned as a
 * friendly 409 rather than a duplicate row.
 */
async function createRequest(client, { requesterId, targetUserId, sport = null, message = null }) {
  if (!access.isUuid(targetUserId)) return err(404, 'not_found', 'Player not found.');
  if (String(requesterId) === String(targetUserId)) {
    return err(400, 'self', 'You cannot send a request to yourself.');
  }

  const people = await client.query(
    'SELECT id, name, role, is_active FROM users WHERE id = ANY($1::uuid[])',
    [[requesterId, targetUserId]],
  );
  const requester = people.rows.find((r) => String(r.id) === String(requesterId));
  const target = people.rows.find((r) => String(r.id) === String(targetUserId));
  if (!target || target.role !== 'player' || target.is_active !== true) {
    return err(404, 'not_found', 'Player not found.');
  }

  const note = typeof message === 'string' && message.trim() ? message.trim().slice(0, 500) : null;
  const sportVal = typeof sport === 'string' && sport.trim() ? sport.trim() : null;

  let row;
  try {
    const ins = await client.query(
      `INSERT INTO play_requests
         (requester_user_id, target_user_id, sport, message, expires_at)
       VALUES ($1, $2, $3, $4, now() + ($5 || ' days')::interval)
       RETURNING *`,
      [requesterId, targetUserId, sportVal, note, String(REQUEST_TTL_DAYS)],
    );
    row = ins.rows[0];
  } catch (e) {
    if (e.code === '23505') {
      return err(409, 'duplicate', 'You already have a pending request to this player.');
    }
    throw e;
  }

  const requesterName = (requester && requester.name) || 'A player';
  await notify(client, {
    userId: targetUserId,
    type: 'play_request',
    title: requesterName,
    body: note || `wants to play${sportVal ? ` ${sportVal}` : ''}`,
    payload: { requestId: row.id, requesterId, sport: sportVal },
    actorId: requesterId,
  });

  return {
    ok: true,
    status: 201,
    code: null,
    message: null,
    data: {
      id: String(row.id),
      status: row.status,
      sport: row.sport,
      message: row.message,
      createdAt: row.created_at,
      expiresAt: row.expires_at,
      otherUserId: String(targetUserId),
    },
  };
}

/**
 * Requests sent TO this user. Each row carries the requester's public card (name,
 * avatar, trust) so the inbox renders without a second round trip. `status` filters
 * when given; null returns every state, newest first, so a history tab and a pending
 * tab are the same query with a different argument.
 */
async function incoming(client, userId, { status = null } = {}) {
  const { rows } = await client.query(
    `SELECT pr.id, pr.sport, pr.message, pr.status, pr.channel_id,
            pr.created_at, pr.decided_at, pr.expires_at,
            pr.requester_user_id AS other_user_id,
            u.name AS other_name, u.avatar_url AS other_avatar,
            pp.trust_score
       FROM play_requests pr
       JOIN users u ON u.id = pr.requester_user_id
       LEFT JOIN player_profiles pp ON pp.user_id = pr.requester_user_id
      WHERE pr.target_user_id = $1
        AND ($2::text IS NULL OR pr.status = $2)
      ORDER BY pr.created_at DESC
      LIMIT 100`,
    [userId, status],
  );
  return { ok: true, status: 200, code: null, message: null, data: rows.map(mapRow) };
}

/**
 * Requests this user SENT. Symmetric to incoming(); the card is the target's, and the
 * outgoing list is where a requester sees a decline (which sends no notification).
 */
async function outgoing(client, userId, { status = null } = {}) {
  const { rows } = await client.query(
    `SELECT pr.id, pr.sport, pr.message, pr.status, pr.channel_id,
            pr.created_at, pr.decided_at, pr.expires_at,
            pr.target_user_id AS other_user_id,
            u.name AS other_name, u.avatar_url AS other_avatar,
            pp.trust_score
       FROM play_requests pr
       JOIN users u ON u.id = pr.target_user_id
       LEFT JOIN player_profiles pp ON pp.user_id = pr.target_user_id
      WHERE pr.requester_user_id = $1
        AND ($2::text IS NULL OR pr.status = $2)
      ORDER BY pr.created_at DESC
      LIMIT 100`,
    [userId, status],
  );
  return { ok: true, status: 200, code: null, message: null, data: rows.map(mapRow) };
}

/**
 * Accept or decline a pending request addressed to `userId`.
 *
 * The transition is the guard: the UPDATE only fires on a row that is this user's and
 * still `pending`, so a request that was already decided, cancelled, expired or never
 * theirs updates zero rows and returns 409 — one check covers not-found, not-yours and
 * a double tap. On accept the two are wired into a `direct` room (idempotent, so a
 * retried accept reuses the same channel), the request records the channel it opened,
 * an opening pill is posted, and the requester is pinged with the channel so the tap
 * lands in the room. The returned `pill` lets the route emit that system message over
 * the socket after it commits, exactly as the booking/captain rooms do.
 */
async function respond(client, { id, userId, action }) {
  if (!access.isUuid(id)) return err(404, 'not_found', 'Request not found.');
  if (action !== 'accept' && action !== 'decline') {
    return err(400, 'bad_action', 'Action must be accept or decline.');
  }
  const next = action === 'accept' ? 'accepted' : 'declined';

  const upd = await client.query(
    `UPDATE play_requests SET status = $3, decided_at = now()
      WHERE id = $1 AND target_user_id = $2 AND status = 'pending'
      RETURNING requester_user_id, target_user_id, sport`,
    [id, userId, next],
  );
  if (!upd.rows[0]) {
    return err(409, 'not_pending', 'This request is no longer pending.');
  }
  const { requester_user_id: requesterId } = upd.rows[0];

  if (action === 'decline') {
    return { ok: true, status: 200, code: null, message: null, data: { status: 'declined', channelId: null } };
  }

  const channelId = await chat.ensureDirectChannel(client, requesterId, userId);
  await client.query('UPDATE play_requests SET channel_id = $2 WHERE id = $1', [id, channelId]);

  // The acceptor's name titles the requester's notification and their view of the room
  // (a DM row is titled by the other person). One lookup serves both.
  const who = await client.query('SELECT name FROM users WHERE id = $1', [userId]);
  const accepterName = (who.rows[0] && who.rows[0].name) || 'A player';

  const pill = await chat.postSystemMessage(client, channelId, {
    body: 'You are now connected. Say hello.',
    meta: { kind: 'direct_opened' },
  });

  await notify(client, {
    userId: requesterId,
    type: 'play_request_accepted',
    title: accepterName,
    body: 'accepted your request. Say hello.',
    payload: { requestId: id, channelId, channelType: 'direct', channelTitle: accepterName },
    actorId: userId,
  });

  return {
    ok: true,
    status: 200,
    code: null,
    message: null,
    data: { status: 'accepted', channelId },
    pill: pill && pill.message ? { channelId, messageId: pill.message.id } : null,
  };
}

/**
 * The requester withdraws their own still-pending ask. Same transition guard as
 * respond(): only a pending row owned by this requester moves to `cancelled`.
 */
async function cancel(client, { id, userId }) {
  if (!access.isUuid(id)) return err(404, 'not_found', 'Request not found.');
  const upd = await client.query(
    `UPDATE play_requests SET status = 'cancelled', decided_at = now()
      WHERE id = $1 AND requester_user_id = $2 AND status = 'pending'
      RETURNING id`,
    [id, userId],
  );
  if (!upd.rows[0]) return err(409, 'not_pending', 'This request is no longer pending.');
  return { ok: true, status: 200, code: null, message: null, data: { status: 'cancelled' } };
}

/**
 * Players this user could ask to play — the discovery list behind the Players tab.
 *
 * Honest by construction: every row is a real active player account, and every number
 * on it is read from the tables that own it. `bookings_30d` is that player's recent
 * confirmed/checked-in bookings (the same activity signal rosterService uses),
 * `trust_score` is their profile's, and `plays_sport` is whether the requested sport
 * is in their stated preferences. Nothing is invented; a player with an unfilled
 * profile simply has an empty sport list and a null trust, which the UI renders as
 * "not set" rather than a fabricated default.
 *
 * A sport is a soft SORT, not a filter: an empty preferences list is an unfilled
 * profile, not a refusal to play, so matching players lead but the rest still appear —
 * the same choice suggestPlayers makes. `pending_request` flags anyone this user has
 * already asked, so the tab shows "Requested" (disabled) instead of hiding them and
 * letting a duplicate ask hit the 409. Self and non-players are excluded in SQL.
 *
 * No ML here on purpose: this is the plain, un-gated "find any player" list, whereas
 * rosterService.suggestPlayers ranks candidates FOR A TEAM and is admin+team gated.
 */
async function discoverPlayers(client, { userId, sport = null, limit = 40 } = {}) {
  const lim = Math.min(Math.max(Number(limit) || 40, 1), 60);
  const sportVal = typeof sport === 'string' && sport.trim() ? sport.trim() : null;

  const { rows } = await client.query(
    `SELECT u.id AS user_id, u.name, u.avatar_url,
            COALESCE(pp.sport_preferences, '{}') AS sports,
            pp.trust_score,
            COALESCE(act.n, 0)::int AS bookings_30d,
            ($2::text IS NOT NULL
             AND $2 = ANY(COALESCE(pp.sport_preferences, '{}'))) AS plays_sport,
            EXISTS (SELECT 1 FROM play_requests pr
                     WHERE pr.requester_user_id = $1 AND pr.target_user_id = u.id
                       AND pr.status = 'pending') AS pending_request
       FROM users u
       JOIN player_profiles pp ON pp.user_id = u.id
       LEFT JOIN LATERAL (
         SELECT count(*) AS n FROM bookings b
          WHERE b.player_id = u.id
            AND b.status::text = ANY($3::text[])
            AND b.created_at >= now() - interval '30 days'
       ) act ON TRUE
      WHERE u.role = 'player' AND u.is_active = true AND u.id <> $1
      ORDER BY plays_sport DESC, bookings_30d DESC, u.name ASC
      LIMIT $4`,
    [userId, sportVal, BOOKED_STATUSES, lim],
  );

  const data = rows.map((r) => ({
    userId: String(r.user_id),
    name: r.name,
    avatarUrl: r.avatar_url,
    sports: Array.isArray(r.sports) ? r.sports : [],
    trustScore: r.trust_score,
    bookings30d: Number(r.bookings_30d || 0),
    playsSport: !!r.plays_sport,
    pendingRequest: !!r.pending_request,
  }));
  return { ok: true, status: 200, code: null, message: null, data };
}

module.exports = {
  createRequest, incoming, outgoing, respond, cancel, discoverPlayers,
  REQUEST_TTL_DAYS,
};
