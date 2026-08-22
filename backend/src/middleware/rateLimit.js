const { rateLimit, ipKeyGenerator } = require('express-rate-limit');
const jwt = require('jsonwebtoken');

/**
 * Request quotas (SRS SEC-6).
 *
 * Two tiers in one limiter, because the bucket a request lands in depends on
 * whether it carries a usable token:
 *
 *   authenticated → 100 req/min, counted per USER id
 *   anonymous     →  20 req/min, counted per IP
 *
 * Counting logged-in traffic per user rather than per IP matters here: a whole
 * cricket team on one café's Wi-Fi shares an IP, and the tight anonymous quota
 * would otherwise lock them all out of the app together.
 *
 * NOTE for deployment: the anonymous tier keys off `req.ip`, which is the socket
 * address unless Express is told to trust a proxy. Behind a load balancer, set
 * `app.set('trust proxy', <hops>)` in server.js — deliberately NOT set here,
 * since trusting X-Forwarded-For blindly lets any client forge its own IP and
 * walk straight past this limiter.
 */
const WINDOW_MS = 60 * 1000;
const AUTHENTICATED_MAX = 100;
const ANONYMOUS_MAX = 20;

/**
 * Which user is this, if any?
 *
 * This runs BEFORE authMiddleware, so `req.user` does not exist yet and the
 * token has to be read here. A token that fails verification counts as
 * anonymous — rejecting it is still authMiddleware's job, this only decides how
 * many attempts the caller is allowed. Memoised because both `limit` and
 * `keyGenerator` need the answer and jwt.verify is not free.
 */
const identifyUser = (req) => {
  if ('rateLimitUserId' in req) return req.rateLimitUserId;

  let userId = null;
  const header = req.headers.authorization;
  if (header) {
    const [scheme, token] = header.split(' ');
    if (scheme === 'Bearer' && token) {
      try {
        userId = jwt.verify(token, process.env.JWT_SECRET).id || null;
      } catch {
        userId = null; // expired or forged — treat as anonymous
      }
    }
  }

  req.rateLimitUserId = userId;
  return userId;
};

const apiRateLimit = rateLimit({
  windowMs: WINDOW_MS,
  limit: (req) => (identifyUser(req) ? AUTHENTICATED_MAX : ANONYMOUS_MAX),

  keyGenerator: (req) => {
    const userId = identifyUser(req);
    // ipKeyGenerator collapses IPv6 to a /56 so one client cannot rotate
    // through its own address range to reset the counter.
    return userId ? `user:${userId}` : `ip:${ipKeyGenerator(req.ip)}`;
  },

  // Uptime probes and the S.7 admin health panel poll /api/health; the realtime
  // handshake and its polling fallback live under /socket.io and carry their own
  // per-socket flood limiter. Throttling either here would make the API look
  // down (health) or silently break live chat under load (socket.io).
  skip: (req) => req.path === '/api/health' || req.path.startsWith('/socket.io'),

  standardHeaders: 'draft-7', // RateLimit / RateLimit-Policy
  legacyHeaders: false,

  // Same envelope as every other error the API returns (USE-3).
  handler: (req, res) => {
    res.status(429).json({
      success: false,
      message: 'Too many requests. Please slow down and try again in a minute.',
    });
  },
});

module.exports = { apiRateLimit, WINDOW_MS, AUTHENTICATED_MAX, ANONYMOUS_MAX };
