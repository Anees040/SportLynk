/**
 * Auto-decision sweep for pending booking requests (FR4.10)
 *
 * Every 5 minutes:
 *   • pending for more than 2h AND slot starts more than 2h from now
 *       → auto-confirm (owner stayed silent; escrow stays frozen, no money moves)
 *   • pending AND slot starts within 2h (or has already started)
 *       → auto-reject + FULL refund: player balance +P, frozen -P, slot freed
 *
 * Both paths write a notification row for the player and the owner, and every
 * ledger write happens inside one transaction with FOR UPDATE on the booking
 * and the wallet.
 */

const pool = require('../db/pool');
const { POLICY, round2, lockWallet, applyWallet, logTxn } = require('../utils/escrow');
const { notify } = require('../utils/notify');

const SWEEP_INTERVAL_MS = 5 * 60 * 1000;

let _running = false;

async function processPendingRequests() {
  if (_running) return;
  _running = true;
  try {
    // slot_date + start_time are PKT wall-clock values → compare with PKT now.
    const res = await pool.query(
      `SELECT b.id,
              CASE
                WHEN (b.slot_date::DATE + b.start_time::TIME)
                     < (NOW() AT TIME ZONE $1) + ($2 || ' hours')::INTERVAL
                  THEN 'reject'
                WHEN b.created_at < NOW() - ($3 || ' hours')::INTERVAL
                  THEN 'approve'
                ELSE 'wait'
              END AS decision
         FROM bookings b
        WHERE b.status = 'pending'`,
      [
        POLICY.TIMEZONE,
        String(POLICY.AUTO_DECIDE_MIN_LEAD_HOURS),
        String(POLICY.AUTO_DECIDE_AFTER_HOURS),
      ],
    );

    const due = res.rows.filter((r) => r.decision !== 'wait');
    if (due.length === 0) {
      console.log('[AutoApproveJob] sweep: 0 pending request(s) due.');
      return;
    }

    const toApprove = due.filter((r) => r.decision === 'approve').length;
    const toReject = due.length - toApprove;
    console.log(
      `[AutoApproveJob] sweep: ${due.length} due (${toApprove} auto-confirm, ${toReject} auto-reject).`,
    );

    let done = 0;
    for (const row of due) {
      const ok =
        row.decision === 'approve'
          ? await autoConfirm(row.id)
          : await autoReject(row.id);
      if (ok) done++;
    }
    console.log(`[AutoApproveJob] sweep complete: ${done}/${due.length} decided.`);
  } catch (err) {
    console.error('[AutoApproveJob] sweep error:', err.message);
  } finally {
    _running = false;
  }
}

/** Re-read the booking under lock; returns null if it is no longer pending. */
async function lockPending(client, bookingId) {
  const res = await client.query(
    `SELECT b.id, b.player_id, b.slot_id, b.security_deposit, b.owner_id,
            v.owner_id AS venue_owner_id, v.name AS venue_name, u.name AS player_name
       FROM bookings b
       JOIN venues v ON v.id = b.venue_id
       JOIN users u ON u.id = b.player_id
      WHERE b.id = $1 AND b.status = 'pending'
      FOR UPDATE OF b`,
    [bookingId],
  );
  return res.rows[0] || null;
}

