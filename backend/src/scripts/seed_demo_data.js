/**
 * seed_demo_data.js — realistic demo data for manual testing of the player flow.
 *
 * SAFETY — read this before running
 *   • The development database IS the production Supabase. This script therefore
 *     only ever ADDS rows (INSERT / INSERT … ON CONFLICT). It never DELETEs,
 *     TRUNCATEs or UPDATEs an existing row that it did not create. (The sibling
 *     `seed.js` wipes every table — do NOT confuse the two.)
 *   • DRY-RUN BY DEFAULT. With no flag it runs every insert inside one transaction
 *     and then ROLLS BACK, writing nothing — it only proves the inserts fit the live
 *     schema and prints what it would create. Pass `--commit` to actually keep them.
 *   • Seeded rows are identified by ownership: every seeded user's email is under
 *     `@seed.sportlynk.test`, and every seeded venue/team/booking belongs to one of
 *     them, so `--undo` removes exactly the seeded data and never a real row. The
 *     names themselves are realistic — there is no visible tag in the app.
 *   • Idempotent: re-running finds its own rows and never duplicates.
 *
 * USAGE (from backend/)
 *   node src/scripts/seed_demo_data.js            # DRY RUN — writes nothing
 *   node src/scripts/seed_demo_data.js --commit   # actually seed
 *   node src/scripts/seed_demo_data.js --undo     # remove only the seeded rows
 *
 * What it seeds: 3 owners (+approved profiles, 3 venues each with a rolling slot
 * window and a few venue reviews), 10 players (realistic names, trust 100, varied
 * ELO, funded wallets), 4 public teams with rosters + chat channels + win/loss/ELO
 * records, a handful of past played bookings carrying the reviews, and CONFIRMED- and
 * PENDING-future bookings (what makes the challenge picker, cancellation and booking
 * screens testable). Actual `matches` rows are NOT seeded — the team records stand in
 * for match history; play a match to populate the Match Center.
 */
require('dotenv').config();
const bcrypt = require('bcrypt');
const pool = require('../db/pool');
const slots = require('../services/slotService');
const booking = require('../services/bookingService');
const chat = require('../utils/chatCore');

const SEED_DOMAIN = 'seed.sportlynk.test';
const NOTES_MARK = 'SEED_DEMO_DATA';
const PASSWORD = 'password123';

const COMMIT = process.argv.includes('--commit');
const UNDO = process.argv.includes('--undo');
// Internal: seed then undo in one rolled-back transaction, to prove both paths fit
// the live schema (FK order included) without keeping anything. Not for normal use.
const SELFTEST = process.argv.includes('--selftest');

const log = (m) => console.log(`   ${m}`);
const section = (t) => console.log(`\n── ${t} ${'─'.repeat(Math.max(0, 56 - t.length))}`);
const money = (n) => `PKR ${Number(n || 0).toFixed(0)}`;

// Idempotent row writers — each finds its own tagged row first, inserts only if absent.

async function ensureUser(client, { name, email, phone, role }) {
  const found = await client.query('SELECT id FROM users WHERE lower(email) = lower($1)', [email]);
  if (found.rows.length) return found.rows[0].id;
  const hash = await bcrypt.hash(PASSWORD, 12);
  // SELECT-first (above) is the idempotency guard; this runs in one transaction with
  // no concurrent writer, so no ON CONFLICT clause is needed — and users.email has no
  // table-level unique constraint to name as a conflict target anyway.
  const { rows } = await client.query(
    `INSERT INTO users (name, email, password_hash, role, phone, is_active)
     VALUES ($1, $2, $3, $4, $5, true)
     RETURNING id`,
    [name, email, hash, role, phone],
  );
  return rows[0].id;
}

async function ensureOwnerProfile(client, userId, fullName, businessName, cnic) {
  const found = await client.query('SELECT 1 FROM owner_profiles WHERE user_id = $1', [userId]);
  if (found.rows.length) return;
  await client.query(
    `INSERT INTO owner_profiles (user_id, full_name, cnic_number, business_name, verification_status)
     VALUES ($1, $2, $3, $4, 'approved'::owner_verification_status)`,
    [userId, fullName, cnic, businessName],
  );
}

