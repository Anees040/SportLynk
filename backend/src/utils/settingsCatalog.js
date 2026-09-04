/**
 * What each global setting is -- where it lives, its type, the range a write may
 * use, and the sentence an admin reads next to it -- plus the validator that
 * guards `PUT /api/admin/settings`.
 *
 * Why this is a separate file from `globalSettings.js`
 * `globalSettings.js` is on the hot path: every booking, every rating, every
 * Scout turn reads it, and its job is to answer fast and never throw. It
 * therefore clamps -- a k_factor of 900 quietly falls back to 32 and the app
 * keeps working. That is right for a read and wrong for a write: an admin who
 * types 900, is shown "saved", and then watches ratings move by 32 has been lied
 * to by their own admin panel.
 *
 * So a write is REJECTED with a named range instead, and the ranges live here.
 *
 * The invariant that matters (asserted by check_admin.js)
 * every field's [min, max] is a subset of the clamp its accessor applies.
 * Anything this file accepts therefore survives the accessor byte-for-byte -- a
 * saved value can never be silently rewritten on the next read. Where the two
 * differ it is deliberate and one-directional: `k_factor` reads 1..200 (tolerating
 * a row written by hand in SQL long before this file existed) but only accepts
 * 8..64 from an admin, because a K of 1 freezes the ladder and a K of 200 makes
 * one friendly worth a season. Never the other way round.
 *
 * Why the LABELS and descriptions are server-side
 * The admin screen renders whatever this file sends, so a key added later
 * appears in the app -- correctly labelled, correctly bounded -- with no
 * client change and no release. The alternative is a Dart const map that drifts
 * out of step with what the server enforces, which is exactly the class
 * of bug where the UI offers a range the API refuses.
 *
 * Shape of the store
 * `global_settings` is `(key text, value jsonb)` with seven rows, one per
 * top-level key; five of them hold an object. A field is therefore addressed as
 * `row.path` ('elo.k_factor') or bare when the row is the value
 * ('commission_pct'). `isOverridden` is a value comparison against DEFAULTS, not
 * "does a row exist" -- the seed wrote all seven rows on day one.
 */

const { DEFAULTS } = require('./globalSettings');

/** Section order, exactly as the admin screen shows it. */
const SECTIONS = [
  { key: 'money', label: 'Commission & deposits', hint: 'The platform’s cut, and how much a player puts at risk.' },
  { key: 'sports', label: 'Sports', hint: 'Switch a sport off to stop new venues and new bookings for it.' },
  { key: 'elo', label: 'Ratings (ELO)', hint: 'How far one match can move a team’s rating.' },
  { key: 'match', label: 'Matches & disputes', hint: 'Challenge windows, result deadlines, and when a rating freezes.' },
  { key: 'tournament', label: 'Tournament defaults', hint: 'Copied onto a NEW tournament. Existing tournaments keep their own numbers.' },
  { key: 'assistant', label: 'Scout (AI assistant)', hint: 'How confident the intent model must be before Scout acts.' },
];

/**
 * Every writable field. `row` is the `global_settings.key`; `path` is the property
 * inside that row's object, or null when the row itself is the value.
 *
 * `type`: 'int' | 'number' | 'bool' | 'text' | 'sports'.
 * `min`/`max` bound the write (see the invariant above). `readClamp` records the
 * accessor's own band so the check script can assert the subset relationship
 * rather than take this comment's word for it.
 */
