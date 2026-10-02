/**
 * add_future_slots.js — fill every active venue's slot window on demand.
 *
 * Why this still exists
 * It is no longer required. jobs/slotMaintenanceJob.js keeps the rolling window
 * filled for every active venue while the API is running, which is what removed
 * the standing need to run this by hand — a venue used to be bookable only for
 * whatever fixed window the route that created it wrote once, and this script was
 * the sole cure when that window aged into the past.
 *
 * It is kept for the two cases the sweep cannot serve: filling the window
 * immediately rather than waiting for the next sweep, and asking what would be
 * created without writing anything (`--dry`). `--days` also reaches further ahead
 * than the sweep's horizon, which is occasionally useful for a demo.
 *
 * The grid itself lives in utils/slotGrid.js and the writes in
 * services/slotService.js; neither is duplicated here, so what this script
 * creates is byte-for-byte what the running server creates: additive only,
 * NOT EXISTS-guarded per slot, PKT wall-clock dates, and each venue's own
 * operating hours. Existing rows are never modified — a booked or blocked slot
 * stays exactly as it is — and nothing is ever deleted.
 *
 * USAGE
 *   node src/scripts/add_future_slots.js                  # 14 days, all active venues
 *   node src/scripts/add_future_slots.js --days 7
 *   node src/scripts/add_future_slots.js --venue <uuid>
 *   node src/scripts/add_future_slots.js --dry            # report, change nothing
 */

const pool = require('../db/pool');
const slotService = require('../services/slotService');

function argOf(flag, fallback) {
  const i = process.argv.indexOf(flag);
  if (i === -1 || i === process.argv.length - 1) return fallback;
  return process.argv[i + 1];
}

const DAYS = slotService.clampDays(argOf('--days', slotService.HORIZON_DAYS));
const VENUE = argOf('--venue', null);
const DRY = process.argv.includes('--dry');

async function main() {
  console.log('');
  console.log('═══ Add future slots ═══════════════════════════════════════════');
  console.log(`  Window : next ${DAYS} day(s) starting today (${slotService.PKT_TIMEZONE})`);
  console.log(`  Hours  : each venue's own, or `
    + `${String(slotService.FALLBACK_FROM_HOUR).padStart(2, '0')}:00-`
    + `${String(slotService.FALLBACK_TO_HOUR).padStart(2, '0')}:00 where it has none set`);
  console.log(DRY ? '  MODE   : --dry — nothing will be written' : '  MODE   : writing');
  console.log('');

  const r = await slotService.ensureActiveVenueSlots({
    days: DAYS,
    venueId: VENUE,
    dryRun: DRY,
  });

  if (r.venues === 0) {
    console.log(VENUE
      ? '  No active venue with that id.'
      : '  No active venues. Register an owner and add a venue first.');
    return 1;
  }

  for (const v of r.results) {
    const name = String(v.name).slice(0, 28).padEnd(29);
    if (v.skippedVenue) {
      console.log(`  ${name} skipped — ${v.reason}`);
      continue;
    }
    const window = slotService.describeWindow(v.fromHour, v.toHour);
    console.log(`  ${name} ${String(v.created).padStart(4)} ${DRY ? 'would be created' : 'created'}, `
      + `${String(v.skipped).padStart(4)} already there  (${window})`);
  }

  console.log('');
  console.log(`  ${DRY ? 'Would create' : 'Created'} ${r.created} slot(s); ${r.skipped} already existed.`);

  // The number that matters: what a player can book right now. Mirrors the API's
  // own filter (future dates, plus today only after now, PKT).
  const bookable = await slotService.countBookable();
  console.log('');
  console.log(`  Bookable right now (what the app will show): ${bookable}`);
  console.log(bookable > 0
    ? '  Booking tests can run.'
    : '  Still nothing bookable — check venue is_active, price, and operating hours.');
  console.log('');
  console.log('  The running API maintains this window hourly on its own');
  console.log('  (jobs/slotMaintenanceJob.js); this script is only a manual top-up.');
  console.log('');
  return 0;
}

main()
  .then(async (code) => {
    await pool.end().catch(() => {});
    process.exit(code);
  })
  .catch(async (e) => {
    console.error('');
    console.error('Failed:', e.message);
    console.error('   Nothing was deleted — this script only ever inserts.');
    await pool.end().catch(() => {});
    process.exit(1);
  });
