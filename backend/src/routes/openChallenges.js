/**
 * Open Challenges API — the Live Challenge Feed (item 9).
 *
 * Thin: parse, delegate to openChallengeService, map its {ok,status,code,message,data}
 * to the project's {success,...} envelope. All the rules — authority, booking
 * validation, first-claim-wins, the prep room — live in the service, which both this
 * router and (potentially) Scout can call.
 */
const express = require('express');
const auth = require('../middleware/authMiddleware');
const svc = require('../services/openChallengeService');
const pool = require('../db/pool');

const router = express.Router();
router.use(auth);

function send(res, r) {
  if (r.ok) return res.status(r.status).json({ success: true, message: r.message, data: r.data });
  return res.status(r.status).json({ success: false, code: r.code, message: r.message });
}

// GET /api/open-challenges?sport=football — the public board.
router.get('/', async (req, res, next) => {
  try {
    const r = await svc.listBoard(pool, { userId: req.user.id, sport: req.query.sport || null });
    return send(res, r);
  } catch (e) { next(e); }
});

// POST /api/open-challenges  { teamId, bookingId } — offer a confirmed booking.
router.post('/', async (req, res, next) => {
  try {
    const r = await svc.postChallengeTx({
      userId: req.user.id,
      teamId: req.body.teamId,
      bookingId: req.body.bookingId,
    });
    return send(res, r);
  } catch (e) { next(e); }
});

// POST /api/open-challenges/:id/claim  { teamId } — claim an open card.
router.post('/:id/claim', async (req, res, next) => {
  try {
    const r = await svc.claimChallengeTx({
      userId: req.user.id,
      openId: req.params.id,
      teamId: req.body.teamId,
    });
    return send(res, r);
  } catch (e) { next(e); }
});

// DELETE /api/open-challenges/:id — withdraw your own open card.
router.delete('/:id', async (req, res, next) => {
  try {
    const r = await svc.cancelChallengeTx({ userId: req.user.id, openId: req.params.id });
    return send(res, r);
  } catch (e) { next(e); }
});

module.exports = router;
