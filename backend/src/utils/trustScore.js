/**
 * Trust Score 2.0 (ER2.5)
 *
 * One composite score, 0..100, recomputed synchronously after every event that
 * can move it — a review received, a no-show, a dispute. It replaces the old
 * flat "trust_score − 10 per no-show" decrement, which could only ever fall and
 * said nothing about why.
 *
 *   trust = round( 35·rating_norm + 30·attendance_rate
 *                + 20·dispute_free_rate + 15·sentiment_norm )
 *
 * The four components, each normalised to 0..1:
 *
 *   rating_norm       avg(stars received) / 5           — reviews about the user
 *   attendance_rate   checked_in / (checked_in + no_show) — the user's bookings
 *   dispute_free_rate 1 − disputes_against / matches      — a pre-S.7 proxy (see below)
 *   sentiment_norm    (avg(sentiment_score) + 1) / 2      — model score on review text
 *
 * Cold start. A brand-new user has no reviews, no bookings, no matches — every
 * component is absent. Rather than let "no data" read as "zero trust" (the
 * cold-start injustice ER2.5 warns about), an absent component contributes a
 * neutral 0.5 prior to the aggregate. A user with no signal at all therefore
 * scores round(35·.5 + 30·.5 + 20·.5 + 15·.5) = 50 — exactly the documented
 * baseline. The component COLUMNS are stored NULL when there is no signal (so a
 * UI can say "no data yet" rather than draw a misleading 50% bar); only the
 * aggregate substitutes the prior.
 *
 * dispute_free_rate is a proxy until S.7. Fault in a dispute is not adjudicated
 * until an admin resolves it, so before then the metric can only count "disputes the
 * other side filed on a match this user's team played" as a soft negative
 * signal. A dispute this user's own team raised does not count against them
 * (that would punish objecting to a bad result), and a `dismissed` dispute is
 * dropped entirely. This is intentionally conservative and documented as a
 * proxy; S.7's resolution flow can refine it.
 *
 * Scope. Reviews target one user (a venue review has no user target; an opponent
 * review targets the opposing team's captain — see routes/reviews.js), so the
 * review-based components move a captain's score as the team's representative.
 * Attendance is genuinely per-user. This matches the captain-to-captain review
 * model chosen for Wave C.
 *
 * The functions take any pg client (a transaction client or the pool) so the
 * caller controls atomicity: the no-show and review paths call recomputeTrust
 * inside their money/state transaction (so the score and the event commit
 * together); the dispute path calls recomputeForMatch on the pool after commit
 * (best-effort — a failed recompute must never roll back a filed dispute).
 */

// Spec weights. They sum to 100, so the aggregate is already on a 0..100 scale.
const WEIGHTS = { rating: 35, attendance: 30, disputes: 20, sentiment: 15 };

// What an absent component contributes to the aggregate (not to its column).
const NEUTRAL_PRIOR = 0.5;

/** pg returns numeric/bigint as strings; NULL as null. */
const asNum = (v) => (v === null || v === undefined ? null : Number(v));

const clamp01 = (x) => Math.max(0, Math.min(1, x));

/**
 * Recompute and persist one user's Trust Score 2.0.
 *
 * @param {import('pg').ClientBase} db  a pg client (txn) or the pool
 * @param {string} userId
 * @returns {Promise<{trustScore:number, components:object}>}
 */
