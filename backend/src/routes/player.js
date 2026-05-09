const express = require('express');
const router = express.Router();
const pool = require('../db/pool');
const authMiddleware = require('../middleware/authMiddleware');

// GET /api/player/home — home screen data
router.get('/home', authMiddleware, async (req, res, next) => {
  try {
    const userId = req.user.id;

    // Upcoming bookings (max 3) — wrapped in try-catch so missing table doesn't crash
    let upcomingBookings = [];
    try {
      const upcoming = await pool.query(`
        SELECT b.id, b.slot_date, b.start_time, b.end_time, b.status,
          b.total_amount, v.name as venue_name, v.city,
          COALESCE(v.venue_photos[1], null) as venue_photo
        FROM bookings b JOIN venues v ON v.id = b.venue_id
        WHERE b.player_id = $1 AND b.status IN ('confirmed','pending')
          AND b.slot_date >= CURRENT_DATE
        ORDER BY b.slot_date, b.start_time LIMIT 3`, [userId]);
      upcomingBookings = upcoming.rows;
    } catch (e) {
      console.log('Bookings query skipped (table may not exist):', e.message);
    }

    // Featured venues — all active venues
    let featuredVenues = [];
    try {
      const venues = await pool.query(`
        SELECT id, name, sport_type, city, address,
          price_per_hour, rating, total_reviews,
          COALESCE(venue_photos[1], null) as cover_photo
        FROM venues WHERE is_active = true
        ORDER BY rating DESC NULLS LAST LIMIT 6`);
      featuredVenues = venues.rows;
    } catch (e) {
      console.log('Venues query failed:', e.message);
    }

    // Wallet balance
    let walletData = { balance: 0, frozen_balance: 0 };
    try {
      const wallet = await pool.query(
        `SELECT balance, frozen_balance FROM wallets WHERE user_id = $1`, [userId]);
      if (wallet.rows.length > 0) walletData = wallet.rows[0];
    } catch (e) {
      console.log('Wallet query skipped:', e.message);
    }

    // Player profile quick stats
    let profileData = { trust_score: 100, elo_rating: 1000, sport_preferences: [] };
    try {
      const profile = await pool.query(`
        SELECT pp.trust_score, pp.elo_rating, pp.sport_preferences
        FROM player_profiles pp WHERE pp.user_id = $1`, [userId]);
      if (profile.rows.length > 0) profileData = profile.rows[0];
    } catch (e) {
      console.log('Profile query skipped:', e.message);
    }

    res.json({
      success: true,
      data: {
        upcomingBookings,
        featuredVenues,
        wallet: walletData,
        profile: profileData
      }
    });
  } catch (e) {
    console.error('Player home error:', e);
    next(e);
  }
});

module.exports = router;
