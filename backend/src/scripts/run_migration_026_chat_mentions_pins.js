/**
 * run_migration_026_chat_mentions_pins.js — add chat_messages.mentions,
 * pinned_at and pinned_by.
 *
 * Usage:  node src/scripts/run_migration_026_chat_mentions_pins.js
 *
 * Idempotent (ADD COLUMN IF NOT EXISTS): applies the migration, confirms all
 * three columns are present afterwards, and proves a second run is a no-op.
 */
const path = require('path');
const fs = require('fs');
const pool = require('../db/pool');

const SQL_PATH = path.join(__dirname, '..', '..', 'migrations', '026_chat_mentions_pins.sql');

async function columns() {
  const { rows } = await pool.query(
    `SELECT column_name FROM information_schema.columns
      WHERE table_name = 'chat_messages'
        AND column_name IN ('mentions','pinned_at','pinned_by')
      ORDER BY column_name`,
  );
  return rows.map((r) => r.column_name);
}

async function main() {
  const sql = fs.readFileSync(SQL_PATH, 'utf8');
  console.log('026 — chat mentions and pins\n');

  await pool.query(sql);
  const after = await columns();
  console.log(`Columns present: ${after.join(', ') || '(none)'}`);
  if (after.length !== 3) {
    console.error('  ✗ expected mentions, pinned_at and pinned_by to exist');
    process.exitCode = 1;
    return;
  }

  await pool.query(sql);
  const again = await columns();
  if (again.length === 3) {
    console.log('  ✓ re-run is a no-op — idempotent (all three columns stable)');
  } else {
    console.error('  ✗ second run changed the column set');
    process.exitCode = 1;
  }
}

main()
  .catch((err) => { console.error('Migration runner crashed:', err.message); process.exitCode = 1; })
  .finally(() => pool.end());
