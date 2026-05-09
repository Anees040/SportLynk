const express = require('express');
const router = express.Router();
const { pool } = require('../db/pool');
const authMiddleware = require('../middleware/authMiddleware');

// GET /api/player/home — home screen data
router.get('/home', authMiddleware, async (req, res, next) => {
  try {
    const userId = req.user.id;
    // Upcoming bookings (max 3)
    const upcoming = await pool.query(`
      SELECT b.id, b.slot_date, b.start_time, b.end_time, b.status,
        b.total_amount, v.name as venue_name, v.city,
        COALESCE(v.venue_photos[1],null) as venue_photo
      FROM bookings b JOIN venues v ON v.id=b.venue_id
      WHERE b.player_id=$1 AND b.status IN ('confirmed','pending')
        AND b.slot_date >= CURRENT_DATE
      ORDER BY b.slot_date, b.start_time LIMIT 3`, [userId]);
    // Featured venues
    const venues = await pool.query(`
      SELECT id, name, sport_type, city, address,
        price_per_hour, rating, total_reviews,
        COALESCE(venue_photos[1],null) as cover_photo
      FROM venues WHERE is_active=true
      ORDER BY rating DESC NULLS LAST LIMIT 6`);
    // Wallet balance
    const wallet = await pool.query(
      `SELECT balance, frozen_balance FROM wallets WHERE user_id=$1`, [userId]);
    // Player profile quick stats
    const profile = await pool.query(`
      SELECT pp.trust_score, pp.elo_rating, pp.sport_preferences
      FROM player_profiles pp WHERE pp.user_id=$1`, [userId]);
    res.json({ success:true, data: {
      upcomingBookings: upcoming.rows,
      featuredVenues: venues.rows,
      wallet: wallet.rows[0] || { balance:0, frozen_balance:0 },
      profile: profile.rows[0] || { trust_score:100, elo_rating:1000, sport_preferences:[] }
    }});
  } catch(e){ next(e); }
});

module.exports = router;
