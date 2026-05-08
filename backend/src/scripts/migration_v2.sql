-- MIGRATION V2: SportLynk Auth Overhaul
-- Run in pgAdmin Query Tool or via psql

-- 1. Make email optional (nullable) while keeping unique constraint for non-null values
ALTER TABLE users ALTER COLUMN email DROP NOT NULL;
DROP INDEX IF EXISTS users_email_key;
CREATE UNIQUE INDEX IF NOT EXISTS users_email_unique_when_not_null ON users (email) WHERE email IS NOT NULL;

-- 2. Add phone_verified and avatar_url to users
ALTER TABLE users ADD COLUMN IF NOT EXISTS phone_verified BOOLEAN DEFAULT false;
ALTER TABLE users ADD COLUMN IF NOT EXISTS avatar_url TEXT;

-- 3. Phone must be unique and not null going forward
UPDATE users SET phone = 'UNKNOWN_' || id::text WHERE phone IS NULL;
ALTER TABLE users ALTER COLUMN phone SET NOT NULL;
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'users_phone_unique'
  ) THEN
    ALTER TABLE users ADD CONSTRAINT users_phone_unique UNIQUE (phone);
  END IF;
END $$;

-- 4. Create owner_verification_status enum
DO $$ BEGIN
  CREATE TYPE owner_verification_status AS ENUM ('pending', 'under_review', 'approved', 'rejected');
EXCEPTION WHEN duplicate_object THEN null;
END $$;

-- 5. Create ground_type enum
DO $$ BEGIN
  CREATE TYPE ground_type AS ENUM ('turf', 'futsal', 'concrete', 'grass', 'indoor');
EXCEPTION WHEN duplicate_object THEN null;
END $$;

-- 6. Drop and recreate owner_profiles with full fields
DROP TABLE IF EXISTS owner_profiles CASCADE;
CREATE TABLE owner_profiles (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID REFERENCES users(id) ON DELETE CASCADE UNIQUE NOT NULL,
  full_name VARCHAR(255) NOT NULL,
  cnic_number VARCHAR(15) NOT NULL,
  cnic_front_url TEXT,
  cnic_back_url TEXT,
  selfie_with_cnic_url TEXT,
  business_name VARCHAR(255),
  ground_name VARCHAR(255),
  ground_type ground_type,
  sport_types TEXT[] DEFAULT '{}',
  city VARCHAR(100),
  full_address TEXT,
  google_maps_link TEXT,
  latitude DECIMAL(10,8),
  longitude DECIMAL(11,8),
  operating_hours_from TIME,
  operating_hours_to TIME,
  price_per_hour DECIMAL(10,2),
  ground_photos TEXT[] DEFAULT '{}',
  utility_bill_url TEXT,
  ownership_proof_url TEXT,
  alternate_contact_phone VARCHAR(20),
  verification_status owner_verification_status DEFAULT 'pending',
  verification_notes TEXT,
  verified_by UUID REFERENCES users(id),
  verified_at TIMESTAMP,
  rejection_reason TEXT,
  submitted_at TIMESTAMP DEFAULT NOW(),
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);

-- 7. CNIC uniqueness constraint
ALTER TABLE owner_profiles ADD CONSTRAINT owner_cnic_unique UNIQUE (cnic_number);

-- 8. Update player_profiles with avatar reference
ALTER TABLE player_profiles ADD COLUMN IF NOT EXISTS avatar_url TEXT;

-- 9. Update venues table
ALTER TABLE venues ADD COLUMN IF NOT EXISTS ground_type ground_type;
ALTER TABLE venues ADD COLUMN IF NOT EXISTS venue_photos TEXT[] DEFAULT '{}';
ALTER TABLE venues ADD COLUMN IF NOT EXISTS operating_hours_from TIME;
ALTER TABLE venues ADD COLUMN IF NOT EXISTS operating_hours_to TIME;
ALTER TABLE venues ADD COLUMN IF NOT EXISTS rating DECIMAL(3,2) DEFAULT 0.00;
ALTER TABLE venues ADD COLUMN IF NOT EXISTS total_reviews INT DEFAULT 0;

-- 10. OTP tracking table
CREATE TABLE IF NOT EXISTS phone_otp_log (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  phone VARCHAR(20) NOT NULL,
  purpose VARCHAR(20) NOT NULL,
  firebase_uid TEXT,
  verified BOOLEAN DEFAULT false,
  created_at TIMESTAMP DEFAULT NOW(),
  expires_at TIMESTAMP DEFAULT NOW() + INTERVAL '10 minutes'
);

-- 11. Index for fast phone OTP lookups
CREATE INDEX IF NOT EXISTS idx_otp_phone_purpose ON phone_otp_log (phone, purpose, verified);

-- 12. Wallets table (ensure exists with PKR currency)
CREATE TABLE IF NOT EXISTS wallets (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID REFERENCES users(id) ON DELETE CASCADE UNIQUE NOT NULL,
  balance DECIMAL(10,2) DEFAULT 0.00,
  currency VARCHAR(10) DEFAULT 'PKR',
  created_at TIMESTAMP DEFAULT NOW()
);

-- 13. Mark existing seeded users as phone_verified for professional DB state
UPDATE users SET phone_verified = true WHERE phone IS NOT NULL AND phone NOT LIKE 'UNKNOWN_%';
