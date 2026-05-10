const fs = require('fs');
const path = require('path');
const pool = require('./src/db/pool');

async function runMigration() {
  try {
    const sqlPath = path.join(__dirname, 'migrations', '001_fix_schema.sql');
    const sql = fs.readFileSync(sqlPath, 'utf8');
    await pool.query(sql);
    console.log('Migration successful');
    process.exit(0);
  } catch (e) {
    console.error('Migration failed:', e);
    process.exit(1);
  }
}
runMigration();
