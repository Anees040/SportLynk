/**
 * passwordResetService state-machine tests (server-owned OTP for password reset).
 *
 * Run:  npm test          (from backend/),  or  node --test test/passwordReset.test.js
 *
 * These prove the reset state machine with the database off, the way requests.test.js
 * does: every service function takes an open `client`, so a fake client that records its
 * queries and returns canned rows drives each branch. smsService.sendSms is swapped per
 * test so no SMS leaves the process, and the code the service generated is recovered from
 * the captured SMS to prove the stored value is the HMAC of that code — never the code.
 */
process.env.JWT_SECRET = process.env.JWT_SECRET || 'test-secret';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const svc = require('../src/services/passwordResetService');
const sms = require('../src/services/smsService');

const PHONE = '03001234567';
const USER = '11111111-1111-1111-1111-111111111111';

// A fake pg client: records every query, returns whatever the responder yields for a
// matching SQL (or an empty result), and throws when the responder returns an Error.
function mkClient(responder) {
  const calls = [];
  return {
    calls,
    async query(sql, params) {
      calls.push({ sql, params });
      const out = responder ? responder(sql, params) : null;
      if (out instanceof Error) throw out;
      return out || { rows: [] };
    },
  };
}

const ran = (c, re) => c.calls.some((q) => re.test(q.sql));
const callWith = (c, re) => c.calls.find((q) => re.test(q.sql));

// Swap smsService.sendSms for the span of one test, always restoring it.
async function withSms(fake, body) {
  const real = sms.sendSms;
  sms.sendSms = fake;
  try { return await body(); } finally { sms.sendSms = real; }
}

// The responder for a happy send: the user exists, no prior send is on record, and the
// insert succeeds. Individual tests override one branch to exercise a failure.
function sendResponder() {
  return (sql) => {
    if (/FROM users WHERE phone/.test(sql)) return { rows: [{ id: USER }] };
    if (/in_cooldown/.test(sql)) return { rows: [{ in_cooldown: 0, in_window: 0 }] };
    if (/INSERT INTO password_reset_codes/.test(sql)) return { rows: [{ id: 'code-1' }] };
    return null;
  };
}

// ── sendCode ──────────────────────────────────────────────────────────────────────

test('1 — an unknown phone is a 404 and sends no SMS', async () => {
  let smsCalls = 0;
  await withSms(async () => { smsCalls += 1; return { ok: true }; }, async () => {
    const c = mkClient((sql) => (/FROM users WHERE phone/.test(sql) ? { rows: [] } : null));
    const r = await svc.sendCode(c, { phone: PHONE });
    assert.equal(r.status, 404);
    assert.equal(r.ok, false);
    assert.equal(smsCalls, 0);
    assert.ok(!ran(c, /INSERT INTO password_reset_codes/));
  });
});

test('2 — a disabled gateway is a 503 and stores nothing', async () => {
  await withSms(async () => ({ ok: false, disabled: true, reason: 'TEXTBEE_API_KEY is not set' }), async () => {
    const c = mkClient(sendResponder());
    const r = await svc.sendCode(c, { phone: PHONE });
    assert.equal(r.status, 503);
    assert.equal(r.code, 'sms_disabled');
    assert.ok(!ran(c, /INSERT INTO password_reset_codes/));
  });
});

test('3 — a gateway error is a 502 and stores nothing', async () => {
  await withSms(async () => ({ ok: false, error: 'sms gateway returned 401' }), async () => {
    const c = mkClient(sendResponder());
    const r = await svc.sendCode(c, { phone: PHONE });
    assert.equal(r.status, 502);
    assert.equal(r.code, 'sms_failed');
    assert.ok(!ran(c, /INSERT INTO password_reset_codes/));
  });
});

