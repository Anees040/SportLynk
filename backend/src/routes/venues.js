const express = require('express');
const router = express.Router();
const pool = require('../db/pool');
const authMiddleware = require('../middleware/authMiddleware');

// GET /api/venues — list with filters
router.get('/', authMiddleware, async (req, res, next) => {
  try {
    const { sport, city, search, limit = 20, offset = 0 } = req.query;
    let conditions = ['v.is_active = true'];
    let params = [];
    let i = 1;
    if (sport) { conditions.push(`v.sport_type = $${i++}`); params.push(sport); }
    if (city)  { conditions.push(`v.city ILIKE $${i++}`); params.push(`%${city}%`); }
    if (search){ conditions.push(`(v.name ILIKE $${i++} OR v.address ILIKE $${i})`);
                 params.push(`%${search}%`,`%${search}%`); i+=2; }
    const where = conditions.join(' AND ');
    const result = await pool.query(`
      SELECT v.*, 
        COALESCE(v.venue_photos[1], null) as cover_photo,
        u.name as owner_name
      FROM venues v
      LEFT JOIN users u ON u.id = v.owner_id
      WHERE ${where}
      ORDER BY v.rating DESC NULLS LAST
      LIMIT $${i} OFFSET $${i+1}
    `, [...params, limit, offset]);
    res.json({ success: true, data: result.rows });
  } catch(e){ next(e); }
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
    const slots = await pool.query(
      `SELECT * FROM slots WHERE venue_id=$1 AND slot_date=$2 ORDER BY start_time`,
      [id, slotDate]);
    res.json({ success:true, data: { ...venue.rows[0], slots: slots.rows } });
  } catch(e){ next(e); }
});

module.exports = router;