async function recomputeTrust(db, userId) {
  // One round-trip gathers every raw aggregate the four components need.
  const { rows: [raw] } = await db.query(
    `
    WITH my_teams AS (
      SELECT team_id FROM team_members WHERE user_id = $1
    ),
    my_matches AS (
      SELECT m.id
        FROM matches m
       WHERE m.status IN ('completed', 'disputed')
         AND (m.challenger_team IN (SELECT team_id FROM my_teams)
              OR m.opponent_team  IN (SELECT team_id FROM my_teams))
    )
    SELECT
      -- reviews RECEIVED (moderated-out rows never count toward trust)
      (SELECT avg(rating)          FROM reviews
         WHERE reviewed_user_id = $1 AND hidden = false)                       AS avg_rating,
      (SELECT count(rating)        FROM reviews
         WHERE reviewed_user_id = $1 AND hidden = false)                       AS n_rating,
      (SELECT avg(sentiment_score) FROM reviews
         WHERE reviewed_user_id = $1 AND hidden = false
           AND sentiment_score IS NOT NULL)                                    AS avg_sentiment,
      (SELECT count(sentiment_score) FROM reviews
         WHERE reviewed_user_id = $1 AND hidden = false)                       AS n_sentiment,
      -- attendance over the user's OWN bookings
      (SELECT count(*) FILTER (WHERE status = 'checked_in') FROM bookings
         WHERE player_id = $1)                                                 AS checked_in,
      (SELECT count(*) FILTER (WHERE status = 'no_show')    FROM bookings
         WHERE player_id = $1)                                                 AS no_shows,
      -- dispute proxy: matches the user's teams played, and disputes the OTHER
      -- side filed on them (not dismissed)
      (SELECT count(*) FROM my_matches)                                        AS played,
      (SELECT count(*) FROM disputes d
         JOIN my_matches mm ON mm.id = d.match_id
        WHERE d.raised_by_team IS NOT NULL
          AND d.status <> 'dismissed'
          AND d.raised_by_team NOT IN (SELECT team_id FROM my_teams))          AS disputes_against
    `,
    [userId],
  );

  const nRating = asNum(raw.n_rating) || 0;
  const nSentiment = asNum(raw.n_sentiment) || 0;
  const checkedIn = asNum(raw.checked_in) || 0;
  const noShows = asNum(raw.no_shows) || 0;
  const played = asNum(raw.played) || 0;
  const disputesAgainst = asNum(raw.disputes_against) || 0;

  // Each component is a real 0..1 value when there is a signal, else null.
  const ratingNorm = nRating > 0 ? clamp01(asNum(raw.avg_rating) / 5) : null;
  const attendanceRate = (checkedIn + noShows) > 0
    ? clamp01(checkedIn / (checkedIn + noShows))
    : null;
  const disputeFreeRate = played > 0
    ? clamp01(1 - disputesAgainst / played)
    : null;
  const sentimentNorm = nSentiment > 0
    ? clamp01((asNum(raw.avg_sentiment) + 1) / 2)
    : null;

  // The aggregate substitutes the neutral prior for any absent component.
  const p = (x) => (x === null ? NEUTRAL_PRIOR : x);
  const trustScore = Math.round(
    WEIGHTS.rating * p(ratingNorm)
    + WEIGHTS.attendance * p(attendanceRate)
    + WEIGHTS.disputes * p(disputeFreeRate)
    + WEIGHTS.sentiment * p(sentimentNorm),
  );
  const clamped = Math.max(0, Math.min(100, trustScore));

  // Upsert: every player has a profile (auth.js:53), so this is normally an
  // UPDATE; the INSERT arm is a safety net if a profile is somehow missing.
  // Components store the real value or NULL — never the prior.
  await db.query(
    `
    INSERT INTO player_profiles
      (user_id, trust_score, trust_rating, trust_attendance, trust_disputes, trust_sentiment)
    VALUES ($1, $2, $3, $4, $5, $6)
    ON CONFLICT (user_id) DO UPDATE SET
      trust_score      = EXCLUDED.trust_score,
      trust_rating     = EXCLUDED.trust_rating,
      trust_attendance = EXCLUDED.trust_attendance,
      trust_disputes   = EXCLUDED.trust_disputes,
      trust_sentiment  = EXCLUDED.trust_sentiment
    `,
    [userId, clamped, ratingNorm, attendanceRate, disputeFreeRate, sentimentNorm],
  );

  return {
    trustScore: clamped,
    components: {
      rating: ratingNorm,
      attendance: attendanceRate,
      disputes: disputeFreeRate,
      sentiment: sentimentNorm,
    },
  };
}

/**
 * The single user who represents a team for trust purposes: teams.captain_id,
 * or the earliest-joined role='captain' member if that pointer is unset.
 * Returns null for a team with no captain at all (nothing to recompute).
 */
async function representativeCaptain(db, teamId) {
  const { rows: [row] } = await db.query(
    `SELECT COALESCE(
              t.captain_id,
              (SELECT tm.user_id FROM team_members tm
                WHERE tm.team_id = t.id AND tm.role = 'captain'
                ORDER BY tm.joined_at ASC
                LIMIT 1)
            ) AS captain_id
       FROM teams t
      WHERE t.id = $1`,
    [teamId],
  );
  return row ? row.captain_id : null;
}

/**
 * Recompute both teams' representative captains after a match-level event (a
 * dispute filed or resolved). A new dispute moves dispute_free_rate for the team
 * it was filed against; recomputing both captains covers either side without the
 * caller having to work out which. De-dupes in case one user captains both.
 *
 * Best-effort by contract: call it after the state transaction has committed.
 */
async function recomputeForMatch(db, matchId) {
  const { rows: [m] } = await db.query(
    'SELECT challenger_team, opponent_team FROM matches WHERE id = $1',
    [matchId],
  );
  if (!m) return [];

  const captains = await Promise.all([
    representativeCaptain(db, m.challenger_team),
    representativeCaptain(db, m.opponent_team),
  ]);

  const seen = new Set();
  const done = [];
  for (const uid of captains) {
    if (!uid || seen.has(String(uid))) continue;
    seen.add(String(uid));
    await recomputeTrust(db, uid);
    done.push(uid);
  }
  return done;
}

module.exports = {
  recomputeTrust,
  recomputeForMatch,
  representativeCaptain,
  // exposed for tests / documentation of the composite
  WEIGHTS,
  NEUTRAL_PRIOR,
};
