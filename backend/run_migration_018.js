/**
 * Runner for migrations/018_assistant.sql
 * Usage: node run_migration_018.js
 *
 * Applied as ONE multi-statement command, so Postgres wraps it in a single
 * implicit transaction and a failure anywhere leaves the database untouched.
 * (No `-- @@SPLIT@@` marker: 018 adds no enum values, and `ALTER TYPE ... ADD
 * VALUE` is the only statement that cannot run inside a transaction.)
 *
 * Four things this proves that a `\d` dump cannot:
 *
 *   1. MANY ASSISTANT THREADS PER USER ARE LEGAL. 015 created
 *      `ux_chat_channels_type_ref UNIQUE (type, ref_id) WHERE ref_id IS NOT NULL`.
 *      Scout's threads carry ref_id = NULL, so the index does not apply and a
 *      user may hold as many as they like — which is the entire basis of "new
 *      chat / switch chat". That is a subtle read of somebody else's index, so it
 *      is PROVEN by inserting two and checking neither is rejected, not asserted.
 *
 *   2. THE MONEY-AND-POLICY FIREWALL CONSTRAINS. chk_assistant_kb_intent is what
 *      stops a learned, human-typed answer from ever being served for
 *      wallet_balance or refund_policy. A constraint that exists but does not
 *      constrain reads as enforced and is enforced nowhere, so a row that MUST be
 *      rejected is inserted and its SQLSTATE asserted.
 *
 *   3. assistant_turns HAS NO TEXT COLUMN. doc/claude.md forbids logging the
 *      utterance. That is a property of the SCHEMA, so it is checked against
 *      information_schema rather than trusted to code review: any future column
 *      named like message text fails this runner loudly.
 *
 *   4. question_norm IS GENERATED. KB matching depends on it, and a plain column
 *      that some INSERT forgets to fill degrades fuzzy search to silence rather
 *      than to an error. The probe inserts mixed-case punctuated text and checks
 *      the normalised form the database derived by itself.
 *
 * Safe to re-run: every statement in the .sql is idempotent.
 */
const fs = require('fs');
const path = require('path');
const pool = require('./src/db/pool');

// 018 ALTERs or references all of these. A missing one means 013/015 never ran.
const PREREQUISITE_TABLES = [
  'users', 'venues', 'bookings', 'slots', 'wallets',
  'chat_channels', 'chat_messages', 'chat_channel_members', 'global_settings',
];

const EXPECTED_INDEXES = [
  'idx_chat_channels_assistant',
  'idx_chat_messages_assistant',
  'idx_assistant_kb_serve',
  'idx_assistant_kb_owner',
  'idx_assistant_esc_owner',
  'idx_assistant_esc_user',
  'idx_assistant_esc_open_venue',
  'idx_assistant_turns_time',
  'idx_assistant_turns_intent',
  'idx_assistant_turns_abstain',
  'idx_assistant_feedback_msg',
];

const EXPECTED_CONSTRAINTS = [
  'chk_chat_channels_persona',
  'chk_chat_messages_kind',
  'chk_chat_messages_payload',
  'chk_assistant_kb_scope_val',
  'chk_assistant_kb_source',
  'chk_assistant_kb_status',
  'chk_assistant_kb_venue',
  'chk_assistant_kb_nonempty',
  'chk_assistant_kb_intent',
  'chk_assistant_esc_status',
  'chk_assistant_esc_q',
  'chk_assistant_esc_answer',
  'chk_assistant_turns_mode',
  'chk_assistant_turns_src',
  'chk_assistant_feedback_vote',
];

