/**
 * quickReplies.js — FR8.10, AI quick replies.
 *
 * A venue owner answers the same six questions all day. This reads the message
 * the other side just sent, classifies it with model #4 — the released 23-label
 * intent classifier, unchanged, no new labels, nothing retrained — and hands back
 * three replies that can be sent with one tap.
 *
 * Advisory only, and that is a hard rule. A suggestion is text placed in the
 * composer; the human still presses send, and the send goes through the ordinary
 * POST /:channelId/messages path with the same validation, the same flood limit
 * and the same idempotency key. Nothing here can put words in somebody's mouth,
 * which is the whole difference between a helpful chip and a bot that lies to a
 * customer on the owner's behalf.
 *
 * Why the replies are A TABLE AND NOT GENERATED
 * A generated sentence can invent a price, a slot or a refund policy. These
 * cannot: the only variable parts are `{venue}` and `{price}`, both read from the
 * booking row this channel already points at. The trained model does the part a
 * model is good at — understanding a Roman-Urdu question — and none of the part
 * it would get wrong.
 *
 * Why this is a utility module and not inline in routes/chat.js
 * `suggestFor` takes a `client`, so check_chat.js can drive the real classifier
 * over rows inside its own transaction and roll them back. Same discipline as
 * chatList.js and bookingService's core functions.
 */

const mlClient = require('../services/mlClient');
const access = require('./teamAccess');

/**
 * intent → three replies, per audience. Keys are real labels from the frozen
 * 23-label spec (ml-service/app/core/intent_spec.py) — an intent the model
 * cannot emit is a branch that can never run, so there are none here.
 */
const QUICK_REPLIES = {
  owner: {
    check_availability: [
      'Yes, that slot is free.',
      "Sorry, that one's already booked.",
      'Let me check and confirm in a few minutes.',
    ],
    book_venue: [
      "Go ahead and book it — I'll approve right away.",
      'That hour is taken. The next one is open.',
      'Which day and time do you want?',
    ],
    my_bookings: [
      'Your booking is confirmed — see you then.',
      "It's still pending, I'll approve it shortly.",
      'Show your QR code at the gate to check in.',
    ],
    cancel_booking: [
      "No problem, cancel it from the app and I'll process it.",
      'Cancelling this close forfeits the deposit, per the app policy.',
      'Want to move to another slot instead?',
    ],
    venue_info: [
      '{venue} has floodlights, parking and changing rooms.',
      'Full details and photos are on the venue page.',
      'Anything specific you want to know?',
    ],
    refund_policy: [
      'Cancel outside the window and the deposit comes back in full.',
      'The deposit is released once you check in.',
      "I'll confirm the exact amount and let you know.",
    ],
    contact_owner: [
      "I'm here — what do you need?",
      'You can reach me on this chat any time.',
      'My number is on the venue page.',
    ],
    find_venue: [
      'We are at {venue} — the map is on the venue page.',
      'Tell me the area and I will point you to it.',
      'Parking is right at the gate.',
    ],
    greeting: ['Hello — how can I help?', 'Hi! What do you need?', 'Assalam-o-Alaikum!'],
    affirm: ['Done.', 'Noted, thanks.', 'Perfect, see you then.'],
    deny: ['No problem.', 'Understood.', 'Let me know if that changes.'],
  },
  player: {
    check_availability: [
      'Is that slot still free?',
      'That time works for me.',
      'Can we do an hour later?',
    ],
    book_venue: ['I want to book it.', 'Booking it now.', 'Hold it for me please.'],
    my_bookings: ['Is my booking confirmed?', 'On my way.', 'Can you confirm the timing?'],
    cancel_booking: [
      'I need to cancel, sorry.',
      'Can I move it to another day?',
      'Will I get the deposit back?',
    ],
    venue_info: ['Do you have floodlights?', 'Is there parking?', 'What size is the ground?'],
    refund_policy: [
      'What happens to my deposit if I cancel?',
      'Is the deposit refundable?',
      'When do I get the refund?',
    ],
    contact_owner: ['Can you call me?', 'Please confirm here.', 'What is your number?'],
    find_venue: ['Where exactly is the ground?', 'Can you share the location?', 'Which gate?'],
    greeting: ['Hello!', 'Hi there!', 'Assalam-o-Alaikum!'],
    affirm: ['Yes, please.', 'Confirmed.', 'Sounds good.'],
    deny: ['No thanks.', 'Not that one.', 'Maybe later.'],
  },
  // The coordination room. Both sides are captains of opposing teams, so the
  // useful replies are about the fixture, not about the venue — and they read
  // identically to either team, because one room holds both.
  captain: {
    check_availability: ['That time works for us.', 'Can we start 30 minutes later?', 'Confirmed.'],
    book_venue: ['We will book the ground.', 'Can you book it?', 'Already booked.'],
    my_bookings: ['Booking is done.', 'Sharing the booking details now.', 'Which venue?'],
    find_players: ['We are 11.', 'We are short two players.', 'Bringing a full squad.'],
    find_opponents: ['We are in.', 'Good game.', 'Rematch soon?'],
    team_stats: ['Good game.', 'Well played.', 'Rematch soon?'],
    greeting: ['Hello!', 'Ready for the match?', 'Assalam-o-Alaikum!'],
    affirm: ['Confirmed.', 'Agreed.', 'See you there.'],
    deny: ['That does not work for us.', 'Sorry, cannot make it.', 'Can we reschedule?'],
  },
};

