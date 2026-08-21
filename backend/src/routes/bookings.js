const express = require("express");
const router = express.Router();
const pool = require("../db/pool");
const authMiddleware = require("../middleware/authMiddleware");
const checkRole = require("../middleware/roleMiddleware");
const crypto = require("crypto");
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
} = require("../utils/escrow");
const { notify } = require("../utils/notify");

// POST /api/bookings — create booking (player only)
// Ledger: player balance -P, player frozen +P, status pending (P = slot price).
// The 20% at-risk deposit is stored on the booking but nothing is forfeited yet.
router.post(
  "/",
  authMiddleware,
  checkRole("player"),
  async (req, res, next) => {
    const { slotId, venueId, notes } = req.body;
    if (!slotId || !venueId)
      return res
        .status(400)
        .json({ success: false, message: "slotId and venueId required" });

    const client = await pool.connect();
    try {
      await client.query("BEGIN");

      // 1. Lock the slot row atomically — only proceed if slot is available (handles race conditions at DB level)
      const slotRes = await client.query(
        `SELECT s.*, v.name as venue_name, v.price_per_hour, v.owner_id
       FROM slots s JOIN venues v ON v.id = s.venue_id
       WHERE s.id=$1 AND s.venue_id=$2
         AND s.status = 'available'
       FOR UPDATE`,
        [slotId, venueId],
      );

      if (!slotRes.rows.length) {
        await client.query("ROLLBACK");
        return res
          .status(409)
          .json({
            success: false,
            message: "Slot no longer available. Another player just booked it.",
          });
      }

      const slot = slotRes.rows[0];

      // Escrow = FULL slot price. Deposit = 20% of it (server-side only).
      const basePrice = round2(slot.price);
      const escrowAmount = basePrice;
      const depositAmount = depositFor(basePrice);

      // 2. Lock + check player wallet
      const playerWallet = await lockWallet(client, req.user.id);

      if (!playerWallet || asNum(playerWallet.balance) < escrowAmount) {
        await client.query("ROLLBACK");
        return res
          .status(400)
          .json({ success: false, message: "Insufficient wallet balance" });
      }

      // 3. Generate QR
      const qrData = crypto.randomUUID();

      // 4. Create booking
      const localSlotDateStr =
        slot.slot_date instanceof Date
          ? slot.slot_date.toLocaleDateString("en-CA")
          : slot.slot_date;
      const booking = await client.query(
        `
      INSERT INTO bookings (player_id, venue_id, slot_id, slot_date, start_time,
        end_time, base_price, security_deposit, deposit_amount, total_amount,
        status, qr_code, notes, owner_id)
      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,'pending',$11,$12,$13)
      RETURNING *`,
        [
          req.user.id,
          venueId,
          slotId,
          localSlotDateStr,
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

      // 5. Mark slot as booked
      await client.query(
        `UPDATE slots SET status='booked', locked_by=null WHERE id=$1`,
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
        userId: req.user.id,
        bookingId: booking.rows[0].id,
        type: "booking_payment",
        amount: -escrowAmount,
        balanceAfter: updated.balance,
        description: `Booking payment at ${slot.venue_name} (held in escrow)`,
        counterparty: slot.venue_name,
      });

      await client.query("COMMIT");
      res.status(201).json({ success: true, data: booking.rows[0] });
    } catch (e) {
      await client.query("ROLLBACK");
      console.error("Booking creation error:", e);
      next(e);
    } finally {
      client.release();
    }
  },
);

// GET /api/bookings/my — player's bookings
router.get("/my", authMiddleware, async (req, res, next) => {
  try {
    const { status } = req.query;
    let where = "b.player_id=$1";
    const params = [req.user.id];
    if (status) {
      where += ` AND b.status=$2`;
      params.push(status);
    }
    const result = await pool.query(
      `
      SELECT b.*, v.name as venue_name, v.city, v.address,
        COALESCE(v.venue_photos[1],null) as venue_photo
      FROM bookings b JOIN venues v ON v.id=b.venue_id
      WHERE ${where}
      ORDER BY b.created_at DESC LIMIT 50`,
      params,
    );
    res.json({ success: true, data: result.rows });
  } catch (e) {
    next(e);
  }
});

// GET /api/bookings/:id — booking detail
router.get("/:id", authMiddleware, async (req, res, next) => {
  try {
    const result = await pool.query(
      `
      SELECT b.*, v.name as venue_name, v.city, v.address, v.latitude, v.longitude,
        COALESCE(v.venue_photos[1],null) as venue_photo,
        u.name as player_name
      FROM bookings b
      JOIN venues v ON v.id=b.venue_id
      JOIN users u ON u.id=b.player_id
      WHERE b.id=$1 AND (b.player_id=$2 OR $3='owner')`,
      [req.params.id, req.user.id, req.user.role],
    );
    if (!result.rows.length)
      return res
        .status(404)
        .json({ success: false, message: "Booking not found" });
    res.json({ success: true, data: result.rows[0] });
  } catch (e) {
    next(e);
  }
});

// PATCH /api/bookings/:id/cancel — player cancels
// >= 24h before slot : player balance +P, frozen -P              (full refund)
// <  24h before slot : player balance +0.8P, frozen -P, owner +0.2P
router.patch("/:id/cancel", authMiddleware, async (req, res, next) => {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    const b = await client.query(
      `SELECT b.*, v.owner_id, v.name AS venue_name, u.name AS player_name
       FROM bookings b
       JOIN venues v ON v.id = b.venue_id
       JOIN users u ON u.id = b.player_id
       WHERE b.id=$1 AND b.player_id=$2 FOR UPDATE OF b`,
      [req.params.id, req.user.id],
    );

    if (!b.rows.length) {
      await client.query("ROLLBACK");
      return res
        .status(404)
        .json({ success: false, message: "Booking not found" });
    }

    const booking = b.rows[0];
    if (!["pending", "confirmed"].includes(booking.status)) {
      await client.query("ROLLBACK");
      return res
        .status(400)
        .json({ success: false, message: "Cannot cancel this booking" });
    }

    // security_deposit holds what is ACTUALLY in escrow for this booking;
    // deposit_amount is the 20% at-risk slice.
    const escrow = round2(booking.security_deposit);
    const deposit = round2(booking.deposit_amount);
    const ownerId = booking.owner_id;
    const playerId = booking.player_id;
    const bookingId = booking.id;

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
      type: "refund",
      amount: refund,
      balanceAfter: playerAfter.balance,
      description: lateCancel
        ? `Late cancellation — ${100 - POLICY.DEPOSIT_PERCENT}% refunded`
        : "Booking cancellation — full refund",
      counterparty: booking.venue_name,
    });

    if (penalty > 0 && ownerWallet) {
      await logTxn(client, {
        walletId: playerWallet.id,
        userId: playerId,
        bookingId,
        type: "escrow_release",
        amount: -penalty,
        balanceAfter: playerAfter.balance,
        description: `Late cancellation penalty (${POLICY.DEPOSIT_PERCENT}% deposit to venue)`,
        counterparty: booking.venue_name,
      });

      const ownerAfter = await applyWallet(client, ownerWallet.id, {
        balance: penalty,
      });
      await logTxn(client, {
        walletId: ownerWallet.id,
        userId: ownerId,
        bookingId,
        type: "escrow_received",
        amount: penalty,
        balanceAfter: ownerAfter.balance,
        description: "Received late cancellation penalty",
        counterparty: booking.player_name,
      });

      await notify(client, {
        userId: ownerId,
        bookingId,
        type: "booking_cancelled_late",
        title: "Late cancellation",
        body: `${booking.player_name} cancelled within ${POLICY.CANCELLATION_WINDOW_HOURS}h — PKR ${penalty} credited to your wallet.`,
      });
    }

    // Cancel the booking and free the slot
    await client.query(
      `UPDATE bookings SET status='cancelled', cancelled_at=NOW(), cancellation_reason=$1 WHERE id=$2`,
      [lateCancel ? "late_cancellation" : "user_cancelled", bookingId],
    );

    await client.query(
      `UPDATE slots SET status='available', locked_at=null, locked_by=null WHERE id=$1`,
      [booking.slot_id],
    );

    await client.query("COMMIT");
    const msg = lateCancel
      ? `Booking cancelled within ${POLICY.CANCELLATION_WINDOW_HOURS} hours — PKR ${refund} refunded, PKR ${penalty} deposit forfeited to the venue.`
      : `Booking cancelled — PKR ${refund} refunded to your wallet.`;
    res.json({ success: true, message: msg });
  } catch (e) {
    await client.query("ROLLBACK");
    console.error("Booking cancellation error:", e);
    next(e);
  } finally {
    client.release();
  }
});

