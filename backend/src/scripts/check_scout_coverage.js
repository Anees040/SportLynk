/**
 * check_scout_coverage.js — how well does Scout's knowledge base answer real,
 * messy questions? A measured number, no LLM, run against the live database.
 *
 * Usage:  node src/scripts/check_scout_coverage.js
 *         node src/scripts/check_scout_coverage.js --strict   (exit 1 below the bar)
 *
 * What this measures, and what it does not
 * This exercises the KNOWLEDGE layer only — assistantKb.search(), the same call the
 * dialog manager makes when the intent model abstains on a "how does X work" question.
 * It does NOT measure intent routing (that is model #4's own exam, 0.7043) or the
 * actions (that is check_assistant.js end to end). It answers one question: when a
 * user asks an app how-to in sloppy English or Roman Urdu, does Scout find the right
 * answer or fall through to the menu?
 *
 * The cases are deliberately messy — typos, missing punctuation, Roman Urdu, and
 * synonyms — because a curated question that matches its own seed proves nothing. A
 * case passes only when the matched row is the RIGHT topic (its question contains the
 * expected marker) and the similarity clears the serving floor. A wrong-topic match
 * counts as a miss, not a pass: serving the wrong answer confidently is the failure
 * this floor exists to prevent.
 */
const pool = require('../db/pool');
const kb = require('../services/assistantKb');

const STRICT = process.argv.includes('--strict');
const PASS_BAR = 0.85; // used only with --strict

/**
 * Each case: what a user might type, and a marker that identifies the correct ANSWER
 * (a distinctive lowercase fragment of the answer text). The answer, not the question,
 * is what is checked — a Roman-Urdu variant row and its English original share the
 * same answer verbatim, so "did Scout serve the right thing?" is the honest test
 * regardless of which phrasing row the matcher landed on. Grouped by topic.
 */
const CASES = [
  // Scout / languages
  { say: 'what can you help me with', want: 'find players and opponents' },
  { say: 'kya kya kaam kar sakty ho', want: 'find players and opponents' },
  { say: 'can i talk to you in urdu', want: 'english and roman urdu' },

  // Finding grounds
  { say: 'how do i find a ground nearby', want: 'closest and best-fitting' },
  { say: 'i want to find grounds close by', want: 'closest and best-fitting' },
  { say: 'ground kaise dhundu', want: 'closest and best-fitting' },
  { say: 'can i filter grounds by budget', want: 'cheapest first' },
  { say: 'show me cheap grounds', want: 'cheapest first' },
  { say: 'which sports can i book', want: 'sports available' },
  { say: 'how to check if a ground is free at 7pm', want: 'free slots are the ones' },
  { say: 'how do i see a grounds facilities and price', want: 'facilities, price, timings' },
  { say: 'how do i get directions to a ground', want: 'open a route' },
  { say: 'ground tak kaise pahunchu', want: 'open a route' },
  { say: 'the ground page doesnt answer my question', want: 'forwards your question' },

  // Booking mechanics
  { say: 'how do i book a ground', want: 'shown on the confirm screen' },
  { say: 'how to book ground', want: 'shown on the confirm screen' },
  { say: 'ground book kaise karu', want: 'shown on the confirm screen' },
  { say: 'how do i pay for a booking', want: 'paid from your sportlynk wallet' },
  { say: 'what does deposit held in escrow mean', want: 'held safely by sportlynk' },
  { say: 'how do i know my booking is confirmed', want: 'once the owner accepts' },
  { say: 'can i book more than one slot', want: 'book each slot separately' },

  // My bookings
  { say: 'how do i see my bookings', want: 'status of each' },
  { say: 'meri bookings kahan hain', want: 'status of each' },
  { say: 'what do the booking statuses mean', want: 'pending means the owner' },

  // Cancellation
  { say: 'how do i cancel a booking', want: 'exact refund before you confirm' },
  { say: 'booking cancel kaise karu', want: 'exact refund before you confirm' },
  { say: 'will i get a refund if i cancel', want: 'how far ahead of the slot' },
  { say: 'what happens if i dont show up', want: 'used booking' },

  // Wallet
  { say: 'how do i add money to my wallet', want: 'follow the top-up steps' },
  { say: 'wallet me paise kaise add karu', want: 'follow the top-up steps' },
  { say: 'how do i withdraw money', want: 'registered payout method' },
  { say: 'why is some of my balance unavailable', want: 'shows as escrowed' },
  { say: 'is my payment information safe', want: 'paid straight out' },

  // Teams
  { say: 'how do i invite players to my team', want: 'accept join requests' },
  { say: 'how do i join a team', want: 'the captain approves it' },
  { say: 'team kaise join karu', want: 'the captain approves it' },
  { say: 'how do i leave a team', want: 'hand captaincy' },
  { say: 'what does the captain do', want: 'manages the roster' },
  { say: 'how do i find players for my team', want: 'fit your side' },

  // Opponents & matches
  { say: 'how do i challenge another team', want: 'challenge with a booked slot' },
  { say: 'how are opponents matched', want: 'how close their elo' },
  { say: 'how is a match result recorded', want: 'verified results move' },

  // Ratings
  { say: 'how do i see my teams rating', want: 'rank and its recent record' },
  { say: 'why did my rating drop after losing', want: 'losing team to the winning' },
  { say: 'what rating does a new team start at', want: '1000' },
  { say: 'how does elo work', want: '1000' },

  // Tournaments
  { say: 'how do i register my team for a tournament', want: 'before the deadline' },
  { say: 'tournament me team kaise register karu', want: 'before the deadline' },
  { say: 'where can i see my tournaments', want: 'cups your team has entered' },
  { say: 'how do tournament fixtures work', want: 'fixtures are generated' },
  { say: 'do i need a team to enter a tournament', want: 'team events' },
  { say: 'kya akele tournament join kar sakta hun', want: 'team events' },
  { say: 'how do i join a tournament', want: 'registration' },

  // Notifications & account
  { say: 'how do notifications work', want: 'booking updates' },
  { say: 'why am i not getting notifications', want: 'phone settings' },
  { say: 'how do i change my profile', want: 'sport preferences' },
];

