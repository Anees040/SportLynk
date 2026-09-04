/**
 * global_settings reader
 *
 * Migration 013 created `global_settings (key text PRIMARY KEY, value jsonb)` and
 * seeded four rows, but until now nothing read them. This module is the single
 * place that does, so a value like the ELO K-factor is tunable from the database
 * instead of being a literal buried in a route.
 *
 * Three things this has to get right, none of which are obvious:
 *
 *   1. Never throw. Settings are read on the hot path of verifying a match. If
 *      the settings table is missing, empty, or the connection blips, an ELO
 *      calculation must still happen with the documented defaults rather than
 *      500-ing a match the players already played. Every failure here degrades
 *      to DEFAULTS and logs once.
 *
 *   2. Scalars and objects both. The seeded rows are a mix: `elo` is a jsonb
 *      object (`{"base":1000,"k_factor":32}`) while `commission_pct` is a jsonb
 *      string (`'0'`). node-postgres parses jsonb automatically, so `value` arrives as
 *      an object, a string, or a number depending on the row. Callers get a
 *      typed accessor per setting rather than having to know which.
 *
 *   3. Clamp, don't trust. `global_settings` is admin-writable. A typo like
 *      `{"base":"abc"}` must not propagate NaN into a team's rating column,
 *      where it would poison every future match. Anything non-finite or out of
 *      a sane band falls back to the default for that field alone.
 *
 * Cached for TTL_MS because a match verification reads it once per request and
 * these values change roughly never. `invalidate()` exists so an admin settings
 * endpoint (S.7) can drop the cache the moment it writes.
 */

const pool = require('../db/pool');

/**
 * The values that ship in migration 013. Duplicated here deliberately: this is
 * the contract the code guarantees even with an empty table, so it must be
 * readable without opening the .sql file.
 */
const DEFAULTS = Object.freeze({
  elo: Object.freeze({ base: 1000, k_factor: 32 }),
  commission_pct: 0,
  deposit_pct: 20,
  sports_enabled: Object.freeze({ football: true, cricket: true }),
  assistant: Object.freeze({
    name: 'Scout',
    confidence_floor: 0.45,
    escalation_enabled: true,
    policy_text: Object.freeze({}),
  }),
  match: Object.freeze({
    challenge_ttl_hours: 48,   // FR5.12
    dispute_window_hours: 24,  // FR5.17
    dispute_freeze_ratio: 0.30, // ER2.3
    dispute_freeze_min: 3,     // ER2.3
  }),
  // Migration 019. These are the defaults a new tournament is created with, not
  // live policy: min_teams / prize_percent / winner_percent / runnerup_percent /
  // venue_discount_percent / slot_minutes are copied onto the tournament row at
  // create time, and the row wins from then on. A tournament already holding
  // captains' entry fees must not have its prize split changed underneath them.
  tournament: Object.freeze({
    min_teams: 4,
    prize_percent: 60,
    winner_percent: 70,
    runnerup_percent: 30,
    venue_discount_percent: 0,
    slot_minutes: 60,
    round_gap_days: 1,
    round_rest_minutes: 60,
    max_knockout_teams: 32,
    max_round_robin_teams: 6,
    target_margin_percent: 25,
    k_early: 40,
    k_semi: 48,
    k_final: 56,
  }),
});

const TTL_MS = 60_000;

/** key -> { value, at } */
const cache = new Map();

/** One log line per bad key, not one per request. */
const warned = new Set();

function warnOnce(key, message) {
  if (warned.has(key)) return;
  warned.add(key);
  console.warn(`[settings] ${key}: ${message}`);
}

/**
 * Read one row. Accepts an optional `client` so a caller already inside a
 * transaction reads through the same connection instead of grabbing a second one
 * from the pool (which, under load, is how a deadlock happens).
 */
async function readRow(key, client) {
  const q = 'SELECT value FROM global_settings WHERE key = $1';
  const runner = client || pool;
  const res = await runner.query(q, [key]);
  return res.rows.length ? res.rows[0].value : undefined;
}

/**
 * Raw setting value, cached. Returns DEFAULTS[key] when the row is absent or
 * unreadable. Never throws.
 */
