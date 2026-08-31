/**
 * One row behind every administrative write.
 *
 * WHY THIS EXISTS
 * "Who changed this, and what did it look like before?" is the first question
 * anybody asks of an admin panel — a viva panel included. Suspending an account,
 * ruling on a dispute and moving the commission percentage are all irreversible
 * from the user's side, so each one leaves a row here with the BEFORE and AFTER
 * state as jsonb. `admin_audit.admin_id` is `ON DELETE SET NULL` (migration 020
 * §7) on purpose: removing an admin must not erase what they did.
 *
 * WHY IT CAN NEVER FAIL THE OPERATION IT RECORDS
 * Same discipline as `utils/notify.js`, and for the same reason: this runs inside
 * transactions that move money and apply Elo. A missing table, a column added in
 * a later migration, an oversized jsonb — none of those may roll back a dispute
 * ruling that has already credited two wallets. So the whole body is
 * SAVEPOINT-wrapped and a failure is swallowed with a warning.
 *
 * That is a deliberate asymmetry, and it is the right way round: an audit row
 * without its action is a lie, an action without its audit row is a gap. A gap is
 * visible (the operation is in the data, the audit is not); a rolled-back
 * operation with a successful audit row would be invisible and wrong.
 */

/**
 * Actions this module knows. Free-form text is accepted — the column is `text`
 * and a future wave must not need a migration to log something new — but naming
 * them here keeps the vocabulary consistent and greppable, which is what makes
 * the trail searchable a year later.
 */
const ACTIONS = Object.freeze({
  USER_SUSPEND: 'user.suspend',
  USER_REINSTATE: 'user.reinstate',
  DISPUTE_RULE: 'dispute.rule',
  DISPUTE_DISMISS: 'dispute.dismiss',
  SETTINGS_UPDATE: 'settings.update',
  SETTINGS_RESET: 'settings.reset',
  VENUE_APPROVE: 'venue.approve',
  VENUE_REJECT: 'venue.reject',
  REVIEW_MODERATE: 'review.moderate',
  REGISTRATION_APPROVE: 'registration.approve',
  REGISTRATION_REJECT: 'registration.reject',
});

/** jsonb columns take an object or nothing; `undefined` must not become `"null"`. */
function asJson(v) {
  if (v === undefined || v === null) return null;
  try {
    return JSON.stringify(v);
  } catch {
    return null; // a circular object is not worth failing an audit over
  }
}

/**
 * Record one admin action. MUST be called with the same `client` as the
 * operation it describes, so the row is atomic with it.
 *
 * @param client     the pg client inside the operation's transaction
 * @param adminId    `req.user.id`
 * @param action     one of ACTIONS, or a `noun.verb` string
 * @param entityType 'user' | 'dispute' | 'match' | 'settings' | 'venue' | 'review'
 * @param entityId   uuid of the thing acted on, or null for a global change
 * @param before     state before, as a plain object
 * @param after      state after
 * @param note       the admin's own words, when the UI collected any
 * @returns `{ ok: true, id }` or `{ ok: false, error }` — never throws
 */
async function audit(client, { adminId, action, entityType, entityId, before, after, note }) {
  if (!client || !action) return { ok: false, error: 'audit requires a client and an action' };

  await client.query('SAVEPOINT sl_audit');
  try {
    const { rows } = await client.query(
      `INSERT INTO admin_audit
         (admin_id, action, entity_type, entity_id, before, after, note)
       VALUES ($1, $2, $3, $4, $5::jsonb, $6::jsonb, $7)
       RETURNING id`,
      [
        adminId || null,
        String(action),
        entityType || null,
        entityId || null,
        asJson(before),
        asJson(after),
        note ? String(note).slice(0, 2000) : null,
      ]
    );
    await client.query('RELEASE SAVEPOINT sl_audit');
    return { ok: true, id: rows[0].id };
  } catch (e) {
    await client.query('ROLLBACK TO SAVEPOINT sl_audit');
    // Loud in the log, invisible to the caller. See the header: a gap in the
    // trail is recoverable, a rolled-back ruling is not.
    console.warn(`[audit] ${action} not recorded: ${e.message}`);
    return { ok: false, error: e.message };
  }
}

module.exports = { audit, ACTIONS };
