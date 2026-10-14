-- ════════════════════════════════════════════════════════════════════════════
-- 040_admin_rbac.sql   ·   super admin + per-admin permissions
-- ════════════════════════════════════════════════════════════════════════════
--
-- Until now every `role='admin'` row could do everything the admin panel exposes:
-- the one `router.use(auth, checkRole('admin'))` gate in routes/admin.js is the
-- whole authorisation model. This adds a Meta-style tier on top of it:
--
--   is_super_admin     one account that holds every power and is the only one that
--                      may create or manage other admins. Singularity is enforced in
--                      the service and the bootstrap script (make_super_admin.js),
--                      not here, so the super admin can be transferred without a
--                      deferred-constraint dance.
--   admin_permissions  the subset of permission keys a SUB-admin has been granted
--                      (see utils/adminPermissions.js). Ignored for the super admin,
--                      who passes every check implicitly; empty for a non-admin.
--
-- Purely additive: two columns with safe defaults, no existing row rewritten and no
-- DROP/TRUNCATE/DELETE. Every current admin keeps working as a non-super admin with
-- an empty permission set until the bootstrap promotes one to super admin and grants
-- the rest. authMiddleware tolerates these columns being absent (it falls back to the
-- legacy is_active/role read), so applying this before or after a code deploy is safe.

ALTER TABLE users
  ADD COLUMN IF NOT EXISTS is_super_admin    boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS admin_permissions text[]  NOT NULL DEFAULT '{}',
  ALTER COLUMN phone DROP NOT NULL;

COMMENT ON COLUMN users.is_super_admin IS
  'The single super admin: holds every admin power and is the only account that can '
  'manage other admins. Singularity enforced in adminManagementService + make_super_admin.js.';
COMMENT ON COLUMN users.admin_permissions IS
  'Permission keys granted to a sub-admin (see utils/adminPermissions.js). Ignored for '
  'the super admin (who passes everything); empty for non-admins.';
