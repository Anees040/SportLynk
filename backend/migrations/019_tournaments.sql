-- ════════════════════════════════════════════════════════════════════════════
-- 019 — TOURNAMENTS: the module 013 left as three empty tables  (S.7 Wave A)
-- ════════════════════════════════════════════════════════════════════════════
--
-- SRS Module 6 (FE-1 … FE-8) is a whole module, and since migration 013 it has
-- existed as `tournaments`, `tournament_teams` and `fixtures` with no route, no
-- service, no job and no screen. Everything 013 wrote is kept; this migration
-- adds only what the module cannot be built without.
--
-- FOUR THINGS ARE WORTH READING BEFORE THE DDL.
--
-- 1. THE ECONOMICS ARE COLUMNS, NOT A CALCULATION IN A ROUTE.
--
--    A tournament consumes the owner's sellable inventory: an 8-team knockout is
--    7 fixtures, so ~7 hours of slots that cannot be sold to anyone else. Paying
--    the organiser a PERCENTAGE of the entry-fee pool is therefore wrong, because
--    the venue cost is FIXED while the pool is VARIABLE — 8 x PKR 2,000 = 16,000
--    of fees against ~14,000 of inventory leaves a "30% commission" owner 4,800
--    richer in fees and 14,000 poorer in slots. The tournament would lose them
--    money, which inverts the entire point of this product.
--
--    So the split is a WATERFALL, and every term of it is stored:
--
--      pool_amount         = entry_fee x teams_accepted
--      venue_cost_amount   = SUM(slots.price) of the fixtures' slots,
--                            less venue_discount_percent
--      prize_amount        = (pool - venue_cost) x prize_percent
--      owner_earning_amount= venue_cost + (pool - venue_cost - prize)
--
--    The owner is made whole on inventory BEFORE anyone is paid a prize, so a
--    tournament can never be worse for them than selling the slots. The four
--    columns are stored rather than derived because a wallet statement three
--    months later must be explainable without re-running today's arithmetic
--    against tomorrow's slot prices.
--
-- 2. TEAMS PAY ONE FEE AND NEVER BOOK A TOURNAMENT SLOT.
--
--    `fixtures.slot_id` reserves a slot by flipping it to status='blocked'. It
--    does NOT create a `bookings` row, and that is deliberate three times over:
--    a booking would demand a wallet hold from a captain who has already paid an
--    entry fee (the double charge), it would appear in the owner's booking list
--    as revenue that is actually already accounted for, and — the real hazard —
--    noShowJob sweeps confirmed bookings whose slot has passed and would dock
--    every captain's trust score for a match the app itself scheduled.
--
-- 3. ONE ELO LADDER, K-FACTOR WEIGHTED BY STAKES.
--
--    A separate "tournament ELO" was considered and rejected: brackets are SEEDED
--    by ELO, so a second ladder would seed the first tournament off a field of
--    identical 1000s, and a team with three tournament matches would carry a
--    rating that measures nothing. Instead a tournament match passes a larger
--    kFactor to elo.applyResult (40 early rounds, 48 semi-final, 56 final, and 0
--    for a bye, because no game was played) — the FIDE approach, already
--    supported: `elo_history.k_factor` has recorded it per row since 016.
--
--    The four counters this migration adds to `teams` are what a screen shows
--    instead of a second number: "12 played, 8 W, 2 titles" is a fact, where a
--    parallel rating is an abstraction nobody can calibrate.
--
-- 4. tournament_teams.status: 'registered' vs 'accepted'.
--
--    013 defaults the column to 'registered'; discoveryService.listTournaments
--    has counted `status = 'accepted'` since S.6, so on today's database EVERY
--    capacity count is 0. This migration settles it: 'registered' means the row
--    exists and the fee is frozen, 'accepted' means the entry is confirmed (the
--    normal state — approval is opt-in via requires_approval). Both count toward
--    capacity, and the CHECK below pins the vocabulary so a third spelling cannot
--    quietly appear.
--
-- Prerequisites: schema.sql and migrations 010–018. Idempotent throughout —
-- every statement is ADD COLUMN IF NOT EXISTS, CREATE INDEX IF NOT EXISTS, or a
-- guarded ADD CONSTRAINT. Safe to re-run.
--
-- Run with:  node run_migration_019.js
-- The runner executes each split-marker chunk as its own command, because
-- ALTER TYPE ... ADD VALUE cannot run inside a multi-command string.
-- (The marker is the line "-- @@" + "SPLIT@@" below; never write it in prose.)


