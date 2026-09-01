/**
 * check_notifications.js — the notification system, driven against the real
 * database, always rolled back.
 *
 * Usage:  node src/scripts/check_notifications.js
 *         node src/scripts/check_notifications.js --evidence
 *         node src/scripts/check_notifications.js --verify-clean
 *
 * WHY THIS SCRIPT EXISTS
 * ----------------------
 * Before S.7 Wave C the `notifications` table was WRITE-ONLY: thirty-eight call
 * sites inserted into it and nothing on earth read it. That is the exact shape of
 * breakage that survives a green `npm test` — every unit test passed while the
 * feature did not exist — so this wave is not called done on unit tests.
 *
 * What the unit tests cannot reach is everything interesting here. The collapse
 * upsert depends on Postgres inferring a PARTIAL UNIQUE INDEX from an ON CONFLICT
 * predicate, and a mismatch is a runtime 42P10 inside a money transaction rather
 * than a compile error. `created_at` being timestamptz rather than timestamp is a
 * property of the column, not of the code. The outbox claiming a row exactly once
 * is a property of FOR UPDATE SKIP LOCKED. Quiet hours wrapping midnight is a
 * property of two comparisons whose naive form gets 22:00→07:00 exactly backwards.
 * Each of those is a claim about the database or about wall-clock arithmetic, and
 * the only honest way to check them is to write the rows and read them back.
 *
 * NOTHING SURVIVES IT
 * -------------------
 * notify(), the feed and the outbox drain all take a caller-owned `client` and
 * write no BEGIN of their own — that is why they compose inside a booking approval,
 * and it is why this script holds ONE transaction across the whole run and
 * ROLLBACKs at the end. Rows are prefixed `zznotif-` so a run interrupted before
 * its rollback is identifiable, and `--verify-clean` re-checks that none exist.
 *
 * WHAT IT DOES NOT PROVE
 * ----------------------
 * It drives the core functions, not HTTP, and it never contacts Firebase. The
 * final block therefore closes the gap the only way a rolled-back script can: it
 * reads the SOURCE of server.js, routes/chat.js and routes/auth.js and asserts the
 * wiring exists, and it reads the Flutter route table — lib/routes/app_routes.dart,
 * and lib/main.dart with it — and asserts every route the registry
 * can emit is a route the app actually registers. "A function that works and is
 * never called" and "a notification whose tap goes nowhere" are the two failures
 * this wave exists to end, so both are checked rather than assumed.
 *
 *   ✗  a rule broke. The line names it.
 *   ~  the data could not supply the case. A skip is not a pass.
 */
const fs = require('fs');
const crypto = require('crypto');
const path = require('path');
const pool = require('../db/pool');
const reg = require('../utils/notificationTypes');
const { notify } = require('../utils/notify');
const feed = require('../utils/notificationFeed');
const job = require('../jobs/pushJob');
const push = require('../services/pushService');
const evidence = require('./lib/evidence');

const failures = [];
const skips = [];
let passed = 0;
let seq = 0;

const PREFIX = 'zznotif-';
const ARGS = process.argv.slice(2);
const VERIFY_CLEAN = ARGS.includes('--verify-clean');
const SRC = path.join(__dirname, '..');
const ROOT = path.join(__dirname, '..', '..', '..');

const EVIDENCE_OUT = path.join(ROOT, 'doc', 'notification_evidence.md');

const EVIDENCE_HEADER = `# Notifications — the evidence pack

**This file is generated. Do not edit it by hand.** Every line below was written by a
verification script that had just asserted it against the live database, inside one
transaction that was then rolled back — so the run leaves no rows behind and the
document is reproducible rather than a description of a state somebody once had. To
regenerate:

\`\`\`
cd backend && node src/scripts/check_notifications.js --evidence
\`\`\`

A block absent from this file was not run — it is not a pass.
`;

