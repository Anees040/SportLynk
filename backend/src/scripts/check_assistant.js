/**
 * check_assistant.js — Scout, end to end, against the real database. Always rolled back.
 *
 * Usage:  node src/scripts/check_assistant.js          (ml-service must be running)
 *
 * WHY THIS SCRIPT EXISTS
 * ----------------------
 * test/assistant.test.js proves the DECISIONS: the lexicon, the slot merge, the card
 * shapes, the refund arithmetic. None of that touches a row, which is the point — it
 * runs with the database down. But the wave was asked for something working, and a
 * booking that the dialog manager builds correctly and the ledger records wrongly is
 * still a broken feature. So this script drives REAL turns through
 * services/dialogManager.handleTurn — real classification by model #4, real venue
 * search, a real booking, a real cancellation, a real escalation answered by a real
 * owner — and then asserts the rows.
 *
 * NOTHING SURVIVES IT
 * -------------------
 * handleTurn accepts a caller-owned `client`. Given one, its own BEGIN/COMMIT becomes
 * SAVEPOINT/RELEASE, so this script can hold ONE transaction open across a dozen
 * conversations and ROLLBACK at the end. The committee's database is left exactly as
 * it was found: no bookings, no wallet movement, no chat threads, no telemetry.
 * That is also why the assertions read the rows THEMSELVES rather than trusting the
 * reply text — the reply is the thing under test, not the evidence.
 *
 * WHAT A FAILURE MEANS
 * --------------------
 *   ✗  a rule broke. The line names it.
 *   ~  the seeded data could not supply the case (no free slot 24h out, no team with
 *      two members). Reported as a SKIP, not a pass — a check that never ran is not
 *      a check that passed, and the PASS line counts them separately.
 */
const fs = require('fs');
const path = require('path');
const pool = require('../db/pool');
const dialog = require('../services/dialogManager');
const actions = require('../services/assistantActions');
const threads = require('../services/assistantThreads');
const discovery = require('../services/discoveryService');
const roster = require('../services/rosterService');
const booking = require('../services/bookingService');
const kb = require('../services/assistantKb');
const ml = require('../services/mlClient');
const replyUtil = require('../utils/assistantReply');
const policyText = require('../utils/policyText');
const teamStats = require('../utils/teamStats');
const { POLICY, asNum, round2, depositFor } = require('../utils/escrow');
const evidence = require('./lib/evidence');

const failures = [];
const skips = [];
let passed = 0;

// Off unless --evidence is passed, and when off every method is a no-op -- which is why
// the harness below can call it unconditionally. See src/scripts/lib/evidence.js.
const ev = evidence.recorder({
  key: 'service',
  title: 'Block 1 -- the service layer, driven through `dialogManager.handleTurn`',
  subtitle: 'Real classification by model #4, a real booking, a real cancellation, a real escalation '
    + 'answered by a real owner, all inside ONE transaction that is rolled back at the end. Every '
    + 'assertion reads the ROWS rather than the reply text: the reply is the thing under test, not the '
    + 'evidence.',
  command: 'cd backend && node src/scripts/check_assistant.js --evidence',
});

function section(title) {
  ev.section(title);
  console.log(`\n── ${title} ${'─'.repeat(Math.max(0, 66 - title.length))}`);
}

function check(ok, label, detail = '') {
  if (ok) ev.pass(label); else ev.fail(label, detail);
  if (ok) { passed += 1; console.log(`  ✓ ${label}`); return true; }
  failures.push(label);
  console.log(`  ✗ ${label}${detail ? `  → ${detail}` : ''}`);
  return false;
}

function skip(label, why) {
  ev.skip(label, why);
  skips.push(label);
  console.log(`  ~ ${label}  (skipped: ${why})`);
  return false;
}

function eq(got, want, label) {
  return check(got === want, label, `got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
}

/**
 * Run a read that MIGHT fail without poisoning the outer transaction.
 *
 * Postgres aborts the whole transaction on any error, so one bad query would turn
 * every later check into "current transaction is aborted" and hide the real result.
 * A savepoint per probe keeps a failure local to that probe.
 */
async function probe(client, fn) {
  await client.query('SAVEPOINT probe');
  try {
    const out = await fn();
    await client.query('RELEASE SAVEPOINT probe');
    return { ok: true, out, err: null };
  } catch (err) {
    await client.query('ROLLBACK TO SAVEPOINT probe').catch(() => {});
    return { ok: false, out: null, err };
  }
}

// ════════════════════════════════════════════════════════════════════════════
// DRIVING SCOUT
// ════════════════════════════════════════════════════════════════════════════

/** Every turn this script drives, in order, for the transcript printed on failure. */
const transcript = [];

/**
 * One turn. `text` goes through model #4; `action`+`args` is a button tap.
 *
 * The turn runs on THIS script's client, so its writes join the outer transaction
 * and disappear with it. `quiet` keeps the transcript readable for the dozens of
 * setup turns whose text nobody needs to see.
 */
async function say(client, { userId, threadId = null, text = null, action = null, args = null, persona = 'player' }) {
  const out = await dialog.handleTurn({
    userId, threadId, text: text || '', action, args, persona, client,
  });
  const row = {
    said: text ? `"${text}"` : `[${action}]`,
    intent: out.nlu ? out.nlu.intent : null,
    conf: out.nlu && out.nlu.confidence != null ? Number(out.nlu.confidence).toFixed(2) : null,
    source: out.reply ? out.reply.source : null,
    said_back: out.reply ? String(out.reply.text || '').slice(0, 90) : out.message,
  };
  transcript.push(row);
  ev.turn(row);
  if (!out.ok) console.log(`     ! turn failed: ${out.error || out.message}`);
  return out;
}

/** Cards of one type from a reply, or [] — never a throw on a failed turn. */
const cardsOf = (out, type) => ((out && out.reply && out.reply.cards) || [])
  .filter((c) => c && c.type === type);

/** The first chip whose action matches, or null. */
const chipOf = (out, action) => ((out && out.reply && out.reply.chips) || [])
  .find((c) => c && c.action === action) || null;

/** Does the reply offer this action anywhere — chip or card button? */
function offers(out, action) {
  if (chipOf(out, action)) return true;
  return ((out && out.reply && out.reply.cards) || []).some((c) => {
    const b = c && c.data && (c.data.buttons || c.data.chips);
    return Array.isArray(b) && b.some((x) => x && x.action === action);
  });
}

// ════════════════════════════════════════════════════════════════════════════
// FIXTURES — chosen from the seeded data, never created
// ════════════════════════════════════════════════════════════════════════════

/**
 * Pick the cast: a player who captains a team and can afford a ground, a venue with
 * free slots TODAY in PKT, and that venue's owner.
 *
 * Chosen rather than inserted. A script that seeds its own perfect row proves only
 * that it can seed a row; the committee's demo runs on THIS data, so the checks run
 * on it too — and when it cannot supply a case, that is a skip with a named reason.
 */
async function pickFixtures(client) {
  const now = discovery.pktNow();
  const { rows: vrows } = await client.query(
    `SELECT v.id, v.name, v.city, v.sport_type, v.owner_id, v.latitude, v.longitude,
            count(s.id)::int AS free_today, min(s.price)::numeric AS cheapest
       FROM venues v
       JOIN slots s ON s.venue_id = v.id
       LEFT JOIN owner_profiles op ON op.user_id = v.owner_id
      WHERE v.is_active AND s.status = 'available' AND s.price > 0
        AND s.slot_date = $1::date AND s.start_time > $2::time
        AND (s.locked_until IS NULL OR s.locked_until < NOW())
        AND (op.verification_status = 'approved' OR op.verification_status IS NULL)
        AND v.owner_id IS NOT NULL
      GROUP BY v.id
      ORDER BY count(s.id) DESC, min(s.price) ASC
      LIMIT 8`,
    [now.date, now.time],
  );
  // A player who is an ADMIN of a team unlocks find_players/find_opponents/team_stats
  // in the same run as the booking, and the wallet has to cover the cheapest slot of
  // the venue we are about to choose — otherwise the booking fails on funds and the
  // conversation under test never reaches the ledger.
  const { rows: prows } = await client.query(
    `SELECT u.id, u.name, w.balance,
            (SELECT count(*)::int FROM team_members m
              WHERE m.user_id = u.id AND m.role IN ('captain', 'vice_captain')) AS admin_of,
            (SELECT count(*)::int FROM team_members m WHERE m.user_id = u.id) AS teams
       FROM users u JOIN wallets w ON w.user_id = u.id
      WHERE u.role = 'player' AND u.is_active
      ORDER BY (SELECT count(*) FROM team_members m
                 WHERE m.user_id = u.id AND m.role IN ('captain', 'vice_captain')) DESC,
               w.balance DESC
      LIMIT 8`,
  );
  return { now, venues: vrows, players: prows };
}

/** Pair a player with a venue they can actually pay for. */
function castFrom({ venues, players }) {
  for (const p of players) {
    for (const v of venues) {
      if (asNum(p.balance) >= asNum(v.cheapest)) return { player: p, venue: v };
    }
  }
  return { player: players[0] || null, venue: venues[0] || null };
}

// ════════════════════════════════════════════════════════════════════════════
// 0 — PREFLIGHT
// ════════════════════════════════════════════════════════════════════════════

/**
 * Nothing below this line is worth running if the registry, the model or migration
 * 018 is not there. A missing intent label is a HARD stop: every later conversation
 * would fall back to the help menu and "the menu answered" is not a passing test.
 */
async function preflight(client) {
  section('0  preflight — registry, model #4, migration 018');

  const routable = actions.assertRoutable();
  check(routable.ok && routable.labels === 23 && routable.actions === 27,
    `action registry routes every trained label (${routable.labels} labels, ${routable.actions} actions, `
    + `${routable.buttonOnly} button-only)`, JSON.stringify(routable));

  const nlu = await ml.assertNluLabels(actions.intentLabels());
  const hard = nlu.ok && nlu.reachable && nlu.modelStatus === 'ready';
  check(hard, `model #4 reachable and agrees on all labels (${nlu.modelVersion}, threshold ${nlu.threshold})`,
    JSON.stringify({ unroutable: nlu.unroutable, stale: nlu.stale, status: nlu.modelStatus }));
  if (!hard) {
    console.log('\n  ml-service is not serving intents-v2. Start it and re-run:');
    console.log('    cd ml-service && python -m uvicorn app.main:app --port 8000\n');
    return false;
  }

  const { rows: cols } = await client.query(
    `SELECT table_name || '.' || column_name AS c FROM information_schema.columns
      WHERE table_schema = 'public'
        AND (table_name, column_name) IN
            (('chat_channels','session_state'), ('chat_channels','archived_at'),
             ('chat_channels','assistant_persona'), ('chat_messages','assistant_payload'),
             ('assistant_turns','answer_source'), ('assistant_turns','text_chars'),
             ('assistant_kb','asked_count'), ('assistant_escalations','status'))`,
  );
  eq(cols.length, 8, `migration 018 columns present (${cols.map((r) => r.c).sort().join(', ')})`);

  // Provenance for the evidence pack: exactly what was serving on both sides of the
  // language boundary, gathered here because the connection is open and the model has
  // just answered. No credentials -- and deliberately not /health's apiKeyFingerprint.
  if (ev.on) {
    const spec = await ml.nluSpec();
    const d = spec.data || {};
    const m = d.model || {};
    const c = d.corpus || {};
    const { rows: [dbv] } = await client.query(
      `SELECT current_database() AS db, split_part(version(), ' on ', 1) AS v`,
    );
    ev.addMeta('model #4 (intent NLU)',
      `${m.modelVersion || nlu.modelVersion} · threshold ${m.threshold != null ? m.threshold : nlu.threshold}`
      + ` (from the ${m.thresholdSource || 'artifact'}) · ${m.artifact || 'intent_latest.joblib'}`
      + ` · trained ${m.trainedAt || 'unknown'}`);
    ev.addMeta('label contract',
      `${c.intentSpecVersion || '?'} fp ${c.intentSpecFingerprint || '?'}`
      + ` · dataset ${c.datasetSpecVersion || '?'} fp ${c.datasetSpecFingerprint || '?'}`
      + ` · ${(d.intents || []).length} intents in ${(d.groups || []).length} groups`);
    ev.addMeta('rule extractors (no model, no training)',
      `entities ${(d.entities || {}).specVersion} fp ${(d.entities || {}).fingerprint}`
      + ` · text ${(d.text || {}).specVersion} fp ${(d.text || {}).fingerprint}`);
    ev.addMeta('parse limits',
      `${(d.limits || {}).maxTextChars} chars max · ${(d.limits || {}).latencyBudgetMs}ms budget`
      + ` · ${(d.limits || {}).alternatives} alternatives returned`);
    ev.addMeta('action registry', `${routable.labels} trained labels + ${routable.buttonOnly} button-only`
      + ` = ${routable.actions} actions, boot-asserted`);
    ev.addMeta('database', `${dbv.db} · ${dbv.v} · this run is ONE transaction, rolled back`);
  }
  return true;
}

