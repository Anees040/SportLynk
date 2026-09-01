/**
 * S.4 Wave D — reviews & trust demo seed.
 *
 * The reviews backend (Wave C) shipped with zero reviews in the database, so
 * every Wave D screen — venue reviews, the trust profile, the moderation queue —
 * renders empty until someone writes one. This script fills those screens with a
 * small, clearly-labelled, idempotent fixture so the app looks alive on first
 * launch and the demo has content to act on. It is not a substitute for the live
 * end-to-end test; the live sentiment chip, the abusive→queue path and the
 * two-captains-review-each-other trust bump are all still exercised by hand.
 *
 * What it leaves behind
 *   • Two demo teams — "Demo United" (captain = 1st player) and "Demo Rovers"
 *     (captain = 2nd player) — with a member, elo and W/L/D so the Team
 *     Reputation strip has something to show.
 *   • A handful of checked-in venue bookings and one venue review each, spanning
 *     positive / neutral / negative sentiment, including one abusive review that
 *     is flagged and carries a manual report — so the admin moderation queue is
 *     not empty.
 *   • Opponent (captain-to-captain) reviews received by both demo captains, so
 *     each captain's Trust Profile shows a populated gauge, four live breakdown
 *     tiles and a reviews ledger.
 *   • one completed match between the two demo teams, deliberately left
 *     unreviewed, so the demo can log in as a captain and file the opponent review
 *     live (the "trust updates within seconds" moment) without hitting the
 *     one-review-per-booking guard.
 *
 * Why it writes reviews directly (not through POST /api/reviews)
 *   Seeded reviews carry pre-set sentiment labels/scores so the histogram and the
 *   sentiment summary have data with no ml-service round-trip, and so a re-run is
 *   deterministic. The database's own guards still apply — the one-per-author
 *   unique index, the rating CHECK, every FK — so a bad fixture fails loudly here
 *   exactly as a bad request would at the route. Trust is then recomputed with the
 *   real utils/trustScore.recomputeTrust, so the stored breakdown is genuine.
 *
 * Idempotent. Teams are keyed by name, bookings by a stable notes marker, reviews
 * by the (booking, author, type) unique index (ON CONFLICT DO NOTHING). Running it
 * twice changes nothing the first run did.
 *
 * USAGE
 *   node seed_reviews_demo.js          seed (safe to re-run)
 *   node seed_reviews_demo.js --undo   remove exactly what this script created
 *
 * Needs one active venue and at least two player accounts already in the database
 * (register them in the app first). It never creates users or venues.
 */

require('dotenv').config();
const pool = require('./src/db/pool');
const { recomputeTrust } = require('./src/utils/trustScore');

// Stable markers so a re-run finds its own rows and never duplicates them.
const BOOKING_MARK = 'SEED_REVIEWS_DEMO';       // bookings.notes prefix
const TEAM_A_NAME = 'Demo United';
const TEAM_B_NAME = 'Demo Rovers';

const arg = process.argv[2];

// Tiny console helpers
const log = (m) => console.log(`   ${m}`);
const section = (t) => console.log(`\n── ${t} ${'─'.repeat(Math.max(0, 58 - t.length))}`);

// Idempotent builders

/** A demo team captained by `userId`. Keyed by name; stats reset on every run so
 *  the Team Reputation strip is stable rather than drifting with re-runs. */
async function ensureTeam(client, name, sport, userId, stats) {
  const found = await client.query('SELECT id FROM teams WHERE name = $1', [name]);
  let teamId = found.rows[0]?.id;
  if (!teamId) {
    const ins = await client.query(
      `INSERT INTO teams (name, sport, visibility, city, captain_id, elo, wins, losses, draws)
       VALUES ($1, $2, 'public', 'Islamabad', $3, $4, $5, $6, $7) RETURNING id`,
      [name, sport, userId, stats.elo, stats.wins, stats.losses, stats.draws],
    );
    teamId = ins.rows[0].id;
  } else {
    await client.query(
      `UPDATE teams SET captain_id = $2, elo = $3, wins = $4, losses = $5, draws = $6
        WHERE id = $1`,
      [teamId, userId, stats.elo, stats.wins, stats.losses, stats.draws],
    );
  }
  await client.query(
    `INSERT INTO team_members (team_id, user_id, role)
     VALUES ($1, $2, 'captain')
     ON CONFLICT (team_id, user_id) DO UPDATE SET role = 'captain'`,
    [teamId, userId],
  );
  return teamId;
}

async function addMember(client, teamId, userId) {
  if (!userId) return;
  await client.query(
    `INSERT INTO team_members (team_id, user_id, role)
     VALUES ($1, $2, 'member')
     ON CONFLICT (team_id, user_id) DO UPDATE SET role = 'member'`,
    [teamId, userId],
  );
}

