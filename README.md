# SportLynk 🏟️

SportLynk is a comprehensive sports venue booking and team management platform for Pakistan. Players find and book sports grounds through a secure escrow payment system. Venue owners manage their facilities via a dedicated owner interface with booking approvals, QR check-in, and real-time earnings tracking.

## Current Status: Phase 5 Complete — Both Player & Owner Interfaces Operational

---

## Key Features

### Player Side ✅
- **Smart Venue Discovery** — Search, filter by sport/price/rating, AI-powered sport recommendations
- **Secure Escrow Booking** — Full slot price frozen at booking, released to owner only on check-in
- **Booking Approvals** — Owner approves/rejects before slot is confirmed; auto-approve after 2 hours, auto-reject if the slot is under 2 hours away and still unapproved
- **QR Code Check-in** — Player shows QR to owner; scan instantly transfers payment
- **Cancellation Policy** — ≥24 hours: full refund | <24 hours: 80% refunded, 20% deposit to owner
- **Wallet** — Top-up, real-time balance, itemised frozen-balance breakdown, per-transaction receipts, and withdrawals (min PKR 200, one pending request at a time)
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
| **Database** | PostgreSQL on Supabase — one cloud database for both development and the demo |
| **Auth** | JWT HS256 + bcrypt + Firebase OTP |
| **Storage** | Cloudinary |
| **State** | Provider pattern |
| **Hosting** | Render (free tier) — see `doc/DEPLOY_GUIDE.md` |

## Team
- Mudassar Akram (SP23-BSE-028)
- Muhammad Anees (SP23-BSE-030)  
- **Supervisor:** Miss Ayesha Hussain | COMSATS University Islamabad

## Documentation
| File | Description |
|------|-------------|
| [`doc/ARCHITECTURE.md`](doc/ARCHITECTURE.md) | System design, security, escrow flow |
| [`doc/API.md`](doc/API.md) | All REST endpoints |
| [`doc/DATABASE.md`](doc/DATABASE.md) | PostgreSQL schema + migration history |
| [`doc/FEATURES.md`](doc/FEATURES.md) | Feature completion tracker |
| [`doc/PROGRESS.md`](doc/PROGRESS.md) | Development log, wave by wave |
| [`doc/DEPLOY_GUIDE.md`](doc/DEPLOY_GUIDE.md) | Step-by-step deploy to Render + phone demo setup |
| [`doc/S1_ACCEPTANCE.md`](doc/S1_ACCEPTANCE.md) | Sprint 1 acceptance checklist and how to verify each row |
| [`doc/CODING_STANDARDS.md`](doc/CODING_STANDARDS.md) | Conventions this codebase follows |
| [`doc/PROJECT.md`](doc/PROJECT.md) | Scope, FYP context, module breakdown |

---

## Running the app

### 1. Backend

```bash
cd backend
npm install
cp .env.example .env      # then fill in DATABASE_URL and JWT_SECRET
npm run dev               # nodemon, or `npm start` for plain node
```

You should see `✅ Database connected (TLS on)` and `🚀 Server running on port 3000`.
Check it with `curl http://localhost:3000/api/health`.

### 2. Flutter — pick a run mode

The app reads its API address from one build-time variable, `API_BASE_URL`.
Nothing else in the app hard-codes a host.

| Mode | Command | When |
|---|---|---|
| **Android emulator** | `flutter run` | Default. `10.0.2.2` is the emulator's alias for your laptop's localhost. |
| **Physical phone, same Wi-Fi** | `flutter run --dart-define=API_BASE_URL=http://<laptop-LAN-IP>:3000/api` | Testing on a real device while the backend runs on your laptop. Both must be on the same network, and the backend must stay running. |
| **Physical phone, USB cable** | `adb reverse tcp:3000 tcp:3000` then `flutter run` | Works without Wi-Fi, but only while the cable is plugged in. |
| **Cloud (anywhere, mobile data)** | `flutter run --dart-define=API_BASE_URL=https://<your-app>.onrender.com/api` | Demo mode. Laptop can be off. |

Find your laptop's LAN IP with `ipconfig` (look for IPv4 under your Wi-Fi adapter).

Release build for the demo:

```bash
flutter build apk --release --dart-define=API_BASE_URL=https://<your-app>.onrender.com/api
```

> ⚠️ A physical phone **always** needs `--dart-define`. Plain `flutter run` uses
> `10.0.2.2`, which only means anything inside an emulator. Full walkthrough in
> [`doc/DEPLOY_GUIDE.md`](doc/DEPLOY_GUIDE.md).

### 3. Seeding demo venues (optional)

```bash
cd backend && npm run seed:venues
```

> ⚠️ This *deletes* the first owner account's existing venues, slots, bookings
> and their transaction rows before inserting 10 demo venues. It prints what it is
> about to delete and waits 5 seconds. User accounts and wallet balances are not
> touched.

