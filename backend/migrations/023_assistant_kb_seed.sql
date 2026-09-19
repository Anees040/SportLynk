-- 023_assistant_kb_seed.sql — the app-wide answers Scout can give without an owner.
--
-- Why this migration exists
-- Migration 018 shipped the assistant knowledge base with exactly four global
-- rows (create a team, find opponents, how ELO works, join a tournament). That is
-- the entire set of app-wide questions Scout could answer from the KB, which is why
-- a typed question that is not a live lookup so often fell through to the capability
-- menu. This adds ~40 curated global rows across booking, cancellation, teams,
-- tournaments, ratings, venues, the wallet, notifications and the account, so the
-- common "how does X work" is answered instantly and honestly, labelled source:'kb'.
--
-- Honesty, enforced not asserted
--   • Nothing here is generated. Every answer is written by hand, so nothing is
--     invented and every sentence reflects how the app actually behaves.
--   • No money figures. Per golden rule 3, utils/escrow.js POLICY is the single
--     source of truth for refund shares, deposits and windows. These rows describe
--     the MECHANISM ("you see the exact refund before you confirm") and never a
--     number, so they can never become a second, drifting source of truth.
--   • No blocked intent. chk_assistant_kb_intent rejects wallet_balance,
--     refund_policy, cancel_booking, book_venue and topup_help; the money and
--     cancellation rows below are therefore tagged NULL, and their answers point at
--     the live screen rather than restating a rule.
--
-- Shape
-- scope='global', venue_id NULL, source='admin', status='published' — an admin seed
-- IS the approval, exactly as the four rows in 018 are. The insert is idempotent on
-- the question text (WHERE NOT EXISTS), the same shape 018 uses, so re-running this
-- migration inserts nothing the second time and the four 018 rows are never touched.
--
-- This migration is additive and insert-only. It contains no DROP, TRUNCATE, DELETE
-- or UPDATE, and writes no venue-scoped rows.

