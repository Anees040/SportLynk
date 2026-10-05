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
const receipts = require('../utils/chatReceipts');
const access = require('../utils/teamAccess');
const list = require('../utils/chatList');
const qr = require('../utils/quickReplies');

const router = express.Router();
router.use(auth);

// The reaction palette. A closed set, not free emoji: an arbitrary string in this
// column is rendered on every device that loads the message, so it is validated
// exactly the way every other user-supplied string in this codebase is.
//
// The first eight are the quick-tap row the app shows on a long press; the rest
// are the "+" picker behind it. Both halves must be listed here — a picker offering
// an emoji this array omits reads as a reaction that applies and then vanishes a
// moment later, because the optimistic bubble reverts when the route answers 400.
// Kept in step with `_reactionEmojis` in lib/screens/shared/chat_thread_screen.dart.
const REACTIONS = [
  // Quick row
  '👍', '❤️', '😂', '😮', '😢', '🙏', '🔥', '🎉',
  // Picker
  '👏', '💯', '✅', '❌', '⚽', '🏏', '🏆', '😍',
  '😎', '🤔', '😅', '😭', '🙌', '👌', '💪', '😡',
  '🥳', '😴', '🤝', '👀', '💔', '😤', '🤷', '⏰',
];

const fail = (res, status, message) => res.status(status).json({ success: false, message });
const ok = (res, data) => res.json({ success: true, data });

/**
 * The caller's live membership of a channel, or null. Returns the channel's id,
 * type and ref plus the caller's GROUP role ('admin' | 'member') — the role is
 * what authorises deleting someone else's message, so it is read here in the same
 * query that proves membership rather than trusted from anywhere else.
 *
 * `history_from` comes back in the same row and is the caller's read boundary
 * (migration 036): the earliest message they may see. NULL means no bound, which
 * is every membership that predates the column. Every endpoint that returns
 * message CONTENT passes it through to the query, so there is one boundary and
 * not one per door.
 */
async function member(client, channelId, userId) {
  if (!access.isUuid(channelId)) return null;
  const r = await client.query(
    `SELECT c.id, c.type, c.ref_id, m.role, m.history_from
       FROM chat_channels c
       JOIN chat_channel_members m ON m.channel_id = c.id
      WHERE c.id = $1 AND m.user_id = $2 AND m.left_at IS NULL`,
    [channelId, userId],
  );
  return r.rows[0] || null;
}

/** How many people are live members of a channel — the poll gate's input. */
async function liveMemberCount(client, channelId) {
  const { rows } = await client.query(
    `SELECT count(*)::int AS n FROM chat_channel_members
      WHERE channel_id = $1 AND left_at IS NULL`,
    [channelId],
  );
  return rows[0] ? rows[0].n : 0;
}

/**
 * A poll is a group question, so it takes a group. Two people in a room can ask
 * each other directly, and a ballot between them is a worse version of the
 * conversation they are already having — so the action is refused below this many
 * live members, and the client hides the entry point on the same rule.
 *
 * Counting members rather than switching on the channel TYPE is what makes this
 * hold everywhere: a direct room and a booking room are structurally a pair, and
 * a coordination room with one captain per side is the same shape even though its
 * type says 'captain'.
 */
