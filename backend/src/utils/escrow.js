/**
 * Escrow ledger — the one source of truth for SportLynk money math.
 *
 * | Event                      | Player balance | Player frozen | Owner balance | Status      |
 * | -------------------------- | -------------- | ------------- | ------------- | ----------- |
 * | Book slot (price P)        | -P             | +P            | —             | pending     |
 * | Owner approves (or auto)   | —              | —             | —             | confirmed   |
 * | Owner rejects (or auto)    | +P             | -P            | —             | rejected    |
 * | Cancel >= 24h before slot  | +P             | -P            | —             | cancelled   |
 * | Cancel < 24h before slot   | +0.8P          | -P            | +0.2P         | cancelled   |
 * | QR check-in                | —              | -P            | +P            | checked_in  |
 * | No-show (30 min after)     | +0.8P          | -P            | +0.2P         | no_show     |
 *
 * Every helper here must be called inside a transaction that already holds
 * `FOR UPDATE` locks on the booking + wallet rows (see lockWallet).
 */

const POLICY = {
  /** Player's at-risk deposit as a percentage of the slot price. */
  DEPOSIT_PERCENT: 20,
  /** Free-cancellation window before slot start, in hours. */
  CANCELLATION_WINDOW_HOURS: 24,
  /** Grace period after slot start before a confirmed booking becomes a no-show. */
  NO_SHOW_GRACE_MINUTES: 30,
  /** Trust-score penalty applied on a no-show. */
  NO_SHOW_TRUST_PENALTY: 10,
  /**
   * A pending request older than this is auto-decided (FR4.10). Held in minutes
   * rather than hours so a test override can be finer-grained than one hour
   * without pushing a fraction into `('x hours')::INTERVAL`.
   */
  AUTO_DECIDE_AFTER_MINUTES: 2 * 60,
  /** Pending requests whose slot starts sooner than this are auto-rejected. */
  AUTO_DECIDE_MIN_LEAD_HOURS: 2,
  /** Smallest withdrawal SportLynk will accept, in PKR (FR7.4). */
  WITHDRAWAL_MIN_AMOUNT: 200,
  /** How long a withdrawal sits `pending` before the job marks it paid out. */
  WITHDRAWAL_SETTLE_MINUTES: 24 * 60,
  /** How often the three background sweeps run. */
  SWEEP_INTERVAL_MS: 5 * 60 * 1000,
  /** Slot dates/times are stored as PKT wall-clock values. */
  TIMEZONE: 'Asia/Karachi',
};

// Test-only timing overrides
//
// The acceptance checklist asks for the 2h auto-approve rule to be tested
// "with a 1-min override constant". Editing the constant by hand works exactly
// once and then risks being committed, so the override lives in the environment
// instead: absent ⇒ the SRS defaults above, byte for byte.
//
// These knobs shift *timing only*. No override can change how much money moves —
// DEPOSIT_PERCENT, CANCELLATION_WINDOW_HOURS and NO_SHOW_TRUST_PENALTY are
// deliberately not overridable, because a test run must never be able to produce
// a ledger split that production would not.
//
// Anything set here is collected in ACTIVE_TEST_OVERRIDES so server.js can print
// a loud banner at boot — a silently sped-up sweep is worse than no override.
const ACTIVE_TEST_OVERRIDES = [];

function applyTestOverride(envVar, policyKey, scale = 1, unit = 'min') {
  const raw = process.env[envVar];
  if (raw === undefined || raw.trim() === '') return;
  const n = Number(raw);
  if (!Number.isFinite(n) || n < 0) {
    console.warn(`[escrow] ignoring ${envVar}="${raw}" — expected a non-negative number.`);
    return;
  }
  POLICY[policyKey] = n * scale;
  ACTIVE_TEST_OVERRIDES.push(`${envVar}=${n} ${unit} → POLICY.${policyKey}=${POLICY[policyKey]}`);
}

applyTestOverride('SL_TEST_AUTO_DECIDE_MINUTES', 'AUTO_DECIDE_AFTER_MINUTES');
applyTestOverride('SL_TEST_NO_SHOW_MINUTES', 'NO_SHOW_GRACE_MINUTES');
applyTestOverride('SL_TEST_SETTLE_MINUTES', 'WITHDRAWAL_SETTLE_MINUTES');
applyTestOverride('SL_TEST_SWEEP_SECONDS', 'SWEEP_INTERVAL_MS', 1000, 'sec');

/**
 * Human-readable delay for notification bodies: 120 → "2h", 90 → "1h 30m",
 * 1 → "1 min". Without this, a 1-minute override would tell the player their
 * booking was confirmed because the venue "did not respond within 0.0167h".
 */