// ════════════════════════════════════════════════════════════════════════════
// A — THE BOOKING CONVERSATION (real money, real ledger)
// ════════════════════════════════════════════════════════════════════════════

/**
 * find_venue → check_availability → pick_slot → confirm → a booked row.
 *
 * The point of driving all five turns instead of calling createBooking directly is
 * that every step's output is the next step's input: a venue card whose button
 * carries the wrong id, or a picker whose chip loses the slot, breaks the chain here
 * and nowhere else. The DB assertions at the end are what separate "Scout said
 * Booked" from "Scout booked".
 */
async function conversationA(client, fx) {
  section('A  find a ground → see times → pick → confirm → booked');
  const { player, venue } = fx.cast;
  const sport = String(venue.sport_type || 'football');
  const city = String(venue.city || '');
  const before = await walletOf(client, player.id);

  const a1 = await say(client, { userId: player.id,
    text: `${city.toLowerCase()} mein ${sport} ground chahiye` });
  const thread = a1.threadId;
  eq(a1.nlu && a1.nlu.intent, 'find_venue', `"${city} mein ${sport} ground chahiye" → find_venue`);
  const vcards = cardsOf(a1, 'venue');
  check(vcards.length > 0, `venue cards returned (${vcards.length})`, a1.reply && a1.reply.text);
  check(['live', 'model'].includes(a1.reply.source),
    `source is live or model (got ${a1.reply.source})`);
  check(vcards.every((c) => String(c.data.sport || '').toLowerCase() === sport.toLowerCase()),
    'every card is the sport that was asked for',
    vcards.map((c) => c.data.sport).join(','));
  const askedArea = a1.nlu && a1.nlu.intent === 'find_venue' ? city : null;
  if (askedArea) {
    check(vcards.every((c) => String(c.data.city || '').toLowerCase().includes(city.toLowerCase())),
      `every card is in ${city}`, vcards.map((c) => c.data.city).join(','));
  }
  check(vcards.every((c) => (c.data.buttons || []).some((b) => b.action === 'check_availability')
    && (c.data.buttons || []).some((b) => b.action === 'book_venue')),
  'every venue card has See-times and Book buttons');
  check(vcards.every((c) => (c.data.lat == null) === !(c.data.buttons || []).some((b) => b.action === 'navigate')),
    'a Directions button appears exactly when the ground has coordinates');
  check(vcards.every((c) => c.data.matchPct === null || Number.isFinite(c.data.matchPct)),
    'matchPct is a real number or null, never 0-as-unknown');
  return { thread, a1, vcards, before, player, venue };
}

// ── row readers, so an assertion looks at the DATABASE and not at the sentence ──

async function walletOf(client, userId) {
  const { rows } = await client.query(
    'SELECT id, balance, frozen_balance FROM wallets WHERE user_id = $1', [userId]);
  return rows.length
    ? { id: rows[0].id, balance: asNum(rows[0].balance), frozen: asNum(rows[0].frozen_balance) }
    : { id: null, balance: 0, frozen: 0 };
}

async function bookingRow(client, id) {
  const { rows } = await client.query(
    `SELECT b.*, s.status AS slot_status FROM bookings b
       LEFT JOIN slots s ON s.id = b.slot_id WHERE b.id = $1`, [id]);
  return rows[0] || null;
}

async function txnsFor(client, bookingId) {
  const { rows } = await client.query(
    `SELECT type, user_id, amount::numeric AS amount,
            balance_after::numeric AS balance_after, description
       FROM transactions WHERE booking_id = $1 ORDER BY created_at, id`, [bookingId]);
  return rows.map((r) => ({ ...r, amount: asNum(r.amount), balance_after: asNum(r.balance_after) }));
}

/**
 * Continues conversation A: the three turns where money actually moves.
 *
 * `ctx` is what the discovery half handed back, which is the point — the venue id
 * used here came out of a card Scout painted, not out of a fixture query.
 */
async function bookingHalf(client, ctx) {
  const { thread, vcards, player, before } = ctx;
  const bookable = new Set(ctx.fxVenueIds);
  const target = vcards.find((c) => bookable.has(String(c.data.id))) || vcards[0];
  if (!target) return skip('booking flow', 'find_venue returned no card to tap');

  // Turn 2: the card's OWN button, args and all — a chip, exactly as Flutter sends it.
  const seeTimes = (target.data.buttons || []).find((b) => b.action === 'check_availability');
  const a2 = await say(client, { userId: player.id, threadId: thread,
    action: seeTimes.action, args: seeTimes.args || { venueId: target.data.id } });
  const picker = cardsOf(a2, 'slot_picker')[0];
  if (!picker) return skip('booking flow', `no free slot at ${target.data.name}: "${a2.reply.text}"`);
  eq(String(picker.data.venueId), String(target.data.id), 'the picker is for the ground that was tapped');
  eq(a2.reply.source, 'live', 'availability is answered live');
  check(picker.data.slots.length > 0 && picker.data.slots.every((s, i) => s.n === i + 1 && s.slotId),
    `slot picker is numbered from 1 (${picker.data.slots.length} slots on ${picker.data.date})`);
  check((picker.data.buttons || []).every((b) => b.action === 'pick_slot' && b.args && b.args.slotId),
    'every picker button is a pick_slot carrying its slot id');
  return { ...ctx, a2, picker, target, before };
}

/** Continues A: tap a time, read the confirm card, say yes, then audit the rows. */
async function confirmHalf(client, ctx) {
  const { thread, picker, player, before } = ctx;
  const first = picker.data.buttons[0];
  const a3 = await say(client, { userId: player.id, threadId: thread,
    action: 'pick_slot', args: first.args });
  const conf = cardsOf(a3, 'confirm')[0];
  if (!conf) return skip('confirm card', `pick_slot did not confirm: "${a3.reply.text}"`);

  const slotPrice = picker.data.slots[0].price;
  eq(conf.data.what, 'book_venue', 'the confirm card knows which action it is arming');
  eq(asNum(conf.data.total), asNum(slotPrice), 'the confirm card quotes the picker price');
  eq(asNum(conf.data.deposit), depositFor(asNum(slotPrice)),
    `deposit is ${POLICY.DEPOSIT_PERCENT}% of the total, from escrow POLICY`);
  eq(conf.data.depositPct, POLICY.DEPOSIT_PERCENT, 'depositPct comes from POLICY, not a literal');
  const btn = (conf.data.buttons || []).map((b) => b.action).sort();
  check(btn.length === 2 && btn[0] === 'cancel_confirm' && btn[1] === 'confirm',
    'the confirm card offers exactly Yes and No', btn.join(','));
  eq(a3.state.confirm && a3.state.confirm.action, 'book_venue', 'session_state is armed for book_venue');
  eq(String(a3.state.confirm.slotId), String(first.args.slotId), 'the armed block holds the picked slot');

  // The word that spends money. Typed, not tapped, and decided by the lexicon.
  const a4 = await say(client, { userId: player.id, threadId: thread, text: 'haan' });
  eq(a4.nlu && a4.nlu.via, 'lexicon', '"haan" is decided by the frozen lexicon, not the model');
  check(a4.reply.actionOk === true && a4.reply.action === 'book_venue',
    'the reply says the booking succeeded', JSON.stringify({ ok: a4.reply.actionOk, text: a4.reply.text }));
  const bcard = cardsOf(a4, 'booking')[0];
  if (!check(!!bcard, `a booking card came back: "${a4.reply.text.slice(0, 80)}"`)) return null;

  const row = await bookingRow(client, bcard.data.id);
  if (!check(!!row, 'the booking EXISTS in the bookings table')) return null;
  eq(String(row.slot_id), String(first.args.slotId), 'it is the slot the user tapped');
  eq(String(row.player_id), String(player.id), 'it belongs to the player who asked');
  eq(row.slot_status, 'booked', 'the slot is now marked booked');
  eq(asNum(row.total_amount), asNum(slotPrice), 'the booked amount is the quoted price');
  eq(asNum(row.deposit_amount), depositFor(asNum(slotPrice)), 'the stored deposit is the POLICY deposit');
  return { ...ctx, a3, a4, booking: row, slotPrice: asNum(slotPrice) };
}

/** Closes A: the wallet and the ledger, which is where a chat booking can lie. */
async function moneyAudit(client, ctx) {
  const { player, before, slotPrice, booking: row } = ctx;
  const after = await walletOf(client, player.id);
  eq(after.balance, round2(before.balance - slotPrice),
    `available balance fell by the full price (${before.balance} → ${after.balance})`);
  eq(after.frozen, round2(before.frozen + slotPrice),
    `the same amount is frozen in escrow (${before.frozen} → ${after.frozen})`);
  eq(round2(after.balance + after.frozen), round2(before.balance + before.frozen),
    'no money was created or destroyed by the booking');

  const txns = await txnsFor(client, row.id);
  const pay = txns.find((t) => t.type === 'booking_payment');
  check(!!pay, `a booking_payment row is in the ledger (${txns.length} txn row(s))`,
    txns.map((t) => t.type).join(','));
  if (pay) {
    eq(pay.amount, round2(-slotPrice), 'the ledger amount is the negative of the price');
    eq(pay.balance_after, after.balance, 'balance_after matches the wallet it left behind');
  }

  // The utterance that spent the money is in the THREAD, and the telemetry row for the
  // same turn carries only its length. Both halves of doc/CLAUDE.md's rule, asserted.
  const { rows: [t] } = await client.query(
    `SELECT intent, confidence, model_version, answer_source, action, action_ok, fsm_state,
            text_chars, input_mode
       FROM assistant_turns WHERE user_id = $1 ORDER BY created_at DESC, id DESC LIMIT 1`,
    [player.id],
  );
  check(!!t, 'the turn was recorded in assistant_turns');
  if (t) {
    eq(t.action, 'confirm', 'telemetry names the action that ran');
    eq(t.action_ok, true, 'telemetry records that it succeeded');
    eq(t.answer_source, 'live', 'a booking is answered live');
    eq(t.intent, 'affirm', 'the intent is the affirm that fired it');
    eq(t.confidence, null, 'a lexicon turn records NO confidence, so it cannot skew model metrics');
    eq(t.model_version, null, 'and no model version, for the same reason');
    eq(t.text_chars, 4, '"haan" is stored as a LENGTH (4), never as text');
  }
  return ctx;
}

// ════════════════════════════════════════════════════════════════════════════
// B — THE CANCELLATION (the sentence in the spec, checked against the ledger)
// ════════════════════════════════════════════════════════════════════════════

/**
 * The booking made in A, cancelled through the card button on it.
 *
 * The refund is NOT hardcoded here. bookingService.previewCancellation is the
 * authority, so the assertion is that Scout's sentence, Scout's card and the wallet
 * all say what the service says — which is the FR8.15 claim itself, stated as a test.
 */
