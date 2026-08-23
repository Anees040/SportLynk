/**
 * Notification rows. Written inside the same transaction as the ledger move
 * that caused them, so a rolled-back money move never leaves a stray alert.
 *
 * The INSERT is wrapped in a SAVEPOINT: if the notifications table is missing
 * (migration 010 not run yet) the alert is skipped but the money move — the
 * part that must never be lost — still commits.
 *
 * `payload` (jsonb, added by migration 013) carries the structured facts behind
 * the sentence: which match, how many ELO points, which team. Without it a
 * notification is a dead end — the app can show the text but cannot open the
 * thing it is about, and "+16 ELO" would have to be parsed back out of English.
 * A database that predates the column falls back to inserting without it rather
 * than failing the transaction.
 */

async function notify(client, { userId, bookingId = null, type, title, body = null, payload = null }) {
  if (!userId) return;
  await client.query('SAVEPOINT sl_notify');
  try {
    await client.query(
      `INSERT INTO notifications (user_id, booking_id, type, title, body, payload)
       VALUES ($1,$2,$3,$4,$5,$6)`,
      [userId, bookingId, type, title, body, payload],
    );
    await client.query('RELEASE SAVEPOINT sl_notify');
  } catch (e) {
    await client.query('ROLLBACK TO SAVEPOINT sl_notify');
    if (e.code === '42P01') {
      console.warn('[notify] notifications table missing — run node run_migration_010.js');
      return;
    }
    if (e.code === '42703') {
      // No payload column on this database (pre-013). The alert itself still
      // matters more than the structured extras, so retry without them.
      await client.query('SAVEPOINT sl_notify');
      try {
        await client.query(
          `INSERT INTO notifications (user_id, booking_id, type, title, body)
           VALUES ($1,$2,$3,$4,$5)`,
          [userId, bookingId, type, title, body],
        );
        await client.query('RELEASE SAVEPOINT sl_notify');
      } catch (inner) {
        await client.query('ROLLBACK TO SAVEPOINT sl_notify');
        if (inner.code !== '42P01') throw inner;
        console.warn('[notify] notifications table missing — run node run_migration_010.js');
      }
      return;
    }
    throw e;
  }
}

module.exports = { notify };