const POLL_MIN_MEMBERS = 3;

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
    const type = ['booking', 'captain', 'team', 'direct'].includes(req.query.type) ? req.query.type : null;
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
 *
 * The reader's history window (036) bounds the page from below. Without it,
 * adding a player to a team handed them every message the roster had ever sent —
 * membership was the only check, and membership says nothing about when it began.
 * It is applied here rather than in the client because a boundary the client
 * enforces is not a boundary: the rows would still be on the wire.
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
              ${chat.REPLY_PREVIEW_SQL} AS reply_preview,
              ${chat.POLL_SQL} AS poll,
              COALESCE(jsonb_agg(jsonb_build_object('emoji', r.emoji, 'userId', r.user_id))
                FILTER (WHERE r.id IS NOT NULL), '[]'::jsonb) AS reactions
         FROM chat_messages m
         LEFT JOIN users u ON u.id = m.sender_id
         LEFT JOIN chat_reactions r ON r.message_id = m.id
        WHERE m.channel_id = $1 AND m.created_at < $2
          -- "Delete for me" (033): a message this reader hid is absent from their
          -- history and present in everybody else's.
          AND NOT EXISTS (
            SELECT 1 FROM chat_message_hides h
             WHERE h.message_id = m.id AND h.user_id = $4
          )
          -- The reader's history window (036): nothing from before they joined.
          AND ($5::timestamptz IS NULL OR m.created_at >= $5)
        GROUP BY m.id, u.name, u.avatar_url
        ORDER BY m.created_at DESC
        LIMIT $3`,
      [req.params.channelId, before, limit, req.user.id, m.history_from],
    );
    return ok(res, rows.reverse());
  } catch (e) { next(e); } finally { client.release(); }
});

// Send

/**
 * Post a message. `kind` is 'text' (default), 'image', or 'audio' (a voice note:
 * a Cloudinary clip URL plus its mime and duration). `clientId` makes the send
 * idempotent — a retry after a dropped response returns the original row with a
 * 200, never a duplicate (chatCore + ux_chat_messages_client enforce it).
 */
router.post('/:channelId/messages', async (req, res, next) => {
  const client = await pool.connect();
  try {
    const m = await member(client, req.params.channelId, req.user.id);
    if (!m) return fail(res, 403, 'You are not a chat member.');

    const kind = req.body.kind === 'image' ? 'image' : req.body.kind === 'audio' ? 'audio' : 'text';

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
    } else if (kind === 'audio') {
      // A voice note: the uploaded clip's URL, its mime, and how long it runs.
      // validateMediaUrl pins it to the app's own media host exactly as images are.
      const media = access.validateMediaUrl(req.body.mediaUrl, { label: 'Voice note', required: true });
      if (!media.ok) return fail(res, 400, media.message);
      insert.mediaUrl = media.value;
      insert.mediaMime = typeof req.body.mediaMime === 'string' ? req.body.mediaMime.slice(0, 60) : null;
      const dur = Number.isFinite(+req.body.durationMs) ? Math.trunc(+req.body.durationMs) : 0;
      // Capped at ten minutes so a runaway recording cannot store an arbitrary blob.
      insert.durationMs = Math.max(0, Math.min(dur, 10 * 60 * 1000));
      // The amplitude samples the waveform is drawn from. Client-supplied, so kept
      // only as an array of finite numbers, each clamped to 0..1 and the whole
      // capped at 64 bars — a crafted body cannot store an unbounded blob. The
      // waveform column has existed since migration 015; null when none was sent.
      if (Array.isArray(req.body.waveform)) {
        const bars = req.body.waveform
          .filter((n) => Number.isFinite(+n))
          .slice(0, 64)
          .map((n) => Math.max(0, Math.min(1, Math.round(+n * 1000) / 1000)));
        insert.waveform = bars.length ? JSON.stringify(bars) : null;
      }
    } else {
      const body = access.squashMultiline(req.body.body || '');
      if (!body) return fail(res, 400, 'Message cannot be empty.');
      if (body.length > 4000) return fail(res, 400, 'Message is too long.');
      insert.body = body;
    }

    // Reply/quote: a message may quote an earlier one in the SAME channel. The
    // parent is validated here rather than trusted — a reply_to_id pointing at
    // another channel would let the quote leak a line from a room the sender
    // cannot see. A deleted parent is still a valid target (its row is a
    // tombstone), and the quote then renders as "This message was deleted".
    if (req.body.replyToId != null) {
      if (!access.isUuid(req.body.replyToId)) return fail(res, 400, 'That message cannot be replied to.');
      const parent = (await client.query(
        'SELECT id FROM chat_messages WHERE id = $1 AND channel_id = $2',
        [req.body.replyToId, req.params.channelId],
      )).rows[0];
      if (!parent) return fail(res, 400, 'The message being replied to is not in this chat.');
      insert.replyToId = req.body.replyToId;
    }

    // @mentions: the client sends the resolved user ids (built from a member
    // picker). They are filtered to live members of this channel by
    // chat.setMentions after the insert, so nothing is trusted from the body here.
    const mentionIds = Array.isArray(req.body.mentions)
      ? req.body.mentions.filter((id) => typeof id === 'string').slice(0, 50)
      : [];

    await client.query('BEGIN');
    const out = await chat.insertMessage(client, insert);
    // Inside the same transaction as the insert, and only for a message that was
    // new: a retried clientId returns the original row, and notifying again
    // would ping a phone twice for one message. chatCore skips anybody with the thread
    // open or the channel muted, and is SAVEPOINT-wrapped so a notifications failure
    // cannot roll the message back.
    if (!out.duplicate) {
      const mentioned = await chat.setMentions(client, {
        channelId: req.params.channelId, messageId: out.message.id, userIds: mentionIds,
      });
      await chat.notifyNewMessage(client, {
        channelId: req.params.channelId, message: out.message, mentionedIds: mentioned,
      });
    }
    await client.query('COMMIT');

    const hydrated = await chat.emitPersistedMessage(client, req.params.channelId, out.message.id);
    // The second tick. emitPersistedMessage has just put the row on every online
    // member's socket, so for those members delivered is now a fact — and nothing
    // else was recording it: the mark only moved when a socket CONNECTED, which
    // meant a recipient who was already online when the message landed kept a
    // watermark older than it and the sender's second tick never appeared. Only
    // for a genuinely new message; a retried clientId has already been delivered.
    if (!out.duplicate) {
      await receipts.markDeliveredToOnline(pool, {
        channelId: req.params.channelId, senderId: req.user.id,
      });
    }
    return res.status(out.duplicate ? 200 : 201).json({ success: true, data: hydrated || out.message });
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    next(e);
  } finally { client.release(); }
});

// Read MARK  (blue tick)

/**
 * Mark the channel read up to `at` (or now). The watermark only ever moves
 * forwards (chatReceipts uses GREATEST), so a late-arriving mark cannot turn read
 * messages unread again. This is the REST counterpart of the socket
 * `message:read` event — used when the app is foregrounded but the socket has not
 * yet (re)connected — and it goes through the same helper, which is what makes it
 * broadcast the resulting receipt. It used to write the row and tell nobody, so a
 * read performed on this path left the sender's ticks grey until their next
 * refetch.
 */
router.post('/:channelId/read', async (req, res, next) => {
  try {
    if (!access.isUuid(req.params.channelId)) return fail(res, 404, 'Chat not found.');
    const marks = await receipts.markRead(pool, {
      channelId: req.params.channelId,
      userId: req.user.id,
      at: req.body.at || null,
    });
    if (!marks) return fail(res, 403, 'You are not a chat member.');
    return ok(res, { read: true, ...marks });
  } catch (e) { next(e); }
});

// Members  (the tick watermarks + last-seen, for the client to compute ticks)

/**
 * Every live member with their read/delivered watermarks and last-seen. The chat
 * screen loads this once, then keeps the marks current from live `receipt` events;
 * the group tick for one of my messages is min(other members' mark) vs its time.
 *
 * `history_from` is part of that computation and not incidental: a member who
 * joined after a message was sent cannot see it, so they must not hold its ticks
 * at one grey forever. The client skips them for messages older than their
 * window.
 */
router.get('/:channelId/members', async (req, res, next) => {
  const client = await pool.connect();
  try {
    const m = await member(client, req.params.channelId, req.user.id);
    if (!m) return fail(res, 403, 'You are not a chat member.');
    const { rows } = await client.query(
      `SELECT cm.user_id, cm.role, cm.last_read_at, cm.last_delivered_at,
              cm.history_from,
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

