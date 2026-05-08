SportLynk Auth Overhaul — Implementation Plan
Complete overhaul of the auth system: database schema, backend API, and Flutter UI, as specified in prompt.md.

User Review Required
IMPORTANT

Firebase Phone Auth requires manual Firebase Console setup. I cannot create a Firebase project for you. After I implement the code, you will need to:

Go to Firebase Console → Create a project called "SportLynk"
Add an Android app (package: com.example.sportlynk)
Download google-services.json → place in android/app/
Enable Phone Authentication in Firebase Console → Authentication → Sign-in method
Run flutterfire configure to generate firebase_options.dart
Until Firebase is configured, OTP will be simulated with a mock service that auto-verifies (returns a dummy Firebase UID). This lets you demo the full flow to the committee. When Firebase is configured, just swap the mock with the real service — zero code changes needed.

WARNING

Supabase Storage is not required right now. File pickers will store local file paths until cloud storage is configured.

Open Questions — Resolved
- image_picker package: confirmed OK
- Wallet initial balance: set to 0.00 for new registrations
- Existing seeded users: mark as phone_verified for a professional DB state
Proposed Changes
Part 1 — Database Migration
[NEW] 
migration_v2.sql
Make email nullable with partial unique index
Add phone_verified, avatar_url to users
Make phone NOT NULL + UNIQUE
Create owner_verification_status and ground_type ENUMs
Drop and recreate owner_profiles with all 25+ fields (CNIC, ground, verification workflow)
Add avatar_url to player_profiles
Add ground_type, venue_photos, operating_hours, rating to venues
Create phone_otp_log table
Ensure wallets table exists
Add owner_cnic_unique constraint
Part 2 — Backend Auth Rewrite
[MODIFY] 
auth.js
Add routes: POST /register/player, POST /register/owner, POST /verify-phone, POST /forgot-password/send-otp, POST /forgot-password/reset
Keep existing GET /me route
Old POST /register and POST /login replaced
[MODIFY] 
authController.js
Complete rewrite with:

registerPlayer — validates name/phone/password/firebaseUid, checks phone uniqueness, creates user+player_profile+wallet in transaction
registerOwner — validates all 3-step data, accepts JSON body (file URLs), creates user+owner_profile+wallet, returns status: 'pending'
login — accepts identifier (phone OR email), checks owner verification status (pending/rejected blocks login), 30d JWT
verifyPhone — logs verification
forgotPasswordSendOtp — checks phone exists
forgotPasswordReset — resets password with firebaseUid proof
getMe — updated to return avatar_url and phone
[MODIFY] 
authMiddleware.js
Add phone to decoded JWT payload extraction
Part 3 — Flutter Dependencies
[MODIFY] 
pubspec.yaml
Add firebase_core, firebase_auth, image_picker
Keep all existing deps
Part 4 — Flutter Constants & Widgets
[MODIFY] 
colors.dart
Add: inputFill, warning, border, success
Update: background (#F8FAFC), cardBg (#FFFFFF)
[NEW] 
sport_text_field.dart
Reusable input with inputFill background, radius 12, accent focus border, error border, Poppins font
[NEW] 
password_strength_bar.dart
Real-time strength scoring (6 criteria), animated bar, requirement chips that turn green
[NEW] 
phone_field.dart
Phone input + Verify button, Pakistani format validation (03XX), green checkmark when verified
Part 5 — Flutter Services
[NEW] 
firebase_otp_service.dart
Mock service initially (auto-verifies for demo), with real Firebase implementation ready
sendOtp(), verifyOtp(), _toE164() conversion
Part 6 — Flutter Auth Screens (6 screens)
[MODIFY] 
welcome_screen.dart
Full rewrite: dark green gradient top + white bottom sheet with "I am a Player" / "I am a Venue Owner" buttons, radius 28
[MODIFY] 
login_screen.dart
Full rewrite: curved dark green header + white card body, phone/email identifier field, forgot password link
[DELETE] 
register_screen.dart
Replaced by separate player and owner registration screens
[NEW] 
player_register_screen.dart
Avatar picker, name/phone/email/password fields, PhoneField with OTP verification, password strength bar, confirm password
[NEW] 
owner_register_screen.dart
3-step form: Personal Info → Ground Details → Documents
Step progress indicator, CNIC field with auto-formatting, ground type chips, sport chips, city dropdown, time pickers, document pickers, photo grid
[NEW] 
otp_screen.dart
6-digit OTP input boxes, auto-advance, countdown timer, resend button
[NEW] 
owner_pending_screen.dart
Status checklist (✓ CNIC, ✓ Ground, ✓ Photos, ⏳ Review, ⏳ Activation)
[NEW] 
forgot_password_screen.dart
3-step: enter phone → OTP verify → set new password
Part 7 — Provider & Main Updates
[MODIFY] 
auth_provider.dart
Add: registerPlayer(), registerOwner(), sendForgotPasswordOtp(), resetPassword()
Update: login() to send identifier instead of email, handle pending/rejected owner status
Add state: isPendingOwner, ownerRejectionReason
[MODIFY] 
main.dart
Update routes: /register/player, /register/owner, /otp, /forgot-password, /owner-pending
Remove old /register route
[MODIFY] 
auth_wrapper.dart
Handle pending owner status in auth flow
Verification Plan
Automated Tests
flutter analyze — zero errors/warnings
Backend restart — verify all new endpoints respond correctly via curl
Full compilation check on all 20+ files
Manual Verification
User registers as Player → lands on PlayerHomeScreen
User registers as Owner → goes through 3-step form → lands on OwnerPendingScreen
Login with phone OR email works
Wrong password shows specific error
Pending owner login shows "under review" message
Forgot password flow works end-to-end
All validators fire correctly (empty fields, invalid phone, weak password, etc.)