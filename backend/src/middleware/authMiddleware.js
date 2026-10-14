const jwt = require('jsonwebtoken');
const pool = require('../db/pool');

/**
 * Authentication, and suspension enforcement.
 *
 * Why this file touches the database at all
 * It was previously pure `jwt.verify`: 43 lines, no I/O. That made
 * suspension cosmetic. `routes/auth.js` refuses to log in an inactive user, but a
 * suspended user who was already logged in kept a valid signed token, and every
 * request it carried sailed through until the token expired on its own. Banning
 * somebody who is currently holding a token had no observable effect. A JWT
 * cannot be un-issued, so the only place that fact can be re-checked is here.
 *
 * Why A 30-second cache and not a lookup per request
 * A lookup per request would put one round trip in front of every authenticated
 * call in the app — the home screen alone fires several. A 30 s TTL costs one
 * indexed primary-key read per active user per 30 s, and `invalidate()` is called
 * by the suspend route inside the same process, so the real latency of a ban is
 * ~0 ms rather than 30 s. The window only ever matters for a suspension applied
 * by a different process (a second server instance), where it is 30 s.
 *
 * Why a database error must not log everybody out
 * This is the same rule `utils/globalSettings.js` states for itself: never throw.
 * If Supabase blips, the honest failure mode is "the re-check did not happen, so
 * the already-verified signature stands" — the earlier behaviour. The
 * alternative is an outage that locks out every user of the app because one query
 * timed out, which trades a rare authorisation gap for a total loss of service.
 *
 * Why the role comes from the row when the row is available
 * The token carries a role claim from login time. A user demoted from admin an
 * hour ago still presents `role: 'admin'` in a token that is cryptographically
 * valid. Since the row is in hand anyway, the row wins.
 */

/** How long a fetched account state is trusted. */
const TTL_MS = 30 * 1000;

/**
 * Bound on the cache. Entries are one small object per user, not per token, so
 * this is generous for a phone app; the cap exists so that a flood of tokens for
 * random ids cannot grow the map without limit. Eviction is oldest-first by
 * insertion order, which is what a JS Map iterates in.
 */
const MAX_ENTRIES = 5000;

/** id -> { active, role, at } */
const cache = new Map();

/**
 * Drop a cached account state immediately.
 *
 * Called by the suspend/reinstate routes (and by anything else that changes
 * `users.is_active` or `users.role`) so the change is enforced on the very next
 * request instead of at the end of the TTL. With no argument it clears the whole
 * map — used by the test suite between cases.
 */
function invalidate(userId) {
  if (userId === undefined || userId === null) cache.clear();
  else cache.delete(String(userId));
}

/** Number of live entries. Exposed for the check script, not for callers. */
function cacheSize() {
  return cache.size;
}

/**
 * The account state behind a token, from cache or from one indexed read.
 *
 * Returns `null` when the state could not be read (no id in the token, or the
 * database refused). `null` means "carry on with the token's claims" — see never
 * throw above. It never returns a partially-filled object, so the caller has exactly
 * two cases to handle rather than three.
 */
async function accountState(id) {
  if (!id) return null;
  const key = String(id);
  const hit = cache.get(key);
  if (hit && Date.now() - hit.at < TTL_MS) return hit;

  try {
    // The RBAC columns (migration 040) are read alongside the suspension state, so a
    // permission check costs no extra round trip and shares this cache. They are
    // tolerated as absent: on a database where 040 has not been applied yet the
    // SELECT falls back to the legacy two columns, so suspension enforcement never
    // depends on the newer migration and the apply order cannot wedge the app.
    let row;
    try {
      const r = await pool.query(
        'SELECT is_active, role, is_super_admin, admin_permissions FROM users WHERE id = $1',
        [key],
      );
      row = r.rows[0];
    } catch (e) {
      if (e && e.code === '42703') {
        const r = await pool.query('SELECT is_active, role FROM users WHERE id = $1', [key]);
        row = r.rows[0];
      } else {
        throw e;
      }
    }

    // A token for a row that no longer exists. Not cached: there is nothing to
    // re-check, and caching absence would keep answering for a re-created id.
    if (!row) return { missing: true, at: Date.now() };

    const state = {
      // NULL is_active predates the column's default and means "not suspended".
      active: row.is_active !== false,
      role: row.role || null,
      // Absent on a pre-040 database: a safe false / empty set until 040 is applied.
      isSuperAdmin: row.is_super_admin === true,
      permissions: Array.isArray(row.admin_permissions) ? row.admin_permissions : [],
      at: Date.now(),
    };
    if (cache.size >= MAX_ENTRIES) {
      const oldest = cache.keys().next();
      if (!oldest.done) cache.delete(oldest.value);
    }
    cache.set(key, state);
    return state;
  } catch (err) {
    // Deliberately quiet on the hot path, loud enough to find. A malformed uuid
    // in a forged token lands here too (22P02) and is treated the same way: the
    // signature was still valid, so the request proceeds on its claims.
    if (process.env.NODE_ENV !== 'test') {
      console.warn('[auth] account re-check unavailable:', err.message);
    }
    return null;
  }
}

const authMiddleware = async (req, res, next) => {
  let decoded;
  try {
    const authHeader = req.headers.authorization;

    if (!authHeader) {
      return res
        .status(401)
        .json({ success: false, message: 'No token provided' });
    }

    const parts = authHeader.split(' ');
    if (parts.length !== 2 || parts[0] !== 'Bearer') {
      return res
        .status(401)
        .json({ success: false, message: 'Token format: Bearer <token>' });
    }

    decoded = jwt.verify(parts[1], process.env.JWT_SECRET);
  } catch (err) {
    if (err.name === 'TokenExpiredError') {
      return res
        .status(401)
        .json({ success: false, message: 'Token expired. Please log in again.' });
    }
    return res
      .status(401)
      .json({ success: false, message: 'Unauthorized' });
  }

  // Signature is good. Everything from here on is the account state, and its
  // failures are 403s (the identity holds, the permission does not) rather
  // than 401s (the identity itself is unknown).
  const state = await accountState(decoded.id);

  if (state && state.missing) {
    return res
      .status(401)
      .json({ success: false, message: 'Account no longer exists' });
  }

  if (state && state.active === false) {
    // Worded to match the login refusal in `routes/auth.js` so a suspended user
    // is told the same thing whichever door they try. 403, not 401: the app must
    // not treat this as an expired session and silently bounce to the login
    // screen, where the same message would appear with no explanation.
    return res.status(403).json({
      success: false,
      message: 'Account suspended. Contact support.',
    });
  }

  req.user = {
    id: decoded.id,
    email: decoded.email,
    // The row wins when it is available; the claim is the fallback.
    role: (state && state.role) || decoded.role,
    // Authorisation for the sub-admin tier. From the row only — never the token —
    // so a granted or revoked permission takes effect on the next request. Absent
    // state (DB unreachable, or pre-040) degrades to no powers, which fails closed:
    // a permission check denies rather than letting a stale claim through.
    isSuperAdmin: !!(state && state.isSuperAdmin),
    permissions: (state && Array.isArray(state.permissions)) ? state.permissions : [],
  };

  next();
};

module.exports = authMiddleware;
module.exports.invalidate = invalidate;
module.exports.cacheSize = cacheSize;
module.exports.TTL_MS = TTL_MS;
