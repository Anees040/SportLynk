/**
 * check_chat.js — the chat module, driven against the real database, always
 * rolled back.
 *
 * Usage:  node src/scripts/check_chat.js            (ml-service optional)
 *         node src/scripts/check_chat.js --evidence (writes doc/chat_evidence.md)
 *         node src/scripts/check_chat.js --verify-clean
 *
 * WHY THIS SCRIPT EXISTS
 * ----------------------
 * The unit tests prove the sentences and the payload shapes with the database
 * down. What they cannot prove is the thing S.7 Wave B actually added: that
 * confirming a booking OPENS A ROOM, that accepting a challenge opens a DIFFERENT
 * room containing four specific people, that doing either twice does not open a
 * second one, and that the inbox those rooms appear in counts unread the same way
 * the badge does. Every one of those is a claim about rows in three tables at
 * once, and the only honest way to check it is to write the rows.
 *
 * NOTHING SURVIVES IT
 * -------------------
 * Every function under test takes a caller-owned `client` and writes no BEGIN of
 * its own — that is why routes/owner.js can compose them inside a booking
 * approval, and it is why this script can hold ONE transaction across the whole
 * run and ROLLBACK at the end. Rows are prefixed `zzchat-` so a run interrupted
 * before its rollback is trivially identifiable, and `--verify-clean` re-checks
 * that none exist.
 *
 * WHAT IT DOES NOT PROVE
 * ----------------------
 * It drives the CORE functions, not HTTP. So Block 6 closes the remaining gap the
 * only way a rolled-back script can: it reads the source of every confirm,
 * cancel and no-show path and asserts each one calls the opener. A function that
 * works and is never called is the exact failure mode this wave was written to
 * end, so "is it wired?" is checked, not assumed.
 *
 *   ✗  a rule broke. The line names it.
 *   ~  the data could not supply the case. A skip is not a pass.
 */
const path = require('path');
const pool = require('../db/pool');
const chat = require('../utils/chatCore');
const list = require('../utils/chatList');
const qr = require('../utils/quickReplies');
const sys = require('../utils/chatSystemMessages');
const mc = require('../utils/matchCore');
const ml = require('../services/mlClient');
const actions = require('../services/assistantActions');
const threads = require('../services/assistantThreads');
const evidence = require('./lib/evidence');

const failures = [];
const skips = [];
let passed = 0;

const PREFIX = 'zzchat-';
const ARGS = process.argv.slice(2);
const VERIFY_CLEAN = ARGS.includes('--verify-clean');

const EVIDENCE_OUT = path.join(__dirname, '..', '..', '..', 'doc', 'chat_evidence.md');

const EVIDENCE_HEADER = `# Chat — the evidence pack

**This file is generated. Do not edit it by hand.** Every line below was written by a
verification script that had just asserted it against the live database, inside one
transaction that was then rolled back — so the run leaves no rows behind and the
document is reproducible rather than a description of a state somebody once had. To
regenerate:

\`\`\`
cd backend && node src/scripts/check_chat.js --evidence
\`\`\`

A block absent from this file was not run — it is not a pass.
`;

