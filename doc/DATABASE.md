# Database Schema — PostgreSQL

## Connection
**Supabase is the only database** — the same instance serves local development
and the deployed Render API. A `localhost:5432/sportlynk` line is still commented
out at the top of `backend/.env`, but that copy is **stale** (last written before
Wave A) and is neither a backup nor a fallback. There is one live database.

Use the **session pooler** URI from Supabase → Project Settings → Database in
`backend/.env` as `DATABASE_URL`. The direct `db.<ref>.supabase.co` host is
IPv6-only on the free tier and does not resolve from every network (including
Render's outbound IPv4).

`?sslmode=require` is **optional — the URL works with or without it.** TLS is
decided by `src/db/pool.js` from three independent signals: `sslmode=` in the URL,
`NODE_ENV`, or the host simply not being localhost. But pool.js then *strips*
`sslmode=` before handing the URL to pg, and it has to: in pg 8.20
`pg-connection-string` parses `sslmode=require` as an alias for `verify-full`, and
that parsed value **overrides** the `ssl: {rejectUnauthorized:false}` the pool
passes, so the connection dies on `self-signed certificate in certificate chain`.
Measured on this database: `sslmode=require` fails, no `sslmode` connects,
`sslmode=no-verify` connects.

> ⛔ **Never run `backend/schema.sql` against this database.** It is a
> from-scratch script and the live data — real accounts, wallets, venues, booking
> history — is in there. Schema changes go through `backend/migrations/0XX_*.sql`
> plus their runner, and only ever forward.

## Migration history
| # | File | Wave | What it added |
|---|---|---|---|
| 001–009 | `001_fix_schema` … `009_no_show_job_and_admin` | pre-sprint | Base schema corrections, venue media/amenities, slot-lock columns, payment rules, wallets, owner booking updates, admin + venues, no-show groundwork |
| 010 | `010_escrow_policy_alignment` | S1-A | `notifications`, escrow columns on `bookings` (`security_deposit`, `deposit_amount`, `upfront_percent` default 20, no-show idempotency), `venues.upfront_percent`. Despite the filename it creates **no `escrow_policy` table** — the 20% / 24 h policy lives in `src/utils/escrow.js` → `POLICY`, not in a settings row. |
| 011 | `011_slot_locks` | S1-B | `slots.locked_by` / `locked_until` — 5-minute checkout holds (ER1.5 / FR3.7) |
| 012 | `012_hardening_indexes` | S1-C | Performance indexes; only `bookings(venue_id, slot_id)` was genuinely missing |
| 013 | `013_fyp2_foundation` | S1-D | 12 tables for milestones S.2–S.7 (teams/matches/tournaments/chat/settings) + columns + 14 indexes. Nothing reads them yet, by design. |
| 014 | `014_withdrawals` | S1-F | `withdrawals` + the partial unique index that enforces one pending request per user |
| 015 | `015_teams_chat` | S2-A | `chat_channel_members`, `chat_reactions`, 31 columns and 11 indexes that only became necessary once the team endpoints and the chat UI were written — including the per-sport unique team name FR2.1 asked for and nothing enforced |
| 016 | `016_matches_elo` | S2-B/C | 14 columns + 7 indexes for the match lifecycle and the ELO ledger: the `matches.status` CHECK, the one-submission-per-team key, and `elo_applied` as the exchange latch |
| 017 | `017_reviews_moderation` | S4-C | `review_flags` (the moderation queue, FR9.9) + 4 indexes; the Trust Score 2.0 cold-start baseline |
| 018 | `018_assistant` | S6-C | `assistant_kb`, `assistant_escalations`, `assistant_turns`, `assistant_feedback` + 12 indexes — Scout's session state, so a slot-filling machine can hold a conversation across turns |
| 019 | `019_tournaments` | S7-A | The tournament module. **Adds nothing new to `public`'s table count** — 013 already created `tournaments`, `tournament_teams` and `fixtures`, and nothing had ever read them. 019 is 38 `ADD COLUMN IF NOT EXISTS` (20 on `tournaments`, 5 on `tournament_teams`, 7 on `fixtures`, 4 counters on `teams`, `matches.tournament_id`, `transactions.tournament_id`), 16 guarded CHECK/UNIQUE constraints, 7 indexes, **3 new `txn_type` values** (`tournament_entry`, `tournament_prize`, `tournament_commission`) and one `global_settings` row |

**28 tables in `public` after 014** (27 after 013, plus `withdrawals`), **35 after 018**
(015 adds 2, 017 adds 1, 018 adds 4), and **still 35 after 019** — the tournament
module needed columns and constraints, not tables.

The 014 census was verified against Supabase on 2026-08-21: all 12 of 013's tables
present, 010's 5 escrow columns present, `uq_withdrawals_one_pending` present as a
partial unique index on `status='pending'`, and all 31 key columns typed `uuid`.
**019 has NOT been applied to any database yet** — the SQL and its runner are written
and reviewed, and nothing in this section has been confirmed live.

Each has a `backend/run_migration_0XX.js` runner with machine-checked assertions.
013 and 014 were each verified **idempotent** — run twice, the second run creates
nothing — because a migration you are afraid to re-run is a migration that
silently diverges between environments.

> One caveat learned the hard way: **a green assertion report does not say which
> database it ran against.** Migration 013's runner was reported twice as "applied
> to Supabase" when `DATABASE_URL` was still pointing at localhost. Check the host
> before trusting the ticks.

## Maintenance scripts

All run from `backend/`, all against whatever `DATABASE_URL` points at.

| Script | Destructive? | What it is for |
|---|---|---|
| `src/scripts/add_future_slots.js` | **No** — only inserts | Keeps every active venue supplied with bookable slots. Without future slots nothing can be booked and no acceptance script can run. Idempotent via `NOT EXISTS (venue_id, slot_date, start_time)` — `slots` has **no unique constraint** on that triple, so the guard is the only thing preventing duplicates. `--days N` `--venue <uuid>` `--from H --to H` `--dry`. |
| `src/scripts/reconcile_wallets.js` | Yes, with `--apply` (dry-run by default) | Repairs drift between `wallets.frozen_balance` and `SUM(bookings.security_deposit)` over `pending`/`confirmed` bookings. Releases over-frozen escrow with a `refund` ledger row; **reports but never fixes** under-frozen. |
| `src/scripts/check_tournaments.js` | **No** — one transaction, always `ROLLBACK` | The S.7 Wave A acceptance harness: 10 blocks over configuration refusals, the economics quote, entry fees and refunds, the under-minimum refund-all, the draw and the waterfall, results/K-by-stake/podium, a 5-team field with byes, round robin, the match-flow door, and a closing ledger audit. `--evidence` writes `doc/tournament_evidence.md`; `--verify-clean` re-checks that nothing was left behind. |
| `seed_tournament_demo.js` | **Yes**, with `--undo` | 8 teams with funded wallets and a 2-minute registration deadline, so the deadline job can be watched drawing a real bracket. Idempotent; `--verify` re-reads what it made. |
| `src/scripts/seed_venues.js` | **Yes** — deletes the first owner's venues, slots, bookings and their transactions | Rebuilds the 10 demo grounds. Releases any escrow those bookings held *before* deleting them, prints a delete summary, and waits 5 s for `Ctrl-C` (`--yes` skips). |

### The escrow invariant

```
wallets.frozen_balance  ==  SUM(bookings.security_deposit)
                            WHERE player_id = user AND status IN ('pending','confirmed')
```

`security_deposit` — **not** `total_amount` — is the authority on what is in
escrow for a booking. Both cancel paths, check-in and the no-show job all release
exactly that column, and `GET /api/wallet/frozen` itemises it. The two are equal
for any booking made under Wave A's rules (escrow = full slot price) and differ on
rows created under the old 30% rule.

`GET /api/wallet/frozen` returns `delta` as a live check on this invariant; it
should read 0. It did not for a long time: `seed_venues.js` deleted bookings
without unwinding the escrow they held, stranding PKR 11,100 across two wallets.
Both the cause and the damage are fixed — see PROGRESS.md, "Post-wave fixes".

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
| tournament_id | UUID | FK→tournaments (nullable) — added by **019**; a row carries one context or neither |
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
| `tournament_entry` | Entry fee **frozen** at registration (019) — `balance −E`, `frozen +E` |
| `tournament_commission` | Organiser's earning at the draw: the reserved venue hours **plus** the margin |
| `tournament_prize` | The prize pool — held in the organiser's `frozen` at the draw, then credited to the champion's and runner-up's captains at the final. Logged **positive both times**; the `description` says which |

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

### tournaments
Created bare by **013**, made real by **019** (S.7 Wave A). One row is an owner's cup
at one of their own venues. The four `*_percent` columns and the four `*_amount`
columns are the whole economic contract: the percentages are **copied onto the row at
create time** rather than read live at payout, so an admin editing
`global_settings.tournament` cannot rewrite the terms of a tournament that is already
holding eight captains' entry fees.

| Column | Type | Note |
|---|---|---|
| id · owner_id · venue_id | UUID | 013. `owner_id`→`users`, `venue_id`→`venues` |
| name · sport · format | text | 013. `format` CHECK `knockout \| round_robin` (019) |
| description | text | 019 |
| entry_fee | numeric | 013. What one team pays, once |
| max_teams · min_teams | int | `max_teams` 013; `min_teams` 019 DEFAULT 4. CHECK: power of 2 for knockout, ≤ `max_round_robin_teams` for a league, and `min_teams ≤ max_teams` |
| requires_approval | boolean | 019 DEFAULT false — false lands a registration straight on `accepted` |
| registration_deadline | timestamptz | 013. The deadline job's trigger (FE-4) |
| start_date | date | 013. **Corrected at generation** to the date the bracket actually landed on |
| status | text | 013. CHECK `open \| active \| completed \| cancelled` (019) |
| rounds | int | 019. `log2(bracket size)`, written at generation |
| slot_minutes | int | 019 DEFAULT 60 — one fixture's length |
| prize_percent · winner_percent · runnerup_percent | int | 019 DEFAULT 60 / 70 / 30. CHECK 0–100, and winner + runner-up = 100 |
| venue_discount_percent | int | 019 DEFAULT 0 — the owner's lever on their own inventory |
| pool_amount · venue_cost_amount · prize_amount · owner_earning_amount | numeric(10,2) | 019, all `DEFAULT 0` and CHECK `>= 0`. Zero until the draw; from then on the **settled** figures the ledger actually moved. `pool = venue_cost + prize + margin` |
| winner_team · runner_up_team | UUID | 019 →`teams` |
| fixtures_generated_at | timestamptz | 019. **The generation latch** — the one column that makes drawing a bracket twice impossible |
| activated_at · completed_at · cancelled_at · cancel_reason | timestamptz / text | 019 |
| created_at | timestamptz | 013 |

### tournament_teams
One row is "this team is in this cup". `UNIQUE (tournament_id, team_id)` from 013.

| Column | Type | Note |
|---|---|---|
| id · tournament_id · team_id | UUID | 013, `tournament_id` `ON DELETE CASCADE` |
| status | text | 013, CHECK `registered \| accepted \| rejected \| withdrawn \| eliminated` (019). `registered` = **paid, awaiting approval**; both it and `accepted` hold money, so capacity counts **both** |
| seed | int | 019. Written at generation, ELO-descending |
| paid_amount | numeric(10,2) | 019 DEFAULT 0, CHECK `>= 0` — what was actually frozen, so a refund can never exceed it |
| approved_at · withdrawn_at | timestamptz | 019 |
| eliminated_round | int | 019. Which round ended their run |
| created_at | timestamptz | 013 |

### fixtures
The bracket. `(round, position)` locates a node, 1-based; `team_a`/`team_b` are NULL
until the previous round resolves and feeds them.

| Column | Type | Note |
|---|---|---|
| id · tournament_id | UUID | 013, `ON DELETE CASCADE` |
| round · position | int | 013. `UNIQUE (tournament_id, round, position)` + CHECK `>= 1` (019) |
| team_a · team_b · winner | UUID | 013 →`teams`. CHECK `team_a <> team_b` (019) |
| score_a · score_b | int | 013. CHECK: a `played` fixture **must** have both, and neither may be negative (019) |
| status | text | 013. CHECK `upcoming \| played \| walkover \| cancelled` (019) |
| played_at | timestamptz | 013 |
| match_id | UUID | 019 →`matches`. Set by either settlement door |
| slot_id | UUID | 019 →`slots` `ON DELETE SET NULL`. **A reservation, not a booking** — the slot flips to `blocked` and `uq_fixtures_slot_id` (partial unique) makes two fixtures on one hour impossible |
| scheduled_at | timestamptz | 019 |
| label | text | 019 — "Final", "Semi-final", "Round 1" |
| is_bye | boolean | 019 DEFAULT false. CHECK: a bye has `team_a` and **`team_b IS NULL`** — without it, `is_bye = true` with two teams would advance a side that never played |
| next_round · next_position | int | 019. Where the winner goes; NULL means this is the final |

**Indexes added by 019:** `uq_fixtures_slot_id` (unique, partial on `slot_id IS NOT NULL`),
`idx_fixtures_match`, `idx_fixtures_sched`, `idx_matches_tournament`,
`idx_transactions_tournament`, `idx_tournaments_due` (partial on
`status='open' AND fixtures_generated_at IS NULL` — the deadline job's candidate scan),
`idx_tournaments_owner`.

**019 also touches three existing tables:** `teams` gains `tournament_played`,
`tournament_wins`, `finals_reached`, `titles` (all `int NOT NULL DEFAULT 0`, CHECK
`>= 0`) — the counted achievements that stand in for a second ELO ladder;
`matches` gains `tournament_id` plus `chk_matches_one_context`, because a match is a
booked friendly **or** a tournament fixture, never both; `transactions` gains
`tournament_id` so the ledger is auditable per cup.

**`global_settings.tournament`** (inserted by 019, 14 keys): `min_teams` 4,
`prize_percent` 60, `winner_percent` 70, `runnerup_percent` 30,
`venue_discount_percent` 0, `slot_minutes` 60, `round_gap_days` 1,
`round_rest_minutes` 60, `max_knockout_teams` 32, `max_round_robin_teams` 6,
`target_margin_percent` 25, `k_early` 40, `k_semi` 48, `k_final` 56. The three K
values sit next to `elo.k_factor` (32, friendlies) so the whole ladder is one place.

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
