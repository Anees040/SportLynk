# Deploy Guide — Render + phone demo (Wave S1-E)

**Who does what:** every step in this file is yours to run. Nothing here has been
done for you — the *code* changes Wave E needed are already committed to your
working tree, but no account was created, no dashboard was clicked, and no `git
push` was run on your behalf.

**Time:** ~45 minutes the first time, of which ~10 is waiting on Render.
**Cost:** PKR 0. Render's free web-service tier and Supabase's free tier are enough.

**Read this before you start:** two steps in here are destructive if done wrong.
Step 6 (Supabase) says **verify, do not re-run** — pasting `schema.sql` into your
live database would drop your real accounts. Step 8 (seeding) **deletes** one
owner's venues and their booking history. Both are flagged again in place.

---

## What you are building

```
   BEFORE (today)                        AFTER (this guide)

   Tecno phone ─┐                        Tecno phone ─── mobile data ──┐
                │ same Wi-Fi only                                      │
                ▼                                                      ▼
   Your laptop: node src/server.js       Render: https://….onrender.com/api
                │                                                      │
                ▼                                                      ▼
   Supabase (cloud PostgreSQL)           Supabase (cloud PostgreSQL) — same DB
```

The database does not move. Only the *API process* moves off your laptop, so the
phone stops depending on your laptop being awake and on the same Wi-Fi.

---

## Answering your two questions up front

### "When I disconnect my phone, will the backend still work?"

**Right now — partly, and only under conditions you will lose during a demo.**

Unplugging the USB cable itself is harmless. What matters is where the app is
pointed:

| Situation | Works? | Why |
|---|---|---|
| Cable unplugged, phone still on your Wi-Fi, laptop awake, `node src/server.js` running | ✅ | The app talks to your laptop's LAN IP. The cable was only ever for installing. |
| Laptop lid closed, or you switch Wi-Fi networks, or laptop sleeps | ❌ | The LAN IP is gone. Every request fails. |
| Phone on **mobile data** | ❌ **never worked** | A LAN IP like `192.170.0.110` is not reachable from the internet. |
| Phone anywhere, laptop off — **after this guide** | ✅ | Render runs the API 24/7 on a public HTTPS address. |

So: your current setup is a *development* setup that happens to survive cable
removal. It is not a demo setup. That is exactly what Wave E fixes.

### "How do I test S1 on my phone?"

Build a release APK pointed at Render (step 9 below), install it, unplug, switch
to mobile data. Then work through **[`S1_ACCEPTANCE.md`](S1_ACCEPTANCE.md)** —
it has the per-feature scripts, including the ones that need two accounts.

---

## Step 1 — Pre-flight checks (5 min, all local)

Run these four before touching any dashboard. Each one prevents a specific
failure you would otherwise hit ten minutes later.

```bash
cd D:\sportlynk

# 1a. Is the lockfile tracked? Render's `npm ci` REQUIRES it.
git ls-files --error-unmatch backend/package-lock.json

# 1b. Is any real .env about to be pushed? This must print NOTHING.
git ls-files | Select-String "\.env$"

# 1c. Does the template exist for a fresh clone?
git ls-files backend/.env.example

# 1d. Does the server still boot locally?
cd backend
node src/server.js
```

**What you should see**

- 1a → `backend/package-lock.json`. If it says *"Did you forget to 'git add'?"*,
  stop and run `git add backend/package-lock.json` — Render's build will fail
  without it.
- 1b → **nothing at all.** If it prints `backend/.env`, your database password and
  `JWT_SECRET` are in the repo. Fix that before pushing (`git rm --cached
  backend/.env`, then rotate both secrets).
- 1c → `backend/.env.example`.
- 1d → this, and no red text:

```
✅ Database connected (TLS on)
🚀 SportLynk API running on port 3000
   Environment: development
```

Three background jobs should also announce themselves. If you see a
`⚠️ TEST TIMING OVERRIDES ACTIVE` banner, you still have `SL_TEST_*` variables set
from an earlier test — close that terminal and open a fresh one. **Never deploy
with those set.**

