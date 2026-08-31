/**
 * ELO rating engine  —  S.2 Wave B
 *
 * DELIBERATELY HAS NO DATABASE IMPORT.
 *
 * That is the single most important line in this file. `require('../db/pool')`
 * connects on import (pool.js runs `SELECT NOW()` at module load), so a rating
 * module that reached for the pool could not be unit-tested without a live
 * Supabase connection and an open handle that never lets the test process exit.
 * So: the arithmetic here is pure, `base` and `kFactor` are passed IN by the
 * caller (which reads them from `global_settings` via utils/globalSettings), and
 * the one function that touches Postgres — applyResult() — receives an
 * already-open client and never opens or commits a transaction of its own.
 *
 * WHY applyResult() DOES NOT BEGIN/COMMIT
 * The route that verifies a match already runs connect → BEGIN → … → COMMIT, and
 * the rating change must land in that same transaction as the match row's move
 * to `completed`. A rating that committed separately could survive a rolled-back
 * verification, and there is no way to un-ring that bell — every subsequent match
 * for both teams would be computed from a rating that describes a match that
 * never officially happened. So applyResult() is a *participant* in the caller's
 * transaction, not an owner of its own.
 *
 * THE ROUNDING PROBLEM (and why the exchange is forced zero-sum)
 * `newRating` rounds, and rounding each side independently does not conserve
 * points. Raw deltas are exact negatives (because sA + sB = 1 and eA + eB = 1),
 * but JS `Math.round` breaks ties toward +Infinity: round(r + 2.5) - r = +3
 * while round(r - 2.5) - r = -2. One point is minted from nothing, and over
 * thousands of matches the ladder inflates. So rate() rounds ONCE, on the
 * challenger's side, and mirrors it: deltaOpponent = -deltaChallenger. The pure
 * `newRating` stays exactly as specified (it is what the unit tests exercise);
 * conservation is a property of the *exchange*, enforced structurally rather
 * than hoped for. `elo.test.js` pins this.
 *
 * FR2.6 — UNRANKED UNTIL ONE VERIFIED MATCH
 * A new team's rating is `base` (1000) from the moment it is created, but 1000 is
 * a placeholder, not a measurement, so showing it next to a team that earned
 * 1000 over twenty matches would be a lie of equivalence. isRanked() gates
 * display, and it needs no extra column: wins/losses/draws are incremented in
 * exactly one place — applyResult, which only ever runs on a VERIFIED result —
 * so `wins + losses + draws >= 1` is precisely "has at least one verified match".
 */

/** S values. Anything else is a caller bug, not a user input. */
const OUTCOME = Object.freeze({ WIN: 1, DRAW: 0.5, LOSS: 0 });

/** FR2.6: a team is Unranked until it has this many verified matches. */
const RANKED_MIN_MATCHES = 1;

/** Competitiveness is reported on this closed band (see competitiveness()). */
const COMP_MIN = 5;
const COMP_MAX = 100;

/** The gap at which two teams are considered as mismatched as it gets. */
const COMP_GAP_CAP = 400;

/** FR5.3 — the band a suggested opponent should fall inside, preferentially. */
const PREFERRED_ELO_BAND = 400;

/** Why a rating row was written. Stored on elo_history.reason. */
const REASON = Object.freeze({
  VERIFIED: 'match_verified',
  FROZEN: 'frozen_no_change',
  // S.7 Wave D. An admin ruling on a dispute filed against an ALREADY-RATED
  // match has to move ratings that were already moved, and `elo_history` is the
  // thing that makes a rating explainable. So a correction writes both halves:
  // one row undoing this match's contribution, one row applying the ruled one.
  // Migration 021 widens chk_elo_history_reason to accept them.
  ADMIN_REVERSAL: 'admin_reversal',
  ADMIN_RULING: 'admin_ruling',
});

// ── Pure arithmetic ─────────────────────────────────────────────────────────

/**
 * Expected score for a team rated `ra` against a team rated `rb`.
 * Standard ELO logistic curve: a 400-point lead means a ~10:1 expectation.
 */
