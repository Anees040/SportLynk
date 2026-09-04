/**
 * dialogManager.js — one turn of conversation, start to finish.
 *
 * Why this file exists
 * The spec asks for a slot-filling state machine. This is it, and it is the
 * only place that decides what a turn means. `assistantActions.js` decides what a
 * meaning does; `routes/assistant.js` is transport. Three files, three jobs, and
 * the reason for the split is that every one of the questions below has exactly one
 * right answer per turn and a second opinion is a bug:
 *
 *   - was this a sentence or a button?  A chip carries its own action and never
 *     reaches the classifier, so chip traffic can never flatter model #4's measured
 *     accuracy (assistant_turns.input_mode splits them for exactly this reason).
 *   - is this an answer to what Scout just asked?  "kal" is not a request; it is
 *     the missing `date` of the booking already in progress.
 *   - is this an affirmation?  Money moves on "haan", and that decision is made by
 *     a frozen lexicon in this file, never by a probability. See AFFIRM below.
 *   - and if the model could not place the sentence, which of the five abstain
 *     reasons was it — because "I could not reach the parser" and "I do not know
 *     those words" are different apologies, and one of them is the server's fault.
 *
 * It is the only writer of session_state
 * Actions return a state patch, they never persist one, and the route never touches
 * state at all. So the whole lifecycle of a conversation is readable in `handleTurn`
 * below: read, merge, act, save, once per turn, in that order.
 *
 * The NLU call happens before the transaction opens
 * Deliberate. `POST /nlu/parse` is an HTTP round trip to another process, and doing
 * it with a pg client checked out would hold a Supabase connection open for the
 * length of someone else's cold start. Parse first, then open the transaction that
 * writes the two messages, the state and the telemetry row as one unit.
 */
const pool = require('../db/pool');
const ml = require('./mlClient');
const threads = require('./assistantThreads');
const actions = require('./assistantActions');
const kb = require('./assistantKb');
const settingsUtil = require('../utils/globalSettings');
const {
  SOURCES, CAPABILITIES, reply, menu, chip,
} = require('../utils/assistantReply');

/**
 * The affirmation LEXICON — the two words model #4 is not allowed to decide.
 *
 * `affirm` and `deny` are trained labels, and they are the two the classifier must
 * not be trusted with, because the door they open is `EXECUTORS`: a wallet debit and
 * an escrow hold, or a cancellation with a real refund. A 0.51 confidence is a fine
 * basis for showing a list of grounds and a terrible one for charging PKR 1,600.
 *
 * So a frozen list decides it. It is Roman Urdu first because that is how the users
 * in the demo answer a yes/no question in this app, and every surface
 * below was written down from how people type, not from a dictionary:
 * elongation ("haannn"), the "j" spellings of ji, the bare verb ("karo", "kar do"),
 * and the English that Pakistani chat mixes in mid-sentence.
 *
 * Held to whole utterances only — see `verdictOf`. "haan lekin 7 baje" contains an
 * affirmation and a correction, and treating it as a yes would book the wrong hour.
 */
const AFFIRM = Object.freeze([
  'haan', 'han', 'haa', 'ha', 'hn', 'hanji', 'haanji', 'ji', 'jee', 'jeehan', 'jihan',
  'yes', 'yeah', 'yea', 'yep', 'yup', 'ya', 'yah', 'sure', 'ok', 'oke', 'okay', 'okey', 'k',
  'theek', 'thik', 'teek', 'sahi', 'bilkul', 'zaroor', 'acha', 'accha', 'achha', 'chalo',
  'karo', 'kardo', 'kar', 'krdo', 'kro', 'lelo', 'lo', 'confirm', 'confirmed', 'done',
  'go', 'proceed', 'book', 'bookkaro', 'yesplease', 'pakka', 'right', 'correct', 'fine',
  'hojaye', 'hojao', 'hogaya', 'agreed', 'affirmative', 'sounds', 'good',
]);

/** The same list for "no". `cancel` is here and is a chip label; see verdictOf. */
const DENY = Object.freeze([
  'nahi', 'nahin', 'nai', 'nae', 'nah', 'na', 'nhi', 'no', 'nope', 'never', 'negative',
  'ruko', 'rukho', 'rok', 'rokdo', 'chordo', 'chhoddo', 'chhordo', 'rehnedo',
  'mat', 'matkaro', 'nahikarna', 'baadmein', 'baad', 'later', 'wait', 'skip', 'stop',
  'cancel', 'cancelkaro', 'nevermind', 'nvm', 'dont', 'abhinahi',
]);

const AFFIRM_SET = new Set(AFFIRM);
const DENY_SET = new Set(DENY);

/** Words that carry no decision, so an utterance made only of these plus a yes
 *  still counts as a yes: "haan bhai please". */
const FILLER = new Set([
  'bhai', 'yaar', 'yar', 'boss', 'sir', 'please', 'plz', 'pls', 'scout', 'ap', 'aap',
  'tum', 'to', 'toh', 'hi', 'hai', 'hain', 'he', 'it', 'that', 'this', 'me', 'my',
  'kar', 'karo', 'do', 'dain', 'den', 'jao', 'ahead', 'i', 'am', 'a', 'the', 'thanks', 'shukriya',
]);

