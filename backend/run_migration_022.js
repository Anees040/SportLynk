/**
 * Runner for migrations/022_elo_history_correction.sql
 * Usage: node run_migration_022.js
 *
 * 022 replaces one unique index. That is a small change with a sharp edge, so the
 * probes here are all about the edge rather than the object:
 *
 *   1. The rows 021's labels describe must now be WRITEABLE. Before 022 a reversal
 *      and a ruling for the same (team, match) raised 23505 and aborted the whole
 *      dispute-ruling transaction. This is the failure 022 exists to remove, so it
 *      is asserted directly: three rows, three reasons, one team, one match.
 *   2. A second VERIFICATION must still collide. If it does not, 022 has bought the
 *      correction by deleting the guard, which would be a worse database than the
 *      one it started from. The probe asserts the 23505 AND that the violation
 *      names the new index, because that name is what routes/matches.js turns into
 *      "This match has already been rated."
 *   3. Two reason-less rows must still collide. `reason` is nullable and NULL never
 *      equals NULL in a unique index, so the key folds NULL with COALESCE; without
 *      that, a three-column key would be no guard at all for a writer that omits a
 *      reason. This is the probe that proves the COALESCE is load-bearing.
 *
 * Every probe writes rows and is ALWAYS rolled back — this runs against the shared
 * Supabase database and must leave nothing behind.
 *
 * WHAT NEEDS THIS
 *   `services/disputeService.rule()` with `action: 'rule_challenger'` (or opponent,
 *   or custom) against a match whose `elo_applied` is already true — the overturn
 *   branch, reachable because POST /api/matches/:id/dispute may be filed against a
 *   COMPLETED match. `elo.correctResult` writes up to four history rows there.
 *   Without 022 that transaction dies on the index; with it, the ruling lands and
 *   the audit trail reads reversal-then-ruling per team.
 *
 * THE END-TO-END PROOF IS NOT HERE. `src/scripts/check_admin.js` Block 5 rules a
 * real disputed match through the real service and asserts the four rows, their
 * reasons, and that the ladder still sums to the same total. This runner only
 * proves the schema will let that happen.
 *
 * Safe to re-run: the DROP is guarded by an information-schema check and the
 * CREATE is IF NOT EXISTS.
 */
const fs = require('fs');
const path = require('path');
const pool = require('./src/db/pool');

/** The marker, assembled so this source file never contains a literal one. */
const SPLIT_MARKER = `-- @@${'SPLIT'}@@`;

const OLD_INDEX = 'ux_elo_history_team_match';
const NEW_INDEX = 'ux_elo_history_team_match_reason';

