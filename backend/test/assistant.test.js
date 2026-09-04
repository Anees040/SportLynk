/**
 * test/assistant.test.js — the parts of Scout that can be proved without a database.
 *
 * What this file is for
 * The risk here is not in the SQL; it is in the decisions. A slot merge that keeps a
 * stale slotId puts a confirm card in front of the wrong hour, an affirmation lexicon
 * that says yes to "haan lekin 7 baje" spends the user's money on the wrong slot, and
 * a policy template with a typo'd placeholder tells a user they get a "{refund_pct}%"
 * refund. All three are pure functions, so all three are testable here — no Postgres,
 * no ml-service, no JWT, no network.
 *
 * WHERE the other half lives
 * Anything that touches a row is in src/scripts/check_assistant.js, which runs against
 * the real database inside a transaction it rolls back. The split is deliberate and it
 * is the same one utils/elo has: `npm test` must stay runnable with the database down.
 */
const test = require('node:test');
const assert = require('node:assert/strict');

const dialog = require('../src/services/dialogManager');
const actions = require('../src/services/assistantActions');
const reply = require('../src/utils/assistantReply');
const policyText = require('../src/utils/policyText');
const threads = require('../src/services/assistantThreads');
const discovery = require('../src/services/discoveryService');
const escrow = require('../src/utils/escrow');
const ml = require('../src/services/mlClient');

// 1. The registry — every trained label has somewhere to go

test('assertRoutable: every intent label the model can emit has a handler', () => {
  const out = actions.assertRoutable();
  assert.equal(out.ok, true);
  assert.equal(out.labels, 23, 'intents-v2 has 23 labels');
  assert.equal(out.buttonOnly, 7);
  assert.equal(out.actions, out.labels + out.buttonOnly);
});

// The three tournament actions are executable but untrained, and that is the whole
// point: model #4 v2 was released with 23 labels and nothing retrains it, so the
// classifier cannot start a tournament entry no matter what a user types. If a label
// is ever added for one of these, this test is where it has to be argued.
test('the tournament actions are reachable by chip only, never by the classifier', () => {
  for (const key of ['tournament_detail', 'tournament_register', 'my_tournaments']) {
    assert.equal(actions.isAction(key), true, `${key} has no handler`);
    assert.ok(actions.BUTTON_ONLY.includes(key), `${key} must be button-only`);
    assert.equal(actions.INTENT_LABELS.includes(key), false,
      `${key} is a trained label — model #4 would have to be retrained and re-released`);
  }
  // And the one that spends is behind the confirm gate, not just behind a chip.
  assert.equal(typeof actions.EXECUTORS.tournament_register, 'function',
    'tournament_register must be confirmed before it moves money');
  assert.equal(actions.EXECUTORS.tournament_detail, undefined);
  assert.equal(actions.EXECUTORS.my_tournaments, undefined);
});

test('every ACTIONS value is a function and every label is an action', () => {
  for (const [name, fn] of Object.entries(actions.ACTIONS)) {
    assert.equal(typeof fn, 'function', `${name} is not callable`);
  }
  for (const label of actions.INTENT_LABELS) {
    assert.equal(actions.isAction(label), true, `${label} is not routable`);
  }
});

test('every capability chip points at something executable', () => {
  for (const c of reply.CAPABILITIES) {
    assert.equal(actions.isAction(c.action), true, `capability ${c.action} has no handler`);
    assert.ok(c.label && c.group && c.gloss, `capability ${c.action} is missing display text`);
  }
});

test('the button-only actions are exactly the ones no classifier emits', () => {
  for (const name of actions.BUTTON_ONLY) {
    assert.equal(actions.INTENT_LABELS.includes(name), false,
      `${name} is button-only but the model can also emit it`);
    assert.equal(actions.isAction(name), true);
  }
});

// 2. The affirmation LEXICON — the gate money passes through
//
// verdictOf is the only thing that can arm a confirmed booking, and it is a frozen
// word list rather than the classifier on purpose: a probability cannot be trusted
// with "haan" when the alternative reading costs PKR 2,000. So it must say yes to a
// whole yes, no to a whole no, and NULL to anything with cargo in it.

test('verdictOf: plain yes in both languages', () => {
  for (const yes of ['haan', 'han', 'ji', 'yes', 'yep', 'ok', 'okay', 'theek hai',
    'bilkul', 'confirm', 'kar do', 'haan bhai', 'haan ji please', 'sure yaar']) {
    assert.equal(dialog.verdictOf(yes), 'affirm', `"${yes}" should affirm`);
  }
});

test('verdictOf: plain no in both languages', () => {
  for (const no of ['nahi', 'nahin', 'no', 'nope', 'cancel', 'ruko', 'baad mein',
    'rehne do', 'nahi bhai', 'stop', 'nvm']) {
    assert.equal(dialog.verdictOf(no), 'deny', `"${no}" should deny`);
  }
});

test('verdictOf: an affirmation with CARGO is not an affirmation', () => {
  // The one that matters: "yes but 7pm" is a correction. Reading it as a yes books
  // the 6pm already on the confirm card and the user watches their money go to the
  // wrong hour. Anything the lexicon does not recognise makes the whole thing null.
  for (const mixed of ['haan lekin 7 baje', 'yes but change the date', 'haan 2 ghante',
    'ok but cheaper one', 'yes rawal cricket ground', 'haan nahi', 'no yes']) {
    assert.equal(dialog.verdictOf(mixed), null, `"${mixed}" must not decide`);
  }
});

