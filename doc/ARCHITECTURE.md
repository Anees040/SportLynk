# SportLynk Architecture

## Pattern: Layered Architecture
Layer 1 — Presentation: Flutter (Dart) mobile app
Layer 2 — Business Logic: Node.js Express API
Layer 3 — Data & Services: 
          - PostgreSQL (local dev / Supabase cloud)
          - Firebase Authentication (SMS/OTP validation)
          - Cloudinary (Image storage for avatars and venues)

## Communication
Flutter → HTTPS REST + JWT Bearer → Node.js
Node.js → pg pool (parameterized SQL) → PostgreSQL
Node.js → Cloudinary API (image uploads)
Flutter → Firebase Auth API (OTP requests)

## Booking & Escrow Flow

### The escrow ledger (single source of truth)

Every money movement in SportLynk is one of the seven events below. `P` is the
full slot price. The whole of `P` is frozen at booking; the **deposit** is the
at-risk 20% slice (`deposit_amount = 0.20 × P`) that the player forfeits on a
late cancellation or a no-show.

| Event | Player balance | Player frozen | Owner balance | Booking status |
| --- | --- | --- | --- | --- |
| Book slot (price P) | −P | +P | — | `pending` |
| Owner approves (or auto) | — | — | — | `confirmed` |
| Owner rejects | +P | −P | — | `rejected` |
| Cancel more than 24h before slot | +P | −P | — | `cancelled` |
| Cancel within 24h | +0.8P | −P | +0.2P | `cancelled` |
| QR check-in | — | −P | +P | `checked_in` |
| No-show (auto, 30 min after start) | +0.8P | −P | +0.2P | `no_show` |

Policy constants live in exactly one place — `backend/src/utils/escrow.js`
(`POLICY`) — so routes, jobs and docs cannot drift:

| Constant | Value | Meaning |
|---|---|---|
| `DEPOSIT_PERCENT` | 20 | at-risk slice of the price |
| `CANCELLATION_WINDOW_HOURS` | 24 | free-cancellation cut-off |
| `NO_SHOW_GRACE_MINUTES` | 30 | grace after slot start before forfeit |
| `NO_SHOW_TRUST_PENALTY` | 10 | `player_profiles.trust_score` deduction |
| `AUTO_DECIDE_AFTER_HOURS` | 2 | pending age that triggers auto-confirm (FR4.10) |
| `AUTO_DECIDE_MIN_LEAD_HOURS` | 2 | lead time under which pending is auto-rejected |

Column semantics (see `migrations/010_escrow_policy_alignment.sql`):
- `bookings.security_deposit` — the amount **actually held** in escrow for that
  booking (new rows = full price `P`; legacy rows may hold 30% of `P`).
- `bookings.deposit_amount` — the 20% at-risk deposit.
- The penalty on a late cancel / no-show is `min(deposit_amount, security_deposit)`,
  so legacy rows can never refund more money than was ever frozen.

### Request lifecycle

1. Player selects slot and taps 'Book Now' (no slot locking — instant DB-atomic claim)
2. Backend uses `SELECT ... FOR UPDATE` to claim the slot — handles simultaneous bookings at microsecond level
3. Full slot price moves from Player's `balance` → Player's `frozen_balance`;
   `deposit_amount` is computed server-side (clients never send an amount)
4. Booking created with status: `pending`
5. Owner reviews booking (sees trust score) → Approve or Reject
   - Approve → status: `confirmed`, `approved_at` set; money stays frozen
   - Reject → status: `rejected`; full escrow returned to `balance`; slot freed
   - `autoApproveJob` sweeps every 5 min (FR4.10): pending for >2h with the slot
     still >2h away → auto-confirm; slot starting within 2h and still unapproved
     → auto-reject + full refund. Both write `auto_decided_at` + notifications.
6. Owner scans Player's QR code at venue (`POST /owner/scan-qr`)
   - `player.frozen_balance -= P` → `owner.balance += P`
   - Booking status → `checked_in`
7. Cancellation (`PATCH /bookings/:id/cancel`)
   - ≥24h before slot start → full refund, status `cancelled`
   - <24h before slot start → 80% refunded, 20% credited to the owner,
     `cancellation_reason = 'late_cancellation'`
8. No-show — `noShowJob` sweeps every 5 min for `confirmed` bookings whose slot
   started >30 min ago with no check-in (the owner's `POST /owner/no-show/:id`
   button is an early trigger for the identical ledger move)
   - Player `balance += 0.8P`, `frozen_balance -= P`, owner `balance += 0.2P`
   - Player `trust_score -= 10` + a `notifications` row for both parties
   - Booking status → `no_show`, `no_show_processed = true` (idempotency guard)

