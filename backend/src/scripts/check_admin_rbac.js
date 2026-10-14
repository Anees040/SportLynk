/**
 * check_admin_rbac.js — the sub-admin tier, driven against the real database inside
 * one transaction that is always rolled back.
 *
 * Usage:  node src/scripts/check_admin_rbac.js
 *         node src/scripts/check_admin_rbac.js --verify-clean
 *
 * What this proves that npm test cannot
 * `test/adminRbac.test.js` proves the middleware and the service refusals with the
 * database off, using a fake client. This proves the same create/update/remove path
 * against the REAL `users` table — that migration 040's columns exist, that their
 * defaults are what the code assumes, and that a row the service wrote reads back as a
 * req.user the gate accepts or denies correctly.
 *
 * Why enforcement is checked from the written row, not through authMiddleware
 * `authMiddleware.accountState` reads through the pool and cannot see a row created
 * inside this transaction (the same constraint check_admin.js Block 8 documents). So
 * rather than commit a throwaway admin, this reads each written row back in the same
 * transaction, builds the exact `req.user` authMiddleware would, and runs the real
 * `requirePermission` / `requireSuperAdmin` against it. The authMiddleware pool-read
 * wiring (and is_active enforcement) is already covered by check_admin.js Block 8;
 * this file owns the permission arithmetic end to end, and leaves no row behind.
 *
 *   ✗  a rule broke. The line names it.
 */
const pool = require('../db/pool');
const svc = require('../services/adminManagementService');
const { requirePermission, requireSuperAdmin } = require('../middleware/permissionMiddleware');

const PREFIX = 'zzrbac-';
const VERIFY_CLEAN = process.argv.slice(2).includes('--verify-clean');

const failures = [];
let passed = 0;

