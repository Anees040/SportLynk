/**
 * S.7 Wave A — tournament demo seed.
 *
 * The problem it solves
 * The tournament module has one beat that cannot be demonstrated from a cold
 * database: the deadline arrives, and eight paid-up teams are drawn onto real venue
 * hours by a job nobody pressed. Reaching that beat by hand means registering eight
 * players, creating eight teams, funding eight wallets and then waiting for a
 * deadline that was set days out — twenty minutes of tapping before the interesting
 * two seconds. This writes the whole board in one command and sets the deadline two
 * minutes out, so the job does the interesting part while the log is still open.
 *
 * What it leaves behind (it commits — this is a demo seed, not a check)
 *   • 8 captains with funded wallets, 8 teams on descending ELO (1720 … 1350) so the
 *     bracket's seeding is legible: seed 1 must meet seed 8.
 *   • One knockout tournament at a venue already owned, entry fee quoted by
 *     `POST /api/tournaments/preview` rather than picked out of the air, with all
 *     eight teams registered and their fees genuinely held in escrow.
 *   • A registration deadline `--deadline` seconds out (default 120). Nothing else:
 *     no fixtures, no blocked slots, no bracket. Those are the job's to write, and
 *     watching it write them is the point.
 *
 * Why the deadline is moved after registration, not at creation
 * `register` refuses once the deadline has passed — correctly. Creating the cup with
 * a two-minute deadline would race the eight registrations against it and the last
 * captains would be turned away with `deadline_passed`. So the cup is created with a
 * comfortable deadline, the field is filled, and only then is the clock moved to two
 * minutes out. That is a seeder's licence to write state the API would not: the API
 * is being demonstrated, not bypassed — every rupee still moves through
 * `tournamentService.register`.
 *
 * The job has to be running, and its sweep is 5 minutes by default
 * `tournamentJob` sweeps on `POLICY.SWEEP_INTERVAL_MS`, which is 5 minutes unless
 * `SL_TEST_SWEEP_SECONDS` says otherwise. A two-minute deadline with a five-minute
 * sweep means up to five minutes of staring at a log. Start the server as:
 *
 *   SL_TEST_SWEEP_SECONDS=20 npm run dev        (PowerShell: $env:SL_TEST_SWEEP_SECONDS=20)
 *
 * …or skip the wait entirely with `--generate`, which draws the bracket through the
 * organiser's own endpoint path instead of the job's.
 *
 * It chooses a venue, it never creates one
 * The whole economic argument is denominated in `slots.price`, so the venue must be
 * real, priced, owned, and carry enough genuinely free hours for a 7-fixture bracket
 * spread over enough days. Same predicate the check script uses. If nothing
 * qualifies it says so and stops rather than inventing inventory.
 *
 * Idempotent. Captains are keyed on a stable email prefix, teams on a marker in
 * `teams.bio`, the cup on its name. Re-running tops wallets up, fills any missing
 * entry, and leaves everything else alone.
 *
 * USAGE
 *   node seed_tournament_demo.js                  seed (safe to re-run)
 *   node seed_tournament_demo.js --deadline=120   seconds until the deadline
 *   node seed_tournament_demo.js --fee=3000       override the quoted entry fee
 *   node seed_tournament_demo.js --generate       draw the bracket now, don't wait
 *   node seed_tournament_demo.js --play           settle every unplayed fixture
 *   node seed_tournament_demo.js --verify         bracket, standings, money, audit
 *   node seed_tournament_demo.js --undo           remove exactly what it created
 */
require('dotenv').config();
const pool = require('./src/db/pool');
const T = require('./src/services/tournamentService');
const fx = require('./src/utils/fixtures');
const discovery = require('./src/services/discoveryService');
const settings = require('./src/utils/globalSettings');
const { round2, asNum } = require('./src/utils/escrow');
const bcrypt = require('bcrypt');

// The board

/** Stable marker, written into `teams.bio`, so --undo finds its own teams. */
const MARK = 'SEED_TOURNAMENT_DEMO';
const EMAIL_PREFIX = 'demo-cup-';
const CUP_NAME = 'SportLynk Invitational (demo)';
/** Real, signable accounts: the UI pass needs to log in as a captain. */
const PASSWORD = 'demo1234';

/**
 * Eight squads on descending ELO. The gaps are 50-70 points, wide enough that
 * `seedTeams` produces one unambiguous order — eight teams all on 1000 would make
 * "seed 1 plays seed 8" unprovable — and narrow enough that the win probabilities
 * printed on the bracket read as a real field rather than a mismatch.
 */
const SQUADS = [
  { team: 'Clifton Chargers', captain: 'Bilal Ahmed', elo: 1720 },
  { team: 'Gulberg Galaxy', captain: 'Hassan Raza', elo: 1660 },
  { team: 'DHA Dynamos', captain: 'Usman Tariq', elo: 1600 },
  { team: 'Model Town Mavericks', captain: 'Ayesha Khan', elo: 1550 },
  { team: 'Saddar Strikers', captain: 'Zain Abbas', elo: 1500 },
  { team: 'Johar Jets', captain: 'Fatima Noor', elo: 1450 },
  { team: 'Bahria Blues', captain: 'Omar Sheikh', elo: 1400 },
  { team: 'Cantt Cobras', captain: 'Danish Iqbal', elo: 1350 },
];

const TEAMS = SQUADS.length;
const FIXTURES = fx.fixtureCount(fx.FORMATS.KNOCKOUT, TEAMS); // 7
const DEFAULT_DEADLINE_SECONDS = 120;

const ARGS = process.argv.slice(2);
const has = (flag) => ARGS.includes(flag);
const numArg = (name, dflt) => {
  const hit = ARGS.find((a) => a.startsWith(`${name}=`));
  const n = hit ? Number(hit.slice(name.length + 1)) : NaN;
  return Number.isFinite(n) && n > 0 ? n : dflt;
};