// DELETE FOR me  (033)
//
// Hides one message from the caller's own history and nothing more: the row is
// untouched, every other member still sees it, and the sender is not told. No
// socket event and no pill — a hide is private housekeeping, not an action on the
// conversation, which is why it is a plain insert rather than a tombstone.
//
// Any member may hide any message they can see, including somebody else's and
// including a message they are not allowed to delete for everyone.
router.post('/:channelId/messages/:messageId/hide', async (req, res, next) => {
  const client = await pool.connect();
  try {
    const m = await member(client, req.params.channelId, req.user.id);
    if (!m) return fail(res, 403, 'You are not a chat member.');
    if (!access.isUuid(req.params.messageId)) return fail(res, 404, 'Message not found.');

    // Scoped to the channel the caller proved membership of, so a message id from
    // another room cannot be hidden (harmless, but it would be an unchecked write).
    const msg = (await client.query(
      'SELECT id FROM chat_messages WHERE id = $1 AND channel_id = $2',
      [req.params.messageId, req.params.channelId],
    )).rows[0];
    if (!msg) return fail(res, 404, 'Message not found.');

    await client.query(
      `INSERT INTO chat_message_hides (message_id, user_id) VALUES ($1, $2)
       ON CONFLICT (message_id, user_id) DO NOTHING`,
      [req.params.messageId, req.user.id],
    );
    return ok(res, { hidden: true });
  } catch (e) { next(e); } finally { client.release(); }
});

// PIN  (a channel admin pins a message to the top of the thread)
//
// Pinning is an admin power — the same authority that deletes anyone's message: in
// a booking room the owner, in a team or captain room the captains. It is not a
// power over one's own message the way delete is: a plain member cannot pin even
// their own line, because a pin is an announcement to the whole room. Pinning
// posts a visible "X pinned a message" pill so everyone knows an announcement was
// made; unpinning is silent. The live signal is 'chat:pinned', a channel-wide
// nudge telling every open client to refetch GET /pinned rather than a payload
// each would have to merge into its own banner state.

