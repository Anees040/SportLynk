/**
 * run_migration_028_play_requests.js — direct play requests + 1:1 DM channels.
 *
 * Usage:  node src/scripts/run_migration_028_play_requests.js
 *
 * Idempotent (CREATE ... IF NOT EXISTS, plus a DROP/ADD on the widened CHECK):
 * applies the migration, confirms the two new tables and the widened channel-type
 * constraint are present, then proves a second run is a no-op.
 */
const path = require('path');
const fs = require('fs');
const pool = require('../db/pool');

const SQL_PATH = path.join(__dirname, '..', '..', 'migrations', '028_play_requests.sql');

async function hasTable(name) {
  const { rows } = await pool.query(
    `SELECT 1 FROM information_schema.tables
      WHERE table_schema = 'public' AND table_name = $1`,
    [name],
  );
  return rows.length === 1;
}

/** The channel-type CHECK admits 'direct' once widened. */
async function directTypeAllowed() {
  const { rows } = await pool.query(
    `SELECT pg_get_constraintdef(oid) AS def
       FROM pg_constraint WHERE conname = 'chk_chat_channels_type'`,
  );
  return rows.length === 1 && /'direct'/.test(rows[0].def);
}

async function state() {
  return {
    playRequests: await hasTable('play_requests'),
    directChannels: await hasTable('direct_channels'),
    directType: await directTypeAllowed(),
  };
}

async function main() {
  const sql = fs.readFileSync(SQL_PATH, 'utf8');
  console.log('028 — direct play requests + 1:1 DM channels\n');

  await pool.query(sql);
  const after = await state();
  const missing = Object.entries(after).filter(([, ok]) => !ok).map(([k]) => k);
  if (missing.length) {
    console.error(`  ✗ expected after apply, not found: ${missing.join(', ')}`);
    process.exitCode = 1;
    return;
  }
  console.log('  ✓ table present: play_requests');
  console.log('  ✓ table present: direct_channels');
  console.log("  ✓ chk_chat_channels_type admits 'direct'");

  await pool.query(sql);
  const again = await state();
  if (again.playRequests && again.directChannels && again.directType) {
    console.log('\n  ✓ re-run is a no-op — idempotent (tables + constraint stable)');
  } else {
    console.error('\n  ✗ second run changed the schema');
    process.exitCode = 1;
  }
}

main()
  .catch((err) => { console.error('Migration runner crashed:', err.message); process.exitCode = 1; })
  .finally(() => pool.end());
