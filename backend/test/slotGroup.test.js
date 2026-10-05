/**
 * slotGroup.test.js — the rules that decide whether consecutive slots may be
 * booked together, and what they cost.
 *
 * Same discipline as test/slotGrid.test.js: no database, no ml-service, no clock.
 * utils/slotGroup.js is deliberately free of db/pool so these cases can run
 * without Supabase being reachable, and a failure here is a failure of the group
 * rules and never of the environment.
 *
 * Why this file carries more cases than the feature looks like it needs
 * These are the rules that decide a player's price, and the per-slot discount is
 * what every downstream money figure is derived from: the escrow frozen, the 20%
 * at risk, and what a late cancellation forfeits. A rounding error here is a
 * rounding error in all four.
 *
 * The properties, in the order they are tested:
 *   - a run is unbroken only when each slot starts exactly where the last ended,
 *     including across the midnight seam of a venue whose hours wrap;
 *   - a gap, an overlap or a different day is refused with a reason a player can
 *     read;
 *   - the best qualifying discount wins, not the highest threshold, so booking
 *     more can never cost more;
 *   - the group total is the sum of the rounded per-slot prices, because those are
 *     the figures the booking rows will actually hold;
 *   - a group is at least two slots and at most MAX_GROUP_SLOTS;
 *   - a tier set is validated as a whole, so an owner is told which rule is wrong.
 */
const test = require('node:test');
const assert = require('node:assert/strict');

const group = require('../src/utils/slotGroup');

/** A slot row in the shape the `slots` table returns. */
const slot = (date, start, end, price = 2000, status = 'available') => ({
  id: `${date}-${start}`,
  slot_date: date,
  start_time: start,
  end_time: end,
  price,
  status,
});

const D = '2026-10-10';
const D2 = '2026-10-11';

test('an unbroken run of hours is consecutive', () => {
  const r = group.checkConsecutive([
    slot(D, '18:00:00', '19:00:00'),
    slot(D, '19:00:00', '20:00:00'),
    slot(D, '20:00:00', '21:00:00'),
  ].map(group.normaliseSlot));
  assert.equal(r.ok, true);
  assert.equal(r.reason, null);
});

test('slots given out of order are still consecutive', () => {
  // The player taps 20:00 then 19:00. Sorting is the module's job, not theirs.
  const r = group.checkConsecutive([
    slot(D, '20:00:00', '21:00:00'),
    slot(D, '19:00:00', '20:00:00'),
  ].map(group.normaliseSlot));
  assert.equal(r.ok, true);
});

test('a gap in the middle is refused and the gap is named', () => {
  const r = group.checkConsecutive([
    slot(D, '18:00:00', '19:00:00'),
    slot(D, '20:00:00', '21:00:00'),
  ].map(group.normaliseSlot));
  assert.equal(r.ok, false);
  assert.match(r.reason, /gap between 19:00 and 20:00/);
});

test('an overlap is refused as a gap rather than silently double-booked', () => {
  const r = group.checkConsecutive([
    slot(D, '18:00:00', '19:30:00'),
    slot(D, '19:00:00', '20:00:00'),
  ].map(group.normaliseSlot));
  assert.equal(r.ok, false);
});

test('two different days are refused', () => {
  const r = group.checkConsecutive([
    slot(D, '18:00:00', '19:00:00'),
    slot(D2, '18:00:00', '19:00:00'),
  ].map(group.normaliseSlot));
  assert.equal(r.ok, false);
  assert.match(r.reason, /not on the same day/);
});

test('the midnight seam of a wrapped window is one unbroken run', () => {
  // A ground open 18:00-02:00 most wants to sell 23:00 and 00:00 together, and
  // utils/slotGrid.js stores them on two calendar dates because slot_date plus
  // start_time is wall-clock. Refusing the seam would make the feature useless
  // for exactly the venues that need it.
  const r = group.checkConsecutive([
    slot(D, '23:00:00', '24:00:00'),
    slot(D2, '00:00:00', '01:00:00'),
  ].map(group.normaliseSlot));
  assert.equal(r.ok, true);
});