/** A booking `hoursAgo` in the past, tagged so a re-run reuses it. `checked_in`
 *  sets checked_in_at (an attended slot); `no_show` leaves it null. */
async function ensureBooking(client, { tag, playerId, venueId, price, status, hoursAgo }) {
  const notes = `${BOOKING_MARK}/${tag}`;
  const found = await client.query('SELECT id FROM bookings WHERE notes = $1', [notes]);
  if (found.rows.length) return found.rows[0].id;

  const deposit = Math.round(price * 0.2 * 100) / 100;
  const { rows } = await client.query(
    `INSERT INTO bookings
       (player_id, venue_id, slot_date, start_time, end_time,
        base_price, security_deposit, total_amount, status, notes, checked_in_at)
     SELECT $1, $2,
            (d)::date, (d)::time, ((d) + interval '1 hour')::time,
            $3, $4, $3, $5::booking_status, $6,
            CASE WHEN $5 = 'checked_in' THEN now() ELSE NULL END
       FROM (SELECT date_trunc('hour',
               (NOW() AT TIME ZONE 'Asia/Karachi') - ($7 || ' hours')::interval) AS d) s
     RETURNING id`,
    [playerId, venueId, price, deposit, status, notes, String(hoursAgo)],
  );
  return rows[0].id;
}

/** One completed match on `bookingId`, teamA beat teamB 3–1. One per booking
 *  (ux_matches_booking_live), so skip if a match already sits on this slot. */
async function ensureCompletedMatch(client, { bookingId, sport, teamA, teamB, verifiedBy }) {
  const found = await client.query('SELECT id FROM matches WHERE booking_id = $1', [bookingId]);
  if (found.rows.length) return found.rows[0].id;

  const { rows } = await client.query(
    `INSERT INTO matches
       (challenger_team, opponent_team, booking_id, sport, status,
        winner_team, score_challenger, score_opponent,
        elo_applied, results_locked, verified_by, verified_at, responded_at)
     VALUES ($1, $2, $3, $4, 'completed', $1, 3, 1, true, true, $5, now(), now())
     RETURNING id`,
    [teamA, teamB, bookingId, sport, verifiedBy],
  );
  return rows[0].id;
}

/** Insert one review, pre-scored. Idempotent on (booking, author, type). Returns
 *  the review id, or the existing row's id on a re-run. */
async function ensureReview(client, r) {
  const ins = await client.query(
    `INSERT INTO reviews
       (booking_id, reviewer_id, reviewed_user_id, venue_id, rating, comment,
        reviewer_name, review_type, sentiment_label, sentiment_score, flagged)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
     ON CONFLICT (booking_id, reviewer_id, review_type) DO NOTHING
     RETURNING id`,
    [r.bookingId, r.reviewerId, r.reviewedUserId, r.venueId, r.stars, r.text,
      r.reviewerName, r.reviewType, r.sentimentLabel, r.sentimentScore, r.flagged || false],
  );
  if (ins.rows.length) return ins.rows[0].id;
  const existing = await client.query(
    `SELECT id FROM reviews WHERE booking_id = $1 AND reviewer_id = $2 AND review_type = $3`,
    [r.bookingId, r.reviewerId, r.reviewType],
  );
  return existing.rows[0]?.id || null;
}

/** Recompute the denormalised venue rating/total the listings read. Mirrors
 *  routes/reviews.js so the seeded average matches what the app would compute. */
async function refreshVenueAggregate(client, venueId) {
  await client.query(
    `UPDATE venues
        SET rating = COALESCE(sub.avg_rating, 0), total_reviews = COALESCE(sub.n, 0)
       FROM (SELECT ROUND(AVG(rating)::numeric, 2) AS avg_rating, COUNT(*) AS n
               FROM reviews
              WHERE venue_id = $1 AND review_type = 'venue' AND hidden = false) sub
      WHERE venues.id = $1`,
    [venueId],
  );
}

// Prerequisites

async function loadPrereqs(client) {
  const players = (await client.query(
    "SELECT id, name FROM users WHERE role = 'player' AND is_active = true ORDER BY created_at LIMIT 3",
  )).rows;
  const venue = (await client.query(
    `SELECT id, name, owner_id, sport_type, COALESCE(base_price, price_per_hour, 2000) AS price
       FROM venues WHERE is_active = true ORDER BY created_at LIMIT 1`,
  )).rows[0];
  return { players, venue };
}

// Seed

