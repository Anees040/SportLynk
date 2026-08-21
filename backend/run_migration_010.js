/**
 * Runner for migrations/010_escrow_policy_alignment.sql
 * Usage: node run_migration_010.js
 *
 * The migration file is split on `-- @@SPLIT@@`; each chunk is sent as its own
 * command because PostgreSQL refuses `ALTER TYPE ... ADD VALUE` inside a
 * multi-command string.
 */
const fs = require('fs');
const path = require('path');
const pool = require('./src/db/pool');

async function run() {
  const sqlFile = path.join(__dirname, 'migrations', '010_escrow_policy_alignment.sql');
  const chunks = fs
    .readFileSync(sqlFile, 'utf8')
    .split('-- @@SPLIT@@')
    .map((c) => c.trim())
    .filter((c) => c.length > 0);

  const client = await pool.connect();
  let failed = false;
  try {
    for (let i = 0; i < chunks.length; i++) {
      try {
        await client.query(chunks[i]);
        console.log(`✅ chunk ${i + 1}/${chunks.length} applied`);
      } catch (e) {
        // Enum values that already exist are fine; anything else is a real failure.
        if (/already exists|duplicate/i.test(e.message)) {
          console.log(`↷  chunk ${i + 1}/${chunks.length} skipped — ${e.message}`);
        } else {
          failed = true;
          console.error(`❌ chunk ${i + 1}/${chunks.length} failed:`, e.message);
        }
      }
    }
    if (!failed) {
      console.log('');
      console.log('Migration 010 applied:');
      console.log('   - booking_status enum + "rejected"');
      console.log('   - bookings.deposit_amount (20% of price, backfilled)');
      console.log('   - bookings.approved_at / auto_decided_at');
      console.log('   - venues.upfront_percent normalised to 20');
      console.log('   - notifications table + job sweep indexes');
    }
  } finally {
    client.release();
    await pool.end();
  }
  process.exit(failed ? 1 : 0);
}

run();
