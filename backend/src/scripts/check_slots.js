/**
 * check_slots.js — does a player actually see bookable hours, and if not, why.
 *
 * Why a row count is not enough
 * `SELECT COUNT(*) FROM slots` can report thousands while every ground shows
 * "No slots available", because three independent filters stand between a row and
 * the grid the player taps:
 *
 *   1. `venues.is_active` — a venue awaiting admin approval is invisible.
 *   2. the owner verification gate in discoveryService.searchVenues — a venue
 *      whose owner is `pending` or `rejected` is dropped from the list, so the
 *      ground is not merely empty, it is absent.
 *   3. the PKT slot window in discoveryService.venueDetail — a future date shows
 *      every slot, today shows only hours that have not started yet, and a past
 *      date shows none.
 *
 * So this script asks the questions through discoveryService itself rather than
 * through SQL of its own. What it prints is what the API returns, which is what
 * the app paints — if the numbers here are healthy and the phone still shows
 * nothing, the fault is in the client or in which API the client is pointed at,
 * and that is worth knowing before reading any more backend code.
 *
 * Read-only. It writes nothing and is safe to run against live data at any time.
 *
 * USAGE
 *   node src/scripts/check_slots.js              # every active venue, 14 days
 *   node src/scripts/check_slots.js --days 3
 *   node src/scripts/check_slots.js --venue <uuid>
 */

const pool = require('../db/pool');
const disc = require('../services/discoveryService');
const grid = require('../utils/slotGrid');

function argOf(flag, fallback) {
  const i = process.argv.indexOf(flag);
  if (i === -1 || i === process.argv.length - 1) return fallback;
  return process.argv[i + 1];
}

const DAYS = grid.clampDays(argOf('--days', grid.HORIZON_DAYS));
const VENUE = argOf('--venue', null);

/** PKT is UTC+5 with no DST, so the offset is the whole conversion. */
const PKT_OFFSET_MS = 5 * 60 * 60 * 1000;
const pktDateStr = (dayOffset) => new Date(Date.now() + PKT_OFFSET_MS + dayOffset * 86400000)
  .toISOString()
  .slice(0, 10);

