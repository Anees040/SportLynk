-- Migration 012: Query indexes for the hot read paths (Wave C — backend hardening)
--
-- Every statement is IF NOT EXISTS *under the name the index already has in this
-- database*, so re-running is a no-op and — importantly — no duplicate index is
-- created under a second name. Three of the four requested indexes turned out to
-- already exist (from migrations 006/009); they are restated here so the set the
-- app depends on is documented in one place and guaranteed on a fresh DB.

-- 1. bookings(venue_id, slot_id) — NEW.
--    The venue+slot pair is how a slot is traced back to the booking that owns
--    it (owner calendar, no-show/auto-approve sweeps, slot release on cancel).
--    The pre-existing idx_bookings_venue_date covers (venue_id, slot_date) and
--    cannot serve a slot_id lookup.
CREATE INDEX IF NOT EXISTS idx_bookings_venue_slot
    ON bookings (venue_id, slot_id);

-- 2. bookings(player_id, status) — already present under this name.
--    Serves GET /api/bookings/my, which always filters by player and usually
--    also by status (upcoming / past tabs).
CREATE INDEX IF NOT EXISTS idx_bookings_player_status
    ON bookings (player_id, status);

-- 3. transactions(user_id, created_at DESC) — already present under this name.
--    Serves GET /api/wallet/transactions: one user's ledger, newest first. The
--    DESC matters — it lets the ORDER BY read straight off the index.
CREATE INDEX IF NOT EXISTS idx_txn_user
    ON transactions (user_id, created_at DESC);

-- 4. slots(venue_id, slot_date) — already present under this name, as the wider
--    (venue_id, slot_date, status). Its leading columns are exactly the pair we
--    need, so the venue-detail slot grid and owner calendar are already covered
--    and a separate two-column index would only add write cost. Restated with
--    the existing name so this migration stays a no-op instead of duplicating it.
--    (The column is `slot_date`, not `date`.)
CREATE INDEX IF NOT EXISTS idx_slots_venue_date
    ON slots (venue_id, slot_date);
