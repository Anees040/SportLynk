/**
 * reportService.js — S.7 Wave D · FR4.16. The financial export, written once and
 * used by both the owner's report and the platform's.
 *
 * WHY THE MONEY COMES FROM THE LEDGER AND NOT FROM `bookings`
 * `bookings` holds what was AGREED (`total_amount`, `deposit_amount`); the
 * `transactions` rows hold what actually MOVED. Those two disagree in every
 * interesting case: a cancelled booking has a price and no earning, a no-show pays
 * the owner the deposit and nothing else, a checked-in booking pays the full escrow
 * minus whatever the commission percentage was ON THAT DAY. Recomputing from prices
 * would produce a report that looks right and does not reconcile with the wallet the
 * owner is looking at, which is worse than no report. So every money column here is
 * a SUM over `transactions` for that booking, and the only two columns taken from
 * `bookings` are labelled as the agreement, not the outcome.
 *
 * THE FOUR SHAPES `utils/escrow.js` WRITES, read back:
 *   escrow_received      + on the OWNER's wallet   what the venue earned
 *                                                  (check-in release OR forfeited deposit)
 *   platform_commission  - on the OWNER's wallet   SportLynk's cut, taken at check-in
 *   no_show_penalty      - on the PLAYER's wallet  the deposit they lost
 *   refund               + on the PLAYER's wallet  what came back to them
 *
 * ONE FLAT TABLE, NOT SECTIONS. Tournament earnings are a `tournament_commission`
 * row against a tournament rather than a booking, so they could have been a second
 * block under a second header — but a CSV with two header rows cannot be opened as a
 * table by anything (Excel's own pivot included). Instead the first column says which
 * kind of row it is, and a tournament row leaves the booking-only cells empty. One
 * header, one TOTAL, still readable by a human.
 *
 * NO COURT COLUMN. The plan's row spec names one; this schema has no court
 * sub-entity (no `courts` table, no `bookings.court_id`) — a venue IS the bookable
 * surface — so the slot window stands where a court would go rather than emitting a
 * column that is always empty.
 *
 * DATES. Bookings are ranged over `slot_date` (the day the game was played, which is
 * the day an owner means by "August"), tournament rows over the commission
 * transaction's `created_at` (the day the money moved — a tournament has no single
 * slot date). Both bounds are inclusive and both are UTC, per the golden rule.
 */

const { asNum, round2 } = require('../utils/escrow');
const csv = require('../utils/csv');

/** A year and a day. Long enough for "last financial year", short enough to stream. */
const RANGE_MAX_DAYS = 366;

/** Keyset page size. The export is streamed, so this bounds memory, not the result. */
const PAGE = 500;

const RE_DATE = /^\d{4}-\d{2}-\d{2}$/;
const RE_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Statuses whose deposit is still contingent — neither forfeited nor returned yet. */
const PENDING_STATUSES = new Set(['pending', 'confirmed']);

/**
 * Validate `?from&to&venueId&format`. Both dates are REQUIRED and the span is
 * capped: an unbounded export is a table scan of every booking the platform has
 * ever taken, served over a socket that will time out first. Refusing is kinder
 * than a truncated file the owner cannot tell is truncated.
 */
function parseRange(query = {}) {
  const from = String(query.from || '').trim();
  const to = String(query.to || '').trim();
  if (!RE_DATE.test(from) || !RE_DATE.test(to)) {
    return { ok: false, status: 400, message: 'from and to are required as YYYY-MM-DD dates.' };
  }
  const a = Date.parse(`${from}T00:00:00Z`);
  const b = Date.parse(`${to}T00:00:00Z`);
  if (!Number.isFinite(a) || !Number.isFinite(b)) {
    return { ok: false, status: 400, message: 'from and to must be real calendar dates.' };
  }
  if (b < a) {
    return { ok: false, status: 400, message: 'to must not be earlier than from.' };
  }
  const days = Math.round((b - a) / 86_400_000) + 1;
  if (days > RANGE_MAX_DAYS) {
    return {
      ok: false,
      status: 400,
      message: `Range is ${days} days; the maximum is ${RANGE_MAX_DAYS}. Export it in parts.`,
    };
  }

  const venueId = String(query.venueId || '').trim();
  if (venueId && !RE_UUID.test(venueId)) {
    return { ok: false, status: 400, message: 'Invalid venueId.' };
  }

  const fmt = String(query.format || 'csv').trim().toLowerCase();
  if (fmt !== 'csv' && fmt !== 'json') {
    return { ok: false, status: 400, message: "format must be 'csv' or 'json'." };
  }

  return { ok: true, from, to, days, venueId: venueId || null, format: fmt };
}

