const express = require('express');
const router = express.Router();
const pool = require('../db/pool');
const authMiddleware = require('../middleware/authMiddleware');
const { recommendVenues, SOURCE_MODEL } = require('../services/mlClient');
const { TtlCache } = require('../utils/ttlCache');
const discovery = require('../services/discoveryService');
const recoCache = new TtlCache({ name: 'venue-recommendations', ttlMs: 15 * 60 * 1000, maxEntries: 1000 });

/**
 * The checkout-hold and PKT-clock rules that used to live here moved into
 * services/discoveryService.js in S.6 Wave C, because Scout answers `find_venue`,
 * `venue_info` and `check_availability` and FR8.15 forbids a second opinion about
 * whether a slot is free. `slotColumns` is still exported from there for any route
 * that needs the derived columns.
 */

/**
 * GET /api/venues — browse with filters. TRANSPORT ONLY.
 *
 * The owner-verification gate, the filter list and the five sorts are in
 * discoveryService.searchVenues; the response bytes are unchanged.
 */
router.get('/', authMiddleware, async (req, res, next) => {
  try {
    const rows = await discovery.searchVenues(pool, {
      sport: req.query.sport,
      city: req.query.city,
      search: req.query.search,
      sort: req.query.sort,
      minPrice: req.query.min_price,
      maxPrice: req.query.max_price,
      minRating: req.query.min_rating,
      limit: req.query.limit,
      offset: req.query.offset,
    });
    res.json({ success: true, data: rows });
  } catch (e) {
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

/**
 * GET /api/venues/:id — detail + the day's slots. TRANSPORT ONLY.
 *
 * discoveryService.venueDetail owns the three-branch slot window (future date =
 * all slots, today = only slots that have not started in PKT, past = none) so
 * Scout's `venue_info` shows exactly what this screen shows.
 */
router.get('/:id', authMiddleware, async (req, res, next) => {
  try {
    const out = await discovery.venueDetail(pool, {
      venueId: req.params.id, userId: req.user.id, date: req.query.date,
    });
    if (!out.ok) return res.status(out.status).json({ success: false, message: out.message });
    res.json({ success: true, data: out.data });
  } catch (e) { next(e); }
});

module.exports = router;
