/**
 * assistantActions.js — the actions Scout can perform.
 *
 * One function per capability, and every one of them returns the same shape:
 *
 *   { reply, state? }     reply  = utils/assistantReply.reply(...)
 *                         state  = an optional patch the dialog manager merges
 *
 * Why ACTIONS do not write state themselves
 * A booking flow that both answers the user and edits session_state from inside
 * the action is a flow with two writers, and the failure mode is a `confirm` that
 * survives the turn it was answered in — Scout re-asking "confirm?" forever, or
 * worse, holding a stale confirmation and executing it against a later "haan".
 * So actions propose a patch and services/dialogManager.js is the only writer.
 *
 * Why there is no SQL in this file
 * FR8.15. Every read goes through discoveryService / rosterService / bookingService
 * / teamStats, which are the same functions the REST routes call. There are exactly
 * three exceptions, each marked with `SQL EXCEPTION` where it happens: the caller's
 * wallet row, the caller's own team memberships, and the caller's profile. All three
 * are one join keyed on the caller's own id with no derived rule attached, so
 * wrapping them in a shared function would add an indirection that owns nothing --
 * and any rule they do touch is borrowed (teamAccess.ADMIN_ROLES decides who counts
 * as a team admin, here as everywhere).
 *
 * The ACTION key is the contract
 * `ACTIONS` is keyed by the same strings as the trained intent labels, plus the
 * button-only ones (`pick_slot`, `confirm`, `capability_menu`, …). That is what
 * lets a chip press skip the classifier entirely: routes/assistant.js looks the
 * key up here directly. `assertRoutable()` proves at boot that every one of the
 * artifact's 23 labels has a home, so a retrain that adds a label fails loudly
 * instead of silently landing in out_of_scope.
 */
const pool = require('../db/pool');
const { reply, chip, card, menu, SOURCES, CARDS, CAPABILITIES } = require('../utils/assistantReply');
const discovery = require('./discoveryService');
const roster = require('./rosterService');
const booking = require('./bookingService');
const T = require('./tournamentService');
const kb = require('./assistantKb');
const ml = require('./mlClient');
const teamStats = require('../utils/teamStats');
const elo = require('../utils/elo');
const settingsUtil = require('../utils/globalSettings');
const policyText = require('../utils/policyText');
const { POLICY, round2, asNum, depositFor } = require('../utils/escrow');
const access = require('../utils/teamAccess');

/** Cards per list. Three venues is what the spec asked for; six slots fit. */
const TOP_VENUES = 3;
const TOP_SLOTS = 6;
const TOP_PEOPLE = 5;

/** PKR, the way a person writes it. */
const money = (n) => `PKR ${Number(round2(asNum(n))).toLocaleString('en-PK')}`;

/** "6:00 PM" from a Postgres time. */
function clock(t) {
  const s = String(t || '');
  const h = Number(s.slice(0, 2));
  const m = s.slice(3, 5);
  if (!Number.isFinite(h)) return s;
  const ampm = h >= 12 ? 'PM' : 'AM';
  const h12 = h % 12 === 0 ? 12 : h % 12;
  return `${h12}:${m} ${ampm}`;
}

/** "Sat 30 Aug" — short enough for a chip, unambiguous about which day. */
function day(d) {
  const s = String(d || '').slice(0, 10);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(s)) return s;
  const [y, mo, dd] = s.split('-').map(Number);
  const dt = new Date(Date.UTC(y, mo - 1, dd));
  const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return `${DAYS[dt.getUTCDay()]} ${dd} ${MONTHS[mo - 1]}`;
}

/** Today / tomorrow in PKT, so "kal" resolves the same way everywhere. */
function pktDate(offsetDays = 0) {
  const base = new Date(Date.now() + discovery.PKT_OFFSET_MS + offsetDays * 86400000);
  return base.toISOString().slice(0, 10);
}

/**
 * A venue card, built once so the three places that show venues cannot drift.
 *
 * `matchPct` is passed through unchanged, including null. mlClient's contract is
 * that an unavailable ranker means "order these deterministically and invent no
 * percentage", and a card that filled in a 0 would be a lie with a number on it.
 */
function venueCard(v, { matchPct = null, reasons = null, sport = null, date = null } = {}) {
  const chips = [
    chip('See times', 'check_availability', { venueId: v.id, date: date || undefined }),
    chip('Book', 'book_venue', { venueId: v.id, sport: sport || v.sport_type, date: date || undefined }),
  ];
  if (v.latitude != null && v.longitude != null) {
    chips.push(chip('Directions', 'navigate', { venueId: v.id }));
  }
  return card(CARDS.VENUE, {
    id: v.id,
    name: v.name,
    city: v.city || null,
    address: v.address || null,
    sport: v.sport_type || null,
    pricePerHour: v.price_per_hour == null ? null : Number(v.price_per_hour),
    rating: v.rating == null ? null : Number(v.rating),
    totalReviews: v.total_reviews == null ? null : Number(v.total_reviews),
    photo: v.cover_photo || null,
    lat: v.latitude == null ? null : Number(v.latitude),
    lng: v.longitude == null ? null : Number(v.longitude),
    matchPct: matchPct == null ? null : Number(matchPct),
    reasons: Array.isArray(reasons) ? reasons : [],
    buttons: chips,
  });
}

/** The slot_picker card. Numbered, because "2" is a valid thing for a user to type. */
function slotPickerCard(venue, slots, { date }) {
  return card(CARDS.SLOT_PICKER, {
    venueId: venue.id,
    venueName: venue.name,
    date,
    dateLabel: day(date),
    slots: slots.map((s, i) => ({
      n: i + 1,
      slotId: s.id,
      startTime: String(s.start_time).slice(0, 5),
      endTime: String(s.end_time || '').slice(0, 5) || null,
      label: clock(s.start_time),
      price: s.price == null ? null : Number(s.price),
      priceLabel: s.price == null ? null : money(s.price),
    })),
    buttons: slots.map((s, i) => chip(clock(s.start_time), 'pick_slot', { slotId: s.id, n: i + 1 })),
  });
}

/**
 * A date column as YYYY-MM-DD.
 *
 * node-postgres turns a date into a JS Date at local midnight, and
 * `toISOString()` on that shifts the day backwards for any timezone west of UTC.
 * bookings.slot_date is PKT wall-clock text, so the fix is to add the offset back
 * before slicing rather than to hope the server runs in Karachi.
 */
