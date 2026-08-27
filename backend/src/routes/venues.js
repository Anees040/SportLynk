const express = require('express');
const router = express.Router();
const pool = require('../db/pool');
const authMiddleware = require('../middleware/authMiddleware');
const { recommendVenues, SOURCE_MODEL } = require('../services/mlClient');
const { TtlCache } = require('../utils/ttlCache');
const recoCache = new TtlCache({ name: 'venue-recommendations', ttlMs: 15 * 60 * 1000, maxEntries: 1000 });

/**
 * Checkout holds (see routes/slotLock.js) live in slots.locked_until only —
 * `status` stays 'available' while a slot is held. So the state the UI paints is
 * DERIVED per request, never stored, and an expired hold reads as free with no
 * sweep job involved.
 *
 * SRS colour code: Green available · Amber booked · Red blocked · Blue locked.
 *
 * `userParam` is the SQL placeholder ($3, $4, …) carrying the caller's id, so a
 * player can still select the slot they are holding themselves.
 */
const HOLD_IS_LIVE = `(s.locked_until IS NOT NULL AND s.locked_until > NOW())`;
const slotColumns = (userParam) => `s.*,
        (s.status = 'available' AND ${HOLD_IS_LIVE}) AS is_locked,
        (${HOLD_IS_LIVE} AND s.locked_by = ${userParam}) AS locked_by_me,
        CASE WHEN s.status = 'available' AND ${HOLD_IS_LIVE} THEN 'locked'
             ELSE s.status::text END AS effective_status`;

// GET /api/venues — list with filters
router.get('/', authMiddleware, async (req, res, next) => {
  try {
    const { sport, city, search, sort, min_price, max_price, min_rating, limit = 20, offset = 0 } = req.query;
    let conditions = ['v.is_active = true'];
    let params = [];
    let i = 1;

    if (sport) {
      conditions.push(`LOWER(v.sport_type) = LOWER($${i})`);
      params.push(sport);
      i++;
    }
    if (city) {
      conditions.push(`v.city ILIKE $${i}`);
      params.push(`%${city}%`);
      i++;
    }
    if (search) {
      conditions.push(`(v.name ILIKE $${i} OR v.address ILIKE $${i + 1} OR v.city ILIKE $${i + 2} OR v.sport_type ILIKE $${i + 3})`);
      params.push(`%${search}%`, `%${search}%`, `%${search}%`, `%${search}%`);
      i += 4;
    }
    if (min_price) {
      conditions.push(`v.price_per_hour >= $${i}`);
      params.push(parseFloat(min_price));
      i++;
    }
    if (max_price) {
      conditions.push(`v.price_per_hour <= $${i}`);
      params.push(parseFloat(max_price));
      i++;
    }
    if (min_rating) {
      conditions.push(`COALESCE(v.rating, 0) >= $${i}`);
      params.push(parseFloat(min_rating));
      i++;
    }

    const where = conditions.join(' AND ');

    // Sort options
    let orderBy = 'v.rating DESC NULLS LAST';
    if (sort === 'price_low') orderBy = 'v.price_per_hour ASC NULLS LAST';
    else if (sort === 'price_high') orderBy = 'v.price_per_hour DESC NULLS LAST';
    else if (sort === 'rating') orderBy = 'v.rating DESC NULLS LAST';
    else if (sort === 'newest') orderBy = 'v.created_at DESC';
    else if (sort === 'reviews') orderBy = 'v.total_reviews DESC NULLS LAST';

    const result = await pool.query(`
      SELECT v.*, 
        COALESCE(v.venue_photos[1], null) as cover_photo,
        v.venue_photos,
        u.name as owner_name
      FROM venues v
      LEFT JOIN users u ON u.id = v.owner_id
      LEFT JOIN owner_profiles op ON op.user_id = v.owner_id
      WHERE ${where}
        AND (op.verification_status = 'approved' OR op.verification_status IS NULL)
      ORDER BY ${orderBy}
      LIMIT $${i} OFFSET $${i + 1}
    `, [...params, limit, offset]);

    res.json({ success: true, data: result.rows });

  } catch(e) {
    console.error('GET /venues error:', e);
    next(e);
  }
});

