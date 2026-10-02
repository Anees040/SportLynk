/**
 * check_scout_context.js — the three context bugs reported from the phone, driven as
 * REAL turns against the live database and then rolled back.
 *
 * Why real turns: each of these is about what the dialog manager REMEMBERS between
 * turns, and session_state only exists in the database. A stub would be testing the
 * stub. handleTurn accepts an injected client precisely so a verification run can take
 * the SAVEPOINT path, so everything here happens inside one transaction that is rolled
 * back at the end — no thread, message, booking or telemetry row survives.
 *
 * It proves, or fails to prove, three things:
 *   1. a new session starts with EMPTY state (no ground carried from the last chat)
 *   2. "koi or ground" after choosing a ground browses OTHER grounds
 *   3. a stale Confirm tap says the confirmation was already answered, not that
 *      nothing was held
 *
 * Usage:  node src/scripts/check_scout_context.js
 * Needs:  a reachable database. ml-service is optional — where a typed sentence needs
 *         the classifier, the check says so instead of silently passing.
 */
const pool = require('../db/pool');
const dialog = require('../services/dialogManager');
const threads = require('../services/assistantThreads');

let passed = 0;
let failed = 0;

function check(name, ok, detail = '') {
  if (ok) {
    passed += 1;
    console.log(`  ✓ ${name}`);
  } else {
    failed += 1;
    console.error(`  ✗ ${name}${detail ? ` — ${detail}` : ''}`);
  }
}

async function aPlayer(client) {
  const { rows } = await client.query(
    `SELECT id, name FROM users WHERE role = 'player' ORDER BY created_at LIMIT 1`,
  );
  return rows[0] || null;
}

async function aVenue(client) {
  const { rows } = await client.query(
    `SELECT id, name, sport_type FROM venues WHERE is_active = true ORDER BY created_at LIMIT 1`,
  );
  return rows[0] || null;
}

async function main() {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    const user = await aPlayer(client);
    const venue = await aVenue(client);
    if (!user || !venue) {
      console.error('No player or no active venue in the database — nothing to drive.');
      process.exitCode = 1;
      return;
    }
    console.log(`player: ${user.name}   venue: ${venue.name}\n`);

    // 1. A ground is chosen in chat A, then chat B is started fresh.
    console.log('1. a new chat does not inherit the last chat\'s ground');
    const a1 = await dialog.handleTurn({
      userId: user.id, client,
      action: 'venue_info', args: { venueId: venue.id }, text: 'Ground details',
    });
    check('chat A: a ground chip resolves', a1.ok, a1.message || '');
    const threadA = a1.threadId;
    const stateA = await threads.get(client, { userId: user.id, threadId: threadA });
    const slotsA = threads.readState(stateA.session_state).slots || {};
    check('chat A now carries that ground in its session',
      String(slotsA.venueId || '') === String(venue.id),
      `slots.venueId=${slotsA.venueId}`);

    const b1 = await dialog.handleTurn({
      userId: user.id, client, newSession: true,
      action: 'capability_menu', text: 'What can you do?',
    });
    check('chat B is a different thread', b1.ok && b1.threadId !== threadA,
      `A=${threadA} B=${b1.threadId}`);
    const stateB = await threads.get(client, { userId: user.id, threadId: b1.threadId });
    const slotsB = threads.readState(stateB.session_state).slots || {};
    check('chat B carries NO ground from chat A',
      !slotsB.venueId && !slotsB.venueName,
      `slots=${JSON.stringify(slotsB)}`);

    // 2. "koi or ground" after choosing a ground must browse others.
    console.log('\n2. "koi or ground" browses other grounds');
    const c1 = await dialog.handleTurn({
      userId: user.id, client, newSession: true,
      action: 'venue_info', args: { venueId: venue.id }, text: 'Ground details',
    });
    const threadC = c1.threadId;
    const c2 = await dialog.handleTurn({
      userId: user.id, client, threadId: threadC, text: 'koi or ground',
    });
    check('the turn is answered', c2.ok, c2.message || '');
    const intentC = c2.nlu ? c2.nlu.intent : null;
    check('it is treated as find_venue, whatever the classifier said',
      (c2.state && c2.state.intent === 'find_venue') || intentC === 'find_venue'
        || (c2.reply && c2.reply.action === 'find_venue'),
      `state.intent=${c2.state && c2.state.intent} nlu=${intentC} action=${c2.reply && c2.reply.action}`);
    const stateC = await threads.get(client, { userId: user.id, threadId: threadC });
    const slotsC = threads.readState(stateC.session_state).slots || {};
    check('the ground it was trying to get away from is dropped',
      String(slotsC.venueId || '') !== String(venue.id),
      `slots.venueId=${slotsC.venueId}`);

    // 3. A stale Confirm tap.
    console.log('\n3. a stale Confirm tap is honest about what happened');
    const d1 = await dialog.handleTurn({
      userId: user.id, client, newSession: true,
      action: 'confirm', text: 'Confirm',
    });
    check('the turn is answered rather than erroring', d1.ok, d1.message || '');
    const said = (d1.reply && d1.reply.text) || '';
    check('it does NOT claim nothing was held', !/not holding anything/i.test(said), said);
    check('it says the confirmation was already answered', /already answered/i.test(said), said);
    check('it offers the bookings list as the record',
      !!(d1.reply && d1.reply.chips || []).find((c) => c.action === 'my_bookings'), said);

    console.log(`\n${passed} passed, ${failed} failed`);
    if (failed) process.exitCode = 1;
  } finally {
    // Nothing this script did is kept, pass or fail.
    await client.query('ROLLBACK').catch(() => {});
    client.release();
  }
}

main()
  .catch((err) => { console.error('check crashed:', err.message); process.exitCode = 1; })
  .finally(() => pool.end());
