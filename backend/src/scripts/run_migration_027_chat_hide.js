/**
 * run_migration_027_chat_hide.js — add chat_channel_members.hidden_at.
 *
 * Usage:  node src/scripts/run_migration_027_chat_hide.js
 *
 * Idempotent (ADD COLUMN IF NOT EXISTS): applies the migration, confirms the
 * column is present afterwards, and proves a second run is a no-op.
 */
const path = require('path');
const fs = require('fs');
const pool = require('../db/pool');

const SQL_PATH = path.join(__dirname, '..', '..', 'migrations', '027_chat_hide.sql');

async function hasHiddenAt() {
  const { rows } = await pool.query(
    `SELECT column_name FROM information_schema.columns
      WHERE table_name = 'chat_channel_members' AND column_name = 'hidden_at'`,
  );
  return rows.length === 1;
}

async function main() {
  const sql = fs.readFileSync(SQL_PATH, 'utf8');
  console.log('027 — per-member chat hide\n');

  await pool.query(sql);
  if (!(await hasHiddenAt())) {
    console.error('  ✗ expected chat_channel_members.hidden_at to exist');
    process.exitCode = 1;
    return;
  }
  console.log('Column present: chat_channel_members.hidden_at');

  await pool.query(sql);
  if (await hasHiddenAt()) {
    console.log('  ✓ re-run is a no-op — idempotent (hidden_at stable)');
  } else {
    console.error('  ✗ second run changed the column set');
    process.exitCode = 1;
  }
}

main()
  .catch((err) => { console.error('Migration runner crashed:', err.message); process.exitCode = 1; })
  .finally(() => pool.end());
