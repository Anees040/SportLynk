/**
 * ELO engine unit tests  —  S.2 Wave B
 *
 * Run:  npm test            (from backend/)
 *   or  node --test test/
 *
 * These are real unit tests: `src/utils/elo.js` imports no database, so nothing
 * here needs a connection, a seeded row, or a running server. That is by design —
 * see the header of elo.js.
 *
 * The four properties the spec calls out are covered by tests 3, 4, 5 and 6:
 *   3  symmetric (zero-sum) exchange
 *   4  an upset gains more points than an expected win
 *   5  a draw shifts rating toward the lower-rated team
 *   6  the K-factor is respected
 * The rest pin the pieces the match routes depend on (FR2.6 ranked/unranked,
 * the competitiveness band, and the winner-id → S translation).
 */

const test = require('node:test');
const assert = require('node:assert/strict');

const elo = require('../src/utils/elo');

const K = 32;

test('1 — expected(): equal ratings are an exact coin flip, and expectations sum to 1', () => {
  assert.equal(elo.expected(1000, 1000), 0.5);
  assert.equal(elo.expected(1543, 1543), 0.5);

  // The complement property is what makes the exchange conservable at all.
  for (const [a, b] of [[1000, 1200], [1400, 1000], [987, 1611], [1500, 1499]]) {
    const sum = elo.expected(a, b) + elo.expected(b, a);
    assert.ok(Math.abs(sum - 1) < 1e-12, `expected(${a},${b}) + expected(${b},${a}) = ${sum}`);
  }
});

test('2 — expected(): a 400-point lead is ~10:1, and the curve is monotonic', () => {
  // The defining property of the 400-point scale.
  const favourite = elo.expected(1400, 1000);
  assert.ok(Math.abs(favourite - 10 / 11) < 1e-9, `got ${favourite}`);
  assert.ok(Math.abs(elo.expected(1000, 1400) - 1 / 11) < 1e-9);

  // Strictly increasing in one's own rating.
  let prev = -1;
  for (const r of [600, 800, 1000, 1200, 1400, 1800]) {
    const e = elo.expected(r, 1200);
    assert.ok(e > prev, `expected(${r},1200)=${e} should exceed ${prev}`);
    prev = e;
  }
});

test('3 — SYMMETRIC EXCHANGE: what one team gains, the other loses, exactly', () => {
  const pairs = [
    [1000, 1000], [1000, 1200], [1400, 1000], [1013, 987],
    [800, 1750], [1499, 1500], [1234, 1233], [2000, 1000],
  ];

  for (const [rc, ro] of pairs) {
    for (const sc of [elo.OUTCOME.WIN, elo.OUTCOME.DRAW, elo.OUTCOME.LOSS]) {
      const x = elo.rate({
        ratingChallenger: rc, ratingOpponent: ro, scoreChallenger: sc, kFactor: K,
      });

      // Zero-sum in the deltas...
      assert.equal(
        x.challenger.delta + x.opponent.delta, 0,
        `deltas must cancel for ${rc} vs ${ro} @ S=${sc}`,
      );
      // ...and therefore the ladder's total points are invariant. This is the
      // property that independent Math.round() on both sides would silently
      // break, minting a point out of nothing on every tie-breaking round.
      assert.equal(
        x.challenger.after + x.opponent.after, rc + ro,
        `total rating must be conserved for ${rc} vs ${ro} @ S=${sc}`,
      );
      // Ratings stay integers — teams.elo is an int column.
      assert.ok(Number.isInteger(x.challenger.after) && Number.isInteger(x.opponent.after));
    }
  }
});

