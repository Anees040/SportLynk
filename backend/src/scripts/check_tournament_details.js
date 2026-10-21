/**
 * Read-only regression check for the detail endpoint used by owners and players.
 * Uses real Postgres types: a mocked query cannot catch lower(team_sport).
 * Run: node src/scripts/check_tournament_details.js
 */
const assert = require('node:assert/strict');
const pool = require('../db/pool');
const tournaments = require('../services/tournamentService');

async function main() {
  const client = await pool.connect();
  try {
    await client.query('BEGIN READ ONLY');
    await client.query("SET LOCAL statement_timeout = '15s'");
    const recent = await client.query(
      'SELECT id, owner_id FROM tournaments ORDER BY created_at DESC LIMIT 10',
    );
    assert.ok(recent.rows.length, 'Create a tournament before running this check');
    const players = await client.query("SELECT id FROM users WHERE role = 'player' LIMIT 1");
    assert.ok(players.rows.length, 'A player account is needed to check both roles');

    for (const row of recent.rows) {
      for (const [role, userId] of [
        ['owner', row.owner_id],
        ['player', players.rows[0].id],
      ]) {
        const result = await tournaments.detail(client, { tournamentId: row.id, userId });
        assert.equal(result.ok, true, `${role} detail succeeds`);
        assert.equal(result.status, 200);
        assert.equal(result.data.tournament.id, row.id);
        assert.equal(result.data.viewer.isOwner, role === 'owner');
        assert.equal(Boolean(result.data.organiser), role === 'owner');
        assert.ok(Array.isArray(result.data.fixtures));
        assert.ok(Array.isArray(result.data.standings));
      }
    }

    const missing = await tournaments.detail(client, { tournamentId: 'invalid-id' });
    assert.equal(missing.status, 404);
    console.log(`PASS: ${recent.rows.length} tournament(s) open for both owners and players; missing IDs return 404.`);
  } finally {
    await client.query('ROLLBACK').catch(() => {});
    client.release();
  }
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
}).finally(() => pool.end());
