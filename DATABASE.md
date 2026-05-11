# Database Schema — PostgreSQL

## Connection
Local: postgresql://postgres:sportlynk123@localhost:5432/sportlynk
Cloud: Supabase URI (see .env in backend)
Both have IDENTICAL schema.

## Tables

### users
| Column | Type | Constraints |
|--------|------|-------------|
| id | UUID | PK DEFAULT gen_random_uuid() |
| email | VARCHAR(255) | UNIQUE NOT NULL |
| password_hash | VARCHAR(255) | NOT NULL |
| role | ENUM('player','owner','admin') | DEFAULT 'player' |
| name | VARCHAR(255) | NOT NULL |
| phone | VARCHAR(20) | |
| avatar_url | TEXT | |
| is_active | BOOLEAN | DEFAULT true |
| created_at | TIMESTAMP | DEFAULT NOW() |

### player_profiles
| Column | Type | Constraints |
|--------|------|-------------|
| id | UUID | PK |
| user_id | UUID | FK→users UNIQUE |
| sport_preferences | TEXT[] | DEFAULT '{}' |
| elo_rating | DECIMAL | DEFAULT 1000 |
| trust_score | INT | DEFAULT 100 |

### owner_profiles
| Column | Type | Constraints |
|--------|------|-------------|
| id | UUID | PK |
| user_id | UUID | FK→users UNIQUE |
| business_name | VARCHAR(255) | |
| cnic | VARCHAR(15) | |
| is_verified | BOOLEAN | DEFAULT false |

### venues
| Column | Type | Constraints |
|--------|------|-------------|
| id | UUID | PK |
| owner_id | UUID | FK→users |
| name | VARCHAR(255) | |
| description | TEXT | |
| sport_type | VARCHAR(50) | |
| ground_type | VARCHAR(20) | ENUM-like ('turf', 'futsal', 'indoor', etc.) |
| city | VARCHAR(100) | |
| address | TEXT | |
| latitude | DECIMAL(10,8) | |
| longitude | DECIMAL(11,8) | |
| base_price | DECIMAL(10,2) | |
| price_per_hour | DECIMAL(10,2) | |
| upfront_percent | DECIMAL(5,2) | DEFAULT 30.00 — Dynamic % taken at booking |
| discount_percent | DECIMAL(5,2) | DEFAULT 0.00 — Discount for full payment |
| image_url | TEXT | |
| venue_photos | TEXT[] | DEFAULT '{}' |
| amenities | JSONB | DEFAULT '{}'::jsonb |
| rating | DECIMAL(3,2) | DEFAULT NULL |
| total_reviews | INT | DEFAULT 0 |
| operating_hours_from | TIME | DEFAULT NULL |
| operating_hours_to | TIME | DEFAULT NULL |
| is_active | BOOLEAN | DEFAULT true |

### slots
| Column | Type | Constraints |
|--------|------|-------------|
| id | UUID | PK |
| venue_id | UUID | FK→venues |
| slot_date | DATE | |
| start_time | TIME | |
| end_time | TIME | |
| status | ENUM('available','booked','blocked','temporarily_locked') | DEFAULT 'available' |
| locked_by | UUID | FK→users — Player who locked the slot |
| locked_at | TIMESTAMP | DEFAULT NULL — Auto-released after 2 minutes |
| price | DECIMAL(10,2) | |

### bookings
| Column | Type | Constraints |
|--------|------|-------------|
| id | UUID | PK |
| venue_id | UUID | FK→venues |
| player_id | UUID | FK→users |
| slot_id | UUID | FK→slots |
| slot_date | DATE | Date of the booked slot |
| start_time | TIME | Slot start time |
| end_time | TIME | Slot end time |
| base_price | DECIMAL(10,2) | Price of the slot |
| security_deposit | DECIMAL(10,2) | Amount frozen in the player's wallet |
| total_amount | DECIMAL(10,2) | Full price of the slot |
| status | ENUM('pending','confirmed','checked_in','completed','no_show','cancelled') | DEFAULT 'pending' |
| qr_code | VARCHAR(512) | UUID used for venue check-in |
| notes | TEXT | |
| cancelled_at | TIMESTAMP | Set on cancellation |
| cancellation_reason | VARCHAR(255) | 'user_cancelled' or 'late_cancellation' |
| created_at | TIMESTAMP | DEFAULT NOW() |
| updated_at | TIMESTAMP | DEFAULT NOW() |

