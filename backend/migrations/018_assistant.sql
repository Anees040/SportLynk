-- ════════════════════════════════════════════════════════════════════════════
-- 018 — SCOUT: the SportLynk assistant's persistence layer  (S.6 Wave C)
-- ════════════════════════════════════════════════════════════════════════════
--
-- Model #4 (the intent classifier + rule entity extractor) has been trained,
-- gated and served at POST /nlu/parse since Wave B, and NOTHING called it: the
-- classifier answered `{intent, confidence, entities}` into the void. This
-- migration is what the Node dialog manager needs in order to hold a
-- conversation across turns and then actually DO the thing.
--
-- Five concerns, five sections. Read the "why" on each: three of them are the
-- difference between an assistant and a search box with a chat skin.
--
--   1. SESSION STATE — a slot-filling machine is a state machine, and its state
--      has to survive the request. Two turns ("book a football ground" then
--      "tomorrow 6pm") only compose if turn 1's slots are still there in turn 2.
--
--   2. ASSISTANT MESSAGES — Scout's replies are not text. They are text PLUS
--      cards and buttons, because a chat that can only answer in prose is a
--      dead end the moment the user has to pick one of three venues. The cards
--      are stored with the message so scrolling back up re-renders the real
--      thing instead of an orphaned sentence.
--
--   3. THE KNOWLEDGE BASE — the learning loop. Scout cannot know that ground
--      G-11 has floodlights until someone tells it. When it does not know, it
--      asks the OWNER, and the owner's reply is stored HERE, published for that
--      venue, and served to the next player who asks. The second player gets an
--      instant answer to a question the first player had to wait for. That is
--      the whole mechanism, and it needs no retrain to work.
--
--   4. ESCALATIONS — the queue in front of (3). A question Scout could not
--      answer becomes a row an owner can see, answer, or decline. Without a
--      durable row this is a fire-and-forget notification: the owner closes the
--      app, the question is gone, and the player is still waiting.
--
--   5. TURN TELEMETRY + FEEDBACK — evidence. `assistant_turns` records what the
--      classifier decided on every real production turn and DELIBERATELY DOES
--      NOT STORE THE TEXT (doc/claude.md: the utterance is never logged). So the
--      abstention rate, the intent mix and the action success rate are all
--      measurable from live traffic without building a transcript archive.
--      `assistant_feedback` is the thumbs-up/down — the only signal in the whole
--      system that says an answer was WRONG rather than merely low-confidence.
--
-- ── Deviations from the wave spec, and why ──────────────────────────────────
--
--   a. The spec says session state lives in "chat_channels type='assistant' + a
--      session_state jsonb". Done exactly, with one addition: `archived_at` and
--      `title`, because the same table now has to serve "new chat / switch chat
--      / rename chat", and a thread list needs a name and a way to disappear.
--      `title` already exists (015, denormalised from the team) and is reused.
--
--   b. chat_messages gets ONE new column (`assistant_payload jsonb`), not five.
--      Cards, chips, source, intent and confidence all travel inside it. A
--      column per concept would be five migrations the first time the card
--      vocabulary grows.
--
--   c. `kind = 'assistant'` is a NEW value on chk_chat_messages_kind rather than
--      a reuse of 'system'. A system row is an EVENT ("Ali left"); an assistant
--      row is a participant's message with a NULL sender_id. Rendering, unread
--      counting and the reply-to target all differ, and 015's own comment says
--      system_meta exists so the client can render an event — not a reply.
--
--   d. pg_trgm is requested but NOT required. Similarity search is how a KB
--      lookup tolerates "does g11 have lights" against a stored "Does G-11
--      ground have floodlights?". If the extension cannot be created (a locked-
--      down database), the migration still succeeds and assistantKb.js falls
--      back to a token-overlap query — measurably worse, never broken.
--
--   e. The refund policy TEXT is seeded into global_settings as the wave spec
--      asks, but as a TEMPLATE with {deposit_pct} / {window_hours} placeholders
--      filled from utils/escrow.js POLICY at render time. A frozen English
--      sentence saying "20%" is a second source of truth for a number that
--      decides money, and it would go stale silently the day POLICY changes.
--
-- Safe to re-run: every statement is idempotent.
-- ════════════════════════════════════════════════════════════════════════════


