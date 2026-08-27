/**
 * Matches API (S.2 Wave C) — challenge, respond, result, verify, dispute, list.
 *
 * THE STATE MACHINE — doc/API.md is the authoritative copy, chk_matches_status
 * (migration 016) is the database's copy, utils/matchCore.STATUS is the code's.
 * All three must agree.
 *
 *   challenge_sent ─(opponent captain accepts)──→ accepted
 *         │                                          │
 *         │(reject, or 48h expiry — FR5.12)          │(both captains submit,
 *         ↓                                          │ submissions agree)
 *   rejected | expired                                ↓
 *                                              awaiting_owner
 *         ┌────────────────────────────────────────┐  │
 *         │(submissions conflict — ER2.1)          │  │(venue owner verifies:
 *         ↓                                        │  │ ELO exchange runs — ER2.2)
 *      disputed ←──(either captain, within 24h)────────completed
 *         │                                            FR5.17
 *         └─(admin resolves — S.7)──→ completed
 *
 * FOUR RULES THAT SHAPE EVERY HANDLER
 *
 *   1. THE BODY IS NEVER AUTHORITY. Which team the caller may act for is read
 *      from team_members inside the locked transaction (access.requireRole →
 *      lockTeam FOR UPDATE), never taken from the request. A client that sends
 *      `{"challengerTeam": someoneElsesTeam}` gets a 403, not a match.
 *
 *   2. LOCK, THEN DECIDE. Every transition does matchCore.lockMatch first. Two
 *      captains submitting the final result in the same instant would otherwise
 *      both see "one result in", both decide they are not the second, and leave
 *      the match stuck in `accepted` with two results and nobody to advance it.
 *
 *   3. A RETURN MUST NEVER LEAVE AN OPEN TRANSACTION. `finally` always releases,
 *      and every early exit rolls back first via `bail()`. A client released
 *      mid-BEGIN is handed to the next request still inside that transaction —
 *      a cross-request corruption bug, not a slow query.
 *
 *   4. EMIT AFTER COMMIT, ALWAYS. Sockets and chat pills flush once the row is
 *      durable. Emitting inside the transaction tells a client to re-fetch a row
 *      that is not committed yet, and it reads the old one.
 *
 * WHAT IS DELIBERATELY *NOT* HERE
 *   • Admin dispute resolution. S.7 owns that UI; this file's job is to make
 *     sure a disputed match cannot have ELO applied to it in the meantime.
 *   • Any score override by the venue owner. The owner VERIFIES what two
 *     captains already agreed on; adjudicating a disagreement is the admin's
 *     job, and giving the owner a pen here would make the "both captains agree"
 *     gate decorative.
 */

const express = require('express');
const pool = require('../db/pool');
const auth = require('../middleware/authMiddleware');
const access = require('../utils/teamAccess');
const mc = require('../utils/matchCore');
const elo = require('../utils/elo');
const settings = require('../utils/globalSettings');
const teamStats = require('../utils/teamStats');
const ml = require('../services/mlClient');
const bus = require('../realtime/bus');
const { PREVIEW_LABEL } = require('../utils/matchPreview');
const { notify } = require('../utils/notify');
const { recomputeForMatch } = require('../utils/trustScore');

const router = express.Router();
router.use(auth);

const { STATUS, LIVE_STATUSES } = mc;

/**
 * Normalise an id from the wire.
 *
 * Lowercased because Postgres returns uuids lowercase, and matchCore's lookup maps
 * are keyed on that string. A client that sends `A1B2-…` in caps would otherwise
 * pass isUuid(), reach a `features.get()` that misses, and be told its own team
 * does not exist.
 */
const uuid = (v) => String(v ?? '').trim().toLowerCase();

// ─── Envelope helpers (same shape as routes/teams.js) ───────────────────────
const fail = (res, status, message) => res.status(status).json({ success: false, message });
const ok = (res, data, message) => res.json({ success: true, data, ...(message ? { message } : {}) });

/** Roll back, then answer — the only safe way to leave an open transaction. */
async function bail(client, res, status, message) {
  await client.query('ROLLBACK').catch(() => {});
  return fail(res, status, message);
}

/**
 * Turn the DB errors this flow can legitimately produce into friendly envelopes.
 *
 * Keyed on the constraint NAME rather than just the SQLSTATE, because three
 * different unique violations reach here and "already exists" is useless as an
 * answer to all three. Anything unrecognised returns null and goes to next(e),
 * which answers a generic 500 — never a raw SQL string (golden rule 5).
 */
function friendlyDbError(e) {
  if (e.code === '23505') {
    switch (e.constraint) {
      case 'ux_matches_booking_live':
        return { status: 409, message: 'That slot already has a match on it.' };
      case 'match_results_match_id_submitted_by_team_key':
        return { status: 409, message: 'Your team has already submitted a result for this match.' };
      case 'ux_disputes_match_team':
        return { status: 409, message: 'Your team has already disputed this match.' };
      case 'ux_elo_history_team_match':
        return { status: 409, message: 'This match has already been rated.' };
      default:
        return { status: 409, message: 'That has already been recorded.' };
    }
  }
  if (e.code === '23514') return { status: 400, message: 'That is not a valid match update.' };
  if (e.code === '22P02') return { status: 404, message: 'Not found.' }; // bad uuid
  return null;
}

async function nameOf(client, userId) {
  if (!userId) return null;
  const { rows } = await client.query('SELECT name FROM users WHERE id = $1', [userId]);
  return rows[0]?.name || null;
}

// ─── Input validation ───────────────────────────────────────────────────────

/**
 * A scoreline component.
 *
 * Validated with a regex rather than parseInt, because `parseInt('3abc')` is 3
 * and `parseInt('3.9')` is 3 — both would silently accept a client bug and store
 * a number the user did not type. 999 is the ceiling because cricket scores are
 * runs, not goals, and a three-figure innings is ordinary.
 */
const SCORE_MAX = 999;
const RE_SCORE = /^\d{1,3}$/;

function parseScore(raw, label) {
  if (raw === undefined || raw === null || raw === '') {
    return { ok: false, message: `${label} is required.` };
  }
  const s = typeof raw === 'number' ? String(raw) : String(raw).trim();
  if (!RE_SCORE.test(s)) {
    return { ok: false, message: `${label} must be a whole number from 0 to ${SCORE_MAX}.` };
  }
  return { ok: true, value: Number.parseInt(s, 10) };
}

const DISPUTE_REASON_MIN = 10;
const DISPUTE_REASON_MAX = 500;

function parseDisputeReason(raw) {
  const value = access.squashMultiline(raw ?? '');
  if (value.length < DISPUTE_REASON_MIN) {
    return { ok: false, message: `Please explain the problem in at least ${DISPUTE_REASON_MIN} characters.` };
  }
  if (value.length > DISPUTE_REASON_MAX) {
    return { ok: false, message: `Please keep it under ${DISPUTE_REASON_MAX} characters.` };
  }
  return { ok: true, value };
}

/**
 * How many unanswered challenges one team may have out at once.
 *
 * Not in the spec, but every live challenge PINS A BOOKING (one live match per
 * booking, migration 016) and fires a notification at another captain. Without a
 * cap, one compromised account can paper every public team in its sport with
 * challenges and lock up its own slots for 48 hours at a time. Ten is far above
 * what a real squad does in a week.
 */
