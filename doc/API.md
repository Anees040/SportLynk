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

## Teams (Token required) — S2 Wave A
Mounted at `/api/teams`. Every route requires a token. **Authority is membership,
never the request body:** the caller's role is re-read from `team_members` inside
the same locked transaction as the write it authorises, so a forged `{"role":…}`
is never trusted and two writers cannot race the "≥1 captain" invariant (FR2.10).

| Method | Endpoint | Auth | Body / Query | Response |
|--------|----------|------|--------------|----------|
| POST | `/teams` | any | `{name, sport, visibility?, bio?, logo?}` | `{…team, role:'captain', channelId}` — creates the team, its captain row, and the group chat |
| GET | `/teams/mine` | member | — | `[{…team, role, channel_id}]` — my teams, newest first |
| GET | `/teams/rankings` | any | `?sport=` | `[{…team, member_count}]` — public only, ELO desc, top 100 |
| GET | `/teams/discover` | any | `?sport=&q=` | `[{…team, member_count}]` — public teams I'm not in, top 60 |
| GET | `/teams/invites/:token` | any | — | `{id, name, sport, logo_url, visibility, member_count}` — preview before joining |
| GET | `/teams/:id` | any¹ | — | `{…team, role, channelId, roster:[{user_id, name, avatar_url, role, elo, trust_score, joined_at, last_seen_at}]}` |
| PATCH | `/teams/:id` | **captain** | `{bio?, visibility?, logo?}` | `{…team}` — logo re-syncs the chat channel's photo |
| POST | `/teams/:id/invites` | **admin** | `{note?}` | `{id, expires_at, token_prefix, token, link}` — raw `token` returned **once** |
| GET | `/teams/:id/invites` | **admin** | — | `[{id, token_prefix, note, created_at, expires_at, created_by_name}]` |
| DELETE | `/teams/:id/invites/:iid` | **admin** | — | `{revoked:true}` |
| POST | `/teams/join/:token` | any | — | `{teamId, channelId}` or `{teamId, alreadyMember:true}` |
| POST | `/teams/:id/join-request` | any | `{message?}` | `{success, message}` — public teams only |
| GET | `/teams/:id/requests` | **admin** | — | `[{id, user_id, status, message, created_at, name, avatar_url, player_elo}]` |
| PATCH | `/teams/:id/requests/:rid` | **admin** | `{action:'approve'\|'reject'}` | `{status}` |
| PATCH | `/teams/:id/members/:uid` | **captain** | `{action:'remove'\|'captain'\|'vice_captain'\|'member'}` | `{updated:true}` |
| DELETE | `/teams/:id/members/me` | member | — | `{left:true}` |

¹ `GET /teams/:id` returns 403 for a **private** team the caller is not a member of;
a public team's profile is readable by anyone. "admin" = captain **or** vice-captain;
role changes and removal are **captain-only**.

**Guard rails worth knowing (all return `{success:false, message}`):**

