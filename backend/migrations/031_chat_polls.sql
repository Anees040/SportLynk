-- ════════════════════════════════════════════════════════════════════════════
-- 031_chat_polls.sql   ·   in-chat polls (WhatsApp-style)
-- ════════════════════════════════════════════════════════════════════════════
--
-- A poll is a message of its own kind: the question lives in chat_messages.body
-- (so the inbox preview and every existing message read render it unchanged),
-- while the options and the votes live in the two tables below. Keeping the poll
-- anchored to a real message row means it sits in the timeline, counts toward the
-- channel's last-activity, and is deleted-for-everyone by the same path as any
-- other message (ON DELETE CASCADE from chat_messages).
--
-- 'poll' is a NEW value on chk_chat_messages_kind, added the way 015 and 018 add
-- a kind: DROP the constraint and restate the whole enumeration. The payload rule
-- is restated too — a poll, like a text or an assistant row, must carry a body.
--
-- Purely additive: two new tables, two indexes, and two widened CHECK
-- constraints. No column is dropped and no row is rewritten; a poll simply cannot
-- be stored until the app writes one.

ALTER TABLE chat_messages DROP CONSTRAINT IF EXISTS chk_chat_messages_kind;
ALTER TABLE chat_messages
  ADD CONSTRAINT chk_chat_messages_kind
  CHECK (kind IN ('text', 'image', 'audio', 'system', 'assistant', 'poll'));

ALTER TABLE chat_messages DROP CONSTRAINT IF EXISTS chk_chat_messages_payload;
ALTER TABLE chat_messages
  ADD CONSTRAINT chk_chat_messages_payload
  CHECK (
    deleted_at IS NOT NULL
    OR (kind = 'text'      AND body IS NOT NULL AND btrim(body) <> '')
    OR (kind = 'assistant' AND body IS NOT NULL AND btrim(body) <> '')
    OR (kind = 'system'    AND body IS NOT NULL)
    OR (kind = 'poll'      AND body IS NOT NULL AND btrim(body) <> '')
    OR (kind IN ('image', 'audio') AND media_url IS NOT NULL)
  );

-- One row per poll, bound to the message that announces it. `options` is a jsonb
-- array of option labels (the ballot never changes once posted, so it is stored
-- with the poll rather than in a child table). `allow_multiple` decides whether a
-- voter may pick more than one option; `closed_at` freezes the tally.
CREATE TABLE IF NOT EXISTS chat_polls (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id     UUID NOT NULL REFERENCES chat_channels(id) ON DELETE CASCADE,
  message_id     UUID NOT NULL UNIQUE REFERENCES chat_messages(id) ON DELETE CASCADE,
  created_by     UUID REFERENCES users(id) ON DELETE SET NULL,
  question       text NOT NULL,
  options        jsonb NOT NULL,              -- array of option label strings
  allow_multiple boolean NOT NULL DEFAULT false,
  closed_at      timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now()
);

-- One row per (poll, voter, option). The unique key blocks a double vote for the
-- same option; a single-choice poll is enforced in the service by clearing a
-- voter's other options before recording the new one. Votes are named — the
-- voter's id is kept so "who voted for what" can be shown, WhatsApp-style.
CREATE TABLE IF NOT EXISTS chat_poll_votes (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  poll_id      UUID NOT NULL REFERENCES chat_polls(id) ON DELETE CASCADE,
  option_index integer NOT NULL,
  user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (poll_id, user_id, option_index)
);

CREATE INDEX IF NOT EXISTS idx_chat_polls_message ON chat_polls (message_id);
CREATE INDEX IF NOT EXISTS idx_chat_poll_votes_poll ON chat_poll_votes (poll_id);

COMMENT ON TABLE chat_polls IS
  'In-chat polls. The question is the anchoring chat_messages.body (kind=poll); '
  'options is a jsonb array of labels; votes live in chat_poll_votes.';
