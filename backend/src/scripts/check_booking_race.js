/**
 * check_booking_race.js — proves two players cannot book the same slot at once.
 *
 * Usage:
 *   node src/scripts/check_booking_race.js            # explain, touch nothing
 *   node src/scripts/check_booking_race.js --run       # run the live race, then clean up
 *
 * The guarantee under test lives in services/bookingService.js::createBooking: it
 * takes `SELECT … FOR UPDATE OF s` on the slot row before it checks status, so two
 * concurrent bookings serialise on that row lock — the first commits status='booked'
 * and the second, unblocked a moment later, reads 'booked' and is refused with code
 * `slot_taken`. check_booking_service.js already asserts the *serial* refusal; this
 * asserts the *concurrent* one, which is the "same millisecond" case.
 *
 * Why it needs a real commit (and therefore cleans up): proving the second caller is
 * refused requires the first to have committed the booked status — a rolled-back
 * winner would release the lock with the slot still free and the second would simply
 * succeed. So this books for real on a far-future slot (a full-refund cancel window),
 * asserts the outcome, then cancels the winner through the normal path. Net effect:
 * the slot is available again and the test player's balance is whole; the only trace
 * is a booking_payment + refund pair in the ledger, which is the honest record of
 * what happened.
 *
 * Gated behind --run so it never books by accident.
 */
const pool = require('../db/pool');
const { createBookingTx, cancelBookingTx } = require('../services/bookingService');

const RUN = process.argv.includes('--run');

async function farFutureSlot() {
  // Day 10+ ahead, available, cheap-enough for a topped-up test wallet. Far future
  // so the cleanup cancel lands in the full-refund (>24h) window.
  const { rows } = await pool.query(
    `SELECT s.id, s.venue_id, s.price, v.name AS venue_name
       FROM slots s JOIN venues v ON v.id = s.venue_id
      WHERE s.status = 'available' AND v.is_active = true
        AND NOT (s.locked_until IS NOT NULL AND s.locked_until > NOW())
        AND s.slot_date >= ((NOW() AT TIME ZONE 'Asia/Karachi')::date + 10)
      ORDER BY s.slot_date, s.start_time
      LIMIT 1`,
  );
  return rows[0] || null;
}

async function twoTestPlayers(minBalance) {
  // Top two @test.pk players so neither fails on balance, and return their ids.
  await pool.query(
    `UPDATE wallets SET balance = GREATEST(balance, $1)
      WHERE user_id IN (SELECT id FROM users WHERE role='player' AND email LIKE '%@test.pk')`,
    [minBalance],
  );
  const { rows } = await pool.query(
    `SELECT u.id, u.name FROM users u
      WHERE u.role='player' AND u.email LIKE '%@test.pk' ORDER BY u.name LIMIT 2`,
  );
  return rows;
}

async function main() {
  console.log('\n═══ Booking race check ═════════════════════════════════════════\n');
  if (!RUN) {
    console.log('  Dry: pass --run to fire two concurrent bookings at one slot and');
    console.log('  assert exactly one wins (the other gets slot_taken), then clean up.\n');
    console.log('  The guarantee is services/bookingService.js createBooking: SELECT …');
    console.log('  FOR UPDATE OF s, then a status recheck → 409 slot_taken.\n');
    return 0;
  }

  const slot = await farFutureSlot();
  if (!slot) { console.log('  No far-future available slot — run add_future_slots first.'); return 1; }
  const players = await twoTestPlayers(Number(slot.price) * 2 + 1000);
  if (players.length < 2) { console.log('  Need two @test.pk players — run `npm run seed`.'); return 1; }

  console.log(`  Slot ${slot.id} at ${slot.venue_name}, PKR ${slot.price}`);
  console.log(`  Firing ${players[0].name} and ${players[1].name} at it simultaneously…\n`);

  // Both calls launched before either is awaited — the real concurrent case.
  const [a, b] = await Promise.all([
    createBookingTx({ userId: players[0].id, slotId: slot.id, venueId: slot.venue_id }),
    createBookingTx({ userId: players[1].id, slotId: slot.id, venueId: slot.venue_id }),
  ]);

  const wins = [a, b].filter((r) => r.ok);
  const losers = [a, b].filter((r) => !r.ok);
  const winner = wins[0];
  const loser = losers[0];

  let ok = true;
  const assert = (cond, label) => {
    console.log(`  ${cond ? '✓' : '✗'} ${label}`);
    if (!cond) ok = false;
  };
  assert(wins.length === 1, `exactly one booking succeeded (got ${wins.length})`);
  assert(losers.length === 1, `exactly one booking was refused (got ${losers.length})`);
  assert(loser && loser.code === 'slot_taken',
    `the refused one is slot_taken (got ${loser ? loser.code : 'none'})`);

  // Clean up: cancel the winner (full refund at >24h), leaving the slot available.
  if (winner && winner.data && winner.data.id) {
    const winnerUser = winner === a ? players[0].id : players[1].id;
    const c = await cancelBookingTx({ userId: winnerUser, bookingId: winner.data.id });
    assert(c.ok, `winner cancelled and refunded (slot freed) — ${c.ok ? 'done' : c.code}`);
  }

  console.log(`\n  ${ok ? '✅ Race is prevented.' : '❌ Race NOT prevented — see above.'}\n`);
  return ok ? 0 : 1;
}

main()
  .then(async (code) => { await pool.end().catch(() => {}); process.exit(code); })
  .catch(async (e) => {
    console.error('  Failed:', e.message);
    await pool.end().catch(() => {});
    process.exit(1);
  });
