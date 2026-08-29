# Scout — the evidence pack

**This file is generated. Do not edit it by hand.** Every line below was written by a
verification script that had just asserted it against the running system, and each block
records the commit, the model version and the command that produced it. To regenerate:

```
cd backend && npm run evidence      # both blocks, in order

# or one at a time:
node src/scripts/check_assistant.js      --evidence   # the service layer, in one rolled-back transaction
node src/scripts/check_assistant_http.js --evidence   # the same assistant over real Express, with real JWTs
```

Each script owns one block and rewrites only its own, so the two can be run in either
order, or separately. A block absent from this file was not run — it is not a pass.

<!-- scout-evidence:service BEGIN -->

## Block 1 -- the service layer, driven through `dialogManager.handleTurn`

Real classification by model #4, a real booking, a real cancellation, a real escalation answered by a real owner, all inside ONE transaction that is rolled back at the end. Every assertion reads the ROWS rather than the reply text: the reply is the thing under test, not the evidence.

**PASS 326/326** · 0 skipped · produced Aug 29, 2026, 06:49:06 PKT (2026-08-29T01:49:06.092Z)

| provenance | value |
|---|---|
| command | `cd backend && node src/scripts/check_assistant.js --evidence` |
| commit | `c751102` — feat: implement Wave S6-C Scout (dialog manager & actions) [278/278 · 60/60 · 78/78 · migration 018 36/36] · **32 uncommitted path(s) in the tree** |
| node | v22.19.0 on win32 |
| model #4 (intent NLU) | intent-v2-20260828-2315 · threshold 0.45 (from the artifact) · intent_latest.joblib · trained 2026-08-28T23:15:00+00:00 |
| label contract | assistant-intents-v2 fp 68396192ab4a87a4 · dataset assistant-dataset-v2 fp 339ad58af5ddb072 · 23 intents in 8 groups |
| rule extractors (no model, no training) | entities nlu-entities-v1 fp 34aee7e75192e6fe · text nlu-text-v1 fp eca8d0423d2084b3 |
| parse limits | 500 chars max · 50ms budget · 3 alternatives returned |
| action registry | 23 trained labels + 4 button-only = 27 actions, boot-asserted |
| database | postgres · PostgreSQL 17.6 · this run is ONE transaction, rolled back |

### What this run establishes

- **FR8.15 holds by census, not by assertion** — `INSERT INTO bookings` appears in exactly 1 of 50 backend source files (`services/bookingService.js`), and `assistantActions.js` contains none of the six money primitives. Scout prepares; the shared service spends.
- **The telemetry cannot become a transcript** — `assistant_turns` has 17 columns and not one of them can hold what the user typed (`text_chars int` records the length only), which is also the property an external rephrasing API would have reversed -- see the Wave S6-E decision in PROGRESS.md.

### Every assertion, in the order it was made

**0  preflight — registry, model #4, migration 018**

- ✓ action registry routes every trained label (23 labels, 27 actions, 4 button-only)
- ✓ model #4 reachable and agrees on all labels (intent-v2-20260828-2315, threshold 0.45)
- ✓ migration 018 columns present (assistant_escalations.status, assistant_kb.asked_count, assistant_turns.answer_source, assistant_turns.text_chars, chat_channels.archived_at, chat_channels.assistant_persona, chat_channels.session_state, chat_messages.assistant_payload)

**A  find a ground → see times → pick → confirm → booked**

- ✓ "Rawalpindi mein cricket ground chahiye" → find_venue
- ✓ venue cards returned (2)
- ✓ source is live or model (got model)
- ✓ every card is the sport that was asked for
- ✓ every card is in Rawalpindi
- ✓ every venue card has See-times and Book buttons
- ✓ a Directions button appears exactly when the ground has coordinates
- ✓ matchPct is a real number or null, never 0-as-unknown
- ✓ the picker is for the ground that was tapped
- ✓ availability is answered live
- ✓ slot picker is numbered from 1 (6 slots on 2026-08-29)
- ✓ every picker button is a pick_slot carrying its slot id
- ✓ the confirm card knows which action it is arming
- ✓ the confirm card quotes the picker price
- ✓ deposit is 20% of the total, from escrow POLICY
- ✓ depositPct comes from POLICY, not a literal
- ✓ the confirm card offers exactly Yes and No
- ✓ session_state is armed for book_venue
- ✓ the armed block holds the picked slot
- ✓ "haan" is decided by the frozen lexicon, not the model
- ✓ the reply says the booking succeeded
- ✓ a booking card came back: "Booked. Bahria Cricket Arena, Sat 29 Aug at 8:00 AM. PKR 2,200 is held in escrow"
- ✓ the booking EXISTS in the bookings table
- ✓ it is the slot the user tapped
- ✓ it belongs to the player who asked
- ✓ the slot is now marked booked
- ✓ the booked amount is the quoted price
- ✓ the stored deposit is the POLICY deposit
- ✓ available balance fell by the full price (8300 → 6100)
- ✓ the same amount is frozen in escrow (0 → 2200)
- ✓ no money was created or destroyed by the booking
- ✓ a booking_payment row is in the ledger (1 txn row(s))
- ✓ the ledger amount is the negative of the price
- ✓ balance_after matches the wallet it left behind
- ✓ the turn was recorded in assistant_turns
- ✓ telemetry names the action that ran
- ✓ telemetry records that it succeeded
- ✓ a booking is answered live
- ✓ the intent is the affirm that fired it
- ✓ a lexicon turn records NO confidence, so it cannot skew model metrics
- ✓ and no model version, for the same reason
- ✓ "haan" is stored as a LENGTH (4), never as text