/** The three replies to fall back on when the intent has no entry, or none was found. */
const GENERIC = {
  owner: ['Yes, that works.', 'Let me check and confirm.', 'Please call me to confirm.'],
  player: ['Okay, thanks.', 'Can you confirm please?', 'One more question.'],
  captain: ['Confirmed.', 'Let me check with the team.', 'See you there.'],
};

/**
 * The down-path. When ml-service is unreachable the endpoint must still be
 * useful, so a tiny keyword table stands in — the same discipline every other
 * model call in this codebase follows (mlClient never throws; callers degrade).
 * Deliberately small: it covers the words that appear in a booking
 * chat, and anything it misses gets the generic set, which is still three
 * sendable sentences.
 */
const LEXICON = [
  [/\b(free|available|khali|slot)\b/i, 'check_availability'],
  [/\b(book|booking|karwa|karado|reserve)\b/i, 'book_venue'],
  [/\b(cancel|cancell?ation|mansookh)\b/i, 'cancel_booking'],
  [/\b(refund|deposit|paisay|paise|wapas)\b/i, 'refund_policy'],
  [/\b(where|kahan|location|address|map|gate)\b/i, 'find_venue'],
  [/\b(floodlight|light|parking|ground|pitch|size|facility)\b/i, 'venue_info'],
  [/\b(call|number|contact|baat)\b/i, 'contact_owner'],
  [/\b(confirm|confirmed|status|meri booking|my booking)\b/i, 'my_bookings'],
  [/\b(players?|khilari|kitne log)\b/i, 'find_players'],
  [/^(hi|hello|hey|salam|assalam|aoa)\b/i, 'greeting'],
  [/^(ok|okay|yes|haan|han|ji|theek|sahi|done)\b/i, 'affirm'],
  [/^(no|nahi|nahin|nope)\b/i, 'deny'],
];

function lexiconIntent(text) {
  const t = String(text || '');
  for (const [re, intent] of LEXICON) if (re.test(t)) return intent;
  return null;
}

