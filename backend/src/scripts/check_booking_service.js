/**
 * check_booking_service.js — proves the S.6 Wave C extraction did not change money.
 *
 * Usage: node src/scripts/check_booking_service.js
 *
 * routes/bookings.js POST "/" and PATCH "/:id/cancel" were reduced to transport
 * and their rules moved into services/bookingService.js so the assistant can
 * execute the same code path (FR8.15). A refactor of escrow code is exactly the
 * kind of change that passes review and still loses PKR 200 per cancellation, so
 * this script books and cancels for real and asserts the ledger.
 *
 * Everything runs inside a transaction that is always rolled back. It calls the
 * core functions (createBooking / cancelBooking), not the *Tx wrappers, precisely
 * so the transaction stays this script's to abandon: a verification pass must not
 * leave a booked slot, a spent wallet or a ledger row behind on a database the
 * committee will look at.
 *
 * What is asserted, per the table at the top of utils/escrow.js:
 *
 *   book                  player balance -P, frozen +P, booking pending, slot booked
 *   cancel  >= 24h out    player balance +P, frozen -P, owner untouched, slot free
 *   cancel  <  24h out    player balance +0.8P, frozen -P, owner +0.2P
 *   preview               quotes the same refund/penalty the execution then moves
 *   double-book           second attempt on a booked slot is refused (slot_taken)
 *   double-cancel         second cancel is refused (not_cancellable)
 *   broke player          a balance below the slot price is refused, wallet intact
 */
const pool = require('../db/pool');
const {
  createBooking,
  cancelBooking,
  previewCancellation,
  listCancellable,
} = require('../services/bookingService');
const { POLICY, round2, asNum, depositFor } = require('../utils/escrow');

const failures = [];
let passed = 0;
function check(ok, label, detail = '') {
  if (ok) { passed += 1; console.log(`   ✓ ${label}`); }
  else {
    failures.push(label);
    console.log(`   ✗ ${label}${detail ? ` — ${detail}` : ''}`);
  }
}
function near(a, b, eps = 0.011) {
  return Math.abs(round2(a) - round2(b)) <= eps;
}

async function wallet(client, userId) {
  const { rows } = await client.query(
    'SELECT balance, frozen_balance FROM wallets WHERE user_id=$1', [userId]);
  return rows.length
    ? { balance: asNum(rows[0].balance), frozen: asNum(rows[0].frozen_balance) }
    : { balance: 0, frozen: 0 };
}

/**
 * Find a player and an available slot whose start is at least `minHoursOut` away
 * (or, when `late` is true, inside the cancellation window so the 80/20 split is
 * the one under test). Returns null when the seeded data cannot supply one, and
 * the caller reports a skip rather than a failure — an empty slot table is a
 * seeding problem, not a bug in the money.
 */
async function findSlot(client, { late }) {
  const cmp = late ? '<' : '>=';
  const { rows } = await client.query(
    `SELECT s.id, s.venue_id, s.price, s.slot_date, s.start_time,
            v.owner_id, v.name AS venue_name
       FROM slots s JOIN venues v ON v.id = s.venue_id
      WHERE s.status = 'available'
        AND (s.locked_until IS NULL OR s.locked_until < NOW())
        AND s.price > 0
        AND (s.slot_date + s.start_time) - (NOW() + interval '5 hours')
            ${cmp} interval '${POLICY.CANCELLATION_WINDOW_HOURS} hours'
        AND (s.slot_date + s.start_time) > (NOW() + interval '5 hours')
      ORDER BY s.slot_date ASC, s.start_time ASC
      LIMIT 1`,
  );
  return rows[0] || null;
}

async function findPlayer(client, minBalance) {
  const { rows } = await client.query(
    `SELECT u.id, u.name, w.balance
       FROM users u JOIN wallets w ON w.user_id = u.id
      WHERE u.role = 'player' AND w.balance >= $1
      ORDER BY w.balance DESC LIMIT 1`,
    [minBalance],
  );
  return rows[0] || null;
}

