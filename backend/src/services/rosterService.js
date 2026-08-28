/**
 * rosterService.js — "who should we play with, and who should we play against".
 *
 * WHY THIS FILE EXISTS
 * --------------------
 * FR8.15: no business rule may exist twice. Scout answers `find_players` and
 * `find_opponents`, and the ONLY honest way to do that is to run the same code
 * the roster rail and the Find Opponents screen already run — the candidate
 * pools, the model call, the fallback ordering, the trust badges and the
 * "unranked pairing shows no percentage" rule. Re-implementing any of it for the
 * assistant would give SportLynk two opinions about who is a good teammate, and
 * the first person to notice would be the person whose demo it is.
 *
 * So the two handler bodies were MOVED here verbatim, exactly as S.6 Wave C
 * moved routes/bookings.js's rules into bookingService.js, and both routes are
 * now transport:
 *
 *   GET /api/teams/:id/suggested-players  -> suggestPlayers()
 *   GET /api/matches/opponents            -> suggestOpponents()
 *
 * Nothing about the ranking changed in the move. Both functions return
 * { ok, status, code, message, data } instead of writing to `res`, which is what
 * lets the assistant call them; the route unwraps that into the JSON envelope it
 * always sent, so the Flutter app sees the same bytes it saw in S.5.
 *
 * WHAT THE CALLER STILL OWES
 * --------------------------
 * A pg client. Neither function opens or commits anything — they are pure reads,
 * and the assistant calls them inside the turn's transaction so a suggestion and
 * the booking it leads to are read against one consistent snapshot.
 */
const access = require('../utils/teamAccess');
const stats = require('../utils/teamStats');
const teamStats = stats;
const mc = require('../utils/matchCore');
const elo = require('../utils/elo');
const ml = require('./mlClient');
const settings = require('../utils/globalSettings');

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
 * below needs no cast and this one does.
 */
const BOOKED_STATUSES = ['confirmed', 'checked_in'];


// ==========================================================================
// PLAYERS
// ==========================================================================

/**
 * suggestPlayers — FR2.8, the roster screen's rail, and Scout's `find_players`.
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
async function suggestPlayers(client, { teamId: teamId0, userId } = {}) {
  const g = await access.requireRole(client, teamId0, userId, 'admin');
  if (g.error) {
    return { ok: false, status: g.error.status, code: 'forbidden',
      message: g.error.message, data: null };
  }

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

  return { ok: true, status: 200, code: 'ok', message: null, data: {
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
  } };
}


// ==========================================================================
// OPPONENTS
// ==========================================================================

/**
 * suggestOpponents — GET /api/matches/opponents, and Scout's `find_opponents`.
 *
 * The Find Opponents list (FR5.3 – FR5.5): public teams in the same sport that
 * the caller does not already belong to, CLOSEST RATING FIRST, each carrying its
 * competitiveness score against the caller's team and its roster trust badge.
 *
 * WHY NOT /teams/discover
 * That endpoint is rating-ordered and team-agnostic — it cannot know which team
 * you would be challenging, so it cannot order by rating PROXIMITY, cannot
 * compute competitiveness, and does not carry trust. All three are what this
 * screen is specified to show, and all three depend on the pairing rather than on
 * either team alone.
 *
 * FR5.3 — S.5 Wave B MOVED THE RANKING TO THE MODEL SEAM, and the SQL's
 * `abs(t.elo - my elo)` ordering is now the FALLBACK rather than the answer. The
 * ml-service scores 0.6 x rating proximity + 0.2 x opponent trust + 0.2 x recent
 * activity and returns a component breakdown per row; when it cannot be reached
 * the rows ship in this query's order with S.2's competitiveness formula, which is
 * why the ORDER BY still has to be right. `withinBand` is reported per row on both
 * paths so the UI can mark where the good-match band ends.
 */
