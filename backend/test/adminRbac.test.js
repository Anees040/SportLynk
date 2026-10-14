/**
 * adminRbac.test.js — the sub-admin authorisation tier, proved with the database off.
 *
 * Run:  npm test   (from backend/),  or  node --test test/adminRbac.test.js
 *
 * Three units, no network:
 *   • permissionMiddleware — the gate: super admin passes everything, a granted key
 *     passes its own route, a missing key is 403, no user is 401.
 *   • adminPermissions — the catalog is internally consistent and `sanitize` rejects
 *     an unknown key by name while de-duplicating and ordering a valid list.
 *   • adminManagementService — the create/update/remove/restore refusals, driven by a
 *     fake pg client (the same technique passwordReset.test.js uses).
 */
const test = require('node:test');
const assert = require('node:assert/strict');

const { requirePermission, requireSuperAdmin } = require('../src/middleware/permissionMiddleware');
const perms = require('../src/utils/adminPermissions');
const svc = require('../src/services/adminManagementService');

// Fakes

function mkRes() {
  return {
    statusCode: null,
    body: null,
    status(c) { this.statusCode = c; return this; },
    json(b) { this.body = b; return this; },
  };
}

/** Run a middleware and report whether it called next() or answered. */
function run(mw, user) {
  const req = { user };
  const res = mkRes();
  let nexted = false;
  mw(req, res, () => { nexted = true; });
  return { nexted, status: res.statusCode, body: res.body };
}

/** A fake pg client: records queries, returns what the responder yields for a match. */
function mkClient(responder) {
  const calls = [];
  return {
    calls,
    async query(sql, params) {
      calls.push({ sql, params });
      const out = responder ? responder(sql, params) : null;
      if (out instanceof Error) throw out;
      return out || { rows: [] };
    },
  };
}

const SUPER = { id: 's1', isSuperAdmin: true, permissions: [] };
const SUB = (p) => ({ id: 'u1', isSuperAdmin: false, permissions: p });

// permissionMiddleware

test('requirePermission: super admin passes any permission', () => {
  const r = run(requirePermission('user_management'), SUPER);
  assert.equal(r.nexted, true);
});

test('requirePermission: a granted key passes its own route', () => {
  const r = run(requirePermission('match_disputes'), SUB(['match_disputes']));
  assert.equal(r.nexted, true);
});

test('requirePermission: a missing key is refused 403', () => {
  const r = run(requirePermission('user_management'), SUB(['match_disputes']));
  assert.equal(r.nexted, false);
  assert.equal(r.status, 403);
  assert.equal(r.body.success, false);
  assert.match(r.body.message, /permission/i);
});

test('requirePermission: no user is 401, not 403', () => {
  const r = run(requirePermission('user_management'), undefined);
  assert.equal(r.status, 401);
});

test('requireSuperAdmin: only the super admin passes', () => {
  assert.equal(run(requireSuperAdmin, SUPER).nexted, true);
  const sub = run(requireSuperAdmin, SUB(['user_management', 'match_disputes']));
  assert.equal(sub.nexted, false);
  assert.equal(sub.status, 403);
});

// adminPermissions catalog

test('catalog: keys are unique and well-formed, and manage-admins is NOT grantable', () => {
  const keys = perms.PERMISSION_KEYS;
  assert.equal(new Set(keys).size, keys.length, 'keys are unique');
  assert.ok(keys.length >= 7, 'at least the seven surfaces');
  for (const p of perms.PERMISSIONS) {
    assert.ok(p.key && p.label && p.description, `${p.key} is fully described`);
  }
  assert.ok(!keys.includes('manage_admins'), 'managing admins is super-admin-only, never a key');
  assert.ok(!keys.includes('super_admin'), 'super admin is not a permission');
});

test('sanitize: a valid list is de-duplicated and ordered by the catalog', () => {
  const out = perms.sanitize(['match_disputes', 'owner_approvals', 'match_disputes']);
  assert.equal(out.ok, true);
  assert.deepEqual(out.permissions, ['owner_approvals', 'match_disputes']);
});

test('sanitize: an unknown key is rejected by name', () => {
  const out = perms.sanitize(['user_management', 'make_everything']);
  assert.equal(out.ok, false);
  assert.deepEqual(out.invalid, ['make_everything']);
  assert.deepEqual(out.permissions, ['user_management']);
});

test('sanitize: a non-list is refused', () => {
  assert.equal(perms.sanitize('user_management').ok, false);
  assert.equal(perms.sanitize(null).ok, false);
});

// adminManagementService — create

test('create: short name is refused before any query', async () => {
  const c = mkClient();
  const out = await svc.create(c, { creatorId: 's1', name: 'Al', email: 'a@b.com', password: 'longenough', permissions: [] });
  assert.equal(out.ok, false);
  assert.equal(out.code, 'name_required');
  assert.equal(c.calls.length, 0);
});

test('create: invalid email is refused', async () => {
  const out = await svc.create(mkClient(), { creatorId: 's1', name: 'Alice', email: 'not-an-email', password: 'longenough', permissions: [] });
  assert.equal(out.code, 'email_invalid');
});

test('create: short password is refused', async () => {
  const out = await svc.create(mkClient(), { creatorId: 's1', name: 'Alice', email: 'a@b.com', password: 'short', permissions: [] });
  assert.equal(out.code, 'password_short');
});

