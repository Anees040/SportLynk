/**
 * bookingService.js — the ONE implementation of "book a slot" and "cancel a
 * booking", callable from a route or from Scout.
 *
 * WHY THIS FILE EXISTS
 * --------------------
 * FR8.15: no business rule may be duplicated. Until this extraction, every rule
 * that decides whether a booking may happen — the slot row lock, the checkout
 * hold, the wallet balance floor, the escrow split, the 24-hour cancellation
 * window, the ledger rows, the owner notification — lived INSIDE two Express
 * handlers in routes/bookings.js, interleaved with `res.status(...).json(...)`.
 *
 * The assistant has to create real bookings. There were exactly three ways to do
 * that, and two of them are wrong:
 *
 *   1. Reimplement the rules in the dialog manager. This is the worst option and
 *      the most tempting one, because it looks like the smallest diff. It gives
 *      SportLynk two escrow implementations that must be kept in step by memory,
 *      and the first time they diverge, money is wrong.
 *   2. Have the assistant make an HTTP call to its own API. Works, and pays a
 *      whole network round trip, a second JWT verification and a second
 *      connection to talk to itself — and still cannot join the booking to the
 *      chat message in one transaction.
 *   3. Extract the rules into a function both callers invoke. This file.
 *
 * WHAT CHANGED, AND WHAT DELIBERATELY DID NOT
 * -------------------------------------------
 * The SQL, the order of operations, the lock order, the rounding, the ledger
 * types, the notification and the messages are all MOVED, not rewritten. A
 * refactor of money code that also improves the money code cannot be reviewed:
 * every difference has to be explained, so there are none to explain. The one
 * structural change is that these functions RETURN their outcome
 *
 *     { ok, status, code, message, data }
 *
 * instead of writing it to a response. The route turns that back into
 * `res.status(status).json(...)` and behaves exactly as before; Scout reads
 * `code` and phrases its own sentence.
 *
 * `code` exists so the dialog manager never has to string-match English. When
 * Scout has to say "wo slot abhi kisi ne le liya" it branches on
 * `code === 'slot_taken'`, not on the wording of a message that a copy edit
 * could change.
 *
 * TRANSACTION OWNERSHIP
 * ---------------------
 * The core functions take a `client` that is ALREADY inside a transaction and
 * never BEGIN, COMMIT or ROLLBACK. That is what lets a caller do more work
 * atomically with the booking. Each has a `*Tx` wrapper that owns the whole
 * transaction for callers who just want the operation; both the route and Scout
 * use the wrappers today.
 *
 * previewCancellation() is the one genuinely NEW function, and it is new because
 * the assistant needs something the REST API never did: the refund arithmetic
 * WITHOUT performing the cancellation, so a user can be asked "PKR 1,600 comes
 * back (80%) — confirm?" and still say no. It computes the split with the same
 * penaltySplit() the executing path uses, so the number quoted in the question
 * is the number the ledger will move.
 */
const crypto = require('crypto');
const pool = require('../db/pool');
const {
  POLICY,
  asNum,
  round2,
  depositFor,
  penaltySplit,
  isLateCancellation,
  lockWallet,
  applyWallet,
  logTxn,
} = require('../utils/escrow');
const { notify } = require('../utils/notify');

/** Uniform failure. `code` is for machines, `message` is for humans. */
function fail(status, code, message) {
  return { ok: false, status, code, message, data: null };
}

function done(status, data, message = null) {
  return { ok: true, status, code: 'ok', message, data };
}

/** slot_date arrives from pg as a Date; bookings stores PKT wall-clock text. */
function localDateStr(value) {
  return value instanceof Date ? value.toLocaleDateString('en-CA') : value;
}

// ─────────────────────────────────────────────────────────────────────────────
// CREATE
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Create a booking. Ledger: player balance -P, player frozen +P, status pending
 * (P = slot price). The 20% at-risk deposit is recorded on the booking but
 * nothing is forfeited yet.
 *
 * Caller must already be inside a transaction. On `ok:false` the caller must
 * ROLLBACK — nothing here has been undone, because the row lock taken on the
 * slot is the transaction's to release.
 */
