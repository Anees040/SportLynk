/**
 * fixtureSchedule.test.js — the calendar half of the tournament maths.
 *
 * Same discipline as test/fixtures.test.js: no database, no ml-service, no clock.
 * Every scenario builds its own slot pool, so a failure here is a failure of the
 * allocator and never of the environment.
 *
 * The properties worth defending, in the order they are tested:
 *   - a fixture is placed on a real venue hour, once, and no hour is used twice;
 *   - rounds are ordered in time, so nobody plays a semi-final before their
 *     quarter-final (the calendar rule and the clock rule, separately);
 *   - byes cost the tournament nothing, because nobody turns up to one;
 *   - the model path takes the dead hours for every round but the final, and the
 *     final takes the busiest hour of its date on purpose;
 *   - with no model, the schedule is plainly chronological — the fallback the
 *     documentation and `meta.scheduling.source` both promise;
 *   - a venue without enough free hours gets a refusal and not a half-built
 *     bracket, because a half-built bracket mis-prices the whole tournament.
 */
const test = require('node:test');
const assert = require('node:assert/strict');

const fx = require('../src/utils/fixtures');
const sch = require('../src/utils/fixtureSchedule');

/** Prices and demand that mirror a real futsal ground: quiet afternoons, busy evenings. */
const PRICE = {
  11: 1000, 12: 1200, 13: 1200, 14: 1200, 15: 1200,
  16: 1500, 17: 1500, 18: 2500, 19: 2500, 20: 2500, 21: 2000, 22: 1800,
};
const DEMAND = {
  11: 0.05, 12: 0.08, 13: 0.08, 14: 0.10, 15: 0.10,
  16: 0.15, 17: 0.25, 18: 0.60, 19: 0.80, 20: 0.85, 21: 0.50, 22: 0.30,
};

/** A pool of venue hours: `days` dates × the given hours, priced as above. */
function pool({ days = 3, hours = [16, 17, 18, 19, 20, 21], from = '2026-09-01' } = {}) {
  const slots = [];
  const demand = {};
  const start = sch.dateKey(from);
  for (let d = 0; d < days; d += 1) {
    const date = sch.keyToDate(start + d);
    for (const h of hours) {
      const id = `${date}#${h}`;
      slots.push({
        id,
        slot_date_str: date,
        start_time: `${String(h).padStart(2, '0')}:00:00`,
        end_time: `${String(h + 1).padStart(2, '0')}:00:00`,
        price: String(PRICE[h]),
      });
      demand[id] = DEMAND[h];
    }
  }
  return { slots, demand };
}

/** n teams with descending ELO, already seeded, plus the built fixtures. */
function bracket(n, format = fx.FORMATS.KNOCKOUT) {
  const teams = Array.from({ length: n }, (_, i) => ({
    id: `t${i + 1}`, name: `Team ${i + 1}`, elo: 1500 - i * 25,
  }));
  const seeded = fx.seedTeams(teams);
  return { seeded, built: fx.buildFixtures(format, seeded) };
}

/** The hour a slot id carries, for readable assertions. */
const hourOf = (slotId) => Number(String(slotId).split('#')[1]);

test('1 · dates and times survive both spellings pg hands back', () => {
  assert.equal(sch.dateString('2026-09-01'), '2026-09-01');
  assert.equal(sch.dateString('2026-09-01T18:00:00.000Z'), '2026-09-01');
  assert.equal(sch.keyToDate(sch.dateKey('2026-09-01')), '2026-09-01');
  assert.equal(sch.dateKey('2026-09-02') - sch.dateKey('2026-09-01'), 1);
  assert.equal(sch.dateKey('2026-03-01') - sch.dateKey('2026-02-28'), 1, 'no leap day in 2026');
  assert.equal(sch.dateKey('2024-03-01') - sch.dateKey('2024-02-28'), 2, 'leap day in 2024');

  // node-postgres returns a date as a Date at local midnight. Reading it with
  // toISOString() reports the previous day west of PKT, which is the bug
  // dateString exists to avoid, so it must read the local components.
  const local = new Date(2026, 8, 1, 0, 0, 0);
  assert.equal(sch.dateString(local), '2026-09-01');
  assert.equal(sch.dateString(new Date('nonsense')), null);
  assert.equal(sch.dateString(null), null);
  assert.equal(sch.dateKey('not a date'), null);

  assert.equal(sch.timeMinutes('18:00:00'), 1080);
  assert.equal(sch.timeMinutes('18:30'), 1110);
  assert.equal(sch.timeMinutes('7:05'), 425);
  assert.equal(sch.timeMinutes('24:00'), null);
  assert.equal(sch.timeMinutes('18:60'), null);
  assert.equal(sch.timeMinutes(''), null);
  assert.equal(sch.minutesTime(1080), '18:00:00');
  assert.equal(sch.minutesTime(0), '00:00:00');
  assert.equal(sch.minutesTime(1440 + 90), '01:30:00', 'wraps into the next day');
});

