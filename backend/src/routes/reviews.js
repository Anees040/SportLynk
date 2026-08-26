/**
 * Reviews API (S.4 Wave C) — the first code that ever WRITES the reviews table.
 *
 * FOUR ENDPOINTS, ONE FEATURE FILE
 *   POST /api/reviews                 leave a venue or opponent review        (FR9.1)
 *   GET  /api/venues/:id/reviews      a venue's reviews + rating/sentiment    (FR9.x)
 *   GET  /api/users/:id/reviews       reviews a user RECEIVED + trust ledger  (ER2.5)
 *   POST /api/reviews/:id/flag        report a review to moderation           (FR9.9)
 *
 * The two GETs are addressed under /api/venues and /api/users, not /api/reviews,
 * so this router is mounted at the bare `/api` root (see server.js) and every
 * handler declares `auth` explicitly rather than the file using `router.use(auth)`.
 * A router-level guard at `/api` would run on EVERY /api request that fell through
 * to this mount — including /api/auth/login — and 401 it. Per-route auth keeps the
 * guard on exactly the four paths below, and matches routes/bookings.js's style.
 *
 * TWO REVIEW SHAPES, DECIDED IN THE PLAN
 *   venue:    reviewer = the booker, gated on booking.status = 'checked_in' (they
 *             actually turned up). Target is the venue; reviewed_user_id is NULL.
 *   opponent: CAPTAIN-TO-CAPTAIN. Only a role='captain' member of one of the match's
 *             two teams may file it, and the target reviewed_user_id is DERIVED as
 *             the opposing team's representative captain — never taken from the body.
 *             A match has ~11 players a side but reviews.reviewed_user_id is one user,
 *             and the captain is the team's single representative (utils/trustScore).
 *
 * WHY SENTIMENT IS SCORED BEFORE THE TRANSACTION OPENS
 *   Scoring a review's text is a ≤2s network call to the ml-service. Making it while
 *   holding a `FOR UPDATE` lock on the booking row would pin that lock for the whole
 *   round-trip. So the flow is: authorise + derive the target with an UNLOCKED read
 *   (which also means an unauthorised request never reaches the ml-service), THEN
 *   score, THEN open the transaction, re-resolve under the lock, and insert. If the
 *   model is unavailable the review still saves with sentiment_label NULL — the
 *   honest "not scored yet" state — and jobs/sentimentBackfillJob.js fills it in
 *   later. Nothing here invents a label; that is mlClient's no-heuristic contract.
 *
 * WHY reviews.flagged IS A UNION
 *   `flagged` means "a human should look at this", for EITHER reason: the sentiment
 *   model escalated it (needsReview — abuse or strongly negative) at creation, or a
 *   participant reported it via /flag. The review_flags table records the manual
 *   reports specifically (who/why, an admin queue mirroring `disputes`); an
 *   auto-escalation sets `flagged` without a review_flags row. See migration 017.
 *
 * ENVELOPE + ERRORS follow routes/matches.js exactly: { success, message } / { success,
 * data }, friendlyDbError keyed on the constraint NAME, and never a raw SQL string on
 * the wire (golden rule 5).
 */

const express = require('express');
const pool = require('../db/pool');
const auth = require('../middleware/authMiddleware');
const ml = require('../services/mlClient');
const { recomputeTrust, representativeCaptain } = require('../utils/trustScore');

const router = express.Router();

// ─── Envelope helpers (same shape as routes/matches.js) ─────────────────────
const fail = (res, status, message) => res.status(status).json({ success: false, message });
const ok = (res, data, message) => res.json({ success: true, data, ...(message ? { message } : {}) });

/** Roll back, then answer — the only safe way to leave an open transaction. */
async function bail(client, res, status, message) {
  await client.query('ROLLBACK').catch(() => {});
  return fail(res, status, message);
}

/**
 * DB errors this flow can legitimately produce, turned into friendly envelopes.
 * Keyed on the constraint NAME: two different unique violations reach here and
 * "already exists" answers neither well. Anything unrecognised returns null and
 * goes to next(e) → a generic 500, never a raw SQL string (golden rule 5).
 */
function friendlyDbError(e) {
  if (e.code === '23505') {
    switch (e.constraint) {
      case 'ux_reviews_one_per_author':
        return { status: 409, message: 'You have already left this review.' };
      case 'review_flags_review_id_flagged_by_key':
        return { status: 409, message: 'You have already reported this review.' };
      default:
        return { status: 409, message: 'That has already been recorded.' };
    }
  }
  if (e.code === '23514') return { status: 400, message: 'That is not a valid review.' };
  if (e.code === '23503') return { status: 404, message: 'That booking or user no longer exists.' };
  if (e.code === '22P02') return { status: 404, message: 'Not found.' }; // malformed uuid
  return null;
}

