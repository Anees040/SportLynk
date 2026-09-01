/**
 * check_price_sanity.js — does the served model price things the way a human would?
 *
 * S.3 Wave E's milestone checklist contains two claims that no unit test in this repo
 * covers, because they are not about code paths — they are about whether the trained
 * model behaves like a person who knows the business:
 *
 *     "Suggested price changes sensibly: Friday 8pm > Tuesday 3am;
 *      low-rated venue < high-rated"
 *
 * `check_ml_service.js` proves the wiring (60 checks: envelope, auth, guardrails,
 * fallback, timezone). It deliberately does not prove this, because these are model
 * claims, and a passing wiring test with a nonsense model is exactly the failure this
 * project cannot afford in a viva. So this script exists to make those claims
 * falsifiable, run them against the LIVE serving path, and write the result to
 * `ml-service/reports/price_sanity.json` as part of the evidence pack.
 *
 * Why it goes through mlClient rather than curling the Python directly
 * The number the committee will see is the number on the owner's card, and that number
 * has been through `applyGuardrails` and the rounding step. Probing FastAPI directly
 * would test a number nobody is ever shown. So this calls `mlClient.suggestPrice` — the
 * exact function `GET /api/owner/venues/:id/pricing` calls.
 *
 * Why it refuses to run on the heuristic
 * The heuristic multiplies peak hours by a constant. It would pass "Friday 8pm >
 * Tuesday 3am" perfectly while proving nothing about the model. A green tick earned
 * by the fallback is worse than a red one, so `source: 'heuristic'` is a hard failure
 * here — the one place in this codebase where the fallback is not an acceptable answer.
 *
 * Two classes of CHECK, and why the split is not an excuse
 *   [require]  Directional claims the model must never invert. These gate the exit code.
 *   [observe]  Measured quantities recorded without a pass/fail, because the honest
 *              reading is "this effect is smaller than the model's resolution". Printing
 *              them unjudged is the point: a 0.002 swing in P(book) on a model with
 *              Brier 0.168 is noise, and dressing noise as a passing test is the kind of
 *              thing that collapses under one question.
 *
 * The finding this script was written to expose
 * "low-rated < high-rated" is true, but only where the policy band leaves room for it.
 * At Friday 20:00 both a 4.8-star and a 2.0-star venue return the same price, because
 * both are pinned to the +30% policy cap; the rating signal is real (P(book) 0.638 vs
 * 0.596) but the cap binds first and the suggestion cannot express it. That is a safety
 * feature working as designed — an owner is never shown a 3x price — and it is far more
 * defensible stated plainly than discovered by an examiner.
 *
 * And the corollary, which is easier to get wrong: the one hour where the prices are
 * strictly ordered (03:00) is the hour where the ordering means least. Its P(book) gap
 * runs the other way, by 0.002. Off-peak the revenue curve is nearly flat across the
 * band, so a wobble that small moves the argmax by a whole grid step. The honest summary
 * is that the rating effect is measurable at peak and only in P(book) — never in the
 * price. See the `contrary` observation below, which exists to say so out loud.
 *
 * Usage:  node src/scripts/check_price_sanity.js          (from D:\sportlynk\backend)
 *         node src/scripts/check_price_sanity.js --no-write
 * Requires uvicorn on ML_SERVICE_URL. Exit 0 = every [require] held.
 */

const path = require('path');
const fs = require('fs');

require('dotenv').config({ path: path.join(__dirname, '..', '..', '.env') });

const ml = require('../services/mlClient');

const REPORT_PATH = path.join(
  __dirname, '..', '..', '..', 'ml-service', 'reports', 'price_sanity.json',
);

// A single venue profile, held constant across every scenario so that the only thing
// varying between two rows of a comparison is the thing being tested. Same sport, same
// city, same base price — otherwise a price difference proves nothing.
const BASE = { basePrice: 2000, sport: 'Futsal', city: 'Lahore' };

// Fixed dates, not `new Date()`, so two runs a week apart produce comparable evidence.
// Chosen against the 2026 calendar: 2026-08-28 is a Friday, 2026-08-25 a Tuesday,
// 2026-08-27 a Thursday (an ordinary weekday, used for the rating pairs so that the
// Friday effect cannot be mistaken for a rating effect).
const FRIDAY = '2026-08-28';
const TUESDAY = '2026-08-25';
const THURSDAY = '2026-08-27';

