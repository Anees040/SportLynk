# S1 Acceptance Checklist — audit + manual test scripts

**How to use this file.** You pasted the S1 milestone checklist; this file audits
every row against the actual code, tells you whether it is **done in code**
(DONE-BY-CODE), **done by your manual steps** (DONE-BY-HAND), **not done yet**, or
**stale wording** that no longer matches the project — then gives you the exact
test to run. You run the scripts; the code work is already done and verified on
disk.

The last page of this file is the checkbox list you hand to your supervisor.

---

## The checklist audit

Status legend:
- ✅ **DONE-IN-CODE** — implemented, on disk. Still needs a manual run to count as verified.
- 🟡 **VERIFY-BY-HAND** — code exists; the checklist row is only ticked after you run the script.
- ⛔ **STALE** — the wording refers to a world that no longer exists. Read the note; the row has a *different* meaning now.
- ❌ **NOT DONE** — genuinely outstanding. Fixing it is a step in [`DEPLOY_GUIDE.md`](DEPLOY_GUIDE.md).

| # | Checklist item (your wording) | Status | Where it lives | Done by | Verification |
|---|---|---|---|---|---|
| 1 | Book → approve → QR check-in moves **100%** of the slot price to the owner; both ledgers match Wave A's money table | ✅ DONE-IN-CODE | `backend/src/utils/escrow.js` (ledger table at top), booking routes call every helper inside one transaction with `FOR UPDATE` locks | Code: me. Manual: **you** | Script **A** below. The decisive row is the check-in: player's `frozen` drops to 0, owner's `balance` rises by the full price, one `escrow_received` transaction on the owner side. |
| 2 | Late cancel → owner keeps **20%**; early cancel → **100%** refund; no-show → penalised **30 min** after slot start | ✅ DONE-IN-CODE | `POLICY.CANCELLATION_WINDOW_HOURS=24` in `escrow.js`, `penaltySplit()` returns 80/20, `jobs/noShowJob.js` runs on `NO_SHOW_GRACE_MINUTES=30` | Code: me. Manual: **you** | Script **A** (cancels) + Script **C2** (no-show, with the 1-minute override). |
| 3 | Pending booking auto-approves at **2h** — test with a **1-min override constant** | ✅ DONE-IN-CODE | `POLICY.AUTO_DECIDE_AFTER_MINUTES = 2*60`; `SL_TEST_AUTO_DECIDE_MINUTES=1` override | Code: me. Manual: **you** | Script **C1** below. The override is an environment variable, not an edited constant — so you cannot forget it and commit it. |
| 4 | Slot locking between **two accounts**, locked slot shows **blue** | ✅ DONE-IN-CODE | Migrations 004 + 011 (partial unique index), `routes/slotLock.js` `POST /:id/lock` + `DELETE /:id/lock` | Code: me. Manual: **you** | Script **B** below (two accounts on two phones or one logged-out/in). Blue rendering is Flutter-side; check it visually in the booking screen. |
| 5 | "Migration 010 applied local + Supabase"; Render healthy; phone demo on mobile data | ⛔ **STALE** + ❌ demo not done | — | — | **Read this carefully.** There is **no local database** — Supabase has been the only database since Wave A. Migrations **001–014** are applied to it via runners; 013 and 014 were each verified idempotent (run twice, second run creates nothing). So the real wording is *"migrations 001–014 applied to Supabase"* and that half is ✅. The **Render + phone-on-mobile-data** half is ❌ — nothing is deployed yet. That is the whole point of [`DEPLOY_GUIDE.md`](DEPLOY_GUIDE.md). When step 9 of the guide is done, this row ticks. |
| 6 | Withdraw + itemised frozen breakdown + transaction detail sheet | ✅ DONE-IN-CODE | `routes/wallet.js`: `POST /withdraw`, `DELETE /withdraw/:id`, `GET /frozen`, `GET /withdrawals`; migration 014 (withdrawals table + partial unique index); Flutter: `withdraw_sheet.dart`, `frozen_balance_sheet.dart`, `transaction_detail_sheet.dart` | Code: me. Manual: **you** | Script **D** below (400 → 201 → 409 → DELETE refund → settle). |
| 7 | `flutter analyze` **0 issues** · rate limiting · `.env.example` committed · tag `s1-done` | 🟡 mixed | — | — | Split: <br>• **analyze** — ❌ not run yet. In `D:\sportlynk`, type `! flutter analyze` and it must end with `No issues found!`. <br>• **rate limiting** — ✅ in code (`middleware/rateLimit.js`, two tiers: 100/min per user, 20/min per IP) **and** fixed for Render: `server.js` now sets `trust proxy = 1` behind Render's proxy, so phone traffic is keyed per-user, not all squashed into one 20/min bucket. <br>• **`.env.example` committed** — ✅ `git ls-files backend/.env.example` returns it. <br>• **tag `s1-done`** — ❌ does not exist yet (tags are only `S1-Wave-2/3/4`). Create it **only after every row above is genuinely ticked** — command at the bottom of this file. |

