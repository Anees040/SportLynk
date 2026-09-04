/**
 * Chat API — the REST half of chat. The live
 * half (typing, receipts, presence) is Socket.IO in realtime/; this file owns the
 * inbox, history, sending, read-marks, membership watermarks, reactions,
 * delete-for-everyone, mute and the FR8.10 reply suggestions.
 *
 * Three channel TYPES, one set of handlers. A team chat, a booking room and a
 * match coordination room differ in who is in them and what the header shows —
 * never in how a message is sent or read. Membership on chat_channel_members is
 * the only authorisation rule, so adding a type costs a creator in chatCore and
 * nothing at all here.
 *
 * Two invariants, same as routes/teams.js:
 *   1. Membership is authority. Every handler proves the caller is a live member
 *      of the channel via `member()` before doing anything — never trusts a body.
 *   2. A media URL is only ever one of the app's own. Images are pinned to Cloudinary by
 *      access.validateMediaUrl, so a caller cannot make the app render a request
 *      to a host of their choosing (the same rule team logos follow).
 *
 * Every write goes through chatCore so the denormalised last-message columns and
 * the socket fan-out stay in one place and cannot drift from the row that landed.
 */

const express = require('express');
const pool = require('../db/pool');
const auth = require('../middleware/authMiddleware');
const chat = require('../utils/chatCore');
const access = require('../utils/teamAccess');
const list = require('../utils/chatList');
const qr = require('../utils/quickReplies');

const router = express.Router();
router.use(auth);

// The reaction palette. A closed set, not free emoji: an arbitrary string in this
// column is rendered on every device that loads the message, so it is validated
// exactly the way every other user-supplied string in this codebase is.
const REACTIONS = ['👍', '❤️', '😂', '😮', '😢', '🙏', '🔥', '🎉'];

const fail = (res, status, message) => res.status(status).json({ success: false, message });
const ok = (res, data) => res.json({ success: true, data });

/**
 * The caller's live membership of a channel, or null. Returns the channel's id,
 * type and ref plus the caller's GROUP role ('admin' | 'member') — the role is
 * what authorises deleting someone else's message, so it is read here in the same
 * query that proves membership rather than trusted from anywhere else.
 */
async function member(client, channelId, userId) {
  if (!access.isUuid(channelId)) return null;
  const r = await client.query(
    `SELECT c.id, c.type, c.ref_id, m.role
       FROM chat_channels c
       JOIN chat_channel_members m ON m.channel_id = c.id
      WHERE c.id = $1 AND m.user_id = $2 AND m.left_at IS NULL`,
    [channelId, userId],
  );
  return r.rows[0] || null;
}

// The CHAT list
//
// Every channel the caller belongs to, most-recent first — the inbox. Until this
// existed the app could only open a chat it already knew the id of (a team, from
// the team screen), which is why a booking room nobody navigates to might as well
// not exist.
//
// Mounted before '/:channelId/*' — and that is not a style choice. Express matches
// in declaration order, so a '/:channelId' route declared above '/unread-count'
// would swallow the literal string as a channel id and answer 404 forever.
//
// The queries live in utils/chatList.js and take a client, so check_chat.js drives
// these exact reads inside a transaction it rolls back.

/**
 * GET /api/chat?limit&cursor&type — the inbox page.
 *
 * Cursor-paginated on the same expression it sorts by, so a room that receives a
 * message mid-scroll cannot make a row appear twice or vanish.
 */
router.get('/', async (req, res, next) => {
  try {
    const limit = Math.min(Math.max(parseInt(req.query.limit, 10) || 30, 1), 50);
    const type = ['booking', 'captain', 'team'].includes(req.query.type) ? req.query.type : null;
    const page = await list.listChats(pool, {
      userId: req.user.id, limit, cursor: req.query.cursor || null, type,
    });
    return ok(res, page);
  } catch (e) { next(e); }
});

/**
 * GET /api/chat/unread-count — the header badge, one round trip.
 *
 * Muted rooms are excluded here and counted in the list; a badge that counts a
 * conversation the user silenced on purpose is why people switch badges off.
 */
router.get('/unread-count', async (req, res, next) => {
  try {
    return ok(res, await list.unreadCounts(pool, req.user.id));
  } catch (e) { next(e); }
});

// Channel lookup

/** Resolve a team's channel id — the entry point the chat screen opens with. */
router.get('/team/:teamId', async (req, res, next) => {
  try {
    if (!access.isUuid(req.params.teamId)) return fail(res, 404, 'Team not found.');
    // Members-only: a stranger must not be able to discover a private team's
    // channel id by probing this endpoint.
    const q = await pool.query(
      `SELECT c.id
         FROM chat_channels c
         JOIN chat_channel_members m ON m.channel_id = c.id
        WHERE c.type = 'team' AND c.ref_id = $1
          AND m.user_id = $2 AND m.left_at IS NULL`,
      [req.params.teamId, req.user.id],
    );
    if (!q.rows[0]) return fail(res, 404, 'Chat not found.');
    return ok(res, { channelId: q.rows[0].id });
  } catch (e) { next(e); }
});

