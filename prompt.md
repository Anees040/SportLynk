AGENT CONTEXT — READ BEFORE DOING ANYTHING
You are working on SportLynk, a Flutter + Node.js/Express + PostgreSQL sports venue booking app for Pakistan. The project already exists. Prompt 1 from the developer guide has been executed — the basic Flutter foundation compiles and runs. However, the auth UI is unprofessional, validations are broken or missing, the registration flow is wrong for both roles, and SMS OTP has not been implemented. Your job is to completely overhaul the auth system — backend + database + Flutter UI — in one autonomous session.
Tech stack:

Flutter (Dart) — frontend mobile app
Node.js + Express — backend REST API (already running)
PostgreSQL — database (local + Supabase cloud via .env switch)
Firebase Phone Authentication — for SMS OTP (free tier, works in Pakistan)
firebase_auth Flutter package for OTP UI and verification

Design language:

Primary dark: #0A1F13 (very dark green, used for header sections and AppBar)
Accent bright green: #22C55E
Accent light: #DCFCE7
Background: #F8FAFC (near-white, slightly cool)
Card background: #FFFFFF
Text primary: #111827
Text secondary: #6B7280
Error: #DC2626
Warning amber: #F59E0B
Font: Google Poppins (already in pubspec)
Input fields: light grey fill #F1F5F9, border-radius 12, no visible border on default, green border on focus, red border on error
Buttons: fully rounded (radius 28), accent green filled for primary, outlined for secondary
All cards: border-radius 16, elevation 0 with subtle border #E5E7EB or shadow
The reference aesthetic is: clean, minimal white body with a bold dark-green curved header section at top. Like a modern Pakistani fintech app (JazzCash/SadaPay aesthetic but greener).


PART 1 — DATABASE SCHEMA MIGRATION
Current schema problems:

users.email is UNIQUE NOT NULL — email must become optional (nullable, still unique when provided)
owner_profiles has only business_name, cnic, is_verified — completely inadequate
No phone OTP verification tracking anywhere
No CNIC image storage columns
No ground type field in venues
No owner verification status workflow (pending/approved/rejected)
No venue photos storage

Execute this migration script. The agent must write this as a .sql file AND run it via the project's database connection, OR provide clear instructions. Do NOT drop existing tables — use ALTER TABLE and CREATE TABLE IF NOT EXISTS:
sql-- MIGRATION: SportLynk Auth Overhaul
-- Run in pgAdmin Query Tool or via psql

-- 1. Make email optional (nullable) while keeping unique constraint for non-null values
ALTER TABLE users ALTER COLUMN email DROP NOT NULL;
-- Add partial unique index for email (only enforces uniqueness when email is not null)
DROP INDEX IF EXISTS users_email_key;
CREATE UNIQUE INDEX users_email_unique_when_not_null ON users (email) WHERE email IS NOT NULL;

-- 2. Add phone_verified and avatar_url to users (avatar_url may already exist, use IF NOT EXISTS pattern)
ALTER TABLE users ADD COLUMN IF NOT EXISTS phone_verified BOOLEAN DEFAULT false;
ALTER TABLE users ADD COLUMN IF NOT EXISTS avatar_url TEXT;

-- 3. Phone must be unique and not null going forward
-- First backfill any null phones with a placeholder (if existing data)
UPDATE users SET phone = 'UNKNOWN_' || id::text WHERE phone IS NULL;
ALTER TABLE users ALTER COLUMN phone SET NOT NULL;
-- Add unique constraint on phone
ALTER TABLE users ADD CONSTRAINT users_phone_unique UNIQUE (phone);

-- 4. Create owner_verification_status enum
DO $$ BEGIN
  CREATE TYPE owner_verification_status AS ENUM ('pending', 'under_review', 'approved', 'rejected');
EXCEPTION WHEN duplicate_object THEN null;
END $$;

-- 5. Create ground_type enum
DO $$ BEGIN
  CREATE TYPE ground_type AS ENUM ('turf', 'futsal', 'concrete', 'grass', 'indoor');
EXCEPTION WHEN duplicate_object THEN null;
END $$;

-- 6. Drop and recreate owner_profiles with full fields
DROP TABLE IF EXISTS owner_profiles CASCADE;
CREATE TABLE owner_profiles (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID REFERENCES users(id) ON DELETE CASCADE UNIQUE NOT NULL,

  -- Step 1: Personal Info
  full_name VARCHAR(255) NOT NULL,
  cnic_number VARCHAR(15) NOT NULL,       -- Format: XXXXX-XXXXXXX-X (15 chars with dashes, 13 digits)
  cnic_front_url TEXT,                    -- Cloudinary or Supabase Storage URL
  cnic_back_url TEXT,                     -- Cloudinary or Supabase Storage URL
  selfie_with_cnic_url TEXT,             -- Owner holding CNIC photo

  -- Step 2: Business/Ground Info (first ground)
  business_name VARCHAR(255),
  ground_name VARCHAR(255),
  ground_type ground_type,               -- 'turf' or 'futsal' primarily
  sport_types TEXT[] DEFAULT '{}',       -- ['football', 'cricket', 'futsal']
  city VARCHAR(100),
  full_address TEXT,
  google_maps_link TEXT,                 -- Optional Google Maps URL they paste
  latitude DECIMAL(10,8),
  longitude DECIMAL(11,8),
  operating_hours_from TIME,             -- e.g., 06:00
  operating_hours_to TIME,               -- e.g., 23:00
  price_per_hour DECIMAL(10,2),

  -- Step 3: Documents & Verification
  ground_photos TEXT[] DEFAULT '{}',     -- Min 3 photo URLs required
  utility_bill_url TEXT,                 -- Electricity/gas bill of the ground location
  ownership_proof_url TEXT,             -- Rent agreement or ownership deed
  alternate_contact_phone VARCHAR(20),

  -- Admin verification workflow
  verification_status owner_verification_status DEFAULT 'pending',
  verification_notes TEXT,               -- Admin notes when approving/rejecting
  verified_by UUID REFERENCES users(id), -- Admin user who verified
  verified_at TIMESTAMP,
  rejection_reason TEXT,
  submitted_at TIMESTAMP DEFAULT NOW(),

  -- Meta
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);

