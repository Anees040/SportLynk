/**
 * push_booking_past.js — move one booking's slot time into the past so a match
 * result can be submitted without waiting for the pitch time to arrive.
 *
 * Why this exists
 * The match flow deliberately refuses a result before the slot has started
 * (routes/matches.js: "You can submit the result once the slot has started") —
 * otherwise a captain could file a scoreline for a game nobody played and the
 * opponent's only recourse would be a dispute. That rule is correct, and it also
 * means the two-phone acceptance test cannot be run at 23:00 when the next
 * bookable slot is 08:00 tomorrow.
 *
 * run_match_flow_check.js solves this internally with pushBookingIntoPast(). This
 * script is the same operation as a command, for the manual run.
 *
 * Why not just an UPDATE IN the SQL editor
 * Because of checked_in_at. A booking whose start time is in the past with
 * checked_in_at IS NULL is exactly what noShowJob.js sweeps: 30 minutes later it
 * auto-forfeits the booking and splits the escrow to the owner. A hand-written
 * UPDATE that moves only the three time columns therefore quietly costs the player
 * the booking and the money, several minutes after it appeared to work. This
 * script sets checked_in_at in the same statement, which is the flag that sweep
 * checks (noShowJob.js: `AND b.checked_in_at IS NULL`).
 *
 * The honest CAVEAT
 * Setting checked_in_at is not a real QR check-in: it moves no money. The escrow
 * stays frozen in the player's wallet instead of transferring to the owner, so
 * /wallet/frozen will report a non-zero delta afterwards. That is drift, it is
 * expected, and `node src/scripts/reconcile_wallets.js` reports it (add --fix to
 * repair). Pass --no-checkin to skip the flag and let the no-show sweep settle the
 * money properly instead — the match result still submits either way, because that
 * gate reads the slot time and not the booking status.
 *
 * Bookings, not SLOTS
 * `bookings` carries its own slot_date/start_time/end_time, denormalised at
 * booking time, and both the picker (GET /matches/linkable-bookings) and the
 * result gate read those columns. The `slots` row is left alone: it stays booked,
 * and nothing reads its time for this flow.
 *
 * USAGE
 *   node src/scripts/push_booking_past.js                       # list candidates
 *   node src/scripts/push_booking_past.js --match <uuid>        # by match
 *   node src/scripts/push_booking_past.js --booking <uuid>      # by booking
 *   node src/scripts/push_booking_past.js --match <uuid> --dry  # show, change nothing
 *   node src/scripts/push_booking_past.js --match <uuid> --no-checkin
 *   node src/scripts/push_booking_past.js --booking <uuid> --force  # no live match
 */

const pool = require('../db/pool');

const TZ = 'Asia/Karachi';
const LIVE = ['challenge_sent', 'accepted', 'awaiting_results', 'awaiting_owner'];

function arg(name) {
  const i = process.argv.indexOf(`--${name}`);
  return i === -1 ? null : process.argv[i + 1] || null;
}
const has = (name) => process.argv.includes(`--${name}`);

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Every live match with a booking, so the id can be copied from the output. */
async function list() {
  const { rows } = await pool.query(
    `SELECT m.id AS match_id, m.status::text AS status, m.booking_id,
            ct.name AS challenger, ot.name AS opponent,
            b.slot_date::text AS d, b.start_time::text AS st,
            b.checked_in_at IS NOT NULL AS checked_in,
            b.status::text AS booking_status,
            ((b.slot_date::DATE + b.start_time::TIME) <= (NOW() AT TIME ZONE $1)) AS started,
            v.name AS venue
       FROM matches m
       JOIN teams ct ON ct.id = m.challenger_team
       JOIN teams ot ON ot.id = m.opponent_team
       LEFT JOIN bookings b ON b.id = m.booking_id
       LEFT JOIN venues v ON v.id = b.venue_id
      WHERE m.status = ANY($2::text[]) AND m.booking_id IS NOT NULL
      ORDER BY m.created_at DESC
      LIMIT 25`,
    [TZ, LIVE],
  );

  if (!rows.length) {
    console.log('\nNo live match with a linked booking.');
    console.log('Send a challenge from the app first, then re-run this to find it.\n');
    return;
  }

  console.log(`\n${rows.length} live match(es) with a booking:\n`);
  for (const r of rows) {
    const when = `${r.d} ${String(r.st).slice(0, 5)}`;
    const flag = r.started ? 'ALREADY STARTED — result can be submitted' : 'in the future';
    console.log(`  ${r.challenger} vs ${r.opponent}`);
    console.log(`    match    ${r.match_id}   [${r.status}]`);
    console.log(`    booking  ${r.booking_id}  ${r.venue || '(venue?)'}`);
    console.log(`    slot     ${when} PKT — ${flag}`);
    console.log(`    booking status ${r.booking_status}, checked in: ${r.checked_in ? 'yes' : 'no'}\n`);
  }
  console.log('Push one back with:');
  console.log('  node src/scripts/push_booking_past.js --match <match uuid>\n');
}