async function main() {
  const trgm = await kb.hasTrgm(pool);
  const results = { right: 0, wrong: [], none: [] };

  for (const c of CASES) {
    // eslint-disable-next-line no-await-in-loop
    const hit = await kb.search(pool, { question: c.say });
    if (!hit.hit || !hit.row) {
      results.none.push(c);
      continue;
    }
    const answer = String(hit.row.answer).toLowerCase();
    if (answer.includes(c.want.toLowerCase())) {
      results.right += 1;
    } else {
      results.wrong.push({ ...c, got: hit.row.question, sim: Number(hit.similarity) });
    }
  }

  const n = CASES.length;
  const pct = ((results.right / n) * 100).toFixed(1);

  console.log('Scout knowledge-base coverage');
  console.log(`Matcher: ${trgm ? 'trigram' : 'token overlap'}  ·  floor: ${kb.MIN_SIMILARITY}\n`);
  console.log(`Correct topic: ${results.right}/${n}  (${pct}%)`);
  console.log(`Wrong topic:   ${results.wrong.length}`);
  console.log(`No match:      ${results.none.length}\n`);

  if (results.wrong.length) {
    console.log('Reached the WRONG topic:');
    for (const w of results.wrong) {
      console.log(`  "${w.say}"  ->  "${w.got}"  (sim ${w.sim.toFixed(3)}; wanted ~"${w.want}")`);
    }
    console.log('');
  }
  if (results.none.length) {
    console.log('Fell through to the menu (no match at all):');
    for (const m of results.none) console.log(`  "${m.say}"  (wanted ~"${m.want}")`);
    console.log('');
  }

  if (STRICT && results.right / n < PASS_BAR) {
    console.error(`FAILED --strict: ${pct}% is under the ${PASS_BAR * 100}% bar.`);
    process.exitCode = 1;
  } else {
    console.log(results.right === n
      ? 'Every question reached its answer.'
      : 'Baseline recorded. Gaps above are candidates for variant phrasings.');
  }
}

main()
  .catch((err) => { console.error('Coverage check crashed:', err.message); process.exitCode = 1; })
  .finally(() => pool.end());
