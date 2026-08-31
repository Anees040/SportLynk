# Tournaments — the evidence pack

**This file is generated. Do not edit it by hand.** Every line below was written by a
verification script that had just asserted it against the live database, inside one
transaction that was then rolled back — so the run leaves no rows behind and the
document is reproducible rather than a description of a state somebody once had. To
regenerate:

```
cd backend && node src/scripts/check_tournaments.js --evidence
```

A block absent from this file was not run — it is not a pass.

<!-- tournament-evidence:tournaments BEGIN -->

## S.7 Wave A -- the tournament module, driven through `tournamentService`

Five tournaments -- one cancelled under its minimum, an 8-team knockout played to a champion, a 5-team knockout with byes, a 4-team round-robin decided on goal difference, and one driven through the S.2 captain-submit door -- created, paid into, drawn onto real venue hours, played out and audited, all inside ONE transaction that is rolled back at the end. Every money assertion reads the WALLET and the LEDGER rather than the return value: the return value is the thing under test, not the evidence.

**PASS 441/441** · 1 skipped · produced Aug 30, 2026, 01:26:10 PKT (2026-08-29T20:26:10.354Z)

| provenance | value |
|---|---|
| command | `cd backend && node src/scripts/check_tournaments.js --evidence` |
| commit | `352a587` — feat: implement Tournaments feature · **5 uncommitted path(s) in the tree** |
| node | v22.19.0 on win32 |
| venue | Shalimar Cricket Academy — Islamabad, cricket |
| free hours scanned | 75 over 5 days, PKR 2800.00–2800.00 an hour |
| scheduler | model · pricing-v1-20260825-0041 · scored 75/75 candidate hours |
| K factors | friendly 32 · early 40 · semi 48 · final 56 |
| transaction | one BEGIN, one ROLLBACK — no row below outlived the run |

### What this run establishes

- **The waterfall on a real venue** — PKR 3200 × 8 teams = **25600** pool · venue cost **19600** (seven real slot prices) · prize **3600** (winner 2520, runner-up 1080) · owner **22000**.
- **The owner is never worse off than selling the hours** — owner earning 22000 against a retail value of 19600 for the same seven hours — the venue cost is recovered before any prize is set aside.
- **The fee is quoted, not guessed** — `POST /api/tournaments/preview` recommended PKR 3500 a team before the tournament existed, from this venue's own slot prices.
- **One ELO ladder, weighted by stake** — read back out of `elo_history.k_factor`: round 1 at K=40, the semi-finals at 48, the final at 56 against 32 for a friendly — and K=0 for a bye, which writes no rating row at all.
- **Reservation, not booking** — every fixture holds a real slot at `status = blocked` and NOT ONE `bookings` row was written, so no captain is charged twice and `noShowJob` has nothing to sweep.

### Every assertion, in the order it was made

**Block 1 — configuration refusals (FE-1)**

- ✓ a knockout field of 6 is refused, and the message says "power of two"
- ✓ 8, 16 and 32 are accepted knockout fields
- ✓ a knockout field above the 32 cap is refused
- ✓ round-robin above 6 teams is refused, and the message says why
- ✓ round-robin at the cap is accepted
- ✓ a minimum field larger than the maximum is refused
- ✓ a two-character name is refused
- ✓ a 5-minute fixture is refused
- ✓ a prize share above 100% is refused
- ✓ winner 80 / runner-up 30 is refused — the shares must total exactly 100
- ✓ a 0% prize share is ACCEPTED — "the venue keeps the surplus" is a real cup, not a typo
- ✓ a deadline in the past is refused
- ✓ a start date before the deadline is refused — the scheduler could not keep that promise
- ✓ a future deadline with no start date is accepted
- ~ an owner cannot post a tournament at somebody else's venue — *skipped: only one venue owner in the data*
- ✓ a tournament at a venue that does not exist is refused

**Block 2 — the economics quote (FE-1), from real slot prices**

