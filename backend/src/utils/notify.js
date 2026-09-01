/**
 * Notification rows — written inside the same transaction as the ledger move that
 * caused them, so a rolled-back money move never leaves a stray alert.
 *
 * What changed in S.7 wave C
 * The signature did not. Thirty-eight call sites across jobs, routes and services
 * pass `{ userId, bookingId?, type, title, body?, payload? }` and every one of
 * them still does — moving them would have been the largest and least useful diff
 * in the wave, and a notification's call site is exactly the wrong place to
 * decide what category it belongs to or where tapping it goes. Those facts are
 * properties of the TYPE, they are identical at every site that emits it, and
 * they now come from `utils/notificationTypes.js`.
 *
 * So this function grew a middle: it looks the type up in the registry and stamps
 * `category`, `priority`, `deep_link`, `entity_type`, `entity_id` and `group_key`
 * onto the row before inserting it. The caller supplies the sentence; the registry
 * supplies the behaviour.
 *
 * The collapse UPSERT
 * When the registry gives the type a `group_key` (chat messages, join requests),
 * the write becomes an upsert against `ux_notifications_group` — the UNIQUE
 * Partial index from migration 020 — and a repeat bumps `group_count` instead of
 * inserting a second row. Three messages from one person are one feed row and one
 * tray banner reading "3 new messages", which is what every professional app
 * does and what the notifications table could not represent before 020.
 *
 * The index is partial on `is_read = false AND dismissed_at IS NULL`, and the
 * ON CONFLICT clause repeats that predicate verbatim — Postgres can only infer a
 * partial unique index when the arbiter predicate implies the index predicate,
 * and a mismatch is a runtime 42P10, not a compile error. That is why the shape of
 * this query is asserted by run_migration_020.js's probes rather than trusted.
 *
 * Once a collapsed row is read or dismissed it leaves the index, so the next
 * message starts a fresh row: seeing "2 new messages" and then being told nothing
 * about the third is the failure mode that rule exists to prevent.
 *
 * Why every degradation path is still here
 * The whole body is SAVEPOINT-wrapped, and a missing table (42P01), a missing
 * column (42703) or a missing index (42P10) each fall back to a simpler write
 * rather than failing. This is not defensive habit: `notify()` is called while
 * holding `FOR UPDATE` locks on wallet rows mid-settlement. The money must commit
 * even on a database that is one migration behind — losing an alert costs a
 * refresh, losing a refund costs money.
 *
 * Nothing here emits a socket event or sends a push. `sent_push = false` makes the
 * row its own outbox, and `jobs/pushJob.js` drains it after the commit — an HTTPS
 * call to FCM from inside this function would hold those locks across a network
 * round trip.
 */

const reg = require('./notificationTypes');

// Every column 020 added that this writer fills. Kept as one list so the
// degradation path below can be reasoned about in one place.
// created_at is written explicitly as clock_timestamp() rather than left to the
// column default now(). now() is the transaction timestamp, so several notifications
// written in one transaction -- a booking approval alerts the player and the owner, a
// generated bracket alerts every captain -- would land on a byte-identical created_at.
// The feed sorts and pages on (created_at, id), so a tie is survivable there; it is
// still wrong in the feed itself, where two alerts from one transaction would sort
// arbitrarily and "newest first" would stop meaning anything. chatCore.insertMessage
// uses clock_timestamp() for the same reason.
const FULL_COLUMNS = '(user_id, booking_id, type, title, body, payload, category, '
  + 'priority, deep_link, entity_type, entity_id, actor_id, image_url, expires_at, '
  + 'group_key, created_at)';

/** The 15 bound parameters, then the clock. Shared by both inserts below. */
const FULL_VALUES = 'VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15, clock_timestamp())';

/**
 * Write one notification.
 *
 * @param client an OPEN transaction client — never the pool. Every caller is
 *   already inside a transaction, and that is the point: the alert and the money
 *   move commit together or not at all.
 * @param userId recipient. A falsy id is a no-op (a booking with no owner row
 *   yet, a captain who left) rather than an error.
 * @param type must be registered in notificationTypes.js. An unregistered type
 *   still writes — as category 'system' with no deep link — and the boot
 *   assertion is what keeps that from happening quietly.
 * @param payload the structured facts behind the sentence: which match, which
 *   team, how many ELO points. The registry reads ids out of it to build the
 *   deep link, so it is now load-bearing rather than decorative.
 * @param actorId who caused this, when it was a person. Renders the avatar.
 * @param expiresAt when the row stops being actionable (a challenge's 48h TTL).
 *   pushJob skips an expired row: buzzing about a challenge that can no longer be
 *   accepted is worse than silence.
 */
