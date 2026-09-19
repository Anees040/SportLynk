/**
 * run_migration_024_kb_variants.js — apply the Roman-Urdu / synonym KB variants.
 *
 * Usage:  node src/scripts/run_migration_024_kb_variants.js
 *
 * Idempotent (INSERT ... WHERE NOT EXISTS on the question text): applies the seed,
 * reports how many rows it added, and proves a second run adds nothing. The retrieval
 * proof for these rows is check_scout_coverage.js, which measures the Roman-Urdu and
 * synonym questions end to end through assistantKb.search().
 */
const path = require('path');
const fs = require('fs');
const pool = require('../db/pool');

const SQL_PATH = path.join(__dirname, '..', '..', 'migrations', '024_assistant_kb_variants.sql');

async function globalCount() {
  const { rows } = await pool.query(
    "SELECT count(*)::int AS n FROM assistant_kb WHERE scope = 'global' AND status = 'published'",
  );
  return rows[0].n;
}

async function main() {
  const sql = fs.readFileSync(SQL_PATH, 'utf8');
  console.log('024 — assistant KB variants (Roman Urdu / synonyms)\n');

  const before = await globalCount();
  const first = await pool.query(sql);
  const afterFirst = await globalCount();
  console.log(`Global rows: ${before} -> ${afterFirst}  (inserted ${first.rowCount || 0})`);

  const second = await pool.query(sql);
  const afterSecond = await globalCount();
  if ((second.rowCount || 0) === 0 && afterSecond === afterFirst) {
    console.log(`  ✓ re-run inserted 0 rows — idempotent (${afterSecond} rows stable)`);
  } else {
    console.error(`  ✗ not idempotent: re-run added ${second.rowCount}`);
    process.exitCode = 1;
  }
}

main()
  .catch((err) => { console.error('Migration runner crashed:', err.message); process.exitCode = 1; })
  .finally(() => pool.end());
