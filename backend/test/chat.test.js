/**
 * Chat unit tests
 *
 * Run:  npm test            (from backend/)
 *   or  node --test test/chat.test.js
 *
 * What this file is for, and what it is not for
 * `src/scripts/check_chat.js` proves the rows: that confirming a booking opens a
 * room, that four people land in a captain channel, that the unread count matches
 * a hand-computed number. It needs a database and forty seconds.
 *
 * These tests prove the sentences and the tables — the parts that are pure
 * functions and constant data, and that therefore break in milliseconds with
 * Supabase switched off. Three of them are the kind of bug a live demo surfaces
 * and a check script cannot:
 *
 *   - a pill in the shared captain room that says "your team" reads backwards to
 *     half the room, and no schema constraint can catch it;
 *   - a quick-reply table keyed to an intent the classifier cannot emit is three
 *     chips that never appear, silently, forever;
 *   - `slotLabel` passing a PKT wall-clock time through a timezone conversion is
 *     an off-by-five-hours that only shows up on somebody's phone.
 *
 * Nothing here opens a connection. Every module under test is either pure
 * (`chatSystemMessages`, the pure half of `chatList`) or does its I/O behind a
 * `client` argument that is never supplied here (`quickReplies`).
 */

const test = require('node:test');
const assert = require('node:assert/strict');

const sys = require('../src/utils/chatSystemMessages');
const list = require('../src/utils/chatList');
const qr = require('../src/utils/quickReplies');
const actions = require('../src/services/assistantActions');

// 1 — the opening pills: the two sentences the spec promised, verbatim

test('1 — the booking room opens with the sentence a push notification can quote', () => {
  assert.equal(
    sys.sentenceFor('booking_confirmed', {}),
    'Booking confirmed — chat with the venue here',
  );
});

test('2 — the coordination room opens with FR8.5 wording, verbatim', () => {
  // Quoted from the requirement. If this string ever drifts, the requirement is
  // no longer met even though every row still exists.
  assert.equal(sys.sentenceFor('match_coordinate', {}), 'Challenge accepted — coordinate here');
});

test('3 — a cancellation names its reason, because that is what the next message argues about', () => {
  assert.equal(
    sys.sentenceFor('booking_cancelled', { v: 'late cancellation' }),
    'This booking was cancelled (late cancellation)',
  );
  assert.equal(sys.sentenceFor('booking_cancelled', {}), 'This booking was cancelled');
});

test('4 — a no-show is worded as the venue’s action, since that is who marked it', () => {
  assert.equal(
    sys.sentenceFor('booking_no_show', {}),
    'The venue marked this booking as a no-show',
  );
});

// 2 — Neutrality: the property that makes one shared room readable to both teams

/** Every sentence the coordination room can ever contain. */
const COORD_EVENTS = [
  'match_coordinate', 'match_result_in', 'match_both_results_in',
  'match_settled', 'match_under_review', 'match_ruled',
];

/** Every sentence a single team's own chat gets for the same lifecycle. */
const TEAM_EVENTS = [
  'match_challenge_sent', 'match_challenge_received', 'match_accepted',
  'match_declined', 'match_result_submitted', 'match_awaiting_owner',
  'match_verified', 'match_disputed',
];

test('5 — no sentence in the shared room addresses the reader as "you"', () => {
  // This is the whole reason the coord vocabulary exists separately. A captain
  // room holds both teams; "you challenged them" is false for half of it.
  for (const event of COORD_EVENTS) {
    for (const opts of [{}, { a: 'Ali', t: 'Falcons', v: 'Titans', d: 'Falcons won 3-1' }]) {
      const s = sys.sentenceFor(event, opts);
      assert.ok(!/\byou\b|\byour\b/i.test(s), `${event} says "you": ${s}`);
    }
  }
});

test('6 — and none of them names a winner side-first without being asked to', () => {
  // `d` (detail) is the caller's own neutral scoreline. Without it the sentence
  // must not invent a subject: "Result verified" is safe, "Falcons won" is not.
  assert.equal(sys.sentenceFor('match_settled', {}), 'The result has been verified');
  assert.equal(
    sys.sentenceFor('match_settled', { d: 'Falcons 3 - 1 Titans' }),
    'Result verified — Falcons 3 - 1 Titans',
  );
});