const FIELDS = {
  commission_pct: {
    row: 'commission_pct', path: null, section: 'money',
    type: 'number', min: 0, max: 50, step: 0.5, unit: '%', readClamp: [0, 50],
    label: 'Platform commission',
    description: 'Taken from the venue owner’s earnings when a booking is checked in. The player never pays it, and it is 0 by default.',
  },
  deposit_pct: {
    row: 'deposit_pct', path: null, section: 'money',
    type: 'number', min: 0, max: 100, step: 5, unit: '%', readClamp: [0, 100],
    label: 'At-risk deposit',
    description: 'The share of the slot price a player forfeits on a no-show. Applies to NEW bookings only — an existing booking keeps the amount it was created with.',
  },
  sports_enabled: {
    row: 'sports_enabled', path: null, section: 'sports',
    type: 'sports', readClamp: null,
    label: 'Sports accepted',
    description: 'A sport switched off stops new venues and new bookings for it. Bookings already confirmed are honoured.',
  },
  'elo.base': {
    row: 'elo', path: 'base', section: 'elo',
    type: 'int', min: 800, max: 2000, step: 50, readClamp: [100, 5000],
    label: 'Starting rating',
    description: 'The rating a brand-new team begins at. Changing it does not move any existing team.',
  },
  'elo.k_factor': {
    row: 'elo', path: 'k_factor', section: 'elo',
    type: 'int', min: 8, max: 64, step: 2, readClamp: [1, 200],
    label: 'K-factor',
    description: 'How far one match can move a rating. 32 is the chess standard: lower is steadier, higher is more reactive.',
  },
  'match.challenge_ttl_hours': {
    row: 'match', path: 'challenge_ttl_hours', section: 'match',
    type: 'int', min: 1, max: 168, step: 1, unit: 'h', readClamp: [1, 720],
    label: 'Challenge expiry',
    description: 'How long an unanswered challenge stays open before it expires by itself.',
  },
  'match.dispute_window_hours': {
    row: 'match', path: 'dispute_window_hours', section: 'match',
    type: 'int', min: 1, max: 168, step: 1, unit: 'h', readClamp: [1, 720],
    label: 'Dispute window',
    description: 'How long after a result a captain may still dispute it.',
  },
  'match.dispute_freeze_ratio': {
    row: 'match', path: 'dispute_freeze_ratio', section: 'match',
    type: 'number', min: 0.05, max: 1, step: 0.05, readClamp: [0.01, 1],
    label: 'Rating-freeze threshold',
    description: 'Freeze a team’s rating once this share of its recent matches is disputed (0.3 = three in ten).',
  },
  'match.dispute_freeze_min': {
    row: 'match', path: 'dispute_freeze_min', section: 'match',
    type: 'int', min: 1, max: 50, step: 1, readClamp: [1, 1000],
    label: 'Minimum disputes to freeze',
    description: 'The threshold above never fires below this many disputes, so one argument cannot freeze a new team.',
  },
};

