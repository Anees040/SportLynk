/**
 * suspensionService.js — S.7 Wave D · FR10.8. Suspending an account, and putting
 * it back.
 *
 * Why a service and not twenty lines in the route
 * Suspension is not one UPDATE. A banned player is a player who is holding slots
 * other people want to book, sitting in tournament brackets that are about to be
 * drawn, and carrying open challenges other captains are waiting on. A banned
 * owner is worse: their venues stay listed and players keep paying money into
 * them. Flipping `is_active` alone produces an account that cannot log in while
 * still occupying everybody else's Saturday.
 *
 * So this file is the cascade, and every step of it delegates:
 *
 *   bookings      -> bookingService.cancelBooking   (the core, in this transaction)
 *   requests      -> bookingService.rejectBooking   (same, shared with owner.js)
 *   tournaments   -> tournamentService.withdraw     (refund + seed release)
 *   challenges    -> matchCore.fanOut               (pills + notifications)
 *
 * Nothing here re-implements a refund. That is the whole point of the file: it
 * decides what must be undone, and the modules that already own each piece of
 * money decide how.
 *
 * What it deliberately will not touch
 * A booking that a LIVE MATCH is played on. Once a challenge is accepted, the
 * fixture involves a second team who did nothing wrong, whose own escrow is on
 * the line, and possibly a tournament bracket. Force-cancelling that from a ban
 * would take money and a fixture away from an innocent third party, so those
 * bookings are reported back to the admin as needing a decision rather than
 * silently destroyed. An honest count in the response beats a hidden cascade.
 *
 * The late-cancellation penalty is not WAIVED
 * `cancelBooking` applies the ordinary 24-hour rule, so a suspended player whose
 * slot is tomorrow forfeits the 20% deposit to the venue owner exactly as if they
 * had cancelled it themselves. That is deliberate: the owner is inside their
 * no-refund window through no fault of their own, and the person who caused the
 * cancellation is the person being suspended. The split is recorded in the audit
 * row so the decision is visible rather than inferred.
 */
const mc = require('../utils/matchCore');
const bookingService = require('./bookingService');
const tournaments = require('./tournamentService');
const { notify } = require('../utils/notify');
const { audit, ACTIONS } = require('../utils/adminAudit');
const { hoursUntilSlot, round2, asNum } = require('../utils/escrow');

/** Same envelope as bookingService, so a route can treat both alike. */
function fail(status, code, message) {
  return { ok: false, status, code, message, data: null };
}
function done(data, message = null) {
  return { ok: true, status: 200, code: 'ok', message, data };
}

/** Statuses in which a match is a real fixture rather than an open invitation. */
const COMMITTED = Object.freeze([
  mc.STATUS.ACCEPTED, mc.STATUS.AWAITING_RESULTS,
  mc.STATUS.AWAITING_OWNER, mc.STATUS.COMPLETED, mc.STATUS.DISPUTED,
]);

/**
 * Expire every open challenge either of the user's captained teams is in.
 *
 * `challenge_sent` is an invitation, not a commitment: no result exists, no Elo
 * is at stake, and the only thing it holds is the challenger's booking — which
 * the booking pass immediately after this one can then cancel, in that order and
 * for that reason.
 */
async function expireOpenChallenges(client, { userId, teamIds }) {
  if (!teamIds.length) return [];
  const { rows } = await client.query(
    `SELECT id FROM matches
      WHERE status = $2 AND (challenger_team = ANY($1::uuid[]) OR opponent_team = ANY($1::uuid[]))
      ORDER BY created_at`,
    [teamIds, mc.STATUS.CHALLENGE_SENT],
  );

  const out = [];
  for (const r of rows) {
    const m = await mc.lockMatch(client, r.id);
    if (!m || m.status !== mc.STATUS.CHALLENGE_SENT) continue; // swept under us

    await client.query(
      'UPDATE matches SET status = $2, updated_at = now() WHERE id = $1',
      [m.id, mc.STATUS.EXPIRED],
    );

    const features = await mc.teamFeatures(client, [m.challenger_team, m.opponent_team]);
    const nameOf = (id) => features.get(String(id))?.name || 'the other team';
    const mine = teamIds.map(String);
    // The other captain is the one who needs telling: they are waiting on a reply
    // that is never coming. The suspended user gets one `account_suspended`
    // notification for the whole cascade, not one per side-effect.
    const sides = [m.challenger_team, m.opponent_team].map((teamId) => {
      const isTheirs = mine.includes(String(teamId));
      const other = String(teamId) === String(m.challenger_team) ? m.opponent_team : m.challenger_team;
      return {
        teamId,
        event: 'match_cancelled_admin',
        otherTeamName: nameOf(other),
        notify: isTheirs ? undefined : {
          type: 'match_expired',
          title: 'Challenge cancelled',
          body: `The challenge with ${nameOf(other)} was cancelled by SportLynk. The slot is free again.`,
          extra: { opponentTeam: other },
        },
      };
    });

    const fan = await mc.fanOut(client, { matchId: m.id, sides });
    out.push({ matchId: m.id, bookingId: m.booking_id, fan });
  }
  return out;
}

