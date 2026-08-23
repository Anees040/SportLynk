/**
 * Runner for migrations/016_matches_elo.sql
 * Usage: node run_migration_016.js
 *
 * Applied as ONE multi-statement command, so Postgres wraps it in a single
 * implicit transaction and a failure anywhere leaves the database untouched.
 * (No `-- @@SPLIT@@` marker: this migration adds no enum values, and
 * `ALTER TYPE ... ADD VALUE` is the only statement that cannot run inside a
 * transaction.)
 *
 * Like the 015 runner, this is more than a `\d` dump:
 *
 *   1. A PRE-FLIGHT that can stop the migration. chk_matches_status is a CHECK
 *      over live data — if a row already holds a status outside the state
 *      machine, the ALTER fails with a 23514 that names the constraint and not
 *      the row. Bad statuses are found and PRINTED first, and the migration is
 *      not attempted, because deciding what a mystery status should become is a
 *      decision for a human. The same applies to ux_matches_booking_live: two
 *      live matches already sharing one booking is a double-booked pitch, and a
 *      migration must not pick which match survives.
 *
 *   2. FUNCTIONAL PROBES. Ten of the guarantees here are constraints, and a
 *      constraint that exists but does not constrain is worse than no constraint
 *      — it reads as enforced in the schema and is enforced nowhere. Each probe
 *      inserts a row that MUST be rejected and asserts the SQLSTATE, inside a
 *      transaction that is always rolled back. The probe that matters most is
 *      the one-live-match-per-booking index, because that is the only thing
 *      standing between a double-tapped Challenge button and two teams turning
 *      up for the same slot.
 *
 * Safe to re-run: every statement in the .sql is idempotent.
 */
const fs = require('fs');
const path = require('path');
const pool = require('./src/db/pool');

// 016 alters or references all of these. A missing one means 013 was never run.
const PREREQUISITE_TABLES = [
  'users', 'teams', 'bookings', 'venues',
  'matches', 'match_results', 'disputes', 'elo_history', 'global_settings',
];

const EXPECTED_INDEXES = [
  'ux_matches_booking_live',
  'idx_matches_expiry',
  'idx_matches_awaiting_owner',
  'ux_elo_history_team_match',
  'idx_teams_elo_frozen',
  'ux_disputes_match_team',
  'idx_disputes_raised_by',
];

const EXPECTED_CONSTRAINTS = [
  'chk_matches_status',
  'chk_matches_distinct_teams',
  'chk_matches_scores_nonneg',
  'chk_matches_competitiveness',
  'chk_elo_history_reason',
  'chk_disputes_status',
  'chk_match_results_scores',
];

// column → information_schema.data_type, per table.
const EXPECTED_COLUMNS = {
  matches: {
    competitiveness: 'integer',
    preview_text: 'text',
    elo_applied: 'boolean',
    results_locked: 'boolean',
    created_by: 'uuid',
    responded_at: 'timestamp with time zone',
    updated_at: 'timestamp with time zone',
  },
  elo_history: {
    elo_delta: 'integer',
    k_factor: 'numeric',
    reason: 'text',
  },
  teams: {
    elo_frozen: 'boolean',
    elo_frozen_reason: 'text',
    elo_frozen_at: 'timestamp with time zone',
  },
  disputes: {
    resolved_at: 'timestamp with time zone',
  },
};

/** Every status the state machine in doc/API.md can produce. */
const LEGAL_STATUSES = [
  'challenge_sent', 'accepted', 'rejected', 'expired',
  'awaiting_results', 'awaiting_owner', 'completed', 'disputed',
];

