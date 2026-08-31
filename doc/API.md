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

### The inbox, the other two rooms, mute & AI quick replies — S.7 Wave B
S2 shipped team chat only, and the app could open a room **only if it already knew
the id**. Three things followed from that: `booking` and `captain` were legal in the
`chk_chat_channels_type` CHECK constraint and nothing ever created one, there was no
list, and a room nobody can navigate to might as well not exist.

| Method | Endpoint | Body / Query | Response |
|--------|----------|--------------|----------|
| GET | `/chat` | `?limit=≤50&cursor=<sortAt>&type=booking\|captain\|team` | `{items:[…], nextCursor}` — the inbox, `last_message_at DESC NULLS LAST` |
| GET | `/chat/unread-count` | — | `{total, rooms, byType:{booking,captain,team}}` — the header badge, one trip |
| GET | `/chat/booking/:bookingId` | — | `{channelId}` — 404 to a non-member |
| GET | `/chat/match/:matchId` | — | `{channelId}` — the captain room for that match |
| POST | `/chat/:channelId/mute` | `{muted?:bool, hours?}` | `{muted, mutedUntil}` — floored at 1 h, capped at a year |
| POST | `/chat/:channelId/quick-replies` | `{text}` **or** `{messageId}` | `{suggestions:[{text,intent}], intent, confidence, source}` (FR8.10) |

An inbox row is
`{id, type, refId, title, imageUrl, lastMessageAt, lastMessagePreview,
lastMessageSenderId, lastMessageSenderName, messageCount, unread, muted, mutedUntil,
role, sortAt, context}`.

**`context` is what makes the list readable**, and it is per type: a booking carries
its status, slot date and venue; a captain room its match status, opponent and
scoreline; a team its member count. Without it the three room types are an
indistinguishable list of names.

**`cursor` is `sortAt`, passed back VERBATIM.** It is keyed on the exact expression
the server sorts by, so a room that receives a message mid-scroll cannot make a row
appear twice or vanish. `type='assistant'` (Scout has its own screen) and
`archived_at IS NOT NULL` are excluded. **Muted rooms are counted in the list but not
in the badge** — a badge that counts a conversation you silenced on purpose is why
people switch badges off.

**Who creates the two new rooms, and when.** Both are `ON CONFLICT (type, ref_id)`
idempotent, both post their opening pill through `chatSystemMessages`, and both emit
**after commit**:

| Room | `type`/`ref_id` | Members | Created at |
|---|---|---|---|
| booking | `booking` / booking id | player + venue owner | booking **confirmed** — owner approval *and* `autoApproveJob`. Not on request: an unapproved request is not a conversation |
| captain | `captain` / match id | both teams' captains **and** vice-captains | challenge **accepted**, in the same transaction as the fan-out — carrying **"Challenge accepted — coordinate here"** (FR8.5, verbatim) |

`matchCore.fanOut` also posts **one neutral pill** into the captain room per lifecycle
event (result submitted / awaiting owner / verified / disputed) — per-team wording is
wrong in a shared room. That log is what Wave D's dispute case file archives (FR10.6),
which is why Wave B was built first.

**Quick replies are advisory, and train nothing.** The message is classified by
**model #4** (the released 23-label classifier, byte-identical, no new labels) and the
intent selects three canned replies by the caller's role *in that room*. Tapping a chip
fills the composer; nothing auto-sends, and the send goes through
`POST /:channelId/messages` like any other message. `source` is `model`, `lexicon`
(ml-service down — a small keyword table answers) or `unavailable`.

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

## Tournaments (Token required) — S.7 Wave A

Mounted at `/api/tournaments`, all of SRS Module 6 (FE-1…FE-8). `/mine` and
`/preview` are declared **before** `/:id` so neither word is ever parsed as an id.
**Only a venue owner posts or runs a tournament**, and only at a venue they own:
every owner write is `checkRole('owner')` **and** re-reads `tournaments.owner_id`
(via `venues.owner_id` at create) inside the locked transaction, so holding an
owner token is not authority over *this* cup. Every reply is the house shape —
`{success, data, message, code}` or `{success:false, message, code}`.

