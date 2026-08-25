/**
 * mlClient.js — the backend's only door to the Python ML service.
 *
 * WHY THIS FILE IS ALLOWED TO EXIST AT ALL
 * ----------------------------------------
 * SportLynk gained a third process in S.3 (ml-service/, FastAPI + scikit-learn).
 * A third process is a third thing that can be down, and the owner dashboard is
 * not allowed to break because a Python service on port 8000 is not running —
 * which, in development, is most of the time.
 *
 * So this module has one job: make the ml-service OPTIONAL. Every caller gets a
 * usable answer, and every answer says truthfully where it came from. Nothing in
 * here throws. Nothing in here leaks a message from the network layer to a client.
 * That is ER2.6's graceful-degradation requirement expressed as code rather than
 * as a paragraph.
 *
 * WHY `source` IS ON EVERY RESPONSE
 * ---------------------------------
 * `source: 'model'` means a trained scikit-learn model produced this number.
 * `source: 'heuristic'` means the ml-service could not be reached (or has no model
 * yet) and a hard-coded business rule produced it instead.
 *
 * The FYP committee is entitled to ask "is that number from your trained model?"
 * and get a true answer, and an owner setting a real price is entitled to know
 * whether they are looking at a model output or a rule of thumb. That is only
 * possible if the two paths are distinguishable at the point of use, so `source`
 * is not diagnostic metadata — it is part of the contract, and the dashboard is
 * required to render it.
 *
 * The corollary, which is the reason ml-service has no fallback of its own: if the
 * Python service quietly answered `base * 1.15` when it had no model, every
 * response would arrive labelled `source: 'model'` and the label would be a lie.
 * The rule therefore lives HERE, on the far side of a failed call, where its use is
 * unambiguous. Same principle as utils/matchPreview.js's PREVIEW_LABEL.
 *
 * WHY confidence AND demand ARE null ON THE HEURISTIC PATH
 * -------------------------------------------------------
 * A hard-coded 15% uplift has no confidence. Emitting `confidence: 0.5` so the UI
 * always has something to render would be inventing a statistic, and it would be
 * indistinguishable on screen from a real one. Null is the honest value, and the
 * dashboard hides the confidence chip when it is null.
 *
 * WHY `fetch` AND NOT axios
 * -------------------------
 * The wave text said axios. Node here is v22 (`engines: >=20`), where global
 * `fetch` and `AbortSignal.timeout()` are stable and give the exact 2-second
 * timeout the wave asks for. scripts/run_match_flow_check.js already uses `fetch`,
 * so this is house style, and axios would add a dependency and a supply-chain
 * surface for zero functional gain. The contract the wave specified — 2s timeout,
 * ML_* env vars, heuristic fallback, a `source` field — is implemented exactly.
 *
 * GUARDRAILS APPLY TO BOTH PATHS
 * ------------------------------
 * A model must never be able to suggest PKR 47 or PKR 190,000 to a real venue
 * owner. Every suggestion, model or heuristic, is clamped into
 * [base x 0.70, base x 1.50] and rounded to the nearest PKR 50, and `clamped: true`
 * says when the raw suggestion was outside. The band is not arbitrary: it is the
 * same PRICE_RATIO_MIN/MAX the model is TRAINED on, so a suggestion is always
 * interpolation inside the trained range rather than extrapolation beyond it.
 *
 * CIRCUIT BREAKER
 * ---------------
 * Without one, every owner-dashboard load pays the full 2s timeout while the
 * ml-service is off. Three consecutive failures open the breaker for 30s, during
 * which calls go straight to the heuristic. Logging happens on state TRANSITIONS
 * only, in the spirit of utils/globalSettings.js's warnOnce — one line when it
 * opens, one when it recovers, not one per request.
 */

// ─── Configuration ────────────────────────────────────────────
// Read at call time, not at module load, so tests and scripts can set the env
// vars after requiring this module — and so a service started before .env was
// finished picks up the change on restart rather than caching an empty string.

/** Default 2s, exactly as the wave specifies. */
const DEFAULT_TIMEOUT_MS = 2000;