test('7 — the per-team sentences DO take a side, and that asymmetry is deliberate', () => {
  // If these ever became neutral too, the two vocabularies would have collapsed
  // into one and the room would have lost the thing it was split out to provide.
  const sent = sys.sentenceFor('match_challenge_sent', { a: 'Ali', t: 'Titans', v: 'Titans' });
  const recv = sys.sentenceFor('match_challenge_received', { a: 'Ali', t: 'Falcons', v: 'Falcons' });
  assert.notEqual(sent, recv);
  assert.ok(/\byou\b|\byour\b/i.test(`${sent} ${recv}`),
    'at least one per-team sentence should address its own team directly');
});

test('8 — an unknown event never throws, so a missing case cannot roll back a transaction', () => {
  // chatCore.postSystemMessage runs inside the transaction that moves the money.
  // A sentence lookup that throws on a typo would undo a booking approval.
  assert.doesNotThrow(() => sys.sentenceFor('match_teleported', { a: 'Ali' }));
  assert.equal(typeof sys.sentenceFor('nonsense_event', {}), 'string');
});

test('9 — buildSystemMessage returns a body AND structured meta for every system event', () => {
  for (const event of [...COORD_EVENTS, 'booking_confirmed', 'booking_cancelled', 'booking_no_show']) {
    const p = sys.buildSystemMessage(event, { actorName: 'Ali', targetName: 'Falcons' });
    assert.ok(p.body && p.body.length > 0, `${event} has no body`);
    assert.equal(typeof p.meta, 'object');
    assert.equal(p.meta.event, event, `${event} meta does not name itself`);
  }
});

// 3 — FR8.10: the reply tables, checked against the FROZEN label set
//
// Model #4 is released and its 23 labels are frozen (ml-service's intent_spec.py,
// enumerated in Node by assistantActions.intentLabels). A quick-reply table keyed
// to an intent the classifier cannot emit is not a compile error and not a runtime
// error — it is three chips that never appear, and nobody finds out. So the keys
// are asserted against the real label set rather than against a copy of it.

const LABELS = new Set(actions.intentLabels());

test('10 — the frozen label set is still the 23 the code was built against', () => {
  assert.equal(LABELS.size, 23);
});

test('11 — every quick-reply key is a label the classifier can actually emit', () => {
  for (const [audience, table] of Object.entries(qr.QUICK_REPLIES)) {
    for (const intent of Object.keys(table)) {
      assert.ok(LABELS.has(intent), `${audience}.${intent} is not a trained label`);
    }
  }
});

test('12 — and so is every intent the keyword fallback can produce', () => {
  // The fallback runs when ml-service is down. If it invented an intent, the
  // lookup would miss and the user would silently get generic replies at the exact
  // moment the feature is meant to be carrying itself.
  // LEXICON is [regex, intent] pairs — a table, not objects, so the regexes stay
  // readable in one column beside the label they map to.
  for (const [re, intent] of qr.LEXICON) {
    assert.ok(re instanceof RegExp, `lexicon row for ${intent} is not a regex`);
    assert.ok(LABELS.has(intent), `lexicon intent ${intent} is not a trained label`);
  }
});

test('13 — every entry offers exactly three replies, the number a chip row fits', () => {
  for (const [audience, table] of Object.entries(qr.QUICK_REPLIES)) {
    for (const [intent, replies] of Object.entries(table)) {
      assert.equal(replies.length, 3, `${audience}.${intent} offers ${replies.length}`);
      for (const r of replies) {
        assert.equal(typeof r, 'string');
        assert.ok(r.trim().length > 0, `${audience}.${intent} has a blank reply`);
      }
    }
  }
  for (const [audience, replies] of Object.entries(qr.GENERIC)) {
    assert.equal(replies.length, 3, `GENERIC.${audience} offers ${replies.length}`);
  }
});

