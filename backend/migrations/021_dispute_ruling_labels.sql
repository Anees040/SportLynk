-- ═══════════════════════════════════════════════════════════════════════════
-- 021_dispute_ruling_labels.sql   ·   S.7 Wave D
--
-- Two label vocabularies that Wave D writes into and that 020 could not widen,
-- because both are enforced by objects a plain ADD COLUMN cannot touch: a CHECK
-- constraint and an enum type.
--
-- WHY THIS IS A SEPARATE MIGRATION AND NOT PART OF 020
-- 020 is applied. Editing an applied migration rewrites history: the next person
-- to run the chain from scratch would get a different 020 than the one this
-- database has, and the difference would be invisible until something failed.
--
-- WHY IT NEEDS THE SPLIT MARKER (019's precedent)
-- `ALTER TYPE ... ADD VALUE` may run inside a transaction on PG 12+, but the new
-- label CANNOT BE USED until that transaction commits. The runner's probe inserts
-- a `platform_commission` row to prove the label works, so the ALTER has to be in
-- a chunk of its own that commits first. Everything before the marker is one
-- atomic chunk; the ALTER is the second.
--
-- ─── 1. elo_history.reason — two labels for an admin correction ─────────────
--
-- `chk_elo_history_reason` allows only 'match_verified' and 'frozen_no_change'.
-- Wave D's dispute ruling needs two more, and the reason it needs them is the
-- one case the dispute route explicitly left to S.7:
--
--   POST /api/matches/:id/dispute can be filed against a COMPLETED match, whose
--   ELO has ALREADY been applied. Its own comment says "the rating stands until
--   an admin resolves it (S.7) — silently reversing a verified result would move
--   two ratings with no audit row explaining why".
--
-- The operative word is SILENTLY. An admin ruling that flips the winner MUST move
-- those ratings, or `matches.winner_team` and `teams.elo` end up contradicting
-- each other permanently. So the ruling reverses the original exchange and applies
-- the ruled one, and both halves are written to elo_history as their own rows:
--
--   admin_reversal  — elo_delta is the NEGATIVE of the original row's delta,
--                     applied to the CURRENT rating (a ledger reversal, not an
--                     edit): matches played since the disputed one keep counting.
--   admin_ruling    — the exchange computed from the admin's ruled scoreline.
--
-- Four rows, two per team, and `SELECT * FROM elo_history WHERE match_id = …`
-- reads as the whole story in order. That is the property the freeze comment was
-- protecting, and it is preserved rather than traded away.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'public.elo_history'::regclass
       AND conname  = 'chk_elo_history_reason'
  ) THEN
    ALTER TABLE elo_history DROP CONSTRAINT chk_elo_history_reason;
  END IF;

  ALTER TABLE elo_history
    ADD CONSTRAINT chk_elo_history_reason
    CHECK (
      reason IS NULL OR reason IN (
        'match_verified',    -- the owner (or organiser) verified the result
        'frozen_no_change',  -- one side's rating is frozen; the row records the zero
        'admin_reversal',    -- S.7 Wave D: an admin ruling undid this application
        'admin_ruling'       -- S.7 Wave D: the exchange the admin's ruling produced
      )
    );
END $$;
-- @@SPLIT@@
-- ─── 2. txn_type += 'platform_commission' ──────────────────────────────────
--
-- Migration 013 seeded `global_settings.commission.commission_pct` and then
-- deliberately left it authoritative over NOTHING, with a warning: making it
-- authoritative over money "silently" would be a money bug. Wave D is the wave
-- that moves that authority across, explicitly and with a ledger row of its own —
-- so `transactions.type` needs a label for it. Today the only commission in the
-- enum is `tournament_commission`, which is the VENUE OWNER's margin on entry
-- fees, a different party and a different direction of money.
--
-- The platform's cut of a booking is deducted from the owner's credit at QR
-- check-in, where the escrow is already released under a `FOR UPDATE` lock, and
-- it writes one `platform_commission` row so the owner's statement adds up.
-- `commission_pct` defaults to 0, so applying this migration changes no number
-- anywhere until an admin sets it — the transfer of authority is what ships, not
-- a rate.
--
-- IF NOT EXISTS makes this re-runnable (PG 10+).
ALTER TYPE txn_type ADD VALUE IF NOT EXISTS 'platform_commission';
