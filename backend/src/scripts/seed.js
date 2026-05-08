const bcrypt = require('bcrypt');
const pool = require('../db/pool');

async function seed() {
  const client = await pool.connect();
  console.log('🚀 Starting Database Seed...');

  try {
    await client.query('BEGIN');

    // 1. Clear existing data
    console.log('🧹 Clearing existing data...');
    await client.query('DELETE FROM wallet_transactions');
    await client.query('DELETE FROM wallets');
    await client.query('DELETE FROM bookings');
    await client.query('DELETE FROM venue_slots');
    await client.query('DELETE FROM venues');
    await client.query('DELETE FROM owner_profiles');
    await client.query('DELETE FROM player_profiles');
    await client.query('DELETE FROM users');

    // 2. Hash password
    console.log('🔐 Hashing password (this may take a few seconds)...');
    const passwordHash = await bcrypt.hash('password123', 12);

    // 3. Insert Users
    console.log('👤 Inserting users...');
    const users = [
      { name: 'Ahmed Khan', email: 'ahmed@sportlynk.pk', role: 'owner', phone: '03001234567' },
      { name: 'Sara Malik', email: 'sara@sportlynk.pk', role: 'owner', phone: '03009876543' },
      { name: 'Bilal Raza', email: 'bilal@test.pk', role: 'player', phone: '03331122334' },
      { name: 'Hina Farooq', email: 'hina@test.pk', role: 'player', phone: '03451234567' },
      { name: 'Usman Ali', email: 'usman@test.pk', role: 'player', phone: '03211234567' },
    ];

    const userMap = {};
    for (const u of users) {
      const res = await client.query(
        'INSERT INTO users (name, email, password_hash, role, phone) VALUES ($1, $2, $3, $4, $5) RETURNING id, name',
        [u.name, u.email, passwordHash, u.role, u.phone]
      );
      userMap[u.name] = res.rows[0].id;
    }

    // 4. Insert Profiles
    console.log('📄 Inserting profiles...');
    // Owners
    await client.query(
      'INSERT INTO owner_profiles (user_id, business_name, cnic, is_verified) VALUES ($1, $2, $3, $4)',
      [userMap['Ahmed Khan'], 'Khan Sports Complex', '35202-1234567-1', true]
    );
    await client.query(
      'INSERT INTO owner_profiles (user_id, business_name, cnic, is_verified) VALUES ($1, $2, $3, $4)',
      [userMap['Sara Malik'], 'Malik Sports Hub', '35202-9876543-2', true]
    );
    // Players
    await client.query(
      "INSERT INTO player_profiles (user_id, sport_preferences, elo_rating, trust_score) VALUES ($1, $2, $3, $4)",
      [userMap['Bilal Raza'], ['Football', 'Cricket'], 1150, 95]
    );
    await client.query(
      "INSERT INTO player_profiles (user_id, sport_preferences, elo_rating, trust_score) VALUES ($1, $2, $3, $4)",
      [userMap['Hina Farooq'], ['Badminton'], 980, 88]
    );
    await client.query(
      "INSERT INTO player_profiles (user_id, sport_preferences, elo_rating, trust_score) VALUES ($1, $2, $3, $4)",
      [userMap['Usman Ali'], ['Football', 'Futsal'], 1220, 100]
    );

    // 5. Insert Wallets
    console.log('💰 Inserting wallets...');
    const wallets = [
      { name: 'Ahmed Khan', balance: 15000 },
      { name: 'Sara Malik', balance: 8500 },
      { name: 'Bilal Raza', balance: 3500 },
      { name: 'Hina Farooq', balance: 2000 },
      { name: 'Usman Ali', balance: 5000 },
    ];
    for (const w of wallets) {
      await client.query(
        'INSERT INTO wallets (user_id, balance, frozen_balance) VALUES ($1, $2, 0)',
        [userMap[w.name], w.balance]
      );
    }

    // 6. Insert Venues
    console.log('🏟️ Inserting venues...');
    const venues = [
      {
        owner: 'Ahmed Khan',
        name: 'PakSports Arena',
        sport_type: 'Football',
        city: 'Islamabad',
        address: 'F-10 Markaz, Islamabad',
        description: 'Premium 5-a-side football turf with floodlights and changing rooms. Fully equipped with international-quality artificial grass.',
        latitude: 33.6938,
        longitude: 73.0652,
        base_price: 1500,
        current_price: 1500,
      },
      {
        owner: 'Ahmed Khan',
        name: 'Capital Cricket Ground',
        sport_type: 'Cricket',
        city: 'Islamabad',
        address: 'G-9/4, Islamabad',
        description: 'Indoor cricket practice nets with bowling machine available. Suitable for batting and bowling sessions for all skill levels.',
        latitude: 33.6761,
        longitude: 73.0619,
        base_price: 2000,
        current_price: 2000,
      },
      {
        owner: 'Ahmed Khan',
        name: 'Islamabad Futsal Zone',
        sport_type: 'Futsal',
        city: 'Islamabad',
        address: 'Blue Area, Islamabad',
        description: 'Air-conditioned indoor futsal court with professional markings. Perfect for competitive matches and team training sessions.',
        latitude: 33.7294,
        longitude: 73.0931,
        base_price: 1200,
        current_price: 1800,
      },
      {
        owner: 'Sara Malik',
        name: 'Lahore Sports Arena',
        sport_type: 'Football',
        city: 'Lahore',
        address: 'DHA Phase 5, Lahore',
        description: 'Outdoor football ground with natural grass. Spacious facility with spectator seating for up to 200 people.',
        latitude: 31.4816,
        longitude: 74.4324,
        base_price: 2500,
        current_price: 2500,
      },
      {
        owner: 'Sara Malik',
        name: 'Karachi Badminton Club',
        sport_type: 'Badminton',
        city: 'Karachi',
        address: 'Clifton Block 8, Karachi',
        description: 'Three professional badminton courts with non-slip flooring and proper court lighting. Rackets available for rent.',
        latitude: 24.8133,
        longitude: 67.0299,
        base_price: 800,
        current_price: 800,
      },
    ];

    const venueMap = {};
    for (const v of venues) {
      const res = await client.query(
        `INSERT INTO venues (owner_id, name, description, sport_type, city, address, latitude, longitude, base_price, current_price)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) RETURNING id, name`,
        [userMap[v.owner], v.name, v.description, v.sport_type, v.city, v.address, v.latitude, v.longitude, v.base_price, v.current_price]
      );
      venueMap[v.name] = res.rows[0].id;
    }

    // 7. Insert Venue Slots
    console.log('🕒 Inserting venue slots...');

    const getFutureDate = (daysAhead) => {
      const d = new Date();
      d.setDate(d.getDate() + daysAhead);
      return d.toISOString().split('T')[0];
    };

    let totalSlots = 0;

    // PakSports Arena (venue 1) — 5 days
    const venue1Id = venueMap['PakSports Arena'];
    const times1 = ['06:00', '07:00', '08:00', '17:00', '18:00', '19:00', '20:00'];
    for (let i = 1; i <= 5; i++) {
      const date = getFutureDate(i);
      for (const t of times1) {
        const start = t;
        const end = (parseInt(t.split(':')[0]) + 1).toString().padStart(2, '0') + ':00';
        await client.query(
          'INSERT INTO venue_slots (venue_id, date, start_time, end_time, price, status) VALUES ($1, $2, $3, $4, $5, $6)',
          [venue1Id, date, start, end, 1500, 'available']
        );
        totalSlots++;
      }
    }

    // Capital Cricket Ground (venue 2) — 3 days
    const venue2Id = venueMap['Capital Cricket Ground'];
    const times2 = ['07:00', '08:00', '16:00', '17:00', '18:00'];
    for (let i = 1; i <= 3; i++) {
      const date = getFutureDate(i);
      for (const t of times2) {
        const start = t;
        const end = (parseInt(t.split(':')[0]) + 1).toString().padStart(2, '0') + ':00';
        await client.query(
          'INSERT INTO venue_slots (venue_id, date, start_time, end_time, price, status) VALUES ($1, $2, $3, $4, $5, $6)',
          [venue2Id, date, start, end, 2000, 'available']
        );
        totalSlots++;
      }
    }

    // Islamabad Futsal Zone (venue 3) — 5 days
    const venue3Id = venueMap['Islamabad Futsal Zone'];
    const times3 = ['09:00', '10:00', '16:00', '17:00', '19:00', '20:00'];
    for (let i = 1; i <= 5; i++) {
      const date = getFutureDate(i);
      for (const t of times3) {
        const start = t;
        const end = (parseInt(t.split(':')[0]) + 1).toString().padStart(2, '0') + ':00';
        await client.query(
          'INSERT INTO venue_slots (venue_id, date, start_time, end_time, price, status) VALUES ($1, $2, $3, $4, $5, $6)',
          [venue3Id, date, start, end, 1800, 'available']
        );
        totalSlots++;
      }
    }

    // Lahore Sports Arena (venue 4) — 3 days
    const venue4Id = venueMap['Lahore Sports Arena'];
    const times4 = ['06:00', '07:00', '17:00', '18:00', '19:00'];
    for (let i = 1; i <= 3; i++) {
      const date = getFutureDate(i);
      for (const t of times4) {
        const start = t;
        const end = (parseInt(t.split(':')[0]) + 1).toString().padStart(2, '0') + ':00';
        await client.query(
          'INSERT INTO venue_slots (venue_id, date, start_time, end_time, price, status) VALUES ($1, $2, $3, $4, $5, $6)',
          [venue4Id, date, start, end, 2500, 'available']
        );
        totalSlots++;
      }
    }

    // Karachi Badminton Club (venue 5) — 3 days
    const venue5Id = venueMap['Karachi Badminton Club'];
    const times5 = ['08:00', '09:00', '14:00', '15:00', '17:00'];
    for (let i = 1; i <= 3; i++) {
      const date = getFutureDate(i);
      for (const t of times5) {
        const start = t;
        const end = (parseInt(t.split(':')[0]) + 1).toString().padStart(2, '0') + ':00';
        await client.query(
          'INSERT INTO venue_slots (venue_id, date, start_time, end_time, price, status) VALUES ($1, $2, $3, $4, $5, $6)',
          [venue5Id, date, start, end, 800, 'available']
        );
        totalSlots++;
      }
    }

    await client.query('COMMIT');
    console.log('✅ SEED COMPLETE');

    // Summary Table
    console.log('\n--- SEED SUMMARY ---');
    console.table([
      { Entity: 'Users', Created: users.length },
      { Entity: 'Profiles', Created: users.length },
      { Entity: 'Wallets', Created: users.length },
      { Entity: 'Venues', Created: venues.length },
      { Entity: 'Venue Slots', Created: totalSlots },
    ]);

  } catch (err) {
    await client.query('ROLLBACK');
    console.error('❌ SEED FAILED:', err.message);
  } finally {
    client.release();
    process.exit();
  }
}

seed();