- ✓ the full 8-team bracket can be placed on this venue's free hours
- ✓ an 8-team knockout is quoted as 7 fixtures
- ✓ a 4-team minimum turnout is quoted as 3 fixtures
- ✓ the quote is denominated in real slot prices, not an estimate
- ✓ seven hours cost more than three — the quote scales with the field, not the fee
- ✓ a recommended entry fee is quoted
- ✓ the recommendation is achievable at the configured prize share
- ✓ at the recommended fee the MINIMUM legal turnout still clears the venue cost
- ✓ the recommended fee is never underwater at the worst legal turnout
- ✓ and the owner still earns at least what selling those same hours would have paid
- ✓ at capacity: pool = venue cost + prize + margin, to the paisa
- ✓ at capacity: the owner takes everything that is not prize money
- ✓ at capacity: the winner and runner-up shares total the prize exactly
- ✓ at capacity: the split reports its own identity as exact
- ✓ at the minimum: pool = venue cost + prize + margin, to the paisa
- ✓ at the minimum: the owner takes everything that is not prize money
- ✓ at the minimum: the winner and runner-up shares total the prize exactly
- ✓ at the minimum: the split reports its own identity as exact
- ✓ at the recommended fee: pool = venue cost + prize + margin, to the paisa
- ✓ at the recommended fee: the owner takes everything that is not prize money
- ✓ at the recommended fee: the winner and runner-up shares total the prize exactly
- ✓ at the recommended fee: the split reports its own identity as exact
- ✓ a 6-team round-robin is quoted as 15 fixtures — n(n-1)/2
- ✓ and its recommended fee is HIGHER than the knockout's, because it eats more inventory

**The cup itself — posted by the venue owner (FE-1)**

- ✓ an 8-team knockout is posted at PKR 3200 a team

**Block 3 — entry fees, refusals and refunds (FE-3, FE-4, FE-5)**

- ✓ a captain enters their team
- ✓ registration answers 201 Created
- ✓ the entry fee leaves the spendable balance
- ✓ and appears in the frozen balance
- ✓ the wallet TOTAL is unchanged — the fee is held, not spent
- ✓ a tournament_entry ledger row is written
- ✓ the ledger row carries the negative fee
- ✓ and the balance it recorded matches the wallet
- ✓ the same team cannot enter twice
- ✓ only the captain may enter a team
- ✓ a team from another sport cannot enter
- ✓ a captain who cannot cover the fee is refused, and pays nothing
- ✓ the refused captain has nothing frozen
- ✓ a captain may withdraw while registration is open
- ✓ the whole fee is back in the spendable balance
- ✓ and nothing is left frozen
- ✓ a refund ledger row is written
- ✓ the refund row carries the positive fee
- ✓ and the team may enter again after withdrawing
- ✓ the field fills to 8 teams
- ✓ a ninth team is refused — the participant cap is enforced (FE-4)
- ✓ the organiser may remove a team (FE-5)
- ✓ a removed team is refunded in full
- ✓ and nothing of theirs stays frozen
- ✓ a captain cannot remove somebody else's team
- ✓ and the freed spot can be taken by the team that was refused a moment ago

**Block 5 — the draw, the reservation and the waterfall (FE-6)**

