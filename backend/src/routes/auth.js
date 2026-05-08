const router = require('express').Router();
const bcrypt = require('bcrypt');
const jwt = require('jsonwebtoken');
const pool = require('../db/pool');
const auth = require('../middleware/authMiddleware');

// ─── POST /api/auth/register/player ──────────────────────────
router.post('/register/player', async (req, res, next) => {
  try {
    const { name, phone, password, email, firebaseUid, avatarUrl } = req.body;

    if (!name || name.trim().length < 3) {
      return res.status(400).json({ success: false, message: 'Name must be at least 3 characters' });
    }
    if (!phone || !/^03\d{9}$/.test(phone.replace(/\s/g, ''))) {
      return res.status(400).json({ success: false, message: 'Valid Pakistani phone required (03XXXXXXXXX)' });
    }
    if (!firebaseUid) {
      return res.status(400).json({ success: false, message: 'Phone verification required before registration' });
    }
    if (!password || password.length < 8) {
      return res.status(400).json({ success: false, message: 'Password must be at least 8 characters' });
    }
    if (email && email.trim() !== '') {
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim())) {
        return res.status(400).json({ success: false, message: 'Invalid email format' });
      }
      const dup = await pool.query('SELECT id FROM users WHERE email = $1', [email.trim()]);
      if (dup.rows.length > 0) {
        return res.status(409).json({ success: false, message: 'Email already registered' });
      }
    }

    const phoneDup = await pool.query('SELECT id FROM users WHERE phone = $1', [phone.replace(/\s/g, '')]);
    if (phoneDup.rows.length > 0) {
      return res.status(409).json({ success: false, message: 'Phone number already registered' });
    }

    const hashedPassword = await bcrypt.hash(password, 12);
    const emailVal = (email && email.trim() !== '') ? email.trim() : null;
    const cleanPhone = phone.replace(/\s/g, '');

    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      const userRes = await client.query(
        `INSERT INTO users (name, phone, email, password_hash, role, phone_verified, avatar_url)
         VALUES ($1, $2, $3, $4, 'player', true, $5)
         RETURNING id, name, phone, email, role, avatar_url`,
        [name.trim(), cleanPhone, emailVal, hashedPassword, avatarUrl || null]
      );
      const user = userRes.rows[0];
      await client.query('INSERT INTO player_profiles (user_id) VALUES ($1)', [user.id]);
      await client.query('INSERT INTO wallets (user_id, balance) VALUES ($1, 0.00)', [user.id]);
      await client.query('COMMIT');

      const token = jwt.sign({ id: user.id, role: 'player', phone: user.phone }, process.env.JWT_SECRET, { expiresIn: '30d' });
      return res.status(201).json({
        success: true,
        data: { token, user: { id: user.id, name: user.name, phone: user.phone, email: user.email, role: user.role, avatarUrl: user.avatar_url } },
        message: 'Registration successful'
      });
    } catch (e) {
      await client.query('ROLLBACK');
      throw e;
    } finally {
      client.release();
    }
  } catch (err) {
    if (err.code === '23505') return res.status(409).json({ success: false, message: 'Phone or email already registered' });
    next(err);
  }
});

