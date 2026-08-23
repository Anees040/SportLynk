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

// ─── Proxy trust (deployment only) ────────────────────────────
// Render terminates TLS in its own proxy and forwards the request, so `req.ip`
// is the proxy's address unless Express is told how many hops to trust. That
// breaks the anonymous tier of the rate limiter in the worst way: every phone on
// the internet lands in ONE 20-req/min bucket, so two people using the app at
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

// ─── Middleware ───────────────────────────────────────────────
app.use(cors({ origin: "*" }));
app.use(helmet());
// Request log. Sits above the rate limiter so throttled requests still show up
// as 429s — those lines are the signal that a client is misbehaving.
app.use(morgan("dev"));
// Rate limit BEFORE body parsing, so a flood costs us no JSON parsing (SEC-6).
app.use(apiRateLimit);
app.use(express.json());

// ─── Routes ──────────────────────────────────────────────────
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
const { startNoShowJob } = require("./jobs/noShowJob");
const { startAutoApproveJob } = require("./jobs/autoApproveJob");
const { startWithdrawalJob } = require("./jobs/withdrawalJob");
const { startMatchExpiryJob } = require("./jobs/matchExpiryJob");
const { ACTIVE_TEST_OVERRIDES } = require("./utils/escrow");

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
app.use("/api/matches", matchRoutes);

// ─── Health check ────────────────────────────────────────────
app.get("/api/health", (req, res) => {
  res.json({
    success: true,
    data: { status: "running" },
    message: "SportLynk API is healthy",
  });
});

// ─── 404 ─────────────────────────────────────────────────────
// Must sit after every route. Without it an unknown path falls through to
// Express's built-in handler, which answers with an HTML error page and breaks
// the { success, message } contract every Flutter client parses against.
app.use((req, res) => {
  res.status(404).json({ success: false, message: "Route not found" });
});

// ─── Global error handler ────────────────────────────────────
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

// ─── Start server ────────────────────────────────────────────
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

  // Start background jobs
  startNoShowJob();
  startAutoApproveJob();
  startWithdrawalJob();
  startMatchExpiryJob();
});
