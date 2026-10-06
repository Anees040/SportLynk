-- ════════════════════════════════════════════════════════════════════════════
-- 038_trust_baseline_100.sql   ·   Trust Score 2.0 cold-start baseline → 100
-- ════════════════════════════════════════════════════════════════════════════
--
-- A new account started at 50. That is the aggregate of Trust 2.0's four components
-- when every one of them is absent and each is given a neutral 0.5 prior
-- (migration 017). A 50/100 on day one reads as "half-trustworthy" before the user
-- has done anything, which penalises newcomers for having no history.
--
-- Trust is now modelled as a reputation to keep rather than one to earn: a new user
-- starts at 100, and only a real negative signal — a poor review, a no-show, a
-- dispute the other side filed — moves the score down. The matching code change is
-- in utils/trustScore.js, where NEUTRAL_PRIOR became 1.0 so a recompute of a
-- zero-signal user also yields 100.
--
-- This migration carries the other half: the column DEFAULT, which is what a freshly
-- inserted player_profiles row takes before any trust event has triggered a recompute.
--
-- Purely a DEFAULT change. It does NOT rewrite existing rows — exactly as 017
-- deliberately left live scores alone — so a user who has earned a real score keeps
-- it. Existing zero-signal users still reading 50 move to 100 on their next trust
-- event, when recomputeTrust runs with the new prior. A one-time recompute can bring
-- them over sooner if wanted; it is deliberately not bundled here, because a blanket
-- rewrite of a reputation column is a data decision, not a schema one.

ALTER TABLE player_profiles ALTER COLUMN trust_score SET DEFAULT 100;

COMMENT ON COLUMN player_profiles.trust_score IS
  'Trust Score 2.0 aggregate (ER2.5), 0..100. DEFAULT 100 = a zero-signal new user; '
  'trust is lose-only, so each of the four trust_* components contributes a full 1.0 '
  'prior until a real negative signal lowers it. Recomputed by utils/trustScore.js '
  'after every review / no-show / dispute event.';
