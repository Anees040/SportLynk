/**
 * run_migration_040_admin_rbac.js — super admin + per-admin permissions.
 *
 * Usage:  node src/scripts/run_migration_040_admin_rbac.js
 *
 * Idempotent (ADD COLUMN IF NOT EXISTS): applies the migration, confirms the two new
 * columns on `users` are present, then proves a second run is a no-op.
 */
const path = require('path');
const fs = require('fs');
const pool = require('../db/pool');

const SQL_PATH = path.join(__dirname, '..', '..', 'migrations', '040_admin_rbac.sql');

async function hasColumn(table, column) {
  const { rows } = await pool.query(
    `SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2`,
    [table, column],
  );
  return rows.length === 1;
}

async function state() {
  return {
    is_super_admin: await hasColumn('users', 'is_super_admin'),
    admin_permissions: await hasColumn('users', 'admin_permissions'),
  };
}

async function main() {
  const sql = fs.readFileSync(SQL_PATH, 'utf8');
  console.log('040 — super admin + per-admin permissions\n');

  await pool.query(sql);
  const after = await state();
  const missing = Object.entries(after).filter(([, ok]) => !ok).map(([k]) => k);
  if (missing.length) {
    console.error(`  ✗ expected columns after apply, not found: ${missing.join(', ')}`);
    process.exitCode = 1;
    return;
  }
  console.log('  ✓ column present: users.is_super_admin');
  console.log('  ✓ column present: users.admin_permissions');

  await pool.query(sql);
  const again = await state();
  if (again.is_super_admin && again.admin_permissions) {
    console.log('\n  ✓ re-run is a no-op — idempotent (both columns stable)');
  } else {
    console.error('\n  ✗ second run changed the schema');
    process.exitCode = 1;
  }
}

main()
  .catch((err) => { console.error('Migration runner crashed:', err.message); process.exitCode = 1; })
  .finally(() => pool.end());
