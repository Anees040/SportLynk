-- ════════════════════════════════════════════════════════════════════════════
-- 041_multi_challenge.sql   ·   multi-team invites + the open challenge board
-- ════════════════════════════════════════════════════════════════════════════
--
-- The problem: a captain could challenge exactly ONE team per booked slot. If that
-- captain was slow or declined, the slot window lapsed with no opponent. This lets a
-- captain offer one slot to SEVERAL teams at once, or post it to an open board any
-- eligible team can claim — first accept locks the match, the rest are voided — all
-- without ever double-booking the slot.
--
-- Both changes are additive to data (no row is rewritten):
--
-- 1. Relax ux_matches_booking_live. 016 forbade more than one match per booking
--    across the whole live set, INCLUDING challenge_sent, which is exactly what capped
--    a slot at one challenge. The guard that actually matters — a slot is never
--    DOUBLE-BOOKED — is "at most one match ACCEPTED or beyond", so the index is rebuilt
--    on that narrower predicate. Several challenge_sent rows on one booking are now
--    legal; the first to reach 'accepted' takes the slot and this index rejects any
--    second (the first-accept-locks backstop). The index KEEPS ITS NAME so
--    routes/matches.js friendlyDbError still maps its 23505 to a sentence.
--
-- 2. open_challenges — a slot a captain has offered to anyone, with no named opponent
--    yet, which does not fit the two-team `matches` row. A claim creates the matches
--    row (accepted) and marks the open challenge claimed, in one transaction.

-- ── 1. matches: one LOCKED match per booking (was: one live match) ──────────────
DROP INDEX IF EXISTS ux_matches_booking_live;
CREATE UNIQUE INDEX IF NOT EXISTS ux_matches_booking_live
  ON matches (booking_id)
  WHERE booking_id IS NOT NULL
    AND status IN ('accepted', 'awaiting_results', 'awaiting_owner',
                   'completed', 'disputed');

-- ── 2. open_challenges: a slot offered to the board ─────────────────────────────
CREATE TABLE IF NOT EXISTS open_challenges (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id       UUID NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  challenger_team  UUID NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
  sport            text NOT NULL,
  status           text NOT NULL DEFAULT 'open',   -- open|claimed|cancelled|expired
  expires_at       timestamptz NOT NULL,
  -- The captain who posted it; SET NULL so losing the account keeps the record.
  created_by       UUID REFERENCES users(id) ON DELETE SET NULL,
  -- Filled when a team claims the slot: the claiming team and the match that claim
  -- created, so a board row points at the fixture it became.
  claimed_by_team  UUID REFERENCES teams(id) ON DELETE SET NULL,
  claimed_match_id UUID REFERENCES matches(id) ON DELETE SET NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  decided_at       timestamptz,
  CONSTRAINT chk_open_challenges_status
    CHECK (status IN ('open', 'claimed', 'cancelled', 'expired'))
);

-- At most one OPEN offer per booking — a slot cannot be posted to the board twice at
-- once. Partial on status='open', so a cancelled/expired offer never blocks a re-post.
CREATE UNIQUE INDEX IF NOT EXISTS ux_open_challenges_booking_open
  ON open_challenges (booking_id)
  WHERE status = 'open';

-- The board read: the open offers in a sport, soonest to expire first.
CREATE INDEX IF NOT EXISTS idx_open_challenges_board
  ON open_challenges (status, sport, expires_at);

-- A captain's own offers, and the expiry sweep's candidate scan.
CREATE INDEX IF NOT EXISTS idx_open_challenges_team
  ON open_challenges (challenger_team, status);
CREATE INDEX IF NOT EXISTS idx_open_challenges_expiry
  ON open_challenges (expires_at)
  WHERE status = 'open';

COMMENT ON TABLE open_challenges IS
  'A booked slot offered to the open board with no named opponent (migration 041). '
  'A claim creates an accepted matches row and marks this claimed, in one transaction.';
