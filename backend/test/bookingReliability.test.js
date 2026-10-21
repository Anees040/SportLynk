const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const escrow = require('../src/utils/escrow');

const bookingId = '11111111-1111-4111-8111-111111111111';
const qrCode = '22222222-2222-4222-8222-222222222222';

function setup({ owner = 'owner', status = 'confirmed', failTrust = false } = {}) {
  const handlers = new Map();
  const events = [];
  let released = 0;
  const client = {
    async query(sql, params) {
      events.push({ sql, params });
      if (sql.includes('AS pkt_now')) return { rows: [{ id: bookingId, status, owner_id: owner, pkt_now: '2026-10-21T18:30:00' }] };
      if (sql.includes('b.security_deposit')) return { rows: [{ id: bookingId, player_id: 'player', security_deposit: '2000.00', player_name: 'Player', venue_name: 'Ground', slot_date: '2026-10-21', start_time: '18:00:00', end_time: '19:00:00' }] };
      if (sql.includes('FROM venues WHERE id=')) return { rows: [{ id: 'venue' }] };
      return { rows: [] };
    },
    release() { released++; },
  };
  const router = { use() {}, get() {}, put() {}, post(p, h) { handlers.set(p, h); }, patch(p, h) { handlers.set(p, h); } };
  const filename = path.join(__dirname, '../src/routes/owner.js');
  vm.runInNewContext(fs.readFileSync(filename, 'utf8'), {
    module: { exports: {} },
    require(name) {
      if (name === 'express') return { Router: () => router };
      if (name === '../db/pool') return { connect: async () => client };
      if (name === '../middleware/roleMiddleware') return () => () => {};
      if (name === '../utils/ttlCache') return require('../src/utils/ttlCache');
      if (name === '../utils/globalSettings') return { commission: async () => 0 };
      if (name === '../utils/escrow') return {
        ...escrow,
        lockWallet: async (_, user) => ({ id: user }),
        applyWallet: async () => ({ balance: '12000.50' }),
        logTxn: async () => {},
      };
      if (name === '../utils/trustScore') return {
        recomputeTrust: async (_, user) => {
          events.push({ sql: 'recompute', user });
          if (failTrust) throw new Error('trust update failed');
        },
        emitTrustUpdate: user => events.push({ sql: 'emit', user }),
      };
      return {};
    },
  }, { filename });
  return {
    events,
    async invoke(route, body) {
      let result;
      let error;
      const response = { statusCode: 200, status(code) { this.statusCode = code; return this; }, json(value) { result = value; } };
      await handlers.get(route)({ body, user: { id: 'owner' }, params: { id: 'venue' } }, response, e => { error = e; });
      return { result, error, status: response.statusCode, released };
    },
  };
}

test('manual check-in resolves the booking ID; QR scans still resolve the separate token', async () => {
  for (const body of [{ bookingId }, { qrCode }]) {
    const app = setup();
    const response = await app.invoke('/scan-qr', body);
    assert.ifError(response.error);
    assert.equal(response.result.success, true);
    const lookup = app.events.find(e => e.sql.includes('AS pkt_now'));
    assert.match(lookup.sql, body.bookingId ? /b\.id=\$1::uuid/ : /b\.qr_code=\$1/);
    assert.equal(lookup.params[0], body.bookingId || body.qrCode);
    assert.equal(response.result.data.newOwnerBalance, '12000.50');
    const commit = app.events.findIndex(e => e.sql === 'COMMIT');
    assert.ok(app.events.findIndex(e => e.sql === 'recompute') < commit);
    assert.ok(app.events.findIndex(e => e.sql === 'emit') > commit);
    assert.equal(response.released, 1);
  }
});

test('invalid input releases the connection once without opening a transaction', async () => {
  for (const body of [{}, { bookingId: 'not-a-uuid' }, { bookingId: 'BK123' }, { bookingId: 'BK00012G' }, { qrCode: {} }]) {
    const app = setup();
    const response = await app.invoke('/scan-qr', body);
    assert.ifError(response.error);
    assert.equal(response.status, 400);
    assert.equal(response.released, 1);
    assert.equal(app.events.length, 0);
  }
});

test('short manual codes accept lowercase and separators and use the indexed code lookup', async () => {
  for (const bookingId of ['BK00012A', ' bk00-012a ', 'BK00 012A']) {
    const app = setup();
    const response = await app.invoke('/scan-qr', { bookingId });
    assert.ifError(response.error);
    assert.equal(response.result.success, true);
    const lookup = app.events.find(e => e.sql.includes('AS pkt_now'));
    assert.match(lookup.sql, /b\.checkin_code=\$1/);
    assert.equal(lookup.params[0], 'BK00012A');
  }
});

test('manual check-in preserves ownership and duplicate-check-in protection', async () => {
  for (const identifier of [bookingId, 'BK00012A']) {
    for (const [options, expected] of [[{ owner: 'another-owner' }, 403], [{ status: 'checked_in' }, 409], [{ status: 'cancelled' }, 409]]) {
      const app = setup(options);
      const response = await app.invoke('/scan-qr', { bookingId: identifier });
      assert.equal(response.status, expected);
      assert.ok(!app.events.some(e => e.sql === 'COMMIT' || e.sql === 'emit'));
    }
  }
});

test('failed trust recompute rolls back check-in and emits no premature refresh', async () => {
  const app = setup({ failTrust: true });
  const response = await app.invoke('/scan-qr', { bookingId });
  assert.match(response.error.message, /trust update failed/);
  assert.ok(app.events.some(e => e.sql === 'ROLLBACK'));
  assert.ok(!app.events.some(e => e.sql === 'COMMIT' || e.sql === 'emit'));
});

test('venue saves preserve custom decimal percentages and the default choice', async () => {
  for (const deposit_pct of [0, 20, 35.5, 40, 50, 100, null]) {
    const app = setup();
    const response = await app.invoke('/venues/:id', { deposit_pct });
    assert.ifError(response.error);
    assert.equal(response.result.success, true);
    assert.equal(app.events.find(e => e.sql.startsWith('UPDATE venues')).params[0], deposit_pct);
  }
});
