/**
 * pushService.js — the only place in the backend that talks to Firebase Cloud
 * Messaging.
 *
 * ─── WHY THIS SHIPS DORMANT ───────────────────────────────────────────────────
 * FCM needs a service-account JSON that cannot go in git (it is a private key for
 * the whole Firebase project). So this module is written to be COMPLETELY ABSENT
 * until `FIREBASE_SERVICE_ACCOUNT` points at a real file: `isConfigured()` answers
 * false, `sendToUser()` returns `{skipped:'unconfigured'}`, and one warning is
 * printed at boot instead of one per notification.
 *
 * That is the same discipline as `mlClient.isConfigured()` and `bus.attach()`, and
 * it is what lets the entire notification feature — bell, badge, list, deep links,
 * preferences, live socket delivery — be built, tested and demonstrated with no
 * Firebase project in existence. Adding the key later switches the tray on with no
 * code change.
 *
 * `require('firebase-admin')` is also lazy and caught, so a tree where
 * `npm install` has not been run yet degrades exactly like a missing key rather
 * than crashing at import time. A backend that cannot boot because an OPTIONAL
 * push dependency is missing is a worse failure than a phone that does not buzz.
 *
 * ─── WHY THE CALLER PASSES A `client` ─────────────────────────────────────────
 * Sending a push has a database side effect: FCM answers
 * `registration-token-not-registered` for a token belonging to an app that was
 * uninstalled, and that answer is the ONLY way to learn a device is gone. If it is
 * not written down, every future send retries a token that can never succeed. So
 * this module reads `user_devices` and revokes dead rows through the client it is
 * given — the pushJob's, outside the money path, where a slow network call is
 * harmless.
 *
 * ─── WHY BOTH A `notification` AND A `data` BLOCK ─────────────────────────────
 * `notification` is what the OS renders when the app is killed — without it, a
 * data-only message is delivered to a background handler that cannot draw a tray
 * banner on Android. `data` is what the app needs when the user TAPS it: the deep
 * link route and args, computed server-side by notificationTypes.js, so the client
 * never re-derives a route from a type string. Both, always.
 *
 * FCM requires every `data` value to be a string. A number or a null there is a
 * hard `invalid-argument` for the whole batch, which is why `strData()` exists and
 * why nothing is spread into `data` unfiltered.
 */

const path = require('path');
const fs = require('fs');

// ─── Module state ────────────────────────────────────────────────────────────
// Resolved once, on first use. 'unknown' means init() has not run yet; after it
// runs the answer never changes for the life of the process, because a key that
// appears on disk mid-run is not a case worth reloading for.
let _app = null;
let _msg = null; // the Messaging instance, from firebase-admin/messaging
let _state = 'unknown'; // 'unknown' | 'ready' | 'disabled'
let _reason = null;
let _projectId = null;

/** Named so a second require in one process reuses the app instead of colliding. */
const APP_NAME = 'sportlynk-push';

/**
 * Load and initialise firebase-admin, at most once.
 *
 * Every failure path sets `_state = 'disabled'` with a `_reason` that names the fix,
 * and returns false. Nothing here throws: the caller is a background job draining an
 * outbox, and an exception there would be an unhandled rejection in a timer.
 */