-- ════════════════════════════════════════════════════════════════════════════
-- 1. SESSION STATE — the slot-filling machine's memory
-- ════════════════════════════════════════════════════════════════════════════
--
-- One assistant channel = one conversation thread = one state machine. jsonb,
-- not columns, because the shape is genuinely open: what `book_venue` is holding
-- mid-flow (sport, date, time, area, a chosen slot, a pending confirmation) has
-- almost nothing in common with what `cancel_booking` is holding, and a column
-- per slot would be a schema change every time the dialog gains an action.
--
-- Its contract is owned by services/dialogManager.js (STATE_VERSION), which
-- validates on read and resets a state it does not recognise rather than
-- crashing on a thread that was mid-flow when the server was redeployed.
ALTER TABLE chat_channels
  ADD COLUMN IF NOT EXISTS session_state      jsonb NOT NULL DEFAULT '{}'::jsonb,
  -- Soft delete. "Delete chat" hides the thread; the messages stay for the
  -- assistant's evidence pass, and an accidental swipe is recoverable.
  ADD COLUMN IF NOT EXISTS archived_at        timestamptz,
  -- 'player' or 'owner'. The SAME dialog manager serves both, with a different
  -- action table and a different capability menu — an owner asking "kal ki
  -- bookings" means their venue's bookings, not their own.
  ADD COLUMN IF NOT EXISTS assistant_persona  text;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_chat_channels_persona') THEN
    ALTER TABLE chat_channels
      ADD CONSTRAINT chk_chat_channels_persona
      CHECK (assistant_persona IS NULL
             OR (type = 'assistant' AND assistant_persona IN ('player', 'owner')));
  END IF;
END $$;

-- The thread list. created_by IS the owning user for an assistant channel (a
-- team channel is created by whoever made the team), so this one partial index
-- answers "my Scout threads, newest first" without touching the members table.
CREATE INDEX IF NOT EXISTS idx_chat_channels_assistant
  ON chat_channels (created_by, last_message_at DESC NULLS LAST)
  WHERE type = 'assistant' AND archived_at IS NULL;


-- ════════════════════════════════════════════════════════════════════════════
-- 2. ASSISTANT MESSAGES — replies that carry cards and buttons
-- ════════════════════════════════════════════════════════════════════════════
--
-- The payload the client renders:
--
--   {
--     "source":     "live" | "policy" | "model" | "kb" | "menu" | "escalated",
--     "intent":     "book_venue",          -- what the classifier decided
--     "confidence": 0.87,                  -- and how sure it was
--     "abstained":  false,
--     "chips":      [{"label":"Tomorrow 6pm", "action":"set_slot",
--                     "args":{"date":"2026-08-29","time":"18:00"}}],
--     "cards":      [{"type":"venue", "data":{...}}]
--   }
--
-- `source` is the honesty field, and it is on EVERY reply. A committee demo of
-- an AI assistant lives or dies on whether the panel believes the answer came
-- from somewhere real, so each bubble can say so out loud: "live data" (computed
-- from Postgres on this request), "policy" (the rules text, not a guess),
-- "model" (a trained ranker chose this order), "venue owner answered" (a human
-- said it once and Scout remembered), "menu" (Scout does not know and is saying
-- so), "sent to the owner" (nobody knows yet, someone was asked). It is one
-- string and it is the difference between a demo and a black box.
--
-- `chips` are the second addressing mode for actions, and the reason Scout can
-- do things the classifier was never trained to recognise. A chip press posts
-- {action, args} — no text, no classification, no confidence threshold. So
-- "Suggest players" and "Directions" are fully operational buttons even though
-- assistant-intents-v1 has no find_players and no navigate label. Free text
-- reaches the 15 trained intents; chips reach every action. Turning either into
-- a first-class INTENT is an intents-v2 retrain, not an edit here.
ALTER TABLE chat_messages
  ADD COLUMN IF NOT EXISTS assistant_payload jsonb;

-- 015 wrote this constraint as DROP-then-ADD for exactly this reason: a new
-- `kind` cannot be added without restating the whole enumeration.
ALTER TABLE chat_messages DROP CONSTRAINT IF EXISTS chk_chat_messages_kind;
ALTER TABLE chat_messages
  ADD CONSTRAINT chk_chat_messages_kind
  CHECK (kind IN ('text', 'image', 'audio', 'system', 'assistant'));

