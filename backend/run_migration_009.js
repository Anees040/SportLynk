const { Pool } = require('pg');
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '../.env') });

const pool = new Pool({
  user: process.env.DB_USER || 'postgres',
  host: process.env.DB_HOST || 'localhost',
  database: process.env.DB_NAME || 'sportlynk',
  password: process.env.DB_PASSWORD || 'sportlynk123',
  port: process.env.DB_PORT || 5432,
});

async function run() {
  const sqlFile = path.join(__dirname, 'migrations', '009_no_show_job_and_admin.sql');
  const sql = fs.readFileSync(sqlFile, 'utf8');
  const client = await pool.connect();
  try {
    await client.query(sql);
    console.log('✅ Migration 009 applied successfully.');
    console.log('   - Added no_show_processed column to bookings');
    console.log('   - Admin account created: admin@sportlynk.com / Admin@123');
  } catch (e) {
    console.error('❌ Migration failed:', e.message);
  } finally {
    client.release();
    pool.end();
  }
}

run();