Object.assign(FIELDS, {
  'tournament.min_teams': {
    row: 'tournament', path: 'min_teams', section: 'tournament',
    type: 'int', min: 2, max: 32, step: 1, readClamp: [2, 32],
    label: 'Minimum teams',
    description: 'Below this a new tournament cannot start.',
  },
  'tournament.prize_percent': {
    row: 'tournament', path: 'prize_percent', section: 'tournament',
    type: 'int', min: 0, max: 100, step: 5, unit: '%', readClamp: [0, 100],
    label: 'Prize pool share',
    description: 'The share of entry fees paid out as prizes. The rest is the venue owner’s earnings.',
  },
  'tournament.winner_percent': {
    row: 'tournament', path: 'winner_percent', section: 'tournament',
    type: 'int', min: 0, max: 100, step: 5, unit: '%', readClamp: [0, 100],
    label: 'Winner’s share of the pool',
    description: 'Must total 100 with the runner-up’s share — the accessor falls back to 70/30 otherwise, so a write that does not add up is refused here.',
    pairsWith: 'tournament.runnerup_percent',
  },
  'tournament.runnerup_percent': {
    row: 'tournament', path: 'runnerup_percent', section: 'tournament',
    type: 'int', min: 0, max: 100, step: 5, unit: '%', readClamp: [0, 100],
    label: 'Runner-up’s share of the pool',
    description: 'Must total 100 with the winner’s share.',
    pairsWith: 'tournament.winner_percent',
  },
  'tournament.venue_discount_percent': {
    row: 'tournament', path: 'venue_discount_percent', section: 'tournament',
    type: 'int', min: 0, max: 100, step: 5, unit: '%', readClamp: [0, 100],
    label: 'Venue slot discount',
    description: 'Discount applied to the owner’s own slots when they block them out for a tournament.',
  },
  'tournament.slot_minutes': {
    row: 'tournament', path: 'slot_minutes', section: 'tournament',
    type: 'int', min: 15, max: 240, step: 15, unit: 'min', readClamp: [15, 240],
    label: 'Fixture length',
    description: 'How long one fixture occupies a slot when the bracket is scheduled.',
  },
  'tournament.round_gap_days': {
    row: 'tournament', path: 'round_gap_days', section: 'tournament',
    type: 'int', min: 0, max: 30, step: 1, unit: 'd', readClamp: [0, 30],
    label: 'Days between rounds',
    description: '0 plays the whole cup on one date.',
  },
  'tournament.round_rest_minutes': {
    row: 'tournament', path: 'round_rest_minutes', section: 'tournament',
    type: 'int', min: 0, max: 1440, step: 15, unit: 'min', readClamp: [0, 1440],
    label: 'Rest between a team’s fixtures',
    description: 'The minimum gap the scheduler leaves a team on a same-day round.',
  },
  'tournament.max_knockout_teams': {
    row: 'tournament', path: 'max_knockout_teams', section: 'tournament',
    type: 'int', min: 2, max: 32, step: 2, readClamp: [2, 32],
    label: 'Largest knockout bracket',
    description: 'The most teams a knockout tournament may accept.',
  },
  'tournament.max_round_robin_teams': {
    row: 'tournament', path: 'max_round_robin_teams', section: 'tournament',
    type: 'int', min: 2, max: 12, step: 1, readClamp: [2, 12],
    label: 'Largest round-robin group',
    description: 'Round robin is n(n-1)/2 fixtures, so this stays small on purpose.',
  },
  'tournament.target_margin_percent': {
    row: 'tournament', path: 'target_margin_percent', section: 'tournament',
    type: 'int', min: 0, max: 200, step: 5, unit: '%', readClamp: [0, 200],
    label: 'Owner margin target',
    description: 'Used only to RECOMMEND an entry fee in the create preview. The owner still types the fee.',
  },
  'tournament.k_early': {
    row: 'tournament', path: 'k_early', section: 'tournament',
    type: 'int', min: 8, max: 80, step: 2, readClamp: [1, 200],
    label: 'K-factor — early rounds',
    description: 'Tournament fixtures rate harder than friendlies. This overrides the global K for early rounds.',
  },
  'tournament.k_semi': {
    row: 'tournament', path: 'k_semi', section: 'tournament',
    type: 'int', min: 8, max: 80, step: 2, readClamp: [1, 200],
    label: 'K-factor — semi-finals',
    description: 'As above, for a semi-final.',
  },
  'tournament.k_final': {
    row: 'tournament', path: 'k_final', section: 'tournament',
    type: 'int', min: 8, max: 80, step: 2, readClamp: [1, 200],
    label: 'K-factor — final',
    description: 'As above, for the final.',
  },
  'assistant.confidence_floor': {
    row: 'assistant', path: 'confidence_floor', section: 'assistant',
    type: 'number', min: 0.05, max: 0.95, step: 0.05, readClamp: [0.05, 0.95],
    label: 'Intent confidence floor',
    description: 'Below this Scout shows its capability menu instead of guessing. A MIRROR of the model’s own threshold, not the authority on it.',
  },
  'assistant.escalation_enabled': {
    row: 'assistant', path: 'escalation_enabled', section: 'assistant',
    type: 'bool', readClamp: null,
    label: 'Offer human help',
    description: 'When Scout cannot help, offer to hand the conversation to support.',
  },
  'assistant.name': {
    row: 'assistant', path: 'name', section: 'assistant',
    type: 'text', maxLen: 40, readClamp: null,
    label: 'Assistant name',
    description: 'What the assistant calls itself in its own replies.',
  },
});

/** Row keys that hold an object; the rest are the value. */
const OBJECT_ROWS = Object.freeze(['elo', 'match', 'tournament', 'assistant', 'sports_enabled']);

/** The documented default for one field, dug out of the frozen DEFAULTS tree. */
function defaultOf(key) {
  const f = FIELDS[key];
  if (!f) return undefined;
  const d = DEFAULTS[f.row];
  if (!f.path) return d;
  return d && typeof d === 'object' ? d[f.path] : undefined;
}

/** The stored (or defaulted) value for one field, given the raw jsonb rows. */
function valueOf(key, rawByRow) {
  const f = FIELDS[key];
  if (!f) return undefined;
  const raw = rawByRow[f.row];
  if (raw === undefined || raw === null) return defaultOf(key);
  if (!f.path) return raw;
  if (typeof raw !== 'object' || Array.isArray(raw)) return defaultOf(key);
  return Object.prototype.hasOwnProperty.call(raw, f.path) ? raw[f.path] : defaultOf(key);
}

/** Same shape as `valueOf`, for every field. Used by `validate` as the baseline. */
function flatten(rawByRow) {
  const out = {};
  for (const key of Object.keys(FIELDS)) out[key] = valueOf(key, rawByRow);
  return out;
}

function sameValue(a, b) {
  if (a === b) return true;
  if (typeof a === 'number' && typeof b === 'number') return Math.abs(a - b) < 1e-9;
  if (a && b && typeof a === 'object' && typeof b === 'object') {
    return JSON.stringify(sortedKeys(a)) === JSON.stringify(sortedKeys(b));
  }
  return false;
}