const log = (m) => console.log(`   ${m}`);
const section = (t) => console.log(`\n── ${t} ${'─'.repeat(Math.max(0, 58 - t.length))}`);
const pkr = (v) => `PKR ${asNum(v).toLocaleString('en-US', { maximumFractionDigits: 2 })}`;
const pad = (s, n) => String(s == null ? '' : s).padEnd(n);

/** '2026-08-29 18:00' from a timestamptz, in the reader's own clock. */
function when(value) {
  if (!value) return '—';
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? String(value) : d.toISOString().slice(0, 16).replace('T', ' ');
}

// Prerequisites — the venue, which is chosen and never created

/**
 * The same predicate `check_tournaments.js` uses, for the same reasons: a real price
 * (the economics are denominated in `slots.price`), an owner (only owners may post a
 * cup), a sport teams play, and enough free hours over enough days that a
 * three-round bracket with a gap between rounds can be placed.
 *
 * The floor is FIXTURES + slack rather than exactly FIXTURES, because the round gap
 * pushes later rounds onto later days and a venue with exactly seven free hours all
 * on one afternoon cannot host a three-round cup.
 */
async function pickVenue(client) {
  const now = discovery.pktNow();
  const { rows } = await client.query(
    `SELECT v.id, v.name, v.city, v.sport_type, v.owner_id,
            v.price_per_hour, v.base_price,
            u.name AS owner_name, u.email AS owner_email,
            count(s.id)::int AS free_hours,
            count(DISTINCT s.slot_date)::int AS free_days,
            min(s.price)::numeric AS cheapest,
            max(s.price)::numeric AS dearest,
            round(avg(s.price), 2)::numeric AS typical
       FROM venues v
       JOIN users u ON u.id = v.owner_id
       JOIN slots s ON s.venue_id = v.id
      WHERE v.is_active AND v.owner_id IS NOT NULL
        AND COALESCE(v.price_per_hour, v.base_price, 0) > 0
        AND LOWER(v.sport_type) IN ('football', 'cricket')
        AND s.status = 'available' AND s.price > 0
        AND NOT ${discovery.HOLD_IS_LIVE}
        AND (s.slot_date > $1::date OR (s.slot_date = $1::date AND s.start_time >= $2::time))
        AND s.slot_date <= ($1::date + 20)
        AND NOT EXISTS (SELECT 1 FROM fixtures f WHERE f.slot_id = s.id AND f.status <> 'cancelled')
      GROUP BY v.id, u.name, u.email
     HAVING count(s.id) >= $3 AND count(DISTINCT s.slot_date) >= 3
      ORDER BY count(s.id) DESC
      LIMIT 1`,
    [now.date, now.time, FIXTURES + 5],
  );
  return rows[0] || null;
}

/** The cup, by name. Returns the full loaded row (or null) so callers can branch. */
async function findCup(client) {
  const { rows } = await client.query('SELECT id FROM tournaments WHERE name = $1 LIMIT 1', [CUP_NAME]);
  return rows[0] ? T.loadTournament(client, rows[0].id) : null;
}

// The cast — eight captains, eight squads, eight funded wallets

/**
 * Idempotent on three keys: the captain's email, the team's (name, sport) — which
 * carries a unique index — and the wallet's user_id.
 *
 * The wallet is topped up with GREATEST, never overwritten. A blunt `SET balance`
 * would look harmless and quietly break the audit: on a second run the eight fees
 * are already sitting in `frozen_balance`, and resetting `balance` would mint money
 * the ledger has no row for, which is precisely what `--verify` exists to catch.
 *
 * A team whose name is taken by somebody who is not this seeder stops the run. The
 * alternative — adopting it — would put a real squad in a demo cup and then delete
 * them on `--undo`, and no amount of convenience is worth that.
 */