async function seed() {
  const client = await pool.connect();
  try {
    const { players, venue } = await loadPrereqs(client);
    if (players.length < 2 || !venue) {
      console.log('\n⚠️  Not enough data to seed.');
      if (!venue) console.log('   • No active venue found — approve a venue first.');
      if (players.length < 2) console.log(`   • Need ≥2 player accounts, found ${players.length} — register players in the app.`);
      console.log('   Nothing was written.\n');
      return { skipped: true };
    }

    const [capA, capB, member] = players;
    const sport = ['football', 'cricket'].includes((venue.sport_type || '').toLowerCase())
      ? venue.sport_type.toLowerCase()
      : 'football';
    const price = Number(venue.price) || 2000;

    console.log('\nSportLynk — S.4 Wave D reviews & trust demo seed');
    log(`Venue:   ${venue.name}`);
    log(`Captain A: ${capA.name}   Captain B: ${capB.name}${member ? `   Member: ${member.name}` : ''}`);

    await client.query('BEGIN');

    // Teams
    section('Teams');
    const teamA = await ensureTeam(client, TEAM_A_NAME, sport, capA.id,
      { elo: 1185, wins: 8, losses: 3, draws: 2 });
    const teamB = await ensureTeam(client, TEAM_B_NAME, sport, capB.id,
      { elo: 1072, wins: 5, losses: 6, draws: 1 });
    await addMember(client, teamA, member?.id);
    log(`${TEAM_A_NAME} (elo 1185) vs ${TEAM_B_NAME} (elo 1072) — captains wired.`);

    // Venue reviews (varied sentiment, one abusive→flagged)
    section('Venue reviews');
    const venueReviewData = [
      { by: capA, stars: 5, text: 'Great turf, floodlights were perfect and the staff were super helpful. Highly recommended!', label: 'positive', score: 0.94 },
      { by: capB, stars: 5, text: 'Bohat acha ground hai, surface bhi smooth tha. Dobara zaroor ayenge!', label: 'positive', score: 0.88 },
      { by: member || capA, stars: 4, text: 'Good pitch overall, though the parking got a bit tight in the evening.', label: 'positive', score: 0.55 },
      { by: capA, stars: 3, text: 'It was okay. Nothing special but it does the job for a casual game.', label: 'neutral', score: 0.02 },
      { by: capB, stars: 1, text: 'Worst experience ever. The manager was rude and abusive, complete waste of money.', label: 'negative', score: -0.86, flagged: true, report: 'Abusive language — reported by a player.' },
    ];

    let vIdx = 0;
    let flaggedReviewId = null;
    for (const d of venueReviewData) {
      vIdx += 1;
      const bookingId = await ensureBooking(client, {
        tag: `venue${vIdx}`, playerId: d.by.id, venueId: venue.id, price,
        status: 'checked_in', hoursAgo: 24 * vIdx + 3,
      });
      const rid = await ensureReview(client, {
        bookingId, reviewerId: d.by.id, reviewedUserId: null, venueId: venue.id,
        stars: d.stars, text: d.text, reviewerName: d.by.name, reviewType: 'venue',
        sentimentLabel: d.label, sentimentScore: d.score, flagged: d.flagged,
      });
      if (d.report && rid) {
        flaggedReviewId = rid;
        await client.query(
          `INSERT INTO review_flags (review_id, flagged_by, reason)
           VALUES ($1, $2, $3) ON CONFLICT (review_id, flagged_by) DO NOTHING`,
          [rid, (member || capA).id, d.report],
        );
      }
    }
    await refreshVenueAggregate(client, venue.id);
    log(`${venueReviewData.length} venue reviews (1 abusive, flagged + reported). Venue rating refreshed.`);

    // Opponent (captain-to-captain) reviews → populate both trust profiles
    section('Opponent reviews (captain-to-captain)');
    // Received by captain B (from A). A separate booking each — one review per booking.
    const bReviews = [
      { stars: 5, text: 'Titan-level sportsmanship. Played clean, shook hands, great game.', label: 'positive', score: 0.90 },
      { stars: 4, text: 'Competitive match but all in good spirit. Respect.', label: 'positive', score: 0.58 },
      { stars: 2, text: 'Turned up 20 minutes late and argued nearly every call.', label: 'negative', score: -0.48 },
    ];
    let oIdx = 0;
    for (const d of bReviews) {
      oIdx += 1;
      const bookingId = await ensureBooking(client, {
        tag: `oppB${oIdx}`, playerId: capA.id, venueId: venue.id, price,
        status: 'checked_in', hoursAgo: 24 * oIdx + 200,
      });
      await ensureReview(client, {
        bookingId, reviewerId: capA.id, reviewedUserId: capB.id, venueId: null,
        stars: d.stars, text: d.text, reviewerName: capA.name, reviewType: 'opponent',
        sentimentLabel: d.label, sentimentScore: d.score,
      });
    }
    // Received by captain A (from B).
    const aReviews = [
      { stars: 5, text: 'Respectful opponents, well organised and on time. Would play again.', label: 'positive', score: 0.86 },
      { stars: 4, text: 'Good match, no issues at all.', label: 'positive', score: 0.50 },
    ];
    oIdx = 0;
    for (const d of aReviews) {
      oIdx += 1;
      const bookingId = await ensureBooking(client, {
        tag: `oppA${oIdx}`, playerId: capB.id, venueId: venue.id, price,
        status: 'checked_in', hoursAgo: 24 * oIdx + 400,
      });
      await ensureReview(client, {
        bookingId, reviewerId: capB.id, reviewedUserId: capA.id, venueId: null,
        stars: d.stars, text: d.text, reviewerName: capB.name, reviewType: 'opponent',
        sentimentLabel: d.label, sentimentScore: d.score,
      });
    }
    // One no-show for B so attendance is realistically < 100%.
    await ensureBooking(client, {
      tag: 'noShowB', playerId: capB.id, venueId: venue.id, price,
      status: 'no_show', hoursAgo: 600,
    });
    log(`${bReviews.length} reviews received by ${capB.name}, ${aReviews.length} by ${capA.name}, + 1 no-show.`);

    // One completed match, left unreviewed for the live demo
    section('Live-demo match');
    const liveBooking = await ensureBooking(client, {
      tag: 'liveMatch', playerId: capA.id, venueId: venue.id, price,
      status: 'checked_in', hoursAgo: 5,
    });
    const matchId = await ensureCompletedMatch(client, {
      bookingId: liveBooking, sport, teamA, teamB, verifiedBy: venue.owner_id,
    });
    log(`Completed match ${String(matchId).slice(0, 8)}… on booking ${String(liveBooking).slice(0, 8)}… — no opponent review yet.`);

    // Recompute trust from the real engine
    section('Trust recompute');
    for (const uid of [capA.id, capB.id, member?.id].filter(Boolean)) {
      const { trustScore } = await recomputeTrust(client, uid);
      const who = uid === capA.id ? capA.name : uid === capB.id ? capB.name : member.name;
      log(`${who}: trust_score = ${trustScore}`);
    }

    await client.query('COMMIT');

    console.log('\n✅ Seed complete. Demo it with:');
    log(`• Venue reviews  → open "${venue.name}" → Reviews`);
    log(`• Trust profile  → view ${capB.name}'s profile (populated gauge + 4 tiles + ledger)`);
    log(`• Moderation     → admin → Moderation (1 flagged review waiting)`);
    log(`• Live review    → log in as ${capA.name} (captain of ${TEAM_A_NAME}) → Match Center → History → Rate opponent`);
    console.log('');
    return { skipped: false, venue, capA, capB, flaggedReviewId };
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    throw e;
  } finally {
    client.release();
  }
}