const MAX_LIVE_CHALLENGES = 10;

// ═══════════════════════════════════════════════════════════════════════════
// READS
//
// Registered before `/:id` — Express matches in registration order, so a literal
// path declared after a param route is unreachable ("preview" would arrive as an
// id and 404 as a malformed uuid).
// ═══════════════════════════════════════════════════════════════════════════

/**
 * GET /api/matches/preview?challengerTeam=&opponentTeam=
 *
 * Everything the challenge screen shows BEFORE anything is created: both teams'
 * ratings and records, the competitiveness score (FR5.4) and the generated
 * preview sentence (FR5.10).
 *
 * A separate endpoint rather than computing it client-side because the inputs
 * (last-5 form, both current ratings) are server data, and because the numbers
 * on the screen must be produced by the same code that will later be stored on
 * the row — a client-side estimate that disagreed with the stored snapshot would
 * look like a bug in whichever one the user saw second.
 */
router.get('/preview', async (req, res, next) => {
  const a = uuid(req.query.challengerTeam || req.query.teamId);
  const b = uuid(req.query.opponentTeam);
  if (!access.isUuid(a) || !access.isUuid(b)) return fail(res, 400, 'Two team ids are required.');
  if (a === b) return fail(res, 400, 'A team cannot play itself.');

  const client = await pool.connect();
  try {
    // Read-only, but the membership check still has to happen: a preview leaks
    // another team's form and rating, so only someone who could actually send
    // this challenge may see it.
    const role = await mc.roleInTeam(client, a, req.user.id);
    if (!role) return fail(res, 403, 'You are not a member of that team.');

    const features = await mc.teamFeatures(client, [a, b]);
    const challenger = features.get(a);
    const opponent = features.get(b);
    if (!challenger || !opponent) return fail(res, 404, 'Team not found.');
    if (challenger.sport !== opponent.sport) {
      return fail(res, 400, 'Both teams must play the same sport.');
    }
    if (opponent.visibility !== 'public' && !(await mc.roleInTeam(client, b, req.user.id))) {
      return fail(res, 403, 'That team is private.');
    }

    const { base } = await settings.elo({ client });
    const { competitiveness, previewText } = mc.deriveCompAndPreview({
      challenger, opponent, seed: `${a}:${b}`,
    });

    const shape = (t) => ({
      id: t.id,
      name: t.name,
      logoUrl: t.logoUrl,
      city: t.city,
      sport: t.sport,
      elo: t.elo || base,
      ranked: elo.isRanked(t),
      displayElo: elo.displayElo(t, base),
      played: t.wins + t.losses + t.draws,
      wins: t.wins,
      losses: t.losses,
      draws: t.draws,
      form: t.form,
      memberCount: t.memberCount,
      ...mc.trustBadge(t.trustScore),
      eloFrozen: t.eloFrozen,
    });

    return ok(res, {
      challenger: shape(challenger),
      opponent: shape(opponent),
      competitiveness,
      previewText,
      previewLabel: PREVIEW_LABEL,
      eloGap: Math.abs((challenger.elo || base) - (opponent.elo || base)),
      // FR5.3 — the band the recommender prefers, so the screen can say why a
      // pairing is or is not a natural one.
      withinPreferredBand:
        Math.abs((challenger.elo || base) - (opponent.elo || base)) <= elo.PREFERRED_ELO_BAND,
      preferredBand: elo.PREFERRED_ELO_BAND,
    });
  } catch (e) {
    const f = friendlyDbError(e);
    return f ? fail(res, f.status, f.message) : next(e);
  } finally {
    client.release();
  }
});

/**
 * GET /api/matches/linkable-bookings?teamId=
 *
 * The venue picker on the challenge screen (FR5.11): the caller's own CONFIRMED,
 * still-in-the-future bookings that no live match is already using.
 *
 * Filtered server-side, not in the app. A client-side filter would eventually
 * offer a slot that another challenge claimed thirty seconds ago, and the user
 * would pick it and get a 409 for a reason they could not see.
 */
router.get('/linkable-bookings', async (req, res, next) => {
  const teamId = uuid(req.query.teamId);
  if (teamId && !access.isUuid(teamId)) return fail(res, 400, 'Invalid team.');

  const client = await pool.connect();
  try {
    let sport = null;
    if (teamId) {
      const role = await mc.roleInTeam(client, teamId, req.user.id);
      if (!role) return fail(res, 403, 'You are not a member of that team.');
      const { rows } = await client.query(
        'SELECT sport::text AS sport FROM teams WHERE id = $1', [teamId],
      );
      sport = rows[0]?.sport || null;
    }

    // The sport filter is applied only when the venue's own sport_type is one of
    // the team sports. Venue rows predate this flow and some carry free-text
    // values, so an unrecognised sport_type must not hide a usable booking.
    const { rows } = await client.query(
      `SELECT b.id, b.slot_date, b.start_time, b.end_time, b.total_amount,
              b.status::text AS status,
              v.id AS venue_id, v.name AS venue_name, v.city AS venue_city,
              v.sport_type
         FROM bookings b
         JOIN venues v ON v.id = b.venue_id
        WHERE b.player_id = $1
          AND b.status = 'confirmed'
          AND (b.slot_date::DATE + b.start_time::TIME) > (NOW() AT TIME ZONE $2)
          AND NOT EXISTS (
                SELECT 1 FROM matches m
                 WHERE m.booking_id = b.id AND m.status = ANY($3::text[])
              )
          AND ($4::text IS NULL
               OR lower(v.sport_type) NOT IN ('football', 'cricket')
               OR lower(v.sport_type) = $4)
        ORDER BY b.slot_date, b.start_time
        LIMIT 50`,
      [req.user.id, mc.TIMEZONE, LIVE_STATUSES, sport],
    );

    return ok(res, rows.map((r) => ({
      id: r.id,
      slotDate: r.slot_date,
      startTime: r.start_time,
      endTime: r.end_time,
      totalAmount: r.total_amount,
      status: r.status,
      venueId: r.venue_id,
      venueName: r.venue_name,
      venueCity: r.venue_city,
      venueSport: r.sport_type,
    })));
  } catch (e) {
    const f = friendlyDbError(e);
    return f ? fail(res, f.status, f.message) : next(e);
  } finally {
    client.release();
  }
});

/**
 * GET /api/matches/owner/pending
 *
 * The owner's "Match results to verify" queue: `awaiting_owner` matches on
 * venues this account owns, each with BOTH submissions attached so the verify
 * screen can show what the two captains said side by side.
 *
 * Authority is `v.owner_id = $1` in the WHERE clause, not a role check on the
 * token. Ownership of the specific venue is the actual permission, and enforcing
 * it in the query means a player who calls this gets an empty list rather than a
 * list filtered by something else.
 */
