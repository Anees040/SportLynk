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
| GET | `/venues/recommended` | `?limit?` (default 20) | `{items: [{...venue, match_pct, reasons[], score}], source, label}` — S.5 model #3 |

> `GET /venues/recommended` is the content-based recommender rail. **`source`** is
> `model` \| `heuristic` \| `unavailable`; the app renders the ✨ Sparkles badge and the
> `match_pct` chip **only** when `source == 'model'`. On the heuristic fallback (ml-service
> down) `match_pct`, `score` and `reasons` come back `null`/`[]` — the client shows no score
> rather than a fabricated one. **`label`** is `"For you"` for a warm profile and `"Popular
> nearby"` for the cold-start (popularity-in-city + stated sports) path. Node caches `model`
> results for 15 min; heuristic results are never cached. Training pulls its snapshot over the
> internal, separately-keyed `GET /api/internal/export/reco-data` (dev-only, not a client
> route — fail-closed auth in TESTING.md §6.12).

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
| GET | `/teams/rankings` | any | `?sport=&city=&limit=` | `{teams:[…], cities:[{city, teams}], sport, city, rankedMinMatches, movementWindowDays}` — **object, not array** (S2-D); ranked teams only, ELO desc |
| GET | `/teams/discover` | any | `?sport=&q=` | `[{…team, member_count}]` — public teams I'm not in, top 60 |
| GET | `/teams/invites/:token` | any | — | `{id, name, sport, logo_url, visibility, member_count}` — preview before joining |
| GET | `/teams/:id` | any¹ | — | `{…team, role, channelId, roster:[…], stats:{…}, eloHistory:[…]}` — `stats`/`eloHistory` added in S2-D |
| PATCH | `/teams/:id` | **captain** | `{bio?, visibility?, city?, logo?}` | `{…team}` — logo re-syncs the chat channel's photo; `city` is only written when the key is present (absent = keep, `''` = clear) and feeds the S2-D leaderboard filter |
| POST | `/teams/:id/invites` | **admin** | `{note?}` | `{id, expires_at, token_prefix, token, link}` — raw `token` returned **once** |
| GET | `/teams/:id/invites` | **admin** | — | `[{id, token_prefix, note, created_at, expires_at, created_by_name}]` |
| DELETE | `/teams/:id/invites/:iid` | **admin** | — | `{revoked:true}` |
| POST | `/teams/join/:token` | any | — | `{teamId, channelId}` or `{teamId, alreadyMember:true}` |
| POST | `/teams/:id/join-request` | any | `{message?}` | `{success, message}` — public teams only |
| GET | `/teams/:id/requests` | **admin** | — | `[{id, user_id, status, message, created_at, name, avatar_url, player_elo}]` |
| PATCH | `/teams/:id/requests/:rid` | **admin** | `{action:'approve'\|'reject'}` | `{status}` |
| PATCH | `/teams/:id/members/:uid` | **captain** | `{action:'remove'\|'captain'\|'vice_captain'\|'member'}` | `{updated:true}` |
| DELETE | `/teams/:id/members/me` | member | — | `{left:true}` |
| GET | `/teams/:id/suggested-players` | **admin** | — | `{team:{id, sport, city, homeCity}, ranking:{…}, suggestions:[{userId, name, avatarUrl, sports, bookingsLast30d, hasHomeArea, trustScore, trustBand, trustLabel, matchPct, score, components, eloSource, reasons}]}` — S.5 Wave B (FR2.8) |

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