/**
 * One book-then-cancel cycle, asserted end to end. `late` selects which side of
 * the 24-hour boundary the slot sits on, which is the only thing that changes the
 * arithmetic — so the same function proves both rows of the escrow table.
 */
async function cycle(client, { late }) {
  const label = late ? 'LATE cancellation (inside the 24h window)' : 'EARLY cancellation (full refund)';
  console.log('');
  console.log(`── ${label} ──`);

  const slot = await findSlot(client, { late });
  if (!slot) {
    console.log('   ~ skipped: no available future slot on this side of the window.');
    console.log('     (run: node src/scripts/add_future_slots.js)');
    return;
  }
  const price = round2(slot.price);
  const player = await findPlayer(client, price);
  if (!player) {
    console.log(`   ~ skipped: no player wallet holds PKR ${price}.`);
    return;
  }

  const before = await wallet(client, player.id);
  const ownerBefore = await wallet(client, slot.owner_id);
  const dstr = slot.slot_date instanceof Date
    ? slot.slot_date.toLocaleDateString('en-CA') : String(slot.slot_date).slice(0, 10);
  console.log(`   slot ${dstr} ${String(slot.start_time).slice(0, 5)} `
    + `at ${slot.venue_name}, PKR ${price}`);
  console.log(`   player ${player.name}: balance ${before.balance}, frozen ${before.frozen}`);

  // Book
  const booked = await createBooking(client, {
    userId: player.id, slotId: slot.id, venueId: slot.venue_id,
    notes: '__check_booking_service',
  });
  check(booked.ok && booked.status === 201, 'createBooking returns 201', JSON.stringify(booked));
  if (!booked.ok) return;

  const afterBook = await wallet(client, player.id);
  check(near(afterBook.balance, before.balance - price),
    `player balance fell by exactly the slot price (${before.balance} → ${afterBook.balance}, P=${price})`);
  check(near(afterBook.frozen, before.frozen + price),
    `player frozen rose by exactly the slot price (${before.frozen} → ${afterBook.frozen})`);
  check(booked.data.status === 'pending', `booking opens as 'pending' — got '${booked.data.status}'`);
  check(near(booked.data.deposit_amount, depositFor(price)),
    `deposit_amount is ${POLICY.DEPOSIT_PERCENT}% of the price `
    + `(${booked.data.deposit_amount} vs ${depositFor(price)})`);
  check(near(booked.data.security_deposit, price),
    `security_deposit holds the FULL escrowed price (${booked.data.security_deposit})`);
  check(!!booked.data.qr_code, 'a QR code was generated');

  const { rows: [slotNow] } = await client.query(
    'SELECT status, locked_by, locked_until FROM slots WHERE id=$1', [slot.id]);
  check(slotNow.status === 'booked' && !slotNow.locked_by && !slotNow.locked_until,
    `the slot is 'booked' and the checkout hold was dropped — got ${JSON.stringify(slotNow)}`);

  const { rows: txns } = await client.query(
    `SELECT type, amount FROM transactions WHERE booking_id=$1 ORDER BY created_at`,
    [booked.data.id]);
  check(txns.length === 1 && txns[0].type === 'booking_payment' && near(txns[0].amount, -price),
    `exactly one ledger row: booking_payment ${-price} — got ${JSON.stringify(txns)}`);

  // Double book — the row lock's job
  const again = await createBooking(client, {
    userId: player.id, slotId: slot.id, venueId: slot.venue_id,
  });
  check(!again.ok && again.status === 409 && again.code === 'slot_taken',
    `booking the same slot twice is refused with 409 slot_taken — got ${again.status}/${again.code}`);

  // Preview — must quote what execution will move
  const pv = await previewCancellation(client, { userId: player.id, bookingId: booked.data.id });
  check(pv.ok, 'previewCancellation reads the booking back', JSON.stringify(pv));
  if (!pv.ok) return;
  check(pv.data.late === late,
    `preview puts the slot on the ${late ? 'late' : 'early'} side of the ${pv.data.windowHours}h window`);
  const expectRefund = late ? round2(price - depositFor(price)) : price;
  const expectPenalty = late ? depositFor(price) : 0;
  check(near(pv.data.refund, expectRefund) && near(pv.data.penalty, expectPenalty),
    `preview quotes refund ${expectRefund} / penalty ${expectPenalty} `
    + `— got ${pv.data.refund} / ${pv.data.penalty}`);
  check(pv.data.refundPct === (late ? 100 - POLICY.DEPOSIT_PERCENT : 100),
    `preview refundPct is ${late ? 100 - POLICY.DEPOSIT_PERCENT : 100}% — got ${pv.data.refundPct}%`);

  const cancellable = await listCancellable(client, { userId: player.id, limit: 50 });
  check(Array.isArray(cancellable) && cancellable.some((b) => b.id === booked.data.id),
    'listCancellable offers the new booking to the dialog manager');

  // Cancel
  const cancelled = await cancelBooking(client, { userId: player.id, bookingId: booked.data.id });
  check(cancelled.ok && cancelled.status === 200, 'cancelBooking returns 200', JSON.stringify(cancelled));
  if (!cancelled.ok) return;

  check(near(cancelled.data.refund, pv.data.refund) && near(cancelled.data.penalty, pv.data.penalty),
    `execution moved exactly what the preview quoted `
    + `(${pv.data.refund}/${pv.data.penalty} → ${cancelled.data.refund}/${cancelled.data.penalty})`);

  const afterCancel = await wallet(client, player.id);
  const ownerAfter = await wallet(client, slot.owner_id);
  check(near(afterCancel.balance, before.balance - expectPenalty),
    `player is out exactly the penalty over the whole cycle `
    + `(${before.balance} → ${afterCancel.balance}, penalty=${expectPenalty})`);
  check(near(afterCancel.frozen, before.frozen),
    `player frozen returned to its opening value (${before.frozen} → ${afterCancel.frozen})`);
  check(near(ownerAfter.balance, ownerBefore.balance + expectPenalty),
    `owner received exactly the penalty (${ownerBefore.balance} → ${ownerAfter.balance})`);
  check(near(ownerAfter.frozen, ownerBefore.frozen),
    'owner frozen balance was never touched');

  const { rows: [bookingRow] } = await client.query(
    'SELECT status, cancellation_reason FROM bookings WHERE id=$1', [booked.data.id]);
  check(bookingRow.status === 'cancelled'
    && bookingRow.cancellation_reason === (late ? 'late_cancellation' : 'user_cancelled'),
    `booking is cancelled with reason '${bookingRow.cancellation_reason}'`);

  const { rows: [slotFree] } = await client.query(
    'SELECT status FROM slots WHERE id=$1', [slot.id]);
  check(slotFree.status === 'available', `the slot is back on sale — got '${slotFree.status}'`);

  const { rows: ledger } = await client.query(
    `SELECT type, amount FROM transactions WHERE booking_id=$1 ORDER BY created_at, type`,
    [booked.data.id]);
  const types = ledger.map((t) => t.type).sort().join(',');
  const wantTypes = late
    ? 'booking_payment,escrow_received,escrow_release,refund'
    : 'booking_payment,refund';
  check(types === wantTypes, `ledger rows are exactly ${wantTypes} — got ${types}`);
  const sum = round2(ledger.reduce((a, t) => a + asNum(t.amount), 0));
  check(near(sum, -expectPenalty),
    `the ledger sums to -${expectPenalty} (what the player actually lost) — got ${sum}`);

  // Double cancel
  const twice = await cancelBooking(client, { userId: player.id, bookingId: booked.data.id });
  check(!twice.ok && twice.status === 400 && twice.code === 'not_cancellable',
    `cancelling twice is refused with 400 not_cancellable — got ${twice.status}/${twice.code}`);
  const pvTwice = await previewCancellation(client, { userId: player.id, bookingId: booked.data.id });
  check(!pvTwice.ok && pvTwice.code === 'not_cancellable',
    'the preview refuses an already-cancelled booking too, so no chip can offer it');
}