/**
 * Evening peak window, inclusive, in PKT hours.
 *
 * DUPLICATED from ml-service/app/core/features.py, which is the SOURCE OF TRUTH.
 * Node cannot import a Python module, so these two numbers necessarily exist
 * twice. Silent drift between two definitions of "peak" is the obvious future bug:
 * the model would value one set of hours and the fallback a different set, and
 * nobody would notice because both paths keep returning plausible numbers.
 *
 * That is why the ml-service exposes GET /features/spec and why
 * scripts/check_ml_service.js ASSERTS these constants match it. If you change them
 * here, change features.py in the same commit — the check will fail otherwise.
 */
const PEAK_START_HOUR = 18;
const PEAK_END_HOUR = 22;

/**
 * The peak-hour uplift, from the wave spec: peak hour -> base x 1.15.
 *
 * A stated business rule, not a measurement. It is the fallback precisely because
 * it needs no data: the live database has 22 bookings and zero price variation, so
 * there is nothing to fit a better rule to. Wave B's model replaces it as the
 * primary path; this stays as the floor.
 */
const HEURISTIC_PEAK_MULTIPLIER = 1.15;

/**
 * Guardrail band, as a multiple of the venue's own price_per_hour.
 *
 * Same values as PRICE_RATIO_MIN/MAX in features.py — deliberately, so the clamp
 * band and the trained band are identical and a clamped suggestion is never an
 * extrapolation. Also asserted against /features/spec by check_ml_service.js.
 */
const PRICE_RATIO_MIN = 0.70;
const PRICE_RATIO_MAX = 1.50;

/**
 * Suggestions are rounded to the nearest PKR 50.
 *
 * Venue pricing in Pakistan is quoted in round numbers; "PKR 2,347" reads as a
 * machine talking and an owner will not use it. Rounding also stops the UI from
 * implying a precision the model does not have.
 */
const PRICE_ROUND_TO = 50;

/** Consecutive failures that open the breaker, and how long it stays open. */
const BREAKER_THRESHOLD = 3;
const BREAKER_COOLDOWN_MS = 30_000;

/**
 * Demand-level thresholds for the forecast chart's colours.
 *
 * These live HERE, not in the ml-service, on purpose. "Is 0.41 a high-demand hour"
 * is a presentation question, not a modelling one — the model's job ends at
 * P(book) = 0.41, and turning that into a colour is a product decision that must
 * apply identically to whatever path produced the number. Keeping it on the Node
 * side means one threshold table, one chart legend, and no chance of the ML service
 * and the dashboard disagreeing about what "high" means.
 *
 * ANCHORED ON A MEASURED NUMBER, not on taste. `DEMAND_BASE_RATE` is the training
 * set's unconditional booking rate (`baseRate` in reports/pricing_metrics.json,
 * 0.280109 for the current artifact) — i.e. the probability of a slot booking when
 * you know nothing about it. So "high" means clearly above what an average slot
 * does, and "low" means clearly below, which is the comparison an owner is actually
 * making when they look at the chart. A fixed 0.33/0.66 split would be arbitrary,
 * and scaling to each series' own max would be worse: a dead week would render
 * exactly like a busy one and the colour would carry no information at all.
 *
 * Update DEMAND_BASE_RATE when a retrain moves it materially. It is duplicated
 * across the language boundary for the same reason PEAK_START_HOUR is, and
 * scripts/check_ml_service.js is the place to assert it.
 */
const DEMAND_BASE_RATE = 0.28;
const DEMAND_HIGH_MULTIPLE = 1.6; // ~0.45
const DEMAND_LOW_MULTIPLE = 0.55; // ~0.15

/** Demand level values. Exported so no caller writes the string itself. */
const DEMAND_HIGH = 'high';
const DEMAND_MEDIUM = 'medium';
const DEMAND_LOW = 'low';

/**
 * Bucket a probability for the chart. `null` in, `null` out — an unknown demand is
 * not a low demand, and colouring it as one would be a lie told in green.
 */
