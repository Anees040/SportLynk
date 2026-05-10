const express = require('express');
const router = express.Router();
const pool = require('../db/pool');
const authMiddleware = require('../middleware/authMiddleware');
const checkRole = require('../middleware/roleMiddleware');

// POST /api/slots/:id/lock - Temporarily lock a slot for booking (5 min TTL)
router.post('/:id/lock', authMiddleware, checkRole('player'), async (req, res, next) => {
  const client = await pool.connect();
  try {
    const slotId = req.params.id;
    await client.query('BEGIN');
    
    // Check if slot is available
    const slotCheck = await client.query(
      `SELECT * FROM slots WHERE id=$1 FOR UPDATE`, 
      [slotId]
    );
    
    if (!slotCheck.rows.length) {
      await client.query('ROLLBACK');
      return res.status(404).json({ success: false, message: 'Slot not found' });
    }
    
    const slot = slotCheck.rows[0];
    
    // If it's locked by someone else, check if it's expired
    if (slot.status === 'temporarily_locked') {
      const lockedAt = new Date(slot.locked_at);
      const now = new Date();
      const diffMinutes = (now - lockedAt) / (1000 * 60);
      
      if (diffMinutes < 5) {
        await client.query('ROLLBACK');
        return res.status(409).json({ success: false, message: 'Slot is currently locked by another user' });
      }
      // If expired, we can proceed to lock it
    } else if (slot.status !== 'available') {
      await client.query('ROLLBACK');
      return res.status(409).json({ success: false, message: `Slot is already ${slot.status}` });
    }
    
    // Lock it
    const updated = await client.query(
      `UPDATE slots 
       SET status='temporarily_locked', locked_at=NOW() 
       WHERE id=$1 RETURNING *`, 
      [slotId]
    );
    
    await client.query('COMMIT');
    res.json({ success: true, message: 'Slot locked successfully', data: updated.rows[0] });
  } catch (e) {
    await client.query('ROLLBACK');
    next(e);
  } finally {
    client.release();
  }
});

// DELETE /api/slots/:id/lock - Unlock a slot
router.delete('/:id/lock', authMiddleware, checkRole('player'), async (req, res, next) => {
  try {
    const slotId = req.params.id;
    
    const result = await pool.query(
      `UPDATE slots 
       SET status='available', locked_at=null 
       WHERE id=$1 AND status='temporarily_locked' 
       RETURNING *`, 
      [slotId]
    );
    
    if (!result.rows.length) {
      return res.status(404).json({ success: false, message: 'Slot is not locked or not found' });
    }
    
    res.json({ success: true, message: 'Slot unlocked' });
  } catch (e) {
    next(e);
  }
});

module.exports = router;