test('verdictOf: empty, long and unknown input all decline to decide', () => {
  assert.equal(dialog.verdictOf(''), null);
  assert.equal(dialog.verdictOf(null), null);
  assert.equal(dialog.verdictOf('   '), null);
  assert.equal(dialog.verdictOf('haan haan haan haan haan haan haan'), null,
    'over six words is never a bare yes');
  assert.equal(dialog.verdictOf('kya haal hai'), null);
});

test('AFFIRM and DENY do not overlap', () => {
  const both = dialog.AFFIRM.filter((w) => dialog.DENY.includes(w));
  assert.deepEqual(both, [], `a word cannot mean yes and no: ${both.join(', ')}`);
});

test('words(): punctuation and case are not part of a decision', () => {
  assert.deepEqual(dialog.words('Haan, Bhai!'), ['haan', 'bhai']);
  assert.equal(dialog.verdictOf('HAAN!!!'), 'affirm');
  assert.equal(dialog.verdictOf('Nahi...'), 'deny');
});

// 3. SLOTS — what the conversation remembers, and what it must forget

test('cleanSlots: unknown keys from a client are dropped, not stored', () => {
  const out = dialog.cleanSlots({ sport: 'cricket', venueId: 'abc', evil: 'DROP TABLE' });
  assert.deepEqual(Object.keys(out).sort(), ['sport', 'venueId']);
});

test('cleanSlots: numeric slots stay numbers, blanks disappear', () => {
  const out = dialog.cleanSlots({ budget: '2500', n: 3, offset: 'x', sport: '  ', date: '' });
  assert.equal(out.budget, 2500);
  assert.equal(typeof out.budget, 'number');
  assert.equal(out.n, 3);
  assert.equal('offset' in out, false, 'unparseable numbers are dropped');
  assert.equal('sport' in out, false);
  assert.equal('date' in out, false);
});

test('cleanSlots: a long value is truncated rather than rejected', () => {
  const out = dialog.cleanSlots({ question: 'x'.repeat(900) });
  assert.equal(out.question.length, 400);
});

test('mergeSlots: NEW wins, which is what makes a correction work', () => {
  const out = dialog.mergeSlots({ sport: 'cricket', time: '18:00' }, { time: '19:00' });
  assert.equal(out.time, '19:00');
  assert.equal(out.sport, 'cricket', 'unrelated slots survive');
});

test('mergeSlots: a new venue id drops the old venue NAME', () => {
  // {venueId: B, venueName: 'Rawal'} is exactly how a confirm card names the wrong
  // ground. The label must die with the id it described.
  const out = dialog.mergeSlots(
    { venueId: 'aaa', venueName: 'Rawal Cricket Ground' },
    { venueId: 'bbb' },
  );
  assert.equal(out.venueId, 'bbb');
  assert.equal('venueName' in out, false);
});

test('mergeSlots: the same venue id KEEPS its name', () => {
  const out = dialog.mergeSlots(
    { venueId: 'aaa', venueName: 'Rawal' }, { venueId: 'aaa', date: '2026-08-30' },
  );
  assert.equal(out.venueName, 'Rawal');
});

test('mergeSlots: a change of subject forgets DECISIONS but keeps PREFERENCES', () => {
  const out = dialog.mergeSlots(
    { sport: 'cricket', area: 'Lahore', slotId: 's1', venueId: 'v1', bookingId: 'b1' },
    { },
    { keepDecisions: false },
  );
  assert.equal(out.sport, 'cricket', 'a preference is still true after the subject changes');
  assert.equal(out.area, 'Lahore');
  assert.equal('slotId' in out, false, 'a stale slot id would confirm the wrong hour');
  assert.equal('bookingId' in out, false);
});

// 4. ENTITIES → SLOTS — five shapes, none of them `.value`
//
// The Python extractor names each entity's payload after the evidence it carries, so
// the obvious `.value` read would silently drop four of the five. This test is the
// contract with ml-service/app/core/entity_rules.py.

test('slotsFromEntities: each of the five slots is read from its OWN field', () => {
  const out = dialog.slotsFromEntities({
    date: { iso: '2026-08-30', text: 'kal' },
    time: { start: '18:00', end: '19:00' },
    sport: { value: 'cricket', variant: 'tapeball' },
    area: { area: 'dha phase 5', city: 'lahore' },
    budget: { op: 'max', max: 2500 },
  });
  assert.equal(out.date, '2026-08-30');
  assert.equal(out.time, '18:00');
  assert.equal(out.sport, 'cricket');
  assert.equal(out.area, 'Lahore', 'a CITY becomes the city filter');
  assert.equal(out.locality, 'Dha Phase 5', 'a NEIGHBOURHOOD becomes free text over the address');
  assert.equal(out.budget, 2500);
});

test('slotsFromEntities: "sasta" has no number, so it becomes a SORT', () => {
  const out = dialog.slotsFromEntities({ budget: { op: 'qualitative' } });
  assert.equal(out.sort, 'price_low');
  assert.equal('budget' in out, false, 'an invented ceiling would hide grounds the user would take');
});

test('slotsFromEntities: "around 2000" is a number, not a ceiling label', () => {
  const out = dialog.slotsFromEntities({ budget: { op: 'about', amount: 2000 } });
  assert.equal(out.budget, 2000);
});

test('slotsFromEntities: nothing extracted means nothing filled', () => {
  assert.deepEqual(dialog.slotsFromEntities(null), {});
  assert.deepEqual(dialog.slotsFromEntities({ date: null, sport: null }), {});
  assert.deepEqual(dialog.slotsFromEntities({ area: {} }), {});
});

