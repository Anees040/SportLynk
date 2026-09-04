/**
 * assistantThreads.js — Scout's chat threads, on the existing chat tables.
 *
 * Why not a new table
 * The user asked for the affordances a general-purpose assistant has: history,
 * new chat, switch chat, rename. That is a channel with messages, which the chat
 * module already is. Migration 018 therefore added `type='assistant'` to
 * chk_chat_channels_type and three columns (session_state, archived_at,
 * assistant_persona) rather than building a parallel messaging stack that would
 * need its own pagination, its own soft-delete and its own Flutter list widget.
 *
 * What makes an ASSISTANT channel different
 *   ref_id IS NULL       a Scout thread points at no team and no booking, which
 *                        is what lets one user own many of them. The unique index
 *                        ux_chat_channels_type_ref does not apply to NULL ref_id
 *                        — probe 5a in run_migration_018.js proves it, and "new
 *                        chat" stands entirely on that fact.
 *   created_by           the owning user. There is no membership row: a Scout
 *                        thread is private by construction, and every read here
 *                        filters on created_by so it stays that way.
 *   session_state        the dialog manager's whole memory for the thread.
 *   kind='assistant'     Scout's own messages, with the reply payload in
 *                        assistant_payload so Flutter can re-render the cards of
 *                        an old turn instead of showing a bare sentence.
 *
 * The utterance lives here and only here
 * doc/CLAUDE.md forbids logging the user's message. That ban is about logs and
 * telemetry: assistant_turns holds text_chars and no text. The text itself has to
 * exist somewhere for a chat history to exist at all, and this is that place —
 * inside the user's own access-controlled thread, which they can delete.
 */
const pool = require('../db/pool');
const chat = require('../utils/chatCore');

/** A brand-new thread's title, until the first user message renames it. */
const DEFAULT_TITLE = 'New chat';

/** Thread cap per user, so a loop in a client cannot fill the table. */
const MAX_THREADS = 50;

/** `session_state.v` — bumped when the state shape changes incompatibly. */
const STATE_VERSION = 1;

/** The empty state a fresh thread starts with, and what a reset returns to. */
function freshState() {
  return { v: STATE_VERSION, intent: null, slots: {}, pending: null, confirm: null, ctx: {} };
}

/**
 * Read session_state defensively.
 *
 * An unknown version is reset, not migrated. A half-understood state is how a
 * dialog manager ends up confirming a booking the user never asked for, and the
 * cost of a reset is one re-asked question.
 */
function readState(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return freshState();
  if (raw.v !== STATE_VERSION) return freshState();
  return {
    v: STATE_VERSION,
    intent: typeof raw.intent === 'string' ? raw.intent : null,
    slots: raw.slots && typeof raw.slots === 'object' && !Array.isArray(raw.slots) ? raw.slots : {},
    pending: typeof raw.pending === 'string' ? raw.pending : null,
    confirm: raw.confirm && typeof raw.confirm === 'object' ? raw.confirm : null,
    ctx: raw.ctx && typeof raw.ctx === 'object' && !Array.isArray(raw.ctx) ? raw.ctx : {},
  };
}

/** Title from the first thing the user said, the way every chat app does it. */
function titleFrom(text) {
  const t = String(text || '').replace(/\s+/g, ' ').trim();
  if (!t) return DEFAULT_TITLE;
  return t.length <= 42 ? t : `${t.slice(0, 39).trimEnd()}...`;
}

/** One thread, only if this user owns it. Returns null otherwise — not a throw. */
async function get(client, { userId, threadId } = {}) {
  const { rows } = await (client || pool).query(
    `SELECT id, title, session_state, archived_at, assistant_persona,
            created_at, last_message_at, last_message_preview, message_count
       FROM chat_channels
      WHERE id = $1 AND type = 'assistant' AND created_by = $2`,
    [threadId, userId],
  );
  return rows[0] || null;
}