async function ensureCast(client, { sport, city, fund, passwordHash, resetRatings }) {
  const cast = [];
  let madeUsers = 0;
  let madeTeams = 0;
  let resetElo = 0;
  for (let i = 0; i < SQUADS.length; i += 1) {
    const s = SQUADS[i];
    const email = `${EMAIL_PREFIX}${i + 1}@sportlynk.test`;

    let { rows: u } = await client.query('SELECT id FROM users WHERE email = $1', [email]);
    if (!u.length) {
      u = (await client.query(
        `INSERT INTO users (email, password_hash, name, phone, role, phone_verified, is_active)
         VALUES ($1, $2, $3, $4, 'player', TRUE, TRUE) RETURNING id`,
        [email, passwordHash, s.captain, `+92309${String(9500000 + i).slice(-7)}`],
      )).rows;
      madeUsers += 1;
    }
    const captainId = u[0].id;
    await client.query(
      `INSERT INTO player_profiles (user_id) SELECT $1
        WHERE NOT EXISTS (SELECT 1 FROM player_profiles WHERE user_id = $1)`,
      [captainId],
    );

    let { rows: t } = await client.query(
      `SELECT id, name, elo, bio, captain_id FROM teams
        WHERE lower(btrim(name)) = lower(btrim($1)) AND sport = $2`,
      [s.team, sport],
    );
    if (t.length && t[0].bio !== MARK) {
      throw new Error(`the team name "${s.team}" (${sport}) already belongs to somebody else `
        + '— rename it, or edit SQUADS in this file');
    }
    if (!t.length) {
      t = (await client.query(
        // $5 and $6 both carry the ELO: `elo` is integer, the legacy `elo_rating`
        // is numeric(8,2), and a single placeholder feeding both makes Postgres
        // deduce two conflicting types for one parameter (42P08).
        `INSERT INTO teams (name, sport, captain_id, city, elo, elo_rating, visibility, bio)
         VALUES ($1,$2,$3,$4,$5,$6,'public',$7) RETURNING id, name, elo`,
        [s.team, sport, captainId, city, s.elo, s.elo, MARK],
      )).rows;
      madeTeams += 1;
    }
    await client.query(
      `INSERT INTO team_members (team_id, user_id, role) VALUES ($1,$2,'captain')
       ON CONFLICT (team_id, user_id) DO NOTHING`,
      [t[0].id, captainId],
    );
    // Reset the rating on a re-run, but only while no tournament match has been
    // played: `generateFixtures` seeds on ELO, so a squad carrying last cup's
    // winnings would be seeded somewhere other than where this file says it is.
    // Once a bracket is live those ratings are the result of `elo_history` rows,
    // and rewinding them would make the ladder disagree with its own audit trail.
    // Only the rating is ever touched: the tournament counters on `teams` are the
    // record this module exists to build, and wiping those would erase it.
    if (resetRatings && asNum(t[0].elo) !== s.elo) {
      await client.query('UPDATE teams SET elo = $2, elo_rating = $2 WHERE id = $1', [t[0].id, s.elo]);
      t[0].elo = s.elo;
      resetElo += 1;
    }
    await client.query(
      `INSERT INTO wallets (user_id, balance, frozen_balance) VALUES ($1,$2,0)
       ON CONFLICT (user_id) DO UPDATE SET balance = GREATEST(wallets.balance, $2)`,
      [captainId, fund],
    );
    cast.push({
      captainId, teamId: t[0].id, teamName: s.team, captain: s.captain, elo: asNum(t[0].elo),
    });
  }
  // The seed is not the order of SQUADS — it is whatever `seedTeams` makes of the
  // ratings that are in the table, which is the same function (and the same
  // name/id tie-break) `generateFixtures` will run at the deadline. Deriving it here
  // rather than asserting it means the printed seeding cannot drift from the drawn one.
  const seeds = new Map(fx.seedTeams(
    cast.map((c) => ({ id: c.teamId, name: c.teamName, elo: c.elo })),
  ).map((t) => [t.id, t.seed]));
  cast.forEach((c) => { c.seed = seeds.get(c.teamId); });
  return { cast, madeUsers, madeTeams, resetElo };
}

// Seed

/** Every rupee still moves through the service. Only the clock is written directly. */
async function registerAll(client, cup, cast) {
  let entered = 0;
  let already = 0;
  for (const c of cast) {
    const res = await T.register(client, { userId: c.captainId, tournamentId: cup.id, teamId: c.teamId });
    if (res.ok) { entered += 1; continue; }
    if (res.code === 'already_registered') { already += 1; continue; }
    throw new Error(`${c.teamName} could not enter (${res.code}): ${res.message}`);
  }
  return { entered, already };
}

