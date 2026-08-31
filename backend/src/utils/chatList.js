/**
 * chatList.js — the reads behind the chat list (S.7 Wave B).
 *
 * WHY THESE ARE NOT INLINE IN routes/chat.js
 * Every function here takes a `client`, exactly like bookingService's CORE
 * functions do. The routes pass `pool`; check_chat.js passes its own open
 * transaction and rolls it back. That is what makes it possible to verify the
 * REAL query against real rows without leaving any behind — a check script that
 * re-implements the query proves the copy, not the endpoint.
 *
 * WHY `context` IS COMPUTED SERVER-SIDE
 * A row reading "Shalimar Cricket Academy" is a name; a row reading
 * "Confirmed · Sat 5 Sep, 6:00 pm" is a reason to tap. The subtitle depends on
 * the booking's current status or the match's scoreline, both of which live in
 * tables the list already holds the ids for — resolving them here costs one
 * extra indexed read per channel TYPE (never per row) and saves the client N
 * round trips plus a second copy of the status vocabulary.
 *
 * ASSISTANT CHANNELS ARE EXCLUDED EVERYWHERE IN THIS FILE. Scout has its own
 * screen and its own entry point; listing it here would put a robot at the top
 * of a human inbox.
 */

/** 'checked_in' -> 'Checked in'; the wire values are snake_case, the UI is not. */
function humanStatus(s) {
  return String(s || '').replace(/_/g, ' ').replace(/^./, (c) => c.toUpperCase());
}

/**
 * 2026-09-05 + '18:00:00' -> 'Sat 5 Sep, 6:00 pm'.
 *
 * bookings.slot_date/start_time are PKT WALL CLOCK, not instants, so they are
 * formatted as written and never passed through a timezone conversion — the same
 * rule bookingService.localDateStr follows for the same reason.
 */
function slotLabel(slotDate, startTime) {
  const d = slotDate instanceof Date ? slotDate.toLocaleDateString('en-CA') : String(slotDate || '');
  const parts = d.split('-');
  if (parts.length !== 3) return d;
  const dt = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]));
  // Three dash-separated parts is not the same as three NUMBERS: 'not-a-date' splits
  // cleanly and then formats as the literal string "Invalid Date", which would reach
  // a chat row as its subtitle. A subtitle is decoration and must degrade to the raw
  // value rather than to a word the user will read as a fault in their booking.
  if (Number.isNaN(dt.getTime())) return d;
  const day = dt.toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' });
  const hm = String(startTime || '').slice(0, 5);
  if (!hm) return day;
  const [h, mi] = hm.split(':').map(Number);
  const am = h < 12 ? 'am' : 'pm';
  const h12 = ((h + 11) % 12) + 1;
  return `${day}, ${h12}:${String(mi).padStart(2, '0')} ${am}`;
}

/**
 * Resolve the per-type subtitle for a page of channels in at most three batched
 * reads — one per channel type present, never one per row.
 */