### wallets
| Column | Type | Constraints |
|--------|------|-------------|
| id | UUID | PK |
| user_id | UUID | FK→users UNIQUE |
| balance | DECIMAL(10,2) | DEFAULT 500.00 — Available to spend/withdraw |
| frozen_balance | DECIMAL(10,2) | DEFAULT 0.00 — Escrow holdings for active bookings |

### transactions
| Column | Type | Constraints |
|--------|------|-------------|
| id | UUID | PK |
| wallet_id | UUID | FK→wallets |
| user_id | UUID | FK→users |
| booking_id | UUID | FK→bookings (nullable) |
| type | VARCHAR(50) | See Transaction Types below |
| amount | DECIMAL(10,2) | Positive = credit, Negative = debit |
| balance_after | DECIMAL(10,2) | Wallet balance snapshot after transaction |
| description | TEXT | Human-readable summary |
| counterparty_name | VARCHAR(255) | Venue or player name |
| reference_id | VARCHAR(100) | Unique reference (TRX-xxxxx) |
| created_at | TIMESTAMP | DEFAULT NOW() |

#### Transaction Types
| Type | Meaning |
|------|---------|
| `topup` | Player added money to wallet |
| `booking_payment` | Security deposit frozen at booking time |
| `refund` | Full refund on early cancellation (>= 12 hours before slot) |
| `escrow_release` | Late cancellation penalty deducted from player |
| `escrow_received` | Owner receives late cancellation penalty |

## Escrow & Slot Locking Flow

### 1. Slot Selection (Optimistic Locking)
- When a player selects a slot, the app calls `POST /api/slots/:id/lock`.
- The status changes to `temporarily_locked`, `locked_by` is set to the player's ID, and `locked_at` to `NOW()`.
- **Only one slot per player** — selecting a new slot auto-releases the previous one.
- If the player doesn't complete the booking within **2 minutes**, the lock expires.
- Expired locks are released automatically during venue fetch.

### 2. Booking (Escrow Freeze)
When the player confirms the booking:
1. `security_deposit` (dynamic %, based on `venue.upfront_percent`) is deducted from the player's `wallets.balance`.
2. `security_deposit` is added to the player's `wallets.frozen_balance` (NOT the owner's wallet).
3. A `booking_payment` transaction is recorded.
4. Slot status changes to `booked`.
5. Booking status is `confirmed`.

### 3. Dynamic Slot Filtering
- Slots for **past dates** are never shown (API returns empty).
- Slots for **today** only return slots where `start_time > current PKT time`.
- This prevents players from booking a 6 AM slot at 9 AM.

### 4. Completion (Settlement via Owner Resolution)
When the player arrives at the venue:
1. The owner calls `POST /api/bookings/:id/resolve` with `{ "status": "completed" }`.
2. The `security_deposit` is deducted from the player's `frozen_balance`.
3. The `security_deposit` is added to the owner's `balance`.
4. Transactions are recorded for both parties.

### 5. Cancellation (12-Hour Policy)
**Early Cancellation** (>= 12 hours before slot):
1. The `frozen_balance` is deducted.
2. The same amount is added back to the player's `balance`.
3. A `refund` transaction is created.
4. Slot becomes `available`.

**Late Cancellation** (< 12 hours before slot):
1. The `frozen_balance` is deducted from the player.
2. The deposit is transferred to the owner's `balance`.
3. An `escrow_release` transaction (player) and `escrow_received` transaction (owner) are created.
4. Slot becomes `available`.

### 6. No-Show
1. Owner calls `POST /api/bookings/:id/resolve` with `{ "status": "no_show" }`.
2. Same financial flow as late cancellation — the deposit goes to the owner.
