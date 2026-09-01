/**
 * assistantKb.js — the part of Scout that learns.
 *
 * The loop
 *   1. A player asks something about a ground that no query can answer
 *      ("does G-11 have floodlights?", "is there parking for 20 cars?").
 *   2. Scout does not guess. It escalates to that venue's owner and says so.
 *   3. The owner answers in their dashboard. The answer becomes an
 *      assistant_kb row, status 'published'.
 *   4. The next player who asks a paraphrase gets it instantly, labelled
 *      source: 'kb' — a human's answer being reused, not a model inventing one.
 *
 * This is the only way SportLynk's assistant can know something that is not in
 * the schema, and it is the honest way: the knowledge comes from the person who
 * owns the ground, and the label on the answer says so.
 *
 * Three safety rules, each enforced in the database
 * a. Owner-approved. A row is only served at status 'published'. An escalation
 *    the owner never answered serves nothing.
 * b. Per-venue isolation. chk_assistant_kb_venue forces scope='venue' rows to
 *    carry a venue_id, and every read filters on it. A fact about one ground can
 *    never be served for another.
 * c. Never money or POLICY. chk_assistant_kb_intent rejects rows tagged
 *    wallet_balance, refund_policy, cancel_booking, book_venue or topup_help.
 *    Those answers come from the live database and from escrow.js POLICY, and no
 *    owner-written sentence is allowed to become the platform's refund rule.
 *    BLOCKED_INTENTS below mirrors that CHECK so the refusal happens before an
 *    owner has typed an answer that could never be stored.
 *
 * Every function takes an explicit `client`, so a caller inside a transaction
 * stays in it. Nothing here opens its own.
 */
const pool = require('../db/pool');
const { notify } = require('../utils/notify');
const { reply, chip, SOURCES } = require('../utils/assistantReply');
const threads = require('./assistantThreads');

/** Mirrors chk_assistant_kb_intent in migrations/018_assistant.sql. */
const BLOCKED_INTENTS = Object.freeze([
  'wallet_balance', 'refund_policy', 'cancel_booking', 'book_venue', 'topup_help',
]);

/**
 * Similarity floor for a trigram match, and it is deliberately high.
 *
 * A wrong KB answer is worse than no answer: the user believes it, and it is
 * attributed to the venue owner who never said it. 0.42 was chosen against the
 * probe in run_migration_018.js, where a genuine paraphrase of a seeded question
 * scored 0.523 — comfortably above, while unrelated questions about the same
 * ground sit far below.
 */
const MIN_SIMILARITY = 0.42;

