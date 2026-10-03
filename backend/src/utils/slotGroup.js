/**
 * slotGroup.js — the rules that decide whether a set of slots may be booked as one
 * group, and what that group costs, with no database attached.
 *
 * Why this is a separate module
 * services/bookingService.js requires db/pool at module load, which opens a
 * connection, so anything defined there cannot be exercised by a unit test that is
 * supposed to run with no network. The arithmetic that decides a player's price is
 * exactly the arithmetic that most needs testing without one. Same split, and the
 * same reason, as utils/slotGrid.js.
 *
 * What is here and what deliberately is not
 * Here: whether slots are genuinely consecutive, which discount tier applies, and
 * what one slot costs after it. Not here: any movement of money. The escrow, the
 * deposit, the ledger rows and the wallet locks stay in utils/escrow.js and
 * services/bookingService.js, which remain the only implementation of "money moved
 * for a booking" (FR8.15). This module answers questions; it does not act.
 *
 * The discount is applied per slot, not to a group total
 * Each booking row carries its own escrow, deposit and refund, so each row's price
 * has to stand on its own. Discounting per row and summing is therefore the only
 * arrangement where the group's total and the ledger cannot disagree: the total IS
 * the sum of the rows. A group-level total computed separately would be a second
 * number to keep in step, and the first time rounding moved it the receipt and the
 * wallet would differ.
 */

/**
 * The most slots one booking group may cover.
 *
 * Eight is a long evening at the shortest slot length and half a day at the
 * longest. The ceiling exists because a group is created as N real bookings inside
 * one transaction, each taking a row lock and a wallet lock: an unbounded N is an
 * unbounded transaction holding unbounded locks, and a player who can select
 * forty-eight slots can hold a venue's entire week open while they decide.
 */
const MAX_GROUP_SLOTS = 8;

/** Mirrors the CHECK on venue_slot_discounts.percent (migration 035). */
const MAX_DISCOUNT_PERCENT = 50;

/** Mirrors the CHECK on venue_slot_discounts.min_slots (migration 035). */
const MIN_DISCOUNT_SLOTS = 2;
const MAX_DISCOUNT_SLOTS = 12;

/** The 24:00:00 end-of-day marker utils/slotGrid.js writes (see hhmmss). */
const END_OF_DAY = '24:00:00';
const START_OF_DAY = '00:00:00';

const DAY_MS = 24 * 60 * 60 * 1000;

/** pg hands a DATE back as a Date object; bookings store PKT wall-clock text. */
function dateStr(value) {
  if (value instanceof Date) return value.toLocaleDateString('en-CA');
  return String(value == null ? '' : value);
}

/** A TIME column, normalised to 'HH:MM:SS' so two of them can be compared. */
function timeStr(value) {
  const raw = String(value == null ? '' : value).trim();
  const m = /^(\d{1,2}):(\d{2})(?::(\d{2}))?$/.exec(raw);
  if (!m) return raw;
  return `${m[1].padStart(2, '0')}:${m[2]}:${m[3] || '00'}`;
}

/**
 * One slot row reduced to the four fields these rules read.
 *
 * Accepts the row shape the slots table returns, so a caller passes query rows
 * straight in rather than mapping them first and getting the field names wrong.
 */
function normaliseSlot(row = {}) {
  return {
    id: String(row.id == null ? '' : row.id),
    date: dateStr(row.slot_date),
    start: timeStr(row.start_time),
    end: timeStr(row.end_time),
    price: Number(row.price),
    status: row.status == null ? null : String(row.status),
  };
}

/** Chronological, which is also the order every caller must take row locks in. */
function sortSlots(slots) {
  return [...slots].sort((a, b) => (
    a.date === b.date ? a.start.localeCompare(b.start) : a.date.localeCompare(b.date)
  ));
}

/** Whole days between two 'YYYY-MM-DD' strings, or null when either is unreadable. */
function daysBetween(a, b) {
  const from = Date.parse(`${a}T00:00:00Z`);
  const to = Date.parse(`${b}T00:00:00Z`);
  if (!Number.isFinite(from) || !Number.isFinite(to)) return null;
  return Math.round((to - from) / DAY_MS);
}

/**
 * Do these slots form one unbroken run of playing time?
 *
 * Each slot must begin exactly where the previous one ended. Two cases qualify:
 *
 *   - same date, `previous.end === next.start`;
 *   - consecutive dates, where the previous slot ends at the 24:00:00 marker and
 *     the next begins at 00:00:00. This is the midnight seam of a venue whose
 *     hours run past it, and refusing it would mean a ground open 18:00-02:00
 *     could not sell 23:00 and 00:00 together — the two hours it most wants to.
 *
 * Anything else is a gap, an overlap, or a different day, and is refused. The
 * reason is returned rather than thrown so a route can quote it to the player.
 */
function checkConsecutive(slots) {
  const rows = sortSlots(slots);
  for (let i = 1; i < rows.length; i += 1) {
    const prev = rows[i - 1];
    const next = rows[i];
    const gap = daysBetween(prev.date, next.date);
    if (gap === 0) {
      if (prev.end !== next.start) {
        return { ok: false, reason: `there is a gap between ${prev.end.slice(0, 5)} and ${next.start.slice(0, 5)}` };
      }
      continue;
    }
    if (gap === 1 && prev.end === END_OF_DAY && next.start === START_OF_DAY) continue;
    if (gap === null) return { ok: false, reason: 'one of those slots has an unreadable date' };
    return { ok: false, reason: 'those slots are not on the same day' };
  }
  return { ok: true, reason: null };
}

