/**
 * The seam between HTTP routes and the socket server.
 *
 * routes/teams.js needs to push "Sara was added to the group" to everyone's
 * phone, and routes/chat.js needs to push a new message. Both could
 * `require('./index')` and reach for `io` directly — but index.js requires the
 * routes' helpers, so that is a cycle, and in CommonJS a cycle hands one side a
 * half-initialised module whose exports are silently `undefined`.
 *
 * So the wiring is inverted: everyone talks to this module, and the socket
 * server registers itself here once it exists.
 *
 * The second reason is just as important — every emit here is a no-op until
 * `attach()` is called. That means `node src/scripts/*.js`, the migration
 * runners and the background jobs can all import a route helper that emits,
 * without a socket server, without a crash, and without knowing this exists.
 *
 * Room naming
 *   u:<userId>     every socket that user has open (phone + emulator + a second
 *                  device). Used for events that matter wherever they are in the
 *                  app: a new message in a chat they are not looking at, an
 *                  invite, a promotion.
 *   c:<channelId>  sockets currently viewing that chat. Used for the chatter
 *                  that is pointless off-screen — typing indicators, read
 *                  receipts ticking over.
 *
 * A message is emitted to both: `c:` so the open thread appends it instantly,
 * `u:` so the chat list badge and any other screen update too. Socket.IO
 * de-duplicates when one socket is in several of the target rooms, so a member
 * who is looking at the chat receives it exactly once.
 */

let io = null;

/** Called once, by realtime/index.js, after the socket server is built. */
function attach(server) {
  io = server;
}

function isLive() {
  return io !== null;
}

const userRoom = (userId) => `u:${userId}`;
const channelRoom = (channelId) => `c:${channelId}`;

/**
 * Push to one or many users, wherever they are in the app.
 *
 * Never throws. An emit failing is not a reason to roll back the database write
 * that caused it — the REST endpoints are the source of truth and the client
 * re-reads on open, so a dropped event costs a refresh, not correctness.
 */
function emitToUsers(userIds, event, payload) {
  if (!io) return;
  const ids = (Array.isArray(userIds) ? userIds : [userIds]).filter(Boolean);
  if (!ids.length) return;
  try {
    io.to(ids.map(userRoom)).emit(event, payload);
  } catch (e) {
    console.warn(`[rt] emitToUsers(${event}) failed:`, e.message);
  }
}

/** Push to everyone with that chat open. */
function emitToChannel(channelId, event, payload, { exceptSocketId = null } = {}) {
  if (!io || !channelId) return;
  try {
    const target = exceptSocketId
      ? io.except(exceptSocketId).to(channelRoom(channelId))
      : io.to(channelRoom(channelId));
    target.emit(event, payload);
  } catch (e) {
    console.warn(`[rt] emitToChannel(${event}) failed:`, e.message);
  }
}

/**
 * A new/changed message: to the open thread and to every member's device.
 *
 * `memberIds` comes from the caller because it already had to read the roster to
 * write notifications, and reading it twice for one message is the kind of extra
 * query that adds up at chat volume.
 */
function emitMessage(channelId, memberIds, event, payload) {
  if (!io) return;
  try {
    const rooms = [channelRoom(channelId), ...(memberIds || []).filter(Boolean).map(userRoom)];
    io.to(rooms).emit(event, payload);
  } catch (e) {
    console.warn(`[rt] emitMessage(${event}) failed:`, e.message);
  }
}

/** Which user ids currently have at least one socket connected. */
function onlineUserIds() {
  if (!io) return [];
  const out = new Set();
  for (const [, socket] of io.of('/').sockets) {
    if (socket.userId) out.add(socket.userId);
  }
  return [...out];
}

function isUserOnline(userId) {
  if (!io || !userId) return false;
  for (const [, socket] of io.of('/').sockets) {
    if (socket.userId === userId) return true;
  }
  return false;
}

/**
 * Is this user looking at this chat right now?
 *
 * The distinction matters because of what Wave C does with the answer: a new chat
 * message writes a notification row (and therefore a tray push) only when the
 * recipient will not see the message arrive on its own. Someone with the thread
 * open already got it through `c:<channelId>` a millisecond ago, and buzzing their
 * phone about a message visible on screen is the single most irritating thing a
 * chat app does.
 *
 * `socket.rooms` is Socket.IO's own membership set and is maintained by the
 * join/leave the client already sends on opening and closing a thread
 * (realtime/index.js), so this is a read of existing state rather than new
 * bookkeeping. It answers false when no socket server is attached, which is the
 * correct answer for a job or a script: nobody is viewing anything, so notify.
 */
function isUserViewingChannel(userId, channelId) {
  if (!io || !userId || !channelId) return false;
  const room = channelRoom(channelId);
  for (const [, socket] of io.of('/').sockets) {
    if (socket.userId === userId && socket.rooms && socket.rooms.has(room)) return true;
  }
  return false;
}

module.exports = {
  attach,
  isLive,
  userRoom,
  channelRoom,
  emitToUsers,
  emitToChannel,
  emitMessage,
  onlineUserIds,
  isUserOnline,
  isUserViewingChannel,
};