// 5. The state machine — what the telemetry column records

test('fsmStateOf: the four states, and confirm outranks pending', () => {
  assert.equal(dialog.fsmStateOf(null), dialog.FSM.IDLE);
  assert.equal(dialog.fsmStateOf({}), dialog.FSM.IDLE);
  assert.equal(dialog.fsmStateOf({ pending: 'date' }), dialog.FSM.SLOT_FILLING);
  assert.equal(dialog.fsmStateOf({ pending: 'venue' }), dialog.FSM.AWAITING_CHOICE,
    'a venue is chosen by TAPPING, so it is not slot filling');
  assert.equal(dialog.fsmStateOf({ pending: 'slot' }), dialog.FSM.AWAITING_CHOICE);
  assert.equal(dialog.fsmStateOf({ pending: 'question' }), dialog.FSM.SLOT_FILLING);
  assert.equal(
    dialog.fsmStateOf({ pending: 'slot', confirm: { action: 'book_venue' } }),
    dialog.FSM.AWAITING_CONFIRM,
    'money on screen is the state that matters',
  );
});

test('every PENDING_SLOT question names a real slot key', () => {
  for (const [pending, slot] of Object.entries(dialog.PENDING_SLOT)) {
    assert.equal(dialog.SLOT_KEYS.includes(slot), true,
      `pending '${pending}' fills '${slot}', which cleanSlots would drop`);
  }
});

// 6. Continuation — "kal" as an answer, not a new request
//
// The hole this closes: Scout asks "Which day at Rawal?", the user types "kal", and no
// intent model calls a bare adverb book_venue -- it abstains, correctly. Without
// continuationOf the booking dies and the user gets a help menu in answer to their own
// answer.

const abstained = (over = {}) => ({
  intent: null, abstained: true, confidence: 0.2, incoming: {}, inputMode: 'text', ...over,
});

test('continuationOf: an abstain while a question is pending re-runs the PENDING intent', () => {
  const out = dialog.continuationOf({
    prior: { intent: 'book_venue', pending: 'date' },
    said: 'kal',
    decided: abstained({ incoming: { date: '2026-08-30' } }),
  });
  assert.equal(out.intent, 'book_venue');
  assert.deepEqual(out.fill, {}, 'the extractor already filled the date; nothing to invent');
});

test('continuationOf: a TYPED answer to "which ground?" becomes a name to resolve', () => {
  const out = dialog.continuationOf({
    prior: { intent: 'book_venue', pending: 'venue' },
    said: 'rawal cricket ground',
    decided: abstained(),
  });
  assert.equal(out.intent, 'book_venue');
  assert.equal(out.fill.venueName, 'rawal cricket ground');
});

test('continuationOf: a CONFIDENT different intent always wins', () => {
  const out = dialog.continuationOf({
    prior: { intent: 'book_venue', pending: 'date' },
    said: 'wallet balance kitna hai',
    decided: { intent: 'wallet_balance', abstained: false, confidence: 0.95, incoming: {}, inputMode: 'text' },
  });
  assert.equal(out, null, 'abandoning a half-built booking to ask the balance must work');
});

test('continuationOf: pending "question" swallows any text, confident or not', () => {
  // Otherwise "is there parking?" classifies as venue_info and answers a question the
  // user did not ask -- which also breaks the KB learning loop they opted into.
  const out = dialog.continuationOf({
    prior: { intent: 'contact_owner', pending: 'question' },
    said: 'is there parking at the back?',
    decided: { intent: 'venue_info', abstained: false, confidence: 0.91, incoming: {}, inputMode: 'text' },
  });
  assert.equal(out.intent, 'contact_owner');
  assert.equal(out.fill.question, 'is there parking at the back?');
});

test('continuationOf: a CHIP is never a continuation', () => {
  const out = dialog.continuationOf({
    prior: { intent: 'book_venue', pending: 'date' },
    said: 'Wallet',
    decided: { intent: 'wallet_balance', abstained: false, confidence: 1, incoming: {}, inputMode: 'chip' },
  });
  assert.equal(out, null, 'a chip carries its own action and needs no rescue');
});

test('continuationOf: nothing pending, nothing to continue', () => {
  assert.equal(dialog.continuationOf({
    prior: { intent: 'book_venue', pending: null }, said: 'kal', decided: abstained(),
  }), null);
  assert.equal(dialog.continuationOf({
    prior: { intent: null, pending: 'date' }, said: 'kal', decided: abstained(),
  }), null, 'a pending slot with no intent behind it is not resumable');
});

// 7. The payload — Flutter renders by type, so a typo must die here

test('reply(): source is required and validated', () => {
  assert.throws(() => reply.reply('hi', {}), /source must be one of/);
  assert.throws(() => reply.reply('hi', { source: 'lIve' }), /source must be one of/);
  assert.throws(() => reply.reply('hi', { source: 'llm' }), /source must be one of/,
    'there is no LLM in this system and no source that claims one');
  for (const s of reply.SOURCE_VALUES) {
    assert.equal(reply.reply('hi', { source: s }).source, s);
  }
});

test('reply(): the six sources are exactly the ones the CHECK constraint allows', () => {
  assert.deepEqual([...reply.SOURCE_VALUES].sort(),
    ['escalated', 'kb', 'live', 'menu', 'model', 'policy']);
});

test('reply(): an unknown card type throws before it can reach the client', () => {
  assert.throws(
    () => reply.reply('hi', { source: 'live', cards: [{ type: 'graph', data: {} }] }),
    /unknown card type/,
  );
  assert.throws(() => reply.reply('hi', { source: 'live', cards: [null, undefined] }),
    /unknown card type/);
});

