-- ════════════════════════════════════════════════════════════════════════════
-- 016 — S.2 Waves B & C: ELO ledger + match lifecycle constraints
-- ════════════════════════════════════════════════════════════════════════════
--
-- Migration 013 created every TABLE the matchmaking flow needs — matches,
-- match_results, disputes, elo_history, global_settings — and 015 did the same
-- job for teams and chat. This migration adds only what turned out to be missing
-- once the ELO engine and the six match endpoints were actually written. Nothing
-- here duplicates 013 or 015.
--
-- Why each block exists:
--
--   1. matches.status is bare `text` with a DEFAULT and no CHECK. The state
--      machine in doc/API.md is the single source of truth for this column, and a
--      typo'd status ('complete' for 'completed') would not fail — it would
--      create a row that no query matches, so a played match would silently
--      vanish from every screen. A CHECK turns that into a 400 at the boundary.
--
--   2. ONE LIVE MATCH PER BOOKING. This is the invariant that matters most and
--      013 has nothing for it. A booking is one slot at one venue: two teams
--      cannot both play their match in it. Without this, a double-tapped
--      Challenge button creates two matches on one slot, and later BOTH arrive at
--      the owner's verify screen for the same 60 minutes of pitch time. A JS
--      pre-check cannot close this (two simultaneous POSTs both pass it), so it
--      is a partial UNIQUE INDEX over the live statuses only — `rejected` and
--      `expired` deliberately release the booking so it can be offered again.
--
--   3. The 48h expiry sweep (FR5.12) scans for `challenge_sent` rows whose
--      deadline has passed, every few minutes, forever. 013's indexes all lead
--      with a team id, so that sweep was a sequential scan of the whole matches
--      table. Likewise the owner's "results to verify" card looks up
--      `awaiting_owner` rows by venue and had no index at all.
--
--   4. elo_history stores before/after but not the DELTA, the K it was computed
--      with, or WHY. All three are needed: the History screen shows ±points
--      (FR5.16) and should not have to recompute them; K is tunable from
--      global_settings, so a rating computed at K=32 becomes inexplicable once an
--      admin sets K=24 unless the K is stored with the row; and a frozen
--      exchange writes before == after, which is indistinguishable from a
--      genuine no-change draw without a reason column.
--
--   5. matches has no home for the two things the flow computes at challenge
--      time — competitiveness (FR5.4) and the generated preview sentence
--      (FR5.10). Both are snapshots: they describe the teams as they were WHEN
--      CHALLENGED, so recomputing them later from current ratings would quietly
--      rewrite history on the challenge card. They must be stored, not derived.
--
--   6. elo_applied is an idempotency latch. Verification runs the rating
--      exchange; without a latch, a retried request (flaky mobile network, owner
--      double-tap) applies it twice and both teams' ratings are permanently
--      wrong with no way to tell from the data that it happened.
--
--   7. ER2.3 — a team whose dispute ratio exceeds 30% (min 3 disputes) has its
--      ELO frozen platform-wide. That state has to live on the team, and it has
--      to record WHY and WHEN or it is indistinguishable from a bug.
--
--   8. disputes lets one team file unlimited disputes on one match. Three rows
--      from the same team on the same match inflate that team's own dispute count
--      toward its own freeze threshold, and give an admin three copies of one
--      complaint to resolve.
--
-- DEVIATIONS / deliberate omissions
--   a. No index is added on match_results(match_id) — the existing
--      UNIQUE (match_id, submitted_by_team) from 013 already leads with that
--      column and serves every lookup the route makes. Same discipline as 013
--      and 015.
--   b. No CHECK on matches.sport. The column is populated from teams.sport,
--      which is already constrained, and `global_settings.sports_enabled` is the
--      intended tuning point — hard-coding the sport list in a constraint here
--      would mean a migration every time a sport is added.
--   c. `awaiting_results` is ALLOWED by chk_matches_status but is never set by
--      any route. It is in 013's documented vocabulary, and the S.2 state machine
--      simply routes `accepted` → `awaiting_owner` directly; the CHECK is a
--      typo guard, not a second copy of the spec.
--   d. teams.elo_rating (legacy DECIMAL from schema.sql) is left in place and is
--      kept in lockstep by utils/elo.js. teams.elo (int, from 013) is the
--      authority. Same treatment 013 gave elo_rating → elo and 015 gave
--      captain_id → team_members.role.
--
-- Safe to re-run: every statement is IF NOT EXISTS / guarded by a catalog
-- lookup. Applied as ONE command, so Postgres wraps it in a single implicit
-- transaction and it is all-or-nothing.
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1. matches: lifecycle columns ───────────────────────────────────────────