-- ════════════════════════════════════════════════════════════════════════════
-- 0. txn_type — three new values, each its own command
-- ════════════════════════════════════════════════════════════════════════════
--
-- `refund` and `escrow_release` already exist and are reused for the unwind and
-- the un-freeze. These three name the moves that have no existing equivalent:
--
--   tournament_entry      a captain's entry fee leaving their balance for escrow
--   tournament_prize      prize money moving to a winning or runner-up captain
--   tournament_commission the organiser's payout: venue-cost recovery + margin
--
-- One row per payout with the breakdown in `description`, rather than a fourth
-- value for the venue half — the tournament row already stores both terms, and
-- lib/widgets/transaction_detail_sheet.dart has to learn every value added here.

ALTER TYPE txn_type ADD VALUE IF NOT EXISTS 'tournament_entry';

-- @@SPLIT@@

ALTER TYPE txn_type ADD VALUE IF NOT EXISTS 'tournament_prize';

-- @@SPLIT@@

ALTER TYPE txn_type ADD VALUE IF NOT EXISTS 'tournament_commission';

-- @@SPLIT@@

-- ════════════════════════════════════════════════════════════════════════════
-- 0b. BACKFILL — before any CHECK, not after
-- ════════════════════════════════════════════════════════════════════════════
--
-- ORDER MATTERS HERE. Sections 1–3 add CHECK constraints to columns 013 created
-- WITHOUT one, and ALTER TABLE ... ADD CONSTRAINT validates every existing row
-- immediately. A single tournament sitting at a status this migration has not
-- heard of would therefore fail the migration ITSELF — not the app, the DDL.
--
-- The three tables are empty on this database (nothing has ever written a
-- tournament), so these are no-ops today. They are here so that they are still
-- no-ops on a branch that seeded rows first, and they run BEFORE the constraints
-- rather than in a tidy section at the end, which is where the instinct to put
-- them would have been wrong.
UPDATE tournaments      SET status = 'open'        WHERE status IS NULL;
UPDATE tournaments      SET format = 'knockout'    WHERE format IS NULL OR format NOT IN ('knockout','round_robin');
UPDATE tournament_teams SET status = 'registered'  WHERE status IS NULL;
UPDATE fixtures         SET status = 'upcoming'    WHERE status IS NULL;


-- ════════════════════════════════════════════════════════════════════════════
-- 1. TOURNAMENTS — extend the table 013 created
-- ════════════════════════════════════════════════════════════════════════════

-- ─── Configuration the organiser sets (FE-1) ────────────────────────────────
ALTER TABLE tournaments ADD COLUMN IF NOT EXISTS description text;

-- A knockout below 4 teams is a single match with a trophy attached, and the
-- deadline job cancels and refunds rather than generate one. Stored per
-- tournament so an organiser can demand 8 without editing code.
ALTER TABLE tournaments ADD COLUMN IF NOT EXISTS min_teams int NOT NULL DEFAULT 4;

-- Opt-in team approval (FE-5). FALSE means paying IS joining, which is the
-- behaviour a demo wants; TRUE holds every entry at 'registered' until the
-- organiser accepts it, and the fee stays frozen and fully refundable meanwhile.
ALTER TABLE tournaments ADD COLUMN IF NOT EXISTS requires_approval boolean NOT NULL DEFAULT false;