| Condition | Status | Message |
|---|---|---|
| duplicate name for the same sport | 409 | A team with that name already exists for this sport. (`ux_teams_name_sport` on `lower(btrim(name)), sport` → 23505; a JS pre-check can't catch two simultaneous POSTs) |
| caller already in `MAX_TEAMS_PER_USER` teams | 429 | You can be in at most N teams. |
| invite token expired / used / revoked | 410 | This invite link has expired or already been used. |
| team at `MAX_TEAM_SIZE` on join/approve | 409 | This team is already full. |
| removing / demoting the **last** captain | 400 | Promote another captain first. (FR2.10 — the team is never left headless) |
| non-admin hits an admin route | 403 | (role re-read inside the locked txn) |

**Invite tokens are hashed at rest.** The server stores `sha256(token)` and a
`token_prefix` (first 8 chars, for labelling the pending-invites list) — never the
token itself, exactly as a password-reset token is handled. The raw token crosses
the wire once, in the `POST /invites` response. `link` is a
`sportlynk://team/join/<token>` deep link the client shares; the join screen also
accepts a bare token pasted in.

**Membership changes fan out three ways, all after COMMIT:** a grey system message
into the team chat ("Ali added Sara"), a `notifications` row + `team:update` socket
ping to the affected user, and a `chat:message` socket event carrying the system
line. A client that re-fetches on `team:update` always sees the committed row.

---

## Chat (Token required) — S2 Wave A
Mounted at `/api/chat`. The REST half of the WhatsApp-style team group chat; the
live half (typing, receipts, presence, message push) is Socket.IO — see **Realtime**
below. **Every handler proves live channel membership before acting** (`left_at IS
NULL`), and every image URL is pinned to Cloudinary by `validateMediaUrl` so a
caller can never make the app fetch an arbitrary host.

| Method | Endpoint | Body / Query | Response |
|--------|----------|--------------|----------|
| GET | `/chat/team/:teamId` | — | `{channelId}` — the entry point the chat screen opens with; 404 to non-members |
| GET | `/chat/:channelId/messages` | `?before=<createdAt>&limit=≤100` | `[{…message, sender_name, sender_avatar, reactions:[{emoji, userId}]}]` — oldest-first; `before` pages backwards |
| POST | `/chat/:channelId/messages` | text: `{kind:'text', body, clientId}` · image: `{kind:'image', mediaUrl, mediaMime?, mediaW?, mediaH?, body?, clientId}` | persisted message — **201** new, **200** if `clientId` already seen (idempotent) |
| POST | `/chat/:channelId/read` | `{at?}` | `{read:true}` — advances the blue-tick watermark (`GREATEST`, never backwards) |
| GET | `/chat/:channelId/members` | — | `[{user_id, role, last_read_at, last_delivered_at, name, avatar_url, last_seen_at}]` |
| POST | `/chat/:channelId/messages/:messageId/reactions` | `{emoji}` | re-hydrated message — same emoji again clears it, a different one replaces it |
| DELETE | `/chat/:channelId/messages/:messageId` | — | tombstone — own message, or **any** message if you're a channel admin |

**Idempotent send.** `clientId` is a client-generated string: the optimistic bubble
the sender already drew is matched to the server row when it echoes back, and a
retry after a dropped response cannot post twice (`ux_chat_messages_client` rejects
it; the route answers 200 with the original). Voice (`kind:'audio'`) is a planned
follow-up and returns **400 "Voice messages are coming soon."** rather than a
constraint 500.

**Reactions** are a closed palette (`👍 ❤️ 😂 😮 😢 🙏 🔥 🎉`) — an arbitrary
string is validated away, because whatever lands here renders on every device that
loads the message.

**Delete-for-everyone strips the payload.** A tombstone keeps the row (so replies
and history stay coherent) but nulls `body`, `media_url`, `media_mime` and
`waveform` — the delete is a real removal, not a client-trusted hide. The client
renders "This message was deleted" from `deleted_at` alone. System messages cannot
be deleted; a repeat delete is an idempotent 200.

### Ticks (single ✓ / double ✓✓ / blue ✓✓)
Two watermarks per member drive the receipts — no per-message × per-member rows:

| Tick | Meaning |
|---|---|
| ✓ sent | the row exists in `chat_messages` (server accepted it) |
| ✓✓ delivered | every **other** member's `last_delivered_at` ≥ the message's `created_at` |
| ✓✓ blue read | every **other** member's `last_read_at` ≥ the message's `created_at` |

The group tick for one of my messages is `MIN(other members' mark)` vs its time —
one aggregate over `chat_channel_members`, computed client-side from the members
list kept current by live `receipt` events.

---

## Realtime (Socket.IO) — S2 Wave A
Attached to the same Express HTTP server (`🔌 Realtime (Socket.IO) attached` at
boot). The client authenticates with its JWT on connect and is auto-joined to a
personal room `u:<userId>`; opening a chat joins `c:<channelId>`.

| Direction | Event | Payload | Purpose |
|---|---|---|---|
| server → user room | `team:update` | `{teamId, left?}` | membership/role changed — re-fetch |
| server → user room | `team:request` | `{teamId}` | a new join request landed (admins) |
| server → channel | `chat:message` | hydrated message | a new/edited/deleted/reacted message |
| server → channel | `receipt` | `{userId, lastReadAt, lastDeliveredAt}` | move a member's tick watermarks |
| client → server | `typing` | `{channelId, typing}` | drives the "typing…" subtitle |
| client → server | `message:read` | `{channelId, at?}` | socket counterpart of `POST /read` |

Presence ("online" / "last seen") is in-memory in the realtime layer because it is
worthless after a restart; `users.last_seen_at` is persisted on disconnect so a
last-seen survives a deploy.

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
