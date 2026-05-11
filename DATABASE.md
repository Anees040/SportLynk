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
| status | ENUM('available','booked','blocked') | DEFAULT 'available' |
| locked_by | UUID | FK→users (legacy, no longer used) |
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
| status | ENUM('pending','confirmed','checked_in','no_show','cancelled') | DEFAULT 'pending' |
| qr_code | TEXT | UUID used for venue check-in |
| owner_id | UUID | FK→users (denormalized for fast owner queries) |
| checked_in_at | TIMESTAMP | Set when owner scans QR |
| no_show_at | TIMESTAMP | Set when owner marks no-show |
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
|------|--------|
| `topup` | Player added money to wallet |
| `booking_payment` | Full deposit frozen at booking time |
| `refund` | Full refund (early cancellation or owner rejection) |
| `escrow_release` | Deposit deducted from player frozen balance |
| `escrow_received` | Owner receives deposit (check-in, no-show, late cancel) |
| `no_show_penalty` | Player's deposit forfeited for no-show |
| `owner_payout` | Owner withdrew balance |
| `withdrawal` | User withdrew wallet balance |

## Escrow & Booking Flow (Phase 5)

### 1. Slot Selection (No Locking — Atomic)
- Player selects a slot in the UI. No lock API is called.
- When player taps 'Book Now', the backend uses `SELECT ... FOR UPDATE` to atomically claim the slot.
- If two players book the same slot simultaneously, the second gets a 409 conflict error.
- No `temporarily_locked` status is ever set. No timer needed.

### 2. Booking Creation (Escrow Freeze)
1. Backend verifies slot is `available` under row-level lock.
2. Full amount deducted from player's `wallets.balance`.
3. Full amount added to player's `wallets.frozen_balance` (escrow).
4. Booking created with status: `pending`, `owner_id` populated.
5. Slot status changes to `booked`.
6. `booking_payment` transaction recorded.

### 3. Owner Approval
- Owner sees booking in Pending tab with player trust score.
- **Approve** → booking status: `confirmed`; money stays frozen.
- **Reject** → player `frozen_balance` refunded to `balance`; slot freed; `refund` transaction.
- **Auto-approve** after 2 hours (displayed as notice in UI).

### 4. QR Check-in (Settlement)
When player arrives and owner scans QR (`POST /owner/scan-qr`):
1. `player.frozen_balance -= deposit` → `owner.balance += deposit`.
2. `escrow_release` (player) + `escrow_received` (owner) transactions created.
3. Booking status → `checked_in`.

### 5. No-Show
`POST /owner/no-show/:id`:
1. Same financial transfer as check-in.
2. `player.trust_score -= 10` (via `player_profiles`).
3. `no_show_penalty` (player) + `escrow_received` (owner) transactions.
4. Booking status → `no_show`.

### 6. Cancellation (12-Hour Policy)
**Early** (>= 12 hours before slot):
- Full `frozen_balance` refunded to player `balance`. `refund` transaction. Slot freed.

**Late** (< 12 hours before slot):
- Deposit transferred to owner. `escrow_release` + `escrow_received` transactions. Slot freed.

### 7. Dynamic Slot Filtering
- Past time slots never shown (filtered at API level using PKT time).
- Today's slots: only `start_time > current PKT time` returned.
