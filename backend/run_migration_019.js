/**
 * Runner for migrations/019_tournaments.sql
 * Usage: node run_migration_019.js
 *
 * The migration is split on the marker line (spelled "-- @@" + "SPLIT@@" so this
 * comment does not become one) because ALTER TYPE ... ADD VALUE cannot run
 * inside a multi-command string, and 019 adds three txn_type values. Chunks 1-3
 * are those three ALTER TYPEs; chunk 4 is everything else, applied as ONE
 * command so Postgres wraps it in a single implicit transaction and a failure
 * anywhere leaves the schema untouched.
 *
 * Why this runner is long. 019 is the migration that makes tournament money
 * possible, and four of its guarantees are the only thing standing between a
 * demo and a bracket that pays the wrong team:
 *
 *   1. A PRE-FLIGHT that can stop the migration. Sections 1-3 add CHECK
 *      constraints to columns 013 created WITHOUT one, and ADD CONSTRAINT
 *      validates every existing row immediately. The .sql backfills the three
 *      status/format vocabularies first, but a DUPLICATE (tournament_id, round,
 *      position) in fixtures cannot be backfilled - deciding which bracket node
 *      to delete is a decision for a human - so any such pair is printed and the
 *      migration is not attempted.
 *
 *   2. NULLABILITY AND DEFAULTS, not just presence. pool_amount and the three
 *      other money columns are numeric(10,2) NOT NULL DEFAULT 0. If any came out
 *      nullable the waterfall could write a NULL, and the audit
 *      "pool = venue_cost + prize + margin" would compare NULL to NULL, which is
 *      not false - it would pass while the arithmetic was missing. So the census
 *      asserts is_nullable and column_default, not merely that a column exists.
 *
 *   3. FUNCTIONAL PROBES. A constraint that exists but does not constrain reads
 *      as enforced and is enforced nowhere. Each probe writes a row that MUST be
 *      rejected and asserts the SQLSTATE, inside a transaction that is always
 *      rolled back. The three that matter most: a knockout whose max_teams is
 *      not a power of two (an unclosable bracket), a bye carrying two teams (a
 *      team advancing without playing a match), and two fixtures on one slot
 *      (two matches on one pitch, and the second pair of teams turned away).
 *
 *   4. THE ENUM. The three txn_type values are read back out of pg_enum rather
 *      than assumed from a successful ALTER, because ADD VALUE IF NOT EXISTS
 *      succeeds silently when the type is not the one you thought it was.
 *
 * Safe to re-run: every statement in the .sql is idempotent.
 */
const fs = require('fs');
const path = require('path');
const pool = require('./src/db/pool');

// 019 alters or references all of these. A missing one means 013 was never run.
const PREREQUISITE_TABLES = [
  'users', 'teams', 'team_members', 'venues', 'slots', 'bookings',
  'matches', 'transactions', 'wallets',
  'tournaments', 'tournament_teams', 'fixtures', 'global_settings',
];

const NEW_TXN_TYPES = ['tournament_entry', 'tournament_prize', 'tournament_commission'];

// The indexes 019 itself creates.
const EXPECTED_INDEXES = [
  'uq_fixtures_slot_id',
  'idx_fixtures_match',
  'idx_fixtures_sched',
  'idx_matches_tournament',
  'idx_transactions_tournament',
  'idx_tournaments_due',
  'idx_tournaments_owner',
];

// The four 013 already created, which 019 DEPENDS ON and deliberately does not
// re-create under new names (see section 7 of the .sql). Asserted here for the
// same reason uq_fixtures_slot is: a thing you rely on and never check is a thing
// that can quietly go missing.
const INHERITED_INDEXES = [
  'idx_tournaments_status',
  'idx_tournaments_venue',
  'idx_tournament_teams_team',
  'idx_fixtures_tournament',
];

const EXPECTED_CONSTRAINTS = [
  'chk_tournaments_status',
  'chk_tournaments_format',
  'chk_tournaments_max_teams',
  'chk_tournaments_min_teams',
  'chk_tournaments_percents',
  'chk_tournaments_money_nonneg',
  'chk_tournament_teams_status',
  'chk_tournament_teams_paid',
  'chk_fixtures_status',
  'chk_fixtures_coords',
  'chk_fixtures_distinct_teams',
  'chk_fixtures_bye',
  'chk_fixtures_scores',
  'chk_teams_tournament_counters',
  'chk_matches_one_context',
];

// UNIQUE constraints (contype 'u'), which live in pg_constraint but not in the
// CHECK census above. uq_fixtures_slot is what makes fixture generation safe to
// retry: a second run inserting the same (tournament, round, position) hits
// 23505 on the first row and takes the whole transaction down with it.
const EXPECTED_UNIQUE_CONSTRAINTS = ['uq_fixtures_slot'];

