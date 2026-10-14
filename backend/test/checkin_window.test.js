/**
 * Check-in window (QR scan time gate).
 *
 * The arithmetic lives in a pure function so it can be proved without a database:
 * every case fixes `now` to a PKT wall-clock string, the same frame the slot times
 * are in and the same one the scan query hands the function at runtime.
 */

const test = require('node:test');
const assert = require('node:assert');

const { checkinWindow, POLICY } = require('../src/utils/escrow');

// A one-hour evening slot, used by most cases.
const SLOT = { slotDate: '2026-06-15', startTime: '18:00:00', endTime: '19:00:00' };
const at = (s) => new Date(`2026-06-15T${s}`);

test('refuses a scan more than the grace before the slot starts', () => {
  const r = checkinWindow([SLOT], at('17:40:00')); // 20 min early, grace is 15
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'too_early');
});

test('accepts a scan inside the early grace', () => {
  assert.equal(checkinWindow([SLOT], at('17:50:00')).ok, true); // 10 min early
});

test('accepts a scan during the slot', () => {
  assert.equal(checkinWindow([SLOT], at('18:00:00')).ok, true);
  assert.equal(checkinWindow([SLOT], at('18:30:00')).ok, true);
});

test('accepts a scan inside the late grace', () => {
  assert.equal(checkinWindow([SLOT], at('19:10:00')).ok, true); // 10 min after end
});

test('refuses a scan after the late grace', () => {
  const r = checkinWindow([SLOT], at('19:30:00')); // 30 min after end, grace is 15
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'too_late');
});

test('spans the whole run for a multi-slot group', () => {
  const group = [
    { slotDate: '2026-06-15', startTime: '18:00:00', endTime: '19:00:00' },
    { slotDate: '2026-06-15', startTime: '19:00:00', endTime: '20:00:00' },
  ];
  assert.equal(checkinWindow(group, at('18:40:00')).ok, true); // inside first slot
  assert.equal(checkinWindow(group, at('19:40:00')).ok, true); // inside second slot
  assert.equal(checkinWindow(group, at('20:30:00')).reason, 'too_late'); // past run end + grace
});

test('handles a slot that runs past midnight', () => {
  const late = { slotDate: '2026-06-15', startTime: '23:00:00', endTime: '00:00:00' };
  assert.equal(checkinWindow([late], at('23:30:00')).ok, true);
  // 00:10 the next day is inside the 15-min grace after a midnight end.
  assert.equal(checkinWindow([late], new Date('2026-06-16T00:10:00')).ok, true);
  assert.equal(checkinWindow([late], new Date('2026-06-16T00:30:00')).reason, 'too_late');
});

test('never blocks on empty or unparseable input', () => {
  assert.equal(checkinWindow([], at('18:00:00')).ok, true);
  assert.equal(checkinWindow([{ slotDate: 'nope', startTime: 'x', endTime: 'y' }], at('18:00:00')).ok, true);
});

test('the window matches the documented policy', () => {
  assert.equal(POLICY.CHECKIN_EARLY_MINUTES, 15);
  assert.equal(POLICY.CHECKIN_LATE_MINUTES, 15);
});
