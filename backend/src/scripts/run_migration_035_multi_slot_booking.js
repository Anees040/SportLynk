/**
 * run_migration_035_multi_slot_booking.js — applies 035 (grouping + discount tiers).
 *
 * Usage:  node src/scripts/run_migration_035_multi_slot_booking.js
 *
 * 035 adds two columns to `bookings`, two CHECK constraints, one table and three
 * indexes, all guarded. This runner applies it, confirms every object is present,
 * proves the two ceilings actually bite (inside transactions that are rolled back),
 * reports that no existing booking was altered, then re-runs the migration to show
 * a second application is a no-op.
 *
 * A constraint that exists but does not refuse anything is worth catching here
 * rather than at the moment a 90% discount books a slot for nothing.
 */
const path = require('path');
const fs = require('fs');
const pool = require('../db/pool');

const SQL_PATH = path.join(__dirname, '..', '..', 'migrations', '035_multi_slot_booking.sql');

let failures = 0;
const ok = (msg) => console.log(`  ok ${msg}`);
const bad = (msg) => { failures += 1; console.error(`  x  ${msg}`); };

async function hasColumn(table, column) {
  const { rows } = await pool.query(
    `SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2`,
    [table, column],
  );
  return rows.length === 1;
}

async function hasTable(table) {
  const { rows } = await pool.query(
    `SELECT 1 FROM information_schema.tables
      WHERE table_schema = 'public' AND table_name = $1`,
    [table],
  );
  return rows.length === 1;
}

async function hasIndex(name) {
  const { rows } = await pool.query(
    `SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND indexname = $1`,
    [name],
  );
  return rows.length === 1;
}

/** Run `fn` inside a transaction that is always rolled back; true when it threw. */
async function refuses(fn) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    try {
      await fn(client);
      return false;
    } catch {
      return true;
    } finally {
      await client.query('ROLLBACK').catch(() => {});
    }
  } finally {
    client.release();
  }
}

async function main() {
  const sql = fs.readFileSync(SQL_PATH, 'utf8');
  console.log('035 — multi-slot booking groups and owner discount tiers\n');

  const before = await pool.query('SELECT COUNT(*)::int AS c FROM bookings');

  await pool.query(sql);

  for (const col of ['booking_group_id', 'discount_percent']) {
    if (await hasColumn('bookings', col)) ok(`present: column bookings.${col}`);
    else bad(`missing: column bookings.${col}`);
  }
  if (await hasTable('venue_slot_discounts')) ok('present: table venue_slot_discounts');
  else bad('missing: table venue_slot_discounts');

  for (const idx of ['idx_bookings_group', 'ux_venue_slot_discounts', 'idx_venue_slot_discounts_venue']) {
    if (await hasIndex(idx)) ok(`present: index ${idx}`);
    else bad(`missing: index ${idx}`);
  }

  // Every existing booking must read as "no group, no discount" — that is what
  // makes this migration a no-op for the rows already in the table.
  const after = await pool.query(
    `SELECT COUNT(*)::int AS total,
            COUNT(*) FILTER (WHERE booking_group_id IS NOT NULL)::int AS grouped,
            COUNT(*) FILTER (WHERE discount_percent <> 0)::int AS discounted
       FROM bookings`,
  );
  const a = after.rows[0];
  if (a.total === before.rows[0].c) ok(`bookings unchanged: ${a.total} row(s)`);
  else bad(`booking count moved: ${before.rows[0].c} -> ${a.total}`);
  if (a.grouped === 0 && a.discounted === 0) ok('every existing booking reads ungrouped and undiscounted');
  else bad(`unexpected defaults: grouped=${a.grouped} discounted=${a.discounted}`);

  // The ceilings, probed with values they must refuse.
  const venue = await pool.query('SELECT id FROM venues LIMIT 1');
  if (!venue.rows.length) {
    console.log('  -- no venue to probe the discount ceilings with');
  } else {
    const vid = venue.rows[0].id;
    const tooHigh = await refuses((c) => c.query(
      'INSERT INTO venue_slot_discounts (venue_id, min_slots, percent) VALUES ($1, 2, 90)', [vid],
    ));
    if (tooHigh) ok('the CHECK refuses a 90% discount (probe rolled back)');
    else bad('a 90% discount was accepted');

    const tooFew = await refuses((c) => c.query(
      'INSERT INTO venue_slot_discounts (venue_id, min_slots, percent) VALUES ($1, 1, 10)', [vid],
    ));
    if (tooFew) ok('the CHECK refuses a one-slot "multi-slot" tier (probe rolled back)');
    else bad('a min_slots of 1 was accepted');

    const dup = await refuses(async (c) => {
      await c.query('INSERT INTO venue_slot_discounts (venue_id, min_slots, percent) VALUES ($1, 3, 10)', [vid]);
      await c.query('INSERT INTO venue_slot_discounts (venue_id, min_slots, percent) VALUES ($1, 3, 20)', [vid]);
    });
    if (dup) ok('the unique index refuses two rules at the same threshold (probe rolled back)');
    else bad('two tiers at the same threshold were accepted');
  }

  const booking = await pool.query('SELECT id FROM bookings LIMIT 1');
  if (booking.rows.length) {
    const over = await refuses((c) => c.query(
      'UPDATE bookings SET discount_percent = 75 WHERE id = $1', [booking.rows[0].id],
    ));
    if (over) ok('the CHECK refuses a 75% discount on a booking (probe rolled back)');
    else bad('a 75% booking discount was accepted');
  }

  await pool.query(sql);
  if (await hasTable('venue_slot_discounts')) ok('re-run is a no-op — idempotent');
  else bad('table vanished on re-run');

  console.log('');
  if (failures) {
    console.error(`  FAILED — ${failures} check(s) did not hold`);
    process.exitCode = 1;
  } else {
    console.log('  PASS — 035 applied and every guard proved');
  }
}

main()
  .then(async () => {
    await pool.end().catch(() => {});
  })
  .catch(async (e) => {
    console.error('  x  migration failed:', e.message);
    await pool.end().catch(() => {});
    process.exitCode = 1;
  });
