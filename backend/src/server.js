const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '..', '.env') });
const express = require('express');
const cors = require('cors');
const helmet = require('helmet');

const app = express();

// ─── Middleware ───────────────────────────────────────────────
app.use(cors({ origin: '*' }));
app.use(helmet());
app.use(express.json());

// ─── Routes ──────────────────────────────────────────────────
const authRoutes = require('./routes/auth');
const venueRoutes = require('./routes/venues');
const bookingRoutes = require('./routes/bookings');
const ownerRoutes = require('./routes/owner');
const walletRoutes = require('./routes/wallet');
const playerRoutes = require('./routes/player');

app.use('/api/auth', authRoutes);
app.use('/api/venues', venueRoutes);
app.use('/api/bookings', bookingRoutes);
app.use('/api/owner', ownerRoutes);
app.use('/api/wallet', walletRoutes);
app.use('/api/player', playerRoutes);

// ─── Health check ────────────────────────────────────────────
app.get('/api/health', (req, res) => {
  res.json({ success: true, data: { status: 'running' }, message: 'SportLynk API is healthy' });
});

// ─── Global error handler ────────────────────────────────────
app.use((err, req, res, next) => {
  console.error('Unhandled error:', err);
  res.status(500).json({ success: false, message: 'Internal server error' });
});

// ─── Start server ────────────────────────────────────────────
const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`🚀 SportLynk API running on port ${PORT}`);
  console.log(`   Environment: ${process.env.NODE_ENV || 'development'}`);
});
