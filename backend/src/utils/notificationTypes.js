/**
 * The notification registry — one server-owned table of every alert this app can
 * send, and everything the client would otherwise have to guess about it.
 *
 * Why a registry, and why on the server
 * Before this file, `notify()` wrote a type string, a title and a body. Everything
 * else a feed needs — which category the row belongs to (so it can be filtered and
 * opted out of), whether it is worth waking a phone for, which icon it draws, and
 * above all WHERE tapping it goes — was nowhere. The client would have had to
 * switch on the type string and rebuild the route itself, which means:
 *
 *   • two implementations of the same mapping, one in Dart and one in nobody's
 *     head, drifting the first time a type is renamed;
 *   • a type the client has never heard of rendering as a blank icon and a dead
 *     tap — silently, on a real user's phone, with no error anywhere;
 *   • the push payload and the in-app row disagreeing about where the same
 *     notification leads.
 *
 * So the mapping lives here, once. `notify()` stamps `category`, `priority`,
 * `deep_link`, `entity_type/entity_id` and `group_key` onto the row at write time,
 * and the client does exactly what the row tells it. Adding a notification type is
 * one entry in this table.
 *
 * The boot assertion
 * `assertNotificationTypes()` runs at server start (server.js) and fails the boot
 * if any type emitted in the codebase is missing here — the same discipline as
 * `mlClient.assertNluLabels()` and `assistantActions.assertRoutable()`. A missing
 * entry is not a small defect: the row lands with category 'system', no priority
 * to push on and a null deep link, which is precisely the "the notification came
 * but tapping it does nothing" failure this module exists to make impossible.
 *
 * Deep links are route names that must exist in lib/routes/app_routes.dart
 * `deepLink()` returns `{ route, args }` where `route` is a named Flutter route.
 * `check_notifications.js` asserts every route this file can emit is present in
 * the client's `routes:` map — lib/routes/app_routes.dart, where the table lives,
 * unioned with lib/main.dart, where it used to — by string match. That check is
 * the whole reason
 * the mapping is worth centralising: it turns "the tap does nothing" from a bug a
 * user finds into a script failure.
 *
 * A deep link is NULL when the destination genuinely does not exist yet (see
 * assistant_question). Null is honest — the client renders the row as
 * non-tappable — and it is not the same thing as a route that 404s.
 *
 * Priority is a push decision, not a feeling
 *   high    — wake the phone. Money moved, a slot is confirmed or lost, someone
 *             is waiting on a reply with a deadline.
 *   normal  — deliver, but it can wait for the next unlock.
 *   low     — in-app only in practice; the drain still records it.
 *
 * `pushJob` reads this to set android.priority, and `notification_prefs` lets a
 * user mute a whole CATEGORY — never an individual type, which nobody can reason
 * about.
 */

// The nine feed categories, matching chk_notifications_category in migration 020
// (which also allows 'assistant' — see the categories note below).
const CATEGORY = {
  BOOKING: 'booking',
  MATCH: 'match',
  TOURNAMENT: 'tournament',
  WALLET: 'wallet',
  TEAM: 'team',
  CHAT: 'chat',
  VENUE: 'venue',
  REVIEW: 'review',
  ASSISTANT: 'assistant',
  SYSTEM: 'system',
};

const PRIORITY = { HIGH: 'high', NORMAL: 'normal', LOW: 'low' };

/**
 * Every category a user may switch off, in the order the prefs screen shows them.
 * 'system' is deliberately absent: an account suspension is not something a user
 * gets to mute.
 */
const MUTABLE_CATEGORIES = [
  CATEGORY.BOOKING, CATEGORY.MATCH, CATEGORY.TOURNAMENT, CATEGORY.CHAT,
  CATEGORY.TEAM, CATEGORY.WALLET, CATEGORY.ASSISTANT, CATEGORY.VENUE,
  CATEGORY.REVIEW,
];

// Deep-link helpers
//
// Each takes the notify() context — `{ bookingId, payload }` — and returns a
// route + args, or null when the id it needs is not there. Returning null rather
// than a route with an undefined argument is the point: a route pushed with a
// missing id crashes the screen it opens, and a crash on tapping a notification
// is worse than a row that does not respond.

const bookingLink = ({ bookingId, payload }) => {
  const id = bookingId || payload?.bookingId;
  return id ? { route: '/booking-detail', args: { bookingId: id } } : null;
};