/** A percentage forced into the range the database will accept. */
function clampDiscount(percent) {
  const n = Number(percent);
  if (!Number.isFinite(n) || n <= 0) return 0;
  return Math.min(MAX_DISCOUNT_PERCENT, Math.round(n * 100) / 100);
}

/**
 * Which of the owner's tiers applies to a group of this size.
 *
 * The best percentage among the qualifying tiers wins, not the highest threshold.
 * An owner who enters "3 or more: 5%" beneath "2 or more: 10%" has made a mistake
 * in the player's favour, and reading it by threshold would charge the player more
 * for booking more — which is the one outcome a multi-slot discount must never
 * produce.
 */
function pickDiscountPercent(tiers, slotCount) {
  const count = Number(slotCount);
  if (!Number.isFinite(count) || count < MIN_DISCOUNT_SLOTS) return 0;
  let best = 0;
  for (const tier of tiers || []) {
    const min = Number(tier.min_slots);
    const pct = clampDiscount(tier.percent);
    if (!Number.isFinite(min) || pct <= 0) continue;
    if (count >= min && pct > best) best = pct;
  }
  return best;
}

/** Rounded to the two decimals the money columns hold. */
const round2 = (n) => Math.round((Number(n) + Number.EPSILON) * 100) / 100;

/** One slot's price after a discount. 0 stays 0 — a missing price is not invented. */
function discountedPrice(price, percent) {
  const base = Number(price);
  if (!Number.isFinite(base) || base <= 0) return 0;
  const pct = clampDiscount(percent);
  return pct > 0 ? round2(base * (1 - pct / 100)) : round2(base);
}

/**
 * The quote for a group: what each slot costs, what the whole thing costs, and
 * what the discount saved.
 *
 * `total` is the sum of the rounded per-slot prices and not a rounded sum, because
 * the per-slot figures are what the booking rows will actually hold. Quoting a
 * rounded total instead would show the player a number the ledger never moves.
 */
function quoteGroup(slots, tiers) {
  const rows = sortSlots(slots.map(normaliseSlot));
  const percent = pickDiscountPercent(tiers, rows.length);
  const lines = rows.map((s) => ({
    id: s.id,
    date: s.date,
    start: s.start,
    end: s.end,
    listPrice: round2(s.price),
    price: discountedPrice(s.price, percent),
  }));
  const listTotal = round2(lines.reduce((sum, l) => sum + l.listPrice, 0));
  const total = round2(lines.reduce((sum, l) => sum + l.price, 0));
  return {
    slots: lines,
    count: lines.length,
    discountPercent: percent,
    listTotal,
    total,
    saved: round2(listTotal - total),
    from: lines.length ? lines[0].start : null,
    to: lines.length ? lines[lines.length - 1].end : null,
  };
}

/**
 * Every reason a set of slot ids is not a bookable group, checked before any lock
 * is taken. Slot availability is deliberately NOT checked here: it is re-read
 * under a row lock by bookingService.createBooking, and a decision taken on an
 * unlocked read would be a second opinion about whether a slot is free.
 */
function validateGroupRequest(ids) {
  const unique = [...new Set((ids || []).map((v) => String(v == null ? '' : v).trim()).filter(Boolean))];
  if (unique.length < 2) {
    return { ok: false, code: 'not_a_group', message: 'Select at least two slots, or book a single slot.', ids: unique };
  }
  if (unique.length > MAX_GROUP_SLOTS) {
    return {
      ok: false,
      code: 'group_too_large',
      message: `One booking can cover at most ${MAX_GROUP_SLOTS} slots.`,
      ids: unique,
    };
  }
  return { ok: true, code: 'ok', message: null, ids: unique };
}

/**
 * Validate a set of owner discount tiers as a whole before any of it is written.
 *
 * Checked here rather than only by the database so the owner is told which rule is
 * wrong, instead of receiving one constraint violation for a form with four rows
 * in it.
 */
function validateTiers(tiers) {
  const rows = Array.isArray(tiers) ? tiers : [];
  const seen = new Set();
  const clean = [];
  for (const tier of rows) {
    const min = Math.round(Number(tier && tier.min_slots));
    const pct = Number(tier && tier.percent);
    if (!Number.isFinite(min) || min < MIN_DISCOUNT_SLOTS || min > MAX_DISCOUNT_SLOTS) {
      return { ok: false, message: `A tier threshold must be between ${MIN_DISCOUNT_SLOTS} and ${MAX_DISCOUNT_SLOTS} slots.` };
    }
    if (!Number.isFinite(pct) || pct <= 0 || pct > MAX_DISCOUNT_PERCENT) {
      return { ok: false, message: `A discount must be above 0% and at most ${MAX_DISCOUNT_PERCENT}%.` };
    }
    if (seen.has(min)) {
      return { ok: false, message: `There are two rules for ${min} slots. Keep one.` };
    }
    seen.add(min);
    clean.push({ min_slots: min, percent: Math.round(pct * 100) / 100 });
  }
  clean.sort((a, b) => a.min_slots - b.min_slots);
  return { ok: true, message: null, tiers: clean };
}

module.exports = {
  MAX_GROUP_SLOTS,
  MAX_DISCOUNT_PERCENT,
  MIN_DISCOUNT_SLOTS,
  MAX_DISCOUNT_SLOTS,
  END_OF_DAY,
  START_OF_DAY,
  dateStr,
  timeStr,
  normaliseSlot,
  sortSlots,
  checkConsecutive,
  clampDiscount,
  pickDiscountPercent,
  discountedPrice,
  quoteGroup,
  validateGroupRequest,
  validateTiers,
};