/**
 * Cancel the user's own upcoming bookings, refunding through the ordinary path.
 *
 * "Upcoming" is computed with `hoursUntilSlot`, not with SQL's `CURRENT_DATE`:
 * slot_date/start_time are PKT wall-clock values while the database session is
 * UTC, so a raw SQL comparison would treat the small hours of a Pakistani morning
 * as still in the future and try to cancel a slot that has already been played.
 */
async function cancelUpcomingBookings(client, { userId }) {
  const { rows } = await client.query(
    `SELECT b.id, b.slot_date, b.start_time, b.security_deposit, b.status,
            v.name AS venue_name,
            EXISTS (
              SELECT 1 FROM matches m
               WHERE m.booking_id = b.id AND m.status = ANY($2)
            ) AS committed
       FROM bookings b JOIN venues v ON v.id = b.venue_id
      WHERE b.player_id = $1 AND b.status IN ('pending', 'confirmed')
      ORDER BY b.slot_date, b.start_time`,
    [userId, COMMITTED],
  );

  const cancelled = [];
  const skipped = [];
  // `cancelBooking` returns its chat pill on the envelope rather than in `data`,
  // to be emitted after the caller commits. Collected here and handed back so the
  // route can flush them all in one pass once the transaction is durable.
  const pills = [];
  for (const b of rows) {
    if (hoursUntilSlot(b.slot_date, b.start_time) <= 0) continue; // already played
    if (b.committed) {
      skipped.push({
        bookingId: b.id, venueName: b.venue_name,
        slotDate: b.slot_date instanceof Date ? b.slot_date.toLocaleDateString('en-CA') : b.slot_date,
        reason: 'a match has already been accepted on this booking',
      });
      continue;
    }
    const out = await bookingService.cancelBooking(client, { userId, bookingId: b.id });
    if (out.ok) {
      cancelled.push({
        bookingId: b.id,
        venueName: b.venue_name,
        refunded: asNum(out.data && out.data.refund, 0),
        penalty: asNum(out.data && out.data.penalty, 0),
        late: !!(out.data && out.data.late),
      });
      if (out.chatPill) pills.push(out.chatPill);
    } else {
      skipped.push({ bookingId: b.id, venueName: b.venue_name, reason: out.message });
    }
  }
  return { cancelled, skipped, pills };
}

/**
 * Withdraw the teams the user captains from tournaments that have not been drawn.
 *
 * `tournamentService.withdraw` refuses once the bracket exists ("too_late") —
 * correctly, because at that point the entry fee has been paid out to the
 * organiser. A refusal is collected, not raised: the suspension must still go
 * through, and the admin is shown what could not be undone.
 */
async function withdrawFromTournaments(client, { userId, teamIds }) {
  if (!teamIds.length) return { withdrawn: [], skipped: [] };
  const { rows } = await client.query(
    `SELECT tt.tournament_id, tt.team_id, t.name AS tournament_name
       FROM tournament_teams tt
       JOIN teams tm ON tm.id = tt.team_id
       JOIN tournaments t ON t.id = tt.tournament_id
      WHERE tm.captain_id = $1 AND tt.status = ANY($2)`,
    [userId, tournaments.HOLDING],
  );

  const withdrawn = [];
  const skipped = [];
  for (const r of rows) {
    const out = await tournaments.withdraw(client, {
      userId, tournamentId: r.tournament_id, teamId: r.team_id,
    });
    if (out.ok) withdrawn.push({ tournamentId: r.tournament_id, name: r.tournament_name });
    else skipped.push({ tournamentId: r.tournament_id, name: r.tournament_name, reason: out.message });
  }
  return { withdrawn, skipped };
}

