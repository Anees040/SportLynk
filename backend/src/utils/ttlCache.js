/**
 * ttlCache.js — a small, bounded, in-memory TTL cache.
 *
 * Why this exists
 * The owner dashboard carries two ML-backed reads: a price suggestion and
 * a 72-hour demand forecast. Both cost a cross-process HTTP call to the Python
 * service with a 2-second timeout, and both answer questions whose answers do not
 * change minute to minute — a demand forecast for the next 72 hours is the same
 * forecast whether it is requested at 14:00 or at 14:20. Recomputing it on every dashboard
 * refresh would spend 2s of latency and a scikit-learn inference to produce a byte
 * -identical response.
 *
 * utils/globalSettings.js already hand-rolls exactly this pattern inline (a Map of
 * `{value, at}` plus a TTL_MS comparison). Doing it a second time in owner.js would
 * make it a habit rather than a decision, so it moves here once, with the three
 * things the inline version does not have: a size bound, in-flight de-duplication,
 * and a rule about failures.
 *
 * Why in-memory and not REDIS
 * SportLynk already runs three processes (Flutter aside): Node, Postgres, and now
 * FastAPI. A fourth process to hold a value that is cheap to recompute and harmless
 * to lose is the wrong trade at this stage. This cache is a latency optimisation,
 * never a source of truth: the correct behaviour on a cold start, a restart or an
 * eviction is one extra ML call, which is exactly what happens.
 *
 * The consequence to be aware of: with more than one Node instance behind a load
 * balancer, each holds its own copy, so a venue's suggestion could differ across
 * instances for up to one TTL. That is acceptable for a suggestion an owner must
 * explicitly apply. It would not be acceptable for anything transactional, which is
 * why nothing in here caches a booking, a balance, or a lock.
 *
 * Why failures are not cached by default
 * Caching "the ML service was down" for an hour would turn a 30-second outage into a
 * 60-minute one, and mlClient.js already has a circuit breaker whose entire job is to
 * make repeated failures cheap. So `getOrSet` takes a `shouldCache` predicate and the
 * default stores only what the caller says is worth storing. A degraded answer is
 * served, then forgotten.
 *
 * Why in-flight de-duplication
 * Without it, five simultaneous dashboard loads on a cold key make five ML calls,
 * each paying the full timeout, and four of them are thrown away. The promise itself
 * is cached while it is pending, so concurrent callers await the same call. This is
 * the difference between a cache that helps under load and one that only helps when
 * nothing is happening.
 */

/** Entries per cache. A bound, not a tuning knob — see the note in the constructor. */
const DEFAULT_MAX_ENTRIES = 500;

/** One hour, the TTL specified for the owner pricing reads. */
const ONE_HOUR_MS = 60 * 60 * 1000;

class TtlCache {
  /**
   * @param {object}  opts
   * @param {string}  opts.name        appears in stats(); makes two caches tellable apart
   * @param {number}  opts.ttlMs       how long an entry stays fresh
   * @param {number}  opts.maxEntries  hard ceiling on stored entries
   */
  constructor({ name = "cache", ttlMs = ONE_HOUR_MS, maxEntries = DEFAULT_MAX_ENTRIES } = {}) {
    this.name = name;
    this.ttlMs = Math.max(1000, Number(ttlMs) || ONE_HOUR_MS);

    // The bound is what makes this safe to key on user-supplied values. The pricing
    // key is venueId + date + hour, so a scripted client could otherwise mint
    // unbounded distinct keys and grow the heap until the process dies — a cache
    // becoming a memory leak is a real and boring way to lose a production node.
    // Eviction is oldest-inserted first, not least-recently-used: a JS Map iterates
    // in insertion order, so `keys().next()` is the oldest entry for free, and with a
    // uniform TTL the oldest entry is also the one closest to expiring anyway. True
    // LRU would need a second structure to buy almost nothing here.
    this.maxEntries = Math.max(1, Number(maxEntries) || DEFAULT_MAX_ENTRIES);

    /** @type {Map<string, {value: any, at: number}>} */
    this.store = new Map();
    /** @type {Map<string, Promise<any>>} in-flight loads, keyed the same way */
    this.pending = new Map();

    this.hits = 0;
    this.misses = 0;
    this.evictions = 0;
  }

  /** Fresh value, or `undefined`. An expired entry is deleted on the way out. */
  get(key) {
    const hit = this.store.get(key);
    if (!hit) return undefined;
    if (Date.now() - hit.at >= this.ttlMs) {
      this.store.delete(key);
      return undefined;
    }
    return hit.value;
  }

  set(key, value) {
    // Delete-then-set so an overwrite moves the key to the end of the insertion
    // order. Without this, a hot key that is refreshed forever keeps its original
    // position and is evicted while still fresh.
    if (this.store.has(key)) this.store.delete(key);
    this.store.set(key, { value, at: Date.now() });
    while (this.store.size > this.maxEntries) {
      const oldest = this.store.keys().next();
      if (oldest.done) break;
      this.store.delete(oldest.value);
      this.evictions += 1;
    }
    return value;
  }

  /**
   * The method callers use: return the cached value, or run `loader` once.
   *
   * @param {string}   key
   * @param {Function} loader       async () => value
   * @param {object}   [opts]
   * @param {Function} [opts.shouldCache]  (value) => boolean; default caches everything
   *                                       truthy. Pass a predicate to skip storing
   *                                       degraded answers — see the header.
   */
  async getOrSet(key, loader, { shouldCache = (v) => v != null } = {}) {
    const cached = this.get(key);
    if (cached !== undefined) {
      this.hits += 1;
      return cached;
    }

    // Someone else is already loading this exact key: wait for their call instead of
    // making a second one.
    const inFlight = this.pending.get(key);
    if (inFlight) {
      this.hits += 1;
      return inFlight;
    }

    this.misses += 1;
    const promise = (async () => {
      const value = await loader();
      let store = false;
      try {
        store = shouldCache(value) === true;
      } catch {
        // A throwing predicate must not lose the value the caller is waiting for.
        store = false;
      }
      if (store) this.set(key, value);
      return value;
    })();

    this.pending.set(key, promise);
    try {
      return await promise;
    } finally {
      // Always cleared, including on a rejection — otherwise one failed load would
      // pin a rejected promise under that key and every later caller would inherit
      // the same failure forever.
      this.pending.delete(key);
    }
  }

  /** Drop one key, or the whole cache. Called after a write that invalidates it. */
  invalidate(key) {
    if (key === undefined) {
      this.store.clear();
      return;
    }
    this.store.delete(key);
  }

  /**
   * Drop every key that starts with `prefix`.
   *
   * The reason keys are built as `venueId:...` rather than hashed: applying a price
   * to a venue's slots must invalidate every cached suggestion for that venue,
   * whatever date or hour it was keyed on, and a readable prefix makes that one call
   * instead of a bookkeeping structure.
   */
  invalidatePrefix(prefix) {
    if (!prefix) return 0;
    let dropped = 0;
    for (const key of this.store.keys()) {
      if (key.startsWith(prefix)) {
        this.store.delete(key);
        dropped += 1;
      }
    }
    return dropped;
  }

  /** Read-only snapshot for /health and check scripts. */
  stats() {
    return {
      name: this.name,
      size: this.store.size,
      maxEntries: this.maxEntries,
      ttlMs: this.ttlMs,
      hits: this.hits,
      misses: this.misses,
      evictions: this.evictions,
      pending: this.pending.size,
    };
  }
}

module.exports = { TtlCache, ONE_HOUR_MS, DEFAULT_MAX_ENTRIES };
