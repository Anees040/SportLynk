-- Migration 008: Admin role and venue verification
-- NOTE: Admin user password is generated programmatically via run_migration_008.js
--       because bcrypt hashes must be generated at runtime, not hardcoded.

-- Add admin role to user_role enum
DO $$ BEGIN
  ALTER TYPE user_role ADD VALUE 'admin';
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- Add verification fields to venues (for admin approval tracking)
ALTER TABLE venues ADD COLUMN IF NOT EXISTS is_verified BOOLEAN DEFAULT true;
ALTER TABLE venues ADD COLUMN IF NOT EXISTS verification_status VARCHAR(20) DEFAULT 'approved';

-- Add review tracking columns to owner_profiles
ALTER TABLE owner_profiles ADD COLUMN IF NOT EXISTS rejection_reason TEXT;
ALTER TABLE owner_profiles ADD COLUMN IF NOT EXISTS reviewed_at TIMESTAMP;
ALTER TABLE owner_profiles ADD COLUMN IF NOT EXISTS reviewed_by UUID REFERENCES users(id);

-- Note: Admin user and wallet are created by run_migration_008.js
-- because the bcrypt hash must be generated at runtime.