router.get('/owner/pending', async (req, res, next) => {
  try {
    const { rows } = await pool.query(
      `SELECT ${mc.MATCH_VIEW_COLUMNS} ${mc.MATCH_VIEW_FROM}
        WHERE m.status = $2 AND v.owner_id = $1
        ORDER BY b.slot_date DESC, b.start_time DESC
        LIMIT 50`,
      [req.user.id, STATUS.AWAITING_OWNER],
    );
    if (!rows.length) return ok(res, []);

    const { base } = await settings.elo();
    const ids = rows.map((r) => r.id);
    const { rows: subs } = await pool.query(
      `SELECT mr.match_id, mr.submitted_by_team, mr.winner_team,
              mr.score_challenger, mr.score_opponent, mr.created_at,
              t.name AS team_name
         FROM match_results mr
         JOIN teams t ON t.id = mr.submitted_by_team
        WHERE mr.match_id = ANY($1::uuid[])
        ORDER BY mr.created_at`,
      [ids],
    );
    const byMatch = new Map(ids.map((id) => [String(id), []]));
    for (const s of subs) {
      byMatch.get(String(s.match_id))?.push({
        teamId: s.submitted_by_team,
        teamName: s.team_name,
        winnerTeam: s.winner_team,
        scoreChallenger: mc.intOrNull(s.score_challenger),
        scoreOpponent: mc.intOrNull(s.score_opponent),
        submittedAt: s.created_at,
      });
    }

    return ok(res, rows.map((r) => ({
      ...mc.shapeMatch(r, { viewerUserId: req.user.id, base }),
      submissions: byMatch.get(String(r.id)) || [],
    })));
  } catch (e) {
    const f = friendlyDbError(e);
    return f ? fail(res, f.status, f.message) : next(e);
  }
});

/**
 * GET /api/matches/opponents?teamId=&q=
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
router.get('/opponents', async (req, res, next) => {
  const teamId = uuid(req.query.teamId || req.query.team_id);
  if (!access.isUuid(teamId)) return fail(res, 400, 'Pick one of your teams first.');
  const q = access.squash(req.query.q || '');

  const client = await pool.connect();
  try {
    const role = await mc.roleInTeam(client, teamId, req.user.id);
    if (!role) return fail(res, 403, 'You are not a member of that team.');

    const features = await mc.teamFeatures(client, [teamId]);
    const me = features.get(teamId);
    if (!me) return fail(res, 404, 'Team not found.');

    const { base } = await settings.elo({ client });
    const myElo = me.elo || base;

    const params = [req.user.id, teamId, me.sport, myElo];
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

    return ok(res, {
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
    });
  } catch (e) {
    const f = friendlyDbError(e);
    return f ? fail(res, f.status, f.message) : next(e);
  } finally {
    client.release();
  }
});

/**
 * GET /api/matches?team_id=
 *
 * Everything the Match Center renders, in one round trip, bucketed for its three
 * tabs (FR5.16).
 *
 * ONE QUERY, BUCKETED IN JS — deliberately. The four buckets are four filters
 * over the same rows and the same joins, so four queries would repeat the whole
 * MATCH_VIEW join four times for a screen that is opened constantly. It also puts
 * the "is this challenge still live?" rule in one readable place instead of
 * duplicating a timestamp comparison across four WHERE clauses that would then
 * have to be kept in agreement.
 */
router.get('/', async (req, res, next) => {
  const teamId = uuid(req.query.team_id || req.query.teamId);
  if (!access.isUuid(teamId)) return fail(res, 400, 'A team id is required.');

  const client = await pool.connect();
  try {
    // Membership is the gate: a team's fixture list exposes who it is playing,
    // when, and where, which is not public information for a private team.
    const role = await mc.roleInTeam(client, teamId, req.user.id);
    if (!role) return fail(res, 403, 'You are not a member of this team.');

    const { base } = await settings.elo({ client });
    const { rows } = await client.query(
      `SELECT ${mc.MATCH_VIEW_COLUMNS} ${mc.MATCH_VIEW_FROM}
        WHERE m.challenger_team = $1 OR m.opponent_team = $1
        ORDER BY COALESCE(m.verified_at, m.responded_at, m.created_at) DESC
        LIMIT 200`,
      [teamId],
    );

    const now = Date.now();
    const out = { incoming: [], outgoing: [], upcoming: [], history: [] };
    for (const r of rows) {
      const m = mc.shapeMatch(r, {
        viewerTeamIds: [teamId], viewerUserId: req.user.id, base,
      });
      const expiresAt = r.challenge_expires_at ? new Date(r.challenge_expires_at).getTime() : null;

      if (r.status === STATUS.CHALLENGE_SENT) {
        // An expired-but-not-yet-swept challenge is history, not a live one. The
        // sweep runs every few minutes; the UI must not offer Accept in between.
        if (expiresAt !== null && expiresAt <= now) {
          out.history.push({ ...m, effectiveStatus: STATUS.EXPIRED });
        } else if (String(r.opponent_team) === teamId) {
          out.incoming.push(m);
        } else {
          out.outgoing.push(m);
        }
      } else if (
        r.status === STATUS.ACCEPTED
        || r.status === STATUS.AWAITING_RESULTS
        || r.status === STATUS.AWAITING_OWNER
      ) {
        out.upcoming.push(m);
      } else {
        out.history.push(m);
      }
    }

    // Upcoming reads forwards in time — the next fixture belongs at the top.
    out.upcoming.sort((x, y) => {
      const a = x.booking?.slotDate ? `${x.booking.slotDate}T${x.booking.startTime}` : '';
      const b = y.booking?.slotDate ? `${y.booking.slotDate}T${y.booking.startTime}` : '';
      return a < b ? -1 : a > b ? 1 : 0;
    });

    const { disputeWindowHours } = await settings.match({ client });
    return ok(res, {
      teamId,
      myRole: role,
      challenges: { incoming: out.incoming, outgoing: out.outgoing },
      upcoming: out.upcoming,
      history: out.history,
      // Shipped so the History tab can decide whether to draw the dispute flag
      // (FR5.17) without hard-coding 24 in Dart, where an admin change to the
      // setting could never reach it.
      disputeWindowHours,
    });
  } catch (e) {
    const f = friendlyDbError(e);
    return f ? fail(res, f.status, f.message) : next(e);
  } finally {
    client.release();
  }
});

