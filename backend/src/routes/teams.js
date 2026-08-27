/**
 * Teams API (S2 Wave A) — create, browse, roster, invites, join requests, roles.
 *
 * Every mutating handler follows the same transaction shape as routes/wallet.js:
 *   pool.connect() → BEGIN → work → COMMIT, and a `finally` that ALWAYS releases.
 * The two rules that shape this file:
 *
 *   1. A `return` may never leave an open transaction behind. `finally` releases
 *      the client, and a client released mid-transaction is handed to the next
 *      caller still inside a BEGIN — a cross-request corruption bug. So every
 *      early exit rolls back first (see `bail`).
 *
 *   2. Membership is authority. The caller's role is re-read from team_members
 *      inside the same locked transaction as the write it authorises
 *      (access.requireRole → lockTeam FOR UPDATE), so a forged `{"role":...}` in
 *      the body is never trusted and two writers cannot race the "≥1 captain"
 *      invariant (FR2.10).
 *
 * Side effects on a membership change are threefold and fire only AFTER COMMIT,
 * so a client that reacts to a socket event by re-fetching always sees the
 * committed row:
 *   • a grey system message in the team chat ("Ali added Sara")   → everyone
 *   • a notifications row + `team:update` socket ping             → the person
 *   • a `chat:message` socket event for the system line           → the channel
 */

const express = require('express');
const crypto = require('crypto');
const pool = require('../db/pool');
const auth = require('../middleware/authMiddleware');
const access = require('../utils/teamAccess');
const stats = require('../utils/teamStats');
const mc = require('../utils/matchCore');
const elo = require('../utils/elo');
const ml = require('../services/mlClient');
const chat = require('../utils/chatCore');
const { buildSystemMessage } = require('../utils/chatSystemMessages');
const { notify } = require('../utils/notify');
const bus = require('../realtime/bus');

const router = express.Router();
router.use(auth);

// ─── Envelope helpers ───────────────────────────────────────────────────────
const fail = (res, status, message) => res.status(status).json({ success: false, message });
const ok = (res, data, message) => res.json({ success: true, data, ...(message ? { message } : {}) });

/** Roll back, then answer — the only safe way to leave an open transaction. */
async function bail(client, res, status, message) {
  await client.query('ROLLBACK').catch(() => {});
  return fail(res, status, message);
}

/** Turn the two DB errors we expect into friendly envelopes; rethrow the rest. */
function friendlyDbError(e) {
  if (e.code === '23505') return { status: 409, message: 'A team with that name already exists for this sport.' };
  if (e.code === '22P02') return { status: 404, message: 'Not found.' }; // bad uuid slipped through
  return null;
}

/** One name lookup per request, reused for every system-message sentence. */
async function nameOf(client, userId) {
  if (!userId) return null;
  const { rows } = await client.query('SELECT name FROM users WHERE id = $1', [userId]);
  return rows[0]?.name || null;
}

/**
 * Post a grey system message to the team channel AND remember to emit it after
 * commit. Returns the message id so the caller can flush emits post-COMMIT.
 */
async function announce(client, channelId, event, opts) {
  const { message } = await chat.postSystemMessage(client, channelId, buildSystemMessage(event, opts));
  return message.id;
}

// ═══════════════════════════════════════════════════════════════════════════
// CREATE
// ═══════════════════════════════════════════════════════════════════════════
router.post('/', async (req, res, next) => {
  const name = access.validateTeamName(req.body.name);
  const sport = access.validateSport(req.body.sport);
  const bio = access.validateBio(req.body.bio);
  const visibility = access.validateVisibility(req.body.visibility);
  const logo = access.validateMediaUrl(req.body.logo ?? req.body.logoUrl, { label: 'Logo' });
  const invalid = [name, sport, bio, visibility, logo].find((x) => !x.ok);
  if (invalid) return fail(res, 400, invalid.message);

  const client = await pool.connect();
  try {
    // Cap teams per user so one account cannot flood the platform (teamAccess).
    const mine = await client.query(
      'SELECT count(*)::int AS n FROM team_members WHERE user_id = $1', [req.user.id],
    );
    if (mine.rows[0].n >= access.MAX_TEAMS_PER_USER) {
      // No transaction open yet — `finally` does the single release.
      return fail(res, 429, `You can be in at most ${access.MAX_TEAMS_PER_USER} teams.`);
    }

    await client.query('BEGIN');
    const { rows } = await client.query(
      `INSERT INTO teams (name, sport, visibility, bio, logo_url, captain_id)
       VALUES ($1,$2,$3,$4,$5,$6)
       RETURNING ${access.TEAM_COLUMNS.replace(/t\./g, '')}`,
      [name.value, sport.value, visibility.value, bio.value, logo.value, req.user.id],
    );
    const team = rows[0];
    await client.query(
      `INSERT INTO team_members (team_id, user_id, role) VALUES ($1,$2,'captain')`,
      [team.id, req.user.id],
    );
    const channelId = await chat.ensureTeamChannel(client, team);
    await chat.syncTeamMember(client, channelId, req.user.id, 'captain');
    const actorName = await nameOf(client, req.user.id);
    const sysId = await announce(client, channelId, 'group_created', {
      actorId: req.user.id, actorName,
    });
    await client.query('COMMIT');

    await chat.emitPersistedMessage(client, channelId, sysId);
    bus.emitToUsers(req.user.id, 'team:update', { teamId: team.id });
    return ok(res, { ...team, role: 'captain', channelId }, 'Team created.');
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    const f = friendlyDbError(e);
    return f ? fail(res, f.status, f.message) : next(e);
  } finally {
    client.release();
  }
});