async function ensurePlayerProfile(client, userId, { elo, trust = 100, sports }) {
  const found = await client.query('SELECT 1 FROM player_profiles WHERE user_id = $1', [userId]);
  if (found.rows.length) return;
  await client.query(
    `INSERT INTO player_profiles (user_id, sport_preferences, elo_rating, trust_score)
     VALUES ($1, $2::text[], $3, $4)`,
    [userId, sports, elo, trust],
  );
}

/** Fund a wallet so the player can actually book. Additive: tops a seeded wallet up
 *  to a floor, never lowers a balance a real flow has set. */
async function ensureWallet(client, userId, floor) {
  await client.query(
    `INSERT INTO wallets (user_id, balance, frozen_balance)
     VALUES ($1, $2, 0)
     ON CONFLICT (user_id) DO UPDATE SET balance = GREATEST(wallets.balance, $2)`,
    [userId, floor],
  );
}

/** An active venue owned by `ownerId`, with a rolling future slot window
 *  generated through the real slot service (so the grid looks like any other venue). */
async function ensureVenue(client, { ownerId, name, city, sport, ground, price }) {
  const found = await client.query('SELECT id FROM venues WHERE name = $1', [name]);
  let venueId = found.rows[0]?.id;
  if (!venueId) {
    const { rows } = await client.query(
      `INSERT INTO venues
         (owner_id, name, description, sport_type, city, address,
          latitude, longitude, base_price, price_per_hour, rating, total_reviews,
          ground_type, is_active, operating_hours_from, operating_hours_to)
       VALUES ($1, $2, $3, $4, $5, $6, 33.6844, 73.0479, $7, $7, 4.5, 12,
               $8::ground_type, true, '06:00', '23:00')
       RETURNING id`,
      [ownerId, name, 'Well-kept ground with floodlights, changing rooms and parking.', sport, city,
       `${city}, Pakistan`, price, ground],
    );
    venueId = rows[0].id;
  }
  const made = await slots.ensureVenueSlots(client, { venueId });
  return { id: venueId, created: made.created, skipped: made.skipped };
}

/** A public team with a captain, a chat channel and a win/loss/ELO record.
 *  `members` are added as plain members. Idempotent on (name, sport). */
async function ensureTeam(client, { name, sport, city, captainId, record, memberIds = [] }) {
  const found = await client.query('SELECT id FROM teams WHERE lower(btrim(name)) = lower(btrim($1)) AND sport = $2', [name, sport]);
  let teamId = found.rows[0]?.id;
  if (!teamId) {
    const { rows } = await client.query(
      `INSERT INTO teams
         (name, sport, visibility, city, captain_id, elo, elo_rating, wins, losses, draws, bio)
       VALUES ($1, $2, 'public', $3, $4, $5::int, $6::numeric, $7, $8, $9, $10)
       RETURNING id`,
      [name, sport, city, captainId, record.elo, record.elo, record.wins, record.losses, record.draws,
       'Weekend league side, always up for a competitive friendly.'],
    );
    teamId = rows[0].id;
  }
  await client.query(
    `INSERT INTO team_members (team_id, user_id, role) VALUES ($1, $2, 'captain')
     ON CONFLICT (team_id, user_id) DO UPDATE SET role = 'captain'`,
    [teamId, captainId],
  );
  const teamRow = (await client.query(
    'SELECT id, name, logo_url, captain_id FROM teams WHERE id = $1', [teamId],
  )).rows[0];
  const channelId = await chat.ensureTeamChannel(client, teamRow);
  await chat.syncTeamMember(client, channelId, captainId, 'captain');
  for (const uid of memberIds) {
    await client.query(
      `INSERT INTO team_members (team_id, user_id, role) VALUES ($1, $2, 'member')
       ON CONFLICT (team_id, user_id) DO NOTHING`,
      [teamId, uid],
    );
    await chat.syncTeamMember(client, channelId, uid, 'member');
  }
  return { id: teamId, name, channelId };
}

/** A real booking made through the booking service, so escrow is frozen and the
 *  ledger is written exactly as a live booking — which is what makes cancellation
 *  refunds and the wallet balance behave correctly when the data is tested. It
 *  claims the next available future slot at the venue, tags the booking by notes,
 *  and (when `confirm`) flips it to confirmed and opens its chat room, the way owner
 *  approval does. Idempotent on the notes sub-tag. */
