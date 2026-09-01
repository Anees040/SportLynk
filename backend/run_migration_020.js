/**
 * Runner for migrations/020_notifications_admin.sql
 * Usage: node run_migration_020.js
 *
 * 020 turns `notifications` from a write-only log into a feed and adds the two
 * tables the admin module needs. It contains no `ALTER TYPE ... ADD VALUE`, so
 * unlike 019 it needs no chunking: the whole file is applied as one command and
 * Postgres wraps it in a single implicit transaction. A failure anywhere — the
 * timezone conversion, a backfill, a CHECK that a live row violates — leaves the
 * schema exactly as it was. The split mechanism below is kept identical to 019's
 * so that adding a marker later needs no change here.
 *
 * Why this runner is long. Four of 020's guarantees are load-bearing, and each
 * one is the sort of thing that reads as working while being broken:
 *
 *   1. The TIMEZONE conversion is one-way and must stay that way. 187 live rows
 *      are reinterpreted as UTC. The .sql guards on the current data type, so a
 *      second run does nothing; if that guard were on a column list instead,
 *      re-running would apply at time zone a second time and silently move every
 *      historical row by the session offset. The census asserts the resulting
 *      type and the default, because a converted column with a lost default would
 *      make the next INSERT write NULL and every "2 hours ago" read as never.
 *
 *   2. The collapse INDEX must be inferable. notify() v2 does
 *      `ON CONFLICT (user_id, group_key) WHERE <predicate> DO UPDATE` to turn
 *      three chat notifications into one row reading "3 new messages". Postgres
 *      infers a partial unique index only when the index predicate is implied by
 *      the ON CONFLICT WHERE clause — one word out of place and every grouped
 *      notify() raises 42P10 at runtime, inside a money transaction. So the probe
 *      below runs the real upsert twice and asserts group_count goes 1 -> 2.
 *
 *   3. Read and dismissed rows must be outside that index. Once the user has seen
 *      "2 new messages", the next message has to start a fresh row rather than
 *      bump a row already read (which would leave the feed permanently
 *      showing an old timestamp and never re-notify). Two probes prove a same-key
 *      row is accepted once the first is read, and again once it is dismissed.
 *
 *   4. The audit trail must outlive its subjects. admin_audit.admin_id is
 *      on DELETE SET NULL and user_devices.user_id is ON DELETE CASCADE, which is
 *      the opposite pairing on purpose: deleting an admin must not erase what they
 *      did, and deleting a user must not leave their push tokens behind. Both are
 *      proven by deleting a probe user inside the rolled-back transaction.
 *
 * Every probe writes rows that are always ROLLBACKed — this runs against the
 * shared Supabase database and must leave nothing behind.
 *
 * Safe to re-run: every statement in the .sql is idempotent.
 */
const fs = require('fs');
const path = require('path');
const pool = require('./src/db/pool');

// 020 alters or references all of these. A missing one means an earlier
// migration was never run.
const PREREQUISITE_TABLES = [
  'users', 'notifications', 'bookings', 'matches', 'teams', 'disputes',
];

// The two tables 020 creates.
const EXPECTED_TABLES = ['user_devices', 'admin_audit'];

const EXPECTED_INDEXES = [
  'idx_notifications_unread',
  'idx_notifications_outbox',
  'idx_notifications_category',
  'ux_notifications_group',
  'ux_user_devices_token',
  'idx_user_devices_user',
  'idx_admin_audit_created',
  'idx_admin_audit_entity',
  'idx_admin_audit_admin',
  'idx_users_role_active',
  'idx_disputes_queue',
];

// Indexes 020 depends on and deliberately does not re-create. idx_notifications_user
// (010) is what the feed's own user_id filter rides on; the two dispute indexes are
// what make the queue's joins cheap. An index relied on and never checked is one
// that can quietly go missing.
const INHERITED_INDEXES = [
  'idx_notifications_user',
  'idx_disputes_status',
  'ux_disputes_match_team',
];

const EXPECTED_CONSTRAINTS = [
  'chk_notifications_category',
  'chk_notifications_priority',
  'chk_notifications_group_count',
  'chk_notifications_entity',
  'chk_notifications_push_attempts',
  'chk_user_devices_platform',
  'chk_disputes_ruling',
  'chk_disputes_ruled_scores',
];

// Foreign keys (contype 'f'). notifications_actor_id_fkey is the one that matters:
// without it a deleted account leaves rows reading "<someone> sent you a message"
// pointing at a uuid that resolves to nothing, and the feed renders a blank avatar
// with a dead tap.
const EXPECTED_FKEYS = [
  'notifications_actor_id_fkey',
  'users_suspended_by_fkey',
  'user_devices_user_id_fkey',
  'admin_audit_admin_id_fkey',
];

// table -> column -> data_type. Presence and type, because a jsonb column that
// came out as text would accept every write and answer no query.
const EXPECTED_COLUMNS = {
  notifications: {
    created_at: 'timestamp with time zone',
    type: 'text',
    title: 'text',
    read_at: 'timestamp with time zone',
    dismissed_at: 'timestamp with time zone',
    category: 'text',
    priority: 'text',
    group_key: 'text',
    group_count: 'integer',
    deep_link: 'jsonb',
    actor_id: 'uuid',
    image_url: 'text',
    entity_type: 'text',
    entity_id: 'uuid',
    expires_at: 'timestamp with time zone',
    sent_push: 'boolean',
    push_attempts: 'integer',
    pushed_at: 'timestamp with time zone',
    push_error: 'text',
  },
  user_devices: {
    id: 'uuid',
    user_id: 'uuid',
    fcm_token: 'text',
    platform: 'text',
    app_version: 'text',
    device_label: 'text',
    created_at: 'timestamp with time zone',
    last_seen_at: 'timestamp with time zone',
    revoked_at: 'timestamp with time zone',
    revoke_reason: 'text',
  },
  admin_audit: {
    id: 'uuid',
    admin_id: 'uuid',
    action: 'text',
    entity_type: 'text',
    entity_id: 'uuid',
    before: 'jsonb',
    after: 'jsonb',
    note: 'text',
    created_at: 'timestamp with time zone',
  },
  users: {
    notification_prefs: 'jsonb',
    suspended_at: 'timestamp with time zone',
    suspended_reason: 'text',
    suspended_by: 'uuid',
  },
  disputes: {
    ruling: 'text',
    ruled_score_challenger: 'integer',
    ruled_score_opponent: 'integer',
    severity_elo: 'integer',
  },
};

