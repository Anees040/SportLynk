const pool = require('../db/pool');
const bus = require('../realtime/bus');
const { buildSystemMessage } = require('./chatSystemMessages');
const { notify } = require('./notify');

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
  // SEQUENTIAL, not Promise.all. Every caller but emitPills passes a transaction
  // CLIENT, and a single pg client executes one query at a time -- issuing two
  // concurrently only queues them behind a deprecation warning today and throws in
  // pg@9. Two reads that must both finish before the emit gain nothing from being
  // started together on a connection that will serialise them anyway.
  const message = await hydrateMessage(client, messageId);
  const members = await channelMemberIds(client, channelId);
  if (message) bus.emitMessage(channelId, members, event, message);
  return message;
}


// ═══════════════════════════════════════════════════════════════════════════
// THE OTHER TWO CHANNEL TYPES  (S.7 Wave B)
// ═══════════════════════════════════════════════════════════════════════════
//
// `chk_chat_channels_type` has allowed 'booking' and 'captain' since migration
// 015, and until now nothing in the codebase created either one: the constraint
// described an intention, not a feature. These two creators are what turn a
// confirmed booking and an accepted challenge into a room people can actually
// talk in.
//
// BOTH ARE IDEMPOTENT, and that is not a nicety. A booking can be confirmed by
// the owner or by autoApproveJob, and a challenge response can be retried after
// a dropped connection; `ux_chat_channels_type_ref` makes the second attempt an
// UPDATE instead of a duplicate room, so neither path has to know whether the
// other already ran.
//
// WHY THE MEMBER ROLE IS 'admin' FOR THE OWNER AND THE CAPTAINS
// `chk_chat_member_role` allows only 'admin' | 'member', and the group role is
// what authorises deleting somebody else's message (routes/chat.js). In a booking
// room the venue owner is the moderator; in a coordination room both captains
// are. A player in their own booking room is a 'member' — they can delete their
// own messages and nothing else.

/** Upsert one member without disturbing a role somebody already has. */
async function addMember(client, channelId, userId, role = 'member') {
  if (!channelId || !userId) return;
  await client.query(
    `INSERT INTO chat_channel_members (channel_id, user_id, role)
     VALUES ($1, $2, $3)
     ON CONFLICT (channel_id, user_id) DO UPDATE
       SET role = EXCLUDED.role, left_at = NULL`,
    [channelId, userId, role],
  );
}

/**
 * The room for one booking: the player and the venue owner, opened the moment the
 * booking is CONFIRMED.
 *
 * Deliberately not created on request. An unapproved request is not a
 * conversation — it is a form waiting for an answer — and opening a room for
 * every speculative request would fill both inboxes with threads that mostly get
 * rejected.
 *
 * `title` is the venue name and `imageUrl` its photo, denormalised for the same
 * reason the team channel denormalises them: the chat list must be one indexed
 * read, not a join per row.
 */
async function ensureBookingChannel(client, {
  bookingId, playerId, ownerId, title = null, imageUrl = null, createdBy = null,
}) {
  if (!bookingId) return null;
  const { rows } = await client.query(
    `INSERT INTO chat_channels (type, ref_id, title, image_url, created_by)
     VALUES ('booking', $1, $2, $3, $4)
     ON CONFLICT (type, ref_id) WHERE ref_id IS NOT NULL
     DO UPDATE SET title = COALESCE(EXCLUDED.title, chat_channels.title),
                   image_url = COALESCE(EXCLUDED.image_url, chat_channels.image_url)
     RETURNING id`,
    [bookingId, title, imageUrl, createdBy || ownerId || playerId || null],
  );
  const channelId = rows[0].id;
  await addMember(client, channelId, playerId, 'member');
  await addMember(client, channelId, ownerId, 'admin');
  return channelId;
}

/**
 * The room for one match: both captains and both vice-captains, opened when the
 * challenge is ACCEPTED.
 *
 * WHY VICE-CAPTAINS TOO
 * FR8.5 calls this the captains' room, but a vice-captain is exactly the person
 * who runs the team when the captain is unreachable — and "unreachable captain"
 * is the failure this room exists to prevent. Including them costs two rows and
 * removes the single point of failure.
 *
 * `memberIds` is resolved by the caller because it has already read both rosters
 * for its own fan-out, and reading them twice for one room is the kind of extra
 * query that adds up on a hot path.
 */
async function ensureCaptainChannel(client, { matchId, title = null, memberIds = [] }) {
  if (!matchId) return null;
  const { rows } = await client.query(
    `INSERT INTO chat_channels (type, ref_id, title, created_by)
     VALUES ('captain', $1, $2, $3)
     ON CONFLICT (type, ref_id) WHERE ref_id IS NOT NULL
     DO UPDATE SET title = COALESCE(EXCLUDED.title, chat_channels.title)
     RETURNING id`,
    [matchId, title, memberIds[0] || null],
  );
  const channelId = rows[0].id;
  for (const userId of [...new Set(memberIds.filter(Boolean))]) {
    // Everybody in a coordination room is an admin: there is no hierarchy
    // between two opposing captains, and either should be able to clear a
    // mis-sent photo from a room that is evidence in a dispute (FR10.6).
    await addMember(client, channelId, userId, 'admin');
  }
  return channelId;
}

