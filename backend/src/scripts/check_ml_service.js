/**
 * check_ml_service.js — prove the ML integration works, and that it degrades.
 *
 * Why this exists
 * The ml-service/ tier and its Node client (src/services/mlClient.js) were built
 * before any route called them. Without a harness that code would ship having
 * never been executed — and the part that matters most, the degradation path, is
 * exactly the part nobody exercises by accident, because it only runs when
 * something is broken.
 *
 * So this script is the acceptance test for that tier, in the family of
 * verify_schema.js and run_match_flow_check.js: read-only, exits 0 or 1, and safe
 * to run any time.
 *
 * What it proves
 *   1. Guardrails. The clamp band, the PKR 50 rounding and the peak-hour rule are
 *      pure functions, so they are checked with no service and no network. A model
 *      must never be able to suggest PKR 47 or PKR 190,000 to a real venue owner.
 *   2. Cross-language constants. PEAK_START_HOUR, PEAK_END_HOUR and the price-ratio
 *      band exist twice — in mlClient.js and in ml-service/app/core/features.py —
 *      because Node cannot import Python. This asserts the two copies agree, by
 *      reading GET /features/spec. That turns "keep these in sync" from a comment
 *      into a check that fails.
 *   3. The up path. /health answers, reports its model inventory truthfully, and
 *      /predict/price either returns a model suggestion or an honest 503
 *      model_not_loaded. Both are passes; the script says which it saw.
 *   4. The API-KEY gate. A request with no key and a request with a wrong key both
 *      get 401 with the same body. Verified with raw fetch, because mlClient always
 *      sends the real key and therefore cannot test this itself.
 *   5. The down path — without asking anyone to stop UVICORN. The script stands up
 *      its own failure conditions: a closed port (connection refused) and a socket
 *      that accepts and never replies (timeout). It then checks that suggestPrice
 *      still returns a usable heuristic, that the 2-second ceiling is honoured, and
 *      that the circuit breaker opens and short-circuits the next call.
 *
 *      Self-contained on purpose. A test that needs a human to kill a process in
 *      another terminal is a test that gets skipped, and this is the path that
 *      protects the owner dashboard in production.
 *   6. The owner's screen cannot lie. Every figure the dashboard card
 *      and the 72-hour chart display is asserted here to be measured rather than
 *      asserted: the confidence is inside its derived clamp, the "why" chips carry
 *      real counterfactual impacts strongest-first, the caption's AUC comes from the
 *      served artifact, the demand palette's thresholds are checked against the
 *      trained base rate in ml-service/reports/pricing_metrics.json, and every
 *      forecast bar carries the colour its own probability earns. It also proves the
 *      cache serves a degraded answer without storing it — the difference between a
 *      30-second outage and a 60-minute one.
 *
 * What it does not do
 * No database connection, no writes, no schema. Nothing here can affect a booking.
 *
 * USAGE
 *   node src/scripts/check_ml_service.js
 *   node src/scripts/check_ml_service.js --verbose      # show every passing check
 *
 * Start the ML service first for the full run:
 *   cd ..\ml-service ; .\run_dev.ps1
 *
 * With the service down the script still passes: sections 1, 5 and the degradation
 * checks all run, and the up-path sections report skip with the reason. That is
 * intentional — "the backend is fine without the ML service" is a result, not a
 * gap.
 */

const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '..', '..', '.env') });

