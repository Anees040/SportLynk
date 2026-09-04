/**
 * pushJob.js — the transactional outbox drain.
 *
 * Why push is a job and not a function call
 * `notify()` is called from inside money transactions that are holding `FOR UPDATE`
 * locks on wallet rows: approving a booking releases escrow and writes the alert in
 * one transaction, on purpose, so a rolled-back refund can never leave a "you were
 * refunded" notification behind. An HTTPS call to Firebase from inside that
 * transaction would hold those wallet locks open across a network round trip to
 * Google — and a Firebase outage would become a booking outage.
 *
 * So the notification row is the outbox. `sent_push = false` is a work item, this job
 * drains it a few seconds later, and every consequence is the desired one:
 *
 *   · the 38 existing notify() call sites did not change at all;
 *   · the alert is atomic with the money that caused it;
 *   · a server crash loses nothing — the row is still there, still unsent;
 *   · a failure is retryable, and `push_attempts` bounds the retries;
 *   · "why didn't my phone buzz?" is answerable with one SELECT, because the reason
 *     is written into `push_error` rather than into a log file that has rotated away.
 *
 * The cost is up to one tick (~4 s) of delivery latency, which is invisible on a
 * locked phone and is the reason the tick is 4 seconds rather than 5 minutes like the
 * money sweeps.
 *
 * This job also owns the LIVE in-app badge
 * Every drained row emits `notification:new` to `u:<userId>`, whether or not a push
 * was sent, whether or not Firebase is configured at all. That is deliberate: the
 * bell badge, the feed and the tray then have one source of truth and one code path,
 * so a notification can never appear in the tray but not in the app. It also means
 * the entire feature is demonstrable with no Firebase key — everything works except
 * the tray banner.
 *
 * Why a two-phase claim
 * Phase 1 claims a batch in one atomic statement (`push_attempts + 1` on rows chosen
 * with `FOR UPDATE SKIP LOCKED`) and commits. Phase 2 sends and stamps, outside any
 * transaction. Holding a lock across the FCM call would reintroduce exactly the
 * problem this job exists to solve, and bumping the attempt counter before the send
 * is what makes a crash mid-send cost at most MAX_ATTEMPTS retries instead of
 * looping forever on a row that kills the process.
 *
 * `SKIP LOCKED` is what makes two server instances safe: the second one steps over
 * whatever the first has claimed instead of double-sending.
 */

const pool = require('../db/pool');
const bus = require('../realtime/bus');
const push = require('../services/pushService');
const { POLICY } = require('../utils/escrow');

/**
 * ~4 s, and never slower. POLICY.SWEEP_INTERVAL_MS is 5 minutes for the money sweeps
 * and is overridden down to seconds by SL_TEST_SWEEP_SECONDS; taking the minimum of
 * the two means the demo override speeds this job up like every other sweep, while
 * the 5-minute default never slows the tray down to something that reads as broken.
 */
const TICK_MS = Math.max(1000, Math.min(4000, POLICY.SWEEP_INTERVAL_MS));

/** Rows per sweep. 100 rows × up to 20 devices is already a big fan-out. */
const BATCH = 100;

/**
 * A row this old is not pushed.
 *
 * Two reasons. First, the honest one: a banner saying "your booking was approved"
 * that arrives an hour late is worse than no banner, because the user has already
 * seen it in the app. Second, the practical one: `notifications` already holds a
 * backlog of ~190 rows written before this job existed, every one of them
 * `sent_push = false`. Without a cutoff the first tick would fire two hundred
 * banners at a demo phone, and `idx_notifications_outbox` would keep those dead rows
 * forever — every 4-second scan walking a list that can never shrink.
 */
const MAX_AGE_MS = 60 * 60 * 1000;

/** After this many tries the row is closed with whatever the last error was. */
const MAX_ATTEMPTS = 3;

/** One sweep at a time: a slow fan-out must not overlap the next tick. */
let _running = false;