-- ─── The waterfall's parameters (see header note 1) ─────────────────────────
-- Percentages of the SURPLUS (pool - venue_cost), not of the pool: taking a
-- percentage of the pool is what makes the organiser poorer than selling slots.
ALTER TABLE tournaments ADD COLUMN IF NOT EXISTS prize_percent    int NOT NULL DEFAULT 60;
ALTER TABLE tournaments ADD COLUMN IF NOT EXISTS winner_percent   int NOT NULL DEFAULT 70;
ALTER TABLE tournaments ADD COLUMN IF NOT EXISTS runnerup_percent int NOT NULL DEFAULT 30;

-- The organiser's lever on the fairness question. 0 (default) recovers the slots
-- at full retail, so the tournament is never worse than selling them. An owner
-- who would rather fill dead hours than hold out for a booking can discount the
-- recovery, which lowers the entry fee the teams have to pay. It is a decision
-- about their own inventory, so it is their number, not a constant in code.
ALTER TABLE tournaments ADD COLUMN IF NOT EXISTS venue_discount_percent int NOT NULL DEFAULT 0;

-- How long one fixture occupies the ground. The scheduler turns this into a
-- number of consecutive slots, so a 90-minute cricket fixture and a 60-minute
-- futsal fixture do not need two code paths.
ALTER TABLE tournaments ADD COLUMN IF NOT EXISTS slot_minutes int NOT NULL DEFAULT 60;

-- ─── Settled amounts, written once when fixtures are generated ──────────────
ALTER TABLE tournaments ADD COLUMN IF NOT EXISTS pool_amount          numeric(10,2) NOT NULL DEFAULT 0;
ALTER TABLE tournaments ADD COLUMN IF NOT EXISTS venue_cost_amount    numeric(10,2) NOT NULL DEFAULT 0;
ALTER TABLE tournaments ADD COLUMN IF NOT EXISTS prize_amount         numeric(10,2) NOT NULL DEFAULT 0;
ALTER TABLE tournaments ADD COLUMN IF NOT EXISTS owner_earning_amount numeric(10,2) NOT NULL DEFAULT 0;

-- ─── Bracket shape and outcome ──────────────────────────────────────────────
-- `rounds` is log2(bracket size) for a knockout and the number of match-days for
-- a round-robin. Stored because the UI paints columns from it before it has
-- fixtures, and because a bracket must not change shape if a team is later
-- removed.
ALTER TABLE tournaments ADD COLUMN IF NOT EXISTS rounds int;
ALTER TABLE tournaments ADD COLUMN IF NOT EXISTS winner_team    UUID REFERENCES teams(id);
ALTER TABLE tournaments ADD COLUMN IF NOT EXISTS runner_up_team UUID REFERENCES teams(id);

-- ─── Lifecycle timestamps ───────────────────────────────────────────────────
-- fixtures_generated_at is the idempotency latch for the deadline job: it is the
-- one fact that says "the money has already moved and the bracket already
-- exists", and it is checked under FOR UPDATE before any of that happens again.
ALTER TABLE tournaments ADD COLUMN IF NOT EXISTS fixtures_generated_at timestamptz;
ALTER TABLE tournaments ADD COLUMN IF NOT EXISTS activated_at  timestamptz;
ALTER TABLE tournaments ADD COLUMN IF NOT EXISTS completed_at  timestamptz;
ALTER TABLE tournaments ADD COLUMN IF NOT EXISTS cancelled_at  timestamptz;
ALTER TABLE tournaments ADD COLUMN IF NOT EXISTS cancel_reason text;

-- ─── Constraints ────────────────────────────────────────────────────────────
-- Each ADD CONSTRAINT is guarded, because ALTER TABLE ... ADD CONSTRAINT has no
-- IF NOT EXISTS and this file must survive a re-run.

