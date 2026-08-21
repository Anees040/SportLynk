/**
 * No-Show sweep (FR: 30-minute forfeit rule)
 *
 * Every 5 minutes: find `confirmed` bookings whose slot started more than
 * 30 minutes ago with no check-in, then apply the no-show ledger:
 *
 *   player balance +0.8P | player frozen -P | owner balance +0.2P | status no_show
 *   trust_score -10 + a notification row for the player
 *
 * The owner's manual button (POST /api/owner/no-show/:id) is an early trigger
 * for exactly the same ledger move.
 *
 * Slot date/time are PKT wall-clock values, so the overdue test compares them
 * against NOW() converted to Asia/Karachi.
 */

const pool = require('../db/pool');
const {
  POLICY,
  penaltySplit,
  lockWallet,
  applyWallet,
  logTxn,
} = require('../utils/escrow');
const { notify } = require('../utils/notify');

const SWEEP_INTERVAL_MS = 5 * 60 * 1000;

let _running = false;

async function processNoShows() {
  if (_running) return;
  _running = true;
  try {
    // Candidate scan runs outside the money transaction; each booking is then
    // re-read with FOR UPDATE so a concurrent check-in can never be overwritten.
    const overdueRes = await pool.query(
      `SELECT b.id
         FROM bookings b
        WHERE b.status = 'confirmed'
          AND b.checked_in_at IS NULL
          AND b.no_show_processed IS NOT TRUE
          AND (b.slot_date::DATE + b.start_time::TIME)
              < (NOW() AT TIME ZONE $1) - ($2 || ' minutes')::INTERVAL`,
      [POLICY.TIMEZONE, String(POLICY.NO_SHOW_GRACE_MINUTES)],
    );

    if (overdueRes.rows.length === 0) {
      console.log('[NoShowJob] sweep: 0 overdue booking(s).');
      return;
    }

    console.log(`[NoShowJob] sweep: ${overdueRes.rows.length} overdue booking(s)...`);

    let done = 0;
    for (const row of overdueRes.rows) {
      const settled = await settleNoShow(row.id);
      if (settled) done++;
    }
    console.log(`[NoShowJob] sweep complete: ${done}/${overdueRes.rows.length} settled.`);
  } catch (err) {
    console.error('[NoShowJob] sweep error:', err.message);
  } finally {
    _running = false;
  }
}

/** One booking, one transaction: booking row + both wallets locked FOR UPDATE. */
async function settleNoShow(bookingId) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    const res = await client.query(
      `SELECT b.id, b.status, b.security_deposit, b.deposit_amount, b.player_id,
              b.slot_id, v.owner_id, v.name AS venue_name, u.name AS player_name
         FROM bookings b
         JOIN venues v ON v.id = b.venue_id
         JOIN users u ON u.id = b.player_id
        WHERE b.id = $1
          AND b.status = 'confirmed'
          AND b.checked_in_at IS NULL
          AND b.no_show_processed IS NOT TRUE
        FOR UPDATE OF b`,
      [bookingId],
    );

    if (!res.rows.length) {
      // Player checked in (or another sweep won the race) between scan and lock.
      await client.query('ROLLBACK');
      return false;
    }

    const b = res.rows[0];
    const { refund, penalty } = penaltySplit(b.security_deposit, b.deposit_amount);

    await client.query(
      `UPDATE bookings
          SET status = 'no_show', no_show_at = NOW(), no_show_processed = true
        WHERE id = $1`,
      [b.id],
    );

    if (b.slot_id) {
      await client.query("UPDATE slots SET status = 'available' WHERE id = $1", [b.slot_id]);
    }

    const playerWallet = await lockWallet(client, b.player_id);
    const ownerWallet = await lockWallet(client, b.owner_id);

    const playerAfter = await applyWallet(client, playerWallet.id, {
      balance: refund,
      frozen: -(refund + penalty),
    });
    const ownerAfter = ownerWallet
      ? await applyWallet(client, ownerWallet.id, { balance: penalty })
      : null;

    if (refund > 0) {
      await logTxn(client, {
        walletId: playerWallet.id,
        userId: b.player_id,
        bookingId: b.id,
        type: 'refund',
        amount: refund,
        balanceAfter: playerAfter.balance,
        description: `Auto no-show — ${100 - POLICY.DEPOSIT_PERCENT}% returned (${POLICY.NO_SHOW_GRACE_MINUTES} min rule)`,
        counterparty: b.venue_name,
      });
    }

    await logTxn(client, {
      walletId: playerWallet.id,
      userId: b.player_id,
      bookingId: b.id,
      type: 'no_show_penalty',
      amount: -penalty,
      balanceAfter: playerAfter.balance,
      description: `Auto no-show — ${POLICY.DEPOSIT_PERCENT}% deposit forfeited (${POLICY.NO_SHOW_GRACE_MINUTES} min rule)`,
      counterparty: b.venue_name,
    });

    if (ownerAfter) {
      await logTxn(client, {
        walletId: ownerWallet.id,
        userId: b.owner_id,
        bookingId: b.id,
        type: 'escrow_received',
        amount: penalty,
        balanceAfter: ownerAfter.balance,
        description: 'Auto no-show deposit received',
        counterparty: b.player_name,
      });
    }

    await client.query(
      `UPDATE player_profiles
          SET trust_score = GREATEST(trust_score - $1, 0)
        WHERE user_id = $2`,
      [POLICY.NO_SHOW_TRUST_PENALTY, b.player_id],
    );

    await notify(client, {
      userId: b.player_id,
      bookingId: b.id,
      type: 'booking_no_show',
      title: 'Marked as no-show',
      body: `You did not check in at ${b.venue_name} within ${POLICY.NO_SHOW_GRACE_MINUTES} minutes. PKR ${refund} returned, PKR ${penalty} deposit forfeited, trust score -${POLICY.NO_SHOW_TRUST_PENALTY}.`,
    });

    await notify(client, {
      userId: b.owner_id,
      bookingId: b.id,
      type: 'booking_no_show_owner',
      title: 'Player did not show up',
      body: `${b.player_name} missed their slot. PKR ${penalty} deposit credited to your wallet.`,
    });

    await client.query('COMMIT');
    console.log(
      `[NoShowJob] ✓ ${b.id} (${b.player_name} @ ${b.venue_name}) → no_show. Player +${refund}, owner +${penalty}.`,
    );
    return true;
  } catch (err) {
    await client.query('ROLLBACK');
    console.error(`[NoShowJob] ✗ booking ${bookingId}:`, err.message);
    return false;
  } finally {
    client.release();
  }
}

function startNoShowJob() {
  console.log(
    `[NoShowJob] Started — sweeps every ${SWEEP_INTERVAL_MS / 60000} min, ${POLICY.NO_SHOW_GRACE_MINUTES} min grace after slot start.`,
  );
  setTimeout(processNoShows, 5000);
  setInterval(processNoShows, SWEEP_INTERVAL_MS);
}

module.exports = { startNoShowJob, processNoShows };
