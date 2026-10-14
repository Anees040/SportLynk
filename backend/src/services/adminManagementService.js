/**
 * adminManagementService.js — create and manage the admin tier (FR10.* extension).
 *
 * The super admin is the only caller: the routes in `routes/adminAdmins.js` sit behind
 * `requireSuperAdmin`. This file owns the rules that must hold regardless of the UI:
 *
 *   • there is only ever one super admin — this service never creates a second, and
 *     refuses to edit or remove the one that exists (its powers are not a grantable
 *     set, so there is nothing to edit);
 *   • a sub-admin is an ordinary `role='admin'` account with a bcrypt password and a
 *     granted subset of `utils/adminPermissions.js`, so it logs in through the same
 *     email+password path as everyone else;
 *   • "remove" deactivates rather than deletes. `disputes.resolved_by` and
 *     `matches.verified_by` reference `users(id)` with no cascade, so deleting an admin
 *     who ever ruled or verified would fail outright and, worse, would erase the audit
 *     trail (admin_audit.admin_id is ON DELETE SET NULL for exactly that reason). A
 *     deactivated admin cannot log in (authMiddleware + login both check is_active) and
 *     can be restored.
 *
 * Writes take a caller-owned `client` so the route owns the transaction, the audit row
 * and the authMiddleware cache invalidation — the same division of labour as
 * `adminUsers.js` / `suspensionService.js`. Nothing here throws for a business refusal;
 * it returns `{ ok:false, status, code, message }`.
 */
const bcrypt = require('bcrypt');
const perms = require('../utils/adminPermissions');
const audit = require('../utils/adminAudit');

const BCRYPT_COST = 12; // matches routes/auth.js
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const PHONE_RE = /^03\d{9}$/;

function fail(status, code, message) {
  return { ok: false, status, code, message };
}
function done(data, message) {
  return { ok: true, status: 200, data, message };
}

/** One admin row as the API returns it. `active` is derived from is_active. */
function shapeAdmin(u) {
  return {
    id: u.id,
    name: u.name,
    email: u.email || null,
    phone: u.phone || null,
    isSuperAdmin: u.is_super_admin === true,
    permissions: Array.isArray(u.admin_permissions) ? u.admin_permissions : [],
    active: u.is_active !== false,
    createdAt: u.created_at,
  };
}

const SELECT_COLS = `id, name, email, phone, role, is_super_admin, admin_permissions,
                     is_active, created_at`;

/**
 * Every admin account (super admin first, then newest), for the management screen.
 * Reads on the pool — it is a plain list, no transaction.
 */
async function list(db) {
  const { rows } = await db.query(
    `SELECT ${SELECT_COLS} FROM users
      WHERE role = 'admin'
      ORDER BY is_super_admin DESC, created_at DESC, id DESC`,
  );
  return { ok: true, admins: rows.map(shapeAdmin) };
}

/** Fetch one admin row (any state), or null. */
async function getAdmin(db, id) {
  const { rows } = await db.query(
    `SELECT ${SELECT_COLS} FROM users WHERE id = $1 AND role = 'admin'`,
    [id],
  );
  return rows[0] || null;
}

/**
 * Create a new sub-admin login. Validates the same way routes/auth.js validates a
 * registration, plus the permission set. Never creates a super admin — that is the
 * bootstrap script's job alone, so the single-owner rule cannot be bypassed from the
 * app.
 */
async function create(client, {
  creatorId, name, email, phone, password, permissions,
}) {
  const nm = String(name || '').trim();
  if (nm.length < 3) return fail(400, 'name_required', 'Name must be at least 3 characters.');

  const em = String(email || '').trim().toLowerCase();
  if (!EMAIL_RE.test(em)) return fail(400, 'email_invalid', 'A valid email is required — it is how the admin logs in.');

  if (!password || String(password).length < 8) {
    return fail(400, 'password_short', 'Password must be at least 8 characters.');
  }

  const ph = String(phone || '').replace(/\s/g, '');
  if (ph && !PHONE_RE.test(ph)) {
    return fail(400, 'phone_invalid', 'Phone must be a valid Pakistani number (03XXXXXXXXX).');
  }

  const clean = perms.sanitize(permissions);
  if (!clean.ok) {
    return fail(400, 'bad_permissions', `Unknown permission: ${clean.invalid.join(', ')}.`);
  }

  const dupEmail = await client.query('SELECT 1 FROM users WHERE email = $1', [em]);
  if (dupEmail.rows.length) return fail(409, 'email_taken', 'That email is already registered.');
  if (ph) {
    const dupPhone = await client.query('SELECT 1 FROM users WHERE phone = $1', [ph]);
    if (dupPhone.rows.length) return fail(409, 'phone_taken', 'That phone number is already registered.');
  }

  const hash = await bcrypt.hash(String(password), BCRYPT_COST);
  const { rows } = await client.query(
    `INSERT INTO users (name, email, phone, password_hash, role, is_super_admin,
                        admin_permissions, phone_verified, is_active)
     VALUES ($1, $2, $3, $4, 'admin', false, $5, true, true)
     RETURNING ${SELECT_COLS}`,
    [nm, em, ph || null, hash, clean.permissions],
  );
  const row = rows[0];

  await audit.audit(client, {
    adminId: creatorId,
    action: audit.ACTIONS.ADMIN_CREATE,
    entityType: 'admin',
    entityId: row.id,
    before: null,
    after: { email: row.email, permissions: row.admin_permissions },
  });

  return done({ admin: shapeAdmin(row) }, 'Sub-admin created.');
}