**B  cancel it → refund preview → confirmed → wallet and ledger agree**

- ✓ previewCancellation answers for the fresh booking
- ✓ cancel offers a confirm card: "Cancelling Bahria Cricket Arena, Sat 29 Aug at 8:00 AM: you get PKR 1,"
- ✓ the card is armed for cancel_booking
- ✓ the card quotes previewCancellation's refund
- ✓ the sentence states the refund and the percentage — "PKR 1,760 back (80%)"
- ✓ refund + penalty is exactly what was held in escrow
- ✓ inside the 24h window the penalty IS the deposit
- ✓ the yes is read by the frozen lexicon, not the model
- ✓ the turn reports the action it ran
- ✓ the cancellation executed: "Cancelled. PKR 1,760 is back in your wallet and PKR 440 of the deposit went to Bahria Cric"
- ✓ and says the money is back
- ✓ the booking row is cancelled
- ✓ cancelled_at is stamped
- ✓ the reason records which side of the window it was
- ✓ the slot is bookable by someone else again
- ✓ and carries no stale hold
- ✓ the player is credited exactly the previewed refund
- ✓ and the whole escrow is released from frozen
- ✓ the owner receives exactly the penalty (0 when the cancel was early)
- ✓ MONEY IS CONSERVED: nothing was minted and nothing was burned across both wallets
- ✓ exactly one refund row (ledger: refund,escrow_received,escrow_release,booking_payment)
- ✓ the refund row carries the refund
- ✓ credited to the player
- ✓ and its balance_after matches the wallet the user will see
- ✓ a late cancel writes one escrow_release
- ✓ and one escrow_received
- ✓ the release is NEGATIVE on the player
- ✓ against the player
- ✓ the receipt is POSITIVE on the owner
- ✓ against the venue owner
- ✓ with the owner's new balance
- ✓ the owner is notified of the late cancellation
- ✓ the booking's ledger nets to exactly minus the penalty — the only money that left the player

**C  a yes that is really a correction must NOT spend money**

- ✓ a booking confirm is armed
- ✓ the live model still calls that sentence an affirm
- ✓ and it is the MODEL saying so, not the lexicon
- ✓ at 0.5898 — above the threshold, so the old gate WOULD have fired
- ✓ the rule extractor read "7 baje" as 19:00 and it reached the slots
- ✓ NO BOOKING WAS MADE — the model cannot fire the confirm gate
- ✓ and the turn does not report a completed booking
- ✓ the SAME ground reopens
- ✓ on the SAME day
- ✓ at the hour the user actually asked for — nearest to 19:00 first (19:00)
- ✓ the armed confirm is gone, not left waiting for a later yes

**C2  stale confirms, model denials, and the button that must still work**

- ✓ an unrelated turn clears the armed confirm
- ✓ so a later "haan" books NOTHING — a confirm lives exactly one turn
- ✓ and Scout asks what the yes was for: "Yes to what? Tell me and I will do it."
- ✓ the live model calls "nahi 8 baje karo" a deny
- ✓ from the model, so it may not fire the gate either
- ✓ the correction carries 20:00
- ✓ nothing is booked
- ✓ and the errand is re-run rather than abandoned: "Pick a time at Bahria Cricket Arena on Sat 29 Aug:"
- ✓ the confirm BUTTON runs the booking
- ✓ and it succeeds — the gate is closed to the model, not to the user
- ✓ exactly one booking exists for that slot

**D  reads: wallet · bookings · policy · tournaments · team rating · help · out of scope**

- ✓ a balance is answered live
- ✓ the wallet card is painted
- ✓ the card shows the spendable balance
- ✓ and the frozen balance SEPARATELY
- ✓ total is the sum of both
- ✓ and the sentence quotes the spendable number, not the total
- ✓ the booking list is live
- ✓ 1 booking cards for 20 bookings
- ✓ every card is one of THIS player's bookings
- ✓ a rules question is answered from POLICY, never from a query
- ✓ a policy card is painted
- ✓ the card carries the real deposit percent
- ✓ and the refund percent derived from it
- ✓ and the real cancellation window
- ✓ the sentence states the 24-hour window
- ✓ all 7 policy topics render with no unfilled placeholder
- ✓ a topic chip routes to that topic
- ✓ and the topic is cleared, so the next question starts fresh, not stuck on withdrawals
- ✓ the tournament list is live
- ✓ 0 open tournaments → 0 cards
- ✓ and the turn still offers somewhere to go: "There are no tournaments on SportLynk yet. I will list them here as so"
- ✓ "hamari team ki rating kitni hai" → team_stats (there is no my_elo intent: FR2.6 rates TEAMS)
- ✓ a captain of more than one team is asked WHICH, by chip, not guessed at
- ✓ a rating is read live, never remembered
- ✓ the team card is painted: "Demo United is rated 1185. 8W-3L-2D from 13 played, 62% win rate. Rece"
- ✓ played count is profileStats' own (13)
- ✓ the wins are the same wins
- ✓ and the losses the same losses
- ✓ the raw elo is the stored elo (1185)
- ✓ isRanked is profileStats' verdict (true)
- ✓ and displayElo agrees with it (1185)
- ✓ a ranked team is told its number (1185)
- ✓ and its record, in one string (8W-3L-2D)
- ✓ and offers the how-does-rating-work explainer next to the number
- ✓ a player with no team is told so: "You are not in a team yet, so there is no rating to show."
- ✓ and no team is invented to fill the card
- ✓ with somewhere to go instead (ER2.6)
- ✓ app_help explains the app: "SportLynk in one paragraph — Grounds: Browse or search groun..."
- ✓ and offers buttons
- ✓ the capability list is sourced as a menu
- ✓ the capabilities card is painted
- ✓ 16 capabilities listed
- ✓ grouped into 4 sections
- ✓ and EVERY item on the menu is an action Scout can actually run
- ✓ a question outside SportLynk lands on the menu
- ✓ and says so honestly: "That one is outside my ground. I'm Scout — I only do SportLynk: ground"
- ✓ with chips, so it is not a dead end (ER2.6)