/** Owner never answered but there is still time → confirm. No money moves. */
async function autoConfirm(bookingId) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const b = await lockPending(client, bookingId);
    if (!b) {
      await client.query('ROLLBACK');
      return false;
    }

    await client.query(
      `UPDATE bookings
          SET status = 'confirmed', approved_at = NOW(), auto_decided_at = NOW()
        WHERE id = $1`,
      [b.id],
    );

    await notify(client, {
      userId: b.player_id,
      bookingId: b.id,
      type: 'booking_auto_confirmed',
      title: 'Booking auto-confirmed',
      body: `${b.venue_name} did not respond within ${POLICY.AUTO_DECIDE_AFTER_HOURS}h, so your booking was confirmed automatically. Show your QR code at the venue.`,
    });
    await notify(client, {
      userId: b.venue_owner_id || b.owner_id,
      bookingId: b.id,
      type: 'booking_auto_confirmed_owner',
      title: 'Request auto-confirmed',
      body: `${b.player_name}'s request was pending for over ${POLICY.AUTO_DECIDE_AFTER_HOURS}h and has been auto-confirmed.`,
    });

    await client.query('COMMIT');
    console.log(`[AutoApproveJob] ✓ ${b.id} (${b.player_name} @ ${b.venue_name}) → confirmed.`);
    return true;
  } catch (err) {
    await client.query('ROLLBACK');
    console.error(`[AutoApproveJob] ✗ confirm ${bookingId}:`, err.message);
    return false;
  } finally {
    client.release();
  }
}

/** Slot is too close to start and still unapproved → reject with a full refund. */
async function autoReject(bookingId) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const b = await lockPending(client, bookingId);
    if (!b) {
      await client.query('ROLLBACK');
      return false;
    }

    const escrow = round2(b.security_deposit);

    await client.query(
      `UPDATE bookings
          SET status = 'rejected', cancelled_at = NOW(), auto_decided_at = NOW(),
              cancellation_reason = 'auto_rejected_not_approved_in_time'
        WHERE id = $1`,
      [b.id],
    );

    if (b.slot_id) {
      await client.query("UPDATE slots SET status = 'available' WHERE id = $1", [b.slot_id]);
    }

    const wallet = await lockWallet(client, b.player_id);
    if (wallet && escrow > 0) {
      const after = await applyWallet(client, wallet.id, {
        balance: escrow,
        frozen: -escrow,
      });
      await logTxn(client, {
        walletId: wallet.id,
        userId: b.player_id,
        bookingId: b.id,
        type: 'refund',
        amount: escrow,
        balanceAfter: after.balance,
        description: `Auto-rejected — owner did not approve before the ${POLICY.AUTO_DECIDE_MIN_LEAD_HOURS}h cut-off`,
        counterparty: b.venue_name,
      });
    }

    await notify(client, {
      userId: b.player_id,
      bookingId: b.id,
      type: 'booking_auto_rejected',
      title: 'Booking auto-rejected',
      body: `${b.venue_name} did not approve in time (slot starts within ${POLICY.AUTO_DECIDE_MIN_LEAD_HOURS}h). PKR ${escrow} has been refunded in full.`,
    });
    await notify(client, {
      userId: b.venue_owner_id || b.owner_id,
      bookingId: b.id,
      type: 'booking_auto_rejected_owner',
      title: 'Request expired',
      body: `${b.player_name}'s request was auto-rejected — the slot starts within ${POLICY.AUTO_DECIDE_MIN_LEAD_HOURS}h and it was never approved.`,
    });

    await client.query('COMMIT');
    console.log(
      `[AutoApproveJob] ✓ ${b.id} (${b.player_name} @ ${b.venue_name}) → rejected, PKR ${escrow} refunded.`,
    );
    return true;
  } catch (err) {
    await client.query('ROLLBACK');
    console.error(`[AutoApproveJob] ✗ reject ${bookingId}:`, err.message);
    return false;
  } finally {
    client.release();
  }
}

function startAutoApproveJob() {
  console.log(
    `[AutoApproveJob] Started — sweeps every ${SWEEP_INTERVAL_MS / 60000} min ` +
      `(auto-confirm after ${POLICY.AUTO_DECIDE_AFTER_HOURS}h, auto-reject inside ${POLICY.AUTO_DECIDE_MIN_LEAD_HOURS}h of slot start).`,
  );
  setTimeout(processPendingRequests, 10000);
  setInterval(processPendingRequests, SWEEP_INTERVAL_MS);
}

module.exports = { startAutoApproveJob, processPendingRequests };
