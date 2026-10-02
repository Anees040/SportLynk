const express = require('express');
const router = express.Router();
const pool = require('../db/pool');
const authMiddleware = require('../middleware/authMiddleware');
const { recommendVenues, SOURCE_MODEL } = require('../services/mlClient');
const { TtlCache } = require('../utils/ttlCache');
const discovery = require('../services/discoveryService');
const geo = require('../utils/geoDistance');
const settings = require('../utils/globalSettings');
const recoCache = new TtlCache({ name: 'venue-recommendations', ttlMs: 15 * 60 * 1000, maxEntries: 1000 });

/**
 * The checkout-hold and PKT-clock rules that used to live here moved into
 * services/discoveryService.js, because Scout answers `find_venue`,
 * `venue_info` and `check_availability` and FR8.15 forbids a second opinion about
 * whether a slot is free. `slotColumns` is still exported from there for any route
 * that needs the derived columns.
 */

/**
 * GET /api/venues — browse with filters. Transport only.
 *
 * The owner-verification gate, the filter list and the five sorts are in
 * discoveryService.searchVenues; the response bytes are unchanged.
 */
router.get('/', authMiddleware, async (req, res, next) => {
  try {
    // Only the sports the platform carries are listed. Sourced from the admin
    // setting rather than a constant here (or a list in Dart), so switching a sport
    // on or off is one settings write and the browse screen, Scout and the owner
    // create-venue gate all agree about it.
    const enabled = await settings.sportsEnabled();
    const allowed = Object.entries(enabled).filter(([, on]) => on).map(([k]) => k);

    let rows = await discovery.searchVenues(pool, {
      sport: req.query.sport,
      sports: allowed,
      city: req.query.city,
      search: req.query.search,
      sort: req.query.sort,
      minPrice: req.query.min_price,
      maxPrice: req.query.max_price,
      minRating: req.query.min_rating,
      limit: req.query.limit,
      offset: req.query.offset,
    });

    // Same proximity annotation the recommendation rail gets, so the browse list can
    // state "X km away" instead of being titled "Nearby" while knowing nothing about
    // distance. Venues without coordinates keep their place and carry a null distance.
    //
    // `sort=nearest` re-orders in JS, which means it sorts the page the SQL already
    // chose rather than the whole catalogue: it yields "the nearest of the top N",
    // not "the N nearest". Harmless while a city holds fewer venues than one page,
    // and the honest fix when it stops being true is an ORDER BY on a geography
    // column, not a larger page.
    const lat = Number(req.query.lat);
    const lng = Number(req.query.lng);
    if (Number.isFinite(lat) && Number.isFinite(lng)) {
      rows = geo.annotateDistance(rows, { lat, lng });
      if (String(req.query.sort || '') === 'nearest') rows = geo.sortByNearest(rows);
    }
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
    const enabled = await settings.sportsEnabled();
    const allowed = Object.entries(enabled).filter(([, on]) => on).map(([k]) => k);
    const reco = await recoCache.getOrSet(String(req.user.id), () => recommendVenues(req.user.id, { limit }), { shouldCache: r => r && r.source === SOURCE_MODEL });
    let ranked = [];
    if (reco.source === SOURCE_MODEL && reco.items.length) {
      const ids = reco.items.map(x => x.venue_id);
      const rows = await pool.query(`SELECT v.*, COALESCE(v.venue_photos[1], null) AS cover_photo, u.name AS owner_name
        FROM venues v LEFT JOIN users u ON u.id=v.owner_id
        WHERE v.id = ANY($1::uuid[]) AND v.is_active=true AND LOWER(v.sport_type) = ANY($2::text[])`, [ids, allowed]);
      const byId = new Map(rows.rows.map(v => [String(v.id), v]));
      ranked = reco.items.map(x => byId.get(String(x.venue_id)) ? { ...byId.get(String(x.venue_id)), score: x.score, match_pct: x.match_pct, reasons: x.reasons } : null).filter(Boolean);
    } else {
      // The no-model fallback. It used to ORDER BY preferred-sport-first without
      // filtering, so a cricket player's five picks were padded with football the
      // moment the cricket venues ran out — which reads as a recommender that ignores
      // the stated interest. A stated preference is now a filter, not a tiebreak.
      //
      // It relaxes rather than returning nothing: if the player's sports yield no
      // venue at all, every enabled sport is offered instead, because an empty rail
      // tells the player less than a broader one. `preferenceApplied` reports which
      // happened so the client is never guessing why the rail looks the way it does.
      const prefs = await pool.query('SELECT sport_preferences FROM player_profiles WHERE user_id=$1', [req.user.id]);
      const stated = (prefs.rows[0]?.sport_preferences || [])
        .map(s => String(s).toLowerCase())
        .filter(s => allowed.includes(s));
      const wanted = stated.length ? stated : allowed;
      const pick = (sportList) => pool.query(
        `SELECT v.*, COALESCE(v.venue_photos[1], null) AS cover_photo, u.name AS owner_name
           FROM venues v LEFT JOIN users u ON u.id=v.owner_id
          WHERE v.is_active=true AND LOWER(v.sport_type) = ANY($1::text[])
          ORDER BY v.rating DESC NULLS LAST, v.total_reviews DESC NULLS LAST
          LIMIT $2`, [sportList, limit]);
      let rows = await pick(wanted);
      if (!rows.rows.length && stated.length) rows = await pick(allowed);
      ranked = rows.rows.map(v => ({ ...v, score: null, match_pct: null, reasons: [] }));
    }
    // Proximity re-rank, applied after the model (see utils/geoDistance): when the
    // client sends the user's location, annotate each venue with "X km away", and
    // sort nearest-first only when the user asked for it (sort=nearest). Default order
    // stays the model's relevance; venues with no coordinates keep their rank and a
    // null distance. No location sent = no distance field and no behaviour change.
    const lat = Number(req.query.lat);
    const lng = Number(req.query.lng);
    if (Number.isFinite(lat) && Number.isFinite(lng)) {
      ranked = geo.annotateDistance(ranked, { lat, lng });
      if (String(req.query.sort || '') === 'nearest') ranked = geo.sortByNearest(ranked);
    }
    res.json({ success: true, data: { venues: ranked, source: reco.source, label: reco.label || 'For you', modelVersion: reco.modelVersion || null } });
  } catch (e) { next(e); }
});

/**
 * GET /api/venues/:id/availability?days=14 — free-slot count per date.
 *
 * Feeds the player's date rail so each chip can show how many slots a day has
 * before it is tapped. Defined before `/:id` for clarity; the two-segment path does
 * not collide with the single-segment `/:id` either way.
 */
router.get('/:id/availability', authMiddleware, async (req, res, next) => {
  try {
    const out = await discovery.venueAvailability(pool, {
      venueId: req.params.id,
      days: req.query.days,
    });
    if (!out.ok) return res.status(out.status).json({ success: false, message: out.message });
    res.json({ success: true, data: out.data });
  } catch (e) { next(e); }
});

/**
 * GET /api/venues/:id — detail + the day's slots. Transport only.
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