async function createBooking(client, { userId, slotId, venueId, notes = null }) {
  if (!slotId || !venueId) {
    return fail(400, 'missing_args', 'slotId and venueId required');
  }

  // 1. Lock the slot row atomically — the row lock is what actually settles
  //    simultaneous bookings; the checkout hold below is only a courtesy so two
  //    players don't both fill in the same form (SRS ER1.5).
  const slotRes = await client.query(
    `SELECT s.*, v.name as venue_name, v.price_per_hour, v.owner_id,
            (s.locked_until IS NOT NULL AND s.locked_until > NOW()) AS is_held
       FROM slots s JOIN venues v ON v.id = s.venue_id
      WHERE s.id=$1 AND s.venue_id=$2
      FOR UPDATE OF s`,
    [slotId, venueId],
  );
  if (!slotRes.rows.length) return fail(404, 'slot_not_found', 'Slot not found');

  const slot = slotRes.rows[0];

  if (slot.status !== 'available') {
    return fail(409, 'slot_taken', 'Slot no longer available. Another player just booked it.');
  }

  // Held by somebody else — they are mid-checkout, so this is a 409 even though
  // the slot still reads 'available'.
  if (slot.is_held && slot.locked_by !== userId) {
    return fail(409, 'slot_held',
      'Another player is checking out this slot. Try again in a few minutes.');
  }

  // Escrow = FULL slot price. Deposit = 20% of it (server-side only).
  const basePrice = round2(slot.price);
  const escrowAmount = basePrice;
  const depositAmount = depositFor(basePrice);

  // 2. Lock + check player wallet
  const playerWallet = await lockWallet(client, userId);
  if (!playerWallet || asNum(playerWallet.balance) < escrowAmount) {
    return fail(400, 'insufficient_funds', 'Insufficient wallet balance');
  }

  // 3. Generate QR
  const qrData = crypto.randomUUID();

  // 4. Create booking
  const booking = await client.query(
    `INSERT INTO bookings (player_id, venue_id, slot_id, slot_date, start_time,
       end_time, base_price, security_deposit, deposit_amount, total_amount,
       status, qr_code, notes, owner_id)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,'pending',$11,$12,$13)
     RETURNING *`,
    [
      userId,
      venueId,
      slotId,
      localDateStr(slot.slot_date),
      slot.start_time,
      slot.end_time,
      basePrice,
      escrowAmount,
      depositAmount,
      escrowAmount,
      qrData,
      notes || null,
      slot.owner_id || null,
    ],
  );

  // 5. Mark slot as booked and drop the checkout hold
  await client.query(
    `UPDATE slots SET status='booked', locked_by=null, locked_until=null WHERE id=$1`,
    [slotId],
  );

  // 6. Move the full price out of available balance and into escrow
  const updated = await applyWallet(client, playerWallet.id, {
    balance: -escrowAmount,
    frozen: escrowAmount,
  });

  // 7. Log player transaction
  await logTxn(client, {
    walletId: playerWallet.id,
    userId,
    bookingId: booking.rows[0].id,
    type: 'booking_payment',
    amount: -escrowAmount,
    balanceAfter: updated.balance,
    description: `Booking payment at ${slot.venue_name} (held in escrow)`,
    counterparty: slot.venue_name,
  });

  // venue_name is not a bookings column, but every caller wants it and the row
  // is already here — Scout would otherwise re-query the venue to say the name.
  return done(201, { ...booking.rows[0], venue_name: slot.venue_name });
}

// ─────────────────────────────────────────────────────────────────────────────
// CANCEL — preview, then execute
// ─────────────────────────────────────────────────────────────────────────────

/**
 * The refund arithmetic for one booking, WITHOUT cancelling it. New in S.6 Wave C.
 *
 * Deliberately a plain read: no FOR UPDATE. A preview must not hold a row lock
 * while a human decides, and the executing path re-reads under a lock anyway, so
 * a slot that flips between the two turns is caught there rather than pretended
 * away here. The consequence to be honest about: if the 24-hour boundary is
 * crossed between the preview and the confirmation, the executed refund differs
 * from the quoted one. cancelBooking() returns the real numbers it moved, so the
 * message the user finally sees is always the truth.
 */
