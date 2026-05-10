-- 001_fix_schema.sql
-- Ensure venues table has all columns referenced by backend queries.
-- Safe to re-run (uses IF NOT EXISTS / DO blocks).

-- Add missing venue columns
ALTER TABLE venues ADD COLUMN IF NOT EXISTS rating DECIMAL(3,2) DEFAULT NULL;
ALTER TABLE venues ADD COLUMN IF NOT EXISTS total_reviews INT DEFAULT 0;
ALTER TABLE venues ADD COLUMN IF NOT EXISTS venue_photos TEXT[] DEFAULT '{}';
ALTER TABLE venues ADD COLUMN IF NOT EXISTS operating_hours_from TIME DEFAULT NULL;
ALTER TABLE venues ADD COLUMN IF NOT EXISTS operating_hours_to TIME DEFAULT NULL;

-- ground_type enum may already exist from owner_profiles; add column if missing
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'venues' AND column_name = 'ground_type'
  ) THEN
    ALTER TABLE venues ADD COLUMN ground_type VARCHAR(20) DEFAULT 'turf';
  END IF;
END$$;

-- Seed bilal@test.pk wallet to 10000 if currently 0
UPDATE wallets SET balance = 10000.00
WHERE balance = 0
  AND user_id = (SELECT id FROM users WHERE email = 'bilal@test.pk' LIMIT 1);

-- Ensure at least some sample venues exist for testing
INSERT INTO venues (name, description, sport_type, city, address,
  latitude, longitude, price_per_hour, rating, total_reviews,
  ground_type, is_active, operating_hours_from, operating_hours_to)
SELECT * FROM (VALUES
  ('Diamond Cricket Turf','Premium indoor cricket ground','cricket',
   'Islamabad','Sector G-8/2, Islamabad, Pakistan',
   33.6844, 73.0479, 2500.00, 4.5, 12, 'indoor'::ground_type, true, '08:00'::TIME, '23:00'::TIME),
  ('Elite Kick Arena','Top-class indoor football ground','football',
   'Islamabad','F-11 Markaz, Islamabad, Pakistan',
   33.7093, 73.0213, 2000.00, 4.3, 8, 'indoor'::ground_type, true, '09:00'::TIME, '22:00'::TIME),
  ('Stump City Nets','Best cricket nets in Rawalpindi','cricket',
   'Rawalpindi','Saddar, Rawalpindi, Pakistan',
   33.5651, 73.0169, 1800.00, 4.0, 5, 'indoor'::ground_type, true, '07:00'::TIME, '21:00'::TIME),
  ('Green Valley Football','Beautiful outdoor football pitch','football',
   'Islamabad','DHA Phase 2, Islamabad, Pakistan',
   33.6920, 73.0550, 3000.00, 4.7, 15, 'turf'::ground_type, true, '06:00'::TIME, '22:00'::TIME)
) AS v(name,description,sport_type,city,address,lat,lng,price,rating,reviews,gtype,active,hrs_from,hrs_to)
WHERE NOT EXISTS (SELECT 1 FROM venues WHERE is_active = true LIMIT 1);
