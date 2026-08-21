-- Migration 010: Escrow ledger & policy alignment (Wave A)
--
-- Policy source of truth (SRS) — mirrored in doc/ARCHITECTURE.md:
--   escrow        = FULL slot price P, frozen at booking, released to owner on check-in
--   deposit       = 20% of P  → the player's at-risk slice (late cancel / no-show)
--   cancellation  = >= 24h before slot: 100% refund | < 24h: 80% player, 20% owner
--   no-show       = 30 min after slot start: 80% player, 20% owner, trust_score -10
--   auto-decision = pending > 2h & slot > 2h away → confirm | slot < 2h away → reject + full refund
--
-- Column semantics (kept backwards-compatible on purpose):
--   bookings.security_deposit = amount ACTUALLY HELD in escrow for that booking
--                               (legacy rows: 30% of price, new rows: full price)
--   bookings.deposit_amount   = 20% at-risk deposit, computed server-side only
--
-- Run with:  node run_migration_010.js
-- The runner executes each split-marker chunk as its own command because
-- ALTER TYPE ... ADD VALUE cannot run inside a multi-command string.
-- (The marker is the line "-- @@" + "SPLIT@@" below; never write it in prose.)

ALTER TYPE booking_status ADD VALUE IF NOT EXISTS 'rejected';

-- @@SPLIT@@

-- ─── 1. Deposit column (20% of price, server-computed) ──────────────
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS deposit_amount DECIMAL(10,2) DEFAULT 0;

UPDATE bookings
   SET deposit_amount = ROUND(COALESCE(base_price, total_amount, 0) * 0.20, 2)
 WHERE deposit_amount IS NULL OR deposit_amount = 0;

-- ─── 2. Deposit is a platform constant now: 20% everywhere ──────────
-- venues.upfront_percent is no longer used for money math (kept for display
-- continuity only); normalise it so no screen advertises 30%.
ALTER TABLE venues ADD COLUMN IF NOT EXISTS upfront_percent NUMERIC DEFAULT 20;
ALTER TABLE venues ALTER COLUMN upfront_percent SET DEFAULT 20;
UPDATE venues SET upfront_percent = 20 WHERE upfront_percent IS DISTINCT FROM 20;

-- ─── 3. Booking bookkeeping columns used by the background jobs ─────
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS no_show_processed BOOLEAN DEFAULT false;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS no_show_at TIMESTAMP;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS approved_at TIMESTAMP;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS auto_decided_at TIMESTAMP;

-- ─── 4. Notifications (written by noShowJob / autoApproveJob) ───────
CREATE TABLE IF NOT EXISTS notifications (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID REFERENCES users(id) ON DELETE CASCADE,
  booking_id UUID REFERENCES bookings(id) ON DELETE SET NULL,
  type VARCHAR(40) NOT NULL,
  title VARCHAR(255) NOT NULL,
  body TEXT,
  is_read BOOLEAN DEFAULT false,
  created_at TIMESTAMP DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_notifications_user
  ON notifications(user_id, is_read, created_at DESC);

-- ─── 5. Indexes for the 5-minute job sweeps ────────────────────────
CREATE INDEX IF NOT EXISTS idx_bookings_status_slot
  ON bookings(status, slot_date, start_time);
CREATE INDEX IF NOT EXISTS idx_bookings_status_created
  ON bookings(status, created_at);
