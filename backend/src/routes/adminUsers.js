/**
 * adminUsers.js — S.7 Wave D · FR10.8. The user list, and suspension.
 *
 * Mounting
 * This router is mounted into `routes/admin.js`, after its
 * `router.use(auth, checkRole('admin'))`. That is deliberate: there is exactly
 * one place in the codebase that decides who is an admin, and a new admin surface
 * must not be able to forget to ask. Paths here are therefore relative to
 * `/api/admin`.
 *
 * Why suspension is a service call and not SQL in this file
 * See `services/suspensionService.js`: flipping `is_active` is one line, and
 * unwinding the bookings, tournaments, challenges and venues the account is
 * holding is the other three hundred. The route's whole job is the transaction,
 * the audit id, the cache invalidation and the socket flush.
 */
const express = require('express');
const router = express.Router();
const pool = require('../db/pool');
const authMiddleware = require('../middleware/authMiddleware');
const suspension = require('../services/suspensionService');
const chat = require('../utils/chatCore');
const mc = require('../utils/matchCore');

const RE_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PAGE_MAX = 50;

/** Uniform failure, per the golden rule: every error is `{success:false,message}`. */
function bad(res, status, message) {
  return res.status(status).json({ success: false, message });
}

/**
 * GET /api/admin/users?q=&role=&status=&limit=&cursor=
 *
 * `q` matches name, email or phone. `status` is `active|suspended|all`.
 * Keyset-paginated on `(created_at, id)` — the same shape as every other list in
 * the app, and the reason there is no OFFSET here: an admin suspending accounts
 * while paging would otherwise see rows shift under them.
 */
router.get('/users', async (req, res, next) => {
  try {
    const q = String(req.query.q || '').trim().slice(0, 80);
    const role = String(req.query.role || '').trim();
    const status = String(req.query.status || 'all').trim();
    const limit = Math.min(Math.max(parseInt(req.query.limit, 10) || 25, 1), PAGE_MAX);

    const where = [];
    const params = [];
    if (q) {
      params.push(`%${q}%`);
      where.push(`(u.name ILIKE $${params.length} OR u.email ILIKE $${params.length} OR u.phone ILIKE $${params.length})`);
    }
    if (['player', 'owner', 'admin'].includes(role)) {
      params.push(role);
      where.push(`u.role = $${params.length}`);
    }
    if (status === 'active') where.push('u.is_active IS NOT false');
    else if (status === 'suspended') where.push('u.is_active = false');

    // The cursor is `<created_at>~<id>`, opaque to the client exactly like the
    // notification feed's, so its shape can change without a client release.
    const cursor = String(req.query.cursor || '');
    if (cursor.includes('~')) {
      const [ts, id] = cursor.split('~');
      if (RE_UUID.test(id || '')) {
        params.push(ts, id);
        where.push(`(u.created_at, u.id) < ($${params.length - 1}::timestamptz, $${params.length}::uuid)`);
      }
    }

    params.push(limit + 1);
    const { rows } = await pool.query(
      `SELECT u.id, u.name, u.email, u.phone, u.role, u.avatar_url,
              u.is_active, u.created_at, u.suspended_at, u.suspended_reason,
              su.name AS suspended_by_name,
              (SELECT count(*)::int FROM bookings b WHERE b.player_id = u.id) AS bookings,
              (SELECT count(*)::int FROM venues v WHERE v.owner_id = u.id) AS venues,
              COALESCE(w.balance, 0) AS wallet_balance,
              COALESCE(w.frozen_balance, 0) AS wallet_frozen
         FROM users u
         LEFT JOIN users su ON su.id = u.suspended_by
         LEFT JOIN wallets w ON w.user_id = u.id
        ${where.length ? `WHERE ${where.join(' AND ')}` : ''}
        ORDER BY u.created_at DESC, u.id DESC
        LIMIT $${params.length}`,
      params,
    );

    const hasMore = rows.length > limit;
    const page = hasMore ? rows.slice(0, limit) : rows;
    res.json({
      success: true,
      data: {
        items: page.map(shapeUser),
        hasMore,
        nextCursor: hasMore && page.length
          ? `${new Date(page[page.length - 1].created_at).toISOString()}~${page[page.length - 1].id}`
          : null,
      },
    });
  } catch (e) { next(e); }
});