// ─── Small parsers / normalisers ────────────────────────────────────────────

const RE_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const uuid = (v) => String(v ?? '').trim().toLowerCase();
const isUuid = (v) => RE_UUID.test(uuid(v));

/** numeric-string | null → number | null. pg hands back numeric/bigint as strings. */
const num = (v) => (v === null || v === undefined ? null : Number(v));

const REVIEW_TYPES = ['venue', 'opponent'];

/** Longest review body we accept. Comfortably under the ml-service's 4,000-char cap. */
const REVIEW_TEXT_MAX = 2000;
/** A flag reason is a short note for a moderator, not an essay. */
const FLAG_REASON_MAX = 500;

const RE_INT = /^\d+$/;

/**
 * Stars, 1–5. Regex not parseInt: parseInt('4abc') is 4 and parseInt('4.7') is 4,
 * both of which would silently accept a client bug — the same reasoning as
 * matches.js parseScore.
 */
function parseStars(raw) {
  if (raw === undefined || raw === null || raw === '') {
    return { ok: false, message: 'A star rating from 1 to 5 is required.' };
  }
  const s = typeof raw === 'number' ? String(raw) : String(raw).trim();
  if (!RE_INT.test(s)) return { ok: false, message: 'stars must be a whole number from 1 to 5.' };
  const n = Number.parseInt(s, 10);
  if (n < 1 || n > 5) return { ok: false, message: 'stars must be from 1 to 5.' };
  return { ok: true, value: n };
}

/** Optional review body. Empty/whitespace collapses to null (no text, not an error). */
function parseText(raw) {
  if (raw === undefined || raw === null) return { ok: true, value: null };
  if (typeof raw !== 'string') return { ok: false, message: 'text must be a string.' };
  const t = raw.trim();
  if (t === '') return { ok: true, value: null };
  if (t.length > REVIEW_TEXT_MAX) {
    return { ok: false, message: `Please keep your review under ${REVIEW_TEXT_MAX} characters.` };
  }
  return { ok: true, value: t };
}

function parseReason(raw) {
  if (raw === undefined || raw === null) return { ok: true, value: null };
  if (typeof raw !== 'string') return { ok: false, message: 'reason must be a string.' };
  const t = raw.trim();
  if (t === '') return { ok: true, value: null };
  if (t.length > FLAG_REASON_MAX) {
    return { ok: false, message: `Please keep the reason under ${FLAG_REASON_MAX} characters.` };
  }
  return { ok: true, value: t };
}

/** Standard page/limit parse, clamped so a client can't ask for the whole table. */
function pageParams(q) {
  let limit = Number.parseInt(q.limit, 10);
  if (!Number.isInteger(limit) || limit < 1) limit = 20;
  if (limit > 50) limit = 50;
  let page = Number.parseInt(q.page, 10);
  if (!Number.isInteger(page) || page < 1) page = 1;
  return { page, limit, offset: (page - 1) * limit };
}

async function nameOf(db, userId) {
  if (!userId) return null;
  const { rows } = await db.query('SELECT name FROM users WHERE id = $1', [userId]);
  return rows[0]?.name || null;
}

/**
 * Authorise the caller for this review and DERIVE its target, using whichever pg
 * runner is passed (pool for the unlocked pre-flight, the txn client — with
 * lock:true — for the authoritative re-check). One function so the pre-flight and
 * the in-transaction check can never drift apart.
 *
 * Returns { ok:true, booking, match?, reviewedUserId, venueId } or
 *         { ok:false, status, message }.
 */