/**
 * The column list, in file order. `money` cells are `csv.money` formatted (plain
 * two-place decimals — a thousands separator would become a new column); `total`
 * cells are summed into the TOTAL row; `platformOnly` appears only in the
 * all-venues export, where "which owner" is the whole point.
 *
 * `price` and `depositAtRisk` are the AGREEMENT (from `bookings`). Everything after
 * them is what the ledger says actually happened.
 */
const COLUMNS = [
  { key: 'kind', label: 'Type' },
  { key: 'ref', label: 'Reference' },
  { key: 'date', label: 'Date' },
  { key: 'start', label: 'Start' },
  { key: 'end', label: 'End' },
  { key: 'venue', label: 'Venue' },
  { key: 'sport', label: 'Sport' },
  { key: 'owner', label: 'Owner', platformOnly: true },
  { key: 'party', label: 'Player / Team' },
  { key: 'status', label: 'Status' },
  { key: 'price', label: 'Price', money: true, total: true },
  { key: 'depositAtRisk', label: 'Deposit At Risk', money: true, total: true },
  { key: 'gross', label: 'Gross Received', money: true, total: true },
  { key: 'commission', label: 'Commission', money: true, total: true },
  { key: 'net', label: 'Net', money: true, total: true },
  { key: 'depositHeld', label: 'Deposit Held', money: true, total: true },
  { key: 'depositForfeited', label: 'Deposit Forfeited', money: true, total: true },
  { key: 'refunded', label: 'Refunded To Player', money: true, total: true },
  { key: 'settledAt', label: 'Settled At (UTC)' },
];

/** The columns this scope actually emits. */
function columnsFor(scope) {
  return scope === 'platform' ? COLUMNS : COLUMNS.filter((c) => !c.platformOnly);
}

const TOTAL_KEYS = COLUMNS.filter((c) => c.total).map((c) => c.key);

function newTotals() {
  const t = { rows: 0, bookings: 0, tournaments: 0 };
  for (const k of TOTAL_KEYS) t[k] = 0;
  return t;
}

/**
 * Bucket a row under its owner, for the platform report's per-owner subtotals.
 *
 * A row with NO owner on record still gets a bucket, under UNATTRIBUTED, because the
 * alternative is per-owner subtotals that do not add up to the TOTAL row -- and a
 * financial report whose subtotals do not reconcile is one nobody can use. This is
 * not hypothetical: a venue whose owner account was deleted has no owner to bill.
 */
const UNATTRIBUTED = 'unattributed';

function bucketOwner(map, shaped) {
  const key = shaped.ownerId || UNATTRIBUTED;
  if (!map.has(key)) {
    map.set(key, {
      ownerId: shaped.ownerId || null,
      name: shaped.owner || (key === UNATTRIBUTED ? '(no owner on record)' : ''),
      totals: newTotals(),
    });
  }
  const bucket = map.get(key);
  if (!bucket.name && shaped.owner) bucket.name = shaped.owner;
  addTotals(bucket.totals, shaped);
  return bucket;
}

function addTotals(t, shaped) {
  t.rows += 1;
  if (shaped.kind === 'tournament') t.tournaments += 1;
  else t.bookings += 1;
  for (const k of TOTAL_KEYS) t[k] = round2(t[k] + asNum(shaped[k]));
}

/**
 * One keyset page of bookings with their ledger sums.
 *
 * The LATERAL is deliberate: a booking has at most a handful of transactions, and
 * aggregating them per row keeps the report at one row per booking no matter how
 * many money events it produced. A GROUP BY over the join would have to list every
 * selected column and would still need the same CASE arms.
 *
 * The CASE arms mirror `escrow.logTxn`'s four shapes exactly. `platform_commission`
 * and `no_show_penalty` are stored NEGATIVE (they are debits on the wallet they sit
 * on), so both are negated here to read as positive amounts in a report column.
 */
