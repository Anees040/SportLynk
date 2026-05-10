const { Pool } = require('pg');
const dotenv = require('dotenv');
const path = require('path');

dotenv.config({ path: path.join(__dirname, '../../../.env') });

const pool = new Pool({
  user: process.env.DB_USER || 'postgres',
  host: process.env.DB_HOST || 'localhost',
  database: process.env.DB_NAME || 'sportlynk',
  password: process.env.DB_PASSWORD || 'sportlynk123',
  port: process.env.DB_PORT || 5432,
});

const VIDEO_URL = 'https://www.w3schools.com/html/mov_bbb.mp4';

const DUMMY_VENUES = [
  { name: 'F-11 Markaz Football Arena', sport: 'football', city: 'Islamabad', address: 'F-11 Markaz', lat: 33.6844, lng: 73.0479, price: 2000, type: 'turf', rating: 4.8, rev: 124, 
    hours: [16, 23], amenities: { lights: true, parking: true, washroom: true, equipment: 'Ball, Bibs' },
    photos: ['https://images.unsplash.com/photo-1579952363873-27f3bade9f55?q=80&w=800&auto=format&fit=crop', 'https://images.unsplash.com/photo-1518605368461-1ee711689b66?q=80&w=800&auto=format&fit=crop'] },
  
  { name: 'Jinnah Sports Complex', sport: 'football', city: 'Islamabad', address: 'G-6, Islamabad', lat: 33.7185, lng: 73.0828, price: 2500, type: 'indoor', rating: 4.5, rev: 89, 
    hours: [8, 22], amenities: { lights: true, lockers: true, seating: true },
    photos: ['https://images.unsplash.com/photo-1551280857-2b9ebf1fa5fc?q=80&w=800&auto=format&fit=crop', 'https://images.unsplash.com/photo-1575361204481-48a2b10a08e0?q=80&w=800&auto=format&fit=crop'] },
    
  { name: 'Centaurus Kickoff', sport: 'football', city: 'Islamabad', address: 'F-8, Islamabad', lat: 33.7081, lng: 73.0504, price: 3000, type: 'turf', rating: 4.9, rev: 210, 
    hours: [10, 24], amenities: { lights: true, cafe: true, parking: true },
    photos: ['https://images.unsplash.com/photo-1459865264687-595d652de67e?q=80&w=800&auto=format&fit=crop', 'https://images.unsplash.com/photo-1511886929837-354d827aae26?q=80&w=800&auto=format&fit=crop'] },

  { name: 'Bahria Town Futsal', sport: 'football', city: 'Rawalpindi', address: 'Phase 4, Bahria', lat: 33.5516, lng: 73.1166, price: 1800, type: 'turf', rating: 4.3, rev: 45, 
    hours: [14, 22], amenities: { lights: true, parking: true },
    photos: ['https://images.unsplash.com/photo-1589487391730-58f20eb2c308?q=80&w=800&auto=format&fit=crop', 'https://images.unsplash.com/photo-1600250395361-9c6f2a339031?q=80&w=800&auto=format&fit=crop'] },

  { name: 'DHA Phase 2 Arena', sport: 'football', city: 'Islamabad', address: 'DHA Phase 2', lat: 33.5350, lng: 73.1500, price: 2200, type: 'indoor', rating: 4.6, rev: 110, 
    hours: [12, 23], amenities: { lights: true, ac: true, washroom: true },
    photos: ['https://images.unsplash.com/photo-1560272564-c83b66b1ad12?q=80&w=800&auto=format&fit=crop', 'https://images.unsplash.com/photo-1574629810360-7efbb1924043?q=80&w=800&auto=format&fit=crop'] },
  
  { name: 'Diamond Cricket Ground', sport: 'cricket', city: 'Islamabad', address: 'Sector G-8/2', lat: 33.6940, lng: 73.0500, price: 3500, type: 'turf', rating: 4.8, rev: 320, 
    hours: [6, 18], amenities: { pavilion: true, pitch: 'grass', parking: true },
    photos: ['https://images.unsplash.com/photo-1540747913346-19e32dc3e97e?q=80&w=800&auto=format&fit=crop', 'https://images.unsplash.com/photo-1531415074968-036ba1b575da?q=80&w=800&auto=format&fit=crop'] },

  { name: 'Shalimar Cricket Academy', sport: 'cricket', city: 'Islamabad', address: 'F-7 Markaz', lat: 33.7200, lng: 73.0550, price: 2800, type: 'indoor', rating: 4.4, rev: 78, 
    hours: [9, 21], amenities: { lights: true, bowling_machine: true, nets: 4 },
    photos: ['https://images.unsplash.com/photo-1624526267942-ab0f0b580098?q=80&w=800&auto=format&fit=crop', 'https://images.unsplash.com/photo-1516086701168-5f9037cba8cb?q=80&w=800&auto=format&fit=crop'] },

  { name: 'Rawalpindi Cricket Nets', sport: 'cricket', city: 'Rawalpindi', address: 'Stadium Road', lat: 33.6400, lng: 73.0760, price: 1500, type: 'indoor', rating: 4.6, rev: 145, 
    hours: [10, 22], amenities: { lights: true, coaching: true },
    photos: ['https://images.unsplash.com/photo-1587280501635-68a0e82cd5ff?q=80&w=800&auto=format&fit=crop', 'https://images.unsplash.com/photo-1593341646782-e0b495cff86d?q=80&w=800&auto=format&fit=crop'] },

  { name: 'Bahria Cricket Arena', sport: 'cricket', city: 'Rawalpindi', address: 'Phase 7, Bahria', lat: 33.5300, lng: 73.1200, price: 2200, type: 'turf', rating: 4.5, rev: 89, 
    hours: [7, 19], amenities: { parking: true, seating: true },
    photos: ['https://images.unsplash.com/photo-1518063319789-7217e6706b04?q=80&w=800&auto=format&fit=crop', 'https://images.unsplash.com/photo-1624526267865-c3fcc4074f63?q=80&w=800&auto=format&fit=crop'] },
    
  { name: 'Margalla Cricket Club', sport: 'cricket', city: 'Islamabad', address: 'F-9 Park', lat: 33.7050, lng: 73.0150, price: 4000, type: 'turf', rating: 4.9, rev: 410, 
    hours: [6, 20], amenities: { lights: true, pavilion: true, parking: true, washroom: true },
    photos: ['https://images.unsplash.com/photo-1599839619722-39751411ea63?q=80&w=800&auto=format&fit=crop', 'https://images.unsplash.com/photo-1605151515201-9c17be9ea01e?q=80&w=800&auto=format&fit=crop'] },
];