test('2 · scheduled_at carries the PKT offset, not the server timezone', () => {
  // fixtures.scheduled_at is a timestamptz. An offset-free string would store
  // 18:00 in whatever timezone the session happens to be in; +05:00 stores the
  // instant the players are expected at the ground wherever the server sits.
  assert.equal(sch.pktIso('2026-09-01', 18 * 60), '2026-09-01T18:00:00+05:00');
  assert.equal(sch.PKT_SUFFIX, '+05:00');
  const iso = sch.pktIso('2026-09-01', 18 * 60);
  assert.equal(new Date(iso).toISOString(), '2026-09-01T13:00:00.000Z', '18:00 PKT is 13:00 UTC');
  // A slot that runs past midnight rolls the date forward rather than reporting
  // 25:00, which Postgres would reject.
  assert.equal(sch.pktIso('2026-09-01', 24 * 60 + 30), '2026-09-02T00:30:00+05:00');
  assert.equal(sch.pktIso(null, 60), null);
});

test('3 · a slot row is read the way the service actually selects it', () => {
  const s = sch.normaliseSlot({
    id: 'a', slot_date_str: '2026-09-01', start_time: '18:00:00',
    end_time: '19:00:00', price: '2500.00',
  });
  assert.equal(s.date, '2026-09-01');
  assert.equal(s.startTime, '18:00:00');
  assert.equal(s.endTime, '19:00:00');
  assert.equal(s.price, 2500, 'pg DECIMAL arrives as a string and must become a number');
  assert.equal(s.endAt - s.startAt, 60);

  // No end_time: fall back to the tournament's slot_minutes.
  const ninety = sch.normaliseSlot(
    { id: 'b', slot_date: '2026-09-01', startTime: '18:00' }, { slotMinutes: 90 },
  );
  assert.equal(ninety.endAt - ninety.startAt, 90);
  assert.equal(sch.normaliseSlot({ id: 'c', date: '2026-09-01', start_time: '18:00' })
    .endAt % 1440, 19 * 60, 'default slot length is an hour');

  // 23:00 → 00:00 is a one-hour slot that crosses midnight, not a negative one.
  const late = sch.normaliseSlot({ id: 'd', slot_date: '2026-09-01', start_time: '23:00', end_time: '00:00' });
  assert.equal(late.endAt - late.startAt, 60);

  // One malformed row must not stop a tournament that has good ones.
  assert.equal(sch.normaliseSlot({ slot_date: '2026-09-01', start_time: '18:00' }), null, 'no id');
  assert.equal(sch.normaliseSlot({ id: 'e', start_time: '18:00' }), null, 'no date');
  assert.equal(sch.normaliseSlot({ id: 'f', slot_date: '2026-09-01' }), null, 'no time');
  assert.equal(sch.normaliseSlot(null), null);
});

