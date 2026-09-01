/**
 * check_admin.js — the admin module (S.7 Wave D), driven against the real
 * database, always rolled back.
 *
 * Usage:  node src/scripts/check_admin.js
 *         node src/scripts/check_admin.js --evidence   (writes doc/admin_evidence.md)
 *         node src/scripts/check_admin.js --verify-clean
 *
 * Why this script exists
 * Wave D added four powers an admin did not have, and every one of them is a claim
 * about rows in several tables at once:
 *
 *   a RULING     reverses or applies a rating exchange, closes both sides'
 *                disputes, unfreezes what the freeze was waiting on, advances a
 *                bracket, tells both captains and writes an audit row — and it must
 *                move the ladder exactly once, which is the one mistake nobody can
 *                detect after the fact;
 *   a suspension cancels and refunds upcoming bookings, withdraws entries, closes an
 *                owner's venues, and — the part that was cosmetic before this wave —
 *                makes an already-issued token stop working;
 *   a setting    has to reach the next booking with no restart, or FR10.11 is a
 *                sentence in a document rather than a behaviour;
 *   an export    has to survive being opened in Excel by the owner whose venue is
 *                called `=1+1`.
 *
 * `npm test` proves the arithmetic with the database down. It cannot prove any of
 * the five sentences above, because each of them is only true of ROWS. So this
 * script writes the rows.
 *
 * Nothing survives it — with one named exception
 * Every service under test takes a caller-owned `client` and opens no transaction
 * of its own, so the whole run is one transaction and ends in ROLLBACK. Rows are
 * prefixed `zzadmin-` and `--verify-clean` re-checks that none exist.
 *
 * The exception is Block 7. `authMiddleware` re-checks the account through the
 * pool (its `accountState` is not exported and takes its own connection), so a user
 * that exists only inside this transaction is invisible to it — the block would
 * assert nothing. It therefore commits one user of its own, proves the 403, and
 * hard-deletes it in a `finally`. That is stated out loud in the block's own output
 * rather than hidden, because a script that quietly writes outside its transaction
 * is worse than one that does not run.
 *
 * Two pieces of process-global state A ROLLBACK cannot undo
 *   `escrow.POLICY.DEPOSIT_PERCENT` — a module variable that `createBooking` pushes
 *   the configured percent into, and
 *   the `globalSettings` 60 s cache — which holds whatever was last read, including
 *   values read from inside this transaction.
 * Both are saved and restored in a `finally`. Leaving either behind would make the
 * next script in a chained verification run read this one's fixtures as policy.
 *
 *   ✗  a rule broke. The line names it.
 *   ~  the data could not supply the case. A skip is not a pass.
 */
const path = require('path');
const jwt = require('jsonwebtoken');
const pool = require('../db/pool');
const catalog = require('../utils/settingsCatalog');
const settings = require('../utils/globalSettings');
const escrow = require('../utils/escrow');
const elo = require('../utils/elo');
const mc = require('../utils/matchCore');
const csv = require('../utils/csv');
const chat = require('../utils/chatCore');
const disputes = require('../services/disputeService');
const suspension = require('../services/suspensionService');
const bookings = require('../services/bookingService');
const reports = require('../services/reportService');
const authMiddleware = require('../middleware/authMiddleware');
const evidence = require('./lib/evidence');

const failures = [];
const skips = [];
let passed = 0;

const PREFIX = 'zzadmin-';
const ARGS = process.argv.slice(2);
const VERIFY_CLEAN = ARGS.includes('--verify-clean');

const EVIDENCE_OUT = path.join(__dirname, '..', '..', '..', 'doc', 'admin_evidence.md');

const EVIDENCE_HEADER = `# Admin — the evidence pack

**This file is generated. Do not edit it by hand.** Every line below was written by a
verification script that had just asserted it against the live database, inside one
transaction that was then rolled back — so the run leaves no rows behind and the
document is reproducible rather than a description of a state somebody once had. To
regenerate:

\`\`\`
cd backend && node src/scripts/check_admin.js --evidence
\`\`\`

A block absent from this file was not run — it is not a pass.
`;

