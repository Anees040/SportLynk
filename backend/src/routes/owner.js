const express = require("express");
const router = express.Router();
const pool = require("../db/pool");
const auth = require("../middleware/authMiddleware");
const checkRole = require("../middleware/roleMiddleware");
const {
  POLICY,
  round2,
  penaltySplit,
  lockWallet,
  applyWallet,
  logTxn,
} = require("../utils/escrow");
const { notify } = require("../utils/notify");

router.use(auth, checkRole("owner"));

async function autoGenerateVenueIfMissing(ownerId) {
  const checkVenues = await pool.query('SELECT COUNT(*) FROM venues WHERE owner_id=$1', [ownerId]);
  if (parseInt(checkVenues.rows[0].count) === 0) {
    const profileRes = await pool.query("SELECT * FROM owner_profiles WHERE user_id=$1 AND verification_status='approved'", [ownerId]);
    if (profileRes.rows.length > 0) {
      const op = profileRes.rows[0];
      const sportType = op.sport_types && op.sport_types.length > 0 ? op.sport_types[0].toLowerCase() : 'football';
      const venueName = op.ground_name || op.business_name || 'My Venue';
      const vRes = await pool.query(
        `INSERT INTO venues (owner_id, name, description, sport_type, city, address, base_price, price_per_hour, upfront_percent, venue_photos, operating_hours_from, operating_hours_to, is_active, rating, total_reviews)
         VALUES ($1, $2, 'Venue auto-generated', $3, $4, $5, 2000, 2000, 20, $6, '08:00:00', '23:00:00', true, 0, 0)
         RETURNING id`,
        [ownerId, venueName, sportType, op.city || 'Unknown', op.full_address || 'Unknown', op.ground_photos || []]
      );
      const venueId = vRes.rows[0].id;
      for (let i = 0; i < 14; i++) {
        const d = new Date();
        d.setDate(d.getDate() + i);
        const dateStr = d.toLocaleDateString("en-CA");
        for (let hour = 18; hour <= 22; hour++) {
          const sh = hour.toString().padStart(2, "0") + ":00:00";
          const eh = (hour + 1).toString().padStart(2, "0") + ":00:00";
          await pool.query(
            "INSERT INTO slots (venue_id, slot_date, start_time, end_time, price, status) VALUES ($1,$2,$3,$4,$5,'available')",
            [venueId, dateStr, sh, eh, 2000]
          );
        }
      }
    }
  }
}

