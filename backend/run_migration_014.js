/**
 * Runner for migrations/014_withdrawals.sql
 * Usage: node run_migration_014.js
 *
 * Applied as ONE multi-statement command, which Postgres wraps in a single
 * implicit transaction — so it is all-or-nothing. (No `-- @@SPLIT@@` marker
 * needed: this migration adds no enum values, and `ALTER TYPE ... ADD VALUE` is
 * the only statement that cannot run inside a transaction.)
 *
 * The assertions below go further than `\dt` can, because the risk in this
 * migration is not a missing table — it is a constraint that exists but does not
 * actually constrain. `uq_withdrawals_one_pending` is the entire implementation
 * of "one pending withdrawal at a time" (ER1.6), so check 6 does not merely look
 * the index up by name: it inserts two pending rows and asserts the second one is
 * REJECTED, inside a transaction that is then rolled back so no data is left
 * behind.
 *
 * Safe to re-run: every statement in the .sql is IF NOT EXISTS.
 */
const fs = require('fs');
const path = require('path');
const pool = require('./src/db/pool');

// 014 references these. A missing one means schema.sql was never applied and the
// CREATE TABLE would abort the whole transaction with a bare 42P01.
const PREREQUISITE_TABLES = ['users', 'wallets', 'transactions'];

// Every key column must be uuid — all PKs in this schema are uuid.
const MUST_BE_UUID = ['id', 'user_id', 'wallet_id', 'txn_id'];

const EXPECTED_COLUMNS = {
  amount: 'numeric',
  status: 'text',
  method: 'text',
  account_name: 'text',
  account_number: 'text',
  requested_at: 'timestamp without time zone',
  completed_at: 'timestamp without time zone',
  failure_reason: 'text',
};

