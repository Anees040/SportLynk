/**
 * routes/assistant.js — Scout's HTTP surface, and nothing else.
 *
 * Why this file is so thin
 * Every decision a turn needs is already owned somewhere else, and this file's job
 * is to not have an opinion:
 *
 *   services/dialogManager.js   what a turn means   (state machine, lexicon, abstain)
 *   services/assistantActions.js what it does       (26 actions, money, SAVEPOINTs)
 *   services/assistantThreads.js the chat list      (create, rename, page, delete)
 *   services/assistantKb.js      the owner Q&A      (escalate, answer, KB CRUD)
 *   utils/assistantReply.js      the payload shape  (text + chips + cards, 6 sources)
 *
 * So a handler here does three things: read the JWT, call one function, map its
 * `{ok, status, code, message}` onto the `{success, data, message}` envelope every
 * Flutter screen in this app already parses. If a handler in this file ever grows a
 * business rule, it is in the wrong file — that is FR8.15 for the transport layer.
 *
 * The caller is the JWT, always
 * `req.user.id` is the only user id that reaches a service. No handler reads a user
 * id from a body or a query, which is what stops "book for someone else" and "read
 * another player's chats" from being one forged field away.
 *
 * Why /message takes either text or action
 * The wave spec's "no free-text-only dead ends" means every Scout reply ships chips,
 * and a tapped chip posts `{action, args, text: <its label>}` instead of a sentence.
 * That is not a second endpoint: it is the same turn with `input_mode='chip'`, and
 * keeping it here is what keeps chip traffic out of model #4's measured accuracy
 * while still landing in the same transcript.
 */

const express = require('express');
const pool = require('../db/pool');
const auth = require('../middleware/authMiddleware');
const checkRole = require('../middleware/roleMiddleware');
const access = require('../utils/teamAccess');
const dialog = require('../services/dialogManager');
const threads = require('../services/assistantThreads');
const kb = require('../services/assistantKb');
const actions = require('../services/assistantActions');
const { menu, CAPABILITIES } = require('../utils/assistantReply');

const router = express.Router();
router.use(auth);

const fail = (res, status, message) => res.status(status).json({ success: false, message });
const ok = (res, data, message = null) => res.json(
  message ? { success: true, data, message } : { success: true, data },
);

/**
 * A service's `{ok:false, status, message}` becomes the envelope, unchanged.
 * Nothing is invented here: if a service did not set a status, 400 is the honest
 * default for a rejected request.
 */
const relay = (res, out) => fail(res, out.status || 400, out.message || 'Request failed.');

/**
 * The chat this request belongs to.
 *
 * The spec's field is `session_id`; the services call it `threadId`. Both spellings
 * are accepted (plus camelCase) because Wave D's Flutter client is not written yet
 * and a 400 over a naming preference is a wasted afternoon. Absent is legal and
 * means "the newest chat, or a new one" — see threads.getOrCreate.
 */
function threadIdOf(body = {}, query = {}) {
  const raw = body.session_id || body.sessionId || body.threadId || body.thread_id
    || query.session_id || query.sessionId || query.threadId || null;
  const id = String(raw == null ? '' : raw).trim().toLowerCase();
  return access.isUuid(id) ? id : null;
}

// The turn

/**
 * POST /api/assistant/message — the one endpoint the chat screen needs.
 *
 * Body: `{text?, action?, args?, session_id?, client_id?}`; at least one of `text`
 * or `action`. Answers `{reply:{text,chips,cards,source}, threadId, state, nlu}`.
 *
 * A 500 still carries a `reply`, because a chat screen with an error toast and no
 * bubble looks broken in a way that a bubble saying "that did not save, try again"
 * does not. It is deliberately not persisted — the transaction rolled back, so it
 * must not reappear when the thread is reloaded.
 */