// The owner's side of a booking is the requests screen, not /booking-detail:
// that route is player-guarded (AuthGuard requiredRole: 'player'), so sending an
// owner there would bounce them straight back out through the app's own guard.
const ownerBookingLink = ({ payload }) => ({
  route: '/owner-bookings',
  args: payload?.bookingId ? { bookingId: payload.bookingId } : {},
});

// Match notifications open the match centre for the recipient's own team — the
// screen that lists their challenges, results awaiting submission and history.
// teamId is on every payload mc.fanOut writes.
const matchLink = ({ payload }) => (payload?.teamId
  ? { route: '/match-center', args: { teamId: payload.teamId, matchId: payload.matchId || null } }
  : null);

const tournamentLink = ({ payload }) => (payload?.tournamentId
  ? { route: '/tournament-detail', args: { tournamentId: payload.tournamentId } }
  : null);

const teamLink = ({ payload }) => (payload?.teamId
  ? { route: '/team-roster', args: { teamId: payload.teamId, teamName: payload.teamName || null } }
  : null);

const walletLink = () => ({ route: '/wallet', args: {} });

const chatLink = ({ payload }) => (payload?.channelId
  ? {
    route: '/chat-thread',
    args: {
      channelId: payload.channelId,
      type: payload.channelType || 'team',
      title: payload.channelTitle || 'Chat',
    },
  }
  : { route: '/chats', args: {} });

// Collapse groups
//
// A group_key makes the database collapse repeats into one row (see
// ux_notifications_group in migration 020): the second message from the same
// person bumps group_count instead of adding a row. Only types that genuinely
// repeat from the same source get one — three messages in a thread are one
// conversation, whereas three different bookings are three different facts and
// must never be merged.
//
// `title`/`body` rewrite the collapsed row once count > 1, because "Ali: see you
// at 6" is the wrong sentence for the third message.

const chatGroup = {
  key: ({ payload }) => (payload?.channelId ? `chat:${payload.channelId}` : null),
  title: (count, base) => base,
  body: (count, base) => (count > 1 ? `${count} new messages` : base),
};

const teamRequestGroup = {
  key: ({ payload }) => (payload?.teamId ? `teamreq:${payload.teamId}` : null),
  title: (count, base) => (count > 1 ? `${count} players want to join` : base),
  body: (count, base) => base,
};

/**
 * The table.
 *
 * Every key is a `type` value written by a live notify() call site, plus the four
 * chat and moderation additions. `entity` is the polymorphic tap target on the row
 * (chk_notifications_entity in 020 constrains the vocabulary); `icon` is a
 * Material icon name the Flutter feed maps to an IconData.
 */