/**
 * Take a suspended owner's venues off the market and refund the requests nobody
 * is going to answer.
 *
 * The order matters: venues go inactive first so that no new request can be
 * created against them while the refunds are still being written, and only then
 * are the pending ones cleared. Doing it the other way round leaves a race in
 * which a player books the last free slot of a venue that is being closed.
 *
 * Confirmed bookings are counted but not cancelled. A confirmed booking is money
 * already in escrow against a slot the player still expects to play, and undoing
 * it is a refund decision with a counterparty (the owner, who may be reinstated
 * tomorrow). The count is returned so the admin can act on it deliberately.
 */
async function closeOwnerVenues(client, { userId }) {
  const venues = await client.query(
    `UPDATE venues SET is_active = false
      WHERE owner_id = $1 AND is_active = true
      RETURNING id, name`,
    [userId],
  );

  const pending = await client.query(
    `SELECT b.id FROM bookings b JOIN venues v ON v.id = b.venue_id
      WHERE v.owner_id = $1 AND b.status = 'pending'
      ORDER BY b.created_at`,
    [userId],
  );

  const rejected = [];
  const failed = [];
  for (const row of pending.rows) {
    const out = await bookingService.rejectBooking(client, {
      bookingId: row.id, ownerId: userId, reason: 'owner_suspended',
    });
    if (out.ok) rejected.push({ bookingId: row.id, refunded: asNum(out.data.refunded, 0) });
    else failed.push({ bookingId: row.id, reason: out.message });
  }

  const confirmed = await client.query(
    `SELECT count(*)::int AS n FROM bookings b JOIN venues v ON v.id = b.venue_id
      WHERE v.owner_id = $1 AND b.status = 'confirmed'`,
    [userId],
  );

  return {
    venues: venues.rows.map((v) => ({ id: v.id, name: v.name })),
    requestsRejected: rejected,
    requestsFailed: failed,
    confirmedBookingsLeftAlone: confirmed.rows[0].n,
  };
}

/**
 * Suspend an account and unwind everything it is holding. Caller owns the
 * transaction; nothing here BEGINs or COMMITs.
 *
 * Returns `{ ok, data }` where `data.cascade` is the full report — every booking
 * cancelled, every refund, every thing that could not be undone and why. The
 * route echoes it to the admin and the same object is stored as the audit row's
 * `after`, so a month later "what did this ban actually do?" is one SELECT.
 *
 * `authMiddleware.invalidate(userId)` is the caller's job, after COMMIT. Calling
 * it here would re-populate the cache from the still-uncommitted row and hand the
 * suspended user another 30 seconds of access.
 */
async function suspend(client, { adminId, userId, reason }) {
  const clean = String(reason || '').trim();
  if (!clean) return fail(400, 'reason_required', 'A reason is required to suspend an account');
  if (clean.length > 500) return fail(400, 'reason_too_long', 'Keep the reason under 500 characters');
  if (String(adminId) === String(userId)) {
    return fail(400, 'self_suspend', 'You cannot suspend your own account');
  }

  const u = await client.query(
    `SELECT id, name, email, role, is_active FROM users WHERE id = $1 FOR UPDATE`,
    [userId],
  );
  if (!u.rows.length) return fail(404, 'user_not_found', 'User not found');
  const user = u.rows[0];

  // An admin can be suspended only by editing the database directly, on purpose:
  // one compromised admin session should not be able to lock out the others.
  if (user.role === 'admin') {
    return fail(403, 'admin_protected', 'Admin accounts cannot be suspended from the app');
  }
  if (user.is_active === false) {
    return fail(409, 'already_suspended', 'That account is already suspended');
  }

  await client.query(
    `UPDATE users
        SET is_active = false, suspended_at = now(), suspended_reason = $2, suspended_by = $3
      WHERE id = $1`,
    [userId, clean, adminId],
  );

  const teams = await client.query('SELECT id FROM teams WHERE captain_id = $1', [userId]);
  const teamIds = teams.rows.map((t) => t.id);

  // Order is load-bearing: challenges first (they free their bookings), then the
  // bookings themselves, then tournaments, then — for an owner — the venues.
  const challenges = await expireOpenChallenges(client, { userId, teamIds });
  const bookings = await cancelUpcomingBookings(client, { userId });
  const tourneys = await withdrawFromTournaments(client, { userId, teamIds });
  const owner = user.role === 'owner' ? await closeOwnerVenues(client, { userId }) : null;

  const refundedTotal = round2(
    bookings.cancelled.reduce((s, b) => s + asNum(b.refunded, 0), 0)
    + (owner ? owner.requestsRejected.reduce((s, r) => s + asNum(r.refunded, 0), 0) : 0),
  );

  const cascade = {
    challengesExpired: challenges.map((c) => c.matchId),
    bookingsCancelled: bookings.cancelled,
    bookingsLeftAlone: bookings.skipped,
    tournamentsWithdrawn: tourneys.withdrawn,
    tournamentsLeftAlone: tourneys.skipped,
    venuesDeactivated: owner ? owner.venues : [],
    requestsRejected: owner ? owner.requestsRejected.length : 0,
    confirmedBookingsLeftAlone: owner ? owner.confirmedBookingsLeftAlone : 0,
    refundedTotal,
  };

  await notify(client, {
    userId,
    type: 'account_suspended',
    title: 'Your account has been suspended',
    body: refundedTotal > 0
      ? `${clean} Upcoming bookings were cancelled and PKR ${refundedTotal} returned to your wallet. Contact support if you think this is a mistake.`
      : `${clean} Contact support if you think this is a mistake.`,
  });

  await audit(client, {
    adminId,
    action: ACTIONS.USER_SUSPEND,
    entityType: 'user',
    entityId: userId,
    before: { isActive: true, role: user.role },
    after: { isActive: false, reason: clean, cascade },
    note: clean,
  });

  const result = done({
    userId,
    name: user.name,
    email: user.email,
    role: user.role,
    suspended: true,
    reason: clean,
    cascade,
  }, 'Account suspended');
  // Socket work rides on the envelope, never in `data`: both of these must be
  // flushed by the caller after COMMIT, because a live pill for a suspension that
  // then rolled back is a message about something that did not happen.
  result.pills = bookings.pills;
  result.fans = challenges.map((c) => ({ matchId: c.matchId, fan: c.fan }));
  return result;
}

