/**
 * probe_audio.js — exercises the voice-note write and read path against the real
 * database inside a transaction that is always ROLLED BACK. Nothing is persisted.
 *
 * Why: a voice note that fails to INSERT (a column type mismatch, a CHECK) leaves
 * the bubble in the failed state with a dead play button, which looks exactly like
 * "the player is broken". This proves whether the row stores and reads back with
 * its duration and waveform intact, the way probe_pin.js proved the pin cast.
 *
 * Usage:  node src/scripts/probe_audio.js
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
    console.log(`Probing voice note on channel ${channel_id} as ${user_id}`);

    // The exact shape routes/chat.js builds for kind === 'audio'.
    const bars = [0.1, 0.42, 0.87, 0.5, 0.2];
    const insert = {
      channelId: channel_id,
      senderId: user_id,
      clientId: `probe-audio-${Date.now()}`,
      kind: 'audio',
      mediaUrl: 'https://res.cloudinary.com/demo/video/upload/v1/chat_audio/probe.m4a',
      mediaMime: 'audio/mp4',
      durationMs: 7200,
      waveform: JSON.stringify(bars),
    };

    await client.query('BEGIN');
    try {
      console.log('1/2 insertMessage(kind=audio, waveform jsonb) …');
      const out = await chat.insertMessage(client, insert);
      console.log('    ok, id =', out.message.id);
      console.log('    duration_ms stored =', out.message.duration_ms);
      console.log('    waveform stored    =', JSON.stringify(out.message.waveform));

      console.log('2/2 hydrateMessage → what the client parses …');
      const h = await chat.hydrateMessage(client, out.message.id);
      console.log('    kind =', h.kind, ' media_url =', h.media_url);
      console.log('    duration_ms =', h.duration_ms);
      console.log('    waveform =', JSON.stringify(h.waveform));

      const ok = h.kind === 'audio'
        && Number(h.duration_ms) === 7200
        && Array.isArray(h.waveform)
        && h.waveform.length === bars.length;
      console.log(ok
        ? '\nRESULT: the voice-note row stores and reads back correctly.'
        : '\nRESULT: the row came back unexpected — inspect the values above.');
    } finally {
      await client.query('ROLLBACK');
      console.log('(rolled back — nothing persisted)');
    }
  } catch (e) {
    console.error('\nRESULT: the voice-note path THREW:');
    console.error(e);
  } finally {
    client.release();
    await pool.end();
  }
}

main();