Then `Ctrl-C`, and check the health route the way Render will:

```bash
curl http://localhost:3000/api/health
```

→ `{"success":true,"data":{"status":"running"},"message":"SportLynk API is healthy"}`

---

## Step 2 — Push to GitHub (5 min)

The remote already exists: `https://github.com/Anees040/SportLynk.git`. You have
several uncommitted waves sitting in the working tree (D, F and E). Render deploys
from GitHub, so **anything not pushed does not exist to Render.**

```bash
cd D:\sportlynk
git status                    # read this. Confirm no .env, no app_config.dart
git add .
git commit -m "Waves S1-D/E/F: fyp2 foundation, withdrawals, ApiClient, cloud deploy prep"
git push origin main
```

**What you should see:** `git status` clean afterwards, and the commit visible at
`https://github.com/Anees040/SportLynk/commits/main`.

Two notes:

- **`lib/constants/app_config.dart` is gitignored** and will not be pushed. That
  is correct for secrets, but it means a fresh clone of this repo cannot build the
  *Flutter* app. It does not affect Render, which only builds `backend/`. Keep your
  own copy safe — if you lose that file you lose your Cloudinary/Firebase config.
- **Do not tag `s1-done` yet.** Your existing tags are `S1-Wave-2`, `S1-Wave-3`,
  `S1-Wave-4`. The `s1-done` tag in the checklist does not exist and should only be
  created once every row of `S1_ACCEPTANCE.md` is actually ticked — including the
  phone-on-mobile-data row, which needs this guide finished first. The command,
  for later:

  ```bash
  git tag -a s1-done -m "Sprint 1 complete: escrow, slot locking, withdrawals, cloud demo"
  git push origin s1-done
  ```

---

## Step 3 — Create the Render account (3 min)

1. Go to **https://render.com** → **Get Started** → **GitHub**.
2. Authorise Render. When GitHub asks which repositories to grant access to,
   pick **Only select repositories → SportLynk**. Do not grant all repos.
3. Confirm your email if prompted.

**What you should see:** the Render dashboard, empty, with a **+ New** button
top-right.

You do not need a credit card for the free tier. If Render asks for one, you have
selected a paid plan by mistake — back out.

---

## Step 4 — Create the Web Service (5 min)

**+ New → Web Service → Build and deploy from a Git repository → SportLynk →
Connect.**

Then fill the form exactly like this. The two rows that break deploys are **Root
Directory** and **Build Command**:

| Field | Value | Why this exact value |
|---|---|---|
| **Name** | `sportlynk-api` | Becomes your URL: `https://sportlynk-api.onrender.com`. Lowercase, no spaces. |
| **Language / Runtime** | `Node` | Auto-detected. |
| **Branch** | `main` | |
| **Region** | `Singapore` | Nearest to Pakistan of the free regions — ~80 ms vs ~250 ms for Oregon. Pick this one; latency is visible in a live demo. |
| **Root Directory** | `backend` | **Critical.** The Node app is not at the repo root. Leave this blank and the build fails with *"no package.json found"*. |
| **Build Command** | `npm ci` | Reproducible install from `package-lock.json`. Use `npm install` only if `npm ci` fails. |
| **Start Command** | `npm start` | Which is `node src/server.js` (see `backend/package.json`). |
| **Instance Type** | **Free** | |

Then open **Advanced** and set:

| Field | Value |
|---|---|
| **Health Check Path** | `/api/health` |
| **Auto-Deploy** | `Yes` — every push to `main` redeploys |

**Do not click Create yet** — add the environment variables first (next step), or
the first boot will crash on a missing `DATABASE_URL` and you will have to wait
out a failed deploy.

### Why the health check path matters

Render polls it to decide whether your service is live. `/api/health` is a real
route in `src/server.js` and — deliberately — is **exempt from the rate limiter**
(`src/middleware/rateLimit.js`), so Render's polling can never throttle your real
traffic. Point it at `/` instead and Render sees the 404 from the catch-all
handler and marks a perfectly healthy service as failed.

---

## Step 5 — Environment variables on Render (5 min)