test('a next-day slot that does not meet the midnight marker is refused', () => {
  // 23:00-24:00 then 01:00 on the next day is a gap, not a seam.
  const r = group.checkConsecutive([
    slot(D, '23:00:00', '24:00:00'),
    slot(D2, '01:00:00', '02:00:00'),
  ].map(group.normaliseSlot));
  assert.equal(r.ok, false);
});

test('a slot ending at 23:00 does not join a next-day 00:00 slot', () => {
  // Only the end-of-day marker bridges the seam. An end of 23:00 leaves an hour
  // unaccounted for, which is a gap wherever it falls.
  const r = group.checkConsecutive([
    slot(D, '22:00:00', '23:00:00'),
    slot(D2, '00:00:00', '01:00:00'),
  ].map(group.normaliseSlot));
  assert.equal(r.ok, false);
});

test('a single slot and an empty set are trivially consecutive', () => {
  assert.equal(group.checkConsecutive([]).ok, true);
  assert.equal(group.checkConsecutive([group.normaliseSlot(slot(D, '18:00:00', '19:00:00'))]).ok, true);
});

test('half-hour slots form a run, so slot length does not have to be an hour', () => {
  const r = group.checkConsecutive([
    slot(D, '14:30:00', '15:00:00'),
    slot(D, '15:00:00', '15:30:00'),
    slot(D, '15:30:00', '16:00:00'),
  ].map(group.normaliseSlot));
  assert.equal(r.ok, true);
});

test('a TIME column is compared whether or not it carries seconds', () => {
  // pg returns '19:00:00'; a hand-written fixture or a client might send '19:00'.
  // Comparing the raw strings would read those as a gap.
  const r = group.checkConsecutive([
    { ...group.normaliseSlot(slot(D, '18:00', '19:00')) },
    { ...group.normaliseSlot(slot(D, '19:00:00', '20:00:00')) },
  ]);
  assert.equal(r.ok, true);
  assert.equal(group.timeStr('19:00'), '19:00:00');
  assert.equal(group.timeStr('9:05'), '09:05:00');
});

test('a slot_date arriving as a Date is normalised, not stringified by the locale', () => {
  // pg hands a DATE back as a Date object. `toISOString` would shift it a day in
  // PKT; bookings store PKT wall-clock text.
  const s = group.normaliseSlot({ ...slot(D, '18:00:00', '19:00:00'), slot_date: new Date(2026, 9, 10) });
  assert.equal(s.date, '2026-10-10');
});

test('the best qualifying discount wins, so booking more never costs more', () => {
  // An owner who enters "3+ 5%" under "2+ 10%" has made a mistake in the
  // player's favour. Reading the ladder by threshold would charge a player more
  // for booking a third hour, which is the one outcome this feature must not
  // produce.
  const tiers = [{ min_slots: 2, percent: 10 }, { min_slots: 3, percent: 5 }];
  assert.equal(group.pickDiscountPercent(tiers, 2), 10);
  assert.equal(group.pickDiscountPercent(tiers, 3), 10);
  assert.equal(group.pickDiscountPercent(tiers, 4), 10);
});

test('a normal ladder deepens as the run gets longer', () => {
  const tiers = [{ min_slots: 2, percent: 5 }, { min_slots: 3, percent: 10 }, { min_slots: 5, percent: 20 }];
  assert.equal(group.pickDiscountPercent(tiers, 1), 0);
  assert.equal(group.pickDiscountPercent(tiers, 2), 5);
  assert.equal(group.pickDiscountPercent(tiers, 3), 10);
  assert.equal(group.pickDiscountPercent(tiers, 4), 10);
  assert.equal(group.pickDiscountPercent(tiers, 5), 20);
  assert.equal(group.pickDiscountPercent(tiers, 8), 20);
});