> **`GET /teams/:id/suggested-players` (S.5 Wave B, FR2.8).** Admin-only. The pool is public,
> active players who play the team's sport, book venues in the team's home city (derived from the
> venues its members actually book — not always the team's `city` field, hence both `city` and
> `homeCity` are returned), and are not already members. Ranked by
> `0.40·sport-fit + 0.25·elo + 0.20·activity + 0.15·zone`; `eloSource` is `team_elo` when the player
> already plays for a rated team, or `trust_proxy` when teamless. Same `ranking{}` semantics as
> `/matches/opponents`: `matchPct`/`score`/`components` are present only when `ranking.available` is
> true, a `null` component means *no input existed* (not zero), and on the fallback path the list is
> ordered by recent activity with `fallbackNote` carrying the client's sentence. There is **no
> per-user invite** — the rail's "Invite" action reuses `POST /teams/:id/invites` with a `note`.

> **Internal ml-service reco endpoints (not client-reachable).** Node calls the FastAPI ml-service
> (`127.0.0.1:8000`, `X-API-Key`) over `POST /reco/players` and `POST /reco/opponents` (candidate pool
> resolved by Node and posted in the body — the phone never calls ml-service, and ml-service never
> touches Postgres), plus `GET /reco/rank-spec` and `GET /health.recoRankSpec` for the frozen contract
> (`reco-rank-v1`, fingerprint `1a6c5f39bf5a2c56`). These are internal like `/reco/venues` and are not
> part of the client API surface; the client sees only the two Node routes above.

> **`POST /reco/refresh` (S.5 Wave C, internal, ml-service).** Drops the registry's cached venue
> recommender so the next `/reco/venues` re-reads `models/reco_latest.joblib`. Needed because the venue
> matrix is fitted **once** at load and cached — after a retrain, the process keeps serving the old
> snapshot until this is called, which during a demo is indistinguishable from "the model didn't change".
> Returns `{success, data:{...describe(), venues, asOf}, message}`. It discards the loaded object **before**
> validating the replacement, so a missing artifact or a feature-fingerprint mismatch answers 503
> `model_not_loaded` here **and** makes `/reco/venues` 503 until the file is fixed — an outage with a
> reason beats silently serving a model whose file on disk has been swapped. Key-gated like every other
> route (`X-API-Key`; the middleware exempts only `/health` and the docs), so a phone cannot reach it and
> Node is the only caller. Full sequence after seeding: `build_reco.py` → `POST /reco/refresh` →
> `eval_reco.py`.

### Rankings, team stats & ELO history — S2 Wave D

`utils/teamStats.js` owns all three reads. **Fields here are snake_case** (they come
straight out of SQL), unlike `/api/matches`, which is camelCase — the two
conventions are both live, and `profileStats()` is the single conversion point.

**`GET /teams/rankings?sport=&city=&limit=`** (FR5.13)

```jsonc
{ "teams": [ {
      "id": "…", "name": "E2E Falcons", "sport": "football",
      "logo_url": null, "city": "Lahore", "member_count": 3,
      "wins": 2, "losses": 1, "draws": 0, "played": 3,
      "rank": 1,
      "movement": 2,          // places gained vs 7 days ago; NULL = new to the board
      "ranked": true,         // FR2.6
      "display_elo": 1018,    // null when !ranked — never the 1000 seed
      "elo_frozen": false,    // ER2.3
      "is_mine": true         // viewer is a member → the "YOU" highlight
  } ],
  "cities": [ { "city": "Lahore", "teams": 4 } ],
  "sport": null, "city": null,
  "rankedMinMatches": 1, "movementWindowDays": 7 }
```

- **Ranked only.** A team appears after `elo.RANKED_MIN_MATCHES` verified matches
  (FR2.6), bound as a query *parameter* from `elo.js` so the board can never
  disagree with a profile. Before Wave D this listed every public team ordered by
  `elo`, which put brand-new teams on the board at the untouched seed. **On a fresh
  install the board is legitimately empty** — that is the correct answer.
- **`movement` is computed, never stored.** There is no rank-snapshot table and no
  nightly job to rot. `elo_history.elo_before` of a team's oldest change inside the
  window *is* the rating it held then (or its current rating if nothing moved); a
  second `row_number()` over that column reconstructs the position it held. `NULL`
  means it was not on the board then — distinct from `0` ("held its place"), so the
  UI can draw **NEW** instead of inventing a climb.
