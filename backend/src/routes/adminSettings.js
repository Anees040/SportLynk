/**
 * adminSettings.js — FR10.9–FR10.11. Read and change platform policy
 * from the admin app, with no restart.
 *
 * Mounting
 * Mounted into `routes/admin.js` after its single `router.use(auth,
 * checkRole('admin'))`, exactly like `adminUsers.js` and `adminDisputes.js`: one
 * place decides who is an admin, so a new admin surface cannot forget to ask.
 *
 * Why "applies on the next operation" is true here and not a promise
 * `utils/globalSettings.js` caches for 60 s and exposes `invalidate()`; its header
 * has said since it was written that the hook exists "so an admin settings endpoint
 * (S.7) can drop the cache the moment it writes". This is that endpoint. The write
 * and the `invalidate()` are in the same request, so the very next booking, rating
 * or Scout turn reads the new row. FR10.11 asks for exactly that and nothing more:
 * there is no deploy, no restart, no config reload.
 *
 * Why validation lives in `settingsCatalog.js` and not here
 * The accessor clamps out-of-range values so a bad row can never break a booking.
 * That is right for a read and disastrous for a write: an admin who types 900 and
 * is told "saved" would believe the ladder moves 28 times harder than it does. The
 * catalog holds one table of ranges, the route rejects with it, and the accessor
 * clamps with it. Two behaviours, one source.
 *
 * What this route owns that the catalog cannot
 * Three things that need a database and therefore cannot be pure:
 *   1. reading the seven `global_settings` rows through the same accessor the app
 *      uses, so the admin sees effective values rather than raw jsonb;
 *   2. refusing to switch off a sport that has future confirmed bookings, and
 *      saying how many;
 *   3. pushing `deposit_pct` into `escrow.POLICY.DEPOSIT_PERCENT`, which ~30
 *      synchronous call sites use to describe the policy in copy. Copy that
 *      disagrees with the row is worse than either number alone.
 */
const express = require('express');
const router = express.Router();
const pool = require('../db/pool');
const settings = require('../utils/globalSettings');
const catalog = require('../utils/settingsCatalog');
const escrow = require('../utils/escrow');
const { audit, ACTIONS } = require('../utils/adminAudit');

/** Uniform failure, per the golden rule: every error is `{success:false,message}`. */
function bad(res, status, message, extra = {}) {
  return res.status(status).json({ success: false, message, ...extra });
}

/**
 * The raw jsonb for every row the catalog knows about, in one query.
 *
 * Deliberately not `settings.get()` per key: that would serve the 60 s cache, and
 * an admin screen must show what is stored right now, not what was stored a minute
 * ago. The effective value the app will use is then derived by the catalog from
 * these same rows, so the screen and the accessor cannot disagree.
 */
async function rawRows(db = pool) {
  const keys = [...new Set(Object.values(catalog.FIELDS).map((f) => f.row))];
  const { rows } = await db.query(
    'SELECT key, value FROM global_settings WHERE key = ANY($1::text[])', [keys],
  );
  const out = {};
  for (const r of rows) out[r.key] = r.value;
  return out;
}

/**
 * How many future confirmed bookings a sport still has.
 *
 * Why this blocks the write
 * Switching a sport off stops new bookings (`bookingService.createBooking`) and new
 * venues (`routes/owner.js POST /venues`). It says nothing about money already
 * held in escrow for a game on Saturday. Letting the switch flip silently would
 * leave those players with a confirmed booking for a sport the platform no longer
 * books — they can still check in, but nothing in the app explains that, and an
 * admin who was not told the count could not have known to look.
 *
 * So it is a refusal with a number, not a warning and not a cascade: the admin can
 * wait for the fixtures to play out, or cancel them deliberately through the
 * booking routes where each refund is logged. An endpoint that quietly refunded
 * dozens of bookings as a side effect of a toggle would be the worse of the two.
 */
async function futureBookingsBySport(db, sports) {
  if (!sports.length) return {};
  const { rows } = await db.query(
    `SELECT lower(v.sport_type) AS sport, count(*)::int AS n
       FROM bookings b JOIN venues v ON v.id = b.venue_id
      WHERE lower(v.sport_type) = ANY($1::text[])
        AND b.status IN ('confirmed', 'pending')
        AND b.slot_date >= (now() AT TIME ZONE 'UTC')::date
      GROUP BY 1`,
    [sports],
  );
  const out = {};
  for (const r of rows) out[r.sport] = r.n;
  return out;
}

/**
 * GET /api/admin/settings
 *
 * Sections in screen order, each field carrying `{value, default, isOverridden,
 * type, min, max, step, unit, description}`. `value` is effective — what the next
 * booking will use — so an admin reading this screen is reading the
 * platform, not a table.
 */