// ═══════════════════════════════════════════════════════════════════════════
// POST /api/matches/challenge          (FR5.8 – FR5.12)
// ═══════════════════════════════════════════════════════════════════════════
router.post('/challenge', async (req, res, next) => {
  const challengerTeam = uuid(req.body.challengerTeam || req.body.teamId);
  const opponentTeam = uuid(req.body.opponentTeam);
  const bookingId = uuid(req.body.bookingId);

  if (!access.isUuid(challengerTeam)) return fail(res, 400, 'Choose which of your teams is challenging.');
  if (!access.isUuid(opponentTeam)) return fail(res, 400, 'Choose a team to challenge.');
  if (!access.isUuid(bookingId)) return fail(res, 400, 'Choose one of your confirmed bookings for this match.');
  if (challengerTeam === opponentTeam) return fail(res, 400, 'A team cannot challenge itself.');

  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    // 1. Authority. Locks the challenging team and re-reads the caller's role
    //    from team_members inside this transaction (FR2.10: role, not captain_id).
    const gate = await access.requireRole(client, challengerTeam, req.user.id, 'captain');
    if (gate.error) return bail(client, res, gate.error.status, gate.error.message);

    // 2. Both teams' features, in one query — needed for the sport check, the
    //    competitiveness score and the preview.
    const features = await mc.teamFeatures(client, [challengerTeam, opponentTeam]);
    const challenger = features.get(challengerTeam);
    const opponent = features.get(opponentTeam);
    if (!opponent) return bail(client, res, 404, 'That team no longer exists.');
    if (challenger.sport !== opponent.sport) {
      return bail(client, res, 400, 'Both teams must play the same sport.');
    }
    // A private team is not in the opponent list at all; reaching one by id is
    // either a stale screen or someone guessing, and both get the same answer.
    if (opponent.visibility !== 'public'
        && !(await mc.roleInTeam(client, opponentTeam, req.user.id))) {
      return bail(client, res, 403, 'That team is not accepting challenges.');
    }
    if (!(await mc.captainIdsOf(client, [opponentTeam])).get(opponentTeam)?.length) {
      return bail(client, res, 409, 'That team has no captain to accept a challenge right now.');
    }

    // 3. Spam ceiling (see MAX_LIVE_CHALLENGES).
    const { rows: liveRows } = await client.query(
      `SELECT count(*)::int AS n FROM matches
        WHERE challenger_team = $1 AND status = $2 AND challenge_expires_at > now()`,
      [challengerTeam, STATUS.CHALLENGE_SENT],
    );
    if (liveRows[0].n >= MAX_LIVE_CHALLENGES) {
      return bail(client, res, 429,
        `You already have ${MAX_LIVE_CHALLENGES} challenges waiting for a reply.`);
    }

    // 4. The booking (FR5.11). Every condition is in the WHERE clause so a
    //    booking that fails any of them is indistinguishable from one that does
    //    not exist — a caller must not learn about other people's bookings by
    //    probing ids and reading which error comes back.
    const { rows: bRows } = await client.query(
      `SELECT b.id, b.slot_date, b.start_time, b.end_time, b.status::text AS status,
              v.name AS venue_name, v.city AS venue_city, lower(v.sport_type) AS venue_sport,
              ((b.slot_date::DATE + b.start_time::TIME) > (NOW() AT TIME ZONE $3)) AS is_future
         FROM bookings b
         JOIN venues v ON v.id = b.venue_id
        WHERE b.id = $1 AND b.player_id = $2`,
      [bookingId, req.user.id, mc.TIMEZONE],
    );
    const booking = bRows[0];
    if (!booking) return bail(client, res, 404, 'Booking not found.');
    if (booking.status !== 'confirmed') {
      return bail(client, res, 409, 'Only a confirmed booking can host a match.');
    }
    if (!booking.is_future) {
      return bail(client, res, 409, 'That slot has already started. Pick an upcoming booking.');
    }
    if (['football', 'cricket'].includes(booking.venue_sport)
        && booking.venue_sport !== challenger.sport) {
      return bail(client, res, 400, 'That venue is not for this sport.');
    }

    // 5. Friendly version of what ux_matches_booking_live enforces. The index is
    //    what actually holds under a double tap; this exists so the ordinary case
    //    reads as a sentence instead of a constraint name.
    const { rows: taken } = await client.query(
      `SELECT 1 FROM matches WHERE booking_id = $1 AND status = ANY($2::text[]) LIMIT 1`,
      [bookingId, LIVE_STATUSES],
    );
    if (taken.length) {
      return bail(client, res, 409, 'You already have a match on that slot.');
    }

    // 6. The two snapshots (FR5.4, FR5.10). Seeded on the three ids rather than
    //    the match id, which does not exist yet — same inputs always produce the
    //    same sentence, which is what makes it storable.
    const { competitiveness, previewText } = mc.deriveCompAndPreview({
      challenger, opponent, seed: `${challengerTeam}:${opponentTeam}:${bookingId}`,
    });

    const { challengeTtlHours } = await settings.match({ client });

    // 7. Insert. The deadline is the EARLIER of "now + TTL" and kickoff: a
    //    challenge that outlives the slot it is for cannot be accepted usefully,
    //    and would keep the booking pinned past the point of no return.
    const { rows: ins } = await client.query(
      `INSERT INTO matches
         (challenger_team, opponent_team, booking_id, sport, status,
          challenge_expires_at, competitiveness, preview_text, created_by, updated_at)
       SELECT $1, $2, $3, $4, $5,
              LEAST(now() + ($6 || ' hours')::interval,
                    ((b.slot_date::DATE + b.start_time::TIME) AT TIME ZONE $7)),
              $8, $9, $10, now()
         FROM bookings b WHERE b.id = $3
       RETURNING id, challenge_expires_at`,
      [
        challengerTeam, opponentTeam, bookingId, challenger.sport, STATUS.CHALLENGE_SENT,
        String(challengeTtlHours), mc.TIMEZONE,
        competitiveness, previewText, req.user.id,
      ],
    );
    const matchId = ins[0].id;

    // 8. Fan out. The two teams get different sentences on purpose — "you
    //    challenged them" and "they challenged you" are different facts.
    const actorName = await nameOf(client, req.user.id);
    const when = `${booking.slot_date instanceof Date
      ? booking.slot_date.toISOString().slice(0, 10)
      : String(booking.slot_date).slice(0, 10)} at ${String(booking.start_time).slice(0, 5)}`;
    const { pills, memberIds } = await mc.fanOut(client, {
      matchId,
      sides: [
        {
          teamId: challengerTeam,
          event: 'match_challenge_sent',
          actorId: req.user.id,
          actorName,
          otherTeamName: opponent.name,
        },
        {
          teamId: opponentTeam,
          event: 'match_challenge_received',
          otherTeamName: challenger.name,
          notify: {
            type: 'match_challenge',
            title: `${challenger.name} challenged ${opponent.name}`,
            body: `${booking.venue_name || 'A venue'}, ${when}. Reply within `
              + `${Math.round(challengeTtlHours)}h.`,
            extra: { competitiveness, opponentTeam: challengerTeam },
          },
        },
      ],
    });

    await client.query('COMMIT');
    await mc.emitAfterCommit(client, { matchId, pills, memberIds, extra: { event: 'challenge' } });

    const { base } = await settings.elo();
    const view = await mc.fetchMatchView(pool, matchId);
    return ok(
      res,
      mc.shapeMatch(view, { viewerTeamIds: [challengerTeam], viewerUserId: req.user.id, base }),
      'Challenge sent.',
    );
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    const f = friendlyDbError(e);
    return f ? fail(res, f.status, f.message) : next(e);
  } finally {
    client.release();
  }
});

