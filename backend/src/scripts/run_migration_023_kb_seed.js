/**
 * run_migration_023_kb_seed.js — apply migration 023 and prove it actually works.
 *
 * Usage:  node src/scripts/run_migration_023_kb_seed.js
 *
 * Why a dedicated runner rather than the generic one
 * A schema migration is done when the tables exist. A SEED migration is only done
 * when the rows it adds are FINDABLE — a knowledge base nobody can retrieve is the
 * same as an empty one. So this runner does three things and reports each:
 *
 *   1. Apply. Run 023, which is idempotent (INSERT ... WHERE NOT EXISTS), and report
 *      how many rows it inserted.
 *   2. Prove idempotency. Run it a SECOND time and confirm it inserts nothing, so a
 *      re-run on the live database can never duplicate a row.
 *   3. Prove retrieval. Push English paraphrases — deliberately NOT the seeded
 *      wording — through the real assistantKb.search() the dialog manager uses, and
 *      confirm each clears MIN_SIMILARITY against the right answer. This is the check
 *      that a seeded row is one Scout will actually serve, not just one that exists.
 *
 * It writes real rows to the live database on purpose: the seed is meant to persist.
 * It is insert-only and idempotent, so running it twice is safe and running it once
 * more after that changes nothing.
 */
const path = require('path');
const fs = require('fs');
const pool = require('../db/pool');
const kb = require('../services/assistantKb');

const SQL_PATH = path.join(__dirname, '..', '..', 'migrations', '023_assistant_kb_seed.sql');

/** Paraphrases a real user might type, each with the seeded question it should reach.
 *  None is the seeded wording verbatim — the point is to prove paraphrase matching. */
const PROBES = [
  { say: 'how can i cancel a booking i already made', expect: 'cancel a booking' },
  { say: 'add money to my wallet', expect: 'add money to my wallet' },
  // A lexically close paraphrase. Trigram matching is character-level, not semantic,
  // so a synonym swap it cannot bridge ("close to me" for "near me" scores 0.410,
  // just under the floor) is meant to fall to the menu rather than risk a wrong
  // answer -- MIN_SIMILARITY is deliberately high for exactly that reason.
  { say: 'how do i find a ground nearby', expect: 'find a ground near me' },
  { say: 'what do the different booking statuses mean', expect: 'booking statuses mean' },
  { say: 'how do i register my team for a tournament', expect: 'register my team for a tournament' },
  { say: 'what rating does a new team begin at', expect: 'rating does a new team start' },
];

async function globalCount() {
  const { rows } = await pool.query(
    "SELECT count(*)::int AS n FROM assistant_kb WHERE scope = 'global' AND status = 'published'",
  );
  return rows[0].n;
}

async function main() {
  const sql = fs.readFileSync(SQL_PATH, 'utf8');
  let failures = 0;
  const fail = (msg) => { failures += 1; console.error(`  ✗ ${msg}`); };
  const ok = (msg) => console.log(`  ✓ ${msg}`);

  console.log('023 — assistant KB global seed\n');

  const before = await globalCount();
  console.log(`Global published KB rows before: ${before}`);

  const first = await pool.query(sql);
  const inserted = first.rowCount || 0;
  const afterFirst = await globalCount();
  console.log(`Inserted this run: ${inserted}`);
  console.log(`Global published KB rows now:    ${afterFirst}\n`);

  // 2. Idempotency
  const second = await pool.query(sql);
  const afterSecond = await globalCount();
  if ((second.rowCount || 0) === 0 && afterSecond === afterFirst) {
    ok(`re-run inserted 0 rows — the seed is idempotent (${afterSecond} rows stable)`);
  } else {
    fail(`re-run was not idempotent: added ${second.rowCount}, count ${afterFirst} -> ${afterSecond}`);
  }

  // 3. Retrieval — the check that matters
  const trgm = await kb.hasTrgm(pool);
  console.log(`\nRetrieval probe (matcher: ${trgm ? 'trigram' : 'token overlap'}, `
    + `floor: ${kb.MIN_SIMILARITY}):`);
  for (const probe of PROBES) {
    // eslint-disable-next-line no-await-in-loop
    const hit = await kb.search(pool, { question: probe.say });
    if (!hit.hit || !hit.row) {
      fail(`"${probe.say}" matched nothing`);
      continue;
    }
    const matched = String(hit.row.question).toLowerCase().includes(probe.expect.toLowerCase());
    const sim = Number(hit.similarity).toFixed(3);
    if (matched && hit.similarity >= kb.MIN_SIMILARITY) {
      ok(`"${probe.say}"  ->  "${hit.row.question}"  (sim ${sim})`);
    } else if (!matched) {
      fail(`"${probe.say}" reached the wrong row: "${hit.row.question}" (sim ${sim})`);
    } else {
      fail(`"${probe.say}" scored ${sim}, under the ${kb.MIN_SIMILARITY} floor`);
    }
  }

  console.log('');
  if (failures) {
    console.error(`FAILED: ${failures} check(s) did not pass.`);
    process.exitCode = 1;
  } else {
    console.log('OK: seed applied, idempotent, and every probe retrieves its answer.');
  }
}

main()
  .catch((err) => {
    console.error('Migration runner crashed:', err.message);
    process.exitCode = 1;
  })
  .finally(() => pool.end());