/**
 * `pending` → the slot that answers it.
 *
 * When Scout asked "Which day at Rawal?" the next thing the user types is an answer,
 * not a new request, and the classifier has no way to know that: "kal" on its own is
 * out_of_scope to any intent model and correctly so. This table is what turns it back
 * into the missing `date` of the booking already in flight.
 */
const PENDING_SLOT = Object.freeze({
  venue: 'venueId',
  date: 'date',
  slot: 'slotId',
  booking: 'bookingId',
  team: 'teamId',
  question: 'question',
});

/**
 * Slots that are a DECISION about one row, not a search preference.
 *
 * `sport`, `date`, `area` and `budget` are worth carrying across a change of subject
 * — a user who said "cricket in DHA" means it for the next question too. A `slotId`
 * is not: carrying one into a new booking would put a confirm card in front of a slot
 * the user chose ten turns ago and has forgotten. So these are dropped the moment the
 * subject changes.
 */
const DECISION_SLOTS = Object.freeze(['slotId', 'bookingId', 'tournamentId',
  'question', 'offset', 'n']);

/** The four fsm_state values migration 018 allows, and what each one means. */
const FSM = Object.freeze({
  IDLE: 'idle',                       // nothing in flight; the next turn starts fresh
  SLOT_FILLING: 'slot_filling',       // Scout asked for a value the user must TYPE
  AWAITING_CHOICE: 'awaiting_choice', // Scout asked the user to TAP one of a list
  AWAITING_CONFIRM: 'awaiting_confirm', // a confirm card is on screen; money is next
});

/** `pending` values answered by tapping rather than typing. */
const TAP_PENDING = new Set(['venue', 'slot', 'booking', 'team']);

/** How many turns of history an action may see. Six is three exchanges. */
const HISTORY_TURNS = 6;

const nowMs = () => Date.now();

/** Collapse an utterance to comparable words: lowercase, no punctuation, no
 *  elongation ("haannn" → "haan"), no spaces inside a two-word verb ("kar do"). */
function words(text) {
  return String(text == null ? '' : text)
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s]/gu, ' ')
    .replace(/(.)\1{2,}/gu, '$1')
    .split(/\s+/)
    .filter(Boolean);
}

/**
 * Is this whole utterance a yes, a no, or neither?
 *
 * Whole is the load-bearing word. A sentence that contains a yes and anything with
 * meaning is not a yes — "haan lekin 7 baje" is a correction, and answering it with
 * "booked" would charge for the wrong hour. So every word must be an affirmation, a
 * filler, or a repeat of the same decision; one unknown word and this returns null
 * and the sentence goes to the classifier like any other.
 *
 * Mixed signals ("haan nahi") also return null, on the same principle: ask again.
 */
function verdictOf(text) {
  const w = words(text);
  if (!w.length || w.length > 6) return null;
  const joined = w.join('');
  if (AFFIRM_SET.has(joined)) return 'affirm';
  if (DENY_SET.has(joined)) return 'deny';
  let yes = 0;
  let no = 0;
  for (const t of w) {
    if (AFFIRM_SET.has(t)) yes += 1;
    else if (DENY_SET.has(t)) no += 1;
    else if (!FILLER.has(t)) return null;
  }
  if (yes && !no) return 'affirm';
  if (no && !yes) return 'deny';
  return null;
}

/**
 * Every slot key an action reads, and therefore every key a chip is allowed to set.
 *
 * A chip's `args` come from the client, so they are treated as input rather than as
 * something this file wrote earlier: an unknown key is dropped instead of being written into
 * `session_state`, which keeps a looping client from growing the jsonb without bound
 * and keeps the state readable when something goes wrong at 2am.
 */
const SLOT_KEYS = Object.freeze([
  'sport', 'date', 'time', 'area', 'city', 'locality', 'budget', 'sort', 'offset',
  'venueId', 'venueName', 'slotId', 'bookingId', 'teamId', 'teamName', 'tournamentId',
  'q', 'opponentName', 'status', 'topic', 'question', 'name', 'n', 'minRating',
  // `screen` is a navigation hint, not a search preference: it rides on the
  // deep-link chips ("Open team", "Open wallet") so that a client which posts one
  // back instead of routing locally still gets a useful answer out of app_help.
  'screen',
]);
const SLOT_KEY_SET = new Set(SLOT_KEYS);

/** Numeric slots, kept as numbers so `slots.budget || null` cannot become "0". */
const NUMERIC_SLOTS = new Set(['budget', 'offset', 'n', 'minRating']);

/** Longest a slot value may be. A question is prose; the rest are ids and words. */
const SLOT_MAX_CHARS = 400;