test('reply(): every declared card type is accepted', () => {
  for (const t of reply.CARD_VALUES) {
    const out = reply.reply('x', { source: 'live', cards: [reply.card(t, { a: 1 })] });
    assert.equal(out.cards[0].type, t);
  }
});

test('reply(): the payload shape is text + chips + cards + source, always', () => {
  const out = reply.reply('  spaced  ', { source: 'live' });
  assert.deepEqual(Object.keys(out).sort(), ['cards', 'chips', 'source', 'text']);
  assert.equal(out.text, 'spaced');
  assert.deepEqual(out.chips, []);
  assert.deepEqual(out.cards, []);
  const withAction = reply.reply(null, { source: 'live', action: 'book_venue', actionOk: false });
  assert.equal(withAction.text, '', 'a null text is an empty bubble, not the string "null"');
  assert.equal(withAction.action, 'book_venue');
  assert.equal(withAction.actionOk, false, 'actionOk:false must survive; only null is omitted');
});

test('chip(): a label is capped and args are omitted when empty', () => {
  const c = reply.chip('x'.repeat(80), 'find_venue');
  assert.equal(c.label.length, 40);
  assert.equal('args' in c, false);
  assert.deepEqual(reply.chip('Book', 'book_venue', { venueId: 'v1' }).args, { venueId: 'v1' });
  assert.equal('args' in reply.chip('Book', 'book_venue', {}), false);
});

test('menu(): the abstain reply is never text alone', () => {
  const m = reply.menu(null, {});
  assert.equal(m.source, 'menu');
  assert.ok(m.text.length > 0, 'a menu with no sentence is a blank bubble');
  assert.ok(m.chips.length > 0, 'ER2.6: low confidence must offer buttons');
  assert.ok(m.cards.some((c) => c.type === reply.CARDS.CAPABILITIES),
    'the help menu is a card, so Flutter can group it');
  for (const c of m.chips) {
    assert.equal(actions.isAction(c.action), true, `menu chip ${c.action} is not executable`);
  }
});

test('abstainReply(): all five reasons return a menu with chips', () => {
  const ml = require('../src/services/mlClient');
  const reasons = [ml.NLU_ABSTAIN_UNAVAILABLE, ml.NLU_ABSTAIN_TOO_LONG,
    ml.NLU_ABSTAIN_LOW_CONFIDENCE, ml.NLU_ABSTAIN_NO_KNOWN_TERMS, 'something_new'];
  for (const reason of reasons) {
    const out = dialog.abstainReply({ reason, name: 'Scout' });
    assert.equal(out.source, 'menu', `${reason} must still be honest about its source`);
    assert.ok(out.text.length > 0, `${reason} has no sentence`);
    assert.ok(out.chips.length > 0, `${reason} is a dead end`);
  }
});

test('abstainReply(): low confidence promotes the runner-up intents to chips', () => {
  const ml = require('../src/services/mlClient');
  const out = dialog.abstainReply({
    reason: ml.NLU_ABSTAIN_LOW_CONFIDENCE,
    alternatives: [{ intent: 'find_venue' }, { intent: 'my_bookings' }],
  });
  assert.equal(out.chips[0].action, 'find_venue');
  assert.equal(out.chips[1].action, 'my_bookings');
  assert.ok(out.chips.length <= 6, 'six chips is already a wall of buttons');
});

test('guessChips(): never offers a gate, a greeting or the failure itself', () => {
  const out = dialog.guessChips([
    { intent: 'affirm' }, { intent: 'deny' }, { intent: 'out_of_scope' },
    { intent: 'greeting' }, { intent: 'not_a_real_intent' }, { intent: 'wallet_balance' },
  ]);
  assert.equal(out.length, 1);
  assert.equal(out[0].action, 'wallet_balance');
});

// 8. POLICY text — the sentence is stored, the numbers come from escrow.js
//
// Golden rule 3: utils/escrow.js POLICY is the single source of truth for money. So a
// policy answer is a template plus substitution, never a typed-out "20%". A placeholder
// nobody can fill is the failure mode this section exists to catch.

test('every seeded fallback renders with no placeholder left behind', () => {
  for (const [name, template] of Object.entries(policyText.FALLBACKS)) {
    assert.deepEqual(policyText.unfilled(template), [],
      `${name} uses a placeholder values() cannot fill`);
    const text = policyText.render(template);
    assert.equal(/\{[a-z0-9_]+\}/i.test(text), false, `${name} still has a {placeholder}: ${text}`);
  }
});

test('all seven topics have a fallback, and TOPICS is the list', () => {
  assert.equal(policyText.TOPICS.length, 7);
  for (const name of policyText.TOPICS) {
    assert.equal(typeof policyText.FALLBACKS[name], 'string', `${name} has no fallback sentence`);
  }
  assert.deepEqual(Object.keys(policyText.FALLBACKS).sort(), [...policyText.TOPICS].sort());
});

test('the rendered numbers ARE escrow POLICY, not copies of it', () => {
  const v = policyText.values();
  assert.equal(v.deposit_pct, Number(escrow.POLICY.DEPOSIT_PERCENT));
  assert.equal(v.refund_pct, 100 - Number(escrow.POLICY.DEPOSIT_PERCENT));
  assert.equal(v.window_hours, Number(escrow.POLICY.CANCELLATION_WINDOW_HOURS));
  assert.equal(v.no_show_grace, Number(escrow.POLICY.NO_SHOW_GRACE_MINUTES));
  assert.equal(v.trust_penalty, Number(escrow.POLICY.NO_SHOW_TRUST_PENALTY));
  assert.equal(v.withdrawal_min, Number(escrow.POLICY.WITHDRAWAL_MIN_AMOUNT));
  const refund = policyText.render('{refund_pct}% back');
  assert.equal(refund, `${100 - Number(escrow.POLICY.DEPOSIT_PERCENT)}% back`);
});

