/**
 * Slot window maintenance sweep
 *
 * Every active venue needs bookable hours for the next fortnight, permanently.
 * Nothing in the application produced that before this job: admin owner-approval,
 * POST /owner/venues and POST /owner/slots/generate each wrote a window once, at
 * the moment they ran, and then never again. A ground was therefore bookable for
 * exactly fourteen days from its creation and then silently stopped — the slots
 * did not vanish, they aged into the past, discoveryService correctly filtered
 * them out, and the venue page painted "No slots available" on a venue whose rows
 * were all still in the table. Restoring it meant running
 * scripts/add_future_slots.js by hand, which made the product's core function
 * depend on someone remembering to do that.
 *
 * This job is that script, on a timer. services/slotService.js owns the grid; the
 * sweep only decides when to ask for it and what to say about the answer.
 *
 * Why hourly rather than the five minutes the other sweeps use
 * POLICY.SWEEP_INTERVAL_MS exists for deadlines — an escrow release or a no-show
 * penalty is wrong if it is late. A slot window has no deadline of that kind: the
 * only moment it can change is PKT midnight, when the far edge of the horizon
 * moves one day out. An hourly sweep is therefore well inside the only tolerance
 * that exists, and costs one statement per active venue per hour.
 *
 * Why the horizon carries a spare day
 * The player's date strip offers HORIZON_DAYS dates. Generating exactly that many
 * would leave the last one empty for up to an hour after each PKT midnight — the
 * strip gains a day the instant the date changes, and the sweep would not have run
 * yet. One extra day means the reachable window is always already filled, so the
 * rollover is never visible.
 *
 * Idempotent, and safe against live data
 * Every insert is NOT EXISTS-guarded per slot and nothing is updated or deleted,
 * so a repeating sweep cannot disturb a booked hour, an hour an owner blocked, or
 * a live checkout hold. slotService's header sets that out in full.
 */

const slotService = require('../services/slotService');

/** One sweep an hour. The window's only real event is the PKT day rollover. */
const SWEEP_INTERVAL_MS = 60 * 60 * 1000;

/**
 * A spare day beyond what the player's date strip can reach, so the far edge of
 * the horizon is filled before it becomes reachable at PKT midnight.
 */
const SWEEP_HORIZON_DAYS = slotService.HORIZON_DAYS + 1;

/**
 * Run the first sweep shortly after boot rather than waiting out the interval.
 * A server starting with an aged-out window would otherwise serve an hour of
 * "No slots available" on every ground. Offset past the other jobs' 5-8s so the
 * connection pool is not contended the instant the server finishes booting.
 */
const BOOT_DELAY_MS = 12000;

/** One sweep at a time. A slow sweep must not overlap the next tick. */
let _running = false;

async function sweepSlotWindows() {
  if (_running) return;
  _running = true;
  try {
    const r = await slotService.ensureActiveVenueSlots({ days: SWEEP_HORIZON_DAYS });

    if (r.venues === 0) {
      console.log('[SlotMaintenanceJob] sweep: no active venues.');
      return;
    }

    // Venues that could not be filled are named individually. A silent skip here
    // would leave a ground permanently unbookable with nothing in the log to say
    // why, which is the failure this job was written to end. A venue whose
    // statement threw is separated from one whose data is unusable: the first is
    // this job's problem and the second is the owner's.
    const blocked = r.results.filter((v) => v.skippedVenue);
    for (const v of blocked) {
      if (v.failed) {
        console.error(`[SlotMaintenanceJob] ${v.name}: failed — ${v.reason}. Retried next sweep.`);
      } else {
        console.warn(`[SlotMaintenanceJob] ${v.name}: not filled — ${v.reason}.`);
      }
    }

    // The bookable count is the number the app will actually show, not a row
    // count that merely looks healthy; it is logged every sweep so the aged-out
    // case is visible in the terminal the moment it appears rather than on a
    // player's phone.
    const bookable = await slotService.countBookable();
    console.log(
      `[SlotMaintenanceJob] sweep: ${r.created} slot(s) created across `
      + `${r.venues} active venue(s)`
      + `${blocked.length ? `, ${blocked.length} skipped` : ''}`
      + ` — ${bookable} bookable now.`,
    );

    // Dynamic pricing rolls forward with the window: the price model reprices every
    // active venue's future available slots by hour (peak evenings cost more). This
    // is what turns the trained model from an owner-dashboard suggestion into prices
    // a player actually sees. Owner-overridden slots (price_source='owner') are left
    // untouched, and a slot whose model price cannot be set yet keeps its flat price.
    try {
      const priced = await slotService.repriceActiveVenues({});
      console.log(
        `[SlotMaintenanceJob] repriced ${priced.repriced} slot(s) `
        + `(${priced.bySource.model} by model, ${priced.bySource.heuristic} by heuristic).`,
      );
      if (priced.repriced === 0 && bookable > 0) {
        // Not fatal, but worth naming: either migration 030 is unapplied (the
        // price_source column is missing) or every venue is owner-priced.
        const firstReason = (priced.results.find((v) => v.reason) || {}).reason;
        if (firstReason) {
          console.warn(`[SlotMaintenanceJob] repricing set nothing — ${firstReason}.`);
        }
      }
    } catch (e) {
      console.error('[SlotMaintenanceJob] repricing failed:', e.message);
    }

    if (bookable === 0) {
      console.warn(
        '[SlotMaintenanceJob] Nothing is bookable platform-wide. Every active '
        + 'venue is missing a price, has a backwards operating-hours range, or '
        + 'failed; the lines above name which.',
      );
    }
  } catch (e) {
    // Never rethrow from a timer callback: an unhandled rejection here would take
    // the whole server down for something the next sweep would fix.
    console.error('[SlotMaintenanceJob] sweep failed:', e.message);
  } finally {
    _running = false;
  }
}

function startSlotMaintenanceJob() {
  console.log(
    `[SlotMaintenanceJob] Started — sweeps every ${SWEEP_INTERVAL_MS / 60000} min, `
    + `keeping ${SWEEP_HORIZON_DAYS} days of slots ahead in ${slotService.PKT_TIMEZONE}.`,
  );
  setTimeout(sweepSlotWindows, BOOT_DELAY_MS);
  setInterval(sweepSlotWindows, SWEEP_INTERVAL_MS);
}

module.exports = { startSlotMaintenanceJob, sweepSlotWindows, SWEEP_HORIZON_DAYS };