const EXPECTED_INDEXES = [
  'uq_withdrawals_one_pending',
  'idx_withdrawals_user',
  'idx_withdrawals_pending',
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
  const sqlFile = path.join(__dirname, 'migrations', '014_withdrawals.sql');
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
      console.error('❌ Cannot apply migration 014 — prerequisite tables missing:');
      console.error(`   ${missingPrereqs.join(', ')}`);
      console.error('   Apply schema.sql first.');
      client.release();
      await pool.end();
      process.exit(1);
    }
    console.log(`Pre-flight: ${before.length} tables present, all prerequisites found.`);
    if (before.includes('withdrawals')) {
      console.log('   (re-run — withdrawals already present)');
    }
    console.log('');

    // ─── Apply ──────────────────────────────────────────────────────────────
    await client.query(sql);
    console.log('Migration 014 applied. Verifying:');
    console.log('');

    // ─── 1. Table ───────────────────────────────────────────────────────────
    const after = await tableNames(client);
    check(after.includes('withdrawals'), 'withdrawals table exists');

    // ─── 2. Column types ────────────────────────────────────────────────────
    const { rows: cols } = await client.query(
      `SELECT column_name, data_type, is_nullable
         FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'withdrawals'`,
    );
    const typeOf = new Map(cols.map((r) => [r.column_name, r.data_type]));
    const nullableOf = new Map(cols.map((r) => [r.column_name, r.is_nullable]));

    const badUuid = MUST_BE_UUID
      .filter((c) => typeOf.get(c) !== 'uuid')
      .map((c) => `${c} is ${typeOf.get(c) || 'MISSING'}`);
    check(badUuid.length === 0,
      `all ${MUST_BE_UUID.length} key columns are uuid${badUuid.length ? ` — WRONG: ${badUuid.join('; ')}` : ''}`);

    const badCol = Object.entries(EXPECTED_COLUMNS)
      .filter(([c, want]) => typeOf.get(c) !== want)
      .map(([c, want]) => `${c} is ${typeOf.get(c) || 'MISSING'}, want ${want}`);
    check(badCol.length === 0,
      `all ${Object.keys(EXPECTED_COLUMNS).length} data columns correct${badCol.length ? ` — WRONG: ${badCol.join('; ')}` : ''}`);

    // user_id / wallet_id / amount / status / requested_at must be NOT NULL —
    // a nullable user_id would let the partial unique index group orphan rows.
    const mustBeNotNull = ['user_id', 'wallet_id', 'amount', 'status', 'requested_at'];
    const wronglyNullable = mustBeNotNull.filter((c) => nullableOf.get(c) !== 'NO');
    check(wronglyNullable.length === 0,
      `NOT NULL on ${mustBeNotNull.length} required columns${wronglyNullable.length ? ` — NULLABLE: ${wronglyNullable.join(', ')}` : ''}`);

    // ─── 3. CHECK constraints ───────────────────────────────────────────────
    const { rows: checkRows } = await client.query(
      `SELECT con.conname, pg_get_constraintdef(con.oid) AS def
         FROM pg_constraint con
         JOIN pg_class rel ON rel.oid = con.conrelid
         JOIN pg_namespace ns ON ns.oid = rel.relnamespace
        WHERE ns.nspname = 'public' AND rel.relname = 'withdrawals'
          AND con.contype = 'c'`,
    );
    const allChecks = checkRows.map((r) => r.def).join(' | ');
    check(/status/.test(allChecks) && /pending/.test(allChecks),
      "status CHECK restricts to pending/completed/failed/cancelled");
    check(/method/.test(allChecks) && /easypaisa/.test(allChecks),
      'method CHECK restricts to easypaisa/jazzcash/bank');
    check(/amount/.test(allChecks) && />\s*\(?0/.test(allChecks),
      'amount CHECK rejects zero and negatives');

    // ─── 4. Foreign keys ────────────────────────────────────────────────────
    const { rows: fkRows } = await client.query(
      `SELECT kcu.column_name, ccu.table_name AS refs
         FROM information_schema.table_constraints tc
         JOIN information_schema.key_column_usage kcu
           ON kcu.constraint_name = tc.constraint_name
          AND kcu.table_schema = tc.table_schema
         JOIN information_schema.constraint_column_usage ccu
           ON ccu.constraint_name = tc.constraint_name
        WHERE tc.constraint_type = 'FOREIGN KEY'
          AND tc.table_schema = 'public'
          AND tc.table_name = 'withdrawals'`,
    );
    const fks = new Map(fkRows.map((r) => [r.column_name, r.refs]));
    const wantFks = { user_id: 'users', wallet_id: 'wallets', txn_id: 'transactions' };
    const missingFks = Object.entries(wantFks)
      .filter(([c, t]) => fks.get(c) !== t)
      .map(([c, t]) => `${c}→${t} (got ${fks.get(c) || 'none'})`);
    check(missingFks.length === 0,
      `all 3 foreign keys present${missingFks.length ? ` — WRONG: ${missingFks.join(', ')}` : ''}`);

    // ─── 5. Indexes exist, and the unique one is actually partial + unique ───
    const { rows: idxRows } = await client.query(
      `SELECT indexname, indexdef FROM pg_indexes
        WHERE schemaname = 'public' AND tablename = 'withdrawals'`,
    );
    const idx = new Map(idxRows.map((r) => [r.indexname, r.indexdef]));
    const missingIdx = EXPECTED_INDEXES.filter((n) => !idx.has(n));
    check(missingIdx.length === 0,
      `all ${EXPECTED_INDEXES.length} indexes exist${missingIdx.length ? ` — MISSING: ${missingIdx.join(', ')}` : ''}`);

    const uqDef = idx.get('uq_withdrawals_one_pending') || '';
    check(/CREATE UNIQUE INDEX/i.test(uqDef) && /WHERE.*pending/i.test(uqDef),
      `uq_withdrawals_one_pending is UNIQUE and partial on status='pending'${uqDef ? '' : ' — index missing'}`);

    // ─── 6. Functional test: does the constraint actually constrain? ─────────
    // Named indexes prove nothing on their own. Insert two pending rows for the
    // same user and assert the SECOND is rejected with 23505. The whole probe
    // runs inside a transaction that is always rolled back, so it leaves no data
    // behind — and it picks a user with no pending row of their own so the FIRST
    // insert is guaranteed to be the one that succeeds.
    const { rows: victims } = await client.query(
      `SELECT w.user_id, w.id AS wallet_id
         FROM wallets w
        WHERE NOT EXISTS (
                SELECT 1 FROM withdrawals wd
                 WHERE wd.user_id = w.user_id AND wd.status = 'pending')
        LIMIT 1`,
    );
    if (!victims.length) {
      console.log('   ~ skipped one-pending enforcement test (no eligible wallet row)');
    } else {
      const { user_id: uid, wallet_id: wid } = victims[0];
      const insertPending = (amount, status = 'pending', extra = '') =>
        client.query(
          `INSERT INTO withdrawals (user_id, wallet_id, amount, status${extra ? ', completed_at' : ''})
           VALUES ($1, $2, $3, $4${extra ? ', NOW()' : ''})`,
          [uid, wid, amount, status],
        );

      // Every probe insert that is EXPECTED to fail gets its own savepoint —
      // without one, the 23505 aborts the transaction and every later query in
      // this runner dies with 25P02 instead of reporting a result.
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
        await insertPending(1);                                  // the real one
        const second = await tryInsert('p2', () => insertPending(2));
        const completed = await tryInsert('p3', () => insertPending(3, 'completed', 'ts'));
        const badStatus = await tryInsert('p4', () => insertPending(4, 'processing'));
        const badAmount = await tryInsert('p5', () => insertPending(0));

        check(!second.ok && second.code === '23505',
          `a SECOND pending withdrawal is rejected (23505) — ER1.6 enforced by the DB${second.ok ? ' — IT WAS ACCEPTED' : ` — got ${second.code}`}`);
        check(completed.ok,
          'a completed withdrawal coexists with a pending one (index really is partial)');
        check(!badStatus.ok && badStatus.code === '23514',
          `status='processing' rejected by the CHECK${badStatus.ok ? ' — IT WAS ACCEPTED' : ''}`);
        check(!badAmount.ok && badAmount.code === '23514',
          `amount=0 rejected by the CHECK${badAmount.ok ? ' — IT WAS ACCEPTED' : ''}`);
      } finally {
        await client.query('ROLLBACK');   // nothing above may survive
      }
      const { rows: [{ n }] } = await client.query(
        'SELECT COUNT(*)::int AS n FROM withdrawals',
      );
      console.log(`   ~ probe rolled back — withdrawals holds ${n} row(s)`);
    }

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
    console.error('❌ Migration 014 failed:', e.message);
    if (e.detail) console.error('   detail:', e.detail);
    if (e.hint) console.error('   hint:', e.hint);
  } finally {
    client.release();
    await pool.end();
  }

  console.log('');
  if (failures.length) {
    console.error(`❌ Migration 014: ${failures.length} check(s) failed.`);
  } else {
    console.log('✅ Migration 014 verified — withdrawals ready.');
  }
  process.exit(failures.length ? 1 : 0);
}

run();
