/**
 * Tournament maths unit tests
 *
 * Run:  npm test            (from backend/)
 *   or  node --test test/fixtures.test.js
 *
 * `src/utils/fixtures.js` imports nothing but `elo.js`, and neither touches a
 * database, so every test here runs with Supabase switched off. That is the
 * point: a bracket that pairs the wrong seeds, a bye that goes to the bottom of
 * the draw, or a prize pool that is one paisa short must fail here in
 * milliseconds — not during a live demo where the only evidence is a wallet
 * balance that does not add up.
 *
 * The four claims the file header makes are each pinned by a test:
 *   3, 5, 6   the bracket is standard: seeds 1 and 2 can only meet in the final
 *   6         byes land on the top seeds, for every field size from 2 to 32
 *   10        K is 40 / 48 / 56 by stake, and exactly 0 for a bye
 *   14-19     pool = venue_cost + prize + margin, to the paisa, always
 */

const test = require('node:test');
const assert = require('node:assert/strict');

const f = require('../src/utils/fixtures');
const elo = require('../src/utils/elo');

/** n teams, strongest first, with distinct ELOs and names. */
const mk = (n, from = 1500) => Array.from({ length: n }, (_, i) => ({
  id: `t${i + 1}`,
  name: `Team ${String.fromCharCode(65 + i)}`,
  elo: from - i * 40,
}));

/** Play a whole knockout out with the higher seed always winning. */
function playFavourites(bracket) {
  const at = new Map(bracket.fixtures.map((x) => [`${x.round}:${x.position}`, x]));
  const seedOf = new Map();
  for (const x of bracket.fixtures) {
    if (x.teamA) seedOf.set(x.teamA, x.seedA);
    if (x.teamB) seedOf.set(x.teamB, x.seedB);
  }
  for (let r = 1; r <= bracket.rounds; r += 1) {
    for (const x of bracket.fixtures.filter((y) => y.round === r)) {
      if (!x.winner) {
        if (!x.teamA || !x.teamB) continue;
        x.winner = seedOf.get(x.teamA) <= seedOf.get(x.teamB) ? x.teamA : x.teamB;
        x.status = f.FIXTURE_STATUS.PLAYED;
      }
      if (!x.nextRound) continue;
      const nxt = at.get(`${x.nextRound}:${x.nextPosition}`);
      if (x.nextSide === 'a') { nxt.teamA = x.winner; nxt.seedA = seedOf.get(x.winner); }
      else { nxt.teamB = x.winner; nxt.seedB = seedOf.get(x.winner); }
    }
  }
  const final = bracket.fixtures.find((x) => x.round === bracket.rounds);
  return { final, champion: final.winner, seedOf };
}

test('1 — seedTeams(): strongest first, deterministic on a tie, input untouched', () => {
  const input = [
    { id: 'c', name: 'Charlie', elo: 1000 },
    { id: 'a', name: 'Alpha', elo: 1200 },
    { id: 'b', name: 'Bravo', elo: 1000 },
  ];
  const copy = JSON.parse(JSON.stringify(input));
  const out = f.seedTeams(input);
  assert.deepEqual(out.map((t) => t.id), ['a', 'b', 'c']);
  assert.deepEqual(out.map((t) => t.seed), [1, 2, 3]);
  // Two 1000s must not swap between runs, or the same field would draw a
  // different bracket every time generation is retried.
  assert.deepEqual(f.seedTeams(input).map((t) => t.id), ['a', 'b', 'c']);
  assert.deepEqual(input, copy, 'seedTeams must not mutate its argument');
  // A missing rating is an unranked 1000, not a NaN that sorts randomly.
  const un = f.seedTeams([{ id: 'x', name: 'X' }, { id: 'y', name: 'Y', elo: '1100' }]);
  assert.deepEqual(un.map((t) => t.id), ['y', 'x']);
  assert.equal(un[1].elo, 1000);
});

