/**
 * assistantReply.js — the one definition of what Scout sends back.
 *
 * Every reply is `{ text, chips, cards, source, ... }` and Flutter renders by
 * `card.type`. That makes this file a wire contract shared by three producers
 * (assistantActions, assistantKb, dialogManager) and one consumer (the chat
 * screen), so it is built here and nowhere else — a card assembled inline in a
 * service is a card the Flutter switch has never heard of.
 *
 * Two rules that are enforced, not advised
 * 1. No free-text-only dead ends. Every reply that ends a turn without an obvious
 *    next step carries chips. `reply()` therefore takes chips as a first-class
 *    argument and `menu()` exists so "I did not understand" always arrives with
 *    the list of things Scout can do (ER2.6).
 * 2. Every chip carries an explicit `action`. A chip press posts the action, not
 *    its label, so a button never goes through the classifier. That is what makes
 *    capabilities the trained label set does not cover — navigate, find_players,
 *    picking slot #2 — fully operational, and it is why a chip is not just a
 *    suggested phrase to type.
 *
 * `source` is part of the contract
 * Six values, one per reply, mirrored into assistant_turns.answer_source and
 * checked there by chk_assistant_turns_src. It answers the committee's first
 * question about any AI feature — "did the model do this, or did you hard-code
 * it?" — per message rather than per feature.
 */

/** The six honest provenances of a Scout answer. */
const SOURCES = Object.freeze({
  LIVE: 'live',            // computed from the database, now
  POLICY: 'policy',        // rules text, rendered from escrow.js POLICY
  MODEL: 'model',          // a trained ranker or recommender produced it
  KB: 'kb',                // an owner already answered this; reused
  MENU: 'menu',            // capability list / did-you-mean
  ESCALATED: 'escalated',  // forwarded to the venue owner
});
const SOURCE_VALUES = Object.freeze(Object.values(SOURCES));

/**
 * Card types. The first four are the original set; the rest are the same idea extended
 * to the entities Scout was asked to help discover — players, teams, tournaments
 * and a route on a map. Flutter needs a widget per value, so adding one here is a
 * change to two files, deliberately.
 */
const CARDS = Object.freeze({
  VENUE: 'venue',
  BOOKING: 'booking',
  SLOT_PICKER: 'slot_picker',
  CONFIRM: 'confirm',
  PLAYER: 'player',
  TEAM: 'team',
  TOURNAMENT: 'tournament',
  MAP: 'map',
  WALLET: 'wallet',
  STATS: 'stats',
  POLICY: 'policy',
  CAPABILITIES: 'capabilities',
});
const CARD_VALUES = Object.freeze(Object.values(CARDS));

/**
 * One chip. `action` is what the client posts back; `label` is only what a human
 * reads, so changing the wording can never change the behaviour.
 *
 * @param {string} label human text, kept short enough for a phone
 * @param {string} action the action key routes/assistant.js will execute
 * @param {object} [args] structured arguments — ids, dates, a slot number
 */
function chip(label, action, args = null) {
  const out = { label: String(label).slice(0, 40), action: String(action) };
  if (args && Object.keys(args).length) out.args = args;
  return out;
}

/** One card. `data` is whatever that type's Flutter widget reads. */
function card(type, data) {
  return { type: String(type), data: data ?? {} };
}

/**
 * Build a reply.
 *
 * `source` is required and validated: a typo'd source would sail through to the
 * database and be rejected by chk_assistant_turns_src at the very end of the turn,
 * after the money had already moved. Failing here instead is the difference
 * between a bug and a lost booking.
 */
function reply(text, {
  source,
  chips = [],
  cards = [],
  action = null,
  actionOk = null,
  meta = null,
} = {}) {
  if (!SOURCE_VALUES.includes(source)) {
    throw new Error(
      `assistantReply: source must be one of ${SOURCE_VALUES.join('|')}, got ${JSON.stringify(source)}`,
    );
  }
  const bad = cards.filter((c) => !c || !CARD_VALUES.includes(c.type));
  if (bad.length) {
    throw new Error(
      `assistantReply: unknown card type(s) ${JSON.stringify(bad.map((c) => c && c.type))}; `
      + `Flutter renders by type and has no widget for those. Known: ${CARD_VALUES.join('|')}`,
    );
  }
  const out = {
    text: String(text ?? '').trim(),
    chips: chips.filter(Boolean),
    cards: cards.filter(Boolean),
    source,
  };
  if (action) out.action = action;
  if (actionOk !== null) out.actionOk = actionOk;
  if (meta) out.meta = meta;
  return out;
}

