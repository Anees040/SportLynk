/**
 * routes/notifications.js — the feed the table never had (S.7 Wave C).
 *
 * Before this file, `notifications` was write-only: 38 call sites inserted into it
 * and nothing in the entire codebase ever read a row back. The bell on the player
 * home screen was a decorative `Icon` with no `onTap`. So this is not "add push to a
 * working notification system" — it is the read half of the system, and push is a
 * consequence of it.
 *
 * Declaration order is load-bearing
 * Express matches in declaration order, so every literal path — /summary,
 * /preferences, /devices, /read-all, /test — is declared before /:id. Reversed, a
 * GET /api/notifications/summary would arrive at the detail handler as id="summary"
 * and fail as an invalid uuid. Same trap tournaments.js documents for /mine.
 *
 * Authorisation is the WHERE clause
 * Every statement in notificationFeed.js carries `AND user_id = $userId`. There is no
 * separate ownership check to forget, and an id belonging to somebody else matches no
 * row — which surfaces as 404, not 403, because "that notification exists but
 * belongs to somebody else" tells a caller more than they are entitled to know.
 *
 * What this file does not do
 * It never sends a push. Marking something read, dismissing it, changing a
 * preference — none of it touches Firebase. Delivery is the outbox's job
 * (jobs/pushJob.js), which is why a Firebase outage cannot make this endpoint slow.
 */

const express = require('express');
const pool = require('../db/pool');
const auth = require('../middleware/authMiddleware');
const feed = require('../utils/notificationFeed');
const push = require('../services/pushService');
const reg = require('../utils/notificationTypes');
const { notify } = require('../utils/notify');

const router = express.Router();
router.use(auth);

const fail = (res, status, message) => res.status(status).json({ success: false, message });
const ok = (res, data) => res.json({ success: true, data });

/** A uuid, or null. Guards every :id route from a 22P02 on a garbage path segment. */
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// The feed

/**
 * GET /api/notifications?limit&cursor&category&unreadOnly
 *
 * Cursor-paginated on `created_at DESC`, the same expression it sorts by, so a
 * notification arriving mid-scroll cannot duplicate a row or drop one.
 */
router.get('/', async (req, res, next) => {
  try {
    const page = await feed.listFeed(pool, {
      userId: req.user.id,
      limit: req.query.limit,
      cursor: req.query.cursor || null,
      category: req.query.category || null,
      unreadOnly: req.query.unreadOnly === 'true' || req.query.unreadOnly === '1',
    });
    return ok(res, page);
  } catch (e) { return next(e); }
});

/**
 * GET /api/notifications/summary — the badge and the filter-chip counts, one trip.
 *
 * `push` is included so the app can tell the user why their phone is quiet without a
 * second endpoint: an unconfigured server, a denied OS permission and a muted
 * category are three different problems with three different fixes.
 */
router.get('/summary', async (req, res, next) => {
  try {
    const s = await feed.summary(pool, req.user.id);
    return ok(res, { ...s, push: push.status() });
  } catch (e) { return next(e); }
});

// Preferences

/** GET /api/notifications/preferences — a complete form from one call. */
router.get('/preferences', async (req, res, next) => {
  try {
    return ok(res, await feed.getPrefs(pool, req.user.id));
  } catch (e) { return next(e); }
});

/**
 * PUT /api/notifications/preferences
 *
 * The body is normalised through the same function used on read, so an unknown
 * category or a malformed "25:99" is dropped rather than stored, and the response
 * echoes what was kept — the client can diff it against what it sent instead
 * of assuming success. Enforcement is in pushJob, server-side: a preference the client
 * honours is a suggestion, not a preference.
 */
router.put('/preferences', async (req, res, next) => {
  try {
    if (!req.body || typeof req.body !== 'object') return fail(res, 400, 'Body required');
    return ok(res, await feed.setPrefs(pool, req.user.id, req.body));
  } catch (e) { return next(e); }
});

// Devices

/**
 * POST /api/notifications/devices  { token, platform?, appVersion?, label? }
 *
 * Called on login, on every `onTokenRefresh`, and on app start. FCM rotates tokens
 * without warning, so "register on signup" is not enough — a stale token is
 * indistinguishable from a working one until a send fails.
 *
 * `users.fcm_token` is written too, for backward compatibility with migration 012's
 * one-token-per-user column that pre-020 code still reads.
 */
router.post('/devices', async (req, res, next) => {
  const client = await pool.connect();
  try {
    const token = (req.body && req.body.token ? String(req.body.token) : '').trim();
    // FCM tokens are ~160 chars; the bound is a sanity check, not a format check —
    // guessing at their format is how a valid token gets rejected after Google
    // changes its shape.
    if (!token || token.length < 20 || token.length > 4096) {
      return fail(res, 400, 'A valid FCM token is required');
    }
    const platform = ['android', 'ios', 'web'].includes(req.body.platform)
      ? req.body.platform : null;

    await client.query('BEGIN');
    const row = await push.registerDevice(client, {
      userId: req.user.id,
      token,
      platform,
      appVersion: req.body.appVersion ? String(req.body.appVersion).slice(0, 40) : null,
      label: req.body.label ? String(req.body.label).slice(0, 80) : null,
    });
    await client.query('UPDATE users SET fcm_token = $2 WHERE id = $1', [req.user.id, token]);
    await client.query('COMMIT');
    return ok(res, { deviceId: row ? row.id : null, pushConfigured: push.isConfigured() });
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    return next(e);
  } finally {
    client.release();
  }
});