/** This user's threads, newest activity first. Archived ones are hidden by default. */
async function list(client, { userId, includeArchived = false, limit = 30 } = {}) {
  const { rows } = await (client || pool).query(
    `SELECT id, title, archived_at, assistant_persona, created_at,
            last_message_at, last_message_preview, message_count
       FROM chat_channels
      WHERE type = 'assistant' AND created_by = $1
        AND ($2::boolean OR archived_at IS NULL)
      ORDER BY COALESCE(last_message_at, created_at) DESC
      LIMIT $3`,
    [userId, includeArchived, Math.max(1, Math.min(100, limit))],
  );
  return rows;
}

/**
 * Start a thread. `persona` is 'player' or 'owner' — the same Scout, but the owner
 * side answers about a ground the user owns rather than one they want to book.
 */
async function create(client, { userId, title = null, persona = 'player' } = {}) {
  const runner = client || pool;
  const { rows: [{ n }] } = await runner.query(
    `SELECT count(*)::int n FROM chat_channels
      WHERE type = 'assistant' AND created_by = $1 AND archived_at IS NULL`,
    [userId],
  );
  if (n >= MAX_THREADS) {
    return { ok: false, code: 'too_many_threads', status: 409, row: null,
      message: `You have ${n} open chats. Archive one to start another.` };
  }
  const { rows } = await runner.query(
    `INSERT INTO chat_channels (type, ref_id, title, created_by, session_state, assistant_persona)
     VALUES ('assistant', NULL, $1, $2, $3::jsonb, $4)
     RETURNING id, title, session_state, archived_at, assistant_persona, created_at,
               last_message_at, last_message_preview, message_count`,
    [title || DEFAULT_TITLE, userId, JSON.stringify(freshState()),
      persona === 'owner' ? 'owner' : 'player'],
  );
  return { ok: true, code: 'ok', status: 201, row: rows[0], message: null };
}

/** Find this user's most recent open thread, or start one. */
async function getOrCreate(client, { userId, threadId = null, persona = 'player' } = {}) {
  if (threadId) {
    const found = await get(client, { userId, threadId });
    if (found) return { ok: true, row: found, created: false };
    return { ok: false, code: 'thread_not_found', status: 404, row: null, created: false,
      message: 'That chat does not exist.' };
  }
  const open = await list(client, { userId, limit: 1 });
  if (open.length) {
    // Re-read through get(): `list` deliberately omits session_state (a list of 30
    // threads has no use for 30 dialog states, and a `confirm` block has no business
    // in a list view), so returning its row here would hand the dialog manager a row
    // with session_state undefined. readState() would then reset to a fresh state on
    // every turn and Scout would forget the question it had just asked -- for exactly
    // the clients that do not echo a session_id back, which is the default case.
    const full = await get(client, { userId, threadId: open[0].id });
    if (full) return { ok: true, row: full, created: false };
  }
  const made = await create(client, { userId, persona });
  return { ...made, created: made.ok };
}

/** Persist the dialog state. Written once per turn, at the end. */
async function saveState(client, { threadId, state } = {}) {
  await (client || pool).query(
    'UPDATE chat_channels SET session_state = $2::jsonb WHERE id = $1',
    [threadId, JSON.stringify({ ...freshState(), ...state, v: STATE_VERSION })],
  );
}