### The three state machines — SINGLE SOURCE OF TRUTH
```
tournaments.status        open ──▶ active ──▶ completed
                            └──▶ cancelled       (only before the draw; every entry refunded)

tournament_teams.status   registered ──▶ accepted ──▶ eliminated
                               │   (organiser approved)      (lost a knockout tie / league over)
                               ├──▶ rejected                 (organiser said no  → refund)
                               └──▶ withdrawn                (captain pulled out → refund)

fixtures.status           upcoming ──▶ played        (a scoreline exists)
                              ├──▶ walkover          (nobody played — K = 0, no ELO moves)
                              └──▶ cancelled
```
`registered` = **paid, awaiting approval**; `accepted` = **in the field**. Both are
holding money, so capacity and the pool count *both* — a tournament created with
`requiresApproval:false` lands straight on `accepted`. The champion and runner-up
keep `accepted`; only a knocked-out side becomes `eliminated` (with
`eliminated_round`).

### Endpoints
| Method | Endpoint | Auth | Body / Query | Response |
|--------|----------|------|--------------|----------|
| GET | `/tournaments` | any | `?sport=&city=&startFrom=&status=&q=&venueId=&ownerId=&openOnly=&limit=` | `{tournaments:[{…, teamsRegistered, teamsAccepted, spotsLeft, isFull, secondsToDeadline, pool, prize, winnerName}]}` — **object, not array**; **`openOnly` defaults to `true`**, `false` widens to the archive (FE-2) |
| GET | `/tournaments/mine` | any | `?limit=` | `{organising:[…], playing:[…]}` — both roles in one call; `playing` follows **team membership**, not captaincy, so a squad member finds their own bracket |
| POST | `/tournaments/preview` | **owner** | `{venueId, format, entryFee, minTeams, maxTeams, registrationDeadline, startDate, slotMinutes?, prizePercent?, winnerPercent?, runnerupPercent?, venueDiscountPercent?}` | `{venue, config, capacity, minimum, economics:{atCapacity, atMinimum}, recommended, candidateHours, scan, meta}` — **writes nothing** (FE-1) |
| GET | `/tournaments/:id` | any | — | `{tournament, teams, counts, bracket:{rounds, size, byes, total, played, generated, roundsList}, fixtures, standings, economics, viewer, organiser}` — `organiser` is `null` unless the caller owns it (FE-8) |
| POST | `/tournaments` | **owner** | same as `/preview` + `{name, sport, description?, requiresApproval?}` | **201** `{tournament, warning?}` (FE-1) |
| POST | `/tournaments/:id/generate` | **organiser** | `{useModel?}` | `{tournament, generated, teams, seeds:[{teamId, seed, elo}], bracket:{rounds,size,byes,fixtures}, fixtures, economics, rejectedPending, meta:{scheduling:{source, reason}}}` — draws the bracket now (FE-6) |
| PATCH | `/tournaments/:id/teams/:teamId` | **organiser** | `{decision:'approve'\|'reject'\|'remove', reason?}` | `{tournament, teamId, status}` — reject/remove refunds in the same transaction (FE-5) |
| PATCH | `/tournaments/:id/fixtures/:fid/result` | **organiser** | `{scoreA, scoreB}` | `{tournament, fixture, elo, advanced, completed?, payouts?}` (FE-7) |
| POST | `/tournaments/:id/fixtures/:fid/walkover` | **organiser** | `{winnerTeamId, reason?}` | same shape, `elo.kFactor = 0` — **not** a 3-0 |
| POST | `/tournaments/:id/cancel` | **organiser** | `{reason?}` | `{tournament, refunded:{teams, amount}}` — open tournaments only |
| POST | `/tournaments/:id/register` | **player** | `{teamId}` | **201** `{tournament, registration}` — freezes the entry fee (FE-3) |
| DELETE | `/tournaments/:id/register` | **player** | `?teamId=` | `{tournament, refunded}` — before the deadline, full refund |