// ═══════════════════════════════════════════════════════════════════════════
// GET /api/matches/:id
// ═══════════════════════════════════════════════════════════════════════════
router.get('/:id', async (req, res, next) => {
  const id = uuid(req.params.id);
  if (!access.isUuid(id)) return fail(res, 404, 'Match not found.');

  const client = await pool.connect();
  try {
    const row = await mc.fetchMatchView(client, id);
    if (!row) return fail(res, 404, 'Match not found.');

    // Three parties may read a match: a member of either team, and the owner of
    // the venue it is booked at (who has to verify it).
    const mine = await mc.myTeamsAmong(
      client, [row.challenger_team, row.opponent_team], req.user.id,
    );
    const isOwner = row.venue_owner && String(row.venue_owner) === String(req.user.id);
    if (!mine.length && !isOwner) return fail(res, 403, 'You cannot view this match.');

    const { base } = await settings.elo({ client });
    const { disputeWindowHours } = await settings.match({ client });

    // Submissions are visible to the owner (who must compare them) and to the
    // teams once BOTH are in. Showing the opponent's submission while yours is
    // still missing would let a captain copy it, which is exactly the agreement
    // the two-submission rule is supposed to be evidence of.
    const { rows: subs } = await client.query(
      `SELECT mr.submitted_by_team, mr.winner_team, mr.score_challenger,
              mr.score_opponent, mr.created_at, t.name AS team_name
         FROM match_results mr
         JOIN teams t ON t.id = mr.submitted_by_team
        WHERE mr.match_id = $1 ORDER BY mr.created_at`,
      [id],
    );
    const myTeamIds = mine.map((m) => String(m.team_id));
    const bothIn = subs.length >= 2;
    const visible = subs.filter((s) => isOwner || bothIn
      || myTeamIds.includes(String(s.submitted_by_team)));

    return ok(res, {
      ...mc.shapeMatch(row, {
        viewerTeamIds: mine.map((m) => m.team_id), viewerUserId: req.user.id, base,
      }),
      myRole: mine[0]?.role || null,
      submissions: visible.map((s) => ({
        teamId: s.submitted_by_team,
        teamName: s.team_name,
        winnerTeam: s.winner_team,
        scoreChallenger: mc.intOrNull(s.score_challenger),
        scoreOpponent: mc.intOrNull(s.score_opponent),
        submittedAt: s.created_at,
      })),
      iSubmitted: subs.some((s) => myTeamIds.includes(String(s.submitted_by_team))),
      disputeWindowHours,
    });
  } catch (e) {
    const f = friendlyDbError(e);
    return f ? fail(res, f.status, f.message) : next(e);
  } finally {
    client.release();
  }
});

// ═══════════════════════════════════════════════════════════════════════════
// PATCH /api/matches/:id/respond        (FE-4)
// ═══════════════════════════════════════════════════════════════════════════
router.patch('/:id/respond', async (req, res, next) => {
  const id = uuid(req.params.id);
  if (!access.isUuid(id)) return fail(res, 404, 'Match not found.');
  const action = String(req.body.action || '').toLowerCase().trim();
  if (!['accept', 'reject'].includes(action)) {
    return fail(res, 400, 'Action must be accept or reject.');
  }

  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const m = await mc.lockMatch(client, id);
    if (!m) return bail(client, res, 404, 'Match not found.');
    if (m.status !== STATUS.CHALLENGE_SENT) {
      return bail(client, res, 409, `This challenge has already been ${m.status === STATUS.REJECTED ? 'declined' : 'answered'}.`);
    }

    // Only the CHALLENGED team's captain may answer. Locks that team, so a
    // demotion cannot land between this check and the write.
    const gate = await access.requireRole(client, m.opponent_team, req.user.id, 'captain');
    if (gate.error) {
      return bail(client, res, gate.error.status === 403 ? 403 : gate.error.status,
        gate.error.status === 403
          ? 'Only the challenged team\'s captain can answer this.'
          : gate.error.message);
    }

    const features = await mc.teamFeatures(client, [m.challenger_team, m.opponent_team]);
    const challengerName = features.get(String(m.challenger_team))?.name || 'the other team';
    const opponentName = features.get(String(m.opponent_team))?.name || 'the other team';
    const actorName = await nameOf(client, req.user.id);

    // FR5.12 — expired in the window between the app rendering the card and this
    // request arriving. Settle the row rather than answering 409 against a
    // `challenge_sent` that is actually dead; otherwise the sweep never sees it
    // as expired-and-unannounced and the two teams keep a stale card.
    const expired = m.challenge_expires_at && new Date(m.challenge_expires_at).getTime() <= Date.now();
    if (expired) {
      await client.query(
        'UPDATE matches SET status = $2, updated_at = now() WHERE id = $1',
        [id, STATUS.EXPIRED],
      );
      const fan = await mc.fanOut(client, {
        matchId: id,
        sides: [
          { teamId: m.challenger_team, event: 'match_expired', otherTeamName: opponentName },
          { teamId: m.opponent_team, event: 'match_expired', otherTeamName: challengerName },
        ],
      });
      await client.query('COMMIT');
      await mc.emitAfterCommit(client, { matchId: id, ...fan, extra: { event: 'expired' } });
      return fail(res, 409, 'This challenge expired before it could be answered.');
    }

    const accepted = action === 'accept';
    await client.query(
      'UPDATE matches SET status = $2, responded_at = now(), updated_at = now() WHERE id = $1',
      [id, accepted ? STATUS.ACCEPTED : STATUS.REJECTED],
    );

    const event = accepted ? 'match_accepted' : 'match_rejected';
    const title = accepted
      ? `${opponentName} accepted your challenge`
      : `${opponentName} declined your challenge`;
    const { pills, memberIds } = await mc.fanOut(client, {
      matchId: id,
      sides: [
        {
          teamId: m.challenger_team,
          event,
          otherTeamName: opponentName,
          // FE-4: the challenger is the side that has been waiting, so this is
          // the notification that actually matters. Both sides get the pill.
          notify: {
            type: accepted ? 'match_accepted' : 'match_rejected',
            title,
            body: accepted
              ? 'Your match is confirmed. Submit the result once the slot is over.'
              : 'The slot is free again — you can challenge another team.',
            extra: { opponentTeam: m.opponent_team },
          },
        },
        {
          teamId: m.opponent_team,
          event,
          actorId: req.user.id,
          actorName,
          otherTeamName: challengerName,
          ...(accepted ? {
            notify: {
              type: 'match_accepted',
              title: `Match confirmed vs ${challengerName}`,
              body: 'Submit the result once the slot is over.',
              extra: { opponentTeam: m.challenger_team },
            },
          } : {}),
        },
      ],
    });

    await client.query('COMMIT');
    await mc.emitAfterCommit(client, {
      matchId: id, pills, memberIds, extra: { event: accepted ? 'accepted' : 'rejected' },
    });

    const { base } = await settings.elo();
    const view = await mc.fetchMatchView(pool, id);
    return ok(
      res,
      mc.shapeMatch(view, { viewerTeamIds: [m.opponent_team], viewerUserId: req.user.id, base }),
      accepted ? 'Challenge accepted.' : 'Challenge declined.',
    );
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    const f = friendlyDbError(e);
    return f ? fail(res, f.status, f.message) : next(e);
  } finally {
    client.release();
  }
});

