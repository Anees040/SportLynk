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
| 020 | `020_notifications_admin` | S7-C/D | Turns `notifications` from a write-only log line into a feed row, and adds the two tables Wave D audits through. **25 `ADD COLUMN IF NOT EXISTS`** (16 on `notifications`, 4 on `users`, 5 on `disputes`), **2 new tables** (`user_devices`, `admin_audit`), 11 indexes and a backfill. Two of those changes are corrections, not features: `notifications.created_at` is converted `TIMESTAMP → timestamptz` (`USING created_at AT TIME ZONE 'UTC'`, guarded by an `information_schema` check so it is idempotent) because 010 stored it naive and "2 hours ago" was wrong by the server's offset; and `users.notification_prefs` exists so a preference is enforced server-side in `pushJob` rather than honoured by the client. The plan called for an `idx_chat_messages_channel_created`; recon found `idx_chat_messages_channel` is **already** `(channel_id, created_at DESC)` — the exact index the chat list's unread LATERAL uses — so a second index over the same columns under another name would be dead weight on every write, and it was deliberately not created |
| 021 | `021_dispute_ruling_labels` | S7-D | Two label vocabularies that 020 could not widen, because both are enforced by objects `ADD COLUMN` cannot touch: `chk_elo_history_reason` is dropped and recreated with `admin_reversal` and `admin_ruling` alongside `match_verified`/`frozen_no_change`, and `ALTER TYPE txn_type ADD VALUE 'platform_commission'` (which needs its own `-- @@SPLIT@@` chunk — a new enum value is not usable in the same transaction that added it). Separate from 020 because **020 was already applied**, and editing an applied migration rewrites history: the next person to run the chain from scratch would get a different 020 than this database has, invisibly |
| 022 | `022_elo_history_correction` | S7-D | One index, replaced. 016 created `ux_elo_history_team_match UNIQUE (team_id, match_id) WHERE match_id IS NOT NULL` and its runner asserts "one rating row per team per match" — correct while the only writer was `elo.applyResult`. An admin overturning a ruling writes a **second** row per team (the reversal) and then a third (the new exchange), so the key becomes `(team_id, match_id, reason)`. The double-apply guard is unchanged: it was always `matches.elo_applied`, and the index was only ever its database-level echo |

**28 tables in `public` after 014** (27 after 013, plus `withdrawals`), **35 after 018**
(015 adds 2, 017 adds 1, 018 adds 4), **still 35 after 019** — the tournament module
needed columns and constraints, not tables — and **37 after 020** (`user_devices`,
`admin_audit`). 021 and 022 add no tables and no columns: one CHECK constraint, one enum
value, one index.

The 014 census was verified against Supabase on 2026-08-21: all 12 of 013's tables
present, 010's 5 escrow columns present, `uq_withdrawals_one_pending` present as a
partial unique index on `status='pending'`, and all 31 key columns typed `uuid`.
**019 through 022 are all applied to Supabase** (019 and 020 on 2026-08-30, 021 and 022
on 2026-08-31) and `node src/scripts/verify_schema.js` reports **233/233** across the
019 and 020 censuses. Wave A originally shipped on `npm test` alone with 019 unapplied,
which is why no endpoint answered and no check script could run; every wave since has
been gated on the migration landing first.

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

### notifications
Created by **010**, made readable by **020** (S.7 Wave C). Before 020 this table was
**write-only**: ~33 call sites inserted into it and nothing read it. The columns below
are not decoration on a working feature — they are the difference between a row that can
only be printed and a row that can be grouped, filtered, opened, expired and pushed.

| Column | Type | Note |
|---|---|---|
| id · user_id · booking_id | UUID | 010 |
| type | text | 010 `VARCHAR(40)`, widened by 020. The key into `utils/notificationTypes.js` — **45 registered types**, asserted at boot |
| title · body | text | 010 |
| payload | jsonb | 010. The ids the deep link needs |
| is_read | boolean | 010 |
| created_at | **timestamptz** | 010 stored it bare `TIMESTAMP`; 020 converts it `USING created_at AT TIME ZONE 'UTC'`. Until then "2 hours ago" was wrong by the server's offset, against the UTC-storage golden rule |
| read_at · dismissed_at | timestamptz | 020. "When" is a different fact from "whether", and **dismiss ≠ read** |
| category | text | 020, CHECK over 10 values. The unit a user opts out of, and the filter chips |
| priority | text | 020, CHECK `high \| normal \| low`. Decides whether FCM fires at all and whether it is a heads-up |
| group_key · group_count | text · int | 020. The collapse: "Ali sent 3 messages" is one row and one tray banner |
| deep_link | jsonb | 020. The route **and its args**, computed server-side from the registry so client and server cannot drift |
| actor_id · image_url | UUID · text | 020. Who caused it, with their avatar — the row reads like a person, not an event |
| entity_type · entity_id | text · UUID | 020. The polymorphic target of the tap |
| expires_at | timestamptz | 020. A challenge alert past its 48 h TTL must not render as actionable, and is never pushed |
| sent_push · push_attempts · pushed_at · push_error | bool · int · timestamptz · text | 020. **The outbox state** — and the answer to "why didn't my phone buzz?", from SQL |