function describeDelay(minutes) {
  const m = Math.max(0, Math.round(asNum(minutes)));
  if (m < 60) return `${m} min`;
  const h = Math.floor(m / 60);
  const rem = m % 60;
  return rem === 0 ? `${h}h` : `${h}h ${rem}m`;
}


/** pg returns decimal as strings — always parse before doing math. */
function asNum(value, fallback = 0) {
  if (value === null || value === undefined) return fallback;
  const n = typeof value === 'number' ? value : parseFloat(value);
  return Number.isFinite(n) ? n : fallback;
}

function round2(n) {
  return Math.round(asNum(n) * 100) / 100;
}

/**
 * The at-risk deposit for a slot price. Computed server-side only.
 *
 * `pct` lets the one caller that stamps the number onto a booking row
 * pass the admin-configured `deposit_pct` it just read inside its transaction.
 * Every other caller omits it and gets `POLICY.DEPOSIT_PERCENT`, which
 * `setDepositPercent` keeps in step with that setting — so the copy that describes
 * the policy and the amount held cannot disagree.
 */
function depositFor(price, pct = POLICY.DEPOSIT_PERCENT) {
  const p = Number.isFinite(Number(pct)) ? Number(pct) : POLICY.DEPOSIT_PERCENT;
  return round2(asNum(price) * (Math.min(Math.max(p, 0), 100) / 100));
}

/**
 * Point `POLICY.DEPOSIT_PERCENT` at the admin's configured value.
 *
 * Why a setter and not a read
 * `POLICY.DEPOSIT_PERCENT` is read from ~30 places, most of them building a
 * sentence ("20% of the total is your at-risk deposit") in synchronous code that
 * cannot await a settings row. Rather than make thirty call sites async — each a
 * chance to forget — the value is pushed in once at boot and again whenever an
 * admin saves settings, exactly the way `applyTestOverride` above writes it.
 *
 * This does not retroactively change any money: what a booking holds is the
 * `deposit_amount` column stamped when it was created, and every refund reads
 * that column. Out-of-band values are ignored rather than clamped, because a
 * settings row that says "abc" should leave the documented default in place, not
 * silently become 0% and stop protecting venues.
 */
function setDepositPercent(pct, source = 'settings') {
  const n = Number(pct);
  if (!Number.isFinite(n) || n < 0 || n > 100) return POLICY.DEPOSIT_PERCENT;
  if (round2(n) === round2(POLICY.DEPOSIT_PERCENT)) return POLICY.DEPOSIT_PERCENT;
  POLICY.DEPOSIT_PERCENT = round2(n);
  console.log(`[escrow] deposit percent → ${POLICY.DEPOSIT_PERCENT}% (${source})`);
  return POLICY.DEPOSIT_PERCENT;
}

/**
 * Split an escrowed amount for a late cancellation / no-show.
 * The penalty can never exceed what is held in escrow (protects
 * legacy bookings that were escrowed at 30% before this policy landed).
 */
function penaltySplit(escrowHeld, depositAmount) {
  const escrow = round2(escrowHeld);
  const penalty = Math.min(round2(depositAmount), escrow);
  return { refund: round2(escrow - penalty), penalty };
}

/**
 * Hours from now until a slot starts. slot_date + start_time are PKT
 * wall-clock values, so compare them against PKT "now".
 */
function hoursUntilSlot(slotDate, startTime, now = new Date()) {
  const dateStr =
    slotDate instanceof Date ? slotDate.toLocaleDateString('en-CA') : String(slotDate).slice(0, 10);
  const timeStr = String(startTime || '00:00:00').slice(0, 8);
  const slotStart = new Date(`${dateStr}T${timeStr}`);
  if (Number.isNaN(slotStart.getTime())) return Number.POSITIVE_INFINITY;
  return (slotStart - now) / (1000 * 60 * 60);
}

/** True when a cancellation happens inside the 24h window (80/20 split applies). */
function isLateCancellation(slotDate, startTime, now = new Date()) {
  return hoursUntilSlot(slotDate, startTime, now) < POLICY.CANCELLATION_WINDOW_HOURS;
}

/** Lock a user's wallet row for the rest of the transaction (creates it if missing). */
async function lockWallet(client, userId) {
  if (!userId) return null;
  const sql =
    'SELECT id, balance, frozen_balance FROM wallets WHERE user_id=$1 FOR UPDATE';
  const found = await client.query(sql, [userId]);
  if (found.rows.length) return found.rows[0];

  await client.query(
    'INSERT INTO wallets (user_id, balance, frozen_balance) VALUES ($1, 0, 0) ON CONFLICT (user_id) DO NOTHING',
    [userId],
  );
  const created = await client.query(sql, [userId]);
  return created.rows[0] || null;
}

/**
 * Apply a signed delta to a locked wallet. Balances are clamped at 0 so a bad
 * legacy row can never push a wallet negative.
 */