/**
 * A finer layer than the 23-label classifier, for the handful of conversational
 * turns that have one natural answer the topic alone cannot choose.
 *
 * Model #4 is the right granularity for "this message is about availability", but
 * too coarse for a courtesy or a direct question: it maps a salam and a "hi" to the
 * same `greeting` label, so the topic cannot tell that one is answered with "Wa
 * Alaikum Assalam" and the other with "Hello". This reads the words instead, and it
 * is still a table — matched, never generated, the same discipline as the rest of
 * the file — so nothing here can invent a price, a slot or a policy.
 *
 * It fires only on a confident, specific shape and returns null otherwise, so an
 * availability, refund or squad-size question falls straight through to the intent
 * table untouched. The match-coordination turns (who is coming, what time) are
 * gated to the captain/team audience, where "are you free?" means "can you play?"
 * and not "is the slot open?".
 */
function conversationalReply(text, audience) {
  const t = String(text || '').trim();
  if (!t) return null;
  const lower = t.toLowerCase();
  // A salam is matched on its stems rather than one compiled pattern: "salam",
  // "salaam", "assalam o alaikum" and the "slm"/"aoa" shortcuts all have to land,
  // and the words around them ("Assalamualaikum bhai") must not matter.
  const isSalam = lower.includes('salam') || lower.includes('salaa')
    || lower.includes('slm') || lower.includes('aoa') || lower.includes('assalam');
  if (isSalam) {
    return ['Wa Alaikum Assalam', 'Wa Alaikum Assalam! How are you?', 'Walaikum Assalam, kaise ho?'];
  }
  if (/\b(thank\s*you|thanks|thankyou|shukriya|shukria|jazak\s*allah)\b/i.test(t)) {
    return ['You are welcome!', 'No problem at all.', 'Anytime!'];
  }
  // Coordinating a fixture only makes sense between team-mates and captains.
  if (audience === 'captain') {
    const isTimeQuestion = lower.includes('what time') || lower.includes('kitne baj')
      || lower.includes('kitna baj') || lower.includes('kis waqt')
      || lower.includes('time kya') || lower.includes('kab khel')
      || lower.includes('kab shuru');
    if (isTimeQuestion) {
      return ['Let us start at 8 PM.', 'Whatever time suits everyone.', 'I will confirm the time shortly.'];
    }
    // A yes/no "are you turning up?", guarded against the count question
    // ("kitne log aa rahe hain?") that looks similar but wants a number, not a yes.
    if (/\?/.test(t)
        && !/\b(kitne|kitna|kitni|how\s*many|kaun)\b/i.test(t)
        && /\b(are\s*you|will\s*you|can\s*you|aao?ge|aa\s*rahe\s*ho|khelo?\s*ge|coming|available|free|ready|interested|joining)\b/i.test(t)) {
      return ['Yes, I will be there.', 'Not sure yet, I will confirm.', 'Sorry, I can not make it.'];
    }
  }
  return null;
}

/**
 * Who AM I in this room decides the wording — not the app role alone. A captain
 * room is its own audience whatever the two people do elsewhere in the app; in a
 * booking room the venue owner and the player need opposite halves of the same
 * conversation. A team room shares the captain set: the questions asked there
 * are about squad and timing, which is exactly what that table answers.
 */
function audienceFor({ channelType, userRole }) {
  if (channelType === 'captain' || channelType === 'team') return 'captain';
  return userRole === 'owner' ? 'owner' : 'player';
}

/**
 * Which text the suggestion is a reply to.
 *
 * `messageId` is the normal path: the client passes the last message it rendered
 * from the other side and never has to re-send its text, so the suggestion is
 * always computed from the row the server has. `text` exists for the
 * composer-side case ("what could I say to this?") and for the check script.
 */
