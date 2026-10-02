/**
 * probe_pin.js — reproduces the "pin a message" path against the real database
 * inside a transaction that is always ROLLED BACK, to surface the actual error
 * behind the reported 500. Nothing is persisted: every write happens inside one
 * BEGIN/ROLLBACK, mirroring check_chat.js.
 *
 * Usage:  node src/scripts/probe_pin.js
 */
const pool = require('../db/pool');
const chat = require('../utils/chatCore');

async function main() {
  const client = await pool.connect();
  try {
    // A real team channel that has an admin member and at least one pinnable
    // (non-system, non-deleted) message — the exact shape the pin route needs.
    const { rows } = await client.query(`
      SELECT m.id AS message_id, m.channel_id, mem.user_id AS admin_id, c.type
        FROM chat_messages m
        JOIN chat_channels c ON c.id = m.channel_id
        JOIN chat_channel_members mem
          ON mem.channel_id = m.channel_id AND mem.role = 'admin' AND mem.left_at IS NULL
       WHERE m.kind <> 'system' AND m.deleted_at IS NULL AND m.pinned_at IS NULL
       ORDER BY m.created_at DESC
       LIMIT 1
    `);
    if (rows.length === 0) {
      console.log('No (channel, admin, pinnable message) triple found — cannot probe.');
      return;
    }
    const { message_id, channel_id, admin_id, type } = rows[0];
    console.log(`Probing pin on channel ${channel_id} (type=${type}), message ${message_id}, as admin ${admin_id}`);

    await client.query('BEGIN');
    try {
      console.log('1/3 setPinned …');
      await chat.setPinned(client, { messageId: message_id, pinned: true, by: admin_id });
      console.log('    ok');

      console.log('2/3 announceInRoom(message_pinned) …');
      const actorName = (await client.query('SELECT name FROM users WHERE id = $1', [admin_id]))
        .rows[0]?.name || 'Someone';
      const pill = await chat.announceInRoom(client, channel_id, 'message_pinned', {
        actorId: admin_id, actorName,
      });
      console.log('    ok, pill =', pill);

      console.log('3/3 emitPersistedMessage (hydrate + member ids; socket is null in a script) …');
      const hydrated = await chat.emitPersistedMessage(client, channel_id, message_id);
      console.log('    ok, hydrated id =', hydrated && hydrated.id);

      console.log('\nRESULT: the pin path completed with NO error in-process.');
    } finally {
      await client.query('ROLLBACK');
      console.log('(rolled back — nothing persisted)');
    }
  } catch (e) {
    console.error('\nRESULT: the pin path THREW:');
    console.error(e);
  } finally {
    client.release();
    await pool.end();
  }
}

main();
