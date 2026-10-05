-- ════════════════════════════════════════════════════════════════════════════
-- 037_player_profile_visibility.sql   ·   public / private player profiles
-- ════════════════════════════════════════════════════════════════════════════
--
-- A player deciding whether to accept a play request, or a captain weighing whom to
-- invite, had nothing to look at: the app has only ever exposed a player's OWN
-- profile. This adds the visibility flag behind an Instagram-style public profile —
-- a public account opens fully, a private one shows only its name, avatar and
-- headline scores and cannot be asked to play by a stranger.
--
-- Purely additive. Two nullable/defaulted columns on an existing table, no data
-- rewritten, no constraint changed. Every current read and write behaves exactly as
-- before until the first profile is made private.
--
-- `is_public` defaults TRUE on purpose: every account that exists today is already
-- effectively public (there was no way to be otherwise), so the default preserves
-- the status quo rather than hiding everyone the moment this lands. A player opts
-- into privacy; they are not opted in for them.
--
-- `bio` is the one new piece of profile text a public profile can carry. It lives
-- here beside sport_preferences rather than on users, because it is player-facing
-- content, not account identity, and owners/admins have no use for it.

ALTER TABLE player_profiles
  ADD COLUMN IF NOT EXISTS is_public boolean NOT NULL DEFAULT true;

ALTER TABLE player_profiles
  ADD COLUMN IF NOT EXISTS bio text;

COMMENT ON COLUMN player_profiles.is_public IS
  'Instagram-style visibility. true = the full profile (sports, bio, teams, '
  'activity) is visible to any signed-in user and the player may be asked to play. '
  'false = only name, avatar, trust and ELO are visible and play requests are '
  'refused. Defaults true so existing accounts are unchanged.';
COMMENT ON COLUMN player_profiles.bio IS
  'Optional free-text headline the player writes for their public profile.';