/**
 * Resolve a booking's room, or a match's coordination room, from the thing it is
 * about — the entry points behind "Message venue" on a booking and "Coordinate"
 * on a match.
 *
 * 404, never 403, when the caller is not a member: the two are indistinguishable
 * to an honest client and telling a stranger "that room exists but is not yours"
 * confirms a booking they have no business knowing about. Same reason
 * /team/:teamId answers 404 for a non-member.
 *
 * A null answer is also the correct answer for anything that predates the rooms: a
 * booking confirmed last month has no room and never will, so the client renders
 * no button rather than an error.
 */
function refLookup(type, param) {
  return async (req, res, next) => {
    try {
      const refId = req.params[param];
      if (!access.isUuid(refId)) return fail(res, 404, 'Chat not found.');
      const channelId = await list.channelForRef(pool, { type, refId, userId: req.user.id });
      if (!channelId) return fail(res, 404, 'Chat not found.');
      return ok(res, { channelId });
    } catch (e) { next(e); }
  };
}

router.get('/booking/:bookingId', refLookup('booking', 'bookingId'));
router.get('/match/:matchId', refLookup('captain', 'matchId'));

// History

/**
 * A page of messages, oldest-first for direct rendering. `before` is a created_at
 * cursor: the client passes the oldest message it already holds to page backwards.
 * Reactions are aggregated in the same shape emitPersistedMessage sends live, so a
 * message looks identical whether it arrived over the socket or in history.
 */
router.get('/:channelId/messages', async (req, res, next) => {
  const client = await pool.connect();
  try {
    const m = await member(client, req.params.channelId, req.user.id);
    if (!m) return fail(res, 403, 'You are not a chat member.');

    const limit = Math.min(Math.max(Number(req.query.limit) || 40, 1), 100);
    const before = req.query.before || '9999-12-31';
    const { rows } = await client.query(
      `SELECT m.*, u.name AS sender_name, u.avatar_url AS sender_avatar,
              COALESCE(jsonb_agg(jsonb_build_object('emoji', r.emoji, 'userId', r.user_id))
                FILTER (WHERE r.id IS NOT NULL), '[]'::jsonb) AS reactions
         FROM chat_messages m
         LEFT JOIN users u ON u.id = m.sender_id
         LEFT JOIN chat_reactions r ON r.message_id = m.id
        WHERE m.channel_id = $1 AND m.created_at < $2
        GROUP BY m.id, u.name, u.avatar_url
        ORDER BY m.created_at DESC
        LIMIT $3`,
      [req.params.channelId, before, limit],
    );
    return ok(res, rows.reverse());
  } catch (e) { next(e); } finally { client.release(); }
});

// Send

/**
 * Post a message. `kind` is 'text' (default) or 'image'; voice ('audio') is a
 * planned follow-up and rejected explicitly so the client gets a clear sentence
 * rather than a constraint-violation 500. `clientId` makes the send idempotent —
 * a retry after a dropped response returns the original row with a 200, never a
 * duplicate (chatCore + ux_chat_messages_client enforce it).
 */
router.post('/:channelId/messages', async (req, res, next) => {
  const client = await pool.connect();
  try {
    const m = await member(client, req.params.channelId, req.user.id);
    if (!m) return fail(res, 403, 'You are not a chat member.');

    const kind = req.body.kind === 'image' ? 'image' : req.body.kind === 'audio' ? 'audio' : 'text';
    if (kind === 'audio') return fail(res, 400, 'Voice messages are coming soon.');

    const clientId = typeof req.body.clientId === 'string' ? req.body.clientId.slice(0, 64) : null;
    const insert = { channelId: req.params.channelId, senderId: req.user.id, clientId, kind };

    if (kind === 'image') {
      const media = access.validateMediaUrl(req.body.mediaUrl, { label: 'Image', required: true });
      if (!media.ok) return fail(res, 400, media.message);
      insert.mediaUrl = media.value;
      insert.mediaMime = typeof req.body.mediaMime === 'string' ? req.body.mediaMime.slice(0, 60) : null;
      insert.mediaW = Number.isFinite(+req.body.mediaW) ? Math.trunc(+req.body.mediaW) : null;
      insert.mediaH = Number.isFinite(+req.body.mediaH) ? Math.trunc(+req.body.mediaH) : null;
      const caption = access.squashMultiline(req.body.body || '');
      insert.body = caption || null; // an image may carry a caption, or none
    } else {
      const body = access.squashMultiline(req.body.body || '');
      if (!body) return fail(res, 400, 'Message cannot be empty.');
      if (body.length > 4000) return fail(res, 400, 'Message is too long.');
      insert.body = body;
    }

    await client.query('BEGIN');
    const out = await chat.insertMessage(client, insert);
    // Inside the same transaction as the insert, and only for a message that was
    // new: a retried clientId returns the original row, and notifying again
    // would ping a phone twice for one message. chatCore skips anybody with the thread
    // open or the channel muted, and is SAVEPOINT-wrapped so a notifications failure
    // cannot roll the message back.
    if (!out.duplicate) {
      await chat.notifyNewMessage(client, {
        channelId: req.params.channelId, message: out.message,
      });
    }
    await client.query('COMMIT');

    const hydrated = await chat.emitPersistedMessage(client, req.params.channelId, out.message.id);
    return res.status(out.duplicate ? 200 : 201).json({ success: true, data: hydrated || out.message });
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    next(e);
  } finally { client.release(); }
});