- ✓ a captain cannot draw the bracket
- ✓ once the deadline passes, registration is closed (FE-4)
- ✓ the organiser draws the bracket
- ✓ eight teams are in the field
- ✓ an 8-team knockout is 3 rounds
- ✓ the bracket size is 8 — no padding was needed
- ✓ and nobody gets a bye
- ✓ seven fixtures, which is n-1
- ✓ seeding is strictly by ELO, highest first
- ✓ round 1 has four ties
- ✓ and the pairings are 1v8, 2v7, 3v6, 4v5 — the top seed meets the bottom one
- ✓ the last round is labelled Final
- ✓ and the round before it is labelled Semi-final
- ✓ seven fixture rows exist
- ✓ every fixture reserved a real slot
- ✓ and every reserved slot is now blocked, so nobody can book it
- ✓ no slot is used twice
- ✓ every fixture has a scheduled_at stamp
- ✓ NOT ONE booking row was written — a fixture reserves, it does not book (no double charge, no no-show sweep)
- ✓ the pool is eight entry fees
- ✓ the venue cost is the sum of the SEVEN CHOSEN SLOTS' real prices — not an estimate
- ✓ pool = venue cost + prize + margin, to the paisa
- ✓ the owner earning is the venue cost plus the margin
- ✓ THE CENTRAL CLAIM: the owner earns at least the value of the hours consumed — never underwater
- ✓ and at least what those same hours would have fetched sold at the counter
- ✓ the two podium shares total the prize exactly
- ✓ the split reports its own identity as exact
- ✓ zzcheck-Team A: the held fee is released out of frozen
- ✓ zzcheck-Team A: and none of it came back — it was spent on the entry
- ✓ zzcheck-Team A: an escrow_release row records the release
- ✓ zzcheck-Team B: the held fee is released out of frozen
- ✓ zzcheck-Team B: and none of it came back — it was spent on the entry
- ✓ zzcheck-Team B: an escrow_release row records the release
- ✓ zzcheck-Team C: the held fee is released out of frozen
- ✓ zzcheck-Team C: and none of it came back — it was spent on the entry
- ✓ zzcheck-Team C: an escrow_release row records the release
- ✓ zzcheck-Team D: the held fee is released out of frozen
- ✓ zzcheck-Team D: and none of it came back — it was spent on the entry
- ✓ zzcheck-Team D: an escrow_release row records the release
- ✓ zzcheck-Team E: the held fee is released out of frozen
- ✓ zzcheck-Team E: and none of it came back — it was spent on the entry
- ✓ zzcheck-Team E: an escrow_release row records the release
- ✓ zzcheck-Team F: the held fee is released out of frozen
- ✓ zzcheck-Team F: and none of it came back — it was spent on the entry
- ✓ zzcheck-Team F: an escrow_release row records the release
- ✓ zzcheck-Team G: the held fee is released out of frozen
- ✓ zzcheck-Team G: and none of it came back — it was spent on the entry
- ✓ zzcheck-Team G: an escrow_release row records the release
- ✓ zzcheck-Team I: the held fee is released out of frozen
- ✓ zzcheck-Team I: and none of it came back — it was spent on the entry
- ✓ zzcheck-Team I: an escrow_release row records the release
- ✓ the owner is paid the venue cost plus the margin, in SPENDABLE balance
- ✓ and the prize sits in FROZEN, where a withdrawal cannot reach it
- ✓ a tournament_commission row records the owner's earning
- ✓ and carries the right amount
- ✓ a tournament_prize row records the prize being held
- ✓ THE WHOLE POOL is now with the owner — nothing has evaporated
- ✓ the tournament is now active
- ✓ and stamped with when the bracket was drawn
- ✓ the round count is stored on the row
- ✓ pool_amount is stored
- ✓ venue_cost_amount is stored
- ✓ prize_amount is stored
- ✓ owner_earning_amount is stored
- ✓ the schedule is stamped with its provenance
- ✓ model path: the demand model version is recorded
- ✓ model path: it names how many candidate hours it actually scored
- ✓ and it records the window each round was placed in
- ✓ the final takes a busier hour than round 1 — peak crowd for the showpiece, dead hours for the rest
- ✓ the owner-unblock guard finds the fixture standing on a reserved hour (so PATCH /owner/slots/:id/unblock refuses)

**6 · RESULTS, K BY STAKE, ADVANCEMENT AND THE PODIUM (FE-7)**

