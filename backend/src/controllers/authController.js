const bcrypt = require('bcrypt');
const jwt = require('jsonwebtoken');
const pool = require('../db/pool');

// ─── REGISTER PLAYER ─────────────────────────────────────────
const registerPlayer = async (req, res) => {
  try {
    const { name, phone, password, email, firebaseUid, avatarUrl } = req.body;

    if (!name || name.trim().length < 3) {
      return res.status(400).json({ success: false, message: 'Name must be at least 3 characters' });
    }
    if (!phone) {
      return res.status(400).json({ success: false, message: 'Phone number is required' });
    }
    if (!firebaseUid) {
      return res.status(400).json({ success: false, message: 'Phone verification required before registration' });
    }
    if (!password || password.length < 8) {
      return res.status(400).json({ success: false, message: 'Password must be at least 8 characters' });
    }

    if (email && email.trim() !== '') {
      const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
      if (!emailRegex.test(email.trim())) {
        return res.status(400).json({ success: false, message: 'Invalid email format' });
      }
    }

    const existingPhone = await pool.query('SELECT id FROM users WHERE phone = $1', [phone]);
    if (existingPhone.rows.length > 0) {
      return res.status(409).json({ success: false, message: 'Phone number already registered' });
    }

    if (email && email.trim() !== '') {
      const existingEmail = await pool.query('SELECT id FROM users WHERE email = $1', [email.trim()]);
      if (existingEmail.rows.length > 0) {
        return res.status(409).json({ success: false, message: 'Email already registered' });
      }
    }

    const hashedPassword = await bcrypt.hash(password, 12);
    const emailValue = (email && email.trim() !== '') ? email.trim() : null;

    const client = await pool.connect();
    try {
      await client.query('BEGIN');

      const userResult = await client.query(
        `INSERT INTO users (name, phone, email, password_hash, role, phone_verified, avatar_url)
         VALUES ($1, $2, $3, $4, 'player', true, $5)
         RETURNING id, name, phone, email, role, avatar_url`,
        [name.trim(), phone, emailValue, hashedPassword, avatarUrl || null]
      );
      const user = userResult.rows[0];

      await client.query('INSERT INTO player_profiles (user_id) VALUES ($1)', [user.id]);
      await client.query('INSERT INTO wallets (user_id, balance) VALUES ($1, 0.00)', [user.id]);

      await client.query('COMMIT');

      const token = jwt.sign(
        { id: user.id, role: 'player', phone: user.phone },
        process.env.JWT_SECRET,
        { expiresIn: '30d' }
      );

      return res.status(201).json({
        success: true,
        data: {
          token,
          user: { id: user.id, name: user.name, phone: user.phone, email: user.email, role: user.role, avatarUrl: user.avatar_url }
        },
        message: 'Registration successful',
      });
    } catch (err) {
      await client.query('ROLLBACK');
      throw err;
    } finally {
      client.release();
    }
  } catch (err) {
    console.error('Register player error:', err);
    if (err.code === '23505') {
      return res.status(409).json({ success: false, message: 'Phone number or email already registered' });
    }
    return res.status(500).json({ success: false, message: 'Internal server error' });
  }
};