test('4 · demand is read from whatever shape the scheduler built', () => {
  const slot = { id: 'x' };
  assert.equal(sch.readDemand({ x: 0.7 }, slot), 0.7, 'plain object');
  assert.equal(sch.readDemand(new Map([['x', 0.7]]), slot), 0.7, 'Map');
  assert.equal(sch.readDemand((id) => (id === 'x' ? 0.7 : null), slot), 0.7, 'function');
  assert.equal(sch.readDemand({ x: { pBooked: 0.7 } }, slot), 0.7, 'ml-service row');
  assert.equal(sch.readDemand({ x: { p_booked: 0.7 } }, slot), 0.7, 'snake_case row');
  assert.equal(sch.readDemand({ x: 4 }, slot), 1, 'clamped');
  assert.equal(sch.readDemand({ x: -1 }, slot), 0, 'clamped');
  // A slot the model could not score is neutral, so a partial response degrades
  // one slot instead of poisoning the allocation.
  assert.equal(sch.readDemand({ y: 0.7 }, slot), null);
  assert.equal(sch.readDemand({ x: 'busy' }, slot), null);
  assert.equal(sch.readDemand(null, slot), null);
  assert.equal(sch.NEUTRAL_DEMAND, 0.5);
});

test('5 · the three ranking strategies, and their tiebreaks', () => {
  const { slots, demand } = pool({ days: 1 });
  const norm = slots.map((r) => {
    const s = sch.normaliseSlot(r);
    s.pBooked = demand[s.id];
    return s;
  });

  assert.deepEqual(sch.rankSlots(norm, sch.PICK.CHEAP).map((s) => hourOf(s.id)),
    [16, 17, 21, 18, 19, 20], 'quietest hour first');
  assert.deepEqual(sch.rankSlots(norm, sch.PICK.PEAK).map((s) => hourOf(s.id)),
    [20, 19, 18, 21, 17, 16], 'busiest hour first');
  assert.deepEqual(sch.rankSlots(norm, sch.PICK.EARLY).map((s) => hourOf(s.id)),
    [16, 17, 18, 19, 20, 21], 'chronological, full stop');

  // Price is the second sort so the cost benefit survives flat model scores…
  const flat = norm.map((s) => ({ ...s, pBooked: 0.4 }));
  assert.deepEqual(sch.rankSlots(flat, sch.PICK.CHEAP).map((s) => hourOf(s.id)),
    [16, 17, 21, 18, 19, 20], 'equal demand → cheapest first');
  // …and time is the third, so the result is deterministic enough to assert on.
  const same = norm.map((s) => ({ ...s, pBooked: 0.4, price: 1000 }));
  assert.deepEqual(sch.rankSlots(same, sch.PICK.CHEAP).map((s) => hourOf(s.id)),
    [16, 17, 18, 19, 20, 21]);
  assert.equal(norm[0].pBooked, DEMAND[16], 'ranking must not mutate its input');
});

test('6 · a round takes one date when the venue can host it there', () => {
  const mk = (id, date, h) => sch.normaliseSlot(
    { id, slot_date_str: date, start_time: `${h}:00`, price: 1000 },
  );
  // Day 1 has a single spare hour and day 2 has three. A four-fixture round that
  // borrowed day 1's leftover would give half the draw a day less rest, so the
  // earlier date is skipped and its hour stays sellable.
  const eligible = [mk('a', '2026-09-01', 21), mk('b', '2026-09-02', 16),
    mk('c', '2026-09-02', 17), mk('d', '2026-09-02', 18)];
  const one = sch.dayWindow(eligible, 3);
  assert.deepEqual(one.dates, ['2026-09-02']);
  assert.equal(one.split, false);
  assert.deepEqual(one.window.map((s) => s.id), ['b', 'c', 'd']);

  // Only when no single date can hold the round does it span dates.
  const spread = sch.dayWindow(eligible, 4);
  assert.deepEqual(spread.dates, ['2026-09-01', '2026-09-02']);
  assert.equal(spread.split, true);
  assert.equal(spread.window.length, 4);

  // One fixture needs one hour, so the earliest date wins outright.
  assert.deepEqual(sch.dayWindow(eligible, 1).dates, ['2026-09-01']);
});