- ✓ a captain cannot enter their own result
- ✓ a semi-final cannot be settled before round 1
- ✓ a half-entered scoreline is refused
- ✓ R1 · a 2-1: the organiser enters 2-1
- ✓ R1 · a 2-1: the fixture is played
- ✓ R1 · a 2-1: the right team won
- ✓ R1 · a 2-1: the draw flag matches the scoreline
- ✓ R1 · a 2-1: two rating rows, one per team
- ✓ R1 · a 2-1: elo_history.k_factor = 40
- ✓ R1 · a 2-1: the response reports K=40
- ✓ R1 · a 2-1: the exchange is zero-sum (0.00)
- ✓ R1 · a 2-1: team A's played count moved
- ✓ R1 · a 2-1: team B's played count moved
- ✓ R1 · a 2-1: team A's win count is right
- ✓ R1 · a 2-1: team B's win count is right
- ✓ R1 · a 2-1: the beaten team is eliminated
- ✓ R1 · the winner advances into round 2
- ✓ R1 · a 1-1 draw: the organiser enters 1-1
- ✓ R1 · a 1-1 draw: the fixture is played
- ✓ R1 · a 1-1 draw: the right team won
- ✓ R1 · a 1-1 draw: the draw flag matches the scoreline
- ✓ R1 · a 1-1 draw: two rating rows, one per team
- ✓ R1 · a 1-1 draw: elo_history.k_factor = 40
- ✓ R1 · a 1-1 draw: the response reports K=40
- ✓ R1 · a 1-1 draw: the exchange is zero-sum (0.00)
- ✓ R1 · a 1-1 draw: team A's played count moved
- ✓ R1 · a 1-1 draw: team B's played count moved
- ✓ R1 · a 1-1 draw: team A's win count is right
- ✓ R1 · a 1-1 draw: team B's win count is right
- ✓ R1 · a 1-1 draw: the beaten team is eliminated
- ✓ R1 · the drawn tie goes to the higher seed (team A)
- ✓ R1 · the response says it was a draw
- ✓ R1 · and team A really is the higher seed (1450 vs 1400)
- ✓ R1 · a 3-0: the organiser enters 3-0
- ✓ R1 · a 3-0: the fixture is played
- ✓ R1 · a 3-0: the right team won
- ✓ R1 · a 3-0: the draw flag matches the scoreline
- ✓ R1 · a 3-0: two rating rows, one per team
- ✓ R1 · a 3-0: elo_history.k_factor = 40
- ✓ R1 · a 3-0: the response reports K=40
- ✓ R1 · a 3-0: the exchange is zero-sum (0.00)
- ✓ R1 · a 3-0: team A's played count moved
- ✓ R1 · a 3-0: team B's played count moved
- ✓ R1 · a 3-0: team A's win count is right
- ✓ R1 · a 3-0: team B's win count is right
- ✓ R1 · a 3-0: the beaten team is eliminated
- ✓ R1 · the organiser awards a walkover
- ✓ R1 · the fixture is marked walkover
- ✓ R1 · the walkover winner advances
- ✓ R1 · a walkover has no scoreline
- ✓ R1 · a walkover writes no match row
- ✓ R1 · K is 0 for a walkover
- ✓ R1 · and no exchange was applied
- ✓ R1 · the walkover winner's rating did not move
- ✓ R1 · the absent team's rating did not move
- ✓ R1 · a walkover is not a game played
- ✓ R1 · and not a tournament win either
- ✓ R1 · NO elo_history row exists for a walkover
- ✓ R2 · both semi-finals exist
- ✓ R2 · both semi-finals have two named teams now that round 1 is done
- ✓ R2 · they are labelled as semi-finals
- ✓ SF1: the organiser enters 2-0
- ✓ SF1: the fixture is played
- ✓ SF1: the right team won
- ✓ SF1: the draw flag matches the scoreline
- ✓ SF1: two rating rows, one per team
- ✓ SF1: elo_history.k_factor = 48
- ✓ SF1: the response reports K=48
- ✓ SF1: the exchange is zero-sum (0.00)
- ✓ SF1: team A's played count moved
- ✓ SF1: team B's played count moved
- ✓ SF1: team A's win count is right
- ✓ SF1: team B's win count is right
- ✓ SF1: the beaten team is eliminated
- ✓ SF2: the organiser enters 0-1
- ✓ SF2: the fixture is played
- ✓ SF2: the right team won
- ✓ SF2: the draw flag matches the scoreline
- ✓ SF2: two rating rows, one per team
- ✓ SF2: elo_history.k_factor = 48
- ✓ SF2: the response reports K=48
- ✓ SF2: the exchange is zero-sum (0.00)
- ✓ SF2: team A's played count moved
- ✓ SF2: team B's played count moved
- ✓ SF2: team A's win count is right
- ✓ SF2: team B's win count is right
- ✓ SF2: the beaten team is eliminated
- ✓ F · one final
- ✓ F · it is labelled the Final
- ✓ F · both finalists are known
- ✓ F · a 3-2: the organiser enters 3-2
- ✓ F · a 3-2: the fixture is played
- ✓ F · a 3-2: the right team won
- ✓ F · a 3-2: the draw flag matches the scoreline
- ✓ F · a 3-2: two rating rows, one per team
- ✓ F · a 3-2: elo_history.k_factor = 56
- ✓ F · a 3-2: the response reports K=56
- ✓ F · a 3-2: the exchange is zero-sum (0.00)
- ✓ F · a 3-2: team A's played count moved
- ✓ F · a 3-2: team B's played count moved
- ✓ F · a 3-2: team A's win count is right
- ✓ F · a 3-2: team B's win count is right
- ✓ F · a 3-2: the beaten team is eliminated
- ✓ F · no fixture is left upcoming
- ✓ F · settling the final completed the tournament
- ✓ F · the champion is the team that won it
- ✓ F · and the beaten finalist is runner-up
- ✓ F · the two shares total the prize
- ✓ F · the champion's share is 70% of the prize
- ✓ F · the owner's FROZEN balance falls by the whole prize
- ✓ F · and the owner's spendable balance is untouched by the payout
- ✓ F · the owner's frozen is back to what it was before the prize was set aside
- ✓ F · the champion's captain is paid PKR 2520, spendable
- ✓ F · the runner-up's captain is paid PKR 1080
- ✓ F · and nothing of the champion's is frozen — a prize is theirs to spend
- ✓ F · a tournament_prize row records the champion's payment
- ✓ F · with the right amount on it
- ✓ F · and a description that says what it was for
- ✓ F · and one for the runner-up too
- ✓ F · the champion gains a title
- ✓ F · and a final reached
- ✓ F · the runner-up gains no title
- ✓ F · but does reach the final
- ✓ F · the champion is recorded as having played all three rounds
- ✓ F · every tournament record matches the played fixtures exactly — the walkover counts for nobody
- ✓ K · round 1 was rated at 40
- ✓ K · the semi-finals at 48
- ✓ K · and the final at 56
- ✓ K · a final outweighs a friendly (56 vs 32) — ONE ladder, stake-weighted
- ✓ F · the tournament row is completed
- ✓ F · and stamped with when
- ✓ F · winner_team is stored on the row
- ✓ F · runner_up_team too
- ✓ F · exactly one team is left standing
- ✓ F · and the other seven are eliminated
- ✓ a completed tournament takes no further results
- ✓ re-advancing a settled fixture is a no-op, not a second payout
- ✓ and it reports that it advanced nothing