-- The vocabulary 013 documented in a comment, now enforced. `active` is the state
-- between fixture generation and the final being played.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_tournaments_status') THEN
    ALTER TABLE tournaments ADD CONSTRAINT chk_tournaments_status
      CHECK (status IN ('open','active','completed','cancelled'));
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_tournaments_format') THEN
    ALTER TABLE tournaments ADD CONSTRAINT chk_tournaments_format
      CHECK (format IN ('knockout','round_robin'));
  END IF;
END $$;

-- A knockout bracket only closes if the field is a power of two: 4, 8 or 16.
-- `x & (x-1) = 0` is that test, and 32 is the ceiling because 31 fixtures is more
-- ground time than any venue in this system has in a week.
--
-- Round-robin is capped at 6 for a REVENUE reason, not a technical one: it plays
-- n(n-1)/2 fixtures, so 8 teams is 28 hours of inventory against 8 entry fees,
-- and no sane entry fee covers that. 6 teams is 15 fixtures, which a preview can
-- still price sensibly.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_tournaments_max_teams') THEN
    ALTER TABLE tournaments ADD CONSTRAINT chk_tournaments_max_teams CHECK (
      max_teams >= 2 AND (
        (format = 'knockout'    AND max_teams <= 32 AND (max_teams & (max_teams - 1)) = 0)
        OR
        (format = 'round_robin' AND max_teams <= 6)
      )
    );
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_tournaments_min_teams') THEN
    ALTER TABLE tournaments ADD CONSTRAINT chk_tournaments_min_teams
      CHECK (min_teams >= 2 AND min_teams <= max_teams);
  END IF;
END $$;

-- The percentages. winner + runner-up must be exactly 100 or the prize pool
-- either leaks money into nothing or pays out more than was collected.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_tournaments_percents') THEN
    ALTER TABLE tournaments ADD CONSTRAINT chk_tournaments_percents CHECK (
      prize_percent BETWEEN 0 AND 100
      AND venue_discount_percent BETWEEN 0 AND 100
      AND winner_percent BETWEEN 0 AND 100
      AND runnerup_percent BETWEEN 0 AND 100
      AND winner_percent + runnerup_percent = 100
    );
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_tournaments_money_nonneg') THEN
    ALTER TABLE tournaments ADD CONSTRAINT chk_tournaments_money_nonneg CHECK (
      entry_fee >= 0 AND pool_amount >= 0 AND venue_cost_amount >= 0
      AND prize_amount >= 0 AND owner_earning_amount >= 0
      AND slot_minutes > 0
    );
  END IF;
END $$;


-- ════════════════════════════════════════════════════════════════════════════
-- 2. TOURNAMENT_TEAMS — the registration row, and what the fee did
-- ════════════════════════════════════════════════════════════════════════════

-- Seed number, 1 = strongest, assigned from `teams.elo` when fixtures are
-- generated. Stored rather than recomputed because a bracket must stay
-- explainable: a team's ELO moves as the tournament is played, so "why did the
-- 3rd seed play the 6th?" is only answerable against the ratings AT DRAW TIME.
ALTER TABLE tournament_teams ADD COLUMN IF NOT EXISTS seed int;

-- What this team actually paid. `tournaments.entry_fee` is the CURRENT price; a
-- team that registered before the organiser edited it paid the old one, and a
-- refund must return what was taken, not what is advertised now.
ALTER TABLE tournament_teams ADD COLUMN IF NOT EXISTS paid_amount numeric(10,2) NOT NULL DEFAULT 0;

ALTER TABLE tournament_teams ADD COLUMN IF NOT EXISTS approved_at  timestamptz;
ALTER TABLE tournament_teams ADD COLUMN IF NOT EXISTS withdrawn_at timestamptz;

