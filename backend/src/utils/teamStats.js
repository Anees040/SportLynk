/**
 * teamStats.js — the leaderboard, the profile snapshot, and the ELO chart series.
 *
 * Three reads live here rather than in routes/teams.js because each
 * one is a real query with rules attached, and a route file that inlines them
 * stops reading as "who may do what" and starts reading as SQL.
 *
 * The one rule that matters most: ranked means the same thing everywhere
 * FR2.6 says a team has no displayable rating until it has >=1 verified match.
 * That rule lives in elo.isRanked() / elo.displayElo(), and the match
 * screens have used it since. This module binds to those same two functions —
 * RANKED_MIN below is elo.RANKED_MIN_MATCHES, bound as a query parameter, not a
 * literal typed a second time.
 *
 * That matters because the failure it prevents is silent: if the leaderboard
 * used its own "played > 0" test, a team could sit at #4 on the rankings screen
 * and read "Unranked" on its own profile, and nothing would crash — the app
 * would just quietly contradict itself in front of the committee.
 *
 * Why the SEED 1000 is never sent as a rating
 * Unranked teams are excluded from the board entirely (they have not earned a
 * position), and every row still ships `ranked` + `display_elo` so a screen
 * cannot print a placeholder as though it were earned. On a fresh install the
 * board is legitimately empty, and that is the correct answer, not a bug.
 *
 * Why movement is computed, not stored
 * There is no rank-snapshot table, and adding one would need a nightly job that
 * silently rots the day it stops running. elo_history already records
 * (elo_before, elo_after, created_at) for every rating change, so a team's
 * rating 7 days ago is recoverable exactly: it is the `elo_before` of its oldest
 * change inside the window, or — when nothing moved in the window — its rating
 * right now. Re-ranking on that column gives the position it held then, and the
 * difference is the movement. Nothing to schedule, nothing to backfill, and it
 * stays correct if the server is off for a week.
 *
 * A team whose first-ever rating change lands inside the window was not on the
 * board 7 days ago, so its movement is NULL — "new", not "+12". Reporting a
 * climb from a rank it never held would be an invented number.
 *
 * Shape: this file feeds routes/teams.js, which is snake_case. matchCore's
 * teamFeatures() feeds routes/matches.js, which is camelCase. The conversion
 * happens once, in profileStats(), and nowhere else.
 */

const elo = require('./elo');
const mc = require('./matchCore');
const access = require('./teamAccess');

/** FR2.6, bound as a parameter so this file cannot drift from elo.js. */
const RANKED_MIN = elo.RANKED_MIN_MATCHES;

/** How far back "movement" looks. Days, not hours — a leaderboard is weekly. */
const MOVEMENT_WINDOW_DAYS = 7;

/** Recent-activity window for the recommender's activity feature. */
const ACTIVITY_WINDOW_DAYS = 30;

/** Chart depth. FR5.14 asks for the last 10 matches. */
const SERIES_LIMIT = 10;

/** Hard ceiling on a leaderboard page, so ?limit= can never ask for the table. */
const MAX_LIMIT = 100;

/** Only these two reach the chart/history — both terminal, and both displayed. */
const SERIES_STATUSES = [mc.STATUS.COMPLETED, mc.STATUS.DISPUTED];

const int0 = (v) => {
  const n = Number(v);
  return Number.isFinite(n) ? Math.round(n) : 0;
};

/**
 * City as a filter value. `teams.city` is free text, so this is the only thing
 * standing between the column and arbitrary input. Returns null for "no filter"
 * rather than an empty string, so a caller cannot accidentally filter on ''.
 *
 * Uses access.squash() — the same control/bidi/zero-width strip every other team
 * text field already goes through — rather than a second hand-rolled cleaner. A
 * zero-width space inside ?city= would otherwise match nothing while looking
 * exactly like a real city name in the logs.
 */
function normaliseCity(raw) {
  const s = access.squash(raw == null ? '' : raw);
  if (!s || s.length > 80) return null;
  return s;
}

/**
 * The leaderboard (FR5.13).
 *
 * Ranked public teams only, ordered by rating, with the position each team held
 * MOVEMENT_WINDOW_DAYS ago and the difference between the two.
 *
 * `is_mine` is computed here from the viewer's membership rather than being
 * inferred client-side. The screen previously guessed it from a `role` field
 * this endpoint never sent, so the "YOU" badge could never appear — a viewer
 * fact has to be answered by the server that knows the viewer.
 *
 * One statement, so rank_now and rank_then are two window functions over the
 * same candidate set. Ranking twice in JS would mean re-sorting the same rows
 * and re-deriving ties differently.
 */
