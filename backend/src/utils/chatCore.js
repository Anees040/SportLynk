const pool = require('../db/pool');
const bus = require('../realtime/bus');

async function ensureTeamChannel(client, team) {
  const { rows } = await client.query(
    `INSERT INTO chat_channels (type, ref_id, title, image_url, created_by)
     VALUES ('team', $1, $2, $3, $4)
     ON CONFLICT (type, ref_id) WHERE ref_id IS NOT NULL
     DO UPDATE SET title = EXCLUDED.title, image_url = EXCLUDED.image_url
     RETURNING id`,
    [team.id, team.name, team.logo_url || null, team.captain_id || null],
  );
  return rows[0].id;
}

async function syncTeamMember(client, channelId, userId, teamRole) {
  const role = teamRole === 'captain' || teamRole === 'vice_captain' ? 'admin' : 'member';
  await client.query(
    `INSERT INTO chat_channel_members (channel_id, user_id, role)
     VALUES ($1, $2, $3)
     ON CONFLICT (channel_id, user_id) DO UPDATE
       SET role = EXCLUDED.role, left_at = NULL, joined_at = now()`,
    [channelId, userId, role],
  );
}

async function removeTeamMember(client, channelId, userId) {
  await client.query(
    `UPDATE chat_channel_members SET left_at = now()
      WHERE channel_id = $1 AND user_id = $2 AND left_at IS NULL`,
    [channelId, userId],
  );
}

async function channelMemberIds(client, channelId) {
  const { rows } = await client.query(
    `SELECT user_id FROM chat_channel_members
      WHERE channel_id = $1 AND left_at IS NULL`, [channelId],
  );
  return rows.map((row) => row.user_id);
}

async function insertMessage(client, {
  channelId, senderId = null, clientId = null, kind = 'text', body = null,
  mediaUrl = null, mediaMime = null, mediaBytes = null, mediaW = null,
  mediaH = null, durationMs = null, waveform = null, replyToId = null,
  isSystem = false, systemMeta = null, assistantPayload = null,
}) {
  if (clientId && senderId) {
    const existing = await client.query(
      `SELECT * FROM chat_messages
        WHERE channel_id = $1 AND sender_id = $2 AND client_id = $3`,
      [channelId, senderId, clientId],
    );
    if (existing.rows[0]) return { message: existing.rows[0], duplicate: true };
  }

  const { rows } = await client.query(
    // created_at is clock_timestamp(), not the column default now(). now() is the
    // TRANSACTION's timestamp, so two messages written inside one transaction get a
    // byte-identical created_at -- and the assistant writes exactly that: the user's
    // question and Scout's answer, in one turn, in one transaction. With now() the
    // pair could only be ordered by the (kind = 'assistant') tiebreaker, which holds
    // for one turn but collapses across two: every question in the thread sorted
    // above every answer. clock_timestamp() advances per statement, so the rows are
    // ordered by when they were actually written, and the tiebreaker goes back to
    // covering only a genuine same-microsecond tie. Team chat writes one message per
    // transaction, where the two functions are indistinguishable.
    `INSERT INTO chat_messages
       (channel_id, sender_id, client_id, kind, body, media_url, media_mime,
        media_bytes, media_w, media_h, duration_ms, waveform, reply_to_id,
        is_system, system_meta, assistant_payload, created_at)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16, clock_timestamp())
     RETURNING *`,
    [channelId, senderId, clientId, kind, body, mediaUrl, mediaMime,
      mediaBytes, mediaW, mediaH, durationMs, waveform, replyToId,
      isSystem, systemMeta, assistantPayload],
  );
  const message = rows[0];
  // 'text', 'system' and 'assistant' all preview as their body — an assistant
  // row is guaranteed a non-empty body by chk_chat_messages_payload (018).
  const preview = kind === 'image' ? 'Photo' : kind === 'audio' ? 'Voice message' : body;
  await client.query(
    `UPDATE chat_channels SET last_message_at = $2,
       last_message_preview = left($3, 160), last_message_sender_id = $4,
       message_count = message_count + 1 WHERE id = $1`,
    [channelId, message.created_at, preview || '', senderId],
  );
  return { message, duplicate: false };
}

async function postSystemMessage(client, channelId, payload) {
  return insertMessage(client, {
    channelId, kind: 'system', body: payload.body, isSystem: true,
    systemMeta: payload.meta,
  });
}

async function hydrateMessage(clientOrPool, messageId) {
  const { rows } = await (clientOrPool || pool).query(
    `SELECT m.*, u.name AS sender_name, u.avatar_url AS sender_avatar,
       COALESCE(jsonb_agg(jsonb_build_object('emoji', r.emoji, 'userId', r.user_id))
         FILTER (WHERE r.id IS NOT NULL), '[]'::jsonb) AS reactions
       FROM chat_messages m
       LEFT JOIN users u ON u.id = m.sender_id
       LEFT JOIN chat_reactions r ON r.message_id = m.id
      WHERE m.id = $1 GROUP BY m.id, u.name, u.avatar_url`, [messageId],
  );
  return rows[0] || null;
}

async function emitPersistedMessage(client, channelId, messageId, event = 'chat:message') {
  const [message, members] = await Promise.all([
    hydrateMessage(client, messageId), channelMemberIds(client, channelId),
  ]);
  if (message) bus.emitMessage(channelId, members, event, message);
  return message;
}

module.exports = {
  ensureTeamChannel, syncTeamMember, removeTeamMember, channelMemberIds,
  insertMessage, postSystemMessage, hydrateMessage, emitPersistedMessage,
};