test('4 — a resend inside the cooldown is a 429 and sends no SMS', async () => {
  let smsCalls = 0;
  await withSms(async () => { smsCalls += 1; return { ok: true }; }, async () => {
    const c = mkClient((sql) => {
      if (/FROM users WHERE phone/.test(sql)) return { rows: [{ id: USER }] };
      if (/in_cooldown/.test(sql)) return { rows: [{ in_cooldown: 1, in_window: 1 }] };
      return null;
    });
    const r = await svc.sendCode(c, { phone: PHONE });
    assert.equal(r.status, 429);
    assert.equal(r.code, 'cooldown');
    assert.equal(smsCalls, 0);
    assert.ok(!ran(c, /INSERT INTO password_reset_codes/));
  });
});

test('5 — too many sends in the window is a 429', async () => {
  await withSms(async () => ({ ok: true }), async () => {
    const c = mkClient((sql) => {
      if (/FROM users WHERE phone/.test(sql)) return { rows: [{ id: USER }] };
      if (/in_cooldown/.test(sql)) return { rows: [{ in_cooldown: 0, in_window: 5 }] };
      return null;
    });
    const r = await svc.sendCode(c, { phone: PHONE });
    assert.equal(r.status, 429);
    assert.equal(r.code, 'rate_limited');
  });
});

test('6 — a sent code is stored as its HMAC, never in the clear', async () => {
  let captured = null;
  await withSms(async (phone, message) => { captured = { phone, message }; return { ok: true }; }, async () => {
    const c = mkClient(sendResponder());
    const r = await svc.sendCode(c, { phone: PHONE });
    assert.equal(r.status, 200);
    assert.equal(r.ok, true);

    // Recover the code the service generated from the SMS it asked us to send.
    assert.ok(captured, 'an SMS was sent');
    const m = captured.message.match(/\b(\d{6})\b/);
    assert.ok(m, 'the SMS carries a six-digit code');
    const code = m[1];

    const insert = callWith(c, /INSERT INTO password_reset_codes/);
    assert.ok(insert, 'a row was inserted');
    // The stored column holds the HMAC of the code, not the code itself.
    assert.equal(insert.params[2], svc.hashCode(code));
    assert.notEqual(insert.params[2], code);
    assert.equal(insert.params[0], USER);
    assert.equal(insert.params[1], PHONE);
    assert.ok(!insert.params.includes(code));
  });
});

// ── verifyAndReset ──────────────────────────────────────────────────────────────

const codeRow = (over) => ({
  rows: [{
    id: 'x', user_id: USER, code_hash: svc.hashCode('123456'),
    attempts: 0, consumed_at: null, expired: false, ...over,
  }],
});

test('7 — a password under 8 chars is a 400 before any lookup', async () => {
  const c = mkClient();
  const r = await svc.verifyAndReset(c, { phone: PHONE, code: '123456', newPassword: 'short' });
  assert.equal(r.status, 400);
  assert.equal(r.code, 'weak_password');
  assert.equal(c.calls.length, 0);
});

test('8 — no code row for the phone is a generic invalid', async () => {
  const c = mkClient(() => ({ rows: [] }));
  const r = await svc.verifyAndReset(c, { phone: PHONE, code: '123456', newPassword: 'longenough' });
  assert.equal(r.code, 'invalid_code');
  assert.ok(!ran(c, /UPDATE users/));
});

test('9 — an expired code is invalid and does not reset', async () => {
  const c = mkClient((sql) => (/code_hash/.test(sql) ? codeRow({ expired: true }) : null));
  const r = await svc.verifyAndReset(c, { phone: PHONE, code: '123456', newPassword: 'longenough' });
  assert.equal(r.code, 'invalid_code');
  assert.ok(!ran(c, /UPDATE users/));
});

test('10 — a consumed code is invalid and does not reset', async () => {
  const c = mkClient((sql) => (/code_hash/.test(sql) ? codeRow({ consumed_at: 'yesterday' }) : null));
  const r = await svc.verifyAndReset(c, { phone: PHONE, code: '123456', newPassword: 'longenough' });
  assert.equal(r.code, 'invalid_code');
  assert.ok(!ran(c, /UPDATE users/));
});