/**
 * DELETE /api/notifications/devices  { token? }
 *
 * With a token: revoke that one device (a normal logout). Without: revoke all of them
 * — "log me out everywhere", which is the honest response to a lost phone.
 *
 * Revoked, not deleted: `revoke_reason` and `revoked_at` are how "this phone stopped
 * getting notifications last Tuesday" gets answered instead of guessed at.
 */
router.delete('/devices', async (req, res, next) => {
  const client = await pool.connect();
  try {
    const token = req.body && req.body.token ? String(req.body.token).trim() : null;
    await client.query('BEGIN');
    const n = token
      ? await push.revokeDevice(client, token, 'logout')
      : await push.revokeAllForUser(client, req.user.id, 'logout-all');
    // Only clear the legacy column when logging out everywhere; clearing it for one
    // device would silence a second phone that is still signed in.
    if (!token) await client.query('UPDATE users SET fcm_token = NULL WHERE id = $1', [req.user.id]);
    await client.query('COMMIT');
    return ok(res, { revoked: n });
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    return next(e);
  } finally {
    client.release();
  }
});

// Bulk state

/** POST /api/notifications/read-all  { category? } — the "mark all read" button. */
router.post('/read-all', async (req, res, next) => {
  try {
    const category = req.body && req.body.category ? String(req.body.category) : null;
    const n = await feed.markAllRead(pool, req.user.id, category);
    return ok(res, { marked: n, ...(await feed.summary(pool, req.user.id)) });
  } catch (e) { return next(e); }
});

/**
 * DELETE /api/notifications?category= — "clear read".
 *
 * The only hard delete offered, and bounded on purpose: unread rows survive, and so do
 * rows younger than an hour, so a tap immediately after a batch lands cannot erase
 * what just arrived. See notificationFeed.clearRead.
 */
router.delete('/', async (req, res, next) => {
  try {
    const n = await feed.clearRead(pool, req.user.id, req.query.category || null);
    return ok(res, { deleted: n, ...(await feed.summary(pool, req.user.id)) });
  } catch (e) { return next(e); }
});

/**
 * POST /api/notifications/test — the demo lever, and the answer to "is the key working?"
 *
 * Two guards, both necessary. It only ever sends to the caller (no userId is accepted
 * from the body, so it cannot be turned into a way to buzz another user's phone), and
 * it is disabled in production — a live endpoint that writes an arbitrary title and
 * body into somebody's notification tray is a spam vector, however well-intentioned.
 *
 * It goes through the ordinary outbox, not around it: the point is to prove the real
 * delivery path works, and a test that used a different code path would prove nothing.
 */
router.post('/test', async (req, res, next) => {
  const client = await pool.connect();
  try {
    if (process.env.RENDER || process.env.NODE_ENV === 'production') {
      return fail(res, 403, 'Test notifications are disabled in production');
    }
    await client.query('BEGIN');
    const out = await notify(client, {
      userId: req.user.id,
      type: 'system_test',
      title: req.body && req.body.title ? String(req.body.title).slice(0, 120) : 'SportLynk test',
      body: req.body && req.body.body ? String(req.body.body).slice(0, 300) : 'If you can see this, notifications work.',
    });
    await client.query('COMMIT');
    return ok(res, {
      ...out,
      push: push.status(),
      note: 'Written to the outbox; pushJob delivers it within a few seconds.',
    });
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    return next(e);
  } finally {
    client.release();
  }
});

/** GET /api/notifications/types — the registry, for the settings screen and the docs. */
router.get('/types', async (req, res, next) => {
  try {
    return ok(res, {
      types: reg.allTypes().length,
      routes: reg.allRoutes(),
      categories: reg.MUTABLE_CATEGORIES,
    });
  } catch (e) { return next(e); }
});

// One row  —  declared last, after every literal path above

/** PATCH /api/notifications/:id/read — idempotent; a second call is a no-op, not an error. */
router.patch('/:id/read', async (req, res, next) => {
  try {
    if (!UUID.test(req.params.id)) return fail(res, 404, 'Notification not found');
    const r = await feed.markRead(pool, req.user.id, req.params.id);
    if (r === -1) return fail(res, 404, 'Notification not found');
    return ok(res, { changed: r === 1, ...(await feed.summary(pool, req.user.id)) });
  } catch (e) { return next(e); }
});

/**
 * PATCH /api/notifications/:id/unread — "I'll deal with this later".
 *
 * Resets `group_count` to 1: the row re-enters ux_notifications_group, so the next
 * message in that thread bumps it again, and keeping the old count would make it read
 * "4 new messages" when only one is new since the user looked.
 */
router.patch('/:id/unread', async (req, res, next) => {
  try {
    if (!UUID.test(req.params.id)) return fail(res, 404, 'Notification not found');
    const r = await feed.markUnread(pool, req.user.id, req.params.id);
    if (r === -1) return fail(res, 404, 'Notification not found');
    return ok(res, { changed: true, ...(await feed.summary(pool, req.user.id)) });
  } catch (e) { return next(e); }
});

/**
 * DELETE /api/notifications/:id — swipe away.
 *
 * `dismissed_at`, not a DELETE: the row is the only record that the user was ever
 * told, and "I never got a notification about that refund" is a support question this
 * table answers. It also leaves ux_notifications_group, so the next message in a
 * dismissed thread starts a fresh row instead of silently bumping a hidden counter.
 */
router.delete('/:id', async (req, res, next) => {
  try {
    if (!UUID.test(req.params.id)) return fail(res, 404, 'Notification not found');
    const r = await feed.dismiss(pool, req.user.id, req.params.id);
    if (r === -1) return fail(res, 404, 'Notification not found');
    return ok(res, { dismissed: true, ...(await feed.summary(pool, req.user.id)) });
  } catch (e) { return next(e); }
});

module.exports = router;