/** Keep the known keys, coerce, trim, and drop what carries nothing. */
function cleanSlots(raw) {
  const out = {};
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return out;
  for (const [key, value] of Object.entries(raw)) {
    if (!SLOT_KEY_SET.has(key)) continue;
    if (value === null || value === undefined || value === '') continue;
    if (NUMERIC_SLOTS.has(key)) {
      const n = Number(value);
      if (Number.isFinite(n)) out[key] = n;
      continue;
    }
    const s = String(value).replace(/\s+/g, ' ').trim().slice(0, SLOT_MAX_CHARS);
    if (s) out[key] = s;
  }
  return out;
}

/** "dha phase 5" → "Dha Phase 5". The gazetteer works in lowercase; a reply does not. */
function titleCase(s) {
  return String(s || '').replace(/\b\p{L}/gu, (c) => c.toUpperCase());
}

/**
 * NLU entities → slots. The shape differs per slot, on purpose, in Python.
 *
 * `entities.<key>` is an object or null, and each one names its value differently
 * because each one carries different evidence: a date has an `iso` and maybe an
 * `endIso`, a time has `start`/`end` minutes formatted as HH:MM, a sport has a canon
 * `value` plus an optional `variant` (tapeball vs hardball), an area has both an
 * `area` and a `city`, and a budget has an `op` that says whether the number is a
 * ceiling, a floor, or a vague "around 2000". Reading `.value` off all five — the
 * obvious guess — would silently drop four of them.
 *
 * Two mappings are judgement calls, not translation:
 *
 *   - city vs locality. `searchVenues` filters `city ILIKE`, and "DHA" is not a city;
 *     matching it against `city` finds nothing while the ground sits in Lahore with
 *     "DHA Phase 5" in its address. So a city goes to `area` (the city filter the rest
 *     of the codebase already calls that) and a neighbourhood goes to `locality`,
 *     which findVenue passes as the free-text term that searches the address.
 *   - "SASTA" has no number. A qualitative budget cannot become a maxPrice, so it
 *     becomes `sort: 'price_low'` instead — cheapest first is what the user meant, and
 *     an invented ceiling would hide grounds they would have taken.
 */
function slotsFromEntities(entities) {
  const out = {};
  const e = entities || {};
  if (e.date && e.date.iso) out.date = String(e.date.iso);
  if (e.time && e.time.start) out.time = String(e.time.start);
  if (e.sport && e.sport.value) out.sport = String(e.sport.value);
  if (e.area) {
    if (e.area.city) out.area = titleCase(e.area.city);
    if (e.area.area) out.locality = titleCase(e.area.area);
  }
  if (e.budget) {
    const cap = Number(e.budget.max);
    const about = Number(e.budget.amount);
    if (Number.isFinite(cap)) out.budget = cap;
    else if (e.budget.op === 'about' && Number.isFinite(about)) out.budget = about;
    else if (e.budget.op === 'qualitative') out.sort = 'price_low';
  }
  return out;
}

/** An id and its label travel together: a new id makes the old label a lie. */
const PAIRED = Object.freeze([['venueId', 'venueName'], ['teamId', 'teamName']]);

/**
 * Merge what the user just said over what the conversation already knew.
 *
 * New wins, which is the whole reason a correction works: "actually 7pm" replaces the
 * 6pm already in the slot rather than being ignored as "already filled".
 *
 * `keepDecisions` is false when the subject changed — see DECISION_SLOTS. And a new
 * id drops the old id's label, because `{venueId: B, venueName: 'Rawal'}` is how a
 * confirm card ends up naming the wrong ground.
 */
function mergeSlots(prev, incoming, { keepDecisions = true } = {}) {
  const base = cleanSlots(prev);
  const next = cleanSlots(incoming);
  if (!keepDecisions) for (const key of DECISION_SLOTS) delete base[key];
  for (const [id, label] of PAIRED) {
    if (next[id] && base[id] && String(next[id]) !== String(base[id])) delete base[label];
  }
  return { ...base, ...next };
}

/** What the telemetry row records as the machine's position after this turn. */
function fsmStateOf(state) {
  if (!state) return FSM.IDLE;
  if (state.confirm && state.confirm.action) return FSM.AWAITING_CONFIRM;
  if (state.pending) return TAP_PENDING.has(state.pending) ? FSM.AWAITING_CHOICE : FSM.SLOT_FILLING;
  return FSM.IDLE;
}

/** The human label for an intent, so a "did you mean" chip reads like a button. */
function labelFor(intent) {
  const hit = CAPABILITIES.find((c) => c.action === intent);
  return hit ? hit.label : null;
}

/** Intents a guess chip must never offer: two are gates, one is the failure itself. */
const NOT_A_GUESS = new Set(['affirm', 'deny', 'out_of_scope', 'greeting']);

/**
 * "Did you mean" — the runner-up intents, as buttons.
 *
 * `alternatives` is the classifier's own ranking below the winner, so on a
 * low-confidence turn the second and third guesses are the best recovery available
 * and they cost the user one tap instead of a rephrase. Only routable, nameable
 * intents survive the filter: a chip whose action nothing executes is worse than no
 * chip at all.
 */