// Preferences and quiet hours — enforced here, server-side
//
// A preference the client honours is not a preference, it is a suggestion: the
// server would still have sent the push, the phone would still have buzzed, and the
// app would have hidden the row afterwards. Both checks therefore live in the job,
// which is the last code that runs before Firebase is called.
//
// `users.notification_prefs` is `'{}'::jsonb` by default and an absent key means on.
// That way a user who has never opened the settings screen gets everything, and the
// column only ever stores what they changed.
//
//   {
//     "muteAll":    false,
//     "push":       { "chat": false, "tournament": false },   // per category
//     "quietHours": { "enabled": true, "start": "22:00", "end": "07:00" }
//   }
//
// What a suppressed push does *not* do
// It never suppresses the notification row. Muting chat keeps the device quiet;
// it does not mean the message is deleted, and the badge still counts it. Conflating
// "don't buzz me" with "don't tell me" is how apps lose messages.
//
// 'system' bypasses both checks
// notificationTypes.js already declares 'system' unmutable (it is absent from
// MUTABLE_CATEGORIES), and an account suspension is not something a user gets to
// opt out of. Quiet hours are treated the same way for the same reason — the two
// rules have to agree, or a suspension at 23:00 would be silently dropped by the
// half that was not consulted.

/** Wall-clock hour:minute in the app's timezone, as minutes since midnight. */
function localMinutes(when = new Date()) {
  // Slot times are stored as PKT wall-clock throughout SportLynk (POLICY.TIMEZONE),
  // and "10pm" in a Pakistani user's settings means 10pm in Karachi, not 10pm UTC.
  // Deriving it from the same constant keeps quiet hours consistent with every other
  // time the user sees in the app.
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone: POLICY.TIMEZONE, hour: '2-digit', minute: '2-digit', hour12: false,
  }).formatToParts(when);
  const h = Number(parts.find((p) => p.type === 'hour').value);
  const m = Number(parts.find((p) => p.type === 'minute').value);
  return (h % 24) * 60 + m;
}

function parseHM(s, fallback) {
  // Same shape notificationFeed.validHM accepts, deliberately: the value this reads
  // was normalised by that function on the way in, and a stricter parser here would
  // silently enforce the fallback window instead of the one the user was shown.
  const m = /^(\d{1,2}):(\d{1,2})$/.exec(String(s || '').trim());
  if (!m) return fallback;
  const h = Number(m[1]);
  const mi = Number(m[2]);
  if (h > 23 || mi > 59) return fallback;
  return h * 60 + mi;
}

/**
 * Is `when` inside the user's quiet window?
 *
 * The window wraps midnight in the normal case (22:00 → 07:00), which a naive
 * `start <= t && t < end` gets exactly backwards — it would go quiet from 7am to
 * 10pm and buzz all night. Hence the two-branch comparison.
 */
function inQuietHours(prefs, when = new Date()) {
  const q = prefs && prefs.quietHours;
  if (!q || q.enabled !== true) return false;
  const start = parseHM(q.start, 22 * 60);
  const end = parseHM(q.end, 7 * 60);
  if (start === end) return false; // a zero-length window means "off", not "always"
  const t = localMinutes(when);
  return start < end ? (t >= start && t < end) : (t >= start || t < end);
}

/**
 * Why this row must not be pushed, or null to send it.
 * Returned as a short string because it is written verbatim into `push_error`.
 */
function suppressionReason(row, prefs) {
  if (row.category === 'system') return null; // unmutable, by design
  const p = prefs || {};
  if (p.muteAll === true) return 'muted: all notifications';
  if (p.push && p.push[row.category] === false) return `muted: ${row.category}`;
  if (inQuietHours(p)) return 'quiet hours';
  return null;
}

// The sweep

/**
 * Retire rows that are past MAX_AGE_MS or out of attempts, in one statement.
 *
 * This is what keeps `idx_notifications_outbox` bounded. The partial index only holds
 * `sent_push = false` rows, so closing a stale row removes it from the index, and the
 * scan below stays a handful of rows forever instead of growing without limit. The
 * reason is written into `push_error` rather than merely being dropped, because "it
 * was too old by the time the server came back" is a real answer to a real question.
 */