router.post('/message', async (req, res, next) => {
  try {
    const b = req.body || {};
    const out = await dialog.handleTurn({
      userId: req.user.id,
      threadId: threadIdOf(b, req.query),
      text: b.text,
      action: b.action || null,
      args: b.args || null,
      clientId: b.client_id || b.clientId || null,
      persona: req.user.role === 'owner' ? 'owner' : 'player',
    });
    if (!out.ok) {
      if (out.error) console.error('[assistant] turn failed:', out.error);
      return res.status(out.status || 400).json({
        success: false, message: out.message,
        data: out.reply ? { reply: out.reply, threadId: out.threadId || null } : null,
      });
    }
    return ok(res, {
      threadId: out.threadId,
      threadCreated: out.threadCreated,
      messageId: out.messageId,
      reply: out.reply,
      state: { fsm: dialog.fsmStateOf(out.state), pending: out.state.pending || null,
        intent: out.state.intent || null, slots: out.state.slots || {} },
      nlu: out.nlu,
      totalMs: out.totalMs,
    });
  } catch (e) { return next(e); }
});

// Threads — chat history, new chat, switch chat, rename, delete
//
// These four are the "generic assistant" affordances the user asked for by name.
// None of them is Scout-specific: a thread is a `chat_channels` row of type
// 'assistant', which is why it already has a title, a preview and a message count
// without a new table.

/** GET /threads — the drawer. `?archived=1` includes archived chats. */
router.get('/threads', async (req, res, next) => {
  try {
    const rows = await threads.list(pool, {
      userId: req.user.id,
      includeArchived: String(req.query.archived || '') === '1',
      limit: Number(req.query.limit) || 30,
    });
    return ok(res, { threads: rows, max: threads.MAX_THREADS });
  } catch (e) { return next(e); }
});

/** POST /threads — "new chat". A title is optional: the first message renames it. */
router.post('/threads', async (req, res, next) => {
  try {
    const out = await threads.create(pool, {
      userId: req.user.id,
      title: (req.body || {}).title || null,
      persona: req.user.role === 'owner' ? 'owner' : 'player',
    });
    if (!out.ok) return relay(res, out);
    return res.status(201).json({ success: true, data: { thread: out.row } });
  } catch (e) { return next(e); }
});

/**
 * GET /threads/:id/messages — one page of transcript, oldest-first within the page.
 *
 * `before` is an opaque cursor, not an offset: `created_at` is truncated to the
 * millisecond by node-postgres, so two messages written in the same millisecond
 * cannot be separated by a timestamp alone and the cursor carries an id too.
 */
router.get('/threads/:id/messages', async (req, res, next) => {
  try {
    const id = String(req.params.id || '').trim().toLowerCase();
    if (!access.isUuid(id)) return fail(res, 404, 'That chat does not exist.');
    const row = await threads.get(pool, { userId: req.user.id, threadId: id });
    if (!row) return fail(res, 404, 'That chat does not exist.');
    const page = await threads.history(pool, {
      userId: req.user.id, threadId: id,
      limit: Number(req.query.limit) || 40,
      before: req.query.before || null,
    });
    return ok(res, {
      thread: { id: row.id, title: row.title, persona: row.assistant_persona },
      ...page,
      state: { fsm: dialog.fsmStateOf(threads.readState(row.session_state)) },
    });
  } catch (e) { return next(e); }
});

/**
 * PATCH /threads/:id — rename ("new name") or archive.
 *
 * `{title}` renames, `{archived:true|false}` archives or restores, and both in one
 * body is legal. An empty title is a 400 rather than a silent revert to the default,
 * because a chat that renames itself back is a bug report waiting to happen.
 */
