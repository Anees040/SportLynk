const { Pool } = require('pg');
require('dotenv').config({ path: './.env' });
const pool = new Pool({
  user: process.env.DB_USER || 'postgres',
  host: process.env.DB_HOST || 'localhost',
  database: process.env.DB_NAME || 'sportlynk',
  password: process.env.DB_PASSWORD || 'sportlynk123',
  port: parseInt(process.env.DB_PORT || '5432'),
});

pool.query("SELECT column_name FROM information_schema.columns WHERE table_name='owner_profiles'")
  .then(r => {
    console.log('owner_profiles:', r.rows.map(x => x.column_name).join(', '));
    pool.end();
  })
  .catch(e => { console.error(e.message); pool.end(); });