async function notify(client, {
  userId, bookingId = null, type, title, body = null, payload = null,
  actorId = null, imageUrl = null, expiresAt = null,
  category = null, priority = null,
}) {
  if (!userId) return null;

  const ctx = { userId, bookingId, payload, type };
  const entry = reg.describe(type);
  const link = reg.safeDeepLink(type, ctx);
  const { entityType, entityId } = reg.entityFor(type, ctx);
  const groupKey = reg.groupKeyFor(type, ctx);

  const row = {
    userId,
    bookingId,
    type,
    title,
    body,
    payload,
    // An explicit category/priority from the caller wins — used by the admin
    // routes, where one type ('account_suspended') is sent by a human and its
    // urgency is not a property of the type alone.
    category: category || entry.category,
    priority: priority || entry.priority,
    deepLink: link ? JSON.stringify(link) : null,
    entityType,
    entityId,
    actorId,
    imageUrl,
    expiresAt,
    groupKey,
  };

  await client.query('SAVEPOINT sl_notify');
  try {
    const out = groupKey
      ? await insertGrouped(client, row)
      : await insertPlain(client, row);
    await client.query('RELEASE SAVEPOINT sl_notify');
    return out;
  } catch (e) {
    await client.query('ROLLBACK TO SAVEPOINT sl_notify');
    return degrade(client, row, e);
  }
}

/** The ordinary write: one row, every registry-derived column filled. */
async function insertPlain(client, r) {
  const { rows } = await client.query(
    `INSERT INTO notifications ${FULL_COLUMNS} ${FULL_VALUES}
     RETURNING id, group_count`,
    [r.userId, r.bookingId, r.type, r.title, r.body, r.payload, r.category,
      r.priority, r.deepLink, r.entityType, r.entityId, r.actorId, r.imageUrl,
      r.expiresAt, r.groupKey],
  );
  return { id: rows[0].id, groupCount: rows[0].group_count, collapsed: false };
}

/**
 * The collapse write.
 *
 * The WHERE clause after ON CONFLICT is the index predicate, repeated word for
 * word. It is not a filter on which conflicts to handle — it is how Postgres
 * identifies which partial index to use as the arbiter, and it must imply the
 * index's own predicate or the statement fails with 42P10 ("there is no unique or
 * exclusion constraint matching the ON CONFLICT specification").
 *
 * `created_at = clock_timestamp()` on the bump is deliberate: a collapsed row must
 * sort to the top of the feed when the third message arrives, not stay where the first
 * one landed. `title`/`body` are rewritten from the registry's collapsed wording, so
 * the row reads "3 new messages" rather than repeating the newest one as if it
 * were the only one.
 *
 * `sent_push = false` is reset too. The tray banner for "2 new messages" is stale
 * the moment the third arrives, and re-pushing a collapsed row replaces the old
 * banner (same collapseKey) rather than stacking a second one.
 */
async function insertGrouped(client, r) {
  const { rows } = await client.query(
    `INSERT INTO notifications ${FULL_COLUMNS} ${FULL_VALUES}
     ON CONFLICT (user_id, group_key)
       WHERE group_key IS NOT NULL AND is_read = false AND dismissed_at IS NULL
     DO UPDATE SET
       group_count = notifications.group_count + 1,
       created_at  = clock_timestamp(),
       title       = EXCLUDED.title,
       body        = EXCLUDED.body,
       payload     = EXCLUDED.payload,
       deep_link   = EXCLUDED.deep_link,
       actor_id    = EXCLUDED.actor_id,
       image_url   = EXCLUDED.image_url,
       priority    = EXCLUDED.priority,
       sent_push   = false,
       push_error  = NULL
     RETURNING id, group_count`,
    [r.userId, r.bookingId, r.type, r.title, r.body, r.payload, r.category,
      r.priority, r.deepLink, r.entityType, r.entityId, r.actorId, r.imageUrl,
      r.expiresAt, r.groupKey],
  );

  const id = rows[0].id;
  const count = rows[0].group_count;

  // Rewrite the wording only once it is a group. Doing this in a second statement
  // rather than in the upsert keeps the SQL readable and costs one small indexed
  // update on a path that only runs for a genuine repeat.
  if (count > 1) {
    const text = reg.collapsedText(r.type, count, { title: r.title, body: r.body });
    if (text.title !== r.title || text.body !== r.body) {
      await client.query(
        'UPDATE notifications SET title = $2, body = $3 WHERE id = $1',
        [id, text.title, text.body],
      );
    }
  }

  return { id, groupCount: count, collapsed: count > 1 };
}

