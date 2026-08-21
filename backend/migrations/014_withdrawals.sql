-- Migration 014: Withdrawal requests with a real pending → completed lifecycle
--                (Wave F — FR7.4 / ER1.6)
--
-- ─── Why this migration exists at all ──────────────────────────────────────────
-- Wave D's brief said "don't extend the schema beyond migration 013". This file
-- is a deliberate, single, signed-off exception, agreed before it was written.
--
-- The wave spec offered two shapes: "simulated completion after 24h — or instant
-- with status:'completed' for demo". The instant option needs no schema change,
-- but `transactions` has no status column, so a withdrawal that is genuinely
-- *pending* is not representable at all — and the SRS requirement "one pending at
-- a time" is meaningless without a pending state to count. The instant option
-- would have made that requirement vacuous rather than implemented.
--
-- So: one new table, no changes to any existing table, no new enum type.
--
-- ─── Where the money is ───────────────────────────────────────────────────────
-- The debit happens at REQUEST time, not at completion:
--
--   request    balance -= amount   + 1 transactions row (type='withdrawal')  pending
--   completes  no money moves      no ledger row                             completed
--   cancelled  balance += amount   + 1 transactions row (type='refund')      cancelled
--
-- Two consequences worth knowing before reading the code:
--
--   1. The hold is NOT kept in wallets.frozen_balance. frozen_balance means
--      "booking escrow", and the same wave ships an itemised per-booking
--      breakdown of it (FR7.2). A withdrawal hold parked in there would make that
--      breakdown silently disagree with its own total.
--   2. Completion is money-neutral on purpose — the money already left at
--      request time, so you cannot spend what you have asked to withdraw. This
--      mirrors autoApproveJob.autoConfirm, which is also money-neutral.
--
-- Re-running this file is a no-op: every statement is IF NOT EXISTS.

CREATE TABLE IF NOT EXISTS withdrawals (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  wallet_id      UUID NOT NULL REFERENCES wallets(id),
  amount         DECIMAL(10,2) NOT NULL CHECK (amount > 0),

  -- TEXT + CHECK rather than a new enum type. An enum would need ALTER TYPE
  -- handling in the runner (it cannot run inside a transaction — the exact
  -- problem migration 010 had to work around with a @@SPLIT@@ marker) and buys
  -- nothing here. 'failed' exists so a real payout gateway can be wired in S.7
  -- without another migration.
  status         TEXT NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending', 'completed', 'failed', 'cancelled')),

  -- Payout destination. Simulated for the FYP demo; these are the three methods
  -- that actually matter in Pakistan.
  method         TEXT NOT NULL DEFAULT 'easypaisa'
                 CHECK (method IN ('easypaisa', 'jazzcash', 'bank')),
  account_name   TEXT,
  account_number TEXT,

  -- The ledger row that carried the debit. Nullable because the FK target is
  -- written in the same transaction and a legacy/imported row may not have one.
  txn_id         UUID REFERENCES transactions(id) ON DELETE SET NULL,

  requested_at   TIMESTAMP NOT NULL DEFAULT NOW(),
  completed_at   TIMESTAMP,
  failure_reason TEXT
);

-- "One pending withdrawal at a time" (ER1.6), enforced by the DATABASE.
--
-- This is the whole reason the constraint is a partial unique index and not a
-- `SELECT ... WHERE status='pending'` guard in JS: two taps that arrive in the
-- same millisecond both pass a JS check and both insert. Here the second INSERT
-- raises 23505 and the route turns that into a 409. Completed/cancelled/failed
-- rows are excluded by the WHERE, so a user still accumulates full history.
CREATE UNIQUE INDEX IF NOT EXISTS uq_withdrawals_one_pending
  ON withdrawals (user_id)
  WHERE status = 'pending';

-- Serves GET /api/wallet/withdrawals — one user's history, newest first.
CREATE INDEX IF NOT EXISTS idx_withdrawals_user
  ON withdrawals (user_id, requested_at DESC);

-- Serves the withdrawalJob sweep, which reads only pending rows ordered by age.
-- Partial, so it stays tiny no matter how much completed history accumulates.
CREATE INDEX IF NOT EXISTS idx_withdrawals_pending
  ON withdrawals (status, requested_at)
  WHERE status = 'pending';
