# SportLynk 🏟️

SportLynk is a comprehensive sports venue booking and team management platform designed for the Pakistani market. It connects sports enthusiasts (players) with venue owners, providing a seamless ecosystem for discovering venues, managing bookings, and processing secure escrow payments.

## Current Status: Phase 4 Complete — Player Interface Production Ready

The player-facing application is fully functional and production-ready. All booking, payment, and cancellation flows have been tested and stabilized. The project is now transitioning to **Phase 5: Owner Interface**.

### Core Features (Player Side)
- **Escrow Payment System:** Dynamic deposit percentage (set per venue by the owner) is frozen in the player's wallet at booking time. Released to the owner upon completion or forfeited on late cancellation.
- **12-Hour Cancellation Policy:** Cancellations >= 12 hours before the slot receive a full refund. Late cancellations forfeit the deposit to the venue owner.
- **Dynamic Slot Filtering:** Past time slots are automatically hidden based on Pakistan Standard Time (PKT). No stale bookings possible.
- **Professional UI:** Gradient headers, overlapping search bar, branded custom loaders, pull-to-refresh, and premium card-based layouts.
- **Secure Authentication:** Phone Verification (Firebase OTP), Cloudinary Avatar Uploads, JWT-secured REST APIs with route guards.
- **Wallet & Transactions:** Full wallet with Available Balance, Frozen Balance, Top-up, Withdrawal, and detailed transaction history (Frozen, Refund, Penalty types).
- **Help & Support:** In-app FAQ accordion and contact methods.

### Upcoming (Phase 5 — Owner Interface)
- Owner Dashboard with earnings overview
- Venue creation/editing with Cloudinary photo uploads
- Slot generation and inventory management
- Booking resolution (mark completed/no-show to claim escrow)

## Tech Stack
- **Frontend:** Flutter (Dart) — Android & Web
- **Backend:** Node.js, Express.js
- **Database:** PostgreSQL (Local & Supabase Cloud — identical schema)
- **Services:** Firebase Auth (OTP), Cloudinary (Images), JWT (HS256)

## Team
- Mudassar Akram (SP23-BSE-028)
- Muhammad Anees (SP23-BSE-030)
- **Supervisor:** Miss Ayesha Hussain | COMSATS University Islamabad

## Documentation
| File | Description |
|------|-------------|
| `ARCHITECTURE.md` | System architecture and design patterns |
| `API.md` | All REST API endpoints with request/response formats |
| `DATABASE.md` | Complete database schema with escrow flow documentation |
| `FEATURES.md` | Feature completion status tracker |
| `PROGRESS.md` | Daily development progress log |
| `PROJECT.md` | Project overview, team info, and tech stack |
| `RUN_GUIDE.md` | Setup and run instructions |
| `owner_screen_guide.md` | Detailed guide for implementing the Owner Interface |
