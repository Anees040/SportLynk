/**
 * notificationFeed.js — every READ and every state change on the notification feed.
 *
 * The reads live here rather than in the route file for the same reason chatList.js
 * does: `check_notifications.js` has to prove the feed, the badge and the collapse
 * behaviour without standing up an HTTP server, and a check script that re-implements
 * the query it is verifying proves nothing. One implementation, two callers.
 *
 * ─── WHAT "UNREAD" MEANS HERE ────────────────────────────────────────────────
 * `is_read = false AND dismissed_at IS NULL` — the exact predicate of
 * `idx_notifications_unread` and of `ux_notifications_group`, repeated in every
 * counter below. Not a stylistic choice: if the badge counted dismissed rows the
 * number would never reach zero, and if it disagreed with the collapse index by even
 * one term the badge and the feed would show different totals.
 *
 * Every count here is therefore an index-only scan of a PARTIAL index that holds
 * only the rows that matter. A user with four thousand read notifications has an
 * unread count that costs the same as a user with none.
 *
 * ─── DISMISS IS NOT DELETE, AND NOT READ ─────────────────────────────────────
 * Three distinct states, because users use all three:
 *   unread      — in the feed, counted by the badge
 *   read        — in the feed, not counted
 *   dismissed   — gone from the feed, still on disk
 * Swiping a row away is `dismissed_at = now()`, not a DELETE. The row is the only
 * record that the user was ever told, and "I never got a notification about that
 * refund" is a question the support answer to which is this table. Hard deletion is
 * offered only as "clear read", and even that is bounded.
 *
 * A dismiss also leaves `ux_notifications_group`, which is deliberate: swiping away
 * "2 new messages" must let the third message start a FRESH row rather than silently
 * bumping a counter nobody can see.
 */

const reg = require('./notificationTypes');

/** The one predicate that defines "unread", written once. */
const UNREAD = 'is_read = false AND dismissed_at IS NULL';

/** Categories a user may switch off, from the registry (never a hard-coded list). */
const MUTABLE = reg.MUTABLE_CATEGORIES;

/**
 * Shape one row for the client.
 *
 * `deepLink` is passed through exactly as the server computed it. The client's job is
 * to look `route` up in one map — it never inspects `type` to decide where to go, so
 * a new notification type needs no client release.
 */
function shape(r) {
  const entry = reg.describe(r.type);
  return {
    id: r.id,
    type: r.type,
    category: r.category,
    priority: r.priority,
    // The icon comes from the registry rather than the row: it is a property of the
    // type, so changing it must not require rewriting history.
    icon: entry.icon,
    title: r.title,
    body: r.body,
    payload: r.payload || null,
    deepLink: r.deep_link || null,
    entityType: r.entity_type,
    entityId: r.entity_id,
    bookingId: r.booking_id,
    groupKey: r.group_key,
    groupCount: r.group_count || 1,
    imageUrl: r.image_url,
    actor: r.actor_id
      ? { id: r.actor_id, name: r.actor_name || null, avatarUrl: r.actor_avatar || null }
      : null,
    isRead: r.is_read === true,
    readAt: r.read_at,
    expiresAt: r.expires_at,
    // Rendered as a disabled row: the tap would open a screen whose action is gone.
    isExpired: !!(r.expires_at && new Date(r.expires_at).getTime() <= Date.now()),
    createdAt: r.created_at,
  };
}

const SELECT_COLS = `n.id, n.type, n.category, n.priority, n.title, n.body, n.payload,
  n.deep_link, n.entity_type, n.entity_id, n.booking_id, n.group_key, n.group_count,
  n.image_url, n.actor_id, n.is_read, n.read_at, n.expires_at, n.created_at,
  a.name AS actor_name, a.avatar_url AS actor_avatar`;

/**
 * The cursor, both ways. Opaque to the client on purpose: it is a pair today and it
 * must be free to become something else without a client release, so nothing outside
 * this file parses it.
 *
 * A malformed cursor decodes to "no cursor" rather than throwing. It arrives from a
 * query string, so it is user input, and the honest failure for a bad one is the first
 * page -- not a 500 on a screen the user reached by scrolling.
 */