test('a single slot never earns a multi-slot discount', () => {
  const tiers = [{ min_slots: 2, percent: 10 }];
  assert.equal(group.pickDiscountPercent(tiers, 1), 0);
  assert.equal(group.pickDiscountPercent(tiers, 0), 0);
});

test('no ladder, an empty ladder and an unreadable tier all mean no discount', () => {
  assert.equal(group.pickDiscountPercent(null, 3), 0);
  assert.equal(group.pickDiscountPercent([], 3), 0);
  assert.equal(group.pickDiscountPercent([{ min_slots: 'two', percent: 10 }], 3), 0);
  assert.equal(group.pickDiscountPercent([{ min_slots: 2, percent: 'ten' }], 3), 0);
  assert.equal(group.pickDiscountPercent([{ min_slots: 2, percent: 0 }], 3), 0);
});

test('a discount is clamped to what the database will accept', () => {
  // Mirrors the CHECK on venue_slot_discounts.percent (migration 035). A 100%
  // discount would book a free slot and freeze nothing in escrow, which every
  // refund rule then divides by.
  assert.equal(group.clampDiscount(90), group.MAX_DISCOUNT_PERCENT);
  assert.equal(group.clampDiscount(50), 50);
  assert.equal(group.clampDiscount(12.5), 12.5);
  assert.equal(group.clampDiscount(0), 0);
  assert.equal(group.clampDiscount(-10), 0);
  assert.equal(group.clampDiscount('nonsense'), 0);
  assert.equal(group.clampDiscount(null), 0);
});

test('a discounted price is rounded to the two decimals the money columns hold', () => {
  assert.equal(group.discountedPrice(2000, 10), 1800);
  assert.equal(group.discountedPrice(2500, 15), 2125);
  // 1333 x 0.9 = 1199.7 — exactly two decimals, not a float tail.
  assert.equal(group.discountedPrice(1333, 10), 1199.7);
  assert.equal(group.discountedPrice(2000, 0), 2000);
});

test('a missing price stays missing rather than becoming free', () => {
  // priceOf in utils/slotGrid.js refuses to invent a price; discounting must not
  // turn that refusal into a zero-rupee booking either.
  assert.equal(group.discountedPrice(0, 10), 0);
  assert.equal(group.discountedPrice(null, 10), 0);
  assert.equal(group.discountedPrice(-100, 10), 0);
});

test('the group total is the sum of the per-slot prices the bookings will hold', () => {
  // Each booking row carries its own escrow, deposit and refund, so each price
  // has to stand alone. A separately rounded group total would be a second number
  // to keep in step, and the first time rounding moved it the receipt and the
  // wallet would differ.
  const q = group.quoteGroup(
    [slot(D, '18:00:00', '19:00:00', 1333), slot(D, '19:00:00', '20:00:00', 1333)],
    [{ min_slots: 2, percent: 10 }],
  );
  assert.equal(q.count, 2);
  assert.equal(q.discountPercent, 10);
  assert.deepEqual(q.slots.map((s) => s.price), [1199.7, 1199.7]);
  assert.equal(q.total, 2399.4);
  assert.equal(q.listTotal, 2666);
  assert.equal(q.saved, 266.6);
  // The arithmetic that matters: the total IS the sum of the rows.
  assert.equal(q.total, q.slots.reduce((sum, s) => sum + s.price, 0));
});

test('a quote with no ladder charges list price and saves nothing', () => {
  const q = group.quoteGroup(
    [slot(D, '18:00:00', '19:00:00', 2000), slot(D, '19:00:00', '20:00:00', 2550)],
    [],
  );
  assert.equal(q.discountPercent, 0);
  assert.equal(q.total, 4550);
  assert.equal(q.listTotal, 4550);
  assert.equal(q.saved, 0);
});

test('a quote prices each slot at its own rate, so dynamic pricing survives', () => {
  // Slots are priced per hour by the model (slotService.repriceVenueSlots), so a
  // peak hour inside a run costs more than an off-peak one. A group price derived
  // from one rate times N would throw that away.
  const q = group.quoteGroup(
    [slot(D, '17:00:00', '18:00:00', 2000), slot(D, '18:00:00', '19:00:00', 2550)],
    [{ min_slots: 2, percent: 10 }],
  );
  assert.deepEqual(q.slots.map((s) => s.price), [1800, 2295]);
  assert.equal(q.total, 4095);
});

