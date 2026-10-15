/**
 * run_migration_043_venue_pricing.js — applies 043 (venues.ai_pricing_enabled,
 * venues.deposit_pct).
 *
 * Usage:  node src/scripts/run_migration_043_venue_pricing.js
 *
 * 043 is additive: two columns with safe defaults (true / NULL) and one CHECK. It
 * holds no DROP of data, no TRUNCATE and no unfiltered UPDATE or DELETE, so this
 * runner applies it, censuses what should now exist, and re-runs it to prove a
 * second application is a no-op.
 *
 * The census asserts three facts rather than one, because each is independently
 * load-bearing:
 *   - `ai_pricing_enabled` must default true, or every venue repriced so far would
 *     flip to owner-priced the moment the column arrived;
 *   - `deposit_pct` must start NULL on every row, because NULL is what means
 *     "inherit the platform setting" — a row written with a concrete number by this
 *     migration would silently freeze today's global value as a per-venue override;
 *   - the CHECK must exist, so an out-of-range percentage is refused by the database
 *     and not only by the route.
 */
const path = require('path');
const fs = require('fs');
const pool = require('../db/pool');

const SQL_PATH = path.join(__dirname, '..', '..', 'migrations', '043_venue_pricing_and_deposit.sql');

async function main() {
  const sql = fs.readFileSync(SQL_PATH, 'utf8');
  console.log('043 — venues.ai_pricing_enabled, venues.deposit_pct\n');

  await pool.query(sql);
  const fail = async (msg) => {
    console.error(`  ✗ ${msg}`);
    await pool.end().catch(() => {});
    process.exitCode = 1;
  };

  const { rows: cols } = await pool.query(
    `SELECT column_name, is_nullable, column_default
       FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'venues'
        AND column_name IN ('ai_pricing_enabled', 'deposit_pct')`,
  );
  const byName = new Map(cols.map((c) => [c.column_name, c]));

  const ai = byName.get('ai_pricing_enabled');
  if (!ai) return fail('venues.ai_pricing_enabled not present after apply');
  if (ai.is_nullable !== 'NO' || !/true/i.test(ai.column_default || '')) {
    return fail(`ai_pricing_enabled defaults to ${ai.column_default} (nullable=${ai.is_nullable}); expected NOT NULL DEFAULT true`);
  }
  console.log('  ✓ present: venues.ai_pricing_enabled (NOT NULL DEFAULT true)');

  const dep = byName.get('deposit_pct');
  if (!dep) return fail('venues.deposit_pct not present after apply');
  if (dep.is_nullable !== 'YES') {
    return fail(`deposit_pct is NOT NULL; it has to be nullable for "inherit the platform setting" to exist`);
  }
  console.log('  ✓ present: venues.deposit_pct (nullable — NULL inherits the platform setting)');

  const { rows: overridden } = await pool.query(
    'SELECT COUNT(*)::int AS n FROM venues WHERE deposit_pct IS NOT NULL',
  );
  if (overridden[0].n > 0) {
    return fail(`${overridden[0].n} venue(s) already carry a deposit_pct; this migration must not have written one`);
  }
  console.log('  ✓ no venue carries a deposit_pct yet — every one inherits');

  const { rows: cons } = await pool.query(
    `SELECT 1 FROM pg_constraint WHERE conname = 'chk_venues_deposit_pct'`,
  );
  if (!cons.length) return fail('chk_venues_deposit_pct not present after apply');
  console.log('  ✓ present: constraint chk_venues_deposit_pct');

  await pool.query(sql);
  const { rows: again } = await pool.query(
    `SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'venues'
        AND column_name IN ('ai_pricing_enabled', 'deposit_pct')`,
  );
  if (again.length !== 2) return fail('a column vanished on re-run');
  console.log('  ✓ re-run is a no-op — idempotent');

  await pool.end().catch(() => {});
}

main().catch(async (e) => {
  console.error('  ✗ migration failed:', e.message);
  await pool.end().catch(() => {});
  process.exitCode = 1;
});