// GET /api/owner/dashboard — optimized with Promise.all
router.get("/dashboard", async (req, res, next) => {
  try {
    const ownerId = req.user.id;
    await autoGenerateVenueIfMissing(ownerId);
    const today = new Date().toLocaleDateString("en-CA");

    // Run all queries in PARALLEL — reduces latency from ~5x to ~1x round-trip
    const [venueRes, statsRes, upcomingRes, walletRes, escrowRes] = await Promise.all([
      pool.query(
        "SELECT * FROM venues WHERE owner_id=$1 AND is_active=true ORDER BY created_at ASC LIMIT 1",
        [ownerId],
      ),
      pool.query(
        `SELECT
           COUNT(*) FILTER (WHERE b.slot_date=$1::DATE AND b.status IN ('confirmed','checked_in')) AS "bookingsToday",
           COALESCE(SUM(b.security_deposit) FILTER (WHERE b.status='checked_in' AND b.slot_date=$1::DATE), 0) AS "revenueToday",
           COUNT(*) FILTER (WHERE b.status='pending') AS "pendingCount"
         FROM bookings b JOIN venues v ON b.venue_id=v.id WHERE v.owner_id=$2`,
        [today, ownerId],
      ),
      pool.query(
        `SELECT b.id, b.status, b.start_time, b.end_time, b.slot_date, b.total_amount, b.security_deposit,
                u.name AS player_name, COALESCE(pp.trust_score,100) AS trust_score
         FROM bookings b
         JOIN users u ON b.player_id=u.id
         LEFT JOIN player_profiles pp ON pp.user_id=u.id
         JOIN venues v ON b.venue_id=v.id
         WHERE v.owner_id=$1 AND b.slot_date>=$2::DATE AND b.status IN ('confirmed','checked_in')
         ORDER BY b.slot_date ASC, b.start_time ASC LIMIT 10`,
        [ownerId, today],
      ),
      pool.query(
        "SELECT balance, frozen_balance FROM wallets WHERE user_id=$1",
        [ownerId],
      ),
      // Sum of deposits that are frozen with players (pending bookings at this owner's venues)
      pool.query(
        `SELECT COALESCE(SUM(b.security_deposit), 0) AS pending_escrow
         FROM bookings b
         JOIN venues v ON b.venue_id=v.id
         WHERE v.owner_id=$1 AND b.status='pending'`,
        [ownerId],
      ),
    ]);

    res.json({
      success: true,
      data: {
        venue: venueRes.rows[0] || null,
        stats: statsRes.rows[0] || { bookingsToday: 0, revenueToday: 0, pendingCount: 0 },
        upcomingBookings: upcomingRes.rows,
        wallet: walletRes.rows[0] || { balance: 0, frozen_balance: 0 },
        pendingEscrow: parseFloat(escrowRes.rows[0]?.pending_escrow || 0),
      },
    });
  } catch (e) {
    next(e);
  }
});

// GET /api/owner/venues — returns ALL active venues owned by this owner (multi-venue)
router.get("/venues", async (req, res, next) => {
  try {
    await autoGenerateVenueIfMissing(req.user.id);
    const result = await pool.query(
      `SELECT v.id, v.name, v.sport_type, v.city, v.address,
              v.price_per_hour, v.rating, v.total_reviews,
              v.venue_photos, v.operating_hours_from, v.operating_hours_to,
              v.is_active, v.created_at,
              (SELECT COUNT(*) FROM bookings b WHERE b.venue_id = v.id AND b.status='pending') AS pending_bookings,
              (SELECT COUNT(*) FROM bookings b WHERE b.venue_id = v.id AND b.slot_date = CURRENT_DATE AND b.status IN ('confirmed','checked_in')) AS todays_bookings
       FROM venues v
       WHERE v.owner_id = $1
       ORDER BY v.is_active DESC, v.created_at ASC`,
      [req.user.id],
    );
    res.json({ success: true, data: result.rows });
  } catch (e) {
    next(e);
  }
});

// POST /api/owner/venues
router.post("/venues", async (req, res, next) => {
  try {
    const ownerId = req.user.id;
    const {
      groundName,
      sportTypes,
      city,
      fullAddress,
      pricePerHour,
      operatingHoursFrom,
      operatingHoursTo,
      groundPhotos
    } = req.body;

    const sportType = sportTypes && sportTypes.length > 0 ? sportTypes[0].toLowerCase() : 'football';

    // Set is_active = false so it requires admin approval
    const vRes = await pool.query(
      `INSERT INTO venues (owner_id, name, description, sport_type, city, address, base_price, price_per_hour, upfront_percent, venue_photos, operating_hours_from, operating_hours_to, is_active, rating, total_reviews)
       VALUES ($1, $2, 'Venue added via owner dashboard', $3, $4, $5, $6, $6, 20, $7, $8, $9, false, 0, 0)
       RETURNING id`,
      [ownerId, groundName, sportType, city, fullAddress, pricePerHour, groundPhotos || [], operatingHoursFrom, operatingHoursTo]
    );

    const venueId = vRes.rows[0].id;

    // Auto-generate some slots so it's bookable immediately
    for (let i = 0; i < 14; i++) {
      const d = new Date();
      d.setDate(d.getDate() + i);
      const dateStr = d.toLocaleDateString("en-CA");
      for (let hour = 18; hour <= 22; hour++) {
        const sh = hour.toString().padStart(2, "0") + ":00:00";
        const eh = (hour + 1).toString().padStart(2, "0") + ":00:00";
        await pool.query(
          "INSERT INTO slots (venue_id, slot_date, start_time, end_time, price, status) VALUES ($1,$2,$3,$4,$5,'available')",
          [venueId, dateStr, sh, eh, pricePerHour]
        );
      }
    }

    res.json({ success: true, message: 'Venue successfully created', data: { id: venueId } });
  } catch (e) {
    next(e);
  }
});