test('7 · an 8-team bracket lands on 7 real hours, each used once', () => {
  const { slots, demand } = pool();
  const { built } = bracket(8);
  const r = sch.allocate({ fixtures: built.fixtures, slots, demand, notBefore: '2026-09-01' });

  assert.equal(r.ok, true, r.message || '');
  assert.equal(r.need, 7, 'a knockout for 8 needs n-1 hours');
  assert.equal(r.slotsUsed, 7);
  assert.equal(r.assignments.length, 7);
  assert.equal(r.byes.length, 0);
  assert.equal(r.shortfall, null);
  assert.equal(r.dropped, 0);
  assert.equal(r.demandUsed, true);

  const ids = r.assignments.map((a) => a.slotId);
  assert.equal(new Set(ids).size, 7, 'no venue hour is sold to two fixtures');
  const keys = r.assignments.map((a) => a.key);
  assert.equal(new Set(keys).size, 7, 'one assignment per (round, position)');
  for (const a of r.assignments) {
    assert.equal(a.key, sch.keyOf(a.round, a.position));
    assert.equal(a.scheduledAt, `${a.slotDate}T${a.startTime}+05:00`);
    assert.ok(Number.isFinite(a.price) && a.price > 0, 'a price, as a number');
    assert.ok(slots.some((s) => s.id === a.slotId), 'the slot came from the pool');
  }
  // The stored economics are the sum of the hours taken, which is what
  // makes tournaments.venue_cost_amount auditable against the slots table.
  const total = r.assignments.reduce((t, a) => t + a.price, 0);
  assert.equal(r.slotTotal, total);
  assert.equal(r.slotTotal, r.rounds.reduce((t, m) => t + m.total, 0));
  assert.deepEqual(r.rounds.map((m) => m.count), [4, 2, 1]);
  assert.deepEqual(r.rounds.map((m) => m.label), ['Quarter-final', 'Semi-final', 'Final']);
});

test('8 · rounds are ordered in time — nobody plays a semi before their quarter', () => {
  const { slots, demand } = pool({ days: 4 });
  const { built } = bracket(8);
  const r = sch.allocate({ fixtures: built.fixtures, slots, demand, notBefore: '2026-09-01' });
  assert.equal(r.ok, true);

  const at = (a) => new Date(a.scheduledAt).getTime();
  for (let i = 1; i < r.rounds.length; i += 1) {
    const prev = r.assignments.filter((a) => a.round === r.rounds[i - 1].round);
    const next = r.assignments.filter((a) => a.round === r.rounds[i].round);
    assert.ok(Math.max(...prev.map(at)) < Math.min(...next.map(at)),
      `round ${r.rounds[i].round} starts only after round ${r.rounds[i - 1].round} is done`);
  }
  // The default is a day of calendar rest, so each round owns its own date.
  const dates = r.rounds.map((m) => m.date);
  assert.equal(new Set(dates).size, r.rounds.length);
  assert.deepEqual(dates, ['2026-09-01', '2026-09-02', '2026-09-03']);
  for (const m of r.rounds) assert.equal(m.spansDays, false);
  assert.equal(r.startDate, '2026-09-01');
  assert.equal(r.endDate, '2026-09-03');
});

test('9 · the calendar rule is measured in dates, not in 24-hour blocks', () => {
  // The cascade this guards against: round 1 finishing at 21:00 with a gap
  // measured from the final whistle would push round 2 past 21:00 the next day
  // and round 3 past 21:00 the day after, and a bracket would run out of evening
  // and fail to schedule on a venue that plainly has room for it.
  const { slots, demand } = pool({ days: 3, hours: [18, 19, 20, 21] });
  const { built } = bracket(8);
  const r = sch.allocate({
    fixtures: built.fixtures, slots, demand, notBefore: '2026-09-01', roundGapDays: 1,
  });
  assert.equal(r.ok, true, r.message || '');
  assert.deepEqual(r.rounds.map((m) => m.date), ['2026-09-01', '2026-09-02', '2026-09-03']);
  // Round 1 used the last hour of day 1, and round 2 still starts in the evening
  // of day 2 rather than being pushed to 22:00.
  assert.ok(r.rounds[0].slotIds.some((id) => hourOf(id) === 21));
  assert.equal(sch.timeMinutes(r.assignments.find((a) => a.round === 2).startTime), 18 * 60);
});