test('2 — bracketSize / rounds / byes / fixtureCount: the shape arithmetic', () => {
  const table = [
    // n, size, rounds, byes, nodes, playedKnockout, playedRoundRobin
    [2, 2, 1, 0, 1, 1, 1],
    [3, 4, 2, 1, 3, 2, 3],
    [4, 4, 2, 0, 3, 3, 6],
    [5, 8, 3, 3, 7, 4, 10],
    [6, 8, 3, 2, 7, 5, 15],
    [8, 8, 3, 0, 7, 7, 28],
    [11, 16, 4, 5, 15, 10, 55],
    [16, 16, 4, 0, 15, 15, 120],
    [32, 32, 5, 0, 31, 31, 496],
  ];
  for (const [n, size, rounds, byes, nodes, koPlayed, rrPlayed] of table) {
    assert.equal(f.bracketSize(n), size, `bracketSize(${n})`);
    assert.equal(f.roundsFor(n), rounds, `roundsFor(${n})`);
    assert.equal(f.byeCount(n), byes, `byeCount(${n})`);
    assert.equal(f.bracketNodes(n), nodes, `bracketNodes(${n})`);
    assert.equal(f.fixtureCount(f.FORMATS.KNOCKOUT, n), koPlayed, `knockout fixtures(${n})`);
    assert.equal(f.fixtureCount(f.FORMATS.ROUND_ROBIN, n), rrPlayed, `round robin fixtures(${n})`);
    assert.ok(f.isPowerOfTwo(size));
  }
  // The identity the whole padding scheme rests on.
  for (let n = 2; n <= 32; n += 1) {
    assert.equal(f.bracketNodes(n), f.fixtureCount('knockout', n) + f.byeCount(n),
      `nodes = played + byes at n=${n}`);
  }
  // 8 teams round-robin is 28 fixtures against a knockout's 7 — the reason
  // round-robin is capped at 6 in 019's chk_tournaments_max_teams.
  assert.equal(f.fixtureCount('round_robin', 8), 28);
  assert.equal(f.fixtureCount('round_robin', f.MAX_ROUND_ROBIN_TEAMS), 15);
  assert.equal(f.fixtureCount('knockout', 1), 0);
  assert.equal(f.fixtureCount('knockout', 0), 0);
});

test('3 — bracketOrder(): standard pairings, one top-half seed per pair', () => {
  assert.deepEqual(f.bracketOrder(2), [1, 2]);
  assert.deepEqual(f.bracketOrder(4), [1, 4, 2, 3]);
  assert.deepEqual(f.bracketOrder(8), [1, 8, 4, 5, 2, 7, 3, 6]);

  for (const size of [2, 4, 8, 16, 32]) {
    const order = f.bracketOrder(size);
    // A permutation of 1..size, exactly once each.
    assert.deepEqual([...order].sort((a, b) => a - b),
      Array.from({ length: size }, (_, i) => i + 1), `order(${size}) is a permutation`);
    // Every pair sums to size+1, which is what makes 1 meet the weakest team.
    for (let i = 0; i < size; i += 2) {
      assert.equal(order[i] + order[i + 1], size + 1, `pair ${i / 2 + 1} of ${size}`);
      // Exactly one of the pair is in the top half. This is the property that
      // makes padding safe: dropping the highest seed numbers can never empty a
      // pair, so every bye has a team and it is always the stronger one.
      const top = [order[i], order[i + 1]].filter((s) => s <= size / 2).length;
      assert.equal(top, 1, `pair ${i / 2 + 1} of ${size} must hold one top-half seed`);
    }
  }
});

test('4 — knockoutFixtures(8): a full bracket, no byes, every node wired forward', () => {
  const b = f.knockoutFixtures(f.seedTeams(mk(8)));
  assert.equal(b.size, 8);
  assert.equal(b.rounds, 3);
  assert.equal(b.byes, 0);
  assert.equal(b.played, 7);
  assert.equal(b.fixtures.length, 7);

  // (round, position) is unique — 019 enforces it with UNIQUE (tournament_id,
  // round, position), and an INSERT of duplicates would abort the generation.
  const keys = b.fixtures.map((x) => `${x.round}:${x.position}`);
  assert.equal(new Set(keys).size, keys.length);
  assert.deepEqual(b.fixtures.filter((x) => x.round === 1).map((x) => [x.seedA, x.seedB]),
    [[1, 8], [4, 5], [2, 7], [3, 6]]);
  assert.deepEqual(b.fixtures.filter((x) => x.round === 1).map((x) => x.label),
    ['Quarter-final', 'Quarter-final', 'Quarter-final', 'Quarter-final']);
  assert.equal(b.fixtures.filter((x) => x.round === 2).length, 2);
  assert.equal(b.fixtures.filter((x) => x.round === 3).length, 1);
  assert.equal(b.fixtures.find((x) => x.round === 3).label, 'Final');

  // Rounds after the first open as TBD v TBD — the app draws the empty bracket
  // from day one, so the rows must exist before anyone has played.
  for (const x of b.fixtures.filter((y) => y.round > 1)) {
    assert.equal(x.teamA, null);
    assert.equal(x.teamB, null);
    assert.equal(x.status, 'upcoming');
  }
  // Exactly two nodes feed each later node, one into each side.
  for (const x of b.fixtures.filter((y) => y.round < 3)) {
    const feeders = b.fixtures.filter((y) => y.nextRound === x.nextRound
      && y.nextPosition === x.nextPosition);
    assert.equal(feeders.length, 2);
    assert.deepEqual(feeders.map((y) => y.nextSide).sort(), ['a', 'b']);
  }
  assert.equal(b.fixtures.find((x) => x.round === 3).nextRound, null);
});