async function contextFor(client, rows, userId) {
  const byType = { booking: [], captain: [], team: [] };
  for (const r of rows) {
    if (r.ref_id && byType[r.type]) byType[r.type].push(r.ref_id);
  }
  const out = new Map();

  if (byType.booking.length) {
    const q = await client.query(
      `SELECT b.id, b.status, b.slot_date, b.start_time, b.player_id,
              v.name AS venue_name, v.city, v.image_url, u.name AS player_name
         FROM bookings b
         JOIN venues v ON v.id = b.venue_id
         JOIN users u ON u.id = b.player_id
        WHERE b.id = ANY($1::uuid[])`,
      [byType.booking],
    );
    for (const b of q.rows) {
      // The COUNTERPARTY, not "the venue": the owner reading this list needs the
      // player's name, and the player needs the venue's. One row, two titles.
      const iAmPlayer = String(b.player_id) === String(userId);
      out.set(String(b.id), {
        kind: 'booking',
        status: b.status,
        title: iAmPlayer ? b.venue_name : b.player_name,
        imageUrl: iAmPlayer ? b.image_url : null,
        subtitle: `${humanStatus(b.status)} · ${slotLabel(b.slot_date, b.start_time)}`,
        venueName: b.venue_name,
        city: b.city,
        slotLabel: slotLabel(b.slot_date, b.start_time),
      });
    }
  }

  if (byType.captain.length) {
    const q = await client.query(
      `SELECT m.id, m.status, m.score_challenger, m.score_opponent, m.tournament_id,
              m.challenger_team, m.opponent_team,
              tc.name AS challenger_name, tc.logo_url AS challenger_logo,
              tp.name AS opponent_name, tp.logo_url AS opponent_logo,
              EXISTS (SELECT 1 FROM team_members x
                       WHERE x.team_id = m.challenger_team AND x.user_id = $2) AS on_challenger
         FROM matches m
         JOIN teams tc ON tc.id = m.challenger_team
         JOIN teams tp ON tp.id = m.opponent_team
        WHERE m.id = ANY($1::uuid[])`,
      [byType.captain, userId],
    );
    for (const m of q.rows) {
      // "Falcons vs Titans" always reads with MY team first. The row is written
      // per viewer even though the room is shared, because a list is read alone.
      const mine = m.on_challenger ? m.challenger_name : m.opponent_name;
      const theirs = m.on_challenger ? m.opponent_name : m.challenger_name;
      const line = (m.score_challenger !== null && m.score_opponent !== null)
        ? ` · ${m.score_challenger}-${m.score_opponent}`
        : '';
      out.set(String(m.id), {
        kind: 'captain',
        status: m.status,
        title: `${mine} vs ${theirs}`,
        imageUrl: m.on_challenger ? m.opponent_logo : m.challenger_logo,
        subtitle: `${humanStatus(m.status)}${line}`,
        opponentName: theirs,
        isTournament: !!m.tournament_id,
      });
    }
  }

  if (byType.team.length) {
    const q = await client.query(
      `SELECT t.id, t.name, t.logo_url, t.sport,
              (SELECT count(*) FROM team_members x WHERE x.team_id = t.id) AS members
         FROM teams t WHERE t.id = ANY($1::uuid[])`,
      [byType.team],
    );
    for (const t of q.rows) {
      out.set(String(t.id), {
        kind: 'team',
        title: t.name,
        imageUrl: t.logo_url,
        subtitle: `${t.members} member${Number(t.members) === 1 ? '' : 's'}`,
        sport: t.sport,
        memberCount: Number(t.members),
      });
    }
  }
  return out;
}

// The unread expression, written once and reused by the list and the badge so the
// two can never disagree. The watermark is the per-member `last_read_at`, which
// is the same column POST /:channelId/read moves, so the number the badge shows
// is the number opening the thread clears.
//
// System messages COUNT (a "booking cancelled" pill is news); tombstones do not
// (a deleted message must not leave a permanent +1 nobody can clear); and your
// own messages never do.
const UNREAD_SQL = `(SELECT count(*) FROM chat_messages x
    WHERE x.channel_id = c.id
      AND x.deleted_at IS NULL
      AND (x.sender_id IS NULL OR x.sender_id <> $1)
      AND x.created_at > COALESCE(m.last_read_at, '-infinity'::timestamptz))`;

/**
 * Every room this user is in, most recent first.
 *
 * `cursor` is the previous page's last `sortAt`, keyed on the same expression the
 * ORDER BY uses, so paging cannot skip or repeat a row when a message lands
 * mid-scroll (an OFFSET would do both).
 */