Every one of these writes runs inside a single transaction that locks the booking
row (`FOR UPDATE OF b`) and then the wallets, always in the order
booking → player wallet → owner wallet to keep the lock order deadlock-free.
Notification inserts are wrapped in a `SAVEPOINT` so a missing/failed
notification can never roll back a money transfer.

## Race Condition Prevention (Slot Booking)
The app does NOT use temporary slot locking (removed in Phase 5).
Instead, PostgreSQL's `FOR UPDATE` row-level lock in the booking transaction ensures:
- If two players book simultaneously, the second gets a clean 409 error
- No slots can be "held" by bad actors to block availability
- No 2-minute timers or lock expiry logic needed

## Local vs Cloud Database
Development: LOCAL PostgreSQL (localhost:5432)
Production/Demo: Supabase PostgreSQL (cloud)
Switch: change DATABASE_URL in .env file
Both have identical schema — zero migration needed

## Security
Passwords: bcrypt hash (cost 12) — never store plain text
Auth: JWT HS256, 24h expiry, stored in SharedPreferences
QR codes: HMAC-SHA256(bookingId, JWT_SECRET) — tamper-proof
Route protection: authMiddleware verifies JWT on every protected route
RBAC: roleMiddleware checks req.user.role before owner endpoints
SQL injection: parameterized queries only, no string interpolation

## Auth Flow
1. User registers → bcrypt hash password → insert user + wallet + profile → return JWT
2. User logs in → bcrypt.compare → return JWT
3. Flutter stores JWT in SharedPreferences
4. Every API call adds: Authorization: Bearer {jwt}
5. authMiddleware decodes JWT → attaches req.user → controller runs

---

## Architecture Decisions (Chapter 1)

### 1.1 Backend Framework: Express.js (Not NestJS)

Express.js is a minimal, unopinionated Node.js framework. NestJS is a full-featured, opinionated framework built on top of Express.

| Factor | Express.js (CHOSEN) | NestJS (REJECTED) |
|--------|---------------------|-------------------|
| Learning Curve | 1-2 hours to understand. Minimal new concepts. | 1-2 weeks to understand. Decorators, Modules, DI containers, Guards. |
| Code to get running | ~15 lines for a working API server | ~50 lines plus 4-5 config files |
| Time available | You have 3 days. Express is right. | Only viable if you already know TypeScript and OOP patterns. |
| Committee expectation | Express is industry-standard for REST APIs. Fully acceptable. | Impressive IF done correctly. Disastrous if done wrong. |
| Debugging | Error messages are simple and Googleable. | Error messages are complex and layered. |

> [!NOTE]
> NestJS is an excellent framework. The choice of Express is purely practical given your timeline. For FYP-2, NestJS would be worth learning.

### 1.2 Database Strategy: Local PostgreSQL + Supabase Cloud

Many beginners ask: *'Why use two databases?'* The answer is that you are **not** using two separate databases. You are using **one PostgreSQL database engine** with **two hosting environments**. They have identical schemas and identical data at sync time.

**What does 'local' mean?**
Local means the database server runs on your own laptop. It is installed like any other program (pgAdmin included). Data is stored in a folder on your hard drive. It is extremely fast, works offline, and you can inspect data visually through pgAdmin.

**What does 'cloud' (Supabase) mean?**
Cloud means the database server runs on Supabase's servers somewhere in Singapore. You connect to it over the internet using a connection string URL. Supabase provides a beautiful web dashboard where you can see your tables, run SQL, and view data from any device.

**Why use both?**

| Situation | Use This |
|-----------|----------|
| Day-to-day development (coding, testing) | LOCAL — fast, no internet needed, instant |
| Demo for committee, friend wants to test | SUPABASE CLOUD — accessible from anywhere |
| Internet is down | LOCAL — still works perfectly |
| Switching between them | Change ONE line in .env file. Zero code change. |

**How switching works:**
Your backend reads the database address from a file called `.env`. This file has two lines:

```env
# LOCAL (comment this out for demo)
DATABASE_URL=postgresql://postgres:sportlynk123@localhost:5432/sportlynk

# SUPABASE CLOUD (uncomment this for demo)
# DATABASE_URL=postgresql://postgres:yourpass@db.abc.supabase.co:5432/postgres
```

