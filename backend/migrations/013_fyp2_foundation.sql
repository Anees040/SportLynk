-- Migration 013: FYP-2 foundation — schema for milestones S.2 → S.7 (Wave D)
--
-- Lands every table the next six milestones need, in one pass, so those waves
-- only ever write code. Nothing in this migration is READ by any code yet; that
-- is deliberate — see the "wired to nothing" notes below.
--
-- Run with:  node run_migration_013.js
--
-- ─── Why this is 013 and not 010 ────────────────────────────────────────────
-- The wave spec named this file 010_fyp2_foundation.sql, but 010 is taken by
-- 010_escrow_policy_alignment.sql, which is already applied. 011 = slot locks,
-- 012 = hardening indexes. 013 is the next free number.
--
-- ─── Why every key here is UUID, not serial/int ─────────────────────────────
-- The spec declared `id serial PRIMARY KEY` and `<col> int REFERENCES <t>(id)`.
-- Every primary key in this database is UUID (schema.sql: users:23, venues:51,
-- bookings:151, teams:210, …), so `int REFERENCES teams(id)` cannot be created
-- at all — Postgres rejects it with "foreign key constraint cannot be
-- implemented: incompatible types integer and uuid". All keys below are
-- therefore UUID. Genuine integers (scores, rounds, elo, max_teams) stay int.
--
-- ─── Deliberate deviations from the spec ────────────────────────────────────
-- 1. users.suspended       NOT added. users.is_active already is the suspension
--                          flag and is already enforced — src/routes/auth.js:164
--                          returns 403 "Account suspended." when it is false.
--                          A second flag would let an admin set suspended=true
--                          while the login path kept checking is_active.
--                          => S.7's admin suspend action must toggle is_active.
-- 2. notifications.read    NOT added. notifications.is_read already exists
--                          (010:52), is written by src/utils/notify.js, and is
--                          already indexed (010:55, leading on user_id,is_read).
--                          Only `payload jsonb` is genuinely new.
-- 3. matches.winner_team   given the FK the spec omitted. fixtures.winner does
--    match_results         carry REFERENCES teams(id) three lines later in the
--    .winner_team          same spec, so its absence here was an oversight.
--                          Both stay NULLable, so a draw is still expressible.
-- 4. teams.elo /           ADDED even though elo_rating / is_public exist, and
--    teams.visibility      backfilled from them. Opposite call to (1) and (2) on
--                          purpose: teams has zero backend code (no /api/teams
--                          route), so nothing reads the legacy columns and they
--                          cannot drift. int is also the correct type for Elo,
--                          and text visibility leaves room for 'invite_only'.
--                          => treat elo_rating / is_public as legacy-unread.
--
-- ─── global_settings is NOT authoritative ───────────────────────────────────
-- The seed below includes deposit_pct = 20 and commission_pct = 0. These
-- DUPLICATE POLICY in src/utils/escrow.js, which per golden rule 3 (SRS) is the
-- source of truth for money. Nothing reads global_settings in this wave and
-- nothing should until a wave explicitly moves that authority across. Seeding
-- the row is harmless; silently making it authoritative would be a money bug.
--
-- ─── Prerequisites ──────────────────────────────────────────────────────────
-- schema.sql and migration 010 must already be applied (this migration ALTERs
-- teams, reviews, player_profiles, venues, users and notifications rather than
-- redefining them — one table, one definition). run_migration_013.js checks
-- this before applying anything and fails with an actionable message.


-- ════════════════════════════════════════════════════════════════════════════
-- 1. TEAMS — extend the existing table
-- ════════════════════════════════════════════════════════════════════════════

-- New canonical columns. `elo` supersedes the legacy DECIMAL elo_rating and
-- `visibility` supersedes the legacy boolean is_public (see deviation 4).
ALTER TABLE teams ADD COLUMN IF NOT EXISTS elo int NOT NULL DEFAULT 1000;
ALTER TABLE teams ADD COLUMN IF NOT EXISTS visibility text NOT NULL DEFAULT 'public';

-- Already present in schema.sql:213-220. Restated so a database built from
-- migrations alone still ends up correct; genuine no-ops here.
ALTER TABLE teams ADD COLUMN IF NOT EXISTS bio text;
ALTER TABLE teams ADD COLUMN IF NOT EXISTS logo_url text;
ALTER TABLE teams ADD COLUMN IF NOT EXISTS wins int DEFAULT 0,
                  ADD COLUMN IF NOT EXISTS losses int DEFAULT 0,
                  ADD COLUMN IF NOT EXISTS draws int DEFAULT 0;