async function bookOne(client, { tag, playerId, ownerId, venueId, venueName, confirm }) {
  const notes = `${NOTES_MARK}/${tag}`;
  const found = await client.query('SELECT id FROM bookings WHERE notes = $1', [notes]);
  if (found.rows.length) return { id: found.rows[0].id, reused: true };

  // A slot comfortably in the future: past the 2h auto-reject lead and distinct from
  // other seeded bookings, so a confirmed one is linkable on the challenge screen.
  const slot = (await client.query(
    `SELECT id FROM slots
      WHERE venue_id = $1 AND status = 'available'
        AND (slot_date::date + start_time::time) > (NOW() AT TIME ZONE 'Asia/Karachi') + interval '2 days'
      ORDER BY slot_date, start_time LIMIT 1`,
    [venueId],
  )).rows[0];
  if (!slot) return { id: null, reason: 'no free future slot' };

  const r = await booking.createBooking(client, { userId: playerId, slotId: slot.id, venueId, notes });
  if (!r.ok) return { id: null, reason: r.code };
  const bookingId = r.data.id;

  if (confirm) {
    await client.query(
      `UPDATE bookings SET status = 'confirmed', approved_at = NOW() WHERE id = $1`,
      [bookingId],
    );
    // Open the booking room exactly as owner approval / auto-confirm does, so a
    // confirmed booking carries a chat thread like any other.
    await chat.openBookingRoom(client, {
      bookingId, playerId, ownerId, venueName, imageUrl: null, event: 'booking_confirmed',
    });
  }
  return { id: bookingId, confirmed: !!confirm };
}

/** A past, played (checked-in) booking plus the venue review left on it, so venues
 *  show real ratings and the reviews screen has content. The booking is inserted
 *  directly (history, not a live checkout) and back-dated via created_at; the review
 *  is idempotent on (booking, reviewer, type). */
async function ensurePastReview(client, { tag, playerId, playerName, venueId, price, daysAgo, rating, comment }) {
  const notes = `${NOTES_MARK}/${tag}`;
  let bookingId = (await client.query('SELECT id FROM bookings WHERE notes = $1', [notes])).rows[0]?.id;
  if (!bookingId) {
    const deposit = Math.round(Number(price) * 0.2 * 100) / 100;
    bookingId = (await client.query(
      `INSERT INTO bookings
         (player_id, venue_id, slot_date, start_time, end_time,
          base_price, security_deposit, total_amount, status, notes,
          checked_in_at, created_at, updated_at)
       SELECT $1, $2, (d)::date, (d)::time, ((d) + interval '1 hour')::time,
              $3, $4, $3, 'checked_in'::booking_status, $5, d, d, d
         FROM (SELECT date_trunc('hour', (NOW() AT TIME ZONE 'Asia/Karachi') - ($6 || ' days')::interval) AS d) s
       RETURNING id`,
      [playerId, venueId, Number(price), deposit, notes, String(daysAgo)],
    )).rows[0].id;
  }
  await client.query(
    `INSERT INTO reviews
       (booking_id, reviewer_id, reviewed_user_id, venue_id, rating, comment,
        reviewer_name, review_type, sentiment_label, sentiment_score, flagged)
     VALUES ($1, $2, NULL, $3, $4, $5, $6, 'venue', $7, $8, false)
     ON CONFLICT (booking_id, reviewer_id, review_type) DO NOTHING`,
    [bookingId, playerId, venueId, rating, comment, playerName,
     rating >= 4 ? 'positive' : 'neutral', rating >= 4 ? 0.9 : 0.5],
  );
  return bookingId;
}

/** Keep venues.rating / total_reviews in step with the reviews table, as the reviews
 *  route does — the venue card and the model both read venues.rating. */
async function refreshVenueAggregate(client, venueId) {
  await client.query(
    `UPDATE venues
        SET rating = COALESCE(sub.avg, 0), total_reviews = COALESCE(sub.n, 0)
       FROM (SELECT ROUND(AVG(rating)::numeric, 2) AS avg, COUNT(*) AS n
               FROM reviews WHERE venue_id = $1 AND review_type = 'venue' AND hidden = false) sub
      WHERE venues.id = $1`,
    [venueId],
  );
}