function demandLevel(probability) {
  // `typeof` first, because Number(null) is 0 and Number('') is 0 — both finite, both
  // would bucket an ABSENT probability as `low` and paint a green bar on the chart
  // for an hour nothing is known about. Only a real number gets a colour.
  if (typeof probability !== "number" || !Number.isFinite(probability)) return null;
  const p = probability;
  if (p >= DEMAND_BASE_RATE * DEMAND_HIGH_MULTIPLE) return DEMAND_HIGH;
  if (p < DEMAND_BASE_RATE * DEMAND_LOW_MULTIPLE) return DEMAND_LOW;
  return DEMAND_MEDIUM;
}

/**
 * PKT wall-clock date + hour -> a fully-qualified ISO instant.
 *
 * Pakistan is UTC+05:00 with no DST, ever, so the offset is a constant rather than
 * a lookup. Emitting the offset explicitly is what lets Flutter call
 * `DateTime.parse()` and get the right instant without doing timezone arithmetic of
 * its own — and doing it here rather than in Dart means the 72 bars on the chart and
 * the slot rows in the booking list are stamped by the same code.
 *
 * Returns null rather than a half-built string when the parts are unusable, so a bad
 * point is droppable instead of silently landing on 1970.
 */
function pktTimestamp(slotDate, hour) {
  const h = Number(hour);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(String(slotDate || '')) || !Number.isInteger(h)) return null;
  if (h < 0 || h > 23) return null;
  return `${slotDate}T${String(h).padStart(2, '0')}:00:00+05:00`;
}

/** Response `source` values. Exported so no caller writes the string itself. */
const SOURCE_MODEL = 'model';
const SOURCE_HEURISTIC = 'heuristic';
/** Demand forecasts have no heuristic — see forecastDemand(). */
const SOURCE_UNAVAILABLE = 'unavailable';

function baseUrl() {
  const raw = (process.env.ML_SERVICE_URL || '').trim();
  return raw.replace(/\/+$/, ''); // tolerate a trailing slash in .env
}

function apiKey() {
  return (process.env.ML_API_KEY || '').trim();
}

function timeoutMs() {
  const raw = Number(process.env.ML_TIMEOUT_MS);
  // Bounded rather than trusted: a typo'd ML_TIMEOUT_MS=200000 would hold an
  // owner-dashboard request open for 200 seconds, which is worse than any
  // degradation this module exists to avoid.
  if (!Number.isFinite(raw) || raw < 100 || raw > 10_000) return DEFAULT_TIMEOUT_MS;
  return Math.round(raw);
}

function isConfigured() {
  return Boolean(baseUrl() && apiKey());
}

// ─── One-shot logging ─────────────────────────────────────────
// Copied in spirit from utils/globalSettings.js: "one log line per bad key, not
// one per request". A misconfigured ML_SERVICE_URL would otherwise print on every
// single dashboard load and bury everything else in the terminal.

const warned = new Set();
function warnOnce(key, message) {
  if (warned.has(key)) return;
  warned.add(key);
  console.warn(`[mlClient] ${message}`);
}

// ─── Circuit breaker ──────────────────────────────────────────

const breaker = { failures: 0, openUntil: 0, wasOpen: false };

function breakerIsOpen() {
  if (breaker.openUntil === 0) return false;
  if (Date.now() < breaker.openUntil) return true;
  // Cooldown elapsed: half-open. The next call is allowed through and decides.
  breaker.openUntil = 0;
  breaker.failures = 0;
  if (breaker.wasOpen) {
    console.log('[mlClient] circuit breaker cooled down — retrying ml-service');
    breaker.wasOpen = false;
  }
  return false;
}

function recordFailure() {
  breaker.failures += 1;
  if (breaker.failures >= BREAKER_THRESHOLD && breaker.openUntil === 0) {
    breaker.openUntil = Date.now() + BREAKER_COOLDOWN_MS;
    breaker.wasOpen = true;
    console.warn(
      `[mlClient] ml-service unreachable ${breaker.failures}x — serving heuristic ` +
      `prices for the next ${BREAKER_COOLDOWN_MS / 1000}s (source='heuristic')`,
    );
  }
}

