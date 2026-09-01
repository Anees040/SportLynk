const path = require("path");
require("dotenv").config({ path: path.join(__dirname, "..", ".env") });
const http = require("http");
const express = require("express");
const cors = require("cors");
const helmet = require("helmet");
const morgan = require("morgan");
const { apiRateLimit } = require("./middleware/rateLimit");
const { initRealtime } = require("./realtime");

const app = express();

// Proxy trust (deployment only)
// Render terminates TLS in its own proxy and forwards the request, so `req.ip`
// is the proxy's address unless Express is told how many hops to trust. That
// breaks the anonymous tier of the rate limiter in the worst way: every phone on
// the internet lands in one 20-req/min bucket, so two people using the app at
// once can 429 each other. express-rate-limit also logs a validation error for
// exactly this case.
//
// `1` — not `true` — is the safe value: Express then reads the hop Render
// appended to X-Forwarded-For, which a client cannot forge. `true` would take
// the leftmost, client-supplied entry and hand anyone a way to walk past the
// limiter (the risk rateLimit.js warns about).
//
// RENDER is set by Render itself, so this still works if NODE_ENV is forgotten.
if (process.env.RENDER || process.env.NODE_ENV === "production") {
  app.set("trust proxy", 1);
}

// Middleware
app.use(cors({ origin: "*" }));
app.use(helmet());
// Request log. Sits above the rate limiter so throttled requests still show up
// as 429s — those lines are the signal that a client is misbehaving.
app.use(morgan("dev"));
// Rate limit before body parsing, so a flood costs no JSON parsing (SEC-6).
app.use(apiRateLimit);
app.use(express.json());

// Routes
const authRoutes = require("./routes/auth");
const venueRoutes = require("./routes/venues");
const bookingRoutes = require("./routes/bookings");
const ownerRoutes = require("./routes/owner");
const adminRoutes = require("./routes/admin");
const walletRoutes = require("./routes/wallet");
const playerRoutes = require("./routes/player");
const userRoutes = require("./routes/users");
const slotRoutes = require("./routes/slotLock");
const teamRoutes = require("./routes/teams");
const chatRoutes = require("./routes/chat");
const matchRoutes = require("./routes/matches");
const reviewRoutes = require("./routes/reviews");
const internalRoutes = require("./routes/internal");
const assistantRoutes = require("./routes/assistant");
const tournamentRoutes = require("./routes/tournaments");
const notificationRoutes = require("./routes/notifications");
const { startNoShowJob } = require("./jobs/noShowJob");
const { startAutoApproveJob } = require("./jobs/autoApproveJob");
const { startWithdrawalJob } = require("./jobs/withdrawalJob");
const { startMatchExpiryJob } = require("./jobs/matchExpiryJob");
const { startSentimentBackfillJob } = require("./jobs/sentimentBackfillJob");
const { startTournamentJob } = require("./jobs/tournamentJob");
const { startPushJob } = require("./jobs/pushJob");
const { assertNotificationTypes } = require("./utils/notificationTypes");
const settings = require("./utils/globalSettings");
const escrow = require("./utils/escrow");
const { ACTIVE_TEST_OVERRIDES } = require("./utils/escrow");

// Notification registry (S.7 Wave C)
// Runs at load, before a single route is mounted, and throws on an inconsistent
// registry — a category the CHECK constraint would reject, a priority that is not
// high|normal|low, a missing icon, an entity with no id resolver. Same shape as
// services/assistantActions' assertRoutable(): the failure a registry mistake causes
// is a notification that renders blank and taps nowhere, which nobody notices until a
// user complains, so it is made a boot failure instead.
const NOTIF_REGISTRY = assertNotificationTypes();

app.use("/api/auth", authRoutes);
app.use("/api/venues", venueRoutes);
app.use("/api/bookings", bookingRoutes);
app.use("/api/owner", ownerRoutes);
app.use("/api/admin", adminRoutes);
app.use("/api/wallet", walletRoutes);
app.use("/api/player", playerRoutes);
app.use("/api/users", userRoutes);
app.use("/api/slots", slotRoutes);
app.use("/api/teams", teamRoutes);
app.use("/api/chat", chatRoutes);
// Notifications (S.7 Wave C). routes/notifications.js declares /summary,
// /preferences, /devices, /read-all, /test and /types before /:id, for the same
// declaration-order reason as tournaments below.
app.use("/api/notifications", notificationRoutes);
app.use("/api/matches", matchRoutes);
// Tournaments (S.7 Wave A). routes/tournaments.js declares /mine and /preview
// before /:id — Express matches in declaration order, so the reverse would send
// GET /api/tournaments/mine to the detail handler as id="mine".
app.use("/api/tournaments", tournamentRoutes);
app.use("/api/internal", internalRoutes);
// Scout (S.6). Requiring routes/assistant also requires services/assistantActions,
// whose assertRoutable() throws at load time if any trained intent label has no
// handler -- so a mismatch between model #4's labels and the action registry fails
// the boot rather than one unlucky user's message.
app.use("/api/assistant", assistantRoutes);
// Reviews own four paths across three resources — /api/reviews, /api/reviews/:id/flag,
// /api/venues/:id/reviews, /api/users/:id/reviews — so this router mounts at the bare
// /api root and each handler declares `auth` itself (it does not use router.use(auth),
// which at /api would gate every sibling route). It is mounted after the venue and user
// routers: those own /api/venues/:id and /api/users/me, and a request for the deeper
// .../:id/reviews path they don't define simply falls through to here.
app.use("/api", reviewRoutes);

