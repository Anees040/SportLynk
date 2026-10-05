/**
 * run_migration_036_chat_history_window.js — applies 036 (per-member history
 * window).
 *
 * Usage:  node src/scripts/run_migration_036_chat_history_window.js
 *
 * 036 is a single ADD COLUMN IF NOT EXISTS plus a COMMENT, so this runner
 * applies it, confirms the column exists and that every pre-existing membership
 * kept a NULL (the "full history" value), then re-runs it to prove a second
 * application is a no-op. It holds no DROP, TRUNCATE or DELETE and rewrites no
 * row.
 */
const path = require('path');
const fs = require('fs');
const pool = require('../db/pool');

const SQL_PATH = path.join(__dirname, '..', '..', 'migrations', '036_chat_history_window.sql');

async function hasColumn(table, column) {
  const { rows } = await pool.query(
    `SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2`,
    [table, column],
  );
  return rows.length > 0;
}

async function main() {
  const sql = fs.readFileSync(SQL_PATH, 'utf8');

  // Counted BEFORE the column exists, so the post-check below can prove the
  // migration left every existing membership on the grandfathered NULL.
  const before = Number((await pool.query(
    'SELECT count(*) AS n FROM chat_channel_members',
  )).rows[0].n);

  console.log('Applying 036_chat_history_window.sql …');
  await pool.query(sql);

  const column = await hasColumn('chat_channel_members', 'history_from');
  console.log(`  chat_channel_members.history_from present: ${column}`);

  const nulls = column
    ? Number((await pool.query(
      'SELECT count(*) AS n FROM chat_channel_members WHERE history_from IS NULL',
    )).rows[0].n)
    : -1;
  console.log(`  memberships before:                        ${before}`);
  console.log(`  memberships with no lower bound (NULL):    ${nulls}`);

  console.log('Re-applying to confirm idempotency …');
  await pool.query(sql);
  console.log('  ok (no error on re-run)');

  // A membership that came out of this migration with a non-NULL bound would be
  // one whose history just disappeared, so it is a failure and not a warning.
  if (column && nulls >= before) {
    console.log('\nRESULT: 036 applied — new members start their history at the join, '
      + 'and every existing member kept all of theirs.');
  } else {
    console.log('\nRESULT: something is wrong; see the flags above.');
    process.exitCode = 1;
  }
  await pool.end();
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