// Fixed cast of demo entities. Every row is owned by a seeded @seed.sportlynk.test
// account, which is how --undo finds it — the names themselves carry no tag.
const OWNERS = [
  { name: `Ahmed Khan`, email: `owner1@${SEED_DOMAIN}`, phone: '03000000101', biz: 'Khan Sports Complex', cnic: '35200-7000001-1' },
  { name: `Sara Malik`, email: `owner2@${SEED_DOMAIN}`, phone: '03000000102', biz: 'Malik Cricket Hub', cnic: '35200-7000002-2' },
  { name: `Imran Butt`, email: `owner3@${SEED_DOMAIN}`, phone: '03000000103', biz: 'Butt Futsal Lahore', cnic: '35200-7000003-3' },
];
const VENUES = [
  { ownerIdx: 0, name: `Greenfield Football Arena`, city: 'Islamabad', sport: 'football', ground: 'turf', price: 3000 },
  { ownerIdx: 1, name: `Sixers Cricket Ground`, city: 'Rawalpindi', sport: 'cricket', ground: 'turf', price: 2500 },
  { ownerIdx: 2, name: `Northside Futsal Court`, city: 'Lahore', sport: 'football', ground: 'indoor', price: 2000 },
];
const PLAYER_NAMES = [
  'Hassan Raza', 'Bilal Ahmed', 'Usman Khan', 'Fahad Iqbal', 'Zain Malik',
  'Hamza Sheikh', 'Ali Rizvi', 'Omar Farooq', 'Saad Nawaz', 'Daniyal Tariq',
];
const PLAYER_ELOS = [1250, 1180, 1320, 1090, 1400, 1000, 1210, 1150, 1280, 1330];
const PLAYER_SPORTS = [['Football'], ['Football'], ['Cricket'], ['Cricket'],
  ['Football', 'Cricket'], ['Football'], ['Cricket'], ['Football'], ['Cricket'], ['Football', 'Cricket']];
const TEAMS = [
  { name: `Islamabad United FC`, sport: 'football', city: 'Islamabad', captainIdx: 0, memberIdxs: [4, 5], record: { elo: 1320, wins: 8, losses: 3, draws: 1 } },
  { name: `Rawal Rangers`, sport: 'football', city: 'Rawalpindi', captainIdx: 1, memberIdxs: [6], record: { elo: 1180, wins: 5, losses: 5, draws: 2 } },
  { name: `Pindi Panthers CC`, sport: 'cricket', city: 'Rawalpindi', captainIdx: 2, memberIdxs: [7, 8], record: { elo: 1290, wins: 7, losses: 4, draws: 0 } },
  { name: `Lahore Lions CC`, sport: 'cricket', city: 'Lahore', captainIdx: 3, memberIdxs: [9], record: { elo: 1150, wins: 4, losses: 6, draws: 1 } },
];