/** Same normalisation as the generated question_norm column, for the fallback. */
function normalise(text) {
  return String(text || '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
}

/** Words worth matching on. Short function words match everything and mean nothing. */
function contentTokens(text) {
  return normalise(text).split(' ').filter((t) => t.length > 2);
}

let trgmAvailable = null;
/**
 * Is pg_trgm usable on this database? Migration 018 creates it inside an
 * exception-swallowing block, because a managed Postgres role may not be allowed
 * to, so its presence is a runtime fact rather than a guarantee. Checked once and
 * cached: the answer cannot change while the process is running.
 */
async function hasTrgm(client) {
  if (trgmAvailable !== null) return trgmAvailable;
  try {
    const { rows } = await (client || pool).query(
      "SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm'",
    );
    trgmAvailable = rows.length > 0;
  } catch {
    trgmAvailable = false;
  }
  return trgmAvailable;
}

/**
 * Find a published answer for `question`.
 *
 * Scope: rows for this venue plus global rows. A venue row wins ties, because a
 * fact about the ground the user is asking about beats a platform-wide how-to.
 *
 * Two matchers, one meaning. With pg_trgm the database ranks by similarity, which
 * handles paraphrase and Roman-Urdu spelling variation. Without it, Node ranks by
 * content-token overlap — cruder, but it keeps the loop working on a database
 * where the extension could not be created, instead of silently serving nothing.
 *
 * @returns {{hit:boolean, row:object|null, similarity:number, matcher:string}}
 */
async function search(client, { question, venueId = null, limit = 3 } = {}) {
  const runner = client || pool;
  const q = normalise(question);
  if (!q) return { hit: false, row: null, similarity: 0, matcher: 'none', candidates: [] };

  if (await hasTrgm(runner)) {
    const { rows } = await runner.query(
      `SELECT id, scope, venue_id, question, answer, intent, lang, served_count,
              similarity(question_norm, $1) AS sim
         FROM assistant_kb
        WHERE status = 'published'
          AND (scope = 'global' OR ($2::uuid IS NOT NULL AND venue_id = $2::uuid))
          AND similarity(question_norm, $1) >= $3
        ORDER BY (scope = 'venue') DESC, sim DESC
        LIMIT $4`,
      [q, venueId, MIN_SIMILARITY, Math.max(1, Math.min(10, limit))],
    );
    const best = rows[0] || null;
    return {
      hit: !!best,
      row: best,
      similarity: best ? Number(best.sim) : 0,
      matcher: 'trigram',
      candidates: rows,
    };
  }

  // Fallback: content-token overlap, computed in Node
  const tokens = contentTokens(question);
  if (!tokens.length) return { hit: false, row: null, similarity: 0, matcher: 'overlap', candidates: [] };

  const { rows } = await runner.query(
    `SELECT id, scope, venue_id, question, question_norm, answer, intent, lang, served_count
       FROM assistant_kb
      WHERE status = 'published'
        AND (scope = 'global' OR ($1::uuid IS NOT NULL AND venue_id = $1::uuid))
      LIMIT 500`,
    [venueId],
  );
  const scored = rows
    .map((r) => {
      const rowTokens = new Set(contentTokens(r.question_norm || r.question));
      const shared = tokens.filter((t) => rowTokens.has(t)).length;
      // Jaccard-ish: shared over the larger side, so a long stored question does
      // not win just by containing many words.
      const denom = Math.max(tokens.length, rowTokens.size) || 1;
      return { ...r, sim: shared / denom };
    })
    .filter((r) => r.sim >= MIN_SIMILARITY)
    .sort((a, b) => (b.scope === 'venue') - (a.scope === 'venue') || b.sim - a.sim)
    .slice(0, Math.max(1, Math.min(10, limit)));

  const best = scored[0] || null;
  return {
    hit: !!best,
    row: best,
    similarity: best ? Number(best.sim) : 0,
    matcher: 'overlap',
    candidates: scored,
  };
}

/** Count a serve. Never fails a turn: a missed counter is not worth an error. */
async function recordServed(client, kbId) {
  try {
    await (client || pool).query(
      `UPDATE assistant_kb
          SET served_count = served_count + 1, last_served_at = NOW()
        WHERE id = $1`,
      [kbId],
    );
  } catch { /* telemetry, not truth */ }
}

/**
 * Forward an unanswerable venue question to that venue's owner.
 *
 * Refuses, with a reason, when:
 *   money_or_policy  the intent is one chk_assistant_kb_intent would reject. An
 *                    escalation whose answer could never be stored is a queue
 *                    item that wastes an owner's time and then fails.
 *   no_owner         the venue has no owner_id, so there is nobody to ask.
 *   duplicate        the same question is already open for the same venue. The
 *                    existing row is returned instead, so ten players asking the
 *                    same thing produce one item in the owner's queue.
 *
 * The refusals are as important as the success: `{ ok:false, reason }` is what
 * lets the dialog manager say something true instead of promising a follow-up
 * that will never come.
 */
async function escalate(client, {
  userId, channelId = null, messageId = null,
  venueId = null, question, intent = null, confidence = null,
} = {}) {
  const runner = client || pool;
  const text = String(question || '').trim();
  if (!text) return { ok: false, reason: 'empty_question', row: null };
  if (intent && BLOCKED_INTENTS.includes(intent)) {
    return { ok: false, reason: 'money_or_policy', row: null };
  }
  if (!venueId) return { ok: false, reason: 'no_venue', row: null };

  const v = await runner.query(
    'SELECT id, name, owner_id FROM venues WHERE id = $1', [venueId],
  );
  if (!v.rows.length) return { ok: false, reason: 'no_venue', row: null };
  const venue = v.rows[0];
  if (!venue.owner_id) return { ok: false, reason: 'no_owner', row: null, venue };

  const dup = await runner.query(
    `SELECT * FROM assistant_escalations
      WHERE status = 'open' AND venue_id = $1
        AND btrim(regexp_replace(lower(question), '[^[:alnum:]]+', ' ', 'g')) = $2
      ORDER BY created_at ASC LIMIT 1`,
    [venueId, normalise(text)],
  );
  if (dup.rows.length) {
    return { ok: true, reason: 'duplicate', row: dup.rows[0], venue, notified: false };
  }

  const ins = await runner.query(
    `INSERT INTO assistant_escalations
       (user_id, channel_id, message_id, venue_id, owner_id, question, intent, confidence)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
     RETURNING *`,
    [userId, channelId, messageId, venueId, venue.owner_id, text, intent,
      confidence === null ? null : Number(confidence)],
  );

  await notify(runner, {
    userId: venue.owner_id,
    type: 'assistant_question',
    title: `A player asked about ${venue.name}`,
    body: text.length > 160 ? `${text.slice(0, 157)}...` : text,
    payload: { escalationId: ins.rows[0].id, venueId, kind: 'assistant_escalation' },
  });

  return { ok: true, reason: 'created', row: ins.rows[0], venue, notified: true };
}

/**
 * The owner's queue.
 *
 * Scoped by ownership of the VENUE, not by the owner_id stamped on the row, so an
 * ownership transfer cannot orphan a question — and so an owner can never read a
 * question asked about somebody else's ground.
 */
async function listOwnerQuestions(client, { ownerId, status = 'open', limit = 50 } = {}) {
  const runner = client || pool;
  const { rows } = await runner.query(
    `SELECT e.id, e.question, e.intent, e.confidence, e.status, e.answer,
            e.created_at, e.answered_at,
            v.id AS venue_id, v.name AS venue_name,
            u.name AS asked_by_name
       FROM assistant_escalations e
       JOIN venues v ON v.id = e.venue_id
       LEFT JOIN users u ON u.id = e.user_id
      WHERE v.owner_id = $1
        AND ($2::text IS NULL OR e.status = $2::text)
      ORDER BY (e.status = 'open') DESC, e.created_at ASC
      LIMIT $3`,
    [ownerId, status === 'all' ? null : status, Math.max(1, Math.min(200, limit))],
  );
  return rows;
}

// The owner answers — where the learning happens

/**
 * An owner answers an escalated question. This one function closes the loop:
 *
 *   1. authorise — the caller must own the VENUE the question was asked about;
 *   2. remember  — write a published assistant_kb row, so the next player who
 *                  asks the same thing gets the answer instantly, from `kb`;
 *   3. resolve   — mark the escalation answered, pointing at that row;
 *   4. deliver   — post the answer into the asking player's own Scout thread as
 *                  a kind='assistant' message with source 'kb', and notify them.
 *
 * Step 4 is what makes this asynchronous loop feel like a conversation instead
 * of a support ticket: the player asked three hours ago and is not holding a
 * request open, so the answer has to arrive in the thread where they asked it.
 * That is why assistant_escalations carries channel_id and message_id.
 *
 * The intent is nulled out if it is one of BLOCKED_INTENTS. escalate() already
 * refuses those, but chk_assistant_kb_intent would abort the whole transaction
 * if one ever reached here, and losing an owner's typed answer to a constraint
 * violation is worse than losing the intent label on the row.
 */
async function answer(client, {
  escalationId, ownerId, answerText, publish = true,
} = {}) {
  const runner = client || pool;
  const text = String(answerText || '').trim();
  if (!escalationId) return { ok: false, code: 'missing_args', status: 400, message: 'Which question?' };
  if (!text) return { ok: false, code: 'empty_answer', status: 400, message: 'Write an answer first.' };
  if (text.length > 2000) {
    return { ok: false, code: 'answer_too_long', status: 400, message: 'Keep the answer under 2000 characters.' };
  }

  const { rows } = await runner.query(
    `SELECT e.*, v.name AS venue_name, v.owner_id AS venue_owner_id
       FROM assistant_escalations e
       JOIN venues v ON v.id = e.venue_id
      WHERE e.id = $1
      FOR UPDATE OF e`,
    [escalationId],
  );
  if (!rows.length) {
    return { ok: false, code: 'not_found', status: 404, message: 'That question no longer exists.' };
  }
  const esc = rows[0];
  if (esc.venue_owner_id !== ownerId) {
    return { ok: false, code: 'forbidden', status: 403, message: 'That question was asked about another venue.' };
  }
  if (esc.status === 'answered') {
    return { ok: false, code: 'already_answered', status: 409, message: 'You already answered this one.',
      row: esc };
  }

  const intent = esc.intent && !BLOCKED_INTENTS.includes(esc.intent) ? esc.intent : null;
  const status = publish ? 'published' : 'draft';

  const kb = await runner.query(
    `INSERT INTO assistant_kb
       (scope, venue_id, owner_id, question, answer, source, status, intent,
        asked_count, created_by)
     VALUES ('venue', $1, $2, $3, $4, 'owner', $5, $6, 1, $2)
     RETURNING id, scope, venue_id, question, answer, status, intent, created_at`,
    [esc.venue_id, ownerId, esc.question, text, status, intent],
  );
  const kbRow = kb.rows[0];

  await runner.query(
    `UPDATE assistant_escalations
        SET status = 'answered', answer = $2, kb_id = $3, answered_by = $4,
            answered_at = NOW(), updated_at = NOW()
      WHERE id = $1`,
    [esc.id, text, kbRow.id, ownerId],
  );

  // Deliver
  // Best-effort: the answer is already recorded and published, so a thread that
  // the player deleted in the meantime must not roll back the owner's work.
  let delivered = false;
  if (esc.channel_id) {
    const payload = reply(
      `${esc.venue_name} answered your question:\n\n${text}`,
      {
        source: SOURCES.KB,
        chips: [
          chip('Ask something else', 'app_help'),
          chip(`About ${esc.venue_name}`, 'venue_info', { venueId: esc.venue_id }),
        ],
        meta: { escalationId: esc.id, kbId: kbRow.id, venueId: esc.venue_id, answeredBy: 'owner' },
      },
    );
    const posted = await threads.appendMessage(runner, {
      threadId: esc.channel_id, who: 'scout', text: payload.text, payload,
    }).catch(() => ({ ok: false }));
    delivered = !!posted.ok;
  }

  await notify(runner, {
    userId: esc.user_id,
    type: 'assistant_answer',
    title: `${esc.venue_name} answered your question`,
    body: text.length > 160 ? `${text.slice(0, 157)}...` : text,
    payload: {
      kind: 'assistant_answer', escalationId: esc.id, kbId: kbRow.id,
      venueId: esc.venue_id, channelId: esc.channel_id,
    },
  });

  return { ok: true, code: 'ok', status: 200, row: kbRow, escalation: esc, delivered,
    message: delivered ? 'Answer sent to the player.' : 'Answer saved.' };
}

/**
 * The owner declines a question — "not something I can answer". The row closes
 * so the queue stays honest, no KB row is written, and the player is told rather
 * than left waiting: silence is the worst outcome of an escalation.
 */
async function decline(client, { escalationId, ownerId, reason = null } = {}) {
  const runner = client || pool;
  const { rows } = await runner.query(
    `SELECT e.*, v.name AS venue_name, v.owner_id AS venue_owner_id
       FROM assistant_escalations e JOIN venues v ON v.id = e.venue_id
      WHERE e.id = $1 FOR UPDATE OF e`,
    [escalationId],
  );
  if (!rows.length) return { ok: false, code: 'not_found', status: 404, message: 'That question no longer exists.' };
  const esc = rows[0];
  if (esc.venue_owner_id !== ownerId) {
    return { ok: false, code: 'forbidden', status: 403, message: 'That question was asked about another venue.' };
  }
  if (esc.status !== 'open') {
    return { ok: false, code: 'not_open', status: 409, message: 'That question is already closed.' };
  }
  await runner.query(
    `UPDATE assistant_escalations SET status = 'declined', updated_at = NOW() WHERE id = $1`,
    [esc.id],
  );
  if (esc.channel_id) {
    const payload = reply(
      `${esc.venue_name} could not answer that one. You can call the ground directly, `
      + 'or ask me something else.',
      {
        source: SOURCES.MENU,
        chips: [chip('What can you do?', 'app_help'), chip('Find a ground', 'find_venue')],
        meta: { escalationId: esc.id, venueId: esc.venue_id, declined: true },
      },
    );
    await threads.appendMessage(runner, {
      threadId: esc.channel_id, who: 'scout', text: payload.text, payload,
    }).catch(() => null);
  }
  return { ok: true, code: 'ok', status: 200, row: { ...esc, status: 'declined' }, reason,
    message: 'Question closed.' };
}

// Owner KB CRUD — "what Scout says about my ground"
//
// An owner must be able to see and edit what Scout is telling players on their
// behalf. Without that, "Scout remembered your answer" is a black box the owner
// cannot audit, and one badly-worded answer is served forever.
//
// Every function below is scoped by ownership of the venue the row is attached
// to, resolved through venues.owner_id at query time — never through the
// denormalised assistant_kb.owner_id, which is only a record of who typed it.
// Global rows (scope='global', venue_id NULL) are admin territory and are
// invisible to these endpoints by construction.

/** Every KB row for every venue this owner owns. */
async function listKb(client, { ownerId, venueId = null, status = null, limit = 100 } = {}) {
  const { rows } = await (client || pool).query(
    `SELECT k.id, k.scope, k.venue_id, v.name AS venue_name, k.question, k.answer,
            k.source, k.status, k.intent, k.asked_count, k.served_count,
            k.last_served_at, k.created_at, k.updated_at
       FROM assistant_kb k
       JOIN venues v ON v.id = k.venue_id
      WHERE v.owner_id = $1
        AND ($2::uuid IS NULL OR k.venue_id = $2::uuid)
        AND ($3::text IS NULL OR k.status = $3::text)
      ORDER BY (k.status = 'published') DESC, k.updated_at DESC
      LIMIT $4`,
    [ownerId, venueId, status, Math.max(1, Math.min(500, limit))],
  );
  return rows;
}

/**
 * Create or edit one row. An owner may only attach an answer to a venue they
 * own, and may only ever write scope='venue' — a global row would be an owner
 * speaking for the whole app.
 */
async function upsertKb(client, {
  ownerId, id = null, venueId = null, question, answer: answerText,
  intent = null, status = null,
} = {}) {
  const runner = client || pool;
  // An edit is partial: any field left out keeps its stored value, so "fix the
  // wording of the answer" does not require re-sending the question. A new row
  // still needs both halves — a KB entry with no question can never be matched.
  // An empty string counts as "not sent" rather than "blank it": there is no
  // legitimate reason to erase half of a published answer, and a silent blank
  // would be served to players as an empty reply.
  const q = String(question == null ? '' : question).trim() || null;
  const a = String(answerText == null ? '' : answerText).trim() || null;
  if (!id && (!q || !a)) {
    return { ok: false, code: 'missing_args', status: 400, message: 'A question and an answer are both required.' };
  }
  if (id && !q && !a && status == null) {
    return { ok: false, code: 'nothing_to_do', status: 400,
      message: 'Send a question, an answer or a status.' };
  }
  if ((q && q.length > 300) || (a && a.length > 2000)) {
    return { ok: false, code: 'too_long', status: 400,
      message: 'Question max 300 characters, answer max 2000.' };
  }
  // `status` NULL means "do not change it". An edit that only fixes a typo in a
  // draft answer must not publish it as a side effect, and the old default of
  // 'published' did exactly that.
  if (status != null && !['draft', 'published', 'rejected', 'archived'].includes(status)) {
    return { ok: false, code: 'bad_status', status: 400, message: 'Unknown status.' };
  }
  const useIntent = intent && !BLOCKED_INTENTS.includes(intent) ? intent : null;

  if (id) {
    const { rows } = await runner.query(
      `UPDATE assistant_kb k
          SET question = COALESCE($3::text, k.question),
              answer = COALESCE($4::text, k.answer),
              intent = COALESCE($5::text, k.intent),
              status = COALESCE($6::text, k.status), updated_at = NOW()
        WHERE k.id = $1
          AND EXISTS (SELECT 1 FROM venues v WHERE v.id = k.venue_id AND v.owner_id = $2)
        RETURNING k.id, k.scope, k.venue_id, k.question, k.answer, k.status, k.intent,
                  k.created_at, k.updated_at`,
      [id, ownerId, q, a, useIntent, status],
    );
    return rows.length
      ? { ok: true, code: 'ok', status: 200, row: rows[0], message: 'Answer updated.' }
      : { ok: false, code: 'not_found', status: 404, message: 'That answer does not exist.' };
  }

  const owns = await runner.query(
    'SELECT id FROM venues WHERE id = $1 AND owner_id = $2', [venueId, ownerId],
  );
  if (!owns.rows.length) {
    return { ok: false, code: 'forbidden', status: 403, message: 'That is not your venue.' };
  }
  const { rows } = await runner.query(
    `INSERT INTO assistant_kb
       (scope, venue_id, owner_id, question, answer, source, status, intent, created_by)
     VALUES ('venue', $1, $2, $3, $4, 'owner', COALESCE($5::text, 'published'), $6, $2)
     RETURNING id, scope, venue_id, question, answer, status, intent, created_at, updated_at`,
    [venueId, ownerId, q, a, status, useIntent],
  );
  return { ok: true, code: 'ok', status: 201, row: rows[0], message: 'Scout will use this answer.' };
}

/** Publish / unpublish / archive without retyping the answer. */
async function setKbStatus(client, { ownerId, id, status } = {}) {
  if (!['draft', 'published', 'rejected', 'archived'].includes(status)) {
    return { ok: false, code: 'bad_status', status: 400, message: 'Unknown status.' };
  }
  const { rows } = await (client || pool).query(
    `UPDATE assistant_kb k SET status = $3, updated_at = NOW()
      WHERE k.id = $1
        AND EXISTS (SELECT 1 FROM venues v WHERE v.id = k.venue_id AND v.owner_id = $2)
      RETURNING k.id, k.status, k.question`,
    [id, ownerId, status],
  );
  return rows.length
    ? { ok: true, code: 'ok', status: 200, row: rows[0],
      message: status === 'published' ? 'Scout is using this answer.' : 'Scout has stopped using it.' }
    : { ok: false, code: 'not_found', status: 404, message: 'That answer does not exist.' };
}

/**
 * Hard delete. Kept separate from archiving on purpose: archiving stops Scout
 * serving a row while keeping the evidence of what it used to say, and that is
 * the right default for a demo. Delete is for a row that should never have
 * existed.
 */
async function deleteKb(client, { ownerId, id } = {}) {
  const { rowCount } = await (client || pool).query(
    `DELETE FROM assistant_kb k
      WHERE k.id = $1
        AND EXISTS (SELECT 1 FROM venues v WHERE v.id = k.venue_id AND v.owner_id = $2)`,
    [id, ownerId],
  );
  return rowCount > 0
    ? { ok: true, code: 'ok', status: 200, message: 'Answer deleted.' }
    : { ok: false, code: 'not_found', status: 404, message: 'That answer does not exist.' };
}

/**
 * Counters for the owner dashboard and for the wave report: how much has Scout
 * learned, and how much of it is being used.
 */
async function stats(client, { ownerId = null } = {}) {
  const runner = client || pool;
  const scoped = ownerId
    ? 'JOIN venues v ON v.id = k.venue_id WHERE v.owner_id = $1'
    : '';
  const args = ownerId ? [ownerId] : [];
  const { rows: [kb] } = await runner.query(
    `SELECT count(*)::int total,
            count(*) FILTER (WHERE k.status = 'published')::int published,
            COALESCE(sum(k.served_count), 0)::int served
       FROM assistant_kb k ${scoped}`,
    args,
  );
  const { rows: [esc] } = await runner.query(
    ownerId
      ? `SELECT count(*)::int total,
                count(*) FILTER (WHERE e.status = 'open')::int open,
                count(*) FILTER (WHERE e.status = 'answered')::int answered
           FROM assistant_escalations e JOIN venues v ON v.id = e.venue_id
          WHERE v.owner_id = $1`
      : `SELECT count(*)::int total,
                count(*) FILTER (WHERE e.status = 'open')::int open,
                count(*) FILTER (WHERE e.status = 'answered')::int answered
           FROM assistant_escalations e`,
    args,
  );
  return { kb, escalations: esc, minSimilarity: MIN_SIMILARITY, trgm: await hasTrgm(runner) };
}

module.exports = {
  BLOCKED_INTENTS,
  MIN_SIMILARITY,
  normalise,
  contentTokens,
  hasTrgm,
  search,
  recordServed,
  escalate,
  listOwnerQuestions,
  answer,
  decline,
  listKb,
  upsertKb,
  setKbStatus,
  deleteKb,
  stats,
};
