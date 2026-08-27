/**
 * S.5 Wave C — venue-recommender demo seed.
 *
 * THE PROBLEM IT SOLVES
 * The milestone asks for a demo beat where "two different players open the app and
 * see different venue rails". That is a property of the DATA, not of the model: a
 * content recommender builds each player's profile out of the venues they booked,
 * so two players with no booking history — or with the same one — get the same rail
 * and the whole point is invisible. This writes two deliberately CONTRASTING booking
 * histories so the difference is visible on screen and explainable on a slide.
 *
 * WHAT IT LEAVES BEHIND
 *   • Player 1 → three bookings on one end of the catalogue (one sport, or the
 *     premium end when the catalogue is single-sport) + one 5-star review there.
 *   • Player 2 → three bookings on the OTHER end + one 5-star review there.
 *   • Bookings are dated 4 / 12 / 25 days ago via `created_at`, because the profile
 *     is recency-weighted (90-day half-life): the newest booking pulls the rail
 *     hardest, which is exactly the behaviour worth demonstrating.
 *   • Stated sport preferences, but ONLY for a player whose preferences are empty —
 *     it never overwrites a real choice, and says so when it declines.
 *
 * IT DOES NOT CREATE USERS OR VENUES. Register the players and approve the venues
 * first; this script only writes the history that makes them distinguishable.
 *
 * SEEDING IS NOT ENOUGH — THE MODEL MUST BE REBUILT
 * ml-service serves a FROZEN snapshot: the venue matrix is fitted once at load and
 * cached, so rows written here are invisible until the artifact is retrained and the
 * cache dropped. Full sequence:
 *
 *   1  node seed_reco_demo.js
 *   2  cd ../ml-service && .venv\Scripts\python.exe training\build_reco.py
 *   3  curl -X POST -H "X-API-Key: $ML_API_KEY" http://127.0.0.1:8000/reco/refresh
 *   4  node seed_reco_demo.js --verify      ← prints both rails side by side
 *
 * Skip step 2 or 3 and the rails will be identical, which looks like a broken model
 * and is really just a stale snapshot.
 *
 * WHY IT WRITES BOOKINGS DIRECTLY (not through POST /api/bookings)
 * The booking route runs escrow, wallet debits, slot locks and QR issuance — none of
 * which the recommender reads, and all of which would need unwinding on --undo. The
 * export the trainer pulls (`/api/internal/export/reco-data`) selects exactly four
 * things per player: booking venue, booking created_at, high reviews and stated
 * sports. Those are what this writes. Every database guard still applies.
 *
 * IDEMPOTENT. Bookings are keyed by a stable `notes` marker, reviews by the
 * (booking, author, type) unique index. Re-running changes nothing.
 *
 * USAGE
 *   node seed_reco_demo.js            seed (safe to re-run)
 *   node seed_reco_demo.js --verify   ask ml-service for both rails and diff them
 *   node seed_reco_demo.js --undo     remove exactly what this script created
 */

require('dotenv').config();
const pool = require('./src/db/pool');

// Stable marker so a re-run finds its own rows and never duplicates them.
const MARK = 'SEED_RECO_DEMO';
const BOOKINGS_PER_PLAYER = 3;
const DAYS_AGO = [4, 12, 25];        // newest first — recency weighting made visible
const TOP_N = 5;                     // rail depth compared by --verify

const arg = process.argv[2];

const log = (m) => console.log(`   ${m}`);
const section = (t) => console.log(`\n── ${t} ${'─'.repeat(Math.max(0, 58 - t.length))}`);
const asNum = (v) => (v === null || v === undefined ? 0 : Number(v));

// ─────────────────────────────────────────────────────────────────────────────
// Prerequisites
// ─────────────────────────────────────────────────────────────────────────────

async function loadPrereqs(client) {
  const players = (await client.query(
    `SELECT u.id, u.name, COALESCE(pp.sport_preferences, '{}') AS sports
       FROM users u LEFT JOIN player_profiles pp ON pp.user_id = u.id
      WHERE u.role = 'player' AND u.is_active = true
      ORDER BY u.created_at LIMIT 2`,
  )).rows;
  const venues = (await client.query(
    `SELECT id, name, city, LOWER(COALESCE(sport_type::text, '')) AS sport,
            LOWER(COALESCE(ground_type::text, '')) AS ground,
            COALESCE(price_per_hour, base_price, 2000) AS price, rating
       FROM venues WHERE is_active = true ORDER BY created_at`,
  )).rows;
  return { players, venues };
}