const TYPES = {
  // Bookings
  // High almost throughout: a booking is the thing the player paid for, and
  // "confirmed" / "rejected" / "you were marked a no-show" all change what they
  // are doing in the next few hours. The _owner mirrors are normal — the owner
  // is being kept informed of their own venue's automation, not asked to act.
  booking_confirmed: {
    category: CATEGORY.BOOKING, priority: PRIORITY.HIGH,
    icon: 'event_available', entity: 'booking', deepLink: bookingLink,
  },
  booking_rejected: {
    category: CATEGORY.BOOKING, priority: PRIORITY.HIGH,
    icon: 'event_busy', entity: 'booking', deepLink: bookingLink,
  },
  booking_auto_confirmed: {
    category: CATEGORY.BOOKING, priority: PRIORITY.HIGH,
    icon: 'event_available', entity: 'booking', deepLink: bookingLink,
  },
  booking_auto_confirmed_owner: {
    category: CATEGORY.BOOKING, priority: PRIORITY.NORMAL,
    icon: 'schedule', entity: 'booking', deepLink: ownerBookingLink,
  },
  booking_auto_rejected: {
    category: CATEGORY.BOOKING, priority: PRIORITY.HIGH,
    icon: 'event_busy', entity: 'booking', deepLink: bookingLink,
  },
  booking_auto_rejected_owner: {
    category: CATEGORY.BOOKING, priority: PRIORITY.NORMAL,
    icon: 'schedule', entity: 'booking', deepLink: ownerBookingLink,
  },
  booking_no_show: {
    category: CATEGORY.BOOKING, priority: PRIORITY.HIGH,
    icon: 'person_off', entity: 'booking', deepLink: bookingLink,
  },
  booking_no_show_owner: {
    category: CATEGORY.BOOKING, priority: PRIORITY.NORMAL,
    icon: 'person_off', entity: 'booking', deepLink: ownerBookingLink,
  },
  // Goes to the owner (bookingService credits them the penalty), so it links to
  // the owner's requests screen rather than the player's booking detail.
  booking_cancelled_late: {
    category: CATEGORY.BOOKING, priority: PRIORITY.NORMAL,
    icon: 'money_off', entity: 'booking', deepLink: ownerBookingLink,
  },

  // Matches
  // A challenge has a 48h deadline and a slot behind it; the whole point of
  // pushing it is that the other captain does not open the app on their own.
  match_challenge: {
    category: CATEGORY.MATCH, priority: PRIORITY.HIGH,
    icon: 'sports_soccer', entity: 'match', deepLink: matchLink,
  },
  match_accepted: {
    category: CATEGORY.MATCH, priority: PRIORITY.HIGH,
    icon: 'handshake', entity: 'match', deepLink: matchLink,
  },
  match_rejected: {
    category: CATEGORY.MATCH, priority: PRIORITY.NORMAL,
    icon: 'cancel', entity: 'match', deepLink: matchLink,
  },
  match_expired: {
    category: CATEGORY.MATCH, priority: PRIORITY.NORMAL,
    icon: 'timer_off', entity: 'match', deepLink: matchLink,
  },
  match_result_pending: {
    category: CATEGORY.MATCH, priority: PRIORITY.HIGH,
    icon: 'edit_note', entity: 'match', deepLink: matchLink,
  },
  // The one match type addressed to an owner: two teams submitted the same score
  // and the venue has to confirm it. Its home is the owner's verify screen.
  match_verify_pending: {
    category: CATEGORY.MATCH, priority: PRIORITY.NORMAL,
    icon: 'fact_check', entity: 'match',
    deepLink: () => ({ route: '/owner-verify-matches', args: {} }),
  },
  match_verified: {
    category: CATEGORY.MATCH, priority: PRIORITY.HIGH,
    icon: 'verified', entity: 'match', deepLink: matchLink,
  },
  match_disputed: {
    category: CATEGORY.MATCH, priority: PRIORITY.HIGH,
    icon: 'gavel', entity: 'match', deepLink: matchLink,
  },
  // Not a match event as such — the team's rating stopped moving because the
  // roster changed too much. Normal: it is information, not an interruption.
  elo_frozen: {
    category: CATEGORY.MATCH, priority: PRIORITY.NORMAL,
    icon: 'ac_unit', entity: 'team',
    deepLink: ({ payload }) => (payload?.teamId
      ? { route: '/match-center', args: { teamId: payload.teamId } }
      : null),
  },

  // Tournaments
  // Anything that moves money or a bracket is high. Registration receipts and
  // the organiser's own bookkeeping are normal.
  tournament_registered: {
    category: CATEGORY.TOURNAMENT, priority: PRIORITY.NORMAL,
    icon: 'app_registration', entity: 'tournament', deepLink: tournamentLink,
  },
  tournament_entry_received: {
    category: CATEGORY.TOURNAMENT, priority: PRIORITY.NORMAL,
    icon: 'payments', entity: 'tournament', deepLink: tournamentLink,
  },
  tournament_accepted: {
    category: CATEGORY.TOURNAMENT, priority: PRIORITY.HIGH,
    icon: 'how_to_reg', entity: 'tournament', deepLink: tournamentLink,
  },
  tournament_rejected: {
    category: CATEGORY.TOURNAMENT, priority: PRIORITY.HIGH,
    icon: 'person_remove', entity: 'tournament', deepLink: tournamentLink,
  },
  tournament_removed: {
    category: CATEGORY.TOURNAMENT, priority: PRIORITY.HIGH,
    icon: 'person_remove', entity: 'tournament', deepLink: tournamentLink,
  },
  tournament_withdrawn: {
    category: CATEGORY.TOURNAMENT, priority: PRIORITY.NORMAL,
    icon: 'logout', entity: 'tournament', deepLink: tournamentLink,
  },
  tournament_team_withdrew: {
    category: CATEGORY.TOURNAMENT, priority: PRIORITY.NORMAL,
    icon: 'group_off', entity: 'tournament', deepLink: tournamentLink,
  },
  tournament_cancelled: {
    category: CATEGORY.TOURNAMENT, priority: PRIORITY.HIGH,
    icon: 'event_busy', entity: 'tournament', deepLink: tournamentLink,
  },
  tournament_fixtures_ready: {
    category: CATEGORY.TOURNAMENT, priority: PRIORITY.HIGH,
    icon: 'account_tree', entity: 'tournament', deepLink: tournamentLink,
  },
  tournament_generated: {
    category: CATEGORY.TOURNAMENT, priority: PRIORITY.NORMAL,
    icon: 'account_tree', entity: 'tournament', deepLink: tournamentLink,
  },
  tournament_result: {
    category: CATEGORY.TOURNAMENT, priority: PRIORITY.HIGH,
    icon: 'scoreboard', entity: 'tournament', deepLink: tournamentLink,
  },
  tournament_walkover: {
    category: CATEGORY.TOURNAMENT, priority: PRIORITY.HIGH,
    icon: 'directions_run', entity: 'tournament', deepLink: tournamentLink,
  },
  tournament_completed: {
    category: CATEGORY.TOURNAMENT, priority: PRIORITY.HIGH,
    icon: 'emoji_events', entity: 'tournament', deepLink: tournamentLink,
  },
  // The champion's own copy of tournament_completed — a separate type because the
  // sentence and the icon are different ("you won" vs "it is over"), and because a
  // user who has muted tournaments should still not be the last to know.
  tournament_won: {
    category: CATEGORY.TOURNAMENT, priority: PRIORITY.HIGH,
    icon: 'workspace_premium', entity: 'tournament', deepLink: tournamentLink,
  },

  // Teams
  // team_request repeats from different people at the same team, so it collapses:
  // a captain with an open team should see "4 players want to join", not four
  // rows that push four times.
  team_join: {
    category: CATEGORY.TEAM, priority: PRIORITY.NORMAL,
    icon: 'group_add', entity: 'team', deepLink: teamLink,
  },
  team_request: {
    category: CATEGORY.TEAM, priority: PRIORITY.NORMAL,
    icon: 'person_add', entity: 'team', deepLink: teamLink,
    group: teamRequestGroup,
  },
  team_role: {
    category: CATEGORY.TEAM, priority: PRIORITY.NORMAL,
    icon: 'military_tech', entity: 'team', deepLink: teamLink,
  },

  // Wallet
  // "Requested" is low: the user just tapped the button, they know. "Paid out" is
  // high — money left the platform and reached their account, which is the one
  // wallet event worth a buzz.
  withdrawal_requested: {
    category: CATEGORY.WALLET, priority: PRIORITY.LOW,
    icon: 'schedule_send', entity: 'withdrawal', deepLink: walletLink,
  },
  withdrawal_completed: {
    category: CATEGORY.WALLET, priority: PRIORITY.HIGH,
    icon: 'account_balance', entity: 'withdrawal', deepLink: walletLink,
  },
  withdrawal_cancelled: {
    category: CATEGORY.WALLET, priority: PRIORITY.NORMAL,
    icon: 'undo', entity: 'withdrawal', deepLink: walletLink,
  },

  // Scout (the assistant)
  // assistant_question goes to a VENUE owner: a player asked something Scout
  // could not answer and it was escalated. There is no owner-side escalation
  // inbox in the Flutter app yet — the endpoints exist
  // (POST /api/assistant/escalations/:id/answer) and the screen does not — so the
  // deep link is honestly NULL rather than a route that lands nowhere useful.
  // When that screen is built, this becomes a one-line change here and the row
  // starts responding to taps with no client release.
  assistant_question: {
    category: CATEGORY.ASSISTANT, priority: PRIORITY.NORMAL,
    icon: 'help_outline', entity: 'venue', deepLink: () => null,
  },
  // The player's side: the owner answered, and the answer was posted into their
  // own Scout thread — which is a screen that exists.
  assistant_answer: {
    category: CATEGORY.ASSISTANT, priority: PRIORITY.HIGH,
    icon: 'support_agent', entity: 'channel',
    deepLink: () => ({ route: '/assistant', args: {} }),
  },

  // Chat and moderation additions
  // A chat message notifies only when the recipient is offline or looking at a
  // different chat (routes/chat.js checks bus.isUserViewingChannel) — a phone
  // that is already showing the message must not also buzz about it.
  chat_message: {
    category: CATEGORY.CHAT, priority: PRIORITY.NORMAL,
    icon: 'chat_bubble', entity: 'channel', deepLink: chatLink,
    group: chatGroup,
  },
  // An admin ruled on a disputed result. High without question: it changes both
  // teams' ELO and closes an argument the captains have been having.
  dispute_resolved: {
    category: CATEGORY.MATCH, priority: PRIORITY.HIGH,
    icon: 'gavel', entity: 'match', deepLink: matchLink,
  },
  // System, and deliberately not mutable — see MUTABLE_CATEGORIES. A suspended
  // user must be told why, and cannot have opted out of being told.
  account_suspended: {
    category: CATEGORY.SYSTEM, priority: PRIORITY.HIGH,
    icon: 'block', entity: 'user', deepLink: () => null,
  },
  account_reinstated: {
    category: CATEGORY.SYSTEM, priority: PRIORITY.HIGH,
    icon: 'lock_open', entity: 'user', deepLink: () => null,
  },
  // POST /api/notifications/test writes this. Registered rather than left to the
  // unregistered-type fallback for one reason: the demo lever must exercise the same
  // path a real notification takes -- registry lookup, category, priority, outbox --
  // or a green test proves only that the fallback works.
  //
  // SYSTEM, so pushJob's suppressionReason() exempts it from muteAll, from the
  // per-category mutes and from quiet hours. That is what makes it a diagnostic: if
  // the test does not arrive, the answer is the pipe (no key, no device, dead token)
  // and never a preference, so it cannot send anyone looking in the wrong place.
  // NORMAL priority because it is not urgent -- a heads-up banner for a self-test
  // would misrepresent what the tray is for.
  system_test: {
    category: CATEGORY.SYSTEM, priority: PRIORITY.NORMAL,
    icon: 'bug_report', entity: null, deepLink: () => null,
  },
};

