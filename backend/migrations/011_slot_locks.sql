-- Migration 011: Checkout slot locks (Wave B — SRS ER1.5, FR3.7)
--
-- A "lock" is a 5-minute hold one player takes on a free slot while they walk
-- through checkout. Two deliberate design choices make it cheap:
--
--   1. The hold lives ONLY in slots.locked_until / slots.locked_by. The slot's
--      `status` stays 'available' the whole time it is held, so every existing
--      "WHERE status='available'" query keeps working unchanged.
--   2. Expiry is therefore LAZY: a lock whose locked_until has passed reads as
--      free everywhere. No cron sweep is needed, and a client that dies
--      mid-checkout can never strand a slot.
--
-- Effective status is computed in SQL and never stored (SRS colour code):
--   booked                             → 'booked'    (Amber)
--   blocked                            → 'blocked'   (Red)
--   available AND locked_until > NOW() → 'locked'    (Blue)
--   available                          → 'available' (Green)
--
-- Run with:  node run_migration_011.js

-- locked_by already exists from 004_slot_lock_tracking.sql; both statements are
-- idempotent so the migration is safe to re-run.
ALTER TABLE slots ADD COLUMN IF NOT EXISTS locked_by UUID DEFAULT NULL;
ALTER TABLE slots ADD COLUMN IF NOT EXISTS locked_until TIMESTAMPTZ DEFAULT NULL;

-- Phase 5 parked held slots in the 'temporarily_locked' status with a
-- `locked_at` stamp and a 2-minute TTL. Nothing reads either any more, so hand
-- those rows back to 'available' — their TTL expired long ago.
UPDATE slots
   SET status = 'available', locked_by = NULL, locked_until = NULL
 WHERE status = 'temporarily_locked';

-- The only question ever asked of this column is "is the hold still live?",
-- so a partial index over live holds is all that earns its keep.
CREATE INDEX IF NOT EXISTS idx_slots_locked_until
    ON slots (locked_until)
 WHERE locked_until IS NOT NULL;
