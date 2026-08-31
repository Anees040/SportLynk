# Notifications — the evidence pack

**This file is generated. Do not edit it by hand.** Every line below was written by a
verification script that had just asserted it against the live database, inside one
transaction that was then rolled back — so the run leaves no rows behind and the
document is reproducible rather than a description of a state somebody once had. To
regenerate:

```
cd backend && node src/scripts/check_notifications.js --evidence
```

A block absent from this file was not run — it is not a pass.

<!-- notification-evidence:notifications BEGIN -->

## S.7 Wave C -- the registry, the collapse upsert, the feed and the push outbox

Every notification type resolves to a category, a priority and a deep link the app actually registers; three messages from one person collapse into ONE feed row reading "3 new messages" through a partial unique index Postgres has to infer at runtime; the feed pages, filters and counts unread against a hand-computed number; and the outbox claims each row exactly once, honours a muted category and a midnight-wrapping quiet window, and stamps an honest reason on every row it does not push -- including, today, "no Firebase key". One transaction, rolled back at the end.

**PASS 169/169** · 0 skipped · produced Aug 30, 2026, 22:28:22 PKT (2026-08-30T17:28:22.497Z)

| provenance | value |
|---|---|
| command | `cd backend && node src/scripts/check_notifications.js --evidence` |
| commit | `352a587` — feat: implement Tournaments feature · **83 uncommitted path(s) in the tree** |
| node | v22.19.0 on win32 |
| FCM at run time | dormant (FIREBASE_SERVICE_ACCOUNT is not set) |
| outbox tick | 4s |
| registered types | 45 |
| deep-link routes | 9 |
| types emitted by call sites | 31 |
| FCM | off (FIREBASE_SERVICE_ACCOUNT is not set) |

### Every assertion, in the order it was made

**1 · The registry — every type resolves to a category, an icon and a route**

- ✓ assertNotificationTypes() passes at boot
- ✓ every type has a category chk_notifications_category allows
- ✓ every type has a priority the CHECK allows
- ✓ every type has an icon — a feed row can never draw blank
- ✓ 'system' is not a mutable category — a suspension cannot be opted out of
- ✓ chat and booking ARE mutable — the categories a user actually wants control of
- ✓ every type a notify() call site emits is registered (31 scraped)
  > Registered-but-not-yet-emitted types (14): account_reinstated, account_suspended, dispute_resolved, elo_frozen, match_accepted, match_challenge, match_disputed, match_expired, match_rejected, match_result_pending, match_verified, tournament_fixtures_ready, tournament_generated, tournament_won — these are Wave D call sites, not defects.

**7 · Quiet hours — a window that wraps midnight**

- ✓ a 22:00→07:00 window is quiet across midnight and loud at 07:00 (7 instants)
  > Quiet hours 22:00→07:00 in Asia/Karachi: 21:59=loud, 22:00=quiet, 23:30=quiet, 03:00=quiet, 06:59=quiet, 07:00=loud, 12:00=loud
- ✓ a zero-length window reads as OFF, not as always-quiet
- ✓ and a window with no enabled flag is off — opting in has to be explicit
- ✓ muteAll suppresses a booking push
- ✓ but NOT a system one — the same rule notificationTypes states by omitting it from MUTABLE
- ✓ a per-category mute suppresses that category
- ✓ and leaves the others alone
- ✓ an empty prefs object means everything ON — a new category is never silently off

**9 · WIRING — the calls that make the machine reachable**

- ✓ server.js requires routes/notifications
- ✓ and mounts it at /api/notifications — without this the table stays write-only
- ✓ server.js asserts the registry at LOAD, so a bad entry is a boot failure not a blank row
- ✓ and starts the outbox drain (the 7th job)
- ✓ routes/chat.js notifies on a new message
- ✓ guarded by !duplicate — a retried clientId must not ping the phone twice
- ✓ inside the same transaction as the insert — the alert cannot outlive a rolled-back message
- ✓ routes/auth.js can register a device
- ✓ login registers the FCM token it was given
- ✓ and POST /logout exists — a token left registered delivers to whoever signs in next
- ✓ which revokes the device rather than ignoring it
- ✓ chatCore consults presence — no row for a message already on screen
- ✓ and the per-channel mute
- ✓ SAVEPOINT-wrapped, so a notifications failure cannot roll back somebody message

**10 · Deep links — every route the server emits exists in lib/main.dart**

- ✓ main.dart declares 34 named routes
- ✓ the registry emits 9 distinct routes
- ✓ all of them are registered in main.dart
  > All 9 registry routes resolve against lib/main.dart — no notification taps into a dead route.