Still on the create form, find **Environment Variables** → **Add Environment
Variable** for each row below.

> 🔐 **Secrets go in this dashboard and nowhere else.** Never in a committed file,
> never in `README.md`, never pasted into a chat or an email. `backend/.env` is
> gitignored precisely so that these two values only ever exist in two places:
> your laptop and Render.

| Key | Value | Where it comes from |
|---|---|---|
| `DATABASE_URL` | `postgresql://postgres.<ref>:<password>@aws-0-<region>.pooler.supabase.com:5432/postgres?sslmode=require` | Supabase → your project → **Connect** → **Session pooler**. See the three rules below. |
| `JWT_SECRET` | your existing long random string | Copy from your local `backend/.env`. **Use the same value** — a different secret invalidates every existing login, including the test accounts you need for the demo. |
| `NODE_ENV` | `production` | Typed by hand. |

**Do NOT set `PORT`.** Render injects its own and `src/server.js` reads
`process.env.PORT`. Hard-coding `3000` here makes the health check time out
against a port nothing is listening on.

**Do NOT set any `SL_TEST_*` variable.** Those shorten the auto-approve, no-show
and withdrawal-settlement clocks. On a live server that silently corrupts your
money timings.

### Three rules for the `DATABASE_URL`

1. **Session pooler, not direct.** The host must contain `pooler.supabase.com`.
   The direct `db.<ref>.supabase.co` host is IPv6-only on the free tier and
   Render's outbound IPv4 cannot reach it — you get a hanging connection that
   eventually times out, with no useful error.
2. **Keep `?sslmode=require` on the end.** `src/db/pool.js` derives TLS from this
   (and from `NODE_ENV=production`, and from the host not being localhost — three
   independent belts, because a missing TLS flag produces one of the most confusing
   errors in this stack).
3. **Replace `[YOUR-PASSWORD]`.** Supabase hands you the URI with that literal
   placeholder in it. If you paste it unedited, the connection fails with
   *"password authentication failed"*. If you have forgotten the password:
   Supabase → Settings → Database → **Reset database password**, then update it in
   *both* Render and your local `backend/.env`.

Now click **Create Web Service**.

**What you should see** — the live build log, roughly:

```
==> Cloning from https://github.com/Anees040/SportLynk
==> Checking out commit … in branch main
==> Running build command 'npm ci'...
added 132 packages in 12s
==> Build successful 🎉
==> Deploying...
==> Running 'npm start'
✅ Database connected (TLS on)
🚀 SportLynk API running on port 10000
   Environment: production
==> Your service is live 🎉
```

That port number will not be 3000 — Render picks it. That is correct and expected.

First deploy takes 2–4 minutes. If it fails, jump to **Step 11 —
Troubleshooting**; every failure I could anticipate is in that table with its
cause.

---

## Step 6 — Supabase: **verify, do not re-run** (5 min)

> ⛔ **Do not paste `backend/schema.sql` into the Supabase SQL editor.** Read that
> sentence twice. Supabase has been your *only* database since the start of this
> project — your real user accounts, wallets, venues and booking history are in
> there. `schema.sql` is a from-scratch script; running it against a populated
> database is how you lose all of it. There is no local PostgreSQL to fall back on.
>
> The original Wave E spec said *"run schema.sql + migrations 001–010 in the SQL
> editor."* That instruction was written before Supabase became the single
> database. It is wrong now, and following it would be the single most damaging
> thing you could do this sprint. **This step verifies. It does not create.**

Open Supabase → your project → **SQL Editor** → **New query**, and run:

```sql
-- Should return 27 or more.
SELECT COUNT(*) AS table_count
  FROM information_schema.tables
 WHERE table_schema = 'public';

-- Wave F's table. Should return one row: withdrawals.
SELECT table_name
  FROM information_schema.tables
 WHERE table_schema = 'public' AND table_name = 'withdrawals';

-- The partial unique index that enforces "one pending withdrawal at a time"
-- in the DATABASE rather than in a JS if-statement. Should return one row.
SELECT indexname FROM pg_indexes
 WHERE tablename = 'withdrawals' AND indexname = 'uq_withdrawals_one_pending';

-- Wave A's escrow policy columns. Should return 20.00 and 24.
SELECT deposit_percent, cancellation_window_hours
  FROM escrow_policy LIMIT 1;
```