async function conversationB(client, ctx) {
  section('B  cancel it → refund preview → confirmed → wallet and ledger agree');
  const { thread, player, booking: row } = ctx;
  const ownerId = (await client.query('SELECT owner_id FROM venues WHERE id = $1',
    [row.venue_id])).rows[0].owner_id;
  const beforeP = await walletOf(client, player.id);
  const beforeO = await walletOf(client, ownerId);

  const pv = await booking.previewCancellation(client, { userId: player.id, bookingId: row.id });
  if (!check(pv.ok, 'previewCancellation answers for the fresh booking', pv.message)) return ctx;
  const p = pv.data;

  const b1 = await say(client, { userId: player.id, threadId: thread,
    action: 'cancel_booking', args: { bookingId: row.id } });
  const conf = cardsOf(b1, 'confirm')[0];
  if (!check(!!conf, `cancel offers a confirm card: "${b1.reply.text.slice(0, 70)}"`)) return ctx;
  eq(conf.data.what, 'cancel_booking', 'the card is armed for cancel_booking');
  eq(asNum(conf.data.total), asNum(p.refund), 'the card quotes previewCancellation\'s refund');
  check(b1.reply.text.includes(actions.money(p.refund))
    && b1.reply.text.includes(`(${p.refundPct}%)`),
  `the sentence states the refund and the percentage — "${actions.money(p.refund)} back (${p.refundPct}%)"`,
  b1.reply.text);
  eq(round2(asNum(p.refund) + asNum(p.penalty)), round2(asNum(p.escrow)),
    'refund + penalty is exactly what was held in escrow');
  if (p.late) {
    eq(asNum(p.penalty), asNum(row.deposit_amount),
      `inside the ${p.windowHours}h window the penalty IS the deposit`);
  } else {
    eq(asNum(p.penalty), 0, `more than ${p.windowHours}h out, nothing is forfeited`);
  }
  return { ...ctx, b1, p, beforeP, beforeO, ownerId };
}

/**
 * "haan" on the armed cancellation, then the audit that matters most in the whole
 * script: money is CONSERVED. A refund that credits the player without releasing
 * the freeze mints money; a penalty that debits the player without crediting the
 * owner burns it. Both are invisible to a happy-path test that only reads the
 * player's balance, so the sum across BOTH wallets is asserted explicitly.
 */
async function cancelHalf(client, ctx) {
  const { thread, player, booking: row, p, beforeP, beforeO, ownerId } = ctx;
  const y = await say(client, { userId: player.id, threadId: thread, text: 'haan' });
  eq(y.nlu && y.nlu.via, 'lexicon', 'the yes is read by the frozen lexicon, not the model');
  eq(y.reply.action, 'cancel_booking', 'the turn reports the action it ran');
  check(y.reply.actionOk === true, `the cancellation executed: "${y.reply.text.slice(0, 90)}"`,
    y.reply.meta && y.reply.meta.code);
  check(/back in your wallet/i.test(y.reply.text), 'and says the money is back');

  const dead = await bookingRow(client, row.id);
  eq(dead.status, 'cancelled', 'the booking row is cancelled');
  check(dead.cancelled_at != null, 'cancelled_at is stamped');
  eq(dead.cancellation_reason, p.late ? 'late_cancellation' : 'user_cancelled',
    'the reason records which side of the window it was');
  const slot = (await client.query(
    'SELECT status, locked_by, locked_until FROM slots WHERE id = $1', [row.slot_id])).rows[0];
  eq(String(slot.status), 'available', 'the slot is bookable by someone else again');
  check(slot.locked_by == null && slot.locked_until == null, 'and carries no stale hold');

  const afterP = await walletOf(client, player.id);
  const afterO = await walletOf(client, ownerId);
  eq(round2(afterP.balance - beforeP.balance), round2(asNum(p.refund)),
    'the player is credited exactly the previewed refund');
  eq(round2(afterP.frozen - beforeP.frozen), round2(-asNum(p.escrow)),
    'and the whole escrow is released from frozen');
  eq(round2(afterO.balance - beforeO.balance), round2(asNum(p.penalty)),
    'the owner receives exactly the penalty (0 when the cancel was early)');
  eq(round2((afterP.balance + afterP.frozen + afterO.balance + afterO.frozen)
    - (beforeP.balance + beforeP.frozen + beforeO.balance + beforeO.frozen)), 0,
  'MONEY IS CONSERVED: nothing was minted and nothing was burned across both wallets');
  return { ...ctx, afterP, afterO };
}

/**
 * The ledger for the cancelled booking, and the notification the owner gets.
 *
 * `transactions` is the audit trail a committee can read, so the assertion is not
 * merely "a refund row exists" but that the SET of rows for this booking is exactly
 * the set the policy prescribes: payment + refund always, and the two escrow legs
 * only when a penalty was actually charged.
 */
async function cancelLedger(client, ctx) {
  const { player, booking: row, p, afterP, afterO, ownerId } = ctx;
  const t = await txnsFor(client, row.id);
  const byType = (type) => t.filter((r) => r.type === type);
  const types = t.map((r) => r.type).join(',');

  const refunds = byType('refund');
  eq(refunds.length, 1, `exactly one refund row (ledger: ${types})`);
  if (refunds.length) {
    eq(round2(refunds[0].amount), round2(asNum(p.refund)), 'the refund row carries the refund');
    eq(refunds[0].user_id, player.id, 'credited to the player');
    eq(round2(refunds[0].balance_after), round2(afterP.balance),
      'and its balance_after matches the wallet the user will see');
  }

  if (asNum(p.penalty) > 0) {
    const rel = byType('escrow_release');
    const rec = byType('escrow_received');
    eq(rel.length, 1, 'a late cancel writes one escrow_release');
    eq(rec.length, 1, 'and one escrow_received');
    if (rel.length) {
      eq(round2(rel[0].amount), round2(-asNum(p.penalty)), 'the release is NEGATIVE on the player');
      eq(rel[0].user_id, player.id, 'against the player');
    }
    if (rec.length) {
      eq(round2(rec[0].amount), round2(asNum(p.penalty)), 'the receipt is POSITIVE on the owner');
      eq(rec[0].user_id, ownerId, 'against the venue owner');
      eq(round2(rec[0].balance_after), round2(afterO.balance), 'with the owner\'s new balance');
    }
    const note = await client.query(
      `SELECT type FROM notifications WHERE booking_id = $1 AND user_id = $2
         AND type = 'booking_cancelled_late'`, [row.id, ownerId]);
    check(note.rows.length === 1, 'the owner is notified of the late cancellation');
  } else {
    eq(byType('escrow_release').length, 0, 'an early cancel releases nothing to the owner');
    eq(byType('escrow_received').length, 0, 'and credits the owner nothing');
  }
  eq(round2(t.reduce((a, r) => a + r.amount, 0)),
    round2(-asNum(p.penalty)),
    'the booking\'s ledger nets to exactly minus the penalty — the only money that left the player');
  return ctx;
}

// ════════════════════════════════════════════════════════════════════════════
// C — THE STALE YES  (the money gate, proved against the live classifier)
// ════════════════════════════════════════════════════════════════════════════

/**
 * Arm a booking confirm on the first slot this venue has free, today or tomorrow.
 * Returns the confirm card and the slot id it is armed for, or nulls if the ground
 * genuinely has nothing left — which is a skip, not a failure.
 */
async function armBooking(client, { player, thread, venueId }) {
  const today = actions.pktDate();
  let free = (await discovery.freeSlots(client, { venueId, userId: player.id, date: today, limit: 6 })).slots;
  let date = today;
  if (!free.length) {
    date = actions.pktDate(1);
    free = (await discovery.freeSlots(client, { venueId, userId: player.id, date, limit: 6 })).slots;
  }
  if (!free.length) return { out: null, conf: null, slotId: null, date, free: [] };
  const out = await say(client, { userId: player.id, threadId: thread,
    action: 'pick_slot', args: { slotId: free[0].id } });
  return { out, conf: cardsOf(out, 'confirm')[0] || null, slotId: free[0].id, date, free };
}

/** Bookings this player holds on one slot that are not cancelled. */
async function liveBookings(client, { userId, slotId }) {
  const { rows } = await client.query(
    `SELECT id, status FROM bookings
      WHERE player_id = $1 AND slot_id = $2 AND status <> 'cancelled'`, [userId, slotId]);
  return rows;
}

/**
 * The sentence that would have cost the user money.
 *
 * model #4 labels "haan lekin 7 baje" AFFIRM at 0.61 — over its own 0.45 threshold.
 * A gate that reads `intent === 'affirm'` therefore books the 6pm the user was
 * CORRECTING. The gate asks WHERE the yes came from instead, so this sentence takes
 * the correction branch: the same errand re-opens at the hour the user just named,
 * and the armed confirm dies unfired.
 *
 * This is the check that most needs the live classifier. A stub would pass it while
 * the shipped model still said 0.61.
 */
async function conversationC(client, ctx) {
  section('C  a yes that is really a correction must NOT spend money');
  const { player, thread, booking: row } = ctx;
  const venueId = row.venue_id;

  const a = await armBooking(client, { player, thread, venueId });
  if (!a.conf) {
    skip('the stale-yes gate', `${a.free.length} free slots left at the fixture venue`);
    return ctx;
  }
  eq(a.conf.data.what, 'book_venue', 'a booking confirm is armed');

  const y = await say(client, { userId: player.id, threadId: thread, text: 'haan lekin 7 baje' });
  eq(y.nlu && y.nlu.intent, 'affirm', 'the live model still calls that sentence an affirm');
  eq(y.nlu && y.nlu.via, 'model', 'and it is the MODEL saying so, not the lexicon');
  check(y.nlu && y.nlu.confidence >= 0.45,
    `at ${y.nlu ? y.nlu.confidence : '?'} — above the threshold, so the old gate WOULD have fired`);
  eq(y.state && y.state.slots && y.state.slots.time, '19:00',
    'the rule extractor read "7 baje" as 19:00 and it reached the slots');

  const booked = await liveBookings(client, { userId: player.id, slotId: a.slotId });
  eq(booked.length, 0, 'NO BOOKING WAS MADE — the model cannot fire the confirm gate');
  check(y.reply.action !== 'book_venue' || y.reply.actionOk !== true,
    'and the turn does not report a completed booking', y.reply.action);

  const picker = cardsOf(y, 'slot_picker')[0];
  if (picker) {
    eq(picker.data.venueId, venueId, 'the SAME ground reopens');
    eq(String(picker.data.date), String(a.date), 'on the SAME day');
    const first = picker.data.slots[0];
    const dist = (t) => Math.abs((Number(String(t).slice(0, 2)) * 60
      + Number(String(t).slice(3, 5))) - 19 * 60);
    check(picker.data.slots.every((s) => dist(s.startTime) >= dist(first.startTime)),
      `at the hour the user actually asked for — nearest to 19:00 first (${first.startTime})`);
  } else {
    check(/nothing free|which day|pick a time/i.test(y.reply.text),
      'the correction is answered honestly when that hour has nothing free', y.reply.text);
  }
  eq(y.state && y.state.confirm, null, 'the armed confirm is gone, not left waiting for a later yes');
  return ctx;
}

/**
 * The other three ways a confirm gate goes wrong, all of them money.
 *
 *   STALE   an armed confirm that survives an unrelated turn, so a "haan" about
 *           something else books a slot the user stopped talking about.
 *   DENY    the same asymmetry as C, on the other verdict: model #4 calls "nahi 8
 *           baje karo" DENY at 0.51, and a gate that trusted it would answer a
 *           correction by tearing down the errand.
 *   CHIP    the positive control. A gate that never fires passes every negative
 *           test above, so the button path must still spend the money.
 */
