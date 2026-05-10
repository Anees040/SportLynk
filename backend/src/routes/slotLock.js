const express = require('express');
const router = express.Router();
const pool = require('../db/pool');
const authMiddleware = require('../middleware/authMiddleware');
const checkRole = require('../middleware/roleMiddleware');

// ── Constants ────────────────────────────────────────────────
const LOCK_TTL_MINUTES = 2; // Industry standard: 2 minutes

// POST /api/slots/:id/lock — Temporarily lock a slot (1 per player per venue)
router.post('/:id/lock', authMiddleware, checkRole('player'), async (req, res, next) => {
  const client = await pool.connect();
  try {
    const slotId = req.params.id;
    const userId = req.user.id;
    await client.query('BEGIN');
    
    // 1. Get the target slot (with row lock)
    const slotCheck = await client.query(
      `SELECT s.*, s.venue_id FROM slots s WHERE s.id=$1 FOR UPDATE`, [slotId]);
    
    if (!slotCheck.rows.length) {
      await client.query('ROLLBACK');
      return res.status(404).json({ success: false, message: 'Slot not found' });
    }
    
    const slot = slotCheck.rows[0];
    const venueId = slot.venue_id;
    
    // 2. Auto-release ANY existing lock this player has on THIS venue
    await client.query(
      `UPDATE slots 
       SET status='available', locked_at=null, locked_by=null
       WHERE venue_id=$1 AND locked_by=$2 AND status='temporarily_locked'`,
      [venueId, userId]);
    
    // 3. Check if slot is available or has an expired lock
    if (slot.status === 'temporarily_locked') {
      if (slot.locked_by === userId) {
        // Player re-selecting their own slot — allow
      } else {
        const lockedAt = new Date(slot.locked_at);
        const now = new Date();
        const diffMinutes = (now - lockedAt) / (1000 * 60);
        
        if (diffMinutes < LOCK_TTL_MINUTES) {
          await client.query('ROLLBACK');
          return res.status(409).json({ 
            success: false, 
            message: 'Slot is being held by another player. Try again in a moment.' 
          });
        }
        // Expired lock — we can take it
      }
    } else if (slot.status !== 'available') {
      await client.query('ROLLBACK');
      return res.status(409).json({ success: false, message: `Slot is already ${slot.status}` });
    }
    
    // 4. Lock it with ownership tracking
    const updated = await client.query(
      `UPDATE slots 
       SET status='temporarily_locked', locked_at=NOW(), locked_by=$1 
       WHERE id=$2 RETURNING *`, 
      [userId, slotId]);
    
    await client.query('COMMIT');
    res.json({ 
      success: true, 
      message: 'Slot locked successfully', 
      data: updated.rows[0],
      expiresInSeconds: LOCK_TTL_MINUTES * 60
    });
  } catch (e) {
    await client.query('ROLLBACK');
    console.error('Slot lock error:', e);
    next(e);
  } finally {
    client.release();
  }
});

// DELETE /api/slots/:id/lock — Unlock a slot (only by the player who locked it)
router.delete('/:id/lock', authMiddleware, checkRole('player'), async (req, res, next) => {
  try {
    const slotId = req.params.id;
    const userId = req.user.id;
    
    const result = await pool.query(
      `UPDATE slots 
       SET status='available', locked_at=null, locked_by=null
       WHERE id=$1 AND status='temporarily_locked' AND locked_by=$2
       RETURNING *`, 
      [slotId, userId]);
    
    if (!result.rows.length) {
      return res.status(404).json({ success: false, message: 'Slot is not locked by you' });
    }
    
    res.json({ success: true, message: 'Slot unlocked' });
  } catch (e) {
    next(e);
  }
});

module.exports = router;