async function rankings(db, { sport = null, city = null, viewerId = null, limit = MAX_LIMIT } = {}) {
  const params = [];
  const bind = (v) => { params.push(v); return `$${params.length}`; };

  const pViewer = bind(viewerId);
  const pMin = bind(RANKED_MIN);
  const pWindow = bind(`${MOVEMENT_WINDOW_DAYS} days`);

  const conds = [
    "t.visibility = 'public'",
    // FR2.6 — the same played-count elo.isRanked() applies, expressed in SQL.
    `(COALESCE(t.wins,0) + COALESCE(t.losses,0) + COALESCE(t.draws,0)) >= ${pMin}`,
  ];
  if (sport) conds.push(`t.sport = ${bind(sport)}`);
  if (city) conds.push(`lower(btrim(t.city)) = lower(btrim(${bind(city)}))`);

  const pLimit = bind(Math.min(Math.max(int0(limit) || MAX_LIMIT, 1), MAX_LIMIT));

  const { rows } = await db.query(
    `WITH cand AS (
       SELECT t.id, t.name, t.sport::text AS sport, t.logo_url, t.city, t.visibility,
              t.elo, t.wins, t.losses, t.draws, t.elo_frozen, t.captain_id, t.created_at,
              (SELECT count(*)::int FROM team_members m WHERE m.team_id = t.id) AS member_count,
              EXISTS (SELECT 1 FROM team_members m
                       WHERE m.team_id = t.id AND m.user_id = ${pViewer}) AS is_mine
         FROM teams t
        WHERE ${conds.join(' AND ')}
     ),
     past AS (
       SELECT c.id,
              -- The rating it held then: the elo_before of its oldest change
              -- inside the window, or its current rating when nothing moved.
              COALESCE((
                SELECT eh.elo_before FROM elo_history eh
                 WHERE eh.team_id = c.id
                   AND eh.created_at >= now() - ${pWindow}::interval
                   AND eh.elo_before IS NOT NULL
                 ORDER BY eh.created_at ASC, eh.id ASC
                 LIMIT 1
              ), c.elo) AS elo_then,
              -- Was it on the board at all? A first rating change landing inside
              -- the window means it was not.
              EXISTS (
                SELECT 1 FROM elo_history eh
                 WHERE eh.team_id = c.id
                   AND eh.created_at < now() - ${pWindow}::interval
              ) AS existed_then
         FROM cand c
     ),
     board AS (
       SELECT c.*, p.elo_then, p.existed_then,
              row_number() OVER (ORDER BY c.elo DESC, lower(c.name))      AS rank_now,
              row_number() OVER (ORDER BY p.elo_then DESC, lower(c.name)) AS rank_then
         FROM cand c JOIN past p ON p.id = c.id
     )
     SELECT *,
            CASE WHEN existed_then THEN (rank_then - rank_now) ELSE NULL END AS movement
       FROM board
      ORDER BY rank_now
      LIMIT ${pLimit}`,
    params,
  );

  return rows.map((r) => {
    const stats = { wins: int0(r.wins), losses: int0(r.losses), draws: int0(r.draws) };
    const ranked = elo.isRanked(stats);
    return {
      id: r.id,
      name: r.name,
      sport: r.sport,
      logo_url: r.logo_url || null,
      city: r.city || null,
      visibility: r.visibility,
      captain_id: r.captain_id || null,
      created_at: r.created_at,
      member_count: int0(r.member_count),
      wins: stats.wins,
      losses: stats.losses,
      draws: stats.draws,
      played: stats.wins + stats.losses + stats.draws,
      elo: int0(r.elo),
      rank: int0(r.rank_now),
      // null (not 0) when the team was not on the board a week ago, so the UI
      // can draw "NEW" instead of a dash that reads like "held its place".
      movement: r.movement === null || r.movement === undefined ? null : int0(r.movement),
      ranked,
      display_elo: ranked ? int0(r.elo) : null,
      elo_frozen: r.elo_frozen === true,
      is_mine: r.is_mine === true,
    };
  });
}