async function conversationC2(client, ctx) {
  section('C2  stale confirms, model denials, and the button that must still work');
  const { player, thread, booking: row } = ctx;
  const venueId = row.venue_id;

  // ── STALE ────────────────────────────────────────────────────────────────
  const s1 = await armBooking(client, { player, thread, venueId });
  if (!s1.conf) { skip('the stale-confirm checks', 'no free slot to arm one'); return ctx; }
  const away = await say(client, { userId: player.id, threadId: thread, action: 'wallet_balance' });
  eq(away.state && away.state.confirm, null, 'an unrelated turn clears the armed confirm');
  const late = await say(client, { userId: player.id, threadId: thread, text: 'haan' });
  eq((await liveBookings(client, { userId: player.id, slotId: s1.slotId })).length, 0,
    'so a later "haan" books NOTHING — a confirm lives exactly one turn');
  check(/yes to what|tell me/i.test(late.reply.text) || late.reply.action === 'affirm',
    `and Scout asks what the yes was for: "${late.reply.text.slice(0, 60)}"`);

  // ── DENY ─────────────────────────────────────────────────────────────────
  const s2 = await armBooking(client, { player, thread, venueId });
  if (s2.conf) {
    const d = await say(client, { userId: player.id, threadId: thread, text: 'nahi 8 baje karo' });
    eq(d.nlu && d.nlu.intent, 'deny', 'the live model calls "nahi 8 baje karo" a deny');
    eq(d.nlu && d.nlu.via, 'model', 'from the model, so it may not fire the gate either');
    eq(d.state && d.state.slots && d.state.slots.time, '20:00', 'the correction carries 20:00');
    eq((await liveBookings(client, { userId: player.id, slotId: s2.slotId })).length, 0,
      'nothing is booked');
    check(!/^i am not holding/i.test(d.reply.text),
      `and the errand is re-run rather than abandoned: "${d.reply.text.slice(0, 70)}"`);
  }

  // ── CHIP (positive control) ──────────────────────────────────────────────
  const s3 = await armBooking(client, { player, thread, venueId });
  if (!s3.conf) { skip('the chip-confirm control', 'no free slot left to book'); return ctx; }
  // The player already paid a late-cancellation penalty in B, so check the wallet
  // can still cover this slot. An `insufficient_funds` refusal here would be the
  // ledger behaving correctly, not the gate failing, and reporting it as a failure
  // would be a lie about which code was wrong.
  const purse = await walletOf(client, player.id);
  if (purse.balance < asNum(s3.conf.data.total)) {
    skip('the chip-confirm control',
      `wallet holds ${actions.money(purse.balance)}, the slot costs ${s3.conf.data.totalLabel}`);
    return ctx;
  }
  const yes = s3.conf.data.buttons.find((b) => b.action === 'confirm');
  const done = await say(client, { userId: player.id, threadId: thread,
    action: yes.action, args: yes.args || {} });
  eq(done.reply.action, 'book_venue', 'the confirm BUTTON runs the booking');
  check(done.reply.actionOk === true, 'and it succeeds — the gate is closed to the model, not to the user',
    done.reply.meta && done.reply.meta.code);
  eq((await liveBookings(client, { userId: player.id, slotId: s3.slotId })).length, 1,
    'exactly one booking exists for that slot');
  return ctx;
}

// ════════════════════════════════════════════════════════════════════════════
// D — THE READS  (every answer_source in the enum, earned by a real turn)
// ════════════════════════════════════════════════════════════════════════════

/**
 * The six read intents, checked for the thing that is easy to get wrong about each:
 * the wallet must separate spendable from frozen, policy must come from POLICY, an
 * empty tournaments table must be an ANSWER, and anything Scout cannot do must land
 * on the menu instead of a dead end.
 */
async function conversationD(client, ctx) {
  section('D  reads: wallet · bookings · policy · tournaments · team rating · help · out of scope');
  const { player, thread } = ctx;

  const w = await say(client, { userId: player.id, threadId: thread, action: 'wallet_balance' });
  const wcard = cardsOf(w, 'wallet')[0];
  const purse = await walletOf(client, player.id);
  eq(w.reply.source, 'live', 'a balance is answered live');
  if (check(!!wcard, 'the wallet card is painted')) {
    eq(round2(wcard.data.balance), round2(purse.balance), 'the card shows the spendable balance');
    eq(round2(wcard.data.frozen), round2(purse.frozen), 'and the frozen balance SEPARATELY');
    eq(round2(wcard.data.total), round2(purse.balance + purse.frozen), 'total is the sum of both');
    check(w.reply.text.includes(actions.money(purse.balance)),
      'and the sentence quotes the spendable number, not the total');
  }

  const mb = await say(client, { userId: player.id, threadId: thread, action: 'my_bookings' });
  const mine = await booking.listMyBookings(client, { userId: player.id, status: null, limit: 20 });
  eq(mb.reply.source, 'live', 'the booking list is live');
  if (mine.length) {
    const bc = cardsOf(mb, 'booking');
    check(bc.length > 0 && bc.length <= 5, `${bc.length} booking cards for ${mine.length} bookings`);
    const ids = new Set(mine.map((r) => String(r.id)));
    check(bc.every((c) => ids.has(String(c.data.id))),
      'every card is one of THIS player\'s bookings');
  } else {
    check(/no bookings/i.test(mb.reply.text), 'an empty history says so plainly', mb.reply.text);
  }

  // ── POLICY: the sentence is editable, the numbers are not ─────────────────
  const pol = await say(client, { userId: player.id, threadId: thread, text: 'refund policy kya hai' });
  eq(pol.reply.source, 'policy', 'a rules question is answered from POLICY, never from a query');
  const pcard = cardsOf(pol, 'policy')[0];
  if (check(!!pcard, 'a policy card is painted')) {
    eq(pcard.data.depositPct, POLICY.DEPOSIT_PERCENT, 'the card carries the real deposit percent');
    eq(pcard.data.refundPct, 100 - POLICY.DEPOSIT_PERCENT, 'and the refund percent derived from it');
    eq(pcard.data.windowHours, POLICY.CANCELLATION_WINDOW_HOURS, 'and the real cancellation window');
    check(pol.reply.text.includes(String(POLICY.CANCELLATION_WINDOW_HOURS)),
      `the sentence states the ${POLICY.CANCELLATION_WINDOW_HOURS}-hour window`, pol.reply.text);
  }
  const settings = await require('../utils/globalSettings')
    .assistant({ client, fresh: true }).catch(() => ({}));
  let unfilled = 0;
  for (const name of policyText.TOPICS) {
    const t = policyText.topic(name, settings || {});
    if (/\{[a-z0-9_]+\}/i.test(t.text) || !t.text.trim()) unfilled += 1;
  }
  eq(unfilled, 0, `all ${policyText.TOPICS.length} policy topics render with no unfilled placeholder`);
  const wd = await say(client, { userId: player.id, threadId: thread,
    action: 'refund_policy', args: { topic: 'withdrawal' } });
  eq((cardsOf(wd, 'policy')[0] || { data: {} }).data.topic, 'withdrawal',
    'a topic chip routes to that topic');
  check(wd.state.slots.topic == null,
    'and the topic is cleared, so the next question starts fresh, not stuck on withdrawals');

  // ── TOURNAMENTS: an empty table is an answer ──────────────────────────────
  const tl = await say(client, { userId: player.id, threadId: thread, action: 'tournament_list' });
  const open = await discovery.listTournaments(client, { openOnly: true, limit: 10 });
  eq(tl.reply.source, 'live', 'the tournament list is live');
  eq(cardsOf(tl, 'tournament').length, Math.min(open.length, 5),
    `${open.length} open tournaments → ${cardsOf(tl, 'tournament').length} cards`);
  check((tl.reply.chips || []).length > 0,
    `and the turn still offers somewhere to go: "${tl.reply.text.slice(0, 70)}"`);

  // ── TEAM RATING: the checklist's "my_elo", which on SportLynk is team_stats ──
  // SportLynk rates TEAMS and not players (FR2.6), so there is no my_elo action to
  // call: the intent is team_stats, and every number on the card comes from
  // teamStats.profileStats — the same function the team profile screen reads. So
  // this asserts the card against THAT function rather than against a literal, and
  // it is driven by a real captain, because ctx.player may not be in a team at all
  // and "you are not in a team yet" is a different branch, checked after it.
  if (!ctx.adminTeam || !ctx.adminTeam.adminId) {
    skip('team rating', 'no team fixture with a captain in this database');
  } else {
    const cap = ctx.adminTeam.adminId;
    const said = 'hamari team ki rating kitni hai';
    let ts = await say(client, { userId: cap, text: said });
    eq(ts.nlu && ts.nlu.intent, 'team_stats',
      `"${said}" → team_stats (there is no my_elo intent: FR2.6 rates TEAMS)`);
    const tthread = ts.threadId;
    const which = (ts.reply.chips || []).find((c) => c.action === 'team_stats' && c.args && c.args.teamId);
    if (!cardsOf(ts, 'team').length && which) {
      check(true, 'a captain of more than one team is asked WHICH, by chip, not guessed at');
      ts = await say(client, { userId: cap, threadId: tthread, action: 'team_stats', args: which.args });
    }
    eq(ts.reply.source, 'live', 'a rating is read live, never remembered');
    const tcard = cardsOf(ts, 'team')[0];
    if (check(!!tcard, `the team card is painted: "${ts.reply.text.slice(0, 70)}"`)) {
      const s = await teamStats.profileStats(client, tcard.data.id);
      eq(tcard.data.matchesPlayed, s.played, `played count is profileStats' own (${s.played})`);
      eq(tcard.data.wins, s.wins, 'the wins are the same wins');
      eq(tcard.data.losses, s.losses, 'and the losses the same losses');
      eq(tcard.data.elo, s.elo, `the raw elo is the stored elo (${s.elo})`);
      eq(tcard.data.isRanked, s.ranked, `isRanked is profileStats' verdict (${s.ranked})`);
      eq(tcard.data.displayElo, s.display_elo,
        `and displayElo agrees with it (${JSON.stringify(s.display_elo)})`);
      if (s.ranked) {
        check(ts.reply.text.includes(String(s.display_elo)),
          `a ranked team is told its number (${s.display_elo})`, ts.reply.text);
        check(ts.reply.text.includes(`${s.wins}W-${s.losses}L-${s.draws}D`),
          `and its record, in one string (${s.wins}W-${s.losses}L-${s.draws}D)`, ts.reply.text);
      } else {
        // FR2.6 under RANKED_MIN. The failure mode this guards is the friendly lie:
        // printing the 1000 seed as though it had been earned on the pitch.
        eq(s.display_elo, null,
          `unranked at ${s.played}/${s.ranked_min_matches} played → display_elo is NULL, not a seed`);
        check(/unranked/i.test(ts.reply.text), 'and the sentence says unranked', ts.reply.text);
        check(!/\b1000\b/.test(ts.reply.text),
          'and never shows 1000 as if it were a rating', ts.reply.text);
        check(ts.reply.text.includes(String(s.ranked_min_matches)),
          `while saying how many matches it takes (${s.ranked_min_matches})`, ts.reply.text);
      }
      check((ts.reply.chips || []).some((c) => c.action === 'elo_help'),
        'and offers the how-does-rating-work explainer next to the number');
    }
    const { rows: loner } = await client.query(
      `SELECT u.id FROM users u
        WHERE u.role = 'player' AND u.is_active
          AND NOT EXISTS (SELECT 1 FROM team_members m WHERE m.user_id = u.id)
        LIMIT 1`,
    );
    if (!loner.length) {
      skip('the teamless branch', 'every active player in this database is in a team');
    } else {
      const nt = await say(client, { userId: loner[0].id, action: 'team_stats' });
      check(/not in a team/i.test(nt.reply.text),
        `a player with no team is told so: "${nt.reply.text.slice(0, 60)}"`, nt.reply.text);
      eq(cardsOf(nt, 'team').length, 0, 'and no team is invented to fill the card');
      check((nt.reply.chips || []).length > 0, 'with somewhere to go instead (ER2.6)');
    }
  }

  // ── HELP and OUT OF SCOPE: no dead ends (ER2.6) ───────────────────────────
  const ah = await say(client, { userId: player.id, threadId: thread, text: 'app kaise use karun' });
  check(ah.reply.text.length > 40, `app_help explains the app: "${ah.reply.text.slice(0, 60)}..."`);
  check((ah.reply.chips || []).length >= 2, 'and offers buttons');

  const cm = await say(client, { userId: player.id, threadId: thread, action: 'capability_menu' });
  eq(cm.reply.source, 'menu', 'the capability list is sourced as a menu');
  const caps = cardsOf(cm, 'capabilities')[0];
  if (check(!!caps, 'the capabilities card is painted')) {
    check(caps.data.items.length >= 12, `${caps.data.items.length} capabilities listed`);
    check((caps.data.groups || []).length >= 3, `grouped into ${(caps.data.groups || []).length} sections`);
    check(caps.data.items.every((i) => actions.isAction(i.action)),
      'and EVERY item on the menu is an action Scout can actually run');
  }

  const oos = await say(client, { userId: player.id, threadId: thread, text: 'mausam kaisa hai aaj' });
  eq(oos.reply.source, 'menu', 'a question outside SportLynk lands on the menu');
  check(/only do sportlynk|outside my ground/i.test(oos.reply.text),
    `and says so honestly: "${oos.reply.text.slice(0, 70)}"`);
  check((oos.reply.chips || []).length > 0, 'with chips, so it is not a dead end (ER2.6)');
  return ctx;
}

// ════════════════════════════════════════════════════════════════════════════
// E — ASK THE OWNER  (escalated → owner answers → the next player gets it free)
// ════════════════════════════════════════════════════════════════════════════