-- 7. Update player_profiles with avatar reference
ALTER TABLE player_profiles ADD COLUMN IF NOT EXISTS avatar_url TEXT;

-- 8. Update venues table
ALTER TABLE venues ADD COLUMN IF NOT EXISTS ground_type ground_type;
ALTER TABLE venues ADD COLUMN IF NOT EXISTS venue_photos TEXT[] DEFAULT '{}';
ALTER TABLE venues ADD COLUMN IF NOT EXISTS operating_hours_from TIME;
ALTER TABLE venues ADD COLUMN IF NOT EXISTS operating_hours_to TIME;
ALTER TABLE venues ADD COLUMN IF NOT EXISTS rating DECIMAL(3,2) DEFAULT 0.00;
ALTER TABLE venues ADD COLUMN IF NOT EXISTS total_reviews INT DEFAULT 0;

-- 9. OTP tracking table (for phone verification + password reset)
CREATE TABLE IF NOT EXISTS phone_otp_log (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  phone VARCHAR(20) NOT NULL,
  purpose VARCHAR(20) NOT NULL,         -- 'registration', 'password_reset', 'login'
  firebase_uid TEXT,                    -- Firebase UID after successful verification
  verified BOOLEAN DEFAULT false,
  created_at TIMESTAMP DEFAULT NOW(),
  expires_at TIMESTAMP DEFAULT NOW() + INTERVAL '10 minutes'
);

-- 10. Create index for fast phone OTP lookups
CREATE INDEX IF NOT EXISTS idx_otp_phone_purpose ON phone_otp_log (phone, purpose, verified);

-- 11. Wallets table (ensure exists)
CREATE TABLE IF NOT EXISTS wallets (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID REFERENCES users(id) ON DELETE CASCADE UNIQUE NOT NULL,
  balance DECIMAL(10,2) DEFAULT 0.00,
  currency VARCHAR(10) DEFAULT 'PKR',
  created_at TIMESTAMP DEFAULT NOW()
);
IMPORTANT for the agent: After writing this migration, verify it runs without errors. If tables already have conflicting data that prevents the migration, handle it gracefully.

PART 2 — FIREBASE PHONE AUTH SETUP
Why Firebase Phone Auth

Free up to 10,000 verifications/month
Works in Pakistan (Pakistani numbers: 03XX format)
Flutter SDK is first-class
No backend SMS integration needed — Firebase handles delivery

Setup steps the agent must document/implement:
2.1 Add Firebase to Flutter project
Add to pubspec.yaml dependencies:
yamlfirebase_core: ^3.6.0
firebase_auth: ^5.3.1
2.2 Firebase initialization
In lib/main.dart, add before runApp:
dartawait Firebase.initializeApp(
  options: DefaultFirebaseOptions.currentPlatform, // generated by FlutterFire CLI
);
2.3 Create lib/services/firebase_otp_service.dart:
dartimport 'package:firebase_auth/firebase_auth.dart';

class FirebaseOtpService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  
  String? _verificationId;
  int? _resendToken;

  // Send OTP to Pakistani phone number
  // Phone must be in E.164 format: +923001234567
  Future<void> sendOtp({
    required String phone,        // raw input like '03001234567'
    required Function(String verificationId) onCodeSent,
    required Function(String error) onError,
    required Function(PhoneAuthCredential credential) onAutoVerified,
  }) async {
    // Convert Pakistani format to E.164
    String e164Phone = _toE164(phone);
    
    await _auth.verifyPhoneNumber(
      phoneNumber: e164Phone,
      forceResendingToken: _resendToken,
      verificationCompleted: onAutoVerified,
      verificationFailed: (FirebaseAuthException e) {
        onError(e.message ?? 'Verification failed');
      },
      codeSent: (String verificationId, int? resendToken) {
        _verificationId = verificationId;
        _resendToken = resendToken;
        onCodeSent(verificationId);
      },
      codeAutoRetrievalTimeout: (String verificationId) {
        _verificationId = verificationId;
      },
      timeout: const Duration(seconds: 60),
    );
  }

  // Verify OTP entered by user
  Future<String?> verifyOtp(String smsCode) async {
    if (_verificationId == null) return null;
    try {
      PhoneAuthCredential credential = PhoneAuthProvider.credential(
        verificationId: _verificationId!,
        smsCode: smsCode,
      );
      UserCredential result = await _auth.signInWithCredential(credential);
      // Return Firebase UID as proof of verification
      return result.user?.uid;
    } catch (e) {
      return null;
    }
  }

  // Convert 03001234567 → +923001234567
  String _toE164(String phone) {
    String cleaned = phone.replaceAll(RegExp(r'[\s\-()]'), '');
    if (cleaned.startsWith('0')) {
      return '+92${cleaned.substring(1)}';
    }
    if (cleaned.startsWith('92')) {
      return '+$cleaned';
    }
    return cleaned;
  }
}
2.4 After Firebase OTP verification succeeds, call backend /api/auth/verify-phone endpoint (see Part 3) to mark the phone as verified in PostgreSQL. The Firebase UID is the proof.