test('an unknown placeholder is left visible rather than blanked', () => {
  // "you get a % refund" is a sentence a user would believe. "{refund_pctt}%" is one
  // they would report, which is the desired outcome.
  assert.equal(policyText.render('you get {refund_pctt}% back'), 'you get {refund_pctt}% back');
  assert.deepEqual(policyText.unfilled('{refund_pctt} and {refund_pct}'), ['refund_pctt']);
});

test('humanMinutes: hours read as hours', () => {
  assert.equal(policyText.humanMinutes(60), '1 hour');
  assert.equal(policyText.humanMinutes(120), '2 hours');
  assert.equal(policyText.humanMinutes(45), '45 minutes');
  assert.equal(policyText.humanMinutes(1), '1 minute');
  assert.equal(policyText.humanMinutes(90), '1h 30m');
  assert.equal(policyText.humanMinutes(0), '0 minutes');
  assert.equal(policyText.humanMinutes(null), '0 minutes');
});

test('topic(): a stored template wins over the fallback and says so', () => {
  const stored = policyText.topic('refund_policy',
    { policyText: { refund_policy: 'Cancel {window_hours}h before for everything back.' } });
  assert.equal(stored.seeded, true);
  assert.equal(stored.source, 'policy');
  assert.ok(stored.text.includes(`${policyText.values().window_hours}h`));
  const fell = policyText.topic('refund_policy', {});
  assert.equal(fell.seeded, false, 'an unseeded database still gets a real answer');
  assert.ok(fell.text.length > 0);
  assert.equal(policyText.topic('not_a_topic', {}).text, '');
});

test('policyTopicFor: the user\'s OWN WORDS choose the paragraph', () => {
  assert.equal(actions.policyTopicFor({ said: 'refund policy kya hai' }), 'refund_policy');
  assert.equal(actions.policyTopicFor({ said: 'no show hone pe kya hota hai' }), 'no_show');
  assert.equal(actions.policyTopicFor({ said: 'deposit kitna hai' }), 'deposit');
  assert.equal(actions.policyTopicFor({ said: 'paise kaise nikaloon' }), 'withdrawal');
});

test('policyTopicFor: a STALE topic slot cannot answer the wrong question', () => {
  // topic survives in session_state across turns of the same intent, so "no-show rules"
  // followed by "refund policy?" would have answered no-show twice.
  assert.equal(
    actions.policyTopicFor({ said: 'refund policy?', slotTopic: 'no_show' }),
    'refund_policy',
    'words beat a leftover slot',
  );
  assert.equal(
    actions.policyTopicFor({ said: '', slotTopic: 'no_show' }),
    'no_show',
    'with no text at all -- a chip press -- the chip argument is trusted',
  );
  assert.equal(actions.policyTopicFor({ said: '', slotTopic: 'made_up' }), 'refund_policy');
  assert.equal(actions.policyTopicFor({}), 'refund_policy');
});

// 9. Dates — two opposite corrections, both real bugs
//
// node-postgres hands back a date column as a JS Date at local midnight, so
// toISOString() on a machine west of PKT prints the day before -- and a booking
// confirmation is the worst place to be off by one day. dateStr therefore subtracts
// the local offset. A timestamptz is a real instant, so pktDay adds the PKT offset
// instead. Getting these backwards is invisible until a demo runs at 9pm.

test('dateStr(): a DATE column keeps its calendar day', () => {
  // What pg returns for a date of 2026-08-30, whatever the server's timezone is.
  const localMidnight = new Date(2026, 7, 30, 0, 0, 0);
  assert.equal(actions.dateStr(localMidnight), '2026-08-30');
  // And late in the evening, the case that breaks a naive toISOString() east of UTC.
  assert.equal(actions.dateStr(new Date(2026, 7, 30, 23, 30, 0)), '2026-08-30');
  assert.equal(actions.dateStr('2026-08-30'), '2026-08-30');
  assert.equal(actions.dateStr('2026-08-30T18:00:00Z'), '2026-08-30');
  assert.equal(actions.dateStr(null), '');
});

test('pktDay(): a timestamptz is converted, not relabelled', () => {
  // 2026-08-30T20:00Z is already the 31st in Pakistan (UTC+5).
  assert.equal(actions.pktDay(new Date('2026-08-30T20:00:00Z')), '2026-08-31');
  assert.equal(actions.pktDay(new Date('2026-08-30T10:00:00Z')), '2026-08-30');
  assert.equal(actions.pktDay('2026-08-30'), '2026-08-30', 'a plain string is already a day');
});

test('pktDate(): today and tomorrow agree with discoveryService', () => {
  assert.equal(actions.pktDate(0), discovery.pktNow().date);
  const t0 = new Date(`${actions.pktDate(0)}T00:00:00Z`).getTime();
  const t1 = new Date(`${actions.pktDate(1)}T00:00:00Z`).getTime();
  assert.equal(t1 - t0, 86400000, '"kal" is exactly one day after "aaj"');
});