function sortedKeys(o) {
  if (!o || typeof o !== 'object' || Array.isArray(o)) return o;
  const out = {};
  for (const k of Object.keys(o).sort()) out[k] = o[k];
  return out;
}

/**
 * The whole settings surface as the admin screen wants it: sections, each with its
 * fields, each field carrying the effective value (what the app will use)
 * beside its default.
 *
 * `isOverridden` compares values rather than checking for a row, because the seed
 * migration wrote all seven rows with the defaults already in them. "Overridden"
 * has to mean "differs from what the code documents", or every field would wear
 * the badge from day one and the badge would mean nothing.
 */
function describe(rawByRow) {
  const flat = flatten(rawByRow);
  return SECTIONS.map((s) => ({
    ...s,
    fields: Object.keys(FIELDS)
      .filter((k) => FIELDS[k].section === s.key)
      .map((k) => {
        const f = FIELDS[k];
        const def = defaultOf(k);
        return {
          key: k,
          label: f.label,
          description: f.description,
          type: f.type,
          unit: f.unit || null,
          step: f.step ?? null,
          min: f.min ?? null,
          max: f.max ?? null,
          maxLen: f.maxLen ?? null,
          pairsWith: f.pairsWith || null,
          value: flat[k] === undefined ? def : flat[k],
          default: def,
          isOverridden: !sameValue(flat[k], def),
          // Every setting here applies to the next operation: the accessor's cache
          // is dropped by `invalidate()` in the same request that writes the row.
          restartRequired: false,
        };
      }),
  }));
}

/** A sport name normalised the way `isSportEnabled` normalises it. */
function normSport(s) {
  return String(s || '').trim().toLowerCase();
}

/**
 * Coerce and bounds-check one field. Returns `{ok, value}` or `{ok:false, message}`.
 * The message names the range, because "invalid value" tells an admin nothing about
 * what to type instead.
 */
function coerce(key, raw) {
  const f = FIELDS[key];
  if (!f) return { ok: false, message: 'Unknown setting.' };

  if (f.type === 'bool') {
    if (typeof raw === 'boolean') return { ok: true, value: raw };
    if (raw === 'true' || raw === 'false') return { ok: true, value: raw === 'true' };
    return { ok: false, message: 'Must be true or false.' };
  }

  if (f.type === 'text') {
    const s = String(raw ?? '').trim();
    if (!s) return { ok: false, message: 'Cannot be empty.' };
    if (s.length > (f.maxLen || 200)) {
      return { ok: false, message: `Keep it to ${f.maxLen || 200} characters or fewer.` };
    }
    return { ok: true, value: s };
  }

  if (f.type === 'sports') {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
      return { ok: false, message: 'Expected a map of sport → on/off.' };
    }
    const out = {};
    for (const [k, v] of Object.entries(raw)) {
      const name = normSport(k);
      // A sport name is a key other tables store as text; refusing junk here keeps
      // `venues.sport_type` and this map talking about the same strings.
      if (!/^[a-z][a-z0-9 _-]{1,29}$/.test(name)) {
        return { ok: false, message: `"${k}" is not a usable sport name.` };
      }
      out[name] = v !== false;
    }
    if (!Object.keys(out).length) return { ok: false, message: 'Name at least one sport.' };
    if (!Object.values(out).some(Boolean)) {
      return { ok: false, message: 'At least one sport has to stay switched on — otherwise nothing on SportLynk can be booked.' };
    }
    return { ok: true, value: out };
  }

  const n = typeof raw === 'number' ? raw : Number.parseFloat(String(raw));
  if (!Number.isFinite(n)) return { ok: false, message: 'Must be a number.' };
  if (f.type === 'int' && Math.abs(n - Math.round(n)) > 1e-9) {
    return { ok: false, message: 'Must be a whole number.' };
  }
  const v = f.type === 'int' ? Math.round(n) : Math.round(n * 1e6) / 1e6;
  if (v < f.min || v > f.max) {
    const u = f.unit || '';
    return { ok: false, message: `Must be between ${f.min}${u} and ${f.max}${u}.` };
  }
  return { ok: true, value: v };
}

/**
 * Validate a whole patch and turn it into the rows to write.
 *
 * `patch`    flat `{ 'elo.k_factor': 40, sports_enabled: {...} }` from the request.
 * `rawByRow` the current jsonb rows, so cross-field rules can see the values the
 *            admin did not send and the returned rows can be a merge rather than a
 *            replace -- sending `{k_factor: 40}` must not delete `base`.
 *
 * Returns `{ok, errors:[{key,message}], rows:{key:value}, diff:[{key,from,to}]}`.
 * `rows` is empty when nothing changed, which is how the route avoids
 * writing an audit row for a no-op save.
 */
