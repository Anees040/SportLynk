/**
 * check_open_challenges.js — why does the open challenge board look empty?
 *
 * Why this exists
 * The board has four independent ways to show a player nothing, and from the app
 * they look almost alike:
 *
 *   1. migration 041 was never applied, so `open_challenges` does not exist and
 *      the service answers an empty list rather than an error;
 *   2. the table exists but nobody has posted, which is a healthy empty board;
 *   3. cards were posted but every one has expired, and the board filters on
 *      `expires_at > NOW()` — so the row still counts in a `SELECT COUNT(*)` while
 *      being invisible;
 *   4. a post was refused, which is the only case that produces a message.
 *
 * A plain row count cannot tell these apart, which is exactly how a working board
 * gets mistaken for a broken one. This script reads through
 * openChallengeService.listBoard itself, so what it prints is what the app is
 * served. If the board is healthy here and the phone still shows nothing, the fault
 * is in the client or in which API the client is pointed at.
 *
 * Read-only. Writes nothing, takes no locks beyond its own queries, and is safe to
 * run against live data at any time.
 *
 * USAGE
 *   node src/scripts/check_open_challenges.js
 *   node src/scripts/check_open_challenges.js --sport football
 */

const pool = require('../db/pool');
const svc = require('../services/openChallengeService');

function argOf(flag, fallback) {
  const i = process.argv.indexOf(flag);
  if (i === -1 || i === process.argv.length - 1) return fallback;
  return process.argv[i + 1];
}

const failures = [];
function check(ok, label, detail) {
  if (ok) {
    console.log(`   OK  ${label}`);
  } else {
    failures.push(label);
    console.log(`   BAD ${label}${detail ? ` — ${detail}` : ''}`);
  }
}

async function run() {
  const sport = argOf('--sport', null);

  console.log('\n--- Schema -----------------------------------------------');
  const { rows: [t] } = await pool.query(
    "SELECT to_regclass('public.open_challenges') AS t",
  );
  const hasTable = Boolean(t && t.t);
  check(hasTable, 'open_challenges exists (migration 041 applied)',
    'apply src/scripts/run_migration_041_multi_challenge.js');
  if (!hasTable) {
    console.log('\nWithout the table the board is off and answers an empty list.');
    await pool.end();
    process.exit(failures.length ? 1 : 0);
  }

  const { rows: cols } = await pool.query(
    `SELECT column_name FROM information_schema.columns
      WHERE table_schema='public' AND table_name='open_challenges'
      ORDER BY column_name`,
  );
  const names = cols.map((c) => c.column_name);
  check(names.includes('expires_at'), 'expires_at is present (the board filters on it)');
  check(names.includes('challenger_team'), 'challenger_team is present');
  check(names.includes('claimed_by_team'), 'claimed_by_team is present');

  const { rows: [idx] } = await pool.query(
    `SELECT indexdef FROM pg_indexes
      WHERE schemaname='public' AND indexname='ux_open_challenges_booking_open'`,
  );
  check(Boolean(idx), 'ux_open_challenges_booking_open exists (one open offer per booking)',
    'a re-post of a cancelled slot needs this partial index');

  console.log('\n--- Census -----------------------------------------------');
  const { rows: [c] } = await pool.query(
    `SELECT COUNT(*)::int                                              AS total,
            COUNT(*) FILTER (WHERE status = 'open')::int               AS still_open,
            COUNT(*) FILTER (WHERE status = 'claimed')::int            AS claimed,
            COUNT(*) FILTER (WHERE status = 'cancelled')::int          AS cancelled,
            COUNT(*) FILTER (WHERE status = 'open'
                              AND expires_at > NOW())::int             AS live,
            COUNT(*) FILTER (WHERE status = 'open'
                              AND expires_at <= NOW())::int            AS expired_open
       FROM open_challenges`,
  );
  console.log(`   rows ${c.total} — open ${c.still_open} (live ${c.live}, `
    + `expired-but-still-'open' ${c.expired_open}), claimed ${c.claimed}, `
    + `cancelled ${c.cancelled}`);
  // Expiry is lazy by design: nothing sweeps these, the board simply stops
  // showing them. A pile of them is worth naming so it is not mistaken for data
  // loss, but it is not a failure.
  if (c.expired_open > 0) {
    console.log(`   note: ${c.expired_open} row(s) are 'open' but past expires_at. `
      + 'The board hides them and the column stays as it is; this is not a fault.');
  }

  console.log('\n--- What the app is served --------------------------------');
  // The service takes a viewer id only to flag `mine`. The nil uuid belongs to
  // nobody, so every card comes back as somebody else's — which is what a player
  // other than the poster sees, and the case this script is diagnosing.
  const board = await svc.listBoard(pool, {
    userId: '00000000-0000-0000-0000-000000000000',
    sport,
  });
  const cards = (board.data && board.data.challenges) || [];
  console.log(`   GET /api/open-challenges${sport ? `?sport=${sport}` : ''} `
    + `→ ${cards.length} card(s)`);
  for (const card of cards.slice(0, 10)) {
    console.log(`     · ${card.team.name} [${card.sport}] `
      + `${card.booking.slotDate} ${String(card.booking.startTime).slice(0, 5)}`
      + ` @ ${card.booking.venueName} — expires ${card.expiresAt}`);
  }
  if (cards.length > 10) console.log(`     … and ${cards.length - 10} more`);

  // The honest summary. A live row count of zero with a healthy table is an empty
  // board, not a broken one, and the distinction is the whole point of this file.
  console.log('\n--- Result -----------------------------------------------');
  if (c.live === 0) {
    console.log('The board is HEALTHY and EMPTY: nothing is posted and live.');
    console.log('   An empty board is not an error. Post one with the app, or run this');
    console.log('   again after somebody offers a slot.');
  } else if (cards.length === 0) {
    failures.push('rows are live but the board returned none');
    console.log(`BAD ${c.live} live row(s) exist but listBoard returned no cards — `
      + 'a filter is dropping them (sport mismatch, or a broken join on teams/bookings/venues).');
  } else {
    console.log(`OK: ${cards.length} live card(s) are being served.`);
  }

  if (failures.length) {
    console.log(`\nFAILED ${failures.length} check(s):`);
    failures.forEach((f) => console.log(`   - ${f}`));
  }
  await pool.end();
  process.exit(failures.length ? 1 : 0);
}

run().catch(async (e) => {
  console.error(`\ncheck_open_challenges failed: ${e.code || ''} ${e.message}`);
  if (e.detail) console.error(`   detail: ${e.detail}`);
  try { await pool.end(); } catch { /* pool already closed */ }
  process.exit(1);
});