test('5 — knockoutFixtures(5): three byes, all to the top seeds, resolved at once', () => {
  const b = f.knockoutFixtures(f.seedTeams(mk(5)));
  assert.equal(b.size, 8);
  assert.equal(b.byes, 3);
  assert.equal(b.played, 4);

  const byes = b.fixtures.filter((x) => x.isBye);
  assert.deepEqual(byes.map((x) => x.seedA).sort((p, q) => p - q), [1, 2, 3]);
  for (const x of byes) {
    // The exact shape 019's chk_fixtures_bye demands, or the INSERT is rejected.
    assert.ok(x.teamA, 'a bye carries its team in team_a');
    assert.equal(x.teamB, null, 'a bye must have team_b NULL');
    assert.equal(x.status, 'walkover');
    assert.equal(x.winner, x.teamA);
    assert.match(x.label, /bye/);
  }
  // The only real first-round match a 5-team draw needs is 4 v 5.
  const real = b.fixtures.filter((x) => x.round === 1 && !x.isBye);
  assert.equal(real.length, 1);
  assert.deepEqual([real[0].seedA, real[0].seedB], [4, 5]);

  // Byes advance immediately, so the semi-finals already name three teams and
  // seed 2 v seed 3 is playable before a ball is kicked in round 1.
  const semis = b.fixtures.filter((x) => x.round === 2);
  assert.equal(semis[0].teamA, 't1');
  assert.equal(semis[0].teamB, null);
  assert.equal(semis[1].teamA, 't2');
  assert.equal(semis[1].teamB, 't3');
  assert.equal(semis[1].isBye, false, 'two bye winners meeting is a real match, not a bye');
});

test('6 — BYES GO TO THE TOP SEEDS, for every field size from 2 to 32', () => {
  for (let n = 2; n <= 32; n += 1) {
    const b = f.knockoutFixtures(f.seedTeams(mk(n)));
    const byes = b.fixtures.filter((x) => x.isBye);
    assert.equal(byes.length, f.byeCount(n), `n=${n} bye count`);
    // The byes are precisely seeds 1..byeCount — the strongest teams, in order,
    // with no gaps. Nothing in the code sorts them that way; it falls out of the
    // bracket ordering, which is why this is worth asserting rather than trusting.
    assert.deepEqual(byes.map((x) => x.seedA).sort((p, q) => p - q),
      Array.from({ length: f.byeCount(n) }, (_, i) => i + 1), `n=${n} bye seeds`);
    // A bye is a round-1 device only: from round 2 on, every node has either two
    // teams or a TBD waiting for a winner.
    assert.ok(byes.every((x) => x.round === 1), `n=${n} byes only in round 1`);
    assert.equal(b.fixtures.length, f.bracketNodes(n), `n=${n} node count`);
    assert.equal(b.played, n - 1, `n=${n} matches actually played`);
    // Every team appears exactly once in round 1, and nobody is left out.
    const inR1 = b.fixtures.filter((x) => x.round === 1)
      .flatMap((x) => [x.teamA, x.teamB]).filter(Boolean);
    assert.equal(inR1.length, n, `n=${n} every team drawn`);
    assert.equal(new Set(inR1).size, n, `n=${n} no team drawn twice`);
  }
});

test('7 — advanceSlot(): ceil(p/2), odd fills team_a, even fills team_b', () => {
  assert.deepEqual(f.advanceSlot(1, 1), { round: 2, position: 1, side: 'a' });
  assert.deepEqual(f.advanceSlot(1, 2), { round: 2, position: 1, side: 'b' });
  assert.deepEqual(f.advanceSlot(1, 3), { round: 2, position: 2, side: 'a' });
  assert.deepEqual(f.advanceSlot(1, 4), { round: 2, position: 2, side: 'b' });
  assert.deepEqual(f.advanceSlot(3, 7), { round: 4, position: 4, side: 'a' });
  assert.equal(f.advanceSlot(0, 1), null);
  assert.equal(f.advanceSlot(1, 0), null);
});

test('8 — seeds 1 and 2 can only meet in the FINAL, and the favourite wins it', () => {
  for (const n of [2, 4, 5, 8, 11, 16]) {
    const b = f.knockoutFixtures(f.seedTeams(mk(n)));
    const { final, champion, seedOf } = playFavourites(b);
    assert.equal(seedOf.get(champion), 1, `n=${n}: the top seed should win every match`);
    assert.deepEqual([final.seedA, final.seedB].sort((p, q) => p - q), [1, 2],
      `n=${n}: the final must be seed 1 v seed 2`);
    // Seeds 1 and 2 must not have met earlier: no other fixture holds both.
    const early = b.fixtures.filter((x) => x.round < b.rounds
      && [x.seedA, x.seedB].includes(1) && [x.seedA, x.seedB].includes(2));
    assert.equal(early.length, 0, `n=${n}: 1 and 2 met before the final`);
  }
});

