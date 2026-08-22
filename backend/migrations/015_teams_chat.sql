-- ════════════════════════════════════════════════════════════════════════════
-- 015 — S.2 Wave A: teams hardening + WhatsApp-style group chat
-- ════════════════════════════════════════════════════════════════════════════
--
-- Migration 013 already created every TABLE S.2 needs (teams columns,
-- team_invites, team_join_requests, chat_channels, chat_messages). This
-- migration adds only what turned out to be MISSING once the endpoints and the
-- chat UI were actually written. Nothing here duplicates 013.
--
-- Why each block exists:
--
--   1. FR2.1 says a team name is unique per sport. NOTHING enforced that —
--      schema.sql:213 declares `name VARCHAR(255) NOT NULL` with no unique key,
--      so two "Lahore Lions" football teams could both exist and the roster/
--      challenge flows would be ambiguous. A JS pre-check cannot do this (two
--      simultaneous POSTs both pass it), so it is a UNIQUE INDEX and the route
--      turns 23505 into a friendly 409 — the same pattern as
--      uq_withdrawals_one_pending in 014.
--
--   2. GET /api/teams/mine filters team_members by user_id. The only index on
--      that table is UNIQUE(team_id, user_id), which leads on team_id — so
--      "my teams" was a sequential scan of every membership row in the system.
--
--   3. Chat needs per-member state that 013 has no home for: who is in the
--      channel, their group role, whether they muted it, and the two
--      high-water marks that make single/double/blue ticks work. Storing
--      receipts as marks on the MEMBER (not rows per message × member) keeps
--      this O(members) instead of O(messages × members) — 013's
--      chat_messages.read_by jsonb is left in place but is legacy-unread.
--
--   4. chat_messages was text-only: body is NOT NULL and there are no media,
--      reply, edit or delete columns. Images and voice notes need all of them.
--
-- DEVIATIONS / deliberate omissions
--   a. No index is added where an existing UNIQUE constraint already leads with
--      the same column (chat_reactions(message_id), chat_channel_members
--      (channel_id,...)) — the same discipline 013's header states.
--   b. No ASC copy of idx_chat_messages_channel. A btree on
--      (channel_id, created_at DESC) serves ORDER BY created_at ASC by scanning
--      backwards; a second index would double write cost for nothing.
--   c. idx_chat_channels_ref from 013 IS dropped, and replaced by a UNIQUE
--      partial index on the same columns. It is not a duplicate — "one team has
--      exactly one team channel" has to be enforced, or a race in
--      ensureTeamChannel() creates two chats for one team and half the roster
--      talks into the wrong one. The unique index also serves every lookup the
--      dropped one served.
--   d. teams.captain_id is KEPT and kept in sync, but team_members.role is the
--      authoritative source of captaincy from here on — FR2.10 allows more than
--      one captain, which a single column cannot represent. Same treatment 013
--      gave elo_rating → elo.
--
-- Safe to re-run: every statement is IF NOT EXISTS / ON CONFLICT / guarded by a
-- catalog lookup. Applied as ONE command, so Postgres wraps it in a single
-- implicit transaction and it is all-or-nothing.


-- ════════════════════════════════════════════════════════════════════════════
-- 1. TEAMS — the FR2.1 uniqueness rule, plus the indexes the routes need
-- ════════════════════════════════════════════════════════════════════════════

-- lower(btrim(name)) — "Lahore Lions", "lahore lions" and " Lahore Lions "
-- are the same team name to a human, so they must collide here too. The route
-- normalises the same way before inserting, so the stored name keeps the
-- capitalisation the captain typed.
CREATE UNIQUE INDEX IF NOT EXISTS ux_teams_name_sport
  ON teams (lower(btrim(name)), sport);

-- GET /api/teams/mine  →  WHERE tm.user_id = $1   (see reason 2 above)
CREATE INDEX IF NOT EXISTS idx_team_members_user
  ON team_members (user_id);

-- GET /api/teams/rankings  →  WHERE sport = $1 ORDER BY elo DESC
CREATE INDEX IF NOT EXISTS idx_teams_sport_elo
  ON teams (sport, elo DESC);

