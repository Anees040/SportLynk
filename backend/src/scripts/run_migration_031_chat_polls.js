/**
 * run_migration_031_chat_polls.js — applies 031 (in-chat polls).
 *
 * Usage:  node src/scripts/run_migration_031_chat_polls.js
 *
 * 031 widens two CHECK constraints (DROP then ADD, idempotent) and creates two
 * tables and their indexes with IF NOT EXISTS, so a re-run is a no-op. It holds
 * no DROP TABLE, TRUNCATE or DELETE and rewrites no existing row.
 */
const path = require('path');
const fs = require('fs');
const pool = require('../db/pool');

const SQL_PATH = path.join(__dirname, '..', '..', 'migrations', '031_chat_polls.sql');

async function hasTable(name) {
  const { rows } = await pool.query(
    `SELECT 1 FROM information_schema.tables
      WHERE table_schema = 'public' AND table_name = $1`,
    [name],
  );
  return rows.length > 0;
}

async function kindAllowsPoll() {
  const { rows } = await pool.query(
    `SELECT pg_get_constraintdef(oid) AS def FROM pg_constraint
      WHERE conname = 'chk_chat_messages_kind'`,
  );
  return rows[0] && /'poll'/.test(rows[0].def);
}

async function main() {
  const sql = fs.readFileSync(SQL_PATH, 'utf8');
  console.log('Applying 031_chat_polls.sql …');
  await pool.query(sql);

  const polls = await hasTable('chat_polls');
  const votes = await hasTable('chat_poll_votes');
  const kind = await kindAllowsPoll();
  console.log(`  chat_polls present:       ${polls}`);
  console.log(`  chat_poll_votes present:  ${votes}`);
  console.log(`  kind constraint allows poll: ${kind}`);

  // Prove a second application is a clean no-op.
  console.log('Re-applying to confirm idempotency …');
  await pool.query(sql);
  console.log('  ok (no error on re-run)');

  if (polls && votes && kind) {
    console.log('\nRESULT: 031 applied — polls tables and the widened kind are present.');
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