async function previewCancellation(client, { userId, bookingId }) {
  const b = await client.query(
    `SELECT b.id, b.status, b.slot_date, b.start_time, b.end_time,
            b.security_deposit, b.deposit_amount, b.base_price,
            v.name AS venue_name, v.city
       FROM bookings b JOIN venues v ON v.id = b.venue_id
      WHERE b.id=$1 AND b.player_id=$2`,
    [bookingId, userId],
  );
  if (!b.rows.length) return fail(404, 'booking_not_found', 'Booking not found');

  const booking = b.rows[0];
  if (!['pending', 'confirmed'].includes(booking.status)) {
    return fail(400, 'not_cancellable',
      `This booking is ${booking.status} and cannot be cancelled.`);
  }

  const escrow = round2(booking.security_deposit);
  const deposit = round2(booking.deposit_amount);
  const late = isLateCancellation(booking.slot_date, booking.start_time);
  const { refund, penalty } = late ? penaltySplit(escrow, deposit) : { refund: escrow, penalty: 0 };

  return done(200, {
    bookingId: booking.id,
    venueName: booking.venue_name,
    city: booking.city,
    slotDate: localDateStr(booking.slot_date),
    startTime: booking.start_time,
    endTime: booking.end_time,
    status: booking.status,
    escrow,
    deposit,
    refund,
    penalty,
    late,
    // Percentages, so a caller can render "80%" without re-deriving it from
    // POLICY and getting it wrong.
    refundPct: escrow > 0 ? Math.round((refund / escrow) * 100) : 100,
    windowHours: POLICY.CANCELLATION_WINDOW_HOURS,
  });
}

/**
 * Cancel a booking.
 *   >= 24h before slot : player balance +P, frozen -P              (full refund)
 *   <  24h before slot : player balance +0.8P, frozen -P, owner +0.2P
 *
 * Caller must already be inside a transaction. Moved verbatim from
 * routes/bookings.js PATCH /:id/cancel — same lock order, same ledger rows, same
 * notification, same wording.
 */
async function cancelBooking(client, { userId, bookingId }) {
  const b = await client.query(
    `SELECT b.*, v.owner_id, v.name AS venue_name, u.name AS player_name
       FROM bookings b
       JOIN venues v ON v.id = b.venue_id
       JOIN users u ON u.id = b.player_id
      WHERE b.id=$1 AND b.player_id=$2 FOR UPDATE OF b`,
    [bookingId, userId],
  );
  if (!b.rows.length) return fail(404, 'booking_not_found', 'Booking not found');

  const booking = b.rows[0];
  if (!['pending', 'confirmed'].includes(booking.status)) {
    return fail(400, 'not_cancellable', 'Cannot cancel this booking');
  }

  // security_deposit holds what is ACTUALLY in escrow for this booking;
  // deposit_amount is the 20% at-risk slice.
  const escrow = round2(booking.security_deposit);
  const deposit = round2(booking.deposit_amount);
  const ownerId = booking.owner_id;
  const playerId = booking.player_id;

  const lateCancel = isLateCancellation(booking.slot_date, booking.start_time);
  const { refund, penalty } = lateCancel
    ? penaltySplit(escrow, deposit)
    : { refund: escrow, penalty: 0 };

  // Lock wallets in a fixed order (player then owner) to avoid deadlocks.
  const playerWallet = await lockWallet(client, playerId);
  const ownerWallet = penalty > 0 ? await lockWallet(client, ownerId) : null;

  const playerAfter = await applyWallet(client, playerWallet.id, {
    balance: refund,
    frozen: -escrow,
  });

  await logTxn(client, {
    walletId: playerWallet.id,
    userId: playerId,
    bookingId,
    type: 'refund',
    amount: refund,
    balanceAfter: playerAfter.balance,
    description: lateCancel
      ? `Late cancellation — ${100 - POLICY.DEPOSIT_PERCENT}% refunded`
      : 'Booking cancellation — full refund',
    counterparty: booking.venue_name,
  });

  if (penalty > 0 && ownerWallet) {
    await logTxn(client, {
      walletId: playerWallet.id,
      userId: playerId,
      bookingId,
      type: 'escrow_release',
      amount: -penalty,
      balanceAfter: playerAfter.balance,
      description: `Late cancellation penalty (${POLICY.DEPOSIT_PERCENT}% deposit to venue)`,
      counterparty: booking.venue_name,
    });

    const ownerAfter = await applyWallet(client, ownerWallet.id, { balance: penalty });
    await logTxn(client, {
      walletId: ownerWallet.id,
      userId: ownerId,
      bookingId,
      type: 'escrow_received',
      amount: penalty,
      balanceAfter: ownerAfter.balance,
      description: 'Received late cancellation penalty',
      counterparty: booking.player_name,
    });

    await notify(client, {
      userId: ownerId,
      bookingId,
      type: 'booking_cancelled_late',
      title: 'Late cancellation',
      body: `${booking.player_name} cancelled within ${POLICY.CANCELLATION_WINDOW_HOURS}h — PKR ${penalty} credited to your wallet.`,
    });
  }

  // Cancel the booking and free the slot
  await client.query(
    `UPDATE bookings SET status='cancelled', cancelled_at=NOW(), cancellation_reason=$1 WHERE id=$2`,
    [lateCancel ? 'late_cancellation' : 'user_cancelled', bookingId],
  );
  await client.query(
    `UPDATE slots SET status='available', locked_by=null, locked_until=null WHERE id=$1`,
    [booking.slot_id],
  );

  const message = lateCancel
    ? `Booking cancelled within ${POLICY.CANCELLATION_WINDOW_HOURS} hours — PKR ${refund} refunded, PKR ${penalty} deposit forfeited to the venue.`
    : `Booking cancelled — PKR ${refund} refunded to your wallet.`;

  return done(200, {
    bookingId,
    venueName: booking.venue_name,
    slotDate: localDateStr(booking.slot_date),
    startTime: booking.start_time,
    refund,
    penalty,
    late: lateCancel,
    escrow,
  }, message);
}

