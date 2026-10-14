/**
 * make_super_admin.js — create or promote the single super admin.
 *
 * The admin tier (migration 040) has exactly one super admin: the account that holds
 * every power and is the only one that can manage other admins. The app never creates
 * a super admin — that would let the single-owner rule be bypassed from a screen — so
 * this one-off script is the only way to establish or move it.
 *
 * Usage (from backend/):
 *   node src/scripts/make_super_admin.js --email you@site.com --password "StrongPass123" --name "Site Admin" [--phone 03001234567]
 *   node src/scripts/make_super_admin.js --email new@site.com --password "..." --name "..." --transfer
 *
 *   • If no user has that email, a new admin account is created.
 *   • If a user with that email exists, it is promoted to super admin (and its password
 *     is updated only if --password is given).
 *   • If a DIFFERENT super admin already exists, the script refuses unless --transfer is
 *     passed, which demotes the current super admin in the same transaction.
 *
 * The password is read from the argument and NEVER printed, logged, or stored except as
 * a bcrypt hash. Run it yourself so the secret stays with you.
 *
 * Requires migration 040 to be applied first (it writes is_super_admin /
 * admin_permissions); the script checks and says so if it is missing.
 */
const bcrypt = require('bcrypt');
const pool = require('../db/pool');

const BCRYPT_COST = 12;
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const PHONE_RE = /^03\d{9}$/;

/** Minimal `--flag value` / `--flag` parser; no dependency, no surprises. */
function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (!a.startsWith('--')) continue;
    const key = a.slice(2);
    const next = argv[i + 1];
    if (next === undefined || next.startsWith('--')) {
      out[key] = true;
    } else {
      out[key] = next;
      i += 1;
    }
  }
  return out;
}

async function columnsPresent() {
  const { rows } = await pool.query(
    `SELECT count(*)::int AS n FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'users'
        AND column_name IN ('is_super_admin', 'admin_permissions')`,
  );
  return rows[0].n === 2;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const email = String(args.email || '').trim().toLowerCase();
  const name = String(args.name || '').trim();
  const password = typeof args.password === 'string' ? args.password : '';
  const phone = String(args.phone || '').replace(/\s/g, '');
  const transfer = args.transfer === true;

  if (!EMAIL_RE.test(email)) {
    console.error('✗ --email is required and must be a valid email.');
    process.exitCode = 1;
    return;
  }
  if (phone && !PHONE_RE.test(phone)) {
    console.error('✗ --phone must be a Pakistani number (03XXXXXXXXX).');
    process.exitCode = 1;
    return;
  }

  if (!(await columnsPresent())) {
    console.error('✗ migration 040 is not applied — run '
      + 'node src/scripts/run_migration_040_admin_rbac.js first.');
    process.exitCode = 1;
    return;
  }

  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    // Who, if anyone, is the super admin today.
    const current = await client.query(
      'SELECT id, email FROM users WHERE is_super_admin = true',
    );
    const other = current.rows.find((r) => (r.email || '').toLowerCase() !== email);
    if (other && !transfer) {
      await client.query('ROLLBACK');
      console.error(`✗ A super admin already exists (${other.email}). `
        + 'Re-run with --transfer to move super-admin status to the new email.');
      process.exitCode = 1;
      return;
    }
    if (transfer && current.rows.length) {
      // Demote every current super admin before promoting the target, so there is
      // never a moment with two.
      await client.query('UPDATE users SET is_super_admin = false WHERE is_super_admin = true');
    }

    const existing = await client.query('SELECT id FROM users WHERE email = $1', [email]);

    let userId;
    let action;
    if (existing.rows.length) {
      // Promote an existing account.
      userId = existing.rows[0].id;
      const hash = password ? await bcrypt.hash(password, BCRYPT_COST) : null;
      await client.query(
        `UPDATE users
            SET role = 'admin', is_super_admin = true, is_active = true,
                phone_verified = true,
                name = COALESCE(NULLIF($2, ''), name),
                password_hash = COALESCE($3, password_hash)
          WHERE id = $1`,
        [userId, name, hash],
      );
      action = 'promoted';
    } else {
      // Create a fresh account. A password is mandatory here — there is nothing to
      // keep.
      if (!password || password.length < 8) {
        await client.query('ROLLBACK');
        console.error('✗ --password (min 8 chars) is required to create a new super admin.');
        process.exitCode = 1;
        return;
      }
      if (name.length < 3) {
        await client.query('ROLLBACK');
        console.error('✗ --name (min 3 chars) is required to create a new super admin.');
        process.exitCode = 1;
        return;
      }
      if (phone) {
        const dup = await client.query('SELECT 1 FROM users WHERE phone = $1', [phone]);
        if (dup.rows.length) {
          await client.query('ROLLBACK');
          console.error('✗ that phone number is already registered.');
          process.exitCode = 1;
          return;
        }
      }
      const hash = await bcrypt.hash(password, BCRYPT_COST);
      const ins = await client.query(
        `INSERT INTO users (name, email, phone, password_hash, role, is_super_admin,
                            admin_permissions, phone_verified, is_active)
         VALUES ($1, $2, $3, $4, 'admin', true, '{}', true, true)
         RETURNING id`,
        [name, email, phone || null, hash],
      );
      userId = ins.rows[0].id;
      action = 'created';
    }

    await client.query('COMMIT');
    console.log(`✓ super admin ${action}: ${email} (id ${userId})`);
    if (other && transfer) console.log(`  (super-admin status moved from ${other.email})`);
    console.log('  Log in with this email and the password you set.');
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    if (e.code === '23505') {
      console.error('✗ email already registered to another account.');
    } else {
      console.error('✗ failed:', e.message);
    }
    process.exitCode = 1;
  } finally {
    client.release();
  }
}

main()
  .catch((e) => { console.error('crashed:', e.message); process.exitCode = 1; })
  .finally(() => pool.end());