function encodeCursor(createdAt, id) {
  const iso = createdAt instanceof Date ? createdAt.toISOString() : String(createdAt);
  return `${iso}~${id}`;
}

function decodeCursor(cursor) {
  if (!cursor || typeof cursor !== 'string') return { at: null, id: null };
  const cut = cursor.lastIndexOf('~');
  if (cut < 1) return { at: null, id: null };
  const at = cursor.slice(0, cut);
  const id = cursor.slice(cut + 1);
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) {
    return { at: null, id: null };
  }
  if (Number.isNaN(new Date(at).getTime())) return { at: null, id: null };
  return { at, id };
}

/**
 * One page of the feed, newest first.
 *
 * ─── WHY THE CURSOR IS A PAIR AND NOT A TIMESTAMP ────────────────────────────
 * `cursor` is `"<createdAt ISO>~<id>"`, and the sort and the predicate are both on
 * the PAIR `(created_at, id)`. A timestamp alone is not a key here: one transaction
 * routinely writes several notifications -- a booking approval alerts the player and
 * the owner, generating a bracket alerts every captain -- and `created_at` defaults
 * to a per-statement clock that can still tie under load. Rows that tie are ordered
 * arbitrarily by Postgres, so with a `created_at < cursor` predicate a tie landing on
 * a page boundary DROPS every tied row after the first: notification 26 of 26 simply
 * never appears in the feed, and nothing anywhere reports an error. Row-wise
 * comparison on `(created_at, id)` makes the cursor a total order, so every row
 * appears on exactly one page.
 *
 * Offset pagination would be worse still: a notification arriving mid-scroll shifts
 * every subsequent row by one and the reader sees a duplicate.
 *
 * Dismissed rows are excluded ALWAYS — including from the read tab. Dismissed means
 * the user removed it from their feed, and a "read" filter that resurrected it would
 * make the swipe look broken.
 */
async function listFeed(client, {
  userId, limit = 25, cursor = null, category = null, unreadOnly = false,
}) {
  const lim = Math.min(Math.max(parseInt(limit, 10) || 25, 1), 50);
  const cat = category && MUTABLE.concat('system').includes(category) ? category : null;
  const at = decodeCursor(cursor);

  const { rows } = await client.query(
    `SELECT ${SELECT_COLS}
       FROM notifications n
       LEFT JOIN users a ON a.id = n.actor_id
      WHERE n.user_id = $1
        AND n.dismissed_at IS NULL
        AND ($2::text IS NULL OR n.category = $2)
        AND ($3::boolean IS FALSE OR n.is_read = false)
        AND ($4::timestamptz IS NULL
             OR (n.created_at, n.id) < ($4::timestamptz, $5::uuid))
      ORDER BY n.created_at DESC, n.id DESC
      LIMIT $6`,
    [userId, cat, !!unreadOnly, at.at, at.id, lim + 1],
  );

  // One row over the limit is fetched purely to answer hasMore without a COUNT.
  const hasMore = rows.length > lim;
  const page = hasMore ? rows.slice(0, lim) : rows;
  const last = page[page.length - 1];
  return {
    items: page.map(shape),
    hasMore,
    nextCursor: hasMore && last ? encodeCursor(last.created_at, last.id) : null,
  };
}

/**
 * The badge, and the per-category numbers the filter chips render.
 *
 * One statement, because the header needs both and two round trips for one badge is
 * two chances to disagree. `FILTER` keeps it a single pass over the partial index.
 */
async function summary(client, userId) {
  const { rows } = await client.query(
    `SELECT category, count(*)::int AS n
       FROM notifications
      WHERE user_id = $1 AND ${UNREAD}
      GROUP BY category`,
    [userId],
  );
  const byCategory = {};
  let unread = 0;
  for (const r of rows) {
    byCategory[r.category] = r.n;
    unread += r.n;
  }
  // Every category is present, zero included, so the client can render a stable set
  // of chips instead of a row that reflows as notifications arrive.
  for (const c of MUTABLE.concat('system')) {
    if (byCategory[c] === undefined) byCategory[c] = 0;
  }
  return { unread, byCategory };
}