/**
 * The cities that have ranked teams right now — the filter chips are
 * built from this rather than from a hard-coded list of Pakistani cities.
 *
 * A chip the data cannot satisfy is worse than a missing chip: the user taps
 * "Lahore", gets an empty screen, and reads it as a broken feature. Deriving the
 * list means every chip is guaranteed to return at least one team. It also
 * degrades honestly while `teams.city` is still mostly NULL — no chips, rather
 * than five chips that all lead nowhere.
 *
 * Grouped case-folded, the same way the ?city= filter compares. City is free text
 * a captain types, so "Lahore" and "lahore" have to be one chip and not two that
 * return identical rows. min() picks a stable representative and happens to favour
 * the capitalised spelling, which is the one a human would have typed.
 */
async function rankedCities(db, { sport = null } = {}) {
  const params = [RANKED_MIN];
  let extra = '';
  if (sport) { params.push(sport); extra = ` AND t.sport = $${params.length}`; }
  const { rows } = await db.query(
    `SELECT min(btrim(t.city)) AS city, count(*)::int AS teams
       FROM teams t
      WHERE t.visibility = 'public'
        AND t.city IS NOT NULL AND btrim(t.city) <> ''
        AND (COALESCE(t.wins,0) + COALESCE(t.losses,0) + COALESCE(t.draws,0)) >= $1${extra}
      GROUP BY lower(btrim(t.city))
      ORDER BY count(*) DESC, lower(btrim(t.city))`,
    params,
  );
  return rows.map((r) => ({ city: r.city, teams: int0(r.teams) }));
}

/**
 * The profile snapshot (FR5.15).
 *
 * `form` is not re-derived here: matchCore.teamFeatures() already produces the
 * canonical last-5 string that find-opponents and the match preview both read,
 * and a second copy of that SQL would drift the first time one was edited. This
 * function adds only what did not exist anywhere — the 30-day activity count,
 * the win rate, and the FR2.6 pair.
 *
 * activity_30d counts matches that reached a terminal state inside the window,
 * and is the feature the recommender consumes. It counts DISPUTED
 * alongside COMPLETED on purpose: the question it answers is "is this team
 * playing?", and a disputed fixture was still played.
 */
async function profileStats(db, teamId) {
  const [features, counts] = await Promise.all([
    mc.teamFeatures(db, [teamId]),
    db.query(
      `SELECT count(*)::int AS activity_30d
         FROM matches m
        WHERE (m.challenger_team = $1 OR m.opponent_team = $1)
          AND m.status = ANY($2::text[])
          AND COALESCE(m.verified_at, m.updated_at, m.created_at) >= now() - $3::interval`,
      [teamId, SERIES_STATUSES, `${ACTIVITY_WINDOW_DAYS} days`],
    ),
  ]);

  // teamFeatures() returns camelCase (eloFrozen, memberCount) because it feeds
  // the camelCase matches API. teams.js is snake_case, so the rename happens
  // here — this is the one seam between the two conventions.
  const f = features.get(String(teamId)) || {};
  const stats = { wins: int0(f.wins), losses: int0(f.losses), draws: int0(f.draws) };
  const played = stats.wins + stats.losses + stats.draws;
  const ranked = elo.isRanked(stats);

  return {
    wins: stats.wins,
    losses: stats.losses,
    draws: stats.draws,
    played,
    // Integer percent, 0 (never NaN) before a team has played. The client had
    // this guard already; the server must not be the one to send NaN.
    win_rate: played === 0 ? 0 : Math.round((stats.wins / played) * 100),
    ranked,
    display_elo: ranked ? int0(f.elo) : null,
    elo: int0(f.elo),
    elo_frozen: f.eloFrozen === true,
    // '' when a team has no completed match yet, never null, so the UI can
    // always split it into characters without a null check.
    form: String(f.form || ''),
    activity_30d: int0(counts.rows[0] && counts.rows[0].activity_30d),
    activity_window_days: ACTIVITY_WINDOW_DAYS,
    ranked_min_matches: RANKED_MIN,
  };
}

