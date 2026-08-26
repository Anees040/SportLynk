-- ════════════════════════════════════════════════════════════════════════════
-- 017 — S.4 Wave C: reviews moderation + Trust Score 2.0 cold-start baseline
-- ════════════════════════════════════════════════════════════════════════════
--
-- Migration 013 created the reviews columns S.4 needs (review_type, sentiment_*,
-- flagged, hidden) and the four trust_* component columns on player_profiles.
-- What 013 did NOT provide is anything to ENFORCE the review rules the Wave C
-- routes rely on, or the moderation queue the flag endpoint writes to. This
-- migration adds only that. Nothing here duplicates 013.
--
-- Why each block exists:
--
--   1. review_flags — the moderation queue (FR9.9). One row is "someone reports
--      this review". It mirrors the disputes table exactly: a status an admin
--      works through (open|resolved|dismissed) with an index on that status =
--      "the queue", recording WHO reported and WHY. It is a table and not just a
--      boolean on reviews because (a) many users can report one review and an
--      admin needs to see each report, and (b) reviews.flagged already exists as
--      the fast "is this review under a cloud" bit the read paths check — this
--      table is the ledger BEHIND that bit. ON DELETE CASCADE: a report means
--      nothing without the review it is about, so a deleted review takes its
--      reports with it.
--
--   2. ONE REVIEW PER AUTHOR PER BOOKING PER TYPE (FR9.1, "one review per
--      booking"). A JS pre-check cannot close a double-tapped Submit — two POSTs
--      both read "no review yet" and both insert — so it is a UNIQUE INDEX. The
--      key is (booking_id, reviewer_id, review_type) and NOT (booking_id,
--      reviewer_id) on purpose: a match booking lets one captain leave BOTH a
--      venue review and an opponent review (two rows, same booking, same author,
--      different type), and that is legitimate, so type is part of the key.
--
--   3. The two review read paths had no supporting index. GET
--      /venues/:id/reviews lists a venue's visible reviews newest-first and
--      paginates; GET /users/:id/reviews lists the reviews a user has RECEIVED
--      (the trust ledger), and recomputeTrust() aggregates that same set. 013
--      indexed none of it. Both indexes are partial (they skip the rows that
--      side never reads) and both carry created_at DESC so the ORDER BY is an
--      index scan, not a sort-on-read.
--
--   4. trust_score cold-start baseline. schema.sql:39 set the column DEFAULT to
--      100 — the old "everyone starts fully trusted" model. Trust Score 2.0
--      (ER2.5) composes the score from four signals, and a brand-new user has
--      none of them; the documented baseline for a zero-signal user is 50, not
--      100 (utils/trustScore.js gives each absent component a neutral 0.5 prior,
--      and 35·.5 + 30·.5 + 20·.5 + 15·.5 = 50). Registration (auth.js:53)
--      inserts player_profiles with no trust_score and so takes whatever this
--      DEFAULT is — flipping the DEFAULT is the one change that starts new users
--      at 50 without touching that code path.
--
-- DEVIATIONS / deliberate omissions
--   a. No index on review_flags(review_id), though the flag flow and the CASCADE
--      both look flags up by it. The UNIQUE (review_id, flagged_by) below leads
--      with review_id and already serves every such lookup — the same discipline
--      013 and 016 kept (never add a second index a UNIQUE already provides).
--   b. trust_score DEFAULT is changed but EXISTING rows are left as they are. A
--      migration that rewrote every live trust_score to 50 would erase real
--      earned scores; utils/trustScore.js is what moves an existing player onto
--      the 2.0 model, on their next event. A one-time backfill-all is a separate
--      opt-in script (out of scope here).
--   c. The four trust_* component columns are NOT re-added — 013:204-207 already
--      created them. This migration only changes the aggregate's DEFAULT.
--   d. review_flags.created_at is timestamptz (013/016 house style) even though
--      the legacy reviews.created_at is a naive TIMESTAMP (schema.sql:201). New
--      tables get the correct type; the legacy column is not in scope to change.
--
-- Safe to re-run: the table and indexes are IF NOT EXISTS, the CHECK is guarded
-- by a catalog lookup, and ALTER COLUMN SET DEFAULT is idempotent by nature.
-- Applied as ONE command, so Postgres wraps it in a single implicit transaction
-- and it is all-or-nothing.
-- ════════════════════════════════════════════════════════════════════════════


-- ── 1. review_flags: the moderation queue (FR9.9) ───────────────────────────

CREATE TABLE IF NOT EXISTS review_flags (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  review_id   UUID NOT NULL REFERENCES reviews(id) ON DELETE CASCADE,
  flagged_by  UUID NOT NULL REFERENCES users(id),
  reason      text,
  status      text NOT NULL DEFAULT 'open',    -- open|resolved|dismissed
  created_at  timestamptz DEFAULT now(),
  UNIQUE (review_id, flagged_by)               -- one report per user per review
);

COMMENT ON TABLE review_flags IS
  'FR9.9 moderation queue. One row = one user reporting one review. Mirrors disputes: status open|resolved|dismissed, worked through by an admin (S.7). reviews.flagged is the denormalised "under review" bit these rows back.';

-- The queue is worked as a state machine; a typo'd status would create a row no
-- admin query matches. Guarded so re-running the migration is a no-op.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_review_flags_status') THEN
    ALTER TABLE review_flags ADD CONSTRAINT chk_review_flags_status
      CHECK (status IN ('open', 'resolved', 'dismissed'));
  END IF;
END $$;

-- The admin queue is "all flags still open" — same shape as idx_disputes_status.
CREATE INDEX IF NOT EXISTS idx_review_flags_status ON review_flags (status);


-- ── 2. reviews: one review per author per booking per type (FR9.1) ──────────

CREATE UNIQUE INDEX IF NOT EXISTS ux_reviews_one_per_author
  ON reviews (booking_id, reviewer_id, review_type);


-- ── 3. reviews: the two read paths 013 left unindexed ───────────────────────

-- GET /venues/:id/reviews — a venue's visible reviews, newest first, paginated.
-- Partial: hidden reviews are never listed, and opponent reviews (venue_id NULL)
-- are not venue reviews.
CREATE INDEX IF NOT EXISTS idx_reviews_venue_visible
  ON reviews (venue_id, created_at DESC)
  WHERE venue_id IS NOT NULL AND hidden = false;

-- GET /users/:id/reviews and recomputeTrust() — the reviews a user has RECEIVED.
CREATE INDEX IF NOT EXISTS idx_reviews_reviewed_user
  ON reviews (reviewed_user_id, created_at DESC)
  WHERE reviewed_user_id IS NOT NULL;


-- ── 4. player_profiles: Trust Score 2.0 cold-start baseline (ER2.5) ─────────

ALTER TABLE player_profiles ALTER COLUMN trust_score SET DEFAULT 50;

COMMENT ON COLUMN player_profiles.trust_score IS
  'Trust Score 2.0 aggregate (ER2.5), 0..100. DEFAULT 50 = a zero-signal new user (each of the four trust_* components contributes a neutral 0.5 prior). Recomputed by utils/trustScore.js after every review / no-show / dispute event.';