function init() {
  if (_state !== 'unknown') return _state === 'ready';

  const raw = (process.env.FIREBASE_SERVICE_ACCOUNT || '').trim();
  if (!raw) {
    _state = 'disabled';
    _reason = 'FIREBASE_SERVICE_ACCOUNT is not set';
    return false;
  }

  // A path, not the JSON itself. The credential file must live outside git; putting
  // the private key in an env var invites it into a shell history and a log line.
  const file = path.isAbsolute(raw) ? raw : path.join(__dirname, '..', '..', raw);
  if (!fs.existsSync(file)) {
    _state = 'disabled';
    _reason = `FIREBASE_SERVICE_ACCOUNT points at a file that does not exist (${file})`;
    return false;
  }

  let creds;
  try {
    creds = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (e) {
    _state = 'disabled';
    _reason = `service account JSON is unreadable: ${e.message}`;
    return false;
  }
  if (!creds.project_id || !creds.private_key || !creds.client_email) {
    _state = 'disabled';
    // Named explicitly because the wrong file from the Firebase console (the
    // google-services.json meant for the Flutter app) is the likely mistake, and it
    // parses as valid JSON.
    _reason = 'service account JSON has no project_id/private_key/client_email '
      + '(google-services.json is the CLIENT file — you want Settings → Service accounts)';
    return false;
  }

  // firebase-admin v13+ is MODULAR: `require('firebase-admin')` re-exports only the
  // app namespace, and the old namespaced surface (admin.credential.cert,
  // admin.apps, admin.messaging()) is gone. Requiring the two subpaths explicitly is
  // the supported shape for the pinned 14.3.0 in package.json — and the reason this
  // is worth a comment is that the legacy form fails at *first send*, which with a
  // dormant-by-default service means the day you add the key, not the day you write
  // the code.
  let appNs;
  let msgNs;
  try {
    /* eslint-disable global-require, import/no-unresolved, import/no-extraneous-dependencies */
    appNs = require('firebase-admin/app');
    msgNs = require('firebase-admin/messaging');
    /* eslint-enable global-require, import/no-unresolved, import/no-extraneous-dependencies */
  } catch (e) {
    _state = 'disabled';
    _reason = 'firebase-admin is not installed (npm install firebase-admin)';
    return false;
  }

  try {
    // A NAMED app, so a second require of this module in the same process (a check
    // script importing both the job and the service) reuses it instead of colliding
    // with the default app.
    _app = appNs.getApps().find((a) => a && a.name === APP_NAME)
      || appNs.initializeApp({ credential: appNs.cert(creds) }, APP_NAME);
    _msg = msgNs.getMessaging(_app);
    _projectId = creds.project_id;
    _state = 'ready';
    return true;
  } catch (e) {
    _state = 'disabled';
    _reason = `firebase-admin initializeApp failed: ${e.message}`;
    return false;
  }
}

/** True when a real FCM send can happen. Checked by the job before it does work. */
function isConfigured() {
  return init();
}

/**
 * What to print in the boot banner and return from the dev-only test endpoint.
 * `reason` is the actionable half — "why didn't my phone buzz?" answered without
 * reading code.
 */
function status() {
  init();
  return {
    configured: _state === 'ready',
    reason: _state === 'ready' ? null : _reason,
    projectId: _projectId,
  };
}

/** One warning per process, not one per notification. */
let _warned = false;
function warnOnce() {
  if (_warned) return;
  _warned = true;
  console.warn(`[push] disabled — ${_reason}. Notifications are still written and `
    + 'delivered in-app; only the tray banner is off.');
}

// ═══════════════════════════════════════════════════════════════════════════
// DEVICES
// ═══════════════════════════════════════════════════════════════════════════
//
// `users.fcm_token` (migration 012) is one token per user — "last login wins" —
// which breaks the moment you use a phone and an emulator, and has nowhere to
// record that a token is dead. 020's `user_devices` fixes both. The old column is
// still written by auth.js for backward compatibility, and is read here ONLY as a
// fallback for a user who has not opened the app since 020, so an existing tester's
// phone keeps working without re-login.

/** Live (unrevoked) tokens for one user, newest first, de-duplicated. */
async function liveTokens(client, userId) {
  const { rows } = await client.query(
    `SELECT fcm_token FROM user_devices
      WHERE user_id = $1 AND revoked_at IS NULL AND fcm_token <> ''
      ORDER BY last_seen_at DESC
      LIMIT 20`,
    [userId],
  );
  const out = rows.map((r) => r.fcm_token).filter(Boolean);
  if (out.length) return [...new Set(out)];

  // Pre-020 fallback.
  const legacy = await client.query(
    'SELECT fcm_token FROM users WHERE id = $1 AND fcm_token IS NOT NULL', [userId],
  );
  const t = legacy.rows[0] && legacy.rows[0].fcm_token;
  return t ? [t] : [];
}

/**
 * Register or refresh one device token.
 *
 * The UNIQUE index is on `fcm_token` ALONE, not on (user_id, fcm_token), and that is
 * deliberate: FCM issues a token per app INSTALL, so the same token appearing for a
 * second user means the phone was handed over or a second account logged in on it.
 * The token must MOVE, or the previous owner keeps receiving the new owner's
 * notifications — a privacy leak, not a bookkeeping detail. Hence `user_id` is in
 * the DO UPDATE set, and `revoked_at` is cleared: re-registering a token that FCM
 * previously reported dead is the app telling us it is alive again.
 */
async function registerDevice(client, {
  userId, token, platform = null, appVersion = null, label = null,
}) {
  if (!userId || !token) return null;
  const { rows } = await client.query(
    `INSERT INTO user_devices (user_id, fcm_token, platform, app_version, device_label)
     VALUES ($1,$2,$3,$4,$5)
     ON CONFLICT (fcm_token) DO UPDATE SET
       user_id      = EXCLUDED.user_id,
       platform     = COALESCE(EXCLUDED.platform, user_devices.platform),
       app_version  = COALESCE(EXCLUDED.app_version, user_devices.app_version),
       device_label = COALESCE(EXCLUDED.device_label, user_devices.device_label),
       last_seen_at = now(),
       revoked_at   = NULL,
       revoke_reason = NULL
     RETURNING id, user_id`,
    [userId, token, platform, appVersion, label],
  );
  return rows[0] || null;
}

/**
 * Mark one device dead. Called on logout (reason 'logout') and by the send path when
 * FCM says the token is gone.
 *
 * Revoked rather than deleted: `revoke_reason` + `revoked_at` are how you answer
 * "this phone stopped getting notifications last Tuesday" without guessing.
 */
async function revokeDevice(client, token, reason = 'unregistered') {
  if (!token) return 0;
  const { rowCount } = await client.query(
    `UPDATE user_devices SET revoked_at = now(), revoke_reason = $2
      WHERE fcm_token = $1 AND revoked_at IS NULL`,
    [token, String(reason).slice(0, 200)],
  );
  return rowCount;
}

/** Every device of one user, for the logout-everywhere case. */
async function revokeAllForUser(client, userId, reason = 'logout') {
  if (!userId) return 0;
  const { rowCount } = await client.query(
    `UPDATE user_devices SET revoked_at = now(), revoke_reason = $2
      WHERE user_id = $1 AND revoked_at IS NULL`,
    [userId, String(reason).slice(0, 200)],
  );
  return rowCount;
}

// ═══════════════════════════════════════════════════════════════════════════
// THE MESSAGE
// ═══════════════════════════════════════════════════════════════════════════

/** The Android notification channel the Flutter side creates at startup. */
const ANDROID_CHANNEL = 'sportlynk_default';

/**
 * Coerce a payload into FCM's data map: every value a string, every empty one gone.
 *
 * This is not tidiness. `data: {matchId: null}` fails the entire multicast with
 * `invalid-argument`, and because that error is per-message rather than per-token it
 * would look exactly like a bad token — sending the job into revoking healthy
 * devices. Filtering here is what keeps that class of bug impossible.
 */
function strData(obj) {
  const out = {};
  for (const [k, v] of Object.entries(obj || {})) {
    if (v === null || v === undefined || v === '') continue;
    out[k] = typeof v === 'string' ? v : JSON.stringify(v);
  }
  return out;
}

/**
 * Build one multicast message from a notification row.
 *
 * `row` is a `notifications` record as the job read it, so the shape here is the
 * database's, not a hand-assembled DTO — one fewer place for the two to drift.
 *
 * WHY `android.notification.tag` AND `collapseKey` ARE BOTH SET
 * They solve different halves of the same problem. `collapseKey` tells FCM to
 * discard an undelivered earlier message for the same key (the phone was offline);
 * `tag` tells Android to REPLACE the banner already on screen. Without the tag,
 * "2 new messages" and "3 new messages" stack as two banners about the same thread.
 *
 * WHY `ttl` COMES FROM expires_at
 * A challenge alert that has expired must not be delivered by FCM after the phone
 * comes back online — it would open a screen where the action no longer exists. The
 * job already skips a row that is expired at send time; ttl covers the gap between
 * send and delivery.
 */
function buildMessage(row, tokens) {
  const link = parseLink(row.deep_link);
  const high = row.priority === 'high';

  const data = strData({
    notificationId: row.id,
    type: row.type,
    category: row.category,
    priority: row.priority,
    entityType: row.entity_type,
    entityId: row.entity_id,
    bookingId: row.booking_id,
    groupKey: row.group_key,
    groupCount: row.group_count > 1 ? row.group_count : null,
    // The route and its arguments, exactly as notificationTypes.js computed them.
    // The client looks up `route` in one map; it never inspects `type`.
    route: link ? link.route : null,
    args: link && link.args && Object.keys(link.args).length ? link.args : null,
    // Required by flutter_local_notifications / firebase_messaging for the tap to
    // reach the Dart side on a cold start.
    click_action: 'FLUTTER_NOTIFICATION_CLICK',
  });

  const ttlMs = row.expires_at
    ? Math.max(0, new Date(row.expires_at).getTime() - Date.now())
    : null;

  const msg = {
    tokens,
    notification: {
      title: row.title || 'SportLynk',
      body: row.body || '',
    },
    data,
    android: {
      // 'high' wakes the device; 'normal' waits for the next maintenance window.
      // The registry decides, because urgency is a property of the type.
      priority: high ? 'high' : 'normal',
      ...(row.group_key ? { collapseKey: String(row.group_key).slice(0, 200) } : {}),
      ...(ttlMs !== null ? { ttl: ttlMs } : {}),
      notification: {
        channelId: ANDROID_CHANNEL,
        ...(row.group_key ? { tag: String(row.group_key).slice(0, 200) } : {}),
        clickAction: 'FLUTTER_NOTIFICATION_CLICK',
        priority: high ? 'max' : 'default',
        defaultSound: true,
        ...(row.image_url ? { imageUrl: row.image_url } : {}),
      },
    },
    // Android-first project; this block is here so an iOS build is not a code change,
    // and is untested by definition.
    apns: {
      headers: { 'apns-priority': high ? '10' : '5' },
      payload: { aps: { sound: 'default', 'thread-id': row.group_key || row.category } },
    },
  };
  return msg;
}

/** deep_link is jsonb, so pg may hand back an object or (pre-020 rows) a string. */
function parseLink(v) {
  if (!v) return null;
  if (typeof v === 'object') return v;
  try { return JSON.parse(v); } catch (e) { return null; }
}

// ═══════════════════════════════════════════════════════════════════════════
// THE SEND
// ═══════════════════════════════════════════════════════════════════════════

/** FCM's way of saying "this token belongs to an app that is gone". */
const DEAD_TOKEN_CODES = new Set([
  'messaging/registration-token-not-registered',
  'messaging/invalid-registration-token',
  'messaging/invalid-argument',
]);

const BATCH = 500; // sendEachForMulticast's documented hard limit.

/**
 * Deliver one notification row to every live device of its recipient.
 *
 * Returns `{sent, failed, skipped, revoked, error}` — never throws, because the only
 * caller is a timer-driven job and every outcome has to be recordable in
 * `push_error` instead of taking the process down.
 *
 * `skipped` values are all legitimate non-deliveries, and the job stamps the row as
 * handled for each of them: retrying "this user has no devices" every 4 seconds
 * forever is the failure mode that makes an outbox useless.
 */
async function sendToUser(client, userId, row) {
  if (!isConfigured()) {
    warnOnce();
    return { sent: 0, failed: 0, revoked: 0, skipped: 'unconfigured' };
  }
  if (!userId || !row) return { sent: 0, failed: 0, revoked: 0, skipped: 'no-recipient' };

  const tokens = await liveTokens(client, userId);
  if (!tokens.length) return { sent: 0, failed: 0, revoked: 0, skipped: 'no-devices' };

  let sent = 0;
  let failed = 0;
  let revoked = 0;
  const errors = [];

  for (let i = 0; i < tokens.length; i += BATCH) {
    const slice = tokens.slice(i, i + BATCH);
    let resp;
    try {
      resp = await _msg.sendEachForMulticast(buildMessage(row, slice));
    } catch (e) {
      // A whole-batch failure: a malformed message, a revoked service account, no
      // network. Not the tokens' fault, so nothing is revoked.
      failed += slice.length;
      errors.push(`${e.code || 'send-failed'}: ${e.message}`);
      continue;
    }

    sent += resp.successCount;
    failed += resp.failureCount;

    for (let k = 0; k < resp.responses.length; k++) {
      const r = resp.responses[k];
      if (r.success) continue;
      const code = (r.error && r.error.code) || 'unknown';
      errors.push(code);
      if (DEAD_TOKEN_CODES.has(code)) {
        // eslint-disable-next-line no-await-in-loop
        revoked += await revokeDevice(client, slice[k], code);
      }
    }
  }

  return {
    sent,
    failed,
    revoked,
    skipped: null,
    // Deduplicated and clamped: push_error is a diagnostic column, not a log file,
    // and 20 identical token errors say nothing 1 does not.
    error: errors.length ? [...new Set(errors)].join('; ').slice(0, 400) : null,
  };
}

/**
 * Send an ad-hoc message with no notification row behind it. Used only by
 * `POST /api/notifications/test`, which is the lever that answers "is the key
 * working?" without waiting for a real booking to be approved.
 */
async function sendRaw(client, userId, { title, body, route = null, args = null }) {
  return sendToUser(client, userId, {
    id: null, title, body, category: 'system', priority: 'high', type: 'test_push',
    deep_link: route ? { route, args: args || {} } : null,
    entity_type: null, entity_id: null, booking_id: null,
    group_key: null, group_count: 1, expires_at: null, image_url: null,
  });
}

module.exports = {
  isConfigured,
  status,
  init,
  liveTokens,
  registerDevice,
  revokeDevice,
  revokeAllForUser,
  buildMessage,
  sendToUser,
  sendRaw,
  ANDROID_CHANNEL,
};
