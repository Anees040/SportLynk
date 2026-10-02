-- 032_booking_disputes.sql — a player-facing dispute + refund path for bookings.
--
-- Why a new table rather than reusing `disputes` (013)
-- `disputes` is match-scoped: its foreign keys are match_id and raised_by_team, and
-- its lifecycle (elo freeze, severity) is about a contested result. A booking dispute
-- is a different thing — "I was charged but the slot was double-booked", "the owner
-- never showed" — raised by one PLAYER against one BOOKING, resolved by an admin into
-- a refund or a rejection. Overloading the match table would put two unrelated
-- lifecycles behind one status column; a separate table keeps each honest.
--
-- Money is NOT moved here. This table only records the claim and its verdict. The
-- refund, when a dispute is upheld, is performed by bookingDisputeService through the
-- same escrow helpers (lockWallet / applyWallet / logTxn) that cancelBooking uses, so
-- there is still exactly one implementation of "move money for a booking".
--
-- Purely additive: CREATE ... IF NOT EXISTS and nothing else. No DROP, TRUNCATE or
-- DELETE, so a second application is a no-op and no live row is ever at risk.

CREATE TABLE IF NOT EXISTS booking_disputes (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id        UUID NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  raised_by         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  reason            text NOT NULL,
  -- open      — waiting for an admin
  -- upheld    — admin agreed; a refund was issued (refund_amount records how much)
  -- rejected  — admin declined; no money moved
  status            text NOT NULL DEFAULT 'open'
                      CHECK (status IN ('open', 'upheld', 'rejected')),
  resolution_notes  text,
  refund_amount     numeric(10,2),
  resolved_by       UUID REFERENCES users(id),
  created_at        timestamptz NOT NULL DEFAULT now(),
  resolved_at       timestamptz
);

-- One OPEN dispute per booking at a time: a player cannot flood the admin queue by
-- re-filing, but a rejected dispute does not block a genuinely new one later (the
-- partial predicate only covers the open row).
CREATE UNIQUE INDEX IF NOT EXISTS ux_booking_disputes_open
  ON booking_disputes (booking_id) WHERE status = 'open';

-- The admin queue reads open-first; the player's own list reads by raiser.
CREATE INDEX IF NOT EXISTS idx_booking_disputes_status ON booking_disputes (status, created_at);
CREATE INDEX IF NOT EXISTS idx_booking_disputes_raised_by ON booking_disputes (raised_by, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_booking_disputes_booking ON booking_disputes (booking_id);
