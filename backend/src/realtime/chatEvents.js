/**
 * Everything a connected socket is allowed to send the server: opening a thread, typing,
 * and marking messages read. Registered once per connection by realtime/index.js.
 *
 * Two rules hold for every handler
 *   1. Flood budget first. `socket.data.allow()` is the per-socket token bucket;
 *      an event that overruns it is dropped silently. A client cannot buy more
 *      event loop by shouting.
 *   2. Membership is proven by the room, not the payload. Typing and read only
 *      make sense once a socket has opened a channel via `channel:join`, and that
 *      handler is the one place that checks the database and calls socket.join().
 *      So the later handlers can trust `socket.rooms.has(c:<id>)` as proof of
 *      membership and skip a query per keystroke — the room can only have been
 *      entered by passing the check.
 *
 * `socket.to(room)` excludes the sender, which is exactly right here: I don't
 * need my own typing indicator, and my own read doesn't change how I see anyone
 * else's ticks.
 */

const pool = require('../db/pool');
const bus = require('./bus');
const { isUuid } = require('../utils/teamAccess');

function registerChatEvents(io, socket) {
  const userId = socket.userId;
  const allow = () => socket.data.allow();
  const inChannel = (channelId) => socket.rooms.has(bus.channelRoom(channelId));

  /**
   * Open a thread. The only DB-checked entry point: confirm the user is a live
   * member, then join the channel room and stamp read+delivered to now (a
   * message on screen is, by definition, read). Broadcast the resulting
   * receipt so a sender watching sees blue ticks immediately.
   */
  socket.on('channel:join', async (payload = {}) => {
    if (!allow()) return;
    const channelId = payload.channelId;
    if (!isUuid(channelId)) return;
    try {
      const { rowCount } = await pool.query(
        `UPDATE chat_channel_members
            SET last_read_at = now(), last_delivered_at = now()
          WHERE channel_id = $1 AND user_id = $2 AND left_at IS NULL`,
        [channelId, userId],
      );
      if (!rowCount) return; // not a member (or has left) — do not join the room
      socket.join(bus.channelRoom(channelId));
      const at = new Date().toISOString();
      socket.to(bus.channelRoom(channelId)).emit('receipt', {
        channelId, userId, deliveredAt: at, readAt: at,
      });
    } catch (e) {
      console.warn('[rt] channel:join failed:', e.message);
    }
  });

  /** Leave the thread's room — stop receiving its typing/receipt chatter. */
  socket.on('channel:leave', (payload = {}) => {
    if (!allow()) return;
    const channelId = payload.channelId;
    if (isUuid(channelId)) socket.leave(bus.channelRoom(channelId));
  });

  /**
   * Typing indicator. No DB, no persistence — it is pure ephemeral presence, so
   * it only ever goes to people who currently have the thread open.
   */
  socket.on('typing', (payload = {}) => {
    if (!allow()) return;
    const channelId = payload.channelId;
    if (!isUuid(channelId) || !inChannel(channelId)) return;
    socket.to(bus.channelRoom(channelId)).emit('typing', {
      channelId, userId, name: socket.data.name, isTyping: payload.isTyping !== false,
    });
  });

  /**
   * Read up to now. Moves the blue-tick watermark and tells the channel, so this
   * is the live counterpart of POST /api/chat/:id/read (which handles the same
   * for a client that is not currently socket-connected).
   */
  socket.on('message:read', async (payload = {}) => {
    if (!allow()) return;
    const channelId = payload.channelId;
    if (!isUuid(channelId) || !inChannel(channelId)) return;
    try {
      await pool.query(
        `UPDATE chat_channel_members
            SET last_read_at = now(), last_delivered_at = now()
          WHERE channel_id = $1 AND user_id = $2 AND left_at IS NULL`,
        [channelId, userId],
      );
      const at = new Date().toISOString();
      socket.to(bus.channelRoom(channelId)).emit('receipt', {
        channelId, userId, deliveredAt: at, readAt: at,
      });
    } catch (e) {
      console.warn('[rt] message:read failed:', e.message);
    }
  });
}

module.exports = { registerChatEvents };
