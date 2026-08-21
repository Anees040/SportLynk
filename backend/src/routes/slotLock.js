const express = require('express');
const router = express.Router();
const pool = require('../db/pool');
const authMiddleware = require('../middleware/authMiddleware');
const checkRole = require('../middleware/roleMiddleware');

/**
 * Checkout slot locks (SRS ER1.5, FR3.7).
 *
 * A lock is a short hold one player takes on a free slot while they walk
 * through checkout, so two players cannot spend two minutes each filling in the
 * same booking. It is NOT a slot_status value:
 *
 *   `slots.status` stays 'available' for the whole hold — only `locked_until`
 *   and `locked_by` change. That makes expiry LAZY: a lock whose `locked_until`
 *   has passed reads as free everywhere, so no sweep job is needed and a client
 *   that dies mid-checkout can never strand a slot.
 *
 * A hold ends when: the booking is created (bookings.js clears it), the player
 * leaves checkout (DELETE below), or `locked_until` simply passes.
 */
const LOCK_TTL_MINUTES = 5;

/** True while a hold is still live. Expired holds are indistinguishable from free. */
const HOLD_IS_LIVE = `(locked_until IS NOT NULL AND locked_until > NOW())`;

// POST /api/slots/:id/lock — hold a free slot for LOCK_TTL_MINUTES.
// Re-tapping a slot you already hold refreshes the hold; a slot held by
// somebody else is a 409.
router.post('/:id/lock', authMiddleware, checkRole('player'), async (req, res, next) => {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    const found = await client.query(
      `SELECT id, venue_id, status, locked_by, ${HOLD_IS_LIVE} AS is_held
         FROM slots
        WHERE id = $1
        FOR UPDATE`,
      [req.params.id],
    );

    if (!found.rows.length) {
      await client.query('ROLLBACK');
      return res.status(404).json({ success: false, message: 'Slot not found' });
    }

    const slot = found.rows[0];

    if (slot.status !== 'available') {
      await client.query('ROLLBACK');
      return res.status(409).json({
        success: false,
        message: slot.status === 'booked'
          ? 'This slot has just been booked by another player.'
          : 'This slot is not available.',
      });
    }

    if (slot.is_held && slot.locked_by !== req.user.id) {
      await client.query('ROLLBACK');
      return res.status(409).json({
        success: false,
        message: 'Another player is checking out this slot. Try again in a few minutes.',
      });
    }

    // One hold per player per venue — moving to a different slot drops the old
    // hold instead of letting one player sit on the whole grid.
    await client.query(
      `UPDATE slots
          SET locked_by = NULL, locked_until = NULL
        WHERE venue_id = $1 AND locked_by = $2 AND id <> $3`,
      [slot.venue_id, req.user.id, slot.id],
    );

    const updated = await client.query(
      `UPDATE slots
          SET locked_by = $1, locked_until = NOW() + make_interval(mins => $2)
        WHERE id = $3
        RETURNING id, locked_until`,
      [req.user.id, LOCK_TTL_MINUTES, slot.id],
    );

    await client.query('COMMIT');
    res.json({
      success: true,
      message: `Slot held for you for ${LOCK_TTL_MINUTES} minutes`,
      data: {
        slotId: updated.rows[0].id,
        lockedUntil: updated.rows[0].locked_until,
        expiresInSeconds: LOCK_TTL_MINUTES * 60,
      },
    });
  } catch (e) {
    await client.query('ROLLBACK');
    console.error('Slot lock error:', e);
    next(e);
  } finally {
    client.release();
  }
});

// DELETE /api/slots/:id/lock — release your own hold.
// Best-effort by design: the client fires this while walking away from
// checkout, so "there was nothing to release" is a success, not an error.
router.delete('/:id/lock', authMiddleware, checkRole('player'), async (req, res, next) => {
  try {
    const result = await pool.query(
      `UPDATE slots
          SET locked_by = NULL, locked_until = NULL
        WHERE id = $1 AND locked_by = $2
        RETURNING id`,
      [req.params.id, req.user.id],
    );

    const released = result.rows.length > 0;
    res.json({
      success: true,
      message: released ? 'Hold released' : 'No hold to release',
      data: { released },
    });
  } catch (e) {
    console.error('Slot unlock error:', e);
    next(e);
  }
});

module.exports = router;
