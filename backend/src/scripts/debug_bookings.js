const pool = require('../db/pool');

async function run() {
  try {
    const res = await pool.query(`
      SELECT b.*, v.name as venue_name, s.start_time, s.end_time 
      FROM bookings b 
      JOIN venues v ON v.id = b.venue_id
      JOIN slots s ON s.id = b.slot_id
    `);
    console.log(res.rows);
  } catch(e) {
    console.error(e);
  } finally {
    pool.end();
  }
}
run();