// Health check
app.get("/api/health", (req, res) => {
  res.json({
    success: true,
    data: { status: "running" },
    message: "SportLynk API is healthy",
  });
});

// 404
// Must sit after every route. Without it an unknown path falls through to
// Express's built-in handler, which answers with an HTML error page and breaks
// the { success, message } contract every Flutter client parses against.
app.use((req, res) => {
  res.status(404).json({ success: false, message: "Route not found" });
});

// Global error handler
// The last line of defence for USE-3: the full error (including any SQL text,
// constraint names and stack) is logged server-side, and the client only ever
// receives one of the fixed sentences below. Nothing derived from `err.message`
// crosses the wire.
//
// Keep all four parameters — Express identifies error handlers by arity, so
// dropping the unused `next` silently turns this back into normal middleware.
app.use((err, req, res, next) => {
  const status = Number(err.status || err.statusCode) || 500;

  console.error(`Unhandled error [${req.method} ${req.originalUrl}]:`, err);

  let message = "Internal server error";
  if (err.type === "entity.parse.failed") message = "Malformed JSON body";
  else if (err.type === "entity.too.large") message = "Request body too large";
  else if (status === 401) message = "Unauthorized";
  else if (status === 403) message = "Access denied";
  else if (status === 404) message = "Not found";

  res.status(status).json({ success: false, message });
});

// Start server
const PORT = process.env.PORT || 3000;

// Socket.IO needs the raw HTTP server, not the Express `app`, so the WebSocket
// upgrade and the REST API share one port. initRealtime() builds the io server,
// authenticates every handshake with the same JWT as the REST middleware, and
// registers io with the realtime bus that the chat and team routes emit through.
// Requests to /socket.io are handled by engine.io before Express sees them, so
// they never reach the routes or the 404 handler below.
const server = http.createServer(app);
initRealtime(server);

server.listen(PORT, () => {
  console.log(`🚀 SportLynk API running on port ${PORT}`);
  console.log(`   Environment: ${process.env.NODE_ENV || "development"}`);
  console.log(
    `   Notifications: ${NOTIF_REGISTRY.types} types → ${NOTIF_REGISTRY.routes} routes`,
  );

  // A sped-up sweep or a shortened auto-decide window must never be mistaken for
  // real behaviour, so it is announced as loudly as a boot banner can manage.
  if (ACTIVE_TEST_OVERRIDES.length) {
    console.warn("");
    console.warn("  ⚠️  ⚠️  ⚠️   TEST TIMING OVERRIDES ACTIVE   ⚠️  ⚠️  ⚠️");
    for (const line of ACTIVE_TEST_OVERRIDES) console.warn(`      ${line}`);
    console.warn("      Money splits are UNCHANGED — only timings are shortened.");
    console.warn("      Unset these SL_TEST_* vars before any demo or deploy.");
    console.warn("");
  }

  // S.7 Wave D. Pull the admin's configured deposit percent into
  // `escrow.POLICY.DEPOSIT_PERCENT` once, at boot.
  //
  // ~30 call sites read that constant to describe the policy ("20% of the total is
  // your at-risk deposit") from synchronous code that cannot await a settings row.
  // `bookingService` reads the setting itself and stamps the amount it holds onto
  // the booking, so money is already correct without this; what this fixes is copy
  // — a quote screen that says 20% while the next booking holds 25%. Fire-and-forget
  // and silent on failure: a settings read must never be the reason the API does not
  // come up, and the documented default is a safe thing to be describing.
  settings.deposit({ fresh: true })
    .then((pct) => escrow.setDepositPercent(pct, "boot"))
    .catch(() => {});

  // Start background jobs
  startNoShowJob();
  startAutoApproveJob();
  startWithdrawalJob();
  startMatchExpiryJob();
  startSentimentBackfillJob();
  // FE-4: enforces the registration deadline whether or not the organiser opens
  // the app. Without it a tournament nobody generated would hold every captain's
  // entry fee frozen indefinitely.
  startTournamentJob();
  // The notification outbox drain (S.7 Wave C). notify() writes rows inside money
  // transactions and never calls FCM there — holding a wallet row's FOR UPDATE lock
  // across an HTTPS round trip is how a settlement path acquires a network timeout.
  // This job is what turns those rows into a tray banner and an in-app badge, and it
  // announces its own Firebase state on the line below rather than failing to boot.
  startPushJob();
});
