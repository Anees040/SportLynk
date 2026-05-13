const express = require('express');
const router = express.Router();
const pool = require('../db/pool');
const auth = require('../middleware/authMiddleware');
const checkRole = require('../middleware/roleMiddleware');

// All admin routes require authentication + admin role
router.use(auth, checkRole('admin'));

// ─── GET /api/admin/registrations ────────────────────────────────────────────
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

// ─── PATCH /api/admin/registrations/:id/approve ──────────────────────────────
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

// ─── PATCH /api/admin/registrations/:id/reject ───────────────────────────────
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

// ─── GET /api/admin/stats ─────────────────────────────────────────────────────
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

// ─── GET /api/admin/venues/pending ────────────────────────────────────────────
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

// ─── PATCH /api/admin/venues/:id/approve ──────────────────────────────────────
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

module.exports = router;