---

## Script A — the escrow spine (book → approve → QR → ledgers)

**Setup:** a fresh player account, an owner account, one venue with a slot at a
future time (start it ≥ 3 h from now — inside 2 h the auto-decider interferes).

| Step | Action | Expect |
|---|---|---|
| A1 | Player books the slot | Player `balance` −price, player `frozen` +price. Booking `pending`. |
| A2 | Owner opens dashboard → approves | Status `confirmed`. Balances unchanged — approval moves no money (Wave A design: money moves at check-in). |
| A3 | Player shows QR at check-in (owner scans / player confirms) | Booking `checked_in`. Player `frozen` −price (→0). **Owner `balance` +100% of price.** |
| A4 | Check owner wallet history | One `escrow_received` row for the full amount. |
| A5 | Check player wallet history | One `escrow_release` row, same amount, both sides' `balanceAfter` consistent. |

Money table it must match (from `escrow.js`): check-in = player frozen −P, owner
balance +P, nothing else moves.

## Script A2 — the two cancels

| Step | Action | Expect |
|---|---|---|
| A2-1 | Book a slot ≥ 24 h out, cancel it | Player refunded **100%**. Owner untouched. Status `cancelled`. |
| A2-2 | Book a slot < 24 h out (e.g. tomorrow morning, now afternoon), cancel it | Player refunded **80%**, owner gets **20%** (one `late_cancel_penalty`-style row each side). |
| A2-3 | Cancel the same booking twice | Second cancel is a 400 — a cancelled booking cannot cancel again. |

## Script B — slot locking between two accounts

Two phones, or one phone logged out/in twice. Owner creates one venue with slot
`Thu 18:00–20:00`.

| Step | Action | Expect |
|---|---|---|
| B1 | Player 1 taps the slot → book screen | Slot available. |
| B2 | Player 2 opens the same venue, same slot, at the same time | **Slot appears locked** (blue) if Player 1's booking is pending; booking attempt returns 409 or the slot is disabled. |
| B3 | Owner rejects Player 1's request | Slot releases; Player 2 can now book it. |
| B4 | Player 1 locks again, then deletes/cancels | Lock gone, slot blue-state cleared. |

Note: if you are testing with one phone, use two browser sessions of the Flutter
app (or the mobile app for one role, a desktop build for the other). Player 2
must be a *different logged-in account*, not the same one on another device.

## Script C — timed rules with the 1-minute override

These are the only tests that need the backend **running locally** — on Render
the container sleeps and the sweeps only run when traffic wakes it, so a 1-minute
test against the cloud will look broken (see DEPLOY_GUIDE Step 10). Everything
about the overrides: set them in **one dedicated PowerShell**, watch the
**`⚠️ TEST TIMING OVERRIDES ACTIVE` banner** at boot, and **never** set them on
Render.

### C1 — auto-approve in 1 minute (the checklist's "1-min override")

```powershell
cd D:\sportlynk\backend
$env:SL_TEST_AUTO_DECIDE_MINUTES = '1'
$env:SL_TEST_SWEEP_SECONDS = '15'
node src/server.js
```

In the app: player books a slot > 2 h out → wait ~1 min + one 15 s sweep → the
booking is `confirmed` on its own, both parties get a notification saying the
owner "did not respond within 1 min". (The override also proves `describeDelay`
works — the notification says **1 min**, not `0.0167h`.)

### C2 — no-show in 1 minute

Same terminal window style, new env values:

```powershell
$env:SL_TEST_NO_SHOW_MINUTES = '1'
$env:SL_TEST_SWEEP_SECONDS = '15'
node src/server.js
```

Book + approve a slot starting 5 minutes from now, do not check in. Within ~1
min + one sweep: booking `no_show`, player −20% of the price, owner +20%, player
trust score −10, notifications on both sides.

### C3 — withdrawal settles in 1 minute

