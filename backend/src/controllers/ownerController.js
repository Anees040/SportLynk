const crypto = require('crypto');
const pool = require('../db/pool');

// ─── GET OWNER VENUES ────────────────────────────────────────
const getOwnerVenues = async (req, res) => {
  try {
    const result = await pool.query(
      'SELECT * FROM venues WHERE owner_id = $1 AND is_active = true ORDER BY name',
      [req.user.id]
    );
    return res.status(200).json({
      success: true, data: { venues: result.rows }, message: `Found ${result.rows.length} venue(s)`,
    });
  } catch (err) {
    console.error('GetOwnerVenues error:', err);
    return res.status(500).json({ success: false, message: 'Internal server error' });
  }
};

// ─── CREATE VENUE ────────────────────────────────────────────
const createVenue = async (req, res) => {
  try {
    const { name, description, sport_type, city, address, latitude, longitude, base_price } = req.body;
    if (!name || !sport_type || !city || !address || !base_price) {
      return res.status(400).json({ success: false, message: 'name, sport_type, city, address, and base_price are required' });
    }
    const result = await pool.query(
      `INSERT INTO venues (owner_id, name, description, sport_type, city, address, latitude, longitude, base_price, current_price)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$9)
       RETURNING *`,
      [req.user.id, name, description || null, sport_type, city, address, latitude || null, longitude || null, base_price]
    );
    return res.status(201).json({
      success: true, data: { venue: result.rows[0] }, message: 'Venue created successfully',
    });
  } catch (err) {
    console.error('CreateVenue error:', err);
    return res.status(500).json({ success: false, message: 'Internal server error' });
  }
};

// ─── CREATE SLOTS ────────────────────────────────────────────
const createSlots = async (req, res) => {
  try {
    const venueId = req.params.id;
    const { date, slots } = req.body;
    if (!date || !slots || !Array.isArray(slots) || slots.length === 0) {
      return res.status(400).json({ success: false, message: 'date and slots array are required' });
    }
    // Verify venue belongs to this owner
    const venueCheck = await pool.query('SELECT id FROM venues WHERE id = $1 AND owner_id = $2', [venueId, req.user.id]);
    if (venueCheck.rows.length === 0) {
      return res.status(403).json({ success: false, message: 'Venue not found or does not belong to you' });
    }
    const createdSlots = [];
    for (const s of slots) {
      const result = await pool.query(
        `INSERT INTO venue_slots (venue_id, date, start_time, end_time, price)
         VALUES ($1,$2,$3,$4,$5) RETURNING *`,
        [venueId, date, s.start_time, s.end_time, s.price]
      );
      createdSlots.push(result.rows[0]);
    }
    return res.status(201).json({
      success: true, data: { slots: createdSlots, created: createdSlots.length }, message: `Created ${createdSlots.length} slot(s)`,
    });
  } catch (err) {
    console.error('CreateSlots error:', err);
    return res.status(500).json({ success: false, message: 'Internal server error' });
  }
};

// ─── GET OWNER BOOKINGS (pending) ────────────────────────────
const getOwnerBookings = async (req, res) => {
  try {
    const result = await pool.query(
      `SELECT b.id, b.status, b.total_amount, b.deposit_amount, b.created_at,
              u.name AS player_name, u.phone AS player_phone,
              v.name AS venue_name,
              vs.date, vs.start_time, vs.end_time
       FROM bookings b
       JOIN venues v ON b.venue_id = v.id
       JOIN users u ON b.player_id = u.id
       JOIN venue_slots vs ON b.slot_id = vs.id
       WHERE v.owner_id = $1 AND b.status = 'pending'
       ORDER BY vs.date ASC`,
      [req.user.id]
    );
    return res.status(200).json({
      success: true, data: { bookings: result.rows }, message: `Found ${result.rows.length} pending booking(s)`,
    });
  } catch (err) {
    console.error('GetOwnerBookings error:', err);
    return res.status(500).json({ success: false, message: 'Internal server error' });
  }
};

// ─── APPROVE BOOKING ─────────────────────────────────────────
const approveBooking = async (req, res) => {
  try {
    const bookingId = req.params.id;
    // Verify booking's venue belongs to this owner
    const check = await pool.query(
      `SELECT b.id FROM bookings b JOIN venues v ON b.venue_id = v.id
       WHERE b.id = $1 AND v.owner_id = $2 AND b.status = 'pending'`,
      [bookingId, req.user.id]
    );
    if (check.rows.length === 0) {
      return res.status(404).json({ success: false, message: 'Booking not found or not pending' });
    }
    await pool.query("UPDATE bookings SET status = 'confirmed' WHERE id = $1", [bookingId]);
    return res.status(200).json({ success: true, data: {}, message: 'Booking approved' });
  } catch (err) {
    console.error('ApproveBooking error:', err);
    return res.status(500).json({ success: false, message: 'Internal server error' });
  }
};