/**
 * Pick two venue groups that are as far apart as the catalogue allows.
 *
 * SPORT FIRST. The sport block is the single strongest axis in the feature space
 * (a one-hot that two different sports share nothing on), so if the catalogue has
 * two sports with enough venues each, contrast on that — the rails then differ for
 * a reason anyone in the room can restate: "he plays cricket, she plays football".
 *
 * Otherwise fall back to PRICE. A single-sport catalogue still separates cleanly on
 * price_bucket + rating + indoor/outdoor, just less dramatically, so the script says
 * which axis it used rather than pretending the demo is equally strong either way.
 */
function chooseGroups(venues) {
  const bySport = new Map();
  for (const v of venues) {
    if (!v.sport) continue;
    if (!bySport.has(v.sport)) bySport.set(v.sport, []);
    bySport.get(v.sport).push(v);
  }
  const viable = [...bySport.entries()]
    .filter(([, list]) => list.length >= BOOKINGS_PER_PLAYER)
    .sort((a, b) => b[1].length - a[1].length);
  if (viable.length >= 2) {
    return {
      axis: `sport (${viable[0][0]} vs ${viable[1][0]})`,
      groupA: viable[0][1].slice(0, BOOKINGS_PER_PLAYER),
      groupB: viable[1][1].slice(0, BOOKINGS_PER_PLAYER),
      sportA: viable[0][0],
      sportB: viable[1][0],
    };
  }
  const byPrice = [...venues].sort((a, b) => asNum(b.price) - asNum(a.price));
  const need = BOOKINGS_PER_PLAYER * 2;
  if (byPrice.length < need) return null;
  const groupA = byPrice.slice(0, BOOKINGS_PER_PLAYER);
  const groupB = byPrice.slice(-BOOKINGS_PER_PLAYER);
  return {
    axis: `price (Rs ${asNum(groupA[0].price)} end vs Rs ${asNum(groupB[groupB.length - 1].price)} end)`,
    groupA,
    groupB,
    sportA: groupA[0].sport || null,
    sportB: groupB[0].sport || null,
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Idempotent writers
// ─────────────────────────────────────────────────────────────────────────────

/**
 * One checked-in booking `daysAgo` in the past, tagged so a re-run reuses it.
 *
 * `created_at` is set explicitly, and that is the whole point: the export the
 * trainer reads sends created_at as the booking's timestamp, and the profile weights
 * each venue by `0.5 ** (age / 90 days)`. Left to DEFAULT NOW() every seeded booking
 * would weigh the same and the recency half of the design would be undemonstrable.
 * `status` is checked_in because the export counts only confirmed/checked_in rows.
 */
async function ensureBooking(client, { tag, playerId, venueId, price, daysAgo }) {
  const notes = `${MARK}/${tag}`;
  const found = await client.query('SELECT id FROM bookings WHERE notes = $1', [notes]);
  if (found.rows.length) return found.rows[0].id;

  const deposit = Math.round(asNum(price) * 0.2 * 100) / 100;
  const { rows } = await client.query(
    `INSERT INTO bookings
       (player_id, venue_id, slot_date, start_time, end_time,
        base_price, security_deposit, total_amount, status, notes,
        checked_in_at, created_at, updated_at)
     SELECT $1, $2, (d)::date, (d)::time, ((d) + interval '1 hour')::time,
            $3, $4, $3, 'checked_in'::booking_status, $5, d, d, d
       FROM (SELECT date_trunc('hour', NOW() - ($6 || ' days')::interval) AS d) s
     RETURNING id`,
    [playerId, venueId, asNum(price), deposit, notes, String(daysAgo)],
  );
  return rows[0].id;
}

/** One 5-star venue review, pre-scored so no ml-service round-trip is needed and a
 *  re-run is deterministic. Feeds the affinity block (ratings >= 4 are the schema's
 *  only stand-in for a favourites list). Idempotent on (booking, author, type). */
async function ensureReview(client, { bookingId, playerId, playerName, venueId, text }) {
  await client.query(
    `INSERT INTO reviews
       (booking_id, reviewer_id, reviewed_user_id, venue_id, rating, comment,
        reviewer_name, review_type, sentiment_label, sentiment_score, flagged)
     VALUES ($1, $2, NULL, $3, 5, $4, $5, 'venue', 'positive', 0.91, false)
     ON CONFLICT (booking_id, reviewer_id, review_type) DO NOTHING`,
    [bookingId, playerId, venueId, text, playerName],
  );
}

/** Keep venues.rating/total_reviews in step with the reviews table, exactly as
 *  routes/reviews.js does — the model reads venues.rating, so a stale aggregate
 *  would feed the rating block a number the app does not show. */
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

/**
 * Set stated sport preferences ONLY when the player has none.
 *
 * The stated block carries 0.3 of the profile blend, so a contrasting pair here
 * sharpens the demo — but these are a real person's settings, and --undo cannot
 * restore a value it overwrote. So an existing choice is left exactly as it is and
 * the script reports that it declined; the history block (0.5) still separates the
 * two players on its own.
 */
async function ensureStatedSport(client, player, sport) {
  const current = player.sports || [];
  if (!sport) return { changed: false, reason: 'catalogue has no sport_type to state' };
  if (current.length) return { changed: false, reason: `already set to [${current.join(', ')}] — left alone` };
  const upd = await client.query(
    `UPDATE player_profiles SET sport_preferences = $2::text[] WHERE user_id = $1`,
    [player.id, [sport]],
  );
  if (!upd.rowCount) return { changed: false, reason: 'no player_profiles row — create one in the app' };
  return { changed: true, reason: `set to [${sport}]` };
}

// ─────────────────────────────────────────────────────────────────────────────
// Seed
// ─────────────────────────────────────────────────────────────────────────────

async function seed() {
  const client = await pool.connect();
  try {
    const { players, venues } = await loadPrereqs(client);
    const groups = venues.length ? chooseGroups(venues) : null;
    if (players.length < 2 || !groups) {
      console.log('\n⚠️  Not enough data to seed.');
      if (players.length < 2) log(`• Need >=2 player accounts, found ${players.length} — register players in the app.`);
      if (!groups) log(`• Need >=${BOOKINGS_PER_PLAYER * 2} active venues (or 2 sports with >=${BOOKINGS_PER_PLAYER} each), found ${venues.length}.`);
      log('Nothing was written.\n');
      return;
    }

    const [p1, p2] = players;
    console.log('\nSportLynk — S.5 Wave C venue-recommender demo seed');
    log(`Contrast axis: ${groups.axis}`);
    log(`${p1.name} → ${groups.groupA.map((v) => v.name).join(', ')}`);
    log(`${p2.name} → ${groups.groupB.map((v) => v.name).join(', ')}`);

    await client.query('BEGIN');
    const touched = new Set();

    for (const [tag, player, group, sport] of [
      ['a', p1, groups.groupA, groups.sportA],
      ['b', p2, groups.groupB, groups.sportB],
    ]) {
      section(`${player.name} — ${BOOKINGS_PER_PLAYER} bookings + 1 review`);
      let first = null;
      for (let i = 0; i < group.length; i += 1) {
        const v = group[i];
        const bookingId = await ensureBooking(client, {
          tag: `${tag}${i + 1}`, playerId: player.id, venueId: v.id,
          price: v.price, daysAgo: DAYS_AGO[i] ?? 30 + i * 7,
        });
        if (i === 0) first = { bookingId, venue: v };
        touched.add(v.id);
        log(`${DAYS_AGO[i] ?? 30 + i * 7}d ago · ${v.name} · Rs ${asNum(v.price)}${v.ground ? ` · ${v.ground}` : ''}`);
      }
      if (first) {
        await ensureReview(client, {
          bookingId: first.bookingId, playerId: player.id, playerName: player.name,
          venueId: first.venue.id,
          text: `Booked here again — the surface and facilities are consistently good. My go-to ${first.venue.sport || 'ground'} venue.`,
        });
        log(`5-star review on ${first.venue.name} (feeds the affinity block).`);
      }
      const stated = await ensureStatedSport(client, player, sport);
      log(`Stated sports: ${stated.reason}`);
    }

    for (const venueId of touched) await refreshVenueAggregate(client, venueId);
    await client.query('COMMIT');
    printNextSteps(p1, p2);
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    throw e;
  } finally {
    client.release();
  }
}

function printNextSteps(p1, p2) {
  console.log('\n✅ Seed complete — but the rails will NOT differ yet. Retrain and refresh:');
  log('1  cd ../ml-service && .venv\\Scripts\\python.exe training\\build_reco.py');
  log('2  curl -X POST -H "X-API-Key: <ML_API_KEY>" http://127.0.0.1:8000/reco/refresh');
  log('3  node seed_reco_demo.js --verify');
  console.log('\n   Then in the app:');
  log(`• Log in as ${p1.name} → Home → "Recommended for you" rail`);
  log(`• Log in as ${p2.name} → the same rail, different order and different %`);
  log('• Register a BRAND-NEW account → the rail is titled "Popular nearby" with no %');
  console.log('');
}

// ─────────────────────────────────────────────────────────────────────────────
// Verify — ask ml-service for both rails and show that they differ
// ─────────────────────────────────────────────────────────────────────────────

/**
 * The checklist item is "two different demo users see different venue rankings", and
 * this is the evidence for it: the two rails printed side by side with the overlap
 * counted. It calls ml-service directly, on purpose — going through the Node route
 * would need a JWT per player and would mask whether a difference came from the model
 * or from Node's fallback. A stale snapshot shows up here as identical rails.
 */
async function verify() {
  const url = (process.env.ML_SERVICE_URL || '').trim().replace(/\/+$/, '');
  const key = (process.env.ML_API_KEY || '').trim();
  if (!url || !key) {
    console.log('\n⚠️  ML_SERVICE_URL / ML_API_KEY not set in backend/.env — cannot verify.\n');
    return;
  }
  const client = await pool.connect();
  let players;
  let names;
  try {
    const prereqs = await loadPrereqs(client);
    players = prereqs.players;
    // The payload carries venue_id, not venue names — ml-service has no database
    // handle and the export sends ids. Resolve them here so the rail is readable.
    names = new Map(prereqs.venues.map((v) => [String(v.id), v.name]));
  } finally {
    client.release();
  }
  if (players.length < 2) {
    console.log('\n⚠️  Need 2 player accounts to compare.\n');
    return;
  }

  const rails = [];
  for (const p of players) {
    let res;
    try {
      res = await fetch(`${url}/reco/venues`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-API-Key': key },
        body: JSON.stringify({ user_id: p.id, limit: TOP_N }),
        signal: AbortSignal.timeout(5000),
      });
    } catch (e) {
      console.log(`\n❌ ml-service unreachable at ${url} (${e.message}). Is it running?\n`);
      return;
    }
    const body = await res.json().catch(() => ({}));
    if (!res.ok) {
      const why = body?.detail?.message || body?.message || `HTTP ${res.status}`;
      console.log(`\n❌ /reco/venues failed for ${p.name}: ${why}`);
      if (res.status === 503) log('Train it:  .venv\\Scripts\\python.exe training\\build_reco.py');
      console.log('');
      return;
    }
    rails.push({ player: p, items: body.items || [], profile: body.profile, label: body.label });
  }

  section('Rails');
  for (const r of rails) {
    console.log(`\n   ${r.player.name}  (profile: ${r.profile}, rail titled "${r.label}")`);
    r.items.forEach((it, i) => log(
      `  ${i + 1}. ${String(it.match_pct).padStart(3)}%  ${names.get(String(it.venue_id)) || it.venue_id}`
      + `${it.reasons?.length ? `   — ${it.reasons.join(', ')}` : ''}`,
    ));
  }
  const [a, b] = rails.map((r) => r.items.map((it) => it.venue_id));
  const shared = a.filter((id) => b.includes(id)).length;
  const sameOrder = a.length === b.length && a.every((id, i) => id === b[i]);
  section('Verdict');
  log(`top-${TOP_N} venues in common: ${shared}/${Math.max(a.length, b.length)}`);
  if (sameOrder) {
    log('❌ IDENTICAL rails. Either the artifact predates the seed (retrain + POST /reco/refresh),');
    log('   or both players ended up on the cold-start branch (check profile above).');
  } else {
    log('✅ Different rankings for the two players — the demo beat holds.');
  }
  console.log('');
}

// ─────────────────────────────────────────────────────────────────────────────
// Undo — remove exactly what seed() created, in FK-safe order
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Reviews before bookings (the FK), then the venue aggregates are recomputed so the
 * ratings this script inflated go back to what the remaining reviews say.
 *
 * It does NOT restore sport preferences: ensureStatedSport only ever fills an empty
 * list, so there is no prior value to put back, and clearing what a player has since
 * chosen themselves would be worse than leaving a filled-in preference behind.
 */
async function undo() {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const { rows } = await client.query('SELECT id, venue_id FROM bookings WHERE notes LIKE $1', [`${MARK}/%`]);
    const ids = rows.map((r) => r.id);
    const venueIds = [...new Set(rows.map((r) => r.venue_id))];
    if (ids.length) {
      await client.query(
        `DELETE FROM review_flags WHERE review_id IN
           (SELECT id FROM reviews WHERE booking_id = ANY($1::uuid[]))`, [ids]);
      await client.query('DELETE FROM reviews  WHERE booking_id = ANY($1::uuid[])', [ids]);
      await client.query('DELETE FROM bookings WHERE id = ANY($1::uuid[])', [ids]);
      for (const venueId of venueIds) await refreshVenueAggregate(client, venueId);
    }
    await client.query('COMMIT');
    console.log(`\n🧹 Undo complete — removed ${ids.length} seed booking(s) with their reviews; `
      + `${venueIds.length} venue rating(s) recomputed.`);
    log('Retrain + POST /reco/refresh again to make ml-service forget them.\n');
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    throw e;
  } finally {
    client.release();
  }
}

// ─────────────────────────────────────────────────────────────────────────────

(async () => {
  try {
    if (arg === '--undo') await undo();
    else if (arg === '--verify') await verify();
    else await seed();
  } catch (e) {
    console.error('\n❌ seed_reco_demo failed:', e.message);
    if (e.detail) console.error('   detail:', e.detail);
    process.exitCode = 1;
  } finally {
    await pool.end().catch(() => {});
  }
})();