/** Rename ("new name"), archive or un-archive — all owner-checked. */
async function update(client, { userId, threadId, title, archived } = {}) {
  const sets = [];
  const args = [threadId, userId];
  if (typeof title === 'string') {
    const clean = title.replace(/\s+/g, ' ').trim().slice(0, 60);
    if (!clean) return { ok: false, code: 'bad_title', status: 400, row: null,
      message: 'A chat name cannot be empty.' };
    args.push(clean);
    sets.push(`title = $${args.length}`);
  }
  if (typeof archived === 'boolean') {
    sets.push(archived ? 'archived_at = NOW()' : 'archived_at = NULL');
  }
  if (!sets.length) {
    return { ok: false, code: 'nothing_to_do', status: 400, row: null,
      message: 'Send a title or an archived flag.' };
  }
  const { rows } = await (client || pool).query(
    `UPDATE chat_channels SET ${sets.join(', ')}
      WHERE id = $1 AND type = 'assistant' AND created_by = $2
      RETURNING id, title, archived_at, assistant_persona, created_at,
                last_message_at, last_message_preview, message_count`,
    args,
  );
  if (!rows.length) {
    return { ok: false, code: 'thread_not_found', status: 404, row: null,
      message: 'That chat does not exist.' };
  }
  return { ok: true, code: 'ok', status: 200, row: rows[0], message: null };
}

/** Delete a thread and its messages (chat_messages cascades on channel_id). */
async function remove(client, { userId, threadId } = {}) {
  const { rowCount } = await (client || pool).query(
    `DELETE FROM chat_channels WHERE id = $1 AND type = 'assistant' AND created_by = $2`,
    [threadId, userId],
  );
  return rowCount > 0
    ? { ok: true, code: 'ok', status: 200, message: 'Chat deleted.' }
    : { ok: false, code: 'thread_not_found', status: 404, message: 'That chat does not exist.' };
}

// Messages

/**
 * Write one message into a thread through utils/chatCore.insertMessage — the
 * same function routes/chat.js uses. That is deliberate: last_message_at,
 * last_message_preview, last_message_sender_id and message_count are maintained
 * in exactly one place, so a Scout thread and a team thread can never drift into
 * showing their previews differently. chatCore gained one optional parameter
 * (assistantPayload) for the 018 column; nothing else about it changed.
 *
 * `who` is 'user' or 'scout'. A Scout row is kind='assistant' with sender_id
 * NULL (015 made sender_id nullable for system rows) and the reply payload in
 * assistant_payload, so an old turn re-renders with its cards instead of
 * degrading to a bare sentence when the user scrolls back.
 *
 * The first user message also names the thread, which is the "New chat" → real
 * title behaviour of a general assistant, done without asking the user to type
 * a name. An explicit rename via update() wins forever after: once the title is
 * not DEFAULT_TITLE it is never touched again.
 */
async function appendMessage(client, {
  threadId, userId, who, text, payload = null, clientId = null,
} = {}) {
  const runner = client || pool;
  const body = String(text == null ? '' : text).replace(/\s+/g, ' ').trim().slice(0, 4000);
  if (!body) return { ok: false, code: 'empty_message', status: 400, row: null };

  const scout = who === 'scout';
  const out = await chat.insertMessage(runner, {
    channelId: threadId,
    senderId: scout ? null : userId,
    clientId: scout ? null : clientId,
    kind: scout ? 'assistant' : 'text',
    body,
    assistantPayload: scout && payload ? JSON.stringify(payload) : null,
  });

  if (!scout) {
    await runner.query(
      `UPDATE chat_channels SET title = left($2, 42)
        WHERE id = $1 AND (title IS NULL OR title = $3)`,
      [threadId, titleFrom(body), DEFAULT_TITLE],
    );
  }
  return { ok: true, code: 'ok', status: 201, row: out.message, duplicate: out.duplicate };
}

/**
 * A page cursor is the ID of the oldest message on the page, and the sort key it
 * stands for is resolved server-side from that id. Two facts forced this shape:
 *
 * 1. chat_messages.created_at defaults to NOW(), and NOW() in Postgres is the
 *    transaction timestamp, not the statement's. One Scout turn writes the
 *    user's message and Scout's reply in a single transaction — deliberately, so
 *    a booking can never be recorded without the sentence that asked for it — so
 *    those two rows carry a byte-identical created_at. Ordering by created_at
 *    alone put Scout's answer above the question (observed, not theorised), so
 *    the sort key is (created_at, is_assistant, id): within one timestamp the
 *    user speaks before Scout, which is exactly what a turn means, and `id`
 *    makes the order total.
 * 2. A cursor carrying that timestamp as text does not work: node-postgres
 *    parses timestamptz into a JS Date, which is millisecond-precision, so the
 *    microseconds are silently dropped and the ">" comparison then skips the
 *    row it was supposed to resume at. Also observed, in this file's own probe.
 *
 * Passing the id and letting the SQL look up the exact key avoids both.
 */
