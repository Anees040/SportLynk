/**
 * Challenge expiry sweep  —  FR5.12 (S.2 Wave C)
 *
 * Every few minutes: find `challenge_sent` matches whose deadline has passed and
 * settle them as `expired`, with a chat pill in both teams' threads.
 *
 * Why this job exists at all, given the routes already CHECK the deadline
 * PATCH /respond settles an expired challenge on contact, so a captain who taps
 * Accept two minutes late gets an honest answer instead of a match. But nobody is
 * obliged to tap anything, and an unanswered challenge is precisely the case
 * where no request will ever arrive. Left alone the row would sit in
 * `challenge_sent` forever, and because ux_matches_booking_live counts that
 * status, it would hold the BOOKING — the challenger could not reuse their own
 * confirmed slot for a different opponent. The deadline has to be enforced by
 * something that runs whether or not anyone opens the app.
 *
 * Why per-row transactions rather than one bulk UPDATE
 * A single `UPDATE … WHERE challenge_expires_at < now()` would be one statement,
 * but each expiry also posts two chat pills and needs the member list to emit to.
 * Batching those into one transaction means one bad channel row takes down the
 * whole sweep, and a long transaction holds locks across every affected match.
 * Per row: a failure costs one expiry, which the next sweep retries.
 *
 * The candidate scan runs outside any transaction and each row is then re-read
 * with FOR UPDATE — same discipline as noShowJob. Between the scan and the lock
 * the opponent may have accepted, so the status is re-checked under the lock and
 * a match that moved on is left alone. Without that re-check this job could
 * expire a match that was confirmed a millisecond earlier.
 */

const pool = require('../db/pool');
const mc = require('../utils/matchCore');
const settings = require('../utils/globalSettings');
const { POLICY } = require('../utils/escrow');

const SWEEP_INTERVAL_MS = POLICY.SWEEP_INTERVAL_MS;

/** One sweep at a time. A slow sweep must not overlap the next tick. */
let _running = false;

/**
 * Expire one challenge. Returns true if this call is the one that expired it.
 *
 * Self-contained transaction: connect → BEGIN → work → COMMIT, with a `finally`
 * that always releases. A client released mid-transaction is handed to the next
 * caller still inside it.
 */
async function expireOne(matchId) {
  const client = await pool.connect();
  let fan = null;
  try {
    await client.query('BEGIN');

    const m = await mc.lockMatch(client, matchId);
    // Re-check under the lock: accepted, rejected, or already swept by a previous
    // overlapping run. All three mean the row must be left as it is.
    if (!m || m.status !== mc.STATUS.CHALLENGE_SENT) {
      await client.query('ROLLBACK');
      return false;
    }
    // The deadline is also re-read from the locked row rather than trusted from
    // the scan, in case an admin extended it in between.
    if (m.challenge_expires_at && new Date(m.challenge_expires_at).getTime() > Date.now()) {
      await client.query('ROLLBACK');
      return false;
    }

    await client.query(
      'UPDATE matches SET status = $2, updated_at = now() WHERE id = $1',
      [matchId, mc.STATUS.EXPIRED],
    );

    const features = await mc.teamFeatures(client, [m.challenger_team, m.opponent_team]);
    const cName = features.get(String(m.challenger_team))?.name || 'the other team';
    const oName = features.get(String(m.opponent_team))?.name || 'the other team';

    // Only the challenger is notified. They are the side that was waiting, and
    // telling the challenged team "you did not reply in time" is a reproach, not
    // information — the pill in their thread already records what happened.
    fan = await mc.fanOut(client, {
      matchId,
      sides: [
        {
          teamId: m.challenger_team,
          event: 'match_expired',
          otherTeamName: oName,
          notify: {
            type: 'match_expired',
            title: `${oName} did not reply in time`,
            body: 'Your challenge expired and the slot is free again — you can challenge another team.',
            extra: { opponentTeam: m.opponent_team },
          },
        },
        {
          teamId: m.opponent_team,
          event: 'match_expired',
          otherTeamName: cName,
        },
      ],
    });

    await client.query('COMMIT');
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    console.error(`[MatchExpiryJob] ${matchId} failed:`, e.message);
    return false;
  } finally {
    client.release();
  }

  // After commit, and outside the try, so an emit failure cannot be mistaken for
  // a failed expiry — the row is already durable at this point.
  if (fan) {
    await mc.emitAfterCommit(pool, {
      matchId, ...fan, extra: { event: 'expired' },
    }).catch(() => {});
  }
  return true;
}

async function processExpiredChallenges() {
  if (_running) return;
  _running = true;
  try {
    // Uses idx_matches_expiry (migration 016), a partial index on
    // challenge_expires_at WHERE status = 'challenge_sent' — so this scan reads
    // only the live challenges, not the whole matches table, however large the
    // history grows.
    const { rows } = await pool.query(
      `SELECT id FROM matches
        WHERE status = $1
          AND challenge_expires_at IS NOT NULL
          AND challenge_expires_at <= now()
        ORDER BY challenge_expires_at
        LIMIT 200`,
      [mc.STATUS.CHALLENGE_SENT],
    );

    if (rows.length === 0) {
      console.log('[MatchExpiryJob] sweep: 0 expired challenge(s).');
      return;
    }

    console.log(`[MatchExpiryJob] sweep: ${rows.length} expired challenge(s)...`);
    let done = 0;
    for (const row of rows) {
      if (await expireOne(row.id)) done++;
    }
    console.log(`[MatchExpiryJob] sweep complete: ${done}/${rows.length} expired.`);
  } catch (e) {
    // Never rethrow from a timer callback: an unhandled rejection here would take
    // the whole server down for something a retry in five minutes would fix.
    console.error('[MatchExpiryJob] sweep failed:', e.message);
  } finally {
    _running = false;
  }
}

function startMatchExpiryJob() {
  // Read once at boot purely so the log line states the real configured TTL
  // rather than a hard-coded 48 that an admin may already have changed.
  settings.match()
    .then(({ challengeTtlHours }) => {
      console.log(
        `[MatchExpiryJob] Started — sweeps every ${SWEEP_INTERVAL_MS / 60000} min, `
        + `challenge TTL ${challengeTtlHours}h.`,
      );
    })
    .catch(() => {
      console.log(`[MatchExpiryJob] Started — sweeps every ${SWEEP_INTERVAL_MS / 60000} min.`);
    });

  // Offset from the other jobs' 5s so four sweeps do not all fire into the same
  // connection pool the instant the server finishes booting.
  setTimeout(processExpiredChallenges, 8000);
  setInterval(processExpiredChallenges, SWEEP_INTERVAL_MS);
}

module.exports = { startMatchExpiryJob, processExpiredChallenges };
