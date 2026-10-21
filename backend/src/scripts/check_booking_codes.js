// Default: exercise the migration on a session-local temporary table only.
// --live: read-only validation of codes on the configured bookings table.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const pool = require('../db/pool');

async function main() {
  const client = await pool.connect();
  try {
    if (process.argv.includes('--live')) {
      const { rows: [counts] } = await client.query(
        `SELECT count(*)::int AS bookings, count(checkin_code)::int AS codes,
                count(DISTINCT checkin_code)::int AS unique_codes,
                count(*) FILTER (WHERE checkin_code !~ '^BK[0-9A-F]{6,16}$')::int AS invalid
           FROM public.bookings`,
      );
      assert.equal(counts.bookings, counts.codes);
      assert.equal(counts.codes, counts.unique_codes);
      assert.equal(counts.invalid, 0);
      const { rows: indexes } = await client.query(
        `SELECT 1 FROM pg_indexes WHERE schemaname='public'
          AND tablename='bookings' AND indexname='idx_bookings_checkin_code'`,
      );
      assert.equal(indexes.length, 1);
      console.log('Live booking codes verified:', counts);
      return;
    }

    await client.query(`CREATE TEMP TABLE booking_code_test (
      id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
      qr_code text DEFAULT gen_random_uuid()::text,
      status text DEFAULT 'confirmed'
    )`);
    await client.query('INSERT INTO booking_code_test SELECT FROM generate_series(1, 2)');
    const before = await client.query('SELECT id, qr_code, status FROM booking_code_test ORDER BY id');
    const sql = fs.readFileSync(path.join(__dirname,
      '../../migrations/20261021104357_booking_checkin_codes.sql'), 'utf8')
      .replaceAll('public.bookings', 'pg_temp.booking_code_test');
    await client.query(sql);
    const first = await client.query('SELECT * FROM booking_code_test ORDER BY id');
    assert.equal(new Set(first.rows.map(row => row.checkin_code)).size, 2);
    for (const row of first.rows) assert.match(row.checkin_code, /^BK[0-9A-F]{6}$/);
    assert.deepEqual(first.rows.map(({ id, qr_code, status }) => ({ id, qr_code, status })), before.rows);
    await client.query(sql);
    assert.deepEqual((await client.query('SELECT * FROM booking_code_test ORDER BY id')).rows, first.rows);
    const next = await client.query('INSERT INTO booking_code_test DEFAULT VALUES RETURNING checkin_code');
    assert.equal(next.rows[0].checkin_code, 'BK000003');
    await assert.rejects(client.query(`INSERT INTO booking_code_test (booking_number)
      OVERRIDING SYSTEM VALUE VALUES (1)`), { code: '23505' });
    // The code must grow, never truncate and collide, when the six-digit space fills.
    await client.query('ALTER TABLE booking_code_test ALTER COLUMN booking_number RESTART WITH 16777216');
    const large = await client.query('INSERT INTO booking_code_test DEFAULT VALUES RETURNING checkin_code');
    assert.equal(large.rows[0].checkin_code, 'BK1000000');
    console.log('PASS: existing rows, future rows, unique codes, stable reruns, unchanged QR tokens, and code growth.');
  } finally {
    client.release();
  }
}

main().catch(e => {
  console.error('Booking code verification failed:', e.code, e.message);
  process.exitCode = 1;
}).finally(() => pool.end());