function guessChips(alternatives = []) {
  const out = [];
  for (const alt of alternatives) {
    if (!alt || NOT_A_GUESS.has(alt.intent) || !actions.isAction(alt.intent)) continue;
    const label = labelFor(alt.intent);
    if (!label) continue;
    out.push(chip(label, alt.intent));
    if (out.length === 3) break;
  }
  return out;
}

/**
 * The slots already extracted, as a button.
 *
 * The entity extractor is deterministic and runs beside the classifier, not inside
 * it, so an abstained turn can still be holding a perfectly parsed "football,
 * Islamabad, tomorrow 6pm". Printing a help menu and dropping that on the floor
 * wastes work the user already did -- so offer it back as a chip.
 *
 * This is deliberately not an override. A chip carries its own `{action, args}`, so
 * tapping it re-enters `decide()` through the chip door and the classifier's
 * abstention stands: the model was unsure, the reply said so, and the user decided. A rule
 * that quietly promoted a 0.36 guess to an action would be the other thing, and
 * money-adjacent flows are exactly why this codebase does not do that.
 *
 * Requires a sport or a place. Date and time alone must not produce this chip --
 * "kal shaam" is the utterance the model is right to abstain on, and offering a
 * venue search for a bare "tomorrow evening" would be inventing the intent that the
 * abstention declined to invent.
 */
function slotSearchChip(slots) {
  const s = cleanSlots(slots || {});
  const where = s.locality || s.area || null;
  if (!s.sport && !where) return null;

  const args = {};
  for (const key of ['sport', 'area', 'locality', 'date', 'time', 'budget', 'sort']) {
    if (s[key] !== undefined) args[key] = s[key];
  }

  let label;
  if (s.sport && where) label = `${titleCase(s.sport)} in ${where}`;
  else if (s.sport) label = `${titleCase(s.sport)} grounds`;
  else label = `Grounds in ${where}`;
  // Append only what still fits: chip() truncates at 40, and a label chopped
  // mid-word ("...Sat 30 Ag") reads like a bug. Whatever the label omits is still
  // in `args`, so the search itself keeps the full date and time either way.
  for (const extra of [s.date ? actions.day(s.date) : null,
    s.time ? actions.clock(s.time) : null]) {
    if (extra && `${label}, ${extra}`.length <= 40) label = `${label}, ${extra}`;
  }
  return chip(label, 'find_venue', args);
}

/**
 * The apology, chosen by why the model did not answer. Five reasons, three of them
 * the model's own and two of them the server's, and they do not deserve the same sentence:
 *
 *   low_confidence  — it heard words it knows but is not sure enough to act. The
 *                     runner-up intents become buttons, which is the cheapest fix.
 *   no_evidence     — nothing in the sentence pointed at anything SportLynk does.
 *   no_known_terms  — not one word was in the vocabulary; usually another language.
 *   nlu_unavailable — the parser is unreachable. Say so plainly rather than blaming
 *                     the sentence; every button still works, because chips carry
 *                     their own action and never touch the classifier.
 *   text_too_long   — refused before the call; the parser has a hard char limit.
 *
 * Every branch returns the capability menu, so ER2.6's "friendly help menu on low
 * confidence" holds for all five and no reply is ever text alone.
 */
function abstainReply({ reason, alternatives = [], name = 'Scout', slotChip = null }) {
  // Mutating the built payload rather than assembling a second one: menu() is the
  // only place the capability card is built, and it must stay that way. One helper
  // so no branch can forget the lead chips -- the slot chip goes first on all five
  // reasons, because when the parser got something concrete, the most useful button
  // is the one that uses it, and that is as true when the parser is unreachable as when
  // merely hesitated.
  const withChips = (out, extras = []) => {
    const lead = [slotChip, ...extras].filter(Boolean);
    if (lead.length) out.chips = [...lead, ...out.chips].slice(0, 6);
    return out;
  };
  if (reason === ml.NLU_ABSTAIN_UNAVAILABLE) {
    return withChips(menu(
      `I could not read that just now — my language model is not answering. `
      + `Every button below still works, so tap what you need and I will do it.`,
      { name },
    ));
  }
  if (reason === ml.NLU_ABSTAIN_TOO_LONG) {
    return withChips(menu(
      'That is a lot for one message. Say the main thing in a sentence and I will take it from there.',
      { name },
    ));
  }
  if (reason === ml.NLU_ABSTAIN_LOW_CONFIDENCE) {
    return withChips(
      menu('I am not sure I got that. Did you mean one of these?', { name }),
      guessChips(alternatives),
    );
  }
  if (reason === ml.NLU_ABSTAIN_NO_KNOWN_TERMS) {
    return withChips(menu(
      `I did not recognise any of those words. I am ${name} — I only know SportLynk. `
      + 'Here is what I can do:',
      { name },
    ));
  }
  return withChips(menu(null, { name }));
}

/**
 * An owner-taught answer, if one exists. The other half of the learning loop.
 *
 * `assistantKb` is filled by owners answering escalated questions, so the first
 * player to ask "is there parking at Rawal?" gets an escalation and the second gets
 * this — the same reply, instantly, with `source: 'kb'` so the provenance stays
 * honest. Tried on an abstain before the menu because a real answer beats a help
 * screen, and tried even when the model is down for the same reason.
 */