// ─── REGISTER OWNER ──────────────────────────────────────────
const registerOwner = async (req, res) => {
  try {
    const {
      name, phone, password, email, firebaseUid,
      cnicNumber,
      businessName, groundName, groundType, sportTypes,
      city, fullAddress, googleMapsLink,
      latitude, longitude, operatingHoursFrom, operatingHoursTo, pricePerHour,
      alternateContactPhone,
      cnicFrontUrl, cnicBackUrl, selfieWithCnicUrl,
      groundPhotos, utilityBillUrl, ownershipProofUrl
    } = req.body;

    if (!firebaseUid) {
      return res.status(400).json({ success: false, message: 'Phone verification required' });
    }
    if (!name || name.trim().length < 3) {
      return res.status(400).json({ success: false, message: 'Name must be at least 3 characters' });
    }
    if (!phone) {
      return res.status(400).json({ success: false, message: 'Phone number is required' });
    }
    if (!password || password.length < 8) {
      return res.status(400).json({ success: false, message: 'Password must be at least 8 characters' });
    }

    const cnicClean = cnicNumber ? cnicNumber.replace(/-/g, '') : '';
    if (!cnicClean || cnicClean.length !== 13 || !/^\d{13}$/.test(cnicClean)) {
      return res.status(400).json({ success: false, message: 'Invalid CNIC. Must be 13 digits.' });
    }

    const existingPhone = await pool.query('SELECT id FROM users WHERE phone = $1', [phone]);
    if (existingPhone.rows.length > 0) {
      return res.status(409).json({ success: false, message: 'Phone number already registered' });
    }

    if (email && email.trim() !== '') {
      const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
      if (!emailRegex.test(email.trim())) {
        return res.status(400).json({ success: false, message: 'Invalid email format' });
      }
      const existingEmail = await pool.query('SELECT id FROM users WHERE email = $1', [email.trim()]);
      if (existingEmail.rows.length > 0) {
        return res.status(409).json({ success: false, message: 'Email already registered' });
      }
    }

    const hashedPassword = await bcrypt.hash(password, 12);
    const emailValue = (email && email.trim() !== '') ? email.trim() : null;
    const parsedSportTypes = typeof sportTypes === 'string' ? JSON.parse(sportTypes) : (sportTypes || []);
    const parsedGroundPhotos = typeof groundPhotos === 'string' ? JSON.parse(groundPhotos) : (groundPhotos || []);

    const client = await pool.connect();
    try {
      await client.query('BEGIN');

      const userResult = await client.query(
        `INSERT INTO users (name, phone, email, password_hash, role, phone_verified)
         VALUES ($1, $2, $3, $4, 'owner', true)
         RETURNING id, name, phone, email, role`,
        [name.trim(), phone, emailValue, hashedPassword]
      );
      const user = userResult.rows[0];

      await client.query(
        `INSERT INTO owner_profiles (
          user_id, full_name, cnic_number, cnic_front_url, cnic_back_url,
          selfie_with_cnic_url, business_name, ground_name, ground_type,
          sport_types, city, full_address, google_maps_link, latitude, longitude,
          operating_hours_from, operating_hours_to, price_per_hour,
          ground_photos, utility_bill_url, ownership_proof_url,
          alternate_contact_phone, verification_status
        ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,'pending')`,
        [
          user.id, name.trim(), cnicNumber,
          cnicFrontUrl || null, cnicBackUrl || null, selfieWithCnicUrl || null,
          businessName || null, groundName || null, groundType || null,
          parsedSportTypes, city || null, fullAddress || null, googleMapsLink || null,
          latitude || null, longitude || null,
          operatingHoursFrom || null, operatingHoursTo || null, pricePerHour || null,
          parsedGroundPhotos, utilityBillUrl || null, ownershipProofUrl || null,
          alternateContactPhone || null
        ]
      );

      await client.query('INSERT INTO wallets (user_id, balance) VALUES ($1, 0.00)', [user.id]);
      await client.query('COMMIT');

      const token = jwt.sign(
        { id: user.id, role: 'owner', phone: user.phone },
        process.env.JWT_SECRET,
        { expiresIn: '30d' }
      );

      return res.status(201).json({
        success: true,
        message: 'Registration submitted. Admin will review within 24-48 hours.',
        data: { token, user, status: 'pending' }
      });
    } catch (err) {
      await client.query('ROLLBACK');
      throw err;
    } finally {
      client.release();
    }
  } catch (err) {
    console.error('Register owner error:', err);
    if (err.code === '23505') {
      if (err.constraint === 'owner_cnic_unique') {
        return res.status(409).json({ success: false, message: 'This CNIC is already registered' });
      }
      return res.status(409).json({ success: false, message: 'Phone number or email already registered' });
    }
    return res.status(500).json({ success: false, message: 'Internal server error' });
  }
};