-- Round-robin standings are recomputed from fixtures on every read, so these
-- three are a materialised convenience for the knockout side and for team cards:
-- how far a team got, and whether it is still alive.
ALTER TABLE tournament_teams ADD COLUMN IF NOT EXISTS eliminated_round int;

-- Header note 4. 'registered' = fee frozen, awaiting the organiser;
-- 'accepted' = in the tournament; 'rejected' = organiser said no, fee returned;
-- 'withdrawn' = the captain pulled out; 'eliminated' = knocked out on the pitch.
-- The first two are the states that occupy a slot in the field.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_tournament_teams_status') THEN
    ALTER TABLE tournament_teams ADD CONSTRAINT chk_tournament_teams_status
      CHECK (status IN ('registered','accepted','rejected','withdrawn','eliminated'));
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_tournament_teams_paid') THEN
    ALTER TABLE tournament_teams ADD CONSTRAINT chk_tournament_teams_paid
      CHECK (paid_amount >= 0);
  END IF;
END $$;

-- 013 already carries UNIQUE (tournament_id, team_id), which is what stops a
-- double-tapped Register button charging twice. It is asserted by the runner
-- rather than re-created here.


-- ════════════════════════════════════════════════════════════════════════════
-- 3. FIXTURES — a bracket slot that knows when and where it is played
-- ════════════════════════════════════════════════════════════════════════════

-- The link to the match state machine. A fixture with a match_id has a real
-- result flow behind it (captains submit, owner verifies, ELO applies); a fixture
-- without one is either unplayed or a bye. NULL is the normal early state.
ALTER TABLE fixtures ADD COLUMN IF NOT EXISTS match_id UUID REFERENCES matches(id);

-- The reserved ground. See header note 2: this is a reservation, not a booking.
-- ON DELETE SET NULL rather than CASCADE — losing a slot row must not silently
-- delete the fixture that was scheduled on it.
ALTER TABLE fixtures ADD COLUMN IF NOT EXISTS slot_id UUID REFERENCES slots(id) ON DELETE SET NULL;

-- Denormalised kickoff, in UTC. The bracket screen sorts and groups by it, and
-- doing that through slots for 31 fixtures is 31 joins for a header line.
ALTER TABLE fixtures ADD COLUMN IF NOT EXISTS scheduled_at timestamptz;

-- "Quarter-final", "Match 3", "Final". Computed at generation time so the label
-- cannot drift from the bracket it was generated for.
ALTER TABLE fixtures ADD COLUMN IF NOT EXISTS label text;

-- A bye is a fixture with one team, resolved the instant it is created: the top
-- seed advances because the field was not a power of two. It is a real row so
-- that the bracket has a cell to draw and `advance` has a parent to write into.
ALTER TABLE fixtures ADD COLUMN IF NOT EXISTS is_bye boolean NOT NULL DEFAULT false;

-- Where the winner goes. Derivable from (round, position), but stored so the
-- advance step is a single UPDATE against a known row instead of arithmetic that
-- has to agree with the generator's arithmetic.
ALTER TABLE fixtures ADD COLUMN IF NOT EXISTS next_round    int;
ALTER TABLE fixtures ADD COLUMN IF NOT EXISTS next_position int;

-- 013 gave `status` a DEFAULT but no CHECK, so 'plaid' would have been accepted
-- and every bracket query that tests `status = 'played'` would silently skip it.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_fixtures_status') THEN
    ALTER TABLE fixtures ADD CONSTRAINT chk_fixtures_status
      CHECK (status IN ('upcoming','played','walkover','cancelled'));
  END IF;
END $$;

-- A bracket node is (round, position) and there can only be one of it. This is
-- the constraint that makes generation SAFE TO RETRY: a second `generate` call
-- that got past the fixtures_generated_at latch hits 23505 on the first insert
-- and rolls the whole transaction back rather than drawing a doubled bracket.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'uq_fixtures_slot') THEN
    ALTER TABLE fixtures ADD CONSTRAINT uq_fixtures_slot
      UNIQUE (tournament_id, round, position);
  END IF;
