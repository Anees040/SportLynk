const express = require('express');
const router = express.Router();
const pool = require('../db/pool');
const authMiddleware = require('../middleware/authMiddleware');
const {
  POLICY,
  asNum,
  round2,
  lockWallet,
  applyWallet,
  logTxn,
} = require('../utils/escrow');
const { notify } = require('../utils/notify');

// Mirrors the CHECK constraint in migration 014. Kept here too so a bad method
// is a 400 with a readable message rather than a 500 from constraint 23514.
const PAYOUT_METHODS = ['easypaisa', 'jazzcash', 'bank'];
const METHOD_LABEL = { easypaisa: 'Easypaisa', jazzcash: 'JazzCash', bank: 'bank account' };

/** Last 4 digits only — full account numbers never go into a ledger description. */
function maskAccount(n) {
  const s = String(n || '').replace(/\s+/g, '');
  return s.length > 4 ? `••••${s.slice(-4)}` : s;
}

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

// ─── FR7.2 — itemised frozen-balance breakdown ────────────────────────────────
//
// GET /api/wallet/frozen
//
// Answers "where exactly is my PKR 4,800?" with one row per booking that is
// currently holding escrow, which is while the booking is pending or confirmed —
// escrow is released on check-in, cancel, reject and no-show.
//
// The itemised figure is `security_deposit`, NOT `total_amount`. That is the
// column the money code treats as authoritative (routes/bookings.js: "security_
// deposit holds what is ACTUALLY in escrow for this booking", and both cancel
// paths release exactly it). For a Wave-A booking the two are equal, because
// booking freezes the full slot price. For a legacy row created under the old 30%
// rule they differ — one live booking here has total_amount 3000 against
// security_deposit 900 — and summing total_amount then reported "PKR 3,000 frozen
// for this booking" when 900 was frozen. That is a wrong number in the user's
// wallet AND it made `delta` permanently non-zero, so the honest diagnostic below
// could never read 0 and stopped meaning anything.
//
// `slot_price` is returned alongside so the sheet can still show what the booking
// costs, and a row where the two disagree is visibly a legacy row.
//
// Computed server-side rather than filtered in Flutter so the sum can be compared
// against wallets.frozen_balance and any `delta` surfaced. A non-zero delta now
// means genuine drift — escrow the wallet holds that no booking accounts for
// (see backend/src/scripts/reconcile_wallets.js) — rather than a unit mismatch.
router.get('/frozen', authMiddleware, async (req, res, next) => {
  try {
    const [walletRes, itemsRes] = await Promise.all([
      pool.query('SELECT frozen_balance FROM wallets WHERE user_id=$1', [req.user.id]),
      pool.query(
        `SELECT b.id, b.security_deposit AS escrow_held,
                b.total_amount AS slot_price,
                b.slot_date, b.start_time, b.end_time,
                b.status, v.name AS venue_name
           FROM bookings b
           JOIN venues v ON v.id = b.venue_id
          WHERE b.player_id = $1
            AND b.status IN ('pending','confirmed')
          ORDER BY b.slot_date, b.start_time`,
        [req.user.id],
      ),
    ]);

    const items = itemsRes.rows;
    const itemsTotal = round2(
      items.reduce((sum, r) => sum + asNum(r.escrow_held), 0),
    );
    const walletFrozen = walletRes.rows.length
      ? round2(walletRes.rows[0].frozen_balance)
      : 0;

    res.json({
      success: true,
      data: {
        items,
        itemsTotal,
        walletFrozen,
        delta: round2(walletFrozen - itemsTotal),
      },
    });
  } catch (e) { next(e); }
});

// ─── FR7.4 / ER1.6 — withdrawals ──────────────────────────────────────────────

// GET /api/wallet/withdrawals — history plus the one pending row, if any.
router.get('/withdrawals', authMiddleware, async (req, res, next) => {
  try {
    const { rows } = await pool.query(
      `SELECT id, amount, status, method, account_name, account_number,
              requested_at, completed_at, failure_reason
         FROM withdrawals
        WHERE user_id = $1
        ORDER BY requested_at DESC
        LIMIT 50`,
      [req.user.id],
    );
    res.json({
      success: true,
      data: {
        items: rows,
        pending: rows.find((r) => r.status === 'pending') || null,
        minAmount: POLICY.WITHDRAWAL_MIN_AMOUNT,
        settleMinutes: POLICY.WITHDRAWAL_SETTLE_MINUTES,
      },
    });
  } catch (e) { next(e); }
});

