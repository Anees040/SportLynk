/**
 * requestService state-machine tests (module 8c — direct play requests)
 *
 * Run:  npm test            (from backend/), or  node --test test/requests.test.js
 *
 * The live routes and check scripts prove the rows against Supabase. This file
 * proves the state machine and its guards the way chat.test.js proves the chat
 * tables: with the database off. Every service function takes an open `client`,
 * so a fake client that records its queries and returns canned rows drives each
 * branch without a connection. The two heavy chat helpers are replaced per test;
 * notify() runs against the fake client, so the accept path genuinely writes its
 * notification row and the decline path can be proven to write nothing.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const svc = require('../src/services/requestService');
const chatCore = require('../src/utils/chatCore');

// Valid uuids; RE_UUID in teamAccess accepts any 8-4-4-4-12 hex string.
const R = '11111111-1111-1111-1111-111111111111';  // a requester
const T = '22222222-2222-2222-2222-222222222222';  // a target
const ID = '33333333-3333-3333-3333-333333333333'; // a request id

/**
 * A client that records every query and answers from `responder(sql, params)`.
 * A returned Error is thrown (to drive the 23505 branch); a nullish answer
 * becomes an empty result set. Never opens a real connection.
 */
function mkClient(responder) {
  const calls = [];
  return {
    calls,
    async query(sql, params) {
      calls.push({ sql, params });
      const out = responder ? responder(sql, params) : null;
      if (out instanceof Error) throw out;
      return out || { rows: [] };
    },
  };
}

const ran = (c, re) => c.calls.some((q) => re.test(q.sql));
const callWith = (c, re) => c.calls.find((q) => re.test(q.sql));

// ── createRequest ────────────────────────────────────────────────────────────

test('1 — a request to yourself is refused before any query', async () => {
  const c = mkClient();
  const r = await svc.createRequest(c, { requesterId: T, targetUserId: T });
  assert.equal(r.status, 400);
  assert.equal(r.code, 'self');
  assert.equal(c.calls.length, 0);
});

test('2 — a non-uuid target is a 404, not a database round trip', async () => {
  const c = mkClient();
  const r = await svc.createRequest(c, { requesterId: R, targetUserId: 'nope' });
  assert.equal(r.status, 404);
  assert.equal(c.calls.length, 0);
});

test('3 — a target who is not an active player is a 404 and pings no one', async () => {
  const c = mkClient((sql) => (/id = ANY/.test(sql)
    ? {
      rows: [{ id: R, role: 'player', is_active: true },
        { id: T, role: 'owner', is_active: true }],
    }
    : null));
  const r = await svc.createRequest(c, { requesterId: R, targetUserId: T });
  assert.equal(r.status, 404);
  assert.equal(c.calls.length, 1);                 // only the users lookup ran
  assert.ok(!ran(c, /INSERT INTO notifications/));
});

test('4 — a second pending ask in the same direction is a friendly 409', async () => {
  const c = mkClient((sql) => {
    if (/id = ANY/.test(sql)) {
      return {
        rows: [{ id: R, role: 'player', is_active: true },
          { id: T, role: 'player', is_active: true, is_public: true }],
      };
    }
    if (/INSERT INTO play_requests/.test(sql)) {
      return Object.assign(new Error('dup'), { code: '23505' });
    }
    return null;
  });
  const r = await svc.createRequest(c, { requesterId: R, targetUserId: T });
  assert.equal(r.status, 409);
  assert.equal(r.code, 'duplicate');
});