// The columns whose NOT NULL + default are being relied on, not merely their
// presence. The outbox drain reads `WHERE sent_push = false`: a nullable sent_push
// would make every historical row invisible to it (NULL = false is NULL, not
// true), so the entire backlog would sit unpushed with no error anywhere.
// [table, column, expected is_nullable, expected default or null for "any"]
const EXPECTED_COLUMN_RULES = [
  ['notifications', 'created_at', 'YES', 'now()'],
  // is_read closed by §3: a NULL here is invisible to every `is_read = false`
  // predicate below, so the row would never reach the badge or the collapse index.
  ['notifications', 'is_read', 'NO', 'false'],
  ['notifications', 'category', 'NO', "'system'::text"],
  ['notifications', 'priority', 'NO', "'normal'::text"],
  ['notifications', 'group_count', 'NO', '1'],
  ['notifications', 'sent_push', 'NO', 'false'],
  ['notifications', 'push_attempts', 'NO', '0'],
  ['user_devices', 'user_id', 'NO', null],
  ['user_devices', 'fcm_token', 'NO', null],
  ['user_devices', 'created_at', 'NO', 'now()'],
  ['user_devices', 'last_seen_at', 'NO', 'now()'],
  ['admin_audit', 'action', 'NO', null],
  ['admin_audit', 'created_at', 'NO', 'now()'],
  ['users', 'notification_prefs', 'NO', "'{}'::jsonb"],
];

// Probe rows are tagged so the leftover sweep at the end can find any that
// escaped the ROLLBACK.
const PROBE_TAG = '__mig020 probe';

/** The marker, assembled so this source file never contains a literal one. */
const SPLIT_MARKER = `-- @@${'SPLIT'}@@`;

async function tableNames(client) {
  const { rows } = await client.query(
    `SELECT table_name FROM information_schema.tables
      WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
      ORDER BY table_name`,
  );
  return rows.map((r) => r.table_name);
}