**If `withdrawals` comes back empty**, migration 014 has not been applied. Apply
it the same way every other migration was applied — by running the *runner*
locally, which connects to Supabase through `DATABASE_URL`:

```bash
cd D:\sportlynk\backend
node run_migration_014.js
```

**What you should see:** a list of green assertions and a summary line. Then run
it a second time — it is idempotent, and the second run should report that it
created nothing. That "created nothing" line is your proof it is safe to re-run,
which matters because you will re-run it if you ever rebuild the database.

There is **no separate "local + Supabase" step** despite what the S1 checklist
says. One database, applied once. See
[`S1_ACCEPTANCE.md`](S1_ACCEPTANCE.md) row 5 for why that checklist wording is
stale.

---

## Step 7 — Verify the deployed API (3 min)

```bash
curl https://sportlynk-api.onrender.com/api/health
```

**What you should see:**

```json
{"success":true,"data":{"status":"running"},"message":"SportLynk API is healthy"}
```

The **first** call after a period of inactivity may take 30–50 seconds. That is
Render's free tier waking the container, not a bug. Wait it out; do not assume it
is broken. See Step 10.

Then prove the database is genuinely attached, not just the process running:

```bash
curl https://sportlynk-api.onrender.com/api/venues
```

You should get your real venues back as JSON. `/api/health` only proves Node is
alive — it does not touch the database, so a healthy health check with a broken
`DATABASE_URL` is entirely possible. This second call is the one that matters.

Finally, log in with a real account to prove `JWT_SECRET` matches:

```bash
curl -X POST https://sportlynk-api.onrender.com/api/auth/login `
  -H "Content-Type: application/json" `
  -d '{"email":"<your test player>","password":"<password>"}'
```

A token back means all three environment variables are correct. `"Invalid
credentials"` for a password you know is right means `JWT_SECRET` differs from
your local one — or you are hitting a different database than you think.

---

## Step 8 — Seed demo venues (optional, 2 min)

Only if your Supabase venues are thin and you want the 10 demo grounds for the
presentation.

> ⚠️ **This deletes data.** `seed_venues.js` finds the **first owner account** in
> `users` and removes *that owner's* venues, every slot under them, every booking
> against them, and the transaction rows for those bookings — before inserting the
> demo set. User accounts, wallet balances and other owners are untouched.
>
> It prints exactly what it is about to delete, warns you specifically if any of
> those bookings are `confirmed` or `completed` (that is your escrow audit trail —
> the thing `S1_ACCEPTANCE.md` rows 1 and 2 check), and waits 5 seconds so you can
> `Ctrl-C`. **Read that output before letting the countdown finish.**

```bash
cd D:\sportlynk\backend
npm run seed:venues
```

It needs at least one owner account to exist; if none does, it exits telling you
so. To skip the countdown in a script: `npm run seed:venues -- --yes`.

**What you should see:** the delete summary, the countdown, `Using owner ID: …`,
then 10 venues and 15 days × 14 slots each inserted.

Run this **before** any acceptance test you care about, never after — it would
delete the very bookings you just made to prove the escrow works.

---

## Step 9 — Build the phone APK against Render (10 min)

The app takes its API address from **one** build-time variable, `API_BASE_URL`.
Nothing else in the app hard-codes a host any more (Wave E collapsed that down to
`lib/constants/api_constants.dart`).

```bash
cd D:\sportlynk
flutter build apk --release --dart-define=API_BASE_URL=https://sportlynk-api.onrender.com/api
```

**What you should see:** `✓ Built build\app\outputs\flutter-apk\app-release.apk`,
after 3–8 minutes for a first release build.

Install it with the phone plugged in and USB debugging on:

```bash
flutter install --release
```

or push the APK across and tap it in the file manager.

### The one mistake to avoid

