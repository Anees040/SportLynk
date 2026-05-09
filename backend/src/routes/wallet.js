const express = require('express');
const router = express.Router();
const pool = require('../db/pool');
const authMiddleware = require('../middleware/authMiddleware');

// GET /api/wallet/me
router.get('/me', authMiddleware, async (req, res, next) => {
  try {
    const result = await pool.query(
      `SELECT w.*, u.name FROM wallets w JOIN users u ON u.id=w.user_id
       WHERE w.user_id=$1`, [req.user.id]);
    if (!result.rows.length)
      return res.status(404).json({ success:false, message:'Wallet not found' });
    res.json({ success:true, data: result.rows[0] });
  } catch(e){ next(e); }
});

// GET /api/wallet/transactions
router.get('/transactions', authMiddleware, async (req, res, next) => {
  try {
    const { type, limit=20, offset=0 } = req.query;
    let where = 't.user_id=$1';
    const params = [req.user.id];
    if (type && type !== 'all') {
      where += ` AND t.type=$2`; params.push(type);
    }
    const result = await pool.query(`
      SELECT t.*, b.slot_date, b.start_time, b.end_time,
        v.name as venue_name
      FROM transactions t
      LEFT JOIN bookings b ON b.id=t.booking_id
      LEFT JOIN venues v ON v.id=b.venue_id
      WHERE ${where}
      ORDER BY t.created_at DESC
      LIMIT $${params.length+1} OFFSET $${params.length+2}`,
      [...params, limit, offset]);
    res.json({ success:true, data: result.rows });
  } catch(e){ next(e); }
});

// POST /api/wallet/topup — simulated topup (no real payment)
router.post('/topup', authMiddleware, async (req, res, next) => {
  const { amount } = req.body;
  if (!amount || amount < 100 || amount > 50000)
    return res.status(400).json({
      success:false, message:'Amount must be between 100 and 50,000 PKR' });
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const wallet = await client.query(
      `UPDATE wallets SET balance=balance+$1 WHERE user_id=$2
       RETURNING id, balance`, [amount, req.user.id]);
    await client.query(`
      INSERT INTO transactions (wallet_id, user_id, type, amount,
        balance_after, description)
      VALUES ($1,$2,'topup',$3,$4,'Wallet Top-up')`,
      [wallet.rows[0].id, req.user.id, amount, wallet.rows[0].balance]);
    await client.query('COMMIT');
    res.json({ success:true,
      data: { newBalance: wallet.rows[0].balance, amount } });
  } catch(e){ await client.query('ROLLBACK'); next(e); }
  finally { client.release(); }
});

module.exports = router;