async function listChats(client, { userId, limit = 30, cursor = null, type = null }) {
  const lim = Math.min(Math.max(Number(limit) || 30, 1), 60);
  const typeFilter = ['booking', 'captain', 'team'].includes(type) ? type : null;

  const { rows } = await client.query(
    `SELECT c.id, c.type, c.ref_id, c.title, c.image_url, c.created_at,
            c.last_message_at, c.last_message_preview, c.last_message_sender_id,
            c.message_count, m.role, m.last_read_at, m.muted_until,
            COALESCE(c.last_message_at, c.created_at) AS sort_at,
            su.name AS last_message_sender_name,
            ${UNREAD_SQL} AS unread
       FROM chat_channel_members m
       JOIN chat_channels c ON c.id = m.channel_id
       LEFT JOIN users su ON su.id = c.last_message_sender_id
      WHERE m.user_id = $1 AND m.left_at IS NULL
        AND c.type <> 'assistant'
        AND c.archived_at IS NULL
        AND ($2::text IS NULL OR c.type = $2)
        AND ($3::timestamptz IS NULL OR COALESCE(c.last_message_at, c.created_at) < $3)
      ORDER BY sort_at DESC
      LIMIT $4`,
    [userId, typeFilter, cursor, lim],
  );

  const ctx = await contextFor(client, rows, userId);
  const now = Date.now();
  const items = rows.map((r) => {
    const c = ctx.get(String(r.ref_id)) || null;
    return {
      id: r.id,
      type: r.type,
      refId: r.ref_id,
      // The channel's stored title wins when it has one (a team rename is synced
      // into it); the context title is the fallback, and it is what booking and
      // captain rooms actually display.
      title: r.title || (c && c.title) || 'Chat',
      imageUrl: r.image_url || (c && c.imageUrl) || null,
      lastMessageAt: r.last_message_at,
      lastMessagePreview: r.last_message_preview,
      lastMessageSenderId: r.last_message_sender_id,
      lastMessageSenderName: r.last_message_sender_name,
      messageCount: Number(r.message_count || 0),
      unread: Number(r.unread || 0),
      muted: !!(r.muted_until && new Date(r.muted_until).getTime() > now),
      mutedUntil: r.muted_until,
      role: r.role,
      sortAt: r.sort_at,
      context: c,
    };
  });
  return { items, nextCursor: items.length === lim ? items[items.length - 1].sortAt : null };
}

/**
 * The header badge, in one round trip.
 *
 * MUTED ROOMS ARE EXCLUDED. A badge that counts a conversation the user
 * explicitly silenced is why people turn badges off altogether; the room still
 * shows its own count in the list, where it is information rather than a nag.
 */
async function unreadCounts(client, userId) {
  const { rows } = await client.query(
    `SELECT c.type,
            COALESCE(SUM(${UNREAD_SQL}), 0) AS unread,
            COUNT(*) FILTER (WHERE ${UNREAD_SQL} > 0) AS rooms
       FROM chat_channel_members m
       JOIN chat_channels c ON c.id = m.channel_id
      WHERE m.user_id = $1 AND m.left_at IS NULL
        AND c.type <> 'assistant' AND c.archived_at IS NULL
        AND (m.muted_until IS NULL OR m.muted_until <= now())
      GROUP BY c.type`,
    [userId],
  );
  const byType = { booking: 0, captain: 0, team: 0 };
  let total = 0;
  let rooms = 0;
  for (const r of rows) {
    byType[r.type] = Number(r.unread || 0);
    total += Number(r.unread || 0);
    rooms += Number(r.rooms || 0);
  }
  return { total, rooms, byType };
}

/**
 * Resolve a channel id from the thing it is ABOUT, membership-gated.
 *
 * Gating on membership rather than on "is this your booking?" is deliberate: the
 * room's members ARE the booking's participants, so one rule covers both and
 * there is no second authorisation path to keep in sync with the first.
 */
async function channelForRef(client, { type, refId, userId }) {
  const { rows } = await client.query(
    `SELECT c.id FROM chat_channels c
       JOIN chat_channel_members m ON m.channel_id = c.id
      WHERE c.type = $1 AND c.ref_id = $2
        AND m.user_id = $3 AND m.left_at IS NULL`,
    [type, refId, userId],
  );
  return rows[0] ? rows[0].id : null;
}

/**
 * Mute or unmute one room for one member. `until` is null to clear.
 *
 * A TIMESTAMP, NOT A BOOLEAN, and that is the point: "mute for 8 hours" is what
 * people actually want from a booking room the night before a match, and it
 * expires by itself so nobody discovers three weeks later that they silenced
 * their own team. `muted_until` has existed since migration 013 and nothing has
 * ever written it.
 */
async function setMute(client, { channelId, userId, until = null }) {
  const { rows } = await client.query(
    `UPDATE chat_channel_members SET muted_until = $3
      WHERE channel_id = $1 AND user_id = $2 AND left_at IS NULL
      RETURNING muted_until`,
    [channelId, userId, until],
  );
  const mutedUntil = rows[0] ? rows[0].muted_until : null;
  return {
    channelId,
    muted: !!(mutedUntil && new Date(mutedUntil).getTime() > Date.now()),
    mutedUntil,
  };
}

module.exports = {
  humanStatus, slotLabel, contextFor, listChats, unreadCounts, channelForRef, setMute,
};
