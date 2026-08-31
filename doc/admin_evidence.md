# Admin — the evidence pack

**This file is generated. Do not edit it by hand.** Every line below was written by a
verification script that had just asserted it against the live database, inside one
transaction that was then rolled back — so the run leaves no rows behind and the
document is reproducible rather than a description of a state somebody once had. To
regenerate:

```
cd backend && node src/scripts/check_admin.js --evidence
```

A block absent from this file was not run — it is not a pass.

<!-- admin-evidence:admin BEGIN -->

## S.7 Wave D -- rulings, suspension, live settings and the financial export

A disputed match is ruled through the same verified path an owner uses and the ladder moves exactly ONCE -- a second ruling on the same dispute is refused and every rating is unchanged after it; a fixture ruling advances the bracket inside the same transaction; a suspension cancels and refunds the upcoming booking, closes an owner's venues and makes an ALREADY-ISSUED token return 403 on its next request; a commission and a deposit written by the settings route reach the next booking with no restart; and the export escapes a venue named =1+1 so it cannot execute when the owner opens their own report in Excel. One transaction, rolled back at the end.

**PASS 275/275** · 0 skipped · produced Aug 31, 2026, 01:55:41 PKT (2026-08-30T20:55:41.734Z)

| provenance | value |
|---|---|
| command | `cd backend && node src/scripts/check_admin.js --evidence` |
| commit | `352a587` — feat: implement Tournaments feature · **106 uncommitted path(s) in the tree** |
| node | v22.19.0 on win32 |
| venue | F-11 Markaz Football Arena (Islamabad) |
| migration 021 | applied |

### What this run establishes

- **Deposit % before** — 20%
- **Commission % before** — 0%
- **Severity of the ruled dispute** — 16 ELO points at stake
- **Ruling exchange** — 1200→1216 vs 1200→1184 at K=32
- **Overturn** — challenger 1216 → 1184, opponent 1184 → 1216 (K=32)
- **Fixture ruling** — semi-final settled at K=48; winner advanced to the final
- **Suspension cascade** — 1 booking cancelled, PKR 2000 refunded, slot released

### Every assertion, in the order it was made

**Block 0 · The settings catalog holds together**

- ✓ the catalog describes 26 writable fields
- ✓ every field writes a global_settings row globalSettings reads
- ✓ every field belongs to a section the screen renders
- ✓ every write band sits INSIDE the accessor read clamp (no silently-clamped save)
- ✓ every documented default is a value the write band accepts

**Block 1 · The settings screen refuses what the accessor would quietly clamp**

- ✓ a K-factor of 900 is refused
- ✓ and the message names the band
- ✓ a 60% commission is refused (the accessor stops at 50)
- ✓ and the message carries the unit
- ✓ commission + deposit over 100% of the slot price is refused
- ✓ and says why (nobody has that money)
- ✓ a half-finished prize split (80 with the stored 30) is refused
- ✓ rather than being silently reverted to 70/30 by the accessor
- ✓ a minimum above the largest bracket is refused
- ✓ a typo'd key is refused rather than ignored
- ✓ and the response NAMES the key it did not know
- ✓ switching every sport off is refused
- ✓ with the consequence spelled out
- ✓ a legal single-field patch validates
- ✓ the row carries the new k_factor
- ✓ and still carries base — a merge, not a replace
- ✓ the diff is exactly the one field that changed
- ✓ saving an unchanged value writes no row (and therefore no audit entry)

**Block 2 · A settings write is live on the very next operation**

- ✓ the deposit accessor returns 35% immediately after invalidate()
- ✓ the commission accessor returns 7.5% immediately
- ✓ commissionSplit(2000, 7.5%) takes PKR 150
- ✓ and leaves the owner PKR 1850
- ✓ the split loses nothing to rounding
- ✓ the ledger accepts a 'platform_commission' row (migration 021 applied)
- ✓ a PKR 2000 booking created after the write stamps deposit_amount = 700 (35%)
- ✓ while the slot price itself is untouched
- ✓ and the total the player paid into escrow is the full price
- ✓ an existing booking keeps its own stamped deposit (the column, not the percent, is authoritative)
- ✓ football is switched off
- ✓ cricket is still on
- ✓ and a booking for a switched-off sport is REFUSED by the service
- ✓ with 409
- ✓ code 'sport_disabled'
- ✓ with a message a player can read
- ✓ football restored for the rest of the run