async function kbAnswer(client, { said, venueId = null }) {
  const found = await kb.search(client, { question: said, venueId: venueId || null });
  if (!found.hit || !found.row) return null;
  await kb.recordServed(client, found.row.id);
  return reply(found.row.answer, {
    source: SOURCES.KB,
    chips: [
      chip('Ask the owner', 'contact_owner', venueId ? { venueId } : null),
      chip('What can you do?', 'capability_menu'),
    ],
    meta: {
      kbId: found.row.id,
      scope: found.row.scope,
      similarity: Number(found.similarity) || 0,
      matcher: found.matcher,
    },
  });
}

/**
 * What did the user just do? — the one decision this file exists to make.
 *
 * Three doors, in this order, and the order is the design:
 *
 *   1. A chip. It carries its own action, so there is nothing to classify. This is
 *      why `navigate` and `find_players` were fully usable before model #4 had
 *      labels for them, and why a down parser leaves the app operable.
 *   2. The LEXICON. A whole-utterance yes or no is decided by AFFIRM/DENY above and
 *      the classifier is not consulted at all — not as an optimisation, but because
 *      these two answers gate money. A turn decided here records a NULL confidence
 *      and NULL model_version in assistant_turns, which keeps it out of the model's
 *      measured accuracy exactly as chip traffic is kept out.
 *   3. The MODEL. `parseNlu` never throws and never returns a partial object, so
 *      there is one shape to read whether ml-service answered, refused, or is down.
 *
 * The confidence floor is applied here rather than in Python. The model has its own
 * threshold baked into the artifact; `global_settings.assistant.confidence_floor`
 * lets an operator demand more certainty before Scout acts, on demo morning, without
 * a retrain. Only upward — lowering it below the model's own threshold does nothing,
 * because the model has already abstained by then.
 */
async function decide({ said, chipAction, chipArgs, settings, threadId }) {
  if (chipAction) {
    return { inputMode: 'chip', via: 'chip', intent: chipAction, nlu: null,
      confidence: null, abstained: false, abstainReason: null,
      incoming: cleanSlots(chipArgs), keepDecisions: true, nluMs: 0 };
  }

  const verdict = verdictOf(said);
  if (verdict) {
    return { inputMode: 'text', via: 'lexicon', intent: verdict, nlu: null,
      confidence: null, abstained: false, abstainReason: null,
      incoming: {}, keepDecisions: true, nluMs: 0 };
  }

  const nlu = await ml.parseNlu(said, { sessionId: threadId || null });
  const floor = Number(settings.confidenceFloor);
  const shy = !nlu.abstained && Number.isFinite(floor) && nlu.confidence < floor;
  const abstained = nlu.abstained || shy;
  return {
    inputMode: 'text',
    via: 'model',
    intent: abstained ? null : nlu.intent,
    nlu,
    confidence: nlu.available ? nlu.confidence : null,
    abstained,
    abstainReason: abstained
      ? (nlu.abstainReason || ml.NLU_ABSTAIN_LOW_CONFIDENCE)
      : null,
    incoming: slotsFromEntities(nlu.entities),
    keepDecisions: false,
    nluMs: Number.isFinite(Number(nlu.roundTripMs)) ? Number(nlu.roundTripMs) : null,
  };
}

/**
 * Is this an answer to what Scout just asked? — the slot-filling half of the machine.
 *
 * Without this, the state machine has a hole a demo walks straight into. Scout asks
 * "Which day at Rawal?", the user types "kal", and no intent model on earth calls a
 * bare adverb `book_venue` — it abstains, correctly. The booking would then die and
 * the user would get a help menu in answer to their own answer.
 *
 * So when something is pending and the model came back with nothing usable, the
 * pending intent is re-run instead. The entity extractor still ran (Python extracts
 * slots before it decides whether to abstain), so "kal" arrives here as a resolved
 * `date` and the booking moves on to the next question. Where nothing could be
 * extracted, the pending intent re-asks — three chips, not a dead end.
 *
 * Two narrow exceptions, both deliberate:
 *   - `pending: 'question'` swallows any text, confident or not. The user has already
 *     chosen to ask the owner; "is there parking?" classifying as venue_info would
 *     otherwise answer a question they did not ask and break the KB learning loop.
 *   - a typed answer to "which ground?" / "which team?" becomes a name to resolve,
 *     because those questions are normally answered by tapping and a user who types
 *     is still answering.
 *
 * A confident, different intent always wins. A user who abandons a half-built booking
 * to ask their wallet balance gets their balance.
 */
