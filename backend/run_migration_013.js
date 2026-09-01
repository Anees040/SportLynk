/**
 * Runner for migrations/013_fyp2_foundation.sql
 * Usage: node run_migration_013.js
 *
 * Applies the migration as one multi-statement command, which Postgres wraps in
 * a single implicit transaction — so it is all-or-nothing. (No `-- @@SPLIT@@`
 * marker is needed here: unlike 010, this migration contains no
 * `ALTER TYPE ... ADD VALUE`, which is the only statement that cannot run
 * inside a transaction.)
 *
 * The wave's accept criterion was "migration runs clean; \dt shows all tables;
 * server boots". The first two are asserted below rather than left to a human
 * eyeballing psql output — and the assertions go further than \dt can, because
 * the real risk in this migration was never a missing table, it was a column
 * landing as `integer` when every key in this schema is `uuid`.
 *
 * Safe to re-run: every statement in the .sql is IF NOT EXISTS / ON CONFLICT
 * DO NOTHING, and the two teams backfills only fire while the legacy columns
 * still disagree with the new ones.
 */
const fs = require('fs');
const path = require('path');
const pool = require('./src/db/pool');

// Tables this migration ALTERs rather than creates. If any is missing, schema.sql
// or migration 010 has not been applied and the run must stop — an ALTER on a
// missing table would abort the whole transaction with a bare 42P01.
const PREREQUISITE_TABLES = [
  'users', 'venues', 'bookings', 'teams', 'reviews', 'player_profiles',
  'notifications',
];

const NEW_TABLES = [
  'team_invites', 'team_join_requests', 'matches', 'match_results', 'disputes',
  'elo_history', 'tournaments', 'tournament_teams', 'fixtures', 'chat_channels',
  'chat_messages', 'global_settings',
];

// Every column below must be uuid. This is the assertion that would have caught
// the spec as pasted: it declared all of these `int`/`serial`.
const MUST_BE_UUID = {
  team_invites: ['id', 'team_id', 'created_by', 'used_by'],
  team_join_requests: ['id', 'team_id', 'user_id'],
  matches: ['id', 'challenger_team', 'opponent_team', 'booking_id',
            'winner_team', 'verified_by'],
  match_results: ['id', 'match_id', 'submitted_by_team', 'winner_team'],
  disputes: ['id', 'match_id', 'raised_by_team', 'resolved_by'],
  elo_history: ['id', 'team_id', 'match_id'],
  tournaments: ['id', 'owner_id', 'venue_id'],
  tournament_teams: ['id', 'tournament_id', 'team_id'],
  fixtures: ['id', 'tournament_id', 'team_a', 'team_b', 'winner'],
  chat_channels: ['id', 'ref_id'],
  chat_messages: ['id', 'channel_id', 'sender_id'],
};

// Columns added to pre-existing tables → expected data_type.
const NEW_COLUMNS = {
  teams: { elo: 'integer', visibility: 'text', bio: 'text', logo_url: 'text',
           wins: 'integer', losses: 'integer', draws: 'integer' },
  reviews: { review_type: 'text', sentiment_label: 'text',
             sentiment_score: 'numeric', flagged: 'boolean', hidden: 'boolean' },
  player_profiles: { trust_rating: 'numeric', trust_attendance: 'numeric',
                     trust_disputes: 'numeric', trust_sentiment: 'numeric' },
  venues: { booking_window_days: 'integer' },
  users: { fcm_token: 'text' },
  notifications: { payload: 'jsonb' },
};

// The two deliberate omissions. Asserted absent so a later "helpful" migration
// that re-adds them fails this check loudly instead of quietly forking the flag.
const MUST_NOT_EXIST = [
  ['users', 'suspended'],       // is_active is the suspension flag (auth.js:164)
  ['notifications', 'read'],    // is_read is the read flag (010:52)
];