// PATCH /api/owner/venues/:id
router.patch("/venues/:id", async (req, res, next) => {
  try {
    const ownerId = req.user.id;
    const { id } = req.params;
    const { description, price_per_hour, venue_photos } = req.body;

    const vCheck = await pool.query('SELECT id FROM venues WHERE id=$1 AND owner_id=$2', [id, ownerId]);
    if (!vCheck.rows.length) {
      return res.status(404).json({ success: false, message: 'Venue not found or unauthorized' });
    }

    const updates = [];
    const values = [];
    let i = 1;

    if (description !== undefined) {
      updates.push(`description=$${i++}`);
      values.push(description);
    }
    // upfront_percent is deliberately NOT accepted from the client: the deposit is
    // a platform policy (POLICY.DEPOSIT_PERCENT) computed server-side only.
    if (price_per_hour !== undefined) {
      updates.push(`price_per_hour=$${i++}`);
      values.push(price_per_hour);
      // also update base_price to keep them in sync
      updates.push(`base_price=$${i++}`);
      values.push(price_per_hour);
    }
    if (venue_photos !== undefined) {
      updates.push(`venue_photos=$${i++}`);
      values.push(venue_photos);
    }

    if (updates.length > 0) {
      values.push(id);
      await pool.query(
        `UPDATE venues SET ${updates.join(', ')} WHERE id=$${i}`,
        values
      );
    }

    res.json({ success: true, message: 'Venue updated successfully' });
  } catch (e) {
    next(e);
  }
});

// GET /api/owner/bookings?status=pending|confirmed|rejected
router.get("/bookings", async (req, res, next) => {
  try {
    const ownerId = req.user.id;
    const status = req.query.status || "pending";
    // The Rejected tab doubles as the "didn't happen" archive: owner rejections
    // land on 'rejected', player cancellations on 'cancelled'.
    const statuses =
      status === "rejected" ? ["rejected", "cancelled"] : [status];

    const result = await pool.query(
      `
      SELECT b.id, b.status, b.total_amount, b.security_deposit, b.deposit_amount,
             b.slot_date, b.start_time, b.end_time, b.created_at, b.notes,
             u.name AS player_name, u.phone AS player_phone,
             COALESCE(pp.trust_score,100) AS trust_score,
             COALESCE(pp.sport_preferences,'{}') AS sport_preferences,
             v.name AS venue_name
      FROM bookings b
      JOIN venues v ON b.venue_id=v.id
      JOIN users u ON b.player_id=u.id
      LEFT JOIN player_profiles pp ON pp.user_id=u.id
      WHERE v.owner_id=$1 AND b.status = ANY($2::booking_status[])
      ORDER BY b.slot_date ASC, b.start_time ASC
    `,
      [ownerId, statuses],
    );

    res.json({ success: true, data: result.rows });
  } catch (e) {
    next(e);
  }
});

