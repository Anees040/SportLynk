const express = require('express');
const crypto = require('crypto');
const pool = require('../db/pool');
const router = express.Router();

// This export streams every player's full booking history, so it gets its own
// dedicated secret — deliberately not ML_API_KEY. doc/claude.md records ML_API_KEY's
// dev value as pasted in cleartext and pending rotation; reusing it here
// would widen that known-exposed key's blast radius into read access to all bookings.
// Keep them separate.
const MIN_KEY_LEN = 16;

function exportKey(req, res, next) {
  const expected = (process.env.RECO_EXPORT_API_KEY || '').trim();
  // FAIL closed. An unset or too-short key disables the endpoint (503) rather than
  // leaving it open — it must never fail open. 503, not 401, because "the server
  // isn't configured for this" is the honest reason, distinct from "you sent a bad key".
  if (expected.length < MIN_KEY_LEN) {
    return res.status(503).json({ success: false, message: 'Export endpoint is not configured', code: 'export_not_configured' });
  }
  const supplied = req.get('X-Reco-Export-Key') || '';
  const a = Buffer.from(expected, 'utf8');
  const b = Buffer.from(supplied, 'utf8');
  // Missing and wrong are the same 401 with the same body — distinguishing them would
  // confirm to a caller that a key exists. Length-guard first: timingSafeEqual throws
  // on unequal-length buffers, and that throw would itself be a length oracle.
  const ok = a.length === b.length && crypto.timingSafeEqual(a, b);
  if (!ok) {
    res.set('WWW-Authenticate', 'X-Reco-Export-Key');
    return res.status(401).json({ success: false, message: 'Invalid or missing export key', code: 'invalid_api_key' });
  }
  next();
}

router.get('/export/reco-data', exportKey, async (req, res, next) => {
  try {
    const [venues, users, bookings, reviews] = await Promise.all([
      pool.query(`SELECT v.id AS "venueId", v.name, v.sport_type AS "sportType", v.city, v.address,
        v.price_per_hour AS "pricePerHour", v.rating, v.total_reviews AS "totalReviews",
        v.amenities, v.ground_type AS "groundType", v.is_active AS "isActive",
        COUNT(b.id)::int AS "bookingCount"
        FROM venues v LEFT JOIN bookings b ON b.venue_id=v.id AND b.status IN ('confirmed','checked_in')
        GROUP BY v.id ORDER BY v.id`),
      pool.query(`SELECT u.id AS "userId", pp.sport_preferences AS "sportPreferences"
        FROM users u LEFT JOIN player_profiles pp ON pp.user_id=u.id WHERE u.role='player' AND u.is_active=true ORDER BY u.id`),
      pool.query(`SELECT player_id AS "userId", venue_id AS "venueId", created_at AS "bookedAt"
        FROM bookings WHERE status IN ('confirmed','checked_in') ORDER BY player_id, created_at`),
      pool.query(`SELECT reviewer_id AS "userId", venue_id AS "venueId", rating
        FROM reviews WHERE venue_id IS NOT NULL AND rating >= 4 AND COALESCE(hidden,false)=false ORDER BY reviewer_id, created_at`),
    ]);
    const byUser = new Map(users.rows.map(u => [String(u.userId), { ...u, bookings: [], highReviews: [] }]));
    for (const b of bookings.rows) if (byUser.has(String(b.userId))) byUser.get(String(b.userId)).bookings.push(b);
    for (const r of reviews.rows) if (byUser.has(String(r.userId))) byUser.get(String(r.userId)).highReviews.push(r);
    res.json({ success: true, data: { exportedAt: new Date().toISOString(), venues: venues.rows, users: [...byUser.values()] } });
  } catch (e) { next(e); }
});

module.exports = router;
