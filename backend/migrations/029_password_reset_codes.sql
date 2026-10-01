-- ════════════════════════════════════════════════════════════════════════════
-- 029_password_reset_codes.sql   ·   server-owned OTP for password reset
-- ════════════════════════════════════════════════════════════════════════════
--
-- Closes an authentication-bypass in the forgot-password flow. The old
-- POST /auth/forgot-password/reset trusted a client-supplied `firebaseUid`: any
-- caller who sent a non-empty value could set a new password for ANY phone number,
-- because verification lived only in the app. Nothing on the server proved the
-- caller controlled the number.
--
-- The fix moves the one-time code to the server. On "send code" the API generates a
-- six-digit code, stores only its keyed hash here (never the code itself), and sends
-- the code over SMS. On "reset" the API re-hashes the submitted code and compares it
-- to the stored hash before it touches `users.password_hash`. A stolen database row
-- does not reveal a live code, and the client can no longer forge verification.
--
-- One row per send. `expires_at` bounds the code's life, `attempts` caps guessing,
-- and `consumed_at` makes a successful reset single-use. Rows are kept (not deleted
-- on use) so the recent-send count can rate-limit resends and protect the SMS budget.
--
-- Purely additive: a new table and its indexes only. No existing table is altered,
-- and there is no DROP, TRUNCATE, or DELETE here.

CREATE TABLE IF NOT EXISTS password_reset_codes (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  phone       text NOT NULL,                     -- the number the code was sent to
  code_hash   text NOT NULL,                     -- HMAC-SHA256(code, JWT_SECRET); never the code
  attempts    integer NOT NULL DEFAULT 0,        -- wrong guesses so far; capped in the service
  consumed_at timestamptz,                       -- set once, when a reset succeeds (single-use)
  expires_at  timestamptz NOT NULL,              -- short TTL; a stale code cannot be used
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- The two reads the service makes: the newest code for a phone (verify + resend
-- cooldown), and, kept for symmetry with the requests tables, the codes for a user.
CREATE INDEX IF NOT EXISTS idx_password_reset_codes_phone
  ON password_reset_codes (phone, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_password_reset_codes_user
  ON password_reset_codes (user_id, created_at DESC);

COMMENT ON TABLE password_reset_codes IS
  'Server-owned one-time codes for phone-based password reset. Stores the keyed '
  'hash of each six-digit code (never the code), with a TTL, an attempts cap and a '
  'single-use consumed_at, so verification cannot be forged by the client.';
