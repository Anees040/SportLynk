# Database Schema — PostgreSQL

## Connection
**Supabase is the only database** — the same instance serves local development
and the deployed Render API. There is no local PostgreSQL and no second copy to
keep in sync.

Use the **session pooler** URI from Supabase → Project Settings → Database, with
`?sslmode=require`, in `backend/.env` as `DATABASE_URL`. The direct
`db.<ref>.supabase.co` host is IPv6-only on the free tier and does not resolve
from every network (including Render's outbound IPv4). `src/db/pool.js` derives
TLS from `sslmode=` in the URL, from `NODE_ENV`, or from the host simply not being
localhost — three independent signals, because a missing TLS flag produces one of
the most confusing errors in this stack.

> ⛔ **Never run `backend/schema.sql` against this database.** It is a
> from-scratch script and the live data — real accounts, wallets, venues, booking
> history — is in there. Schema changes go through `backend/migrations/0XX_*.sql`
> plus their runner, and only ever forward.

## Migration history
| # | File | Wave | What it added |
|---|---|---|---|
| 001–009 | `001_fix_schema` … `009_no_show_job_and_admin` | pre-sprint | Base schema corrections, venue media/amenities, slot-lock columns, payment rules, wallets, owner booking updates, admin + venues, no-show groundwork |
| 010 | `010_escrow_policy_alignment` | S1-A | `escrow_policy` table (20% deposit / 24 h window), `notifications`, no-show idempotency columns |
| 011 | `011_slot_locks` | S1-B | `slots.locked_by` / `locked_until` — 5-minute checkout holds (ER1.5 / FR3.7) |
| 012 | `012_hardening_indexes` | S1-C | Performance indexes; only `bookings(venue_id, slot_id)` was genuinely missing |
| 013 | `013_fyp2_foundation` | S1-D | 12 tables for milestones S.2–S.7 (teams/matches/tournaments/chat/settings) + columns + 14 indexes. **27 tables total.** Nothing reads them yet, by design. |
| 014 | `014_withdrawals` | S1-F | `withdrawals` + the partial unique index that enforces one pending request per user |

Each has a `backend/run_migration_0XX.js` runner with machine-checked assertions.
013 and 014 were each verified **idempotent** — run twice, the second run creates
nothing — because a migration you are afraid to re-run is a migration that
silently diverges between environments.

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
| `booking_payment` | Full slot price frozen at booking time |
| `refund` | Refund to player (early cancel, rejection, auto-reject, 80% of a late cancel/no-show) |
| `escrow_release` | Escrow deducted from player frozen balance |
| `escrow_received` | Owner receives money (check-in = full price, no-show / late cancel = 20% deposit) |
| `no_show_penalty` | Player's 20% deposit forfeited for no-show |
| `owner_payout` | Owner withdrew balance |
| `withdrawal` | Withdrawal requested — debited at request time, not at settlement (see `withdrawals`) |

### withdrawals
Added by **migration 014** (Wave F). A deliberate single exception to "no schema
past 013": a withdrawal request needs a durable `pending` state that survives a
restart, and faking it with a `transactions` row would mean re-deriving "is there
a request in flight?" by scanning the ledger on every wallet load.

| Column | Type | Constraints |
|--------|------|-------------|
| id | UUID | PK DEFAULT gen_random_uuid() |
| user_id | UUID | FK→users ON DELETE CASCADE |
| wallet_id | UUID | FK→wallets |
| amount | DECIMAL(10,2) | CHECK (amount > 0) |
| status | TEXT | DEFAULT 'pending', CHECK IN ('pending','completed','failed','cancelled') |
| method | TEXT | DEFAULT 'easypaisa', CHECK IN ('easypaisa','jazzcash','bank') |
| account_name | TEXT | nullable |
| account_number | TEXT | nullable |
| txn_id | UUID | FK→transactions — the debit ledger row |
| requested_at | TIMESTAMP | DEFAULT NOW() |
| completed_at | TIMESTAMP | nullable |
| failure_reason | TEXT | nullable |

Indexes:

| Index | Purpose |
|---|---|
| `uq_withdrawals_one_pending` — **UNIQUE** on `(user_id) WHERE status = 'pending'` | Enforces "one pending withdrawal at a time" **in the database**. A JS check reads, decides, then inserts; two fast taps on a slow connection both read "none pending" and both insert. The partial unique index makes the second insert fail with `23505`, which the route maps to `409`. |
| `idx_withdrawals_user (user_id, requested_at DESC)` | The history list |
| `idx_withdrawals_pending (status, requested_at) WHERE status = 'pending'` | The 24 h settlement sweep in `withdrawalJob.js` |

`status` is a `CHECK` rather than a new enum type: `txn_type` is an enum, but a
`withdrawal_status` enum would force an `ALTER TYPE` path in the migration runner
for no benefit.

**Money timing** — the debit is at request, not at settlement, so you cannot spend
money you have already asked to withdraw. Settlement moves no money at all; it is
bookkeeping. Cancelling writes a **new** `refund` row rather than reversing the
original, because the ledger is append-only.

| Event | `wallets.balance` | `transactions` | `withdrawals.status` |
|---|---|---|---|
| Request | `-= amount` | 1 row `withdrawal` | `pending` |
| Settles (24 h job) | unchanged | none | `completed` |
| Cancelled / failed | `+= amount` | 1 row `refund` | `cancelled` / `failed` |

The hold is a plain `balance` debit and **not** `frozen_balance` —
`frozen_balance` means *booking escrow*, and `GET /api/wallet/frozen` itemises it
per booking. Mixing withdrawal holds in would make that breakdown disagree with
its own total.

## Escrow & Booking Flow (Phase 5)

> The authoritative event → ledger table lives in `ARCHITECTURE.md`
> ("The escrow ledger"). Constants come from `backend/src/utils/escrow.js`.

### 1. Slot Selection (No Locking — Atomic)
- Player selects a slot in the UI. No lock API is called.
- When player taps 'Book Now', the backend uses `SELECT ... FOR UPDATE` to atomically claim the slot.
- If two players book the same slot simultaneously, the second gets a 409 conflict error.
- No `temporarily_locked` status is ever set. No timer needed.

### 2. Booking Creation (Escrow Freeze)
1. Backend verifies slot is `available` under row-level lock.
2. Full slot price `P` deducted from player's `wallets.balance`.
3. Same amount added to player's `wallets.frozen_balance` (escrow) → `bookings.security_deposit`.
4. `bookings.deposit_amount = 0.20 × P` is computed server-side (clients never send an amount).
5. Booking created with status: `pending`, `owner_id` populated.
6. Slot status changes to `booked`.
7. `booking_payment` transaction recorded.

### 3. Owner Approval
- Owner sees booking in Pending tab with player trust score.
- **Approve** → booking status: `confirmed`, `approved_at` set; money stays frozen.
- **Reject** → booking status `rejected`; full escrow refunded to `balance`; slot freed; `refund` transaction.
- **`autoApproveJob`** (every 5 min, FR4.10): pending >2h with the slot still >2h
  away → auto-confirm; slot starting within 2h and still unapproved → `rejected`
  + full refund. Both stamp `auto_decided_at`.

### 4. QR Check-in (Settlement)
When player arrives and owner scans QR (`POST /owner/scan-qr`):
1. `player.frozen_balance -= P` → `owner.balance += P`.
2. `escrow_release` (player) + `escrow_received` (owner) transactions created.
3. Booking status → `checked_in`.

### 5. No-Show (30-minute rule)
`noShowJob` sweeps every 5 min for `confirmed` bookings whose slot started more
than 30 minutes ago with no check-in. `POST /owner/no-show/:id` is the owner's
early trigger for the same ledger move.
1. Player `balance += 0.8P`, `frozen_balance -= P`; owner `balance += 0.2P`.
2. `player_profiles.trust_score -= 10`.
3. `refund` + `no_show_penalty` (player) + `escrow_received` (owner) transactions.
4. Booking status → `no_show`, `no_show_at` set, `no_show_processed = true`
   (idempotency guard so the sweep and the button can never double-settle).
5. A `notifications` row is written for the player and the owner.

### 6. Cancellation (24-Hour Policy)
**Early** (>= 24 hours before slot):
- Full escrow refunded to player `balance`. `refund` transaction. Slot freed.

**Late** (< 24 hours before slot):
- Player gets 80% back, the 20% `deposit_amount` goes to the owner.
  `refund` + `escrow_release` (player) + `escrow_received` (owner) transactions.
  `cancellation_reason = 'late_cancellation'`. Slot freed.

Legacy rows that only froze 30% of the price are safe: the penalty is always
`min(deposit_amount, security_deposit)`, so a refund can never exceed what was
actually frozen.

### 7. Dynamic Slot Filtering
- Past time slots never shown (filtered at API level using PKT time).
- Today's slots: only `start_time > current PKT time` returned.