-- And the payload rule, restated with the new kind. An assistant row must have
-- a body: a card-only reply with no sentence is precisely the dead end the wave
-- spec forbids, so the database refuses to store one.
ALTER TABLE chat_messages DROP CONSTRAINT IF EXISTS chk_chat_messages_payload;
ALTER TABLE chat_messages
  ADD CONSTRAINT chk_chat_messages_payload
  CHECK (
    deleted_at IS NOT NULL
    OR (kind = 'text'      AND body IS NOT NULL AND btrim(body) <> '')
    OR (kind = 'assistant' AND body IS NOT NULL AND btrim(body) <> '')
    OR (kind = 'system'    AND body IS NOT NULL)
    OR (kind IN ('image', 'audio') AND media_url IS NOT NULL)
  );

-- Scout's messages have sender_id IS NULL (015 made sender_id nullable for
-- system rows). This index is what makes "show me only what Scout said in this
-- thread" cheap — used by the evidence pass and by feedback lookups.
CREATE INDEX IF NOT EXISTS idx_chat_messages_assistant
  ON chat_messages (channel_id, created_at DESC)
  WHERE kind = 'assistant';


-- ════════════════════════════════════════════════════════════════════════════
-- 3. THE KNOWLEDGE BASE — what Scout learns from humans
-- ════════════════════════════════════════════════════════════════════════════
--
-- Requested, but never at the cost of the two rules in doc/claude.md: a learning
-- loop must be OWNER-APPROVED and PER-VENUE ISOLATED, and it must never answer a
-- money or policy question. Both are enforced structurally, not by convention:
--
--   • status='published' is the approval gate. An escalated question arrives as
--     a 'draft' row and is invisible to search until an owner answers it. There
--     is no code path that publishes a row Scout wrote by itself.
--   • venue_id scopes the answer. "Yes, we have floodlights" is true of ONE
--     ground. Serving it for another venue would be Scout inventing a fact, so
--     search filters on venue_id and a venue-scoped row can never leak across.
--   • CHECK chk_assistant_kb_scope blocks the money/policy intents at the
--     DATABASE. wallet_balance, refund_policy, cancel_booking, book_venue and
--     topup_help can never be a KB-answered intent, no matter what any future
--     route does, because those answers must always be computed or quoted from
--     policy — never remembered from something a human once typed.
-- Requested, never required. On a managed database this can fail two ways: the
-- role may not be allowed to create extensions at all, and even when pg_trgm IS
-- installed it often lives in a separate `extensions` schema, so `gin_trgm_ops`
-- does not resolve unless that schema is on the search_path. Either failure would
-- abort this whole migration (it applies as one implicit transaction), so both are
-- caught here and reported as a NOTICE. assistantKb.js then degrades to token
-- overlap: measurably worse retrieval, never a broken migration.
DO $trgm$
BEGIN
  EXECUTE 'CREATE EXTENSION IF NOT EXISTS pg_trgm';
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE '018: could not create pg_trgm (%) — KB search will use token overlap', SQLERRM;
END $trgm$;

CREATE TABLE IF NOT EXISTS assistant_kb (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  -- 'venue'  → about one ground; only served when the user is asking about it.
  -- 'global' → app-wide how-to, seeded below or written by an admin.
  scope          text NOT NULL DEFAULT 'venue',
  venue_id       uuid REFERENCES venues(id) ON DELETE CASCADE,
  owner_id       uuid REFERENCES users(id)  ON DELETE SET NULL,

  question       text NOT NULL,
  -- Normalised for matching: lowercased, punctuation squashed to single spaces.
  -- GENERATED so it can never drift from `question`, and so a trigram index can
  -- sit on a column instead of on an expression that every query must repeat
  -- byte-identically to be used.
  question_norm  text GENERATED ALWAYS AS (
                   btrim(regexp_replace(lower(question), '[^[:alnum:]]+', ' ', 'g'))
                 ) STORED,
  answer         text NOT NULL,

  -- 'owner'  → a venue owner answered an escalation. The trusted case.
  -- 'admin'  → seeded or curated centrally.
  -- 'derived'→ reserved: a future summariser. NOT served until reviewed, which
  --            is why it starts life as a draft like everything else.
  source         text NOT NULL DEFAULT 'owner',
  status         text NOT NULL DEFAULT 'draft',
  -- The classifier label this answer belongs to, when there was one. Lets search
  -- prefer a KB row that matches the intent Scout already inferred.
  intent         text,
  lang           text NOT NULL DEFAULT 'auto',

  -- Evidence, and the input to "which questions should the owner answer next".
  asked_count    int NOT NULL DEFAULT 0,
  served_count   int NOT NULL DEFAULT 0,
  last_served_at timestamptz,

  created_by     uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at     timestamptz NOT NULL DEFAULT NOW(),
  updated_at     timestamptz NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_assistant_kb_scope_val  CHECK (scope  IN ('venue', 'global')),
  CONSTRAINT chk_assistant_kb_source     CHECK (source IN ('owner', 'admin', 'derived')),
  CONSTRAINT chk_assistant_kb_status     CHECK (status IN ('draft', 'published', 'rejected', 'archived')),
  -- A venue-scoped row without a venue is a fact about nothing; a global row
  -- with one is a venue fact escaping its scope. Both are corruption, not input.
  CONSTRAINT chk_assistant_kb_venue      CHECK (
    (scope = 'venue'  AND venue_id IS NOT NULL) OR
    (scope = 'global' AND venue_id IS NULL)
  ),
  CONSTRAINT chk_assistant_kb_nonempty   CHECK (btrim(question) <> '' AND btrim(answer) <> ''),
  -- The money-and-policy firewall. See the block comment above.
  CONSTRAINT chk_assistant_kb_intent     CHECK (
    intent IS NULL OR intent NOT IN (
      'wallet_balance', 'refund_policy', 'cancel_booking', 'book_venue', 'topup_help'
    )
  )
);

