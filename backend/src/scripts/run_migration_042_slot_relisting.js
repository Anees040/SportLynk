/**
 * run_migration_042_slot_relisting.js — "just freed" re-listing marker on slots (item 8).
 *
 * Usage:  node src/scripts/run_migration_042_slot_relisting.js
 *
 * Idempotent (ADD COLUMN IF NOT EXISTS + CREATE INDEX IF NOT EXISTS): applies the
 * migration, confirms slots.relisted_at exists, then proves a second run is a no-op.
 *
 * Numbered 042 because 041 was taken by a concurrent session (041_multi_challenge).
 */
const path = require('path');
const fs = require('fs');
const pool = require('../db/pool');

const SQL_PATH = path.join(__dirname, '..', '..', 'migrations', '042_slot_relisting.sql');

async function hasColumn() {
  const { rows } = await pool.query(
    `SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'slots'
        AND column_name = 'relisted_at'`,
  );
  return rows.length > 0;
}

async function main() {
  const sql = fs.readFileSync(SQL_PATH, 'utf8');
  console.log('042 — slot re-listing marker\n');

  await pool.query(sql);
  if (!(await hasColumn())) {
    console.error('  ✗ expected slots.relisted_at to exist after the migration');
    process.exitCode = 1;
    return;
  }
  console.log('  ✓ slots.relisted_at present');

  await pool.query(sql);
  console.log('  ✓ re-run is a no-op — idempotent');
}

main()
  .catch((err) => { console.error('Migration runner crashed:', err.message); process.exitCode = 1; })
  .finally(() => pool.end());