test('9 — roundLabel(): the words a captain actually reads', () => {
  assert.equal(f.roundLabel(3, 3), 'Final');
  assert.equal(f.roundLabel(2, 3), 'Semi-final');
  assert.equal(f.roundLabel(1, 3), 'Quarter-final');
  assert.equal(f.roundLabel(1, 2), 'Semi-final');
  assert.equal(f.roundLabel(1, 1), 'Final');
  assert.equal(f.roundLabel(1, 4), 'Round of 16');
  assert.equal(f.roundLabel(1, 5), 'Round of 32');
  assert.equal(f.roundLabel(2, 5), 'Round of 16');
  assert.equal(f.roundLabel(3, 5), 'Quarter-final');
  assert.equal(f.roundLabel(2, 5, f.FORMATS.ROUND_ROBIN), 'Matchday 2');
});

test('10 — K-FACTOR: 40 early, 48 semi, 56 final, and exactly 0 for a bye', () => {
  assert.equal(f.kFactorFor({ round: 1, rounds: 3 }), 40);
  assert.equal(f.kFactorFor({ round: 2, rounds: 3 }), 48);
  assert.equal(f.kFactorFor({ round: 3, rounds: 3 }), 56);
  assert.equal(f.kFactorFor({ round: 1, rounds: 1 }), 56, 'a two-team draw is a final');
  assert.equal(f.kFactorFor({ round: 1, rounds: 4 }), 40);
  assert.equal(f.kFactorFor({ round: 2, rounds: 4 }), 40);
  // A bye beats every other consideration: no game, no rating movement.
  assert.equal(f.kFactorFor({ round: 3, rounds: 3, isBye: true }), 0);
  assert.equal(f.kFactorFor({ round: 1, rounds: 3, isBye: true }), 0);
  // Round-robin has no final, so every matchday is an early round.
  assert.equal(f.kFactorFor({ round: 5, rounds: 5, format: f.FORMATS.ROUND_ROBIN }), 40);
  // global_settings.tournament can move the three tiers.
  assert.equal(f.kFactorFor({ round: 3, rounds: 3, k: { early: 36, semi: 44, final: 50 } }), 50);
  assert.equal(f.kFactorFor({ round: 1, rounds: 3, k: { early: 36 } }), 36);
  // Every tournament K outweighs a friendly's 32 — that is the whole claim.
  for (const r of [1, 2, 3]) {
    assert.ok(f.kFactorFor({ round: r, rounds: 3 }) > f.K.FRIENDLY,
      `round ${r} must count for more than a friendly`);
  }
  // K = 0 does freeze a rating: proved against the ladder itself, not
  // against a comment.
  const frozen = elo.rate({
    ratingChallenger: 1200, ratingOpponent: 1000, scoreChallenger: 1,
    kFactor: f.kFactorFor({ round: 1, rounds: 3, isBye: true }),
  });
  assert.equal(frozen.challenger.delta, 0);
  assert.equal(frozen.opponent.delta, 0);
  // …and a final moves a rating ~75% harder than a friendly does.
  const asFriendly = elo.rate({
    ratingChallenger: 1000, ratingOpponent: 1000, scoreChallenger: 1, kFactor: f.K.FRIENDLY,
  }).challenger.delta;
  const asFinal = elo.rate({
    ratingChallenger: 1000, ratingOpponent: 1000, scoreChallenger: 1,
    kFactor: f.kFactorFor({ round: 3, rounds: 3 }),
  }).challenger.delta;
  assert.equal(asFriendly, 16);
  assert.equal(asFinal, 28);
});

test('11 — circleMethod(): every pair once, nobody twice a day, no bye rows', () => {
  for (const n of [2, 3, 4, 5, 6]) {
    const rr = f.circleMethod(f.seedTeams(mk(n)));
    assert.equal(rr.fixtures.length, f.fixtureCount('round_robin', n), `n=${n} fixture count`);
    assert.equal(rr.rounds, f.roundRobinRounds(n), `n=${n} matchdays`);
    assert.equal(rr.byes, 0, 'a rest day is not a bye fixture');

    const pairs = rr.fixtures.map((x) => [x.teamA, x.teamB].sort().join('|'));
    assert.equal(new Set(pairs).size, pairs.length, `n=${n}: a pair met twice`);
    assert.equal(pairs.length, (n * (n - 1)) / 2, `n=${n}: not every pair met`);

    for (let r = 1; r <= rr.rounds; r += 1) {
      const day = rr.fixtures.filter((x) => x.round === r).flatMap((x) => [x.teamA, x.teamB]);
      assert.equal(new Set(day).size, day.length, `n=${n} matchday ${r}: a team plays twice`);
      // An odd field rests exactly one team per matchday; an even field rests none.
      assert.equal(day.length, n % 2 === 0 ? n : n - 1, `n=${n} matchday ${r} size`);
    }
    // (round, position) stays unique, because the same UNIQUE index serves both
    // formats.
    const keys = rr.fixtures.map((x) => `${x.round}:${x.position}`);
    assert.equal(new Set(keys).size, keys.length, `n=${n} duplicate coordinates`);
    // A league has nowhere to advance to.
    assert.ok(rr.fixtures.every((x) => x.nextRound === null));
  }
  assert.deepEqual(f.circleMethod([]), { rounds: 0, fixtures: [] });
  assert.deepEqual(f.circleMethod([{ id: 'solo' }]), { rounds: 0, fixtures: [] });
});

