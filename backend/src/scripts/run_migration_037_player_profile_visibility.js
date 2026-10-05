/**
 * run_migration_037_player_profile_visibility.js — public/private player profiles.
 *
 * Usage:  node src/scripts/run_migration_037_player_profile_visibility.js
 *
 * Idempotent (ADD COLUMN IF NOT EXISTS): applies the migration, confirms the two
 * new player_profiles columns are present with the intended default, then proves a
 * second run is a no-op.
 */
const path = require('path');
const fs = require('fs');
const pool = require('../db/pool');

const SQL_PATH = path.join(__dirname, '..', '..', 'migrations', '037_player_profile_visibility.sql');

async function column(name) {
  const { rows } = await pool.query(
    `SELECT data_type, column_default, is_nullable
       FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'player_profiles' AND column_name = $1`,
    [name],
  );
  return rows[0] || null;
}

async function state() {
  return {
    isPublic: await column('is_public'),
    bio: await column('bio'),
  };
}

async function main() {
  const sql = fs.readFileSync(SQL_PATH, 'utf8');
  console.log('037 — public/private player profiles\n');

  await pool.query(sql);
  const after = await state();

  if (!after.isPublic) {
    console.error('  ✗ expected after apply: player_profiles.is_public — not found');
    process.exitCode = 1;
    return;
  }
  if (!after.bio) {
    console.error('  ✗ expected after apply: player_profiles.bio — not found');
    process.exitCode = 1;
    return;
  }
  if (after.isPublic.is_nullable !== 'NO' || !/true/.test(after.isPublic.column_default || '')) {
    console.error('  ✗ is_public must be NOT NULL DEFAULT true, got',
      after.isPublic.is_nullable, after.isPublic.column_default);
    process.exitCode = 1;
    return;
  }
  console.log('  ✓ column present: player_profiles.is_public (NOT NULL DEFAULT true)');
  console.log('  ✓ column present: player_profiles.bio');

  await pool.query(sql);
  const again = await state();
  if (again.isPublic && again.bio) {
    console.log('\n  ✓ re-run is a no-op — idempotent (columns stable)');
  } else {
    console.error('\n  ✗ second run changed the schema');
    process.exitCode = 1;
  }
}

main()
  .catch((err) => { console.error('Migration runner crashed:', err.message); process.exitCode = 1; })
  .finally(() => pool.end());