- ✓ player_home_screen.dart references notifications
- ✓ owner_home_screen.dart references notifications

**11 · Schema census — migration 020 on the live database**

- ✓ notifications.read_at
- ✓ notifications.dismissed_at
- ✓ notifications.category
- ✓ notifications.priority
- ✓ notifications.group_key
- ✓ notifications.group_count
- ✓ notifications.deep_link
- ✓ notifications.actor_id
- ✓ notifications.image_url
- ✓ notifications.entity_type
- ✓ notifications.entity_id
- ✓ notifications.expires_at
- ✓ notifications.sent_push
- ✓ notifications.push_attempts
- ✓ notifications.pushed_at
- ✓ notifications.push_error
- ✓ notifications.created_at is timestamptz (010 shipped it naive — "2 hours ago" was wrong by the server offset)
- ✓ user_devices exists — one row per install, not one token per user
- ✓ user_devices.fcm_token
- ✓ user_devices.platform
- ✓ user_devices.revoked_at
- ✓ user_devices.revoke_reason
- ✓ user_devices.last_seen_at
- ✓ users.notification_prefs
- ✓ index idx_notifications_unread
- ✓ index idx_notifications_outbox
- ✓ index ux_notifications_group
- ✓ idx_chat_messages_channel covers (channel_id, created_at) — the chat list is not a seq scan

**2 · The row — registry-stamped columns, inside the caller transaction**

- ✓ notify() writes without throwing
- ✓ the row is readable back on the same connection
- ✓ category came from the registry (match)
- ✓ priority came from the registry (high)
- ✓ entity_type is the polymorphic tap target
- ✓ entity_id was read out of the payload
- ✓ actor_id records who caused it — the feed draws their avatar
- ✓ it starts unread
- ✓ and unpushed — the row IS the outbox
- ✓ group_count starts at 1
- ✓ expires_at survived — a 48h challenge stops being actionable
- ✓ deep_link was computed server-side, not left to the client
- ✓ the route is the match centre
- ✓ and it carries the match id as an arg
  > match_challenge deep link: {"args":{"teamId":"8506ae18-0946-4165-8496-a71aa73bc8d9","matchId":"9390afaf-04ff-4502-ab60-5acb5d91d03f"},"route":"/match-center"}
- ✓ notifications.created_at is timestamptz — the UTC-storage rule holds after 020
- ✓ an UNREGISTERED type still writes instead of throwing
- ✓ as category=system
- ✓ with no deep link rather than a guessed one

**3 · Collapse — three messages become one row reading 3 new messages**

- ✓ ux_notifications_group exists (migration 020)
- ✓ it is UNIQUE — two live rows for one thread are impossible
- ✓ and PARTIAL on dismissed_at IS NULL
- ✓ and on is_read = false — a read row leaves the index
  > ux_notifications_group: CREATE UNIQUE INDEX ux_notifications_group ON public.notifications USING btree (user_id, group_key) WHERE ((group_key IS NOT NULL) AND (is_read = false) AND (dismissed_at IS NULL))
- ✓ the first chat message writes
- ✓ the first is group_count = 1
- ✓ and is not yet a collapsed row
- ✓ two more messages arrive
- ✓ the third BUMPS the same row to group_count = 3
- ✓ and it is the same row id — no duplicate was inserted
- ✓ the feed holds ONE row for three messages, not three
- ✓ the title stays the person — the tray needs a thread identity
- ✓ the body reads 3 new messages, not the newest one alone
- ✓ sent_push was RESET — the 2 new messages banner is now stale
  > After three messages the feed holds one row: Bilal Khan / 3 new messages (group_count=3).
- ✓ a fourth message after the user has read the row
- ✓ starts a FRESH row — a read row has left the partial index
- ✓ and counts from 1 again
- ✓ a message in a DIFFERENT thread
- ✓ is its own row — group_key is per conversation, not per type
- ✓ two join requests for one team
- ✓ collapse to one row with group_count = 2
- ✓ and the TITLE is what changes for this group
  > Two join requests collapse to: 2 players want to join

**4 · The feed — paging, filtering, and a hand-computed unread count**

- ✓ summary.unread matches a hand count (5)
- ✓ byCategory names every category, including the zeroes the chips need
  > Summary for the run user: unread=5, byCategory={"chat":2,"match":1,"system":1,"team":1,"booking":0,"tournament":0,"wallet":0,"assistant":0,"venue":0,"review":0}
