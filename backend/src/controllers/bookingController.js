const crypto = require('crypto');
const pool = require('../db/pool');

// ─── CREATE BOOKING (atomic transaction) ─────────────────────
const createBooking = async (req, res) => {
  const client = await pool.connect();
  try {
    const { slotId, venueId } = req.body;
    const playerId = req.user.id;

    if (!slotId || !venueId) {
      return res.status(400).json({ success: false, message: 'slotId and venueId are required' });
    }

    await client.query('BEGIN');

    // 1. Lock slot row — prevent double-booking
    const slotResult = await client.query('SELECT * FROM venue_slots WHERE id = $1 FOR UPDATE', [slotId]);
    const slot = slotResult.rows[0];
    if (!slot) throw { status: 404, message: 'Slot not found' };
    if (slot.status !== 'available') throw { status: 409, message: 'Slot is no longer available. Please select another time.' };

    // 2. Check wallet balance
    const walletResult = await client.query('SELECT * FROM wallets WHERE user_id = $1', [playerId]);
    const wallet = walletResult.rows[0];
    if (!wallet) throw { status: 404, message: 'Wallet not found. Contact support.' };
    const depositAmount = parseFloat((slot.price * 0.3).toFixed(2));
    if (parseFloat(wallet.balance) < depositAmount) {
      throw { status: 402, message: `Insufficient balance. You need Rs. ${depositAmount} deposit. Current balance: Rs. ${wallet.balance}` };
    }

    // 3. Update slot status
    await client.query('UPDATE venue_slots SET status = $1 WHERE id = $2', ['booked', slotId]);

    // 4. Escrow: Deduct deposit from player and freeze it in owner's wallet
    const venueRes = await client.query('SELECT owner_id FROM venues WHERE id = $1', [venueId]);
    const ownerId = venueRes.rows[0].owner_id;

    await client.query(
      'UPDATE wallets SET balance = balance - $1 WHERE user_id = $2',
      [depositAmount, playerId]
    );

    await client.query(
      'UPDATE wallets SET frozen_balance = frozen_balance + $1 WHERE user_id = $2',
      [depositAmount, ownerId]
    );

    // 5. Generate booking ID and QR hash
    const bookingIdResult = await client.query('SELECT gen_random_uuid() AS id');
    const bookingId = bookingIdResult.rows[0].id;
    const qrHash = crypto.createHmac('sha256', process.env.JWT_SECRET).update(bookingId).digest('hex');

    // 6. Insert booking
    await client.query(
      `INSERT INTO bookings (id, venue_id, player_id, slot_id, status, total_amount, deposit_amount, qr_code_hash)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8)`,
      [bookingId, venueId, playerId, slotId, 'pending', slot.price, depositAmount, qrHash]
    );

    // 7. Log wallet transaction
    await client.query(
      'INSERT INTO wallet_transactions (wallet_id, type, amount, reference_id) VALUES ($1,$2,$3,$4)',
      [wallet.id, 'deposit_freeze', depositAmount, bookingId]
    );

    await client.query('COMMIT');
    return res.status(201).json({
      success: true,
      data: { bookingId, qrData: bookingId, depositAmount, status: 'pending' },
      message: 'Booking created successfully',
    });
  } catch (err) {
    await client.query('ROLLBACK');
    const status = err.status || 500;
    console.error('CreateBooking error:', err);
    return res.status(status).json({ success: false, message: err.message || 'Booking failed' });
  } finally {
    client.release();
  }
};

// ─── GET MY BOOKINGS ─────────────────────────────────────────
const getMyBookings = async (req, res) => {
  try {
    const result = await pool.query(
      `SELECT b.id, b.status, b.total_amount, b.deposit_amount, b.qr_code_hash, b.created_at,
              v.name AS venue_name, v.city, v.image_url,
              vs.date, vs.start_time, vs.end_time
       FROM bookings b
       JOIN venues v ON b.venue_id = v.id
       JOIN venue_slots vs ON b.slot_id = vs.id
       WHERE b.player_id = $1
       ORDER BY b.created_at DESC`,
      [req.user.id]
    );
    return res.status(200).json({
      success: true, data: { bookings: result.rows }, message: `Found ${result.rows.length} booking(s)`,
    });
  } catch (err) {
    console.error('GetMyBookings error:', err);
    return res.status(500).json({ success: false, message: 'Internal server error' });
  }
};

module.exports = { createBooking, getMyBookings };