**E  escalation → the owner answers → the next ask is free**

- ✓ a question only the owner can answer is sourced as escalated
- ✓ and is accepted: "Asked the owner of Bahria Cricket Arena. You will get a notification t"
- ✓ the reply carries the escalation id
- ✓ the queue row is open
- ✓ filed against the right ground
- ✓ and addressed to its owner
- ✓ and it remembers WHICH chat to answer into
- ✓ the owner is notified there is a question waiting
- ✓ asking the identical question again does NOT file a second queue item
- ✓ there is still exactly one row for it
- ✓ a MONEY question is refused entry to the owner queue — POLICY is not the owner's to redefine
- ✓ the owner answers the queued question
- ✓ the answer is published, not left a draft
- ✓ and scoped to that ONE venue — never applied to other grounds
- ✓ stored verbatim
- ✓ the queue row closes
- ✓ pointing at the KB entry it produced
- ✓ and records who answered
- ✓ the answer is DELIVERED into the player's own chat thread
- ✓ a Scout message carrying it is in the thread
- ✓ and that message re-renders as a KB answer when the user scrolls back
- ✓ and the player is notified it landed
- ✓ the SAME question is now answered from the knowledge base
- ✓ with the owner's own words
- ✓ from the entry the owner just wrote
- ✓ and the reuse is counted
- ✓ the owner is NOT disturbed a second time
- ✓ and Scout does not pretend to ask again: "Yes — four floodlight towers, and night slots run until 2am."

**F  discovery: ground info · directions · players · opponents · teams**

- ✓ venue_info paints the ground
- ✓ the right ground
- ✓ with the name the venue page shows
- ✓ and names it in the sentence
- ✓ and offers to show times
- ✓ navigate paints a map card
- ✓ for that ground
- ✓ hasPin states honestly whether the venue has coordinates
- ✓ a geo: URI Android can open (geo:33.53000000,73.12000000?q=Bahr...)
- ✓ and a Maps URL as the fallback
- ✓ the URL routes to a pin when there is one and searches the address when there is not
- ✓ 2 joinable teams → 2 cards
- ✓ every team card carries the id a join request needs
- ✓ strongest first, as the sentence claims
- ✓ 2 squads → Scout asks which one instead of guessing: "Which team am I finding players for?"
- ✓ one chip per squad, so nobody types a team name
- ✓ and every chip carries a team the user really administers
- ✓ 5 suggestions for Demo United → 5 player cards
- ✓ a weighted scorer does not earn the AI badge (ranking source: ranked)
- ✓ and meta.ranking keeps what the badge cannot say: ranked
- ✓ a ranked answer carries a match percentage
- ✓ and never suggests the asker to themselves
- ✓ and every card is a player the ranking service actually returned
- ✓ 2 opponents → 2 team cards
- ✓ and never offers the team its own squad as an opponent
- ✓ every opponent card is one the ranking service returned, in its order
- ✓ and the badge does not call a weighted mean a model
- ✓ while meta.ranking still names the scorer: ranked

**G  threads: new · switch · rename · archive · delete · ownership**

- ✓ a new chat can be started
- ✓ it starts as "New chat"
- ✓ with the player persona by default
- ✓ and a clean dialog state
- ✓ at state version 1
- ✓ the FIRST message names the chat, the way every chat app does
- ✓ "islamabad mein cricket ground chahiye s..." — trimmed to fit a phone
- ✓ a rename squashes whitespace and sticks
- ✓ and a later message does NOT overwrite a name the user chose
- ✓ an empty rename is refused
- ✓ the chat just used is at the TOP of the list
- ✓ the list is ordered newest-activity-first, the order the chat drawer shows
- ✓ and it holds only open chats
- ✓ 2 chats listed — switching between them is just an id
- ✓ 4 messages stored in this chat
- ✓ the QUESTION is the first bubble
- ✓ and Scout's answer is the second
- ✓ the question is stored verbatim
- ✓ user and Scout strictly alternate — no bubble is out of order anywhere
- ✓ the answer is stamped AFTER the question, never before (740ms apart - the model call sits between them)
- ✓ a tie on time is broken by kind, so a question can never render under its own answer
- ✓ and the pagination cursor compares the SAME three fields it sorts by
- ✓ old Scout turns keep their payload, so scrolling back re-renders cards
- ✓ and every stored payload still carries a legal answer.source
- ✓ 2 pages of 2 walked back through the chat
- ✓ paging 2-at-a-time returns EVERY message exactly once, in the same order as one big read
- ✓ no message is served twice by two pages
- ✓ a junk cursor from a client is treated as "no cursor", not an error
- ✓ a chat can be archived
- ✓ archiving hides it from the chat list
- ✓ but it is still there when asked for
- ✓ and its messages are NOT destroyed — archive is not delete
- ✓ unarchiving brings it back
- ✓ 2 messages written into the chat about to be deleted
- ✓ the user can delete a chat
- ✓ and it is gone
- ✓ its messages are gone with it — deleting a chat really deletes what was said in it
- ✓ deleting it twice is a clean 404, not a crash
- ✓ chat 51 is refused instead of letting the drawer grow forever
- ✓ with a 409, and a sentence telling the user to archive one
- ✓ "You have 50 open chats. Archive one to start another."
- ✓ and archiving one frees the slot, exactly as that sentence promised
- ✓ 2 chats left after the cap test cleaned up after itself
- ✓ another user asking for this chat by id gets NOTHING back
- ✓ and no messages — ownership is re-checked in the JOIN, not trusted
- ✓ they cannot rename it
- ✓ they cannot delete it
- ✓ and they cannot post into it either
- ✓ a 404, which does not even confirm the chat exists
- ✓ the owner's chat is untouched by all of that
- ✓ a client that sends no chat id still gets an answer
- ✓ in the newest open chat, or a fresh one
- ✓ an owner's chat is marked owner — same Scout, different side of the ground