// ─── POST /api/auth/register/owner ───────────────────────────
router.post('/register/owner', async (req, res, next) => {
  try {
    const {
      name, phone, password, email, firebaseUid, cnicNumber,
      businessName, groundName, groundType, sportTypes,
      city, fullAddress, googleMapsLink, latitude, longitude,
      operatingHoursFrom, operatingHoursTo, pricePerHour,
      alternateContactPhone,
      cnicFrontUrl, cnicBackUrl, selfieWithCnicUrl,
      groundPhotos, utilityBillUrl, ownershipProofUrl
    } = req.body;

    if (!firebaseUid) return res.status(400).json({ success: false, message: 'Phone verification required' });
    if (!name || name.trim().length < 3) return res.status(400).json({ success: false, message: 'Name must be at least 3 characters' });
    if (!phone || !/^03\d{9}$/.test(phone.replace(/\s/g, ''))) return res.status(400).json({ success: false, message: 'Valid phone required' });
    if (!password || password.length < 8) return res.status(400).json({ success: false, message: 'Password min 8 chars' });

    const cnicClean = cnicNumber ? cnicNumber.replace(/-/g, '') : '';
    if (cnicClean.length !== 13 || !/^\d{13}$/.test(cnicClean)) {
      return res.status(400).json({ success: false, message: 'Invalid CNIC. Must be 13 digits.' });
    }

    const phoneDup = await pool.query('SELECT id FROM users WHERE phone = $1', [phone.replace(/\s/g, '')]);
    if (phoneDup.rows.length > 0) return res.status(409).json({ success: false, message: 'Phone already registered' });

    if (email && email.trim() !== '') {
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim())) return res.status(400).json({ success: false, message: 'Invalid email format' });
      const dup = await pool.query('SELECT id FROM users WHERE email = $1', [email.trim()]);
      if (dup.rows.length > 0) return res.status(409).json({ success: false, message: 'Email already registered' });
    }

    const hashedPassword = await bcrypt.hash(password, 12);
    const emailVal = (email && email.trim() !== '') ? email.trim() : null;
    const cleanPhone = phone.replace(/\s/g, '');
    const parsedSports = typeof sportTypes === 'string' ? JSON.parse(sportTypes) : (sportTypes || []);
    const parsedPhotos = typeof groundPhotos === 'string' ? JSON.parse(groundPhotos) : (groundPhotos || []);

    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      const userRes = await client.query(
        `INSERT INTO users (name, phone, email, password_hash, role, phone_verified) VALUES ($1,$2,$3,$4,'owner',true) RETURNING id, name, phone, email, role`,
        [name.trim(), cleanPhone, emailVal, hashedPassword]
      );
      const user = userRes.rows[0];

      await client.query(
        `INSERT INTO owner_profiles (user_id, full_name, cnic_number, cnic_front_url, cnic_back_url, selfie_with_cnic_url, business_name, ground_name, ground_type, sport_types, city, full_address, google_maps_link, latitude, longitude, operating_hours_from, operating_hours_to, price_per_hour, ground_photos, utility_bill_url, ownership_proof_url, alternate_contact_phone, verification_status)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,'pending')`,
        [user.id, name.trim(), cnicNumber, cnicFrontUrl||null, cnicBackUrl||null, selfieWithCnicUrl||null,
         businessName||null, groundName||null, groundType||null, parsedSports, city||null, fullAddress||null,
         googleMapsLink||null, latitude||null, longitude||null, operatingHoursFrom||null, operatingHoursTo||null,
         pricePerHour||null, parsedPhotos, utilityBillUrl||null, ownershipProofUrl||null, alternateContactPhone||null]
      );
      await client.query('INSERT INTO wallets (user_id, balance) VALUES ($1, 0.00)', [user.id]);
      await client.query('COMMIT');

      const token = jwt.sign({ id: user.id, role: 'owner', phone: user.phone }, process.env.JWT_SECRET, { expiresIn: '30d' });
      return res.status(201).json({
        success: true, message: 'Registration submitted. Admin will review within 24-48 hours.',
        data: { token, user: { id: user.id, name: user.name, phone: user.phone, email: user.email, role: user.role }, status: 'pending' }
      });
    } catch (e) { await client.query('ROLLBACK'); throw e; }
    finally { client.release(); }
  } catch (err) {
    if (err.code === '23505') {
      if (err.constraint === 'owner_cnic_unique') return res.status(409).json({ success: false, message: 'CNIC already registered' });
      return res.status(409).json({ success: false, message: 'Phone or email already registered' });
    }
    next(err);
  }
});