test('discovery.normDate(): junk becomes today rather than an error', () => {
  assert.equal(discovery.normDate('2026-08-30'), '2026-08-30');
  assert.equal(discovery.normDate('tomorrow'), discovery.pktNow().date);
  assert.equal(discovery.normDate(''), discovery.pktNow().date);
  assert.equal(discovery.normDate(null), discovery.pktNow().date);
  assert.equal(discovery.normDate('30-08-2026'), discovery.pktNow().date);
});

test('the PKT offset is five hours with no DST', () => {
  assert.equal(discovery.PKT_OFFSET_MS, 5 * 60 * 60 * 1000);
  assert.equal(String(escrow.POLICY.TIMEZONE), 'Asia/Karachi');
});

test('day() and clock(): what a chip says', () => {
  assert.equal(actions.day('2026-08-30'), 'Sun 30 Aug');
  assert.equal(actions.day('2026-08-30T00:00:00Z'), 'Sun 30 Aug');
  assert.equal(actions.clock('18:00:00'), '6:00 PM');
  assert.equal(actions.clock('06:30:00'), '6:30 AM');
  assert.equal(actions.clock('00:00:00'), '12:00 AM');
  assert.equal(actions.clock('12:00:00'), '12:00 PM');
  assert.equal(actions.clock('23:00'), '11:00 PM');
});

test('money(): a price is grouped and prefixed, never a bare float', () => {
  assert.equal(actions.money(2000), 'PKR 2,000');
  assert.equal(actions.money('1600.5'), 'PKR 1,600.5');
  assert.equal(actions.money(0), 'PKR 0');
  assert.equal(actions.money(null), 'PKR 0', 'a missing price must not print "PKR null"');
});

// 10. The REFUND sentence — "PKR 1,600 back (80%)" must be arithmetic
//
// The spec asks the cancel flow to quote the refund before executing. Scout quotes
// bookingService.previewCancellation, which derives its numbers from these two escrow
// functions -- so the number in the question is the number in the ledger by
// construction, not by two implementations agreeing.

test('penaltySplit(): a late cancellation keeps the deposit and refunds the rest', () => {
  const escrowHeld = 2000;
  const deposit = escrow.depositFor(escrowHeld);
  const { refund, penalty } = escrow.penaltySplit(escrowHeld, deposit);
  assert.equal(refund + penalty, escrowHeld, 'money is conserved');
  assert.equal(penalty, deposit);
  assert.equal(Math.round((refund / escrowHeld) * 100), 100 - Number(escrow.POLICY.DEPOSIT_PERCENT));
  // The exact sentence the confirm card asks, at the exact price the demo uses.
  assert.equal(actions.money(refund), 'PKR 1,600');
  assert.equal(refund, 1600);
});

test('depositFor(): the 20% in the spec comes from POLICY, not from a literal', () => {
  assert.equal(escrow.depositFor(2000), 2000 * Number(escrow.POLICY.DEPOSIT_PERCENT) / 100);
  assert.equal(escrow.depositFor(0), 0);
  assert.equal(escrow.round2(escrow.depositFor(1499)), escrow.round2(1499 * 0.2));
});

test('isLateCancellation(): the window is the boundary, in PKT', () => {
  const H = Number(escrow.POLICY.CANCELLATION_WINDOW_HOURS);
  const inPkt = (ms) => new Date(Date.now() + ms + discovery.PKT_OFFSET_MS);
  const iso = (d) => d.toISOString();
  const far = inPkt((H + 6) * 3600000);
  const soon = inPkt(1 * 3600000);
  assert.equal(escrow.isLateCancellation(iso(far).slice(0, 10), iso(far).slice(11, 19)), false,
    `more than ${H}h away is a full refund`);
  assert.equal(escrow.isLateCancellation(iso(soon).slice(0, 10), iso(soon).slice(11, 19)), true,
    'an hour before the slot is a late cancellation');
});

// 11. Threads — history, new chat, rename, and the state that survives a reload

test('readState(): an unknown version RESETS rather than being half-understood', () => {
  const fresh = threads.freshState();
  assert.equal(fresh.v, threads.STATE_VERSION);
  assert.deepEqual(threads.readState({ v: 99, confirm: { action: 'book_venue' } }), fresh,
    'a state we cannot read must never carry a confirm block forward');
  assert.deepEqual(threads.readState(null), fresh);
  assert.deepEqual(threads.readState('nonsense'), fresh);
  assert.deepEqual(threads.readState([]), fresh);
});

test('readState(): a valid state keeps its fields and drops junk types', () => {
  const out = threads.readState({
    v: threads.STATE_VERSION, intent: 'book_venue', slots: { sport: 'cricket' },
    pending: 'date', confirm: { action: 'book_venue' }, ctx: { lastIntent: 'find_venue' },
  });
  assert.equal(out.intent, 'book_venue');
  assert.equal(out.pending, 'date');
  assert.deepEqual(out.slots, { sport: 'cricket' });
  assert.equal(out.confirm.action, 'book_venue');
  assert.equal(out.ctx.lastIntent, 'find_venue');
  const bad = threads.readState({ v: threads.STATE_VERSION, intent: 42, slots: [], pending: {} });
  assert.equal(bad.intent, null);
  assert.deepEqual(bad.slots, {});
  assert.equal(bad.pending, null);
});

test('titleFrom(): the first message names the chat, the way every chat app does', () => {
  assert.equal(threads.titleFrom('kal shaam cricket ground chahiye'),
    'kal shaam cricket ground chahiye');
  assert.equal(threads.titleFrom(''), threads.DEFAULT_TITLE);
  assert.equal(threads.titleFrom('   '), threads.DEFAULT_TITLE);
  assert.equal(threads.titleFrom('a  b\n c'), 'a b c', 'newlines would break a list row');
  const long = threads.titleFrom('x'.repeat(100));
  assert.equal(long.length, 42);
  assert.ok(long.endsWith('...'));
});