ALTER TABLE matches ADD COLUMN IF NOT EXISTS competitiveness INT;
ALTER TABLE matches ADD COLUMN IF NOT EXISTS preview_text    TEXT;
ALTER TABLE matches ADD COLUMN IF NOT EXISTS elo_applied     BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE matches ADD COLUMN IF NOT EXISTS results_locked  BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE matches ADD COLUMN IF NOT EXISTS created_by      UUID REFERENCES users(id);
ALTER TABLE matches ADD COLUMN IF NOT EXISTS responded_at    TIMESTAMPTZ;
ALTER TABLE matches ADD COLUMN IF NOT EXISTS updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW();

COMMENT ON COLUMN matches.competitiveness IS
  'FR5.4 snapshot at challenge time: round(100 - (min(|eloA-eloB|,400)/400)*95), 5..100. NULL when either team was Unranked (FR2.6).';
COMMENT ON COLUMN matches.preview_text IS
  'FR5.10 template-NLG preview generated at challenge time from real features. Snapshot, never recomputed. Labelled "Preview" in the UI.';
COMMENT ON COLUMN matches.elo_applied IS
  'Idempotency latch. TRUE once utils/elo.applyResult has run for this match; blocks a retried verification from applying the exchange twice.';
COMMENT ON COLUMN matches.results_locked IS
  'ER2.1 freeze. TRUE once both captains have submitted; no further match_results rows are accepted.';

-- The state machine, as a constraint. doc/API.md holds the authoritative diagram.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_matches_status') THEN
    ALTER TABLE matches ADD CONSTRAINT chk_matches_status CHECK (status IN (
      'challenge_sent', 'accepted', 'rejected', 'expired',
      'awaiting_results', 'awaiting_owner', 'completed', 'disputed'
    ));
  END IF;
END $$;

-- A team cannot challenge itself. Cheap, and it closes the one input the route
-- validates that would otherwise produce an unplayable row.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_matches_distinct_teams') THEN
    ALTER TABLE matches ADD CONSTRAINT chk_matches_distinct_teams
      CHECK (challenger_team IS DISTINCT FROM opponent_team);
  END IF;
END $$;

-- Scores are goals, not signed quantities.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_matches_scores_nonneg') THEN
    ALTER TABLE matches ADD CONSTRAINT chk_matches_scores_nonneg CHECK (
      (score_challenger IS NULL OR score_challenger >= 0) AND
      (score_opponent   IS NULL OR score_opponent   >= 0)
    );
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_matches_competitiveness') THEN
    ALTER TABLE matches ADD CONSTRAINT chk_matches_competitiveness
      CHECK (competitiveness IS NULL OR competitiveness BETWEEN 5 AND 100);
  END IF;
END $$;


-- ── 2. matches: one live match per booking ──────────────────────────────────
--
-- See note 2 in the header. `rejected` and `expired` are excluded so a declined
-- challenge hands the slot back for a fresh offer.

CREATE UNIQUE INDEX IF NOT EXISTS ux_matches_booking_live
  ON matches (booking_id)
  WHERE booking_id IS NOT NULL
    AND status IN ('challenge_sent', 'accepted', 'awaiting_results',
                   'awaiting_owner', 'completed', 'disputed');


-- ── 3. matches: the two hot lookups 013 left unindexed ──────────────────────

-- FR5.12 — the 48h expiry sweep, running every few minutes forever.
CREATE INDEX IF NOT EXISTS idx_matches_expiry
  ON matches (challenge_expires_at)
  WHERE status = 'challenge_sent';

-- The owner's "Match results to verify" card: matches → bookings → venues.
CREATE INDEX IF NOT EXISTS idx_matches_awaiting_owner
  ON matches (booking_id)
  WHERE status = 'awaiting_owner';


-- ── 4. elo_history: make a rating explainable ───────────────────────────────

ALTER TABLE elo_history ADD COLUMN IF NOT EXISTS elo_delta INT;
ALTER TABLE elo_history ADD COLUMN IF NOT EXISTS k_factor  NUMERIC(6,2);
ALTER TABLE elo_history ADD COLUMN IF NOT EXISTS reason    TEXT;

