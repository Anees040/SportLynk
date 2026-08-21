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

const useSsl = needsSsl(connectionString);

const pool = new Pool({
  connectionString,
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
    if (m.includes('ssl') || m.includes('tls') || m.includes('secure')) {
      console.error('   → Add ?sslmode=require to the end of DATABASE_URL.');
    } else if (m.includes('password') || m.includes('authentication')) {
      console.error('   → Wrong password, or the URL still contains [YOUR-PASSWORD].');
    } else if (m.includes('enotfound') || m.includes('eai_again')) {
      console.error('   → Host not found. Copy the URL again from Supabase → Connect.');
    } else if (m.includes('etimedout') || m.includes('econnrefused')) {
      console.error('   → Use the Session pooler URL from Supabase → Connect, not the direct one.');
    }
  });

module.exports = pool;
