/**
 * check_assistant_http.js — Scout over real HTTP. The half check_assistant.js cannot reach.
 *
 * Usage:  node src/scripts/check_assistant_http.js        (ml-service must be running)
 *         node src/scripts/check_assistant_http.js --keep  (leave the fixtures behind)
 *
 * Why a second script
 * check_assistant.js is affordable because it calls the services with a client it owns
 * and rolls the whole run back. That is also its blind spot: it never goes through
 * Express, so `router.use(auth)`, the JSON envelope, the four accepted spellings of
 * `session_id`, the opaque message cursor and every status code in the router are
 * asserted nowhere. TESTING.md steps 196, 197 and 200 are that gap written out as
 * curl commands — a page nobody runs twice. This is those three steps as one command.
 *
 * These writes are real, and they are cleaned up
 * There is no transaction to roll back: the server owns its own connections, which is
 * the entire point. So the script keeps a ledger of everything it creates — threads,
 * KB rows, escalations, feedback, notifications — and deletes it in a `finally`, then
 * counts what is left and prints the census. `--keep` skips the delete so the rows
 * can be inspected afterwards.
 *
 * What it deliberately does not do is spend money. It drives the booking flow up to
 * the confirmation card and then denies it, because a real booking over real HTTP
 * against the committee's demo wallet is not a test, it is a purchase. The booking
 * itself is proven by check_assistant.js (rolled back) and check_booking_service.js.
 *
 * What a failure means
 *   x  the HTTP surface disagrees with the services. The line names it.
 *   ~  the data could not supply the case. A skip, counted separately.
 */
const path = require('path');
const { spawn } = require('child_process');
const jwt = require('jsonwebtoken');
const pool = require('../db/pool');
const threadsSvc = require('../services/assistantThreads');
const actions = require('../services/assistantActions');
const ml = require('../services/mlClient');
const evidence = require('./lib/evidence');

const PORT = Number(process.env.PORT) || 3000;
const BASE = (process.env.API_BASE || `http://localhost:${PORT}/api`).replace(/\/+$/, '');
const KEEP = process.argv.includes('--keep');
// Recorded for the evidence pack: a reader must know whether this run brought its own
// server up or borrowed one that was already there.
let SPAWNED = false;

const failures = [];
const skips = [];
const notes = [];
let passed = 0;

// The other half of the pack that check_assistant.js writes: same file, its own block.
// Off unless --evidence is passed. See src/scripts/lib/evidence.js.
const ev = evidence.recorder({
  key: 'http',
  title: 'Block 2 -- the same assistant over real Express, with real JWTs',
  subtitle: 'Nothing here is called directly. Every line below went over HTTP to a listening server '
    + 'through the auth middleware and the rate limiter, so the route projections, the status codes and '
    + 'SEC-6 are exercised rather than argued from source. Residue is deleted in a `finally`, and the '
    + 'last block is the one claim that can only be made AFTER the delete.',
  command: 'cd backend && node src/scripts/check_assistant_http.js --evidence',
});

function section(title) {
  ev.section(title);
  console.log(`\n── ${title} ${'─'.repeat(Math.max(0, 66 - title.length))}`);
}

function check(ok, label, detail = '') {
  if (ok) ev.pass(label); else ev.fail(label, detail);
  if (ok) { passed += 1; console.log(`  ✓ ${label}`); return true; }
  failures.push(label);
  console.log(`  ✗ ${label}${detail ? `  → ${detail}` : ''}`);
  return false;
}

