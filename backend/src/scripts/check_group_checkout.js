// Exercise quotes and bookings using real PostgreSQL types and session-local
// copies only. No real slot, wallet, booking, notification or discount is changed.
const assert = require('node:assert/strict');
const pool = require('../db/pool');
const { previewGroup, createBookingGroup } = require('../services/bookingService');

async function main() {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query("SET LOCAL statement_timeout='15s'");
    const { rows: [pair] } = await client.query(
      `SELECT a.venue_id, ARRAY[a.id,b.id] AS ids
         FROM public.slots a JOIN public.slots b
           ON b.venue_id=a.venue_id AND b.slot_date=a.slot_date AND b.start_time=a.end_time
         JOIN public.venues v ON v.id=a.venue_id
        WHERE a.status='available' AND b.status='available'
          AND (a.locked_until IS NULL OR a.locked_until<=NOW())
          AND (b.locked_until IS NULL OR b.locked_until<=NOW())
          AND a.slot_date+a.start_time > NOW() AT TIME ZONE 'Asia/Karachi'
        ORDER BY (lower(v.name)='the pavilion') DESC, a.slot_date, a.start_time LIMIT 1`);
    assert.ok(pair, 'An available consecutive pair is required');
    const { rows: [player] } = await client.query(
      `SELECT u.id FROM public.users u JOIN public.wallets w ON w.user_id=u.id
        WHERE u.role='player' AND u.is_active IS NOT FALSE ORDER BY w.balance DESC LIMIT 1`);
    assert.ok(player, 'An active player is required');
    const tables = ['users', 'venues', 'wallets', 'slots', 'bookings', 'transactions', 'notifications', 'venue_slot_discounts'];
    for (const table of tables) {
      await client.query(`CREATE TEMP TABLE ${table} (LIKE public.${table} INCLUDING ALL) ON COMMIT DROP`);
      const { rows: [scope] } = await client.query(
        `SELECT $1::regclass = $2::regclass AS temporary`, [table, `pg_temp.${table}`]);
      assert.ok(scope.temporary, `${table} writes must target the temporary copy`);
    }
    await client.query('INSERT INTO pg_temp.users SELECT * FROM public.users WHERE id=$1', [player.id]);
    await client.query('INSERT INTO pg_temp.venues SELECT * FROM public.venues WHERE id=$1', [pair.venue_id]);
    await client.query('INSERT INTO pg_temp.wallets SELECT * FROM public.wallets WHERE user_id=$1', [player.id]);
    await client.query('INSERT INTO pg_temp.slots SELECT * FROM public.slots WHERE id=ANY($1::uuid[])', [pair.ids]);
    await client.query('UPDATE pg_temp.slots SET price=1600');
    await client.query('UPDATE pg_temp.venues SET deposit_pct=40');
    await client.query('UPDATE pg_temp.wallets SET balance=13190, frozen_balance=0');
    for (const percent of [0, 10]) {
      await client.query('SAVEPOINT scenario');
      if (percent) await client.query(
        'INSERT INTO pg_temp.venue_slot_discounts (venue_id,min_slots,percent) VALUES ($1,2,$2)',
        [pair.venue_id, percent]);
      const input = { userId: player.id, venueId: pair.venue_id, slotIds: pair.ids };
      const quote = await previewGroup(client, input);
      assert.equal(quote.ok, true);
      const total = percent ? 2880 : 3200;
      assert.equal(quote.data.total, total);
      assert.equal(quote.data.runs[0].discountPercent, percent);
      const created = await createBookingGroup(client, input);
      assert.equal(created.ok, true, created.message);
      assert.equal(created.data.total, total);
      assert.equal(created.data.bookings.length, 2);
      assert.equal(new Set(created.data.bookings.map(b => b.booking_group_id)).size, 1);
      assert.ok(created.data.bookings.every(b => b.status === 'pending' && b.qr_code));
      assert.equal(created.data.bookings.reduce((sum, b) => sum + Number(b.deposit_amount), 0), total * 0.4);
      const { rows: [wallet] } = await client.query('SELECT balance,frozen_balance FROM pg_temp.wallets WHERE user_id=$1', [player.id]);
      assert.equal(Number(wallet.balance), 13190 - total);
      assert.equal(Number(wallet.frozen_balance), total);
      const { rows: [ledger] } = await client.query('SELECT sum(amount) AS amount FROM pg_temp.transactions');
      assert.equal(Number(ledger.amount), -total);
      await client.query('ROLLBACK TO SAVEPOINT scenario');
      console.log(`PASS: ${percent}% discount, quote PKR ${total}, two pending bookings, correct escrow/deposit/ledger.`);
    }
  } finally {
    await client.query('ROLLBACK');
    client.release();
  }
}
main().catch(e => {
  console.error('Group checkout failed:', e.code || '', e.message);
  process.exitCode = 1;
}).finally(() => pool.end());