**Block 4 — under the minimum field, everyone is refunded (FE-4)**

- ✓ a second tournament is posted
- ✓ zzcheck-Team J enters the tournament that will not fill
- ✓ zzcheck-Team K enters the tournament that will not fill
- ✓ the deadline sweep answers rather than throwing
- ✓ two teams against a minimum of four is cancelled, not drawn
- ✓ and no bracket is reported
- ✓ both entries are refunded
- ✓ the refund total is the two PKR 500 fees
- ✓ the tournament row is marked cancelled
- ✓ and the reason says the field was too small
- ✓ zzcheck-Team J's captain is back to their opening balance
- ✓ zzcheck-Team J's captain has nothing left frozen
- ✓ zzcheck-Team K's captain is back to their opening balance
- ✓ zzcheck-Team K's captain has nothing left frozen
- ✓ no fixture was written for the cancelled tournament

**7 · A FIVE-TEAM FIELD: PADDING, BYES AND WHO GETS THEM**

- ✓ a third tournament is posted for a five-team field
- ✓ zzcheck-Team A enters the five-team cup
- ✓ zzcheck-Team B enters the five-team cup
- ✓ zzcheck-Team C enters the five-team cup
- ✓ zzcheck-Team D enters the five-team cup
- ✓ zzcheck-Team E enters the five-team cup
- ✓ five teams are drawn without a complaint
- ✓ five teams are in the field
- ✓ the bracket is padded to the next power of two
- ✓ which is still three rounds
- ✓ and the three spare places become byes
- ✓ seven fixture rows, of which three are byes
- ✓ three bye rows exist in the bracket
- ✓ a bye has no opponent — team B is NULL
- ✓ a bye is recorded as a walkover, not as an upcoming fixture
- ✓ and is resolved immediately in favour of the team that got it
- ✓ A BYE CONSUMES NO VENUE HOUR — nobody turns up, so nothing is reserved
- ✓ the byes go to the TOP THREE SEEDS, not to whoever entered first
- ✓ exactly one round-one tie is actually played
- ✓ and it is seeds 4 and 5 — the two teams that missed out
- ✓ every bye team is pre-advanced into its round-two node
- ✓ round two holds the three bye teams and one empty slot
- ✓ no rating moved: three byes wrote no elo_history at all
- ✓ zzcheck-Team A: a bye is not a game played
- ✓ zzcheck-Team A: and not a tournament win either
- ✓ zzcheck-Team B: a bye is not a game played
- ✓ zzcheck-Team B: and not a tournament win either
- ✓ zzcheck-Team C: a bye is not a game played
- ✓ zzcheck-Team C: and not a tournament win either
- ✓ four real hours are reserved: seven rows minus three byes
- ✓ the pool is five entry fees, not eight
- ✓ the venue cost counts only the hours the bracket will actually consume
- ✓ and the waterfall still closes to the paisa on an odd field
- ✓ the owner is still never underwater on a five-team cup
- ✓ the five-team cup completes
- ✓ with both a champion and a runner-up
- ✓ exactly four fixtures were played — n-1 for five teams
- ✓ the five-team champion is paid from the prize pool
- ✓ and paid exactly the winner share of it