// ═══════════════════════════════════════════════════════════════════════════
// POST /api/matches/:id/result          (ER2.1)
// ═══════════════════════════════════════════════════════════════════════════
router.post('/:id/result', async (req, res, next) => {
  const id = uuid(req.params.id);
  if (!access.isUuid(id)) return fail(res, 404, 'Match not found.');

  // Scores are always CHALLENGER-then-OPPONENT, never "us then them". A
  // submitter-relative scoreline would need flipping on read, and the flip would
  // eventually be forgotten in one of the places that reads it.
  const sc = parseScore(req.body.scoreChallenger, 'The challenger\'s score');
  const so = parseScore(req.body.scoreOpponent, 'The opponent\'s score');
  const bad = [sc, so].find((x) => !x.ok);
  if (bad) return fail(res, 400, bad.message);

  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const m = await mc.lockMatch(client, id);
    if (!m) return bail(client, res, 404, 'Match not found.');

    if (m.status === STATUS.AWAITING_OWNER) {
      return bail(client, res, 409, 'Both results are already in — the venue owner is verifying.');
    }
    if (m.status === STATUS.DISPUTED) {
      return bail(client, res, 409, 'This match is under review. Results are locked.');
    }
    if (m.status !== STATUS.ACCEPTED && m.status !== STATUS.AWAITING_RESULTS) {
      return bail(client, res, 409, 'Results can only be submitted for a confirmed match.');
    }
    // ER2.1 — the freeze. Once both submissions are in, nothing else is accepted,
    // whatever the status says.
    if (m.results_locked) {
      return bail(client, res, 409, 'Results for this match are locked.');
    }

    // Which side is the caller? Captain of exactly one of the two teams.
    const roles = await mc.myTeamsAmong(client, [m.challenger_team, m.opponent_team], req.user.id);
    const asCaptain = roles.find((r) => r.role === 'captain');
    if (!asCaptain) {
      return bail(client, res, 403, 'Only a captain of one of these teams can submit a result.');
    }
    const submittedByTeam = asCaptain.team_id;

    // The slot has to be over. Without this a captain could submit a scoreline
    // for a match that has not been played, and the opponent's only recourse
    // would be a dispute.
    const { rows: sRows } = await client.query(
      `SELECT ((b.slot_date::DATE + b.start_time::TIME) <= (NOW() AT TIME ZONE $2)) AS started,
              b.slot_date, b.start_time
         FROM bookings b WHERE b.id = $1`,
      [m.booking_id, mc.TIMEZONE],
    );
    if (m.booking_id && sRows[0] && sRows[0].started !== true) {
      return bail(client, res, 409, 'You can submit the result once the slot has started.');
    }

    // The winner is DERIVED from the scores, never taken from the body. If the
    // client also sent one, it has to agree — a picker that disagrees with the
    // steppers is a client bug, and silently trusting either one would record a
    // result the captain did not intend.
    const derivedWinner = sc.value > so.value ? m.challenger_team
      : (so.value > sc.value ? m.opponent_team : null);
    const claimed = req.body.winnerTeam;
    if (claimed !== undefined && claimed !== null && String(claimed).trim() !== '') {
      const c = uuid(claimed);
      if (!access.isUuid(c)) return bail(client, res, 400, 'Invalid winning team.');
      if (String(derivedWinner || '') !== c) {
        return bail(client, res, 400, 'The winner you picked does not match the score you entered.');
      }
    } else if (req.body.isDraw === true && derivedWinner !== null) {
      return bail(client, res, 400, 'A draw needs the two scores to be equal.');
    }

    await client.query(
      `INSERT INTO match_results
         (match_id, submitted_by_team, winner_team, score_challenger, score_opponent)
       VALUES ($1,$2,$3,$4,$5)`,
      [id, submittedByTeam, derivedWinner, sc.value, so.value],
    );

    const { rows: all } = await client.query(
      `SELECT submitted_by_team, winner_team, score_challenger, score_opponent
         FROM match_results WHERE match_id = $1 ORDER BY created_at`,
      [id],
    );

    const features = await mc.teamFeatures(client, [m.challenger_team, m.opponent_team]);
    const cName = features.get(String(m.challenger_team))?.name || 'the challenger';
    const oName = features.get(String(m.opponent_team))?.name || 'the opponent';
    const nameOfTeam = (tid) => (String(tid) === String(m.challenger_team) ? cName : oName);
    const actorName = await nameOf(client, req.user.id);
    const line = mc.scoreline(sc.value, so.value);

    let nextStatus = m.status;
    let outcome = 'waiting';
    let detail = null;

    if (all.length < 2) {
      // First submission. Nothing changes state; the other captain is nudged.
      const { pills, memberIds } = await mc.fanOut(client, {
        matchId: id,
        sides: [
          {
            teamId: submittedByTeam,
            event: 'match_result_submitted',
            actorId: req.user.id,
            actorName,
            otherTeamName: nameOfTeam(
              String(submittedByTeam) === String(m.challenger_team) ? m.opponent_team : m.challenger_team,
            ),
          },
          {
            teamId: String(submittedByTeam) === String(m.challenger_team)
              ? m.opponent_team : m.challenger_team,
            event: 'match_result_submitted',
            actorId: req.user.id,
            actorName,
            otherTeamName: nameOfTeam(submittedByTeam),
            notify: {
              type: 'match_result_pending',
              title: `${nameOfTeam(submittedByTeam)} submitted a result`,
              body: `They recorded ${cName} ${line} ${oName}. Submit yours to confirm it.`,
              extra: { needsResult: true },
            },
          },
        ],
      });
      await client.query(
        'UPDATE matches SET updated_at = now() WHERE id = $1', [id],
      );
      await client.query('COMMIT');
      await mc.emitAfterCommit(client, { matchId: id, pills, memberIds, extra: { event: 'result' } });
    } else {
      // Both in. Consistent → awaiting_owner. Conflicting → disputed.
      const [a, b] = all;
      const agrees = String(a.winner_team || '') === String(b.winner_team || '')
        && mc.intOrNull(a.score_challenger) === mc.intOrNull(b.score_challenger)
        && mc.intOrNull(a.score_opponent) === mc.intOrNull(b.score_opponent);

      if (agrees) {
        nextStatus = STATUS.AWAITING_OWNER;
        outcome = 'awaiting_owner';
        await client.query(
          `UPDATE matches
              SET status = $2, results_locked = TRUE, winner_team = $3,
                  score_challenger = $4, score_opponent = $5, updated_at = now()
            WHERE id = $1`,
          [id, nextStatus, a.winner_team, a.score_challenger, a.score_opponent],
        );
        detail = `${cName} ${mc.scoreline(a.score_challenger, a.score_opponent)} ${oName}`;

        const fan = await mc.fanOut(client, {
          matchId: id,
          sides: [
            {
              teamId: m.challenger_team, event: 'match_awaiting_owner',
              otherTeamName: oName, detail,
            },
            {
              teamId: m.opponent_team, event: 'match_awaiting_owner',
              otherTeamName: cName, detail,
            },
          ],
        });

        // The owner is the one who has to act next, so they are the one told.
        const { rows: own } = await client.query(
          `SELECT v.owner_id, v.name AS venue_name
             FROM bookings b JOIN venues v ON v.id = b.venue_id WHERE b.id = $1`,
          [m.booking_id],
        );
        if (own[0]?.owner_id) {
          await notify(client, {
            userId: own[0].owner_id,
            bookingId: m.booking_id,
            type: 'match_verify_pending',
            title: 'A match result needs your verification',
            body: `${cName} vs ${oName} at ${own[0].venue_name || 'your venue'} — ${detail}.`,
            payload: { matchId: id, venueName: own[0].venue_name || null },
          });
        }
        await client.query('COMMIT');
        await mc.emitAfterCommit(client, {
          matchId: id, ...fan, extra: { event: 'awaiting_owner' },
        });
        if (own[0]?.owner_id) {
          bus.emitToUsers(own[0].owner_id, 'match:update', { matchId: id, event: 'awaiting_owner' });
        }
      } else {
        nextStatus = STATUS.DISPUTED;
        outcome = 'disputed';
        await client.query(
          `UPDATE matches SET status = $2, results_locked = TRUE, updated_at = now()
            WHERE id = $1`,
          [id, nextStatus],
        );
        // A SYSTEM dispute: raised_by_team is NULL because neither team filed it.
        // This matters for ER2.3 — counting a conflict against both teams would
        // freeze an honest side for an opponent's typo.
        await client.query(
          `INSERT INTO disputes (match_id, raised_by_team, reason, status)
           VALUES ($1, NULL, $2, 'open')`,
          [id, `Submitted results do not match: ${nameOfTeam(a.submitted_by_team)} recorded `
            + `${mc.scoreline(a.score_challenger, a.score_opponent)}, `
            + `${nameOfTeam(b.submitted_by_team)} recorded `
            + `${mc.scoreline(b.score_challenger, b.score_opponent)}.`],
        );
        detail = 'the two submissions do not match';

        const fan = await mc.fanOut(client, {
          matchId: id,
          sides: [
            {
              teamId: m.challenger_team, event: 'match_disputed', otherTeamName: oName,
              notify: {
                type: 'match_disputed',
                title: 'Results do not match',
                body: `Your submission for ${cName} vs ${oName} differs from theirs. `
                  + 'An admin will review it — no rating change until then.',
              },
            },
            {
              teamId: m.opponent_team, event: 'match_disputed', otherTeamName: cName,
              notify: {
                type: 'match_disputed',
                title: 'Results do not match',
                body: `Your submission for ${cName} vs ${oName} differs from theirs. `
                  + 'An admin will review it — no rating change until then.',
              },
            },
          ],
        });
        await client.query('COMMIT');
        await mc.emitAfterCommit(client, { matchId: id, ...fan, extra: { event: 'disputed' } });
        // Trust Score 2.0 (ER2.5): a dispute changes both captains' dispute-free
        // rate, so recompute after the state is committed. Best-effort and out of
        // band — a recompute failure must never fail the result submission.
        recomputeForMatch(pool, id).catch((e) =>
          console.error('[matches] trust recompute (system dispute) failed:', e.message),
        );
      }
    }

    const { base } = await settings.elo();
    const view = await mc.fetchMatchView(pool, id);
    const messages = {
      waiting: 'Result submitted. Waiting for the other captain.',
      awaiting_owner: 'Result submitted — both captains agree. The venue owner will verify it.',
      disputed: 'Your result does not match theirs. An admin will review it.',
    };
    return ok(
      res,
      {
        ...mc.shapeMatch(view, {
          viewerTeamIds: [submittedByTeam], viewerUserId: req.user.id, base,
        }),
        outcome,
      },
      messages[outcome],
    );
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    const f = friendlyDbError(e);
    return f ? fail(res, f.status, f.message) : next(e);
  } finally {
    client.release();
  }
});

