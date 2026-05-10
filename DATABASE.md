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
| locked_at | TIMESTAMP | DEFAULT NULL (for 5-min TTL) |
| price | DECIMAL(10,2) | |

### bookings
| Column | Type | Constraints |
|--------|------|-------------|
| id | UUID | PK |
| venue_id | UUID | FK→venues |
| player_id | UUID | FK→users |
| slot_id | UUID | FK→slots |
| status | ENUM('pending','confirmed','checked_in','no_show','cancelled') | DEFAULT 'pending' |
| total_amount | DECIMAL(10,2) | Full price of the slot |
| deposit_amount | DECIMAL(10,2) | 30% of total, deducted from player → frozen in owner wallet |
| qr_code_hash | VARCHAR(512) | HMAC-SHA256 of bookingId |
| created_at | TIMESTAMP | DEFAULT NOW() |

...

## Escrow & Slot Locking Flow

### 1. Slot Selection (Locking)
- When a user selects a slot, the app calls `POST /api/slots/:id/lock`.
- The status changes to `temporarily_locked` and `locked_at` is set to `NOW()`.
- If the user doesn't complete the booking within 5 minutes, the lock expires.
- Expired locks are released automatically during venue fetch or via background cleanup.

### 2. Booking (Escrow)
- When the user confirms the booking:
  1. 30% of `total_amount` is calculated as `deposit_amount`.
  2. `deposit_amount` is deducted from player's `wallets.balance`.
  3. `deposit_amount` is added to owner's `wallets.frozen_balance`.
  4. Slot status changes to `booked`.
  5. Booking status is `confirmed`.

### 3. Completion (Settlement)
- When the player checks in at the venue:
  1. The remaining 70% is paid in cash at the venue.
  2. The owner marks the booking as `checked_in`.
  3. The `frozen_balance` (30%) is moved to the owner's available `balance`.

### 4. Cancellation (Refunds)
- If the player cancels within the allowed timeframe (e.g., 24h before):
  1. The `frozen_balance` (30%) is moved back to the player's `balance`.
  2. Slot becomes `available`.
- If the player cancels too late or is a `no_show`:
  1. The `frozen_balance` (30%) is released from owner's `frozen_balance` to their available `balance` as a penalty fee.

