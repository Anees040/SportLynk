const express = require('express');
const router = express.Router();
const { pool } = require('../db/pool');
const authMiddleware = require('../middleware/authMiddleware');
const checkRole = require('../middleware/roleMiddleware');
const crypto = require('crypto');

// POST /api/bookings — create booking (player only)
router.post('/', authMiddleware, checkRole('player'), async (req, res, next) => {
  const { slotId, venueId, notes } = req.body;
  if (!slotId || !venueId)
    return res.status(400).json({ success:false, message:'slotId and venueId required' });
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    // Lock slot
    const slotRes = await client.query(
      `SELECT s.*, v.name as venue_name, v.price_per_hour
       FROM slots s JOIN venues v ON v.id = s.venue_id
       WHERE s.id=$1 AND s.venue_id=$2 AND s.status='available' FOR UPDATE`,
      [slotId, venueId]);
    if (!slotRes.rows.length) {
      await client.query('ROLLBACK');
      return res.status(409).json({ success:false, message:'Slot no longer available' });
    }
    const slot = slotRes.rows[0];
    const basePrice = parseFloat(slot.price);
    const deposit = Math.round(basePrice * 0.2); // 20% deposit
    const total = basePrice; // full amount for simplicity
    // Check wallet
    const wallet = await client.query(
      `SELECT * FROM wallets WHERE user_id=$1 FOR UPDATE`, [req.user.id]);
    if (!wallet.rows.length || parseFloat(wallet.rows[0].balance) < total) {
      await client.query('ROLLBACK');
      return res.status(400).json({ success:false, message:'Insufficient wallet balance' });
    }
    // Generate QR
    const qrData = crypto.randomUUID();
    // Create booking
    const booking = await client.query(`
      INSERT INTO bookings (player_id, venue_id, slot_id, slot_date, start_time,
        end_time, base_price, security_deposit, total_amount, status, qr_code, notes)
      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,'confirmed',$10,$11)
      RETURNING *`,
      [req.user.id, venueId, slotId, slot.slot_date, slot.start_time,
       slot.end_time, basePrice, deposit, total, qrData, notes||null]);
    // Mark slot booked
    await client.query(`UPDATE slots SET status='booked' WHERE id=$1`, [slotId]);
    // Deduct wallet
    const newBalance = parseFloat(wallet.rows[0].balance) - total;
    await client.query(
      `UPDATE wallets SET balance=$1 WHERE user_id=$2`, [newBalance, req.user.id]);
    // Log transaction
    await client.query(`
      INSERT INTO transactions (wallet_id, user_id, booking_id, type, amount,
        balance_after, description, counterparty_name)
      VALUES ($1,$2,$3,'booking_payment',$4,$5,$6,$7)`,
      [wallet.rows[0].id, req.user.id, booking.rows[0].id,
       -total, newBalance, `Booking at ${slot.venue_name}`, slot.venue_name]);
    await client.query('COMMIT');
    res.status(201).json({ success:true, data: booking.rows[0] });
  } catch(e){ await client.query('ROLLBACK'); next(e); }
  finally { client.release(); }
});

// GET /api/bookings/my — player's bookings
router.get('/my', authMiddleware, async (req, res, next) => {
  try {
    const { status } = req.query;
    let where = 'b.player_id=$1';
    const params = [req.user.id];
    if (status) { where += ` AND b.status=$2`; params.push(status); }
    const result = await pool.query(`
      SELECT b.*, v.name as venue_name, v.city, v.address,
        COALESCE(v.venue_photos[1],null) as venue_photo
      FROM bookings b JOIN venues v ON v.id=b.venue_id
      WHERE ${where}
      ORDER BY b.created_at DESC LIMIT 50`, params);
    res.json({ success:true, data: result.rows });
  } catch(e){ next(e); }
});

// GET /api/bookings/:id — booking detail
router.get('/:id', authMiddleware, async (req, res, next) => {
  try {
    const result = await pool.query(`
      SELECT b.*, v.name as venue_name, v.city, v.address, v.latitude, v.longitude,
        COALESCE(v.venue_photos[1],null) as venue_photo,
        u.name as player_name
      FROM bookings b 
      JOIN venues v ON v.id=b.venue_id
      JOIN users u ON u.id=b.player_id
      WHERE b.id=$1 AND (b.player_id=$2 OR $3='owner')`,
      [req.params.id, req.user.id, req.user.role]);
    if (!result.rows.length)
      return res.status(404).json({ success:false, message:'Booking not found' });
    res.json({ success:true, data: result.rows[0] });
  } catch(e){ next(e); }
});

// PATCH /api/bookings/:id/cancel — player cancels
router.patch('/:id/cancel', authMiddleware, async (req, res, next) => {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const b = await client.query(
      `SELECT * FROM bookings WHERE id=$1 AND player_id=$2 FOR UPDATE`,
      [req.params.id, req.user.id]);
    if (!b.rows.length)
      return res.status(404).json({ success:false, message:'Booking not found' });
    if (!['pending','confirmed'].includes(b.rows[0].status))
      return res.status(400).json({ success:false, message:'Cannot cancel this booking' });
    // Refund
    const refund = parseFloat(b.rows[0].total_amount);
    const wallet = await client.query(
      `UPDATE wallets SET balance=balance+$1 WHERE user_id=$2 RETURNING balance`,
      [refund, req.user.id]);
    await client.query(
      `UPDATE bookings SET status='cancelled',cancelled_at=NOW() WHERE id=$1`,
      [req.params.id]);
    await client.query(
      `UPDATE slots SET status='available' WHERE id=$1`, [b.rows[0].slot_id]);
    await client.query(`
      INSERT INTO transactions (wallet_id, user_id, booking_id, type, amount,
        balance_after, description)
      VALUES ((SELECT id FROM wallets WHERE user_id=$1),$1,$2,'refund',$3,$4,'Booking cancellation refund')`,
      [req.user.id, req.params.id, refund, wallet.rows[0].balance]);
    await client.query('COMMIT');
    res.json({ success:true, message:'Booking cancelled and refunded' });
  } catch(e){ await client.query('ROLLBACK'); next(e); }
  finally { client.release(); }
});

module.exports = router;
