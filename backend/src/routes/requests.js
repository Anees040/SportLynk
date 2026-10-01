/**
 * Requests API — the REST half of direct player-to-player play requests (module 8c).
 *
 * Thin by contract: every handler proves identity through `auth`, opens one
 * transaction, hands the work to requestService, and translates the service's
 * `{ ok, status, code, message, data }` into an envelope. No business rule lives
 * here — the state machine, the duplicate guard and the room-opening side effect are
 * all the service's, so this file and check scripts exercise the same code.
 *
 * The one side effect that must wait for COMMIT is the accept pill: the socket event
 * that carries the opening system message is emitted only after the row it points at
 * is durable, the same rule routes/teams.js and routes/chat.js follow.
 */

const express = require('express');
const pool = require('../db/pool');
const auth = require('../middleware/authMiddleware');
const chat = require('../utils/chatCore');
const requests = require('../services/requestService');

const router = express.Router();
router.use(auth);

const fail = (res, status, message) => res.status(status).json({ success: false, message });

/** Roll back, then answer — the only safe way to leave an open transaction. */
async function bail(client, res, status, message) {
  await client.query('ROLLBACK').catch(() => {});
  return fail(res, status, message);
}

// The five statuses a request can be in, for validating an optional list filter.
const STATUSES = ['pending', 'accepted', 'declined', 'cancelled', 'expired'];
const statusFilter = (q) => (STATUSES.includes(q) ? q : null);

/**
 * GET /api/requests/discover?sport&limit — players this user could ask to play.
 * A plain read: the honest discovery list, no transaction needed.
 */
router.get('/discover', async (req, res, next) => {
  try {
    const r = await requests.discoverPlayers(pool, {
      userId: req.user.id,
      sport: req.query.sport || null,
      limit: req.query.limit,
    });
    return res.status(r.status).json({ success: r.ok, data: r.data });
  } catch (e) { next(e); }
});

/** GET /api/requests/incoming?status — requests addressed to this user. */
router.get('/incoming', async (req, res, next) => {
  try {
    const r = await requests.incoming(pool, req.user.id, { status: statusFilter(req.query.status) });
    return res.status(r.status).json({ success: r.ok, data: r.data });
  } catch (e) { next(e); }
});

/** GET /api/requests/outgoing?status — requests this user has sent. */
router.get('/outgoing', async (req, res, next) => {
  try {
    const r = await requests.outgoing(pool, req.user.id, { status: statusFilter(req.query.status) });
    return res.status(r.status).json({ success: r.ok, data: r.data });
  } catch (e) { next(e); }
});

/**
 * POST /api/requests — ask a player to play. Body: { targetUserId, sport?, message? }.
 * The service validates the target and blocks a duplicate pending ask; the target is
 * notified inside the same transaction, so a committed request always has its ping.
 */
router.post('/', async (req, res, next) => {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const r = await requests.createRequest(client, {
      requesterId: req.user.id,
      targetUserId: req.body.targetUserId,
      sport: req.body.sport,
      message: req.body.message,
    });
    if (!r.ok) return bail(client, res, r.status, r.message);
    await client.query('COMMIT');
    return res.status(r.status).json({ success: true, data: r.data });
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    next(e);
  } finally {
    client.release();
  }
});

/**
 * POST /api/requests/:id/respond — accept or decline. Body: { action }.
 * Accept opens the direct room and notifies the requester; the opening pill is
 * emitted over the socket only after COMMIT.
 */
router.post('/:id/respond', async (req, res, next) => {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const r = await requests.respond(client, {
      id: req.params.id, userId: req.user.id, action: req.body.action,
    });
    if (!r.ok) return bail(client, res, r.status, r.message);
    await client.query('COMMIT');
    if (r.pill) await chat.emitPills(pool, r.pill);
    return res.status(r.status).json({ success: true, data: r.data });
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    next(e);
  } finally {
    client.release();
  }
});

/** POST /api/requests/:id/cancel — the requester withdraws a pending ask. */
router.post('/:id/cancel', async (req, res, next) => {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const r = await requests.cancel(client, { id: req.params.id, userId: req.user.id });
    if (!r.ok) return bail(client, res, r.status, r.message);
    await client.query('COMMIT');
    return res.status(r.status).json({ success: true, data: r.data });
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    next(e);
  } finally {
    client.release();
  }
});

module.exports = router;