/**
 * Lift a suspension.
 *
 * What comes back and what does not
 * The account does. The cascade does not: a refunded booking has been refunded,
 * a withdrawn tournament entry has released its seed and may have been filled by
 * somebody else, and an expired challenge belongs to a slot that is probably gone.
 * Re-creating any of that from a reinstatement would be inventing bookings.
 *
 * Venues are the one exception, and they are handled precisely rather than
 * broadly: the suspension's own audit row lists exactly which venues it
 * deactivated, so only those come back. A blanket `is_active = true` would also
 * revive a venue an admin had rejected for its own reasons, which is why the audit
 * trail is read here instead of guessed at.
 */
async function reinstate(client, { adminId, userId, note }) {
  const u = await client.query(
    `SELECT id, name, email, role, is_active, suspended_reason FROM users WHERE id = $1 FOR UPDATE`,
    [userId],
  );
  if (!u.rows.length) return fail(404, 'user_not_found', 'User not found');
  const user = u.rows[0];
  if (user.is_active !== false) {
    return fail(409, 'not_suspended', 'That account is not suspended');
  }

  await client.query(
    `UPDATE users
        SET is_active = true, suspended_at = NULL, suspended_reason = NULL, suspended_by = NULL
      WHERE id = $1`,
    [userId],
  );

  // The most recent suspension of this user, whoever performed it. `after` holds
  // the cascade object written above.
  const last = await client.query(
    `SELECT after FROM admin_audit
      WHERE action = $2 AND entity_type = 'user' AND entity_id = $1
      ORDER BY created_at DESC LIMIT 1`,
    [userId, ACTIONS.USER_SUSPEND],
  );
  const venueIds = (((last.rows[0] || {}).after || {}).cascade || {}).venuesDeactivated || [];
  const ids = venueIds.map((v) => (v && v.id) || v).filter(Boolean);

  let restored = [];
  if (ids.length) {
    const r = await client.query(
      `UPDATE venues SET is_active = true
        WHERE id = ANY($1::uuid[]) AND owner_id = $2 AND is_active = false
        RETURNING id, name`,
      [ids, userId],
    );
    restored = r.rows.map((v) => ({ id: v.id, name: v.name }));
  }

  await notify(client, {
    userId,
    type: 'account_reinstated',
    title: 'Your account is active again',
    body: restored.length
      ? `Welcome back. ${restored.length} venue${restored.length > 1 ? 's are' : ' is'} listed again.`
      : 'Welcome back — you can book and play again.',
  });

  await audit(client, {
    adminId,
    action: ACTIONS.USER_REINSTATE,
    entityType: 'user',
    entityId: userId,
    before: { isActive: false, reason: user.suspended_reason },
    after: { isActive: true, venuesRestored: restored },
    note: note ? String(note).slice(0, 500) : null,
  });

  return done({
    userId, name: user.name, email: user.email, role: user.role,
    suspended: false, venuesRestored: restored,
  }, 'Account reinstated');
}

module.exports = { suspend, reinstate };