async function resolveReviewContext(db, { bookingId, reviewType, callerId, lock = false }) {
  const bRes = await db.query(
    `SELECT b.id, b.player_id, b.venue_id, b.status, v.owner_id
       FROM bookings b
       JOIN venues v ON v.id = b.venue_id
      WHERE b.id = $1
      ${lock ? 'FOR UPDATE OF b' : ''}`,
    [bookingId],
  );
  if (!bRes.rows.length) return { ok: false, status: 404, message: 'Booking not found.' };
  const booking = bRes.rows[0];

  if (reviewType === 'venue') {
    if (booking.player_id !== callerId) {
      return { ok: false, status: 403, message: 'You can only review a venue you booked.' };
    }
    // 'checked_in' is the attended state — there is no 'completed' booking status.
    if (booking.status !== 'checked_in') {
      return {
        ok: false,
        status: 400,
        message: 'You can review this venue once your booking is checked in.',
      };
    }
    return { ok: true, booking, reviewedUserId: null, venueId: booking.venue_id };
  }

  // opponent — captain-to-captain, target derived (never from the body)
  const mRes = await db.query(
    `SELECT id, challenger_team, opponent_team, status
       FROM matches
      WHERE booking_id = $1 AND status = 'completed'
      ORDER BY created_at DESC
      LIMIT 1`,
    [bookingId],
  );
  if (!mRes.rows.length) {
    return { ok: false, status: 400, message: 'This booking has no completed match to review.' };
  }
  const match = mRes.rows[0];

  const memRes = await db.query(
    `SELECT team_id, role FROM team_members
      WHERE user_id = $1 AND team_id IN ($2, $3)`,
    [callerId, match.challenger_team, match.opponent_team],
  );
  if (!memRes.rows.length) {
    return { ok: false, status: 403, message: 'You did not take part in this match.' };
  }
  const captainRow = memRes.rows.find((r) => r.role === 'captain');
  if (!captainRow) {
    return {
      ok: false,
      status: 403,
      message: "Only your team's captain can review the opposing team.",
    };
  }

  const callerTeam = captainRow.team_id;
  const otherTeam =
    callerTeam === match.challenger_team ? match.opponent_team : match.challenger_team;
  const reviewedUserId = await representativeCaptain(db, otherTeam);
  if (!reviewedUserId) {
    return {
      ok: false,
      status: 409,
      message: 'The opposing team has no captain set, so there is nobody to review.',
    };
  }
  if (reviewedUserId === callerId) {
    return { ok: false, status: 400, message: 'You cannot review yourself.' };
  }
  return { ok: true, booking, match, reviewedUserId, venueId: null };
}

// ═══════════════════════════════════════════════════════════════════════════
// POST /api/reviews — leave a venue or opponent review
// ═══════════════════════════════════════════════════════════════════════════

router.post('/reviews', auth, async (req, res, next) => {
  const bookingId = uuid(req.body.booking_id ?? req.body.bookingId);
  const reviewType = String(req.body.review_type ?? req.body.reviewType ?? '')
    .trim()
    .toLowerCase();
  const stars = parseStars(req.body.stars ?? req.body.rating);
  const parsedText = parseText(req.body.text ?? req.body.comment);
  const callerId = req.user.id;

  if (!isUuid(bookingId)) return fail(res, 400, 'A valid booking_id is required.');
  if (!REVIEW_TYPES.includes(reviewType)) {
    return fail(res, 400, "review_type must be 'venue' or 'opponent'.");
  }
  if (!stars.ok) return fail(res, 400, stars.message);
  if (!parsedText.ok) return fail(res, 400, parsedText.message);
  const text = parsedText.value;

  // 1) Authorise + derive target with an UNLOCKED read. An unauthorised request
  //    returns here and never reaches the ml-service.
  const pre = await resolveReviewContext(pool, { bookingId, reviewType, callerId });
  if (!pre.ok) return fail(res, pre.status, pre.message);

  // 2) Score sentiment BEFORE the transaction — no lock is held during the ≤2s call.
  //    Unavailable → nulls stored; the backfill job fills them in later.
  const sentiment = text ? await ml.analyzeSentiment(text) : null;
  const label = sentiment && sentiment.available ? sentiment.label : null;
  const score = sentiment && sentiment.available ? sentiment.score : null;
  const flagged = Boolean(sentiment && sentiment.available && sentiment.flagged);

  const reviewerName = await nameOf(pool, callerId);

  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    // 3) Re-resolve under a row lock — closes the window between the pre-flight read
    //    and the insert (e.g. the booking's status changing, or the captaincy moving).
    const ctx = await resolveReviewContext(client, {
      bookingId,
      reviewType,
      callerId,
      lock: true,
    });
    if (!ctx.ok) return bail(client, res, ctx.status, ctx.message);

    const ins = await client.query(
      `INSERT INTO reviews
         (booking_id, reviewer_id, reviewed_user_id, venue_id, rating, comment,
          reviewer_name, review_type, sentiment_label, sentiment_score, flagged)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
       RETURNING id, created_at`,
      [
        bookingId,
        callerId,
        ctx.reviewedUserId,
        ctx.venueId,
        stars.value,
        text,
        reviewerName,
        reviewType,
        label,
        score,
        flagged,
      ],
    );
    const review = ins.rows[0];

    if (reviewType === 'venue') {
      // Refresh the denormalised aggregate the listings already read (player.js,
      // venues.js). Averaged over VISIBLE venue reviews only, so a hidden review
      // stops counting the moment it is hidden.
      await client.query(
        `UPDATE venues
            SET rating = sub.avg_rating,
                total_reviews = sub.n
           FROM (
             SELECT ROUND(AVG(rating)::numeric, 2) AS avg_rating, COUNT(*) AS n
               FROM reviews
              WHERE venue_id = $1 AND review_type = 'venue' AND hidden = false
           ) sub
          WHERE venues.id = $1`,
        [ctx.venueId],
      );
    } else {
      // An opponent review changes the target captain's rating and sentiment inputs,
      // so recompute their Trust Score inside the same transaction (ER2.5).
      await recomputeTrust(client, ctx.reviewedUserId);
    }

    await client.query('COMMIT');

    return res.status(201).json({
      success: true,
      message: 'Review posted.',
      data: {
        id: review.id,
        bookingId,
        reviewType,
        stars: stars.value,
        text,
        reviewedUserId: ctx.reviewedUserId,
        venueId: ctx.venueId,
        // The moderation verdict, so the client can show "flagged for review" without
        // a second call. source is 'model' | 'unavailable' | null (no text scored).
        sentiment: {
          label,
          score,
          flagged,
          source: sentiment ? sentiment.source : null,
        },
        createdAt: review.created_at,
      },
    });
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    const f = friendlyDbError(e);
    if (f) return fail(res, f.status, f.message);
    return next(e);
  } finally {
    client.release();
  }
});

