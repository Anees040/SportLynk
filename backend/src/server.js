const path = require("path");
require("dotenv").config({ path: path.join(__dirname, "..", ".env") });
const express = require("express");
const cors = require("cors");
const helmet = require("helmet");
const morgan = require("morgan");
const { apiRateLimit } = require("./middleware/rateLimit");

const app = express();

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
const { startNoShowJob } = require("./jobs/noShowJob");
const { startAutoApproveJob } = require("./jobs/autoApproveJob");

app.use("/api/auth", authRoutes);
app.use("/api/venues", venueRoutes);
app.use("/api/bookings", bookingRoutes);
app.use("/api/owner", ownerRoutes);
app.use("/api/admin", adminRoutes);
app.use("/api/wallet", walletRoutes);
app.use("/api/player", playerRoutes);
app.use("/api/users", userRoutes);
app.use("/api/slots", slotRoutes);

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
app.listen(PORT, () => {
  console.log(`🚀 SportLynk API running on port ${PORT}`);
  console.log(`   Environment: ${process.env.NODE_ENV || "development"}`);
  // Start background jobs
  startNoShowJob();
  startAutoApproveJob();
});
