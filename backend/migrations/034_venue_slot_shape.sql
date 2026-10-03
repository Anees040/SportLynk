-- 034_venue_slot_shape.sql — owner-chosen slot length.
--
-- What this adds and why
-- `slots` were whole hours on the hour for every venue on the platform, because
-- utils/slotGrid.js had no other shape to offer. Owners need three things that one
-- shape cannot express: a ground that opens at 14:30, a ground that sells 30- or
-- 90-minute slots, and a ground that trades past midnight.
--
-- Only the slot length needs a column. The opening offset is already expressed by
-- `operating_hours_from`, which has been a TIME with minute precision since
-- migration 001 — it was the generator that floored it to the hour. Running past
-- midnight needs no column either: a closing time earlier than the opening time is
-- now read as a window that rolls over, which is what an owner entering 18:00-02:00
-- means and what the previous code refused outright.
--
-- The allowed lengths are constrained in the database and not only in Node, because
-- an out-of-range value would silently produce a grid no screen can render. All four
-- divide 1440, so a window that opens on a multiple of its own duration never
-- produces a slot that straddles midnight.
--
-- Purely additive. ADD COLUMN IF NOT EXISTS with a DEFAULT that reproduces the
-- behaviour every venue already has, and a CHECK added only when absent. No DROP,
-- TRUNCATE, DELETE or UPDATE of an existing row, so a second application is a no-op
-- and no live slot, booking or price is touched.

ALTER TABLE venues
  ADD COLUMN IF NOT EXISTS slot_duration_minutes INT NOT NULL DEFAULT 60;

-- Postgres has no ADD CONSTRAINT IF NOT EXISTS, so the guard is explicit. Named so a
-- violation reports the rule rather than a generated identifier.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'chk_venues_slot_duration'
       AND conrelid = 'public.venues'::regclass
  ) THEN
    ALTER TABLE venues
      ADD CONSTRAINT chk_venues_slot_duration
      CHECK (slot_duration_minutes IN (30, 60, 90, 120));
  END IF;
END $$;

COMMENT ON COLUMN venues.slot_duration_minutes IS
  'Length of one bookable slot in minutes (30/60/90/120). The opening offset comes '
  'from operating_hours_from; a closing time below the opening time runs past midnight.';
