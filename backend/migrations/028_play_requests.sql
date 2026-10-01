-- ════════════════════════════════════════════════════════════════════════════
-- 028_play_requests.sql   ·   direct "let's play" requests + 1:1 DM rooms
-- ════════════════════════════════════════════════════════════════════════════
--
-- Matchmaking, the part the challenge flow never covered. A team challenge is a
-- commitment: it needs a booking, a slot and both captains. What was missing is the
-- INTRODUCTION before any of that — one player finding another and asking "want to
-- play?" — and the private thread the two of them talk in once the other says yes.
--
-- Three things ship together here because a request is only useful if accepting it
-- opens somewhere to talk:
--
--   1. play_requests   a directed, notified ask from one player to another, with a
--                      small state machine (pending → accepted|declined|cancelled|
--                      expired). One pending ask per direction at a time.
--
--   2. direct          a new chat_channels TYPE for a 1:1 room. The existing three
--                      types (team, captain, booking) all hang off a single UUID in
--                      ref_id; a DM belongs to a PAIR of users and has no single
--                      entity, so its ref_id stays NULL and the pair is mapped
--                      separately (see 3). Widening the CHECK is safe: every existing
--                      row already has a type in the old set, so nothing revalidates.
--
--   3. direct_channels the canonical (user_lo, user_hi) → channel_id map that makes
--                      "the room for these two people" a single indexed lookup and
--                      keeps a pair from ever getting two rooms. ux_chat_channels_type_ref
--                      cannot do this job: it dedups on (type, ref_id), and a DM's
--                      ref_id is NULL.
--
-- Purely additive. No column changes on an existing table, and the one constraint
-- touched is only WIDENED, so every current chat read and write behaves exactly as
-- before until the first direct room is opened.

-- 1 ─ Allow the 'direct' channel type ───────────────────────────────────────────
-- Drop-then-add rather than the 015 add-if-absent block, because this must REPLACE
-- the four-value CHECK with the five-value one. Idempotent: a second run drops the
-- widened constraint and adds the identical one back.
ALTER TABLE chat_channels DROP CONSTRAINT IF EXISTS chk_chat_channels_type;
ALTER TABLE chat_channels
  ADD CONSTRAINT chk_chat_channels_type
  CHECK (type IN ('team', 'captain', 'booking', 'assistant', 'direct'));


-- 2 ─ The requests themselves ────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS play_requests (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  requester_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  target_user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  sport             text,                              -- the sport the ask is about; NULL = unspecified
  message           text,                              -- optional note from the requester
  status            text NOT NULL DEFAULT 'pending',   -- pending|accepted|declined|cancelled|expired
  -- The DM opened when the request is accepted, so the "Message" button on an
  -- accepted request goes straight to the room. SET NULL, not CASCADE: deleting a
  -- channel must not erase the request history that records the two ever connected.
  channel_id        UUID REFERENCES chat_channels(id) ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  decided_at        timestamptz,                       -- when it was accepted/declined
  expires_at        timestamptz,                       -- TTL; a stale ask reads as 'expired'
  CONSTRAINT chk_play_requests_status
    CHECK (status IN ('pending', 'accepted', 'declined', 'cancelled', 'expired')),
  CONSTRAINT chk_play_requests_not_self
    CHECK (requester_user_id <> target_user_id)
);

-- At most one LIVE ask per direction. Partial on status = 'pending', so a declined
-- or cancelled ask does not block the two from trying again later, and A→B being
-- open does not stop B→A. A duplicate pending insert raises 23505, which the service
-- turns into a friendly 409 rather than a second row.
CREATE UNIQUE INDEX IF NOT EXISTS ux_play_requests_pending
  ON play_requests (requester_user_id, target_user_id)
  WHERE status = 'pending';

-- The two inbox reads: "who is asking me" and "who have I asked", newest first.
CREATE INDEX IF NOT EXISTS idx_play_requests_incoming
  ON play_requests (target_user_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_play_requests_outgoing
  ON play_requests (requester_user_id, status, created_at DESC);


-- 3 ─ The pair → room map ─────────────────────────────────────────────────────────
-- Canonical ordering (user_lo < user_hi) makes {A,B} and {B,A} the same key, so the
-- pair has exactly one row and therefore exactly one room. The PK is the pair; the
-- channel is UNIQUE too, so a channel can never be claimed by two different pairs.
CREATE TABLE IF NOT EXISTS direct_channels (
  user_lo    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  user_hi    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  channel_id UUID NOT NULL UNIQUE REFERENCES chat_channels(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_lo, user_hi),
  CONSTRAINT chk_direct_channels_order CHECK (user_lo < user_hi)
);

COMMENT ON TABLE play_requests IS
  'Directed player-to-player "let''s play" asks with a pending/accepted/declined/'
  'cancelled/expired state machine. Accepting opens a direct chat (channel_id).';
COMMENT ON TABLE direct_channels IS
  'Canonical (user_lo<user_hi) -> channel_id map for 1:1 direct rooms, whose '
  'chat_channels.ref_id is NULL because a DM has no single entity to key on.';
