/**
 * Runner for migrations/017_reviews_moderation.sql
 * Usage: node run_migration_017.js
 *
 * Applied as ONE multi-statement command, so Postgres wraps it in a single
 * implicit transaction and a failure anywhere leaves the database untouched.
 * (No `-- @@SPLIT@@` marker: this migration adds no enum values, and
 * `ALTER TYPE ... ADD VALUE` is the only statement that cannot run in a txn.)
 *
 * Like the 016 runner, this is more than a `\d` dump:
 *
 *   1. A PRE-FLIGHT that can stop the migration. ux_reviews_one_per_author is a
 *      UNIQUE index over live data — if two rows already share
 *      (booking_id, reviewer_id, review_type) the CREATE fails with a 23505 that
 *      names the index, not the rows. Any such pair is found and PRINTED first
 *      and the migration is not attempted, because deciding which duplicate
 *      review to keep is a decision for a human.
 *
 *   2. FUNCTIONAL PROBES. Three of the guarantees here are constraints, and a
 *      constraint that exists but does not constrain is worse than none — it
 *      reads as enforced and is enforced nowhere. Each probe inserts a row that
 *      MUST be rejected and asserts the SQLSTATE, inside a transaction that is
 *      always rolled back. The probe that matters most is the one-review-per-
 *      author index, because that is the only thing standing between a
 *      double-tapped Submit and two reviews for one booking.
 *
 * Safe to re-run: every statement in the .sql is idempotent.
 */
const fs = require('fs');
const path = require('path');
const pool = require('./src/db/pool');

// 017 alters or references all of these. A missing one means 013 was never run.
const PREREQUISITE_TABLES = ['users', 'reviews', 'player_profiles', 'bookings', 'venues'];

const EXPECTED_INDEXES = [
  'idx_review_flags_status',
  'ux_reviews_one_per_author',
  'idx_reviews_venue_visible',
  'idx_reviews_reviewed_user',
];

const EXPECTED_CONSTRAINTS = ['chk_review_flags_status'];