test('10 · a one-day cup: the clock rule keeps a squad from playing twice at once', () => {
  // Ten hours is what a 7-fixture bracket with an hour of rest per round needs:
  // 4 + rest + 2 + rest + 1. Nine would legitimately refuse, and does below.
  const { slots, demand } = pool({ days: 1, hours: [11, 12, 13, 14, 15, 16, 17, 18, 19, 20] });
  const { built } = bracket(8);
  const r = sch.allocate({
    fixtures: built.fixtures, slots, demand, notBefore: '2026-09-01',
    roundGapDays: 0, roundRestMinutes: 60,
  });
  assert.equal(r.ok, true, r.message || '');
  assert.equal(new Set(r.assignments.map((a) => a.slotDate)).size, 1, 'all on one date');

  const end = (a) => sch.timeMinutes(a.endTime);
  const start = (a) => sch.timeMinutes(a.startTime);
  for (let round = 2; round <= 3; round += 1) {
    const prev = r.assignments.filter((a) => a.round === round - 1);
    const next = r.assignments.filter((a) => a.round === round);
    assert.ok(Math.min(...next.map(start)) >= Math.max(...prev.map(end)) + 60,
      `round ${round} gives an hour of rest after round ${round - 1}`);
  }
  // Packing wins over demand when the rounds share a date: the early rounds take
  // the earliest hours so the day fits, and only the final consults the model.
  assert.deepEqual(r.rounds.map((m) => m.pick), ['early', 'early', 'peak']);
  assert.deepEqual(r.rounds[0].slotIds.map(hourOf), [11, 12, 13, 14]);
  assert.deepEqual(r.rounds[1].slotIds.map(hourOf), [16, 17]);
  assert.deepEqual(r.rounds[2].slotIds.map(hourOf), [20], 'the final buys the busiest hour left');
});

test('11 · byes cost the tournament nothing', () => {
  // 5 teams in a bracket of 8: three byes, four hours of venue. A bye is nobody
  // turning up, so booking an hour for one would charge the pool for an empty
  // ground and hand the owner an hour they could have sold.
  const { slots, demand } = pool();
  const { built } = bracket(5);
  assert.equal(built.byes, 3);
  const r = sch.allocate({ fixtures: built.fixtures, slots, demand, notBefore: '2026-09-01' });

  assert.equal(r.ok, true, r.message || '');
  assert.equal(r.need, 4, 'seven bracket nodes minus three byes');
  assert.equal(r.slotsUsed, 4);
  assert.equal(r.byes.length, 3);
  for (const b of r.byes) assert.equal(b.round, 1, 'byes only ever happen in round 1');
  const byeKeys = new Set(r.byes.map((b) => sch.keyOf(b.round, b.position)));
  for (const a of r.assignments) assert.ok(!byeKeys.has(a.key), 'no hour was spent on a bye');
  assert.equal(r.slotTotal, r.assignments.reduce((t, a) => t + a.price, 0));

  // The one real round-1 match is 4 v 5; the rest of round 1 walked over.
  assert.deepEqual(r.rounds.map((m) => m.count), [1, 2, 1]);
});

test('12 · the model takes the dead hours, the final buys the busiest one', () => {
  const { slots, demand } = pool();
  const { built } = bracket(8);
  const model = sch.allocate({ fixtures: built.fixtures, slots, demand, notBefore: '2026-09-01' });
  const chrono = sch.allocate({ fixtures: built.fixtures, slots, notBefore: '2026-09-01' });
  assert.equal(model.ok, true);
  assert.equal(chrono.ok, true);
  assert.equal(model.demandUsed, true);
  assert.equal(chrono.demandUsed, false, 'no scores → the fallback, and it says so');
  assert.deepEqual(model.rounds.map((m) => m.pick), ['cheap', 'cheap', 'peak']);
  assert.deepEqual(chrono.rounds.map((m) => m.pick), ['early', 'early', 'early']);

  // The precise claim, which is the one the check script will assert on a real
  // tournament: every round but the final costs no more than a chronological
  // schedule would, and the final deliberately takes the busiest hour instead.
  const beforeFinal = (r) => r.rounds.slice(0, -1).reduce((t, m) => t + m.total, 0);
  assert.ok(beforeFinal(model) <= beforeFinal(chrono),
    `early rounds: model ${beforeFinal(model)} ≤ chronological ${beforeFinal(chrono)}`);
  assert.ok(beforeFinal(model) < beforeFinal(chrono), 'and strictly cheaper at a peak-priced venue');

  const final = model.rounds[2];
  assert.equal(final.meanPBooked, 0.85, 'the busiest hour of its date');
  assert.ok(final.meanPBooked > final.meanWindowPBooked, 'busier than the average hour available');
  for (const m of model.rounds.slice(0, -1)) {
    assert.ok(m.meanPBooked < m.meanWindowPBooked,
      `round ${m.round} sits below the day's average demand`);
  }
});

