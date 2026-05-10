const express = require('express');
const router = express.Router();
const pool = require('../db/pool');
const authMiddleware = require('../middleware/authMiddleware');

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
      WHERE ${where}
      ORDER BY ${orderBy}
      LIMIT $${i} OFFSET $${i + 1}
    `, [...params, limit, offset]);

    res.json({ success: true, data: result.rows });
  } catch(e) {
    console.error('GET /venues error:', e);
    next(e);
  }
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
      
    // Auto-release expired locks (5 minute TTL)
    await pool.query(
      `UPDATE slots 
       SET status='available', locked_at=null 
       WHERE venue_id=$1 AND slot_date=$2 AND status='temporarily_locked' 
       AND locked_at < NOW() - INTERVAL '5 minutes'`,
      [id, slotDate]);
      
    const slots = await pool.query(
      `SELECT * FROM slots WHERE venue_id=$1 AND slot_date=$2 ORDER BY start_time`,
      [id, slotDate]);
    res.json({ success:true, data: { ...venue.rows[0], slots: slots.rows } });
  } catch(e){ next(e); }
});

module.exports = router;
