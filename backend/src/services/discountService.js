/**
 * discountService.js — the owner's multi-slot discount ladder.
 *
 * One table, two operations: read a venue's tiers, and replace them. The
 * arithmetic that decides which tier applies and what a slot then costs is in
 * utils/slotGroup.js, which has no database attached and is unit-tested; this
 * file is the I/O.
 *
 * Why the table's absence is handled here rather than at the callers
 * `venue_slot_discounts` arrives with migration 035, and the player's venue page,
 * the booking quote and the booking itself all read it. A database where that
 * migration has not been applied must still sell slots at list price, so the
 * table's presence is probed once and a missing table reads as "this venue has no
 * discounts" — which is true, and is what every caller would do with an empty
 * list anyway. Doing it in one place keeps the four callers free of the special
 * case.
 *
 * A positive answer is cached for the life of the process because a table cannot
 * disappear. A negative answer is not cached, so applying the migration takes
 * effect without a restart.
 */
const pool = require('../db/pool');
const group = require('../utils/slotGroup');

let tablePresent = false;

async function hasTable(runner) {
  if (tablePresent) return true;
  const { rows } = await runner.query(
    `SELECT 1 FROM information_schema.tables
      WHERE table_schema = 'public' AND table_name = 'venue_slot_discounts'`,
  );
  tablePresent = rows.length === 1;
  return tablePresent;
}

/**
 * One venue's tiers, cheapest threshold first.
 *
 * `percent` is returned as a number rather than the string pg hands back for a
 * NUMERIC, so a caller can do arithmetic with it without remembering to parse.
 */
async function tiersFor(runner, venueId) {
  const db = runner || pool;
  const id = String(venueId == null ? '' : venueId).trim();
  if (!id) return [];
  if (!(await hasTable(db))) return [];
  const { rows } = await db.query(
    `SELECT min_slots, percent FROM venue_slot_discounts
      WHERE venue_id = $1 ORDER BY min_slots ASC`,
    [id],
  );
  return rows.map((r) => ({ min_slots: Number(r.min_slots), percent: Number(r.percent) }));
}

/**
 * Replace one venue's tiers with the given set.
 *
 * Replace rather than merge, because the ladder is edited as a whole on one
 * screen: an owner who removes a rule expects it gone, and a merge would leave it
 * standing with nothing in the UI to show why. The DELETE is filtered to the one
 * venue and reaches only rows that owner authored — it touches no booking, no
 * slot and no money.
 *
 * Validated before anything is written, so a form with four rows reports the one
 * that is wrong instead of a constraint violation for whichever row Postgres
 * happened to reach first.
 *
 * Caller supplies a transaction client when the replacement must be atomic; the
 * owner route does.
 */
async function setTiers(runner, { venueId, tiers }) {
  const db = runner || pool;
  const id = String(venueId == null ? '' : venueId).trim();
  if (!id) return { ok: false, code: 'missing_args', message: 'venueId required', tiers: [] };

  if (!(await hasTable(db))) {
    return {
      ok: false,
      code: 'migration_pending',
      message: 'Discounts are not available yet — migration 035 has not been applied to this database.',
      tiers: [],
    };
  }

  const checked = group.validateTiers(tiers);
  if (!checked.ok) return { ok: false, code: 'invalid_tier', message: checked.message, tiers: [] };

  await db.query('DELETE FROM venue_slot_discounts WHERE venue_id = $1', [id]);
  for (const tier of checked.tiers) {
    await db.query(
      `INSERT INTO venue_slot_discounts (venue_id, min_slots, percent) VALUES ($1, $2, $3)`,
      [id, tier.min_slots, tier.percent],
    );
  }
  return { ok: true, code: 'ok', message: null, tiers: checked.tiers };
}

/**
 * The sentence a venue page shows above its slot grid, or null when the venue has
 * no ladder. Composed here so the player app and Scout cannot describe the same
 * ladder differently.
 */
function describeTiers(tiers) {
  if (!tiers || !tiers.length) return null;
  const parts = tiers.map((t) => `${t.min_slots}+ slots ${t.percent}% off`);
  return `Book more, pay less: ${parts.join(' · ')}`;
}

module.exports = { tiersFor, setTiers, describeTiers };