test('create: an unknown permission is refused by name', async () => {
  const out = await svc.create(mkClient(), {
    creatorId: 's1', name: 'Alice', email: 'a@b.com', password: 'longenough', permissions: ['owner_approvals', 'nope'],
  });
  assert.equal(out.code, 'bad_permissions');
  assert.match(out.message, /nope/);
});

test('create: a taken email is a 409', async () => {
  const c = mkClient((sql) => {
    if (/SELECT 1 FROM users WHERE email/.test(sql)) return { rows: [{ '?column?': 1 }] };
    return null;
  });
  const out = await svc.create(c, { creatorId: 's1', name: 'Alice', email: 'a@b.com', password: 'longenough', permissions: [] });
  assert.equal(out.ok, false);
  assert.equal(out.status, 409);
  assert.equal(out.code, 'email_taken');
});

test('create: a valid sub-admin is inserted with its permission set', async () => {
  const c = mkClient((sql) => {
    if (/SELECT 1 FROM users WHERE email/.test(sql)) return { rows: [] };
    if (/INSERT INTO users/.test(sql)) {
      return { rows: [{
        id: 'new-1', name: 'Alice', email: 'a@b.com', phone: null, role: 'admin',
        is_super_admin: false, admin_permissions: ['owner_approvals', 'match_disputes'],
        is_active: true, created_at: '2026-01-01T00:00:00Z',
      }] };
    }
    if (/INSERT INTO admin_audit/.test(sql)) return { rows: [{ id: 'audit-1' }] };
    return null;
  });
  const out = await svc.create(c, {
    creatorId: 's1', name: 'Alice', email: 'A@B.com', password: 'longenough',
    permissions: ['match_disputes', 'owner_approvals'],
  });
  assert.equal(out.ok, true);
  assert.equal(out.data.admin.email, 'a@b.com');
  assert.equal(out.data.admin.isSuperAdmin, false);
  assert.deepEqual(out.data.admin.permissions, ['owner_approvals', 'match_disputes']);
  // The INSERT fixed role='admin' and is_super_admin=false — a created account can
  // never be a second super admin.
  assert.ok(c.calls.some((q) => /INSERT INTO users/.test(q.sql) && /'admin', false/.test(q.sql)));
});

// adminManagementService — update / remove / restore refusals

const adminRow = (over = {}) => ({
  rows: [{
    id: 'u1', name: 'Bob', email: 'b@b.com', phone: null, role: 'admin',
    is_super_admin: false, admin_permissions: ['match_disputes'],
    is_active: true, created_at: '2026-01-01T00:00:00Z', ...over,
  }],
});

test('update: a missing admin is 404', async () => {
  const c = mkClient((sql) => (/FROM users WHERE id/.test(sql) ? { rows: [] } : null));
  const out = await svc.updatePermissions(c, { actorId: 's1', targetId: 'u1', permissions: [] });
  assert.equal(out.status, 404);
  assert.equal(out.code, 'not_found');
});

test('update: the super admin cannot be edited', async () => {
  const c = mkClient((sql) => (/FROM users WHERE id/.test(sql) ? adminRow({ is_super_admin: true }) : null));
  const out = await svc.updatePermissions(c, { actorId: 's1', targetId: 'u1', permissions: ['user_management'] });
  assert.equal(out.status, 403);
  assert.equal(out.code, 'is_super_admin');
});

test('remove: you cannot remove your own access', async () => {
  const out = await svc.remove(mkClient(), { actorId: 'u1', targetId: 'u1' });
  assert.equal(out.code, 'self');
});

test('remove: the super admin cannot be removed', async () => {
  const c = mkClient((sql) => (/FROM users WHERE id/.test(sql) ? adminRow({ is_super_admin: true }) : null));
  const out = await svc.remove(c, { actorId: 's1', targetId: 'u1' });
  assert.equal(out.status, 403);
  assert.equal(out.code, 'is_super_admin');
});

test('remove: a sub-admin is deactivated and its permissions cleared', async () => {
  const c = mkClient((sql) => {
    if (/FROM users WHERE id/.test(sql)) return adminRow();
    if (/UPDATE users/.test(sql)) return adminRow({ is_active: false, admin_permissions: [] });
    if (/INSERT INTO admin_audit/.test(sql)) return { rows: [{ id: 'a' }] };
    return null;
  });
  const out = await svc.remove(c, { actorId: 's1', targetId: 'u1' });
  assert.equal(out.ok, true);
  assert.equal(out.data.admin.active, false);
  assert.deepEqual(out.data.admin.permissions, []);
  // The UPDATE cleared the permission array, not just the active flag.
  assert.ok(c.calls.some((q) => /UPDATE users/.test(q.sql) && /admin_permissions = '\{\}'/.test(q.sql)));
});

test('restore: reactivates a removed sub-admin', async () => {
  const c = mkClient((sql) => {
    if (/FROM users WHERE id/.test(sql)) return adminRow({ is_active: false, admin_permissions: [] });
    if (/UPDATE users SET is_active = true/.test(sql)) return adminRow({ is_active: true, admin_permissions: [] });
    if (/INSERT INTO admin_audit/.test(sql)) return { rows: [{ id: 'a' }] };
    return null;
  });
  const out = await svc.restore(c, { actorId: 's1', targetId: 'u1' });
  assert.equal(out.ok, true);
  assert.equal(out.data.admin.active, true);
});
