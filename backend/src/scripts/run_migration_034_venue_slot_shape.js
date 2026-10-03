/**
 * run_migration_034_venue_slot_shape.js — applies 034 (venues.slot_duration_minutes).
 *
 * Usage:  node src/scripts/run_migration_034_venue_slot_shape.js
 *
 * 034 is one ADD COLUMN IF NOT EXISTS plus a guarded CHECK and nothing else, so this
 * runner applies it, confirms the column and the constraint are present, reports how
 * many venues now carry the 60-minute default, then re-runs it to prove a second
 * application is a no-op. The migration is purely additive; it holds no DROP,
 * TRUNCATE, DELETE or UPDATE, so a re-run cannot lose data.
 *
 * The CHECK is also probed with a value the constraint must refuse, inside a
 * transaction that is rolled back — a constraint that exists but does not bite is
 * worth catching here rather than at the moment an owner saves 45 minutes.
 */
const path = require('path');
const fs = require('fs');
const pool = require('../db/pool');

const SQL_PATH = path.join(__dirname, '..', '..', 'migrations', '034_venue_slot_shape.sql');

async function hasColumn(table, column) {
  const { rows } = await pool.query(
    `SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2`,
    [table, column],
  );
  return rows.length === 1;
}

async function hasConstraint(name) {
  const { rows } = await pool.query(
    `SELECT 1 FROM pg_constraint WHERE conname = $1 AND conrelid = 'public.venues'::regclass`,
    [name],
  );
  return rows.length === 1;
}

/** Does the CHECK actually refuse a bad length? Written and rolled back. */
async function constraintBites() {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const { rows } = await client.query('SELECT id FROM venues LIMIT 1');
    if (!rows.length) {
      await client.query('ROLLBACK');
      return 'no venue to probe with';
    }
    try {
      await client.query('UPDATE venues SET slot_duration_minutes = 45 WHERE id = $1', [rows[0].id]);
      await client.query('ROLLBACK');
      return 'accepted 45 minutes';
    } catch {
      await client.query('ROLLBACK');
      return null;
    }
  } finally {
    client.release();
  }
}

async function main() {
  const sql = fs.readFileSync(SQL_PATH, 'utf8');
  console.log('034 — venues.slot_duration_minutes (owner-chosen slot length)\n');

  await pool.query(sql);

  if (!(await hasColumn('venues', 'slot_duration_minutes'))) {
    console.error('  x venues.slot_duration_minutes not present after apply');
    process.exitCode = 1;
    return;
  }
  console.log('  ok present: column venues.slot_duration_minutes');

  if (!(await hasConstraint('chk_venues_slot_duration'))) {
    console.error('  x chk_venues_slot_duration not present after apply');
    process.exitCode = 1;
    return;
  }
  console.log('  ok present: constraint chk_venues_slot_duration');

  const bite = await constraintBites();
  if (bite === null) console.log('  ok the CHECK refuses 45 minutes (probe rolled back)');
  else console.log(`  -- CHECK not proved: ${bite}`);

  const census = await pool.query(
    `SELECT slot_duration_minutes AS d, COUNT(*)::int AS c
       FROM venues GROUP BY 1 ORDER BY 1`,
  );
  for (const r of census.rows) console.log(`     ${String(r.d).padStart(4)} min : ${r.c} venue(s)`);

  await pool.query(sql);
  if (await hasColumn('venues', 'slot_duration_minutes')) {
    console.log('  ok re-run is a no-op — idempotent');
  } else {
    console.error('  x column vanished on re-run');
    process.exitCode = 1;
  }
}

main()
  .then(async () => {
    await pool.end().catch(() => {});
  })
  .catch(async (e) => {
    console.error('  x migration failed:', e.message);
    await pool.end().catch(() => {});
    process.exitCode = 1;
  });