- ✓ a limit of 3 returns exactly 3 rows
- ✓ and reports hasMore without a COUNT(*) over the table
- ✓ with a nextCursor to continue from
- ✓ every row carries an icon resolved from the registry, not from the row
- ✓ and a category
- ✓ and an isExpired flag so a dead challenge does not look actionable
- ✓ the second page does not repeat a row from the first
- ✓ and the two pages are the unpaged order, in order — no row falls between them
- ✓ a malformed cursor is user input and must not throw
- ✓ it decodes to page one rather than a 500
- ✓ a category filter returns only that category
- ✓ unreadOnly returns nothing already read

**5 · Three states — unread, read, dismissed (and dismissed is not deleted)**

- ✓ markRead marks an unread row
- ✓ a second markRead is a no-op, not an error — the client can retry safely
- ✓ read_at records WHEN, which is a different fact from whether
- ✓ markUnread puts it back
- ✓ and RESETS group_count — otherwise it would read 4 new messages when one is new
- ✓ another user marking it read gets -1 — the route turns that into a 404
- ✓ dismiss removes it from the feed
- ✓ the ROW SURVIVES — it is the only record the user was ever told
- ✓ with dismissed_at stamped
- ✓ and marked read too — a dismissed row that still counted would leave an uncleanable badge
- ✓ and the feed no longer lists it
- ✓ markAllRead clears the rest (4 row(s) from 4 unread)
- ✓ the badge is now zero

**6 · Preferences — stored server-side, because a client-honoured toggle is a suggestion**

- ✓ the default is everything ON
- ✓ with a push and an inApp map
- ✓ the response carries the registry category list and names system as unmutable
- ✓ an explicit false is stored
- ✓ an unknown category is dropped, not persisted
- ✓ and true is not stored as an override — an absent key already means ON
- ✓ an invalid 25:99 falls back rather than being kept
- ✓ while a sloppy 7:3 is NORMALISED rather than replaced
  > Normalised prefs: {"muteAll":false,"push":{"booking":false,"match":true,"tournament":true,"chat":true,"team":true,"wallet":true,"assistant":true,"venue":true,"review":true},"inApp":{"booking":true,"match":true,"tournament":true,"chat":true,"team":true,"wallet":true,"assistant":true,"venue":true,"review":true},"quietHours":{"enabled":true,"start":"22:00","end":"07:03"}}
- ✓ and it round-trips through the database — one normaliser on read and on write
- ✓ validHM zero-pads a readable time
- ✓ and rejects an hour that does not exist
- ✓ and anything unparseable, so the caller can fall back

**8 · The outbox — claimed once, stamped with a reason, badge emitted regardless**

- ✓ idx_notifications_outbox exists — the drain is an index scan
- ✓ the drain runs
- ✓ the fresh row leaves the outbox
- ✓ with push_attempts = 1 — the claim is an UPDATE, so a crash cannot loop
- ✓ and an honest reason: push disabled: FIREBASE_SERVICE_ACCOUNT is not set
- ✓ while the IN-APP row stays unread — push and feed are separate concerns
  > A row with no device and no Firebase key is stamped: push disabled: FIREBASE_SERVICE_ACCOUNT is not set
- ✓ a second drain claims nothing — no row is pushed twice
- ✓ a drain with an expired row
- ✓ counts it as expired
- ✓ and says so on the row
- ✓ while the in-app row is untouched — it renders as expired, not gone
- ✓ a drain with a MUTED category
- ✓ records it as suppressed by the preference
- ✓ and names the reason: muted: booking
- ✓ the IN-APP row is still delivered — a mute silences the phone only
- ✓ and is still in the feed
  > A muted category is recorded as "muted: booking" while the in-app row stays unread.
- ✓ a system notification with muteAll set
- ✓ is NOT suppressed — a suspension cannot be muted (push disabled: FIREBASE_SERVICE_ACCOUNT is not set)
- ✓ a drain with a row older than the cutoff
- ✓ retires it rather than claiming it (retired=1)
- ✓ so it leaves the partial outbox index
- ✓ without ever being claimed — a stale banner is worse than none
- ✓ and records why: not pushed: older than 60 min when the outbox ran
- ✓ a row at the 3-attempt ceiling
- ✓ is retired, not claimed a fourth time
- ✓ carrying the last error forward: gave up after 3 attempts: simulated transport failure

**The rollback**

- ✓ after ROLLBACK neither test user still exists
- ✓ and not one notification this run wrote — the database is as it was

<!-- notification-evidence:notifications END -->