test('11 — too many attempts is a 429', async () => {
  const c = mkClient((sql) => (/code_hash/.test(sql) ? codeRow({ attempts: 5 }) : null));
  const r = await svc.verifyAndReset(c, { phone: PHONE, code: '123456', newPassword: 'longenough' });
  assert.equal(r.status, 429);
  assert.equal(r.code, 'too_many_attempts');
  assert.ok(!ran(c, /UPDATE users/));
});

test('12 — a wrong code spends one attempt and does not touch users', async () => {
  const c = mkClient((sql) => (/code_hash/.test(sql)
    ? codeRow({ code_hash: svc.hashCode('654321') })
    : null));
  const r = await svc.verifyAndReset(c, { phone: PHONE, code: '123456', newPassword: 'longenough' });
  assert.equal(r.status, 400);
  assert.equal(r.code, 'invalid_code');
  assert.ok(callWith(c, /SET attempts = attempts \+ 1/), 'the wrong guess is counted');
  assert.ok(!ran(c, /UPDATE users/));
});

test('13 — the right code consumes it and resets the password by user_id', async () => {
  const c = mkClient((sql) => {
    if (/code_hash/.test(sql)) return codeRow({ attempts: 1 });
    if (/UPDATE users/.test(sql)) return { rows: [{ id: USER }] };
    return null;
  });
  const r = await svc.verifyAndReset(c, { phone: PHONE, code: '123456', newPassword: 'longenough' });
  assert.equal(r.status, 200);
  assert.equal(r.ok, true);
  assert.equal(r.data.userId, USER);

  // The used code is consumed, siblings are invalidated, and the password update targets
  // the user_id the code was issued to — not the phone.
  assert.ok(ran(c, /SET consumed_at = now\(\) WHERE id = \$1/));
  assert.ok(ran(c, /consumed_at IS NULL AND id <> \$2/));
  const upd = callWith(c, /UPDATE users SET password_hash/);
  assert.ok(upd);
  assert.equal(upd.params[1], USER);
  assert.ok(!ran(c, /SET attempts = attempts \+ 1/)); // a match spends no attempt
});

// ── static source: invariants behaviour alone cannot pin ──────────────────────────

const SRC = (...p) => fs.readFileSync(path.join(__dirname, '..', ...p), 'utf8');

test('14 — the code is stored only as an HMAC keyed with JWT_SECRET', () => {
  const s = SRC('src', 'services', 'passwordResetService.js');
  assert.ok(s.includes("createHmac('sha256', process.env.JWT_SECRET)"));
  assert.ok(s.includes('(user_id, phone, code_hash, expires_at)'));
});

test('15 — the reset route no longer trusts a client firebaseUid', () => {
  const auth = SRC('src', 'routes', 'auth.js');
  const reset = auth.slice(auth.indexOf("'/forgot-password/reset'"));
  assert.ok(!/firebaseUid/.test(reset), 'firebaseUid is gone from the reset handler');
  assert.ok(reset.includes('verifyAndReset'));
});

test('16 — the migration is additive and stores hash, TTL, cap and single-use', () => {
  const raw = SRC('migrations', '029_password_reset_codes.sql');
  for (const col of ['code_hash', 'expires_at', 'attempts', 'consumed_at']) {
    assert.ok(raw.includes(col), `029 declares ${col}`);
  }
  // Strip SQL comments before the destructive-statement check: the header prose names
  // DROP/TRUNCATE/DELETE precisely to say the body has none of them.
  const sql = raw.replace(/--.*$/gm, '');
  assert.ok(!/DROP\s+TABLE/i.test(sql));
  assert.ok(!/TRUNCATE/i.test(sql));
  assert.ok(!/DELETE\s+FROM/i.test(sql));
});

test('17 — send-otp and reset stay on the public auth router', () => {
  const auth = SRC('src', 'routes', 'auth.js');
  assert.ok(auth.includes("router.post('/forgot-password/send-otp'"));
  assert.ok(auth.includes("router.post('/forgot-password/reset'"));
  assert.ok(!/router\.use\(auth\)/.test(auth)); // forgot-password must work without a token
});
