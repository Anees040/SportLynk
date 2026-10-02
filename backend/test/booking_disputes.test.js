/**
 * test/booking_disputes.test.js — bookingDisputeService without a database.
 *
 * These prove the BRANCHING: ownership, the open-dispute guard, and that a resolve
 * moves money only when it should. The money arithmetic itself is deliberately the
 * same escrow helpers (lockWallet/applyWallet/logTxn) and the same statements
 * cancelBooking uses, so its correctness is a reuse guarantee verified live after
 * migration 032 is applied — the one path these stubs do not exercise is the
 * refundable uphold, because stubbing the escrow SQL would test the stub, not the
 * money. Everything that decides WHETHER money moves is covered here.
 */
const test = require('node:test');
const assert = require('node:assert/strict');

const svc = require('../src/services/bookingDisputeService');

/** A client whose query() answers by matching the SQL, and records every call. */
function stub(rules = []) {
  const seen = [];
  return {
    seen,
    async query(sql, args) {
      const s = String(sql).replace(/\s+/g, ' ').trim();
      seen.push({ sql: s, args });
      for (const r of rules) {
        if (r.match.test(s)) return { rows: r.rows || [], rowCount: (r.rows || []).length };
      }
      return { rows: [], rowCount: 0 };
    },
    ran(re) { return this.seen.some((q) => re.test(q.sql)); },
  };
}

test('raise: an empty reason is refused before any query', async () => {
  const c = stub();
  const out = await svc.raise(c, { userId: 'u1', bookingId: 'b1', reason: '   ' });
  assert.equal(out.ok, false);
  assert.equal(out.status, 400);
  assert.equal(c.seen.length, 0, 'nothing is read until there is a reason to file');
});

test('raise: a booking that is not the caller\'s is a 404', async () => {
  const c = stub([{ match: /FROM bookings b WHERE b\.id/, rows: [] }]);
  const out = await svc.raise(c, { userId: 'u1', bookingId: 'b1', reason: 'double booked' });
  assert.equal(out.status, 404);
  assert.ok(!c.ran(/INSERT INTO booking_disputes/), 'no dispute is filed for a foreign booking');
});

test('raise: a second open dispute on the same booking is a 409', async () => {
  const c = stub([
    { match: /FROM bookings b WHERE b\.id/, rows: [{ id: 'b1', status: 'confirmed' }] },
    { match: /FROM booking_disputes WHERE booking_id = \$1 AND status = 'open'/, rows: [{ x: 1 }] },
  ]);
  const out = await svc.raise(c, { userId: 'u1', bookingId: 'b1', reason: 'owner no-show' });
  assert.equal(out.status, 409);
  assert.ok(!c.ran(/INSERT INTO booking_disputes/));
});

test('raise: a valid first dispute is filed', async () => {
  const c = stub([
    { match: /FROM bookings b WHERE b\.id/, rows: [{ id: 'b1', status: 'confirmed' }] },
    { match: /FROM booking_disputes WHERE booking_id = \$1 AND status = 'open'/, rows: [] },
    { match: /INSERT INTO booking_disputes/, rows: [{ id: 'd1', status: 'open', booking_id: 'b1' }] },
  ]);
  const out = await svc.raise(c, { userId: 'u1', bookingId: 'b1', reason: 'charged but slot gone' });
  assert.equal(out.ok, true);
  assert.equal(out.status, 201);
  assert.equal(out.row.status, 'open');
});

test('resolve: an unknown dispute is a 404', async () => {
  const c = stub([{ match: /FROM booking_disputes\s+WHERE id = \$1 FOR UPDATE/, rows: [] }]);
  const out = await svc.resolve(c, { disputeId: 'd1', adminId: 'a1', uphold: true });
  assert.equal(out.status, 404);
});

test('resolve: a dispute that is already resolved cannot be ruled again', async () => {
  const c = stub([
    { match: /FROM booking_disputes\s+WHERE id = \$1 FOR UPDATE/, rows: [{ id: 'd1', status: 'upheld' }] },
  ]);
  const out = await svc.resolve(c, { disputeId: 'd1', adminId: 'a1', uphold: false });
  assert.equal(out.status, 409);
});

test('resolve: rejecting closes the row and moves no money', async () => {
  const c = stub([
    { match: /FROM booking_disputes\s+WHERE id = \$1 FOR UPDATE/, rows: [{ id: 'd1', status: 'open', booking_id: 'b1' }] },
    { match: /SET status = 'rejected'/, rows: [{ id: 'd1', status: 'rejected', refund_amount: null }] },
  ]);
  const out = await svc.resolve(c, { disputeId: 'd1', adminId: 'a1', uphold: false, notes: 'no evidence' });
  assert.equal(out.ok, true);
  assert.equal(out.refund, 0);
  assert.equal(out.row.status, 'rejected');
  assert.ok(!c.ran(/FROM bookings b JOIN venues/), 'a rejection never touches the booking');
  assert.ok(!c.ran(/UPDATE slots SET status = 'available'/), 'and never frees a slot');
});

test('resolve: upholding an already-settled booking records the verdict with no auto-refund', async () => {
  const c = stub([
    { match: /FROM booking_disputes\s+WHERE id = \$1 FOR UPDATE/, rows: [{ id: 'd1', status: 'open', booking_id: 'b1' }] },
    { match: /FROM bookings b JOIN venues/, rows: [{ id: 'b1', status: 'completed', slot_id: 's1', player_id: 'u1', security_deposit: 1600, venue_name: 'Rawal' }] },
    { match: /SET status = 'upheld'/, rows: [{ id: 'd1', status: 'upheld', refund_amount: 0 }] },
  ]);
  const out = await svc.resolve(c, { disputeId: 'd1', adminId: 'a1', uphold: true });
  assert.equal(out.ok, true);
  assert.equal(out.refund, 0, 'the escrow was already released, so nothing is auto-refunded');
  assert.equal(out.row.status, 'upheld');
  assert.ok(!c.ran(/UPDATE slots SET status = 'available'/),
    'a settled booking is not re-cancelled and its slot is not freed');
});
