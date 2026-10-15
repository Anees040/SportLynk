-- ════════════════════════════════════════════════════════════════════════════
-- 043_venue_pricing_and_deposit.sql   ·   per-venue pricing authority + deposit
-- ════════════════════════════════════════════════════════════════════════════
--
-- Two owner-facing controls that did not have a place to live:
--
-- 1. `ai_pricing_enabled` — whether the trained price model may set this venue's
--    slot prices. Until now the model repriced every active venue on every sweep
--    (slotMaintenanceJob → slotService.repriceVenueSlots) and an owner's only
--    recourse was to override each slot by hand. An owner who wants a flat rate
--    across their ground had to keep re-overriding the sweep. Default true, so
--    every existing venue keeps the behaviour it has today.
--
-- 2. `deposit_pct` — the share of the slot price this venue's players have at risk.
--    It has been a single platform-wide number since migration 010
--    (`global_settings.deposit_pct`, read by bookingService via `settings.deposit`),
--    which is what this column makes per-venue WITHOUT removing that default: NULL
--    means "inherit the platform setting", so the migration changes nothing for any
--    existing row and the admin's value stays the fallback.
--
--    NULL rather than a copied default is deliberate. Copying the current global
--    value into every venue would freeze today's number as a per-venue override, and
--    a later admin change would then look like it had no effect on any venue.
--
-- Why not `venues.upfront_percent` (the column that already looks like this)
--    Migration 010 retired it from money math and normalised every row to 20 for
--    display continuity. It is documented as no longer authoritative, is written by
--    two INSERT paths that hardcode 20, and nothing reads it for arithmetic.
--    Reviving it would put the authoritative deposit on a column whose contract
--    says it is not, so the new value gets a new column and that one is left alone.
--
-- Additive only: no DROP of data, no TRUNCATE, no unfiltered UPDATE or DELETE. Both
-- columns arrive with safe defaults/NULL so applying this before or after a code
-- deploy leaves the running system correct either way.

ALTER TABLE venues
  ADD COLUMN IF NOT EXISTS ai_pricing_enabled boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS deposit_pct        numeric;

-- A percentage of a slot price. The upper bound is 100 because a booking cannot
-- hold more than the slot costs; 0 is legal and means "no deposit is at risk" for
-- this venue, which is a business choice an owner is allowed to make.
ALTER TABLE venues
  DROP CONSTRAINT IF EXISTS chk_venues_deposit_pct;
ALTER TABLE venues
  ADD CONSTRAINT chk_venues_deposit_pct
  CHECK (deposit_pct IS NULL OR (deposit_pct >= 0 AND deposit_pct <= 100));

COMMENT ON COLUMN venues.ai_pricing_enabled IS
  'Whether the trained price model may set this venue''s slot prices. False leaves '
  'the owner''s own price untouched by repriceVenueSlots. Default true.';

COMMENT ON COLUMN venues.deposit_pct IS
  'Per-venue at-risk deposit as a percentage of the slot price. NULL inherits '
  'global_settings.deposit_pct. Stamped into bookings.deposit_amount at booking '
  'time, so a later change never rewrites an existing booking.';