const LIVE_STATUSES = [
  'challenge_sent', 'accepted', 'awaiting_results',
  'awaiting_owner', 'completed', 'disputed',
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
  const sqlFile = path.join(__dirname, 'migrations', '016_matches_elo.sql');
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
      console.error('❌ Cannot apply migration 016 — prerequisite tables missing:');
      console.error(`   ${missingPrereqs.join(', ')}`);
      console.error('   Apply schema.sql, then run_migration_013.js, then 015.');
      client.release();
      await pool.end();
      process.exit(1);
    }

    // 1a. A status outside the state machine blocks chk_matches_status.
    const { rows: badStatus } = await client.query(
      `SELECT status, count(*)::int AS n
         FROM matches
        WHERE status IS NULL OR NOT (status = ANY($1))
        GROUP BY status
        ORDER BY n DESC`,
      [LEGAL_STATUSES],
    );
    if (badStatus.length) {
      console.error('❌ Cannot apply migration 016 — matches.status values outside');
      console.error('   the state machine block chk_matches_status:');
      console.error('');
      for (const r of badStatus) {
        console.error(`   ${r.n}× ${r.status === null ? 'NULL' : `"${r.status}"`}`);
      }
      console.error('');
      console.error(`   Legal values: ${LEGAL_STATUSES.join(', ')}`);
      console.error('   Fix or delete those rows, then re-run. A migration must not');
      console.error('   guess what a mystery status was supposed to mean.');
      client.release();
      await pool.end();
      process.exit(1);
    }

    // 1b. Two live matches on one booking block ux_matches_booking_live — and
    //     mean a pitch is already double-booked.
    const { rows: dupeBookings } = await client.query(
      `SELECT booking_id, count(*)::int AS n, string_agg(id::text || ' (' || status || ')', ', ') AS which
         FROM matches
        WHERE booking_id IS NOT NULL AND status = ANY($1)
        GROUP BY booking_id
       HAVING count(*) > 1
        ORDER BY n DESC`,
      [LIVE_STATUSES],
    );
    if (dupeBookings.length) {
      console.error('❌ Cannot apply migration 016 — more than one live match shares');
      console.error('   a booking, which blocks ux_matches_booking_live:');
      console.error('');
      for (const d of dupeBookings) {
        console.error(`   booking ${d.booking_id}: ${d.n}× → ${d.which}`);
      }
      console.error('');
      console.error('   One slot cannot host two matches. Cancel or reject all but one');
      console.error('   of each set, then re-run.');
      client.release();
      await pool.end();
      process.exit(1);
    }

    // 1c. Duplicate disputes from one team on one match block ux_disputes_match_team.
    const { rows: dupeDisputes } = await client.query(
      `SELECT match_id, raised_by_team, count(*)::int AS n
         FROM disputes
        WHERE match_id IS NOT NULL AND raised_by_team IS NOT NULL
        GROUP BY match_id, raised_by_team
       HAVING count(*) > 1`,
    );
    if (dupeDisputes.length) {
      console.error('❌ Cannot apply migration 016 — a team has filed more than one');
      console.error('   dispute on the same match, blocking ux_disputes_match_team:');
      console.error('');
      for (const d of dupeDisputes) {
        console.error(`   match ${d.match_id}, team ${d.raised_by_team}: ${d.n} disputes`);
      }
      console.error('');
      console.error('   Keep one row per (match, team) and delete the rest, then re-run.');
      client.release();
      await pool.end();
      process.exit(1);
    }

    const { rows: [counts] } = await client.query(
      `SELECT (SELECT count(*)::int FROM matches)       AS matches,
              (SELECT count(*)::int FROM match_results) AS results,
              (SELECT count(*)::int FROM elo_history)   AS history,
              (SELECT count(*)::int FROM disputes)      AS disputes,
              (SELECT count(*)::int FROM teams)         AS teams`,
    );
    console.log(`Pre-flight: ${before.length} tables present, all prerequisites found.`);
    console.log(`   ${counts.matches} match(es), ${counts.results} submitted result(s), `
      + `${counts.history} rating row(s), ${counts.disputes} dispute(s), ${counts.teams} team(s).`);
    console.log('   No illegal statuses, no double-booked matches, no duplicate disputes.');
    console.log('');

    // ─── Apply ──────────────────────────────────────────────────────────────
    await client.query(sql);
    console.log('Migration 016 applied. Verifying:');
    console.log('');

    // ─── 1. Columns ─────────────────────────────────────────────────────────
    const { rows: cols } = await client.query(
      `SELECT table_name, column_name, data_type, is_nullable, column_default
         FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = ANY($1)`,
      [Object.keys(EXPECTED_COLUMNS)],
    );
    const typeOf = new Map(cols.map((r) => [`${r.table_name}.${r.column_name}`, r.data_type]));
    const defaultOf = new Map(cols.map((r) => [`${r.table_name}.${r.column_name}`, r.column_default]));

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

    // The two latches must default to false, or an existing match would look
    // already-verified and its rating exchange would be skipped forever.
    check(/false/i.test(defaultOf.get('matches.elo_applied') || ''),
      'matches.elo_applied defaults to FALSE (an unverified match is not already rated)');
    check(/false/i.test(defaultOf.get('matches.results_locked') || ''),
      'matches.results_locked defaults to FALSE');
    check(/false/i.test(defaultOf.get('teams.elo_frozen') || ''),
      'teams.elo_frozen defaults to FALSE (no team starts frozen)');

    // ─── 2. Indexes ─────────────────────────────────────────────────────────
    const { rows: idxRows } = await client.query(
      `SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = 'public'`,
    );
    const idx = new Map(idxRows.map((r) => [r.indexname, r.indexdef]));
    const missingIdx = EXPECTED_INDEXES.filter((n) => !idx.has(n));
    check(missingIdx.length === 0,
      `all ${EXPECTED_INDEXES.length} indexes exist${missingIdx.length ? ` — MISSING: ${missingIdx.join(', ')}` : ''}`);

    // The ones that must have a specific SHAPE, not just a name.
    const bookingIdx = idx.get('ux_matches_booking_live') || '';
    check(/CREATE UNIQUE INDEX/i.test(bookingIdx) && /WHERE/i.test(bookingIdx)
      && /rejected/i.test(bookingIdx) === false,
      'ux_matches_booking_live is UNIQUE and partial, and does NOT cover rejected/expired '
      + '(a declined challenge must release the slot)');

    const expiryIdx = idx.get('idx_matches_expiry') || '';
    check(/challenge_sent/i.test(expiryIdx),
      'idx_matches_expiry is partial on challenge_sent — the 48h sweep is not a seq scan');

    const histIdx = idx.get('ux_elo_history_team_match') || '';
    check(/CREATE UNIQUE INDEX/i.test(histIdx),
      'ux_elo_history_team_match is UNIQUE — one rating row per team per match');

    // ─── 3. CHECK constraints exist ─────────────────────────────────────────
    const { rows: conRows } = await client.query(
      `SELECT con.conname, pg_get_constraintdef(con.oid) AS def
         FROM pg_constraint con
         JOIN pg_class rel ON rel.oid = con.conrelid
         JOIN pg_namespace ns ON ns.oid = rel.relnamespace
        WHERE ns.nspname = 'public' AND con.contype = 'c'`,
    );
    const cons = new Map(conRows.map((r) => [r.conname, r.def]));
    const missingCons = EXPECTED_CONSTRAINTS.filter((n) => !cons.has(n));
    check(missingCons.length === 0,
      `all ${EXPECTED_CONSTRAINTS.length} CHECK constraints exist${missingCons.length ? ` — MISSING: ${missingCons.join(', ')}` : ''}`);

    const statusDef = cons.get('chk_matches_status') || '';
    const missingStates = LEGAL_STATUSES.filter((s) => !statusDef.includes(s));
    check(missingStates.length === 0,
      `chk_matches_status covers all ${LEGAL_STATUSES.length} states of the machine${missingStates.length ? ` — MISSING: ${missingStates.join(', ')}` : ''}`);

    // ─── 4. Settings rows Wave B reads ──────────────────────────────────────
    const { rows: settings } = await client.query(
      `SELECT key, value FROM global_settings WHERE key IN ('elo','match')`,
    );
    const byKey = new Map(settings.map((r) => [r.key, r.value]));
    const eloCfg = byKey.get('elo') || {};
    check(Number(eloCfg.base) > 0 && Number(eloCfg.k_factor) > 0,
      `global_settings.elo is readable — base ${eloCfg.base}, K ${eloCfg.k_factor}`);
    const matchCfg = byKey.get('match') || {};
    check(Number(matchCfg.challenge_ttl_hours) === 48 && Number(matchCfg.dispute_window_hours) === 24,
      `global_settings.match is readable — ${matchCfg.challenge_ttl_hours}h challenge TTL (FR5.12), `
      + `${matchCfg.dispute_window_hours}h dispute window (FR5.17)`);

    // ─── 5. Backfill actually happened ──────────────────────────────────────
    const { rows: [bf] } = await client.query(
      `SELECT count(*)::int AS unbackfilled
         FROM elo_history
        WHERE elo_delta IS NULL AND elo_before IS NOT NULL AND elo_after IS NOT NULL`,
    );
    check(bf.unbackfilled === 0,
      `every pre-existing rating row has its delta backfilled (${bf.unbackfilled} left NULL)`);

    // ─── 6. Functional probes — do the constraints actually constrain? ───────
    // Everything below runs inside a transaction that is ALWAYS rolled back, and
    // every insert expected to fail gets its own SAVEPOINT: without one, the
    // first 23514 aborts the transaction and every later query dies with 25P02
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
      const { rows: probeTeams } = await client.query(
        `INSERT INTO teams (name, sport) VALUES
           ('__mig016 Probe A', 'football'), ('__mig016 Probe B', 'football')
         RETURNING id`,
      );
      const { rows: bookingRows } = await client.query('SELECT id FROM bookings LIMIT 1');
      const [ta, tb] = probeTeams.map((r) => r.id);

      // 6a. A team cannot play itself.
      const selfPlay = await tryInsert('m1', () => client.query(
        `INSERT INTO matches (challenger_team, opponent_team, sport, status)
         VALUES ($1, $1, 'football', 'challenge_sent')`, [ta]));
      check(!selfPlay.ok && selfPlay.code === '23514',
        `a team challenging itself is rejected (23514)${selfPlay.ok ? ' — IT WAS ACCEPTED' : ` — got ${selfPlay.code}`}`);

      // 6b. A status outside the state machine.
      const badState = await tryInsert('m2', () => client.query(
        `INSERT INTO matches (challenger_team, opponent_team, sport, status)
         VALUES ($1, $2, 'football', 'complete')`, [ta, tb]));
      check(!badState.ok && badState.code === '23514',
        `status='complete' (typo for 'completed') is rejected by chk_matches_status${badState.ok ? ' — IT WAS ACCEPTED' : ''}`);

      // 6c. Competitiveness outside the 5..100 band.
      const badComp = await tryInsert('m3', () => client.query(
        `INSERT INTO matches (challenger_team, opponent_team, sport, status, competitiveness)
         VALUES ($1, $2, 'football', 'challenge_sent', 0)`, [ta, tb]));
      check(!badComp.ok && badComp.code === '23514',
        `competitiveness=0 is rejected (the band floors at 5, and 0 reads as missing data)${badComp.ok ? ' — IT WAS ACCEPTED' : ''}`);

      // 6d. THE important one — one live match per booking.
      if (bookingRows.length) {
        const bid = bookingRows[0].id;
        await client.query(
          `INSERT INTO matches (challenger_team, opponent_team, booking_id, sport, status)
           VALUES ($1, $2, $3, 'football', 'challenge_sent')`, [ta, tb, bid]);

        const doubleTap = await tryInsert('m4', () => client.query(
          `INSERT INTO matches (challenger_team, opponent_team, booking_id, sport, status)
           VALUES ($1, $2, $3, 'football', 'challenge_sent')`, [ta, tb, bid]));
        check(!doubleTap.ok && doubleTap.code === '23505',
          `a SECOND live match on the same booking is rejected (23505) — a double-tapped `
          + `Challenge cannot double-book the pitch${doubleTap.ok ? ' — IT WAS ACCEPTED' : ''}`);

        const afterReject = await tryInsert('m5', () => client.query(
          `INSERT INTO matches (challenger_team, opponent_team, booking_id, sport, status)
           VALUES ($2, $1, $3, 'football', 'rejected')`, [ta, tb, bid]));
        check(afterReject.ok,
          'a REJECTED match on that same booking is allowed — declining hands the slot back');
      } else {
        console.log('   ~ skipped the booking probes (no bookings row to attach a match to)');
      }

      // 6e. One result per team per match (013's UNIQUE), and non-negative scores.
      const { rows: [m] } = await client.query(
        `INSERT INTO matches (challenger_team, opponent_team, sport, status)
         VALUES ($1, $2, 'football', 'accepted') RETURNING id`, [ta, tb]);
      await client.query(
        `INSERT INTO match_results (match_id, submitted_by_team, winner_team, score_challenger, score_opponent)
         VALUES ($1, $2, $2, 3, 1)`, [m.id, ta]);
      const twice = await tryInsert('m6', () => client.query(
        `INSERT INTO match_results (match_id, submitted_by_team, winner_team, score_challenger, score_opponent)
         VALUES ($1, $2, $2, 5, 0)`, [m.id, ta]));
      check(!twice.ok && twice.code === '23505',
        `a team submitting a SECOND result for one match is rejected (23505) — "once" is `
        + `enforced by the DB, not by a JS check${twice.ok ? ' — IT WAS ACCEPTED' : ''}`);

      const negScore = await tryInsert('m7', () => client.query(
        `INSERT INTO match_results (match_id, submitted_by_team, winner_team, score_challenger, score_opponent)
         VALUES ($1, $2, $2, -1, 0)`, [m.id, tb]));
      check(!negScore.ok && negScore.code === '23514',
        `a negative score is rejected${negScore.ok ? ' — IT WAS ACCEPTED' : ''}`);

      // 6f. One rating row per team per match.
      await client.query(
        `INSERT INTO elo_history (team_id, match_id, elo_before, elo_after, elo_delta, k_factor, reason)
         VALUES ($1, $2, 1000, 1016, 16, 32, 'match_verified')`, [ta, m.id]);
      const twoRatings = await tryInsert('m8', () => client.query(
        `INSERT INTO elo_history (team_id, match_id, elo_before, elo_after, elo_delta, k_factor, reason)
         VALUES ($1, $2, 1016, 1032, 16, 32, 'match_verified')`, [ta, m.id]));
      check(!twoRatings.ok && twoRatings.code === '23505',
        `a SECOND rating row for one team in one match is rejected — a retried `
        + `verification cannot rate twice${twoRatings.ok ? ' — IT WAS ACCEPTED' : ''}`);

      const badReason = await tryInsert('m9', () => client.query(
        `INSERT INTO elo_history (team_id, match_id, elo_before, elo_after, elo_delta, reason)
         VALUES ($1, $2, 1000, 1000, 0, 'because')`, [tb, m.id]));
      check(!badReason.ok && badReason.code === '23514',
        `an unrecognised elo_history.reason is rejected${badReason.ok ? ' — IT WAS ACCEPTED' : ''}`);

      // 6g. One dispute per team per match.
      await client.query(
        `INSERT INTO disputes (match_id, raised_by_team, reason) VALUES ($1, $2, 'probe')`,
        [m.id, ta]);
      const twoDisputes = await tryInsert('m10', () => client.query(
        `INSERT INTO disputes (match_id, raised_by_team, reason) VALUES ($1, $2, 'probe again')`,
        [m.id, ta]));
      check(!twoDisputes.ok && twoDisputes.code === '23505',
        `a team filing a SECOND dispute on one match is rejected — one team cannot `
        + `inflate its own ER2.3 ratio${twoDisputes.ok ? ' — IT WAS ACCEPTED' : ''}`);

      const badDispute = await tryInsert('m11', () => client.query(
        `INSERT INTO disputes (match_id, raised_by_team, reason, status)
         VALUES ($1, $2, 'probe', 'pending')`, [m.id, tb]));
      check(!badDispute.ok && badDispute.code === '23514',
        `dispute status='pending' (not in open/resolved/dismissed) is rejected${badDispute.ok ? ' — IT WAS ACCEPTED' : ''}`);
    } finally {
      await client.query('ROLLBACK');   // nothing above may survive
    }

    const { rows: [{ t, mm }] } = await client.query(
      `SELECT (SELECT count(*)::int FROM teams WHERE name LIKE '__mig016%') AS t,
              (SELECT count(*)::int FROM matches m
                 JOIN teams x ON x.id = m.challenger_team
                WHERE x.name LIKE '__mig016%') AS mm`,
    );
    check(t === 0 && mm === 0,
      `probe rolled back cleanly — ${t} probe team(s), ${mm} probe match(es) left behind`);

    // ─── Listing ────────────────────────────────────────────────────────────
    console.log('');
    console.log('Match lifecycle now enforced by the database:');
    console.log('   challenge_sent ─accept→ accepted ─both results agree→ awaiting_owner');
    console.log('                                    ─owner verifies→ completed');
    console.log('   │reject / 48h expiry→ rejected | expired');
    console.log('   │results conflict→ disputed ─admin resolves→ completed');
  } catch (e) {
    failures.push(`migration threw: ${e.message}`);
    console.error('');
    console.error('❌ Migration 016 failed:', e.message);
    if (e.detail) console.error('   detail:', e.detail);
    if (e.hint) console.error('   hint:', e.hint);
  } finally {
    client.release();
    await pool.end();
  }

  console.log('');
  if (failures.length) {
    console.error(`❌ Migration 016: ${failures.length} check(s) failed.`);
  } else {
    console.log('✅ Migration 016 verified — ELO ledger and match lifecycle ready.');
  }
  process.exit(failures.length ? 1 : 0);
}

run();