function eq(got, want, label) {
  return check(got === want, label, `got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
}

function skip(label, why) {
  ev.skip(label, why);
  skips.push(label);
  console.log(`  ~ ${label}  (skipped: ${why})`);
  return false;
}

/** Something the reader needs to know that is not itself a pass or a fail. */
function note(line) {
  notes.push(line);
  ev.note(line);
  console.log(`  · ${line}`);
}

/**
 * One HTTP call, and never a throw for a 4xx.
 *
 * A checker that treats a 404 as an exception cannot assert a 404, so every response
 * comes back as `{status, json, text}` and the assertions read it. The body is parsed
 * leniently on purpose: a 500 from Express's default handler is HTML, and the status
 * code is still the thing under test.
 */
async function api(method, p, { token, body, raw } = {}) {
  const headers = {};
  if (token) headers.Authorization = raw ? token : `Bearer ${token}`;
  let payload;
  if (body !== undefined) {
    headers['Content-Type'] = 'application/json';
    payload = JSON.stringify(body);
  }
  const res = await fetch(`${BASE}${p}`, { method, headers, body: payload });
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { json = null; }
  const out = { status: res.status, headers: res.headers, json, text, data: json && json.data };
  // Every turn is recorded here rather than at each call site: there are forty of them,
  // and a transcript that misses the ones somebody forgot to annotate is worse than none.
  if (ev.on && p === '/assistant/message' && out.data && out.data.reply) {
    const n = out.data.nlu || {};
    ev.turn({
      said: body && body.text ? `"${body.text}"` : `[${(body && body.action) || '?'}]`,
      intent: n.intent || null,
      conf: n.confidence != null ? Number(n.confidence).toFixed(4) : null,
      source: `${out.data.reply.source || '-'} (via ${n.via || '-'})`,
      said_back: String(out.data.reply.text || '').slice(0, 90),
    });
  }
  return out;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function serverIsUp() {
  try {
    const res = await api('GET', '/health');
    return res.status === 200;
  } catch { return false; }
}

/**
 * Use the server that is already running; start one if there is not.
 *
 * TESTING.md step 196 says "npm start in one terminal, then curl in another", and the
 * reason those steps were never run is that two terminals is one more than anybody
 * does. If port 3000 already answers /api/health this attaches to it and changes
 * nothing; otherwise it starts src/server.js itself and kills it at the end, so the
 * whole pass is one command either way.
 */
async function ensureServer() {
  if (await serverIsUp()) {
    note(`attached to the server already listening on ${BASE}`);
    return { up: true, spawned: false };
  }
  const root = path.join(__dirname, '..', '..');
  const child = spawn(process.execPath, [path.join('src', 'server.js')], {
    cwd: root, env: process.env, stdio: ['ignore', 'pipe', 'pipe'],
  });
  const log = [];
  const keep = (b) => { log.push(String(b)); if (log.length > 40) log.shift(); };
  child.stdout.on('data', keep);
  child.stderr.on('data', keep);
  let exited = false;
  child.on('exit', (code) => { exited = true; keep(`[server exited ${code}]`); });

  for (let i = 0; i < 60 && !exited; i += 1) {
    await sleep(500);
    if (await serverIsUp()) {
      note(`started src/server.js on port ${PORT} for this run (pid ${child.pid})`);
      global.__scoutChild = child;   // so the finally block can kill what it started
      SPAWNED = true;
      return { up: true, spawned: true };
    }
  }
  console.log(`\n  the server never answered ${BASE}/health. Its output:\n`);
  console.log(log.join('').split('\n').slice(-16).map((l) => `    ${l}`).join('\n'));
  try { child.kill(); } catch { /* already dead */ }
  return { up: false, spawned: true };
}

// FIXTURES and tokens

/**
 * Chosen from the real database, never inserted — same rule as check_assistant.js.
 * Two players (the second one exists only to be a stranger), the owner who actually
 * owns venues, and a second owner who owns none: an isolation check needs somebody to
 * be excluded, and "sees an empty queue" is the exclusion.
 */
async function pickCast() {
  const q = async (sql, args) => (await pool.query(sql, args)).rows;
  const players = await q(
    `SELECT u.id, u.name, u.email, u.phone FROM users u
      WHERE u.role = 'player' AND u.is_active
      ORDER BY (u.email IS NULL), u.created_at LIMIT 4`,
  );
  const owners = await q(
    `SELECT u.id, u.name, u.email, u.phone,
            (SELECT count(*)::int FROM venues v WHERE v.owner_id = u.id) AS venues
       FROM users u LEFT JOIN owner_profiles op ON op.user_id = u.id
      WHERE u.role = 'owner' AND u.is_active
        AND (op.verification_status = 'approved' OR op.verification_status IS NULL)
      ORDER BY (SELECT count(*) FROM venues v WHERE v.owner_id = u.id) DESC LIMIT 4`,
  );
  const owner = owners.find((o) => o.venues > 0) || null;
  const venue = owner ? (await q(
    `SELECT v.id, v.name, v.city, v.sport_type FROM venues v
      WHERE v.owner_id = $1 AND v.is_active ORDER BY v.name LIMIT 1`, [owner.id]))[0] : null;
  return {
    player: players[0] || null,
    stranger: players.find((p) => players[0] && p.id !== players[0].id) || null,
    owner,
    otherOwner: owners.find((o) => owner && o.id !== owner.id) || null,
    venue,
  };
}

const SEED_PASSWORD = process.env.CHECK_HTTP_PASSWORD || 'password123';

/** The token the app itself would issue: same claims as routes/auth.js line 182. */
function mint(user, { expiresIn = '2h' } = {}) {
  return jwt.sign({ id: user.id, role: user.role || null, phone: user.phone || null },
    process.env.JWT_SECRET, { expiresIn });
}

/**
 * A token for a cast member, through the front door when the front door opens.
 *
 * Step 196 starts with "TOKEN=<login as the demo player>", so the login is attempted
 * first and reported. But a database that has outgrown seed.js has no password this
 * script can know, and refusing to test 16 endpoints over a password is the wrong
 * trade: the fallback mints the same claims with the same secret, which traverses the
 * same authMiddleware. Which path was taken is printed, never guessed at.
 */
async function tokenFor(user, role) {
  const who = { ...user, role };
  const identifier = user.email || user.phone;
  if (identifier) {
    const res = await api('POST', '/auth/login', { body: { identifier, password: SEED_PASSWORD } });
    if (res.status === 200 && res.data && res.data.token) {
      return { token: res.data.token, via: 'login', user: who };
    }
  }
  return { token: mint(who), via: 'minted', user: who };
}

// The ledger — everything this run creates, so the finally block can undo it
//
// Migration 018 does most of the work: deleting a thread CASCADEs its messages and
// their feedback. What it does not take with it is the escalation (channel_id is on
// DELETE SET NULL, deliberately — the telemetry outlives the conversation) or the KB
// row it produced, so those two are deleted explicitly and by id.
const made = { threads: [], kb: [], escalations: [], notifications: [] };

/** What the post-cleanup census needs, since it runs in the finally block. */
const runCtx = { uid: null, ranAt: null, turns: 0 };

async function cleanup() {
  if (KEEP) {
    console.log(`\n  --keep: leaving ${made.threads.length} thread(s), `
      + `${made.kb.length} KB row(s) and ${made.escalations.length} escalation(s) behind.`);
    for (const t of made.threads) console.log(`    thread   ${t.id}`);
    for (const id of made.kb) console.log(`    kb       ${id}`);
    for (const id of made.escalations) console.log(`    escalate ${id}`);
    return { threads: made.threads.length, kb: made.kb.length, esc: made.escalations.length };
  }
  let gone = 0;
  for (const id of made.kb) {
    await pool.query('DELETE FROM assistant_kb WHERE id = $1', [id]).then(() => { gone += 1; })
      .catch(() => {});
  }
  for (const id of made.escalations) {
    await pool.query('DELETE FROM assistant_escalations WHERE id = $1', [id])
      .then(() => { gone += 1; }).catch(() => {});
  }
  for (const key of made.notifications) {
    await pool.query(
      `DELETE FROM notifications WHERE type = ANY($1::text[]) AND payload->>$2 = $3`,
      [['assistant_question', 'assistant_answer', 'assistant_declined'], key.field, key.value],
    ).then(() => { gone += 1; }).catch(() => {});
  }
  for (const t of made.threads) {
    const res = await api('DELETE', `/assistant/threads/${t.id}`, { token: t.token });
    if (res.status === 200) gone += 1;
    else await pool.query('DELETE FROM chat_channels WHERE id = $1', [t.id]).catch(() => {});
  }
  return { gone };
}

// 0 — Preflight

async function preflight(cast) {
  section('0  preflight — the server, the model, and a cast to act with');
  const h = await api('GET', '/health');
  eq(h.status, 200, `GET /api/health answers 200 (${(h.json && h.json.message) || '?'})`);

  const nlu = await ml.assertNluLabels(actions.intentLabels());
  const hard = nlu.ok && nlu.reachable && nlu.modelStatus === 'ready';
  check(hard, `model #4 reachable and agrees on all labels (${nlu.modelVersion}, threshold ${nlu.threshold})`,
    JSON.stringify({ unroutable: nlu.unroutable, stale: nlu.stale, status: nlu.modelStatus }));
  if (!hard) {
    console.log('\n  ml-service is not serving intents-v2. Start it and re-run:');
    console.log('    cd ml-service && python -m uvicorn app.main:app --port 8000\n');
    return false;
  }
  check(!!cast.player, 'there is an active player to be');
  check(!!cast.stranger, 'and a second one to be a stranger to them');
  check(!!(cast.owner && cast.venue),
    `and an owner with a ground (${cast.owner ? cast.owner.name : '-'} / ${cast.venue ? cast.venue.name : '-'})`);
  if (ev.on) {
    ev.addMeta('transport', `${BASE} · ${SPAWNED ? 'this run started src/server.js itself'
      : 'attached to a server that was already listening'} · real JWTs signed with the real secret`);
    ev.addMeta('model #4 (intent NLU)', `${nlu.modelVersion} · threshold ${nlu.threshold}`);
    ev.addMeta('endpoints exercised', '16 assistant routes · TESTING.md 4.20 steps 196 / 197 / 200');
    ev.addMeta('cast', `${cast.player ? cast.player.name : '-'} (player)`
      + ` · ${cast.stranger ? cast.stranger.name : '-'} (stranger)`
      + ` · ${cast.owner ? cast.owner.name : '-'} (owner of ${cast.venue ? cast.venue.name : '-'})`);
  }
  return !!(cast.player && cast.stranger);
}

// A — the door  (testing.md step 197, first sentence)

/**
 * `router.use(auth)` is one line, and the claim it makes is about all sixteen
 * endpoints. So all sixteen are asked without a token, by method and path, rather
 * than one of them being asked and the other fifteen being assumed. The ids in the
 * paths are random uuids: auth runs before any handler, so a 401 here also proves
 * nothing downstream got a chance to look at them.
 */
const ENDPOINTS = [
  ['POST', '/assistant/message'],
  ['GET', '/assistant/threads'],
  ['POST', '/assistant/threads'],
  ['GET', '/assistant/threads/00000000-0000-4000-8000-000000000001/messages'],
  ['PATCH', '/assistant/threads/00000000-0000-4000-8000-000000000001'],
  ['DELETE', '/assistant/threads/00000000-0000-4000-8000-000000000001'],
  ['POST', '/assistant/messages/00000000-0000-4000-8000-000000000001/feedback'],
  ['GET', '/assistant/capabilities'],
];

const OWNER_ENDPOINTS = [
  ['GET', '/assistant/owner/questions'],
  ['POST', '/assistant/owner/questions/00000000-0000-4000-8000-000000000001/answer'],
  ['POST', '/assistant/owner/questions/00000000-0000-4000-8000-000000000001/decline'],
  ['GET', '/assistant/owner/kb'],
  ['POST', '/assistant/owner/kb'],
  ['PATCH', '/assistant/owner/kb/00000000-0000-4000-8000-000000000001'],
  ['DELETE', '/assistant/owner/kb/00000000-0000-4000-8000-000000000001'],
  ['GET', '/assistant/owner/stats'],
];