-- Browse / find-opponents filters on visibility before anything else.
CREATE INDEX IF NOT EXISTS idx_teams_visibility_sport
  ON teams (visibility, sport);

-- Who invited whom — shown in the roster ("added by Ali") and needed to audit
-- an invite chain if a team is reported.
ALTER TABLE team_members ADD COLUMN IF NOT EXISTS invited_by uuid REFERENCES users(id);

-- role was `VARCHAR(20) DEFAULT 'member'` with no constraint, so a typo in any
-- future route could write role='captian' and silently strip someone of their
-- captaincy. Normalise anything unexpected to 'member' FIRST, or the constraint
-- cannot be added to a table that already violates it.
UPDATE team_members
   SET role = 'member'
 WHERE role IS NULL OR role NOT IN ('captain', 'vice_captain', 'member');

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'chk_team_members_role'
  ) THEN
    ALTER TABLE team_members
      ADD CONSTRAINT chk_team_members_role
      CHECK (role IN ('captain', 'vice_captain', 'member'));
  END IF;
END $$;

-- A team created before this migration may have teams.captain_id set but no
-- team_members row for that captain — the old UI never wrote one. From here on
-- team_members.role is authoritative (deviation d), so the founder has to
-- actually be in the roster or the "≥1 captain" invariant reads as violated and
-- nobody can administer the team.
INSERT INTO team_members (team_id, user_id, role)
SELECT t.id, t.captain_id, 'captain'
  FROM teams t
 WHERE t.captain_id IS NOT NULL
   AND NOT EXISTS (
     SELECT 1 FROM team_members m
      WHERE m.team_id = t.id AND m.user_id = t.captain_id)
ON CONFLICT (team_id, user_id) DO NOTHING;

-- And promote the founder if they are in the roster as a plain member.
UPDATE team_members m
   SET role = 'captain'
  FROM teams t
 WHERE t.id = m.team_id
   AND t.captain_id = m.user_id
   AND m.role <> 'captain';


-- ════════════════════════════════════════════════════════════════════════════
-- 2. TEAM INVITES — hashed at rest, revocable (FR2.11)
-- ════════════════════════════════════════════════════════════════════════════
--
-- An invite token is a bearer capability: whoever holds the string joins the
-- team. 013 stored it in plaintext, so a leaked database dump — or anyone with
-- read access to it — could join any team that had an outstanding invite.
--
-- We now store sha256(token) and never the token itself, exactly the way a
-- password-reset token is handled. POST /teams/join/:token hashes the incoming
-- value and looks THAT up, so the UNIQUE index still does the work.
--
-- token_prefix is the first 8 characters, kept in the clear on purpose: the
-- captain's "pending invites" list has to label rows somehow ("Invite ••••a3f9")
-- and 8 characters of a 43-character base64url string is not a usable secret.
ALTER TABLE team_invites
  ADD COLUMN IF NOT EXISTS token_hash   text,
  ADD COLUMN IF NOT EXISTS token_prefix text,
  ADD COLUMN IF NOT EXISTS revoked_at   timestamptz,
  ADD COLUMN IF NOT EXISTS used_at      timestamptz,
  ADD COLUMN IF NOT EXISTS note         text;

-- 013 declared token NOT NULL. New rows write token_hash and leave token NULL,
-- so the old constraint has to go or every INSERT fails.
ALTER TABLE team_invites ALTER COLUMN token DROP NOT NULL;

-- Any row written before this migration is unusable under the new scheme (we
-- cannot recover a hash from a token we no longer trust), so hash what is there
-- rather than leaving rows that can never be matched. pgcrypto's digest() is not
-- guaranteed present, so this uses md5 — NOT for security, only so pre-existing
-- development rows have a deterministic non-null value. Real tokens are hashed
-- in Node with crypto.createHash('sha256'), which is 64 hex characters; these
-- legacy rows are 32 and can therefore never collide with a real one.
UPDATE team_invites
   SET token_hash   = md5(token),
       token_prefix = left(token, 8)
 WHERE token IS NOT NULL AND token_hash IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS ux_team_invites_token_hash
  ON team_invites (token_hash);