async function resolveSourceText(client, { channel, userId, text, messageId }) {
  let t = typeof text === 'string' ? text.trim() : '';
  if (!t && messageId) {
    if (!access.isUuid(messageId)) return { error: { status: 400, message: 'messageId must be a uuid.' } };
    const { rows } = await client.query(
      `SELECT body, sender_id FROM chat_messages
        WHERE id = $1 AND channel_id = $2 AND deleted_at IS NULL AND kind = 'text'`,
      [messageId, channel.id],
    );
    if (!rows[0]) return { error: { status: 404, message: 'That message is not in this chat.' } };
    // Suggesting a reply to the caller's own message is a bug, not a feature.
    if (String(rows[0].sender_id) === String(userId)) {
      return { error: { status: 400, message: 'Quick replies are for a message from the other side.' } };
    }
    t = String(rows[0].body || '').trim();
  }
  if (!t) return { error: { status: 400, message: 'Send either text or messageId.' } };
  // 500 chars is well past anything the classifier needs and stops a 4 KB
  // paragraph from becoming a model round trip.
  return { text: t.length > 500 ? t.slice(0, 500) : t };
}

/**
 * The two facts a canned reply is allowed to contain, read from the booking this
 * room points at. Both are read, never guessed; a room that is not a booking room
 * gets nulls and the placeholders degrade to 'the venue' / 'the listed rate'.
 */
async function bookingFacts(client, channel) {
  if (!channel || channel.type !== 'booking' || !channel.ref_id) return { venue: null, price: null };
  const { rows } = await client.query(
    `SELECT v.name, b.base_price FROM bookings b
       JOIN venues v ON v.id = b.venue_id WHERE b.id = $1`,
    [channel.ref_id],
  );
  if (!rows[0]) return { venue: null, price: null };
  // base_price is numeric -> a string out of pg. Number() first, per the money rule.
  return {
    venue: rows[0].name || null,
    price: rows[0].base_price === null ? null : Number(rows[0].base_price),
  };
}

/** '{venue} at {price}' -> the real name and rate, or a safe generic phrase. */
function filler({ venue, price }) {
  return (s) => String(s)
    .replace(/\{venue\}/g, venue || 'the venue')
    .replace(/\{price\}/g, price === null || price === undefined ? 'the listed rate' : `PKR ${price}`);
}

/**
 * The whole endpoint, minus Express. Returns `{error:{status,message}}` or
 * `{data:{…}}` so the route is a five-line adapter and the check script can call
 * this directly with its own transaction client.
 */
async function suggestFor(client, { channel, userId, userRole, text, messageId }) {
  const src = await resolveSourceText(client, { channel, userId, text, messageId });
  if (src.error) return src;

  const audience = audienceFor({ channelType: channel.type, userRole });

  const nlu = await mlClient.parseNlu(src.text, { sessionId: `qr:${channel.id}` });
  let source = nlu && nlu.available ? 'model' : 'unavailable';
  // An abstention is the model saying "I am not confident enough", and the honest
  // move is the keyword table, not its low-confidence guess.
  let intent = (nlu && nlu.available && !nlu.abstained) ? nlu.intent : null;
  if (!intent) {
    const guess = lexiconIntent(src.text);
    if (guess) { intent = guess; source = 'lexicon'; }
  }

  const fill = filler(await bookingFacts(client, channel));
  const table = QUICK_REPLIES[audience] || {};
  // A specific conversational turn (a salam, a "what time?", a "are you coming?")
  // answers itself better than its topic does, and takes precedence when it fires.
  // The source still reflects how the MESSAGE was understood — the model, the
  // keyword table, or neither — because the reply text being chosen by a rule does
  // not make a model-classified message any less model-classified.
  const convo = conversationalReply(src.text, audience);
  const picked = convo || (intent && table[intent]) || GENERIC[audience] || GENERIC.player;

  return {
    data: {
      suggestions: picked.slice(0, 3).map((t) => ({ text: fill(t), intent: intent || null })),
      intent: intent || null,
      confidence: nlu && nlu.available ? nlu.confidence : 0,
      audience,
      source,
      modelVersion: (nlu && nlu.modelVersion) || null,
      // Says out loud that nothing was sent, so a client author cannot mistake
      // this for an action endpoint.
      advisory: true,
    },
  };
}

module.exports = {
  QUICK_REPLIES, GENERIC, LEXICON,
  lexiconIntent, conversationalReply, audienceFor, resolveSourceText, bookingFacts, filler, suggestFor,
};