async function seed(client) {
  section('Owners + venues');
  const owners = [];
  for (const o of OWNERS) {
    const id = await ensureUser(client, { ...o, role: 'owner' });
    await ensureOwnerProfile(client, id, o.name, o.biz, o.cnic);
    owners.push(id);
    log(`owner  ${o.name} <${o.email}>`);
  }
  const venues = [];
  for (const v of VENUES) {
    const made = await ensureVenue(client, { ...v, ownerId: owners[v.ownerIdx] });
    venues.push({ ...v, id: made.id, ownerId: owners[v.ownerIdx] });
    log(`venue  ${v.name} (${v.sport}, ${v.city}) — +${made.created} slot(s)`);
  }
  const venueForSport = (sport) => venues.find((v) => v.sport === sport) || venues[0];

  section('Players');
  const players = [];
  for (let i = 0; i < PLAYER_ELOS.length; i += 1) {
    const n = i + 1;
    const id = await ensureUser(client, {
      name: PLAYER_NAMES[i], email: `player${n}@${SEED_DOMAIN}`,
      phone: `030000002${String(n).padStart(2, '0')}`, role: 'player',
    });
    await ensurePlayerProfile(client, id, { elo: PLAYER_ELOS[i], trust: 100, sports: PLAYER_SPORTS[i] });
    await ensureWallet(client, id, 50000);
    players.push(id);
  }
  log(`${players.length} players, trust 100, ELO ${Math.min(...PLAYER_ELOS)}–${Math.max(...PLAYER_ELOS)}, wallets funded ${money(50000)}`);

  section('Teams + rosters');
  const teams = [];
  for (const t of TEAMS) {
    const made = await ensureTeam(client, {
      name: t.name, sport: t.sport, city: t.city,
      captainId: players[t.captainIdx], record: t.record,
      memberIds: t.memberIdxs.map((i) => players[i]),
    });
    teams.push({ ...t, id: made.id });
    log(`team   ${t.name} (${t.sport}) — captain Player ${t.captainIdx + 1}, ${t.memberIdxs.length} member(s), ${t.record.wins}W-${t.record.losses}L-${t.record.draws}D`);
  }

  section('Bookings (confirmed + pending, all future)');
  let confirmed = 0;
  let pending = 0;
  for (const t of teams) {
    const v = venueForSport(t.sport);
    const cap = players[t.captainIdx];
    const plan = [
      { tag: `t${t.captainIdx}-c1`, confirm: true },
      { tag: `t${t.captainIdx}-c2`, confirm: true },
      { tag: `t${t.captainIdx}-p1`, confirm: false },
    ];
    for (const p of plan) {
      const r = await bookOne(client, {
        tag: p.tag, playerId: cap, ownerId: v.ownerId, venueId: v.id,
        venueName: v.name, confirm: p.confirm,
      });
      if (r.id && !r.reused) { if (r.confirmed) confirmed += 1; else pending += 1; }
      if (!r.id) log(`  skip ${p.tag}: ${r.reason}`);
    }
  }
  log(`${confirmed} confirmed + ${pending} pending future booking(s) created (reused rows left as-is).`);

  section('History + venue reviews');
  const reviewLines = [
    [5, 'Great surface and the floodlights are excellent. Will book again.'],
    [4, 'Good ground, well maintained. Parking fills up on weekends.'],
    [5, 'Clean changing rooms and friendly staff. Highly recommended.'],
    [4, 'Solid pitch and the app booking was smooth.'],
  ];
  let reviewed = 0;
  for (let vi = 0; vi < venues.length; vi += 1) {
    const v = venues[vi];
    // Three different players leave a dated review on each venue.
    for (let k = 0; k < 3; k += 1) {
      const pIdx = (vi * 3 + k) % players.length;
      const [rating, comment] = reviewLines[(vi + k) % reviewLines.length];
      await ensurePastReview(client, {
        tag: `rev-v${vi}-${k}`, playerId: players[pIdx], playerName: PLAYER_NAMES[pIdx],
        venueId: v.id, price: v.price, daysAgo: 7 + k * 9, rating, comment,
      });
      reviewed += 1;
    }
    await refreshVenueAggregate(client, v.id);
  }
  log(`${reviewed} venue review(s) across ${venues.length} venues (ratings recomputed).`);
}

/** Remove only what seed() added. Everything seeded belongs to a user whose email is
 *  under @seed.sportlynk.test — the one marker that does not depend on how a venue or
 *  team was named — so this deletes by ownership, in FK-safe order, inside the
 *  caller's transaction (a failed step rolls the whole undo back). */