test('decodeCursor(): a junk cursor is "no cursor", not a 400', () => {
  const id = '3f2504e0-4f89-11d3-9a0c-0305e82c3301';
  assert.equal(threads.decodeCursor(id), id);
  assert.equal(threads.decodeCursor(id.toUpperCase()), id.toUpperCase());
  assert.equal(threads.decodeCursor('2026-08-30T10:00:00.123456Z'), null,
    'the timestamp cursor that lost its microseconds is not accepted');
  assert.equal(threads.decodeCursor(''), null);
  assert.equal(threads.decodeCursor(null), null);
  assert.equal(threads.decodeCursor(42), null);
});

// 12. CARDS — every action card has buttons (the spec's hard rule)

const VENUE_ROW = {
  id: 'v1', name: 'Rawal Cricket Ground', city: 'Islamabad', address: 'Sector G-9',
  sport_type: 'cricket', price_per_hour: '2000.00', rating: '4.5', total_reviews: 12,
  cover_photo: 'https://x/1.jpg', latitude: '33.68', longitude: '73.04',
};

test('venueCard: numbers are numbers, and an absent ranker invents no percentage', () => {
  const c = actions.venueCard(VENUE_ROW, { matchPct: null, sport: 'cricket', date: '2026-08-30' });
  assert.equal(c.type, reply.CARDS.VENUE);
  assert.equal(c.data.pricePerHour, 2000);
  assert.equal(typeof c.data.rating, 'number');
  assert.equal(c.data.matchPct, null, 'a 0 here would be a lie with a number on it');
  assert.deepEqual(c.data.reasons, []);
  assert.ok(c.data.buttons.length >= 2, 'a venue card with no buttons is a dead end');
  for (const b of c.data.buttons) assert.equal(actions.isAction(b.action), true);
  assert.ok(c.data.buttons.some((b) => b.action === 'navigate'),
    'a venue with coordinates offers Directions');
});

test('venueCard: no coordinates means no Directions button', () => {
  const c = actions.venueCard({ ...VENUE_ROW, latitude: null, longitude: null }, {});
  assert.equal(c.data.buttons.some((b) => b.action === 'navigate'), false);
  assert.equal(c.data.lat, null);
});

test('venueCard: a real matchPct is passed through unchanged', () => {
  const c = actions.venueCard(VENUE_ROW, { matchPct: 87, reasons: ['cricket', 'in budget'] });
  assert.equal(c.data.matchPct, 87);
  assert.deepEqual(c.data.reasons, ['cricket', 'in budget']);
});

test('slotPickerCard: numbered chips, because "2" is a thing a user types', () => {
  const c = actions.slotPickerCard(VENUE_ROW, [
    { id: 's1', start_time: '18:00:00', end_time: '19:00:00', price: '2000' },
    { id: 's2', start_time: '19:00:00', end_time: '20:00:00', price: '2000' },
  ], { date: '2026-08-30' });
  assert.equal(c.type, reply.CARDS.SLOT_PICKER);
  assert.equal(c.data.slots[0].n, 1);
  assert.equal(c.data.slots[0].label, '6:00 PM');
  assert.equal(c.data.slots[0].priceLabel, 'PKR 2,000');
  assert.equal(c.data.dateLabel, 'Sun 30 Aug');
  assert.equal(c.data.buttons.length, 2);
  assert.equal(c.data.buttons[0].action, 'pick_slot');
  assert.equal(c.data.buttons[0].args.slotId, 's1');
});

test('confirmCard: the deposit line comes from POLICY and both ways out are buttons', () => {
  const c = actions.confirmCard({
    what: 'book_venue', title: 'Rawal Cricket Ground',
    lines: ['Sun 30 Aug, 6:00 PM'], total: 2000, deposit: escrow.depositFor(2000),
  });
  assert.equal(c.type, reply.CARDS.CONFIRM);
  assert.equal(c.data.depositPct, escrow.POLICY.DEPOSIT_PERCENT);
  assert.equal(c.data.depositLabel, 'PKR 400');
  assert.equal(c.data.totalLabel, 'PKR 2,000');
  assert.deepEqual(c.data.buttons.map((b) => b.action), ['confirm', 'cancel_confirm'],
    'there is no default action on a card that spends money');
});

test('bookingCard: a pending booking is not softened into a confirmed one', () => {
  const c = actions.bookingCard({
    id: 'b1', status: 'pending', slot_date: '2026-08-30', start_time: '18:00:00',
    end_time: '19:00:00', venue_name: 'Rawal', total_amount: '2000',
  });
  assert.equal(c.type, reply.CARDS.BOOKING);
  assert.equal(c.data.status, 'pending');
});

test('SCREENS: the deep-link map is a contract with Flutter, and `screen` survives a chip', () => {
  assert.ok(Object.keys(actions.SCREENS).length >= 12);
  for (const [key, entry] of Object.entries(actions.SCREENS)) {
    assert.equal(Array.isArray(entry), true, `${key} must be [label, gloss]`);
    assert.equal(entry.length, 2);
    assert.ok(entry[0] && entry[1]);
  }
  // cleanSlots would drop the chip arg that names the screen if SLOT_KEYS forgot it.
  assert.equal(dialog.cleanSlots({ screen: 'wallet' }).screen, 'wallet');
});

