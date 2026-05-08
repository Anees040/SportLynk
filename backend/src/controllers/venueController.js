const pool = require('../db/pool');

// ─── SEARCH VENUES (public) ─────────────────────────────────
const searchVenues = async (req, res) => {
  try {
    const { city, sport_type } = req.query;

    let query = `
      SELECT id, name, description, sport_type, city, address,
             latitude, longitude, base_price, current_price, image_url
      FROM venues
      WHERE is_active = true
    `;
    const params = [];
    let paramIndex = 1;

    if (city) {
      query += ` AND city ILIKE $${paramIndex}`;
      params.push(`%${city}%`);
      paramIndex++;
    }

    if (sport_type) {
      query += ` AND sport_type = $${paramIndex}`;
      params.push(sport_type);
      paramIndex++;
    }

    query += ' ORDER BY name ASC';

    const result = await pool.query(query, params);

    return res.status(200).json({
      success: true,
      data: { venues: result.rows },
      message: `Found ${result.rows.length} venue(s)`,
    });
  } catch (err) {
    console.error('SearchVenues error:', err);
    return res.status(500).json({
      success: false,
      message: 'Internal server error',
    });
  }
};

// ─── GET VENUE BY ID (public) ───────────────────────────────
const getVenueById = async (req, res) => {
  try {
    const { id } = req.params;

    const result = await pool.query(
      `SELECT id, name, description, sport_type, city, address,
              latitude, longitude, base_price, current_price, image_url,
              owner_id, is_active, created_at
       FROM venues
       WHERE id = $1`,
      [id]
    );

    if (result.rows.length === 0) {
      return res.status(404).json({
        success: false,
        message: 'Venue not found',
      });
    }

    return res.status(200).json({
      success: true,
      data: { venue: result.rows[0] },
      message: 'Venue retrieved',
    });
  } catch (err) {
    console.error('GetVenueById error:', err);
    return res.status(500).json({
      success: false,
      message: 'Internal server error',
    });
  }
};

// ─── GET VENUE SLOTS (public) ───────────────────────────────
const getVenueSlots = async (req, res) => {
  try {
    const { id } = req.params;
    const { date } = req.query;

    if (!date) {
      return res.status(400).json({
        success: false,
        message: 'Date query parameter is required (YYYY-MM-DD)',
      });
    }

    const result = await pool.query(
      `SELECT id, venue_id, date, start_time, end_time, status, price
       FROM venue_slots
       WHERE venue_id = $1 AND date = $2
       ORDER BY start_time ASC`,
      [id, date]
    );

    return res.status(200).json({
      success: true,
      data: { slots: result.rows },
      message: `Found ${result.rows.length} slot(s)`,
    });
  } catch (err) {
    console.error('GetVenueSlots error:', err);
    return res.status(500).json({
      success: false,
      message: 'Internal server error',
    });
  }
};

module.exports = { searchVenues, getVenueById, getVenueSlots };
