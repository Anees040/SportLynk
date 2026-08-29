/**
 * tournamentService.js — the only file that writes a tournament row.
 *
 * WHAT THIS MODULE OWNS
 * ---------------------
 * Every state change a tournament can undergo: it is created by a venue owner,
 * captains pay an entry fee into escrow, the deadline turns the field into a
 * seeded bracket standing on real venue slots, results settle fixture by fixture,
 * and the champion and runner-up are paid from the prize the owner is holding.
 * The routes validate shapes and the job supplies a clock; neither touches money.
 *
 * Every operation is `(client, args) -> { ok, status, code, message, data }` and
 * assumes it is ALREADY inside a transaction, exactly as bookingService does. The
 * `*Tx` wrappers at the bottom own BEGIN/COMMIT for callers that are not. A
 * failure returns `ok:false` with nothing undone, because the row locks belong to
 * the transaction and the caller's ROLLBACK is what releases them.
 *
 * THE MONEY MODEL, AND WHY IT IS A WATERFALL RATHER THAN A PERCENTAGE
 * ------------------------------------------------------------------
 * A straight "owner takes 30%" split is economically wrong here, because the pool
 * is variable and the venue's cost is FIXED. Eight teams at PKR 2,000 is a 16,000
 * pool, but a 7-fixture knockout consumes seven hours of inventory worth ~14,000
 * at the counter. A 30% commission would pay the owner 4,800 for hours they could
 * have sold for 14,000 — the tournament would LOSE them money, which inverts the
 * entire point of the feature. So the venue's own inventory is recovered first:
 *
 *     pool       = entry_fee x teams_accepted
 *     venue_cost = SUM(slots.price) over the fixtures' allocated slots
 *                  x (1 - venue_discount_percent)
 *     surplus    = pool - venue_cost
 *     prize      = surplus x prize_percent      (winner 70% / runner-up 30%)
 *     owner      = venue_cost + (surplus - prize)
 *
 * The owner is made whole on inventory BEFORE anyone else is paid, so a tournament
 * can never be worth less than selling the same hours. Teams pay ONE fee and never
 * book or pay for a tournament slot — which is why fixtures reserve slots instead
 * of writing `bookings` rows. `utils/fixtures.splitPool` is that arithmetic, in
 * paisa, unit-tested with the database down; this file only moves what it returns.
 *
 * UNDERWATER GUARD. If the pool does not cover the venue cost, the prize is zero
 * and the owner takes the whole pool. Money is never taken FROM the owner, and the
 * notification says so plainly. Below `min_teams`, the tournament is cancelled and
 * every captain refunded instead — a two-team "cup" is not worth anyone's evening.
 *
 * THE LEDGER, IN FOUR EVENTS
 * --------------------------
 *   register            captain  balance -E, frozen +E        tournament_entry
 *   withdraw / reject   captain  frozen -E, balance +E        refund
 *   fixtures generated  captains frozen -E (all of them)      escrow_release
 *                       owner    balance += venue_cost+margin tournament_commission
 *                       owner    frozen  += prize             tournament_prize
 *   final settled       owner    frozen  -= prize             escrow_release
 *                       winner   balance += winner_share      tournament_prize
 *                       runner-up balance += runnerup_share   tournament_prize
 *
 * The prize sits in the owner's FROZEN balance between those last two events, so a
 * withdrawal request cannot reach money that is already promised to a team. Every
 * row carries `transactions.tournament_id`, so the audit that matters — pool in
 * equals venue cost plus prize plus margin out, to the paisa — is one GROUP BY,
 * and check_tournaments.js asserts it rather than trusting the summary columns.
 *
 * TWO DOORS INTO ONE RESULT PATH
 * ------------------------------
 * A fixture can be settled two ways and they must not drift apart:
 *
 *   a. THE MATCH FLOW (S.2, unchanged). Captains submit scorelines, the organiser
 *      verifies, and `routes/matches.js` calls `advanceAfterMatch` inside the same
 *      transaction that applied ELO. ELO is applied by matches.js, not here — but
 *      with the K this module supplies through `matchContext`, so a final moves a
 *      rating harder than a friendly.
 *   b. THE ORGANISER (SRS FE-7). The owner types the score onto the fixture.
 *      `settleFixture` writes the `matches` row itself, applies ELO with the same
 *      K, and then runs the same advance path.
 *
 * Both funnel through `applyFixtureResult`, and both are idempotent: the fixture's
 * status is the latch here, `matches.elo_applied` is the latch for the rating.
 *
 * WHAT THIS FILE DELIBERATELY DOES NOT DO
 * ---------------------------------------
 *   - it never writes a `bookings` row for a fixture. jobs/noShowJob.js sweeps
 *     bookings and would dock the trust score of every captain in the tournament
 *     for not scanning a QR code at a fixture nobody asked them to check into;
 *   - it never invents a second ELO ladder. One ladder, weighted K;
 *   - it never decides WHERE a fixture is played. `utils/fixtures.js` decides who
 *     plays whom, `utils/fixtureSchedule.js` decides when, and
 *     `services/tournamentScheduler.js` reads the venue and asks the demand model.
 *     Scheduling policy living outside this file is what keeps it testable.
 */
const pool = require('../db/pool');
const fx = require('../utils/fixtures');
const plan = require('../utils/fixtureSchedule');
const scheduler = require('./tournamentScheduler');
const discovery = require('./discoveryService');
const settings = require('../utils/globalSettings');
const eloUtil = require('../utils/elo');
const mc = require('../utils/matchCore');
const { notify } = require('../utils/notify');
const {
  asNum, round2, lockWallet, applyWallet, logTxn,
} = require('../utils/escrow');
const {
  isUuid, squash, squashMultiline, validateSport,
} = require('../utils/teamAccess');

/** Tournament lifecycle, matching 019's chk_tournaments_status. */
const STATUS = Object.freeze({
  OPEN: 'open', ACTIVE: 'active', COMPLETED: 'completed', CANCELLED: 'cancelled',
});

/**
 * Registration lifecycle, matching 019's chk_tournament_teams_status.
 *
 * `registered` means "paid, awaiting the organiser's approval" and `accepted`
 * means "paid and in the field". A tournament with `requires_approval = false`
 * goes straight to `accepted`, which is why `discoveryService.listTournaments`
 * counts BOTH toward capacity: counting only one of them is how that function
 * came to report 0 spots taken for every tournament before this wave.
 */
const REG = Object.freeze({
  REGISTERED: 'registered', ACCEPTED: 'accepted', REJECTED: 'rejected',
  WITHDRAWN: 'withdrawn', ELIMINATED: 'eliminated',
});

/** The states that occupy a place in the field, and therefore hold a fee. */
const HOLDING = Object.freeze([REG.REGISTERED, REG.ACCEPTED]);

/** Ledger vocabulary — the three values migration 019 added to txn_type. */
const TXN = Object.freeze({
  ENTRY: 'tournament_entry',
  PRIZE: 'tournament_prize',
  COMMISSION: 'tournament_commission',
  REFUND: 'refund',
  RELEASE: 'escrow_release',
});

const NAME_MAX = 80;
const DESC_MAX = 600;

/** Uniform failure. `code` is for machines, `message` is for humans. */
function fail(status, code, message) {
  return { ok: false, status, code, message, data: null };
}

function done(status, data, message = null) {
  return { ok: true, status, code: 'ok', message, data };
}

/** pg DATE → 'YYYY-MM-DD' without a timezone round-trip. */
function dateStr(value) {
  if (value == null) return null;
  if (value instanceof Date) return value.toLocaleDateString('en-CA');
  const s = String(value);
  return /^\d{4}-\d{2}-\d{2}/.test(s) ? s.slice(0, 10) : null;
}