test('a quote reports the run it covers, sorted, with its first and last time', () => {
  const q = group.quoteGroup(
    [slot(D, '20:00:00', '21:00:00'), slot(D, '18:00:00', '19:00:00'), slot(D, '19:00:00', '20:00:00')],
    [],
  );
  assert.deepEqual(q.slots.map((s) => s.start), ['18:00:00', '19:00:00', '20:00:00']);
  assert.equal(q.from, '18:00:00');
  assert.equal(q.to, '21:00:00');
});

test('a group is at least two slots, and duplicates are not a group', () => {
  const one = group.validateGroupRequest(['a']);
  assert.equal(one.ok, false);
  assert.equal(one.code, 'not_a_group');

  // The same slot tapped twice is one slot, not a two-slot group that would
  // otherwise try to book it twice and deadlock on its own row lock.
  const dup = group.validateGroupRequest(['a', 'a']);
  assert.equal(dup.ok, false);
  assert.equal(dup.code, 'not_a_group');
  assert.deepEqual(dup.ids, ['a']);
});

test('a group is capped, because each slot is a row lock held for the transaction', () => {
  const ids = Array.from({ length: group.MAX_GROUP_SLOTS + 1 }, (_, i) => `s${i}`);
  const r = group.validateGroupRequest(ids);
  assert.equal(r.ok, false);
  assert.equal(r.code, 'group_too_large');
  assert.match(r.message, new RegExp(String(group.MAX_GROUP_SLOTS)));

  const atCap = group.validateGroupRequest(ids.slice(0, group.MAX_GROUP_SLOTS));
  assert.equal(atCap.ok, true);
});

test('blank and repeated ids are dropped before the count is judged', () => {
  const r = group.validateGroupRequest(['a', '', '  ', 'b', 'a', null, undefined]);
  assert.equal(r.ok, true);
  assert.deepEqual(r.ids, ['a', 'b']);
});

test('a tier set is validated as a whole and names the rule that is wrong', () => {
  assert.equal(group.validateTiers([]).ok, true);

  const low = group.validateTiers([{ min_slots: 1, percent: 10 }]);
  assert.equal(low.ok, false);
  assert.match(low.message, /threshold must be between 2 and 12/);

  const high = group.validateTiers([{ min_slots: 2, percent: 80 }]);
  assert.equal(high.ok, false);
  assert.match(high.message, /at most 50%/);

  const zero = group.validateTiers([{ min_slots: 2, percent: 0 }]);
  assert.equal(zero.ok, false);

  const dup = group.validateTiers([{ min_slots: 3, percent: 10 }, { min_slots: 3, percent: 20 }]);
  assert.equal(dup.ok, false);
  assert.match(dup.message, /two rules for 3 slots/);
});

test('a valid tier set comes back sorted and rounded to the column', () => {
  const r = group.validateTiers([
    { min_slots: 5, percent: '20' },
    { min_slots: 2, percent: 7.555 },
  ]);
  assert.equal(r.ok, true);
  assert.deepEqual(r.tiers, [{ min_slots: 2, percent: 7.56 }, { min_slots: 5, percent: 20 }]);
});

test('the module ceilings match the constraints migration 035 writes', () => {
  // These four numbers appear in the CHECK clauses. If one moves in SQL and not
  // here, the owner's form accepts a rule the database then refuses.
  assert.equal(group.MAX_DISCOUNT_PERCENT, 50);
  assert.equal(group.MIN_DISCOUNT_SLOTS, 2);
  assert.equal(group.MAX_DISCOUNT_SLOTS, 12);
  assert.ok(group.MAX_GROUP_SLOTS >= group.MIN_DISCOUNT_SLOTS);
});
