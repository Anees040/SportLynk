/**
 * The Socket.IO server — the live half of the chat, bolted onto the same HTTP
 * server Express already runs on (server.js calls initRealtime with it).
 *
 * WHAT LIVES HERE vs in bus.js
 *   bus.js is the write side: any REST route can `bus.emitMessage(...)` without
 *   importing this file, and it is a silent no-op until `attach()` runs. THIS
 *   file is the read side: it owns the socket lifecycle — who connected, which
 *   rooms they are in, presence, and the inbound events (typing, receipts). Once
 *   built, it registers itself with bus so the two halves meet.
 *
 * AUTH — identical trust model to authMiddleware.js
 *   A socket proves who it is exactly once, in the handshake, with the same JWT
 *   and the same secret as every REST call. `socket.userId` is then as
 *   trustworthy as `req.user.id`, and every room and every DB write below keys
 *   off it — never off anything the client sends in an event payload.
 *
 * THE TICK SYSTEM (single / double / blue), end to end
 *   ✓   sent       chat_messages row exists (REST created it, bus emitted it)
 *   ✓✓  delivered  the recipient's socket connected and we stamped
 *                  last_delivered_at = now() (see markDeliveredOnConnect)
 *   ✓✓  read       the recipient opened the thread and we stamped last_read_at
 *   Both marks live on chat_channel_members (migration 015). When a mark moves we
 *   broadcast a `receipt` into the channel room so the SENDER, if they are
 *   looking, watches their ticks turn grey→grey-grey→blue in real time.
 */

const { Server } = require('socket.io');
const jwt = require('jsonwebtoken');
const pool = require('../db/pool');
const bus = require('./bus');
const { registerChatEvents } = require('./chatEvents');

/**
 * A tiny per-socket token bucket: ~30 events / 10s.
 *
 * A socket is an open pipe into our event loop; without a ceiling one misbehaving
 * or compromised client can spin typing/read events fast enough to saturate the
 * DB. This is the socket-side echo of middleware/rateLimit.js — cheap, in memory,
 * and applied to every inbound handler in chatEvents.js.
 */
function makeFloodLimiter({ capacity = 30, refillMs = 10000 } = {}) {
  let tokens = capacity;
  let last = Date.now();
  return function allow() {
    const now = Date.now();
    // Continuous refill, so a steady low rate never trips and a burst does.
    tokens = Math.min(capacity, tokens + ((now - last) / refillMs) * capacity);
    last = now;
    if (tokens < 1) return false;
    tokens -= 1;
    return true;
  };
}

/** The user's active (not-left) channel ids — the fan-out set for presence. */
async function activeChannelIds(userId) {
  const { rows } = await pool.query(
    `SELECT channel_id FROM chat_channel_members
      WHERE user_id = $1 AND left_at IS NULL`,
    [userId],
  );
  return rows.map((r) => r.channel_id);
}

/**
 * On connect, everything already waiting for this user is now "delivered".
 * Stamp the mark on every channel they belong to and tell each channel so a
 * sender watching sees the second tick appear. Returns the channel ids so the
 * caller can reuse them for presence without a second query.
 */
async function markDeliveredOnConnect(io, userId) {
  const channelIds = await activeChannelIds(userId);
  if (!channelIds.length) return channelIds;
  const deliveredAt = new Date().toISOString();
  await pool.query(
    `UPDATE chat_channel_members SET last_delivered_at = now()
      WHERE user_id = $1 AND left_at IS NULL`,
    [userId],
  );
  for (const channelId of channelIds) {
    io.to(bus.channelRoom(channelId)).emit('receipt', { channelId, userId, deliveredAt });
  }
  return channelIds;
}

/** Tell a user's channels whether they just came online / went offline. */
function broadcastPresence(io, channelIds, userId, online, lastSeenAt = null) {
  for (const channelId of channelIds) {
    io.to(bus.channelRoom(channelId)).emit('presence', { channelId, userId, online, lastSeenAt });
  }
}

function initRealtime(httpServer) {
  const io = new Server(httpServer, {
    // A phone app, not a browser on our domain — there is no cookie to protect
    // and the JWT in the handshake is the real gate, so any origin may attempt
    // to connect but only a valid token gets past `io.use` below.
    cors: { origin: '*', methods: ['GET', 'POST'] },
    // Keep a dropped phone from lingering as a ghost "online" for long.
    pingTimeout: 20000,
    pingInterval: 25000,
    maxHttpBufferSize: 1e6, // 1 MB — events carry ids and short text, never media
  });

  // ─── Handshake auth ───────────────────────────────────────────────────────
  io.use((socket, next) => {
    try {
      // Accept the token from auth (socket_io_client's `auth:`) or the query
      // string, so either client style works.
      const token = socket.handshake.auth?.token || socket.handshake.query?.token;
      if (!token) return next(new Error('unauthorized'));
      const decoded = jwt.verify(String(token), process.env.JWT_SECRET);
      if (!decoded?.id) return next(new Error('unauthorized'));
      socket.userId = decoded.id;
      socket.userRole = decoded.role;
      return next();
    } catch {
      // Same posture as authMiddleware: any bad/expired token is just refused,
      // with no detail about which, and nothing is logged as an error (a stale
      // token reconnecting is routine, not a fault).
      return next(new Error('unauthorized'));
    }
  });

  // ─── Connection lifecycle ───────────────────────────────────────────────────
  io.on('connection', async (socket) => {
    const userId = socket.userId;
    socket.join(bus.userRoom(userId));           // every device this user has open
    socket.data.allow = makeFloodLimiter();      // per-socket inbound budget

    // Look the display name up once so typing indicators can say "Sara is
    // typing…" without a query per keystroke.
    try {
      const { rows } = await pool.query('SELECT name FROM users WHERE id = $1', [userId]);
      socket.data.name = rows[0]?.name || 'Someone';
    } catch {
      socket.data.name = 'Someone';
    }

    registerChatEvents(io, socket);

    // Deliver-on-connect + presence online. Wrapped because a socket that
    // connects and instantly drops must not take the process down with an
    // unhandled rejection.
    try {
      const channelIds = await markDeliveredOnConnect(io, userId);
      socket.data.channelIds = channelIds;
      broadcastPresence(io, channelIds, userId, true);
    } catch (e) {
      console.warn('[rt] connect setup failed:', e.message);
    }

    socket.on('disconnect', async () => {
      // Only the LAST socket going means the user is truly offline — a second
      // device or a reconnect race must not flip them to "offline" prematurely.
      if (bus.isUserOnline(userId)) return;
      const lastSeenAt = new Date().toISOString();
      try {
        await pool.query('UPDATE users SET last_seen_at = now() WHERE id = $1', [userId]);
      } catch (e) {
        console.warn('[rt] last_seen update failed:', e.message);
      }
      broadcastPresence(io, socket.data.channelIds || [], userId, false, lastSeenAt);
    });
  });

  bus.attach(io);
  console.log('   🔌 Realtime (Socket.IO) attached');
  return io;
}

module.exports = { initRealtime };
