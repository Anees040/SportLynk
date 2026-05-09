-- SportLynk Database Schema
-- Run this SQL in pgAdmin or psql against your sportlynk database

-- ─── ENUMS ───────────────────────────────────────────────────
DO $$ BEGIN
  CREATE TYPE user_role AS ENUM ('player', 'owner', 'admin');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE booking_status AS ENUM ('pending', 'confirmed', 'checked_in', 'no_show', 'cancelled');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE slot_status AS ENUM ('available', 'booked', 'blocked');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ─── TABLES ──────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email VARCHAR(255) UNIQUE NOT NULL,
  password_hash VARCHAR(255) NOT NULL,
  role user_role DEFAULT 'player',
  name VARCHAR(255) NOT NULL,
  phone VARCHAR(20),
  avatar_url TEXT,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS player_profiles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID UNIQUE REFERENCES users(id) ON DELETE CASCADE,
  sport_preferences TEXT[] DEFAULT '{}',
  elo_rating DECIMAL DEFAULT 1000,
  trust_score INT DEFAULT 100
);

CREATE TABLE IF NOT EXISTS owner_profiles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID UNIQUE REFERENCES users(id) ON DELETE CASCADE,
  business_name VARCHAR(255),
  cnic VARCHAR(15),
  is_verified BOOLEAN DEFAULT false
);

CREATE TABLE IF NOT EXISTS venues (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id UUID REFERENCES users(id) ON DELETE CASCADE,
  name VARCHAR(255) NOT NULL,
  description TEXT,
  sport_type VARCHAR(50),
  city VARCHAR(100),
  address TEXT,
  latitude DECIMAL(10,8),
  longitude DECIMAL(11,8),
  base_price DECIMAL(10,2),
  current_price DECIMAL(10,2),
  image_url TEXT,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS venue_slots (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id UUID REFERENCES venues(id) ON DELETE CASCADE,
  date DATE NOT NULL,
  start_time TIME NOT NULL,
  end_time TIME NOT NULL,
  status slot_status DEFAULT 'available',
  price DECIMAL(10,2) NOT NULL
);

CREATE TABLE IF NOT EXISTS bookings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id UUID REFERENCES venues(id) ON DELETE CASCADE,
  player_id UUID REFERENCES users(id) ON DELETE CASCADE,
  slot_id UUID REFERENCES venue_slots(id) ON DELETE CASCADE,
  status booking_status DEFAULT 'pending',
  total_amount DECIMAL(10,2),
  deposit_amount DECIMAL(10,2),
  qr_code_hash VARCHAR(512),
  created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS wallets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID UNIQUE REFERENCES users(id) ON DELETE CASCADE,
  balance DECIMAL(10,2) DEFAULT 500.00,
  frozen_balance DECIMAL(10,2) DEFAULT 0.00
);

CREATE TABLE IF NOT EXISTS wallet_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  wallet_id UUID REFERENCES wallets(id) ON DELETE CASCADE,
  type VARCHAR(50) NOT NULL,
  amount DECIMAL(10,2) NOT NULL,
  reference_id UUID,
  created_at TIMESTAMP DEFAULT NOW()
);

-- ─── INDEXES (performance) ──────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_venues_city ON venues(city);
CREATE INDEX IF NOT EXISTS idx_venues_sport_type ON venues(sport_type);
CREATE INDEX IF NOT EXISTS idx_venues_owner ON venues(owner_id);
CREATE INDEX IF NOT EXISTS idx_venue_slots_venue_date ON venue_slots(venue_id, date);
CREATE INDEX IF NOT EXISTS idx_bookings_player ON bookings(player_id);
CREATE INDEX IF NOT EXISTS idx_bookings_venue ON bookings(venue_id);
CREATE INDEX IF NOT EXISTS idx_wallet_transactions_wallet ON wallet_transactions(wallet_id);
-- -- New ENUMS ----------------------------------------------
DO $$ BEGIN
  CREATE TYPE booking_status AS ENUM
    ('pending','confirmed','checked_in','no_show','cancelled','refunded');
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN
  CREATE TYPE txn_type AS ENUM
    ('topup','booking_payment','security_deposit','refund',
     'no_show_penalty','owner_payout','withdrawal');
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN
  CREATE TYPE slot_status AS ENUM ('available','booked','blocked');
EXCEPTION WHEN duplicate_object THEN null; END $$;

-- -- Venues (safe adds) -------------------------------------
ALTER TABLE venues ADD COLUMN IF NOT EXISTS description TEXT;
ALTER TABLE venues ADD COLUMN IF NOT EXISTS sport_type VARCHAR(50);
ALTER TABLE venues ADD COLUMN IF NOT EXISTS price_per_hour DECIMAL(10,2) DEFAULT 0;
ALTER TABLE venues ADD COLUMN IF NOT EXISTS is_active BOOLEAN DEFAULT true;
ALTER TABLE venues ADD COLUMN IF NOT EXISTS owner_id UUID REFERENCES users(id);

