const pool = require('../db/pool');

async function run() {
  try {
    const res = await pool.query(`SELECT * FROM wallets WHERE user_id='42c213c1-0f9a-4ec7-a315-8779dd70ed3c'`);
    console.log(res.rows);
  } catch(e) {
    console.error(e);
  } finally {
    pool.end();
  }
}
run();
