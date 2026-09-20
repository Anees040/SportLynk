-- ═══════════════════════════════════════════════════════════════════════════
-- 025_team_disband.sql   ·   soft-disband for teams
--
-- Two nullable columns so a captain can dissolve a team without destroying the
-- history that hangs off teams.id. A team is not a chat group: its id is
-- referenced by matches, elo_history, tournament entries and the leaderboard's
-- win/loss columns live on the row itself. A hard DELETE would orphan every one
-- of those (a ruled match pointing at a team that no longer exists, a
-- leaderboard that cannot name last season's champion), so "disband" marks the
-- row archived and leaves the record intact.
--
--   disbanded_at   when the team was dissolved; NULL means active. Every public
--                  read (discovery, rankings) filters on `disbanded_at IS NULL`,
--                  and the roster is emptied at disband time, so an archived team
--                  simply stops appearing while its matches keep counting for the
--                  opponents it played.
--   disbanded_by   who dissolved it, kept for the audit trail an admin dispute
--                  might need. ON DELETE SET NULL because the row must survive
--                  the eventual deletion of a user account.
--
-- Purely additive and idempotent (ADD COLUMN IF NOT EXISTS): no existing row is
-- rewritten, and every value starts NULL, so the behaviour of every current
-- query is unchanged until the disband endpoint writes a timestamp.

ALTER TABLE teams ADD COLUMN IF NOT EXISTS disbanded_at timestamptz;
ALTER TABLE teams ADD COLUMN IF NOT EXISTS disbanded_by uuid REFERENCES users(id) ON DELETE SET NULL;

COMMENT ON COLUMN teams.disbanded_at IS
  'When the team was dissolved by its captain; NULL means active. Public reads '
  'filter on IS NULL. The row is kept so matches, elo_history and tournament '
  'entries that reference teams.id are never orphaned.';
COMMENT ON COLUMN teams.disbanded_by IS
  'The captain who disbanded the team, for the audit trail. NULL once active.';