router.patch('/threads/:id', async (req, res, next) => {
  try {
    const id = String(req.params.id || '').trim().toLowerCase();
    if (!access.isUuid(id)) return fail(res, 404, 'That chat does not exist.');
    const b = req.body || {};
    const has = (k) => Object.prototype.hasOwnProperty.call(b, k);
    if (!has('title') && !has('archived')) {
      return fail(res, 400, 'Send a title or an archived flag.');
    }
    const out = await threads.update(pool, {
      userId: req.user.id, threadId: id,
      title: has('title') ? b.title : undefined,
      archived: has('archived') ? !!b.archived : undefined,
    });
    if (!out.ok) return relay(res, out);
    return ok(res, { thread: out.row }, out.message || null);
  } catch (e) { return next(e); }
});

/**
 * DELETE /threads/:id — gone, with its messages (ON DELETE CASCADE).
 *
 * The telemetry in `assistant_turns` survives deliberately: its channel_id is on
 * DELETE SET NULL, so deleting a chat removes the conversation without erasing the
 * evidence that model #4 answered n turns at m% abstention. Nothing in that table
 * contains what anyone said.
 */
router.delete('/threads/:id', async (req, res, next) => {
  try {
    const id = String(req.params.id || '').trim().toLowerCase();
    if (!access.isUuid(id)) return fail(res, 404, 'That chat does not exist.');
    const out = await threads.remove(pool, { userId: req.user.id, threadId: id });
    if (!out.ok) return relay(res, out);
    return ok(res, { deleted: true }, out.message);
  } catch (e) { return next(e); }
});

// Feedback and CAPABILITIES

/**
 * POST /messages/:id/feedback — thumbs up/down on one Scout message.
 *
 * This is the only SQL statement in this file, and it is here rather than in a
 * service because there is no rule to share: one row, keyed by (message, user), with
 * the ownership check inside the SELECT so a stranger's message id matches nothing
 * and gets a 404 instead of a vote. The UNIQUE constraint makes a vote changeable
 * and un-stuffable, so `ON CONFLICT DO UPDATE` is the whole write.
 *
 * Why it matters for the committee: confidence cannot tell a 0.93 hit from a 0.93
 * misclassification, and this is the only column in the schema that can.
 */
router.post('/messages/:id/feedback', async (req, res, next) => {
  try {
    const id = String(req.params.id || '').trim().toLowerCase();
    if (!access.isUuid(id)) return fail(res, 404, 'That message does not exist.');
    const raw = (req.body || {}).vote;
    const vote = raw === 1 || raw === '1' || raw === 'up' ? 1
      : (raw === -1 || raw === '-1' || raw === 'down' ? -1 : null);
    if (vote === null) return fail(res, 400, 'Vote must be up (1) or down (-1).');
    const reason = String((req.body || {}).reason || '').trim().slice(0, 300) || null;
    const { rows } = await pool.query(
      `INSERT INTO assistant_feedback (message_id, user_id, vote, reason)
       SELECT m.id, $2, $3, $4
         FROM chat_messages m
         JOIN chat_channels c ON c.id = m.channel_id
        WHERE m.id = $1 AND m.kind = 'assistant'
          AND c.type = 'assistant' AND c.created_by = $2
       ON CONFLICT (message_id, user_id)
         DO UPDATE SET vote = EXCLUDED.vote, reason = EXCLUDED.reason, created_at = NOW()
       RETURNING id, vote`,
      [id, req.user.id, vote, reason],
    );
    if (!rows.length) return fail(res, 404, 'That message does not exist.');
    return ok(res, { feedbackId: rows[0].id, vote: rows[0].vote }, 'Thanks — noted.');
  } catch (e) { return next(e); }
});

/**
 * GET /capabilities — ER2.6 as data, so the Flutter help sheet and the abstain menu
 * can never list different abilities. `groups` is the render order; `menu()` builds
 * the same payload a turn would return, chips included.
 */
router.get('/capabilities', (req, res) => ok(res, {
  capabilities: CAPABILITIES,
  actions: actions.intentLabels(),
  menu: menu(null, {}),
}));

