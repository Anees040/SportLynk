-- 004_slot_lock_tracking.sql
-- Add locked_by column to track WHO locked each slot (prevents abuse)
ALTER TABLE slots ADD COLUMN IF NOT EXISTS locked_by UUID DEFAULT NULL;