// Accessors

/**
 * The registry entry for a type, or a safe fallback for one that is not
 * registered.
 *
 * Never throws, and never returns undefined. `notify()` is called from inside
 * money transactions — a lookup miss must not be able to roll back a settled
 * booking over a missing icon. An unregistered type therefore lands as a plain
 * 'system' row with no deep link and no push priority, and the boot assertion
 * below is what stops that from reaching production in the first place.
 */
function describe(type) {
  const t = TYPES[type];
  if (t) return t;
  return {
    category: CATEGORY.SYSTEM,
    priority: PRIORITY.NORMAL,
    icon: 'notifications',
    entity: null,
    deepLink: () => null,
    unregistered: true,
  };
}

function isRegistered(type) {
  return Object.prototype.hasOwnProperty.call(TYPES, type);
}

/** Every registered type, for the check script and the boot banner. */
function allTypes() {
  return Object.keys(TYPES).sort();
}

/**
 * Every distinct route this registry can ever emit. `check_notifications.js`
 * asserts each one exists in the client's route table (lib/routes/app_routes.dart),
 * which is the guard against a
 * notification whose tap goes nowhere.
 *
 * Routes are collected by calling each deepLink with a fully-populated fake
 * context rather than by parsing the source, so a helper that quietly stops
 * returning a route shows up here as a missing entry.
 */
