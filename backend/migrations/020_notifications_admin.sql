-- ═══════════════════════════════════════════════════════════════════════════
--  020_notifications_admin.sql   —   S.7 Waves C + D
--
--  Turns the notifications table from a WRITE-ONLY LOG into a feed, and adds the
--  two tables the admin module needs.
--
--  The starting position is the point of this migration. Migration 010 created
--  `notifications` and ~33 call sites have been inserting into it ever since —
--  but nothing on earth has ever read it. There is no GET route, no screen, no
--  bell. So the columns below are not decoration on a working feature; they are
--  the difference between a row that can only be printed and a row that can be
--  grouped, filtered, opened, expired and pushed.
--
--  WHAT IS DELIBERATELY NOT HERE
--    • idx_chat_messages_channel_created — the plan called it missing. It is not:
--      idx_chat_messages_channel is already (channel_id, created_at DESC), which
--      is the index the chat list's unread LATERAL uses. A second index over the
--      same columns under a different name would be dead weight on every write.
--    • disputes.resolved_at — already timestamptz, added by 016.
--    • A `suspended` boolean. users.is_active is ALREADY checked at login
--      (routes/auth.js), so a second flag would be two sources of truth for one
--      fact. This migration adds the audit columns AROUND it instead.
--
--  DISCIPLINE (same as 019): ADD COLUMN IF NOT EXISTS, guarded DO $$ blocks for
--  every constraint, CREATE ... IF NOT EXISTS for every index, never a DROP and
--  never a recreate. Re-running this file is a no-op.
-- ═══════════════════════════════════════════════════════════════════════════


-- ═══ SECTION 1 · notifications.created_at must be timestamptz ═══════════════
--
-- Migration 010 wrote `created_at TIMESTAMP` — no timezone. Every other
-- timestamp in this schema is timestamptz, so this one column is stored in
-- whatever the server's clock happened to be, and "2 hours ago" is wrong by the
-- server offset the moment the API is deployed anywhere but the developer's
-- laptop. Supabase runs UTC and node-postgres has been handing it UTC instants,
-- so `AT TIME ZONE 'UTC'` reinterprets the existing values correctly rather than
-- shifting them.
--
-- Guarded on the CURRENT type, not on a column list, so a second run finds
-- timestamptz and does nothing. Without the guard the second run would apply
-- AT TIME ZONE 'UTC' to an already-correct timestamptz and silently move every
-- historical row by the session offset.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'notifications'
       AND column_name = 'created_at' AND data_type = 'timestamp without time zone'
  ) THEN
    ALTER TABLE notifications
      ALTER COLUMN created_at TYPE timestamptz USING created_at AT TIME ZONE 'UTC';
    ALTER TABLE notifications ALTER COLUMN created_at SET DEFAULT now();
    RAISE NOTICE 'notifications.created_at converted to timestamptz';
  END IF;
END $$;


-- ═══ SECTION 2 · the feed columns ═══════════════════════════════════════════
--
-- `type` was VARCHAR(40) and the longest live type
-- ('booking_auto_confirmed_owner', 28) sits 12 characters from the ceiling —
-- close enough that the next sensibly-named type is a runtime 22001 inside a
-- money transaction. text costs nothing in Postgres. `title` (VARCHAR(255))
-- carries venue names and full sentences and gets the same treatment.
ALTER TABLE notifications ALTER COLUMN type  TYPE text;
ALTER TABLE notifications ALTER COLUMN title TYPE text;

