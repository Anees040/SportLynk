/**
 * policyText.js — Scout's policy answers, rendered from the one source of truth.
 *
 * Golden rule 3: utils/escrow.js POLICY is the only authority on money and timing.
 * global_settings is a convenience layer and must never silently become
 * authoritative — migration 013's own header says so.
 *
 * That rule collides with wanting the assistant's wording editable without a
 * deploy. The collision is resolved by splitting the two things a policy answer
 * is made of:
 *
 *   the sentence  editable text, stored in global_settings.assistant.policy_text
 *   the numbers   never stored; substituted here from escrow.js POLICY at render
 *
 * So a seeded template reads
 *
 *   "Cancel {window_hours}h or more before your slot starts and you get a full
 *    refund. Cancel later and {refund_pct}% comes back to your wallet..."
 *
 * and the only way for Scout to quote 24h and 80% is for those to be the policy.
 * Change CANCELLATION_WINDOW_HOURS and every answer changes with it, in every
 * language, with no second place to remember to edit. run_migration_018.js
 * asserts no seeded template contains a literal money or timing number, and
 * test/assistant.test.js asserts every placeholder in every template resolves —
 * a typo'd `{window_hrs}` fails a test instead of reaching a user as raw braces.
 *
 * Nothing here reads the database. `topic()` takes the already-fetched settings
 * object, so a caller inside a transaction is not made to open a second one.
 */
const { POLICY } = require('./escrow');

/** Human "2 hours" from 120 minutes, because "{auto_decide} minutes" reads badly. */
function humanMinutes(mins) {
  const n = Number(mins);
  if (!Number.isFinite(n) || n <= 0) return '0 minutes';
  if (n % 60 === 0) {
    const h = n / 60;
    return `${h} hour${h === 1 ? '' : 's'}`;
  }
  if (n < 60) return `${n} minute${n === 1 ? '' : 's'}`;
  return `${Math.floor(n / 60)}h ${n % 60}m`;
}

/**
 * Every placeholder a template may use, resolved from POLICY.
 *
 * Adding a key here is safe. Renaming one is not: the seeded templates in
 * migration 018 use these exact names, so a rename must land in both places or
 * `unfilled()` starts reporting.
 */
function values() {
  const depositPct = Number(POLICY.DEPOSIT_PERCENT);
  return {
    deposit_pct: depositPct,
    refund_pct: 100 - depositPct,
    window_hours: Number(POLICY.CANCELLATION_WINDOW_HOURS),
    no_show_grace: Number(POLICY.NO_SHOW_GRACE_MINUTES),
    trust_penalty: Number(POLICY.NO_SHOW_TRUST_PENALTY),
    auto_decide: humanMinutes(POLICY.AUTO_DECIDE_AFTER_MINUTES),
    withdrawal_min: Number(POLICY.WITHDRAWAL_MIN_AMOUNT),
    timezone: String(POLICY.TIMEZONE),
  };
}

/** `{placeholder}` occurrences, in order, deduplicated. */
function placeholdersIn(template) {
  const found = new Set();
  for (const m of String(template).matchAll(/\{([a-z0-9_]+)\}/gi)) found.add(m[1]);
  return [...found];
}

/**
 * Substitute POLICY values into one template.
 *
 * An unknown placeholder is left exactly as written rather than replaced with an
 * empty string: "you get a % refund" is a sentence a user would believe, and
 * "you get a {refund_pctt}% refund" is one they would report.
 */
function render(template, extra = {}) {
  if (typeof template !== 'string' || !template) return '';
  const vals = { ...values(), ...extra };
  return template.replace(/\{([a-z0-9_]+)\}/gi, (whole, key) => (
    Object.prototype.hasOwnProperty.call(vals, key) ? String(vals[key]) : whole
  ));
}

/** Placeholders in `template` that render() cannot fill. Empty is the healthy case. */
function unfilled(template) {
  const known = values();
  return placeholdersIn(template).filter(
    (k) => !Object.prototype.hasOwnProperty.call(known, k),
  );
}

/**
 * The seven topics migration 018 seeds. Named here so a missing one is a visible
 * gap rather than an undefined lookup, and so the capability menu can list them.
 */
const TOPICS = Object.freeze([
  'refund_policy', 'deposit', 'no_show', 'checkin', 'approval', 'topup', 'withdrawal',
]);

/**
 * Hard fallbacks, used only when global_settings has no row for a topic.
 *
 * These are deliberately terse. They exist so Scout can still answer a policy
 * question on a database that has not been seeded — not as a second copy of the
 * wording, which is what would drift.
 */
const FALLBACKS = Object.freeze({
  refund_policy: 'Cancel {window_hours}h or more before your slot for a full refund. '
    + 'Later than that, {refund_pct}% is refunded and the {deposit_pct}% deposit goes to the venue.',
  deposit: 'Booking holds the full slot price in escrow. {deposit_pct}% of it is your at-risk deposit.',
  no_show: 'Check in within {no_show_grace} minutes of your slot starting, or the booking is a '
    + 'no-show: {refund_pct}% back, {deposit_pct}% to the venue, and {trust_penalty} trust points off.',
  checkin: 'Show your booking QR code at the ground to check in and release the escrow.',
  approval: 'Bookings start pending until the owner approves. Undecided after {auto_decide}, '
    + 'they are decided automatically.',
  topup: 'Open Wallet and tap Top Up.',
  withdrawal: 'You can withdraw unfrozen balance above PKR {withdrawal_min}.',
});

/**
 * The rendered answer for one policy topic.
 *
 * @param {string} name     one of TOPICS
 * @param {object} settings the assistant settings block (globalSettings.assistant())
 * @returns {{topic:string, text:string, source:string, seeded:boolean}}
 *   `source` is always 'policy' — every one of these answers is rules text, and
 *   Scout's reply carries that word so a reader knows no model was involved.
 */
function topic(name, settings = {}) {
  const key = String(name || '').trim();
  const stored = settings && settings.policyText ? settings.policyText[key] : null;
  const template = typeof stored === 'string' && stored.trim()
    ? stored
    : (FALLBACKS[key] || '');
  return {
    topic: key,
    text: render(template),
    source: 'policy',
    seeded: !!(typeof stored === 'string' && stored.trim()),
  };
}

/** All seven, rendered. For the capability menu and for the verification script. */
function all(settings = {}) {
  return TOPICS.map((name) => topic(name, settings));
}

module.exports = {
  TOPICS,
  FALLBACKS,
  values,
  render,
  placeholdersIn,
  unfilled,
  topic,
  all,
  humanMinutes,
};