// ═══════════════════════════════════════════════════════════════════════════
// GET /api/venues/:id/reviews — a venue's visible reviews + aggregates
// ═══════════════════════════════════════════════════════════════════════════

router.get('/venues/:id/reviews', auth, async (req, res, next) => {
  try {
    const venueId = uuid(req.params.id);
    if (!isUuid(venueId)) return fail(res, 404, 'Venue not found.');

    const exists = await pool.query('SELECT 1 FROM venues WHERE id = $1', [venueId]);
    if (!exists.rows.length) return fail(res, 404, 'Venue not found.');

    const { page, limit, offset } = pageParams(req.query);

    // Aggregates over ALL visible venue reviews (not just this page). The sentiment
    // distribution counts canonical labels only — a NULL (unscored) label is not a
    // fourth bucket, it is simply absent from all three.
    const aggRes = await pool.query(
      `SELECT
         COUNT(*)                                              AS total,
         ROUND(AVG(rating)::numeric, 2)                        AS avg_stars,
         COUNT(*) FILTER (WHERE sentiment_label = 'positive')  AS positive,
         COUNT(*) FILTER (WHERE sentiment_label = 'neutral')   AS neutral,
         COUNT(*) FILTER (WHERE sentiment_label = 'negative')  AS negative
       FROM reviews
      WHERE venue_id = $1 AND review_type = 'venue' AND hidden = false`,
      [venueId],
    );
    const agg = aggRes.rows[0];

    const rowsRes = await pool.query(
      `SELECT id, rating AS stars, comment AS text, reviewer_name,
              sentiment_label, created_at
         FROM reviews
        WHERE venue_id = $1 AND review_type = 'venue' AND hidden = false
        ORDER BY created_at DESC
        LIMIT $2 OFFSET $3`,
      [venueId, limit, offset],
    );

    return ok(res, {
      venueId,
      page,
      limit,
      total: num(agg.total) || 0,
      avgStars: agg.avg_stars === null ? null : num(agg.avg_stars),
      sentimentDistribution: {
        positive: num(agg.positive) || 0,
        neutral: num(agg.neutral) || 0,
        negative: num(agg.negative) || 0,
      },
      reviews: rowsRes.rows.map((r) => ({
        id: r.id,
        stars: r.stars,
        text: r.text,
        reviewerName: r.reviewer_name,
        sentimentLabel: r.sentiment_label,
        createdAt: r.created_at,
      })),
    });
  } catch (e) {
    const f = friendlyDbError(e);
    if (f) return fail(res, f.status, f.message);
    return next(e);
  }
});

// ═══════════════════════════════════════════════════════════════════════════
// GET /api/users/:id/reviews — reviews a user RECEIVED + their trust ledger
// ═══════════════════════════════════════════════════════════════════════════

