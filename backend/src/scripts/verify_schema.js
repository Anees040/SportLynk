/**
 * verify_schema.js — prove the database has every object the code expects.
 *
 * WHY THIS EXISTS
 * ---------------
 * There is no migration-tracking table in this project: migrations are applied by
 * hand-run runner scripts (run_migration_0XX.js), and nothing records that they
 * ran. So "is my database up to date?" cannot be answered by reading a version
 * number — it can only be answered by checking whether the objects each migration
 * creates are actually present.
 *
 * That is what this script does. It is READ-ONLY: it creates nothing, changes
 * nothing, and is safe to run against the demo database at any time.
 *
 * THERE IS ONLY ONE DATABASE
 * --------------------------
 * Supabase is it, for development and for the demo (see doc/claude.md). There is
 * no separate local Postgres to keep in sync, so a passing run here means the one
 * database every environment uses is current. The script prints the host it
 * checked, with credentials masked, so a run against the wrong URL is obvious
 * rather than silent — .env has historically carried a stale localhost line.
 *
 * WHAT IT CHECKS
 * --------------
 * Per migration: tables, named indexes, named constraints, and the specific
 * columns the application code reads. Named indexes and constraints are the
 * highest-signal evidence — `chk_matches_status` existing means 016 ran, and its
 * name is unique database-wide, so no table pairing is needed to look it up.
 *
 * Columns are listed explicitly rather than derived from the .sql files, because
 * the point is to check what the CODE depends on. A column a migration adds but
 * nothing reads is not worth failing a deploy over; a column routes/matches.js
 * selects on every request is.
 *
 * EXIT CODE
 * ---------
 * 0 when everything expected is present, 1 when anything is missing — so it can
 * gate a deploy or a demo. Missing objects are printed with the migration that
 * creates them, which is the file you then need to run.
 *
 * USAGE
 * -----
 *   node src/scripts/verify_schema.js
 *   node src/scripts/verify_schema.js --verbose   # list every passing object too
 */

const pool = require('../db/pool');

const verbose = process.argv.includes('--verbose');

/**
 * Expected objects, grouped by the migration that creates them.
 *
 * Only migrations 013 onward are listed. Everything before that predates the
 * FYP-2 sprint and is proven present by the app running at all — the server
 * cannot serve a booking without `bookings`.
 */
