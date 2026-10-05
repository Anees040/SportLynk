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
 * JOINING IS NOT READING
 *   `channel:join` stamps DELIVERED and nothing else. It used to stamp read as
 *   well, on the reasoning that a message on screen is read — but a socket
 *   re-joins its rooms on every reconnect, and a reconnect happens while the
 *   phone is asleep with the thread merely mounted behind a lock screen. That
 *   turned "this device has the channel open somewhere" into a read receipt
 *   nobody had earned, and the sender watched their ticks go blue although the
 *   recipient had not looked at anything. Read is now only ever the explicit
 *   `message:read` below, which the client sends when the thread is genuinely in
 *   front of somebody (foregrounded and on screen).
 *
 * Both marks are moved through utils/chatReceipts so the socket path, the connect
 * hook and the REST fallback cannot drift apart again; that module also owns the
 * `receipt` fan-out, including the copy sent to the reader's own devices.
 */

const pool = require('../db/pool');
const bus = require('./bus');
const receipts = require('../utils/chatReceipts');
const { isUuid } = require('../utils/teamAccess');

function registerChatEvents(io, socket) {
  const userId = socket.userId;
  const allow = () => socket.data.allow();
  const inChannel = (channelId) => socket.rooms.has(bus.channelRoom(channelId));

  /**
   * Open a thread. The only DB-checked entry point: confirm the user is a live
   * member, stamp delivered (the device demonstrably has this channel now), then
   * join the channel room. A null answer from markDelivered means "not a member,
   * or has left", and the room is not joined — which is what keeps every later
   * handler's `socket.rooms` check a valid proof of membership.
   */
  socket.on('channel:join', async (payload = {}) => {
    if (!allow()) return;
    const channelId = payload.channelId;
    if (!isUuid(channelId)) return;
    try {
      const marks = await receipts.markDelivered(pool, { channelId, userId });
      if (!marks) return; // not a member (or has left) — do not join the room
      socket.join(bus.channelRoom(channelId));
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
   *
   * The client sends this only while the thread is visible and the app is
   * foregrounded, which is the whole claim a blue tick makes.
   */
  socket.on('message:read', async (payload = {}) => {
    if (!allow()) return;
    const channelId = payload.channelId;
    if (!isUuid(channelId) || !inChannel(channelId)) return;
    try {
      await receipts.markRead(pool, { channelId, userId });
    } catch (e) {
      console.warn('[rt] message:read failed:', e.message);
    }
  });
}

module.exports = { registerChatEvents };