let failures = 0;
let observations = 0;
const results = [];

function require_(name, ok, detail) {
  results.push({ kind: 'require', name, ok: !!ok, detail });
  if (!ok) failures += 1;
  console.log(`  [${ok ? 'PASS' : 'FAIL'}]  ${name.padEnd(46)} ${detail}`);
}

function observe(name, detail) {
  results.push({ kind: 'observe', name, detail });
  observations += 1;
  console.log(`  [ .. ]  ${name.padEnd(46)} ${detail}`);
}

const pkr = (n) => `PKR ${Number(n).toLocaleString('en-US')}`;

async function ask(label, overrides) {
  const r = await ml.suggestPrice({ ...BASE, ...overrides });
  return { label, ...r };
}

async function main() {
  console.log('');
  console.log('='.repeat(78));
  console.log('PRICE SANITY — does the served model price like a human would?');
  console.log('='.repeat(78));
  console.log(`  service    ${(process.env.ML_SERVICE_URL || '(unset)').trim()}`);
  console.log(`  venue      ${BASE.sport} in ${BASE.city}, base ${pkr(BASE.basePrice)}/hr`);
  console.log('');

  // ── 0. the model must be answering. See the header: a heuristic pass is a false pass.
  const probe = await ask('probe', { startTime: '20:00:00', slotDate: FRIDAY, venueRating: 4.5 });
  if (probe.source !== 'model') {
    console.log(`  [FAIL]  ml-service is not serving the model (source='${probe.source}').`);
    console.log('');
    console.log('  This script cannot judge a model that is not answering, and the heuristic');
    console.log('  would pass the peak/off-peak check for the wrong reason. Start the service:');
    console.log('    cd ml-service && .\\.venv\\Scripts\\python.exe -m uvicorn app.main:app \\');
    console.log('      --host 127.0.0.1 --port 8000');
    process.exit(1);
  }
  console.log(`  model      ${probe.modelVersion}`);
  const m = probe.modelMetrics || {};
  if (m.rocAuc) {
    console.log(`  quality    ROC-AUC ${m.rocAuc}  Brier ${m.brier}  (${m.testRows} held-out rows)`);
  }
  console.log('');

  // ── 1. the headline claim from the checklist: Friday 8pm beats Tuesday 3am.
  console.log('CLAIM 1 — Friday 8pm should cost more than Tuesday 3am');
  const friPeak = await ask('friday-20', { startTime: '20:00:00', slotDate: FRIDAY, venueRating: 4.5 });
  const tueDead = await ask('tuesday-03', { startTime: '03:00:00', slotDate: TUESDAY, venueRating: 4.5 });

  console.log(`         Friday 20:00  ${pkr(friPeak.suggestedPrice).padEnd(12)} ` +
              `${String(friPeak.deltaPct).padStart(4)}%   P(book) ${friPeak.demand}   conf ${friPeak.confidence}`);
  console.log(`         Tuesday 03:00 ${pkr(tueDead.suggestedPrice).padEnd(12)} ` +
              `${String(tueDead.deltaPct).padStart(4)}%   P(book) ${tueDead.demand}   conf ${tueDead.confidence}`);

  require_(
    'Friday 20:00 priced above Tuesday 03:00',
    friPeak.suggestedPrice > tueDead.suggestedPrice,
    `${pkr(friPeak.suggestedPrice)} > ${pkr(tueDead.suggestedPrice)}`,
  );
  require_(
    'and it is demand, not noise, driving it',
    friPeak.demand > tueDead.demand,
    `P(book) ${friPeak.demand} > ${tueDead.demand}`,
  );
  // The owner is owed a reason, not just a number. An empty factor list on a peak slot
  // means the explanation half of FR4.17 has silently stopped working.
  require_(
    'the peak slot explains itself',
    Array.isArray(friPeak.topFactors) && friPeak.topFactors.length > 0,
    (friPeak.topFactors || []).map((f) => `${f.label} ${f.direction}`).join(', ') || 'NO FACTORS',
  );

  // ── 2. the second claim — and the honest complication in it.
  console.log('');
  console.log('CLAIM 2 — a low-rated venue should not out-price a high-rated one');
  const pairs = [
    ['20:00', FRIDAY, 'peak — expect the policy cap to bind'],
    ['11:00', THURSDAY, 'off-peak morning'],
    ['03:00', THURSDAY, 'dead of night — most room to move'],
  ];

  const ratingRows = [];
  for (const [hhmm, date, note] of pairs) {
    const hi = await ask(`hi-${hhmm}`, { startTime: `${hhmm}:00`, slotDate: date, venueRating: 4.8 });
    const lo = await ask(`lo-${hhmm}`, { startTime: `${hhmm}:00`, slotDate: date, venueRating: 2.0 });
    ratingRows.push({ hhmm, note, hi, lo });

    console.log(`         ${hhmm}  4.8★ ${pkr(hi.suggestedPrice).padEnd(10)} vs ` +
                `2.0★ ${pkr(lo.suggestedPrice).padEnd(10)} ` +
                `P(book) ${hi.demand} vs ${lo.demand}   ${note}`);

    // The weak form is the defensible one. A strict "hi > lo" would fail wherever the
    // guardrail pins both to the same rupee — which is most of peak — so gating on it
    // would make a correct system look broken. Inversion, though, is never acceptable.
    require_(
      `${hhmm}: high rating is never priced below low`,
      hi.suggestedPrice >= lo.suggestedPrice,
      hi.suggestedPrice === lo.suggestedPrice
        ? `equal at ${pkr(hi.suggestedPrice)}${hi.atPolicyCap ? ' (both at policy cap)' : ''}`
        : `${pkr(hi.suggestedPrice)} > ${pkr(lo.suggestedPrice)}`,
    );
  }

  const strict = ratingRows.filter((r) => r.hi.suggestedPrice > r.lo.suggestedPrice);
  const capped = ratingRows.filter((r) => r.hi.atPolicyCap && r.lo.atPolicyCap);
  observe(
    'where rating actually moves the price',
    strict.length
      ? `${strict.length}/${ratingRows.length} scenarios (${strict.map((r) => r.hhmm).join(', ')})`
      : 'nowhere — the policy band absorbs it at every hour tested',
  );
  observe(
    'where the policy cap hides the rating signal',
    capped.length
      ? `${capped.map((r) => r.hhmm).join(', ')} — both ratings pinned to the cap, so the ` +
        'price cannot differ even though P(book) does'
      : 'no scenario was cap-bound',
  );
  // The line above is the easiest number in this file to misread, so the disagreement is
  // called out rather than left for a reader to notice. A scenario where the 4.8-star
  // venue is priced higher while the model gives it a lower P(book) is not evidence that
  // rating drives price there — it is a flat revenue curve. Off-peak the curve is nearly
  // level across the band, so a 0.002 wobble in P is enough to move the argmax by one
  // grid step (PKR 100), and 0.002 on a model with Brier 0.168 carries no information.
  // Quoting "strictly ordered at 03:00" without this sentence would be quoting noise.
  const contrary = ratingRows.filter(
    (r) => r.hi.suggestedPrice > r.lo.suggestedPrice && r.hi.demand < r.lo.demand,
  );
  observe(
    'price ordering that disagrees with P(book)',
    contrary.length
      ? `${contrary.map((r) => r.hhmm).join(', ')} — priced higher on the LOWER P(book). ` +
        'A flat off-peak revenue curve, not a rating effect: do not quote it as monotonicity'
      : 'none — every strict price ordering agrees with its P(book) ordering',
  );
  // Recorded, not gated. On this dataset rating shifts P(book) by ~0.04 at peak and by
  // ~0.002 at 03:00; the latter is well inside the model's error and its sign should not
  // be trusted, let alone asserted.
  for (const r of ratingRows) {
    const d = Number((r.hi.demand - r.lo.demand).toFixed(4));
    observe(
      `${r.hhmm}: P(book) gap from 2.8 stars of rating`,
      `${d >= 0 ? '+' : ''}${d}${Math.abs(d) < 0.01 ? '  (below the model\'s resolution — noise)' : ''}`,
    );
  }

  // ── 3. the shape of the day. One pair proves nothing; a demand curve is falsifiable.
  //
  // Measured from the forecast, not from suggestPrice — and the distinction is the whole
  // reason this block is written the way it is. `suggestPrice.demand` is P(book) at the
  // suggested PRICE, and the suggested price is different at every hour (0.75x at 03:00,
  // 1.30x at 20:00). Reading those numbers as a demand curve compares eight different
  // prices and calls the result a clock effect. The first version of this script did
  // exactly that and reported a fake dip at 19:00.
  //
  // `forecastDemand` holds price_ratio at 1.0 and varies only the clock. That is the
  // definition of a demand curve, and it is the series the venue chart draws.
  console.log('');
  console.log('CLAIM 3 — demand should rise through the evening, not wander');
  const fc = await ml.forecastDemand({ ...BASE, slotDate: THURSDAY, startTime: '19:00:00', venueRating: 4.5 });
  const pts = fc.points || [];

  // One calendar day out of the 72-hour window, so a day boundary cannot masquerade as a
  // trend. The middle day of the window is always complete.
  const byDate = {};
  for (const p of pts) (byDate[p.slotDate] = byDate[p.slotDate] || []).push(p);
  const fullDay = Object.values(byDate).find((a) => a.length === 24) || [];
  const curve = fullDay
    .map((p) => ({ hour: p.hour, demand: p.bookProbability, level: p.level }))
    .sort((a, b) => a.hour - b.hour);

  if (curve.length !== 24) {
    require_('a full 24-hour day is present in the forecast', false, `got ${curve.length} hours`);
  } else {
    console.log('         ' + [3, 8, 11, 15, 17, 19, 20, 22].map((h) => `${h}:00`.padEnd(7)).join(''));
    const d = (h) => curve.find((c) => c.hour === h).demand;
    console.log('         ' + [3, 8, 11, 15, 17, 19, 20, 22].map((h) => String(d(h)).padEnd(7)).join(''));

    require_('evening peak beats midday', d(20) > d(15), `${d(20)} > ${d(15)}`);
    require_('evening peak beats dawn', d(20) > d(3), `${d(20)} > ${d(3)}`);
    require_(
      'demand climbs 15:00 → 17:00 → 19:00 → 20:00',
      d(15) < d(17) && d(17) < d(19) && d(19) <= d(20),
      `${d(15)} < ${d(17)} < ${d(19)} <= ${d(20)}`,
    );
    require_('and it falls again after 20:00', d(22) < d(20), `${d(22)} < ${d(20)}`);

    // Where the busiest and deadest hours land is the check a venue owner can judge on
    // sight, which makes it the most valuable one in the file.
    const busiest = curve.reduce((a, b) => (b.demand > a.demand ? b : a));
    const deadest = curve.reduce((a, b) => (b.demand < a.demand ? b : a));
    require_(
      'the busiest hour of the day is an evening hour',
      busiest.hour >= 17 && busiest.hour <= 23,
      `${busiest.hour}:00 at ${busiest.demand}`,
    );
    require_(
      'the deadest hour is overnight or early morning',
      deadest.hour >= 0 && deadest.hour <= 9,
      `${deadest.hour}:00 at ${deadest.demand}`,
    );
  }

  // The price sweep is still worth recording — but as prices, which is what it measures.
  // Printing it beside the demand curve also makes the confound above self-evident to
  // whoever reads this next.
  const priceByHour = [];
  for (const h of [3, 8, 11, 15, 17, 19, 20, 22]) {
    const r = await ask(`h${h}`, {
      startTime: `${String(h).padStart(2, '0')}:00:00`,
      slotDate: THURSDAY,
      venueRating: 4.5,
    });
    priceByHour.push({ hour: h, price: r.suggestedPrice, deltaPct: r.deltaPct });
  }
  observe(
    'suggested price across the same day',
    priceByHour.map((p) => `${p.hour}:00 ${p.deltaPct >= 0 ? '+' : ''}${p.deltaPct}%`).join('  '),
  );
  const distinct = new Set(priceByHour.map((p) => p.price));
  require_(
    'the clock actually changes the price',
    distinct.size >= 2,
    `${distinct.size} distinct prices across 8 hours — a model that priced every hour the ` +
      'same would be useless to an owner',
  );

  // ── 4. the guardrail. The model may want anything; the owner must never see anything.
  console.log('');
  console.log('CLAIM 4 — no suggestion escapes the policy band');
  const all = [friPeak, tueDead, ...ratingRows.flatMap((r) => [r.hi, r.lo])];
  const ratios = all.map((r) => r.suggestedPrice / BASE.basePrice);
  const worstHigh = Math.max(...ratios);
  const worstLow = Math.min(...ratios);
  require_(
    'every suggestion sits inside the policy band',
    worstHigh <= (friPeak.policyMaxRatio || 1.3) + 1e-9 && worstLow >= 0.5,
    `${all.length} suggestions span ${worstLow.toFixed(2)}x–${worstHigh.toFixed(2)}x ` +
      `(cap ${friPeak.policyMaxRatio || 1.3}x)`,
  );
  require_(
    'prices are whole rupees an owner can read',
    all.every((r) => Number.isInteger(r.suggestedPrice)),
    'no fractional PKR',
  );

  // ── 5. the forecast the venue screen draws. Fetched once, at claim 3, and reused —
  //      the demand curve above and the chart below are literally the same series.
  console.log('');
  console.log('CLAIM 5 — the 72h forecast is 72 contiguous PKT hours');
  require_('forecast came from the model', fc.source === 'model', `source='${fc.source}'`);
  require_('72 points', pts.length === 72, `got ${pts.length}`);
  require_(
    'every timestamp is PKT (+05:00)',
    pts.length > 0 && pts.every((p) => String(p.ts).endsWith('+05:00')),
    'no UTC leaked into the chart',
  );
  const contiguous = pts.every((p, i) => i === 0 || p.hour === (pts[i - 1].hour + 1) % 24);
  require_('hours are contiguous with no gaps', contiguous, `${pts[0]?.hour}:00 → ${pts[pts.length - 1]?.hour}:00`);
  const levels = pts.reduce((acc, p) => ({ ...acc, [p.level]: (acc[p.level] || 0) + 1 }), {});
  require_(
    'the chart is not one flat colour',
    Object.keys(levels).length >= 2,
    JSON.stringify(levels),
  );

  // ── report
  console.log('');
  console.log('='.repeat(78));
  const required = results.filter((r) => r.kind === 'require');
  if (failures === 0) {
    console.log(`ALL ${required.length} REQUIRED CHECKS PASSED — ${probe.modelVersion}`);
    console.log(`  ${observations} further quantities recorded without a verdict (see the [ .. ] lines).`);
    console.log('  Read them: they are where this model is honest about its limits.');
  } else {
    console.log(`${failures} of ${required.length} REQUIRED CHECKS FAILED`);
    console.log('  A failure here means the model is priced-nonsense, not that the wiring broke.');
    console.log('  Do not ship or demo it. Re-read reports/model_card_pricing.md first.');
  }
  console.log('='.repeat(78));

  if (!process.argv.includes('--no-write')) {
    const record = {
      // No Date.now() in the compared fields — only here, where it is provenance, not data.
      generatedAt: new Date().toISOString(),
      modelVersion: probe.modelVersion,
      modelMetrics: probe.modelMetrics || null,
      venueProfile: BASE,
      dates: { friday: FRIDAY, tuesday: TUESDAY, thursday: THURSDAY },
      claims: {
        peakBeatsDeadOfNight: {
          fridayEvening: friPeak.suggestedPrice,
          tuesdayPreDawn: tueDead.suggestedPrice,
          holds: friPeak.suggestedPrice > tueDead.suggestedPrice,
        },
        ratingNeverInverts: ratingRows.map((r) => ({
          hour: r.hhmm,
          highRating: r.hi.suggestedPrice,
          lowRating: r.lo.suggestedPrice,
          demandGap: Number((r.hi.demand - r.lo.demand).toFixed(4)),
          bothAtPolicyCap: !!(r.hi.atPolicyCap && r.lo.atPolicyCap),
        })),
        demandCurve: curve,
        suggestedPriceByHour: priceByHour,
      },
      requiredPassed: required.filter((r) => r.ok).length,
      requiredTotal: required.length,
      observations: results.filter((r) => r.kind === 'observe'),
      checks: results,
    };
    try {
      fs.writeFileSync(REPORT_PATH, `${JSON.stringify(record, null, 2)}\n`, 'utf8');
      console.log(`wrote ${path.relative(path.join(__dirname, '..', '..', '..'), REPORT_PATH)}`);
    } catch (err) {
      // Evidence failing to write must not turn a green model red.
      console.log(`  (could not write the report: ${err.message})`);
    }
  }
  console.log('');

  process.exit(failures === 0 ? 0 : 1);
}

main().catch((err) => {
  console.error('');
  console.error(`check_price_sanity crashed: ${err && err.stack ? err.stack : err}`);
  process.exit(1);
});
