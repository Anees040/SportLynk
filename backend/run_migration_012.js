/**
 * Runner for migrations/012_hardening_indexes.sql
 * Usage: node run_migration_012.js
 */
const fs = require('fs');
const path = require('path');
const pool = require('./src/db/pool');

async function run() {
  const sqlFile = path.join(__dirname, 'migrations', '012_hardening_indexes.sql');
  const sql = fs.readFileSync(sqlFile, 'utf8');

  const client = await pool.connect();
  let failed = false;
  try {
    // Snapshot first, so the log can say what was actually created vs. already there.
    const before = await client.query(
      `SELECT indexname FROM pg_indexes
        WHERE schemaname = 'public'
          AND tablename IN ('bookings', 'transactions', 'slots')`,
    );
    const had = new Set(before.rows.map((r) => r.indexname));

    await client.query(sql);

    const after = await client.query(
      `SELECT indexname FROM pg_indexes
        WHERE schemaname = 'public'
          AND tablename IN ('bookings', 'transactions', 'slots')
        ORDER BY indexname`,
    );

    console.log('✅ Migration 012 applied:');
    for (const { indexname } of after.rows) {
      if (!had.has(indexname)) console.log(`   + created ${indexname}`);
    }
    for (const name of ['idx_bookings_venue_slot', 'idx_bookings_player_status',
                        'idx_txn_user', 'idx_slots_venue_date']) {
      if (had.has(name)) console.log(`   = ${name} already present, left alone`);
    }
  } catch (e) {
    failed = true;
    console.error('❌ Migration 012 failed:', e.message);
  } finally {
    client.release();
    await pool.end();
  }
  process.exit(failed ? 1 : 0);
}

run();