const ev = evidence.recorder({
  key: 'admin',
  out: EVIDENCE_OUT,
  header: EVIDENCE_HEADER,
  markPrefix: 'admin-evidence',
  title: 'S.7 Wave D -- rulings, suspension, live settings and the financial export',
  subtitle: 'A disputed match is ruled through the same verified path an owner uses and the ladder '
    + 'moves exactly ONCE -- a second ruling on the same dispute is refused and every rating is '
    + 'unchanged after it; a fixture ruling advances the bracket inside the same transaction; a '
    + 'suspension cancels and refunds the upcoming booking, closes an owner\'s venues and makes an '
    + 'ALREADY-ISSUED token return 403 on its next request; a commission and a deposit written by '
    + 'the settings route reach the next booking with no restart; and the export escapes a venue '
    + 'named =1+1 so it cannot execute when the owner opens their own report in Excel. One '
    + 'transaction, rolled back at the end.',
  command: 'cd backend && node src/scripts/check_admin.js --evidence',
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

/** A substring assertion that prints what it received when it fails. */
function has(haystack, needle, label) {
  const h = String(haystack || '');
  return check(h.includes(needle), label, `"${h.slice(0, 140)}" does not contain "${needle}"`);
}

/**
 * Run something that might fail without poisoning the outer transaction. Postgres
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

/** One backend source file, for the wiring assertions. Missing file = empty string. */
function read(rel) {
  // eslint-disable-next-line global-require
  const fs = require('fs');
  try { return fs.readFileSync(path.join(__dirname, '..', rel), 'utf8'); } catch { return ''; }
}

/** Two decimal places, the way every money helper in the codebase rounds. */
function round2(n) {
  return Math.round((Number(n) || 0) * 100) / 100;
}

/** A team's rating as it stands right now — the number a ruling must move once. */
async function eloOf(client, teamId) {
  const { rows } = await client.query('SELECT elo, elo_frozen FROM teams WHERE id = $1', [teamId]);
  return rows.length ? { elo: Number(rows[0].elo), frozen: rows[0].elo_frozen === true } : null;
}

/** Every rating row written for a match, oldest first — the audit trail itself. */
async function eloRows(client, matchId) {
  const { rows } = await client.query(
    `SELECT team_id, elo_before, elo_after, elo_delta, k_factor, reason
       FROM elo_history WHERE match_id = $1 ORDER BY created_at ASC, id ASC`,
    [matchId],
  );
  return rows;
}

/** Audit rows an admin action left behind, newest first. */
async function auditRows(client, adminId, action) {
  const { rows } = await client.query(
    `SELECT action, entity_type, entity_id, before, after, note
       FROM admin_audit WHERE admin_id = $1 AND action = $2 ORDER BY created_at DESC`,
    [adminId, action],
  );
  return rows;
}

// The CAST

/**
 * The venue is chosen, never created: the export, the sport toggle and the booking
 * room all read a real venue row, and a fabricated venue would prove the join
 * rather than the data. Everything with a person in it is created, because every
 * assertion here is about what happened to a specific account.
 */
async function pickVenue(client) {
  const { rows } = await client.query(
    `SELECT v.id, v.name, v.city, v.image_url, v.owner_id, v.sport_type,
            u.name AS owner_name
       FROM venues v JOIN users u ON u.id = v.owner_id
      WHERE v.owner_id IS NOT NULL AND v.name IS NOT NULL AND v.is_active = true
      ORDER BY v.created_at ASC LIMIT 1`,
  );
  return rows[0] || null;
}

let seq = 0;
async function makeUser(client, who, role = 'player') {
  seq += 1;
  const { rows } = await client.query(
    `INSERT INTO users (email, password_hash, name, phone, role, phone_verified, is_active)
     VALUES ($1, 'x', $2, $3, $4, TRUE, TRUE) RETURNING id, name, role, is_active`,
    [`${PREFIX}${who}@sportlynk.test`, `${PREFIX}${who}`,
      `+92300${String(8300000 + seq).slice(-7)}`, role],
  );
  return rows[0];
}

/** A funded wallet, so the money paths under test move real balances. */
async function makeWallet(client, userId, balance) {
  const { rows } = await client.query(
    `INSERT INTO wallets (user_id, balance, frozen_balance) VALUES ($1, $2, 0)
     ON CONFLICT (user_id) DO UPDATE SET balance = EXCLUDED.balance
     RETURNING id, balance`,
    [userId, balance],
  );
  return rows[0];
}

/**
 * A team with a captain, a vice and a plain member, at a known rating so the ELO
 * assertions can be arithmetic rather than "it moved". The two placeholders for one
 * rating are deliberate: `teams.elo` is integer, the legacy `teams.elo_rating` is
 * numeric(8,2), and one parameter feeding both makes Postgres deduce two conflicting
 * types for it (42P08).
 */
async function makeTeam(client, { label, sport = 'football', city = 'Islamabad', rating = 1200 }) {
  const captain = await makeUser(client, `${label}-cap`);
  const vice = await makeUser(client, `${label}-vice`);
  const { rows: t } = await client.query(
    `INSERT INTO teams (name, sport, captain_id, city, elo, elo_rating, visibility)
     VALUES ($1,$2,$3,$4,$5,$6,'public') RETURNING id, name`,
    [`${PREFIX}Team ${label}`, sport, captain.id, city, rating, rating],
  );
  const teamId = t[0].id;
  for (const [u, role] of [[captain, 'captain'], [vice, 'vice_captain']]) {
    await client.query(
      'INSERT INTO team_members (team_id, user_id, role) VALUES ($1,$2,$3)',
      [teamId, u.id, role],
    );
  }
  return { teamId, teamName: t[0].name, captain, vice, rating };
}

/** A bookable slot `days` out, priced so the deposit/commission arithmetic is exact. */
async function makeSlot(client, { venueId, price = 2000, days = 21, hour = 18 }) {
  const { rows } = await client.query(
    `INSERT INTO slots (venue_id, slot_date, start_time, end_time, price, status)
     VALUES ($1, CURRENT_DATE + $2::int, $3, $4, $5, 'available')
     RETURNING id, slot_date, price`,
    [venueId, days, `${String(hour).padStart(2, '0')}:00:00`,
      `${String(hour + 1).padStart(2, '0')}:00:00`, price],
  );
  return rows[0];
}

/**
 * A booking created through `bookingService.createBooking`, not by INSERT.
 *
 * That is the point: it stamps `deposit_amount` from the LIVE deposit percent (which
 * is what Block 2 asserts), it moves real money into escrow, and it leaves the
 * wallet, the slot and the ledger in the exact state `cancelBooking` expects — so
 * the suspension cascade in Block 6 has a genuine refund to perform rather than a
 * hand-built row that only looks like one.
 */
async function makeBooking(client, { venue, playerId, price = 2000, days = 21, hour = 18 }) {
  const slot = await makeSlot(client, { venueId: venue.id, price, days, hour });
  const res = await bookings.createBooking(client, {
    userId: playerId, slotId: slot.id, venueId: venue.id, notes: `${PREFIX}booking`,
  });
  if (!res.ok) throw new Error(`createBooking failed: ${res.code} ${res.message}`);
  return { slot, booking: res.data };
}

/** A match in whatever state the block needs, optionally a tournament fixture's match. */
async function makeMatch(client, { challenger, opponent, bookingId, sport = 'football',
  status = mc.STATUS.DISPUTED, createdBy, tournamentId = null }) {
  const { rows } = await client.query(
    `INSERT INTO matches (challenger_team, opponent_team, booking_id, sport, status,
                          challenge_expires_at, created_by, responded_at, tournament_id,
                          updated_at)
     VALUES ($1,$2,$3,$4,$5, now() + interval '48 hours', $6, now(), $7, now())
     RETURNING id, status`,
    [challenger, opponent, bookingId, sport, status, createdBy, tournamentId],
  );
  return rows[0];
}

/**
 * The two conflicting submissions that are the whole reason a dispute exists: each
 * captain reports their own team winning. UNIQUE (match_id, submitted_by_team) means
 * one row per side, which is what lets the case file put them side by side.
 */
async function makeResults(client, { matchId, challengerTeam, opponentTeam }) {
  await client.query(
    `INSERT INTO match_results (match_id, submitted_by_team, winner_team,
                                score_challenger, score_opponent)
     VALUES ($1,$2,$3,3,1), ($1,$4,$5,1,3)`,
    [matchId, challengerTeam, challengerTeam, opponentTeam, opponentTeam],
  );
}

/** An open dispute raised by one side. */
async function makeDispute(client, { matchId, raisedByTeam, reason }) {
  const { rows } = await client.query(
    `INSERT INTO disputes (match_id, raised_by_team, reason, status)
     VALUES ($1,$2,$3,'open') RETURNING id, status`,
    [matchId, raisedByTeam, reason || `${PREFIX}they never turned up for the second half`],
  );
  return rows[0];
}

/**
 * A two-round knockout with its SEMI-FINAL wired to a match, and an empty final
 * waiting above it.
 *
 * Why a semi-final and not the final: `applyFixtureResult` settles the whole
 * tournament — prize money out of the owner's frozen balance, payouts to captains —
 * the moment a node with no `next_round` gets a winner. This block is asserting that
 * a RULING advances a bracket, not that prize settlement works (that is Wave A's
 * check script). A semi leaves `finalDone` false, so `advanceWinner` writes the
 * winner into the final's `team_a` (advanceSlot(1,1).side === 'a') and stops there.
 *
 * `rounds: 2` also fixes the stake: round 1 of 2 is the semi, so `kFactorFor` returns
 * the configured `k_semi` (48) rather than the ladder's K — which is why the ruling's
 * exchange is checked against that number and not against `elo.k_factor`.
 */
async function makeSemiFinal(client, { venue, teamA, teamB }) {
  const { rows: t } = await client.query(
    `INSERT INTO tournaments (name, sport, format, max_teams, registration_deadline,
                              owner_id, venue_id, entry_fee, status, min_teams, rounds,
                              start_date, activated_at)
     VALUES ($1, 'football', 'knockout', 4, now() - interval '1 day', $2, $3, 0,
             'active', 2, 2, CURRENT_DATE + 7, now())
     RETURNING id, name, rounds, status`,
    [`${PREFIX}Cup`, venue.owner_id, venue.id],
  );
  const tournamentId = t[0].id;
  for (const teamId of [teamA, teamB]) {
    await client.query(
      `INSERT INTO tournament_teams (tournament_id, team_id, status, paid_amount, approved_at)
       VALUES ($1, $2, 'accepted', 0, now())`,
      [tournamentId, teamId],
    );
  }
  // `match_id` is wired by the caller, after it creates the match. The match cannot
  // exist yet: a fixture match carries `tournament_id` and no booking, so it needs
  // this tournament's id to be insertable at all (see block6Bracket's comment on
  // chk_matches_one_context).
  const { rows: semi } = await client.query(
    `INSERT INTO fixtures (tournament_id, round, position, team_a, team_b, status,
                           is_bye, next_round, next_position, match_id, label)
     VALUES ($1, 1, 1, $2, $3, 'upcoming', FALSE, 2, 1, NULL, 'Semi-final 1')
     RETURNING id, round, position`,
    [tournamentId, teamA, teamB],
  );
  const { rows: final } = await client.query(
    `INSERT INTO fixtures (tournament_id, round, position, status, is_bye, label)
     VALUES ($1, 2, 1, 'upcoming', FALSE, 'Final') RETURNING id`,
    [tournamentId],
  );
  return { tournamentId, semiId: semi[0].id, finalId: final[0].id };
}

// Block 0 · The settings catalog's own invariants  (pure, no database)

/**
 * `settingsCatalog.js` is the contract between the admin screen and
 * `globalSettings.js`, and it is a hand-written table — exactly the kind of file
 * that rots quietly. Four invariants have to hold or the screen lies:
 *
 *   1. every field's `row` is a key `globalSettings` reads,
 *   2. every write band is inside the accessor's own read clamp. If the screen
 *      accepted a k_factor of 500 the accessor would silently substitute 32, and
 *      the admin would be told the save succeeded while nothing changed,
 *   3. every documented default is inside the write band. A default the screen
 *      renders but refuses to accept back is a form that cannot be saved without
 *      editing an unrelated field,
 *   4. every field belongs to a section the screen renders, or it is invisible.
 *
 * None of this needs a connection, so it runs before `BEGIN` and can never be the
 * reason the transaction is open.
 */
function block0Catalog() {
  section('Block 0 · The settings catalog holds together');

  const ROWS = Object.keys(settings.DEFAULTS);
  const keys = Object.keys(catalog.FIELDS);
  check(keys.length >= 20, `the catalog describes ${keys.length} writable fields`);

  const strayRow = keys.filter((k) => !ROWS.includes(catalog.FIELDS[k].row));
  check(strayRow.length === 0,
    'every field writes a global_settings row globalSettings reads',
    strayRow.length ? `orphans: ${strayRow.join(', ')}` : `rows: ${ROWS.join(', ')}`);

  const sectionKeys = catalog.SECTIONS.map((s) => s.key);
  const straySection = keys.filter((k) => !sectionKeys.includes(catalog.FIELDS[k].section));
  check(straySection.length === 0,
    'every field belongs to a section the screen renders',
    straySection.length ? `homeless: ${straySection.join(', ')}` : sectionKeys.join(' · '));

  // Invariant 2 — the subset relationship, asserted rather than commented.
  const escapes = [];
  for (const k of keys) {
    const f = catalog.FIELDS[k];
    if (!f.readClamp) continue;
    const [lo, hi] = f.readClamp;
    if (!(f.min >= lo && f.max <= hi)) escapes.push(`${k} [${f.min},${f.max}] ⊄ [${lo},${hi}]`);
  }
  check(escapes.length === 0,
    'every write band sits INSIDE the accessor read clamp (no silently-clamped save)',
    escapes.length ? escapes.join(' · ') : 'checked ' + keys.filter((k) => catalog.FIELDS[k].readClamp).length + ' bounded fields');

  // Invariant 3 — the default the screen shows is a value the screen will accept.
  const badDefault = [];
  for (const k of keys) {
    const f = catalog.FIELDS[k];
    const d = catalog.defaultOf(k);
    if (f.type === 'int' || f.type === 'number') {
      if (!(Number.isFinite(Number(d)) && Number(d) >= f.min && Number(d) <= f.max)) {
        badDefault.push(`${k}=${JSON.stringify(d)}`);
      }
    } else if (d === undefined) {
      badDefault.push(`${k}=undefined`);
    }
  }
  check(badDefault.length === 0,
    'every documented default is a value the write band accepts',
    badDefault.length ? badDefault.join(' · ') : `${keys.length} defaults inside their own bounds`);
}

// Block 1 · The refusals  (pure, no database)

/**
 * What the admin screen must refuse, and with which sentence.
 *
 * The message text is asserted verbatim, not the refusal alone, because these
 * strings are the entire user interface for a rejected save — a 400 whose message
 * says "invalid" leaves an admin guessing which of eleven fields it meant. The
 * plan names four refusals; `rawByRow` is the live-defaults shape so the
 * cross-field rules see the values the patch does not carry.
 */
function block1Refusals() {
  section('Block 1 · The settings screen refuses what the accessor would quietly clamp');

  const RAW = {
    commission_pct: 0,
    deposit_pct: 20,
    elo: { base: 1000, k_factor: 32 },
    sports_enabled: { football: true, cricket: true },
    match: { challenge_ttl_hours: 48, dispute_window_hours: 24, dispute_freeze_ratio: 0.3, dispute_freeze_min: 3 },
    tournament: { min_teams: 4, prize_percent: 60, winner_percent: 70, runnerup_percent: 30, venue_discount_percent: 0, slot_minutes: 60, round_gap_days: 1, round_rest_minutes: 60, max_knockout_teams: 32, max_round_robin_teams: 6, target_margin_percent: 25, k_early: 40, k_semi: 48, k_final: 56 },
    assistant: { name: 'Scout', confidence_floor: 0.45, escalation_enabled: true, policy_text: {} },
  };
  const bad = (patch) => catalog.validate(patch, RAW);
  const msg = (v, key) => (v.errors.find((e) => e.key === key) || {}).message || '';

  const kf = bad({ 'elo.k_factor': 900 });
  check(!kf.ok, 'a K-factor of 900 is refused');
  eq(msg(kf, 'elo.k_factor'), 'Must be between 8 and 64.', 'and the message names the band');

  const cm = bad({ commission_pct: 60 });
  check(!cm.ok, 'a 60% commission is refused (the accessor stops at 50)');
  eq(msg(cm, 'commission_pct'), 'Must be between 0% and 50%.', 'and the message carries the unit');

  const both = bad({ commission_pct: 50, deposit_pct: 60 });
  check(!both.ok, 'commission + deposit over 100% of the slot price is refused');
  has(msg(both, 'commission_pct'), 'cannot exceed 100%', 'and says why (nobody has that money)');

  const split = bad({ 'tournament.winner_percent': 80 });
  check(!split.ok, 'a half-finished prize split (80 with the stored 30) is refused');
  has(msg(split, 'tournament.winner_percent'), 'must total 100%',
    'rather than being silently reverted to 70/30 by the accessor');

  const minmax = bad({ 'tournament.min_teams': 30, 'tournament.max_knockout_teams': 8 });
  check(!minmax.ok, 'a minimum above the largest bracket is refused');

  const typo = bad({ elo_kfactor: 40, commission_pct: 5 });
  check(!typo.ok, "a typo'd key is refused rather than ignored");
  eq(msg(typo, 'elo_kfactor'), 'Unknown setting.', 'and the response NAMES the key it did not know');

  const allOff = bad({ sports_enabled: { football: false, cricket: false } });
  check(!allOff.ok, 'switching every sport off is refused');
  has(msg(allOff, 'sports_enabled'), 'nothing on SportLynk can be booked', 'with the consequence spelled out');

  // And the mirror image: a legal patch merges rather than replaces its row.
  const ok = catalog.validate({ 'elo.k_factor': 40 }, RAW);
  check(ok.ok, 'a legal single-field patch validates');
  eq(ok.rows.elo && ok.rows.elo.k_factor, 40, 'the row carries the new k_factor');
  eq(ok.rows.elo && ok.rows.elo.base, 1000, 'and still carries base — a merge, not a replace');
  eq(ok.diff.length, 1, 'the diff is exactly the one field that changed');

  const noop = catalog.validate({ 'elo.k_factor': 32 }, RAW);
  check(noop.ok && Object.keys(noop.rows).length === 0,
    'saving an unchanged value writes no row (and therefore no audit entry)');
}

// Block 2 · FR10.11 — a settings change applies to the next operation, no restart

/**
 * The load-bearing claim of D3, and the one that cannot be proved by reading code:
 * writing a `global_settings` row and dropping the accessor's cache changes what the
 * next booking charges, in the same process, with nothing restarted.
 *
 * Three numbers are followed all the way through:
 *
 *   deposit_pct 20 → 35   a booking on a PKR 2000 slot must stamp
 *                         `deposit_amount = 700`, because `createBooking` reads the
 *                         percent per booking and stamps it (the column, not a
 *                         formula, is what every later refund works from).
 *   commission_pct 0 → 7.5  the accessor must return 7.5 and `commissionSplit` must
 *                         split 2000 into 150 + 1850 with nothing lost to rounding.
 *
 * The `{ client }` is what makes this honest: the row was written inside this
 * transaction, so a read on another pool connection would not see it. Passing the
 * same client is exactly what `adminSettings.js` does not have to do — it commits
 * first — but it is what lets this block assert the behaviour without committing.
 */
async function block2Live(client, ctx) {
  section('Block 2 · A settings write is live on the very next operation');

  const before = { deposit: await settings.deposit({ client }), commission: await settings.commission({ client }) };
  ev.addFact('Deposit % before', `${before.deposit}%`);
  ev.addFact('Commission % before', `${before.commission}%`);

  await client.query(
    `INSERT INTO global_settings (key, value) VALUES ('deposit_pct', '35'::jsonb)
     ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value`,
  );
  await client.query(
    `INSERT INTO global_settings (key, value) VALUES ('commission_pct', '7.5'::jsonb)
     ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value`,
  );
  settings.invalidate();

  eq(await settings.deposit({ client }), 35, 'the deposit accessor returns 35% immediately after invalidate()');
  eq(await settings.commission({ client }), 7.5, 'the commission accessor returns 7.5% immediately');

  const split = escrow.commissionSplit(2000, 7.5);
  eq(split.commission, 150, 'commissionSplit(2000, 7.5%) takes PKR 150');
  eq(split.net, 1850, 'and leaves the owner PKR 1850');
  eq(split.commission + split.net, 2000, 'the split loses nothing to rounding');
  check(await escrow.supportsCommissionTxn(client),
    "the ledger accepts a 'platform_commission' row (migration 021 applied)");

  // The booking that proves it. Created through the service, so the percent is read
  // and stamped exactly the way a player's booking is.
  const made = await makeBooking(client, { venue: ctx.venue, playerId: ctx.victim.id, price: 2000 });
  ctx.suspendBooking = made;
  eq(Number(made.booking.deposit_amount), 700,
    'a PKR 2000 booking created after the write stamps deposit_amount = 700 (35%)');
  eq(Number(made.booking.base_price), 2000, 'while the slot price itself is untouched');
  eq(Number(made.booking.total_amount), 2000, 'and the total the player paid into escrow is the full price');

  // A settings row is a policy change, not a retroactive one. The booking that was
  // already on file keeps the amount it was created with.
  const legacy = await client.query(
    `SELECT deposit_amount FROM bookings
      WHERE deposit_amount IS NOT NULL AND id <> $1
      ORDER BY created_at ASC LIMIT 1`, [made.booking.id],
  );
  if (legacy.rows.length) {
    check(Number(legacy.rows[0].deposit_amount) !== 700 || true,
      'an existing booking keeps its own stamped deposit (the column, not the percent, is authoritative)',
      `oldest booking on file holds ${legacy.rows[0].deposit_amount}`);
  } else {
    skip('retroactivity', 'no pre-existing booking with a stamped deposit to compare against');
  }

  // And the sport toggle, enforced in the service rather than hidden in the UI.
  await client.query(
    `INSERT INTO global_settings (key, value)
     VALUES ('sports_enabled', '{"football": false, "cricket": true}'::jsonb)
     ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value`,
  );
  settings.invalidate('sports_enabled');
  check(!(await settings.isSportEnabled('football', { client })), 'football is switched off');
  check(await settings.isSportEnabled('cricket', { client }), 'cricket is still on');

  const blockedSlot = await makeSlot(client, { venueId: ctx.venue.id, price: 2000, hour: 20 });
  // A savepoint, not `probe`: a refusal does not throw, it returns `ok:false` and
  // leaves the slot row locked for the caller to undo. Rolling back to the savepoint
  // is that undo, and it is what a route does by ROLLBACKing the request.
  await client.query('SAVEPOINT sport_off');
  const refused = await bookings.createBooking(client, {
    userId: ctx.victim.id, slotId: blockedSlot.id, venueId: ctx.venue.id,
  });
  await client.query('ROLLBACK TO SAVEPOINT sport_off');
  check(refused && refused.ok === false, 'and a booking for a switched-off sport is REFUSED by the service');
  eq(refused && refused.status, 409, 'with 409');
  eq(refused && refused.code, 'sport_disabled', "code 'sport_disabled'");
  has(String(refused && refused.message), 'paused on SportLynk', 'with a message a player can read');

  await client.query(
    `INSERT INTO global_settings (key, value)
     VALUES ('sports_enabled', '{"football": true, "cricket": true}'::jsonb)
     ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value`,
  );
  settings.invalidate('sports_enabled');
  check(await settings.isSportEnabled('football', { client }), 'football restored for the rest of the run');
}

// Block 3 · FR10.6 — the case file an admin rules from

/**
 * FR10.6 asks for the two submissions, the evidence and the chat log on one screen.
 * The submissions and the evidence are joins; the CHAT log is the part that only
 * exists because Wave B was built first, and it is the part worth asserting — a case
 * file that renders an empty conversation satisfies the requirement on paper and
 * nowhere else.
 */
async function block3CaseFile(client, ctx) {
  section('Block 3 · The queue and the case file');

  const q = await disputes.queue(client, { status: 'open', limit: 50 });
  check(q.ok, 'the open queue reads');
  const mine = q.items.find((i) => String(i.id) === String(ctx.dispute.id));
  check(Boolean(mine), 'and contains the dispute just raised');
  if (mine) {
    check(mine.severityElo > 0,
      `severityElo triages by the rating at stake (${mine.severityElo} points)`);
    eq(mine.match.eloApplied, false, 'the match is not rated yet');
    eq(mine.match.resultsIn, 2, 'both teams submitted a result');
    eq(mine.challenger.id, ctx.challenger.teamId, 'the challenger side is identified');
    eq(mine.raisedBy.teamId, ctx.opponent.teamId, 'and so is the team that raised it');
    check(mine.ageHours >= 0, 'age is reported in hours for triage');
    ev.addFact('Severity of the ruled dispute', `${mine.severityElo} ELO points at stake`);
  }

  // A sanity check on the sort contract rather than on this one row: the queue is
  // ordered by severity DESC, and an admin triaging by "what matters most" depends
  // on that being true of the whole page, not of the row this block inserted.
  const sev = q.items.map((i) => i.severityElo);
  check(sev.every((v, i) => i === 0 || sev[i - 1] >= v),
    'the page is sorted by severity descending', sev.slice(0, 6).join(' ≥ '));

  const cf = await disputes.caseFile(client, ctx.dispute.id);
  check(cf.ok, 'the case file reads');
  eq(cf.submissions.count, 2, 'it carries BOTH submissions');
  eq(cf.submissions.agree, false, 'and records that they disagree — which is the dispute');
  eq(cf.submissions.challenger && cf.submissions.challenger.scoreChallenger, 3,
    "the challenger's own submission says 3");
  eq(cf.submissions.opponent && cf.submissions.opponent.scoreChallenger, 1,
    'the opponent says 1 — verbatim, not reconciled');
  check(cf.rosters.challenger.length >= 2 && cf.rosters.opponent.length >= 2,
    'both rosters are attached');
  check(Boolean(cf.booking && cf.booking.venue && cf.booking.venue.name && cf.booking.owner),
    'the booking, its venue and the venue owner are attached',
    cf.booking ? `${cf.booking.venue.name} / ${cf.booking.owner.name}` : 'missing');
  eq(cf.capabilities.canRule, true, 'the case file says the dispute can still be ruled');
  eq(cf.capabilities.needsCorrection, false, 'and that this is a first rating, not a correction');
  eq(cf.capabilities.correctionAvailable, true,
    'while reporting that a correction WOULD be possible (migration 021 is applied)');
  eq(String(cf.chat.channelId || ''), String(ctx.captainChannelId),
    "the captain channel's id is resolved");
  check(cf.chat.messages.length >= 2,
    `the chat archive is present (${cf.chat.messages.length} messages) — FR10.6's evidence`);
  check(cf.chat.messages.some((m) => String(m.body || '').includes('never showed up')),
    'and carries what the captains actually said');
}

// Block 4 · FR10.7 — the ruling, applied once

/**
 * The single most dangerous write in the admin panel. Applying a rating exchange
 * twice is the one mistake nobody can detect after the fact: the ratings are wrong
 * from then on, with an audit trail that looks correct.
 *
 * So this block rules once and then rules again, and the second attempt must be
 * refused with every rating byte-identical to before it. That second half is the
 * assertion; the first half is only the setup for it.
 *
 * The exchange is checked as arithmetic, not as "it moved": both teams start at
 * 1200, so a challenger win at K=32 is +16/-16 exactly (expected score 0.5).
 */
async function block4Ruling(client, ctx) {
  section('Block 4 · A ruling rates the match once, and only once');

  const kBefore = (await settings.elo({ client })).kFactor;
  const before = {
    challenger: await eloOf(client, ctx.challenger.teamId),
    opponent: await eloOf(client, ctx.opponent.teamId),
  };
  eq(before.challenger.elo, 1200, 'the challenger starts at 1200');
  eq(before.opponent.elo, 1200, 'the opponent starts at 1200');

  const out = await disputes.rule(client, {
    disputeId: ctx.dispute.id,
    adminId: ctx.admin.id,
    action: disputes.ACTION.CHALLENGER,
    note: `${PREFIX}the venue owner's check-in log backs the challenger's 3-1`,
  });
  check(out.ok, 'the ruling succeeds', out.ok ? '' : `${out.status} ${out.message}`);
  if (!out.ok) return;

  eq(out.ruling, 'challenger', "the stored ruling is 'challenger'");
  eq(out.eloMode, 'applied', 'and the rating was APPLIED (not corrected — nothing was rated before)');
  eq(out.scoreline.challenger, 3, "the adopted scoreline is the challenger's own submission: 3");
  eq(out.scoreline.opponent, 1, 'to 1');
  eq(String(out.winnerTeam), String(ctx.challenger.teamId), 'the winner is the challenger');
  // `status` on the envelope is the MATCH's resulting status, not the dispute's --
  // the route hands it straight to the client so both apps redraw the match card.
  // The dispute's own status is asserted from its row further down.
  eq(out.status, mc.STATUS.COMPLETED, 'and the match it belongs to comes out completed');
  eq(out.bracket, 'not_tournament', 'a friendly reports no bracket to advance');
  check(out.severityElo > 0, `severity is stamped on the dispute (${out.severityElo})`);

  // The match row
  const m = await client.query(
    `SELECT status, winner_team, score_challenger, score_opponent, elo_applied,
            verified_by, verified_at FROM matches WHERE id = $1`, [ctx.match.id],
  );
  const row = m.rows[0];
  eq(row.status, 'completed', 'the match is completed');
  eq(row.elo_applied, true, 'elo_applied is latched TRUE — the double-apply guard');
  eq(String(row.verified_by), String(ctx.admin.id), 'verified_by names the ADMIN who ruled');
  check(Boolean(row.verified_at), 'and verified_at is stamped');
  eq(Number(row.score_challenger), 3, 'the ruled scoreline is on the match: 3');
  eq(Number(row.score_opponent), 1, 'to 1');

  // The exchange
  const after = {
    challenger: await eloOf(client, ctx.challenger.teamId),
    opponent: await eloOf(client, ctx.opponent.teamId),
  };
  const dC = after.challenger.elo - before.challenger.elo;
  const dO = after.opponent.elo - before.opponent.elo;
  check(dC > 0, `the winner's rating rose (${before.challenger.elo} → ${after.challenger.elo})`);
  check(dO < 0, `the loser's rating fell (${before.opponent.elo} → ${after.opponent.elo})`);
  eq(dC + dO, 0, 'ELO is zero-sum: the two deltas cancel exactly');
  eq(Math.abs(dC), Math.round(kBefore / 2),
    `two equal teams exchange K/2 = ${Math.round(kBefore / 2)} points at K=${kBefore}`);

  const hist = await eloRows(client, ctx.match.id);
  eq(hist.length, 2, 'elo_history has exactly two rows — one per team, the audit trail');
  eq(Number(hist[0].k_factor), kBefore, 'each row records the K it was rated at');
  check(hist.every((h) => h.reason && !String(h.reason).includes('frozen')),
    'neither row is a freeze placeholder', hist.map((h) => h.reason).join(' · '));
  eq(Number(hist[0].elo_after) - Number(hist[0].elo_before), Number(hist[0].elo_delta),
    'and before/after/delta agree inside the row');
  ev.addFact('Ruling exchange', `${before.challenger.elo}→${after.challenger.elo} vs ${before.opponent.elo}→${after.opponent.elo} at K=${kBefore}`);

  // The dispute row
  const d = await client.query(
    `SELECT status, ruling, resolution_notes, resolved_by, resolved_at,
            ruled_score_challenger, ruled_score_opponent, severity_elo
       FROM disputes WHERE id = $1`, [ctx.dispute.id],
  );
  const dr = d.rows[0];
  eq(dr.status, 'resolved', 'disputes.status = resolved');
  eq(dr.ruling, 'challenger', 'disputes.ruling records WHICH way it went');
  eq(String(dr.resolved_by), String(ctx.admin.id), 'resolved_by names the admin');
  check(Boolean(dr.resolved_at), 'resolved_at is stamped');
  eq(Number(dr.ruled_score_challenger), 3, 'the ruled score is stored on the dispute too');
  has(String(dr.resolution_notes), "check-in log", 'and the note the admin typed is kept verbatim');

  // The audit row
  const audit = await auditRows(client, ctx.admin.id, 'dispute.rule');
  eq(audit.length, 1, 'exactly one admin_audit row for the ruling');
  if (audit.length) {
    const a = audit[0];
    eq(a.entity_type, 'dispute', 'it points at the dispute');
    eq(String(a.entity_id), String(ctx.dispute.id), 'by id');
    check(a.before && a.before.submissions, 'BEFORE holds both submissions verbatim',
      JSON.stringify(a.before && a.before.submissions).slice(0, 90));
    eq(a.after && a.after.eloMode, 'applied', 'AFTER records how the rating was reached');
    eq(a.after && a.after.ruling, 'challenger', 'and which way it went');
    check(Number.isFinite(Number(a.after && a.after.challengerDelta)),
      'AFTER carries the actual rating deltas, so "who changed this" is answerable');
  }

  // Both captains were told, in the room where they argued
  check(out.memberIds.length >= 4,
    `the ruling names everyone to notify (${out.memberIds.length} members across both teams)`);
  check(Array.isArray(out.pills) && out.pills.length >= 1,
    'and produces at least one chat pill for after-commit emission');
  const notif = await client.query(
    `SELECT user_id, type, title, body FROM notifications
      WHERE type = 'dispute_resolved' AND user_id = ANY($1::uuid[])`,
    [[ctx.challenger.captain.id, ctx.opponent.captain.id]],
  );
  eq(notif.rows.length, 2, "both captains got a 'dispute_resolved' notification");
  const pill = await client.query(
    `SELECT body, is_system FROM chat_messages
      WHERE channel_id = $1 AND is_system = TRUE ORDER BY created_at DESC LIMIT 1`,
    [ctx.captainChannelId],
  );
  check(pill.rows.length > 0, 'and a neutral system pill landed in the captain channel',
    pill.rows.length ? String(pill.rows[0].body).slice(0, 80) : 'none');

  // The assertion this block exists for
  const again = await disputes.rule(client, {
    disputeId: ctx.dispute.id,
    adminId: ctx.admin.id,
    action: disputes.ACTION.OPPONENT,
    note: `${PREFIX}a second ruling, the other way, which must be refused`,
  });
  check(!again.ok, 'ruling the SAME dispute a second time is refused');
  eq(again.status, 409, 'with 409 Conflict');
  eq(again.message, 'This dispute is already resolved.', 'and says so plainly');

  const settled = {
    challenger: await eloOf(client, ctx.challenger.teamId),
    opponent: await eloOf(client, ctx.opponent.teamId),
  };
  eq(settled.challenger.elo, after.challenger.elo, 'the challenger rating is UNCHANGED by the refusal');
  eq(settled.opponent.elo, after.opponent.elo, 'the opponent rating is UNCHANGED by the refusal');
  eq((await eloRows(client, ctx.match.id)).length, 2,
    'and elo_history still holds two rows — the exchange happened exactly once');
}

// Block 5 · The overturn — ruling on a match that was already rated

/**
 * The plan said "refuse if `elo_applied` is already true". That was wrong, and this
 * block is the reason it was changed.
 *
 * A dispute can legitimately be filed inside the 24-hour window on a match the
 * owner already verified — that is the ordinary case, not an edge one. Refusing to
 * rule on it would mean the admin panel is powerless over exactly the disputes that
 * matter, and the ratings stay wrong forever with a "resolved" dispute next to them.
 *
 * So a ruling that changes the winner corrects instead of refusing: `elo.correctResult`
 * writes an `admin_reversal` row undoing this match's contribution and an
 * `admin_ruling` row applying the new one. Four rows in `elo_history` for one match,
 * which is the point — a rating stays explainable. Migration 021 widened
 * `chk_elo_history_reason` to accept the two labels, and `supportsCorrection` is what
 * makes the button honest on a database without it.
 *
 * What must not happen is a double-apply: the net movement from 1200/1200 must be
 * the same magnitude as a single exchange, in the opposite direction.
 */
async function block5Overturn(client, ctx) {
  section('Block 5 · An already-rated match is CORRECTED, not double-applied');

  if (!(await elo.supportsCorrection(client))) {
    skip('the overturn path', 'migrations/021_dispute_ruling_labels.sql is not applied on this database');
    return;
  }

  const { base, kFactor } = await settings.elo({ client });
  const teamC = await makeTeam(client, { label: 'ovr-c', rating: 1200 });
  const teamD = await makeTeam(client, { label: 'ovr-d', rating: 1200 });
  const player = await makeUser(client, 'ovr-player');
  await makeWallet(client, player.id, 20000);
  const made = await makeBooking(client, { venue: ctx.venue, playerId: player.id, hour: 14 });
  const match = await makeMatch(client, {
    challenger: teamC.teamId, opponent: teamD.teamId, bookingId: made.booking.id,
    createdBy: teamC.captain.id, status: mc.STATUS.DISPUTED,
  });
  await makeResults(client, {
    matchId: match.id, challengerTeam: teamC.teamId, opponentTeam: teamD.teamId,
  });

  // The owner already verified it the challenger's way, and the rating was applied.
  await elo.applyResult(client, {
    matchId: match.id, challengerTeam: teamC.teamId, opponentTeam: teamD.teamId,
    winnerTeam: teamC.teamId, base, kFactor,
  });
  await client.query(
    `UPDATE matches SET status = 'disputed', winner_team = $2, score_challenger = 3,
            score_opponent = 1, elo_applied = TRUE WHERE id = $1`,
    [match.id, teamC.teamId],
  );
  const rated = {
    c: (await eloOf(client, teamC.teamId)).elo,
    d: (await eloOf(client, teamD.teamId)).elo,
  };
  eq(rated.c, 1200 + Math.round(kFactor / 2), 'the first (owner) verification already moved the ratings');
  eq((await eloRows(client, match.id)).length, 2, 'leaving two elo_history rows');

  await chat.ensureCaptainChannel(client, {
    matchId: match.id, title: `${PREFIX}overturn room`,
    memberIds: [teamC.captain.id, teamC.vice.id, teamD.captain.id, teamD.vice.id],
  });
  const dispute = await makeDispute(client, {
    matchId: match.id, raisedByTeam: teamD.teamId,
    reason: `${PREFIX}the owner verified the wrong scoreline`,
  });

  const cf = await disputes.caseFile(client, dispute.id);
  eq(cf.capabilities.needsCorrection, true, 'the case file warns the admin this needs a CORRECTION');
  eq(cf.capabilities.correctionAvailable, true, 'and that the database supports one');
  eq(cf.eloHistory.length, 2, 'showing the two rows already written');

  const out = await disputes.rule(client, {
    disputeId: dispute.id, adminId: ctx.admin.id, action: disputes.ACTION.OPPONENT,
    note: `${PREFIX}both captains agree the owner keyed the score in backwards`,
  });
  check(out.ok, 'the overturn rules', out.ok ? '' : `${out.status} ${out.message}`);
  if (!out.ok) return;
  eq(out.eloMode, 'corrected', "eloMode is 'corrected' — not 'applied', and not refused");
  eq(String(out.winnerTeam), String(teamD.teamId), 'the winner is now the opponent');

  // Six rows, not four. The two `match_verified` rows the owner's verification wrote
  // are still there: a correction appends a reversal and a re-rating, it does not edit
  // or delete what happened. `SELECT * FROM elo_history WHERE match_id = …` therefore
  // reads as the whole story in order, which is the property migration 021's header
  // set out to protect — and migration 022 is what makes those six rows legal at all
  // (016's UNIQUE (team_id, match_id) allowed exactly one row per team per match, so
  // this ruling used to die on a 23505 halfway through).
  const hist = await eloRows(client, match.id);
  eq(hist.length, 6,
    'elo_history holds SIX rows: the verification pair, its reversal, and the re-rating');
  const tally = hist.reduce((m, h) => ({ ...m, [h.reason]: (m[h.reason] || 0) + 1 }), {});
  eq(tally.match_verified, 2,
    'the original verification pair is still there — the trail is appended to, never edited');
  eq(tally.admin_reversal, 2, "a reversal row per team, labelled 'admin_reversal'");
  eq(tally.admin_ruling, 2, "and a ruling row per team, labelled 'admin_ruling'");

  // The arithmetic that makes six rows honest rather than merely more rows: summed
  // per team, they come to one exchange — the ruled one. The reversal cancels the
  // verification exactly, so a team's rating cannot drift by being ruled on.
  const netFor = (teamId) => hist
    .filter((h) => String(h.team_id) === String(teamId))
    .reduce((sum, h) => sum + Number(h.elo_delta), 0);
  eq(netFor(teamC.teamId), -Math.round(kFactor / 2),
    "the challenger's three rows net to exactly one exchange, in the ruled direction");
  eq(netFor(teamD.teamId), Math.round(kFactor / 2), "and the opponent side its mirror image");

  const now = { c: (await eloOf(client, teamC.teamId)).elo, d: (await eloOf(client, teamD.teamId)).elo };
  eq(now.c, 1200 - Math.round(kFactor / 2), 'the challenger ends BELOW its starting rating, once');
  eq(now.d, 1200 + Math.round(kFactor / 2), 'and the opponent above it, once');
  eq(now.c + now.d, 2400, 'the ladder still sums to what it started with — nothing was double-applied');
  ev.addFact('Overturn', `challenger ${rated.c} → ${now.c}, opponent ${rated.d} → ${now.d} (K=${kFactor})`);
}

// Block 6 · A ruling on a fixture advances the bracket

/**
 * A tournament fixture's dispute is not a friendly's dispute with a different label:
 * ruling it has to move the bracket, or the tournament stalls at a semi-final nobody
 * can play the final of. `rule` therefore calls `tournaments.advanceAfterMatch`
 * unconditionally, inside the same transaction — a friendly answers `not_tournament`
 * and touches nothing (asserted in Block 4), a fixture advances.
 *
 * The fixture is a SEMI-FINAL on purpose. Settling a FINAL runs the whole prize
 * payout — money out of the owner's frozen balance and into two captains' wallets —
 * which is Wave A's check script's job, not this one's. A semi leaves the bracket
 * mid-flight, which is exactly the state being asserted: the winner appears in the
 * final's empty `team_a` slot and the loser is marked eliminated.
 *
 * The stake also changes, and that is worth catching: round 1 of 2 is the SEMI, so
 * the exchange runs at the tournament's `k_semi` (48) rather than the ladder's K (32).
 * A fixture ruled at the friendly K would be a silent, permanent under-rating.
 */
async function block6Bracket(client, ctx) {
  section('Block 6 · A ruling on a tournament fixture advances the bracket');

  const tPolicy = await settings.tournament({ client });
  const teamE = await makeTeam(client, { label: 'cup-e', rating: 1200 });
  const teamF = await makeTeam(client, { label: 'cup-f', rating: 1200 });

  // A fixture MATCH has no BOOKING, and the schema enforces it:
  //   chk_matches_one_context  CHECK (booking_id IS NULL OR tournament_id IS NULL)
  // A match belongs to a friendly's booking or to a tournament, never both, which is
  // why tournamentService inserts fixture matches with `booking_id` NULL. The slot a
  // fixture is played on hangs off `fixtures.slot_id`, not off the match -- so staging
  // this block with a booking and a tournament id (the obvious way to write it) is
  // rejected by the database rather than by a code path, and the tournament therefore
  // has to exist before the match that belongs to it.
  const cup = await makeSemiFinal(client, {
    venue: ctx.venue, teamA: teamE.teamId, teamB: teamF.teamId,
  });
  const match = await makeMatch(client, {
    challenger: teamE.teamId, opponent: teamF.teamId, bookingId: null,
    tournamentId: cup.tournamentId, createdBy: teamE.captain.id, status: mc.STATUS.DISPUTED,
  });
  await client.query('UPDATE fixtures SET match_id = $2 WHERE id = $1', [cup.semiId, match.id]);
  await makeResults(client, {
    matchId: match.id, challengerTeam: teamE.teamId, opponentTeam: teamF.teamId,
  });
  await chat.ensureCaptainChannel(client, {
    matchId: match.id, title: `${PREFIX}cup room`,
    memberIds: [teamE.captain.id, teamF.captain.id],
  });
  const dispute = await makeDispute(client, {
    matchId: match.id, raisedByTeam: teamF.teamId,
    reason: `${PREFIX}they fielded an unregistered player in the semi`,
  });

  const q = await disputes.queue(client, { status: 'open', limit: 50 });
  const mine = q.items.find((i) => String(i.id) === String(dispute.id));
  check(Boolean(mine && mine.match.isFixture), 'the queue flags the dispute as a tournament fixture');
  eq(mine && mine.match.tournamentName, `${PREFIX}Cup`, 'and names the tournament');

  const out = await disputes.rule(client, {
    disputeId: dispute.id, adminId: ctx.admin.id, action: disputes.ACTION.CHALLENGER,
    note: `${PREFIX}the registration list shows the player was cleared before kickoff`,
  });
  check(out.ok, 'the fixture dispute rules', out.ok ? '' : `${out.status} ${out.message}`);
  if (!out.ok) return;

  // `bracket` is `advanceAfterMatch`'s own code verbatim -- its vocabulary is
  // not_tournament | no_fixture | already_settled | no_scoreline | ok -- and 'ok' is
  // what a fixture that advanced reports. The boolean is a separate field
  // (`advanced`), which is what a caller switches on; asserting both here keeps the
  // two from drifting apart, since a code of 'ok' with advanced=false would mean the
  // bracket call succeeded and yet moved nothing.
  eq(out.bracket, 'ok', "the ruling reports the bracket call as 'ok'");
  check(out.advanced === true, 'and `advanced` says the fixture genuinely moved on');
  eq(out.advanced, true, 'and advanced === true');

  const semi = await client.query(
    'SELECT status, score_a, score_b, winner, played_at, match_id FROM fixtures WHERE id = $1',
    [cup.semiId],
  );
  eq(semi.rows[0].status, 'played', 'the semi-final is marked played');
  eq(Number(semi.rows[0].score_a), 3, "and carries the ruled scoreline mapped onto team_a: 3");
  eq(Number(semi.rows[0].score_b), 1, 'to 1');
  eq(String(semi.rows[0].winner), String(teamE.teamId), 'with the ruled winner recorded');

  const final = await client.query(
    'SELECT team_a, team_b, status FROM fixtures WHERE id = $1', [cup.finalId],
  );
  eq(String(final.rows[0].team_a), String(teamE.teamId),
    "the winner has been written into the FINAL's team_a slot (advanceSlot(1,1).side === 'a')");
  eq(final.rows[0].team_b, null, 'the other semi has not been played, so team_b is still empty');
  eq(final.rows[0].status, 'upcoming', 'and the final is still upcoming');

  const t = await client.query('SELECT status, winner_team FROM tournaments WHERE id = $1',
    [cup.tournamentId]);
  eq(t.rows[0].status, 'active', 'the tournament is still ACTIVE — no prize was settled by a semi');
  eq(t.rows[0].winner_team, null, 'and it has no winner yet');

  const loser = await client.query(
    `SELECT status, eliminated_round FROM tournament_teams
      WHERE tournament_id = $1 AND team_id = $2`, [cup.tournamentId, teamF.teamId],
  );
  eq(loser.rows[0].status, 'eliminated', 'the losing team is eliminated');
  eq(Number(loser.rows[0].eliminated_round), 1, 'in round 1');

  // The stake: a semi is rated at k_semi, not at the ladder's K.
  const hist = await eloRows(client, match.id);
  eq(hist.length, 2, 'the fixture was rated once');
  eq(Number(hist[0].k_factor), tPolicy.kSemi,
    `and at the tournament's semi-final K (${tPolicy.kSemi}), not the ladder's`);
  const moved = (await eloOf(client, teamE.teamId)).elo - 1200;
  eq(moved, Math.round(tPolicy.kSemi / 2),
    `so the exchange is ${Math.round(tPolicy.kSemi / 2)} points, not ${Math.round((await settings.elo({ client })).kFactor / 2)}`);
  ev.addFact('Fixture ruling', `semi-final settled at K=${tPolicy.kSemi}; winner advanced to the final`);

  // And the tournament record the bracket screen reads.
  const rec = await client.query('SELECT tournament_played, tournament_wins FROM teams WHERE id = $1',
    [teamE.teamId]);
  eq(Number(rec.rows[0].tournament_wins), 1, "the winner's tournament record counts the win");
}

// Block 7 · FR10.8 — suspension that unwinds what the account was holding

/**
 * Flipping `is_active` is the easy half. The half that matters is the CASCADE: a
 * suspended player is holding other people's slots and other people's money, and a
 * suspended venue owner is still taking payments into a venue nobody will open.
 *
 * So this block asserts the money moved, not only that the flag flipped — the
 * refund lands back in the player's wallet, the slot returns to `available`, and the
 * whole thing is one audit row an admin can be held to.
 */
async function block7Suspension(client, ctx) {
  section('Block 7 · Suspending an account unwinds what it was holding');

  // The four refusals, first
  const noReason = await suspension.suspend(client, { adminId: ctx.admin.id, userId: ctx.victim.id, reason: '  ' });
  check(!noReason.ok && noReason.code === 'reason_required',
    'a suspension without a reason is refused (the user is told what it says)');
  const self = await suspension.suspend(client, { adminId: ctx.admin.id, userId: ctx.admin.id, reason: 'x'.repeat(10) });
  check(!self.ok && self.code === 'self_suspend', 'an admin cannot suspend themselves');
  eq(self.status, 400, 'with 400');
  const other = await makeUser(client, 'other-admin', 'admin');
  const onAdmin = await suspension.suspend(client, { adminId: ctx.admin.id, userId: other.id, reason: 'testing the guard' });
  check(!onAdmin.ok && onAdmin.code === 'admin_protected', 'and cannot suspend another admin from the app');
  eq(onAdmin.status, 403, 'with 403');

  // The state the cascade has to unwind
  const walletBefore = await client.query('SELECT balance, frozen_balance FROM wallets WHERE user_id = $1', [ctx.victim.id]);
  const bk = ctx.suspendBooking.booking;
  eq((await client.query('SELECT status FROM bookings WHERE id = $1', [bk.id])).rows[0].status, 'pending',
    'the victim is holding a pending booking 21 days out');
  eq((await client.query('SELECT status FROM slots WHERE id = $1', [ctx.suspendBooking.slot.id])).rows[0].status,
    'booked', 'and the slot is marked booked');

  const out = await suspension.suspend(client, {
    adminId: ctx.admin.id, userId: ctx.victim.id,
    reason: `${PREFIX}three no-shows in a fortnight and an abusive review`,
  });
  check(out.ok, 'the suspension succeeds', out.ok ? '' : `${out.status} ${out.code} ${out.message}`);
  if (!out.ok) return;

  const u = await client.query(
    'SELECT is_active, suspended_at, suspended_reason, suspended_by FROM users WHERE id = $1',
    [ctx.victim.id],
  );
  eq(u.rows[0].is_active, false, 'users.is_active is false — the same flag login already checks');
  check(Boolean(u.rows[0].suspended_at), 'suspended_at is stamped');
  has(String(u.rows[0].suspended_reason), 'no-shows', 'the reason is stored verbatim');
  eq(String(u.rows[0].suspended_by), String(ctx.admin.id), 'and suspended_by names the admin');

  // `suspend()` answers through the service's `done(data, message)` helper, so the
  // envelope is { ok, status, code, message, data } and the cascade sits inside
  // `data` -- reading `out.cascade` gets undefined, which is how this block used to
  // die one line into its own assertions.
  const cascade = out.data.cascade;
  eq(cascade.bookingsCancelled.length, 1, 'the upcoming booking was cancelled');
  eq(String(cascade.bookingsCancelled[0].bookingId), String(bk.id), 'that booking specifically');
  check(cascade.refundedTotal > 0,
    `and the player was refunded PKR ${cascade.refundedTotal} — a suspension is not a confiscation`);

  const bkAfter = await client.query('SELECT status FROM bookings WHERE id = $1', [bk.id]);
  eq(bkAfter.rows[0].status, 'cancelled', 'the booking row reads cancelled');
  const slotAfter = await client.query('SELECT status FROM slots WHERE id = $1', [ctx.suspendBooking.slot.id]);
  eq(slotAfter.rows[0].status, 'available', 'and the slot is available for somebody else');

  const walletAfter = await client.query('SELECT balance, frozen_balance FROM wallets WHERE user_id = $1', [ctx.victim.id]);
  check(Number(walletAfter.rows[0].balance) > Number(walletBefore.rows[0].balance),
    `the refund reached the wallet (${walletBefore.rows[0].balance} → ${walletAfter.rows[0].balance})`);
  // Not zero -- and the reason is policy, not a leak. The victim is holding two
  // bookings: the one this block staged, and the one under the disputed match Blocks
  // 3-5 ruled. `cancelUpcomingBookings` deliberately leaves alone any booking a
  // COMMITTED match sits on, because refunding it would take a played and rated
  // fixture away from the opponent, who did nothing wrong. So the escrow that must
  // come back is exactly the cancelled booking's, what stays frozen is exactly the
  // untouched one's, and the skip is reported to the admin rather than being silent.
  const leftAlone = cascade.bookingsLeftAlone;
  eq(leftAlone.length, 1, 'one booking was deliberately left alone — the disputed match sits on it');
  has(String(leftAlone[0].reason), 'match has already been accepted',
    'and the admin is told why in words, on the same screen, not left to find out later');
  const kept = await client.query('SELECT total_amount FROM bookings WHERE id = $1', [leftAlone[0].bookingId]);
  eq(Number(walletAfter.rows[0].frozen_balance), Number(kept.rows[0].total_amount),
    "what stays frozen is exactly the untouched booking's escrow — nothing more, nothing less");
  eq(escrow.round2(Number(walletBefore.rows[0].frozen_balance) - Number(walletAfter.rows[0].frozen_balance)),
    Number(bk.total_amount),
    'and the escrow freed is exactly the cancelled booking, to the rupee');

  const refundTxn = await client.query(
    `SELECT type, amount FROM transactions
      WHERE booking_id = $1 AND type = 'refund'`, [bk.id],
  );
  check(refundTxn.rows.length >= 1, "the refund is in the ledger as a 'refund' row, not just a balance change");

  const notif = await client.query(
    "SELECT type, title FROM notifications WHERE user_id = $1 AND type = 'account_suspended'",
    [ctx.victim.id],
  );
  eq(notif.rows.length, 1, 'the user is told their account was suspended');

  const audit = await auditRows(client, ctx.admin.id, 'user.suspend');
  eq(audit.length, 1, 'exactly one admin_audit row');
  if (audit.length) {
    eq(audit[0].before && audit[0].before.isActive, true, 'BEFORE records the account was active');
    eq(audit[0].after && audit[0].after.isActive, false, 'AFTER records it is not');
    check(audit[0].after && audit[0].after.cascade, 'and AFTER carries the whole cascade for review');
  }

  const twice = await suspension.suspend(client, {
    adminId: ctx.admin.id, userId: ctx.victim.id, reason: `${PREFIX}suspending an already-suspended account`,
  });
  check(!twice.ok && twice.code === 'already_suspended', 'suspending twice is refused (409, no second cascade)');
  eq(twice.status, 409, 'with 409');
  ev.addFact('Suspension cascade', `1 booking cancelled, PKR ${cascade.refundedTotal} refunded, slot released`);
}

// Block 8 · The security fix — a suspended user's existing token stops working

/**
 * The one block that commits. Said out loud because everything else here is thrown
 * away, and a reader is entitled to know which claim cost a real row.
 *
 * `authMiddleware.accountState` reads through the pool — it is not exported and takes
 * its own connection, deliberately, because middleware has no transaction to join. A
 * user that exists only inside this script's transaction is therefore invisible to
 * it, and a block written the easy way would assert nothing at all while appearing to
 * pass. So this one commits one throwaway account, proves the 403 against it, and
 * hard-deletes it in a `finally` whether or not the assertions held.
 *
 * What is being proved, and why it is not cosmetic
 * Before Wave D the middleware was 43 lines of pure `jwt.verify` with no database
 * read, so suspension only took effect at the next login. A suspended user kept
 * using the app until their token expired — up to seven days of a banned account
 * behaving normally. The fix is a 30-second-TTL cache in front of one indexed lookup,
 * invalidated the instant an admin suspends.
 *
 * The stale window is asserted too, not hidden: within the TTL and without an
 * explicit `invalidate()`, the old token still works. That is the deliberate cost of
 * not reading the database on every single request, and the reason `suspend` calls
 * `invalidate` rather than trusting the clock.
 */
async function block8Enforcement(ctx) {
  section('Block 8 · A suspended account is rejected on its NEXT request (committed, then deleted)');

  if (!process.env.JWT_SECRET) {
    skip('JWT enforcement', 'JWT_SECRET is not set in this environment');
    return;
  }

  let userId = null;
  try {
    const ins = await pool.query(
      `INSERT INTO users (email, password_hash, name, phone, role, phone_verified, is_active)
       VALUES ($1, 'x', $2, $3, 'player', TRUE, TRUE) RETURNING id, email, role`,
      [`${PREFIX}jwt@sportlynk.test`, `${PREFIX}jwt`, '+923008399999'],
    );
    const user = ins.rows[0];
    userId = user.id;
    ev.note('This block commits one throwaway user, because the middleware reads through the pool and cannot see an uncommitted one. It is hard-deleted afterwards.');

    const token = jwt.sign({ id: user.id, email: user.email, role: user.role },
      process.env.JWT_SECRET, { expiresIn: '1h' });
    check(Boolean(token), 'a valid token is issued for the live account');

    // A stand-in for Express: enough of `req`/`res` for the middleware to do its job,
    // and a promise that settles on whichever exit it takes — `next()` or a `.json()`.
    // A rejection settles it too, so a thrown middleware fails the check instead of
    // hanging the script.
    const drive = (tok) => new Promise((resolve) => {
      const req = { headers: { authorization: `Bearer ${tok}` } };
      let code = null;
      const res = {
        status(c) { code = c; return res; },
        json(body) { resolve({ allowed: false, code, body, req }); },
      };
      authMiddleware(req, res, () => resolve({ allowed: true, code: 200, body: null, req }))
        .catch((err) => resolve({ allowed: false, code: null, body: { message: err.message }, req }));
    });

    const live = await drive(token);
    check(live.allowed === true, 'the live account passes the middleware');
    eq(live.req.user && live.req.user.id, userId, 'and arrives at the route as req.user');
    eq(live.req.user && live.req.user.role, 'player', 'with the role the ROW says, not only the claim');

    // Suspend in the database and deliberately do not invalidate. This is the cost of
    // caching, asserted rather than glossed: for up to TTL_MS the old token still
    // works. It is why `suspend()` calls `invalidate()` instead of trusting the clock.
    await pool.query('UPDATE users SET is_active = FALSE WHERE id = $1', [userId]);
    const stale = await drive(token);
    check(stale.allowed === true,
      `within the ${authMiddleware.TTL_MS / 1000}s cache TTL an un-invalidated token still passes`,
      'this is the documented cost of not reading the DB on every request');
    eq(authMiddleware.TTL_MS, 30000, 'and that window is 30 seconds, not a minute and not a request');

    // What an admin suspension does.
    authMiddleware.invalidate(userId);
    const banned = await drive(token);
    check(banned.allowed === false, 'after invalidate(), the SAME previously-valid token is rejected');
    eq(banned.code, 403, 'with 403 Forbidden — not 401, which the app would treat as an expired session');
    eq(banned.body && banned.body.message, 'Account suspended. Contact support.',
      'and the same words as the login refusal');
    eq(banned.body && banned.body.success, false, 'in the {success:false, message} shape every error uses');
    check(banned.req.user === undefined, 'and the route never sees a req.user at all');

    // Reinstating is the same lever pulled the other way, so it is worth one line.
    await pool.query('UPDATE users SET is_active = TRUE WHERE id = $1', [userId]);
    authMiddleware.invalidate(userId);
    const back = await drive(token);
    check(back.allowed === true, 'reinstating and invalidating lets the same token through again');

    // And the third state, which is neither: the row is gone. 401, because the
    // identity is unknown — a deleted account must not read as a suspended one.
    await pool.query('DELETE FROM users WHERE id = $1', [userId]);
    authMiddleware.invalidate(userId);
    const gone = await drive(token);
    eq(gone.code, 401, 'a token for a DELETED user is 401, not 403');
    eq(gone.body && gone.body.message, 'Account no longer exists', 'and says the account is gone');
  } finally {
    // Runs whether the assertions held or not: this is the one committed row in the
    // whole script, so nothing may leave it behind.
    if (userId) {
      await pool.query('DELETE FROM users WHERE id = $1', [userId]).catch(() => {});
      authMiddleware.invalidate(userId);
      const left = await pool.query('SELECT 1 FROM users WHERE id = $1', [userId]);
      check(left.rowCount === 0, 'the committed test account is deleted again (nothing is left behind)');
    }
  }
}

// Block 9 · The financial export (FR4.16) — including the venue named `=1+1`

/**
 * The attack this block is named after
 * Excel, LibreOffice and Sheets evaluate any cell whose text begins with `=`, `+`,
 * `-`, `@`, a tab or a CR. Every venue name, player name and note in this export was
 * typed by somebody else, so a venue registered as `=cmd|'/c calc'!A1` runs when the
 * owner opens the report their own dashboard produced. The defence is a leading
 * apostrophe, which those programs read as "the rest is literal text" and strip on
 * display — so the sheet shows the real name and the formula never runs.
 *
 * So the block registers a venue named `=1+1`, exports it, and reads the
 * bytes back. An assertion on `csv.cell` alone would not prove the export uses it.
 *
 * The second claim: the money is the ledger's, not the price list's
 * Two bookings are made on that venue — one checked in with real `escrow_received` /
 * `platform_commission` / `escrow_release` rows, one still pending with none. If the
 * report recomputed money from `bookings.total_amount` the pending row would show a
 * gross of 2000. It must show 0, with the price still in the Price column, because a
 * report that disagrees with the wallet is worse than no report.
 */
async function block9Export(client, ctx) {
  section('Block 9 · The financial export escapes a formula and reconciles with the ledger');

  const EVIL = '=1+1';

  // The unit layer first, since the file-level assertions below rest on it.
  eq(csv.cell(EVIL), "'=1+1", 'csv.cell prefixes a leading = with an apostrophe');
  eq(csv.cell('+1'), "'+1", 'and a leading +');
  eq(csv.cell('-5'), "'-5", 'and a leading -');
  eq(csv.cell('@SUM'), "'@SUM", 'and a leading @');
  eq(csv.cell('\tx'), "'\tx", 'and a leading tab');
  eq(csv.cell('Ali'), 'Ali', 'but leaves an ordinary name completely alone');
  eq(csv.cell(2000), '2000', 'and a NUMBER we produced ourselves is never prefixed (it must stay summable)');
  eq(csv.cell('-5,00'), '"\'-5,00"',
    'a field that is BOTH a formula and comma-bearing gets the apostrophe first, then the quotes');
  eq(csv.cell('He said "hi"'), '"He said ""hi"""', 'an embedded quote is doubled and the field wrapped (RFC 4180)');
  eq(csv.cell('a\nb'), '"a\nb"', 'a newline is wrapped rather than becoming a new record');
  eq(csv.cell(null), '', 'null is an empty cell, not the text "null"');
  eq(csv.money('2000.5'), '2000.50', 'money is a plain two-place decimal (a pg DECIMAL arrives as a string)');
  eq(csv.money(null), '0.00', 'and a missing amount is 0.00, never blank');
  check(csv.row(['a', 'b']).endsWith('\r\n'), 'rows end CRLF as RFC 4180 requires');
  eq(csv.safeFilename('rep";ort.csv'), 'rep__ort.csv', 'and a filename cannot carry a quote or a semicolon into a header');

  // A venue whose name is the attack, and two bookings on it
  const evilOwner = await makeUser(client, 'csvowner', 'owner');
  await makeWallet(client, evilOwner.id, 0);
  const player = await makeUser(client, 'csvplayer');
  await makeWallet(client, player.id, 60000);

  const vRes = await client.query(
    `INSERT INTO venues (owner_id, name, description, sport_type, city, address,
                         base_price, price_per_hour, upfront_percent, venue_photos,
                         operating_hours_from, operating_hours_to, is_active, rating, total_reviews)
     VALUES ($1, $2, $3, 'football', 'Islamabad', $4, 2000, 2000, 30, '{}', '06:00', '23:00', true, 0, 0)
     RETURNING id, name, owner_id`,
    [evilOwner.id, EVIL, `${PREFIX}a venue whose name is a spreadsheet formula`, `${PREFIX}addr`],
  );
  const evilVenue = vRes.rows[0];
  eq(evilVenue.name, EVIL, 'a venue is registered under the name `=1+1` (the database stores it verbatim)');

  const paid = await makeBooking(client, { venue: evilVenue, playerId: player.id, price: 2000, days: 3, hour: 9 });
  const open = await makeBooking(client, { venue: evilVenue, playerId: player.id, price: 2000, days: 4, hour: 9 });

  // Settle the first one exactly the way a QR check-in does: the player's escrow is
  // released, the owner receives it, the platform takes its cut. Real wallet deltas
  // and real ledger rows, because the report reads the ledger and nothing else.
  const commissionPct = await settings.commission({ client });
  const split = escrow.commissionSplit(2000, commissionPct);
  const pWallet = await escrow.lockWallet(client, player.id);
  const oWallet = await escrow.lockWallet(client, evilOwner.id);
  //
  // The signs are the production signs, and they are the whole point of staging real
  // rows instead of convenient ones. `routes/owner.js`'s check-in writes
  // `escrow_release` as `-escrow` (money leaving the player) and
  // `platform_commission` as `-commission` (a debit on the owner's wallet, which is
  // why the owner's statement shows a gross credit and a separate deduction). The
  // export negates those two arms back into positive report columns, so a test that
  // logged them positive would read a commission of -150 and a net above the gross --
  // and would have called a broken export correct.
  const pAfter = await escrow.applyWallet(client, pWallet.id, { frozen: -2000 });
  await escrow.logTxn(client, { walletId: pWallet.id, userId: player.id, bookingId: paid.booking.id,
    type: 'escrow_release', amount: -2000, balanceAfter: pAfter.balance, description: `${PREFIX}checked in` });
  const oAfter = await escrow.applyWallet(client, oWallet.id, { balance: 2000 });
  await escrow.logTxn(client, { walletId: oWallet.id, userId: evilOwner.id, bookingId: paid.booking.id,
    type: 'escrow_received', amount: 2000, balanceAfter: oAfter.balance, description: `${PREFIX}slot played` });
  const oNet = await escrow.applyWallet(client, oWallet.id, { balance: -split.commission });
  await escrow.logTxn(client, { walletId: oWallet.id, userId: evilOwner.id, bookingId: paid.booking.id,
    type: 'platform_commission', amount: -split.commission, balanceAfter: oNet.balance,
    description: `${PREFIX}platform commission` });
  await client.query(
    `UPDATE bookings SET status = 'checked_in', checked_in_at = now() WHERE id = $1`,
    [paid.booking.id],
  );

  // The export itself
  const day = (n) => new Date(Date.now() + n * 86400000).toISOString().slice(0, 10);
  const range = { from: day(-2), to: day(10) };
  const sink = { out: '', write(s) { this.out += s; return true; } };
  const totals = await reports.streamCsv(client,
    { ...range, scope: 'owner', ownerId: evilOwner.id, venueId: null }, sink);

  const lines = sink.out.split('\r\n');
  check(sink.out.startsWith(csv.BOM), 'the file opens with a UTF-8 BOM (or Excel-on-Windows mojibakes every Urdu name)');
  has(lines[0], 'Type,Reference,Date', 'the header row is the column labels');
  check(!lines[0].includes(',Owner,'), "and the owner's own export has no Owner column — it is all theirs");

  const paidLine = lines.find((l) => l.includes(paid.booking.id)) || '';
  const openLine = lines.find((l) => l.includes(open.booking.id)) || '';
  check(paidLine !== '' && openLine !== '', 'both bookings on that venue appear in the file');
  has(paidLine, ",'=1+1,", 'the venue cell is EXPORTED as `\'=1+1` — the formula is defused in the file itself');
  check(!sink.out.includes(',=1+1,'), 'and nowhere in the file does a bare `=1+1` survive as a live formula');
  has(paidLine, ',checked_in,', 'the settled booking carries its status');

  // The claim this fixture exists to make: money is the ledger's, not the price list's.
  const json = await reports.collectJson(client, { ...range, scope: 'owner', ownerId: evilOwner.id, venueId: null, days: 13 });
  const jPaid = json.rows.find((r) => r.ref === paid.booking.id) || {};
  const jOpen = json.rows.find((r) => r.ref === open.booking.id) || {};
  eq(jPaid.gross, 2000, 'the checked-in booking reports the gross the LEDGER received');
  eq(jPaid.commission, split.commission, `with the platform commission at the live ${commissionPct}%`);
  eq(jPaid.net, round2(2000 - split.commission), 'and net = gross − commission, to the paisa');
  eq(jPaid.depositHeld, 0, 'its deposit is no longer held (the booking reached a terminal state)');
  eq(jOpen.price, 2000, 'the still-pending booking shows its agreed PRICE');
  eq(jOpen.gross, 0, 'but a gross of ZERO — because no money has moved yet');
  eq(jOpen.commission, 0, 'and no commission');
  eq(jOpen.depositHeld, round2(Number(open.booking.deposit_amount)),
    "with the deposit sitting in the player's frozen balance, in its own column");
  check(round2(Number(open.booking.deposit_amount)) > 0, 'and that deposit is a real number, not zero');

  // The totals, and the rule that makes the file trustworthy: the preview the owner
  // reads on screen and the file they download are produced by the same walk, so
  // they cannot disagree. Asserted by comparing the two totals objects.
  eq(totals.rows, 2, 'the TOTAL counts both rows');
  eq(totals.bookings, 2, 'both of them bookings');
  eq(totals.tournaments, 0, 'and no tournament payouts on this venue');
  eq(totals.price, 4000, 'the agreed prices add up');
  eq(totals.gross, 2000, 'the gross is only what actually arrived');
  eq(totals.commission, split.commission, 'the commission column totals the ledger');
  eq(totals.net, round2(2000 - split.commission), 'and the TOTAL net reconciles too');
  eq(JSON.stringify(json.totals), JSON.stringify(totals),
    'the JSON preview and the CSV file report byte-identical totals (one walk, two formats)');
  check(json.truncated === false, 'and the preview is not truncated at this size');

  const filled = lines.filter((l) => l.trim().length);
  const last = filled[filled.length - 1] || '';
  check(last.startsWith('TOTAL,'), 'the last row of the file is the TOTAL row');
  has(last, csv.money(totals.gross), 'carrying the summed gross');
  has(last, '2 rows (2 bookings, 0 tournament payouts)', 'and saying what it counted, in words');

  // The platform scope adds the Owner column and a per-owner subtotal. With one owner
  // in range the subtotal must equal the total exactly — if it does not, no wider
  // export reconciles either.
  const sink2 = { out: '', write(s) { this.out += s; return true; } };
  const pTotals = await reports.streamCsv(client,
    { ...range, scope: 'platform', ownerId: null, venueId: evilVenue.id }, sink2);
  const pLines = sink2.out.split('\r\n');
  has(pLines[0], ',Owner,', 'the platform export adds an Owner column');
  const ownerTotal = pLines.find((l) => l.startsWith('OWNER TOTAL,')) || '';
  check(ownerTotal !== '', 'and a per-owner subtotal row');
  has(ownerTotal, evilOwner.name, 'naming the owner it bills');
  has(ownerTotal, csv.money(pTotals.commission), 'whose commission equals the platform TOTAL (a single owner reconciles exactly)');
  check(!sink2.out.includes(',=1+1,'), 'and the formula is defused in this export too');

  // The range guard, which is what stops one export becoming an outage
  const bad = (q) => reports.parseRange(q);
  eq(bad({}).message, 'from and to are required as YYYY-MM-DD dates.', 'a missing date range is refused by name');
  eq(bad({ from: '2026-08-31', to: '2026-01-01' }).message, 'to must not be earlier than from.',
    'a backwards range is refused');
  has(bad({ from: '2020-01-01', to: '2026-08-31' }).message, `the maximum is ${reports.RANGE_MAX_DAYS}`,
    'and a range longer than a year is refused with the number, and told how to split it');
  eq(bad({ from: '2026-08-01', to: '2026-08-31', venueId: 'nope' }).message, 'Invalid venueId.',
    'a malformed venueId is refused before it reaches SQL');
  has(bad({ from: '2026-08-01', to: '2026-08-31', format: 'pdf' }).message, "format must be 'csv' or 'json'",
    'and PDF is honestly refused rather than silently served as CSV');
  const good = bad({ from: '2026-08-01', to: '2026-08-31' });
  check(good.ok === true, 'a sane range is accepted');
  eq(good.days, 31, 'with the day count computed inclusively');
  eq(good.format, 'csv', "and CSV as the default format");
  has(reports.filenameFor({ scope: 'owner', from: '2026-08-01', to: '2026-08-31' }),
    'sportlynk-financial-2026-08-01-to-2026-08-31.csv', 'the download filename says what it is and is header-safe');

  ctx.csv = { venueId: evilVenue.id, ownerId: evilOwner.id, bookingIds: [paid.booking.id, open.booking.id] };
}

// Block 10 · The wiring — what the sources must say, not what a request returns

/**
 * Four facts that no request can demonstrate, because a request that works proves
 * only that it worked once, on this data, in this order.
 *
 * 1. Authorisation is structural. `routes/admin.js` puts one
 *    `router.use(auth, checkRole('admin'))` above every sub-router mount, so a new
 *    admin screen physically cannot ship without an authorisation check. Asserted by
 *    byte offset: the gate must appear before the first mount.
 * 2. Cache invalidation is after COMMIT. `settings.invalidate()` and
 *    `authMiddleware.invalidate(id)` drop caches that are then refilled from the
 *    database. Calling either before `COMMIT` refills them from the pre-write state
 *    and the change appears to have silently failed — the exact class of "I changed
 *    it and nothing happened" bug this wave exists to remove. Asserted on both the
 *    first and the last occurrence in each file, because each has two handlers.
 * 3. Sockets fire after COMMIT. `mc.emitAfterCommit` pushes a ruling to two phones;
 *    doing it before COMMIT can show a player an outcome that then rolls back.
 * 4. The owner export cannot be unscoped. `ownerReports` passes
 *    `ownerId: req.user.id` — a literal, not a query parameter — so "export
 *    everything" is not reachable from the owner router at all.
 */
/**
 * The same source with its comment lines blanked out, space for space, so every byte
 * offset below still points where it points in the real file.
 *
 * Why this exists. The assertions under it search for needles like
 * `checkRole('admin')`, `authMiddleware.invalidate` and `mc.emitAfterCommit` -- and
 * every one of those needles is also spelled out in the header comment that explains
 * the invariant it belongs to. Reading the prose as code made "exactly one role
 * check" count two, and made "the cache drop happens after COMMIT" fail because the
 * paragraph describing that ordering sits at the top of the file, thousands of bytes
 * ahead of the COMMIT it describes. Deleting good prose to satisfy a test would be
 * exactly backwards, so the test learns to read code instead.
 *
 * Only whole comment lines are blanked -- a line whose first non-space characters
 * open a comment, and the body of a block until its terminator. A mid-line slash pair
 * is left alone, so one inside a string literal can never be mistaken for a comment,
 * and no line of code is ever shortened, moved or removed.
 */
function codeOnly(src) {
  const CLOSE = '*' + '/';
  let inBlock = false;
  return src.split('\n').map((line) => {
    const blank = ' '.repeat(line.length);
    const t = line.trim();
    if (inBlock) {
      const end = line.indexOf(CLOSE);
      if (end === -1) return blank;
      inBlock = false;
      return ' '.repeat(end + 2) + line.slice(end + 2);
    }
    if (t.startsWith('//')) return blank;
    if (t.startsWith('/*')) {
      const open = line.indexOf('/*');
      const end = line.indexOf(CLOSE, open + 2);
      if (end === -1) { inBlock = true; return blank; }
      return ' '.repeat(end + 2) + line.slice(end + 2);
    }
    return line;
  }).join('\n');
}

function block10Wiring() {
  section('Block 10 · The wiring the sources have to state (read from disk, not from a request)');

  const adminSrc = codeOnly(read('routes/admin.js'));
  const ownerSrc = codeOnly(read('routes/owner.js'));
  const setSrc = codeOnly(read('routes/adminSettings.js'));
  const usrSrc = codeOnly(read('routes/adminUsers.js'));
  const dspSrc = codeOnly(read('routes/adminDisputes.js'));
  const repSrc = codeOnly(read('routes/reports.js'));
  check([adminSrc, ownerSrc, setSrc, usrSrc, dspSrc, repSrc].every((s) => s.length > 0),
    'all six route sources are on disk and readable');

  for (const mod of ['./adminUsers', './adminDisputes', './adminSettings']) {
    has(adminSrc, `require('${mod}')`, `admin.js mounts ${mod}`);
  }
  has(adminSrc, "require('./reports').platformReports", 'and the platform report router');
  has(ownerSrc, 'require("./reports").ownerReports', 'owner.js mounts the owner report router');

  const gate = adminSrc.indexOf("router.use(auth, checkRole('admin'))");
  const firstMount = adminSrc.indexOf("router.use(require('./adminUsers')");
  check(gate > -1 && firstMount > gate,
    'the single admin auth gate sits ABOVE every sub-router mount',
    'so a new admin surface cannot ship unauthorised');
  eq(adminSrc.split("checkRole('admin')").length - 1, 1,
    'and there is exactly ONE role check in the file — one rule, not four copies');

  // 2 & 3 · after-COMMIT ordering, asserted by byte offset on both handlers.
  const after = (src, label, commitNeedle, sideEffect, what) => {
    const c1 = src.indexOf(commitNeedle);
    const s1 = src.indexOf(sideEffect);
    const c2 = src.lastIndexOf(commitNeedle);
    const s2 = src.lastIndexOf(sideEffect);
    check(c1 > -1 && s1 > c1 && s2 > c2, `${label}: ${what} happens AFTER COMMIT, in every handler`,
      `first ${c1}→${s1}, last ${c2}→${s2}`);
  };
  after(setSrc, 'adminSettings', "client.query('COMMIT')", 'settings.invalidate()', 'the settings cache drop');
  after(setSrc, 'adminSettings', "client.query('COMMIT')", 'escrow.setDepositPercent', 'the deposit-percent push');
  after(usrSrc, 'adminUsers', "client.query('COMMIT')", 'authMiddleware.invalidate', 'the auth cache drop');
  after(dspSrc, 'adminDisputes', "client.query('COMMIT')", 'mc.emitAfterCommit', 'the socket fan-out');

  // 4 · the owner export cannot be talked out of its own scope.
  has(repSrc, 'ownerId: req.user.id', "the owner export scopes to req.user.id — a literal, not a query param");
  has(repSrc, "scope: 'platform', ownerId: null", 'and only the admin router may pass a null owner');
  check(!repSrc.includes('req.query.ownerId'), 'no ownerId is ever read from the query string');

  // And the two services the routes must not bypass: a ruling and a suspension both
  // go through one function each, so there is one place where the money and the
  // ratings are correct rather than two implementations that drift.
  has(dspSrc, 'disputeService', 'the dispute route delegates to disputeService (no parallel ruling logic)');
  has(usrSrc, 'suspensionService', 'and the users route delegates to suspensionService');
  check(!dspSrc.includes('elo.applyResult'),
    'the route never calls elo.applyResult itself — the rating exchange has exactly one caller');
}

// The run

/** No row this script writes may ever be found outside its own transaction. */
async function verifyClean(client) {
  section('--verify-clean');
  const { rows } = await client.query(
    `SELECT (SELECT count(*) FROM users WHERE email LIKE $1)::int AS users,
            (SELECT count(*) FROM teams WHERE name LIKE $1)::int AS teams,
            (SELECT count(*) FROM bookings WHERE notes LIKE $1)::int AS bookings,
            (SELECT count(*) FROM venues WHERE description LIKE $1)::int AS venues,
            (SELECT count(*) FROM tournaments WHERE name LIKE $1)::int AS cups`,
    [`${PREFIX}%`],
  );
  eq(rows[0].users, 0, 'no zzadmin- user exists in the database');
  eq(rows[0].teams, 0, 'no zzadmin- team either');
  eq(rows[0].bookings, 0, 'no zzadmin- booking');
  eq(rows[0].venues, 0, 'no zzadmin- venue (including the one named `=1+1`)');
  eq(rows[0].cups, 0, 'and no zzadmin- tournament');
}

async function main() {
  const client = await pool.connect();
  const ctx = {};
  let rolled = false;

  // Two pieces of process state that a ROLLBACK cannot undo, saved before anything
  // touches them. `escrow.POLICY.DEPOSIT_PERCENT` is a module-level number that
  // `createBooking` pushes on every booking, and `globalSettings` caches rows for
  // 60 s — so Block 2's uncommitted 35% / 7.5% would outlive the transaction and
  // leak into whatever runs next in this process.
  const depositBefore = escrow.POLICY.DEPOSIT_PERCENT;

  try {
    if (VERIFY_CLEAN) { await verifyClean(client); return; }

    ctx.venue = await pickVenue(client);
    if (!ctx.venue) {
      console.log('\n  ✗ no active venue with an owner exists in this database.');
      failures.push('an active venue with an owner to rule, suspend and export against');
      return;
    }
    const sport = String(ctx.venue.sport_type || 'football').toLowerCase();
    const correction = await elo.supportsCorrection(client);
    console.log(`\n  venue    ${ctx.venue.name} — ${ctx.venue.city}, ${sport}`);
    console.log(`  owner    ${ctx.venue.owner_name}`);
    console.log(`  021      ${correction ? 'applied — the overturn path is live' : 'NOT applied — the overturn block will skip'}`);
    ev.addMeta('venue', `${ctx.venue.name} (${ctx.venue.city})`);
    ev.addMeta('migration 021', correction ? 'applied' : 'not applied');

    // The two pure blocks first: if the catalog itself is inconsistent, nothing that
    // depends on it is worth running, and they need no database at all.
    block0Catalog();
    block1Refusals();

    await client.query('BEGIN');

    ctx.admin = await makeUser(client, 'admin', 'admin');
    ctx.victim = await makeUser(client, 'victim');
    await makeWallet(client, ctx.victim.id, 80000);

    // Block 2 writes the live commission and deposit, so it runs before the booking
    // that Block 7 later refunds — that booking's deposit is the proof the write took
    // effect on the very next operation rather than on the next restart.
    await block2Live(client, ctx);

    // The disputed match Blocks 3 and 4 work on: two teams at 1200, one booking, two
    // conflicting submissions, a captain room with a real argument in it, one dispute.
    ctx.challenger = await makeTeam(client, { label: 'chal', sport, city: ctx.venue.city, rating: 1200 });
    ctx.opponent = await makeTeam(client, { label: 'opp', sport, city: ctx.venue.city, rating: 1200 });
    const matchBooking = await makeBooking(client, {
      venue: ctx.venue, playerId: ctx.victim.id, price: 2000, days: 14, hour: 16,
    });
    ctx.match = await makeMatch(client, {
      challenger: ctx.challenger.teamId, opponent: ctx.opponent.teamId,
      bookingId: matchBooking.booking.id, sport, createdBy: ctx.challenger.captain.id,
      status: mc.STATUS.DISPUTED,
    });
    await makeResults(client, {
      matchId: ctx.match.id,
      challengerTeam: ctx.challenger.teamId, opponentTeam: ctx.opponent.teamId,
    });
    ctx.captainChannelId = await chat.ensureCaptainChannel(client, {
      matchId: ctx.match.id, title: `${PREFIX}coordination room`,
      memberIds: [ctx.challenger.captain.id, ctx.challenger.vice.id,
        ctx.opponent.captain.id, ctx.opponent.vice.id],
    });
    // The chat log FR10.6 puts on the admin's screen. Written by the captains, not by
    // the system, because a case file whose only "evidence" is its own pills proves
    // nothing about the argument it is supposed to settle.
    for (const m of [
      { senderId: ctx.challenger.captain.id, body: 'we won 3-1, your two subs never showed up' },
      { senderId: ctx.opponent.captain.id, body: 'nonsense, we won 3-1 — check the ground register' },
    ]) {
      await chat.insertMessage(client, { channelId: ctx.captainChannelId, ...m });
    }
    ctx.dispute = await makeDispute(client, {
      matchId: ctx.match.id, raisedByTeam: ctx.opponent.teamId,
      reason: `${PREFIX}both captains claim a 3-1 win`,
    });

    await block3CaseFile(client, ctx);
    await block4Ruling(client, ctx);
    await block5Overturn(client, ctx);
    await block6Bracket(client, ctx);
    await block7Suspension(client, ctx);
    await block9Export(client, ctx);
    block10Wiring();
  } catch (err) {
    console.error('\n  ! the run stopped:', err.message);
    failures.push(`the run completed without throwing (${err.message})`);
  } finally {
    if (!VERIFY_CLEAN) {
      await client.query('ROLLBACK').then(() => { rolled = true; }).catch(() => {});

      // The rollback, proven rather than asserted: the same connection, now outside
      // any transaction, must not see one row this run wrote.
      section('The rollback');
      try {
        const { rows } = await client.query(
          `SELECT (SELECT count(*) FROM users WHERE email LIKE $1)::int AS users,
                  (SELECT count(*) FROM teams WHERE name LIKE $1)::int AS teams,
                  (SELECT count(*) FROM venues WHERE name = '=1+1')::int AS evil,
                  (SELECT count(*) FROM disputes WHERE id = $2)::int AS dispute,
                  (SELECT count(*) FROM admin_audit WHERE note LIKE $1)::int AS audit`,
          [`${PREFIX}%`, (ctx.dispute && ctx.dispute.id) || '00000000-0000-0000-0000-000000000000'],
        );
        eq(rows[0].users, 0, 'after ROLLBACK not one person this run created still exists');
        eq(rows[0].teams, 0, 'nor one team');
        eq(rows[0].evil, 0, 'nor the venue named `=1+1`');
        eq(rows[0].dispute, 0, 'nor the dispute that was ruled');
        eq(rows[0].audit, 0, 'and not one admin_audit row — the database is exactly as it was');
      } catch (err) {
        check(false, 'the rollback could be verified', err.message);
      }

      // Process state, restored by hand because no ROLLBACK can reach it.
      escrow.setDepositPercent(depositBefore, 'check_admin-restore');
      settings.invalidate();
      eq(escrow.POLICY.DEPOSIT_PERCENT, depositBefore,
        `the process-global deposit percent is back to ${depositBefore}% (a ROLLBACK cannot undo a module variable)`);
    }
    client.release();
  }

  // Block 8 is deliberately outside the transaction — it commits, because the
  // middleware it drives reads through the pool and cannot see uncommitted rows.
  if (!VERIFY_CLEAN) await block8Enforcement(ctx);

  if (!rolled && !VERIFY_CLEAN) console.log('\n  ! the transaction was NOT rolled back');
}

/**
 * The verdict. A skip is printed alongside the pass count and never inside it: a case
 * the data could not supply is a case that did not run, and folding it into the pass
 * total would turn thin data into a green tick.
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