/**
 * GET the channel's pinned messages, newest pin first — the banner's source.
 *
 * Bounded by the reader's history window (036) for the same reason the timeline
 * is: a pinned announcement from before somebody joined is still a message they
 * may not read, and the banner shows its text on open.
 */
router.get('/:channelId/pinned', async (req, res, next) => {
  const client = await pool.connect();
  try {
    const m = await member(client, req.params.channelId, req.user.id);
    if (!m) return fail(res, 403, 'You are not a chat member.');
    return ok(res, await chat.listPinned(client, req.params.channelId, 20, m.history_from));
  } catch (e) { next(e); } finally { client.release(); }
});

router.post('/:channelId/messages/:messageId/pin', async (req, res, next) => {
  const client = await pool.connect();
  try {
    const m = await member(client, req.params.channelId, req.user.id);
    if (!m) return fail(res, 403, 'You are not a chat member.');
    if (m.role !== 'admin') return fail(res, 403, 'Only an admin can pin a message.');
    if (!access.isUuid(req.params.messageId)) return fail(res, 404, 'Message not found.');

    const msg = (await client.query(
      'SELECT id, kind, deleted_at, pinned_at FROM chat_messages WHERE id = $1 AND channel_id = $2',
      [req.params.messageId, req.params.channelId],
    )).rows[0];
    if (!msg) return fail(res, 404, 'Message not found.');
    if (msg.deleted_at) return fail(res, 400, 'A deleted message cannot be pinned.');
    if (msg.kind === 'system') return fail(res, 400, 'That message cannot be pinned.');
    if (msg.pinned_at) {
      // Already pinned: return it unchanged, without a second pill.
      return ok(res, await chat.hydrateMessage(client, req.params.messageId));
    }

    const actorName = (await client.query('SELECT name FROM users WHERE id = $1', [req.user.id]))
      .rows[0]?.name || 'Someone';

    await client.query('BEGIN');
    await chat.setPinned(client, { messageId: req.params.messageId, pinned: true, by: req.user.id });
    const pill = await chat.announceInRoom(client, req.params.channelId, 'message_pinned', {
      actorId: req.user.id, actorName,
    });
    await client.query('COMMIT');

    // The updated bubble (pinned_at now set), the pill, and a channel-wide signal
    // so every open client refreshes its pinned banner.
    const hydrated = await chat.emitPersistedMessage(client, req.params.channelId, req.params.messageId);
    if (pill) await chat.emitPills(client, pill);
    await chat.emitPinnedChanged(client, req.params.channelId);
    return ok(res, hydrated);
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    next(e);
  } finally { client.release(); }
});

router.delete('/:channelId/messages/:messageId/pin', async (req, res, next) => {
  const client = await pool.connect();
  try {
    const m = await member(client, req.params.channelId, req.user.id);
    if (!m) return fail(res, 403, 'You are not a chat member.');
    if (m.role !== 'admin') return fail(res, 403, 'Only an admin can unpin a message.');
    if (!access.isUuid(req.params.messageId)) return fail(res, 404, 'Message not found.');

    const msg = (await client.query(
      'SELECT id, pinned_at FROM chat_messages WHERE id = $1 AND channel_id = $2',
      [req.params.messageId, req.params.channelId],
    )).rows[0];
    if (!msg) return fail(res, 404, 'Message not found.');
    if (!msg.pinned_at) return ok(res, { unpinned: true }); // idempotent

    await chat.setPinned(client, { messageId: req.params.messageId, pinned: false });
    // Silent — no pill. Refresh the bubble and nudge the banner.
    const hydrated = await chat.emitPersistedMessage(client, req.params.channelId, req.params.messageId);
    await chat.emitPinnedChanged(client, req.params.channelId);
    return ok(res, hydrated || { unpinned: true });
  } catch (e) { next(e); } finally { client.release(); }
});