const expected = (ra, rb) => 1 / (1 + Math.pow(10, (rb - ra) / 400));

/**
 * New rating from an old rating, the actual score `s` (1 / 0.5 / 0), the
 * expected score `e`, and the K-factor.
 */
const newRating = (r, s, e, k) => Math.round(r + k * (s - e));

/** Finite-number coercion. A NaN reaching a rating column is unrecoverable. */
function num(v, fallback = 0) {
  const n = typeof v === 'number' ? v : Number.parseFloat(String(v));
  return Number.isFinite(n) ? n : fallback;
}

/**
 * One exchange, guaranteed zero-sum.
 *
 * `scoreChallenger` is S for the challenger (1 win / 0.5 draw / 0 loss); the
 * opponent's is its complement. Returns both new ratings, both deltas, and the
 * expectations that produced them — the expectations are what makes a rating
 * change explainable to a player who thinks it is wrong.
 */
function rate({ ratingChallenger, ratingOpponent, scoreChallenger, kFactor }) {
  const rc = Math.round(num(ratingChallenger));
  const ro = Math.round(num(ratingOpponent));
  const k = num(kFactor, 32);
  const sc = num(scoreChallenger);
  const so = 1 - sc;

  const ec = expected(rc, ro);
  const eo = expected(ro, rc);

  // Round once, on the challenger. The opponent mirrors it exactly, so the
  // ladder's total points are invariant. See the header note on rounding.
  const afterChallenger = newRating(rc, sc, ec, k);
  const deltaChallenger = afterChallenger - rc;
  // Negating 0 in JS yields -0, which is a real value that survives into JSON
  // formatting and can render as "-0" next to a drawn match. Normalised here
  // rather than in every display path.
  const deltaOpponent = deltaChallenger === 0 ? 0 : -deltaChallenger;

  return {
    challenger: {
      before: rc,
      after: rc + deltaChallenger,
      delta: deltaChallenger,
      expected: ec,
      score: sc,
    },
    opponent: {
      before: ro,
      after: ro + deltaOpponent,
      delta: deltaOpponent,
      expected: eo,
      score: so,
    },
    kFactor: k,
  };
}

/**
 * Translate a winner id into the pair of S values.
 * `winnerTeam === null` means a draw — the column is nullable for exactly that.
 */
function outcomeFor({ winnerTeam, challengerTeam, opponentTeam }) {
  if (winnerTeam === null || winnerTeam === undefined) {
    return { scoreChallenger: OUTCOME.DRAW, scoreOpponent: OUTCOME.DRAW, draw: true };
  }
  const w = String(winnerTeam);
  if (w === String(challengerTeam)) {
    return { scoreChallenger: OUTCOME.WIN, scoreOpponent: OUTCOME.LOSS, draw: false };
  }
  if (w === String(opponentTeam)) {
    return { scoreChallenger: OUTCOME.LOSS, scoreOpponent: OUTCOME.WIN, draw: false };
  }
  // Reachable only if a route forgot to validate. Loud, because silently
  // treating it as a draw would write a wrong rating that looks legitimate.
  throw new Error('winnerTeam must be one of the two teams in the match, or null for a draw');
}

// ── FR2.6 ranked / unranked ─────────────────────────────────────────────────

/** Verified matches played. Counts only what applyResult() has incremented. */
function playedCount(team) {
  if (!team) return 0;
  return num(team.wins) + num(team.losses) + num(team.draws);
}

/** FR2.6 — has this team earned a displayable rating yet? */
function isRanked(team) {
  return playedCount(team) >= RANKED_MIN_MATCHES;
}

/**
 * The rating to SHOW. `null` means the UI must render "Unranked" rather than a
 * number — returning null instead of 1000 makes it impossible for a screen to
 * accidentally display a placeholder as though it were earned.
 */
function displayElo(team, base = 1000) {
  if (!isRanked(team)) return null;
  return Math.round(num(team && team.elo, base));
}

// ── Competitiveness (deterministic v1; S.5 blends this into the recommender) ─

