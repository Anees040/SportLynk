/**
 * Runner for migrations/021_dispute_ruling_labels.sql
 * Usage: node run_migration_021.js
 *
 * Not yet applied. 019 and 020 were applied with the user's go-ahead; 021 was
 * written afterwards, needs its own, and is listed as a manual step. Everything
 * in Wave D works without it EXCEPT one branch - see what needs this, below.
 *
 * 021 widens two label vocabularies. It is small, but it is the kind of small
 * that fails at runtime rather than at apply time, so both halves are probed with
 * the real statements the application will run:
 *
 *   1. chk_elo_history_reason must accept 'admin_reversal' and 'admin_ruling'
 *      And still reject a typo. A CHECK widened to "reason IS NOT NULL" would
 *      pass a "does it accept the new label" test and quietly accept anything.
 *   2. txn_type must contain 'platform_commission' and accept it in an INSERT.
 *      The label existing in pg_enum is not the same fact as a transaction
 *      writing with it: an ADD VALUE inside the same transaction that uses it
 *      raises 55P04, which is exactly what the split marker is there to avoid.
 *
 * Both probes write rows and are always rolled back - this runs against the
 * shared Supabase database and must leave nothing behind.
 *
 * What needs this
 *   - A dispute ruling that flips an already-rated match (elo_applied = true),
 *     which is only reachable when the dispute was filed against a COMPLETED
 *     match. disputeService checks for the labels first and refuses with a
 *     message naming this file rather than raising a 23514 mid-transaction.
 *   - The commission_pct deduction at check-in, whose ledger row needs the
 *     platform_commission label. commission_pct defaults to 0, so until an
 *     admin changes it nothing is deducted and nothing is written either way.
 *
 * What this migration deliberately does not do
 * There are 24 naive `timestamp` columns left in the schema (bookings.created_at,
 * transactions.created_at, users.created_at, ...). 020 converted `notifications`
 * because a feed renders "2 hours ago" from it; converting the other twelve
 * tables is a sweeping change no wave has asked for, and their values are already
 * UTC because every session is. Wave D's financial export therefore ranges over
 * `bookings.slot_date` - a true date holding PKT wall-clock - instead of over a
 * naive timestamp, which makes "August" mean the same thing to the owner and to
 * Postgres without touching a single column.
 *
 * Safe to re-run: the CHECK is dropped and recreated inside a guarded do block,
 * and ADD VALUE uses IF NOT EXISTS.
 */
const fs = require('fs');
const path = require('path');
const pool = require('./src/db/pool');

/** The marker, assembled so this source file never contains a literal one. */
const SPLIT_MARKER = `-- @@${'SPLIT'}@@`;

const NEW_ELO_REASONS = ['admin_reversal', 'admin_ruling'];
const KEPT_ELO_REASONS = ['match_verified', 'frozen_no_change'];
const NEW_TXN_LABEL = 'platform_commission';

