/**
 * Team rules in one place — validation, roles, and the invariants FR2.10 needs.
 *
 * This is a util rather than a chunk of routes/teams.js on purpose. Every rule
 * here is enforced on more than one endpoint (creating, editing, inviting,
 * approving a join request and promoting all have to agree on what a captain is
 * and what a legal team name is), and a rule that lives in two route handlers
 * eventually disagrees with itself.
 *
 * SECURITY NOTE — none of these helpers trust the request body for authority.
 * `req.user.id` comes from the verified JWT; the caller's role is always re-read
 * from team_members inside the same transaction as the write it authorises, so a
 * client cannot send `{"role":"captain"}` and be believed, and cannot win a race
 * by being demoted between the check and the write.
 */

const pool = require('../db/pool');

// ─── Vocabulary ───────────────────────────────────────────────────────────────

// Mirrors the `team_sport` ENUM (schema.sql:210). Kept here so a bad value is a
// readable 400 instead of a 500 from Postgres error 22P02 ("invalid input value
// for enum team_sport"), which would leak the type name to the client.
const TEAM_SPORTS = ['football', 'cricket'];
const SPORT_LABEL = { football: 'Football', cricket: 'Cricket' };

// `teams.visibility` (migration 013) is free text, so this list is the only
// thing standing between the column and arbitrary input.
const VISIBILITIES = ['public', 'private'];

// Mirrors chk_team_members_role (migration 015).
const TEAM_ROLES = ['captain', 'vice_captain', 'member'];
const ROLE_LABEL = { captain: 'Captain', vice_captain: 'Vice Captain', member: 'Member' };

/**
 * Who may do what.
 *
 * FR2.10 only names the captain, but a one-captain team whose captain is asleep
 * cannot accept a single player, which is exactly the friction that pushes a
 * squad back into WhatsApp. So there are two administrative tiers, matching what
 * a group chat user already expects:
 *
 *   captain       — everything, including roles, team settings and disbanding
 *   vice_captain  — invite, approve/reject join requests, remove plain members
 *   member        — read, chat, leave
 *
 * A vice captain deliberately CANNOT promote, demote, or remove another admin:
 * that is the one power that could be used to take a team from its captain.
 */
const ADMIN_ROLES = ['captain', 'vice_captain'];
const isCaptain = (role) => role === 'captain';
const isAdmin = (role) => ADMIN_ROLES.includes(role);

// A cap, because a team is a squad and not a broadcast list. Without one, a
// single invite link posted publicly can grow a team until the roster screen and
// every "notify the whole team" write become expensive.
const MAX_TEAM_SIZE = 30;

// Cheap ceiling on outstanding invites, so a compromised captain account cannot
// mint unlimited join tokens (each is a bearer capability for 48 hours).
const MAX_LIVE_INVITES = 20;
const INVITE_TTL_HOURS = 48;   // FR2.11

// One person cannot be in twenty teams per sport in a real league, and the cap
// stops an automated account from spamming join requests across the platform.
const MAX_TEAMS_PER_USER = 10;

// ─── Text hygiene ─────────────────────────────────────────────────────────────

/**
 * Characters that have no business in a display string.
 *
 * Built with `new RegExp` from escape sequences rather than written as a literal,
 * so the source file itself contains only printable ASCII — a raw NUL or a raw
 * RTL override inside a .js file breaks diffs, greps and editors long before it
 * breaks the code.
 *
 * Two classes, for two different reasons:
 *
 *   controls  C0/C1, sparing \t \n \r which squash()/squashMultiline() handle
 *             deliberately. A raw control byte in a team name corrupts logs and
 *             can truncate output in any consumer that treats NUL as an end.
 *   invisible Zero-width characters and the bidi overrides. U+202E inside a name
 *             reverses everything after it, which is a cheap way to make one
 *             team's name impersonate another's in a list; and "Li<ZWSP>ons"
 *             looks identical to "Lions" to a human while sailing straight past
 *             the unique index that is supposed to stop duplicate names.
 */