async function sectionA(cast) {
  section('A  the door — four bad headers, then all sixteen with none at all');
  // Order matters, and the reason is SEC-6. The anonymous quota is 20 requests per
  // minute per IP, and a token that fails to verify counts as anonymous (rateLimit.js
  // identifyUser), so every request in this section lands in that one bucket: 4 bad
  // headers + 16 endpoints = exactly 20. The first run of this script did the logins
  // first and the four message assertions came back 429 instead of 401 — the door was
  // shut, but by the wrong doorman. So the cast's tokens are minted here (an
  // authenticated request is counted per user, in a different bucket at 100/min) and
  // the real logins happen after the quota is deliberately spent and waited out.
  const cases = [
    ['a header with no scheme', 'abcdef', 'Token format: Bearer <token>'],
    ['the wrong scheme', 'Basic abcdef', 'Token format: Bearer <token>'],
    ['a forged token', 'Bearer not.a.real.token', 'Unauthorized'],
    ['an EXPIRED token', `Bearer ${mint({ ...cast.player, role: 'player' }, { expiresIn: -60 })}`,
      'Token expired. Please log in again.'],
  ];
  for (const [label, header, message] of cases) {
    const res = await api('POST', '/assistant/message',
      { token: header, raw: true, body: { text: 'hello' } });
    eq(res.status, 401, `${label} → 401`);
    eq(res.json && res.json.message, message, `and says why, in words a screen can show: "${message}"`);
  }

  const all = [...ENDPOINTS, ...OWNER_ENDPOINTS];
  eq(all.length, 16, 'the surface under test is all 16 endpoints of routes/assistant.js');
  const wrong = [];
  for (const [method, p] of all) {
    const res = await api(method, p);
    if (res.status !== 401) wrong.push(`${method} ${p} → ${res.status}`);
  }
  check(wrong.length === 0, 'all 16 answer 401 with no Authorization header — one router.use(auth)',
    wrong.join('; '));

  const good = await api('GET', '/assistant/capabilities',
    { token: mint({ ...cast.player, role: 'player' }) });
  eq(good.status, 200, 'a real token opens the same door (counted per user, not per IP)');
}

/**
 * A2 — SEC-6, which nothing else in the suite can reach.
 *
 * Twenty anonymous requests have just been spent, so the twenty-first is the quota
 * itself. It is asserted here rather than dodged: a limiter that answers 429 without
 * saying when to come back is a client that retries in a loop, and the draft-7 headers
 * are the contract Flutter's interceptor needs. Then the window is waited out, because
 * the logins in step 196 are anonymous too and a minted-token fallback would quietly
 * weaken the evidence for "log in as the demo player".
 */
async function sectionA2() {
  section('A2 the anonymous quota — SEC-6, over the wire');
  const res = await api('GET', '/assistant/capabilities');
  if (res.status !== 429) {
    skip('the anonymous quota', `request 21 answered ${res.status}, so the bucket was not full`);
    return;
  }
  eq(res.json && res.json.message, 'Too many requests. Please slow down and try again in a minute.',
    'the 21st anonymous request in a minute → 429, in the same envelope as every other error');
  const policy = res.headers && res.headers.get('ratelimit-policy');
  eq(policy, '20;w=60', 'and publishes the policy it enforced (20 per 60s), so a client need not guess');
  const retry = Number((res.headers && res.headers.get('retry-after')) || 0);
  check(retry > 0 && retry <= 60, `and Retry-After says when to come back (${retry}s)`);
  ev.addFact('SEC-6 is enforced on the assistant routes, and says so',
    `Request 21 from one IP inside the window was refused 429 with the exact sentence a client shows, `
    + `\`RateLimit-Policy: ${policy}\`, and \`Retry-After: ${retry}\`. Found by a FAILING assertion: `
    + `four bad-header cases came back 429 instead of 401 because the logins above them had already `
    + `spent the anonymous quota.`);
  const wait = Math.min(retry + 2, 62);
  console.log(`     waiting ${wait}s for the window to clear so the logins below are real …`);
  await sleep(wait * 1000);
  note(`spent the anonymous quota on purpose and waited ${wait}s for it to reset`);
}

// B — A real turn over real HTTP  (step 196's first curl, plus the milestone line)

async function sectionB(cast, tok) {
  section('B  a turn through Express — the envelope, the cards, the parse');
  const sport = String(cast.venue ? cast.venue.sport_type : 'football');
  const city = String(cast.venue ? cast.venue.city : 'Islamabad');
  const t = tok.player.token;

  const r1 = await api('POST', '/assistant/message',
    { token: t, body: { text: `${city.toLowerCase()} mein ${sport} ground chahiye` } });
  eq(r1.status, 200, `POST /message "${city} mein ${sport} ground chahiye" → 200`);
  check(r1.json && r1.json.success === true, 'in the {success, data} envelope every Flutter screen parses');
  const d = r1.data || {};
  check(typeof d.threadId === 'string' && d.threadId.length === 36,
    `and it names the chat it landed in (${d.threadId})`);
  if (d.threadId) made.threads.push({ id: d.threadId, token: t });
  eq(d.threadCreated, true, 'which it created, because the request named none');
  eq(d.nlu && d.nlu.intent, 'find_venue', 'model #4 read it as find_venue over the wire');
  check(typeof (d.nlu && d.nlu.confidence) === 'number',
    `with a confidence the client can show (${d.nlu && d.nlu.confidence})`);
  const cards = (d.reply && d.reply.cards) || [];
  check(cards.length > 0 && cards.every((c) => c.type === 'venue'),
    `${cards.length} venue cards came back`, JSON.stringify(cards.map((c) => c.type)));
  check(['live', 'model'].includes(d.reply && d.reply.source),
    `sourced honestly (${d.reply && d.reply.source})`);
  check((d.reply.chips || []).length > 0, 'and every reply ships chips — no free-text dead end');
  check(d.state && typeof d.state.fsm === 'string', `the FSM state comes back for the client (${d.state && d.state.fsm})`);
  check(typeof d.messageId === 'string', 'and the message id a thumbs-up needs');
  return { thread: d.threadId, messageId: d.messageId };
}

/**
 * The two utterances the milestone checklist names, over HTTP rather than in-process.
 *
 * "kal shaam football islamabad" is the one that used to abstain: it is a verbless
 * search-box query, and until Wave E added slots-only templates to find_venue the
 * corpus had never shown the model one. It is asserted here because a checklist line
 * that only passes when called as a function is not a demo.
 */
async function sectionB2(cast, tok, ctx) {
  section('B2 the milestone utterances — Roman Urdu in, real data out');
  const t = tok.player.token;
  const ask = (text) => api('POST', '/assistant/message',
    { token: t, body: { text, session_id: ctx.thread } });

  const kal = await ask('kal shaam football islamabad');
  eq(kal.status, 200, 'POST /message "kal shaam football islamabad" → 200');
  eq(kal.data.nlu && kal.data.nlu.intent, 'find_venue',
    `the keyword query is read as find_venue (${kal.data.nlu && kal.data.nlu.confidence})`);
  check(((kal.data.reply && kal.data.reply.cards) || []).length > 0
    || /no .* ground|nothing|koi/i.test((kal.data.reply || {}).text || ''),
    'and it answers with grounds or an honest empty-handed sentence',
    (kal.data.reply || {}).text);
  const slots = (kal.data.state && kal.data.state.slots) || {};
  check(String(slots.sport || '').toLowerCase() === 'football',
    `the sport survived the parse (${JSON.stringify(slots.sport)})`);
  check(!!slots.date, `and "kal" resolved to a date, in PKT (${slots.date})`);

  const pizza = await ask('order me a pizza');
  eq(pizza.status, 200, 'POST /message "order me a pizza" → 200, not a 400');
  eq(pizza.data.nlu && pizza.data.nlu.intent, 'out_of_scope', 'the model calls it out of scope itself');
  eq(pizza.data.reply && pizza.data.reply.source, 'menu',
    'and Scout answers with the capability menu rather than an apology');
  check(((pizza.data.reply && pizza.data.reply.chips) || []).length >= 3,
    'the menu offers what it CAN do, as buttons');
  check(!/sorry|cannot help|error/i.test((pizza.data.reply || {}).text || ''),
    `a graceful decline, not a failure: "${(pizza.data.reply || {}).text.slice(0, 64)}"`);
}

// C — the four body rules  (step 196's "four things to check while you are in here")

// team_stats and not my_elo: SportLynk rates teams, so my_elo is not an action and an
// entry for it would be an allowlist line that can never match.
const SAFE_CHIPS = new Set(['capability_menu', 'my_bookings', 'wallet_balance', 'team_stats',
  'tournament_list', 'venue_info', 'check_availability', 'find_venue', 'find_teams',
  'refund_policy', 'help_booking']);

