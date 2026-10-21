// Database regression check using only temporary tables and a rolled-back
// transaction. No real venue, slot, booking, or pricing setting is changed.
const assert = require('node:assert/strict');
const pool = require('../db/pool');
const grid = require('../utils/slotGrid');
const slotService = require('../services/slotService');

const venueId = '11111111-1111-4111-8111-111111111111';
const otherId = '22222222-2222-4222-8222-222222222222';

async function main() {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query("SET LOCAL statement_timeout = '15s'");
    const { rows: columns } = await client.query(`
      SELECT table_name, column_name FROM information_schema.columns
       WHERE table_schema = 'public'
         AND ((table_name = 'venues' AND column_name IN ('ai_pricing_enabled', 'deposit_pct'))
           OR (table_name = 'slots' AND column_name = 'price_source'))`);
    assert.equal(columns.length, 3, 'Pricing migrations 030 and 043 must be present');
    console.log('PASS: required pricing columns exist');

    await client.query(`CREATE TEMP TABLE venues (
      id uuid PRIMARY KEY, price_per_hour numeric, base_price numeric,
      ai_pricing_enabled boolean
    ) ON COMMIT DROP`);
    await client.query(`CREATE TEMP TABLE slots (
      id text PRIMARY KEY, venue_id uuid, slot_date date,
      start_time time, end_time time, price numeric, price_source text,
      status text, locked_until timestamptz
    ) ON COMMIT DROP`);
    const { rows: [scope] } = await client.query(`SELECT
      'venues'::regclass = 'pg_temp.venues'::regclass AS venues,
      'slots'::regclass = 'pg_temp.slots'::regclass AS slots`);
    assert.ok(scope.venues && scope.slots, 'All writes must resolve to temporary tables');
    await client.query(`INSERT INTO venues VALUES ($1, 2000, 2000, false), ($2, 3000, 3000, true)`, [venueId, otherId]);
    const fixtures = [
      ['half', 1, '08:00', '08:30', 'model', 'available', false, venueId],
      ['hour', 1, '09:00', '10:00', 'heuristic', 'available', false, venueId],
      ['ninety', 1, '10:00', '11:30', 'model', 'available', false, venueId],
      ['two', 1, '12:00', '14:00', null, 'available', false, venueId],
      ['midnight', 1, '23:00', '24:00', 'model', 'available', false, venueId],
      ['owner', 1, '14:00', '15:00', 'owner', 'available', false, venueId],
      ['booked', 1, '15:00', '16:00', 'model', 'booked', false, venueId],
      ['blocked', 1, '16:00', '17:00', 'model', 'blocked', false, venueId],
      ['held', 1, '17:00', '18:00', 'model', 'available', true, venueId],
      ['past', -1, '18:00', '19:00', 'model', 'available', false, venueId],
      ['other', 1, '19:00', '20:00', 'model', 'available', false, otherId],
    ];
    for (const [id, day, start, end, source, status, held, venue] of fixtures) {
      await client.query(`INSERT INTO slots VALUES (
        $1, $2, (NOW() AT TIME ZONE 'Asia/Karachi')::date + $3::int,
        $4, $5, 9999, $6, $7,
        CASE WHEN $8::boolean THEN NOW() + INTERVAL '10 minutes' END
      )`, [id, venue, day, start, end, source, status, held]);
    }

    const restored = await slotService.returnSlotsToBasePrice(client, { venueId });
    assert.equal(restored.repriced, 5);
    const { rows } = await client.query('SELECT id, price, price_source FROM slots');
    const expected = { half: 1000, hour: 2000, ninety: 3000, two: 4000, midnight: 2000 };
    for (const row of rows) {
      assert.equal(Number(row.price), expected[row.id] ?? 9999, row.id);
      if (row.id in expected) assert.equal(row.price_source, null, row.id);
    }
    assert.equal((await slotService.returnSlotsToBasePrice(client, { venueId })).repriced, 0);
    console.log('PASS: fixed prices respect duration, overrides, bookings, holds, history, and venue scope');

    const stalePlan = [venueId, [8, 9, 10, 12, 23], [7777, 7777, 7777, 7777, 7777],
      ['model', 'model', 'model', 'model', 'model']];
    assert.equal((await client.query(grid.REPRICE_SQL, stalePlan)).rowCount, 0);
    console.log('PASS: an AI plan computed before switch-off cannot overwrite fixed prices');

    await client.query('UPDATE venues SET price_per_hour = 2800 WHERE id = $1', [venueId]);
    await slotService.returnSlotsToBasePrice(client, { venueId });
    const { rows: [hour] } = await client.query("SELECT price FROM slots WHERE id = 'hour'");
    assert.equal(Number(hour.price), 2800);
    await client.query("UPDATE slots SET locked_until = NULL WHERE id = 'held'");
    const swept = await slotService.repriceVenueSlots(client, {
      venueId, venue: { ai_pricing_enabled: false },
    });
    assert.equal(swept.repriced, 1);
    console.log('PASS: rate edits and released checkout holds pick up the owner rate');

    await client.query('UPDATE venues SET ai_pricing_enabled = true WHERE id = $1', [venueId]);
    assert.equal((await slotService.returnSlotsToBasePrice(client, { venueId })).repriced, 0);
    assert.equal((await client.query(grid.REPRICE_SQL, stalePlan)).rowCount, 5);
    console.log('PASS: enabling AI allows dynamic pricing again');

    const { rows: [wire] } = await client.query(`
      SELECT to_jsonb(v) -> 'ai_pricing_enabled' AS ai_pricing_enabled FROM venues v WHERE id=$1`, [venueId]);
    assert.equal(wire.ai_pricing_enabled, true);
    console.log('PASS: venue settings serialize as JSON booleans');
  } finally {
    await client.query('ROLLBACK');
    client.release();
  }
}

main().catch(e => {
  console.error('Venue pricing check failed:', e.code || '', e.message);
  process.exitCode = 1;
}).finally(() => pool.end());