async function seed() {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    const venue = await pickVenue(client);
    if (!venue) {
      await client.query('ROLLBACK');
      console.log(`\n❌ No venue qualifies. A demo cup needs one active, owned, priced venue with at`
        + ` least ${FIXTURES + 5} free priced hours over 3+ days in the next 20 days.`);
      log('Open next week\'s slots for a venue (owner app → Slots), then run this again.');
      console.log('');
      return;
    }
    const policy = await settings.tournament({ client });
    const hourly = asNum(venue.typical) || asNum(venue.price_per_hour) || asNum(venue.base_price);

    section('The venue (chosen, not created)');
    log(`${venue.name} · ${venue.city} · ${venue.sport_type}`);
    log(`owner: ${venue.owner_name} <${venue.owner_email}>`);
    log(`${venue.free_hours} free priced hours over ${venue.free_days} days · `
      + `${pkr(venue.cheapest)}–${pkr(venue.dearest)} an hour (typically ${pkr(hourly)})`);

    // The quote: the fee is asked for, not invented
    const quote = await T.preview(client, {
      ownerId: venue.owner_id, venueId: venue.id, name: CUP_NAME,
      format: fx.FORMATS.KNOCKOUT, maxTeams: TEAMS, minTeams: policy.minTeams, entryFee: 0,
    });
    if (!quote.ok) throw new Error(`preview refused the quote (${quote.code}): ${quote.message}`);
    const rec = quote.data.recommended;
    const fee = round2(numArg('--fee', asNum(rec.entryFee)));
    const atFee = fx.splitPool({
      entryFee: fee, teams: TEAMS, slotTotal: quote.data.capacity.slotTotal ?? quote.data.capacity.estimatedCost,
      venueDiscountPercent: 0, prizePercent: policy.prizePercent,
      winnerPercent: policy.winnerPercent, runnerupPercent: policy.runnerupPercent,
    });

    section('The quote (POST /api/tournaments/preview)');
    log(`${TEAMS} teams · knockout · ${FIXTURES} fixtures · ${quote.data.candidateHours} candidate hours scanned`);
    log(`venue cost at capacity : ${pkr(atFee.slotTotal)}   (${FIXTURES} real slot prices, not an estimate)`);
    log(`recommended entry fee  : ${pkr(rec.entryFee)}   (covers the floor of ${rec.minTeams} teams `
      + `plus a ${rec.targetMarginPercent}% margin)`);
    if (fee !== asNum(rec.entryFee)) log(`overridden by --fee     : ${pkr(fee)}`);
    log(`pool at ${TEAMS} teams      : ${pkr(atFee.pool)}`);
    log(`  prize                : ${pkr(atFee.prize)}  →  winner ${pkr(atFee.winnerShare)} · `
      + `runner-up ${pkr(atFee.runnerupShare)}`);
    log(`  owner earns          : ${pkr(atFee.ownerEarning)}  (${pkr(atFee.venueCost)} covering the hours `
      + `+ ${pkr(atFee.margin)} margin)`);
    if (atFee.upliftPercent != null) {
      log(`  vs selling the hours : ${pkr(atFee.retailValue)}  →  ${atFee.upliftPercent >= 0 ? '+' : ''}`
        + `${atFee.upliftPercent}% for the owner`);
    }
    if (!quote.data.capacity.schedulable) {
      log(`⚠ ${quote.data.capacity.message} — the cup is still created, but the bracket cannot be drawn yet.`);
    }

    // The cast
    // The cup is looked up before the wallets are funded, because on a re-run it is
    // the cup's stored fee that registration will charge — not today's quote. Fund
    // against the quote and a cup created last week at a higher fee would turn its
    // own captains away with `insufficient_funds`.
    let cup = await findCup(client);
    const feeInPlay = cup ? asNum(cup.entry_fee) : fee;
    const fund = Math.max(round2(feeInPlay * 1.5), 5000);
    // Hashed once and shared: eight bcrypt rounds at cost 12 is two seconds of
    // nothing, and the password is the same for all eight by design.
    const passwordHash = await bcrypt.hash(PASSWORD, 12);
    const preBracket = !cup || (cup.status === T.STATUS.OPEN && !cup.fixtures_generated_at);
    const { cast, madeUsers, madeTeams, resetElo } = await ensureCast(client, {
      sport: venue.sport_type, city: venue.city, fund, passwordHash, resetRatings: preBracket,
    });
    section('The cast');
    log(`${madeUsers} captain(s) created, ${TEAMS - madeUsers} already existed · `
      + `${madeTeams} team(s) created · every wallet topped to at least ${pkr(fund)}`
      + `${resetElo ? ` · ${resetElo} rating(s) reset so the seeding is repeatable` : ''}`);
    log(`they are REAL accounts you can sign in as: ${EMAIL_PREFIX}1@sportlynk.test `
      + `… ${EMAIL_PREFIX}${TEAMS}@sportlynk.test, password "${PASSWORD}"`);
    cast.forEach((c) => log(`  seed ${c.seed}  ${pad(c.teamName, 22)} ${pad(c.captain, 16)} ELO ${c.elo}`));

    // The cup
    if (cup && (cup.status !== T.STATUS.OPEN || cup.fixtures_generated_at)) {
      await client.query('COMMIT');
      section('Already in flight');
      log(`"${CUP_NAME}" is ${cup.status}${cup.fixtures_generated_at ? ' with a bracket already drawn' : ''}.`);
      log('The cast and their wallets were topped up; the cup itself was left alone.');
      log('node seed_tournament_demo.js --verify    to inspect it');
      log('node seed_tournament_demo.js --undo      to clear it and start over');
      console.log('');
      return;
    }

    let created = false;
    if (!cup) {
      const startDate = new Date(Date.now() + 24 * 3600 * 1000).toISOString().slice(0, 10);
      const made = await T.create(client, {
        ownerId: venue.owner_id,
        venueId: venue.id,
        name: CUP_NAME,
        description: 'Eight squads, one knockout, drawn automatically at the deadline onto this '
          + 'venue\'s quietest hours. Seeded on ELO — the winner takes 70% of the prize pool.',
        format: fx.FORMATS.KNOCKOUT,
        entryFee: fee,
        maxTeams: TEAMS,
        minTeams: policy.minTeams,
        requiresApproval: false,
        // Comfortably ahead, so the eight registrations below cannot race it. The
        // clock is moved to `--deadline` seconds only once the field is full.
        registrationDeadline: new Date(Date.now() + 2 * 3600 * 1000).toISOString(),
        startDate,
      });
      if (!made.ok) throw new Error(`create refused (${made.code}): ${made.message}`);
      cup = await T.loadTournament(client, made.data.tournament.id);
      created = true;
    }

    const reg = await registerAll(client, cup, cast);
    const seconds = Math.round(numArg('--deadline', DEFAULT_DEADLINE_SECONDS));
    const { rows: moved } = await client.query(
      `UPDATE tournaments SET registration_deadline = now() + make_interval(secs => $2)
        WHERE id = $1 RETURNING registration_deadline`,
      [cup.id, seconds],
    );
    cup = await T.loadTournament(client, cup.id);

    section(created ? 'The cup (created)' : 'The cup (already existed, field topped up)');
    log(`${cup.name}`);
    log(`entry fee ${pkr(cup.entry_fee)} · ${cup.teams_holding}/${cup.max_teams} teams in · `
      + `${reg.entered} entered now, ${reg.already} already were`);
    log(`escrow held: ${pkr(round2(asNum(cup.entry_fee) * Number(cup.teams_holding)))} across `
      + `${cup.teams_holding} captains' frozen balances`);
    log(`deadline moved to ${when(moved[0].registration_deadline)}  (${seconds}s from now)`);

    // Optionally draw it here, instead of waiting for the job
    let drawn = null;
    if (has('--generate')) {
      drawn = await T.generateFixtures(client, {
        actorId: venue.owner_id, tournamentId: cup.id, useModel: !has('--no-model'),
      });
      if (!drawn.ok) throw new Error(`generate refused (${drawn.code}): ${drawn.message}`);
    }

    await client.query('COMMIT');

    if (drawn) {
      const s = drawn.data.meta.scheduling;
      section('The bracket (drawn now, --generate)');
      log(drawn.message);
      log(`scheduling source: ${s.source}${s.modelVersion ? ` · model ${s.modelVersion}` : ''}`
        + `${s.coverage ? ` · ${s.coverage.scored}/${s.coverage.total} hours scored` : ''}`);
      if (s.reason) log(`reason: ${s.reason}`);
      printFixtures(drawn.data.fixtures);
      log('');
      log('node seed_tournament_demo.js --play      settle every fixture and pay the podium');
      log('node seed_tournament_demo.js --verify    the full audit');
      console.log('');
      return;
    }

    section('Now watch the job do the interesting part');
    log(`1. start the API with a fast sweep so you are not waiting five minutes:`);
    log(`     PowerShell:  $env:SL_TEST_SWEEP_SECONDS=20; npm run dev`);
    log(`     bash:        SL_TEST_SWEEP_SECONDS=20 npm run dev`);
    log(`2. within ~${seconds}s + one sweep, [TournamentJob] draws the bracket, blocks ${FIXTURES} `
      + `slots, pays the owner and freezes the prize.`);
    log(`3. node seed_tournament_demo.js --verify   ← bracket, standings, money, audit`);
    log(`4. sign in as ${venue.owner_email} to enter results, or as any captain to watch the bracket.`);
    log('');
    log('In a hurry, or the server is not running?');
    log('   node seed_tournament_demo.js --generate   draws it immediately through the owner path');
    console.log('');
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    throw e;
  } finally {
    client.release();
  }
}