function allRoutes() {
  const ctx = {
    bookingId: '00000000-0000-0000-0000-000000000001',
    payload: {
      bookingId: '00000000-0000-0000-0000-000000000001',
      matchId: '00000000-0000-0000-0000-000000000002',
      teamId: '00000000-0000-0000-0000-000000000003',
      tournamentId: '00000000-0000-0000-0000-000000000004',
      channelId: '00000000-0000-0000-0000-000000000005',
      channelType: 'team',
      channelTitle: 'Titans',
      teamName: 'Titans',
    },
  };
  const out = new Set();
  for (const type of Object.keys(TYPES)) {
    const link = safeDeepLink(type, ctx);
    if (link && link.route) out.add(link.route);
  }
  return [...out].sort();
}

/**
 * Resolve a type's deep link, defensively.
 *
 * A helper that throws (a payload shape nobody anticipated) must degrade to "no
 * link on this row", never to a failed transaction. The row is still worth
 * having: it says what happened, and the feed can be opened by hand.
 */
function safeDeepLink(type, ctx) {
  const entry = describe(type);
  if (typeof entry.deepLink !== 'function') return null;
  try {
    const link = entry.deepLink(ctx || {});
    if (!link || typeof link.route !== 'string' || !link.route.startsWith('/')) return null;
    return { route: link.route, args: link.args || {} };
  } catch (e) {
    console.warn(`[notify] deepLink(${type}) failed:`, e.message);
    return null;
  }
}

/** The collapse key for a type, or null when this type never collapses. */
function groupKeyFor(type, ctx) {
  const entry = describe(type);
  if (!entry.group || typeof entry.group.key !== 'function') return null;
  try {
    const key = entry.group.key(ctx || {});
    return typeof key === 'string' && key ? key.slice(0, 200) : null;
  } catch (e) {
    console.warn(`[notify] groupKey(${type}) failed:`, e.message);
    return null;
  }
}

