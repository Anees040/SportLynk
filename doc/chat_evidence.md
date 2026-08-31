# Chat — the evidence pack

**This file is generated. Do not edit it by hand.** Every line below was written by a
verification script that had just asserted it against the live database, inside one
transaction that was then rolled back — so the run leaves no rows behind and the
document is reproducible rather than a description of a state somebody once had. To
regenerate:

```
cd backend && node src/scripts/check_chat.js --evidence
```

A block absent from this file was not run — it is not a pass.

<!-- chat-evidence:chat BEGIN -->

## S.7 Wave B -- the three channel types, the inbox, and FR8.10 reply suggestions

A booking is confirmed and a room opens with the venue owner and the player in it; a challenge is accepted and a SECOND room opens holding both captains and both vice-captains; every match-lifecycle event posts one NEUTRAL sentence into that shared room; the inbox lists all of it with an unread count checked against a hand-computed number; and the reply suggestions are classified by the released 23-label model with a keyword fallback proven by running it with the model switched off. One transaction, rolled back at the end -- no channel, no message, no membership row survives the run.

**PASS 120/120** · 0 skipped · produced Aug 30, 2026, 03:21:01 PKT (2026-08-29T22:21:01.360Z)

| provenance | value |
|---|---|
| command | `cd backend && node src/scripts/check_chat.js --evidence` |
| commit | `352a587` — feat: implement Tournaments feature · **17 uncommitted path(s) in the tree** |
| node | v22.19.0 on win32 |
| venue | F-11 Markaz Football Arena (Islamabad) |
| ml-service | reachable |
| quick-reply source | model (check_availability) |
| model version | intent-v2-20260828-2315 |

### What this run establishes

- **booking room opening pill** — Booking confirmed — chat with the venue here
- **coordination room opening pill** — Challenge accepted — coordinate here
- **sentences in the coordination room** — 6
- **booking row subtitle** — Pending · Sat 19 Sept, 6:00 pm
- **coordination row title** — zzchat-Team A vs zzchat-Team B
- **unread-count plan** — Index Scan using idx_chat_messages_channel
- **asked by the player** — bhai kal 6 baje ka slot khali hai?
- **offered to the owner** — “Yes, that slot is free.”  ·  “Sorry, that one's already booked.”  ·  “Let me check and confirm in a few minutes.”
- **with ml-service down** — “Cancel outside the window and the deposit comes back in full.”  ·  “The deposit is released once you check in.”  ·  “I'll confirm the exact amount and let you know.”
- **coord pill call sites in routes/matches.js** — 6

### Every assertion, in the order it was made

**Block 1 — a confirmed booking becomes a room**

- ✓ a PENDING booking has no chat room (an unapproved request is not a conversation)
- ✓ confirming it opens the room and posts the opening pill in one call
- ✓ exactly one channel exists for this booking
- ✓ two people are in it — the player and the venue owner, nobody else
- ✓ the venue owner is the room admin (they moderate their own venue)
- ✓ the player is a member — they can delete their own messages and nothing else
- ✓ the room opens with exactly one message
- ✓ and it is a system pill, not something attributed to a person
- ✓ with no sender — nobody typed it
- ✓ whose wording is the one sentence a push notification can show verbatim
- ✓ and whose system_meta carries the same fact structured, for the app to render

**Block 2 — confirming twice does not open a second room**

- ✓ still exactly one channel after a second confirm (ux_chat_channels_type_ref)
- ✓ and it is the SAME channel id, so the earlier history is still there
- ✓ the membership was not duplicated either
- ✓ the pill is posted again — a room is a thing, a sentence is an event
- ✓ cancelling the booking posts a pill into the room instead of deleting it
- ✓ and the pill names the reason, because that is what the next message will argue about
- ✓ a no-show posts its own pill
- ✓ worded as the venue’s action, since that is who marked it
- ✓ a booking that predates this wave has no room, and that is not an error

**Block 3 — an accepted challenge opens the captains’ room**

- ✓ a challenge that has only been SENT has no room (a declined one must leave no thread)
- ✓ and captainChannelId says so by returning null rather than throwing
- ✓ the room’s membership resolves to four people, not two
- ✓ accepting the challenge opens the coordination room
- ✓ both captains AND both vice-captains are in it
- ✓ both captains are members
- ✓ both vice-captains too — “the captain is unreachable” is the failure this room prevents
- ✓ and no ordinary team member, who has their own team chat for this
- ✓ everyone is an admin: there is no hierarchy between two opposing captains
- ✓ exactly one room for this match
- ✓ a retried accept resolves to the same room, never a second one
- ✓ still one
- ✓ and captainChannelId now finds it — the lookup every later pill goes through

**Block 4 — one shared room, one neutral sentence per event**

- ✓ accepting writes three pills: one per team chat, one in the room
- ✓ the coordination room opens with exactly one sentence
- ✓ and it is FR8.5’s wording, verbatim
- ✓ team A’s own chat names team B, in team A’s voice
- ✓ match_result_in posts one pill and only in the shared room
- ✓ match_result_in → “zzchat-Team A submitted a result for this match”
- ✓ match_both_results_in posts one pill and only in the shared room
- ✓ match_both_results_in → “Both results are in — the venue owner will verify the match”
- ✓ match_settled posts one pill and only in the shared room
- ✓ match_settled → “Result verified — zzchat-Team A 3-1 zzchat-Team B”
- ✓ match_under_review posts one pill and only in the shared room
- ✓ match_under_review → “The result is disputed and under review by SportLynk”
- ✓ match_ruled posts one pill and only in the shared room
- ✓ match_ruled → “SportLynk ruled on this match — result upheld”
- ✓ no sentence in the shared room says “you” or “your” — it reads the same to both teams
  > - Challenge accepted — coordinate here
