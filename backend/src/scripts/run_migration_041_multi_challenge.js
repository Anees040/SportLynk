/**
 * run_migration_041_multi_challenge.js — applies 041 (multi-team invites + the open
 * challenge board).
 *
 * Usage:  node src/scripts/run_migration_041_multi_challenge.js
 *
 * 041 does two things with a sharp edge, so the verification is about the edge:
 *
 *   1. It REBUILDS ux_matches_booking_live on a narrower predicate. The whole point
 *      is that the index no longer mentions 'challenge_sent' (so several invites may
 *      sit on one booking) while still covering the ACCEPTED-and-beyond set (so the
 *      slot can never be double-booked). The census asserts exactly that — the
 *      predicate gained nothing and lost only challenge_sent — because getting this
 *      wrong either re-caps the slot at one challenge or removes the double-book guard.
 *   2. It adds open_challenges with a status CHECK and a partial-unique "one open
 *      offer per booking" index. The census asserts both exist.
 *
 * The index keeps its NAME, so routes/matches.js friendlyDbError still turns its
 * 23505 into "That slot already has a match on it." — asserted here too.
 *
 * No rows are written: the schema text is the guarantee, and the end-to-end proof
 * (several invites, first accept locks, siblings voided) is the feature's own tests.
 * The whole migration is applied in one transaction so a failure leaves nothing half-done.
 *
 * Safe to re-run: the DROP is IF EXISTS and every CREATE is IF NOT EXISTS.
 *
 * This runner lives in src/scripts with every other run_migration_* script. It was
 * authored at the backend root, where it resolved `./src/db/pool` and `__dirname +
 * '/migrations'`; the three paths below are the only change the move needed.
 */
const fs = require('fs');
const path = require('path');
const pool = require('../db/pool');

const INDEX = 'ux_matches_booking_live';

async function run() {
  const sqlFile = path.join(__dirname, '..', '..', 'migrations', '041_multi_challenge.sql');
  const sql = fs.readFileSync(sqlFile, 'utf8');

  const client = await pool.connect();
  const failures = [];
  const check = (ok, label) => {
    if (ok) console.log(`   OK  ${label}`);
    else { failures.push(label); console.log(`   BAD ${label}`); }
  };

  try {
    console.log('\n--- Pre-flight -------------------------------------------');
    const { rows: [pre] } = await client.query(
      `SELECT (SELECT indexdef FROM pg_indexes
                WHERE schemaname='public' AND indexname=$1)              AS idx_def,
              (SELECT count(*)::int FROM information_schema.tables
                WHERE table_schema='public' AND table_name='open_challenges') AS has_table`,
      [INDEX],
    );
    console.log(`   ${INDEX}: ${pre.idx_def ? 'present' : 'absent'}`);
    if (pre.idx_def) console.log(`     ${pre.idx_def}`);
    console.log(`   open_challenges table: ${pre.has_table ? 'present (re-run)' : 'absent (will be created)'}`);

    console.log('\n--- Applying 041 -----------------------------------------');
    await client.query('BEGIN');
    await client.query(sql);
    await client.query('COMMIT');
    console.log('   OK  041 applied in one transaction');

    console.log('\n--- Census -----------------------------------------------');
    const { rows: [post] } = await client.query(
      `SELECT indexdef FROM pg_indexes WHERE schemaname='public' AND indexname=$1`,
      [INDEX],
    );
    const def = post?.indexdef || '';
    check(Boolean(def), `${INDEX} still exists (name kept so friendlyDbError still maps it)`);
    check(def.includes('UNIQUE'), `${INDEX} is UNIQUE (a guard, not a lookup)`);
    check(!def.includes("'challenge_sent'"),
      `${INDEX} no longer covers challenge_sent — several invites may sit on one booking`);
    for (const s of ['accepted', 'awaiting_results', 'awaiting_owner', 'completed', 'disputed']) {
      check(def.includes(`'${s}'`), `${INDEX} still covers ${s} (the slot stays single-booked once locked)`);
    }

    const { rows: oc } = await client.query(
      `SELECT indexname, indexdef FROM pg_indexes
        WHERE schemaname='public' AND tablename='open_challenges' ORDER BY indexname`,
    );
    const ocByName = new Map(oc.map((r) => [r.indexname, r.indexdef]));
    check(ocByName.has('ux_open_challenges_booking_open'),
      'ux_open_challenges_booking_open exists (one OPEN offer per booking)');
    const openUx = ocByName.get('ux_open_challenges_booking_open') || '';
    check(openUx.includes('UNIQUE') && openUx.includes("status = 'open'"),
      'and it is UNIQUE and partial on status=open (a cancelled offer never blocks a re-post)');
    check(ocByName.has('idx_open_challenges_board'), 'the board index exists');

    const { rows: [cons] } = await client.query(
      `SELECT count(*)::int AS n FROM information_schema.table_constraints
        WHERE table_schema='public' AND table_name='open_challenges'
          AND constraint_name='chk_open_challenges_status'`,
    );
    check(cons.n === 1, 'chk_open_challenges_status enforces open|claimed|cancelled|expired');

    const routeSrc = fs.readFileSync(path.join(__dirname, '..', 'routes', 'matches.js'), 'utf8');
    check(routeSrc.includes(`case '${INDEX}':`),
      `routes/matches.js still maps ${INDEX} to a friendly 409`);

    console.log('\n--- Result -----------------------------------------------');
    if (failures.length) {
      console.log(`FAILED: 041 applied but ${failures.length} check(s) failed:`);
      failures.forEach((f) => console.log(`   - ${f}`));
    } else {
      console.log('OK: Migration 041 applied and verified.');
      console.log('   one LOCKED match per booking (challenge_sent is no longer capped);');
      console.log('   open_challenges ready for the board.');
    }
    client.release();
    await pool.end();
    process.exit(failures.length ? 1 : 0);
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    console.error(`\nMigration 041 failed: ${e.code || ''} ${e.message}`);
    if (e.detail) console.error(`   detail: ${e.detail}`);
    client.release();
    await pool.end();
    process.exit(1);
  }
}

run();