test('13 · a venue without the hours gets a refusal, not half a bracket', () => {
  // A partial schedule is worse than none: venue_cost would be summed over three
  // hours while the tournament consumed seven, so the owner would be paid for
  // three and the prize pool computed from a cost that never happened.
  const { slots, demand } = pool({ days: 1, hours: [18, 19, 20] });
  const { built } = bracket(8);
  const r = sch.allocate({ fixtures: built.fixtures, slots, demand, notBefore: '2026-09-01' });

  assert.equal(r.ok, false);
  assert.equal(r.code, 'not_enough_slots');
  assert.deepEqual(r.assignments, [], 'nothing is placed');
  assert.equal(r.slotTotal, 0);
  assert.equal(r.slotsUsed, 0);
  assert.deepEqual(r.shortfall, { round: 1, need: 4, available: 3 });
  assert.match(r.message, /Round 1 needs 4 free hours/);
  assert.doesNotMatch(r.message, /after the previous round/, 'round 1 has no previous round');
  assert.match(r.message, /Open more slots/, 'the owner is told what to do about it');

  // A later round running out names that round instead.
  const two = sch.allocate({
    fixtures: built.fixtures, slots: pool({ days: 1, hours: [16, 17, 18, 19] }).slots,
    notBefore: '2026-09-01',
  });
  assert.equal(two.ok, false);
  assert.equal(two.shortfall.round, 2);
  assert.match(two.message, /after the previous round/);
});

test('14 · nothing is scheduled before the registration deadline', () => {
  const { slots, demand } = pool({ days: 4 });
  const { built } = bracket(4);
  // The deadline falls mid-afternoon on day 2, so day 1 and day 2's earlier hours
  // are off the table however quiet the model says they are.
  const r = sch.allocate({
    fixtures: built.fixtures, slots, demand,
    notBefore: { date: '2026-09-02', time: '18:00' },
  });
  assert.equal(r.ok, true, r.message || '');
  for (const a of r.assignments) {
    assert.ok(new Date(a.scheduledAt).getTime() >= new Date('2026-09-02T18:00:00+05:00').getTime(),
      `${a.slotDate} ${a.startTime} is on or after the deadline`);
  }
  assert.equal(r.rounds[0].date, '2026-09-02');
  assert.deepEqual(r.rounds[0].slotIds.map(hourOf), [18, 21], 'the quietest hours still open');

  // The same instant in the other shapes a caller might have it in.
  const iso = sch.allocate({ fixtures: built.fixtures, slots, demand, notBefore: '2026-09-02T18:00:00' });
  assert.deepEqual(iso.assignments.map((a) => a.slotId), r.assignments.map((a) => a.slotId));
  assert.equal(sch.notBeforeMinutes(null), null, 'no deadline → the whole pool');
});

test('15 · a round-robin matchday puts no team on the pitch twice in a day', () => {
  const { seeded, built } = bracket(6, fx.FORMATS.ROUND_ROBIN);
  assert.equal(built.fixtures.length, 15, '6 teams = n(n-1)/2');
  assert.equal(built.rounds, 5);
  const { slots, demand } = pool({ days: 5, hours: [16, 17, 18, 19, 20, 21] });
  const r = sch.allocate({
    fixtures: built.fixtures, slots, demand,
    notBefore: '2026-09-01', format: fx.FORMATS.ROUND_ROBIN,
  });

  assert.equal(r.ok, true, r.message || '');
  assert.equal(r.slotsUsed, 15);
  assert.deepEqual(r.rounds.map((m) => m.count), [3, 3, 3, 3, 3]);

  // Every matchday is its own date, and within a date every team appears once.
  const byKey = new Map(built.fixtures.map((f) => [sch.keyOf(f.round, f.position), f]));
  const perDate = new Map();
  for (const a of r.assignments) {
    const f = byKey.get(a.key);
    if (!perDate.has(a.slotDate)) perDate.set(a.slotDate, []);
    perDate.get(a.slotDate).push(f.teamA, f.teamB);
  }
  assert.equal(perDate.size, 5, 'five matchdays, five dates');
  for (const [date, teams] of perDate) {
    const real = teams.filter(Boolean);
    assert.equal(new Set(real).size, real.length, `no team plays twice on ${date}`);
    assert.equal(real.length, 6, 'all six teams play every matchday');
  }
  assert.equal(new Set(seeded.map((t) => t.id)).size, 6);

  // A round-robin has no final worth a peak hour: its last matchday is three
  // fixtures at once, and buying three peak hours would cost the pool more than
  // the occasion is worth.
  assert.deepEqual(r.rounds.map((m) => m.pick), ['cheap', 'cheap', 'cheap', 'cheap', 'cheap']);
  for (const m of r.rounds) assert.deepEqual(m.slotIds.map(hourOf), [16, 17, 21]);
});