// PATCH /api/owner/bookings/:id/approve — no money moves, escrow stays frozen
router.patch("/bookings/:id/approve", async (req, res, next) => {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    const check = await client.query(
      `SELECT b.id, b.player_id, v.name AS venue_name
         FROM bookings b JOIN venues v ON b.venue_id=v.id
        WHERE b.id=$1 AND v.owner_id=$2 AND b.status='pending'
        FOR UPDATE OF b`,
      [req.params.id, req.user.id],
    );
    if (!check.rows.length) {
      await client.query("ROLLBACK");
      return res
        .status(404)
        .json({ success: false, message: "Booking not found or not pending" });
    }
    await client.query(
      "UPDATE bookings SET status='confirmed', approved_at=NOW() WHERE id=$1",
      [req.params.id],
    );
    await notify(client, {
      userId: check.rows[0].player_id,
      bookingId: check.rows[0].id,
      type: "booking_confirmed",
      title: "Booking confirmed",
      body: `${check.rows[0].venue_name} approved your booking. Show your QR code at the venue to check in.`,
    });
    await client.query("COMMIT");
    res.json({ success: true, message: "Booking approved" });
  } catch (e) {
    await client.query("ROLLBACK");
    next(e);
  } finally {
    client.release();
  }
});

// PATCH /api/owner/bookings/:id/reject — full refund: player balance +P, frozen -P
router.patch("/bookings/:id/reject", async (req, res, next) => {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    const bookingRes = await client.query(
      `SELECT b.id, b.security_deposit, b.player_id, b.slot_id, v.name AS venue_name
       FROM bookings b JOIN venues v ON b.venue_id=v.id
       WHERE b.id=$1 AND v.owner_id=$2 AND b.status='pending'
       FOR UPDATE OF b`,
      [req.params.id, req.user.id],
    );
    if (!bookingRes.rows.length) {
      await client.query("ROLLBACK");
      return res
        .status(404)
        .json({ success: false, message: "Booking not found or not pending" });
    }
    const b = bookingRes.rows[0];
    const escrow = round2(b.security_deposit);

    await client.query(
      "UPDATE bookings SET status='rejected', cancelled_at=NOW(), cancellation_reason='owner_rejected' WHERE id=$1",
      [b.id],
    );
    await client.query("UPDATE slots SET status='available' WHERE id=$1", [
      b.slot_id,
    ]);

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
        type: "refund",
        amount: escrow,
        balanceAfter: after.balance,
        description: "Booking rejected by venue owner — full refund",
        counterparty: b.venue_name,
      });
    }

    await notify(client, {
      userId: b.player_id,
      bookingId: b.id,
      type: "booking_rejected",
      title: "Booking rejected",
      body: `${b.venue_name} could not take your booking. PKR ${escrow} has been refunded to your wallet.`,
    });

    await client.query("COMMIT");
    res.json({ success: true, message: "Booking rejected. Player refunded." });
  } catch (e) {
    await client.query("ROLLBACK");
    next(e);
  } finally {
    client.release();
  }
});

// POST /api/owner/slots/generate
router.post("/slots/generate", async (req, res, next) => {
  try {
    const { venueId } = req.body;
    if (!venueId) return res.status(400).json({ success: false, message: 'venueId is required' });

    // Ensure owner owns the venue
    const check = await pool.query("SELECT price_per_hour FROM venues WHERE id=$1 AND owner_id=$2", [venueId, req.user.id]);
    if (!check.rows.length) return res.status(404).json({ success: false, message: 'Venue not found' });
    const pricePerHour = check.rows[0].price_per_hour;

    // Generate slots for next 7 days
    let created = 0;
    for (let i = 0; i < 7; i++) {
      const d = new Date();
      d.setDate(d.getDate() + i);
      const dateStr = d.toLocaleDateString("en-CA");
      for (let hour = 18; hour <= 22; hour++) {
        const sh = hour.toString().padStart(2, "0") + ":00:00";
        const eh = (hour + 1).toString().padStart(2, "0") + ":00:00";
        // Check if slot exists
        const exists = await pool.query(
          "SELECT id FROM slots WHERE venue_id=$1 AND slot_date=$2 AND start_time=$3",
          [venueId, dateStr, sh]
        );
        if (exists.rows.length === 0) {
          await pool.query(
            "INSERT INTO slots (venue_id, slot_date, start_time, end_time, price, status) VALUES ($1,$2,$3,$4,$5,'available')",
            [venueId, dateStr, sh, eh, pricePerHour]
          );
          created++;
        }
      }
    }

    res.json({ success: true, message: `Generated ${created} new slots for the next 7 days` });
  } catch (e) {
    next(e);
  }
});