// ═══════════════════════════════════════════════════════════════════════════
// LISTS  (declared before /:id so the literal segments win the route match)
// ═══════════════════════════════════════════════════════════════════════════

/** Teams the caller belongs to, newest first, each tagged with their role. */
router.get('/mine', async (req, res, next) => {
  try {
    const { rows } = await pool.query(
      `SELECT ${access.TEAM_COLUMNS}, tm.role,
              (SELECT c.id FROM chat_channels c
                WHERE c.type = 'team' AND c.ref_id = t.id) AS channel_id
         FROM teams t
         JOIN team_members tm ON tm.team_id = t.id
        WHERE tm.user_id = $1
        ORDER BY t.created_at DESC`,
      [req.user.id],
    );
    return ok(res, rows);
  } catch (e) { next(e); }
});

/**
 * Public leaderboard (FR2.7 / FR5.13) — S2 Wave D.
 *
 * Three things changed here in Wave D, and each one closed a real hole:
 *
 *   • RANKED ONLY. This used to list every public team ordered by elo, which put
 *     brand-new teams on the board at the seed 1000 — the exact thing FR2.6 says
 *     never to display as a rating. utils/teamStats.js applies the same
 *     elo.isRanked() threshold the match screens use, so a fresh install now
 *     returns an EMPTY board, which is the honest answer.
 *   • ?city=. Free text, so it goes through normaliseCity() first.
 *   • MOVEMENT + is_mine. Rank change vs 7 days ago, and whether the viewer is a
 *     member. is_mine has to be computed server-side: the screen was inferring
 *     it from a `role` field this endpoint never sent, so the "YOU" highlight
 *     could never appear.
 *
 * Returns an OBJECT, not an array, because the screen needs the city chips in
 * the same round trip and the chips must be derived from the same filtered data
 * (a chip that leads to an empty list reads as a broken feature). The Dart
 * caller was updated with it.
 */
router.get('/rankings', async (req, res, next) => {
  try {
    let sport = null;
    if (req.query.sport) {
      const v = access.validateSport(req.query.sport);
      if (!v.ok) return fail(res, 400, v.message);
      sport = v.value;
    }
    const city = stats.normaliseCity(req.query.city);

    const [teams, cities] = await Promise.all([
      stats.rankings(pool, { sport, city, viewerId: req.user.id, limit: req.query.limit }),
      // Unfiltered by city on purpose — the chip row must not collapse to the
      // one chip you already picked.
      stats.rankedCities(pool, { sport }),
    ]);

    return ok(res, {
      teams,
      cities,
      sport,
      city,
      // Shipped so the empty state can say "≥1 verified match" and the movement
      // legend can say "7 days" without Dart hard-coding either number.
      rankedMinMatches: stats.RANKED_MIN,
      movementWindowDays: stats.MOVEMENT_WINDOW_DAYS,
    });
  } catch (e) { next(e); }
});

/**
 * Browse public teams to challenge (find-opponents). Excludes teams the caller
 * is already in, optional name search and sport filter.
 */
router.get('/discover', async (req, res, next) => {
  try {
    const params = [req.user.id];
    let where = `t.visibility = 'public'
      AND NOT EXISTS (SELECT 1 FROM team_members m WHERE m.team_id = t.id AND m.user_id = $1)`;
    if (req.query.sport) {
      const sport = access.validateSport(req.query.sport);
      if (!sport.ok) return fail(res, 400, sport.message);
      params.push(sport.value);
      where += ` AND t.sport = $${params.length}`;
    }
    const q = access.squash(req.query.q || '');
    if (q) {
      params.push(`%${q}%`);
      where += ` AND t.name ILIKE $${params.length}`;
    }
    const { rows } = await pool.query(
      `SELECT ${access.TEAM_COLUMNS},
              (SELECT count(*)::int FROM team_members m WHERE m.team_id = t.id) AS member_count
         FROM teams t WHERE ${where}
        ORDER BY t.elo DESC, lower(t.name) LIMIT 60`,
      params,
    );
    return ok(res, rows);
  } catch (e) { next(e); }
});

/**
 * Preview an invite before joining — the join screen shows "Falcon FC · 6
 * members" so a stranger knows what they are accepting. 410 (not 404) for a
 * dead token, so the client can show "this invite has expired" specifically.
 */
router.get('/invites/:token', async (req, res, next) => {
  try {
    const hash = crypto.createHash('sha256').update(String(req.params.token)).digest('hex');
    const { rows } = await pool.query(
      `SELECT t.id, t.name, t.sport::text AS sport, t.logo_url, t.visibility,
              (SELECT count(*)::int FROM team_members m WHERE m.team_id = t.id) AS member_count
         FROM team_invites i JOIN teams t ON t.id = i.team_id
        WHERE i.token_hash = $1 AND i.used_at IS NULL
          AND i.revoked_at IS NULL AND i.expires_at > now()`,
      [hash],
    );
    if (!rows[0]) return fail(res, 410, 'This invite link has expired or already been used.');
    return ok(res, rows[0]);
  } catch (e) { next(e); }
});