async function get(key, { client = null, fresh = false } = {}) {
  const fallback = Object.prototype.hasOwnProperty.call(DEFAULTS, key)
    ? DEFAULTS[key]
    : undefined;

  if (!fresh) {
    const hit = cache.get(key);
    if (hit && Date.now() - hit.at < TTL_MS) return hit.value;
  }

  try {
    const value = await readRow(key, client);
    if (value === undefined || value === null) {
      // Absent row is not an error — it means "use the documented default".
      cache.set(key, { value: fallback, at: Date.now() });
      return fallback;
    }
    cache.set(key, { value, at: Date.now() });
    return value;
  } catch (e) {
    // A settings read must never be the reason a match cannot be verified.
    warnOnce(key, `read failed (${e.message}); using default`);
    return fallback;
  }
}

/** Coerce to a finite number inside [min, max], else `fallback`. */
function clampNum(raw, fallback, min, max) {
  const n = typeof raw === 'number' ? raw : Number.parseFloat(String(raw));
  if (!Number.isFinite(n)) return fallback;
  if (n < min || n > max) return fallback;
  return n;
}

/**
 * ELO parameters, already validated and camelCased for JS callers.
 *
 *   base     starting rating for a brand-new team  (teams.elo default 1000)
 *   kFactor  how violently one match can move a rating
 *
 * Bands are deliberately generous but finite: a K of 0 would freeze the whole
 * ladder silently, and a K of 10_000 would make one match meaningless-by-noise.
 * Either is far more likely to be a typo than an intention.
 */
async function elo({ client = null, fresh = false } = {}) {
  const raw = await get('elo', { client, fresh });
  const obj = raw && typeof raw === 'object' && !Array.isArray(raw) ? raw : {};

  return {
    base: Math.round(clampNum(obj.base, DEFAULTS.elo.base, 100, 5000)),
    kFactor: clampNum(obj.k_factor ?? obj.kFactor, DEFAULTS.elo.k_factor, 1, 200),
  };
}

/**
 * Platform commission as a percentage of a booking's price (FR10.9).
 *
 * Seeded 0, which is why nothing read this until now: at 0 there is nothing to
 * take. `routes/owner.js`'s QR check-in is the one place it applies — the moment
 * escrow is released is the moment the platform's cut is knowable and final.
 *
 * The clamp stops at 50 rather than 100 on purpose. A commission that takes the
 * whole slot price is not a business decision, it is a fat-fingered "100" where
 * "10" was meant, and it would credit a venue owner nothing for a game that was
 * played. An admin who genuinely wants more than half has to change this line.
 */
async function commission({ client = null, fresh = false } = {}) {
  const raw = await get('commission_pct', { client, fresh });
  return clampNum(raw, DEFAULTS.commission_pct, 0, 50);
}

/**
 * The player's at-risk deposit, as a percentage of the slot price (FR10.10).
 *
 * WHERE this is authoritative, AND WHERE it is not
 * Authoritative at one moment: `bookingService.createBooking` stamps
 * `bookings.deposit_amount` from it. Every refund afterwards works from that
 * stored amount (`escrow.penaltySplit(escrowHeld, depositAmount)`), so lowering
 * the percentage tomorrow cannot retroactively change what a player already
 * agreed to — which is the whole reason the amount is a column and not a formula.
 *
 * `escrow.POLICY.DEPOSIT_PERCENT` is the same number kept in sync for the ~30
 * places that only describe the policy ("20% of the total is at risk"). Copy that
 * disagrees with the row is worse than either value alone, so the settings writer
 * pushes it there (`escrow.setDepositPercent`) as well as into the cache.
 *
 * Floor 0 is legal — a venue network that wants no deposit at all is a real
 * configuration. Ceiling 100 is the full price, which is what escrow already
 * holds; above that the refund arithmetic would owe the player negative money.
 */
async function deposit({ client = null, fresh = false } = {}) {
  const raw = await get('deposit_pct', { client, fresh });
  return clampNum(raw, DEFAULTS.deposit_pct, 0, 100);
}

/**
 * Which sports may be booked or listed right now (FR10.9).
 *
 * Returned as a plain object of booleans keyed by the sport enum. A key that is
 * absent is treated as enabled by `isSportEnabled` below: adding `padel` to the
 * database enum must not silently disable it because nobody remembered to add a
 * `true` here.
 */