async function sectionC(cast, tok, ctx) {
  section('C  the request body — four spellings, one omission, a chip, a cursor');
  const t = tok.player.token;
  const spellings = ['session_id', 'sessionId', 'threadId', 'thread_id'];
  const landed = [];
  for (const key of spellings) {
    const res = await api('POST', '/assistant/message',
      { token: t, body: { text: 'wallet mein kitna hai', [key]: ctx.thread } });
    landed.push(res.data && res.data.threadId);
  }
  check(landed.every((id) => id === ctx.thread),
    'all four spellings of the chat id land in the SAME chat — Wave D cannot 400 over a naming preference',
    JSON.stringify(landed));

  const before = await api('GET', '/assistant/threads', { token: t });
  const bare = await api('POST', '/assistant/message', { token: t, body: { text: 'my bookings' } });
  eq(bare.status, 200, 'omitting the chat id entirely is legal');
  eq(bare.data.threadCreated, false, 'and means "the newest chat", not "a new one"');
  const after = await api('GET', '/assistant/threads', { token: t });
  eq((after.data.threads || []).length, (before.data.threads || []).length,
    'so the drawer did not grow a thread behind the user');

  const menu = await api('GET', '/assistant/capabilities', { token: t });
  const chip = ((menu.data.menu || {}).chips || []).find((c) => SAFE_CHIPS.has(c.action));
  if (!chip) skip('a chip posted with no text', 'the capability menu offered no read-only chip');
  else {
    const tapped = await api('POST', '/assistant/message',
      { token: t, body: { action: chip.action, args: chip.args || {}, session_id: ctx.thread } });
    eq(tapped.status, 200, `a tapped chip posts {action:"${chip.action}"} with NO text → 200`);
    // The nlu block is present on a chip turn -- it has to be, because `intent` is what
    // the client shows and what telemetry files the turn under. What must be absent is
    // the pair that could enter a measurement: a confidence and a model version. A chip
    // is a certainty, so both are NULL and `via` names the door it came through. This is
    // the same invariant the lexicon path has, checked here over the wire.
    const cn = tapped.data.nlu || {};
    eq(cn.via, 'chip', 'and the parse block says the answer came from a BUTTON');
    check(cn.confidence === null && cn.modelVersion === null,
      'carrying no confidence and no model version — a tap must not enter measured accuracy',
      JSON.stringify({ confidence: cn.confidence, modelVersion: cn.modelVersion }));
    eq(cn.intent, chip.action, 'while still naming the intent the button stands for');
    check(!!(tapped.data.reply && tapped.data.reply.text), 'while still answering with a real bubble');
  }
}

/**
 * The cursor is an opaque row tuple, not a page number.
 *
 * `created_at` is truncated to the millisecond by node-postgres, so two messages
 * written in the same millisecond cannot be ordered by a timestamp alone — which is
 * why the cursor carries an id and why passing it back verbatim is the contract. Two
 * pages that overlap or skip a row would both still "work" on a screen, quietly.
 */
async function sectionC2(cast, tok, ctx) {
  section('C2 the transcript cursor — verbatim, or it silently drops a message');
  const t = tok.player.token;
  const p1 = await api('GET', `/assistant/threads/${ctx.thread}/messages?limit=3`, { token: t });
  eq(p1.status, 200, 'GET /threads/:id/messages?limit=3 → 200');
  const m1 = (p1.data && p1.data.messages) || [];
  eq(m1.length, 3, 'a page of exactly the size asked for');
  check(p1.data.hasMore === true, 'and it says there is more, because there is');
  check(typeof p1.data.cursor === 'string' && p1.data.cursor.length === 36,
    `the cursor is a row id, not an offset (${p1.data.cursor})`);
  check(m1.every((m) => ['user', 'scout'].includes(m.role)),
    'every message names who said it, oldest first within the page');

  const p2 = await api('GET',
    `/assistant/threads/${ctx.thread}/messages?limit=3&before=${p1.data.cursor}`, { token: t });
  eq(p2.status, 200, 'passing that cursor back verbatim → 200');
  const m2 = (p2.data && p2.data.messages) || [];
  const ids1 = new Set(m1.map((m) => m.id));
  check(m2.length > 0 && m2.every((m) => !ids1.has(m.id)),
    `the older page shares no row with the newer one (${m2.length} more)`);
  const bad = await api('GET', `/assistant/threads/${ctx.thread}/messages?before=page-2`,
    { token: t });
  eq(bad.status, 200, 'a cursor somebody hand-edited does not 500');
  check(((bad.data && bad.data.messages) || []).length > 0,
    'it is ignored and the newest page comes back — a garbage cursor must not empty the screen');
  check(!!(p1.data.thread && p1.data.thread.id === ctx.thread),
    'and the page names its own thread, so a late response cannot render into the wrong chat');
}

// D — the CHAT list  (new chat, rename, archive, delete, thumbs)

async function sectionD(cast, tok, ctx) {
  section('D  new chat → rename → archive → restore → thumbs → delete');
  const t = tok.player.token;
  const created = await api('POST', '/assistant/threads', { token: t, body: { title: 'HTTP check' } });
  eq(created.status, 201, 'POST /threads → 201 Created, not 200');
  const th = (created.data || {}).thread || {};
  check(!!th.id, `and returns the row (${th.id})`);
  if (th.id) made.threads.push({ id: th.id, token: t });
  eq(th.title, 'HTTP check', 'with the title it was given');

  const list = await api('GET', '/assistant/threads', { token: t });
  check(((list.data || {}).threads || []).some((x) => x.id === th.id), 'the drawer shows it');
  eq((list.data || {}).max, threadsSvc.MAX_THREADS,
    `and tells the client the ceiling (${threadsSvc.MAX_THREADS}) instead of making it guess`);

  const named = await api('PATCH', `/assistant/threads/${th.id}`, { token: t, body: { title: 'Pindi plans' } });
  eq(named.status, 200, 'PATCH {title} renames it');
  eq(((named.data || {}).thread || {}).title, 'Pindi plans', 'to exactly that');
  const empty = await api('PATCH', `/assistant/threads/${th.id}`, { token: t, body: { title: '  ' } });
  eq(empty.status, 400, 'an EMPTY title is a 400, not a silent revert to the default');
  const neither = await api('PATCH', `/assistant/threads/${th.id}`, { token: t, body: {} });
  eq(neither.status, 400, 'and a body with neither title nor archived is a 400');

  const arch = await api('PATCH', `/assistant/threads/${th.id}`, { token: t, body: { archived: true } });
  eq(arch.status, 200, 'PATCH {archived:true} archives it');
  const open = await api('GET', '/assistant/threads', { token: t });
  check(!((open.data || {}).threads || []).some((x) => x.id === th.id), 'the drawer stops showing it');
  const withArch = await api('GET', '/assistant/threads?archived=1', { token: t });
  check(((withArch.data || {}).threads || []).some((x) => x.id === th.id), 'but ?archived=1 finds it');
  await api('PATCH', `/assistant/threads/${th.id}`, { token: t, body: { archived: false } });
  const back = await api('GET', '/assistant/threads', { token: t });
  check(((back.data || {}).threads || []).some((x) => x.id === th.id), 'and restoring puts it back');
  return { spare: th.id };
}

/**
 * The thumbs, and the only column in the schema that can tell a confident hit from a
 * confident miss. A vote must be changeable (a user taps the wrong one) and it must
 * not be stuffable, which is one UNIQUE constraint and one ON CONFLICT DO UPDATE.
 */
async function sectionD2(cast, tok, ctx) {
  section('D2 feedback — changeable, not stuffable, and never on a stranger message');
  const t = tok.player.token;
  if (!ctx.messageId) return skip('the feedback endpoint', 'no assistant message id came back in B');
  const up = await api('POST', `/assistant/messages/${ctx.messageId}/feedback`,
    { token: t, body: { vote: 1 } });
  eq(up.status, 200, 'POST /messages/:id/feedback {vote:1} → 200');
  eq((up.data || {}).vote, 1, 'recorded as a thumbs up');
  const down = await api('POST', `/assistant/messages/${ctx.messageId}/feedback`,
    { token: t, body: { vote: 'down', reason: 'wrong ground' } });
  eq(down.status, 200, 'voting again is a CHANGE of mind, not a second row');
  eq((down.data || {}).vote, -1, 'now a thumbs down');
  eq(String((down.data || {}).feedbackId), String((up.data || {}).feedbackId),
    'and it is the same row — one vote per person per message');
  const nonsense = await api('POST', `/assistant/messages/${ctx.messageId}/feedback`,
    { token: t, body: { vote: 'maybe' } });
  eq(nonsense.status, 400, 'a vote that is neither up nor down is a 400');
  const foreign = await api('POST',
    '/assistant/messages/00000000-0000-4000-8000-000000000009/feedback',
    { token: t, body: { vote: 1 } });
  eq(foreign.status, 404, 'and a message id that is not theirs matches nothing → 404, never a vote');
  const notUuid = await api('POST', '/assistant/messages/7/feedback', { token: t, body: { vote: 1 } });
  eq(notUuid.status, 404, 'a non-uuid message id is a 404, not a 500 from Postgres');
}