END $$;

-- Rounds and positions are 1-based; a 0 or a negative would break the
-- (round, position) → next-round arithmetic in utils/fixtures.js.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_fixtures_coords') THEN
    ALTER TABLE fixtures ADD CONSTRAINT chk_fixtures_coords
      CHECK (round >= 1 AND position >= 1);
  END IF;
END $$;

-- A team cannot play itself. Cheap to state, and it catches the classic
-- off-by-one in a seeding table (pairing index i with index i).
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_fixtures_distinct_teams') THEN
    ALTER TABLE fixtures ADD CONSTRAINT chk_fixtures_distinct_teams
      CHECK (team_a IS NULL OR team_b IS NULL OR team_a <> team_b);
  END IF;
END $$;

-- A bye means exactly one team is present. Without this, `is_bye = true` with
-- two teams would auto-advance a side that never played a real opponent — the
-- single most damaging thing that can go wrong in a bracket.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_fixtures_bye') THEN
    ALTER TABLE fixtures ADD CONSTRAINT chk_fixtures_bye
      CHECK (is_bye = false OR (team_a IS NOT NULL AND team_b IS NULL));
  END IF;
END $$;

-- A played fixture must have a scoreline. `walkover` must not: nothing happened.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_fixtures_scores') THEN
    ALTER TABLE fixtures ADD CONSTRAINT chk_fixtures_scores
      CHECK (
        (status <> 'played' OR (score_a IS NOT NULL AND score_b IS NOT NULL))
        AND (score_a IS NULL OR score_a >= 0)
        AND (score_b IS NULL OR score_b >= 0)
      );
  END IF;
END $$;

-- One fixture per slot. The slot is BLOCKED while a fixture stands on it
-- (header note 2), so two fixtures pointing at the same hour would be two
-- matches on one pitch — and the second one's teams would arrive to find the
-- ground occupied. Partial so that the many NULLs (unscheduled fixtures) do not
-- collide with each other.
CREATE UNIQUE INDEX IF NOT EXISTS uq_fixtures_slot_id
  ON fixtures (slot_id) WHERE slot_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_fixtures_match      ON fixtures (match_id) WHERE match_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_fixtures_sched      ON fixtures (scheduled_at) WHERE scheduled_at IS NOT NULL;


-- ════════════════════════════════════════════════════════════════════════════
-- 4. TEAMS — the tournament record that replaces a second ELO ladder
-- ════════════════════════════════════════════════════════════════════════════

-- Header note 3. The ladder stays single and K-weighted, so "this team is strong
-- in tournaments" needs somewhere to live that is not a second rating. These
-- four counters are it, and they are ACHIEVEMENTS rather than an abstract number:
-- the team card reads "Tournament record: 12 played · 8 W · 2 titles", which is
-- both more convincing to a viva panel and impossible to misread as a rating.
--
-- They are counters, not a cache of a query, because the fixtures they summarise
-- may be from a tournament the organiser later cancels; the record of having
-- played it should not vanish.
ALTER TABLE teams ADD COLUMN IF NOT EXISTS tournament_played int NOT NULL DEFAULT 0;
ALTER TABLE teams ADD COLUMN IF NOT EXISTS tournament_wins   int NOT NULL DEFAULT 0;
ALTER TABLE teams ADD COLUMN IF NOT EXISTS finals_reached    int NOT NULL DEFAULT 0;
ALTER TABLE teams ADD COLUMN IF NOT EXISTS titles            int NOT NULL DEFAULT 0;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_teams_tournament_counters') THEN
    ALTER TABLE teams ADD CONSTRAINT chk_teams_tournament_counters
      CHECK (tournament_played >= 0 AND tournament_wins >= 0
             AND finals_reached >= 0 AND titles >= 0);
  END IF;
END $$;


