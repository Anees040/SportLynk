# S1 Acceptance Checklist — audit + manual test scripts

**How to use this file.** You pasted the S1 milestone checklist; this file audits
every row against the actual code, tells you whether it is **done in code**
(DONE-BY-CODE), **done by your manual steps** (DONE-BY-HAND), **not done yet**, or
**stale wording** that no longer matches the project — then gives you the exact
test to run. You run the scripts; the code work is already done and verified on
disk.

The last page of this file is the checkbox list you hand to your supervisor.

---

## Finish line — everything left, in the order to do it

All the code for S1 is written, and as of 2026-08-21 the database is verified,
the wallets reconciled, 1,990 slots bookable and `flutter analyze` clean. What
remains is **your runs and your clicks** — nine steps, roughly two focused hours,
and S1 is done. Do them in this order: steps 1–4 need nothing but your laptop and
your phone, step 5 needs a second account, and only 6–7 depend on Render and the
internet — so the things that can be blocked by someone else are last.

| # | Do this | Where | Time | Why in this position |
|---|---|---|---|---|
| 1 | Start the backend locally and leave it running: `cd backend` → `node src/server.js`. Confirm `✅ Database connected (TLS on)` and **three** jobs. | terminal | 1 min | Everything below needs it. If this fails, nothing else matters. |
| 2 | **Script A** (book → approve → QR check-in) and **Script A2** (both cancels + double-cancel 400) | app + this file | 25 min | This is the *money* spine — SRS FR/ER core and the one thing a supervisor will actually re-test. Do it while the DB is freshly reconciled so any drift you see is real. |
| 3 | **Scripts C1, C2, C3** — the three `SL_TEST_*` one-minute tests (auto-approve, no-show, withdrawal settle) | terminal + app | 20 min | Needs the same local backend and a restart per test. Grouped here so you restart once per test instead of interleaving. |
| 4 | **Script D** — the withdrawal contract: 400 → 201 → 409 → DELETE refund → settle, and `delta = 0` | PowerShell (+ app for D7) | 15 min | Not time-dependent, so it survives being interrupted. **Mostly not doable from the app** — the withdraw sheet blocks the under-minimum amount client-side and hides the form once a request is pending, so D1 and D3 need the API directly. Script D carries a paste-once PowerShell harness for that. |
| 5 | **Script B** — two-account slot lock, blue state on both sides | two logins | 15 min | Needs a second account, which is the only step with an external dependency (a friend's phone, or a second login on a desktop build). Left late so it doesn't block the rest. |
| 6 | **Deploy: `DEPLOY_GUIDE.md` steps 2 → 7** — push, create the Render service, env vars, verify Supabase, `/api/health` green | browser | 30 min | Do this *after* the local tests pass. Debugging escrow and debugging a cold-starting free-tier container at the same time is how a whole evening disappears. |
| 7 | **Guide step 9** — release APK with `--dart-define=API_BASE_URL=https://….onrender.com/api`, install over USB, **unplug, switch to mobile data, close the laptop**, complete one booking | phone | 20 min | This is checklist row 5's real acceptance criterion. Nothing else proves it. |
| 8 | Re-run `flutter analyze` (must end `No issues found!`) and re-read the checkbox page at the end of this file, ticking only what you actually ran | terminal | 5 min | Tick after the evidence exists, not before. |
| 9 | Commit everything and tag `s1-done` (command at the bottom of this file) | git — yours | 5 min | The tag is a claim of completion. Create it last, once every row above is genuinely green. |

**Two things you can skip.** Migration 008's `venues.is_verified` /
`verification_status` are missing from Supabase and that is harmless — every
consumer reads `owner_profiles.verification_status` instead, so leave them alone.
And you do **not** need to re-run `seed_venues.js`; your 10 hand-built venues
already have 14 days of slots (step 8a of the deploy guide tops them up
non-destructively if the window ever runs short).

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
| 5 | "Migration 010 applied local + Supabase"; Render healthy; phone demo on mobile data | ⛔ **STALE** + ❌ demo not done | — | — | **Read this carefully.** There is only **one live database** — Supabase, since Wave A. (A `localhost:5432/sportlynk` line is still commented out in `backend/.env`, but that copy is stale, pre-Wave-A, and is not a backup.) Migrations **001–014** are applied to Supabase and were verified **directly against it** on 2026-08-21: 28 tables in `public`, all of 013's 12 tables, 010's 5 escrow columns, `withdrawals` + `uq_withdrawals_one_pending` as a partial unique index, all 31 key columns `uuid`. So the real wording is *"migrations 001–014 applied to Supabase"* and that half is ✅ **verified**. The **Render + phone-on-mobile-data** half is ❌ — nothing is deployed yet. That is the whole point of [`DEPLOY_GUIDE.md`](DEPLOY_GUIDE.md). When step 9 of the guide is done, this row ticks. |
| 6 | Withdraw + itemised frozen breakdown + transaction detail sheet | ✅ DONE-IN-CODE | `routes/wallet.js`: `POST /withdraw`, `DELETE /withdraw/:id`, `GET /frozen`, `GET /withdrawals`; migration 014 (withdrawals table + partial unique index); Flutter: `withdraw_sheet.dart`, `frozen_balance_sheet.dart`, `transaction_detail_sheet.dart` | Code: me. Manual: **you** | Script **D** below (400 → 201 → 409 → DELETE refund → settle). |
| 7 | `flutter analyze` **0 issues** · rate limiting · `.env.example` committed · tag `s1-done` | 🟡 mixed | — | — | Split: <br>• **analyze** — ✅ **verified** 2026-08-21: `flutter analyze --no-pub` → `No issues found!`. Re-run before you tag, with `! flutter analyze` in `D:\sportlynk`. <br>• **rate limiting** — ✅ in code (`middleware/rateLimit.js`, two tiers: 100/min per user, 20/min per IP) **and** fixed for Render: `server.js` now sets `trust proxy = 1` behind Render's proxy, so phone traffic is keyed per-user, not all squashed into one 20/min bucket. <br>• **`.env.example` committed** — ✅ `git ls-files backend/.env.example` returns it. <br>• **tag `s1-done`** — ❌ does not exist yet (tags are only `S1-Wave-2/3/4`). Create it **only after every row above is genuinely ticked** — command at the bottom of this file. |

### Before you start: the database is ready, and it wasn't

Two things were broken on Supabase that would have made most of the scripts below
either impossible or misleading. Both are fixed; read this so a green run means
something.

- **There were 0 bookable slots.** All 1,725 slots on Supabase were in the past, and
  every script below begins with "player books a slot". Fixed **without** running
  `seed_venues.js` (which would have deleted your 10 hand-built venues) —
  `node src/scripts/add_future_slots.js` created 2,100 slots across 10 venues × 14
  days × 15 hours, **1,990 bookable now**. It is idempotent, so re-run it any day
  the window runs short:
  ```bash
  cd D:\sportlynk\backend
  node src/scripts/add_future_slots.js --days 14
  ```
- **PKR 11,100 of escrow was frozen against bookings that no longer existed**, so
  D6's "`delta` = 0" check could never have passed honestly. Root cause was
  `seed_venues.js` deleting bookings without unwinding the escrow they held; the
  script is fixed and the damage repaired with `reconcile_wallets.js`. The ledger
  now reads **total frozen 0.00, owed 0.00, delta 0.00**. If a future re-seed or a
  crash ever puts it back, this is the repair — dry-run first, it changes nothing
  without `--apply`:
  ```bash
  node src/scripts/reconcile_wallets.js            # report only
  node src/scripts/reconcile_wallets.js --apply    # release over-frozen amounts
  ```
- **`?sslmode=require` no longer breaks the connection.** It used to, with
  `self-signed certificate in certificate chain` — see the note in
  [`DEPLOY_GUIDE.md`](DEPLOY_GUIDE.md) Step 4. `pool.js` now strips it, so the URL
  works either way. Relevant to you because the guide previously told you to add it
  on Render, which would have failed the first deploy.

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

> ⚠️ **D1 and D3 cannot be done from the app.** The Flutter sheet is *correctly*
> defensive, and that defence hides exactly the two responses this script exists
> to prove: `withdraw_sheet.dart:123` rejects an under-minimum amount on the phone
> so D1's request never reaches the server, and `withdraw_sheet.dart:233` replaces
> the form with the pending view once a request is in flight, so D3's second call
> is unreachable by tapping. **Script D is an API test.** D2, D4, D5 happen to work
> in the app too; D6 and D7 are app-only. Use the harness below for D1–D6.

### The harness (one PowerShell window, no quoting pain)

`Invoke-RestMethod` **throws** on any non-2xx, which would hide the 400 and the
409 — the two results that matter most here. This wrapper catches the throw and
prints the status code either way. Paste it once:

```powershell
$Base = 'http://localhost:3000/api'      # or https://<your-service>.onrender.com/api

function Call {
  param($Method, $Path, $Body)
  $p = @{ Method=$Method; Uri="$Base$Path"; UseBasicParsing=$true
          Headers=@{ Authorization = "Bearer $global:T" } }
  if ($Body) { $p.ContentType='application/json'; $p.Body=($Body|ConvertTo-Json -Compress) }
  try   { $r = Invoke-WebRequest @p; "$([int]$r.StatusCode)  $($r.Content)" }
  catch { $e=$_.Exception.Response
          "$([int]$e.StatusCode)  $((New-Object IO.StreamReader($e.GetResponseStream())).ReadToEnd())" }
}

# log in as the account you want to withdraw from — it needs balance ≥ 1000
$login = Invoke-RestMethod -Method Post -Uri "$Base/auth/login" -ContentType 'application/json' `
         -Body (@{ identifier='03001234567'; password='YOUR-PASSWORD' } | ConvertTo-Json)
$global:T = $login.data.token
```

`accountNumber` is **required** (≥ 6 digits) and `method` must be one of
`easypaisa` / `jazzcash` / `bank` — omit either and you get a *different* 400 than
the one D1 is testing for, so keep them in every call.

| Step | Call | Expect |
|---|---|---|
| D1 | `Call POST /wallet/withdraw @{amount=50; method='easypaisa'; accountNumber='03001234567'}` | **400**, `Minimum withdrawal is PKR 200.` |
| D2 | Same with `amount=1000` | **201**, row `pending`, balance debited 1000 immediately |
| D3 | Run D2's line again, unchanged | **409** — one pending at a time. Two code paths return 409 and you can tell them apart by the message: the readable pre-check (`wallet.js:217`) **names the amount** ("a withdrawal of PKR 1000 in progress"), the partial-unique-index backstop (`wallet.js:284`, Postgres `23505`) does not. Typing the call twice fires the pre-check — the index only wins a genuine simultaneous race, which you cannot produce by hand. Both are real enforcement; the index is what makes the pre-check safe under concurrency. |
| D4 | `Call GET /wallet/withdrawals` to read the `id`, then `Call DELETE /wallet/withdraw/<id>` | **200**, money refunded via a *new* ledger row — the audit trail keeps both halves |
| D5 | Run D2 again, then `Call GET /wallet/withdrawals` | Exactly one `pending` row in the list, marked `PENDING` |
| D6 | `Call GET /wallet/frozen` with an active booking | Itemised rows sum to the wallet's `frozen_balance`; **`delta = 0`**. This now genuinely reads 0 — the wallets were reconciled on 2026-08-21 and rows itemise `escrow_held` (`security_deposit`, the amount actually in escrow), not the slot price. A non-zero delta therefore means real drift: frozen money no active booking accounts for. Repair with `node src/scripts/reconcile_wallets.js --apply`. |
| D7 | **In the app** — tap any transaction | `TransactionDetailSheet` opens: icon, label, exact amount, `balanceAfter`, timestamp in **PKT** (UTC+5 — a transaction at 8 PM local must read 8 PM, not 3 PM) |

---

## The stale-wordings register (read before your viva)

1. **"Migration 010 applied local + Supabase"** — there is one live database, not
   two, and migration 010 was superseded by 011–014 anyway. The true state is
   *001–014 applied to Supabase, verified against Supabase*. Say it that way. (The
   commented-out `localhost` line in `backend/.env` is a stale pre-Wave-A copy, not
   a second environment — do not mention it as one.)
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