test('12 — standings(): 3/1/0, goal difference, walkovers count, byes do not', () => {
  const teams = [
    { id: 'a', name: 'Alpha', elo: 1000 },
    { id: 'b', name: 'Bravo', elo: 1000 },
    { id: 'c', name: 'Charlie', elo: 1000 },
    { id: 'd', name: 'Delta', elo: 1000 },
  ];
  const fixtures = [
    // Postgres shape on purpose: snake_case, DECIMALs as strings.
    { round: 1, position: 1, team_a: 'a', team_b: 'b', score_a: 3, score_b: 0, status: 'played', winner: 'a' },
    { round: 1, position: 2, team_a: 'c', team_b: 'd', score_a: '2', score_b: '2', status: 'played', winner: null },
    { round: 2, position: 1, team_a: 'a', team_b: 'c', score_a: 1, score_b: 2, status: 'played', winner: 'c' },
    // A walkover: a result with no scoreline.
    { round: 2, position: 2, team_a: 'b', team_b: 'd', score_a: null, score_b: null, status: 'walkover', winner: 'b' },
    // Neither of these may touch the table.
    { round: 3, position: 1, team_a: 'a', team_b: 'd', score_a: null, score_b: null, status: 'upcoming', winner: null },
    { round: 3, position: 2, team_a: 'c', team_b: null, score_a: null, score_b: null, status: 'walkover', winner: 'c', is_bye: true },
  ];
  const t = f.standings(teams, fixtures);
  const row = (id) => t.find((x) => x.teamId === id);

  assert.equal(row('a').played, 2);
  assert.deepEqual([row('a').wins, row('a').draws, row('a').losses], [1, 0, 1]);
  assert.equal(row('a').points, 3);
  assert.equal(row('a').goalsFor, 4);
  assert.equal(row('a').goalsAgainst, 2);
  assert.equal(row('a').goalDiff, 2);

  assert.equal(row('c').points, 4, 'a draw is 1 and a win is 3');
  assert.equal(row('c').played, 2, 'the bye in round 3 must not count as a match');
  assert.equal(row('c').goalsFor, 4);

  // The walkover is a played win with no goals — the team turned up.
  assert.equal(row('b').played, 2);
  assert.equal(row('b').wins, 1);
  assert.equal(row('b').points, 3);
  assert.equal(row('b').goalsFor, 0);
  assert.equal(row('d').losses, 1);
  assert.equal(row('d').points, 1);

  // Order: c (4) then the two on 3 split by goal difference, then d.
  assert.deepEqual(t.map((x) => x.teamId), ['c', 'a', 'b', 'd']);
  assert.deepEqual(t.map((x) => x.position), [1, 2, 3, 4]);

  // A team that registered but has not played yet still appears, on zero.
  const cold = f.standings(teams, []);
  assert.equal(cold.length, 4);
  assert.ok(cold.every((x) => x.played === 0 && x.points === 0));
  assert.deepEqual(cold.map((x) => x.teamId), ['a', 'b', 'c', 'd'], 'alphabetical when all tied');
});

test('13 — standings(): head-to-head splits teams level on points and goals', () => {
  const teams = [{ id: 'x', name: 'Xerxes' }, { id: 'y', name: 'Yankee' }];
  // Two teams, two meetings: one 1-0 each way. Level on everything.
  const level = f.standings(teams, [
    { round: 1, position: 1, teamA: 'x', teamB: 'y', scoreA: 1, scoreB: 0, status: 'played', winner: 'x' },
    { round: 2, position: 1, teamA: 'y', teamB: 'x', scoreA: 1, scoreB: 0, status: 'played', winner: 'y' },
  ]);
  assert.equal(level[0].points, level[1].points);
  assert.deepEqual(level.map((r) => r.teamId), ['x', 'y'], 'alphabetical is the last resort');

  // Now the real tiebreak. Three teams end level on points, goal difference and
  // goals for, and only the head-to-head separates two of them — and the names
  // are chosen so that alphabetical order would give the opposite answer. If the
  // comparator ignored head-to-head this test would fail, which is the point.
  const three = [
    { id: 'x', name: 'Zulu' },        // beat Alpha head-to-head, but sorts last by name
    { id: 'y', name: 'Alpha' },
    { id: 'z', name: 'Mid' },
  ];
  const h2h = f.standings(three, [
    { round: 1, position: 1, teamA: 'x', teamB: 'y', scoreA: 1, scoreB: 0, status: 'played', winner: 'x' },
    { round: 2, position: 1, teamA: 'z', teamB: 'x', scoreA: 2, scoreB: 1, status: 'played', winner: 'z' },
    { round: 3, position: 1, teamA: 'y', teamB: 'z', scoreA: 2, scoreB: 1, status: 'played', winner: 'y' },
  ]);
  const xr = h2h.find((r) => r.teamId === 'x');
  const yr = h2h.find((r) => r.teamId === 'y');
  assert.deepEqual([xr.points, yr.points], [3, 3]);
  assert.deepEqual([xr.goalDiff, yr.goalDiff], [0, 0]);
  assert.deepEqual([xr.goalsFor, yr.goalsFor], [2, 2]);
  assert.ok(h2h.findIndex((r) => r.teamId === 'x') < h2h.findIndex((r) => r.teamId === 'y'),
    'Zulu beat Alpha, so Zulu is above it despite losing on name');
});