const EXPECTED_INDEXES = [
  'idx_team_invites_team', 'idx_matches_challenger', 'idx_matches_opponent',
  'idx_matches_booking', 'idx_disputes_match', 'idx_disputes_status',
  'idx_elo_history_team', 'idx_elo_history_match', 'idx_tournaments_status',
  'idx_tournaments_venue', 'idx_tournament_teams_team', 'idx_fixtures_tournament',
  'idx_chat_messages_channel', 'idx_chat_channels_ref',
];

// FKs the spec omitted and this migration adds back (winner_team on both).
const EXPECTED_FKS = [
  ['matches', 'winner_team'],
  ['match_results', 'winner_team'],
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
  const sqlFile = path.join(__dirname, 'migrations', '013_fyp2_foundation.sql');
  const sql = fs.readFileSync(sqlFile, 'utf8');

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
      console.error('❌ Cannot apply migration 013 — prerequisite tables missing:');
      console.error(`   ${missingPrereqs.join(', ')}`);
      console.error('');
      console.error('   013 extends these tables rather than redefining them.');
      console.error('   Apply schema.sql and then node run_migration_010.js first.');
      client.release();
      await pool.end();
      process.exit(1);
    }
    console.log(`Pre-flight: ${before.length} tables present, all prerequisites found.`);
    const alreadyThere = NEW_TABLES.filter((t) => before.includes(t));
    if (alreadyThere.length) {
      console.log(`   (re-run — already present: ${alreadyThere.join(', ')})`);
    }
    console.log('');

    // Apply
    await client.query(sql);
    console.log('Migration 013 applied. Verifying:');
    console.log('');

    // 1. Tables
    const after = await tableNames(client);
    const missing = NEW_TABLES.filter((t) => !after.includes(t));
    check(missing.length === 0,
      `all ${NEW_TABLES.length} new tables exist${missing.length ? ` — MISSING: ${missing.join(', ')}` : ''}`);

    // 2. Column types (the uuid-vs-int assertion)
    const { rows: cols } = await client.query(
      `SELECT table_name, column_name, data_type
         FROM information_schema.columns
        WHERE table_schema = 'public'`,
    );
    const typeOf = new Map(
      cols.map((r) => [`${r.table_name}.${r.column_name}`, r.data_type]),
    );

    const badUuid = [];
    for (const [table, columns] of Object.entries(MUST_BE_UUID)) {
      for (const col of columns) {
        const t = typeOf.get(`${table}.${col}`);
        if (t !== 'uuid') badUuid.push(`${table}.${col} is ${t || 'MISSING'}`);
      }
    }
    const uuidCount = Object.values(MUST_BE_UUID).reduce((n, c) => n + c.length, 0);
    check(badUuid.length === 0,
      `all ${uuidCount} key columns are uuid${badUuid.length ? ` — WRONG: ${badUuid.join('; ')}` : ''}`);

    const badCol = [];
    for (const [table, columns] of Object.entries(NEW_COLUMNS)) {
      for (const [col, want] of Object.entries(columns)) {
        const t = typeOf.get(`${table}.${col}`);
        if (t !== want) badCol.push(`${table}.${col} is ${t || 'MISSING'}, want ${want}`);
      }
    }
    check(badCol.length === 0,
      `added columns on existing tables correct${badCol.length ? ` — WRONG: ${badCol.join('; ')}` : ''}`);

    const leaked = MUST_NOT_EXIST.filter(([t, c]) => typeOf.has(`${t}.${c}`));
    check(leaked.length === 0,
      `duplicate flags absent (users.suspended, notifications.read)${leaked.length ? ` — PRESENT: ${leaked.map((p) => p.join('.')).join(', ')}` : ''}`);

    // 3. The FKs the spec omitted
    const { rows: fkRows } = await client.query(
      `SELECT tc.table_name, kcu.column_name
         FROM information_schema.table_constraints tc
         JOIN information_schema.key_column_usage kcu
           ON kcu.constraint_name = tc.constraint_name
          AND kcu.table_schema    = tc.table_schema
        WHERE tc.constraint_type = 'FOREIGN KEY'
          AND tc.table_schema    = 'public'`,
    );
    const fks = new Set(fkRows.map((r) => `${r.table_name}.${r.column_name}`));
    const missingFks = EXPECTED_FKS
      .map(([t, c]) => `${t}.${c}`)
      .filter((k) => !fks.has(k));
    check(missingFks.length === 0,
      `winner_team FKs present${missingFks.length ? ` — MISSING: ${missingFks.join(', ')}` : ''}`);

    // 4. Teams backfill
    // Guarded on the legacy columns still existing, exactly as the migration's
    // own do block is — a database built from migrations alone may not have them.
    const hasEloRating = typeOf.has('teams.elo_rating');
    const hasIsPublic = typeOf.has('teams.is_public');
    const { rows: [teamCounts] } = await client.query(
      `SELECT COUNT(*)::int AS total,
              ${hasEloRating ? `COUNT(*) FILTER (
                WHERE elo_rating IS NOT NULL
                  AND elo <> ROUND(elo_rating)::int
              )::int` : '0'} AS elo_drift,
              ${hasIsPublic ? `COUNT(*) FILTER (
                WHERE is_public IS FALSE AND visibility <> 'private'
              )::int` : '0'} AS vis_drift
         FROM teams`,
    );
    check(teamCounts.elo_drift === 0,
      hasEloRating
        ? `teams.elo matches legacy elo_rating on all ${teamCounts.total} row(s)`
        : `teams.elo present (no legacy elo_rating to reconcile, ${teamCounts.total} row(s))`);
    check(teamCounts.vis_drift === 0,
      hasIsPublic
        ? 'teams.visibility matches legacy is_public'
        : 'teams.visibility present (no legacy is_public to reconcile)');

    // 5. global_settings seed
    const { rows: settings } = await client.query(
      'SELECT key FROM global_settings ORDER BY key',
    );
    const seeded = settings.map((r) => r.key);
    const wantSeed = ['commission_pct', 'deposit_pct', 'elo', 'sports_enabled'];
    const missingSeed = wantSeed.filter((k) => !seeded.includes(k));
    check(missingSeed.length === 0,
      `global_settings seeded (${seeded.join(', ')})${missingSeed.length ? ` — MISSING: ${missingSeed.join(', ')}` : ''}`);

    // 6. Indexes
    const { rows: idxRows } = await client.query(
      `SELECT indexname FROM pg_indexes WHERE schemaname = 'public'`,
    );
    const idx = new Set(idxRows.map((r) => r.indexname));
    const missingIdx = EXPECTED_INDEXES.filter((n) => !idx.has(n));
    check(missingIdx.length === 0,
      `all ${EXPECTED_INDEXES.length} new indexes exist${missingIdx.length ? ` — MISSING: ${missingIdx.join(', ')}` : ''}`);

    // Listing (the \dt the accept criterion asked for)
    console.log('');
    const created = after.filter((t) => !before.includes(t));
    console.log(`Tables now in public (${after.length}):`);
    for (const t of after) {
      const mark = created.includes(t) ? '+' : ' ';
      console.log(`   ${mark} ${t}`);
    }
    console.log('');
    console.log(created.length
      ? `Created this run: ${created.join(', ')}`
      : 'Created this run: none (idempotent re-run).');
  } catch (e) {
    failures.push(`migration threw: ${e.message}`);
    console.error('');
    console.error('❌ Migration 013 failed:', e.message);
    if (e.detail) console.error('   detail:', e.detail);
    if (e.hint) console.error('   hint:', e.hint);
  } finally {
    client.release();
    await pool.end();
  }

  console.log('');
  if (failures.length) {
    console.error(`❌ Migration 013: ${failures.length} check(s) failed.`);
  } else {
    console.log('✅ Migration 013 verified — schema ready for S.2 → S.7.');
  }
  process.exit(failures.length ? 1 : 0);
}

run();