/**
 * comp = round(100 − (min(|a − b|, 400) / 400) × 95)   →  5 … 100
 *
 * Equal ratings score 100; a gap of 400 or more bottoms out at 5 rather than 0,
 * because "5% competitive" is honest about a thrashing while "0%" reads like
 * missing data.
 */
function competitiveness(eloA, eloB) {
  const gap = Math.min(Math.abs(num(eloA) - num(eloB)), COMP_GAP_CAP);
  const score = Math.round(COMP_MAX - (gap / COMP_GAP_CAP) * (COMP_MAX - COMP_MIN));
  return Math.max(COMP_MIN, Math.min(COMP_MAX, score));
}

/**
 * Competitiveness between two team ROWS, honouring FR2.6: if either side has no
 * verified match its rating is a placeholder, so any percentage computed from it
 * would be fabricated precision. `null` → the UI shows "Unranked".
 */
function competitivenessFor(teamA, teamB) {
  if (!isRanked(teamA) || !isRanked(teamB)) return null;
  return competitiveness(teamA.elo, teamB.elo);
}

// ── The one database-touching function ──────────────────────────────────────

/**
 * Lock both team rows in a deterministic order.
 *
 * Two matches being verified at the same instant that share a team (say A-vs-B
 * and B-vs-C) will deadlock if one transaction locks A then B while the other
 * locks B then A. Sorting the ids first means every transaction in the system
 * acquires these locks in the same sequence, which makes that deadlock
 * unreachable. Two explicit statements rather than one `ORDER BY … FOR UPDATE`
 * so the guarantee does not depend on how the planner places its LockRows node.
 */
async function lockBothTeams(client, idA, idB) {
  const [first, second] = [String(idA), String(idB)].sort();
  const cols = 'id, elo, wins, losses, draws, elo_frozen';
  const a = await client.query(`SELECT ${cols} FROM teams WHERE id = $1 FOR UPDATE`, [first]);
  const b = await client.query(`SELECT ${cols} FROM teams WHERE id = $1 FOR UPDATE`, [second]);

  const rows = [...a.rows, ...b.rows];
  const byId = new Map(rows.map((r) => [String(r.id), r]));
  return { challenger: byId.get(String(idA)), opponent: byId.get(String(idB)) };
}

/**
 * Apply a verified result: both ratings, both W/L/D counters, and TWO
 * elo_history rows — all inside the caller's transaction.
 *
 * ER2.3 — if EITHER team's rating is frozen (dispute-abuse ratio over the
 * threshold), the whole exchange is frozen, not just that team's half. Letting a
 * clean team collect points from a frozen one would make a frozen account a
 * points farm, and would also break zero-sum. W/L/D and the history rows are
 * still written, with delta 0 and reason `frozen_no_change`, so the audit trail
 * records that the match happened and explains why nothing moved.
 *
 * @returns {{challenger:object, opponent:object, frozen:boolean, kFactor:number}}
 */
