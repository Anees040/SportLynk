require('dotenv').config();
const { Pool } = require('pg');
const pool = new Pool({ connectionString: process.env.DATABASE_URL });

async function run() {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const b = await client.query(
      `SELECT b.*, v.owner_id
       FROM bookings b
       JOIN venues v ON v.id = b.venue_id
       WHERE b.id=$1 FOR UPDATE`,
      ['59f42046-4bf9-4c0b-8a8b-95168d2d39e5']
    );

    if (!b.rows.length) throw new Error('Not found');

    const deposit = parseFloat(b.rows[0].security_deposit);
    const ownerId = b.rows[0].owner_id;
    const playerId = b.rows[0].player_id;
    const bookingId = '59f42046-4bf9-4c0b-8a8b-95168d2d39e5';

    const d = b.rows[0].slot_date;
    const slotDateStr = d instanceof Date ? d.toLocaleDateString("en-CA") : d;
    const slotDateTimeStr = `${slotDateStr}T${b.rows[0].start_time}`;
    const slotDateTime = new Date(slotDateTimeStr);
    const now = new Date();

    const diffHours = (slotDateTime - now) / (1000 * 60 * 60);
    const isLateCancel = diffHours < 12;

    if (isLateCancel) {
      await client.query(
        `UPDATE wallets SET frozen_balance=GREATEST(frozen_balance-$1, 0) WHERE user_id=$2`,
        [deposit, playerId]
      );
      const ownerWallet = await client.query(
        `UPDATE wallets SET balance=balance+$1 WHERE user_id=$2 RETURNING id, balance`,
        [deposit, ownerId]
      );
      const playerWallet = await client.query(
        `SELECT id, balance FROM wallets WHERE user_id=$1`,
        [playerId]
      );
      await client.query(
        `INSERT INTO transactions (wallet_id, user_id, booking_id, type, amount, balance_after, description)
         VALUES ($1,$2,$3,'escrow_release',-$4,$5,'Late cancellation penalty to owner')`,
        [playerWallet.rows[0].id, playerId, bookingId, deposit, playerWallet.rows[0].balance]
      );
      await client.query(
        `INSERT INTO transactions (wallet_id, user_id, booking_id, type, amount, balance_after, description)
         VALUES ($1,$2,$3,'escrow_received',$4,$5,'Received late cancellation penalty')`,
        [ownerWallet.rows[0].id, ownerId, bookingId, deposit, ownerWallet.rows[0].balance]
      );
    } else {
      await client.query(
        `UPDATE wallets SET frozen_balance=GREATEST(frozen_balance-$1, 0) WHERE user_id=$2`,
        [deposit, playerId]
      );
      const playerWallet = await client.query(
        `UPDATE wallets SET balance=balance+$1 WHERE user_id=$2 RETURNING balance, id`,
        [deposit, playerId]
      );
      await client.query(
        `INSERT INTO transactions (wallet_id, user_id, booking_id, type, amount, balance_after, description)
         VALUES ($1,$2,$3,'refund',$4,$5,'Booking cancellation refund')`,
        [playerWallet.rows[0].id, playerId, bookingId, deposit, playerWallet.rows[0].balance]
      );
    }
    
    await client.query(
      `UPDATE bookings SET status='cancelled', cancelled_at=NOW(), cancellation_reason=$1 WHERE id=$2`,
      [isLateCancel ? "late_cancellation" : "user_cancelled", bookingId]
    );
    await client.query(
      `UPDATE slots SET status='available', locked_at=null, locked_by=null WHERE id=$1`,
      [b.rows[0].slot_id]
    );
    await client.query('ROLLBACK'); // rollback just in case
    console.log('Success!', isLateCancel ? 'Late' : 'Early');
  } catch(e) {
    await client.query('ROLLBACK');
    console.error('Error:', e);
  } finally {
    client.release();
    pool.end();
  }
}
run();