// E — somebody else's CHAT  (step 197: 404, never 403, never a leaked title)

/**
 * A 403 on a stranger's thread would confirm the thread exists, which is a fact about
 * another person's account. Every ownership check in this router is inside the SELECT
 * for that reason: a row belonging to somebody else matches nothing, so the answer is 404 and
 * it is the same 404 an invented id gets.
 */
async function sectionE(cast, tok, ctx) {
  section('E  a stranger chat — 404 and nothing else');
  const t = tok.player.token;
  const s = tok.stranger.token;
  const theirs = await api('POST', '/assistant/threads', { token: s, body: { title: 'Not yours' } });
  const tid = ((theirs.data || {}).thread || {}).id;
  if (!tid) return skip('the cross-user checks', 'the second player could not open a chat');
  made.threads.push({ id: tid, token: s });

  const read = await api('GET', `/assistant/threads/${tid}/messages`, { token: t });
  eq(read.status, 404, "GET another player's /threads/:id/messages → 404");
  check(!/Not yours/.test(read.text), 'and the body does not leak their title', read.text.slice(0, 90));
  check(!/403|forbidden|denied/i.test(read.text),
    'nor admits the chat exists by saying "forbidden"', read.text.slice(0, 90));
  const post = await api('POST', '/assistant/message',
    { token: t, body: { text: 'hello', session_id: tid } });
  eq(post.status, 404, "POST /message into another player's chat → 404 thread_not_found");
  const patch = await api('PATCH', `/assistant/threads/${tid}`, { token: t, body: { title: 'mine now' } });
  eq(patch.status, 404, 'and renaming it → 404');
  const del = await api('DELETE', `/assistant/threads/${tid}`, { token: t });
  eq(del.status, 404, 'and deleting it → 404');
  const still = await api('GET', `/assistant/threads/${tid}/messages`, { token: s });
  eq(still.status, 200, 'while its real owner still has it');

  const junk = await api('GET', '/assistant/threads/not-a-uuid/messages', { token: t });
  eq(junk.status, 404, 'a non-uuid thread id is a 404, not a 500 from a failed uuid cast');
  const junkPost = await api('POST', '/assistant/message',
    { token: t, body: { text: 'wallet balance', session_id: 'not-a-uuid' } });
  eq(junkPost.status, 200,
    'but a non-uuid session_id on /message means "no id given" — a bad id must not lock a user out of chatting');
}

// F — too long, and the role gate

/**
 * ParseRequest.text has max_length=500, so a 501-character message is a 422 from
 * FastAPI — and a 422 is not something a chat screen can render. mlClient refuses it
 * before the HTTP call and returns an abstention, so the user gets a bubble.
 */
async function sectionF(cast, tok, ctx) {
  section('F  a 501-character message, and the 500-character boundary');
  const t = tok.player.token;
  const limit = ml.NLU_MAX_TEXT_CHARS;
  eq(limit, 500, 'the parser limit this checks against is 500 chars');

  const over = await api('POST', '/assistant/message',
    { token: t, body: { text: 'a'.repeat(limit + 1), session_id: ctx.thread } });
  eq(over.status, 200, `${limit + 1} chars → 200 with a bubble, never a 422 forwarded to the screen`);
  // routes/assistant.js projects the parse as {intent,confidence,via,abstained,reason,…}
  // -- `reason` over the wire is dialogManager's `abstainReason`. The refusal is decided
  // in mlClient before the HTTP call to FastAPI, which would have answered 422.
  eq(over.data.nlu && over.data.nlu.reason, 'text_too_long', 'the abstention names its reason');
  eq(over.data.nlu && over.data.nlu.abstained, true, 'and says plainly that it abstained');
  eq(over.data.reply && over.data.reply.source, 'menu', 'and the answer is the capability menu');
  check((over.data.nlu || {}).intent === null,
    'no intent was invented for it', JSON.stringify(over.data.nlu && over.data.nlu.intent));

  const at = await api('POST', '/assistant/message',
    { token: t, body: { text: `${'ground '.repeat(70)}chahiye`.slice(0, limit), session_id: ctx.thread } });
  eq(at.status, 200, `exactly ${limit} chars is ACCEPTED and parsed`);
  check((at.data.nlu || {}).reason !== 'text_too_long',
    'the boundary is inclusive — 500 is fine, 501 is not',
    JSON.stringify((at.data.nlu || {}).reason));

  const empty = await api('POST', '/assistant/message', { token: t, body: {} });
  check(empty.status >= 400 && empty.status < 500,
    `a body with neither text nor action is a 4xx (${empty.status}), not a crash`);

  section('F2 the role gate — the owner half is not a player URL');
  const leaks = [];
  for (const [method, p] of OWNER_ENDPOINTS) {
    const res = await api(method, p, { token: t, body: method === 'GET' ? undefined : {} });
    if (res.status !== 403) leaks.push(`${method} ${p} -> ${res.status}`);
  }
  check(leaks.length === 0,
    'all 8 owner endpoints answer 403 Access denied to a player token', leaks.join('; '));
}

// G — the 51st CHAT  (step 197's last sentence)

/**
 * MAX_THREADS is 50 OPEN chats — archived ones do not count, which is why the message
 * says "archive one" rather than "delete one". Reaching it costs 50 real rows, so this
 * runs as the stranger (whose list this script owns) and every row is in the ledger
 * before it is asked for, so a crash mid-fill still cleans up.
 */
async function sectionG(cast, tok) {
  section('G  the 51st chat — a named 409, not a silent 50-chat ceiling');
  const s = tok.stranger.token;
  const cap = threadsSvc.MAX_THREADS;
  const open = (await pool.query(
    `SELECT count(*)::int n FROM chat_channels
      WHERE type = 'assistant' AND created_by = $1 AND archived_at IS NULL`,
    [tok.stranger.user.id])).rows[0].n;
  const need = cap - open;
  if (need < 0) return skip('the thread ceiling', `that account already has ${open} open chats`);
  note(`filling from ${open} open chats to ${cap} (${need} to create)`);
  for (let i = 0; i < need; i += 1) {
    const res = await api('POST', '/assistant/threads', { token: s, body: { title: `cap ${i + 1}` } });
    const id = ((res.data || {}).thread || {}).id;
    if (id) made.threads.push({ id, token: s });
    if (res.status !== 201) return check(false, `filling to the cap stopped at ${i}`, res.text.slice(0, 90));
  }
  const over = await api('POST', '/assistant/threads', { token: s, body: { title: 'the 51st' } });
  eq(over.status, 409, `the ${cap + 1}st chat → 409 Conflict`);
  check(/archive one/i.test((over.json || {}).message || ''),
    `and says what to do about it: "${(over.json || {}).message}"`);
  const id = ((over.data || {}).thread || {}).id;
  check(!id, 'and no row was created for it');
  const arch = made.threads.filter((x) => x.token === s)[0];
  await api('PATCH', `/assistant/threads/${arch.id}`, { token: s, body: { archived: true } });
  const now = await api('POST', '/assistant/threads', { token: s, body: { title: 'after archiving' } });
  eq(now.status, 201, 'archiving one frees the slot — the ceiling counts OPEN chats, as the message claims');
  const freed = ((now.data || {}).thread || {}).id;
  if (freed) made.threads.push({ id: freed, token: s });
}

// H — GET /capabilities  (ER2.6 as data, so two screens cannot disagree)