test('16 · fixtures read back out of the table allocate the same way', () => {
  const { slots, demand } = pool();
  const { built } = bracket(5);
  // What the table gives back: snake_case, decimal-ish strings, a uuid per row,
  // and the byes already resolved as walkovers.
  const rows = built.fixtures.map((f, i) => ({
    id: `f${i + 1}`,
    round: String(f.round),
    position: String(f.position),
    team_a: f.teamA,
    team_b: f.teamB,
    is_bye: f.isBye,
    status: f.status,
    label: f.label,
  }));
  const r = sch.allocate({ fixtures: rows, slots, demand, notBefore: '2026-09-01' });
  assert.equal(r.ok, true, r.message || '');
  assert.equal(r.slotsUsed, 4);
  assert.equal(r.byes.length, 3);
  for (const a of r.assignments) {
    assert.match(a.fixtureId, /^f\d+$/, 'the row id comes back so the service can UPDATE it');
  }
  // A cancelled fixture is not scheduled at all.
  const cancelled = rows.map((row) => (row.round === '3' ? { ...row, status: 'cancelled' } : row));
  const c = sch.allocate({ fixtures: cancelled, slots, demand, notBefore: '2026-09-01' });
  assert.equal(c.slotsUsed, 3, 'the final was cancelled, so no hour is held for it');
  assert.ok(!c.assignments.some((a) => a.round === 3));
});

test('17 · the allocation is deterministic and the pool is left alone', () => {
  const { slots, demand } = pool();
  const { built } = bracket(8);
  const args = { fixtures: built.fixtures, slots, demand, notBefore: '2026-09-01' };
  const a = sch.allocate(args);
  const b = sch.allocate(args);
  assert.deepEqual(b, a, 'same inputs, same schedule — the check script depends on it');
  assert.equal(slots[0].price, String(PRICE[16]), 'the caller’s rows are not mutated');
  assert.equal(built.fixtures[0].round, 1);

  // Two hours that claim the same id are one hour, and a malformed row is dropped
  // rather than allowed to fail the whole generation.
  const dirty = [...slots, { ...slots[0] }, { id: 'broken', price: 100 }];
  const r = sch.allocate({ ...args, slots: dirty });
  assert.equal(r.ok, true);
  assert.equal(r.dropped, 2);
  assert.equal(r.available, slots.length);
  assert.deepEqual(r.assignments.map((x) => x.slotId), a.assignments.map((x) => x.slotId));
});

