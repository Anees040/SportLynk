/**
 * userService.js — the public face of a player's account (profile visibility).
 *
 * The app has always shown a player only their OWN profile. This service answers the
 * other question: "who is this other player?" — the read behind a tappable name in
 * the request inbox, the discovery list and a team roster. It is the honest companion
 * to requestService: every field is a real column, nothing is invented when a value
 * is missing, and a private account yields only what must stay public to be useful.
 *
 * The visibility contract (an Instagram-style rule)
 *   • public  — the full profile: name, avatar, trust, ELO, sports, bio, the teams
 *               the player belongs to (with each team's record), and recent activity.
 *   • private — only name, avatar, trust and ELO. The sports, bio, teams and activity
 *               are withheld entirely (absent from the payload, not nulled), so a
 *               private player's details cannot leak through a field the client
 *               forgot to hide. A player viewing THEMSELVES always sees the full
 *               profile regardless of the flag — `isSelf` carries that.
 *
 * Shape, like requestService: every function takes a db handle (pool or an open
 * client) and returns `{ ok, status, code, message, data }` rather than writing to
 * `res`, so the route stays thin and the branches are testable without a connection.
 */
const access = require('../utils/teamAccess');

// Bookings that count as activity — the same two statuses requestService and the
// recommender treat as real. `status::text = ANY(...)` because bookings.status is an
// ENUM. A public profile's "active this month" is this count, never a fabricated one.
const BOOKED_STATUSES = ['confirmed', 'checked_in'];

const err = (status, code, message) => ({ ok: false, status, code, message, data: null });

/**
 * The profile of `targetId` as seen by `viewerId`.
 *
 * 404 for a non-uuid id, a missing user, or a non-player (owners and admins have no
 * public profile). Otherwise 200 with the always-public header, plus the full detail
 * when the profile is public or the viewer is its owner.
 */
async function publicProfile(client, { viewerId, targetId }) {
  if (!access.isUuid(targetId)) return err(404, 'not_found', 'Player not found.');

  const base = await client.query(
    `SELECT u.id, u.name, u.avatar_url, u.created_at, u.role,
            COALESCE(pp.is_public, true) AS is_public,
            pp.bio,
            COALESCE(pp.sport_preferences, '{}') AS sport_preferences,
            COALESCE(pp.elo_rating, 1000) AS elo_rating,
            pp.trust_score
       FROM users u
       LEFT JOIN player_profiles pp ON pp.user_id = u.id
      WHERE u.id = $1`,
    [targetId],
  );
  const row = base.rows[0];
  if (!row || row.role !== 'player') return err(404, 'not_found', 'Player not found.');

  const isSelf = String(viewerId) === String(targetId);
  const isPublic = row.is_public !== false;

  // The header every viewer sees, private or not. ELO carries its documented 1000
  // seed; trust stays nullable so an unrated account reads "not rated yet" rather
  // than a fabricated score.
  const header = {
    id: String(row.id),
    name: row.name,
    avatarUrl: row.avatar_url || null,
    isPublic,
    isSelf,
    trustScore: row.trust_score === null || row.trust_score === undefined ? null : Number(row.trust_score),
    eloRating: Math.round(Number(row.elo_rating)),
    memberSince: row.created_at,
  };

  // A private profile viewed by anyone but its owner stops at the header. The detail
  // keys are omitted, not set to null, so there is nothing to leak.
  if (!isPublic && !isSelf) {
    return { ok: true, status: 200, code: null, message: null, data: header };
  }

  const [teamsRes, activityRes] = await Promise.all([
    client.query(
      `SELECT t.id, t.name, t.sport::text AS sport, t.logo_url, tm.role,
              t.elo, t.wins, t.losses, t.draws
         FROM team_members tm
         JOIN teams t ON t.id = tm.team_id
        WHERE tm.user_id = $1 AND t.disbanded_at IS NULL
        ORDER BY t.created_at DESC`,
      [targetId],
    ),
    client.query(
      `SELECT count(*)::int AS n
         FROM bookings b
        WHERE b.player_id = $1
          AND b.status::text = ANY($2::text[])
          AND b.created_at >= now() - interval '30 days'`,
      [targetId, BOOKED_STATUSES],
    ),
  ]);

  const teams = teamsRes.rows.map((t) => ({
    id: String(t.id),
    name: t.name,
    sport: t.sport,
    logoUrl: t.logo_url || null,
    role: t.role,
    elo: t.elo === null || t.elo === undefined ? null : Number(t.elo),
    wins: Number(t.wins || 0),
    losses: Number(t.losses || 0),
    draws: Number(t.draws || 0),
  }));

  return {
    ok: true,
    status: 200,
    code: null,
    message: null,
    data: {
      ...header,
      bio: row.bio || null,
      sports: Array.isArray(row.sport_preferences) ? row.sport_preferences : [],
      bookings30d: Number(activityRes.rows[0]?.n || 0),
      teams,
    },
  };
}

module.exports = { publicProfile, BOOKED_STATUSES };