-- GET /api/teams/:id/invites — the captain's outstanding-invite list.
CREATE INDEX IF NOT EXISTS idx_team_invites_team
  ON team_invites (team_id, created_at DESC);


-- ════════════════════════════════════════════════════════════════════════════
-- 3. JOIN REQUESTS — audit columns + a re-request path
-- ════════════════════════════════════════════════════════════════════════════
--
-- 013 has UNIQUE (team_id, user_id), which is right — one live request per
-- person — but it means a rejected player can never ask again, because the row
-- survives the rejection. The route therefore UPSERTs a rejected/cancelled row
-- back to 'pending' instead of inserting; that needs no schema change, only the
-- audit columns below so "rejected by X on date Y" is not lost when it happens.
ALTER TABLE team_join_requests
  ADD COLUMN IF NOT EXISTS decided_at timestamptz,
  ADD COLUMN IF NOT EXISTS decided_by uuid REFERENCES users(id),
  ADD COLUMN IF NOT EXISTS message    text;

UPDATE team_join_requests
   SET status = 'pending'
 WHERE status IS NULL
    OR status NOT IN ('pending', 'approved', 'rejected', 'cancelled');

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'chk_join_requests_status'
  ) THEN
    ALTER TABLE team_join_requests
      ADD CONSTRAINT chk_join_requests_status
      CHECK (status IN ('pending', 'approved', 'rejected', 'cancelled'));
  END IF;
END $$;

-- The captain's pending queue, and the badge count on the roster screen.
CREATE INDEX IF NOT EXISTS idx_join_requests_team_status
  ON team_join_requests (team_id, status);


-- ════════════════════════════════════════════════════════════════════════════
-- 4. CHAT CHANNELS — one per team, with a denormalised last message
-- ════════════════════════════════════════════════════════════════════════════
--
-- last_message_at / _preview / _sender_id exist so the chat LIST is a single
-- indexed read of chat_channel_members joined to chat_channels. The obvious
-- alternative — a correlated subquery per channel to find its newest message —
-- is the classic N+1 that makes a messenger's list screen feel slow, and it gets
-- worse with every message ever sent. These three columns are written in the
-- same transaction as the INSERT into chat_messages, so they cannot drift.
--
-- title / image_url are denormalised from the team for the same reason, and are
-- re-synced by PATCH /api/teams/:id when the name or logo changes.
ALTER TABLE chat_channels
  ADD COLUMN IF NOT EXISTS title                  text,
  ADD COLUMN IF NOT EXISTS image_url              text,
  ADD COLUMN IF NOT EXISTS created_by             uuid REFERENCES users(id),
  ADD COLUMN IF NOT EXISTS last_message_at        timestamptz,
  ADD COLUMN IF NOT EXISTS last_message_preview   text,
  ADD COLUMN IF NOT EXISTS last_message_sender_id uuid REFERENCES users(id),
  ADD COLUMN IF NOT EXISTS message_count          int NOT NULL DEFAULT 0;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'chk_chat_channels_type'
  ) THEN
    ALTER TABLE chat_channels
      ADD CONSTRAINT chk_chat_channels_type
      CHECK (type IN ('team', 'captain', 'booking', 'assistant'));
  END IF;
END $$;

-- "One team, one chat" — enforced, not hoped for. See deviation c: the
-- non-unique index this replaces answered exactly the same lookups.
DROP INDEX IF EXISTS idx_chat_channels_ref;
CREATE UNIQUE INDEX IF NOT EXISTS ux_chat_channels_type_ref
  ON chat_channels (type, ref_id) WHERE ref_id IS NOT NULL;


