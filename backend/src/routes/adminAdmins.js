/**
 * adminAdmins.js — the super-admin-only surface for managing the admin tier.
 *
 * Mounted into `routes/admin.js`, so it already sits behind that file's single
 * `auth, checkRole('admin')`. On top of that, the whole router requires the super
 * admin specifically (`requireSuperAdmin`): creating admins and granting powers is not
 * a delegable permission, so there is always one accountable owner. Paths are relative
 * to `/api/admin`.
 *
 * The rules live in `services/adminManagementService.js`; this file owns only the HTTP
 * shape, the transaction, and the `authMiddleware.invalidate(id)` that makes a
 * permission or access change take effect on the target's very next request.
 */
const express = require('express');
const router = express.Router();
const pool = require('../db/pool');
const authMiddleware = require('../middleware/authMiddleware');
const { requireSuperAdmin } = require('../middleware/permissionMiddleware');
const perms = require('../utils/adminPermissions');
const admins = require('../services/adminManagementService');

const RE_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function bad(res, status, message) {
  return res.status(status).json({ success: false, message });
}

// requireSuperAdmin guards each route individually below, not as a router-level
// `use`: this sub-router is mounted at '/' in admin.js, so a `router.use` gate would
// run for — and 403 — every admin request that falls through it, not only its own.

/** GET /api/admin/permissions — the catalog the Manage Admins screen renders from. */
router.get('/permissions', requireSuperAdmin, (req, res) => {
  res.json({ success: true, data: { permissions: perms.PERMISSIONS } });
});

/** GET /api/admin/admins — every admin account, super admin first. */
router.get('/admins', requireSuperAdmin, async (req, res, next) => {
  try {
    const out = await admins.list(pool);
    res.json({ success: true, data: { admins: out.admins } });
  } catch (e) { next(e); }
});

/**
 * POST /api/admin/admins  { name, email, password, phone?, permissions[] }
 * Create a new sub-admin login with the chosen permission subset.
 */
router.post('/admins', requireSuperAdmin, async (req, res, next) => {
  const b = req.body || {};
  const client = await pool.connect();
  let out;
  try {
    await client.query('BEGIN');
    out = await admins.create(client, {
      creatorId: req.user.id,
      name: b.name,
      email: b.email,
      phone: b.phone,
      password: b.password,
      permissions: b.permissions,
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
  res.status(201).json({ success: true, message: out.message, data: out.data });
});

/**
 * PATCH /api/admin/admins/:id  { permissions[], name? }
 * Replace a sub-admin's granted permissions (and optionally rename them).
 */
router.patch('/admins/:id', requireSuperAdmin, async (req, res, next) => {
  const { id } = req.params;
  if (!RE_UUID.test(id)) return bad(res, 400, 'Invalid admin id');
  const b = req.body || {};
  const client = await pool.connect();
  let out;
  try {
    await client.query('BEGIN');
    out = await admins.updatePermissions(client, {
      actorId: req.user.id,
      targetId: id,
      name: b.name,
      permissions: b.permissions,
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
  // The change is authoritative from the row; drop the cached account state so the
  // sub-admin's next request reads the new permissions instead of waiting out the TTL.
  authMiddleware.invalidate(id);
  res.json({ success: true, message: out.message, data: out.data });
});

/**
 * DELETE /api/admin/admins/:id — remove a sub-admin's access (deactivate + clear
 * permissions). Reversible via POST /admins/:id/restore.
 */
router.delete('/admins/:id', requireSuperAdmin, async (req, res, next) => {
  const { id } = req.params;
  if (!RE_UUID.test(id)) return bad(res, 400, 'Invalid admin id');
  const client = await pool.connect();
  let out;
  try {
    await client.query('BEGIN');
    out = await admins.remove(client, { actorId: req.user.id, targetId: id });
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

/** POST /api/admin/admins/:id/restore — reactivate a removed sub-admin. */
router.post('/admins/:id/restore', requireSuperAdmin, async (req, res, next) => {
  const { id } = req.params;
  if (!RE_UUID.test(id)) return bad(res, 400, 'Invalid admin id');
  const client = await pool.connect();
  let out;
  try {
    await client.query('BEGIN');
    out = await admins.restore(client, { actorId: req.user.id, targetId: id });
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

module.exports = router;
