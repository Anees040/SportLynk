-- Permanent, unique manual check-in codes for existing and future bookings.
-- The UUID remains the relational key and the QR token stays unchanged.
-- Identity assignment also fills existing rows; no application backfill needed.
-- Codes are public references. Owner authorization/status/time gates still apply.
-- One statement keeps this atomic through both pg and Supabase CLI db query.
DO $migration$
BEGIN
SET LOCAL lock_timeout = '5s';

ALTER TABLE public.bookings
  ADD COLUMN IF NOT EXISTS booking_number bigint GENERATED ALWAYS AS IDENTITY;

ALTER TABLE public.bookings
  ADD COLUMN IF NOT EXISTS checkin_code text GENERATED ALWAYS AS (
    'BK' || upper(lpad(to_hex(booking_number),
      greatest(6, length(to_hex(booking_number))), '0'))
  ) STORED;

-- Do not truncate after six hex digits: codes grow after 16 million bookings.
CREATE UNIQUE INDEX IF NOT EXISTS idx_bookings_checkin_code
  ON public.bookings (checkin_code);

COMMENT ON COLUMN public.bookings.checkin_code IS
  'Short manual check-in reference, e.g. BK00012A. Not an authorization token.';
END
$migration$;
