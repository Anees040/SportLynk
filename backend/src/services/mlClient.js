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
/** Demand forecasts and sentiment have no heuristic — see forecastDemand()/analyzeSentiment(). */
const SOURCE_UNAVAILABLE = 'unavailable';

/**
 * The three sentiment classes, in the ml-service's canonical order (text_norm.LABELS,
 * alphabetical). Exported so routes, the backfill job and the verification script
 * validate a label against ONE list rather than three hand-typed string literals that
 * could drift from what `/sentiment/spec` publishes.
 */
const SENTIMENT_LABELS = ['negative', 'neutral', 'positive'];

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

// ─── Sentiment (model #2) ─────────────────────────────────────
//
// Same no-heuristic posture as forecastDemand, and for the same reason: there is
// no defensible rule-of-thumb that turns "worst turf in the city" into a polarity
// score, so when the model is unreachable this returns source:'unavailable' with a
// null label rather than inventing one. A caller stores NULL, which is the truthful
// "not scored yet" state — reviews.sentiment_label is nullable precisely for this.
//
// ONE contract difference from the price/demand paths, and it is deliberate: a 4xx
// does NOT count against the circuit breaker. The sentiment endpoint answers 422
// `unusable_text` for a review that normalises to no evidence (punctuation, numbers,
// separators only). That is a fact about ONE review, not a service outage — the very
// next review may score cleanly. Tripping the breaker on it would let a handful of
// "..." reviews open the circuit and stop scoring for everyone. So only 5xx /
// network / timeout — genuine service failures — call recordFailure(); a 4xx returns
// unavailable with `clientError:true` and leaves the breaker untouched, which is the
// signal the backfill job uses to mark that row terminally unscoreable.

/**
 * Build the public sentiment shape from the ml-service's bare response body.
 *
 * Defensive like normaliseFactors: `reviews.sentiment_label` has a NOT-in-set value
 * stored nowhere downstream can interpret it, so a body whose label is not one of the
 * three canonical classes, or whose score is not a finite number in [-1,1], is treated
 * as no result rather than written through. In practice the Python response_model
 * guarantees both, so this is a belt-and-braces guard, not an expected path.
 */
function sentimentResult(data, reviewId) {
  const label = SENTIMENT_LABELS.includes(data.label) ? data.label : null;
  const score = Number(data.score);
  const confidence = Number(data.confidence);
  if (label === null || !Number.isFinite(score) || score < -1 || score > 1) return null;
  const tox = data.toxicity && typeof data.toxicity === 'object' ? data.toxicity : {};
  return {
    source: SOURCE_MODEL,
    available: true,
    clientError: false,
    reviewId: data.reviewId ?? reviewId ?? null,
    label,
    score,
    confidence: Number.isFinite(confidence) ? confidence : null,
    // needsReview is the moderation union (abuse OR strong-negative); it maps 1:1 to
    // reviews.flagged. The finer-grained signals ride along for logging and for a
    // moderation UI, but the route only needs `flagged`.
    flagged: data.needsReview === true,
    toxic: tox.flagged === true,
    strongNegative: data.strongNegative === true,
    reviewReasons: Array.isArray(data.reviewReasons) ? data.reviewReasons : [],
    outOfDistribution: data.outOfDistribution === true,
    modelVersion: data.modelVersion || null,
    reason: null,
  };
}

/** The unavailable shape — every field the success shape has, emptied. */
function sentimentUnavailable(reason, clientError = false) {
  return {
    source: SOURCE_UNAVAILABLE,
    available: false,
    clientError,
    reviewId: null,
    label: null,
    score: null,
    confidence: null,
    flagged: false,
    toxic: false,
    strongNegative: false,
    reviewReasons: [],
    outOfDistribution: false,
    modelVersion: null,
    reason,
  };
}

