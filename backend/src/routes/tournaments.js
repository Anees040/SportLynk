/**
 * Tournaments API (S.7 Wave A) — SRS Module 6, FE-1 … FE-8.
 *
 * What this file is and is not
 * It is transport. Every rule about who may do what, every peso that moves and
 * every row that changes lives in `services/tournamentService.js`, which takes a
 * `client` and returns `{ok, status, code, message, data}`. This file reads the
 * request, calls one service function, and shapes the reply. The reason is the
 * same one bookingService exists for: the deadline job, Scout and these routes all
 * drive the same tournament, and three copies of "may this team register?" would be
 * three chances to disagree about it.
 *
 * Route order is load-bearing
 * `/mine` and `/preview` are declared before `/:id`. Express matches in
 * declaration order, so with `/:id` first a request for `/api/tournaments/mine`
 * would arrive at `detail` with `tournamentId = 'mine'` and 404 — a bug that looks
 * like a missing endpoint and is a sorting mistake.
 *
 * The role split
 * Reads are open to any signed-in user, because a public tournament overview is
 * FE-8 and a player has to be able to browse before they enter. Writes divide in
 * two: `checkRole('owner')` gates creating, generating, approving, entering results
 * and cancelling, and `checkRole('player')` gates registering and withdrawing. The
 * "only a venue owner runs a tournament" rule is therefore enforced by middleware
 * and again inside the service (`requireOwnedVenue`, `owner_id` comparisons), so a
 * player who obtains an owner token still cannot manage someone else's cup.
 *
 * Why `/:id/generate` is exposed at all
 * `jobs/tournamentJob.js` generates the bracket at the deadline unattended, so the
 * endpoint is not required for the flow to work. It exists because a demo cannot
 * wait for a wall clock, and because an owner whose field filled early should be
 * able to start. Both doors call the same `generateFixturesTx`, and its latch
 * (`fixtures_generated_at` under the row lock) is what makes pressing the button at
 * the same instant the job fires a 409 rather than two brackets.
 */
const express = require('express');
const auth = require('../middleware/authMiddleware');
const checkRole = require('../middleware/roleMiddleware');
const svc = require('../services/tournamentService');

const router = express.Router();
router.use(auth);

/** One shape for every reply, so a client never has to guess. */
function send(res, result, { createdStatus = null } = {}) {
  if (!result || !result.ok) {
    const status = (result && result.status) || 500;
    return res.status(status).json({
      success: false,
      message: (result && result.message) || 'Request failed',
      code: (result && result.code) || 'error',
    });
  }
  return res.status(createdStatus || result.status || 200).json({
    success: true,
    data: result.data,
    message: result.message || null,
    code: result.code || 'ok',
  });
}

/** Errors from the service layer are already shaped; anything else is a 500. */
const guard = (fn) => async (req, res, next) => {
  try { await fn(req, res); } catch (e) { next(e); }
};

// Reads  (any signed-in user)

/**
 * GET /api/tournaments — browse (FE-2).
 *
 * `openOnly` defaults to true, so the default answer to "what tournaments are
 * there" is the ones a team can still enter. `?openOnly=false` widens it to the
 * archive, which is what the "past tournaments" tab and a leaderboard need.
 */
router.get('/', guard(async (req, res) => {
  const openOnly = String(req.query.openOnly ?? 'true') !== 'false';
  send(res, await svc.browseRead({
    sport: req.query.sport || null,
    city: req.query.city || null,
    startFrom: req.query.startFrom || req.query.from || null,
    status: req.query.status || null,
    q: req.query.q || '',
    venueId: req.query.venueId || null,
    ownerId: req.query.ownerId || null,
    openOnly,
    limit: req.query.limit,
  }));
}));

/** GET /api/tournaments/mine — my tournaments, as organiser and as player. */
router.get('/mine', guard(async (req, res) => {
  send(res, await svc.mineRead({ userId: req.user.id, limit: req.query.limit }));
}));

/**
 * POST /api/tournaments/preview — the economics quote, owner only (FE-1).
 *
 * A POST that writes nothing, because the quote depends on the whole draft
 * configuration — format, both team counts, the four percentages, the slot length
 * and the deadline — and putting a dozen fields in a query string to preserve the
 * verb would be worse than the small dishonesty of POSTing a read.
 */