// ═══════════════════════════════════════════════════════════════════════════
// STATE CHANGES
// ═══════════════════════════════════════════════════════════════════════════
//
// Every one of these is scoped `AND user_id = $userId`. That is the authorisation:
// an id belonging to somebody else matches no row and returns 0, which the route
// turns into a 404 rather than a 403 — telling a caller "that notification exists but
// is not yours" is more than they are entitled to know.

/** Mark one row read. Idempotent; `read_at` is not overwritten on a second call. */
async function markRead(client, userId, id) {
  const { rowCount } = await client.query(
    `UPDATE notifications
        SET is_read = true, read_at = COALESCE(read_at, now())
      WHERE id = $1 AND user_id = $2 AND is_read = false`,
    [id, userId],
  );
  if (rowCount) return 1;
  // Already read, or not theirs. Distinguish, so the route can 404 honestly.
  const { rowCount: exists } = await client.query(
    'SELECT 1 FROM notifications WHERE id = $1 AND user_id = $2', [id, userId],
  );
  return exists ? 0 : -1;
}

/**
 * Put one row back to unread.
 *
 * `group_count` is RESET to 1 and `group_key` is left in place, which needs saying:
 * an unread row re-enters `ux_notifications_group`, so the next message in that
 * thread will bump this row again. Leaving the old count would make the row read
 * "4 new messages" when only one of them is genuinely new since the user looked.
 */
async function markUnread(client, userId, id) {
  const { rowCount } = await client.query(
    `UPDATE notifications
        SET is_read = false, read_at = NULL, group_count = 1
      WHERE id = $1 AND user_id = $2 AND dismissed_at IS NULL`,
    [id, userId],
  );
  return rowCount ? 1 : -1;
}

/** Mark everything read, or everything in one category. Returns the count. */
async function markAllRead(client, userId, category = null) {
  const cat = category && MUTABLE.concat('system').includes(category) ? category : null;
  const { rowCount } = await client.query(
    `UPDATE notifications
        SET is_read = true, read_at = COALESCE(read_at, now())
      WHERE user_id = $1 AND ${UNREAD}
        AND ($2::text IS NULL OR category = $2)`,
    [userId, cat],
  );
  return rowCount;
}

/**
 * Swipe one row away. Also marks it read, because a dismissed row that still counted
 * toward the badge would leave a number the user cannot clear by any means.
 */
async function dismiss(client, userId, id) {
  const { rowCount } = await client.query(
    `UPDATE notifications
        SET dismissed_at = now(), is_read = true, read_at = COALESCE(read_at, now())
      WHERE id = $1 AND user_id = $2 AND dismissed_at IS NULL`,
    [id, userId],
  );
  return rowCount ? 1 : -1;
}

/**
 * "Clear read" — the only hard delete offered, and deliberately narrow.
 *
 * Unread rows are never touched (clearing something you have not seen is data loss
 * dressed as tidying), and rows younger than an hour are kept so that a tap on Clear
 * immediately after a batch arrives cannot erase what just came in. Dismissed rows go
 * too: the user has already removed them from view.
 */
async function clearRead(client, userId, category = null) {
  const cat = category && MUTABLE.concat('system').includes(category) ? category : null;
  const { rowCount } = await client.query(
    `DELETE FROM notifications
      WHERE user_id = $1
        AND (is_read = true OR dismissed_at IS NOT NULL)
        AND created_at < now() - interval '1 hour'
        AND ($2::text IS NULL OR category = $2)`,
    [userId, cat],
  );
  return rowCount;
}

// ═══════════════════════════════════════════════════════════════════════════
// PREFERENCES
// ═══════════════════════════════════════════════════════════════════════════
//
// Stored as `users.notification_prefs jsonb DEFAULT '{}'` and read by pushJob before
// every send. Two rules shape the whole design:
//
//   1. AN ABSENT KEY MEANS ON. A user who has never opened the settings screen has
//      `{}` and receives everything, and the column only ever holds what they
//      actually changed. The alternative — writing 9 categories × 2 channels of
//      `true` at signup — means every future category defaults to off for existing
//      users, silently, and nobody notices for a release or two.
//
//   2. THE SERVER NORMALISES ON READ. `getPrefs` always returns a complete object, so
//      the settings screen renders a full form from one GET and never has to know
//      what a default is. The client is a view of this, not a second opinion about it.
//
// `inApp` is honoured by the Flutter side for the foreground banner only — it can
// never suppress the ROW or the badge. Muting is about interruption, not about
// hiding what happened.