`POST /preview` is a POST that reads: the quote depends on the whole draft — both
team counts, four percentages, the slot length, the format and the deadline — and a
dozen fields in a query string would be a worse dishonesty than the verb.

**Authority is never the body.** `POST /:id/register` takes `teamId` from the
request but reads `teams.captain_id` inside the locked transaction, so sending
someone else's team id is a **403**, not an entry.

### The money model — the venue cost is recovered FIRST
A percentage split of the pool would be wrong, because the venue cost is **fixed**
while the pool is **variable**: 8 teams × PKR 2,000 is a 16,000 pool, but a 7-fixture
knockout consumes ~7 hours of inventory worth ~14,000 at the list price, so a 30%
commission would pay the owner 4,800 for slots they could have sold for 14,000. So
the split is a waterfall, computed by the pure `splitPool()` in
`src/utils/fixtures.js` and stored on the row at generation:

```
pool       = entry_fee × teams_in_field
venue_cost = SUM(slots.price) over the fixtures' reserved slots     ← real prices, not an estimate
             × (1 − venue_discount_percent/100)                     ← the owner's lever, default 0
surplus    = pool − venue_cost
prize      = surplus × prize_percent/100        (default 60)
               winner    = prize × winner_percent/100     (default 70)
               runner_up = prize − winner
owner      = venue_cost + (surplus − prize)
```
`pool_amount`, `venue_cost_amount`, `prize_amount` and `owner_earning_amount` are all
written onto the `tournaments` row, so nobody re-derives them later:
**`pool = venue_cost + prize + margin` to the paisa**, asserted by
`src/scripts/check_tournaments.js`.

**Underwater guard.** If `pool < venue_cost` the prize is 0, the owner takes the
whole pool, and the response message says so — money is never taken *from* the
owner. Below `min_teams` at the deadline the tournament is cancelled and every entry
refunded instead.

| Event | Ledger move | `txn_type` |
|---|---|---|
| Register | captain `balance −E`, `frozen +E` | `tournament_entry` |
| Withdraw before deadline · organiser rejects/removes · cancelled | captain `frozen −E`, `balance +E` | `refund` |
| Bracket drawn | every captain `frozen −E`; organiser `balance += venue_cost + margin`; organiser `frozen += prize` | `escrow_release`, `tournament_commission`, `tournament_prize` |
| Final settled | organiser `frozen −prize`; champion captain `+winner share`; runner-up captain `+runner-up share` | `escrow_release`, `tournament_prize` |

The prize sits in the organiser's **frozen** balance, so the existing withdrawal
paths already refuse to touch it — the same rule that protects a booking's escrow,
not a new one. `tournament_prize` is therefore logged **positive twice** (the
organiser's hold, then the champion's credit); the row's own `description` says
which, which is why `lib/widgets/transaction_detail_sheet.dart` prints the
description rather than branching on the type.

**A fixture reserves a slot; it does not create a booking.** The slot flips to
`status='blocked'` and the fixture holds `slot_id` + `scheduled_at`. Writing real
`bookings` rows would pull in wallet holds, pollute the owner's booking list and —
the real danger — let `noShowJob` sweep them and dock both captains' trust scores.
`PATCH /owner/slots/:id/unblock` therefore **refuses** a slot a live fixture stands
on. Teams pay **one** fee and never book or pay for a tournament slot.