// Undo — remove exactly what seed() created, in FK-safe order

async function undo() {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const { rows: bk } = await client.query(
      `SELECT id FROM bookings WHERE notes LIKE $1`, [`${BOOKING_MARK}/%`],
    );
    const bookingIds = bk.map((r) => r.id);

    if (bookingIds.length) {
      // review_flags cascade with reviews; delete reviews then matches then bookings.
      await client.query(
        `DELETE FROM review_flags WHERE review_id IN
           (SELECT id FROM reviews WHERE booking_id = ANY($1::uuid[]))`, [bookingIds]);
      await client.query(`DELETE FROM reviews  WHERE booking_id = ANY($1::uuid[])`, [bookingIds]);
      await client.query(`DELETE FROM matches  WHERE booking_id = ANY($1::uuid[])`, [bookingIds]);
      await client.query(`DELETE FROM bookings WHERE id = ANY($1::uuid[])`, [bookingIds]);
    }
    // Demo teams (team_members cascade on team delete).
    await client.query(`DELETE FROM teams WHERE name = ANY($1::text[])`, [[TEAM_A_NAME, TEAM_B_NAME]]);

    await client.query('COMMIT');
    console.log(`\n🧹 Undo complete — removed ${bookingIds.length} seed booking(s) with their reviews/matches, and the two demo teams.\n`);
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    throw e;
  } finally {
    client.release();
  }
}


(async () => {
  try {
    if (arg === '--undo') await undo();
    else await seed();
  } catch (e) {
    console.error('\n❌ Seed failed:', e.message);
    if (e.detail) console.error('   detail:', e.detail);
    process.exitCode = 1;
  } finally {
    await pool.end().catch(() => {});
  }
})();
