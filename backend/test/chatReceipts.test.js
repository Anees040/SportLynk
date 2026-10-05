/**
 * chatReceipts.test.js — the tick lifecycle and the history window.
 *
 * Covers the four faults a two-account test of the team chat exposed:
 *
 *   1. A message never reached a second tick. last_delivered_at only moved when a
 *      socket CONNECTED, so a recipient who was already online when the message
 *      landed kept a watermark older than it.
 *   2. A message reached a BLUE tick nobody had earned. `channel:join` stamped
 *      last_read_at, and a socket re-joins its rooms on every reconnect —
 *      including behind a lock screen with the thread merely mounted.
 *   3. A newly added team member could read the whole backlog: membership was the
 *      only check on the history endpoint, and membership says nothing about when
 *      it began.
 *   4. A poll could be created in a room with two people in it.
 *
 * Two kinds of test here. The watermark helpers take a `client` — the same seam
 * chatList's functions use — so a stub records the statement and the parameters
 * the real code would have sent, and the SQL itself is asserted rather than
 * described. Everything that is a wiring rule (which route calls which helper,
 * which query carries the boundary) is read off the source, because the fault in
 * every one of those cases was a missing call rather than a wrong one.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const receipts = require('../src/utils/chatReceipts');

const src = (...p) => fs.readFileSync(path.join(__dirname, '..', 'src', ...p), 'utf8');
const RECEIPTS_SRC = src('utils', 'chatReceipts.js');
const EVENTS_SRC = src('realtime', 'chatEvents.js');
const RT_INDEX_SRC = src('realtime', 'index.js');
const ROUTES_SRC = src('routes', 'chat.js');
const CORE_SRC = src('utils', 'chatCore.js');
const LIST_SRC = src('utils', 'chatList.js');

/**
 * A pg client that records every query and answers from a queued script.
 *
 * `rows` is consumed one result per call, so a helper that makes two statements
 * (read the roster, then update it) can be driven exactly as the real one is.
 */
function stubClient(results = []) {
  const calls = [];
  const queue = [...results];
  return {
    calls,
    query: async (text, params) => {
      calls.push({ text, params });
      return queue.length ? queue.shift() : { rows: [], rowCount: 0 };
    },
  };
}

const ts = (iso) => new Date(iso);

// ───────────────────────────────────────────────────────────────────────────────
// 1. The watermarks themselves
// ───────────────────────────────────────────────────────────────────────────────

