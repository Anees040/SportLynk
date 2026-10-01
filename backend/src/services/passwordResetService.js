/**
 * passwordResetService.js — server-owned OTP for phone-based password reset.
 *
 * The hole this closes
 * The old reset route trusted a client-supplied `firebaseUid`: any caller who sent a
 * non-empty value could set a new password for ANY phone number, because the OTP was
 * only ever checked inside the app. Nothing on the server proved the caller controlled
 * the number. This service moves the code to the server: `sendCode` generates a
 * six-digit code, stores only its keyed hash (never the code) and sends the code over
 * SMS; `verifyAndReset` re-hashes the submitted code and compares it to the stored hash
 * before it touches `users.password_hash`. A stolen `password_reset_codes` row reveals
 * no live code, and the client can no longer forge verification.
 *
 * Why no wrapping transaction
 * Unlike the request/team services, these functions run against the pool in autocommit,
 * not inside a route-owned BEGIN/COMMIT. The reason is the attempts counter: a wrong
 * guess must PERSIST its `attempts = attempts + 1`, and a route that rolled back on a
 * business failure (the requests.js pattern) would erase exactly that increment and
 * uncap guessing. The success path consumes the code before it writes the password, so
 * an interruption between the two leaves a spent code and an unchanged password — a
 * safe, self-correcting failure (request a fresh code), never a reusable one.
 *
 * The return shape is the services' usual `{ ok, status, code, message, data }`.
 */
const crypto = require('crypto');
const bcrypt = require('bcrypt');
const sms = require('./smsService');

// Code lifetime and guardrails. The window/cooldown pair is the real SMS-budget
// protection: the app-wide IP limiter runs behind Render's proxy with `trust proxy`
// deliberately low, so this per-phone limit in the table is what actually bounds sends.
// MAX_ATTEMPTS caps online guessing far below the 1-in-a-million a single guess faces.
const CODE_LENGTH = 6;
const CODE_TTL_MIN = 10;
const MAX_ATTEMPTS = 5;
const RESEND_COOLDOWN_SEC = 60;
const MAX_SENDS_PER_WINDOW = 5;
const SEND_WINDOW_MIN = 60;

const err = (status, code, message) => ({ ok: false, status, code, message, data: null });

// The single answer every "the code did not check out" branch returns, so a caller
// cannot tell an unknown code from an expired or already-used one.
const invalid = () => err(400, 'invalid_code', 'Invalid or expired code. Request a new one.');

/**
 * The keyed hash stored in place of the code. HMAC with JWT_SECRET as the pepper means a
 * leaked table is not a leaked code: without the secret the six-digit space cannot be
 * brute-forced back from the hash. JWT_SECRET is already a hard requirement for auth, so
 * depending on it here adds no new operational surface.
 */
function hashCode(code) {
  return crypto.createHmac('sha256', process.env.JWT_SECRET).update(String(code)).digest('hex');
}

/** A uniform six-digit code, zero-padded. crypto.randomInt is unbiased and CSPRNG-backed. */
function generateCode() {
  return crypto.randomInt(0, 10 ** CODE_LENGTH).toString().padStart(CODE_LENGTH, '0');
}

/**
 * Issue a code to the account that owns `phone`. The SMS is sent BEFORE the row is
 * written, and a send that cannot happen stores nothing: an undelivered code must not sit
 * in the table pretending a reset is in progress, nor skew the resend window. The 404 for
 * an unknown number is kept deliberately — phone signup already discloses existence, and a
 * user recovering a forgotten account needs to know which number has one; the per-phone
 * cooldown and window bound both the enumeration and the SMS spend.
 */