COMMENT ON COLUMN elo_history.elo_delta IS
  'elo_after - elo_before, stored so FR5.16 can show +-points without recomputing. Exactly 0 on a frozen exchange.';
COMMENT ON COLUMN elo_history.k_factor IS
  'The K this row was computed with. global_settings.elo.k_factor is tunable, so without this a past rating becomes unexplainable.';
COMMENT ON COLUMN elo_history.reason IS
  'match_verified | frozen_no_change. Distinguishes a genuine no-change draw from an ER2.3 frozen exchange, which look identical otherwise.';

-- Backfill the delta for any row written before this migration. There are none
-- in practice (nothing wrote elo_history before Wave B), but a migration that
-- leaves a NULL where the app expects a number is a migration that has to be
-- remembered, and this costs one statement.
UPDATE elo_history
   SET elo_delta = elo_after - elo_before
 WHERE elo_delta IS NULL
   AND elo_after IS NOT NULL
   AND elo_before IS NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_elo_history_reason') THEN
    ALTER TABLE elo_history ADD CONSTRAINT chk_elo_history_reason
      CHECK (reason IS NULL OR reason IN ('match_verified', 'frozen_no_change'));
  END IF;
END $$;

-- One rating row per team per match. A retried verification must not be able to
-- append a second history row even if the elo_applied latch were bypassed.
CREATE UNIQUE INDEX IF NOT EXISTS ux_elo_history_team_match
  ON elo_history (team_id, match_id)
  WHERE match_id IS NOT NULL;


-- ── 5. teams: ER2.3 platform-wide ELO freeze ────────────────────────────────

ALTER TABLE teams ADD COLUMN IF NOT EXISTS elo_frozen        BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE teams ADD COLUMN IF NOT EXISTS elo_frozen_reason TEXT;
ALTER TABLE teams ADD COLUMN IF NOT EXISTS elo_frozen_at     TIMESTAMPTZ;

COMMENT ON COLUMN teams.elo_frozen IS
  'ER2.3: TRUE when this team disputed >30%% of its matches (min 3). Freezes BOTH sides of every exchange it plays, so a frozen team cannot be farmed for points.';

-- Tiny table by comparison with matches, but the freeze check runs on every
-- verification, so the count it does is worth an index.
CREATE INDEX IF NOT EXISTS idx_teams_elo_frozen
  ON teams (id)
  WHERE elo_frozen = TRUE;


-- ── 6. disputes: one complaint per team per match ───────────────────────────

ALTER TABLE disputes ADD COLUMN IF NOT EXISTS resolved_at TIMESTAMPTZ;

CREATE UNIQUE INDEX IF NOT EXISTS ux_disputes_match_team
  ON disputes (match_id, raised_by_team);

-- ER2.3 counts disputes BY the raising team; that count runs on verification.
CREATE INDEX IF NOT EXISTS idx_disputes_raised_by
  ON disputes (raised_by_team);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_disputes_status') THEN
    ALTER TABLE disputes ADD CONSTRAINT chk_disputes_status
      CHECK (status IN ('open', 'resolved', 'dismissed'));
  END IF;
END $$;


-- ── 7. match_results: scores are goals ──────────────────────────────────────

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_match_results_scores') THEN
    ALTER TABLE match_results ADD CONSTRAINT chk_match_results_scores CHECK (
      (score_challenger IS NULL OR score_challenger >= 0) AND
      (score_opponent   IS NULL OR score_opponent   >= 0)
    );
  END IF;
END $$;


-- ── 8. global_settings: the rows Wave B actually reads ──────────────────────
--
-- 013 seeded these. Re-asserted with ON CONFLICT DO NOTHING so a database that
-- was created before 013's seed block, or had a row deleted by hand, still has
-- what utils/globalSettings.js expects. The defaults in that module are the real
-- safety net; this is belt and braces.

INSERT INTO global_settings (key, value) VALUES
  ('elo',            '{"base": 1000, "k_factor": 32}'::jsonb),
  ('match',          '{"challenge_ttl_hours": 48, "dispute_window_hours": 24, "dispute_freeze_ratio": 0.30, "dispute_freeze_min": 3}'::jsonb)
ON CONFLICT (key) DO NOTHING;
