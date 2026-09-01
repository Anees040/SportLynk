// Uses the app's own pool — do not build a second one here.
//
// This script used to create its own Pool from DB_USER/DB_HOST/DB_NAME, which
// defaulted to a local `postgres@localhost/sportlynk` with SSL off, and loaded
// .env from D:\sportlynk\.env (the Flutter root — the wrong directory). The net
// effect was that it could never reach Supabase, which is the only database this
// project has. Requiring ../db/pool gets DATABASE_URL, TLS and the error hints
// for free.
const pool = require("../db/pool");

// `--yes` (or SL_SEED_YES=1) skips the countdown, for scripted runs.
const SKIP_CONFIRM =
  process.argv.includes("--yes") || process.env.SL_SEED_YES === "1";

// Working Unsplash photo URLs (direct CDN format)
const DUMMY_VENUES = [
  {
    name: "F-11 Markaz Football Arena",
    sport: "football",
    city: "Islamabad",
    address: "F-11 Markaz, Islamabad",
    lat: 33.6844,
    lng: 73.0479,
    price: 2000,
    type: "turf",
    rating: 4.8,
    rev: 124,
    hours: [16, 23],
    amenities: { lights: true, parking: true, washroom: true, equipment: "Ball, Bibs" },
    photos: [
      "https://images.unsplash.com/photo-1459865264687-595d652de67e?auto=format&fit=crop&w=800",
      "https://images.unsplash.com/photo-1574629810360-7efbb1924043?auto=format&fit=crop&w=800",
      "https://images.unsplash.com/photo-1553778263-73a83bab9b0c?auto=format&fit=crop&w=800",
    ],
  },
  {
    name: "Jinnah Sports Complex",
    sport: "football",
    city: "Islamabad",
    address: "G-6, Islamabad",
    lat: 33.7185,
    lng: 73.0828,
    price: 2500,
    type: "indoor",
    rating: 4.5,
    rev: 89,
    hours: [8, 22],
    amenities: { lights: true, lockers: true, seating: true },
    photos: [
      "https://images.unsplash.com/photo-1571019614242-c5c5dee9f50b?auto=format&fit=crop&w=800",
      "https://images.unsplash.com/photo-1518604666860-9ed391f76460?auto=format&fit=crop&w=800",
      "https://images.unsplash.com/photo-1543326727-cf6c39e8f84c?auto=format&fit=crop&w=800",
    ],
  },
  {
    name: "Centaurus Kickoff",
    sport: "football",
    city: "Islamabad",
    address: "F-8, Islamabad",
    lat: 33.7081,
    lng: 73.0504,
    price: 3000,
    type: "turf",
    rating: 4.9,
    rev: 210,
    hours: [10, 23],
    amenities: { lights: true, cafe: true, parking: true },
    photos: [
      "https://images.unsplash.com/photo-1529900748604-07564a03e7a6?auto=format&fit=crop&w=800",
      "https://images.unsplash.com/photo-1459865264687-595d652de67e?auto=format&fit=crop&w=800",
      "https://images.unsplash.com/photo-1553778263-73a83bab9b0c?auto=format&fit=crop&w=800",
    ],
  },
  {
    name: "Bahria Town Futsal",
    sport: "football",
    city: "Rawalpindi",
    address: "Phase 4, Bahria Town",
    lat: 33.5516,
    lng: 73.1166,
    price: 1800,
    type: "turf",
    rating: 4.3,
    rev: 45,
    hours: [14, 22],
    amenities: { lights: true, parking: true },
    photos: [
      "https://images.unsplash.com/photo-1574629810360-7efbb1924043?auto=format&fit=crop&w=800",
      "https://images.unsplash.com/photo-1571019614242-c5c5dee9f50b?auto=format&fit=crop&w=800",
      "https://images.unsplash.com/photo-1518604666860-9ed391f76460?auto=format&fit=crop&w=800",
    ],
  },
  {
    name: "DHA Phase 2 Arena",
    sport: "football",
    city: "Islamabad",
    address: "DHA Phase 2, Islamabad",
    lat: 33.535,
    lng: 73.15,
    price: 2200,
    type: "indoor",
    rating: 4.6,
    rev: 110,
    hours: [12, 23],
    amenities: { lights: true, ac: true, washroom: true },
    photos: [
      "https://images.unsplash.com/photo-1543326727-cf6c39e8f84c?auto=format&fit=crop&w=800",
      "https://images.unsplash.com/photo-1529900748604-07564a03e7a6?auto=format&fit=crop&w=800",
      "https://images.unsplash.com/photo-1574629810360-7efbb1924043?auto=format&fit=crop&w=800",
    ],
  },
  {
    name: "Diamond Cricket Ground",
    sport: "cricket",
    city: "Islamabad",
    address: "Sector G-8/2, Islamabad",
    lat: 33.694,
    lng: 73.05,
    price: 3500,
    type: "turf",
    rating: 4.8,
    rev: 320,
    hours: [6, 18],
    amenities: { pavilion: true, pitch: "grass", parking: true },
    photos: [
      "https://images.unsplash.com/photo-1540747913346-19e32dc3e97e?auto=format&fit=crop&w=800",
      "https://images.unsplash.com/photo-1531415074968-036ba1b575da?auto=format&fit=crop&w=800",
      "https://images.unsplash.com/photo-1624526267942-ab0f0b580098?auto=format&fit=crop&w=800",
    ],
  },
  {
    name: "Shalimar Cricket Academy",
    sport: "cricket",
    city: "Islamabad",
    address: "F-7 Markaz, Islamabad",
    lat: 33.72,
    lng: 73.055,
    price: 2800,
    type: "indoor",
    rating: 4.4,
    rev: 78,
    hours: [9, 21],
    amenities: { lights: true, bowling_machine: true, nets: 4 },
    photos: [
      "https://images.unsplash.com/photo-1624526267942-ab0f0b580098?auto=format&fit=crop&w=800",
      "https://images.unsplash.com/photo-1540747913346-19e32dc3e97e?auto=format&fit=crop&w=800",
      "https://images.unsplash.com/photo-1531415074968-036ba1b575da?auto=format&fit=crop&w=800",
    ],
  },
  {
    name: "Rawalpindi Cricket Nets",
    sport: "cricket",
    city: "Rawalpindi",
    address: "Stadium Road, Rawalpindi",
    lat: 33.64,
    lng: 73.076,
    price: 1500,
    type: "indoor",
    rating: 4.6,
    rev: 145,
    hours: [10, 22],
    amenities: { lights: true, coaching: true },
    photos: [
      "https://images.unsplash.com/photo-1531415074968-036ba1b575da?auto=format&fit=crop&w=800",
      "https://images.unsplash.com/photo-1624526267942-ab0f0b580098?auto=format&fit=crop&w=800",
      "https://images.unsplash.com/photo-1540747913346-19e32dc3e97e?auto=format&fit=crop&w=800",
    ],
  },
  {
    name: "Bahria Cricket Arena",
    sport: "cricket",
    city: "Rawalpindi",
    address: "Phase 7, Bahria Town",
    lat: 33.53,
    lng: 73.12,
    price: 2200,
    type: "turf",
    rating: 4.5,
    rev: 89,
    hours: [7, 19],
    amenities: { parking: true, seating: true },
    photos: [
      "https://images.unsplash.com/photo-1624526267942-ab0f0b580098?auto=format&fit=crop&w=800",
      "https://images.unsplash.com/photo-1531415074968-036ba1b575da?auto=format&fit=crop&w=800",
      "https://images.unsplash.com/photo-1540747913346-19e32dc3e97e?auto=format&fit=crop&w=800",
    ],
  },
  {
    name: "Margalla Cricket Club",
    sport: "cricket",
    city: "Islamabad",
    address: "F-9 Park, Islamabad",
    lat: 33.705,
    lng: 73.015,
    price: 4000,
    type: "turf",
    rating: 4.9,
    rev: 410,
    hours: [6, 20],
    amenities: { lights: true, pavilion: true, parking: true, washroom: true },
    photos: [
      "https://images.unsplash.com/photo-1540747913346-19e32dc3e97e?auto=format&fit=crop&w=800",
      "https://images.unsplash.com/photo-1624526267942-ab0f0b580098?auto=format&fit=crop&w=800",
      "https://images.unsplash.com/photo-1531415074968-036ba1b575da?auto=format&fit=crop&w=800",
    ],
  },
];