```powershell
$env:SL_TEST_SETTLE_MINUTES = '1'
$env:SL_TEST_SWEEP_SECONDS = '15'
node src/server.js
```

Request a withdrawal, wait ~1 min: the `pending` row becomes `completed`, money
stays out of `balance` the whole time (the debit happens at request time, the
settle is just bookkeeping).

**Reset after each test:** close the terminal and open a fresh one — otherwise
the next `node src/server.js` starts with the overrides still active and the
banner will tell you so.

## Script D — the withdrawal endpoint contract

Against any running backend (local is fine; against Render is also fine — this
is not time-dependent).

| Step | Call | Expect |
|---|---|---|
| D1 | `POST /api/wallet/withdraw` `{"amount": 50}` | **400**, message says minimum is PKR 200 |
| D2 | `POST /api/wallet/withdraw` `{"amount": 1000}` | **201**, row `pending`, balance debited 1000 immediately |
| D3 | Same call again before it settles | **409** — one pending at a time (the partial unique index in migration 014 is the enforcement, this is it firing) |
| D4 | `DELETE /api/wallet/withdraw/:id` | **200**, money refunded via a *new* ledger row — the audit trail keeps both halves |
| D5 | Repeat D2, then check `GET /api/wallet/withdrawals` | Exactly one `pending` row in the list, marked `PENDING` |
| D6 | `GET /api/wallet/frozen` with an active booking | Itemised rows sum to the wallet's `frozen_balance`; `delta = 0` (a non-zero delta means legacy rows under the pre-Wave-A 30% rule) |
| D7 | In the app: tap any transaction | `TransactionDetailSheet` opens: icon, label, exact amount, `balanceAfter`, timestamp in **PKT** (UTC+5 — a transaction at 8 PM local must read 8 PM, not 3 PM) |

---

## The stale-wordings register (read before your viva)

1. **"Migration 010 applied local + Supabase"** — there is no local database, and
   migration 010 was superseded by 011–014 anyway. The true state is *001–014
   applied to Supabase*. Say it that way.
2. **"1-min override constant"** — it is an *environment variable*
   (`SL_TEST_AUTO_DECIDE_MINUTES`), not an edited constant. Edited constants get
   committed by accident; env vars cannot. The checklist's intent (test the 2h
   rule at 1 min) is satisfied.
3. **"Tag `s1-done`"** — does not exist. Create it only when everything above is
   green, so a wrong tag never claims a false completion:

```powershell
cd D:\sportlynk
git tag -a s1-done -m "Sprint 1 complete: escrow, slot locking, withdrawals, cloud demo"
git push origin s1-done
```

4. **The one-deployment reality** — a local backend *and* the Render backend point
   at the **same Supabase database**. Any test against one is a test against the
   same data. That is by design: two separate databases would need two migrations
   applied twice, and the whole project's sync history is full of exactly that
   kind of drift.

---

## The one-page checklist (print this)

**SportLynk — Sprint 1 acceptance**

Code work (done by Claude, in the working tree — uncommitted until you commit):

- [ ] Wave A–D: escrow ledger, 80/20 cancels, no-show job, 2h auto-decide, slot
      locking (004/011), migrations 001–014
- [ ] Wave F: ApiClient (JWT + timeout + friendly errors), `num_util.asNum`,
      withdrawals endpoint + sheet, frozen-breakdown sheet, transaction detail
      sheet, rate limiter, `trust proxy` fix for Render
- [ ] `flutter analyze` → `No issues found!`

Manual verification (you, from this file):

- [ ] A: book → approve → QR check-in moves 100% to owner; ledgers match
- [ ] A2: early cancel 100%, late cancel 80/20
- [ ] C1: auto-approve in 1 min (override)
- [ ] C2: no-show in 1 min (override)
- [ ] C3: withdrawal settles in 1 min (override)
- [ ] B: two-account slot lock, blue state
- [ ] D: withdraw 400/201/409/refund/settle; frozen breakdown `delta=0`;
      transaction detail in PKT

Deployment (from [`DEPLOY_GUIDE.md`](DEPLOY_GUIDE.md)):

- [ ] Render service green; `/api/health` + `/api/venues` + login verified
- [ ] Release APK built with `--dart-define=API_BASE_URL=https://….onrender.com/api`
- [ ] Cable unplugged, Wi-Fi off, **mobile data on**, laptop closed → booking works
- [ ] `.env.example` committed, real secrets only in Render dashboard + local `.env`
- [ ] `git tag -a s1-done` pushed