// column → information_schema.data_type, for the four tables 018 creates plus
// the columns it adds to the two chat tables.
const EXPECTED_COLUMNS = {
  chat_channels: {
    session_state: 'jsonb',
    archived_at: 'timestamp with time zone',
    assistant_persona: 'text',
  },
  chat_messages: {
    assistant_payload: 'jsonb',
  },
  assistant_kb: {
    id: 'uuid', scope: 'text', venue_id: 'uuid', owner_id: 'uuid',
    question: 'text', question_norm: 'text', answer: 'text',
    source: 'text', status: 'text', intent: 'text', lang: 'text',
    asked_count: 'integer', served_count: 'integer',
    last_served_at: 'timestamp with time zone',
    created_by: 'uuid',
    created_at: 'timestamp with time zone',
    updated_at: 'timestamp with time zone',
  },
  assistant_escalations: {
    id: 'uuid', user_id: 'uuid', channel_id: 'uuid', message_id: 'uuid',
    venue_id: 'uuid', owner_id: 'uuid', question: 'text', intent: 'text',
    confidence: 'numeric', status: 'text', answer: 'text', kb_id: 'uuid',
    answered_by: 'uuid',
    answered_at: 'timestamp with time zone',
    created_at: 'timestamp with time zone',
    updated_at: 'timestamp with time zone',
  },
  assistant_turns: {
    id: 'bigint', user_id: 'uuid', channel_id: 'uuid',
    input_mode: 'text', text_chars: 'integer',
    intent: 'text', confidence: 'numeric', abstained: 'boolean',
    abstain_reason: 'text', model_version: 'text',
    action: 'text', action_ok: 'boolean', answer_source: 'text', fsm_state: 'text',
    nlu_ms: 'integer', total_ms: 'integer',
    created_at: 'timestamp with time zone',
  },
  assistant_feedback: {
    id: 'uuid', message_id: 'uuid', user_id: 'uuid',
    vote: 'smallint', reason: 'text',
    created_at: 'timestamp with time zone',
  },
};

// ── The privacy assertion ───────────────────────────────────────────────────
// Nothing resembling raw user text may live on the telemetry table. Names, not
// a regex on the whole column list, so the failure message can say WHICH.
const FORBIDDEN_TURN_COLUMNS = [
  'text', 'body', 'utterance', 'message', 'message_text', 'raw_text',
  'query', 'input', 'input_text', 'transcript', 'reply', 'answer',
];

async function tableNames(client) {
  const { rows } = await client.query(
    `SELECT table_name FROM information_schema.tables
      WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
      ORDER BY table_name`,
  );
  return rows.map((r) => r.table_name);
}

