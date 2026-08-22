/**
 * Runner for migrations/015_teams_chat.sql
 * Usage: node run_migration_015.js
 *
 * Applied as ONE multi-statement command, so Postgres wraps it in a single
 * implicit transaction and a failure anywhere leaves the database untouched.
 * (No `-- @@SPLIT@@` marker: this migration adds no enum values, and
 * `ALTER TYPE ... ADD VALUE` is the only statement that cannot run inside a
 * transaction.)
 *
 * Two things make this runner more than a `\d` dump:
 *
 *   1. A PRE-FLIGHT that can stop the migration. ux_teams_name_sport is a UNIQUE
 *      index over live data — if two football teams are already called "Lahore
 *      Lions", CREATE UNIQUE INDEX fails with a 23505 whose message names the
 *      index, not the teams. So the duplicates are found and PRINTED first, and
 *      the migration is not attempted, because "rename one of these two teams"
 *      is a decision for a human and not something a migration may do silently.
 *
 *   2. FUNCTIONAL PROBES. Six of the guarantees here are constraints, and a
 *      constraint that exists but does not constrain is worse than no constraint
 *      — it reads as enforced in the schema and is enforced nowhere. Each probe
 *      inserts a row that MUST be rejected and asserts the SQLSTATE, inside a
 *      transaction that is always rolled back.
 *
 * Safe to re-run: every statement in the .sql is idempotent.
 */
const fs = require('fs');
const path = require('path');
const pool = require('./src/db/pool');

// 015 alters or references all of these. A missing one means schema.sql or 013
// was never applied, and the first ALTER would abort with a bare 42P01.
const PREREQUISITE_TABLES = [
  'users', 'teams', 'team_members', 'team_invites', 'team_join_requests',
  'chat_channels', 'chat_messages',
];

const EXPECTED_TABLES = ['chat_channel_members', 'chat_reactions'];

const EXPECTED_INDEXES = [
  // teams
  'ux_teams_name_sport',
  'idx_team_members_user',
  'idx_teams_sport_elo',
  'idx_teams_visibility_sport',
  // invites / requests
  'ux_team_invites_token_hash',
  'idx_team_invites_team',
  'idx_join_requests_team_status',
  // chat
  'ux_chat_channels_type_ref',
  'idx_chat_members_user_active',
  'ux_chat_messages_client',
  'idx_chat_messages_media',
];

const EXPECTED_CONSTRAINTS = [
  'chk_team_members_role',
  'chk_join_requests_status',
  'chk_chat_channels_type',
  'chk_chat_messages_kind',
  'chk_chat_messages_payload',
  'chk_chat_member_role',
];

// column → information_schema.data_type, per table.
const EXPECTED_COLUMNS = {
  team_invites: {
    token_hash: 'text', token_prefix: 'text',
    revoked_at: 'timestamp with time zone', used_at: 'timestamp with time zone',
  },
  team_join_requests: {
    decided_at: 'timestamp with time zone', decided_by: 'uuid', message: 'text',
  },
  chat_channels: {
    title: 'text', image_url: 'text', created_by: 'uuid',
    last_message_at: 'timestamp with time zone',
    last_message_preview: 'text', last_message_sender_id: 'uuid',
    message_count: 'integer',
  },
  chat_channel_members: {
    channel_id: 'uuid', user_id: 'uuid', role: 'text',
    left_at: 'timestamp with time zone',
    last_read_at: 'timestamp with time zone',
    last_delivered_at: 'timestamp with time zone',
    muted_until: 'timestamp with time zone',
  },
  chat_messages: {
    client_id: 'text', kind: 'text', media_url: 'text', media_mime: 'text',
    media_bytes: 'integer', duration_ms: 'integer', waveform: 'jsonb',
    reply_to_id: 'uuid', edited_at: 'timestamp with time zone',
    deleted_at: 'timestamp with time zone', system_meta: 'jsonb',
  },
  chat_reactions: { message_id: 'uuid', user_id: 'uuid', emoji: 'text' },
  users: { last_seen_at: 'timestamp with time zone' },
  team_members: { invited_by: 'uuid' },
};