> ⚠️ **`--dart-define` is not optional on a physical phone.** Plain `flutter run`
> now defaults to `10.0.2.2`, which is the Android *emulator's* alias for your
> laptop. On a real Tecno it means nothing and every request fails instantly with
> a connection error. If the app loads but every screen is empty, this is why —
> check what you passed to the build.

### Then unplug

Pull the cable. Turn **Wi-Fi off** on the phone. Turn **mobile data on**. Open the
app and complete a booking.

That is Wave E's acceptance criterion, and it is the moment the project stops
depending on your laptop. You can close the laptop entirely — Render is serving.

All four run modes, for reference:

| Mode | Command |
|---|---|
| Android emulator | `flutter run` |
| Phone on your Wi-Fi | `flutter run --dart-define=API_BASE_URL=http://<laptop-LAN-IP>:3000/api` |
| Phone over USB cable | `adb reverse tcp:3000 tcp:3000` then `flutter run` |
| Phone anywhere (demo) | `flutter run --dart-define=API_BASE_URL=https://sportlynk-api.onrender.com/api` |

Find the LAN IP with `ipconfig` — the IPv4 address under your Wi-Fi adapter.

**On the release build's signing:** `android/app/build.gradle.kts` signs release
with the *debug* keystore. That is why `--release` works with no keystore setup,
and it is also why Firebase phone OTP keeps working (same SHA-1 fingerprint as
your debug builds). Fine for an FYP demo. You would need a real keystore only to
publish on Play Store.

---

## Step 10 — The warm-up ritual (do this before every demo)

Render's free tier **stops your container after ~15 minutes of no traffic.** Two
consequences, and the second one is the one people miss:

**1. The first request after sleep takes 30–50 seconds.**

Wave F's `ApiClient` already absorbs this: the timeout is 45 s until the first
successful response of an app session, then tightens to 10 s. So a cold start
shows a slow spinner rather than an error. But 45 seconds of spinner while your
supervisor watches is its own kind of failure. So:

```bash
# 2 minutes before you present, twice, ~30 s apart:
curl https://sportlynk-api.onrender.com/api/health
curl https://sportlynk-api.onrender.com/api/health
```

The second one should come back instantly. Then open the app on the phone and
tap through one screen to be sure. Keep using it — anything within 15 minutes
keeps it warm.

**2. While the container is asleep, the three background sweeps do not run.**

`noShowJob`, `autoApproveJob` and `withdrawalJob` are `setInterval` timers inside
the API process (5-minute period). A sleeping process runs no timers. There is no
external scheduler.

What that actually means:

- A pending booking does not auto-approve *on the stroke of* 2 hours. It
  auto-approves at the first sweep after the container next wakes up.
- A no-show is not penalised 30 minutes after the slot. It is penalised the next
  time someone opens the app and something else happens to hit the API.
- A withdrawal does not settle exactly 24 hours later.

None of the *money math* is wrong — the jobs compare against real timestamps, so
when they do run they do the right thing for the right rows. Only the *moment of
firing* drifts. This is a free-tier trade-off, and it is worth a sentence in your
report rather than something to hide: an always-on paid instance or an external
cron ping would fix it.

**For a live demo of a timed feature, do not rely on Render.** Run the backend
locally with a shortened clock instead — that is what the `SL_TEST_*` overrides
exist for, and the exact commands are in
[`S1_ACCEPTANCE.md`](S1_ACCEPTANCE.md) rows 2 and 3.

---

## Step 11 — Troubleshooting

Ordered roughly by how likely you are to hit them.