// The owner side — "what is Scout telling players about my ground?"
//
// This half is what makes the assistant's learning loop legitimate rather than a
// black box. A player asks something no query can answer, the owner answers it once,
// and Scout serves that answer to everyone who asks again with `source: 'kb'`.
//
// Three rules hold across every endpoint below
//   1. checkRole('owner') gates the surface, and ownership of the venue — resolved
//      through venues.owner_id inside assistantKb, never from a client-supplied
//      owner id — gates every individual row. An owner cannot read, answer or edit
//      anything attached to somebody else's ground.
//   2. Money and policy are out of bounds. assistantKb.BLOCKED_INTENTS keeps those
//      questions out of the queue in the first place, so an owner can never redefine
//      the refund rules by answering a question about them.
//   3. Answering is transactional. kb.answer() takes a row lock (FOR UPDATE of e),
//      writes the KB row, closes the escalation, posts into the player's own thread
//      and notifies them — either all of that happens or none of it does, so a player
//      is never notified about an answer that failed to save.
// `auth` already ran for the whole router (line 47), so this is the role gate only.
const owner = checkRole('owner');

/**
 * GET /owner/questions?status=open|answered|declined|all
 *
 * The queue, open items first and oldest first within that — a question waiting three
 * days should not sit under one asked this morning.
 */
router.get('/owner/questions', owner, async (req, res, next) => {
  try {
    const status = ['open', 'answered', 'declined', 'all']
      .includes(String(req.query.status || '')) ? String(req.query.status) : 'open';
    const rows = await kb.listOwnerQuestions(pool, {
      ownerId: req.user.id, status, limit: Number(req.query.limit) || 50,
    });
    return ok(res, { questions: rows, status, blockedIntents: kb.BLOCKED_INTENTS });
  } catch (e) { return next(e); }
});

/**
 * POST /owner/questions/:id/answer  {answer, publish?}
 *
 * The whole loop in one transaction — see rule 3 above. `publish: false` saves the
 * answer as a draft: the player still gets it, but Scout will not reuse it until the
 * owner publishes, which is the escape hatch for a one-off reply.
 */
router.post('/owner/questions/:id/answer', owner, async (req, res, next) => {
  const id = String(req.params.id || '').trim().toLowerCase();
  if (!access.isUuid(id)) return fail(res, 404, 'That question no longer exists.');
  const body = req.body || {};
  const text = String(body.answer || body.text || '').trim();
  const publish = body.publish === undefined ? true : !!body.publish;
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const out = await kb.answer(client, {
      escalationId: id, ownerId: req.user.id, answerText: text, publish,
    });
    if (!out.ok) {
      await client.query('ROLLBACK');
      return relay(res, out);
    }
    await client.query('COMMIT');
    return ok(res, {
      kb: out.row, delivered: out.delivered, published: publish,
      escalationId: id,
    }, out.message);
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    return next(e);
  } finally {
    client.release();
  }
});

/**
 * POST /owner/questions/:id/decline  {reason?}
 *
 * Closes the item and tells the player, because silence is the worst outcome of an
 * escalation: they asked, nobody answered, and Scout looks broken. No KB row is
 * written — a declined question must not teach Scout anything.
 */
router.post('/owner/questions/:id/decline', owner, async (req, res, next) => {
  const id = String(req.params.id || '').trim().toLowerCase();
  if (!access.isUuid(id)) return fail(res, 404, 'That question no longer exists.');
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const out = await kb.decline(client, {
      escalationId: id, ownerId: req.user.id,
      reason: String((req.body || {}).reason || '').trim().slice(0, 300) || null,
    });
    if (!out.ok) {
      await client.query('ROLLBACK');
      return relay(res, out);
    }
    await client.query('COMMIT');
    return ok(res, { escalationId: id, status: 'declined' }, out.message);
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    return next(e);
  } finally {
    client.release();
  }
});

/**
 * GET /owner/kb?venue_id=&status=
 *
 * Everything Scout says on this owner's behalf, with the serve counters — the audit
 * view. An owner who cannot see what the assistant is repeating for them cannot be
 * asked to take responsibility for it.
 */
