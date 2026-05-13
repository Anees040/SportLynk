const express = require("express");
const router = express.Router();
const pool = require("../db/pool");
const authMiddleware = require("../middleware/authMiddleware");
const checkRole = require("../middleware/roleMiddleware");
const crypto = require("crypto");

// POST /api/bookings — create booking (player only)
router.post(
  "/",
  authMiddleware,
  checkRole("player"),
  async (req, res, next) => {
    const { slotId, venueId, notes, paymentType = "upfront" } = req.body;
    if (!slotId || !venueId)
      return res
        .status(400)
        .json({ success: false, message: "slotId and venueId required" });

    const client = await pool.connect();
    try {
      await client.query("BEGIN");

      // 1. Lock the slot row atomically — only proceed if slot is available (handles race conditions at DB level)
      const slotRes = await client.query(
        `SELECT s.*, v.name as venue_name, v.price_per_hour, v.owner_id,
              v.upfront_percent, v.discount_percent
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
      const basePrice = parseFloat(slot.price);
      const upfrontPct = parseFloat(slot.upfront_percent || 30);
      const discountPct = parseFloat(slot.discount_percent || 0);

      let amountToPay = 0;
      let totalAmount = basePrice;

      if (paymentType === "full") {
        const discount = basePrice * (discountPct / 100);
        totalAmount = basePrice - discount;
        amountToPay = Math.round(totalAmount);
      } else {
        // upfront
        amountToPay = Math.round(basePrice * (upfrontPct / 100));
        totalAmount = basePrice; // remainder paid at venue
      }

      // 2. Check player wallet
      const playerWallet = await client.query(
        `SELECT * FROM wallets WHERE user_id=$1 FOR UPDATE`,
        [req.user.id],
      );

      if (
        !playerWallet.rows.length ||
        parseFloat(playerWallet.rows[0].balance) < amountToPay
      ) {
        await client.query("ROLLBACK");
        return res
          .status(400)
          .json({ success: false, message: "Insufficient wallet balance" });
      }

      // 4. Generate QR
      const qrData = crypto.randomUUID();

      // 5. Create booking
      const localSlotDateStr =
        slot.slot_date instanceof Date
          ? slot.slot_date.toLocaleDateString("en-CA")
          : slot.slot_date;
      const booking = await client.query(
        `
      INSERT INTO bookings (player_id, venue_id, slot_id, slot_date, start_time,
        end_time, base_price, security_deposit, total_amount, status, qr_code, notes, owner_id)
      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,'pending',$10,$11,$12)
      RETURNING *`,
        [
          req.user.id,
          venueId,
          slotId,
          localSlotDateStr,
          slot.start_time,
          slot.end_time,
          basePrice,
          amountToPay,
          totalAmount,
          qrData,
          notes || null,
          slot.owner_id || null,
        ],
      );

      // 6. Mark slot as booked
      await client.query(
        `UPDATE slots SET status='booked', locked_by=null WHERE id=$1`,
        [slotId],
      );

      // 7. Deduct from player available balance and ADD to player frozen balance (escrow)
      const newPlayerBalance =
        parseFloat(playerWallet.rows[0].balance) - amountToPay;
      const newPlayerFrozen =
        parseFloat(playerWallet.rows[0].frozen_balance || 0) + amountToPay;
      await client.query(
        `UPDATE wallets SET balance=$1, frozen_balance=$2 WHERE id=$3`,
        [newPlayerBalance, newPlayerFrozen, playerWallet.rows[0].id],
      );

      // 8. Log player transaction
      await client.query(
        `
      INSERT INTO transactions (wallet_id, user_id, booking_id, type, amount,
        balance_after, description, counterparty_name)
      VALUES ($1,$2,$3,'booking_payment',$4,$5,$6,$7)`,
        [
          playerWallet.rows[0].id,
          req.user.id,
          booking.rows[0].id,
          -amountToPay,
          newPlayerBalance,
          `Booking payment at ${slot.venue_name}`,
          slot.venue_name,
        ],
      );

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
router.patch("/:id/cancel", authMiddleware, async (req, res, next) => {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    const b = await client.query(
      `SELECT b.*, v.owner_id
       FROM bookings b
       JOIN venues v ON v.id = b.venue_id
       WHERE b.id=$1 AND b.player_id=$2 FOR UPDATE`,
      [req.params.id, req.user.id],
    );

    if (!b.rows.length) {
      await client.query("ROLLBACK");
      return res
        .status(404)
        .json({ success: false, message: "Booking not found" });
    }

    if (!["pending", "confirmed"].includes(b.rows[0].status)) {
      await client.query("ROLLBACK");
      return res
        .status(400)
        .json({ success: false, message: "Cannot cancel this booking" });
    }

    // Escrow / Cancellation Logic
    const deposit = parseFloat(b.rows[0].security_deposit);
    const ownerId = b.rows[0].owner_id;
    const playerId = b.rows[0].player_id;
    const bookingId = req.params.id;

    // Calculate time difference for late cancellation penalty (12 hours)
    // Safely extract local YYYY-MM-DD from the DB Date object to prevent UTC shifts
    const d = b.rows[0].slot_date;
    const slotDateStr = d instanceof Date ? d.toLocaleDateString("en-CA") : d;
    const slotDateTimeStr = `${slotDateStr}T${b.rows[0].start_time}`;
    const slotDateTime = new Date(slotDateTimeStr);
    const now = new Date();

    // Difference in hours
    const diffHours = (slotDateTime - now) / (1000 * 60 * 60);
    const isLateCancel = diffHours < 12;

    if (isLateCancel) {
      // Late cancel: Player loses deposit, Owner gets it

      // 1. Deduct from Player's frozen balance
      await client.query(
        `UPDATE wallets SET frozen_balance=GREATEST(frozen_balance-$1, 0) WHERE user_id=$2`,
        [deposit, playerId],
      );

      // 2. Add to Owner's available balance
      const ownerWallet = await client.query(
        `UPDATE wallets SET balance=balance+$1 WHERE user_id=$2 RETURNING id, balance`,
        [deposit, ownerId],
      );

      // 3. Transactions
      const playerWallet = await client.query(
        `SELECT id, balance FROM wallets WHERE user_id=$1`,
        [playerId],
      );

      await client.query(
        `
        INSERT INTO transactions (wallet_id, user_id, booking_id, type, amount, balance_after, description)
        VALUES ($1,$2,$3,'escrow_release',$4,$5,'Late cancellation penalty to owner')`,
        [
          playerWallet.rows[0].id,
          playerId,
          bookingId,
          -deposit,
          playerWallet.rows[0].balance,
        ],
      );

      await client.query(
        `
        INSERT INTO transactions (wallet_id, user_id, booking_id, type, amount, balance_after, description)
        VALUES ($1,$2,$3,'escrow_received',$4,$5,'Received late cancellation penalty')`,
        [
          ownerWallet.rows[0].id,
          ownerId,
          bookingId,
          deposit,
          ownerWallet.rows[0].balance,
        ],
      );
    } else {
      // Early cancel: Player gets a full refund

      // 1. Deduct from Player's frozen balance
      await client.query(
        `UPDATE wallets SET frozen_balance=GREATEST(frozen_balance-$1, 0) WHERE user_id=$2`,
        [deposit, playerId],
      );

      // 2. Add back to Player's available balance
      const playerWallet = await client.query(
        `UPDATE wallets SET balance=balance+$1 WHERE user_id=$2 RETURNING balance, id`,
        [deposit, playerId],
      );

      // 3. Transaction
      await client.query(
        `
        INSERT INTO transactions (wallet_id, user_id, booking_id, type, amount, balance_after, description)
        VALUES ($1,$2,$3,'refund',$4,$5,'Booking cancellation refund')`,
        [
          playerWallet.rows[0].id,
          playerId,
          bookingId,
          deposit,
          playerWallet.rows[0].balance,
        ],
      );
    }

    // Cancel the booking and free the slot
    await client.query(
      `UPDATE bookings SET status='cancelled', cancelled_at=NOW(), cancellation_reason=$1 WHERE id=$2`,
      [isLateCancel ? "late_cancellation" : "user_cancelled", bookingId],
    );

    await client.query(
      `UPDATE slots SET status='available', locked_at=null, locked_by=null WHERE id=$1`,
      [b.rows[0].slot_id],
    );

    await client.query("COMMIT");
    const msg = isLateCancel
      ? "Booking cancelled. Note: Cancellation was within 12 hours, deposit forfeited."
      : "Booking cancelled and deposit refunded to your wallet.";
    res.json({ success: true, message: msg });
  } catch (e) {
    await client.query("ROLLBACK");
    console.error("Booking cancellation error:", e);
    next(e);
  } finally {
    client.release();
  }
});

// POST /api/bookings/:id/resolve — Owner resolve booking (completed or no_show)
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
      WHERE b.id=$1 FOR UPDATE`,
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

      if (!["confirmed", "checked_in"].includes(b.rows[0].status)) {
        await client.query("ROLLBACK");
        return res
          .status(400)
          .json({
            success: false,
            message: "Booking is already resolved or cancelled",
          });
      }

      const deposit = parseFloat(b.rows[0].security_deposit || 0);

      // Debit player frozen balance
      await client.query(
        `UPDATE wallets SET frozen_balance=GREATEST(frozen_balance-$1, 0) WHERE user_id=$2`,
        [deposit, b.rows[0].player_id],
      );

      // Credit owner available balance
      const ownerWallet = await client.query(
        `UPDATE wallets SET balance=balance+$1 WHERE user_id=$2 RETURNING id, balance`,
        [deposit, req.user.id],
      );

      // Transaction for player (Frozen Escrow Released)
      const playerWallet = await client.query(
        `SELECT id, balance FROM wallets WHERE user_id=$1`,
        [b.rows[0].player_id],
      );
      await client.query(
        `
      INSERT INTO transactions (wallet_id, user_id, booking_id, type, amount, balance_after, description, counterparty_name)
      VALUES ($1,$2,$3,'escrow_release',$4,$5,$6,$7)`,
        [
          playerWallet.rows[0].id,
          b.rows[0].player_id,
          req.params.id,
          -deposit,
          playerWallet.rows[0].balance,
          `Escrow released to venue owner`,
          b.rows[0].venue_name,
        ],
      );

      // Transaction for owner (Escrow Received)
      await client.query(
        `
      INSERT INTO transactions (wallet_id, user_id, booking_id, type, amount, balance_after, description, counterparty_name)
      VALUES ($1,$2,$3,'escrow_received',$4,$5,$6,$7)`,
        [
          ownerWallet.rows[0].id,
          req.user.id,
          req.params.id,
          deposit,
          ownerWallet.rows[0].balance,
          `Received booking payment`,
          b.rows[0].player_name,
        ],
      );

      // Update booking status
      await client.query(`UPDATE bookings SET status=$1 WHERE id=$2`, [
        status,
        req.params.id,
      ]);

      await client.query("COMMIT");
      res.json({
        success: true,
        message: `Booking marked as ${status} and funds transferred to your wallet.`,
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
