const express = require('express');
const router = express.Router();
const pool = require('../db/pool');
const auth = require('../middleware/authMiddleware');
const checkRole = require('../middleware/roleMiddleware');
const { recomputeTrust } = require('../utils/trustScore');

// All admin routes require authentication + admin role
router.use(auth, checkRole('admin'));

// The four admin surfaces are separate files but the same router, mounted here and
// therefore behind the single `auth + checkRole('admin')` line above. Splitting
// them by concern keeps each one reviewable; mounting them here means a new admin
// screen cannot accidentally ship without an authorisation check, which is the
// mistake this arrangement exists to make impossible.
router.use(require('./adminUsers'));
router.use(require('./adminDisputes'));
router.use(require('./adminSettings'));
router.use(require('./reports').platformReports);

const RE_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Refresh the denormalised rating/total_reviews a venue's listing reads. Mirrors
 * the aggregate in routes/reviews.js (visible venue reviews only), so hiding or
 * restoring a review moves the star average exactly the way posting one does.
 * COALESCE keeps the columns numeric when the last visible review is hidden
 * (avg over zero rows is NULL) — the POST path never hits that, moderation can.
 */
async function refreshVenueAggregate(client, venueId) {
  if (!venueId) return;
  await client.query(
    `UPDATE venues
        SET rating = COALESCE(sub.avg_rating, 0),
            total_reviews = COALESCE(sub.n, 0)
       FROM (
         SELECT ROUND(AVG(rating)::numeric, 2) AS avg_rating, COUNT(*) AS n
           FROM reviews
          WHERE venue_id = $1 AND review_type = 'venue' AND hidden = false
       ) sub
      WHERE venues.id = $1`,
    [venueId],
  );
}

// GET /api/admin/registrations
// List all owner registration submissions, filtered by status
// Query param: ?status=pending|approved|rejected  (default: pending)
router.get('/registrations', async (req, res, next) => {
  try {
    const status = req.query.status || 'pending';
    const result = await pool.query(`
      SELECT
        op.id,
        op.user_id,
        op.verification_status,
        op.ground_name,
        op.ground_type,
        op.sport_types,
        op.city,
        op.full_address,
        op.price_per_hour,
        op.operating_hours_from,
        op.operating_hours_to,
        op.cnic_number,
        op.business_name,
        op.cnic_front_url,
        op.cnic_back_url,
        op.selfie_with_cnic_url,
        op.ground_photos,
        op.utility_bill_url,
        op.ownership_proof_url,
        op.rejection_reason,
        op.verified_at as reviewed_at,
        op.created_at,
        u.name   AS owner_name,
        u.phone  AS owner_phone,
        u.email  AS owner_email
      FROM owner_profiles op
      JOIN users u ON op.user_id = u.id
      WHERE op.verification_status = $1
      ORDER BY op.created_at DESC
    `, [status]);

    res.json({ success: true, data: result.rows });
  } catch (e) { next(e); }
});

// PATCH /api/admin/registrations/:id/approve
// Approve a pending owner registration, create their venue + 14-day slots
router.patch('/registrations/:id/approve', async (req, res, next) => {
  const client = await pool.connect();
  try {
    const { id } = req.params; // owner_profiles.id

    // Fetch the pending registration
    const opRes = await client.query(
      `SELECT op.*, u.id AS user_id, u.name AS owner_name
       FROM owner_profiles op
       JOIN users u ON op.user_id = u.id
       WHERE op.id = $1 AND op.verification_status = 'pending'`,
      [id]
    );

    if (!opRes.rows.length) {
      client.release();
      return res.status(404).json({
        success: false,
        message: 'Registration not found or already reviewed',
      });
    }

    const op = opRes.rows[0];
    await client.query('BEGIN');

    // Mark as approved
    await client.query(
      `UPDATE owner_profiles
       SET verification_status = 'approved',
           verified_at = NOW(),
           reviewed_by = $1
       WHERE id = $2`,
      [req.user.id, id]
    );

    // Derive sport_type (use first entry in sport_types array)
    const sportType =
      op.sport_types && op.sport_types.length > 0
        ? op.sport_types[0].toLowerCase()
        : 'football';

    // Create the venue
    const venueRes = await client.query(
      `INSERT INTO venues (
         owner_id, name, description, sport_type, city, address,
         base_price, price_per_hour, upfront_percent, venue_photos,
         operating_hours_from, operating_hours_to,
         is_active, rating, total_reviews
       )
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 30, $9, $10, $11, true, 0, 0)
       RETURNING id`,

      [
        op.user_id,
        op.ground_name || op.business_name || 'Venue',
        `Sports ground in ${op.city || 'Pakistan'}`,
        sportType,
        op.city || 'Islamabad',
        op.full_address || op.city || 'Pakistan',
        op.price_per_hour || 2000,
        op.price_per_hour || 2000,
        op.ground_photos || [],
        op.operating_hours_from || '06:00',
        op.operating_hours_to  || '23:00',
      ]
    );
    const venueId = venueRes.rows[0].id;

    // Generate slots for the next 14 days
    const fromH = parseInt((op.operating_hours_from || '06:00').split(':')[0], 10);
    const toH   = parseInt((op.operating_hours_to   || '22:00').split(':')[0], 10);

    for (let d = 0; d < 14; d++) {
      const slotDate = new Date();
      slotDate.setDate(slotDate.getDate() + d);
      const dateStr = slotDate.toISOString().split('T')[0];

      for (let h = fromH; h < toH; h++) {
        await client.query(
          `INSERT INTO slots (venue_id, slot_date, start_time, end_time, price, status)
           VALUES ($1, $2, $3, $4, $5, 'available')
           ON CONFLICT DO NOTHING`,
          [
            venueId,
            dateStr,
            `${h.toString().padStart(2, '0')}:00:00`,
            `${(h + 1).toString().padStart(2, '0')}:00:00`,
            op.price_per_hour || 2000,
          ]
        );
      }
    }

    await client.query('COMMIT');
    res.json({
      success: true,
      message: 'Owner approved and venue created successfully',
      data: { venueId },
    });
  } catch (e) {
    await client.query('ROLLBACK');
    next(e);
  } finally {
    client.release();
  }
});