-- One-time reconciliation of the legacy columns into the new ones. Each UPDATE
-- only touches rows where the new column is still at its default AND the legacy
-- column disagrees with it, which can only be true before this has run — so
-- re-running the migration is a no-op and never clobbers a live value.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'public' AND table_name = 'teams'
                AND column_name = 'elo_rating') THEN
    UPDATE teams
       SET elo = ROUND(elo_rating)::int
     WHERE elo = 1000
       AND elo_rating IS NOT NULL
       AND ROUND(elo_rating)::int <> 1000;
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'public' AND table_name = 'teams'
                AND column_name = 'is_public') THEN
    UPDATE teams
       SET visibility = 'private'
     WHERE visibility = 'public'
       AND is_public IS FALSE;
  END IF;
END $$;


-- ════════════════════════════════════════════════════════════════════════════
-- 2. TEAM MEMBERSHIP — invites and join requests
-- ════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS team_invites (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  team_id     UUID REFERENCES teams(id) ON DELETE CASCADE,
  token       text UNIQUE NOT NULL,
  created_by  UUID REFERENCES users(id),
  expires_at  timestamptz NOT NULL,
  used_by     UUID REFERENCES users(id),
  created_at  timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS team_join_requests (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  team_id     UUID REFERENCES teams(id) ON DELETE CASCADE,
  user_id     UUID REFERENCES users(id),
  status      text NOT NULL DEFAULT 'pending',  -- pending|accepted|rejected
  created_at  timestamptz DEFAULT now(),
  UNIQUE (team_id, user_id)
);


-- ════════════════════════════════════════════════════════════════════════════
-- 3. MATCHES — challenge → play → both captains report → owner verifies
-- ════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS matches (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  challenger_team      UUID REFERENCES teams(id),
  opponent_team        UUID REFERENCES teams(id),
  booking_id           UUID REFERENCES bookings(id),
  sport                text NOT NULL,
  status               text NOT NULL DEFAULT 'challenge_sent',
  -- challenge_sent|accepted|rejected|expired|awaiting_results|awaiting_owner|completed|disputed
  challenge_expires_at timestamptz,
  winner_team          UUID REFERENCES teams(id),   -- NULL = draw or not decided
  score_challenger     int,
  score_opponent       int,
  verified_by          UUID REFERENCES users(id),
  verified_at          timestamptz,
  created_at           timestamptz DEFAULT now()
);

-- One row per team's submitted scoreline. Two rows that agree → auto-confirm;
-- two that disagree → a dispute. The UNIQUE stops a captain submitting twice.
CREATE TABLE IF NOT EXISTS match_results (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  match_id           UUID REFERENCES matches(id) ON DELETE CASCADE,
  submitted_by_team  UUID REFERENCES teams(id),
  winner_team        UUID REFERENCES teams(id),     -- NULL = the submitter says draw
  score_challenger   int,
  score_opponent     int,
  created_at         timestamptz DEFAULT now(),
  UNIQUE (match_id, submitted_by_team)
);

CREATE TABLE IF NOT EXISTS disputes (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  match_id          UUID REFERENCES matches(id),
  raised_by_team    UUID REFERENCES teams(id),
  reason            text,
  status            text DEFAULT 'open',            -- open|resolved|dismissed
  resolution_notes  text,
  resolved_by       UUID REFERENCES users(id),
  created_at        timestamptz DEFAULT now()
);

-- Audit trail for every rating change, so an Elo can always be explained.
CREATE TABLE IF NOT EXISTS elo_history (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  team_id     UUID REFERENCES teams(id),
  match_id    UUID REFERENCES matches(id),
  elo_before  int,
  elo_after   int,
  created_at  timestamptz DEFAULT now()
);


-- ════════════════════════════════════════════════════════════════════════════
-- 4. REVIEWS — extend for opponent reviews + S.4 sentiment
-- ════════════════════════════════════════════════════════════════════════════

-- Postgres backfills the 'venue' default onto existing rows, which is exactly
-- right: every review that exists today is a venue review.
ALTER TABLE reviews ADD COLUMN IF NOT EXISTS review_type text DEFAULT 'venue';   -- venue|opponent
ALTER TABLE reviews ADD COLUMN IF NOT EXISTS sentiment_label text;               -- positive|neutral|negative
ALTER TABLE reviews ADD COLUMN IF NOT EXISTS sentiment_score numeric;
ALTER TABLE reviews ADD COLUMN IF NOT EXISTS flagged boolean DEFAULT false;
ALTER TABLE reviews ADD COLUMN IF NOT EXISTS hidden boolean DEFAULT false;


-- ════════════════════════════════════════════════════════════════════════════
-- 5. TRUST SCORE BREAKDOWN (S.4)
-- ════════════════════════════════════════════════════════════════════════════

-- The existing player_profiles.trust_score INT (schema.sql:39) stays as the
-- aggregate the app already shows and the no-show job already decrements
-- (src/routes/bookings.js:462, src/routes/owner.js:659). These four are the
-- per-signal components it will be composed from.
ALTER TABLE player_profiles ADD COLUMN IF NOT EXISTS trust_rating numeric,
                            ADD COLUMN IF NOT EXISTS trust_attendance numeric,
                            ADD COLUMN IF NOT EXISTS trust_disputes numeric,
                            ADD COLUMN IF NOT EXISTS trust_sentiment numeric;


-- ════════════════════════════════════════════════════════════════════════════
-- 6. TOURNAMENTS (S.7)
-- ════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS tournaments (
  id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id                UUID REFERENCES users(id),
  venue_id                UUID REFERENCES venues(id),
  name                    text NOT NULL,
  sport                   text NOT NULL,
  format                  text NOT NULL,            -- knockout|round_robin
  entry_fee               numeric DEFAULT 0,
  max_teams               int NOT NULL,
  registration_deadline   timestamptz NOT NULL,
  start_date              date,
  status                  text DEFAULT 'open',      -- open|active|completed|cancelled
  created_at              timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS tournament_teams (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tournament_id  UUID REFERENCES tournaments(id) ON DELETE CASCADE,
  team_id        UUID REFERENCES teams(id),
  status         text DEFAULT 'registered',         -- registered|withdrawn|eliminated
  created_at     timestamptz DEFAULT now(),
  UNIQUE (tournament_id, team_id)
);

-- The bracket. (round, position) locates a node; team_a/team_b are NULL until
-- the previous round resolves and feeds them.
CREATE TABLE IF NOT EXISTS fixtures (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tournament_id  UUID REFERENCES tournaments(id) ON DELETE CASCADE,
  round          int NOT NULL,
  position       int NOT NULL,
  team_a         UUID REFERENCES teams(id),
  team_b         UUID REFERENCES teams(id),
  score_a        int,
  score_b        int,
  winner         UUID REFERENCES teams(id),
  status         text DEFAULT 'upcoming',           -- upcoming|played|walkover|cancelled
  played_at      timestamptz
);


-- ════════════════════════════════════════════════════════════════════════════
-- 7. CHAT (S.7)
-- ════════════════════════════════════════════════════════════════════════════

-- ref_id is a polymorphic pointer whose meaning depends on `type`: the team id,
-- the booking id, the match id, or NULL for the assistant channel. It is UUID
-- (not int, as the spec had it) because all of those keys are UUID. It carries
-- no FK precisely because it points at different tables per row.
CREATE TABLE IF NOT EXISTS chat_channels (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  type        text NOT NULL,                        -- team|captain|booking|assistant
  ref_id      UUID,
  created_at  timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS chat_messages (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id  UUID REFERENCES chat_channels(id) ON DELETE CASCADE,
  sender_id   UUID REFERENCES users(id),
  body        text NOT NULL,
  is_system   boolean DEFAULT false,
  read_by     jsonb DEFAULT '[]',
  created_at  timestamptz DEFAULT now()
);


-- ════════════════════════════════════════════════════════════════════════════
-- 8. NOTIFICATIONS — extend, do not recreate
-- ════════════════════════════════════════════════════════════════════════════

-- The table itself is owned by migration 010:45 and is already written by
-- src/utils/notify.js. A CREATE TABLE IF NOT EXISTS here would have SILENTLY
-- SKIPPED it, leaving S.7 code to fail at runtime against columns that were
-- never added. Only the genuinely new column is added, and the read flag stays
-- is_read (deviation 2) so there is exactly one of it.
ALTER TABLE notifications ADD COLUMN IF NOT EXISTS payload jsonb;


-- ════════════════════════════════════════════════════════════════════════════
-- 9. GLOBAL SETTINGS — created and seeded, read by nothing (see header)
-- ════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS global_settings (
  key    text PRIMARY KEY,
  value  jsonb NOT NULL
);

INSERT INTO global_settings (key, value) VALUES
  ('elo',            '{"base":1000, "k_factor":32}'),
  ('commission_pct', '0'),
  ('deposit_pct',    '20'),
  ('sports_enabled', '{"football":true, "cricket":true}')
ON CONFLICT (key) DO NOTHING;


-- ════════════════════════════════════════════════════════════════════════════
-- 10. VENUES / USERS — small additions
-- ════════════════════════════════════════════════════════════════════════════

-- How far ahead a player may book this venue. Not read yet; slot generation
-- currently uses its own horizon.
ALTER TABLE venues ADD COLUMN IF NOT EXISTS booking_window_days int DEFAULT 14;

-- FCM device token for push (S.7). One per user; last login wins.
ALTER TABLE users ADD COLUMN IF NOT EXISTS fcm_token text;

-- NOTE: users.suspended is deliberately NOT added — see deviation 1 in the
-- header. users.is_active is the suspension flag and is already enforced at
-- src/routes/auth.js:164.


-- ════════════════════════════════════════════════════════════════════════════
-- 11. INDEXES
-- ════════════════════════════════════════════════════════════════════════════
--
-- Postgres does NOT auto-index foreign key columns. Six tables above use
-- ON DELETE CASCADE, so without an index on the referencing column, deleting
-- one team or tournament sequentially scans every child table.
--
-- NOT indexed here, because an existing UNIQUE constraint already provides a
-- leading-column index and a second one would only add write cost:
--   team_join_requests(team_id, …)   ← UNIQUE (team_id, user_id)
--   match_results(match_id, …)       ← UNIQUE (match_id, submitted_by_team)
--   tournament_teams(tournament_id,) ← UNIQUE (tournament_id, team_id)
--   team_invites(token)              ← UNIQUE (token)
--   notifications(user_id, is_read)  ← idx_notifications_user, from 010:55
-- Do not "fix" those gaps by adding duplicates.

-- Cascade parent with nothing else covering it.
CREATE INDEX IF NOT EXISTS idx_team_invites_team      ON team_invites (team_id);

-- "my team's matches", filtered by status, from either side of the fixture.
CREATE INDEX IF NOT EXISTS idx_matches_challenger     ON matches (challenger_team, status);
CREATE INDEX IF NOT EXISTS idx_matches_opponent       ON matches (opponent_team, status);
-- Match ← booking, for the owner's verify screen and the check-in flow.
CREATE INDEX IF NOT EXISTS idx_matches_booking        ON matches (booking_id);

CREATE INDEX IF NOT EXISTS idx_disputes_match         ON disputes (match_id);
-- The admin queue is "all disputes still open".
CREATE INDEX IF NOT EXISTS idx_disputes_status        ON disputes (status);

-- A team's rating graph, newest first.
CREATE INDEX IF NOT EXISTS idx_elo_history_team       ON elo_history (team_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_elo_history_match      ON elo_history (match_id);

-- "open tournaments still accepting registrations", and an owner's own list.
CREATE INDEX IF NOT EXISTS idx_tournaments_status     ON tournaments (status, registration_deadline);
CREATE INDEX IF NOT EXISTS idx_tournaments_venue      ON tournaments (venue_id);

-- "which tournaments is this team in" — the UNIQUE covers the other direction.
CREATE INDEX IF NOT EXISTS idx_tournament_teams_team  ON tournament_teams (team_id);

-- Bracket render: every fixture of a tournament in draw order. Also the
-- cascade index for tournament_id.
CREATE INDEX IF NOT EXISTS idx_fixtures_tournament    ON fixtures (tournament_id, round, position);

-- The hottest read in S.7: one channel's messages, newest first. Also the
-- cascade index for channel_id.
CREATE INDEX IF NOT EXISTS idx_chat_messages_channel  ON chat_messages (channel_id, created_at DESC);

-- Channel lookup by what it is attached to (team page → its team channel).
CREATE INDEX IF NOT EXISTS idx_chat_channels_ref      ON chat_channels (type, ref_id);