- **`cities` is not city-filtered** on purpose: the chip row must not collapse to
  the chip you just picked. It lists only cities that actually hold ranked teams, so
  a chip can never lead to an empty screen. `teams.city` is still mostly NULL, so
  this correctly degrades to *no chips* rather than chips that go nowhere.
- `is_mine` is answered by the server because only the server knows the viewer. The
  screen used to infer it from a `role` field this endpoint never sent, so the "YOU"
  badge could never appear.

**`GET /teams/:id`** gained two blocks (FR5.14 / FR5.15 / FR5.16):

```jsonc
"stats": {                      // FR5.15 + the S.5 recommender features
  "wins": 2, "losses": 1, "draws": 0, "played": 3, "win_rate": 67,
  "ranked": true, "display_elo": 1018, "elo": 1018, "elo_frozen": false,
  "form": "WLW",                // last 5, NEWEST FIRST, '' before the first match
  "activity_30d": 3, "activity_window_days": 30, "ranked_min_matches": 1
},
"eloHistory": [ {               // last 10 terminal matches, OLDEST FIRST
  "match_id": "…", "at": "2026-08-20T…Z", "status": "completed",
  "verified": true,             // → solid green dot
  "disputed": false,            // → hollow red dot
  "rated": true,                // false = verified but frozen → hollow grey dot
  "opponent_id": "…", "opponent_name": "E2E Titans", "opponent_logo": null,
  "my_score": 2, "their_score": 1,
  "result": "win",              // win | loss | draw | disputed
  "elo_before": 1000, "elo_after": 1018, "elo_delta": 18,
  "elo_at": 1018                // y-position; carried forward across unrated points
} ]
```

- `form` is **not** re-derived here — it comes from `matchCore.teamFeatures()`, the
  same string find-opponents and the match preview read, so a second copy of that
  SQL cannot drift.
- **`eloHistory` is driven by `matches`, LEFT JOINing `elo_history`,** not by
  `elo_history` alone. A disputed match has no history row by design (Wave C: the
  match completes and records W/L, but no points move), so reading history alone
  would silently drop exactly the points FR5.14 asks to display in red. A point with
  no join partner is unrated; it plots at the last known rating (`elo_at`) because a
  drop to zero would read as a collapse. `rated` ships separately from `disputed` so
  a frozen team is never labelled "disputed".
- `activity_30d` counts disputed alongside completed: the question it answers is
  "is this team actually playing?", and a disputed fixture was still played.

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
| server → user room | `match:update` | `{matchId, status, …}` | a match this user is party to moved — re-fetch (S2 Wave C) |
| server → channel | `chat:message` | hydrated message | a new/edited/deleted/reacted message |
| server → channel | `receipt` | `{userId, lastReadAt, lastDeliveredAt}` | move a member's tick watermarks |
| client → server | `typing` | `{channelId, typing}` | drives the "typing…" subtitle |
| client → server | `message:read` | `{channelId, at?}` | socket counterpart of `POST /read` |

Presence ("online" / "last seen") is in-memory in the realtime layer because it is
worthless after a restart; `users.last_seen_at` is persisted on disconnect so a
last-seen survives a deploy.

**`match:update` deliberately never carries the match itself.** One emit goes to
both rosters *and* to the venue owner, and those three audiences have different read
permissions — a team may not see the opponent's submission until both are in, while
the owner may see both. Shipping the row would have to either over-share or ship a
different payload per recipient; instead every client re-reads through the gated
endpoint, so the socket can never become a way around a read gate.

---

## Matches & ELO (Token required) — S2 Waves B + C
Mounted at `/api/matches`. Challenge → play → both captains report → the venue owner
verifies → ratings move. Migration 016 adds `matches`, `match_results`, `disputes`,
`elo_history` and the `teams.elo` counters.