// ─── LOGIN (phone OR email) ─────────────────────────────────
const login = async (req, res) => {
  try {
    const { identifier, password } = req.body;

    if (!identifier || !password) {
      return res.status(400).json({ success: false, message: 'Phone/email and password are required' });
    }

    let userResult;
    const cleaned = identifier.replace(/\s/g, '');
    const isPhone = /^0[0-9]{10}$/.test(cleaned);

    if (isPhone) {
      userResult = await pool.query('SELECT * FROM users WHERE phone = $1', [cleaned]);
    } else {
      userResult = await pool.query('SELECT * FROM users WHERE email = $1', [cleaned.toLowerCase()]);
    }

    if (userResult.rows.length === 0) {
      return res.status(401).json({ success: false, message: 'Invalid credentials provided' });
    }

    const user = userResult.rows[0];

    if (!user.is_active) {
      return res.status(403).json({ success: false, message: 'Account suspended. Contact support.' });
    }

    if (user.role === 'owner') {
      const ownerProfile = await pool.query(
        'SELECT verification_status, rejection_reason FROM owner_profiles WHERE user_id = $1',
        [user.id]
      );
      if (ownerProfile.rows.length > 0) {
        const status = ownerProfile.rows[0].verification_status;
        if (status === 'pending' || status === 'under_review') {
          return res.status(403).json({
            success: false,
            message: 'Your owner account is under review. You will be notified once approved.',
            status: 'pending'
          });
        }
        if (status === 'rejected') {
          return res.status(403).json({
            success: false,
            message: `Account rejected: ${ownerProfile.rows[0].rejection_reason || 'Contact support'}`,
            status: 'rejected'
          });
        }
      }
    }

    const passwordMatch = await bcrypt.compare(password, user.password_hash);
    if (!passwordMatch) {
      return res.status(401).json({ success: false, message: 'Invalid credentials provided' });
    }

    const token = jwt.sign(
      { id: user.id, role: user.role, phone: user.phone },
      process.env.JWT_SECRET,
      { expiresIn: '30d' }
    );

    return res.json({
      success: true,
      data: {
        token,
        user: {
          id: user.id, name: user.name, phone: user.phone,
          email: user.email, role: user.role, avatarUrl: user.avatar_url
        }
      },
      message: 'Login successful',
    });
  } catch (err) {
    console.error('Login error:', err);
    return res.status(500).json({ success: false, message: 'Internal server error' });
  }
};

// ─── VERIFY PHONE ────────────────────────────────────────────
const verifyPhone = async (req, res) => {
  try {
    const { phone, firebaseUid, purpose } = req.body;
    await pool.query(
      `INSERT INTO phone_otp_log (phone, purpose, firebase_uid, verified) VALUES ($1, $2, $3, true)`,
      [phone, purpose || 'registration', firebaseUid || null]
    );
    return res.json({ success: true, message: 'Phone verified' });
  } catch (err) {
    console.error('Verify phone error:', err);
    return res.status(500).json({ success: false, message: 'Internal server error' });
  }
};

// ─── FORGOT PASSWORD: SEND OTP ──────────────────────────────
const forgotPasswordSendOtp = async (req, res) => {
  try {
    const { phone } = req.body;
    if (!phone) {
      return res.status(400).json({ success: false, message: 'Phone number is required' });
    }
    const user = await pool.query('SELECT id FROM users WHERE phone = $1', [phone]);
    if (user.rows.length === 0) {
      return res.status(404).json({ success: false, message: 'No account found with this phone number' });
    }
    return res.json({ success: true, message: 'Proceed with Firebase OTP verification' });
  } catch (err) {
    console.error('Forgot password send OTP error:', err);
    return res.status(500).json({ success: false, message: 'Internal server error' });
  }
};

// ─── FORGOT PASSWORD: RESET ─────────────────────────────────
const forgotPasswordReset = async (req, res) => {
  try {
    const { phone, newPassword, firebaseUid } = req.body;
    if (!firebaseUid) {
      return res.status(400).json({ success: false, message: 'OTP verification required' });
    }
    if (!newPassword || newPassword.length < 8) {
      return res.status(400).json({ success: false, message: 'Password must be at least 8 characters' });
    }
    const hashed = await bcrypt.hash(newPassword, 12);
    const result = await pool.query('UPDATE users SET password_hash = $1 WHERE phone = $2 RETURNING id', [hashed, phone]);
    if (result.rows.length === 0) {
      return res.status(404).json({ success: false, message: 'No account found with this phone number' });
    }
    return res.json({ success: true, message: 'Password reset successful' });
  } catch (err) {
    console.error('Forgot password reset error:', err);
    return res.status(500).json({ success: false, message: 'Internal server error' });
  }
};

// ─── GET ME ──────────────────────────────────────────────────
const getMe = async (req, res) => {
  try {
    const result = await pool.query(
      'SELECT id, name, email, role, phone, phone_verified, avatar_url, created_at FROM users WHERE id = $1',
      [req.user.id]
    );
    if (result.rows.length === 0) {
      return res.status(404).json({ success: false, message: 'User not found' });
    }
    const user = result.rows[0];
    return res.json({
      success: true,
      data: {
        user: {
          id: user.id, name: user.name, email: user.email, role: user.role,
          phone: user.phone, avatarUrl: user.avatar_url, created_at: user.created_at
        }
      },
      message: 'User retrieved',
    });
  } catch (err) {
    console.error('GetMe error:', err);
    return res.status(500).json({ success: false, message: 'Internal server error' });
  }
};

module.exports = { registerPlayer, registerOwner, login, verifyPhone, forgotPasswordSendOtp, forgotPasswordReset, getMe };
