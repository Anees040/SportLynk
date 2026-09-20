-- ════════════════════════════════════════════════════════════════════════════
-- 026_chat_mentions_pins.sql   ·   @mentions and pinned messages
-- ════════════════════════════════════════════════════════════════════════════
--
-- Two chat features that need a column each. Reply/quote is deliberately absent:
-- reply_to_id has existed on chat_messages since migration 015, so the reply
-- feature is wiring and UI, not schema.
--
--   mentions    the user ids a message @-mentions, as a jsonb array of uuid
--               strings. A message body is not parsed on the server to find them:
--               a display name can contain spaces and repeat across members, so
--               the client — which built the mention from a member picker and
--               therefore knows the exact user — sends the resolved id list, and
--               the route keeps only ids that are live members of the channel.
--               jsonb rather than a join table because a mention is read with its
--               message and never queried across messages; storing it on the row
--               keeps "who was mentioned" a property of the one row it belongs to.
--
--   pinned_at   when a message was pinned to the top of the thread, NULL when it
--   pinned_by   is not pinned, and who pinned it. A captain pins "Sunday 6pm,
--               F-11, PKR 500 each" so it survives the scroll; only a channel
--               admin may pin, the same authority that may delete anyone's
--               message (routes/chat.js). ON DELETE SET NULL so the pin outlives
--               the eventual deletion of the pinner's account — the message stays
--               pinned, it simply no longer names who did it.
--
-- Purely additive and idempotent (ADD COLUMN IF NOT EXISTS): every value starts
-- NULL, no existing row is rewritten, and every current query behaves exactly as
-- before until the mention and pin endpoints write these columns.

ALTER TABLE chat_messages
  ADD COLUMN IF NOT EXISTS mentions  jsonb,
  ADD COLUMN IF NOT EXISTS pinned_at timestamptz,
  ADD COLUMN IF NOT EXISTS pinned_by uuid REFERENCES users(id) ON DELETE SET NULL;

-- The pinned-message read: "the pinned messages of this channel, newest first".
-- Partial, because only a handful of rows in a channel are ever pinned, so the
-- index stays tiny and the banner's lookup never scans the thread.
CREATE INDEX IF NOT EXISTS idx_chat_messages_pinned
  ON chat_messages (channel_id, pinned_at DESC)
  WHERE pinned_at IS NOT NULL;

COMMENT ON COLUMN chat_messages.mentions IS
  'The user ids this message @-mentions, as a jsonb array of uuid strings. '
  'Written by the client (which resolved each mention against a member picker) '
  'and filtered by the route to live channel members. Read with the message.';
COMMENT ON COLUMN chat_messages.pinned_at IS
  'When this message was pinned to the top of the thread; NULL means not pinned. '
  'Only a channel admin may set it.';
COMMENT ON COLUMN chat_messages.pinned_by IS
  'Who pinned the message, for the pinned banner. NULL once unpinned or when the '
  'pinner account is deleted.';