// table -> column -> information_schema.data_type.
const EXPECTED_COLUMNS = {
  tournaments: {
    description: 'text',
    min_teams: 'integer',
    requires_approval: 'boolean',
    prize_percent: 'integer',
    winner_percent: 'integer',
    runnerup_percent: 'integer',
    venue_discount_percent: 'integer',
    slot_minutes: 'integer',
    pool_amount: 'numeric',
    venue_cost_amount: 'numeric',
    prize_amount: 'numeric',
    owner_earning_amount: 'numeric',
    rounds: 'integer',
    winner_team: 'uuid',
    runner_up_team: 'uuid',
    fixtures_generated_at: 'timestamp with time zone',
    activated_at: 'timestamp with time zone',
    completed_at: 'timestamp with time zone',
    cancelled_at: 'timestamp with time zone',
    cancel_reason: 'text',
  },
  tournament_teams: {
    seed: 'integer',
    paid_amount: 'numeric',
    approved_at: 'timestamp with time zone',
    withdrawn_at: 'timestamp with time zone',
    eliminated_round: 'integer',
  },
  fixtures: {
    match_id: 'uuid',
    slot_id: 'uuid',
    scheduled_at: 'timestamp with time zone',
    label: 'text',
    is_bye: 'boolean',
    next_round: 'integer',
    next_position: 'integer',
  },
  teams: {
    tournament_played: 'integer',
    tournament_wins: 'integer',
    finals_reached: 'integer',
    titles: 'integer',
  },
  matches: { tournament_id: 'uuid' },
  transactions: { tournament_id: 'uuid' },
};

// The columns whose NOT NULL is itself a guarantee (header note 2), mapped to a
// fragment their DEFAULT must contain. A money column that came back nullable is
// a silent hole in the audit, so this is checked as strictly as the type.
const EXPECTED_NOT_NULL = {
  'tournaments.min_teams': '4',
  'tournaments.requires_approval': 'false',
  'tournaments.prize_percent': '60',
  'tournaments.winner_percent': '70',
  'tournaments.runnerup_percent': '30',
  'tournaments.venue_discount_percent': '0',
  'tournaments.slot_minutes': '60',
  'tournaments.pool_amount': '0',
  'tournaments.venue_cost_amount': '0',
  'tournaments.prize_amount': '0',
  'tournaments.owner_earning_amount': '0',
  'tournament_teams.paid_amount': '0',
  'fixtures.is_bye': 'false',
  'teams.tournament_played': '0',
  'teams.tournament_wins': '0',
  'teams.finals_reached': '0',
  'teams.titles': '0',
};

// The keys utils/globalSettings.js will read out of the 'tournament' row.
const EXPECTED_SETTING_KEYS = [
  'min_teams', 'prize_percent', 'winner_percent', 'runnerup_percent',
  'venue_discount_percent', 'slot_minutes', 'round_gap_days',
  'round_rest_minutes',
  'max_knockout_teams', 'max_round_robin_teams', 'target_margin_percent',
  'k_early', 'k_semi', 'k_final',
];

// Every probe row carries this in a text column so the leftover check can prove
// the rollback took, rather than trusting that it did.
const PROBE_TAG = '__mig019 probe';

async function tableNames(client) {
  const { rows } = await client.query(
    `SELECT table_name FROM information_schema.tables
      WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
      ORDER BY table_name`,
  );
  return rows.map((r) => r.table_name);
}

/** The marker, assembled so this source file never contains a literal one. */
const SPLIT_MARKER = `-- @@${'SPLIT'}@@`;