function recordSuccess() {
  if (breaker.failures > 0 || breaker.openUntil !== 0) {
    console.log('[mlClient] ml-service reachable again — resuming model predictions');
  }
  breaker.failures = 0;
  breaker.openUntil = 0;
  breaker.wasOpen = false;
}

/** Test/script hook: forget the breaker and the warn-once set. */
function resetBreaker() {
  breaker.failures = 0;
  breaker.openUntil = 0;
  breaker.wasOpen = false;
  warned.clear();
}

/** Read-only snapshot, for check_ml_service.js and future health output. */
function breakerState() {
  return {
    open: breaker.openUntil !== 0 && Date.now() < breaker.openUntil,
    failures: breaker.failures,
    reopensInMs: breaker.openUntil ? Math.max(0, breaker.openUntil - Date.now()) : 0,
  };
}

// ─── Transport ────────────────────────────────────────────────

/**
 * One HTTP call to ml-service. Resolves to { ok, status, body, error } — never
 * rejects, so no caller needs a try/catch and none can forget one.
 *
 * The ml-service returns the house envelope { success, message, code } on every
 * error, and its typed prediction bodies bare (their schema is in /docs). Both are
 * handled by unwrapping `body.data` when present, so one reader covers both.
 */
async function call(path, { method = 'POST', payload = null } = {}) {
  const url = baseUrl();
  if (!url || !apiKey()) {
    warnOnce(
      'unconfigured',
      'ML_SERVICE_URL / ML_API_KEY not set — model features will serve heuristics. ' +
      'See backend/.env.example and ml-service/README.md.',
    );
    return { ok: false, status: 0, body: null, error: 'ml-service not configured' };
  }

  const started = Date.now();
  try {
    const res = await fetch(`${url}${path}`, {
      method,
      headers: {
        'Content-Type': 'application/json',
        // The shared secret. NEVER logged, here or anywhere else.
        'X-API-Key': apiKey(),
      },
      body: payload === null ? undefined : JSON.stringify(payload),
      // The wave's 2-second ceiling. AbortSignal.timeout covers DNS, connect and
      // response, which a per-socket timeout option would not.
      signal: AbortSignal.timeout(timeoutMs()),
    });

    let body = null;
    try {
      body = await res.json();
    } catch {
      // A non-JSON body (an HTML error page from something else listening on the
      // port) is a failure, not a crash.
      body = null;
    }

    const elapsed = Date.now() - started;
    if (!res.ok) {
      return {
        ok: false,
        status: res.status,
        body,
        elapsed,
        error: (body && body.message) || `ml-service responded ${res.status}`,
      };
    }
    return { ok: true, status: res.status, body: (body && body.data) || body, elapsed };
  } catch (err) {
    // AbortError (timeout), ECONNREFUSED (not running), ENOTFOUND (bad URL) all
    // land here and are all the same thing to a caller: no model available.
    const elapsed = Date.now() - started;
    const reason = err && err.name === 'TimeoutError'
      ? `timed out after ${timeoutMs()}ms`
      : (err && err.code) || (err && err.name) || 'network error';
    return { ok: false, status: 0, body: null, elapsed, error: reason };
  }
}

// ─── Guardrails ───────────────────────────────────────────────

function roundToStep(value, step) {
  return Math.round(value / step) * step;
}

/**
 * Clamp to the trained band, round to PKR 50, and report whether either changed
 * the number.
 *
 * Order matters: clamp, round, then re-clamp onto the 50-grid. Rounding a boundary
 * value can push it a few rupees back outside the band (base 1,010 -> min 707 ->
 * rounds to 700), and a guardrail that is violated by its own rounding step is not
 * a guardrail. The re-clamp moves to the nearest multiple of 50 that is INSIDE the
 * band.
 */
