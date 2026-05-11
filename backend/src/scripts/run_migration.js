const fs = require('fs');
const path = require('path');
const pool = require('../db/pool');

async function run() {
  const sqlPath = path.join(__dirname, '../../migrations/006_ensure_wallets.sql');
  const sql = fs.readFileSync(sqlPath, 'utf8');
  try {
    console.log('Running migration...');
    await pool.query(sql);
    console.log('Migration completed successfully.');
  } catch (e) {
    console.error('Migration failed:', e);
  } finally {
    pool.end();
  }
}
run();