// ═══════════════════════════════════════════════════════════════════════════
// PATCH /api/matches/:id/verify         (ER2.2)
// ═══════════════════════════════════════════════════════════════════════════
router.patch('/:id/verify', async (req, res, next) => {
  const id = uuid(req.params.id);
  if (!access.isUuid(id)) return fail(res, 404, 'Match not found.');

  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const m = await mc.lockMatch(client, id);
    if (!m) return bail(client, res, 404, 'Match not found.');

    if (m.status === STATUS.COMPLETED) {
      return bail(client, res, 409, 'This match has already been verified.');
    }
    if (m.status === STATUS.DISPUTED) {
      // The backend rule S.7's UI relies on: a disputed match cannot be rated.
      return bail(client, res, 409, 'This match is disputed. An admin has to resolve it first.');
    }
    if (m.status !== STATUS.AWAITING_OWNER) {
      return bail(client, res, 409, 'This match is not waiting for verification.');
    }
    // Idempotency latch. A retried request (flaky network, double tap) must not
    // run the exchange twice — two applications are undetectable afterwards.
    if (m.elo_applied) {
      return bail(client, res, 409, 'This match has already been rated.');
    }

    // Authority: the owner of the venue this match is booked at. Expressed as a
    // WHERE clause so ownership of THIS venue is the permission, not a role claim.
    if (!m.booking_id) {
      return bail(client, res, 409, 'This match has no linked booking to verify against.');
    }
    const { rows: ownRows } = await client.query(
      `SELECT v.owner_id, v.name AS venue_name
         FROM bookings b JOIN venues v ON v.id = b.venue_id
        WHERE b.id = $1 AND v.owner_id = $2`,
      [m.booking_id, req.user.id],
    );
    if (!ownRows.length) {
      return bail(client, res, 403, 'Only the venue owner can verify this match.');
    }

    // Nothing to rate if the agreed result never made it onto the row.
    if (m.score_challenger === null || m.score_opponent === null) {
      return bail(client, res, 409, 'This match has no agreed scoreline yet.');
    }

    const features = await mc.teamFeatures(client, [m.challenger_team, m.opponent_team]);
    const cName = features.get(String(m.challenger_team))?.name || 'the challenger';
    const oName = features.get(String(m.opponent_team))?.name || 'the opponent';

    const { base, kFactor } = await settings.elo({ client });

    // The rating exchange. Participates in THIS transaction — a rating that
    // committed separately could survive a rolled-back verification, and every
    // future match for both teams would compute from a rating describing a match
    // that never officially happened.
    const exchange = await elo.applyResult(client, {
      matchId: id,
      challengerTeam: m.challenger_team,
      opponentTeam: m.opponent_team,
      winnerTeam: m.winner_team,
      base,
      kFactor,
    });

    await client.query(
      `UPDATE matches
          SET status = $2, verified_by = $3, verified_at = now(),
              elo_applied = TRUE, updated_at = now()
        WHERE id = $1`,
      [id, STATUS.COMPLETED, req.user.id],
    );

    const line = mc.scoreline(m.score_challenger, m.score_opponent);
    const wordFor = (teamId) => {
      if (m.winner_team === null) return 'draw';
      return String(m.winner_team) === String(teamId) ? 'win' : 'loss';
    };
    const detailFor = (teamId, side) => {
      const word = wordFor(teamId);
      const head = `${cName} ${line} ${oName} (${word})`;
      return exchange.frozen
        ? `${head} — rating frozen, no change`
        : `${head}, ${mc.signed(side.delta)} ELO → ${side.after}`;
    };

    const { pills, memberIds } = await mc.fanOut(client, {
      matchId: id,
      sides: [
        {
          teamId: m.challenger_team,
          event: 'match_verified',
          otherTeamName: oName,
          detail: detailFor(m.challenger_team, exchange.challenger),
          notify: {
            type: 'match_verified',
            title: exchange.frozen
              ? `Match verified — ${cName} rating frozen`
              : `${mc.signed(exchange.challenger.delta)} ELO — now ${exchange.challenger.after}`,
            body: `${cName} ${line} ${oName}, verified by ${ownRows[0].venue_name || 'the venue'}.`,
            extra: {
              eloDelta: exchange.challenger.delta,
              eloAfter: exchange.challenger.after,
              frozen: exchange.frozen,
              teamName: cName,
            },
          },
        },
        {
          teamId: m.opponent_team,
          event: 'match_verified',
          otherTeamName: cName,
          detail: detailFor(m.opponent_team, exchange.opponent),
          notify: {
            type: 'match_verified',
            title: exchange.frozen
              ? `Match verified — ${oName} rating frozen`
              : `${mc.signed(exchange.opponent.delta)} ELO — now ${exchange.opponent.after}`,
            body: `${cName} ${line} ${oName}, verified by ${ownRows[0].venue_name || 'the venue'}.`,
            extra: {
              eloDelta: exchange.opponent.delta,
              eloAfter: exchange.opponent.after,
              frozen: exchange.frozen,
              teamName: oName,
            },
          },
        },
      ],
    });

    await client.query('COMMIT');
    await mc.emitAfterCommit(client, { matchId: id, pills, memberIds, extra: { event: 'verified' } });

    const view = await mc.fetchMatchView(pool, id);
    return ok(
      res,
      {
        ...mc.shapeMatch(view, { viewerUserId: req.user.id, base }),
        elo: {
          frozen: exchange.frozen,
          reason: exchange.reason,
          kFactor: exchange.kFactor,
          challenger: exchange.challenger,
          opponent: exchange.opponent,
        },
      },
      exchange.frozen
        ? 'Result verified. One of these teams has a frozen rating, so no points changed hands.'
        : 'Result verified and ratings updated.',
    );
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    const f = friendlyDbError(e);
    return f ? fail(res, f.status, f.message) : next(e);
  } finally {
    client.release();
  }
});

