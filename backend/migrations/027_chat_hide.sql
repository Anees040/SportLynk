-- ════════════════════════════════════════════════════════════════════════════
-- 027_chat_hide.sql   ·   per-member "delete/clear conversation"
-- ════════════════════════════════════════════════════════════════════════════
--
-- WhatsApp's "Delete chat" is not a delete: it removes the conversation from the
-- one member's inbox and leaves everyone else's untouched, and the room comes
-- back the moment a new message arrives. That is a per-member watermark, not a
-- state on the channel — the same shape as last_read_at.
--
--   hidden_at   when this member hid the conversation, NULL when it is visible.
--               The inbox lists a room only when it has activity STRICTLY AFTER
--               this stamp: hiding clears the current backlog from view, and the
--               next message un-hides the room by being newer than the stamp.
--               Membership itself is untouched (left_at stays NULL), so the member
--               still receives messages, still counts for the group ticks, and is
--               never removed from a team by clearing its chat.
--
-- Deliberately NOT a delete of any message row: a booking room's history is shared
-- evidence of what was agreed, and one participant clearing their own view must not
-- destroy it for the other. Delete-for-everyone already exists per message
-- (chat_messages.deleted_at) and is a separate, admin-gated action.
--
-- Purely additive and idempotent (ADD COLUMN IF NOT EXISTS): the column starts
-- NULL for every existing member, so every current inbox read behaves exactly as
-- before until POST /chat/channels/:id/hide writes it.

ALTER TABLE chat_channel_members
  ADD COLUMN IF NOT EXISTS hidden_at timestamptz;

COMMENT ON COLUMN chat_channel_members.hidden_at IS
  'When this member hid (cleared) the conversation from their inbox; NULL means '
  'visible. The chat list shows the room only when its last activity is newer than '
  'this stamp, so a new message un-hides it. Membership (left_at) is untouched.';
