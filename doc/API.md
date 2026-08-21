# API Endpoints — SportLynk REST API

**Base URL:** `http://10.0.2.2:3000/api` (Android emulator) | `http://localhost:3000/api` (web/real device)  
**Auth:** All protected routes require `Authorization: Bearer {JWT_TOKEN}` header  
**Response Format:** All endpoints return `{ success: bool, data?: any, message?: string }`

---

## Auth (No token required)
| Method | Endpoint | Body | Response |
|--------|----------|------|----------|
| POST | `/auth/register/player` | `{name, phone, password, email?, avatarUrl?}` | `{token, user}` |
| POST | `/auth/register/owner` | `{personal, ground, documents}` | `{token, user, status}` |
| POST | `/auth/login` | `{identifier, password}` | `{token, user, status}` |
| POST | `/auth/verify-phone` | `{firebaseUid, phone}` | `{success}` |
| POST | `/auth/forgot-password/send-otp` | `{phone}` | `{success}` |
| POST | `/auth/forgot-password/reset` | `{phone, otp, newPassword}` | `{success}` |
| GET | `/auth/me` | — | `{user}` |

---

## Users (Token required)
| Method | Endpoint | Body | Response |
|--------|----------|------|----------|
| GET | `/users/me/player` | — | `{id, name, email, phone, avatar_url, sport_preferences, elo_rating, trust_score, balance, frozen_balance}` |
| PATCH | `/users/me/update` | `{name?, email?, sportPreferences?, avatarUrl?}` | `{name, email, avatar_url, sport_preferences}` |
| POST | `/users/me/change-password` | `{currentPassword, newPassword}` | `{success, message}` |

---

## Wallet (Token required)
| Method | Endpoint | Query | Response |
|--------|----------|-------|----------|
| GET | `/wallet/me` | — | `{balance, frozen_balance}` |
| GET | `/wallet/transactions` | `limit?, type?` | `[{id, type, amount, balance_after, description, counterparty_name, reference_id, created_at, venue_name, slot_date, start_time, end_time}]` |
| POST | `/wallet/topup` | — | Body: `{amount}` → `{newBalance}` |
| GET | `/wallet/frozen` | — | `{items: [{id, escrow_held, slot_price, slot_date, start_time, end_time, status, venue_name}], itemsTotal, walletFrozen, delta}` |
| GET | `/wallet/withdrawals` | `limit?` | `{items: [{id, amount, status, method, account_name, account_number, requested_at, completed_at, failure_reason}], pending}` |
| POST | `/wallet/withdraw` | — | Body: `{amount, method?, accountName?, accountNumber?}` → `{withdrawal, newBalance}` |
| DELETE | `/wallet/withdraw/:id` | — | `{withdrawal, newBalance}` — cancels a pending request and refunds it |

### `GET /wallet/frozen` (FR7.2)

One row per booking that is currently holding escrow — i.e. `status IN
('pending','confirmed')`, since escrow is released on check-in, cancel, reject and
no-show.