### Guard rails (all `{success:false, message, code}`)
| Condition | Status | `code` | Why |
|---|---|---|---|
| non-owner posts a tournament | 403 | — | `checkRole('owner')` on the route |
| owner posts at a venue they do not own, or an inactive one | 403 / 409 | `not_your_venue` · `venue_inactive` | ownership is read **in SQL** from `venues.owner_id`, never from the body |
| knockout `maxTeams` that is not a power of 2, or round-robin over 6 teams | 400 | `invalid` | a bracket that cannot be halved, and `n(n−1)/2` = 28 fixtures ≈ 28 venue hours for 8 teams |
| register with someone else's `teamId` | 403 | `not_captain` | `teams.captain_id` is re-read inside the locked transaction |
| register a team in the wrong sport | 409 | `sport_mismatch` | cross-sport ratings would be meaningless |
| register after `registration_deadline`, or on a closed/cancelled cup | 409 | `deadline_passed` · `not_open` | FE-4 is enforced **on read**, not only by the job |
| the same team registers twice | 409 | `already_registered` | counted under `FOR UPDATE`, so two simultaneous POSTs cannot both win |
| the cap is reached | 409 | `full` | the count includes `registered` **and** `accepted`: an approval-gated cup with 8 pending teams is full, not empty |
| captain's `balance` < entry fee | 409 | `insufficient_funds` | checked on the locked wallet row |
| withdraw after the bracket is drawn | 409 | `too_late` | the fee is already in the pool and a slot is already reserved |
| a non-organiser generates, cancels, approves, or types a result | 403 | `not_organiser` | `tournaments.owner_id` compared in the same transaction as the write |
| generating twice | 409 | `already_generated` | `fixtures_generated_at` is the latch; `uq_fixtures_slot` (`tournament_id, round, position`) is the backstop |
| a field that cannot be drawn or scheduled | 409 | `no_fixtures` | **the whole transaction rolls back** — a cup is never left half-drawn with eight captains' money in the wrong place |
| `unblock` a slot a live fixture stands on | 409 | `fixture_reserved` | `PATCH /owner/slots/:id/unblock`, so the ground cannot be freed from under a fixture |

### ELO: one ladder, K weighted by stakes
Tournament results are more authoritative than friendlies, and the correct place to
say that is **K**, not a second rating — `elo.applyResult` already accepts `kFactor`
and `elo_history` already stores `k_factor` per row, so this needed no refactor. A
separate tournament ELO would also be self-defeating: brackets are *seeded by* ELO, so
a fresh ladder would seed the first cup off all-1000s.

| Match | K |
|---|---|
| Friendly | 32 (`global_settings.elo.k_factor`, unchanged) |
| Tournament, early rounds | 40 |
| Semi-final | 48 |
| Final | 56 |
| Bye / walkover | **0** — no game was played, so no rating moves |

"Why does this count more?" is answered by `SELECT k_factor FROM elo_history` instead
of by a second leaderboard. For the *achievement* side of the question, 019 adds four
counters to `teams` — `tournament_played`, `tournament_wins`, `finals_reached`,
`titles` — returned by `TEAM_COLUMNS` and shown on the team card as
"12 played · 8 W · 2 titles 🏆".

### Two doors, one settle function
1. **The captains' door.** A tournament fixture writes a real `matches` row with
   `tournament_id` set and `booking_id NULL`, so the existing S.2 flow works
   unchanged: both captains submit, the owner verifies, and
   `advanceAfterMatch(client, matchId)` runs **inside that same verify transaction**.
   Authority for such a match derives from `tournaments.owner_id` rather than from the
   booking's venue.
2. **The organiser's door.** `PATCH /:id/fixtures/:fid/result` writes the match row
   itself and runs the same ELO + advance path (FE-7).

Both are idempotent — `matches.elo_applied` and `fixtures.status` are the latches —
and both feed the same advancement, standings refresh, counter bumps and podium
payout. `matchCore`'s match view COALESCEs the fixture's slot and the tournament name,
so a tournament match reports a venue and a time like any other instead of NULL.

