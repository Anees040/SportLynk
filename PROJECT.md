# SportLynk — FYP Project

## Overview
SportLynk is a full-stack sports venue booking platform for Pakistan. Players discover and book sports grounds with an escrow-protected payment system. Venue owners manage their facilities, review booking requests, scan QR codes to check in players, and track earnings — all from a dedicated mobile interface.

**Current Status:** Phase 5 Complete — Both Player and Owner interfaces are fully functional.

## Team
- Mudassar Akram (SP23-BSE-028)
- Muhammad Anees (SP23-BSE-030)
- **Supervisor:** Miss Ayesha Hussain | COMSATS University Islamabad

## Tech Stack
| Layer | Technology |
|-------|-----------|
| Mobile App | Flutter (Dart) — Android |
| Backend API | Node.js + Express.js |
| Database | PostgreSQL 16 (local dev) + Supabase (cloud demo) |
| Authentication | JWT (HS256, 24h) + bcrypt (cost 12) + Firebase OTP |
| File Storage | Cloudinary (avatars, venue photos) |
| State Management | Provider pattern |
| Fonts | Google Fonts — Poppins |

## App Colors
- Primary: `#0A1F13` (dark green)
- Accent: `#22C55E` (bright green)
- Background: `#F8FAFC` (light grey)
- Error: `#DC2626` | Warning: `#F59E0B` | Success: `#16A34A`

## API
- Android emulator: `http://10.0.2.2:3000/api`
- Real device/web: `http://{your-wifi-ip}:3000/api`

## Project Structure
```
lib/
  constants/   — colors.dart, api_constants.dart, app_colors.dart
  models/      — user.dart, venue.dart, slot.dart, booking.dart, wallet.dart
  providers/   — auth_provider.dart, venue_provider.dart, booking_provider.dart
  services/    — cloudinary_service.dart, firebase_otp_service.dart
  screens/
    auth/      — welcome, login, register (player+owner), otp, forgot_password
    player/    — home, find_venues, venue_detail, confirm_booking, bookings,
                  player_booking_detail, wallet, wallet_history, profile,
                  teams, create_team, team_roster, find_opponents, team_rankings,
                  trust_score, tournaments, help_support
    owner/     — home (with 5-tab nav), booking_requests, slot_calendar,
                  qr_scanner, venue_screen, profile
  widgets/     — custom_button.dart, custom_loader.dart, sport_text_field.dart

backend/src/
  routes/      — auth.js, bookings.js, owner.js, player.js, users.js, venues.js, wallet.js
  middleware/  — authMiddleware.js, roleMiddleware.js
  db/          — pool.js
  scripts/     — seed.js, seed_venues.js, run_migration.js
  migrations/  — 001 through 007
```

## Documentation Files
| File | Description |
|------|-------------|
| `ARCHITECTURE.md` | System design, patterns, security decisions |
| `API.md` | All REST endpoints with request/response |
| `DATABASE.md` | PostgreSQL schema with escrow flow |
| `FEATURES.md` | Feature completion tracker |
| `PROGRESS.md` | Daily development log |
| `RUN_GUIDE.md` | Setup and run instructions |