/**
 * Everything that can go wrong with the write above, and the simpler write to try
 * instead. Runs after the savepoint has already been rolled back, so each attempt
 * starts from a clean subtransaction.
 *
 * The order matters: 42P10 (no matching index) is retried as a plain insert, which
 * still delivers the notification and merely fails to collapse it. Only after that
 * does the write fall back to the pre-020 column set.
 */
async function degrade(client, r, e) {
  if (e.code === '42P01') {
    console.warn('[notify] notifications table missing — run node run_migration_010.js');
    return null;
  }

  // The collapse index is absent (020 not applied, or hand-dropped). Insert the
  // row without grouping: two rows for two messages is a worse feed, not a broken
  // one, and the alternative is losing the alert entirely.
  if (e.code === '42P10') {
    console.warn('[notify] ux_notifications_group missing — run node run_migration_020.js '
      + '(notifications will not collapse until then)');
    return attempt(client, () => insertPlain(client, { ...r, groupKey: null }))
      .catch((inner) => degradeColumns(client, r, inner));
  }

  // A column 020 adds is missing on this database.
  if (e.code === '42703') return degradeColumns(client, r, e);

  // Anything else is a real bug (a CHECK the registry violates, a bad FK) and must
  // not be swallowed — a wrong category is a fixable defect, and hiding it here is
  // how it would survive to the demo. The caller's transaction rolls back.
  throw e;
}

/**
 * The pre-020 shapes, in order: with payload (pre-020, post-013), then without
 * (pre-013). Both drop the registry columns, so the row still says what happened
 * and simply has no category, no priority and no deep link.
 */
async function degradeColumns(client, r, e) {
  if (e && e.code === '42P01') {
    console.warn('[notify] notifications table missing — run node run_migration_010.js');
    return null;
  }
  console.warn('[notify] 020 columns missing — writing a plain row '
    + '(no category/priority/deep link until run_migration_020.js is applied)');

  try {
    return await attempt(client, async () => {
      const { rows } = await client.query(
        `INSERT INTO notifications (user_id, booking_id, type, title, body, payload)
         VALUES ($1,$2,$3,$4,$5,$6) RETURNING id`,
        [r.userId, r.bookingId, r.type, r.title, r.body, r.payload],
      );
      return { id: rows[0].id, groupCount: 1, collapsed: false, degraded: true };
    });
  } catch (inner) {
    if (inner.code !== '42703') {
      if (inner.code === '42P01') {
        console.warn('[notify] notifications table missing — run node run_migration_010.js');
        return null;
      }
      throw inner;
    }
  }

  // No payload column either (pre-013). The alert itself still matters more than
  // the structured extras.
  try {
    return await attempt(client, async () => {
      const { rows } = await client.query(
        `INSERT INTO notifications (user_id, booking_id, type, title, body)
         VALUES ($1,$2,$3,$4,$5) RETURNING id`,
        [r.userId, r.bookingId, r.type, r.title, r.body],
      );
      return { id: rows[0].id, groupCount: 1, collapsed: false, degraded: true };
    });
  } catch (inner) {
    if (inner.code === '42P01') {
      console.warn('[notify] notifications table missing — run node run_migration_010.js');
      return null;
    }
    throw inner;
  }
}

/**
 * Run one write inside its own savepoint, rolling back on failure.
 *
 * Every retry needs this: a failed statement poisons the whole transaction until
 * something rolls back to a savepoint, so a second attempt without one would fail
 * with 25P02 ("current transaction is aborted") and take the money with it.
 */
async function attempt(client, fn) {
  await client.query('SAVEPOINT sl_notify_retry');
  try {
    const out = await fn();
    await client.query('RELEASE SAVEPOINT sl_notify_retry');
    return out;
  } catch (e) {
    await client.query('ROLLBACK TO SAVEPOINT sl_notify_retry');
    throw e;
  }
}

module.exports = { notify };