### The state machine — SINGLE SOURCE OF TRUTH
Three copies of this exist and **all three must agree**: this table, the
`chk_matches_status` CHECK constraint in `migrations/016_matches_elo.sql`, and
`matchCore.STATUS` in code.

```
  challenge_sent ─(opponent captain accepts)──→ accepted
        │                                          │
        │(reject, or 48h expiry — FR5.12)          │(both captains submit,
        ↓                                          │ submissions agree)
  rejected | expired                                ↓
                                             awaiting_owner
        ┌────────────────────────────────────────┐  │
        │(submissions conflict — ER2.1)          │  │(venue owner verifies:
        ↓                                        │  │ ELO exchange runs — ER2.2)
     disputed ←──(either captain, within 24h)────────completed
        │                                            FR5.17
        └─(admin resolves — S.7)──→ completed
```

| Status | Meaning | Who can move it |
|---|---|---|
| `challenge_sent` | waiting on the opponent captain; dies at 48h | opponent captain, or `matchExpiryJob` |
| `accepted` | on. Results open once the slot's start time passes | either captain (one submission each) |
| `awaiting_owner` | both captains reported the **same** score | the venue owner of the linked booking |
| `completed` | verified; ELO exchanged, `elo_history` written | terminal (a dispute can reopen it) |
| `rejected` / `expired` | never played; the booking is released for reuse | terminal |
| `disputed` | reports conflicted, or a captain flagged inside 24h | admin only (S.7) — **ELO is blocked meanwhile** |

### Endpoints
| Method | Endpoint | Auth | Body / Query | Response |
|--------|----------|------|--------------|----------|
| GET | `/matches/opponents` | member | `?teamId=&q=` | `{myTeam, myRole, canChallenge, preferredBand, ranking:{…}, opponents:[{team, eloGap, withinBand, competitiveness, matchPct, rankScore, components, reasons, matchesLast30d}]}` — S.5 Wave B re-ranking (FR5.3–5.5) |
| GET | `/matches/preview` | member | `?challengerTeam=&opponentTeam=` | `{challenger, opponent, competitiveness, previewText, previewLabel:'Preview', eloGap, withinPreferredBand}` (FR5.4/FR5.10) |
| GET | `/matches/linkable-bookings` | **captain** | `?teamId=` | `[{id, slotDate, startTime, endTime, venueName, sportType, totalAmount}]` — my **confirmed, future** bookings with no live match (FR5.11) |
| POST | `/matches/challenge` | **captain** | `{challengerTeam, opponentTeam, bookingId}` | the match — expires in 48h, competitiveness + preview snapshotted onto the row |
| GET | `/matches` | member | `?team_id=` | `{teamId, myRole, challenges:{incoming, outgoing}, upcoming, history, disputeWindowHours}` (FR5.16) |
| GET | `/matches/:id` | party¹ | — | `{…match, myRole, submissions, iSubmitted, disputeWindowHours}` |
| PATCH | `/matches/:id/respond` | **opponent captain** | `{action:'accept'\|'reject'}` | the match — accept notifies both rosters (FE-4) |
| POST | `/matches/:id/result` | **captain** | `{scoreChallenger, scoreOpponent, winnerTeam?}` | the match — **one submission per team, ever** (ER2.1) |
| PATCH | `/matches/:id/verify` | **venue owner** | — | `{…match, elo:{frozen, reason, kFactor, challenger, opponent}}` (ER2.2) |
| POST | `/matches/:id/dispute` | **captain** | `{reason}` (≥10 chars) | the match, now `disputed` — within 24h of completion (FR5.17) |
| GET | `/matches/owner/pending` | **owner** | — | `[{…match, submissions:[{teamId, teamName, winnerTeam, scoreChallenger, scoreOpponent, submittedAt}]}]` — `awaiting_owner` on **my** venues |