async function retireStale(runner) {
  const { rowCount } = await runner.query(
    `UPDATE notifications
        SET sent_push = true,
            push_error = CASE WHEN push_attempts >= $1
              THEN 'gave up after ' || push_attempts || ' attempts: ' || COALESCE(push_error, 'unknown')
              ELSE 'not pushed: older than ' || $2 || ' min when the outbox ran' END
      WHERE sent_push = false
        AND (created_at < now() - ($2 || ' minutes')::interval OR push_attempts >= $1)`,
    [MAX_ATTEMPTS, Math.round(MAX_AGE_MS / 60000)],
  );
  return rowCount;
}

/**
 * Phase 1 — claim a batch atomically and bump its attempt counter.
 *
 * One statement, so the claim and the counter cannot diverge. `FOR UPDATE SKIP
 * LOCKED` inside the sub-select is what makes a second server instance step over
 * these rows rather than send them twice.
 */
async function claimBatch(runner) {
  const { rows } = await runner.query(
    `UPDATE notifications n
        SET push_attempts = n.push_attempts + 1
      WHERE n.id IN (
        SELECT id FROM notifications
          WHERE sent_push = false
            AND created_at >= now() - ($1 || ' minutes')::interval
            AND push_attempts < $2
          ORDER BY created_at
          FOR UPDATE SKIP LOCKED
          LIMIT $3
      )
      RETURNING n.id, n.user_id, n.booking_id, n.type, n.title, n.body, n.category,
                n.priority, n.deep_link, n.entity_type, n.entity_id, n.group_key,
                n.group_count, n.image_url, n.expires_at, n.created_at, n.push_attempts`,
    [Math.round(MAX_AGE_MS / 60000), MAX_ATTEMPTS, BATCH],
  );
  return rows;
}

/** Prefs + active flag for everybody in this batch, in one read. */
async function loadRecipients(runner, userIds) {
  if (!userIds.length) return new Map();
  const { rows } = await runner.query(
    'SELECT id, notification_prefs, is_active FROM users WHERE id = ANY($1::uuid[])',
    [userIds],
  );
  return new Map(rows.map((r) => [String(r.id), r]));
}

/** Close one row out. `error` doubles as the human explanation for a skip. */
async function stamp(runner, id, { error = null }) {
  await runner.query(
    `UPDATE notifications
        SET sent_push = true, pushed_at = now(), push_error = $2
      WHERE id = $1`,
    [id, error ? String(error).slice(0, 400) : null],
  );
}

/**
 * One drain.
 *
 * Every claimed row ends up stamped and emitted exactly once, whatever happens — a
 * row that is claimed and then neither sent nor closed is a row that gets its
 * attempt counter burned three times and then retires with "unknown", which is the
 * one outcome that would make this table lie.
 */
