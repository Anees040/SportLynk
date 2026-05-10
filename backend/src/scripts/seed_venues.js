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

const FOOTBALL_PICS = [
  'https://images.unsplash.com/photo-1579952363873-27f3bade9f55?q=80&w=800&auto=format&fit=crop',
  'https://images.unsplash.com/photo-1518605368461-1ee711689b66?q=80&w=800&auto=format&fit=crop',
  'https://images.unsplash.com/photo-1551280857-2b9ebf1fa5fc?q=80&w=800&auto=format&fit=crop',
];

const CRICKET_PICS = [
  'https://images.unsplash.com/photo-1540747913346-19e32dc3e97e?q=80&w=800&auto=format&fit=crop',
  'https://images.unsplash.com/photo-1531415074968-036ba1b575da?q=80&w=800&auto=format&fit=crop',
  'https://images.unsplash.com/photo-1624526267942-ab0f0b580098?q=80&w=800&auto=format&fit=crop',
];

const VIDEO_URL = 'https://www.w3schools.com/html/mov_bbb.mp4';

const DUMMY_VENUES = [
  { name: 'F-11 Markaz Football Arena', sport_type: 'football', city: 'Islamabad', address: 'F-11 Markaz, Islamabad', lat: 33.6844, lng: 73.0479, price: 2000, type: 'turf', rating: 4.8, rev: 124 },
  { name: 'Jinnah Sports Complex', sport_type: 'football', city: 'Islamabad', address: 'G-6, Islamabad', lat: 33.7185, lng: 73.0828, price: 2500, type: 'indoor', rating: 4.5, rev: 89 },
  { name: 'Centaurus Kickoff', sport_type: 'football', city: 'Islamabad', address: 'F-8, Islamabad', lat: 33.7081, lng: 73.0504, price: 3000, type: 'turf', rating: 4.9, rev: 210 },
  { name: 'Bahria Town Futsal Ground', sport_type: 'football', city: 'Rawalpindi', address: 'Phase 4, Bahria Town, Rawalpindi', lat: 33.5516, lng: 73.1166, price: 1800, type: 'turf', rating: 4.3, rev: 45 },
  { name: 'DHA Phase 2 Arena', sport_type: 'football', city: 'Islamabad', address: 'DHA Phase 2, Islamabad', lat: 33.5350, lng: 73.1500, price: 2200, type: 'indoor', rating: 4.6, rev: 110 },
  { name: 'Rawal Lake Futsal', sport_type: 'football', city: 'Islamabad', address: 'Rawal Lake Park, Islamabad', lat: 33.7000, lng: 73.1200, price: 1500, type: 'turf', rating: 4.2, rev: 67 },
  { name: 'Ayub Park Football Pitch', sport_type: 'football', city: 'Rawalpindi', address: 'Ayub National Park, Rawalpindi', lat: 33.5700, lng: 73.0500, price: 1600, type: 'turf', rating: 4.4, rev: 88 },
  { name: 'G-11 Sports Club', sport_type: 'football', city: 'Islamabad', address: 'G-11 Markaz, Islamabad', lat: 33.6650, lng: 73.0150, price: 2100, type: 'turf', rating: 4.7, rev: 156 },
  { name: 'PWD Football Academy', sport_type: 'football', city: 'Islamabad', address: 'PWD Housing Society, Islamabad', lat: 33.5680, lng: 73.1360, price: 1700, type: 'indoor', rating: 4.1, rev: 34 },
  { name: 'Stadium Road Futsal', sport_type: 'football', city: 'Rawalpindi', address: 'Stadium Road, Rawalpindi', lat: 33.6300, lng: 73.0700, price: 1900, type: 'turf', rating: 4.5, rev: 92 },
  
  { name: 'Diamond Cricket Ground', sport_type: 'cricket', city: 'Islamabad', address: 'Sector G-8/2, Islamabad', lat: 33.6940, lng: 73.0500, price: 3500, type: 'turf', rating: 4.8, rev: 320 },
  { name: 'Shalimar Cricket Academy', sport_type: 'cricket', city: 'Islamabad', address: 'F-7 Markaz, Islamabad', lat: 33.7200, lng: 73.0550, price: 2800, type: 'indoor', rating: 4.4, rev: 78 },
  { name: 'Rawalpindi Cricket Stadium Nets', sport_type: 'cricket', city: 'Rawalpindi', address: 'Stadium Road, Rawalpindi', lat: 33.6400, lng: 73.0760, price: 1500, type: 'indoor', rating: 4.6, rev: 145 },
  { name: 'Bahria Cricket Arena', sport_type: 'cricket', city: 'Rawalpindi', address: 'Phase 7, Bahria Town, Rawalpindi', lat: 33.5300, lng: 73.1200, price: 2200, type: 'turf', rating: 4.5, rev: 89 },
  { name: 'DHA Phase 1 Nets', sport_type: 'cricket', city: 'Islamabad', address: 'DHA Phase 1, Islamabad', lat: 33.5400, lng: 73.1100, price: 1800, type: 'indoor', rating: 4.2, rev: 55 },
  { name: 'Margalla Cricket Club', sport_type: 'cricket', city: 'Islamabad', address: 'F-9 Park, Islamabad', lat: 33.7050, lng: 73.0150, price: 4000, type: 'turf', rating: 4.9, rev: 410 },
  { name: 'Saddar Indoor Nets', sport_type: 'cricket', city: 'Rawalpindi', address: 'Saddar, Rawalpindi', lat: 33.5950, lng: 73.0450, price: 1600, type: 'indoor', rating: 4.1, rev: 42 },
  { name: 'G-9 Markaz Pitch', sport_type: 'cricket', city: 'Islamabad', address: 'G-9 Markaz, Islamabad', lat: 33.6800, lng: 73.0300, price: 2000, type: 'turf', rating: 4.3, rev: 67 },
  { name: 'CBR Town Cricket Ground', sport_type: 'cricket', city: 'Islamabad', address: 'CBR Town, Islamabad', lat: 33.5800, lng: 73.1300, price: 2500, type: 'turf', rating: 4.4, rev: 95 },
  { name: 'Liaquat Bagh Nets', sport_type: 'cricket', city: 'Rawalpindi', address: 'Liaquat Bagh, Rawalpindi', lat: 33.6050, lng: 73.0550, price: 1200, type: 'indoor', rating: 4.0, rev: 28 },
];

