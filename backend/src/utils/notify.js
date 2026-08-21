/**
 * Notification rows. Written inside the same transaction as the ledger move
 * that caused them, so a rolled-back money move never leaves a stray alert.
 *
 * The INSERT is wrapped in a SAVEPOINT: if the notifications table is missing
 * (migration 010 not run yet) the alert is skipped but the money move — the
 * part that must never be lost — still commits.
 */

async function notify(client, { userId, bookingId = null, type, title, body = null }) {
  if (!userId) return;
  await client.query('SAVEPOINT sl_notify');
  try {
    await client.query(
      `INSERT INTO notifications (user_id, booking_id, type, title, body)
       VALUES ($1,$2,$3,$4,$5)`,
      [userId, bookingId, type, title, body],
    );
    await client.query('RELEASE SAVEPOINT sl_notify');
  } catch (e) {
    await client.query('ROLLBACK TO SAVEPOINT sl_notify');
    if (e.code === '42P01') {
      console.warn('[notify] notifications table missing — run node run_migration_010.js');
      return;
    }
    throw e;
  }
}

module.exports = { notify };
