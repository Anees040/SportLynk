# SportLynk FYP

## Overview
Flutter mobile app for sports venue booking in Pakistan.
Players find and book sports grounds. Owners manage facilities.
**Current Status:** Phase 4 (Player Interface, Dynamic Slots, & Escrow Logic) Complete. Ready for Phase 5 (Owner Interface).
## Team
- Mudassar Akram (SP23-BSE-028)
- Muhammad Anees (SP23-BSE-030)
- Supervisor: Miss Ayesha Hussain | COMSATS University Islamabad

## Tech Stack
- Mobile: Flutter (Dart) — Android
- Backend: Node.js + Express.js
- Local DB: PostgreSQL 16 (localhost:5432/sportlynk, user: postgres, pass: sportlynk123)
- Cloud DB: Supabase (PostgreSQL — same schema as local)
- Auth: JWT (HS256, 24h expiry) + bcrypt (cost 12)
- State: Provider pattern
- SMS/OTP: Firebase Authentication
- Storage: Cloudinary (Avatars & Venue Images)

## Colors
Primary: #0A1F13 | Accent: #22C55E | Error: #DC2626 | BG: #F9FAFB
Font: Google Fonts Poppins

## API
Dev: http://10.0.2.2:3000/api  (Android emulator)
Dev (real device): http://192.170.0.1:3000/api  (your WiFi IP)

## Folder: lib/
constants/ — colors.dart, api_constants.dart
models/ — user.dart, venue.dart, slot.dart, booking.dart, wallet.dart
services/ — api_service.dart, auth_service.dart, cloudinary_service.dart, firebase_otp_service.dart
providers/ — auth_provider.dart, venue_provider.dart, booking_provider.dart
screens/auth/ — welcome_screen.dart, login_screen.dart, owner_register_screen.dart, player_register_screen.dart, otp_screen.dart, forgot_password_screen.dart
screens/player/ — player_home_screen.dart, find_venues_screen.dart, venue_detail_screen.dart, confirm_booking_screen.dart, bookings_screen.dart, wallet_screen.dart, wallet_history_screen.dart, player_profile_screen.dart, teams_screen.dart, create_team_screen.dart, team_roster_screen.dart, find_opponents_screen.dart, team_rankings_screen.dart
screens/owner/ — owner_home_screen.dart, owner_pending_screen.dart
widgets/ — sport_text_field.dart, phone_field.dart, password_strength_bar.dart, auth_guard.dart