// ─────────────────────────────────────────────────────────────────────────────
// READS — shared so Scout's answers and the REST list can never disagree
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Bookings this user could cancel right now, soonest slot first.
 *
 * Scout asks "which one?" with these as cards, so the order is by WHEN THE SLOT
 * IS, not when it was created (GET /my orders by created_at, which is right for a
 * history list and wrong for "pick the one you want to cancel").
 */
async function listCancellable(client, { userId, limit = 5 }) {
  const runner = client || pool;
  const { rows } = await runner.query(
    `SELECT b.id, b.slot_date, b.start_time, b.end_time, b.status,
            b.security_deposit, b.deposit_amount, b.base_price,
            v.id AS venue_id, v.name AS venue_name, v.city, v.address,
            v.latitude, v.longitude
       FROM bookings b JOIN venues v ON v.id = b.venue_id
      WHERE b.player_id = $1 AND b.status IN ('pending','confirmed')
      ORDER BY b.slot_date ASC, b.start_time ASC
      LIMIT $2`,
    [userId, Math.max(1, Math.min(20, limit))],
  );
  return rows.map((r) => ({ ...r, slot_date: localDateStr(r.slot_date) }));
}

/**
 * The same projection GET /api/bookings/my returns, so a booking rendered in chat
 * and the same booking rendered on the bookings screen carry identical fields.
 */
async function listMyBookings(client, { userId, status = null, limit = 50 }) {
  const runner = client || pool;
  const params = [userId];
  let where = 'b.player_id=$1';
  if (status) {
    where += ' AND b.status=$2';
    params.push(status);
  }
  params.push(Math.max(1, Math.min(50, limit)));
  const { rows } = await runner.query(
    `SELECT b.*, v.name as venue_name, v.city, v.address,
            v.latitude, v.longitude,
            COALESCE(v.venue_photos[1],null) as venue_photo
       FROM bookings b JOIN venues v ON v.id=b.venue_id
      WHERE ${where}
      ORDER BY b.slot_date DESC, b.start_time DESC
      LIMIT $${params.length}`,
    params,
  );
  return rows.map((r) => ({ ...r, slot_date: localDateStr(r.slot_date) }));
}

// ─────────────────────────────────────────────────────────────────────────────
// TRANSACTION WRAPPERS
// ─────────────────────────────────────────────────────────────────────────────
//
// `runInTx` is the only place BEGIN/COMMIT/ROLLBACK is written for these two
// operations. A failed operation (`ok:false`) rolls back exactly like a thrown
// error does: the slot lock and any wallet lock are released and nothing is left
// half-applied. That mattered enough to centralise — the original handlers each
// had five `await client.query("ROLLBACK"); return res.status(...)` pairs, and one
// missing rollback there would leak a locked slot row until the pool recycled the
// connection.
async function runInTx(fn) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const result = await fn(client);
    if (result && result.ok) await client.query('COMMIT');
    else await client.query('ROLLBACK');
    return result;
  } catch (e) {
    try { await client.query('ROLLBACK'); } catch { /* connection already gone */ }
    throw e;
  } finally {
    client.release();
  }
}

const createBookingTx = (input) => runInTx((c) => createBooking(c, input));
const cancelBookingTx = (input) => runInTx((c) => cancelBooking(c, input));

module.exports = {
  createBooking,
  createBookingTx,
  previewCancellation,
  cancelBooking,
  cancelBookingTx,
  listCancellable,
  listMyBookings,
  runInTx,
};
