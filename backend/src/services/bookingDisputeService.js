/**
 * bookingDisputeService.js — a player disputes a booking, an admin upholds or rejects it.
 *
 * The money rule: this service NEVER invents a refund path. When a dispute is upheld
 * and the booking's escrow is still held (status pending or confirmed), it moves money
 * with the SAME escrow helpers cancelBooking uses — lockWallet, applyWallet, logTxn —
 * and performs the SAME full-refund arithmetic cancelBooking performs on an on-time
 * cancellation (player balance += escrow, player frozen -= escrow), then cancels the
 * booking and frees the slot exactly as that path does. A dispute waives the late
 * penalty on purpose: an upheld dispute means the fault was not the player's, so the
 * 24-hour rule that governs a voluntary cancellation does not apply.
 *
 * When the escrow has already settled (the booking was completed, released or already
 * cancelled), there is nothing left in frozen balance to return, so an upheld dispute
 * on such a booking is recorded with a zero auto-refund and a note — the money, if any
 * is owed, is a manual adjustment, not something this path will fabricate.
 *
 * The row only ever records the claim and the verdict (migration 032). It is the admin
 * dispute queue's data; the refund is a side effect of upholding, done in the same
 * transaction so a dispute can never read "upheld" without the money having moved.
 */
const pool = require('../db/pool');
const {
  round2, lockWallet, applyWallet, logTxn,
} = require('../utils/escrow');

const fail = (status, code, message) => ({ ok: false, status, code, message, row: null });

/** Statuses whose escrow is still frozen and therefore refundable in full. */
const REFUNDABLE = new Set(['pending', 'confirmed']);

/**
 * Raise a dispute on one of the caller's own bookings.
 *
 * Ownership is in the WHERE clause, never trusted from the caller: a booking id that
 * is not this player's matches no row and gets a 404, not someone else's booking. The
 * partial unique index (one open dispute per booking) is the real guard against a
 * flood; this pre-check just turns the race it would lose into a clean sentence.
 */
async function raise(client, { userId, bookingId, reason } = {}) {
  const runner = client || pool;
  const text = String(reason == null ? '' : reason).replace(/\s+/g, ' ').trim().slice(0, 1000);
  if (!text) return fail(400, 'empty_reason', 'Tell us what went wrong so an admin can look into it.');

  const b = await runner.query(
    `SELECT b.id, b.status FROM bookings b WHERE b.id = $1 AND b.player_id = $2`,
    [bookingId, userId],
  );
  if (!b.rows.length) return fail(404, 'booking_not_found', 'Booking not found.');

  const open = await runner.query(
    `SELECT 1 FROM booking_disputes WHERE booking_id = $1 AND status = 'open'`,
    [bookingId],
  );
  if (open.rows.length) {
    return fail(409, 'already_open', 'You already have an open dispute on this booking.');
  }

  const { rows } = await runner.query(
    `INSERT INTO booking_disputes (booking_id, raised_by, reason)
     VALUES ($1, $2, $3)
     RETURNING id, booking_id, raised_by, reason, status, created_at`,
    [bookingId, userId, text],
  );
  return { ok: true, status: 201, code: 'ok', row: rows[0],
    message: 'Dispute submitted. An admin will review it and you will see the outcome here.' };
}

/** The caller's own disputes, newest first — for the status line on a booking. */
async function listMine(client, { userId, limit = 50 } = {}) {
  const { rows } = await (client || pool).query(
    `SELECT d.id, d.booking_id, d.reason, d.status, d.refund_amount,
            d.resolution_notes, d.created_at, d.resolved_at
       FROM booking_disputes d
      WHERE d.raised_by = $1
      ORDER BY d.created_at DESC
      LIMIT $2`,
    [userId, Math.max(1, Math.min(100, Number(limit) || 50))],
  );
  return rows;
}

/** The admin queue: open first, then by age. Joined to the booking it is about. */
async function listForAdmin(client, { status = 'open', limit = 100 } = {}) {
  const want = ['open', 'upheld', 'rejected', 'all'].includes(status) ? status : 'open';
  const { rows } = await (client || pool).query(
    `SELECT d.id, d.booking_id, d.reason, d.status, d.refund_amount, d.resolution_notes,
            d.created_at, d.resolved_at,
            u.name AS player_name, v.name AS venue_name,
            b.status AS booking_status, b.slot_date, b.start_time, b.security_deposit
       FROM booking_disputes d
       JOIN bookings b ON b.id = d.booking_id
       JOIN users u ON u.id = d.raised_by
       JOIN venues v ON v.id = b.venue_id
      WHERE ($1 = 'all' OR d.status = $1)
      ORDER BY (d.status = 'open') DESC, d.created_at ASC
      LIMIT $2`,
    [want, Math.max(1, Math.min(200, Number(limit) || 100))],
  );
  return rows;
}