async function run() {
  const sqlFile = path.join(__dirname, 'migrations', '019_tournaments.sql');
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
    // ─── Pre-flight ─────────────────────────────────────────────────────────
    const before = await tableNames(client);
    const missingPrereqs = PREREQUISITE_TABLES.filter((t) => !before.includes(t));
    if (missingPrereqs.length) {
      console.error('❌ Cannot apply migration 019 — prerequisite tables missing:');
      console.error(`   ${missingPrereqs.join(', ')}`);
      console.error('   Apply schema.sql, then run_migration_013.js through 018.');
      client.release();
      await pool.end();
      process.exit(1);
    }

    // uq_fixtures_slot is a UNIQUE constraint over live data. Two bracket nodes
    // sharing (tournament, round, position) would make ADD CONSTRAINT fail with
    // a 23505 that names the constraint and not the rows, so they are found and
    // printed FIRST — a migration must not choose which fixture to delete.
    const { rows: dupeFixtures } = await client.query(
      `SELECT tournament_id, round, position, count(*)::int AS n
         FROM fixtures
        WHERE tournament_id IS NOT NULL
        GROUP BY tournament_id, round, position
       HAVING count(*) > 1
        ORDER BY n DESC`,
    );
    if (dupeFixtures.length) {
      console.error('❌ Cannot apply migration 019 — more than one fixture shares a');
      console.error('   (tournament, round, position), which blocks uq_fixtures_slot:');
      console.error('');
      for (const d of dupeFixtures) {
        console.error(`   tournament ${d.tournament_id}, round ${d.round}, `
          + `position ${d.position}: ${d.n} fixtures`);
      }
      console.error('');
      console.error('   Keep one fixture per bracket node and delete the rest, then');
      console.error('   re-run. A migration must not pick which fixture survives.');
      client.release();
      await pool.end();
      process.exit(1);
    }

    // chk_matches_one_context validates existing rows. A match that somehow
    // already had both a booking and a tournament would block it — impossible
    // today (the column is being added), but the check costs one query and the
    // failure it prevents is a cryptic 23514 on an ALTER TABLE.
    const hasTournamentCol = await client.query(
      `SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'matches'
          AND column_name = 'tournament_id'`,
    );
    if (hasTournamentCol.rows.length) {
      const { rows: [{ both }] } = await client.query(
        `SELECT count(*)::int AS both FROM matches
          WHERE booking_id IS NOT NULL AND tournament_id IS NOT NULL`,
      );
      if (both > 0) {
        console.error(`❌ Cannot apply migration 019 — ${both} match(es) carry BOTH a`);
        console.error('   booking_id and a tournament_id, which blocks chk_matches_one_context.');
        console.error('   A match belongs to one context; clear the wrong one and re-run.');
        client.release();
        await pool.end();
        process.exit(1);
      }
    }

    const { rows: [counts] } = await client.query(
      `SELECT (SELECT count(*)::int FROM tournaments)      AS tournaments,
              (SELECT count(*)::int FROM tournament_teams) AS entries,
              (SELECT count(*)::int FROM fixtures)         AS fixtures,
              (SELECT count(*)::int FROM teams)            AS teams,
              (SELECT count(*)::int FROM matches)          AS matches,
              (SELECT count(*)::int FROM transactions)     AS transactions`,
    );
    console.log(`Pre-flight: ${before.length} tables present, all prerequisites found.`);
    console.log(`   ${counts.tournaments} tournament(s), ${counts.entries} entry(ies), `
      + `${counts.fixtures} fixture(s), ${counts.teams} team(s), `
      + `${counts.matches} match(es), ${counts.transactions} transaction(s).`);
    console.log('   No duplicate bracket nodes, no dual-context matches.');
    console.log('');

    // ─── Apply ──────────────────────────────────────────────────────────────
    // Only an ALTER TYPE chunk may be skipped on "already exists": swallowing
    // that message anywhere else would hide a real collision (an index or a
    // constraint name already taken by something that is not ours).
    let applyFailed = false;
    for (let i = 0; i < chunks.length; i++) {
      const isEnumChunk = /^ALTER TYPE/m.test(chunks[i]) && chunks[i].length < 4000;
      try {
        await client.query(chunks[i]);
        console.log(`✅ chunk ${i + 1}/${chunks.length} applied`
          + (isEnumChunk ? ' (enum value)' : ''));
      } catch (e) {
        if (isEnumChunk && /already exists|duplicate/i.test(e.message)) {
          console.log(`↷  chunk ${i + 1}/${chunks.length} skipped — ${e.message}`);
        } else {
          applyFailed = true;
          failures.push(`chunk ${i + 1} failed: ${e.message}`);
          console.error(`❌ chunk ${i + 1}/${chunks.length} failed:`, e.message);
          if (e.detail) console.error('   detail:', e.detail);
          if (e.hint) console.error('   hint:', e.hint);
        }
      }
    }
    if (applyFailed) throw new Error('one or more chunks failed — see above');

    console.log('');
    console.log('Migration 019 applied. Verifying:');
    console.log('');

    // ─── 1. The three new txn_type values ───────────────────────────────────
    const { rows: enumRows } = await client.query(
      `SELECT e.enumlabel FROM pg_enum e
         JOIN pg_type t ON t.oid = e.enumtypid
        WHERE t.typname = 'txn_type'
        ORDER BY e.enumsortorder`,
    );
    const labels = enumRows.map((r) => r.enumlabel);
    const missingEnum = NEW_TXN_TYPES.filter((v) => !labels.includes(v));
    check(missingEnum.length === 0,
      `txn_type carries all 3 new values${missingEnum.length ? ` — MISSING: ${missingEnum.join(', ')}` : ''} `
      + `(now ${labels.length}: ${labels.join(', ')})`);

    // Reused rather than re-invented: the unwind and the un-freeze.
    check(labels.includes('refund') && labels.includes('escrow_release'),
      'txn_type still carries refund and escrow_release (the tournament unwind reuses them)');

    // ─── 2. Columns, with types ─────────────────────────────────────────────
    const { rows: cols } = await client.query(
      `SELECT table_name, column_name, data_type, is_nullable, column_default
         FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = ANY($1)`,
      [Object.keys(EXPECTED_COLUMNS)],
    );
    const colInfo = new Map(cols.map((r) => [`${r.table_name}.${r.column_name}`, r]));
    let colTotal = 0;
    const badCols = [];
    for (const [table, want] of Object.entries(EXPECTED_COLUMNS)) {
      for (const [col, type] of Object.entries(want)) {
        colTotal += 1;
        const got = colInfo.get(`${table}.${col}`);
        if (!got) badCols.push(`${table}.${col} MISSING`);
        else if (got.data_type !== type) badCols.push(`${table}.${col} is ${got.data_type}, want ${type}`);
      }
    }
    check(badCols.length === 0,
      `all ${colTotal} new columns present with the right type across 6 tables`
      + `${badCols.length ? ` — WRONG: ${badCols.join('; ')}` : ''}`);

    // The money columns must be numeric(10,2) exactly: a bare `numeric` would
    // store 7560.333333 and the paisa audit in check_tournaments.js would fail
    // on a rounding artefact rather than on a real imbalance.
    const { rows: scales } = await client.query(
      `SELECT table_name, column_name, numeric_precision, numeric_scale
         FROM information_schema.columns
        WHERE table_schema = 'public'
          AND ((table_name = 'tournaments' AND column_name IN
                 ('pool_amount','venue_cost_amount','prize_amount','owner_earning_amount'))
            OR (table_name = 'tournament_teams' AND column_name = 'paid_amount'))`,
    );
    const badScale = scales
      .filter((r) => Number(r.numeric_precision) !== 10 || Number(r.numeric_scale) !== 2)
      .map((r) => `${r.table_name}.${r.column_name} is numeric(${r.numeric_precision},${r.numeric_scale})`);
    check(scales.length === 5 && badScale.length === 0,
      `all 5 money columns are numeric(10,2) — paisa-exact`
      + `${badScale.length ? ` — WRONG: ${badScale.join('; ')}` : ''}`);

    // ─── 3. NOT NULL and DEFAULT (header note 2) ────────────────────────────
    const badNotNull = [];
    for (const [key, wantDefault] of Object.entries(EXPECTED_NOT_NULL)) {
      const got = colInfo.get(key);
      if (!got) { badNotNull.push(`${key} MISSING`); continue; }
      if (got.is_nullable !== 'NO') badNotNull.push(`${key} is NULLABLE`);
      else if (!String(got.column_default || '').includes(wantDefault)) {
        badNotNull.push(`${key} DEFAULT is "${got.column_default}", want ${wantDefault}`);
      }
    }
    check(badNotNull.length === 0,
      `all ${Object.keys(EXPECTED_NOT_NULL).length} policy/money columns are NOT NULL with the right DEFAULT`
      + `${badNotNull.length ? ` — WRONG: ${badNotNull.join('; ')}` : ''}`);

    // The four columns that must stay NULLABLE, because NULL is their meaning:
    // "not generated yet", "no winner yet", "not scheduled yet".
    const nullableWanted = ['tournaments.fixtures_generated_at', 'tournaments.winner_team',
      'tournaments.rounds', 'fixtures.slot_id', 'fixtures.scheduled_at', 'fixtures.match_id'];
    const badNullable = nullableWanted
      .filter((k) => (colInfo.get(k) || {}).is_nullable !== 'YES');
    check(badNullable.length === 0,
      'the 6 columns whose NULL is a meaning ("not generated / no winner / not scheduled") stay nullable'
      + `${badNullable.length ? ` — WRONG: ${badNullable.join(', ')}` : ''}`);

    // ─── 4. Indexes ─────────────────────────────────────────────────────────
    const { rows: idxRows } = await client.query(
      `SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = 'public'`,
    );
    const idx = new Map(idxRows.map((r) => [r.indexname, r.indexdef]));
    const missingIdx = EXPECTED_INDEXES.filter((n) => !idx.has(n));
    check(missingIdx.length === 0,
      `all ${EXPECTED_INDEXES.length} indexes 019 creates exist`
      + `${missingIdx.length ? ` — MISSING: ${missingIdx.join(', ')}` : ''}`);

    const missingInherited = INHERITED_INDEXES.filter((n) => !idx.has(n));
    check(missingInherited.length === 0,
      `the ${INHERITED_INDEXES.length} tournament indexes 013 created are still present, so 019 `
      + `did not need to duplicate them`
      + `${missingInherited.length ? ` — MISSING: ${missingInherited.join(', ')}` : ''}`);

    // The point of not re-creating them: exactly ONE index over
    // (status, registration_deadline). A second one under a different name would
    // double the write cost of every tournament update to answer one query.
    const browseIdx = idx.get('idx_tournaments_status') || '';
    check(/registration_deadline/i.test(browseIdx) && !idx.has('idx_tournaments_open'),
      'the browse list is served by the idx_tournaments_status that 013 created — no duplicate '
      + 'index over the same two columns');

    // The one index that is a RULE and not an optimisation: one fixture per slot.
    // It must be UNIQUE and it must be partial, or the many unscheduled fixtures
    // (slot_id NULL) would collide with each other and generation would fail.
    const slotIdx = idx.get('uq_fixtures_slot_id') || '';
    check(/CREATE UNIQUE INDEX/i.test(slotIdx) && /WHERE/i.test(slotIdx),
      'uq_fixtures_slot_id is UNIQUE and partial on slot_id IS NOT NULL '
      + '(one fixture per reserved hour; unscheduled fixtures do not collide)');

    // The deadline job scans this every sweep, forever. Partial on the two facts
    // that define a candidate, so a completed tournament is never read.
    const dueIdx = idx.get('idx_tournaments_due') || '';
    check(/WHERE/i.test(dueIdx) && /fixtures_generated_at/i.test(dueIdx),
      'idx_tournaments_due is partial on status = open AND fixtures_generated_at IS NULL '
      + '(the job never reads a tournament it has already handled)');

    const txnIdx = idx.get('idx_transactions_tournament') || '';
    check(/WHERE/i.test(txnIdx),
      'idx_transactions_tournament is partial on tournament_id IS NOT NULL '
      + '(the ledger is mostly bookings; this indexes only the tournament rows)');

    // ─── 5. Constraints ─────────────────────────────────────────────────────
    const { rows: conRows } = await client.query(
      `SELECT con.conname, con.contype, pg_get_constraintdef(con.oid) AS def
         FROM pg_constraint con
         JOIN pg_class rel ON rel.oid = con.conrelid
         JOIN pg_namespace ns ON ns.oid = rel.relnamespace
        WHERE ns.nspname = 'public' AND con.contype IN ('c', 'u')`,
    );
    const cons = new Map(conRows.map((r) => [r.conname, r]));
    const missingCons = EXPECTED_CONSTRAINTS.filter((n) => !cons.has(n));
    check(missingCons.length === 0,
      `all ${EXPECTED_CONSTRAINTS.length} CHECK constraints exist`
      + `${missingCons.length ? ` — MISSING: ${missingCons.join(', ')}` : ''}`);

    const missingUniq = EXPECTED_UNIQUE_CONSTRAINTS.filter((n) => (cons.get(n) || {}).contype !== 'u');
    check(missingUniq.length === 0,
      'uq_fixtures_slot is a UNIQUE constraint on (tournament_id, round, position) '
      + '— fixture generation is safe to retry'
      + `${missingUniq.length ? ` — MISSING: ${missingUniq.join(', ')}` : ''}`);

    // 013's UNIQUE (tournament_id, team_id) is what 019 RELIES ON rather than
    // re-creating, so it is asserted rather than assumed: without it, a
    // double-tapped Register button charges one captain twice.
    const dedupe = conRows.find((r) => r.contype === 'u'
      && /tournament_id/.test(r.def) && /team_id/.test(r.def) && !/round/.test(r.def));
    check(Boolean(dedupe),
      `tournament_teams still carries UNIQUE (tournament_id, team_id) `
      + `— one entry per team, so a double-tapped Register cannot charge twice`
      + `${dedupe ? ` [${dedupe.conname}]` : ''}`);

    // The bracket-shape CHECK must actually contain the power-of-two test; a
    // constraint that only capped the ceiling would let max_teams = 6 through.
    const maxTeamsDef = (cons.get('chk_tournaments_max_teams') || {}).def || '';
    check(/&/.test(maxTeamsDef) && /round_robin/.test(maxTeamsDef),
      'chk_tournaments_max_teams tests the power of two (x & (x-1) = 0) for knockout '
      + 'and caps round_robin separately');

    // ─── 6. The global_settings tournament block ────────────────────────────
    const { rows: setRows } = await client.query(
      `SELECT value FROM global_settings WHERE key = 'tournament'`,
    );
    const setting = setRows.length ? setRows[0].value : null;
    const missingKeys = setting
      ? EXPECTED_SETTING_KEYS.filter((k) => setting[k] === undefined)
      : EXPECTED_SETTING_KEYS;
    check(Boolean(setting) && missingKeys.length === 0,
      `global_settings.tournament carries all ${EXPECTED_SETTING_KEYS.length} policy keys`
      + `${missingKeys.length ? ` — MISSING: ${missingKeys.join(', ')}` : ''}`);

    // The split must add up in the SEED too, not only in the code that reads it.
    if (setting) {
      check(Number(setting.winner_percent) + Number(setting.runnerup_percent) === 100,
        `the seeded prize split adds to 100 (winner ${setting.winner_percent} `
        + `+ runner-up ${setting.runnerup_percent})`);
      check(Number(setting.k_early) === 40 && Number(setting.k_semi) === 48
        && Number(setting.k_final) === 56,
        'the seeded K-factors are 40 / 48 / 56 (early / semi / final) against 32 for a friendly');
    }

    // elo.k_factor must still be 32: the tournament weights are ADDED beside the
    // friendly ladder, not a replacement for it.
    const { rows: eloRows } = await client.query(
      `SELECT value FROM global_settings WHERE key = 'elo'`,
    );
    check(eloRows.length > 0 && Number(eloRows[0].value.k_factor) === 32,
      'global_settings.elo.k_factor is still 32 — one ladder, the friendly weight untouched');

    // ─── 7. Functional probes ───────────────────────────────────────────────
    // Everything below runs inside a transaction that is ALWAYS rolled back, and
    // every write expected to fail gets its own SAVEPOINT: without one, the first
    // 23505/23514 aborts the transaction and every later query dies with 25P02
    // instead of reporting a result.
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

    // The probes need real FK targets. A seeded dev database has them; an empty
    // one skips the probes with a note — the constraints are still proven to
    // EXIST above, and the probes are what prove they BITE.
    const { rows: teamRows } = await client.query(
      'SELECT id, titles FROM teams ORDER BY created_at LIMIT 2');
    const { rows: slotRows } = await client.query('SELECT id FROM slots LIMIT 2');
    const { rows: bookingRows } = await client.query('SELECT id FROM bookings LIMIT 1');

    if (teamRows.length >= 2) {
      const [tA, tB] = teamRows.map((r) => r.id);

      // One parameterised INSERT for the tournament probes. Every probe row
      // carries PROBE_TAG in `name` and `description` so the leftover check can
      // prove the rollback took.
      const insT = (fields = {}) => {
        const base = {
          name: PROBE_TAG, sport: 'football', description: PROBE_TAG,
          format: 'knockout', max_teams: 8, ...fields,
        };
        const keys = Object.keys(base);
        const ph = keys.map((_, i) => `$${i + 1}`).join(', ');
        return client.query(
          `INSERT INTO tournaments (${keys.join(', ')}, registration_deadline)
           VALUES (${ph}, now() + interval '7 days') RETURNING id`,
          keys.map((k) => base[k]),
        );
      };

      await client.query('BEGIN');
      try {
        // ── 7a. Bracket shape — the constraint that keeps a knockout closable ─
        const ok8 = await tryWrite('p1', () => insT({ max_teams: 8 }));
        check(ok8.ok, 'a knockout with max_teams = 8 is accepted (a closable bracket)');

        const bad6 = await tryWrite('p2', () => insT({ max_teams: 6 }));
        check(!bad6.ok && bad6.code === '23514',
          `a knockout with max_teams = 6 is rejected (23514) — 6 is not a power of two, so `
          + `round 2 would have 3 teams and the bracket could never close`
          + `${bad6.ok ? ' — IT WAS ACCEPTED' : ` — got ${bad6.code}`}`);

        const bad64 = await tryWrite('p3', () => insT({ max_teams: 64 }));
        check(!bad64.ok && bad64.code === '23514',
          `a knockout with max_teams = 64 is rejected (23514) — 63 fixtures is more ground `
          + `time than any venue in this system has${bad64.ok ? ' — IT WAS ACCEPTED' : ''}`);

        const rr6 = await tryWrite('p4', () => insT({ format: 'round_robin', max_teams: 6 }));
        check(rr6.ok, 'a round-robin with max_teams = 6 is accepted (15 fixtures, still priceable)');

        const rr8 = await tryWrite('p5', () => insT({ format: 'round_robin', max_teams: 8 }));
        check(!rr8.ok && rr8.code === '23514',
          `a round-robin with max_teams = 8 is rejected (23514) — n(n-1)/2 is 28 fixtures `
          + `against 8 entry fees, which no sane fee covers`
          + `${rr8.ok ? ' — IT WAS ACCEPTED' : ''}`);

        const rr5 = await tryWrite('p6', () => insT({ format: 'round_robin', max_teams: 5 }));
        check(rr5.ok, 'a round-robin with max_teams = 5 is accepted (the power-of-two rule is knockout-only)');

        // ── 7b. Vocabulary ───────────────────────────────────────────────────
        const badFmt = await tryWrite('p7', () => insT({ format: 'league' }));
        check(!badFmt.ok && badFmt.code === '23514',
          `format = 'league' is rejected (23514) — utils/fixtures.js generates two shapes`
          + `${badFmt.ok ? ' — IT WAS ACCEPTED' : ''}`);

        const badStatus = await tryWrite('p8', () => insT({ status: 'draft' }));
        check(!badStatus.ok && badStatus.code === '23514',
          `status = 'draft' is rejected (23514) — the browse list tests status = 'open' and a `
          + `typo'd status would make a tournament invisible while still taking money`
          + `${badStatus.ok ? ' — IT WAS ACCEPTED' : ''}`);

        // ── 7c. The money percentages ────────────────────────────────────────
        const badSplit = await tryWrite('p9', () => insT({ winner_percent: 60, runnerup_percent: 30 }));
        check(!badSplit.ok && badSplit.code === '23514',
          `winner 60 + runner-up 30 is rejected (23514) — 10% of the prize pool would be `
          + `collected from the teams and paid to nobody`
          + `${badSplit.ok ? ' — IT WAS ACCEPTED' : ''}`);

        const okSplit = await tryWrite('p10', () => insT({ winner_percent: 65, runnerup_percent: 35 }));
        check(okSplit.ok, 'winner 65 + runner-up 35 is accepted (any split is fine as long as it totals 100)');

        const badDisc = await tryWrite('p11', () => insT({ venue_discount_percent: 120 }));
        check(!badDisc.ok && badDisc.code === '23514',
          `venue_discount_percent = 120 is rejected (23514) — a discount above 100 would make `
          + `venue_cost negative and pay the owner for using their own ground`
          + `${badDisc.ok ? ' — IT WAS ACCEPTED' : ''}`);

        const badFee = await tryWrite('p12', () => insT({ entry_fee: -500 }));
        check(!badFee.ok && badFee.code === '23514',
          `entry_fee = -500 is rejected (23514)${badFee.ok ? ' — IT WAS ACCEPTED' : ''}`);

        const badMin = await tryWrite('p13', () => insT({ max_teams: 4, min_teams: 8 }));
        check(!badMin.ok && badMin.code === '23514',
          `min_teams 8 above max_teams 4 is rejected (23514) — the deadline job would cancel `
          + `every tournament of that shape, refunding teams that had done nothing wrong`
          + `${badMin.ok ? ' — IT WAS ACCEPTED' : ''}`);

        const badMinutes = await tryWrite('p14', () => insT({ slot_minutes: 0 }));
        check(!badMinutes.ok && badMinutes.code === '23514',
          `slot_minutes = 0 is rejected (23514) — the scheduler divides by it`
          + `${badMinutes.ok ? ' — IT WAS ACCEPTED' : ''}`);

        // ── 7d. Registration — one entry per team, and its vocabulary ─────────
        const { rows: [tour] } = await insT({ max_teams: 4, entry_fee: 1000 });
        await client.query(
          `INSERT INTO tournament_teams (tournament_id, team_id, status, paid_amount)
           VALUES ($1, $2, 'accepted', 1000)`, [tour.id, tA]);

        const dupeEntry = await tryWrite('p15', () => client.query(
          `INSERT INTO tournament_teams (tournament_id, team_id) VALUES ($1, $2)`,
          [tour.id, tA]));
        check(!dupeEntry.ok && dupeEntry.code === '23505',
          `the same team registering twice is rejected (23505) — a double-tapped Register `
          + `cannot freeze two entry fees${dupeEntry.ok ? ' — IT WAS ACCEPTED' : ''}`);

        const badEntryStatus = await tryWrite('p16', () => client.query(
          `INSERT INTO tournament_teams (tournament_id, team_id, status) VALUES ($1, $2, 'paid')`,
          [tour.id, tB]));
        check(!badEntryStatus.ok && badEntryStatus.code === '23514',
          `tournament_teams status = 'paid' is rejected (23514) — capacity counts `
          + `registered + accepted, and a status outside that list is a team nobody counts`
          + `${badEntryStatus.ok ? ' — IT WAS ACCEPTED' : ''}`);

        const negPaid = await tryWrite('p17', () => client.query(
          `INSERT INTO tournament_teams (tournament_id, team_id, paid_amount)
           VALUES ($1, $2, -1)`, [tour.id, tB]));
        check(!negPaid.ok && negPaid.code === '23514',
          `a negative paid_amount is rejected (23514) — a refund must return what was taken`
          + `${negPaid.ok ? ' — IT WAS ACCEPTED' : ''}`);

        // ── 7e. The bracket ──────────────────────────────────────────────────
        await client.query(
          `INSERT INTO fixtures (tournament_id, round, position, team_a, team_b, label)
           VALUES ($1, 1, 1, $2, $3, 'Semi-final 1')`, [tour.id, tA, tB]);

        const dupeNode = await tryWrite('p18', () => client.query(
          `INSERT INTO fixtures (tournament_id, round, position) VALUES ($1, 1, 1)`,
          [tour.id]));
        check(!dupeNode.ok && dupeNode.code === '23505',
          `a second fixture at (round 1, position 1) is rejected (23505) — this is what makes `
          + `fixture generation safe to retry instead of drawing a doubled bracket`
          + `${dupeNode.ok ? ' — IT WAS ACCEPTED' : ''}`);

        const zeroRound = await tryWrite('p19', () => client.query(
          `INSERT INTO fixtures (tournament_id, round, position) VALUES ($1, 0, 1)`,
          [tour.id]));
        check(!zeroRound.ok && zeroRound.code === '23514',
          `round 0 is rejected (23514) — rounds are 1-based and the advance arithmetic `
          + `assumes it${zeroRound.ok ? ' — IT WAS ACCEPTED' : ''}`);

        const selfPlay = await tryWrite('p20', () => client.query(
          `INSERT INTO fixtures (tournament_id, round, position, team_a, team_b)
           VALUES ($1, 1, 2, $2, $2)`, [tour.id, tA]));
        check(!selfPlay.ok && selfPlay.code === '23514',
          `a team drawn against itself is rejected (23514) — the classic off-by-one in a `
          + `seeding table${selfPlay.ok ? ' — IT WAS ACCEPTED' : ''}`);

        // THE most damaging thing a bracket can get wrong.
        const fatBye = await tryWrite('p21', () => client.query(
          `INSERT INTO fixtures (tournament_id, round, position, team_a, team_b, is_bye)
           VALUES ($1, 1, 2, $2, $3, true)`, [tour.id, tA, tB]));
        check(!fatBye.ok && fatBye.code === '23514',
          `a bye carrying TWO teams is rejected (23514) — it would advance a side that never `
          + `played its opponent${fatBye.ok ? ' — IT WAS ACCEPTED' : ''}`);

        const thinBye = await tryWrite('p22', () => client.query(
          `INSERT INTO fixtures (tournament_id, round, position, team_a, is_bye, status, winner)
           VALUES ($1, 1, 2, $2, true, 'walkover', $2)`, [tour.id, tA]));
        check(thinBye.ok,
          'a real bye — one team, status walkover, winner = that team — is accepted and resolved at once');

        const noScore = await tryWrite('p23', () => client.query(
          `INSERT INTO fixtures (tournament_id, round, position, team_a, team_b, status)
           VALUES ($1, 1, 3, $2, $3, 'played')`, [tour.id, tA, tB]));
        check(!noScore.ok && noScore.code === '23514',
          `status = 'played' with no scoreline is rejected (23514) — standings are DERIVED from `
          + `these scores, so a NULL would silently drop a result from the table`
          + `${noScore.ok ? ' — IT WAS ACCEPTED' : ''}`);

        const badFixStatus = await tryWrite('p24', () => client.query(
          `INSERT INTO fixtures (tournament_id, round, position, status) VALUES ($1, 9, 9, 'plaid')`,
          [tour.id]));
        check(!badFixStatus.ok && badFixStatus.code === '23514',
          `fixture status = 'plaid' is rejected (23514) — 013 documented the vocabulary in a `
          + `comment and enforced nothing${badFixStatus.ok ? ' — IT WAS ACCEPTED' : ''}`);

        // ── 7f. One fixture per reserved hour ────────────────────────────────
        if (slotRows.length) {
          const slot = slotRows[0].id;
          await client.query(
            `UPDATE fixtures SET slot_id = $2, scheduled_at = now() + interval '2 days'
              WHERE tournament_id = $1 AND round = 1 AND position = 1`, [tour.id, slot]);
          const twoOnOne = await tryWrite('p25', () => client.query(
            `INSERT INTO fixtures (tournament_id, round, position, slot_id)
             VALUES ($1, 2, 1, $2)`, [tour.id, slot]));
          check(!twoOnOne.ok && twoOnOne.code === '23505',
            `a second fixture on the SAME slot is rejected (23505) — the slot is blocked for `
            + `the first, so the second pair of teams would arrive to an occupied ground`
            + `${twoOnOne.ok ? ' — IT WAS ACCEPTED' : ''}`);
        } else {
          console.log('   ~ skipped the one-fixture-per-slot probe (no slots rows)');
        }

        // ── 7g. A match belongs to ONE context ───────────────────────────────
        const tourMatch = await tryWrite('p26', () => client.query(
          `INSERT INTO matches (challenger_team, opponent_team, sport, status, tournament_id)
           VALUES ($1, $2, 'football', 'awaiting_owner', $3) RETURNING id`,
          [tA, tB, tour.id]));
        check(tourMatch.ok,
          'a tournament match — booking_id NULL, tournament_id set — is accepted, so S.2\'s '
          + 'result flow is reused rather than duplicated');

        if (bookingRows.length) {
          const bothCtx = await tryWrite('p27', () => client.query(
            `INSERT INTO matches (challenger_team, opponent_team, sport, booking_id, tournament_id)
             VALUES ($1, $2, 'football', $3, $4)`, [tA, tB, bookingRows[0].id, tour.id]));
          check(!bothCtx.ok && bothCtx.code === '23514',
            `a match carrying BOTH a booking and a tournament is rejected (23514) — "who may `
            + `verify this result?" would have two answers, and that is a dispute waiting to `
            + `happen${bothCtx.ok ? ' — IT WAS ACCEPTED' : ''}`);
        } else {
          console.log('   ~ skipped the dual-context probe (no bookings rows)');
        }

        // ── 7h. The tournament-record counters ───────────────────────────────
        const negTitles = await tryWrite('p28', () => client.query(
          `UPDATE teams SET titles = -1 WHERE id = $1`, [tA]));
        check(!negTitles.ok && negTitles.code === '23514',
          `titles = -1 is rejected (23514) — the counters are an achievement record and only `
          + `ever go up${negTitles.ok ? ' — IT WAS ACCEPTED' : ''}`);

        const bumpRecord = await tryWrite('p29', () => client.query(
          `UPDATE teams SET tournament_played = tournament_played + 1,
                            tournament_wins   = tournament_wins + 1,
                            finals_reached    = finals_reached + 1,
                            titles            = titles + 1
            WHERE id = $1`, [tA]));
        check(bumpRecord.ok,
          'the four counters increment together (the team card reads "12 played · 8 W · 2 titles")');

        // ── 7i. The ledger can be read per tournament ────────────────────────
        const { rows: walletRows } = await client.query('SELECT user_id FROM wallets LIMIT 1');
        if (walletRows.length) {
          const entryTxn = await tryWrite('p30', () => client.query(
            `INSERT INTO transactions (user_id, type, amount, description, tournament_id)
             VALUES ($1, 'tournament_entry', 1000, $2, $3)`,
            [walletRows[0].user_id, PROBE_TAG, tour.id]));
          check(entryTxn.ok,
            'a tournament_entry transaction tagged with tournament_id is accepted — the paisa '
            + 'audit (pool = venue_cost + prize + margin) is one GROUP BY, not a text parse');
        } else {
          console.log('   ~ skipped the ledger probe (no wallets rows)');
        }
      } finally {
        await client.query('ROLLBACK');   // nothing above may survive
      }

      const { rows: [left] } = await client.query(
        `SELECT (SELECT count(*)::int FROM tournaments  WHERE name        = $1) AS t,
                (SELECT count(*)::int FROM transactions WHERE description = $1) AS x`,
        [PROBE_TAG],
      );
      const leftover = left.t + left.x;
      check(leftover === 0,
        `probes rolled back cleanly — ${leftover} probe row(s) left behind`);

      // The counters were bumped inside the rolled-back transaction; prove the
      // rollback reached them too, because a leaked +1 title would be a false
      // achievement on a real team's card. Compared against the value READ
      // BEFORE the probes, not against 0 — a team may legitimately have titles.
      const { rows: [nowTeam] } = await client.query(
        'SELECT titles FROM teams WHERE id = $1', [teamRows[0].id],
      );
      check(Number(nowTeam.titles) === Number(teamRows[0].titles),
        `the probe titles increment rolled back too — team still at ${teamRows[0].titles} `
        + `title(s), no false achievement left on a real team`);
    } else {
      console.log('   ~ skipped all functional probes (need two teams rows)');
      console.log('     The constraints are proven to EXIST above; run the seed script and');
      console.log('     re-run this to prove they BITE.');
    }

    // ─── Listing ────────────────────────────────────────────────────────────
    console.log('');
    console.log('Tournament module now enforced by the database:');
    console.log('   • knockout max_teams is a power of two, round-robin capped at 6 — FE-1/FE-6');
    console.log('   • one entry per team, one fixture per bracket node, one fixture per slot — FE-4');
    console.log('   • a bye carries exactly one team and resolves immediately');
    console.log('   • a played fixture must have a scoreline (standings are derived) — FE-7');
    console.log('   • winner% + runner-up% = 100, no negative money, discount 0-100');
    console.log('   • a match has a booking OR a tournament, never both');
    console.log('   • three txn_type values, and the ledger is filterable by tournament');
    console.log('   • teams carry a tournament record instead of a second ELO ladder');
  } catch (e) {
    failures.push(`migration threw: ${e.message}`);
    console.error('');
    console.error('❌ Migration 019 failed:', e.message);
    if (e.detail) console.error('   detail:', e.detail);
    if (e.hint) console.error('   hint:', e.hint);
  } finally {
    client.release();
    await pool.end();
  }

  console.log('');
  if (failures.length) {
    console.error(`❌ Migration 019: ${failures.length} check(s) failed.`);
  } else {
    console.log('✅ Migration 019 verified — tournaments, brackets and the prize waterfall ready.');
  }
  process.exit(failures.length ? 1 : 0);
}

run();
