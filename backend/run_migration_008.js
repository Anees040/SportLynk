const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '.env') });
const bcrypt = require('bcrypt');
const pool = require('./src/db/pool');

async function run() {
  try {
    console.log('🔄 Running migration 008: Admin role & venues...\n');

    // ── Step 1: Add admin to user_role enum ──────────────────────────────────
    try {
      await pool.query("ALTER TYPE user_role ADD VALUE 'admin'");
      console.log('✅ Added admin to user_role enum');
    } catch (e) {
      if (e.message.includes('already exists') || e.message.includes('duplicate')) {
        console.log('⏭️  user_role.admin already exists');
      } else {
        throw e;
      }
    }

    // ── Step 2: Add columns to venues ────────────────────────────────────────
    await pool.query("ALTER TABLE venues ADD COLUMN IF NOT EXISTS is_verified BOOLEAN DEFAULT true");
    await pool.query("ALTER TABLE venues ADD COLUMN IF NOT EXISTS verification_status VARCHAR(20) DEFAULT 'approved'");
    console.log('✅ venues: is_verified, verification_status columns ensured');

    // ── Step 3: Add columns to owner_profiles ────────────────────────────────
    await pool.query("ALTER TABLE owner_profiles ADD COLUMN IF NOT EXISTS rejection_reason TEXT");
    await pool.query("ALTER TABLE owner_profiles ADD COLUMN IF NOT EXISTS reviewed_at TIMESTAMP");
    await pool.query("ALTER TABLE owner_profiles ADD COLUMN IF NOT EXISTS reviewed_by UUID REFERENCES users(id)");
    console.log('✅ owner_profiles: rejection_reason, reviewed_at, reviewed_by columns ensured');

    // ── Step 4: Create admin user ─────────────────────────────────────────────
    const adminExists = await pool.query("SELECT id FROM users WHERE email = 'admin@sportlynk.com'");
    if (adminExists.rows.length === 0) {
      const hash = await bcrypt.hash('Admin@SportLynk1', 12);
      const adminRes = await pool.query(
        `INSERT INTO users (name, email, password_hash, role, phone, phone_verified, is_active)
         VALUES ('Admin SportLynk', 'admin@sportlynk.com', $1, 'admin', '03000000000', true, true)
         RETURNING id`,
        [hash]
      );
      const adminId = adminRes.rows[0].id;
      await pool.query('INSERT INTO wallets (user_id, balance) VALUES ($1, 0)', [adminId]);
      console.log('✅ Admin created:');
      console.log('   Email:    admin@sportlynk.com');
      console.log('   Password: Admin@SportLynk1');
      console.log('   Role:     admin');
    } else {
      console.log('⏭️  Admin user already exists (admin@sportlynk.com)');
    }

    // ── Step 5: Create test owner ─────────────────────────────────────────────
    const ownerExists = await pool.query("SELECT id FROM users WHERE email = 'testowner@sportlynk.com'");
    let ownerId;

    if (ownerExists.rows.length === 0) {
      const hash = await bcrypt.hash('Owner@123', 12);
      const ownerRes = await pool.query(
        `INSERT INTO users (name, email, password_hash, role, phone, phone_verified, is_active)
         VALUES ('Ahmed Khan', 'testowner@sportlynk.com', $1, 'owner', '03331234567', true, true)
         RETURNING id`,
        [hash]
      );
      ownerId = ownerRes.rows[0].id;
      await pool.query('INSERT INTO wallets (user_id, balance) VALUES ($1, 0)', [ownerId]);

      // Create approved owner_profile
      await pool.query(
        `INSERT INTO owner_profiles (
           user_id, full_name, cnic_number, business_name, ground_name, ground_type,
           sport_types, city, full_address, operating_hours_from, operating_hours_to,
           price_per_hour, verification_status, reviewed_at
         )
         VALUES ($1, 'Ahmed Khan', '1234567890123', 'Khan Sports',
                 'F-11 Markaz Football Arena', 'turf', ARRAY['Football'], 'Islamabad',
                 'F-11 Markaz, Islamabad', '14:00', '23:00', 2000.00, 'approved', NOW())`,
        [ownerId]
      );

      console.log('✅ Test owner created:');
      console.log('   Email:    testowner@sportlynk.com');
      console.log('   Password: Owner@123');
      console.log('   Role:     owner (approved)');
    } else {
      ownerId = ownerExists.rows[0].id;
      console.log('⏭️  Test owner already exists (testowner@sportlynk.com)');
    }

    // ── Step 6: Ensure test owner has a venue ────────────────────────────────
    if (ownerId) {
      const venueExists = await pool.query('SELECT id FROM venues WHERE owner_id = $1 LIMIT 1', [ownerId]);

      if (venueExists.rows.length === 0) {
        const venueRes = await pool.query(
          `INSERT INTO venues (
             owner_id, name, description, sport_type, city, address,
             base_price, price_per_hour, upfront_percent, rating, total_reviews,
             venue_photos, operating_hours_from, operating_hours_to,
             is_active, is_verified, verification_status
           )
           VALUES (
             $1,
             'F-11 Markaz Football Arena',
             'Premium indoor football turf with floodlights and all facilities',
             'football', 'Islamabad', 'F-11 Markaz, Islamabad, Pakistan',
             2000, 2000, 30, 4.8, 124,
             ARRAY[
               'https://images.unsplash.com/photo-1546519638-68e109498ffc?w=800&q=80',
               'https://images.unsplash.com/photo-1459865264687-595d652de67e?w=800&q=80',
               'https://images.unsplash.com/photo-1574629810360-7efbb1924043?w=800&q=80'
             ],
             '14:00', '23:00', true, true, 'approved'
           )
           RETURNING id`,
          [ownerId]
        );
        const venueId = venueRes.rows[0].id;

        // Create slots for next 14 days
        let slotsCreated = 0;
        for (let d = 0; d < 14; d++) {
          const slotDate = new Date();
          slotDate.setDate(slotDate.getDate() + d);
          const dateStr = slotDate.toISOString().split('T')[0];
          for (let h = 14; h < 23; h++) {
            const startTime = `${h.toString().padStart(2, '0')}:00:00`;
            const endTime = `${(h + 1).toString().padStart(2, '0')}:00:00`;
            await pool.query(
              `INSERT INTO slots (venue_id, slot_date, start_time, end_time, price, status)
               VALUES ($1, $2, $3, $4, 2000, 'available')
               ON CONFLICT DO NOTHING`,
              [venueId, dateStr, startTime, endTime]
            );
            slotsCreated++;
          }
        }

        console.log(`✅ Test venue created: ${venueId}`);
        console.log(`   Name: F-11 Markaz Football Arena`);
        console.log(`   Slots: ${slotsCreated} slots over 14 days (14:00-23:00)`);
      } else {
        console.log(`⏭️  Test owner already has a venue (${venueExists.rows[0].id})`);
      }
    }

    console.log('\n✅ Migration 008 complete\n');
    process.exit(0);
  } catch (e) {
    console.error('\n❌ Migration 008 failed:', e.message);
    console.error(e.stack);
    process.exit(1);
  }
}

run();