/**
 * The one loop in the wave that makes Scout better over time, and the only place it
 * is allowed to not know something.
 *
 * A question no query can answer goes to the venue OWNER (`source: 'escalated'`),
 * the owner's answer is published into assistant_kb AND delivered into the player's
 * own thread, and the same question asked again is served from the KB
 * (`source: 'kb'`) without disturbing anyone. Money and policy may never enter that
 * queue — an owner answering "what is the refund rule" would be redefining POLICY.
 */
async function conversationE(client, ctx) {
  section('E  escalation → the owner answers → the next ask is free');
  const { player, thread, booking: row } = ctx;
  const venueId = row.venue_id;
  const v = (await client.query('SELECT name, owner_id FROM venues WHERE id = $1', [venueId])).rows[0];
  if (!v.owner_id) { skip('the escalation loop', 'the fixture venue has no owner account'); return ctx; }
  const question = `floodlights kaam karte hain ya nahi check ${String(venueId).slice(0, 8)}`;

  const e1 = await say(client, { userId: player.id, threadId: thread,
    action: 'contact_owner', args: { venueId, question } });
  eq(e1.reply.source, 'escalated', 'a question only the owner can answer is sourced as escalated');
  check(e1.reply.actionOk === true, `and is accepted: "${e1.reply.text.slice(0, 70)}"`);
  const escId = e1.reply.meta && e1.reply.meta.escalationId;
  if (!check(!!escId, 'the reply carries the escalation id')) return ctx;
  const esc = (await client.query('SELECT * FROM assistant_escalations WHERE id = $1', [escId])).rows[0];
  eq(esc.status, 'open', 'the queue row is open');
  eq(esc.venue_id, venueId, 'filed against the right ground');
  eq(esc.owner_id, v.owner_id, 'and addressed to its owner');
  eq(String(esc.channel_id), String(e1.threadId), 'and it remembers WHICH chat to answer into');
  const onote = await client.query(
    `SELECT 1 FROM notifications WHERE user_id = $1 AND type = 'assistant_question'
       AND (payload->>'escalationId') = $2`, [v.owner_id, String(escId)]);
  check(onote.rows.length === 1, 'the owner is notified there is a question waiting');

  const again = await say(client, { userId: player.id, threadId: thread,
    action: 'contact_owner', args: { venueId, question } });
  check(again.reply.meta && again.reply.meta.duplicate === true,
    'asking the identical question again does NOT file a second queue item');
  eq((await client.query(
    'SELECT count(*)::int n FROM assistant_escalations WHERE venue_id = $1 AND question = $2',
    [venueId, question])).rows[0].n, 1, 'there is still exactly one row for it');

  const blocked = await probe(client, () => kb.escalate(client, {
    userId: player.id, venueId, question: 'refund kitna milega', intent: 'refund_policy' }));
  eq(blocked.ok && blocked.out && blocked.out.reason, 'money_or_policy',
    'a MONEY question is refused entry to the owner queue — POLICY is not the owner\'s to redefine');
  return { ...ctx, escId, question, ownerId2: v.owner_id, venueName: v.name };
}

/**
 * The owner's half, and then the payoff.
 *
 * `kb.answer` is what routes/assistant.js calls from the owner's queue screen. The
 * assertion that matters most is DELIVERY: the answer has to appear in the PLAYER's
 * thread, because a knowledge base nobody sees is not an answer to anybody.
 */
async function conversationE2(client, ctx) {
  const { player, thread, escId, question, ownerId2, venueName } = ctx;
  if (!escId) return ctx;
  const answerText = 'Yes — four floodlight towers, and night slots run until 2am.';

  const ans = await probe(client, () => kb.answer(client, {
    escalationId: escId, ownerId: ownerId2, answerText, publish: true }));
  if (!check(ans.ok && ans.out && ans.out.ok, 'the owner answers the queued question',
    ans.err ? ans.err.message : (ans.out && ans.out.message))) return ctx;
  const kbRow = ans.out.row;
  eq(kbRow.status, 'published', 'the answer is published, not left a draft');
  eq(kbRow.scope, 'venue', 'and scoped to that ONE venue — never applied to other grounds');
  eq(kbRow.answer, answerText, 'stored verbatim');
  const closed = (await client.query(
    'SELECT status, kb_id, answered_by FROM assistant_escalations WHERE id = $1', [escId])).rows[0];
  eq(closed.status, 'answered', 'the queue row closes');
  eq(String(closed.kb_id), String(kbRow.id), 'pointing at the KB entry it produced');
  eq(closed.answered_by, ownerId2, 'and records who answered');

  check(ans.out.delivered === true, 'the answer is DELIVERED into the player\'s own chat thread');
  const posted = await client.query(
    `SELECT body, assistant_payload FROM chat_messages
      WHERE channel_id = $1 AND kind = 'assistant' AND body LIKE $2`,
    [thread, `%${answerText.slice(0, 30)}%`]);
  check(posted.rows.length === 1, 'a Scout message carrying it is in the thread');
  if (posted.rows.length) {
    eq(posted.rows[0].assistant_payload.source, 'kb',
      'and that message re-renders as a KB answer when the user scrolls back');
  }
  const pnote = await client.query(
    `SELECT 1 FROM notifications WHERE user_id = $1 AND type = 'assistant_answer'
       AND (payload->>'kbId') = $2`, [player.id, String(kbRow.id)]);
  check(pnote.rows.length === 1, 'and the player is notified it landed');

  // ── THE PAYOFF: the same question, served from the KB ─────────────────────
  const reuse = await say(client, { userId: player.id, threadId: thread,
    action: 'contact_owner', args: { venueId: ctx.booking.venue_id, question } });
  eq(reuse.reply.source, 'kb', 'the SAME question is now answered from the knowledge base');
  eq(reuse.reply.text, answerText, 'with the owner\'s own words');
  check(reuse.reply.meta && String(reuse.reply.meta.kbId) === String(kbRow.id),
    'from the entry the owner just wrote');
  eq((await client.query('SELECT served_count FROM assistant_kb WHERE id = $1',
    [kbRow.id])).rows[0].served_count, 1, 'and the reuse is counted');
  eq((await client.query(
    `SELECT count(*)::int n FROM assistant_escalations WHERE venue_id = $1 AND question = $2`,
    [ctx.booking.venue_id, question])).rows[0].n, 1,
  'the owner is NOT disturbed a second time');
  check(!/asked the owner/i.test(reuse.reply.text),
    `and Scout does not pretend to ask again: "${reuse.reply.text.slice(0, 60)}"`);
  return ctx;
}

// ════════════════════════════════════════════════════════════════════════════
// F — DISCOVERY  (grounds, players, opponents, teams, and the map)
// ════════════════════════════════════════════════════════════════════════════

/**
 * The five things the user asked Scout to help them DISCOVER.
 *
 * Each one is checked against the service it must agree with rather than against a
 * hardcoded expectation, because the point of the FR8.15 extraction is that Scout
 * and the screens read the same rows. Where a trained model ranks the answer the
 * `source` badge must say `model`, and where it does not the cards must carry NO
 * match percentage — a fabricated number is worse than an absent one.
 */