/**
 * A player whose balance is below the slot price must be refused, and refused
 * without moving a rupee — the assistant will happily let a user try.
 */
async function brokeCheck(client) {
  console.log('');
  console.log('── INSUFFICIENT FUNDS ──');
  const slot = await findSlot(client, { late: false });
  if (!slot) { console.log('   ~ skipped: no available future slot.'); return; }
  const price = round2(slot.price);

  const { rows } = await client.query(
    `SELECT u.id, u.name, w.balance FROM users u JOIN wallets w ON w.user_id = u.id
      WHERE u.role = 'player' AND w.balance < $1 ORDER BY w.balance ASC LIMIT 1`,
    [price],
  );
  if (!rows.length) {
    console.log(`   ~ skipped: every player wallet can afford PKR ${price}.`);
    return;
  }
  const broke = rows[0];
  const wBefore = await wallet(client, broke.id);
  const res = await createBooking(client, {
    userId: broke.id, slotId: slot.id, venueId: slot.venue_id,
  });
  check(!res.ok && res.status === 400 && res.code === 'insufficient_funds',
    `PKR ${wBefore.balance} against a PKR ${price} slot is refused with `
    + `400 insufficient_funds — got ${res.status}/${res.code}`);
  check(typeof res.code === 'string' && res.code !== 'ok' && !!res.message,
    `the refusal carries a machine code plus human text, so the dialog manager `
    + `never string-matches English — got ${res.code} / "${res.message}"`);
  const wAfter = await wallet(client, broke.id);
  check(near(wAfter.balance, wBefore.balance) && near(wAfter.frozen, wBefore.frozen),
    'the refused attempt left the wallet exactly as it was');
  const { rows: [slotStill] } = await client.query(
    'SELECT status, locked_by FROM slots WHERE id=$1', [slot.id]);
  check(slotStill.status === 'available' && !slotStill.locked_by,
    'the refused attempt wrote nothing: the slot is still available and unheld');

  // Bad input, since the dialog manager will pass whatever a user typed.
  const noArgs = await createBooking(client, { userId: broke.id });
  check(!noArgs.ok && noArgs.code === 'missing_args',
    `a call with no slotId is refused with missing_args — got ${noArgs.code}`);
  const ghost = await createBooking(client, {
    userId: broke.id,
    slotId: '00000000-0000-0000-0000-000000000000',
    venueId: slot.venue_id,
  });
  check(!ghost.ok && ghost.status === 404 && ghost.code === 'slot_not_found',
    `an unknown slot id is refused with 404 slot_not_found — got ${ghost.status}/${ghost.code}`);
}

async function main() {
  console.log('══ bookingService.js — live escrow verification (always rolled back) ══');
  console.log(`   policy: deposit ${POLICY.DEPOSIT_PERCENT}%, `
    + `cancellation window ${POLICY.CANCELLATION_WINDOW_HOURS}h, tz ${POLICY.TIMEZONE}`);

  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await cycle(client, { late: false });
    await cycle(client, { late: true });
    await brokeCheck(client);
  } catch (err) {
    console.error('');
    console.error('✗ threw:', err.message);
    failures.push(`threw: ${err.message}`);
  } finally {
    await client.query('ROLLBACK').catch(() => {});
    client.release();
    await pool.end();
  }

  console.log('');
  console.log(`PASS ${passed}/${passed + failures.length}`);
  if (failures.length) {
    console.log(`❌ ${failures.length} check(s) failed:`);
    failures.forEach((f) => console.log(`   - ${f}`));
    process.exit(1);
  }
  console.log('✅ bookingService matches the escrow table — the extraction is money-safe.');
  process.exit(0);
}

main();
