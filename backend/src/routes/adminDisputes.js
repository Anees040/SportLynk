/**
 * adminDisputes.js — S.7 Wave D · FR10.6 / FR10.7. The dispute queue, the case
 * file, and the ruling.
 *
 * Mounting
 * Mounted into `routes/admin.js`, after its single
 * `router.use(auth, checkRole('admin'))` — the same reason as `adminUsers.js`:
 * one place in the codebase decides who is an admin, and a new admin surface must
 * not be able to forget to ask. Paths here are relative to `/api/admin`.
 *
 * Why the RULING is a service call and this file is thin
 * A ruling reverses a rating exchange, re-rates two teams, closes both sides'
 * disputes, unfreezes what the freeze was waiting on, advances a bracket and
 * writes an audit row — and either all of that is true or none of it is. So the
 * atomic part lives in `services/disputeService.js`, in one function that can be
 * read end to end, and this file owns only what a route should own: `BEGIN`, the
 * HTTP shape, and `emitAfterCommit` once the transaction is durable.
 *
 * Why the case file is a pool read and not a transaction
 * An admin reads a case file for minutes. Holding a transaction open for that is
 * how an idle-in-transaction session ends up sitting on rows the players are
 * trying to use.
 */
const express = require('express');
const router = express.Router();
const pool = require('../db/pool');
const disputes = require('../services/disputeService');
const mc = require('../utils/matchCore');

const RE_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Uniform failure, per the golden rule: every error is `{success:false,message}`. */
function bad(res, status, message) {
  return res.status(status).json({ success: false, message });
}

/**
 * GET /api/admin/disputes?status=open&cursor=&limit=
 *
 * Sorted by what is at stake, then by age — an admin with ten minutes should
 * spend them on the match that moves the most rating, not on whichever arrived
 * last. `status` is `open|resolved|dismissed|all`.
 */
router.get('/disputes', async (req, res, next) => {
  try {
    const out = await disputes.queue(pool, {
      status: req.query.status,
      cursor: req.query.cursor,
      limit: req.query.limit,
    });
    if (!out.ok) return bad(res, out.status, out.message);
    res.json({
      success: true,
      data: { items: out.items, nextCursor: out.nextCursor, count: out.items.length },
    });
  } catch (e) { next(e); }
});

/**
 * GET /api/admin/disputes/:id
 *
 * The case file: both submissions side by side, both rosters with trust scores,
 * the booking and the owner's check-in evidence, the ELO ledger for the match,
 * and the captain-channel chat archive — which is the literal FR10.6 requirement
 * and the reason Wave B was built before this one.
 */
router.get('/disputes/:id', async (req, res, next) => {
  const { id } = req.params;
  if (!RE_UUID.test(id)) return bad(res, 400, 'Invalid dispute id');
  try {
    const out = await disputes.caseFile(pool, id);
    if (!out.ok) return bad(res, out.status, out.message);
    const { ok, ...data } = out;
    res.json({ success: true, data });
  } catch (e) { next(e); }
});

/**
 * PATCH /api/admin/disputes/:id
 *   { action: 'rule_challenger'|'rule_opponent'|'rule_draw'|'rule_custom'|'dismiss',
 *     scoreChallenger?, scoreOpponent?, note }
 *
 * One transaction, through the same path as the owner's
 * `POST /api/matches/:id/verify`: lock the match, rate inside the transaction,
 * stamp `elo_applied`, advance the bracket, then fan out. `note` is required — the
 * teams are told what it says, so a ruling with no explanation is not a ruling.
 *
 * After commit, and only after, `mc.emitAfterCommit` pushes the chat pills and the
 * `match:update` frames. Emitting inside the transaction would tell both apps to
 * re-fetch a match that is not committed yet, and they would read the old one.
 */
router.patch('/disputes/:id', async (req, res, next) => {
  const { id } = req.params;
  if (!RE_UUID.test(id)) return bad(res, 400, 'Invalid dispute id');

  const body = req.body || {};
  const client = await pool.connect();
  let out;
  try {
    await client.query('BEGIN');
    out = await disputes.rule(client, {
      disputeId: id,
      adminId: req.user.id,
      action: body.action,
      scoreChallenger: body.scoreChallenger,
      scoreOpponent: body.scoreOpponent,
      note: body.note,
    });
    if (!out.ok) {
      await client.query('ROLLBACK');
      return res.status(out.status).json({
        success: false,
        message: out.message,
        ...(out.code ? { code: out.code } : {}),
      });
    }
    await client.query('COMMIT');
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    return next(e);
  } finally {
    client.release();
  }

  // Durable now. Nothing below may turn a completed ruling into a 500.
  await mc.emitAfterCommit(pool, {
    matchId: out.matchId,
    pills: out.pills,
    memberIds: out.memberIds,
    extra: { event: 'ruled', ruling: out.ruling },
  }).catch(() => {});

  const { ok, pills, memberIds, ...data } = out;
  res.json({ success: true, message: messageFor(out), data });
});

/**
 * The one sentence an admin reads after ruling. It says out loud the two things
 * they cannot see from the row: whether any rating moved, and whether the
 * bracket followed. `already_settled` means this fixture's winner had already
 * advanced — the rating is corrected, the bracket is not rewritten, and pretending
 * otherwise is how a tournament ends up with a final nobody can explain.
 */
function messageFor(out) {
  const parts = [];
  if (out.action === disputes.ACTION.DISMISS) {
    parts.push('Dispute dismissed — the original result stands.');
  } else {
    parts.push(`Ruled ${out.scoreline.challenger}–${out.scoreline.opponent}.`);
    if (out.eloMode === 'applied') parts.push('Ratings applied.');
    else if (out.eloMode === 'corrected') parts.push('Previous ratings reversed and re-applied.');
    else if (out.eloMode === 'unchanged') parts.push('Ratings already matched this result — unchanged.');
    if (out.exchange && out.exchange.frozen) parts.push('One team is still frozen, so no points moved.');
  }
  if (out.unfroze && out.unfroze.length) {
    parts.push(`${out.unfroze.length === 2 ? 'Both teams' : 'One team'} unfrozen.`);
  }
  if (out.bracket === 'already_settled') {
    parts.push('This fixture had already advanced, so the bracket was left as it is.');
  } else if (out.advanced) {
    parts.push('Bracket advanced.');
  }
  if (out.closed > 1) parts.push(`${out.closed} disputes closed.`);
  return parts.join(' ');
}

module.exports = router;
