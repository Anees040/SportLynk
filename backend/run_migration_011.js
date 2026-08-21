/**
 * Runner for migrations/011_slot_locks.sql
 * Usage: node run_migration_011.js
 */
const fs = require('fs');
const path = require('path');
const pool = require('./src/db/pool');

async function run() {
  const sqlFile = path.join(__dirname, 'migrations', '011_slot_locks.sql');
  const sql = fs.readFileSync(sqlFile, 'utf8');

  const client = await pool.connect();
  let failed = false;
  try {
    await client.query(sql);
    console.log('✅ Migration 011 applied:');
    console.log('   - slots.locked_until (timestamptz) + slots.locked_by (uuid)');
    console.log("   - legacy 'temporarily_locked' slots released to 'available'");
    console.log('   - partial index idx_slots_locked_until');
  } catch (e) {
    failed = true;
    console.error('❌ Migration 011 failed:', e.message);
  } finally {
    client.release();
    await pool.end();
  }
  process.exit(failed ? 1 : 0);
}

run();