PART 3 — BACKEND CHANGES (Node.js / Express)
3.1 Update Registration Routes
File: routes/auth.js — rewrite registration logic:
Player registration now accepts: { name, phone, password, email? }
Owner registration is handled differently — see multi-step below.
javascript// POST /api/auth/register/player
router.post('/register/player', async (req, res) => {
  const { name, phone, password, email, firebaseUid, avatarUrl } = req.body;

  // Validate required fields
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

  // Validate email format if provided
  if (email && email.trim() !== '') {
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    if (!emailRegex.test(email.trim())) {
      return res.status(400).json({ success: false, message: 'Invalid email format' });
    }
  }

  // Check phone not already registered
  const existingPhone = await pool.query('SELECT id FROM users WHERE phone = $1', [phone]);
  if (existingPhone.rows.length > 0) {
    return res.status(409).json({ success: false, message: 'Phone number already registered' });
  }

  // Check email uniqueness if provided
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
       RETURNING id, name, phone, email, role`,
      [name.trim(), phone, emailValue, hashedPassword, avatarUrl || null]
    );
    const user = userResult.rows[0];

    await client.query(
      `INSERT INTO player_profiles (user_id) VALUES ($1)`,
      [user.id]
    );
    await client.query(
      `INSERT INTO wallets (user_id) VALUES ($1)`,
      [user.id]
    );

    await client.query('COMMIT');

    const token = jwt.sign({ id: user.id, role: 'player', phone: user.phone }, process.env.JWT_SECRET, { expiresIn: '30d' });
    return res.status(201).json({ success: true, data: { token, user } });
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
  }
});
Owner registration is MULTI-STEP. Backend receives all steps in one final submission:
javascript// POST /api/auth/register/owner
// This receives the complete owner data after all 3 steps are filled in Flutter
router.post('/register/owner', upload.fields([
  { name: 'cnicFront', maxCount: 1 },
  { name: 'cnicBack', maxCount: 1 },
  { name: 'selfieWithCnic', maxCount: 1 },
  { name: 'groundPhotos', maxCount: 6 },
  { name: 'utilityBill', maxCount: 1 },
  { name: 'ownershipProof', maxCount: 1 }
]), async (req, res) => {
  const {
    // Step 1 - Personal
    name, phone, password, email, firebaseUid,
    cnicNumber,
    // Step 2 - Ground  
    businessName, groundName, groundType, sportTypes,
    city, fullAddress, googleMapsLink,
    latitude, longitude, operatingHoursFrom, operatingHoursTo, pricePerHour,
    // Step 3 - Contacts
    alternateContactPhone
  } = req.body;

  // Validate firebaseUid (phone was verified)
  if (!firebaseUid) {
    return res.status(400).json({ success: false, message: 'Phone verification required' });
  }

  // Validate CNIC format: 13 digits, stored as XXXXX-XXXXXXX-X
  const cnicClean = cnicNumber?.replace(/-/g, '');
  if (!cnicClean || cnicClean.length !== 13 || !/^\d{13}$/.test(cnicClean)) {
    return res.status(400).json({ success: false, message: 'Invalid CNIC. Must be 13 digits.' });
  }

  // Require minimum 3 ground photos
  if (!req.files['groundPhotos'] || req.files['groundPhotos'].length < 3) {
    return res.status(400).json({ success: false, message: 'At least 3 ground photos required' });
  }

  // Upload files to Supabase Storage or Cloudinary (implement uploadFile helper)
  // ... file upload logic ...

  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    const hashedPassword = await bcrypt.hash(password, 12);
    const emailValue = (email && email.trim() !== '') ? email.trim() : null;

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
      [user.id, name.trim(), cnicNumber, cnicFrontUrl, cnicBackUrl,
       selfieUrl, businessName, groundName, groundType,
       JSON.parse(sportTypes), city, fullAddress, googleMapsLink,
       latitude, longitude, operatingHoursFrom, operatingHoursTo, pricePerHour,
       groundPhotoUrls, utilityBillUrl, ownershipProofUrl, alternateContactPhone]
    );

    await client.query(`INSERT INTO wallets (user_id) VALUES ($1)`, [user.id]);
    await client.query('COMMIT');

    const token = jwt.sign({ id: user.id, role: 'owner', phone: user.phone, verified: false }, process.env.JWT_SECRET, { expiresIn: '30d' });
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
});
3.2 Phone Verification Endpoint
javascript// POST /api/auth/verify-phone
// Called after Firebase OTP success to check phone is valid before registration
router.post('/verify-phone', async (req, res) => {
  const { phone } = req.body;
  // Firebase already verified. Just return success.
  // Optionally: log it in phone_otp_log
  return res.json({ success: true, message: 'Phone verified' });
});
3.3 Forgot Password via SMS OTP
javascript// POST /api/auth/forgot-password/send-otp
router.post('/forgot-password/send-otp', async (req, res) => {
  const { phone } = req.body;
  const user = await pool.query('SELECT id FROM users WHERE phone = $1', [phone]);
  if (user.rows.length === 0) {
    return res.status(404).json({ success: false, message: 'No account found with this phone number' });
  }
  // Tell Flutter to trigger Firebase OTP for this phone
  return res.json({ success: true, message: 'Proceed with Firebase OTP verification' });
});

// POST /api/auth/forgot-password/reset
router.post('/forgot-password/reset', async (req, res) => {
  const { phone, newPassword, firebaseUid } = req.body;
  // firebaseUid proves the OTP was verified
  if (!firebaseUid) {
    return res.status(400).json({ success: false, message: 'OTP verification required' });
  }
  if (!newPassword || newPassword.length < 8) {
    return res.status(400).json({ success: false, message: 'Password must be at least 8 characters' });
  }
  const hashed = await bcrypt.hash(newPassword, 12);
  await pool.query('UPDATE users SET password_hash = $1 WHERE phone = $2', [hashed, phone]);
  return res.json({ success: true, message: 'Password reset successful' });
});
3.4 Login — role-agnostic (one endpoint for both Player and Owner)
javascript// POST /api/auth/login
// Accepts phone OR email
router.post('/login', async (req, res) => {
  const { identifier, password } = req.body; // identifier = phone or email

  let userResult;
  // Determine if identifier is phone or email
  const isPhone = /^0[0-9]{10}$/.test(identifier.replace(/\s/g, ''));
  if (isPhone) {
    userResult = await pool.query('SELECT * FROM users WHERE phone = $1', [identifier.replace(/\s/g, '')]);
  } else {
    userResult = await pool.query('SELECT * FROM users WHERE email = $1', [identifier.toLowerCase()]);
  }

  if (userResult.rows.length === 0) {
    return res.status(401).json({ success: false, message: 'No account found with this phone/email' });
  }
  const user = userResult.rows[0];

  if (!user.is_active) {
    return res.status(403).json({ success: false, message: 'Account suspended. Contact support.' });
  }

  // Check owner verification status
  if (user.role === 'owner') {
    const ownerProfile = await pool.query(
      'SELECT verification_status FROM owner_profiles WHERE user_id = $1', [user.id]
    );
    if (ownerProfile.rows.length > 0 && ownerProfile.rows[0].verification_status === 'pending') {
      return res.status(403).json({
        success: false,
        message: 'Your owner account is under review. You will be notified once approved.',
        status: 'pending'
      });
    }
    if (ownerProfile.rows.length > 0 && ownerProfile.rows[0].verification_status === 'rejected') {
      const profile = ownerProfile.rows[0];
      return res.status(403).json({
        success: false,
        message: `Account rejected: ${profile.rejection_reason || 'Contact support'}`,
        status: 'rejected'
      });
    }
  }

  const passwordMatch = await bcrypt.compare(password, user.password_hash);
  if (!passwordMatch) {
    return res.status(401).json({ success: false, message: 'Incorrect password' });
  }

  const token = jwt.sign({ id: user.id, role: user.role, phone: user.phone }, process.env.JWT_SECRET, { expiresIn: '30d' });
  return res.json({
    success: true,
    data: {
      token,
      user: { id: user.id, name: user.name, phone: user.phone, email: user.email, role: user.role, avatarUrl: user.avatar_url }
    }
  });
});

PART 4 — FLUTTER: COMPLETE AUTH UI REDESIGN
Delete these existing files and rewrite from scratch:

lib/screens/auth/welcome_screen.dart
lib/screens/auth/login_screen.dart
lib/screens/auth/register_screen.dart

Create new files:

lib/screens/auth/player_register_screen.dart
lib/screens/auth/owner_register_screen.dart (multi-step)
lib/screens/auth/otp_screen.dart
lib/screens/auth/forgot_password_screen.dart
lib/widgets/password_strength_bar.dart
lib/widgets/phone_field.dart
lib/services/firebase_otp_service.dart (see Part 2)


4.1 Design System — Add to lib/constants/colors.dart
dartclass AppColors {
  static const Color primary = Color(0xFF0A1F13);
  static const Color accent = Color(0xFF22C55E);
  static const Color accentLight = Color(0xFFDCFCE7);
  static const Color background = Color(0xFFF8FAFC);
  static const Color cardBg = Color(0xFFFFFFFF);
  static const Color inputFill = Color(0xFFF1F5F9);
  static const Color textPrimary = Color(0xFF111827);
  static const Color textSecondary = Color(0xFF6B7280);
  static const Color error = Color(0xFFDC2626);
  static const Color warning = Color(0xFFF59E0B);
  static const Color disabled = Color(0xFFD1D5DB);
  static const Color border = Color(0xFFE5E7EB);
  static const Color success = Color(0xFF16A34A);
}
4.2 Reusable Input Widget — lib/widgets/sport_text_field.dart
dartclass SportTextField extends StatelessWidget {
  final String hint;
  final IconData prefixIcon;
  final bool obscure;
  final TextEditingController controller;
  final String? Function(String?)? validator;
  final TextInputType keyboardType;
  final Widget? suffix;
  final int maxLines;
  final bool enabled;

  // Full implementation:
  // - Container with fill color AppColors.inputFill
  // - Border radius 12
  // - On focus: border 1.5px AppColors.accent
  // - On error: border 1.5px AppColors.error
  // - prefix icon in AppColors.textSecondary
  // - Poppins font
  // - Error text below in red, 12sp
}
4.3 Welcome Screen — lib/screens/auth/welcome_screen.dart
Layout (inspired by JazzCash/SadaPay welcome pattern):
Scaffold(backgroundColor: AppColors.background)
│
├── Stack
│   ├── Background: full screen dark green gradient
│   │   LinearGradient: #0A1F13 → #1A3A25 (diagonal 135°)
│   │
│   └── Column (main content)
│       ├── Expanded (top section — dark green)
│       │   └── Center > Column
│       │       ├── SportLynk logo image (CircleAvatar, radius 52, white border 2px)
│       │       ├── SizedBox(16)
│       │       ├── RichText: 'Sport' white Poppins bold 36 + 'Lynk' accent bold 36
│       │       └── Text 'Book. Play. Compete.' white opacity:0.7 16sp
│       │
│       └── Bottom sheet (white, borderRadius top 32)
│           Padding(24, horizontal; 32, top; 48, bottom)
│           Column:
│           ├── Text 'Get Started' textPrimary bold 22
│           ├── Text 'Join Pakistan\'s sports community' textSecondary 14
│           ├── SizedBox(32)
│           ├── ElevatedButton.icon 'I am a Player'
│           │   Icon: sports_soccer. Full width. accent bg. radius 28. height 56.
│           │   → Navigator.pushNamed('/register/player')
│           ├── SizedBox(12)
│           ├── OutlinedButton.icon 'I am a Venue Owner'  
│           │   Icon: store. Full width. accent border. accent text. radius 28. height 56.
│           │   → Navigator.pushNamed('/register/owner')
│           ├── SizedBox(24)
│           └── Center: TextButton 'Already have an account? ' + bold accent 'Log In'
│               → Navigator.pushNamed('/login')
4.4 Login Screen — lib/screens/auth/login_screen.dart
One login screen. No role toggle needed. Backend determines role from credentials.
Scaffold(backgroundColor: AppColors.background)
│
├── Stack
│   ├── Top curved header (dark green, height: 220)
│   │   Container + ClipPath (curved bottom edge)
│   │   │ Linear gradient #0A1F13 → #166534
│   │   └── Column centered:
│   │       ├── Back arrow (white) top-left in SafeArea
│   │       ├── Logo image (radius 36)
│   │       ├── 'SportLynk' white bold 24
│   │       └── 'Book. Play. Compete.' white opacity:0.7 13sp
│   │
│   └── Positioned(top: 180) white card:
│       Container(white, borderRadius top 28, shadow subtle)
│       SingleChildScrollView > Padding(24)
│       │
│       ├── Text 'Welcome Back' textPrimary bold 24
│       ├── Text 'Sign in to continue booking venues' textSecondary 14
│       ├── SizedBox(28)
│       ├── SportTextField(hint:'Phone or Email', icon: phone_android, controller: identifierCtrl)
│       │   Validator: must not be empty. If contains @ then check email format.
│       │   If no @, check Pakistani phone: starts with 03, 11 digits.
│       ├── SizedBox(16)
│       ├── SportTextField(hint:'Password', icon: lock_outline, obscure: true,
│       │   suffix: IconButton eye toggle, controller: passwordCtrl)
│       │   Validator: must not be empty
│       ├── Align(right): TextButton 'Forgot Password?' accent color
│       │   → Navigator.pushNamed('/forgot-password')
│       ├── SizedBox(28)
│       ├── Consumer<AuthProvider>: CustomButton 'Log In' isLoading:isLoading
│       │   Full width. height 56. accent. radius 28.
│       │   On tap: validate → authProvider.login(identifier, password)
│       │   On success: pushNamedAndRemoveUntil to correct home by role
│       │   On fail: SnackBar with error message (show specific message from backend)
│       ├── SizedBox(24)
│       └── Center: 'Don\'t have an account? ' grey + bold accent 'Sign Up'
│           → Navigator.pushNamed('/welcome')
4.5 Player Registration — lib/screens/auth/player_register_screen.dart
Single screen (not multi-step — player registration is simple).
AppBar: 'Create Account' primary bg, white back arrow + title

Body: SingleChildScrollView > Padding(horizontal:24, top:16)

Column:
├── Center: GestureDetector avatar picker
│   Stack:
│   ├── CircleAvatar(radius: 48, bg: accentLight)
│   │   if avatarFile != null: Image.file | else: Icon(person, 48, accent)
│   └── Positioned(bottom:0, right:0): CircleAvatar(radius:16, bg:accent)
│       Icon(camera_alt, 16, white)
│   On tap: ImagePicker().pickImage(source: gallery/camera dialog)
│   Below: Text 'Add Photo (optional)' textSecondary 12 center
│
├── SizedBox(24)
├── Text 'Player Account' in a Chip (accentLight bg, accent text, icon sports)
├── SizedBox(20)
│
├── SportTextField(hint:'Full Name *', icon:person_outline, ctrl:nameCtrl)
│   Validator:
│   - Required
│   - Min 3 characters: 'Name must be at least 3 characters'
│   - Max 50 characters
│   - Only letters and spaces: 'Name can only contain letters and spaces'
│   - No leading/trailing spaces (trim before validate)
│
├── SizedBox(16)
├── PhoneField widget (see 4.8 below)
│   Required. Pakistani format. Shows 'Verify' button → triggers OTP flow
│   Phone must be verified before registration proceeds.
│   Show green checkmark + 'Verified ✓' when done.
│
├── SizedBox(16)
├── SportTextField(hint:'Email (optional)', icon:mail_outline, ctrl:emailCtrl)
│   keyboardType: emailAddress
│   Validator:
│   - If empty: pass (null = valid)
│   - If not empty: must contain @ and valid domain
│   - 'Invalid email format'
│
├── SizedBox(16)
├── PasswordField with real-time strength bar (see 4.9 below)
│   Validator:
│   - Required
│   - Min 8 characters
│   - Must contain uppercase letter
│   - Must contain lowercase letter
│   - Must contain at least one number
│   - Must contain at least one special character (!@#$%^&*)
│   Show these requirements as checklist below field, turning green as met.
│
├── SizedBox(16)
├── SportTextField(hint:'Confirm Password *', icon:lock_outline, obscure:true)
│   Validator:
│   - Required
│   - Must match password field
│   - 'Passwords do not match'
│
├── SizedBox(32)
├── Consumer<AuthProvider>: CustomButton 'Create Account'
│   DISABLED if phone not verified (show tooltip 'Verify phone first')
│   On tap:
│   1. Validate form
│   2. Check phone is verified (firebaseUid is not null)
│   3. authProvider.registerPlayer(name, phone, password, email?, firebaseUid, avatarUrl?)
│   4. On success → pushNamedAndRemoveUntil('/player-home')
│   5. On fail → SnackBar with specific backend error
│
└── TextButton 'Already have account? Login' → '/login'
4.6 Owner Registration — lib/screens/auth/owner_register_screen.dart
Multi-step (3 steps). Like the Teacher Registration reference image.
State: int _currentStep = 0 (0, 1, 2)
Progress indicator at top: Stepper with 3 nodes connected by lines.

Step 1: Personal (person icon)
Step 2: Ground Details (location_on icon)
Step 3: Documents (folder icon)

STEP 1 — Personal Information
AppBar: 'Owner Registration' (show current step 1/3 in subtitle)

Column:
├── StepProgressIndicator (custom widget, 3 steps, accent color for completed)
├── SizedBox(24)
├── Text 'Personal Information' bold 20
├── Text 'Let\'s verify your identity' textSecondary 14
├── SizedBox(24)
│
├── Center: Avatar picker (same as player, but label 'Add Your Photo')
│
├── SportTextField 'Full Name *' — same strict validators as player
├── SizedBox(16)
├── PhoneField — same as player, must verify via OTP before step 2
│   Phone is the primary identifier.
├── SizedBox(16)
├── SportTextField 'Email (optional)' — same optional validator
├── SizedBox(16)
├── PasswordField with strength bar
├── SizedBox(16)
├── SportTextField 'Confirm Password *' — match validator
├── SizedBox(16)
├── SportTextField 'CNIC Number *' (hint: '3XXXXX-XXXXXXX-X')
│   keyboardType: number with auto-formatting (add dashes automatically)
│   Validator:
│   - Required
│   - Strip dashes → must be exactly 13 digits
│   - First 5 digits: district code (not all zeros)
│   - Must match format: XXXXX-XXXXXXX-X
│   Helper text: 'Your CNIC is used for identity verification only'
│
├── SizedBox(32)
└── CustomButton 'Continue →'
    On tap: validate → if phone verified → setState(_currentStep = 1)
    If phone not verified: show error 'Please verify your phone number first'
STEP 2 — Ground Details
Column:
├── StepProgressIndicator (step 2 active)
├── SizedBox(24)
├── Text 'Your Ground' bold 20
├── Text 'Tell us about the venue you manage' textSecondary 14
├── SizedBox(24)
│
├── SportTextField 'Business / Ground Name *'
│   Validator: required, min 3 chars
│
├── SizedBox(16)
├── Text 'Ground Type *' textPrimary bold 14
├── SizedBox(8)
├── Row of 2 selection chips: [Turf] [Futsal]
│   Toggle chips. At least one required.
│   Selected: accent bg white text. Unselected: inputFill bg textSecondary.
│   Design: width each ~140, height 48, radius 12, icon + text
│
├── SizedBox(16)
├── Text 'Sports Offered *' textPrimary bold 14
├── SizedBox(8)
├── Wrap of multi-select chips: [Football] [Cricket] [Badminton] [Basketball] [Futsal]
│   At least 1 required.
│
├── SizedBox(16)
├── DropdownButtonFormField 'City *'
│   Options: Islamabad, Rawalpindi, Lahore, Karachi, Peshawar, Quetta, Multan, Faisalabad
│   Validator: required
│
├── SizedBox(16)
├── SportTextField 'Full Address *' (maxLines:2)
│   Validator: required, min 10 chars
│
├── SizedBox(16)
├── SportTextField 'Google Maps Link (optional)'
│   hint: 'Paste Google Maps URL'
│   Validator: if not empty, must start with 'https://maps.google' or 'https://goo.gl'
│   Helper: 'Open Google Maps → Share → Copy link → Paste here'
│
├── SizedBox(16)
├── Row:
│   ├── Expanded: SportTextField 'Opens at *' (hint: '06:00')
│   │   keyboardType: datetime. Tap: showTimePicker
│   └── SizedBox(12)
│   └── Expanded: SportTextField 'Closes at *' (hint: '23:00')
│
├── SizedBox(16)
├── SportTextField 'Price per Hour (PKR) *'
│   keyboardType: number
│   Validator: required, must be a number > 0, reasonable range 500-50000
│
├── SizedBox(16)
├── SportTextField 'Alternate Contact Phone (optional)'
│   Validator: if not empty, same Pakistani phone format check
│
├── SizedBox(32)
├── Row:
│   ├── OutlinedButton '← Back' → setState(_currentStep = 0)
│   └── SizedBox(12)
│   └── Expanded: CustomButton 'Continue →' → validate → setState(_currentStep = 2)
STEP 3 — Documents & Verification
Column:
├── StepProgressIndicator (step 3 active)
├── SizedBox(24)
├── Text 'Verification Documents' bold 20
├── Text 'Required for trust & safety. Admin reviews within 24-48 hours.' textSecondary 14
├── SizedBox(8)
├── Container(accentLight, borderRadius:8, padding:12)
│   Row: Icon(info_outline, accent, 18) + SizedBox(8)
│   Text 'All documents are encrypted and only viewed by SportLynk admins.'
│
├── SizedBox(24)
│
├── Text 'CNIC Photos *' bold 14
├── Text 'Take clear photos in good lighting' textSecondary 12
├── SizedBox(8)
├── Row:
│   ├── _DocumentPicker(label:'CNIC Front', icon:credit_card, required:true, onPicked: ...)
│   └── SizedBox(12)
│   └── _DocumentPicker(label:'CNIC Back', icon:credit_card_back, required:true, onPicked: ...)
│   Each _DocumentPicker: dashed border container 120x90, tap to pick from gallery
│   Shows thumbnail when selected, green border + checkmark
│
├── SizedBox(16)
├── _DocumentPicker(label:'Selfie with CNIC *', icon:face, required:true, fullWidth:true)
│   Helper: 'Hold your CNIC next to your face and take a photo'
│
├── SizedBox(20)
├── Text 'Ground Photos *' bold 14
├── Text 'Minimum 3 photos (field, entrance, facilities)' textSecondary 12
├── SizedBox(8)
├── GridView 3-column photo picker:
│   - Each slot: dashed border 100x100 container with '+' icon
│   - When photo selected: shows thumbnail, red X to remove
│   - Show count: '3/6 photos added' in accent color
│   - Minimum 3 required validation
│
├── SizedBox(16)
├── _DocumentPicker(label:'Utility Bill (optional)', hint:'Electricity/gas bill of the ground')
│
├── SizedBox(16)
├── _DocumentPicker(label:'Ownership/Rent Proof (optional)', hint:'Ownership deed or rent agreement')
│
├── SizedBox(24)
├── Container(color:Color(0xFFFEF3C7), borderRadius:8, padding:12)  
│   Row: Icon(warning_amber_outlined, warning, 18)
│   Text 'Your account will be reviewed. You cannot list venues until approved.'
│
├── SizedBox(32)
├── Row:
│   ├── OutlinedButton '← Back'
│   └── SizedBox(12)
│   └── Expanded: Consumer<AuthProvider>: CustomButton 'Submit Application'
│       isLoading:isLoading
│       On tap:
│       1. Validate: CNIC front, CNIC back, selfie, min 3 ground photos
│       2. Upload all files (show upload progress)
│       3. authProvider.registerOwner(allData)
│       4. On success → show OwnerPendingScreen (NOT owner home)
│       5. On fail → SnackBar with error
Owner Pending Screen — lib/screens/auth/owner_pending_screen.dart
Show AFTER successful owner registration. No bottom nav.

Scaffold(bg: AppColors.background)
SafeArea > Center > Padding(32)
Column center:
├── Lottie animation or Icon(pending_actions, size:100, color:accent) with spin animation
├── SizedBox(24)
├── Text 'Application Submitted!' bold 24 center
├── SizedBox(12)
├── Text 'Our team will review your documents within 24-48 hours. 
│    You\'ll receive an SMS notification once approved.'
│   textSecondary center
├── SizedBox(32)
├── Card(borderRadius:16, border:accentLight):
│   ListTile icon+text for each:
│   ✓ Identity verification (CNIC)
│   ✓ Ground details submitted  
│   ✓ Photos received
│   ⏳ Admin review (in progress)
│   ⏳ Account activation
├── SizedBox(40)
└── TextButton 'Back to Home' → pushNamedAndRemoveUntil('/welcome')
4.7 OTP Screen — lib/screens/auth/otp_screen.dart
Receives: String phone (passed via route arguments)

Scaffold(bg:background)
AppBar: 'Verify Phone' primary

Center > Padding(24) Column:
├── Icon(sms, size:72, color:accent) with gentle scale animation
├── SizedBox(24)
├── Text 'Enter OTP' bold 24
├── Text 'Code sent to +92-XXX-XXXXXXX' textSecondary 14
│   (mask middle digits for privacy)
├── SizedBox(32)
│
├── OTP input: Row of 6 individual digit boxes
│   Each box: Container(48x56, fill:inputFill, borderRadius:12)
│   On focus: accent border. On filled: primary border.
│   Auto-advance to next box on digit entry.
│   Auto-submit when all 6 filled.
│   Use: pin_code_fields package OR build manually with 6 TextFields
│
├── SizedBox(32)
├── CustomButton 'Verify Code' isLoading:isLoading
│   On tap: firebaseOtpService.verifyOtp(enteredCode)
│   On success: pop with result (firebaseUid) back to register screen
│   On fail: SnackBar 'Invalid or expired code'
│
├── SizedBox(16)
├── CountdownTimer widget:
│   Show 'Resend code in 0:45' countdown
│   After 0: show TextButton 'Resend OTP'
│   On resend: call firebaseOtpService.sendOtp again
│
└── TextButton 'Change Phone Number' → pop
4.8 Phone Field Widget — lib/widgets/phone_field.dart
dart// PhoneField is a custom widget that combines the input + verify button
// Props: controller, onVerified(String firebaseUid), bool isVerified

// Layout: Column
//   Row:
//     Expanded: SportTextField('Phone Number *', icon:phone_android, ctrl:ctrl)
//       keyboardType: phone
//       inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(11)]
//     SizedBox(8)
//     if !isVerified:
//       ElevatedButton('Verify', onPressed: _sendOtp, accent bg, radius 8, height 56)
//     if isVerified:
//       Container(accent, radius:8, padding:8x12): Icon(check_circle, white) + Text('Verified', white 12)
//
// Validator on the text field:
//   - Required
//   - Must be exactly 11 digits
//   - Must start with '03' (Pakistani mobile)
//   - Valid prefixes: 030, 031, 032, 033, 034, 035, 036 (Zong, Jazz, Telenor, Ufone, Warid, SCO)
//   - Error: 'Enter valid Pakistani mobile number (03XX-XXXXXXX)'
//
// _sendOtp():
//   1. Validate phone field (show error if invalid)
//   2. Navigator.pushNamed('/otp', arguments: phone)
//   3. On return: if firebaseUid != null → setState isVerified=true, call onVerified(uid)
4.9 Password Strength Bar — lib/widgets/password_strength_bar.dart
dart// Real-time password strength indicator
// Props: String password (from controller, listen in parent with addListener)

// Strength scoring:
// length >= 8: +1
// contains uppercase: +1  
// contains lowercase: +1
// contains digit: +1
// contains special char (!@#$%^&*): +1
// length >= 12: +1 bonus

// Score → Level:
// 0-1: Weak (error red)
// 2-3: Fair (warning amber)
// 4-5: Good (accent green)
// 6: Strong (success dark green)

// Widget layout:
// Column:
//   AnimatedContainer bar (full width, height 4, borderRadius 2)
//     animated width = score/6 * maxWidth
//     animated color = level color
//   SizedBox(8)
//   Row: requirement chips (turn green when met)
//     [8+ chars] [A-Z] [a-z] [0-9] [!@#]
//     Each chip: small pill, grey when not met, green check when met
//     Animate with AnimatedDefaultTextStyle
4.10 Forgot Password — lib/screens/auth/forgot_password_screen.dart
Step 1 — Enter phone number
  SportTextField 'Phone Number' + CustomButton 'Send OTP'
  On tap: POST /api/auth/forgot-password/send-otp
  On success: trigger Firebase OTP → navigate to OTP screen

Step 2 — OTP verified (returned from OTP screen with firebaseUid)

Step 3 — Enter new password
  PasswordField with strength bar
  Confirm Password field
  CustomButton 'Reset Password'
  On tap: POST /api/auth/forgot-password/reset {phone, newPassword, firebaseUid}
  On success: SnackBar 'Password changed!' → pop to login

PART 5 — AUTH PROVIDER UPDATES
Update lib/providers/auth_provider.dart:
dart// Add these methods:

Future<bool> registerPlayer({
  required String name,
  required String phone,
  required String password,
  String? email,
  required String firebaseUid,
  String? avatarUrl,
}) async { ... }

Future<bool> registerOwner(Map<String, dynamic> data) async { ... }
// data contains all step 1+2+3 fields + file URLs after upload

Future<void> sendForgotPasswordOtp(String phone) async { ... }

Future<bool> resetPassword({
  required String phone,
  required String newPassword,
  required String firebaseUid,
}) async { ... }

// Update login method signature:
Future<bool> login(String identifier, String password) async {
  // identifier = phone or email
  // Send to POST /api/auth/login as { identifier, password }
  // Handle specific error codes:
  // - 'pending' status → set pendingStatus = true, return false
  // - 'rejected' status → show rejection reason
}

// Add state:
bool isPendingOwner = false;  // show pending screen
String? ownerRejectionReason;

PART 6 — ROUTE UPDATES
Update lib/main.dart routes:
dartroutes: {
  '/welcome': (_) => WelcomeScreen(),
  '/login': (_) => LoginScreen(),
  '/register/player': (_) => PlayerRegisterScreen(),
  '/register/owner': (_) => OwnerRegisterScreen(),
  '/otp': (_) => OtpScreen(),
  '/forgot-password': (_) => ForgotPasswordScreen(),
  '/owner-pending': (_) => OwnerPendingScreen(),
  '/player-home': (_) => PlayerHomeScreen(),
  '/owner-home': (_) => OwnerHomeScreen(),
}

PART 7 — ANTI-SCAM ARCHITECTURE (implement or document)
What you must build NOW (for committee demo):

✅ CNIC photo collection in owner registration
✅ Admin verification workflow (pending → approved/rejected)
✅ Owner cannot access venue management until verification_status = 'approved'
✅ Phone OTP prevents fake account creation (one phone = one account)
✅ Player trust score in player_profiles (starts at 100, decrements on no-shows)

What admin will do (future admin panel):

View submitted owner applications with all documents
Click Approve → update verification_status = 'approved' → owner gets SMS
Click Reject → add rejection reason → owner gets SMS with reason
Suspend users who abuse platform (is_active = false)

Loophole mitigations already built in:

Phone uniqueness: one phone = one account system-wide
CNIC number uniqueness: add UNIQUE constraint to owner_profiles.cnic_number so same CNIC cannot register two owner accounts
Image review: admin manually checks CNIC photos match selfie (like Careem/InDrive)
Utility bill or ownership proof: proves physical connection to the ground location
Ground photos: minimum 3 required so fake grounds with stock photos are detectable

Additional constraint to add to schema:
sqlALTER TABLE owner_profiles ADD CONSTRAINT owner_cnic_unique UNIQUE (cnic_number);

PART 8 — EXECUTION ORDER FOR AGENT
Execute in this exact order:

Run schema migration SQL (Part 1) — verify no errors
Add Firebase to pubspec.yaml and run flutter pub get
Set up Firebase project (document steps — agent cannot do Firebase console, give developer exact instructions)
Create lib/services/firebase_otp_service.dart (Part 2)
Update backend auth routes (Part 3) — routes/auth.js
Create lib/constants/colors.dart (updated)
Create lib/widgets/sport_text_field.dart
Create lib/widgets/password_strength_bar.dart (Part 4.9)
Create lib/widgets/phone_field.dart (Part 4.8)
Rewrite lib/screens/auth/welcome_screen.dart (Part 4.3)
Rewrite lib/screens/auth/login_screen.dart (Part 4.4)
Create lib/screens/auth/player_register_screen.dart (Part 4.5)
Create lib/screens/auth/owner_register_screen.dart (Part 4.6)
Create lib/screens/auth/otp_screen.dart (Part 4.7)
Create lib/screens/auth/owner_pending_screen.dart (Part 4.6 pending)
Create lib/screens/auth/forgot_password_screen.dart (Part 4.10)
Update lib/providers/auth_provider.dart (Part 5)
Update lib/main.dart routes (Part 6)
Verify the app compiles — fix any import errors
Run backend — verify all new endpoints return correct responses


CRITICAL REMINDERS FOR AGENT

NEVER leave // TODO or // implement later anywhere. Every field must have a working validator.
NEVER generate placeholder UI — every screen must be fully implemented.
ALL text must use Poppins font via GoogleFonts.poppins()
ALL colors must come from AppColors constants — no hex literals in widgets
Phone numbers stored in DB must always be in 03XXXXXXXXX format (11 digits, no spaces)
Before every backend change, check if the Express route handler imports match what's in the file
The owner registration screen collects files — use image_picker package for photo selection and implement upload to Supabase Storage OR store locally as file paths for now with a TODO comment for upload
Do NOT change the existing venue listing, booking, or owner home screens — ONLY touch auth
Test each screen compiles before moving to the next


End of prompt. Agent should now execute all parts autonomously.