// ═══════════════════════════════════════════════════════════════════════════
// POST /api/matches/:id/dispute         (FR5.17, ER2.3)
// ═══════════════════════════════════════════════════════════════════════════
router.post('/:id/dispute', async (req, res, next) => {
  const id = uuid(req.params.id);
  if (!access.isUuid(id)) return fail(res, 404, 'Match not found.');
  const reason = parseDisputeReason(req.body.reason);
  if (!reason.ok) return fail(res, 400, reason.message);

  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const m = await mc.lockMatch(client, id);
    if (!m) return bail(client, res, 404, 'Match not found.');

    const { disputeWindowHours, disputeFreezeRatio, disputeFreezeMin } =
      await settings.match({ client });

    if (m.status === STATUS.DISPUTED) {
      return bail(client, res, 409, 'This match is already under review.');
    }
    // Disputable at two points: after the owner verifies (within the window), or
    // while it is sitting in the owner's queue — a result you know is wrong
    // should not have to be rated first before you can object to it.
    if (m.status !== STATUS.COMPLETED && m.status !== STATUS.AWAITING_OWNER) {
      return bail(client, res, 409, 'Only a completed or pending-verification match can be disputed.');
    }
    if (m.status === STATUS.COMPLETED) {
      const verifiedAt = m.verified_at ? new Date(m.verified_at).getTime() : null;
      const deadline = verifiedAt === null ? null : verifiedAt + disputeWindowHours * 3600_000;
      if (deadline !== null && Date.now() > deadline) {
        return bail(client, res, 409,
          `Disputes close ${Math.round(disputeWindowHours)} hours after a result is verified.`);
      }
    }

    const roles = await mc.myTeamsAmong(client, [m.challenger_team, m.opponent_team], req.user.id);
    const asCaptain = roles.find((r) => r.role === 'captain');
    if (!asCaptain) {
      return bail(client, res, 403, 'Only a captain of one of these teams can dispute this result.');
    }
    const raisedBy = asCaptain.team_id;

    const features = await mc.teamFeatures(client, [m.challenger_team, m.opponent_team]);
    const cName = features.get(String(m.challenger_team))?.name || 'the challenger';
    const oName = features.get(String(m.opponent_team))?.name || 'the opponent';
    const myName = String(raisedBy) === String(m.challenger_team) ? cName : oName;
    const actorName = await nameOf(client, req.user.id);

    await client.query(
      `INSERT INTO disputes (match_id, raised_by_team, reason, status)
       VALUES ($1, $2, $3, 'open')`,
      [id, raisedBy, reason.value],
    );

    // Freezes ELO if it has not been applied yet: `disputed` is not a status the
    // verify endpoint accepts, so the exchange can no longer run. If it HAS been
    // applied, the rating stands until an admin resolves it (S.7) — silently
    // reversing a verified result would move two ratings with no audit row
    // explaining why, and the elo_history ledger is the thing that makes a
    // rating explainable at all.
    await client.query(
      'UPDATE matches SET status = $2, updated_at = now() WHERE id = $1',
      [id, STATUS.DISPUTED],
    );

    // ER2.3 — the ratio check, on the team that raised it.
    const freeze = await mc.applyDisputeFreeze(client, raisedBy, {
      ratio: disputeFreezeRatio, min: disputeFreezeMin,
    });

    const otherTeam = String(raisedBy) === String(m.challenger_team)
      ? m.opponent_team : m.challenger_team;
    const otherName = String(raisedBy) === String(m.challenger_team) ? oName : cName;

    const { pills, memberIds } = await mc.fanOut(client, {
      matchId: id,
      sides: [
        {
          teamId: raisedBy,
          event: 'match_disputed',
          actorId: req.user.id,
          actorName,
          otherTeamName: otherName,
          ...(freeze.changed ? {
            notify: {
              type: 'elo_frozen',
              // Not "<name>'s rating" — half the team names in this league end
              // in an s ("Titans's" is what that produces) and a possessive is
              // not worth the special-casing when a preposition reads better.
              title: `Rating frozen for ${myName}`,
              body: freeze.reason
                + ' Ratings will not change until an admin reviews your disputes.',
              extra: { frozen: true, teamId: raisedBy },
            },
          } : {}),
        },
        {
          teamId: otherTeam,
          event: 'match_disputed',
          otherTeamName: myName,
          notify: {
            type: 'match_disputed',
            title: `${myName} disputed the result`,
            body: `${cName} vs ${oName} is under review. An admin will decide it.`,
            extra: { raisedByTeam: raisedBy },
          },
        },
      ],
    });

    await client.query('COMMIT');
    await mc.emitAfterCommit(client, { matchId: id, pills, memberIds, extra: { event: 'disputed' } });
    // Trust Score 2.0 (ER2.5): recompute both captains' scores now that the
    // dispute is committed. Best-effort and out of band — see the system-dispute
    // site above; a recompute failure must never fail the dispute filing.
    recomputeForMatch(pool, id).catch((e) =>
      console.error('[matches] trust recompute (manual dispute) failed:', e.message),
    );

    const { base } = await settings.elo();
    const view = await mc.fetchMatchView(pool, id);
    return ok(
      res,
      {
        ...mc.shapeMatch(view, {
          viewerTeamIds: [raisedBy], viewerUserId: req.user.id, base,
        }),
        eloFrozen: freeze.frozen,
        eloFrozenNow: freeze.changed,
      },
      freeze.changed
        ? 'Dispute filed. Your team has now disputed too many matches, so its rating is frozen pending review.'
        : 'Dispute filed. An admin will review this result.',
    );
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    const f = friendlyDbError(e);
    return f ? fail(res, f.status, f.message) : next(e);
  } finally {
    client.release();
  }
});

module.exports = router;
