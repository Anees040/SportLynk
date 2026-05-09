DROP TABLE IF EXISTS bookings CASCADE;

CREATE TABLE bookings (
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

CREATE INDEX idx_bookings_player_status ON bookings(player_id, status);
CREATE INDEX idx_bookings_venue_date ON bookings(venue_id, slot_date);

INSERT INTO venues (name, description, sport_type, city, address,
  latitude, longitude, price_per_hour,
  ground_type, is_active)
SELECT * FROM (VALUES
  ('Diamond Cricket Turf','Premium indoor cricket ground','cricket',
   'Islamabad','Sector G-8/2, Islamabad, Pakistan',
   33.6844,73.0479,2500.00,'indoor'::ground_type,true),
  ('Elite Kick Arena','Top-class indoor football ground','football',
   'Islamabad','F-11 Markaz, Islamabad, Pakistan',
   33.7093,73.0213,2000.00,'indoor'::ground_type,true),
  ('Stump City Nets','Best cricket nets in Rawalpindi','cricket',
   'Rawalpindi','Saddar, Rawalpindi, Pakistan',
   33.5651,73.0169,1800.00,'indoor'::ground_type,true)
) AS v(name,description,sport_type,city,address,lat,lng,price,gtype,active)
WHERE NOT EXISTS (SELECT 1 FROM venues LIMIT 1);

DROP TABLE IF EXISTS transactions CASCADE;
DROP TABLE IF EXISTS reviews CASCADE;

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