router.get('/owner/kb', owner, async (req, res, next) => {
  try {
    const venueId = String(req.query.venue_id || req.query.venueId || '').trim().toLowerCase();
    const status = String(req.query.status || '').trim();
    const rows = await kb.listKb(pool, {
      ownerId: req.user.id,
      venueId: access.isUuid(venueId) ? venueId : null,
      status: ['draft', 'published', 'rejected', 'archived'].includes(status) ? status : null,
      limit: Number(req.query.limit) || 100,
    });
    return ok(res, { entries: rows });
  } catch (e) { return next(e); }
});

/**
 * POST /owner/kb  {venue_id, question, answer, status?}
 *
 * Pre-empting a question instead of waiting to be asked — "no floodlights", "parking
 * at the back". Same table, same matcher, `source: 'owner'`.
 */
router.post('/owner/kb', owner, async (req, res, next) => {
  try {
    const b = req.body || {};
    const venueId = String(b.venue_id || b.venueId || '').trim().toLowerCase();
    if (!access.isUuid(venueId)) return fail(res, 400, 'Which venue is this answer for?');
    const out = await kb.upsertKb(pool, {
      ownerId: req.user.id, venueId,
      question: b.question, answer: b.answer,
      intent: b.intent || null,
      status: typeof b.status === 'string' ? b.status : null,
    });
    if (!out.ok) return relay(res, out);
    return res.status(out.status || 201).json({ success: true, data: { entry: out.row }, message: out.message });
  } catch (e) { return next(e); }
});

/**
 * PATCH /owner/kb/:id  {question?, answer?, status?}
 *
 * Two shapes in one endpoint on purpose: a status-only body publishes or retires a row
 * without retyping it (setKbStatus), and a body with text rewrites it (upsertKb with an
 * id). Both are ownership-checked through venues.owner_id inside the service.
 */
router.patch('/owner/kb/:id', owner, async (req, res, next) => {
  try {
    const id = String(req.params.id || '').trim().toLowerCase();
    if (!access.isUuid(id)) return fail(res, 404, 'That answer does not exist.');
    const b = req.body || {};
    const hasText = typeof b.question === 'string' || typeof b.answer === 'string';
    if (!hasText && typeof b.status !== 'string') {
      return fail(res, 400, 'Send a question, an answer or a status.');
    }
    const out = hasText
      ? await kb.upsertKb(pool, {
        ownerId: req.user.id, id, question: b.question, answer: b.answer,
        intent: b.intent || null,
        // Omitted status means "leave it as it is" — see upsertKb.
        status: typeof b.status === 'string' ? b.status : null,
      })
      : await kb.setKbStatus(pool, { ownerId: req.user.id, id, status: String(b.status) });
    if (!out.ok) return relay(res, out);
    return ok(res, { entry: out.row }, out.message);
  } catch (e) { return next(e); }
});

/** DELETE /owner/kb/:id — for a row that should never have existed. Archive otherwise. */
router.delete('/owner/kb/:id', owner, async (req, res, next) => {
  try {
    const id = String(req.params.id || '').trim().toLowerCase();
    if (!access.isUuid(id)) return fail(res, 404, 'That answer does not exist.');
    const out = await kb.deleteKb(pool, { ownerId: req.user.id, id });
    if (!out.ok) return relay(res, out);
    return ok(res, { deleted: id }, out.message);
  } catch (e) { return next(e); }
});

/**
 * GET /owner/stats — how much has Scout learned from this owner, and is it being used?
 *
 * `served` is the number that matters: a KB row nobody ever hits is a row that was not
 * worth asking for, and the wave report quotes this counter.
 */
router.get('/owner/stats', owner, async (req, res, next) => {
  try {
    return ok(res, await kb.stats(pool, { ownerId: req.user.id }));
  } catch (e) { return next(e); }
});

module.exports = router;