**H  FR8.15 — one implementation of every rule, shared by route and Scout**

- ✓ 50 source files scanned
- ✓ exactly ONE file in the whole backend inserts a booking
- ✓ and it is the shared service, not a route and not the assistant
- ✓ written once inside it, not twice
- ✓ Scout cannot insert a booking — it has no such code at all
- ✓ Scout cannot move a wallet — it has no such code at all
- ✓ Scout cannot write a ledger row — it has no such code at all
- ✓ Scout cannot split a penalty — it has no such code at all
- ✓ Scout cannot lock a wallet — it has no such code at all
- ✓ Scout cannot free a slot — it has no such code at all
- ✓ it goes through bookingService for all of it
- ✓ the REST route calls the same two functions Scout calls
- ✓ and books/cancels without touching a wallet itself — transport only
- ✓ the owner-settle route keeps its own ledger, which Scout does not expose (not duplicated logic)
- ✓ searchVenues returns 10 grounds for GET /api/venues
- ✓ only active grounds, as the venue list page needs
- ✓ with the cover photo and owner name the card renders — the response bytes did not change
- ✓ default order is still rating-first (NULLS LAST), the S.5 Wave A ordering
- ✓ and sort=price_low still sorts
- ✓ a filter that matches nothing returns an empty list, not everything
- ✓ a ground asked about a PAST date answers with no slots rather than an error
- ✓ and tomorrow lists 15 slots
- ✓ a junk ground id is a 400 with a human sentence
- ✓ and an unknown one is a 404
- ✓ discoverTeams answers GET /api/teams/discover with 2 teams
- ✓ listTournaments answers the tournaments list (0 open)
- ✓ suggestPlayers answers for GET /api/teams/:id/suggest-players (ok)
- ✓ with a suggestions array (5 players)
- ✓ and an honest model flag — ranking.available=true
- ✓ suggestOpponents answers for the opponent finder too
- ✓ with an opponents array (2 teams)
- ✓ a non-admin is refused by the SERVICE, not by the route — so Scout is refused too
- ✓ a junk team id is rejected with the same words for both callers
- ✓ assistant_turns has 17 columns of telemetry
- ✓ and not one free-text column that could hold what the user typed
- ✓ the length is logged instead — enough to study long questions, useless as a transcript
- ✓ the turn WAS logged — with its length, its intent and its confidence
- ✓ and the sentence itself lives in exactly ONE place: the user's own chat
- ✓ so deleting the chat really does erase it — nothing else kept a copy
- ✓ while the telemetry survives with a NULL channel — measurable, and no longer linked to a chat

**I  the milestone utterance — "kal shaam football islamabad", end to end**

- ✓ "kal shaam football islamabad" → find_venue
- ✓ answered rather than sent to the abstain menu (source model)
- ✓ and it was the MODEL that read it, not a chip (0.8108)
- ✓ the sport came out of the sentence, not out of a fixture
- ✓ "kal" resolved to tomorrow in PKT (2026-08-30)
- ✓ and "shaam" reached the slots as the 18:00-21:00 window start
- ✓ and the city survived the parse (Islamabad)
- ✓ Scout offered grounds to tap (3)
- ✓ every ground offered is a football ground
- ✓ the picker is for the ground that was tapped
- ✓ and for the day the utterance asked for, not for today (2026-08-30)
- ✓ tapping a time arms a confirm card
- ✓ armed for book_venue
- ✓ quoting the price the picker showed
- ✓ the chain ends in a booking: "Booked. F-11 Markaz Football Arena, Sun 30 Aug at 6:00 PM. PKR 2,000 is held in "
- ✓ and a booking card to show for it
- ✓ THE BOOKING EXISTS — the checklist line, as a row
- ✓ it is the slot that was tapped
- ✓ booked for the player who typed the sentence
- ✓ at the ground Scout offered
- ✓ for the quoted price
- ✓ with the POLICY deposit held
- ✓ and the slot is no longer on sale
- ✓ ON THE DAY "kal" MEANT — the whole point of the Roman-Urdu parse
- ✓ the ledger is correct: balance fell by the price (5660 → 3660)
- ✓ the same money sits in escrow, not nowhere
- ✓ and nothing was minted or burned on the way
- ✓ one booking_payment row in the ledger (booking_payment)
- ✓ for the negative of the price
- ✓ and balance_after matches the wallet the user will see

### The 45 turns this run actually drove