-- -- Slots --------------------------------------------------
CREATE TABLE IF NOT EXISTS slots (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  venue_id UUID REFERENCES venues(id) ON DELETE CASCADE,
  slot_date DATE NOT NULL,
  start_time TIME NOT NULL,
  end_time TIME NOT NULL,
  price DECIMAL(10,2) NOT NULL,
  status slot_status DEFAULT 'available',
  created_at TIMESTAMP DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_slots_venue_date ON slots(venue_id, slot_date, status);

-- -- Bookings -----------------------------------------------
CREATE TABLE IF NOT EXISTS bookings (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  player_id UUID REFERENCES users(id),
  venue_id UUID REFERENCES venues(id),
  slot_id UUID REFERENCES slots(id),
  slot_date DATE NOT NULL,
  start_time TIME NOT NULL,
  end_time TIME NOT NULL,
  base_price DECIMAL(10,2) NOT NULL,
  security_deposit DECIMAL(10,2) DEFAULT 0,
  total_amount DECIMAL(10,2) NOT NULL,
  status booking_status DEFAULT 'pending',
  qr_code TEXT,
  notes TEXT,
  cancelled_at TIMESTAMP,
  cancellation_reason TEXT,
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_bookings_player ON bookings(player_id, status);
CREATE INDEX IF NOT EXISTS idx_bookings_venue ON bookings(venue_id, slot_date);

-- -- Transactions --------------------------------------------
CREATE TABLE IF NOT EXISTS transactions (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  wallet_id UUID REFERENCES wallets(id),
  user_id UUID REFERENCES users(id),
  booking_id UUID REFERENCES bookings(id),
  type txn_type NOT NULL,
  amount DECIMAL(10,2) NOT NULL,
  balance_after DECIMAL(10,2),
  description TEXT,
  counterparty_name VARCHAR(255),
  reference_id VARCHAR(50) UNIQUE DEFAULT ('TRX-' || substr(gen_random_uuid()::text,1,8)),
  created_at TIMESTAMP DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_txn_user ON transactions(user_id, created_at DESC);

-- -- Wallet: add frozen_balance ------------------------------
ALTER TABLE wallets ADD COLUMN IF NOT EXISTS frozen_balance DECIMAL(10,2) DEFAULT 0;

-- -- Reviews ------------------------------------------------
CREATE TABLE IF NOT EXISTS reviews (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  booking_id UUID REFERENCES bookings(id),
  reviewer_id UUID REFERENCES users(id),
  reviewed_user_id UUID REFERENCES users(id),
  venue_id UUID REFERENCES venues(id),
  rating INT CHECK(rating BETWEEN 1 AND 5),
  comment TEXT,
  reviewer_name VARCHAR(255),
  created_at TIMESTAMP DEFAULT NOW()
);

-- -- Teams (schema only, UI-first feature) ------------------
DO $$ BEGIN
  CREATE TYPE team_sport AS ENUM ('football','cricket');
EXCEPTION WHEN duplicate_object THEN null; END $$;

CREATE TABLE IF NOT EXISTS teams (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  sport team_sport NOT NULL,
  logo_url TEXT,
  bio TEXT,
  is_public BOOLEAN DEFAULT true,
  captain_id UUID REFERENCES users(id),
  elo_rating DECIMAL(8,2) DEFAULT 1000,
  wins INT DEFAULT 0,
  losses INT DEFAULT 0,
  draws INT DEFAULT 0,
  city VARCHAR(100),
  created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS team_members (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  team_id UUID REFERENCES teams(id) ON DELETE CASCADE,
  user_id UUID REFERENCES users(id),
  role VARCHAR(20) DEFAULT 'member',
  joined_at TIMESTAMP DEFAULT NOW(),
  UNIQUE(team_id, user_id)
);

-- -- Insert test data ----------------------------------------
-- Test venues (run only if venues table is empty)
INSERT INTO venues (name, description, sport_type, city, address,
  latitude, longitude, price_per_hour, rating, total_reviews,
  ground_type, is_active)
SELECT * FROM (VALUES
  ('Diamond Cricket Turf','Premium indoor cricket ground','cricket',
   'Islamabad','Sector G-8/2, Islamabad, Pakistan',
   33.6844,73.0479,2500.00,4.8,120,'indoor',true),
  ('Elite Kick Arena','Top-class indoor football ground','football',
   'Islamabad','F-11 Markaz, Islamabad, Pakistan',
   33.7093,73.0213,2000.00,4.6,85,'indoor',true),
  ('Stump City Nets','Best cricket nets in Rawalpindi','cricket',
   'Rawalpindi','Saddar, Rawalpindi, Pakistan',
   33.5651,73.0169,1800.00,4.3,60,'indoor',true)
) AS v(name,description,sport_type,city,address,lat,lng,price,rating,reviews,gtype,active)
WHERE NOT EXISTS (SELECT 1 FROM venues LIMIT 1)
RETURNING id;

-- Add slots for today and next 7 days for each venue
INSERT INTO slots (venue_id, slot_date, start_time, end_time, price, status)
SELECT v.id,
  (CURRENT_DATE + d.day)::DATE,
  (h.hour || ':00')::TIME,
  ((h.hour+1) || ':00')::TIME,
  v.price_per_hour,
  'available'
FROM venues v
CROSS JOIN generate_series(0,6) d(day)
CROSS JOIN generate_series(6,22) h(hour)
WHERE NOT EXISTS (
  SELECT 1 FROM slots WHERE venue_id = v.id
    AND slot_date = (CURRENT_DATE + d.day)::DATE
    AND start_time = (h.hour || ':00')::TIME
)
ON CONFLICT DO NOTHING;

-- Top up test user wallets (update your test user phone)
UPDATE wallets SET balance = 10000
WHERE user_id = (SELECT id FROM users WHERE role='player' LIMIT 1)
  AND balance = 0;
