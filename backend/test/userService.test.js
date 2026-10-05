/**
 * userService.publicProfile tests — player profile visibility (public / private).
 *
 * Run:  npm test            (from backend/), or  node --test test/userService.test.js
 *
 * Same shape as requests.test.js: publicProfile takes a db handle, so a fake client
 * that records its queries and answers from canned rows drives every branch with the
 * database off. The point the tests pin hardest is the privacy contract — a private
 * profile seen by a stranger must carry ONLY the header, with the detail keys absent
 * (not nulled), so nothing can leak through a field the client forgot to hide.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const svc = require('../src/services/userService');

const V = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; // a viewer
const U = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'; // the player being viewed

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

// A player row as the base query returns it. Overridable per test.
const playerRow = (over = {}) => ({
  id: U, name: 'Sara', avatar_url: 'http://x/a.png', created_at: 'JOINED', role: 'player',
  is_public: true, bio: 'Left winger.', sport_preferences: ['football'],
  elo_rating: 1180, trust_score: 88, ...over,
});

// Answer the base identity query; the teams and activity queries default to empty.
function baseResponder(row, { teams = [], bookings = 0 } = {}) {
  return (sql) => {
    if (/FROM users u/.test(sql)) return { rows: row ? [row] : [] };
    if (/FROM team_members tm/.test(sql)) return { rows: teams };
    if (/FROM bookings b/.test(sql)) return { rows: [{ n: bookings }] };
    return null;
  };
}

// ── guards ──────────────────────────────────────────────────────────────────────

test('1 — a non-uuid id is a 404 before any query', async () => {
  const c = mkClient();
  const r = await svc.publicProfile(c, { viewerId: V, targetId: 'nope' });
  assert.equal(r.status, 404);
  assert.equal(c.calls.length, 0);
});

test('2 — a missing user is a 404', async () => {
  const c = mkClient(baseResponder(null));
  const r = await svc.publicProfile(c, { viewerId: V, targetId: U });
  assert.equal(r.status, 404);
  assert.equal(c.calls.length, 1);                 // only the identity read ran
});

test('3 — a non-player (owner) has no public profile: 404', async () => {
  const c = mkClient(baseResponder(playerRow({ role: 'owner' })));
  const r = await svc.publicProfile(c, { viewerId: V, targetId: U });
  assert.equal(r.status, 404);
});

// ── the public payload ────────────────────────────────────────────────────────────

test('4 — a public profile returns the full detail from real columns', async () => {
  const c = mkClient(baseResponder(playerRow(), {
    teams: [{
      id: 't1', name: 'Falcons', sport: 'football', logo_url: null, role: 'captain',
      elo: 1230, wins: 5, losses: 2, draws: 1,
    }],
    bookings: 4,
  }));
  const r = await svc.publicProfile(c, { viewerId: V, targetId: U });
  assert.equal(r.status, 200);
  assert.equal(r.data.isPublic, true);
  assert.equal(r.data.isSelf, false);
  assert.equal(r.data.name, 'Sara');
  assert.equal(r.data.eloRating, 1180);
  assert.equal(r.data.trustScore, 88);
  assert.equal(r.data.memberSince, 'JOINED');
  assert.equal(r.data.bio, 'Left winger.');
  assert.deepEqual(r.data.sports, ['football']);
  assert.equal(r.data.bookings30d, 4);
  assert.equal(r.data.teams.length, 1);
  assert.deepEqual(r.data.teams[0], {
    id: 't1', name: 'Falcons', sport: 'football', logoUrl: null, role: 'captain',
    elo: 1230, wins: 5, losses: 2, draws: 1,
  });
});

test('5 — ELO carries its 1000 seed and a null trust stays null (never fabricated)', async () => {
  const c = mkClient(baseResponder(playerRow({ elo_rating: 1000, trust_score: null, bio: null, sport_preferences: null })));
  const r = await svc.publicProfile(c, { viewerId: V, targetId: U });
  assert.equal(r.data.eloRating, 1000);
  assert.equal(r.data.trustScore, null);
  assert.equal(r.data.bio, null);
  assert.deepEqual(r.data.sports, []);               // null preferences to empty, not invented
});

// ── the privacy contract ────────────────────────────────────────────────────────

test('6 — a private profile seen by a stranger is the header ALONE: detail keys absent', async () => {
  const c = mkClient(baseResponder(playerRow({ is_public: false })));
  const r = await svc.publicProfile(c, { viewerId: V, targetId: U });
  assert.equal(r.status, 200);
  assert.equal(r.data.isPublic, false);
  assert.equal(r.data.isSelf, false);
  // The header the viewer is allowed to see.
  assert.equal(r.data.name, 'Sara');
  assert.equal(r.data.eloRating, 1180);
  assert.equal(r.data.trustScore, 88);
  // The withheld detail must be ABSENT, not null — nothing to leak.
  assert.ok(!('sports' in r.data), 'sports withheld');
  assert.ok(!('bio' in r.data), 'bio withheld');
  assert.ok(!('teams' in r.data), 'teams withheld');
  assert.ok(!('bookings30d' in r.data), 'activity withheld');
  // And the service never even reads the detail for a private stranger view.
  assert.equal(c.calls.length, 1);
  assert.ok(!c.calls.some((q) => /FROM team_members tm/.test(q.sql)));
});

test('7 — a player viewing their OWN private profile sees everything (isSelf wins)', async () => {
  const c = mkClient(baseResponder(playerRow({ is_public: false }), { teams: [], bookings: 0 }));
  const r = await svc.publicProfile(c, { viewerId: U, targetId: U });
  assert.equal(r.data.isPublic, false);
  assert.equal(r.data.isSelf, true);
  assert.ok('sports' in r.data, 'own detail is visible');
  assert.ok('teams' in r.data);
  assert.deepEqual(r.data.teams, []);
});

test('8 — a null is_public (no profile row) reads as public', async () => {
  const c = mkClient(baseResponder(playerRow({ is_public: null })));
  const r = await svc.publicProfile(c, { viewerId: V, targetId: U });
  assert.equal(r.data.isPublic, true);
  assert.ok('teams' in r.data);
});

// ── static source: migration 037 is additive and defaults public ─────────────────

const SRC = (...p) => fs.readFileSync(path.join(__dirname, '..', ...p), 'utf8');
const MIG037 = SRC('migrations', '037_player_profile_visibility.sql');

test('9 — 037 adds is_public NOT NULL DEFAULT true and bio, additively', () => {
  assert.ok(/ADD COLUMN IF NOT EXISTS is_public boolean NOT NULL DEFAULT true/.test(MIG037));
  assert.ok(/ADD COLUMN IF NOT EXISTS bio text/.test(MIG037));
  assert.ok(!/DROP TABLE/i.test(MIG037));
  assert.ok(!/DROP COLUMN/i.test(MIG037));
  assert.ok(!/TRUNCATE/i.test(MIG037));
  assert.ok(!/DELETE FROM/i.test(MIG037));
  assert.ok(!/UPDATE player_profiles SET/i.test(MIG037));  // no data rewrite
});

// ── static source: the route is wired and the service is exported ─────────────────

const USERS_ROUTE = SRC('src', 'routes', 'users.js');

test('10 — the public-profile route is declared and delegates to the service', () => {
  assert.ok(USERS_ROUTE.includes("router.get('/:id/public-profile'"));
  assert.ok(USERS_ROUTE.includes('userService.publicProfile'));
  assert.equal(typeof svc.publicProfile, 'function');
});

test('11 — /me/update accepts isPublic and bio, and writes them player-side', () => {
  assert.ok(/const \{ name, email, sportPreferences, avatarUrl, isPublic, bio \}/.test(USERS_ROUTE));
  assert.ok(USERS_ROUTE.includes('UPDATE player_profiles SET is_public = $1 WHERE user_id = $2'));
  assert.ok(USERS_ROUTE.includes('UPDATE player_profiles SET bio = $1 WHERE user_id = $2'));
});
