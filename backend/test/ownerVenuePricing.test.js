const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const grid = require('../src/utils/slotGrid');

function loadService(db, suggestPrice = async () => ({ suggestedPrice: 2500, source: 'model' })) {
  const filename = path.join(__dirname, '../src/services/slotService.js');
  const module = { exports: {} };
  vm.runInNewContext(fs.readFileSync(filename, 'utf8'), {
    module,
    require(name) {
      if (name === '../db/pool') return db;
      if (name === '../utils/slotGrid') return grid;
      if (name === './mlClient') return { suggestPrice };
      throw new Error(`Unexpected dependency ${name}`);
    },
  }, { filename });
  return module.exports;
}

function setup({ failRestore = false, found = true } = {}) {
  const events = [];
  const handlers = new Map();
  const client = {
    async query(sql, params) {
      events.push({ sql, params });
      if (sql.includes('FROM venues WHERE id=')) return { rows: found ? [{
        id: 'venue', operating_hours_from: '08:00', operating_hours_to: '23:00',
        price_per_hour: 2000, base_price: 2000,
      }] : [] };
      if (sql === grid.RETURN_TO_BASE_PRICE_SQL && failRestore) throw new Error('price write failed');
      return { rows: [], rowCount: 3 };
    },
    release() { events.push({ sql: 'release' }); },
  };
  const pool = { connect: async () => client };
  const slotService = loadService(pool);
  slotService.repriceVenueSlots = async () => { events.push({ sql: 'model' }); };
  slotService.reshapeVenueSlots = async () => {
    events.push({ sql: 'reshape' });
    return { ok: true, window: '08:00–23:00', durationMin: 30, perDay: 30 };
  };
  const router = {
    use() {}, get() {}, post() {}, put() {},
    patch(route, handler) { handlers.set(route, handler); },
  };
  const filename = path.join(__dirname, '../src/routes/owner.js');
  vm.runInNewContext(fs.readFileSync(filename, 'utf8'), {
    module: { exports: {} },
    require(name) {
      if (name === 'express') return { Router: () => router };
      if (name === '../db/pool') return pool;
      if (name === '../middleware/roleMiddleware') return () => () => {};
      if (name === '../utils/ttlCache') return require('../src/utils/ttlCache');
      if (name === '../services/slotService') return slotService;
      return {};
    },
  }, { filename });
  return {
    events,
    async save(body) {
      let result;
      let error;
      const res = {
        statusCode: 200,
        status(code) { this.statusCode = code; return this; },
        json(value) { events.push({ sql: 'response' }); result = value; },
      };
      await handlers.get('/venues/:id')(
        { body, user: { id: 'owner' }, params: { id: 'venue' } }, res, e => { error = e; },
      );
      return { result, error, status: res.statusCode };
    },
  };
}

test('turning AI off restores prices before commit and a successful response', async () => {
  const app = setup();
  const response = await app.save({ ai_pricing_enabled: false, price_per_hour: 2800 });
  assert.ifError(response.error);
  assert.equal(response.result.success, true);
  const order = app.events.map(e => e.sql);
  assert.ok(order.indexOf(grid.RETURN_TO_BASE_PRICE_SQL) > order.indexOf('BEGIN'));
  assert.ok(order.indexOf(grid.RETURN_TO_BASE_PRICE_SQL) < order.indexOf('COMMIT'));
  assert.ok(order.indexOf('COMMIT') < order.indexOf('response'));
  assert.ok(!order.includes('model'));
  assert.equal(order.at(-1), 'release');
});

test('a price restore failure rolls back the venue setting instead of reporting success', async () => {
  const app = setup({ failRestore: true });
  const response = await app.save({ ai_pricing_enabled: false });
  assert.match(response.error.message, /price write failed/);
  assert.equal(response.result, undefined);
  const order = app.events.map(e => e.sql);
  assert.ok(order.includes('ROLLBACK'));
  assert.ok(!order.includes('COMMIT'));
  assert.equal(order.at(-1), 'release');
});

test('price-only edits reconcile the saved mode and switching AI on schedules repricing', async () => {
  for (const body of [{ price_per_hour: 3100 }, { ai_pricing_enabled: true }]) {
    const app = setup();
    const response = await app.save(body);
    assert.ifError(response.error);
    const order = app.events.map(e => e.sql);
    assert.equal(order.includes(grid.RETURN_TO_BASE_PRICE_SQL), 'price_per_hour' in body);
    assert.ok(order.indexOf('model') > order.indexOf('COMMIT'));
  }
});

test('a simultaneous slot-length edit restores prices after reshaping', async () => {
  const app = setup();
  const response = await app.save({ ai_pricing_enabled: false, slot_duration_minutes: 30 });
  assert.ifError(response.error);
  const order = app.events.map(e => e.sql);
  assert.ok(order.indexOf('reshape') < order.indexOf(grid.RETURN_TO_BASE_PRICE_SQL));
  assert.ok(order.indexOf(grid.RETURN_TO_BASE_PRICE_SQL) < order.indexOf('COMMIT'));
});

test('unauthorized venue edits never change prices', async () => {
  const app = setup({ found: false });
  const response = await app.save({ ai_pricing_enabled: false });
  assert.equal(response.status, 404);
  assert.ok(!app.events.some(e => e.sql === 'BEGIN'));
});

test('maintenance reconciles fixed prices without asking the model', async () => {
  const queries = [];
  const service = loadService({ query: async sql => {
    queries.push(sql);
    return { rowCount: 2 };
  } }, () => { throw new Error('AI must not run'); });
  const result = await service.repriceVenueSlots(null, {
    venueId: 'venue', venue: { ai_pricing_enabled: false },
  });
  assert.equal(result.ok, true);
  assert.equal(result.repriced, 2);
  assert.deepEqual(queries, [grid.RETURN_TO_BASE_PRICE_SQL]);
  queries.length = 0;
  await service.repriceVenueSlots(null, {
    venueId: 'venue', venue: { ai_pricing_enabled: false }, dryRun: true,
  });
  assert.equal(queries.length, 0);
});
