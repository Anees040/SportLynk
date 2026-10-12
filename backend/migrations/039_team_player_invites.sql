-- ════════════════════════════════════════════════════════════════════════════
-- 039_team_player_invites.sql   ·   direct team → player invitations
-- ════════════════════════════════════════════════════════════════════════════
--
-- The mirror of team_join_requests (028's play_requests is player→player; the join
-- request is player→team). This is the missing TEAM→PLAYER direction: a captain who
-- is short of players picks a specific player and invites them straight into the
-- squad. The invite lands in that player's inbox; accepting adds them to the team.
--
-- Shaped exactly like team_join_requests so the roster/inbox code reads both the same
-- way: a small state machine (pending → accepted|declined|cancelled), one LIVE invite
-- per (team, player) at a time, and the inviting admin recorded for the audit trail.
--
-- Purely additive: one new table and its indexes, nothing on an existing table, so
-- every current read and write behaves exactly as before until the first invite.

CREATE TABLE IF NOT EXISTS team_player_invites (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  team_id     UUID NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
  user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,   -- the invited player
  status      text NOT NULL DEFAULT 'pending',                        -- pending|accepted|declined|cancelled
  message     text,                                                   -- optional note from the captain
  -- The admin who sent it. SET NULL, not CASCADE: losing the inviter's account must
  -- not erase the record that the player was invited.
  invited_by  UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  decided_at  timestamptz,                                            -- when accepted/declined
  CONSTRAINT chk_team_player_invites_status
    CHECK (status IN ('pending', 'accepted', 'declined', 'cancelled'))
);

-- At most one LIVE invite per (team, player). Partial on status='pending', so a
-- declined or cancelled invite does not block a later re-invite. A duplicate pending
-- insert raises 23505, which the service turns into a friendly 409.
CREATE UNIQUE INDEX IF NOT EXISTS ux_team_player_invites_pending
  ON team_player_invites (team_id, user_id)
  WHERE status = 'pending';

-- The player's inbox ("who has invited me"), newest first.
CREATE INDEX IF NOT EXISTS idx_team_player_invites_incoming
  ON team_player_invites (user_id, status, created_at DESC);
-- The captain's view ("who have we invited to this team").
CREATE INDEX IF NOT EXISTS idx_team_player_invites_team
  ON team_player_invites (team_id, status);

COMMENT ON TABLE team_player_invites IS
  'Directed team->player invitations (pending/accepted/declined/cancelled). The '
  'mirror of team_join_requests; accepting adds the player to team_members.';