async function applyWallet(client, walletId, { balance = 0, frozen = 0 }) {
  const r = await client.query(
    `UPDATE wallets
        SET balance = GREATEST(balance + $1, 0),
            frozen_balance = GREATEST(frozen_balance + $2, 0)
      WHERE id = $3
      RETURNING id, balance, frozen_balance`,
    [round2(balance), round2(frozen), walletId],
  );
  return r.rows[0] || null;
}

/**
 * Append one row to the transaction ledger. Returns the new row's id so a caller
 * that needs to point at the ledger entry it just created (withdrawals.txn_id)
 * can do so without a second query. Existing callers ignore the return value.
 *
 * `tournamentId` (019) is the tournament equivalent of `bookingId`: a tournament
 * moves money for up to 32 captains plus the owner across four events, none of
 * which has a booking, so without it the entry fees, the commission and the prize
 * would be loose rows identifiable only by parsing `description`.
 *
 * The column is only named when a caller supplies one. That is deliberate: every
 * booking, wallet and match caller passes nothing, so their INSERT stays exactly
 * the statement it was before 019 and cannot break on a database where 019 has not
 * been applied yet. A tournament caller gets the 019 column and, if the migration
 * is missing, a loud 42703 — which is the right outcome, because a tournament whose
 * ledger rows silently lost their tournament_id would break the "pool in equals
 * venue cost plus prize plus margin out" audit without breaking anything visible.
 */
/**
 * Is the `platform_commission` ledger type available in this database?
 *
 * Why a probe and not a try/catch
 * `transactions.type` is a Postgres ENUM, and an unknown label is a 22P02 that
 * aborts the whole transaction -- which at check-in means the escrow release and
 * the check-in itself roll back too. A player standing at the ground with a valid
 * QR code must not be turned away because a migration has not been run, so the
 * capability is checked before any write and the commission is skipped (loudly,
 * once) when the label is missing.
 *
 * Cached true-only, exactly like `elo.supportsCorrection`: an enum value cannot be
 * removed by `ALTER TYPE`, so once present it is present for the life of the
 * process, and a false is worth re-checking after `run_migration_021.js` runs.
 */
let commissionTxnReady = false;
async function supportsCommissionTxn(client) {
  if (commissionTxnReady) return true;
  try {
    const { rows } = await client.query(
      `SELECT 1 FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
        WHERE t.typname = 'txn_type' AND e.enumlabel = 'platform_commission' LIMIT 1`,
    );
    // No such enum type at all (a text column) means nothing to violate.
    if (rows.length) { commissionTxnReady = true; return true; }
    const { rows: isEnum } = await client.query(
      "SELECT 1 FROM pg_type WHERE typname = 'txn_type' LIMIT 1",
    );
    if (!isEnum.length) { commissionTxnReady = true; return true; }
    return false;
  } catch {
    // A probe that cannot run must not decide policy; assume unavailable and let
    // the caller skip, which is the outcome that keeps money correct.
    return false;
  }
}

/**
 * The platform's cut of one released escrow, and what is left for the venue.
 *
 * Rounded so that `net + commission === gross` exactly, with the rounding
 * remainder given to the owner rather than the platform. Two independently
 * rounded halves can differ from the whole by a paisa, and a ledger that does not
 * add up is worth more trouble than a paisa.
 */
function commissionSplit(gross, pct) {
  const g = round2(gross);
  const p = Number.isFinite(Number(pct)) ? Math.min(Math.max(Number(pct), 0), 100) : 0;
  if (p <= 0 || g <= 0) return { gross: g, commission: 0, net: g, pct: 0 };
  const commission = round2(g * (p / 100));
  return { gross: g, commission, net: round2(g - commission), pct: p };
}

async function logTxn(client, {
  walletId, userId, bookingId, tournamentId = null, type, amount, balanceAfter, description, counterparty,
}) {
  if (!walletId) return null;
  const withTournament = tournamentId != null;
  const r = await client.query(
    `INSERT INTO transactions
       (wallet_id, user_id, booking_id, type, amount, balance_after, description, counterparty_name${
       withTournament ? ', tournament_id' : ''})
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8${withTournament ? ',$9' : ''})
     RETURNING id`,
    [
      walletId,
      userId,
      bookingId,
      type,
      round2(amount),
      round2(balanceAfter),
      description,
      counterparty || null,
      ...(withTournament ? [tournamentId] : []),
    ],
  );
  return r.rows[0] ? r.rows[0].id : null;
}

module.exports = {
  POLICY,
  ACTIVE_TEST_OVERRIDES,
  describeDelay,
  asNum,
  round2,
  depositFor,
  setDepositPercent,
  supportsCommissionTxn,
  commissionSplit,
  penaltySplit,
  hoursUntilSlot,
  isLateCancellation,
  lockWallet,
  applyWallet,
  logTxn,
};
