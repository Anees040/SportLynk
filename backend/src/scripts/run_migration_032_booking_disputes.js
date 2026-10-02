/**
 * run_migration_032_booking_disputes.js — applies 032 (the booking_disputes table).
 *
 * Usage:  node src/scripts/run_migration_032_booking_disputes.js
 *
 * 032 is CREATE TABLE / CREATE INDEX ... IF NOT EXISTS and nothing else, so this runner
 * applies it, confirms the table and its four indexes are present, then re-runs it to
 * prove a second application is a no-op. The migration is purely additive; it holds no
 * DROP, TRUNCATE or DELETE, so a re-run cannot lose data.
 */
const path = require('path');
const fs = require('fs');
const pool = require('../db/pool');

const SQL_PATH = path.join(__dirname, '..', '..', 'migrations', '032_booking_disputes.sql');

async function hasTable(name) {
  const { rows } = await pool.query(
    `SELECT 1 FROM information_schema.tables
      WHERE table_schema = 'public' AND table_name = $1`,
    [name],
  );
  return rows.length === 1;
}

async function hasIndex(name) {
  const { rows } = await pool.query(
    "SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND indexname = $1",
    [name],
  );
  return rows.length === 1;
}

async function state() {
  return {
    'table booking_disputes': await hasTable('booking_disputes'),
    'index ux_booking_disputes_open': await hasIndex('ux_booking_disputes_open'),
    'index idx_booking_disputes_status': await hasIndex('idx_booking_disputes_status'),
    'index idx_booking_disputes_raised_by': await hasIndex('idx_booking_disputes_raised_by'),
    'index idx_booking_disputes_booking': await hasIndex('idx_booking_disputes_booking'),
  };
}

async function main() {
  const sql = fs.readFileSync(SQL_PATH, 'utf8');
  console.log('032 — player booking disputes + refund path\n');

  await pool.query(sql);
  const after = await state();
  const missing = Object.entries(after).filter(([, ok]) => !ok).map(([k]) => k);
  if (missing.length) {
    console.error(`  ✗ not present after apply: ${missing.join(', ')}`);
    process.exitCode = 1;
    return;
  }
  for (const k of Object.keys(after)) console.log(`  ✓ present: ${k}`);

  await pool.query(sql);
  const again = await state();
  if (Object.values(again).every(Boolean)) {
    console.log('\n  ✓ re-run is a no-op — idempotent');
  } else {
    console.error('\n  ✗ second run changed the schema');
    process.exitCode = 1;
  }
}

main()
  .catch((err) => { console.error('Migration runner crashed:', err.message); process.exitCode = 1; })
  .finally(() => pool.end());
