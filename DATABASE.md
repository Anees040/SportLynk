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
| city | VARCHAR(100) | |
| address | TEXT | |
| latitude | DECIMAL(10,8) | |
| longitude | DECIMAL(11,8) | |
| base_price | DECIMAL(10,2) | |
| current_price | DECIMAL(10,2) | |
| image_url | TEXT | |
| is_active | BOOLEAN | DEFAULT true |

### venue_slots
| Column | Type | Constraints |
|--------|------|-------------|
| id | UUID | PK |
| venue_id | UUID | FK→venues |
| date | DATE | |
| start_time | TIME | |
| end_time | TIME | |
| status | ENUM('available','booked','blocked') | DEFAULT 'available' |
| price | DECIMAL(10,2) | |

### bookings
| Column | Type | Constraints |
|--------|------|-------------|
| id | UUID | PK |
| venue_id | UUID | FK→venues |
| player_id | UUID | FK→users |
| slot_id | UUID | FK→venue_slots |
| status | ENUM('pending','confirmed','checked_in','no_show','cancelled') | DEFAULT 'pending' |
| total_amount | DECIMAL(10,2) | |
| deposit_amount | DECIMAL(10,2) | 30% of total, frozen in wallet |
| qr_code_hash | VARCHAR(512) | HMAC-SHA256 of bookingId |
| created_at | TIMESTAMP | DEFAULT NOW() |

### wallets
| Column | Type | Constraints |
|--------|------|-------------|
| id | UUID | PK |
| user_id | UUID | FK→users UNIQUE |
| balance | DECIMAL(10,2) | DEFAULT 500.00 |
| frozen_balance | DECIMAL(10,2) | DEFAULT 0.00 |

### wallet_transactions
| Column | Type | Constraints |
|--------|------|-------------|
| id | UUID | PK |
| wallet_id | UUID | FK→wallets |
| type | VARCHAR(50) | 'deposit_freeze','deposit_release','refund','earning' |
| amount | DECIMAL(10,2) | |
| reference_id | UUID | |
| created_at | TIMESTAMP | DEFAULT NOW() |