async function main() {
  let problems = 0;

  console.log('');
  console.log('═══ Slot visibility check ══════════════════════════════════════');

  const clock = await pool.query(
    `SELECT (NOW() AT TIME ZONE '${grid.PKT_TIMEZONE}')::date AS d,
            (NOW() AT TIME ZONE '${grid.PKT_TIMEZONE}')::time AS t,
            NOW() AS utc`,
  );
  console.log(`  PKT now : ${String(clock.rows[0].d).slice(0, 10)} ${String(clock.rows[0].t).slice(0, 8)}`);
  console.log(`  UTC now : ${clock.rows[0].utc.toISOString().slice(0, 19)}`);
  console.log(`  Window  : ${DAYS} day(s) ahead`);
  console.log('');

  // 1. The table, before any filter. Separates "no rows" from "rows nobody sees".
  const raw = await pool.query(
    `SELECT COUNT(*)::int AS total,
            MIN(slot_date) AS oldest,
            MAX(slot_date) AS newest
       FROM slots`,
  );
  const bookable = await pool.query(grid.BOOKABLE_COUNT_SQL);
  console.log(`── Rows ─────────────────────────────────────────────────────────`);
  console.log(`  slots in table : ${raw.rows[0].total}`
    + `  (${raw.rows[0].oldest ? String(raw.rows[0].oldest).slice(0, 10) : '-'}`
    + ` .. ${raw.rows[0].newest ? String(raw.rows[0].newest).slice(0, 10) : '-'})`);
  console.log(`  bookable now   : ${bookable.rows[0].c}`);
  if (raw.rows[0].total > 0 && bookable.rows[0].c === 0) {
    console.log('  >>> Every slot has aged into the past. This is the window that');
    console.log('      jobs/slotMaintenanceJob.js exists to keep rolling — check that');
    console.log('      the API is running and that its boot sweep logged a line.');
    problems += 1;
  }
  console.log('');

  // 2. is_active, which decides whether a venue exists for a player at all.
  const venues = await pool.query(
    `SELECT v.id, v.name, v.is_active, v.price_per_hour, v.base_price,
            v.operating_hours_from, v.operating_hours_to,
            op.verification_status
       FROM venues v
       LEFT JOIN owner_profiles op ON op.user_id = v.owner_id
      ${VENUE ? 'WHERE v.id = $1' : ''}
      ORDER BY v.is_active DESC, v.name`,
    VENUE ? [VENUE] : [],
  );
  const inactive = venues.rows.filter((v) => !v.is_active);
  console.log(`── Venues ───────────────────────────────────────────────────────`);
  console.log(`  ${venues.rows.length} total, ${venues.rows.length - inactive.length} active`);
  for (const v of inactive) {
    console.log(`  >>> ${String(v.name).slice(0, 30)} is_active=false — invisible to players`);
    console.log(`      (an admin has to approve it; POST /owner/venues creates it inactive)`);
    problems += 1;
  }
  console.log('');

  // 3. The verification gate. A venue missing from this list is absent from the
  //    browse screen entirely, which looks nothing like "zero slots" and is the
  //    one failure mode a slot count can never reveal.
  const listed = await disc.searchVenues(null, { limit: 100 });
  const listedIds = new Set(listed.map((v) => String(v.id)));
  console.log(`── Player browse list (discoveryService.searchVenues) ───────────`);
  console.log(`  ${listed.length} venue(s) visible`);
  for (const v of venues.rows) {
    if (v.is_active && !listedIds.has(String(v.id))) {
      console.log(`  >>> ${String(v.name).slice(0, 30)} is active but NOT listed`);
      console.log(`      owner verification_status = ${v.verification_status ?? 'NULL'}`);
      console.log(`      (the gate passes 'approved' and NULL only)`);
      problems += 1;
    }
  }
  console.log('');

  // 4. The grid itself, day by day, through the same function the venue page calls.
  console.log(`── Slots per day (discoveryService.venueDetail) ─────────────────`);
  console.log(`  d0 is today in PKT and shows only hours that have not started.`);
  console.log('');
  for (const v of listed) {
    const counts = [];
    let free = 0;
    for (let off = 0; off < DAYS; off += 1) {
      const r = await disc.venueDetail(null, { venueId: v.id, date: pktDateStr(off) });
      if (!r.ok) {
        counts.push('ERR');
        continue;
      }
      counts.push(String(r.data.slots.length));
      free += r.data.slots.filter((s) => s.effective_status === 'available').length;
    }
    const empty = counts.filter((c) => c === '0').length;
    const flag = free === 0 ? '  <<< NOTHING BOOKABLE' : '';
    if (free === 0) problems += 1;
    console.log(`  ${String(v.name).slice(0, 26).padEnd(27)} ${counts.join(' ')}`);
    console.log(`  ${''.padEnd(27)} ${free} free over ${DAYS} day(s)`
      + `${empty ? `, ${empty} empty day(s)` : ''}${flag}`);
  }

  console.log('');
  console.log('════════════════════════════════════════════════════════════════');
  if (problems === 0) {
    console.log('  No backend problem found: the API is returning bookable slots.');
    console.log('');
    console.log('  If the phone still shows "No slots available", the fault is not');
    console.log('  in the data. Check, in this order:');
    console.log('    1. which API the build points at — API_BASE_URL on the');
    console.log('       --dart-define, and adb reverse tcp:3000 tcp:3000 if local;');
    console.log('    2. whether that API talks to this same database (a Render');
    console.log('       deployment has its own DATABASE_URL);');
    console.log('    3. the date selected on the venue page — late in the PKT');
    console.log('       evening today is legitimately empty while tomorrow is not.');
  } else {
    console.log(`  ${problems} problem(s) found — each is marked >>> or <<< above.`);
  }
  console.log('');
  return problems === 0 ? 0 : 1;
}

main()
  .then(async (code) => {
    await pool.end().catch(() => {});
    process.exit(code);
  })
  .catch(async (e) => {
    console.error('');
    console.error('Failed:', e.message);
    await pool.end().catch(() => {});
    process.exit(1);
  });