async function run() {
  const sqlFile = path.join(__dirname, 'migrations', '020_notifications_admin.sql');
  const chunks = fs.readFileSync(sqlFile, 'utf8')
    .split(SPLIT_MARKER)
    .map((c) => c.trim())
    .filter((c) => c.length > 0);

  const client = await pool.connect();
  const failures = [];
  const check = (ok, label) => {
    if (ok) console.log(`   ✓ ${label}`);
    else { failures.push(label); console.log(`   ✗ ${label}`); }
  };

  try {
    // Pre-flight
    const before = await tableNames(client);
    const missingPrereqs = PREREQUISITE_TABLES.filter((t) => !before.includes(t));
    if (missingPrereqs.length) {
      console.error('❌ Cannot apply migration 020 — prerequisite tables missing:');
      console.error(`   ${missingPrereqs.join(', ')}`);
      console.error('   Apply schema.sql, then run_migration_010.js through 019.');
      client.release();
      await pool.end();
      process.exit(1);
    }

    // ux_notifications_group is a UNIQUE index over live data. Nothing writes
    // group_key today (the column is being added), so this can only fire on a
    // re-run — but a re-run after notify() v2 has been live is exactly when it
    // matters, and CREATE UNIQUE INDEX would fail with a 23505 that names the
    // index and not the rows.
    const hasGroupKey = await client.query(
      `SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'notifications'
          AND column_name = 'group_key'`,
    );
    if (hasGroupKey.rows.length) {
      const { rows: dupeGroups } = await client.query(
        `SELECT user_id, group_key, count(*)::int AS n
           FROM notifications
          WHERE group_key IS NOT NULL AND is_read = false AND dismissed_at IS NULL
          GROUP BY user_id, group_key
         HAVING count(*) > 1
          ORDER BY n DESC`,
      );
      if (dupeGroups.length) {
        console.error('❌ Cannot apply migration 020 — more than one UNREAD notification');
        console.error('   shares a (user_id, group_key), which blocks ux_notifications_group:');
        console.error('');
        for (const d of dupeGroups) {
          console.error(`   user ${d.user_id}, group_key "${d.group_key}": ${d.n} rows`);
        }
        console.error('');
        console.error('   Mark the older duplicates read, then re-run. A migration must not');
        console.error('   pick which of a user\'s notifications disappears.');
        client.release();
        await pool.end();
        process.exit(1);
      }
    }

    // chk_notifications_category validates every existing row the instant it is
    // added, and the .sql backfills `category` from a case on the type prefix
    // immediately before. If a live type ever falls outside that case it lands on
    // 'system', which is in the vocabulary — so this cannot fail. Printed anyway,
    // because the number is the interesting part: it is the size of the backlog
    // about to become a readable feed.
    const { rows: [pre] } = await client.query(
      `SELECT count(*)::int AS n,
              count(*) FILTER (WHERE is_read)::int AS read,
              count(DISTINCT type)::int AS types,
              count(DISTINCT user_id)::int AS users
         FROM notifications`,
    );
    const { rows: [tz] } = await client.query(
      `SELECT data_type FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'notifications'
          AND column_name = 'created_at'`,
    );
    console.log(`Pre-flight: ${before.length} tables present, all prerequisites found.`);
    console.log(`   notifications: ${pre.n} row(s), ${pre.read} read, `
      + `${pre.types} distinct type(s), ${pre.users} recipient(s).`);
    console.log(`   created_at is currently "${tz.data_type}" — `
      + `${tz.data_type === 'timestamp with time zone'
        ? 'already converted, section 1 will no-op'
        : 'section 1 will reinterpret these rows as UTC'}.`);
    console.log(`   user_devices/admin_audit: `
      + `${EXPECTED_TABLES.filter((t) => before.includes(t)).length}/2 already present.`);
    console.log('');

    // Apply
    // 020 has no ALTER TYPE, so there is nothing whose "already exists" may be
    // swallowed: any error here is real and takes the whole file down with it.
    let applyFailed = false;
    for (let i = 0; i < chunks.length; i++) {
      try {
        await client.query(chunks[i]);
        console.log(`✅ chunk ${i + 1}/${chunks.length} applied`);
      } catch (e) {
        applyFailed = true;
        failures.push(`chunk ${i + 1} failed: ${e.message}`);
        console.error(`❌ chunk ${i + 1}/${chunks.length} failed:`, e.message);
        if (e.detail) console.error('   detail:', e.detail);
        if (e.hint) console.error('   hint:', e.hint);
      }
    }
    if (applyFailed) throw new Error('one or more chunks failed — see above');

    console.log('');
    console.log('Migration 020 applied. Verifying:');
    console.log('');
    // 1. The two new tables
    const after = await tableNames(client);
    for (const t of EXPECTED_TABLES) check(after.includes(t), `table ${t} exists`);
    check(after.length >= before.length,
      `no table disappeared (${before.length} → ${after.length})`);

    // 2. Columns, with their types
    const { rows: colRows } = await client.query(
      `SELECT table_name, column_name, data_type, is_nullable, column_default
         FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = ANY($1::text[])`,
      [Object.keys(EXPECTED_COLUMNS)],
    );
    const colMap = new Map();
    for (const c of colRows) colMap.set(`${c.table_name}.${c.column_name}`, c);

    let colOk = 0;
    let colBad = 0;
    for (const [table, cols] of Object.entries(EXPECTED_COLUMNS)) {
      for (const [col, type] of Object.entries(cols)) {
        const got = colMap.get(`${table}.${col}`);
        if (got && got.data_type === type) {
          colOk++;
        } else {
          colBad++;
          check(false, `${table}.${col} is ${type} — got `
            + `${got ? `"${got.data_type}"` : 'NO SUCH COLUMN'}`);
        }
      }
    }
    check(colBad === 0, `all ${colOk} expected column(s) present with the right type`);

    // 3. Nullability and defaults, where they are load-bearing
    for (const [table, col, nullable, def] of EXPECTED_COLUMN_RULES) {
      const got = colMap.get(`${table}.${col}`);
      if (!got) { check(false, `${table}.${col} exists (for its NOT NULL/default)`); continue; }
      const nullOk = got.is_nullable === nullable;
      const defOk = def === null ? true : String(got.column_default || '') === def;
      check(nullOk && defOk,
        `${table}.${col} is ${nullable === 'NO' ? 'NOT NULL' : 'nullable'}`
        + `${def === null ? '' : ` DEFAULT ${def}`}`
        + `${nullOk && defOk ? '' : ` — got is_nullable=${got.is_nullable}, `
          + `default=${got.column_default === null ? 'NULL' : `"${got.column_default}"`}`}`);
    }

    // 4. CHECK constraints and foreign keys
    const { rows: conRows } = await client.query(
      `SELECT conname, contype FROM pg_constraint WHERE conname = ANY($1::text[])`,
      [[...EXPECTED_CONSTRAINTS, ...EXPECTED_FKEYS]],
    );
    const conMap = new Map(conRows.map((r) => [r.conname, r.contype]));
    for (const c of EXPECTED_CONSTRAINTS) {
      check(conMap.get(c) === 'c', `CHECK ${c} exists`);
    }
    for (const f of EXPECTED_FKEYS) {
      check(conMap.get(f) === 'f', `FK ${f} exists`);
    }

    // The two delete behaviours 020 relies on, read out of pg_constraint rather
    // than assumed from the CREATE TABLE text. 'c' = CASCADE, 'n' = SET NULL.
    const { rows: delRules } = await client.query(
      `SELECT conname, confdeltype FROM pg_constraint
        WHERE conname IN ('user_devices_user_id_fkey', 'admin_audit_admin_id_fkey',
                          'notifications_actor_id_fkey', 'users_suspended_by_fkey')`,
    );
    const delMap = new Map(delRules.map((r) => [r.conname, r.confdeltype]));
    check(delMap.get('user_devices_user_id_fkey') === 'c',
      'user_devices.user_id is ON DELETE CASCADE — a deleted account leaves no push tokens');
    check(delMap.get('admin_audit_admin_id_fkey') === 'n',
      'admin_audit.admin_id is ON DELETE SET NULL — the audit trail outlives the admin');
    check(delMap.get('notifications_actor_id_fkey') === 'n',
      'notifications.actor_id is ON DELETE SET NULL — a deleted actor leaves a readable row');
    check(delMap.get('users_suspended_by_fkey') === 'n',
      'users.suspended_by is ON DELETE SET NULL');

    // 5. Indexes, and the predicates the queries depend on
    const { rows: idxRows } = await client.query(
      `SELECT indexname, indexdef FROM pg_indexes
        WHERE schemaname = 'public' AND indexname = ANY($1::text[])`,
      [[...EXPECTED_INDEXES, ...INHERITED_INDEXES]],
    );
    const idxMap = new Map(idxRows.map((r) => [r.indexname, r.indexdef]));
    for (const i of EXPECTED_INDEXES) check(idxMap.has(i), `index ${i} exists`);
    for (const i of INHERITED_INDEXES) {
      check(idxMap.has(i), `inherited index ${i} still exists (020 depends on it)`);
    }

    // A partial index whose predicate does not match the query's WHERE clause is
    // never used, and nothing anywhere reports that — the feature just gets slow
    // as the table grows. So the predicates are asserted as text.
    const unreadDef = idxMap.get('idx_notifications_unread') || '';
    check(/is_read = false/.test(unreadDef) && /dismissed_at IS NULL/.test(unreadDef)
      && /created_at DESC/.test(unreadDef),
      'idx_notifications_unread is (user_id, created_at DESC) WHERE unread AND not dismissed '
      + '— the exact shape of the feed\'s default page');
    const outboxDef = idxMap.get('idx_notifications_outbox') || '';
    check(/sent_push = false/.test(outboxDef),
      'idx_notifications_outbox is partial on sent_push = false — the drain scans the '
      + 'backlog, not the table');
    const groupDef = idxMap.get('ux_notifications_group') || '';
    check(/UNIQUE/.test(groupDef) && /group_key IS NOT NULL/.test(groupDef)
      && /is_read = false/.test(groupDef) && /dismissed_at IS NULL/.test(groupDef),
      'ux_notifications_group is UNIQUE and partial on (group_key NOT NULL, unread, '
      + 'not dismissed) — the collapse upsert\'s inference target');
    const tokenDef = idxMap.get('ux_user_devices_token') || '';
    check(/UNIQUE/.test(tokenDef),
      'ux_user_devices_token is UNIQUE — one FCM token belongs to one row, so a device '
      + 'that changes hands MOVES instead of receiving two people\'s notifications');
    const queueDef = idxMap.get('idx_disputes_queue') || '';
    check(/severity_elo/.test(queueDef) && /status = 'open'/.test(queueDef),
      'idx_disputes_queue orders open disputes by severity — the queue sorts by '
      + 'consequence, not by age alone');

    // 6. The backfill, on the real 187 rows
    // A backfill that ran and got the case wrong is worse than one that did not
    // run: every historical row would be filed under the wrong filter chip and
    // the count on 'system' would look plausible. So the mapping is asserted per
    // prefix, against live data.
    const { rows: catRows } = await client.query(
      `SELECT category, count(*)::int AS n FROM notifications GROUP BY category ORDER BY n DESC`,
    );
    console.log(`   · category distribution: `
      + `${catRows.map((r) => `${r.category}=${r.n}`).join(', ')}`);

    const { rows: [mis] } = await client.query(
      `SELECT
         count(*) FILTER (WHERE type LIKE 'booking%'    AND category <> 'booking')::int    AS b,
         count(*) FILTER (WHERE type LIKE 'match%'      AND category <> 'match')::int      AS m,
         count(*) FILTER (WHERE type LIKE 'tournament%' AND category <> 'tournament')::int AS t,
         count(*) FILTER (WHERE type LIKE 'team%'       AND category <> 'team')::int       AS g,
         count(*) FILTER (WHERE type LIKE 'withdrawal%' AND category <> 'wallet')::int     AS w,
         count(*) FILTER (WHERE category IS NULL)::int                                     AS nul
       FROM notifications`,
    );
    check(mis.b + mis.m + mis.t + mis.g + mis.w === 0,
      'every historical row is filed under the category its type implies '
      + `(booking ${mis.b}, match ${mis.m}, tournament ${mis.t}, team ${mis.g}, `
      + 'wallet ' + mis.w + ' misfiled)');
    check(mis.nul === 0, 'no row has a NULL category — the outbox never has to reason about one');

    const { rows: [rd] } = await client.query(
      `SELECT count(*) FILTER (WHERE is_read AND read_at IS NULL)::int AS missing,
              count(*) FILTER (WHERE NOT is_read AND read_at IS NOT NULL)::int AS spurious
         FROM notifications`,
    );
    check(rd.missing === 0 && rd.spurious === 0,
      'is_read and read_at agree on every row '
      + `(${rd.missing} read row(s) with no read_at, ${rd.spurious} unread with one)`);

    const { rows: [hi] } = await client.query(
      `SELECT count(*) FILTER (WHERE priority = 'high')::int AS high,
              count(*) FILTER (WHERE priority = 'normal')::int AS normal,
              count(*) FILTER (WHERE priority = 'low')::int AS low FROM notifications`,
    );
    check(hi.high + hi.normal + hi.low === pre.n,
      `every row carries a priority (${hi.high} high, ${hi.normal} normal, ${hi.low} low)`);
    check(hi.high > 0,
      'the backfill promoted the interruptive types to high — a confirmed booking and a '
      + 'challenge are worth a buzz; "someone rated a venue" is not');

    // The conversion itself, read back from the catalog rather than inferred from
    // a successful ALTER.
    const { rows: [tzAfter] } = await client.query(
      `SELECT data_type, column_default FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'notifications'
          AND column_name = 'created_at'`,
    );
    check(tzAfter.data_type === 'timestamp with time zone',
      `notifications.created_at is timestamptz — got "${tzAfter.data_type}"`);
    check(String(tzAfter.column_default || '').startsWith('now()'),
      `the conversion kept the DEFAULT (got ${tzAfter.column_default === null
        ? 'NULL — the next INSERT would write no timestamp'
        : `"${tzAfter.column_default}"`})`);

    // 187 rows were reinterpreted, not shifted. Any row now claiming to be in the
    // future is the signature of a double conversion.
    const { rows: [drift] } = await client.query(
      `SELECT count(*) FILTER (WHERE created_at > now() + interval '1 hour')::int AS future,
              min(created_at) AS oldest, max(created_at) AS newest FROM notifications`,
    );
    check(drift.future === 0,
      `no notification is dated in the future — ${drift.future} row(s) ahead of now() `
      + '(a non-zero count is what a double AT TIME ZONE looks like)');
    if (pre.n > 0) {
      console.log(`   · the backlog spans ${new Date(drift.oldest).toISOString()} → `
        + `${new Date(drift.newest).toISOString()}`);
    }

    // 7. Functional probes
    // A constraint that exists but does not constrain reads as enforced and is
    // enforced nowhere. Each probe writes a row that must be accepted or must be
    // rejected with a named SQLSTATE, inside a transaction that is always rolled
    // back. Nothing here survives.
    console.log('');
    console.log('   Functional probes (all rolled back):');

    // Two helpers, and the difference between them is the point.
    //
    // tryWrite rolls back to its savepoint even when the write succeeds, so each
    // vocabulary probe is completely isolated: one probe's accepted row can never
    // be the reason the next one passes or fails.
    //
    // tryKeep RELEASEs instead, so the row survives inside the outer transaction.
    // The collapse-index probes need that — an upsert cannot conflict with a row
    // that was rolled away — and so do the cascade probes, which delete a user and
    // then look for what the delete took with it.
    const tryWrite = async (label, fn) => {
      await client.query(`SAVEPOINT ${label}`);
      try {
        const r = await fn();
        await client.query(`ROLLBACK TO SAVEPOINT ${label}`);
        return { ok: true, code: null, rows: (r && r.rows) || [] };
      } catch (e) {
        await client.query(`ROLLBACK TO SAVEPOINT ${label}`);
        return { ok: false, code: e.code, rows: [] };
      }
    };
    const tryKeep = async (label, fn) => {
      await client.query(`SAVEPOINT ${label}`);
      try {
        const r = await fn();
        await client.query(`RELEASE SAVEPOINT ${label}`);
        return { ok: true, code: null, rows: (r && r.rows) || [] };
      } catch (e) {
        await client.query(`ROLLBACK TO SAVEPOINT ${label}`);
        return { ok: false, code: e.code, rows: [] };
      }
    };

    const { rows: userRows } = await client.query(
      "SELECT id, role FROM users WHERE role = 'player' ORDER BY created_at LIMIT 1",
    );
    const { rows: matchRows } = await client.query(
      'SELECT id, challenger_team FROM matches WHERE challenger_team IS NOT NULL LIMIT 1',
    );

    if (!userRows.length) {
      console.log('   ~ skipped all functional probes (need one users row)');
      console.log('     The constraints are proven to EXIST above; seed the database and');
      console.log('     re-run this to prove they BITE.');
    } else {
      const uid = userRows[0].id;
      // notify()'s own column list, so a probe cannot pass against a shape the
      // real writer does not use.
      const insN = (over = {}) => {
        const base = {
          user_id: uid,
          type: 'chat_message',
          title: PROBE_TAG,
          body: null,
          category: 'chat',
          priority: 'normal',
          ...over,
        };
        const keys = Object.keys(base);
        const ph = keys.map((_, i) => `$${i + 1}`).join(', ');
        return client.query(
          `INSERT INTO notifications (${keys.join(', ')}) VALUES (${ph})
           RETURNING id, group_count, category, priority, created_at`,
          keys.map((k) => base[k]),
        );
      };

      await client.query('BEGIN');
      try {
        // 7a. The vocabularies
        const okBase = await tryWrite('p1', () => insN());
        check(okBase.ok,
          'a plain chat notification is accepted (the baseline — every probe below '
          + 'differs from this row by exactly one field)');

        const badCat = await tryWrite('p2', () => insN({ category: 'bogus' }));
        check(!badCat.ok && badCat.code === '23514',
          "category = 'bogus' is rejected (23514) — the category IS the filter chip and the "
          + 'unit a user opts out of, so a typo would silently make a notification '
          + `un-filterable and un-mutable${badCat.ok ? ' — IT WAS ACCEPTED' : ` — got ${badCat.code}`}`);

        const okAssistant = await tryWrite('p3', () => insN({ category: 'assistant', type: 'assistant_question' }));
        check(okAssistant.ok,
          "category = 'assistant' is accepted — assistant_question/assistant_answer are LIVE "
          + 'types (an owner is asked, a player is answered) and would otherwise be filed as '
          + "'system' alongside account suspensions");

        const badPri = await tryWrite('p4', () => insN({ priority: 'urgent' }));
        check(!badPri.ok && badPri.code === '23514',
          "priority = 'urgent' is rejected (23514) — priority decides whether FCM fires at all, "
          + `so an unknown value must not reach the drain${badPri.ok ? ' — IT WAS ACCEPTED' : ''}`);

        const badCount = await tryWrite('p5', () => insN({ group_count: 0 }));
        check(!badCount.ok && badCount.code === '23514',
          'group_count = 0 is rejected (23514) — a collapsed row represents at least the one '
          + `notification that created it, and "0 new messages" is not a sentence${badCount.ok ? ' — IT WAS ACCEPTED' : ''}`);

        const badEntity = await tryWrite('p6', () => insN({ entity_type: 'planet' }));
        check(!badEntity.ok && badEntity.code === '23514',
          "entity_type = 'planet' is rejected (23514) — the client switches on this to build "
          + `the tap target${badEntity.ok ? ' — IT WAS ACCEPTED' : ''}`);

        const okEntity = await tryWrite('p7', () => insN({ entity_type: 'channel', entity_id: uid }));
        check(okEntity.ok, "entity_type = 'channel' is accepted (chat rows point at a channel)");

        const badAttempts = await tryWrite('p8', () => insN({ push_attempts: -1 }));
        check(!badAttempts.ok && badAttempts.code === '23514',
          'push_attempts = -1 is rejected (23514) — the drain gives up after N attempts, and a '
          + `negative count would make it retry forever${badAttempts.ok ? ' — IT WAS ACCEPTED' : ''}`);

        const badActor = await tryWrite('p9', () => insN({
          actor_id: '00000000-0000-0000-0000-000000000001',
        }));
        check(!badActor.ok && badActor.code === '23503',
          'an actor_id that is not a user is rejected (23503) — "Ali sent you a message" must '
          + `name someone who exists${badActor.ok ? ' — IT WAS ACCEPTED' : ` — got ${badActor.code}`}`);

        // 7b. The row a client can render
        const dl = await tryWrite('p10', () => insN({
          deep_link: JSON.stringify({ route: '/booking-detail', args: { bookingId: uid } }),
          image_url: 'https://example.test/a.png',
          expires_at: new Date(Date.now() + 3600e3).toISOString(),
        }));
        check(dl.ok,
          'deep_link jsonb + image_url + expires_at are accepted together — the route is '
          + 'computed server-side so the client cannot drift from it');

        const { rows: dlRead } = await client.query(
          `SELECT deep_link ->> 'route' AS route FROM notifications
            WHERE title = $1 AND deep_link IS NOT NULL LIMIT 1`,
          [PROBE_TAG],
        );
        check(dlRead.length === 0,
          'every probe above is isolated — its savepoint rolled back on success too, so '
          + `no accepted row can prop up the next probe (${dlRead.length} left visible)`);

        // 7c. The collapse. The one probe this whole runner exists for
        // notify() v2 runs this exact statement inside money transactions. If the
        // ON CONFLICT predicate does not imply the index predicate, Postgres
        // raises 42P10 — "no unique or exclusion constraint matching the on
        // CONFLICT specification" — and every grouped notification fails at
        // runtime, inside a transaction holding FOR UPDATE locks on a wallet.
        const GKEY = `${PROBE_TAG}:gk`;
        const upsert = (n) => client.query(
          `INSERT INTO notifications
             (user_id, type, title, body, category, priority, group_key, group_count)
           VALUES ($1, 'chat_message', $2, $3, 'chat', 'normal', $4, 1)
           ON CONFLICT (user_id, group_key)
             WHERE group_key IS NOT NULL AND is_read = false AND dismissed_at IS NULL
           DO UPDATE SET group_count = notifications.group_count + 1,
                         created_at  = now(),
                         body        = EXCLUDED.body
           RETURNING id, group_count`,
          [uid, PROBE_TAG, `message ${n}`, GKEY],
        );

        const up1 = await tryKeep('p11', () => upsert(1));
        check(up1.ok && Number(up1.rows[0].group_count) === 1,
          'the collapse upsert INSERTS on the first notification (group_count = 1)'
          + `${up1.ok ? '' : ` — FAILED with ${up1.code}`}`);

        const up2 = await tryKeep('p12', () => upsert(2));
        check(up2.ok && Number(up2.rows[0].group_count) === 2
          && up1.ok && up2.rows[0].id === up1.rows[0].id,
          'the second notification BUMPS the same row to group_count = 2 instead of '
          + 'inserting — "Ali sent 2 messages", one row and one tray banner'
          + `${up2.ok ? '' : ` — FAILED with ${up2.code} (42P10 means the index predicate and the `
            + 'ON CONFLICT WHERE clause do not match)'}`);

        const up3 = await tryKeep('p13', () => upsert(3));
        check(up3.ok && Number(up3.rows[0].group_count) === 3,
          'and again to 3 — the count is the number of real events, not a rounded "several"');

        // A plain INSERT must still be blocked, because the index is what makes
        // the upsert atomic under two concurrent senders rather than merely tidy.
        const dupe = await tryWrite('p14', () => insN({ group_key: GKEY }));
        check(!dupe.ok && dupe.code === '23505',
          'a plain INSERT sharing the (user_id, group_key) of an unread row is rejected '
          + '(23505) — the uniqueness is enforced by the database, so two messages arriving '
          + `in the same millisecond collapse instead of racing${dupe.ok ? ' — IT WAS ACCEPTED' : ` — got ${dupe.code}`}`);

        // 7d. Read and dismissed rows must fall outside that index
        await client.query(
          'UPDATE notifications SET is_read = true, read_at = now() WHERE id = $1',
          [up1.rows[0].id],
        );
        const up4 = await tryKeep('p15', () => upsert(4));
        check(up4.ok && up4.rows[0].id !== up1.rows[0].id
          && Number(up4.rows[0].group_count) === 1,
          'once the collapsed row is READ, the next message starts a FRESH row at 1 — '
          + 'bumping a row the user already opened would leave the feed showing an old '
          + 'timestamp and never notify again');

        await client.query(
          'UPDATE notifications SET dismissed_at = now() WHERE id = $1',
          [up4.rows[0].id],
        );
        const up5 = await tryKeep('p16', () => upsert(5));
        check(up5.ok && up5.rows[0].id !== up4.rows[0].id
          && Number(up5.rows[0].group_count) === 1,
          'and once it is DISMISSED, the next message starts another fresh row — swiping a '
          + 'notification away must not mute the conversation');

        const { rows: [gk] } = await client.query(
          'SELECT count(*)::int AS n FROM notifications WHERE group_key = $1', [GKEY],
        );
        check(gk.n === 3,
          `the five messages produced exactly 3 rows (${gk.n} found) — collapsed while unread, `
          + 'fresh after read, fresh after dismiss');

        // 7e. user_devices — one row per phone
        const TOKEN = `${PROBE_TAG}:token:aaa`;
        const dev1 = await tryKeep('p17', () => client.query(
          `INSERT INTO user_devices (user_id, fcm_token, platform, device_label)
           VALUES ($1, $2, 'android', $3) RETURNING id`,
          [uid, TOKEN, PROBE_TAG],
        ));
        check(dev1.ok, 'a device registers with a token, a platform and a label');

        const dev2 = await tryWrite('p18', () => client.query(
          `INSERT INTO user_devices (user_id, fcm_token, platform)
           VALUES ($1, $2, 'ios') RETURNING id`,
          [uid, `${PROBE_TAG}:token:bbb`],
        ));
        check(dev2.ok,
          'the SAME user registers a SECOND device — this is the case users.fcm_token could '
          + 'never represent, and it is the ordinary setup for this project (a phone and an '
          + 'emulator), where last-login-wins silently stops the phone buzzing');

        const dupeTok = await tryWrite('p19', () => client.query(
          `INSERT INTO user_devices (user_id, fcm_token) VALUES ($1, $2)`,
          [uid, TOKEN],
        ));
        check(!dupeTok.ok && dupeTok.code === '23505',
          'the same FCM token twice is rejected (23505) — one token is one device '
          + `installation, globally${dupeTok.ok ? ' — IT WAS ACCEPTED' : ` — got ${dupeTok.code}`}`);

        const badPlat = await tryWrite('p20', () => client.query(
          `INSERT INTO user_devices (user_id, fcm_token, platform) VALUES ($1, $2, 'symbian')`,
          [uid, `${PROBE_TAG}:token:ccc`],
        ));
        check(!badPlat.ok && badPlat.code === '23514',
          "platform = 'symbian' is rejected (23514) — the send path sets android.priority "
          + `from it${badPlat.ok ? ' — IT WAS ACCEPTED' : ''}`);

        // 7f. A device that changes hands must move, not duplicate
        // This is the upsert POST /api/notifications/devices runs. If the token
        // stayed on the old row, the previous owner of that phone would keep
        // receiving the new owner's notifications — a privacy failure, not a bug.
        const probeUser = await tryKeep('p21', () => client.query(
          `INSERT INTO users (name, phone, password_hash, role)
           VALUES ($1, $2, 'x', 'player') RETURNING id`,
          [PROBE_TAG, '+920200000020'],
        ));
        if (!probeUser.ok) {
          check(false, `could not create a probe user (${probeUser.code}) — `
            + 'the ownership-transfer and cascade probes are skipped');
        } else {
          const puid = probeUser.rows[0].id;
          const moved = await tryKeep('p22', () => client.query(
            `INSERT INTO user_devices (user_id, fcm_token, platform, last_seen_at)
             VALUES ($1, $2, 'android', now())
             ON CONFLICT (fcm_token) DO UPDATE
               SET user_id = EXCLUDED.user_id, platform = EXCLUDED.platform,
                   last_seen_at = now(), revoked_at = NULL, revoke_reason = NULL
             RETURNING id, user_id`,
            [puid, TOKEN],
          ));
          check(moved.ok && dev1.ok && moved.rows[0].id === dev1.rows[0].id
            && moved.rows[0].user_id === puid,
            'registering an existing token under a different user MOVES the one row instead '
            + 'of adding a second — a shared or resold phone cannot deliver one person\'s '
            + `notifications to another${moved.ok ? '' : ` — FAILED with ${moved.code}`}`);

          const { rows: [tokCount] } = await client.query(
            'SELECT count(*)::int AS n FROM user_devices WHERE fcm_token = $1', [TOKEN],
          );
          check(tokCount.n === 1, `exactly one row holds that token (${tokCount.n} found)`);

          // 7g. The two opposite delete rules
          const audit = await tryKeep('p23', () => client.query(
            `INSERT INTO admin_audit (admin_id, action, entity_type, entity_id, before, after, note)
             VALUES ($1, 'suspend_user', 'user', $2, $3::jsonb, $4::jsonb, $5) RETURNING id`,
            [puid, uid, JSON.stringify({ is_active: true }),
              JSON.stringify({ is_active: false, suspended_reason: 'probe' }), PROBE_TAG],
          ));
          check(audit.ok,
            'an admin_audit row records before/after as jsonb — "who changed this, and what '
            + 'did it look like before?" is answerable from one table');

          await client.query('DELETE FROM users WHERE id = $1', [puid]);

          const { rows: [gone] } = await client.query(
            'SELECT count(*)::int AS n FROM user_devices WHERE user_id = $1', [puid],
          );
          check(gone.n === 0,
            'deleting the account took its push tokens with it (ON DELETE CASCADE) — a '
            + 'deleted user must not keep receiving notifications on a phone we still have '
            + `a token for (${gone.n} left)`);

          const { rows: survived } = await client.query(
            'SELECT admin_id FROM admin_audit WHERE id = $1', [audit.rows[0].id],
          );
          check(survived.length === 1 && survived[0].admin_id === null,
            'but the audit row SURVIVED with admin_id NULL (ON DELETE SET NULL) — deleting an '
            + 'admin must not erase what they did, which is the opposite rule to the one '
            + `above, on purpose${survived.length ? '' : ' — THE AUDIT ROW WAS DELETED'}`);
        }

        // 7h. The dispute ruling vocabulary
        if (matchRows.length) {
          const mid = matchRows[0].id;
          const rteam = matchRows[0].challenger_team;
          const insD = (over = {}) => {
            const base = {
              match_id: mid, raised_by_team: rteam, reason: PROBE_TAG, status: 'open', ...over,
            };
            const keys = Object.keys(base);
            const ph = keys.map((_, i) => `$${i + 1}`).join(', ');
            return client.query(
              `INSERT INTO disputes (${keys.join(', ')}) VALUES (${ph}) RETURNING id`,
              keys.map((k) => base[k]),
            );
          };

          const dOk = await tryWrite('p24', () => insD({
            status: 'resolved', ruling: 'draw', ruled_score_challenger: 2,
            ruled_score_opponent: 2, severity_elo: 18,
          }));
          check(dOk.ok,
            "a dispute ruled 'draw' with a 2-2 scoreline and severity 18 is accepted — 'draw' "
            + 'is in the vocabulary because the admin app offers a rule_draw action, and a '
            + 'CHECK that omitted it would 23514 on the first drawn ruling');

          const dBad = await tryWrite('p25', () => insD({ status: 'resolved', ruling: 'coin_toss' }));
          check(!dBad.ok && dBad.code === '23514',
            "ruling = 'coin_toss' is rejected (23514) — the queue COUNTS rulings, and a human "
            + `sentence in resolution_notes cannot be counted${dBad.ok ? ' — IT WAS ACCEPTED' : ''}`);

          const dNeg = await tryWrite('p26', () => insD({
            status: 'resolved', ruling: 'custom', ruled_score_challenger: -1, ruled_score_opponent: 0,
          }));
          check(!dNeg.ok && dNeg.code === '23514',
            'a ruled scoreline of -1 is rejected (23514) — a negative goal count is not a '
            + `scoreline, and it would flow straight into elo.applyResult${dNeg.ok ? ' — IT WAS ACCEPTED' : ''}`);

          const dDismiss = await tryWrite('p27', () => insD({ status: 'dismissed', ruling: 'dismissed' }));
          check(dDismiss.ok,
            "status = 'dismissed' with ruling = 'dismissed' is accepted — chk_disputes_status "
            + "(016) already allows 'dismissed', so the admin app's dismiss action closes the "
            + "case there rather than mislabelling it 'resolved'");
        } else {
          console.log('   ~ skipped the dispute probes (no matches rows)');
        }

        // 7i. Preferences and the suspension audit trail
        const prefs = await tryWrite('p28', () => client.query(
          `UPDATE users SET notification_prefs = $2::jsonb WHERE id = $1
           RETURNING notification_prefs -> 'push' ->> 'chat' AS chat_push`,
          [uid, JSON.stringify({
            push: { chat: false, booking: true }, quietHours: { start: '23:00', end: '07:00' },
          })],
        ));
        check(prefs.ok && prefs.rows[0].chat_push === 'false',
          'notification_prefs stores a nested push/quiet-hours object and is queryable by path '
          + '— the drain reads the preference itself, so a toggle is enforced server-side '
          + 'rather than honoured by whichever client feels like it');

        const badSusp = await tryWrite('p29', () => client.query(
          `UPDATE users SET is_active = false, suspended_at = now(), suspended_reason = $2,
                            suspended_by = '00000000-0000-0000-0000-000000000002'
            WHERE id = $1`,
          [uid, PROBE_TAG],
        ));
        check(!badSusp.ok && badSusp.code === '23503',
          'suspended_by must be a real user (23503) — "suspended by whom?" is the second '
          + `question after "suspended when?"${badSusp.ok ? ' — IT WAS ACCEPTED' : ` — got ${badSusp.code}`}`);
      } finally {
        await client.query('ROLLBACK');   // nothing above may survive
      }

      // 8. Nothing leaked
      const { rows: [left] } = await client.query(
        `SELECT (SELECT count(*)::int FROM notifications WHERE title = $1)     AS n,
                (SELECT count(*)::int FROM user_devices  WHERE fcm_token LIKE $2) AS d,
                (SELECT count(*)::int FROM admin_audit   WHERE note = $1)     AS a,
                (SELECT count(*)::int FROM disputes      WHERE reason = $1)   AS p,
                (SELECT count(*)::int FROM users         WHERE name = $1)     AS u`,
        [PROBE_TAG, `${PROBE_TAG}%`],
      );
      const leftover = left.n + left.d + left.a + left.p + left.u;
      check(leftover === 0,
        `probes rolled back cleanly — ${leftover} probe row(s) left behind `
        + `(${left.n} notification, ${left.d} device, ${left.a} audit, ${left.p} dispute, `
        + `${left.u} user)`);

      // The prefs probe wrote to a real user's row. Prove the rollback reached it,
      // because a leaked preference object would silently suppress that person's
      // notifications and nothing would ever report it.
      const { rows: [realUser] } = await client.query(
        'SELECT notification_prefs::text AS p, is_active FROM users WHERE id = $1', [uid],
      );
      check(realUser.p === '{}' && realUser.is_active === true,
        `the probes left the real user untouched — prefs are ${realUser.p}, `
        + `is_active is ${realUser.is_active}`);
    }

    // Listing
    console.log('');
    console.log('The notification feed is now representable in the database:');
    console.log('   • created_at is timestamptz — "2 hours ago" is the same sentence on every server');
    console.log('   • read_at / dismissed_at — dismissing is not reading, and both are timestamps');
    console.log('   • category + priority — the filter chip, the opt-out unit, and whether FCM fires');
    console.log('   • group_key + group_count with a UNIQUE partial index — "Ali sent 3 messages"');
    console.log('     is one row and one banner, collapsed atomically by the database');
    console.log('   • deep_link jsonb — the tap target is computed server-side, so the client');
    console.log('     cannot drift from it (the "tap does nothing" failure has no way in)');
    console.log('   • actor_id + image_url — the row reads like a person, not an event');
    console.log('   • expires_at — a challenge past its 48h TTL cannot render as actionable');
    console.log('   • sent_push / push_attempts / pushed_at / push_error — the outbox, and the');
    console.log('     answer to "why didn\'t my phone buzz?" without reading a log file');
    console.log('   • user_devices — one row per phone, revocable one at a time');
    console.log('   • admin_audit — before/after jsonb behind every admin write, outliving the admin');
    console.log('   • disputes.ruling + ruled scores + severity_elo — a queue that sorts by');
    console.log('     consequence and a ruling that can be counted');
  } catch (e) {
    failures.push(`migration threw: ${e.message}`);
    console.error('');
    console.error('❌ Migration 020 failed:', e.message);
    if (e.detail) console.error('   detail:', e.detail);
    if (e.hint) console.error('   hint:', e.hint);
  } finally {
    client.release();
    await pool.end();
  }

  console.log('');
  if (failures.length) {
    console.error(`❌ Migration 020: ${failures.length} check(s) failed.`);
  } else {
    console.log('✅ Migration 020 verified — the notifications table is a feed, and the admin');
    console.log('   module has its audit trail, its device registry and its ruling vocabulary.');
  }
  process.exit(failures.length ? 1 : 0);
}

run();