/**
 * Score one review's text. ALWAYS resolves (never throws), like every function here.
 *
 * Returns:
 *   { source, available, clientError, reviewId, label, score, confidence, flagged,
 *     toxic, strongNegative, reviewReasons, outOfDistribution, modelVersion, reason }
 *
 * `available:true` → `label`/`score` are real and safe to store. `available:false` →
 * store NULLs. `clientError:true` on a false result means the text itself is
 * unscoreable (a 422), so a retry with the same text will fail identically — the
 * caller should stop retrying it, not back off and try later.
 */
async function analyzeSentiment(text, { reviewId = null } = {}) {
  const body = typeof text === 'string' ? text.trim() : '';
  if (!body) {
    // No text is not a service failure and not worth a network round-trip. It is,
    // however, terminally unscoreable — flagged clientError so the backfill marks an
    // empty-string comment 'unscoreable' instead of re-selecting it every sweep.
    return sentimentUnavailable('No review text to analyse', true);
  }

  if (breakerIsOpen() || !isConfigured()) {
    return sentimentUnavailable('Sentiment analysis unavailable — ML service is not reachable');
  }

  const res = await call('/predict/sentiment', { payload: { text: body, reviewId } });

  if (!res.ok) {
    const clientError = res.status >= 400 && res.status < 500;
    if (!clientError) {
      // Genuine service failure (5xx / network / timeout): count it and log once.
      recordFailure();
      warnOnce(
        `sentiment-fail-${res.status}`,
        `ml-service /predict/sentiment -> ${res.status || 'no response'} (${res.error})`,
      );
      return sentimentUnavailable('Sentiment analysis unavailable — ML service is not reachable');
    }
    // 4xx: the review is unusable, the service is fine. Breaker untouched.
    return sentimentUnavailable('Review text could not be scored', true);
  }

  recordSuccess();
  const parsed = sentimentResult(res.body || {}, reviewId);
  if (!parsed) {
    // A 200 whose body we cannot use. The service responded, so this does not count
    // against the breaker; the row simply stays unscored for now.
    warnOnce('sentiment-malformed', 'ml-service returned 200 with no usable sentiment label');
    return sentimentUnavailable('Sentiment analysis returned an unusable result');
  }
  return parsed;
}

/**
 * Score many reviews in one call — for the backfill job and any future moderation
 * page. `items`: [{ text, reviewId }].
 *
 * Returns { source, available, clientError, count, results:[…per-item shape…], reason }.
 * The ml-service batch is ALL-OR-NOTHING on validation (one unusable row 422s the
 * whole batch), so `available:false` with `clientError:true` is the signal to fall
 * back to per-row scoring — that is how the caller isolates which single row is the
 * unscoreable one. A 5xx/network failure returns `clientError:false`: the service is
 * down, per-row would fail identically, so the caller should just wait for the next
 * sweep.
 */
