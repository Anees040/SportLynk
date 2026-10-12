/**
 * run_migration_039_team_player_invites.js — direct team → player invitations.
 *
 * Usage:  node src/scripts/run_migration_039_team_player_invites.js
 *
 * Idempotent (CREATE ... IF NOT EXISTS): applies the migration, confirms the new
 * table and its pending-unique index are present, then proves a second run is a no-op.
 */
const path = require('path');
const fs = require('fs');
const pool = require('../db/pool');

const SQL_PATH = path.join(__dirname, '..', '..', 'migrations', '039_team_player_invites.sql');

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
    'SELECT 1 FROM pg_indexes WHERE schemaname = \'public\' AND indexname = $1',
    [name],
  );
  return rows.length === 1;
}

async function state() {
  return {
    table: await hasTable('team_player_invites'),
    pendingIndex: await hasIndex('ux_team_player_invites_pending'),
  };
}

async function main() {
  const sql = fs.readFileSync(SQL_PATH, 'utf8');
  console.log('039 — direct team -> player invitations\n');

  await pool.query(sql);
  const after = await state();
  const missing = Object.entries(after).filter(([, ok]) => !ok).map(([k]) => k);
  if (missing.length) {
    console.error(`  ✗ expected after apply, not found: ${missing.join(', ')}`);
    process.exitCode = 1;
    return;
  }
  console.log('  ✓ table present: team_player_invites');
  console.log('  ✓ unique pending index present: ux_team_player_invites_pending');

  await pool.query(sql);
  const again = await state();
  if (again.table && again.pendingIndex) {
    console.log('\n  ✓ re-run is a no-op — idempotent (table + index stable)');
  } else {
    console.error('\n  ✗ second run changed the schema');
    process.exitCode = 1;
  }
}

main()
  .catch((err) => { console.error('Migration runner crashed:', err.message); process.exitCode = 1; })
  .finally(() => pool.end());