const ev = evidence.recorder({
  key: 'notifications',
  out: EVIDENCE_OUT,
  header: EVIDENCE_HEADER,
  markPrefix: 'notification-evidence',
  title: 'S.7 Wave C -- the registry, the collapse upsert, the feed and the push outbox',
  subtitle: 'Every notification type resolves to a category, a priority and a deep link the app '
    + 'actually registers; three messages from one person collapse into ONE feed row reading '
    + '"3 new messages" through a partial unique index Postgres has to infer at runtime; the '
    + 'feed pages, filters and counts unread against a hand-computed number; and the outbox '
    + 'claims each row exactly once, honours a muted category and a midnight-wrapping quiet '
    + 'window, and stamps an honest reason on every row it does not push -- including, today, '
    + '"no Firebase key". One transaction, rolled back at the end.',
  command: 'cd backend && node src/scripts/check_notifications.js --evidence',
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

function skip(label, why) {
  ev.skip(label, why);
  skips.push(label);
  console.log(`  ~ ${label}  (skipped: ${why})`);
  return false;
}

function eq(got, want, label) {
  return check(got === want, label, `got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
}

function has(haystack, needle, label) {
  const h = String(haystack || '');
  return check(h.includes(needle), label, `"${h.slice(0, 120)}" does not contain "${needle}"`);
}

/**
 * Run something that MIGHT fail without poisoning the outer transaction. Postgres
 * aborts the whole transaction on any error, so one bad query would turn every
 * later check into "current transaction is aborted" and hide the real result.
 */
async function probe(client, fn) {
  await client.query('SAVEPOINT probe');
  try {
    const out = await fn();
    await client.query('RELEASE SAVEPOINT probe');
    return { ok: true, out, err: null };
  } catch (err) {
    await client.query('ROLLBACK TO SAVEPOINT probe').catch(() => {});
    return { ok: false, out: null, err };
  }
}

function read(rel) {
  try { return fs.readFileSync(path.join(SRC, rel), 'utf8'); } catch (e) { return ''; }
}

function readRoot(rel) {
  try { return fs.readFileSync(path.join(ROOT, rel), 'utf8'); } catch (e) { return ''; }
}

async function makeUser(client, who, role = 'player') {
  seq += 1;
  const { rows } = await client.query(
    `INSERT INTO users (email, password_hash, name, phone, role, phone_verified)
     VALUES ($1, 'x', $2, $3, $4, TRUE) RETURNING id, name, role, notification_prefs`,
    [`${PREFIX}${who}@sportlynk.test`, `${PREFIX}${who}`,
      `+92300${String(8400000 + seq).slice(-7)}`, role],
  );
  return rows[0];
}

/** One notification row, read back whole. */
async function rowOf(client, id) {
  const { rows } = await client.query('SELECT * FROM notifications WHERE id = $1', [id]);
  return rows[0] || null;
}

// ═══════════════════════════════════════════════════════════════════════════
// 1 · THE REGISTRY  — the thing that decides where a tap goes
// ═══════════════════════════════════════════════════════════════════════════
//
// Every property the feed renders — category chip, icon, priority, destination —
// is a property of the TYPE, resolved server-side. So the registry is the single
// place a notification can be silently broken, and it is checked first.
//
// The last assertion in this block is the important one: it SCRAPES every
// `type: '...'` passed to a notify() call site out of the source tree and requires
// each to be registered. An unregistered type still writes a row (notify() must
// never throw inside a money transaction) but lands as category=system with a dead
// tap — which is precisely the "the button does nothing" breakage that started
// this sprint.

function probeSync(fn) {
  try { return { ok: true, out: fn(), err: null }; } catch (err) { return { ok: false, out: null, err }; }
}

// `type:` and the rest of its line, then every QUOTED lowercase literal on it.
// The quoting is the whole point. `type: side.notify.type` is a VARIABLE whose value
// is a literal written somewhere else, and a ternary puts TWO type names on one line
// -- a single combined capture reads the first as the identifier before the quote and
// the second not at all, then fails the check on a name no call site ever emits.
// Splitting it in two costs one regex and makes the assertion say what it means.
const TYPE_LINE = /\btype:\s*([^\n]*)/g;
const QUOTED = new RegExp('[\'"`]([a-z][a-z0-9_]*)[\'"`]', 'g');

function scrapeEmittedTypes() {
  const found = new Set();
  const walk = (dir) => {
    for (const name of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, name.name);
      if (name.isDirectory()) { if (name.name !== 'scripts') walk(full); continue; }
      if (!name.name.endsWith('.js')) continue;
      const src = fs.readFileSync(full, 'utf8');
      // Only inside a notify(...) argument object, and non-greedy so the window
      // closes at the call's own `})` instead of swallowing the logTxn() after it --
      // otherwise a ledger `type: 'refund'` is reported as an unregistered
      // notification type, which is a true statement about the wrong table.
      const calls = src.match(/notify\(\s*\w+\s*,\s*\{[\s\S]{0,600}?\}\s*\)/g) || [];
      for (const call of calls) {
        for (const line of call.matchAll(TYPE_LINE)) {
          for (const q of line[1].matchAll(QUOTED)) found.add(q[1]);
        }
      }
    }
  };
  walk(SRC);
  return [...found].sort();
}

function blockRegistry() {
  section('1 · The registry — every type resolves to a category, an icon and a route');

  const spec = probeSync(() => reg.assertNotificationTypes());
  check(spec.ok, 'assertNotificationTypes() passes at boot',
    spec.err ? spec.err.message.split('\n')[0] : '');
  if (!spec.ok) return;
  ev.addMeta('registered types', String(spec.out.types));
  ev.addMeta('deep-link routes', String(spec.out.routes));
  console.log(`    ${spec.out.types} types → ${spec.out.routes} distinct routes`);

  const types = reg.allTypes();
  const CATS = new Set(Object.values(reg.CATEGORY));
  let badCat = 0; let badIcon = 0; let badPrio = 0;
  for (const t of types) {
    const e = reg.describe(t);
    if (!CATS.has(e.category)) badCat += 1;
    if (!e.icon) badIcon += 1;
    if (!['high', 'normal', 'low'].includes(e.priority)) badPrio += 1;
  }
  eq(badCat, 0, 'every type has a category chk_notifications_category allows');
  eq(badPrio, 0, 'every type has a priority the CHECK allows');
  eq(badIcon, 0, 'every type has an icon — a feed row can never draw blank');

  // 'system' must NOT be mutable: a suspension the user opted out of being told
  // about is a suspension they discover by being unable to log in.
  check(!reg.MUTABLE_CATEGORIES.includes('system'),
    "'system' is not a mutable category — a suspension cannot be opted out of");
  check(reg.MUTABLE_CATEGORIES.includes('chat') && reg.MUTABLE_CATEGORIES.includes('booking'),
    'chat and booking ARE mutable — the categories a user actually wants control of');

  const emitted = scrapeEmittedTypes();
  ev.addMeta('types emitted by call sites', String(emitted.length));
  const unregistered = emitted.filter((t) => !reg.isRegistered(t));
  eq(unregistered.length, 0,
    `every type a notify() call site emits is registered (${emitted.length} scraped)`);
  if (unregistered.length) console.log(`      unregistered: ${unregistered.join(', ')}`);

  // The reverse is NOT an error and is deliberately reported rather than failed:
  // dispute_resolved and account_* are registered ahead of Wave D's call sites, and
  // a registry entry with no caller yet is a plan, not a bug.
  const unused = types.filter((t) => !emitted.includes(t));
  console.log(`    registered but not yet emitted (${unused.length}): ${unused.join(', ') || 'none'}`);
  ev.note(`Registered-but-not-yet-emitted types (${unused.length}): ${unused.join(', ') || 'none'} `
    + '— these are Wave D call sites, not defects.');
}

// ═══════════════════════════════════════════════════════════════════════════
// 2 · WHAT notify() ACTUALLY WRITES
// ═══════════════════════════════════════════════════════════════════════════

async function blockRow(client, ctx) {
  section('2 · The row — registry-stamped columns, inside the caller transaction');

  const r = await probe(client, () => notify(client, {
    userId: ctx.alice.id,
    type: 'match_challenge',
    title: 'New challenge',
    body: 'Lightning XI challenged you.',
    payload: { matchId: ctx.fakeMatchId, teamId: ctx.fakeTeamId },
    actorId: ctx.bob.id,
    expiresAt: new Date(Date.now() + 48 * 3600 * 1000),
  }));
  if (!check(r.ok, 'notify() writes without throwing', r.err && r.err.message)) return;

  const row = await rowOf(client, r.out.id);
  if (!check(!!row, 'the row is readable back on the same connection')) return;
  ctx.matchNotifId = row.id;

  const entry = reg.describe('match_challenge');
  eq(row.category, entry.category, `category came from the registry (${entry.category})`);
  eq(row.priority, entry.priority, `priority came from the registry (${entry.priority})`);
  eq(row.entity_type, 'match', 'entity_type is the polymorphic tap target');
  eq(row.entity_id, ctx.fakeMatchId, 'entity_id was read out of the payload');
  eq(row.actor_id, ctx.bob.id, 'actor_id records who caused it — the feed draws their avatar');
  eq(row.is_read, false, 'it starts unread');
  eq(row.sent_push, false, 'and unpushed — the row IS the outbox');
  eq(row.group_count, 1, 'group_count starts at 1');
  check(row.expires_at !== null, 'expires_at survived — a 48h challenge stops being actionable');

  const link = row.deep_link && (typeof row.deep_link === 'string'
    ? JSON.parse(row.deep_link) : row.deep_link);
  check(!!link, 'deep_link was computed server-side, not left to the client');
  if (link) {
    eq(link.route, '/match-center', 'the route is the match centre');
    eq(link.args && link.args.matchId, ctx.fakeMatchId, 'and it carries the match id as an arg');
    console.log(`    deep_link → ${JSON.stringify(link)}`);
    ev.note(`match_challenge deep link: ${JSON.stringify(link)}`);
  }

  // The UTC rule, checked on the COLUMN rather than on a value. Migration 010 used
  // bare TIMESTAMP, which makes "2 hours ago" wrong by the server offset; 020
  // converts it, and that conversion is exactly the kind of thing that silently
  // does not happen on a database one migration behind.
  const { rows: t } = await client.query(
    `SELECT data_type FROM information_schema.columns
      WHERE table_name = 'notifications' AND column_name = 'created_at'`,
  );
  eq(t[0] && t[0].data_type, 'timestamp with time zone',
    'notifications.created_at is timestamptz — the UTC-storage rule holds after 020');

  // An unregistered type must DEGRADE, never throw: notify() runs while holding
  // FOR UPDATE locks on wallet rows, and losing an alert costs a refresh while
  // rolling the transaction back costs money.
  const u = await probe(client, () => notify(client, {
    userId: ctx.alice.id, type: 'zz_not_a_real_type', title: 'Unknown', body: 'x',
  }));
  if (check(u.ok, 'an UNREGISTERED type still writes instead of throwing',
    u.err && u.err.message)) {
    const ur = await rowOf(client, u.out.id);
    eq(ur.category, 'system', 'as category=system');
    eq(ur.deep_link, null, 'with no deep link rather than a guessed one');
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 3 · THE COLLAPSE UPSERT  — three messages, one feed row
// ═══════════════════════════════════════════════════════════════════════════
//
// This is the block that justifies migration 020 existing at all. Postgres infers a
// PARTIAL unique index as the ON CONFLICT arbiter only when the clause predicate
// implies the index predicate, and a mismatch raises 42P10 at RUNTIME — inside a
// money transaction, on a path that until then looked fine.
//
// The second half is the rule that keeps collapse honest: a row that has been READ
// or DISMISSED leaves the partial index, so the next message must start a FRESH
// row. Bumping a hidden counter instead would show "2 new messages", then tell the
// user nothing at all about the third.

async function blockCollapse(client, ctx) {
  section('3 · Collapse — three messages become one row reading 3 new messages');

  const idx = await client.query(
    `SELECT indexdef FROM pg_indexes
      WHERE tablename = 'notifications' AND indexname = 'ux_notifications_group'`,
  );
  if (!check(idx.rows.length === 1, 'ux_notifications_group exists (migration 020)')) {
    skip('the collapse upsert', 'the partial unique index is missing');
    return;
  }
  const def = idx.rows[0].indexdef;
  has(def, 'UNIQUE', 'it is UNIQUE — two live rows for one thread are impossible');
  has(def, 'dismissed_at IS NULL', 'and PARTIAL on dismissed_at IS NULL');
  has(def, 'is_read = false', 'and on is_read = false — a read row leaves the index');
  ev.note(`ux_notifications_group: ${def}`);

  const send = (n) => notify(client, {
    userId: ctx.alice.id, type: 'chat_message',
    title: 'Bilal Khan', body: `message ${n}`,
    payload: { channelId: ctx.fakeChannelId, channelType: 'booking', channelTitle: 'Bilal Khan' },
    actorId: ctx.bob.id,
  });

  const one = await probe(client, () => send(1));
  if (!check(one.ok, 'the first chat message writes', one.err && one.err.message)) return;
  eq(one.out.groupCount, 1, 'the first is group_count = 1');
  eq(one.out.collapsed, false, 'and is not yet a collapsed row');

  const two = await probe(client, () => send(2));
  const three = await probe(client, () => send(3));
  if (!check(two.ok && three.ok, 'two more messages arrive',
    (two.err || three.err || {}).message)) return;
  eq(three.out.groupCount, 3, 'the third BUMPS the same row to group_count = 3');
  eq(three.out.id, one.out.id, 'and it is the same row id — no duplicate was inserted');

  const { rows: cnt } = await client.query(
    `SELECT count(*)::int AS n FROM notifications
      WHERE user_id = $1 AND type = 'chat_message'`, [ctx.alice.id],
  );
  eq(cnt[0].n, 1, 'the feed holds ONE row for three messages, not three');

  const row = await rowOf(client, one.out.id);
  eq(row.title, 'Bilal Khan', 'the title stays the person — the tray needs a thread identity');
  eq(row.body, '3 new messages', 'the body reads 3 new messages, not the newest one alone');
  eq(row.sent_push, false, 'sent_push was RESET — the 2 new messages banner is now stale');
  console.log(`    one row: "${row.title}" / "${row.body}" (group_count=${row.group_count})`);
  ev.note(`After three messages the feed holds one row: ${row.title} / ${row.body} `
    + `(group_count=${row.group_count}).`);

  // Read it, then send a fourth. It must NOT bump the read row.
  await feed.markRead(client, ctx.alice.id, row.id);
  const four = await probe(client, () => send(4));
  if (check(four.ok, 'a fourth message after the user has read the row',
    four.err && four.err.message)) {
    check(four.out.id !== row.id,
      'starts a FRESH row — a read row has left the partial index');
    eq(four.out.groupCount, 1, 'and counts from 1 again');
    ctx.freshChatId = four.out.id;
  }

  // A different collapse group, to prove the key is per-thread and not per-type.
  const other = await probe(client, () => notify(client, {
    userId: ctx.alice.id, type: 'chat_message',
    title: 'Team Lightning', body: 'hi',
    payload: { channelId: ctx.fakeChannelId2, channelType: 'team', channelTitle: 'Team Lightning' },
  }));
  if (check(other.ok, 'a message in a DIFFERENT thread', other.err && other.err.message)) {
    check(other.out.id !== ctx.freshChatId,
      'is its own row — group_key is per conversation, not per type');
    ctx.otherChatId = other.out.id;
  }

  // Two join requests for one team collapse with their OWN wording, which proves the
  // group is a registry property rather than something hard-coded for chat.
  const j1 = await probe(client, () => notify(client, {
    userId: ctx.alice.id, type: 'team_request', title: 'Lightning XI',
    body: 'Bilal asked to join.', payload: { teamId: ctx.fakeTeamId, teamName: 'Lightning XI' },
  }));
  const j2 = await probe(client, () => notify(client, {
    userId: ctx.alice.id, type: 'team_request', title: 'Lightning XI',
    body: 'Usman asked to join.', payload: { teamId: ctx.fakeTeamId, teamName: 'Lightning XI' },
  }));
  if (check(j1.ok && j2.ok, 'two join requests for one team', (j1.err || j2.err || {}).message)) {
    eq(j2.out.groupCount, 2, 'collapse to one row with group_count = 2');
    const jr = await rowOf(client, j2.out.id);
    eq(jr.title, '2 players want to join', 'and the TITLE is what changes for this group');
    ev.note(`Two join requests collapse to: ${jr.title}`);
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 4 · THE FEED  — the read side that did not exist before this wave
// ═══════════════════════════════════════════════════════════════════════════
//
// The unread count is checked against a HAND-COMPUTED number rather than against a
// second copy of the same query. A check script that re-implements the query it is
// verifying proves only that the author can write the bug twice.

async function blockFeed(client, ctx) {
  section('4 · The feed — paging, filtering, and a hand-computed unread count');

  const { rows: hand } = await client.query(
    `SELECT count(*)::int AS unread
       FROM notifications
      WHERE user_id = $1 AND is_read = false AND dismissed_at IS NULL`, [ctx.alice.id],
  );
  const s = await feed.summary(client, ctx.alice.id);
  eq(s.unread, hand[0].unread, `summary.unread matches a hand count (${hand[0].unread})`);
  check(Object.keys(s.byCategory).length >= 8,
    'byCategory names every category, including the zeroes the chips need');
  console.log(`    unread ${s.unread} · byCategory ${JSON.stringify(s.byCategory)}`);
  ev.note(`Summary for the run user: unread=${s.unread}, byCategory=${JSON.stringify(s.byCategory)}`);

  const page = await feed.listFeed(client, { userId: ctx.alice.id, limit: 3 });
  eq(page.items.length, 3, 'a limit of 3 returns exactly 3 rows');
  eq(page.hasMore, true, 'and reports hasMore without a COUNT(*) over the table');
  check(!!page.nextCursor, 'with a nextCursor to continue from');
  const first = page.items[0];
  check(!!first.icon, 'every row carries an icon resolved from the registry, not from the row');
  check(!!first.category, 'and a category');
  check('isExpired' in first, 'and an isExpired flag so a dead challenge does not look actionable');

  // The pair cursor, exercised where it actually matters. Every row in this run was
  // written inside ONE transaction milliseconds apart, so several share a created_at to
  // the microsecond — exactly the tie that a timestamp-only cursor silently drops rows
  // on. Page 2 must therefore neither repeat page 1 nor lose anything between them.
  const next = await feed.listFeed(client, {
    userId: ctx.alice.id, limit: 3, cursor: page.nextCursor,
  });
  const overlap = next.items.filter((i) => page.items.some((p) => p.id === i.id));
  eq(overlap.length, 0, 'the second page does not repeat a row from the first');
  const all = await feed.listFeed(client, { userId: ctx.alice.id, limit: 50 });
  const paged = [...page.items, ...next.items].map((i) => i.id);
  eq(paged.join(','), all.items.slice(0, paged.length).map((i) => i.id).join(','),
    'and the two pages are the unpaged order, in order — no row falls between them');
  check(feed.listFeed(client, { userId: ctx.alice.id, cursor: 'garbage' }) instanceof Promise,
    'a malformed cursor is user input and must not throw');
  const bad = await feed.listFeed(client, { userId: ctx.alice.id, limit: 3, cursor: 'garbage' });
  eq(bad.items[0].id, page.items[0].id, 'it decodes to page one rather than a 500');

  const chatOnly = await feed.listFeed(client, { userId: ctx.alice.id, category: 'chat' });
  check(chatOnly.items.length > 0 && chatOnly.items.every((i) => i.category === 'chat'),
    'a category filter returns only that category');

  const unreadOnly = await feed.listFeed(client, { userId: ctx.alice.id, unreadOnly: true });
  check(unreadOnly.items.every((i) => i.isRead === false),
    'unreadOnly returns nothing already read');
}

async function blockStates(client, ctx) {
  section('5 · Three states — unread, read, dismissed (and dismissed is not deleted)');

  const target = ctx.matchNotifId;
  if (!target) { skip('the state transitions', 'block 2 did not produce a row'); return; }

  eq(await feed.markRead(client, ctx.alice.id, target), 1, 'markRead marks an unread row');
  eq(await feed.markRead(client, ctx.alice.id, target), 0,
    'a second markRead is a no-op, not an error — the client can retry safely');
  const r1 = await rowOf(client, target);
  check(r1.read_at !== null, 'read_at records WHEN, which is a different fact from whether');

  eq(await feed.markUnread(client, ctx.alice.id, target), 1, 'markUnread puts it back');
  const r2 = await rowOf(client, target);
  eq(r2.group_count, 1,
    'and RESETS group_count — otherwise it would read 4 new messages when one is new');

  // Somebody else must not be able to touch it. Authorisation IS the WHERE clause,
  // so the honest answer is "no such row for you" rather than 403.
  eq(await feed.markRead(client, ctx.bob.id, target), -1,
    'another user marking it read gets -1 — the route turns that into a 404');

  eq(await feed.dismiss(client, ctx.alice.id, target), 1, 'dismiss removes it from the feed');
  const r3 = await rowOf(client, target);
  check(r3 !== null, 'the ROW SURVIVES — it is the only record the user was ever told');
  check(r3.dismissed_at !== null, 'with dismissed_at stamped');
  eq(r3.is_read, true,
    'and marked read too — a dismissed row that still counted would leave an uncleanable badge');

  const after = await feed.listFeed(client, { userId: ctx.alice.id, limit: 50 });
  eq(after.items.filter((i) => i.id === target).length, 0, 'and the feed no longer lists it');

  const s = await feed.summary(client, ctx.alice.id);
  const all = await feed.markAllRead(client, ctx.alice.id);
  check(all >= 1, `markAllRead clears the rest (${all} row(s) from ${s.unread} unread)`);
  const s2 = await feed.summary(client, ctx.alice.id);
  eq(s2.unread, 0, 'the badge is now zero');
}

async function blockPrefs(client, ctx) {
  section('6 · Preferences — stored server-side, because a client-honoured toggle is a suggestion');

  const d = feed.defaultPrefs();
  check(d.muteAll === false, 'the default is everything ON');
  check(!!d.push && !!d.inApp, 'with a push and an inApp map');

  // setPrefs returns `{prefs, categories, unmutable}`, not the bare prefs: the
  // settings screen needs the CATEGORY LIST from the registry in the same response, or
  // it would hard-code its own copy and a new category would need a client release.
  const saved = await feed.setPrefs(client, ctx.alice.id, {
    muteAll: false,
    push: { booking: false, chat: true, nonsense_category: false },
    quietHours: { enabled: true, start: '25:99', end: '7:3' },
  });
  const written = saved.prefs;
  check(saved.categories.length >= 8 && saved.unmutable.includes('system'),
    'the response carries the registry category list and names system as unmutable');
  eq(written.push.booking, false, 'an explicit false is stored');
  check(!('nonsense_category' in written.push), 'an unknown category is dropped, not persisted');
  check(!('chat' in written.push) || written.push.chat === true,
    'and true is not stored as an override — an absent key already means ON');
  eq(written.quietHours.start, '22:00', 'an invalid 25:99 falls back rather than being kept');
  eq(written.quietHours.end, '07:03', 'while a sloppy 7:3 is NORMALISED rather than replaced');
  ev.note(`Normalised prefs: ${JSON.stringify(written)}`);

  const read = await feed.getPrefs(client, ctx.alice.id);
  eq(JSON.stringify(read.prefs), JSON.stringify(written),
    'and it round-trips through the database — one normaliser on read and on write');

  // The two failure modes are asserted apart. An unparseable value falls back to the
  // DEFAULT window, and a sloppy but readable one is normalised -- if the check used
  // '7:0' and expected '07:00' it would pass either way, and would keep passing after
  // somebody broke normalisation.
  eq(feed.validHM('9:5'), '09:05', 'validHM zero-pads a readable time');
  eq(feed.validHM('24:00'), null, 'and rejects an hour that does not exist');
  eq(feed.validHM('nope'), null, 'and anything unparseable, so the caller can fall back');
}

// ═══════════════════════════════════════════════════════════════════════════
// 7 · QUIET HOURS  — the two comparisons whose naive form is exactly backwards
// ═══════════════════════════════════════════════════════════════════════════
//
// `start <= t && t < end` gets 22:00 → 07:00 inverted: quiet all day, loud all
// night. That is a pure function, so it is checked without touching the database,
// at a fixed instant in Asia/Karachi rather than in the server timezone — slot times
// are PKT wall-clock throughout SportLynk, and "quiet at 10pm" means the users 10pm.

function pkt(hhmm) {
  // 2026-08-30 in PKT is UTC+5, so subtract five hours to build the instant.
  const [h, m] = hhmm.split(':').map(Number);
  return new Date(Date.UTC(2026, 7, 30, h - 5, m, 0));
}

function blockQuietHours() {
  section('7 · Quiet hours — a window that wraps midnight');

  const on = { quietHours: { enabled: true, start: '22:00', end: '07:00' } };
  const cases = [
    ['21:59', false], ['22:00', true], ['23:30', true],
    ['03:00', true], ['06:59', true], ['07:00', false], ['12:00', false],
  ];
  let wrong = 0;
  for (const [t, want] of cases) {
    const got = job.inQuietHours(on, pkt(t));
    if (got !== want) { wrong += 1; console.log(`      ${t} → ${got}, want ${want}`); }
  }
  eq(wrong, 0, 'a 22:00→07:00 window is quiet across midnight and loud at 07:00 (7 instants)');
  ev.note('Quiet hours 22:00→07:00 in Asia/Karachi: '
    + cases.map(([t, w]) => `${t}=${w ? 'quiet' : 'loud'}`).join(', '));

  check(job.inQuietHours({ quietHours: { enabled: true, start: '22:00', end: '22:00' } }, pkt('23:00')) === false,
    'a zero-length window reads as OFF, not as always-quiet');
  check(job.inQuietHours({ quietHours: { start: '22:00', end: '07:00' } }, pkt('23:00')) === false,
    'and a window with no enabled flag is off — opting in has to be explicit');

  // The suppression chain, checked against the registry rule it has to agree with.
  const muteAll = { muteAll: true };
  check(job.suppressionReason({ category: 'booking' }, muteAll) !== null,
    'muteAll suppresses a booking push');
  check(job.suppressionReason({ category: 'system' }, muteAll) === null,
    'but NOT a system one — the same rule notificationTypes states by omitting it from MUTABLE');
  check(job.suppressionReason({ category: 'chat' }, { push: { chat: false } }) !== null,
    'a per-category mute suppresses that category');
  check(job.suppressionReason({ category: 'booking' }, { push: { chat: false } }) === null,
    'and leaves the others alone');
  check(job.suppressionReason({ category: 'booking' }, {}) === null,
    'an empty prefs object means everything ON — a new category is never silently off');
}

// ═══════════════════════════════════════════════════════════════════════════
// 8 · THE OUTBOX  — every row leaves with an honest reason
// ═══════════════════════════════════════════════════════════════════════════
//
// The drain runs against the SAME transaction this script owns, which is the only
// way to observe it without leaving stamped rows behind. Firebase is never called:
// with no service account the send path is skipped and the row is stamped with why,
// and that is the state this wave SHIPS in — so it is the state that gets tested.
//
// The important ordering claim is that a muted category is recorded as muted even
// while push is unconfigured. Both are true at once, and reporting the Firebase key
// first would make preference enforcement unobservable until the day a key exists.

async function blockOutbox(client, ctx) {
  section('8 · The outbox — claimed once, stamped with a reason, badge emitted regardless');

  const outbox = await client.query(
    `SELECT indexdef FROM pg_indexes
      WHERE tablename = 'notifications' AND indexname = 'idx_notifications_outbox'`,
  );
  check(outbox.rows.length === 1, 'idx_notifications_outbox exists — the drain is an index scan');

  ev.addMeta('FCM', push.isConfigured() ? 'configured' : `off (${push.status().reason})`);
  console.log(`    FCM: ${push.isConfigured() ? 'configured' : push.status().reason}`);

  // A fresh row for a user with no muted category and no device.
  await feed.setPrefs(client, ctx.bob.id, { muteAll: false, push: {}, inApp: {} });
  const fresh = await notify(client, {
    userId: ctx.bob.id, type: 'booking_confirmed', title: 'Booking confirmed',
    body: 'Ravi Cricket Ground, 6pm', payload: { bookingId: ctx.fakeBookingId },
  });
  const t1 = await probe(client, () => job.drainOutbox(client));
  if (!check(t1.ok, 'the drain runs', t1.err && t1.err.message)) return;
  const f1 = await rowOf(client, fresh.id);
  eq(f1.sent_push, true, 'the fresh row leaves the outbox');
  eq(f1.push_attempts, 1, 'with push_attempts = 1 — the claim is an UPDATE, so a crash cannot loop');
  check(!!f1.push_error, `and an honest reason: ${f1.push_error}`);
  eq(f1.is_read, false, 'while the IN-APP row stays unread — push and feed are separate concerns');
  ev.note(`A row with no device and no Firebase key is stamped: ${f1.push_error}`);

  const t2 = await probe(client, () => job.drainOutbox(client));
  check(t2.ok && t2.out.claimed === 0, 'a second drain claims nothing — no row is pushed twice');

  // A row that has already expired. The in-app row must survive as expired; only the
  // banner is the part that would mislead.
  const dead = await notify(client, {
    userId: ctx.bob.id, type: 'match_challenge', title: 'Challenge', body: 'expired',
    payload: { matchId: ctx.fakeMatchId }, expiresAt: new Date(Date.now() - 60000),
  });
  const t3 = await probe(client, () => job.drainOutbox(client));
  if (check(t3.ok, 'a drain with an expired row', t3.err && t3.err.message)) {
    eq(t3.out.expired, 1, 'counts it as expired');
    const d = await rowOf(client, dead.id);
    has(d.push_error, 'expired', 'and says so on the row');
    eq(d.is_read, false, 'while the in-app row is untouched — it renders as expired, not gone');
  }

  // A muted category. This is the assertion that would be impossible if the
  // configured-check came first.
  await feed.setPrefs(client, ctx.bob.id, { push: { booking: false } });
  const muted = await notify(client, {
    userId: ctx.bob.id, type: 'booking_confirmed', title: 'Booking confirmed',
    body: 'muted category', payload: { bookingId: ctx.fakeBookingId },
  });
  const t4 = await probe(client, () => job.drainOutbox(client));
  if (check(t4.ok, 'a drain with a MUTED category', t4.err && t4.err.message)) {
    eq(t4.out.suppressed, 1, 'records it as suppressed by the preference');
    const m = await rowOf(client, muted.id);
    has(m.push_error, 'muted', `and names the reason: ${m.push_error}`);
    eq(m.is_read, false, 'the IN-APP row is still delivered — a mute silences the phone only');
    eq(m.dismissed_at, null, 'and is still in the feed');
    ev.note(`A muted category is recorded as "${m.push_error}" while the in-app row stays unread.`);
  }

  // system, with everything muted. It must still go out.
  await feed.setPrefs(client, ctx.bob.id, { muteAll: true });
  const sys = await notify(client, {
    userId: ctx.bob.id, type: 'account_suspended', title: 'Account suspended',
    body: 'Contact support.',
  });
  const t5 = await probe(client, () => job.drainOutbox(client));
  if (check(t5.ok, 'a system notification with muteAll set', t5.err && t5.err.message)) {
    const sr = await rowOf(client, sys.id);
    check(!/muted/.test(sr.push_error || ''),
      `is NOT suppressed — a suspension cannot be muted (${sr.push_error})`);
  }
  await feed.setPrefs(client, ctx.bob.id, {});

  // retireStale. An over-age row must LEAVE the outbox with a reason, because
  // idx_notifications_outbox is partial on sent_push = false and a row that can never
  // be sent would otherwise sit in that index forever, walked by every 4-second scan.
  const old = await notify(client, {
    userId: ctx.bob.id, type: 'booking_reminder', title: 'Old', body: 'stale',
    payload: { bookingId: ctx.fakeBookingId },
  });
  await client.query(
    `UPDATE notifications SET created_at = now() - interval '3 hours', sent_push = false
      WHERE id = $1`, [old.id],
  );
  const t6 = await probe(client, () => job.drainOutbox(client));
  if (check(t6.ok, 'a drain with a row older than the cutoff', t6.err && t6.err.message)) {
    check(t6.out.retired >= 1, `retires it rather than claiming it (retired=${t6.out.retired})`);
    const o = await rowOf(client, old.id);
    eq(o.sent_push, true, 'so it leaves the partial outbox index');
    eq(o.push_attempts, 0, 'without ever being claimed — a stale banner is worse than none');
    has(o.push_error, 'older than', `and records why: ${o.push_error}`);
  }

  // The attempt ceiling. Three failed claims and the row closes with the last error,
  // which is what stops one poisonous row from being retried forever.
  const doomed = await notify(client, {
    userId: ctx.bob.id, type: 'booking_reminder', title: 'Doomed', body: 'retries',
    payload: { bookingId: ctx.fakeBookingId },
  });
  await client.query(
    'UPDATE notifications SET sent_push = false, push_attempts = $2, push_error = $3 WHERE id = $1',
    [doomed.id, job.MAX_ATTEMPTS, 'simulated transport failure'],
  );
  const t7 = await probe(client, () => job.drainOutbox(client));
  if (check(t7.ok, `a row at the ${job.MAX_ATTEMPTS}-attempt ceiling`, t7.err && t7.err.message)) {
    const d2 = await rowOf(client, doomed.id);
    eq(d2.sent_push, true, 'is retired, not claimed a fourth time');
    has(d2.push_error, 'gave up after', `carrying the last error forward: ${d2.push_error}`);
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 9 · WIRING  —  the part a passing unit test cannot see
// ═══════════════════════════════════════════════════════════════════════════
//
// Everything above proves the notification MACHINE works. This block proves it is
// PLUGGED IN, by reading the source of the files that have to call it. That
// distinction is the whole reason this block exists: the failure that opened this
// sprint was not a broken function, it was a correct function nobody called — a
// notifications table with 33 writers and no reader, and a bell icon with no onTap.
//
// A string match on source is a blunt instrument and it is the right one here. The
// alternative is booting an HTTP server, authenticating two users and driving a socket
// from a script that must not commit anything, to assert a fact that is decided at
// require() time.
function blockWiring() {
  section('9 · WIRING — the calls that make the machine reachable');

  const server = read('server.js');
  check(/routes\/notifications/.test(server), 'server.js requires routes/notifications');
  check(/app\.use\(\s*["']\/api\/notifications["']/.test(server),
    'and mounts it at /api/notifications — without this the table stays write-only');
  check(/assertNotificationTypes\(\)/.test(server),
    'server.js asserts the registry at LOAD, so a bad entry is a boot failure not a blank row');
  check(/startPushJob\(\)/.test(server), 'and starts the outbox drain (the 7th job)');

  const chatRoute = read('routes/chat.js');
  check(/notifyNewMessage/.test(chatRoute), 'routes/chat.js notifies on a new message');
  check(/!out\.duplicate/.test(chatRoute),
    'guarded by !duplicate — a retried clientId must not ping the phone twice');
  const chatWindow = chatRoute.slice(0, chatRoute.indexOf('notifyNewMessage'));
  check(chatWindow.lastIndexOf('BEGIN') > chatWindow.lastIndexOf('COMMIT'),
    'inside the same transaction as the insert — the alert cannot outlive a rolled-back message');

  const auth = read('routes/auth.js');
  check(/pushService/.test(auth), 'routes/auth.js can register a device');
  check(/registerDevice/.test(auth), 'login registers the FCM token it was given');
  check(/router\.post\(\s*["']\/logout["']/.test(auth),
    'and POST /logout exists — a token left registered delivers to whoever signs in next');
  check(/revokeAllForUser|revokeDevice/.test(auth), 'which revokes the device rather than ignoring it');

  const core = read('utils/chatCore.js');
  check(/isUserViewingChannel/.test(core),
    'chatCore consults presence — no row for a message already on screen');
  check(/muted_until/.test(core), 'and the per-channel mute');
  check(/SAVEPOINT sl_chat_notify/.test(core),
    'SAVEPOINT-wrapped, so a notifications failure cannot roll back somebody message');
}

// ═══════════════════════════════════════════════════════════════════════════
// 10 · THE DEEP LINKS RESOLVE  —  server routes vs the Flutter route table
// ═══════════════════════════════════════════════════════════════════════════
//
// The registry computes the destination SERVER-side and ships it as
// `deep_link: {route, args}`, so the client never guesses. That removes one class of
// drift and creates another: the server can now name a route the app does not have,
// and the symptom is a notification that looks perfect and does nothing when tapped.
//
// Nothing in Dart or in Node can catch that — one half is a string in a JS object, the
// other is a key in a Flutter route table — so it is checked here, by reading that table
// and requiring every route the registry can emit to appear in it.
// This is the single assertion in the file that is aimed directly at the breakage the
// user reported, and it is why the registry keeps its routes in one exported list.
//
// The table's home is lib/routes/app_routes.dart; it used to be inline in lib/main.dart.
// BOTH are read and their keys UNIONED, because this block does not care which file
// declares a route — only that the app registers it. Reading both is also what stops a
// future move of the table from turning a real assertion into a silent false pass: the
// route set would have to vanish from two files at once for that.
function blockDeepLinks() {
  section('10 · Deep links — every route the server emits exists in the route table');

  const routeFiles = [
    path.join('lib', 'routes', 'app_routes.dart'),
    path.join('lib', 'main.dart'),
  ];
  const sources = routeFiles.map((rel) => readRoot(rel)).filter(Boolean);
  if (!sources.length) { skip(`${routeFiles.join(' / ')} could not be read`); return; }

  const declared = new Set();
  for (const src of sources) {
    for (const hit of src.match(/["'](\/[a-z0-9-]+)["']\s*:/g) || []) {
      declared.add(hit.replace(/["':\s]/g, ''));
    }
  }
  check(declared.size > 10, `the route table declares ${declared.size} named routes`);

  const routes = reg.allRoutes();
  check(routes.length > 0, `the registry emits ${routes.length} distinct routes`);
  const missing = routes.filter((r) => !declared.has(r));
  if (check(missing.length === 0,
    missing.length ? `MISSING from the route table: ${missing.join(', ')}` : 'all of them are registered in app_routes.dart')) {
    ev.note(`All ${routes.length} registry routes resolve against the Flutter route table — no notification taps into a dead route.`);
  }

  // The bells. Wave B shipped them inert on purpose; Wave C is what gives them a tap.
  for (const screen of ['player_home_screen.dart', 'owner_home_screen.dart']) {
    const src = readRoot(path.join('lib', 'screens', screen.startsWith('player') ? 'player' : 'owner', screen));
    if (!src) { skip(`${screen} could not be read`); continue; }
    check(/notification/i.test(src), `${screen} references notifications`);
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 11 · SCHEMA CENSUS  —  migration 020 is actually applied
// ═══════════════════════════════════════════════════════════════════════════
//
// Wave A shipped on `npm test` alone against a schema that had never been applied, and
// every check script in it was unrunnable as a result. So the last block asserts the
// columns and indexes this wave depends on are present on the CONNECTED database, not
// merely present in a .sql file in the repo.
async function blockSchema(client) {
  section('11 · Schema census — migration 020 on the live database');

  const cols = async (table) => {
    const { rows } = await client.query(
      'SELECT column_name, data_type FROM information_schema.columns WHERE table_name = $1',
      [table],
    );
    return new Map(rows.map((r) => [r.column_name, r.data_type]));
  };

  const n = await cols('notifications');
  for (const c of ['read_at', 'dismissed_at', 'category', 'priority', 'group_key',
    'group_count', 'deep_link', 'actor_id', 'image_url', 'entity_type', 'entity_id',
    'expires_at', 'sent_push', 'push_attempts', 'pushed_at', 'push_error']) {
    check(n.has(c), `notifications.${c}`);
  }
  eq(n.get('created_at'), 'timestamp with time zone',
    'notifications.created_at is timestamptz (010 shipped it naive — "2 hours ago" was wrong by the server offset)');

  const d = await cols('user_devices');
  check(d.size > 0, 'user_devices exists — one row per install, not one token per user');
  for (const c of ['fcm_token', 'platform', 'revoked_at', 'revoke_reason', 'last_seen_at']) {
    check(d.has(c), `user_devices.${c}`);
  }

  const u = await cols('users');
  check(u.has('notification_prefs'), 'users.notification_prefs');
  const { rows: idx } = await client.query(
    `SELECT indexname FROM pg_indexes
      WHERE tablename IN ('notifications','user_devices','chat_messages')`,
  );
  const names = new Set(idx.map((r) => r.indexname));
  for (const i of ['idx_notifications_unread', 'idx_notifications_outbox',
    'ux_notifications_group']) {
    check(names.has(i), `index ${i}`);
  }
  // The plan called (channel_id, created_at) missing on chat_messages. It is not:
  // idx_chat_messages_channel already covers it, so 020 adds nothing and this asserts
  // the covering index by its real name instead of creating a duplicate.
  check(names.has('idx_chat_messages_channel'),
    'idx_chat_messages_channel covers (channel_id, created_at) — the chat list is not a seq scan');
}

// ════════════════════════════════════════════════════════════════════════════
// THE RUN
// ════════════════════════════════════════════════════════════════════════════

/** No row this script writes may ever be found outside its own transaction. */
async function verifyClean(client) {
  section('--verify-clean');
  const { rows } = await client.query(
    `SELECT (SELECT count(*) FROM users WHERE email LIKE $1)::int AS users,
            (SELECT count(*) FROM notifications n JOIN users u ON u.id = n.user_id
              WHERE u.email LIKE $1)::int AS notifs,
            (SELECT count(*) FROM user_devices d JOIN users u ON u.id = d.user_id
              WHERE u.email LIKE $1)::int AS devices`,
    [`${PREFIX}%`],
  );
  eq(rows[0].users, 0, 'no zznotif- user exists in the database');
  eq(rows[0].notifs, 0, 'no notification belongs to one');
  eq(rows[0].devices, 0, 'and no device row either');
}

async function main() {
  const client = await pool.connect();
  const ctx = {};
  let rolled = false;
  try {
    if (VERIFY_CLEAN) { await verifyClean(client); return; }

    const st = push.status();
    console.log(`\n  registry  ${reg.allTypes().length} types → ${reg.allRoutes().length} routes`);
    console.log(`  FCM       ${st.configured ? `ready (project ${st.projectId})` : `off — ${st.reason}`}`);
    console.log(`  outbox    every ${job.TICK_MS / 1000}s, ${job.MAX_ATTEMPTS} attempts, `
      + `${Math.round(job.MAX_AGE_MS / 60000)} min cutoff`);
    ev.addMeta('FCM at run time', st.configured ? `configured (${st.projectId})` : `dormant (${st.reason})`);
    ev.addMeta('outbox tick', `${job.TICK_MS / 1000}s`);

    // The registry and the two source-reading blocks touch no database at all, so
    // they run before BEGIN — a schema problem must not be able to hide a wiring
    // problem, which is what happens when the whole file is one try block.
    blockRegistry();
    blockQuietHours();
    blockWiring();
    blockDeepLinks();

    await client.query('BEGIN');
    await blockSchema(client);

    ctx.alice = await makeUser(client, 'alice');
    ctx.bob = await makeUser(client, 'bob');
    // Ids for things this run does not need to exist. `entity_id` is deliberately
    // NOT a foreign key (it is polymorphic across six entity types), and the deep
    // link is a string the app resolves, so a random uuid exercises every code path
    // a real one would without dragging six tables' worth of fixtures into a test
    // about notifications.
    ctx.fakeBookingId = crypto.randomUUID();
    ctx.fakeMatchId = crypto.randomUUID();
    ctx.fakeTeamId = crypto.randomUUID();
    ctx.fakeChannelId = crypto.randomUUID();
    ctx.fakeChannelId2 = crypto.randomUUID();

    await blockRow(client, ctx);
    await blockCollapse(client, ctx);
    await blockFeed(client, ctx);
    await blockStates(client, ctx);
    await blockPrefs(client, ctx);
    await blockOutbox(client, ctx);
  } catch (err) {
    console.error('\n  ! the run stopped:', err.message);
    failures.push(`the run completed without throwing (${err.message})`);
  } finally {
    if (!VERIFY_CLEAN) {
      await client.query('ROLLBACK').then(() => { rolled = true; }).catch(() => {});

      // The rollback, proven rather than asserted: the same connection, now outside
      // any transaction, must not be able to see one row this run wrote.
      section('The rollback');
      try {
        const { rows } = await client.query(
          `SELECT (SELECT count(*) FROM users WHERE email LIKE $1)::int AS users,
                  (SELECT count(*) FROM notifications WHERE id = $2)::int AS notif`,
          [`${PREFIX}%`, ctx.matchNotifId || '00000000-0000-0000-0000-000000000000'],
        );
        eq(rows[0].users, 0, 'after ROLLBACK neither test user still exists');
        eq(rows[0].notif, 0, 'and not one notification this run wrote — the database is as it was');
      } catch (err) {
        check(false, 'the rollback could be verified', err.message);
      }
    }
    client.release();
  }
  if (!rolled && !VERIFY_CLEAN) console.log('\n  ! the transaction was NOT rolled back');
}

/**
 * The verdict. A skip is printed alongside the pass count and never inside it: a
 * case the data could not supply is a case that did not run, and folding it into
 * the pass total would turn thin data into a green tick.
 */
async function report() {
  const total = passed + failures.length;
  console.log(`\n${'═'.repeat(72)}`);
  if (failures.length) {
    console.log(`FAIL ${passed}/${total}${skips.length ? ` · ${skips.length} skipped` : ''}\n`);
    for (const f of failures) console.log(`  ✗ ${f}`);
  } else {
    console.log(`PASS ${passed}/${total}${skips.length ? ` · ${skips.length} skipped` : ''}`);
  }
  if (skips.length) {
    console.log('\nskipped (the data could not supply the case, not a pass):');
    for (const s of skips) console.log(`  ~ ${s}`);
  }
  if (ev.on) {
    const written = await ev.write({ passed, failed: failures.length, skipped: skips.length });
    if (written) console.log(`\nevidence → ${written.path} (${written.lines} lines)`);
  }
  console.log('');
  return failures.length ? 1 : 0;
}

main()
  .then(report)
  .then(async (code) => {
    await pool.end();
    process.exit(code);
  })
  .catch(async (err) => {
    console.error('\nthe harness itself failed:', err);
    await pool.end().catch(() => {});
    process.exit(1);
  });
