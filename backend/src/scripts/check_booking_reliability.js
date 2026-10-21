// Read-only PostgreSQL verification. No users, bookings, scores or schema are changed.
// Run: node src/scripts/check_booking_reliability.js
const assert = require('node:assert/strict');
const { recomputeTrust, calculateTrust } = require('../utils/trustScore');

async function main() {
  let aggregateSql;
  const userId = '00000000-0000-4000-8000-000000000000';
  // Capture the production aggregate without executing its lock or persistence.
  await recomputeTrust({ async query(sql) {
    if (sql.includes('WITH my_teams')) aggregateSql = sql;
    return { rows: [{}] };
  } }, userId);

  const pool = require('../db/pool');
  pool.options.connectionTimeoutMillis = 15000;
  let client;
  try {
    client = await pool.connect();
    await client.query('BEGIN READ ONLY');
    await client.query("SET LOCAL statement_timeout = '15s'");
    await client.query(aggregateSql, [userId]);
    console.log('PASS: production trust aggregate executes on the configured schema.');

    const fixtureSql = aggregateSql.replace('WITH my_teams AS', `WITH bookings AS (
      SELECT * FROM jsonb_to_recordset($2::jsonb) AS b(
        id uuid, player_id uuid, status text, booking_group_id uuid,
        cancellation_reason text, cancelled_at timestamptz
      )
    ), my_teams AS`);
    const groupId = '00000000-0000-4000-8000-000000000010';
    const row = (i, status, group = groupId) => ({
      id: `00000000-0000-4000-8000-${String(i).padStart(12, '0')}`,
      player_id: userId, status, booking_group_id: group,
    });
    for (const scenario of [
      { name: 'three missed slots in one group count once', bookings: [row(1, 'no_show'), row(2, 'no_show'), row(3, 'no_show')], attended: 0, missed: 1 },
      { name: 'an attended group is not also penalized as a no-show', bookings: [row(1, 'checked_in'), row(2, 'no_show')], attended: 1, missed: 0 },
      { name: 'three separate no-shows count as three incidents', bookings: [row(1, 'no_show', null), row(2, 'no_show', null), row(3, 'no_show', null)], attended: 0, missed: 3 },
      { name: 'multiple checked-in slots count as one attendance', bookings: [row(1, 'checked_in'), row(2, 'checked_in')], attended: 1, missed: 0 },
    ]) {
      const { rows: [raw] } = await client.query(fixtureSql, [userId, JSON.stringify(scenario.bookings)]);
      const score = calculateTrust(raw);
      assert.equal(score.checkedIn, scenario.attended);
      assert.equal(score.noShows, scenario.missed);
      console.log(`PASS: ${scenario.name}.`);
    }
    const { rows: [column] } = await client.query(`SELECT data_type FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'venues' AND column_name = 'deposit_pct'`);
    assert.equal(column?.data_type, 'numeric');
    console.log('PASS: venue deposits support decimal percentages.');
    await client.query('ROLLBACK');
  } finally {
    if (client) {
      await client.query('ROLLBACK').catch(() => {});
      client.release();
    }
    await pool.end();
  }
}

main().catch(error => {
  console.error('Read-only verification failed:', error.code || error.message);
  process.exitCode = 1;
});