-- ════════════════════════════════════════════════════════════════════════════
-- 5. MATCHES — the missing link between a bracket and the result flow
-- ════════════════════════════════════════════════════════════════════════════

-- S.2 built the whole result machine — captain submits, opponent agrees, OWNER
-- VERIFIES, ELO applies once under `matches.elo_applied` — around a booking.
-- A tournament match has no booking (header note 2), so without this column a
-- tournament result would have to be a SECOND result flow: a second dispute
-- path, a second ELO application, a second set of chat pills. That is exactly
-- the duplication FR8.15 exists to prevent.
--
-- So a tournament match is an ordinary `matches` row with `booking_id IS NULL`
-- and `tournament_id` set. Two consequences the code must honour, both of which
-- are asserted by the runner's probes and by check_tournaments.js:
--
--   a. AUTHORITY. routes/matches.js derives "may this user verify?" from
--      bookings.venue → venues.owner_id. When booking_id IS NULL it must derive
--      it from tournaments.owner_id instead. Same person in practice — the
--      organiser IS the venue owner — but a different join.
--   b. VENUE AND TIME. matchCore.MATCH_VIEW_FROM reaches the venue through the
--      booking, so a tournament match would render with a NULL ground and a NULL
--      kickoff. It COALESCEs the fixture's slot in instead.
ALTER TABLE matches ADD COLUMN IF NOT EXISTS tournament_id UUID REFERENCES tournaments(id) ON DELETE SET NULL;

-- Every match still belongs to exactly one context. A row with both a booking
-- and a tournament would make the authority question above ambiguous, and
-- ambiguity about who may confirm a result is a dispute waiting to happen.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_matches_one_context') THEN
    ALTER TABLE matches ADD CONSTRAINT chk_matches_one_context
      CHECK (booking_id IS NULL OR tournament_id IS NULL);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_matches_tournament
  ON matches (tournament_id) WHERE tournament_id IS NOT NULL;


-- ════════════════════════════════════════════════════════════════════════════
-- 6. TRANSACTIONS — so the ledger can be read per tournament
-- ════════════════════════════════════════════════════════════════════════════

