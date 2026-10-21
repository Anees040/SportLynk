const test = require('node:test');
const assert = require('node:assert/strict');
const { calculateTrust, recomputeTrust } = require('../src/utils/trustScore');

test('new accounts retain 100 with unmeasured components', () => {
  const result = calculateTrust({});
  assert.equal(result.trustScore, 100);
  assert.deepEqual(result.components, { rating: null, attendance: null, disputes: null, sentiment: null });
});

test('one no-show is mild; repeated missed bookings progressively reduce trust', () => {
  assert.deepEqual([1, 2, 3].map(no_shows => calculateTrust({ no_shows }).trustScore), [93, 84, 73]);
});

test('attendance immediately improves trust and reduces the repeated no-show deduction', () => {
  for (const no_shows of [1, 2, 3, 10]) {
    const missed = calculateTrust({ no_shows });
    const attended = calculateTrust({ no_shows, checked_in: 1 });
    assert.ok(attended.trustScore > missed.trustScore);
    assert.ok(attended.repeatedNoShowPenalty <= missed.repeatedNoShowPenalty);
    assert.equal(attended.attendanceRate, 1 / (1 + no_shows));
  }
  assert.equal(calculateTrust({ no_shows: 1, checked_in: 1 }).trustScore, 94);
});

test('a long positive record limits the impact of one incident', () => {
  assert.equal(calculateTrust({ checked_in: 19, no_shows: 1 }).trustScore, 99);
  const review = calculateTrust({ n_rating: '1', avg_rating: '1', n_sentiment: '1', avg_sentiment: '-1' });
  assert.equal(review.trustScore, 89);
});

test('cancellation allowance, bounds and numeric database strings remain supported', () => {
  assert.equal(calculateTrust({ recent_cancels: 2 }).cancellationPenalty, 0);
  assert.ok(calculateTrust({ recent_cancels: 20 }).cancellationPenalty > 0);
  assert.equal(calculateTrust({ recent_cancels: 10000 }).trustScore, 0);
  assert.equal(calculateTrust({ no_shows: '3', checked_in: '1' }).trustScore,
    calculateTrust({ no_shows: 3, checked_in: 1 }).trustScore);
});

test('pool recomputes acquire a profile lock and commit the new score before releasing', async () => {
  const calls = [];
  const client = {
    async query(sql, params) {
      calls.push({ sql, params });
      return { rows: sql.includes('WITH my_teams') ? [{ no_shows: '1', checked_in: '1' }] : [] };
    },
    release() { calls.push({ sql: 'release' }); },
  };
  const result = await recomputeTrust({ totalCount: 1, async connect() { return client; } }, 'player');
  assert.equal(result.trustScore, 94);
  assert.equal(calls[0].sql, 'BEGIN');
  assert.match(calls[1].sql, /FOR UPDATE/);
  assert.equal(calls[3].params[1], 94);
  assert.deepEqual(calls.slice(-2).map(c => c.sql), ['COMMIT', 'release']);
});
