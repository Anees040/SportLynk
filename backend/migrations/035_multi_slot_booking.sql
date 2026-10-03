-- 035_multi_slot_booking.sql — consecutive-slot bookings and owner-set discounts.
--
-- The shape of a multi-slot booking, and why
-- A player booking three consecutive hours produces THREE `bookings` rows that
-- share a `booking_group_id`, not one row spanning three slots. The alternative was
-- considered and rejected: `bookings.slot_id` is a single reference that escrow,
-- the QR check-in, the no-show sweep, the cancellation window and the owner's
-- approval queue all read, so widening a booking to many slots would mean
-- revisiting every one of those money paths at once. Grouping instead leaves each
-- row's escrow, deposit, refund and QR exactly as they are, and the player's
-- screens render the group as one card.
--
-- The cost of that choice, stated rather than hidden: a three-hour booking has
-- three QR codes and can be cancelled hour by hour. The first is a check-in
-- inconvenience; the second is arguably correct, since each hour's refund is
-- governed by its own distance from its own start time.
--
-- The discount is a tier table, not a column
-- Owners price multi-hour play as a ladder ("two hours 5% off, three hours 10%"),
-- which a single percent column cannot express. `min_slots` is the threshold and
-- the applicable tier is the highest `min_slots` at or below the number of slots
-- booked. The discount is applied PER ROW, so each booking's escrow and refund stay
-- internally consistent and the group total is simply the sum of its rows — there
-- is no second, group-level money figure that could disagree with the ledger.
--
-- The ceiling is in the database and not only in Node: a 100% discount would book
-- a free slot and freeze nothing in escrow, which every downstream refund rule
-- would then divide by.
--
-- Purely additive. ADD COLUMN IF NOT EXISTS, CREATE TABLE IF NOT EXISTS, guarded
-- CHECKs, and defaults that reproduce exactly what every existing booking already
-- means (no group, no discount). No DROP, TRUNCATE, DELETE, or UPDATE of a live
-- row, so a second application is a no-op and no booking or ledger entry is
-- touched.

-- -- Grouping ------------------------------------------------

ALTER TABLE bookings
  ADD COLUMN IF NOT EXISTS booking_group_id UUID DEFAULT NULL;

-- The discount that was applied to this row, kept for the receipt. Stored per
-- booking rather than per group because it is what justifies this row's base_price,
-- and because the owner's tiers can change after the booking was made.
ALTER TABLE bookings
  ADD COLUMN IF NOT EXISTS discount_percent NUMERIC(5,2) NOT NULL DEFAULT 0;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'chk_bookings_discount_percent'
       AND conrelid = 'public.bookings'::regclass
  ) THEN
    ALTER TABLE bookings
      ADD CONSTRAINT chk_bookings_discount_percent
      CHECK (discount_percent >= 0 AND discount_percent <= 50);
  END IF;
END $$;

-- The player's list groups by this column, so it is the lookup that has to be fast.
-- Partial: the overwhelming majority of bookings are single and carry NULL, and
-- indexing those would be dead weight on every insert.
CREATE INDEX IF NOT EXISTS idx_bookings_group
  ON bookings (booking_group_id) WHERE booking_group_id IS NOT NULL;

COMMENT ON COLUMN bookings.booking_group_id IS
  'Shared by the bookings created together for consecutive slots. NULL for a single '
  'booking. Each row keeps its own escrow, deposit, refund and QR code.';

-- -- Owner discount tiers -----------------------------------

CREATE TABLE IF NOT EXISTS venue_slot_discounts (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id    UUID NOT NULL REFERENCES venues(id) ON DELETE CASCADE,
  -- Book this many consecutive slots or more to earn `percent` off each of them.
  min_slots   INT NOT NULL CHECK (min_slots BETWEEN 2 AND 12),
  -- Capped at 50: past that the deposit and refund arithmetic is working with a
  -- price that no longer resembles the venue's own rate.
  percent     NUMERIC(5,2) NOT NULL CHECK (percent > 0 AND percent <= 50),
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- One rule per threshold per venue: two rows saying "2 or more" with different
-- percentages would make the price depend on row order.
CREATE UNIQUE INDEX IF NOT EXISTS ux_venue_slot_discounts
  ON venue_slot_discounts (venue_id, min_slots);

CREATE INDEX IF NOT EXISTS idx_venue_slot_discounts_venue
  ON venue_slot_discounts (venue_id, min_slots DESC);