async function sectionH(cast, tok) {
  section('H  the capability list — one source for the help sheet and the abstain menu');
  const res = await api('GET', '/assistant/capabilities', { token: tok.player.token });
  eq(res.status, 200, 'GET /capabilities → 200');
  const d = res.data || {};
  const caps = d.capabilities || [];
  check(caps.length > 0 && caps.every((c) => c.action && c.label && c.group && c.gloss),
    `${caps.length} capabilities, each with an action, a label, a group and a sentence`);
  const labels = actions.intentLabels();
  eq((d.actions || []).length, labels.length,
    `and the routable action list the client can trust (${labels.length} labels)`);
  check((d.actions || []).every((a) => labels.includes(a)),
    'every entry is a label the registry really routes');
  const unroutable = caps.filter((c) => !labels.includes(c.action) && !actions.isAction(c.action));
  check(unroutable.length === 0,
    'no capability advertises a button that would 400 when tapped',
    unroutable.map((c) => c.action).join(','));
  eq((d.menu || {}).source, 'menu', 'the menu payload is sourced as menu, not as an answer');
  check(((d.menu || {}).chips || []).length >= 3,
    `and ships ${((d.menu || {}).chips || []).length} chips, so the abstain reply and the help sheet agree`);
  const groups = [...new Set(caps.map((c) => c.group))];
  check(groups.length >= 3, `grouped for rendering (${groups.join(' · ')})`);
}

// I — the owner side  (testing.md step 200, the wave's most demo-able feature)

/**
 * A player asks something no query can answer; the owner answers it once; every later
 * asker is served from the knowledge base with `source: 'kb'` and the owner is never
 * disturbed again. That round trip is the whole learning loop, and this is it over
 * HTTP, across four different tokens.
 *
 * The question carries a run tag so it cannot collide with a KB row that already
 * exists — a "hit" from somebody else's answer would pass this section for the wrong
 * reason.
 */
async function sectionI(cast, tok, ctx) {
  section('I  escalate → the owner answers → the next ask is free (source: kb)');
  if (!cast.venue || !tok.owner) return skip('the owner round trip', 'no owner with a venue');
  const t = tok.player.token;
  const o = tok.owner.token;
  const tag = String(Date.now()).slice(-8);
  const question = `floodlights kaam karte hain check ${tag}`;
  const answerText = `Yes — four floodlight towers, night slots until 2am. (check ${tag})`;

  const e1 = await api('POST', '/assistant/message', { token: t,
    body: { action: 'contact_owner', args: { venueId: cast.venue.id, question }, session_id: ctx.thread } });
  eq(e1.status, 200, 'the player asks the owner a question → 200');
  eq(e1.data.reply && e1.data.reply.source, 'escalated', 'sourced as escalated, not answered');
  const escId = e1.data.reply && e1.data.reply.meta && e1.data.reply.meta.escalationId;
  if (!check(!!escId, `and the reply carries the queue id (${escId})`)) return;
  made.escalations.push(escId);
  made.notifications.push({ field: 'escalationId', value: String(escId) });
  eq(e1.data.reply.meta.notified, true, 'and the owner is notified there is a question waiting');

  const queue = await api('GET', '/assistant/owner/questions', { token: o });
  eq(queue.status, 200, "GET /owner/questions as the ground's owner → 200");
  const mine = ((queue.data || {}).questions || []).find((q) => String(q.id) === String(escId));
  check(!!mine, `the question is in THEIR queue (${((queue.data || {}).questions || []).length} open)`);
  if (mine) eq(mine.status, 'open', 'marked open');
  check(((queue.data || {}).blockedIntents || []).length > 0,
    'and the response states which intents may never enter the queue — money and policy');
  return { escId, question, answerText };
}

async function sectionI2(cast, tok, ctx, esc) {
  if (!esc || !esc.escId) return null;
  section('I2 the answer — one transaction, delivered into the asker own chat');
  const t = tok.player.token;
  const o = tok.owner.token;
  const other = tok.otherOwner ? tok.otherOwner.token : null;

  if (!other) skip('the cross-owner check', 'there is only one owner account');
  else {
    const theirQueue = await api('GET', '/assistant/owner/questions', { token: other });
    eq(theirQueue.status, 200, 'a DIFFERENT owner may open the queue endpoint');
    check(!((theirQueue.data || {}).questions || []).some((q) => String(q.id) === String(esc.escId)),
      "but does not see a question about somebody else's ground");
    const steal = await api('POST', `/assistant/owner/questions/${esc.escId}/answer`,
      { token: other, body: { answer: 'I will answer for them.' } });
    check(steal.status === 404 || steal.status === 403,
      `and cannot answer it (${steal.status}) — ownership is resolved through venues.owner_id, never from the body`);
  }

  const blank = await api('POST', `/assistant/owner/questions/${esc.escId}/answer`,
    { token: o, body: { answer: '   ' } });
  check(blank.status >= 400 && blank.status < 500,
    `an EMPTY answer is refused (${blank.status}) — a blank KB row would teach Scout to say nothing`);

  const ans = await api('POST', `/assistant/owner/questions/${esc.escId}/answer`,
    { token: o, body: { answer: esc.answerText, publish: true } });
  eq(ans.status, 200, 'the owner answers → 200');
  const kbRow = (ans.data || {}).kb || {};
  if (!check(!!kbRow.id, `and a KB entry is written (${kbRow.id})`)) return null;
  made.kb.push(kbRow.id);
  made.notifications.push({ field: 'kbId', value: String(kbRow.id) });
  eq(kbRow.status, 'published', 'published, not left a draft');
  eq(kbRow.scope, 'venue', 'and scoped to that ONE ground — never applied to other venues');
  eq(kbRow.answer, esc.answerText, 'stored verbatim');
  eq((ans.data || {}).delivered, true, "and DELIVERED into the player's own chat");

  const page = await api('GET', `/assistant/threads/${ctx.thread}/messages?limit=40`, { token: t });
  const posted = ((page.data || {}).messages || [])
    .filter((m) => m.role === 'scout' && String(m.text || '').includes(esc.answerText.slice(0, 24)));
  eq(posted.length, 1, "the answer is a Scout message in the player's transcript");
  if (posted.length) {
    eq((posted[0].payload || {}).source, 'kb',
      'and it re-renders as a KB answer when they scroll back, days later');
  }
  return { kbId: kbRow.id };
}

async function sectionI3(cast, tok, ctx, esc, kb) {
  if (!kb || !kb.kbId) return;
  section('I3 the payoff — the same question, answered free, owner not disturbed');
  const t = tok.player.token;
  const o = tok.owner.token;

  const reuse = await api('POST', '/assistant/message', { token: t,
    body: { action: 'contact_owner', args: { venueId: cast.venue.id, question: esc.question },
      session_id: ctx.thread } });
  eq(reuse.status, 200, 'the player asks the identical question again → 200');
  eq(reuse.data.reply && reuse.data.reply.source, 'kb', 'answered from the knowledge base this time');
  eq(reuse.data.reply && reuse.data.reply.text, esc.answerText, "in the owner's own words");
  eq(String(reuse.data.reply.meta && reuse.data.reply.meta.kbId), String(kb.kbId),
    'from the entry the owner just wrote');
  check(!/asked the owner/i.test((reuse.data.reply || {}).text || ''),
    'and Scout does not pretend to ask again');
  const n = (await pool.query(
    'SELECT count(*)::int n FROM assistant_escalations WHERE venue_id = $1 AND question = $2',
    [cast.venue.id, esc.question])).rows[0].n;
  eq(n, 1, 'there is still exactly ONE queue row for it — the owner is not disturbed twice');

  const list = await api('GET', '/assistant/owner/kb', { token: o });
  eq(list.status, 200, 'GET /owner/kb → 200, the audit view');
  const row = ((list.data || {}).entries || []).find((r) => String(r.id) === String(kb.kbId));
  check(!!row, 'the entry is listed for its owner');
  if (row) {
    check(Number(row.served_count || row.servedCount || 0) >= 1,
      `with the serve counter the wave report quotes (${row.served_count ?? row.servedCount})`);
  }
  const stats = await api('GET', '/assistant/owner/stats', { token: o });
  eq(stats.status, 200, 'GET /owner/stats → 200');
  check(stats.data && typeof stats.data === 'object' && Object.keys(stats.data).length > 0,
    `and reports what Scout has been saying on their behalf (${Object.keys(stats.data || {}).join(', ')})`);
}

