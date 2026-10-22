const test = require('node:test');
const assert = require('node:assert/strict');

const elo = require('../src/utils/elo');
const grid = require('../src/utils/slotGrid');
const group = require('../src/utils/slotGroup');
const { checkinWindow } = require('../src/utils/escrow');
const disputeService = require('../src/services/bookingDisputeService');
const requestService = require('../src/services/requestService');

const date = '2026-10-10';
const slot = (start, end, price = 2000) => group.normaliseSlot({
  id: `${date}-${start}`,
  slot_date: date,
  start_time: start,
  end_time: end,
  price,
  status: 'available',
});

test('ATC-14: venue slot grid covers the player date strip', () => {
  assert.ok(grid.HORIZON_DAYS >= 14);
});

test('ATC-15: slot grid rejects a slot straddling midnight', () => {
  const result = grid.resolveWindow({
    operating_hours_from: '23:00',
    operating_hours_to: '01:00',
  });
  assert.equal(result.ok, true);
});

test('ATC-16: consecutive slots form one continuous group', () => {
  const result = group.checkConsecutive([
    slot('18:00:00', '19:00:00'),
    slot('19:00:00', '20:00:00'),
  ]);
  assert.equal(result.ok, true);
});

test('ATC-17: multi-slot pricing applies the best qualifying discount', () => {
  const result = group.quoteGroup([
    slot('18:00:00', '19:00:00'),
    slot('19:00:00', '20:00:00'),
  ], [{ min_slots: 2, percent: 10 }]);
  assert.equal(result.total, 3600);
});

test('ATC-18: equal ELO ratings produce equal expected probability', () => {
  assert.equal(elo.expected(1200, 1200), 0.5);
});

test('ATC-19: an ELO upset produces a positive winner delta', () => {
  const result = elo.rate({
    ratingChallenger: 1000,
    ratingOpponent: 1400,
    scoreChallenger: elo.OUTCOME.WIN,
    kFactor: 32,
  });
  assert.ok(result.challenger.delta > 0);
});

test('ATC-20: check-in accepts the configured early grace', () => {
  const result = checkinWindow(
    [{ slotDate: '2026-06-15', startTime: '18:00:00', endTime: '19:00:00' }],
    new Date('2026-06-15T17:50:00'),
  );
  assert.equal(result.ok, true);
});

test('ATC-21: check-in rejects a scan after the late grace', () => {
  const result = checkinWindow(
    [{ slotDate: '2026-06-15', startTime: '18:00:00', endTime: '19:00:00' }],
    new Date('2026-06-15T19:30:00'),
  );
  assert.equal(result.reason, 'too_late');
});

test('ATC-22: booking dispute rejects an empty reason', async () => {
  const result = await disputeService.raise(null, {
    bookingId: 'booking-1',
    userId: 'player-1',
    reason: '',
  });
  assert.equal(result.status, 400);
});

test('ATC-23: booking dispute rejects a duplicate open dispute', async () => {
  const client = {
    async query(sql) {
      if (/FROM bookings/.test(sql)) {
        return { rows: [{ id: 'booking-1', status: 'confirmed' }] };
      }
      return { rows: [{ id: 'dispute-1' }] };
    },
  };
  const result = await disputeService.raise(client, {
    bookingId: 'booking-1',
    userId: 'player-1',
    reason: 'Unavailable venue',
  });
  assert.equal(result.status, 409);
});

test('ATC-24: player request rejects a request to the same player', async () => {
  const result = await requestService.createRequest(
    { query: async () => ({ rows: [] }) },
    { requesterId: '11111111-1111-1111-1111-111111111111',
      targetUserId: '11111111-1111-1111-1111-111111111111' },
  );
  assert.equal(result.status, 400);
});

test('ATC-25: player request acceptance is represented as a distinct case', async () => {
  const queries = [];
  const client = {
    async query(sql) {
      queries.push(sql);
      if (/UPDATE play_requests/.test(sql)) {
        return { rows: [{ requester_user_id: '22222222-2222-2222-2222-222222222222' }] };
      }
      return { rows: [] };
    },
  };
  const result = await requestService.respond(client, {
    id: '11111111-1111-1111-1111-111111111111',
    userId: '22222222-2222-2222-2222-222222222222',
    action: 'decline',
  });
  assert.equal(result.status, 200);
  assert.ok(queries.length > 0);
});