async function seed() {
  try {
    console.log('Connecting to DB...');
    await pool.query('DELETE FROM wallet_transactions');
    await pool.query('DELETE FROM transactions');
    await pool.query('DELETE FROM bookings');
    await pool.query('DELETE FROM venues'); // Cascades to slots
    
    // Find owner
    const ownerRes = await pool.query("SELECT id FROM users WHERE role='owner' LIMIT 1");
    const ownerId = ownerRes.rows.length > 0 ? ownerRes.rows[0].id : null;
    
    if (!ownerId) {
      console.log('No owner found. Run seed_users.js first.');
      return;
    }

    console.log('Inserting venues...');
    for (const v of DUMMY_VENUES) {
      const amenitiesJson = JSON.stringify(v.amenities);

      const res = await pool.query(`
        INSERT INTO venues (
          owner_id, name, description, sport_type, city, address, 
          latitude, longitude, base_price, current_price, price_per_hour,
          image_url, venue_photos, video_url, is_active, rating, total_reviews, ground_type, amenities
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19)
        RETURNING id
      `, [
        ownerId, v.name, `Premium ${v.sport} facility in ${v.city}. High-quality ${v.type}.`,
        v.sport, v.city, v.address, v.lat, v.lng, v.price, v.price, v.price,
        v.photos[0], v.photos, VIDEO_URL, true, v.rating, v.rev, v.type, amenitiesJson
      ]);

      const venueId = res.rows[0].id;
      
      const startHr = v.hours[0];
      const endHr = v.hours[1];
      
      // Seed 7 days
      for (let day = 0; day <= 7; day++) {
        for (let hour = startHr; hour < endHr; hour++) {
          const isPeak = hour >= 18 && hour <= 21;
          const slotPrice = isPeak ? v.price * 1.2 : v.price;
          
          // Random status but mostly available
          const rand = Math.random();
          let status = 'available';
          if (rand > 0.8) status = 'booked';
          else if (rand > 0.9) status = 'temporarily_locked';
          else if (rand > 0.95) status = 'blocked';
          
          await pool.query(`
            INSERT INTO slots (venue_id, slot_date, start_time, end_time, price, status)
            VALUES ($1, CURRENT_DATE + $2::integer, $3::time, $4::time, $5, $6)
          `, [
            venueId, day, `${hour}:00:00`, `${hour+1}:00:00`, slotPrice, status
          ]);
        }
      }
    }

    console.log('Successfully seeded venues and slots.');
  } catch (e) {
    console.error('Seeding error:', e);
  } finally {
    pool.end();
  }
}

seed();
