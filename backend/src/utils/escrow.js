/**
 * Escrow ledger — the ONE source of truth for SportLynk money math.
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
  /** A pending request older than this is auto-decided (FR4.10). */
  AUTO_DECIDE_AFTER_HOURS: 2,
  /** Pending requests whose slot starts sooner than this are auto-rejected. */
  AUTO_DECIDE_MIN_LEAD_HOURS: 2,
  /** Slot dates/times are stored as PKT wall-clock values. */
  TIMEZONE: 'Asia/Karachi',
};

/** pg returns DECIMAL as strings — always parse before doing math. */
function asNum(value, fallback = 0) {
  if (value === null || value === undefined) return fallback;
  const n = typeof value === 'number' ? value : parseFloat(value);
  return Number.isFinite(n) ? n : fallback;
}

function round2(n) {
  return Math.round(asNum(n) * 100) / 100;
}

/** 20% of the slot price — the at-risk deposit. Computed server-side only. */
function depositFor(price) {
  return round2(asNum(price) * (POLICY.DEPOSIT_PERCENT / 100));
}

/**
 * Split an escrowed amount for a late cancellation / no-show.
 * The penalty can never exceed what is actually held in escrow (protects
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

/** Append one row to the transaction ledger. */
async function logTxn(client, { walletId, userId, bookingId, type, amount, balanceAfter, description, counterparty }) {
  if (!walletId) return;
  await client.query(
    `INSERT INTO transactions
       (wallet_id, user_id, booking_id, type, amount, balance_after, description, counterparty_name)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8)`,
    [
      walletId,
      userId,
      bookingId,
      type,
      round2(amount),
      round2(balanceAfter),
      description,
      counterparty || null,
    ],
  );
}

module.exports = {
  POLICY,
  asNum,
  round2,
  depositFor,
  penaltySplit,
  hoursUntilSlot,
  isLateCancellation,
  lockWallet,
  applyWallet,
  logTxn,
};
