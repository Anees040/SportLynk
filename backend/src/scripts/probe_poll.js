/**
 * probe_poll.js — exercises the poll create + vote + hydrate path against the
 * real database inside a transaction that is always ROLLED BACK. Nothing is
 * persisted. Confirms createPoll, votePoll and the POLL_SQL projection work on
 * live Postgres before the Flutter UI relies on them.
 *
 * Usage:  node src/scripts/probe_poll.js
 */
const pool = require('../db/pool');
const chat = require('../utils/chatCore');

async function main() {
  const client = await pool.connect();
  try {
    const { rows } = await client.query(`
      SELECT mem.channel_id, mem.user_id
        FROM chat_channel_members mem
        JOIN chat_channels c ON c.id = mem.channel_id
       WHERE mem.left_at IS NULL AND c.type = 'team'
       LIMIT 1
    `);
    if (rows.length === 0) {
      console.log('No team channel member found — cannot probe.');
      return;
    }
    const { channel_id, user_id } = rows[0];
    console.log(`Probing poll on channel ${channel_id} as ${user_id}`);

    await client.query('BEGIN');
    try {
      console.log('1/3 createPoll …');
      const messageId = await chat.createPoll(client, {
        channelId: channel_id,
        userId: user_id,
        question: 'Probe: Sunday 6pm?',
        options: ['Yes', 'No', 'Maybe'],
        allowMultiple: false,
      });
      console.log('    ok, message', messageId);

      const pollId = (await client.query(
        'SELECT id FROM chat_polls WHERE message_id = $1', [messageId])).rows[0].id;

      console.log('2/3 votePoll (option 0) …');
      const v1 = await chat.votePoll(client, { channelId: channel_id, pollId, userId: user_id, optionIndex: 0 });
      console.log('    ok', v1.ok);
      console.log('    switch to option 2 (single-choice should replace) …');
      await chat.votePoll(client, { channelId: channel_id, pollId, userId: user_id, optionIndex: 2 });

      console.log('3/3 hydrateMessage → poll projection …');
      const hydrated = await chat.hydrateMessage(client, messageId);
      console.log('    kind =', hydrated.kind);
      console.log('    poll =', JSON.stringify(hydrated.poll));

      const votes = hydrated.poll.votes;
      const ok = hydrated.kind === 'poll'
        && hydrated.poll.options.length === 3
        && votes.length === 1
        && votes[0].optionIndex === 2;
      console.log(ok
        ? '\nRESULT: poll create + single-choice vote + projection all correct.'
        : '\nRESULT: projection unexpected — inspect the poll JSON above.');
    } finally {
      await client.query('ROLLBACK');
      console.log('(rolled back — nothing persisted)');
    }
  } catch (e) {
    console.error('\nRESULT: the poll path THREW:');
    console.error(e);
  } finally {
    client.release();
    await pool.end();
  }
}

main();
