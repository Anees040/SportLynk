/**
 * adminPermissions.js — the catalog of admin permissions, in one place.
 *
 * This is the single source of truth for what a sub-admin can be granted. The
 * permission middleware validates against it, the admin-management service refuses a
 * key not listed here, and the Flutter "Manage admins" screen renders its checkboxes
 * from `GET /api/admin/permissions`, which serves this list verbatim — so the two
 * halves can never drift, the same reason the settings catalog is server-owned.
 *
 * Each key maps 1:1 to a real admin surface, and the route that enforces it is named
 * so the mapping is greppable:
 *
 *   owner_approvals    admin.js        — owner registration + venue approval/rejection
 *   match_disputes     adminDisputes.js— the match-dispute queue, case file and ruling
 *   booking_disputes   adminDisputes.js— the booking-dispute queue and uphold/reject
 *   user_management    adminUsers.js   — user search, suspend and reinstate
 *   review_moderation  admin.js        — the flagged-review queue and hide/restore
 *   platform_settings  adminSettings.js— commission, deposits, Elo, sports toggles
 *   financial_reports  reports.js      — the platform CSV / JSON export
 *
 * Managing admins is deliberately NOT a key here: it is Super-Admin-only and never
 * delegable, so there is always exactly one accountable owner of the admin tier.
 */

/** The ordered catalog. `order` fixes the render order on the admin screen. */
const PERMISSIONS = Object.freeze([
  {
    key: 'owner_approvals',
    label: 'Owner & venue approvals',
    description: 'Review owner registrations and approve or reject owners and their venues.',
  },
  {
    key: 'match_disputes',
    label: 'Match disputes',
    description: 'Rule on disputed matches and adjust the result and ratings.',
  },
  {
    key: 'booking_disputes',
    label: 'Booking disputes',
    description: 'Resolve booking disputes a player raised, upholding (refunding) or rejecting.',
  },
  {
    key: 'user_management',
    label: 'User management',
    description: 'Search accounts, suspend an account and reinstate it.',
  },
  {
    key: 'review_moderation',
    label: 'Review moderation',
    description: 'Act on flagged reviews — hide, restore or dismiss the flag.',
  },
  {
    key: 'platform_settings',
    label: 'Platform settings',
    description: 'Change commission, deposits, Elo and which sports are bookable.',
  },
  {
    key: 'financial_reports',
    label: 'Financial reports',
    description: 'View and export the platform financial report (commission per owner).',
  },
]);

/** The set of valid keys, for fast membership checks. */
const PERMISSION_KEYS = Object.freeze(PERMISSIONS.map((p) => p.key));
const KEY_SET = new Set(PERMISSION_KEYS);

/** True when `key` is a permission this catalog defines. */
function isValidKey(key) {
  return typeof key === 'string' && KEY_SET.has(key);
}

/**
 * Normalise a client-supplied list into a clean, de-duplicated subset of the catalog.
 * Returns `{ ok, permissions, invalid }`: `ok` is false when any entry is not a known
 * key, and `invalid` names the offenders so the route can say which one it rejected
 * rather than failing with a bare "invalid".
 */
function sanitize(list) {
  if (!Array.isArray(list)) return { ok: false, permissions: [], invalid: ['(not a list)'] };
  const invalid = [];
  const out = new Set();
  for (const raw of list) {
    const k = typeof raw === 'string' ? raw.trim() : '';
    if (isValidKey(k)) out.add(k);
    else invalid.push(String(raw));
  }
  // Preserve catalog order so stored and rendered permissions read consistently.
  const permissions = PERMISSION_KEYS.filter((k) => out.has(k));
  return { ok: invalid.length === 0, permissions, invalid };
}

module.exports = {
  PERMISSIONS,
  PERMISSION_KEYS,
  isValidKey,
  sanitize,
};