// GET /api/owner/slots?date=YYYY-MM-DD&venueId=123
router.get("/slots", async (req, res, next) => {
  try {
    const date = req.query.date || new Date().toLocaleDateString("en-CA");
    const venueId = req.query.venueId;
    let query = `SELECT s.*, v.name AS venue_name FROM slots s JOIN venues v ON s.venue_id=v.id
                 WHERE v.owner_id=$1 AND s.slot_date=$2::DATE`;
    const params = [req.user.id, date];
    if (venueId) {
      params.push(venueId);
      query += ` AND s.venue_id=$3`;
    }
    query += ` ORDER BY s.start_time ASC`;

    const result = await pool.query(query, params);
    res.json({ success: true, data: result.rows });
  } catch (e) {
    next(e);
  }
});

// PATCH /api/owner/slots/:id/block
router.patch("/slots/:id/block", async (req, res, next) => {
  try {
    const check = await pool.query(
      `SELECT s.id FROM slots s JOIN venues v ON s.venue_id=v.id
       WHERE s.id=$1 AND v.owner_id=$2 AND s.status='available'`,
      [req.params.id, req.user.id],
    );
    if (!check.rows.length)
      return res
        .status(404)
        .json({
          success: false,
          message: "Slot not found or cannot be blocked",
        });
    await pool.query("UPDATE slots SET status='blocked' WHERE id=$1", [
      req.params.id,
    ]);
    res.json({ success: true, message: "Slot blocked" });
  } catch (e) {
    next(e);
  }
});

// PATCH /api/owner/slots/:id/unblock
router.patch("/slots/:id/unblock", async (req, res, next) => {
  try {
    const check = await pool.query(
      `SELECT s.id FROM slots s JOIN venues v ON s.venue_id=v.id
       WHERE s.id=$1 AND v.owner_id=$2 AND s.status='blocked'`,
      [req.params.id, req.user.id],
    );
    if (!check.rows.length)
      return res
        .status(404)
        .json({ success: false, message: "Slot not found or not blocked" });
    await pool.query("UPDATE slots SET status='available' WHERE id=$1", [
      req.params.id,
    ]);
    res.json({ success: true, message: "Slot unblocked" });
  } catch (e) {
    next(e);
  }
});