ALTER TABLE notifications
  -- WHEN, not just WHETHER. is_read is a boolean with no timestamp, so "you read
  -- this before the match started" is unanswerable. Kept alongside is_read
  -- rather than replacing it: 33 call sites and one index reference the boolean.
  ADD COLUMN IF NOT EXISTS read_at       timestamptz,
  -- Dismiss is NOT read. Swiping a row away says "I have dealt with this";
  -- opening the list says "I have seen it". Collapsing the two loses the only
  -- signal that distinguishes an ignored feed from an empty one.
  ADD COLUMN IF NOT EXISTS dismissed_at  timestamptz,
  -- The unit a user opts out of, and the filter chip row. NOT NULL with a
  -- default so the outbox never has to reason about a null category; Section 3
  -- backfills the real values from the type prefix.
  ADD COLUMN IF NOT EXISTS category      text NOT NULL DEFAULT 'system',
  -- Decides whether FCM fires at all, and whether it is a heads-up notification
  -- or a quiet tray line. A booking approval is high; "someone joined your team"
  -- is not worth waking a phone for.
  ADD COLUMN IF NOT EXISTS priority      text NOT NULL DEFAULT 'normal',
  -- Collapse. Three messages in one chat is ONE row reading "3 new messages",
  -- not three rows and three buzzes. The unique partial index in Section 5 is
  -- what makes the upsert atomic.
  ADD COLUMN IF NOT EXISTS group_key     text,
  ADD COLUMN IF NOT EXISTS group_count   integer NOT NULL DEFAULT 1,
  -- {route, args} computed server-side from the type registry, so the client
  -- never guesses a route from a type string and the two cannot drift.
  ADD COLUMN IF NOT EXISTS deep_link     jsonb,
  -- Who caused it, and their avatar. A row that reads like a person is worth
  -- more than one that reads like an event.
  ADD COLUMN IF NOT EXISTS actor_id      uuid,
  ADD COLUMN IF NOT EXISTS image_url     text,
  -- The polymorphic target of the tap. booking_id already exists (010) and is
  -- kept — this covers the other five kinds of thing a notification is about.
  ADD COLUMN IF NOT EXISTS entity_type   text,
  ADD COLUMN IF NOT EXISTS entity_id     uuid,
  -- A challenge alert past its 48h TTL must not render as actionable, and must
  -- not be pushed at all if the outbox reaches it late.
  ADD COLUMN IF NOT EXISTS expires_at    timestamptz,
  -- THE OUTBOX. notify() runs inside money transactions holding FOR UPDATE
  -- locks; an HTTPS call to FCM there would hold row locks across a network
  -- round trip. So the row IS the outbox and pushJob drains it. These four
  -- columns are also the answer to "why didn't my phone buzz?" — in SQL.
  ADD COLUMN IF NOT EXISTS sent_push     boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS push_attempts integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS pushed_at     timestamptz,
  ADD COLUMN IF NOT EXISTS push_error    text;

-- actor_id as a real FK, added separately so a database that somehow holds an
-- actor id for a deleted user does not fail the whole migration on the ALTER.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'notifications_actor_id_fkey') THEN
    -- Any orphan is nulled first: an alert stays readable when the person who
    -- caused it deletes their account, which is also why this is SET NULL.
    UPDATE notifications SET actor_id = NULL
     WHERE actor_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM users u WHERE u.id = notifications.actor_id);
    ALTER TABLE notifications
      ADD CONSTRAINT notifications_actor_id_fkey
      FOREIGN KEY (actor_id) REFERENCES users(id) ON DELETE SET NULL;
  END IF;
END $$;


-- ═══ SECTION 3 · backfill, before any CHECK can validate it ═════════════════
--
-- ADD CONSTRAINT validates every existing row immediately, so the vocabulary has
-- to be true of the 187 rows already in the table before the CHECK goes on.
-- The mapping is by type PREFIX because that is how the types were actually
-- named — booking_*, match_*, tournament_*, team_*, withdrawal_*, assistant_* —
-- and anything unrecognised lands in 'system', which is the honest answer for a
-- row whose category nobody has decided yet.
UPDATE notifications SET category =
  CASE
    WHEN type LIKE 'booking%'     THEN 'booking'
    WHEN type LIKE 'match%'       THEN 'match'
    WHEN type = 'elo_frozen'      THEN 'match'
    WHEN type LIKE 'tournament%'  THEN 'tournament'
    WHEN type LIKE 'team%'        THEN 'team'
    WHEN type LIKE 'withdrawal%'  THEN 'wallet'
    WHEN type LIKE 'wallet%'      THEN 'wallet'
    WHEN type LIKE 'escrow%'      THEN 'wallet'
    WHEN type LIKE 'refund%'      THEN 'wallet'
    WHEN type LIKE 'assistant%'   THEN 'assistant'
    WHEN type LIKE 'chat%'        THEN 'chat'
    WHEN type LIKE 'review%'      THEN 'review'
    WHEN type LIKE 'venue%'       THEN 'venue'
    WHEN type LIKE 'dispute%'     THEN 'match'
    WHEN type LIKE 'account%'     THEN 'system'
    ELSE 'system'
  END