function validate(patch, rawByRow) {
  const errors = [];
  const current = flatten(rawByRow);
  const next = { ...current };
  const diff = [];

  if (!patch || typeof patch !== 'object' || Array.isArray(patch)) {
    return { ok: false, errors: [{ key: null, message: 'Expected an object of settings.' }], rows: {}, diff: [] };
  }

  for (const [key, raw] of Object.entries(patch)) {
    if (!FIELDS[key]) {
      // Named rather than ignored: a typo'd key that vanishes silently is how an
      // admin comes to believe they changed something they did not.
      errors.push({ key, message: 'Unknown setting.' });
      continue;
    }
    const c = coerce(key, raw);
    if (!c.ok) { errors.push({ key, message: c.message }); continue; }
    next[key] = c.value;
  }

  // Cross-field rules
  // Checked against `next`, so they hold for the state after the save whether or
  // not the admin sent both halves in this request.

  // The platform cannot take more than exists. Commission comes out of the owner's
  // earnings and the deposit out of the player's escrow, so together over 100% of
  // the slot price means one of them is being paid with money nobody has.
  const comm = Number(next.commission_pct);
  const dep = Number(next.deposit_pct);
  if (Number.isFinite(comm) && Number.isFinite(dep) && comm + dep > 100) {
    errors.push({
      key: 'commission_pct',
      message: `Commission (${comm}%) plus the deposit (${dep}%) comes to ${Math.round((comm + dep) * 100) / 100}% of the slot price. Together they cannot exceed 100%.`,
    });
  }

  // `globalSettings.tournament()` silently reverts both to 70/30 when they do not
  // total 100. Rejecting here is the difference between an error and a lie.
  const w = Number(next['tournament.winner_percent']);
  const r = Number(next['tournament.runnerup_percent']);
  if (Number.isFinite(w) && Number.isFinite(r) && w + r !== 100) {
    errors.push({
      key: 'tournament.winner_percent',
      message: `Winner ${w}% + runner-up ${r}% must total 100% (currently ${w + r}%).`,
    });
  }

  if (Number.isFinite(Number(next['tournament.min_teams']))
    && Number.isFinite(Number(next['tournament.max_knockout_teams']))
    && Number(next['tournament.min_teams']) > Number(next['tournament.max_knockout_teams'])) {
    errors.push({
      key: 'tournament.min_teams',
      message: `The minimum (${next['tournament.min_teams']}) cannot be above the largest knockout bracket (${next['tournament.max_knockout_teams']}).`,
    });
  }

  if (errors.length) return { ok: false, errors, rows: {}, diff: [] };

  // Build the rows to write
  const touchedRows = new Set();
  for (const key of Object.keys(patch)) {
    if (!FIELDS[key]) continue;
    if (sameValue(next[key], current[key])) continue;
    diff.push({ key, from: current[key], to: next[key], label: FIELDS[key].label });
    touchedRows.add(FIELDS[key].row);
  }

  const rows = {};
  for (const rowKey of touchedRows) {
    const base = rawByRow[rowKey];
    if (!OBJECT_ROWS.includes(rowKey)) {
      // Scalar row: the field is the row.
      const only = Object.keys(FIELDS).find((k) => FIELDS[k].row === rowKey);
      rows[rowKey] = next[only];
      continue;
    }
    const merged = base && typeof base === 'object' && !Array.isArray(base) ? { ...base } : {};
    if (rowKey === 'sports_enabled') {
      rows[rowKey] = next.sports_enabled;
      continue;
    }
    for (const k of Object.keys(FIELDS)) {
      const f = FIELDS[k];
      if (f.row !== rowKey || !f.path) continue;
      // Only write paths this file knows. A key some later migration added to the
      // row and this catalog has not caught up with is left exactly as it was
      // rather than dropped -- a merge, not a replace.
      if (next[k] !== undefined) merged[f.path] = next[k];
    }
    rows[rowKey] = merged;
  }

  return { ok: true, errors: [], rows, diff };
}

/** Fields whose stored value differs from the documented default. */
function overrides(rawByRow) {
  const flat = flatten(rawByRow);
  return Object.keys(FIELDS).filter((k) => !sameValue(flat[k], defaultOf(k)));
}

module.exports = {
  SECTIONS, FIELDS, OBJECT_ROWS,
  describe, validate, coerce, flatten, valueOf, defaultOf, overrides, sameValue, normSport,
};