// ─── REJECT BOOKING (with refund) ────────────────────────────
const rejectBooking = async (req, res) => {
  const client = await pool.connect();
  try {
    const bookingId = req.params.id;
    // Get booking details and verify ownership
    const bookingResult = await client.query(
      `SELECT b.id, b.deposit_amount, b.player_id, b.slot_id, v.owner_id
       FROM bookings b JOIN venues v ON b.venue_id = v.id
       WHERE b.id = $1 AND v.owner_id = $2 AND b.status = 'pending'`,
      [bookingId, req.user.id]
    );
    if (bookingResult.rows.length === 0) {
      client.release();
      return res.status(404).json({ success: false, message: 'Booking not found or not pending' });
    }
    const booking = bookingResult.rows[0];

    await client.query('BEGIN');
    // Cancel booking
    await client.query("UPDATE bookings SET status = 'cancelled' WHERE id = $1", [bookingId]);
    // Release slot
    await client.query("UPDATE venue_slots SET status = 'available' WHERE id = $1", [booking.slot_id]);
    // Refund deposit
    await client.query(
      'UPDATE wallets SET balance = balance + $1, frozen_balance = frozen_balance - $1 WHERE user_id = $2',
      [booking.deposit_amount, booking.player_id]
    );
    // Log refund transaction
    const walletResult = await client.query('SELECT id FROM wallets WHERE user_id = $1', [booking.player_id]);
    await client.query(
      'INSERT INTO wallet_transactions (wallet_id, type, amount, reference_id) VALUES ($1,$2,$3,$4)',
      [walletResult.rows[0].id, 'refund', booking.deposit_amount, bookingId]
    );
    await client.query('COMMIT');

    return res.status(200).json({ success: true, data: {}, message: 'Booking rejected and deposit refunded' });
  } catch (err) {
    await client.query('ROLLBACK');
    console.error('RejectBooking error:', err);
    return res.status(500).json({ success: false, message: 'Internal server error' });
  } finally {
    client.release();
  }
};

// ─── VERIFY CHECK-IN (QR scan) ──────────────────────────────
const verifyCheckIn = async (req, res) => {
  try {
    const { qrData, venueId } = req.body;
    if (!qrData || !venueId) {
      return res.status(400).json({ success: false, message: 'qrData and venueId are required' });
    }
    const expectedHash = crypto.createHmac('sha256', process.env.JWT_SECRET).update(qrData).digest('hex');
    const result = await pool.query(
      `SELECT b.id, b.status, b.deposit_amount, b.player_id,
              v.owner_id, u.name AS player_name,
              vs.date, vs.start_time, vs.end_time
       FROM bookings b
       JOIN venues v ON b.venue_id = v.id
       JOIN users u ON b.player_id = u.id
       JOIN venue_slots vs ON b.slot_id = vs.id
       WHERE b.id = $1 AND b.qr_code_hash = $2`,
      [qrData, expectedHash]
    );
    if (result.rows.length === 0) {
      return res.status(401).json({ success: false, message: 'Invalid or tampered QR code' });
    }
    const booking = result.rows[0];
    if (booking.owner_id !== req.user.id) {
      return res.status(403).json({ success: false, message: 'This booking is not for your venue' });
    }
    if (booking.status !== 'confirmed') {
      return res.status(409).json({ success: false, message: `Booking is not in confirmed state (status: ${booking.status})` });
    }
    return res.status(200).json({
      success: true,
      data: {
        bookingId: booking.id,
        playerName: booking.player_name,
        slotTime: `${booking.start_time} - ${booking.end_time}`,
        slotDate: booking.date,
      },
      message: 'QR code verified',
    });
  } catch (err) {
    console.error('VerifyCheckIn error:', err);
    return res.status(500).json({ success: false, message: 'Internal server error' });
  }
};

// ─── SUBMIT CHECK-IN DECISION ────────────────────────────────
const submitCheckInDecision = async (req, res) => {
  const client = await pool.connect();
  try {
    const { bookingId, action } = req.body;
    if (!bookingId || !action || !['check_in', 'no_show'].includes(action)) {
      return res.status(400).json({ success: false, message: "bookingId and action ('check_in' or 'no_show') are required" });
    }
    const newStatus = action === 'check_in' ? 'checked_in' : 'no_show';

    // Get booking details
    const bookingResult = await client.query(
      `SELECT b.id, b.deposit_amount, b.player_id, v.owner_id
       FROM bookings b JOIN venues v ON b.venue_id = v.id
       WHERE b.id = $1 AND v.owner_id = $2 AND b.status = 'confirmed'`,
      [bookingId, req.user.id]
    );
    if (bookingResult.rows.length === 0) {
      client.release();
      return res.status(404).json({ success: false, message: 'Booking not found or not in confirmed state' });
    }
    const booking = bookingResult.rows[0];

    await client.query('BEGIN');
    // Update booking status
    await client.query('UPDATE bookings SET status = $1 WHERE id = $2', [newStatus, bookingId]);
    // Release frozen balance from player
    await client.query(
      'UPDATE wallets SET frozen_balance = frozen_balance - $1 WHERE user_id = $2',
      [booking.deposit_amount, booking.player_id]
    );
    // Pay owner
    await client.query(
      'UPDATE wallets SET balance = balance + $1 WHERE user_id = $2',
      [booking.deposit_amount, booking.owner_id]
    );
    // Log earning transaction for owner
    const ownerWallet = await client.query('SELECT id FROM wallets WHERE user_id = $1', [booking.owner_id]);
    await client.query(
      'INSERT INTO wallet_transactions (wallet_id, type, amount, reference_id) VALUES ($1,$2,$3,$4)',
      [ownerWallet.rows[0].id, 'earning', booking.deposit_amount, bookingId]
    );
    // If no-show, penalize trust score
    if (action === 'no_show') {
      await client.query(
        'UPDATE player_profiles SET trust_score = trust_score - 5 WHERE user_id = $1',
        [booking.player_id]
      );
    }
    await client.query('COMMIT');

    const msg = action === 'check_in' ? 'Check-in confirmed' : 'No-show recorded';
    return res.status(200).json({ success: true, data: {}, message: msg });
  } catch (err) {
    await client.query('ROLLBACK');
    console.error('SubmitCheckInDecision error:', err);
    return res.status(500).json({ success: false, message: 'Internal server error' });
  } finally {
    client.release();
  }
};

module.exports = {
  getOwnerVenues, createVenue, createSlots,
  getOwnerBookings, approveBooking, rejectBooking,
  verifyCheckIn, submitCheckInDecision,
};