A `#` at the start of a line means it is ignored. To switch: add `#` to one line and remove `#` from the other. Restart the backend. That is the entire process.

> [!WARNING]
> NEVER commit your .env file to GitHub. Add it to .gitignore. It contains your database password.

### 1.3 Authentication: How It Works End-to-End

This is a full explanation of authentication from scratch. Many beginners treat auth as a black box. After reading this, you will understand every piece.

**The Problem Auth Solves:**
HTTP is stateless. Every request is isolated. The server has no memory of previous requests. So after a player logs in, how does the server know who they are on the next request? The answer is: the client proves their identity on every request by sending a **token**.

**What is bcrypt?**
bcrypt is a password hashing algorithm. A hash is a one-way transformation. You put in `'password123'` and get out a 60-character string like `'$2b$12$abcdef...'`. You cannot reverse it. When someone logs in, you hash their input and compare it to the stored hash. You never store or compare plain text passwords.

The `12` in bcrypt is the cost factor. It means the algorithm runs 2^12 (4096) internal rounds. This makes brute-force attacks slow. An attacker trying billions of passwords per second is slowed to thousands per second.

**What is JWT?**
JWT stands for JSON Web Token. It is a string in three parts separated by dots: `Header.Payload.Signature`.

Example:
```
eyJhbGciOiJIUzI1NiJ9.eyJpZCI6IjEyMyIsInJvbGUiOiJwbGF5ZXIifQ.AbC123XyZ
```

The **Payload** contains data like user ID and role. The **Signature** is a cryptographic proof that the payload was not tampered with. Only the server knows the secret used to create the signature.

**Complete Authentication Flow (Step by Step):**

| Step | What Happens | Who Does It | Technical Detail |
|------|-------------|-------------|------------------|
| 1 | User fills in name, email, password and taps Register | Flutter UI | Form validation runs first |
| 2 | Flutter sends POST request to /api/auth/register with the form data | Flutter | JSON body: {name, email, password, role, phone} |
| 3 | Backend receives request, checks email not already in database | Node.js | SELECT from users WHERE email=$1 |
| 4 | Backend hashes the password | Node.js | bcrypt.hash(password, 12) — takes ~300ms intentionally |
| 5 | Backend inserts user into database | Node.js | INSERT INTO users... RETURNING id, email, role |
| 6 | Backend creates wallet for this user | Node.js | INSERT INTO wallets(user_id) VALUES($1) |
| 7 | Backend creates player or owner profile | Node.js | INSERT INTO player_profiles or owner_profiles |
| 8 | Backend creates a JWT token | Node.js | jwt.sign({id, email, role}, JWT_SECRET, {expiresIn:'24h'}) |
| 9 | Backend sends token back to Flutter | Node.js | Response: {success:true, data:{token, user}} |
| 10 | Flutter stores the token securely | Flutter | SharedPreferences.setString('jwt_token', token) |
| 11 | For every future API request, Flutter adds the token | Flutter | Headers: {Authorization: 'Bearer eyJ...'} |
| 12 | Backend middleware verifies the token on every request | Node.js | jwt.verify(token, JWT_SECRET) — extracts {id, email, role} |
| 13 | Controller uses req.user.id to know who is making the request | Node.js | SELECT * FROM bookings WHERE player_id = req.user.id |

**What RBAC Means:**
RBAC stands for Role-Based Access Control. Different API routes are only accessible to certain roles. A player token cannot access owner routes and vice versa. This is enforced by middleware that checks `req.user.role` before the controller runs.

**How role protection works in Express:**
```javascript
// This middleware runs BEFORE the controller
const checkRole = (role) => (req, res, next) => {
  if (req.user.role !== role) {
    return res.status(403).json({success:false, message:'Access denied'})
  }
  next() // role matches, continue to controller
}

// Route setup
router.post('/bookings', authMiddleware, checkRole('player'), createBooking)
// authMiddleware runs first → then checkRole → then createBooking
```

### 1.4 Why Not Supabase Auth Instead of Custom JWT?

Supabase has a built-in authentication system that handles everything automatically. The reason we use custom JWT with Express instead is **consistency with your SRS documentation**. Your SRS states *'Node.js Express backend with JWT authentication and bcrypt'*. The committee will compare your implementation to your SRS. Changing auth providers mid-project creates a documentation mismatch that requires explanation.

Additionally, custom JWT gives you full control over the token payload, expiry, and role-based logic, which is important for the RBAC features SportLynk requires.