WHERE category = 'system';

-- "Read at some unknown time" is a better fact than "never read" for a row the
-- boolean already says was read. created_at is the only timestamp that exists on
-- these rows, and it is a lower bound, not a guess at the real moment.
UPDATE notifications SET read_at = created_at
 WHERE is_read = TRUE AND read_at IS NULL;

-- is_read is nullable (010 gave it a DEFAULT but no NOT NULL), and every partial
-- index and every feed query below tests `is_read = false`. A single NULL row
-- would answer NULL to that — not true — so it would be invisible to the badge,
-- absent from ux_notifications_group, and therefore immune to the collapse
-- upsert. That is precisely the silent breakage this migration exists to remove,
-- so the column is closed rather than left as a trap. 0 rows are NULL today.
UPDATE notifications SET is_read = FALSE WHERE is_read IS NULL;
ALTER TABLE notifications ALTER COLUMN is_read SET NOT NULL;

-- Priority for the history, so a backfilled row does not read as 'normal' when
-- its type would have been high. Only the two that actually matter are raised:
-- money moved, or something is waiting on this person.
UPDATE notifications SET priority = 'high'
 WHERE priority = 'normal'
   AND type IN ('booking_confirmed', 'booking_rejected', 'booking_auto_confirmed',
                'booking_auto_rejected', 'booking_no_show', 'match_challenge',
                'match_disputed', 'match_verify_pending', 'withdrawal_completed',
                'tournament_won', 'tournament_fixtures_ready');


-- ═══ SECTION 4 · the vocabularies, enforced ═════════════════════════════════
--
-- A CHECK that exists but does not constrain reads as enforced and is enforced
-- nowhere, so each of these is probed by run_migration_020.js with a row that
-- MUST be rejected.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_notifications_category') THEN
    ALTER TABLE notifications ADD CONSTRAINT chk_notifications_category
      CHECK (category IN ('booking','match','tournament','wallet','team','chat',
                          'venue','review','assistant','system'));
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_notifications_priority') THEN
    ALTER TABLE notifications ADD CONSTRAINT chk_notifications_priority
      CHECK (priority IN ('high','normal','low'));
  END IF;

  -- A collapsed row counts itself. group_count = 0 would render as "0 new
  -- messages", which is a row that says nothing happened.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_notifications_group_count') THEN
    ALTER TABLE notifications ADD CONSTRAINT chk_notifications_group_count
      CHECK (group_count >= 1);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_notifications_entity') THEN
    ALTER TABLE notifications ADD CONSTRAINT chk_notifications_entity
      CHECK (entity_type IS NULL OR entity_type IN
        ('booking','match','tournament','team','venue','channel','withdrawal','user','dispute'));
  END IF;

  -- push_attempts is what stops the outbox retrying a permanently-dead token
  -- forever; a negative value would defeat the cap.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_notifications_push_attempts') THEN
    ALTER TABLE notifications ADD CONSTRAINT chk_notifications_push_attempts
      CHECK (push_attempts >= 0);
  END IF;
END $$;


-- ═══ SECTION 5 · the four indexes the feed actually reads through ═══════════
--
-- idx_notifications_user (010) is (user_id, is_read, created_at DESC) and stays —
-- it serves the unfiltered list. These four cover what 010 could not know about.

-- The badge and the default "unread only" view. Partial, so it holds only the
-- rows a user has not dealt with — which for an active user is a handful out of a
-- history of thousands.
CREATE INDEX IF NOT EXISTS idx_notifications_unread
  ON notifications (user_id, created_at DESC)
  WHERE is_read = false AND dismissed_at IS NULL;