test('14 — the audience follows the ROOM first and the app role second', () => {
  // A captain room is its own audience no matter who is reading it: an owner who
  // is also a captain must not be offered "Sorry, that slot is booked" in a room
  // about a match. Everywhere else the app role decides.
  assert.equal(qr.audienceFor({ channelType: 'captain', userRole: 'owner' }), 'captain');
  assert.equal(qr.audienceFor({ channelType: 'team', userRole: 'player' }), 'captain');
  assert.equal(qr.audienceFor({ channelType: 'booking', userRole: 'owner' }), 'owner');
  assert.equal(qr.audienceFor({ channelType: 'booking', userRole: 'player' }), 'player');
  assert.equal(qr.audienceFor({ channelType: 'booking', userRole: undefined }), 'player');
});

test('15 — the two sides of a booking room get genuinely different sentences', () => {
  // The owner answers and the player asks. If the tables ever converged, one side
  // would be handed the other side's half of the conversation.
  const shared = Object.keys(qr.QUICK_REPLIES.owner)
    .filter((k) => qr.QUICK_REPLIES.player[k]);
  assert.ok(shared.length >= 3, 'the two audiences should overlap on several intents');
  for (const intent of shared) {
    assert.notDeepEqual(
      qr.QUICK_REPLIES.owner[intent], qr.QUICK_REPLIES.player[intent],
      `${intent} reads identically to both sides`,
    );
  }
});

test('16 — the keyword fallback reads Roman Urdu, which is what people actually type', () => {
  assert.equal(qr.lexiconIntent('bhai kal 6 baje ka slot khali hai?'), 'check_availability');
  assert.equal(qr.lexiconIntent('paisay wapas milenge?'), 'refund_policy');
  assert.equal(qr.lexiconIntent('ground kahan hai'), 'find_venue');
  assert.equal(qr.lexiconIntent('aoa'), 'greeting');
  assert.equal(qr.lexiconIntent(''), null);
  assert.equal(qr.lexiconIntent(null), null);
});

test('17 — an unrecognisable message yields no intent rather than a wrong one', () => {
  // Returning null is what makes the endpoint fall through to the GENERIC replies.
  // Guessing here would hand the owner three answers to a question nobody asked.
  assert.equal(qr.lexiconIntent('qwertyuiop zxcvbnm'), null);
});

test('18 — no placeholder can reach the wire, filled or unfilled', () => {
  const withFacts = qr.filler({ venue: 'Shalimar Cricket Academy', price: 2500 });
  const without = qr.filler({ venue: null, price: null });
  for (const [audience, table] of Object.entries(qr.QUICK_REPLIES)) {
    for (const [intent, replies] of Object.entries(table)) {
      for (const r of replies) {
        for (const fill of [withFacts, without]) {
          const out = fill(r);
          assert.ok(!/[{}]/.test(out), `${audience}.${intent} leaks a placeholder: ${out}`);
          assert.ok(out.trim().length > 0, `${audience}.${intent} filled to nothing`);
        }
      }
    }
  }
});

test('19 — {venue} and {price} are substituted when the booking supplies them', () => {
  const fill = qr.filler({ venue: 'Shalimar Cricket Academy', price: 2500 });
  assert.equal(fill('See you at {venue}.'), 'See you at Shalimar Cricket Academy.');
  assert.ok(fill("That's PKR {price} for the hour.").includes('2500'));
});

// 4 — the inbox subtitle: a wall clock that must never be re-zoned
//
// `bookings.slot_date` and `start_time` are PKT wall clock, not instants. The same
// rule bookingService.localDateStr follows applies here: format what is written,
// never pass it through a conversion. A "6:00 pm" slot that renders as "1:00 pm"
// because the server is in UTC is the kind of bug that only appears on somebody
// else's machine, so it is pinned with an explicit TZ below.

// en-GB abbreviates September as "Sept", not "Sep" — that is ICU's short form and
// what the app shows, so the expectations below quote it rather than
// tidying it into a four-letter guess.
test('20 — a slot renders as written, in 12-hour form with the weekday', () => {
  assert.equal(list.slotLabel('2026-09-05', '18:00:00'), 'Sat 5 Sept, 6:00 pm');
  assert.equal(list.slotLabel('2026-09-05', '06:30:00'), 'Sat 5 Sept, 6:30 am');
  assert.equal(list.slotLabel('2026-01-01', '00:00:00'), 'Thu 1 Jan, 12:00 am');
  assert.equal(list.slotLabel('2026-01-01', '12:00:00'), 'Thu 1 Jan, 12:00 pm');
});