test('5 — a created request is 201 and pings the target with play_request', async () => {
  const c = mkClient((sql) => {
    if (/id = ANY/.test(sql)) {
      return {
        rows: [{ id: R, name: 'Bilal', role: 'player', is_active: true, is_public: true },
          { id: T, name: 'Sara', role: 'player', is_active: true, is_public: true }],
      };
    }
    if (/INSERT INTO play_requests/.test(sql)) {
      return {
        rows: [{
          id: 'req-1', status: 'pending', sport: 'cricket',
          message: null, created_at: 'C', expires_at: 'E',
        }],
      };
    }
    if (/INSERT INTO notifications/.test(sql)) return { rows: [{ id: 'n1', group_count: 1 }] };
    return null;                                     // SAVEPOINT / RELEASE
  });
  const r = await svc.createRequest(c, { requesterId: R, targetUserId: T, sport: 'cricket' });
  assert.equal(r.status, 201);
  assert.equal(r.data.id, 'req-1');
  assert.equal(r.data.otherUserId, T);
  const n = callWith(c, /INSERT INTO notifications/);
  assert.ok(n, 'the target is notified inside the same transaction');
  assert.equal(n.params[0], T);                      // recipient is the target
  assert.equal(n.params[2], 'play_request');         // the ask, not the accept
});

test('5b — a private player cannot be asked: 403 profile_private, and no row is written', async () => {
  const c = mkClient((sql) => (/id = ANY/.test(sql)
    ? {
      rows: [{ id: R, name: 'Bilal', role: 'player', is_active: true, is_public: true },
        { id: T, name: 'Sara', role: 'player', is_active: true, is_public: false }],
    }
    : null));
  const r = await svc.createRequest(c, { requesterId: R, targetUserId: T });
  assert.equal(r.status, 403);
  assert.equal(r.code, 'profile_private');
  assert.equal(c.calls.length, 1);                   // only the lookup ran
  assert.ok(!ran(c, /INSERT INTO play_requests/));   // nothing inserted
  assert.ok(!ran(c, /INSERT INTO notifications/));   // nobody pinged
});

test('5c — a null is_public (a player with no profile row) is treated as public', async () => {
  const c = mkClient((sql) => {
    if (/id = ANY/.test(sql)) {
      return {
        rows: [{ id: R, name: 'Bilal', role: 'player', is_active: true, is_public: true },
          { id: T, name: 'Sara', role: 'player', is_active: true, is_public: null }],
      };
    }
    if (/INSERT INTO play_requests/.test(sql)) {
      return { rows: [{ id: 'req-2', status: 'pending', sport: null, message: null, created_at: 'C', expires_at: 'E' }] };
    }
    if (/INSERT INTO notifications/.test(sql)) return { rows: [{ id: 'n1', group_count: 1 }] };
    return null;
  });
  const r = await svc.createRequest(c, { requesterId: R, targetUserId: T });
  assert.equal(r.status, 201);                       // null visibility does not block the ask
});

// ── respond: guards ───────────────────────────────────────────────────────────

test('6 — respond on a non-uuid id is a 404 before any query', async () => {
  const c = mkClient();
  const r = await svc.respond(c, { id: 'nope', userId: T, action: 'accept' });
  assert.equal(r.status, 404);
  assert.equal(c.calls.length, 0);
});

test('7 — an action that is neither accept nor decline is a 400', async () => {
  const c = mkClient();
  const r = await svc.respond(c, { id: ID, userId: T, action: 'maybe' });
  assert.equal(r.status, 400);
  assert.equal(r.code, 'bad_action');
  assert.equal(c.calls.length, 0);
});

test('8 — responding to a request that is no longer pending is a 409', async () => {
  const c = mkClient(() => ({ rows: [] }));          // the transition matches zero rows
  const r = await svc.respond(c, { id: ID, userId: T, action: 'accept' });
  assert.equal(r.status, 409);
  assert.equal(r.code, 'not_pending');
  assert.equal(c.calls.length, 1);                   // only the guarded UPDATE ran
});

test('9 — a decline moves exactly one row: no room, no notification', async () => {
  const c = mkClient((sql) => (/UPDATE play_requests SET status = \$3/.test(sql)
    ? { rows: [{ requester_user_id: R, target_user_id: T, sport: null }] }
    : null));
  const r = await svc.respond(c, { id: ID, userId: T, action: 'decline' });
  assert.equal(r.status, 200);
  assert.equal(r.data.status, 'declined');
  assert.equal(r.data.channelId, null);
  assert.equal(c.calls.length, 1);                   // the transition, and nothing after it
  assert.ok(!ran(c, /SET channel_id/));
  assert.ok(!ran(c, /INSERT INTO notifications/));
});