function dateStr(v) {
  if (v instanceof Date) {
    return new Date(v.getTime() - v.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
  }
  return String(v == null ? '' : v).slice(0, 10);
}

/**
 * The confirm card — the last thing between a sentence and a wallet.
 *
 * It exists because a classifier is a guess. "kal 6 baje book kar do" can be a
 * booking or it can be a question about tomorrow, and the difference is PKR 2,000
 * of the user's money moving into escrow. So the numbers are shown before the
 * write, both buttons are explicit, and there is no default action: `confirm` and
 * `cancel_confirm` are the only two ways out of this card.
 *
 * The deposit line is required by the spec and comes from escrow.js POLICY
 * via depositFor(), never from a literal 20 typed here.
 */
function confirmCard({ what, title, lines = [], total = null, deposit = null,
  note = null, yes = 'Confirm', no = 'Cancel' } = {}) {
  return card(CARDS.CONFIRM, {
    what,
    title,
    lines,
    total: total == null ? null : Number(total),
    totalLabel: total == null ? null : money(total),
    deposit: deposit == null ? null : Number(deposit),
    depositLabel: deposit == null ? null : money(deposit),
    depositPct: POLICY.DEPOSIT_PERCENT,
    note,
    buttons: [chip(yes, 'confirm'), chip(no, 'cancel_confirm')],
  });
}

/**
 * A booking card, shared by `my_bookings`, a fresh booking and a cancellation, so
 * the same booking never renders three different ways.
 *
 * `status` is passed through verbatim: 'pending' means the owner has not approved
 * yet, and softening that word in the assistant would be Scout telling a user they
 * are confirmed when they are not.
 */
function bookingCard(b, { buttons = null } = {}) {
  const date = dateStr(b.slot_date ?? b.slotDate);
  const start = String(b.start_time || '').slice(0, 5);
  const end = String(b.end_time || '').slice(0, 5);
  const total = b.total_amount ?? b.base_price ?? null;
  const acts = buttons || [
    chip('Directions', 'navigate', { venueId: b.venue_id }),
    ...(b.status === 'pending' || b.status === 'confirmed'
      ? [chip('Cancel it', 'cancel_booking', { bookingId: b.id })] : []),
  ];
  return card(CARDS.BOOKING, {
    id: b.id,
    venueId: b.venue_id || null,
    venueName: b.venue_name || null,
    city: b.city || null,
    date,
    dateLabel: day(date),
    startTime: start,
    endTime: end || null,
    timeLabel: end ? `${clock(start)} - ${clock(end)}` : clock(start),
    status: b.status || null,
    total: total == null ? null : Number(total),
    totalLabel: total == null ? null : money(total),
    deposit: b.deposit_amount == null ? null : Number(b.deposit_amount),
    qr: b.qr_code || null,
    buttons: acts.filter(Boolean),
  });
}

/**
 * Resolve "Rawal ground" to a venue id.
 *
 * The assistant is handed a name far more often than an id, and a wrong guess here
 * books the wrong ground — so the rule is: exactly one match resolves, several
 * matches ask, none matches falls back to a search. It never picks the first row.
 */
async function resolveVenue(client, { venueId = null, name = null, sport = null, area = null } = {}) {
  if (venueId && access.isUuid(String(venueId).trim().toLowerCase())) {
    const got = await discovery.venueDetail(client, { venueId, userId: null });
    return got.ok ? { one: got.data, many: [] } : { one: null, many: [] };
  }
  const term = String(name || '').trim();
  if (!term) return { one: null, many: [] };
  const hits = await discovery.searchVenues(client, {
    search: term, sport: sport || null, city: area || null, limit: 5,
  });
  if (hits.length === 1) return { one: hits[0], many: [] };
  return { one: null, many: hits };
}

/**
 * The team the user is acting for.
 *
 * `find_players` and `find_opponents` are about a specific squad, and most users
 * captain exactly one — so a single team resolves silently and several teams ask,
 * by chip, with no typing. A user in no team is told how to create one rather than
 * shown an empty list, which is the difference between a dead end and an onboarding.
 */
async function resolveTeam(client, { userId, teamId = null, name = null, adminOnly = false } = {}) {
  // SQL exception 2 of 3 (see the file header): the caller's own memberships.
  const runner = client || pool;
  const id = teamId ? String(teamId).trim().toLowerCase() : null;

  // One query shape for all three ways in — a chip carrying an id, a spoken team
  // name, or nothing at all. An id is resolved rather than trusted because every
  // caller needs the name and the role back, not the id alone, and because an id
  // that survives this join is one the caller is provably a member of: a stale chip
  // then fails here as "which team?" instead of as a 403 from three layers down.
  async function ask({ byId = false, byName = false }) {
    const params = [userId];
    let extra = '';
    if (byId) { params.push(id); extra += ` AND t.id = $${params.length}`; }
    // ADMIN_ROLES rather than a typed list: teamAccess owns who counts as an admin.
    if (adminOnly) { params.push(access.ADMIN_ROLES); extra += ` AND tm.role = ANY($${params.length})`; }
    if (byName) { params.push(`%${access.squash(name)}%`); extra += ` AND t.name ILIKE $${params.length}`; }
    const { rows } = await runner.query(
      `SELECT t.id, t.name, t.sport::text AS sport, t.elo,
              t.logo_url, t.city, t.wins, t.losses, t.draws, tm.role
         FROM team_members tm JOIN teams t ON t.id = tm.team_id
        WHERE tm.user_id = $1${extra}
        ORDER BY t.elo DESC, lower(t.name) LIMIT 5`,
      params,
    );
    return rows;
  }

  const byId = !!(id && access.isUuid(id));
  const byName = !!(name && access.squash(name));
  let rows = await ask({ byId, byName });
  // A chip or a name that matches none of the caller's teams: re-ask unfiltered so
  // the reply can offer the teams they do have instead of "you are not in a team".
  if (!rows.length && (byId || byName)) rows = await ask({});
  if (rows.length === 1) return { one: rows[0], many: [] };
  return { one: null, many: rows };
}

// Discovery

/**
 * find_venue — "koi ground milega football ka Rawalpindi mein 2000 se kam?"
 *
 * The trained entity extractor supplies sport / area / budget / date, and every one
 * of them is optional: an empty search is a valid question ("show me grounds") and
 * must not be turned into a slot-filling interrogation. Only `book_venue` asks.
 *
 * Ranking comes from model #3 when the user has history and the service is up
 * (`source: 'model'`); otherwise the deterministic rating order stands and no
 * match percentage is shown. The reply's `source` says which happened, per message.
 */
async function findVenue(ctx) {
  const { client, userId, slots = {} } = ctx;
  const rows = await discovery.searchVenues(client, {
    sport: slots.sport || null,
    city: slots.area || null,
    // `locality` is a neighbourhood ("DHA", "Gulberg"), which is not a city and so
    // cannot go through the city filter -- it is matched against the address by the
    // same free-text term a spoken venue name uses. dialogManager splits the two.
    search: slots.venueName || slots.locality || null,
    maxPrice: slots.budget || null,
    // `sort` and `offset` arrive from this action's own chips -- "Cheapest first"
    // and "More grounds". Reading them here is what makes those two chips do
    // something; a chip whose args nobody reads is a button that lies.
    sort: slots.sort || (slots.budget ? 'price_low' : null),
    offset: slots.offset || 0,
    limit: 12,
  });
  if (!rows.length) {
    // Paging off the end of a list is not the same as finding nothing: the user has
    // just seen three grounds, so "nothing matching that" would read as a bug.
    if (slots.offset) {
      return { reply: reply('That is every ground I have for that search.', {
        source: SOURCES.LIVE,
        chips: [chip('Start again', 'find_venue'), chip('What can you do?', 'capability_menu')],
      }) };
    }
    const wider = await discovery.searchVenues(client, { sport: slots.sport || null, limit: TOP_VENUES });
    if (!wider.length) {
      return { reply: reply('I could not find any ground matching that yet.', {
        source: SOURCES.LIVE,
        chips: [chip('Show all grounds', 'find_venue'), chip('What can you do?', 'capability_menu')],
      }) };
    }
    const where = [slots.locality, slots.area].filter(Boolean).join(', ');
    const what = [where && `in ${where}`, slots.budget && `under ${money(slots.budget)}`]
      .filter(Boolean).join(' ');
    return { reply: reply(`Nothing ${what || 'matching that'}. Here is what is close:`, {
      source: SOURCES.LIVE,
      cards: wider.map((v) => venueCard(v, { sport: slots.sport, date: slots.date })),
      chips: [chip('Wider search', 'find_venue', { sport: slots.sport || undefined })],
    }) };
  }

  // Model #3 ranks only the rows the filters already allowed, so a recommendation
  // can never smuggle a venue past the verification gate or the price ceiling.
  let ranked = rows.slice(0, TOP_VENUES).map((v) => ({ v, matchPct: null, reasons: [] }));
  let source = SOURCES.LIVE;
  let label = null;
  try {
    const reco = await ml.recommendVenues(userId, { limit: 40 });
    if (reco && reco.source === 'model' && Array.isArray(reco.items) && reco.items.length) {
      const byId = new Map(rows.map((v) => [String(v.id), v]));
      const hit = reco.items
        .map((x) => (byId.get(String(x.venue_id))
          ? { v: byId.get(String(x.venue_id)), matchPct: x.match_pct, reasons: x.reasons || [] }
          : null))
        .filter(Boolean);
      if (hit.length) {
        ranked = hit.slice(0, TOP_VENUES);
        source = SOURCES.MODEL;
        label = reco.label || 'Picked for you';
      }
    }
  } catch (e) { /* a down ranker is a fallback, never an error the user sees */ }

  const head = source === SOURCES.MODEL
    ? `${label} — ${ranked.length} ground${ranked.length === 1 ? '' : 's'} I think suit you:`
    : `Found ${rows.length} ground${rows.length === 1 ? '' : 's'}. Top ${ranked.length}:`;
  return { reply: reply(head, {
    source,
    cards: ranked.map((r) => venueCard(r.v, {
      matchPct: r.matchPct, reasons: r.reasons, sport: slots.sport, date: slots.date,
    })),
    chips: [
      ...(rows.length > ranked.length ? [chip('More grounds', 'find_venue', {
        sport: slots.sport || undefined, area: slots.area || undefined, offset: ranked.length,
      })] : []),
      chip('Cheapest first', 'find_venue', { sport: slots.sport || undefined, sort: 'price_low' }),
    ],
    meta: { matched: rows.length, ranker: source },
  }) };
}

/**
 * check_availability — "kal 6 baje Rawal ground free hai?"
 *
 * Answers with the picker rather than a yes/no, because a "no" that does not offer
 * the nearest free hour is a dead end (spec rule 5). The venue has to be resolved
 * first, and an ambiguous name asks by chip instead of guessing.
 */
async function checkAvailability(ctx) {
  const { client, userId, slots = {} } = ctx;
  const { one, many } = await resolveVenue(client, {
    venueId: slots.venueId, name: slots.venueName, sport: slots.sport, area: slots.area,
  });
  if (!one) {
    if (many.length) {
      return { reply: reply('Which ground did you mean?', {
        source: SOURCES.LIVE,
        cards: many.slice(0, TOP_VENUES).map((v) => venueCard(v, { date: slots.date })),
        chips: many.slice(0, 4).map((v) => chip(v.name, 'check_availability',
          { venueId: v.id, date: slots.date || undefined })),
      }) };
    }
    return { reply: reply('Tell me which ground and I will check the times.', {
      source: SOURCES.LIVE,
      chips: [chip('Find a ground', 'find_venue', { sport: slots.sport || undefined })],
    }), state: { pending: 'venue', intent: 'check_availability' } };
  }

  const date = slots.date || pktDate();
  const { slots: free, past } = await discovery.freeSlots(client, {
    venueId: one.id, userId, date, time: slots.time, limit: TOP_SLOTS,
  });
  if (past) {
    return { reply: reply(`${day(date)} has already gone. Which day did you mean?`, {
      source: SOURCES.LIVE,
      chips: [chip('Today', 'check_availability', { venueId: one.id, date: pktDate() }),
        chip('Tomorrow', 'check_availability', { venueId: one.id, date: pktDate(1) })],
    }) };
  }
  if (!free.length) {
    const next = await discovery.freeSlots(client, {
      venueId: one.id, userId, date: pktDate(1), limit: TOP_SLOTS });
    const extra = next.slots.length
      ? { cards: [slotPickerCard(one, next.slots, { date: next.slotDate })],
        text: `${one.name} is full on ${day(date)}. ${day(next.slotDate)} is open:` }
      : { cards: [], text: `${one.name} has nothing free on ${day(date)}.` };
    return { reply: reply(extra.text, {
      source: SOURCES.LIVE,
      cards: extra.cards,
      chips: [chip('Other grounds', 'find_venue', { sport: slots.sport || one.sport_type })],
    }) };
  }
  const asked = slots.time ? ` around ${clock(slots.time)}` : '';
  return { reply: reply(
    `${one.name} on ${day(date)}${asked} — ${free.length} slot${free.length === 1 ? '' : 's'} free:`, {
      source: SOURCES.LIVE,
      cards: [slotPickerCard(one, free, { date })],
      chips: [chip('Another day', 'check_availability', { venueId: one.id, date: pktDate(1) })],
      meta: { venueId: one.id, date },
    }),
  state: { intent: 'book_venue', slots: { venueId: one.id, venueName: one.name, date, sport: one.sport_type } } };
}

/**
 * venue_info — facilities, price, rating, timings, and the escape hatch.
 *
 * "Ask the owner" is on this card deliberately: the whole learning loop starts
 * with a question Scout cannot answer about a specific ground, and the only place
 * a user naturally asks it is while looking at that ground.
 */
async function venueInfo(ctx) {
  const { client, userId, slots = {} } = ctx;
  const { one, many } = await resolveVenue(client, {
    venueId: slots.venueId, name: slots.venueName, sport: slots.sport, area: slots.area });
  if (!one) {
    if (many.length) {
      return { reply: reply('Which one?', {
        source: SOURCES.LIVE,
        chips: many.slice(0, 4).map((v) => chip(v.name, 'venue_info', { venueId: v.id })),
      }) };
    }
    return { reply: reply('Which ground would you like to know about?', {
      source: SOURCES.LIVE, chips: [chip('Find a ground', 'find_venue')],
    }), state: { pending: 'venue', intent: 'venue_info' } };
  }
  const det = await discovery.venueDetail(client, { venueId: one.id, userId, date: slots.date });
  const v = det.ok ? det.data : one;
  // `amenities` and `operating_hours_from/to` are the real column names (013/014);
  // an assistant quoting a column that does not exist would print nothing at all.
  const facilities = Array.isArray(v.amenities) ? v.amenities.filter(Boolean) : [];
  const bits = [
    v.city && `${v.city}`,
    v.price_per_hour != null && `${money(v.price_per_hour)}/hour`,
    v.rating != null && Number(v.rating) > 0
      && `rated ${Number(v.rating).toFixed(1)}${v.total_reviews ? ` (${v.total_reviews})` : ''}`,
    (v.operating_hours_from && v.operating_hours_to)
      && `open ${clock(v.operating_hours_from)}–${clock(v.operating_hours_to)}`,
  ].filter(Boolean);
  const text = `${v.name} — ${bits.join(' · ')}.`
    + (facilities.length ? ` Facilities: ${facilities.slice(0, 6).join(', ')}.` : '');
  return { reply: reply(text, {
    source: SOURCES.LIVE,
    cards: [venueCard(v, { sport: slots.sport, date: slots.date })],
    chips: [
      chip('See times', 'check_availability', { venueId: v.id }),
      chip('Ask the owner', 'contact_owner', { venueId: v.id }),
      ...(v.latitude != null ? [chip('Directions', 'navigate', { venueId: v.id })] : []),
    ],
    meta: { venueId: v.id },
  }), state: { slots: { venueId: v.id, venueName: v.name } } };
}

/**
 * navigate — the maps capability, and the one that had to be honest about what a
 * backend can do.
 *
 * Scout cannot draw a route; the phone can. So this returns a MAP card carrying the
 * ground's coordinates plus a `geo:` URI and a Google Maps URL, and Flutter's
 * widget opens whichever the device has (url_launcher). Building it here rather
 * than in Dart keeps one rule in one place: a venue with no latitude gets its
 * address as a search query instead of a broken pin at 0,0 in the Gulf of Guinea.
 */
async function navigate(ctx) {
  const { client, userId, slots = {} } = ctx;
  let target = null;
  if (slots.venueId || slots.venueName) {
    const { one, many } = await resolveVenue(client, {
      venueId: slots.venueId, name: slots.venueName, area: slots.area });
    if (!one && many.length) {
      return { reply: reply('Directions to which ground?', {
        source: SOURCES.LIVE,
        chips: many.slice(0, 4).map((v) => chip(v.name, 'navigate', { venueId: v.id })),
      }) };
    }
    target = one;
  }
  if (!target) {
    // No ground named: the next booking is almost always what "how do I get there"
    // means, so answer that instead of asking.
    const mine = await booking.listMyBookings(client, { userId, limit: 50 });
    const next = mine.find((b) => ['pending', 'confirmed', 'checked_in'].includes(b.status)
      && b.slot_date >= pktDate());
    if (next) {
      target = { id: next.venue_id, name: next.venue_name, city: next.city,
        address: next.address, latitude: next.latitude, longitude: next.longitude };
    }
  }
  if (!target) {
    return { reply: reply('Which ground do you want directions to?', {
      source: SOURCES.LIVE, chips: [chip('Find a ground', 'find_venue')],
    }), state: { pending: 'venue', intent: 'navigate' } };
  }
  const hasPin = target.latitude != null && target.longitude != null;
  const query = encodeURIComponent([target.name, target.address, target.city]
    .filter(Boolean).join(', '));
  const data = {
    venueId: target.id,
    name: target.name,
    address: target.address || null,
    city: target.city || null,
    lat: hasPin ? Number(target.latitude) : null,
    lng: hasPin ? Number(target.longitude) : null,
    hasPin,
    geoUri: hasPin ? `geo:${target.latitude},${target.longitude}?q=${query}` : `geo:0,0?q=${query}`,
    mapsUrl: hasPin
      ? `https://www.google.com/maps/dir/?api=1&destination=${target.latitude},${target.longitude}`
      : `https://www.google.com/maps/search/?api=1&query=${query}`,
  };
  return { reply: reply(
    hasPin ? `${target.name}${target.city ? `, ${target.city}` : ''} — tap to open the route.`
      : `I do not have a pin for ${target.name}, so this searches Maps for the address.`, {
      source: SOURCES.LIVE,
      cards: [card(CARDS.MAP, data)],
      chips: [chip('About this ground', 'venue_info', { venueId: target.id }),
        chip('See times', 'check_availability', { venueId: target.id })],
    }) };
}

// BOOKING

/**
 * book_venue — the slot-filling flow, and the only action that spends money.
 *
 * The state machine is deliberately small, and every step is reachable by button:
 *
 *   no venue     -> ask (or search, if a sport was given)
 *   no date      -> today / tomorrow chips
 *   no slot      -> slot_picker card
 *   slot chosen  -> CONFIRM card with the price and the deposit note
 *   confirmed    -> bookingService.createBooking, inside the turn's transaction
 *
 * The confirm step is not decoration. It is the last point at which a
 * misclassified sentence can be stopped before a wallet moves, so `state.confirm`
 * carries the resolved slotId and the quoted price, and the dialog manager will
 * only execute it against an explicit affirmation.
 */
async function bookVenue(ctx) {
  const { client, userId, slots = {} } = ctx;

  if (!slots.venueId) {
    const { one, many } = await resolveVenue(client, {
      name: slots.venueName, sport: slots.sport, area: slots.area });
    if (one) slots.venueId = one.id;
    else if (many.length) {
      return { reply: reply('Which ground should I book?', {
        source: SOURCES.LIVE,
        cards: many.slice(0, TOP_VENUES).map((v) => venueCard(v, { sport: slots.sport, date: slots.date })),
        chips: many.slice(0, 4).map((v) => chip(v.name, 'book_venue',
          { venueId: v.id, date: slots.date || undefined, time: slots.time || undefined })),
      }), state: { intent: 'book_venue', pending: 'venue', slots } };
    } else {
      const opts = await discovery.searchVenues(client, {
        sport: slots.sport || null, city: slots.area || null,
        search: slots.locality || null, limit: TOP_VENUES });
      if (!opts.length) {
        return { reply: reply('Which ground would you like to book?', {
          source: SOURCES.LIVE, chips: [chip('Find a ground', 'find_venue')],
        }), state: { intent: 'book_venue', pending: 'venue', slots } };
      }
      return { reply: reply(
        slots.sport ? `Which ${slots.sport} ground?` : 'Which ground should I book?', {
          source: SOURCES.LIVE,
          cards: opts.map((v) => venueCard(v, { sport: slots.sport, date: slots.date })),
          chips: opts.map((v) => chip(v.name, 'book_venue',
            { venueId: v.id, date: slots.date || undefined, time: slots.time || undefined })),
        }), state: { intent: 'book_venue', pending: 'venue', slots } };
    }
  }

  const det = await discovery.venueDetail(client, { venueId: slots.venueId, userId, date: slots.date });
  if (!det.ok) {
    return { reply: reply('I could not open that ground. Pick another?', {
      source: SOURCES.LIVE, chips: [chip('Find a ground', 'find_venue')],
    }), state: { intent: 'book_venue', pending: 'venue', slots: { ...slots, venueId: null } } };
  }
  const venue = det.data;
  slots.venueName = venue.name;
  slots.sport = slots.sport || venue.sport_type;

  if (!slots.date) {
    return { reply: reply(`Which day at ${venue.name}?`, {
      source: SOURCES.LIVE,
      chips: [
        chip('Today', 'book_venue', { venueId: venue.id, date: pktDate() }),
        chip('Tomorrow', 'book_venue', { venueId: venue.id, date: pktDate(1) }),
        chip(day(pktDate(2)), 'book_venue', { venueId: venue.id, date: pktDate(2) }),
      ],
    }), state: { intent: 'book_venue', pending: 'date', slots } };
  }

  if (!slots.slotId) {
    const { slots: free, past } = await discovery.freeSlots(client, {
      venueId: venue.id, userId, date: slots.date, time: slots.time, limit: TOP_SLOTS });
    if (past) {
      return { reply: reply(`${day(slots.date)} is in the past. Which day?`, {
        source: SOURCES.LIVE,
        chips: [chip('Today', 'book_venue', { venueId: venue.id, date: pktDate() }),
          chip('Tomorrow', 'book_venue', { venueId: venue.id, date: pktDate(1) })],
      }), state: { intent: 'book_venue', pending: 'date', slots: { ...slots, date: null } } };
    }
    if (!free.length) {
      return { reply: reply(`${venue.name} has nothing free on ${day(slots.date)}.`, {
        source: SOURCES.LIVE,
        chips: [chip('Tomorrow', 'book_venue', { venueId: venue.id, date: pktDate(1) }),
          chip('Other grounds', 'find_venue', { sport: slots.sport || undefined })],
      }), state: { intent: 'book_venue', pending: 'date', slots: { ...slots, date: null } } };
    }
    // A single free slot at an explicitly asked hour still goes through the picker:
    // auto-selecting removes the user's chance to see the price before confirming.
    return { reply: reply(`Pick a time at ${venue.name} on ${day(slots.date)}:`, {
      source: SOURCES.LIVE,
      cards: [slotPickerCard(venue, free, { date: slots.date })],
      chips: [chip('Another day', 'book_venue', { venueId: venue.id, date: pktDate(1) })],
    }), state: { intent: 'book_venue', pending: 'slot', slots } };
  }

  // CONFIRM
  // The confirm step is not decoration. It is the last point at which a
  // misclassified sentence can be stopped before a wallet moves, so state.confirm
  // carries the resolved slotId and the QUOTED price, and dialogManager will only
  // execute it against an explicit affirmation.
  const got = await discovery.slotById(client, { slotId: slots.slotId, userId });
  if (!got.ok || !got.data.bookable) {
    const why = {
      taken: 'someone just booked that time',
      held: 'another player is checking out on that time right now',
      blocked: 'the owner has blocked that time',
      past: 'that time has already started',
      venue_inactive: 'that ground is not taking bookings',
    }[got.ok ? got.data.reason : ''] || 'that time is not available';
    return { reply: reply(`Sorry, ${why}. Pick another?`, {
      source: SOURCES.LIVE,
      chips: [chip('Show times', 'check_availability',
        { venueId: venue.id, date: slots.date })],
    }), state: { intent: 'book_venue', pending: 'slot', slots: { ...slots, slotId: null } } };
  }
  const s = got.data;
  const price = asNum(s.price);
  const dep = depositFor(price);
  return {
    reply: reply(
      `${venue.name}, ${day(slots.date)} at ${clock(s.start_time)} — ${money(price)}. Book it?`, {
        source: SOURCES.LIVE,
        cards: [confirmCard({
          what: 'book_venue',
          title: `Book ${venue.name}`,
          lines: [
            { label: 'Ground', value: venue.name },
            { label: 'Day', value: day(slots.date) },
            { label: 'Time', value: s.end_time
              ? `${clock(s.start_time)} - ${clock(s.end_time)}` : clock(s.start_time) },
            { label: 'Sport', value: venue.sport_type || slots.sport || '-' },
          ],
          total: price,
          deposit: dep,
          note: `${money(price)} is held in escrow. ${money(dep)} `
            + `(${POLICY.DEPOSIT_PERCENT}%) is your at-risk deposit if you cancel late or no-show.`,
          yes: 'Yes, book it',
        })],
      }),
    state: {
      intent: 'book_venue',
      pending: null,
      slots,
      confirm: {
        action: 'book_venue',
        slotId: s.id,
        venueId: venue.id,
        venueName: venue.name,
        date: slots.date,
        startTime: String(s.start_time).slice(0, 5),
        price,
        deposit: dep,
      },
    },
  };
}

/**
 * Run one money call inside a SAVEPOINT.
 *
 * bookingService's contract is "the caller must ROLLBACK on ok:false", and a Scout
 * turn cannot do that: the user's message and Scout's reply are written in the same
 * transaction on purpose, so that a booking can never be recorded without the
 * sentence that asked for it. Rolling the whole turn back to report "insufficient
 * funds" would delete the conversation that explains the failure.
 *
 * A savepoint satisfies both. The failed write is undone exactly as bookingService
 * requires, and the turn — including the sentence Scout is about to say about it —
 * survives.
 */
async function withSavepoint(client, fn) {
  await client.query('SAVEPOINT scout_act');
  try {
    const out = await fn();
    if (out && out.ok === false) await client.query('ROLLBACK TO SAVEPOINT scout_act');
    else await client.query('RELEASE SAVEPOINT scout_act');
    return out;
  } catch (e) {
    await client.query('ROLLBACK TO SAVEPOINT scout_act').catch(() => {});
    throw e;
  }
}

/**
 * `pick_slot` — the chip under a slot_picker row.
 *
 * It is deliberately not its own flow. A picked slot is a filled `slotId` on the
 * booking intent, so this hands straight to bookVenue and lands on the confirm
 * step. Writing a second path here is how the picker and the typed flow would
 * start quoting prices differently.
 */
async function pickSlot(ctx) {
  const slots = { ...(ctx.slots || {}) };
  if (!slots.slotId) {
    return { reply: reply('Which time did you mean? Tap one of the times above.', {
      source: SOURCES.LIVE,
      chips: [chip('Show times again', 'check_availability',
        { venueId: slots.venueId || undefined, date: slots.date || undefined })],
    }) };
  }
  // The chip carries only a slot id, and session_state may have been reset between
  // the picker and the tap (a new chat, a version bump). The slot itself knows
  // which ground and which day it belongs to, so backfill from the row rather than
  // asking the user to say it again.
  if (!slots.venueId || !slots.date) {
    const got = await discovery.slotById(ctx.client, { slotId: slots.slotId, userId: ctx.userId });
    if (!got.ok) {
      return { reply: reply('That time is no longer on the board. Shall I show what is free?', {
        source: SOURCES.LIVE,
        chips: [chip('Find a ground', 'find_venue')],
      }), state: { intent: null, pending: null, slots: {}, confirm: null } };
    }
    slots.venueId = slots.venueId || got.data.venue_id;
    slots.date = slots.date || got.data.slotDate;
    slots.venueName = slots.venueName || got.data.venue_name;
    slots.sport = slots.sport || got.data.sport_type;
  }
  return bookVenue({ ...ctx, slots });
}

/**
 * Execute a confirmed booking. Reached only from an explicit affirmation.
 *
 * The slot is re-checked here even though the confirm step just checked it, and
 * even though createBooking checks it again under a row lock. That is not
 * paranoia: a confirm can sit in session_state across a long pause, and the two
 * cheap reads let Scout say "someone just booked that 6pm" instead of surfacing
 * bookingService's 409 as a bare failure.
 *
 * The QUOTED price is compared against the LIVE one and the booking is stopped if
 * they differ. A user who agreed to PKR 2,000 has not agreed to PKR 2,500, and an
 * owner may legitimately change a price between two turns of a chat.
 */
async function executeBooking(ctx) {
  const { client, userId } = ctx;
  const c = ctx.confirm || {};
  if (!c.slotId || !c.venueId) {
    return { reply: reply('I lost track of which slot that was. Shall we start again?', {
      source: SOURCES.LIVE, chips: [chip('Find a ground', 'find_venue')],
    }), state: { intent: null, pending: null, slots: {}, confirm: null } };
  }

  const got = await discovery.slotById(client, { slotId: c.slotId, userId });
  if (!got.ok || !got.data.bookable) {
    const why = {
      taken: 'someone booked that slot first',
      held: 'another player is checking out on it right now',
      blocked: 'the owner blocked it',
      past: 'it has already started',
      venue_inactive: 'that ground stopped taking bookings',
    }[got.ok ? got.data.reason : ''] || 'it is no longer available';
    return { reply: reply(`I could not book that slot — ${why}. Want to see what else is free?`, {
      source: SOURCES.LIVE, actionOk: false, action: 'book_venue',
      chips: [chip('Show times', 'check_availability', { venueId: c.venueId, date: c.date })],
    }), state: { intent: 'book_venue', pending: 'slot', confirm: null,
      slots: { venueId: c.venueId, date: c.date, venueName: c.venueName } } };
  }
  const live = asNum(got.data.price);
  if (c.price != null && round2(live) !== round2(c.price)) {
    return { reply: reply(
      `The price for that slot changed to ${money(live)} (you agreed to ${money(c.price)}). `
      + 'Book it at the new price?', {
        source: SOURCES.LIVE, actionOk: false, action: 'book_venue',
      }), state: { intent: 'book_venue', pending: null,
      slots: { venueId: c.venueId, date: c.date, venueName: c.venueName, slotId: c.slotId },
      confirm: { ...c, price: live, deposit: depositFor(live) } } };
  }

  const out = await withSavepoint(client, () => booking.createBooking(client, {
    userId, slotId: c.slotId, venueId: c.venueId,
    notes: 'Booked with Scout',
  }));

  if (!out.ok) {
    // insufficient_funds is the one failure a user can do something about, so it
    // gets the top-up chip rather than the generic apology.
    const short = out.code === 'insufficient_funds';
    const need = short ? money(live) : null;
    return { reply: reply(
      short
        ? `Your wallet is short — that slot needs ${need} held in escrow. Top up and I will book it.`
        : `I could not complete that booking: ${out.message}`, {
        source: SOURCES.LIVE, actionOk: false, action: 'book_venue',
        meta: { code: out.code },
        chips: short
          ? [chip('Top up wallet', 'topup_help'), chip('Cheaper grounds', 'find_venue',
            { maxPrice: Math.max(0, Math.floor(live * 0.7)) })]
          : [chip('Show times', 'check_availability', { venueId: c.venueId, date: c.date })],
      }),
    state: { intent: null, pending: null, slots: {}, confirm: null } };
  }

  const b = out.data;
  const dep = asNum(b.deposit_amount);
  return {
    reply: reply(
      `Booked. ${b.venue_name}, ${day(dateStr(b.slot_date))} at ${clock(b.start_time)}. `
      + `${money(b.total_amount)} is held in escrow and the owner will approve it shortly. `
      + `Show your QR at the ground to check in — ${money(dep)} `
      + `(${POLICY.DEPOSIT_PERCENT}%) is at risk if you no-show.`, {
        source: SOURCES.LIVE, action: 'book_venue', actionOk: true,
        cards: [bookingCard({ ...b, city: got.data.city })],
        chips: [chip('My bookings', 'my_bookings'),
          chip('Directions', 'navigate', { venueId: b.venue_id }),
          chip('Find players', 'find_players')],
      }),
    // The flow is finished. Clearing slots as well as confirm matters: a leftover
    // venueId would make the next unrelated "kal 6 baje?" resolve to this ground.
    state: { intent: null, pending: null, slots: {}, confirm: null },
  };
}

/**
 * `cancel_booking` — list what is cancellable, then quote the refund, then ask.
 *
 * The refund is quoted before the question, which is the spec's requirement
 * ("You'll get PKR 1,600 back (80%) — confirm?") and also the only honest way to
 * ask: a late cancellation forfeits the deposit, and a user who is not shown that
 * number before answering has not been asked a fair question.
 *
 * With exactly one cancellable booking Scout still shows the confirm card rather
 * than acting. One booking is not consent.
 */
async function cancelBooking(ctx) {
  const { client, userId, slots = {} } = ctx;

  if (!slots.bookingId) {
    const rows = await booking.listCancellable(client, { userId, limit: 5 });
    if (!rows.length) {
      return { reply: reply('You have no upcoming bookings to cancel.', {
        source: SOURCES.LIVE,
        chips: [chip('My bookings', 'my_bookings'), chip('Book a ground', 'book_venue')],
      }), state: { intent: null, pending: null, slots: {}, confirm: null } };
    }
    if (rows.length > 1) {
      return { reply: reply('Which booking should I cancel?', {
        source: SOURCES.LIVE,
        cards: rows.map((r) => bookingCard(r, {
          buttons: [chip('Cancel this one', 'cancel_booking', { bookingId: r.id })] })),
        chips: rows.slice(0, 4).map((r) => chip(
          `${r.venue_name} ${clock(r.start_time)}`, 'cancel_booking', { bookingId: r.id })),
      }), state: { intent: 'cancel_booking', pending: 'booking', slots } };
    }
    slots.bookingId = rows[0].id;
  }

  const pv = await booking.previewCancellation(client, { userId, bookingId: slots.bookingId });
  if (!pv.ok) {
    return { reply: reply(pv.message, {
      source: SOURCES.LIVE, actionOk: false, action: 'cancel_booking',
      meta: { code: pv.code },
      chips: [chip('My bookings', 'my_bookings')],
    }), state: { intent: null, pending: null, slots: {}, confirm: null } };
  }
  const p = pv.data;
  const late = p.late
    ? `That is inside the ${p.windowHours}-hour window, so ${money(p.penalty)} of the deposit `
      + 'goes to the venue.'
    : `That is more than ${p.windowHours} hours away, so you get the full amount back.`;
  return {
    reply: reply(
      `Cancelling ${p.venueName}, ${day(p.slotDate)} at ${clock(p.startTime)}: you get `
      + `${money(p.refund)} back (${p.refundPct}%). ${late} Confirm?`, {
        source: SOURCES.LIVE,
        cards: [confirmCard({
          what: 'cancel_booking',
          title: `Cancel ${p.venueName}`,
          lines: [
            { label: 'Day', value: day(p.slotDate) },
            { label: 'Time', value: clock(p.startTime) },
            { label: 'Held in escrow', value: money(p.escrow) },
            { label: 'Refund to wallet', value: `${money(p.refund)} (${p.refundPct}%)` },
            ...(p.penalty > 0
              ? [{ label: 'Deposit forfeited', value: money(p.penalty) }] : []),
          ],
          total: p.refund,
          deposit: p.penalty > 0 ? p.penalty : null,
          note: late,
          yes: 'Yes, cancel it',
          no: 'Keep it',
        })],
      }),
    state: {
      intent: 'cancel_booking',
      pending: null,
      slots: { bookingId: p.bookingId },
      confirm: {
        action: 'cancel_booking',
        bookingId: p.bookingId,
        venueName: p.venueName,
        refund: p.refund,
        penalty: p.penalty,
        late: p.late,
      },
    },
  };
}

/**
 * Execute a confirmed cancellation.
 *
 * The numbers reported are the ones cancelBooking moved, never the quoted
 * ones. previewCancellation says so in its own header: if the 24-hour boundary is
 * crossed between the quote and the confirmation, the real refund is smaller, and
 * a Scout that repeated its own quote would be telling the user something false
 * about their wallet. When the two differ Scout says so out loud.
 */
async function executeCancel(ctx) {
  const { client, userId } = ctx;
  const c = ctx.confirm || {};
  if (!c.bookingId) {
    return { reply: reply('I lost track of which booking that was.', {
      source: SOURCES.LIVE, chips: [chip('My bookings', 'my_bookings')],
    }), state: { intent: null, pending: null, slots: {}, confirm: null } };
  }

  const out = await withSavepoint(client, () => booking.cancelBooking(client, {
    userId, bookingId: c.bookingId }));

  if (!out.ok) {
    return { reply: reply(`I could not cancel that: ${out.message}`, {
      source: SOURCES.LIVE, actionOk: false, action: 'cancel_booking',
      meta: { code: out.code },
      chips: [chip('My bookings', 'my_bookings')],
    }), state: { intent: null, pending: null, slots: {}, confirm: null } };
  }

  const r = out.data;
  const drifted = c.refund != null && round2(c.refund) !== round2(r.refund);
  const note = drifted
    ? ` The quote changed while we were talking — the actual refund is ${money(r.refund)}.`
    : '';
  return {
    reply: reply(
      `Cancelled. ${money(r.refund)} is back in your wallet`
      + `${r.penalty > 0 ? ` and ${money(r.penalty)} of the deposit went to ${r.venueName}` : ''}`
      + `.${note} The slot is free for other players again.`, {
        source: SOURCES.LIVE, action: 'cancel_booking', actionOk: true,
        chips: [chip('Wallet', 'wallet_balance'), chip('Book another', 'book_venue'),
          chip('Refund rules', 'refund_policy')],
      }),
    state: { intent: null, pending: null, slots: {}, confirm: null },
  };
}

// Reads — "my bookings", "wallet", "my elo", tournaments, policy

/**
 * `my_bookings`. Upcoming first, because that is what a person means when they ask
 * on a Friday afternoon; a status word in the utterance ("cancelled wale") narrows
 * it instead of being ignored.
 */
async function myBookings(ctx) {
  const { client, userId, slots = {} } = ctx;
  const want = ['pending', 'confirmed', 'completed', 'cancelled', 'checked_in']
    .includes(String(slots.status || '')) ? String(slots.status) : null;
  const rows = await booking.listMyBookings(client, { userId, status: want, limit: 20 });
  if (!rows.length) {
    return { reply: reply(
      want ? `You have no ${want} bookings.` : 'You have no bookings yet.', {
        source: SOURCES.LIVE,
        chips: [chip('Book a ground', 'book_venue'), chip('Find a ground', 'find_venue')],
      }) };
  }
  const today = discovery.pktNow().date;
  const upcoming = rows.filter((r) => dateStr(r.slot_date) >= today
    && ['pending', 'confirmed', 'checked_in'].includes(r.status));
  const show = (upcoming.length ? upcoming : rows).slice(0, 5);
  const pend = show.filter((r) => r.status === 'pending').length;
  const head = upcoming.length
    ? `You have ${upcoming.length} upcoming booking${upcoming.length === 1 ? '' : 's'}`
      + `${pend ? `, ${pend} still waiting on owner approval` : ''}:`
    : `Your last ${show.length} booking${show.length === 1 ? '' : 's'}:`;
  return { reply: reply(head, {
    source: SOURCES.LIVE,
    cards: show.map((r) => bookingCard(r)),
    chips: [chip('Book another', 'book_venue'),
      ...(upcoming.length ? [chip('Cancel one', 'cancel_booking')] : []),
      chip('Refund rules', 'refund_policy')],
  }) };
}

/**
 * `wallet_balance`.
 *
 * SQL exception 1 of 3 (see the file header). One row, one table, no derived rule:
 * `balance` is spendable and `frozen_balance` is money already committed to
 * bookings in escrow. Routing this through a service would add a layer that owns
 * nothing.
 *
 * The two numbers are reported separately on purpose. A player who sees a single
 * total and then hits `insufficient_funds` at the confirm card has been misled by
 * their own assistant.
 */
async function walletBalance(ctx) {
  const { client, userId } = ctx;
  const { rows } = await client.query(
    'SELECT balance, frozen_balance FROM wallets WHERE user_id = $1', [userId]);
  const w = rows[0] || { balance: 0, frozen_balance: 0 };
  const free = asNum(w.balance);
  const held = asNum(w.frozen_balance);
  const heldNote = held > 0
    ? ` ${money(held)} is held in escrow for bookings you have not played yet.`
    : '';
  return { reply: reply(
    `You have ${money(free)} available to spend.${heldNote}`, {
      source: SOURCES.LIVE,
      cards: [card(CARDS.WALLET, {
        balance: free,
        balanceLabel: money(free),
        frozen: held,
        frozenLabel: money(held),
        total: round2(free + held),
        totalLabel: money(free + held),
        withdrawalMin: POLICY.WITHDRAWAL_MIN_AMOUNT,
        buttons: [chip('Top up', 'topup_help'), chip('Book a ground', 'book_venue')],
      })],
      chips: [chip('How do I top up?', 'topup_help'),
        chip('Withdraw rules', 'refund_policy', { topic: 'withdrawal' }),
        chip('My bookings', 'my_bookings')],
    }) };
}

/**
 * The seven policy topics, keyed by the words a user types.
 *
 * This is topic routing, not policy: every sentence and every number still comes
 * from utils/policyText.js, which renders escrow.js POLICY into the editable
 * wording in global_settings. Adding a synonym here can change which rule Scout

/**
 * A timestamptz as a PKT calendar day.
 *
 * `registration_deadline` is an instant, not a date, so it needs the PKT offset
 * added — the opposite correction to dateStr(), which undoes a local-midnight date.
 * Getting this backwards moves a deadline by a day, and a deadline is the one
 * number on a tournament card a team cannot afford to read wrong.
 */
function pktDay(ts) {
  if (!(ts instanceof Date)) return dateStr(ts);
  return new Date(ts.getTime() + discovery.PKT_OFFSET_MS).toISOString().slice(0, 10);
}

/**
 * "closes in 4 hours" — the sentence a countdown makes, not the timer itself.
 *
 * The phone gets `secondsToDeadline` from the REST payload and animates it; a chat
 * bubble is written once and read later, so it says the size of the gap rather than
 * a precise number that will be wrong by the time it is read. Past deadlines are
 * reported as closed instead of as a negative, which is how a stale card betrays
 * itself.
 */
function untilLabel(when) {
  const ms = new Date(when).getTime() - Date.now();
  if (!Number.isFinite(ms)) return null;
  if (ms <= 0) return 'closed';
  const mins = Math.round(ms / 60000);
  if (mins < 90) return `${mins} minute${mins === 1 ? '' : 's'} left`;
  const hrs = Math.round(mins / 60);
  if (hrs < 48) return `${hrs} hours left`;
  return `${Math.round(hrs / 24)} days left`;
}

/**
 * A tournament card, built once — the same rule bookingCard follows.
 *
 * It reads either shape on purpose. `tournament_list` has snake_case rows straight
 * from discoveryService, and `tournament_detail` has the camelCase payload
 * `GET /api/tournaments/:id` returns; making two card builders would mean the browse
 * bubble and the detail bubble could render the same cup differently, which is the
 * exact failure this file avoids for venues, bookings and players already.
 *
 * Nothing is invented: a value that neither shape carries stays null, so a Flutter
 * widget can tell "no prize pool yet" from "prize pool of zero".
 */
function tournamentCard(t, { buttons = null } = {}) {
  const venue = t.venue || {};
  const fee = asNum(t.entry_fee == null ? t.entryFee : t.entry_fee, 0);
  const maxTeams = Number(t.max_teams == null ? t.maxTeams : t.max_teams) || null;
  const teamsIn = Number((t.teams_in == null ? t.teamsRegistered : t.teams_in) || 0);
  const start = t.start_date || t.startDate || null;
  const startDay = start ? dateStr(start) : null;
  const raw = t.registration_deadline == null ? t.registrationDeadline : t.registration_deadline;
  // Coerced to a Date before pktDay sees it: the camelCase payload carries the
  // deadline as an ISO string, and pktDay's string path takes the UTC day, which is
  // the wrong day for anything after 7pm PKT. See pktDay's own comment.
  const rawDeadline = raw instanceof Date ? raw : (raw ? new Date(raw) : null);
  const deadline = rawDeadline && !Number.isNaN(rawDeadline.getTime()) ? pktDay(rawDeadline) : null;
  const prize = t.prize_amount == null ? t.prize : t.prize_amount;
  const spots = maxTeams == null ? null : Math.max(0, maxTeams - teamsIn);

  return card(CARDS.TOURNAMENT, {
    id: t.id,
    name: t.name,
    sport: t.sport || null,
    format: t.format || null,
    status: t.status || null,
    venueId: t.venue_id || venue.id || null,
    venueName: t.venue_name || venue.name || null,
    city: t.venue_city || venue.city || null,
    organiser: t.organiser_name || t.organiserName || t.ownerName || null,
    entryFee: fee,
    entryFeeLabel: fee > 0 ? money(fee) : 'Free entry',
    startDate: startDay,
    startLabel: startDay ? day(startDay) : null,
    deadline,
    deadlineLabel: deadline ? day(deadline) : null,
    closesIn: rawDeadline ? untilLabel(rawDeadline) : null,
    maxTeams,
    teamsIn,
    spotsLeft: t.spotsLeft == null ? spots : Number(t.spotsLeft),
    isFull: t.isFull == null ? (maxTeams != null && teamsIn >= maxTeams) : Boolean(t.isFull),
    prize: prize == null ? null : asNum(prize, 0),
    prizeLabel: prize == null || asNum(prize, 0) <= 0 ? null : money(prize),
    winnerName: t.winner_name || t.winnerName || null,
    runnerUpName: t.runner_up_name || t.runnerUpName || null,
    buttons: buttons || [chip('Details', 'tournament_detail', { tournamentId: t.id })],
  });
}

/**
 * `tournament_list`. The table is empty on a fresh database, and that is a real
 * answer rather than an error — Scout says nothing is open and offers the things
 * that are, instead of implying the feature is broken.
 *
 * The card itself is `tournamentCard`, shared with `tournament_detail` so browse and
 * detail cannot render the same cup two ways. `city` comes from the VENUE, because
 * tournaments have no city of their own.
 *
 * The chips are the module's whole front door: `Details` opens the bracket and
 * `Enter this cup` opens the entry flow. Neither spends anything — 019 gave every
 * tournament a real entry fee, so the only path to a charge is the confirm card that
 * `tournament_register` arms.
 */
async function tournamentList(ctx) {
  const { client, slots = {} } = ctx;
  const rows = await discovery.listTournaments(client, {
    sport: slots.sport || null, openOnly: true, limit: 5 });
  if (!rows.length) {
    const any = await discovery.listTournaments(client, { openOnly: false, limit: 3 });
    return { reply: reply(
      any.length
        ? 'No tournaments are open for registration right now — the ones on SportLynk have '
          + 'already started or finished.'
        : 'There are no tournaments on SportLynk yet. I will list them here as soon as an '
          + 'organiser posts one.', {
        source: SOURCES.LIVE,
        chips: [chip('Find opponents', 'find_opponents'), chip('Book a ground', 'book_venue')],
      }) };
  }
  return { reply: reply(
    `${rows.length} tournament${rows.length === 1 ? '' : 's'} open for registration:`, {
      source: SOURCES.LIVE,
      cards: rows.map((t) => tournamentCard(t, {
        buttons: [
          chip('Details', 'tournament_detail', { tournamentId: t.id }),
          // Offered on the card, never fired by it: the chip opens the entry flow,
          // which resolves the team, checks the wallet and asks for a confirmation
          // before a rupee moves. `isFull` is respected here so the button is not
          // painted onto a cup that cannot accept it.
          ...(t.isFull ? [] : [chip('Enter this cup', 'tournament_register', { tournamentId: t.id })]),
          ...(t.venue_id ? [chip('Ground info', 'venue_info', { venueId: t.venue_id })] : []),
        ],
      })),
      chips: [chip('My tournaments', 'my_tournaments'), chip('My teams', 'team_stats'),
        chip('Find opponents', 'find_opponents')],
    }) };
}


/**
 * `tournament_detail` — one cup: the field, the bracket and the money.
 *
 * Chip-only, and it must stay that way. The classifier has 23 labels and none of them
 * is "that tournament": a sentence cannot carry a uuid, so a trained label here would
 * mean Scout guessing which cup a user meant and showing them somebody else's bracket.
 * The id arrives in a chip's args instead — the same door `pick_slot` uses, for the
 * same reason. No trained labels are added for it, so the released artifact and its
 * 23 labels stay byte-identical.
 *
 * Every number below comes from `tournamentService.detail`, which is exactly what
 * `GET /api/tournaments/:id` calls. Scout computes no standing, no countdown and no
 * prize share of its own (FR8.15): the bubble and the screen read one implementation,
 * so they cannot disagree about who is winning or what the champion gets paid.
 */
async function tournamentDetail(ctx) {
  const { client, userId, slots = {} } = ctx;
  const id = String(slots.tournamentId || '').trim();
  // A chip that arrived without its argument is an integration slip, not a
  // conversation problem — and the useful answer is the list the user was about to
  // pick from, with the ids attached, rather than an apology.
  if (!id) return tournamentList(ctx);

  const out = await T.detail(client, { tournamentId: id, userId });
  if (!out.ok) {
    return {
      reply: reply(out.message, {
        source: SOURCES.LIVE, action: 'tournament_detail', actionOk: false,
        meta: { code: out.code },
        chips: [chip('Tournaments', 'tournament_list'), chip('My tournaments', 'my_tournaments')],
      }),
      state: { intent: null, pending: null, slots: {}, confirm: null },
    };
  }

  const d = out.data;
  const t = d.tournament;
  const e = d.economics || {};
  const v = d.viewer || {};
  const b = d.bracket || {};
  const deadline = t.registrationDeadline ? new Date(t.registrationDeadline) : null;
  const shape = t.format === 'round_robin' ? 'round robin' : 'knockout';
  const where = [t.venue.name, t.venue.city].filter(Boolean).join(', ');

  const said = [`${t.name} — ${shape}${where ? ` at ${where}` : ''}.`];
  said.push(`${t.teamsRegistered}/${t.maxTeams} teams in`
    + `${t.entryFee > 0 ? ` at ${money(t.entryFee)} entry` : ', free entry'}.`);

  // The four states a cup can be read in, each one a different question the user is
  // asking: can I still enter, when is my match, who won, what happened.
  if (t.status === 'cancelled') {
    said.push('It was cancelled and every entry fee went back to the team that paid it.');
  } else if (t.status === 'completed' && t.winnerName) {
    said.push(`${t.winnerName} won it${t.runnerUpName ? `, with ${t.runnerUpName} runner-up` : ''}`
      + `${asNum(e.winnerShare) > 0 ? ` — ${money(e.winnerShare)} to the champions` : ''}.`);
  } else if (b.generated) {
    said.push(`The bracket is drawn: ${b.played} of ${b.total} fixtures played over `
      + `${b.rounds} round${b.rounds === 1 ? '' : 's'}`
      + `${b.byes ? `, ${b.byes} bye${b.byes === 1 ? '' : 's'} to the top seeds` : ''}.`);
  } else if (deadline) {
    const left = untilLabel(deadline);
    said.push(left === 'closed'
      ? 'Registration has closed — the bracket is drawn automatically on the next sweep.'
      : `Registration closes ${day(pktDay(deadline))} (${left}), and the bracket is drawn `
        + 'automatically at the deadline, seeded on ELO.');
  }

  // Where the user personally stands. `myRegistration` is the captain's own entry; a
  // round robin has a table worth reciting in a sentence and a knockout does not, so
  // the two formats answer "how is it going" differently.
  const mine = v.myRegistration;
  if (mine) {
    said.push(`${mine.teamName} is entered${mine.seed ? ` as seed ${mine.seed}` : ''}`
      + `${mine.status === 'registered' ? ', waiting on the organiser' : ''}.`);
    const next = (d.fixtures || []).find((f) => f.status === 'upcoming'
      && (f.teamA === mine.teamId || f.teamB === mine.teamId));
    if (next) {
      const foe = next.teamA === mine.teamId ? next.teamBName : next.teamAName;
      const odds = next.teamA === mine.teamId ? next.winProbabilityA : next.winProbabilityB;
      said.push(`Next: ${next.label || `round ${next.round}`} against `
        + `${foe || 'a team still to be decided'}`
        + `${next.slotDate ? ` on ${day(dateStr(next.slotDate))} at ${clock(next.startTime)}` : ''}`
        // The Elo formula, named as itself. It is arithmetic on two ratings, not a
        // trained model, and calling it one would be a claim a viva panel can check.
        + `${odds == null ? '' : ` — Elo gives you ${Math.round(odds * 100)}%`}.`);
    }
  } else if (t.format === 'round_robin' && (d.standings || []).length) {
    const top = d.standings[0];
    said.push(`${top.teamName} leads the table on ${top.points} point${top.points === 1 ? '' : 's'}.`);
  }

  if (asNum(e.prize) > 0) {
    said.push(`${e.settled ? 'Prize pool' : 'Projected prize pool'} ${money(e.prize)}: `
      + `${money(e.winnerShare)} to the winner, ${money(e.runnerupShare)} to the runner-up.`);
  }
  if (t.format === 'knockout' && b.generated && !e.settled) {
    said.push('A drawn knockout tie goes to the higher seed.');
  }

  const enter = chip('Enter this cup', 'tournament_register', { tournamentId: t.id });
  const chips = [];
  // `canRegister` is the service's answer to "may I, personally, press this" — open,
  // not full, not the organiser, has an eligible squad, can afford the fee. Scout does
  // not re-derive any of it: painting a button the API would refuse is worse than
  // painting none.
  if (v.canRegister) chips.push(enter);
  else if (v.canAfford === false && t.registrationOpen) chips.push(chip('Add money', 'topup_help'));
  if (t.venue.id) chips.push(chip('Ground info', 'venue_info', { venueId: t.venue.id }));
  chips.push(chip('My tournaments', 'my_tournaments'));
  chips.push(chip('Open Tournaments', 'app_help', { screen: 'tournaments' }));

  return {
    reply: reply(said.join(' '), {
      source: SOURCES.LIVE, action: 'tournament_detail', actionOk: true,
      cards: [tournamentCard(t, {
        buttons: [
          ...(v.canRegister ? [enter] : []),
          ...(t.venue.id ? [chip('Ground info', 'venue_info', { venueId: t.venue.id })] : []),
        ],
      })],
      chips,
      meta: {
        rounds: b.rounds || null,
        fixtures: b.total || 0,
        played: b.played || 0,
        generated: Boolean(b.generated),
      },
    }),
    // The id survives the turn so a follow-up ("enter it", "kitna hai?") is about this
    // cup. `tournamentId` is a DECISION slot in dialogManager, so the moment the user
    // changes subject it is dropped rather than carried into the next errand.
    state: {
      intent: 'tournament_detail',
      pending: null,
      confirm: null,
      slots: { tournamentId: t.id },
    },
  };
}


/**
 * `tournament_register` — the entry flow, and the only tournament money door.
 *
 * Chip-only, for a harder reason than `tournament_detail`. This one spends: the entry
 * fee leaves the captain's balance the moment it succeeds. The S.6 rule stands
 * unchanged — money is reached by a chip and confirmed by the frozen lexicon, never by
 * a probability — so there is no trained label for it, and the classifier cannot start
 * an entry no matter what a user types. The path is: a card Scout painted → this
 * action → a confirm card → `executeTournamentEntry`.
 *
 * Nothing here writes. Every branch below either refuses with the service's own reason
 * or arms a confirmation, which lives exactly one turn (see dialogManager's confirm
 * gate). That is what makes it impossible for yesterday's "haan" to enter a cup today.
 */
async function tournamentRegister(ctx) {
  const { client, userId, slots = {} } = ctx;
  const id = String(slots.tournamentId || '').trim();
  // Which cup is not a guess Scout is allowed to make: the list it just painted has
  // the ids on its buttons, so re-offering it is both the safe answer and the useful
  // one. `tournamentList` puts an "Enter this cup" chip on every cup with room.
  if (!id) return tournamentList(ctx);

  const out = await T.detail(client, { tournamentId: id, userId });
  if (!out.ok) {
    return {
      reply: reply(out.message, {
        source: SOURCES.LIVE, action: 'tournament_register', actionOk: false,
        meta: { code: out.code },
        chips: [chip('Tournaments', 'tournament_list')],
      }),
      state: { intent: null, pending: null, slots: {}, confirm: null },
    };
  }

  const d = out.data;
  const t = d.tournament;
  const v = d.viewer || {};
  const e = d.economics || {};
  const detailChip = chip('Bracket and details', 'tournament_detail', { tournamentId: t.id });
  // Every refusal ends the same way: say why, offer the way forward, keep the cup as
  // the subject so the next sentence is still about it.
  const no = (text, extra = []) => ({
    reply: reply(text, {
      source: SOURCES.LIVE, action: 'tournament_register', actionOk: false,
      chips: [...extra, detailChip, chip('Tournaments', 'tournament_list')],
    }),
    state: { intent: 'tournament_register', pending: null, confirm: null,
      slots: { tournamentId: t.id } },
  });

  // May this cup be entered at all
  // Read in the order a person would ask it, and every answer is the state the
  // service would refuse with anyway, said in a sentence instead of a code.
  if (v.isOwner) {
    return no(`You are the organiser of ${t.name} — an owner cannot enter their own `
      + 'tournament. Teams enter it, and you keep the venue cost plus the margin.');
  }
  if (v.myRegistration) {
    return no(`${v.myRegistration.teamName} is already entered in ${t.name}`
      + `${v.myRegistration.status === 'registered' ? ', waiting on the organiser to approve it' : ''}.`);
  }
  if (t.status !== 'open') {
    return no(t.status === 'cancelled'
      ? `${t.name} was cancelled.`
      : `${t.name} has already started — the bracket is drawn and the field is closed.`);
  }
  if (t.spotsLeft <= 0) {
    return no(`${t.name} is full at ${t.maxTeams} teams.`);
  }
  if (!t.registrationOpen) {
    return no(`Registration for ${t.name} closed on ${day(pktDay(new Date(t.registrationDeadline)))}.`);
  }

  // Which squad
  // `eligibleTeams` is the service's list: teams this user captains, in this
  // tournament's sport, not already entered. Only a captain can enter a team and only
  // a captain can be paid a prize, so a member of somebody else's squad is told the
  // truth rather than shown a button that would 403.
  const teams = v.eligibleTeams || [];
  if (!teams.length) {
    return no(`You need a ${t.sport} team you captain to enter ${t.name}`
      + `${v.isCaptain ? ' — the squads you captain are either in it already or play another sport.' : '.'}`,
    [chip('My teams', 'team_stats'), chip('Create a team', 'create_team_help')]);
  }
  const asked = String(slots.teamId || '').trim();
  const chosen = teams.find((x) => String(x.id) === asked)
    || (teams.length === 1 ? teams[0] : null);
  if (!chosen) {
    return {
      reply: reply(`Which squad is entering ${t.name}?`, {
        source: SOURCES.LIVE,
        cards: teams.slice(0, 5).map((x) => teamCard(
          { id: x.id, name: x.name, sport: t.sport, elo: x.elo, logo_url: x.logoUrl },
          { buttons: [chip('Enter with this team', 'tournament_register',
            { tournamentId: t.id, teamId: x.id })] },
        )),
        chips: teams.slice(0, 4).map((x) => chip(x.name, 'tournament_register',
          { tournamentId: t.id, teamId: x.id })),
      }),
      // `pending: 'team'` is a TAP question (see dialogManager's TAP_PENDING), so the
      // turn is recorded as awaiting a choice rather than as slot filling.
      state: { intent: 'tournament_register', pending: 'team', confirm: null,
        slots: { tournamentId: t.id } },
    };
  }

  // The money
  const fee = asNum(t.entryFee, 0);
  const balance = v.walletBalance;
  if (balance != null && balance < fee) {
    return no(`${t.name} costs ${money(fee)} to enter and you have ${money(balance)} available`
      + ` — ${money(round2(fee - balance))} short.`,
    [chip('Add money', 'topup_help'), chip('Wallet', 'wallet_balance')]);
  }

  // Arm the confirmation
  // The card states the four things a captain is agreeing to: what leaves the wallet,
  // what it buys, what happens if they win, and when the money stops being theirs to
  // take back. `withdraw` is allowed until the bracket is drawn, which is the honest
  // version of "held" and the reason the note says it out loud.
  const held = t.requiresApproval
    ? 'The organiser approves entries, so the fee is held until they decide — rejected, and it comes straight back.'
    : 'The fee is held in escrow until the bracket is drawn; withdraw before the deadline and you get all of it back.';
  const winnerShare = asNum(e.winnerShare, 0);
  return {
    reply: reply(
      `Entering ${chosen.name} in ${t.name} costs ${money(fee)}`
      + `${balance == null ? '' : `, leaving ${money(round2(balance - fee))} available`}. `
      + `${winnerShare > 0 ? `The champions take ${money(winnerShare)}. ` : ''}Confirm?`, {
        source: SOURCES.LIVE,
        cards: [confirmCard({
          what: 'tournament_register',
          title: `Enter ${t.name}`,
          lines: [
            { label: 'Team', value: chosen.name },
            { label: 'Format', value: t.format === 'round_robin' ? 'Round robin' : 'Knockout' },
            { label: 'Venue', value: [t.venue.name, t.venue.city].filter(Boolean).join(', ') || '—' },
            { label: 'Entry fee', value: money(fee) },
            ...(balance == null ? []
              : [{ label: 'Wallet after', value: money(round2(balance - fee)) }]),
            ...(winnerShare > 0 ? [{ label: 'If you win', value: money(winnerShare) }] : []),
            { label: 'Registration closes', value: day(pktDay(new Date(t.registrationDeadline))) },
          ],
          total: fee,
          note: held,
          yes: 'Yes, enter',
          no: 'Not now',
        })],
      }),
    state: {
      intent: 'tournament_register',
      pending: null,
      slots: { tournamentId: t.id, teamId: chosen.id, teamName: chosen.name },
      // What the executor reads. The quote is carried so the reply can own up to a
      // change: an organiser may edit the fee between this turn and the next one.
      confirm: {
        action: 'tournament_register',
        tournamentId: t.id,
        tournamentName: t.name,
        teamId: chosen.id,
        teamName: chosen.name,
        fee,
        requiresApproval: Boolean(t.requiresApproval),
      },
    },
  };
}

/**
 * The executor behind a confirmed entry. Reached only through dialogManager's confirm
 * gate, which fires on the chip or on a whole-utterance affirm from the frozen
 * lexicon — never on a model score. By the time this runs the captain has seen the
 * fee, the wallet after, and the prize, on a card.
 *
 * The write itself belongs to `tournamentService.register`: it takes the tournament
 * FOR UPDATE, re-checks the deadline and the cap, and moves the fee balance → frozen
 * in the same transaction. Scout does not re-implement one line of that, which is
 * what keeps the FR8.15 census (no wallet or ledger calls in this file) true.
 */
async function executeTournamentEntry(ctx) {
  const { client, userId } = ctx;
  const c = ctx.confirm || {};
  if (!c.tournamentId || !c.teamId) {
    return { reply: reply('I lost track of which tournament that was.', {
      source: SOURCES.LIVE, chips: [chip('Tournaments', 'tournament_list')],
    }), state: { intent: null, pending: null, slots: {}, confirm: null } };
  }

  const out = await withSavepoint(client, () => T.register(client, {
    userId, tournamentId: c.tournamentId, teamId: c.teamId }));

  if (!out.ok) {
    // The service re-checks everything under a row lock, so a refusal here is a real
    // race — the last spot went, or the deadline passed while the card was on screen.
    return { reply: reply(`I could not enter that: ${out.message}`, {
      source: SOURCES.LIVE, actionOk: false, action: 'tournament_register',
      meta: { code: out.code },
      chips: [
        ...(out.code === 'insufficient_funds' ? [chip('Add money', 'topup_help')] : []),
        chip('Bracket and details', 'tournament_detail', { tournamentId: c.tournamentId }),
        chip('Tournaments', 'tournament_list'),
      ],
    }), state: { intent: null, pending: null, slots: {}, confirm: null } };
  }

  const r = out.data.registration;
  const cup = out.data.tournament || {};
  const paid = asNum(r.paidAmount, 0);
  // Own up to a changed quote rather than quietly charging a different number: the
  // organiser can edit the fee while the confirmation is on screen.
  const drifted = c.fee != null && round2(asNum(c.fee)) !== round2(paid);
  const note = drifted
    ? ` The fee changed while we were talking — ${money(paid)} is what was actually held.`
    : '';
  const pending = r.status === 'registered' && r.requiresApproval;
  return {
    reply: reply(
      pending
        ? `Entry submitted. ${money(paid)} is held while ${cup.ownerName || 'the organiser'} `
          + `reviews it — if they reject it, every rupee comes straight back.${note}`
        : `${r.teamName} is in ${cup.name || 'the tournament'}. ${money(paid)} is held in escrow`
          + ` until the bracket is drawn, and you can withdraw for a full refund until then.`
          + `${note}`,
      {
        source: SOURCES.LIVE, action: 'tournament_register', actionOk: true,
        cards: [tournamentCard(cup, { buttons: [
          chip('Bracket and details', 'tournament_detail', { tournamentId: c.tournamentId })] })],
        chips: [chip('My tournaments', 'my_tournaments'), chip('Wallet', 'wallet_balance'),
          chip('Tournaments', 'tournament_list')],
      }),
    // The subject stays the cup: "kab shuru hoga" right after this should not have to
    // name it again.
    state: { intent: 'tournament_register', pending: null, confirm: null,
      slots: { tournamentId: c.tournamentId } },
  };
}

/**
 * `my_tournaments` — chip-only, and a read.
 *
 * Chip-only not because it spends but because it does not exist in the released
 * classifier's 23 labels, and S.6's rule is that the label set is frozen: adding a
 * trained label means retraining and re-releasing model #4, which this work does not
 * do. A user who types "meray tournaments" lands on `my_bookings`-style routing or a
 * clarify, and the chip on every tournament card gets them here in one tap.
 *
 * Two lists, because a venue owner is both organiser and — through a team they
 * captain — potentially a competitor. Organising comes first for them; a player only
 * ever sees the one they are in.
 */
async function myTournaments(ctx) {
  const { client, userId } = ctx;
  const out = await T.mine(client, { userId });
  if (!out.ok) {
    return { reply: reply(out.message, {
      source: SOURCES.LIVE, actionOk: false, action: 'my_tournaments',
      meta: { code: out.code },
      chips: [chip('Tournaments', 'tournament_list')],
    }) };
  }
  const organising = out.data.organising || [];
  const playing = out.data.playing || [];
  if (!organising.length && !playing.length) {
    return { reply: reply(
      'You are not in any tournament yet. Owners post them and captains enter a squad'
      + ' — the entry fee is the only thing you pay, and the venue slots come with it.', {
        source: SOURCES.LIVE, action: 'my_tournaments', actionOk: true,
        chips: [chip('Open tournaments', 'tournament_list'), chip('My teams', 'team_stats'),
          chip('Find opponents', 'find_opponents')],
      }) };
  }

  // The entry's own state, in the words a captain would use for it. 'registered' is
  // deliberately not softened to "entered": the fee is held and the organiser has not
  // said yes yet, and Scout claiming otherwise is Scout lying about money.
  const entryWord = (s) => ({
    registered: 'waiting on the organiser', accepted: 'confirmed',
    eliminated: 'knocked out', withdrawn: 'withdrawn',
  }[String(s)] || String(s || ''));
  const cupWord = (s) => ({
    open: 'registration open', active: 'in progress',
    completed: 'finished', cancelled: 'cancelled',
  }[String(s)] || String(s || ''));

  // One sentence, then the cards carry the structure — the house style
  // everywhere in this file. A bulleted block would read as a report; Scout answers
  // in prose, and the separator is the same middle dot the rest of the file uses.
  const DOTS = ' · ';
  const said = [];
  playing.slice(0, 4).forEach((t) => {
    const m = t.myEntry || {};
    const seed = m.seed ? `, seed ${m.seed}` : '';
    const won = t.status === 'completed' && t.winnerTeam && t.winnerTeam === m.teamId;
    said.push(`${t.name} with ${m.teamName}${seed} — `
      + `${won ? 'CHAMPIONS' : entryWord(m.status)}, ${cupWord(t.status)}`);
  });
  organising.slice(0, 4).forEach((t) => {
    said.push(`${t.name}, yours to run — ${t.teamsRegistered}/${t.maxTeams} teams`
      + `, ${cupWord(t.status)}`);
  });

  const head = [
    playing.length ? `You are in ${playing.length} tournament${playing.length === 1 ? '' : 's'}` : null,
    organising.length ? `running ${organising.length}` : null,
  ].filter(Boolean).join(' and ');
  const show = [...playing, ...organising].slice(0, 5);
  return {
    reply: reply(`${head}.${DOTS}${said.join(DOTS)}.`, {
      source: SOURCES.LIVE, action: 'my_tournaments', actionOk: true,
      cards: show.map((t) => tournamentCard(t, { buttons: [
        chip('Bracket and details', 'tournament_detail', { tournamentId: t.id })] })),
      chips: [chip('Open tournaments', 'tournament_list'), chip('Wallet', 'wallet_balance'),
        chip('My teams', 'team_stats')],
      meta: { organising: organising.length, playing: playing.length },
    }),
    state: { intent: 'my_tournaments', pending: null, confirm: null, slots: {} },
  };
}

// People and TEAMS — the ranked answers, all of them through rosterService

/**
 * A player card. `matchPct` and `reasons` come from model #4's ranker via
 * rosterService and are passed through unchanged, null included — the same rule
 * venueCard follows, for the same reason.
 */
function playerCard(p) {
  return card(CARDS.PLAYER, {
    id: p.id || p.user_id,
    name: p.name,
    city: p.city || null,
    position: p.position || p.preferred_position || null,
    skill: p.skill_level || null,
    trustScore: p.trust_score == null ? null : Number(p.trust_score),
    matchesPlayed: p.matches_played == null ? null : Number(p.matches_played),
    matchPct: p.matchPct == null ? null : Number(p.matchPct),
    reasons: Array.isArray(p.reasons) ? p.reasons : [],
    photo: p.profile_photo || p.avatar_url || null,
    buttons: [chip('View profile', 'app_help', { screen: 'player', id: p.id || p.user_id })],
  });
}

/** A team card, used by find_teams, find_opponents and team_stats. */
function teamCard(t, { buttons = null } = {}) {
  return card(CARDS.TEAM, {
    id: t.id,
    name: t.name,
    sport: t.sport || null,
    city: t.city || null,
    logo: t.logo_url || null,
    elo: t.elo == null ? null : Number(t.elo),
    displayElo: t.displayElo == null ? null : Number(t.displayElo),
    isRanked: t.isRanked == null ? null : !!t.isRanked,
    memberCount: t.member_count == null ? null : Number(t.member_count),
    matchesPlayed: t.matches_played == null ? null : Number(t.matches_played),
    wins: t.wins == null ? null : Number(t.wins),
    losses: t.losses == null ? null : Number(t.losses),
    matchPct: t.matchPct == null ? null : Number(t.matchPct),
    reasons: Array.isArray(t.reasons) ? t.reasons : [],
    buttons: buttons || [chip('Team stats', 'team_stats', { teamId: t.id })],
  });
}

// People and TEAMS

/**
 * find_players — "kisi ko chahiye football team ke liye".
 *
 * Model #4's job ends at the label; which team is a question the classifier cannot
 * answer, because a user with three squads has three right answers. So the team is
 * resolved the same way every other id in this file is: a chip carrying `teamId`, a
 * spoken name, or — when the caller has exactly one team an admin can recruit for —
 * silence. Anything ambiguous asks, with the teams as chips.
 *
 * Admin-only is not this file's rule: rosterService.suggestPlayers calls
 * access.requireRole(..., 'admin') and would refuse anyway. Resolving with
 * `adminOnly` here only changes where the user finds out — a friendly "you are not
 * an admin of that squad" instead of a 403 shape from two layers down.
 */
async function findPlayers(ctx) {
  const { client, userId } = ctx;
  const slots = { ...(ctx.slots || {}) };
  const { one, many } = await resolveTeam(client, {
    userId, teamId: slots.teamId, name: slots.teamName, adminOnly: true,
  });

  if (!one) {
    if (!many.length) {
      return { reply: reply('You are not an admin of any team yet, so there is no squad for me to fill. Create one and I will find players for it.', {
        source: SOURCES.LIVE,
        chips: [chip('Create a team', 'create_team_help'), chip('Join a team', 'find_teams')],
      }), state: { intent: null, slots: {} } };
    }
    return { reply: reply('Which team am I finding players for?', {
      source: SOURCES.LIVE,
      chips: many.slice(0, 4).map((t) => chip(t.name, 'find_players', { teamId: t.id })),
    }), state: { intent: 'find_players', pending: 'team', slots } };
  }

  slots.teamId = one.id;
  slots.teamName = one.name;
  const out = await roster.suggestPlayers(client, { teamId: one.id, userId });
  if (!out.ok) {
    return { reply: reply(out.message || 'I could not read that squad.', {
      source: SOURCES.LIVE, actionOk: false, action: 'find_players',
      chips: [chip('My rating', 'team_stats', { teamId: one.id })],
    }), state: { intent: null, slots } };
  }

  const list = out.data.suggestions || [];
  const rank = out.data.ranking || {};
  if (!list.length) {
    return { reply: reply(`I found nobody new for ${one.name} right now. Everyone matching its sport is already on a squad, or the pool is empty in your area.`, {
      source: SOURCES.LIVE, action: 'find_players', actionOk: true,
      chips: [chip('Find opponents', 'find_opponents', { teamId: one.id }),
        chip('Find a ground', 'find_venue')],
    }), state: { intent: null, slots } };
  }

  // The `source` badge is the honest half of this reply, and it answers a narrower
  // question than "is this list well ordered". reco_rank.py is a deterministic
  // weighted scorer, not a trained model: the module states the weights literally,
  // so mlClient gives it its own third value, `'ranked'`, and says why at length.
  // This file used to stamp `model` over it anyway, which put an "AI" badge on a
  // weighted mean on a screen a real captain reads. Two separate questions:
  //
  //   scored     — the formula ran, so the percentages are real and "best fit
  //                first" is a true sentence
  //   modelBadge — a trained model shaped this answer. Only model #3, the venue
  //                recommender, ever earns it on a Scout reply, and it earns it by
  //                ml-service saying `source: 'model'` itself rather than by this
  //                file inferring it from "the call did not fail".
  //
  // `meta.ranking` still carries 'ranked' vs 'heuristic', so the distinction a
  // reviewer needs survives in the place that can hold a name. A fabricated number
  // would be worse than no number, and the fallbackNote says so in the sentence
  // rather than only in the payload.
  const scored = rank.available === true;
  const modelBadge = rank.source === 'model';
  const head = `${list.length} player${list.length === 1 ? '' : 's'} for ${one.name}`;
  const tail = scored
    ? ', best fit first.'
    : `. ${rank.fallbackNote || 'Ranking is unavailable, so these are in recent-activity order.'}`;
  return {
    reply: reply(head + tail, {
      source: modelBadge ? SOURCES.MODEL : SOURCES.LIVE,
      action: 'find_players', actionOk: true,
      cards: list.slice(0, TOP_PEOPLE).map((p) => playerCard({
        id: p.userId, name: p.name, avatar_url: p.avatarUrl,
        trust_score: p.trustScore, matchPct: p.matchPct, reasons: p.reasons,
        matches_played: p.bookingsLast30d,
      })),
      chips: [chip('Find opponents', 'find_opponents', { teamId: one.id }),
        chip('My rating', 'team_stats', { teamId: one.id }),
        chip('What can you do?', 'capability_menu')],
      meta: { teamId: one.id, ranking: rank.source || null, considered: rank.considered || null },
    }),
    state: { intent: null, slots },
  };
}

/**
 * find_opponents — "koi team milegi match ke liye?"
 *
 * Ordered by rating proximity, not by strength, which is why it cannot reuse
 * find_teams: the score depends on the pairing, so the caller's team has to be
 * resolved first. Any member may look; only a captain may challenge.
 *
 * What Scout does not do here, and says so: a challenge requires a booked slot
 * (matchCore's rule — a match is played at a ground at a time, so the challenge
 * carries a booking id). Offering "challenge them" as a chip would be a button that
 * fails, so the reply offers the step that comes first: book a ground.
 */
async function findOpponents(ctx) {
  const { client, userId } = ctx;
  const slots = { ...(ctx.slots || {}) };
  const { one, many } = await resolveTeam(client, {
    userId, teamId: slots.teamId, name: slots.teamName,
  });

  if (!one) {
    if (!many.length) {
      return { reply: reply('You need a team before I can find opponents for it.', {
        source: SOURCES.LIVE,
        chips: [chip('Create a team', 'create_team_help'), chip('Join a team', 'find_teams')],
      }), state: { intent: null, slots: {} } };
    }
    return { reply: reply('Which of your teams is playing?', {
      source: SOURCES.LIVE,
      chips: many.slice(0, 4).map((t) => chip(t.name, 'find_opponents', { teamId: t.id })),
    }), state: { intent: 'find_opponents', pending: 'team', slots } };
  }

  slots.teamId = one.id;
  slots.teamName = one.name;
  const out = await roster.suggestOpponents(client, {
    teamId: one.id, userId, q: slots.opponentName || '',
  });
  if (!out.ok) {
    return { reply: reply(out.message || 'I could not read that squad.', {
      source: SOURCES.LIVE, actionOk: false, action: 'find_opponents',
      chips: [chip('My rating', 'team_stats', { teamId: one.id })],
    }), state: { intent: null, slots } };
  }

  const d = out.data;
  const list = d.opponents || [];
  const rank = d.ranking || {};
  const mine = d.myTeam || {};
  if (!list.length) {
    return { reply: reply(`No public ${one.sport || ''} team is open for a match right now, so there is nobody for ${one.name} to play yet.`.replace(/\s+/g, ' '), {
      source: SOURCES.LIVE, action: 'find_opponents', actionOk: true,
      chips: [chip('Find players', 'find_players', { teamId: one.id }),
        chip('Browse teams', 'find_teams'), chip('Find a ground', 'find_venue')],
    }), state: { intent: null, slots } };
  }

  // Same split as find_players: `scored` is "the weighted formula ran", `modelBadge`
  // is "a trained model shaped this", and reco_rank.py is only ever the first.
  const scored = rank.available === true;
  const modelBadge = rank.source === 'model';
  const near = list.filter((t) => t.withinBand === true).length;
  const mineElo = mine.displayElo == null ? null : Number(mine.displayElo);
  const bits = [`${list.length} team${list.length === 1 ? '' : 's'} you could play`];
  if (mineElo != null) bits.push(`${one.name} is rated ${mineElo}`);
  if (near) bits.push(`${near} within ${d.preferredBand} points`);
  const why = scored ? 'Closest match first.'
    : (rank.fallbackNote ? `${rank.fallbackNote}.` : 'Ordered by rating proximity.');

  return {
    reply: reply(`${bits.join(' — ')}. ${why}`, {
      source: modelBadge ? SOURCES.MODEL : SOURCES.LIVE,
      action: 'find_opponents', actionOk: true,
      cards: list.slice(0, TOP_PEOPLE).map((t) => teamCard({
        id: t.id, name: t.name, sport: t.sport, city: t.city, logo_url: t.logoUrl,
        elo: t.elo, displayElo: t.displayElo, isRanked: t.ranked,
        member_count: t.memberCount, matches_played: t.played,
        wins: t.wins, losses: t.losses, matchPct: t.matchPct, reasons: t.reasons,
      }, { buttons: [chip('Team stats', 'team_stats', { teamId: t.id })] })),
      // A challenge needs a booked slot, so the honest next step is a ground —
      // not a "Challenge" button that would 400 for want of a booking id.
      chips: [chip('Book a ground', 'book_venue', { sport: one.sport || null }),
        chip('My rating', 'team_stats', { teamId: one.id }),
        chip('Find players', 'find_players', { teamId: one.id })],
      meta: { teamId: one.id, canChallenge: d.canChallenge === true, myRole: d.myRole || null,
        ranking: rank.source || null, preferredBand: d.preferredBand ?? null },
    }),
    state: { intent: null, slots },
  };
}

/**
 * find_teams — "koi team hai join karne ke liye?"
 *
 * discoveryService.discoverTeams is the same query GET /api/teams/discover runs,
 * so the two exclusions are inherited rather than restated: private squads are out,
 * and so is any team the user is already in ("find me a team" must never offer the
 * one they captain).
 *
 * Strongest first — deliberately not rating-proximity order. Someone looking for a
 * squad to join wants the good ones; only find_opponents cares about a fair pairing.
 * There is no model here, so the source is `live` and no card carries a percentage.
 *
 * The card's button deep-links to the team screen instead of sending a join request.
 * POST /api/teams/:id/join-request exists and works for public teams, but it takes a
 * message and it is a write against another user's squad: Scout hands over the
 * screen and the user taps it, which is the same courtesy the venue cards get.
 */
async function findTeams(ctx) {
  const { client, userId } = ctx;
  const slots = { ...(ctx.slots || {}) };
  const out = await discovery.discoverTeams(client, {
    userId, sport: slots.sport || null, q: slots.teamName || '', limit: 40,
  });
  if (!out.ok) {
    return { reply: reply(out.message || 'I could not search teams just now.', {
      source: SOURCES.LIVE, actionOk: false, action: 'find_teams',
      chips: [chip('What can you do?', 'capability_menu')],
    }), state: { intent: null, slots } };
  }

  const rows = out.data || [];
  const named = slots.sport ? `${slots.sport} ` : '';
  if (!rows.length) {
    const relax = slots.sport
      ? 'Try another sport, or I can look at every sport.'
      : 'Every public squad already has you in it, or there are none yet.';
    return { reply: reply(`No ${named}team is open to join right now. ${relax}`, {
      source: SOURCES.LIVE, action: 'find_teams', actionOk: true,
      chips: [slots.sport ? chip('Any sport', 'find_teams', { sport: null }) : null,
        chip('Create a team', 'create_team_help'),
        chip('Find a ground', 'find_venue')].filter(Boolean),
    }), state: { intent: null, slots: { ...slots, sport: slots.sport || null } } };
  }

  return {
    reply: reply(`${rows.length} ${named}team${rows.length === 1 ? '' : 's'} you can join, strongest first. Open one to send a join request.`.replace(/\s+/g, ' '), {
      source: SOURCES.LIVE, action: 'find_teams', actionOk: true,
      cards: rows.slice(0, TOP_PEOPLE).map((t) => teamCard({
        id: t.id, name: t.name, sport: t.sport, city: t.city, logo_url: t.logo_url,
        elo: t.elo, displayElo: elo.displayElo(t), isRanked: elo.isRanked(t),
        member_count: t.member_count, matches_played: elo.playedCount(t),
        wins: t.wins, losses: t.losses,
      }, {
        buttons: [chip('Open team', 'app_help', { screen: 'team', id: t.id }),
          chip('Team stats', 'team_stats', { teamId: t.id })],
      })),
      chips: [chip('Create my own', 'create_team_help'),
        chip('How is rating worked out?', 'elo_help'),
        chip('Find a ground', 'find_venue')],
      meta: { count: rows.length, sport: slots.sport || null },
    }),
    state: { intent: null, slots },
  };
}

/**
 * team_stats — "meri team ki rating kya hai?"
 *
 * utils/teamStats.profileStats is what GET /api/teams/:id already paints its rating
 * block from, so the numbers Scout reads out are the numbers on the team screen.
 *
 * FR2.6 is the whole subtlety: below `ranked_min_matches` a team has no displayable
 * rating and `display_elo` is NULL — not 1000. Scout therefore has two different
 * sentences, and the unranked one says how many matches are still needed instead of
 * quoting a placeholder the app itself refuses to show.
 */
async function teamRating(ctx) {
  const { client, userId } = ctx;
  const slots = { ...(ctx.slots || {}) };
  const { one, many } = await resolveTeam(client, {
    userId, teamId: slots.teamId, name: slots.teamName,
  });
  if (!one) {
    if (!many.length) {
      return { reply: reply('You are not in a team yet, so there is no rating to show.', {
        source: SOURCES.LIVE,
        chips: [chip('Create a team', 'create_team_help'), chip('Join a team', 'find_teams'),
          chip('How is rating worked out?', 'elo_help')],
      }), state: { intent: null, slots: {} } };
    }
    return { reply: reply('Which team?', {
      source: SOURCES.LIVE,
      chips: many.slice(0, 4).map((t) => chip(t.name, 'team_stats', { teamId: t.id })),
    }), state: { intent: 'team_stats', pending: 'team', slots } };
  }

  slots.teamId = one.id;
  slots.teamName = one.name;
  const s = await teamStats.profileStats(client, one.id);
  const record = `${s.wins}W-${s.losses}L-${s.draws}D`;
  const activity = s.activity_30d === 0
    ? `No matches in the last ${s.activity_window_days} days.`
    : `${s.activity_30d} match${s.activity_30d === 1 ? '' : 'es'} in the last ${s.activity_window_days} days.`;
  const text = s.ranked
    ? `${one.name} is rated ${s.display_elo}${s.elo_frozen ? ' (rating frozen)' : ''}. ${record} from ${s.played} played, ${s.win_rate}% win rate.${s.form ? ` Recent form ${s.form.split('').join(' ')}.` : ''} ${activity}`
    : `${one.name} is still unranked — ${s.played} of ${s.ranked_min_matches} matches played. ${record} so far. ${activity} Play ${Math.max(1, s.ranked_min_matches - s.played)} more and the rating appears.`;

  return {
    reply: reply(text.replace(/\s+/g, ' ').trim(), {
      source: SOURCES.LIVE, action: 'team_stats', actionOk: true,
      cards: [teamCard({
        id: one.id, name: one.name, sport: one.sport, city: one.city, logo_url: one.logo_url,
        elo: s.elo, displayElo: s.display_elo, isRanked: s.ranked,
        matches_played: s.played, wins: s.wins, losses: s.losses,
      }, {
        buttons: [chip('Find opponents', 'find_opponents', { teamId: one.id }),
          chip('Find players', 'find_players', { teamId: one.id })],
      })],
      chips: [chip('Find opponents', 'find_opponents', { teamId: one.id }),
        chip('How is rating worked out?', 'elo_help'),
        chip('Book a ground', 'book_venue', { sport: one.sport || null })],
      meta: { teamId: one.id, ranked: s.ranked, eloFrozen: s.elo_frozen },
    }),
    state: { intent: null, slots },
  };
}

// POLICY and help  —  no database reads, no model, and no invented numbers

/**
 * refund_policy — "cancel karne pe paisa wapas milta hai?"
 *
 * Golden rule 3 in one function. The sentence comes from
 * global_settings.assistant.policy_text (an owner can reword it); every number in it
 * is substituted from utils/escrow.js POLICY at render time by utils/policyText.js.
 * So the cancellation window Scout quotes is the window bookingService itself
 * enforces, and rewording the text cannot make Scout lie about the arithmetic.
 *
 * Which paragraph, and why it is not the classifier's job
 * The model has one label for every money-rules question; policyText has seven
 * topics. So the paragraph is chosen here, and by the words the user typed
 * — never from a leftover slot. A chip press (no text) is the one case that trusts
 * `slots.topic`, because that value came from the chip the user just tapped. This is
 * deliberate: `topic` survives across turns of the same intent, so honouring a stale
 * one would answer "refund policy?" with the no-show paragraph read three turns ago.
 */
const POLICY_WORDS = Object.freeze([
  ['no_show', /no.?show|nahi (aya|aaya|pohnch)|late (aya|aaya)|grace/i],
  ['deposit', /deposit|advance|escrow|hold (rakh|kar)|20 ?%/i],
  ['checkin', /check.?in|qr|scan|entry/i],
  ['approval', /approv|owner (accept|manzoor)|pending|kitni der me confirm/i],
  ['withdrawal', /withdraw|nikal|payout|bank/i],
  ['topup', /top.?up|paisa (dal|add)|recharge/i],
]);

function policyTopicFor({ said = '', slotTopic = null } = {}) {
  const t = String(said || '').trim();
  if (!t) {
    return policyText.TOPICS.includes(String(slotTopic || '')) ? String(slotTopic) : 'refund_policy';
  }
  for (const [name, re] of POLICY_WORDS) if (re.test(t)) return name;
  return 'refund_policy';
}

async function refundPolicy(ctx) {
  const settings = ctx.settings || {};
  const slots = { ...(ctx.slots || {}) };
  const name = policyTopicFor({ said: ctx.text, slotTopic: slots.topic });
  const main = policyText.topic(name, settings);
  const also = name === 'refund_policy'
    ? policyText.topic('deposit', settings)
    : policyText.topic('refund_policy', settings);

  const others = ['refund_policy', 'no_show', 'deposit', 'checkin']
    .filter((k) => k !== name).slice(0, 2);
  const LABELS = { refund_policy: 'Refunds', no_show: 'No-show rules', deposit: 'Deposit',
    checkin: 'Check-in', approval: 'Owner approval', topup: 'Top-ups', withdrawal: 'Withdrawals' };

  return {
    reply: reply(main.text, {
      source: SOURCES.POLICY, action: 'refund_policy', actionOk: true,
      cards: [card(CARDS.POLICY, {
        topic: name,
        title: LABELS[name] || 'Policy',
        body: main.text,
        extra: also.text,
        windowHours: POLICY.CANCELLATION_WINDOW_HOURS,
        refundPct: 100 - Number(POLICY.DEPOSIT_PERCENT),
        depositPct: Number(POLICY.DEPOSIT_PERCENT),
        graceMinutes: POLICY.NO_SHOW_GRACE_MINUTES,
      })],
      chips: [...others.map((k) => chip(LABELS[k], 'refund_policy', { topic: k })),
        chip('My bookings', 'my_bookings')],
      meta: { topic: name, seeded: main.seeded },
    }),
    // `topic` is cleared so the next policy question starts from the words in it.
    state: { intent: null, slots: { ...slots, topic: null } },
  };
}

/**
 * topup_help — "wallet me paisa kaise dalun?"
 *
 * There is no payment gateway in the FYP build, so this is honestly a how-to and not
 * a transaction: Scout points at the Wallet screen and states the withdrawal floor,
 * which is a POLICY number and therefore rendered rather than typed.
 */
async function topupHelp(ctx) {
  const settings = ctx.settings || {};
  const top = policyText.topic('topup', settings);
  const out = policyText.topic('withdrawal', settings);
  return {
    reply: reply(`${top.text} ${out.text}`, {
      source: SOURCES.POLICY, action: 'topup_help', actionOk: true,
      cards: [card(CARDS.POLICY, {
        topic: 'topup', title: 'Money in and out',
        body: top.text, extra: out.text,
        withdrawalMin: Number(POLICY.WITHDRAWAL_MIN_AMOUNT),
      })],
      chips: [chip('Wallet balance', 'wallet_balance'),
        chip('Open wallet', 'app_help', { screen: 'wallet' }),
        chip('Refund policy', 'refund_policy')],
      meta: { topic: 'topup', seeded: top.seeded && out.seeded },
    }),
    state: { intent: null },
  };
}

/**
 * elo_help — "rating kaise banti hai?"
 *
 * Every number here is read from the two owners of it: utils/elo.js for the rules and
 * global_settings for the tunables. If the committee changes the K-factor in the
 * database, this answer changes with it — which is the entire reason globalSettings
 * exists and the reason this handler is async for a sentence with no query in it.
 */
async function eloHelp() {
  const cfg = await settingsUtil.elo({});
  const text = `Every team starts at ${cfg.base}. After a verified match the winner takes points from the loser — how many depends on the gap between the two ratings, scaled by a K-factor of ${cfg.kFactor}, so beating a stronger side moves you more than beating a weaker one. A draw moves both a little. Ratings show up after ${elo.RANKED_MIN_MATCHES} verified match${elo.RANKED_MIN_MATCHES === 1 ? '' : 'es'}; until then a team is Unranked rather than shown at ${cfg.base}. I look for opponents within ${elo.PREFERRED_ELO_BAND} points, and the match bar runs ${elo.COMP_MIN}–${elo.COMP_MAX}%.`;
  return {
    reply: reply(text, {
      source: SOURCES.POLICY, action: 'elo_help', actionOk: true,
      cards: [card(CARDS.POLICY, {
        topic: 'elo', title: 'How rating works', body: text,
        base: cfg.base, kFactor: cfg.kFactor,
        rankedMinMatches: elo.RANKED_MIN_MATCHES,
        preferredBand: elo.PREFERRED_ELO_BAND,
      })],
      chips: [chip('My rating', 'team_stats'), chip('Find opponents', 'find_opponents'),
        chip('What can you do?', 'capability_menu')],
    }),
    state: { intent: null },
  };
}

/**
 * create_team_help — "team kaise banau?"
 *
 * A write Scout deliberately does not perform. Creating a team takes a name, a sport
 * and a visibility choice, and it makes the caller captain of a real row other people
 * then join; a chat turn that guessed any of those three would be a squad the user did
 * not ask for. So this is the steps plus a deep link, and it says what Scout will do
 * once the team exists — which is the part the user asked for.
 */
async function createTeamHelp(ctx) {
  const slots = ctx.slots || {};
  const sport = slots.sport ? `${slots.sport} ` : '';
  const text = `Open Teams and tap the + button: name your ${sport}squad, pick the sport, and choose Public so players can find it. You become captain, then share the invite link or accept join requests. Once it exists I can find players for it, suggest opponents your rating, and book the ground.`;
  return {
    reply: reply(text.replace(/\s+/g, ' '), {
      source: SOURCES.LIVE, action: 'create_team_help', actionOk: true,
      chips: [chip('Open Teams', 'app_help', { screen: 'teams' }),
        chip('Browse teams to join', 'find_teams', { sport: slots.sport || null }),
        chip('How is rating worked out?', 'elo_help')],
    }),
    state: { intent: null },
  };
}

/**
 * greeting — "assalam o alaikum", "hi", "kya haal hai".
 *
 * SQL exception 3 of 3 (see the file header): the caller's own name. One row keyed on
 * the caller's own id with no derived rule attached, so it stays here rather than
 * earning a service function.
 *
 * Answers by name — the user's, and Scout's own from global_settings, so renaming the
 * assistant renames it everywhere — and then immediately offers work. A greeting that
 * only greets back is a dead end, and the spec forbids those.
 */
async function greeting(ctx) {
  const settings = ctx.settings || {};
  const who = settings.name || 'Scout';
  let first = '';
  try {
    const { rows } = await ctx.client.query('SELECT name FROM users WHERE id = $1', [ctx.userId]);
    first = String((rows[0] && rows[0].name) || '').trim().split(' ')[0];
  } catch (e) {
    first = '';  // a greeting is never worth failing a turn over
  }
  const hello = first ? `Assalam-o-alaikum ${first}!` : 'Assalam-o-alaikum!';
  return {
    reply: reply(`${hello} I'm ${who}. I can find a ground and book it, suggest players or opponents, and answer anything about your bookings, wallet or the rules. What do you need?`, {
      source: SOURCES.LIVE, action: 'greeting', actionOk: true,
      chips: [chip('Find a ground', 'find_venue'), chip('Book a ground', 'book_venue'),
        chip('My bookings', 'my_bookings'), chip('What can you do?', 'capability_menu')],
    }),
    state: { intent: null },
  };
}

/**
 * app_help — "ye app kaise chalti hai", "profile kahan hai", and every deep-link chip.
 *
 * The screen MAP is a contract with Flutter, not prose
 * Cards and chips hand back `{screen, id}` so the client can push a route instead of
 * posting a message. The Flutter chip handler routes on this map's keys; a client that
 * posts one back anyway lands here and gets the sentence for that screen, which is
 * why the same table serves both.
 */
const SCREENS = Object.freeze({
  home: ['Home', 'Your feed: nearby grounds, your next booking and anything needing attention.'],
  venues: ['Grounds', 'Browse or search grounds, filter by sport, city, price and rating.'],
  venue: ['Ground', 'Photos, facilities, price, rating and the day\'s slots.'],
  bookings: ['My Bookings', 'Upcoming and past bookings, with the QR code for check-in.'],
  wallet: ['Wallet', 'Available balance, money held in escrow, and your transactions.'],
  teams: ['Teams', 'Your squads, and the + button to start one.'],
  team: ['Team', 'Roster, rating, form and join requests.'],
  matches: ['Matches', 'Challenges you have sent or received, and results to verify.'],
  player: ['Player', 'A player\'s profile: position, skill level and trust score.'],
  profile: ['Profile', 'Your details, position, skill level and trust score.'],
  chat: ['Chats', 'Your team and booking conversations — and me.'],
  tournaments: ['Tournaments', 'What is running, entry fee and the registration deadline.'],
});

async function appHelp(ctx) {
  const slots = ctx.slots || {};
  const key = String(slots.screen || '').trim().toLowerCase();
  const hit = SCREENS[key];
  if (hit) {
    return {
      reply: reply(`${hit[0]} — ${hit[1]}`, {
        source: SOURCES.LIVE, action: 'app_help', actionOk: true,
        chips: [chip('What can you do?', 'capability_menu'), chip('Find a ground', 'find_venue')],
        meta: { screen: key },
      }),
      state: { intent: null, slots: { ...slots, screen: null } },
    };
  }
  const tour = Object.entries(SCREENS)
    .filter(([k]) => ['venues', 'bookings', 'wallet', 'teams', 'matches'].includes(k))
    .map(([, v]) => `${v[0]}: ${v[1]}`).join(' ');
  return {
    reply: reply(`SportLynk in one paragraph — ${tour} Ask me for any of it in plain words and I will do it for you.`, {
      source: SOURCES.LIVE, action: 'app_help', actionOk: true,
      chips: [chip('Find a ground', 'find_venue'), chip('My bookings', 'my_bookings'),
        chip('Wallet balance', 'wallet_balance'), chip('What can you do?', 'capability_menu')],
    }),
    state: { intent: null, slots: { ...slots, screen: null } },
  };
}

/**
 * capability_menu — the button-only "what can you do?".
 *
 * Identical payload to the abstain menu, on purpose: a user who asks what Scout can do
 * and a user whose sentence Scout could not place should see the same list, so there is
 * one place where capabilities are described. `source` is `menu`, which is how the
 * metrics separate "I helped" from "I offered to".
 */
async function capabilityMenu(ctx) {
  const settings = ctx.settings || {};
  return { reply: menu(null, { name: settings.name || 'Scout' }), state: { intent: null } };
}

/**
 * out_of_scope — the model's own "this is not about SportLynk".
 *
 * Scout is deliberately not a general assistant (the user's requirement), so the honest
 * answer to "mausam kaisa hai" is that it does grounds, teams, bookings and money — and
 * then the menu, so the turn still ends somewhere useful. ER2.6.
 */
async function outOfScope(ctx) {
  const settings = ctx.settings || {};
  const who = settings.name || 'Scout';
  const m = menu(`That one is outside my ground. I'm ${who} — I only do SportLynk: grounds, bookings, teams, players and your wallet. Here is the whole list:`,
    { name: who });
  return { reply: { ...m, action: 'out_of_scope', actionOk: true }, state: { intent: null, slots: {} } };
}

// Ask the owner  —  the one place Scout is allowed to not know

/**
 * contact_owner — "ground wale se pooch lo floodlights hain ya nahi".
 *
 * The escalation is the honest answer to a question no query can answer: is there
 * parking, is the turf new, can we play at 2am. Scout files it against the venue, the
 * owner answers from their queue, the answer is published into assistant_kb, and the
 * next player asking the same thing gets it instantly with `source: 'kb'`. That loop is
 * why Scout has an owner side at all.
 *
 * Three things this deliberately refuses
 *   money/policy   assistantKb.BLOCKED_INTENTS — an owner may not redefine the refund
 *                  rules by answering a question, so those never enter the queue.
 *   no venue       "ask the owner" needs an owner; without a ground Scout asks which.
 *   duplicate      ten players asking the same thing is one queue item, and everyone
 *                  is told it is already with the owner rather than filing again.
 *
 * A KB hit short-circuits the whole thing: if the owner has already answered this, the
 * answer is served immediately and nobody is disturbed.
 */
async function contactOwner(ctx) {
  const { client, userId } = ctx;
  const slots = { ...(ctx.slots || {}) };
  const question = String(slots.question || ctx.text || '').trim();

  const { one, many } = await resolveVenue(client, {
    venueId: slots.venueId, name: slots.venueName, sport: slots.sport, area: slots.locality || slots.city,
  });
  if (!one) {
    const ask = 'Which ground should I ask about?';
    if (many.length) {
      return { reply: reply(ask, {
        source: SOURCES.LIVE,
        chips: many.slice(0, TOP_VENUES).map((v) => chip(v.name, 'contact_owner', { venueId: v.id })),
      }), state: { intent: 'contact_owner', pending: 'venue', slots: { ...slots, question } } };
    }
    return { reply: reply(`${ask} Name it, or pick one from a search.`, {
      source: SOURCES.LIVE,
      chips: [chip('Find a ground', 'find_venue'), chip('What can you do?', 'capability_menu')],
    }), state: { intent: 'contact_owner', pending: 'venue', slots: { ...slots, question } } };
  }

  slots.venueId = one.id;
  slots.venueName = one.name;
  if (!question) {
    return { reply: reply(`What should I ask the owner of ${one.name}?`, {
      source: SOURCES.LIVE,
      chips: [chip('Ground details', 'venue_info', { venueId: one.id }),
        chip('Free times', 'check_availability', { venueId: one.id })],
    }), state: { intent: 'contact_owner', pending: 'question', slots } };
  }

  // Already answered? Serve it and disturb nobody.
  const known = await kb.search(client, { question, venueId: one.id, limit: 1 });
  if (known.hit) {
    await kb.recordServed(client, known.row.id);
    return {
      reply: reply(known.row.answer, {
        source: SOURCES.KB, action: 'contact_owner', actionOk: true,
        chips: [chip('Ground details', 'venue_info', { venueId: one.id }),
          chip('Free times', 'check_availability', { venueId: one.id }),
          chip('Ask something else', 'contact_owner', { venueId: one.id })],
        meta: { kbId: known.row.id, venueId: one.id, similarity: known.similarity,
          matcher: known.matcher, scope: known.row.scope },
      }),
      state: { intent: null, slots: { ...slots, question: null } },
    };
  }

  const esc = await kb.escalate(client, {
    userId, channelId: ctx.channelId, messageId: ctx.messageId,
    venueId: one.id, question, intent: ctx.intent || 'contact_owner', confidence: ctx.confidence,
  });

  if (!esc.ok) {
    const why = {
      money_or_policy: 'That one is a SportLynk rule, not the owner\'s call — I can answer it myself.',
      no_owner: `${one.name} has no owner account linked yet, so there is nobody for me to ask.`,
      no_venue: 'I could not find that ground.',
      empty_question: 'Tell me what to ask and I will pass it on.',
    }[esc.reason] || 'I could not pass that on just now.';
    return {
      reply: reply(why, {
        source: SOURCES.LIVE, action: 'contact_owner', actionOk: false,
        chips: [esc.reason === 'money_or_policy' ? chip('Refund policy', 'refund_policy') : null,
          chip('Ground details', 'venue_info', { venueId: one.id }),
          chip('What can you do?', 'capability_menu')].filter(Boolean),
        meta: { reason: esc.reason, venueId: one.id },
      }),
      state: { intent: null, slots: { ...slots, question: null } },
    };
  }

  const dup = esc.reason === 'duplicate';
  return {
    reply: reply(dup
      ? `Someone already asked ${one.name} exactly that and it is still with the owner. I will show you the answer here as soon as it lands.`
      : `Asked the owner of ${one.name}. You will get a notification the moment they answer, and the answer will show up in this chat.`, {
      source: SOURCES.ESCALATED, action: 'contact_owner', actionOk: true,
      chips: [chip('Ground details', 'venue_info', { venueId: one.id }),
        chip('Free times', 'check_availability', { venueId: one.id }),
        chip('Find another ground', 'find_venue')],
      meta: { escalationId: esc.row.id, venueId: one.id, duplicate: dup,
        notified: esc.notified === true },
    }),
    state: { intent: null, slots: { ...slots, question: null } },
  };
}

// Confirmation  —  the two-turn gate in front of every write

/**
 * `confirm` — the user said yes to an armed confirmation.
 *
 * The dialog manager has already established that this turn may fire a confirm at all:
 * a `confirm` block was armed by the previous turn, it survives exactly one turn, and
 * only four inputs reach here (the Confirm chip, a whole-utterance affirm, and their
 * two negatives to cancel_confirm). This function therefore does not re-litigate
 * consent — it dispatches on what was armed.
 *
 * Dispatch on the block, not on the intent. `ctx.confirm.action` was written by the
 * handler that asked the question, so "haan" can never fire a booking when what was
 * armed was a cancellation, no matter what the classifier made of the word.
 */
async function runConfirmed(ctx) {
  const c = ctx.confirm || {};
  const run = EXECUTORS[String(c.action || '')];
  if (typeof run === 'function') return run(ctx);
  return {
    reply: reply('I am not holding anything to confirm. What would you like to do?', {
      source: SOURCES.LIVE,
      chips: [chip('Find a ground', 'find_venue'), chip('My bookings', 'my_bookings'),
        chip('What can you do?', 'capability_menu')],
    }),
    state: { intent: null, pending: null, confirm: null, slots: {} },
  };
}

/**
 * `cancel_confirm` — the user said no to an armed confirmation.
 *
 * Nothing is executed and the block is dropped. The reply keeps the subject alive
 * (the ground, the booking) because "nahi" almost always means "not that one" rather
 * than "stop": offering other times is the difference between a helpful assistant and
 * one that forces the user to start over.
 */
async function cancelConfirm(ctx) {
  const c = ctx.confirm || {};
  const booked = String(c.action || '') === 'book_venue';
  const keep = booked && c.venueId ? { venueId: c.venueId, venueName: c.venueName,
    date: c.date || null } : {};
  return {
    reply: reply(booked
      ? `No problem — nothing booked${c.venueName ? ` at ${c.venueName}` : ''}. Want a different time, or a different ground?`
      : 'Left it as it is — nothing was cancelled.', {
      source: SOURCES.LIVE, action: 'cancel_confirm', actionOk: true,
      chips: booked
        ? [chip('Other times', 'check_availability', keep),
          chip('Another ground', 'find_venue'), chip('What can you do?', 'capability_menu')]
        : [chip('My bookings', 'my_bookings'), chip('Refund policy', 'refund_policy')],
    }),
    state: { intent: null, pending: null, confirm: null, slots: keep },
  };
}

/**
 * `affirm` and `deny` with nothing armed — "haan" out of the blue.
 *
 * These exist because the classifier has labels for them and assertRoutable() demands
 * a home for every label. They must never look like a confirmation: the whole point of
 * the one-turn confirm block is that a stray yes cannot spend money, so this asks what
 * the user is agreeing to instead of guessing.
 *
 * `ctx.lastIntent` (the previous turn's subject, from session ctx) is used only to make
 * the question specific. It never executes anything.
 */
async function strayAffirm(ctx) {
  const last = String(ctx.lastIntent || '');
  const nudge = {
    find_venue: 'Shall I book one of those grounds?',
    check_availability: 'Want me to book one of those times?',
    venue_info: 'Shall I check what is free there?',
    find_players: 'Want me to look at opponents too?',
    find_opponents: 'Shall I find a ground for the match?',
    my_bookings: 'Want to cancel one, or book another?',
  }[last] || 'Yes to what? Tell me and I will do it.';
  return {
    reply: reply(nudge, {
      source: SOURCES.LIVE, action: 'affirm', actionOk: true,
      chips: [chip('Find a ground', 'find_venue'), chip('Book a ground', 'book_venue'),
        chip('My bookings', 'my_bookings'), chip('What can you do?', 'capability_menu')],
    }),
    state: { intent: null, pending: null, confirm: null },
  };
}

async function strayDeny(ctx) {
  const settings = ctx.settings || {};
  return {
    reply: reply(`Alright — nothing done. Tell me what you need instead and I'll get on it.`, {
      source: SOURCES.LIVE, action: 'deny', actionOk: true,
      chips: [chip('Find a ground', 'find_venue'), chip('My bookings', 'my_bookings'),
        chip('What can you do?', 'capability_menu')],
      meta: { name: settings.name || 'Scout' },
    }),
    state: { intent: null, pending: null, confirm: null, slots: {} },
  };
}

// The registry  —  the only thing routes/assistant.js and dialogManager dispatch on

/**
 * The 23 labels the released intent artifact can produce.
 *
 * They are LISTED here, not imported: ml-service owns the model and this process
 * cannot read intent_spec.py, and /nlu/health does not publish the label set. So the
 * list is duplicated exactly once, on purpose, and assertRoutable() turns that
 * duplication into a boot-time assertion instead of a latent bug — a retrain that adds
 * a 24th label makes the server refuse to start rather than route it to out_of_scope.
 *
 * Alphabetical, like INTENT_SPEC's own tuple, so a diff between the two is readable.
 */
const INTENT_LABELS = Object.freeze([
  'affirm', 'app_help', 'book_venue', 'cancel_booking', 'check_availability',
  'contact_owner', 'create_team_help', 'deny', 'elo_help', 'find_opponents',
  'find_players', 'find_teams', 'find_venue', 'greeting', 'my_bookings', 'navigate',
  'out_of_scope', 'refund_policy', 'team_stats', 'topup_help', 'tournament_list',
  'venue_info', 'wallet_balance',
]);

/**
 * Actions that exist only as a button. The classifier has no label for them and never
 * will: they are steps inside a flow, reached by tapping a chip Scout itself painted.
 */
// Executable, but not trained labels: nothing in this list can be reached by the
// classifier, only by a chip Scout itself painted. The three tournament actions are
// here because model #4 was released with 23 labels and nothing here retrains it
// -- and because `tournament_register` spends, so it must stay behind the chip.
const BUTTON_ONLY = Object.freeze(['pick_slot', 'confirm', 'cancel_confirm', 'capability_menu',
  'tournament_detail', 'tournament_register', 'my_tournaments']);

/** Confirmed writes, keyed by the `action` in the armed confirm block. */
const EXECUTORS = Object.freeze({
  book_venue: executeBooking,
  cancel_booking: executeCancel,
  tournament_register: executeTournamentEntry,
});

/**
 * Every key Scout can execute. The 23 trained labels plus the seven button-only steps.
 *
 * dialogManager looks a handler up here by intent; routes/assistant.js looks one up by
 * the `action` on a chip. Both go through this object, which is why a chip can skip the
 * classifier entirely and why there is exactly one definition of what Scout can do.
 */
const ACTIONS = Object.freeze({
  // Discovery
  find_venue: findVenue,
  check_availability: checkAvailability,
  venue_info: venueInfo,
  navigate,
  find_players: findPlayers,
  find_opponents: findOpponents,
  find_teams: findTeams,
  tournament_list: tournamentList,
  tournament_detail: tournamentDetail,
  team_stats: teamRating,
  // Booking and money
  book_venue: bookVenue,
  pick_slot: pickSlot,
  cancel_booking: cancelBooking,
  tournament_register: tournamentRegister,
  my_bookings: myBookings,
  my_tournaments: myTournaments,
  wallet_balance: walletBalance,
  confirm: runConfirmed,
  cancel_confirm: cancelConfirm,
  // Talking
  greeting,
  affirm: strayAffirm,
  deny: strayDeny,
  refund_policy: refundPolicy,
  topup_help: topupHelp,
  elo_help: eloHelp,
  create_team_help: createTeamHelp,
  contact_owner: contactOwner,
  app_help: appHelp,
  capability_menu: capabilityMenu,
  out_of_scope: outOfScope,
});

/** Is this string something Scout can execute? Used to reject a junk chip with a 400. */
function isAction(key) {
  return Object.prototype.hasOwnProperty.call(ACTIONS, String(key || ''));
}

/** The trained labels, for GET /api/assistant/capabilities and the NLU check. */
function intentLabels() {
  return [...INTENT_LABELS];
}

/**
 * Boot-time proof that this file can route everything that can reach it.
 *
 * Four assertions, and each one has caught a real class of bug here:
 *   1. every trained label has a handler        — a retrain cannot land in silence
 *   2. every handler is a function              — a typo'd name is a 500 at runtime
 *   3. every capability chip is executable      — a menu button that 400s is worse
 *                                                 than a missing button
 *   4. every confirm executor is a handler too  — so `confirm` can always dispatch
 *
 * Throws rather than logs. server.js requires this module at boot, so a broken registry
 * stops the process instead of shipping an assistant with a hole in it.
 */
function assertRoutable() {
  const missing = INTENT_LABELS.filter((l) => !isAction(l));
  if (missing.length) {
    throw new Error(`assistantActions: no handler for intent label(s) ${missing.join(', ')}. `
      + 'A retrain that adds a label needs a handler here (or an explicit alias to out_of_scope).');
  }
  const notFn = Object.keys(ACTIONS).filter((k) => typeof ACTIONS[k] !== 'function');
  if (notFn.length) {
    throw new Error(`assistantActions: ACTIONS.${notFn.join(', ACTIONS.')} is not a function.`);
  }
  const unreachable = CAPABILITIES.map((c) => c.action).filter((a) => !isAction(a));
  if (unreachable.length) {
    throw new Error(`assistantActions: capability menu offers unexecutable action(s) `
      + `${unreachable.join(', ')} — every chip in assistantReply.CAPABILITIES must be routable.`);
  }
  const badExec = Object.keys(EXECUTORS).filter((k) => typeof EXECUTORS[k] !== 'function');
  if (badExec.length) {
    throw new Error(`assistantActions: EXECUTORS.${badExec.join(', EXECUTORS.')} is not a function.`);
  }
  return {
    ok: true,
    labels: INTENT_LABELS.length,
    actions: Object.keys(ACTIONS).length,
    buttonOnly: BUTTON_ONLY.length,
    executors: Object.keys(EXECUTORS).length,
  };
}

module.exports = {
  // constants
  TOP_VENUES, TOP_SLOTS, TOP_PEOPLE, INTENT_LABELS, BUTTON_ONLY, SCREENS,
  // registry
  ACTIONS, EXECUTORS, isAction, intentLabels, assertRoutable,
  // helpers worth testing on their own
  money, clock, day, pktDate, pktDay, dateStr, policyTopicFor, withSavepoint,
  venueCard, slotPickerCard, confirmCard, bookingCard, playerCard, teamCard,
  resolveVenue, resolveTeam,
  // handlers, so check_assistant.js can drive one without a chat turn
  findVenue, checkAvailability, venueInfo, navigate, findPlayers, findOpponents,
  findTeams, tournamentList, tournamentDetail, tournamentRegister, myTournaments,
  teamRating, bookVenue, pickSlot, cancelBooking,
  myBookings, walletBalance, runConfirmed, cancelConfirm, executeBooking, executeCancel,
  executeTournamentEntry,
  greeting, strayAffirm, strayDeny, refundPolicy, topupHelp, eloHelp, createTeamHelp,
  contactOwner, appHelp, capabilityMenu, outOfScope,
};