| Symptom | Cause | Fix |
|---|---|---|
| Build: `npm ci … can only install with an existing package-lock.json` | Lockfile not pushed | `git add backend/package-lock.json && git commit && git push`. Or switch Build Command to `npm install`. |
| Build: `ENOENT: no such file or directory … package.json` | **Root Directory** is blank | Settings → set it to `backend` → Manual Deploy. |
| Build: `bcrypt` / `node-gyp` / `prebuild-install` failure | Render picked a Node version with no prebuilt binary for `bcrypt ^6` | `backend/package.json` already pins `"engines": {"node": ">=20"}`. If it still fails, add env var `NODE_VERSION=20` and redeploy. |
| Deploy: `❌ DATABASE_URL is not set` | Variable missing or misspelled on Render | Environment tab → add it exactly as `DATABASE_URL`. |
| Deploy: `no pg_hba.conf entry … no encryption` or `SSL required` | `?sslmode=require` missing from the URL | Add it. `NODE_ENV=production` also forces TLS — set both. |
| Deploy: `password authentication failed for user "postgres…"` | `[YOUR-PASSWORD]` placeholder still in the URL, or wrong password | Recopy from Supabase → Connect, substitute the real password. Reset it in Supabase if unknown. |
| Deploy: `getaddrinfo ENOTFOUND` / connection hangs then times out | Using the **direct** `db.<ref>.supabase.co` host, which is IPv6-only | Switch to the **Session pooler** URI (`…pooler.supabase.com:5432`). |
| Health check never turns green, service marked failed | Health Check Path wrong, or `PORT` was set manually | Path must be `/api/health`. Delete any `PORT` variable you added. |
| First request takes ~40 s, then everything is fast | Free-tier cold start. Not a bug. | Warm up before demos (Step 10). |
| App on phone: every screen empty, instant errors | Built without `--dart-define`, so it is pointed at `10.0.2.2` | Rebuild with `--dart-define=API_BASE_URL=https://….onrender.com/api`. |
| App works on Wi-Fi, dies on mobile data | Still pointed at a LAN IP | Same fix as above. A `192.168.x.x` / `192.170.x.x` address is not reachable from the internet, by design. |
| `429 Too many requests` on the phone | Rate limiter. Now correctly keyed per-user behind Render's proxy (`app.set("trust proxy", 1)` in `server.js`) | Wait 60 s. If it recurs with light use, something is retrying in a loop — check the Render logs. |
| `502 Bad Gateway` | Process crashed after boot | Render → **Logs**. The stack trace is there. `/api/health` returning 404 instead means the service is up but the path is wrong. |
| `404 {"success":false,"message":"Route not found"}` | You reached the API but the path is wrong | Every route is under `/api/…`. `https://…onrender.com/venues` is a 404; `/api/venues` is correct. |
| Everything worked yesterday, all requests fail today | Free-tier services are suspended after 90 days of inactivity, or a failed auto-deploy replaced a working one | Render → Events. Manual Deploy → **Deploy latest commit**. |

**Reading the logs is the fastest path for anything not in this table.** Render →
your service → **Logs**. `morgan` prints every request with its status code, and
the global error handler in `src/server.js` logs the full stack server-side while
returning only a safe generic message to the client — so the real cause is always
in the Render log even when the app shows "Internal server error".

---

## Where things live afterwards

| Thing | Where | Notes |
|---|---|---|
| API process | Render (`sportlynk-api`) | Redeploys on every push to `main` |
| Database | Supabase | Unchanged. Same DB for local dev and the deployed API. |
| DB password, `JWT_SECRET` | Render dashboard **and** local `backend/.env` only | Never in git |
| Flutter secrets | `lib/constants/app_config.dart`, `lib/firebase_options.dart` | Gitignored. Back these up outside the repo. |
| API address the app uses | Passed at build time via `--dart-define=API_BASE_URL` | Single source: `lib/constants/api_constants.dart` |

---

## Done when

- [ ] `https://<your-app>.onrender.com/api/health` returns the healthy JSON
- [ ] `/api/venues` returns your real venues (proves the DB is attached)
- [ ] Login with an existing account succeeds (proves `JWT_SECRET` matches)
- [ ] Release APK installed on the Tecno, built with `--dart-define`
- [ ] Cable unplugged, Wi-Fi **off**, mobile data **on**, laptop closed
- [ ] A booking completed end-to-end in that state

That last line is Wave E's acceptance criterion. When it is true, tick row 5 in
[`S1_ACCEPTANCE.md`](S1_ACCEPTANCE.md) and carry on down that checklist.
