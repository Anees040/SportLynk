/**
 * check_ml_service.js — prove the ML integration works, and that it degrades.
 *
 * WHY THIS EXISTS
 * ---------------
 * S.3 Wave A added a whole tier (ml-service/) and a client for it
 * (src/services/mlClient.js), but no route calls that client until Wave C. Without
 * a harness, Wave A would ship code that has never been executed — and the part
 * that matters most, the DEGRADATION path, is exactly the part nobody exercises by
 * accident because it only runs when something is broken.
 *
 * So this script is the acceptance test for the wave, in the family of
 * verify_schema.js and run_match_flow_check.js: read-only, exits 0 or 1, and safe
 * to run any time.
 *
 * WHAT IT PROVES
 * --------------
 *   1. GUARDRAILS. The clamp band, the PKR 50 rounding and the peak-hour rule are
 *      pure functions, so they are checked with no service and no network. A model
 *      must never be able to suggest PKR 47 or PKR 190,000 to a real venue owner.
 *   2. CROSS-LANGUAGE CONSTANTS. PEAK_START_HOUR, PEAK_END_HOUR and the price-ratio
 *      band exist twice — in mlClient.js and in ml-service/app/core/features.py —
 *      because Node cannot import Python. This asserts the two copies agree, by
 *      reading GET /features/spec. That turns "keep these in sync" from a comment
 *      into a check that fails.
 *   3. THE UP PATH. /health answers, reports its model inventory truthfully, and
 *      /predict/price either returns a model suggestion (Wave C onward) or an
 *      honest 503 model_not_loaded (Wave A/B). Both are passes; the script says
 *      which it saw.
 *   4. THE API-KEY GATE. A request with no key and a request with a wrong key both
 *      get 401 with the same body. Verified with raw fetch, because mlClient always
 *      sends the real key and therefore cannot test this itself.
 *   5. THE DOWN PATH — WITHOUT ASKING ANYONE TO STOP UVICORN. The script stands up
 *      its own failure conditions: a closed port (connection refused) and a socket
 *      that accepts and never replies (timeout). It then checks that suggestPrice
 *      still returns a usable heuristic, that the 2-second ceiling is honoured, and
 *      that the circuit breaker opens and short-circuits the next call.
 *
 *      Self-contained on purpose. A test that needs a human to kill a process in
 *      another terminal is a test that gets skipped, and this is the path that
 *      protects the owner dashboard in production.
 *
 * WHAT IT DOES NOT DO
 * -------------------
 * No database connection, no writes, no schema. Nothing here can affect a booking.
 *
 * USAGE
 * -----
 *   node src/scripts/check_ml_service.js
 *   node src/scripts/check_ml_service.js --verbose      # show every passing check
 *
 * Start the ML service first for the full run:
 *   cd ..\ml-service ; .\run_dev.ps1
 *
 * With the service DOWN the script still passes: sections 1, 5 and the degradation
 * checks all run, and the up-path sections report SKIP with the reason. That is
 * intentional — "the backend is fine without the ML service" is a result, not a
 * gap.
 */

const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '..', '..', '.env') });

const crypto = require('crypto');
const net = require('net');

const ml = require('../services/mlClient');

const verbose = process.argv.includes('--verbose');

let passed = 0;
const failures = [];
const skipped = [];

function ok(label, detail = '') {
  passed += 1;
  if (verbose) console.log(`   ok    ${label}${detail ? `  — ${detail}` : ''}`);
}

function fail(label, detail) {
  failures.push({ label, detail });
  console.log(`   FAIL  ${label}`);
  if (detail) console.log(`         ${detail}`);
}

function skip(label, why) {
  skipped.push({ label, why });
  console.log(`   skip  ${label}  — ${why}`);
}

function check(label, condition, detail = '') {
  if (condition) ok(label, detail);
  else fail(label, detail || 'condition was false');
}

function section(title) {
  console.log(`\n${title}`);
}

/** First 8 hex of sha256 — the same digest ml-service's /health reports. */
function fingerprint(value) {
  return crypto.createHash('sha256').update(value, 'utf8').digest('hex').slice(0, 8);
}

/** A TCP port with nothing listening on it: bind, read the port, close. */
function closedPort() {
  return new Promise((resolve, reject) => {
    const probe = net.createServer();
    probe.once('error', reject);
    probe.listen(0, '127.0.0.1', () => {
      const { port } = probe.address();
      probe.close(() => resolve(port));
    });
  });
}