-- The outbox scan, every 4 seconds, forever. Partial on sent_push = false so the
-- index is empty when the queue is drained and the scan costs nothing.
CREATE INDEX IF NOT EXISTS idx_notifications_outbox
  ON notifications (created_at)
  WHERE sent_push = false;

-- The category filter chips.
CREATE INDEX IF NOT EXISTS idx_notifications_category
  ON notifications (user_id, category, created_at DESC);

-- THE COLLAPSE. This is a UNIQUE index and not merely a lookup: it is what makes
-- notify()'s ON CONFLICT upsert atomic, so two chat messages arriving in the same
-- millisecond produce one row reading "2 new messages" rather than two rows or a
-- lost update. The predicate must match the ON CONFLICT ... WHERE clause exactly
-- for Postgres to infer this index.
--
-- Read and dismissed rows are OUT of the index on purpose: once you have seen
-- "2 new messages", the next message must start a fresh row rather than bump a
-- row you have already read.
CREATE UNIQUE INDEX IF NOT EXISTS ux_notifications_group
  ON notifications (user_id, group_key)
  WHERE group_key IS NOT NULL AND is_read = false AND dismissed_at IS NULL;


-- ═══ SECTION 6 · user_devices — one row per phone, not one token per user ════
--
-- users.fcm_token already exists and is one-per-user: "last login wins". That
-- breaks the instant you use a phone AND an emulator, which is the exact setup
-- this project is demoed on — the emulator's login silently steals the token and
-- the phone stops buzzing with no error anywhere.
--
-- It also cannot record a token as DEAD. FCM rotates tokens and answers
-- `registration-token-not-registered` for a stale one; that must revoke ONE
-- device, not log the user out everywhere. A revoked row is kept rather than
-- deleted so "your other phone stopped receiving pushes on the 3rd" is
-- answerable.
--
-- THERE IS NOTHING TO MIGRATE OUT OF users.fcm_token: the column has existed
-- since 013 and, verified by grep, NO code has ever written or read it (24 users,
-- 0 tokens). It is vestigial, and it stays only because this schema never DROPs —
-- verify_schema.js asserts its presence. user_devices is the sole registry.
CREATE TABLE IF NOT EXISTS user_devices (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  fcm_token     text NOT NULL,
  platform      text,
  app_version   text,
  device_label  text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  last_seen_at  timestamptz NOT NULL DEFAULT now(),
  revoked_at    timestamptz,
  revoke_reason text
);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_user_devices_platform') THEN
    ALTER TABLE user_devices ADD CONSTRAINT chk_user_devices_platform
      CHECK (platform IS NULL OR platform IN ('android','ios','web'));
  END IF;
END $$;

-- A token identifies a device installation, globally. If it reappears under a
-- different user (a shared phone, a reinstall after a logout) the row must MOVE,
-- not duplicate — otherwise the previous owner keeps receiving the new owner's
-- notifications, which is a privacy failure and not merely a bug. The UNIQUE is
-- what lets the register endpoint be a single ON CONFLICT upsert.
CREATE UNIQUE INDEX IF NOT EXISTS ux_user_devices_token ON user_devices (fcm_token);

-- The send path: every live device for one user, in one indexed read.
CREATE INDEX IF NOT EXISTS idx_user_devices_user
  ON user_devices (user_id) WHERE revoked_at IS NULL;