async function conversationF(client, ctx) {
  section('F  discovery: ground info · directions · players · opponents · teams');
  const { player, thread, booking: row } = ctx;
  const venueId = row.venue_id;

  const vi = await say(client, { userId: player.id, threadId: thread,
    action: 'venue_info', args: { venueId } });
  const vcard = cardsOf(vi, 'venue')[0];
  const truth = await discovery.venueDetail(client, { venueId, userId: player.id });
  if (check(!!vcard, 'venue_info paints the ground')) {
    eq(String(vcard.data.id), String(venueId), 'the right ground');
    eq(vcard.data.name, truth.data.name, 'with the name the venue page shows');
    check(vi.reply.text.includes(truth.data.name), 'and names it in the sentence');
    check((vi.reply.chips || []).some((c) => c.action === 'check_availability'),
      'and offers to show times');
  }

  const nav = await say(client, { userId: player.id, threadId: thread,
    action: 'navigate', args: { venueId } });
  const map = cardsOf(nav, 'map')[0];
  if (check(!!map, 'navigate paints a map card')) {
    eq(map.data.venueId, venueId, 'for that ground');
    eq(map.data.hasPin, truth.data.latitude != null && truth.data.longitude != null,
      'hasPin states honestly whether the venue has coordinates');
    check(/^geo:/.test(map.data.geoUri), `a geo: URI Android can open (${map.data.geoUri.slice(0, 34)}...)`);
    check(/^https:\/\/www\.google\.com\/maps\//.test(map.data.mapsUrl), 'and a Maps URL as the fallback');
    check(map.data.hasPin
      ? /destination=/.test(map.data.mapsUrl) : /query=/.test(map.data.mapsUrl),
    'the URL routes to a pin when there is one and searches the address when there is not');
  }

  const ft = await say(client, { userId: player.id, threadId: thread, action: 'find_teams' });
  const joinable = await discovery.discoverTeams(client, { userId: player.id, limit: 40 });
  eq(cardsOf(ft, 'team').length, Math.min((joinable.data || []).length, actions.TOP_PEOPLE),
    `${(joinable.data || []).length} joinable teams → ${cardsOf(ft, 'team').length} cards`);
  check(cardsOf(ft, 'team').every((c) => c.data.id && c.data.name),
    'every team card carries the id a join request needs');
  if ((joinable.data || []).length > 1) {
    const elos = cardsOf(ft, 'team').map((c) => Number(c.data.elo || 0));
    check(elos.every((e, i) => i === 0 || elos[i - 1] >= e), 'strongest first, as the sentence claims');
  }

  // ── PLAYERS and OPPONENTS: only answerable for a team the user administers ─
  // A user who captains TWO squads has two right answers, so the correct reply to a
  // bare "find me players" is a question. That branch is asserted rather than
  // avoided: it is the one most likely to be quietly broken by a chip that forgets
  // its team id.
  const mine = (await client.query(
    `SELECT t.id, t.name FROM teams t JOIN team_members m ON m.team_id = t.id
      WHERE m.user_id = $1 AND m.role IN ('captain', 'vice_captain')
      ORDER BY t.elo DESC NULLS LAST`,
    [player.id])).rows;

  /** The card assertions, once, for whichever team the conversation lands on. */
  async function assertPeopleFor(out, teamId, teamName) {
    const sp = await roster.suggestPlayers(client, { teamId, userId: player.id });
    const list = sp.ok ? (sp.data.suggestions || []) : [];
    const ranked = sp.ok && sp.data.ranking.available === true;
    const cards = cardsOf(out, 'player');
    eq(cards.length, Math.min(list.length, actions.TOP_PEOPLE),
      `${list.length} suggestions for ${teamName} → ${cards.length} player cards`);
    if (!list.length) return;
    // The badge answers a NARROWER question than "is this list well ordered": did a
    // TRAINED model shape it? For players the honest answer is never yes. reco_rank.py
    // is a deterministic weighted scorer whose weights S.5 Wave B states literally, so
    // mlClient gives it its own value, 'ranked', and this reply stays `live` whether or
    // not the formula ran. The scored-vs-recent-activity distinction is not lost — it
    // is asserted one line down, in meta.ranking, the field that can hold a name.
    eq(out.reply.source, 'live',
      `a weighted scorer does not earn the AI badge (ranking source: ${sp.data.ranking.source})`);
    eq(out.reply.meta && out.reply.meta.ranking, sp.data.ranking.source,
      `and meta.ranking keeps what the badge cannot say: ${sp.data.ranking.source}`);
    check(cards.every((c) => (c.data.matchPct != null) === ranked),
      ranked ? 'a ranked answer carries a match percentage'
        : 'an UNRANKED answer carries no percentage — no fabricated numbers');
    if (!ranked) {
      check(out.reply.text.includes('activity') || out.reply.text.includes('unavailable'),
        'and the sentence admits the ranker was unavailable', out.reply.text);
    }
    check(cards.every((c) => String(c.data.id) !== String(player.id)),
      'and never suggests the asker to themselves');
    const ids = new Set(list.slice(0, actions.TOP_PEOPLE).map((x) => String(x.userId)));
    check(cards.every((c) => ids.has(String(c.data.id))),
      'and every card is a player the ranking service actually returned');
  }

  const fp = await say(client, { userId: player.id, threadId: thread, action: 'find_players' });
  if (!mine.length) {
    check(/not an admin of any team/i.test(fp.reply.text),
      `no squad → Scout says so instead of inventing players: "${fp.reply.text.slice(0, 60)}"`);
    check((fp.reply.chips || []).some((c) => c.action === 'create_team_help'),
      'and offers the way forward');
  } else if (mine.length > 1) {
    check(/which team/i.test(fp.reply.text),
      `${mine.length} squads → Scout asks which one instead of guessing: "${fp.reply.text}"`);
    const picks = (fp.reply.chips || []).filter((c) => c.action === 'find_players');
    eq(picks.length, Math.min(mine.length, 4), 'one chip per squad, so nobody types a team name');
    const own = new Set(mine.map((t) => String(t.id)));
    check(picks.every((c) => c.args && own.has(String(c.args.teamId))),
      'and every chip carries a team the user really administers');
    const chosen = mine.find((t) => String(t.id) === String(picks[0].args.teamId)) || mine[0];
    const fp2 = await say(client, { userId: player.id, threadId: thread,
      action: 'find_players', args: { teamId: chosen.id } });
    await assertPeopleFor(fp2, chosen.id, chosen.name);
  } else {
    await assertPeopleFor(fp, mine[0].id, mine[0].name);
  }

  if (mine.length) {
    const myTeam = mine[0];
    const fo = await say(client, { userId: player.id, threadId: thread,
      action: 'find_opponents', args: { teamId: myTeam.id } });
    const so = await roster.suggestOpponents(client, { teamId: myTeam.id, userId: player.id });
    const opps = so.ok ? (so.data.opponents || []) : [];
    eq(cardsOf(fo, 'team').length, Math.min(opps.length, actions.TOP_PEOPLE),
      `${opps.length} opponents → ${cardsOf(fo, 'team').length} team cards`);
    check(cardsOf(fo, 'team').every((c) => String(c.data.id) !== String(myTeam.id)),
      'and never offers the team its own squad as an opponent');
    if (opps.length) {
      const oppIds = new Set(opps.slice(0, actions.TOP_PEOPLE).map((o) => String(o.id)));
      check(cardsOf(fo, 'team').every((c) => oppIds.has(String(c.data.id))),
        'every opponent card is one the ranking service returned, in its order');
      // Same rule as find_players: pairing PROXIMITY is arithmetic, not inference,
      // so the badge stays `live` and meta.ranking carries 'ranked' vs 'heuristic'.
      eq(fo.reply.source, 'live',
        'and the badge does not call a weighted mean a model');
      eq(fo.reply.meta && fo.reply.meta.ranking,
        so.data.ranking ? so.data.ranking.source : null,
        `while meta.ranking still names the scorer: ${so.data.ranking && so.data.ranking.source}`);
    }
  }
  return ctx;
}

// ════════════════════════════════════════════════════════════════════════════
// G — THE CHAT ITSELF  (history, new chat, rename, archive, delete, ownership)
// ════════════════════════════════════════════════════════════════════════════

/**
 * The affordances the user asked for by name: "chat history, rename (new name),
 * switch chat, new chat".
 *
 * Two of these checks exist because of bugs this wave actually hit. Message ORDER
 * is one: both rows of a turn are written in the same transaction, so NOW() gives
 * them a byte-identical created_at and ordering by time alone put Scout's answer
 * above the question. PAGINATION is the other: a cursor carrying that timestamp lost
 * its microseconds through node-postgres and skipped a row.
 */
async function conversationG(client, ctx) {
  section('G  threads: new · switch · rename · archive · delete · ownership');
  const { player, players } = ctx;

  const made = await threads.create(client, { userId: player.id });
  if (!check(made.ok, 'a new chat can be started', made.message)) return ctx;
  eq(made.row.title, threads.DEFAULT_TITLE, `it starts as "${threads.DEFAULT_TITLE}"`);
  eq(made.row.assistant_persona, 'player', 'with the player persona by default');
  const t2 = made.row.id;
  const st = threads.readState(made.row.session_state);
  eq(st.intent, null, 'and a clean dialog state');
  eq(st.v, threads.STATE_VERSION, `at state version ${threads.STATE_VERSION}`);

  const first = 'islamabad mein cricket ground chahiye shaam ke liye';
  await say(client, { userId: player.id, threadId: t2, text: first });
  const named = await threads.get(client, { userId: player.id, threadId: t2 });
  eq(named.title, threads.titleFrom(first),
    'the FIRST message names the chat, the way every chat app does');
  check(named.title !== threads.DEFAULT_TITLE && named.title.length <= 42,
    `"${named.title}" — trimmed to fit a phone`);

  const ren = await threads.update(client, { userId: player.id, threadId: t2, title: '  Pindi  plans  ' });
  eq(ren.ok && ren.row.title, 'Pindi plans', 'a rename squashes whitespace and sticks');
  await say(client, { userId: player.id, threadId: t2, text: 'wallet balance batao' });
  eq((await threads.get(client, { userId: player.id, threadId: t2 })).title, 'Pindi plans',
    'and a later message does NOT overwrite a name the user chose');
  eq((await threads.update(client, { userId: player.id, threadId: t2, title: '   ' })).code,
    'bad_title', 'an empty rename is refused');

  const open = await threads.list(client, { userId: player.id, limit: 30 });
  const stamp = (r) => new Date(r.last_message_at || r.created_at).getTime();
  eq(String(open[0].id), String(t2), 'the chat just used is at the TOP of the list');
  check(open.every((r, i) => i === 0 || stamp(open[i - 1]) >= stamp(r)),
    'the list is ordered newest-activity-first, the order the chat drawer shows');
  check(open.every((r) => r.archived_at === null), 'and it holds only open chats');
  check(open.length >= 2, `${open.length} chats listed — switching between them is just an id`);

  // ── the ordering bug, asserted ────────────────────────────────────────────
  const hAll = await threads.history(client, { userId: player.id, threadId: t2, limit: 100 });
  check(hAll.messages.length >= 4, `${hAll.messages.length} messages stored in this chat`);
  const firstPair = hAll.messages.slice(0, 2);
  eq(firstPair[0] && firstPair[0].role, 'user', 'the QUESTION is the first bubble');
  eq(firstPair[1] && firstPair[1].role, 'scout', 'and Scout\'s answer is the second');
  eq(firstPair[0] && firstPair[0].text, first, 'the question is stored verbatim');
  check(hAll.messages.every((m, i) => i === 0 || m.role !== hAll.messages[i - 1].role),
    'user and Scout strictly alternate — no bubble is out of order anywhere');
  const gap = new Date(firstPair[1].createdAt).getTime() - new Date(firstPair[0].createdAt).getTime();
  check(gap >= 0,
    `the answer is stamped AFTER the question, never before (${gap}ms apart - the model call sits between them)`);
  // Both halves of the guarantee are asserted, because each covers what the other
  // cannot. The behaviour above proves the rows come back in the right order; the
  // source below proves the SORT KEY still breaks a tie by kind — which is what
  // saves the render when two rows do land in the same microsecond, and what the
  // driver could never distinguish anyway, since node-postgres truncates a
  // timestamptz to milliseconds.
  const tsrc = fs.readFileSync(path.join(__dirname, '..', 'services', 'assistantThreads.js'), 'utf8');
  check(tsrc.includes("ORDER BY m.created_at DESC, (m.kind = 'assistant') DESC, m.id DESC"),
    'a tie on time is broken by kind, so a question can never render under its own answer');
  check(tsrc.includes("(m.kind = 'assistant')::int, m.id) <"),
    'and the pagination cursor compares the SAME three fields it sorts by');

  const withCards = hAll.messages.filter((m) => m.role === 'scout' && m.payload);
  check(withCards.length >= 1, 'old Scout turns keep their payload, so scrolling back re-renders cards');
  check(withCards.every((m) => replyUtil.SOURCE_VALUES.includes(m.payload.source)),
    'and every stored payload still carries a legal answer.source');

  // ── the pagination bug, asserted ──────────────────────────────────────────
  const full = hAll.messages.map((m) => String(m.id));
  const walked = [];
  let cursor = null;
  let pages = 0;
  for (;;) {
    const pg = await threads.history(client, { userId: player.id, threadId: t2, limit: 2, before: cursor });
    walked.unshift(...pg.messages.map((m) => String(m.id)));
    pages += 1;
    cursor = pg.cursor;
    if (!pg.hasMore || !cursor || pages > 40) break;
  }
  check(pages >= 2, `${pages} pages of 2 walked back through the chat`);
  eq(walked.join('|'), full.join('|'),
    'paging 2-at-a-time returns EVERY message exactly once, in the same order as one big read');
  eq(new Set(walked).size, walked.length, 'no message is served twice by two pages');
  const junk = await threads.history(client, { userId: player.id, threadId: t2, limit: 2, before: 'page-2-plz' });
  eq(junk.messages.map((m) => String(m.id)).join('|'),
    full.slice(-2).join('|'), 'a junk cursor from a client is treated as "no cursor", not an error');

  // ── archive, delete, and the cap ──────────────────────────────────────────
  const arch = await threads.update(client, { userId: player.id, threadId: t2, archived: true });
  check(arch.ok && arch.row.archived_at !== null, 'a chat can be archived');
  const afterArch = await threads.list(client, { userId: player.id, limit: 50 });
  check(!afterArch.some((r) => String(r.id) === String(t2)), 'archiving hides it from the chat list');
  const withArch = await threads.list(client, { userId: player.id, includeArchived: true, limit: 50 });
  check(withArch.some((r) => String(r.id) === String(t2)), 'but it is still there when asked for');
  check(await threads.get(client, { userId: player.id, threadId: t2 }) !== null,
    'and its messages are NOT destroyed — archive is not delete');
  await threads.update(client, { userId: player.id, threadId: t2, archived: false });
  check((await threads.list(client, { userId: player.id, limit: 50 }))
    .some((r) => String(r.id) === String(t2)), 'unarchiving brings it back');

  const doomed = await threads.create(client, { userId: player.id });
  await say(client, { userId: player.id, threadId: doomed.row.id, text: 'mera wallet dikhao' });
  const before = (await client.query('SELECT count(*)::int n FROM chat_messages WHERE channel_id = $1',
    [doomed.row.id])).rows[0].n;
  check(before >= 2, `${before} messages written into the chat about to be deleted`);
  const del = await threads.remove(client, { userId: player.id, threadId: doomed.row.id });
  check(del.ok, 'the user can delete a chat');
  eq(await threads.get(client, { userId: player.id, threadId: doomed.row.id }), null, 'and it is gone');
  eq((await client.query('SELECT count(*)::int n FROM chat_messages WHERE channel_id = $1',
    [doomed.row.id])).rows[0].n, 0,
  'its messages are gone with it — deleting a chat really deletes what was said in it');
  eq((await threads.remove(client, { userId: player.id, threadId: doomed.row.id })).code,
    'thread_not_found', 'deleting it twice is a clean 404, not a crash');

  const openNow = (await client.query(
    `SELECT count(*)::int n FROM chat_channels
      WHERE type = 'assistant' AND created_by = $1 AND archived_at IS NULL`, [player.id])).rows[0].n;
  const room = threads.MAX_THREADS - openNow;
  const filler = [];
  for (let i = 0; i < room; i += 1) {
    const r = await threads.create(client, { userId: player.id, title: `filler ${i}` });
    if (r.ok) filler.push(r.row.id);
  }
  const overflow = await threads.create(client, { userId: player.id });
  eq(overflow.code, 'too_many_threads',
    `chat ${threads.MAX_THREADS + 1} is refused instead of letting the drawer grow forever`);
  eq(overflow.status, 409, 'with a 409, and a sentence telling the user to archive one');
  check(/archive/i.test(overflow.message || ''), `"${overflow.message}"`);
  await threads.update(client, { userId: player.id, threadId: filler[0], archived: true });
  const freed = await threads.create(client, { userId: player.id });
  check(freed.ok, 'and archiving one frees the slot, exactly as that sentence promised');
  // Put the drawer back: the cap test is the only place this script manufactures
  // rows, and leaving 50 of them would starve every later stage of a new thread.
  if (freed.ok) filler.push(freed.row.id);
  for (const id of filler) await threads.remove(client, { userId: player.id, threadId: id });
  const cleaned = (await client.query(
    `SELECT count(*)::int n FROM chat_channels
      WHERE type = 'assistant' AND created_by = $1 AND archived_at IS NULL`, [player.id])).rows[0].n;
  check(cleaned < threads.MAX_THREADS, `${cleaned} chats left after the cap test cleaned up after itself`);

  // ── ownership: a thread id is not a capability ────────────────────────────
  const other = players.find((p) => String(p.id) !== String(player.id));
  if (!other) {
    skip('another user cannot read this chat', 'only one player fixture available');
  } else {
    eq(await threads.get(client, { userId: other.id, threadId: t2 }), null,
      'another user asking for this chat by id gets NOTHING back');
    const stolen = await threads.history(client, { userId: other.id, threadId: t2, limit: 50 });
    eq(stolen.messages.length, 0, 'and no messages — ownership is re-checked in the JOIN, not trusted');
    eq((await threads.update(client, { userId: other.id, threadId: t2, title: 'mine now' })).code,
      'thread_not_found', 'they cannot rename it');
    eq((await threads.remove(client, { userId: other.id, threadId: t2 })).code,
      'thread_not_found', 'they cannot delete it');
    const intruded = await say(client, { userId: other.id, threadId: t2, text: 'wallet balance' });
    eq(intruded.code, 'thread_not_found', 'and they cannot post into it either');
    eq(intruded.status, 404, 'a 404, which does not even confirm the chat exists');
    eq((await threads.get(client, { userId: player.id, threadId: t2 })).title, 'Pindi plans',
      'the owner\'s chat is untouched by all of that');
  }

  const noThread = await say(client, { userId: player.id, threadId: null, text: 'kya kar sakte ho' });
  check(noThread.ok && noThread.threadId, 'a client that sends no chat id still gets an answer');
  check(noThread.reply && noThread.reply.text, 'in the newest open chat, or a fresh one');
  const asOwner = await threads.create(client, { userId: ctx.owner.id, persona: 'owner' });
  eq(asOwner.ok && asOwner.row.assistant_persona, 'owner',
    'an owner\'s chat is marked owner — same Scout, different side of the ground');
  return ctx;
}

// ════════════════════════════════════════════════════════════════════════════
// H — FR8.15: ONE IMPLEMENTATION, AND THE S.5 READS STILL WORK THROUGH IT
// ════════════════════════════════════════════════════════════════════════════

/** Every .js file under src/, so a rule can be counted across the whole tree. */
function srcFiles(dir, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, e.name);
    // scripts/ is verification code, not production code, and THIS file quotes the
    // very SQL it is counting -- scanning it would count the assertion as a caller.
    if (e.isDirectory() && e.name !== 'scripts') srcFiles(full, out);
    else if (e.isFile() && e.name.endsWith('.js')) out.push(full);
  }
  return out;
}