| said to Scout | intent | conf | source | what Scout said back |
|---|---|---|---|---|
| "rawalpindi mein cricket ground chahiye" | find_venue | 0.73 | model | For you — 2 grounds I think suit you: |
| [check_availability] | check_availability | — | live | Bahria Cricket Arena on Sat 29 Aug — 6 slots free: |
| [pick_slot] | pick_slot | — | live | Bahria Cricket Arena, Sat 29 Aug at 8:00 AM — PKR 2,200. Book it? |
| "haan" | affirm | — | live | Booked. Bahria Cricket Arena, Sat 29 Aug at 8:00 AM. PKR 2,200 is held in escrow and the o |
| [cancel_booking] | cancel_booking | — | live | Cancelling Bahria Cricket Arena, Sat 29 Aug at 8:00 AM: you get PKR 1,760 back (80%). That |
| "haan" | affirm | — | live | Cancelled. PKR 1,760 is back in your wallet and PKR 440 of the deposit went to Bahria Cric |
| [pick_slot] | pick_slot | — | live | Bahria Cricket Arena, Sat 29 Aug at 8:00 AM — PKR 2,200. Book it? |
| "haan lekin 7 baje" | affirm | 0.59 | live | Pick a time at Bahria Cricket Arena on Sat 29 Aug: |
| [pick_slot] | pick_slot | — | live | Bahria Cricket Arena, Sat 29 Aug at 8:00 AM — PKR 2,200. Book it? |
| [wallet_balance] | wallet_balance | — | live | You have PKR 7,860 available to spend. |
| "haan" | affirm | — | live | Yes to what? Tell me and I will do it. |
| [pick_slot] | pick_slot | — | live | Bahria Cricket Arena, Sat 29 Aug at 8:00 AM — PKR 2,200. Book it? |
| "nahi 8 baje karo" | deny | 0.55 | live | Pick a time at Bahria Cricket Arena on Sat 29 Aug: |
| [pick_slot] | pick_slot | — | live | Bahria Cricket Arena, Sat 29 Aug at 8:00 AM — PKR 2,200. Book it? |
| [confirm] | confirm | — | live | Booked. Bahria Cricket Arena, Sat 29 Aug at 8:00 AM. PKR 2,200 is held in escrow and the o |
| [wallet_balance] | wallet_balance | — | live | You have PKR 5,660 available to spend. PKR 2,200 is held in escrow for bookings you have n |
| [my_bookings] | my_bookings | — | live | You have 1 upcoming booking, 1 still waiting on owner approval: |
| "refund policy kya hai" | refund_policy | 0.92 | policy | Cancel 24h or more before your slot starts and you get a full refund. Cancel later than th |
| [refund_policy] | refund_policy | — | policy | You can withdraw any unfrozen balance above PKR 200 from the Wallet screen. Money held in |
| [tournament_list] | tournament_list | — | live | There are no tournaments on SportLynk yet. I will list them here as soon as an organiser p |
| "hamari team ki rating kitni hai" | team_stats | 0.88 | live | Which team? |
| [team_stats] | team_stats | — | live | Demo United is rated 1185. 8W-3L-2D from 13 played, 62% win rate. Recent form W. 1 match i |
| [team_stats] | team_stats | — | live | You are not in a team yet, so there is no rating to show. |
| "app kaise use karun" | app_help | 0.76 | live | SportLynk in one paragraph — Grounds: Browse or search grounds, filter by sport, city, pri |
| [capability_menu] | capability_menu | — | menu | I'm Scout — I help with grounds, bookings, teams and your wallet. Here is what I can do: |
| "mausam kaisa hai aaj" | out_of_scope | 0.70 | menu | That one is outside my ground. I'm Scout — I only do SportLynk: grounds, bookings, teams, |
| [contact_owner] | contact_owner | — | escalated | Asked the owner of Bahria Cricket Arena. You will get a notification the moment they answe |
| [contact_owner] | contact_owner | — | escalated | Someone already asked Bahria Cricket Arena exactly that and it is still with the owner. I |
| [contact_owner] | contact_owner | — | kb | Yes — four floodlight towers, and night slots run until 2am. |
| [venue_info] | venue_info | — | live | Bahria Cricket Arena — Rawalpindi · PKR 2,200/hour · rated 4.5 (89). |
| [navigate] | navigate | — | live | Bahria Cricket Arena, Rawalpindi — tap to open the route. |
| [find_teams] | find_teams | — | live | 2 teams you can join, strongest first. Open one to send a join request. |
| [find_players] | find_players | — | live | Which team am I finding players for? |
| [find_players] | find_players | — | live | 5 players for Demo United, best fit first. |
| [find_opponents] | find_opponents | — | live | 2 teams you could play — Demo United is rated 1185 — 2 within 400 points. Closest match fi |
| "islamabad mein cricket ground chahiye shaam ke liye" | find_venue | 0.77 | model | For you — 3 grounds I think suit you: |
| "wallet balance batao" | wallet_balance | 0.93 | live | You have PKR 5,660 available to spend. PKR 2,200 is held in escrow for bookings you have n |
| "mera wallet dikhao" | wallet_balance | 0.63 | live | You have PKR 5,660 available to spend. PKR 2,200 is held in escrow for bookings you have n |
| "wallet balance" | chip | — | — | That chat does not exist. |
| "kya kar sakte ho" | create_team_help | 0.68 | live | Open Teams and tap the + button: name your cricket squad, pick the sport, and choose Publi |
| "yahan ka refund kaisay milta hai bhai" | refund_policy | 0.60 | policy | Cancel 24h or more before your slot starts and you get a full refund. Cancel later than th |
| "kal shaam football islamabad" | find_venue | 0.81 | model | For you — 3 grounds I think suit you: |
| [check_availability] | check_availability | — | live | F-11 Markaz Football Arena on Sun 30 Aug around 6:00 PM — 6 slots free: |
| [pick_slot] | pick_slot | — | live | F-11 Markaz Football Arena, Sun 30 Aug at 6:00 PM — PKR 2,000. Book it? |
| [confirm] | confirm | — | live | Booked. F-11 Markaz Football Arena, Sun 30 Aug at 6:00 PM. PKR 2,000 is held in escrow and |

<!-- scout-evidence:service END -->

<!-- scout-evidence:http BEGIN -->