function continuationOf({ prior, said, decided }) {
  const pending = prior.pending ? String(prior.pending) : null;
  if (!pending || !PENDING_SLOT[pending]) return null;
  if (decided.inputMode === 'chip') return null;

  if (pending === 'question' && said) {
    return { intent: prior.intent || 'contact_owner', fill: { question: said } };
  }
  const usable = decided.intent && !decided.abstained && decided.intent !== 'out_of_scope';
  if (usable) return null;
  if (!prior.intent) return null;

  const slot = PENDING_SLOT[pending];
  const fill = {};
  if (!decided.incoming[slot] && said) {
    if (slot === 'venueId') fill.venueName = said;
    else if (slot === 'teamId') fill.teamName = said;
  }
  return { intent: prior.intent, fill };
}

/** One telemetry row per turn. Never the text — its length, and nothing else. */
async function recordTurn(client, row) {
  const { rows } = await client.query(
    `INSERT INTO assistant_turns
       (user_id, channel_id, input_mode, text_chars, intent, confidence, abstained,
        abstain_reason, model_version, action, action_ok, answer_source, fsm_state,
        nlu_ms, total_ms)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)
     RETURNING id`,
    [
      row.userId, row.channelId, row.inputMode, row.textChars,
      row.intent, row.confidence, row.abstained === true, row.abstainReason,
      row.modelVersion, row.action, row.actionOk, row.answerSource, row.fsmState,
      row.nluMs, row.totalMs,
    ],
  );
  return rows[0] ? String(rows[0].id) : null;
}

/** The shape every failure returns, so the route has one branch instead of five. */
function fail(status, code, message) {
  return { ok: false, status, code, message, reply: null, state: null };
}

/**
 * One turn, start to finish.
 *
 * @param {object}  input
 * @param {string}  input.userId    the JWT's user, never a body field
 * @param {string}  [input.threadId] the chat this belongs to; the newest one if omitted
 * @param {string}  [input.text]    what the user typed, or a tapped chip's label
 * @param {string}  [input.action]  a chip's action — set, and no classification happens
 * @param {object}  [input.args]    a chip's structured args, whitelisted by cleanSlots
 * @param {string}  [input.clientId] the client's idempotency key for the user message
 * @returns {Promise<object>} `{ok, status, code, message, threadId, reply, state, ...}`
 *
 * Order of operations, and why it is this order:
 *   read thread + state → classify (no DB connection held) → BEGIN → user message →
 *   act → scout message → save state → telemetry → COMMIT.
 *
 * Everything that touches the database is in one transaction, so a turn either
 * happened or it did not: no booking without the message that confirms it, and no
 * state saying "awaiting confirm" for a card the user never saw. The money calls
 * inside the actions take a SAVEPOINT rather than a nested transaction, which is what
 * lets `createBooking` fail on a lost race and still leave this turn commitable.
 */
