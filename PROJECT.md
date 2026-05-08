# SportLynk FYP

## Overview
Flutter mobile app for sports venue booking in Pakistan.
Players find and book sports grounds. Owners manage facilities.

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

## Colors
Primary: #0A1F13 | Accent: #22C55E | Error: #DC2626 | BG: #F9FAFB
Font: Google Fonts Poppins

## API
Dev: http://10.0.2.2:3000/api  (Android emulator)
Dev (real device): http://192.170.0.1:3000/api  (your WiFi IP)

## Folder: lib/
constants/ — colors.dart, api_constants.dart
models/ — user.dart, venue.dart, slot.dart, booking.dart, wallet.dart
services/ — api_service.dart, auth_service.dart, venue_service.dart, booking_service.dart, owner_service.dart
providers/ — auth_provider.dart, venue_provider.dart, booking_provider.dart
screens/auth/ — welcome_screen.dart, login_screen.dart, register_screen.dart
screens/player/ — player_home_screen.dart, venue_list_screen.dart, venue_detail_screen.dart, booking_confirm_screen.dart, booking_success_screen.dart, my_bookings_screen.dart
screens/owner/ — owner_home_screen.dart, venue_create_screen.dart, slot_manager_screen.dart, qr_scanner_screen.dart
widgets/ — venue_card.dart, booking_request_card.dart, booking_card.dart, slot_tile.dart, custom_button.dart