function countIn(files, re) {
  const hits = [];
  for (const f of files) {
    const body = fs.readFileSync(f, 'utf8');
    const m = body.match(re);
    if (m) hits.push({ file: path.relative(path.join(__dirname, '..', '..'), f).split(path.sep).join('/'), n: m.length });
  }
  return hits;
}

/**
 * The requirement in one sentence: a rule about money or ranking may exist ONCE.
 * The assistant is not allowed a second copy that drifts. This is asserted by
 * counting, across every file under src/, and by calling the shared read services
 * with the arguments the REST routes pass them.
 */
async function conversationH(client, ctx) {
  section('H  FR8.15 — one implementation of every rule, shared by route and Scout');
  const { player, owner } = ctx;
  const files = srcFiles(path.join(__dirname, '..'));
  check(files.length > 20, `${files.length} source files scanned`);

  const inserts = countIn(files, /INSERT INTO bookings/g);
  eq(inserts.length, 1, 'exactly ONE file in the whole backend inserts a booking');
  eq(inserts[0] && inserts[0].file, 'src/services/bookingService.js',
    'and it is the shared service, not a route and not the assistant');
  eq(inserts[0] && inserts[0].n, 1, 'written once inside it, not twice');
  ev.addFact('FR8.15 holds by census, not by assertion',
    `\`INSERT INTO bookings\` appears in exactly ${inserts.length} of ${files.length} backend source `
    + 'files (`services/bookingService.js`), and `assistantActions.js` contains none of the six money '
    + 'primitives. Scout prepares; the shared service spends.');

  const scout = path.join(__dirname, '..', 'services', 'assistantActions.js');
  const scoutBody = fs.readFileSync(scout, 'utf8');
  for (const [name, re] of [
    ['insert a booking', /INSERT INTO bookings/],
    ['move a wallet', /applyWallet\s*\(/],
    ['write a ledger row', /logTxn\s*\(/],
    ['split a penalty', /penaltySplit\s*\(/],
    ['lock a wallet', /lockWallet\s*\(/],
    ['free a slot', /UPDATE slots SET status/i],
  ]) {
    check(!re.test(scoutBody), `Scout cannot ${name} — it has no such code at all`);
  }
  check(/require\(['"]\.\/bookingService['"]\)/.test(scoutBody),
    'it goes through bookingService for all of it');

  const routeBody = fs.readFileSync(path.join(__dirname, '..', 'routes', 'bookings.js'), 'utf8');
  check(/createBookingTx/.test(routeBody) && /cancelBookingTx/.test(routeBody),
    'the REST route calls the same two functions Scout calls');
  const upTo = routeBody.slice(0, routeBody.indexOf('/:id/resolve'));
  check(!/applyWallet\s*\(/.test(upTo),
    'and books/cancels without touching a wallet itself — transport only');
  check(/penaltySplit/.test(routeBody),
    'the owner-settle route keeps its own ledger, which Scout does not expose (not duplicated logic)');

  // ── the S.5 reads, called the way the REST routes call them ───────────────
  const vList = await discovery.searchVenues(client, { limit: 12 });
  check(vList.length > 0, `searchVenues returns ${vList.length} grounds for GET /api/venues`);
  check(vList.every((v) => v.is_active === true), 'only active grounds, as the venue list page needs');
  check(vList.every((v) => 'cover_photo' in v && 'owner_name' in v),
    'with the cover photo and owner name the card renders — the response bytes did not change');
  const rated = vList.map((v) => asNum(v.rating) || 0);
  check(rated.every((r, i) => i === 0 || rated[i - 1] >= r),
    'default order is still rating-first (NULLS LAST), the S.5 Wave A ordering');
  const cheap = await discovery.searchVenues(client, { sort: 'price_low', limit: 6 });
  const prices = cheap.map((v) => asNum(v.price_per_hour) || 0);
  check(prices.every((p, i) => i === 0 || prices[i - 1] <= p), 'and sort=price_low still sorts');
  eq((await discovery.searchVenues(client, { sport: 'no-such-sport' })).length, 0,
    'a filter that matches nothing returns an empty list, not everything');

  const vid = ctx.venueId || vList[0].id;
  const past = await discovery.venueDetail(client, { venueId: vid, userId: player.id, date: '2020-01-01' });
  check(past.ok && past.data.slots.length === 0,
    'a ground asked about a PAST date answers with no slots rather than an error');
  const fut = await discovery.venueDetail(client, { venueId: vid, userId: player.id, date: ctx.tomorrow });
  check(fut.ok && Array.isArray(fut.data.slots), `and tomorrow lists ${fut.data.slots.length} slots`);
  eq((await discovery.venueDetail(client, { venueId: 'not-a-uuid', userId: player.id })).code,
    'bad_venue', 'a junk ground id is a 400 with a human sentence');
  eq((await discovery.venueDetail(client, { venueId: ctx.deadUuid, userId: player.id })).code,
    'venue_not_found', 'and an unknown one is a 404');

  const teamsFor = await discovery.discoverTeams(client, { userId: player.id, limit: 20 });
  check(teamsFor.ok && Array.isArray(teamsFor.data),
    `discoverTeams answers GET /api/teams/discover with ${(teamsFor.data || []).length} teams`);
  const trn = await discovery.listTournaments(client, { limit: 5 });
  check(Array.isArray(trn), `listTournaments answers the tournaments list (${trn.length} open)`);

  if (!ctx.adminTeam) {
    skip('the ranking services answer through the shared path', 'no team fixture with an admin');
  } else {
    const sp = await roster.suggestPlayers(client, { teamId: ctx.adminTeam.id, userId: ctx.adminTeam.adminId });
    check(sp.ok, `suggestPlayers answers for GET /api/teams/:id/suggest-players (${sp.message || 'ok'})`);
    check(sp.data && Array.isArray(sp.data.suggestions),
      `with a suggestions array (${sp.data && (sp.data.suggestions || []).length} players)`);
    check(sp.data && sp.data.ranking && typeof sp.data.ranking.available === 'boolean',
      `and an honest model flag — ranking.available=${sp.data && sp.data.ranking && sp.data.ranking.available}`);
    const so = await roster.suggestOpponents(client, { teamId: ctx.adminTeam.id, userId: ctx.adminTeam.adminId });
    check(so.ok, 'suggestOpponents answers for the opponent finder too');
    check(so.data && Array.isArray(so.data.opponents),
      `with an opponents array (${so.data && (so.data.opponents || []).length} teams)`);
    if (!ctx.adminTeam.outsiderId) {
      skip('a non-member is refused by the service', 'every fixture user is on that team');
    } else {
      eq((await roster.suggestPlayers(client,
        { teamId: ctx.adminTeam.id, userId: ctx.adminTeam.outsiderId })).code,
      'forbidden', 'a non-admin is refused by the SERVICE, not by the route — so Scout is refused too');
    }
    eq((await roster.suggestOpponents(client, { teamId: 'nope', userId: player.id })).code,
      'bad_team', 'a junk team id is rejected with the same words for both callers');
  }

  // ── privacy: the telemetry cannot become a transcript ──────────────────────
  const cols = (await client.query(
    `SELECT column_name, data_type FROM information_schema.columns
      WHERE table_name = 'assistant_turns' ORDER BY ordinal_position`)).rows;
  check(cols.length > 0, `assistant_turns has ${cols.length} columns of telemetry`);
  const texty = cols.filter((c) => /char|text|json/.test(c.data_type)
    && !['input_mode', 'intent', 'abstain_reason', 'model_version', 'action',
      'answer_source', 'fsm_state', 'error_code'].includes(c.column_name));
  eq(texty.map((c) => c.column_name).join(','), '',
    'and not one free-text column that could hold what the user typed');
  ev.addFact('The telemetry cannot become a transcript',
    `\`assistant_turns\` has ${cols.length} columns and not one of them can hold what the user typed `
    + '(`text_chars int` records the length only), which is also the property an external rephrasing '
    + 'API would have reversed -- see the Wave S6-E decision in PROGRESS.md.');
  check(cols.some((c) => c.column_name === 'text_chars'),
    'the length is logged instead — enough to study long questions, useless as a transcript');
  const said = 'yahan ka refund kaisay milta hai bhai';
  const t3 = await threads.create(client, { userId: player.id });
  await say(client, { userId: player.id, threadId: t3.row.id, text: said });
  const leaked = (await client.query(
    `SELECT count(*)::int n FROM assistant_turns
      WHERE channel_id = $1 AND text_chars = $2`, [t3.row.id, said.length])).rows[0].n;
  check(leaked >= 1, 'the turn WAS logged — with its length, its intent and its confidence');
  const inThread = (await client.query(
    `SELECT count(*)::int n FROM chat_messages WHERE channel_id = $1 AND body = $2`,
    [t3.row.id, said])).rows[0].n;
  eq(inThread, 1, 'and the sentence itself lives in exactly ONE place: the user\'s own chat');
  await threads.remove(client, { userId: player.id, threadId: t3.row.id });
  eq((await client.query('SELECT count(*)::int n FROM chat_messages WHERE body = $1', [said])).rows[0].n, 0,
    'so deleting the chat really does erase it — nothing else kept a copy');
  check((await client.query(
    `SELECT count(*)::int n FROM assistant_turns WHERE channel_id IS NULL`)).rows[0].n >= 1,
  'while the telemetry survives with a NULL channel — measurable, and no longer linked to a chat');
  return ctx;
}

// ════════════════════════════════════════════════════════════════════════════
// THE CAST'S SUPPORTING ROLES
// ════════════════════════════════════════════════════════════════════════════

/** A day after PKT today, as YYYY-MM-DD — the date every "kal" assertion uses. */
// ════════════════════════════════════════════════════════════════════════════
// I — THE MILESTONE LINE  ("kal shaam football islamabad" → a booked row)
// ════════════════════════════════════════════════════════════════════════════

/**
 * The first line of the S.6 acceptance checklist, run as one continuous chain
 * instead of argued from two halves that touch.
 *
 * Everything here is already covered: A books through the picker, and the HTTP
 * check parses this exact sentence. What was NOT covered is the JOIN — that the
 * committee's own utterance, with its Roman-Urdu date and no venue id anywhere in
 * it, reaches a row in `bookings` with the ledger behind it. So this drives the
 * sentence and then taps only what Scout painted: the card's See-times button, the
 * picker's first slot, the confirm card's Yes. No fixture id is used, and the date
 * is never computed here — if the extractor read "kal" wrongly the picker is for
 * the wrong day and the assertion below says so.
 *
 * It runs LAST on purpose. It spends real balance, and every earlier section
 * asserts against a wallet it measured itself, so a second booking must not land
 * in the middle of them. The whole run is one rolled-back transaction regardless.
 */
async function conversationI(client, ctx) {
  section('I  the milestone utterance — "kal shaam football islamabad", end to end');
  const { player } = ctx;
  const said = 'kal shaam football islamabad';

  const i1 = await say(client, { userId: player.id, text: said });
  const thread = i1.threadId;
  eq(i1.nlu && i1.nlu.intent, 'find_venue', `"${said}" → find_venue`);
  check(['live', 'model'].includes(i1.reply.source),
    `answered rather than sent to the abstain menu (source ${i1.reply.source})`);
  check(i1.nlu && i1.nlu.via === 'model' && i1.nlu.confidence > 0,
    `and it was the MODEL that read it, not a chip (${i1.nlu && i1.nlu.confidence})`);
  const slots = (i1.state && i1.state.slots) || {};
  eq(slots.sport, 'football', 'the sport came out of the sentence, not out of a fixture');
  eq(slots.date, ctx.tomorrow, `"kal" resolved to tomorrow in PKT (${ctx.tomorrow})`);
  eq(slots.time, '18:00', 'and "shaam" reached the slots as the 18:00-21:00 window start');
  check(String(slots.area || '').toLowerCase().includes('islamabad'),
    `and the city survived the parse (${slots.area || 'none'})`);
  const cards = cardsOf(i1, 'venue');
  if (!check(cards.length > 0, `Scout offered grounds to tap (${cards.length})`, i1.reply.text)) return ctx;
  check(cards.every((c) => String(c.data.sport || '').toLowerCase() === 'football'),
    'every ground offered is a football ground', cards.map((c) => c.data.sport).join(','));

  // Tap See-times on each offered card until one has a free slot. A full ground is
  // not a failure of the chain -- it is what the next card is for.
  const seen = [];
  let picker = null; let target = null;
  for (const c of cards) {
    const b = (c.data.buttons || []).find((x) => x.action === 'check_availability');
    if (!b) continue;
    const turn = await say(client, { userId: player.id, threadId: thread,
      action: b.action, args: b.args || { venueId: c.data.id } });
    const p = cardsOf(turn, 'slot_picker')[0];
    seen.push(`${c.data.name}: ${p ? `${p.data.slots.length} free` : 'none'}`);
    if (p && p.data.slots.length) { picker = p; target = c; break; }
  }
  if (!picker) return skip('the milestone chain', `no free slot on ${ctx.tomorrow} — ${seen.join(' · ')}`);
  eq(String(picker.data.venueId), String(target.data.id), 'the picker is for the ground that was tapped');
  eq(picker.data.date, ctx.tomorrow,
    `and for the day the utterance asked for, not for today (${picker.data.date})`);

  const pick = picker.data.buttons[0];
  const i3 = await say(client, { userId: player.id, threadId: thread,
    action: 'pick_slot', args: pick.args });
  const conf = cardsOf(i3, 'confirm')[0];
  if (!check(!!conf, 'tapping a time arms a confirm card', i3.reply.text)) return ctx;
  const price = asNum(picker.data.slots[0].price);
  eq(conf.data.what, 'book_venue', 'armed for book_venue');
  eq(asNum(conf.data.total), price, 'quoting the price the picker showed');

  const purse = await walletOf(client, player.id);
  if (purse.balance < price) {
    return skip('the milestone booking', `wallet has ${purse.balance}, the slot costs ${price}`);
  }
  const yes = (conf.data.buttons || []).find((b) => b.action === 'confirm');
  const i4 = await say(client, { userId: player.id, threadId: thread, action: yes.action });
  check(i4.reply.actionOk === true && i4.reply.action === 'book_venue',
    `the chain ends in a booking: "${i4.reply.text.slice(0, 80)}"`,
    JSON.stringify({ ok: i4.reply.actionOk, action: i4.reply.action }));
  const bcard = cardsOf(i4, 'booking')[0];
  if (!check(!!bcard, 'and a booking card to show for it')) return ctx;

  const row = await bookingRow(client, bcard.data.id);
  if (!check(!!row, 'THE BOOKING EXISTS — the checklist line, as a row')) return ctx;
  eq(String(row.slot_id), String(pick.args.slotId), 'it is the slot that was tapped');
  eq(String(row.player_id), String(player.id), 'booked for the player who typed the sentence');
  eq(String(row.venue_id), String(target.data.id), 'at the ground Scout offered');
  eq(asNum(row.total_amount), price, 'for the quoted price');
  eq(asNum(row.deposit_amount), depositFor(price), 'with the POLICY deposit held');
  eq(row.slot_status, 'booked', 'and the slot is no longer on sale');
  const when = await client.query('SELECT slot_date::text d FROM slots WHERE id = $1', [row.slot_id]);
  eq(when.rows[0].d, ctx.tomorrow, 'ON THE DAY "kal" MEANT — the whole point of the Roman-Urdu parse');

  const after = await walletOf(client, player.id);
  eq(after.balance, round2(purse.balance - price),
    `the ledger is correct: balance fell by the price (${purse.balance} → ${after.balance})`);
  eq(after.frozen, round2(purse.frozen + price), 'the same money sits in escrow, not nowhere');
  eq(round2(after.balance + after.frozen), round2(purse.balance + purse.frozen),
    'and nothing was minted or burned on the way');
  const txns = await txnsFor(client, row.id);
  const pay = txns.find((t) => t.type === 'booking_payment');
  if (check(!!pay, `one booking_payment row in the ledger (${txns.map((t) => t.type).join(',')})`)) {
    eq(pay.amount, round2(-price), 'for the negative of the price');
    eq(pay.balance_after, after.balance, 'and balance_after matches the wallet the user will see');
  }
  return ctx;
}

function pktTomorrow(now) {
  const d = new Date(`${now.date}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + 1);
  return d.toISOString().slice(0, 10);
}

/**
 * A team the cast player administers, whoever administers one otherwise, plus a
 * player who is NOT on it — the negative case for the ranking services. Returns
 * null when the seed has no team with a captain, which is a skip and not a failure.
 */
async function adminTeamFor(client, playerId) {
  const { rows } = await client.query(
    `SELECT t.id, t.name, m.user_id AS admin_id
       FROM team_members m JOIN teams t ON t.id = m.team_id
      WHERE m.role IN ('captain', 'vice_captain')
      ORDER BY (m.user_id = $1) DESC, t.elo DESC NULLS LAST
      LIMIT 1`,
    [playerId],
  );
  if (!rows.length) return null;
  const { rows: out } = await client.query(
    `SELECT u.id FROM users u
      WHERE u.role = 'player' AND u.is_active
        AND NOT EXISTS (SELECT 1 FROM team_members m
                         WHERE m.team_id = $1 AND m.user_id = u.id)
      LIMIT 1`,
    [rows[0].id],
  );
  return { id: rows[0].id, name: rows[0].name, adminId: rows[0].admin_id,
    outsiderId: out.length ? out[0].id : null };
}

// ════════════════════════════════════════════════════════════════════════════
// MAIN
// ════════════════════════════════════════════════════════════════════════════

/**
 * Everything runs inside ONE transaction that is ALWAYS rolled back, so a full
 * verification run leaves the seeded database byte-identical: no test booking to
 * explain in the demo, no drained wallet, no orphan chat. The turns still see their
 * own writes, because they run on this client — that is what the `client` parameter
 * on handleTurn exists for.
 */
async function main() {
  console.log('\nSCOUT — WAVE C VERIFICATION');
  console.log('every assertion below is stated against the service it must agree with,');
  console.log('and the whole run is rolled back at the end.\n');

  const client = await pool.connect();
  let fatal = null;
  try {
    await client.query('BEGIN');

    if (!(await preflight(client))) {
      failures.push('preflight');
    } else {
      const fx = await pickFixtures(client);
      fx.cast = castFrom(fx);
      if (!fx.cast.player || !fx.cast.venue) {
        failures.push('no usable fixture: need one active venue with a free slot today and one player wallet');
      } else {
        const { rows: [ownerRow] } = await client.query(
          'SELECT id, name FROM users WHERE id = $1', [fx.cast.venue.owner_id],
        );
        const extras = {
          players: fx.players,
          owner: ownerRow || { id: fx.cast.venue.owner_id, name: 'owner' },
          venueId: fx.cast.venue.id,
          fxVenueIds: fx.venues.map((v) => String(v.id)),
          today: fx.now.date,
          tomorrow: pktTomorrow(fx.now),
          deadUuid: '00000000-0000-4000-8000-000000000000',
          adminTeam: await adminTeamFor(client, fx.cast.player.id),
        };
        console.log(`\n  cast: ${fx.cast.player.name} (PKR ${fx.cast.player.balance}) `
          + `· ${fx.cast.venue.name} (${fx.cast.venue.free_today} free today, from PKR ${fx.cast.venue.cheapest}) `
          + `· owner ${extras.owner.name}`
          + (extras.adminTeam ? ` · team ${extras.adminTeam.name}` : ' · no team fixture'));

        let ctx = { ...(await conversationA(client, fx)), ...extras };
        ctx = await bookingHalf(client, ctx);
        ctx = await confirmHalf(client, ctx);
        ctx = await moneyAudit(client, ctx);
        ctx = await conversationB(client, ctx);
        ctx = await cancelHalf(client, ctx);
        ctx = await cancelLedger(client, ctx);
        ctx = await conversationC(client, ctx);
        ctx = await conversationC2(client, ctx);
        ctx = await conversationD(client, ctx);
        ctx = await conversationE(client, ctx);
        ctx = await conversationE2(client, ctx);
        ctx = await conversationF(client, ctx);
        ctx = await conversationG(client, ctx);
        await conversationH(client, ctx);
        await conversationI(client, ctx);
      }
    }
  } catch (err) {
    fatal = err;
  } finally {
    await client.query('ROLLBACK').catch(() => {});
    client.release();
    await pool.end().catch(() => {});
  }

  if (fatal) {
    console.log(`\n  ✗ the run stopped on an exception: ${fatal.message}`);
    console.log(fatal.stack ? fatal.stack.split('\n').slice(1, 6).join('\n') : '');
    failures.push(`exception: ${fatal.message}`);
  }

  console.log(`\n${'═'.repeat(72)}`);
  if (transcript.length) {
    console.log(`\nWHAT SCOUT WAS ACTUALLY SAID, AND WHAT IT SAID BACK (${transcript.length} turns)`);
    for (const t of transcript) {
      const badge = t.intent ? `${t.intent}${t.conf ? ` ${t.conf}` : ''}` : 'chip';
      console.log(`  ${String(t.said).slice(0, 46).padEnd(46)} ${badge.padEnd(24)} ${t.source || '-'}`);
      console.log(`     ${t.said_back}`);
    }
  }

  const total = passed + failures.length;
  if (ev.on) {
    const w = await ev.write({ passed, failed: failures.length, skipped: skips.length });
    if (w) console.log(`  evidence written to ${path.relative(process.cwd(), w.path)} (${w.lines} lines)`);
  }
  console.log(`\n${'═'.repeat(72)}`);
  if (skips.length) {
    console.log(`\n${skips.length} skipped (the seed could not supply the case):`);
    for (const s of skips) console.log(`  ~ ${s}`);
  }
  if (failures.length) {
    console.log(`\nFAIL ${passed}/${total}\n`);
    for (const f of failures) console.log(`  ✗ ${f}`);
    console.log('\nnothing was written: the transaction was rolled back.\n');
    process.exit(1);
  }
  console.log(`\nPASS ${passed}/${total}`);
  console.log('the transaction was rolled back — the database is exactly as it was.\n');
}

main().catch(async (err) => {
  console.error('\n✗ check_assistant crashed outside the transaction:', err);
  await pool.end().catch(() => {});
  process.exit(1);
});