async function seed() {
  const client = await pool.connect();
  try {
    console.log("Connecting to DB...");

    // Find owner — use first owner found (preserves all users)
    const ownerRes = await client.query(
      "SELECT id FROM users WHERE role='owner' LIMIT 1"
    );
    const ownerId = ownerRes.rows.length > 0 ? ownerRes.rows[0].id : null;

    if (!ownerId) {
      console.log("No owner found. Register an owner account first.");
      return;
    }

    console.log(`Using owner ID: ${ownerId}`);

    // Destructive pre-flight
    // The four DELETEs below wipe this owner's venues, slots, bookings and the
    // transaction rows attached to those bookings — i.e. real ledger history, on
    // the live database. Show exactly what is about to go, then give a human five
    // seconds to hit Ctrl-C. This is cheap insurance against pasting the command
    // out of the deploy guide on the wrong day.
    const counts = await client.query(
      `SELECT
         (SELECT COUNT(*) FROM venues WHERE owner_id = $1) AS venues,
         (SELECT COUNT(*) FROM slots  WHERE venue_id IN (SELECT id FROM venues WHERE owner_id = $1)) AS slots,
         (SELECT COUNT(*) FROM bookings WHERE venue_id IN (SELECT id FROM venues WHERE owner_id = $1)) AS bookings,
         (SELECT COUNT(*) FROM bookings WHERE venue_id IN (SELECT id FROM venues WHERE owner_id = $1)
            AND status IN ('confirmed','completed')) AS live_bookings,
         (SELECT COUNT(*) FROM transactions WHERE booking_id IN
            (SELECT id FROM bookings WHERE venue_id IN (SELECT id FROM venues WHERE owner_id = $1))) AS txns`,
      [ownerId]
    );
    const c = counts.rows[0];
    const total =
      Number(c.venues) + Number(c.slots) + Number(c.bookings) + Number(c.txns);

    if (total > 0) {
      console.log("");
      console.log("⚠️  THIS WILL DELETE, for that owner only:");
      console.log(`      ${c.venues} venue(s)`);
      console.log(`      ${c.slots} slot(s)`);
      console.log(`      ${c.bookings} booking(s)  — ${c.live_bookings} confirmed/completed`);
      console.log(`      ${c.txns} transaction row(s) (ledger history)`);
      console.log("    Users and wallets are NOT deleted. Any escrow those bookings");
      console.log("    were holding is RELEASED back to the players' spendable balance");
      console.log("    first, with a ledger row — so no frozen money is left stranded.");
      if (Number(c.live_bookings) > 0) {
        console.log("");
        console.log("    ⛔ Some of those bookings are confirmed/completed. Deleting them");
        console.log("       destroys the escrow trail your acceptance tests check.");
      }
      if (!SKIP_CONFIRM) {
        console.log("");
        for (let s = 5; s > 0; s--) {
          process.stdout.write(`\r    Starting in ${s}s — Ctrl-C to abort... `);
          await new Promise((r) => setTimeout(r, 1000));
        }
        console.log("\r    Starting.                              ");
      }
      console.log("");
    }

    // Unwind escrow before deleting the bookings that hold it
    // This is the fix for a real bug. The DELETEs below remove booking rows, but
    // the escrow those bookings were holding lives in wallets.frozen_balance — a
    // different table this script never touched. So every past run left frozen
    // money with nothing to account for it: by the time this was found, 11,100 PKR
    // was stranded across two wallets, unreachable by their owners, and
    // GET /api/wallet/frozen reported a permanent non-zero `delta`.
    //
    // Releasing it back to spendable balance first keeps the invariant
    // (frozen_balance == sum of security_deposit over pending/confirmed bookings)
    // true on both sides of the delete. security_deposit is the authority on what
    // is in escrow — see routes/bookings.js.
    //
    // A `refund` ledger row is written per player, because money moving into
    // spendable balance without a ledger entry is exactly the kind of silent gap
    // this whole script caused. The row is written before the transactions DELETE
    // below, so scope it to booking_id IS NULL work — these rows carry no
    // booking_id precisely so the delete cannot take them with it.
    const holders = await client.query(
      `SELECT b.player_id,
              w.id                      AS wallet_id,
              SUM(b.security_deposit)   AS escrow
         FROM bookings b
         JOIN wallets w ON w.user_id = b.player_id
        WHERE b.venue_id IN (SELECT id FROM venues WHERE owner_id = $1)
          AND b.status IN ('pending','confirmed')
        GROUP BY b.player_id, w.id
       HAVING SUM(b.security_deposit) > 0`,
      [ownerId]
    );

    if (holders.rows.length) {
      console.log(`Releasing escrow held by ${holders.rows.length} player(s) before deleting their bookings:`);
      for (const h of holders.rows) {
        const amount = Math.round(Number(h.escrow) * 100) / 100;
        const upd = await client.query(
          `UPDATE wallets
              SET balance        = GREATEST(balance + $1, 0),
                  frozen_balance = GREATEST(frozen_balance - $1, 0)
            WHERE id = $2
          RETURNING balance`,
          [amount, h.wallet_id]
        );
        await client.query(
          `INSERT INTO transactions
             (wallet_id, user_id, booking_id, type, amount, balance_after,
              description, counterparty_name)
           VALUES ($1, $2, NULL, 'refund', $3, $4, $5, 'SportLynk')`,
          [
            h.wallet_id,
            h.player_id,
            amount,
            upd.rows[0] ? upd.rows[0].balance : 0,
            `Escrow released — the venue and its bookings were removed by a data reseed.`,
          ]
        );
        console.log(`      released PKR ${amount.toFixed(2)} to player ${h.player_id}`);
      }
      console.log("");
    }

    // Only delete venues (and cascade slots/bookings) — not users or wallets
    await client.query("DELETE FROM transactions WHERE booking_id IN (SELECT id FROM bookings WHERE venue_id IN (SELECT id FROM venues WHERE owner_id = $1))", [ownerId]);
    await client.query("DELETE FROM bookings WHERE venue_id IN (SELECT id FROM venues WHERE owner_id = $1)", [ownerId]);
    await client.query("DELETE FROM slots WHERE venue_id IN (SELECT id FROM venues WHERE owner_id = $1)", [ownerId]);
    await client.query("DELETE FROM venues WHERE owner_id = $1", [ownerId]);

    console.log("Inserting venues with working photo URLs...");
    for (const v of DUMMY_VENUES) {
      const amenitiesJson = JSON.stringify(v.amenities);

      const res = await client.query(
        `INSERT INTO venues (
          owner_id, name, description, sport_type, city, address,
          latitude, longitude, base_price, current_price, price_per_hour,
          image_url, venue_photos, is_active,
          rating, total_reviews, ground_type, amenities
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, true, $14, $15, $16, $17)
        RETURNING id`,
        [
          ownerId,
          v.name,
          `Premium ${v.sport} facility in ${v.city}. High-quality ${v.type}.`,
          v.sport,
          v.city,
          v.address,
          v.lat,
          v.lng,
          v.price,
          v.price,
          v.price,
          v.photos[0],
          v.photos,
          v.rating,
          v.rev,
          v.type,
          amenitiesJson,
        ]
      );

      const venueId = res.rows[0].id;
      const startHr = v.hours[0];
      const endHr = v.hours[1];

      // Seed 15 days of slots (today + 14)
      for (let day = 0; day <= 14; day++) {
        for (let hour = startHr; hour < endHr; hour++) {
          const isPeak = hour >= 17 && hour <= 21;
          const slotPrice = isPeak ? Math.round(v.price * 1.2) : v.price;

          await client.query(
            `INSERT INTO slots (venue_id, slot_date, start_time, end_time, price, status)
             VALUES ($1, CURRENT_DATE + $2::integer, $3::time, $4::time, $5, 'available')
             ON CONFLICT DO NOTHING`,
            [
              venueId,
              day,
              `${hour.toString().padStart(2, "0")}:00:00`,
              `${(hour + 1).toString().padStart(2, "0")}:00:00`,
              slotPrice,
            ]
          );
        }
      }
      console.log(`  ✓ ${v.name} — ${15 * (endHr - startHr)} slots created`);
    }

    console.log("\n✅ Successfully seeded venues and slots with working photo URLs.");
    console.log("   Player/Owner accounts preserved.");
  } catch (e) {
    console.error("Seeding error:", e.message);
    process.exitCode = 1; // so a failed seed cannot look like a successful one
  } finally {
    client.release();
    pool.end();
  }
}

seed();