// PATCH /api/admin/registrations/:id/reject
// Reject a pending owner registration with a reason
router.patch('/registrations/:id/reject', async (req, res, next) => {
  try {
    const { id } = req.params;
    const { reason } = req.body;

    if (!reason || reason.trim().length < 5) {
      return res.status(400).json({
        success: false,
        message: 'Rejection reason required (min 5 characters)',
      });
    }

    const result = await pool.query(
      `UPDATE owner_profiles
       SET verification_status = 'rejected',
           rejection_reason    = $1,
           verified_at         = NOW(),
           reviewed_by         = $2
       WHERE id = $3 AND verification_status = 'pending'
       RETURNING id`,
      [reason.trim(), req.user.id, id]
    );

    if (!result.rows.length) {
      return res.status(404).json({
        success: false,
        message: 'Registration not found or already reviewed',
      });
    }

    res.json({ success: true, message: 'Registration rejected' });
  } catch (e) { next(e); }
});

// GET /api/admin/stats
// Dashboard summary counts
router.get('/stats', async (req, res, next) => {
  try {
    const [pending, approved, rejected, players, venues, bookings] = await Promise.all([
      pool.query("SELECT COUNT(*) FROM owner_profiles WHERE verification_status = 'pending'"),
      pool.query("SELECT COUNT(*) FROM owner_profiles WHERE verification_status = 'approved'"),
      pool.query("SELECT COUNT(*) FROM owner_profiles WHERE verification_status = 'rejected'"),
      pool.query("SELECT COUNT(*) FROM users WHERE role = 'player'"),
      pool.query("SELECT COUNT(*) FROM venues WHERE is_active = true"),
      pool.query("SELECT COUNT(*) FROM bookings WHERE status IN ('pending', 'confirmed', 'checked_in')"),
    ]);

    res.json({
      success: true,
      data: {
        pendingRegistrations: parseInt(pending.rows[0].count, 10),
        approvedOwners:       parseInt(approved.rows[0].count, 10),
        rejectedOwners:       parseInt(rejected.rows[0].count, 10),
        totalPlayers:         parseInt(players.rows[0].count, 10),
        activeVenues:         parseInt(venues.rows[0].count, 10),
        activeBookings:       parseInt(bookings.rows[0].count, 10),
      },
    });
  } catch (e) { next(e); }
});

// GET /api/admin/venues/pending
// List venues pending approval
router.get('/venues/pending', async (req, res, next) => {
  try {
    const result = await pool.query(
      `SELECT v.id, v.name, v.sport_type, v.city, v.address, v.created_at, u.name as owner_name
       FROM venues v
       JOIN users u ON u.id = v.owner_id
       WHERE v.is_active = false
       ORDER BY v.created_at DESC`
    );
    res.json({ success: true, data: result.rows });
  } catch (e) { next(e); }
});

// PATCH /api/admin/venues/:id/approve
// Approve a pending venue
router.patch('/venues/:id/approve', async (req, res, next) => {
  try {
    const result = await pool.query(
      `UPDATE venues SET is_active = true WHERE id = $1 RETURNING id`,
      [req.params.id]
    );
    if (!result.rows.length) {
      return res.status(404).json({ success: false, message: 'Venue not found' });
    }
    res.json({ success: true, message: 'Venue approved and live' });
  } catch (e) { next(e); }
});