function applyGuardrails(rawPrice, basePrice) {
  const min = basePrice * PRICE_RATIO_MIN;
  const max = basePrice * PRICE_RATIO_MAX;

  const bounded = Math.min(Math.max(rawPrice, min), max);
  let price = roundToStep(bounded, PRICE_ROUND_TO);

  if (price < min) price = Math.ceil(min / PRICE_ROUND_TO) * PRICE_ROUND_TO;
  if (price > max) price = Math.floor(max / PRICE_ROUND_TO) * PRICE_ROUND_TO;

  // A degenerate base (below PKR 50) would make the band narrower than one
  // rounding step and leave nothing on the grid. Fall back to the base itself
  // rather than returning 0 or 50 — no real venue is priced there, but a seeded
  // test row could be.
  if (!Number.isFinite(price) || price <= 0) price = Math.round(basePrice);

  return {
    price,
    // Rounding alone is not "clamped" — only the band biting is. Otherwise almost
    // every response would carry clamped:true and the flag would mean nothing.
    clamped: rawPrice < min - 0.5 || rawPrice > max + 0.5,
  };
}

function deltaPct(suggested, base) {
  if (!(base > 0)) return 0;
  return Math.round(((suggested - base) / base) * 1000) / 10; // 1 decimal place
}

/** Hour-of-day from '19:00:00' | '19:00' | 19 | Date. NaN when unreadable. */
function hourOf(startTime) {
  if (startTime === null || startTime === undefined) return NaN;
  if (typeof startTime === 'number') return Number.isInteger(startTime) ? startTime : NaN;
  if (startTime instanceof Date) return startTime.getHours();
  const head = String(startTime).trim().split(':')[0];
  const hour = Number.parseInt(head, 10);
  return Number.isInteger(hour) && hour >= 0 && hour <= 23 ? hour : NaN;
}

function isPeakHour(hour) {
  return Number.isInteger(hour) && hour >= PEAK_START_HOUR && hour <= PEAK_END_HOUR;
}

/**
 * The fallback rule, from the wave spec: peak hour -> base x 1.15, else base.
 *
 * Deliberately the simplest defensible rule. Something more elaborate here would
 * be a second, untrained pricing model competing with the real one, and it would
 * be tempting to keep. This is a floor, not a rival.
 *
 * An unreadable start_time yields no uplift rather than a guess — a suggestion
 * built on a misparsed hour is worse than no suggestion, and `reason` says so.
 */
function heuristicPrice(basePrice, startTime) {
  const hour = hourOf(startTime);
  if (!Number.isInteger(hour)) {
    return {
      raw: basePrice,
      reason: 'ML service unavailable; slot time unreadable, so no peak uplift applied',
      factors: [],
    };
  }
  if (isPeakHour(hour)) {
    return {
      raw: basePrice * HEURISTIC_PEAK_MULTIPLIER,
      reason:
        `ML service unavailable; peak-hour rule applied ` +
        `(${PEAK_START_HOUR}:00–${PEAK_END_HOUR}:59, +${Math.round((HEURISTIC_PEAK_MULTIPLIER - 1) * 100)}%)`,
      // One chip, no impact number. The rule KNOWS this is a peak hour — that part
      // is true and worth showing — but it has not measured anything, so `impact`
      // stays null and the UI renders the label without a magnitude. See
      // priceResponse().
      factors: [{ key: 'time_of_day', label: 'Peak hour', direction: 'up', impact: null }],
    };
  }
  return {
    raw: basePrice,
    reason: `ML service unavailable; off-peak rule applied (no change to base price)`,
    factors: [{ key: 'time_of_day', label: 'Off-peak hour', direction: 'down', impact: null }],
  };
}

/**
 * THE one response shape, built here for both paths.
 *
 * A single builder rather than two literals: the UI must not need a branch, and
 * two hand-written object literals would eventually disagree about a field name.
 * `confidence` and `demand` are null unless a model supplied them — see the
 * header comment.
 *
 * `topFactors` carries an `impact` of `null` on the heuristic path. That is the same
 * honesty rule as `confidence: null`: the model path's impacts are MEASURED (a
 * counterfactual re-prediction per factor, see ml-service/app/routers/pricing.py),
 * while the heuristic can only assert "this is a peak hour" from a hardcoded rule.
 * A number there would be indistinguishable on screen from a measured one, so there
 * is no number — the chip renders as a bare label and the card's `source` badge says
 * why.
 */