test('10 — an accept opens the direct room, records it, and pings the requester', async () => {
  let ensureArgs = null;
  let postChannel = null;
  const realEnsure = chatCore.ensureDirectChannel;
  const realPost = chatCore.postSystemMessage;
  chatCore.ensureDirectChannel = async (...a) => { ensureArgs = a; return 'chan-1'; };
  chatCore.postSystemMessage = async (client, channelId) => {
    postChannel = channelId;
    return { message: { id: 'msg-1' } };
  };
  try {
    const c = mkClient((sql) => {
      if (/SET channel_id/.test(sql)) return { rows: [] };
      if (/UPDATE play_requests SET status = \$3/.test(sql)) {
        return { rows: [{ requester_user_id: R, target_user_id: T, sport: 'football' }] };
      }
      if (/SELECT name FROM users/.test(sql)) return { rows: [{ name: 'Sara' }] };
      if (/INSERT INTO notifications/.test(sql)) return { rows: [{ id: 'n1', group_count: 1 }] };
      return null;
    });
    const r = await svc.respond(c, { id: ID, userId: T, action: 'accept' });
    assert.equal(r.data.status, 'accepted');
    assert.equal(r.data.channelId, 'chan-1');
    assert.deepEqual(r.pill, { channelId: 'chan-1', messageId: 'msg-1' });
    assert.deepEqual(ensureArgs, [c, R, T]);          // paired requester and acceptor
    assert.equal(postChannel, 'chan-1');
    assert.ok(ran(c, /UPDATE play_requests SET channel_id = \$2/));
    const n = callWith(c, /INSERT INTO notifications/);
    assert.equal(n.params[0], R);                     // the requester is pinged
    assert.equal(n.params[2], 'play_request_accepted');
    assert.equal(n.params[5].channelType, 'direct');  // payload carries the room
    assert.equal(n.params[5].channelId, 'chan-1');
  } finally {
    chatCore.ensureDirectChannel = realEnsure;
    chatCore.postSystemMessage = realPost;
  }
});

// ── cancel ────────────────────────────────────────────────────────────────────

test('11 — cancel on a non-uuid id is a 404 before any query', async () => {
  const c = mkClient();
  const r = await svc.cancel(c, { id: 'nope', userId: R });
  assert.equal(r.status, 404);
  assert.equal(c.calls.length, 0);
});

test('12 — cancelling a request that is not pending (or not yours) is a 409', async () => {
  const c = mkClient(() => ({ rows: [] }));
  const r = await svc.cancel(c, { id: ID, userId: R });
  assert.equal(r.status, 409);
  assert.equal(c.calls.length, 1);
});

test('13 — the requester withdraws their own pending ask', async () => {
  const c = mkClient((sql) => (/SET status = 'cancelled'/.test(sql) ? { rows: [{ id: ID }] } : null));
  const r = await svc.cancel(c, { id: ID, userId: R });
  assert.equal(r.status, 200);
  assert.equal(r.data.status, 'cancelled');
});

// ── incoming / outgoing: the shared card, one query with a filter argument ──────

test('14 — an incoming row maps to the inbox card; a null channel stays null', async () => {
  const c = mkClient(() => ({
    rows: [{
      id: 42, sport: 'tennis', message: 'hi', status: 'pending', channel_id: null,
      created_at: 'C', decided_at: null, expires_at: 'E',
      other_user_id: R, other_name: 'Bilal', other_avatar: null, trust_score: 90,
    }],
  }));
  const r = await svc.incoming(c, T, {});
  assert.equal(r.data[0].id, '42');                  // stringified
  assert.equal(r.data[0].channelId, null);
  assert.equal(r.data[0].otherUserId, R);
  assert.equal(r.data[0].otherName, 'Bilal');
  assert.equal(r.data[0].trustScore, 90);
});