/**
 * The ELO chart series + match history (FR5.14 / FR5.16) — the team's last N
 * terminal matches, oldest first so a line chart reads left to right without the
 * client reversing anything.
 *
 * Why this is not just `SELECT * FROM elo_history`
 * FR5.14 wants disputed matches on the chart, drawn as red hollow dots. A
 * disputed match has no elo_history row — that is the whole point of the dispute
 * rule: the match completes and records W/L, but no points move.
 * Reading elo_history alone would silently drop exactly the points the
 * requirement asks to display.
 *
 * So the series is driven by `matches` and LEFT JOINs elo_history. A row with no
 * join partner is a match that moved no rating — disputed, or completed while
 * the team's rating was frozen (ER2.3). Those points are plotted at the last
 * known rating, carried forward in JS below, because a chart that dropped to
 * zero on a frozen match would read as a catastrophic loss.
 */
async function eloSeries(db, teamId, { limit = SERIES_LIMIT } = {}) {
  const n = Math.min(Math.max(int0(limit) || SERIES_LIMIT, 1), 50);
  const { rows } = await db.query(
    `SELECT m.id AS match_id,
            m.status,
            m.winner_team,
            m.challenger_team,
            m.opponent_team,
            m.score_challenger,
            m.score_opponent,
            m.elo_applied,
            COALESCE(m.verified_at, m.updated_at, m.created_at) AS at,
            ct.name AS challenger_name,
            ct.logo_url AS challenger_logo,
            ot.name AS opponent_name,
            ot.logo_url AS opponent_logo,
            eh.elo_before, eh.elo_after, eh.elo_delta
       FROM matches m
       JOIN teams ct ON ct.id = m.challenger_team
       JOIN teams ot ON ot.id = m.opponent_team
       LEFT JOIN elo_history eh ON eh.match_id = m.id AND eh.team_id = $1
      WHERE (m.challenger_team = $1 OR m.opponent_team = $1)
        AND m.status = ANY($2::text[])
      ORDER BY COALESCE(m.verified_at, m.updated_at, m.created_at) DESC, m.id DESC
      LIMIT $3`,
    [teamId, SERIES_STATUSES, n],
  );

  // Oldest first for the chart's x-axis.
  const ordered = rows.slice().reverse();

  let lastKnown = null;
  const points = ordered.map((r) => {
    const mine = String(r.challenger_team) === String(teamId);
    const myScore = mine ? int0(r.score_challenger) : int0(r.score_opponent);
    const theirScore = mine ? int0(r.score_opponent) : int0(r.score_challenger);
    const rated = r.elo_after !== null && r.elo_after !== undefined;
    if (rated) lastKnown = int0(r.elo_after);

    const outcome = r.winner_team === null || r.winner_team === undefined
      ? 'draw'
      : (String(r.winner_team) === String(teamId) ? 'win' : 'loss');

    return {
      match_id: r.match_id,
      at: r.at,
      status: r.status,
      // The two flags FR5.14 draws with: solid green vs hollow red.
      verified: r.status === mc.STATUS.COMPLETED,
      disputed: r.status === mc.STATUS.DISPUTED,
      // A completed-but-unrated point is a FROZEN rating, not a dispute. The UI
      // needs to tell those apart so it never calls a frozen team "disputed".
      rated,
      opponent_id: mine ? r.opponent_team : r.challenger_team,
      opponent_name: mine ? r.opponent_name : r.challenger_name,
      opponent_logo: (mine ? r.opponent_logo : r.challenger_logo) || null,
      my_score: myScore,
      their_score: theirScore,
      result: r.status === mc.STATUS.DISPUTED ? 'disputed' : outcome,
      elo_before: rated ? int0(r.elo_before) : null,
      elo_after: rated ? int0(r.elo_after) : null,
      elo_delta: rated ? int0(r.elo_delta) : null,
      // Where the dot sits. Carried forward so an unrated match does not read as
      // a fall to zero.
      elo_at: rated ? int0(r.elo_after) : lastKnown,
    };
  });

  // Points before the team's first rated match have no rating to sit at. Drop
  // them rather than invent one — a chart is allowed to start later than the
  // match history does.
  return points.filter((p) => p.elo_at !== null);
}

module.exports = {
  RANKED_MIN,
  MOVEMENT_WINDOW_DAYS,
  ACTIVITY_WINDOW_DAYS,
  // Exported so the opponent recommender counts "recent activity"
  // over exactly the statuses this file already counts it over. A third hand-typed
  // copy of [completed, disputed] is how the rail and the profile card would end up
  // disagreeing about how active a team is.
  SERIES_STATUSES,
  SERIES_LIMIT,
  MAX_LIMIT,
  normaliseCity,
  rankings,
  rankedCities,
  profileStats,
  eloSeries,
};
