/**
 * reports.js — S.7 Wave D · D4 / FR4.16. The financial export, as two routes over
 * one generator (`services/reportService.js`).
 *
 * TWO ROUTERS, ONE FILE
 *   `ownerReports`    mounted INTO `routes/owner.js`, so it inherits that file's
 *                     single `router.use(auth, checkRole("owner"))` and is scoped to
 *                     `req.user.id` -> `/api/owner/reports/financial`
 *   `platformReports` mounted INTO `routes/admin.js`, behind its
 *                     `auth + checkRole('admin')` -> `/api/admin/reports/platform`
 * Same reason as `adminUsers` / `adminDisputes` / `adminSettings`: one place in the
 * codebase decides who may see this, and a new surface cannot forget to ask. The
 * owner router NEVER omits its owner filter, so "export everything" is not reachable
 * by editing a query string.
 *
 * THE ONE THING A STREAMED RESPONSE GETS WRONG
 * Once the first byte is written the status code is spent: an error after that
 * cannot become `{success:false,message}`, and Express's error handler would send
 * JSON into the middle of a CSV. So a failure mid-stream appends a final
 * `ERROR,<message>` row and ends the response. The file is then visibly truncated in
 * the last place anybody looks, instead of silently short — a report that is quietly
 * missing yesterday's bookings is worse than one that says it broke.
 */
const express = require('express');
const pool = require('../db/pool');
const reports = require('../services/reportService');
const csv = require('../utils/csv');

const ownerReports = express.Router();
const platformReports = express.Router();

function bad(res, status, message) {
  return res.status(status).json({ success: false, message });
}

/** Headers for a downloadable CSV. `nosniff` because the filename is user-visible. */
function csvHeaders(res, filename) {
  res.setHeader('Content-Type', 'text/csv; charset=utf-8');
  res.setHeader('Content-Disposition', `attachment; filename="${csv.safeFilename(filename)}"`);
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('X-Content-Type-Options', 'nosniff');
}

/**
 * Serve one report in either format. Shared by both routers so the CSV and the JSON
 * can never drift apart: the same `eachRow` walk feeds both.
 */
async function serve(req, res, opts) {
  if (opts.format === 'json') {
    const data = await reports.collectJson(pool, opts);
    return res.json({ success: true, data });
  }

  csvHeaders(res, reports.filenameFor(opts));
  try {
    await reports.streamCsv(pool, opts, res);
  } catch (e) {
    // Headers are already out; see the file header. Say so in the file itself.
    console.error('[reports] stream failed mid-file:', e.message);
    res.write(csv.row(['ERROR', 'The export failed part-way through. Please try again.']));
  }
  return res.end();
}

/**
 * GET /api/owner/reports/financial?from&to&venueId&format=csv|json
 *
 * One row per booking on this owner's venues in the range, plus one row per
 * tournament payout they earned, plus a TOTAL. Money from the ledger, so it
 * reconciles with the wallet screen to the paisa.
 */
ownerReports.get('/reports/financial', async (req, res, next) => {
  const r = reports.parseRange(req.query);
  if (!r.ok) return bad(res, r.status, r.message);

  try {
    // Checked rather than left to the owner filter: an empty file for a venue that
    // is not yours reads as "no bookings", which is a different and wrong answer.
    if (r.venueId) {
      const { rows } = await pool.query(
        'SELECT 1 FROM venues WHERE id = $1 AND owner_id = $2',
        [r.venueId, req.user.id],
      );
      if (!rows.length) return bad(res, 404, 'Venue not found.');
    }
    return await serve(req, res, { ...r, scope: 'owner', ownerId: req.user.id });
  } catch (e) { return next(e); }
});

/**
 * GET /api/admin/reports/platform?from&to&venueId&format=csv|json
 *
 * The same generator with no owner filter, an extra Owner column, and a subtotal per
 * owner before the TOTAL — which is where "commission earned per owner" (FR4.16)
 * actually lives, since commission is a ledger row on the owner's wallet.
 */
platformReports.get('/reports/platform', async (req, res, next) => {
  const r = reports.parseRange(req.query);
  if (!r.ok) return bad(res, r.status, r.message);
  try {
    return await serve(req, res, { ...r, scope: 'platform', ownerId: null });
  } catch (e) { return next(e); }
});

module.exports = { ownerReports, platformReports };
