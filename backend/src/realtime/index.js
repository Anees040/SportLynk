/**
 * The Socket.IO server — the live half of the chat, bolted onto the same HTTP
 * server Express already runs on (server.js calls initRealtime with it).
 *
 * What lives here vs in bus.js
 *   bus.js is the write side: any REST route can `bus.emitMessage(...)` without
 *   importing this file, and it is a silent no-op until `attach()` runs. This
 *   file is the read side: it owns the socket lifecycle — who connected, which
 *   rooms they are in, presence, and the inbound events (typing, receipts). Once
 *   built, it registers itself with bus so the two halves meet.
 *
 * Auth — identical trust model to authMiddleware.js
 *   A socket proves who it is exactly once, in the handshake, with the same JWT
 *   and the same secret as every REST call. `socket.userId` is then as
 *   trustworthy as `req.user.id`, and every room and every DB write below keys
 *   off it — never off anything the client sends in an event payload.
 *
 * The tick system (single / double / blue), end to end
 *   ✓   sent       chat_messages row exists (REST created it, bus emitted it)
 *   ✓✓  delivered  the recipient's device has it — stamped both when a socket
 *                  connects (markDeliveredOnConnect, for everything that was
 *                  waiting) and when a message is pushed to a member who was
 *                  already online (receipts.markDeliveredToOnline, called by the
 *                  send route)
 *   ✓✓  read       the recipient had the thread in front of them and the client
 *                  said so with `message:read`
 *   Both marks live on chat_channel_members (migration 015) and are moved only
 *   through utils/chatReceipts, which also owns the `receipt` fan-out — so the
 *   sender, if they are looking, watches their ticks turn grey → grey-grey → blue
 *   in real time, and the reader's own inbox drops its badge.
 */

const { Server } = require('socket.io');
const jwt = require('jsonwebtoken');
const pool = require('../db/pool');
const bus = require('./bus');
const receipts = require('../utils/chatReceipts');
const { registerChatEvents } = require('./chatEvents');

/**
 * A tiny per-socket token bucket: ~30 events / 10s.
 *
 * A socket is an open pipe into the server's event loop; without a ceiling one
 * misbehaving or compromised client can spin typing/read events fast enough to
 * saturate the DB. This is the socket-side echo of middleware/rateLimit.js — cheap,
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

/** Tell a user's channels whether they just came online / went offline. */
function broadcastPresence(io, channelIds, userId, online, lastSeenAt = null) {
  for (const channelId of channelIds) {
    io.to(bus.channelRoom(channelId)).emit('presence', { channelId, userId, online, lastSeenAt });
  }
}

function initRealtime(httpServer) {
  const io = new Server(httpServer, {
    // A phone app, not a browser on the app's own domain — there is no cookie to
    // and the JWT in the handshake is the real gate, so any origin may attempt
    // to connect but only a valid token gets past `io.use` below.
    cors: { origin: '*', methods: ['GET', 'POST'] },
    // Keep a dropped phone from lingering as a ghost "online" for long.
    pingTimeout: 20000,
    pingInterval: 25000,
    maxHttpBufferSize: 1e6, // 1 MB — events carry ids and short text, never media
  });

  // Handshake auth
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
      // Same posture as authMiddleware: any bad/expired token is refused outright,
      // with no detail about which, and nothing is logged as an error (a stale
      // token reconnecting is routine, not a fault).
      return next(new Error('unauthorized'));
    }
  });

  // Connection lifecycle
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
    // unhandled rejection. The stamp returns the channels it touched — every live
    // membership — which is exactly the fan-out set presence needs, so the two
    // share one query.
    try {
      const channelIds = await receipts.markDeliveredOnConnect(pool, userId);
      socket.data.channelIds = channelIds;
      broadcastPresence(io, channelIds, userId, true);
    } catch (e) {
      console.warn('[rt] connect setup failed:', e.message);
    }

    socket.on('disconnect', async () => {
      // Only the last socket going means the user is truly offline — a second
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