async function drainOutbox(externalClient = null) {
  // An external client is how check_notifications.js drives this inside its own
  // transaction and rolls the whole thing back: every query below runs on the caller
  // connection, so a verification run can observe all four outcomes without stamping
  // a single row that survives it. The job itself always passes nothing and gets its
  // own pooled connection.
  if (_running && !externalClient) return { claimed: 0 };
  if (!externalClient) _running = true;
  const tally = {
    claimed: 0, pushed: 0, suppressed: 0, expired: 0, inactive: 0, noDevice: 0,
    failed: 0, revoked: 0, retired: 0,
  };

  const client = externalClient || await pool.connect();
  try {
    tally.retired = await retireStale(client);
    const rows = await claimBatch(client);
    tally.claimed = rows.length;
    if (!rows.length) return tally;

    const recips = await loadRecipients(client, [...new Set(rows.map((r) => String(r.user_id)))]);
    const configured = push.isConfigured();

    // eslint-disable-next-line no-restricted-syntax
    for (const row of rows) {
      const user = recips.get(String(row.user_id));
      // Computed once, before the chain, so it is not evaluated twice and so its
      // position in the chain is a visible decision rather than a side effect.
      const muted = user ? suppressionReason(row, user.notification_prefs) : null;
      let error = null;

      if (!user) {
        error = 'recipient no longer exists';
      } else if (user.is_active === false) {
        // A suspended account is not messaged. The row stays in the feed for when
        // they are reinstated; buzzing a suspended user's phone about a booking they
        // can no longer attend is noise on top of bad news.
        error = 'recipient inactive';
        tally.inactive++;
      } else if (row.expires_at && new Date(row.expires_at).getTime() <= Date.now()) {
        // A challenge alert past its 48h TTL would open a screen whose Accept button
        // is gone. The in-app row is still there and reads as expired; the banner is
        // the part that would mislead.
        error = 'expired before push';
        tally.expired++;
      } else if (muted) {
        // Before the `configured` check, on purpose. Both can be true at once, and
        // the user's own setting is the more specific and more actionable answer to
        // "why didn't my phone buzz?" — "you muted booking alerts" is something they
        // can change; "the server has no Firebase key" is not. Checking it first is
        // also what makes the rule observable while push ships dormant: with the
        // order reversed every suppression would be recorded as 'push disabled', and
        // check_notifications.js could not prove preferences are enforced at all.
        error = muted;
        tally.suppressed++;
      } else if (!configured) {
        error = `push disabled: ${push.status().reason}`;
      } else {
        const res = await push.sendToUser(client, row.user_id, row);
        tally.revoked += res.revoked || 0;
        if (res.skipped === 'no-devices') {
          // Not a failure: the account has simply never opened the app on a phone
          // that granted notification permission.
          error = 'no registered device';
          tally.noDevice++;
        } else if (res.sent > 0) {
          tally.pushed++;
          // One device of three failing is still a delivered notification, so the
          // row is a success that records what went wrong on the others.
          if (res.error) error = `partial: ${res.error}`;
        } else {
          error = res.error || 'no delivery';
          tally.failed++;
        }
      }

      await stamp(client, row.id, { error });

      // Always, and last. The in-app badge is not conditional on Firebase, on a
      // preference or on a successful send — the row exists, so the bell must move.
      // Emitting after the stamp means a client that re-reads /summary on this event
      // cannot see a half-written row.
      bus.emitToUsers(row.user_id, 'notification:new', {
        id: row.id,
        type: row.type,
        category: row.category,
        priority: row.priority,
        title: row.title,
        body: row.body,
        deepLink: row.deep_link || null,
        groupKey: row.group_key,
        groupCount: row.group_count,
        imageUrl: row.image_url,
        createdAt: row.created_at,
      });
    }
    return tally;
  } catch (e) {
    // Never rethrow from a timer callback: an unhandled rejection here takes the
    // whole server down for something the next tick would retry in four seconds.
    console.error('[PushJob] drain failed:', e.message);
    return tally;
  } finally {
    if (!externalClient) { client.release(); _running = false; }
  }
}

/** The tick. Silent when there is nothing to do — this runs every 4 seconds. */
async function tick() {
  const t = await drainOutbox();
  if (!t.claimed && !t.retired) return;
  const bits = Object.entries(t)
    .filter(([, v]) => v > 0)
    .map(([k, v]) => `${k}=${v}`)
    .join(' ');
  console.log(`[PushJob] ${bits}`);
}

function startPushJob() {
  const st = push.status();
  console.log(`[PushJob] Started — outbox drains every ${TICK_MS / 1000}s, `
    + `${st.configured ? `FCM ready (project ${st.projectId})` : `FCM OFF (${st.reason})`}.`);
  if (!st.configured) {
    console.log('[PushJob]   → in-app notifications and live badges work regardless; '
      + 'set FIREBASE_SERVICE_ACCOUNT to enable tray delivery.');
  }
  // Offset from the other five jobs so six sweeps do not all fire into the same
  // connection pool the instant the server finishes booting.
  setTimeout(tick, 6000);
  setInterval(tick, TICK_MS);
}

module.exports = {
  startPushJob, drainOutbox, tick, inQuietHours, suppressionReason, localMinutes,
  TICK_MS, MAX_AGE_MS, MAX_ATTEMPTS,
};