// ═══════════════════════════════════════════════════════════════════════════
// PROFILE
// ═══════════════════════════════════════════════════════════════════════════
router.get('/:id', async (req, res, next) => {
  if (!access.isUuid(req.params.id)) return fail(res, 404, 'Team not found.');
  try {
    const team = (await pool.query(
      `SELECT ${access.TEAM_COLUMNS} FROM teams t WHERE t.id = $1`, [req.params.id],
    )).rows[0];
    if (!team) return fail(res, 404, 'Team not found.');

    const me = (await pool.query(
      'SELECT role FROM team_members WHERE team_id = $1 AND user_id = $2',
      [team.id, req.user.id],
    )).rows[0];
    // A private team's roster and bio are members-only.
    if (team.visibility === 'private' && !me) return fail(res, 403, 'This team is private.');

    const [roster, channel, snapshot, eloHistory] = await Promise.all([
      access.fetchRoster(pool, team.id),
      pool.query(`SELECT id FROM chat_channels WHERE type='team' AND ref_id=$1`, [team.id]),
      // Wave D item 5 — W/L/D, win rate (FR5.15), the last-5 form string and the
      // 30-day activity count that S.5's recommender will consume as features.
      // Read here rather than from a second endpoint because the profile screen
      // needs all of it on first paint, and a second round trip would let the
      // header render a win rate before the chart knows the team is unranked.
      stats.profileStats(pool, team.id),
      // FR5.14/FR5.16 — the last 10 terminal matches, oldest first, each point
      // carrying its own verified/disputed flag and signed ELO delta.
      stats.eloSeries(pool, team.id),
    ]);
    return ok(res, {
      ...team,
      role: me?.role || null,
      channelId: channel.rows[0]?.id || null,
      roster,
      stats: snapshot,
      eloHistory,
    });
  } catch (e) { next(e); }
});

// ═══════════════════════════════════════════════════════════════════════════
// EDIT  (captain only)
// ═══════════════════════════════════════════════════════════════════════════
router.patch('/:id', async (req, res, next) => {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const g = await access.requireRole(client, req.params.id, req.user.id, 'captain');
    if (g.error) return bail(client, res, g.error.status, g.error.message);

    const bio = access.validateBio(req.body.bio);
    const vis = access.validateVisibility(req.body.visibility, g.team.visibility);
    const logo = access.validateMediaUrl(req.body.logo ?? req.body.logoUrl, { label: 'Logo' });
    const city = access.validateCity(req.body.city);
    const invalid = [bio, vis, logo, city].find((x) => !x.ok);
    if (invalid) return bail(client, res, 400, invalid.message);

    // City is only written when the key is actually present. A bio-only patch
    // must not wipe a city set earlier, but sending city:'' must still clear it —
    // which is why this is a CASE and not the COALESCE the logo uses.
    const citySent = req.body.city !== undefined;

    const { rows } = await client.query(
      `UPDATE teams
          SET bio = $1,
              visibility = $2,
              logo_url = COALESCE($3, logo_url),
              city = CASE WHEN $4::boolean THEN $5 ELSE city END
        WHERE id = $6
        RETURNING ${access.TEAM_COLUMNS.replace(/t\./g, '')}`,
      [bio.value, vis.value, logo.value, citySent, city.value, req.params.id],
    );
    const team = rows[0];
    // Keep the chat channel's title/photo in step with the team's.
    const channelId = await chat.ensureTeamChannel(client, team);

    // A visibility flip is worth a system line; a bio tweak is not noise anyone
    // needs pinged about, so only the meaningful changes are announced.
    const actorName = await nameOf(client, req.user.id);
    const sysIds = [];
    if (vis.value !== g.team.visibility) {
      sysIds.push(await announce(client, channelId, 'visibility_changed', {
        actorId: req.user.id, actorName, value: vis.value,
      }));
    }
    if (logo.value) {
      sysIds.push(await announce(client, channelId, 'icon_changed', { actorId: req.user.id, actorName }));
    }
    await client.query('COMMIT');

    for (const id of sysIds) await chat.emitPersistedMessage(client, channelId, id);
    return ok(res, team, 'Team updated.');
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    next(e);
  } finally {
    client.release();
  }
});

// ═══════════════════════════════════════════════════════════════════════════
// SUGGESTED PLAYERS  (FR2.8, S.5 Wave B)
// ═══════════════════════════════════════════════════════════════════════════

/**
 * How far back "where this team plays" and "where this player plays" are read.
 *
 * Longer than the 30-day activity window on purpose: activity is a measure of how
 * busy someone is right now, home turf is a fact about them that changes slowly.
 * One booking last month should not move a player's neighbourhood, and a captain
 * who took August off should not have their team's location forgotten.
 */
const HOME_WINDOW_DAYS = 180;

/** Rows scored, and rows returned. The rail shows a handful; the pool is wider. */
const SUGGEST_POOL = 80;
const SUGGEST_LIMIT = 12;

/**
 * Bookings that count as real. Same two statuses the reco export uses.
 *
 * `status::text = ANY($n::text[])` and not a bare `= ANY`: bookings.status is the
 * `booking_status` ENUM, and Postgres will not compare an enum to a text array
 * without the cast. matches.status is plain text, which is why the opponent query
 * in routes/matches.js needs no cast and this one does.
 */
const BOOKED_STATUSES = ['confirmed', 'checked_in'];