async function suggestOpponents(client, { teamId: teamId0, userId, q: q0 = '' } = {}) {
  // The route used to normalise the query string before connecting. It lives here
  // now because the assistant passes a team id it resolved from a NAME, and both
  // callers must reject the same garbage with the same words.
  const teamId = String(teamId0 == null ? '' : teamId0).trim().toLowerCase();
  if (!access.isUuid(teamId)) {
    return { ok: false, status: 400, code: 'bad_team',
      message: 'Pick one of your teams first.', data: null };
  }
  const q = access.squash(q0 || '');

  const role = await mc.roleInTeam(client, teamId, userId);
  if (!role) {
    return { ok: false, status: 403, code: 'not_a_member',
      message: 'You are not a member of that team.', data: null };
  }

  const features = await mc.teamFeatures(client, [teamId]);
  const me = features.get(teamId);
  if (!me) {
    return { ok: false, status: 404, code: 'team_not_found',
      message: 'Team not found.', data: null };
  }

  const { base } = await settings.elo({ client });
  const myElo = me.elo || base;

  const params = [userId, teamId, me.sport, myElo];
  let extra = '';
  if (q) {
    params.push(`%${q}%`);
    extra = ` AND t.name ILIKE $${params.length}`;
  }

  const { rows } = await client.query(
    `SELECT t.id, t.name, t.logo_url, t.city, t.sport::text AS sport,
            t.elo, t.wins, t.losses, t.draws, t.elo_frozen,
            COALESCE(tr.trust, 100) AS trust_score,
            COALESCE(tr.members, 0) AS member_count,
            abs(COALESCE(t.elo, $4) - $4) AS gap
       FROM teams t
       LEFT JOIN LATERAL (
         SELECT round(avg(pp.trust_score))::int AS trust, count(*)::int AS members
           FROM team_members m
           LEFT JOIN player_profiles pp ON pp.user_id = m.user_id
          WHERE m.team_id = t.id
       ) tr ON TRUE
      WHERE t.visibility = 'public'
        AND t.sport = $3
        AND t.id <> $2
        AND NOT EXISTS (
              SELECT 1 FROM team_members m
               WHERE m.team_id = t.id AND m.user_id = $1
            )${extra}
      ORDER BY abs(COALESCE(t.elo, $4) - $4), lower(t.name)
      LIMIT 60`,
    params,
  );

  // ── Recent activity for the whole pool, in one query ────────────────────
  // The recommender's third component. Counted over the SAME 30-day window and
  // the SAME statuses utils/teamStats.js already counts a team's own activity
  // over (a disputed fixture was still played), so the number behind a "Playing
  // regularly" reason is the number that team's own profile card shows.
  //
  // LEFT JOIN LATERAL over unnest, so a team with no matches comes back as ZERO
  // rather than missing: zero is a measurement — genuinely inactive — and
  // reco_rank scores it 0.0, while an absent value would take the neutral prior
  // and quietly reward a dormant team.
  const ids = rows.map((r) => r.id);
  const activity = new Map();
  if (ids.length) {
    const { rows: act } = await client.query(
      `SELECT x.id, COALESCE(c.n, 0)::int AS activity_30d
         FROM unnest($1::uuid[]) AS x(id)
         LEFT JOIN LATERAL (
           SELECT count(*) AS n
             FROM matches m
            WHERE (m.challenger_team = x.id OR m.opponent_team = x.id)
              AND m.status = ANY($2::text[])
              AND COALESCE(m.verified_at, m.updated_at, m.created_at) >= now() - $3::interval
         ) c ON TRUE`,
      [ids, teamStats.SERIES_STATUSES, `${teamStats.ACTIVITY_WINDOW_DAYS} days`],
    );
    for (const a of act) activity.set(a.id, mc.int0(a.activity_30d));
  }

  const opponents = rows.map((r) => {
    const stats = {
      wins: mc.int0(r.wins), losses: mc.int0(r.losses), draws: mc.int0(r.draws),
    };
    const rating = mc.int0(r.elo) || base;
    const ranked = elo.isRanked(stats);
    return {
      id: r.id,
      name: r.name,
      logoUrl: r.logo_url || null,
      city: r.city || null,
      sport: r.sport,
      elo: rating,
      ranked,
      displayElo: ranked ? rating : null,
      played: stats.wins + stats.losses + stats.draws,
      ...stats,
      memberCount: mc.int0(r.member_count),
      eloFrozen: r.elo_frozen === true,
      ...mc.trustBadge(r.trust_score),
      eloGap: mc.int0(r.gap),
      withinBand: mc.int0(r.gap) <= elo.PREFERRED_ELO_BAND,
      // FR5.4 — null whenever either side is unranked, so the bar renders
      // "Unranked" instead of a percentage derived from a placeholder 1000.
      //
      // THIS IS NOW THE FALLBACK VALUE. When the ranking service answers, it is
      // overwritten below by the three-component score; when it does not, this v1
      // number ships unchanged and the screen keeps working. Both paths obey the
      // same unranked rule, which is why the swap is invisible to the UI.
      competitiveness: elo.competitivenessFor(me, { elo: rating, ...stats }),
      matchesLast30d: activity.get(r.id) ?? 0,
      // Populated only on the ranked path — see below. Null here rather than
      // absent so Dart's model reads one shape from both paths.
      matchPct: null,
      rankScore: null,
      components: null,
      reasons: [],
    };
  });

  // ── FR5.3 — model ranking, v1 kept as the fallback ──────────────────────
  // The ml-service scores each pairing on 0.6 x rating proximity + 0.2 x trust +
  // 0.2 x recent activity and returns a per-row component breakdown, which the app
  // renders as the expandable "Why this match?" line. Rating proximity is the same
  // curve utils/elo.js uses, so the primary and fallback paths agree about what a
  // close match is and only disagree about what else counts.
  //
  // If it is unreachable the rows keep the SQL's rating-proximity order and v1's
  // competitiveness, and `ranking.source` says `heuristic` — the feature degrades
  // to exactly what S.2 shipped rather than going blank (ER2.6).
  const ranked = await ml.recommendOpponents({
    teamId,
    team: {
      team_id: teamId,
      elo: myElo,
      ranked: elo.isRanked(me),
      trust_score: me.trustScore,
      sport: me.sport,
      city: me.city,
    },
    candidates: opponents.map((o) => ({
      team_id: o.id,
      elo: o.elo,
      ranked: o.ranked,
      trust_score: o.trustScore,
      matches_30d: o.matchesLast30d,
    })),
    limit: Math.max(1, opponents.length),
  });

  let list = opponents;
  if (ranked.available && ranked.items.length) {
    const enriched = new Map(
      opponents.map((o) => [String(o.id), o]),
    );
    for (const it of ranked.items) {
      const row = enriched.get(String(it.team_id));
      if (!row) continue;
      // `?? null` and not `|| null`: a legitimate 0 must survive, and
      // competitiveness is deliberately null for an unranked pairing.
      row.competitiveness = it.competitiveness ?? null;
      row.matchPct = it.match_pct ?? null;
      row.rankScore = it.score ?? null;
      row.components = it.components || null;
      row.reasons = Array.isArray(it.reasons) ? it.reasons : [];
    }
    // Reorder to the scorer's ranking. Anything it did not score (it cannot
    // happen today, but a future filter there would make it possible) keeps its
    // v1 position at the tail rather than vanishing from the screen.
    const seen = new Set();
    const ordered = [];
    for (const it of ranked.items) {
      const row = enriched.get(String(it.team_id));
      if (row && !seen.has(String(it.team_id))) {
        ordered.push(row);
        seen.add(String(it.team_id));
      }
    }
    for (const o of opponents) if (!seen.has(String(o.id))) ordered.push(o);
    list = ordered;
  }

  return { ok: true, status: 200, code: 'ok', message: null, data: {
    myTeam: {
      id: me.id,
      name: me.name,
      logoUrl: me.logoUrl,
      sport: me.sport,
      elo: myElo,
      ranked: elo.isRanked(me),
      displayElo: elo.displayElo(me, base),
      played: me.wins + me.losses + me.draws,
      wins: me.wins,
      losses: me.losses,
      draws: me.draws,
      ...mc.trustBadge(me.trustScore),
      eloFrozen: me.eloFrozen,
    },
    // Shipped so the Challenge button can be disabled for a non-captain rather
    // than offered and then refused by the API with a 403.
    myRole: role,
    canChallenge: role === 'captain',
    preferredBand: elo.PREFERRED_ELO_BAND,
    // Which path produced the order and the percentages, in the same spirit as
    // the pricing card's `source` badge: a screen that shows a ranking is
    // entitled to say what ranked it, and the FYP committee is entitled to ask.
    ranking: {
      source: ranked.source,
      available: ranked.available,
      specVersion: ranked.rankSpecVersion,
      specFingerprint: ranked.rankSpecFingerprint,
      weights: ranked.weights,
      componentOrder: ranked.componentOrder,
      activityWindowDays: teamStats.ACTIVITY_WINDOW_DAYS,
      fallbackNote: ranked.available
        ? null
        : 'Ordered by rating proximity — the ranking service is unavailable',
    },
    opponents: list,
  } };
}

module.exports = {
  HOME_WINDOW_DAYS,
  SUGGEST_POOL,
  SUGGEST_LIMIT,
  BOOKED_STATUSES,
  suggestPlayers,
  suggestOpponents,
};