async function run() {
  const sqlFile = path.join(__dirname, 'migrations', '021_dispute_ruling_labels.sql');
  const chunks = fs.readFileSync(sqlFile, 'utf8')
    .split(SPLIT_MARKER)
    .map((c) => c.trim())
    .filter((c) => c.length > 0);

  const client = await pool.connect();
  const failures = [];
  const check = (ok, label) => {
    if (ok) console.log(`   OK  ${label}`);
    else { failures.push(label); console.log(`   BAD ${label}`); }
  };

  try {
    console.log('\n--- Pre-flight -------------------------------------------');
    const { rows: pre } = await client.query(
      `SELECT
         (SELECT count(*)::int FROM pg_constraint
           WHERE conrelid = 'public.elo_history'::regclass
             AND conname = 'chk_elo_history_reason') AS has_check,
         (SELECT count(*)::int FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
           WHERE t.typname = 'txn_type') AS txn_labels,
         (SELECT count(*)::int FROM elo_history) AS history_rows`,
    );
    console.log(`   elo_history rows: ${pre[0].history_rows}`);
    console.log(`   txn_type labels before: ${pre[0].txn_labels}`);
    if (!pre[0].has_check) {
      console.log('   ! chk_elo_history_reason absent - 021 will create it');
    }

    console.log(`\n--- Applying 021 (${chunks.length} chunks) ----------------------`);
    for (let i = 0; i < chunks.length; i += 1) {
      await client.query(chunks[i]);
      console.log(`   OK  chunk ${i + 1}/${chunks.length} applied`);
    }

    console.log('\n--- Census -----------------------------------------------');
    const { rows: [def] } = await client.query(
      `SELECT pg_get_constraintdef(oid) AS d FROM pg_constraint
        WHERE conrelid = 'public.elo_history'::regclass
          AND conname = 'chk_elo_history_reason'`,
    );
    check(Boolean(def), 'chk_elo_history_reason exists');
    for (const r of [...KEPT_ELO_REASONS, ...NEW_ELO_REASONS]) {
      check(Boolean(def) && def.d.includes(`'${r}'`), `CHECK names ${r}`);
    }

    const { rows: labels } = await client.query(
      `SELECT enumlabel FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
        WHERE t.typname = 'txn_type' ORDER BY e.enumsortorder`,
    );
    const have = labels.map((l) => l.enumlabel);
    check(have.includes(NEW_TXN_LABEL), `txn_type includes ${NEW_TXN_LABEL}`);
    check(have.includes('tournament_commission'),
      'txn_type still includes tournament_commission (nothing replaced)');
    console.log(`   txn_type is now: ${have.join(' | ')}`);

    console.log('\n--- Probes (all rolled back) -----------------------------');
    await client.query('BEGIN');

    // elo_history.team_id and .match_id are both nullable, so a label probe needs
    // no team and no match - which keeps this from depending on seed data.
    for (const r of [...KEPT_ELO_REASONS, ...NEW_ELO_REASONS]) {
      try {
        await client.query(
          `INSERT INTO elo_history (team_id, match_id, elo_before, elo_after, elo_delta, k_factor, reason)
           VALUES (NULL, NULL, 1000, 1016, 16, 32, $1)`,
          [r],
        );
        check(true, `elo_history accepts reason ${r}`);
      } catch (e) {
        check(false, `elo_history accepts reason ${r} (${e.code} ${e.message})`);
      }
    }

    // The half that matters more: a widened CHECK must still be a CHECK.
    await client.query('SAVEPOINT p_bad');
    try {
      await client.query(
        `INSERT INTO elo_history (elo_before, elo_after, elo_delta, reason)
         VALUES (1000, 1000, 0, 'admin_rulling')`,
      );
      await client.query('ROLLBACK TO SAVEPOINT p_bad');
      check(false, 'elo_history still REJECTS a typo (admin_rulling)');
    } catch (e) {
      await client.query('ROLLBACK TO SAVEPOINT p_bad');
      check(e.code === '23514', 'elo_history still REJECTS a typo (admin_rulling)');
    }

    // The enum label in an actual INSERT. Uses the platform's own shape: a
    // zero amount against no wallet, which is all the type system cares about.
    try {
      await client.query(
        `INSERT INTO transactions (wallet_id, user_id, booking_id, type, amount, description)
         VALUES (NULL, NULL, NULL, $1, 0, 'migration 021 probe')`,
        [NEW_TXN_LABEL],
      );
      check(true, `transactions accepts type ${NEW_TXN_LABEL}`);
    } catch (e) {
      check(false, `transactions accepts type ${NEW_TXN_LABEL} (${e.code} ${e.message})`);
    }

    await client.query('ROLLBACK');
    const { rows: [after] } = await client.query(
      `SELECT (SELECT count(*)::int FROM elo_history) AS h,
              (SELECT count(*)::int FROM transactions WHERE description = 'migration 021 probe') AS t`,
    );
    check(after.h === pre[0].history_rows, `elo_history unchanged (${after.h} rows)`);
    check(after.t === 0, 'no probe transaction left behind');

    console.log('\n--- Result -----------------------------------------------');
    if (failures.length) {
      console.log(`FAILED: 021 applied but ${failures.length} check(s) failed:`);
      failures.forEach((f) => console.log(`   - ${f}`));
    } else {
      console.log('OK: Migration 021 applied and verified.');
      console.log('   elo_history.reason: match_verified | frozen_no_change | admin_reversal | admin_ruling');
      console.log(`   txn_type: +${NEW_TXN_LABEL} (commission_pct still defaults to 0 - no number moved)`);
    }
    client.release();
    await pool.end();
    process.exit(failures.length ? 1 : 0);
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    console.error(`\nMigration 021 failed: ${e.code || ''} ${e.message}`);
    if (e.detail) console.error(`   detail: ${e.detail}`);
    client.release();
    await pool.end();
    process.exit(1);
  }
}

run();