/** The captain room for a match, or null if the challenge predates Wave B. */
async function captainChannelId(client, matchId) {
  if (!matchId) return null;
  const { rows } = await client.query(
    "SELECT id FROM chat_channels WHERE type = 'captain' AND ref_id = $1", [matchId],
  );
  return rows[0] ? rows[0].id : null;
}

/** The booking room for a booking, or null if it was never confirmed. */
async function bookingChannelId(client, bookingId) {
  if (!bookingId) return null;
  const { rows } = await client.query(
    "SELECT id FROM chat_channels WHERE type = 'booking' AND ref_id = $1", [bookingId],
  );
  return rows[0] ? rows[0].id : null;
}

/**
 * "This booking is now a conversation", in one call: room, both members, opening
 * pill. Returns `{ channelId, messageId }` for the caller to emit AFTER its
 * COMMIT, or null when there was nothing to open.
 *
 * SAVEPOINT-wrapped for the same reason matchCore.announceToTeam is: approving a
 * booking moves money and frees a slot, and a chat table that is missing or a
 * title that trips a constraint must never be able to undo that. A booking with
 * no room is a booking you cannot message about; a rolled-back approval is a
 * player who paid and got nothing.
 *
 * There are exactly two confirm paths -- the owner tapping approve and
 * autoApproveJob -- and they call this identically, so the room and its first
 * sentence do not depend on which one won the race.
 */
async function openBookingRoom(client, {
  bookingId, playerId, ownerId, venueName = null, imageUrl = null,
  event = 'booking_confirmed', value = null, actorName = null,
}) {
  if (!bookingId || !playerId || !ownerId) return null;
  await client.query('SAVEPOINT sl_booking_room');
  try {
    const channelId = await ensureBookingChannel(client, {
      bookingId, playerId, ownerId,
      title: venueName || null,
      imageUrl: imageUrl || null,
      createdBy: ownerId,
    });
    const { message } = await postSystemMessage(
      client, channelId,
      buildSystemMessage(event, { value, actorName, targetName: null }),
    );
    await client.query('RELEASE SAVEPOINT sl_booking_room');
    return { channelId, messageId: message.id };
  } catch (e) {
    await client.query('ROLLBACK TO SAVEPOINT sl_booking_room');
    console.warn(`[chat] booking room (${event}) skipped:`, e.message);
    return null;
  }
}

/**
 * Post one pill into an EXISTING room, or do nothing if the room was never
 * created (a booking confirmed before Wave B shipped has no channel, and that
 * must read as "no pill", not as an error).
 */
async function announceInRoom(client, channelId, event, opts = {}) {
  if (!channelId) return null;
  await client.query('SAVEPOINT sl_room_pill');
  try {
    const { message } = await postSystemMessage(
      client, channelId, buildSystemMessage(event, opts),
    );
    await client.query('RELEASE SAVEPOINT sl_room_pill');
    return { channelId, messageId: message.id };
  } catch (e) {
    await client.query('ROLLBACK TO SAVEPOINT sl_room_pill');
    console.warn(`[chat] room pill (${event}) skipped:`, e.message);
    return null;
  }
}

/**
 * Emit a batch of `{channelId, messageId}` pills. Call this AFTER COMMIT and
 * never before: a socket event that arrives while the transaction is open tells
 * the app to re-read a row it cannot see yet, and it renders the old one.
 * Swallows its own failures -- the write is already durable, and a dropped
 * socket frame costs the user one pull-to-refresh, not the booking.
 */