function section(t) { console.log(`\n── ${t} ${'─'.repeat(Math.max(0, 60 - t.length))}`); }
function check(ok, label, detail = '') {
  if (ok) { passed += 1; console.log(`  ✓ ${label}`); return true; }
  failures.push(label);
  console.log(`  ✗ ${label}${detail ? `  → ${detail}` : ''}`);
  return false;
}
function eq(got, want, label) {
  return check(JSON.stringify(got) === JSON.stringify(want), label,
    `got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
}

/** Run a gate middleware against a req.user and report whether it called next(). */
function gate(mw, user) {
  const req = { user };
  let code = null;
  let nexted = false;
  const res = { status(c) { code = c; return res; }, json() { return res; } };
  mw(req, res, () => { nexted = true; });
  return { nexted, code };
}

/** Build the req.user authMiddleware would, from a fresh read of the row. */
async function reqUserFor(client, id) {
  const { rows } = await client.query(
    'SELECT is_super_admin, admin_permissions, is_active FROM users WHERE id = $1', [id],
  );
  const r = rows[0];
  return {
    row: r,
    user: {
      id,
      isSuperAdmin: r.is_super_admin === true,
      permissions: Array.isArray(r.admin_permissions) ? r.admin_permissions : [],
    },
  };
}

let seq = 0;
async function makeSuperAdmin(client) {
  seq += 1;
  const { rows } = await client.query(
    `INSERT INTO users (email, password_hash, name, role, is_super_admin,
                        admin_permissions, phone_verified, is_active)
     VALUES ($1, 'x', $2, 'admin', true, '{}', true, true)
     RETURNING id`,
    [`${PREFIX}super${seq}@sportlynk.test`, `${PREFIX}super`],
  );
  return rows[0].id;
}

async function main() {
  const client = await pool.connect();
  try {
    if (VERIFY_CLEAN) {
      const { rows } = await client.query(
        'SELECT count(*)::int AS n FROM users WHERE email LIKE $1', [`${PREFIX}%`]);
      eq(rows[0].n, 0, 'no zzrbac- user exists in the database');
      return;
    }

    // The columns must be present, or nothing below means anything.
    const cols = await client.query(
      `SELECT count(*)::int AS n FROM information_schema.columns
        WHERE table_schema='public' AND table_name='users'
          AND column_name IN ('is_super_admin','admin_permissions')`);
    if (cols.rows[0].n !== 2) {
      console.log('\n  ✗ migration 040 is not applied — run run_migration_040_admin_rbac.js first.');
      failures.push('migration 040 applied');
      return;
    }

    await client.query('BEGIN');
    const superId = await makeSuperAdmin(client);

    section('Block 1 · The super admin passes every gate');
    const sup = await reqUserFor(client, superId);
    eq(sup.row.is_super_admin, true, 'the fixture is a super admin');
    check(gate(requirePermission('user_management'), sup.user).nexted, 'super admin passes user_management');
    check(gate(requirePermission('financial_reports'), sup.user).nexted, 'super admin passes financial_reports');
    check(gate(requireSuperAdmin, sup.user).nexted, 'super admin passes requireSuperAdmin');

    section('Block 2 · A sub-admin is created with exactly its granted set');
    const created = await svc.create(client, {
      creatorId: superId,
      name: `${PREFIX}Helper`,
      email: `${PREFIX}helper@sportlynk.test`,
      password: 'longenough1',
      permissions: ['match_disputes'],
    });
    check(created.ok, 'create succeeds', created.ok ? '' : `${created.code} ${created.message}`);
    const subId = created.ok ? created.data.admin.id : null;
    if (!subId) { await client.query('ROLLBACK'); return; }
    const sub = await reqUserFor(client, subId);
    eq(sub.row.is_super_admin, false, 'a created sub-admin is NEVER a super admin (singularity holds)');
    eq(sub.row.admin_permissions, ['match_disputes'], 'the row carries exactly the granted key');
    eq(sub.row.is_active, true, 'and is active');

    section('Block 3 · The gate accepts the granted surface and refuses the rest');
    check(gate(requirePermission('match_disputes'), sub.user).nexted, 'the sub-admin passes /disputes');
    const u = gate(requirePermission('user_management'), sub.user);
    check(!u.nexted && u.code === 403, 'and is 403 on /users');
    const s = gate(requirePermission('platform_settings'), sub.user);
    check(!s.nexted && s.code === 403, 'and 403 on /settings');
    const f = gate(requirePermission('financial_reports'), sub.user);
    check(!f.nexted && f.code === 403, 'and 403 on /reports/platform');
    const sa = gate(requireSuperAdmin, sub.user);
    check(!sa.nexted && sa.code === 403, 'and 403 on the admin-management surface');

    section('Block 4 · Editing permissions flips the gate on the next read');
    const upd = await svc.updatePermissions(client, {
      actorId: superId, targetId: subId, permissions: ['match_disputes', 'user_management'],
    });
    check(upd.ok, 'update succeeds', upd.ok ? '' : upd.message);
    const sub2 = await reqUserFor(client, subId);
    check(gate(requirePermission('user_management'), sub2.user).nexted,
      'user_management now passes (authMiddleware.invalidate makes this live in the route)');
    check(gate(requirePermission('match_disputes'), sub2.user).nexted, 'match_disputes still passes');

    section('Block 5 · Remove deactivates and clears, restore re-activates');
    const rem = await svc.remove(client, { actorId: superId, targetId: subId });
    check(rem.ok, 'remove succeeds', rem.ok ? '' : rem.message);
    const sub3 = await reqUserFor(client, subId);
    eq(sub3.row.is_active, false, 'the account is deactivated (authMiddleware then returns 403 on its next request)');
    eq(sub3.row.admin_permissions, [], 'and its permissions are cleared');
    const res = await svc.restore(client, { actorId: superId, targetId: subId });
    check(res.ok, 'restore succeeds', res.ok ? '' : res.message);
    eq((await reqUserFor(client, subId)).row.is_active, true, 'and the account is active again');

    section('Block 6 · The refusals that protect the single owner');
    const bad = await svc.create(client, {
      creatorId: superId, name: `${PREFIX}X`, email: `${PREFIX}x@sportlynk.test`,
      password: 'longenough1', permissions: ['not_a_real_key'],
    });
    check(!bad.ok && bad.code === 'bad_permissions', 'an unknown permission key is refused by name');
    const editSuper = await svc.updatePermissions(client, {
      actorId: superId, targetId: superId, permissions: ['user_management'],
    });
    check(!editSuper.ok && editSuper.code === 'is_super_admin', 'the super admin cannot be edited');
    const remSuper = await svc.remove(client, { actorId: superId, targetId: superId });
    check(!remSuper.ok && remSuper.code === 'self', 'the super admin cannot remove themselves');
    const remSelfSub = await svc.remove(client, { actorId: subId, targetId: subId });
    check(!remSelfSub.ok && remSelfSub.code === 'self', 'nobody can remove their own access');
  } catch (err) {
    console.error('\n  ! the run stopped:', err.message);
    failures.push(`the run completed without throwing (${err.message})`);
  } finally {
    if (!VERIFY_CLEAN) {
      await client.query('ROLLBACK').catch(() => {});
      section('The rollback');
      const { rows } = await client.query(
        'SELECT count(*)::int AS n FROM users WHERE email LIKE $1', [`${PREFIX}%`]);
      eq(rows[0].n, 0, 'after ROLLBACK not one zzrbac- row remains');
    }
    client.release();
  }
}

main()
  .then(() => {
    const total = passed + failures.length;
    console.log(`\n${'═'.repeat(60)}`);
    console.log(failures.length ? `FAIL ${passed}/${total}` : `PASS ${passed}/${total}`);
    for (const f of failures) console.log(`  ✗ ${f}`);
    console.log('');
  })
  .then(() => pool.end())
  .then(() => process.exit(failures.length ? 1 : 0))
  .catch(async (err) => {
    console.error('the harness itself failed:', err);
    await pool.end().catch(() => {});
    process.exit(1);
  });
