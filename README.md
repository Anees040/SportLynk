# SportLynk

SportLynk is a comprehensive sports venue booking and team management platform designed for the Pakistani market. It connects sports enthusiasts (players) with venue owners, providing a seamless ecosystem for discovering venues, managing bookings, and processing secure escrow payments.

## Current Status: Phase 4 Completed

Phase 4 introduces professional High-Fidelity UI/UX improvements and a robust financial escrow system.

### Key Features
- **Escrow Payment Flow:** 30% booking deposits are securely deducted from the player's wallet and frozen in the owner's wallet until check-in.
- **Dynamic Venue Details:** Horizontal image galleries, rich JSONB amenities, and 12-hour AM/PM color-coded slot statuses.
- **Professional UI Redesign:** Grid-based home screen, AI-recommended horizontal scrolling cards, and advanced filtering.
- **Secure Authentication:** Phone Verification (Firebase OTP), Cloudinary Avatar Uploads, and JWT-secured REST APIs.
- **Wallet & Transactions:** Full wallet integration for deposits, top-ups, and transaction history.

## Tech Stack
- **Frontend:** Flutter (Dart)
- **Backend:** Node.js, Express.js
- **Database:** PostgreSQL (Local & Supabase Cloud)
- **Services:** Firebase Auth (OTP), Cloudinary (Images)

## Documentation
For detailed architecture, API endpoints, and setup instructions, please refer to:
- `ARCHITECTURE.md`
- `API.md`
- `DATABASE.md`
- `RUN_GUIDE.md`
