/**
 * Sentiment backfill sweep (S.4 Wave C) — the safety net behind inline scoring.
 *
 * routes/reviews.js scores a review's text at creation. When the ml-service is down
 * at that moment the review still saves, honestly, with sentiment_label NULL (the
 * no-heuristic contract: never invent a label). This job is what later turns those
 * NULLs into real scores, so a spell of ml-service downtime doesn't leave a
 * permanent hole in the trust and venue-sentiment signals.
 *
 * Every sweep:
 *   1. Take up to BATCH reviews that have text but no sentiment yet, oldest first.
 *   2. Score them in one batch call. The ml-service batch is all-or-nothing on
 *      validation — a single unusable row 422s the whole batch — so:
 *        • batch available            → UPDATE each scored row.
 *        • batch 422 (clientError)    → fall back to per-row scoring to isolate the
 *                                       unusable row(s).
 *        • batch 5xx/down (!clientErr)→ leave the whole set for the next sweep.
 *   3. A row that even single-row scoring rejects as unusable text (a 422: empty,
 *      all-emoji, evidence-free) is stamped with the terminal 'unscoreable'
 *      sentinel. That value is excluded from every read (the distribution counts
 *      only the three real labels; trust uses sentiment_score, still NULL) and,
 *      crucially, is no longer NULL — so it is never re-selected. Without it, one
 *      permanently-unscoreable row would come back every sweep forever and wedge
 *      the queue behind it.
 *
 * Review text is never logged here — only ids and counts — matching the ml-service's
 * own discipline.
 */

const pool = require('../db/pool');
const ml = require('../services/mlClient');

// The ml-service batch endpoint caps at 200 items; take exactly that.
const BATCH = 200;
// A safety net, not a live path — a slow cadence is fine, and reviews created while
// the service is up never reach it. Offset from the other jobs' start so boot isn't
// a thundering herd of first sweeps.
const SWEEP_MS = 5 * 60 * 1000;
const INITIAL_DELAY_MS = 20000;

let _running = false;

/**
 * Persist one scored result. Guarded on `sentiment_label IS NULL` so a review that
 * was scored inline (or by a previous sweep) in the meantime is never overwritten,
 * and `flagged` is only ever raised, never cleared — a moderation escalation from
 * the model must not undo a human's manual flag.
 */
async function applyScored(id, r) {
  await pool.query(
    `UPDATE reviews
        SET sentiment_label = $2,
            sentiment_score = $3,
            flagged = flagged OR $4
      WHERE id = $1 AND sentiment_label IS NULL`,
    [id, r.label, r.score, r.flagged === true],
  );
}

/**
 * Resolve one review on its own. Returns 'scored' | 'unscoreable' | 'service_down'.
 * 'service_down' means the service failed mid-sweep (not the row's fault) — the
 * caller should stop and wait rather than hammer a downed service.
 */
async function applyPerRow(row) {
  const r = await ml.analyzeSentiment(row.comment, { reviewId: row.id });
  if (r.available) {
    await applyScored(row.id, r);
    return 'scored';
  }
  if (r.clientError) {
    // Terminal: the text itself cannot be scored, so mark it and stop re-selecting it.
    await pool.query(
      `UPDATE reviews SET sentiment_label = 'unscoreable'
        WHERE id = $1 AND sentiment_label IS NULL`,
      [row.id],
    );
    return 'unscoreable';
  }
  return 'service_down';
}

async function sweepSentimentBackfill() {
  if (_running) return;
  _running = true;
  try {
    const { rows } = await pool.query(
      `SELECT id, comment
         FROM reviews
        WHERE comment IS NOT NULL AND sentiment_label IS NULL
        ORDER BY created_at ASC
        LIMIT $1`,
      [BATCH],
    );
    if (!rows.length) {
      console.log('[SentimentBackfill] sweep: 0 unscored review(s).');
      return;
    }

    const batch = await ml.analyzeSentimentBatch(
      rows.map((r) => ({ text: r.comment, reviewId: r.id })),
    );

    // Service is down (5xx / network / timeout): per-row would fail identically, so
    // defer the whole set. The rows stay NULL and come back next sweep.
    if (!batch.available && !batch.clientError) {
      console.log(
        `[SentimentBackfill] sweep: ml-service unavailable — deferring ${rows.length} review(s).`,
      );
      return;
    }

    let scored = 0;
    let unscoreable = 0;
    let deferred = 0;

    if (batch.available) {
      const byId = new Map(batch.results.map((r) => [String(r.reviewId), r]));
      for (const row of rows) {
        const r = byId.get(String(row.id));
        if (r) {
          await applyScored(row.id, r);
          scored += 1;
        } else {
          // Scored the batch but this row came back without a usable result (a
          // malformed row the builder dropped). Resolve it individually so it can
          // never be re-selected forever.
          const out = await applyPerRow(row);
          if (out === 'scored') scored += 1;
          else if (out === 'unscoreable') unscoreable += 1;
          else deferred += 1;
        }
      }
    } else {
      // batch 422: at least one row is unusable. Per-row isolates which.
      for (const row of rows) {
        const out = await applyPerRow(row);
        if (out === 'scored') scored += 1;
        else if (out === 'unscoreable') unscoreable += 1;
        else {
          deferred += 1;
          break; // service fell over mid-sweep — stop hammering it
        }
      }
    }

    console.log(
      `[SentimentBackfill] sweep: ${scored} scored, ${unscoreable} unscoreable, ` +
        `${deferred} deferred (of ${rows.length}).`,
    );
  } catch (err) {
    console.error('[SentimentBackfill] sweep error:', err.message);
  } finally {
    _running = false;
  }
}

function startSentimentBackfillJob() {
  console.log(
    `[SentimentBackfill] Started — sweeps every ${SWEEP_MS / 60000} min, ` +
      `up to ${BATCH} review(s) per sweep.`,
  );
  setTimeout(sweepSentimentBackfill, INITIAL_DELAY_MS);
  setInterval(sweepSentimentBackfill, SWEEP_MS);
}

module.exports = { startSentimentBackfillJob, sweepSentimentBackfill };