const EXPECTED = [
  {
    migration: '013_fyp2_foundation.sql',
    tables: ['team_invites', 'team_join_requests', 'matches', 'match_results',
      'disputes', 'elo_history', 'tournaments', 'tournament_teams', 'fixtures',
      'chat_channels', 'chat_messages', 'global_settings'],
    // idx_chat_channels_ref is NOT listed: 013 creates it and 015 line 242 drops
    // it, replacing it with the unique partial ux_chat_channels_type_ref. Its
    // absence on an up-to-date database is correct, so expecting it would make
    // this script report a false failure forever.
    indexes: ['idx_matches_booking', 'idx_matches_challenger', 'idx_matches_opponent',
      'idx_elo_history_team', 'idx_elo_history_match', 'idx_disputes_match',
      'idx_disputes_status', 'idx_chat_messages_channel',
      'idx_team_invites_team', 'idx_tournaments_status', 'idx_tournaments_venue',
      'idx_tournament_teams_team', 'idx_fixtures_tournament'],
    // The ER2.1 one-submission-per-team rule. 013 declares it as an inline
    // UNIQUE (match_id, submitted_by_team) table constraint, so Postgres names it
    // rather than the migration — and that generated name is what
    // routes/matches.js:100 keys its 409 on. Checked here under its real name so
    // a rename would be caught by this script rather than by a 500 in production.
    constraints: ['match_results_match_id_submitted_by_team_key'],
    columns: [
      ['teams', 'elo'], ['teams', 'wins'], ['teams', 'losses'], ['teams', 'draws'],
      ['teams', 'visibility'], ['teams', 'logo_url'], ['teams', 'bio'],
      ['reviews', 'sentiment_score'], ['reviews', 'sentiment_label'],
      ['reviews', 'review_type'], ['reviews', 'flagged'], ['reviews', 'hidden'],
      ['player_profiles', 'trust_attendance'], ['player_profiles', 'trust_disputes'],
      ['player_profiles', 'trust_rating'], ['player_profiles', 'trust_sentiment'],
      ['venues', 'booking_window_days'], ['users', 'fcm_token'],
      ['notifications', 'payload'],
    ],
  },
  {
    migration: '014_withdrawals.sql',
    tables: ['withdrawals'],
    indexes: ['uq_withdrawals_one_pending', 'idx_withdrawals_user', 'idx_withdrawals_pending'],
    constraints: [],
    columns: [],
  },
  {
    migration: '015_teams_chat.sql',
    tables: ['chat_channel_members', 'chat_reactions'],
    indexes: ['ux_teams_name_sport', 'ux_chat_channels_type_ref', 'ux_chat_messages_client',
      'ux_team_invites_token_hash', 'idx_team_members_user', 'idx_chat_members_user_active',
      'idx_chat_messages_media', 'idx_join_requests_team_status', 'idx_teams_sport_elo',
      'idx_teams_visibility_sport'],
    constraints: ['chk_team_members_role', 'chk_chat_channels_type',
      'chk_chat_messages_kind', 'chk_chat_messages_payload', 'chk_join_requests_status'],
    columns: [
      ['users', 'last_seen_at'],
      ['team_invites', 'token_hash'], ['team_invites', 'token_prefix'],
      ['team_invites', 'used_at'], ['team_invites', 'revoked_at'],
      ['chat_messages', 'kind'], ['chat_messages', 'media_url'],
      ['chat_messages', 'media_mime'], ['chat_messages', 'waveform'],
      ['chat_messages', 'duration_ms'], ['chat_messages', 'reply_to_id'],
      ['chat_messages', 'client_id'], ['chat_messages', 'deleted_at'],
      ['chat_messages', 'edited_at'], ['chat_messages', 'system_meta'],
      ['chat_channels', 'last_message_at'], ['chat_channels', 'last_message_preview'],
      ['chat_channels', 'last_message_sender_id'], ['chat_channels', 'message_count'],
    ],
  },
  {
    migration: '016_matches_elo.sql',
    tables: [],
    indexes: ['ux_matches_booking_live', 'ux_elo_history_team_match',
      'ux_disputes_match_team', 'idx_matches_expiry', 'idx_matches_awaiting_owner',
      'idx_disputes_raised_by', 'idx_teams_elo_frozen'],
    constraints: ['chk_matches_status', 'chk_matches_distinct_teams',
      'chk_matches_scores_nonneg', 'chk_matches_competitiveness',
      'chk_match_results_scores', 'chk_elo_history_reason', 'chk_disputes_status'],
    columns: [
      ['matches', 'competitiveness'], ['matches', 'preview_text'],
      ['matches', 'elo_applied'], ['matches', 'results_locked'],
      ['matches', 'created_by'], ['matches', 'responded_at'], ['matches', 'updated_at'],
      ['teams', 'elo_frozen'], ['teams', 'elo_frozen_reason'], ['teams', 'elo_frozen_at'],
      ['elo_history', 'k_factor'], ['elo_history', 'elo_delta'], ['elo_history', 'reason'],
      ['disputes', 'resolved_at'],
    ],
  },
  {
    migration: '019_tournaments.sql',
    // No new tables: 013 already created tournaments, tournament_teams and
    // fixtures as bare shells. 019 is the migration that makes them usable, so
    // its evidence is entirely columns, constraints and indexes.
    tables: [],
    // The four tournament indexes 013 already made (idx_tournaments_status,
    // idx_tournaments_venue, idx_tournament_teams_team, idx_fixtures_tournament)
    // are listed under 013 above and deliberately NOT repeated here — 019 does
    // not create them, and CREATE INDEX IF NOT EXISTS matches on the name, so a
    // second entry over different columns would have silently no-opped.
    indexes: ['uq_fixtures_slot_id', 'idx_fixtures_match', 'idx_fixtures_sched',
      'idx_matches_tournament', 'idx_transactions_tournament',
      'idx_tournaments_due', 'idx_tournaments_owner'],
    // Every CHECK 019 adds, plus the one UNIQUE. These are the highest-signal
    // objects in the whole file: chk_tournaments_max_teams is the power-of-2
    // knockout rule, chk_fixtures_bye is "a bye has exactly one team", and
    // chk_matches_one_context is "a match belongs to a booking or a tournament,
    // never both" — the invariants tournamentService relies on rather than
    // re-checks.
    constraints: ['chk_tournaments_status', 'chk_tournaments_format',
      'chk_tournaments_max_teams', 'chk_tournaments_min_teams',
      'chk_tournaments_percents', 'chk_tournaments_money_nonneg',
      'chk_tournament_teams_status', 'chk_tournament_teams_paid',
      'chk_fixtures_status', 'chk_fixtures_coords', 'chk_fixtures_distinct_teams',
      'chk_fixtures_bye', 'chk_fixtures_scores', 'chk_teams_tournament_counters',
      'chk_matches_one_context', 'uq_fixtures_slot'],
    // The columns the application code actually reads or writes. The four money
    // columns on tournaments are the stored waterfall (pool = venue_cost + prize
    // + owner margin), fixtures.slot_id is the slot reservation that replaces a
    // bookings row, and the teams counters are the tournament record shown on the
    // team card in place of a second ELO ladder.
    columns: [
      ['tournaments', 'description'], ['tournaments', 'min_teams'],
      ['tournaments', 'requires_approval'], ['tournaments', 'prize_percent'],
      ['tournaments', 'winner_percent'], ['tournaments', 'runnerup_percent'],
      ['tournaments', 'venue_discount_percent'], ['tournaments', 'slot_minutes'],
      ['tournaments', 'rounds'], ['tournaments', 'winner_team'],
      ['tournaments', 'runner_up_team'], ['tournaments', 'pool_amount'],
      ['tournaments', 'venue_cost_amount'], ['tournaments', 'prize_amount'],
      ['tournaments', 'owner_earning_amount'],
      ['tournaments', 'fixtures_generated_at'], ['tournaments', 'activated_at'],
      ['tournaments', 'completed_at'], ['tournaments', 'cancelled_at'],
      ['tournaments', 'cancel_reason'],
      ['tournament_teams', 'seed'], ['tournament_teams', 'paid_amount'],
      ['tournament_teams', 'approved_at'], ['tournament_teams', 'withdrawn_at'],
      ['tournament_teams', 'eliminated_round'],
      ['fixtures', 'match_id'], ['fixtures', 'slot_id'],
      ['fixtures', 'scheduled_at'], ['fixtures', 'label'], ['fixtures', 'is_bye'],
      ['fixtures', 'next_round'], ['fixtures', 'next_position'],
      ['teams', 'tournament_played'], ['teams', 'tournament_wins'],
      ['teams', 'finals_reached'], ['teams', 'titles'],
      ['matches', 'tournament_id'], ['transactions', 'tournament_id'],
    ],
  },
];