**The row is the outbox.** `notify()` runs inside money transactions holding `FOR UPDATE`
locks, so an inline HTTPS call to FCM would hold row locks across a network round trip.
Instead `sent_push = false` **is** the queue and `jobs/pushJob.js` drains it on a ~4 s
tick — atomic with the money, crash-safe, retryable, and zero changes to the 33 existing
call sites.

Indexes (020): partial `idx_notifications_unread (user_id, created_at DESC)
WHERE is_read = false AND dismissed_at IS NULL` (for an active user this holds a handful
of rows out of thousands); partial `idx_notifications_outbox (created_at)
WHERE sent_push = false` (**empty when the queue is drained, so the 4-second scan costs
nothing**); `idx_notifications_category (user_id, category, created_at DESC)`; and
`ux_notifications_group UNIQUE (user_id, group_key) WHERE group_key IS NOT NULL AND
is_read = false AND dismissed_at IS NULL`. That last one is UNIQUE rather than a lookup
because it is what makes `notify()`'s `ON CONFLICT` upsert atomic — two chat messages in
the same millisecond produce one row reading "2 new messages" instead of two rows or a
lost update. Its predicate must match the `ON CONFLICT … WHERE` clause exactly for
Postgres to infer it, and read/dismissed rows are out of it on purpose: once you have
seen a collapsed row, the next message must start a fresh one.

### user_devices
**020.** One row per phone. `users.fcm_token` (012) is one-token-per-user — "last login
wins" — which breaks the instant you use a phone *and* an emulator, and cannot record a
token as dead. FCM rotates tokens without warning and answers
`registration-token-not-registered` for a dead one; that must revoke **one device**, not
log you out everywhere. `users.fcm_token` is still written on device register and still read as a last-resort fallback when a user has no live device row, so migration 012's one-token world keeps working.

| Column | Type | Note |
|---|---|---|
| id · user_id | UUID | `user_id` → `users` ON DELETE CASCADE |
| fcm_token | text | **UNIQUE** (`ux_user_devices_token`) |
| platform | text | CHECK `android \| ios \| web` |
| app_version · device_label | text | What the support answer is made of |
| created_at · last_seen_at | timestamptz | |
| revoked_at · revoke_reason | timestamptz · text | **Revoked, not deleted** — "this phone stopped getting notifications last Tuesday" is answered rather than guessed at |

The UNIQUE on the token is a correctness rule, not a tidiness one: a token identifies a
device *installation*, globally, so if it reappears under a different user (a shared
phone, a reinstall after a logout) the row must **move**, not duplicate — otherwise the
previous owner keeps receiving the new owner's notifications, which is a privacy failure
and not merely a bug. It is also what lets the register endpoint be a single
`ON CONFLICT` upsert. Send path: `idx_user_devices_user (user_id) WHERE revoked_at IS
NULL` — every live device for one user in one indexed read.

### admin_audit
**020.** One table behind **every** admin write: dispute ruling, suspend, reinstate,
settings change, venue approval. "Who changed this, and what did it look like before?" is
the first question anyone asks about an admin panel, and before this there was no way to
answer it — the ruling, the suspension and the commission change all just happened.

| Column | Type | Note |
|---|---|---|
| id · admin_id | UUID | `admin_id` → `users` ON DELETE SET NULL — the log outlives the account |
| action | text | e.g. `dispute_ruled`, `user_suspended`, `settings_changed` |
| entity_type · entity_id | text · UUID | |
| before · after | jsonb | **jsonb, not columns**: five writes touch five different shapes, and a row that stores the whole prior state can answer a question nobody thought to add a column for |
| note | text | The admin's own sentence. For a ruling it is required, and the teams are shown it |
| created_at | timestamptz | |

Indexes: `idx_admin_audit_created (created_at DESC)` — an audit log is only ever read
backwards; `idx_admin_audit_entity (entity_type, entity_id, created_at DESC)` —
"everything ever done to THIS match / THIS user"; `idx_admin_audit_admin (admin_id,
created_at DESC)`.

**Reinstate reads this table back.** It re-lists the venues *that* suspension took down by
reading `after.cascade.venuesDeactivated` off its own audit row (the one read
`idx_admin_audit_entity` exists for) — so a venue the owner had closed themselves before the ban stays
closed. Nothing else is restored: a refunded booking cannot be un-refunded.

**020 also touches two existing tables:** `users` gains `notification_prefs jsonb`
(per-category × in-app/push toggles plus quiet hours, **enforced in the job**) and
`suspended_at` / `suspended_reason` / `suspended_by` — audit columns *around*
`users.is_active` rather than a second `suspended` boolean, because `is_active` is
already checked at login and two flags for one fact is how they diverge. `disputes` gains
`ruling` (CHECK `challenger · opponent · draw · custom · dismissed`),
`ruled_score_challenger`, `ruled_score_opponent` and `severity_elo`.

Two more indexes come with those columns. `idx_users_role_active (role, is_active)`
serves the admin user search, which always filters by both. `idx_disputes_queue
(severity_elo DESC NULLS LAST, created_at) WHERE status = 'open'` **is** the queue's
sort order made durable: `idx_disputes_status` (016) is on `status` alone and cannot
order, so without this one every page of the triage queue sorts the whole open set in
memory to answer “what is most at stake, and what has waited longest”.

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
