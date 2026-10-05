/**
 * chatReceipts.js — the two watermarks behind the ticks, in one place.
 *
 * WHAT A TICK MEANS
 *   ✓   sent       the chat_messages row exists
 *   ✓✓  delivered  every other participant's device has it
 *   ✓✓  read       every other participant has opened the thread since
 *
 * Both marks live on chat_channel_members (migration 015) as high-water
 * timestamps, and the group tick is min(mark) across the other participants —
 * which is what makes a double tick in a team chat mean "everyone", not
 * "somebody".
 *
 * WHY THIS FILE EXISTS
 *   Three callers move these marks: the socket handlers (realtime/chatEvents.js),
 *   the connect hook (realtime/index.js) and the REST fallback
 *   (routes/chat.js POST /:channelId/read). Each had its own UPDATE and its own
 *   emit, and they had already drifted apart in three ways that the ticks were
 *   visibly wrong because of:
 *
 *     1. `channel:join` stamped last_read_at. A socket re-joins its rooms on every
 *        reconnect, including while the phone is asleep with the thread merely
 *        mounted — so a recipient who had not looked at anything reported a read
 *        receipt and the sender saw blue ticks nobody had earned.
 *     2. Nothing stamped last_delivered_at when a message was pushed. The mark
 *        only moved when a socket CONNECTED, so a recipient who was already
 *        online when the message landed kept a watermark older than it, and the
 *        sender's second tick never appeared.
 *     3. The REST route emitted nothing at all, so a read performed over the
 *        fallback path was invisible to everyone until the next refetch.
 *
 *   Every function here takes a `client` for the same reason chatList's do: a
 *   check script can drive the real statement inside a transaction it rolls back.
 *
 * WHY A RECEIPT ALSO GOES TO THE READER'S OWN ROOM
 *   A read is news for two audiences. The other members need it for their ticks,
 *   and the reader's OWN other screens need it to drop the unread badge — the
 *   inbox sits mounted underneath the open thread and has no other way to learn
 *   that the room it is showing a count for has just been read. Sending it to
 *   `u:<reader>` as well also makes a second device agree, which is the behaviour
 *   people expect from reading on a phone with a tablet open.
 */

const bus = require('../realtime/bus');

/**
 * Tell the room, and the member's own devices, that a mark moved.
 *
 * Omitted fields are left out rather than sent as null: a delivered-only receipt
 * must not be mistaken for "read is now null" by a client that overwrites what it
 * is given.
 */
function broadcast(channelId, userId, { deliveredAt = null, readAt = null } = {}) {
  if (!channelId || !userId) return;
  const payload = { channelId, userId };
  if (deliveredAt) payload.deliveredAt = deliveredAt;
  if (readAt) payload.readAt = readAt;
  bus.emitReceipt(channelId, userId, payload);
}

/**
 * Move one member's read mark (and, with it, delivered — a message on screen is
 * delivered by definition) to `at`, or to now.
 *
 * GREATEST on both columns: a late-arriving mark, a second device a few seconds
 * behind, or a client clock that is wrong must never be able to pull a watermark
 * backwards and turn read messages unread again. Returns the member's new marks,
 * or null when the caller is not a live member — which the callers treat as "do
 * not join the room / 403", never as a silent success.
 */
async function markRead(client, { channelId, userId, at = null }) {
  if (!channelId || !userId) return null;
  const { rows } = await client.query(
    `UPDATE chat_channel_members
        SET last_read_at      = GREATEST(last_read_at, COALESCE($3::timestamptz, now())),
            last_delivered_at = GREATEST(last_delivered_at, COALESCE($3::timestamptz, now()))
      WHERE channel_id = $1 AND user_id = $2 AND left_at IS NULL
      RETURNING last_read_at, last_delivered_at`,
    [channelId, userId, at],
  );
  if (!rows[0]) return null;
  const marks = {
    readAt: rows[0].last_read_at.toISOString(),
    deliveredAt: rows[0].last_delivered_at.toISOString(),
  };
  broadcast(channelId, userId, marks);
  return marks;
}

/**
 * Move one member's delivered mark only, leaving read where it is.
 *
 * This is what opening a thread's live feed earns: the device demonstrably has
 * the channel, which is the second tick, and nothing more. Read is a separate
 * claim the client makes explicitly once the thread is actually in front of
 * somebody.
 */
async function markDelivered(client, { channelId, userId, at = null }) {
  if (!channelId || !userId) return null;
  const { rows } = await client.query(
    `UPDATE chat_channel_members
        SET last_delivered_at = GREATEST(last_delivered_at, COALESCE($3::timestamptz, now()))
      WHERE channel_id = $1 AND user_id = $2 AND left_at IS NULL
      RETURNING last_delivered_at`,
    [channelId, userId, at],
  );
  if (!rows[0]) return null;
  const marks = { deliveredAt: rows[0].last_delivered_at.toISOString() };
  broadcast(channelId, userId, marks);
  return marks;
}

/**
 * Everything already waiting for this user is now on their device: stamp
 * delivered across every channel they are in, and tell each channel so a sender
 * watching sees the second tick appear.
 *
 * Returns the channel ids so the caller can reuse them for presence without a
 * second query.
 */
async function markDeliveredOnConnect(client, userId) {
  if (!userId) return [];
  const { rows } = await client.query(
    `UPDATE chat_channel_members
        SET last_delivered_at = GREATEST(last_delivered_at, now())
      WHERE user_id = $1 AND left_at IS NULL
      RETURNING channel_id, last_delivered_at`,
    [userId],
  );
  for (const r of rows) {
    broadcast(r.channel_id, userId, { deliveredAt: r.last_delivered_at.toISOString() });
  }
  return rows.map((r) => r.channel_id);
}

/**
 * A message has just been pushed into the room: stamp delivered for every other
 * participant whose device is connected to receive it.
 *
 * This is the missing half of the second tick. `bus.emitMessage` had already put
 * the row on every online member's socket by the time this runs, so for those
 * members "delivered" is a statement of fact rather than an assumption — and for
 * everybody offline the mark stays where it is, which is what keeps a single tick
 * meaning something.
 *
 * Online-ness is read from the socket server's own connection map, the same
 * source `bus.isUserViewingChannel` uses to decide whether to push a
 * notification. With no socket server attached (a script, a job) nobody is
 * online, so nothing is stamped — the correct answer, not a degraded one.
 *
 * `senderId` is excluded because a sender's own marks are not part of their own
 * ticks; it is null for a system message, which has no sender to exclude.
 */
async function markDeliveredToOnline(client, { channelId, senderId = null }) {
  if (!channelId) return [];
  const { rows } = await client.query(
    `SELECT user_id FROM chat_channel_members
      WHERE channel_id = $1 AND left_at IS NULL
        AND ($2::uuid IS NULL OR user_id <> $2)`,
    [channelId, senderId],
  );
  const online = rows.map((r) => r.user_id).filter((id) => bus.isUserOnline(id));
  if (!online.length) return [];

  const updated = await client.query(
    `UPDATE chat_channel_members
        SET last_delivered_at = GREATEST(last_delivered_at, now())
      WHERE channel_id = $1 AND user_id = ANY($2::uuid[]) AND left_at IS NULL
      RETURNING user_id, last_delivered_at`,
    [channelId, online],
  );
  for (const r of updated.rows) {
    broadcast(channelId, r.user_id, { deliveredAt: r.last_delivered_at.toISOString() });
  }
  return updated.rows.map((r) => r.user_id);
}

module.exports = {
  broadcast,
  markRead,
  markDelivered,
  markDeliveredOnConnect,
  markDeliveredToOnline,
};