test('4 — UPSET: beating a stronger team is worth more than beating an equal one', () => {
  const win = (rc, ro) => elo.rate({
    ratingChallenger: rc, ratingOpponent: ro, scoreChallenger: elo.OUTCOME.WIN, kFactor: K,
  }).challenger.delta;

  const upset = win(1000, 1400);   // huge underdog wins
  const evenly = win(1000, 1000);  // coin flip won
  const expectedWin = win(1400, 1000); // favourite does its job

  assert.ok(upset > evenly, `upset ${upset} should beat even-match ${evenly}`);
  assert.ok(evenly > expectedWin, `even-match ${evenly} should beat routine ${expectedWin}`);

  // Concrete values, so a regression in the formula is visible and not just
  // "still ordered correctly".
  assert.equal(upset, 29);        // 32 × (1 − 1/11)
  assert.equal(evenly, 16);       // 32 × 0.5
  assert.equal(expectedWin, 3);   // 32 × (1 − 10/11)

  // Reward rises monotonically with how unlikely the win was.
  let prev = -Infinity;
  for (const opp of [800, 1000, 1200, 1400, 1600]) {
    const d = win(1000, opp);
    assert.ok(d > prev, `beating ${opp} (${d}) should be worth more than the previous tier`);
    prev = d;
  }
});

test('5 — DRAW shifts rating toward the lower-rated team', () => {
  // Favourite is the challenger: it drops, the underdog climbs.
  const a = elo.rate({
    ratingChallenger: 1400, ratingOpponent: 1000, scoreChallenger: elo.OUTCOME.DRAW, kFactor: K,
  });
  assert.ok(a.challenger.delta < 0, 'higher-rated team must lose points on a draw');
  assert.ok(a.opponent.delta > 0, 'lower-rated team must gain points on a draw');
  assert.equal(a.challenger.delta, -13);
  assert.equal(a.opponent.delta, 13);

  // Same match with the sides swapped must move the same two ratings the same
  // way — the outcome cannot depend on who happened to issue the challenge.
  const b = elo.rate({
    ratingChallenger: 1000, ratingOpponent: 1400, scoreChallenger: elo.OUTCOME.DRAW, kFactor: K,
  });
  assert.equal(b.challenger.after, a.opponent.after);
  assert.equal(b.opponent.after, a.challenger.after);

  // A draw between equals is a non-event.
  const even = elo.rate({
    ratingChallenger: 1200, ratingOpponent: 1200, scoreChallenger: elo.OUTCOME.DRAW, kFactor: K,
  });
  assert.equal(even.challenger.delta, 0);
  assert.equal(even.opponent.delta, 0);
});

test('6 — K-FACTOR is respected: it scales the swing, and K=0 freezes it', () => {
  const deltaAt = (k) => elo.rate({
    ratingChallenger: 1000, ratingOpponent: 1200, scoreChallenger: elo.OUTCOME.WIN, kFactor: k,
  }).challenger.delta;

  const d16 = deltaAt(16);
  const d32 = deltaAt(32);
  const d64 = deltaAt(64);

  assert.ok(d16 < d32 && d32 < d64, `expected 16<32<64 to grow, got ${d16}/${d32}/${d64}`);

  // Doubling K doubles the swing, to within the one point that rounding to an
  // integer rating can cost. Asserting "within 1" rather than "exactly double"
  // is the honest bound — `newRating` rounds, so exact doubling is not available.
  assert.ok(Math.abs(d32 - 2 * d16) <= 1, `${d32} vs 2×${d16}`);
  assert.ok(Math.abs(d64 - 2 * d32) <= 1, `${d64} vs 2×${d32}`);

  // The pure function, exercised directly at the spec's signature.
  assert.equal(elo.newRating(1000, 1, 0.5, 32), 1016);
  assert.equal(elo.newRating(1000, 0, 0.5, 32), 984);
  assert.equal(elo.newRating(1000, 1, 0.25, 0), 1000, 'K=0 must move nothing');
  assert.equal(elo.newRating(1000, 0.5, 0.5, 999), 1000, 'S===E must move nothing at any K');
});

test('7 — newRating() always returns an integer rating', () => {
  for (const r of [1000, 1013, 877]) {
    for (const s of [0, 0.5, 1]) {
      for (const e of [0.0909, 0.2402, 0.5, 0.7598, 0.9091]) {
        const out = elo.newRating(r, s, e, K);
        assert.ok(Number.isInteger(out), `newRating(${r},${s},${e},${K}) = ${out}`);
      }
    }
  }
});