async function run() {
  const sqlFile = path.join(__dirname, 'migrations', '018_assistant.sql');
  const sql = fs.readFileSync(sqlFile, 'utf8');

  const client = await pool.connect();
  const failures = [];
  const check = (ok, label) => {
    if (ok) console.log(`   ✓ ${label}`);
    else { failures.push(label); console.log(`   ✗ ${label}`); }
  };

  try {
    // ─── Pre-flight ─────────────────────────────────────────────────────────
    const before = await tableNames(client);
    const missingPrereqs = PREREQUISITE_TABLES.filter((t) => !before.includes(t));
    if (missingPrereqs.length) {
      console.error('❌ Cannot apply migration 018 — prerequisite tables missing:');
      console.error(`   ${missingPrereqs.join(', ')}`);
      console.error('   Apply schema.sql, then run_migration_013.js through 017.');
      client.release();
      await pool.end();
      process.exit(1);
    }

    // The whole wave stands on chat_channels accepting type='assistant'. 015 put
    // it in chk_chat_channels_type. If that constraint is missing or narrower,
    // every INSERT the dialog manager makes would fail at runtime with a 23514
    // that names a constraint and not a cause — so refuse now, with the cause.
    const { rows: typeCon } = await client.query(
      `SELECT pg_get_constraintdef(oid) AS def
         FROM pg_constraint WHERE conname = 'chk_chat_channels_type'`,
    );
    const typeDef = typeCon.length ? typeCon[0].def : '';
    if (!/assistant/i.test(typeDef)) {
      console.error('❌ Cannot apply migration 018 — chat_channels does not accept');
      console.error("   type = 'assistant'.");
      console.error(`   chk_chat_channels_type is: ${typeDef || 'MISSING'}`);
      console.error('   Apply run_migration_015.js first; 018 stores every Scout thread');
      console.error('   as an assistant channel and would fail on the first insert.');
      client.release();
      await pool.end();
      process.exit(1);
    }

    // Any chat_messages.kind outside the enumeration 018 is about to install
    // would make ADD CONSTRAINT fail against live data. The new set is a strict
    // superset of 015's, so this can only trip on a hand-edited row — but the
    // error Postgres gives ("check constraint is violated by some row") names no
    // row, so find it here instead.
    const { rows: strayKinds } = await client.query(
      `SELECT kind, count(*)::int AS n FROM chat_messages
        WHERE kind NOT IN ('text','image','audio','system','assistant')
        GROUP BY kind ORDER BY n DESC`,
    );
    if (strayKinds.length) {
      console.error('❌ Cannot apply migration 018 — chat_messages holds kinds outside');
      console.error("   ('text','image','audio','system','assistant'):");
      for (const k of strayKinds) console.error(`   kind='${k.kind}' × ${k.n}`);
      console.error('   Fix or delete those rows; a migration must not guess what they meant.');
      client.release();
      await pool.end();
      process.exit(1);
    }

    const { rows: [counts] } = await client.query(
      `SELECT (SELECT count(*)::int FROM chat_channels) AS channels,
              (SELECT count(*)::int FROM chat_messages) AS messages,
              (SELECT count(*)::int FROM venues)        AS venues,
              (SELECT count(*)::int FROM users)         AS users`,
    );
    console.log(`Pre-flight: ${before.length} tables present, all prerequisites found.`);
    console.log(`   ${counts.channels} chat channel(s), ${counts.messages} message(s), `
      + `${counts.venues} venue(s), ${counts.users} user(s).`);
    console.log("   chat_channels already accepts type='assistant' (migration 015).");
    console.log('   No chat_messages.kind values outside the new enumeration.');
    console.log('');

    // ─── Apply ──────────────────────────────────────────────────────────────
    await client.query(sql);
    console.log('Migration 018 applied. Verifying:');
    console.log('');

    // ─── 1. Columns ─────────────────────────────────────────────────────────
    const { rows: cols } = await client.query(
      `SELECT table_name, column_name, data_type
         FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = ANY($1)`,
      [Object.keys(EXPECTED_COLUMNS)],
    );
    const typeOf = new Map(cols.map((r) => [`${r.table_name}.${r.column_name}`, r.data_type]));
    let colTotal = 0;
    const badCols = [];
    for (const [table, want] of Object.entries(EXPECTED_COLUMNS)) {
      for (const [col, type] of Object.entries(want)) {
        colTotal += 1;
        const got = typeOf.get(`${table}.${col}`);
        if (got !== type) badCols.push(`${table}.${col} is ${got || 'MISSING'}, want ${type}`);
      }
    }
    check(badCols.length === 0,
      `all ${colTotal} assistant columns present with the right type across `
      + `${Object.keys(EXPECTED_COLUMNS).length} tables`
      + `${badCols.length ? ` — WRONG: ${badCols.join('; ')}` : ''}`);

    // session_state must be NOT NULL DEFAULT '{}': the dialog manager reads state
    // before it has ever written any, and a NULL there is a crash on turn 1 of
    // every brand-new thread.
    const { rows: [ssCol] } = await client.query(
      `SELECT is_nullable, column_default FROM information_schema.columns
        WHERE table_schema='public' AND table_name='chat_channels' AND column_name='session_state'`,
    );
    check(ssCol && ssCol.is_nullable === 'NO' && /\{\}/.test(ssCol.column_default || ''),
      `chat_channels.session_state is NOT NULL DEFAULT '{}' (turn 1 of a new thread reads `
      + `state before writing any)`);

    // ─── 2. THE PRIVACY ASSERTION ───────────────────────────────────────────
    const turnCols = cols.filter((c) => c.table_name === 'assistant_turns').map((c) => c.column_name);
    const leaks = turnCols.filter((c) => FORBIDDEN_TURN_COLUMNS.includes(c));
    check(leaks.length === 0,
      'assistant_turns stores NO utterance text — text_chars only '
      + '(doc/claude.md: the assistant utterance is never logged)'
      + `${leaks.length ? ` — FORBIDDEN COLUMN(S) PRESENT: ${leaks.join(', ')}` : ''}`);
    check(turnCols.includes('text_chars'),
      'assistant_turns.text_chars exists — length is the only property of the text kept');

    // ─── 3. Indexes ─────────────────────────────────────────────────────────
    const { rows: idxRows } = await client.query(
      `SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = 'public'`,
    );
    const idx = new Map(idxRows.map((r) => [r.indexname, r.indexdef]));
    const missingIdx = EXPECTED_INDEXES.filter((n) => !idx.has(n));
    check(missingIdx.length === 0,
      `all ${EXPECTED_INDEXES.length} indexes exist`
      + `${missingIdx.length ? ` — MISSING: ${missingIdx.join(', ')}` : ''}`);

    // The thread list index must be partial on type + archived_at, or it indexes
    // every team channel in the app to answer a question about one user's Scout.
    const threadIdx = idx.get('idx_chat_channels_assistant') || '';
    check(/WHERE/i.test(threadIdx) && /assistant/i.test(threadIdx) && /archived_at/i.test(threadIdx),
      "idx_chat_channels_assistant is partial on type='assistant' AND archived_at IS NULL "
      + '(the thread list never scans team channels or deleted threads)');

    // pg_trgm is optional by design (see deviation d in the .sql). Report which
    // path KB search will take rather than pass/fail on it.
    const { rows: trgm } = await client.query(
      `SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm'`,
    );
    const useTrgm = trgm.length > 0 && idx.has('idx_assistant_kb_trgm');
    if (useTrgm) {
      check(true, 'pg_trgm present and idx_assistant_kb_trgm built — KB search uses trigram similarity');
    } else if (trgm.length) {
      console.log('   ~ pg_trgm is installed but idx_assistant_kb_trgm was not built (usually the');
      console.log('     extension sits in a schema this role cannot see on its search_path,');
      console.log('     so gin_trgm_ops does not resolve). KB search falls back to token overlap.');
    } else {
      console.log('   ~ pg_trgm unavailable on this database — KB search falls back to token');
      console.log('     overlap (slower, still correct). Not a failure.');
    }

    // ─── 4. Constraints ─────────────────────────────────────────────────────
    const { rows: conRows } = await client.query(
      `SELECT con.conname, pg_get_constraintdef(con.oid) AS def
         FROM pg_constraint con
         JOIN pg_class rel ON rel.oid = con.conrelid
         JOIN pg_namespace ns ON ns.oid = rel.relnamespace
        WHERE ns.nspname = 'public' AND con.contype IN ('c', 'u')`,
    );
    const cons = new Map(conRows.map((r) => [r.conname, r.def]));
    const missingCons = EXPECTED_CONSTRAINTS.filter((n) => !cons.has(n));
    check(missingCons.length === 0,
      `all ${EXPECTED_CONSTRAINTS.length} CHECK constraint(s) exist`
      + `${missingCons.length ? ` — MISSING: ${missingCons.join(', ')}` : ''}`);

    // The kind enumeration must now carry 'assistant' AND still carry 015's four —
    // a DROP-then-ADD that lost one would silently make every voice note
    // unwritable, and nothing in the assistant would notice.
    const kindDef = cons.get('chk_chat_messages_kind') || '';
    const kindsOk = ['text', 'image', 'audio', 'system', 'assistant']
      .every((k) => kindDef.includes(`'${k}'`));
    check(kindsOk,
      "chk_chat_messages_kind carries all five kinds including 'assistant' "
      + `(the DROP-then-ADD kept 015's four)${kindsOk ? '' : ` — got: ${kindDef}`}`);

    // The money-and-policy firewall, by definition.
    const fwDef = cons.get('chk_assistant_kb_intent') || '';
    const fwIntents = ['wallet_balance', 'refund_policy', 'cancel_booking', 'book_venue', 'topup_help'];
    const fwOk = fwIntents.every((i) => fwDef.includes(i));
    check(fwOk,
      `chk_assistant_kb_intent names all ${fwIntents.length} money/policy intents — a learned, `
      + `human-typed answer can never be served for them${fwOk ? '' : ` — got: ${fwDef}`}`);

    // ─── 5. Functional probes — do the constraints actually constrain? ───────
    // Everything below runs inside a transaction that is ALWAYS rolled back, and
    // every insert expected to fail gets its own SAVEPOINT: without one, the first
    // 23505/23514 aborts the transaction and every later query dies with 25P02
    // instead of reporting a result.
    const tryInsert = async (label, fn) => {
      await client.query(`SAVEPOINT ${label}`);
      try {
        const r = await fn();
        await client.query(`ROLLBACK TO SAVEPOINT ${label}`);
        return { ok: true, code: null, rows: r && r.rows };
      } catch (e) {
        await client.query(`ROLLBACK TO SAVEPOINT ${label}`);
        return { ok: false, code: e.code };
      }
    };

    // The probes need a real user and a real venue (both are FK targets). A
    // seeded dev database has them; an empty one skips with a note — the
    // constraints are still proven to EXIST above, the probes are the bonus.
    const { rows: userRow } = await client.query('SELECT id FROM users LIMIT 1');
    const { rows: venueRow } = await client.query(
      'SELECT id, owner_id FROM venues ORDER BY created_at LIMIT 1',
    );

    if (userRow.length && venueRow.length) {
      const uid = userRow[0].id;
      const vid = venueRow[0].id;
      const oid = venueRow[0].owner_id;

      await client.query('BEGIN');
      try {
        // 5a. THE ONE THAT MAKES "new chat" POSSIBLE. 015's
        //     ux_chat_channels_type_ref is UNIQUE (type, ref_id) WHERE ref_id IS
        //     NOT NULL. Scout's threads carry ref_id = NULL, so the index must not
        //     apply and a user may hold many. Proven, not assumed.
        const { rows: [chA] } = await client.query(
          `INSERT INTO chat_channels (type, ref_id, created_by, title, assistant_persona)
           VALUES ('assistant', NULL, $1, '__mig018 probe A', 'player') RETURNING id`,
          [uid],
        );
        const second = await tryInsert('p1', () => client.query(
          `INSERT INTO chat_channels (type, ref_id, created_by, title, assistant_persona)
           VALUES ('assistant', NULL, $1, '__mig018 probe B', 'player') RETURNING id`,
          [uid],
        ));
        check(second.ok,
          'a SECOND assistant thread for the same user is allowed — ux_chat_channels_type_ref '
          + 'does not apply to ref_id IS NULL rows, which is what "new chat" stands on'
          + `${second.ok ? '' : ` — REJECTED with ${second.code}`}`);

        // 5b. A persona outside the two the dialog manager can serve.
        const badPersona = await tryInsert('p2', () => client.query(
          `INSERT INTO chat_channels (type, ref_id, created_by, assistant_persona)
           VALUES ('assistant', NULL, $1, 'captain')`, [uid]));
        check(!badPersona.ok && badPersona.code === '23514',
          `assistant_persona='captain' is rejected (23514) — only player|owner exist`
          + `${badPersona.ok ? ' — IT WAS ACCEPTED' : ''}`);

        // 5c. A persona on a NON-assistant channel: a team chat has no persona,
        //     and one there would silently route team messages to the dialog manager.
        const personaOnTeam = await tryInsert('p3', () => client.query(
          `INSERT INTO chat_channels (type, ref_id, created_by, assistant_persona)
           VALUES ('team', NULL, $1, 'player')`, [uid]));
        check(!personaOnTeam.ok && personaOnTeam.code === '23514',
          `assistant_persona on a type='team' channel is rejected (23514)`
          + `${personaOnTeam.ok ? ' — IT WAS ACCEPTED' : ''}`);

        // 5d. session_state round-trips as jsonb, and DEFAULTs to an empty object
        //     rather than NULL on a thread nothing has written yet.
        const { rows: [freshState] } = await client.query(
          'SELECT session_state FROM chat_channels WHERE id = $1', [chA.id]);
        check(freshState && JSON.stringify(freshState.session_state) === '{}',
          `a brand-new thread reads session_state = {} (not NULL) — got `
          + `${JSON.stringify(freshState && freshState.session_state)}`);
        await client.query(
          `UPDATE chat_channels SET session_state = $2 WHERE id = $1`,
          [chA.id, JSON.stringify({ v: 1, intent: 'book_venue', slots: { sport: 'football' } })]);
        const { rows: [savedState] } = await client.query(
          `SELECT session_state->>'intent' AS intent,
                  session_state->'slots'->>'sport' AS sport
             FROM chat_channels WHERE id = $1`, [chA.id]);
        check(savedState && savedState.intent === 'book_venue' && savedState.sport === 'football',
          'a half-filled slot set survives a write/read cycle as queryable jsonb '
          + '(this is what makes turn 2 of a booking possible)');

        // 5e. Scout's own message: kind='assistant', sender_id NULL, cards in the
        //     payload. And the shape the wave spec forbids — a card with no
        //     sentence — refused by the database rather than by a code review.
        const { rows: [msg] } = await client.query(
          `INSERT INTO chat_messages (channel_id, sender_id, kind, body, assistant_payload)
           VALUES ($1, NULL, 'assistant', '__mig018 probe reply', $2) RETURNING id`,
          [chA.id, JSON.stringify({
            source: 'live', intent: 'find_venue', confidence: 0.81,
            cards: [{ type: 'venue', data: { id: vid } }],
            chips: [{ label: 'Directions', action: 'navigate', args: { venueId: vid } }],
          })],
        );
        check(!!msg.id, "an assistant message stores kind='assistant' with sender_id NULL and a payload");
        const { rows: [readBack] } = await client.query(
          `SELECT assistant_payload->>'source' AS source,
                  jsonb_array_length(assistant_payload->'cards') AS n_cards,
                  assistant_payload->'chips'->0->>'action' AS chip_action
             FROM chat_messages WHERE id = $1`, [msg.id]);
        check(readBack && readBack.source === 'live' && Number(readBack.n_cards) === 1
              && readBack.chip_action === 'navigate',
          'cards and chips are queryable inside assistant_payload — a chip can carry an '
          + "action ('navigate') that assistant-intents-v1 has no label for");

        const emptyAssistant = await tryInsert('p4', () => client.query(
          `INSERT INTO chat_messages (channel_id, sender_id, kind, body, assistant_payload)
           VALUES ($1, NULL, 'assistant', NULL, '{"cards":[]}'::jsonb)`, [chA.id]));
        check(!emptyAssistant.ok && emptyAssistant.code === '23514',
          'an assistant message with cards but NO text is rejected (23514) — the wave spec '
          + `forbids a free-text-less dead end${emptyAssistant.ok ? ' — IT WAS ACCEPTED' : ''}`);

        // 5f. Feedback: a vote is ±1, one per user per message, changeable but not
        //     stuffable. This is the only signal that says an answer was WRONG.
        await client.query(
          `INSERT INTO assistant_feedback (message_id, user_id, vote) VALUES ($1, $2, -1)`,
          [msg.id, uid]);
        const dupVote = await tryInsert('p5', () => client.query(
          `INSERT INTO assistant_feedback (message_id, user_id, vote) VALUES ($1, $2, 1)`,
          [msg.id, uid]));
        check(!dupVote.ok && dupVote.code === '23505',
          `a second vote by the same user on the same message is rejected (23505)`
          + `${dupVote.ok ? ' — IT WAS ACCEPTED' : ''}`);
        const zeroVote = await tryInsert('p6', () => client.query(
          `INSERT INTO assistant_feedback (message_id, user_id, vote) VALUES ($1, $2, 0)`,
          [msg.id, uid]));
        check(!zeroVote.ok && zeroVote.code === '23514',
          `vote = 0 is rejected (23514) — a rating has a direction${zeroVote.ok ? ' — IT WAS ACCEPTED' : ''}`);

        // 5g. THE FIREWALL. A human-typed answer must never be servable for a
        //     money or policy question, no matter what any future route does.
        const moneyKb = await tryInsert('p7', () => client.query(
          `INSERT INTO assistant_kb (scope, venue_id, question, answer, intent, status)
           VALUES ('venue', $1, 'kitna refund milega', 'poora paisa wapas', 'refund_policy', 'published')`,
          [vid]));
        check(!moneyKb.ok && moneyKb.code === '23514',
          `a KB row with intent='refund_policy' is rejected by the database (23514) — the money `
          + `and policy answers are computed or quoted, never remembered`
          + `${moneyKb.ok ? ' — IT WAS ACCEPTED, THE FIREWALL IS OPEN' : ''}`);
        const walletKb = await tryInsert('p8', () => client.query(
          `INSERT INTO assistant_kb (scope, venue_id, question, answer, intent)
           VALUES ('venue', $1, 'mera balance', '5000', 'wallet_balance')`, [vid]));
        check(!walletKb.ok && walletKb.code === '23514',
          `intent='wallet_balance' likewise rejected (23514)${walletKb.ok ? ' — IT WAS ACCEPTED' : ''}`);

        // 5h. Scope integrity: a venue fact must name its venue, and a global fact
        //     must not — either way round is a fact escaping the ground it is true of.
        const venueNoId = await tryInsert('p9', () => client.query(
          `INSERT INTO assistant_kb (scope, venue_id, question, answer)
           VALUES ('venue', NULL, 'floodlights hain?', 'ji haan')`));
        check(!venueNoId.ok && venueNoId.code === '23514',
          `scope='venue' with venue_id NULL is rejected (23514) — a fact about no ground`
          + `${venueNoId.ok ? ' — IT WAS ACCEPTED' : ''}`);
        const globalWithId = await tryInsert('p10', () => client.query(
          `INSERT INTO assistant_kb (scope, venue_id, question, answer)
           VALUES ('global', $1, 'floodlights hain?', 'ji haan')`, [vid]));
        check(!globalWithId.ok && globalWithId.code === '23514',
          `scope='global' carrying a venue_id is rejected (23514) — one ground's answer must `
          + `never be served for another${globalWithId.ok ? ' — IT WAS ACCEPTED' : ''}`);

        // 5i. question_norm is GENERATED, so fuzzy matching cannot be defeated by an
        //     INSERT that forgets to normalise. Punctuation squashed, case folded.
        const { rows: [kb1] } = await client.query(
          `INSERT INTO assistant_kb (scope, venue_id, owner_id, question, answer, status, intent)
           VALUES ('venue', $1, $2, 'Does G-11 ground have FLOODLIGHTS at night?',
                   'Yes — floodlights run until 11pm.', 'published', 'venue_info')
           RETURNING question_norm`, [vid, oid]);
        check(kb1.question_norm === 'does g 11 ground have floodlights at night',
          `question_norm is derived by the database, lowercased and punctuation-squashed `
          + `— got "${kb1.question_norm}"`);

        // 5j. Fuzzy retrieval actually retrieves. "does g11 have lights" shares no
        //     exact phrase with the stored question, and that is the whole point: a
        //     KB that only answers verbatim repeats would never serve a second user.
        if (useTrgm) {
          const { rows: hits } = await client.query(
            `SELECT similarity(question_norm, $2) AS sim FROM assistant_kb
              WHERE scope='venue' AND venue_id=$1 AND status='published'
                AND similarity(question_norm, $2) > 0.2
              ORDER BY sim DESC LIMIT 1`,
            [vid, 'does g11 ground have lights']);
          check(hits.length === 1 && Number(hits[0].sim) > 0.2,
            `a paraphrase ("does g11 ground have lights") retrieves the stored floodlights `
            + `answer by trigram similarity${hits.length ? ` (sim=${Number(hits[0].sim).toFixed(3)})` : ' — NO HIT'}`);
        }

        // 5k. Escalation: 'answered' with no answer would show the owner a resolved
        //     question and leave the player with nothing.
        const { rows: [esc] } = await client.query(
          `INSERT INTO assistant_escalations
             (user_id, channel_id, message_id, venue_id, owner_id, question, intent, confidence)
           VALUES ($1,$2,$3,$4,$5,'washroom hai?','venue_info',0.3122) RETURNING id, status`,
          [uid, chA.id, msg.id, vid, oid]);
        check(esc.status === 'open', `a new escalation opens as 'open' — got '${esc.status}'`);
        const hollow = await tryInsert('p11', () => client.query(
          `UPDATE assistant_escalations SET status='answered' WHERE id=$1`, [esc.id]));
        check(!hollow.ok && hollow.code === '23514',
          `marking an escalation 'answered' without an answer is rejected (23514)`
          + `${hollow.ok ? ' — IT WAS ACCEPTED' : ''}`);
        await client.query(
          `UPDATE assistant_escalations SET status='answered', answer='Ji, washroom available hai.',
             answered_by=$2, answered_at=NOW() WHERE id=$1`, [esc.id, oid]);
        check(true, "an escalation WITH an answer moves to 'answered' (the learning loop's happy path)");

        // 5l. Telemetry rejects an input_mode outside text|chip, because the split
        //     between them is what keeps chip traffic out of the model's measured
        //     accuracy — where it would flatter it enormously.
        await client.query(
          `INSERT INTO assistant_turns
             (user_id, channel_id, input_mode, text_chars, intent, confidence, abstained,
              action, action_ok, answer_source, fsm_state, nlu_ms, total_ms)
           VALUES ($1,$2,'text',34,'find_venue',0.8135,false,'find_venue',true,'live','idle',41,96)`,
          [uid, chA.id]);
        const badMode = await tryInsert('p12', () => client.query(
          `INSERT INTO assistant_turns (user_id, input_mode) VALUES ($1, 'voice')`, [uid]));
        check(!badMode.ok && badMode.code === '23514',
          `assistant_turns.input_mode='voice' is rejected (23514) — only text|chip exist`
          + `${badMode.ok ? ' — IT WAS ACCEPTED' : ''}`);
        const badSource = await tryInsert('p13', () => client.query(
          `INSERT INTO assistant_turns (user_id, answer_source) VALUES ($1, 'guess')`, [uid]));
        check(!badSource.ok && badSource.code === '23514',
          `answer_source='guess' is rejected (23514) — the six honest sources are the whole set`
          + `${badSource.ok ? ' — IT WAS ACCEPTED' : ''}`);
      } finally {
        await client.query('ROLLBACK');   // nothing above may survive
      }

      const { rows: [{ leftover }] } = await client.query(
        `SELECT (SELECT count(*)::int FROM chat_channels WHERE title LIKE '__mig018%')
              + (SELECT count(*)::int FROM assistant_kb WHERE question LIKE 'Does G-11%')
                AS leftover`,
      );
      check(leftover === 0, `probe rolled back cleanly — ${leftover} probe row(s) left behind`);
    } else {
      console.log('   ~ skipped the functional probes (need one users row and one venues row)');
    }

    // ─── 6. Seeds ───────────────────────────────────────────────────────────
    // These the migration COMMITS, so they are read outside the probe transaction.
    const { rows: [asstRow] } = await client.query(
      `SELECT value FROM global_settings WHERE key = 'assistant'`,
    );
    const settings = (asstRow && asstRow.value) || {};
    const policyText = settings.policy_text || {};
    const WANT_POLICY = ['refund_policy', 'deposit', 'no_show', 'checkin', 'approval', 'topup', 'withdrawal'];
    const missingPolicy = WANT_POLICY.filter((k) => !policyText[k]);
    check(settings.name === 'Scout' && missingPolicy.length === 0,
      `global_settings.assistant seeded: name='${settings.name}' and all ${WANT_POLICY.length} `
      + `policy templates present${missingPolicy.length ? ` — MISSING: ${missingPolicy.join(', ')}` : ''}`);

    // Every number in the policy text must still be a {placeholder}. A literal
    // "20%" here is a second source of truth for a money rule (golden rule 3),
    // and it goes stale in silence the day escrow.js POLICY changes.
    const hardNumbers = Object.entries(policyText)
      .filter(([, v]) => /(?<!\{)\b\d+\s*(%|hours|hrs|minutes|mins)\b/i.test(String(v)))
      .map(([k]) => k);
    check(hardNumbers.length === 0,
      'no policy template hard-codes a money or timing number — every one is a {placeholder} '
      + `filled from escrow.js POLICY at render time`
      + `${hardNumbers.length ? ` — LITERAL NUMBER IN: ${hardNumbers.join(', ')}` : ''}`);

    const { rows: [kbCount] } = await client.query(
      `SELECT count(*)::int AS n FROM assistant_kb
        WHERE scope='global' AND status='published' AND source='admin'`,
    );
    check(kbCount.n >= 4,
      `${kbCount.n} published global how-to answer(s) seeded (create team, find opponents, `
      + `ELO, tournaments) — Scout can answer these on turn 1 with no owner involved`);

    // ─── Listing ────────────────────────────────────────────────────────────
    console.log('');
    console.log('Scout can now hold a conversation, and the database enforces:');
    console.log('   • many assistant threads per user       — new chat / switch chat / rename');
    console.log('   • session_state jsonb per thread        — slot filling survives the request');
    console.log("   • kind='assistant' + assistant_payload  — cards and chips, never a dead end");
    console.log('   • KB approval gate (draft→published)    — an owner must approve what Scout learns');
    console.log('   • KB venue scope + money firewall       — a learned answer cannot cross grounds,');
    console.log('                                             and can never answer about money');
    console.log('   • text-free turn telemetry              — the utterance is never logged');
  } catch (e) {
    failures.push(`migration threw: ${e.message}`);
    console.error('');
    console.error('❌ Migration 018 failed:', e.message);
    if (e.detail) console.error('   detail:', e.detail);
    if (e.hint) console.error('   hint:', e.hint);
  } finally {
    client.release();
    await pool.end();
  }

  console.log('');
  if (failures.length) {
    console.error(`❌ Migration 018: ${failures.length} check(s) failed.`);
  } else {
    console.log('✅ Migration 018 verified — Scout persistence layer ready.');
  }
  process.exit(failures.length ? 1 : 0);
}

run();
