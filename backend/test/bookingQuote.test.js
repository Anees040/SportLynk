const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { createRequire } = require('node:module');

function service(tiers = []) {
  const filename = path.join(__dirname, '../src/services/bookingService.js');
  const realRequire = createRequire(filename);
  const module = { exports: {} };
  vm.runInNewContext(fs.readFileSync(filename, 'utf8'), {
    module, Date,
    require(name) {
      if (name === '../db/pool' || name === '../utils/notify'
          || name === '../utils/trustScore' || name === '../utils/globalSettings'
          || name === '../utils/chatCore') return {};
      if (name === './discountService') return { tiersFor: async () => tiers };
      return realRequire(name);
    },
  }, { filename });
  return module.exports;
}

const slot = (id, start, end, extra = {}) => ({
  id, slot_date: new Date(2026, 9, 21), start_time: start, end_time: end,
  price: '1600.00', status: 'available', held_by_other: false, ...extra,
});

async function quote(rows, tiers = []) {
  return service(tiers).previewGroup({ query: async () => ({ rows }) }, {
    userId: 'player', venueId: 'venue', slotIds: rows.map(row => row.id),
  });
}

test('two database slot rows quote PKR 3200 with the correct dates and time range', async () => {
  const result = await quote([slot('later', '18:00:00', '19:00:00'), slot('first', '17:00:00', '18:00:00')]);
  assert.equal(result.ok, true);
  assert.equal(result.data.total, 3200);
  assert.equal(result.data.runCount, 1);
  const run = result.data.runs[0];
  assert.equal(run.from, '17:00:00');
  assert.equal(run.to, '19:00:00');
  assert.equal(run.slots[0].date, '2026-10-21');
  assert.equal(run.slots[0].id, 'first');
});

test('discounts apply per contiguous run and preserve slot details after normalization', async () => {
  const result = await quote([
    slot('one', '09:00:00', '10:00:00'), slot('two', '10:00:00', '11:00:00'),
    slot('three', '17:00:00', '18:00:00'),
  ], [{ min_slots: 2, percent: 10 }]);
  assert.equal(result.data.runCount, 2);
  assert.equal(result.data.total, 4480);
  assert.equal(result.data.saved, 320);
  assert.equal(result.data.runs[0].discountPercent, 10);
  assert.equal(result.data.runs[1].discountPercent, 0);
  assert.equal(result.data.runs[1].from, '17:00:00');
});

test('quoting rejects booked slots and another player checkout hold', async () => {
  for (const extra of [{ status: 'booked' }, { held_by_other: true }]) {
    const result = await quote([
      slot('one', '17:00:00', '18:00:00'), slot('two', '18:00:00', '19:00:00', extra),
    ]);
    assert.equal(result.status, 409);
    assert.equal(result.code, 'slot_taken');
  }
});
