/**
 * add_future_slots.js — give every active venue bookable slots for the next N days.
 *
 * WHY THIS EXISTS
 * ---------------
 * A venue with no future slot cannot be booked, so with zero future slots the
 * entire S1 acceptance suite is untestable: book → approve → QR check-in, both
 * cancel paths, the two-account slot lock, and the 1-minute auto-approve and
 * no-show tests all begin with "player books a slot".
 *
 * seed_venues.js can produce slots, but it DELETES the owner's venues, bookings
 * and ledger history first — fine for a from-scratch demo database, wrong when the
 * venues were built by hand and are worth keeping. This script is the additive
 * alternative: it never deletes anything and never touches wallets.
 *
 * IDEMPOTENT
 * ----------
 * `slots` has no unique constraint on (venue_id, slot_date, start_time), so
 * re-running would otherwise double every slot. Each INSERT is guarded by a
 * NOT EXISTS on that triple, which means you can run this daily to keep a rolling
 * window and only the genuinely missing rows are created. Existing slots are never
 * modified — a booked or blocked slot stays exactly as it is.
 *
 * PKT, NOT UTC
 * ------------
 * `slot_date` is a DATE and `start_time` a TIME: wall-clock values in the venue's
 * own timezone, which is Asia/Karachi. "Today" is therefore computed as
 * (NOW() AT TIME ZONE 'Asia/Karachi')::date, not CURRENT_DATE — the database runs
 * in UTC, so between midnight and 05:00 PKT those two are different days and the
 * first day of slots would land in the past.
 *
 * USAGE
 * -----
 *   node src/scripts/add_future_slots.js                  # 14 days, all active venues
 *   node src/scripts/add_future_slots.js --days 7
 *   node src/scripts/add_future_slots.js --venue <uuid>
 *   node src/scripts/add_future_slots.js --from 8 --to 23 # hour window (24h clock)
 *   node src/scripts/add_future_slots.js --dry            # report, change nothing
 */

const pool = require('../db/pool');

function argOf(flag, fallback) {
  const i = process.argv.indexOf(flag);
  if (i === -1 || i === process.argv.length - 1) return fallback;
  return process.argv[i + 1];
}

const DAYS = Math.max(1, Math.min(60, parseInt(argOf('--days', '14'), 10) || 14));
const VENUE = argOf('--venue', null);
const DRY = process.argv.includes('--dry');

// Used only when a venue has no operating_hours set — every venue currently has
// them NULL. One-hour slots from 08:00 to 23:00 gives 15 per day, which is enough
// to test without making the player grid unusable.
const DEFAULT_FROM = Math.max(0, Math.min(23, parseInt(argOf('--from', '8'), 10) || 8));
const DEFAULT_TO = Math.max(1, Math.min(24, parseInt(argOf('--to', '23'), 10) || 23));

const hh = (h) => `${String(h).padStart(2, '0')}:00:00`;

