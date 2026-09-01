const express = require("express");
const router = express.Router();
const pool = require("../db/pool");
const authMiddleware = require("../middleware/authMiddleware");
const checkRole = require("../middleware/roleMiddleware");
const {
  POLICY,
  round2,
  penaltySplit,
  lockWallet,
  applyWallet,
  logTxn,
} = require("../utils/escrow");
// FR8.15 — one implementation of book/cancel, shared with the assistant.
const {
  createBookingTx,
  cancelBookingTx,
} = require("../services/bookingService");
const { notify } = require("../utils/notify");
const { recomputeTrust } = require("../utils/trustScore");

// POST /api/bookings — create booking (player only)
// Ledger: player balance -P, player frozen +P, status pending (P = slot price).
// The 20% at-risk deposit is stored on the booking but nothing is forfeited yet.
//
// The rules moved to services/bookingService.js in S.6 Wave C so the assistant
// creates bookings through this logic rather than a second copy of it (FR8.15).
// What is left here is transport: read the request, call the service, shape the
// response. The status codes, the messages and the ledger are unchanged.
router.post(
  "/",
  authMiddleware,
  checkRole("player"),
  async (req, res, next) => {
    const { slotId, venueId, notes } = req.body;
    try {
      const result = await createBookingTx({
        userId: req.user.id,
        slotId,
        venueId,
        notes,
      });
      if (!result.ok) {
        return res
          .status(result.status)
          .json({ success: false, message: result.message });
      }
      res.status(201).json({ success: true, data: result.data });
    } catch (e) {
      console.error("Booking creation error:", e);
      next(e);
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
//
// Same extraction as POST above: the split, the lock order, the ledger rows and
// the owner notification now live in services/bookingService.js, which Scout also
// calls after showing the user a refund preview.
router.patch("/:id/cancel", authMiddleware, async (req, res, next) => {
  try {
    const result = await cancelBookingTx({
      userId: req.user.id,
      bookingId: req.params.id,
    });
    if (!result.ok) {
      return res
        .status(result.status)
        .json({ success: false, message: result.message });
    }
    res.json({ success: true, message: result.message });
  } catch (e) {
    console.error("Booking cancellation error:", e);
    next(e);
  }
});

// POST /api/bookings/:id/resolve — owner settles a confirmed booking
//   completed → escrow released in full to the owner (same ledger as QR check-in)
//   no_show   → 80% back to player, 20% deposit to owner, trust score recomputed
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
        await notify(client, {
          userId: booking.player_id,
          bookingId: booking.id,
          type: "booking_no_show",
          title: "Marked as no-show",
          body: `You missed your slot at ${booking.venue_name}. PKR ${refund} returned, PKR ${penalty} deposit forfeited, and your trust score has been updated.`,
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

      // Trust Score 2.0: recompute now that the booking's final status is set,
      // so attendance_rate reflects this outcome (utils/trustScore.js). Only a
      // no-show moves trust here; a checked_in settlement lets it accrue via
      // reviews instead.
      if (isNoShow) {
        await recomputeTrust(client, booking.player_id);
      }

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