test('1 — a read mark moves both watermarks, and only ever forwards', async () => {
  const client = stubClient([{
    rows: [{ last_read_at: ts('2026-10-04T10:00:00Z'), last_delivered_at: ts('2026-10-04T10:00:00Z') }],
  }]);
  const marks = await receipts.markRead(client, { channelId: 'c1', userId: 'u1' });

  const sql = client.calls[0].text;
  // GREATEST on BOTH columns. Without it a second device a few seconds behind,
  // or a client clock that is wrong, drags the watermark back and turns read
  // messages unread again.
  assert.match(sql, /last_read_at\s*=\s*GREATEST\(last_read_at,/);
  assert.match(sql, /last_delivered_at\s*=\s*GREATEST\(last_delivered_at,/);
  // Scoped to one membership, and never to a member who has left.
  assert.match(sql, /channel_id = \$1 AND user_id = \$2/);
  assert.match(sql, /left_at IS NULL/);
  assert.deepEqual(marks, {
    readAt: '2026-10-04T10:00:00.000Z',
    deliveredAt: '2026-10-04T10:00:00.000Z',
  });
});

test('2 — a read mark on a channel the caller is not in returns null, not a silent success', async () => {
  // The routes turn this into a 403 and the socket handler refuses to join the
  // room. A helper that answered "fine" would hand both of them a false positive.
  const client = stubClient([{ rows: [] }]);
  assert.equal(await receipts.markRead(client, { channelId: 'c1', userId: 'u9' }), null);
});

test('3 — a delivered mark leaves the read watermark alone', async () => {
  const client = stubClient([{ rows: [{ last_delivered_at: ts('2026-10-04T10:00:00Z') }] }]);
  const marks = await receipts.markDelivered(client, { channelId: 'c1', userId: 'u1' });

  const sql = client.calls[0].text;
  assert.match(sql, /SET last_delivered_at = GREATEST/);
  // The whole point of the separation: having the channel open is the second
  // tick, and nothing more. A read is a separate claim the client makes.
  assert.ok(!/last_read_at/.test(sql), 'markDelivered is still writing last_read_at');
  assert.deepEqual(marks, { deliveredAt: '2026-10-04T10:00:00.000Z' });
});

test('4 — a delivered-only receipt carries no readAt field at all', () => {
  // An absent field means "this mark did not move". Sending readAt: null would be
  // read by a client that overwrites what it is given as "nothing has been read",
  // which is how a blue tick turns back into a grey one.
  const emitted = [];
  const bus = require('../src/realtime/bus');
  const original = bus.emitReceipt;
  bus.emitReceipt = (channelId, userId, payload) => emitted.push(payload);
  try {
    receipts.broadcast('c1', 'u1', { deliveredAt: '2026-10-04T10:00:00.000Z' });
    receipts.broadcast('c1', 'u1', { deliveredAt: 'd', readAt: 'r' });
  } finally {
    bus.emitReceipt = original;
  }
  assert.deepEqual(emitted[0], {
    channelId: 'c1', userId: 'u1', deliveredAt: '2026-10-04T10:00:00.000Z',
  });
  assert.ok(!('readAt' in emitted[0]), 'a delivered-only receipt is claiming a read');
  assert.equal(emitted[1].readAt, 'r');
});

test('5 — delivered-on-send stamps the members who are online and nobody else', async () => {
  const bus = require('../src/realtime/bus');
  const originalOnline = bus.isUserOnline;
  // u2 has a socket; u3 does not. u1 is the sender and must not be asked about.
  bus.isUserOnline = (id) => id === 'u2';
  try {
    const client = stubClient([
      { rows: [{ user_id: 'u2' }, { user_id: 'u3' }] },
      { rows: [{ user_id: 'u2', last_delivered_at: ts('2026-10-04T10:00:00Z') }] },
    ]);
    const stamped = await receipts.markDeliveredToOnline(client, {
      channelId: 'c1', senderId: 'u1',
    });

    // The sender is excluded in SQL, not filtered in JS afterwards.
    assert.match(client.calls[0].text, /user_id <> \$2/);
    assert.deepEqual(client.calls[0].params, ['c1', 'u1']);
    // Only the online id reaches the UPDATE — an offline member keeps their old
    // watermark, which is what makes a single tick mean something.
    assert.deepEqual(client.calls[1].params, ['c1', ['u2']]);
    assert.match(client.calls[1].text, /GREATEST\(last_delivered_at, now\(\)\)/);
    assert.deepEqual(stamped, ['u2']);
  } finally {
    bus.isUserOnline = originalOnline;
  }
});

test('6 — with nobody online, delivered-on-send writes nothing', async () => {
  const bus = require('../src/realtime/bus');
  const originalOnline = bus.isUserOnline;
  bus.isUserOnline = () => false;
  try {
    const client = stubClient([{ rows: [{ user_id: 'u2' }, { user_id: 'u3' }] }]);
    assert.deepEqual(
      await receipts.markDeliveredToOnline(client, { channelId: 'c1', senderId: 'u1' }),
      [],
    );
    // One statement: the roster read. No UPDATE, because an UPDATE here would be
    // the bug — a second tick for a phone that is switched off.
    assert.equal(client.calls.length, 1);
  } finally {
    bus.isUserOnline = originalOnline;
  }
});

test('7 — a system message has no sender to exclude and does not crash on it', async () => {
  const bus = require('../src/realtime/bus');
  const originalOnline = bus.isUserOnline;
  bus.isUserOnline = () => false;
  try {
    const client = stubClient([{ rows: [] }]);
    await receipts.markDeliveredToOnline(client, { channelId: 'c1', senderId: null });
    // `user_id <> NULL` is NULL for every row and would silently exclude the whole
    // roster, so the guard has to be in the predicate.
    assert.match(client.calls[0].text, /\$2::uuid IS NULL OR user_id <> \$2/);
    assert.deepEqual(client.calls[0].params, ['c1', null]);
  } finally {
    bus.isUserOnline = originalOnline;
  }
});

test('8 — connect stamps delivered across every live membership in one statement', async () => {
  const client = stubClient([{
    rows: [
      { channel_id: 'c1', last_delivered_at: ts('2026-10-04T10:00:00Z') },
      { channel_id: 'c2', last_delivered_at: ts('2026-10-04T10:00:00Z') },
    ],
  }]);
  const ids = await receipts.markDeliveredOnConnect(client, 'u1');
  assert.equal(client.calls.length, 1, 'connect is making more than one round trip');
  assert.match(client.calls[0].text, /RETURNING channel_id, last_delivered_at/);
  // The ids come back so presence reuses them instead of re-reading the roster.
  assert.deepEqual(ids, ['c1', 'c2']);
});

// ───────────────────────────────────────────────────────────────────────────────
// 2. Joining is not reading
// ───────────────────────────────────────────────────────────────────────────────

test('9 — channel:join stamps delivered and never read', () => {
  const join = EVENTS_SRC.slice(
    EVENTS_SRC.indexOf("socket.on('channel:join'"),
    EVENTS_SRC.indexOf("socket.on('channel:leave'"),
  );
  assert.ok(join.length > 0, 'the channel:join handler was not found');
  assert.match(join, /receipts\.markDelivered\(/);
  // The original fault, written as a rule: a reconnect while the phone is asleep
  // must not be able to report that somebody read anything.
  assert.ok(!/markRead|last_read_at/.test(join),
    'channel:join is marking the channel read again');
});

test('10 — the room is only joined once the membership check has passed', () => {
  const join = EVENTS_SRC.slice(
    EVENTS_SRC.indexOf("socket.on('channel:join'"),
    EVENTS_SRC.indexOf("socket.on('channel:leave'"),
  );
  // Every later handler trusts socket.rooms as proof of membership, so the guard
  // has to come before the join or that proof is worthless.
  assert.ok(join.indexOf('if (!marks) return') < join.indexOf('socket.join('),
    'the room is joined before membership is proven');
});

test('11 — message:read is the only socket path that moves the read watermark', () => {
  const read = EVENTS_SRC.slice(EVENTS_SRC.indexOf("socket.on('message:read'"));
  assert.match(read, /receipts\.markRead\(/);
  // And it still requires the room, which is the membership proof.
  assert.match(read, /!inChannel\(channelId\)/);
});

test('12 — no handler writes a watermark with its own UPDATE any more', () => {
  // Three callers had three copies of these two statements and they had drifted
  // in three different ways. One home, or the ticks go wrong again.
  for (const [name, source] of [
    ['realtime/chatEvents.js', EVENTS_SRC],
    ['realtime/index.js', RT_INDEX_SRC],
    ['routes/chat.js', ROUTES_SRC],
  ]) {
    assert.ok(!/SET last_read_at|SET last_delivered_at/.test(source),
      `${name} is still writing a watermark directly`);
  }
});

test('13 — a receipt reaches the reader\'s own devices, not only the room', () => {
  // The inbox sits mounted underneath the open thread and has no other way to
  // learn that the room it shows a badge for has just been read.
  const BUS_SRC = src('realtime', 'bus.js');
  const emit = BUS_SRC.slice(BUS_SRC.indexOf('function emitReceipt'));
  assert.match(emit, /io\.to\(\[channelRoom\(channelId\), userRoom\(userId\)\]\)/);
  assert.match(RECEIPTS_SRC, /bus\.emitReceipt\(/);
});

// ───────────────────────────────────────────────────────────────────────────────
// 3. The second tick is wired to the send
// ───────────────────────────────────────────────────────────────────────────────

test('14 — sending a message stamps delivered for everyone already online', () => {
  const send = ROUTES_SRC.slice(
    ROUTES_SRC.indexOf("router.post('/:channelId/messages'"),
    ROUTES_SRC.indexOf('// Read MARK'),
  );
  assert.ok(send.length > 0, 'the send route was not found');
  assert.match(send, /receipts\.markDeliveredToOnline\(/);
  // After the emit, so "delivered" is a statement about a push that has happened.
  assert.ok(send.indexOf('emitPersistedMessage') < send.indexOf('markDeliveredToOnline'),
    'delivered is stamped before the message is pushed');
  // And not for a retried clientId, which was delivered the first time.
  assert.match(send, /if \(!out\.duplicate\) \{\s*await receipts\.markDeliveredToOnline/);
});

test('15 — creating a poll earns the same second tick a message does', () => {
  const polls = ROUTES_SRC.slice(
    ROUTES_SRC.indexOf("router.post('/:channelId/polls'"),
    ROUTES_SRC.indexOf("router.post('/:channelId/polls/:pollId/vote'"),
  );
  assert.match(polls, /receipts\.markDeliveredToOnline\(/);
});

test('16 — the REST read route broadcasts, instead of writing the row and telling nobody', () => {
  const route = ROUTES_SRC.slice(
    ROUTES_SRC.indexOf("router.post('/:channelId/read'"),
    ROUTES_SRC.indexOf('// Members  (the tick'),
  );
  assert.ok(route.length > 0, 'the read route was not found');
  assert.match(route, /receipts\.markRead\(/);
  // A null answer is "not a member", and it has to stay a 403 rather than
  // becoming a cheerful 200.
  assert.match(route, /if \(!marks\) return fail\(res, 403/);
});

// ───────────────────────────────────────────────────────────────────────────────
// 4. The history window
// ───────────────────────────────────────────────────────────────────────────────

test('17 — the membership check returns the reader\'s history boundary', () => {
  const fn = ROUTES_SRC.slice(
    ROUTES_SRC.indexOf('async function member('),
    ROUTES_SRC.indexOf('async function liveMemberCount('),
  );
  assert.match(fn, /m\.history_from/);
});

test('18 — every endpoint that returns message content applies the boundary', () => {
  // Four doors into a room's backlog. A boundary on three of them is not a
  // boundary: the timeline, the pinned banner, the media gallery and the unread
  // count all read the same rows.
  const history = ROUTES_SRC.slice(
    ROUTES_SRC.indexOf("router.get('/:channelId/messages'"),
    ROUTES_SRC.indexOf('// Send'),
  );
  assert.match(history, /\$5::timestamptz IS NULL OR m\.created_at >= \$5/);
  assert.match(history, /m\.history_from/);

  const pinned = ROUTES_SRC.slice(
    ROUTES_SRC.indexOf("router.get('/:channelId/pinned'"),
    ROUTES_SRC.indexOf("router.post('/:channelId/messages/:messageId/pin'"),
  );
  assert.match(pinned, /m\.history_from/);

  const media = ROUTES_SRC.slice(ROUTES_SRC.indexOf("router.get('/:channelId/media'"));
  assert.match(media.slice(0, 900), /since: m\.history_from/);
});

test('19 — the pinned and media reads carry the bound into their SQL', () => {
  const pinned = CORE_SRC.slice(
    CORE_SRC.indexOf('async function listPinned'),
    CORE_SRC.indexOf('async function listMedia'),
  );
  assert.match(pinned, /\$3::timestamptz IS NULL OR m\.created_at >= \$3/);
  const media = CORE_SRC.slice(
    CORE_SRC.indexOf('async function listMedia'),
    CORE_SRC.indexOf('// The other two channel TYPES'),
  );
  assert.match(media, /\$4::timestamptz IS NULL OR m\.created_at >= \$4/);
});

test('20 — the unread count cannot count a message the reader may not open', () => {
  // A badge counting messages behind the boundary is a count that opening the
  // thread can never clear, which is the one thing a badge must never be.
  const m = LIST_SRC.match(/const UNREAD_SQL = `([\s\S]*?)`;/);
  assert.ok(m, 'UNREAD_SQL not found');
  assert.match(m[1], /history_from/);
});

test('21 — a membership stamps its history start on creation', () => {
  for (const name of ['syncTeamMember', 'addMember']) {
    const fn = CORE_SRC.slice(CORE_SRC.indexOf(`async function ${name}`));
    const stmt = fn.slice(0, fn.indexOf('}\n'));
    assert.match(stmt, /history_from/, `${name} does not set history_from`);
    assert.match(stmt, /VALUES \(\$1, \$2, \$3, now\(\)\)/,
      `${name} does not stamp now() on the insert`);
  }
});

test('22 — a role change moves neither the join date nor the history start', () => {
  // This is why the boundary is not keyed on joined_at: syncTeamMember is what a
  // PROMOTION goes through, and it used to rewrite joined_at on every call. A
  // boundary on that column would have deleted a promoted member's history.
  const fn = CORE_SRC.slice(
    CORE_SRC.indexOf('async function syncTeamMember'),
    CORE_SRC.indexOf('async function removeTeamMember'),
  );
  assert.ok(!/SET role = EXCLUDED\.role,\s*left_at = NULL,\s*joined_at = now\(\)/.test(fn),
    'a role change still rewrites joined_at');
  // Both are moved only on the rejoin branch, guarded by the same condition.
  const guards = fn.match(/CASE WHEN chat_channel_members\.left_at IS NOT NULL/g) || [];
  assert.equal(guards.length, 2, 'joined_at and history_from are not both guarded');
});

test('23 — rejoining starts a fresh window rather than restoring the gap', () => {
  const fn = CORE_SRC.slice(
    CORE_SRC.indexOf('async function addMember'),
    CORE_SRC.indexOf('async function ensureBookingChannel'),
  );
  assert.match(fn, /history_from = CASE WHEN chat_channel_members\.left_at IS NOT NULL/);
});

test('24 — the member list exposes the boundary, because the group tick needs it', () => {
  // A member who joined after a message cannot see it, so they must not be able
  // to hold its ticks at one grey for everybody else forever.
  const route = ROUTES_SRC.slice(
    ROUTES_SRC.indexOf("router.get('/:channelId/members'"),
    ROUTES_SRC.indexOf('// REACTIONS'),
  );
  assert.match(route, /cm\.history_from/);
});

// ───────────────────────────────────────────────────────────────────────────────
// 5. Polls are for groups
// ───────────────────────────────────────────────────────────────────────────────

test('25 — a poll needs a group, and the threshold is counted not assumed', () => {
  assert.match(ROUTES_SRC, /const POLL_MIN_MEMBERS = 3;/);
  const polls = ROUTES_SRC.slice(
    ROUTES_SRC.indexOf("router.post('/:channelId/polls'"),
    ROUTES_SRC.indexOf("router.post('/:channelId/polls/:pollId/vote'"),
  );
  assert.match(polls, /liveMemberCount\(client, req\.params\.channelId\) < POLL_MIN_MEMBERS/);
  assert.match(polls, /return fail\(res, 400,/);
  // The refusal comes before any of the ballot validation, so a two-person room
  // gets the reason rather than a complaint about its options.
  assert.ok(polls.indexOf('POLL_MIN_MEMBERS') < polls.indexOf('A poll needs a question'),
    'the group check runs after the question is validated');
});

test('26 — the member count is live members only', () => {
  const fn = ROUTES_SRC.slice(
    ROUTES_SRC.indexOf('async function liveMemberCount('),
    ROUTES_SRC.indexOf('const POLL_MIN_MEMBERS'),
  );
  // Somebody who left is not a participant and must not keep a dead room
  // pollable.
  assert.match(fn, /left_at IS NULL/);
});

test('27 — voting is not gated, only creating', () => {
  // A poll that exists in a room has to stay usable by everyone in it, including
  // if the room later shrinks — otherwise a ballot becomes unanswerable.
  const vote = ROUTES_SRC.slice(ROUTES_SRC.indexOf("router.post('/:channelId/polls/:pollId/vote'"));
  assert.ok(!/POLL_MIN_MEMBERS/.test(vote.slice(0, 800)),
    'voting is gated on the member count');
});