async function sectionI4(cast, tok, ctx, kb) {
  section('I4 KB upkeep, a decline that teaches nothing, and policy that never escalates');
  const t = tok.player.token;
  const o = tok.owner.token;

  const pre = await api('POST', '/assistant/owner/kb', { token: o,
    body: { venue_id: cast.venue.id, question: 'parking kahan hai', answer: 'At the back, free.' } });
  check(pre.status === 200 || pre.status === 201,
    `an owner may PRE-EMPT a question instead of waiting to be asked (${pre.status})`);
  const preId = ((pre.data || {}).entry || {}).id;
  if (preId) made.kb.push(preId);
  const noVenue = await api('POST', '/assistant/owner/kb', { token: o,
    body: { question: 'anything', answer: 'anything' } });
  eq(noVenue.status, 400, 'a KB row with no venue is a 400 — an answer with no ground is unservable');

  if (kb && kb.kbId) {
    const edited = await api('PATCH', `/assistant/owner/kb/${kb.kbId}`, { token: o,
      body: { answer: 'Four towers. Night slots run to 2am.' } });
    eq(edited.status, 200, 'PATCH /owner/kb/:id rewrites an answer');
    const retired = await api('PATCH', `/assistant/owner/kb/${kb.kbId}`, { token: o,
      body: { status: 'archived' } });
    eq(retired.status, 200, 'and a status-only body retires one without retyping it');
    const nothing = await api('PATCH', `/assistant/owner/kb/${kb.kbId}`, { token: o, body: {} });
    eq(nothing.status, 400, 'while an empty body is a 400');
  }
  const foreignKb = await api('DELETE', '/assistant/owner/kb/00000000-0000-4000-8000-000000000007',
    { token: o });
  eq(foreignKb.status, 404, "and a KB id that is not theirs → 404, never somebody else's row deleted");

  const tag = String(Date.now()).slice(-8);
  const q2 = `astro turf kab badla tha ${tag}`;
  const e2 = await api('POST', '/assistant/message', { token: t,
    body: { action: 'contact_owner', args: { venueId: cast.venue.id, question: q2 }, session_id: ctx.thread } });
  const id2 = e2.data && e2.data.reply && e2.data.reply.meta && e2.data.reply.meta.escalationId;
  if (!id2) skip('the decline path', 'the second escalation was not accepted');
  else {
    made.escalations.push(id2);
    made.notifications.push({ field: 'escalationId', value: String(id2) });
    const dec = await api('POST', `/assistant/owner/questions/${id2}/decline`,
      { token: o, body: { reason: 'not something I track' } });
    eq(dec.status, 200, 'POST /owner/questions/:id/decline → 200');
    const row = (await pool.query(
      'SELECT status, kb_id FROM assistant_escalations WHERE id = $1', [id2])).rows[0] || {};
    eq(row.status, 'declined', 'the queue row closes as declined');
    eq(row.kb_id, null, 'and writes NO KB entry — a declined question must not teach Scout anything');
  }
}

// J — the money gate, over HTTP  (the rule the whole wave hangs on)

/**
 * USE-6's chain up to the confirmation card, and then not through it.
 *
 * check_assistant.js books for real and rolls back; this script has no transaction, so
 * a booking here would be a purchase from the committee's demo wallet. What it asserts
 * instead is the thing a rollback cannot: that the confirm gate holds over HTTP.
 *
 * "haan lekin 7 baje" — "yes, but 7 o'clock" — parses as `affirm` at 0.6112, above the
 * 0.45 floor. It is a correction, and a model that spends money on it would book the
 * hour the user was fixing. `decisive` is `via === 'chip' || via === 'lexicon'`, so the
 * model's own confident affirm is not a door. That is asserted here through Express,
 * against the real classifier, with a wallet balance read before and after.
 */
async function sectionJ(cast, tok, ctx) {
  section('J  the confirm gate — a confident model affirm may not spend PKR');
  if (!cast.venue) return skip('the money gate', 'no fixture venue');
  const t = tok.player.token;
  const uid = tok.player.user.id;
  const walletOf = async () => (await pool.query(
    'SELECT balance::numeric b, frozen_balance::numeric f FROM wallets WHERE user_id = $1',
    [uid])).rows[0] || { b: 0, f: 0 };
  const bookingsOf = async () => (await pool.query(
    'SELECT count(*)::int n FROM bookings WHERE player_id = $1', [uid])).rows[0].n;
  const w0 = await walletOf();
  const b0 = await bookingsOf();

  const times = await api('POST', '/assistant/message', { token: t,
    body: { action: 'check_availability', args: { venueId: cast.venue.id }, session_id: ctx.thread } });
  const picker = (((times.data || {}).reply || {}).cards || []).find((c) => c.type === 'slot_picker');
  if (!picker) return skip('the money gate', `no free slot at ${cast.venue.name} today`);
  eq(times.data.reply.source, 'live', 'availability is answered live, from slots');
  const btn = (picker.data.buttons || [])[0];
  check(!!(btn && btn.args && btn.args.slotId), 'the picker button carries its slot id');

  const picked = await api('POST', '/assistant/message', { token: t,
    body: { action: 'pick_slot', args: btn.args, session_id: ctx.thread } });
  const conf = (((picked.data || {}).reply || {}).cards || []).find((c) => c.type === 'confirm');
  if (!conf) return skip('the money gate', `pick_slot did not arm a confirm: "${picked.data.reply.text}"`);
  eq(conf.data.what, 'book_venue', 'the confirm card knows which action it is arming');
  // The HTTP route projects state to {fsm,pending,intent,slots} -- `confirm` is not
  // exposed, on purpose, so a client cannot read what is armed. `fsm` is the flag.
  eq(picked.data.state && picked.data.state.fsm, 'awaiting_confirm',
    'and the FSM says money is next');
  return { w0, b0, walletOf, bookingsOf, slotId: btn.args.slotId };
}

/** The sentence that must not spend money, and the census that proves it did not. */
async function sectionJ2(cast, tok, ctx, j) {
  if (!j) return null;
  const t = tok.player.token;
  const y = await api('POST', '/assistant/message', { token: t,
    body: { text: 'haan lekin 7 baje', session_id: ctx.thread } });
  eq(y.status, 200, 'the correction is answered, not rejected');
  const nlu = (y.data || {}).nlu || {};
  eq(nlu.intent, 'affirm', 'the shipped model still calls "haan lekin 7 baje" an affirm');
  eq(nlu.via, 'model', 'and it is the MODEL saying so — no chip, no lexicon');
  check(nlu.confidence >= 0.45,
    `at ${nlu.confidence} — over the 0.45 floor, so an intent-only gate WOULD have fired`);
  const st = (y.data || {}).state || {};
  eq(st.slots && st.slots.time, '19:00', 'the rule extractor read "7 baje" as 19:00');
  check(st.fsm !== 'awaiting_confirm',
    `the armed confirm is gone, not left waiting for a later yes (fsm: ${st.fsm})`);
  check(y.data.reply.action !== 'book_venue' || y.data.reply.actionOk !== true,
    'the turn does not report a completed booking', String(y.data.reply.action));

  const b1 = await j.bookingsOf();
  eq(b1, j.b0, `NO BOOKING WAS MADE over HTTP — ${j.b0} before, ${b1} after`);
  const w1 = await j.walletOf();
  eq(String(w1.b), String(j.w0.b), `the wallet did not move (${j.w0.b})`);
  ev.addFact('A confident model affirm cannot spend PKR, proved over HTTP',
    `\`haan lekin 7 baje\` parsed \`affirm\` at ${nlu.confidence} via \`${nlu.via}\` -- above the 0.45 `
    + `threshold -- with a booking armed and waiting. Census either side of that one turn: bookings `
    + `${j.b0} to ${b1}, balance ${j.w0.b} to ${w1.b}. Money is gated by chip-or-lexicon only.`);
  eq(String(w1.f), String(j.w0.f), 'and nothing was frozen into escrow');

  // Yesterday's yes cannot buy today's slot: the confirm block died with the
  // correction, so a bare "haan" now — lexicon-decisive, the one word that does spend
  // money — has nothing armed to spend it on. This is the second half of the gate, and
  // it is the half that can only be checked by trying it.
  const late = await api('POST', '/assistant/message', { token: t,
    body: { text: 'haan', session_id: ctx.thread } });
  eq(late.status, 200, 'a bare "haan" with nothing armed is still answered');
  eq(((late.data || {}).nlu || {}).via, 'lexicon', '"haan" IS decided by the frozen lexicon');
  const b2 = await j.bookingsOf();
  eq(b2, j.b0, 'and it bought nothing, because the armed block was already gone');
  const w2 = await j.walletOf();
  eq(String(w2.b), String(j.w0.b), 'the wallet is still untouched after the stale yes');
  note(`money gate held: bookings ${j.b0} → ${b2}, balance ${j.w0.b} unchanged`);
  return j;
}