async function bookingPage(db, { from, to, ownerId, venueId, after }) {
  const params = [from, to];
  const where = ['b.slot_date >= $1::date', 'b.slot_date <= $2::date'];
  // `v.owner_id`, NOT `b.owner_id`. The booking's copy is stamped at create time and
  // is NULL on every row written before that column existed (45 of 50 in this
  // database), so scoping by it would silently hide an owner's own older bookings
  // from their own report. `venues.owner_id` is the authority for whose venue it is.
  if (ownerId) { params.push(ownerId); where.push(`v.owner_id = $${params.length}`); }
  if (venueId) { params.push(venueId); where.push(`b.venue_id = $${params.length}`); }
  if (after) {
    params.push(after.date, after.id);
    where.push(`(b.slot_date, b.id) > ($${params.length - 1}::date, $${params.length}::uuid)`);
  }
  params.push(PAGE);

  const { rows } = await db.query(
    `SELECT b.id, b.slot_date, b.start_time, b.end_time, b.status,
            b.total_amount, b.deposit_amount, b.checked_in_at, b.no_show_at, b.cancelled_at,
            COALESCE(b.owner_id, v.owner_id) AS owner_id,
            v.name  AS venue_name, v.sport_type,
            pl.name AS player_name,
            ow.name AS owner_name,
            COALESCE(t.gross, 0)      AS gross,
            COALESCE(t.commission, 0) AS commission,
            COALESCE(t.forfeited, 0)  AS forfeited,
            COALESCE(t.refunded, 0)   AS refunded
       FROM bookings b
       JOIN venues v  ON v.id = b.venue_id
       LEFT JOIN users pl ON pl.id = b.player_id
       LEFT JOIN users ow ON ow.id = COALESCE(b.owner_id, v.owner_id)
       LEFT JOIN LATERAL (
         SELECT SUM(CASE WHEN tx.type = 'escrow_received'     AND tx.user_id = COALESCE(b.owner_id, v.owner_id) THEN  tx.amount ELSE 0 END) AS gross,
                SUM(CASE WHEN tx.type = 'platform_commission' AND tx.user_id = COALESCE(b.owner_id, v.owner_id) THEN -tx.amount ELSE 0 END) AS commission,
                SUM(CASE WHEN tx.type = 'refund'              AND tx.user_id = b.player_id THEN  tx.amount ELSE 0 END) AS refunded,
                -- Two shapes forfeit a deposit, and only two. no_show_penalty always
                -- does. escrow_release does ONLY on a cancelled booking, where it is
                -- the late-cancellation slice moving to the venue -- at check-in the
                -- SAME type and sign means the full price being paid for a game that
                -- was played, which is not a forfeit and must not be counted as one.
                SUM(CASE WHEN tx.type = 'no_show_penalty' AND tx.user_id = b.player_id THEN -tx.amount ELSE 0 END)
              + SUM(CASE WHEN tx.type = 'escrow_release'  AND tx.user_id = b.player_id
                          AND b.status = 'cancelled'                                   THEN -tx.amount ELSE 0 END) AS forfeited
           FROM transactions tx
          WHERE tx.booking_id = b.id
       ) t ON TRUE
      WHERE ${where.join(' AND ')}
      ORDER BY b.slot_date, b.id
      LIMIT $${params.length}`,
    params,
  );
  return rows;
}

/**
 * A booking row, shaped for both formats.
 *
 * `depositHeld` is the one derived cell: while a booking is still pending or
 * confirmed the at-risk deposit has neither been forfeited nor returned, so it sits
 * in the player's frozen balance and belongs in a column of its own. Once the
 * booking reaches any terminal status the number is zero and the money is in either
 * `depositForfeited` or `refunded` — so the three columns never double-count.
 */