test('14 — splitPool(): the worked example, to the rupee', () => {
  // 8 teams at PKR 4,000, seven one-hour slots at PKR 2,000. These are the exact
  // numbers in doc/CLAUDE.md, and they are the argument for
  // the whole waterfall: the owner clears 21,200 on inventory that would have
  // fetched 14,000 at the counter.
  const e = f.splitPool({ entryFee: 4000, teams: 8, slotTotal: 14000 });
  assert.equal(e.pool, 32000);
  assert.equal(e.venueCost, 14000);
  assert.equal(e.surplus, 18000);
  assert.equal(e.prize, 10800);
  assert.equal(e.winnerShare, 7560);
  assert.equal(e.runnerupShare, 3240);
  assert.equal(e.margin, 7200);
  assert.equal(e.ownerEarning, 21200);
  assert.equal(e.underwater, false);
  assert.equal(e.retailValue, 14000);
  assert.equal(e.uplift, 7200);
  assert.equal(e.upliftPercent, 51.43);
  assert.equal(e.identityOk, true);
  // The three sentences the create screen and the check script both assert.
  assert.equal(e.pool, e.venueCost + e.prize + e.margin);
  assert.equal(e.ownerEarning + e.prize, e.pool);
  assert.equal(e.winnerShare + e.runnerupShare, e.prize);
  // `pool` may be handed in directly instead of fee x teams (the deadline job
  // knows the real accepted count, the preview does not).
  assert.deepEqual(f.splitPool({ pool: 32000, slotTotal: 14000 }).prize, e.prize);
});

test('15 — splitPool(): the identity holds to the PAISA across the whole space', () => {
  const fees = [0, 1, 500, 999.99, 1000.5, 2000, 3333.33, 4000, 12345.67];
  const teamCounts = [2, 3, 4, 5, 6, 7, 8, 16];
  const slots = [0, 1, 1750.25, 7000, 14000, 33333.33, 99999.99];
  const prizes = [0, 33, 50, 60, 65, 100];
  const wins = [50, 65, 70, 100];
  let cases = 0;
  for (const entryFee of fees) {
    for (const teams of teamCounts) {
      for (const slotTotal of slots) {
        for (const prizePercent of prizes) {
          for (const winnerPercent of wins) {
            const e = f.splitPool({
              entryFee, teams, slotTotal, prizePercent,
              winnerPercent, runnerupPercent: 100 - winnerPercent,
            });
            cases += 1;
            const p = (v) => Math.round(v * 100);           // back to paisa
            assert.equal(p(e.pool), p(e.venueCost) + p(e.prize) + p(e.margin),
              `identity broke at fee=${entryFee} teams=${teams} slots=${slotTotal}`);
            assert.equal(p(e.ownerEarning) + p(e.prize), p(e.pool), 'owner + prize must be the pool');
            assert.equal(p(e.winnerShare) + p(e.runnerupShare), p(e.prize), 'shares must be the prize');
            assert.ok(e.prize >= 0, 'a prize is never negative');
            assert.ok(e.ownerEarning >= 0, 'money is never taken from the owner');
            assert.ok(e.ownerEarning <= e.pool, 'the owner cannot be paid more than came in');
            assert.equal(e.identityOk, true);
          }
        }
      }
    }
  }
  assert.ok(cases > 2000, `expected a real sweep, ran ${cases}`);
});

test('16 — splitPool(): UNDERWATER pays no prize and never bills the owner', () => {
  // Four teams at PKR 1,000 cannot cover seven hours at PKR 2,000.
  const e = f.splitPool({ entryFee: 1000, teams: 4, slotTotal: 14000 });
  assert.equal(e.pool, 4000);
  assert.equal(e.venueCost, 14000);
  assert.equal(e.surplus, -10000);
  assert.equal(e.underwater, true);
  assert.equal(e.prize, 0, 'there is nothing left to award');
  assert.equal(e.winnerShare, 0);
  assert.equal(e.runnerupShare, 0);
  assert.equal(e.margin, -10000, 'the shortfall is stated, not hidden');
  assert.equal(e.ownerEarning, 4000, 'the owner takes the pool and no more');
  assert.equal(e.ownerEarning, e.pool);
  assert.equal(e.identityOk, true);
  // Exactly break-even is not underwater: nothing is owed, nothing is left.
  const even = f.splitPool({ entryFee: 3500, teams: 4, slotTotal: 14000 });
  assert.equal(even.surplus, 0);
  assert.equal(even.underwater, false);
  assert.equal(even.prize, 0);
  assert.equal(even.ownerEarning, 14000);
  assert.equal(even.margin, 0);
});