function priceResponse({
  source,
  basePrice,
  rawPrice,
  confidence = null,
  demand = null,
  reason = null,
  modelVersion = null,
  topFactors = [],
  modelMetrics = null,
  atPolicyCap = false,
  policyMaxRatio = null,
}) {
  const { price, clamped } = applyGuardrails(rawPrice, basePrice);
  return {
    source,
    basePrice: Math.round(basePrice),
    suggestedPrice: price,
    deltaPct: deltaPct(price, basePrice),
    confidence,
    demand,
    demandLevel: demandLevel(demand),
    reason,
    modelVersion,
    clamped,
    topFactors,
    modelMetrics,
    atPolicyCap,
    policyMaxRatio,
  };
}

/**
 * Normalise the ml-service's `topFactors` for the wire.
 *
 * Defensive rather than trusting: this array is rendered directly as chips on an
 * owner's dashboard, so every field is coerced and anything unusable is dropped
 * instead of reaching Flutter as `null` inside a `Text()`. A malformed factor costs
 * a chip; it must never cost the suggestion.
 */
function normaliseFactors(raw) {
  if (!Array.isArray(raw)) return [];
  return raw
    .map((f) => {
      const label = typeof f?.label === 'string' ? f.label.trim() : '';
      if (!label) return null;
      const impact = Number(f?.impact);
      return {
        key: typeof f?.key === 'string' && f.key ? f.key : 'factor',
        label,
        direction: f?.direction === 'down' ? 'down' : 'up',
        impact: Number.isFinite(impact) ? impact : null,
      };
    })
    .filter(Boolean);
}

// ─── Public API ───────────────────────────────────────────────

/**
 * Suggest a price for one slot. ALWAYS resolves to a usable suggestion.
 *
 * ctx: { basePrice, slotDate, startTime, sport, city, venueRating?, venueId?, asOf? }
 *
 * Returns:
 *   { source, basePrice, suggestedPrice, deltaPct, confidence, demand, reason,
 *     modelVersion, clamped }
 *
 * `basePrice` is the only required field; without it there is nothing to suggest a
 * price relative to, and that is a caller bug rather than a degradation, so it
 * returns a zeroed response with a reason instead of guessing a base.
 */
async function suggestPrice(ctx = {}) {
  const basePrice = Number(ctx.basePrice);
  if (!Number.isFinite(basePrice) || basePrice <= 0) {
    warnOnce('no-base-price', 'suggestPrice called without a usable basePrice');
    return {
      source: SOURCE_HEURISTIC,
      basePrice: 0,
      suggestedPrice: 0,
      deltaPct: 0,
      confidence: null,
      demand: null,
      demandLevel: null,
      reason: 'No base price available for this venue',
      modelVersion: null,
      clamped: false,
      topFactors: [],
      modelMetrics: null,
      atPolicyCap: false,
      policyMaxRatio: null,
    };
  }

  const fallback = () => {
    const { raw, reason, factors } = heuristicPrice(basePrice, ctx.startTime);
    return priceResponse({
      source: SOURCE_HEURISTIC,
      basePrice,
      rawPrice: raw,
      reason,
      topFactors: factors,
    });
  };

  if (breakerIsOpen() || !isConfigured()) return fallback();

  const res = await call('/predict/price', {
    payload: {
      sport: ctx.sport,
      city: ctx.city,
      basePrice,
      slotDate: ctx.slotDate,
      startTime: ctx.startTime,
      venueRating: ctx.venueRating ?? null,
      candidatePrice: ctx.candidatePrice ?? null,
      asOf: ctx.asOf ?? null,
      venueId: ctx.venueId ?? null,
    },
  });

  if (!res.ok) {
    recordFailure();
    // Logged once per breaker cycle, not per request. A 503 here is the EXPECTED
    // state between Wave A and Wave B (no model trained yet), so this must not
    // read as an incident.
    warnOnce(
      `price-fail-${res.status}`,
      `ml-service /predict/price -> ${res.status || 'no response'} (${res.error}); ` +
      'using heuristic',
    );
    return fallback();
  }

  recordSuccess();

  const data = res.body || {};
  const raw = Number(data.suggestedPrice);
  if (!Number.isFinite(raw) || raw <= 0) {
    // A 200 with an unusable body. Treated as a failure, because a malformed
    // success is a worse thing to trust than a clean error.
    warnOnce('price-malformed', 'ml-service returned 200 with no usable suggestedPrice');
    recordFailure();
    return fallback();
  }

  const confidence = Number(data.confidence);
  const demand = Number(data.bookProbability);
  const policyMaxRatio = Number(data.policyMaxRatio);
  return priceResponse({
    source: SOURCE_MODEL,
    basePrice,
    rawPrice: raw,
    // Only pass a number through if it really is one. `Number(undefined)` is NaN,
    // and NaN serialises to null in JSON — which would look identical to the
    // honest null of the heuristic path while actually being a bug.
    confidence: Number.isFinite(confidence) ? confidence : null,
    demand: Number.isFinite(demand) ? demand : null,
    reason: data.reason || null,
    modelVersion: data.modelVersion || null,
    topFactors: normaliseFactors(data.topFactors),
    // Passed through whole rather than re-shaped. The dashboard's "Model v1 · AUC
    // 0.76" caption reads from here, so it quotes the served artifact's own test
    // scores; a constant in Dart would drift the first time the model is retrained
    // and nothing would catch it.
    modelMetrics: data.modelMetrics && typeof data.modelMetrics === 'object' ? data.modelMetrics : null,
    atPolicyCap: data.atPolicyCap === true,
    policyMaxRatio: Number.isFinite(policyMaxRatio) ? policyMaxRatio : null,
  });
}