module.exports = {
  REFUNDABLE,
  fail,
  raise,
  listMine,
  listForAdmin,
  resolve,
};

/**
 * Uphold or reject an open dispute. Caller is already inside a transaction.
 *
 * uphold === true and the booking's escrow is still frozen → the full-refund branch of
 * cancelBooking, verbatim in mechanism: lock the player's wallet, move the held escrow
 * from frozen back to balance, log it, cancel the booking and free the slot. The late
 * penalty is deliberately not applied. uphold with an already-settled booking records
 * the verdict with a zero auto-refund. uphold === false just closes the row.
 *
 * The dispute is locked FOR UPDATE and must be `open`, so two admins cannot resolve the
 * same dispute twice and a resolved dispute cannot be refunded again.
 */
async function resolve(client, {
  disputeId, adminId, uphold, notes = null,
} = {}) {
  const d = await client.query(
    `SELECT id, booking_id, raised_by, status FROM booking_disputes
      WHERE id = $1 FOR UPDATE`,
    [disputeId],
  );
  if (!d.rows.length) return fail(404, 'dispute_not_found', 'That dispute no longer exists.');
  if (d.rows[0].status !== 'open') {
    return fail(409, 'already_resolved', 'This dispute has already been resolved.');
  }
  const dispute = d.rows[0];
  const note = String(notes == null ? '' : notes).replace(/\s+/g, ' ').trim().slice(0, 1000) || null;

  if (!uphold) {
    const { rows } = await client.query(
      `UPDATE booking_disputes
          SET status = 'rejected', resolution_notes = $2, resolved_by = $3, resolved_at = now()
        WHERE id = $1
      RETURNING id, booking_id, status, refund_amount, resolution_notes, resolved_at`,
      [disputeId, note, adminId],
    );
    return { ok: true, status: 200, code: 'ok', row: rows[0], refund: 0,
      message: 'Dispute rejected. No refund was issued.' };
  }

  // Upheld. Lock the booking and, only while its escrow is still held, refund in full.
  const b = await client.query(
    `SELECT b.id, b.status, b.slot_id, b.player_id, b.security_deposit, v.name AS venue_name
       FROM bookings b JOIN venues v ON v.id = b.venue_id
      WHERE b.id = $1 FOR UPDATE OF b`,
    [dispute.booking_id],
  );
  if (!b.rows.length) return fail(404, 'booking_not_found', 'The booking no longer exists.');
  const booking = b.rows[0];

  let refund = 0;
  if (REFUNDABLE.has(booking.status)) {
    const escrow = round2(booking.security_deposit);
    const wallet = await lockWallet(client, booking.player_id);
    const after = await applyWallet(client, wallet.id, { balance: escrow, frozen: -escrow });
    await logTxn(client, {
      walletId: wallet.id,
      userId: booking.player_id,
      bookingId: booking.id,
      type: 'refund',
      amount: escrow,
      balanceAfter: after.balance,
      description: 'Dispute upheld — full refund',
      counterparty: booking.venue_name,
    });
    await client.query(
      `UPDATE bookings SET status = 'cancelled', cancelled_at = NOW(),
              cancellation_reason = 'dispute_upheld' WHERE id = $1`,
      [booking.id],
    );
    await client.query(
      `UPDATE slots SET status = 'available', locked_by = null, locked_until = null WHERE id = $1`,
      [booking.slot_id],
    );
    refund = escrow;
  }

  const { rows } = await client.query(
    `UPDATE booking_disputes
        SET status = 'upheld', refund_amount = $2, resolution_notes = $3,
            resolved_by = $4, resolved_at = now()
      WHERE id = $1
    RETURNING id, booking_id, status, refund_amount, resolution_notes, resolved_at`,
    [disputeId, refund, note, adminId],
  );
  const message = refund > 0
    ? `Dispute upheld — PKR ${refund} refunded to the player's wallet.`
    : 'Dispute upheld. The booking was already settled, so no automatic refund was issued '
      + '(any adjustment is manual).';
  return { ok: true, status: 200, code: 'ok', row: rows[0], refund, message };
}