**8 · ROUND ROBIN — POINTS, GOAL DIFFERENCE AND A CHAMPION FROM THE TABLE**

- ✓ a four-team league is posted
- ✓ zzcheck-Team A joins the league
- ✓ zzcheck-Team B joins the league
- ✓ zzcheck-Team C joins the league
- ✓ zzcheck-Team D joins the league
- ✓ the league fixture list is generated
- ✓ four teams play six fixtures — n(n-1)/2, not n-1
- ✓ a league has no byes
- ✓ six fixture rows exist
- ✓ each one reserved its own distinct hour
- ✓ every pairing occurs exactly once
- ✓ and no team is asked to play twice on the same day
- ✓ no fixture points at a next round — a league does not advance, it accumulates
- ✓ league · seed 1 2-0 seed 4
- ✓ league · nobody is eliminated while 5 fixtures remain
- ✓ league · seed 2 2-1 seed 3
- ✓ league · nobody is eliminated while 4 fixtures remain
- ✓ league · seed 3 0-3 seed 1
- ✓ league · nobody is eliminated while 3 fixtures remain
- ✓ league · seed 2 3-0 seed 4
- ✓ league · nobody is eliminated while 2 fixtures remain
- ✓ league · seed 1 1-1 seed 2
- ✓ league · a drawn league fixture has NO winner
- ✓ league · and the row stores no winner either
- ✓ league · nobody is eliminated while 1 fixtures remain
- ✓ league · seed 3 1-0 seed 4
- ✓ league · exactly one fixture was drawn
- ✓ league · one K value across the whole league
- ✓ league · and it is the early-round K (40) — a league has no final to weight
- ✓ league · the detail read returns a table
- ✓ league · four rows in the table
- ✓ league · every row of the table is exact — 3 for a win, 1 for a draw, 0 for a loss
- ✓ league · the table is sorted correctly
- ✓ league · and carries a position on each row
- ✓ league · THE TIE-BREAK: the top two are level on points and separated by goal difference
- ✓ league · playing the last fixture completes the league
- ✓ league · the champion is the team at the top of the table, not the winner of a final
- ✓ league · and second place is the runner-up
- ✓ league · the table-topper is paid the winner share
- ✓ league · and paid exactly the winner share of the league prize
- ✓ league · the pool is four entry fees
- ✓ league · and the waterfall closes on a league exactly as it does on a knockout
- ✓ league · six hours of inventory are recovered before anyone is paid a prize

**9 · THE MATCH-FLOW DOOR (S.2 verify → advanceAfterMatch)**