**Block 3 · The queue and the case file**

- ✓ the open queue reads
- ✓ and contains the dispute just raised
- ✓ severityElo triages by the rating at stake (16 points)
- ✓ the match is not rated yet
- ✓ both teams submitted a result
- ✓ the challenger side is identified
- ✓ and so is the team that raised it
- ✓ age is reported in hours for triage
- ✓ the page is sorted by severity descending
- ✓ the case file reads
- ✓ it carries BOTH submissions
- ✓ and records that they disagree — which is the dispute
- ✓ the challenger's own submission says 3
- ✓ the opponent says 1 — verbatim, not reconciled
- ✓ both rosters are attached
- ✓ the booking, its venue and the venue owner are attached
- ✓ the case file says the dispute can still be ruled
- ✓ and that this is a first rating, not a correction
- ✓ while reporting that a correction WOULD be possible (migration 021 is applied)
- ✓ the captain channel's id is resolved
- ✓ the chat archive is present (2 messages) — FR10.6's evidence
- ✓ and carries what the captains actually said

**Block 4 · A ruling rates the match once, and only once**

- ✓ the challenger starts at 1200
- ✓ the opponent starts at 1200
- ✓ the ruling succeeds
- ✓ the stored ruling is 'challenger'
- ✓ and the rating was APPLIED (not corrected — nothing was rated before)
- ✓ the adopted scoreline is the challenger's own submission: 3
- ✓ to 1
- ✓ the winner is the challenger
- ✓ and the match it belongs to comes out completed
- ✓ a friendly reports no bracket to advance
- ✓ severity is stamped on the dispute (16)
- ✓ the match is completed
- ✓ elo_applied is latched TRUE — the double-apply guard
- ✓ verified_by names the ADMIN who ruled
- ✓ and verified_at is stamped
- ✓ the ruled scoreline is on the match: 3
- ✓ to 1
- ✓ the winner's rating rose (1200 → 1216)
- ✓ the loser's rating fell (1200 → 1184)
- ✓ ELO is zero-sum: the two deltas cancel exactly
- ✓ two equal teams exchange K/2 = 16 points at K=32
- ✓ elo_history has exactly two rows — one per team, the audit trail
- ✓ each row records the K it was rated at
- ✓ neither row is a freeze placeholder
- ✓ and before/after/delta agree inside the row
- ✓ disputes.status = resolved
- ✓ disputes.ruling records WHICH way it went
- ✓ resolved_by names the admin
- ✓ resolved_at is stamped
- ✓ the ruled score is stored on the dispute too
- ✓ and the note the admin typed is kept verbatim
- ✓ exactly one admin_audit row for the ruling
- ✓ it points at the dispute
- ✓ by id
- ✓ BEFORE holds both submissions verbatim
- ✓ AFTER records how the rating was reached
- ✓ and which way it went
- ✓ AFTER carries the actual rating deltas, so "who changed this" is answerable
- ✓ the ruling names everyone to notify (4 members across both teams)
- ✓ and produces at least one chat pill for after-commit emission
- ✓ both captains got a 'dispute_resolved' notification
- ✓ and a neutral system pill landed in the captain channel
- ✓ ruling the SAME dispute a second time is refused
- ✓ with 409 Conflict
- ✓ and says so plainly
- ✓ the challenger rating is UNCHANGED by the refusal
- ✓ the opponent rating is UNCHANGED by the refusal
- ✓ and elo_history still holds two rows — the exchange happened exactly once

**Block 5 · An already-rated match is CORRECTED, not double-applied**

- ✓ the first (owner) verification already moved the ratings
- ✓ leaving two elo_history rows
- ✓ the case file warns the admin this needs a CORRECTION
- ✓ and that the database supports one
- ✓ showing the two rows already written
- ✓ the overturn rules
- ✓ eloMode is 'corrected' — not 'applied', and not refused
- ✓ the winner is now the opponent
- ✓ elo_history holds SIX rows: the verification pair, its reversal, and the re-rating
- ✓ the original verification pair is still there — the trail is appended to, never edited
- ✓ a reversal row per team, labelled 'admin_reversal'
- ✓ and a ruling row per team, labelled 'admin_ruling'
- ✓ the challenger's three rows net to exactly one exchange, in the ruled direction
- ✓ and the opponent side its mirror image
- ✓ the challenger ends BELOW its starting rating, once
- ✓ and the opponent above it, once
- ✓ the ladder still sums to what it started with — nothing was double-applied