INSERT INTO assistant_kb (scope, venue_id, question, answer, source, status, intent)
SELECT 'global', NULL::uuid, v.question, v.answer, 'admin', 'published', v.intent
FROM (VALUES
  -- Scout and languages
  ('What can Scout help me with?',
   'Scout helps you find and book grounds, check what times are free, see your bookings and wallet, manage your team, find players and opponents, track your rating and enter tournaments. Ask in your own words.',
   'app_help'),
  ('Can I talk to Scout in Urdu?',
   'Yes. Scout understands English and Roman Urdu, and you can mix the two in one message — for example "football ground chahiye kal shaam".',
   'app_help'),

  -- Finding grounds
  ('How do I find a ground near me?',
   'Tell Scout the sport and area, or open Find Venues and filter by sport, area, budget or date. Results are ranked for you, closest and best-fitting first.',
   'find_venue'),
  ('Can I filter grounds by price?',
   'Yes. Give Scout a budget and it keeps results within it, or sorts the cheapest first. In Find Venues you can set the same filters by hand.',
   'find_venue'),
  ('What sports can I book grounds for?',
   'SportLynk lists grounds across the sports available in your area. Tell Scout the sport you want and it will find the grounds that match.',
   'find_venue'),
  ('How do I check whether a ground is free at a certain time?',
   'Ask Scout for the sport, area and time, or open a ground and look at its slots for that day. Free slots are the ones you can pick.',
   'check_availability'),
  ('How do I see a ground''s facilities, price and timings?',
   'Open the ground to see its facilities, price, timings and rating, or ask Scout about it by name.',
   'venue_info'),
  ('How do I get directions to a ground?',
   'Ask Scout for directions, or tap Directions on the ground to open a route in your phone''s maps app.',
   'navigate'),
  ('The ground page does not answer my question — what do I do?',
   'Ask Scout about that ground. If it is something only the owner would know, Scout forwards your question to them and sends you their answer in this chat when they reply.',
   'contact_owner'),

  -- Booking mechanics (money mechanism only, no figures)
  ('How do I book a ground?',
   'Pick a ground and an open slot in Find Venues or through Scout, then confirm. Your deposit is held in escrow and the exact amount is shown on the confirm screen before anything is charged.',
   NULL),
  ('How do I pay for a booking?',
   'Bookings are paid from your SportLynk wallet. If your balance is low, add money first. The amount due is always shown before you confirm.',
   NULL),
  ('What does "deposit held in escrow" mean?',
   'Your deposit is held safely by SportLynk rather than paid straight to the owner. It is released when the booking completes, or returned under the cancellation terms you see before you book.',
   NULL),
  ('How do I know if my booking is confirmed?',
   'A booking shows Confirmed in My Bookings once the owner accepts it, and you get a notification. Until then it shows Pending.',
   'my_bookings'),
  ('Can I book more than one slot?',
   'Yes. Book each slot separately — each booking holds its own deposit in escrow and appears on its own line in My Bookings.',
   NULL),

  -- My bookings
  ('How do I see my bookings?',
   'Open My Bookings, or ask Scout "my bookings". You will see your upcoming and past bookings with the status of each.',
   'my_bookings'),
  ('What do the booking statuses mean?',
   'Pending means the owner has not accepted yet, Confirmed means your slot is locked in, Completed means the game is done, and Cancelled means the booking was called off.',
   'my_bookings'),

  -- Cancellation and no-show (no figures)
  ('How do I cancel a booking?',
   'Open the booking in My Bookings and choose Cancel. Scout shows you the exact refund before you confirm, so you always know what you get back.',
   NULL),
  ('Will I get a refund if I cancel?',
   'That depends on how far ahead of the slot you cancel. The exact refund for your booking is shown before you confirm the cancellation — nothing is decided behind your back.',
   NULL),
  ('What happens if I do not show up for my booking?',
   'A no-show is treated as a used booking: the slot was reserved for you and kept from others. If you cannot make it, cancel ahead of time instead.',
   NULL),

  -- Wallet (no figures)
  ('How do I add money to my wallet?',
   'Open Wallet and choose Add money, then follow the top-up steps. Your available balance updates once the top-up completes.',
   NULL),
  ('How do I withdraw money from my wallet?',
   'Open Wallet and choose Withdraw. The amount goes to your registered payout method and shows as pending until it is processed.',
   NULL),
  ('Why is some of my wallet balance unavailable?',
   'Money held for an active booking sits in escrow and shows as escrowed rather than available. It is released back to you when the booking completes or is refunded.',
   NULL),
  ('Is my payment information safe?',
   'Payments run through your SportLynk wallet and booking deposits are held in escrow rather than paid straight out, so money is only released once a booking is settled.',
   NULL),

  -- Teams
  ('How do I invite players to my team?',
   'Open your team and use Invite, or accept join requests from players who apply. As captain you manage who is on the roster.',
   'create_team_help'),
  ('How do I join an existing team?',
   'Open Teams, find one that is recruiting, and send a join request. The captain approves it and you are in.',
   'find_teams'),
  ('How do I leave a team?',
   'Open the team and choose Leave. If you are the captain, hand captaincy to another member first so the team is not left without one.',
   NULL),
  ('What does the team captain do?',
   'The captain creates the team, manages the roster, books grounds, and registers the team for matches and tournaments.',
   NULL),
  ('How do I find players to fill my team?',
   'Ask Scout to find players, or open Find Players. Players are ranked by how well they fit your side.',
   'find_players'),

  -- Opponents and matches
  ('How do I challenge another team?',
   'Open your team, tap Find Opponents, pick a team near your rating, and send a challenge with a booked slot.',
   'find_opponents'),
  ('How are opponents matched to my team?',
   'SportLynk ranks nearby teams by how close their ELO rating is to yours, so you get a competitive match rather than a lopsided one.',
   'find_opponents'),
  ('How is a match result recorded?',
   'After a match the result is submitted and then verified. Only verified results move each team''s ELO rating.',
   NULL),

  -- Ratings
  ('How do I see my team''s rating?',
   'Ask Scout for your rating, or open your team to see its ELO, its rank and its recent record.',
   'team_stats'),
  ('Why did my rating go down after a loss?',
   'ELO moves rating from the losing team to the winning one. Losing to a much stronger team costs little; losing to a weaker one costs more.',
   'elo_help'),
  ('What rating does a new team start at?',
   'Every team starts at 1000 ELO and moves from there as verified match results come in.',
   'elo_help'),

  -- Tournaments
  ('How do I register my team for a tournament?',
   'Open Tournaments, pick one that is still open for registration, and register your team before the deadline. You must be the captain to register.',
   'tournament_list'),
  ('Where can I see the tournaments my team is in?',
   'Open My Tournaments, or ask Scout, to see the cups your team has entered, your fixtures and where your squad stands.',
   NULL),
  ('How do tournament fixtures work?',
   'Once a tournament fills, its fixtures are generated and you will see your matches, their times and their grounds on the tournament screen.',
   NULL),
  ('Can I enter a tournament on my own?',
   'Tournaments are team events, so you register a team rather than yourself. Create or join a team first, then register it as the captain.',
   'tournament_list'),

  -- Notifications and account
  ('How do notifications work?',
   'SportLynk notifies you about booking updates, team activity, match results and answers to questions you have asked. Tap a notification to open the screen it is about.',
   NULL),
  ('Why am I not getting notifications?',
   'Check that notifications are turned on for SportLynk in your phone settings and that you are signed in. Some updates also appear inside the app without a push.',
   NULL),
  ('How do I change my profile details?',
   'Open Profile to update your name, your sport preferences and the rest of your details.',
   NULL)
) AS v(question, answer, intent)
WHERE NOT EXISTS (
  SELECT 1 FROM assistant_kb k WHERE k.scope = 'global' AND k.question = v.question
);