async function applyResult(client, {
  matchId,
  challengerTeam,
  opponentTeam,
  winnerTeam = null,
  base = 1000,
  kFactor = 32,
}) {
  if (!client) throw new Error('applyResult requires an open pg client');
  if (!matchId || !challengerTeam || !opponentTeam) {
    throw new Error('applyResult requires matchId, challengerTeam and opponentTeam');
  }
  if (String(challengerTeam) === String(opponentTeam)) {
    throw new Error('a team cannot play itself');
  }

  const teams = await lockBothTeams(client, challengerTeam, opponentTeam);
  if (!teams.challenger || !teams.opponent) {
    throw new Error('one or both teams no longer exist');
  }

  const { scoreChallenger, draw } = outcomeFor({ winnerTeam, challengerTeam, opponentTeam });
  const frozen = Boolean(teams.challenger.elo_frozen || teams.opponent.elo_frozen);

  const beforeC = Math.round(num(teams.challenger.elo, base));
  const beforeO = Math.round(num(teams.opponent.elo, base));

  let exchange;
  if (frozen) {
    exchange = {
      challenger: { before: beforeC, after: beforeC, delta: 0, expected: expected(beforeC, beforeO), score: scoreChallenger },
      opponent: { before: beforeO, after: beforeO, delta: 0, expected: expected(beforeO, beforeC), score: 1 - scoreChallenger },
      kFactor: num(kFactor, 32),
    };
  } else {
    exchange = rate({
      ratingChallenger: beforeC,
      ratingOpponent: beforeO,
      scoreChallenger,
      kFactor,
    });
  }

  // W/L/D always move — a frozen rating does not mean the match did not happen.
  const counters = draw
    ? { c: 'draws', o: 'draws' }
    : scoreChallenger === OUTCOME.WIN
      ? { c: 'wins', o: 'losses' }
      : { c: 'losses', o: 'wins' };

  // `elo_rating` is the legacy DECIMAL from schema.sql. `elo` (int, from 013) is
  // the authority, but the older column is still selected by pre-S2 code, so it
  // is kept in lockstep rather than left to drift into a contradiction.
  //
  // The same number is bound TWICE on purpose. `elo` is integer and `elo_rating`
  // is numeric, and a single placeholder feeding both makes Postgres deduce two
  // conflicting types for one parameter (42P08, "integer versus numeric"). Two
  // placeholders let each column infer its own type, with no casts to get wrong.
  const writeTeam = (teamId, after, counterCol) => client.query(
    `UPDATE teams
        SET elo = $2,
            elo_rating = $3,
            ${counterCol} = COALESCE(${counterCol}, 0) + 1
      WHERE id = $1`,
    [teamId, after, after],
  );

  await writeTeam(challengerTeam, exchange.challenger.after, counters.c);
  await writeTeam(opponentTeam, exchange.opponent.after, counters.o);

  const reason = frozen ? REASON.FROZEN : REASON.VERIFIED;
  const writeHistory = (teamId, side) => client.query(
    `INSERT INTO elo_history
       (team_id, match_id, elo_before, elo_after, elo_delta, k_factor, reason)
     VALUES ($1, $2, $3, $4, $5, $6, $7)`,
    [teamId, matchId, side.before, side.after, side.delta, exchange.kFactor, reason],
  );

  await writeHistory(challengerTeam, exchange.challenger);
  await writeHistory(opponentTeam, exchange.opponent);

  return { ...exchange, frozen, reason };
}

// ═══════════════════════════════════════════════════════════════════════════
// S.7 Wave D — correcting a rating that was already applied
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Does this database accept the two labels a correction writes?
 *
 * `chk_elo_history_reason` is a CHECK, so an unwidened one raises 23514 in the
 * middle of the ruling transaction — after the scoreline is written, before the
 * bracket advances. That rolls back cleanly, but the admin is told "23514"
 * instead of "run migration 021", so `disputeService` asks this first.
 *
 * Only a POSITIVE answer is cached. Caching a negative would mean applying 021
 * had no effect until the server was restarted, which is exactly the kind of
 * "it's applied but it still doesn't work" that costs an evening.
 */
let correctionReady = false;
async function supportsCorrection(client) {
  if (correctionReady) return true;
  const { rows } = await client.query(
    `SELECT pg_get_constraintdef(oid) AS d FROM pg_constraint
      WHERE conrelid = 'public.elo_history'::regclass
        AND conname = 'chk_elo_history_reason'`,
  );
  // No CHECK at all means nothing to violate.
  const ok = rows.length === 0
    || (rows[0].d.includes(`'${REASON.ADMIN_REVERSAL}'`)
        && rows[0].d.includes(`'${REASON.ADMIN_RULING}'`));
  if (ok) correctionReady = true;
  return ok;
}

