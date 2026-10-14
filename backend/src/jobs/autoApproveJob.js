/**
 * Auto-decision sweep for pending booking requests (FR4.10)
 *
 * Every 5 minutes:
 *   • a near-term slot (within NEAR_TERM_WINDOW) left pending past the short urgent
 *       window → auto-confirm (the owner stayed silent through the window they had)
 *   • pending longer than the ordinary owner-decision window, slot still far off
 *       → auto-confirm (owner stayed silent; escrow stays frozen, no money moves)
 *   • pending and slot starts within the short reject lead (or has already started),
 *       and it was too close to kickoff to wait out either confirm window
 *       → auto-reject + full refund: player balance +P, frozen -P, slot freed
 *
 * The near-term rule is what closes the lost-revenue gap: a booking made 1–2 hours
 * before kickoff could never reach the 2-hour auto-confirm, so it was always rejected
 * at the lead. It now confirms after a short window instead — the owner keeps that
 * window to approve or reject by hand, and only a booking made too close to kickoff
 * to wait the window out is refunded.
 *
 * Both paths write a notification row for the player and the owner, and every
 * ledger write happens inside one transaction with FOR UPDATE on the booking
 * and the wallet.
 */

const pool = require('../db/pool');
const {
  POLICY,
  describeDelay,
  round2,
  lockWallet,
  applyWallet,
  logTxn,
} = require('../utils/escrow');
const { notify } = require('../utils/notify');
const chat = require('../utils/chatCore');

let _running = false;

async function processPendingRequests() {
  if (_running) return;
  _running = true;
  try {
    // slot_date + start_time are PKT wall-clock values → compare with PKT now.
    // Order matters: the near-term confirm is tried before the reject floor so a
    // silent owner's near-term booking is kept, not killed; the reject floor then
    // only catches a still-pending slot too close to kickoff to have waited either
    // confirm window out.
    const res = await pool.query(
      `SELECT b.id,
              CASE
                WHEN (b.slot_date::DATE + b.start_time::TIME)
                       <  (NOW() AT TIME ZONE $1) + ($4 || ' minutes')::INTERVAL
                     AND (b.slot_date::DATE + b.start_time::TIME)
                       >= (NOW() AT TIME ZONE $1) + ($2 || ' minutes')::INTERVAL
                     AND b.created_at < NOW() - ($5 || ' minutes')::INTERVAL
                  THEN 'approve_near'
                WHEN (b.slot_date::DATE + b.start_time::TIME)
                       < (NOW() AT TIME ZONE $1) + ($2 || ' minutes')::INTERVAL
                  THEN 'reject'
                WHEN b.created_at < NOW() - ($3 || ' minutes')::INTERVAL
                  THEN 'approve'
                ELSE 'wait'
              END AS decision
         FROM bookings b
        WHERE b.status = 'pending'`,
      [
        POLICY.TIMEZONE,
        String(POLICY.AUTO_REJECT_MIN_LEAD_MINUTES),
        String(POLICY.AUTO_DECIDE_AFTER_MINUTES),
        String(POLICY.NEAR_TERM_WINDOW_MINUTES),
        String(POLICY.NEAR_TERM_AUTO_CONFIRM_MINUTES),
      ],
    );

    const due = res.rows.filter((r) => r.decision !== 'wait');
    if (due.length === 0) {
      console.log('[AutoApproveJob] sweep: 0 pending request(s) due.');
      return;
    }

    const toReject = due.filter((r) => r.decision === 'reject').length;
    const toApprove = due.length - toReject;
    console.log(
      `[AutoApproveJob] sweep: ${due.length} due (${toApprove} auto-confirm, ${toReject} auto-reject).`,
    );

    let done = 0;
    for (const row of due) {
      const ok =
        row.decision === 'reject'
          ? await autoReject(row.id)
          : await autoConfirm(row.id, row.decision === 'approve_near');
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
            v.owner_id AS venue_owner_id, v.name AS venue_name,
            v.image_url AS venue_image, u.name AS player_name
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
async function autoConfirm(bookingId, nearTerm = false) {
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

    const window = nearTerm
      ? POLICY.NEAR_TERM_AUTO_CONFIRM_MINUTES
      : POLICY.AUTO_DECIDE_AFTER_MINUTES;
    await notify(client, {
      userId: b.player_id,
      bookingId: b.id,
      type: 'booking_auto_confirmed',
      title: 'Booking auto-confirmed',
      body: `${b.venue_name} did not respond within ${describeDelay(window)}, so your booking was confirmed automatically. Show your QR code at the venue.`,
    });
    await notify(client, {
      userId: b.venue_owner_id || b.owner_id,
      bookingId: b.id,
      type: 'booking_auto_confirmed_owner',
      title: 'Request auto-confirmed',
      body: `${b.player_name}'s request was pending for over ${describeDelay(window)} and has been auto-confirmed.`,
    });

    // Confirm path #2. Identical call to routes/owner.js so the
    // room and its opening sentence do not depend on who confirmed; the unique
    // (type, ref_id) index makes a race between the two an update, not a
    // duplicate room.
    const pill = await chat.openBookingRoom(client, {
      bookingId: b.id,
      playerId: b.player_id,
      ownerId: b.venue_owner_id || b.owner_id,
      venueName: b.venue_name,
      imageUrl: b.venue_image || null,
      event: 'booking_confirmed',
    });

    await client.query('COMMIT');
    await chat.emitPills(pool, pill);
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
        description: `Auto-rejected — owner did not approve before the ${describeDelay(POLICY.AUTO_REJECT_MIN_LEAD_MINUTES)} cut-off`,
        counterparty: b.venue_name,
      });
    }

    await notify(client, {
      userId: b.player_id,
      bookingId: b.id,
      type: 'booking_auto_rejected',
      title: 'Booking auto-rejected',
      body: `${b.venue_name} did not approve in time (slot starts within ${describeDelay(POLICY.AUTO_REJECT_MIN_LEAD_MINUTES)}). PKR ${escrow} has been refunded in full.`,
    });
    await notify(client, {
      userId: b.venue_owner_id || b.owner_id,
      bookingId: b.id,
      type: 'booking_auto_rejected_owner',
      title: 'Request expired',
      body: `${b.player_name}'s request was auto-rejected — the slot starts within ${describeDelay(POLICY.AUTO_REJECT_MIN_LEAD_MINUTES)} and it was never approved.`,
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
    `[AutoApproveJob] Started — sweeps every ${POLICY.SWEEP_INTERVAL_MS / 60000} min ` +
      `(auto-confirm after ${describeDelay(POLICY.AUTO_DECIDE_AFTER_MINUTES)}, ` +
      `near-term confirm after ${describeDelay(POLICY.NEAR_TERM_AUTO_CONFIRM_MINUTES)} within ${describeDelay(POLICY.NEAR_TERM_WINDOW_MINUTES)}, ` +
      `auto-reject inside ${describeDelay(POLICY.AUTO_REJECT_MIN_LEAD_MINUTES)} of slot start).`,
  );
  setTimeout(processPendingRequests, 10000);
  setInterval(processPendingRequests, POLICY.SWEEP_INTERVAL_MS);
}

module.exports = { startAutoApproveJob, processPendingRequests };