// Printing

/** The bracket as the demo will describe it: round, slot, price, scoreline. */
function printFixtures(fixtures) {
  let round = 0;
  for (const f of [...fixtures].sort((x, y) => x.round - y.round || x.position - y.position)) {
    if (f.round !== round) {
      round = f.round;
      console.log(`   ── round ${round}${f.label ? ` · ${f.label}` : ''}`);
    }
    const tie = `${pad(f.teamAName || 'TBD', 22)} v ${pad(f.teamBName || (f.isBye ? '(bye)' : 'TBD'), 22)}`;
    const at = f.isBye
      ? 'no hour consumed'
      : `${f.slotDate || '—'} ${String(f.startTime || '').slice(0, 5)} · ${pkr(f.slotPrice)}`;
    const outcome = f.scoreline
      ? `${f.scoreline}  → ${f.winner === f.teamA ? f.teamAName : f.teamBName}`
      : (f.isBye ? `walkover → ${f.teamAName}` : (f.winProbabilityA == null ? ''
        : `${Math.round(f.winProbabilityA * 100)}% / ${Math.round(f.winProbabilityB * 100)}%`));
    log(`  ${tie}  ${pad(at, 30)} ${outcome}`);
  }
}

// Play — settle every unplayed fixture through the organiser's own door

/**
 * Deterministic scores, with one deliberate upset.
 *
 * The favourite winning every tie would make the final champion identical to seed 1,
 * and a bracket that always agrees with the seeding proves nothing about whether the
 * bracket follows results. So the first fixture of round 1 goes to the underdog, and
 * everything after that goes to the higher ELO by a goal. The upset then has to
 * propagate: if advancement were seed-driven rather than result-driven, round 2 would
 * contain the wrong team and `--verify` would show it.
 */
function scoreFor(f, upsetId) {
  const a = f.teamAElo == null ? 1000 : f.teamAElo;
  const b = f.teamBElo == null ? 1000 : f.teamBElo;
  const favouriteIsA = a >= b;
  const upset = f.id === upsetId;
  const aWins = upset ? !favouriteIsA : favouriteIsA;
  return aWins ? { scoreA: 2, scoreB: 1 } : { scoreA: 1, scoreB: 2 };
}

/**
 * Each result is its own transaction, exactly as `PATCH /:id/fixtures/:fid/result`
 * would be: one request, one commit. A single transaction around all seven would
 * hide the thing worth demonstrating — that the bracket advances, and the final
 * settles the tournament, as separate committed steps.
 */
async function play() {
  const cup = await findCup(pool);
  if (!cup) {
    console.log(`\n❌ "${CUP_NAME}" does not exist yet. Run the seed first.\n`);
    return;
  }
  if (cup.status === T.STATUS.COMPLETED) {
    console.log(`\n✔ "${CUP_NAME}" is already complete. node seed_tournament_demo.js --verify\n`);
    return;
  }
  if (cup.status !== T.STATUS.ACTIVE) {
    console.log(`\n❌ "${CUP_NAME}" is ${cup.status} — there is no bracket to play.`);
    log(cup.status === T.STATUS.OPEN
      ? 'Wait for the deadline job, or run --generate to draw it now.'
      : 'It was cancelled; --undo and seed again.');
    console.log('');
    return;
  }

  const first = (await T.loadFixtures(pool, cup.id)).map(T.shapeFixture);
  const upsetId = (first
    .filter((f) => f.round === 1 && !f.isBye && f.teamA && f.teamB)
    .sort((x, y) => x.position - y.position)[0] || {}).id || null;

  section(`Playing out ${cup.name}`);
  let settled = 0;
  for (let guard = 0; guard <= first.length + 2; guard += 1) {
    const rows = (await T.loadFixtures(pool, cup.id)).map(T.shapeFixture);
    const next = rows
      .filter((f) => f.status === fx.FIXTURE_STATUS.UPCOMING && f.teamA && f.teamB)
      .sort((x, y) => x.round - y.round || x.position - y.position)[0];
    if (!next) break;

    const { scoreA, scoreB } = scoreFor(next, upsetId);
    const res = await T.settleFixtureTx({
      actorId: cup.owner_id, tournamentId: cup.id, fixtureId: next.id, scoreA, scoreB,
    });
    if (!res.ok) throw new Error(`result refused (${res.code}): ${res.message}`);
    settled += 1;
    const f = res.data.fixture;
    const k = res.data.elo ? res.data.elo.kFactor : null;
    log(`R${next.round} ${pad(next.teamAName, 22)} ${scoreA}-${scoreB} ${pad(next.teamBName, 22)}`
      + ` → ${f.winner === next.teamA ? next.teamAName : next.teamBName}`
      + `${k == null ? '' : `  (K=${k})`}${next.id === upsetId ? '   ← the upset' : ''}`);
  }
  log(`${settled} fixture(s) settled.`);
  await printPodium(pool, cup.id);
}