router.get('/users/:id/reviews', auth, async (req, res, next) => {
  try {
    const userId = uuid(req.params.id);
    if (!isUuid(userId)) return fail(res, 404, 'User not found.');

    const exists = await pool.query('SELECT 1 FROM users WHERE id = $1', [userId]);
    if (!exists.rows.length) return fail(res, 404, 'User not found.');

    const { page, limit, offset } = pageParams(req.query);

    const aggRes = await pool.query(
      `SELECT COUNT(*) AS total, ROUND(AVG(rating)::numeric, 2) AS avg_stars
         FROM reviews
        WHERE reviewed_user_id = $1 AND hidden = false`,
      [userId],
    );
    const agg = aggRes.rows[0];

    // The stored Trust Score 2.0 breakdown (ER2.5). Each component is NULL until the
    // user has a signal of that kind — the client renders NULL as "no data yet",
    // never as a zero.
    const trustRes = await pool.query(
      `SELECT trust_score, trust_rating, trust_attendance, trust_disputes, trust_sentiment
         FROM player_profiles
        WHERE user_id = $1`,
      [userId],
    );
    const t = trustRes.rows[0] || {};

    const rowsRes = await pool.query(
      `SELECT id, rating AS stars, comment AS text, reviewer_name,
              review_type, sentiment_label, created_at
         FROM reviews
        WHERE reviewed_user_id = $1 AND hidden = false
        ORDER BY created_at DESC
        LIMIT $2 OFFSET $3`,
      [userId, limit, offset],
    );

    return ok(res, {
      userId,
      page,
      limit,
      total: num(agg.total) || 0,
      avgStars: agg.avg_stars === null ? null : num(agg.avg_stars),
      trust: {
        score: t.trust_score ?? null,
        rating: num(t.trust_rating),
        attendance: num(t.trust_attendance),
        disputes: num(t.trust_disputes),
        sentiment: num(t.trust_sentiment),
      },
      reviews: rowsRes.rows.map((r) => ({
        id: r.id,
        stars: r.stars,
        text: r.text,
        reviewerName: r.reviewer_name,
        reviewType: r.review_type,
        sentimentLabel: r.sentiment_label,
        createdAt: r.created_at,
      })),
    });
  } catch (e) {
    const f = friendlyDbError(e);
    if (f) return fail(res, f.status, f.message);
    return next(e);
  }
});

// ═══════════════════════════════════════════════════════════════════════════
// POST /api/reviews/:id/flag — report a review to moderation (FR9.9)
// ═══════════════════════════════════════════════════════════════════════════

router.post('/reviews/:id/flag', auth, async (req, res, next) => {
  const reviewId = uuid(req.params.id);
  const callerId = req.user.id;
  const reason = parseReason(req.body?.reason);

  if (!isUuid(reviewId)) return fail(res, 404, 'Review not found.');
  if (!reason.ok) return fail(res, 400, reason.message);

  // Participant test: the reviewer, the reviewed user, the booker, the venue owner,
  // or any member of either team in the match on that booking may report it. Anyone
  // else has no standing to flag a conversation they were not part of.
  const who = await pool.query(
    `SELECT
        r.id,
        (r.reviewer_id = $2
          OR r.reviewed_user_id = $2
          OR b.player_id = $2
          OR v.owner_id = $2
          OR EXISTS (
            SELECT 1
              FROM matches m
              JOIN team_members tm
                ON tm.team_id IN (m.challenger_team, m.opponent_team)
             WHERE m.booking_id = b.id AND tm.user_id = $2
          )) AS is_participant
       FROM reviews r
       LEFT JOIN bookings b ON b.id = r.booking_id
       LEFT JOIN venues   v ON v.id = COALESCE(r.venue_id, b.venue_id)
      WHERE r.id = $1`,
    [reviewId, callerId],
  );
  if (!who.rows.length) return fail(res, 404, 'Review not found.');
  if (!who.rows[0].is_participant) {
    return fail(res, 403, 'You can only report a review from a booking or match you took part in.');
  }

  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query(
      `INSERT INTO review_flags (review_id, flagged_by, reason) VALUES ($1, $2, $3)`,
      [reviewId, callerId, reason.value],
    );
    // Union flag: put the review into the moderation queue regardless of why.
    await client.query(`UPDATE reviews SET flagged = true WHERE id = $1`, [reviewId]);
    await client.query('COMMIT');

    return ok(res, { reviewId, status: 'open' }, 'Review reported to moderators.');
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    const f = friendlyDbError(e);
    if (f) return fail(res, f.status, f.message);
    return next(e);
  } finally {
    client.release();
  }
});

module.exports = router;