/**
 * 72-hour demand forecast for one venue.
 *
 * ctx: { basePrice, sport, city, venueRating?, hours?, openFrom?, openTo?, venueId? }
 *
 * Returns { source, available, hours, points: [{ts, slotDate, hour, bookProbability,
 *           level}], modelMetrics, reason, modelVersion }
 *
 * `ts` is a fully-qualified PKT instant and `level` is the chart's colour bucket —
 * both computed here so the 72 bars are stamped and bucketed by one piece of code
 * rather than by Dart. See pktTimestamp() and demandLevel().
 *
 * THERE IS NO HEURISTIC FALLBACK HERE, and that is the important part of this
 * function. A peak-hour price rule is a defensible business rule that venue owners
 * already use. A 72-point probability curve is not: any non-model version of it
 * would be numbers this file invented, drawn as a chart, indistinguishable on
 * screen from a real forecast. So when the ml-service is unavailable this returns
 * `available: false` and an empty series, and the dashboard shows "forecast
 * unavailable" instead of a fabricated line.
 *
 * That asymmetry between suggestPrice and forecastDemand is deliberate, and it is
 * the same judgement as `confidence: null` on the heuristic price path.
 */
async function forecastDemand(ctx = {}) {
  const basePrice = Number(ctx.basePrice);
  const unavailable = (reason) => ({
    source: SOURCE_UNAVAILABLE,
    available: false,
    hours: 0,
    points: [],
    modelMetrics: null,
    reason,
    modelVersion: null,
  });

  if (!Number.isFinite(basePrice) || basePrice <= 0) {
    return unavailable('No base price available for this venue');
  }
  if (breakerIsOpen() || !isConfigured()) {
    return unavailable('Demand forecast unavailable — ML service is not reachable');
  }

  const res = await call('/predict/demand', {
    payload: {
      sport: ctx.sport,
      city: ctx.city,
      basePrice,
      venueRating: ctx.venueRating ?? null,
      hours: ctx.hours ?? 72,
      openFrom: ctx.openFrom ?? null,
      openTo: ctx.openTo ?? null,
      venueId: ctx.venueId ?? null,
    },
  });

  if (!res.ok) {
    recordFailure();
    warnOnce(
      `demand-fail-${res.status}`,
      `ml-service /predict/demand -> ${res.status || 'no response'} (${res.error})`,
    );
    return unavailable('Demand forecast unavailable — ML service is not reachable');
  }

  recordSuccess();

  const data = res.body || {};
  const points = Array.isArray(data.points) ? data.points : [];
  if (!points.length) {
    return unavailable('Demand forecast unavailable — model returned no points');
  }

  // A point that cannot be stamped or has no readable probability is DROPPED, not
  // passed through with a null. fl_chart plots a bar per entry, and a bar with no
  // height at an unknown time is a hole in the chart that reads as zero demand.
  const shaped = points
    .map((p) => {
      const probability = Number(p.bookProbability);
      const ts = pktTimestamp(p.slotDate, p.hour);
      if (!ts || !Number.isFinite(probability)) return null;
      return {
        ts,
        slotDate: p.slotDate,
        hour: Number(p.hour),
        bookProbability: probability,
        level: demandLevel(probability),
      };
    })
    .filter(Boolean);

  if (!shaped.length) {
    return unavailable('Demand forecast unavailable — model returned no usable points');
  }

  return {
    source: SOURCE_MODEL,
    available: true,
    // The COUNT OF POINTS SERVED, not the hours requested. They differ whenever the
    // venue's operating window drops hours (72 asked, 48 served for an 08:00–23:00
    // venue), and the chart's axis must describe what it is drawing.
    hours: shaped.length,
    points: shaped,
    modelMetrics: data.modelMetrics && typeof data.modelMetrics === 'object' ? data.modelMetrics : null,
    reason: null,
    modelVersion: data.modelVersion || null,
  };
}

