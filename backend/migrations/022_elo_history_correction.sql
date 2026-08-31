-- ═══════════════════════════════════════════════════════════════════════════
-- 022_elo_history_correction.sql   ·   S.7 Wave D
--
-- One index, replaced. 021 gave `elo_history.reason` two new labels for an admin
-- correction; this migration makes room for the ROWS those labels describe.
--
-- THE COLLISION, EXACTLY
-- 016 line 204 created
--
--   ux_elo_history_team_match  UNIQUE (team_id, match_id) WHERE match_id IS NOT NULL
--
-- and its runner asserts the intent in words: "one rating row per team per match".
-- That was right when the only writer was `elo.applyResult`, which writes once per
-- team and is latched a second time by `matches.elo_applied`. The index is the
-- database-level half of that guard, and applying an exchange twice is the one
-- mistake nobody can detect after the fact.
--
-- Wave D added a second writer. `elo.correctResult` reverses a rating that was
-- already applied and then applies the ruled one, and it records BOTH halves:
--
--   admin_reversal   the negative of what this match originally moved, applied to
--                    the CURRENT rating — a ledger reversal, not an edit, so
--                    matches played since the disputed one keep counting.
--   admin_ruling     the exchange computed from the admin's ruled scoreline.
--
-- Two rows per team for one match, against a unique index on exactly
-- (team_id, match_id). The second write raises 23505 and takes the whole ruling
-- transaction with it. 021 widened the CHECK so the labels were legal; nobody
-- noticed that 016's uniqueness guard forbids the rows they are for. So an
-- overturn of an already-rated match was unreachable in practice — which is
-- precisely the branch Wave D exists to deliver.
--
-- WHY THE KEY GAINS `reason` RATHER THAN LOSING UNIQUENESS
-- Dropping the index outright would buy the correction by removing the guard from
-- every path, including the ordinary verification one. Adding `reason` to the key
-- keeps every double-write that mattered impossible:
--
--   a second applyResult   → two `match_verified` rows       → still collides
--   a second correction    → two `admin_reversal` rows        → still collides
--   reversal + ruling      → two DIFFERENT reasons            → now allowed
--
-- and the arithmetic invariant survives untouched: a match's total contribution to
-- a team's rating is the sum of its rows' deltas, which for a corrected match is
-- (−old_net) + ruled_delta — exactly one exchange, the ruled one. `SELECT * FROM
-- elo_history WHERE match_id = …` still reads as the whole story, in order.
--
-- COALESCE(reason, 'unspecified') IS DELIBERATE
-- `reason` is nullable (the CHECK reads `reason IS NULL OR reason IN (…)`), and in
-- a unique index NULL never equals NULL — so a bare three-column key would let two
-- reason-less rows through for the same team and match, re-opening the exact hole
-- this index exists to close. Folding NULL to a value closes it. There are 0 such
-- rows today; the guard is for the writer that forgets a reason tomorrow.
--
-- WHY 016 IS NOT EDITED
-- 016 is applied everywhere. Rewriting it would give the next person who runs the
-- chain from scratch a different 016 than this database has, and the difference
-- would be invisible until something failed. 016 creates the old index, 022 drops
-- it — in that order, the chain converges on the same schema either way.
--
-- NO SPLIT MARKER. Both statements are DDL on a two-row table and belong in ONE
-- transaction: the moment between "guard dropped" and "guard created" must not be
-- observable, and nothing here has to commit before the probes can use it.

-- ─── 1. Retire 016's two-column guard ──────────────────────────────────────
-- Guarded rather than `DROP INDEX IF EXISTS` only for the log line: a re-run
-- should say nothing was there rather than look like it removed something.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_indexes
     WHERE schemaname = 'public' AND indexname = 'ux_elo_history_team_match'
  ) THEN
    DROP INDEX public.ux_elo_history_team_match;
    RAISE NOTICE '022: dropped ux_elo_history_team_match (superseded)';
  ELSE
    RAISE NOTICE '022: ux_elo_history_team_match already absent';
  END IF;
END $$;

-- ─── 2. The successor ──────────────────────────────────────────────────────
-- Same table, same partial predicate, one more key column. If this raises 23505
-- the database already holds two rows with the same (team, match, reason) — which
-- would be a genuine double-application, and stopping the migration to look at it
-- is the correct outcome, not something to code around.
CREATE UNIQUE INDEX IF NOT EXISTS ux_elo_history_team_match_reason
  ON elo_history (team_id, match_id, COALESCE(reason, 'unspecified'))
  WHERE match_id IS NOT NULL;

COMMENT ON INDEX ux_elo_history_team_match_reason IS
  'One rating row per team per match PER REASON: a second verification still '
  'collides, while a correction''s reversal+ruling pair (021 labels) is allowed. '
  'Supersedes ux_elo_history_team_match from 016.';
