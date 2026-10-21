const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function routes(query) {
  const handlers = new Map();
  const router = { get(route, ...chain) { handlers.set(route, chain); } };
  const filename = path.join(__dirname, '../src/routes/adminOverview.js');
  vm.runInNewContext(fs.readFileSync(filename, 'utf8'), {
    module: { exports: {} },
    require(name) {
      if (name === 'express') return { Router: () => router };
      if (name === '../db/pool') return { query };
      return require(path.resolve(path.dirname(filename), name));
    },
  }, { filename });
  return handlers;
}

async function invoke(chain, query = {}, user = { isSuperAdmin: true }) {
  let status = 200;
  let body;
  const res = {
    status(value) { status = value; return this; },
    json(value) { body = value; },
  };
  let allowed = false;
  chain[0]({ user }, res, () => { allowed = true; });
  if (allowed) await chain[1]({ user, query }, res, (error) => { throw error; });
  return { status, body };
}

test('each overview list requires its management permission', async () => {
  let calls = 0;
  const handlers = routes(async () => { calls++; return { rows: [] }; });
  for (const [route, permission] of [
    ['/venues/active', 'owner_approvals'],
    ['/bookings/active', 'booking_disputes'],
  ]) {
    assert.equal((await invoke(handlers.get(route), {}, { permissions: [] })).status, 403);
    assert.equal(calls, route === '/venues/active' ? 0 : 1);
    const allowed = await invoke(handlers.get(route), {}, { permissions: [permission] });
    assert.equal(allowed.status, 200);
    assert.equal(allowed.body.data.items.length, 0);
  }
});

test('lists match dashboard filters and use bounded queries', async () => {
  const queries = [];
  const handlers = routes(async (sql, params) => { queries.push({ sql, params }); return { rows: [] }; });
  await invoke(handlers.get('/venues/active'), { limit: '100000' });
  await invoke(handlers.get('/bookings/active'));
  assert.match(queries[0].sql, /v\.is_active = true/);
  assert.equal(queries[0].params[0], 51);
  assert.match(queries[1].sql, /b\.status IN \('pending', 'confirmed', 'checked_in'\)/);
  assert.match(queries[1].sql, /LEFT JOIN venues/);
  assert.equal(queries[1].params[0], 26);
});

test('cursor keeps timestamp precision, carries the last visible row and binds parameters', async () => {
  const id = '00000000-0000-4000-8000-000000000001';
  const time = '2026-10-21 10:30:00.123456+00';
  let params;
  let sql;
  const handlers = routes(async (query, values) => {
    sql = query;
    params = values;
    return { rows: [{ id, cursor_time: time, name: 'First' }, { id: 'extra' }] };
  });
  const result = await invoke(handlers.get('/venues/active'), { limit: '1', cursor: `${time}~${id}` });
  assert.equal(result.body.data.items.length, 1);
  assert.equal(result.body.data.items[0].cursor_time, undefined);
  assert.equal(result.body.data.nextCursor, `${time}~${id}`);
  assert.equal(params[0], time);
  assert.equal(params[1], id);
  assert.equal(params[2], 2);
  assert.match(sql, /\(v\.created_at, v\.id\) < \(\$1::timestamptz, \$2::uuid\)/);
});

test('invalid cursors never query the database', async () => {
  const handlers = routes(async () => { throw new Error('Unexpected query'); });
  for (const cursor of ['bad', 'not-a-date~00000000-0000-4000-8000-000000000001', "2026-10-21~' OR true"]) {
    const result = await invoke(handlers.get('/venues/active'), { cursor });
    assert.equal(result.status, 400);
  }
});