async function seed() {
  try {
    console.log('Connecting to DB...');
    await pool.query('DELETE FROM venues'); // Clear old dummy venues (cascades slots & bookings)
    console.log('Cleared existing venues.');

    // Find the test owner to assign venues
    const ownerRes = await pool.query("SELECT id FROM users WHERE role='owner' LIMIT 1");
    const ownerId = ownerRes.rows.length > 0 ? ownerRes.rows[0].id : null;

    console.log('Inserting 20 synthetic venues...');
    for (const v of DUMMY_VENUES) {
      const photos = v.sport_type === 'football' ? FOOTBALL_PICS : CRICKET_PICS;
      const mainImage = photos[Math.floor(Math.random() * photos.length)];

      const res = await pool.query(`
        INSERT INTO venues (
          owner_id, name, description, sport_type, city, address, 
          latitude, longitude, base_price, current_price, price_per_hour,
          image_url, venue_photos, video_url, is_active, rating, total_reviews, ground_type
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18)
        RETURNING id
      `, [
        ownerId, v.name, `Premium ${v.sport_type} facility in ${v.city}. Professional lighting and high-quality ${v.type}.`,
        v.sport_type, v.city, v.address, v.lat, v.lng, v.price, v.price, v.price,
        mainImage, photos, VIDEO_URL, true, v.rating, v.rev, v.type
      ]);

      const venueId = res.rows[0].id;

      // Generate Slots for the next 7 days, 16:00 to 23:00
      for (let day = 0; day <= 7; day++) {
        for (let hour = 16; hour <= 23; hour++) {
          await pool.query(`
            INSERT INTO slots (venue_id, slot_date, start_time, end_time, price, status)
            VALUES ($1, CURRENT_DATE + $2::integer, $3::time, $4::time, $5, 'available')
          `, [
            venueId, day, `${hour}:00:00`, `${hour+1}:00:00`, v.price
          ]);
        }
      }
    }

    console.log('Successfully seeded 20 synthetic venues and slots.');
  } catch (e) {
    console.error('Seeding error:', e);
  } finally {
    pool.end();
  }
}

seed();