test('17 — splitPool(): the rounding remainder lands in the owner margin', () => {
  // A surplus of PKR 100.01 at 60% is 60.006 — six-tenths of a paisa that has to
  // go somewhere. It goes to the margin, never to a prize that cannot be paid.
  const e = f.splitPool({ pool: 100.01, slotTotal: 0, prizePercent: 60 });
  assert.equal(e.prize, 60);
  assert.equal(e.margin, 40.01);
  // Asserted in paisa, not rupees: 0 + 60 + 40.01 evaluates to 100.00999999999999
  // in IEEE floats. That failure mode is exactly why splitPool does its
  // arithmetic in integer paisa and reports `identityOk` from inside, instead of
  // leaving every caller to re-add rupee decimals and get a different answer.
  const paisa = (v) => Math.round(v * 100);
  assert.equal(paisa(e.pool), paisa(e.venueCost) + paisa(e.prize) + paisa(e.margin));
  assert.equal(e.identityOk, true);
  // A prize of 3 paisa split 70/30 is 2.1 / 0.9: the winner is floored to 2 and
  // the runner-up takes the exact complement, so no paisa evaporates.
  const tiny = f.splitPool({ pool: 0.05, slotTotal: 0, prizePercent: 60 });
  assert.equal(tiny.prize, 0.03);
  assert.equal(tiny.winnerShare, 0.02);
  assert.equal(tiny.runnerupShare, 0.01);
  assert.equal(tiny.winnerShare + tiny.runnerupShare, tiny.prize);
  // Fee strings from pg (decimal comes back as text) must not become NaN.
  const fromDb = f.splitPool({ entryFee: '4000.00', teams: '8', slotTotal: '14000.00' });
  assert.equal(fromDb.ownerEarning, 21200);
});

test('18 — splitPool(): the venue discount is the owner giving up their own cost', () => {
  const full = f.splitPool({ entryFee: 4000, teams: 8, slotTotal: 14000 });
  const half = f.splitPool({
    entryFee: 4000, teams: 8, slotTotal: 14000, venueDiscountPercent: 50,
  });
  assert.equal(half.venueCost, 7000);
  assert.equal(half.venueDiscount, 7000);
  assert.equal(half.surplus, 25000);
  assert.equal(half.prize, 15000, 'a discount moves money into the prize pool');
  assert.ok(half.prize > full.prize);
  assert.ok(half.ownerEarning < full.ownerEarning, 'and out of the owner’s pocket');
  assert.equal(half.identityOk, true);
  // 100% off: the venue is free, the whole pool is surplus.
  const free = f.splitPool({ entryFee: 4000, teams: 8, slotTotal: 14000, venueDiscountPercent: 100 });
  assert.equal(free.venueCost, 0);
  assert.equal(free.surplus, 32000);
  assert.equal(free.prize, 19200);
  assert.equal(free.ownerEarning, 12800);
  // Out-of-range percentages are clamped rather than trusted — 019's CHECK would
  // reject the row, but the preview endpoint must not do the arithmetic anyway.
  assert.equal(f.splitPool({ pool: 100, slotTotal: 0, prizePercent: 900 }).prize, 100);
  assert.equal(f.splitPool({ pool: 100, slotTotal: 0, prizePercent: -50 }).prize, 0);
});

