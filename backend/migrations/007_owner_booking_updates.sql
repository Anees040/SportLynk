-- 007_owner_booking_updates.sql
-- Add escrow transaction types to txn_type enum
DO $$ BEGIN ALTER TYPE txn_type ADD VALUE 'escrow_release'; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN ALTER TYPE txn_type ADD VALUE 'escrow_received'; EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Add owner_id and timestamp columns to bookings
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS owner_id UUID REFERENCES users(id);
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS checked_in_at TIMESTAMP;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS no_show_at TIMESTAMP;

-- Backfill owner_id for existing bookings from venue
UPDATE bookings b SET owner_id = v.owner_id
FROM venues v WHERE b.venue_id = v.id AND b.owner_id IS NULL;

-- Ensure all users have wallets
INSERT INTO wallets (user_id)
SELECT id FROM users
WHERE NOT EXISTS (SELECT 1 FROM wallets w WHERE w.user_id = users.id);

-- Ensure owner wallets start with 0 balance (players already seeded with 500)
UPDATE wallets SET balance = 0
WHERE user_id IN (SELECT id FROM users WHERE role = 'owner')
AND balance = 500.00;
