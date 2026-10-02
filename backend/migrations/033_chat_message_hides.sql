-- ════════════════════════════════════════════════════════════════════════════
-- 033_chat_message_hides.sql   ·   "Delete for me" on a single message
-- ════════════════════════════════════════════════════════════════════════════
--
-- WhatsApp offers two deletes on a message: "Delete for everyone", which is the
-- existing tombstone (chat_messages.deleted_at — visible to the room as "This
-- message was deleted"), and "Delete for me", which removes it from one person's
-- view and leaves it untouched for everybody else.
--
-- The second needs per-reader state, so it cannot live on chat_messages: one row
-- per (message, reader) is the only shape that lets two members of the same room
-- disagree about whether a line is visible. 027 did the same thing for a whole
-- conversation (chat_channel_members.hidden_at); this is the per-message
-- equivalent.
--
-- Deliberately not a soft flag on the message: a hide is private. Nothing is
-- broadcast, no system pill is posted, and the sender is never told — hiding is a
-- reader's own housekeeping, not an action on the conversation.
--
-- Purely additive: one new table and one index. No existing table is altered and
-- no row is rewritten; every message stays visible until a reader hides it.

CREATE TABLE IF NOT EXISTS chat_message_hides (
  message_id UUID NOT NULL REFERENCES chat_messages(id) ON DELETE CASCADE,
  user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, user_id)
);

-- The read the history query makes: "which messages has THIS reader hidden?".
-- The primary key already covers (message_id, user_id); this index serves the
-- other direction, which is the one the per-reader filter uses.
CREATE INDEX IF NOT EXISTS idx_chat_message_hides_user
  ON chat_message_hides (user_id, message_id);

COMMENT ON TABLE chat_message_hides IS
  'One row per (message, reader) that the reader hid with "Delete for me". '
  'Private to that reader: the message itself is untouched and every other '
  'member still sees it. Distinct from chat_messages.deleted_at, which is '
  '"delete for everyone".';
