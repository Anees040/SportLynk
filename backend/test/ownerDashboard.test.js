const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function ownerRoutes(query) {
  const handlers = new Map();
  const router = {
    use() {},
    get(route, handler) { handlers.set(route, handler); },
    post() {},
    patch() {},
    put() {},
  };
  const filename = path.join(__dirname, '../src/routes/owner.js');
  vm.runInNewContext(fs.readFileSync(filename, 'utf8'), {
    module: { exports: {} },
    require(name) {
      if (name === 'express') return { Router: () => router };
      if (name === '../db/pool') return { query };
      if (name === '../middleware/roleMiddleware') return () => () => {};
      if (name === '../utils/ttlCache') return require('../src/utils/ttlCache');
      return {};
    },
  }, { filename });
  return handlers;
}

async function invoke(handler) {
  let body;
  await handler({ user: { id: 'owner-1' } }, {
    json(value) { body = value; },
  }, (error) => { throw error; });
  return body;
}

test('the venue list returns stored descriptions for the management form', async () => {
  const storedVenue = { id: 'venue-1', description: 'Saved floodlights description' };
  let selectedSql;
  const routes = ownerRoutes(async (sql) => {
    if (sql.startsWith('SELECT COUNT(*)')) return { rows: [{ count: '1' }] };
    selectedSql = sql;
    return { rows: [storedVenue] };
  });
  const result = await invoke(routes.get('/venues'));
  assert.match(selectedSql, /v\.description/);
  assert.equal(result.data[0].description, storedVenue.description);
});

test('upcoming bookings exclude ended slots using venue time and preserve overnight play', async () => {
  const queries = [];
  const routes = ownerRoutes(async (sql, params) => {
    queries.push({ sql, params });
    if (sql.startsWith('SELECT COUNT(*)')) return { rows: [{ count: '1' }] };
    return { rows: [] };
  });
  const result = await invoke(routes.get('/dashboard'));
  assert.equal(result.success, true);
  const upcoming = queries.find(({ sql }) => sql.includes('u.name AS player_name'));
  assert.match(upcoming.sql, /b\.slot_date \+ b\.end_time/);
  assert.match(upcoming.sql, /b\.end_time < b\.start_time THEN INTERVAL '1 day'/);
  assert.match(upcoming.sql, /AT TIME ZONE 'Asia\/Karachi' > NOW\(\)/);
  assert.equal(upcoming.params[0], 'owner-1');
  assert.match(upcoming.params[1], /^\d{4}-\d{2}-\d{2}$/);
  assert.match(upcoming.sql, /b\.slot_date >= \$2::DATE - 1/);
});