test('19 — recommendEntryFee(): the fee actually meets the target at MIN teams', () => {
  const r = f.recommendEntryFee({ slotTotal: 14000, minTeams: 4, targetMarginPercent: 25 });
  assert.equal(r.venueCost, 14000);
  assert.equal(r.targetMargin, 3500);
  assert.equal(r.achievable, true);
  assert.equal(r.entryFee % 100, 0, 'a recommended fee is a round number');
  // The promise: at the worst legal turnout the owner still clears the target.
  assert.ok(r.atMinTeams.margin >= r.targetMargin,
    `margin ${r.atMinTeams.margin} should reach ${r.targetMargin}`);
  assert.equal(r.atMinTeams.underwater, false);
  assert.ok(r.atMinTeams.ownerEarning > r.atMinTeams.retailValue,
    'a tournament must beat selling the same slots');
  // A fuller field only ever earns more.
  const full = f.splitPool({ entryFee: r.entryFee, teams: 8, slotTotal: 14000 });
  assert.ok(full.ownerEarning > r.atMinTeams.ownerEarning);
  assert.ok(full.prize > r.atMinTeams.prize);

  // The recommendation scales with the inventory it has to recover.
  const cheap = f.recommendEntryFee({ slotTotal: 3500, minTeams: 4 });
  assert.ok(cheap.entryFee < r.entryFee);
  // A generous owner discounting the venue lowers what teams must pay.
  const kind = f.recommendEntryFee({ slotTotal: 14000, minTeams: 4, venueDiscountPercent: 50 });
  assert.ok(kind.entryFee < r.entryFee, 'a venue discount is a cheaper tournament');
  // Round-robin's 28 fixtures cost four times a knockout's seven, and the
  // recommendation says so out loud instead of letting the owner find out later.
  const rr = f.recommendEntryFee({ slotTotal: 28 * 2000, minTeams: 4 });
  assert.ok(rr.entryFee > 3 * r.entryFee, `round-robin fee ${rr.entryFee} vs knockout ${r.entryFee}`);
  // prize_percent 100 leaves no margin to solve for: cover the cost and say so.
  const all = f.recommendEntryFee({ slotTotal: 14000, minTeams: 4, prizePercent: 100 });
  assert.equal(all.achievable, false);
  assert.equal(all.entryFee, 3500);
  assert.equal(all.atMinTeams.ownerEarning, 14000, 'the cost is still recovered first');
  assert.equal(all.atMinTeams.prize, 0);
});

test('20 — winProbability(): the Elo curve, not a second opinion', () => {
  assert.equal(f.winProbability(1000, 1000), 0.5);
  for (const [a, b] of [[1000, 1200], [1400, 1000], [1013, 987]]) {
    assert.equal(f.winProbability(a, b), elo.expected(a, b), 'must be the ladder’s own formula');
    assert.ok(Math.abs(f.winProbability(a, b) + f.winProbability(b, a) - 1) < 1e-12);
  }
  // A 400-point gap is the defining 10:1 of the scale.
  assert.ok(Math.abs(f.winProbability(1400, 1000) - 10 / 11) < 1e-9);
  // Unrated teams default to 1000 rather than producing NaN on a fixture card.
  assert.equal(f.winProbability(null, undefined), 0.5);
  assert.equal(f.winProbability('1200', '1000'), elo.expected(1200, 1000));
});

test('21 — normaliseFixture(): a Postgres row and a generated node read the same', () => {
  const fromDb = f.normaliseFixture({
    round: 2, position: 1, team_a: 'a', team_b: 'b', score_a: '3', score_b: '1',
    winner: 'a', status: 'played', is_bye: false,
  });
  const fromCode = f.normaliseFixture({
    round: 2, position: 1, teamA: 'a', teamB: 'b', scoreA: 3, scoreB: 1,
    winner: 'a', status: 'played', isBye: false,
  });
  assert.deepEqual(fromDb, fromCode);
  assert.equal(fromDb.scoreA, 3, 'a DECIMAL string must arrive as a number');
  // An unplayed fixture keeps NULL scores as null, not 0 — 0-0 is a real result.
  const blank = f.normaliseFixture({ round: 1, position: 1, team_a: null, score_a: null });
  assert.equal(blank.scoreA, null);
  assert.equal(blank.teamA, null);
  assert.equal(blank.status, 'upcoming');
  assert.equal(blank.isBye, false);
  assert.equal(f.normaliseFixture({ is_bye: true }).isBye, true);
  assert.equal(f.normaliseFixture(null).status, 'upcoming');
});

test('22 — buildFixtures(): one call site, both formats, and the caps hold', () => {
  const seeded = f.seedTeams(mk(6));
  const ko = f.buildFixtures(f.FORMATS.KNOCKOUT, seeded);
  const rr = f.buildFixtures(f.FORMATS.ROUND_ROBIN, seeded);
  assert.equal(ko.fixtures.length, f.bracketNodes(6));
  assert.equal(rr.fixtures.length, 15);
  // An unknown format must not silently become a league — knockout is the safe
  // default and 019's chk_tournaments_format rejects anything else at the row.
  assert.equal(f.buildFixtures('league', seeded).fixtures.length, ko.fixtures.length);

  // The caps this file publishes are the ones the migration enforces.
  assert.equal(f.MAX_KNOCKOUT_TEAMS, 32);
  assert.equal(f.MAX_ROUND_ROBIN_TEAMS, 6);
  assert.ok(f.isPowerOfTwo(f.MAX_KNOCKOUT_TEAMS));
  assert.equal(f.isPowerOfTwo(6), false);
  assert.equal(f.isPowerOfTwo(0), false);
  assert.equal(f.isPowerOfTwo(1), true);
  // Money helpers are exported because the service must round the same way.
  assert.equal(f.toPaisa('1234.567'), 123457);
  assert.equal(f.fromPaisa(123457), 1234.57);
  assert.equal(f.round2('99.994'), 99.99);
  assert.equal(f.asNum('abc', 7), 7);
  assert.deepEqual(f.POINTS, { WIN: 3, DRAW: 1, LOSS: 0 });
});