**`escrow_held` is `bookings.security_deposit`, and it is the authoritative
figure** — that is the column the money code releases on every path
(`routes/bookings.js`: *"security_deposit holds what is ACTUALLY in escrow for this
booking"*). `slot_price` is `bookings.total_amount`, returned alongside so the UI
can show what the booking costs. For a Wave-A booking the two are equal, because
booking freezes the full slot price; for a legacy row created under the old 30%
rule they differ, and a row where they disagree is visibly a legacy row.

> This changed on 2026-08-21. `items[].total_amount` was replaced by
> `escrow_held` + `slot_price`. Summing `total_amount` reported "PKR 3,000 frozen
> for this booking" when 900 was actually frozen, and it made `delta` permanently
> non-zero on any database holding a legacy row.

`delta = walletFrozen - itemsTotal` and should be **0**. It is returned rather
than hidden so a mismatch is visible. Now that items itemise the real escrow
figure, a non-zero delta means **genuine drift** — frozen money that no active
booking accounts for — not a unit mismatch. Repair it with
`node src/scripts/reconcile_wallets.js --apply`. Computed server-side rather than
filtered in the client precisely so the comparison can be made against
`wallets.frozen_balance`.

### `POST /wallet/withdraw` (FR7.4 / ER1.6)

| Condition | Status | Message |
|---|---|---|
| `amount < 200` | 400 | Minimum withdrawal is PKR 200. |
| `amount > balance` | 400 | Names the available balance; escrow is not withdrawable. |
| a `pending` request already exists | **409** | You already have a withdrawal in progress. |
| bad `method` | 400 | Mirrors migration 014's `CHECK` so a bad value is a readable 400, not a 500 from constraint `23514`. |
| ok | 201 | `{withdrawal, newBalance}` |

The 409 is enforced by a **partial unique index** (`uq_withdrawals_one_pending ON
withdrawals (user_id) WHERE status = 'pending'`), not by a JS read-then-insert —
two fast taps would both read "none pending" and both insert. The route maps
Postgres error `23505` to the 409.

**Money timing.** The debit happens at **request** time, so you cannot spend money
you have already asked to withdraw:

| Event | Wallet | Ledger | `withdrawals.status` |
|---|---|---|---|
| `POST /withdraw` | `balance -= amount` | 1 row `withdrawal`, `-amount` | `pending` |
| Settles (24 h, `withdrawalJob`) | **nothing moves** | none | `completed` |
| `DELETE /withdraw/:id` | `balance += amount` | 1 **new** `refund` row | `cancelled` |

The refund is a new append-only row, not a reversal of the original — the ledger
keeps both halves of the story. The hold is a plain `balance` debit and
deliberately **not** `frozen_balance`, because `frozen_balance` means *booking
escrow* and `GET /wallet/frozen` itemises it per booking.

---

## Venues (Token required)
| Method | Endpoint | Query/Body | Response |
|--------|----------|------------|----------|
| GET | `/venues` | `city?, sport_type?, search?, min_price?, max_price?, min_rating?, sort?` | `[{venue with rating, photos, amenities}]` |
| GET | `/venues/:id` | `?date=YYYY-MM-DD` | `{venue with slots[]}` |

---

## Bookings (Player token required)
| Method | Endpoint | Body | Response |
|--------|----------|------|----------|
| POST | `/bookings` | `{slotId, venueId, notes?}` | `{booking}` — status: `pending`, money frozen in wallet |
| GET | `/bookings/my` | `?status=` | `[{booking with venue info}]` |
| GET | `/bookings/:id` | — | `{booking with venue, player, qr_code}` |
| PATCH | `/bookings/:id/cancel` | — | `{success, message}` — refund or penalty based on 12hr rule |

---

## Owner (Owner token required)
| Method | Endpoint | Body | Response |
|--------|----------|------|----------|
| GET | `/owner/dashboard` | — | `{venue, stats: {bookingsToday, revenueToday, pendingCount}, upcomingBookings, wallet}` |
| GET | `/owner/bookings` | `?status=pending\|confirmed\|rejected` | `[{booking with player trust_score, sport_preferences}]` |
| PATCH | `/owner/bookings/:id/approve` | — | `{success}` — booking status → confirmed |
| PATCH | `/owner/bookings/:id/reject` | — | `{success}` — booking cancelled, player fully refunded |
| GET | `/owner/slots` | `?date=YYYY-MM-DD` | `[{slot with status}]` |
| PATCH | `/owner/slots/:id/block` | — | `{success}` — blocks available slot |
| PATCH | `/owner/slots/:id/unblock` | — | `{success}` — unblocks blocked slot |
| POST | `/owner/scan-qr` | `{qrCode}` | `{playerName, venueName, slotDate, startTime, endTime, amount, newOwnerBalance}` — transfers escrow to owner |
| POST | `/owner/no-show/:id` | — | `{success}` — forfeits deposit, trust_score -10 |
| GET | `/owner/venue` | — | `{venue}` — owner's primary venue |
| GET | `/owner/analytics` | — | `{monthTotal, weeklyRevenue: [{week_num, revenue, total_bookings}]}` |
| GET | `/owner/venues` | — | `[{venues}]` |
| POST | `/owner/venues` | `{name, description, sport_type, city, address, base_price}` | `{venue}` |
| POST | `/owner/venues/:id/slots` | `{date, slots: [{start_time, end_time, price}]}` | `[{slot}]` |

---

## Escrow & Payment Flow
```
1. Player books slot → Full amount deducted from player.balance → added to player.frozen_balance
   Booking status: 'pending'

2. Owner approves → Booking status: 'confirmed'
   (Or auto-approves after 2 hours — backend cron job)

3. Owner rejects → Player frozen_balance refunded to player.balance
   Booking status: 'cancelled'

4. Player arrives → Owner scans QR code → POST /owner/scan-qr
   player.frozen_balance -= deposit → owner.balance += deposit
   Booking status: 'checked_in'

5. No-show → POST /owner/no-show/:id
   player.frozen_balance -= deposit → owner.balance += deposit
   player trust_score -= 10 | Booking status: 'no_show'

6. Player cancels (>12hrs before) → Full refund to player.balance
   Booking status: 'cancelled'

7. Player cancels (<12hrs before) → Deposit forfeited to owner.balance
   Booking status: 'cancelled'
```

---

## Transaction Types (txn_type enum)
| Type | Meaning |
|------|---------|
| `topup` | Player added money to wallet |
| `booking_payment` | Money frozen for booking |
| `refund` | Money refunded (cancellation or rejection) |
| `escrow_release` | Player's frozen money sent to owner |
| `escrow_received` | Owner received money from player |
| `no_show_penalty` | Player's deposit forfeited for no-show |
| `owner_payout` | Owner withdrew balance |
| `withdrawal` | User requested a withdrawal — debited at request time, not at settlement |