/** A socket that accepts connections and never answers — forces a client timeout. */
function blackHole() {
  return new Promise((resolve, reject) => {
    const sockets = new Set();
    const server = net.createServer((socket) => {
      sockets.add(socket);
      socket.on('error', () => {}); // the client aborting is expected, not an error
      socket.on('close', () => sockets.delete(socket));
    });
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      resolve({
        port: server.address().port,
        close: () =>
          new Promise((done) => {
            for (const socket of sockets) socket.destroy();
            server.close(() => done());
          }),
      });
    });
  });
}

async function main() {
  console.log('\nSportLynk — ML service integration check');
  console.log('='.repeat(64));

  const url = (process.env.ML_SERVICE_URL || '').trim();
  const key = (process.env.ML_API_KEY || '').trim();

  // ─── 0. Configuration ─────────────────────────────────────────
  section('0. Configuration (backend/.env)');
  console.log(`   ML_SERVICE_URL   ${url || '(unset)'}`);
  console.log(`   ML_API_KEY       ${key ? `set, ${key.length} chars, fp=${fingerprint(key)}` : '(unset)'}`);
  console.log(`   ML_TIMEOUT_MS    ${ml.timeoutMs()}  (default ${ml.DEFAULT_TIMEOUT_MS})`);
  if (key) {
    // The point of the fingerprint: compare this line against /health's
    // apiKeyFingerprint to prove the two .env files hold the same key, without
    // either process printing a secret. A trailing space that no editor shows
    // produces a different digest.
    console.log('   -> compare fp above with data.apiKeyFingerprint from /health');
  }

  // ─── 1. Guardrails — pure, no network ─────────────────────────
  section('1. Guardrails and heuristic (pure functions, no service needed)');

  const BASE = 2000;

  {
    const r = ml.applyGuardrails(BASE * 5, BASE);
    check(
      'absurdly high suggestion is clamped to base x 1.50',
      r.price === 3000 && r.clamped === true,
      `got ${r.price}, clamped=${r.clamped}`,
    );
  }
  {
    const r = ml.applyGuardrails(47, BASE);
    check(
      'absurdly low suggestion is clamped to base x 0.70',
      r.price === 1400 && r.clamped === true,
      `got ${r.price}, clamped=${r.clamped}`,
    );
  }
  {
    const r = ml.applyGuardrails(2347, BASE);
    check(
      'in-band price rounds to nearest PKR 50 and is not marked clamped',
      r.price === 2350 && r.clamped === false,
      `got ${r.price}, clamped=${r.clamped}`,
    );
  }
  {
    // A guardrail that its own rounding step can violate is not a guardrail.
    const odd = 1010;
    const r = ml.applyGuardrails(1, odd);
    check(
      'rounding never pushes a clamped price back outside the band',
      r.price >= odd * ml.PRICE_RATIO_MIN && r.price % ml.PRICE_ROUND_TO === 0,
      `base ${odd}, min ${odd * ml.PRICE_RATIO_MIN}, got ${r.price}`,
    );
  }
  {
    const peak = ml.heuristicPrice(BASE, '19:00:00');
    check(
      `peak-hour heuristic applies +${Math.round((ml.HEURISTIC_PEAK_MULTIPLIER - 1) * 100)}%`,
      peak.raw === BASE * ml.HEURISTIC_PEAK_MULTIPLIER,
      `got ${peak.raw}`,
    );
    const off = ml.heuristicPrice(BASE, '11:00:00');
    check('off-peak heuristic leaves the base price alone', off.raw === BASE, `got ${off.raw}`);
    const bad = ml.heuristicPrice(BASE, 'not-a-time');
    check(
      'unreadable slot time yields no uplift rather than a guess',
      bad.raw === BASE && /unreadable/i.test(bad.reason),
      bad.reason,
    );
  }
  {
    check(
      `peak window boundaries are inclusive (${ml.PEAK_START_HOUR}–${ml.PEAK_END_HOUR})`,
      ml.isPeakHour(ml.PEAK_START_HOUR) &&
        ml.isPeakHour(ml.PEAK_END_HOUR) &&
        !ml.isPeakHour(ml.PEAK_START_HOUR - 1) &&
        !ml.isPeakHour(ml.PEAK_END_HOUR + 1),
    );
    check(
      'hourOf parses TIME strings, ints and Dates',
      ml.hourOf('19:00:00') === 19 && ml.hourOf('19:00') === 19 && ml.hourOf(19) === 19,
    );
  }
  {
    // Missing basePrice is a caller bug, not a degradation: it must not be papered
    // over with a guessed base.
    const r = await ml.suggestPrice({ startTime: '19:00:00' });
    check(
      'suggestPrice without a basePrice returns 0 and a reason, never a guess',
      r.suggestedPrice === 0 && typeof r.reason === 'string' && r.reason.length > 0,
      r.reason,
    );
  }

  // ─── 2. Up path ───────────────────────────────────────────────
  section('2. ML service up path');

  ml.resetBreaker();
  const healthResult = await ml.health();

  if (!healthResult.reachable) {
    skip('/health', healthResult.error || 'not reachable');
    skip('/features/spec cross-language constant check', 'ml-service not reachable');
    skip('/predict/price', 'ml-service not reachable');
    skip('API-key gate (401 on missing / wrong key)', 'ml-service not reachable');
    console.log('\n   To run these, start the ML service in another terminal:');
    console.log('       cd ..\\ml-service ; .\\run_dev.ps1');
  } else {
    const h = healthResult.data || {};
    check('/health returns 200 in the house envelope', healthResult.status === 200);
    check('/health reports a service name and version', Boolean(h.service && h.version),
      `${h.service} v${h.version}`);
    check('/health reports a model inventory', Array.isArray(h.models), `${h.modelsTotal} model(s)`);
    check(
      '/health does NOT return the API key',
      !JSON.stringify(h).includes(key),
      'a secret in a health body would be a leak',
    );

    if (key && h.apiKeyFingerprint) {
      check(
        'backend/.env and ml-service/.env hold the SAME key (fingerprints match)',
        h.apiKeyFingerprint === fingerprint(key),
        `backend=${fingerprint(key)} ml-service=${h.apiKeyFingerprint}`,
      );
    }

    for (const m of h.models || []) {
      console.log(
        `   model ${String(m.key).padEnd(10)} ${String(m.status).padEnd(14)} ` +
        `${m.modelVersion || m.reason || ''}`,
      );
    }

    // ── cross-language constants
    const specResult = await ml.featureSpec();
    if (!specResult.reachable) {
      fail('/features/spec', specResult.error || `status ${specResult.status}`);
    } else {
      const spec = specResult.data || {};
      check('/features/spec publishes a feature spec version',
        typeof spec.featureSpecVersion === 'string' && spec.featureSpecVersion.length > 0,
        spec.featureSpecVersion);
      check(
        'PEAK_START_HOUR / PEAK_END_HOUR match features.py',
        Array.isArray(spec.peakHours) &&
          spec.peakHours[0] === ml.PEAK_START_HOUR &&
          spec.peakHours[1] === ml.PEAK_END_HOUR,
        `node=[${ml.PEAK_START_HOUR},${ml.PEAK_END_HOUR}] python=[${(spec.peakHours || []).join(',')}]`,
      );
      check(
        'guardrail band matches the band the model is TRAINED on',
        Array.isArray(spec.priceRatioRange) &&
          Math.abs(spec.priceRatioRange[0] - ml.PRICE_RATIO_MIN) < 1e-9 &&
          Math.abs(spec.priceRatioRange[1] - ml.PRICE_RATIO_MAX) < 1e-9,
        `node=[${ml.PRICE_RATIO_MIN},${ml.PRICE_RATIO_MAX}] python=[${(spec.priceRatioRange || []).join(',')}]`,
      );
      check(
        'feature order is frozen and non-empty',
        Array.isArray(spec.featureOrder) && spec.featureOrder.length > 0,
        `${(spec.featureOrder || []).length} features`,
      );
    }

    // ── API-key gate. Raw fetch: mlClient always sends the real key.
    try {
      const body = JSON.stringify({
        sport: 'football', city: 'lahore', basePrice: 2000,
        slotDate: '2026-08-25', startTime: '19:00:00',
      });
      const headers = { 'Content-Type': 'application/json' };

      const noKey = await fetch(`${url}/predict/price`, { method: 'POST', headers, body });
      check('POST /predict/price with NO key -> 401', noKey.status === 401, `got ${noKey.status}`);

      const wrongKey = await fetch(`${url}/predict/price`, {
        method: 'POST',
        headers: { ...headers, 'X-API-Key': 'definitely-not-the-key' },
        body,
      });
      check('POST /predict/price with a WRONG key -> 401', wrongKey.status === 401,
        `got ${wrongKey.status}`);

      const noKeyBody = await noKey.json().catch(() => null);
      check(
        '401 body is the house envelope { success:false, message }',
        noKeyBody && noKeyBody.success === false && typeof noKeyBody.message === 'string',
        JSON.stringify(noKeyBody),
      );

      const publicHealth = await fetch(`${url}/health`);
      check('GET /health is public (no key required)', publicHealth.status === 200,
        `got ${publicHealth.status}`);
    } catch (err) {
      fail('API-key gate', err.message);
    }

    // ── the real call
    ml.resetBreaker();
    const suggestion = await ml.suggestPrice({
      sport: 'football',
      city: 'lahore',
      basePrice: BASE,
      slotDate: '2026-08-25',
      startTime: '19:00:00',
      venueRating: 4.2,
    });

    check(
      'suggestPrice returns the full response shape',
      ['source', 'basePrice', 'suggestedPrice', 'deltaPct', 'confidence', 'demand',
        'reason', 'modelVersion', 'clamped'].every((f) => f in suggestion),
      Object.keys(suggestion).join(', '),
    );
    check(
      'suggested price is inside the guardrail band',
      suggestion.suggestedPrice >= BASE * ml.PRICE_RATIO_MIN &&
        suggestion.suggestedPrice <= BASE * ml.PRICE_RATIO_MAX,
      `${suggestion.suggestedPrice} in [${BASE * ml.PRICE_RATIO_MIN}, ${BASE * ml.PRICE_RATIO_MAX}]`,
    );

    if (suggestion.source === ml.SOURCE_MODEL) {
      console.log(`   -> source='model'  PKR ${suggestion.suggestedPrice} ` +
        `(${suggestion.deltaPct >= 0 ? '+' : ''}${suggestion.deltaPct}%) ` +
        `model=${suggestion.modelVersion}`);
      check('a model response carries a model version', Boolean(suggestion.modelVersion));
    } else {
      // The EXPECTED state in Wave A/B. Not a failure — but it must be honest
      // about being a heuristic, which is the whole point of the `source` field.
      console.log(`   -> source='heuristic'  PKR ${suggestion.suggestedPrice} ` +
        `(${suggestion.deltaPct >= 0 ? '+' : ''}${suggestion.deltaPct}%)`);
      console.log(`      reason: ${suggestion.reason}`);
      check(
        'no model yet -> heuristic, and it does NOT fabricate a confidence',
        suggestion.confidence === null && suggestion.demand === null,
        `confidence=${suggestion.confidence} demand=${suggestion.demand}`,
      );
      check('heuristic response explains itself', typeof suggestion.reason === 'string' &&
        suggestion.reason.length > 0);
    }

    // ── demand forecast: must NOT invent a chart
    ml.resetBreaker();
    const forecast = await ml.forecastDemand({
      sport: 'football', city: 'lahore', basePrice: BASE, hours: 72,
    });
    if (forecast.available) {
      console.log(`   -> forecast source='${forecast.source}' ${forecast.hours} points`);
      check('forecast points are probabilities in [0,1]',
        forecast.points.every((p) => p.bookProbability >= 0 && p.bookProbability <= 1));
    } else {
      check(
        'no model -> forecast is unavailable, NOT a fabricated series',
        forecast.points.length === 0 && forecast.source === ml.SOURCE_UNAVAILABLE,
        forecast.reason,
      );
    }
  }

  // ─── 3. Down path — stood up locally, no human needed ──────────
  section('3. Degradation path (failure conditions created by this script)');

  const realUrl = process.env.ML_SERVICE_URL;
  let hole = null;

  try {
    // 3a. Connection refused — the "uvicorn is not running" case.
    const dead = await closedPort();
    process.env.ML_SERVICE_URL = `http://127.0.0.1:${dead}`;
    ml.resetBreaker();

    const t0 = Date.now();
    const refused = await ml.suggestPrice({
      sport: 'football', city: 'lahore', basePrice: BASE,
      slotDate: '2026-08-25', startTime: '19:00:00',
    });
    const refusedMs = Date.now() - t0;

    check(
      'service down -> still returns a usable suggestion',
      refused.suggestedPrice > 0,
      `PKR ${refused.suggestedPrice} in ${refusedMs}ms`,
    );
    check(
      "service down -> source='heuristic' (never mislabelled as 'model')",
      refused.source === ml.SOURCE_HEURISTIC,
      refused.source,
    );
    check(
      'service down -> peak-hour rule gives base x 1.15 = 2300',
      refused.suggestedPrice === 2300,
      `got ${refused.suggestedPrice}`,
    );
    check(
      'service down -> confidence and demand are null, not invented',
      refused.confidence === null && refused.demand === null,
    );

    const downForecast = await ml.forecastDemand({
      sport: 'football', city: 'lahore', basePrice: BASE,
    });
    check(
      'service down -> demand forecast reports unavailable with no points',
      downForecast.available === false && downForecast.points.length === 0,
      downForecast.reason,
    );

    // 3b. Timeout — the "service is up but hung" case, which a refused connection
    // does not exercise. This is what the 2-second ceiling is actually for.
    hole = await blackHole();
    process.env.ML_SERVICE_URL = `http://127.0.0.1:${hole.port}`;
    ml.resetBreaker();

    const limit = ml.timeoutMs();
    const t1 = Date.now();
    const hung = await ml.suggestPrice({
      sport: 'football', city: 'lahore', basePrice: BASE,
      slotDate: '2026-08-25', startTime: '11:00:00',
    });
    const hungMs = Date.now() - t1;

    check(
      `hung service -> aborted at the ${limit}ms ceiling, not left hanging`,
      hungMs >= limit - 100 && hungMs < limit + 600,
      `returned after ${hungMs}ms (ceiling ${limit}ms)`,
    );
    check('hung service -> heuristic answer, off-peak so base price stands',
      hung.source === ml.SOURCE_HEURISTIC && hung.suggestedPrice === BASE,
      `${hung.source} PKR ${hung.suggestedPrice}`);

    // 3c. Circuit breaker. Without it, every dashboard load pays the full ceiling
    // while the service is off — which in development is most of the time.
    ml.resetBreaker();
    process.env.ML_SERVICE_URL = `http://127.0.0.1:${dead}`;
    for (let i = 0; i < ml.BREAKER_THRESHOLD; i += 1) {
      await ml.suggestPrice({
        sport: 'football', city: 'lahore', basePrice: BASE,
        slotDate: '2026-08-25', startTime: '19:00:00',
      });
    }
    const state = ml.breakerState();
    check(
      `circuit breaker opens after ${ml.BREAKER_THRESHOLD} consecutive failures`,
      state.open === true,
      `failures=${state.failures}, reopens in ${Math.round(state.reopensInMs / 1000)}s`,
    );

    process.env.ML_SERVICE_URL = `http://127.0.0.1:${hole.port}`; // would hang if called
    const t2 = Date.now();
    const shortCircuited = await ml.suggestPrice({
      sport: 'football', city: 'lahore', basePrice: BASE,
      slotDate: '2026-08-25', startTime: '19:00:00',
    });
    const shortMs = Date.now() - t2;
    check(
      'open breaker short-circuits: no network call, answer is instant',
      shortMs < 50 && shortCircuited.source === ml.SOURCE_HEURISTIC,
      `${shortMs}ms (would have hung for ${limit}ms if it had called)`,
    );
  } catch (err) {
    fail('degradation path', err.message);
  } finally {
    if (hole) await hole.close();
    // Restore, so a later require of this module in the same process is unaffected.
    if (realUrl === undefined) delete process.env.ML_SERVICE_URL;
    else process.env.ML_SERVICE_URL = realUrl;
    ml.resetBreaker();
  }

  // ─── Summary ──────────────────────────────────────────────────
  console.log(`\n${'='.repeat(64)}`);
  if (!failures.length) {
    console.log(`${passed}/${passed} checks passed${skipped.length ? `, ${skipped.length} skipped` : ''}.`);
    if (skipped.length) {
      console.log('\nSkipped (ML service was not running — the backend is fine without it):');
      for (const s of skipped) console.log(`   ${s.label}`);
    }
    console.log('');
    return;
  }

  console.log(`${passed} passed, ${failures.length} FAILED${skipped.length ? `, ${skipped.length} skipped` : ''}.\n`);
  for (const f of failures) {
    console.log(`   ${f.label}`);
    if (f.detail) console.log(`      ${f.detail}`);
  }
  console.log('');
  process.exitCode = 1;
}

main().catch((err) => {
  console.error('\nCheck script failed:', err.message, '\n');
  process.exitCode = 1;
});
