/**
 * seed_slot_states.js — give a venue a realistic mix of slot states for testing.
 *
 * Why this exists
 * A freshly generated venue is a wall of identical green "available" chips, so the
 * player grid's other three states — booked (amber), blocked (red), held (blue) —
 * are never seen while testing. This spreads a venue's near-future slots across all
 * four so the grid, the colour legend, and the "can't select a taken slot" paths can
 * actually be exercised.
 *
 * Honest states, not painted ones
 *   - blocked : status='blocked' — exactly what an owner's Block button does.
 *   - held    : a real `locked_until` in the future owned by another player — exactly
 *               what a second player mid-checkout produces (it expires in 5 min).
 *   - booked  : a REAL booking via bookingService.createBookingTx, so the wallet
 *               ledger, the owner's pending-requests list and the booking detail are
 *               all consistent. It is NOT a status='booked' row with no booking
 *               behind it, which would be a placeholder the rest of the app trips on.
 *   - the rest stay available.
 *
 * Writes to the live database, so it is DRY-RUN BY DEFAULT. Pass --commit to write.
 * Booked slots spend a test player's wallet, so on --commit the three seeded test
 * players (bilal/hina/usman@test.pk) are topped up first; nothing touches a real
 * user. --reset frees blocks and holds again (bookings are real money movements and
 * are left alone — cancel them through the app if needed).
 *
 * USAGE
 *   node src/scripts/seed_slot_states.js                      # dry run, all active venues
 *   node src/scripts/seed_slot_states.js --venue <uuid> --commit
 *   node src/scripts/seed_slot_states.js --days 3 --commit
 *   node src/scripts/seed_slot_states.js --reset --commit     # back to all-available
 */
const pool = require('../db/pool');
const { createBookingTx } = require('../services/bookingService');

function argOf(flag, fallback) {
  const i = process.argv.indexOf(flag);
  if (i === -1 || i === process.argv.length - 1) return fallback;
  return process.argv[i + 1];
}
const VENUE = argOf('--venue', null);
const DAYS = Math.max(1, Math.min(14, parseInt(argOf('--days', '3'), 10) || 3));
const COMMIT = process.argv.includes('--commit');
const RESET = process.argv.includes('--reset');

/** A test player's wallet must clear a few bookings; top it well past any slot price. */
const TEST_WALLET_FLOOR = 100000;

function shuffle(arr) {
  for (let i = arr.length - 1; i > 0; i -= 1) {
    const j = Math.floor(Math.random() * (i + 1));
    [arr[i], arr[j]] = [arr[j], arr[i]];
  }
  return arr;
}

async function activeVenues() {
  const { rows } = await pool.query(
    `SELECT id, name FROM venues WHERE is_active = true ${VENUE ? 'AND id = $1' : ''} ORDER BY name`,
    VENUE ? [VENUE] : [],
  );
  return rows;
}

async function futureAvailable(venueId) {
  const { rows } = await pool.query(
    `SELECT id FROM slots
      WHERE venue_id = $1
        AND status = 'available'
        AND NOT (locked_until IS NOT NULL AND locked_until > NOW())
        AND slot_date <= ((NOW() AT TIME ZONE 'Asia/Karachi')::date + ($2::int - 1))
        AND (slot_date > (NOW() AT TIME ZONE 'Asia/Karachi')::date
         OR (slot_date = (NOW() AT TIME ZONE 'Asia/Karachi')::date
             AND start_time > (NOW() AT TIME ZONE 'Asia/Karachi')::time))
      ORDER BY slot_date, start_time`,
    [venueId, DAYS],
  );
  return rows.map((r) => r.id);
}

async function testPlayers() {
  const { rows } = await pool.query(
    `SELECT u.id, u.name, w.id AS wallet_id, w.balance
       FROM users u JOIN wallets w ON w.user_id = u.id
      WHERE u.role = 'player' AND u.email LIKE '%@test.pk'
      ORDER BY u.name`,
  );
  return rows;
}