router.get('/settings', async (req, res, next) => {
  try {
    const raw = await rawRows();
    const sections = catalog.describe(raw);
    res.json({
      success: true,
      data: {
        sections,
        overrides: catalog.overrides(raw),
        // Named here so the screen can say it out loud rather than implying it.
        appliesImmediately: true,
        cacheTtlSeconds: 60,
      },
    });
  } catch (e) { return next(e); }
});

/**
 * PUT /api/admin/settings
 * Body: `{ settings: { 'elo.k_factor': 40, commission_pct: 5, ... }, note }`
 * (a bare flat object is accepted too, so a curl one-liner works).
 *
 * Order of operations, and why
 *   1. `FOR UPDATE` on the rows being touched. Two admins saving different sections
 *      of the same screen at once would otherwise each write a merge built from the
 *      state they loaded, and the later write would silently undo the earlier one.
 *   2. validate against the current rows (so cross-field rules see values this
 *      request did not send).
 *   3. the sports refusal, which needs a count.
 *   4. write, audit inside the transaction, COMMIT.
 *   5. only then `invalidate()` and the escrow push — invalidating before COMMIT
 *      would let a concurrent read cache the old value for another 60 s, which is
 *      the one ordering mistake that turns "applies immediately" back into a lie.
 */
router.put('/settings', async (req, res, next) => {
  const body = req.body || {};
  const patch = body.settings && typeof body.settings === 'object' && !Array.isArray(body.settings)
    ? body.settings
    : body;
  const note = String(body.note || '').trim().slice(0, 500);

  if (!patch || typeof patch !== 'object' || Array.isArray(patch) || !Object.keys(patch).length) {
    return bad(res, 400, 'Nothing to save.');
  }

  const client = await pool.connect();
  let out;
  try {
    await client.query('BEGIN');
    const keys = [...new Set(Object.values(catalog.FIELDS).map((f) => f.row))];
    await client.query(
      'SELECT key FROM global_settings WHERE key = ANY($1::text[]) FOR UPDATE', [keys],
    );

    const raw = await rawRows(client);
    const v = catalog.validate(patch, raw);
    if (!v.ok) {
      await client.query('ROLLBACK');
      return bad(res, 400, v.errors[0].message, { errors: v.errors });
    }
    if (!v.diff.length) {
      await client.query('ROLLBACK');
      const sections = catalog.describe(raw);
      return res.json({
        success: true,
        message: 'Nothing changed — those are already the saved values.',
        data: { sections, changed: [], overrides: catalog.overrides(raw) },
      });
    }

    // The sports refusal. Only sports going from on to off are checked; switching
    // one on can never orphan anything.
    if (v.rows.sports_enabled) {
      const before = catalog.valueOf('sports_enabled', raw) || {};
      const after = v.rows.sports_enabled;
      const turningOff = Object.keys(after).filter((s) => after[s] === false && before[s] !== false);
      // A sport dropped from the map entirely is also being switched off, and
      // `isSportEnabled` fails OPEN for an unknown name — so removing a key would
      // otherwise look like a disable and behave like an enable.
      for (const s of Object.keys(before)) {
        if (before[s] !== false && !Object.prototype.hasOwnProperty.call(after, s)) turningOff.push(s);
      }
      if (turningOff.length) {
        const counts = await futureBookingsBySport(client, turningOff);
        const blocked = Object.entries(counts).filter(([, n]) => n > 0);
        if (blocked.length) {
          await client.query('ROLLBACK');
          const parts = blocked.map(([s, n]) => `${s} (${n} booking${n === 1 ? '' : 's'})`);
          return bad(res, 409,
            `Cannot switch off ${parts.join(' and ')} — those bookings are already paid for and still to be played. `
            + 'Cancel or let them finish first, then switch the sport off.',
            { code: 'sport_has_bookings', counts });
        }
      }
    }

    for (const [key, value] of Object.entries(v.rows)) {
      await client.query(
        `INSERT INTO global_settings (key, value) VALUES ($1, $2::jsonb)
         ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value`,
        [key, JSON.stringify(value)],
      );
    }

    await audit(client, {
      adminId: req.user.id,
      action: ACTIONS.SETTINGS_UPDATE,
      entityType: 'settings',
      entityId: null,
      before: Object.fromEntries(v.diff.map((d) => [d.key, d.from])),
      after: Object.fromEntries(v.diff.map((d) => [d.key, d.to])),
      note: note || v.diff.map((d) => `${d.label}: ${d.from} → ${d.to}`).join('; '),
    });

    await client.query('COMMIT');
    out = { raw: v.rows, diff: v.diff };
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    return next(e);
  } finally {
    client.release();
  }

  // Durable. Everything below is cache hygiene and must not be able to turn a
  // saved setting into a 500.
  settings.invalidate();
  if (Object.prototype.hasOwnProperty.call(out.raw, 'deposit_pct')) {
    escrow.setDepositPercent(out.raw.deposit_pct, 'admin');
  }

  const fresh = await rawRows().catch(() => null);
  res.json({
    success: true,
    message: `Saved. ${out.diff.length} setting${out.diff.length === 1 ? '' : 's'} changed and applies to the next booking — no restart needed.`,
    data: {
      changed: out.diff,
      sections: fresh ? catalog.describe(fresh) : null,
      overrides: fresh ? catalog.overrides(fresh) : null,
    },
  });
});