async function emitPills(clientOrPool, pills) {
  for (const pill of (Array.isArray(pills) ? pills : [pills])) {
    if (!pill || !pill.channelId || !pill.messageId) continue;
    try {
      await emitPersistedMessage(clientOrPool, pill.channelId, pill.messageId);
    } catch (e) {
      console.warn('[chat] pill emit skipped:', e.message);
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// CHAT → NOTIFICATION  (S.7 Wave C)
// ═══════════════════════════════════════════════════════════════════════════
//
// A message is the one notification whose correctness is decided by PRESENCE, not
// by the message. Every other alert in SportLynk is about something that happened
// to you while you were elsewhere; a chat message is frequently about something on
// the screen you are looking at right now, and buzzing a phone about a line of text
// already visible on it is the single most irritating thing a chat app does.
//
// So three separate mutes are consulted, in order of how specific they are:
//
//   1. `bus.isUserViewingChannel(userId, channelId)` — the thread is OPEN on their
//      screen. No row at all: writing one would leave a permanent unread badge for
//      a message they demonstrably read, and the badge is only useful while it is
//      trustworthy.
//   2. `chat_channel_members.muted_until` — they muted THIS conversation. Also no
//      row: a muted group that still moved the bell would not be muted.
//   3. Everything else (offline, or in the app but on another screen) gets a row.
//      The tray banner is then pushJob's decision, where the per-category
//      preference and quiet hours live. That split is deliberate: whether you are
//      TOLD is a chat concern, whether your phone BUZZES is a notification concern.
//
// GROUP WORDING. `chatGroup` in the registry leaves `title` alone and rewrites only
// `body` to "N new messages", so the title must carry the thread's identity: the
// sender for a two-person room, the channel for a group. A collapsed team row then
// reads "Lightning XI" / "3 new messages" and a collapsed booking room reads
// "Ali Raza" / "3 new messages", which is what the tray of every messaging app
// shows.
//
// SAVEPOINT-WRAPPED, and this is the load-bearing part: this runs inside the same
// transaction as the message INSERT. A notifications table one migration behind, a
// CHECK the registry trips, a member row with a column that does not exist — none of
// them may be allowed to roll back somebody's message. A sent message with no alert
// is a missed ping; a rolled-back message is a lie about a conversation.

/** 'Photo' / 'Voice message' / the text — the same preview the channel row stores. */
function messagePreview(message) {
  if (!message) return '';
  if (message.kind === 'image') return 'Photo';
  if (message.kind === 'audio') return 'Voice message';
  return String(message.body || '').slice(0, 160);
}

/**
 * Write one `chat_message` notification per member who is not looking at the thread.
 *
 * Returns `{ notified, viewing, muted }` so the check script can assert the split
 * rather than merely counting rows.
 */
async function notifyNewMessage(client, { channelId, message }) {
  const out = { notified: 0, viewing: 0, muted: 0 };
  // System pills and Scout's own replies are never a ping: nobody wants a banner
  // saying "booking confirmed" one second after tapping Approve, and the assistant
  // thread is by definition already on screen.
  if (!channelId || !message || message.is_system || !message.sender_id) return out;

  await client.query('SAVEPOINT sl_chat_notify');
  try {
    const { rows } = await client.query(
      `SELECT c.type, c.title AS channel_title, cm.user_id,
              (cm.muted_until IS NOT NULL AND cm.muted_until > now()) AS is_muted,
              s.name AS sender_name, s.avatar_url AS sender_avatar
         FROM chat_channel_members cm
         JOIN chat_channels c ON c.id = cm.channel_id
         LEFT JOIN users s ON s.id = $2
        WHERE cm.channel_id = $1 AND cm.left_at IS NULL`,
      [channelId, message.sender_id],
    );
    if (!rows.length || rows[0].type === 'assistant') {
      await client.query('RELEASE SAVEPOINT sl_chat_notify');
      return out;
    }

    const channelType = rows[0].type;
    const channelTitle = rows[0].channel_title || null;
    const senderName = rows[0].sender_name || 'Someone';
    const preview = messagePreview(message);
    // Group by MEMBER COUNT, not by channel type: a booking room is always two
    // people, a captain room is two-to-four, and a team of two would read wrong if
    // the type alone decided it.
    const isGroup = rows.length > 2;
    const title = isGroup ? (channelTitle || 'Group chat') : senderName;
    const body = isGroup ? `${senderName}: ${preview}` : preview;
    const payload = {
      channelId,
      channelType,
      channelTitle: channelTitle || (isGroup ? 'Group chat' : senderName),
      messageId: message.id,
      senderId: message.sender_id,
      senderName,
    };

    for (const r of rows) {
      if (r.user_id === message.sender_id) continue;
      if (bus.isUserViewingChannel(r.user_id, channelId)) { out.viewing += 1; continue; }
      if (r.is_muted) { out.muted += 1; continue; }
      await notify(client, {
        userId: r.user_id,
        type: 'chat_message',
        title,
        body: body || 'New message',
        payload,
        actorId: message.sender_id,
        imageUrl: r.sender_avatar || null,
      });
      out.notified += 1;
    }

    await client.query('RELEASE SAVEPOINT sl_chat_notify');
    return out;
  } catch (e) {
    await client.query('ROLLBACK TO SAVEPOINT sl_chat_notify');
    console.warn('[chat] message notification skipped:', e.message);
    return out;
  }
}

module.exports = {
  ensureTeamChannel, syncTeamMember, removeTeamMember, channelMemberIds,
  insertMessage, postSystemMessage, hydrateMessage, emitPersistedMessage,
  addMember, ensureBookingChannel, ensureCaptainChannel,
  captainChannelId, bookingChannelId,
  openBookingRoom, announceInRoom, emitPills,
  messagePreview, notifyNewMessage,
};
