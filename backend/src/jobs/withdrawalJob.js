/**
 * Withdrawal settlement sweep (FR7.4 / ER1.6)
 *
 * Every 5 minutes: find `pending` withdrawals older than
 * POLICY.WITHDRAWAL_SETTLE_MINUTES (24h) and mark them `completed`.
 *
 * **No money moves here.** The debit already happened when the request was
 * created (POST /api/wallet/withdraw), so the player could not spend money they
 * had asked to withdraw. Settlement only flips the payout state and tells the
 * user. This is the same shape as autoApproveJob.autoConfirm, which is also
 * money-neutral — and it means a crash mid-sweep can never lose or duplicate
 * funds, only leave a row pending for another five minutes.
 *
 * Each row is still re-read `FOR UPDATE` before the flip, so a concurrent
 * DELETE /api/wallet/withdraw/:id (user cancels) can never be overwritten.
 *
 * For demos: SL_TEST_SETTLE_MINUTES=1 SL_TEST_SWEEP_SECONDS=15 makes this
 * observable in under a minute. See .env.example.
 */

const pool = require('../db/pool');
const { POLICY, describeDelay, asNum } = require('../utils/escrow');
const { notify } = require('../utils/notify');

let _running = false;

async function processWithdrawals() {
  if (_running) return;
  _running = true;
  try {
    // Candidate scan runs outside the transaction; each row is re-locked below.
    // requested_at is a plain UTC timestamp (NOW()), so no timezone conversion
    // is needed here — unlike the booking sweeps, which compare PKT wall-clock
    // slot times.
    const dueRes = await pool.query(
      `SELECT id
         FROM withdrawals
        WHERE status = 'pending'
          AND requested_at < NOW() - ($1 || ' minutes')::INTERVAL
        ORDER BY requested_at`,
      [String(POLICY.WITHDRAWAL_SETTLE_MINUTES)],
    );

    if (dueRes.rows.length === 0) {
      console.log('[WithdrawalJob] sweep: 0 withdrawal(s) due.');
      return;
    }

    console.log(`[WithdrawalJob] sweep: ${dueRes.rows.length} withdrawal(s) due...`);

    let done = 0;
    for (const row of dueRes.rows) {
      if (await settleWithdrawal(row.id)) done++;
    }
    console.log(`[WithdrawalJob] sweep complete: ${done}/${dueRes.rows.length} settled.`);
  } catch (err) {
    console.error('[WithdrawalJob] sweep error:', err.message);
  } finally {
    _running = false;
  }
}

/** One withdrawal, one transaction. Flips pending → completed; moves no money. */
async function settleWithdrawal(withdrawalId) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    const res = await client.query(
      `SELECT w.id, w.user_id, w.amount, w.method, w.account_number
         FROM withdrawals w
        WHERE w.id = $1 AND w.status = 'pending'
        FOR UPDATE`,
      [withdrawalId],
    );

    if (!res.rows.length) {
      // The user cancelled (or another sweep won the race) between scan and lock.
      await client.query('ROLLBACK');
      return false;
    }

    const w = res.rows[0];
    const amount = asNum(w.amount);

    await client.query(
      `UPDATE withdrawals SET status = 'completed', completed_at = NOW() WHERE id = $1`,
      [w.id],
    );

    const tail = w.account_number ? String(w.account_number).slice(-4) : null;
    await notify(client, {
      userId: w.user_id,
      type: 'withdrawal_completed',
      title: 'Withdrawal paid out',
      body: `PKR ${amount} has been sent to your ${w.method}${tail ? ` account ending ${tail}` : ' account'}.`,
    });

    await client.query('COMMIT');
    console.log(`[WithdrawalJob] ✓ ${w.id} → completed (PKR ${amount} via ${w.method}).`);
    return true;
  } catch (err) {
    await client.query('ROLLBACK');
    console.error(`[WithdrawalJob] ✗ withdrawal ${withdrawalId}:`, err.message);
    return false;
  } finally {
    client.release();
  }
}

function startWithdrawalJob() {
  console.log(
    `[WithdrawalJob] Started — sweeps every ${POLICY.SWEEP_INTERVAL_MS / 60000} min, ` +
      `settles ${describeDelay(POLICY.WITHDRAWAL_SETTLE_MINUTES)} after request.`,
  );
  setTimeout(processWithdrawals, 15000);
  setInterval(processWithdrawals, POLICY.SWEEP_INTERVAL_MS);
}

module.exports = { startWithdrawalJob, processWithdrawals, settleWithdrawal };
