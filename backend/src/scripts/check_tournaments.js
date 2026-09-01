/**
 * check_tournaments.js — the tournament module, end to end, against the real
 * database. Always rolled back.
 *
 * Usage:  node src/scripts/check_tournaments.js            (ml-service optional)
 *         node src/scripts/check_tournaments.js --evidence (writes doc/tournament_evidence.md)
 *
 * Why this script exists
 * test/fixtures.test.js and test/fixtureSchedule.test.js prove the decisions with
 * the database down: the bracket shape, the byes, the seeding, the waterfall
 * arithmetic, the K table, the slot ranking. None of that touches a row, which is
 * the point. But a bracket the pure functions draw perfectly and the ledger records
 * wrongly is still a broken feature, and the one claim this wave rests on —
 * "the owner is never worse off than selling the same hours" — is a claim about
 * money in wallets, not about a pure function's return value.
 *
 * So this script drives the real service against the real schema: real venue slots
 * reserved, real entry fees frozen and released, a real bracket played out to a
 * champion, and then it reads the wallets and the ledger back and asserts the
 * arithmetic to the paisa.
 *
 * Nothing survives it
 * Every service function takes a caller-owned `client` and writes no BEGIN of its
 * own — that is what lets routes/matches.js compose them, and it is what lets this
 * script hold one transaction open across three whole tournaments and ROLLBACK at
 * the end. The committee's database is left exactly as it was found: no tournament,
 * no fixture, no blocked slot, no wallet movement, no notification.
 *
 * Why it creates its CAST instead of choosing it
 * check_assistant.js chooses its cast from the seeded data, because a booking needs
 * one player and one venue and the seed has hundreds. A tournament needs eight
 * captains of eight same-sport teams with funded wallets, and asserting the money
 * needs their opening balances known. Choosing eight would make most runs a skip.
 * So the venue, its owner and its free hours are chosen (the demo runs on those
 * rows, so the checks must too), and the eight captains and teams are created
 * inside the transaction that throws them away. Rows created here are prefixed
 * `zzcheck-` so that a failed run interrupted before its ROLLBACK is trivially
 * identifiable — and `--verify-clean` re-checks that none exist.
 *
 * What a failure means
 *   ✗  a rule broke. The line names it.
 *   ~  the seeded data could not supply the case (no venue with enough free hours
 *      ahead). Reported as a skip, not a pass — a check that never ran is not a
 *      check that passed, and the PASS line counts them separately.
 */
const pool = require('../db/pool');
const T = require('../services/tournamentService');
const scheduler = require('../services/tournamentScheduler');
const discovery = require('../services/discoveryService');
const fx = require('../utils/fixtures');
const mc = require('../utils/matchCore');
const elo = require('../utils/elo');
const settings = require('../utils/globalSettings');
const { asNum, round2 } = require('../utils/escrow');
const evidence = require('./lib/evidence');

const failures = [];
const skips = [];
let passed = 0;

const PREFIX = 'zzcheck-';
const ARGS = process.argv.slice(2);
const VERIFY_CLEAN = ARGS.includes('--verify-clean');

const EVIDENCE_OUT = require('path').join(__dirname, '..', '..', '..', 'doc', 'tournament_evidence.md');

const EVIDENCE_HEADER = `# Tournaments — the evidence pack

**This file is generated. Do not edit it by hand.** Every line below was written by a
verification script that had just asserted it against the live database, inside one
transaction that was then rolled back — so the run leaves no rows behind and the
document is reproducible rather than a description of a state somebody once had. To
regenerate:

\`\`\`
cd backend && node src/scripts/check_tournaments.js --evidence
\`\`\`

A block absent from this file was not run — it is not a pass.
`;