## Block 2 -- the same assistant over real Express, with real JWTs

Nothing here is called directly. Every line below went over HTTP to a listening server through the auth middleware and the rate limiter, so the route projections, the status codes and SEC-6 are exercised rather than argued from source. Residue is deleted in a `finally`, and the last block is the one claim that can only be made AFTER the delete.

**PASS 173/173** · 0 skipped · produced Aug 29, 2026, 06:38:40 PKT (2026-08-29T01:38:40.495Z)

| provenance | value |
|---|---|
| command | `cd backend && node src/scripts/check_assistant_http.js --evidence` |
| commit | `c751102` — feat: implement Wave S6-C Scout (dialog manager & actions) [278/278 · 60/60 · 78/78 · migration 018 36/36] · **31 uncommitted path(s) in the tree** |
| node | v22.19.0 on win32 |
| transport | http://localhost:3000/api · attached to a server that was already listening · real JWTs signed with the real secret |
| model #4 (intent NLU) | intent-v2-20260828-2315 · threshold 0.45 |
| endpoints exercised | 16 assistant routes · TESTING.md 4.20 steps 196 / 197 / 200 |
| cast | Bilal Raza (player) · Hina Farooq (stranger) · Ahmed Khan (owner of Bahria Cricket Arena) |

### What this run establishes

- **SEC-6 is enforced on the assistant routes, and says so** — Request 21 from one IP inside the window was refused 429 with the exact sentence a client shows, `RateLimit-Policy: 20;w=60`, and `Retry-After: 60`. Found by a FAILING assertion: four bad-header cases came back 429 instead of 401 because the logins above them had already spent the anonymous quota.
- **A confident model affirm cannot spend PKR, proved over HTTP** — `haan lekin 7 baje` parsed `affirm` at 0.5898 via `model` -- above the 0.45 threshold -- with a booking armed and waiting. Census either side of that one turn: bookings 27 to 27, balance 8300.00 to 8300.00. Money is gated by chip-or-lexicon only.
- **Deleting a conversation does not delete its telemetry** — The thread this run created was deleted through the API, and all 19 of its `assistant_turns` rows are still there with `channel_id` nulled 19/19 -- migration 018's `ON DELETE SET NULL`, which is why a user can clear their history without erasing the corpus the next model is trained on.

### Every assertion, in the order it was made
  > attached to the server already listening on http://localhost:3000/api

**0  preflight — the server, the model, and a cast to act with**

- ✓ GET /api/health answers 200 (SportLynk API is healthy)
- ✓ model #4 reachable and agrees on all labels (intent-v2-20260828-2315, threshold 0.45)
- ✓ there is an active player to be
- ✓ and a second one to be a stranger to them
- ✓ and an owner with a ground (Ahmed Khan / Bahria Cricket Arena)

**A  the door — four bad headers, then all sixteen with none at all**

- ✓ a header with no scheme → 401
- ✓ and says why, in words a screen can show: "Token format: Bearer <token>"
- ✓ the wrong scheme → 401
- ✓ and says why, in words a screen can show: "Token format: Bearer <token>"
- ✓ a forged token → 401
- ✓ and says why, in words a screen can show: "Unauthorized"
- ✓ an EXPIRED token → 401
- ✓ and says why, in words a screen can show: "Token expired. Please log in again."
- ✓ the surface under test is all 16 endpoints of routes/assistant.js
- ✓ all 16 answer 401 with no Authorization header — one router.use(auth)
- ✓ a real token opens the same door (counted per user, not per IP)

**A2 the anonymous quota — SEC-6, over the wire**

- ✓ the 21st anonymous request in a minute → 429, in the same envelope as every other error
- ✓ and publishes the policy it enforced (20 per 60s), so a client need not guess
- ✓ and Retry-After says when to come back (60s)
  > spent the anonymous quota on purpose and waited 62s for it to reset
  > tokens: player via login, stranger via login, owner via login

**B  a turn through Express — the envelope, the cards, the parse**

- ✓ POST /message "Rawalpindi mein cricket ground chahiye" → 200
- ✓ in the {success, data} envelope every Flutter screen parses
- ✓ and it names the chat it landed in (75660cb3-fff5-446b-9134-d55d8a09442d)
- ✓ which it created, because the request named none
- ✓ model #4 read it as find_venue over the wire
- ✓ with a confidence the client can show (0.7305)
- ✓ 2 venue cards came back
- ✓ sourced honestly (model)
- ✓ and every reply ships chips — no free-text dead end
- ✓ the FSM state comes back for the client (idle)
- ✓ and the message id a thumbs-up needs

**B2 the milestone utterances — Roman Urdu in, real data out**

- ✓ POST /message "kal shaam football islamabad" → 200
- ✓ the keyword query is read as find_venue (0.8108)
- ✓ and it answers with grounds or an honest empty-handed sentence
- ✓ the sport survived the parse ("football")
- ✓ and "kal" resolved to a date, in PKT (2026-08-30)
- ✓ POST /message "order me a pizza" → 200, not a 400
- ✓ the model calls it out of scope itself
- ✓ and Scout answers with the capability menu rather than an apology
- ✓ the menu offers what it CAN do, as buttons
- ✓ a graceful decline, not a failure: "That one is outside my ground. I'm Scout — I only do SportLynk: "

**C  the request body — four spellings, one omission, a chip, a cursor**

- ✓ all four spellings of the chat id land in the SAME chat — Wave D cannot 400 over a naming preference
- ✓ omitting the chat id entirely is legal
- ✓ and means "the newest chat", not "a new one"
- ✓ so the drawer did not grow a thread behind the user
- ✓ a tapped chip posts {action:"find_venue"} with NO text → 200
- ✓ and the parse block says the answer came from a BUTTON
- ✓ carrying no confidence and no model version — a tap must not enter measured accuracy
- ✓ while still naming the intent the button stands for
- ✓ while still answering with a real bubble

