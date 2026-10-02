/**
 * run_migration_033_chat_message_hides.js — applies 033 ("Delete for me").
 *
 * Usage:  node src/scripts/run_migration_033_chat_message_hides.js
 *
 * 033 is CREATE TABLE / CREATE INDEX ... IF NOT EXISTS only, so this runner
 * applies it, confirms the table and index exist, then re-runs it to prove a
 * second application is a no-op. It holds no DROP, TRUNCATE or DELETE.
 */
const path = require('path');
const fs = require('fs');
const pool = require('../db/pool');

const SQL_PATH = path.join(__dirname, '..', '..', 'migrations', '033_chat_message_hides.sql');

async function hasTable(name) {
  const { rows } = await pool.query(
    `SELECT 1 FROM information_schema.tables
      WHERE table_schema = 'public' AND table_name = $1`,
    [name],
  );
  return rows.length > 0;
}

async function hasIndex(name) {
  const { rows } = await pool.query(
    "SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND indexname = $1",
    [name],
  );
  return rows.length > 0;
}

async function main() {
  const sql = fs.readFileSync(SQL_PATH, 'utf8');
  console.log('Applying 033_chat_message_hides.sql …');
  await pool.query(sql);

  const table = await hasTable('chat_message_hides');
  const index = await hasIndex('idx_chat_message_hides_user');
  console.log(`  chat_message_hides present:        ${table}`);
  console.log(`  idx_chat_message_hides_user present: ${index}`);

  console.log('Re-applying to confirm idempotency …');
  await pool.query(sql);
  console.log('  ok (no error on re-run)');

  if (table && index) {
    console.log('\nRESULT: 033 applied — per-reader message hides are available.');
  } else {
    console.log('\nRESULT: something is missing; see the flags above.');
    process.exitCode = 1;
  }
  await pool.end();
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