/**
 * GET /api/teams/:id/suggested-players — FR2.8, the roster screen's rail.
 *
 * ADMIN ONLY, and that is a privacy decision rather than a UI one. The response
 * names other players and says how often they have been booking, so it is limited
 * to the two people who can actually act on it — the captain and vice-captain, the
 * same gate as the invite endpoints it feeds. An ordinary member browsing a list of
 * strangers' activity has no use for it and no business seeing it.
 *
 * WHAT THE CANDIDATE POOL IS, AND WHY THE SPEC'S FILTERS ARE WHERE THEY ARE
 * The wave defines the pool as "public players, same city, sport matches, not
 * already members". Three of those needed a decision, because the columns the
 * literal reading wants do not exist:
 *
 *   • "PUBLIC PLAYERS" — there is no per-player visibility flag anywhere in the
 *     schema, so this is `role='player' AND is_active=true`: the same definition of
 *     "a player account that exists" that the reco export already uses. No column
 *     was invented and none was assumed.
 *
 *   • "SAME CITY" — player_profiles has no city either. A player's city is DERIVED
 *     from the venues they actually book, which is stronger evidence than a
 *     self-typed field would have been. A player with no bookings has no derived
 *     city, and is ADMITTED rather than excluded: unknown is not "different", and a
 *     strict filter on a derived column would empty this rail of exactly the new
 *     players it is most useful for. Their zone component is then null, which the
 *     scorer treats as neutral instead of as a penalty.
 *
 *   • "SPORT MATCHES" — deliberately NOT filtered in SQL. Which spellings of a
 *     sport are the same sport is decided by one alias table, and that table lives
 *     in ml-service/app/core/reco_features.py. A LIKE clause here would be a second
 *     opinion that silently drops the player who typed "Soccer". So the pool is
 *     sport-agnostic, the scorer computes fit, and a candidate whose STATED
 *     preferences exclude this sport (fit == 0) is dropped afterwards. Players who
 *     stated nothing (fit == null) stay: an empty preferences array is an unfilled
 *     profile, not a refusal.
 *
 * The pool is capped at SUGGEST_POOL rows and ordered by recent booking activity
 * before the cap, so on a large user base the rows that fall off the end are
 * dormant accounts rather than relevant ones.
 */
