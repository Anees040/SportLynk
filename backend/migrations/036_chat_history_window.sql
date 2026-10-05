-- ════════════════════════════════════════════════════════════════════════════
-- 036_chat_history_window.sql   ·   a member's history starts where they joined
-- ════════════════════════════════════════════════════════════════════════════
--
-- WhatsApp's group rule: somebody added to an existing group reads what is said
-- from then on and never the backlog. SportLynk had no such boundary — the
-- history endpoint selected every row in the channel for anybody holding a live
-- membership, so adding a player to a team handed them months of the roster's
-- private conversation.
--
-- WHY A NEW COLUMN RATHER THAN joined_at
--   chat_channel_members.joined_at already records when the membership began, and
--   it is the obvious candidate. It cannot be used:
--
--     chatCore.syncTeamMember's ON CONFLICT clause wrote `joined_at = now()` on
--     every call, and routes/teams.js calls it on a ROLE CHANGE as well as on an
--     add. So a member promoted to vice-captain last week has joined_at = last
--     week, and gating history on that column would delete their history from
--     under them the moment this shipped. Live rows already carry that damage,
--     which no migration can undo — the real dates are gone.
--
--   history_from is therefore a separate fact with exactly one writer (membership
--   creation) and one meaning: the earliest message this member may read. That it
--   is independent of joined_at is a feature, not duplication — "when did you
--   join" is audit data that the roster screen shows and a captain may correct,
--   while this is an access boundary that must never move for a reason unrelated
--   to joining. chatCore is fixed in the same change to stop rewriting joined_at.
--
-- NULL MEANS "EVERYTHING"
--   Every row that exists when this migration runs keeps a NULL, and the history
--   query reads NULL as no lower bound. Nobody already in a chat loses a message.
--   The boundary applies from here on: chatCore stamps now() on every membership
--   it creates, which for a brand-new channel precedes its first message (so the
--   founding members see all of it) and for an existing channel is the join.
--
-- REJOINING
--   A member who left and is added back gets a fresh window — the conversation
--   that happened while they were out is not theirs. The cost is that the history
--   they legitimately read before leaving goes with it, because one timestamp
--   cannot express two windows. Privacy is the side to err on, and re-adding
--   somebody is a deliberate act by an admin rather than an accident.
--
-- Purely additive: one nullable column on one table. No row is rewritten, no
-- constraint changes, and a server running the previous code ignores the column
-- entirely. Safe to re-run.

ALTER TABLE chat_channel_members
  ADD COLUMN IF NOT EXISTS history_from timestamptz;

COMMENT ON COLUMN chat_channel_members.history_from IS
  'The earliest message created_at this member may read. NULL means no lower '
  'bound (every membership that predates migration 036, which keeps full '
  'history). Stamped now() when a membership row is created and when a member '
  'who had left is re-added; never moved by a role change. Distinct from '
  'joined_at, which is audit data and was historically overwritten on role '
  'syncs.';

-- No index. The column is read as a single scalar from the member row the
-- endpoint has already fetched to prove membership, and then compared against
-- chat_messages.created_at — a range the existing (channel_id, created_at DESC)
-- index from 013/015 already serves. An index on history_from itself would be
-- written on every join and read by nothing.