### Where the AI is (no retraining — models #1 and #4 untouched)
| # | What | Where |
|---|---|---|
| 1 | **Seeded bracket generation** — ELO-descending seeds, 1 v lowest, `rounds = log2(n)`, byes to the top seeds, winners auto-advanced into the next round's TBD | `src/utils/fixtures.js` — pure, unit-tested with the DB down |
| 2 | **Elo win probability per fixture** — `1/(1+10^((Rb−Ra)/400))`, labelled as the Elo formula, **not** as ML | `fixtures.winProbability`, shown on the bracket |
| 3 | **Demand-aware scheduling (trained model #1)** — early rounds go into the **lowest**-P(booked) windows, the final into the **highest** one | `src/services/tournamentScheduler.js` → `mlClient.forecastDemand` |
| 4 | **Scout** — three **chip-only** actions (`tournament_detail`, `tournament_register`, `my_tournaments`) | `src/services/assistantActions.js`; **no new trained labels**, so model #4's 23 labels stay byte-identical |

Scheduling is not cosmetic: because `venue_cost` is the sum of the chosen slots' real
prices, off-peak placement **lowers the entry fee teams must pay** while **protecting
the owner's sellable peak inventory**. When ml-service is down the allocator falls back
to chronological order and stamps `meta.scheduling.source = 'chronological'` with a
`reason`, so the demo can prove which path ran rather than assert it.

---

## Notifications (Token required) — S.7 Wave C
Mounted at `/api/notifications`. Before this wave the `notifications` table was
**write-only**: ~33 call sites inserted into it and nothing on earth read it. So this
is not "push added to a working notification system" — it is the notification system,
and then push.

| Method | Endpoint | Body / Query | Response |
|--------|----------|--------------|----------|
| GET | `/notifications` | `?limit&cursor&category&unreadOnly` | `{items:[…], nextCursor}` — `created_at DESC` |
| GET | `/notifications/summary` | — | `{unread, byCategory:{…}, push:{configured, …}}` |
| GET \| PUT | `/notifications/preferences` | `{muteAll, push:{cat:bool}, inApp:{cat:bool}, quietHours:{enabled,start,end}}` | the **normalised** prefs — unknown keys and a malformed `"25:99"` are dropped, not stored |
| POST | `/notifications/devices` | `{token, platform?, appVersion?, label?}` | `{deviceId, …}` — call on login, on app start, **and on every `onTokenRefresh`** |
| DELETE | `/notifications/devices` | `{token?}` | `{revoked:n}` — one device, or every device when the body is empty |
| POST | `/notifications/read-all` | `{category?}` | `{marked:n, unread, byCategory}` |
| DELETE | `/notifications` | `?category=` | `{deleted:n, …}` — clear **read** only, and only rows older than an hour |
| GET | `/notifications/types` | — | `{types, routes, categories}` — the registry, for the prefs screen |
| POST | `/notifications/test` | `{title?, body?}` | the demo lever — **caller only**, 403 in production |
| PATCH | `/notifications/:id/read` | — | `{changed, unread, byCategory}` — idempotent |
| PATCH | `/notifications/:id/unread` | — | resets `group_count` to 1 |
| DELETE | `/notifications/:id` | — | `{dismissed:true, …}` — `dismissed_at`, **not** a DELETE |

A feed row is
`{id, type, category, priority, icon, title, body, payload, deepLink, entityType,
entityId, bookingId, groupKey, groupCount, imageUrl, actor:{id,name,avatarUrl}|null,
isRead, readAt, expiresAt, isExpired, createdAt}`.

**`cursor` is a `"<createdAt>~<id>"` PAIR and is opaque.** One transaction routinely
writes several notifications (a booking approval alerts the player *and* the owner), and
a timestamp-only cursor silently drops every tied row after the first at a page
boundary. Nothing outside `notificationFeed.js` builds or parses it; a malformed cursor
decodes to "no cursor" and answers page one rather than 500 on a screen the user reached
by scrolling.

**One server-owned registry: `utils/notificationTypes.js`.** Every `type` maps to
`{category, priority, icon, deepLink(payload), groupKey(payload)}` — **45 types → 9
routes**, printed at boot. The client never guesses a route or an icon, adding a type is
one line, and `assertNotificationTypes()` at boot names any emitted-but-unregistered
type. An unregistered type renders as a blank icon and a dead tap, which is exactly the
class of silent breakage this wave existed to end.

Categories (`booking · match · tournament · chat · team · wallet · assistant · venue ·
review`, plus a non-mutable `system`) are the unit a user opts out of and the filter
chips. `priority` (`high · normal · low`) decides whether FCM fires at all and whether
it is a heads-up.

**Push is a transactional outbox, not an inline call.** `notify()` runs inside money
transactions holding `FOR UPDATE` locks; an HTTPS call to FCM there would hold row locks
across a network round trip. So the notification row **is** the outbox
(`sent_push = false`) and `jobs/pushJob.js` drains it on a ~4 s tick. Consequences: zero
changes to the 33 existing call sites, atomic with the money, survives a crash,
retryable, and "why didn't my phone buzz?" is answerable from SQL (`push_attempts`,
`pushed_at`, `push_error`). Cost: up to ~4 s of delivery latency, invisible on a locked
phone.

**Prefs and quiet hours are enforced in the job, server-side.** A toggle the client
honours is a suggestion, not a preference. `inApp` suppresses the foreground banner
only — it can never suppress the row or the badge, because muting is about interruption,
not about hiding what happened. An expired row is never pushed.

**Chat push is presence-aware:** a new message notifies only when the recipient is
offline or not viewing that channel, via the `bus.isUserOnline()` that already existed.

**It ships dormant.** `pushService` no-ops with one warning when
`FIREBASE_SERVICE_ACCOUNT` is unset (the same discipline as `mlClient.isConfigured()`);
the boot banner then reads `[PushJob] … FCM OFF`. Bell, badge, feed, deep links, prefs
and live socket delivery all work without the key. `registration-token-not-registered`
and `invalid-argument` revoke **one device row** — never a logout everywhere, which is
why `user_devices` replaced the one-token-per-user `users.fcm_token` (still written, for
backward compatibility).

---

## Admin (Admin token required) — S.7 Wave D
Mounted at `/api/admin`, which applies **one** `router.use(auth, checkRole('admin'))`
above every sub-router (`adminUsers`, `adminDisputes`, `adminSettings`,
`reports.platformReports`). There is therefore no per-path authorisation to remember,
and a new admin path cannot ship without a gate. Every write lands in **`admin_audit`**
with `before`/`after` jsonb — "who changed this?" is the first question a viva panel
asks about an admin panel.

### Disputes — the queue and the ruling (FR10.6, FR10.7)
The raise flow shipped in S2 Wave C and **nothing ever read the table**.

| Method | Endpoint | Body / Query | Response |
|--------|----------|--------------|----------|
| GET | `/admin/disputes` | `?status=open\|resolved\|dismissed\|all&cursor&limit` | `{items:[…], nextCursor, count}` |
| GET | `/admin/disputes/:id` | — | the case file (below) |
| PATCH | `/admin/disputes/:id` | `{action, scoreChallenger?, scoreOpponent?, note}` | `{ruling, eloMoved, bracket, …}` + a sentence |

`action` is `rule_challenger · rule_opponent · rule_draw · rule_custom · dismiss`.
**`note` is required** — the teams are told what it says, so a ruling with no
explanation is not a ruling.

**Sorted by what is at stake, then by age.** `severityElo` is the rating actually on the
line, computed with the same pure `elo.rate()` at the live K, so an admin with ten
minutes spends them on the match that moves the most rating rather than on whichever
arrived last. The list cursor is a `"<severityElo>~<createdAt>~<id>"` **triple** and is
opaque; building it client-side pages wrong.

**The case file** is both `match_results` rows side by side (the table's
`UNIQUE (match_id, submitted_by_team)` guarantees exactly one per team), each roster with
current Elo and trust score, the booking + venue + slot, the owner's check-in/QR
evidence, the match's `elo_history`, and **the captain-channel chat archive** — a plain
read of the room Wave B now creates. That archive is the literal FR10.6 requirement.

**A ruling goes through the same verified path as the owner's `POST /matches/:id/verify`,
in one transaction** — not a parallel implementation: lock the match `FOR UPDATE`, write
the ruled scoreline and `winner_team`, `elo.applyResult()` (same call, same `elo_history`
audit trail, honours `elo_frozen`), stamp `status = completed` + `verified_by` +
`elo_applied`, `tournaments.advanceAfterMatch()` unconditionally (a friendly answers
`not_tournament` and touches nothing; a fixture advances the bracket inside the same
transaction), close the dispute, `notify()` **both** captains and post one neutral pill
into the room where they argued about it. `emitAfterCommit` runs **after** COMMIT —
emitting inside would tell both apps to re-fetch a match that is not committed yet.
`dismiss` skips the rating work, leaves both submissions intact and returns the match to
`awaiting_owner`. Escrow is untouched by a ruling: the deposit is settled by
check-in/no-show, not by who won. A fixture whose bracket already advanced answers
`code:'already_settled'` rather than rewriting history.

### Users — suspension that actually suspends (FR10.8)
| Method | Endpoint | Body / Query | Response |
|--------|----------|--------------|----------|
| GET | `/admin/users` | `?q=&role=&status=active\|suspended\|all&limit&cursor` | keyset page on `(created_at, id)` |
| PATCH | `/admin/users/:id/suspend` | `{reason}` — required | `{cascade:{…}}` + a sentence |
| PATCH | `/admin/users/:id/reinstate` | `{note?}` | what was re-listed |

**The security fix this wave landed.** `middleware/authMiddleware.js` was 43 lines of
pure `jwt.verify` with **no DB read**, so a suspended user's existing token kept working
until it expired — `users.is_active` was checked at login only, which made suspension
cosmetic. It now carries a **30 s-TTL in-process cache** of `(id → {is_active, role})`:
one small indexed lookup per user per 30 s, `invalidate(id)` called the instant a
suspension commits, and — following `globalSettings.js`'s NEVER-THROW rule — a DB error
falls back to the token's claims rather than locking everybody out. Suspended →
**403** `Account suspended…`, matching the login message.

Suspension is a **cascade in one transaction**: upcoming bookings cancelled *with
refunds* through the existing `bookingService.cancelBooking` core function (so it joins
this transaction), open challenges withdrawn, upcoming tournament registrations
withdrawn, and the user notified. A suspended **owner** additionally has their venues
set `is_active = false` and their pending requests rejected + refunded — otherwise
players keep paying into a dead venue. Reinstate lifts the ban and re-lists the venues
**that suspension** took down, read back from its own audit row; nothing else is
restored, because a refunded booking cannot be un-refunded. Guards: you cannot suspend
yourself, you cannot suspend another admin, and wallet withdrawals refuse for an inactive
user where the wallet row is already locked.

### Global settings, live (FR10.9–FR10.11)
| Method | Endpoint | Body | Response |
|--------|----------|------|----------|
| GET | `/admin/settings` | — | `{sections:[{key,label,description,fields:[…]}], overrides:[…]}` |
| PUT | `/admin/settings` | `{settings:{key:value}, note?}` (note ≤ 500) | `{changed, sections, overrides}` + a sentence |
| POST | `/admin/settings/reset` | `{keys:[…]}` **or** `{all:true}` | what went back to default |

A field is
`{key, label, description, type, unit, step, min, max, maxLen, pairsWith, value,
default, isOverridden, restartRequired}` in six sections —
`money · sports · elo · match · tournament · assistant`. **There are exactly five
types** (`int · number · bool · text · sports`), so a screen that renders those five
renders the whole catalogue, and adding a key is a server change with no app release.
Values are read back **through the same accessor the app uses**, so an admin sees
*effective* values rather than raw rows.

**Written bounds ⊂ read clamps.** `globalSettings.js` already clamps on read; PUT
rejects at the edge exactly what the accessor would have silently clamped, so the admin
gets an error instead of a lie. Refused outright: `commission_pct + deposit_pct > 100`;
`tournament.winner_percent + runnerup_percent ≠ 100` (this is what `pairsWith` marks);
`min_teams > max_knockout_teams`; `k_factor` outside 8–64; switching off a sport that has
future confirmed bookings — **409 `code:'sport_has_bookings'`** with the count per sport,
because the honest answer names what is in the way. `sports_enabled` is a
`{sportName: bool}` map and at least one must stay on. Sport toggles are enforced on
venue create/edit **and** on booking, not merely hidden in the UI.

A write calls `settings.invalidate()`, so it **applies to the next operation with no
restart** (FR10.11) — the hook `globalSettings.js`'s header has advertised since S.4.
`POST /reset` DELETEs the override row, so the key follows `DEFAULTS` forever after.
Validation failures answer **400** with `errors:[{key,message}]`; a no-op write is a
`success:true` `Nothing changed — those are already the saved values.`

> `bad(res, status, message, extra)` spreads `extra` at the **top level** of the
> envelope. `errors` and `code` are therefore siblings of `message`, **not** nested
> under `data`.

### Financial export (FR4.16)
Two scopes, **one generator**, so the CSV and the JSON can never drift: the same
`eachRow` walk feeds both.

| Method | Endpoint | Query |
|--------|----------|-------|
| GET | `/owner/reports/financial` | `?from&to&venueId&format=csv\|json` |
| GET | `/admin/reports/platform` | `?from&to&venueId&format=csv\|json` |

`from`/`to` are **required** `YYYY-MM-DD` and the span is capped at **366 days**.
`?format=json` returns `{range:{from,to,days}, columns:[{key,label,money}], totals, rows,
truncated, byOwner?}` with `rows` capped at 500 — **the totals are always for the whole
range and only `rows` is a page**, which `truncated` says out loud. CSV is streamed
(`res.write` per row, never a giant string) with a UTF-8 BOM, one row per booking, one
per tournament payout, and a `TOTAL` summary row.

**The columns and their order are the server's.** The preview table renders whatever
`columns` says, so the numbers on the phone cannot disagree with the numbers in the file,
and adding a column needs no app release.

**Money comes from the ledger** (`transactions`, the shapes `escrow.logTxn` writes), never
recomputed from prices, so the export reconciles with the wallet to the paisa. `price` and
`depositAtRisk` are the *agreement*; everything after them is the ledger. `byOwner` is
where "commission earned per owner" actually lives — commission is a ledger row on the
owner's wallet, not a column of the booking — and it includes an `(no owner on record)`
bucket so the subtotals reconcile with TOTAL.

**CSV injection is escaped.** A venue named `=cmd|…` or `+1+1` *executes* when the file
opens in Excel, so every field starting with `= + - @`, tab or CR is prefixed with `'`
and quotes are doubled. This is the one non-obvious correctness item in the export.

**A failure has two shapes, and the boundary is the first byte.** Before it: an ordinary
`{success:false, message}` with a real status code. After streaming starts the status
code is spent, so a mid-stream failure appends a final `ERROR,…` row instead — a 200
whose last line starts with `ERROR,` is a truncated export, and the app says so rather
than handing over a file quietly missing yesterday's bookings.

> The CSV is **not** fetched through Flutter's `ApiClient`: that client sends
> `Accept: application/json` and decodes every response into the `{success,…}` envelope.
> `ReportService.downloadCsv` is a direct `http.get` that keeps `bodyBytes` intact, which
> is why the BOM survives and Excel on Windows opens Urdu venue names readable instead of
> as mojibake.

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
| `tournament_entry` | Tournament entry fee **frozen** at registration (S.7 Wave A) — refunded in full on withdraw, rejection or cancellation |
| `tournament_commission` | Organiser's earning at the draw: the venue hours the fixtures reserved **plus** the margin on top |
| `tournament_prize` | The prize pool — logged **twice**: held in the organiser's `frozen` at the draw, then credited to the champion's and runner-up's captains at the final. The `description` says which |