function shapeBooking(r) {
  const gross = round2(asNum(r.gross));
  const commission = round2(asNum(r.commission));
  const settledAt = r.checked_in_at || r.no_show_at || r.cancelled_at || null;
  return {
    kind: 'booking',
    ref: r.id,
    date: csv.isoDate(r.slot_date),
    start: csv.hhmm(r.start_time),
    end: csv.hhmm(r.end_time),
    venue: r.venue_name || '',
    sport: r.sport_type || '',
    owner: r.owner_name || '',
    ownerId: r.owner_id || null,
    party: r.player_name || '',
    status: r.status || '',
    price: round2(asNum(r.total_amount)),
    depositAtRisk: round2(asNum(r.deposit_amount)),
    gross,
    commission,
    net: round2(gross - commission),
    depositHeld: PENDING_STATUSES.has(String(r.status))
      ? round2(asNum(r.deposit_amount))
      : 0,
    depositForfeited: round2(asNum(r.forfeited)),
    refunded: round2(asNum(r.refunded)),
    settledAt: settledAt ? new Date(settledAt).toISOString().replace('T', ' ').slice(0, 19) : '',
  };
}

/**
 * Tournament earnings. One row per `tournament_commission` transaction — the venue
 * cost plus the organiser's margin, credited the moment fixtures are generated (see
 * the four-event ledger table in `services/tournamentService.js`).
 *
 * There is no commission-on-commission: SportLynk's `commission_pct` applies to
 * bookings at check-in, and a tournament's slots are booked by the organiser
 * themselves, so `commission` is 0 here and `net` equals `gross`. Saying that with a
 * zero rather than an empty cell is the honest version.
 */
async function tournamentRows(db, { from, to, ownerId, venueId }) {
  const params = [from, to];
  const where = [
    "tx.type = 'tournament_commission'",
    'tx.tournament_id IS NOT NULL',
    'tx.created_at >= $1::date',
    "tx.created_at < ($2::date + INTERVAL '1 day')",
  ];
  if (ownerId) { params.push(ownerId); where.push(`tx.user_id = $${params.length}`); }
  if (venueId) { params.push(venueId); where.push(`tn.venue_id = $${params.length}`); }

  const { rows } = await db.query(
    `SELECT tx.id, tx.created_at, tx.amount, tx.tournament_id, tx.user_id,
            tn.name AS tournament_name, tn.sport, tn.start_date,
            v.name  AS venue_name,
            ow.name AS owner_name
       FROM transactions tx
       JOIN tournaments tn ON tn.id = tx.tournament_id
       LEFT JOIN venues v  ON v.id = tn.venue_id
       LEFT JOIN users ow  ON ow.id = tx.user_id
      WHERE ${where.join(' AND ')}
      ORDER BY tx.created_at, tx.id`,
    params,
  );
  return rows;
}

function shapeTournament(r) {
  const gross = round2(asNum(r.amount));
  return {
    kind: 'tournament',
    ref: r.tournament_id,
    date: csv.isoDate(r.created_at),
    start: '',
    end: '',
    venue: r.venue_name || '',
    sport: r.sport || '',
    owner: r.owner_name || '',
    ownerId: r.user_id || null,
    party: r.tournament_name || '',
    status: 'entry fees',
    price: 0,
    depositAtRisk: 0,
    gross,
    commission: 0,
    net: gross,
    depositHeld: 0,
    depositForfeited: 0,
    refunded: 0,
    settledAt: r.created_at
      ? new Date(r.created_at).toISOString().replace('T', ' ').slice(0, 19)
      : '',
  };
}

/**
 * Walk every row of the report exactly once, in file order, calling `onRow`.
 *
 * Bookings are paged by keyset (`(slot_date, id) > (…)`) rather than OFFSET so a
 * long export cannot skip or repeat a row when another booking is confirmed
 * mid-stream, and so page N costs the same as page 1. Tournament rows are a single
 * small read appended after them: there are at most a few dozen in a year, and
 * interleaving them by date would mean holding both result sets open to merge.
 */
async function eachRow(db, opts, onRow) {
  let after = null;
  for (;;) {
    const page = await bookingPage(db, { ...opts, after });
    for (const r of page) await onRow(shapeBooking(r));
    if (page.length < PAGE) break;
    const last = page[page.length - 1];
    after = { date: csv.isoDate(last.slot_date), id: last.id };
  }
  for (const r of await tournamentRows(db, opts)) await onRow(shapeTournament(r));
}

