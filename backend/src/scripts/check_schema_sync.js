/**
 * check_schema_sync.js — is the live Supabase schema in sync with migrations/?
 *
 * Usage:  node src/scripts/check_schema_sync.js
 *
 * Why this script exists
 * This project has migration FILES but no migration-tracking table and no runner that
 * records what was applied, so "are all migrations run?" cannot be answered by asking
 * the database what it remembers — it remembers nothing. The honest substitute is
 * structural: read every migrations/*.sql, extract the tables and columns it declares
 * (CREATE TABLE, ALTER TABLE ... ADD COLUMN), and check each against the live schema.
 *
 * It is strictly read-only — it only queries information_schema — so it is safe to run
 * against the production database at any time.
 *
 * A migration that only INSERTs data or only creates indexes/constraints declares no
 * table or column, so it shows as "no structural objects" and must be verified another
 * way (e.g. 023/024 by their KB row counts, reported at the end).
 */
const path = require('path');
const fs = require('fs');
const pool = require('../db/pool');

const MIGRATIONS_DIR = path.join(__dirname, '..', '..', 'migrations');

/** Strip SQL comments so prose inside them ("create the table here") is never parsed
 *  as a real object. Removes block comments first, then line comments. */
function stripComments(sql) {
  return sql.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/--[^\n]*/g, ' ');
}

/** Pull declared table names from CREATE TABLE [IF NOT EXISTS] [schema.]name. */
function createdTables(sql) {
  const out = new Set();
  const re = /create\s+table\s+(?:if\s+not\s+exists\s+)?(?:"?[a-z0-9_]+"?\.)?"?([a-z_][a-z0-9_]*)"?/gi;
  let m;
  while ((m = re.exec(sql))) out.add(m[1].toLowerCase());
  return [...out];
}

/**
 * Pull (table, column) pairs from ALTER TABLE statements.
 *
 * Parsed per statement — the text from each `ALTER TABLE t` up to the next `;` — and
 * every `ADD COLUMN` inside it is attributed to that table. This is what a single
 * naive regex gets wrong two ways: it pairs a table with a later ADD COLUMN that
 * belongs to a different statement, and it sees only the first column of a multi-column
 * `ADD COLUMN a, ADD COLUMN b` ALTER.
 */
function addedColumns(sql) {
  const out = [];
  const stmt = /alter\s+table\s+(?:if\s+exists\s+)?(?:"?[a-z0-9_]+"?\.)?"?([a-z_][a-z0-9_]*)"?([^;]*)/gi;
  let m;
  while ((m = stmt.exec(sql))) {
    const table = m[1].toLowerCase();
    const body = m[2];
    const col = /add\s+column\s+(?:if\s+not\s+exists\s+)?"?([a-z_][a-z0-9_]*)"?/gi;
    let c;
    while ((c = col.exec(body))) out.push([table, c[1].toLowerCase()]);
  }
  return out;
}

async function main() {
  // Live schema
  const { rows: tRows } = await pool.query(
    "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'",
  );
  const liveTables = new Set(tRows.map((r) => r.table_name.toLowerCase()));

  const { rows: cRows } = await pool.query(
    "SELECT table_name, column_name FROM information_schema.columns WHERE table_schema = 'public'",
  );
  const liveCols = new Set(cRows.map((r) => `${r.table_name.toLowerCase()}.${r.column_name.toLowerCase()}`));

  // Is there any migration-tracking table at all?
  const trackers = ['schema_migrations', 'migrations', 'pgmigrations', '_migrations', 'knex_migrations'];
  const tracker = trackers.find((t) => liveTables.has(t)) || null;

  const files = fs.readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort();
  let missing = 0;

  console.log('Schema sync — migrations/ vs live Supabase\n');
  console.log(`Live public tables: ${liveTables.size}`);
  console.log(`Migration tracking table: ${tracker || 'none (applied state is not recorded anywhere)'}\n`);

  for (const file of files) {
    const sql = stripComments(fs.readFileSync(path.join(MIGRATIONS_DIR, file), 'utf8'));
    const tables = createdTables(sql);
    const cols = addedColumns(sql);

    if (!tables.length && !cols.length) {
      console.log(`• ${file}: no CREATE TABLE / ADD COLUMN (data, index or constraint only) — verify separately`);
      continue;
    }

    const missTables = tables.filter((t) => !liveTables.has(t));
    // Only flag a missing column when its table exists; a missing table already covers it.
    const missCols = cols.filter(([t, c]) => liveTables.has(t) && !liveCols.has(`${t}.${c}`));

    if (!missTables.length && !missCols.length) {
      console.log(`✓ ${file}: all ${tables.length} table(s)`
        + `${cols.length ? ` + ${cols.length} column(s)` : ''} present`);
    } else {
      missing += 1;
      console.log(`✗ ${file}: MISSING`);
      if (missTables.length) console.log(`    tables:  ${missTables.join(', ')}`);
      if (missCols.length) console.log(`    columns: ${missCols.map(([t, c]) => `${t}.${c}`).join(', ')}`);
    }
  }

  // Data-only migrations verified by their effect
  const { rows: kb } = await pool.query(
    "SELECT count(*)::int n FROM assistant_kb WHERE scope = 'global' AND status = 'published'",
  );
  console.log(`\nData check — 023/024 assistant KB global rows: ${kb[0].n} (expected 69)`);

  console.log('');
  if (missing) {
    console.log(`RESULT: ${missing} migration(s) have objects NOT present in Supabase — see above.`);
    process.exitCode = 1;
  } else {
    console.log('RESULT: every table and column declared in migrations/ exists in Supabase.');
  }
}

main()
  .catch((err) => { console.error('Schema check crashed:', err.message); process.exitCode = 1; })
  .finally(() => pool.end());