async function sportsEnabled({ client = null, fresh = false } = {}) {
  const raw = await get('sports_enabled', { client, fresh });
  const obj = raw && typeof raw === 'object' && !Array.isArray(raw) ? raw : {};
  const out = {};
  for (const [k, v] of Object.entries({ ...DEFAULTS.sports_enabled, ...obj })) {
    out[String(k).toLowerCase()] = v !== false;
  }
  return out;
}

/**
 * `false` only when an admin has explicitly switched this sport off.
 *
 * Fails OPEN, and that is deliberate: the cost of a wrongly-allowed booking is a
 * refund, the cost of a wrongly-blocked one is every player in the city being
 * told the app is broken. An unknown sport, an unreadable settings row and a
 * missing key all mean "allowed".
 */
async function isSportEnabled(sport, { client = null, fresh = false } = {}) {
  const key = String(sport || '').trim().toLowerCase();
  if (!key) return true;
  const map = await sportsEnabled({ client, fresh });
  return map[key] !== false;
}

/** Drop cached values so the next read hits the database. */
function invalidate(key) {
  if (key) cache.delete(key);
  else cache.clear();
}

/**
 * Match lifecycle timings (FR5.12, FR5.17, ER2.3), validated and camelCased.
 *
 *   challengeTtlHours   how long an unanswered challenge lives            (48)
 *   disputeWindowHours  how long after verification a result can be
 *                       disputed                                          (24)
 *   disputeFreezeRatio  fraction of a team's matches disputed by that team
 *                       that triggers a platform-wide ELO freeze         (0.30)
 *   disputeFreezeMin    minimum disputes before the ratio is even
 *                       considered, so a team that disputes its first and
 *                       only match is not frozen at 100%                    (3)
 *
 * The upper clamps matter more than they look. A TTL of 10_000 hours makes
 * challenges effectively immortal and the booking they pin unusable (the live
 * match per booking is UNIQUE); a freeze ratio of 0 would freeze every team that
 * ever raised one dispute. Both are typo shapes, not intentions.
 */
async function match({ client = null, fresh = false } = {}) {
  const raw = await get('match', { client, fresh });
  const obj = raw && typeof raw === 'object' && !Array.isArray(raw) ? raw : {};
  const d = DEFAULTS.match;

  return {
    challengeTtlHours: clampNum(
      obj.challenge_ttl_hours ?? obj.challengeTtlHours, d.challenge_ttl_hours, 1, 720,
    ),
    disputeWindowHours: clampNum(
      obj.dispute_window_hours ?? obj.disputeWindowHours, d.dispute_window_hours, 1, 720,
    ),
    disputeFreezeRatio: clampNum(
      obj.dispute_freeze_ratio ?? obj.disputeFreezeRatio, d.dispute_freeze_ratio, 0.01, 1,
    ),
    disputeFreezeMin: Math.round(clampNum(
      obj.dispute_freeze_min ?? obj.disputeFreezeMin, d.dispute_freeze_min, 1, 1000,
    )),
  };
}


/**
 * Scout's settings (S.6), validated and camelCased.
 *
 *   name              what the assistant calls itself in its own replies
 *   confidenceFloor   below this the dialog manager shows the capability menu
 *                     instead of guessing. A mirror of the artifact's threshold,
 *                     not the authority on it: the model applies its own floor
 *                     and reports it on every parse, so this value exists for the
 *                     UI copy and for an owner who wants Scout to be more
 *                     cautious than the artifact is — never to loosen it.
 *   escalationEnabled whether an unknown venue question may be forwarded to that
 *                     venue's owner. One switch, so a demo can turn the learning
 *                     loop off without a deploy.
 *   policyText        editable sentences with {placeholders}; the numbers are
 *                     substituted from escrow.js POLICY by utils/policyText.js.
 *
 * The clamp on confidenceFloor is [0.05, 0.95] for the same reason the ELO bands
 * are finite: 0 would route every stray utterance into a real action, and 1 would
 * make Scout answer nothing at all. Both are typo shapes.
 */