// POLLS  (a WhatsApp-style poll posted into the room)
//
// A poll is a message of kind 'poll' whose body is the question; the ballot and
// the votes live in chat_polls / chat_poll_votes. Any MEMBER OF A GROUP may create
// one and any member may vote — a poll is a group question, not an admin
// announcement, so it is not gated the way pinning is. Creating and voting both
// re-push the poll message to the room so every open client sees the new tally at
// once.
//
// It IS gated on the room having a group in it (POLL_MIN_MEMBERS). A poll offered
// in a one-to-one chat — a player and a venue owner, two captains — is a ballot
// between two people who can simply answer each other, and it was reaching both
// of those rooms. The client hides the entry point on the same rule; this is the
// half that makes it true, since a hidden button is not a restriction.
router.post('/:channelId/polls', async (req, res, next) => {
  const client = await pool.connect();
  try {
    const m = await member(client, req.params.channelId, req.user.id);
    if (!m) return fail(res, 403, 'You are not a chat member.');

    if (await liveMemberCount(client, req.params.channelId) < POLL_MIN_MEMBERS) {
      return fail(res, 400, 'Polls are for group chats. Just ask them directly.');
    }

    const question = access.squashMultiline(req.body.question || '');
    if (!question) return fail(res, 400, 'A poll needs a question.');
    if (question.length > 300) return fail(res, 400, 'The question is too long.');

    const options = (Array.isArray(req.body.options) ? req.body.options : [])
      .map((o) => access.squashMultiline(String(o || '')).slice(0, 100))
      .filter((o) => o.length > 0)
      .slice(0, 12);
    if (options.length < 2) return fail(res, 400, 'A poll needs at least two options.');

    const allowMultiple = req.body.allowMultiple === true;

    await client.query('BEGIN');
    const messageId = await chat.createPoll(client, {
      channelId: req.params.channelId,
      userId: req.user.id,
      question,
      options,
      allowMultiple,
    });
    await client.query('COMMIT');

    const hydrated = await chat.emitPersistedMessage(client, req.params.channelId, messageId);
    // A poll is a message, so it earns the same second tick as one.
    await receipts.markDeliveredToOnline(pool, {
      channelId: req.params.channelId, senderId: req.user.id,
    });
    return ok(res, hydrated);
  } catch (e) {
    try { await client.query('ROLLBACK'); } catch (_) { /* already resolved */ }
    next(e);
  } finally { client.release(); }
});

router.post('/:channelId/polls/:pollId/vote', async (req, res, next) => {
  const client = await pool.connect();
  try {
    const m = await member(client, req.params.channelId, req.user.id);
    if (!m) return fail(res, 403, 'You are not a chat member.');
    if (!access.isUuid(req.params.pollId)) return fail(res, 404, 'Poll not found.');

    const optionIndex = Number.isInteger(+req.body.optionIndex) ? +req.body.optionIndex : -1;
    const r = await chat.votePoll(client, {
      channelId: req.params.channelId,
      pollId: req.params.pollId,
      userId: req.user.id,
      optionIndex,
    });
    if (!r.ok) return fail(res, r.status, r.message);

    const hydrated = await chat.emitPersistedMessage(client, r.channelId, r.messageId);
    return ok(res, hydrated);
  } catch (e) { next(e); } finally { client.release(); }
});

// Shared media  (the "all photos in this chat" gallery)

/**
 * GET the channel's shared photos, newest first, paginated on `before` (a
 * created_at cursor, like history). Served by idx_chat_messages_media (015), and
 * bounded below by the reader's history window (036) — the gallery is the second
 * door into a room's backlog and must not be a way around the first.
 */
router.get('/:channelId/media', async (req, res, next) => {
  const client = await pool.connect();
  try {
    const m = await member(client, req.params.channelId, req.user.id);
    if (!m) return fail(res, 403, 'You are not a chat member.');
    const limit = Math.min(Math.max(Number(req.query.limit) || 60, 1), 100);
    return ok(res, await chat.listMedia(client, {
      channelId: req.params.channelId,
      before: req.query.before || null,
      limit,
      since: m.history_from,
    }));
  } catch (e) { next(e); } finally { client.release(); }
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

// Hide (clear) a conversation for the caller only

/**
 * POST /api/chat/:channelId/hide — body `{hidden}` (default true).
 *
 * WhatsApp's "Delete chat": drops the room from THIS member's inbox and leaves
 * every other member's untouched. It is a per-member view watermark (hidden_at,
 * migration 027), not a delete of any message and not a leave — the caller stays a
 * live member, keeps receiving messages, and the room reappears the moment one
 * arrives after the stamp. `{hidden:false}` restores it immediately.
 *
 * Membership is proved first, exactly like mute, so a stranger cannot clear a room
 * they were never in.
 */
router.post('/:channelId/hide', async (req, res, next) => {
  const client = await pool.connect();
  try {
    const m = await member(client, req.params.channelId, req.user.id);
    if (!m) return fail(res, 403, 'You are not a chat member.');
    const at = (req.body || {}).hidden === false ? null : 'now';
    return ok(res, await list.setHidden(client, {
      channelId: m.id, userId: req.user.id, at,
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