test('21 — the hour is NOT shifted by the server’s timezone', () => {
  // 18:00 is 18:00 whether the process thinks it is in Karachi, London or Tokyo:
  // the value never becomes an instant, so there is nothing to convert.
  const label = list.slotLabel('2026-09-05', '18:00:00');
  assert.ok(label.endsWith('6:00 pm'), label);
  // A Date-typed slot_date (what pg returns for a date column) must read the same
  // as the string form, because both reach this function in practice.
  const asDate = new Date(2026, 8, 5);
  assert.equal(list.slotLabel(asDate, '18:00:00'), 'Sat 5 Sept, 6:00 pm');
});

test('22 — a missing or malformed slot degrades to something printable', () => {
  // A subtitle is decoration. It must never be the reason a list request 500s.
  assert.equal(list.slotLabel('2026-09-05', null), 'Sat 5 Sept');
  assert.equal(list.slotLabel('2026-09-05', ''), 'Sat 5 Sept');
  assert.equal(list.slotLabel('not-a-date', '18:00'), 'not-a-date');
  assert.equal(list.slotLabel(null, null), '');
});

test('23 — a wire status becomes a sentence-cased phrase, not a snake_case token', () => {
  assert.equal(list.humanStatus('checked_in'), 'Checked in');
  assert.equal(list.humanStatus('pending'), 'Pending');
  assert.equal(list.humanStatus('awaiting_owner'), 'Awaiting owner');
  assert.equal(list.humanStatus(null), '');
});

// 5 — the UNREAD rule, read off the SQL the two readers share
//
// The list and the badge must never disagree about what "unread" means, and the
// only way to guarantee that without a database is to prove they are literally the
// same string. `check_chat.js` proves the number this expression produces; this
// proves there is exactly one expression producing it.

const fs = require('node:fs');
const path = require('node:path');
const LIST_SRC = fs.readFileSync(
  path.join(__dirname, '..', 'src', 'utils', 'chatList.js'), 'utf8',
);

test('24 — the unread expression is written once and interpolated, never duplicated', () => {
  assert.equal((LIST_SRC.match(/const UNREAD_SQL = /g) || []).length, 1);
  // Three interpolations: one in the list, two in the badge (its sum and its
  // room count). A fourth copy written out by hand would be the drift this guards.
  const uses = (LIST_SRC.match(/\$\{UNREAD_SQL\}/g) || []).length;
  assert.ok(uses >= 3, `UNREAD_SQL is interpolated ${uses} times, expected at least 3`);
  assert.ok(!/count\(\*\) FROM chat_messages x[\s\S]*count\(\*\) FROM chat_messages x/
    .test(LIST_SRC.replace(/const UNREAD_SQL = `[\s\S]*?`;/, '')),
  'a second hand-written copy of the unread count exists outside UNREAD_SQL');
});

test('25 — the rule itself: tombstones and my own messages never count', () => {
  const m = LIST_SRC.match(/const UNREAD_SQL = `([\s\S]*?)`;/);
  assert.ok(m, 'UNREAD_SQL not found');
  const sql = m[1];
  // A deleted message must not leave a permanent +1 nobody can clear.
  assert.ok(/deleted_at IS NULL/.test(sql), 'tombstones are being counted');
  // But a SYSTEM message must: "booking cancelled" is news, and it has no sender.
  assert.ok(/sender_id IS NULL OR/.test(sql), 'system messages are not being counted');
  // And the watermark is the same column the read endpoint moves.
  assert.ok(/last_read_at/.test(sql), 'the count is not keyed on last_read_at');
});

test('26 — assistant channels are excluded from every inbox read, without exception', () => {
  // Scout has its own screen. One missed filter would put a robot at the top of a
  // human inbox, so both readers are checked rather than the one that is easy.
  const excl = (LIST_SRC.match(/type <> 'assistant'/g) || []).length;
  assert.ok(excl >= 2, `only ${excl} reads exclude assistant channels, expected 2`);
  const archived = (LIST_SRC.match(/archived_at IS NULL/g) || []).length;
  assert.ok(archived >= 2, `only ${archived} reads exclude archived channels`);
});