async function assistant({ client = null, fresh = false } = {}) {
  const raw = await get('assistant', { client, fresh });
  const obj = raw && typeof raw === 'object' && !Array.isArray(raw) ? raw : {};
  const d = DEFAULTS.assistant;

  const name = typeof obj.name === 'string' && obj.name.trim()
    ? obj.name.trim().slice(0, 40)
    : d.name;
  const policy = obj.policy_text ?? obj.policyText;

  return {
    name,
    confidenceFloor: clampNum(
      obj.confidence_floor ?? obj.confidenceFloor, d.confidence_floor, 0.05, 0.95,
    ),
    // Anything other than an explicit false leaves the loop on, so a partially
    // written settings row cannot silently disable a feature the docs claim.
    escalationEnabled: (obj.escalation_enabled ?? obj.escalationEnabled) !== false,
    policyText: policy && typeof policy === 'object' && !Array.isArray(policy) ? policy : {},
  };
}

/**
 * Tournament policy (migration 019), validated and camelCased.
 *
 * Read at two moments and no others: `create`, which copies the split onto the
 * new row, and `preview`, which quotes a recommended entry fee. Once a
 * tournament exists, `tournamentService` reads its COLUMNS, never this — see the
 * DEFAULTS comment for why.
 *
 * The clamps are the interesting part:
 *
 *   winnerPercent / runnerupPercent must sum to 100 or the prize pool either
 *   leaks money into nothing or pays out more than was collected. A pair that
 *   does not sum is rejected wholesale rather than field-by-field, because
 *   {"winner_percent": 80} alone is a half-finished edit, and honouring it with
 *   the default 30 would silently pay out 110% of the prize. `chk_tournaments_percents`
 *   would reject the row anyway; this turns a 500 into a sane default.
 *
 *   prizePercent may legitimately be 0 — a "the venue keeps the surplus" cup is
 *   a real configuration, not a typo — so its floor is 0, unlike the ELO K.
 *
 *   roundGapDays may be 0: a one-day cup plays every round on one date. That is
 *   the case fixtureSchedule.js schedules with PICK.EARLY.
 */
async function tournament({ client = null, fresh = false } = {}) {
  const raw = await get('tournament', { client, fresh });
  const obj = raw && typeof raw === 'object' && !Array.isArray(raw) ? raw : {};
  const d = DEFAULTS.tournament;
  const int = (a, b, key, min, max) => Math.round(clampNum(a ?? b, d[key], min, max));

  let winner = int(obj.winner_percent, obj.winnerPercent, 'winner_percent', 0, 100);
  let runnerUp = int(obj.runnerup_percent, obj.runnerupPercent, 'runnerup_percent', 0, 100);
  if (winner + runnerUp !== 100) {
    warnOnce('tournament.percents', `winner ${winner} + runner-up ${runnerUp} != 100; using defaults`);
    winner = d.winner_percent;
    runnerUp = d.runnerup_percent;
  }

  return {
    minTeams: int(obj.min_teams, obj.minTeams, 'min_teams', 2, 32),
    prizePercent: int(obj.prize_percent, obj.prizePercent, 'prize_percent', 0, 100),
    winnerPercent: winner,
    runnerupPercent: runnerUp,
    venueDiscountPercent: int(obj.venue_discount_percent, obj.venueDiscountPercent, 'venue_discount_percent', 0, 100),
    slotMinutes: int(obj.slot_minutes, obj.slotMinutes, 'slot_minutes', 15, 240),
    roundGapDays: int(obj.round_gap_days, obj.roundGapDays, 'round_gap_days', 0, 30),
    roundRestMinutes: int(obj.round_rest_minutes, obj.roundRestMinutes, 'round_rest_minutes', 0, 1440),
    maxKnockoutTeams: int(obj.max_knockout_teams, obj.maxKnockoutTeams, 'max_knockout_teams', 2, 32),
    maxRoundRobinTeams: int(obj.max_round_robin_teams, obj.maxRoundRobinTeams, 'max_round_robin_teams', 2, 12),
    targetMarginPercent: int(obj.target_margin_percent, obj.targetMarginPercent, 'target_margin_percent', 0, 200),
    kEarly: int(obj.k_early, obj.kEarly, 'k_early', 1, 200),
    kSemi: int(obj.k_semi, obj.kSemi, 'k_semi', 1, 200),
    kFinal: int(obj.k_final, obj.kFinal, 'k_final', 1, 200),
  };
}

module.exports = {
  DEFAULTS, get, clampNum, invalidate,
  // typed accessors, one per settings key
  elo, match, assistant, tournament,
  commission, deposit, sportsEnabled, isSportEnabled,
};
