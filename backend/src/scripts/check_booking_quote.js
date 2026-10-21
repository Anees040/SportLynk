// Read-only reproduction against the configured database. No booking is created.
const pool = require('../db/pool');
const { previewGroup } = require('../services/bookingService');
const jwt = require('jsonwebtoken');
const assert = require('node:assert/strict');

const args = process.argv.slice(2);
const option = name => {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : null;
};

async function main() {
  if (option('--api')) return compareApi();
  const { rows: columns } = await pool.query(
    `SELECT column_name, data_type FROM information_schema.columns
     WHERE table_schema='public' AND table_name='slots'
       AND column_name IN ('id','venue_id','locked_by','locked_until')`,
  );
  console.log('Slot column types:', columns);
  const { rows } = await pool.query(
    `SELECT venue_id, array_agg(id ORDER BY slot_date, start_time) AS ids
       FROM (SELECT id, venue_id, slot_date, start_time FROM slots
              WHERE status='available' ORDER BY slot_date DESC LIMIT 100) s
      GROUP BY venue_id HAVING count(*) >= 2 LIMIT 1`,
  );
  if (!rows.length) throw new Error('No available pair to quote');
  const result = await previewGroup(pool, {
    userId: '11111111-1111-4111-8111-111111111111',
    venueId: rows[0].venue_id,
    slotIds: rows[0].ids.slice(0, 2),
  });
  console.log('Quote:', JSON.stringify(result));
}

async function compareApi() {
  const base = option('--api').replace(/\/+$/, '');
  const venueName = option('--venue') || 'The Pavilion';
  const date = option('--date') || '2026-10-21';
  const { rows: venues } = await pool.query('SELECT id FROM venues WHERE lower(name)=lower($1)', [venueName]);
  assert.equal(venues.length, 1, 'Expected exactly one venue with that name');
  const venueId = venues[0].id;
  const { rows: slots } = args.includes('--available')
    ? await pool.query(
      `SELECT s.id, s.status FROM slots s
        WHERE s.venue_id=$1 AND s.status='available'
          AND (s.locked_until IS NULL OR s.locked_until <= NOW())
          AND (s.slot_date + s.start_time) > (NOW() AT TIME ZONE 'Asia/Karachi')
        ORDER BY s.slot_date, s.start_time LIMIT 2`, [venueId])
    : await pool.query(
      `SELECT id, status FROM slots WHERE venue_id=$1 AND slot_date=$2
        AND start_time >= '17:00' AND end_time <= '19:00' ORDER BY start_time`,
      [venueId, date],
    );
  assert.equal(slots.length, 2, 'Expected the two slots shown in the report');
  const { rows: players } = await pool.query(
    `SELECT id FROM users WHERE role='player' AND is_active IS NOT FALSE ORDER BY created_at DESC LIMIT 1`,
  );
  assert.ok(players.length, 'An active player is required for the authenticated read');
  const userId = players[0].id;
  const input = { userId, venueId, slotIds: slots.map(slot => slot.id) };
  const local = await previewGroup(pool, input);
  console.log('Current workspace:', JSON.stringify({ status: local.status, code: local.code, total: local.data?.total, saved: local.data?.saved }));
  const token = jwt.sign({ id: userId, role: 'player' }, process.env.JWT_SECRET, { expiresIn: '2m' });
  const response = await fetch(`${base}/bookings/group/quote`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ venueId, slotIds: input.slotIds }),
    signal: AbortSignal.timeout(45000),
  });
  const result = await response.json();
  console.log('Phone API:', JSON.stringify({ base, status: response.status, message: result.message, total: result.data?.total, saved: result.data?.saved }));
  assert.equal(response.status, local.status, 'The deployed API must answer the same quote as the current workspace');
  if (local.ok) assert.equal(result.data.total, local.data.total, 'The deployed quote must match the current service');
}

main().catch(e => {
  console.error('Quote failed:', e.code, e.message);
  process.exitCode = 1;
}).finally(() => pool.end());