const RE_CONTROL = new RegExp('[\\u0000-\\u0008\\u000B\\u000C\\u000E-\\u001F\\u007F-\\u009F]', 'g');
const RE_INVISIBLE = new RegExp('[\\u200B-\\u200F\\u202A-\\u202E\\u2060-\\u2064\\u2066-\\u2069\\uFEFF]', 'g');

function stripUnsafe(raw) {
  return String(raw).replace(RE_CONTROL, '').replace(RE_INVISIBLE, '');
}

/** Collapse runs of whitespace to single spaces and trim the ends. */
function squash(raw) {
  return stripUnsafe(raw).replace(/\s+/g, ' ').trim();
}

/**
 * Multi-line text (a bio, a chat message): keep newlines, drop the rest of the
 * whitespace noise, and cap consecutive blank lines so nobody can push a screen
 * of empty space into a list.
 */
function squashMultiline(raw) {
  return stripUnsafe(raw)
    .replace(/\r\n?/g, '\n')
    .replace(/[ \t]+/g, ' ')
    .replace(/ *\n */g, '\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

/**
 * Is this string shaped like a UUID?
 *
 * Every id in this schema is a UUID, and handing Postgres `/api/teams/abc` gives
 * SQLSTATE 22P02 — which the global error handler can only turn into a 500. A
 * mistyped link is a 404, not a server fault, so the shape is checked before the
 * value ever reaches a query.
 */
const RE_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const isUuid = (v) => typeof v === 'string' && RE_UUID.test(v.trim());

const NAME_MIN = 3;
const NAME_MAX = 40;
const BIO_MAX = 300;
const CITY_MAX = 60;

/**
 * Validate and normalise a team name.
 *
 * Returns `{ ok:true, value }` or `{ ok:false, message }` — never throws, so a
 * route can answer 400 with the message verbatim. The DB then has the final say
 * on uniqueness via ux_teams_name_sport (migration 015); this only catches the
 * shapes that are wrong regardless of what else exists.
 */
function validateTeamName(raw) {
  if (raw === undefined || raw === null || String(raw).trim() === '') {
    return { ok: false, message: 'Team name is required.' };
  }
  const value = squash(raw);
  if (value.length < NAME_MIN) {
    return { ok: false, message: `Team name must be at least ${NAME_MIN} characters.` };
  }
  if (value.length > NAME_MAX) {
    return { ok: false, message: `Team name cannot be longer than ${NAME_MAX} characters.` };
  }
  // At least two letters or digits, so "!!!" and "---" are not team names. This
  // also blocks a name made only of combining marks, which renders as a smear.
  if ((value.match(/[\p{L}\p{N}]/gu) || []).length < 2) {
    return { ok: false, message: 'Team name needs at least two letters or numbers.' };
  }
  return { ok: true, value };
}

function validateBio(raw) {
  if (raw === undefined || raw === null) return { ok: true, value: null };
  const value = squashMultiline(raw);
  if (value === '') return { ok: true, value: null };
  if (value.length > BIO_MAX) {
    return { ok: false, message: `Bio cannot be longer than ${BIO_MAX} characters.` };
  }
  return { ok: true, value };
}

function validateCity(raw) {
  if (raw === undefined || raw === null) return { ok: true, value: null };
  const value = squash(raw);
  if (value === '') return { ok: true, value: null };
  if (value.length > CITY_MAX) {
    return { ok: false, message: 'City name is too long.' };
  }
  return { ok: true, value };
}

function validateSport(raw) {
  const value = String(raw || '').toLowerCase().trim();
  if (!TEAM_SPORTS.includes(value)) {
    return {
      ok: false,
      message: `Choose a sport: ${TEAM_SPORTS.map((s) => SPORT_LABEL[s]).join(' or ')}.`,
    };
  }
  return { ok: true, value };
}

function validateVisibility(raw, fallback = 'public') {
  if (raw === undefined || raw === null || raw === '') return { ok: true, value: fallback };
  // The Flutter toggle is a bool; accept both so the client can send either.
  if (raw === true) return { ok: true, value: 'public' };
  if (raw === false) return { ok: true, value: 'private' };
  const value = String(raw).toLowerCase().trim();
  if (!VISIBILITIES.includes(value)) {
    return { ok: false, message: 'Visibility must be public or private.' };
  }
  return { ok: true, value };
}

/**
 * Accept a media URL only if it is one of ours.
 *
 * A `logo_url` is echoed back to every member and rendered by the app, so an
 * arbitrary attacker-supplied URL is a real problem: it turns every roster view
 * into a request to a host of their choosing (IP/User-Agent harvesting, and a
 * tracking pixel that reports exactly who opened a team), and `http://` targets
 * would also break the release build's cleartext policy. Pinning to Cloudinary —
 * the only uploader the app has — makes the field a reference to something we
 * host rather than a redirect to anywhere.
 */
const MEDIA_HOSTS = ['res.cloudinary.com'];
function validateMediaUrl(raw, { label = 'Image', required = false } = {}) {
  if (raw === undefined || raw === null || String(raw).trim() === '') {
    return required
      ? { ok: false, message: `${label} is required.` }
      : { ok: true, value: null };
  }
  const value = String(raw).trim();
  if (value.length > 500) return { ok: false, message: `${label} URL is too long.` };
  let url;
  try {
    url = new URL(value);
  } catch {
    return { ok: false, message: `${label} could not be read as a link.` };
  }
  if (url.protocol !== 'https:') {
    return { ok: false, message: `${label} must be an https link.` };
  }
  if (!MEDIA_HOSTS.includes(url.hostname.toLowerCase())) {
    return { ok: false, message: `${label} must be uploaded through the app.` };
  }
  return { ok: true, value: url.toString() };
}

// ─── Membership reads ─────────────────────────────────────────────────────────

/**
 * Lock the team row for the duration of a membership change.
 *
 * FOR UPDATE, not a plain SELECT, and this is not decoration. "A team always has
 * at least one captain" (FR2.10) is a rule about a COUNT, and a count is only
 * safe if concurrent writers are serialised. Two captains hitting "leave" at the
 * same moment would otherwise both read `captains = 2`, both decide they are not
 * the last one, and both commit — leaving a team nobody can administer, with no
 * constraint violated. Locking the parent `teams` row makes every membership
 * change to one team take its turn.
 */
async function lockTeam(client, teamId) {
  const { rows } = await client.query(
    `SELECT id, name, sport::text AS sport, visibility, logo_url, bio, city,
            captain_id, elo, wins, losses, draws, created_at
       FROM teams WHERE id = $1 FOR UPDATE`,
    [teamId],
  );
  return rows[0] || null;
}

/** The caller's own row in a team, or null if they are not in it. */
async function loadMembership(client, teamId, userId) {
  const { rows } = await client.query(
    `SELECT role, joined_at FROM team_members WHERE team_id = $1 AND user_id = $2`,
    [teamId, userId],
  );
  return rows[0] || null;
}

async function countCaptains(client, teamId) {
  const { rows } = await client.query(
    `SELECT count(*)::int AS n FROM team_members
      WHERE team_id = $1 AND role = 'captain'`,
    [teamId],
  );
  return rows[0].n;
}

async function countMembers(client, teamId) {
  const { rows } = await client.query(
    `SELECT count(*)::int AS n FROM team_members WHERE team_id = $1`,
    [teamId],
  );
  return rows[0].n;
}

/**
 * Every user id on a team's roster — the fan-out list for notifications and for
 * pushing a socket event to people who are not currently in the chat screen.
 */
async function teamMemberIds(client, teamId, { except = null } = {}) {
  const { rows } = await client.query(
    `SELECT user_id FROM team_members WHERE team_id = $1`, [teamId],
  );
  return rows.map((r) => r.user_id).filter((id) => id !== except);
}

/**
 * Guard used by every mutating team route.
 *
 * Answers with a `{ error: { status, message } }` pair rather than throwing,
 * because these are all expected outcomes with distinct HTTP codes — 404 for a
 * team that does not exist, 403 for one the caller has no business in — and an
 * exception would flatten them into a 500 via the global handler.
 *
 * `need` is 'member' | 'admin' | 'captain'.
 */
async function requireRole(client, teamId, userId, need = 'captain') {
  const team = await lockTeam(client, teamId);
  if (!team) return { error: { status: 404, message: 'Team not found.' } };

  const me = await loadMembership(client, teamId, userId);
  if (!me) {
    return { error: { status: 403, message: 'You are not a member of this team.' } };
  }
  if (need === 'captain' && !isCaptain(me.role)) {
    return { error: { status: 403, message: 'Only the team captain can do that.' } };
  }
  if (need === 'admin' && !isAdmin(me.role)) {
    return { error: { status: 403, message: 'Only the captain or vice captain can do that.' } };
  }
  return { team, me };
}

// ─── Shared SQL ───────────────────────────────────────────────────────────────

/**
 * The public shape of a team, used by /teams/mine, /teams/:id, browse and
 * rankings so all four return the same field names and Flutter needs one model.
 *
 * `sport::text` because pg hands an ENUM back as its label anyway, but being
 * explicit means a future ENUM rename cannot silently change the wire format.
 */
const TEAM_COLUMNS = `
  t.id, t.name, t.sport::text AS sport, t.logo_url, t.bio, t.visibility,
  t.city, t.elo, t.wins, t.losses, t.draws, t.captain_id, t.created_at,
  t.tournament_played, t.tournament_wins, t.finals_reached, t.titles`;

/**
 * One roster row as the app wants it. LEFT JOIN, not JOIN, on player_profiles —
 * a user who never completed a profile must not vanish from the roster.
 */
const MEMBER_COLUMNS = `
  tm.user_id AS id, tm.role, tm.joined_at, tm.invited_by,
  u.name, u.avatar_url, u.last_seen_at,
  pp.trust_score, pp.elo_rating AS player_elo`;

const MEMBER_FROM = `
  FROM team_members tm
  JOIN users u ON u.id = tm.user_id
  LEFT JOIN player_profiles pp ON pp.user_id = tm.user_id`;

/**
 * Captain first, then vice captains, then members alphabetically — the order the
 * roster screen renders without having to sort client-side (FR2.9 pins the
 * captain to the top). Done in SQL because re-sorting the list in Dart on every
 * rebuild is waste, and because two screens would otherwise each invent an order.
 */
const MEMBER_ORDER = `
  ORDER BY CASE tm.role WHEN 'captain' THEN 0 WHEN 'vice_captain' THEN 1 ELSE 2 END,
           lower(u.name)`;

/** Roster for one team, ordered for display. */
async function fetchRoster(clientOrPool, teamId) {
  const { rows } = await (clientOrPool || pool).query(
    `SELECT ${MEMBER_COLUMNS} ${MEMBER_FROM} WHERE tm.team_id = $1 ${MEMBER_ORDER}`,
    [teamId],
  );
  return rows;
}

module.exports = {
  TEAM_SPORTS,
  SPORT_LABEL,
  VISIBILITIES,
  TEAM_ROLES,
  ROLE_LABEL,
  ADMIN_ROLES,
  MAX_TEAM_SIZE,
  MAX_LIVE_INVITES,
  MAX_TEAMS_PER_USER,
  INVITE_TTL_HOURS,
  NAME_MAX,
  BIO_MAX,
  isCaptain,
  isAdmin,
  isUuid,
  stripUnsafe,
  squash,
  squashMultiline,
  validateTeamName,
  validateBio,
  validateCity,
  validateSport,
  validateVisibility,
  validateMediaUrl,
  lockTeam,
  loadMembership,
  countCaptains,
  countMembers,
  teamMemberIds,
  requireRole,
  fetchRoster,
  TEAM_COLUMNS,
  MEMBER_COLUMNS,
  MEMBER_FROM,
  MEMBER_ORDER,
};