router.post('/preview', checkRole('owner'), guard(async (req, res) => {
  send(res, await svc.previewRead({ ...req.body, ownerId: req.user.id }));
}));

/** GET /api/tournaments/:id — the public overview, plus the organiser's view. */
router.get('/:id', guard(async (req, res) => {
  send(res, await svc.detailRead({ tournamentId: req.params.id, userId: req.user.id }));
}));

// Owner writes  (FE-1, FE-5, FE-6, FE-7)

/** POST /api/tournaments — post a tournament at one of my own venues (FE-1). */
router.post('/', checkRole('owner'), guard(async (req, res) => {
  send(res, await svc.createTx({ ...req.body, ownerId: req.user.id }), { createdStatus: 201 });
}));

/**
 * POST /api/tournaments/:id/generate — draw the bracket now (FE-6).
 *
 * `useModel: false` forces the chronological path, which is how the demo proves the
 * scheduler's provenance stamp means something: the same tournament, generated both
 * ways, produces `meta.scheduling.source = 'model'` and `'chronological'`.
 */
router.post('/:id/generate', checkRole('owner'), guard(async (req, res) => {
  send(res, await svc.generateFixturesTx({
    actorId: req.user.id,
    tournamentId: req.params.id,
    useModel: req.body?.useModel !== false,
  }));
}));

/** PATCH /api/tournaments/:id/teams/:teamId — approve · reject · remove (FE-5). */
router.patch('/:id/teams/:teamId', checkRole('owner'), guard(async (req, res) => {
  send(res, await svc.ownerDecisionTx({
    ownerId: req.user.id,
    tournamentId: req.params.id,
    teamId: req.params.teamId,
    decision: req.body?.decision,
    reason: req.body?.reason,
  }));
}));

/** PATCH /api/tournaments/:id/fixtures/:fid/result — organiser types the score (FE-7). */
router.patch('/:id/fixtures/:fid/result', checkRole('owner'), guard(async (req, res) => {
  send(res, await svc.settleFixtureTx({
    actorId: req.user.id,
    tournamentId: req.params.id,
    fixtureId: req.params.fid,
    scoreA: req.body?.scoreA,
    scoreB: req.body?.scoreB,
  }));
}));

/**
 * POST /api/tournaments/:id/fixtures/:fid/walkover — a team did not turn up.
 *
 * Separate from the result endpoint on purpose: a walkover is not a 3-0, it is "no
 * game was played", and the difference is visible in the ledger and the ratings —
 * `kFactorFor` returns 0, so nobody's ELO moves for a match nobody played.
 */
router.post('/:id/fixtures/:fid/walkover', checkRole('owner'), guard(async (req, res) => {
  send(res, await svc.walkoverTx({
    actorId: req.user.id,
    tournamentId: req.params.id,
    fixtureId: req.params.fid,
    winnerTeamId: req.body?.winnerTeamId,
    reason: req.body?.reason,
  }));
}));

/** POST /api/tournaments/:id/cancel — call it off and refund every entry. */
router.post('/:id/cancel', checkRole('owner'), guard(async (req, res) => {
  send(res, await svc.cancelTx({
    actorId: req.user.id,
    tournamentId: req.params.id,
    reason: req.body?.reason,
  }));
}));

// Captain writes  (FE-3)

/**
 * POST /api/tournaments/:id/register — enter a team and freeze the entry fee.
 *
 * The team comes from the body but the authority does not: the service reads
 * `teams.captain_id` inside the locked transaction, so sending someone else's team
 * id is a 403 and not an entry.
 */
router.post('/:id/register', checkRole('player'), guard(async (req, res) => {
  send(res, await svc.registerTx({
    userId: req.user.id,
    tournamentId: req.params.id,
    teamId: req.body?.teamId,
  }), { createdStatus: 201 });
}));

/** DELETE /api/tournaments/:id/register — pull out before the deadline, full refund. */
router.delete('/:id/register', checkRole('player'), guard(async (req, res) => {
  send(res, await svc.withdrawTx({
    userId: req.user.id,
    tournamentId: req.params.id,
    teamId: req.query.teamId || req.body?.teamId,
  }));
}));

module.exports = router;