// Verify — every number below is read back from the database, not remembered

/** Who won, who came second, and what each was paid. */
async function printPodium(client, tournamentId) {
  const { rows } = await client.query(
    `SELECT t.status, t.prize_amount, t.winner_percent, t.runnerup_percent,
            w.name AS champion, r.name AS runner_up,
            wc.name AS champion_captain, rc.name AS runner_up_captain
       FROM tournaments t
       LEFT JOIN teams w ON w.id = t.winner_team
       LEFT JOIN teams r ON r.id = t.runner_up_team
       LEFT JOIN users wc ON wc.id = w.captain_id
       LEFT JOIN users rc ON rc.id = r.captain_id
      WHERE t.id = $1`, [tournamentId],
  );
  const t = rows[0];
  if (!t || t.status !== T.STATUS.COMPLETED) return;
  const { rows: paid } = await client.query(
    `SELECT u.name, tr.amount FROM transactions tr JOIN users u ON u.id = tr.user_id
      WHERE tr.tournament_id = $1 AND tr.type = 'tournament_prize' AND tr.amount > 0
      ORDER BY tr.amount DESC`, [tournamentId],
  );
  section('The podium');
  log(`🏆 ${t.champion} (${t.champion_captain})`);
  log(`🥈 ${t.runner_up} (${t.runner_up_captain})`);
  for (const p of paid) log(`paid ${pad(p.name, 20)} ${pkr(p.amount)}`);
}

async function verify() {
  const cup = await findCup(pool);
  if (!cup) {
    console.log(`\n❌ "${CUP_NAME}" does not exist. Run the seed first.\n`);
    return;
  }
  const res = await T.detail(pool, { tournamentId: cup.id, userId: cup.owner_id });
  if (!res.ok) throw new Error(res.message);
  const d = res.data;

  section('The cup');
  log(`${d.tournament.name} · ${d.tournament.format} · ${d.tournament.status}`);
  log(`${d.tournament.venue ? d.tournament.venue.name : '—'} · entry ${pkr(d.tournament.entryFee)} · `
    + `${d.counts.holding}/${d.tournament.maxTeams} teams`);
  log(`deadline ${when(d.tournament.registrationDeadline)}`
    + `${d.tournament.fixturesGeneratedAt ? ` · bracket drawn ${when(d.tournament.fixturesGeneratedAt)}` : ''}`);

  if (!d.bracket.generated) {
    log('No bracket yet — the deadline job has not run. --generate draws it now.');
  } else {
    section(`The bracket (${d.bracket.rounds} rounds, ${d.bracket.total} fixtures, `
      + `${d.bracket.byes} bye(s), ${d.bracket.played} played)`);
    printFixtures(d.fixtures);
  }

  if (d.tournament.format === fx.FORMATS.ROUND_ROBIN || d.bracket.played > 0) {
    section('Standings');
    log(`${pad('#', 3)}${pad('team', 24)}${pad('P', 3)}${pad('W', 3)}${pad('D', 3)}${pad('L', 3)}`
      + `${pad('GF', 4)}${pad('GA', 4)}${pad('GD', 5)}pts`);
    d.standings.forEach((s, i) => log(
      `${pad(i + 1, 3)}${pad(s.name, 24)}${pad(s.played, 3)}${pad(s.wins, 3)}${pad(s.draws, 3)}`
      + `${pad(s.losses, 3)}${pad(s.goalsFor, 4)}${pad(s.goalsAgainst, 4)}`
      + `${pad(s.goalDiff > 0 ? `+${s.goalDiff}` : s.goalDiff, 5)}${s.points}`,
    ));
  }

  // The money, read from the tournament row and the ledger
  const e = d.economics;
  section(e.settled ? 'The economics (settled — these rupees moved)' : 'The economics (projected)');
  log(`pool        ${pkr(e.pool)}  = ${pkr(e.entryFee)} x ${e.teams} teams`);
  log(`venue cost  ${pkr(e.venueCost)}  ← recovered by the owner FIRST`);
  log(`prize       ${pkr(e.prize)}  (${e.prizePercent}% of the surplus)`);
  log(`  winner    ${pkr(e.winnerShare)}   runner-up ${pkr(e.runnerupShare)}`);
  log(`owner earns ${pkr(e.ownerEarning)}  = ${pkr(e.venueCost)} cost + ${pkr(e.margin)} margin`);
  if (e.underwater) log('⚠ underwater: the pool did not cover the venue, so there is no prize.');

  // The claim the plan makes in words, checked against rows: what the reserved
  // hours would have fetched at their own listed prices, against what the owner
  // was paid for them.
  const { rows: hours } = await pool.query(
    `SELECT COUNT(*)::int AS n, COALESCE(SUM(s.price), 0)::numeric AS retail,
            COALESCE(round(AVG(s.price), 2), 0)::numeric AS avg_taken,
            COUNT(*) FILTER (WHERE s.status = 'blocked')::int AS blocked
       FROM fixtures f JOIN slots s ON s.id = f.slot_id
      WHERE f.tournament_id = $1`, [cup.id],
  );
  const { rows: mkt } = await pool.query(
    `SELECT COALESCE(round(AVG(price), 2), 0)::numeric AS avg_all
       FROM slots WHERE venue_id = $1 AND price > 0`, [cup.venue_id],
  );
  if (hours[0].n > 0) {
    const retail = asNum(hours[0].retail);
    const uplift = retail > 0 ? round2(((asNum(e.ownerEarning) - retail) / retail) * 100) : null;
    section('The owner is better off than selling the same hours');
    log(`${hours[0].n} hours reserved (${hours[0].blocked} still blocked) worth ${pkr(retail)} at list`);
    log(`owner earned ${pkr(e.ownerEarning)} → ${uplift == null ? '—' : `${uplift >= 0 ? '+' : ''}${uplift}%`}`);
    log(`average hour taken ${pkr(hours[0].avg_taken)} vs ${pkr(mkt[0].avg_all)} across this venue`);
    log(asNum(hours[0].avg_taken) <= asNum(mkt[0].avg_all)
      ? '✔ the scheduler took cheaper-than-average hours — the owner keeps their sellable peak'
      : '· the scheduler took dearer-than-average hours (a peak final, or a thin week of inventory)');
  }

  // The ledger: three identities, each read from `transactions`
  const { rows: led } = await pool.query(
    `SELECT type::text AS type, COUNT(*)::int AS n, COALESCE(SUM(amount), 0)::numeric AS total,
            COALESCE(SUM(amount) FILTER (WHERE user_id = $2), 0)::numeric AS owner_total
       FROM transactions WHERE tournament_id = $1 GROUP BY type ORDER BY type`,
    [cup.id, cup.owner_id],
  );
  section('The ledger');
  const sumOf = (type, field = 'total') => {
    const hit = led.find((r) => r.type === type);
    return hit ? round2(asNum(hit[field])) : 0;
  };
  for (const r of led) log(`${pad(r.type, 24)}${pad(r.n, 4)} row(s)  ${pkr(r.total)}`);
  const paidIn = round2(-sumOf('tournament_entry'));
  const refunded = sumOf('refund');
  const podium = round2(sumOf('tournament_prize') - sumOf('tournament_prize', 'owner_total'));
  const check = (ok, line) => log(`${ok ? '✔' : '✘'} ${line}`);
  check(paidIn === round2(asNum(e.pool) + refunded),
    `every rupee in is accounted for: ${pkr(paidIn)} paid in = ${pkr(e.pool)} pool + ${pkr(refunded)} refunded`);
  check(sumOf('tournament_commission', 'owner_total') === round2(asNum(e.ownerEarning)),
    `the owner's commission row equals owner_earning_amount (${pkr(e.ownerEarning)})`);
  check(round2(asNum(e.ownerEarning) + asNum(e.prize)) === round2(asNum(e.pool)),
    `owner earning + prize = pool, to the paisa`);
  if (d.tournament.status === T.STATUS.COMPLETED) {
    check(podium === round2(asNum(e.prize)),
      `the podium was paid exactly the prize: ${pkr(podium)}`);
  } else if (asNum(e.prize) > 0) {
    log(`· ${pkr(e.prize)} is still frozen in the owner's wallet, waiting on the final`);
  }

  // The wallets
  const { rows: wallets } = await pool.query(
    `SELECT u.name, u.email, w.balance, w.frozen_balance,
            (w.balance + w.frozen_balance)::numeric AS total
       FROM wallets w JOIN users u ON u.id = w.user_id
      WHERE u.email LIKE $1 OR u.id = $2
      ORDER BY (u.id = $2) DESC, u.email`,
    [`${EMAIL_PREFIX}%`, cup.owner_id],
  );
  section('The wallets');
  log(`${pad('who', 26)}${pad('spendable', 16)}${pad('frozen', 16)}total`);
  for (const w of wallets) {
    log(`${pad(w.name, 26)}${pad(pkr(w.balance), 16)}${pad(pkr(w.frozen_balance), 16)}${pkr(w.total)}`);
  }
  const negatives = wallets.filter((w) => asNum(w.balance) < 0 || asNum(w.frozen_balance) < 0);
  check(negatives.length === 0, `no wallet is negative in either column (${wallets.length} checked)`);

  // The scheduler's provenance is not a column — it is in the notification the
  // owner was sent, which is where a demo can also point at it on screen.
  const { rows: prov } = await pool.query(
    `SELECT payload FROM notifications
      WHERE type = 'tournament_generated' AND payload->>'tournamentId' = $1
      ORDER BY created_at DESC LIMIT 1`, [String(cup.id)],
  );
  if (prov.length) {
    const p = prov[0].payload || {};
    section('Provenance');
    log(`scheduling source: ${p.source || '—'}  `
      + `(${p.source === 'model' ? 'the released demand model chose these hours' : 'chronological fallback — ml-service was unreachable'})`);
    log(`${p.hours} hours · owner ${pkr(p.ownerEarning)} · venue cost ${pkr(p.venueCost)} · prize ${pkr(p.prize)}`);
  }

  await printPodium(pool, cup.id);
  console.log('');
}