// K — the residue  (what a real HTTP run leaves behind, stated rather than hoped)

/**
 * check_assistant.js rolls back; this script cannot, so it must account for itself.
 *
 * Two kinds of row survive the cleanup on purpose. `assistant_turns.channel_id` is on
 * DELETE SET NULL, so the telemetry for every turn above stays — orphaned, by design,
 * because metrics outlive conversations. And a declined escalation's row is the record
 * of the decline. Both are counted here so the number is a claim, not a surprise.
 */
async function sectionK(cast, tok, ranAt) {
  section('K  residue — what a live run leaves in the database');
  const uid = tok.player.user.id;
  runCtx.uid = uid; runCtx.ranAt = ranAt;
  const turns = (await pool.query(
    `SELECT count(*)::int n, count(channel_id)::int withchan
       FROM assistant_turns WHERE user_id = $1 AND created_at >= $2`, [uid, ranAt])).rows[0];
  check(turns.n > 0, `this run measured ${turns.n} turn(s) in assistant_turns`);
  const cols = (await pool.query(
    `SELECT column_name FROM information_schema.columns
      WHERE table_name = 'assistant_turns'`)).rows.map((r) => r.column_name);
  check(!cols.some((c) => /utterance|text$|message$|query|prompt/i.test(c)),
    `and none of its ${cols.length} columns can hold the utterance itself`,
    cols.filter((c) => /text|message/i.test(c)).join(',') || 'text_chars only');
  const openThreads = (await pool.query(
    `SELECT count(*)::int n FROM chat_channels
      WHERE created_by = $1 AND type = 'assistant' AND archived_at IS NULL`, [uid])).rows[0].n;
  note(`player has ${openThreads} open Scout thread(s) after cleanup (cap ${threadsSvc.MAX_THREADS})`);
  runCtx.turns = turns.n;
  note(`${turns.withchan} of ${turns.n} telemetry rows still point at a live thread `
    + '— the FK claim is checked again after cleanup deletes those threads');
}

/**
 * The one assertion that can only be made after the delete.
 *
 * `assistant_turns.channel_id` is on DELETE SET NULL, not CASCADE, and the reason is in
 * migration 018: metrics outlive conversations. Deleting the threads this run created is
 * therefore a live test of that choice — if the FK were CASCADE, the cleanup above would
 * have silently erased the evidence for model #4's accuracy along with the chat. So the
 * same rows are counted again, after.
 */
async function afterCleanup() {
  if (!runCtx.uid || !runCtx.turns) return;
  const { rows: [r] } = await pool.query(
    `SELECT count(*)::int n, count(channel_id)::int withchan
       FROM assistant_turns WHERE user_id = $1 AND created_at >= $2`,
    [runCtx.uid, runCtx.ranAt],
  );
  eq(r.n, runCtx.turns,
    `all ${runCtx.turns} telemetry rows SURVIVED the chat being deleted (ON DELETE SET NULL)`);
  eq(r.withchan, 0, 'each with its channel_id nulled — orphaned on purpose, never cascaded away');
  ev.addFact('Deleting a conversation does not delete its telemetry',
    `The thread this run created was deleted through the API, and all ${r.n} of its \`assistant_turns\` `
    + `rows are still there with \`channel_id\` nulled ${r.n}/${r.n} -- migration 018's `
    + `\`ON DELETE SET NULL\`, which is why a user can clear their history without erasing the corpus `
    + `the next model is trained on.`);
}

// Main — one command, in the order a reviewer reads the spec

async function main() {
  const ranAt = new Date(Date.now() - 1000).toISOString();
  console.log('\n  Scout over real HTTP — TESTING.md §4.20 steps 196, 197 and 200');
  console.log(`  ${BASE}${KEEP ? '   (--keep: no cleanup)' : ''}`);

  const server = await ensureServer();
  if (!server.up) {
    console.log('\n  Could not reach or start the API. Nothing was tested.\n');
    process.exitCode = 1;
    return;
  }
  console.log(`  server: ${server.spawned ? 'spawned by this script' : 'already listening'}`);

  const cast = await pickCast();
  const ok = await preflight(cast);
  if (!ok) { failures.push('preflight'); return; }

  // A and A2 run before any login: they spend the whole anonymous quota by design.
  await sectionA(cast);
  await sectionA2();

  const tok = {
    player: await tokenFor(cast.player, 'player'),
    stranger: await tokenFor(cast.stranger, 'player'),
    owner: cast.owner ? await tokenFor(cast.owner, 'owner') : null,
    otherOwner: cast.otherOwner ? await tokenFor(cast.otherOwner, 'owner') : null,
  };
  note(`tokens: player via ${tok.player.via}, stranger via ${tok.stranger.via}`
    + `${tok.owner ? `, owner via ${tok.owner.via}` : ''}`);

  const ctx = await sectionB(cast, tok);
  if (!ctx || !ctx.thread) { failures.push('B never produced a thread — the rest cannot run'); return; }
  await sectionB2(cast, tok, ctx);
  await sectionC(cast, tok, ctx);
  await sectionC2(cast, tok, ctx);
  await sectionD(cast, tok, ctx);
  await sectionD2(cast, tok, ctx);
  await sectionE(cast, tok, ctx);
  await sectionF(cast, tok, ctx);
  await sectionH(cast, tok);
  const esc = await sectionI(cast, tok, ctx);
  const kb = await sectionI2(cast, tok, ctx, esc);
  await sectionI3(cast, tok, ctx, esc, kb);
  await sectionI4(cast, tok, ctx, kb);
  const j = await sectionJ(cast, tok, ctx);
  await sectionJ2(cast, tok, ctx, j);
  await sectionG(cast, tok);          // last: it fills the stranger's drawer to the cap
  await sectionK(cast, tok, ranAt);
}

/**
 * The footer, and the two things that must happen even when an assertion throws:
 * the rows this run created are deleted, and a spawned server is killed. A crashed
 * run that leaves 50 threads in the drawer would make the next run fail at the cap.
 */
(async () => {
  let child = null;
  try {
    await main();
    child = global.__scoutChild || null;
  } catch (err) {
    failures.push(`threw: ${err.message}`);
    console.error(`\n  ✗ ${err.stack}`);
  } finally {
    try {
      const c = await cleanup();
      if (!KEEP) console.log(`\n  cleanup: ${c.gone} row(s)/thread(s) removed`);
      if (!KEEP) {
        section('L  after the delete — the telemetry the FK was written to keep');
        await afterCleanup();
      }
    } catch (err) {
      console.log(`\n  cleanup FAILED: ${err.message}`);
      failures.push(`cleanup: ${err.message}`);
    }
    const total = passed + failures.length;
    if (ev.on) {
      const w = await ev.write({ passed, failed: failures.length, skipped: skips.length });
      if (w) console.log(`  evidence written to ${path.relative(process.cwd(), w.path)} (${w.lines} lines)`);
    }
    console.log(`\n${'═'.repeat(78)}`);
    if (notes.length) {
      console.log('  notes');
      for (const n of notes) console.log(`    · ${n}`);
    }
    if (skips.length) {
      console.log(`  skipped ${skips.length}:`);
      for (const s of skips) console.log(`    ~ ${s}`);
    }
    if (failures.length) {
      console.log(`  FAIL ${passed}/${total}`);
      for (const f of failures) console.log(`    ✗ ${f}`);
    } else {
      console.log(`  PASS ${passed}/${total}${skips.length ? ` (${skips.length} skipped)` : ''}`);
    }
    console.log(`${'═'.repeat(78)}\n`);
    const kid = global.__scoutChild || child;
    if (kid && !kid.killed) { try { kid.kill(); } catch { /* already gone */ } }
    await pool.end().catch(() => {});
    process.exit(failures.length ? 1 : 0);
  }
})();