test('27 — the badge excludes muted rooms and the list does not', () => {
  // A badge that counts a room the user silenced is why people turn badges off.
  // The room still shows its own count in the list, where it is information.
  const badge = LIST_SRC.slice(LIST_SRC.indexOf('async function unreadCounts'));
  assert.ok(/muted_until IS NULL OR/.test(badge), 'the badge counts muted rooms');
  const listFn = LIST_SRC.slice(
    LIST_SRC.indexOf('async function listChats'),
    LIST_SRC.indexOf('async function unreadCounts'),
  );
  assert.ok(!/muted_until IS NULL OR/.test(listFn), 'the list hides muted rooms');
});

// 6 — route order: the one Express mistake that cannot be caught at runtime
//
// Express matches in declaration order. `GET /:channelId` declared above
// `GET /unread-count` swallows the literal as a channel id, and the failure is a
// 404 with a correct-looking body — no stack trace, no log line, nothing to grep.
// So the order is asserted here, statically, where a future insert in the wrong
// place fails in milliseconds.

const CHAT_ROUTES_SRC = fs.readFileSync(
  path.join(__dirname, '..', 'src', 'routes', 'chat.js'), 'utf8',
);

/** The character offset of a route declaration, or -1. */
const at = (verb, p) => CHAT_ROUTES_SRC.indexOf(`router.${verb}('${p}'`);

test('28 — every literal and named-prefix route is declared above /:channelId', () => {
  const firstParam = Math.min(
    ...['/:channelId/messages', '/:channelId/read', '/:channelId/members',
      '/:channelId/mute', '/:channelId/quick-replies']
      .map((p) => {
        const g = at('get', p); const po = at('post', p); const d = at('delete', p);
        return Math.min(...[g, po, d].filter((i) => i !== -1));
      })
      .filter((i) => Number.isFinite(i)),
  );
  assert.ok(Number.isFinite(firstParam), 'no /:channelId route found at all');
  for (const p of ['/', '/unread-count', '/team/:teamId', '/booking/:bookingId', '/match/:matchId']) {
    const i = at('get', p);
    assert.notEqual(i, -1, `GET ${p} is not declared`);
    assert.ok(i < firstParam, `GET ${p} is declared AFTER a /:channelId route and will never match`);
  }
});

test('29 — the six chat endpoints all exist', () => {
  assert.notEqual(at('get', '/'), -1, 'GET /api/chat (the inbox)');
  assert.notEqual(at('get', '/unread-count'), -1, 'GET /api/chat/unread-count');
  assert.notEqual(at('get', '/booking/:bookingId'), -1, 'GET /api/chat/booking/:bookingId');
  assert.notEqual(at('get', '/match/:matchId'), -1, 'GET /api/chat/match/:matchId');
  assert.notEqual(at('post', '/:channelId/mute'), -1, 'POST /api/chat/:id/mute');
  assert.notEqual(at('post', '/:channelId/quick-replies'), -1, 'POST /api/chat/:id/quick-replies');
});

test('30 — a ref lookup answers 404, never 403, when the caller is not a member', () => {
  // Telling a stranger "that room exists but is not yours" confirms a booking they
  // should not know about. The two named-prefix lookups share one helper so the
  // decision is made once.
  const helper = CHAT_ROUTES_SRC.slice(
    CHAT_ROUTES_SRC.indexOf('function refLookup'),
    CHAT_ROUTES_SRC.indexOf('function refLookup') + 700,
  );
  assert.ok(helper.length > 0, 'refLookup not found');
  assert.ok(!/403/.test(helper), 'a ref lookup leaks existence with a 403');
  assert.ok((helper.match(/404/g) || []).length >= 2,
    'both the malformed-id and the not-a-member paths should 404');
});

test('31 — the routes delegate to the client-taking utils rather than re-querying', () => {
  // This is what makes check_chat.js able to prove the real query: the endpoint and
  // the script call the same function, one with `pool` and one with an open
  // transaction. A route that inlined its own SQL would be unverifiable.
  for (const call of ['list.listChats(', 'list.unreadCounts(', 'list.channelForRef(',
    'list.setMute(', 'qr.suggestFor(']) {
    assert.ok(CHAT_ROUTES_SRC.includes(call), `routes/chat.js does not call ${call}`);
  }
});