/** The cells for one row, in this scope's column order. */
function cellsFor(shaped, cols) {
  return cols.map((c) => (c.money ? csv.money(shaped[c.key]) : shaped[c.key] ?? ''));
}

/**
 * A summary row (TOTAL, or a per-owner subtotal). Only the totalled money cells are
 * filled; every other cell is left EMPTY rather than repeated, so a reader scanning
 * the last rows cannot mistake a subtotal for another booking.
 */
function summaryRow(cols, totals, label, ownerName) {
  return cols.map((c) => {
    if (c.key === 'kind') return label;
    if (c.key === 'owner' && ownerName) return ownerName;
    if (c.key === 'party') {
      return `${totals.rows} rows (${totals.bookings} bookings, ${totals.tournaments} tournament payouts)`;
    }
    if (c.total) return csv.money(totals[c.key]);
    return '';
  });
}

/**
 * Stream the report as CSV into `sink` (the `res` object in the route — this is why
 * it writes per row instead of building a string: a year of a busy venue is tens of
 * thousands of rows, and holding the whole file in memory to send it is the one
 * mistake that turns a report into an outage).
 *
 * Returns the totals so the route can log or assert on them.
 */
async function streamCsv(db, opts, sink) {
  const cols = columnsFor(opts.scope);
  const totals = newTotals();
  const byOwner = new Map();

  // The BOM must be the very first bytes or Excel-on-Windows reads UTF-8 as
  // cp1252 and every Urdu name and every em dash in a venue title is mojibake.
  sink.write(csv.BOM);
  sink.write(csv.row(cols.map((c) => c.label)));

  await eachRow(db, opts, (shaped) => {
    addTotals(totals, shaped);
    if (opts.scope === 'platform') bucketOwner(byOwner, shaped);
    sink.write(csv.row(cellsFor(shaped, cols)));
  });

  if (opts.scope === 'platform' && byOwner.size) {
    const owners = [...byOwner.values()].sort((a, b) => b.totals.commission - a.totals.commission);
    for (const o of owners) sink.write(csv.row(summaryRow(cols, o.totals, 'OWNER TOTAL', o.name)));
  }
  sink.write(csv.row(summaryRow(cols, totals, 'TOTAL', '')));
  return totals;
}

/**
 * The same walk, collected into JSON for the Flutter preview. `rows` is capped: the
 * screen shows totals and the first page, and the CSV is the artefact for anything
 * longer. `truncated` says so out loud rather than letting a preview quietly
 * disagree with the file the owner downloads.
 */
const JSON_ROW_CAP = 500;

async function collectJson(db, opts) {
  const totals = newTotals();
  const byOwner = new Map();
  const rows = [];

  await eachRow(db, opts, (shaped) => {
    addTotals(totals, shaped);
    if (opts.scope === 'platform') bucketOwner(byOwner, shaped);
    if (rows.length < JSON_ROW_CAP) rows.push(shaped);
  });

  const out = {
    range: { from: opts.from, to: opts.to, days: opts.days },
    columns: columnsFor(opts.scope).map((c) => ({ key: c.key, label: c.label, money: Boolean(c.money) })),
    totals,
    rows,
    truncated: totals.rows > rows.length,
  };
  if (opts.scope === 'platform') {
    out.byOwner = [...byOwner.values()]
      .sort((a, b) => b.totals.commission - a.totals.commission)
      .map((o) => ({ ownerId: o.ownerId, name: o.name, ...o.totals }));
  }
  return out;
}

/** `sportlynk-financial-2026-01-01-to-2026-08-31.csv`, already header-safe. */
function filenameFor(opts) {
  const stem = opts.scope === 'platform' ? 'sportlynk-platform' : 'sportlynk-financial';
  return csv.safeFilename(`${stem}-${opts.from}-to-${opts.to}.csv`);
}

module.exports = {
  RANGE_MAX_DAYS,
  JSON_ROW_CAP,
  COLUMNS,
  columnsFor,
  parseRange,
  eachRow,
  streamCsv,
  collectJson,
  filenameFor,
  shapeBooking,
  shapeTournament,
  newTotals,
  addTotals,
  bucketOwner,
  UNATTRIBUTED,
};