async function reset() {
  const venues = await activeVenues();
  let freed = 0;
  for (const v of venues) {
    if (!COMMIT) {
      const { rows } = await pool.query(
        `SELECT COUNT(*)::int c FROM slots
          WHERE venue_id = $1 AND (status = 'blocked'
             OR (locked_until IS NOT NULL AND locked_until > NOW()))`,
        [v.id],
      );
      console.log(`  ${v.name}: ${rows[0].c} blocked/held slot(s) would be freed`);
      freed += rows[0].c;
      continue;
    }
    const r = await pool.query(
      `UPDATE slots
          SET status = CASE WHEN status = 'blocked' THEN 'available'::slot_status ELSE status END,
              locked_by = NULL, locked_until = NULL
        WHERE venue_id = $1 AND (status = 'blocked'
           OR (locked_until IS NOT NULL AND locked_until > NOW()))`,
      [v.id],
    );
    console.log(`  ${v.name}: freed ${r.rowCount} blocked/held slot(s)`);
    freed += r.rowCount;
  }
  console.log(`\n  ${COMMIT ? 'Freed' : 'Would free'} ${freed} slot(s). Bookings were left intact.`);
}

async function seed() {
  const venues = await activeVenues();
  if (!venues.length) {
    console.log(VENUE ? '  No active venue with that id.' : '  No active venues.');
    return;
  }

  const players = await testPlayers();
  if (COMMIT && !players.length) {
    console.log('  No @test.pk player accounts found — run `npm run seed` first.');
    return;
  }
  if (COMMIT) {
    // Top the test players up so a run of bookings cannot fail on balance. These are
    // seeded test identities only; no real user's wallet is touched.
    await pool.query(
      `UPDATE wallets SET balance = GREATEST(balance, $1)
        WHERE user_id IN (SELECT id FROM users WHERE role='player' AND email LIKE '%@test.pk')`,
      [TEST_WALLET_FLOOR],
    );
  }

  let rr = 0;
  for (const v of venues) {
    const ids = shuffle(await futureAvailable(v.id));
    if (!ids.length) {
      console.log(`  ${v.name}: no future available slots to spread`);
      continue;
    }
    // ~20% booked, ~20% blocked, ~10% held, the rest left available.
    const nBook = Math.max(1, Math.round(ids.length * 0.2));
    const nBlock = Math.max(1, Math.round(ids.length * 0.2));
    const nHold = Math.max(1, Math.round(ids.length * 0.1));
    const toBook = ids.slice(0, nBook);
    const toBlock = ids.slice(nBook, nBook + nBlock);
    const toHold = ids.slice(nBook + nBlock, nBook + nBlock + nHold);

    if (!COMMIT) {
      console.log(`  ${v.name}: of ${ids.length} free → would book ${toBook.length}, `
        + `block ${toBlock.length}, hold ${toHold.length}, leave ${ids.length - toBook.length - toBlock.length - toHold.length}`);
      continue;
    }

    let booked = 0;
    for (let i = 0; i < toBook.length; i += 1) {
      const player = players[(rr + i) % players.length];
      const out = await createBookingTx({ userId: player.id, slotId: toBook[i], venueId: v.id });
      if (out.ok) booked += 1;
    }
    rr += toBook.length;

    const blk = await pool.query(
      `UPDATE slots SET status='blocked' WHERE id = ANY($1::uuid[]) AND status='available'`,
      [toBlock],
    );
    const held = await pool.query(
      `UPDATE slots SET locked_by=$2, locked_until=NOW() + interval '5 minutes'
        WHERE id = ANY($1::uuid[]) AND status='available'`,
      [toHold, players[0].id],
    );
    console.log(`  ${v.name}: booked ${booked}, blocked ${blk.rowCount}, held ${held.rowCount}, `
      + `left ${ids.length - booked - blk.rowCount - held.rowCount} available`);
  }
}

async function main() {
  console.log('');
  console.log('═══ Seed slot states ═══════════════════════════════════════════');
  console.log(`  Scope : ${VENUE ? 'one venue' : 'all active venues'}, next ${DAYS} day(s)`);
  console.log(`  Mode  : ${COMMIT ? 'WRITING' : '--dry (default) — pass --commit to write'}`);
  console.log(RESET ? '  Action: --reset (free blocks and holds)' : '  Action: spread states');
  console.log('');
  if (RESET) await reset();
  else await seed();
  console.log('');
}

main()
  .then(async () => { await pool.end().catch(() => {}); })
  .catch(async (e) => {
    console.error('Failed:', e.message);
    await pool.end().catch(() => {});
    process.exitCode = 1;
  });