// ─── POST /api/auth/login ────────────────────────────────────
router.post('/login', async (req, res, next) => {
  try {
    const { identifier, password } = req.body;
    if (!identifier || !password) return res.status(400).json({ success: false, message: 'Phone/email and password required' });

    const cleaned = identifier.replace(/\s/g, '');
    const isPhone = /^0[0-9]{10}$/.test(cleaned);
    const userRes = isPhone
      ? await pool.query('SELECT * FROM users WHERE phone = $1', [cleaned])
      : await pool.query('SELECT * FROM users WHERE email = $1', [cleaned.toLowerCase()]);

    if (userRes.rows.length === 0) return res.status(401).json({ success: false, message: 'No account found with this phone/email' });
    const user = userRes.rows[0];

    if (!user.is_active) return res.status(403).json({ success: false, message: 'Account suspended. Contact support.' });

    if (user.role === 'owner') {
      const op = await pool.query('SELECT verification_status, rejection_reason FROM owner_profiles WHERE user_id = $1', [user.id]);
      if (op.rows.length > 0) {
        const st = op.rows[0].verification_status;
        if (st === 'pending' || st === 'under_review') {
          return res.status(403).json({ success: false, message: 'Your account is under review.', status: 'pending' });
        }
        if (st === 'rejected') {
          return res.status(403).json({ success: false, message: `Rejected: ${op.rows[0].rejection_reason || 'Contact support'}`, status: 'rejected' });
        }
      }
    }

    const match = await bcrypt.compare(password, user.password_hash);
    if (!match) return res.status(401).json({ success: false, message: 'Incorrect password' });

    const token = jwt.sign({ id: user.id, role: user.role, phone: user.phone }, process.env.JWT_SECRET, { expiresIn: '30d' });
    return res.json({
      success: true,
      data: { token, user: { id: user.id, name: user.name, phone: user.phone, email: user.email, role: user.role, avatarUrl: user.avatar_url } },
      message: 'Login successful'
    });
  } catch (err) { next(err); }
});

// ─── POST /api/auth/verify-phone ─────────────────────────────
router.post('/verify-phone', async (req, res, next) => {
  try {
    const { phone } = req.body;
    if (!phone) return res.status(400).json({ success: false, message: 'Phone required' });
    const existing = await pool.query('SELECT id FROM users WHERE phone = $1', [phone.replace(/\s/g, '')]);
    return res.json({ success: true, exists: existing.rows.length > 0 });
  } catch (err) { next(err); }
});

// ─── POST /api/auth/forgot-password/send-otp ─────────────────
router.post('/forgot-password/send-otp', async (req, res, next) => {
  try {
    const { phone } = req.body;
    if (!phone) return res.status(400).json({ success: false, message: 'Phone required' });
    const user = await pool.query('SELECT id FROM users WHERE phone = $1', [phone.replace(/\s/g, '')]);
    if (user.rows.length === 0) return res.status(404).json({ success: false, message: 'No account found with this phone number' });
    return res.json({ success: true, message: 'Proceed with Firebase OTP verification' });
  } catch (err) { next(err); }
});

// ─── POST /api/auth/forgot-password/reset ────────────────────
router.post('/forgot-password/reset', async (req, res, next) => {
  try {
    const { phone, newPassword, firebaseUid } = req.body;
    if (!firebaseUid) return res.status(403).json({ success: false, message: 'OTP verification required' });
    if (!newPassword || newPassword.length < 8) return res.status(400).json({ success: false, message: 'Password must be at least 8 characters' });
    const hashed = await bcrypt.hash(newPassword, 12);
    const result = await pool.query('UPDATE users SET password_hash = $1 WHERE phone = $2 RETURNING id', [hashed, phone.replace(/\s/g, '')]);
    if (result.rows.length === 0) return res.status(404).json({ success: false, message: 'No account found' });
    return res.json({ success: true, message: 'Password reset successful' });
  } catch (err) { next(err); }
});

// ─── GET /api/auth/me ────────────────────────────────────────
router.get('/me', auth, async (req, res, next) => {
  try {
    const result = await pool.query(
      'SELECT id, name, email, role, phone, phone_verified, avatar_url, created_at FROM users WHERE id = $1',
      [req.user.id]
    );
    if (result.rows.length === 0) return res.status(404).json({ success: false, message: 'User not found' });
    const u = result.rows[0];
    return res.json({
      success: true,
      data: { user: { id: u.id, name: u.name, email: u.email, role: u.role, phone: u.phone, avatarUrl: u.avatar_url, created_at: u.created_at } },
      message: 'User retrieved'
    });
  } catch (err) { next(err); }
});

module.exports = router;