// 13. Abstention recovery — the parse survives, so offer it as a button
//
// The entity extractor runs beside the classifier, not inside it, so a turn can
// abstain on the intent while holding a flawless "football, Islamabad, tomorrow 6pm".
// The measured case: "kal shaam football islamabad" parsed all four entities and
// still scored find_venue 0.364 against a 0.45 floor. The corpus fix (eight verbless
// keyword templates, retrained to intent-v2-20260828-2315) took that to 0.81, and this
// is the belt to its braces for the abstentions that remain.
//
// The invariant these tests defend is WHERE the recovery happens: a chip carries its
// own {action, args}, so tapping one re-enters decide() through the chip door. Nothing
// here promotes a low score to an action -- the user does, with a tap.

const ABSTAIN = {
  low: ml.NLU_ABSTAIN_LOW_CONFIDENCE,
  none: ml.NLU_ABSTAIN_NO_EVIDENCE,
  terms: ml.NLU_ABSTAIN_NO_KNOWN_TERMS,
  down: ml.NLU_ABSTAIN_UNAVAILABLE,
  long: ml.NLU_ABSTAIN_TOO_LONG,
};

test('slotSearchChip: a parsed sport and city become one routable button', () => {
  const out = dialog.slotSearchChip({
    sport: 'football', area: 'Islamabad', date: '2026-08-30', time: '18:00',
  });
  assert.equal(out.action, 'find_venue');
  assert.equal(actions.isAction(out.action), true, 'a chip nothing executes is worse than no chip');
  assert.match(out.label, /Football in Islamabad/);
  // Every arg must survive the whitelist, or the tap searches without them.
  assert.deepEqual(dialog.cleanSlots(out.args), {
    sport: 'football', area: 'Islamabad', date: '2026-08-30', time: '18:00',
  });
});

test('slotSearchChip: date and time ALONE offer nothing — the abstention stands', () => {
  // "kal shaam" is the utterance the model is right to abstain on: it names no sport
  // and no place. A venue-search button here would be inventing the intent that the
  // abstention just declined to invent.
  assert.equal(dialog.slotSearchChip({ date: '2026-08-30', time: '18:00' }), null);
  assert.equal(dialog.slotSearchChip({}), null);
  assert.equal(dialog.slotSearchChip(null), null);
});

test('slotSearchChip: a place with no sport still searches, and a bare sport still searches', () => {
  assert.match(dialog.slotSearchChip({ area: 'Islamabad' }).label, /^Grounds in Islamabad$/);
  assert.match(dialog.slotSearchChip({ sport: 'cricket' }).label, /^Cricket grounds$/);
  // A neighbourhood is a `locality`, not a city -- slotsFromEntities' own distinction.
  const near = dialog.slotSearchChip({ sport: 'futsal', locality: 'F-11 Markaz' });
  assert.equal(near.args.locality, 'F-11 Markaz');
  assert.equal(near.args.area, undefined);
});

test('slotSearchChip: the label fits the chip cap, and the args keep what it drops', () => {
  const out = dialog.slotSearchChip({
    sport: 'badminton', locality: 'Bahria Town Phase 7', date: '2026-08-30', time: '18:00',
  });
  assert.ok(out.label.length <= 40, `40 is chip()'s own cap, got ${out.label.length}`);
  assert.equal(out.label.endsWith('Ag'), false, 'a label chopped mid-word reads like a bug');
  // The label had no room for the time; the search must still use it.
  assert.equal(out.args.time, '18:00');
  assert.equal(out.args.date, '2026-08-30');
});

test('abstainReply: the slot chip leads on all five reasons, including "we are down"', () => {
  const slotChip = dialog.slotSearchChip({ sport: 'football', area: 'Islamabad' });
  for (const [why, reason] of Object.entries(ABSTAIN)) {
    const out = dialog.abstainReply({ reason, slotChip, name: 'Scout' });
    assert.equal(out.chips[0].action, 'find_venue', `${why} dropped the slot chip`);
    assert.equal(out.chips[0].label, slotChip.label);
    assert.ok(out.chips.length <= 6, `${why} exceeded the chip cap`);
    // Never at the cost of the capability menu: ER2.6 wants the help card on all five.
    assert.ok(out.cards.some((c) => c.type === 'capabilities'), `${why} lost the menu`);
  }
});

test('abstainReply: the slot chip outranks the "did you mean" guesses', () => {
  // Order is the whole point: the concrete search the user just described beats a
  // label-only guess at what they meant.
  const out = dialog.abstainReply({
    reason: ABSTAIN.low,
    alternatives: [{ intent: 'find_players', confidence: 0.31 }, { intent: 'book_venue', confidence: 0.2 }],
    slotChip: dialog.slotSearchChip({ sport: 'football', area: 'Islamabad' }),
  });
  assert.equal(out.chips[0].action, 'find_venue');
  assert.deepEqual(out.chips.slice(1, 3).map((c) => c.action), ['find_players', 'book_venue']);
});

test('abstainReply: no parse, no chip — the reply is exactly what it was before', () => {
  const bare = dialog.abstainReply({ reason: ABSTAIN.terms, name: 'Scout' });
  assert.equal(bare.chips.some((c) => c.action === 'find_venue' && c.args), false);
  assert.ok(bare.cards.some((c) => c.type === 'capabilities'));
});

// The pool opens on require (services/dialogManager -> db/pool). Without this the
// suite sits on an idle client until node's own timeout, which turns a 300ms test
// file into a 13-second one.
test.after(async () => {
  await require('../src/db/pool').end();
});
