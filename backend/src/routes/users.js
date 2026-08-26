const express = require('express');
const router = express.Router();
const bcrypt = require('bcrypt');
const pool = require('../db/pool');
const authMiddleware = require('../middleware/authMiddleware');

// GET /api/users/me/player — get full player profile with defaults
router.get('/me/player', authMiddleware, async (req, res, next) => {
  try {
    const userId = req.user.id;
    const result = await pool.query(`
      SELECT 
        u.id, u.name, u.email, u.phone, u.avatar_url, u.created_at,
        COALESCE(pp.sport_preferences, '{}') as sport_preferences,
        COALESCE(pp.elo_rating, 1000) as elo_rating,
        COALESCE(pp.trust_score, 100) as trust_score,
        COALESCE(w.balance, 0) as balance,
        COALESCE(w.frozen_balance, 0) as frozen_balance
      FROM users u
      LEFT JOIN player_profiles pp ON pp.user_id = u.id
      LEFT JOIN wallets w ON w.user_id = u.id
      WHERE u.id = $1
    `, [userId]);

    if (!result.rows.length) {
      return res.status(404).json({ success: false, message: 'User not found' });
    }

    const row = result.rows[0];
    // Ensure sport_preferences is always an array
    if (row.sport_preferences && typeof row.sport_preferences === 'string') {
      try {
        row.sport_preferences = JSON.parse(row.sport_preferences);
      } catch (_) {
        row.sport_preferences = [];
      }
    }
    if (!Array.isArray(row.sport_preferences)) {
      row.sport_preferences = [];
    }

    res.json({ success: true, data: row });
  } catch (err) {
    console.error('GET /me/player error:', err);
    next(err);
  }
});

// PATCH /api/users/me/update
router.patch('/me/update', authMiddleware, async (req, res, next) => {
  const { name, email, sportPreferences, avatarUrl } = req.body;
  const userId = req.user.id;

  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    // Update users table (name, email, avatar_url)
    if (name) {
      await client.query('UPDATE users SET name = $1 WHERE id = $2', [name, userId]);
    }
    
    if (email !== undefined) {
      const cleanEmail = (email && typeof email === 'string' && email.trim() !== '') ? email.trim() : null;
      if (cleanEmail) {
        const existing = await client.query(
          'SELECT id FROM users WHERE email = $1 AND id != $2', [cleanEmail, userId]);
        if (existing.rows.length > 0) {
          await client.query('ROLLBACK');
          return res.status(409).json({ success: false, message: 'Email already in use' });
        }
      }
      await client.query(
        'UPDATE users SET email = $1 WHERE id = $2', 
        [cleanEmail, userId]);
    }

    if (avatarUrl !== undefined) {
      await client.query(
        'UPDATE users SET avatar_url = $1 WHERE id = $2',
        [avatarUrl || null, userId]);
    }

    // Update player_profiles table (sport_preferences) using UPSERT.
    // trust_score 50 = the Trust Score 2.0 cold-start baseline (ER2.5); this
    // INSERT arm rarely fires (auth.js:53 already created the profile at
    // registration), but it must not seed the retired 100 baseline if it does.
    if (sportPreferences && Array.isArray(sportPreferences)) {
      await client.query(`
        INSERT INTO player_profiles (user_id, sport_preferences, elo_rating, trust_score)
        VALUES ($1, $2, 1000, 50)
        ON CONFLICT (user_id) DO UPDATE
        SET sport_preferences = $2
      `, [userId, sportPreferences]);
    }

    await client.query('COMMIT');

    // Fetch updated data
    const result = await pool.query(`
      SELECT 
        u.name, u.email, u.avatar_url,
        COALESCE(pp.sport_preferences, '{}') as sport_preferences
      FROM users u
      LEFT JOIN player_profiles pp ON pp.user_id = u.id
      WHERE u.id = $1
    `, [userId]);

    res.json({ success: true, data: result.rows[0] });
  } catch (err) {
    await client.query('ROLLBACK');
    console.error('PATCH /me/update error:', err);
    next(err);
  } finally {
    client.release();
  }
});

// POST /api/users/me/change-password
router.post('/me/change-password', authMiddleware, async (req, res, next) => {
  try {
    const { currentPassword, newPassword } = req.body;
    const userId = req.user.id;

    if (!currentPassword || !newPassword) {
      return res.status(400).json({ success: false, message: 'Current and new password are required' });
    }
    if (newPassword.length < 8) {
      return res.status(400).json({ success: false, message: 'New password must be at least 8 characters' });
    }

    // Fetch current hash
    const userRes = await pool.query('SELECT password_hash FROM users WHERE id = $1', [userId]);
    if (!userRes.rows.length) {
      return res.status(404).json({ success: false, message: 'User not found' });
    }

    // Verify current password
    const match = await bcrypt.compare(currentPassword, userRes.rows[0].password_hash);
    if (!match) {
      return res.status(401).json({ success: false, message: 'Current password is incorrect' });
    }

    // Hash new password and update
    const hashed = await bcrypt.hash(newPassword, 12);
    await pool.query('UPDATE users SET password_hash = $1 WHERE id = $2', [hashed, userId]);

    res.json({ success: true, message: 'Password changed successfully' });
  } catch (err) {
    console.error('POST /me/change-password error:', err);
    next(err);
  }
});

module.exports = router;