router.get('/:id/suggested-players', async (req, res, next) => {
  const client = await pool.connect();
  try {
    const g = await access.requireRole(client, req.params.id, req.user.id, 'admin');
    if (g.error) { await client.query('ROLLBACK').catch(() => {}); return fail(res, g.error.status, g.error.message); }

    const teamId = g.team.id;
    const sport = g.team.sport;

    // Where this team plays: the venue its current members book most often. Teams
    // have a `city` column but no address, so without this the zone component could
    // never say more than "same city" — and 0.15 of the score would be dead weight.
    const home = await client.query(
      `SELECT v.city, v.address
         FROM bookings b
         JOIN venues v ON v.id = b.venue_id
        WHERE b.status::text = ANY($2::text[])
          AND b.created_at >= now() - ($3 || ' days')::interval
          AND b.player_id IN (SELECT user_id FROM team_members WHERE team_id = $1)
        GROUP BY v.id, v.city, v.address
        ORDER BY count(*) DESC, max(b.created_at) DESC
        LIMIT 1`,
      [teamId, BOOKED_STATUSES, String(HOME_WINDOW_DAYS)],
    );
    const teamHome = home.rows[0] || null;

    const { rows } = await client.query(
      `SELECT u.id AS user_id, u.name, u.avatar_url,
              COALESCE(pp.sport_preferences, '{}') AS sports,
              pp.trust_score,
              tm.elo AS team_elo,
              COALESCE(tm.played, 0)::int AS team_played,
              COALESCE(act.n, 0)::int AS bookings_30d,
              loc.city AS home_city,
              loc.address AS home_address
         FROM users u
         JOIN player_profiles pp ON pp.user_id = u.id
         -- The player's most-played team IN THIS SPORT, which is the one whose
         -- rating says something about how they would fit here. Ordered by matches
         -- played so a dormant second team cannot outvote their real one.
         LEFT JOIN LATERAL (
           SELECT t.elo,
                  (COALESCE(t.wins,0) + COALESCE(t.losses,0) + COALESCE(t.draws,0)) AS played
             FROM team_members m2
             JOIN teams t ON t.id = m2.team_id
            WHERE m2.user_id = u.id AND t.sport = $2
            ORDER BY (COALESCE(t.wins,0) + COALESCE(t.losses,0) + COALESCE(t.draws,0)) DESC,
                     t.elo DESC NULLS LAST
            LIMIT 1
         ) tm ON TRUE
         LEFT JOIN LATERAL (
           SELECT count(*) AS n
             FROM bookings b
            WHERE b.player_id = u.id
              AND b.status::text = ANY($3::text[])
              AND b.created_at >= now() - ($4 || ' days')::interval
         ) act ON TRUE
         LEFT JOIN LATERAL (
           SELECT v.city, v.address
             FROM bookings b
             JOIN venues v ON v.id = b.venue_id
            WHERE b.player_id = u.id
              AND b.status::text = ANY($3::text[])
              AND b.created_at >= now() - ($5 || ' days')::interval
            GROUP BY v.id, v.city, v.address
            ORDER BY count(*) DESC, max(b.created_at) DESC
            LIMIT 1
         ) loc ON TRUE
        WHERE u.role = 'player'
          AND u.is_active = true
          AND NOT EXISTS (
                SELECT 1 FROM team_members m
                 WHERE m.team_id = $1 AND m.user_id = u.id
              )
          -- Unknown city is admitted; a DIFFERENT known city is not.
          AND ($6::text IS NULL OR loc.city IS NULL OR lower(loc.city) = lower($6))
        ORDER BY COALESCE(act.n, 0) DESC, lower(u.name)
        LIMIT ${SUGGEST_POOL}`,
      [
        teamId, sport, BOOKED_STATUSES,
        String(stats.ACTIVITY_WINDOW_DAYS), String(HOME_WINDOW_DAYS),
        (teamHome && teamHome.city) || g.team.city || null,
      ],
    );

    const teamPlayed = Number(g.team.wins || 0) + Number(g.team.losses || 0) + Number(g.team.draws || 0);
    const ranked = await ml.recommendPlayers({
      teamId,
      team: {
        team_id: teamId,
        sport,
        // Address and city travel raw: zone_of() lives in reco_features.py and is
        // the only implementation of "which part of town is this". Deriving a zone
        // key here in SQL or JS would be a second one.
        city: (teamHome && teamHome.city) || g.team.city || null,
        address: (teamHome && teamHome.address) || null,
        elo: g.team.elo,
        ranked: teamPlayed >= elo.RANKED_MIN_MATCHES,
      },
      candidates: rows.map((r) => ({
        user_id: r.user_id,
        sports: Array.isArray(r.sports) ? r.sports : [],
        team_elo: r.team_elo,
        team_ranked: Number(r.team_played) >= elo.RANKED_MIN_MATCHES,
        trust_score: r.trust_score,
        bookings_30d: r.bookings_30d,
        city: r.home_city,
        address: r.home_address,
      })),
      limit: SUGGEST_LIMIT,
    });

    const byId = new Map(rows.map((r) => [String(r.user_id), r]));
    const shape = (r, hit) => ({
      userId: r.user_id,
      name: r.name,
      avatarUrl: r.avatar_url || null,
      sports: Array.isArray(r.sports) ? r.sports : [],
      bookingsLast30d: Number(r.bookings_30d) || 0,
      // Whether the zone component had anything to work with, so the UI can say
      // "no recent bookings" instead of implying the player is somewhere else.
      hasHomeArea: Boolean(r.home_city),
      ...mc.trustBadge(r.trust_score),
      matchPct: hit ? (hit.match_pct ?? null) : null,
      score: hit ? (hit.score ?? null) : null,
      components: hit ? (hit.components || null) : null,
      // Which of the two rating paths the 0.25 block used — a team rating, or trust
      // standing in for one. The breakdown row says so rather than showing a number
      // whose meaning changes per player.
      eloSource: hit ? (hit.elo_source || null) : null,
      reasons: hit && Array.isArray(hit.reasons) ? hit.reasons : [],
    });

    let suggestions;
    if (ranked.available) {
      suggestions = ranked.items
        // fit === 0 means they stated their sports and this is not one of them.
        // fit === null means they stated none — kept, and scored neutrally.
        .filter((it) => !(it.components && it.components.fit === 0))
        .map((it) => {
          const row = byId.get(String(it.user_id));
          return row ? shape(row, it) : null;
        })
        .filter(Boolean)
        .slice(0, SUGGEST_LIMIT);
    } else {
      // FALLBACK: the pool in recent-activity order, with NO percentages — the same
      // rule the venue recommender's heuristic path follows (mlClient's header: a
      // fallback never carries a fabricated match_pct). The rail still works, and it
      // shows no number rather than a made-up one.
      //
      // Its sport test is an EXACT case-insensitive match, because the alias table is
      // in the service that is currently unreachable. So while ranking is down this
      // list may omit a player who typed "Soccer" for a football team. Stated as a
      // known degradation rather than hidden: `ranking.fallbackNote` says the list is
      // unranked, and the omission is recoverable by a refresh once the service is up.
      const wanted = String(sport || '').trim().toLowerCase();
      suggestions = rows
        .filter((r) => {
          const list = Array.isArray(r.sports) ? r.sports : [];
          if (!list.length) return true;
          return list.some((s) => String(s || '').trim().toLowerCase() === wanted);
        })
        .slice(0, SUGGEST_LIMIT)
        .map((r) => shape(r, null));
    }

    return ok(res, {
      team: { id: teamId, sport, city: g.team.city || null, homeCity: (teamHome && teamHome.city) || null },
      ranking: {
        source: ranked.source,
        available: ranked.available,
        specVersion: ranked.rankSpecVersion,
        specFingerprint: ranked.rankSpecFingerprint,
        weights: ranked.weights,
        componentOrder: ranked.componentOrder,
        considered: ranked.available ? ranked.considered : rows.length,
        activityWindowDays: stats.ACTIVITY_WINDOW_DAYS,
        fallbackNote: ranked.available
          ? null
          : 'Listed by recent activity — the ranking service is unavailable, so no match score is shown',
      },
      suggestions,
    });
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    const f = friendlyDbError(e);
    return f ? fail(res, f.status, f.message) : next(e);
  } finally {
    client.release();
  }
});

// ═══════════════════════════════════════════════════════════════════════════
// INVITES  (admin = captain or vice-captain)
// ═══════════════════════════════════════════════════════════════════════════