const ev = evidence.recorder({
  key: 'tournaments',
  out: EVIDENCE_OUT,
  header: EVIDENCE_HEADER,
  markPrefix: 'tournament-evidence',
  title: 'S.7 Wave A -- the tournament module, driven through `tournamentService`',
  subtitle: 'Five tournaments -- one cancelled under its minimum, an 8-team knockout played to a '
    + 'champion, a 5-team knockout with byes, a 4-team round-robin decided on goal difference, and '
    + 'one driven through the S.2 captain-submit door -- created, paid into, drawn onto real venue '
    + 'hours, played out and audited, all inside ONE transaction that is rolled back at the end. '
    + 'Every money assertion reads the WALLET and the LEDGER rather than the return value: the '
    + 'return value is the thing under test, not the evidence.',
  command: 'cd backend && node src/scripts/check_tournaments.js --evidence',
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

/** Money equality to the paisa. Never compare pg numerics with ===. */
function money(got, want, label) {
  const g = round2(asNum(got, NaN));
  const w = round2(asNum(want, NaN));
  return check(Math.abs(g - w) < 0.005, label, `got ${g}, want ${w}`);
}

/** A refusal: the call failed, with this code, and for the stated reason. */
function refused(result, code, label) {
  const got = result && result.ok === false ? result.code : `ok:${result && result.ok}`;
  return check(result && result.ok === false && result.code === code, label,
    `got ${got}${result && result.message ? ` — "${result.message}"` : ''}`);
}

/** A success, printing the service's own message when it unexpectedly failed. */
function worked(result, label) {
  return check(Boolean(result && result.ok), label,
    result ? `${result.code || 'failed'} — ${result.message}` : 'no result');
}

/**
 * Run something that might fail without poisoning the outer transaction.
 *
 * Postgres aborts the whole transaction on any error, so one bad query would turn
 * every later check into "current transaction is aborted" and hide the real result.
 * A savepoint per probe keeps a failure local to that probe.
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

/** One wallet, as numbers. Missing wallet reads as zero, which is what it is. */
async function walletOf(client, userId) {
  const { rows } = await client.query(
    'SELECT id, balance, frozen_balance FROM wallets WHERE user_id = $1', [userId]);
  const w = rows[0];
  return {
    id: w ? w.id : null,
    balance: round2(asNum(w && w.balance, 0)),
    frozen: round2(asNum(w && w.frozen_balance, 0)),
    total: round2(asNum(w && w.balance, 0) + asNum(w && w.frozen_balance, 0)),
  };
}

/** Every wallet this run touches, so the closing audit can total them. */
const watched = new Map();       // userId -> label
function watch(userId, label) { if (userId) watched.set(String(userId), label); }

/** A snapshot of every watched wallet, for a before/after delta. */
async function snapshot(client) {
  const out = new Map();
  for (const userId of watched.keys()) out.set(userId, await walletOf(client, userId));
  return out;
}

// The CAST

/**
 * The venue: chosen, never created. It needs a real price (the whole economic
 * argument is denominated in `slots.price`), an owner, and enough genuinely free
 * hours spread over enough days that a three-round bracket with a day between
 * rounds can be placed. The four tournaments this script draws brackets for
 * consume 7 + 4 + 6 + 3 = 20 hours between them, and each `generate` blocks the hours
 * it took, so the scan has to find comfortably more than that.
 *
 * The 28-hour floor is therefore the 20 the run needs plus room for the round-gap to
 * push a fixture onto a later day. The seeded venues carry ~86 free priced hours over
 * six days, so this is a guard against running on thin data, not a tight fit.
 */
async function pickVenue(client) {
  const now = discovery.pktNow();
  const { rows } = await client.query(
    `SELECT v.id, v.name, v.city, v.sport_type, v.owner_id,
            v.price_per_hour, v.base_price,
            count(s.id)::int AS free_hours,
            count(DISTINCT s.slot_date)::int AS free_days,
            min(s.price)::numeric AS cheapest, max(s.price)::numeric AS dearest
       FROM venues v
       JOIN slots s ON s.venue_id = v.id
      WHERE v.is_active AND v.owner_id IS NOT NULL
        AND COALESCE(v.price_per_hour, v.base_price, 0) > 0
        AND LOWER(v.sport_type) IN ('football', 'cricket')
        AND s.status = 'available' AND s.price > 0
        AND NOT ${discovery.HOLD_IS_LIVE}
        AND (s.slot_date > $1::date OR (s.slot_date = $1::date AND s.start_time >= $2::time))
        AND s.slot_date <= ($1::date + 20)
      GROUP BY v.id
     HAVING count(s.id) >= 28 AND count(DISTINCT s.slot_date) >= 4
      ORDER BY count(s.id) DESC
      LIMIT 1`,
    [now.date, now.time],
  );
  return rows[0] || null;
}

/**
 * The captains and their teams: created, then thrown away with the transaction.
 *
 * `tag` exists because the run needs three casts, not one: the twelve same-sport
 * captains who play, one captain of a team in the other sport (so `sport_mismatch`
 * is provable), and one whose wallet is empty (so `insufficient_funds` is). Without
 * a tag the second call would collide with the first on `users.email`.
 *
 * Each captain is funded to exactly `fund`, so every later assertion about their
 * wallet is an assertion about a known opening balance rather than a delta against
 * whatever the seed happened to leave. ELO is set descending so the seeding check
 * has an unambiguous expected order — `seedTeams` sorts on ELO, and eight teams all
 * on 1000 would make "seed 1 plays seed 8" untestable.
 */
async function makeCast(client, {
  sport, city, count, fund, tag = null, eloTop = 1600, phoneBase = 9000000,
}) {
  const cast = [];
  for (let i = 0; i < count; i += 1) {
    const elo = eloTop - i * 50;
    const who = tag ? `${tag}${i + 1}` : `cap${i + 1}`;
    const teamName = tag
      ? `${PREFIX}Team ${tag}${i + 1}`
      : `${PREFIX}Team ${String.fromCharCode(65 + i)}`;
    const { rows: u } = await client.query(
      `INSERT INTO users (email, password_hash, name, phone, role, phone_verified)
       VALUES ($1, 'x', $2, $3, 'player', TRUE) RETURNING id`,
      [`${PREFIX}${who}@sportlynk.test`, `${PREFIX}Captain ${who}`,
        `+92300${String(phoneBase + i).slice(-7)}`],
    );
    const captainId = u[0].id;
    const { rows: t } = await client.query(
      // $5 and $6 both carry `elo`, on purpose. `teams.elo` is integer and the
      // legacy `teams.elo_rating` is numeric(8,2); one placeholder feeding both
      // makes Postgres deduce two conflicting types for one parameter and the
      // INSERT dies with 42P08. Two placeholders let each column infer its own
      // type -- the same rule `utils/elo.js` writes ratings under.
      `INSERT INTO teams (name, sport, captain_id, city, elo, elo_rating, visibility)
       VALUES ($1,$2,$3,$4,$5,$6,'public') RETURNING id, name, elo`,
      [teamName, sport, captainId, city, elo, elo],
    );
    await client.query(
      `INSERT INTO team_members (team_id, user_id, role) VALUES ($1,$2,'captain')`,
      [t[0].id, captainId],
    );
    await client.query(
      `INSERT INTO wallets (user_id, balance, frozen_balance) VALUES ($1,$2,0)
       ON CONFLICT (user_id) DO UPDATE SET balance = $2, frozen_balance = 0`,
      [captainId, fund],
    );
    watch(captainId, `${tag ? `${tag} ` : ''}captain ${i + 1} (${t[0].name})`);
    cast.push({
      captainId, teamId: t[0].id, teamName: t[0].name, elo, seedExpected: i + 1,
    });
  }
  return cast;
}

/**
 * An entry fee that clears this venue's real prices, with room to spare.
 *
 * A fixed fee would make the later cups assert the wrong thing on a differently
 * priced venue: five teams at PKR 1,500 is PKR 7,500 of pool against four hours,
 * which on a venue charging 2,000 is a healthy cup and on one charging 3,000 is
 * underwater. Underwater is a state the module handles correctly and Block 2 already
 * asserts through `preview`; it is not the state Blocks 7-9 were written to examine.
 * Deriving the fee from `slots.price` keeps each block testing its own claim, and
 * keeps the numbers in the evidence pack recognisable as this venue's.
 *
 * `margin` is the headroom over bare cost — 1.3 means the pool clears the hours by
 * 30%, which is roughly the shape of the worked example in the plan.
 */
function feeFor(ctx, { fixtures, teams, margin = 1.3 }) {
  const hour = asNum(ctx.venue.dearest, 0)
    || asNum(ctx.venue.price_per_hour, 0) || asNum(ctx.venue.base_price, 0) || 1000;
  return Math.max(500, Math.ceil((hour * fixtures * margin) / teams / 100) * 100);
}

/** Push a tournament's deadline into the past, the way the clock would. */
async function expireDeadline(client, tournamentId) {
  await client.query(
    `UPDATE tournaments SET registration_deadline = now() - interval '2 minutes' WHERE id = $1`,
    [tournamentId],
  );
}

// Block 1 — configuration (SRS FE-1): what may not be created

/**
 * The refusals that cost nothing to prove and everything to get wrong. A knockout
 * whose field is not a power of two cannot be drawn at all, and finding that out at
 * the deadline — after eight captains have paid — is the failure this block exists
 * to make impossible.
 */
async function blockConfig(client, ctx) {
  section('Block 1 — configuration refusals (FE-1)');
  const policy = await settings.tournament({ client });
  const base = {
    name: 'Check Cup', format: 'knockout', maxTeams: 8, minTeams: 4, entryFee: 1000,
  };
  const cfg = (over) => T.validateConfig({ ...base, ...over }, policy);

  const ko6 = cfg({ maxTeams: 6 });
  check(!ko6.ok && /power of two/i.test(ko6.errors.join(' ')),
    'a knockout field of 6 is refused, and the message says "power of two"',
    ko6.errors.join(' | '));
  check(cfg({ maxTeams: 8 }).ok && cfg({ maxTeams: 16 }).ok && cfg({ maxTeams: 32 }).ok,
    '8, 16 and 32 are accepted knockout fields');
  check(!cfg({ maxTeams: 64 }).ok, `a knockout field above the ${fx.MAX_KNOCKOUT_TEAMS} cap is refused`);

  const rr8 = cfg({ format: 'round_robin', maxTeams: 8 });
  check(!rr8.ok && /n\(n-1\)\/2/.test(rr8.errors.join(' ')),
    `round-robin above ${fx.MAX_ROUND_ROBIN_TEAMS} teams is refused, and the message says why`,
    rr8.errors.join(' | '));
  check(cfg({ format: 'round_robin', maxTeams: 6 }).ok,
    'round-robin at the cap is accepted');

  check(!cfg({ minTeams: 9 }).ok, 'a minimum field larger than the maximum is refused');
  check(!cfg({ name: 'X' }).ok, 'a two-character name is refused');
  check(!cfg({ slotMinutes: 5 }).ok, 'a 5-minute fixture is refused');
  check(!cfg({ prizePercent: 150 }).ok, 'a prize share above 100% is refused');
  check(!cfg({ winnerPercent: 80 }).ok,
    'winner 80 / runner-up 30 is refused — the shares must total exactly 100');
  check(cfg({ prizePercent: 0 }).ok,
    'a 0% prize share is ACCEPTED — "the venue keeps the surplus" is a real cup, not a typo');

  const past = T.validateDates({ registrationDeadline: '2020-01-01T10:00:00Z' });
  check(!past.ok && /future/i.test(past.errors.join(' ')),
    'a deadline in the past is refused');
  const soon = new Date(Date.now() + 3 * 86400000).toISOString();
  const backwards = T.validateDates({
    registrationDeadline: soon,
    startDate: new Date(Date.now() + 86400000).toISOString().slice(0, 10),
  });
  check(!backwards.ok && /before registration closes/i.test(backwards.errors.join(' ')),
    'a start date before the deadline is refused — the scheduler could not keep that promise');
  check(T.validateDates({ registrationDeadline: soon }).ok,
    'a future deadline with no start date is accepted');

  // The one refusal that needs the database: the venue has to belong to the caller.
  const foreign = await client.query(
    `SELECT id FROM venues WHERE owner_id IS NOT NULL AND owner_id <> $1 AND is_active LIMIT 1`,
    [ctx.venue.owner_id],
  );
  if (foreign.rows.length) {
    const r = await probe(client, () => T.create(client, {
      ownerId: ctx.venue.owner_id, venueId: foreign.rows[0].id, ...base,
      registrationDeadline: soon,
    }));
    refused(r.out, 'not_your_venue', 'an owner cannot post a tournament at somebody else\'s venue');
  } else {
    skip('an owner cannot post a tournament at somebody else\'s venue', 'only one venue owner in the data');
  }

  const ghost = await probe(client, () => T.create(client, {
    ownerId: ctx.venue.owner_id, venueId: '00000000-0000-0000-0000-000000000000',
    ...base, registrationDeadline: soon,
  }));
  refused(ghost.out, 'venue_not_found', 'a tournament at a venue that does not exist is refused');
}

// Block 2 — the economics quote (the argument, made checkable)

/**
 * The claim this wave is built on is that a tournament pays an owner more than
 * selling the same hours, and that teams pay one fee for several matches. Both
 * halves are arithmetic over `slots.price`, and `preview` is where the owner sees
 * it before committing. So this block asserts the quote itself: that the
 * recommended fee clears the venue cost at the minimum turnout (the case that
 * would otherwise bankrupt the cup), that the waterfall closes to the paisa, and
 * that round-robin's n(n-1)/2 is quoted as the four-times-costlier thing
 * it is, rather than discovered at the deadline.
 */
async function blockEconomics(client, ctx) {
  section('Block 2 — the economics quote (FE-1), from real slot prices');
  const q = await probe(client, () => T.preview(client, {
    ownerId: ctx.venue.owner_id, venueId: ctx.venue.id,
    name: 'Preview Cup', format: 'knockout', maxTeams: 8, minTeams: 4,
    entryFee: 1000, useModel: ctx.useModel,
  }));
  if (!q.ok || !q.out.ok) {
    skip('the economics quote', q.err ? q.err.message : (q.out && q.out.message) || 'preview failed');
    return null;
  }
  const p = q.out.data;
  ctx.preview = p;

  // `schedulable`, not `ok`: that is the field `preview` emits and the field
  // `lib/models/tournament.dart` parses. Asserting `.ok` read undefined and
  // reported a failure on a quote that was fine.
  check(p.capacity && p.capacity.schedulable === true,
    'the full 8-team bracket can be placed on this venue\'s free hours',
    p.capacity ? `${p.capacity.code} — ${p.capacity.message}` : 'no capacity block');
  eq(p.capacity.fixtures, 7, 'an 8-team knockout is quoted as 7 fixtures');
  eq(p.minimum.fixtures, 3, 'a 4-team minimum turnout is quoted as 3 fixtures');
  check(asNum(p.capacity.slotTotal, 0) > 0,
    'the quote is denominated in real slot prices, not an estimate',
    `slotTotal=${p.capacity.slotTotal}`);
  check(asNum(p.capacity.slotTotal, 0) > asNum(p.minimum.slotTotal, 0),
    'seven hours cost more than three — the quote scales with the field, not the fee');

  // The recommended fee: the mechanism that stops an owner underpricing
  const rec = p.recommended;
  check(rec && asNum(rec.entryFee, 0) > 0, 'a recommended entry fee is quoted',
    JSON.stringify(rec && rec.entryFee));
  check(rec.achievable === true,
    'the recommendation is achievable at the configured prize share');
  const atMin = rec.atMinTeams;
  check(asNum(atMin.pool, 0) >= asNum(atMin.venueCost, 0),
    'at the recommended fee the MINIMUM legal turnout still clears the venue cost',
    `pool ${atMin.pool} vs venueCost ${atMin.venueCost}`);
  check(atMin.underwater === false,
    'the recommended fee is never underwater at the worst legal turnout');
  check(asNum(atMin.ownerEarning, 0) >= asNum(atMin.retailValue, 0),
    'and the owner still earns at least what selling those same hours would have paid',
    `earning ${atMin.ownerEarning} vs retail ${atMin.retailValue}`);

  // The waterfall closes, to the paisa
  for (const [label, split] of [['at capacity', p.economics.atCapacity],
    ['at the minimum', p.economics.atMinimum], ['at the recommended fee', atMin]]) {
    money(split.pool, round2(asNum(split.venueCost, 0) + asNum(split.prize, 0) + asNum(split.margin, 0)),
      `${label}: pool = venue cost + prize + margin, to the paisa`);
    money(split.ownerEarning, round2(asNum(split.pool, 0) - asNum(split.prize, 0)),
      `${label}: the owner takes everything that is not prize money`);
    money(split.winnerShare + split.runnerupShare, split.prize,
      `${label}: the winner and runner-up shares total the prize exactly`);
    check(split.identityOk === true, `${label}: the split reports its own identity as exact`);
  }

  // Round-robin is quoted as the four-times-costlier format
  const rr = await probe(client, () => T.preview(client, {
    ownerId: ctx.venue.owner_id, venueId: ctx.venue.id,
    name: 'Preview League', format: 'round_robin', maxTeams: 6, minTeams: 4,
    entryFee: 1000, useModel: false,
  }));
  if (rr.ok && rr.out.ok) {
    const league = rr.out.data;
    eq(league.capacity.fixtures, 15, 'a 6-team round-robin is quoted as 15 fixtures — n(n-1)/2');
    check(asNum(league.recommended.entryFee, 0) > asNum(rec.entryFee, 0),
      'and its recommended fee is HIGHER than the knockout\'s, because it eats more inventory',
      `league ${league.recommended.entryFee} vs knockout ${rec.entryFee}`);
  } else {
    skip('a 6-team round-robin is quoted as 15 fixtures', 'not enough free hours for 15 fixtures');
  }
  return p;
}

// Block 3 — registration, the money door (FE-3, FE-4, FE-5)

/** The ledger rows this run wrote for one user, newest first. */
async function txnsOf(client, userId, { type = null, tournamentId = null } = {}) {
  const { rows } = await client.query(
    `SELECT type::text AS type, amount, balance_after, description, tournament_id
       FROM transactions
      WHERE user_id = $1
        AND ($2::text IS NULL OR type::text = $2)
        AND ($3::uuid IS NULL OR tournament_id = $3)
      ORDER BY created_at DESC, id DESC`,
    [userId, type, tournamentId],
  );
  return rows;
}

/**
 * One entry fee, followed end to end: the balance falls, the frozen balance rises
 * by the same amount, the wallet total does not move (nothing has been spent yet —
 * it is held), and a `tournament_entry` row records it against the tournament.
 *
 * The total-unchanged assertion is the one that matters. A fee that left the
 * captain's wallet before the bracket was drawn would be money taken for a
 * tournament that might still be cancelled, and the refund paths would have nothing
 * to give back.
 */
async function blockRegistration(client, ctx, t) {
  section('Block 3 — entry fees, refusals and refunds (FE-3, FE-4, FE-5)');
  const cast = ctx.cast;
  const fee = round2(asNum(t.entry_fee, 0));
  const one = cast[0];

  const before = await walletOf(client, one.captainId);
  const r1 = await probe(client, () => T.register(client, {
    userId: one.captainId, tournamentId: t.id, teamId: one.teamId,
  }));
  if (!worked(r1.out, 'a captain enters their team', r1.err && r1.err.message)) return false;
  eq(r1.out.status, 201, 'registration answers 201 Created');
  const after = await walletOf(client, one.captainId);
  money(after.balance, before.balance - fee, 'the entry fee leaves the spendable balance');
  money(after.frozen, before.frozen + fee, 'and appears in the frozen balance');
  money(after.total, before.total, 'the wallet TOTAL is unchanged — the fee is held, not spent');
  const entry = (await txnsOf(client, one.captainId, { type: 'tournament_entry', tournamentId: t.id }))[0];
  check(Boolean(entry), 'a tournament_entry ledger row is written');
  if (entry) {
    money(entry.amount, -fee, 'the ledger row carries the negative fee');
    money(entry.balance_after, after.balance, 'and the balance it recorded matches the wallet');
  }

  // The refusals
  refused(
    (await probe(client, () => T.register(client, {
      userId: one.captainId, tournamentId: t.id, teamId: one.teamId,
    }))).out,
    'already_registered', 'the same team cannot enter twice',
  );
  refused(
    (await probe(client, () => T.register(client, {
      userId: cast[1].captainId, tournamentId: t.id, teamId: one.teamId,
    }))).out,
    'not_captain', 'only the captain may enter a team',
  );
  refused(
    (await probe(client, () => T.register(client, {
      userId: ctx.wrongSport.captainId, tournamentId: t.id, teamId: ctx.wrongSport.teamId,
    }))).out,
    'sport_mismatch', 'a team from another sport cannot enter',
  );
  refused(
    (await probe(client, () => T.register(client, {
      userId: ctx.broke.captainId, tournamentId: t.id, teamId: ctx.broke.teamId,
    }))).out,
    'insufficient_funds', 'a captain who cannot cover the fee is refused, and pays nothing',
  );
  const brokeWallet = await walletOf(client, ctx.broke.captainId);
  money(brokeWallet.frozen, 0, 'the refused captain has nothing frozen');

  // Withdraw gives every rupee back
  const w = await probe(client, () => T.withdraw(client, {
    userId: one.captainId, tournamentId: t.id, teamId: one.teamId,
  }));
  worked(w.out, 'a captain may withdraw while registration is open');
  const back = await walletOf(client, one.captainId);
  money(back.balance, before.balance, 'the whole fee is back in the spendable balance');
  money(back.frozen, before.frozen, 'and nothing is left frozen');
  const refund = (await txnsOf(client, one.captainId, { type: 'refund', tournamentId: t.id }))[0];
  check(Boolean(refund), 'a refund ledger row is written');
  if (refund) money(refund.amount, fee, 'the refund row carries the positive fee');

  const again = await probe(client, () => T.register(client, {
    userId: one.captainId, tournamentId: t.id, teamId: one.teamId,
  }));
  worked(again.out, 'and the team may enter again after withdrawing');

  // Fill the field, then prove the cap and the removal both hold
  for (let i = 1; i <= 7; i += 1) {
    const c = cast[i];
    const r = await probe(client, () => T.register(client, {
      userId: c.captainId, tournamentId: t.id, teamId: c.teamId,
    }));
    if (!r.ok || !r.out.ok) {
      check(false, `team ${i + 1} of 8 enters`, r.err ? r.err.message : r.out.message);
      return false;
    }
  }
  check(true, 'the field fills to 8 teams');
  refused(
    (await probe(client, () => T.register(client, {
      userId: cast[8].captainId, tournamentId: t.id, teamId: cast[8].teamId,
    }))).out,
    'full', 'a ninth team is refused — the participant cap is enforced (FE-4)',
  );

  // FE-5: removal is a refund and a freed spot, which is why it is tested as one
  // thing. A removal that took the money and left the field full would be worse
  // than a refusal.
  const removed = cast[7];
  const removedBefore = await walletOf(client, removed.captainId);
  const rm = await probe(client, () => T.ownerDecision(client, {
    ownerId: ctx.venue.owner_id, tournamentId: t.id, teamId: removed.teamId,
    decision: 'remove', reason: 'checked by check_tournaments.js',
  }));
  worked(rm.out, 'the organiser may remove a team (FE-5)');
  const removedAfter = await walletOf(client, removed.captainId);
  money(removedAfter.balance, removedBefore.balance + fee, 'a removed team is refunded in full');
  money(removedAfter.frozen, removedBefore.frozen - fee, 'and nothing of theirs stays frozen');
  refused(
    (await probe(client, () => T.ownerDecision(client, {
      ownerId: cast[0].captainId, tournamentId: t.id, teamId: cast[1].teamId, decision: 'remove',
    }))).out,
    'not_organiser', 'a captain cannot remove somebody else\'s team',
  );

  const filler = await probe(client, () => T.register(client, {
    userId: cast[8].captainId, tournamentId: t.id, teamId: cast[8].teamId,
  }));
  worked(filler.out, 'and the freed spot can be taken by the team that was refused a moment ago');
  ctx.field = cast.slice(0, 7).concat([cast[8]]);
  return true;
}

// Block 4 — the deadline (FE-4): too few teams means everyone is paid back

/**
 * The rule that makes a tournament safe to enter: if the field does not reach
 * `min_teams` by the deadline, nobody plays and nobody pays. This is the path the
 * deadline job takes automatically, so it is asserted through the same function the
 * job calls — `generateFixtures({ bySystem: true })` — rather than through `cancel`.
 *
 * The assertion is per captain and exact. "Everyone was refunded" is a claim about
 * two specific wallets returning to two specific opening balances, and a refund
 * that is one paisa short is the kind of thing a demo never notices and an auditor
 * always does.
 */
async function blockUnderMinimum(client, ctx) {
  section('Block 4 — under the minimum field, everyone is refunded (FE-4)');
  const [a, b] = [ctx.cast[9], ctx.cast[10]];
  const created = await probe(client, () => T.create(client, {
    ownerId: ctx.venue.owner_id, venueId: ctx.venue.id,
    name: `${PREFIX}Abandoned Cup`, format: 'knockout', maxTeams: 8, minTeams: 4,
    entryFee: 500, registrationDeadline: new Date(Date.now() + 3600000).toISOString(),
    useModel: false,
  }));
  if (!worked(created.out, 'a second tournament is posted')) return;
  const t = await T.loadTournament(client, created.out.data.tournament.id);

  const opening = new Map();
  for (const c of [a, b]) {
    opening.set(c.captainId, await walletOf(client, c.captainId));
    const r = await probe(client, () => T.register(client, {
      userId: c.captainId, tournamentId: t.id, teamId: c.teamId,
    }));
    worked(r.out, `${c.teamName} enters the tournament that will not fill`);
  }

  await expireDeadline(client, t.id);
  const gen = await probe(client, () => T.generateFixtures(client, {
    tournamentId: t.id, bySystem: true, useModel: false,
  }));
  worked(gen.out, 'the deadline sweep answers rather than throwing');
  eq(gen.out && gen.out.code, 'cancelled_min_teams',
    'two teams against a minimum of four is cancelled, not drawn');
  eq(gen.out && gen.out.data && gen.out.data.generated, false, 'and no bracket is reported');
  if (gen.out && gen.out.data) {
    eq(gen.out.data.teamsRefunded, 2, 'both entries are refunded');
    money(gen.out.data.refunded, 1000, 'the refund total is the two PKR 500 fees');
  }

  const fresh = await T.loadTournament(client, t.id);
  eq(fresh.status, 'cancelled', 'the tournament row is marked cancelled');
  check(Boolean(fresh.cancel_reason) && /min|team/i.test(fresh.cancel_reason),
    'and the reason says the field was too small', fresh.cancel_reason);
  for (const c of [a, b]) {
    const now = await walletOf(client, c.captainId);
    const was = opening.get(c.captainId);
    money(now.balance, was.balance, `${c.teamName}'s captain is back to their opening balance`);
    money(now.frozen, was.frozen, `${c.teamName}'s captain has nothing left frozen`);
  }
  const { rows: fixtures } = await client.query(
    'SELECT COUNT(*)::int AS n FROM fixtures WHERE tournament_id = $1', [t.id]);
  eq(fixtures[0].n, 0, 'no fixture was written for the cancelled tournament');
}

// Block 5 — generation (FE-6): the bracket, the ground, and the money

/**
 * The transaction the module is built around, asserted in four parts:
 *
 *   the DRAW      — 8 teams, 3 rounds, 7 fixtures, seeded 1-v-8 by ELO;
 *   the ground    — seven distinct real slots, every one of them now 'blocked',
 *                   and no slot used twice (uq_fixtures_slot_id is the guarantee,
 *                   this is the proof it holds in practice);
 *   the money     — every captain's frozen fee released, the owner's balance up by
 *                   `venue_cost + margin`, the prize frozen where a withdrawal
 *                   cannot reach it, and the waterfall closing to the paisa;
 *   the provenance— `meta.scheduling.source` is 'model' or 'chronological' and says
 *                   which, so the demo proves the model ran instead of asserting it.
 */
async function blockGenerate(client, ctx, t) {
  section('Block 5 — the draw, the reservation and the waterfall (FE-6)');
  const fee = round2(asNum(t.entry_fee, 0));
  const field = ctx.field;
  const opening = new Map();
  for (const c of field) opening.set(c.captainId, await walletOf(client, c.captainId));
  const ownerBefore = await walletOf(client, ctx.venue.owner_id);
  // Block 6 needs this to prove the podium came out of the frozen prize rather than
  // out of thin air, so it is recorded at the one moment it is still pre-prize.
  ctx.ownerFrozenBeforePrize = ownerBefore.frozen;

  refused(
    (await probe(client, () => T.generateFixtures(client, {
      actorId: field[0].captainId, tournamentId: t.id,
    }))).out,
    'not_organiser', 'a captain cannot draw the bracket',
  );

  await expireDeadline(client, t.id);
  refused(
    (await probe(client, () => T.register(client, {
      userId: ctx.cast[11].captainId, tournamentId: t.id, teamId: ctx.cast[11].teamId,
    }))).out,
    'deadline_passed', 'once the deadline passes, registration is closed (FE-4)',
  );

  const g = await probe(client, () => T.generateFixtures(client, {
    actorId: ctx.venue.owner_id, tournamentId: t.id, useModel: ctx.useModel,
  }));
  if (!worked(g.out, 'the organiser draws the bracket', g.err && g.err.message)) return null;
  const d = g.out.data;
  ctx.generated = d;

  // The draw
  eq(d.teams, 8, 'eight teams are in the field');
  eq(d.bracket.rounds, 3, 'an 8-team knockout is 3 rounds');
  eq(d.bracket.size, 8, 'the bracket size is 8 — no padding was needed');
  eq(d.bracket.byes, 0, 'and nobody gets a bye');
  eq(d.bracket.fixtures, 7, 'seven fixtures, which is n-1');

  const byElo = [...field].sort((a, b) => b.elo - a.elo);
  const seeds = new Map(d.seeds.map((s) => [String(s.teamId), s.seed]));
  check(byElo.every((c, i) => seeds.get(String(c.teamId)) === i + 1),
    'seeding is strictly by ELO, highest first',
    d.seeds.map((s) => `${s.seed}:${s.elo}`).join(' '));

  const round1 = d.fixtures.filter((f) => f.round === 1);
  eq(round1.length, 4, 'round 1 has four ties');
  const pairs = round1.map((f) => [seeds.get(String(f.teamA)), seeds.get(String(f.teamB))]
    .sort((x, y) => x - y).join('v'));
  check(pairs.includes('1v8') && pairs.includes('2v7') && pairs.includes('3v6') && pairs.includes('4v5'),
    'and the pairings are 1v8, 2v7, 3v6, 4v5 — the top seed meets the bottom one',
    pairs.join(' '));

  const labels = d.fixtures.map((f) => f.label).filter(Boolean);
  check(labels.some((l) => /final/i.test(l) && !/semi|quarter/i.test(l)), 'the last round is labelled Final',
    labels.join(' | '));
  check(labels.some((l) => /semi/i.test(l)), 'and the round before it is labelled Semi-final');

  // The ground
  const { rows: placed } = await client.query(
    `SELECT f.id, f.slot_id, f.scheduled_at, f.round, s.status::text AS slot_status,
            to_char(s.slot_date, 'YYYY-MM-DD') AS slot_date, s.start_time, s.price
       FROM fixtures f LEFT JOIN slots s ON s.id = f.slot_id
      WHERE f.tournament_id = $1 ORDER BY f.round, f.position`, [t.id]);
  eq(placed.length, 7, 'seven fixture rows exist');
  check(placed.every((r) => r.slot_id), 'every fixture reserved a real slot');
  check(placed.every((r) => r.slot_status === 'blocked'),
    'and every reserved slot is now blocked, so nobody can book it',
    placed.map((r) => r.slot_status).join(','));
  eq(new Set(placed.map((r) => String(r.slot_id))).size, 7, 'no slot is used twice');
  check(placed.every((r) => r.scheduled_at), 'every fixture has a scheduled_at stamp');

  const { rows: noBooking } = await client.query(
    `SELECT COUNT(*)::int AS n FROM bookings b
      WHERE b.slot_id = ANY($1::uuid[])`, [placed.map((r) => r.slot_id)]);
  eq(noBooking[0].n, 0,
    'NOT ONE booking row was written — a fixture reserves, it does not book (no double charge, no no-show sweep)');

  // The money
  const split = d.economics;
  money(split.pool, fee * 8, 'the pool is eight entry fees');
  money(split.venueCost, placed.reduce((sum, r) => sum + asNum(r.price, 0), 0),
    'the venue cost is the sum of the SEVEN CHOSEN SLOTS\' real prices — not an estimate');
  money(split.pool, round2(asNum(split.venueCost, 0) + asNum(split.prize, 0) + asNum(split.margin, 0)),
    'pool = venue cost + prize + margin, to the paisa');
  money(split.ownerEarning, round2(asNum(split.venueCost, 0) + asNum(split.margin, 0)),
    'the owner earning is the venue cost plus the margin');
  check(asNum(split.ownerEarning, 0) >= asNum(split.venueCost, 0),
    'THE CENTRAL CLAIM: the owner earns at least the value of the hours consumed — never underwater',
    `earning ${split.ownerEarning} vs venue cost ${split.venueCost}`);
  check(asNum(split.ownerEarning, 0) >= asNum(split.retailValue, 0),
    'and at least what those same hours would have fetched sold at the counter',
    `earning ${split.ownerEarning} vs retail ${split.retailValue}`);
  money(split.winnerShare + split.runnerupShare, split.prize,
    'the two podium shares total the prize exactly');
  check(split.identityOk === true, 'the split reports its own identity as exact');

  for (const c of field) {
    const was = opening.get(c.captainId);
    const now = await walletOf(client, c.captainId);
    money(now.frozen, was.frozen - fee, `${c.teamName}: the held fee is released out of frozen`);
    money(now.balance, was.balance, `${c.teamName}: and none of it came back — it was spent on the entry`);
    const rel = (await txnsOf(client, c.captainId, { type: 'escrow_release', tournamentId: t.id }))[0];
    check(Boolean(rel), `${c.teamName}: an escrow_release row records the release`);
  }

  const ownerAfter = await walletOf(client, ctx.venue.owner_id);
  money(ownerAfter.balance, ownerBefore.balance + asNum(split.ownerEarning, 0),
    'the owner is paid the venue cost plus the margin, in SPENDABLE balance');
  money(ownerAfter.frozen, ownerBefore.frozen + asNum(split.prize, 0),
    'and the prize sits in FROZEN, where a withdrawal cannot reach it');
  const commission = (await txnsOf(client, ctx.venue.owner_id,
    { type: 'tournament_commission', tournamentId: t.id }))[0];
  check(Boolean(commission), 'a tournament_commission row records the owner\'s earning');
  if (commission) money(commission.amount, split.ownerEarning, 'and carries the right amount');
  if (asNum(split.prize, 0) > 0) {
    const held = (await txnsOf(client, ctx.venue.owner_id,
      { type: 'tournament_prize', tournamentId: t.id }))[0];
    check(Boolean(held), 'a tournament_prize row records the prize being held');
  }

  // The pool is conserved at this instant: what the eight captains paid is now
  // exactly what the owner holds, in balance plus frozen.
  money(round2((ownerAfter.balance - ownerBefore.balance) + (ownerAfter.frozen - ownerBefore.frozen)),
    split.pool, 'THE WHOLE POOL is now with the owner — nothing has evaporated');

  // The stored amounts, so no auditor has to re-derive them
  const row = await T.loadTournament(client, t.id);
  ctx.tRow = row;
  eq(row.status, 'active', 'the tournament is now active');
  check(Boolean(row.fixtures_generated_at), 'and stamped with when the bracket was drawn');
  eq(Number(row.rounds), 3, 'the round count is stored on the row');
  money(row.pool_amount, split.pool, 'pool_amount is stored');
  money(row.venue_cost_amount, split.venueCost, 'venue_cost_amount is stored');
  money(row.prize_amount, split.prize, 'prize_amount is stored');
  money(row.owner_earning_amount, split.ownerEarning, 'owner_earning_amount is stored');

  // The provenance
  const sch = d.meta && d.meta.scheduling;
  check(sch && [scheduler.SOURCE.MODEL, scheduler.SOURCE.CHRONOLOGICAL].includes(sch.source),
    'the schedule is stamped with its provenance', sch ? sch.source : 'no meta.scheduling');
  if (sch && sch.source === scheduler.SOURCE.MODEL) {
    check(Boolean(sch.modelVersion), 'model path: the demand model version is recorded', String(sch.modelVersion));
    check(sch.coverage && sch.coverage.scored > 0,
      'model path: it names how many candidate hours it actually scored',
      JSON.stringify(sch.coverage));
    console.log(`     ↳ model #1 scored ${sch.coverage.scored}/${sch.coverage.total} candidate hours (${sch.modelVersion})`);
  } else if (sch) {
    check(Boolean(sch.reason), 'chronological path: the fallback says WHY, loudly', String(sch.reason));
    console.log(`     ↳ fell back to chronological: ${sch.reason}`);
  }
  check(Array.isArray(sch && sch.picks) && sch.picks.length === 3,
    'and it records the window each round was placed in');

  // The final should be the round the model liked most and the early rounds the
  // hours it liked least — that is the whole point of asking a booking-probability
  // model the inverse question. Only assertable when the model answered.
  if (sch && sch.source === scheduler.SOURCE.MODEL) {
    const final = sch.picks.find((x) => x.round === 3);
    const early = sch.picks.find((x) => x.round === 1);
    if (final && early && final.meanPBooked != null && early.meanPBooked != null) {
      check(asNum(final.meanPBooked, 0) >= asNum(early.meanPBooked, 0),
        'the final takes a busier hour than round 1 — peak crowd for the showpiece, dead hours for the rest',
        `final ${final.meanPBooked} vs round 1 ${early.meanPBooked}`);
    } else {
      skip('the final takes a busier hour than round 1', 'the forecast did not reach every chosen hour');
    }
  } else {
    skip('the final takes a busier hour than round 1', 'ml-service unavailable, chronological fallback');
  }

  // The unblock guard: the owner cannot free an hour a fixture stands on
  const { rows: guard } = await client.query(
    `SELECT f.id FROM fixtures f JOIN tournaments t2 ON t2.id = f.tournament_id
      WHERE f.slot_id = $1 AND f.status <> 'cancelled' LIMIT 1`, [placed[0].slot_id]);
  eq(guard.length, 1,
    'the owner-unblock guard finds the fixture standing on a reserved hour (so PATCH /owner/slots/:id/unblock refuses)');
  return d;
}

// Block 6 — results, K, advancement and the podium (FE-7)

/** The bracket as it stands, keyed by round then position. */
async function bracketNow(client, tournamentId) {
  const rows = await T.loadFixtures(client, tournamentId);
  return rows.map(T.shapeFixture);
}

/** The rating rows one match wrote, so K can be read rather than assumed. */
async function eloRowsFor(client, matchId) {
  const { rows } = await client.query(
    `SELECT team_id, elo_before, elo_after, elo_delta, k_factor, reason
       FROM elo_history WHERE match_id = $1 ORDER BY created_at`, [matchId]);
  return rows;
}

const teamCounters = async (client, teamId) => {
  const { rows } = await client.query(
    `SELECT elo, COALESCE(tournament_played,0)::int AS played,
            COALESCE(tournament_wins,0)::int AS wins,
            COALESCE(finals_reached,0)::int AS finals,
            COALESCE(titles,0)::int AS titles
       FROM teams WHERE id = $1`, [teamId]);
  const r = rows[0] || {};
  return {
    elo: asNum(r.elo, 1000), played: r.played || 0, wins: r.wins || 0,
    finals: r.finals || 0, titles: r.titles || 0,
  };
};

/**
 * Settle one fixture through the organiser door and assert the whole consequence:
 * the fixture, the winner, the advance, the elimination, the counters, the match
 * row and the K it was rated at. Returns the service result.
 */
async function settleAndAssert(client, ctx, t, fixture, { scoreA, scoreB, expectK, label }) {
  const beforeA = await teamCounters(client, fixture.teamA);
  const beforeB = await teamCounters(client, fixture.teamB);
  const r = await probe(client, () => T.settleFixture(client, {
    actorId: ctx.venue.owner_id, tournamentId: t.id, fixtureId: fixture.id, scoreA, scoreB,
  }));
  if (!worked(r.out, `${label}: the organiser enters ${scoreA}-${scoreB}`, r.err && r.err.message)) {
    return null;
  }
  const data = r.out.data;
  eq(data.fixture.status, 'played', `${label}: the fixture is played`);
  const expectWinner = scoreA === scoreB
    ? String(fixture.teamAElo >= fixture.teamBElo ? fixture.teamA : fixture.teamB)
    : String(scoreA > scoreB ? fixture.teamA : fixture.teamB);
  eq(String(data.winner), expectWinner, `${label}: the right team won`);
  eq(data.draw, scoreA === scoreB, `${label}: the draw flag matches the scoreline`);

  // K is read from elo_history, not taken from the response, because the claim
  // being made is about the stored rating trail an examiner would query.
  const rows = await eloRowsFor(client, data.matchId);
  eq(rows.length, 2, `${label}: two rating rows, one per team`);
  const ks = [...new Set(rows.map((r) => Number(r.k_factor)))];
  eq(ks.length === 1 ? ks[0] : ks, expectK, `${label}: elo_history.k_factor = ${expectK}`);
  eq(data.elo && Number(data.elo.kFactor), expectK, `${label}: the response reports K=${expectK}`);
  const sum = rows.reduce((n, r) => n + asNum(r.elo_delta, 0), 0);
  check(Math.abs(sum) < 0.005, `${label}: the exchange is zero-sum (${sum.toFixed(2)})`);

  // The counters: a played game moves `tournament_played` for both, and
  // `tournament_wins` only for whoever went through.
  const afterA = await teamCounters(client, fixture.teamA);
  const afterB = await teamCounters(client, fixture.teamB);
  eq(afterA.played - beforeA.played, 1, `${label}: team A's played count moved`);
  eq(afterB.played - beforeB.played, 1, `${label}: team B's played count moved`);
  const wonA = expectWinner === String(fixture.teamA);
  eq(afterA.wins - beforeA.wins, wonA ? 1 : 0, `${label}: team A's win count is right`);
  eq(afterB.wins - beforeB.wins, wonA ? 0 : 1, `${label}: team B's win count is right`);

  // The loser is out of a knockout, and the winner is standing in the next slot.
  const { rows: gone } = await client.query(
    `SELECT status FROM tournament_teams WHERE tournament_id = $1 AND team_id = $2`,
    [t.id, expectWinner === String(fixture.teamA) ? fixture.teamB : fixture.teamA]);
  eq(gone[0] && gone[0].status, 'eliminated', `${label}: the beaten team is eliminated`);
  return r.out;
}

async function block6(client, ctx) {
  section('6 · RESULTS, K BY STAKE, ADVANCEMENT AND THE PODIUM (FE-7)');
  ctx.policy = ctx.policy || await settings.tournament({ client });
  const t = ctx.t8;
  if (!t) return skip('no generated bracket to play out');
  const board = await bracketNow(client, t.id);
  const r1 = board.filter((f) => f.round === 1).sort((a, b) => a.position - b.position);
  if (r1.length !== 4) return skip(`round 1 has ${r1.length} fixtures, expected 4`);

  // Refusals first, on a live bracket, before any of it is played
  const byCaptain = await probe(client, () => T.settleFixture(client, {
    actorId: ctx.field[0].userId, tournamentId: t.id, fixtureId: r1[0].id, scoreA: 3, scoreB: 0,
  }));
  refused(byCaptain.out, 'not_organiser', 'a captain cannot enter their own result');
  const semiEarly = board.find((f) => f.round === 2);
  const early = await probe(client, () => T.settleFixture(client, {
    actorId: ctx.venue.owner_id, tournamentId: t.id, fixtureId: semiEarly.id, scoreA: 1, scoreB: 0,
  }));
  refused(early.out, 'teams_unknown', 'a semi-final cannot be settled before round 1');
  const noScore = await probe(client, () => T.settleFixture(client, {
    actorId: ctx.venue.owner_id, tournamentId: t.id, fixtureId: r1[0].id, scoreA: 2, scoreB: null,
  }));
  refused(noScore.out, 'bad_score', 'a half-entered scoreline is refused');

  // Round 1: a win, a draw, a rout and a walkover
  // Four different endings on purpose, because each one exercises a different
  // rule: the ordinary case, the knockout tie-break, and the game nobody played.
  const win1 = await settleAndAssert(client, ctx, t, r1[0],
    { scoreA: 2, scoreB: 1, expectK: ctx.policy.kEarly, label: 'R1 · a 2-1' });
  if (win1) {
    check(win1.data.advanced && win1.data.advanced.round === 2,
      'R1 · the winner advances into round 2');
  }

  // A drawn knockout fixture. `drawWinner` sends the higher seed through, which is
  // the documented policy — there is no penalty-shootout model to appeal to — so
  // the assertion is that the SEED decided it, not the scoreline.
  const drawn = r1[1];
  const dres = await settleAndAssert(client, ctx, t, drawn,
    { scoreA: 1, scoreB: 1, expectK: ctx.policy.kEarly, label: 'R1 · a 1-1 draw' });
  if (dres) {
    eq(String(dres.data.winner), String(drawn.teamA),
      'R1 · the drawn tie goes to the higher seed (team A)');
    check(dres.data.draw === true, 'R1 · the response says it was a draw');
    check(drawn.teamAElo >= drawn.teamBElo,
      `R1 · and team A really is the higher seed (${drawn.teamAElo} vs ${drawn.teamBElo})`);
  }

  await settleAndAssert(client, ctx, t, r1[2],
    { scoreA: 3, scoreB: 0, expectK: ctx.policy.kEarly, label: 'R1 · a 3-0' });

  // The walkover. The claim: no game was played, so no rating moves and no
  // counter moves — the only things that change are the bracket and the record
  // that it happened.
  const wo = r1[3];
  const eloBeforeA = (await teamCounters(client, wo.teamA));
  const eloBeforeB = (await teamCounters(client, wo.teamB));
  const wres = await probe(client, () => T.walkover(client, {
    actorId: ctx.venue.owner_id, tournamentId: t.id, fixtureId: wo.id,
    winnerTeamId: wo.teamA, reason: 'the opponent did not arrive',
  }));
  if (worked(wres.out, 'R1 · the organiser awards a walkover', wres.err && wres.err.message)) {
    eq(wres.out.data.fixture.status, 'walkover', 'R1 · the fixture is marked walkover');
    eq(String(wres.out.data.winner), String(wo.teamA), 'R1 · the walkover winner advances');
    eq(wres.out.data.fixture.scoreA, null, 'R1 · a walkover has no scoreline');
    eq(wres.out.data.fixture.matchId, null, 'R1 · a walkover writes no match row');
    eq(Number(wres.out.data.elo.kFactor), 0, 'R1 · K is 0 for a walkover');
    check(wres.out.data.elo.applied === false, 'R1 · and no exchange was applied');
    const afterA = await teamCounters(client, wo.teamA);
    const afterB = await teamCounters(client, wo.teamB);
    money(afterA.elo, eloBeforeA.elo, 'R1 · the walkover winner\'s rating did not move');
    money(afterB.elo, eloBeforeB.elo, 'R1 · the absent team\'s rating did not move');
    eq(afterA.played, eloBeforeA.played, 'R1 · a walkover is not a game played');
    eq(afterA.wins, eloBeforeA.wins, 'R1 · and not a tournament win either');
    // Keyed through `matches.tournament_id` rather than a timestamp: elo_history
    // rows reach a tournament only through the match row a rated fixture creates,
    // and a walkover creates none. These two teams have played nothing else in
    // this tournament, so any row at all would be one the walkover wrote.
    const { rows: hist } = await client.query(
      `SELECT count(*)::int AS n
         FROM elo_history eh
         JOIN matches m ON m.id = eh.match_id
        WHERE m.tournament_id = $1 AND eh.team_id = ANY($2::uuid[])`,
      [t.id, [wo.teamA, wo.teamB]]);
    eq(hist[0].n, 0, 'R1 · NO elo_history row exists for a walkover');
  }

  // Round 2: the semi-finals, rated harder
  const semis = (await bracketNow(client, t.id))
    .filter((f) => f.round === 2).sort((a, b) => a.position - b.position);
  eq(semis.length, 2, 'R2 · both semi-finals exist');
  check(semis.every((f) => f.teamA && f.teamB),
    'R2 · both semi-finals have two named teams now that round 1 is done');
  check(semis.every((f) => /semi/i.test(f.label || '')),
    'R2 · they are labelled as semi-finals', semis.map((f) => f.label).join(' | '));
  for (const [i, s] of semis.entries()) {
    await settleAndAssert(client, ctx, t, s, {
      scoreA: i === 0 ? 2 : 0, scoreB: i === 0 ? 0 : 1,
      expectK: ctx.policy.kSemi, label: `SF${i + 1}`,
    });
  }

  // The final: K at its highest, and the podium paid
  const finals = (await bracketNow(client, t.id)).filter((f) => f.round === 3);
  eq(finals.length, 1, 'F · one final');
  const fin = finals[0];
  check(/final/i.test(fin.label || '') && !/semi/i.test(fin.label || ''),
    'F · it is labelled the Final', fin.label);
  check(Boolean(fin.teamA && fin.teamB), 'F · both finalists are known');

  const ownerBefore = await walletOf(client, ctx.venue.owner_id);
  const champCapBefore = await walletOf(client, ctx.captainByTeam.get(String(fin.teamA)));
  const runnerCapBefore = await walletOf(client, ctx.captainByTeam.get(String(fin.teamB)));
  const champRecordBefore = await teamCounters(client, fin.teamA);
  const runnerRecordBefore = await teamCounters(client, fin.teamB);
  const econ = ctx.generated.economics;

  const fres = await settleAndAssert(client, ctx, t, fin,
    { scoreA: 3, scoreB: 2, expectK: ctx.policy.kFinal, label: 'F · a 3-2' });
  if (!fres) return skip('the final did not settle, so the podium cannot be checked');

  eq(Number(fres.data.remaining), 0, 'F · no fixture is left upcoming');
  check(Boolean(fres.data.completed), 'F · settling the final completed the tournament');
  const podium = fres.data.completed || {};
  eq(String(podium.winnerTeam), String(fin.teamA), 'F · the champion is the team that won it');
  eq(String(podium.runnerUpTeam), String(fin.teamB), 'F · and the beaten finalist is runner-up');

  // The podium. The prize came out of the owner's FROZEN balance — where
  // generation put it — and landed in two captains' spendable balances. Nothing
  // was minted: the owner's frozen falls by exactly what the two of them gained.
  const winnerShare = round2(asNum(podium.winnerShare, 0));
  const runnerupShare = round2(asNum(podium.runnerupShare, 0));
  money(winnerShare + runnerupShare, econ.prize, 'F · the two shares total the prize');
  money(round2((econ.prize * asNum(ctx.tRow.winner_percent, 70)) / 100), winnerShare,
    `F · the champion's share is ${ctx.tRow.winner_percent}% of the prize`);

  const ownerAfter = await walletOf(client, ctx.venue.owner_id);
  money(ownerBefore.frozen - ownerAfter.frozen, econ.prize,
    'F · the owner\'s FROZEN balance falls by the whole prize');
  money(ownerAfter.balance, ownerBefore.balance,
    'F · and the owner\'s spendable balance is untouched by the payout');
  money(ownerAfter.frozen, ctx.ownerFrozenBeforePrize,
    'F · the owner\'s frozen is back to what it was before the prize was set aside');

  const champCapAfter = await walletOf(client, ctx.captainByTeam.get(String(fin.teamA)));
  const runnerCapAfter = await walletOf(client, ctx.captainByTeam.get(String(fin.teamB)));
  money(champCapAfter.balance - champCapBefore.balance, winnerShare,
    `F · the champion's captain is paid PKR ${winnerShare}, spendable`);
  money(runnerCapAfter.balance - runnerCapBefore.balance, runnerupShare,
    `F · the runner-up's captain is paid PKR ${runnerupShare}`);
  money(champCapAfter.frozen, champCapBefore.frozen,
    'F · and nothing of the champion\'s is frozen — a prize is theirs to spend');
  const champTxn = (await txnsOf(client, ctx.captainByTeam.get(String(fin.teamA)),
    { type: 'tournament_prize', tournamentId: t.id }))[0];
  check(Boolean(champTxn), 'F · a tournament_prize row records the champion\'s payment');
  if (champTxn) {
    money(champTxn.amount, winnerShare, 'F · with the right amount on it');
    check(/champion/i.test(champTxn.description || ''),
      'F · and a description that says what it was for', champTxn.description);
  }
  const runnerTxn = (await txnsOf(client, ctx.captainByTeam.get(String(fin.teamB)),
    { type: 'tournament_prize', tournamentId: t.id }))[0];
  check(Boolean(runnerTxn), 'F · and one for the runner-up too');

  // The tournament record — achievements instead of a second ELO ladder.
  const champRecord = await teamCounters(client, fin.teamA);
  const runnerRecord = await teamCounters(client, fin.teamB);
  eq(champRecord.titles - champRecordBefore.titles, 1, 'F · the champion gains a title');
  eq(champRecord.finals - champRecordBefore.finals, 1, 'F · and a final reached');
  eq(runnerRecord.titles - runnerRecordBefore.titles, 0, 'F · the runner-up gains no title');
  eq(runnerRecord.finals - runnerRecordBefore.finals, 1, 'F · but does reach the final');
  eq(champRecord.played, 3, 'F · the champion is recorded as having played all three rounds');

  // Every counter, derived from the bracket rather than from my expectation of it:
  // a team's `tournament_played` must equal the number of `played` fixtures it
  // appeared in — which is also the cleanest possible proof that the walkover
  // moved nobody's record, since it appears in the bracket but not in this count.
  const wholeBracket = await bracketNow(client, t.id);
  const expectPlayed = new Map();
  const expectWins = new Map();
  const bump = (m, id) => { if (id) m.set(String(id), (m.get(String(id)) || 0) + 1); };
  for (const f of wholeBracket) {
    if (f.status !== 'played') continue;
    bump(expectPlayed, f.teamA);
    bump(expectPlayed, f.teamB);
    bump(expectWins, f.winner);
  }
  let countersOk = true;
  const countersDetail = [];
  for (const c of ctx.field) {
    const rec = await teamCounters(client, c.teamId);
    const wantPlayed = expectPlayed.get(String(c.teamId)) || 0;
    const wantWins = expectWins.get(String(c.teamId)) || 0;
    if (rec.played !== wantPlayed || rec.wins !== wantWins) {
      countersOk = false;
      countersDetail.push(`${c.teamName}: played ${rec.played}/${wantPlayed} wins ${rec.wins}/${wantWins}`);
    }
  }
  check(countersOk,
    'F · every tournament record matches the played fixtures exactly — the walkover counts for nobody',
    countersDetail.join(' | '));

  // K rose with the stakes. Read back from the trail, per round, so the
  // claim "a final moves a rating ~75% harder than a friendly" is checkable.
  const { rows: ks } = await client.query(
    `SELECT f.round, MIN(eh.k_factor)::numeric AS k
       FROM fixtures f
       JOIN elo_history eh ON eh.match_id = f.match_id
      WHERE f.tournament_id = $1 GROUP BY f.round ORDER BY f.round`, [t.id]);
  const kByRound = new Map(ks.map((r) => [Number(r.round), asNum(r.k, 0)]));
  eq(kByRound.get(1), ctx.policy.kEarly, `K · round 1 was rated at ${ctx.policy.kEarly}`);
  eq(kByRound.get(2), ctx.policy.kSemi, `K · the semi-finals at ${ctx.policy.kSemi}`);
  eq(kByRound.get(3), ctx.policy.kFinal, `K · and the final at ${ctx.policy.kFinal}`);
  const eloPolicy = await settings.elo({ client });
  check(asNum(kByRound.get(3), 0) > asNum(eloPolicy.kFactor, 32),
    `K · a final outweighs a friendly (${kByRound.get(3)} vs ${eloPolicy.kFactor}) — ONE ladder, stake-weighted`,
    'FIDE precedent: one rating, different K per event tier');

  // The tournament row, closed out.
  const finalRow = await T.loadTournament(client, t.id);
  eq(finalRow.status, 'completed', 'F · the tournament row is completed');
  check(Boolean(finalRow.completed_at), 'F · and stamped with when');
  eq(String(finalRow.winner_team), String(fin.teamA), 'F · winner_team is stored on the row');
  eq(String(finalRow.runner_up_team), String(fin.teamB), 'F · runner_up_team too');
  const { rows: still } = await client.query(
    `SELECT status::text AS s, COUNT(*)::int AS n FROM tournament_teams
      WHERE tournament_id = $1 GROUP BY status`, [t.id]);
  const byStatus = new Map(still.map((r) => [r.s, r.n]));
  eq(byStatus.get('accepted') || 0, 1, 'F · exactly one team is left standing');
  eq(byStatus.get('eliminated') || 0, 7, 'F · and the other seven are eliminated');

  // Idempotence, both doors. A double-click on the organiser's Save button, and a
  // stale verify arriving after the bracket already moved on.
  refused((await probe(client, () => T.settleFixture(client, {
    actorId: ctx.venue.owner_id, tournamentId: t.id, fixtureId: fin.id, scoreA: 1, scoreB: 0,
  }))).out, 'not_active', 'a completed tournament takes no further results');
  const reAdvance = await probe(client, () => T.advanceAfterMatch(client, fres.data.matchId));
  eq(reAdvance.out && reAdvance.out.code, 'already_settled',
    're-advancing a settled fixture is a no-op, not a second payout');
  eq(reAdvance.out && reAdvance.out.data.advanced, false, 'and it reports that it advanced nothing');
}

// Block 7 — A field that is not a power of two: byes

/**
 * `max_teams` must be a power of two, but the count at the deadline is whatever
 * turned up. Five teams is therefore the ordinary case, not the exotic
 * one, and the bracket has to absorb it: pad to eight, give the three spare places
 * to the top seeds, and resolve those three immediately so round two has real teams
 * standing in it.
 *
 * The claim being proved is that a bye is bookkeeping, not a match. It consumes no
 * venue hour (so it costs the field nothing), moves no rating, and moves no
 * tournament record — and yet the team it belongs to is in round two before a ball
 * is kicked.
 */
async function block7(client, ctx) {
  section('7 · A FIVE-TEAM FIELD: PADDING, BYES AND WHO GETS THEM');
  const five = ctx.cast.slice(0, 5);
  // These five have already played the eight-team cup, so "a bye moved nothing" is
  // a claim about a delta. Snapshot first, compare after.
  const recordBefore = new Map();
  for (const c of five) recordBefore.set(String(c.teamId), await teamCounters(client, c.teamId));
  const fee = feeFor(ctx, { fixtures: 4, teams: 5 });
  const created = await probe(client, () => T.create(client, {
    ownerId: ctx.venue.owner_id, venueId: ctx.venue.id,
    name: `${PREFIX}Bye Cup`, format: 'knockout', maxTeams: 8, minTeams: 4,
    entryFee: fee, registrationDeadline: new Date(Date.now() + 3600000).toISOString(),
  }));
  if (!worked(created.out, 'a third tournament is posted for a five-team field')) return;
  const t = await T.loadTournament(client, created.out.data.tournament.id);
  for (const c of five) {
    const r = await probe(client, () => T.register(client, {
      userId: c.captainId, tournamentId: t.id, teamId: c.teamId,
    }));
    if (!worked(r.out, `${c.teamName} enters the five-team cup`, r.err && r.err.message)) return;
  }
  await expireDeadline(client, t.id);
  const g = await probe(client, () => T.generateFixtures(client, {
    actorId: ctx.venue.owner_id, tournamentId: t.id, useModel: false,
  }));
  if (!worked(g.out, 'five teams are drawn without a complaint', g.err && g.err.message)) return;
  const d = g.out.data;

  eq(d.teams, 5, 'five teams are in the field');
  eq(d.bracket.size, 8, 'the bracket is padded to the next power of two');
  eq(d.bracket.rounds, 3, 'which is still three rounds');
  eq(d.bracket.byes, 3, 'and the three spare places become byes');
  eq(d.bracket.fixtures, 7, 'seven fixture rows, of which three are byes');

  const rows = await bracketNow(client, t.id);
  const byes = rows.filter((f) => f.isBye);
  eq(byes.length, 3, 'three bye rows exist in the bracket');
  check(byes.every((f) => f.teamB === null), 'a bye has no opponent — team B is NULL');
  check(byes.every((f) => f.status === 'walkover'),
    'a bye is recorded as a walkover, not as an upcoming fixture',
    byes.map((f) => f.status).join(','));
  check(byes.every((f) => String(f.winner) === String(f.teamA)),
    'and is resolved immediately in favour of the team that got it');
  check(byes.every((f) => f.slotId === null),
    'A BYE CONSUMES NO VENUE HOUR — nobody turns up, so nothing is reserved');

  // Who gets them: the top seeds, which is the only defensible answer. Handing a
  // bye to the fifth seed would reward the weakest team in the field.
  const seeds = new Map(d.seeds.map((s) => [String(s.teamId), s.seed]));
  const byeSeeds = byes.map((f) => seeds.get(String(f.teamA))).sort((a, b) => a - b);
  eq(byeSeeds.join(','), '1,2,3',
    'the byes go to the TOP THREE SEEDS, not to whoever entered first');

  const r1real = rows.filter((f) => f.round === 1 && !f.isBye);
  eq(r1real.length, 1, 'exactly one round-one tie is actually played');
  const playedSeeds = [seeds.get(String(r1real[0].teamA)), seeds.get(String(r1real[0].teamB))]
    .sort((a, b) => a - b).join('v');
  eq(playedSeeds, '4v5', 'and it is seeds 4 and 5 — the two teams that missed out');

  // The bye teams are already standing in round two.
  const r2 = rows.filter((f) => f.round === 2);
  const inR2 = new Set(r2.flatMap((f) => [f.teamA, f.teamB]).filter(Boolean).map(String));
  check(byes.every((f) => inR2.has(String(f.teamA))),
    'every bye team is pre-advanced into its round-two node');
  eq([...inR2].length, 3, 'round two holds the three bye teams and one empty slot');

  // Nothing was rated and nothing was recorded.
  const { rows: hist } = await client.query(
    `SELECT COUNT(*)::int AS n FROM elo_history eh
       JOIN matches m ON m.id = eh.match_id WHERE m.tournament_id = $1`, [t.id]);
  eq(hist[0].n, 0, 'no rating moved: three byes wrote no elo_history at all');
  for (const f of byes) {
    const rec = await teamCounters(client, f.teamA);
    const previously = recordBefore.get(String(f.teamA)) || { played: 0, wins: 0 };
    eq(rec.played, previously.played, `${f.teamAName}: a bye is not a game played`);
    eq(rec.wins, previously.wins, `${f.teamAName}: and not a tournament win either`);
  }

  // The money still closes with a five-team field, and the venue cost counts only
  // the four hours that will be used — which is precisely why a short
  // field is cheaper per team rather than a loss for someone.
  const split = d.economics;
  const withSlots = rows.filter((f) => f.slotId);
  eq(withSlots.length, 4, 'four real hours are reserved: seven rows minus three byes');
  money(split.pool, fee * 5, 'the pool is five entry fees, not eight');
  money(split.venueCost, withSlots.reduce((sum, f) => sum + asNum(f.slotPrice, 0), 0),
    'the venue cost counts only the hours the bracket will actually consume');
  money(split.pool, round2(asNum(split.venueCost, 0) + asNum(split.prize, 0) + asNum(split.margin, 0)),
    'and the waterfall still closes to the paisa on an odd field');
  check(asNum(split.ownerEarning, 0) >= asNum(split.venueCost, 0),
    'the owner is still never underwater on a five-team cup',
    `earning ${split.ownerEarning} vs venue cost ${split.venueCost}`);

  // Playing it out: four real fixtures decide it, and the bye teams have to win
  // something before they lift anything.
  let guard = 0;
  for (;;) {
    guard += 1;
    if (guard > 10) { check(false, 'the five-team bracket resolves in a bounded number of rounds'); break; }
    const live = (await bracketNow(client, t.id))
      .filter((f) => f.status === 'upcoming' && f.teamA && f.teamB)
      .sort((a, b) => a.round - b.round || a.position - b.position);
    if (!live.length) break;
    const res = await probe(client, () => T.settleFixture(client, {
      actorId: ctx.venue.owner_id, tournamentId: t.id, fixtureId: live[0].id, scoreA: 2, scoreB: 1,
    }));
    if (!res.ok || !res.out.ok) {
      check(false, `the five-team bracket plays out (round ${live[0].round})`,
        res.err ? res.err.message : res.out.message);
      break;
    }
  }
  const done5 = await T.loadTournament(client, t.id);
  eq(done5.status, 'completed', 'the five-team cup completes');
  check(Boolean(done5.winner_team) && Boolean(done5.runner_up_team),
    'with both a champion and a runner-up');
  const rated = await client.query(
    `SELECT COUNT(*)::int AS n FROM fixtures WHERE tournament_id = $1 AND status = 'played'`, [t.id]);
  eq(rated.rows[0].n, 4, 'exactly four fixtures were played — n-1 for five teams');

  // The podium was paid out of the prize that generation froze, and the owner's
  // frozen balance is level again.
  const champCap = ctx.captainByTeam.get(String(done5.winner_team));
  if (champCap) {
    const paid = (await txnsOf(client, champCap, { type: 'tournament_prize', tournamentId: t.id }))[0];
    check(Boolean(paid), 'the five-team champion is paid from the prize pool');
    if (paid) {
      money(paid.amount, round2((asNum(split.prize, 0) * asNum(t.winner_percent, 70)) / 100),
        'and paid exactly the winner share of it');
    }
  }
}

// Block 8 — round robin: the table, not the bracket (FE-6, FE-7)

/**
 * A league is a different shape of the same module: no elimination, no advance,
 * n(n-1)/2 fixtures, and the champion decided by a table rather than by a final.
 * Four teams is six fixtures over three matchdays, which is small enough to state
 * the whole expected table in advance and then assert it row by row.
 *
 * The results are chosen so that the table exercises every tie-break in turn:
 * a draw shares the points, two teams finish level on points and are separated by
 * goal difference, and nobody wins by accident of insertion order.
 */
async function block8(client, ctx) {
  section('8 · ROUND ROBIN — POINTS, GOAL DIFFERENCE AND A CHAMPION FROM THE TABLE');
  const four = ctx.cast.slice(0, 4);
  const fee = feeFor(ctx, { fixtures: 6, teams: 4 });
  const created = await probe(client, () => T.create(client, {
    ownerId: ctx.venue.owner_id, venueId: ctx.venue.id,
    name: `${PREFIX}Round Robin League`, format: 'round_robin', maxTeams: 4, minTeams: 4,
    entryFee: fee, registrationDeadline: new Date(Date.now() + 3600000).toISOString(),
  }));
  if (!worked(created.out, 'a four-team league is posted', created.err && created.err.message)) return;
  const t = await T.loadTournament(client, created.out.data.tournament.id);
  for (const c of four) {
    const r = await probe(client, () => T.register(client, {
      userId: c.captainId, tournamentId: t.id, teamId: c.teamId,
    }));
    if (!worked(r.out, `${c.teamName} joins the league`, r.err && r.err.message)) return;
  }
  await expireDeadline(client, t.id);
  const g = await probe(client, () => T.generateFixtures(client, {
    actorId: ctx.venue.owner_id, tournamentId: t.id, useModel: false,
  }));
  if (!worked(g.out, 'the league fixture list is generated', g.err && g.err.message)) return;
  const d = g.out.data;

  eq(d.bracket.fixtures, 6, 'four teams play six fixtures — n(n-1)/2, not n-1');
  eq(d.bracket.byes, 0, 'a league has no byes');
  const rows = await bracketNow(client, t.id);
  eq(rows.length, 6, 'six fixture rows exist');
  eq(new Set(rows.map((f) => String(f.slotId))).size, 6, 'each one reserved its own distinct hour');

  // Every team meets every other team exactly once, and nobody plays twice in a day.
  const met = new Set(rows.map((f) => [String(f.teamA), String(f.teamB)].sort().join('|')));
  eq(met.size, 6, 'every pairing occurs exactly once');
  const perDay = new Map();
  for (const f of rows) {
    for (const id of [f.teamA, f.teamB]) {
      const key = `${f.slotDate}#${id}`;
      perDay.set(key, (perDay.get(key) || 0) + 1);
    }
  }
  check([...perDay.values()].every((n) => n === 1),
    'and no team is asked to play twice on the same day',
    [...perDay.entries()].filter(([, n]) => n > 1).map(([k]) => k).join(' '));

  // No advancement structure at all: a league fixture has nowhere to advance to.
  check(rows.every((f) => f.nextRound === null && f.nextPosition === null),
    'no fixture points at a next round — a league does not advance, it accumulates');

  // The results, chosen so the table needs its tie-breaks
  // Seeds 1 and 2 finish level on seven points and are separated by goal
  // difference alone, which is the only way to prove the sort is doing the work.
  const seedOf = new Map(d.seeds.map((s) => [String(s.teamId), s.seed]));
  const PLAN = new Map([
    ['1|2', { winner: 0, goals: [1, 1] }],   // a draw: a point each
    ['1|3', { winner: 1, goals: [3, 0] }],
    ['1|4', { winner: 1, goals: [2, 0] }],
    ['2|3', { winner: 2, goals: [2, 1] }],
    ['2|4', { winner: 2, goals: [3, 0] }],
    ['3|4', { winner: 3, goals: [1, 0] }],
  ]);
  let leagueDraws = 0;
  for (const f of rows) {
    const sa = seedOf.get(String(f.teamA));
    const sb = seedOf.get(String(f.teamB));
    const p = PLAN.get([sa, sb].sort((x, y) => x - y).join('|'));
    if (!p) { check(false, `the league plan covers seeds ${sa} v ${sb}`); continue; }
    const aWins = p.winner === sa;
    const scoreA = p.winner === 0 ? p.goals[0] : (aWins ? p.goals[0] : p.goals[1]);
    const scoreB = p.winner === 0 ? p.goals[1] : (aWins ? p.goals[1] : p.goals[0]);
    const res = await probe(client, () => T.settleFixture(client, {
      actorId: ctx.venue.owner_id, tournamentId: t.id, fixtureId: f.id, scoreA, scoreB,
    }));
    if (!worked(res.out, `league · seed ${sa} ${scoreA}-${scoreB} seed ${sb}`,
      res.err && res.err.message)) continue;
    if (p.winner === 0) {
      leagueDraws += 1;
      eq(res.out.data.winner, null, 'league · a drawn league fixture has NO winner');
      eq(res.out.data.fixture.winner, null, 'league · and the row stores no winner either');
    }
    // Nobody is eliminated by losing a league game — every team plays every matchday.
    const { rows: st } = await client.query(
      `SELECT COUNT(*)::int AS n FROM tournament_teams
        WHERE tournament_id = $1 AND status = 'eliminated'`, [t.id]);
    if (res.out.data.remaining > 0) {
      eq(st[0].n, 0, `league · nobody is eliminated while ${res.out.data.remaining} fixtures remain`);
    }
  }
  eq(leagueDraws, 1, 'league · exactly one fixture was drawn');

  // Every league fixture is rated at the EARLY K — there is no showpiece in a table.
  const { rows: leagueK } = await client.query(
    `SELECT DISTINCT eh.k_factor::numeric AS k
       FROM fixtures f JOIN elo_history eh ON eh.match_id = f.match_id
      WHERE f.tournament_id = $1`, [t.id]);
  eq(leagueK.length, 1, 'league · one K value across the whole league');
  money(leagueK[0] && leagueK[0].k, ctx.policy.kEarly,
    `league · and it is the early-round K (${ctx.policy.kEarly}) — a league has no final to weight`);

  // The table
  // Stated in full and asserted row by row, because "the standings look right" is
  // not a claim: 3/1/0, goal difference as the separator, and the champion taken
  // from the top of the table rather than from a final that a league never plays.
  const view = await probe(client, () => T.detail(client, { tournamentId: t.id }));
  if (!worked(view.out, 'league · the detail read returns a table', view.err && view.err.message)) return;
  const table = view.out.data.standings;
  eq(table.length, 4, 'league · four rows in the table');
  const EXPECT = {
    1: { points: 7, played: 3, wins: 2, draws: 1, losses: 0, goalsFor: 6, goalsAgainst: 1, goalDiff: 5 },
    2: { points: 7, played: 3, wins: 2, draws: 1, losses: 0, goalsFor: 6, goalsAgainst: 2, goalDiff: 4 },
    3: { points: 3, played: 3, wins: 1, draws: 0, losses: 2, goalsFor: 2, goalsAgainst: 5, goalDiff: -3 },
    4: { points: 0, played: 3, wins: 0, draws: 0, losses: 3, goalsFor: 0, goalsAgainst: 6, goalDiff: -6 },
  };
  let tableOk = true;
  const tableDetail = [];
  for (const row of table) {
    const seed = seedOf.get(String(row.teamId));
    const want = EXPECT[seed];
    if (!want) { tableOk = false; tableDetail.push(`unknown seed ${seed}`); continue; }
    for (const key of Object.keys(want)) {
      if (Number(row[key]) !== want[key]) {
        tableOk = false;
        tableDetail.push(`seed ${seed} ${key}=${row[key]} want ${want[key]}`);
      }
    }
  }
  check(tableOk, 'league · every row of the table is exact — 3 for a win, 1 for a draw, 0 for a loss',
    tableDetail.join(' | '));

  const order = table.map((r) => seedOf.get(String(r.teamId)));
  eq(order.join(','), '1,2,3,4', 'league · the table is sorted correctly');
  eq(Number(table[0].position), 1, 'league · and carries a position on each row');
  check(Number(table[0].points) === Number(table[1].points)
    && Number(table[0].goalDiff) > Number(table[1].goalDiff),
    'league · THE TIE-BREAK: the top two are level on points and separated by goal difference',
    `${table[0].points}pts GD${table[0].goalDiff} vs ${table[1].points}pts GD${table[1].goalDiff}`);

  // Completion by the table, and the podium paid to its top two.
  const leagueRow = await T.loadTournament(client, t.id);
  eq(leagueRow.status, 'completed', 'league · playing the last fixture completes the league');
  eq(seedOf.get(String(leagueRow.winner_team)), 1,
    'league · the champion is the team at the top of the table, not the winner of a final');
  eq(seedOf.get(String(leagueRow.runner_up_team)), 2, 'league · and second place is the runner-up');
  const champ = ctx.captainByTeam.get(String(leagueRow.winner_team));
  const paid = champ ? (await txnsOf(client, champ, { type: 'tournament_prize', tournamentId: t.id }))[0] : null;
  check(Boolean(paid), 'league · the table-topper is paid the winner share');
  const leagueSplit = d.economics;
  if (paid) {
    money(paid.amount, round2((asNum(leagueSplit.prize, 0) * asNum(t.winner_percent, 70)) / 100),
      'league · and paid exactly the winner share of the league prize');
  }
  money(leagueSplit.pool, fee * 4, 'league · the pool is four entry fees');
  money(leagueSplit.pool,
    round2(asNum(leagueSplit.venueCost, 0) + asNum(leagueSplit.prize, 0) + asNum(leagueSplit.margin, 0)),
    'league · and the waterfall closes on a league exactly as it does on a knockout');
  check(asNum(leagueSplit.venueCost, 0) > 0 && asNum(leagueSplit.ownerEarning, 0) >= asNum(leagueSplit.venueCost, 0),
    'league · six hours of inventory are recovered before anyone is paid a prize',
    `earning ${leagueSplit.ownerEarning} vs venue cost ${leagueSplit.venueCost}`);
}

// Block 9 — the other door: the S.2 MATCH flow

/**
 * Two doors, one bracket. Block 6 proved the organiser's door; this one proves the
 * captain-submits → organiser-verifies door that S.2 already built, because a
 * tournament whose bracket advanced differently depending on which screen was used
 * would be worse than one with a single door.
 *
 * `routes/matches.js` is an Express handler and cannot be called from here, so what
 * is asserted is the contract it depends on, in the order it uses it:
 *
 *   1. `matchContext` answers who may verify and with what K — and answers `null`
 *      for a friendly, which is the branch that keeps the S.2 path unchanged;
 *   2. the ELO exchange is applied once, by the caller, with that K;
 *   3. `advanceAfterMatch` moves the bracket and does not rate the game a second
 *      time — the one mistake that leaves no trace afterwards;
 *   4. the extended match view resolves a venue, a time and an owner for a match
 *      that has no booking at all.
 */
async function block9(client, ctx) {
  section('9 · THE MATCH-FLOW DOOR (S.2 verify → advanceAfterMatch)');
  const four = ctx.cast.slice(0, 4);
  const created = await probe(client, () => T.create(client, {
    ownerId: ctx.venue.owner_id, venueId: ctx.venue.id,
    name: `${PREFIX}Two Door Cup`, format: 'knockout', maxTeams: 4, minTeams: 4,
    entryFee: feeFor(ctx, { fixtures: 3, teams: 4 }),
    registrationDeadline: new Date(Date.now() + 3600000).toISOString(),
  }));
  if (!worked(created.out, 'a four-team knockout is posted for the match-flow door')) return;
  const t = await T.loadTournament(client, created.out.data.tournament.id);
  for (const c of four) {
    const r = await probe(client, () => T.register(client, {
      userId: c.captainId, tournamentId: t.id, teamId: c.teamId,
    }));
    if (!worked(r.out, `${c.teamName} enters`, r.err && r.err.message)) return;
  }
  await expireDeadline(client, t.id);
  const g = await probe(client, () => T.generateFixtures(client, {
    actorId: ctx.venue.owner_id, tournamentId: t.id, useModel: false,
  }));
  if (!worked(g.out, 'the semi-finals are drawn', g.err && g.err.message)) return;

  const board = await bracketNow(client, t.id);
  const semi = board.filter((f) => f.round === 1).sort((a, b) => a.position - b.position)[0];
  eq(board.length, 3, 'a four-team knockout is two semi-finals and a final');

  // Step 1: the match row a captain's submission produces
  // Written here exactly as `routes/matches.js` writes it: no booking, the
  // tournament on the row, and both scores agreed by the two captains.
  const { rows: ins } = await client.query(
    `INSERT INTO matches
       (challenger_team, opponent_team, booking_id, tournament_id, sport, status,
        score_challenger, score_opponent, created_by)
     VALUES ($1,$2,NULL,$3,$4,'awaiting_owner',4,1,$5) RETURNING id`,
    [semi.teamA, semi.teamB, t.id, t.sport, ctx.captainByTeam.get(String(semi.teamA))]);
  const matchId = ins[0].id;
  await client.query('UPDATE fixtures SET match_id = $2 WHERE id = $1', [semi.id, matchId]);

  // Step 2: matchContext — authority and K, from the tournament
  const mctx = await T.matchContext(client, matchId);
  check(Boolean(mctx) && mctx.isTournament === true,
    'matchContext recognises a tournament match');
  if (mctx) {
    eq(String(mctx.ownerId), String(ctx.venue.owner_id),
      'AUTHORITY: the person entitled to verify is the ORGANISER, reached through tournaments.owner_id');
    // kSemi, not kEarly. This block posts a four-team cup, so it has two rounds
    // and round 1 is the semi-final -- `fx.kFactorFor` returns table.semi for
    // `round === rounds - 1`. Expecting the early K here asserted the shape of an
    // eight-team bracket against a four-team one.
    eq(Number(mctx.kFactor), ctx.policy.kSemi,
      `K: round 1 of a four-team cup is the semi-final, so the stake is ${ctx.policy.kSemi}`);
    eq(String(mctx.fixtureId), String(semi.id), 'and it resolves back to the right fixture');
    eq(Number(mctx.round), 1, 'with the round it belongs to');
    eq(mctx.fixtureStatus, 'upcoming', 'and the fixture is still open');
  }

  // Step 3: the caller applies the exchange once, with that K
  const eloPolicy = await settings.elo({ client });
  const exchange = await elo.applyResult(client, {
    matchId,
    challengerTeam: semi.teamA,
    opponentTeam: semi.teamB,
    winnerTeam: semi.teamA,
    base: eloPolicy.base,
    kFactor: mctx ? mctx.kFactor : ctx.policy.kSemi,
  });
  await client.query(
    `UPDATE matches SET winner_team = $2, status = 'completed', verified_by = $3,
            verified_at = now(), elo_applied = TRUE, results_locked = TRUE
      WHERE id = $1`,
    [matchId, semi.teamA, ctx.venue.owner_id]);
  eq(Number(exchange.kFactor), ctx.policy.kSemi, 'the exchange was rated at the tournament K');

  // Step 4: advanceAfterMatch moves the bracket, and rates nothing
  const adv = await probe(client, () => T.advanceAfterMatch(client, matchId));
  if (worked(adv.out, 'advanceAfterMatch answers on a tournament match', adv.err && adv.err.message)) {
    eq(adv.out.data.advanced, true, 'it reports that it advanced the bracket');
    eq(adv.out.data.fixture.status, 'played', 'the fixture is now played');
    eq(Number(adv.out.data.fixture.scoreA), 4, 'the scoreline landed on the right side of the bracket');
    eq(Number(adv.out.data.fixture.scoreB), 1, 'and the other score on the other side');
    eq(String(adv.out.data.winner), String(semi.teamA), 'with the agreed winner');
    check(adv.out.data.fixtures.some(
      (f) => f.round === 2
        && [String(f.teamA), String(f.teamB)].includes(String(semi.teamA)),
    ), 'and the winner is standing in the final');
  }

  // The assertion this block exists for. Two rows, not four: `advanceAfterMatch`
  // runs with applyElo:false because the caller has already rated the game. A
  // second application would double the rating change for one match and leave no
  // way to tell afterwards which half was real.
  const twice = await eloRowsFor(client, matchId);
  eq(twice.length, 2, 'EXACTLY TWO rating rows for one match — the exchange was NOT applied twice');
  const total = twice.reduce((n, r) => n + asNum(r.elo_delta, 0), 0);
  check(Math.abs(total) < 0.005, 'and it is still zero-sum');
  const { rows: applied } = await client.query(
    'SELECT elo_applied, status::text AS status, verified_by FROM matches WHERE id = $1', [matchId]);
  eq(applied[0].elo_applied, true, 'the match row keeps its elo_applied latch');
  eq(String(applied[0].verified_by), String(ctx.venue.owner_id),
    'and records the organiser as the verifier');

  // Idempotence: a retry, or a second verify racing the first, changes nothing.
  const again = await probe(client, () => T.advanceAfterMatch(client, matchId));
  eq(again.out && again.out.code, 'already_settled', 'a repeat advance is a no-op');
  eq((await eloRowsFor(client, matchId)).length, 2, 'and writes no further rating rows');

  // Step 5: the extended view — a match with no booking still has a where
  const { rows: view } = await client.query(
    `SELECT ${mc.MATCH_VIEW_COLUMNS} ${mc.MATCH_VIEW_FROM} WHERE m.id = $1`, [matchId]);
  check(view.length === 1, 'the match view returns the tournament match');
  if (view.length) {
    const v = view[0];
    eq(v.booking_id, null, 'it genuinely has no booking');
    check(Boolean(v.venue_name), 'and yet it resolves a VENUE, through the fixture\'s slot', String(v.venue_name));
    check(Boolean(v.slot_date) && Boolean(v.start_time), 'and a date and a kick-off time',
      `${v.slot_date} ${v.start_time}`);
    eq(String(v.venue_owner), String(ctx.venue.owner_id),
      'venue_owner resolves to the ORGANISER, which is what the verify screen filters on');
    check(Boolean(v.tournament_name), 'the tournament name is on the row', String(v.tournament_name));
    eq(Number(v.fixture_round), 1, 'so is the round');
    check(Boolean(v.fixture_label), 'and the fixture label', String(v.fixture_label));
    check(v.slot_started === true || v.slot_started === false,
      'slot_started is a real boolean, not NULL — without it the phone hides Submit result',
      String(v.slot_started));
    check(v.ct_delta != null && v.ot_delta != null,
      'and both rating deltas are visible on the row', `${v.ct_delta} / ${v.ot_delta}`);
  }

  // The friendly branch: the S.2 path must be untouched
  // A tournament hook that changed how a friendly behaves would be a regression
  // dressed as a feature, so the null answer is asserted rather than assumed.
  const { rows: fr } = await client.query(
    `INSERT INTO matches
       (challenger_team, opponent_team, booking_id, tournament_id, sport, status, created_by)
     VALUES ($1,$2,NULL,NULL,$3,'challenge_sent',$4) RETURNING id`,
    [four[0].teamId, four[1].teamId, t.sport, four[0].captainId]);
  const friendly = fr[0].id;
  eq(await T.matchContext(client, friendly), null,
    'matchContext returns NULL for a match with no tournament — the S.2 path is unchanged');
  const frAdv = await probe(client, () => T.advanceAfterMatch(client, friendly));
  eq(frAdv.out && frAdv.out.code, 'not_tournament',
    'advanceAfterMatch declines a friendly, so matches.js can call it unconditionally');
  eq(frAdv.out && frAdv.out.ok, true, 'and declines it as a success, not as an error');
  eq(frAdv.out && frAdv.out.data.advanced, false, 'having advanced nothing');
  eq(await T.matchContext(client, 'not-a-uuid'), null, 'and a malformed id is null, not a throw');
  eq((await eloRowsFor(client, friendly)).length, 0, 'the friendly was not rated by any of this');
}

// Block 10 — the closing audit: nothing was minted, nothing vanished

/**
 * Four tournaments have run: one cancelled under the minimum, one eight-team
 * knockout played to a champion, one five-team cup with byes, one league, and one
 * left deliberately mid-flight. Roughly forty wallet movements. This block asks
 * the only question that matters about all of them at once:
 *
 *   is the amount of money in the system the same as it was before any of it ran?
 *
 * It is asked three ways, because each catches a different class of bug:
 *
 *   Total       — every watched wallet's balance plus frozen, summed. Catches a
 *                 payout larger than the pool, and a refund paid twice.
 *   Outstanding — what is still frozen must be exactly the prize of the one
 *                 tournament still in flight. Catches a hold nobody released.
 *   Per row     — for each tournament, what the captains paid in equals the pool
 *                 plus what was refunded, and the pool equals the owner's earning
 *                 plus what the podium was paid. Catches money moving without a
 *                 ledger row to explain it, which is the failure an auditor finds
 *                 and a demo never does.
 */
async function block10(client, ctx, opening) {
  section('10 · THE CLOSING LEDGER AUDIT');
  const closing = await snapshot(client);
  const totalOf = (m) => round2([...m.values()].reduce((n, w) => n + w.total, 0));
  const frozenOf = (m) => round2([...m.values()].reduce((n, w) => n + w.frozen, 0));

  money(totalOf(closing), totalOf(opening),
    `TOTAL MONEY IS CONSERVED across ${watched.size} wallets and four tournaments`);

  const { rows: live } = await client.query(
    `SELECT COALESCE(SUM(prize_amount), 0)::numeric AS held
       FROM tournaments WHERE name LIKE $1 AND status = 'active'`, [`${PREFIX}%`]);
  money(frozenOf(closing) - frozenOf(opening), live[0].held,
    'OUTSTANDING HOLDS are exactly the prize of the one tournament still in flight');

  const { rows: tours } = await client.query(
    `SELECT id, name, status::text AS status, entry_fee,
            COALESCE(pool_amount, 0)::numeric AS pool,
            COALESCE(venue_cost_amount, 0)::numeric AS venue_cost,
            COALESCE(prize_amount, 0)::numeric AS prize,
            COALESCE(owner_earning_amount, 0)::numeric AS owner_earning
       FROM tournaments WHERE name LIKE $1 ORDER BY created_at`, [`${PREFIX}%`]);
  eq(tours.length, 5, 'five tournaments were run by this script');

  let grandIn = 0;
  let grandOut = 0;
  for (const row of tours) {
    const label = row.name.replace(PREFIX, '');
    const { rows: led } = await client.query(
      `SELECT type::text AS type, user_id, COALESCE(SUM(amount), 0)::numeric AS total
         FROM transactions WHERE tournament_id = $1 GROUP BY type, user_id`, [row.id]);
    const sumOf = (type, { owner = null } = {}) => round2(led
      .filter((r) => r.type === type
        && (owner === null
          || (owner ? String(r.user_id) === String(ctx.venue.owner_id)
            : String(r.user_id) !== String(ctx.venue.owner_id))))
      .reduce((n, r) => n + asNum(r.total, 0), 0));

    const paidIn = -sumOf('tournament_entry');
    const refunded = sumOf('refund');
    const pool = round2(asNum(row.pool, 0));
    money(paidIn, round2(pool + refunded),
      `${label}: every rupee paid in either became the pool or went back — ${paidIn} = ${pool} + ${refunded}`);

    if (pool > 0) {
      money(sumOf('tournament_commission', { owner: true }), row.owner_earning,
        `${label}: the owner's commission row equals owner_earning_amount`);
      money(round2(asNum(row.owner_earning, 0) + asNum(row.prize, 0)), pool,
        `${label}: owner earning + prize = pool, to the paisa`);
      if (row.status === 'completed') {
        money(sumOf('tournament_prize', { owner: false }), row.prize,
          `${label}: the podium was paid EXACTLY the prize — no more, no less`);
        money(-sumOf('escrow_release', { owner: true }), row.prize,
          `${label}: and the owner's frozen prize was released to pay it`);
      }
    }
    grandIn = round2(grandIn + paidIn);
    grandOut = round2(grandOut + refunded + pool);
  }
  money(grandIn, grandOut,
    `THE WHOLE RUN: PKR ${grandIn} entered the tournaments and PKR ${grandOut} is accounted for`);

  // Nothing anywhere went negative, and every ledger row records a real balance.
  const { rows: neg } = await client.query(
    `SELECT COUNT(*)::int AS n FROM wallets WHERE user_id = ANY($1::uuid[])
      AND (balance < 0 OR frozen_balance < 0)`, [[...watched.keys()]]);
  eq(neg[0].n, 0, 'no wallet is negative in either column');
  const { rows: orphan } = await client.query(
    `SELECT COUNT(*)::int AS n FROM transactions
      WHERE type::text IN ('tournament_entry','tournament_commission','tournament_prize')
        AND tournament_id IS NULL`);
  eq(orphan[0].n, 0, 'every tournament ledger row names the tournament it belongs to');
}

// The driver

/**
 * `--verify-clean` — the other half of the promise this script makes.
 *
 * Every row it writes is prefixed `zzcheck-` and thrown away by a ROLLBACK. That
 * is easy to claim and easy to get wrong: one stray `pool.query` outside the
 * transaction, or an interrupted run, and the seeded database quietly grows a
 * dozen fake captains. So the claim is separately checkable, from a fresh
 * connection, with no transaction of its own.
 */
async function verifyClean(client) {
  section('--verify-clean · nothing this script writes survives it');
  const probes = [
    ['users', `SELECT COUNT(*)::int AS n FROM users WHERE email LIKE '${PREFIX}%'`],
    ['teams', `SELECT COUNT(*)::int AS n FROM teams WHERE name LIKE '${PREFIX}%'`],
    ['tournaments', `SELECT COUNT(*)::int AS n FROM tournaments WHERE name LIKE '${PREFIX}%'`],
    ['fixtures', `SELECT COUNT(*)::int AS n FROM fixtures f
                    JOIN tournaments t ON t.id = f.tournament_id
                   WHERE t.name LIKE '${PREFIX}%'`],
    ['blocked slots', `SELECT COUNT(*)::int AS n FROM slots s
                         WHERE s.status = 'blocked' AND EXISTS (
                           SELECT 1 FROM fixtures f JOIN tournaments t ON t.id = f.tournament_id
                            WHERE f.slot_id = s.id AND t.name LIKE '${PREFIX}%')`],
  ];
  for (const [what, sql] of probes) {
    const { rows } = await client.query(sql);
    eq(rows[0].n, 0, `no ${what} rows from a previous run are left in the database`);
  }
}

/** The run. One transaction, every block in order, and a ROLLBACK either way. */
async function main() {
  const client = await pool.connect();
  const ctx = {};
  let rolled = false;
  try {
    if (VERIFY_CLEAN) {
      await verifyClean(client);
      return;
    }

    ctx.policy = await settings.tournament({ client });
    ctx.eloPolicy = await settings.elo({ client });
    ctx.useModel = !ARGS.includes('--no-model');

    ctx.venue = await pickVenue(client);
    if (!ctx.venue) {
      console.log('\n  ✗ no venue in this database has 28 free priced hours over 4+ days ahead.');
      console.log('    Seed slots first (node src/scripts/seed_venues.js), then re-run.');
      failures.push('a venue with enough free hours to place four brackets');
      return;
    }
    const sport = String(ctx.venue.sport_type || '').toLowerCase();
    const otherSport = sport === 'cricket' ? 'football' : 'cricket';
    watch(ctx.venue.owner_id, `the venue owner (${ctx.venue.name})`);

    console.log(`\n  venue    ${ctx.venue.name} — ${ctx.venue.city}, ${sport}`);
    console.log(`  hours    ${ctx.venue.free_hours} free over ${ctx.venue.free_days} days`
      + `, PKR ${ctx.venue.cheapest}–${ctx.venue.dearest} each`);
    console.log(`  model    ${ctx.useModel ? 'demand model WILL be asked (pass --no-model to skip)' : 'skipped (--no-model)'}`);
    console.log(`  K        friendly ${ctx.eloPolicy.kFactor} · early ${ctx.policy.kEarly}`
      + ` · semi ${ctx.policy.kSemi} · final ${ctx.policy.kFinal}`);

    await client.query('BEGIN');

    // The cast: twelve who play, one in the wrong sport, one with an empty wallet.
    // Funded well past the four entry fees any one of them pays, because the point
    // of the wallet assertions is the delta, not the opening number.
    ctx.cast = await makeCast(client, { sport, city: ctx.venue.city, count: 12, fund: 60000 });
    [ctx.wrongSport] = await makeCast(client, {
      sport: otherSport, city: ctx.venue.city, count: 1, fund: 60000,
      tag: 'alt', eloTop: 1200, phoneBase: 9100000,
    });
    [ctx.broke] = await makeCast(client, {
      sport, city: ctx.venue.city, count: 1, fund: 0,
      tag: 'broke', eloTop: 1100, phoneBase: 9200000,
    });
    ctx.captainByTeam = new Map([...ctx.cast, ctx.wrongSport, ctx.broke]
      .map((c) => [String(c.teamId), c.captainId]));

    // The baseline for the closing audit, taken after funding and before any
    // tournament exists. Funding a wallet is a mint; the tournaments must not be.
    const opening = await snapshot(client);

    await blockConfig(client, ctx);
    await blockEconomics(client, ctx);

    // The tournament the middle of this script is about: eight teams, a real fee
    // priced off this venue's own hours, and a deadline the script moves itself.
    section('The cup itself — posted by the venue owner (FE-1)');
    const cupFee = feeFor(ctx, { fixtures: 7, teams: 8 });
    const posted = await probe(client, () => T.create(client, {
      ownerId: ctx.venue.owner_id, venueId: ctx.venue.id,
      name: `${PREFIX}Champions Cup`, format: 'knockout',
      description: 'Written and destroyed by check_tournaments.js.',
      maxTeams: 8, minTeams: 4, entryFee: cupFee,
      registrationDeadline: new Date(Date.now() + 2 * 3600000).toISOString(),
      useModel: ctx.useModel,
    }));
    if (!worked(posted.out, `an 8-team knockout is posted at PKR ${cupFee} a team`,
      posted.err && posted.err.message)) {
      throw new Error('the tournament could not be created, so nothing downstream can be asserted');
    }
    ctx.t8 = await T.loadTournament(client, posted.out.data.tournament.id);

    const filled = await blockRegistration(client, ctx, ctx.t8);
    if (filled) {
      await blockGenerate(client, ctx, ctx.t8);
      if (ctx.generated) await block6(client, ctx);
      else skip('the results, the podium and the K table', 'the bracket was not drawn');
    } else {
      skip('the draw, the podium and the K table', 'the eight-team field could not be filled');
    }

    // These three post their own tournaments, so they run whatever happened above.
    await blockUnderMinimum(client, ctx);
    await block7(client, ctx);
    await block8(client, ctx);
    await block9(client, ctx);
    await block10(client, ctx, opening);

    // The evidence pack, while the numbers are still in hand
    if (ev.on) {
      const sch = (ctx.generated && ctx.generated.meta && ctx.generated.meta.scheduling) || {};
      const econ = (ctx.generated && ctx.generated.economics) || {};
      ev.addMeta('venue', `${ctx.venue.name} — ${ctx.venue.city}, ${ctx.venue.sport_type}`);
      ev.addMeta('free hours scanned', `${ctx.venue.free_hours} over ${ctx.venue.free_days} days`
        + `, PKR ${ctx.venue.cheapest}–${ctx.venue.dearest} an hour`);
      ev.addMeta('scheduler', `${sch.source || 'not reached'}`
        + `${sch.modelVersion ? ` · ${sch.modelVersion}` : ''}`
        + `${sch.coverage ? ` · scored ${sch.coverage.scored}/${sch.coverage.total} candidate hours` : ''}`
        + `${sch.reason ? ` · ${sch.reason}` : ''}`);
      ev.addMeta('K factors', `friendly ${ctx.eloPolicy.kFactor} · early ${ctx.policy.kEarly}`
        + ` · semi ${ctx.policy.kSemi} · final ${ctx.policy.kFinal}`);
      ev.addMeta('transaction', 'one BEGIN, one ROLLBACK — no row below outlived the run');
      if (econ.pool != null) {
        ev.addFact('The waterfall on a real venue',
          `PKR ${cupFee} × 8 teams = **${econ.pool}** pool · venue cost **${econ.venueCost}** `
          + `(seven real slot prices) · prize **${econ.prize}** (winner ${econ.winnerShare}, `
          + `runner-up ${econ.runnerupShare}) · owner **${econ.ownerEarning}**.`);
        ev.addFact('The owner is never worse off than selling the hours',
          `owner earning ${econ.ownerEarning} against a retail value of ${econ.retailValue} for the `
          + 'same seven hours — the venue cost is recovered before any prize is set aside.');
      }
      if (ctx.preview && ctx.preview.recommended) {
        ev.addFact('The fee is quoted, not guessed',
          `\`POST /api/tournaments/preview\` recommended PKR ${ctx.preview.recommended.entryFee} `
          + 'a team before the tournament existed, from this venue\'s own slot prices.');
      }
      ev.addFact('One ELO ladder, weighted by stake',
        `read back out of \`elo_history.k_factor\`: round 1 at K=${ctx.policy.kEarly}, the semi-finals `
        + `at ${ctx.policy.kSemi}, the final at ${ctx.policy.kFinal} against ${ctx.eloPolicy.kFactor} `
        + 'for a friendly — and K=0 for a bye, which writes no rating row at all.');
      ev.addFact('Reservation, not booking',
        'every fixture holds a real slot at `status = blocked` and NOT ONE `bookings` row was '
        + 'written, so no captain is charged twice and `noShowJob` has nothing to sweep.');
    }
  } catch (err) {
    console.error(`\n  ✗ the run stopped: ${err.message}`);
    // The stack, not the message alone. A bare pg message like "inconsistent types
    // deduced for parameter $5" names no file and no query, and hunting it by eye
    // across 1900 lines is the slowest possible way to fix a one-line bug.
    if (err.stack) {
      const NL = String.fromCharCode(10);
      console.error(String(err.stack).split(NL).slice(1, 7).join(NL));
    }
    if (err.code) console.error(`  sqlstate ${err.code}`);
    failures.push(`the run completed without throwing (${err.message})`);
  } finally {
    if (!VERIFY_CLEAN) {
      await client.query('ROLLBACK').catch(() => {});
      rolled = true;
      // The rollback, proven rather than asserted: the same connection, now outside
      // any transaction, must not be able to see a single row this run wrote.
      section('The rollback');
      try {
        const { rows } = await client.query(
          `SELECT (SELECT COUNT(*) FROM users WHERE email LIKE $1)::int AS users,
                  (SELECT COUNT(*) FROM tournaments WHERE name LIKE $1)::int AS tournaments`,
          [`${PREFIX}%`],
        );
        eq(rows[0].users, 0, 'after ROLLBACK not one captain this run created still exists');
        eq(rows[0].tournaments, 0, 'and not one tournament — the database is exactly as it was');
      } catch (err) {
        check(false, 'the rollback could be verified', err.message);
      }
    }
    client.release();
  }
  if (!rolled && !VERIFY_CLEAN) console.log('\n  ! the transaction was NOT rolled back');
}

/**
 * The verdict.
 *
 * A skip is printed alongside the pass count and never inside it: a case the
 * seeded data could not supply is a case that did not run, and folding it into the
 * pass total would turn thin data into a green tick. The exit code is non-zero only
 * for a real failure, so a skip does not break a pipeline while a broken rule does.
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