const crypto = require('crypto');
const net = require('net');
const fs = require('fs');

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

  // 0. Configuration
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

  // 1. Guardrails — pure, no network
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

  // Dashboard pure functions: the demand palette and the PKT stamp
  {
    // These three shape every bar on the owner's forecast chart, so they are checked
    // without the service: a colour that is wrong here is wrong on the demo laptop.
    check(
      `demand thresholds bucket around the trained base rate (${ml.DEMAND_BASE_RATE})`,
      ml.demandLevel(0.9) === ml.DEMAND_HIGH &&
        ml.demandLevel(ml.DEMAND_BASE_RATE) === ml.DEMAND_MEDIUM &&
        ml.demandLevel(0.01) === ml.DEMAND_LOW,
      `high>=${(ml.DEMAND_BASE_RATE * ml.DEMAND_HIGH_MULTIPLE).toFixed(3)}, ` +
        `low<${(ml.DEMAND_BASE_RATE * ml.DEMAND_LOW_MULTIPLE).toFixed(3)}`,
    );
    check(
      'the level boundaries are inclusive-low / exclusive-high, with no gap',
      ml.demandLevel(ml.DEMAND_BASE_RATE * ml.DEMAND_HIGH_MULTIPLE) === ml.DEMAND_HIGH &&
        ml.demandLevel(ml.DEMAND_BASE_RATE * ml.DEMAND_LOW_MULTIPLE) === ml.DEMAND_MEDIUM,
    );
    check(
      // The bug this exists to prevent: Number(null) === 0, which is finite, so a
      // naive guard buckets an absent probability as `low` and paints a bar on the
      // chart for an hour nothing is known about.
      'an absent or non-numeric probability gets NO colour, not the low colour',
      [null, undefined, '', '0.5', NaN, {}].every((v) => ml.demandLevel(v) === null),
    );
    check(
      'pktTimestamp stamps +05:00 and rejects anything it cannot stamp honestly',
      ml.pktTimestamp('2026-08-25', 19) === '2026-08-25T19:00:00+05:00' &&
        ml.pktTimestamp('2026-08-25', 0) === '2026-08-25T00:00:00+05:00' &&
        ml.pktTimestamp('25-08-2026', 19) === null &&
        ml.pktTimestamp('2026-08-25', 24) === null &&
        ml.pktTimestamp('2026-08-25', '19:00') === null,
    );
    const factors = ml.normaliseFactors([
      { key: 'is_peak', label: ' Peak hour ', direction: 'up', impact: 0.52 },
      { key: 'x', label: '', direction: 'up', impact: 0.1 },   // no label -> dropped
      { label: 'Weekend', direction: 'sideways', impact: 'nope' },
      'not an object',
    ]);
    check(
      'normaliseFactors keeps usable chips, drops the unusable, never throws',
      factors.length === 2 &&
        factors[0].label === 'Peak hour' &&
        factors[1].direction === 'up' &&
        factors[1].impact === null,
      JSON.stringify(factors),
    );
    check('normaliseFactors survives a non-array', ml.normaliseFactors(null).length === 0);
  }

  // The thresholds must be anchored on measured data
  {
    // The demand palette's whole claim is that "high" means high relative to what
    // this venue population books, not relative to a number someone liked.
    // That claim is only true while DEMAND_BASE_RATE tracks the base rate the model
    // was trained against, so it is asserted against the artifact's own metrics.
    const metricsPath = path.join(
      __dirname, '..', '..', '..', 'ml-service', 'reports', 'pricing_metrics.json',
    );
    if (!fs.existsSync(metricsPath)) {
      skip('DEMAND_BASE_RATE matches the trained base rate', 'pricing_metrics.json not found');
    } else {
      let measured = null;
      try {
        const raw = JSON.parse(fs.readFileSync(metricsPath, 'utf8'));
        // `metrics.test.baseRate` is the held-out split's unconditional booking rate —
        // the same population the served model is scored against. Deliberately not
        // `dataset.bookedRate`, which is the whole file including the training half.
        measured = Number(raw?.metrics?.test?.baseRate);
      } catch {
        measured = null;
      }
      if (!Number.isFinite(measured)) {
        skip('DEMAND_BASE_RATE matches the trained base rate', 'no metrics.test.baseRate found');
      } else {
        check(
          'DEMAND_BASE_RATE is the trained base rate, not a taste-based constant',
          Math.abs(ml.DEMAND_BASE_RATE - measured) <= 0.02,
          `constant ${ml.DEMAND_BASE_RATE} vs measured ${measured.toFixed(6)}`,
        );
      }
    }
  }

  // The owner-route cache
  {
    // owner.js keys its caches on user-supplied date/hour values, so the bound is
    // what stops a scripted client turning the cache into a memory leak.
    const { TtlCache, ONE_HOUR_MS } = require('../utils/ttlCache');
    const c = new TtlCache({ name: 'probe', ttlMs: ONE_HOUR_MS, maxEntries: 3 });
    let loads = 0;
    const load = async () => { loads += 1; return { v: loads }; };

    const [a, b] = await Promise.all([c.getOrSet('k', load), c.getOrSet('k', load)]);
    check(
      'concurrent callers on a cold key share ONE load, not one each',
      loads === 1 && a === b,
      `loads=${loads}`,
    );
    check('a second call is served from memory', (await c.getOrSet('k', load)).v === 1 && loads === 1);

    for (const k of ['a', 'b', 'c', 'd']) await c.getOrSet(k, load);
    check(
      `the cache is bounded (maxEntries respected, oldest evicted)`,
      c.stats().size === 3,
      JSON.stringify(c.stats()),
    );

    let degradedLoads = 0;
    const degraded = new TtlCache({ name: 'degraded', ttlMs: ONE_HOUR_MS });
    const opts = { shouldCache: (v) => v?.source === ml.SOURCE_MODEL };
    for (let i = 0; i < 2; i += 1) {
      await degraded.getOrSet('venue:price', async () => {
        degradedLoads += 1;
        return { source: ml.SOURCE_HEURISTIC };
      }, opts);
    }
    check(
      // Caching a degraded answer would keep the dashboard degraded for an hour after
      // the ml-service came back, which is worse than the outage it papers over.
      'a degraded (heuristic) answer is served but NOT cached',
      degradedLoads === 2 && degraded.stats().size === 0,
      `loads=${degradedLoads} size=${degraded.stats().size}`,
    );

    c.set('v1:price:a', 1);
    c.set('v1:price:b', 2);
    c.set('v2:price:a', 3);
    const dropped = c.invalidatePrefix('v1:price:');
    check(
      'applying a price can drop every cached suggestion for that venue by prefix',
      dropped === 2 && c.get('v2:price:a') === 3 && c.get('v1:price:a') === undefined,
      `dropped=${dropped}`,
    );
  }

  // 2. Up path
  section('2. ML service up path');

  ml.resetBreaker();
  const healthResult = await ml.health();

  if (!healthResult.reachable) {
    skip('/health', healthResult.error || 'not reachable');
    skip('/features/spec cross-language constant check', 'ml-service not reachable');
    skip('/predict/price', 'ml-service not reachable');
    skip('/sentiment/spec cross-language label check', 'ml-service not reachable');
    skip('/predict/sentiment (sentiment up path)', 'ml-service not reachable');
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
        'demandLevel', 'reason', 'modelVersion', 'clamped', 'topFactors', 'modelMetrics',
        'atPolicyCap', 'policyMaxRatio'].every((f) => f in suggestion),
      Object.keys(suggestion).join(', '),
    );
    check(
      'suggested price is inside the guardrail band',
      suggestion.suggestedPrice >= BASE * ml.PRICE_RATIO_MIN &&
        suggestion.suggestedPrice <= BASE * ml.PRICE_RATIO_MAX,
      `${suggestion.suggestedPrice} in [${BASE * ml.PRICE_RATIO_MIN}, ${BASE * ml.PRICE_RATIO_MAX}]`,
    );
    check(
      // The bar and the chips are drawn from these; a shape drift here shows up on the
      // owner's dashboard as a card that silently loses half its content.
      'topFactors is always an array and demandLevel always agrees with demand',
      Array.isArray(suggestion.topFactors) &&
        suggestion.demandLevel === ml.demandLevel(suggestion.demand),
      `${suggestion.topFactors.length} factors, level=${suggestion.demandLevel}`,
    );

    if (suggestion.source === ml.SOURCE_MODEL) {
      console.log(`   -> source='model'  PKR ${suggestion.suggestedPrice} ` +
        `(${suggestion.deltaPct >= 0 ? '+' : ''}${suggestion.deltaPct}%) ` +
        `model=${suggestion.modelVersion}`);
      check('a model response carries a model version', Boolean(suggestion.modelVersion));

      // The numbers the card puts on screen
      check(
        // Confidence is derived (identification x boundary penalty x attainment) and
        // clamped to [0.05, 0.95]. A hard 0 or 1 would mean the derivation was skipped.
        'confidence is a derived probability inside its clamp, never 0 or 1',
        typeof suggestion.confidence === 'number' &&
          suggestion.confidence >= 0.05 && suggestion.confidence <= 0.95,
        `confidence=${suggestion.confidence}`,
      );
      check(
        'expected occupancy is a probability, and the card can render it',
        typeof suggestion.demand === 'number' &&
          suggestion.demand >= 0 && suggestion.demand <= 1,
        `demand=${suggestion.demand}`,
      );
      check(
        // 19:00 is inside the peak window on a Tuesday, so the model must have something
        // to say about why. Zero chips here means the counterfactual probe silently
        // failed and the card would render an unexplained price.
        'a peak-hour suggestion comes with at least one measured "why" chip',
        suggestion.topFactors.length > 0 &&
          suggestion.topFactors.every((f) =>
            typeof f.label === 'string' && f.label.length > 0 &&
            (f.direction === 'up' || f.direction === 'down') &&
            typeof f.impact === 'number' && f.impact >= 0 && f.impact <= 1),
        suggestion.topFactors.map((f) => `${f.label} ${f.direction}${f.impact.toFixed(3)}`).join(', '),
      );
      check(
        'factors arrive strongest-first, so the card can trust the order',
        suggestion.topFactors.every((f, i, a) => i === 0 || a[i - 1].impact >= f.impact),
      );
      check(
        // This is the caption under the card. If it is absent the caption disappears;
        // if it is wrong the demo claims a score the artifact never measured.
        'modelMetrics carries the served artifact\'s own measured scores',
        suggestion.modelMetrics &&
          typeof suggestion.modelMetrics.rocAuc === 'number' &&
          suggestion.modelMetrics.rocAuc > 0.5 &&
          typeof suggestion.modelMetrics.brier === 'number',
        suggestion.modelMetrics
          ? `AUC ${suggestion.modelMetrics.rocAuc} ceiling ${suggestion.modelMetrics.rocAucCeiling} ` +
            `brier ${suggestion.modelMetrics.brier} rows ${suggestion.modelMetrics.testRows}`
          : 'absent',
      );
      check(
        'the policy cap is reported as a boolean plus the ratio it capped at',
        typeof suggestion.atPolicyCap === 'boolean' &&
          (suggestion.policyMaxRatio === null || suggestion.policyMaxRatio > 1),
        `atPolicyCap=${suggestion.atPolicyCap} ratio=${suggestion.policyMaxRatio}`,
      );
      if (suggestion.atPolicyCap) {
        check(
          // ELASTICITY_PEAK < 1 makes expected revenue rise monotonically to the cap on
          // peak slots, so this fires legitimately and often — but then the reason must
          // say so, or the owner sees a price that stopped for no stated cause.
          'a capped suggestion explains that it was the cap that stopped it',
          /cap/i.test(String(suggestion.reason)),
          suggestion.reason,
        );
      }
    } else {
      // The EXPECTED state before a model is trained. Not a failure — but it must be honest
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
      check(
        // The heuristic gets one chip, and it must be honest about being a rule: an
        // `impact` of 0 would present a rule as a measurement of no effect, which is
        // the same dishonesty as the old hardcoded "92% CONFIDENCE" in the other
        // direction. The card renders the label without a number when impact is null.
        'the heuristic\'s chip is a rule, and says so by carrying no impact',
        suggestion.topFactors.length === 1 && suggestion.topFactors[0].impact === null,
        JSON.stringify(suggestion.topFactors),
      );
      check(
        'a heuristic never carries model metrics or a policy cap',
        suggestion.modelMetrics === null && suggestion.atPolicyCap === false,
        `metrics=${suggestion.modelMetrics} cap=${suggestion.atPolicyCap}`,
      );
    }

    // ── demand forecast: must not invent a chart
    ml.resetBreaker();
    const forecast = await ml.forecastDemand({
      sport: 'football', city: 'lahore', basePrice: BASE, hours: 72,
    });
    if (forecast.available) {
      console.log(`   -> forecast source='${forecast.source}' ${forecast.hours} points`);
      check('forecast points are probabilities in [0,1]',
        forecast.points.every((p) => p.bookProbability >= 0 && p.bookProbability <= 1));
      check(
        // `hours` is the count served, not the count asked for. Any point that could
        // not be stamped or read is dropped rather than drawn as a zero-height bar at
        // an unknown time, so these two must always agree.
        'the reported hour count is the number of points actually served',
        forecast.hours === forecast.points.length,
        `hours=${forecast.hours} points=${forecast.points.length}`,
      );
      check(
        'every point is stamped in PKT (+05:00) — the chart never converts a timezone',
        forecast.points.every((p) =>
          /^\d{4}-\d{2}-\d{2}T\d{2}:00:00\+05:00$/.test(String(p.ts)) &&
          p.ts === ml.pktTimestamp(p.slotDate, p.hour)),
        forecast.points[0] ? forecast.points[0].ts : 'no points',
      );
      check(
        'every bar has a colour, and it is the one its own probability earns',
        forecast.points.every((p) => p.level !== null && p.level === ml.demandLevel(p.bookProbability)),
      );
      check(
        // The forecast holds price_ratio at 1.0 and walks the clock, so a flat series
        // would mean the time features are not reaching the model at all.
        'the forecast actually varies by hour rather than repeating one number',
        new Set(forecast.points.map((p) => p.bookProbability.toFixed(4))).size > 3,
        `${new Set(forecast.points.map((p) => p.bookProbability.toFixed(4))).size} distinct values`,
      );
      const levels = forecast.points.reduce((acc, p) => {
        acc[p.level] = (acc[p.level] || 0) + 1;
        return acc;
      }, {});
      console.log(`      demand mix: ${JSON.stringify(levels)}`);
    } else {
      check(
        'no model -> forecast is unavailable, NOT a fabricated series',
        forecast.points.length === 0 && forecast.source === ml.SOURCE_UNAVAILABLE,
        forecast.reason,
      );
    }

    // Sentiment: the cross-language label set, then the up path
    // The mirror of the /features/spec check above. SENTIMENT_LABELS in mlClient.js is
    // a hand-copy of text_norm.LABELS that Node cannot import, and a drift silently
    // mislabels every stored review, so the two are asserted equal over the wire.
    const sentSpec = await ml.sentimentSpec();
    if (!sentSpec.reachable) {
      fail('/sentiment/spec', sentSpec.error || `status ${sentSpec.status}`);
    } else {
      const s = sentSpec.data || {};
      check(
        '/sentiment/spec publishes a normaliser spec version',
        typeof s.normSpecVersion === 'string' && s.normSpecVersion.length > 0,
        s.normSpecVersion,
      );
      check(
        'sentiment label set matches text_norm.LABELS across the language boundary',
        Array.isArray(s.labels) &&
          s.labels.length === ml.SENTIMENT_LABELS.length &&
          s.labels.every((l, i) => l === ml.SENTIMENT_LABELS[i]),
        `node=[${ml.SENTIMENT_LABELS.join(',')}] python=[${(s.labels || []).join(',')}]`,
      );
    }

    // The up path. Mirrors the price section: with a model loaded this asserts the
    // exact shape routes/reviews.js stores; with no model it must degrade honestly
    // (available:false, source:'unavailable') and invent nothing. Both are passes.
    ml.resetBreaker();
    const sentiment = await ml.analyzeSentiment(
      'great venue, well maintained pitch and friendly staff',
      { reviewId: 'check-ml-service' },
    );
    check(
      'analyzeSentiment always returns the full result shape',
      ['source', 'available', 'clientError', 'reviewId', 'label', 'score', 'confidence',
        'flagged', 'toxic', 'strongNegative', 'reviewReasons', 'outOfDistribution',
        'modelVersion', 'reason'].every((f) => f in sentiment),
      Object.keys(sentiment).join(', '),
    );

    if (sentiment.available) {
      console.log(`   -> sentiment source='model'  label=${sentiment.label} ` +
        `score=${sentiment.score >= 0 ? '+' : ''}${sentiment.score} model=${sentiment.modelVersion}`);
      check('a scored review is source=model, never a rule', sentiment.source === ml.SOURCE_MODEL);
      check(
        'label is one of the three canonical classes',
        ml.SENTIMENT_LABELS.includes(sentiment.label),
        sentiment.label,
      );
      check(
        // Stored in reviews.sentiment_score and averaged into trust_sentiment, so a
        // value outside [-1,1] would corrupt the trust ledger, not just one row.
        'score is signed polarity in [-1, 1]',
        typeof sentiment.score === 'number' && sentiment.score >= -1 && sentiment.score <= 1,
        `score=${sentiment.score}`,
      );
      check(
        'confidence is a probability in [0, 1]',
        typeof sentiment.confidence === 'number' &&
          sentiment.confidence >= 0 && sentiment.confidence <= 1,
        `confidence=${sentiment.confidence}`,
      );
      check(
        // `flagged` is written verbatim to reviews.flagged; the finer signals ride a
        // moderation UI that switches on them, so all three must be real booleans.
        'the moderation flags are all booleans',
        typeof sentiment.flagged === 'boolean' &&
          typeof sentiment.toxic === 'boolean' &&
          typeof sentiment.strongNegative === 'boolean',
        `flagged=${sentiment.flagged} toxic=${sentiment.toxic} strongNeg=${sentiment.strongNegative}`,
      );
      check('a scored review carries a model version', Boolean(sentiment.modelVersion),
        sentiment.modelVersion);
      check(
        'a clean, positive review is not flagged for moderation',
        sentiment.flagged === false,
        sentiment.reviewReasons.join(',') || 'no reasons',
      );

      // The deliberate difference from the price path: unusable text is a 422, and it
      // must come back available:false + clientError:true without opening the breaker —
      // bad input is not an outage. sentimentBackfillJob.js relies on exactly this to
      // mark a row 'unscoreable' rather than deferring the whole sweep.
      ml.resetBreaker();
      const junk = await ml.analyzeSentiment('...', { reviewId: 'check-junk' });
      check(
        'unscoreable text -> unavailable + clientError, and does NOT open the breaker',
        junk.available === false && junk.clientError === true && !ml.breakerState().open,
        `available=${junk.available} clientError=${junk.clientError} breakerOpen=${ml.breakerState().open}`,
      );
    } else {
      // The untrained state, or a model that failed to load. Honest degradation, not a
      // failure — the same posture the price path takes when no artifact is present.
      console.log(`   -> sentiment source='${sentiment.source}' (no model): ${sentiment.reason}`);
      check(
        'no model -> sentiment is unavailable, and invents NO label or score',
        sentiment.source === ml.SOURCE_UNAVAILABLE &&
          sentiment.label === null && sentiment.score === null,
        `source=${sentiment.source} label=${sentiment.label} score=${sentiment.score}`,
      );
    }
  }

  // 3. Down path — stood up locally, no human needed
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
    // does not exercise. This is what the 2-second ceiling is for.
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

  // Summary
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