/** Mint a single-use invite. The RAW token is returned exactly once, never stored. */
router.post('/:id/invites', async (req, res, next) => {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const g = await access.requireRole(client, req.params.id, req.user.id, 'admin');
    if (g.error) return bail(client, res, g.error.status, g.error.message);

    const live = await client.query(
      `SELECT count(*)::int AS n FROM team_invites
        WHERE team_id = $1 AND used_at IS NULL AND revoked_at IS NULL AND expires_at > now()`,
      [req.params.id],
    );
    if (live.rows[0].n >= access.MAX_LIVE_INVITES) {
      return bail(client, res, 429, 'This team already has the maximum number of active invites.');
    }

    const token = crypto.randomBytes(32).toString('base64url');
    const tokenHash = crypto.createHash('sha256').update(token).digest('hex');
    const { rows } = await client.query(
      `INSERT INTO team_invites (team_id, token_hash, token_prefix, created_by, expires_at, note)
       VALUES ($1,$2,$3,$4, now() + ($5 || ' hours')::interval, $6)
       RETURNING id, expires_at, token_prefix`,
      [req.params.id, tokenHash, token.slice(0, 8), req.user.id, String(access.INVITE_TTL_HOURS),
        access.squash(req.body.note || '') || null],
    );
    await client.query('COMMIT');
    return ok(res, {
      ...rows[0],
      token,
      link: `sportlynk://team/join/${token}`,
    }, 'Invite created.');
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    next(e);
  } finally {
    client.release();
  }
});

/** Live invites for the captain's pending list — labelled by prefix, never the token. */
router.get('/:id/invites', async (req, res, next) => {
  const client = await pool.connect();
  try {
    const g = await access.requireRole(client, req.params.id, req.user.id, 'admin');
    if (g.error) { await client.query('ROLLBACK').catch(() => {}); return fail(res, g.error.status, g.error.message); }
    const { rows } = await client.query(
      `SELECT i.id, i.token_prefix, i.note, i.created_at, i.expires_at, u.name AS created_by_name
         FROM team_invites i LEFT JOIN users u ON u.id = i.created_by
        WHERE i.team_id = $1 AND i.used_at IS NULL AND i.revoked_at IS NULL AND i.expires_at > now()
        ORDER BY i.created_at DESC`,
      [req.params.id],
    );
    return ok(res, rows);
  } catch (e) { next(e); } finally { client.release(); }
});

/** Revoke a live invite. */
router.delete('/:id/invites/:iid', async (req, res, next) => {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const g = await access.requireRole(client, req.params.id, req.user.id, 'admin');
    if (g.error) return bail(client, res, g.error.status, g.error.message);
    const r = await client.query(
      `UPDATE team_invites SET revoked_at = now()
        WHERE id = $1 AND team_id = $2 AND used_at IS NULL AND revoked_at IS NULL`,
      [req.params.iid, req.params.id],
    );
    await client.query('COMMIT');
    if (!r.rowCount) return fail(res, 404, 'Invite not found.');
    return ok(res, { revoked: true });
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    next(e);
  } finally { client.release(); }
});

// ═══════════════════════════════════════════════════════════════════════════
// JOIN via token
// ═══════════════════════════════════════════════════════════════════════════
router.post('/join/:token', async (req, res, next) => {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const hash = crypto.createHash('sha256').update(String(req.params.token)).digest('hex');
    // Alias every column we need — a bare `i.*, t.*` lets the team's `id`
    // overwrite the invite's `id`, which silently broke single-use before.
    const { rows } = await client.query(
      `SELECT i.id AS invite_id, i.created_by AS inviter_id,
              t.id AS team_id, t.name, t.sport::text AS sport, t.logo_url, t.captain_id
         FROM team_invites i JOIN teams t ON t.id = i.team_id
        WHERE i.token_hash = $1 AND i.used_at IS NULL
          AND i.revoked_at IS NULL AND i.expires_at > now()
        FOR UPDATE OF i`,
      [hash],
    );
    const inv = rows[0];
    if (!inv) return bail(client, res, 410, 'This invite link has expired or already been used.');

    const already = await client.query(
      'SELECT 1 FROM team_members WHERE team_id = $1 AND user_id = $2',
      [inv.team_id, req.user.id],
    );
    if (already.rowCount) {
      // Idempotent: burn the token, report success, do not double-announce.
      await client.query('UPDATE team_invites SET used_at = now(), used_by = $1 WHERE id = $2',
        [req.user.id, inv.invite_id]);
      await client.query('COMMIT');
      return ok(res, { teamId: inv.team_id, alreadyMember: true }, 'You are already in this team.');
    }

    const size = await access.countMembers(client, inv.team_id);
    if (size >= access.MAX_TEAM_SIZE) {
      return bail(client, res, 409, 'This team is already full.');
    }

    await client.query(
      `INSERT INTO team_members (team_id, user_id, role, invited_by) VALUES ($1,$2,'member',$3)`,
      [inv.team_id, req.user.id, inv.inviter_id],
    );
    await client.query('UPDATE team_invites SET used_at = now(), used_by = $1 WHERE id = $2',
      [req.user.id, inv.invite_id]);

    // `inv` aliases the team id as `team_id`; ensureTeamChannel reads `.id`.
    const channelId = await chat.ensureTeamChannel(client, {
      id: inv.team_id, name: inv.name, logo_url: inv.logo_url, captain_id: inv.captain_id,
    });
    await chat.syncTeamMember(client, channelId, req.user.id, 'member');
    const joinerName = await nameOf(client, req.user.id);
    const sysId = await announce(client, channelId, 'member_joined_link', {
      targetId: req.user.id, targetName: joinerName,
    });

    // Tell the existing admins someone walked in the door.
    const admins = (await client.query(
      `SELECT user_id FROM team_members WHERE team_id = $1 AND role IN ('captain','vice_captain')`,
      [inv.team_id],
    )).rows.map((r) => r.user_id);
    for (const uid of admins) {
      await notify(client, {
        userId: uid, type: 'team_join',
        title: inv.name, body: `${joinerName} joined the team.`,
      });
    }
    await client.query('COMMIT');

    await chat.emitPersistedMessage(client, channelId, sysId);
    bus.emitToUsers([req.user.id, ...admins], 'team:update', { teamId: inv.team_id });
    return ok(res, { teamId: inv.team_id, channelId }, `Welcome to ${inv.name}!`);
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    next(e);
  } finally { client.release(); }
});