// GET /api/venues/recommended — model ranking with an honest heuristic fallback.
router.get('/recommended', authMiddleware, async (req, res, next) => {
  try {
    const limit = Math.max(1, Math.min(Number(req.query.limit) || 20, 100));
    const reco = await recoCache.getOrSet(String(req.user.id), () => recommendVenues(req.user.id, { limit }), { shouldCache: r => r && r.source === SOURCE_MODEL });
    let ranked = [];
    if (reco.source === SOURCE_MODEL && reco.items.length) {
      const ids = reco.items.map(x => x.venue_id);
      const rows = await pool.query(`SELECT v.*, COALESCE(v.venue_photos[1], null) AS cover_photo, u.name AS owner_name
        FROM venues v LEFT JOIN users u ON u.id=v.owner_id WHERE v.id = ANY($1::uuid[]) AND v.is_active=true`, [ids]);
      const byId = new Map(rows.rows.map(v => [String(v.id), v]));
      ranked = reco.items.map(x => byId.get(String(x.venue_id)) ? { ...byId.get(String(x.venue_id)), score: x.score, match_pct: x.match_pct, reasons: x.reasons } : null).filter(Boolean);
    } else {
      const prefs = await pool.query('SELECT sport_preferences FROM player_profiles WHERE user_id=$1', [req.user.id]);
      const sports = prefs.rows[0]?.sport_preferences || [];
      const rows = await pool.query(`SELECT v.*, COALESCE(v.venue_photos[1], null) AS cover_photo, u.name AS owner_name
        FROM venues v LEFT JOIN users u ON u.id=v.owner_id WHERE v.is_active=true
        ORDER BY CASE WHEN LOWER(v.sport_type)=ANY($1::text[]) THEN 0 ELSE 1 END, v.rating DESC NULLS LAST LIMIT $2`, [sports.map(s => String(s).toLowerCase()), limit]);
      ranked = rows.rows.map(v => ({ ...v, score: null, match_pct: null, reasons: [] }));
    }
    res.json({ success: true, data: { venues: ranked, source: reco.source, label: reco.label || 'For you', modelVersion: reco.modelVersion || null } });
  } catch (e) { next(e); }
});

// GET /api/venues/:id — detail + today's slots
router.get('/:id', authMiddleware, async (req, res, next) => {
  try {
    const { id } = req.params;
    const { date } = req.query;
    const slotDate = date || new Date().toISOString().split('T')[0];
    const venue = await pool.query(
      `SELECT v.*, u.name as owner_name, u.phone as owner_phone
       FROM venues v LEFT JOIN users u ON u.id = v.owner_id
       WHERE v.id = $1 AND v.is_active = true`, [id]);
    if (!venue.rows.length)
      return res.status(404).json({ success:false, message:'Venue not found' });

    // Calculate current PKT time for dynamic filtering
    const now = new Date();
    const pktNow = new Date(now.getTime() + (5 * 60 * 60 * 1000));
    const todayLocalStr = pktNow.toISOString().split('T')[0];
    const nowTimeStr = pktNow.toISOString().split('T')[1].split('.')[0]; // HH:mm:ss

    let slots = { rows: [] };
    if (slotDate > todayLocalStr) {
      slots = await pool.query(
        `SELECT ${slotColumns('$3')} FROM slots s
          WHERE s.venue_id=$1 AND s.slot_date=$2 ORDER BY s.start_time`,
        [id, slotDate, req.user.id]);
    } else if (slotDate === todayLocalStr) {
      slots = await pool.query(
        `SELECT ${slotColumns('$4')} FROM slots s
          WHERE s.venue_id=$1 AND s.slot_date=$2 AND s.start_time > $3 ORDER BY s.start_time`,
        [id, slotDate, nowTimeStr, req.user.id]);
    } // If slotDate < todayLocalStr, returns empty slots array

    res.json({ success:true, data: { ...venue.rows[0], slots: slots.rows } });
  } catch(e){ next(e); }
});

module.exports = router;