**Block 6 · A ruling on a tournament fixture advances the bracket**

- ✓ the queue flags the dispute as a tournament fixture
- ✓ and names the tournament
- ✓ the fixture dispute rules
- ✓ the ruling reports the bracket call as 'ok'
- ✓ and `advanced` says the fixture genuinely moved on
- ✓ and advanced === true
- ✓ the semi-final is marked played
- ✓ and carries the ruled scoreline mapped onto team_a: 3
- ✓ to 1
- ✓ with the ruled winner recorded
- ✓ the winner has been written into the FINAL's team_a slot (advanceSlot(1,1).side === 'a')
- ✓ the other semi has not been played, so team_b is still empty
- ✓ and the final is still upcoming
- ✓ the tournament is still ACTIVE — no prize was settled by a semi
- ✓ and it has no winner yet
- ✓ the losing team is eliminated
- ✓ in round 1
- ✓ the fixture was rated once
- ✓ and at the tournament's semi-final K (48), not the ladder's
- ✓ so the exchange is 24 points, not 16
- ✓ the winner's tournament record counts the win

**Block 7 · Suspending an account unwinds what it was holding**

- ✓ a suspension without a reason is refused (the user is told what it says)
- ✓ an admin cannot suspend themselves
- ✓ with 400
- ✓ and cannot suspend another admin from the app
- ✓ with 403
- ✓ the victim is holding a pending booking 21 days out
- ✓ and the slot is marked booked
- ✓ the suspension succeeds
- ✓ users.is_active is false — the same flag login already checks
- ✓ suspended_at is stamped
- ✓ the reason is stored verbatim
- ✓ and suspended_by names the admin
- ✓ the upcoming booking was cancelled
- ✓ that booking specifically
- ✓ and the player was refunded PKR 2000 — a suspension is not a confiscation
- ✓ the booking row reads cancelled
- ✓ and the slot is available for somebody else
- ✓ the refund reached the wallet (76000.00 → 78000.00)
- ✓ one booking was deliberately left alone — the disputed match sits on it
- ✓ and the admin is told why in words, on the same screen, not left to find out later
- ✓ what stays frozen is exactly the untouched booking's escrow — nothing more, nothing less
- ✓ and the escrow freed is exactly the cancelled booking, to the rupee
- ✓ the refund is in the ledger as a 'refund' row, not just a balance change
- ✓ the user is told their account was suspended
- ✓ exactly one admin_audit row
- ✓ BEFORE records the account was active
- ✓ AFTER records it is not
- ✓ and AFTER carries the whole cascade for review
- ✓ suspending twice is refused (409, no second cascade)
- ✓ with 409

**Block 9 · The financial export escapes a formula and reconciles with the ledger**