async function run() {
  const sqlFile = path.join(__dirname, 'migrations', '022_elo_history_correction.sql');
  const chunks = fs.readFileSync(sqlFile, 'utf8')
    .split(SPLIT_MARKER)
    .map((c) => c.trim())
    .filter((c) => c.length > 0);

  const client = await pool.connect();
  const failures = [];
  const skipped = [];
  const check = (ok, label) => {
    if (ok) console.log(`   OK  ${label}`);
    else { failures.push(label); console.log(`   BAD ${label}`); }
  };
  const skip = (label, why) => { skipped.push(label); console.log(`   --  ${label} (${why})`); };

  try {
    console.log('\n--- Pre-flight -------------------------------------------');
    const { rows: [pre] } = await client.query(
      `SELECT (SELECT count(*)::int FROM elo_history)                       AS history_rows,
              (SELECT count(*)::int FROM pg_indexes
                WHERE schemaname='public' AND indexname=$1)                 AS has_old,
              (SELECT count(*)::int FROM pg_indexes
                WHERE schemaname='public' AND indexname=$2)                 AS has_new`,
      [OLD_INDEX, NEW_INDEX],
    );
    console.log(`   elo_history rows: ${pre.history_rows}`);
    console.log(`   ${OLD_INDEX}: ${pre.has_old ? 'present (will be dropped)' : 'absent'}`);
    console.log(`   ${NEW_INDEX}: ${pre.has_new ? 'present (re-run)' : 'absent (will be created)'}`);

    // The one thing that can make the CREATE fail. Reported BEFORE applying, so a
    // failure reads as "these rows are the problem" instead of a bare 23505.
    const { rows: dupes } = await client.query(
      `SELECT team_id, match_id, COALESCE(reason, 'unspecified') AS reason, count(*)::int AS n
         FROM elo_history
        WHERE match_id IS NOT NULL
        GROUP BY 1, 2, 3
       HAVING count(*) > 1
        ORDER BY n DESC
        LIMIT 5`,
    );
    if (dupes.length) {
      console.log(`   ! ${dupes.length} duplicate (team, match, reason) group(s) already exist:`);
      for (const d of dupes) console.log(`     team ${d.team_id} match ${d.match_id} reason ${d.reason} ×${d.n}`);
      console.log('   ! the CREATE below will fail — investigate these rows first.');
    } else {
      console.log('   no duplicate (team, match, reason) groups — the new index can be built');
    }

    console.log(`\n--- Applying 022 (${chunks.length} chunk${chunks.length === 1 ? '' : 's'}) --------------------`);
    for (let i = 0; i < chunks.length; i += 1) {
      await client.query(chunks[i]);
      console.log(`   OK  chunk ${i + 1}/${chunks.length} applied`);
    }

    console.log('\n--- Census -----------------------------------------------');
    const { rows: idx } = await client.query(
      `SELECT indexname, indexdef FROM pg_indexes
        WHERE schemaname='public' AND tablename='elo_history' ORDER BY indexname`,
    );
    const byName = new Map(idx.map((r) => [r.indexname, r.indexdef]));
    check(!byName.has(OLD_INDEX), `${OLD_INDEX} is gone (superseded, not kept alongside)`);
    const def = byName.get(NEW_INDEX) || '';
    check(Boolean(def), `${NEW_INDEX} exists`);
    check(def.includes('UNIQUE'), `${NEW_INDEX} is UNIQUE (it is a guard, not a lookup)`);
    check(def.includes('team_id') && def.includes('match_id'),
      'its key still starts with (team_id, match_id) — the 016 guard is kept, not replaced');
    check(def.toLowerCase().includes('coalesce'),
      "its key folds a NULL reason (COALESCE) so two reason-less rows still collide");
    check(def.includes('match_id IS NOT NULL'),
      'and it is still PARTIAL — a history row with no match (a manual adjustment) is unconstrained');
    console.log(`   elo_history indexes: ${idx.map((r) => r.indexname).join(' | ')}`);

    // The name is not cosmetic: routes/matches.js switches on e.constraint to turn a
    // 23505 into "This match has already been rated." A rename with no matching edit
    // downgrades that to the generic "That has already been recorded."
    const routeSrc = fs.readFileSync(path.join(__dirname, 'src', 'routes', 'matches.js'), 'utf8');
    check(routeSrc.includes(`case '${NEW_INDEX}':`),
      `routes/matches.js maps ${NEW_INDEX} to a friendly 409`);
    check(!new RegExp(`case '${OLD_INDEX}':`).test(routeSrc),
      'and no longer switches on the retired name');

    const censusSrc = fs.readFileSync(path.join(__dirname, 'src', 'scripts', 'verify_schema.js'), 'utf8');
    check(censusSrc.includes(NEW_INDEX) && !censusSrc.includes(`'${OLD_INDEX}'`),
      'verify_schema.js censuses the new index and not the retired one');

    console.log('\n--- Probes (all rolled back) -----------------------------');
    // elo_history.team_id and .match_id are FK-bound, and the partial index only
    // covers rows WITH a match — so these probes need one real team and one real
    // match. They are read from whatever the database already holds and never
    // written to; if the table is empty the probes say so rather than inventing ids.
    const { rows: [seed] } = await client.query(
      `SELECT (SELECT id FROM matches ORDER BY created_at LIMIT 1)                     AS match_id,
              (SELECT challenger_team FROM matches ORDER BY created_at LIMIT 1)        AS team_id`,
    );

    await client.query('BEGIN');
    if (!seed || !seed.match_id || !seed.team_id) {
      skip('the reversal+ruling trio is writeable', 'no match rows to hang a probe on');
      skip('a second verification still collides', 'no match rows to hang a probe on');
      skip('two reason-less rows still collide', 'no match rows to hang a probe on');
    } else {
      const ins = (reason) => client.query(
        `INSERT INTO elo_history (team_id, match_id, elo_before, elo_after, elo_delta, k_factor, reason)
         VALUES ($1, $2, 1200, 1216, 16, 32, $3)`,
        [seed.team_id, seed.match_id, reason],
      );

      // 1. THE FAILURE 022 REMOVES. Before this migration the second of these three
      //    raised 23505 and took the ruling transaction with it.
      await client.query('SAVEPOINT p_trio');
      try {
        await ins('match_verified');
        await ins('admin_reversal');
        await ins('admin_ruling');
        check(true, 'one team, one match: match_verified + admin_reversal + admin_ruling all accepted');
      } catch (e) {
        check(false, `the reversal+ruling trio is writeable (${e.code} ${e.constraint || e.message})`);
      }

      // 2. THE GUARD 022 KEEPS. The trio above is still in the transaction, so this
      //    is a genuine second verification for a team that already has one.
      try {
        await ins('match_verified');
        check(false, 'a second match_verified for the same team+match still collides');
      } catch (e) {
        check(e.code === '23505' && e.constraint === NEW_INDEX,
          `a second match_verified for the same team+match still collides (${e.code} ${e.constraint})`);
      }
      await client.query('ROLLBACK TO SAVEPOINT p_trio');

      // 3. THE COALESCE. Two rows that both omit a reason: without the fold, NULL
      //    never equals NULL and both would be accepted for the same team+match.
      await client.query('SAVEPOINT p_null');
      try {
        await ins(null);
        await ins(null);
        check(false, 'two reason-less rows for the same team+match still collide');
      } catch (e) {
        check(e.code === '23505' && e.constraint === NEW_INDEX,
          `two reason-less rows for the same team+match still collide (${e.code} ${e.constraint})`);
      }
      await client.query('ROLLBACK TO SAVEPOINT p_null');

      // 4. And a row with NO match is still outside the guard entirely — that is what
      //    the partial predicate is for, and 021's own probes rely on it.
      await client.query('SAVEPOINT p_nomatch');
      try {
        await client.query(
          `INSERT INTO elo_history (team_id, match_id, elo_before, elo_after, elo_delta, k_factor, reason)
           VALUES ($1, NULL, 1200, 1200, 0, 32, 'admin_ruling'), ($1, NULL, 1200, 1200, 0, 32, 'admin_ruling')`,
          [seed.team_id],
        );
        check(true, 'two match-less rows are still allowed (the index is partial on purpose)');
      } catch (e) {
        check(false, `two match-less rows are still allowed (${e.code} ${e.constraint || e.message})`);
      }
      await client.query('ROLLBACK TO SAVEPOINT p_nomatch');
    }

    await client.query('ROLLBACK');
    const { rows: [after] } = await client.query('SELECT count(*)::int AS n FROM elo_history');
    check(after.n === pre.history_rows, `elo_history unchanged (${after.n} rows)`);

    console.log('\n--- Result -----------------------------------------------');
    if (failures.length) {
      console.log(`FAILED: 022 applied but ${failures.length} check(s) failed:`);
      failures.forEach((f) => console.log(`   - ${f}`));
    } else {
      console.log('OK: Migration 022 applied and verified.');
      console.log(`   ${OLD_INDEX} → ${NEW_INDEX}`);
      console.log('   one rating row per team per match PER REASON:');
      console.log('     a second verification still collides; a correction may write reversal + ruling');
      console.log('   next: node src/scripts/check_admin.js --evidence  (Block 5 is the end-to-end proof)');
      if (skipped.length) console.log(`   ${skipped.length} probe(s) skipped for want of seed data`);
    }
    client.release();
    await pool.end();
    process.exit(failures.length ? 1 : 0);
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    console.error(`\nMigration 022 failed: ${e.code || ''} ${e.message}`);
    if (e.detail) console.error(`   detail: ${e.detail}`);
    client.release();
    await pool.end();
    process.exit(1);
  }
}

run();