/** One row of the admin list. `suspended` is derived, never a second column. */
function shapeUser(u) {
  return {
    id: u.id,
    name: u.name,
    email: u.email,
    phone: u.phone || null,
    role: u.role,
    avatarUrl: u.avatar_url || null,
    suspended: u.is_active === false,
    suspendedAt: u.suspended_at || null,
    suspendedReason: u.suspended_reason || null,
    suspendedByName: u.suspended_by_name || null,
    createdAt: u.created_at,
    counts: { bookings: u.bookings, venues: u.venues },
    wallet: { balance: Number(u.wallet_balance), frozen: Number(u.wallet_frozen) },
  };
}

/**
 * PATCH /api/admin/users/:id/suspend   { reason }
 *
 * One transaction: the flag, the cascade (bookings refunded, tournaments
 * withdrawn, challenges expired, venues closed), the user's notification and the
 * audit row. Either all of that is true or none of it is.
 *
 * After the commit, three things happen in this order and for these reasons:
 *   1. `authMiddleware.invalidate(id)` — the ban takes effect on the very next
 *      request instead of at the end of the 30 s TTL. It must come after COMMIT:
 *      invalidating first would let the next request re-read the still-uncommitted
 *      row and cache "active" for another half minute.
 *   2. the chat pills, so the affected rooms show what happened live.
 *   3. the match fan-outs, so both apps redraw the cancelled challenges.
 * None of the three can fail the suspension — it is already durable.
 */
router.patch('/users/:id/suspend', async (req, res, next) => {
  const { id } = req.params;
  if (!RE_UUID.test(id)) return bad(res, 400, 'Invalid user id');

  const client = await pool.connect();
  let out;
  try {
    await client.query('BEGIN');
    out = await suspension.suspend(client, {
      adminId: req.user.id,
      userId: id,
      reason: req.body && req.body.reason,
    });
    if (!out.ok) {
      await client.query('ROLLBACK');
      return bad(res, out.status, out.message);
    }
    await client.query('COMMIT');
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    return next(e);
  } finally {
    client.release();
  }

  authMiddleware.invalidate(id);
  await flush(out);
  res.json({ success: true, message: out.message, data: out.data });
});

/**
 * PATCH /api/admin/users/:id/reinstate   { note? }
 *
 * Lifts the ban and re-lists the venues this suspension took down (read back from
 * its audit row — see the service). Nothing else is restored, because a refunded
 * booking cannot be un-refunded.
 */
router.patch('/users/:id/reinstate', async (req, res, next) => {
  const { id } = req.params;
  if (!RE_UUID.test(id)) return bad(res, 400, 'Invalid user id');

  const client = await pool.connect();
  let out;
  try {
    await client.query('BEGIN');
    out = await suspension.reinstate(client, {
      adminId: req.user.id,
      userId: id,
      note: req.body && req.body.note,
    });
    if (!out.ok) {
      await client.query('ROLLBACK');
      return bad(res, out.status, out.message);
    }
    await client.query('COMMIT');
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    return next(e);
  } finally {
    client.release();
  }

  authMiddleware.invalidate(id);
  res.json({ success: true, message: out.message, data: out.data });
});

/**
 * Post-commit socket work. Every emit is individually caught: a dropped socket
 * frame must never turn a completed suspension into a 500.
 */
async function flush(out) {
  for (const pill of out.pills || []) {
    await chat.emitPills(pool, pill).catch(() => {});
  }
  for (const f of out.fans || []) {
    if (!f.fan) continue;
    await mc.emitAfterCommit(pool, {
      matchId: f.matchId, ...f.fan, extra: { event: 'cancelled' },
    }).catch(() => {});
  }
}

module.exports = router;