- ✓ a four-team knockout is posted for the match-flow door
- ✓ zzcheck-Team A enters
- ✓ zzcheck-Team B enters
- ✓ zzcheck-Team C enters
- ✓ zzcheck-Team D enters
- ✓ the semi-finals are drawn
- ✓ a four-team knockout is two semi-finals and a final
- ✓ matchContext recognises a tournament match
- ✓ AUTHORITY: the person entitled to verify is the ORGANISER, reached through tournaments.owner_id
- ✓ K: round 1 of a four-team cup is the semi-final, so the stake is 48
- ✓ and it resolves back to the right fixture
- ✓ with the round it belongs to
- ✓ and the fixture is still open
- ✓ the exchange was rated at the tournament K
- ✓ advanceAfterMatch answers on a tournament match
- ✓ it reports that it advanced the bracket
- ✓ the fixture is now played
- ✓ the scoreline landed on the right side of the bracket
- ✓ and the other score on the other side
- ✓ with the agreed winner
- ✓ and the winner is standing in the final
- ✓ EXACTLY TWO rating rows for one match — the exchange was NOT applied twice
- ✓ and it is still zero-sum
- ✓ the match row keeps its elo_applied latch
- ✓ and records the organiser as the verifier
- ✓ a repeat advance is a no-op
- ✓ and writes no further rating rows
- ✓ the match view returns the tournament match
- ✓ it genuinely has no booking
- ✓ and yet it resolves a VENUE, through the fixture's slot
- ✓ and a date and a kick-off time
- ✓ venue_owner resolves to the ORGANISER, which is what the verify screen filters on
- ✓ the tournament name is on the row
- ✓ so is the round
- ✓ and the fixture label
- ✓ slot_started is a real boolean, not NULL — without it the phone hides Submit result
- ✓ and both rating deltas are visible on the row
- ✓ matchContext returns NULL for a match with no tournament — the S.2 path is unchanged
- ✓ advanceAfterMatch declines a friendly, so matches.js can call it unconditionally
- ✓ and declines it as a success, not as an error
- ✓ having advanced nothing
- ✓ and a malformed id is null, not a throw
- ✓ the friendly was not rated by any of this

**10 · THE CLOSING LEDGER AUDIT**

- ✓ TOTAL MONEY IS CONSERVED across 15 wallets and four tournaments
- ✓ OUTSTANDING HOLDS are exactly the prize of the one tournament still in flight
- ✓ five tournaments were run by this script
- ✓ Champions Cup: every rupee paid in either became the pool or went back — 32000 = 25600 + 6400
- ✓ Champions Cup: the owner's commission row equals owner_earning_amount
- ✓ Champions Cup: owner earning + prize = pool, to the paisa
- ✓ Champions Cup: the podium was paid EXACTLY the prize — no more, no less
- ✓ Champions Cup: and the owner's frozen prize was released to pay it
- ✓ Abandoned Cup: every rupee paid in either became the pool or went back — 1000 = 0 + 1000
- ✓ Bye Cup: every rupee paid in either became the pool or went back — 15000 = 15000 + 0
- ✓ Bye Cup: the owner's commission row equals owner_earning_amount
- ✓ Bye Cup: owner earning + prize = pool, to the paisa
- ✓ Bye Cup: the podium was paid EXACTLY the prize — no more, no less
- ✓ Bye Cup: and the owner's frozen prize was released to pay it
- ✓ Round Robin League: every rupee paid in either became the pool or went back — 22000 = 22000 + 0
- ✓ Round Robin League: the owner's commission row equals owner_earning_amount
- ✓ Round Robin League: owner earning + prize = pool, to the paisa
- ✓ Round Robin League: the podium was paid EXACTLY the prize — no more, no less
- ✓ Round Robin League: and the owner's frozen prize was released to pay it
- ✓ Two Door Cup: every rupee paid in either became the pool or went back — 11200 = 11200 + 0
- ✓ Two Door Cup: the owner's commission row equals owner_earning_amount
- ✓ Two Door Cup: owner earning + prize = pool, to the paisa
- ✓ THE WHOLE RUN: PKR 81200 entered the tournaments and PKR 81200 is accounted for
- ✓ no wallet is negative in either column
- ✓ every tournament ledger row names the tournament it belongs to

**The rollback**

- ✓ after ROLLBACK not one captain this run created still exists
- ✓ and not one tournament — the database is exactly as it was

<!-- tournament-evidence:tournaments END -->
