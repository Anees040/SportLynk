/**
 * No-Show Auto Job
 * Runs every 60 seconds. Marks confirmed bookings as no_show
 * if the slot start time has passed by more than 30 minutes.
 * Transfers security_deposit from player frozen → owner balance.
 * Penalises trust_score by -10.
 */

const pool = require('../db/pool');

let _running = false;

async function processNoShows() {
  if (_running) return;
  _running = true;
  const client = await pool.connect();
  try {
    // Find all confirmed bookings where start time + 30 min has passed
    const overdueRes = await client.query(`
      SELECT
        b.id, b.security_deposit, b.player_id, b.slot_id,
        v.owner_id, u.name AS player_name, v.name AS venue_name
      FROM bookings b
      JOIN venues v ON b.venue_id = v.id
      JOIN users u ON b.player_id = u.id
      WHERE b.status = 'confirmed'
        AND (b.slot_date::DATE + b.start_time::TIME) < (NOW() AT TIME ZONE 'Asia/Karachi') - INTERVAL '30 minutes'
        AND b.no_show_processed IS NOT TRUE
    `);

    if (overdueRes.rows.length === 0) {
      return;
    }

    console.log(`[NoShowJob] Processing ${overdueRes.rows.length} overdue booking(s)...`);

    for (const b of overdueRes.rows) {
      const innerClient = await pool.connect();
      try {
        const deposit = parseFloat(b.security_deposit || 0);
        await innerClient.query('BEGIN');

        // Mark booking as no_show
        await innerClient.query(
          `UPDATE bookings
           SET status = 'no_show', no_show_at = NOW(), no_show_processed = true
           WHERE id = $1`,
          [b.id]
        );

        // Release slot back to available
        if (b.slot_id) {
          await innerClient.query(
            "UPDATE slots SET status = 'available' WHERE id = $1",
            [b.slot_id]
          );
        }

        if (deposit > 0) {
          // Deduct from player frozen balance
          const pw = await innerClient.query(
            `UPDATE wallets
             SET frozen_balance = GREATEST(frozen_balance - $1, 0)
             WHERE user_id = $2
             RETURNING id, balance`,
            [deposit, b.player_id]
          );

          // Add to owner balance
          const ow = await innerClient.query(
            `UPDATE wallets
             SET balance = balance + $1
             WHERE user_id = $2
             RETURNING id, balance`,
            [deposit, b.owner_id]
          );

          if (pw.rows.length > 0) {
            await innerClient.query(
              `INSERT INTO transactions (wallet_id, user_id, booking_id, type, amount, balance_after, description)
               VALUES ($1, $2, $3, 'no_show_penalty', $4, $5, 'Auto no-show: deposit forfeited (30 min rule)')`,
              [pw.rows[0].id, b.player_id, b.id, -deposit, pw.rows[0].balance]
            );
          }

          if (ow.rows.length > 0) {
            await innerClient.query(
              `INSERT INTO transactions (wallet_id, user_id, booking_id, type, amount, balance_after, description, counterparty_name)
               VALUES ($1, $2, $3, 'escrow_received', $4, $5, 'Auto no-show deposit received', $6)`,
              [ow.rows[0].id, b.owner_id, b.id, deposit, ow.rows[0].balance, b.player_name]
            );
          }
        }

        // Penalise player trust score
        await innerClient.query(
          `UPDATE player_profiles
           SET trust_score = GREATEST(trust_score - 10, 0)
           WHERE user_id = $1`,
          [b.player_id]
        );

        await innerClient.query('COMMIT');
        console.log(`[NoShowJob] ✓ Booking ${b.id} (${b.player_name} @ ${b.venue_name}) marked no_show. PKR ${deposit} transferred.`);
      } catch (err) {
        await innerClient.query('ROLLBACK');
        console.error(`[NoShowJob] ✗ Failed booking ${b.id}:`, err.message);
      } finally {
        innerClient.release();
      }
    }
  } catch (err) {
    console.error('[NoShowJob] Query error:', err.message);
  } finally {
    _running = false;
    client.release();
  }
}

function startNoShowJob() {
  console.log('[NoShowJob] Started — checks every 60 seconds.');
  // Run once on startup after a short delay
  setTimeout(processNoShows, 5000);
  // Then every 60 seconds
  setInterval(processNoShows, 60 * 1000);
}

module.exports = { startNoShowJob };