-- ═══ SECTION 7 · admin_audit — one table behind every admin write ═══════════
--
-- "Who changed this, and what did it look like before?" is the first question
-- anyone asks about an admin panel, and today there is no way to answer it: the
-- dispute ruling, the suspension and the commission change all just happen.
--
-- before/after are jsonb rather than columns because the five writes behind this
-- table touch five different shapes, and a row that stores the whole prior state
-- can answer a question nobody thought to add a column for.
CREATE TABLE IF NOT EXISTS admin_audit (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_id    uuid REFERENCES users(id) ON DELETE SET NULL,
  action      text NOT NULL,
  entity_type text,
  entity_id   uuid,
  before      jsonb,
  after       jsonb,
  note        text,
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- The audit log read backwards, which is the only way anyone reads one.
CREATE INDEX IF NOT EXISTS idx_admin_audit_created ON admin_audit (created_at DESC);
-- "Everything that has ever been done to THIS match / THIS user."
CREATE INDEX IF NOT EXISTS idx_admin_audit_entity
  ON admin_audit (entity_type, entity_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_admin_audit_admin
  ON admin_audit (admin_id, created_at DESC);


-- ═══ SECTION 8 · users — preferences, and the suspension audit trail ════════
ALTER TABLE users
  -- Per-category × in-app/push toggles plus quiet hours, ENFORCED IN THE JOB.
  -- A preference the client honours is a suggestion; this column is read
  -- server-side before anything is sent. '{}' means "every default", so an
  -- existing user needs no backfill and a new key needs no migration.
  ADD COLUMN IF NOT EXISTS notification_prefs jsonb NOT NULL DEFAULT '{}'::jsonb,
  -- The audit trail AROUND is_active, which is the flag login already checks.
  -- Adding a second `suspended` boolean would create two sources of truth for one
  -- fact, and the two would disagree within a sprint.
  ADD COLUMN IF NOT EXISTS suspended_at       timestamptz,
  ADD COLUMN IF NOT EXISTS suspended_reason   text,
  ADD COLUMN IF NOT EXISTS suspended_by       uuid;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'users_suspended_by_fkey') THEN
    UPDATE users SET suspended_by = NULL
     WHERE suspended_by IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM users a WHERE a.id = users.suspended_by);
    ALTER TABLE users ADD CONSTRAINT users_suspended_by_fkey
      FOREIGN KEY (suspended_by) REFERENCES users(id) ON DELETE SET NULL;
  END IF;
END $$;

-- The admin user search (?q=&role=&status=). Without this, "find the player who
-- emailed me" is a sequential scan over every account.
CREATE INDEX IF NOT EXISTS idx_users_role_active ON users (role, is_active);


-- ═══ SECTION 9 · disputes — the ruling, and what it cost ════════════════════
--
-- The raise flow has existed since 016 (routes/matches.js inserts here twice);
-- nothing has ever read or ruled on one. resolved_at and chk_disputes_status
-- ('open','resolved','dismissed') are already in place.
ALTER TABLE disputes
  -- WHICH way it was ruled, as a vocabulary rather than free text in
  -- resolution_notes — the queue counts rulings, and a human sentence cannot be
  -- counted.
  ADD COLUMN IF NOT EXISTS ruling                 text,
  -- The scoreline the admin decided, which for 'custom' is neither team's
  -- submission. Stored on the dispute as well as on the match so the case file
  -- still shows what was ruled after a later correction to the match row.
  ADD COLUMN IF NOT EXISTS ruled_score_challenger integer,
  ADD COLUMN IF NOT EXISTS ruled_score_opponent   integer,
  -- The rating actually at stake, computed at raise/queue time with the live
  -- K-factor. This is what lets the queue sort by consequence instead of by age:
  -- a 40-point swing between two 1400-rated teams matters more than a 4-point
  -- one, and the admin should see it first.
  ADD COLUMN IF NOT EXISTS severity_elo           integer;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_disputes_ruling') THEN
    ALTER TABLE disputes ADD CONSTRAINT chk_disputes_ruling
      CHECK (ruling IS NULL OR ruling IN ('challenger','opponent','draw','custom','dismissed'));
  END IF;
  -- A negative goal count is not a scoreline. Kept as a CHECK rather than a
  -- validation in the route because the route is not the only thing that will
  -- ever write here.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_disputes_ruled_scores') THEN
    ALTER TABLE disputes ADD CONSTRAINT chk_disputes_ruled_scores
      CHECK ((ruled_score_challenger IS NULL OR ruled_score_challenger >= 0)
         AND (ruled_score_opponent   IS NULL OR ruled_score_opponent   >= 0));
  END IF;
END $$;

-- The queue: open disputes, worst first, then oldest. idx_disputes_status (016)
-- is on status alone and cannot order; this one is the queue's own index.
CREATE INDEX IF NOT EXISTS idx_disputes_queue
  ON disputes (severity_elo DESC NULLS LAST, created_at)
  WHERE status = 'open';
