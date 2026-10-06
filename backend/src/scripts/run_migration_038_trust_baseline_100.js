/**
 * run_migration_038_trust_baseline_100.js — Trust Score 2.0 baseline → 100.
 *
 * Usage:  node src/scripts/run_migration_038_trust_baseline_100.js
 *
 * Idempotent (ALTER COLUMN SET DEFAULT): applies the migration, confirms the new
 * default on player_profiles.trust_score, then proves a second run is a no-op.
 *
 * Does NOT touch existing rows — only the column default new inserts take. Existing
 * zero-signal users move to 100 on their next recomputeTrust, because NEUTRAL_PRIOR
 * in utils/trustScore.js is now 1.0.
 */
const path = require('path');
const fs = require('fs');
const pool = require('../db/pool');

const SQL_PATH = path.join(__dirname, '..', '..', 'migrations', '038_trust_baseline_100.sql');

async function trustDefault() {
  const { rows } = await pool.query(
    `SELECT column_default
       FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'player_profiles'
        AND column_name = 'trust_score'`,
  );
  return rows[0] ? rows[0].column_default : null;
}

async function main() {
  const sql = fs.readFileSync(SQL_PATH, 'utf8');
  console.log('038 — Trust Score 2.0 baseline → 100\n');

  await pool.query(sql);
  const after = await trustDefault();
  // column_default reads back like "100" (a bare integer literal).
  if (after === null || !/\b100\b/.test(String(after))) {
    console.error('  ✗ expected player_profiles.trust_score DEFAULT 100, got', after);
    process.exitCode = 1;
    return;
  }
  console.log('  ✓ player_profiles.trust_score DEFAULT is now 100');

  await pool.query(sql);
  const again = await trustDefault();
  if (again !== null && /\b100\b/.test(String(again))) {
    console.log('\n  ✓ re-run is a no-op — idempotent (default stable)');
  } else {
    console.error('\n  ✗ second run changed the default');
    process.exitCode = 1;
  }
}

main()
  .catch((err) => { console.error('Migration runner crashed:', err.message); process.exitCode = 1; })
  .finally(() => pool.end());
