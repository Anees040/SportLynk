/**
 * Registration-deadline sweep — SRS FE-4.
 *
 * Every few minutes: find open tournaments whose registration deadline has passed
 * and settle them, one of two ways.
 *
 *   enough teams  →  generateFixtures: seed the bracket, place it on the venue's
 *                    real slots, release every captain's entry fee out of frozen,
 *                    pay the owner their inventory cost plus margin, freeze the
 *                    prize, and notify everyone.
 *   too few teams →  cancel and refund every entry in full.
 *
 * Why a job and not just the button
 * `POST /:id/generate` exists for an owner who wants to start early, but FE-4 says
 * the deadline is enforced, and nobody is obliged to press anything. Without this
 * sweep a tournament whose owner lost interest would sit at `open` forever with
 * eight captains' money frozen — the fee held, no bracket, no refund. That is the
 * worst state in the whole module, and it is exactly the state that only a clock
 * can prevent.
 *
 * Why per-tournament transactions
 * Same reason matchExpiryJob works per row: one generation moves eight wallets,
 * blocks seven slots and writes nine notifications. Batching them would mean one
 * venue with no free hours takes down the whole sweep, and a long transaction would
 * hold every affected wallet's lock at once. Per tournament, a failure costs that
 * one tournament, which the next sweep retries.
 *
 * Why it never "FIXES" A refusal
 * `generateFixtures` returning `ok: false` — not enough free hours, a slot taken
 * mid-scan — rolls back and the tournament stays `open` for the next sweep. The job
 * does not then cancel it, because a venue that has not opened next week's slots
 * yet is a fixable situation and the owner is the one who can fix it; auto-cancelling
 * would refund eight teams for an administrative gap that a single tap resolves.
 * `not_enough_slots` is therefore logged loudly and left alone, and the only
 * automatic cancellation is the one FE-4 specifies: too few teams.
 *
 * The candidate scan runs outside any transaction; `generateFixturesTx` re-reads
 * and locks each tournament and re-checks the latch, so a deadline that the owner
 * pressed Generate on a millisecond earlier turns into `already_generated` and is
 * skipped rather than drawn twice.
 */

const pool = require('../db/pool');
const svc = require('../services/tournamentService');
const { POLICY } = require('../utils/escrow');

/** Honours SL_TEST_SWEEP_SECONDS through POLICY, like every other sweep. */
const SWEEP_INTERVAL_MS = POLICY.SWEEP_INTERVAL_MS;

/** A generation is slow (a model call plus eight wallets); never overlap sweeps. */
let _running = false;

/** Codes that mean "not this sweep's problem", logged quietly. */
const BENIGN = new Set(['already_generated', 'too_early', 'cancelled', 'not_found']);

/**
 * Settle one tournament. Returns a one-word outcome for the sweep's tally.
 *
 * The system is the actor, so `bySystem: true` — that is what lets the service
 * skip the owner-authority check it would apply to a request, auto-reject entries
 * still awaiting approval (the organiser had until the deadline to decide), and
 * word the notifications as "the deadline passed" rather than "the organiser".
 */
async function settleOne(row) {
  try {
    const result = await svc.generateFixturesTx({
      actorId: null,
      tournamentId: row.id,
      bySystem: true,
      useModel: true,
    });

    if (result.ok && result.code === 'cancelled_min_teams') {
      const d = result.data || {};
      console.log(
        `[TournamentJob] "${row.name}" cancelled — ${d.teams} team(s), needs ${d.minTeams}; `
        + `${d.teamsRefunded || 0} refund(s) totalling PKR ${d.refunded || 0}.`,
      );
      return 'cancelled';
    }

    if (result.ok) {
      const d = result.data || {};
      const e = d.economics || {};
      const src = d.meta && d.meta.scheduling ? d.meta.scheduling.source : 'unknown';
      console.log(
        `[TournamentJob] "${row.name}" drawn — ${d.teams} team(s), `
        + `${(d.fixtures || []).length} fixture(s), scheduler=${src}; `
        + `pool ${e.pool} = venue ${e.venueCost} + prize ${e.prize} + margin ${e.margin}.`,
      );
      return 'generated';
    }

    const level = BENIGN.has(result.code) ? 'log' : 'warn';
    console[level](
      `[TournamentJob] "${row.name}" skipped (${result.code}): ${result.message}`,
    );
    return BENIGN.has(result.code) ? 'skipped' : 'blocked';
  } catch (e) {
    // One tournament's failure must not end the sweep — the rest still have
    // deadlines that have passed.
    console.error(`[TournamentJob] ${row.id} failed:`, e.message);
    return 'failed';
  }
}

async function processDueTournaments() {
  if (_running) return;
  _running = true;
  try {
    // Uses idx_tournaments_due (019) — partial on exactly the two facts that
    // define a candidate, so the sweep reads the handful of open tournaments and
    // never the archive, however large it grows.
    const { rows } = await pool.query(
      `SELECT id, name, registration_deadline
         FROM tournaments
        WHERE status = 'open'
          AND fixtures_generated_at IS NULL
          AND registration_deadline IS NOT NULL
          AND registration_deadline <= now()
        ORDER BY registration_deadline
        LIMIT 50`,
    );

    if (rows.length === 0) {
      console.log('[TournamentJob] sweep: 0 tournament(s) due.');
      return;
    }

    console.log(`[TournamentJob] sweep: ${rows.length} tournament(s) past deadline...`);
    const tally = { generated: 0, cancelled: 0, skipped: 0, blocked: 0, failed: 0 };
    for (const row of rows) {
      tally[await settleOne(row)] += 1;
    }
    console.log(
      `[TournamentJob] sweep complete: ${tally.generated} drawn, ${tally.cancelled} cancelled, `
      + `${tally.blocked} blocked, ${tally.skipped} skipped, ${tally.failed} failed.`,
    );
  } catch (e) {
    // Never rethrow from a timer callback.
    console.error('[TournamentJob] sweep failed:', e.message);
  } finally {
    _running = false;
  }
}

function startTournamentJob() {
  console.log(
    `[TournamentJob] Started — sweeps every ${Math.round(SWEEP_INTERVAL_MS / 1000)}s, `
    + 'generates or cancels at the registration deadline (FE-4).',
  );
  // 11s: after matchExpiryJob's 8s, so the four sweeps do not all hit the pool in
  // the same instant the server finishes booting.
  setTimeout(processDueTournaments, 11000);
  setInterval(processDueTournaments, SWEEP_INTERVAL_MS);
}

module.exports = { startTournamentJob, processDueTournaments, settleOne, SWEEP_INTERVAL_MS };