/** A complete, valid prefs object with nothing switched off. */
function defaultPrefs() {
  const push = {};
  const inApp = {};
  for (const c of MUTABLE) { push[c] = true; inApp[c] = true; }
  return {
    muteAll: false,
    push,
    inApp,
    quietHours: { enabled: false, start: '22:00', end: '07:00' },
  };
}

/** Merge what is stored over the defaults, dropping anything unrecognised. */
function normalisePrefs(stored) {
  const out = defaultPrefs();
  const s = stored && typeof stored === 'object' ? stored : {};
  if (s.muteAll === true) out.muteAll = true;
  for (const channel of ['push', 'inApp']) {
    const src = s[channel];
    if (!src || typeof src !== 'object') continue;
    for (const c of MUTABLE) {
      // Explicit false only. A stored `true` is the default anyway, and a stored
      // string or number is a client bug that must not become a stored preference.
      if (src[c] === false) out[channel][c] = false;
    }
  }
  const q = s.quietHours;
  if (q && typeof q === 'object') {
    out.quietHours.enabled = q.enabled === true;
    const s1 = validHM(q.start);
    const e1 = validHM(q.end);
    if (s1) out.quietHours.start = s1;
    if (e1) out.quietHours.end = e1;
  }
  return out;
}

/**
 * "22:00" → "22:00"; "25:99", "7:5" and "abc" → null.
 *
 * The range check matters as much as the shape one: a stored "25:99" is rejected by
 * pushJob's parser and falls back to 22:00, so quiet hours would still WORK — but the
 * settings screen would render "25:99" back at the user as if it were their setting.
 * Re-emitted zero-padded so the stored form is canonical and two users who typed
 * "7:00" and "07:00" have byte-identical preferences.
 */
function validHM(v) {
  // 1-2 digits on BOTH sides. A time picker always sends HH:mm, but the settings
  // screen is not the only caller of a JSON API, and "9:5" has exactly one sensible
  // reading. Rejecting it would silently substitute the DEFAULT window instead, which
  // is the worst of the three outcomes: the user set a quiet window, was shown a
  // different one, and nothing reported an error. pushJob.parseHM accepts the same
  // shape -- the two must agree or a window that reads 09:05 on screen would be
  // enforced as something else.
  const m = /^(\d{1,2}):(\d{1,2})$/.exec(String(v == null ? '' : v).trim());
  if (!m) return null;
  const h = Number(m[1]);
  const mi = Number(m[2]);
  if (h > 23 || mi > 59) return null;
  return `${String(h).padStart(2, '0')}:${String(mi).padStart(2, '0')}`;
}

async function getPrefs(client, userId) {
  const { rows } = await client.query(
    'SELECT notification_prefs FROM users WHERE id = $1', [userId],
  );
  return {
    prefs: normalisePrefs(rows[0] && rows[0].notification_prefs),
    // The client renders one row per category and needs to know which ones exist and
    // which are unmutable — from the registry, so adding a category is a server change.
    categories: MUTABLE,
    unmutable: ['system'],
  };
}

/**
 * Write preferences.
 *
 * The incoming body is normalised through the SAME function used on read, so an
 * unknown category, a string where a boolean belongs, or a malformed "25:99" cannot
 * be stored — they are dropped and the response shows the caller exactly what was
 * kept. Validating on the way in and on the way out with one function is what stops
 * the two from drifting.
 *
 * The full normalised object is written rather than a jsonb merge: it is small, and a
 * partial merge makes "switch this back on" ambiguous between absent and true.
 */
async function setPrefs(client, userId, body) {
  const next = normalisePrefs(body);
  await client.query(
    'UPDATE users SET notification_prefs = $2::jsonb WHERE id = $1',
    [userId, JSON.stringify(next)],
  );
  return { prefs: next, categories: MUTABLE, unmutable: ['system'] };
}

module.exports = {
  UNREAD,
  shape,
  listFeed,
  summary,
  markRead,
  markUnread,
  markAllRead,
  dismiss,
  clearRead,
  defaultPrefs,
  normalisePrefs,
  validHM,
  getPrefs,
  setPrefs,
};