-- ════════════════════════════════════════════════════════════════════════════
-- 5. CHANNEL MEMBERS — group participants, roles, mute, and the tick marks
-- ════════════════════════════════════════════════════════════════════════════
--
-- The two timestamp columns ARE the tick system:
--
--   ✓   sent       the row exists in chat_messages (the server accepted it)
--   ✓✓  delivered  every other member has last_delivered_at >= created_at
--   ✓✓  read       every other member has last_read_at      >= created_at
--
-- Marks rather than rows because a 20-person team sending 1,000 messages would
-- otherwise need 20,000 receipt rows, all of which have to be written on every
-- "seen" event. A mark is one UPDATE per member per visit, and the group tick is
-- MIN(mark) across the other members — computed in one aggregate.
--
-- left_at is a soft leave: WhatsApp keeps "Ali left" and Ali's old messages
-- visible after he goes, and a hard DELETE would take his history with it (or
-- orphan it). Every membership query filters `left_at IS NULL`.
CREATE TABLE IF NOT EXISTS chat_channel_members (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id        uuid NOT NULL REFERENCES chat_channels(id) ON DELETE CASCADE,
  user_id           uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role              text NOT NULL DEFAULT 'member',
  joined_at         timestamptz NOT NULL DEFAULT now(),
  left_at           timestamptz,
  -- Epoch, not NULL: "has read nothing" and "has read up to X" then compare
  -- with the same operator and no COALESCE is needed in any hot query.
  last_read_at      timestamptz NOT NULL DEFAULT '1970-01-01T00:00:00Z',
  last_delivered_at timestamptz NOT NULL DEFAULT '1970-01-01T00:00:00Z',
  muted_until       timestamptz,
  UNIQUE (channel_id, user_id),
  CONSTRAINT chk_chat_member_role CHECK (role IN ('admin', 'member'))
);

-- "Which chats am I in?" — the chat list's driving query. Partial, because a
-- member who has left is never listed and would only bloat the index.
CREATE INDEX IF NOT EXISTS idx_chat_members_user_active
  ON chat_channel_members (user_id) WHERE left_at IS NULL;


-- ════════════════════════════════════════════════════════════════════════════
-- 6. CHAT MESSAGES — media, replies, edits, deletes, idempotency
-- ════════════════════════════════════════════════════════════════════════════
ALTER TABLE chat_messages
  -- Client-generated id. Two jobs: the optimistic bubble the sender already
  -- drew can be matched to the server row when it echoes back, and a retry
  -- after a dropped response cannot post the same message twice (the partial
  -- unique index below rejects it, and the route answers 200 with the original).
  ADD COLUMN IF NOT EXISTS client_id   text,
  ADD COLUMN IF NOT EXISTS kind        text NOT NULL DEFAULT 'text',
  ADD COLUMN IF NOT EXISTS media_url   text,
  ADD COLUMN IF NOT EXISTS media_mime  text,
  ADD COLUMN IF NOT EXISTS media_bytes int,
  ADD COLUMN IF NOT EXISTS media_w     int,
  ADD COLUMN IF NOT EXISTS media_h     int,
  ADD COLUMN IF NOT EXISTS duration_ms int,
  -- Amplitude samples captured while recording, 0-100, ~40 of them. Drawing the
  -- real waveform needs no audio decoding on the receiving device.
  ADD COLUMN IF NOT EXISTS waveform    jsonb,
  ADD COLUMN IF NOT EXISTS reply_to_id uuid REFERENCES chat_messages(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS edited_at   timestamptz,
  ADD COLUMN IF NOT EXISTS deleted_at  timestamptz,
  ADD COLUMN IF NOT EXISTS deleted_by  uuid REFERENCES users(id),
  -- For is_system rows: {"event":"member_added","actor":"…","target":"…"} so the
  -- client can render "Ali added Sara" with real names and tappable avatars
  -- instead of a frozen English sentence that cannot be localised.
  ADD COLUMN IF NOT EXISTS system_meta jsonb;

-- 013 declared body NOT NULL. An image or a voice note has no body.
ALTER TABLE chat_messages ALTER COLUMN body DROP NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'chk_chat_messages_kind'
  ) THEN
    ALTER TABLE chat_messages
      ADD CONSTRAINT chk_chat_messages_kind
      CHECK (kind IN ('text', 'image', 'audio', 'system'));
  END IF;
END $$;

