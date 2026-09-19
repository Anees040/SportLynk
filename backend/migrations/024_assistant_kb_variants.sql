-- 024_assistant_kb_variants.sql — the same answers, reachable in the words people
-- actually type: Roman Urdu, code-switch, and English synonyms.
--
-- Why this migration exists
-- Migration 023 seeded 41 global how-to answers, each in one English phrasing.
-- check_scout_coverage.js then measured how well those answers survive messy input
-- and found the honest gap: trigram matching is character-level, so a Roman-Urdu
-- question ("wallet me paise kaise add karu") shares almost no characters with its
-- English row and falls through to the menu. The intent model handles code-switch for
-- ACTIONS; the KB, which is where how-to answers live, was English-only.
--
-- The fix, without an LLM and without semantics
-- A knowledge base grows by adding rows, exactly as an owner answering a question
-- does. So each row below is a Roman-Urdu, code-switched or synonym phrasing of a
-- question 023/018 already answers, pointing at the SAME answer text. Trigram then
-- matches a Roman-Urdu query against a Roman-Urdu row, and Scout serves the answer it
-- already had. The answer stays in English because the app's surface is English; what
-- changes is that Scout now UNDERSTANDS the question however it was typed.
--
-- Same guarantees as 023
-- scope='global', source='admin', status='published'; no money figures; no blocked
-- intent (chk_assistant_kb_intent). Insert-only and idempotent on the question text,
-- so a re-run inserts nothing and the 023/018 rows are never touched. The answer text
-- is copied verbatim from the row it mirrors, so the two never disagree.

INSERT INTO assistant_kb (scope, venue_id, question, answer, source, status, intent)
SELECT 'global', NULL::uuid, v.question, v.answer, 'admin', 'published', v.intent
FROM (VALUES
  -- Scout / languages
  ('Scout aap kya kya kaam kar sakte ho?',
   'Scout helps you find and book grounds, check what times are free, see your bookings and wallet, manage your team, find players and opponents, track your rating and enter tournaments. Ask in your own words.',
   'app_help'),

  -- Finding grounds
  ('Mere paas koi ground dhundo',
   'Tell Scout the sport and area, or open Find Venues and filter by sport, area, budget or date. Results are ranked for you, closest and best-fitting first.',
   'find_venue'),
  ('Ground kaise dhundu?',
   'Tell Scout the sport and area, or open Find Venues and filter by sport, area, budget or date. Results are ranked for you, closest and best-fitting first.',
   'find_venue'),
  ('Find grounds close by',
   'Tell Scout the sport and area, or open Find Venues and filter by sport, area, budget or date. Results are ranked for you, closest and best-fitting first.',
   'find_venue'),
  ('Show me cheap grounds',
   'Yes. Give Scout a budget and it keeps results within it, or sorts the cheapest first. In Find Venues you can set the same filters by hand.',
   'find_venue'),
  ('Sasta ground chahiye',
   'Yes. Give Scout a budget and it keeps results within it, or sorts the cheapest first. In Find Venues you can set the same filters by hand.',
   'find_venue'),
  ('Ground tak kaise pahunchu?',
   'Ask Scout for directions, or tap Directions on the ground to open a route in your phone''s maps app.',
   'navigate'),

  -- Booking mechanics
  ('Ground book kaise karu?',
   'Pick a ground and an open slot in Find Venues or through Scout, then confirm. Your deposit is held in escrow and the exact amount is shown on the confirm screen before anything is charged.',
   NULL),
  ('Booking ke paise kaise dene hain?',
   'Bookings are paid from your SportLynk wallet. If your balance is low, add money first. The amount due is always shown before you confirm.',
   NULL),

  -- My bookings
  ('Meri bookings kahan hain?',
   'Open My Bookings, or ask Scout "my bookings". You will see your upcoming and past bookings with the status of each.',
   'my_bookings'),
  ('Meri saari bookings dikhao',
   'Open My Bookings, or ask Scout "my bookings". You will see your upcoming and past bookings with the status of each.',
   'my_bookings'),

  -- Cancellation
  ('Booking cancel kaise karu?',
   'Open the booking in My Bookings and choose Cancel. Scout shows you the exact refund before you confirm, so you always know what you get back.',
   NULL),
  ('Agar main cancel karu to paise wapas milenge?',
   'That depends on how far ahead of the slot you cancel. The exact refund for your booking is shown before you confirm the cancellation — nothing is decided behind your back.',
   NULL),

  -- Wallet
  ('Wallet me paise kaise add karu?',
   'Open Wallet and choose Add money, then follow the top-up steps. Your available balance updates once the top-up completes.',
   NULL),
  ('Wallet se paise kaise nikalu?',
   'Open Wallet and choose Withdraw. The amount goes to your registered payout method and shows as pending until it is processed.',
   NULL),

  -- Teams
  ('Team kaise banau?',
   'Go to Teams and tap Create Team. Pick a name, sport and city — you become the captain, and you can invite players or accept join requests from there.',
   'create_team_help'),
  ('Kisi team me kaise join karu?',
   'Open Teams, find one that is recruiting, and send a join request. The captain approves it and you are in.',
   'find_teams'),
  ('Apni team ke liye players kaise dhundu?',
   'Ask Scout to find players, or open Find Players. Players are ranked by how well they fit your side.',
   'find_players'),

  -- Opponents
  ('Kisi team ko match ke liye kaise challenge karu?',
   'Open your team, tap Find Opponents, pick a team near your rating, and send a challenge with a booked slot.',
   'find_opponents'),

  -- Ratings
  ('Rating kaise kaam karti hai?',
   'Every team starts at 1000. Winning takes rating from the team you beat, and the closer the two ratings are, the smaller the swing. Only verified match results move it.',
   'elo_help'),
  ('Meri team ki rating kya hai?',
   'Ask Scout for your rating, or open your team to see its ELO, its rank and its recent record.',
   'team_stats'),

  -- Tournaments
  ('Tournament me team kaise register karu?',
   'Open Tournaments, pick one that is still open for registration, and register your team before the deadline. You must be the captain to register.',
   'tournament_list'),
  ('Do I need a team to join a tournament?',
   'Tournaments are team events, so you register a team rather than yourself. Create or join a team first, then register it as the captain.',
   'tournament_list'),
  ('Kya main akele tournament join kar sakta hun?',
   'Tournaments are team events, so you register a team rather than yourself. Create or join a team first, then register it as the captain.',
   'tournament_list')
) AS v(question, answer, intent)
WHERE NOT EXISTS (
  SELECT 1 FROM assistant_kb k WHERE k.scope = 'global' AND k.question = v.question
);