async function sendCode(client, { phone }) {
  const cleanPhone = String(phone || '').replace(/\s/g, '');
  if (!cleanPhone) return err(400, 'bad_phone', 'Phone required');

  const found = await client.query('SELECT id FROM users WHERE phone = $1', [cleanPhone]);
  if (found.rows.length === 0) {
    return err(404, 'not_found', 'No account found with this phone number');
  }
  const userId = found.rows[0].id;

  // Cooldown and window evaluated against the database clock so process/DB skew widens
  // neither. in_cooldown blocks a rapid resend; in_window bounds the hour.
  const rl = await client.query(
    `SELECT
       count(*) FILTER (WHERE created_at > now() - ($2 || ' seconds')::interval) AS in_cooldown,
       count(*) FILTER (WHERE created_at > now() - ($3 || ' minutes')::interval) AS in_window
       FROM password_reset_codes
      WHERE phone = $1`,
    [cleanPhone, String(RESEND_COOLDOWN_SEC), String(SEND_WINDOW_MIN)],
  );
  if (Number(rl.rows[0].in_cooldown || 0) > 0) {
    return err(429, 'cooldown', 'A code was just sent. Please wait a minute before requesting another.');
  }
  if (Number(rl.rows[0].in_window || 0) >= MAX_SENDS_PER_WINDOW) {
    return err(429, 'rate_limited', 'Too many code requests. Please try again later.');
  }

  const code = generateCode();
  const message = `Your SportLynk password reset code is ${code}. `
    + `It expires in ${CODE_TTL_MIN} minutes. Do not share it.`;

  const sent = await sms.sendSms(cleanPhone, message);
  if (!sent.ok) {
    // Nothing is stored on a failed send. Disabled (no gateway) and a gateway error are
    // told apart so the status story stays honest, but both are a plain "try later".
    if (sent.disabled) {
      return err(503, 'sms_disabled', 'The SMS service is not available right now. Please try again later.');
    }
    return err(502, 'sms_failed', 'Could not send the code right now. Please try again.');
  }

  await client.query(
    `INSERT INTO password_reset_codes (user_id, phone, code_hash, expires_at)
     VALUES ($1, $2, $3, now() + ($4 || ' minutes')::interval)`,
    [userId, cleanPhone, hashCode(code), String(CODE_TTL_MIN)],
  );

  return {
    ok: true,
    status: 200,
    code: null,
    message: 'A verification code has been sent to your phone.',
    data: { expiresInSeconds: CODE_TTL_MIN * 60 },
  };
}

/**
 * Verify a submitted code and, only on a match, set the new password. The newest code for
 * the phone is the one that counts; a missing, consumed or expired row and a wrong code
 * all return the same generic invalid() so nothing about the code's state leaks. A wrong
 * guess costs one of MAX_ATTEMPTS. The compare is constant-time.
 */
async function verifyAndReset(client, { phone, code, newPassword }) {
  const cleanPhone = String(phone || '').replace(/\s/g, '');
  const codeStr = String(code || '').trim();
  if (!newPassword || newPassword.length < 8) {
    return err(400, 'weak_password', 'Password must be at least 8 characters');
  }
  if (!cleanPhone || !codeStr) return invalid();

  const { rows } = await client.query(
    `SELECT id, user_id, code_hash, attempts, consumed_at, (expires_at < now()) AS expired
       FROM password_reset_codes
      WHERE phone = $1
      ORDER BY created_at DESC
      LIMIT 1`,
    [cleanPhone],
  );
  const row = rows[0];
  if (!row || row.consumed_at || row.expired) return invalid();
  if (row.attempts >= MAX_ATTEMPTS) {
    return err(429, 'too_many_attempts', 'Too many incorrect attempts. Request a new code.');
  }

  // Constant-time compare over the hashes; both are sha256 hex (32 bytes). The length
  // guard keeps timingSafeEqual from throwing on a malformed stored value.
  const submitted = Buffer.from(hashCode(codeStr), 'hex');
  const stored = Buffer.from(String(row.code_hash), 'hex');
  const match = submitted.length === stored.length && crypto.timingSafeEqual(submitted, stored);

  if (!match) {
    await client.query('UPDATE password_reset_codes SET attempts = attempts + 1 WHERE id = $1', [row.id]);
    return invalid();
  }

  // Consume before writing the password: a spent code that never changed a password is a
  // safe interruption, a reusable one is not. Sibling live codes for the phone are spent
  // too, so a completed reset leaves no outstanding code behind.
  await client.query('UPDATE password_reset_codes SET consumed_at = now() WHERE id = $1', [row.id]);
  await client.query(
    'UPDATE password_reset_codes SET consumed_at = now() WHERE phone = $1 AND consumed_at IS NULL AND id <> $2',
    [cleanPhone, row.id],
  );

  const hashed = await bcrypt.hash(newPassword, 12);
  // By user_id, not phone: the account is the one the code was issued to, immune to a
  // phone row that changed between send and reset.
  await client.query('UPDATE users SET password_hash = $1 WHERE id = $2', [hashed, row.user_id]);

  return {
    ok: true,
    status: 200,
    code: null,
    message: 'Your password has been reset. You can now log in.',
    data: { userId: String(row.user_id) },
  };
}

module.exports = {
  sendCode,
  verifyAndReset,
  hashCode,
  generateCode,
  CODE_LENGTH,
  CODE_TTL_MIN,
  MAX_ATTEMPTS,
  RESEND_COOLDOWN_SEC,
  MAX_SENDS_PER_WINDOW,
  SEND_WINDOW_MIN,
};