**C2 the transcript cursor — verbatim, or it silently drops a message**

- ✓ GET /threads/:id/messages?limit=3 → 200
- ✓ a page of exactly the size asked for
- ✓ and it says there is more, because there is
- ✓ the cursor is a row id, not an offset (5c3b33ae-62d4-4164-8a94-b6f34fbdfa71)
- ✓ every message names who said it, oldest first within the page
- ✓ passing that cursor back verbatim → 200
- ✓ the older page shares no row with the newer one (3 more)
- ✓ a cursor somebody hand-edited does not 500
- ✓ it is ignored and the newest page comes back — a garbage cursor must not empty the screen
- ✓ and the page names its own thread, so a late response cannot render into the wrong chat

**D  new chat → rename → archive → restore → thumbs → delete**

- ✓ POST /threads → 201 Created, not 200
- ✓ and returns the row (eb42688d-fca7-4995-8d75-24fdfd48752a)
- ✓ with the title it was given
- ✓ the drawer shows it
- ✓ and tells the client the ceiling (50) instead of making it guess
- ✓ PATCH {title} renames it
- ✓ to exactly that
- ✓ an EMPTY title is a 400, not a silent revert to the default
- ✓ and a body with neither title nor archived is a 400
- ✓ PATCH {archived:true} archives it
- ✓ the drawer stops showing it
- ✓ but ?archived=1 finds it
- ✓ and restoring puts it back

**D2 feedback — changeable, not stuffable, and never on a stranger message**

- ✓ POST /messages/:id/feedback {vote:1} → 200
- ✓ recorded as a thumbs up
- ✓ voting again is a CHANGE of mind, not a second row
- ✓ now a thumbs down
- ✓ and it is the same row — one vote per person per message
- ✓ a vote that is neither up nor down is a 400
- ✓ and a message id that is not theirs matches nothing → 404, never a vote
- ✓ a non-uuid message id is a 404, not a 500 from Postgres

**E  a stranger chat — 404 and nothing else**

- ✓ GET another player's /threads/:id/messages → 404
- ✓ and the body does not leak their title
- ✓ nor admits the chat exists by saying "forbidden"
- ✓ POST /message into another player's chat → 404 thread_not_found
- ✓ and renaming it → 404
- ✓ and deleting it → 404
- ✓ while its real owner still has it
- ✓ a non-uuid thread id is a 404, not a 500 from a failed uuid cast
- ✓ but a non-uuid session_id on /message means "no id given" — a bad id must not lock a user out of chatting

**F  a 501-character message, and the 500-character boundary**

- ✓ the parser limit this checks against is 500 chars
- ✓ 501 chars → 200 with a bubble, never a 422 forwarded to the screen
- ✓ the abstention names its reason
- ✓ and says plainly that it abstained
- ✓ and the answer is the capability menu
- ✓ no intent was invented for it
- ✓ exactly 500 chars is ACCEPTED and parsed
- ✓ the boundary is inclusive — 500 is fine, 501 is not
- ✓ a body with neither text nor action is a 4xx (400), not a crash

**F2 the role gate — the owner half is not a player URL**

- ✓ all 8 owner endpoints answer 403 Access denied to a player token

**H  the capability list — one source for the help sheet and the abstain menu**

- ✓ GET /capabilities → 200
- ✓ 16 capabilities, each with an action, a label, a group and a sentence
- ✓ and the routable action list the client can trust (23 labels)
- ✓ every entry is a label the registry really routes
- ✓ no capability advertises a button that would 400 when tapped
- ✓ the menu payload is sourced as menu, not as an answer
- ✓ and ships 6 chips, so the abstain reply and the help sheet agree
- ✓ grouped for rendering (Discover · Booking · Team · Money)

**I  escalate → the owner answers → the next ask is free (source: kb)**

- ✓ the player asks the owner a question → 200
- ✓ sourced as escalated, not answered
- ✓ and the reply carries the queue id (bf6294a7-751a-4b0b-babf-90081318be70)
- ✓ and the owner is notified there is a question waiting
- ✓ GET /owner/questions as the ground's owner → 200
- ✓ the question is in THEIR queue (1 open)
- ✓ marked open
- ✓ and the response states which intents may never enter the queue — money and policy

**I2 the answer — one transaction, delivered into the asker own chat**

- ✓ a DIFFERENT owner may open the queue endpoint
- ✓ but does not see a question about somebody else's ground
- ✓ and cannot answer it (403) — ownership is resolved through venues.owner_id, never from the body
- ✓ an EMPTY answer is refused (400) — a blank KB row would teach Scout to say nothing
- ✓ the owner answers → 200
- ✓ and a KB entry is written (0284ac6b-a296-46aa-929a-4265fe9fef43)
- ✓ published, not left a draft
- ✓ and scoped to that ONE ground — never applied to other venues
- ✓ stored verbatim
- ✓ and DELIVERED into the player's own chat
- ✓ the answer is a Scout message in the player's transcript
- ✓ and it re-renders as a KB answer when they scroll back, days later

**I3 the payoff — the same question, answered free, owner not disturbed**

- ✓ the player asks the identical question again → 200
- ✓ answered from the knowledge base this time
- ✓ in the owner's own words
- ✓ from the entry the owner just wrote
- ✓ and Scout does not pretend to ask again
- ✓ there is still exactly ONE queue row for it — the owner is not disturbed twice
- ✓ GET /owner/kb → 200, the audit view
- ✓ the entry is listed for its owner
- ✓ with the serve counter the wave report quotes (1)
- ✓ GET /owner/stats → 200
- ✓ and reports what Scout has been saying on their behalf (kb, escalations, minSimilarity, trgm)

