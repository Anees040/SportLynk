/**
 * run_migration_030_slot_price_source.js — applies 030 (slots.price_source).
 *
 * Usage:  node src/scripts/run_migration_030_slot_price_source.js
 *
 * 030 is a single ALTER TABLE ... ADD COLUMN IF NOT EXISTS and nothing else, so this
 * runner applies it, confirms the column is present, then re-runs it to prove a
 * second application is a no-op. The migration is purely additive; it holds no DROP,
 * TRUNCATE or DELETE and rewrites no existing price, so a re-run cannot lose data.
 */
const path = require('path');
const fs = require('fs');
const pool = require('../db/pool');

const SQL_PATH = path.join(__dirname, '..', '..', 'migrations', '030_slot_price_source.sql');

async function hasColumn(table, column) {
  const { rows } = await pool.query(
    `SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2`,
    [table, column],
  );
  return rows.length === 1;
}

async function main() {
  const sql = fs.readFileSync(SQL_PATH, 'utf8');
  console.log('030 — slots.price_source (price provenance)\n');

  await pool.query(sql);
  if (!(await hasColumn('slots', 'price_source'))) {
    console.error('  ✗ slots.price_source not present after apply');
    process.exitCode = 1;
    return;
  }
  console.log('  ✓ present: column slots.price_source');

  await pool.query(sql);
  if (await hasColumn('slots', 'price_source')) {
    console.log('  ✓ re-run is a no-op — idempotent');
  } else {
    console.error('  ✗ column vanished on re-run');
    process.exitCode = 1;
  }
}

main()
  .then(async () => {
    await pool.end().catch(() => {});
  })
  .catch(async (e) => {
    console.error('  ✗ migration failed:', e.message);
    await pool.end().catch(() => {});
    process.exitCode = 1;
  });