/**
 * Replace an applied result with a ruled one.
 *
 * WHY THIS IS A REVERSAL AND NOT AN EDIT
 * The disputed match is rarely the teams' last match. By the time an admin rules,
 * both sides may have played again, and their current ratings already fold those
 * in. Setting a rating back to `elo_history.elo_before` would silently delete
 * every match played since. So this subtracts THIS MATCH'S NET CONTRIBUTION from
 * the current rating — the discipline the money ledger already uses, where a
 * wrong entry is reversed rather than overwritten — and applies the ruled
 * exchange from there.
 *
 * The net is `SUM(elo_delta)` over every row this match has ever written, so a
 * second correction of the same match is also correct: whatever the first one
 * added, the sum contains it.
 *
 * Four rows land in `elo_history` (two per team) and
 * `SELECT * FROM elo_history WHERE match_id = … ORDER BY created_at` then reads
 * as the whole story: rated, undone, re-rated. That is the property the dispute
 * route's "no audit row explaining why" comment was protecting — it objected to
 * a SILENT reversal, not to an audited one.
 *
 * W/L/D COUNTERS move with it. The original application incremented one column
 * per team; this decrements those and increments the ruled ones, so a team whose
 * loss became a win does not end up carrying both. GREATEST(…, 0) guards a
 * counter that was never incremented in the first place.
 *
 * @returns {{frozen:boolean, kFactor:number, challenger:object, opponent:object}}
 *   Each side reports `before` (the rating this correction started from),
 *   `reversedTo`, `after`, `delta` (the visible movement, after − before) and
 *   `ruledDelta` (the exchange itself).
 */