// POST /api/wallet/withdraw
//
// The money leaves `balance` HERE, not when the job settles the row — you must
// not be able to spend what you have already asked to withdraw. The hold is a
// plain balance debit rather than frozen_balance because frozen_balance means
// "booking escrow" and GET /frozen above itemises it.
router.post('/withdraw', authMiddleware, async (req, res, next) => {
  const { amount, method = 'easypaisa', accountName, accountNumber } = req.body;
  const amt = round2(amount);
  const min = POLICY.WITHDRAWAL_MIN_AMOUNT;

  if (!Number.isFinite(amt) || amt <= 0)
    return res.status(400).json({ success:false, message:'Enter a valid withdrawal amount.' });
  if (amt < min)
    return res.status(400).json({ success:false, message:`Minimum withdrawal is PKR ${min}.` });
  if (!PAYOUT_METHODS.includes(method))
    return res.status(400).json({ success:false, message:'Choose a valid payout method.' });
  if (String(accountNumber || '').replace(/\s+/g, '').length < 6)
    return res.status(400).json({
      success:false, message:'Enter the account or mobile number to send the money to.' });

  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    // Pending check BEFORE the wallet lock, and with FOR UPDATE.
    //
    // Both parts matter. It gives a readable 409 instead of a raw constraint
    // error — and, critically, it fixes a lock-order deadlock: DELETE below
    // locks the withdrawal row and then the wallet. If this route took the
    // wallet first and then blocked on the unique index, the two would wait on
    // each other. Taking the withdrawal lock first makes both paths agree on
    // the order. (When no pending row exists this locks nothing, and no
    // deadlock is possible because DELETE has no row to work on either.)
    const existing = await client.query(
      `SELECT id, amount, requested_at FROM withdrawals
        WHERE user_id = $1 AND status = 'pending'
        FOR UPDATE`,
      [req.user.id],
    );
    if (existing.rows.length) {
      await client.query('ROLLBACK');
      return res.status(409).json({
        success: false,
        message: `You already have a withdrawal of PKR ${asNum(existing.rows[0].amount)} in progress. Cancel it or wait for it to complete.`,
      });
    }

    const wallet = await lockWallet(client, req.user.id);
    if (!wallet) {
      await client.query('ROLLBACK');
      return res.status(404).json({ success:false, message:'Wallet not found' });
    }

    const available = asNum(wallet.balance);
    const frozen = asNum(wallet.frozen_balance);
    if (amt > available) {
      await client.query('ROLLBACK');
      return res.status(400).json({
        success: false,
        message: frozen > 0
          ? `You can withdraw up to PKR ${available}. PKR ${frozen} is held in escrow for active bookings.`
          : `You can withdraw up to PKR ${available}.`,
      });
    }

    const after = await applyWallet(client, wallet.id, { balance: -amt });
    const txnId = await logTxn(client, {
      walletId: wallet.id,
      userId: req.user.id,
      bookingId: null,
      type: 'withdrawal',
      amount: -amt,
      balanceAfter: after.balance,
      description: `Withdrawal to ${METHOD_LABEL[method]} ${maskAccount(accountNumber)}`,
      counterparty: accountName || null,
    });

    const ins = await client.query(
      `INSERT INTO withdrawals
         (user_id, wallet_id, amount, status, method, account_name, account_number, txn_id)
       VALUES ($1,$2,$3,'pending',$4,$5,$6,$7)
       RETURNING id, amount, status, method, account_name, account_number,
                 requested_at, completed_at`,
      [
        req.user.id, wallet.id, amt, method,
        accountName || null, String(accountNumber).replace(/\s+/g, ''), txnId,
      ],
    );

    await notify(client, {
      userId: req.user.id,
      type: 'withdrawal_requested',
      title: 'Withdrawal requested',
      body: `PKR ${amt} is on its way to your ${METHOD_LABEL[method]}. It will be paid out within 24 hours.`,
    });

    await client.query('COMMIT');
    res.status(201).json({
      success: true,
      data: { withdrawal: ins.rows[0], newBalance: after.balance },
      message: `Withdrawal of PKR ${amt} requested.`,
    });
  } catch (e) {
    await client.query('ROLLBACK');
    // Backstop for the race the pre-check above cannot see: two requests that
    // both pass the check in the same instant. The partial unique index rejects
    // the loser, and this turns 23505 into the same friendly 409.
    if (e.code === '23505') {
      return res.status(409).json({
        success: false,
        message: 'You already have a withdrawal in progress. Cancel it or wait for it to complete.',
      });
    }
    next(e);
  } finally { client.release(); }
});

// DELETE /api/wallet/withdraw/:id — cancel a pending request and refund it.
//
// Without this, one test withdrawal locks the feature for a full settle window.
// The refund is a real ledger entry, not a reversal of the original row: the
// ledger is append-only so the audit trail keeps both halves.
router.delete('/withdraw/:id', authMiddleware, async (req, res, next) => {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    const res1 = await client.query(
      `SELECT id, amount, method FROM withdrawals
        WHERE id = $1 AND user_id = $2 AND status = 'pending'
        FOR UPDATE`,
      [req.params.id, req.user.id],
    );
    if (!res1.rows.length) {
      await client.query('ROLLBACK');
      return res.status(404).json({
        success:false, message:'No pending withdrawal found to cancel.' });
    }

    const w = res1.rows[0];
    const amt = round2(w.amount);

    await client.query(
      `UPDATE withdrawals SET status = 'cancelled' WHERE id = $1`, [w.id],
    );

    const wallet = await lockWallet(client, req.user.id);
    const after = await applyWallet(client, wallet.id, { balance: amt });
    await logTxn(client, {
      walletId: wallet.id,
      userId: req.user.id,
      bookingId: null,
      type: 'refund',
      amount: amt,
      balanceAfter: after.balance,
      description: 'Withdrawal cancelled — amount returned to wallet',
    });

    await notify(client, {
      userId: req.user.id,
      type: 'withdrawal_cancelled',
      title: 'Withdrawal cancelled',
      body: `PKR ${amt} is back in your wallet.`,
    });

    await client.query('COMMIT');
    res.json({
      success: true,
      data: { newBalance: after.balance },
      message: `Withdrawal cancelled — PKR ${amt} returned.`,
    });
  } catch (e) { await client.query('ROLLBACK'); next(e); }
  finally { client.release(); }
});

module.exports = router;