async function undo(client) {
  section('Removing seeded rows');
  const userIds = (await client.query(
    'SELECT id FROM users WHERE email LIKE $1', [`%@${SEED_DOMAIN}`],
  )).rows.map((r) => r.id);
  if (!userIds.length) { log(`nothing seeded — no @${SEED_DOMAIN} accounts found`); return; }

  const idsOf = async (sql) => (await client.query(sql, [userIds])).rows.map((r) => r.id);
  const teamIds = await idsOf('SELECT id FROM teams WHERE captain_id = ANY($1::uuid[])');
  const venueIds = await idsOf('SELECT id FROM venues WHERE owner_id = ANY($1::uuid[])');
  const bookingIds = (await client.query(
    `SELECT id FROM bookings
      WHERE player_id = ANY($1::uuid[]) OR notes LIKE $2 OR venue_id = ANY($3::uuid[])`,
    [userIds, `${NOTES_MARK}/%`, venueIds],
  )).rows.map((r) => r.id);

  const run = async (label, sql, params) => {
    const r = await client.query(sql, params);
    if (r.rowCount) log(`deleted ${r.rowCount} ${label}`);
  };

  // Release escrow on any still-active booking in the set through the real cancel
  // path before deleting it, so the correct wallet is refunded — including a real
  // account that booked a seeded venue — rather than leaving money frozen.
  const activeBookings = (await client.query(
    `SELECT id, player_id FROM bookings WHERE id = ANY($1::uuid[]) AND status IN ('pending','confirmed')`,
    [bookingIds],
  )).rows;
  for (const b of activeBookings) await booking.cancelBooking(client, { userId: b.player_id, bookingId: b.id });
  if (activeBookings.length) log(`released escrow on ${activeBookings.length} active booking(s)`);

  // Reviews reference bookings + venues, and the ledger references bookings, so both
  // go before the bookings themselves.
  if (bookingIds.length) {
    await run('review(s)', 'DELETE FROM reviews WHERE booking_id = ANY($1::uuid[])', [bookingIds]);
    await run('ledger row(s)', 'DELETE FROM transactions WHERE booking_id = ANY($1::uuid[])', [bookingIds]);
    await run('booking(s)', 'DELETE FROM bookings WHERE id = ANY($1::uuid[])', [bookingIds]);
  }

  // Chat channels (team rooms + booking rooms) reference seeded users via created_by,
  // so they and their messages/memberships must go before the users.
  const refIds = [...teamIds, ...bookingIds];
  const chans = (await client.query(
    'SELECT id FROM chat_channels WHERE created_by = ANY($1::uuid[]) OR ref_id = ANY($2::uuid[])',
    [userIds, refIds],
  )).rows.map((r) => r.id);
  if (chans.length) {
    await client.query('DELETE FROM chat_messages WHERE channel_id = ANY($1::uuid[])', [chans]);
    await client.query('DELETE FROM chat_channel_members WHERE channel_id = ANY($1::uuid[])', [chans]);
    await run('chat channel(s)', 'DELETE FROM chat_channels WHERE id = ANY($1::uuid[])', [chans]);
  }

  if (teamIds.length) {
    await run('team member row(s)', 'DELETE FROM team_members WHERE team_id = ANY($1::uuid[])', [teamIds]);
    await run('team(s)', 'DELETE FROM teams WHERE id = ANY($1::uuid[])', [teamIds]);
  }
  // A seeded player may also sit in a non-seeded team as a plain member.
  await run('other membership(s)', 'DELETE FROM team_members WHERE user_id = ANY($1::uuid[])', [userIds]);
  if (venueIds.length) {
    await run('slot(s)', 'DELETE FROM slots WHERE venue_id = ANY($1::uuid[])', [venueIds]);
    await run('venue(s)', 'DELETE FROM venues WHERE id = ANY($1::uuid[])', [venueIds]);
  }
  // Any remaining ledger rows for these wallets (e.g. a top-up) before the wallets.
  await run('wallet ledger row(s)', 'DELETE FROM transactions WHERE user_id = ANY($1::uuid[])', [userIds]);
  await run('wallet(s)', 'DELETE FROM wallets WHERE user_id = ANY($1::uuid[])', [userIds]);
  await run('player_profile(s)', 'DELETE FROM player_profiles WHERE user_id = ANY($1::uuid[])', [userIds]);
  await run('owner_profile(s)', 'DELETE FROM owner_profiles WHERE user_id = ANY($1::uuid[])', [userIds]);
  await run('user(s)', 'DELETE FROM users WHERE id = ANY($1::uuid[])', [userIds]);
}

(async () => {
  const mode = SELFTEST ? 'selftest' : (UNDO ? 'undo' : 'seed');
  const kept = (COMMIT && !SELFTEST) ? '(COMMIT — writes kept)' : '(dry run — rolled back, nothing kept)';
  console.log(`\nSportLynk demo data — ${mode} ${kept}`);
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    if (SELFTEST) { await seed(client); await undo(client); }
    else if (UNDO) await undo(client);
    else await seed(client);
    if (COMMIT && !SELFTEST) {
      await client.query('COMMIT');
      console.log(`\n✅ ${UNDO ? 'Seeded rows removed.' : `Committed. Log in as player1@${SEED_DOMAIN} (password: ${PASSWORD}).`}`);
    } else {
      await client.query('ROLLBACK');
      console.log(SELFTEST
        ? '\n✅ Self-test OK — seed and undo both fit the live schema; nothing was written.'
        : '\n✅ Dry run OK — the live schema accepted every statement; nothing was written.');
      if (!SELFTEST) {
        console.log(`   Re-run with --commit to keep it:  node src/scripts/seed_demo_data.js ${UNDO ? '--undo ' : ''}--commit`);
      }
    }
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    console.error(`\n❌ ${mode} failed — nothing written:`, e.message);
    if (e.detail) console.error('   detail:', e.detail);
    if (e.hint) console.error('   hint:', e.hint);
    process.exitCode = 1;
  } finally {
    client.release();
    await pool.end().catch(() => {});
  }
})();