async function main() {
  console.log('');
  console.log('═══ Add future slots ═══════════════════════════════════════════');
  console.log(`  Window : next ${DAYS} day(s) starting today (Asia/Karachi)`);
  console.log(`  Hours  : ${hh(DEFAULT_FROM)} – ${hh(DEFAULT_TO)} where a venue has none set`);
  console.log(DRY ? '  MODE   : --dry — nothing will be written' : '  MODE   : writing');
  console.log('');

  const venues = await pool.query(
    `SELECT id, name, city, price_per_hour, base_price,
            operating_hours_from, operating_hours_to
       FROM venues
      WHERE is_active = true
        ${VENUE ? 'AND id = $1' : ''}
      ORDER BY name`,
    VENUE ? [VENUE] : [],
  );

  if (!venues.rows.length) {
    console.log(VENUE
      ? '  No active venue with that id.'
      : '  No active venues. Register an owner and add a venue first.');
    return 1;
  }

  // "Today" in PKT, resolved by the database so there is one clock, not two.
  const todayRes = await pool.query(
    `SELECT (NOW() AT TIME ZONE 'Asia/Karachi')::date AS today,
            (NOW() AT TIME ZONE 'Asia/Karachi')::time AS now_time`,
  );
  const today = todayRes.rows[0].today;
  console.log(`  Today in PKT: ${String(today).slice(0, 10)} (local time now ${String(todayRes.rows[0].now_time).slice(0, 5)})`);
  console.log('');

  let createdTotal = 0;
  let skippedTotal = 0;

  for (const v of venues.rows) {
    // A venue's own hours win when set; the CLI window is only the fallback.
    const fromH = v.operating_hours_from
      ? parseInt(String(v.operating_hours_from).slice(0, 2), 10)
      : DEFAULT_FROM;
    const toH = v.operating_hours_to
      ? parseInt(String(v.operating_hours_to).slice(0, 2), 10)
      : DEFAULT_TO;

    const price = Number(v.price_per_hour ?? v.base_price ?? 0);
    if (!(price > 0)) {
      console.log(`  ${String(v.name).slice(0, 28).padEnd(29)} skipped — no price set`);
      continue;
    }
    if (toH <= fromH) {
      console.log(`  ${String(v.name).slice(0, 28).padEnd(29)} skipped — operating hours ${fromH}:00–${toH}:00 are not a forward range`);
      continue;
    }

    let created = 0;
    let skipped = 0;
    const perVenue = DAYS * (toH - fromH);

    // One statement per venue, not one per slot. The naive loop issued a round
    // trip per slot — 10 venues x 14 days x 15 hours = 2,100 requests to a remote
    // Supabase pooler, which took minutes. generate_series builds the whole grid
    // inside Postgres, so this is 10 statements total and finishes in seconds.
    //
    // The NOT EXISTS still guards each individual row, so idempotency is unchanged:
    // rows that already exist are simply not produced by the SELECT.
    const gridSql = `
      SELECT $1::uuid,
             ($2::date + d)::date,
             make_time(h, 0, 0),
             make_time(h + 1, 0, 0),
             $5::numeric,
             'available'::slot_status
        FROM generate_series(0, $3::int - 1) AS d,
             generate_series($4::int, $6::int - 1) AS h
       WHERE NOT EXISTS (
             SELECT 1 FROM slots s
              WHERE s.venue_id = $1::uuid
                AND s.slot_date = ($2::date + d)::date
                AND s.start_time = make_time(h, 0, 0))`;
    const params = [v.id, today, DAYS, fromH, price, toH];

    if (DRY) {
      const r = await pool.query(`SELECT COUNT(*)::int AS c FROM (${gridSql}) g`, params);
      created = r.rows[0].c;
      skipped = perVenue - created;
    } else {
      const r = await pool.query(
        `INSERT INTO slots (venue_id, slot_date, start_time, end_time, price, status)
         ${gridSql}`,
        params,
      );
      created = r.rowCount;
      skipped = perVenue - created;
    }

    createdTotal += created;
    skippedTotal += skipped;
    console.log(`  ${String(v.name).slice(0, 28).padEnd(29)} ${String(created).padStart(4)} ${DRY ? 'would be created' : 'created'}, ${String(skipped).padStart(4)} already there`);
  }

  console.log('');
  console.log(`  ${DRY ? 'Would create' : 'Created'} ${createdTotal} slot(s); ${skippedTotal} already existed.`);

  // Report the number that actually matters: what a player can book right now.
  // Mirrors the API's own filter (future dates, plus today only after now, PKT).
  const bookable = await pool.query(
    `SELECT COUNT(*)::int AS c
       FROM slots
      WHERE status = 'available'
        AND (slot_date >  (NOW() AT TIME ZONE 'Asia/Karachi')::date
         OR (slot_date =  (NOW() AT TIME ZONE 'Asia/Karachi')::date
        AND start_time > (NOW() AT TIME ZONE 'Asia/Karachi')::time))`,
  );
  console.log('');
  console.log(`  Bookable right now (what the app will show): ${bookable.rows[0].c}`);
  console.log(bookable.rows[0].c > 0
    ? '  ✅ Booking tests can run.'
    : '  ⚠️  Still nothing bookable — check venue is_active and prices.');
  console.log('');
  return 0;
}

main()
  .then((code) => process.exit(code))
  .catch((e) => {
    console.error('');
    console.error('❌ Failed:', e.message);
    console.error('   Nothing was deleted — this script only ever inserts.');
    process.exit(1);
  });