async function handleTurn({
  userId, threadId = null, text = '', action = null, args = null,
  clientId = null, persona = 'player', client: injected = null,
} = {}) {
  const t0 = nowMs();
  const said = String(text == null ? '' : text).replace(/\s+/g, ' ').trim();
  const chipAction = String(action == null ? '' : action).trim();

  if (!userId) return fail(401, 'auth_required', 'Sign in to chat with Scout.');
  if (!said && !chipAction) return fail(400, 'empty_message', 'Say something and I will help.');
  if (chipAction && !actions.isAction(chipAction)) {
    // A chip the server cannot execute is an integration bug, not a conversation
    // problem, and hiding it behind a help menu is how it survives to demo day.
    return fail(400, 'unknown_action', `I have no action called "${chipAction}".`);
  }

  // `injected` is a caller-owned client, used by src/scripts/check_assistant.js so a
  // verification run can drive real turns -- real bookings, real ledger rows, real
  // telemetry -- inside a transaction it then rolls back, leaving the committee's
  // database exactly as it found it. The turn's own transaction becomes a SAVEPOINT
  // in that case, so a failing turn still rolls back only itself. Production never
  // passes it and takes the BEGIN/COMMIT path below.
  const runner = injected || pool;
  const TXN = injected
    ? { begin: 'SAVEPOINT scout_turn', commit: 'RELEASE SAVEPOINT scout_turn',
      rollback: 'ROLLBACK TO SAVEPOINT scout_turn' }
    : { begin: 'BEGIN', commit: 'COMMIT', rollback: 'ROLLBACK' };

  const got = await threads.getOrCreate(runner, { userId, threadId, persona });
  if (!got.ok) return fail(got.status || 404, got.code || 'thread_error', got.message);
  const thread = got.row;
  const prior = threads.readState(thread.session_state);
  const settings = await settingsUtil.assistant({});

  // Classify outside the transaction
  // parseNlu is an HTTP round trip to ml-service. Doing it after `pool.connect()`
  // would hold a Supabase connection for the length of someone else's network,
  // which is how a chat feature takes down the booking API under load.
  const decided = await decide({
    said, chipAction, chipArgs: args, settings, threadId: thread.id,
  });

  // Is this turn an answer to the question Scout asked last turn, rather than a new
  // request? continuationOf owns that judgement; see its comment for why a bare
  // "kal" cannot be classified but can still be understood.
  const cont = continuationOf({ prior, said, decided });
  const intent = cont ? cont.intent : decided.intent;
  const incoming = cont ? { ...decided.incoming, ...cont.fill } : decided.incoming;

  // Decisions (a chosen slot, a chosen booking) survive a follow-up that continues
  // the same errand, and are dropped the moment the user changes subject -- otherwise
  // "book something else" would confirm against the slot they picked ten turns ago.
  const keepDecisions = !!cont || decided.keepDecisions
    || (!!intent && intent === prior.intent);
  const slots = mergeSlots(prior.slots, incoming, { keepDecisions });

  // The confirm gate
  // An armed confirm block lives exactly one turn. Only these four inputs may fire
  // it: the Yes/No chips, or a whole-utterance affirm/deny from the frozen lexicon.
  // Anything else -- a new question, a correction, an unreadable message -- falls
  // through to the normal path, which clears `confirm` by not re-arming it. That is
  // what makes it impossible for yesterday's "haan" to buy today's slot.
  let actionKey = intent;
  let confirm = null;
  const armed = prior.confirm && prior.confirm.action ? prior.confirm : null;
  // Money is gated by the chip and the FROZEN LEXICON -- never by the MODEL.
  // model #4 labels "haan lekin 7 baje" affirm at 0.61, which is over its own
  // threshold: read as a yes, it books the 6pm the user was correcting. verdictOf
  // refuses that sentence on purpose (test/assistant.test.js S2), so the gate asks
  // where the affirm came from, not merely what it says.
  const decisive = decided.via === 'chip' || decided.via === 'lexicon';
  if (armed && (chipAction === 'confirm' || (!chipAction && decisive && intent === 'affirm'))) {
    actionKey = 'confirm'; confirm = armed;
  } else if (armed && (chipAction === 'cancel_confirm'
    || (!chipAction && decisive && intent === 'deny'))) {
    actionKey = 'cancel_confirm'; confirm = armed;
  } else if (armed && !chipAction && (intent === 'affirm' || intent === 'deny')) {
    // The model called it a yes/no and the lexicon did not, so the sentence carried
    // more than a yes. That is a correction, and the useful answer is neither the
    // booking nor "I am not holding anything to confirm": it is the same errand,
    // re-run with what the user just changed. `slotId` was already dropped by
    // mergeSlots (affirm != book_venue, so keepDecisions is false) while venueId and
    // date survived -- so "haan lekin 7 baje" reopens the same ground on the same
    // day at 7pm, and the confirm block dies unfired.
    actionKey = armed.action || prior.intent || intent;
  }

  const client = injected || await pool.connect();
  let payload = null;
  let out = null;
  let userMsgId = null;
  try {
    await client.query(TXN.begin);

    // The user's own bubble. For a chip turn the client echoes the chip's label as
    // `text` so the transcript reads like a conversation; if it did not, the
    // capability label is a truthful stand-in. Persisting nothing would leave two
    // Scout messages in a row with no visible reason.
    const echo = said || labelFor(chipAction) || null;
    if (echo) {
      const um = await threads.appendMessage(client, {
        threadId: thread.id, userId, who: 'user', text: echo, clientId,
      });
      if (um.ok && um.row) userMsgId = String(um.row.id);
    }

    if (!intent) {
      // Nothing to act on: the model abstained and no pending question caught it.
      // Before offering a menu, try the owner Q&A -- "is there parking?" is a real
      // question that no intent label covers, and the KB is where its answer lives.
      const topicHint = slots.venueId || prior.ctx.lastVenueId || null;
      payload = (decided.abstainReason !== ml.NLU_ABSTAIN_TOO_LONG && said
        ? await kbAnswer(client, { said, venueId: topicHint })
        : null)
        || abstainReply({
          reason: decided.abstainReason,
          alternatives: decided.nlu ? decided.nlu.alternatives : [],
          name: settings.name,
          // This turn's parse, not the merged slots: the chip must echo what the
          // user just typed. Merged slots would resurrect a search from six turns
          // ago on an unrelated unreadable message, which reads as Scout ignoring
          // the question it just admitted it could not read.
          slotChip: slotSearchChip(incoming),
        });
    } else {
      const fn = actions.ACTIONS[actionKey];
      if (typeof fn !== 'function') {
        // Only reachable if a retrain ships a label the Node side has no action for.
        // assertRoutable() guards against it at boot; this keeps the turn honest if
        // it ever slips through, rather than throwing a 500 at the user.
        payload = menu(`I know the words "${actionKey}" but I cannot do it yet.`,
          { name: settings.name });
      } else {
        out = await fn({
          client, userId, slots, confirm, text: said, settings,
          channelId: thread.id, messageId: userMsgId,
          intent, confidence: decided.confidence,
          // The previous turn's subject. Read-only context: it lets a bare "haan"
          // with nothing armed ask a specific question instead of a generic one.
          // No action may execute anything on the strength of it.
          lastIntent: prior.ctx.lastIntent || null,
        });
        payload = out && out.reply ? out.reply : menu(null, { name: settings.name });
      }
    }

    // Next state
    // An action returns a partial patch, and the two halves read opposite ways on
    // purpose:
    //   `intent`/`slots` -- absent means KEEP what this turn computed, because most
    //     actions have no opinion about them and re-stating them would be noise.
    //   `pending`/`confirm` -- absent means cleared, because a question and a confirm
    //     block are one-turn things. An action that wants either must say so, and
    //     forgetting to is a bug that ends the errand rather than one that loops it.
    const patch = out && out.state ? out.state : {};
    const nextSlots = cleanSlots('slots' in patch ? patch.slots : slots);
    const nextState = {
      v: threads.STATE_VERSION,
      intent: 'intent' in patch ? (patch.intent || null) : (intent || null),
      slots: nextSlots,
      pending: 'pending' in patch ? (patch.pending || null) : null,
      confirm: 'confirm' in patch ? (patch.confirm || null) : null,
      ctx: {
        // `lastVenueId` is what lets "is there parking?" three turns later know which
        // ground the question is about, so an owner Q&A hit can be venue-scoped.
        lastIntent: intent || prior.ctx.lastIntent || null,
        lastVenueId: nextSlots.venueId || prior.ctx.lastVenueId || null,
        turns: Number(prior.ctx.turns || 0) + 1,
      },
    };

    const sm = await threads.appendMessage(client, {
      threadId: thread.id, userId, who: 'scout',
      text: payload.text || 'Here is what I can do.', payload,
    });
    await threads.saveState(client, { threadId: thread.id, state: nextState });

    const turnId = await recordTurn(client, {
      userId, channelId: thread.id, inputMode: decided.inputMode,
      // Length of what the classifier was given, so a chip turn records none: there
      // was no utterance to measure. The text itself is never stored here.
      textChars: decided.inputMode === 'text' && said ? said.length : null,
      intent: intent || null, confidence: decided.confidence,
      abstained: decided.abstained, abstainReason: decided.abstainReason,
      modelVersion: decided.nlu ? decided.nlu.modelVersion : null,
      action: out ? actionKey : null,
      actionOk: out ? (payload.actionOk !== false) : null,
      answerSource: payload.source, fsmState: fsmStateOf(nextState),
      nluMs: decided.nluMs, totalMs: nowMs() - t0,
    });
    await client.query(TXN.commit);
    return {
      ok: true, status: 200, code: 'ok', message: null,
      threadId: String(thread.id), threadCreated: !!got.created,
      turnId, messageId: sm.ok && sm.row ? String(sm.row.id) : null,
      reply: payload, state: nextState,
      nlu: {
        intent: intent || null, confidence: decided.confidence, via: decided.via,
        abstained: decided.abstained, reason: decided.abstainReason,
        modelVersion: decided.nlu ? decided.nlu.modelVersion : null,
        ms: decided.nluMs,
      },
      totalMs: nowMs() - t0,
    };
  } catch (err) {
    await client.query(TXN.rollback).catch(() => {});
    // The turn is gone -- no messages, no state change, no booking. What must not be
    // lost is the fact that it failed, so one telemetry row goes in outside the
    // rolled-back transaction with answer_source NULL and action_ok false. Without it
    // a crashing action looks exactly like a quiet user in the metrics.
    try {
      await recordTurn(client, {
        userId, channelId: thread.id, inputMode: decided.inputMode,
        textChars: decided.inputMode === 'text' && said ? said.length : null,
        intent: intent || null, confidence: decided.confidence,
        abstained: decided.abstained, abstainReason: decided.abstainReason,
        modelVersion: decided.nlu ? decided.nlu.modelVersion : null,
        action: actionKey || null, actionOk: false, answerSource: null,
        fsmState: fsmStateOf(prior), nluMs: decided.nluMs, totalMs: nowMs() - t0,
      });
    } catch { /* telemetry must never mask the real error */ }
    return {
      ok: false, status: 500, code: 'turn_failed',
      // USE-3: the client gets a fixed sentence. `err.message` can carry SQL text
      // and constraint names, so it travels in `error` for the server log only.
      message: 'Scout could not finish that message.',
      threadId: String(thread.id), turnId: null, messageId: null,
      // A reply the route can still render, deliberately not persisted: the
      // transaction is rolled back, so it must not appear again on reload.
      reply: menu('Something went wrong on my side and I did not save that message. Try again, or use a button below.',
        { name: settings.name }),
      state: prior, error: err.message,
    };
  } finally {
    if (!injected) client.release();
  }
}

module.exports = {
  handleTurn,
  // The FSM's vocabulary, exported so routes and tests name states the same way the
  // telemetry column does rather than repeating string literals.
  FSM,
  PENDING_SLOT,
  SLOT_KEYS,
  HISTORY_TURNS,
  // Pure, and therefore unit-testable without a database or ml-service: these are
  // where the turn's decisions live, so this is where test/assistant.test.js
  // proves that "haan lekin 7 baje" does not buy anything.
  AFFIRM,
  DENY,
  words,
  verdictOf,
  cleanSlots,
  mergeSlots,
  slotsFromEntities,
  fsmStateOf,
  guessChips,
  slotSearchChip,
  abstainReply,
  labelFor,
  continuationOf,
};