// Undo — remove exactly what seed() created, in FK-safe order

/**
 * Order matters twice over here.
 *
 * `matches.tournament_id` and `transactions.tournament_id` are both on DELETE SET
 * NULL, so the match ids and the ledger rows have to be collected and deleted
 * before the tournament row goes — afterwards they are orphans nothing can find.
 * And the reserved slots must be handed back before the fixtures are deleted, for
 * the same reason: `fixtures.slot_id` is the only record of which hours were taken,
 * and a cascade would erase the evidence while leaving the slots blocked forever.
 *
 * Deleting the captains is the one step allowed to fail. A demo captain who has
 * since booked a court has history this script did not create and must not remove,
 * so that case is caught inside a SAVEPOINT and reported instead of cascading.
 */
async function undo() {
  const client = await pool.connect();
  const counted = {};
  const del = async (label, sql, params) => {
    const r = await client.query(sql, params);
    if (r.rowCount) counted[label] = (counted[label] || 0) + r.rowCount;
    return r.rowCount;
  };
  try {
    await client.query('BEGIN');
    const tIds = (await client.query('SELECT id FROM tournaments WHERE name = $1', [CUP_NAME]))
      .rows.map((r) => r.id);
    const teamIds = (await client.query('SELECT id FROM teams WHERE bio = $1', [MARK]))
      .rows.map((r) => r.id);
    const userIds = (await client.query('SELECT id FROM users WHERE email LIKE $1', [`${EMAIL_PREFIX}%`]))
      .rows.map((r) => r.id);
    if (!tIds.length && !teamIds.length && !userIds.length) {
      await client.query('ROLLBACK');
      console.log('\n🧹 Nothing to undo — this seed has left nothing behind.\n');
      return;
    }
    const matchIds = (await client.query(
      `SELECT id FROM matches
        WHERE tournament_id = ANY($1::uuid[])
           OR challenger_team = ANY($2::uuid[]) OR opponent_team = ANY($2::uuid[])`,
      [tIds, teamIds],
    )).rows.map((r) => r.id);

    // 1 · the hours go back on sale before the fixtures that name them disappear
    await del('slots unblocked',
      `UPDATE slots SET status = 'available'
        WHERE status = 'blocked'
          AND id IN (SELECT slot_id FROM fixtures WHERE tournament_id = ANY($1::uuid[]) AND slot_id IS NOT NULL)`,
      [tIds]);

    // 2 · the match state machine, deepest child first
    await del('elo history', 'DELETE FROM elo_history WHERE match_id = ANY($1::uuid[]) OR team_id = ANY($2::uuid[])',
      [matchIds, teamIds]);
    await del('disputes', 'DELETE FROM disputes WHERE match_id = ANY($1::uuid[])', [matchIds]);
    await del('match results', 'DELETE FROM match_results WHERE match_id = ANY($1::uuid[])', [matchIds]);
    await client.query('UPDATE fixtures SET match_id = NULL WHERE match_id = ANY($1::uuid[])', [matchIds]);
    await del('matches', 'DELETE FROM matches WHERE id = ANY($1::uuid[])', [matchIds]);

    // 3 · the ledger, while `tournament_id` still points somewhere
    await del('transactions',
      'DELETE FROM transactions WHERE tournament_id = ANY($1::uuid[]) OR user_id = ANY($2::uuid[])',
      [tIds, userIds]);

    // 4 · the tournament — fixtures and entries cascade off it
    await del('entries', 'DELETE FROM tournament_teams WHERE team_id = ANY($1::uuid[])', [teamIds]);
    await del('fixtures', 'DELETE FROM fixtures WHERE tournament_id = ANY($1::uuid[])', [tIds]);
    await del('tournaments', 'DELETE FROM tournaments WHERE id = ANY($1::uuid[])', [tIds]);

    // 5 · chat, if a demo captain ever opened a team channel
    const channelIds = (await client.query(
      `SELECT id FROM chat_channels WHERE ref_id = ANY($1::uuid[]) OR created_by = ANY($2::uuid[])`,
      [teamIds, userIds],
    )).rows.map((r) => r.id);
    if (channelIds.length) {
      await del('chat reactions',
        `DELETE FROM chat_reactions WHERE message_id IN
           (SELECT id FROM chat_messages WHERE channel_id = ANY($1::uuid[]))`, [channelIds]);
      await del('chat messages', 'DELETE FROM chat_messages WHERE channel_id = ANY($1::uuid[])', [channelIds]);
      await del('chat members', 'DELETE FROM chat_channel_members WHERE channel_id = ANY($1::uuid[])', [channelIds]);
      await del('chat channels', 'DELETE FROM chat_channels WHERE id = ANY($1::uuid[])', [channelIds]);
    }
    await client.query('UPDATE chat_channels SET last_message_sender_id = NULL WHERE last_message_sender_id = ANY($1::uuid[])', [userIds]);
    await del('chat messages (elsewhere)', 'DELETE FROM chat_messages WHERE sender_id = ANY($1::uuid[])', [userIds]);
    await del('chat members (elsewhere)', 'DELETE FROM chat_channel_members WHERE user_id = ANY($1::uuid[])', [userIds]);

    // 6 · the squads
    await del('team members', 'DELETE FROM team_members WHERE team_id = ANY($1::uuid[])', [teamIds]);
    await del('team invites', 'DELETE FROM team_invites WHERE team_id = ANY($1::uuid[])', [teamIds]);
    await del('join requests', 'DELETE FROM team_join_requests WHERE team_id = ANY($1::uuid[])', [teamIds]);
    await del('teams', 'DELETE FROM teams WHERE id = ANY($1::uuid[])', [teamIds]);

    // 7 · the captains — the one step allowed to fail
    let orphans = 0;
    if (userIds.length) {
      await client.query('SAVEPOINT drop_cast');
      try {
        await del('wallets', 'DELETE FROM wallets WHERE user_id = ANY($1::uuid[])', [userIds]);
        await del('captains', 'DELETE FROM users WHERE id = ANY($1::uuid[])', [userIds]);
      } catch (e) {
        await client.query('ROLLBACK TO SAVEPOINT drop_cast');
        orphans = userIds.length;
        counted.wallets = 0;
        counted.captains = 0;
        console.log(`\n⚠ the demo captains were kept: ${e.message}`);
        log('They have history this script did not create (a booking, a review). Remove that first.');
      }
    }
    await client.query('COMMIT');

    section('Undo');
    const lines = Object.entries(counted).filter(([, n]) => n > 0);
    if (!lines.length) log('nothing left to remove');
    for (const [what, n] of lines) log(`${pad(what, 26)}${n}`);
    if (orphans) log(`${pad('captains kept', 26)}${orphans}`);
    console.log('');
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    throw e;
  } finally {
    client.release();
  }
}


(async () => {
  try {
    if (has('--undo')) await undo();
    else if (has('--verify')) await verify();
    else if (has('--play')) await play();
    else await seed();
  } catch (e) {
    console.error('\n❌ seed_tournament_demo failed:', e.message);
    if (e.detail) console.error('   detail:', e.detail);
    if (e.code) console.error('   code:', e.code);
    process.exitCode = 1;
  } finally {
    await pool.end().catch(() => {});
  }
})();
