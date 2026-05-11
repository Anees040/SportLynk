-- Migration 009: Add no_show_processed flag + ensure admin tables are ready
-- Run this before starting the server with the new noShowJob

ALTER TABLE bookings ADD COLUMN IF NOT EXISTS no_show_processed BOOLEAN DEFAULT false;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS no_show_at TIMESTAMP;

-- Ensure owner_profiles has reviewed_by column
ALTER TABLE owner_profiles ADD COLUMN IF NOT EXISTS reviewed_by UUID REFERENCES users(id);

-- Create admin account if it doesn't exist
-- Password hash is for: Admin@123 (bcrypt, 10 rounds)
INSERT INTO users (name, phone, email, password_hash, role, phone_verified)
VALUES (
  'SportLynk Admin',
  '03000000000',
  'admin@sportlynk.com',
  '$2b$10$L1v0TYYTmHiwd.x/v09I.eJoy//NHeI1YydlQfrVZrfZzSHfz0ch2',
  'admin',
  true
)
ON CONFLICT (phone) DO NOTHING;

-- Also try by email if phone conflicts differently
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM users WHERE email = 'admin@sportlynk.com') THEN
    INSERT INTO users (name, phone, email, password_hash, role, phone_verified)
    VALUES (
      'SportLynk Admin',
      '03000000001',
      'admin@sportlynk.com',
      '$2b$10$L1v0TYYTmHiwd.x/v09I.eJoy//NHeI1YydlQfrVZrfZzSHfz0ch2',
      'admin',
      true
    );
  END IF;
END $$;