/** An ISO instant, or null. Used for every timestamptz that crosses the API. */
function iso(value) {
  if (value == null) return null;
  const d = value instanceof Date ? value : new Date(String(value));
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

// ─────────────────────────────────────────────────────────────────────────────
// READING
// ─────────────────────────────────────────────────────────────────────────────

/**
 * One tournament as every screen wants it: the row, the venue it consumes, the
 * organiser's name, and the two counts capacity is judged by.
 *
 * `teams_holding` is the count that fills the field — `registered` plus
 * `accepted`, because both have paid — while `teams_accepted` is the count that
 * will actually be seeded. They differ only while an approval-gated tournament
 * has decisions outstanding, and the browse screen needs the first while
 * generation needs the second.
 */
const T_COLUMNS = `
  t.id, t.owner_id, t.venue_id, t.name, t.description, t.sport, t.format,
  t.entry_fee, t.max_teams, t.min_teams, t.requires_approval,
  t.prize_percent, t.winner_percent, t.runnerup_percent, t.venue_discount_percent,
  t.slot_minutes, t.registration_deadline, t.start_date, t.status, t.rounds,
  t.winner_team, t.runner_up_team,
  t.pool_amount, t.venue_cost_amount, t.prize_amount, t.owner_earning_amount,
  t.fixtures_generated_at, t.activated_at, t.completed_at, t.cancelled_at,
  t.cancel_reason, t.created_at,
  v.name AS venue_name, v.city AS venue_city, v.address AS venue_address,
  v.sport_type AS venue_sport, v.rating AS venue_rating,
  v.price_per_hour AS venue_price_per_hour,
  u.name AS owner_name, u.phone AS owner_phone,
  wt.name AS winner_name, rt.name AS runner_up_name,
  (SELECT COUNT(*) FROM tournament_teams tt
    WHERE tt.tournament_id = t.id AND tt.status IN ('registered','accepted')) AS teams_holding,
  (SELECT COUNT(*) FROM tournament_teams tt
    WHERE tt.tournament_id = t.id AND tt.status = 'accepted') AS teams_accepted,
  (SELECT COUNT(*) FROM tournament_teams tt
    WHERE tt.tournament_id = t.id AND tt.status = 'registered') AS teams_pending`;

const T_FROM = `
  FROM tournaments t
  LEFT JOIN venues v ON v.id = t.venue_id
  LEFT JOIN users  u ON u.id = t.owner_id
  LEFT JOIN teams wt ON wt.id = t.winner_team
  LEFT JOIN teams rt ON rt.id = t.runner_up_team`;

/**
 * Load one tournament. `forUpdate` locks `tournaments` ONLY — the LEFT JOINs and
 * the counting sub-selects make `FOR UPDATE` illegal on the joined form, and
 * locking a venue row because someone opened a tournament page would be wrong
 * anyway. Money paths therefore lock in two steps: this row, then each wallet.
 */
async function loadTournament(client, id, { forUpdate = false } = {}) {
  if (!isUuid(id)) return null;
  if (forUpdate) {
    const lock = await client.query('SELECT id FROM tournaments WHERE id = $1 FOR UPDATE', [id]);
    if (!lock.rows.length) return null;
  }
  const r = await client.query(`SELECT ${T_COLUMNS} ${T_FROM} WHERE t.id = $1`, [id]);
  return r.rows[0] || null;
}

/** Registrations with the team, its rating and its captain. Ordered as seeded. */
async function loadRegistrations(client, tournamentId, { statuses = null } = {}) {
  const params = [tournamentId];
  let filter = '';
  if (Array.isArray(statuses) && statuses.length) {
    params.push(statuses);
    filter = ` AND tt.status = ANY($${params.length}::text[])`;
  }
  const r = await client.query(
    `SELECT tt.id AS registration_id, tt.tournament_id, tt.team_id, tt.status, tt.seed,
            tt.paid_amount, tt.created_at, tt.approved_at, tt.withdrawn_at, tt.eliminated_round,
            tm.name AS team_name, tm.logo_url, tm.city, tm.elo, tm.captain_id,
            tm.tournament_played, tm.tournament_wins, tm.finals_reached, tm.titles,
            u.name AS captain_name
       FROM tournament_teams tt
       JOIN teams tm ON tm.id = tt.team_id
       LEFT JOIN users u ON u.id = tm.captain_id
      WHERE tt.tournament_id = $1${filter}
      ORDER BY tt.seed NULLS LAST, tm.elo DESC, tt.created_at`,
    params,
  );
  return r.rows;
}

/** The bracket, with names and the reserved hour resolved for display. */
async function loadFixtures(client, tournamentId) {
  const r = await client.query(
    `SELECT f.id, f.tournament_id, f.round, f.position, f.label, f.is_bye,
            f.team_a, f.team_b, f.score_a, f.score_b, f.winner, f.status,
            f.played_at, f.match_id, f.slot_id, f.scheduled_at,
            f.next_round, f.next_position,
            ta.name AS team_a_name, ta.logo_url AS team_a_logo, ta.elo AS team_a_elo,
            tb.name AS team_b_name, tb.logo_url AS team_b_logo, tb.elo AS team_b_elo,
            to_char(s.slot_date, 'YYYY-MM-DD') AS slot_date, s.start_time, s.end_time, s.price
       FROM fixtures f
       LEFT JOIN teams ta ON ta.id = f.team_a
       LEFT JOIN teams tb ON tb.id = f.team_b
       LEFT JOIN slots s ON s.id = f.slot_id
      WHERE f.tournament_id = $1
      ORDER BY f.round, f.position`,
    [tournamentId],
  );
  return r.rows;
}

/** A team's captain, locked so a concurrent captaincy change cannot split a refund. */
async function captainOf(client, teamId) {
  const r = await client.query(
    'SELECT id, name, sport::text AS sport, captain_id, elo FROM teams WHERE id = $1',
    [teamId],
  );
  return r.rows[0] || null;
}

// ─────────────────────────────────────────────────────────────────────────────
// SHAPING — one reader per row type, so the API and the check script agree
// ─────────────────────────────────────────────────────────────────────────────

/**
 * The tournament as the app receives it. Money is `asNum`-ed here and nowhere
 * else, because pg hands back numeric(10,2) as a STRING and a single missed
 * coercion turns "2000" + "500" into "2000500" on a screen.
 */
function shapeTournament(row) {
  if (!row) return null;
  const holding = Number(row.teams_holding || 0);
  const accepted = Number(row.teams_accepted || 0);
  const deadline = iso(row.registration_deadline);
  const open = row.status === STATUS.OPEN
    && deadline != null && new Date(deadline).getTime() > Date.now()
    && holding < Number(row.max_teams);

  return {
    id: row.id,
    name: row.name,
    description: row.description || null,
    sport: row.sport,
    format: row.format,
    status: row.status,
    ownerId: row.owner_id,
    ownerName: row.owner_name || null,
    ownerPhone: row.owner_phone || null,
    venue: {
      id: row.venue_id,
      name: row.venue_name || null,
      city: row.venue_city || null,
      address: row.venue_address || null,
      sportType: row.venue_sport || null,
      rating: row.venue_rating == null ? null : asNum(row.venue_rating, 0),
      pricePerHour: row.venue_price_per_hour == null ? null : asNum(row.venue_price_per_hour, 0),
    },
    entryFee: asNum(row.entry_fee, 0),
    maxTeams: Number(row.max_teams),
    minTeams: Number(row.min_teams),
    requiresApproval: Boolean(row.requires_approval),
    teamsRegistered: holding,
    teamsAccepted: accepted,
    teamsPending: Number(row.teams_pending || 0),
    spotsLeft: Math.max(0, Number(row.max_teams) - holding),
    registrationDeadline: deadline,
    startDate: dateStr(row.start_date),
    rounds: row.rounds == null ? null : Number(row.rounds),
    slotMinutes: Number(row.slot_minutes || 60),
    registrationOpen: open,
    prizePercent: Number(row.prize_percent),
    winnerPercent: Number(row.winner_percent),
    runnerupPercent: Number(row.runnerup_percent),
    venueDiscountPercent: Number(row.venue_discount_percent),
    winnerTeam: row.winner_team || null,
    winnerName: row.winner_name || null,
    runnerUpTeam: row.runner_up_team || null,
    runnerUpName: row.runner_up_name || null,
    // Zero until fixtures are generated; from then on these are the settled
    // figures the ledger actually moved, not an estimate.
    pool: asNum(row.pool_amount, 0),
    venueCost: asNum(row.venue_cost_amount, 0),
    prize: asNum(row.prize_amount, 0),
    ownerEarning: asNum(row.owner_earning_amount, 0),
    fixturesGeneratedAt: iso(row.fixtures_generated_at),
    activatedAt: iso(row.activated_at),
    completedAt: iso(row.completed_at),
    cancelledAt: iso(row.cancelled_at),
    cancelReason: row.cancel_reason || null,
    createdAt: iso(row.created_at),
  };
}

function shapeRegistration(row) {
  return {
    registrationId: row.registration_id,
    teamId: row.team_id,
    teamName: row.team_name,
    logoUrl: row.logo_url || null,
    city: row.city || null,
    elo: Math.round(asNum(row.elo, 1000)),
    captainId: row.captain_id || null,
    captainName: row.captain_name || null,
    status: row.status,
    seed: row.seed == null ? null : Number(row.seed),
    paidAmount: asNum(row.paid_amount, 0),
    registeredAt: iso(row.created_at),
    approvedAt: iso(row.approved_at),
    withdrawnAt: iso(row.withdrawn_at),
    eliminatedRound: row.eliminated_round == null ? null : Number(row.eliminated_round),
    // The tournament record that replaces a second ELO ladder (019 on `teams`).
    record: {
      played: Number(row.tournament_played || 0),
      wins: Number(row.tournament_wins || 0),
      finals: Number(row.finals_reached || 0),
      titles: Number(row.titles || 0),
    },
  };
}

/**
 * One fixture. `winProbability` is the Elo formula, computed on read so a rating
 * change between generation and kickoff is reflected — and labelled in the UI as
 * the Elo formula, never as "ML", because it is arithmetic with no model in it.
 */
function shapeFixture(row) {
  const a = row.team_a_elo == null ? null : asNum(row.team_a_elo, 1000);
  const b = row.team_b_elo == null ? null : asNum(row.team_b_elo, 1000);
  const upcoming = row.status === fx.FIXTURE_STATUS.UPCOMING;
  return {
    id: row.id,
    round: Number(row.round),
    position: Number(row.position),
    label: row.label || null,
    isBye: Boolean(row.is_bye),
    status: row.status,
    teamA: row.team_a || null,
    teamAName: row.team_a_name || null,
    teamALogo: row.team_a_logo || null,
    teamAElo: a == null ? null : Math.round(a),
    teamB: row.team_b || null,
    teamBName: row.team_b_name || null,
    teamBLogo: row.team_b_logo || null,
    teamBElo: b == null ? null : Math.round(b),
    scoreA: row.score_a == null ? null : Number(row.score_a),
    scoreB: row.score_b == null ? null : Number(row.score_b),
    winner: row.winner || null,
    scoreline: row.score_a == null || row.score_b == null
      ? null : `${Number(row.score_a)} - ${Number(row.score_b)}`,
    matchId: row.match_id || null,
    slotId: row.slot_id || null,
    slotDate: row.slot_date || null,
    startTime: row.start_time || null,
    endTime: row.end_time || null,
    slotPrice: row.price == null ? null : asNum(row.price, 0),
    scheduledAt: iso(row.scheduled_at),
    playedAt: iso(row.played_at),
    nextRound: row.next_round == null ? null : Number(row.next_round),
    nextPosition: row.next_position == null ? null : Number(row.next_position),
    // Only for a fixture that has not been played: after the fact the scoreline is
    // the truth and a probability next to it reads like an excuse.
    winProbabilityA: upcoming && a != null && b != null ? fx.winProbability(a, b) : null,
    winProbabilityB: upcoming && a != null && b != null ? fx.winProbability(b, a) : null,
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// VALIDATION
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Validate a create/preview payload against the format's own rules.
 *
 * Every rule here is also a database CHECK in 019. That duplication is on purpose:
 * the CHECK is the guarantee and this is the error MESSAGE. A constraint violation
 * surfaces as `23514 chk_tournaments_max_teams`, which tells an owner nothing; the
 * sentence "Knockout needs a power of two: 2, 4, 8, 16 or 32" tells them what to
 * type instead.
 */
function validateConfig(input, policy) {
  const errors = [];
  const name = squash(input.name).slice(0, NAME_MAX);
  const description = input.description == null || String(input.description).trim() === ''
    ? null : squashMultiline(input.description).slice(0, DESC_MAX);

  if (!name || name.length < 3) errors.push('Give the tournament a name of at least 3 characters');

  const format = String(input.format || fx.FORMATS.KNOCKOUT).trim().toLowerCase();
  if (format !== fx.FORMATS.KNOCKOUT && format !== fx.FORMATS.ROUND_ROBIN) {
    errors.push('Format must be knockout or round_robin');
  }

  const maxTeams = Math.round(asNum(input.maxTeams, 0));
  if (format === fx.FORMATS.KNOCKOUT) {
    if (!fx.isPowerOfTwo(maxTeams) || maxTeams < 2 || maxTeams > fx.MAX_KNOCKOUT_TEAMS) {
      errors.push(`A knockout field must be a power of two: 2, 4, 8, 16 or ${fx.MAX_KNOCKOUT_TEAMS}`);
    }
  } else if (maxTeams < 2 || maxTeams > fx.MAX_ROUND_ROBIN_TEAMS) {
    // The cap is a revenue rule, not a technical one, so the message says why.
    errors.push(
      `Round-robin is capped at ${fx.MAX_ROUND_ROBIN_TEAMS} teams because it plays `
      + `n(n-1)/2 fixtures — ${fx.MAX_ROUND_ROBIN_TEAMS} teams is already `
      + `${fx.fixtureCount(fx.FORMATS.ROUND_ROBIN, fx.MAX_ROUND_ROBIN_TEAMS)} hours of your venue`,
    );
  }

  const minTeams = Math.round(asNum(input.minTeams, policy.minTeams));
  if (minTeams < 2 || (maxTeams >= 2 && minTeams > maxTeams)) {
    errors.push('The minimum field must be at least 2 and no more than the maximum');
  }

  const entryFee = round2(asNum(input.entryFee, 0));
  if (!(entryFee >= 0)) errors.push('The entry fee cannot be negative');

  const prizePercent = Math.round(asNum(input.prizePercent, policy.prizePercent));
  const winnerPercent = Math.round(asNum(input.winnerPercent, policy.winnerPercent));
  const runnerupPercent = Math.round(asNum(input.runnerupPercent, policy.runnerupPercent));
  const venueDiscountPercent = Math.round(asNum(input.venueDiscountPercent, policy.venueDiscountPercent));
  if (prizePercent < 0 || prizePercent > 100) errors.push('The prize share must be between 0 and 100 percent');
  if (venueDiscountPercent < 0 || venueDiscountPercent > 100) {
    errors.push('The venue discount must be between 0 and 100 percent');
  }
  if (winnerPercent + runnerupPercent !== 100) {
    errors.push('The winner and runner-up shares must add up to exactly 100 percent');
  }

  const slotMinutes = Math.round(asNum(input.slotMinutes, policy.slotMinutes));
  if (slotMinutes < 15 || slotMinutes > 240) errors.push('A fixture must be between 15 and 240 minutes');

  return {
    ok: errors.length === 0,
    errors,
    value: {
      name, description, format, maxTeams, minTeams, entryFee,
      prizePercent, winnerPercent, runnerupPercent, venueDiscountPercent, slotMinutes,
    },
  };
}

/** The deadline and start date, which only `create` needs (preview has no dates). */
function validateDates(input) {
  const errors = [];
  const raw = input.registrationDeadline == null ? '' : String(input.registrationDeadline).trim();
  const deadline = raw ? new Date(raw) : null;
  if (!deadline || Number.isNaN(deadline.getTime())) {
    errors.push('Give a registration deadline');
  } else if (deadline.getTime() <= Date.now()) {
    errors.push('The registration deadline must be in the future');
  }

  const startRaw = input.startDate == null ? '' : String(input.startDate).trim();
  const startDate = /^\d{4}-\d{2}-\d{2}$/.test(startRaw) ? startRaw : null;
  if (startRaw && !startDate) errors.push('The start date must be YYYY-MM-DD');
  // Fixtures are generated AT the deadline onto slots at or after it, so a start
  // date before the deadline is a promise the scheduler cannot keep.
  if (startDate && deadline && !Number.isNaN(deadline.getTime())
      && startDate < deadline.toISOString().slice(0, 10)) {
    errors.push('The tournament cannot start before registration closes');
  }
  return { ok: errors.length === 0, errors, value: { deadline, startDate } };
}

/**
 * The venue, and the organiser's right to use it. A tournament consumes a venue's
 * inventory for hours, so this is the one place the ownership check happens and
 * every write path goes through it.
 */
async function requireOwnedVenue(client, { venueId, ownerId }) {
  if (!isUuid(venueId)) return { error: fail(400, 'bad_venue', 'Choose a venue') };
  const r = await client.query(
    `SELECT ${scheduler.VENUE_COLUMNS}, owner_id, is_active, address
       FROM venues WHERE id = $1`,
    [venueId],
  );
  const venue = r.rows[0] || null;
  if (!venue) return { error: fail(404, 'venue_not_found', 'Venue not found') };
  if (String(venue.owner_id) !== String(ownerId)) {
    // Deliberately the same 403 an owner gets for someone else's venue: only
    // venue owners run tournaments, and they run them at their own grounds.
    return { error: fail(403, 'not_your_venue', 'You can only run a tournament at your own venue') };
  }
  if (venue.is_active === false) {
    return { error: fail(409, 'venue_inactive', 'Reactivate this venue before running a tournament here') };
  }
  return { venue };
}

// ─────────────────────────────────────────────────────────────────────────────
// PREVIEW — the economics quote, before the tournament exists (SRS FE-1)
// ─────────────────────────────────────────────────────────────────────────────

/** A field of n placeholder teams, all equal, purely to count and place fixtures. */
function pseudoField(n) {
  return Array.from({ length: Math.max(0, n) }, (_, i) => ({
    id: `preview-${i + 1}`, name: `Team ${i + 1}`, elo: 1000,
  }));
}

/**
 * preview — what this tournament would cost and earn, quoted from REAL slot prices.
 *
 * This endpoint exists because the waterfall only protects the owner if the owner
 * can see it before committing. Without it an owner types "PKR 2,000, 8 teams",
 * the deadline passes, and they discover they have sold seven hours worth 14,000
 * for a 16,000 pool. So `preview` schedules the bracket against the venue's actual
 * free hours, sums their actual prices, and hands back both the breakdown at the
 * fee they typed and a RECOMMENDED fee that clears the venue cost at the minimum
 * legal turnout.
 *
 * Two turnouts are scheduled, not one, because they cost different amounts: a
 * knockout plays n-1 fixtures, so a half-full field consumes half the inventory.
 * Quoting only the full field would over-recommend, and quoting only the minimum
 * would under-reserve. Both are real allocations over the same candidate slots —
 * one database read and, thanks to the hour-long demand cache, one model call.
 *
 * Writes nothing. It does not reserve, hold or block a single slot.
 */
async function preview(client, input = {}) {
  const policy = await settings.tournament({ client });
  const cfg = validateConfig(input, policy);
  if (!cfg.ok) return fail(400, 'invalid', cfg.errors[0]);

  const owned = await requireOwnedVenue(client, { venueId: input.venueId, ownerId: input.ownerId });
  if (owned.error) return owned.error;
  const { venue } = owned;

  const v = cfg.value;
  const deadline = input.registrationDeadline ? new Date(String(input.registrationDeadline)) : null;
  const notBefore = deadline && !Number.isNaN(deadline.getTime()) && deadline.getTime() > Date.now()
    ? deadline : null;

  const roundGapDays = Math.round(asNum(input.roundGapDays, policy.roundGapDays));
  const roundRestMinutes = Math.round(asNum(input.roundRestMinutes, policy.roundRestMinutes));
  const scan = await scheduler.candidateSlots(client, { venueId: venue.id, notBefore });

  const runFor = (teams) => scheduler.schedule(client, {
    venue,
    slots: scan.slots,
    fixtures: fx.buildFixtures(v.format, fx.seedTeams(pseudoField(teams))).fixtures,
    format: v.format,
    notBefore,
    slotMinutes: v.slotMinutes,
    roundGapDays,
    roundRestMinutes,
    useModel: input.useModel !== false,
  });

  const full = await runFor(v.maxTeams);
  const floor = v.minTeams === v.maxTeams ? full : await runFor(v.minTeams);

  // When the venue does not yet have enough free hours, the quote must still be
  // useful — an owner who has not opened their slots for next week needs to see
  // the shape of the deal AND the reason it cannot be scheduled yet. So the cost
  // falls back to list price x fixtures, clearly flagged as an estimate.
  const listPrice = asNum(venue.price_per_hour ?? venue.base_price, 0);
  const hoursFor = (teams) => fx.fixtureCount(v.format, teams);
  const costOf = (alloc, teams) => (alloc.ok
    ? asNum(alloc.slotTotal, 0)
    : round2(listPrice * hoursFor(teams) * (v.slotMinutes / 60)));

  const fullCost = costOf(full, v.maxTeams);
  const floorCost = costOf(floor, v.minTeams);

  const atCapacity = fx.splitPool({
    entryFee: v.entryFee, teams: v.maxTeams, slotTotal: fullCost,
    venueDiscountPercent: v.venueDiscountPercent, prizePercent: v.prizePercent,
    winnerPercent: v.winnerPercent, runnerupPercent: v.runnerupPercent,
  });
  const atMinimum = fx.splitPool({
    entryFee: v.entryFee, teams: v.minTeams, slotTotal: floorCost,
    venueDiscountPercent: v.venueDiscountPercent, prizePercent: v.prizePercent,
    winnerPercent: v.winnerPercent, runnerupPercent: v.runnerupPercent,
  });
  // Recommended from the WORST legal turnout, because that is the case a fee has
  // to survive. A fee that only works with a full field is a fee that loses money
  // the first time six teams turn up instead of eight.
  const recommended = fx.recommendEntryFee({
    slotTotal: floorCost, venueDiscountPercent: v.venueDiscountPercent,
    minTeams: v.minTeams, prizePercent: v.prizePercent,
    winnerPercent: v.winnerPercent, runnerupPercent: v.runnerupPercent,
    targetMarginPercent: Math.round(asNum(input.targetMarginPercent, policy.targetMarginPercent)),
  });

  const summarise = (alloc, teams) => ({
    schedulable: alloc.ok === true,
    code: alloc.code,
    message: alloc.ok ? null : alloc.message,
    shortfall: alloc.shortfall || null,
    teams,
    fixtures: hoursFor(teams),
    byes: Array.isArray(alloc.byes) ? alloc.byes.length : 0,
    hoursNeeded: alloc.need == null ? hoursFor(teams) : alloc.need,
    hoursAvailable: alloc.available == null ? scan.slots.length : alloc.available,
    slotTotal: alloc.ok ? asNum(alloc.slotTotal, 0) : null,
    estimatedCost: alloc.ok ? null : costOf(alloc, teams),
    firstAt: alloc.firstAt || null,
    lastAt: alloc.lastAt || null,
    startDate: alloc.startDate || null,
    endDate: alloc.endDate || null,
    rounds: (alloc.rounds || []).map((r) => ({
      round: r.round, label: r.label, pick: r.pick, date: r.date,
      count: r.count, total: r.total, spansDays: r.spansDays,
    })),
  });

  return done(200, {
    venue: {
      id: venue.id, name: venue.name, city: venue.city,
      sportType: venue.sport_type, pricePerHour: listPrice,
    },
    config: { ...v, roundGapDays, roundRestMinutes },
    capacity: summarise(full, v.maxTeams),
    minimum: summarise(floor, v.minTeams),
    economics: { atCapacity, atMinimum },
    recommended,
    candidateHours: scan.slots.length,
    scan: { from: scan.from, until: scan.until, horizonDays: scan.horizonDays },
    meta: full.meta,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// CREATE (SRS FE-1)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * create — an owner posts a tournament at one of their own venues.
 *
 * The prize split is COPIED onto the row from `global_settings.tournament` (or
 * from what the owner typed) rather than read live at payout time. That is the
 * single most important line in this function: a tournament already holding eight
 * captains' entry fees must not have its prize percentage changed underneath the
 * teams that paid into it, and an admin editing the global default must not
 * silently rewrite every open tournament's terms.
 *
 * Feasibility is CHECKED but not ENFORCED. If the venue has no free hours yet the
 * tournament is still created, with a warning, because opening next week's slots
 * is a thing an owner does after posting a cup — refusing here would force them to
 * do those two jobs in an order nobody would guess. The deadline job refuses to
 * generate rather than half-schedule, so nothing can be sold that cannot be played.
 */
async function create(client, input = {}) {
  const policy = await settings.tournament({ client });
  const cfg = validateConfig(input, policy);
  if (!cfg.ok) return fail(400, 'invalid', cfg.errors[0]);
  const dates = validateDates(input);
  if (!dates.ok) return fail(400, 'invalid', dates.errors[0]);

  const owned = await requireOwnedVenue(client, { venueId: input.venueId, ownerId: input.ownerId });
  if (owned.error) return owned.error;
  const { venue } = owned;

  // Teams exist in exactly two sports, so a tournament in a third is a tournament
  // nobody can enter. The venue's own sport is the default; an explicit value wins.
  const sport = validateSport(input.sport || venue.sport_type);
  if (!sport.ok) return fail(400, 'bad_sport', sport.message);

  const v = cfg.value;
  const ins = await client.query(
    `INSERT INTO tournaments
       (owner_id, venue_id, name, description, sport, format, entry_fee,
        max_teams, min_teams, requires_approval, registration_deadline, start_date,
        prize_percent, winner_percent, runnerup_percent, venue_discount_percent,
        slot_minutes, status)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,'open')
     RETURNING id`,
    [
      input.ownerId, venue.id, v.name, v.description, sport.value, v.format, v.entryFee,
      v.maxTeams, v.minTeams, input.requiresApproval === true, dates.value.deadline,
      dates.value.startDate, v.prizePercent, v.winnerPercent, v.runnerupPercent,
      v.venueDiscountPercent, v.slotMinutes,
    ],
  );
  const id = ins.rows[0].id;

  // A read-only feasibility probe. `useModel:false` on purpose — this answers
  // "are there enough hours?", which is arithmetic, and spending a model call to
  // answer it would make creating a tournament depend on the ml-service being up.
  const probe = await scheduler.schedule(client, {
    venue,
    fixtures: fx.buildFixtures(v.format, fx.seedTeams(pseudoField(v.maxTeams))).fixtures,
    format: v.format,
    notBefore: dates.value.deadline,
    slotMinutes: v.slotMinutes,
    roundGapDays: policy.roundGapDays,
    roundRestMinutes: policy.roundRestMinutes,
    useModel: false,
  });

  const row = await loadTournament(client, id);
  return done(201, {
    tournament: shapeTournament(row),
    feasibility: {
      schedulable: probe.ok === true,
      hoursNeeded: probe.need == null ? fx.fixtureCount(v.format, v.maxTeams) : probe.need,
      hoursAvailable: probe.available == null ? 0 : probe.available,
      shortfall: probe.shortfall || null,
      warning: probe.ok ? null : probe.message,
      estimatedVenueCost: probe.ok ? asNum(probe.slotTotal, 0) : null,
    },
  }, probe.ok ? null : probe.message);
}

// ─────────────────────────────────────────────────────────────────────────────
// MONEY — three helpers, so a fee is charged, refunded and released in one place
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Move the entry fee from a captain's spendable balance into escrow.
 *
 * The wallet is locked FOR UPDATE by `lockWallet` before the balance is read, so
 * two teammates hitting Register on two phones cannot both pass the sufficiency
 * check against the same balance. The fee is FROZEN rather than paid: until the
 * bracket exists there is nothing to pay for, and a tournament that never reaches
 * `min_teams` has to give every paisa back.
 */
async function chargeEntry(client, { tournament, captainId, teamName, fee }) {
  if (!(fee > 0)) return { ok: true, wallet: null };
  const wallet = await lockWallet(client, captainId);
  if (!wallet) return { error: fail(404, 'no_wallet', 'The captain has no wallet yet') };
  const balance = asNum(wallet.balance, 0);
  if (round2(balance) + 0.001 < round2(fee)) {
    return {
      error: fail(409, 'insufficient_funds',
        `Entry is PKR ${round2(fee)} but the captain's wallet holds PKR ${round2(balance)}. Top up and try again.`),
    };
  }
  const after = await applyWallet(client, wallet.id, { balance: -fee, frozen: fee });
  await logTxn(client, {
    walletId: wallet.id,
    userId: captainId,
    bookingId: null,
    tournamentId: tournament.id,
    type: TXN.ENTRY,
    amount: -fee,
    balanceAfter: after.balance,
    description: `${tournament.name} entry fee — ${teamName} (held in escrow)`,
    counterparty: tournament.venue_name || tournament.name,
  });
  return { ok: true, wallet, after };
}

/** Give a held fee back. Used by withdraw, reject, remove, and cancel-and-refund-all. */
async function refundEntry(client, { tournament, captainId, teamName, amount, reason }) {
  const fee = round2(asNum(amount, 0));
  if (!(fee > 0) || !captainId) return { ok: true };
  const wallet = await lockWallet(client, captainId);
  if (!wallet) return { ok: true };
  const after = await applyWallet(client, wallet.id, { balance: fee, frozen: -fee });
  await logTxn(client, {
    walletId: wallet.id,
    userId: captainId,
    bookingId: null,
    tournamentId: tournament.id,
    type: TXN.REFUND,
    amount: fee,
    balanceAfter: after.balance,
    description: `${tournament.name} — ${reason} (${teamName})`,
    counterparty: tournament.venue_name || tournament.name,
  });
  return { ok: true, after };
}

// ─────────────────────────────────────────────────────────────────────────────
// REGISTER / WITHDRAW  (SRS FE-3, FE-4)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * register — a captain enters their team and pays the entry fee.
 *
 * Only the CAPTAIN may register, for the same reason only the captain may book: the
 * fee comes out of one person's wallet, and a squad member spending their captain's
 * money is not a feature. FE-4's two automatic enforcements both live here — the
 * deadline and the participant cap — and both are re-checked under the tournament's
 * row lock, because "there was one spot left when the screen rendered" is precisely
 * the race a cap has to survive.
 *
 * A team that previously withdrew may re-enter while the tournament is still open;
 * the existing row is reused so `UNIQUE (tournament_id, team_id)` holds.
 */
async function register(client, { userId, tournamentId, teamId } = {}) {
  if (!isUuid(teamId)) return fail(400, 'bad_team', 'Choose a team');
  const t = await loadTournament(client, tournamentId, { forUpdate: true });
  if (!t) return fail(404, 'not_found', 'Tournament not found');
  if (t.status !== STATUS.OPEN) {
    return fail(409, 'not_open', t.status === STATUS.CANCELLED
      ? 'This tournament was cancelled'
      : 'Registration for this tournament has closed');
  }
  if (new Date(t.registration_deadline).getTime() <= Date.now()) {
    return fail(409, 'deadline_passed', 'The registration deadline has passed');
  }

  const team = await captainOf(client, teamId);
  if (!team) return fail(404, 'team_not_found', 'Team not found');
  if (String(team.captain_id || '') !== String(userId)) {
    return fail(403, 'not_captain', 'Only the team captain can enter a tournament');
  }
  if (String(team.sport) !== String(t.sport)) {
    return fail(409, 'sport_mismatch', `${team.name} plays ${team.sport}; this is a ${t.sport} tournament`);
  }

  const existing = await client.query(
    'SELECT id, status, paid_amount FROM tournament_teams WHERE tournament_id = $1 AND team_id = $2 FOR UPDATE',
    [t.id, teamId],
  );
  const prior = existing.rows[0] || null;
  if (prior && HOLDING.includes(prior.status)) {
    return fail(409, 'already_registered', `${team.name} is already entered`);
  }
  if (prior && prior.status === REG.REJECTED) {
    return fail(409, 'rejected', 'The organiser did not accept this team into the tournament');
  }

  // The cap is counted under the lock, and counts both holding states: an
  // approval-gated tournament with 8 pending teams is FULL, not empty.
  const held = await client.query(
    `SELECT COUNT(*)::int AS n FROM tournament_teams
      WHERE tournament_id = $1 AND status = ANY($2::text[])`,
    [t.id, HOLDING],
  );
  if (held.rows[0].n >= Number(t.max_teams)) {
    return fail(409, 'full', 'This tournament is full');
  }

  const fee = asNum(t.entry_fee, 0);
  const charged = await chargeEntry(client, {
    tournament: t, captainId: userId, teamName: team.name, fee,
  });
  if (charged.error) return charged.error;

  const nextStatus = t.requires_approval ? REG.REGISTERED : REG.ACCEPTED;
  if (prior) {
    await client.query(
      `UPDATE tournament_teams
          SET status = $1, paid_amount = $2, withdrawn_at = NULL, seed = NULL,
              eliminated_round = NULL, approved_at = CASE WHEN $1 = 'accepted' THEN now() ELSE NULL END,
              created_at = now()
        WHERE id = $3`,
      [nextStatus, fee, prior.id],
    );
  } else {
    await client.query(
      `INSERT INTO tournament_teams (tournament_id, team_id, status, paid_amount, approved_at)
       VALUES ($1,$2,$3,$4, CASE WHEN $3 = 'accepted' THEN now() ELSE NULL END)`,
      [t.id, teamId, nextStatus, fee],
    );
  }

  await notify(client, {
    userId,
    type: 'tournament_registered',
    title: t.requires_approval ? 'Entry submitted' : 'You are in',
    body: t.requires_approval
      ? `${team.name} is awaiting the organiser's approval for ${t.name}. PKR ${round2(fee)} is held until they decide.`
      : `${team.name} is entered in ${t.name}. PKR ${round2(fee)} is held until the bracket is drawn.`,
    payload: { tournamentId: t.id, teamId, fee: round2(fee) },
  });
  if (t.owner_id && String(t.owner_id) !== String(userId)) {
    await notify(client, {
      userId: t.owner_id,
      type: 'tournament_entry_received',
      title: t.requires_approval ? 'A team needs your approval' : 'A team entered your tournament',
      body: `${team.name} entered ${t.name} (${held.rows[0].n + 1}/${t.max_teams}).`,
      payload: { tournamentId: t.id, teamId, needsApproval: Boolean(t.requires_approval) },
    });
  }

  const fresh = await loadTournament(client, t.id);
  return done(201, {
    tournament: shapeTournament(fresh),
    registration: {
      teamId, teamName: team.name, status: nextStatus, paidAmount: round2(fee),
      requiresApproval: Boolean(t.requires_approval),
    },
  }, t.requires_approval
    ? `Entry submitted — PKR ${round2(fee)} held pending the organiser's approval`
    : `${team.name} is in. PKR ${round2(fee)} held in escrow.`);
}

/**
 * withdraw — a captain pulls their team out and gets the fee back.
 *
 * Allowed only while the tournament is still `open`. Once fixtures exist the fee
 * has already been released to the organiser and the bracket has a hole in it, so
 * withdrawing then would mean either clawing money back from the owner or paying a
 * refund out of the prize the remaining teams are playing for. Both are worse than
 * a plain "too late", which is what this returns.
 */
async function withdraw(client, { userId, tournamentId, teamId } = {}) {
  if (!isUuid(teamId)) return fail(400, 'bad_team', 'Choose a team');
  const t = await loadTournament(client, tournamentId, { forUpdate: true });
  if (!t) return fail(404, 'not_found', 'Tournament not found');

  const reg = await client.query(
    `SELECT tt.id, tt.status, tt.paid_amount, tm.name AS team_name, tm.captain_id
       FROM tournament_teams tt JOIN teams tm ON tm.id = tt.team_id
      WHERE tt.tournament_id = $1 AND tt.team_id = $2 FOR UPDATE OF tt`,
    [t.id, teamId],
  );
  const row = reg.rows[0];
  if (!row) return fail(404, 'not_registered', 'That team is not entered in this tournament');
  if (String(row.captain_id || '') !== String(userId)) {
    return fail(403, 'not_captain', 'Only the team captain can withdraw the team');
  }
  if (!HOLDING.includes(row.status)) {
    return fail(409, 'not_active', `That entry is already ${row.status}`);
  }
  if (t.status !== STATUS.OPEN || t.fixtures_generated_at) {
    return fail(409, 'too_late',
      'The bracket has already been drawn — the entry fee has been paid out to the organiser and cannot be withdrawn');
  }

  await refundEntry(client, {
    tournament: t, captainId: userId, teamName: row.team_name,
    amount: row.paid_amount, reason: 'entry withdrawn, fee refunded',
  });
  await client.query(
    `UPDATE tournament_teams SET status = 'withdrawn', withdrawn_at = now(), seed = NULL
      WHERE id = $1`,
    [row.id],
  );
  await notify(client, {
    userId,
    type: 'tournament_withdrawn',
    title: 'Entry withdrawn',
    body: `${row.team_name} has been withdrawn from ${t.name}. PKR ${round2(asNum(row.paid_amount, 0))} is back in your wallet.`,
    payload: { tournamentId: t.id, teamId },
  });
  if (t.owner_id) {
    await notify(client, {
      userId: t.owner_id,
      type: 'tournament_team_withdrew',
      title: 'A team withdrew',
      body: `${row.team_name} withdrew from ${t.name}.`,
      payload: { tournamentId: t.id, teamId },
    });
  }
  const fresh = await loadTournament(client, t.id);
  return done(200, {
    tournament: shapeTournament(fresh),
    refunded: round2(asNum(row.paid_amount, 0)),
  }, `Withdrawn — PKR ${round2(asNum(row.paid_amount, 0))} refunded`);
}

// ─────────────────────────────────────────────────────────────────────────────
// ORGANISER TEAM MANAGEMENT (SRS FE-5)
// ─────────────────────────────────────────────────────────────────────────────

/** The three things an organiser may do to an entry. */
const DECISION = { APPROVE: 'approve', REJECT: 'reject', REMOVE: 'remove' };

/**
 * ownerDecision — approve, reject or remove a registered team.
 *
 * FE-5 asks for "approval and removal", and the money makes the difference
 * between the two verbs matter:
 *
 *   approve  → the entry becomes `accepted`; the fee stays frozen (it is released
 *              to the organiser when the bracket is drawn, not before).
 *   reject   → the entry becomes `rejected` and the fee is refunded IN FULL. A
 *              team the organiser turned away must never be out of pocket, which
 *              is also why `register` refuses to let a rejected team pay again.
 *   remove   → identical money, different word and different notification. Used
 *              after an entry was already accepted.
 *
 * Both refusals are only possible while the tournament is still `open`. Once the
 * bracket exists a team is IN it, and removing a side from a drawn bracket would
 * mean either a hole in round 1 or re-drawing a tournament people have already
 * travelled for; the honest answer is a walkover, which `walkover` provides.
 */
async function ownerDecision(client, {
  ownerId, tournamentId, teamId, decision, reason = null,
} = {}) {
  const verb = String(decision || '').trim().toLowerCase();
  if (!Object.values(DECISION).includes(verb)) {
    return fail(400, 'bad_decision', 'Choose approve, reject or remove');
  }
  if (!isUuid(teamId)) return fail(400, 'bad_team', 'Choose a team');

  const t = await loadTournament(client, tournamentId, { forUpdate: true });
  if (!t) return fail(404, 'not_found', 'Tournament not found');
  if (String(t.owner_id || '') !== String(ownerId)) {
    return fail(403, 'not_organiser', 'Only the organiser can manage this tournament');
  }
  if (t.status !== STATUS.OPEN || t.fixtures_generated_at) {
    return fail(409, 'too_late',
      'The bracket has already been drawn — use a walkover to settle a team that cannot play');
  }

  const reg = await client.query(
    `SELECT tt.id, tt.status, tt.paid_amount, tm.name AS team_name, tm.captain_id
       FROM tournament_teams tt JOIN teams tm ON tm.id = tt.team_id
      WHERE tt.tournament_id = $1 AND tt.team_id = $2 FOR UPDATE OF tt`,
    [t.id, teamId],
  );
  const row = reg.rows[0];
  if (!row) return fail(404, 'not_registered', 'That team is not entered in this tournament');
  if (!HOLDING.includes(row.status)) {
    return fail(409, 'not_active', `That entry is already ${row.status}`);
  }

  const note = squash(reason || '').slice(0, 200) || null;

  if (verb === DECISION.APPROVE) {
    if (row.status === REG.ACCEPTED) {
      return fail(409, 'already_accepted', `${row.team_name} is already accepted`);
    }
    await client.query(
      `UPDATE tournament_teams SET status = 'accepted', approved_at = now() WHERE id = $1`,
      [row.id],
    );
    if (row.captain_id) {
      await notify(client, {
        userId: row.captain_id,
        type: 'tournament_accepted',
        title: 'Your team is in',
        body: `${row.team_name} has been accepted into ${t.name}. The bracket is drawn when registration closes.`,
        payload: { tournamentId: t.id, teamId },
      });
    }
    const fresh = await loadTournament(client, t.id);
    return done(200, { tournament: shapeTournament(fresh), teamId, status: REG.ACCEPTED },
      `${row.team_name} accepted`);
  }

  // reject | remove — both refund, and both say who did it and why.
  const refunded = round2(asNum(row.paid_amount, 0));
  if (refunded > 0) {
    await refundEntry(client, {
      tournament: t, captainId: row.captain_id, teamName: row.team_name,
      amount: refunded,
      reason: verb === DECISION.REJECT ? 'entry not accepted, fee refunded' : 'removed by organiser, fee refunded',
    });
  }
  const nextStatus = verb === DECISION.REJECT ? REG.REJECTED : REG.WITHDRAWN;
  await client.query(
    `UPDATE tournament_teams
        SET status = $1, withdrawn_at = now(), approved_at = NULL, seed = NULL
      WHERE id = $2`,
    [nextStatus, row.id],
  );
  if (row.captain_id) {
    await notify(client, {
      userId: row.captain_id,
      type: verb === DECISION.REJECT ? 'tournament_rejected' : 'tournament_removed',
      title: verb === DECISION.REJECT ? 'Entry not accepted' : 'Removed from tournament',
      body: `${row.team_name} ${verb === DECISION.REJECT ? 'was not accepted into' : 'has been removed from'} ${t.name}`
        + `${note ? ` — ${note}` : ''}. PKR ${refunded} has been refunded.`,
      payload: { tournamentId: t.id, teamId, refunded, reason: note },
    });
  }
  const fresh = await loadTournament(client, t.id);
  return done(200, {
    tournament: shapeTournament(fresh), teamId, status: nextStatus, refunded,
  }, `${row.team_name} ${verb === DECISION.REJECT ? 'rejected' : 'removed'} — PKR ${refunded} refunded`);
}

// ─────────────────────────────────────────────────────────────────────────────
// CANCEL — the only path that gives every rupee back
// ─────────────────────────────────────────────────────────────────────────────

/**
 * refundEveryone — release every holding entry's fee and mark the entries.
 *
 * Shared by `cancel` (the organiser calls it off) and by the deadline job's
 * under-minimum path, because those two are the same event from different
 * directions and a second implementation of "give everyone their money back" is
 * the last thing this file needs.
 *
 * Every refund is one `applyWallet` + one `refund` ledger row per captain, under
 * that captain's wallet lock. Two teams sharing a captain therefore produce two
 * rows, which is correct: they paid two fees.
 */
async function refundEveryone(client, { tournament, reason }) {
  const regs = await loadRegistrations(client, tournament.id, { statuses: HOLDING });
  let total = 0;
  const refunds = [];
  for (const r of regs) {
    const amount = round2(asNum(r.paid_amount, 0));
    if (amount > 0 && r.captain_id) {
      await refundEntry(client, {
        tournament, captainId: r.captain_id, teamName: r.team_name, amount, reason,
      });
      total = round2(total + amount);
    }
    refunds.push({ teamId: r.team_id, teamName: r.team_name, captainId: r.captain_id, amount });
  }
  if (regs.length) {
    await client.query(
      `UPDATE tournament_teams
          SET status = 'withdrawn', withdrawn_at = now(), seed = NULL
        WHERE tournament_id = $1 AND status = ANY($2::text[])`,
      [tournament.id, HOLDING],
    );
  }
  return { refunds, total, teams: regs.length };
}

/**
 * cancel — the organiser calls the tournament off, or the deadline job does it
 * because too few teams entered.
 *
 * Permitted only while `status = 'open'`. After generation the fees have been
 * released to the organiser, slots are blocked and byes are already resolved;
 * "cancel" would then mean clawing money back out of the owner's wallet, which
 * this system never does. An organiser who must abandon a running tournament
 * cancels the remaining fixtures — a different, later problem than this one.
 *
 * `actorId` is the user to attribute it to, or null when the job did it.
 */
async function cancel(client, {
  actorId = null, tournamentId, reason = null, bySystem = false,
} = {}) {
  const t = await loadTournament(client, tournamentId, { forUpdate: true });
  if (!t) return fail(404, 'not_found', 'Tournament not found');
  if (!bySystem && String(t.owner_id || '') !== String(actorId)) {
    return fail(403, 'not_organiser', 'Only the organiser can cancel this tournament');
  }
  if (t.status === STATUS.CANCELLED) {
    return fail(409, 'already_cancelled', 'This tournament is already cancelled');
  }
  if (t.status !== STATUS.OPEN || t.fixtures_generated_at) {
    return fail(409, 'too_late',
      'The bracket has been drawn and the entry fees have been paid out — this tournament can no longer be cancelled');
  }

  const note = squash(reason || '').slice(0, 200)
    || (bySystem ? 'Not enough teams entered by the deadline' : 'Cancelled by the organiser');
  const { refunds, total, teams } = await refundEveryone(client, {
    tournament: t, reason: 'tournament cancelled, fee refunded',
  });

  await client.query(
    `UPDATE tournaments
        SET status = 'cancelled', cancelled_at = now(), cancel_reason = $2,
            pool_amount = 0, venue_cost_amount = 0, prize_amount = 0, owner_earning_amount = 0
      WHERE id = $1`,
    [t.id, note],
  );

  for (const r of refunds) {
    if (!r.captainId) continue;
    await notify(client, {
      userId: r.captainId,
      type: 'tournament_cancelled',
      title: 'Tournament cancelled',
      body: `${t.name} has been cancelled — ${note}. PKR ${r.amount} has been refunded to your wallet.`,
      payload: { tournamentId: t.id, teamId: r.teamId, refunded: r.amount, reason: note },
    });
  }
  if (t.owner_id && bySystem) {
    await notify(client, {
      userId: t.owner_id,
      type: 'tournament_cancelled',
      title: 'Tournament cancelled',
      body: `${t.name} was cancelled — ${note}. ${teams} ${teams === 1 ? 'team was' : 'teams were'} refunded PKR ${total}.`,
      payload: { tournamentId: t.id, refunded: total, teams, reason: note },
    });
  }

  const fresh = await loadTournament(client, t.id);
  return done(200, {
    tournament: shapeTournament(fresh),
    refunded: total, teamsRefunded: teams, reason: note,
  }, `Tournament cancelled — PKR ${total} refunded to ${teams} ${teams === 1 ? 'team' : 'teams'}`);
}

// ─────────────────────────────────────────────────────────────────────────────
// GENERATION (SRS FE-6) — the one place a bracket comes into existence
// ─────────────────────────────────────────────────────────────────────────────

/**
 * generateFixtures — draw the bracket, reserve the ground, settle the money.
 *
 * This is the transaction the whole module is built around, and it is one
 * transaction on purpose: seeding, fixtures, slot reservation and three kinds of
 * money move either all happen or none do. A crash halfway through the old way of
 * doing this leaves fixtures on unblocked slots, or fees released for a bracket
 * that does not exist.
 *
 * Order matters and is not arbitrary:
 *
 *   1. LATCH.  `fixtures_generated_at IS NULL` under the tournament's row lock.
 *              The job and the organiser's button race by design; the loser gets
 *              `already_generated`, not a doubled bracket.
 *   2. FIELD.  Pending approvals are resolved (see below), then the accepted
 *              teams are counted. Below `min_teams` → cancel and refund everyone,
 *              which is the ONLY outcome where this function does not draw.
 *   3. DRAW.   `fx.seedTeams` then `fx.buildFixtures` — pure, DB-free, and the
 *              same functions `test/fixtures.test.js` proves with the DB down.
 *   4. PLACE.  `scheduler.schedule` puts them on real free hours. If the venue
 *              cannot host the whole bracket the function REFUSES and writes
 *              nothing — a half-scheduled tournament would charge a pool against
 *              three hours of inventory while consuming seven.
 *   5. RESERVE.The chosen slots are re-locked and re-checked, then flipped to
 *              'blocked'. Between the candidate scan and here a player could have
 *              started a checkout, so the reservation is verified under a lock and
 *              the whole transaction fails if an hour has gone.
 *   6. MONEY.  Every captain's frozen fee is released, the pool is split by the
 *              waterfall, and the owner receives their earning in `balance` while
 *              the prize sits in their `frozen` where a withdrawal cannot reach it.
 *
 * PENDING APPROVALS. An approval-gated tournament can reach its deadline with
 * entries the organiser never decided on. Before the deadline that is their
 * business and this function refuses (`pending_decisions`) so they can decide.
 * After it, silence is an answer: the outstanding entries are rejected and
 * refunded in full, because the alternative is a tournament that can never be
 * generated because nobody clicked, and a captain's money frozen indefinitely.
 */
async function generateFixtures(client, {
  actorId = null, tournamentId, bySystem = false, useModel = true,
} = {}) {
  const t = await loadTournament(client, tournamentId, { forUpdate: true });
  if (!t) return fail(404, 'not_found', 'Tournament not found');
  if (!bySystem && String(t.owner_id || '') !== String(actorId)) {
    return fail(403, 'not_organiser', 'Only the organiser can generate this tournament');
  }
  if (t.fixtures_generated_at || t.status === STATUS.ACTIVE || t.status === STATUS.COMPLETED) {
    return fail(409, 'already_generated', 'The bracket for this tournament has already been drawn');
  }
  if (t.status === STATUS.CANCELLED) return fail(409, 'cancelled', 'This tournament was cancelled');

  const policy = await settings.tournament({ client });
  const deadlinePassed = new Date(t.registration_deadline).getTime() <= Date.now();
  const holding = Number(t.teams_holding) || 0;
  const full = holding >= Number(t.max_teams);

  // The organiser may draw early once the field is full — that is closing
  // registration, not skipping it. Otherwise the deadline governs, because a team
  // that entered on time must not find the bracket already drawn without them.
  if (!deadlinePassed && !full) {
    return fail(409, 'too_early',
      'Registration is still open. The bracket is drawn automatically at the deadline, or now if the field fills up.');
  }

  // ---- 2. the field ------------------------------------------------------
  const pending = await loadRegistrations(client, t.id, { statuses: [REG.REGISTERED] });
  if (pending.length && !deadlinePassed) {
    return fail(409, 'pending_decisions',
      `${pending.length} ${pending.length === 1 ? 'team is' : 'teams are'} still waiting for your approval`);
  }
  for (const p of pending) {
    const amount = round2(asNum(p.paid_amount, 0));
    if (amount > 0 && p.captain_id) {
      await refundEntry(client, {
        tournament: t, captainId: p.captain_id, teamName: p.team_name, amount,
        reason: 'entry not accepted before the deadline, fee refunded',
      });
    }
    await client.query(
      `UPDATE tournament_teams SET status = 'rejected', withdrawn_at = now(), seed = NULL WHERE id = $1`,
      [p.registration_id],
    );
    if (p.captain_id) {
      await notify(client, {
        userId: p.captain_id,
        type: 'tournament_rejected',
        title: 'Entry not accepted',
        body: `${p.team_name} was not accepted into ${t.name} before the deadline. PKR ${amount} has been refunded.`,
        payload: { tournamentId: t.id, teamId: p.team_id, refunded: amount },
      });
    }
  }

  const field = await loadRegistrations(client, t.id, { statuses: [REG.ACCEPTED] });
  const minTeams = Math.max(2, Number(t.min_teams) || policy.minTeams);
  if (field.length < minTeams) {
    const cancelled = await cancel(client, {
      tournamentId: t.id, bySystem: true,
      reason: `Only ${field.length} ${field.length === 1 ? 'team' : 'teams'} entered — ${minTeams} are needed`,
    });
    if (!cancelled.ok) return cancelled;
    return {
      ok: true, status: 200, code: 'cancelled_min_teams',
      message: cancelled.message,
      data: { ...cancelled.data, generated: false, teams: field.length, minTeams },
    };
  }

  // ---- 3. the draw (pure) ------------------------------------------------
  const seeded = fx.seedTeams(field.map((r) => ({
    id: r.team_id, name: r.team_name, elo: r.elo, captainId: r.captain_id,
  })));
  const built = fx.buildFixtures(t.format, seeded);
  if (!built.fixtures.length) {
    return fail(409, 'no_fixtures', 'That field cannot be drawn into a bracket');
  }

  // ---- 4. the placement (model #1, or chronological) ---------------------
  const notBefore = deadlinePassed ? null : t.registration_deadline;
  const placed = await scheduler.schedule(client, {
    venueId: t.venue_id,
    fixtures: built.fixtures,
    format: t.format,
    notBefore,
    slotMinutes: Number(t.slot_minutes) || policy.slotMinutes,
    roundGapDays: policy.roundGapDays,
    roundRestMinutes: policy.roundRestMinutes,
    useModel: useModel !== false,
  });
  if (!placed.ok) {
    return {
      ok: false, status: 409, code: placed.code || 'not_schedulable',
      message: placed.message || 'This venue does not have enough free hours for the whole bracket',
      data: { shortfall: placed.shortfall || null, meta: placed.meta || null },
    };
  }

  // ---- 5. the reservation -----------------------------------------------
  // Re-locked and re-checked. `candidateSlots` ran a moment ago without a lock,
  // so between the scan and here a player could have started a checkout on one of
  // the chosen hours. Verifying under the lock turns that race into a clean
  // failure of the whole transaction instead of a fixture on a sold hour.
  const slotIds = placed.assignments.map((a) => a.slotId);
  const locked = await client.query(
    `SELECT s.id FROM slots s
      WHERE s.id = ANY($1::uuid[]) AND s.status = 'available' AND NOT ${discovery.HOLD_IS_LIVE}
      ORDER BY s.id
        FOR UPDATE`,
    [slotIds],
  );
  if (locked.rows.length !== slotIds.length) {
    return fail(409, 'slot_taken',
      'One of the hours chosen for this bracket was taken while it was being drawn. Try again.');
  }
  await client.query(
    `UPDATE slots SET status = 'blocked' WHERE id = ANY($1::uuid[])`,
    [slotIds],
  );

  // ---- the fixtures rows -------------------------------------------------
  // `built.fixtures` already carries resolved byes (status 'walkover', the top
  // seed as winner, and that team pre-advanced into its round-2 node), so the
  // rows are inserted exactly as the pure builder produced them.
  const byKey = new Map(placed.assignments.map((a) => [plan.keyOf(a.round, a.position), a]));
  for (const f of built.fixtures) {
    const at = byKey.get(plan.keyOf(f.round, f.position)) || null;
    await client.query(
      `INSERT INTO fixtures
         (tournament_id, round, position, label, team_a, team_b, is_bye, status, winner,
          next_round, next_position, slot_id, scheduled_at, played_at)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)`,
      [t.id, f.round, f.position, f.label, f.teamA, f.teamB, f.isBye, f.status, f.winner,
        f.nextRound, f.nextPosition, at ? at.slotId : null, at ? at.scheduledAt : null,
        f.isBye ? new Date() : null],
    );
  }

  // Seeds are stored so the bracket can be re-read and re-drawn identically, and
  // so the teams tab can show "Seed 3" without recomputing the ladder.
  for (const s of seeded) {
    await client.query(
      'UPDATE tournament_teams SET seed = $1 WHERE tournament_id = $2 AND team_id = $3',
      [s.seed, t.id, s.id],
    );
  }

  // ---- 6. the money ------------------------------------------------------
  // The pool is the sum of what was ACTUALLY frozen, not `entry_fee x teams`. An
  // owner who edits the fee after two teams have entered must not be paid on a
  // number nobody paid; releasing exactly what each captain holds is the only
  // version of this that leaves the ledger summing to zero.
  const pool = field.reduce((sum, r) => round2(sum + asNum(r.paid_amount, 0)), 0);
  const split = fx.splitPool({
    pool,
    entryFee: asNum(t.entry_fee, 0),
    teams: field.length,
    slotTotal: asNum(placed.slotTotal, 0),
    venueDiscountPercent: asNum(t.venue_discount_percent, 0),
    prizePercent: asNum(t.prize_percent, policy.prizePercent),
    winnerPercent: asNum(t.winner_percent, policy.winnerPercent),
    runnerupPercent: asNum(t.runnerup_percent, policy.runnerupPercent),
  });

  for (const r of field) {
    const fee = round2(asNum(r.paid_amount, 0));
    if (fee <= 0 || !r.captain_id) continue;
    const wallet = await lockWallet(client, r.captain_id);
    if (!wallet) continue;
    const after = await applyWallet(client, wallet.id, { frozen: -fee });
    await logTxn(client, {
      walletId: wallet.id,
      userId: r.captain_id,
      bookingId: null,
      tournamentId: t.id,
      type: TXN.RELEASE,
      amount: -fee,
      balanceAfter: after.balance,
      description: `${t.name} — entry fee released to the organiser (${r.team_name})`,
      counterparty: t.venue_name || t.owner_name || t.name,
    });
  }

  const ownerWallet = t.owner_id ? await lockWallet(client, t.owner_id) : null;
  if (ownerWallet) {
    if (split.ownerEarning > 0) {
      const after = await applyWallet(client, ownerWallet.id, { balance: split.ownerEarning });
      await logTxn(client, {
        walletId: ownerWallet.id,
        userId: t.owner_id,
        bookingId: null,
        tournamentId: t.id,
        type: TXN.COMMISSION,
        amount: split.ownerEarning,
        balanceAfter: after.balance,
        description: `${t.name} — venue cost PKR ${split.venueCost} + organiser margin PKR ${split.margin}`
          + ` (${field.length} teams, ${placed.slotsUsed} hours)`,
        counterparty: t.name,
      });
    }
    // The prize goes to the organiser's FROZEN balance, not their spendable one.
    // They are holding it for the champion, and `wallets.frozen_balance` is
    // already the column every withdrawal path refuses to touch — so the prize is
    // protected by the same rule that protects a booking's escrow, not by a new one.
    if (split.prize > 0) {
      const after = await applyWallet(client, ownerWallet.id, { frozen: split.prize });
      await logTxn(client, {
        walletId: ownerWallet.id,
        userId: t.owner_id,
        bookingId: null,
        tournamentId: t.id,
        type: TXN.PRIZE,
        amount: split.prize,
        balanceAfter: after.balance,
        description: `${t.name} — prize pool held for the champion`
          + ` (winner PKR ${split.winnerShare}, runner-up PKR ${split.runnerupShare})`,
        counterparty: t.name,
      });
    }
  }

  // ---- the row -----------------------------------------------------------
  // `start_date` is corrected to the date the bracket actually landed on. The
  // owner typed a guess before the venue's free hours were known; the fixtures
  // are the fact, and a browse screen showing a date no fixture is on is a lie
  // nobody would think to check.
  await client.query(
    `UPDATE tournaments
        SET status = 'active', fixtures_generated_at = now(), activated_at = now(),
            rounds = $2, start_date = COALESCE($3::date, start_date),
            pool_amount = $4, venue_cost_amount = $5,
            prize_amount = $6, owner_earning_amount = $7
      WHERE id = $1`,
    [t.id, built.rounds, placed.startDate || null,
      split.pool, split.venueCost, split.prize, split.ownerEarning],
  );

  // ---- notifications ----------------------------------------------------
  const rows = await loadFixtures(client, t.id);
  const firstFor = new Map();
  for (const f of rows) {
    if (f.is_bye || !f.scheduled_at) continue;
    for (const side of [f.team_a, f.team_b]) {
      if (side && !firstFor.has(String(side))) firstFor.set(String(side), f);
    }
  }
  const byeTeams = new Set(rows.filter((f) => f.is_bye && f.team_a).map((f) => String(f.team_a)));

  for (const r of field) {
    if (!r.captain_id) continue;
    const first = firstFor.get(String(r.team_id));
    const when = first
      ? `${first.slot_date} at ${String(first.start_time).slice(0, 5)}`
      : 'a time the organiser will confirm';
    await notify(client, {
      userId: r.captain_id,
      type: 'tournament_fixtures_ready',
      title: 'The bracket is out',
      body: `${t.name}: ${r.team_name} is seeded ${r.seed || '—'} of ${field.length}.`
        + `${byeTeams.has(String(r.team_id)) ? ' You have a bye in round 1.' : ''}`
        + ` First match ${when}. Winner takes PKR ${split.winnerShare}.`,
      payload: {
        tournamentId: t.id,
        teamId: r.team_id,
        fixtureId: first ? first.id : null,
        scheduledAt: first ? iso(first.scheduled_at) : null,
        winnerShare: split.winnerShare,
        runnerupShare: split.runnerupShare,
      },
    });
  }
  if (t.owner_id) {
    await notify(client, {
      userId: t.owner_id,
      type: 'tournament_generated',
      title: 'Tournament under way',
      body: `${t.name}: ${field.length} teams, ${built.fixtures.length - built.byes} matches over `
        + `${placed.slotsUsed} hours. You earn PKR ${split.ownerEarning}`
        + ` (PKR ${split.venueCost} of it covering the slots)`
        + `${split.underwater ? ' — the pool did not cover the venue cost, so there is no prize.' : '.'}`,
      payload: {
        tournamentId: t.id,
        teams: field.length,
        hours: placed.slotsUsed,
        ownerEarning: split.ownerEarning,
        venueCost: split.venueCost,
        prize: split.prize,
        source: placed.meta.scheduling.source,
      },
    });
  }

  const fresh = await loadTournament(client, t.id);
  return done(200, {
    tournament: shapeTournament(fresh),
    generated: true,
    teams: field.length,
    seeds: seeded.map((s) => ({ teamId: s.id, teamName: s.name, seed: s.seed, elo: s.elo })),
    bracket: { rounds: built.rounds, size: built.size || null, byes: built.byes, fixtures: built.fixtures.length },
    fixtures: rows.map(shapeFixture),
    economics: split,
    rejectedPending: pending.length,
    // The provenance block, echoed verbatim from the scheduler: 'model' when the
    // released demand model actually scored the candidate hours, 'chronological'
    // when it could not, and `reason` saying which. This is the claim the demo
    // checks rather than asserts.
    meta: placed.meta,
  }, `Bracket drawn — ${field.length} teams, ${placed.slotsUsed} hours reserved`
    + `${split.prize > 0 ? `, PKR ${split.prize} prize pool` : ', no prize (pool did not cover the venue)'}`);
}

// ─────────────────────────────────────────────────────────────────────────────
// RESULTS (SRS FE-7) — two doors, one settle function
// ─────────────────────────────────────────────────────────────────────────────

/** One fixture, with both teams, the slot, and the tournament's format context. */
async function loadFixture(client, { tournamentId, fixtureId, matchId = null, forUpdate = false }) {
  const where = matchId ? 'f.match_id = $1' : 'f.id = $1';
  const key = matchId || fixtureId;
  if (!isUuid(key)) return null;
  if (forUpdate) {
    const lock = await client.query(
      `SELECT id FROM fixtures f WHERE ${where}${tournamentId ? ' AND f.tournament_id = $2' : ''} FOR UPDATE`,
      tournamentId ? [key, tournamentId] : [key],
    );
    if (!lock.rows.length) return null;
  }
  const r = await client.query(
    `SELECT f.*, ta.name AS team_a_name, tb.name AS team_b_name,
            ta.captain_id AS captain_a, tb.captain_id AS captain_b,
            ta.elo AS team_a_elo, tb.elo AS team_b_elo,
            sa.seed AS seed_a, sb.seed AS seed_b,
            to_char(s.slot_date, 'YYYY-MM-DD') AS slot_date, s.start_time, s.end_time, s.price
       FROM fixtures f
       LEFT JOIN teams ta ON ta.id = f.team_a
       LEFT JOIN teams tb ON tb.id = f.team_b
       LEFT JOIN slots s  ON s.id = f.slot_id
       LEFT JOIN tournament_teams sa ON sa.tournament_id = f.tournament_id AND sa.team_id = f.team_a
       LEFT JOIN tournament_teams sb ON sb.tournament_id = f.tournament_id AND sb.team_id = f.team_b
      WHERE ${where}${tournamentId ? ' AND f.tournament_id = $2' : ''}`,
    tournamentId ? [key, tournamentId] : [key],
  );
  return r.rows[0] || null;
}

/**
 * Who advances from a drawn knockout tie: the HIGHER SEED, i.e. the lower seed
 * number.
 *
 * This project has no penalty-shootout model and inventing one would be inventing
 * a result. Every knockout needs a tie-break rule and "the team that finished the
 * season ranked higher progresses" is a real one used in real competitions, so it
 * is stated in the policy text, shown on the bracket, and implemented here rather
 * than left to whichever side happens to be `team_a`.
 */
function drawWinner(fixture) {
  const seedA = Number(fixture.seed_a);
  const seedB = Number(fixture.seed_b);
  if (Number.isFinite(seedA) && Number.isFinite(seedB) && seedA !== seedB) {
    return seedA < seedB ? fixture.team_a : fixture.team_b;
  }
  const eloA = asNum(fixture.team_a_elo, 1000);
  const eloB = asNum(fixture.team_b_elo, 1000);
  if (eloA !== eloB) return eloA > eloB ? fixture.team_a : fixture.team_b;
  return fixture.team_a;
}

/** A score is a non-negative integer or it is not a score. */
function readScore(value) {
  const n = Number(value);
  if (!Number.isFinite(n) || !Number.isInteger(n) || n < 0 || n > 999) return null;
  return n;
}

/**
 * advanceWinner — write the winner into the node it feeds.
 *
 * `next_round`/`next_position` were stored at generation so this is one UPDATE
 * against a known row rather than arithmetic that has to agree with the
 * generator's arithmetic. The side is derived the same way `fixtures.advanceSlot`
 * derives it — an odd position feeds side A — and the write is conditional on the
 * target side still being empty, so a retry cannot overwrite a name already there.
 */
async function advanceWinner(client, { tournament, fixture, winner }) {
  if (!winner || !fixture.next_round || !fixture.next_position) return null;
  const side = fx.advanceSlot(fixture.round, fixture.position).side === 'a' ? 'team_a' : 'team_b';
  const r = await client.query(
    `UPDATE fixtures SET ${side} = $4
      WHERE tournament_id = $1 AND round = $2 AND position = $3 AND ${side} IS NULL
      RETURNING id, round, position, team_a, team_b`,
    [tournament.id, fixture.next_round, fixture.next_position, winner],
  );
  return r.rows[0] || null;
}

/**
 * completeTournament — pay the podium and close the books.
 *
 * The prize has been sitting in the ORGANISER's frozen balance since generation,
 * so paying it out is a release, not a new charge: owner `frozen -= prize`, then
 * `winnerShare` into the champion captain's balance and `runnerupShare` into the
 * runner-up's. The ledger therefore reads pool in → venue cost + margin + prize
 * out, which is exactly what `check_tournaments.js` asserts to the paisa.
 *
 * Winner and runner-up are read off the FIXTURES, never recomputed from a bracket
 * shape: a knockout's champion is the final's winner and the runner-up is the side
 * that lost it, and a round-robin's are the top two rows of the table. Both are
 * facts already in the database at this point.
 *
 * `titles` and `finals_reached` move once, here, rather than during advancement:
 * a team that reaches a final and loses it has still reached a final, and a
 * counter incremented mid-bracket would have to be undone if the tournament were
 * abandoned. `finals_reached` is knockout-only — a league's top two did not reach
 * a final, they finished first and second.
 */
async function completeTournament(client, { tournament, fixtures }) {
  const t = tournament;
  const isKnockout = t.format !== fx.FORMATS.ROUND_ROBIN;
  let winnerTeam = null;
  let runnerUpTeam = null;

  if (isKnockout) {
    const finals = fixtures.filter((f) => !f.next_round && !f.is_bye);
    const final = finals.length ? finals.reduce((a, b) => (b.round > a.round ? b : a)) : null;
    if (!final || !final.winner) return null;
    winnerTeam = final.winner;
    runnerUpTeam = String(final.team_a) === String(final.winner) ? final.team_b : final.team_a;
  } else {
    const regs = await loadRegistrations(client, t.id, { statuses: [REG.ACCEPTED, REG.ELIMINATED] });
    const table = fx.standings(
      regs.map((r) => ({ id: r.team_id, name: r.team_name, elo: r.elo, seed: r.seed })),
      fixtures,
    );
    if (!table.length) return null;
    winnerTeam = table[0].teamId;
    runnerUpTeam = table.length > 1 ? table[1].teamId : null;
  }

  const prize = round2(asNum(t.prize_amount, 0));
  const winnerPct = asNum(t.winner_percent, 70);
  const winnerShare = round2((prize * winnerPct) / 100);
  const runnerupShare = round2(prize - winnerShare);

  const names = new Map();
  for (const f of fixtures) {
    if (f.team_a) names.set(String(f.team_a), f.team_a_name);
    if (f.team_b) names.set(String(f.team_b), f.team_b_name);
  }
  const captains = await client.query(
    'SELECT id, name, captain_id FROM teams WHERE id = ANY($1::uuid[])',
    [[winnerTeam, runnerUpTeam].filter(Boolean)],
  );
  const teamById = new Map(captains.rows.map((r) => [String(r.id), r]));
  const champion = teamById.get(String(winnerTeam)) || null;
  const runnerUp = runnerUpTeam ? teamById.get(String(runnerUpTeam)) || null : null;

  // The release, then the two payments. Guarded on prize > 0 so an underwater
  // tournament completes cleanly with a champion and no money movement at all.
  const payouts = [];
  if (prize > 0 && t.owner_id) {
    const ownerWallet = await lockWallet(client, t.owner_id);
    if (ownerWallet) {
      const after = await applyWallet(client, ownerWallet.id, { frozen: -prize });
      await logTxn(client, {
        walletId: ownerWallet.id,
        userId: t.owner_id,
        bookingId: null,
        tournamentId: t.id,
        type: TXN.RELEASE,
        amount: -prize,
        balanceAfter: after.balance,
        description: `${t.name} — prize pool paid out to the podium`,
        counterparty: champion ? champion.name : t.name,
      });
    }
    const pay = async (team, amount, place) => {
      if (!team || !team.captain_id || amount <= 0) return;
      const wallet = await lockWallet(client, team.captain_id);
      if (!wallet) return;
      const after = await applyWallet(client, wallet.id, { balance: amount });
      await logTxn(client, {
        walletId: wallet.id,
        userId: team.captain_id,
        bookingId: null,
        tournamentId: t.id,
        type: TXN.PRIZE,
        amount,
        balanceAfter: after.balance,
        description: `${t.name} — ${place} prize (${team.name})`,
        counterparty: t.venue_name || t.name,
      });
      payouts.push({ teamId: team.id, teamName: team.name, place, amount });
    };
    await pay(champion, winnerShare, 'champion');
    await pay(runnerUp, runnerupShare, 'runner-up');
  }

  // The tournament record. Achievements, not a second rating — see 019 note 3.
  if (winnerTeam) {
    await client.query(
      `UPDATE teams SET titles = COALESCE(titles, 0) + 1${isKnockout ? ', finals_reached = COALESCE(finals_reached, 0) + 1' : ''} WHERE id = $1`,
      [winnerTeam],
    );
  }
  if (runnerUpTeam && isKnockout) {
    await client.query(
      'UPDATE teams SET finals_reached = COALESCE(finals_reached, 0) + 1 WHERE id = $1',
      [runnerUpTeam],
    );
  }

  await client.query(
    `UPDATE tournaments
        SET status = 'completed', completed_at = now(), winner_team = $2, runner_up_team = $3
      WHERE id = $1`,
    [t.id, winnerTeam, runnerUpTeam],
  );
  await client.query(
    `UPDATE tournament_teams SET status = 'eliminated'
      WHERE tournament_id = $1 AND status = 'accepted' AND team_id <> $2`,
    [t.id, winnerTeam],
  );

  const championName = (champion && champion.name) || names.get(String(winnerTeam)) || 'the champion';
  const runnerUpName = (runnerUp && runnerUp.name) || (runnerUpTeam ? names.get(String(runnerUpTeam)) : null);
  const podiumLine = prize > 0
    ? `PKR ${winnerShare} to ${championName}${runnerUpName ? ` and PKR ${runnerupShare} to ${runnerUpName}` : ''}.`
    : 'There was no prize pool — the entry fees did not clear the venue cost.';

  const all = await loadRegistrations(client, t.id);
  for (const r of all) {
    if (!r.captain_id || !HOLDING.concat([REG.ELIMINATED]).includes(r.status)) continue;
    const isChampion = String(r.team_id) === String(winnerTeam);
    const isRunnerUp = runnerUpTeam && String(r.team_id) === String(runnerUpTeam);
    await notify(client, {
      userId: r.captain_id,
      type: isChampion ? 'tournament_won' : 'tournament_completed',
      title: isChampion ? `${r.team_name} are champions` : `${t.name} is over`,
      body: isChampion
        ? `${r.team_name} won ${t.name}.${prize > 0 ? ` PKR ${winnerShare} is in your wallet.` : ''}`
        : `${championName} won ${t.name}.${isRunnerUp && prize > 0 ? ` PKR ${runnerupShare} is in your wallet as runner-up.` : ''}`,
      payload: {
        tournamentId: t.id,
        teamId: r.team_id,
        winnerTeam,
        runnerUpTeam,
        amount: isChampion ? winnerShare : (isRunnerUp ? runnerupShare : 0),
      },
    });
  }
  if (t.owner_id) {
    await notify(client, {
      userId: t.owner_id,
      type: 'tournament_completed',
      title: `${t.name} is complete`,
      body: `${championName} lifted the trophy. ${podiumLine}`,
      payload: { tournamentId: t.id, winnerTeam, runnerUpTeam, prize },
    });
  }

  return {
    winnerTeam, runnerUpTeam, championName, runnerUpName,
    prize, winnerShare: prize > 0 ? winnerShare : 0, runnerupShare: prize > 0 ? runnerupShare : 0,
    payouts,
  };
}

/**
 * applyFixtureResult — the ONE place a fixture stops being upcoming.
 *
 * Both doors into the result flow end here, which is the point: the organiser
 * typing a score (FE-7) and the S.2 captain-submits → owner-verifies flow must
 * produce byte-identical bracket state, or a tournament would advance differently
 * depending on which screen was used.
 *
 * The difference between the two doors is ELO, and only ELO:
 *
 *   organiser door  → `applyElo: true`. This function writes the `matches` row and
 *                     applies the exchange itself, with K from `fx.kFactorFor`.
 *   match-flow door → `applyElo: false`. `routes/matches.js` has ALREADY applied
 *                     the exchange inside the same transaction (its own
 *                     `matches.elo_applied` latch), so a second application here
 *                     would double-count the rating for one game.
 *
 * The latch for THIS function is `fixtures.status`: anything other than
 * `upcoming` returns `already_settled` and writes nothing.
 */
async function applyFixtureResult(client, {
  tournament, fixture, scoreA = null, scoreB = null,
  matchId = null, applyElo = false, actorId = null,
  asWalkover = false, winnerTeam = null,
} = {}) {
  const t = tournament;
  const f = fixture;
  if (f.status !== fx.FIXTURE_STATUS.UPCOMING) {
    return fail(409, 'already_settled', `That fixture is already ${f.status}`);
  }

  const rounds = Number(t.rounds) || null;
  const isRoundRobin = t.format === fx.FORMATS.ROUND_ROBIN;
  let a = null;
  let b = null;
  let winner = null;

  if (asWalkover) {
    if (!f.team_a && !f.team_b) return fail(409, 'no_teams', 'That fixture has no teams yet');
    const candidates = [f.team_a, f.team_b].filter(Boolean).map(String);
    winner = winnerTeam && candidates.includes(String(winnerTeam))
      ? String(winnerTeam)
      : candidates[0];
  } else {
    if (!f.team_a || !f.team_b) {
      return fail(409, 'teams_unknown',
        'Both teams for this fixture are not known yet — the previous round has to be played first');
    }
    a = readScore(scoreA);
    b = readScore(scoreB);
    if (a === null || b === null) {
      return fail(400, 'bad_score', 'Enter both scores as whole numbers');
    }
    if (a === b) {
      // A league draw is a draw and shares the points. A knockout tie has to
      // produce someone to play the next round, so the higher seed goes through.
      winner = isRoundRobin ? null : String(drawWinner(f));
    } else {
      winner = a > b ? String(f.team_a) : String(f.team_b);
    }
  }

  const status = asWalkover ? fx.FIXTURE_STATUS.WALKOVER : fx.FIXTURE_STATUS.PLAYED;
  await client.query(
    `UPDATE fixtures
        SET score_a = $2, score_b = $3, winner = $4, status = $5,
            played_at = now(), match_id = COALESCE($6, match_id)
      WHERE id = $1`,
    [f.id, a, b, winner, status, matchId],
  );

  // The tournament record. A walkover is not a game played — nobody turned up —
  // so it moves no counters, exactly as it moves no rating.
  if (!asWalkover) {
    await client.query(
      `UPDATE teams SET tournament_played = COALESCE(tournament_played, 0) + 1
        WHERE id = ANY($1::uuid[])`,
      [[f.team_a, f.team_b].filter(Boolean)],
    );
    if (winner) {
      await client.query(
        'UPDATE teams SET tournament_wins = COALESCE(tournament_wins, 0) + 1 WHERE id = $1',
        [winner],
      );
    }
  }

  // ELO — organiser door only. K rises with the stakes (40 / 48 / 56), and a
  // walkover is K=0 by `kFactorFor`, so this is skipped rather than applied at 0.
  let exchange = null;
  let kFactor = 0;
  if (!asWalkover && f.team_a && f.team_b) {
    const policy = await settings.tournament({ client });
    kFactor = fx.kFactorFor({
      round: f.round, rounds, isBye: false, format: t.format,
      k: { early: policy.kEarly, semi: policy.kSemi, final: policy.kFinal },
    });
    if (applyElo && matchId) {
      const { base } = await settings.elo({ client });
      exchange = await eloUtil.applyResult(client, {
        matchId,
        challengerTeam: f.team_a,
        opponentTeam: f.team_b,
        winnerTeam: winner,
        base,
        kFactor,
      });
      // The organiser door owns the whole match row: it created it a moment ago
      // as `awaiting_owner`, so the verified state is written here, once, in the
      // same transaction as the rating. The match-flow door never reaches this
      // branch — routes/matches.js has already written all of it.
      await client.query(
        `UPDATE matches
            SET winner_team = $2, score_challenger = $3, score_opponent = $4,
                status = 'completed', verified_by = COALESCE($5, verified_by),
                verified_at = now(), elo_applied = TRUE, results_locked = TRUE,
                updated_at = now()
          WHERE id = $1`,
        [matchId, winner, a, b, actorId],
      );
    }
  }

  const advanced = await advanceWinner(client, { tournament: t, fixture: f, winner });

  // The loser is out. Round-robin has no elimination — every team plays every
  // matchday — so the status only moves in a knockout.
  if (!isRoundRobin && winner && f.team_a && f.team_b) {
    const loser = String(f.team_a) === String(winner) ? f.team_b : f.team_a;
    if (loser) {
      await client.query(
        `UPDATE tournament_teams SET status = 'eliminated', eliminated_round = $3
          WHERE tournament_id = $1 AND team_id = $2 AND status = 'accepted'`,
        [t.id, loser, f.round],
      );
    }
  }

  // Completion: a knockout is over when the node with nowhere to advance to has a
  // winner; a league is over when no fixture is upcoming.
  const rows = await loadFixtures(client, t.id);
  const remaining = rows.filter((r) => r.status === fx.FIXTURE_STATUS.UPCOMING).length;
  const finalDone = isRoundRobin
    ? remaining === 0
    : rows.some((r) => !r.next_round && !r.is_bye && r.winner);
  let completed = null;
  if (finalDone && (isRoundRobin ? remaining === 0 : true) && t.status === STATUS.ACTIVE) {
    completed = await completeTournament(client, { tournament: t, fixtures: rows });
  }

  const settled = rows.find((r) => String(r.id) === String(f.id)) || null;
  const fresh = await loadTournament(client, t.id);
  return done(200, {
    tournament: shapeTournament(fresh),
    fixture: settled ? shapeFixture(settled) : null,
    winner,
    winnerName: winner === String(f.team_a || '') ? f.team_a_name : f.team_b_name,
    draw: !asWalkover && a !== null && a === b,
    walkover: asWalkover,
    advanced: advanced
      ? { fixtureId: advanced.id, round: advanced.round, position: advanced.position }
      : null,
    elo: exchange
      ? {
        kFactor: exchange.kFactor, frozen: exchange.frozen, reason: exchange.reason,
        challenger: exchange.challenger, opponent: exchange.opponent,
      }
      : { kFactor, applied: false },
    remaining,
    completed,
    fixtures: rows.map(shapeFixture),
  }, completed
    ? `${completed.championName} win ${t.name}`
    : (asWalkover ? 'Walkover recorded' : 'Result recorded'));
}

/**
 * settleFixture — SRS FE-7: the organiser types the score straight onto the
 * bracket.
 *
 * A tournament cannot depend on both captains being reachable. The organiser is
 * standing at the ground with a whistle; they saw the game. So this is the primary
 * result door, and it still produces a real `matches` row — `booking_id IS NULL`,
 * `tournament_id` set, `verified_by` the organiser — so that the result appears in
 * both teams' match history, moves their ELO through the ONE ladder, and lands in
 * `elo_history` with the tournament K recorded against it. Nothing about a
 * tournament result is a special case downstream; only the door is different.
 */
async function settleFixture(client, {
  actorId, tournamentId, fixtureId, scoreA, scoreB,
} = {}) {
  const t = await loadTournament(client, tournamentId, { forUpdate: true });
  if (!t) return fail(404, 'not_found', 'Tournament not found');
  if (String(t.owner_id || '') !== String(actorId)) {
    return fail(403, 'not_organiser', 'Only the organiser can enter a result');
  }
  if (t.status !== STATUS.ACTIVE) {
    return fail(409, 'not_active', t.status === STATUS.COMPLETED
      ? 'This tournament is already complete'
      : 'This tournament has no bracket yet');
  }

  const f = await loadFixture(client, { tournamentId: t.id, fixtureId, forUpdate: true });
  if (!f) return fail(404, 'fixture_not_found', 'Fixture not found');
  if (f.status !== fx.FIXTURE_STATUS.UPCOMING) {
    return fail(409, 'already_settled', `That fixture is already ${f.status}`);
  }
  if (!f.team_a || !f.team_b) {
    return fail(409, 'teams_unknown',
      'Both teams for this fixture are not known yet — the previous round has to be played first');
  }
  const a = readScore(scoreA);
  const b = readScore(scoreB);
  if (a === null || b === null) return fail(400, 'bad_score', 'Enter both scores as whole numbers');

  // The match row exists so the result is an ordinary match everywhere else in the
  // app. `challenger_team` is `team_a` by construction, which is what lets
  // `advanceAfterMatch` map a verified scoreline back onto the fixture unambiguously.
  const inserted = await client.query(
    `INSERT INTO matches
       (challenger_team, opponent_team, booking_id, tournament_id, sport, status,
        score_challenger, score_opponent, created_by)
     VALUES ($1,$2,NULL,$3,$4,'awaiting_owner',$5,$6,$7)
     RETURNING id`,
    [f.team_a, f.team_b, t.id, t.sport, a, b, actorId],
  );
  const matchId = inserted.rows[0].id;
  await client.query('UPDATE fixtures SET match_id = $2 WHERE id = $1', [f.id, matchId]);

  const result = await applyFixtureResult(client, {
    tournament: t, fixture: f, scoreA: a, scoreB: b,
    matchId, applyElo: true, actorId,
  });
  if (!result.ok) return result;

  const line = mc.scoreline(a, b);
  const nameOf = (id) => (String(id) === String(f.team_a) ? f.team_a_name : f.team_b_name);
  for (const teamId of [f.team_a, f.team_b]) {
    const captain = String(teamId) === String(f.team_a) ? f.captain_a : f.captain_b;
    if (!captain) continue;
    const won = result.data.winner && String(result.data.winner) === String(teamId);
    await notify(client, {
      userId: captain,
      type: 'tournament_result',
      title: result.data.draw
        ? `Draw — ${f.team_a_name} ${line} ${f.team_b_name}`
        : (won ? 'Through to the next round' : 'Result recorded'),
      body: `${f.label || `Round ${f.round}`} of ${t.name}: ${f.team_a_name} ${line} ${f.team_b_name}`
        + `${result.data.draw && t.format !== fx.FORMATS.ROUND_ROBIN
          ? ` — drawn, so the higher seed (${nameOf(result.data.winner)}) advances.` : '.'}`,
      payload: {
        tournamentId: t.id, fixtureId: f.id, matchId,
        teamId, scoreA: a, scoreB: b,
        winner: result.data.winner,
        kFactor: result.data.elo ? result.data.elo.kFactor : null,
      },
    });
  }
  return { ...result, data: { ...result.data, matchId } };
}

/**
 * walkover — a team does not turn up, or cannot continue.
 *
 * Recorded rather than scored: `status = 'walkover'`, a winner, no scoreline, and
 * NO rating movement, because K is 0 for a game nobody played. The slot stays
 * blocked — the tournament reserved and paid for that hour at generation, and
 * un-reserving it would put `venue_cost_amount` out of step with the hours the
 * bracket actually consumed, which is the one number the ledger audit rests on.
 */
async function walkover(client, {
  actorId, tournamentId, fixtureId, winnerTeamId = null, reason = null,
} = {}) {
  const t = await loadTournament(client, tournamentId, { forUpdate: true });
  if (!t) return fail(404, 'not_found', 'Tournament not found');
  if (String(t.owner_id || '') !== String(actorId)) {
    return fail(403, 'not_organiser', 'Only the organiser can award a walkover');
  }
  if (t.status !== STATUS.ACTIVE) return fail(409, 'not_active', 'This tournament has no live bracket');

  const f = await loadFixture(client, { tournamentId: t.id, fixtureId, forUpdate: true });
  if (!f) return fail(404, 'fixture_not_found', 'Fixture not found');
  if (winnerTeamId && ![String(f.team_a), String(f.team_b)].includes(String(winnerTeamId))) {
    return fail(400, 'bad_winner', 'That team is not in this fixture');
  }

  const result = await applyFixtureResult(client, {
    tournament: t, fixture: f, asWalkover: true, winnerTeam: winnerTeamId, actorId,
  });
  if (!result.ok) return result;

  const note = squash(reason || '').slice(0, 200) || 'the opponent could not play';
  for (const teamId of [f.team_a, f.team_b].filter(Boolean)) {
    const captain = String(teamId) === String(f.team_a) ? f.captain_a : f.captain_b;
    if (!captain) continue;
    const won = String(result.data.winner) === String(teamId);
    await notify(client, {
      userId: captain,
      type: 'tournament_walkover',
      title: won ? 'Walkover in your favour' : 'Walkover recorded',
      body: `${f.label || `Round ${f.round}`} of ${t.name} was awarded as a walkover — ${note}.`
        + ' No rating changed, because no game was played.',
      payload: { tournamentId: t.id, fixtureId: f.id, teamId, winner: result.data.winner, reason: note },
    });
  }
  return result;
}

/**
 * matchContext — what `routes/matches.js` needs to know about a tournament match.
 *
 * S.2 answers two questions from the booking: WHO may verify (the owner of the
 * venue the match is booked at) and WHAT K to rate it with (the global 32). A
 * tournament match has no booking, so both answers have to come from somewhere
 * else, and this is that somewhere:
 *
 *   authority → `tournaments.owner_id`. In practice the same person, because only
 *               a venue owner can run a tournament at their own venue, but a
 *               different join and therefore a different query.
 *   K         → `fx.kFactorFor(round, rounds)` — 40 early, 48 semi, 56 final.
 *
 * Returns null for an ordinary friendly, which is the signal for matches.js to
 * take its existing booking path unchanged. That shape matters: the hook is two
 * branches around one call, not a rewrite of the verify handler.
 */
async function matchContext(client, matchId) {
  if (!isUuid(matchId)) return null;
  const r = await client.query(
    `SELECT m.id AS match_id, m.tournament_id, m.challenger_team, m.opponent_team,
            t.owner_id, t.name AS tournament_name, t.format, t.rounds,
            t.status AS tournament_status, t.sport,
            v.name AS venue_name, v.id AS venue_id,
            f.id AS fixture_id, f.round, f.position, f.label, f.is_bye,
            f.status AS fixture_status
       FROM matches m
       JOIN tournaments t ON t.id = m.tournament_id
       LEFT JOIN venues v ON v.id = t.venue_id
       LEFT JOIN fixtures f ON f.match_id = m.id
      WHERE m.id = $1`,
    [matchId],
  );
  const row = r.rows[0];
  if (!row) return null;

  const policy = await settings.tournament({ client });
  return {
    isTournament: true,
    matchId: row.match_id,
    tournamentId: row.tournament_id,
    tournamentName: row.tournament_name,
    tournamentStatus: row.tournament_status,
    ownerId: row.owner_id,
    venueId: row.venue_id,
    venueName: row.venue_name,
    format: row.format,
    rounds: Number(row.rounds) || null,
    fixtureId: row.fixture_id,
    round: Number(row.round) || null,
    position: Number(row.position) || null,
    label: row.label,
    fixtureStatus: row.fixture_status,
    kFactor: fx.kFactorFor({
      round: row.round, rounds: row.rounds, isBye: Boolean(row.is_bye), format: row.format,
      k: { early: policy.kEarly, semi: policy.kSemi, final: policy.kFinal },
    }),
  };
}

/**
 * advanceAfterMatch — called by `routes/matches.js` INSIDE the verify transaction.
 *
 * By the time this runs, matches.js has locked the match, verified the organiser's
 * authority, applied the ELO exchange with the K this module supplied and set
 * `elo_applied`. What is left is the bracket: the fixture takes the agreed
 * scoreline, the winner advances, the loser is eliminated, and the final closes
 * the tournament and pays the podium. Hence `applyElo: false` — rating twice for
 * one game is the one mistake nobody can detect afterwards.
 *
 * A friendly returns `not_tournament` and touches nothing, so matches.js can call
 * it unconditionally and keep the hook to a single line.
 */
async function advanceAfterMatch(client, matchId) {
  if (!isUuid(matchId)) return done(200, { advanced: false }, null);
  const m = await client.query(
    `SELECT id, tournament_id, challenger_team, opponent_team, winner_team,
            score_challenger, score_opponent, status
       FROM matches WHERE id = $1`,
    [matchId],
  );
  const match = m.rows[0];
  if (!match || !match.tournament_id) {
    return { ok: true, status: 200, code: 'not_tournament', message: null, data: { advanced: false } };
  }

  const t = await loadTournament(client, match.tournament_id, { forUpdate: true });
  if (!t) return { ok: true, status: 200, code: 'not_tournament', message: null, data: { advanced: false } };

  const f = await loadFixture(client, { tournamentId: t.id, fixtureId: null, matchId, forUpdate: true });
  if (!f) {
    return { ok: true, status: 200, code: 'no_fixture', message: null, data: { advanced: false } };
  }
  if (f.status !== fx.FIXTURE_STATUS.UPCOMING) {
    return { ok: true, status: 200, code: 'already_settled', message: null, data: { advanced: false } };
  }

  // The match row stores the scoreline as challenger/opponent. Mapping it back by
  // TEAM ID rather than by column order means a match row created outside
  // `settleFixture` — a captain-initiated challenge that was later linked to a
  // fixture — still lands the right score on the right side of the bracket.
  const challengerIsA = String(match.challenger_team) === String(f.team_a);
  const scoreA = challengerIsA ? match.score_challenger : match.score_opponent;
  const scoreB = challengerIsA ? match.score_opponent : match.score_challenger;
  if (scoreA === null || scoreB === null) {
    return { ok: true, status: 200, code: 'no_scoreline', message: null, data: { advanced: false } };
  }

  const result = await applyFixtureResult(client, {
    tournament: t, fixture: f, scoreA, scoreB, matchId, applyElo: false,
  });
  if (!result.ok) return result;
  return { ...result, data: { ...result.data, advanced: true } };
}

// ─────────────────────────────────────────────────────────────────────────────
// READS
// ─────────────────────────────────────────────────────────────────────────────

/**
 * viewerContext — the four questions every tournament screen asks about "me".
 *
 * A player's screen needs to know which of their teams is already in, which of
 * them COULD enter (right sport, they captain it, not already entered), and
 * whether the wallet covers the fee. Working that out client-side would mean
 * shipping the whole team list and the wallet balance to the phone and hoping the
 * two agree; deriving it here means the register button is enabled by the same
 * facts `register` will enforce, so the sheet cannot offer an action that is about
 * to be refused.
 */
async function viewerContext(client, { tournament, userId, registrations }) {
  const empty = {
    isOwner: false, isCaptain: false, myTeam: null, myRegistration: null,
    eligibleTeams: [], walletBalance: null, canAfford: null, canRegister: false,
  };
  if (!userId) return empty;

  const isOwner = String(tournament.owner_id) === String(userId);
  const mine = (registrations || []).find(
    (r) => String(r.captain_id) === String(userId) && HOLDING.includes(r.status),
  ) || null;

  const teams = await client.query(
    `SELECT t.id, t.name, t.logo_url, t.elo, t.sport
       FROM teams t
      WHERE t.captain_id = $1 AND LOWER(t.sport) = LOWER($2)
        AND NOT EXISTS (
              SELECT 1 FROM tournament_teams tt
               WHERE tt.tournament_id = $3 AND tt.team_id = t.id
                 AND tt.status IN ('registered','accepted'))
      ORDER BY t.elo DESC, lower(t.name)`,
    [userId, tournament.sport, tournament.id],
  );

  const w = await client.query('SELECT balance FROM wallets WHERE user_id = $1', [userId]);
  const balance = w.rows.length ? asNum(w.rows[0].balance, 0) : null;
  const fee = asNum(tournament.entry_fee, 0);
  const canAfford = balance == null ? null : balance >= fee;
  const open = tournament.status === STATUS.OPEN
    && !tournament.fixtures_generated_at
    && new Date(tournament.registration_deadline).getTime() > Date.now()
    && Number(tournament.teams_holding || 0) < Number(tournament.max_teams);

  return {
    isOwner,
    isCaptain: teams.rows.length > 0 || Boolean(mine),
    myTeam: mine ? { id: mine.team_id, name: mine.team_name } : null,
    myRegistration: mine ? shapeRegistration(mine) : null,
    eligibleTeams: teams.rows.map((r) => ({
      id: r.id, name: r.name, logoUrl: r.logo_url || null, elo: Math.round(asNum(r.elo, 1000)),
    })),
    walletBalance: balance,
    canAfford,
    // Not "is registration open" — "may I, personally, press the button".
    canRegister: Boolean(open && !isOwner && !mine && teams.rows.length && canAfford),
  };
}

/**
 * economicsOf — the money block, in one of two modes, and it says which.
 *
 * Once fixtures exist the four amounts on the tournament row ARE the answer: they
 * are what the ledger moved, so nothing is recomputed and `settled: true`. Before
 * that there is no venue cost yet — no slots have been chosen — so the block is a
 * PROJECTION at list price, flagged `settled: false`, and the owner's create screen
 * gets the real quote from `preview`, which schedules against actual slot prices.
 *
 * The distinction is the whole reason this is not one number: a projection that
 * looked identical to a settled figure would let a captain read "prize PKR 10,800"
 * off a half-empty tournament and hold the organiser to it.
 */
function economicsOf(row, { teamsCounted = null } = {}) {
  const prizePercent = Number(row.prize_percent);
  const winnerPercent = Number(row.winner_percent);
  const runnerupPercent = Number(row.runnerup_percent);
  const settledPool = asNum(row.pool_amount, 0);

  if (row.fixtures_generated_at && settledPool > 0) {
    const prize = asNum(row.prize_amount, 0);
    return {
      settled: true,
      teams: teamsCounted == null ? Number(row.teams_accepted || 0) : teamsCounted,
      entryFee: asNum(row.entry_fee, 0),
      pool: settledPool,
      venueCost: asNum(row.venue_cost_amount, 0),
      prize,
      prizePercent,
      winnerPercent,
      runnerupPercent,
      winnerShare: round2((prize * winnerPercent) / 100),
      runnerupShare: round2(prize - round2((prize * winnerPercent) / 100)),
      ownerEarning: asNum(row.owner_earning_amount, 0),
      margin: round2(asNum(row.owner_earning_amount, 0) - asNum(row.venue_cost_amount, 0)),
      underwater: asNum(row.prize_amount, 0) <= 0 && settledPool > 0,
    };
  }

  const teams = teamsCounted == null
    ? Math.max(Number(row.teams_holding || 0), Number(row.min_teams))
    : Math.max(teamsCounted, Number(row.min_teams));
  const hours = fx.fixtureCount(row.format, teams);
  const listPrice = asNum(row.venue_price_per_hour, 0);
  const slotTotal = round2(listPrice * hours * (Number(row.slot_minutes || 60) / 60));
  return {
    ...fx.splitPool({
      entryFee: asNum(row.entry_fee, 0),
      teams,
      slotTotal,
      venueDiscountPercent: Number(row.venue_discount_percent),
      prizePercent,
      winnerPercent,
      runnerupPercent,
    }),
    settled: false,
    projectedFor: teams,
    hours,
    listPrice,
  };
}

/** The bracket grouped by round, which is how every bracket UI wants it. */
function groupRounds(rows, roundsTotal, format) {
  const byRound = new Map();
  for (const r of rows) {
    const n = Number(r.round);
    if (!byRound.has(n)) byRound.set(n, []);
    byRound.get(n).push(shapeFixture(r));
  }
  return [...byRound.keys()].sort((a, b) => a - b).map((n) => {
    const list = byRound.get(n);
    return {
      round: n,
      label: fx.roundLabel(n, roundsTotal, format),
      total: list.length,
      played: list.filter((f) => f.status !== fx.FIXTURE_STATUS.UPCOMING).length,
      date: list.map((f) => f.slotDate).filter(Boolean).sort()[0] || null,
      fixtures: list,
    };
  });
}

/**
 * detail — GET /api/tournaments/:id. The public overview (SRS FE-8) plus, for the
 * people entitled to it, the organiser's view of the same tournament.
 *
 * One endpoint serves the browse card, the bracket screen, the standings table and
 * the owner's management screen, because they are all the same tournament and a
 * second endpoint would be a second chance for them to disagree about how many
 * teams are in. What varies is `viewer` — the "can I press this" block — and the
 * visibility of withdrawn and rejected entries, which are the organiser's business
 * and nobody else's.
 *
 * `standings` is computed for both formats. A knockout does not have a league
 * table, but it does have "who beat whom, and how far did they get", and the same
 * derivation answers that; the UI shows it as a results table under the bracket.
 */
async function detail(client, { tournamentId, userId = null } = {}) {
  const t = await loadTournament(client, tournamentId);
  if (!t) return fail(404, 'not_found', 'Tournament not found');

  const isOwner = Boolean(userId) && String(t.owner_id) === String(userId);
  const all = await loadRegistrations(client, t.id);
  // Withdrawn and rejected entries are the organiser's record, not the public's.
  const visible = isOwner
    ? all
    : all.filter((r) => HOLDING.includes(r.status) || r.status === REG.ELIMINATED);

  const rows = await loadFixtures(client, t.id);
  const roundsTotal = Number(t.rounds) || (rows.length
    ? Math.max(...rows.map((r) => Number(r.round) || 1)) : 0);
  const field = all.filter((r) => r.status !== REG.REJECTED && r.status !== REG.WITHDRAWN);

  const table = fx.standings(
    field.map((r) => ({ id: r.team_id, name: r.team_name, elo: r.elo, seed: r.seed })),
    rows,
  );

  const holding = Number(t.teams_holding || 0);
  const deadlinePassed = new Date(t.registration_deadline).getTime() <= Date.now();

  return done(200, {
    tournament: shapeTournament(t),
    teams: visible.map(shapeRegistration),
    counts: {
      holding,
      accepted: Number(t.teams_accepted || 0),
      pending: Number(t.teams_pending || 0),
      withdrawn: all.filter((r) => r.status === REG.WITHDRAWN).length,
      rejected: all.filter((r) => r.status === REG.REJECTED).length,
    },
    bracket: {
      format: t.format,
      rounds: roundsTotal,
      size: rows.length ? fx.bracketSize(field.length) : null,
      byes: rows.filter((r) => r.is_bye).length,
      total: rows.length,
      played: rows.filter((r) => r.status !== fx.FIXTURE_STATUS.UPCOMING).length,
      generated: Boolean(t.fixtures_generated_at),
      roundsList: groupRounds(rows, roundsTotal, t.format),
    },
    fixtures: rows.map(shapeFixture),
    standings: table,
    economics: economicsOf(t, { teamsCounted: t.fixtures_generated_at ? null : holding }),
    viewer: await viewerContext(client, { tournament: t, userId, registrations: all }),
    organiser: isOwner ? {
      pendingApprovals: all.filter((r) => r.status === REG.REGISTERED).length,
      // The same two conditions `generateFixtures` will test, so the button is not
      // offered before it can work.
      canGenerate: t.status === STATUS.OPEN && !t.fixtures_generated_at
        && (deadlinePassed || holding >= Number(t.max_teams)),
      canCancel: t.status === STATUS.OPEN,
      deadlinePassed,
      unsettledFixtures: rows.filter(
        (r) => r.status === fx.FIXTURE_STATUS.UPCOMING && r.team_a && r.team_b,
      ).length,
    } : null,
  });
}

/**
 * mine — GET /api/tournaments/mine. Both roles in one call.
 *
 * A user can be an organiser and a player at the same time (the SRS does not stop
 * an owner from captaining a squad), and the phone has one "My tournaments" tab, so
 * splitting this into two endpoints would mean two round trips to draw one screen.
 *
 * `playing` follows TEAM MEMBERSHIP, not captaincy. Only a captain can enter a
 * tournament or be paid a prize, but every member plays in it and expects to find
 * it here; a squad member who could not see their own bracket would be a bug
 * reported as "the app forgot my tournament".
 */
async function mine(client, { userId, limit = 40 } = {}) {
  if (!isUuid(userId)) return fail(400, 'bad_user', 'Sign in to see your tournaments');
  const cap = Math.max(1, Math.min(Math.round(asNum(limit, 40)), 100));

  const organising = await client.query(
    `SELECT ${T_COLUMNS} ${T_FROM}
      WHERE t.owner_id = $1
      ORDER BY (t.status = 'open') DESC, t.registration_deadline DESC
      LIMIT $2`,
    [userId, cap],
  );

  const playing = await client.query(
    `SELECT ${T_COLUMNS},
            tt.team_id AS my_team_id, tt.status AS my_status, tt.seed AS my_seed,
            tt.paid_amount AS my_paid, tt.eliminated_round AS my_eliminated_round,
            tm.name AS my_team_name,
            (tm.captain_id = $1) AS i_am_captain
       ${T_FROM}
       JOIN tournament_teams tt ON tt.tournament_id = t.id
       JOIN teams tm ON tm.id = tt.team_id
      WHERE (tm.captain_id = $1
             OR EXISTS (SELECT 1 FROM team_members mm
                         WHERE mm.team_id = tm.id AND mm.user_id = $1))
        AND tt.status <> 'rejected'
      ORDER BY (t.status = 'open') DESC, t.registration_deadline DESC
      LIMIT $2`,
    [userId, cap],
  );

  return done(200, {
    organising: organising.rows.map((r) => ({
      ...shapeTournament(r),
      economics: economicsOf(r),
    })),
    playing: playing.rows.map((r) => ({
      ...shapeTournament(r),
      myEntry: {
        teamId: r.my_team_id,
        teamName: r.my_team_name,
        status: r.my_status,
        seed: r.my_seed == null ? null : Number(r.my_seed),
        paidAmount: asNum(r.my_paid, 0),
        eliminatedRound: r.my_eliminated_round == null ? null : Number(r.my_eliminated_round),
        isCaptain: Boolean(r.i_am_captain),
      },
    })),
  });
}

/**
 * browse — GET /api/tournaments. FE-2's filters, answered by ONE query.
 *
 * The list itself is `discoveryService.listTournaments`, which Scout already calls,
 * extended rather than forked so the assistant and the browse screen can never
 * disagree about which tournaments are open or how many spots are left. This
 * function is the camelCase adapter plus the countdown, and nothing else — Scout
 * keeps its snake_case rows untouched.
 */
async function browse(client, {
  sport = null, city = null, startFrom = null, status = null, q = '',
  venueId = null, ownerId = null, openOnly = true, limit = 20,
} = {}) {
  const rows = await discovery.listTournaments(client, {
    sport, city, startFrom, status, q, venueId, ownerId, openOnly, limit,
  });
  const now = Date.now();
  return done(200, {
    tournaments: rows.map((r) => {
      const deadline = iso(r.registration_deadline);
      const msLeft = deadline ? new Date(deadline).getTime() - now : null;
      return {
        id: r.id,
        name: r.name,
        description: r.description || null,
        sport: r.sport,
        format: r.format,
        status: r.status,
        ownerId: r.owner_id,
        organiserName: r.organiser_name || null,
        venue: { id: r.venue_id, name: r.venue_name || null, city: r.venue_city || null },
        entryFee: asNum(r.entry_fee, 0),
        maxTeams: Number(r.max_teams),
        minTeams: Number(r.min_teams),
        requiresApproval: Boolean(r.requires_approval),
        teamsRegistered: Number(r.teams_in || 0),
        teamsAccepted: Number(r.teams_accepted || 0),
        spotsLeft: Number(r.spotsLeft || 0),
        isFull: Boolean(r.isFull),
        registrationDeadline: deadline,
        // Published as seconds so a phone can count down without re-parsing the
        // date, and clamped at 0 so a stale row never shows a negative timer.
        secondsToDeadline: msLeft == null ? null : Math.max(0, Math.floor(msLeft / 1000)),
        startDate: dateStr(r.start_date),
        rounds: r.rounds == null ? null : Number(r.rounds),
        prizePercent: Number(r.prize_percent),
        pool: asNum(r.pool_amount, 0),
        prize: asNum(r.prize_amount, 0),
        winnerName: r.winner_name || null,
      };
    }),
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// TRANSACTIONS
//
// Every function above takes a `client` and never writes BEGIN, COMMIT or
// ROLLBACK, which is what lets `routes/matches.js` run `advanceAfterMatch` inside
// its own verify transaction and the deadline job run `generateFixtures` inside
// one it already holds. `runInTx` is the ONLY place in this module those three
// words appear, copied from bookingService.js so the rule is the same everywhere:
// a result with `ok: false` rolls back.
//
// That last part matters more here than anywhere else in the codebase. A refused
// generation has usually already written something — auto-rejected approvals, a
// refund, a slot flipped to blocked — and rolling back on the refusal is what
// keeps a tournament that could not be scheduled from being left half-drawn with
// eight captains' money in the wrong place.
// ─────────────────────────────────────────────────────────────────────────────

async function runInTx(fn) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const result = await fn(client);
    if (result && result.ok) await client.query('COMMIT');
    else await client.query('ROLLBACK');
    return result;
  } catch (e) {
    try { await client.query('ROLLBACK'); } catch { /* connection already gone */ }
    throw e;
  } finally {
    client.release();
  }
}

const createTx = (input) => runInTx((c) => create(c, input));
const registerTx = (input) => runInTx((c) => register(c, input));
const withdrawTx = (input) => runInTx((c) => withdraw(c, input));
const ownerDecisionTx = (input) => runInTx((c) => ownerDecision(c, input));
const cancelTx = (input) => runInTx((c) => cancel(c, input));
const generateFixturesTx = (input) => runInTx((c) => generateFixtures(c, input));
const settleFixtureTx = (input) => runInTx((c) => settleFixture(c, input));
const walkoverTx = (input) => runInTx((c) => walkover(c, input));

// Reads run on the pool directly: a read-only handler that opened a transaction
// would hold a connection for the length of a page render for no gain.
const previewRead = (input) => preview(pool, input);
const detailRead = (input) => detail(pool, input);
const mineRead = (input) => mine(pool, input);
const browseRead = (input) => browse(pool, input);

module.exports = {
  // constants
  STATUS,
  REG,
  HOLDING,
  TXN,
  DECISION,
  NAME_MAX,
  DESC_MAX,
  // shared SQL + loaders, exported for the job, the check script and the seeder
  T_COLUMNS,
  T_FROM,
  loadTournament,
  loadRegistrations,
  loadFixtures,
  loadFixture,
  captainOf,
  // shapers
  shapeTournament,
  shapeRegistration,
  shapeFixture,
  economicsOf,
  groupRounds,
  viewerContext,
  // validation, exported so the check script can assert the messages
  validateConfig,
  validateDates,
  requireOwnedVenue,
  pseudoField,
  readScore,
  drawWinner,
  // money helpers (in-transaction)
  chargeEntry,
  refundEntry,
  refundEveryone,
  // operations — client-taking, no BEGIN of their own
  preview,
  create,
  register,
  withdraw,
  ownerDecision,
  cancel,
  generateFixtures,
  applyFixtureResult,
  advanceWinner,
  completeTournament,
  settleFixture,
  walkover,
  matchContext,
  advanceAfterMatch,
  detail,
  mine,
  browse,
  // transaction owners — what routes and jobs call
  runInTx,
  createTx,
  registerTx,
  withdrawTx,
  ownerDecisionTx,
  cancelTx,
  generateFixturesTx,
  settleFixtureTx,
  walkoverTx,
  previewRead,
  detailRead,
  mineRead,
  browseRead,
};