- ✓ csv.cell prefixes a leading = with an apostrophe
- ✓ and a leading +
- ✓ and a leading -
- ✓ and a leading @
- ✓ and a leading tab
- ✓ but leaves an ordinary name completely alone
- ✓ and a NUMBER we produced ourselves is never prefixed (it must stay summable)
- ✓ a field that is BOTH a formula and comma-bearing gets the apostrophe first, then the quotes
- ✓ an embedded quote is doubled and the field wrapped (RFC 4180)
- ✓ a newline is wrapped rather than becoming a new record
- ✓ null is an empty cell, not the text "null"
- ✓ money is a plain two-place decimal (a pg DECIMAL arrives as a string)
- ✓ and a missing amount is 0.00, never blank
- ✓ rows end CRLF as RFC 4180 requires
- ✓ and a filename cannot carry a quote or a semicolon into a header
- ✓ a venue is registered under the name `=1+1` (the database stores it verbatim)
- ✓ the file opens with a UTF-8 BOM (or Excel-on-Windows mojibakes every Urdu name)
- ✓ the header row is the column labels
- ✓ and the owner's own export has no Owner column — it is all theirs
- ✓ both bookings on that venue appear in the file
- ✓ the venue cell is EXPORTED as `'=1+1` — the formula is defused in the file itself
- ✓ and nowhere in the file does a bare `=1+1` survive as a live formula
- ✓ the settled booking carries its status
- ✓ the checked-in booking reports the gross the LEDGER received
- ✓ with the platform commission at the live 7.5%
- ✓ and net = gross − commission, to the paisa
- ✓ its deposit is no longer held (the booking reached a terminal state)
- ✓ the still-pending booking shows its agreed PRICE
- ✓ but a gross of ZERO — because no money has moved yet
- ✓ and no commission
- ✓ with the deposit sitting in the player's frozen balance, in its own column
- ✓ and that deposit is a real number, not zero
- ✓ the TOTAL counts both rows
- ✓ both of them bookings
- ✓ and no tournament payouts on this venue
- ✓ the agreed prices add up
- ✓ the gross is only what actually arrived
- ✓ the commission column totals the ledger
- ✓ and the TOTAL net reconciles too
- ✓ the JSON preview and the CSV file report byte-identical totals (one walk, two formats)
- ✓ and the preview is not truncated at this size
- ✓ the last row of the file is the TOTAL row
- ✓ carrying the summed gross
- ✓ and saying what it counted, in words
- ✓ the platform export adds an Owner column
- ✓ and a per-owner subtotal row
- ✓ naming the owner it bills
- ✓ whose commission equals the platform TOTAL (a single owner reconciles exactly)
- ✓ and the formula is defused in this export too
- ✓ a missing date range is refused by name
- ✓ a backwards range is refused
- ✓ and a range longer than a year is refused with the number, and told how to split it
- ✓ a malformed venueId is refused before it reaches SQL
- ✓ and PDF is honestly refused rather than silently served as CSV
- ✓ a sane range is accepted
- ✓ with the day count computed inclusively
- ✓ and CSV as the default format
- ✓ the download filename says what it is and is header-safe

**Block 10 · The wiring the sources have to state (read from disk, not from a request)**

- ✓ all six route sources are on disk and readable
- ✓ admin.js mounts ./adminUsers
- ✓ admin.js mounts ./adminDisputes
- ✓ admin.js mounts ./adminSettings
- ✓ and the platform report router
- ✓ owner.js mounts the owner report router
- ✓ the single admin auth gate sits ABOVE every sub-router mount
- ✓ and there is exactly ONE role check in the file — one rule, not four copies
- ✓ adminSettings: the settings cache drop happens AFTER COMMIT, in every handler
- ✓ adminSettings: the deposit-percent push happens AFTER COMMIT, in every handler
- ✓ adminUsers: the auth cache drop happens AFTER COMMIT, in every handler
- ✓ adminDisputes: the socket fan-out happens AFTER COMMIT, in every handler
- ✓ the owner export scopes to req.user.id — a literal, not a query param
- ✓ and only the admin router may pass a null owner
- ✓ no ownerId is ever read from the query string
- ✓ the dispute route delegates to disputeService (no parallel ruling logic)
- ✓ and the users route delegates to suspensionService
- ✓ the route never calls elo.applyResult itself — the rating exchange has exactly one caller

**The rollback**

- ✓ after ROLLBACK not one person this run created still exists
- ✓ nor one team
- ✓ nor the venue named `=1+1`
- ✓ nor the dispute that was ruled
- ✓ and not one admin_audit row — the database is exactly as it was
- ✓ the process-global deposit percent is back to 20% (a ROLLBACK cannot undo a module variable)

**Block 8 · A suspended account is rejected on its NEXT request (committed, then deleted)**

  > This block commits one throwaway user, because the middleware reads through the pool and cannot see an uncommitted one. It is hard-deleted afterwards.
- ✓ a valid token is issued for the live account
- ✓ the live account passes the middleware
- ✓ and arrives at the route as req.user
- ✓ with the role the ROW says, not only the claim
- ✓ within the 30s cache TTL an un-invalidated token still passes
- ✓ and that window is 30 seconds, not a minute and not a request
- ✓ after invalidate(), the SAME previously-valid token is rejected
- ✓ with 403 Forbidden — not 401, which the app would treat as an expired session
- ✓ and the same words as the login refusal
- ✓ in the {success:false, message} shape every error uses
- ✓ and the route never sees a req.user at all
- ✓ reinstating and invalidating lets the same token through again
- ✓ a token for a DELETED user is 401, not 403
- ✓ and says the account is gone
- ✓ the committed test account is deleted again (nothing is left behind)

<!-- admin-evidence:admin END -->