// ═══════════════════════════════════════════════════════════════════════════
// JOIN REQUESTS  (public teams)
// ═══════════════════════════════════════════════════════════════════════════
router.post('/:id/join-request', async (req, res, next) => {
  if (!access.isUuid(req.params.id)) return fail(res, 404, 'Team not found.');
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const t = (await client.query(
      'SELECT id, name, visibility FROM teams WHERE id = $1 FOR UPDATE', [req.params.id],
    )).rows[0];
    if (!t) return bail(client, res, 404, 'Team not found.');
    if (t.visibility !== 'public') return bail(client, res, 403, 'This team is invite-only.');

    const mine = await client.query(
      'SELECT 1 FROM team_members WHERE team_id = $1 AND user_id = $2', [t.id, req.user.id],
    );
    if (mine.rowCount) return bail(client, res, 409, 'You are already in this team.');

    const msg = access.validateBio(req.body.message);
    // UPSERT: 013's UNIQUE(team_id,user_id) would otherwise block anyone who was
    // ever rejected from re-applying. Re-open the row and clear the old verdict.
    await client.query(
      `INSERT INTO team_join_requests (team_id, user_id, status, message)
       VALUES ($1,$2,'pending',$3)
       ON CONFLICT (team_id, user_id) DO UPDATE
         SET status = 'pending', message = EXCLUDED.message,
             created_at = now(), decided_at = NULL, decided_by = NULL`,
      [t.id, req.user.id, msg.ok ? msg.value : null],
    );

    const requesterName = await nameOf(client, req.user.id);
    const admins = (await client.query(
      `SELECT user_id FROM team_members WHERE team_id = $1 AND role IN ('captain','vice_captain')`,
      [t.id],
    )).rows.map((r) => r.user_id);
    for (const uid of admins) {
      await notify(client, {
        userId: uid, type: 'team_request',
        title: t.name, body: `${requesterName} asked to join.`,
      });
    }
    await client.query('COMMIT');
    bus.emitToUsers(admins, 'team:request', { teamId: t.id });
    return ok(res, null, 'Request sent. The captain will review it.');
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    next(e);
  } finally { client.release(); }
});

/** Pending requests for an admin to review. */
router.get('/:id/requests', async (req, res, next) => {
  const client = await pool.connect();
  try {
    const g = await access.requireRole(client, req.params.id, req.user.id, 'admin');
    if (g.error) { await client.query('ROLLBACK').catch(() => {}); return fail(res, g.error.status, g.error.message); }
    const { rows } = await client.query(
      `SELECT r.id, r.user_id, r.status, r.message, r.created_at,
              u.name, u.avatar_url, pp.elo_rating AS player_elo
         FROM team_join_requests r
         JOIN users u ON u.id = r.user_id
         LEFT JOIN player_profiles pp ON pp.user_id = r.user_id
        WHERE r.team_id = $1 AND r.status = 'pending'
        ORDER BY r.created_at DESC`,
      [req.params.id],
    );
    return ok(res, rows);
  } catch (e) { next(e); } finally { client.release(); }
});

/** Approve or reject a pending request. Body: { action: 'approve' | 'reject' }. */
router.patch('/:id/requests/:rid', async (req, res, next) => {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const g = await access.requireRole(client, req.params.id, req.user.id, 'admin');
    if (g.error) return bail(client, res, g.error.status, g.error.message);

    const approve = req.body.action === 'approve' || req.body.status === 'approved';
    const status = approve ? 'approved' : 'rejected';
    const r = (await client.query(
      `UPDATE team_join_requests SET status = $1, decided_at = now(), decided_by = $2
        WHERE id = $3 AND team_id = $4 AND status = 'pending'
        RETURNING user_id`,
      [status, req.user.id, req.params.rid, req.params.id],
    )).rows[0];
    if (!r) return bail(client, res, 404, 'That request is no longer pending.');

    let channelId = null;
    let sysId = null;
    if (approve) {
      if (await access.countMembers(client, req.params.id) >= access.MAX_TEAM_SIZE) {
        return bail(client, res, 409, 'This team is already full.');
      }
      await client.query(
        `INSERT INTO team_members (team_id, user_id, role) VALUES ($1,$2,'member')
         ON CONFLICT (team_id, user_id) DO NOTHING`,
        [req.params.id, r.user_id],
      );
      channelId = await chat.ensureTeamChannel(client, g.team);
      await chat.syncTeamMember(client, channelId, r.user_id, 'member');
      const [actorName, targetName] = await Promise.all([
        nameOf(client, req.user.id), nameOf(client, r.user_id),
      ]);
      sysId = await announce(client, channelId, 'member_joined_request', {
        actorId: req.user.id, actorName, targetId: r.user_id, targetName,
      });
    }
    await notify(client, {
      userId: r.user_id, type: 'team_request',
      title: g.team.name,
      body: approve ? `You're in! Welcome to ${g.team.name}.` : `Your request to join ${g.team.name} was declined.`,
    });
    await client.query('COMMIT');

    if (sysId) await chat.emitPersistedMessage(client, channelId, sysId);
    bus.emitToUsers(r.user_id, 'team:update', { teamId: req.params.id });
    return ok(res, { status });
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    next(e);
  } finally { client.release(); }
});