test('15 — outgoing passes the status filter as $2, and null when it is absent', async () => {
  const c = mkClient(() => ({ rows: [] }));
  await svc.outgoing(c, R, {});
  await svc.outgoing(c, R, { status: 'accepted' });
  assert.equal(c.calls[0].params[1], null);
  assert.equal(c.calls[1].params[1], 'accepted');
});

// ── discoverPlayers: honest, and clamped ────────────────────────────────────────

test('16 — the discovery limit is clamped to [1, 60], defaulting to 40', async () => {
  const seen = [];
  const c = mkClient((sql, params) => {
    if (/JOIN player_profiles pp/.test(sql)) seen.push(params[3]);
    return { rows: [] };
  });
  await svc.discoverPlayers(c, { userId: R, limit: -1 });
  await svc.discoverPlayers(c, { userId: R, limit: 999 });
  await svc.discoverPlayers(c, { userId: R, limit: 5 });
  await svc.discoverPlayers(c, { userId: R });
  assert.deepEqual(seen, [1, 60, 5, 40]);
});

test('17 — discovery invents nothing: a null trust stays null, a null sport list is empty', async () => {
  const c = mkClient(() => ({
    rows: [
      {
        user_id: 'u9', name: 'Zed', avatar_url: null, sports: ['football', 'cricket'],
        trust_score: 72, is_public: true, bookings_30d: 3, plays_sport: true, pending_request: false,
      },
      {
        user_id: 'u10', name: 'Amy', avatar_url: 'http://x/a.png', sports: null,
        trust_score: null, is_public: false, bookings_30d: 0, plays_sport: false, pending_request: true,
      },
    ],
  }));
  const r = await svc.discoverPlayers(c, { userId: R, sport: 'football' });
  assert.deepEqual(r.data[0], {
    userId: 'u9', name: 'Zed', avatarUrl: null, sports: ['football', 'cricket'],
    trustScore: 72, isPublic: true, bookings30d: 3, playsSport: true, pendingRequest: false,
  });
  assert.equal(r.data[1].trustScore, null);          // not a fabricated default
  assert.deepEqual(r.data[1].sports, []);            // null preferences to empty, not invented
  assert.equal(r.data[1].pendingRequest, true);
  assert.equal(r.data[1].isPublic, false);           // a private player is flagged, not hidden
});

// ── static source: the service invariants behaviour alone cannot pin ────────────

const SRC = (...p) => fs.readFileSync(path.join(__dirname, '..', ...p), 'utf8');
const SVC_SRC = SRC('src', 'services', 'requestService.js');

test('18 — every service function and the TTL constant are exported', () => {
  for (const fn of ['createRequest', 'incoming', 'outgoing', 'respond', 'cancel', 'discoverPlayers']) {
    assert.equal(typeof svc[fn], 'function', `${fn} is exported`);
  }
  assert.ok(Number.isInteger(svc.REQUEST_TTL_DAYS) && svc.REQUEST_TTL_DAYS > 0);
});

test('19 — create stamps expires_at from the TTL, and decline returns before any room opens', () => {
  assert.ok(
    SVC_SRC.includes("now() + ($5 || ' days')::interval"),
    'expires_at is set in SQL from the TTL argument',
  );
  // The decline early-return must precede the room-opening call, or a decline would
  // open a channel. Ordering inside respond() is the guarantee; slice past the header
  // comment, which also names ensureDirectChannel.
  const respondSrc = SVC_SRC.slice(SVC_SRC.indexOf('async function respond'));
  assert.ok(respondSrc.indexOf('channelId: null') < respondSrc.indexOf('ensureDirectChannel'));
  // One transition guard covers not-found, not-yours and a double tap, on both paths.
  assert.ok(SVC_SRC.includes("target_user_id = $2 AND status = 'pending'"));
  assert.ok(SVC_SRC.includes("requester_user_id = $2 AND status = 'pending'"));
});