async function main() {
  const url = process.env.DATABASE_URL || '(unset)';
  console.log('\nDatabase:', url.replace(/\/\/[^:]*:[^@]*@/, '//***:***@'));

  const [tables, indexes, constraints, columns] = await Promise.all([
    pool.query("SELECT table_name n FROM information_schema.tables WHERE table_schema='public'"),
    pool.query("SELECT indexname n FROM pg_indexes WHERE schemaname='public'"),
    pool.query(`SELECT c.conname n FROM pg_constraint c
                  JOIN pg_namespace ns ON ns.oid = c.connamespace WHERE ns.nspname='public'`),
    pool.query(`SELECT table_name t, column_name c FROM information_schema.columns
                 WHERE table_schema='public'`),
  ]);

  const haveTable = new Set(tables.rows.map((r) => r.n));
  const haveIndex = new Set(indexes.rows.map((r) => r.n));
  const haveConstraint = new Set(constraints.rows.map((r) => r.n));
  const haveColumn = new Set(columns.rows.map((r) => `${r.t}.${r.c}`));

  let pass = 0;
  const missing = [];

  for (const m of EXPECTED) {
    const local = [];
    const note = (kind, name, ok) => {
      if (ok) { pass += 1; if (verbose) local.push(`   ok    ${kind} ${name}`); }
      else { local.push(`   MISS  ${kind} ${name}`); missing.push({ m: m.migration, kind, name }); }
    };

    for (const t of m.tables) note('table     ', t, haveTable.has(t));
    for (const i of m.indexes) note('index     ', i, haveIndex.has(i));
    for (const c of m.constraints) note('constraint', c, haveConstraint.has(c));
    for (const [t, c] of m.columns) note('column    ', `${t}.${c}`, haveColumn.has(`${t}.${c}`));

    const total = m.tables.length + m.indexes.length + m.constraints.length + m.columns.length;
    const miss = local.filter((l) => l.includes('MISS')).length;
    const badge = miss === 0 ? 'APPLIED' : `${miss} MISSING`;
    console.log(`\n${m.migration.padEnd(28)} ${String(total - miss)}/${total}  ${badge}`);
    for (const line of local) console.log(line);
  }

  console.log(`\n${'-'.repeat(60)}`);
  if (!missing.length) {
    console.log(`${pass}/${pass} objects present — schema is up to date.`);
    console.log('Nothing to run in the Supabase SQL editor.\n');
    return;
  }

  console.log(`${missing.length} object(s) missing.\n`);
  const byMigration = new Map();
  for (const x of missing) {
    if (!byMigration.has(x.m)) byMigration.set(x.m, []);
    byMigration.get(x.m).push(`${x.kind.trim()} ${x.name}`);
  }
  for (const [mig, list] of byMigration) {
    console.log(`  ${mig}`);
    for (const l of list) console.log(`      ${l}`);
    const runner = mig.replace(/^(\d+)_.*$/, 'run_migration_$1.js');
    console.log(`    → node ${runner}\n`);
  }
  process.exitCode = 1;
}

main()
  .catch((e) => { console.error('\nFailed:', e.message, '\n'); process.exitCode = 1; })
  .finally(() => pool.end());
