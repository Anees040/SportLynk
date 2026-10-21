const express = require('express');
const router = express.Router();
const pool = require('../db/pool');
const { requirePermission } = require('../middleware/permissionMiddleware');

// Mounted under admin.js's authentication and admin-role gates. Each list uses
// the same predicate as /stats and its existing management permission.
const lists = [
  {
    path: '/venues/active', permission: 'owner_approvals', alias: 'v',
    select: `v.id, v.name, v.city, v.address, v.sport_type,
             u.name AS owner_name, v.created_at::text AS cursor_time`,
    from: 'venues v LEFT JOIN users u ON u.id = v.owner_id',
    where: 'v.is_active = true',
  },
  {
    path: '/bookings/active', permission: 'booking_disputes', alias: 'b',
    select: `b.id, b.status, b.slot_date::text, b.start_time, b.end_time,
             b.total_amount, v.name AS venue_name, u.name AS player_name,
             b.created_at::text AS cursor_time`,
    from: `bookings b LEFT JOIN venues v ON v.id = b.venue_id
           LEFT JOIN users u ON u.id = b.player_id`,
    where: "b.status IN ('pending', 'confirmed', 'checked_in')",
  },
];

for (const list of lists) {
  router.get(list.path, requirePermission(list.permission), async (req, res, next) => {
    try {
      const limit = Math.min(Math.max(parseInt(req.query.limit, 10) || 25, 1), 50);
      const params = [];
      let where = list.where;
      if (req.query.cursor) {
        const parts = String(req.query.cursor).split('~');
        const [time, id] = parts;
        if (parts.length !== 2 || !Number.isFinite(Date.parse(time)) ||
            !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) {
          return res.status(400).json({ success: false, message: 'Invalid page cursor.' });
        }
        params.push(time, id);
        where += ` AND (${list.alias}.created_at, ${list.alias}.id) < ($1::timestamptz, $2::uuid)`;
      }
      params.push(limit + 1);
      const { rows } = await pool.query(
        `SELECT ${list.select} FROM ${list.from} WHERE ${where}
         ORDER BY ${list.alias}.created_at DESC, ${list.alias}.id DESC
         LIMIT $${params.length}`, params,
      );
      const hasMore = rows.length > limit;
      const page = rows.slice(0, limit);
      const last = page[page.length - 1];
      res.json({
        success: true,
        data: {
          items: page.map(({ cursor_time, ...row }) => row),
          nextCursor: hasMore ? `${last.cursor_time}~${last.id}` : null,
        },
      });
    } catch (error) { next(error); }
  });
}

module.exports = router;
