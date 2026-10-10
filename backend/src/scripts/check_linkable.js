/**
 * check_linkable.js — read-only diagnostic for "no confirmed bookings to link".
 *
 * The challenge screen's booking picker (GET /matches/linkable-bookings) shows a
 * captain their own CONFIRMED, still-FUTURE bookings that no live match already
 * uses, filtered to the team's sport. When a player who clearly holds a confirmed
 * booking sees "you have no confirmed upcoming bookings left to link", one of those
 * clauses is excluding it. This script names which one, per (player, team), without
 * writing anything.
 *
 * Usage (from backend/):
 *   node src/scripts/check_linkable.js                 # scan every team member
 *   node src/scripts/check_linkable.js someone@mail.pk # one player, by email or id
 *
 * Read-only: SELECT only. Safe against the live database.
 */
const pool = require('../db/pool');
const mc = require('../utils/matchCore');

const LIVE = mc.LIVE_STATUSES;
const TZ = mc.TIMEZONE;

function sportMatches(teamSport, venueSport) {
  const s = (teamSport || '').toLowerCase();
  const v = (venueSport || '').toLowerCase();
  if (!s) return true;
  if (!['football', 'cricket'].includes(v)) return true;
  return v === s;
}

async function main() {
  const arg = process.argv[2] || null;

  // Every CONFIRMED booking of a team member, with the exact clause flags the
  // linkable query applies. team_members is the membership table the route reads
  // its captaincy from.
  const params = [TZ, LIVE];
  let who = '';
  if (arg) {
    who = arg.includes('@') ? 'AND lower(u.email) = lower($3)' : 'AND u.id::text = $3';
    params.push(arg);
  }

  const { rows } = await pool.query(
    `SELECT u.id AS player_id, u.name AS player_name, u.email,
            t.id AS team_id, t.name AS team_name, t.sport::text AS team_sport,
            b.id AS booking_id, b.slot_date, b.start_time,
            v.name AS venue_name, lower(v.sport_type) AS venue_sport,
            ((b.slot_date::DATE + b.start_time::TIME) > (NOW() AT TIME ZONE $1)) AS is_future,
            EXISTS (SELECT 1 FROM matches m
                     WHERE m.booking_id = b.id AND m.status = ANY($2::text[])) AS already_matched
       FROM bookings b
       JOIN users u ON u.id = b.player_id
       JOIN venues v ON v.id = b.venue_id
       JOIN team_members tm ON tm.user_id = u.id
       JOIN teams t ON t.id = tm.team_id
      WHERE b.status = 'confirmed' ${who}
      ORDER BY u.name, t.name, b.slot_date, b.start_time
      LIMIT 500`,
    params,
  );

  if (!rows.length) {
    console.log('No CONFIRMED bookings found for team members' + (arg ? ` matching "${arg}"` : '') + '.');
    console.log('If the booking in question reads "confirmed" in the app but is not here, it is');
    console.log('most likely still status=pending (the QR appears before the owner approves).');
    return;
  }

  // Group by player+team so the output reads like the screen the captain sees.
  const groups = new Map();
  for (const r of rows) {
    const key = `${r.player_id}::${r.team_id}`;
    if (!groups.has(key)) groups.set(key, { r, items: [] });
    groups.get(key).items.push(r);
  }

  for (const { r, items } of groups.values()) {
    console.log(`\n${r.player_name} <${r.email}>  —  team "${r.team_name}" (sport: ${r.team_sport})`);
    let linkable = 0;
    for (const b of items) {
      const future = b.is_future === true;
      const matched = b.already_matched === true;
      const sportOk = sportMatches(r.team_sport, b.venue_sport);
      const ok = future && !matched && sportOk;
      if (ok) linkable += 1;
      const reasons = [];
      if (!future) reasons.push('slot is in the PAST (PKT)');
      if (matched) reasons.push('already attached to a live match');
      if (!sportOk) reasons.push(`venue sport ${b.venue_sport} != team sport ${r.team_sport}`);
      const tag = ok ? 'LINKABLE  ' : 'excluded  ';
      const date = b.slot_date instanceof Date ? b.slot_date.toLocaleDateString('en-CA') : b.slot_date;
      console.log(`  ${tag} ${date} ${String(b.start_time).slice(0, 5)}  ${b.venue_name}` +
        (ok ? '' : `  — ${reasons.join('; ')}`));
    }
    console.log(`  => ${linkable} of ${items.length} confirmed booking(s) are linkable for this team.`);
  }

  console.log('\nIf a booking you expected is "excluded", the reason beside it is the fix target.');
}

main()
  .catch((e) => { console.error('check_linkable error:', e.message); process.exitCode = 1; })
  .finally(() => pool.end());