// ═══════════════════════════════════════════════════════════════════════════
// ROLES & REMOVAL  (captain only) — promote / demote / remove
// ═══════════════════════════════════════════════════════════════════════════
router.patch('/:id/members/:uid', async (req, res, next) => {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const g = await access.requireRole(client, req.params.id, req.user.id, 'captain');
    if (g.error) return bail(client, res, g.error.status, g.error.message);

    const target = await access.loadMembership(client, req.params.id, req.params.uid);
    if (!target) return bail(client, res, 404, 'That player is not on this team.');

    const action = req.body.action || req.body.role;
    const channelId = await chat.ensureTeamChannel(client, g.team);
    const [actorName, targetName] = await Promise.all([
      nameOf(client, req.user.id), nameOf(client, req.params.uid),
    ]);
    let event = null;
    let eventOpts = {};

    if (action === 'remove') {
      // FR2.10 — never leave the team headless.
      if (target.role === 'captain' && await access.countCaptains(client, req.params.id) <= 1) {
        return bail(client, res, 400, 'Promote another captain before removing this one.');
      }
      await client.query('DELETE FROM team_members WHERE team_id = $1 AND user_id = $2',
        [req.params.id, req.params.uid]);
      await chat.removeTeamMember(client, channelId, req.params.uid);
      event = 'member_removed';
      eventOpts = { actorId: req.user.id, actorName, targetId: req.params.uid, targetName };
    } else if (['captain', 'vice_captain', 'member'].includes(action)) {
      if (action === target.role) return bail(client, res, 400, `They are already a ${access.ROLE_LABEL[action]}.`);
      // Demoting the last captain would leave the team with none.
      if (target.role === 'captain' && action !== 'captain'
          && await access.countCaptains(client, req.params.id) <= 1) {
        return bail(client, res, 400, 'Promote another captain before stepping this one down.');
      }
      await client.query('UPDATE team_members SET role = $1 WHERE team_id = $2 AND user_id = $3',
        [action, req.params.id, req.params.uid]);
      await chat.syncTeamMember(client, channelId, req.params.uid, action);
      const promoting = access.TEAM_ROLES.indexOf(action) < access.TEAM_ROLES.indexOf(target.role);
      event = promoting ? 'role_promoted' : 'role_demoted';
      eventOpts = { actorId: req.user.id, actorName, targetId: req.params.uid, targetName, role: action };
    } else {
      return bail(client, res, 400, 'Unknown action.');
    }

    const sysId = await announce(client, channelId, event, eventOpts);
    await notify(client, {
      userId: req.params.uid, type: 'team_role', title: g.team.name,
      body: event === 'member_removed'
        ? `You were removed from ${g.team.name}.`
        : `You are now ${access.ROLE_LABEL[action]} of ${g.team.name}.`,
    });
    await client.query('COMMIT');

    await chat.emitPersistedMessage(client, channelId, sysId);
    bus.emitToUsers(req.params.uid, 'team:update', { teamId: req.params.id });
    return ok(res, { updated: true });
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    next(e);
  } finally { client.release(); }
});

/**
 * Leave a team yourself. Any member can; the sole captain cannot (they would
 * orphan the team) — they must hand over the captaincy or disband first. This is
 * the endpoint the acceptance test's "B leaves" exercises, kept separate from
 * the captain-only role route above so a plain member is actually allowed in.
 */
router.delete('/:id/members/me', async (req, res, next) => {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const g = await access.requireRole(client, req.params.id, req.user.id, 'member');
    if (g.error) return bail(client, res, g.error.status, g.error.message);

    if (g.me.role === 'captain' && await access.countCaptains(client, req.params.id) <= 1) {
      return bail(client, res, 400,
        'You are the only captain. Promote someone else before leaving.');
    }

    await client.query('DELETE FROM team_members WHERE team_id = $1 AND user_id = $2',
      [req.params.id, req.user.id]);
    const channelId = await chat.ensureTeamChannel(client, g.team);
    await chat.removeTeamMember(client, channelId, req.user.id);
    const name = await nameOf(client, req.user.id);
    const sysId = await announce(client, channelId, 'member_left', {
      targetId: req.user.id, targetName: name,
    });
    await client.query('COMMIT');

    await chat.emitPersistedMessage(client, channelId, sysId);
    bus.emitToUsers(req.user.id, 'team:update', { teamId: req.params.id, left: true });
    return ok(res, { left: true }, 'You left the team.');
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    next(e);
  } finally { client.release(); }
});

module.exports = router;
