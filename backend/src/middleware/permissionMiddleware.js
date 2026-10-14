/**
 * permissionMiddleware.js — the sub-admin authorisation gate.
 *
 * Layered UNDER the single `auth, checkRole('admin')` in routes/admin.js, never in
 * place of it: by the time these run, the caller is already a verified admin. These
 * narrow that to a specific power.
 *
 * `req.user.isSuperAdmin` and `req.user.permissions` are populated by
 * authMiddleware from the account row (not the JWT), so a permission change takes
 * effect on the next request without a re-login — the same "the row wins" rule the
 * role already follows. The super admin passes every check implicitly, which is why
 * there is no 'manage_admins' permission key: that power is super-admin-only.
 */

/** The one refusal shape, matching the golden rule every error uses. */
function deny(res, message) {
  return res.status(403).json({ success: false, message });
}

/**
 * Require one named permission. Returns middleware so a route can read:
 *   router.use(requirePermission('user_management'))
 *   router.patch('/x', requirePermission('match_disputes'), handler)
 */
function requirePermission(key) {
  return (req, res, next) => {
    const u = req.user;
    if (!u) return res.status(401).json({ success: false, message: 'Unauthorized' });
    if (u.isSuperAdmin) return next();
    if (Array.isArray(u.permissions) && u.permissions.includes(key)) return next();
    return deny(res, 'You do not have permission for this action.');
  };
}

/** Require the super admin specifically — for the admin-management surface itself. */
function requireSuperAdmin(req, res, next) {
  const u = req.user;
  if (!u) return res.status(401).json({ success: false, message: 'Unauthorized' });
  if (u.isSuperAdmin) return next();
  return deny(res, 'Only the super admin can manage administrators.');
}

module.exports = { requirePermission, requireSuperAdmin };