/**
 * POST /api/admin/settings/reset
 * Body: `{ keys: ['elo.k_factor', 'commission_pct'] }` — or `{ all: true }`.
 *
 * Why a row is deleted rather than rewritten with the default
 * `settings.get()` treats an absent row as "use the documented default", so no row
 * is the truest possible statement of "not overridden": the day a default changes
 * in `DEFAULTS`, a reset key follows it, while a key rewritten with today's number
 * would be frozen at it forever and look overridden again.
 *
 * A row holding an object is only deleted when every field in it is being reset;
 * otherwise the remaining overrides are merged back and the row stays.
 */
router.post('/settings/reset', async (req, res, next) => {
  const body = req.body || {};
  const all = body.all === true;
  const keys = all
    ? Object.keys(catalog.FIELDS)
    : (Array.isArray(body.keys) ? body.keys.map(String) : []);

  if (!keys.length) return bad(res, 400, 'Name the settings to reset, or pass {all:true}.');
  const unknown = keys.filter((k) => !catalog.FIELDS[k]);
  if (unknown.length) return bad(res, 400, `Unknown setting: ${unknown[0]}`);

  const client = await pool.connect();
  let out;
  try {
    await client.query('BEGIN');
    const rowKeys = [...new Set(Object.values(catalog.FIELDS).map((f) => f.row))];
    await client.query(
      'SELECT key FROM global_settings WHERE key = ANY($1::text[]) FOR UPDATE', [rowKeys],
    );
    const raw = await rawRows(client);

    // Only keys that are overridden are worth touching, so a reset of an
    // untouched key is a no-op rather than a spurious audit row.
    const doing = keys.filter((k) => !catalog.sameValue(catalog.valueOf(k, raw), catalog.defaultOf(k)));
    if (!doing.length) {
      await client.query('ROLLBACK');
      return res.json({
        success: true,
        message: 'Those are already at their defaults.',
        data: { reset: [], sections: catalog.describe(raw), overrides: catalog.overrides(raw) },
      });
    }

    const before = Object.fromEntries(doing.map((k) => [k, catalog.valueOf(k, raw)]));
    const byRow = new Map();
    for (const k of doing) {
      const f = catalog.FIELDS[k];
      if (!byRow.has(f.row)) byRow.set(f.row, []);
      byRow.get(f.row).push(k);
    }

    const deleted = [];
    const rewritten = [];
    for (const [rowKey, fieldKeys] of byRow) {
      const inRow = Object.keys(catalog.FIELDS).filter((k) => catalog.FIELDS[k].row === rowKey);
      const whole = inRow.every((k) => fieldKeys.includes(k));
      if (whole) {
        await client.query('DELETE FROM global_settings WHERE key = $1', [rowKey]);
        deleted.push(rowKey);
        continue;
      }
      const base = raw[rowKey];
      const merged = base && typeof base === 'object' && !Array.isArray(base) ? { ...base } : {};
      for (const k of fieldKeys) {
        const def = catalog.defaultOf(k);
        if (def === undefined) delete merged[catalog.FIELDS[k].path];
        else merged[catalog.FIELDS[k].path] = def;
      }
      await client.query(
        `INSERT INTO global_settings (key, value) VALUES ($1, $2::jsonb)
         ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value`,
        [rowKey, JSON.stringify(merged)],
      );
      rewritten.push(rowKey);
    }

    await audit(client, {
      adminId: req.user.id,
      action: ACTIONS.SETTINGS_RESET,
      entityType: 'settings',
      entityId: null,
      before,
      after: Object.fromEntries(doing.map((k) => [k, catalog.defaultOf(k)])),
      note: `reset ${doing.join(', ')}`,
    });

    await client.query('COMMIT');
    out = { reset: doing, deleted, rewritten };
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    return next(e);
  } finally {
    client.release();
  }

  settings.invalidate();
  if (out.reset.includes('deposit_pct')) {
    escrow.setDepositPercent(catalog.defaultOf('deposit_pct'), 'admin-reset');
  }

  const fresh = await rawRows().catch(() => null);
  res.json({
    success: true,
    message: `Reset ${out.reset.length} setting${out.reset.length === 1 ? '' : 's'} to the documented default.`,
    data: {
      reset: out.reset,
      sections: fresh ? catalog.describe(fresh) : null,
      overrides: fresh ? catalog.overrides(fresh) : null,
    },
  });
});

module.exports = router;