async function correctResult(client, {
  matchId,
  challengerTeam,
  opponentTeam,
  previousWinnerTeam,
  winnerTeam = null,
  base = 1000,
  kFactor = 32,
}) {
  if (!client) throw new Error('correctResult requires an open pg client');
  if (!matchId || !challengerTeam || !opponentTeam) {
    throw new Error('correctResult requires matchId, challengerTeam and opponentTeam');
  }
  if (String(challengerTeam) === String(opponentTeam)) {
    throw new Error('a team cannot play itself');
  }

  const teams = await lockBothTeams(client, challengerTeam, opponentTeam);
  if (!teams.challenger || !teams.opponent) {
    throw new Error('one or both teams no longer exist');
  }

  // What this match has contributed to each rating so far.
  const { rows: netRows } = await client.query(
    `SELECT team_id, COALESCE(SUM(elo_delta), 0)::int AS net, count(*)::int AS n
       FROM elo_history
      WHERE match_id = $1 AND team_id = ANY($2::uuid[])
      GROUP BY team_id`,
    [matchId, [String(challengerTeam), String(opponentTeam)]],
  );
  const netOf = new Map(netRows.map((r) => [String(r.team_id), r]));
  const netC = netOf.get(String(challengerTeam)) || { net: 0, n: 0 };
  const netO = netOf.get(String(opponentTeam)) || { net: 0, n: 0 };

  const currentC = Math.round(num(teams.challenger.elo, base));
  const currentO = Math.round(num(teams.opponent.elo, base));
  const revertedC = currentC - netC.net;
  const revertedO = currentO - netO.net;

  const { scoreChallenger, draw } = outcomeFor({ winnerTeam, challengerTeam, opponentTeam });
  const frozen = Boolean(teams.challenger.elo_frozen || teams.opponent.elo_frozen);

  // A frozen side still gets its rows, at zero — the same shape `applyResult`
  // writes, so the two paths cannot disagree about what "frozen" looks like.
  const exchange = frozen
    ? {
      kFactor: num(kFactor, 32),
      challenger: {
        before: revertedC, after: revertedC, delta: 0, score: scoreChallenger,
        expected: expected(revertedC, revertedO),
      },
      opponent: {
        before: revertedO, after: revertedO, delta: 0, score: 1 - scoreChallenger,
        expected: expected(revertedO, revertedC),
      },
    }
    : rate({
      ratingChallenger: revertedC,
      ratingOpponent: revertedO,
      scoreChallenger,
      kFactor,
    });

  // ── Counters: −1 on what the old outcome recorded, +1 on the ruled one ─────
  const cols = (w) => {
    if (!w) return { c: null, o: null }; // a draw that was never a win/loss
    const o = outcomeFor({ winnerTeam: w, challengerTeam, opponentTeam });
    if (o.draw) return { c: 'draws', o: 'draws' };
    return o.scoreChallenger === OUTCOME.WIN
      ? { c: 'wins', o: 'losses' }
      : { c: 'losses', o: 'wins' };
  };
  // `winnerTeam = null` is a genuine draw on both sides of this comparison, and
  // `cols(null)` cannot tell that apart from "no previous outcome". So the ruled
  // side is derived from the outcome we already computed, and only the PREVIOUS
  // side is allowed to be unknown.
  const prev = previousWinnerTeam === undefined
    ? { c: null, o: null }
    : (previousWinnerTeam === null ? { c: 'draws', o: 'draws' } : cols(previousWinnerTeam));
  const next = draw
    ? { c: 'draws', o: 'draws' }
    : (scoreChallenger === OUTCOME.WIN
      ? { c: 'wins', o: 'losses' }
      : { c: 'losses', o: 'wins' });

  const moves = (oldCol, newCol) => {
    const m = { wins: 0, losses: 0, draws: 0 };
    if (oldCol) m[oldCol] -= 1;
    if (newCol) m[newCol] += 1;
    return m;
  };

  // `elo` and the legacy `elo_rating` are bound as TWO placeholders on purpose:
  // one placeholder used twice raises 42P08 on this driver.
  const writeTeam = (teamId, after, m) => client.query(
    `UPDATE teams
        SET elo = $2,
            elo_rating = $3,
            wins   = GREATEST(COALESCE(wins, 0)   + $4, 0),
            losses = GREATEST(COALESCE(losses, 0) + $5, 0),
            draws  = GREATEST(COALESCE(draws, 0)  + $6, 0)
      WHERE id = $1`,
    [teamId, after, after, m.wins, m.losses, m.draws],
  );

  await writeTeam(challengerTeam, exchange.challenger.after, moves(prev.c, next.c));
  await writeTeam(opponentTeam, exchange.opponent.after, moves(prev.o, next.o));

  // ── Two history rows per team ─────────────────────────────────────────────
  const writeHistory = (teamId, before, after, delta, reason) => client.query(
    `INSERT INTO elo_history
       (team_id, match_id, elo_before, elo_after, elo_delta, k_factor, reason)
     VALUES ($1, $2, $3, $4, $5, $6, $7)`,
    [teamId, matchId, before, after, delta, exchange.kFactor, reason],
  );

  // The reversal row is written even when the net is 0 (an originally frozen
  // exchange): "an admin undid this" is a fact worth recording. It is skipped
  // only when this match never wrote a row for that team at all.
  if (netC.n > 0) {
    await writeHistory(challengerTeam, currentC, revertedC, -netC.net, REASON.ADMIN_REVERSAL);
  }
  if (netO.n > 0) {
    await writeHistory(opponentTeam, currentO, revertedO, -netO.net, REASON.ADMIN_REVERSAL);
  }
  await writeHistory(challengerTeam, revertedC, exchange.challenger.after,
    exchange.challenger.delta, REASON.ADMIN_RULING);
  await writeHistory(opponentTeam, revertedO, exchange.opponent.after,
    exchange.opponent.delta, REASON.ADMIN_RULING);

  const side = (cur, reverted, ex) => ({
    before: cur,
    reversedTo: reverted,
    after: ex.after,
    delta: ex.after - cur,
    ruledDelta: ex.delta,
    expected: ex.expected,
    score: ex.score,
  });

  return {
    frozen,
    reason: REASON.ADMIN_RULING,
    kFactor: exchange.kFactor,
    challenger: side(currentC, revertedC, exchange.challenger),
    opponent: side(currentO, revertedO, exchange.opponent),
  };
}

module.exports = {
  // constants
  OUTCOME,
  REASON,
  RANKED_MIN_MATCHES,
  COMP_MIN,
  COMP_MAX,
  COMP_GAP_CAP,
  PREFERRED_ELO_BAND,
  // pure
  expected,
  newRating,
  rate,
  outcomeFor,
  playedCount,
  isRanked,
  displayElo,
  competitiveness,
  competitivenessFor,
  // transactional
  applyResult,
  correctResult,
  supportsCorrection,
};