**I4 KB upkeep, a decline that teaches nothing, and policy that never escalates**

- ✓ an owner may PRE-EMPT a question instead of waiting to be asked (201)
- ✓ a KB row with no venue is a 400 — an answer with no ground is unservable
- ✓ PATCH /owner/kb/:id rewrites an answer
- ✓ and a status-only body retires one without retyping it
- ✓ while an empty body is a 400
- ✓ and a KB id that is not theirs → 404, never somebody else's row deleted
- ✓ POST /owner/questions/:id/decline → 200
- ✓ the queue row closes as declined
- ✓ and writes NO KB entry — a declined question must not teach Scout anything

**J  the confirm gate — a confident model affirm may not spend PKR**

- ✓ availability is answered live, from slots
- ✓ the picker button carries its slot id
- ✓ the confirm card knows which action it is arming
- ✓ and the FSM says money is next
- ✓ the correction is answered, not rejected
- ✓ the shipped model still calls "haan lekin 7 baje" an affirm
- ✓ and it is the MODEL saying so — no chip, no lexicon
- ✓ at 0.5898 — over the 0.45 floor, so an intent-only gate WOULD have fired
- ✓ the rule extractor read "7 baje" as 19:00
- ✓ the armed confirm is gone, not left waiting for a later yes (fsm: awaiting_choice)
- ✓ the turn does not report a completed booking
- ✓ NO BOOKING WAS MADE over HTTP — 27 before, 27 after
- ✓ the wallet did not move (8300.00)
- ✓ and nothing was frozen into escrow
- ✓ a bare "haan" with nothing armed is still answered
- ✓ "haan" IS decided by the frozen lexicon
- ✓ and it bought nothing, because the armed block was already gone
- ✓ the wallet is still untouched after the stale yes
  > money gate held: bookings 27 → 27, balance 8300.00 unchanged

**G  the 51st chat — a named 409, not a silent 50-chat ceiling**

  > filling from 1 open chats to 50 (49 to create)
- ✓ the 51st chat → 409 Conflict
- ✓ and says what to do about it: "You have 50 open chats. Archive one to start another."
- ✓ and no row was created for it
- ✓ archiving one frees the slot — the ceiling counts OPEN chats, as the message claims

**K  residue — what a live run leaves in the database**

- ✓ this run measured 19 turn(s) in assistant_turns
- ✓ and none of its 17 columns can hold the utterance itself
  > player has 2 open Scout thread(s) after cleanup (cap 50)
  > 19 of 19 telemetry rows still point at a live thread — the FK claim is checked again after cleanup deletes those threads

**L  after the delete — the telemetry the FK was written to keep**

- ✓ all 19 telemetry rows SURVIVED the chat being deleted (ON DELETE SET NULL)
- ✓ each with its channel_id nulled — orphaned on purpose, never cascaded away

### The 19 turns this run actually drove

| said to Scout | intent | conf | source | what Scout said back |
|---|---|---|---|---|
| "rawalpindi mein cricket ground chahiye" | find_venue | 0.7305 | model (via model) | For you — 2 grounds I think suit you: |
| "kal shaam football islamabad" | find_venue | 0.8108 | model (via model) | For you — 3 grounds I think suit you: |
| "order me a pizza" | out_of_scope | 0.8790 | menu (via model) | That one is outside my ground. I'm Scout — I only do SportLynk: grounds, bookings, teams, |
| "wallet mein kitna hai" | wallet_balance | 0.7896 | live (via model) | You have PKR 8,300 available to spend. |
| "wallet mein kitna hai" | wallet_balance | 0.7896 | live (via model) | You have PKR 8,300 available to spend. |
| "wallet mein kitna hai" | wallet_balance | 0.7896 | live (via model) | You have PKR 8,300 available to spend. |
| "wallet mein kitna hai" | wallet_balance | 0.7896 | live (via model) | You have PKR 8,300 available to spend. |
| "my bookings" | my_bookings | 0.9096 | live (via model) | Your last 5 bookings: |
| [find_venue] | find_venue | — | model (via chip) | For you — 3 grounds I think suit you: |
| "wallet balance" | wallet_balance | 0.9302 | live (via model) | You have PKR 8,300 available to spend. |
| "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" | chip | — | menu (via model) | That is a lot for one message. Say the main thing in a sentence and I will take it from th |
| "ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground ground chahiye" | chip | 0.3832 | menu (via model) | I am not sure I got that. Did you mean one of these? |
| [contact_owner] | contact_owner | — | escalated (via chip) | Asked the owner of Bahria Cricket Arena. You will get a notification the moment they answe |
| [contact_owner] | contact_owner | — | kb (via chip) | Yes — four floodlight towers, night slots until 2am. (check 67459979) |
| [contact_owner] | contact_owner | — | escalated (via chip) | Asked the owner of Bahria Cricket Arena. You will get a notification the moment they answe |
| [check_availability] | check_availability | — | live (via chip) | Bahria Cricket Arena on Sat 29 Aug — 6 slots free: |
| [pick_slot] | pick_slot | — | live (via chip) | Bahria Cricket Arena, Sat 29 Aug at 8:00 AM — PKR 2,200. Book it? |
| "haan lekin 7 baje" | affirm | 0.5898 | live (via model) | Pick a time at Bahria Cricket Arena on Sat 29 Aug: |
| "haan" | affirm | — | live (via lexicon) | Yes to what? Tell me and I will do it. |

<!-- scout-evidence:http END -->