/**
 * What Scout can do — the single source for the help menu, the chips on it and
 * `GET /api/assistant/capabilities`.
 *
 * `action` is the executable key, so this table is also the answer to "can a user
 * reach this without the classifier?". Everything here is reachable by button,
 * including the two capabilities the released v1 artifact has no label for
 * (find_players, navigate) — which is precisely why chips carry actions.
 */
const CAPABILITIES = Object.freeze([
  { action: 'find_venue', label: 'Find a ground', group: 'Discover',
    gloss: 'Grounds by sport, area, budget or date — ranked for you.' },
  { action: 'check_availability', label: 'Check a time', group: 'Discover',
    gloss: 'Is a slot free at a ground on a given day.' },
  { action: 'book_venue', label: 'Book a ground', group: 'Booking',
    gloss: 'Pick a slot and pay from your wallet, deposit held in escrow.' },
  { action: 'my_bookings', label: 'My bookings', group: 'Booking',
    gloss: 'Your upcoming and past bookings.' },
  { action: 'cancel_booking', label: 'Cancel a booking', group: 'Booking',
    gloss: 'With the refund shown before you confirm.' },
  { action: 'navigate', label: 'Directions', group: 'Discover',
    gloss: 'Open a route to a ground in Maps.' },
  { action: 'find_players', label: 'Find players', group: 'Team',
    gloss: 'Players to fill your side, ranked by fit.' },
  { action: 'find_opponents', label: 'Find opponents', group: 'Team',
    gloss: 'Teams near your rating looking for a match.' },
  { action: 'find_teams', label: 'Join a team', group: 'Team',
    gloss: 'Teams that are recruiting.' },
  { action: 'team_stats', label: 'My rating', group: 'Team',
    gloss: 'Your ELO, rank and recent record.' },
  { action: 'create_team_help', label: 'Create a team', group: 'Team',
    gloss: 'How to start a squad and invite players.' },
  { action: 'tournament_list', label: 'Tournaments', group: 'Discover',
    gloss: 'What is running on SportLynk and how to enter.' },
  { action: 'my_tournaments', label: 'My tournaments', group: 'Team',
    gloss: 'Cups you are in or running, and where your squad stands.' },
  { action: 'wallet_balance', label: 'Wallet balance', group: 'Money',
    gloss: 'Available and escrowed amounts.' },
  { action: 'topup_help', label: 'Add money', group: 'Money',
    gloss: 'How top-ups and withdrawals work.' },
  { action: 'refund_policy', label: 'Refund policy', group: 'Money',
    gloss: 'Cancellation window, deposit and refund share.' },
  { action: 'venue_info', label: 'About a ground', group: 'Discover',
    gloss: 'Facilities, price, timings, rating — or ask the owner.' },
]);

/** The six chips the help menu leads with. Fewer than sixteen fits a phone. */
const MENU_CHIP_ACTIONS = Object.freeze([
  'find_venue', 'book_venue', 'my_bookings', 'find_players', 'wallet_balance', 'refund_policy',
]);

/**
 * The capability menu — Scout's answer to "I did not understand that".
 *
 * ER2.6 asks for a friendly help menu on low confidence, and this is it. It is
 * never text alone: the chips are the recovery path, so a user whose sentence the
 * model could not place is one tap from the thing they wanted.
 */
function menu(text, { name = 'Scout', groups = true } = {}) {
  const chips = MENU_CHIP_ACTIONS
    .map((a) => CAPABILITIES.find((c) => c.action === a))
    .filter(Boolean)
    .map((c) => chip(c.label, c.action));

  const body = text || `I'm ${name} — I help with grounds, bookings, teams and your wallet. `
    + 'Here is what I can do:';

  const data = { name, items: CAPABILITIES.map((c) => ({ ...c })) };
  if (groups) {
    data.groups = [...new Set(CAPABILITIES.map((c) => c.group))].map((g) => ({
      group: g,
      items: CAPABILITIES.filter((c) => c.group === g).map((c) => c.action),
    }));
  }

  return reply(body, {
    source: SOURCES.MENU,
    chips,
    cards: [card(CARDS.CAPABILITIES, data)],
  });
}

/** Actions the capability table can execute — used by the boot-time label check. */
function capabilityActions() {
  return CAPABILITIES.map((c) => c.action);
}

module.exports = {
  SOURCES,
  SOURCE_VALUES,
  CARDS,
  CARD_VALUES,
  CAPABILITIES,
  MENU_CHIP_ACTIONS,
  chip,
  card,
  reply,
  menu,
  capabilityActions,
};
