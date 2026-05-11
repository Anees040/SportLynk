-- 006_ensure_wallets.sql
-- 1. Ensure ALL users (players and owners) have a wallet
INSERT INTO wallets (user_id)
SELECT id FROM users
WHERE NOT EXISTS (SELECT 1 FROM wallets WHERE user_id = users.id);

-- 2. Add dynamic upfront & discount rules to venues if the columns exist (they were added in 005)
-- We will update some sample venues to have different payment rules

UPDATE venues
SET upfront_percent = 50, discount_percent = 5
WHERE name ILIKE '%Diamond Cricket%';

UPDATE venues
SET upfront_percent = 20, discount_percent = 0
WHERE name ILIKE '%Elite Kick%';

UPDATE venues
SET upfront_percent = 100, discount_percent = 10
WHERE name ILIKE '%Stump City%';

UPDATE venues
SET upfront_percent = 30, discount_percent = 15
WHERE name ILIKE '%Green Valley%';