async function tableNames(client) {
  const { rows } = await client.query(
    `SELECT table_name FROM information_schema.tables
      WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
      ORDER BY table_name`,
  );
  return rows.map((r) => r.table_name);
}

async function run() {
  const sqlFile = path.join(__dirname, 'migrations', '015_teams_chat.sql');
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
      console.error('❌ Cannot apply migration 015 — prerequisite tables missing:');
      console.error(`   ${missingPrereqs.join(', ')}`);
      console.error('   Apply schema.sql, then run_migration_013.js first.');
      client.release();
      await pool.end();
      process.exit(1);
    }

    // The one thing in this migration that can fail on real data.
    const { rows: dupes } = await client.query(
      `SELECT sport::text AS sport, lower(btrim(name)) AS key,
              count(*)::int AS n,
              string_agg(DISTINCT name, ' | ') AS variants
         FROM teams
        GROUP BY 1, 2
       HAVING count(*) > 1
        ORDER BY n DESC`,
    );
    if (dupes.length) {
      console.error('❌ Cannot apply migration 015 — duplicate team names block');
      console.error('   the FR2.1 unique index ux_teams_name_sport:');
      console.error('');
      for (const d of dupes) {
        console.error(`   ${d.sport}: ${d.n}× "${d.key}"  →  ${d.variants}`);
      }
      console.error('');
      console.error('   Rename or delete one of each pair, then re-run. A migration');
      console.error('   must not pick which team keeps the name.');
      client.release();
      await pool.end();
      process.exit(1);
    }

    const { rows: [{ teams: teamCount }] } = await client.query(
      'SELECT count(*)::int AS teams FROM teams',
    );
    console.log(`Pre-flight: ${before.length} tables present, all prerequisites found.`);
    console.log(`   ${teamCount} team(s), no duplicate names per sport.`);
    for (const t of EXPECTED_TABLES) {
      if (before.includes(t)) console.log(`   (re-run — ${t} already present)`);
    }
    console.log('');

    // ─── Apply ──────────────────────────────────────────────────────────────
    await client.query(sql);
    console.log('Migration 015 applied. Verifying:');
    console.log('');

    // ─── 1. Tables ──────────────────────────────────────────────────────────
    const after = await tableNames(client);
    const missingTables = EXPECTED_TABLES.filter((t) => !after.includes(t));
    check(missingTables.length === 0,
      `both new tables exist${missingTables.length ? ` — MISSING: ${missingTables.join(', ')}` : ''}`);

    // ─── 2. Columns ─────────────────────────────────────────────────────────
    const { rows: cols } = await client.query(
      `SELECT table_name, column_name, data_type, is_nullable
         FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = ANY($1)`,
      [Object.keys(EXPECTED_COLUMNS)],
    );
    const typeOf = new Map(cols.map((r) => [`${r.table_name}.${r.column_name}`, r.data_type]));
    const nullableOf = new Map(cols.map((r) => [`${r.table_name}.${r.column_name}`, r.is_nullable]));

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
      `all ${colTotal} columns present with the right type${badCols.length ? ` — WRONG: ${badCols.join('; ')}` : ''}`);

    // body had to become nullable, or an image message cannot be stored at all.
    check(nullableOf.get('chat_messages.body') === 'YES',
      'chat_messages.body is now NULLABLE (image/voice rows carry no body)');
    // token had to become nullable, or a hashed-only invite cannot be inserted.
    check(nullableOf.get('team_invites.token') === 'YES' ||
          typeOf.get('team_invites.token') === undefined,
      'team_invites.token is now NULLABLE (tokens are stored hashed)');

    // ─── 3. Indexes ─────────────────────────────────────────────────────────
    const { rows: idxRows } = await client.query(
      `SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = 'public'`,
    );
    const idx = new Map(idxRows.map((r) => [r.indexname, r.indexdef]));
    const missingIdx = EXPECTED_INDEXES.filter((n) => !idx.has(n));
    check(missingIdx.length === 0,
      `all ${EXPECTED_INDEXES.length} indexes exist${missingIdx.length ? ` — MISSING: ${missingIdx.join(', ')}` : ''}`);

    // The three that must have a specific SHAPE, not just a name.
    const nameIdx = idx.get('ux_teams_name_sport') || '';
    check(/CREATE UNIQUE INDEX/i.test(nameIdx) && /lower/i.test(nameIdx) && /btrim/i.test(nameIdx),
      'ux_teams_name_sport is UNIQUE and case/whitespace-insensitive (FR2.1)');

    const chanIdx = idx.get('ux_chat_channels_type_ref') || '';
    check(/CREATE UNIQUE INDEX/i.test(chanIdx) && /WHERE/i.test(chanIdx),
      'ux_chat_channels_type_ref is UNIQUE and partial — one team, one chat');

    const clientIdx = idx.get('ux_chat_messages_client') || '';
    check(/CREATE UNIQUE INDEX/i.test(clientIdx) && /client_id IS NOT NULL/i.test(clientIdx),
      'ux_chat_messages_client is UNIQUE and partial — idempotent send');

    // Deviation c: the non-unique predecessor must be GONE, not left alongside.
    check(!idx.has('idx_chat_channels_ref'),
      'idx_chat_channels_ref dropped (replaced by the unique index above)');

    // ─── 4. CHECK constraints exist ─────────────────────────────────────────
    const { rows: conRows } = await client.query(
      `SELECT con.conname, rel.relname AS tbl, pg_get_constraintdef(con.oid) AS def
         FROM pg_constraint con
         JOIN pg_class rel ON rel.oid = con.conrelid
         JOIN pg_namespace ns ON ns.oid = rel.relnamespace
        WHERE ns.nspname = 'public' AND con.contype = 'c'`,
    );
    const cons = new Map(conRows.map((r) => [r.conname, r.def]));
    const missingCons = EXPECTED_CONSTRAINTS.filter((n) => !cons.has(n));
    check(missingCons.length === 0,
      `all ${EXPECTED_CONSTRAINTS.length} CHECK constraints exist${missingCons.length ? ` — MISSING: ${missingCons.join(', ')}` : ''}`);

    check(/vice_captain/.test(cons.get('chk_team_members_role') || ''),
      'chk_team_members_role allows captain / vice_captain / member');
    check(/audio/.test(cons.get('chk_chat_messages_kind') || ''),
      'chk_chat_messages_kind allows text / image / audio / system');

    // ─── 5. Backfill actually happened ──────────────────────────────────────
    const { rows: [bf] } = await client.query(
      `SELECT
         (SELECT count(*)::int FROM teams)                                    AS teams,
         (SELECT count(*)::int FROM chat_channels WHERE type = 'team')        AS channels,
         (SELECT count(*)::int FROM team_members)                             AS members,
         (SELECT count(*)::int FROM chat_channel_members)                     AS chat_members,
         (SELECT count(*)::int FROM teams t WHERE NOT EXISTS (
            SELECT 1 FROM chat_channels c WHERE c.type='team' AND c.ref_id=t.id)) AS teams_without_chat,
         (SELECT count(*)::int FROM teams t WHERE NOT EXISTS (
            SELECT 1 FROM team_members m WHERE m.team_id=t.id AND m.role='captain')) AS teams_without_captain`,
    );
    check(bf.teams_without_chat === 0,
      `every team has a chat channel (${bf.channels} channel(s) for ${bf.teams} team(s))`);
    check(bf.chat_members >= bf.members,
      `every roster member mirrored into chat (${bf.chat_members} chat member(s) for ${bf.members} roster row(s))`);
    // Teams with captain_id NULL cannot be fixed by a backfill — report, don't fail.
    if (bf.teams_without_captain > 0) {
      console.log(`   ~ ${bf.teams_without_captain} team(s) still have no captain (captain_id was NULL) — FR2.10 will be enforced from creation onward`);
    } else {
      check(true, 'every team has at least one captain in team_members (FR2.10)');
    }

    // ─── 6. Functional probes — do the constraints actually constrain? ───────
    // Everything below runs inside a transaction that is ALWAYS rolled back, and
    // every insert expected to fail gets its own SAVEPOINT: without one, the
    // first 23505 aborts the transaction and every later query dies with 25P02
    // instead of reporting a result.
    const tryInsert = async (label, fn) => {
      await client.query(`SAVEPOINT ${label}`);
      try {
        await fn();
        await client.query(`ROLLBACK TO SAVEPOINT ${label}`);
        return { ok: true, code: null };
      } catch (e) {
        await client.query(`ROLLBACK TO SAVEPOINT ${label}`);
        return { ok: false, code: e.code };
      }
    };

    await client.query('BEGIN');
    try {
      // 6a. FR2.1 — the same name twice in the same sport.
      await client.query(
        `INSERT INTO teams (name, sport) VALUES ('__mig015 Probe FC', 'football')`);
      const sameName = await tryInsert('t1', () => client.query(
        `INSERT INTO teams (name, sport) VALUES ('  __MIG015 probe fc  ', 'football')`));
      const otherSport = await tryInsert('t2', () => client.query(
        `INSERT INTO teams (name, sport) VALUES ('__mig015 Probe FC', 'cricket')`));

      check(!sameName.ok && sameName.code === '23505',
        `the same team name in the same sport is rejected (23505) — FR2.1 enforced by the DB${sameName.ok ? ' — IT WAS ACCEPTED' : ` — got ${sameName.code}`}`);
      check(otherSport.ok,
        'the same name in a DIFFERENT sport is allowed (unique is per-sport, not global)');

      // 6b. Roles.
      const { rows: probeTeam } = await client.query(
        `SELECT id FROM teams WHERE name = '__mig015 Probe FC' AND sport = 'football'`);
      const { rows: someUser } = await client.query('SELECT id FROM users LIMIT 1');
      if (probeTeam.length && someUser.length) {
        const tid = probeTeam[0].id;
        const uid = someUser[0].id;
        const badRole = await tryInsert('t3', () => client.query(
          `INSERT INTO team_members (team_id, user_id, role) VALUES ($1,$2,'captian')`,
          [tid, uid]));
        check(!badRole.ok && badRole.code === '23514',
          `role='captian' (typo) rejected by chk_team_members_role${badRole.ok ? ' — IT WAS ACCEPTED' : ''}`);

        // 6c. One team, one chat.
        await client.query(
          `INSERT INTO chat_channels (type, ref_id, title) VALUES ('team',$1,'probe')`, [tid]);
        const dupChannel = await tryInsert('t4', () => client.query(
          `INSERT INTO chat_channels (type, ref_id, title) VALUES ('team',$1,'probe 2')`, [tid]));
        check(!dupChannel.ok && dupChannel.code === '23505',
          `a SECOND chat channel for the same team is rejected (23505)${dupChannel.ok ? ' — IT WAS ACCEPTED' : ''}`);

        // 6d. Message payload + idempotency + reactions.
        const { rows: [chan] } = await client.query(
          `SELECT id FROM chat_channels WHERE type='team' AND ref_id=$1`, [tid]);
        const emptyText = await tryInsert('t5', () => client.query(
          `INSERT INTO chat_messages (channel_id, sender_id, kind, body)
           VALUES ($1,$2,'text','   ')`, [chan.id, uid]));
        check(!emptyText.ok && emptyText.code === '23514',
          `a whitespace-only text message is rejected by chk_chat_messages_payload${emptyText.ok ? ' — IT WAS ACCEPTED' : ''}`);

        const imageNoUrl = await tryInsert('t6', () => client.query(
          `INSERT INTO chat_messages (channel_id, sender_id, kind) VALUES ($1,$2,'image')`,
          [chan.id, uid]));
        check(!imageNoUrl.ok && imageNoUrl.code === '23514',
          `an image message with no media_url is rejected${imageNoUrl.ok ? ' — IT WAS ACCEPTED' : ''}`);

        // The escape hatch has to work too, or "delete for everyone" cannot
        // clear the content it is supposed to clear.
        const tombstone = await tryInsert('t9', () => client.query(
          `INSERT INTO chat_messages (channel_id, sender_id, kind, deleted_at, deleted_by)
           VALUES ($1,$2,'text',now(),$2)`, [chan.id, uid]));
        check(tombstone.ok,
          'a deleted tombstone with NO body or media is allowed (delete-for-everyone really erases)');

        const { rows: [msg] } = await client.query(
          `INSERT INTO chat_messages (channel_id, sender_id, kind, body, client_id)
           VALUES ($1,$2,'text','probe','cid-mig015') RETURNING id`, [chan.id, uid]);
        const replay = await tryInsert('t7', () => client.query(
          `INSERT INTO chat_messages (channel_id, sender_id, kind, body, client_id)
           VALUES ($1,$2,'text','probe again','cid-mig015')`, [chan.id, uid]));
        check(!replay.ok && replay.code === '23505',
          `a replayed send with the same client_id is rejected (23505) — retries cannot duplicate${replay.ok ? ' — IT WAS ACCEPTED' : ''}`);

        await client.query(
          `INSERT INTO chat_reactions (message_id, user_id, emoji) VALUES ($1,$2,'👍')`,
          [msg.id, uid]);
        const twoReactions = await tryInsert('t8', () => client.query(
          `INSERT INTO chat_reactions (message_id, user_id, emoji) VALUES ($1,$2,'❤️')`,
          [msg.id, uid]));
        check(!twoReactions.ok && twoReactions.code === '23505',
          `a second reaction from the same user is rejected (the route UPSERTs instead)${twoReactions.ok ? ' — IT WAS ACCEPTED' : ''}`);
      } else {
        console.log('   ~ skipped role/chat probes (no users row to attach a member to)');
      }
    } finally {
      await client.query('ROLLBACK');   // nothing above may survive
    }

    const { rows: [{ n, c }] } = await client.query(
      `SELECT (SELECT count(*)::int FROM teams WHERE name LIKE '__mig015%') AS n,
              (SELECT count(*)::int FROM chat_messages WHERE client_id = 'cid-mig015') AS c`,
    );
    check(n === 0 && c === 0,
      `probe rolled back cleanly — ${n} probe team(s), ${c} probe message(s) left behind`);

    // ─── Listing ────────────────────────────────────────────────────────────
    console.log('');
    const created = after.filter((t) => !before.includes(t));
    console.log(`Tables now in public (${after.length}):`);
    for (const t of after) {
      console.log(`   ${created.includes(t) ? '+' : ' '} ${t}`);
    }
    console.log('');
    console.log(created.length
      ? `Created this run: ${created.join(', ')}`
      : 'Created this run: none (idempotent re-run).');
  } catch (e) {
    failures.push(`migration threw: ${e.message}`);
    console.error('');
    console.error('❌ Migration 015 failed:', e.message);
    if (e.detail) console.error('   detail:', e.detail);
    if (e.hint) console.error('   hint:', e.hint);
  } finally {
    client.release();
    await pool.end();
  }

  console.log('');
  if (failures.length) {
    console.error(`❌ Migration 015: ${failures.length} check(s) failed.`);
  } else {
    console.log('✅ Migration 015 verified — teams hardened, group chat ready.');
  }
  process.exit(failures.length ? 1 : 0);
}

run();