async function push({ matchId, bookingId, dry, checkin, force }) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    // Resolve the booking, and read the match alongside it so the safety check
    // below sees the same snapshot the update will act on.
    const { rows } = await client.query(
      `SELECT b.id, b.player_id, b.status::text AS booking_status,
              b.slot_date::text AS d, b.start_time::text AS st, b.end_time::text AS et,
              b.checked_in_at, b.total_amount, b.security_deposit,
              u.name AS player, v.name AS venue,
              m.id AS match_id, m.status::text AS match_status
         FROM bookings b
         JOIN users u ON u.id = b.player_id
         JOIN venues v ON v.id = b.venue_id
         LEFT JOIN matches m ON m.booking_id = b.id AND m.status = ANY($3::text[])
        WHERE ($1::uuid IS NOT NULL AND b.id = $1::uuid)
           OR ($2::uuid IS NOT NULL AND b.id = (SELECT booking_id FROM matches WHERE id = $2::uuid))
        FOR UPDATE OF b`,
      [bookingId, matchId, LIVE],
    );

    if (!rows.length) {
      await client.query('ROLLBACK');
      console.error('\nNo such booking (or that match has no linked booking).\n');
      process.exitCode = 1;
      return;
    }
    const b = rows[0];

    console.log(`\nBooking  ${b.id}`);
    console.log(`Player   ${b.player}`);
    console.log(`Venue    ${b.venue}`);
    console.log(`Slot     ${b.d} ${String(b.st).slice(0, 5)}–${String(b.et).slice(0, 5)} PKT`);
    console.log(`Status   ${b.booking_status}, checked in: ${b.checked_in_at ? 'yes' : 'no'}`);
    console.log(`Match    ${b.match_id ? `${b.match_id} [${b.match_status}]` : 'none live'}`);

    if (!b.match_id && !force) {
      await client.query('ROLLBACK');
      console.error('\nThis booking has no live match. This script is for the match'
        + ' acceptance run, so it refuses by default — pass --force if you meant it.\n');
      process.exitCode = 1;
      return;
    }

    if (dry) {
      await client.query('ROLLBACK');
      console.log('\n--dry: nothing changed. It would move the slot to 3 hours ago'
        + ` (ending 2 hours ago)${checkin ? ' and set checked_in_at' : ''}.\n`);
      return;
    }

    const { rows: after } = await client.query(
      `UPDATE bookings
          SET slot_date  = ((NOW() AT TIME ZONE $2) - interval '3 hours')::date,
              start_time = ((NOW() AT TIME ZONE $2) - interval '3 hours')::time,
              end_time   = ((NOW() AT TIME ZONE $2) - interval '2 hours')::time,
              checked_in_at = CASE WHEN $3 THEN COALESCE(checked_in_at, NOW()) ELSE checked_in_at END,
              updated_at = NOW()
        WHERE id = $1
      RETURNING slot_date::text AS d, start_time::text AS st, end_time::text AS et,
                checked_in_at IS NOT NULL AS checked_in`,
      [b.id, TZ, checkin],
    );

    await client.query('COMMIT');

    const a = after[0];
    console.log(`\nMoved to ${a.d} ${String(a.st).slice(0, 5)}–${String(a.et).slice(0, 5)} PKT`
      + ` (checked in: ${a.checked_in ? 'yes' : 'no'})`);
    console.log('Both captains can submit the result now.');

    if (checkin && !b.checked_in_at) {
      console.log('\nNOTE — checked_in_at was set to keep noShowJob from forfeiting this');
      console.log(`booking, but no money moved: PKR ${b.total_amount} stays frozen in`);
      console.log(`${b.player}'s wallet instead of transferring to the owner.`);
      console.log('Check with:  node src/scripts/reconcile_wallets.js   (--fix to repair)');
    }
    if (!checkin) {
      console.log('\nNOTE — --no-checkin: noShowJob will forfeit this booking about 30');
      console.log('minutes from the new start time and settle the escrow to the owner.');
      console.log('The match result still submits — that gate reads the slot time only.');
    }
    console.log('');
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    throw e;
  } finally {
    client.release();
  }
}

(async () => {
  const matchId = arg('match');
  const bookingId = arg('booking');

  for (const [flag, val] of [['match', matchId], ['booking', bookingId]]) {
    if (val && !UUID_RE.test(val)) {
      console.error(`\n--${flag} is not a uuid: ${val}\n`);
      process.exitCode = 1;
      return;
    }
  }

  if (!matchId && !bookingId) await list();
  else {
    await push({
      matchId,
      bookingId,
      dry: has('dry'),
      checkin: !has('no-checkin'),
      force: has('force'),
    });
  }
})()
  .catch((e) => {
    console.error('\nFailed:', e.message, '\n');
    process.exitCode = 1;
  })
  .finally(() => pool.end());