test('18 · the empty and degenerate cases answer instead of throwing', () => {
  const { slots, demand } = pool();
  assert.equal(sch.allocate().ok, true, 'nothing to schedule is not a failure');
  assert.deepEqual(sch.allocate().assignments, []);
  assert.equal(sch.allocate({ slots }).slotTotal, 0);
  assert.equal(sch.allocate({ fixtures: [], slots }).firstAt, null);

  // A two-team tournament is one fixture, and that fixture is the final, so it
  // takes the best hour of the earliest date it may be played on.
  const { built } = bracket(2);
  const r = sch.allocate({ fixtures: built.fixtures, slots, demand, notBefore: '2026-09-01' });
  assert.equal(r.slotsUsed, 1);
  assert.equal(r.rounds[0].pick, 'peak');
  assert.equal(r.rounds[0].label, 'Final');
  assert.equal(hourOf(r.assignments[0].slotId), 20, 'the busiest hour of day one');
  assert.equal(r.firstAt, r.lastAt);

  // An all-bye pseudo-bracket consumes no hours and still reports honestly.
  const byesOnly = sch.allocate({
    fixtures: [{ round: 1, position: 1, isBye: true, teamA: 't1', status: 'walkover' }],
    slots, demand, notBefore: '2026-09-01',
  });
  assert.equal(byesOnly.ok, true);
  assert.equal(byesOnly.byes.length, 1);
  assert.equal(byesOnly.slotsUsed, 0);
  assert.deepEqual(byesOnly.rounds, []);
  assert.equal(byesOnly.startDate, null);
});

test('19 · the schedule feeds the economics, and the owner is never underwater', () => {
  // This is the whole chain a service will run, with no database in it: seed the
  // teams, build the bracket, allocate real hours, then price the tournament from
  // the hours taken rather than from an estimate.
  const { slots, demand } = pool();
  const { built } = bracket(8);
  const r = sch.allocate({ fixtures: built.fixtures, slots, demand, notBefore: '2026-09-01' });
  assert.equal(r.ok, true, r.message || '');

  const e = fx.splitPool({ entryFee: 4000, teams: 8, slotTotal: r.slotTotal });
  assert.equal(e.slotTotal, r.slotTotal, 'venue cost is the sum of the fixtures’ own slots');
  assert.equal(e.venueCost, r.slotTotal, 'no discount configured');
  assert.equal(e.identityOk, true, 'pool = venue cost + prize + margin, to the paisa');
  assert.ok(e.ownerEarning >= e.venueCost,
    `the owner clears the inventory first: ${e.ownerEarning} >= ${e.venueCost}`);
  assert.ok(e.uplift > 0, `and beats selling the same hours: +${e.uplift}`);
  assert.equal(e.underwater, false);
  assert.equal(e.winnerShare + e.runnerupShare <= e.prize, true);

  // The recommended fee is computed from the same allocation, so an owner who
  // takes the recommendation cannot end up with a tournament that loses money.
  const rec = fx.recommendEntryFee({ slotTotal: r.slotTotal, minTeams: 4 });
  assert.equal(rec.achievable, true);
  const worst = fx.splitPool({ entryFee: rec.entryFee, teams: 4, slotTotal: r.slotTotal });
  assert.equal(worst.underwater, false, 'even at the minimum turnout the fee covers the venue');
  assert.ok(worst.ownerEarning >= worst.venueCost);
});

test('20 · a 90-minute slot is 90 minutes of rest arithmetic too', () => {
  // slot_minutes lives on the tournament row, and a futsal ground selling
  // 90-minute blocks must not be treated as an hour when the rest is computed.
  // The 14:45 slot is the discriminator: two 90-minute semi-finals from 11:00 and
  // 13:00 finish at 14:30, so with 30 minutes of rest nothing may start before
  // 15:00. Treat the blocks as an hour by mistake and 14:45 becomes legal and is
  // taken, which is exactly the bug this hour is here to catch.
  const slots = ['11:00', '13:00', '14:45', '17:00', '19:00', '21:00'].map((t) => ({
    id: `2026-09-01#${t}`, slot_date_str: '2026-09-01', start_time: `${t}:00`, price: 2000,
  }));
  const { built } = bracket(4);
  const r = sch.allocate({
    fixtures: built.fixtures, slots, notBefore: '2026-09-01',
    slotMinutes: 90, roundGapDays: 0, roundRestMinutes: 30,
  });
  assert.equal(r.ok, true, r.message || '');
  assert.deepEqual(r.assignments.map((a) => a.startTime), ['11:00:00', '13:00:00', '17:00:00']);
  assert.deepEqual(r.assignments.map((a) => a.endTime), ['12:30:00', '14:30:00', '18:30:00']);
  assert.ok(!r.assignments.some((a) => a.startTime === '14:45:00'), '14:45 is inside the rest');
  assert.equal(r.slotTotal, 6000);
});