// POST /api/owner/scan-qr — check in player: escrow (full price) player frozen → owner balance
router.post("/scan-qr", async (req, res, next) => {
  const client = await pool.connect();
  try {
    const { qrCode } = req.body;
    if (!qrCode) {
      client.release();
      return res
        .status(400)
        .json({ success: false, message: "qrCode required" });
    }

    await client.query("BEGIN");

    const bookingRes = await client.query(
      `
      SELECT b.id, b.status, b.security_deposit, b.slot_date, b.start_time, b.end_time,
             b.player_id, u.name AS player_name, v.name AS venue_name, v.owner_id
      FROM bookings b
      JOIN users u ON b.player_id=u.id
      JOIN venues v ON b.venue_id=v.id
      WHERE b.qr_code=$1 FOR UPDATE OF b
    `,
      [qrCode],
    );

    if (!bookingRes.rows.length) {
      await client.query("ROLLBACK");
      return res
        .status(404)
        .json({
          success: false,
          message: "Invalid QR code. No booking found.",
        });
    }
    const booking = bookingRes.rows[0];

    if (booking.owner_id !== req.user.id) {
      await client.query("ROLLBACK");
      return res
        .status(403)
        .json({
          success: false,
          message: "This QR code is not for your venue.",
        });
    }
    if (booking.status === "checked_in") {
      await client.query("ROLLBACK");
      return res
        .status(409)
        .json({ success: false, message: "Player already checked in." });
    }
    if (booking.status !== "confirmed") {
      await client.query("ROLLBACK");
      return res
        .status(409)
        .json({
          success: false,
          message: `Cannot check in: booking is ${booking.status}`,
        });
    }

    const escrow = round2(booking.security_deposit);

    await client.query(
      "UPDATE bookings SET status='checked_in', checked_in_at=NOW() WHERE id=$1",
      [booking.id],
    );

    const playerWallet = await lockWallet(client, booking.player_id);
    const ownerWallet = await lockWallet(client, req.user.id);

    const playerAfter = await applyWallet(client, playerWallet.id, {
      frozen: -escrow,
    });
    const ownerAfter = await applyWallet(client, ownerWallet.id, {
      balance: escrow,
    });

    await logTxn(client, {
      walletId: playerWallet.id,
      userId: booking.player_id,
      bookingId: booking.id,
      type: "escrow_release",
      amount: -escrow,
      balanceAfter: playerAfter.balance,
      description: "Payment released to venue on check-in",
      counterparty: booking.venue_name,
    });
    await logTxn(client, {
      walletId: ownerWallet.id,
      userId: req.user.id,
      bookingId: booking.id,
      type: "escrow_received",
      amount: escrow,
      balanceAfter: ownerAfter.balance,
      description: "Received booking payment — player checked in",
      counterparty: booking.player_name,
    });

    await client.query("COMMIT");
    res.json({
      success: true,
      data: {
        playerName: booking.player_name,
        venueName: booking.venue_name,
        slotDate: booking.slot_date,
        startTime: booking.start_time,
        endTime: booking.end_time,
        amount: escrow,
        newOwnerBalance: ownerAfter?.balance || 0,
      },
      message: "Check-in successful!",
    });
  } catch (e) {
    await client.query("ROLLBACK");
    next(e);
  } finally {
    client.release();
  }
});

// POST /api/owner/no-show/:id — early trigger for the 30-minute rule.
// Ledger: player balance +0.8P, frozen -P, owner +0.2P, trust_score -10.
router.post("/no-show/:id", async (req, res, next) => {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");

    const bookingRes = await client.query(
      `
      SELECT b.id, b.status, b.security_deposit, b.deposit_amount, b.player_id,
             u.name AS player_name, v.name AS venue_name
      FROM bookings b
      JOIN venues v ON b.venue_id=v.id
      JOIN users u ON b.player_id=u.id
      WHERE b.id=$1 AND v.owner_id=$2 FOR UPDATE OF b
    `,
      [req.params.id, req.user.id],
    );

    if (!bookingRes.rows.length) {
      await client.query("ROLLBACK");
      return res
        .status(404)
        .json({ success: false, message: "Booking not found." });
    }
    const b = bookingRes.rows[0];
    if (b.status !== "confirmed") {
      await client.query("ROLLBACK");
      return res
        .status(409)
        .json({
          success: false,
          message: `Cannot mark no-show: booking is ${b.status}`,
        });
    }

    const { refund, penalty } = penaltySplit(b.security_deposit, b.deposit_amount);

    await client.query(
      `UPDATE bookings SET status='no_show', no_show_at=NOW(), no_show_processed=true WHERE id=$1`,
      [b.id],
    );

    const playerWallet = await lockWallet(client, b.player_id);
    const ownerWallet = await lockWallet(client, req.user.id);

    const playerAfter = await applyWallet(client, playerWallet.id, {
      balance: refund,
      frozen: -(refund + penalty),
    });
    const ownerAfter = await applyWallet(client, ownerWallet.id, {
      balance: penalty,
    });

    await client.query(
      "UPDATE player_profiles SET trust_score=GREATEST(trust_score-$1,0) WHERE user_id=$2",
      [POLICY.NO_SHOW_TRUST_PENALTY, b.player_id],
    );

    if (refund > 0) {
      await logTxn(client, {
        walletId: playerWallet.id,
        userId: b.player_id,
        bookingId: b.id,
        type: "refund",
        amount: refund,
        balanceAfter: playerAfter.balance,
        description: `No-show — ${100 - POLICY.DEPOSIT_PERCENT}% returned`,
        counterparty: b.venue_name,
      });
    }
    await logTxn(client, {
      walletId: playerWallet.id,
      userId: b.player_id,
      bookingId: b.id,
      type: "no_show_penalty",
      amount: -penalty,
      balanceAfter: playerAfter.balance,
      description: `No-show — ${POLICY.DEPOSIT_PERCENT}% deposit forfeited to venue`,
      counterparty: b.venue_name,
    });
    await logTxn(client, {
      walletId: ownerWallet.id,
      userId: req.user.id,
      bookingId: b.id,
      type: "escrow_received",
      amount: penalty,
      balanceAfter: ownerAfter.balance,
      description: "No-show deposit received",
      counterparty: b.player_name,
    });

    await notify(client, {
      userId: b.player_id,
      bookingId: b.id,
      type: "booking_no_show",
      title: "Marked as no-show",
      body: `You missed your slot at ${b.venue_name}. PKR ${refund} returned, PKR ${penalty} deposit forfeited, trust score -${POLICY.NO_SHOW_TRUST_PENALTY}.`,
    });

    await client.query("COMMIT");
    res.json({
      success: true,
      message: `Marked as no-show. PKR ${penalty} deposit credited to you, PKR ${refund} returned to the player.`,
    });
  } catch (e) {
    await client.query("ROLLBACK");
    next(e);
  } finally {
    client.release();
  }
});