/**
 * ml-service /health, for diagnostics and check_ml_service.js.
 *
 * Deliberately does NOT consult the circuit breaker: "is the service up" must stay
 * answerable while the breaker is open, otherwise the breaker hides the very thing
 * you opened the health check to find out. It does not record failures either, for
 * the same reason — a diagnostic probe should not be able to trip the production
 * path.
 */
async function health() {
  if (!isConfigured()) {
    return { reachable: false, error: 'ML_SERVICE_URL / ML_API_KEY not set', data: null };
  }
  const res = await call('/health', { method: 'GET' });
  if (!res.ok) {
    return { reachable: false, error: res.error, status: res.status, data: null };
  }
  return { reachable: true, error: null, status: res.status, data: res.body, elapsed: res.elapsed };
}

/**
 * The feature contract as the PYTHON side defines it.
 *
 * Exists so check_ml_service.js can assert that PEAK_START_HOUR, PEAK_END_HOUR and
 * the price-ratio band in this file still match features.py. Those numbers are
 * necessarily duplicated across the language boundary; this turns "keep them in
 * sync" from a comment into a test that fails.
 */
async function featureSpec() {
  const res = await call('/features/spec', { method: 'GET' });
  if (!res.ok) return { reachable: false, error: res.error, status: res.status, data: null };
  return { reachable: true, error: null, status: res.status, data: res.body };
}

module.exports = {
  // public API
  suggestPrice,
  forecastDemand,
  health,
  featureSpec,

  // constants — exported so routes, scripts and tests reference the value rather
  // than re-typing a string or a number that could drift
  SOURCE_MODEL,
  SOURCE_HEURISTIC,
  SOURCE_UNAVAILABLE,
  DEMAND_HIGH,
  DEMAND_MEDIUM,
  DEMAND_LOW,
  DEMAND_BASE_RATE,
  DEMAND_HIGH_MULTIPLE,
  DEMAND_LOW_MULTIPLE,
  PEAK_START_HOUR,
  PEAK_END_HOUR,
  HEURISTIC_PEAK_MULTIPLIER,
  PRICE_RATIO_MIN,
  PRICE_RATIO_MAX,
  PRICE_ROUND_TO,
  DEFAULT_TIMEOUT_MS,
  BREAKER_THRESHOLD,
  BREAKER_COOLDOWN_MS,

  // internals, exported for the verification script
  isConfigured,
  timeoutMs,
  applyGuardrails,
  heuristicPrice,
  isPeakHour,
  hourOf,
  demandLevel,
  pktTimestamp,
  normaliseFactors,
  resetBreaker,
  breakerState,
};