/**
 * Change a sub-admin's granted permissions (and, optionally, their display name).
 * Refuses on the super admin: their powers are implicit and total, so there is no set
 * to edit. The route invalidates the authMiddleware cache for the target afterward.
 */
async function updatePermissions(client, {
  actorId, targetId, name, permissions,
}) {
  const target = await getAdmin(client, targetId);
  if (!target) return fail(404, 'not_found', 'Admin not found.');
  if (target.is_super_admin) {
    return fail(403, 'is_super_admin', 'The super admin already holds every permission.');
  }

  const clean = perms.sanitize(permissions);
  if (!clean.ok) {
    return fail(400, 'bad_permissions', `Unknown permission: ${clean.invalid.join(', ')}.`);
  }

  const nm = name === undefined || name === null ? null : String(name).trim();
  if (nm !== null && nm.length < 3) {
    return fail(400, 'name_required', 'Name must be at least 3 characters.');
  }

  const before = { name: target.name, permissions: target.admin_permissions };
  const { rows } = await client.query(
    `UPDATE users
        SET admin_permissions = $2,
            name = COALESCE($3, name)
      WHERE id = $1 AND role = 'admin'
      RETURNING ${SELECT_COLS}`,
    [targetId, clean.permissions, nm],
  );
  const row = rows[0];

  await audit.audit(client, {
    adminId: actorId,
    action: audit.ACTIONS.ADMIN_UPDATE,
    entityType: 'admin',
    entityId: targetId,
    before,
    after: { name: row.name, permissions: row.admin_permissions },
  });

  return done({ admin: shapeAdmin(row) }, 'Permissions updated.');
}

/**
 * Remove a sub-admin's access: deactivate and clear their permissions. Reversible via
 * `restore`. Refuses on the super admin and on the actor removing themselves.
 */
async function remove(client, { actorId, targetId }) {
  if (String(actorId) === String(targetId)) {
    return fail(400, 'self', 'You cannot remove your own access.');
  }
  const target = await getAdmin(client, targetId);
  if (!target) return fail(404, 'not_found', 'Admin not found.');
  if (target.is_super_admin) {
    return fail(403, 'is_super_admin', 'The super admin cannot be removed.');
  }
  if (target.is_active === false) {
    return fail(409, 'already_removed', 'That admin has already been removed.');
  }

  const { rows } = await client.query(
    `UPDATE users
        SET is_active = false, admin_permissions = '{}'
      WHERE id = $1 AND role = 'admin'
      RETURNING ${SELECT_COLS}`,
    [targetId],
  );
  const row = rows[0];

  await audit.audit(client, {
    adminId: actorId,
    action: audit.ACTIONS.ADMIN_REMOVE,
    entityType: 'admin',
    entityId: targetId,
    before: { active: true, permissions: target.admin_permissions },
    after: { active: false, permissions: [] },
  });

  return done({ admin: shapeAdmin(row) }, 'Admin access removed.');
}

/**
 * Restore a previously removed sub-admin — reactivate the login. Permissions were
 * cleared on removal, so the super admin re-grants them separately (an explicit step,
 * not an accidental re-grant of whatever they held before).
 */
async function restore(client, { actorId, targetId }) {
  const target = await getAdmin(client, targetId);
  if (!target) return fail(404, 'not_found', 'Admin not found.');
  if (target.is_super_admin) {
    return fail(400, 'is_super_admin', 'The super admin is already active.');
  }
  if (target.is_active !== false) {
    return fail(409, 'already_active', 'That admin is already active.');
  }

  const { rows } = await client.query(
    `UPDATE users SET is_active = true
      WHERE id = $1 AND role = 'admin'
      RETURNING ${SELECT_COLS}`,
    [targetId],
  );

  await audit.audit(client, {
    adminId: actorId,
    action: audit.ACTIONS.ADMIN_RESTORE,
    entityType: 'admin',
    entityId: targetId,
    before: { active: false },
    after: { active: true },
  });

  return done({ admin: shapeAdmin(rows[0]) }, 'Admin access restored.');
}

module.exports = {
  list,
  getAdmin,
  create,
  updatePermissions,
  remove,
  restore,
  shapeAdmin,
};