-- A row must carry SOMETHING. Without this a bug that posts an empty body and
-- no media leaves an untappable blank bubble in the history forever.
--
-- The `deleted_at IS NOT NULL` escape hatch is load-bearing, not laziness:
-- "delete for everyone" must actually REMOVE the text and the media URL, not
-- merely hide them behind a flag the client is trusted to respect. A tombstone
-- therefore has no payload at all, and the client renders "This message was
-- deleted" from deleted_at alone.
--
-- DROP-then-ADD rather than a DO-block guard, so re-running this migration
-- REPLACES an older definition of the same rule instead of leaving the first one
-- in place — which is what an `IF NOT EXISTS` check would silently do.
ALTER TABLE chat_messages DROP CONSTRAINT IF EXISTS chk_chat_messages_payload;
ALTER TABLE chat_messages
  ADD CONSTRAINT chk_chat_messages_payload
  CHECK (
    deleted_at IS NOT NULL OR
    (kind = 'text'   AND body IS NOT NULL AND btrim(body) <> '') OR
    (kind = 'system' AND body IS NOT NULL) OR
    (kind IN ('image', 'audio') AND media_url IS NOT NULL)
  );

-- Idempotent send (reason above). Partial so the millions of legacy/system rows
-- with a NULL client_id are not indexed and cannot collide with each other.
CREATE UNIQUE INDEX IF NOT EXISTS ux_chat_messages_client
  ON chat_messages (channel_id, sender_id, client_id)
  WHERE client_id IS NOT NULL;

-- Media grid in group-info ("47 photos"). Partial — it indexes only the few
-- percent of rows that are media, so it stays tiny.
CREATE INDEX IF NOT EXISTS idx_chat_messages_media
  ON chat_messages (channel_id, created_at DESC)
  WHERE kind IN ('image', 'audio') AND deleted_at IS NULL;


-- ════════════════════════════════════════════════════════════════════════════
-- 7. REACTIONS — one emoji per person per message, as in WhatsApp
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS chat_reactions (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id uuid NOT NULL REFERENCES chat_messages(id) ON DELETE CASCADE,
  user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  emoji      text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  -- Tapping a second emoji REPLACES the first, so this is the whole rule.
  UNIQUE (message_id, user_id)
);
-- No index on message_id alone: UNIQUE (message_id, user_id) already leads with
-- it, so reaction lookups for a message use that (see deviation a).


-- ════════════════════════════════════════════════════════════════════════════
-- 8. PRESENCE — "online" / "last seen today at 6:12 pm"
-- ════════════════════════════════════════════════════════════════════════════
-- Written when a socket disconnects. Live presence itself is in-memory in the
-- realtime layer (it is worthless after a restart), but last-seen has to survive
-- one, or every user reads "last seen a long time ago" after a deploy.
ALTER TABLE users ADD COLUMN IF NOT EXISTS last_seen_at timestamptz;


-- ════════════════════════════════════════════════════════════════════════════
-- 9. BACKFILL — every existing team gets its group chat
-- ════════════════════════════════════════════════════════════════════════════
-- Without this, teams created before S.2 have a "Team chat" button that opens
-- nothing, and the first person to tap it would race two channels into
-- existence if ux_chat_channels_type_ref were not there to stop them.
INSERT INTO chat_channels (type, ref_id, title, image_url, created_by, created_at)
SELECT 'team', t.id, t.name, t.logo_url, t.captain_id, COALESCE(t.created_at, now())
  FROM teams t
 WHERE NOT EXISTS (
   SELECT 1 FROM chat_channels c WHERE c.type = 'team' AND c.ref_id = t.id);

INSERT INTO chat_channel_members (channel_id, user_id, role, joined_at)
SELECT c.id,
       tm.user_id,
       CASE WHEN tm.role IN ('captain', 'vice_captain') THEN 'admin' ELSE 'member' END,
       COALESCE(tm.joined_at, now())
  FROM chat_channels c
  JOIN team_members tm ON tm.team_id = c.ref_id
 WHERE c.type = 'team'
ON CONFLICT (channel_id, user_id) DO NOTHING;