¹ a member of either team, **or** the owner of the linked venue.

> **`GET /matches/opponents` ranking (S.5 Wave B).** The `ranking{}` block —
> `{source, available, specVersion, specFingerprint, weights, componentOrder, activityWindowDays,
> fallbackNote}` — says which path ran. When **`source == "ranked"`** (`available:true`) the list is
> ordered by a weighted match score (`0.60·elo-proximity + 0.20·trust + 0.20·activity`): each row
> carries `matchPct`, `rankScore`, a `components{elo,trust,activity}` map and `reasons[]`.
> `competitiveness` equals `matchPct` when **both** teams are ranked and is `null` when either is
> unranked (FR2.6) — the card prints "Unranked" but the team is **still ranked** in the list (ELO term
> → neutral prior). A `null` component means *no input existed* and is **not** zero. When the scorer is
> unavailable the response falls back to the v1 `|ΔELO|`-ascending sort (`source != "ranked"`,
> `available:false`): `matchPct`/`rankScore`/`components` come back `null`/`[]`, `withinBand` marks the
> ±band boundary, and `fallbackNote` carries the sentence the client shows instead of a score.

**Guard rails (all `{success:false, message}`):**

| Condition | Status | Why |
|---|---|---|
| booking not `confirmed`, not mine, or in the past | 400 | FR5.11 — a match must be pinned to a real, paid, future slot |
| booking already has a live match | 409 | `ux_matches_booking_live` partial unique index — a JS pre-check can't stop two simultaneous POSTs |
| the two teams play different sports | 400 | cross-sport ratings would be meaningless |
| challenging yourself, or >10 challenges out | 400 / 429 | a challenge pins a booking and pings a captain; uncapped it is a spam vector |
| accepting after `challenge_expires_at` | 409 | the sweep may not have run yet — expiry is enforced on read, not only by the job |
| second submission from the same team | 409 | `match_results_match_id_submitted_by_team_key` — the one-shot rule (ER2.1). Declared as an inline `UNIQUE (match_id, submitted_by_team)` in 013, so Postgres named it; that generated name is what the 409 keys on |
| submitting before the slot's start time | 400 | you cannot report a match that has not begun |
| owner verifying a match on someone else's venue | 403 | ownership is checked **in SQL** (`v.owner_id = $1`), not from the body |
| verifying a `disputed` match | 409 | the S.7 backstop — a contested result never moves ratings |
| a `winnerTeam` that disagrees with the scores | 400 | the server derives the winner; the field is a cross-check, not an input |

**The ELO exchange is one transaction** (Wave B). On verify, inside the same commit
as the status change: both teams' `elo` (+ legacy `elo_rating` in lockstep),
`wins/losses/draws`, and **exactly two `elo_history` rows** whose deltas net to zero.
`utils/elo.js` is pure — no database import — so the arithmetic is unit-tested
without a connection (`npm test`, 10 tests).

**A team is "Unranked" until it has ≥1 verified match** (FR2.6). The API sends
`ranked:false` and the UI prints *Unranked* rather than the seed 1000, because a
number nobody has earned reads as a claim. Competitiveness is
`round(100 − (min(|eloA − eloB|, 400) / 400) × 95)` → 5–100, and is `null` (not 50,
not 0) when either side is unranked.

**Ratings can be frozen.** A team whose dispute ratio exceeds 30% over ≥3 matches has
its rating frozen platform-wide (ER2.3): the match still completes and still records
W/L, but no points move and the response says so in plain words. `global_settings`
holds `elo.base`, `elo.k_factor`, and the match TTL / dispute-window / freeze
thresholds — policy is a row, not a constant in the bundle.

**The venue owner has no pen.** Verify confirms what two captains already agreed;
there is no score-override field. Adjudicating a disagreement is the admin's job
(S.7), and giving the owner an override here would make the "both captains agree"
gate decorative.

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