-- The serving index: published rows for one venue (or global), newest first.
CREATE INDEX IF NOT EXISTS idx_assistant_kb_serve
  ON assistant_kb (scope, venue_id, status);
CREATE INDEX IF NOT EXISTS idx_assistant_kb_owner
  ON assistant_kb (owner_id, status, updated_at DESC);
-- Fuzzy match. GIN + gin_trgm_ops is what makes `question_norm % $1` and
-- `similarity(question_norm, $1) > 0.3` fast instead of a full scan per turn.
-- Wrapped in a DO block because CREATE EXTENSION above may have been refused on
-- a managed database with a restricted extension allow-list: assistantKb.js
-- degrades to token overlap and the migration must NOT fail over a nice-to-have.
DO $trgmidx$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm') THEN
    BEGIN
      EXECUTE 'CREATE INDEX IF NOT EXISTS idx_assistant_kb_trgm '
           || 'ON assistant_kb USING gin (question_norm gin_trgm_ops)';
    EXCEPTION WHEN OTHERS THEN
      -- Almost always "operator class gin_trgm_ops does not exist": the extension
      -- is installed in a schema this role's search_path does not include.
      RAISE NOTICE '018: pg_trgm present but the index could not be built (%) — token overlap it is', SQLERRM;
    END;
  ELSE
    RAISE NOTICE '018: pg_trgm unavailable — KB search will use token overlap (slower, still correct)';
  END IF;
END $trgmidx$;


-- ════════════════════════════════════════════════════════════════════════════
-- 4. ESCALATIONS — the queue that turns "I don't know" into an answer
-- ════════════════════════════════════════════════════════════════════════════
--
-- Life of a row: a player asks something Scout cannot answer about a specific
-- venue → status='open' and the owner is notified → owner answers (→ a published
-- assistant_kb row + the answer is posted back into the player's own Scout
-- thread + the player is notified) or declines → 'answered' / 'declined'.
--
-- channel_id and message_id are how the answer finds its way home. Without them
-- an owner's reply has nowhere to go: the player asked three hours ago and is not
-- holding an HTTP request open. This is the one place the assistant is genuinely
-- asynchronous, and it is why the queue is a table and not a notification.
CREATE TABLE IF NOT EXISTS assistant_escalations (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  channel_id   uuid REFERENCES chat_channels(id) ON DELETE SET NULL,
  message_id   uuid REFERENCES chat_messages(id) ON DELETE SET NULL,

  venue_id     uuid REFERENCES venues(id) ON DELETE CASCADE,
  owner_id     uuid REFERENCES users(id)  ON DELETE SET NULL,

  question     text NOT NULL,
  -- What the classifier thought, for the record. An escalation is BY DEFINITION
  -- a turn the model got wrong or abstained on, so these two columns are the
  -- highest-value training signal in the system for intents-v2.
  intent       text,
  confidence   numeric(5, 4),

  status       text NOT NULL DEFAULT 'open',
  answer       text,
  kb_id        uuid REFERENCES assistant_kb(id) ON DELETE SET NULL,
  answered_by  uuid REFERENCES users(id) ON DELETE SET NULL,
  answered_at  timestamptz,

  created_at   timestamptz NOT NULL DEFAULT NOW(),
  updated_at   timestamptz NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_assistant_esc_status CHECK (status IN ('open', 'answered', 'declined', 'expired')),
  CONSTRAINT chk_assistant_esc_q      CHECK (btrim(question) <> ''),
  -- 'answered' with no answer is a lie the owner queue would show as resolved.
  CONSTRAINT chk_assistant_esc_answer CHECK (
    status <> 'answered' OR (answer IS NOT NULL AND btrim(answer) <> '')
  )
);