async function analyzeSentimentBatch(items = []) {
  const list = Array.isArray(items) ? items : [];
  const unavailable = (reason, clientError = false) => ({
    source: SOURCE_UNAVAILABLE,
    available: false,
    clientError,
    count: 0,
    results: [],
    reason,
  });

  if (!list.length) return unavailable('No reviews to analyse', true);
  if (breakerIsOpen() || !isConfigured()) {
    return unavailable('Sentiment analysis unavailable — ML service is not reachable');
  }

  const payloadItems = list.map((it) => ({
    text: typeof it.text === 'string' ? it.text.trim() : '',
    reviewId: it.reviewId ?? null,
  }));

  const res = await call('/predict/sentiment/batch', { payload: { items: payloadItems } });

  if (!res.ok) {
    const clientError = res.status >= 400 && res.status < 500;
    if (!clientError) {
      recordFailure();
      warnOnce(
        `sentiment-batch-fail-${res.status}`,
        `ml-service /predict/sentiment/batch -> ${res.status || 'no response'} (${res.error})`,
      );
      return unavailable('Sentiment analysis unavailable — ML service is not reachable');
    }
    // 422: at least one item is unusable. Caller retries per-row to find it.
    return unavailable('One or more reviews could not be scored', true);
  }

  recordSuccess();
  const data = res.body || {};
  const raw = Array.isArray(data.results) ? data.results : [];
  // Map each result back through the same defensive builder; drop any the builder
  // rejects (a per-row null) rather than passing a malformed row to an UPDATE.
  const results = raw
    .map((row) => sentimentResult(row, row && row.reviewId))
    .filter(Boolean);

  return {
    source: SOURCE_MODEL,
    available: true,
    clientError: false,
    count: results.length,
    results,
    reason: null,
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

/**
 * The sentiment contract as the PYTHON side defines it (text_norm.spec()).
 *
 * The sibling of featureSpec(), and it exists for the same reason: SENTIMENT_LABELS
 * in this file is a copy of text_norm.LABELS that Node cannot import, so
 * check_ml_service.js asserts the two agree by reading /sentiment/spec — turning
 * "keep the label set and normaliser version in sync" into a check that fails.
 */
async function sentimentSpec() {
  const res = await call('/sentiment/spec', { method: 'GET' });
  if (!res.ok) return { reachable: false, error: res.error, status: res.status, data: null };
  return { reachable: true, error: null, status: res.status, data: res.body };
}

async function recommendVenues(userId, { limit = 20 } = {}) {
  const unavailable = (reason) => ({ source: SOURCE_HEURISTIC, available: false, items: [], profile: null, label: 'For you', reason });
  if (!userId || breakerIsOpen() || !isConfigured()) return unavailable('Recommendations unavailable');
  const res = await call('/reco/venues', { payload: { user_id: String(userId), limit } });
  if (!res.ok) {
    if (!(res.status >= 400 && res.status < 500)) recordFailure();
    return unavailable('Recommendations unavailable');
  }
  recordSuccess();
  const data = res.body || {};
  return { source: SOURCE_MODEL, available: true, items: Array.isArray(data.items) ? data.items : [], profile: data.profile || null, label: data.label || 'For you', modelVersion: data.modelVersion || null, reason: null };
}

// ─── Player & opponent ranking (S.5 Wave B) ───────────────────
//
// These two call `core/reco_rank.py`, which is a DETERMINISTIC WEIGHTED SCORER and
// not a trained model — the wave states the weights literally, so there is nothing
// to fit. Hence a third `source` value: `'ranked'`. Calling it `'model'` would put
// an "AI" badge over a weighted mean on a screen a real captain reads, and calling
// it `'heuristic'` would be worse, because that word already means "the ml-service
// could not be reached" everywhere else in this file. Three honest states:
//
//   'ranked'      — the published formula scored this list, percentages are real
//   'heuristic'   — ml-service unreachable; the caller's own fallback ordered it
//   'unavailable' — nothing to show (used only where a fallback makes no sense)
//
// A 4xx does NOT trip the breaker, for the same reason it does not on the sentiment
// path: a 422 means THIS payload was malformed, which the next request may not be.
//
// The candidate pool travels in the request body. ml-service has no database
// connection, so it cannot look up who is on a roster or which teams are public —
// the SQL lives in the routes, and this seam only carries the rows across.

/** The formula ran. Not a model, and deliberately not labelled as one. */
const SOURCE_RANKED = 'ranked';

/**
 * Shared transport for /reco/players and /reco/opponents.
 *
 * Returns { source, available, items, considered, weights, componentOrder,
 *           rankSpecVersion, rankSpecFingerprint, reason } and never throws.
 *
 * `available:false` is the caller's cue to fall back to its own deterministic
 * ordering (v1's |ELO gap| sort for opponents) — NOT to hide the feature. Every
 * item's percentages stay absent on that path rather than being invented, which is
 * the same rule as `confidence: null` on the heuristic price path.
 */
async function rankViaMl(path, { teamId, team = {}, candidates = [], limit = 20 } = {}) {
  const unavailable = (reason) => ({
    source: SOURCE_UNAVAILABLE,
    available: false,
    items: [],
    considered: 0,
    weights: null,
    componentOrder: [],
    rankSpecVersion: null,
    rankSpecFingerprint: null,
    reason,
  });

  const list = Array.isArray(candidates) ? candidates : [];
  if (!teamId) return unavailable('No team to rank for');
  // An EMPTY POOL IS AN ANSWER, not an outage: there is genuinely nobody to
  // suggest. Answering it here saves a round-trip per empty roster and keeps the
  // caller from reading "unavailable" as "the service is down".
  if (!list.length) {
    return {
      source: SOURCE_RANKED,
      available: true,
      items: [],
      considered: 0,
      weights: null,
      componentOrder: [],
      rankSpecVersion: null,
      rankSpecFingerprint: null,
      reason: null,
    };
  }
  if (breakerIsOpen() || !isConfigured()) return unavailable('Ranking unavailable — ML service is not reachable');

  const res = await call(path, {
    payload: { team_id: String(teamId), team, candidates: list, limit },
  });

  if (!res.ok) {
    const clientError = res.status >= 400 && res.status < 500;
    if (!clientError) {
      recordFailure();
      warnOnce(`rank-fail-${path}-${res.status}`, `ml-service ${path} -> ${res.status || 'no response'} (${res.error})`);
    } else {
      warnOnce(`rank-4xx-${path}`, `ml-service ${path} rejected the payload (${res.status})`);
    }
    return unavailable('Ranking unavailable — ML service is not reachable');
  }

  recordSuccess();
  const data = res.body || {};
  return {
    source: SOURCE_RANKED,
    available: true,
    items: Array.isArray(data.items) ? data.items : [],
    considered: Number.isInteger(data.considered) ? data.considered : 0,
    weights: data.weights && typeof data.weights === 'object' ? data.weights : null,
    componentOrder: Array.isArray(data.componentOrder) ? data.componentOrder : [],
    // Carried through to the client so a stored payload can be traced to the exact
    // weights that produced its percentages — the sibling of `modelVersion`.
    rankSpecVersion: data.rankSpecVersion || null,
    rankSpecFingerprint: data.rankSpecFingerprint || null,
    reason: null,
  };
}

/** FR2.8 — rank candidate players for a team's roster rail. */
async function recommendPlayers(ctx = {}) {
  return rankViaMl('/reco/players', ctx);
}

/** FR5.3 — rank candidate opponents, replacing S.2's |ELO gap| sort as the % shown. */
async function recommendOpponents(ctx = {}) {
  return rankViaMl('/reco/opponents', ctx);
}

/**
 * The ranking contract as the PYTHON side defines it (reco_rank.spec()).
 *
 * The sibling of featureSpec()/sentimentSpec(), for the same reason: utils/elo.js's
 * COMP_GAP_CAP is 400 and so is reco_rank.ELO_GAP_CAP, Node cannot import Python,
 * and check_ml_service.js has to be able to ASSERT they still agree rather than
 * trust a comment. If they drift, the app draws a "well matched" band around a row
 * whose percentage disagrees.
 */
async function rankSpec() {
  const res = await call('/reco/rank-spec', { method: 'GET' });
  if (!res.ok) return { reachable: false, error: res.error, status: res.status, data: null };
  return { reachable: true, error: null, status: res.status, data: res.body };
}

// ─── Assistant NLU (model #4) ─────────────────────────────────
/**
 * The one Node-side door to the trained intent classifier + rule entity extractor.
 *
 * WHY THE LABEL LIST IS NOT HARD-CODED HERE
 * -----------------------------------------
 * Every other model in this file has a stable output shape; the assistant's does
 * not. `intent_spec.py` is a living artifact — it went from 15 labels
 * (assistant-intents-v1) to 23 (v2) inside one wave — and the RELEASED joblib can
 * lag the module that describes it, so at any moment `/nlu/spec` may advertise
 * labels `/nlu/parse` cannot yet emit. A copy of the label list in Node would be
 * wrong for one of those two states.
 *
 * So the routing table lives in services/assistantActions.js keyed by label, it is
 * built for the SUPERSET, and `assertNluLabels()` compares it to the live spec at
 * boot. An unknown label is then a printed mismatch instead of a silent no-op
 * branch — the failure mode that a hard-coded list produces and hides.
 *
 * WHY THERE IS NO KEYWORD FALLBACK
 * --------------------------------
 * When ml-service is down, `suggestPrice()` falls back to a business rule because
 * a price is still a price. An INTENT is not: a hand-written keyword matcher would
 * be a second, untrained, unmeasured classifier answering under the same UI, and
 * "the model understood you" would become a lie in exactly the case the committee
 * will test. The honest degradation is to abstain and let the dialog manager show
 * the capability menu, whose chips carry explicit actions and therefore need no
 * classification at all. Scout stays fully usable by button while the model is
 * unreachable, and never pretends to have understood free text.
 */

/** The five entity slots the extractor always returns. Contract, not a guess. */
const NLU_ENTITY_KEYS = ['date', 'time', 'sport', 'area', 'budget'];

/** The label the Python side falls back to. Node branches on it, so it is named. */
const NLU_FALLBACK_INTENT = 'out_of_scope';

/** ParseRequest.text has max_length=500; exceeding it is a 422, not a parse. */
const NLU_MAX_TEXT_CHARS = 500;

/** The three silences the model itself can report (GET /nlu/spec.abstainReasons). */
const NLU_ABSTAIN_LOW_CONFIDENCE = 'low_confidence';
const NLU_ABSTAIN_NO_EVIDENCE = 'no_evidence';
const NLU_ABSTAIN_NO_KNOWN_TERMS = 'no_known_terms';
const NLU_MODEL_ABSTAIN_REASONS = [
  NLU_ABSTAIN_LOW_CONFIDENCE, NLU_ABSTAIN_NO_EVIDENCE, NLU_ABSTAIN_NO_KNOWN_TERMS,
];

/** Two more that only Node can detect, added before the call is ever made. */
const NLU_ABSTAIN_UNAVAILABLE = 'nlu_unavailable';
const NLU_ABSTAIN_TOO_LONG = 'text_too_long';

/** All five slots, always present — so no caller writes `entities.date && ...`. */
function emptyEntities() {
  const out = {};
  for (const key of NLU_ENTITY_KEYS) out[key] = null;
  return out;
}

/**
 * A parse-shaped answer for the cases where no parse happened. Same field set as
 * the real thing, `available: false`, and a reason the dialog manager can render.
 */
function nluUnavailable(reason, abstainReason, { status = 0 } = {}) {
  return {
    available: false,
    source: SOURCE_UNAVAILABLE,
    intent: NLU_FALLBACK_INTENT,
    confidence: 0,
    entities: emptyEntities(),
    abstained: true,
    abstainReason,
    topIntent: NLU_FALLBACK_INTENT,
    topConfidence: 0,
    intentGroup: null,
    alternatives: [],
    threshold: null,
    modelVersion: null,
    intentSpecVersion: null,
    entitySpecVersion: null,
    nluTextSpecVersion: null,
    elapsedMs: null,
    status,
    error: reason,
  };
}

/**
 * Classify one utterance and extract its slots.
 *
 * `text` is sent RAW. The frozen normaliser is baked into the pipeline as a
 * FunctionTransformer, so pre-cleaning here would apply a second, different
 * normalisation and reintroduce the train/serve skew the artifact was shaped to
 * make impossible. Trim only — that is what pydantic does anyway.
 *
 * Never throws. Never returns a partial object: on every path the caller gets all
 * of the fields below, so the dialog manager has no optional-shape branches.
 *
 * @param {string} text            the user's message, exactly as typed
 * @param {object} [opts]
 * @param {string} [opts.sessionId] opaque conversation id, for correlation only
 * @param {string} [opts.now]       ISO instant, ONLY for tests pinning "kal"
 */
async function parseNlu(text, { sessionId = null, now = null } = {}) {
  const raw = typeof text === 'string' ? text.trim() : '';
  if (!raw) {
    return nluUnavailable('empty text', NLU_ABSTAIN_NO_EVIDENCE, { status: 400 });
  }
  if (raw.length > NLU_MAX_TEXT_CHARS) {
    // Truncating would silently change what the user said, and a 422 from
    // pydantic would surface as an opaque failure. Refuse locally and say why.
    return nluUnavailable(
      `text is ${raw.length} chars; the parser accepts ${NLU_MAX_TEXT_CHARS}`,
      NLU_ABSTAIN_TOO_LONG, { status: 400 },
    );
  }

  const payload = { text: raw };
  if (sessionId) payload.sessionId = String(sessionId).slice(0, 64);
  if (now) payload.now = now;

  const res = await call('/nlu/parse', { method: 'POST', payload });
  if (!res.ok || !res.body || typeof res.body.intent !== 'string') {
    return nluUnavailable(
      res.error || 'ml-service returned no intent',
      NLU_ABSTAIN_UNAVAILABLE, { status: res.status || 0 },
    );
  }

  const b = res.body;
  const entities = emptyEntities();
  if (b.entities && typeof b.entities === 'object') {
    for (const key of NLU_ENTITY_KEYS) {
      const slot = b.entities[key];
      entities[key] = slot && typeof slot === 'object' ? slot : null;
    }
  }

  const confidence = Number.isFinite(Number(b.confidence)) ? Number(b.confidence) : 0;
  return {
    available: true,
    source: SOURCE_MODEL,
    intent: b.intent,
    confidence,
    entities,
    abstained: b.abstained === true,
    abstainReason: b.abstainReason || null,
    topIntent: b.topIntent || b.intent,
    topConfidence: Number.isFinite(Number(b.topConfidence)) ? Number(b.topConfidence) : confidence,
    intentGroup: b.intentGroup || null,
    alternatives: Array.isArray(b.alternatives)
      ? b.alternatives
        .filter((a) => a && typeof a.intent === 'string')
        .map((a) => ({
          intent: a.intent,
          confidence: Number(a.confidence) || 0,
          group: a.group || null,
        }))
      : [],
    threshold: Number.isFinite(Number(b.threshold)) ? Number(b.threshold) : null,
    modelVersion: b.modelVersion || null,
    intentSpecVersion: b.intentSpecVersion || null,
    entitySpecVersion: b.entitySpecVersion || null,
    nluTextSpecVersion: b.nluTextSpecVersion || null,
    // The server's own wall clock, plus ours including the network.
    elapsedMs: Number.isFinite(Number(b.elapsedMs)) ? Number(b.elapsedMs) : null,
    roundTripMs: res.elapsed ?? null,
    status: res.status,
    error: null,
  };
}

/**
 * The NLU contract as the PYTHON side defines it — the sibling of sentimentSpec().
 *
 * Deliberately does not 503 when no artifact is loaded, so this is also the way to
 * ask "is the label list I route on still the label list that exists?" against a
 * service whose model has not been retrained yet.
 */
async function nluSpec() {
  const res = await call('/nlu/spec', { method: 'GET' });
  if (!res.ok) return { reachable: false, error: res.error, status: res.status, data: null };
  return { reachable: true, error: null, status: res.status, data: res.body };
}

/** intent_spec.spec() publishes its version as `intentSpecVersion`. */
function corpusVersion(data) {
  const c = (data && data.corpus) || {};
  return c.intentSpecVersion || c.specVersion || null;
}

/**
 * Boot-time contract check: does the routing table cover the labels the service
 * can actually produce?
 *
 * Two directions, and they are NOT equally serious:
 *
 *   unroutable  a label in the spec that Node has no branch for. A user utterance
 *               classified into it would fall through to the capability menu with
 *               no explanation. This is the real defect and it prints as one.
 *   stale       a label Node routes that the spec no longer lists. Harmless at
 *               runtime (nothing will ever emit it) but it means dead code, and
 *               after a rename it means the LIVE label is in `unroutable` too.
 *
 * Non-fatal by design: a backend that refuses to boot because a Python service on
 * port 8000 is not running would fail the same graceful-degradation requirement
 * this whole file exists to satisfy. It is loud, and check_assistant.js turns the
 * same comparison into a hard failure where a hard failure belongs.
 *
 * @param {string[]} routed the labels services/assistantActions.js can handle
 */
async function assertNluLabels(routed = []) {
  const spec = await nluSpec();
  if (!spec.reachable) {
    warnOnce('nlu-spec-unreachable',
      `assistant NLU spec unreachable (${spec.error}) — label routing unverified. `
      + 'Scout will serve its capability menu until ml-service answers.');
    return {
      ok: false, reachable: false, error: spec.error,
      unroutable: [], stale: [], specVersion: null, modelStatus: null, labels: [],
    };
  }

  const data = spec.data || {};
  const labels = Array.isArray(data.intents)
    ? data.intents.map((i) => (typeof i === 'string' ? i : i && i.intent)).filter(Boolean)
    : [];
  const routedSet = new Set(routed);
  const specSet = new Set(labels);
  const unroutable = labels.filter((l) => !routedSet.has(l));
  const stale = routed.filter((l) => !specSet.has(l));
  const model = data.model || {};

  if (unroutable.length) {
    console.error(
      `✗ assistant NLU: ${unroutable.length} intent(s) the model can emit have no `
      + `route in services/assistantActions.js: ${unroutable.join(', ')}. `
      + 'Users hitting them get the capability menu. Add a branch or map them.',
    );
  }
  if (stale.length) {
    console.warn(
      `~ assistant NLU: Node routes ${stale.length} label(s) absent from `
      + `${data.corpus && data.corpus.specVersion ? data.corpus.specVersion : 'the spec'}: `
      + `${stale.join(', ')}. Dead branches, or a rename to follow.`,
    );
  }
  if (!unroutable.length && !stale.length) {
    console.log(
      `✓ assistant NLU: ${labels.length} intents routed `
      + `(${model.modelVersion || 'no artifact'}, threshold ${model.threshold ?? '?'})`,
    );
  }

  return {
    ok: unroutable.length === 0,
    reachable: true,
    error: null,
    labels,
    unroutable,
    stale,
    specVersion: corpusVersion(data),
    modelStatus: model.status || null,
    modelVersion: model.modelVersion || null,
    threshold: Number.isFinite(Number(model.threshold)) ? Number(model.threshold) : null,
    fallbackIntent: model.fallbackIntent || NLU_FALLBACK_INTENT,
  };
}

module.exports = {
  // public API
  suggestPrice,
  forecastDemand,
  analyzeSentiment,
  analyzeSentimentBatch,
  health,
  featureSpec,
  sentimentSpec,
  recommendVenues,
  recommendPlayers,
  recommendOpponents,
  rankSpec,
  parseNlu,
  nluSpec,
  assertNluLabels,

  // constants — exported so routes, scripts and tests reference the value rather
  // than re-typing a string or a number that could drift
  SOURCE_MODEL,
  SOURCE_HEURISTIC,
  SOURCE_UNAVAILABLE,
  SOURCE_RANKED,
  SENTIMENT_LABELS,
  NLU_ENTITY_KEYS,
  NLU_FALLBACK_INTENT,
  NLU_MAX_TEXT_CHARS,
  NLU_MODEL_ABSTAIN_REASONS,
  NLU_ABSTAIN_LOW_CONFIDENCE,
  NLU_ABSTAIN_NO_EVIDENCE,
  NLU_ABSTAIN_NO_KNOWN_TERMS,
  NLU_ABSTAIN_UNAVAILABLE,
  NLU_ABSTAIN_TOO_LONG,
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
  emptyEntities,
  nluUnavailable,
};