test('8 — FR2.6: a team is Unranked until it has one verified match', () => {
  const fresh = { elo: 1000, wins: 0, losses: 0, draws: 0 };
  const played = { elo: 1016, wins: 1, losses: 0, draws: 0 };
  const drew = { elo: 1000, wins: 0, losses: 0, draws: 1 };
  const lost = { elo: 984, wins: 0, losses: 1, draws: 0 };

  assert.equal(elo.isRanked(fresh), false);
  assert.equal(elo.isRanked(played), true);
  assert.equal(elo.isRanked(drew), true, 'a draw is still a verified match');
  assert.equal(elo.isRanked(lost), true, 'a loss is still a verified match');

  // displayElo returns null — not 1000 — so no screen can render a placeholder
  // rating as though it had been earned.
  assert.equal(elo.displayElo(fresh), null);
  assert.equal(elo.displayElo(played), 1016);

  // Postgres hands decimal/BIGINT back as strings; the helpers must survive it.
  assert.equal(elo.isRanked({ elo: '1016', wins: '1', losses: '0', draws: '0' }), true);
  assert.equal(elo.displayElo({ elo: '1016', wins: '1', losses: '0', draws: '0' }), 1016);
  assert.equal(elo.playedCount({ wins: '2', losses: '3', draws: '1' }), 6);
  assert.equal(elo.playedCount(null), 0, 'a missing team is not ranked, not a crash');
});

test('9 — competitiveness(): 100 when even, floors at 5, never leaves the band', () => {
  assert.equal(elo.competitiveness(1200, 1200), 100);
  assert.equal(elo.competitiveness(1000, 1400), 5, 'a 400 gap is the floor');
  assert.equal(elo.competitiveness(1000, 2500), 5, 'gaps beyond 400 are capped, not negative');
  assert.equal(elo.competitiveness(1400, 1000), elo.competitiveness(1000, 1400), 'order-independent');

  // Monotonically decreasing, and always inside [5, 100].
  let prev = 101;
  for (const gap of [0, 50, 100, 200, 300, 400, 800]) {
    const c = elo.competitiveness(1200, 1200 + gap);
    assert.ok(c >= elo.COMP_MIN && c <= elo.COMP_MAX, `gap ${gap} → ${c} out of band`);
    assert.ok(c <= prev, `gap ${gap} → ${c} should not exceed the tighter gap's ${prev}`);
    prev = c;
  }

  // FR2.6 again: an unranked side means the honest answer is "Unranked", not a
  // percentage derived from a placeholder rating.
  const fresh = { elo: 1000, wins: 0, losses: 0, draws: 0 };
  const played = { elo: 1180, wins: 3, losses: 1, draws: 0 };
  assert.equal(elo.competitivenessFor(fresh, played), null);
  assert.equal(elo.competitivenessFor(played, fresh), null);
  assert.equal(elo.competitivenessFor(played, { elo: 1200, wins: 1, losses: 0, draws: 0 }), 95);
});

test('10 — outcomeFor(): winner id maps to S, null is a draw, a stranger throws', () => {
  const C = '11111111-1111-1111-1111-111111111111';
  const O = '22222222-2222-2222-2222-222222222222';

  const cWin = elo.outcomeFor({ winnerTeam: C, challengerTeam: C, opponentTeam: O });
  assert.deepEqual(
    { ...cWin },
    { scoreChallenger: 1, scoreOpponent: 0, draw: false },
  );

  const oWin = elo.outcomeFor({ winnerTeam: O, challengerTeam: C, opponentTeam: O });
  assert.deepEqual(
    { ...oWin },
    { scoreChallenger: 0, scoreOpponent: 1, draw: false },
  );

  for (const nothing of [null, undefined]) {
    const d = elo.outcomeFor({ winnerTeam: nothing, challengerTeam: C, opponentTeam: O });
    assert.deepEqual({ ...d }, { scoreChallenger: 0.5, scoreOpponent: 0.5, draw: true });
  }

  // A winner that is not in the match must be loud. Silently scoring it as a
  // draw would write a plausible-looking but wrong rating for both teams.
  assert.throws(
    () => elo.outcomeFor({
      winnerTeam: '33333333-3333-3333-3333-333333333333',
      challengerTeam: C,
      opponentTeam: O,
    }),
    /must be one of the two teams/,
  );
});
