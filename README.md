# SportLynk 🏟️

SportLynk is a comprehensive sports venue booking and team management platform for Pakistan. Players find and book sports grounds through a secure escrow payment system. Venue owners manage their facilities via a dedicated owner interface with booking approvals, QR check-in, and real-time earnings tracking.

## Current Status: Phase 5 Complete — Both Player & Owner Interfaces Operational

---

## Key Features

### Player Side ✅
- **Smart Venue Discovery** — Search, filter by sport/price/rating, AI-powered sport recommendations
- **Secure Escrow Booking** — Full deposit frozen at booking, released to owner only on check-in
- **Booking Approvals** — Owner approves/rejects before slot is confirmed; auto-approve after 2 hours
- **QR Code Check-in** — Player shows QR to owner; scan instantly transfers payment
- **Cancellation Policy** — >12 hours: full refund | <12 hours: deposit forfeited
- **Wallet** — Top-up, real-time balance, frozen balance display, full transaction history
- **Teams & Matchmaking** — Create teams, find opponents, view city rankings

### Owner Side ✅
- **Dashboard** — Today's revenue, pending bookings count, AI price suggestion, upcoming bookings list
- **Booking Management** — Approve/reject with player trust score + auto-refund on rejection
- **Slot Calendar** — Month view, block/unblock individual slots
- **QR Scanner** — Scan player's booking QR to instantly release payment to owner wallet
- **No-Show Management** — Mark no-show to forfeit deposit and penalize trust score
- **Venue Analytics** — Monthly revenue trend chart, per-week breakdown, financials

---

## Tech Stack
| | |
|---|---|
| **Mobile** | Flutter (Dart) — Android |
| **Backend** | Node.js + Express.js |
| **Database** | PostgreSQL 16 (local) + Supabase (cloud) |
| **Auth** | JWT HS256 + bcrypt + Firebase OTP |
| **Storage** | Cloudinary |
| **State** | Provider pattern |

## Team
- Mudassar Akram (SP23-BSE-028)
- Muhammad Anees (SP23-BSE-030)  
- **Supervisor:** Miss Ayesha Hussain | COMSATS University Islamabad

## Documentation
| File | Description |
|------|-------------|
| `ARCHITECTURE.md` | System design, security, escrow flow |
| `API.md` | All 30+ REST endpoints |
| `DATABASE.md` | PostgreSQL schema |
| `FEATURES.md` | Feature completion tracker |
| `PROGRESS.md` | Daily development log |
| `RUN_GUIDE.md` | Setup instructions |

## Quick Start
```bash
# Backend
cd backend && npm install && npm run dev

# Flutter (Android emulator)
flutter run
```

> **Note:** Copy `.env.example` to `.env` in `backend/` and set your `DATABASE_URL` and `JWT_SECRET`.