-- The owner's inbox: "my open questions, oldest first" — oldest first because a
-- question that has been waiting longest is the one costing a player the most.
CREATE INDEX IF NOT EXISTS idx_assistant_esc_owner
  ON assistant_escalations (owner_id, status, created_at);
CREATE INDEX IF NOT EXISTS idx_assistant_esc_user
  ON assistant_escalations (user_id, created_at DESC);
-- Dedup probe: don't re-ask an owner the same thing that is already open.
CREATE INDEX IF NOT EXISTS idx_assistant_esc_open_venue
  ON assistant_escalations (venue_id, status)
  WHERE status = 'open';


-- ════════════════════════════════════════════════════════════════════════════
-- 5. TURN TELEMETRY (text-free) + FEEDBACK
-- ════════════════════════════════════════════════════════════════════════════
--
-- ⚠ THE UTTERANCE IS NOT STORED HERE, AND MUST NEVER BE ADDED. ⚠
--
-- doc/claude.md's standing rule is that the assistant utterance is never logged —
-- only intent, confidence, chars and session id. That rule is about LOGS AND
-- TELEMETRY, and this table is telemetry, so it holds `text_chars` and not
-- `text`. Anyone tempted to add a `text` column for "better analytics" is
-- building a transcript archive out of a metrics table: the message text already
-- exists exactly once, in chat_messages, inside the user's own access-controlled
-- thread, because chat history is a feature the user asked for. One copy, one
-- access rule. Two copies is a leak with a schema.
--
-- What this buys, from live traffic, with no annotation effort: the real
-- abstention rate (vs the 0.45 threshold's exam-set estimate), the production
-- intent mix (vs the corpus's designed mix), p50/p95 latency split between the
-- classifier and the action, and the action failure rate.
CREATE TABLE IF NOT EXISTS assistant_turns (
  id             bigserial PRIMARY KEY,

  user_id        uuid REFERENCES users(id) ON DELETE SET NULL,
  channel_id     uuid REFERENCES chat_channels(id) ON DELETE SET NULL,

  -- 'text' → free text went to the classifier. 'chip' → a button was pressed and
  -- no classification happened at all. Splitting them keeps chip traffic out of
  -- the model's measured accuracy, where it would flatter it enormously.
  input_mode     text NOT NULL DEFAULT 'text',
  text_chars     int,                         -- length only. Never the text.

  intent         text,
  confidence     numeric(5, 4),
  abstained      boolean NOT NULL DEFAULT false,
  abstain_reason text,                        -- low_confidence | no_evidence | no_known_terms
  model_version  text,

  -- What the dialog manager DID with it, which is the part accuracy cannot show:
  -- a correctly classified intent that then failed to execute is still a failed
  -- turn for the user.
  action         text,
  action_ok      boolean,
  answer_source  text,                        -- live|policy|model|kb|menu|escalated
  fsm_state      text,                        -- idle|slot_filling|awaiting_choice|awaiting_confirm

  nlu_ms         int,
  total_ms       int,
  created_at     timestamptz NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_assistant_turns_mode CHECK (input_mode IN ('text', 'chip')),
  CONSTRAINT chk_assistant_turns_src  CHECK (
    answer_source IS NULL OR answer_source IN ('live','policy','model','kb','menu','escalated')
  )
);

CREATE INDEX IF NOT EXISTS idx_assistant_turns_time   ON assistant_turns (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_assistant_turns_intent ON assistant_turns (intent, created_at DESC);
-- Serves the headline evidence number: abstention rate over a window.
CREATE INDEX IF NOT EXISTS idx_assistant_turns_abstain
  ON assistant_turns (abstained, created_at DESC)
  WHERE input_mode = 'text';

-- ── Feedback ────────────────────────────────────────────────────────────────
-- The only signal that distinguishes "confidently wrong" from "correct". The
-- classifier's own confidence cannot: a 0.93 misclassification looks identical
-- to a 0.93 hit from the inside. UNIQUE (message_id, user_id) makes a vote
-- changeable and un-stuffable.
CREATE TABLE IF NOT EXISTS assistant_feedback (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id uuid NOT NULL REFERENCES chat_messages(id) ON DELETE CASCADE,
  user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  vote       smallint NOT NULL,
  reason     text,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  CONSTRAINT chk_assistant_feedback_vote CHECK (vote IN (-1, 1)),
  CONSTRAINT ux_assistant_feedback UNIQUE (message_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_assistant_feedback_msg ON assistant_feedback (message_id);


-- ════════════════════════════════════════════════════════════════════════════
-- 6. SEEDS — the policy answers Scout is allowed to quote
-- ════════════════════════════════════════════════════════════════════════════
--
-- The wave spec asks for "canned policy text from global_settings", and here it
-- is — as TEMPLATES, not sentences. Every number is a {placeholder} filled at
-- render time from utils/escrow.js POLICY, which per golden rule 3 is the source
-- of truth for money. Migration 013's own header says global_settings must never
-- silently become authoritative, and a hard-coded "20%" in an answer Scout reads
-- aloud is exactly that: a second copy of a money rule that goes stale in
-- silence the day POLICY changes. Templates cannot go stale — a wrong number
-- would have to be a wrong POLICY, which is one place and already reviewed.
--
-- Placeholders (utils/policyText.js is the only renderer):
--   {deposit_pct} {refund_pct} {window_hours} {no_show_grace} {withdrawal_min}
--   {trust_penalty} {auto_decide}
INSERT INTO global_settings (key, value) VALUES (
  'assistant',
  jsonb_build_object(
    'name', 'Scout',
    'confidence_floor', 0.45,
    'escalation_enabled', true,
    'policy_text', jsonb_build_object(
      'refund_policy',
        'Cancel {window_hours}h or more before your slot starts and you get a full refund. ' ||
        'Cancel later than that and {refund_pct}% comes back to your wallet — the {deposit_pct}% ' ||
        'deposit goes to the venue owner for holding the ground.',
      'deposit',
        'When you book, the full slot price is held in escrow from your wallet. ' ||
        '{deposit_pct}% of it is your at-risk deposit; the rest is released back to you ' ||
        'if the booking is rejected or cancelled in time.',
      'no_show',
        'If you do not check in within {no_show_grace} minutes of your slot starting, the booking ' ||
        'is marked a no-show: {refund_pct}% returns to your wallet, the venue keeps the ' ||
        '{deposit_pct}% deposit, and your trust score drops by {trust_penalty} points.',
      'checkin',
        'Show the QR code on your booking at the ground. Scanning it releases the escrow to the ' ||
        'venue owner and marks you checked in.',
      'approval',
        'A new booking starts as pending until the venue owner approves it. If nobody responds ' ||
        'within {auto_decide}, it is decided automatically so your money is never stuck.',
      'topup',
        'Open Wallet and tap Top Up. Payments are simulated in this build, so a top-up credits ' ||
        'your wallet immediately.',
      'withdrawal',
        'You can withdraw any unfrozen balance above PKR {withdrawal_min} from the Wallet screen. ' ||
        'Money held in escrow for an active booking cannot be withdrawn until that booking closes.'
    )
  )
) ON CONFLICT (key) DO NOTHING;

-- App-wide how-to rows. scope='global', source='admin', published immediately:
-- these are not learned facts, they are documentation, and an admin seed IS the
-- approval. Nothing here answers a money question — the intent firewall on
-- assistant_kb would reject the row if it tried.
INSERT INTO assistant_kb (scope, venue_id, question, answer, source, status, intent)
SELECT v.scope, NULL::uuid, v.question, v.answer, 'admin', 'published', v.intent
FROM (VALUES
  ('global', 'How do I create a team?',
   'Go to Teams and tap Create Team. Pick a name, sport and city — you become the captain, and you can invite players or accept join requests from there.',
   'create_team_help'),
  ('global', 'How do I find opponents for a match?',
   'Open your team and tap Find Opponents. SportLynk ranks nearby teams by ELO closeness so you get a fair match, then you send a challenge with a booked slot.',
   'find_opponents'),
  ('global', 'How does ELO rating work?',
   'Every team starts at 1000. Winning takes rating from the team you beat, and the closer the two ratings are, the smaller the swing. Only verified match results move it.',
   'team_stats'),
  ('global', 'How do I join a tournament?',
   'Open Tournaments, pick one that is still open for registration, and register your team before the deadline. You need to be the captain to register.',
   'tournament_list')
) AS v(scope, question, answer, intent)
WHERE NOT EXISTS (
  SELECT 1 FROM assistant_kb k WHERE k.scope = 'global' AND k.question = v.question
);