-- `transactions.booking_id` is how every money question in this project is
-- currently answered: "show me the ledger for this booking". A tournament moves
-- money for up to 32 captains plus the owner across four events, none of which
-- has a booking, so without this column the entry fees, the commission and the
-- prize would be loose rows identifiable only by parsing `description` text.
--
-- With it, the audit that matters — pool in equals venue cost plus prize plus
-- margin out, to the paisa — is one GROUP BY, and check_tournaments.js asserts
-- exactly that rather than trusting the columns on the tournament row.
ALTER TABLE transactions ADD COLUMN IF NOT EXISTS tournament_id UUID REFERENCES tournaments(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_transactions_tournament
  ON transactions (tournament_id) WHERE tournament_id IS NOT NULL;


-- ════════════════════════════════════════════════════════════════════════════
-- 7. TOURNAMENTS — the one index 013 did not already provide
-- ════════════════════════════════════════════════════════════════════════════
--
-- 013:361-369 ALREADY created four tournament indexes, and they are exactly what
-- this module needs:
--
--   idx_tournaments_status     (status, registration_deadline)   the browse list
--   idx_tournaments_venue      (venue_id)                        venue history
--   idx_tournament_teams_team  (team_id)                         "my tournaments"
--   idx_fixtures_tournament    (tournament_id, round, position)  the bracket
--
-- They are NOT re-created here under new names, and that is a deliberate call
-- rather than an omission. CREATE INDEX IF NOT EXISTS matches on the NAME, never
-- on the definition, so the two obvious mistakes have opposite symptoms and both
-- are invisible until someone reads pg_indexes:
--
--   * a new name over the same columns — idx_tournaments_open (status,
--     registration_deadline) — silently BUILDS A SECOND identical index, doubling
--     the write cost of every tournament update to answer the same query;
--   * an old name over new columns — idx_tournaments_venue (venue_id, start_date)
--     — silently does NOTHING, because 013 already took that name for the
--     single-column version, and the "improvement" never exists.
--
-- The runner asserts all four are present, because 019 depends on them.
--
-- What is genuinely missing is the index for a query nothing has ever run: the
-- deadline job's candidate scan. Partial on the two facts that define a
-- candidate, so that once S.7 has been live for a while — when almost every row
-- carries a fixtures_generated_at — the sweep still reads only the handful of
-- rows it can act on, every few minutes, forever.
CREATE INDEX IF NOT EXISTS idx_tournaments_due
  ON tournaments (registration_deadline)
  WHERE status = 'open' AND fixtures_generated_at IS NULL;

-- The organiser's own list on the owner screen. 013 indexed venue_id but not
-- owner_id, and "my tournaments" is the query an organiser runs every visit.
CREATE INDEX IF NOT EXISTS idx_tournaments_owner ON tournaments (owner_id, created_at DESC);


-- ════════════════════════════════════════════════════════════════════════════
-- 8. GLOBAL SETTINGS — the tournament policy block
-- ════════════════════════════════════════════════════════════════════════════

-- utils/globalSettings.js reads this table with a DEFAULTS fallback, so the row
-- is a convenience for an admin screen rather than the authority: the code works
-- with the table empty. What it buys is a way to change the split without a
-- deploy, which is the difference between a demo and a product.
--
-- min_teams / prize_percent / winner_percent / runnerup_percent are also COLUMNS
-- on each tournament, and the columns win. This row is only the default a new
-- tournament is created with — a tournament already taking money must not have
-- its prize split changed underneath the teams that paid into it, which is
-- precisely why the values are copied onto the row at create time.
--
-- k_early / k_semi / k_final are the stake weights from header note 3. They live
-- next to elo.k_factor (32, friendlies) so the whole ladder is one place.
INSERT INTO global_settings (key, value) VALUES
  ('tournament', '{
     "min_teams": 4,
     "prize_percent": 60,
     "winner_percent": 70,
     "runnerup_percent": 30,
     "venue_discount_percent": 0,
     "slot_minutes": 60,
     "round_gap_days": 1,
     "round_rest_minutes": 60,
     "max_knockout_teams": 32,
     "max_round_robin_teams": 6,
     "target_margin_percent": 25,
     "k_early": 40,
     "k_semi": 48,
     "k_final": 56
   }')
ON CONFLICT (key) DO NOTHING;


-- ════════════════════════════════════════════════════════════════════════════
-- 9. WHAT THIS MIGRATION DELIBERATELY DOES NOT DO
-- ════════════════════════════════════════════════════════════════════════════
--
-- 1. It does not add a `bookings` row per fixture, nor a nullable
--    `bookings.tournament_id`. Header note 2 is the argument; the short version
--    is that jobs/noShowJob.js sweeps bookings and would dock the trust score of
--    every captain in the tournament for not scanning a QR code at a fixture.
--
-- 2. It does not add `teams.tournament_elo`. Header note 3 — one ladder,
--    weighted K, because brackets are SEEDED by ELO and a second ladder would
--    seed the first tournament off all-1000s.
--
-- 3. It does not touch `matches.status`, `chk_matches_status` or `elo_applied`.
--    A tournament match is an ORDINARY match; if it needed a new status the
--    claim that S.2's flow is reused would be false.
--
-- 4. It does not create a `standings` table. Round-robin standings are derived
--    from fixtures on read (3/1/0, goal difference, head-to-head) in
--    utils/fixtures.js, which means a corrected scoreline immediately corrects
--    the table with no second row to keep in step. FE-7's "refresh live
--    standings" is that derivation, not a cache.
--
-- 5. It does not drop or rename anything. 013's columns are all still there and
--    still mean what they meant.