function encodeCursor(row) {
  return row && row.id ? String(row.id) : null;
}

/** Validate a cursor. Junk from a client is treated as "no cursor", not an error. */
function decodeCursor(raw) {
  return typeof raw === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(raw)
    ? raw : null;
}

/**
 * One page of a thread, oldest-first for rendering, walking backwards from
 * `before` (a cursor from a previous page) so an infinite scroll never uses
 * OFFSET.
 *
 * Ownership is re-checked in the JOIN rather than trusted from the caller: a
 * message read is the one place where a wrong thread id would leak another
 * user's conversation, so the WHERE clause carries created_by even though every
 * route that calls this has already looked the thread up.
 */
async function history(client, {
  userId, threadId, limit = 40, before = null,
} = {}) {
  const n = Math.max(1, Math.min(100, Number(limit) || 40));
  const cur = decodeCursor(before);
  const { rows } = await (client || pool).query(
    `SELECT m.id, m.kind, m.body, m.assistant_payload, m.sender_id, m.created_at
       FROM chat_messages m
       JOIN chat_channels c ON c.id = m.channel_id
      WHERE c.id = $1 AND c.type = 'assistant' AND c.created_by = $2
        AND m.deleted_at IS NULL
        AND ($3::uuid IS NULL OR
             (m.created_at, (m.kind = 'assistant')::int, m.id) <
             (SELECT b.created_at, (b.kind = 'assistant')::int, b.id
                FROM chat_messages b WHERE b.id = $3::uuid AND b.channel_id = c.id))
      ORDER BY m.created_at DESC, (m.kind = 'assistant') DESC, m.id DESC
      LIMIT $4`,
    [threadId, userId, cur, n + 1],
  );
  const more = rows.length > n;
  const window = more ? rows.slice(0, n) : rows;
  const page = window.slice().reverse();
  return {
    messages: page.map((r) => ({
      id: r.id,
      role: r.kind === 'assistant' ? 'scout' : 'user',
      text: r.body,
      payload: r.assistant_payload || null,
      createdAt: r.created_at,
    })),
    hasMore: more,
    // The cursor for the next (older) page is the oldest row on this one.
    cursor: window.length ? encodeCursor(window[window.length - 1]) : null,
  };
}

/**
 * The last few turns, oldest-first, as flat text — what the dialog manager shows
 * itself when a follow-up ("aur koi?") only makes sense against what was just
 * said. It is context, not a prompt: there is no LLM here, and nothing in this
 * array reaches the classifier.
 */
async function recentTurns(client, { threadId, limit = 6 } = {}) {
  const { rows } = await (client || pool).query(
    `SELECT kind, body, assistant_payload FROM chat_messages
      WHERE channel_id = $1 AND deleted_at IS NULL
        AND kind IN ('text', 'assistant')
      ORDER BY created_at DESC, (kind = 'assistant') DESC, id DESC
      LIMIT $2`,
    [threadId, Math.max(1, Math.min(20, Number(limit) || 6))],
  );
  return rows.reverse().map((r) => ({
    role: r.kind === 'assistant' ? 'scout' : 'user',
    text: r.body,
    source: (r.assistant_payload && r.assistant_payload.source) || null,
  }));
}

module.exports = {
  DEFAULT_TITLE,
  MAX_THREADS,
  STATE_VERSION,
  freshState,
  readState,
  titleFrom,
  get,
  list,
  create,
  getOrCreate,
  saveState,
  update,
  remove,
  appendMessage,
  history,
  recentTurns,
  encodeCursor,
  decodeCursor,
};
