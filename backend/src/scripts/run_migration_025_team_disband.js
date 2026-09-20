/**
 * run_migration_025_team_disband.js — add teams.disbanded_at / disbanded_by.
 *
 * Usage:  node src/scripts/run_migration_025_team_disband.js
 *
 * Idempotent (ADD COLUMN IF NOT EXISTS): applies the migration, confirms both
 * columns are present afterwards, and proves a second run is a no-op.
 */
const path = require('path');
const fs = require('fs');
const pool = require('../db/pool');

const SQL_PATH = path.join(__dirname, '..', '..', 'migrations', '025_team_disband.sql');

async function columns() {
  const { rows } = await pool.query(
    `SELECT column_name FROM information_schema.columns
      WHERE table_name = 'teams' AND column_name IN ('disbanded_at','disbanded_by')
      ORDER BY column_name`,
  );
  return rows.map((r) => r.column_name);
}

async function main() {
  const sql = fs.readFileSync(SQL_PATH, 'utf8');
  console.log('025 — team disband columns\n');

  await pool.query(sql);
  const after = await columns();
  console.log(`Columns present: ${after.join(', ') || '(none)'}`);
  if (after.length !== 2) {
    console.error('  ✗ expected disbanded_at and disbanded_by to exist');
    process.exitCode = 1;
    return;
  }

  await pool.query(sql);
  const again = await columns();
  if (again.length === 2) {
    console.log('  ✓ re-run is a no-op — idempotent (both columns stable)');
  } else {
    console.error('  ✗ second run changed the column set');
    process.exitCode = 1;
  }
}

main()
  .catch((err) => { console.error('Migration runner crashed:', err.message); process.exitCode = 1; })
  .finally(() => pool.end());
