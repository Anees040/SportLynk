/**
 * run_migration_029_password_reset_codes.js — applies 029 (server-owned OTP table).
 *
 * Usage:  node src/scripts/run_migration_029_password_reset_codes.js
 *
 * 029 is CREATE TABLE / CREATE INDEX ... IF NOT EXISTS and nothing else, so this runner
 * applies it, confirms the table and its two indexes are present, then re-runs it to
 * prove a second application is a no-op. The migration is purely additive; it holds no
 * DROP, TRUNCATE or DELETE, so a re-run cannot lose data.
 */
const path = require('path');
const fs = require('fs');
const pool = require('../db/pool');

const SQL_PATH = path.join(__dirname, '..', '..', 'migrations', '029_password_reset_codes.sql');

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
    'table password_reset_codes': await hasTable('password_reset_codes'),
    'index idx_password_reset_codes_phone': await hasIndex('idx_password_reset_codes_phone'),
    'index idx_password_reset_codes_user': await hasIndex('idx_password_reset_codes_user'),
  };
}

async function main() {
  const sql = fs.readFileSync(SQL_PATH, 'utf8');
  console.log('029 — server-owned OTP for password reset\n');

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