// ── static source: migration 028 (play_requests + direct rooms) ─────────────────

const MIG028 = SRC('migrations', '028_play_requests.sql');

test('20 — at most one live ask per direction: a partial unique index on pending', () => {
  assert.ok(/CREATE UNIQUE INDEX IF NOT EXISTS ux_play_requests_pending/.test(MIG028));
  assert.ok(MIG028.includes('ON play_requests (requester_user_id, target_user_id)'));
  assert.ok(MIG028.includes("WHERE status = 'pending'"));
});

test('21 — the status CHECK is the five-state machine, and a request cannot target itself', () => {
  assert.ok(MIG028.includes(
    "CHECK (status IN ('pending', 'accepted', 'declined', 'cancelled', 'expired'))",
  ));
  assert.ok(MIG028.includes('CHECK (requester_user_id <> target_user_id)'));
});

test('22 — the chat_channels type CHECK is widened to allow direct rooms', () => {
  assert.ok(MIG028.includes(
    "CHECK (type IN ('team', 'captain', 'booking', 'assistant', 'direct'))",
  ));
});

test('23 — direct_channels keeps a pair to one room: canonical order, unique channel', () => {
  assert.ok(MIG028.includes('CHECK (user_lo < user_hi)'));
  assert.ok(MIG028.includes('channel_id UUID NOT NULL UNIQUE'));
  assert.ok(MIG028.includes('PRIMARY KEY (user_lo, user_hi)'));
});

test('24 — 028 is additive: history survives channel deletion and no data is dropped', () => {
  assert.ok(MIG028.includes('REFERENCES chat_channels(id) ON DELETE SET NULL'));
  assert.ok(!/DROP TABLE/i.test(MIG028));
  assert.ok(!/TRUNCATE/i.test(MIG028));
  assert.ok(!/DELETE FROM/i.test(MIG028));
});

// ── static source: migration 027 (per-member chat hide) ─────────────────────────

const MIG027 = SRC('migrations', '027_chat_hide.sql');

test('25 — 027 adds hidden_at additively and touches nothing else', () => {
  assert.ok(MIG027.includes('ADD COLUMN IF NOT EXISTS hidden_at timestamptz'));
  assert.equal((MIG027.match(/ALTER TABLE/g) || []).length, 1);  // the one column add
  assert.ok(!/DROP TABLE/i.test(MIG027));
  assert.ok(!/TRUNCATE/i.test(MIG027));
  assert.ok(!/DELETE FROM/i.test(MIG027));
});

// ── static source: the route stays thin, authed, and commits before it emits ─────

const ROUTES = SRC('src', 'routes', 'requests.js');
const SERVER = SRC('src', 'server.js');

test('26 — every request endpoint is declared', () => {
  assert.ok(ROUTES.includes("router.get('/discover'"));
  assert.ok(ROUTES.includes("router.get('/incoming'"));
  assert.ok(ROUTES.includes("router.get('/outgoing'"));
  assert.ok(ROUTES.includes("router.post('/'"));
  assert.ok(ROUTES.includes("router.post('/:id/respond'"));
  assert.ok(ROUTES.includes("router.post('/:id/cancel'"));
});

test('27 — the router authenticates every route', () => {
  assert.ok(ROUTES.includes('router.use(auth)'));
});

test('28 — the accept pill is emitted only after COMMIT', () => {
  const respond = ROUTES.slice(ROUTES.indexOf('/:id/respond'));
  assert.ok(respond.indexOf("await client.query('COMMIT')") < respond.indexOf('emitPills'));
});

test('29 — no business SQL leaks into the route (the state machine is the service)', () => {
  assert.ok(!ROUTES.includes('INSERT INTO play_requests'));
  assert.ok(!ROUTES.includes('UPDATE play_requests'));
});

test('30 — the API is mounted at /api/requests', () => {
  assert.ok(SERVER.includes('require("./routes/requests")'));
  assert.ok(SERVER.includes('app.use("/api/requests", requestRoutes)'));
});