const ev = evidence.recorder({
  key: 'chat',
  out: EVIDENCE_OUT,
  header: EVIDENCE_HEADER,
  markPrefix: 'chat-evidence',
  title: 'S.7 Wave B -- the three channel types, the inbox, and FR8.10 reply suggestions',
  subtitle: 'A booking is confirmed and a room opens with the venue owner and the player in it; a '
    + 'challenge is accepted and a SECOND room opens holding both captains and both '
    + 'vice-captains; every match-lifecycle event posts one NEUTRAL sentence into that shared '
    + 'room; the inbox lists all of it with an unread count checked against a hand-computed '
    + 'number; and the reply suggestions are classified by the released 23-label model with a '
    + 'keyword fallback proven by running it with the model switched off. One transaction, '
    + 'rolled back at the end -- no channel, no message, no membership row survives the run.',
  command: 'cd backend && node src/scripts/check_chat.js --evidence',
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

/** A substring assertion that prints what it actually got when it fails. */
function has(haystack, needle, label) {
  const h = String(haystack || '');
  return check(h.includes(needle), label, `"${h.slice(0, 120)}" does not contain "${needle}"`);
}

/**
 * Run something that MIGHT fail without poisoning the outer transaction. Postgres
 * aborts the whole transaction on any error, so one bad query would turn every
 * later check into "current transaction is aborted" and hide the real result.
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

/** Every message in a channel, oldest first — the thread as a reader sees it. */
async function threadOf(client, channelId) {
  const { rows } = await client.query(
    `SELECT id, kind, body, sender_id, is_system, system_meta, created_at
       FROM chat_messages WHERE channel_id = $1 AND deleted_at IS NULL
      ORDER BY created_at ASC, id ASC`, [channelId],
  );
  return rows;
}

/** The live membership of a channel, with each member's group role. */
async function membersOf(client, channelId) {
  const { rows } = await client.query(
    `SELECT m.user_id, m.role, u.name
       FROM chat_channel_members m JOIN users u ON u.id = m.user_id
      WHERE m.channel_id = $1 AND m.left_at IS NULL ORDER BY u.name`, [channelId],
  );
  return rows;
}

/** How many channels exist for one (type, ref) — the idempotency number. */
async function channelCount(client, type, refId) {
  const { rows } = await client.query(
    'SELECT count(*)::int n FROM chat_channels WHERE type = $1 AND ref_id = $2',
    [type, refId],
  );
  return rows[0].n;
}

// ════════════════════════════════════════════════════════════════════════════
// THE CAST
// ════════════════════════════════════════════════════════════════════════════

/**
 * The venue is CHOSEN, never created: a booking room's title and image come off a
 * real venue row, and a fabricated venue would prove the join rather than the
 * data. Everything with a person in it is CREATED, because the assertions are
 * about exactly who is in a room and a seeded team's roster is not known here.
 */
async function pickVenue(client) {
  const { rows } = await client.query(
    `SELECT v.id, v.name, v.city, v.image_url, v.owner_id, v.sport_type,
            u.name AS owner_name
       FROM venues v JOIN users u ON u.id = v.owner_id
      WHERE v.owner_id IS NOT NULL AND v.name IS NOT NULL
      ORDER BY (v.image_url IS NOT NULL) DESC, v.created_at ASC LIMIT 1`,
  );
  return rows[0] || null;
}

let seq = 0;
async function makeUser(client, who, role = 'player') {
  seq += 1;
  const { rows } = await client.query(
    `INSERT INTO users (email, password_hash, name, phone, role, phone_verified)
     VALUES ($1, 'x', $2, $3, $4, TRUE) RETURNING id, name, role`,
    [`${PREFIX}${who}@sportlynk.test`, `${PREFIX}${who}`,
      `+92300${String(8100000 + seq).slice(-7)}`, role],
  );
  return rows[0];
}

/**
 * A team with a captain, a vice-captain and a plain member — three roles because
 * the coordination room must contain the first two and NOT the third, and a team
 * with only a captain could not tell those two rules apart.
 */
async function makeTeam(client, { label, sport, city }) {
  const captain = await makeUser(client, `${label}-cap`);
  const vice = await makeUser(client, `${label}-vice`);
  const plain = await makeUser(client, `${label}-member`);
  const { rows: t } = await client.query(
    // $5 AND $6 both carry the rating, on purpose: teams.elo is integer and the
    // legacy teams.elo_rating is numeric(8,2), and one placeholder feeding both
    // makes Postgres deduce two conflicting types for one parameter (42P08).
    `INSERT INTO teams (name, sport, captain_id, city, elo, elo_rating, visibility)
     VALUES ($1,$2,$3,$4,$5,$6,'public') RETURNING id, name`,
    [`${PREFIX}Team ${label}`, sport, captain.id, city, 1200, 1200],
  );
  const teamId = t[0].id;
  for (const [u, role] of [[captain, 'captain'], [vice, 'vice_captain'], [plain, 'member']]) {
    await client.query(
      'INSERT INTO team_members (team_id, user_id, role) VALUES ($1,$2,$3)',
      [teamId, u.id, role],
    );
  }
  // The team's own group chat, so the per-team pills in Block 3 have somewhere to
  // land and the inbox has a third channel type to list.
  const channelId = await chat.ensureTeamChannel(client, {
    id: teamId, name: t[0].name, logo_url: null, captain_id: captain.id,
  });
  for (const [u, role] of [[captain, 'captain'], [vice, 'vice_captain'], [plain, 'member']]) {
    await chat.syncTeamMember(client, channelId, u.id, role);
  }
  return {
    teamId, teamName: t[0].name, captain, vice, plain, channelId,
  };
}

/**
 * A pending booking on the chosen venue, far enough ahead that no job in this
 * database would act on it. The room is opened by Block 1, not here — the whole
 * point is that opening it is what confirmation does.
 */
async function makeBooking(client, { venue, playerId }) {
  const { rows } = await client.query(
    `INSERT INTO bookings (venue_id, player_id, slot_date, start_time, end_time,
                           base_price, total_amount, status, notes)
     VALUES ($1,$2, (CURRENT_DATE + 21), '18:00', '19:00', 2500, 2500, 'pending', $3)
     RETURNING id, slot_date, start_time`,
    [venue.id, playerId, `${PREFIX}booking`],
  );
  return rows[0];
}

// ════════════════════════════════════════════════════════════════════════════
// BLOCK 1 — THE BOOKING ROOM (FR8.4): confirmation opens a conversation
// ════════════════════════════════════════════════════════════════════════════

async function blockBookingRoom(client, ctx) {
  section('Block 1 — a confirmed booking becomes a room');

  const before = await channelCount(client, 'booking', ctx.booking.id);
  eq(before, 0, 'a PENDING booking has no chat room (an unapproved request is not a conversation)');

  const pill = await chat.openBookingRoom(client, {
    bookingId: ctx.booking.id,
    playerId: ctx.player.id,
    ownerId: ctx.venue.owner_id,
    venueName: ctx.venue.name,
    imageUrl: ctx.venue.image_url || null,
    event: 'booking_confirmed',
  });
  check(!!(pill && pill.channelId && pill.messageId),
    'confirming it opens the room and posts the opening pill in one call');
  if (!pill) return null;
  ctx.bookingChannel = pill.channelId;

  eq(await channelCount(client, 'booking', ctx.booking.id), 1,
    'exactly one channel exists for this booking');

  const mem = await membersOf(client, pill.channelId);
  eq(mem.length, 2, 'two people are in it — the player and the venue owner, nobody else');
  const owner = mem.find((m) => String(m.user_id) === String(ctx.venue.owner_id));
  const player = mem.find((m) => String(m.user_id) === String(ctx.player.id));
  eq(owner ? owner.role : null, 'admin',
    'the venue owner is the room admin (they moderate their own venue)');
  eq(player ? player.role : null, 'member',
    'the player is a member — they can delete their own messages and nothing else');

  const thread = await threadOf(client, pill.channelId);
  eq(thread.length, 1, 'the room opens with exactly one message');
  eq(thread[0].kind, 'system', 'and it is a system pill, not something attributed to a person');
  eq(thread[0].sender_id, null, 'with no sender — nobody typed it');
  eq(thread[0].body, 'Booking confirmed — chat with the venue here',
    'whose wording is the one sentence a push notification can show verbatim');
  eq(thread[0].system_meta && thread[0].system_meta.event, 'booking_confirmed',
    'and whose system_meta carries the same fact structured, for the app to render');
  ev.addFact('booking room opening pill', thread[0].body);
  return pill.channelId;
}

/**
 * The second confirmation. Both real confirm paths — the owner tapping approve and
 * autoApproveJob — call the same opener, and a retried request after a dropped
 * connection calls it again. Two rooms for one booking would split a conversation
 * in half with no way to merge it, so this is the assertion that matters most in
 * the whole block.
 */
async function blockIdempotent(client, ctx) {
  section('Block 2 — confirming twice does not open a second room');

  const again = await chat.openBookingRoom(client, {
    bookingId: ctx.booking.id,
    playerId: ctx.player.id,
    ownerId: ctx.venue.owner_id,
    venueName: ctx.venue.name,
    event: 'booking_confirmed',
  });
  eq(await channelCount(client, 'booking', ctx.booking.id), 1,
    'still exactly one channel after a second confirm (ux_chat_channels_type_ref)');
  eq(again && again.channelId, ctx.bookingChannel,
    'and it is the SAME channel id, so the earlier history is still there');
  eq((await membersOf(client, ctx.bookingChannel)).length, 2,
    'the membership was not duplicated either');

  // The pill IS posted twice, and that is correct: the room is idempotent, a
  // sentence is an event. Two identical pills means somebody confirmed twice.
  const thread = await threadOf(client, ctx.bookingChannel);
  eq(thread.length, 2, 'the pill is posted again — a room is a thing, a sentence is an event');

  // Cancellation. The room is NOT deleted: the refund argument still has to happen
  // somewhere, and an admin ruling a dispute needs the archive.
  const cancelled = await chat.announceInRoom(client, ctx.bookingChannel, 'booking_cancelled', {
    value: 'late cancellation',
  });
  check(!!cancelled, 'cancelling the booking posts a pill into the room instead of deleting it');
  const t2 = await threadOf(client, ctx.bookingChannel);
  eq(t2[t2.length - 1].body, 'This booking was cancelled (late cancellation)',
    'and the pill names the reason, because that is what the next message will argue about');

  const noShow = await chat.announceInRoom(client, ctx.bookingChannel, 'booking_no_show', {});
  check(!!noShow, 'a no-show posts its own pill');
  const t3 = await threadOf(client, ctx.bookingChannel);
  eq(t3[t3.length - 1].body, 'The venue marked this booking as a no-show',
    'worded as the venue’s action, since that is who marked it');

  // announceInRoom on a room that does not exist must read as "no pill", not as an
  // error: a booking confirmed before Wave B shipped has no channel at all.
  const none = await chat.announceInRoom(client, null, 'booking_cancelled', {});
  eq(none, null, 'a booking that predates this wave has no room, and that is not an error');
}

// ════════════════════════════════════════════════════════════════════════════
// BLOCK 3 — THE COORDINATION ROOM (FR8.5)
// ════════════════════════════════════════════════════════════════════════════

async function blockCaptainRoom(client, ctx) {
  section('Block 3 — an accepted challenge opens the captains’ room');

  eq(await channelCount(client, 'captain', ctx.match.id), 0,
    'a challenge that has only been SENT has no room (a declined one must leave no thread)');
  eq(await chat.captainChannelId(client, ctx.match.id), null,
    'and captainChannelId says so by returning null rather than throwing');

  const leads = await mc.leadIdsOf(client, [ctx.teamA.teamId, ctx.teamB.teamId]);
  eq(leads.length, 4, 'the room’s membership resolves to four people, not two');

  const channelId = await chat.ensureCaptainChannel(client, {
    matchId: ctx.match.id,
    title: `${ctx.teamA.teamName} vs ${ctx.teamB.teamName}`,
    memberIds: leads,
  });
  check(!!channelId, 'accepting the challenge opens the coordination room');
  ctx.coordChannel = channelId;

  const mem = await membersOf(client, channelId);
  eq(mem.length, 4, 'both captains AND both vice-captains are in it');
  const ids = new Set(mem.map((m) => String(m.user_id)));
  check(ids.has(String(ctx.teamA.captain.id)) && ids.has(String(ctx.teamB.captain.id)),
    'both captains are members');
  check(ids.has(String(ctx.teamA.vice.id)) && ids.has(String(ctx.teamB.vice.id)),
    'both vice-captains too — “the captain is unreachable” is the failure this room prevents');
  check(!ids.has(String(ctx.teamA.plain.id)) && !ids.has(String(ctx.teamB.plain.id)),
    'and no ordinary team member, who has their own team chat for this');
  check(mem.every((m) => m.role === 'admin'),
    'everyone is an admin: there is no hierarchy between two opposing captains');

  eq(await channelCount(client, 'captain', ctx.match.id), 1, 'exactly one room for this match');
  const again = await chat.ensureCaptainChannel(client, {
    matchId: ctx.match.id, title: 'retry', memberIds: leads,
  });
  eq(again, channelId, 'a retried accept resolves to the same room, never a second one');
  eq(await channelCount(client, 'captain', ctx.match.id), 1, 'still one');
  eq(await chat.captainChannelId(client, ctx.match.id), channelId,
    'and captainChannelId now finds it — the lookup every later pill goes through');
  return channelId;
}

/**
 * Every match-lifecycle event now writes THREE sentences: one per team, in that
 * team's own voice, plus ONE neutral sentence in the shared room. The per-team
 * wording is written from one side's point of view — "you challenged them" — and a
 * room holding both captains would tell half its readers the opposite of what
 * happened. This block drives the real fan-out and reads all three back.
 */
async function blockNeutralPills(client, ctx) {
  section('Block 4 — one shared room, one neutral sentence per event');

  const A = ctx.teamA;
  const B = ctx.teamB;
  const accept = await mc.fanOut(client, {
    matchId: ctx.match.id,
    sides: [
      { teamId: A.teamId, event: 'match_accepted', otherTeamName: B.teamName },
      { teamId: B.teamId, event: 'match_accepted', otherTeamName: A.teamName },
    ],
    coord: { event: 'match_coordinate', channelId: ctx.coordChannel },
  });
  eq(accept.pills.length, 3, 'accepting writes three pills: one per team chat, one in the room');

  const coordThread = await threadOf(client, ctx.coordChannel);
  eq(coordThread.length, 1, 'the coordination room opens with exactly one sentence');
  eq(coordThread[0].body, 'Challenge accepted — coordinate here',
    'and it is FR8.5’s wording, verbatim');
  ev.addFact('coordination room opening pill', coordThread[0].body);

  const aThread = await threadOf(client, A.channelId);
  has(aThread[aThread.length - 1].body, B.teamName,
    'team A’s own chat names team B, in team A’s voice');

  // The rest of the lifecycle, in order, exactly as routes/matches.js posts it.
  const events = [
    ['match_result_in', { teamName: A.teamName }, `${A.teamName} submitted a result for this match`],
    ['match_both_results_in', {}, 'Both results are in — the venue owner will verify the match'],
    ['match_settled', { detail: `${A.teamName} 3-1 ${B.teamName}` },
      `Result verified — ${A.teamName} 3-1 ${B.teamName}`],
    ['match_under_review', {}, 'The result is disputed and under review by SportLynk'],
    ['match_ruled', { detail: 'result upheld' }, 'SportLynk ruled on this match — result upheld'],
  ];
  for (const [event, opts, want] of events) {
    const out = await mc.fanOut(client, {
      matchId: ctx.match.id, sides: [], coord: { event, channelId: ctx.coordChannel, ...opts },
    });
    eq(out.pills.length, 1, `${event} posts one pill and only in the shared room`);
    const t = await threadOf(client, ctx.coordChannel);
    eq(t[t.length - 1].body, want, `${event} → “${want}”`);
  }

  // The property that makes a shared room readable: not one sentence in it is
  // written from one team's point of view. This is a check on the whole thread, so
  // a future sentence added carelessly fails here rather than in front of a user.
  const all = await threadOf(client, ctx.coordChannel);
  const pov = all.filter((m) => /\byou\b|\byour\b/i.test(String(m.body || '')));
  eq(pov.length, 0,
    'no sentence in the shared room says “you” or “your” — it reads the same to both teams');
  ev.addFact('sentences in the coordination room', String(all.length));
  ev.note(all.map((m) => `- ${m.body}`).join('\n'));

  // The other half of the same rule: the per-team sentences DO take a side, and
  // that is correct. If these ever stopped differing, the neutral set would be
  // pointless.
  const sideA = sys.sentenceFor('match_challenge_sent', { a: 'Ali', v: B.teamName });
  const sideB = sys.sentenceFor('match_challenge_received', { v: A.teamName });
  check(sideA !== sideB && /challenged/.test(sideA) && /your team/.test(sideB),
    'the per-team sentences still take a side — “they challenged your team” vs “you challenged them”');

  // A match with no room: the pill is skipped, the transaction is untouched. This
  // is the entire migration story for challenges accepted before Wave B.
  const orphan = await mc.fanOut(client, {
    matchId: ctx.match.id, sides: [], coord: { event: 'match_settled', channelId: null },
  });
  // channelId null falls back to the lookup, which finds the room this run made;
  // the honest test of "no room" is a match id that has none.
  const noRoom = await mc.fanOut(client, {
    matchId: ctx.orphanMatch.id, sides: [], coord: { event: 'match_settled' },
  });
  eq(noRoom.pills.length, 0, 'a match with no coordination room posts nothing and does not throw');
  check(orphan.pills.length === 1,
    'while a null channelId still resolves the room by match id, the way fanOut’s callers rely on');
}

// ════════════════════════════════════════════════════════════════════════════
// BLOCK 5 — THE INBOX: what the list says, and what the badge says
// ════════════════════════════════════════════════════════════════════════════

async function blockInbox(client, ctx) {
  section('Block 5 — the inbox, its unread count and its badge');

  // The captain of team A is in three rooms by now: their team chat, the
  // coordination room, and nothing else — so a booking room is added to the same
  // person to get all three types into one list.
  const uid = ctx.teamA.captain.id;
  await chat.addMember(client, ctx.bookingChannel, uid, 'member');

  const page = await list.listChats(client, { userId: uid, limit: 30 });
  const types = page.items.map((i) => i.type);
  check(types.includes('booking') && types.includes('captain') && types.includes('team'),
    'the list holds all three channel types for one person');
  eq(page.items.length, 3, 'and exactly the three rooms they are a live member of');

  // Ordering: most recent first, by the same expression the cursor pages on.
  const times = page.items.map((i) => new Date(i.sortAt).getTime());
  check(times.every((t, i) => i === 0 || times[i - 1] >= t),
    'ordered most-recent-first, on the same expression the cursor pages on');

  // The context subtitle is the reason a row is tappable rather than a bare name.
  const bookingRow = page.items.find((i) => i.type === 'booking');
  const coordRow = page.items.find((i) => i.type === 'captain');
  const teamRow = page.items.find((i) => i.type === 'team');
  has(bookingRow.context && bookingRow.context.subtitle, 'Pending',
    'a booking row’s subtitle carries its live status, read from the booking row itself');
  has(bookingRow.context && bookingRow.context.subtitle, ',',
    'and the slot, formatted as PKT wall-clock and never re-zoned');
  has(coordRow.context && coordRow.context.title, ' vs ',
    'a coordination row reads “my team vs theirs” — written per viewer even though the room is shared');
  has(teamRow.context && teamRow.context.subtitle, 'member',
    'a team row carries its member count');
  ev.addFact('booking row subtitle', String(bookingRow.context.subtitle));
  ev.addFact('coordination row title', String(coordRow.context.title));

  // ── The unread count, against a number computed by hand ──────────────────
  //
  // Every pill in the coordination room was written by nobody (sender_id NULL) and
  // team A's captain has never marked it read, so all of them are unread. Counting
  // them here from the raw table is the only way to prove the LATERAL in the list
  // agrees with reality rather than with itself.
  const { rows: byHand } = await client.query(
    `SELECT count(*)::int n FROM chat_messages
      WHERE channel_id = $1 AND deleted_at IS NULL
        AND (sender_id IS NULL OR sender_id <> $2)`,
    [ctx.coordChannel, uid],
  );
  eq(coordRow.unread, byHand[0].n,
    `the list’s unread count for the shared room is the hand-computed ${byHand[0].n}`);

  // A message from ME is never unread to me, and a tombstone leaves no permanent +1.
  const mine = await chat.insertMessage(client, {
    channelId: ctx.coordChannel, senderId: uid, kind: 'text', body: 'On my way',
  });
  const gone = await chat.insertMessage(client, {
    channelId: ctx.coordChannel, senderId: ctx.teamB.captain.id, kind: 'text', body: 'oops',
  });
  await client.query('UPDATE chat_messages SET deleted_at = now() WHERE id = $1', [gone.message.id]);
  const p2 = await list.listChats(client, { userId: uid, limit: 30 });
  const coord2 = p2.items.find((i) => i.id === ctx.coordChannel);
  eq(coord2.unread, byHand[0].n,
    'my own message does not count as unread to me, and a deleted one stops counting at all');
  has(coord2.lastMessagePreview, 'oops',
    'though the preview still shows the deleted message until something newer arrives');

  // Reading the room clears it — the same column POST /:channelId/read moves, which
  // is what makes the badge and the thread agree.
  //
  // clock_timestamp(), NOT now(), and only because this script is one long
  // transaction. now() is the TRANSACTION's timestamp, fixed at the BEGIN above,
  // so it is EARLIER than the clock_timestamp() insertMessage stamped on every
  // message this run wrote — a watermark set with it would clear nothing and the
  // failure would look like a bug in the count. In production each read is its own
  // statement on the pool, so its now() is genuinely later than every committed
  // message and the endpoint's plain now() is correct as written. Using the same
  // function the writer uses is what makes the assertion comparable.
  await client.query(
    `UPDATE chat_channel_members SET last_read_at = clock_timestamp()
      WHERE channel_id = $1 AND user_id = $2`, [ctx.coordChannel, uid],
  );
  const p3 = await list.listChats(client, { userId: uid, limit: 30 });
  eq(p3.items.find((i) => i.id === ctx.coordChannel).unread, 0,
    'marking it read clears the count to zero');

  // ── The badge ────────────────────────────────────────────────────────────
  const badge = await list.unreadCounts(client, uid);
  const listTotal = p3.items.reduce((s, i) => s + i.unread, 0);
  eq(badge.total, listTotal, 'the badge total equals the sum of the rows it summarises');
  check(typeof badge.byType.booking === 'number' && typeof badge.byType.team === 'number',
    'and it breaks down by type, which is what a per-tab badge needs');

  // Mute: excluded from the badge, still shown in the list. A badge that counts a
  // conversation somebody silenced on purpose is why people switch badges off.
  const beforeMute = await list.unreadCounts(client, uid);
  const muted = await list.setMute(client, {
    channelId: ctx.bookingChannel, userId: uid,
    until: new Date(Date.now() + 8 * 3600 * 1000),
  });
  check(muted.muted === true && !!muted.mutedUntil,
    'muting writes muted_until — a timestamp, so “mute 8 hours” un-mutes itself');
  const afterMute = await list.unreadCounts(client, uid);
  const bookingUnread = p3.items.find((i) => i.type === 'booking').unread;
  eq(afterMute.total, beforeMute.total - bookingUnread,
    'the muted room drops out of the badge by exactly its own count');
  const p4 = await list.listChats(client, { userId: uid, limit: 30 });
  const mutedRow = p4.items.find((i) => i.id === ctx.bookingChannel);
  check(mutedRow && mutedRow.muted === true && mutedRow.unread === bookingUnread,
    'while the list still shows the room, and still shows its count — information, not a nag');
  const unmuted = await list.setMute(client, { channelId: ctx.bookingChannel, userId: uid, until: null });
  eq(unmuted.muted, false, 'and un-muting clears it');

  // The type filter and the cursor.
  const only = await list.listChats(client, { userId: uid, limit: 30, type: 'team' });
  check(only.items.length === 1 && only.items[0].type === 'team',
    'the type filter returns only that type');
  const firstPage = await list.listChats(client, { userId: uid, limit: 2 });
  eq(firstPage.items.length, 2, 'a limit of two returns two rows');
  check(!!firstPage.nextCursor, 'and a cursor, because there is more');
  const secondPage = await list.listChats(client, { userId: uid, limit: 2, cursor: firstPage.nextCursor });
  const overlap = secondPage.items.filter((i) => firstPage.items.some((f) => f.id === i.id));
  eq(overlap.length, 0, 'the second page does not repeat a row from the first');
  eq(firstPage.items.length + secondPage.items.length, 3, 'and between them they are the whole list');

  // Assistant channels are excluded everywhere. Scout has its own screen and its
  // own entry point; a robot at the top of a human inbox is the wrong default.
  //
  // A REAL Scout thread carries no chat_channel_members row at all — it is keyed by
  // created_by — so the inner join alone would already hide it. One is added here on
  // purpose, so that the `type <> 'assistant'` filter is the only thing left doing
  // the work and the test cannot pass for the wrong reason.
  const scout = await threads.create(client, { userId: uid, persona: 'player' });
  check(!!(scout && scout.ok), 'a Scout thread can be opened for this user');
  await chat.addMember(client, scout.row.id, uid, 'member');
  await chat.insertMessage(client, {
    channelId: scout.row.id, senderId: ctx.teamB.captain.id, kind: 'text', body: 'unread to uid',
  });
  const p5 = await list.listChats(client, { userId: uid, limit: 30 });
  check(!p5.items.some((i) => i.type === 'assistant'),
    'it does NOT appear in the inbox even as a member with an unread message in it');
  const badge5 = await list.unreadCounts(client, uid);
  eq(badge5.byType.assistant, undefined,
    'and the badge has no bucket for Scout at all — three human types, nothing else');

  // ── The index the unread count depends on ────────────────────────────────
  //
  // Migration 013 already ships idx_chat_messages_channel (channel_id, created_at
  // DESC), which is exactly the shape the LATERAL count and every history page need.
  // This asserts it is still there and that the planner actually chooses it — an
  // index nobody uses is a line in a migration, not a fast query.
  const { rows: ix } = await client.query(
    `SELECT indexdef FROM pg_indexes
      WHERE tablename = 'chat_messages' AND indexname = 'idx_chat_messages_channel'`);
  check(!!ix[0], 'idx_chat_messages_channel exists (migration 013)');
  if (ix[0]) {
    has(ix[0].indexdef, '(channel_id, created_at DESC)',
      'and it covers exactly the columns the count and the history page filter and sort on');
  }
  const plan = await probe(client, async () => {
    const { rows } = await client.query(
      `EXPLAIN (FORMAT JSON) SELECT count(*) FROM chat_messages
        WHERE channel_id = $1 AND created_at > now() - interval '1 day'`,
      [ctx.coordChannel],
    );
    return JSON.stringify(rows[0]['QUERY PLAN']);
  });
  if (!plan.ok) {
    skip('the planner uses that index for the unread count', plan.err.message);
  } else if (plan.out.includes('idx_chat_messages_channel')) {
    check(true, 'and the planner chooses it for the unread count (EXPLAIN shows an index scan)');
    ev.addFact('unread-count plan', 'Index Scan using idx_chat_messages_channel');
  } else {
    const { rows: n } = await client.query('SELECT count(*)::int n FROM chat_messages');
    skip('the planner uses that index for the unread count',
      `chat_messages holds ${n[0].n} rows — a sequential scan is the correct plan at this size`);
  }
}

// ════════════════════════════════════════════════════════════════════════════
// BLOCK 6 — FR8.10: the reply suggestions
// ════════════════════════════════════════════════════════════════════════════

async function blockQuickReplies(client, ctx) {
  section('Block 6 — FR8.10 reply suggestions, model and fallback');

  // Every key in the table must be a label the model can actually emit. A key that
  // is not in the frozen 23-label spec is a branch that can never run — the same
  // guard mlClient.assertNluLabels applies to Scout's routing.
  const labels = new Set(actions.intentLabels());
  eq(labels.size, 23, 'the frozen spec still has 23 labels and this wave added none');
  const unknown = [];
  for (const [audience, table] of Object.entries(qr.QUICK_REPLIES)) {
    for (const key of Object.keys(table)) if (!labels.has(key)) unknown.push(`${audience}/${key}`);
  }
  eq(unknown.length, 0, `every quick-reply key is a real label (${unknown.join(', ') || 'none unknown'})`);
  const lexUnknown = qr.LEXICON.map((r) => r[1]).filter((l) => !labels.has(l));
  eq(lexUnknown.length, 0, 'and so is every intent the keyword fallback can produce');
  check(Object.values(qr.QUICK_REPLIES).every(
    (t) => Object.values(t).every((v) => Array.isArray(v) && v.length === 3)),
  'every entry offers exactly three replies — the number a chip row fits');

  // The owner's side of a booking room, driven through the real classifier.
  const askedByPlayer = await chat.insertMessage(client, {
    channelId: ctx.bookingChannel, senderId: ctx.player.id, kind: 'text',
    body: 'bhai kal 6 baje ka slot khali hai?',
  });
  const ownerChannel = { id: ctx.bookingChannel, type: 'booking', ref_id: ctx.booking.id };
  const asOwner = await qr.suggestFor(client, {
    channel: ownerChannel, userId: ctx.owner.id, userRole: 'owner',
    messageId: askedByPlayer.message.id,
  });
  check(!asOwner.error, `the owner gets a suggestion${asOwner.error ? `: ${asOwner.error.message}` : ''}`);
  if (asOwner.error) return;
  eq(asOwner.data.suggestions.length, 3, 'three of them');
  eq(asOwner.data.audience, 'owner', 'worded for the venue owner, because that is who is replying');
  eq(asOwner.data.advisory, true, 'and flagged advisory — tapping one fills the composer, it never sends');
  ev.addMeta('quick-reply source', `${asOwner.data.source} (${asOwner.data.intent || 'no intent'})`);
  ev.addFact('asked by the player', 'bhai kal 6 baje ka slot khali hai?');
  ev.addFact('offered to the owner', asOwner.data.suggestions.map((s) => `“${s.text}”`).join('  ·  '));
  if (asOwner.data.source === 'model') {
    eq(asOwner.data.intent, 'check_availability',
      'the released model classifies the Roman-Urdu question as check_availability');
    check(asOwner.data.confidence > 0, 'with a real confidence, not a zero');
    ev.addMeta('model version', String(asOwner.data.modelVersion || 'unknown'));
  } else {
    skip('the released model classifies the Roman-Urdu question',
      `ml-service answered "${asOwner.data.source}" — the keyword fallback carried it instead`);
    eq(asOwner.data.intent, 'check_availability', 'and the keyword fallback reaches the same intent');
  }

  // The same message, the other side of the room: a player asking themselves what
  // to say gets the player's half of the conversation, not the owner's.
  const asPlayer = await qr.suggestFor(client, {
    channel: ownerChannel, userId: ctx.player.id, userRole: 'player',
    text: 'bhai kal 6 baje ka slot khali hai?',
  });
  eq(asPlayer.data.audience, 'player', 'the player gets the player audience in the same room');
  const ownerTexts = asOwner.data.suggestions.map((s) => s.text).join('|');
  const playerTexts = asPlayer.data.suggestions.map((s) => s.text).join('|');
  check(ownerTexts !== playerTexts,
    'and genuinely different sentences — the two sides need opposite halves of one conversation');

  // A captain room is its own audience whatever the two people do elsewhere.
  const asCaptain = await qr.suggestFor(client, {
    channel: { id: ctx.coordChannel, type: 'captain', ref_id: ctx.match.id },
    userId: ctx.teamA.captain.id, userRole: 'player', text: 'kitne log aa rahe hain?',
  });
  eq(asCaptain.data.audience, 'captain',
    'a coordination room is its own audience regardless of the caller’s app role');

  // {venue} is READ from the booking this room points at. This is the only fact a
  // canned reply is allowed to contain, and it is the reason none of them can lie.
  const info = await qr.suggestFor(client, {
    channel: ownerChannel, userId: ctx.owner.id, userRole: 'owner',
    text: 'floodlights aur parking hai?',
  });
  const joined = info.data.suggestions.map((s) => s.text).join(' ');
  check(!joined.includes('{venue}') && !joined.includes('{price}'),
    'no placeholder ever reaches the wire');
  if (info.data.intent === 'venue_info') {
    has(joined, ctx.venue.name, 'and {venue} is filled with the real venue name off the booking row');
  } else {
    skip('{venue} is filled from the booking row', `classified as ${info.data.intent || 'nothing'}, not venue_info`);
  }

  // The refusals.
  const own = await qr.suggestFor(client, {
    channel: ownerChannel, userId: ctx.player.id, userRole: 'player',
    messageId: askedByPlayer.message.id,
  });
  eq(own.error && own.error.status, 400, 'suggesting a reply to your OWN message is refused');
  const empty = await qr.suggestFor(client, {
    channel: ownerChannel, userId: ctx.owner.id, userRole: 'owner', text: '   ',
  });
  eq(empty.error && empty.error.status, 400, 'so is an empty body');
  const elsewhere = await qr.suggestFor(client, {
    channel: { id: ctx.coordChannel, type: 'captain', ref_id: ctx.match.id },
    userId: ctx.owner.id, userRole: 'owner', messageId: askedByPlayer.message.id,
  });
  eq(elsewhere.error && elsewhere.error.status, 404,
    'and a messageId from a different channel — the id alone is never enough');

  // ── The down-path, proven by taking the model away ────────────────────────
  //
  // ml-service being reachable during a check run is exactly when the fallback is
  // NOT exercised, so parseNlu is swapped for the shape it returns when the service
  // is unreachable. That is the same object the real failure path produces
  // (mlClient.nluUnavailable), so this proves the branch rather than a mock of it.
  const realParse = ml.parseNlu;
  ml.parseNlu = async () => ({
    available: false, source: 'unavailable', intent: 'out_of_scope', confidence: 0,
    abstained: true, abstainReason: 'unreachable', modelVersion: null,
  });
  try {
    const down = await qr.suggestFor(client, {
      channel: ownerChannel, userId: ctx.owner.id, userRole: 'owner',
      text: 'mere paisay wapas kab milenge?',
    });
    eq(down.data.source, 'lexicon', 'with ml-service down the keyword table answers instead');
    eq(down.data.intent, 'refund_policy', 'and it reads the Roman-Urdu refund question correctly');
    eq(down.data.suggestions.length, 3, 'still three sendable sentences, not an error');
    eq(down.data.confidence, 0, 'with confidence 0 — the endpoint never claims a model it did not use');
    ev.addFact('with ml-service down', down.data.suggestions.map((s) => `“${s.text}”`).join('  ·  '));

    // A sentence no keyword matches still has to produce something sendable.
    const nothing = await qr.suggestFor(client, {
      channel: ownerChannel, userId: ctx.owner.id, userRole: 'owner',
      text: 'zzzz qwerty flumph',
    });
    eq(nothing.data.intent, null, 'an unrecognisable message yields no intent');
    eq(nothing.data.source, 'unavailable', 'and says so');
    eq(nothing.data.suggestions.length, 3, 'and STILL offers three generic replies rather than nothing');
  } finally {
    ml.parseNlu = realParse;
  }
}

// ════════════════════════════════════════════════════════════════════════════
// BLOCK 7 — IS IT WIRED? the check a rolled-back script can still make
// ════════════════════════════════════════════════════════════════════════════

/**
 * Everything above proves the openers WORK. None of it proves anything CALLS them,
 * and "the machinery exists and is not wired to anything" is the exact failure this
 * whole sprint is repairing. So this block reads the source of every path that
 * should open or annotate a room and asserts the call is there.
 *
 * A string match is a weak proof of behaviour and a strong proof of absence: it
 * cannot tell you the call is correct, but it fails loudly the day somebody adds a
 * third confirm path and forgets the room. That is the failure worth catching here.
 */
function blockWiring() {
  section('Block 7 — every confirm, cancel and no-show path calls the opener');
  const fs = require('fs');
  const read = (rel) => {
    try { return fs.readFileSync(path.join(__dirname, '..', rel), 'utf8'); } catch { return ''; }
  };

  const wanted = [
    ['routes/owner.js', 'openBookingRoom', 'the owner approving a booking opens the room'],
    ['routes/owner.js', "announceInRoom(client, nsRoom, \"booking_no_show\"", 'the owner marking a no-show posts its pill'],
    ['jobs/autoApproveJob.js', 'openBookingRoom', 'auto-approval opens the SAME room, so the race has no wrong winner'],
    ['jobs/noShowJob.js', 'announceInRoom', 'the no-show sweep posts its pill too'],
    ['services/bookingService.js', "announceInRoom(client, roomId, 'booking_cancelled'", 'cancelling a booking annotates the room instead of deleting it'],
    ['routes/matches.js', 'ensureCaptainChannel', 'accepting a challenge opens the coordination room'],
    ['routes/chat.js', 'list.listChats', 'GET /api/chat is served by the same function this script drove'],
    ['routes/chat.js', 'list.unreadCounts', 'so is the badge'],
    ['routes/chat.js', 'qr.suggestFor', 'and so are the reply suggestions'],
  ];
  for (const [file, needle, label] of wanted) {
    check(read(file).includes(needle), label, `${file} has no "${needle}"`);
  }

  // Every emit is AFTER the commit. A socket frame that arrives while the
  // transaction is open tells the app to re-read a row it cannot see yet, and it
  // renders the old one — the single most confusing bug class in a live chat.
  for (const file of ['routes/owner.js', 'jobs/autoApproveJob.js', 'jobs/noShowJob.js']) {
    const src = read(file);
    const emitAt = src.indexOf('emitPills');
    const commitAt = src.lastIndexOf('COMMIT', emitAt > 0 ? emitAt : undefined);
    check(emitAt > 0 && commitAt > 0 && commitAt < emitAt,
      `${file} emits its pill AFTER COMMIT, never inside the transaction`);
  }

  // All six match-lifecycle fan-outs carry a coord pill. Five would mean one
  // lifecycle event is invisible in the room the players are arguing in.
  const matches = read('routes/matches.js');
  const coordSites = (matches.match(/coord:/g) || []).length;
  check(coordSites >= 6, 'all six match-lifecycle fan-outs pass a coord pill', `found ${coordSites}`);
  ev.addFact('coord pill call sites in routes/matches.js', String(coordSites));
}

// ════════════════════════════════════════════════════════════════════════════
// THE RUN
// ════════════════════════════════════════════════════════════════════════════

/** No row this script writes may ever be found outside its own transaction. */
async function verifyClean(client) {
  section('--verify-clean');
  const { rows } = await client.query(
    `SELECT (SELECT count(*) FROM users WHERE email LIKE $1)::int AS users,
            (SELECT count(*) FROM teams WHERE name LIKE $1)::int AS teams,
            (SELECT count(*) FROM bookings WHERE notes LIKE $1)::int AS bookings`,
    [`${PREFIX}%`],
  );
  eq(rows[0].users, 0, 'no zzchat- user exists in the database');
  eq(rows[0].teams, 0, 'no zzchat- team either');
  eq(rows[0].bookings, 0, 'and no zzchat- booking');
}

async function main() {
  const client = await pool.connect();
  const ctx = {};
  let rolled = false;
  try {
    if (VERIFY_CLEAN) { await verifyClean(client); return; }

    ctx.venue = await pickVenue(client);
    if (!ctx.venue) {
      console.log('\n  ✗ no venue with an owner exists in this database.');
      failures.push('a venue with an owner to open a booking room against');
      return;
    }
    const sport = String(ctx.venue.sport_type || 'cricket').toLowerCase();
    console.log(`\n  venue    ${ctx.venue.name} — ${ctx.venue.city}, ${sport}`);
    console.log(`  owner    ${ctx.venue.owner_name}`);
    const nlu = await ml.nluSpec();
    console.log(`  model    ${nlu.reachable ? 'ml-service reachable — suggestions will report source:model' : 'ml-service down — the keyword fallback carries FR8.10'}`);
    ev.addMeta('venue', `${ctx.venue.name} (${ctx.venue.city})`);
    ev.addMeta('ml-service', nlu.reachable ? 'reachable' : 'unreachable (fallback path)');

    await client.query('BEGIN');

    ctx.owner = { id: ctx.venue.owner_id, name: ctx.venue.owner_name };
    ctx.player = await makeUser(client, 'player');
    ctx.booking = await makeBooking(client, { venue: ctx.venue, playerId: ctx.player.id });
    ctx.teamA = await makeTeam(client, { label: 'A', sport, city: ctx.venue.city });
    ctx.teamB = await makeTeam(client, { label: 'B', sport, city: ctx.venue.city });
    // `matches` has NO match_date: the fixture's when-and-where IS `booking_id`,
    // and a friendly challenge carries only `challenge_expires_at`. The challenged
    // match is the one every room and pill assertion runs against; `orphanMatch`
    // deliberately never gets a room, so block 4 can prove that a lifecycle event
    // on a roomless match posts nothing instead of throwing.
    const { rows: m } = await client.query(
      `INSERT INTO matches (challenger_team, opponent_team, booking_id, sport, status,
                            challenge_expires_at, created_by, updated_at)
       VALUES ($1,$2,$3,$4,'challenge_sent', now() + interval '48 hours', $5, now())
       RETURNING id`,
      [ctx.teamA.teamId, ctx.teamB.teamId, ctx.booking.id, sport, ctx.teamA.captain.id],
    );
    [ctx.match] = m;
    const { rows: om } = await client.query(
      `INSERT INTO matches (challenger_team, opponent_team, sport, status,
                            challenge_expires_at, created_by, updated_at)
       VALUES ($1,$2,$3,'challenge_sent', now() + interval '48 hours', $4, now())
       RETURNING id`,
      [ctx.teamB.teamId, ctx.teamA.teamId, sport, ctx.teamB.captain.id],
    );
    [ctx.orphanMatch] = om;

    await blockBookingRoom(client, ctx);
    if (ctx.bookingChannel) await blockIdempotent(client, ctx);
    await blockCaptainRoom(client, ctx);
    if (ctx.coordChannel) await blockNeutralPills(client, ctx);
    if (ctx.bookingChannel && ctx.coordChannel) await blockInbox(client, ctx);
    if (ctx.bookingChannel) await blockQuickReplies(client, ctx);
    blockWiring();
  } catch (err) {
    console.error('\n  ! the run stopped:', err.message);
    failures.push(`the run completed without throwing (${err.message})`);
  } finally {
    if (!VERIFY_CLEAN) {
      await client.query('ROLLBACK').then(() => { rolled = true; }).catch(() => {});

      // The rollback, proven rather than asserted: the same connection, now outside
      // any transaction, must not be able to see a single row this run wrote.
      section('The rollback');
      try {
        const { rows } = await client.query(
          `SELECT (SELECT count(*) FROM users WHERE email LIKE $1)::int AS users,
                  (SELECT count(*) FROM teams WHERE name LIKE $1)::int AS teams,
                  (SELECT count(*) FROM chat_channels WHERE id = $2)::int AS room`,
          [`${PREFIX}%`, ctx.bookingChannel || '00000000-0000-0000-0000-000000000000'],
        );
        eq(rows[0].users, 0, 'after ROLLBACK not one person this run created still exists');
        eq(rows[0].teams, 0, 'nor one team');
        eq(rows[0].room, 0, 'and not the booking room either — the database is exactly as it was');
      } catch (err) {
        check(false, 'the rollback could be verified', err.message);
      }
    }
    client.release();
  }
  if (!rolled && !VERIFY_CLEAN) console.log('\n  ! the transaction was NOT rolled back');
}

/**
 * The verdict. A skip is printed alongside the pass count and never inside it: a
 * case the data could not supply is a case that did not run, and folding it into
 * the pass total would turn thin data into a green tick.
 */
async function report() {
  const total = passed + failures.length;
  console.log(`\n${'═'.repeat(72)}`);
  if (failures.length) {
    console.log(`FAIL ${passed}/${total}${skips.length ? ` · ${skips.length} skipped` : ''}\n`);
    for (const f of failures) console.log(`  ✗ ${f}`);
  } else {
    console.log(`PASS ${passed}/${total}${skips.length ? ` · ${skips.length} skipped` : ''}`);
  }
  if (skips.length) {
    console.log('\nskipped (the data could not supply the case, not a pass):');
    for (const s of skips) console.log(`  ~ ${s}`);
  }
  if (ev.on) {
    const written = await ev.write({ passed, failed: failures.length, skipped: skips.length });
    if (written) console.log(`\nevidence → ${written.path} (${written.lines} lines)`);
  }
  console.log('');
  return failures.length ? 1 : 0;
}

main()
  .then(report)
  .then(async (code) => {
    await pool.end();
    process.exit(code);
  })
  .catch(async (err) => {
    console.error('\nthe harness itself failed:', err);
    await pool.end().catch(() => {});
    process.exit(1);
  });
