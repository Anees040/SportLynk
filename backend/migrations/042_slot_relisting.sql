-- ════════════════════════════════════════════════════════════════════════════
-- 042_slot_relisting.sql   ·   "Just freed" re-listing marker on slots (item 8)
-- ════════════════════════════════════════════════════════════════════════════
--
-- A booking cancelled close to kickoff frees a prime slot that is hard to re-fill in
-- the time left. To help genuine players snap it up, bookingService.cancelBooking
-- stamps the freed slot with the moment it was re-listed, and the venue page shows a
-- "just freed" badge on a slot stamped within the recent window.
--
-- Additive and idempotent: a nullable timestamp column plus a partial index over the
-- slots that actually carry a stamp. No existing row is rewritten. The slot grid
-- already selects `s.*`, so the column reaches the client with no query change — the
-- Flutter side treats a NULL or stale stamp as "no badge", so this is safe to apply
-- before or after the client ships.
--
-- Numbered 042: 041 was taken by a concurrent session's 041_multi_challenge.sql.
-- Confirm this is still the next free number before applying.

ALTER TABLE slots ADD COLUMN IF NOT EXISTS relisted_at TIMESTAMPTZ;

COMMENT ON COLUMN slots.relisted_at IS
  'When this slot was last freed by a near-kickoff cancellation (item 8 re-listing). '
  'bookingService.cancelBooking sets it inside RELIST_WINDOW_HOURS of the slot; the '
  'venue page badges a still-available slot stamped within the recent window. NULL = '
  'never re-listed.';

CREATE INDEX IF NOT EXISTS idx_slots_relisted_at
  ON slots (relisted_at DESC)
  WHERE relisted_at IS NOT NULL AND status = 'available';