// POST /api/bookings/:id/resolve — owner settles a confirmed booking
//   completed → escrow released in full to the owner (same ledger as QR check-in)
//   no_show   → 80% back to player, 20% deposit to owner, trust_score -10
router.post(
  "/:id/resolve",
  authMiddleware,
  checkRole("owner"),
  async (req, res, next) => {
    const client = await pool.connect();
    try {
      const { status } = req.body;
      if (!["completed", "no_show"].includes(status)) {
        return res
          .status(400)
          .json({
            success: false,
            message: "Invalid status. Must be completed or no_show",
          });
      }

      await client.query("BEGIN");

      // Check if booking belongs to owner's venue and is confirmed/checked_in
      const b = await client.query(
        `
      SELECT b.*, v.owner_id, u.name as player_name, v.name as venue_name
      FROM bookings b
      JOIN venues v ON v.id = b.venue_id
      JOIN users u ON u.id = b.player_id
      WHERE b.id=$1 FOR UPDATE OF b`,
        [req.params.id],
      );

      if (!b.rows.length || b.rows[0].owner_id !== req.user.id) {
        await client.query("ROLLBACK");
        return res
          .status(404)
          .json({
            success: false,
            message: "Booking not found or unauthorized",
          });
      }

      const booking = b.rows[0];

      // Already checked in → escrow was released at the scan; nothing left to move.
      if (booking.status === "checked_in" && status === "completed") {
        await client.query("COMMIT");
        return res.json({
          success: true,
          message: "Booking already settled at check-in.",
        });
      }

      if (booking.status !== "confirmed") {
        await client.query("ROLLBACK");
        return res
          .status(400)
          .json({
            success: false,
            message: "Booking is already resolved or cancelled",
          });
      }

      const escrow = round2(booking.security_deposit);
      const deposit = round2(booking.deposit_amount);
      const isNoShow = status === "no_show";
      const { refund, penalty } = isNoShow
        ? penaltySplit(escrow, deposit)
        : { refund: 0, penalty: escrow };

      const playerWallet = await lockWallet(client, booking.player_id);
      const ownerWallet = await lockWallet(client, req.user.id);

      const playerAfter = await applyWallet(client, playerWallet.id, {
        balance: refund,
        frozen: -escrow,
      });
      const ownerAfter = await applyWallet(client, ownerWallet.id, {
        balance: penalty,
      });

      if (refund > 0) {
        await logTxn(client, {
          walletId: playerWallet.id,
          userId: booking.player_id,
          bookingId: booking.id,
          type: "refund",
          amount: refund,
          balanceAfter: playerAfter.balance,
          description: `No-show — ${100 - POLICY.DEPOSIT_PERCENT}% returned`,
          counterparty: booking.venue_name,
        });
      }

      await logTxn(client, {
        walletId: playerWallet.id,
        userId: booking.player_id,
        bookingId: booking.id,
        type: isNoShow ? "no_show_penalty" : "escrow_release",
        amount: -penalty,
        balanceAfter: playerAfter.balance,
        description: isNoShow
          ? `No-show — ${POLICY.DEPOSIT_PERCENT}% deposit forfeited to venue`
          : "Escrow released to venue owner",
        counterparty: booking.venue_name,
      });

      await logTxn(client, {
        walletId: ownerWallet.id,
        userId: req.user.id,
        bookingId: booking.id,
        type: "escrow_received",
        amount: penalty,
        balanceAfter: ownerAfter.balance,
        description: isNoShow
          ? "Received no-show deposit"
          : "Received booking payment",
        counterparty: booking.player_name,
      });

      if (isNoShow) {
        await client.query(
          `UPDATE player_profiles SET trust_score=GREATEST(trust_score-$1,0) WHERE user_id=$2`,
          [POLICY.NO_SHOW_TRUST_PENALTY, booking.player_id],
        );
        await notify(client, {
          userId: booking.player_id,
          bookingId: booking.id,
          type: "booking_no_show",
          title: "Marked as no-show",
          body: `You missed your slot at ${booking.venue_name}. PKR ${refund} returned, PKR ${penalty} deposit forfeited, trust score -${POLICY.NO_SHOW_TRUST_PENALTY}.`,
        });
      }

      // Update booking status ('completed' is settled as checked_in — money delivered)
      await client.query(
        `UPDATE bookings
            SET status=$1,
                checked_in_at = COALESCE(checked_in_at, CASE WHEN $1='checked_in' THEN NOW() END),
                no_show_at = COALESCE(no_show_at, CASE WHEN $1='no_show' THEN NOW() END),
                no_show_processed = CASE WHEN $1='no_show' THEN true ELSE no_show_processed END
          WHERE id=$2`,
        [isNoShow ? "no_show" : "checked_in", booking.id],
      );

      await client.query("COMMIT");
      res.json({
        success: true,
        message: isNoShow
          ? `Marked as no-show. PKR ${penalty} credited to your wallet, PKR ${refund} returned to the player.`
          : `Booking completed. PKR ${penalty} credited to your wallet.`,
      });
    } catch (e) {
      await client.query("ROLLBACK");
      console.error("Resolve booking error:", e);
      next(e);
    } finally {
      client.release();
    }
  },
);

module.exports = router;