// GET /api/owner/venue — returns first active venue for owner
router.get("/venue", async (req, res, next) => {
  try {
    const r = await pool.query(
      "SELECT * FROM venues WHERE owner_id=$1 AND is_active=true ORDER BY created_at ASC LIMIT 1",
      [req.user.id],
    );
    res.json({ success: true, data: r.rows[0] || null });
  } catch (e) {
    next(e);
  }
});

// GET /api/owner/analytics
router.get("/analytics", async (req, res, next) => {
  try {
    const ownerId = req.user.id;
    const monthStart = new Date();
    monthStart.setDate(1);
    const monthStartStr = monthStart.toLocaleDateString("en-CA");

    const monthRes = await pool.query(
      `
      SELECT COALESCE(SUM(
               CASE WHEN b.status='no_show' THEN b.deposit_amount
                    ELSE b.security_deposit END),0) AS "monthTotal"
      FROM bookings b JOIN venues v ON b.venue_id=v.id
      WHERE v.owner_id=$1 AND b.status IN ('checked_in','no_show') AND b.slot_date>=$2::DATE
    `,
      [ownerId, monthStartStr],
    );

    const weeklyRes = await pool.query(
      `
      SELECT CEIL(EXTRACT(DAY FROM (b.slot_date::DATE - DATE_TRUNC('month',b.slot_date::DATE)::DATE))/7.0)::INT AS week_num,
             COALESCE(SUM(b.security_deposit),0) AS revenue,
             COUNT(*) AS total_bookings
      FROM bookings b JOIN venues v ON b.venue_id=v.id
      WHERE v.owner_id=$1 AND b.status='checked_in' AND b.slot_date>=$2::DATE
      GROUP BY week_num ORDER BY week_num ASC
    `,
      [ownerId, monthStartStr],
    );

    res.json({
      success: true,
      data: {
        monthTotal: monthRes.rows[0]?.monthTotal || 0,
        weeklyRevenue: weeklyRes.rows,
      },
    });
  } catch (e) {
    next(e);
  }
});

module.exports = router;
