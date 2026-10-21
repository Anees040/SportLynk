// Read-only integration check for the owner's booking-player profile lookup.
const assert = require('node:assert/strict');
const pool = require('../db/pool');
const { bookingPlayerProfile } = require('../services/userService');

async function main() {
  const { rows } = await pool.query(
    `SELECT DISTINCT ON (b.status) b.id, b.player_id, b.status, v.owner_id
       FROM bookings b JOIN venues v ON v.id = b.venue_id
      WHERE b.status IN ('pending', 'confirmed', 'rejected', 'cancelled')
      ORDER BY b.status, b.created_at DESC`,
  );
  assert.ok(rows.length, 'No bookings available for verification');
  for (const booking of rows) {
    const result = await bookingPlayerProfile(pool, {
      ownerId: booking.owner_id, bookingId: booking.id,
    });
    assert.equal(result.ok, true);
    assert.equal(result.data.id, booking.player_id);
    assert.equal(result.data.isSelf, false);
    assert.ok(result.data.trustScore === null || Number.isFinite(result.data.trustScore));
    const forbidden = await bookingPlayerProfile(pool, {
      ownerId: '00000000-0000-0000-0000-000000000000', bookingId: booking.id,
    });
    assert.equal(forbidden.status, 404);
    console.log(`${booking.status}: player profile and trust readable by the venue owner; unrelated owner refused.`);
  }
}

main().catch(e => {
  console.error('Owner profile verification failed:', e.code, e.message);
  process.exitCode = 1;
}).finally(() => pool.end());