// Read MARK  (blue tick)

/**
 * Mark the channel read up to `at` (or now). GREATEST so a late-arriving mark can
 * never move a watermark backwards. This is the REST counterpart of the socket
 * `message:read` event — used when the app is foregrounded but the socket has not
 * yet (re)connected.
 */
router.post('/:channelId/read', async (req, res, next) => {
  try {
    if (!access.isUuid(req.params.channelId)) return fail(res, 404, 'Chat not found.');
    const n = await pool.query(
      `UPDATE chat_channel_members
          SET last_read_at = GREATEST(last_read_at, COALESCE($3::timestamptz, now())),
              last_delivered_at = GREATEST(last_delivered_at, COALESCE($3::timestamptz, now()))
        WHERE channel_id = $1 AND user_id = $2 AND left_at IS NULL`,
      [req.params.channelId, req.user.id, req.body.at || null],
    );
    if (!n.rowCount) return fail(res, 403, 'You are not a chat member.');
    return ok(res, { read: true });
  } catch (e) { next(e); }
});

// Members  (the tick watermarks + last-seen, for the client to compute ticks)

/**
 * Every live member with their read/delivered watermarks and last-seen. The chat
 * screen loads this once, then keeps the marks current from live `receipt` events;
 * the group tick for one of my messages is min(other members' mark) vs its time.
 */
router.get('/:channelId/members', async (req, res, next) => {
  const client = await pool.connect();
  try {
    const m = await member(client, req.params.channelId, req.user.id);
    if (!m) return fail(res, 403, 'You are not a chat member.');
    const { rows } = await client.query(
      `SELECT cm.user_id, cm.role, cm.last_read_at, cm.last_delivered_at,
              u.name, u.avatar_url, u.last_seen_at
         FROM chat_channel_members cm
         JOIN users u ON u.id = cm.user_id
        WHERE cm.channel_id = $1 AND cm.left_at IS NULL
        ORDER BY CASE cm.role WHEN 'admin' THEN 0 ELSE 1 END, lower(u.name)`,
      [req.params.channelId],
    );
    return ok(res, rows);
  } catch (e) { next(e); } finally { client.release(); }
});

// REACTIONS  (one emoji per person per message — tapping another replaces it)
router.post('/:channelId/messages/:messageId/reactions', async (req, res, next) => {
  const client = await pool.connect();
  try {
    const m = await member(client, req.params.channelId, req.user.id);
    if (!m) return fail(res, 403, 'You are not a chat member.');
    if (!access.isUuid(req.params.messageId)) return fail(res, 404, 'Message not found.');

    const emoji = String(req.body.emoji || '');
    if (!REACTIONS.includes(emoji)) return fail(res, 400, 'That reaction is not allowed.');

    const msg = (await client.query(
      `SELECT id FROM chat_messages
        WHERE id = $1 AND channel_id = $2 AND deleted_at IS NULL`,
      [req.params.messageId, req.params.channelId],
    )).rows[0];
    if (!msg) return fail(res, 404, 'Message not found.');

    await client.query('BEGIN');
    const existing = (await client.query(
      'SELECT emoji FROM chat_reactions WHERE message_id = $1 AND user_id = $2',
      [req.params.messageId, req.user.id],
    )).rows[0];

    if (existing && existing.emoji === emoji) {
      // Tapping the same emoji again clears it (WhatsApp toggle).
      await client.query('DELETE FROM chat_reactions WHERE message_id = $1 AND user_id = $2',
        [req.params.messageId, req.user.id]);
    } else {
      await client.query(
        `INSERT INTO chat_reactions (message_id, user_id, emoji) VALUES ($1,$2,$3)
         ON CONFLICT (message_id, user_id) DO UPDATE SET emoji = EXCLUDED.emoji, created_at = now()`,
        [req.params.messageId, req.user.id, emoji],
      );
    }
    await client.query('COMMIT');

    // Re-emit the message so every open client updates its reaction row in place
    // (they upsert by message id — same event as a new message).
    const hydrated = await chat.emitPersistedMessage(client, req.params.channelId, req.params.messageId);
    return ok(res, hydrated);
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    next(e);
  } finally { client.release(); }
});