/**
 * The wording for a collapsed row at `count`. Returns the originals unchanged for
 * a type with no group or a count of 1, so the caller can apply it blindly.
 */
function collapsedText(type, count, { title, body }) {
  const entry = describe(type);
  if (!entry.group || !(count > 1)) return { title, body };
  const g = entry.group;
  try {
    return {
      title: typeof g.title === 'function' ? g.title(count, title) : title,
      body: typeof g.body === 'function' ? g.body(count, body) : body,
    };
  } catch (e) {
    console.warn(`[notify] collapsedText(${type}) failed:`, e.message);
    return { title, body };
  }
}

/**
 * The entity this notification points at, as `{ entityType, entityId }`.
 *
 * Read from the same context notify() already has. The vocabulary is fixed by
 * chk_notifications_entity (020), so an entity the CHECK does not allow is
 * dropped here rather than raising 23514 inside a money transaction — the row
 * matters more than its tap target.
 */
const ENTITY_IDS = {
  booking: (c) => c.bookingId || c.payload?.bookingId,
  match: (c) => c.payload?.matchId,
  tournament: (c) => c.payload?.tournamentId,
  team: (c) => c.payload?.teamId,
  venue: (c) => c.payload?.venueId,
  channel: (c) => c.payload?.channelId,
  withdrawal: (c) => c.payload?.withdrawalId,
  user: (c) => c.userId,
  dispute: (c) => c.payload?.disputeId,
};

function entityFor(type, ctx) {
  const entry = describe(type);
  const kind = entry.entity;
  if (!kind || !ENTITY_IDS[kind]) return { entityType: null, entityId: null };
  let id = null;
  try { id = ENTITY_IDS[kind](ctx || {}) || null; } catch { id = null; }
  return id ? { entityType: kind, entityId: id } : { entityType: null, entityId: null };
}

// The boot assertion

/**
 * Fail the boot if a type this codebase emits is not registered here.
 *
 * Shaped exactly like mlClient.assertNluLabels() and
 * assistantActions.assertRoutable(): the failure is loud, at start-up, on the
 * developer's machine — not silent, months later, on a user's phone.
 *
 * `emitted` is the list of type strings scraped from the notify() call sites by
 * scripts/check_notifications.js, which is the only thing that can see them all.
 * Called with no argument, this asserts the internal consistency of the table
 * itself (which is what server.js needs at boot: every entry has a category the
 * CHECK constraint allows, a priority, an icon and a callable deepLink).
 */
function assertNotificationTypes(emitted = null) {
  const problems = [];
  const CATS = new Set(Object.values(CATEGORY));
  const PRIOS = new Set(Object.values(PRIORITY));
  const ENTITIES = new Set(Object.keys(ENTITY_IDS));

  for (const [type, entry] of Object.entries(TYPES)) {
    if (!CATS.has(entry.category)) {
      problems.push(`${type}: category '${entry.category}' is not one chk_notifications_category allows`);
    }
    if (!PRIOS.has(entry.priority)) {
      problems.push(`${type}: priority '${entry.priority}' is not high|normal|low`);
    }
    if (!entry.icon) problems.push(`${type}: no icon — the feed row would draw blank`);
    if (typeof entry.deepLink !== 'function') {
      problems.push(`${type}: deepLink must be a function (return null when there is no destination)`);
    }
    if (entry.entity && !ENTITIES.has(entry.entity)) {
      problems.push(`${type}: entity '${entry.entity}' has no id resolver and is not in chk_notifications_entity`);
    }
    if (entry.group && typeof entry.group.key !== 'function') {
      problems.push(`${type}: group.key must be a function`);
    }
  }

  if (Array.isArray(emitted)) {
    for (const type of emitted) {
      if (!isRegistered(type)) {
        problems.push(`${type}: EMITTED by a notify() call site but not registered — `
          + 'it would land as category=system with a dead tap');
      }
    }
  }

  if (problems.length) {
    throw new Error(
      `notificationTypes registry is inconsistent (${problems.length}):\n  - `
      + problems.join('\n  - '),
    );
  }
  return { types: Object.keys(TYPES).length, routes: allRoutes().length };
}

module.exports = {
  CATEGORY, PRIORITY, MUTABLE_CATEGORIES, TYPES,
  describe, isRegistered, allTypes, allRoutes,
  safeDeepLink, groupKeyFor, collapsedText, entityFor,
  assertNotificationTypes,
};