- zzchat-Team A submitted a result for this match
- Both results are in — the venue owner will verify the match
- Result verified — zzchat-Team A 3-1 zzchat-Team B
- The result is disputed and under review by SportLynk
- SportLynk ruled on this match — result upheld
- ✓ the per-team sentences still take a side — “they challenged your team” vs “you challenged them”
- ✓ a match with no coordination room posts nothing and does not throw
- ✓ while a null channelId still resolves the room by match id, the way fanOut’s callers rely on

**Block 5 — the inbox, its unread count and its badge**

- ✓ the list holds all three channel types for one person
- ✓ and exactly the three rooms they are a live member of
- ✓ ordered most-recent-first, on the same expression the cursor pages on
- ✓ a booking row’s subtitle carries its live status, read from the booking row itself
- ✓ and the slot, formatted as PKT wall-clock and never re-zoned
- ✓ a coordination row reads “my team vs theirs” — written per viewer even though the room is shared
- ✓ a team row carries its member count
- ✓ the list’s unread count for the shared room is the hand-computed 7
- ✓ my own message does not count as unread to me, and a deleted one stops counting at all
- ✓ though the preview still shows the deleted message until something newer arrives
- ✓ marking it read clears the count to zero
- ✓ the badge total equals the sum of the rows it summarises
- ✓ and it breaks down by type, which is what a per-tab badge needs
- ✓ muting writes muted_until — a timestamp, so “mute 8 hours” un-mutes itself
- ✓ the muted room drops out of the badge by exactly its own count
- ✓ while the list still shows the room, and still shows its count — information, not a nag
- ✓ and un-muting clears it
- ✓ the type filter returns only that type
- ✓ a limit of two returns two rows
- ✓ and a cursor, because there is more
- ✓ the second page does not repeat a row from the first
- ✓ and between them they are the whole list
- ✓ a Scout thread can be opened for this user
- ✓ it does NOT appear in the inbox even as a member with an unread message in it
- ✓ and the badge has no bucket for Scout at all — three human types, nothing else
- ✓ idx_chat_messages_channel exists (migration 013)
- ✓ and it covers exactly the columns the count and the history page filter and sort on
- ✓ and the planner chooses it for the unread count (EXPLAIN shows an index scan)

**Block 6 — FR8.10 reply suggestions, model and fallback**

- ✓ the frozen spec still has 23 labels and this wave added none
- ✓ every quick-reply key is a real label (none unknown)
- ✓ and so is every intent the keyword fallback can produce
- ✓ every entry offers exactly three replies — the number a chip row fits
- ✓ the owner gets a suggestion
- ✓ three of them
- ✓ worded for the venue owner, because that is who is replying
- ✓ and flagged advisory — tapping one fills the composer, it never sends
- ✓ the released model classifies the Roman-Urdu question as check_availability
- ✓ with a real confidence, not a zero
- ✓ the player gets the player audience in the same room
- ✓ and genuinely different sentences — the two sides need opposite halves of one conversation
- ✓ a coordination room is its own audience regardless of the caller’s app role
- ✓ no placeholder ever reaches the wire
- ✓ and {venue} is filled with the real venue name off the booking row
- ✓ suggesting a reply to your OWN message is refused
- ✓ so is an empty body
- ✓ and a messageId from a different channel — the id alone is never enough
- ✓ with ml-service down the keyword table answers instead
- ✓ and it reads the Roman-Urdu refund question correctly
- ✓ still three sendable sentences, not an error
- ✓ with confidence 0 — the endpoint never claims a model it did not use
- ✓ an unrecognisable message yields no intent
- ✓ and says so
- ✓ and STILL offers three generic replies rather than nothing

**Block 7 — every confirm, cancel and no-show path calls the opener**

- ✓ the owner approving a booking opens the room
- ✓ the owner marking a no-show posts its pill
- ✓ auto-approval opens the SAME room, so the race has no wrong winner
- ✓ the no-show sweep posts its pill too
- ✓ cancelling a booking annotates the room instead of deleting it
- ✓ accepting a challenge opens the coordination room
- ✓ GET /api/chat is served by the same function this script drove
- ✓ so is the badge
- ✓ and so are the reply suggestions
- ✓ routes/owner.js emits its pill AFTER COMMIT, never inside the transaction
- ✓ jobs/autoApproveJob.js emits its pill AFTER COMMIT, never inside the transaction
- ✓ jobs/noShowJob.js emits its pill AFTER COMMIT, never inside the transaction
- ✓ all six match-lifecycle fan-outs pass a coord pill

**The rollback**

- ✓ after ROLLBACK not one person this run created still exists
- ✓ nor one team
- ✓ and not the booking room either — the database is exactly as it was

<!-- chat-evidence:chat END -->