// DELETE FOR everyone

/**
 * Delete a message for everyone: the caller's own, or any message if the caller is a
 * channel admin (captain / vice captain). A tombstone keeps the row — so replies
 * and history stay coherent — but strips the payload entirely (body, media), which
 * the DB payload-check explicitly permits only when deleted_at is set. The client
 * renders "This message was deleted" from deleted_at alone.
 */
router.delete('/:channelId/messages/:messageId', async (req, res, next) => {
  const client = await pool.connect();
  try {
    const m = await member(client, req.params.channelId, req.user.id);
    if (!m) return fail(res, 403, 'You are not a chat member.');
    if (!access.isUuid(req.params.messageId)) return fail(res, 404, 'Message not found.');

    const msg = (await client.query(
      'SELECT sender_id, kind, deleted_at FROM chat_messages WHERE id = $1 AND channel_id = $2',
      [req.params.messageId, req.params.channelId],
    )).rows[0];
    if (!msg) return fail(res, 404, 'Message not found.');
    if (msg.deleted_at) return ok(res, { deleted: true }); // idempotent
    if (msg.kind === 'system') return fail(res, 403, 'That message cannot be deleted.');
    if (msg.sender_id !== req.user.id && m.role !== 'admin') {
      return fail(res, 403, 'You can only delete your own messages.');
    }

    await client.query('BEGIN');
    await client.query(
      `UPDATE chat_messages
          SET deleted_at = now(), deleted_by = $2,
              body = NULL, media_url = NULL, media_mime = NULL, waveform = NULL
        WHERE id = $1`,
      [req.params.messageId, req.user.id],
    );
    await client.query('DELETE FROM chat_reactions WHERE message_id = $1', [req.params.messageId]);
    await client.query('COMMIT');

    const hydrated = await chat.emitPersistedMessage(client, req.params.channelId, req.params.messageId);
    return ok(res, hydrated || { deleted: true });
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    next(e);
  } finally { client.release(); }
});

// Mute

/**
 * POST /api/chat/:channelId/mute — body `{hours}` or `{muted:false}`.
 *
 * `muted_until` has existed on chat_channel_members since migration 013 and
 * nothing has ever written it. A timestamp rather than a boolean is the point:
 * "mute for 8 hours" is what somebody wants from a booking room the night
 * before a match, and it lifts by itself so nobody finds out three weeks later
 * that they silenced their own team.
 */
router.post('/:channelId/mute', async (req, res, next) => {
  const client = await pool.connect();
  try {
    const m = await member(client, req.params.channelId, req.user.id);
    if (!m) return fail(res, 403, 'You are not a chat member.');

    const body = req.body || {};
    let until = null;
    if (body.muted !== false) {
      // Capped at a year, floored at an hour. An unbounded number here is a
      // permanent mute somebody set by typing a zero too many.
      const hours = Number.isFinite(Number(body.hours)) ? Number(body.hours) : 8760;
      const capped = Math.min(Math.max(hours, 1), 8760);
      until = new Date(Date.now() + capped * 3600 * 1000);
    }
    return ok(res, await list.setMute(client, {
      channelId: m.id, userId: req.user.id, until,
    }));
  } catch (e) { next(e); } finally { client.release(); }
});

// FR8.10 — AI quick replies

/**
 * POST /api/chat/:channelId/quick-replies — body `{text}` or `{messageId}`.
 *
 * Classifies the other side's last message with model #4 (the released 23-label
 * classifier, unchanged) and returns three sendable replies chosen by the caller's
 * role in this room. Advisory only: tapping a chip fills the composer, and the
 * send goes through POST /:channelId/messages like any other message. See
 * utils/quickReplies.js for why the replies are a table and not generated.
 */
router.post('/:channelId/quick-replies', async (req, res, next) => {
  const client = await pool.connect();
  try {
    const m = await member(client, req.params.channelId, req.user.id);
    if (!m) return fail(res, 403, 'You are not a chat member.');
    const body = req.body || {};
    const r = await qr.suggestFor(client, {
      channel: m,
      userId: req.user.id,
      userRole: req.user.role,
      text: body.text,
      messageId: body.messageId,
    });
    if (r.error) return fail(res, r.error.status, r.error.message);
    return ok(res, r.data);
  } catch (e) { next(e); } finally { client.release(); }
});

module.exports = router;