// column → information_schema.data_type, for the one table 017 creates.
const EXPECTED_COLUMNS = {
  review_flags: {
    id: 'uuid',
    review_id: 'uuid',
    flagged_by: 'uuid',
    reason: 'text',
    status: 'text',
    created_at: 'timestamp with time zone',
  },
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
  const sqlFile = path.join(__dirname, 'migrations', '017_reviews_moderation.sql');
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
      console.error('❌ Cannot apply migration 017 — prerequisite tables missing:');
      console.error(`   ${missingPrereqs.join(', ')}`);
      console.error('   Apply schema.sql, then run_migration_013.js through 016.');
      client.release();
      await pool.end();
      process.exit(1);
    }

    // Duplicate (booking, author, type) rows would block ux_reviews_one_per_author.
    // NULL booking_id / reviewer_id are excluded: SQL NULLs never collide in a
    // unique index, so they cannot block it and are not the app's concern.
    const { rows: dupeReviews } = await client.query(
      `SELECT booking_id, reviewer_id, review_type, count(*)::int AS n
         FROM reviews
        WHERE booking_id IS NOT NULL AND reviewer_id IS NOT NULL
        GROUP BY booking_id, reviewer_id, review_type
       HAVING count(*) > 1
        ORDER BY n DESC`,
    );
    if (dupeReviews.length) {
      console.error('❌ Cannot apply migration 017 — more than one review shares a');
      console.error('   (booking, author, type), which blocks ux_reviews_one_per_author:');
      console.error('');
      for (const d of dupeReviews) {
        console.error(`   booking ${d.booking_id}, author ${d.reviewer_id}, `
          + `type ${d.review_type}: ${d.n} reviews`);
      }
      console.error('');
      console.error('   Keep one row per (booking, author, type) and delete the rest,');
      console.error('   then re-run. A migration must not pick which review survives.');
      client.release();
      await pool.end();
      process.exit(1);
    }

    const { rows: [counts] } = await client.query(
      `SELECT (SELECT count(*)::int FROM reviews)         AS reviews,
              (SELECT count(*)::int FROM player_profiles) AS profiles,
              (SELECT count(*)::int FROM bookings)        AS bookings,
              (SELECT count(*)::int FROM users)           AS users`,
    );
    console.log(`Pre-flight: ${before.length} tables present, all prerequisites found.`);
    console.log(`   ${counts.reviews} review(s), ${counts.profiles} player profile(s), `
      + `${counts.bookings} booking(s), ${counts.users} user(s).`);
    console.log('   No duplicate (booking, author, type) reviews.');
    console.log('');

    // ─── Apply ──────────────────────────────────────────────────────────────
    await client.query(sql);
    console.log('Migration 017 applied. Verifying:');
    console.log('');

    // ─── 1. review_flags columns ────────────────────────────────────────────
    const { rows: cols } = await client.query(
      `SELECT table_name, column_name, data_type
         FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = ANY($1)`,
      [Object.keys(EXPECTED_COLUMNS)],
    );
    const typeOf = new Map(cols.map((r) => [`${r.table_name}.${r.column_name}`, r.data_type]));
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
      `all ${colTotal} review_flags columns present with the right type${badCols.length ? ` — WRONG: ${badCols.join('; ')}` : ''}`);

    // ─── 2. Indexes ─────────────────────────────────────────────────────────
    const { rows: idxRows } = await client.query(
      `SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = 'public'`,
    );
    const idx = new Map(idxRows.map((r) => [r.indexname, r.indexdef]));
    const missingIdx = EXPECTED_INDEXES.filter((n) => !idx.has(n));
    check(missingIdx.length === 0,
      `all ${EXPECTED_INDEXES.length} indexes exist${missingIdx.length ? ` — MISSING: ${missingIdx.join(', ')}` : ''}`);

    // ux_reviews_one_per_author must be UNIQUE and carry review_type, or a
    // captain's second (opponent) review on a match booking would be rejected.
    const authorIdx = idx.get('ux_reviews_one_per_author') || '';
    check(/CREATE UNIQUE INDEX/i.test(authorIdx) && /review_type/i.test(authorIdx),
      'ux_reviews_one_per_author is UNIQUE and keyed on review_type '
      + '(a captain may leave one venue AND one opponent review per booking)');

    // The read-path indexes must be partial, or they index rows their query
    // never touches (hidden reviews, the NULL side of each review type).
    const venueIdx = idx.get('idx_reviews_venue_visible') || '';
    check(/WHERE/i.test(venueIdx) && /hidden/i.test(venueIdx),
      'idx_reviews_venue_visible is partial on hidden = false (moderated reviews stay out of the listing)');
    const userIdx = idx.get('idx_reviews_reviewed_user') || '';
    check(/WHERE/i.test(userIdx) && /reviewed_user_id/i.test(userIdx),
      'idx_reviews_reviewed_user is partial on reviewed_user_id IS NOT NULL (venue reviews carry none)');

    // ─── 3. CHECK constraint exists ─────────────────────────────────────────
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
      `all ${EXPECTED_CONSTRAINTS.length} CHECK constraint(s) exist${missingCons.length ? ` — MISSING: ${missingCons.join(', ')}` : ''}`);

    // ─── 4. trust_score cold-start default flipped 100 → 50 ─────────────────
    const { rows: [tsCol] } = await client.query(
      `SELECT column_default
         FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'player_profiles'
          AND column_name = 'trust_score'`,
    );
    const tsDefault = (tsCol && tsCol.column_default) || '';
    check(/\b50\b/.test(tsDefault) && !/\b100\b/.test(tsDefault),
      `player_profiles.trust_score DEFAULT is 50, not 100 (zero-signal baseline; was "${tsDefault}")`);

    // ─── 5. Functional probes — do the constraints actually constrain? ───────
    // Everything below runs inside a transaction that is ALWAYS rolled back, and
    // every insert expected to fail gets its own SAVEPOINT: without one, the
    // first 23505/23514 aborts the transaction and every later query dies with
    // 25P02 instead of reporting a result.
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

    // The probes need a real user + booking (both are FK targets). Seeded dev
    // databases have them; an empty one skips the probes with a note — the
    // constraints are still proven to EXIST above, the probes are the bonus.
    const { rows: userRow } = await client.query('SELECT id FROM users LIMIT 1');
    const { rows: bookingRow } = await client.query('SELECT id FROM bookings LIMIT 1');

    if (userRow.length && bookingRow.length) {
      const uid = userRow[0].id;
      const bid = bookingRow[0].id;

      await client.query('BEGIN');
      try {
        // Seed one venue review by this author on this booking.
        const { rows: [r1] } = await client.query(
          `INSERT INTO reviews (booking_id, reviewer_id, review_type, rating, comment)
           VALUES ($1, $2, 'venue', 5, '__mig017 probe') RETURNING id`,
          [bid, uid],
        );

        // 5a. THE important one — a second venue review, same author + booking.
        const dupe = await tryInsert('r1', () => client.query(
          `INSERT INTO reviews (booking_id, reviewer_id, review_type, rating)
           VALUES ($1, $2, 'venue', 3)`, [bid, uid]));
        check(!dupe.ok && dupe.code === '23505',
          `a SECOND venue review on the same booking by the same author is rejected (23505) — `
          + `a double-tapped Submit cannot double-review${dupe.ok ? ' — IT WAS ACCEPTED' : ` — got ${dupe.code}`}`);

        // 5b. A DIFFERENT type on the same (booking, author) is allowed — the
        //     captain's opponent review must not collide with their venue review.
        const otherType = await tryInsert('r2', () => client.query(
          `INSERT INTO reviews (booking_id, reviewer_id, review_type, rating)
           VALUES ($1, $2, 'opponent', 4)`, [bid, uid]));
        check(otherType.ok,
          'an OPPONENT review on that same booking by that same author is allowed '
          + '(venue + opponent are two legitimate reviews)');

        // 5c. review_flags: one report per user per review.
        await client.query(
          `INSERT INTO review_flags (review_id, flagged_by, reason) VALUES ($1, $2, 'probe')`,
          [r1.id, uid]);
        const twoFlags = await tryInsert('r3', () => client.query(
          `INSERT INTO review_flags (review_id, flagged_by, reason) VALUES ($1, $2, 'probe again')`,
          [r1.id, uid]));
        check(!twoFlags.ok && twoFlags.code === '23505',
          `the same user flagging one review twice is rejected (23505)${twoFlags.ok ? ' — IT WAS ACCEPTED' : ''}`);

        // 5d. review_flags status outside the queue's state machine.
        const badStatus = await tryInsert('r4', () => client.query(
          `INSERT INTO review_flags (review_id, flagged_by, status)
           VALUES ($1, $2, 'pending')`, [r1.id, uid]));
        check(!badStatus.ok && badStatus.code === '23514',
          `review_flags status='pending' (not open/resolved/dismissed) is rejected (23514)${badStatus.ok ? ' — IT WAS ACCEPTED' : ''}`);
      } finally {
        await client.query('ROLLBACK');   // nothing above may survive
      }

      const { rows: [{ leftover }] } = await client.query(
        `SELECT count(*)::int AS leftover FROM reviews WHERE comment = '__mig017 probe'`,
      );
      check(leftover === 0, `probe rolled back cleanly — ${leftover} probe review(s) left behind`);
    } else {
      console.log('   ~ skipped the functional probes (need one users row and one bookings row)');
    }

    // ─── Listing ────────────────────────────────────────────────────────────
    console.log('');
    console.log('Reviews backend now enforced by the database:');
    console.log('   • one review per (booking, author, type)  — FR9.1');
    console.log('   • review_flags moderation queue           — FR9.9 (open|resolved|dismissed)');
    console.log('   • new users start at trust_score 50        — ER2.5 cold-start');
  } catch (e) {
    failures.push(`migration threw: ${e.message}`);
    console.error('');
    console.error('❌ Migration 017 failed:', e.message);
    if (e.detail) console.error('   detail:', e.detail);
    if (e.hint) console.error('   hint:', e.hint);
  } finally {
    client.release();
    await pool.end();
  }

  console.log('');
  if (failures.length) {
    console.error(`❌ Migration 017: ${failures.length} check(s) failed.`);
  } else {
    console.log('✅ Migration 017 verified — reviews moderation and trust cold-start ready.');
  }
  process.exit(failures.length ? 1 : 0);
}

run();