// GET /api/admin/reviews/flagged
// The moderation queue (FR9.9). A review needs an admin's eye for either reason:
//   • a participant reported it  → one or more open review_flags rows, or
//   • the sentiment model escalated it at creation → reviews.flagged = true with
//     no review_flags row (routes/reviews.js sets the bit directly for abuse /
//     strongly-negative text).
// So the queue is `flagged = true OR hidden = true`, not just open flags — else the
// auto-escalated abusive review the demo hinges on would never appear. Already-hidden
// reviews are included so an admin can Restore one; they sort last (actioned already).
router.get('/reviews/flagged', async (req, res, next) => {
  try {
    const { rows } = await pool.query(
      `SELECT
         r.id, r.rating AS stars, r.comment AS text, r.reviewer_name,
         r.review_type, r.reviewed_user_id, r.venue_id,
         r.sentiment_label, r.sentiment_score, r.flagged, r.hidden, r.created_at,
         ru.name AS reviewed_user_name,
         v.name  AS venue_name,
         COALESCE(fl.n, 0)            AS open_flag_count,
         COALESCE(fl.flags, '[]'::json) AS flags
       FROM reviews r
       LEFT JOIN bookings b ON b.id = r.booking_id
       LEFT JOIN venues   v ON v.id = COALESCE(r.venue_id, b.venue_id)
       LEFT JOIN users   ru ON ru.id = r.reviewed_user_id
       LEFT JOIN LATERAL (
         SELECT COUNT(*) AS n,
                json_agg(json_build_object(
                  'reason',        f.reason,
                  'flaggedByName', fu.name,
                  'createdAt',     f.created_at
                ) ORDER BY f.created_at DESC) AS flags
           FROM review_flags f
           JOIN users fu ON fu.id = f.flagged_by
          WHERE f.review_id = r.id AND f.status = 'open'
       ) fl ON true
      WHERE r.flagged = true OR r.hidden = true
      ORDER BY r.hidden ASC, r.created_at DESC`,
    );

    res.json({
      success: true,
      data: rows.map((r) => ({
        id: r.id,
        stars: r.stars,
        text: r.text,
        reviewerName: r.reviewer_name,
        reviewType: r.review_type,
        reviewedUserId: r.reviewed_user_id,
        reviewedUserName: r.reviewed_user_name,
        venueId: r.venue_id,
        venueName: r.venue_name,
        sentimentLabel: r.sentiment_label,
        sentimentScore: r.sentiment_score === null ? null : Number(r.sentiment_score),
        flagged: r.flagged,
        hidden: r.hidden,
        openFlagCount: Number(r.open_flag_count) || 0,
        // Manual reports only. An empty array + flagged=true = a model auto-escalation;
        // the client labels that "Auto-flagged by sentiment model".
        flags: r.flags || [],
        createdAt: r.created_at,
      })),
    });
  } catch (e) { next(e); }
});

// PATCH /api/admin/reviews/:id
// Act on a queued review. body { action: 'hide' | 'restore' | 'dismiss' }.
//   hide    → reject the review: hidden=true, resolve its open flags. It stops
//             counting toward the venue average / the captain's trust at once.
//   restore → un-hide a previously hidden review: hidden=false, clear the flag,
//             resolve open flags. It counts again.
//   dismiss → reject the flag, keep the review visible: flagged=false, flags
//             dismissed. Aggregates already ignore `flagged`, so no recompute.
// Everything runs in one transaction with the review row locked (golden rule 4).
router.patch('/reviews/:id', async (req, res, next) => {
  const reviewId = String(req.params.id || '').trim().toLowerCase();
  const action = String(req.body?.action || '').trim().toLowerCase();

  if (!RE_UUID.test(reviewId)) {
    return res.status(404).json({ success: false, message: 'Review not found.' });
  }
  if (!['hide', 'restore', 'dismiss'].includes(action)) {
    return res.status(400).json({
      success: false,
      message: "action must be 'hide', 'restore', or 'dismiss'.",
    });
  }

  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    const rRes = await client.query(
      `SELECT id, venue_id, reviewed_user_id, review_type, hidden, flagged
         FROM reviews WHERE id = $1 FOR UPDATE`,
      [reviewId],
    );
    if (!rRes.rows.length) {
      await client.query('ROLLBACK');
      return res.status(404).json({ success: false, message: 'Review not found.' });
    }
    const review = rRes.rows[0];

    let message;
    if (action === 'hide') {
      await client.query('UPDATE reviews SET hidden = true, flagged = true WHERE id = $1', [reviewId]);
      await client.query("UPDATE review_flags SET status = 'resolved' WHERE review_id = $1 AND status = 'open'", [reviewId]);
      message = 'Review hidden.';
    } else if (action === 'restore') {
      await client.query('UPDATE reviews SET hidden = false, flagged = false WHERE id = $1', [reviewId]);
      await client.query("UPDATE review_flags SET status = 'resolved' WHERE review_id = $1 AND status = 'open'", [reviewId]);
      message = 'Review restored.';
    } else {
      await client.query('UPDATE reviews SET flagged = false WHERE id = $1', [reviewId]);
      await client.query("UPDATE review_flags SET status = 'dismissed' WHERE review_id = $1 AND status = 'open'", [reviewId]);
      message = 'Flag dismissed; review kept.';
    }

    // hide/restore change which reviews are visible, so refresh the aggregate that
    // reads visible rows: the venue's star average, or the reviewed captain's trust.
    if (action === 'hide' || action === 'restore') {
      if (review.venue_id) {
        await refreshVenueAggregate(client, review.venue_id);
      } else if (review.reviewed_user_id) {
        await recomputeTrust(client, review.reviewed_user_id);
      }
    }

    await client.query('COMMIT');
    res.json({ success: true, message });
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    next(e);
  } finally {
    client.release();
  }
});

module.exports = router;
