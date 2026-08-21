const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '..', '..', '.env') });
const { Pool } = require('pg');

const connectionString = process.env.DATABASE_URL || '';

/**
 * Decide whether this connection needs TLS.
 *
 * This used to be `NODE_ENV === 'production' ? {...} : false`, which meant one
 * forgotten environment variable on Render produced a connection failure whose
 * error text says nothing about SSL. Every managed Postgres — Supabase
 * included — requires TLS, so the URL itself is the more reliable signal:
 *
 *   1. An explicit `sslmode=` in the URL always wins (that is what the flag is
 *      for, and `sslmode=disable` must be honoured).
 *   2. NODE_ENV=production still forces TLS on.
 *   3. Otherwise: anything that is not localhost is assumed to be remote, and
 *      therefore to need TLS. This is the case that matters for us — we develop
 *      against Supabase, so the local run needs TLS just as much as Render does.
 */
function needsSsl(url) {
  const explicit = /[?&]sslmode=([a-z-]+)/i.exec(url);
  if (explicit) return explicit[1].toLowerCase() !== 'disable';
  if (process.env.NODE_ENV === 'production') return true;
  if (!url) return false;
  return !/@(?:localhost|127\.0\.0\.1)[:/]/i.test(url);
}

/**
 * Remove `sslmode=` from the URL before pg ever sees it.
 *
 * This is not tidying — it fixes a connection failure. In pg 8.20,
 * pg-connection-string parses `sslmode=require` and treats it as an alias for
 * `verify-full`, and that parsed value OVERRIDES the `ssl` option passed to the
 * Pool constructor. Supabase's pooler presents a chain Node has no root for, so
 * the result is a hard failure:
 *
 *   ❌ Database connection failed: self-signed certificate in certificate chain
 *
 * Measured on this project's exact URL and pg version:
 *   sslmode=require   + ssl:{rejectUnauthorized:false}  → FAILS
 *   (no sslmode)      + ssl:{rejectUnauthorized:false}  → connects
 *   sslmode=no-verify + ssl:{rejectUnauthorized:false}  → connects
 *
 * That made the documented setup self-defeating: doc/claude.md and
 * DEPLOY_GUIDE.md both say to append `?sslmode=require`, and the old error hint
 * below told you to add it too — so following our own instructions broke Render.
 *
 * Stripping it means `sslmode` stays a *signal* that needsSsl() reads, but never
 * a *directive* pg acts on. TLS is then decided in exactly one place: the `ssl`
 * option. Whatever anyone pastes into the Render dashboard now works, with or
 * without the flag, on any pg version.
 */
function stripSslMode(url) {
  if (!url) return url;
  return url
    .replace(/([?&])sslmode=[a-z-]+/i, '$1')  // drop the pair, keep the separator
    .replace(/&&+/g, '&')                     // collapse a gap left mid-query
    .replace(/[?&]$/, '')                     // drop a now-empty trailing ? or &
    .replace(/\?&/, '?');                     // fix "?&next=..."
}

const useSsl = needsSsl(connectionString);

const pool = new Pool({
  connectionString: stripSslMode(connectionString),
  // rejectUnauthorized:false — Supabase's pooler presents a chain Node does not
  // have a root for by default. The connection is still encrypted; we simply do
  // not verify the certificate, which is the accepted trade-off for this project.
  ssl: useSsl ? { rejectUnauthorized: false } : false,
});

// Fail loudly and usefully. "Database connection failed: <driver error>" on its
// own has cost hours before; the hints below name the three things that are
// actually ever wrong.
if (!connectionString) {
  console.error(
    '❌ DATABASE_URL is not set.\n' +
    '   Local:  put it in backend/.env (see backend/.env.example)\n' +
    '   Render: Dashboard → your service → Environment → Add DATABASE_URL'
  );
}

pool.query('SELECT NOW()')
  .then(() => console.log(`✅ Database connected (TLS ${useSsl ? 'on' : 'off'})`))
  .catch((err) => {
    console.error('❌ Database connection failed:', err.message);
    const m = (err.message || '').toLowerCase();
    if (m.includes('self-signed') || m.includes('self signed') || m.includes('certificate')) {
      console.error('   → Certificate rejected. This should be impossible now that');
      console.error('     pool.js strips sslmode= from the URL. If you see this, some');
      console.error('     other code built its own Pool without rejectUnauthorized:false.');
    } else if (m.includes('ssl') || m.includes('tls') || m.includes('secure')) {
      console.error('   → The server wants TLS but this connection did not offer it.');
      console.error('     Check NODE_ENV, or that the host is not localhost.');
    } else if (m.includes('password') || m.includes('authentication')) {
      console.error('   → Wrong password, or the URL still contains [YOUR-PASSWORD].');
    } else if (m.includes('enotfound') || m.includes('eai_again')) {
      console.error('   → Host not found. Copy the URL again from Supabase → Connect.');
    } else if (m.includes('etimedout') || m.includes('econnrefused')) {
      console.error('   → Use the Session pooler URL from Supabase → Connect, not the direct one.');
    }
  });

module.exports = pool;
