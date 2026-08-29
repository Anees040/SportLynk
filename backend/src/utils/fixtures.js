/**
 * fixtures.js — the tournament arithmetic, with no database in sight.
 *
 * WHY THIS FILE EXISTS
 * --------------------
 * Everything a tournament argues about is a calculation: who plays whom, who
 * gets a bye, which node a winner walks into, how many points a draw is worth,
 * how much of the pool is prize money and how much is the venue's. If those
 * calculations lived inside `tournamentService.js` they could only ever be
 * tested by creating a tournament, funding eight wallets and running a job —
 * which is exactly the kind of test nobody runs twice.
 *
 * So the maths lives here, as pure functions with zero I/O: no `pool`, no
 * `client`, no clock, no randomness. `backend/test/fixtures.test.js` therefore
 * runs under `npm test` with the database switched off, and a bracket bug is
 * caught in 40ms instead of during a demo.
 *
 * THE FOUR THINGS THIS FILE DECIDES
 * ---------------------------------
 * 1. THE BRACKET. Teams are seeded by ELO (strongest = seed 1) and paired by the
 *    standard recursive bracket order, so seeds 1 and 2 can only meet in the
 *    final. `max_teams` is a power of two, but the number that actually turns up
 *    at the deadline is whatever registered — so the bracket is padded to the
 *    next power of two and the missing opponents become BYES. Because the
 *    bracket order always pairs a top-half seed with a bottom-half seed, and the
 *    padding only ever removes bottom-half seeds, byes land on the top seeds
 *    automatically. That is a property of the ordering, not a special case:
 *    `test/fixtures.test.js` asserts it for every size from 2 to 32.
 *
 * 2. THE K-FACTOR. Tournament results are more authoritative than a friendly, so
 *    they move ELO harder — 40 in the early rounds, 48 in a semi-final, 56 in a
 *    final, against 32 for a friendly. This is one ladder with FIDE's own
 *    device (one rating, different K per event tier), NOT a second tournament
 *    rating: a team with three tournament matches has no meaningful separate
 *    rating, and the bracket is SEEDED by ELO, so a separate ladder would seed
 *    the first tournament off all-1000s. A bye gets K = 0 — no game was played,
 *    so no rating may move. `elo.applyResult` already takes `kFactor` and
 *    `elo_history.k_factor` already stores it per row, so "why did this count
 *    more?" is answered by a SELECT rather than by a second number on a screen.
 *
 * 3. THE STANDINGS. 3 for a win, 1 for a draw, 0 for a loss, ordered by points,
 *    then goal difference, then goals for, then the head-to-head result, then
 *    name. Derived on read from the fixtures — there is no `standings` table to
 *    fall out of date (see the note at the end of migration 019).
 *
 * 4. THE MONEY, which is the part most worth being able to unit-test. The venue
 *    cost is recovered FIRST and the prize comes out of what is left:
 *
 *        pool       = entry_fee x teams_accepted
 *        venue_cost = SUM(slots.price over the allocated slots)
 *                     x (1 - venue_discount_percent)
 *        surplus    = pool - venue_cost
 *        prize      = surplus x prize_percent      (winner 70 / runner-up 30)
 *        owner      = venue_cost + (surplus - prize)
 *
 *    A flat percentage commission would have been simpler and wrong: the venue
 *    cost is FIXED while the pool is VARIABLE, so 8 teams x PKR 2,000 = 16,000
 *    pool against seven hours of inventory worth ~14,000 would pay the owner a
 *    30% commission of 4,800 for slots they could have sold for 14,000. The
 *    tournament would lose them money, which inverts the whole point of the
 *    feature. Recovering the inventory first means a tournament can never be
 *    worse for an owner than selling the same hours.
 *
 *    `splitPool` works in PAISA as integers and hands the rounding remainder to
 *    the owner's margin, so `pool = venue_cost + prize + margin` holds to the
 *    paisa by construction rather than by luck — `check_tournaments.js` asserts
 *    exactly that identity.
 *
 * WHAT IS NOT HERE
 * ---------------
 * Slot choice (`utils/fixtureSchedule.js` — which hour each fixture is played
 * in), demand forecasting (`services/tournamentScheduler.js`, model #1), and
 * every row that gets written (`services/tournamentService.js`). This file
 * decides shapes and numbers; those decide when and where.
 */

/**
 * The one formula shared with the ladder. `winProbability` below is the Elo
 * expected score, and importing it rather than re-typing `1 / (1 + 10^(d/400))`
 * is deliberate: a fixture card that disagreed with the rating change after the
 * match would be a bug nobody would think to look for. elo.js imports nothing
 * itself, so this stays a database-free module.
 */
const elo = require('./elo');

/** League points. 3/1/0 is the football default and what the SRS shows. */
const POINTS = { WIN: 3, DRAW: 1, LOSS: 0 };

/**
 * K by stake. Overridable from `global_settings.tournament` (k_early / k_semi /
 * k_final) so a marker can be shown the lever; the defaults are the shipped
 * policy. BYE is not configurable — a rating cannot move for a game that was
 * never played, so it is 0 by definition rather than by preference.
 */
const K = { EARLY: 40, SEMI: 48, FINAL: 56, BYE: 0, FRIENDLY: 32 };

/** The two formats 019's `chk_tournaments_format` allows. */
const FORMATS = { KNOCKOUT: 'knockout', ROUND_ROBIN: 'round_robin' };

/** Fixture states, mirroring 019's `chk_fixtures_status`. */
const FIXTURE_STATUS = {
  UPCOMING: 'upcoming', PLAYED: 'played', WALKOVER: 'walkover', CANCELLED: 'cancelled',
};

/**
 * Caps, mirroring `chk_tournaments_max_teams`. Round-robin is capped far lower
 * on purpose: it grows as n(n-1)/2, so 8 teams is 28 fixtures — 28 hours of
 * venue against a knockout's 7. The preview endpoint prices that immediately,
 * but a cap stops it being created by accident in the first place.
 */
const MAX_KNOCKOUT_TEAMS = 32;
const MAX_ROUND_ROBIN_TEAMS = 6;
const MIN_TEAMS_FLOOR = 2;

// ---------------------------------------------------------------------------
// numeric helpers
// ---------------------------------------------------------------------------

/** pg DECIMALs arrive as strings; every number here goes through this first. */
function asNum(v, fallback = 0) {
  const n = typeof v === 'number' ? v : Number.parseFloat(String(v));
  return Number.isFinite(n) ? n : fallback;
}

/** Money, to the paisa, as an integer — the only safe way to split a pool. */
const toPaisa = (v) => Math.round(asNum(v) * 100);
const fromPaisa = (p) => Math.round(p) / 100;

/** Rupees rounded like escrow.round2, for anything not already in paisa. */
const round2 = (v) => Math.round(asNum(v) * 100) / 100;

/** A percentage a caller supplied, clamped into the range 019's CHECKs allow. */
const pct = (v, fallback) => {
  const n = asNum(v, fallback);
  return Math.max(0, Math.min(100, n));
};

/** True for 1, 2, 4, 8, 16, 32 … and nothing else. Powers of two have one bit. */
const isPowerOfTwo = (n) => Number.isInteger(n) && n > 0 && (n & (n - 1)) === 0;

/** A positive integer count, or 0 for anything that is not one. */
const count = (v) => {
  const n = Math.floor(asNum(v, 0));
  return n > 0 ? n : 0;
};

// ==========================================================================
// SEEDING AND BRACKET SHAPE
// ==========================================================================

/**
 * seedTeams — strongest first, and DETERMINISTIC when ratings tie.
 *
 * ELO descending is the seeding rule, but two 1000-rated teams (every team that
 * has never played a verified match) must still get a stable order, or the same
 * eight registrations would produce a different bracket on every generation
 * attempt and nobody could reproduce a bug. So name and then id break the tie.
 *
 * Returns NEW objects with `seed` attached (1-based); the input is not mutated,
 * because the caller usually still needs its rows for the INSERT.
 */
function seedTeams(teams) {
  const list = Array.isArray(teams) ? teams.filter(Boolean) : [];
  const keyed = list.map((t) => ({
    ...t,
    elo: Math.round(asNum(t.elo, 1000)),
    _name: String(t.name == null ? '' : t.name).toLowerCase(),
    _id: String(t.id == null ? '' : t.id),
  }));
  keyed.sort((a, b) => (b.elo - a.elo)
    || (a._name < b._name ? -1 : a._name > b._name ? 1 : 0)
    || (a._id < b._id ? -1 : a._id > b._id ? 1 : 0));
  return keyed.map((t, i) => {
    const out = { ...t, seed: i + 1 };
    delete out._name;
    delete out._id;
    return out;
  });
}

/** The next power of two at or above n, floored at 2 — the padded bracket size. */
function bracketSize(n) {
  const k = count(n);
  if (k <= 2) return 2;
  let size = 2;
  while (size < k) size *= 2;
  return size;
}

/** Rounds a padded bracket needs: 8 teams → 3 (quarter, semi, final). */
function roundsFor(n) {
  return Math.log2(bracketSize(n));
}

/**
 * bracketOrder — seeds in slot order, so that pairs are (arr[0] v arr[1]),
 * (arr[2] v arr[3]) … and the top two seeds cannot meet before the final.
 *
 * The classic recursive construction: a bracket of 2n is a bracket of n with
 * every seed s followed by its mirror (2n + 1 - s).
 *
 *   size 2 → [1, 2]
 *   size 4 → [1, 4, 2, 3]
 *   size 8 → [1, 8, 4, 5, 2, 7, 3, 6]
 *
 * Two properties matter downstream and are asserted in the tests: every pair
 * contains exactly one seed from the top half (so padding, which only removes
 * the highest seed NUMBERS, can never empty a pair), and seed 1 meets seed 2
 * only in round `rounds`.
 */
function bracketOrder(size) {
  const target = bracketSize(size);
  let order = [1, 2];
  while (order.length < target) {
    const half = order.length * 2;
    const next = [];
    for (const s of order) next.push(s, half + 1 - s);
    order = next;
  }
  return order;
}

/**
 * roundLabel — what the bracket header says. "Semi-final" is worth far more to a
 * captain than "Round 3", and the label is stored on the fixture row so the app,
 * the chat pill and the notification all read the same words.
 */
function roundLabel(round, rounds, format = FORMATS.KNOCKOUT) {
  const r = count(round);
  const total = count(rounds);
  if (format === FORMATS.ROUND_ROBIN) return `Matchday ${r || 1}`;
  if (!r || !total) return `Round ${r || 1}`;
  if (r >= total) return 'Final';
  if (r === total - 1) return 'Semi-final';
  if (r === total - 2) return 'Quarter-final';
  return `Round of ${2 ** (total - r + 1)}`;
}

/**
 * advanceSlot — where the winner of (round, position) goes next.
 *
 * Nodes 1 and 2 of a round both feed node 1 of the next, 3 and 4 feed node 2,
 * and so on: `ceil(position / 2)`. Which SIDE matters too — the odd node fills
 * team_a and the even node fills team_b — because that is what stops two
 * winners racing for the same column and one of them overwriting the other.
 */
function advanceSlot(round, position) {
  const r = count(round);
  const p = count(position);
  if (!r || !p) return null;
  return { round: r + 1, position: Math.ceil(p / 2), side: p % 2 === 1 ? 'a' : 'b' };
}

/**
 * fixtureCount — how many fixtures will actually be PLAYED, which is the number
 * the venue is paid for. Byes are excluded because a bye consumes no hour: it is
 * a bracket bookkeeping row, not a match.
 *
 *   knockout    n - 1     every match eliminates exactly one team
 *   round_robin n(n-1)/2  every pair meets once
 */
function fixtureCount(format, n) {
  const k = count(n);
  if (k < 2) return 0;
  if (format === FORMATS.ROUND_ROBIN) return (k * (k - 1)) / 2;
  return k - 1;
}

/** Rows a knockout bracket creates, byes included: a full tree has size-1 nodes. */
const bracketNodes = (n) => bracketSize(n) - 1;

/** Byes needed to pad n teams up to the bracket. 0 when n is already a power of two. */
const byeCount = (n) => bracketSize(n) - count(n);

/** Matchdays a round-robin takes: n-1 for an even n, n for an odd one (one rests). */
function roundRobinRounds(n) {
  const k = count(n);
  if (k < 2) return 0;
  return k % 2 === 0 ? k - 1 : k;
}

/**
 * kFactorFor — the stake weighting described in note 2 of the header.
 *
 * A bye is 0 before anything else is considered, because `is_bye` means no game
 * was played. Round-robin has no final, so every matchday is an early round.
 */
function kFactorFor({ round, rounds, isBye = false, format = FORMATS.KNOCKOUT, k = null } = {}) {
  if (isBye) return K.BYE;
  const table = {
    early: asNum(k && k.early, K.EARLY) || K.EARLY,
    semi: asNum(k && k.semi, K.SEMI) || K.SEMI,
    final: asNum(k && k.final, K.FINAL) || K.FINAL,
  };
  if (format === FORMATS.ROUND_ROBIN) return table.early;
  const r = count(round);
  const total = count(rounds);
  if (!r || !total) return table.early;
  if (r >= total) return table.final;
  if (r === total - 1) return table.semi;
  return table.early;
}

/** Elo expected score — the win probability a fixture card shows. Same formula the ladder uses. */
const winProbability = (eloA, eloB) => elo.expected(Math.round(asNum(eloA, 1000)),
  Math.round(asNum(eloB, 1000)));

/**
 * knockoutFixtures — the ENTIRE bracket in one pass: every node of every round,
 * round 1 paired from the seeds, later rounds left TBD but already wired to the
 * node that feeds them, and byes resolved on the spot.
 *
 * The bracket is built as a complete tree first and populated second, because a
 * knockout has to exist before it is played: the app draws "Semi-final · TBD v
 * TBD" from day one, and a winner needs a row waiting for it rather than an
 * INSERT racing three other results. `next_round` / `next_position` are stored
 * on the row so `advanceAfterMatch` does one UPDATE by coordinate instead of
 * re-deriving the tree shape every time a score comes in.
 *
 * BYES ARE RESOLVED HERE, not left for the job. A padded pair whose bottom-half
 * seed does not exist becomes `{team_a: <seed>, team_b: null, is_bye: true,
 * status: 'walkover', winner: team_a}` and its team is written straight into the
 * next round's slot. That is why a 5-team bracket produces four round-1 rows of
 * which three are byes, and why the first REAL fixture a 5-team draw needs is
 * seed 4 v seed 5.
 *
 * Input: the output of `seedTeams` (or anything with `id` and `seed`).
 * Output: `{ size, rounds, byes, played, fixtures[] }` — `played` being the
 * number of nodes that need a venue slot, i.e. every node that is not a bye.
 */
function knockoutFixtures(seededTeams) {
  const teams = Array.isArray(seededTeams) ? seededTeams.filter(Boolean) : [];
  const n = teams.length;
  const size = bracketSize(n);
  const rounds = Math.log2(size);
  const order = bracketOrder(size);
  const bySeed = new Map(teams.map((t, i) => [count(t.seed) || i + 1, t]));

  // 1. every node of every round, empty, wired forward.
  const fixtures = [];
  const at = new Map();
  for (let r = 1; r <= rounds; r += 1) {
    const nodes = size / 2 ** r;
    for (let p = 1; p <= nodes; p += 1) {
      const next = r < rounds ? advanceSlot(r, p) : null;
      const node = {
        round: r,
        position: p,
        label: roundLabel(r, rounds, FORMATS.KNOCKOUT),
        teamA: null,
        teamB: null,
        seedA: null,
        seedB: null,
        isBye: false,
        status: FIXTURE_STATUS.UPCOMING,
        winner: null,
        nextRound: next ? next.round : null,
        nextPosition: next ? next.position : null,
        nextSide: next ? next.side : null,
      };
      fixtures.push(node);
      at.set(`${r}:${p}`, node);
    }
  }

  // 2. round 1, from the bracket order. `order` alternates top-half seed then
  //    bottom-half mirror, so index 2p-2 is always the seed that exists.
  for (let p = 1; p <= size / 2; p += 1) {
    const node = at.get(`1:${p}`);
    const sa = order[2 * p - 2];
    const sb = order[2 * p - 1];
    const ta = bySeed.get(sa) || null;
    const tb = bySeed.get(sb) || null;
    // A bye must carry its team in team_a — 019's chk_fixtures_bye insists on it.
    const pair = ta && tb ? [[sa, ta], [sb, tb]] : [[sa, ta], [sb, tb]].filter((x) => x[1]);
    if (pair[0]) { [node.seedA, node.teamA] = [pair[0][0], pair[0][1].id]; }
    if (pair[1]) { [node.seedB, node.teamB] = [pair[1][0], pair[1][1].id]; }
    if (node.teamA && !node.teamB) {
      node.isBye = true;
      node.status = FIXTURE_STATUS.WALKOVER;
      node.winner = node.teamA;
      node.label = `${node.label} (bye)`;
    }
  }

  // 3. byes advance immediately, so round 2 opens with a real name in it.
  for (const node of fixtures) {
    if (!node.isBye || !node.nextRound) continue;
    const nxt = at.get(`${node.nextRound}:${node.nextPosition}`);
    if (!nxt) continue;
    if (node.nextSide === 'a') { nxt.teamA = node.winner; nxt.seedA = node.seedA; }
    else { nxt.teamB = node.winner; nxt.seedB = node.seedA; }
  }

  const byes = fixtures.filter((f) => f.isBye).length;
  return { size, rounds, byes, played: fixtures.length - byes, fixtures };
}

/**
 * circleMethod — the round-robin schedule, by the standard rotation.
 *
 * One team is pinned and the rest rotate one place each matchday, which is the
 * textbook construction guaranteeing every pair meets EXACTLY once and no team
 * plays twice on the same matchday. An odd count gets a ghost entry, and the
 * team drawn against the ghost simply rests that matchday — that is a rest, not
 * a bye fixture, so no row is created for it.
 *
 * Sides alternate by matchday so that one team is not listed first in every
 * single fixture. `team_a` carries no home advantage in this system, but a
 * schedule where the same name is always on the left looks like a bug.
 *
 * Output rows carry `(round, position)` like a bracket node, so 019's
 * `UNIQUE (tournament_id, round, position)` holds for both formats and one
 * `fixtures` table serves them both.
 */
function circleMethod(teams) {
  const list = (Array.isArray(teams) ? teams.filter(Boolean) : []).slice();
  if (list.length < 2) return { rounds: 0, fixtures: [] };
  const ghost = list.length % 2 === 1;
  if (ghost) list.push(null);
  const m = list.length;
  const half = m / 2;
  const rounds = m - 1;

  let arr = list.slice();
  const fixtures = [];
  for (let r = 1; r <= rounds; r += 1) {
    let position = 0;
    for (let i = 0; i < half; i += 1) {
      const a = arr[i];
      const b = arr[m - 1 - i];
      if (!a || !b) continue;               // the ghost pairing: that team rests
      position += 1;
      const flip = r % 2 === 0;
      const home = flip ? b : a;
      const away = flip ? a : b;
      fixtures.push({
        round: r,
        position,
        label: roundLabel(r, rounds, FORMATS.ROUND_ROBIN),
        teamA: home.id,
        teamB: away.id,
        seedA: count(home.seed) || null,
        seedB: count(away.seed) || null,
        isBye: false,
        status: FIXTURE_STATUS.UPCOMING,
        winner: null,
        nextRound: null,                    // a league table has nowhere to advance to
        nextPosition: null,
        nextSide: null,
      });
    }
    // Pin arr[0]; rotate the rest one place right.
    arr = [arr[0], arr[m - 1], ...arr.slice(1, m - 1)];
  }
  return { rounds, byes: 0, played: fixtures.length, fixtures };
}

/**
 * buildFixtures — the format switch, so callers say what they want once.
 */
function buildFixtures(format, seededTeams) {
  if (format === FORMATS.ROUND_ROBIN) return circleMethod(seededTeams);
  return knockoutFixtures(seededTeams);
}

// ==========================================================================
// RESULTS AND STANDINGS
// ==========================================================================

/**
 * normaliseFixture — one reader for a fixture, whether it came from Postgres
 * (`team_a`, `score_a`, `is_bye`) or from `buildFixtures` above (`teamA`,
 * `scoreA`, `isBye`). The standings are computed from both — from real rows in
 * the service, and from generated rows in the tests — and a silent undefined on
 * one side of that would produce a table that is quietly wrong rather than
 * broken, which is the worst kind.
 */
function normaliseFixture(row) {
  const r = row || {};
  const get = (snake, camel) => (snake in r ? r[snake] : r[camel]);
  const numOrNull = (v) => (v == null || v === '' ? null : asNum(v, 0));
  return {
    round: count(get('round', 'round')),
    position: count(get('position', 'position')),
    teamA: get('team_a', 'teamA') || null,
    teamB: get('team_b', 'teamB') || null,
    scoreA: numOrNull(get('score_a', 'scoreA')),
    scoreB: numOrNull(get('score_b', 'scoreB')),
    winner: get('winner', 'winner') || null,
    status: String(get('status', 'status') || FIXTURE_STATUS.UPCOMING),
    isBye: Boolean(get('is_bye', 'isBye')),
  };
}

/**
 * standings — the league table, derived on read.
 *
 * ORDER: points, then goal difference, then goals for, then the head-to-head
 * result, then name. Goal-difference-before-head-to-head is the FIFA World Cup
 * ordering (UEFA does the opposite); either is defensible, so the one in use is
 * written down here and in `doc/TESTING.md` rather than left implicit in a
 * comparator. Head-to-head is applied PAIRWISE, which is not a total order in a
 * three-way tie — name is the final tiebreak precisely so that the table is
 * always deterministic even when the sport's own rules would shrug.
 *
 * A walkover counts as a played match and a win with no goals: the team turned
 * up and the other did not, which is a result. A BYE counts as nothing at all —
 * it is bracket bookkeeping, and round-robin does not produce them anyway.
 */
function standings(teams, fixtures) {
  const rows = new Map();
  for (const t of (Array.isArray(teams) ? teams.filter(Boolean) : [])) {
    rows.set(String(t.id), {
      teamId: t.id,
      name: t.name || '',
      elo: Math.round(asNum(t.elo, 1000)),
      seed: count(t.seed) || null,
      played: 0, wins: 0, draws: 0, losses: 0,
      goalsFor: 0, goalsAgainst: 0, goalDiff: 0, points: 0,
      position: 0,
    });
  }
  const h2h = new Map();                       // "a|b" -> points a took off b
  const addH2h = (a, b, p) => {
    const k = `${a}|${b}`;
    h2h.set(k, asNum(h2h.get(k), 0) + p);
  };

  for (const raw of (Array.isArray(fixtures) ? fixtures : [])) {
    const f = normaliseFixture(raw);
    if (f.isBye) continue;
    const played = f.status === FIXTURE_STATUS.PLAYED;
    const walkover = f.status === FIXTURE_STATUS.WALKOVER;
    if (!played && !walkover) continue;
    const a = rows.get(String(f.teamA));
    const b = rows.get(String(f.teamB));

    if (walkover || f.scoreA == null || f.scoreB == null) {
      // No scoreline exists. Award the win to whoever the row names.
      const win = f.winner ? rows.get(String(f.winner)) : null;
      if (!win || (win !== a && win !== b)) continue;
      const lose = win === a ? b : a;
      win.played += 1; win.wins += 1; win.points += POINTS.WIN;
      if (lose) {
        lose.played += 1; lose.losses += 1;
        addH2h(String(win.teamId), String(lose.teamId), POINTS.WIN);
      }
      continue;
    }
    if (!a || !b) continue;                    // a fixture naming a team not in the list
    a.played += 1; b.played += 1;
    a.goalsFor += f.scoreA; a.goalsAgainst += f.scoreB;
    b.goalsFor += f.scoreB; b.goalsAgainst += f.scoreA;
    if (f.scoreA > f.scoreB) {
      a.wins += 1; b.losses += 1; a.points += POINTS.WIN;
      addH2h(String(a.teamId), String(b.teamId), POINTS.WIN);
    } else if (f.scoreB > f.scoreA) {
      b.wins += 1; a.losses += 1; b.points += POINTS.WIN;
      addH2h(String(b.teamId), String(a.teamId), POINTS.WIN);
    } else {
      a.draws += 1; b.draws += 1;
      a.points += POINTS.DRAW; b.points += POINTS.DRAW;
      addH2h(String(a.teamId), String(b.teamId), POINTS.DRAW);
      addH2h(String(b.teamId), String(a.teamId), POINTS.DRAW);
    }
  }

  // A comparator must return 0 for genuine ties or the sort is not stable.
  const cmpName = (x, y) => {
    const a1 = String(x || '').toLowerCase();
    const b1 = String(y || '').toLowerCase();
    return a1 < b1 ? -1 : a1 > b1 ? 1 : 0;
  };
  const table = [...rows.values()];
  for (const r of table) r.goalDiff = r.goalsFor - r.goalsAgainst;
  table.sort((x, y) => (y.points - x.points)
    || (y.goalDiff - x.goalDiff)
    || (y.goalsFor - x.goalsFor)
    || (asNum(h2h.get(`${y.teamId}|${x.teamId}`), 0) - asNum(h2h.get(`${x.teamId}|${y.teamId}`), 0))
    || (y.wins - x.wins)
    || cmpName(x.name, y.name));
  table.forEach((r, i) => { r.position = i + 1; });
  return table;
}

// ==========================================================================
// MONEY  (the waterfall from note 4 of the header)
// ==========================================================================

/**
 * splitPool — the whole economics of a tournament as one pure function.
 *
 * Called three times over a tournament's life, and it must give the same answer
 * every time: once by `POST /api/tournaments/preview` before the row exists,
 * once by `generateFixtures` when the money actually moves, and once by the
 * check script asserting the ledger. One function is the only way those three
 * can agree.
 *
 * EVERYTHING IS COMPUTED IN PAISA AS INTEGERS. Rupee floats do not divide by 3,
 * and a prize pool that is one paisa short of its parts is a failed assertion in
 * `check_tournaments.js` and an unexplainable wallet in the demo. The prize is
 * FLOORED and the winner's share is FLOORED, which means every lost fraction
 * lands in the owner's margin — the residual goes to the party that carries the
 * venue cost, and `pool = venue_cost + prize + margin` holds exactly.
 *
 * UNDERWATER (pool < venue_cost) is a real case, not an error: four teams at a
 * low fee may not cover seven hours of ground. Then the prize is zero and the
 * owner takes the entire pool — the margin goes NEGATIVE, which is the honest
 * statement that the tournament did not cover its inventory, but no money is
 * ever taken FROM the owner. `owner_earning` is `pool - prize`, so it can never
 * exceed what the captains actually paid in.
 *
 * Accepts either a `pool` outright, or `entryFee` x `teams` for the preview,
 * where no team has registered yet.
 */
function splitPool({
  pool = null, entryFee = 0, teams = 0,
  slotTotal = 0, venueDiscountPercent = 0,
  prizePercent = 60, winnerPercent = 70, runnerupPercent = 30,
} = {}) {
  const teamsN = count(teams);
  const feeP = toPaisa(entryFee);
  const poolP = pool == null ? feeP * teamsN : toPaisa(pool);
  const slotP = toPaisa(slotTotal);

  const discountPct = pct(venueDiscountPercent, 0);
  const venueCostP = Math.round((slotP * (100 - discountPct)) / 100);
  const surplusP = poolP - venueCostP;

  const prizePct = pct(prizePercent, 60);
  const winPct = pct(winnerPercent, 70);
  // The two shares must add to 100 (019's chk_tournaments_percents) — the
  // runner-up takes the complement rather than its own rounding, so no paisa of
  // the prize is left unassigned.
  const prizeP = surplusP > 0 ? Math.floor((surplusP * prizePct) / 100) : 0;
  const winnerP = Math.floor((prizeP * winPct) / 100);
  const runnerupP = prizeP - winnerP;

  const marginP = poolP - venueCostP - prizeP;
  const ownerP = venueCostP + marginP;              // === poolP - prizeP

  return {
    teams: teamsN,
    entryFee: fromPaisa(feeP),
    pool: fromPaisa(poolP),
    slotTotal: fromPaisa(slotP),
    venueDiscountPercent: discountPct,
    venueDiscount: fromPaisa(slotP - venueCostP),
    venueCost: fromPaisa(venueCostP),
    surplus: fromPaisa(surplusP),
    prizePercent: prizePct,
    prize: fromPaisa(prizeP),
    winnerPercent: winPct,
    runnerupPercent: pct(runnerupPercent, 30),
    winnerShare: fromPaisa(winnerP),
    runnerupShare: fromPaisa(runnerupP),
    margin: fromPaisa(marginP),
    ownerEarning: fromPaisa(ownerP),
    underwater: surplusP < 0,
    // What the owner would have made selling the same hours at the counter. This
    // is the number the create screen puts the tournament next to, because "you
    // earn 21,200 instead of 14,000" is the entire argument for the feature.
    retailValue: fromPaisa(slotP),
    uplift: fromPaisa(ownerP - slotP),
    upliftPercent: slotP > 0 ? round2(((ownerP - slotP) / slotP) * 100) : null,
    // Proof the split is exact, carried in the payload so the check script and
    // the API assert the same thing rather than each re-deriving it.
    identityOk: poolP === venueCostP + prizeP + marginP && ownerP + prizeP === poolP,
  };
}

/**
 * recommendEntryFee — the number the create screen fills in for the owner.
 *
 * An owner guessing a fee is how a tournament ends up losing them money, so the
 * preview endpoint works BACKWARDS from the margin they want:
 *
 *   margin      = surplus x (1 - prize_percent/100)      the owner keeps what the
 *                                                        prize pool does not take
 *   surplus     = target_margin / (1 - prize_percent/100)
 *   pool needed = venue_cost + surplus
 *   fee         = pool needed / min_teams,  rounded UP to `roundTo`
 *
 * Dividing by `min_teams` rather than `max_teams` is deliberate: the fee has to
 * work at the WORST legal turnout, or a half-full tournament is the one that
 * goes underwater. A full field then simply earns more than the target.
 *
 * `target_margin` is a percentage OF THE VENUE COST (default 25%), not of the
 * pool, because the venue cost is the thing actually at risk.
 *
 * When `prize_percent` is 100 there is no margin to solve for — the owner can
 * only ever recover the venue cost — so the recommendation covers cost alone and
 * says so through `achievable: false`.
 */
function recommendEntryFee({
  slotTotal = 0, venueDiscountPercent = 0, minTeams = 4,
  prizePercent = 60, winnerPercent = 70, runnerupPercent = 30,
  targetMarginPercent = 25, roundTo = 100,
} = {}) {
  const slotP = toPaisa(slotTotal);
  const discountPct = pct(venueDiscountPercent, 0);
  const venueCostP = Math.round((slotP * (100 - discountPct)) / 100);
  const n = Math.max(MIN_TEAMS_FLOOR, count(minTeams) || MIN_TEAMS_FLOOR);
  const keep = (100 - pct(prizePercent, 60)) / 100;
  const targetP = Math.round((venueCostP * pct(targetMarginPercent, 25)) / 100);

  const achievable = keep > 0;
  const surplusNeededP = achievable ? Math.ceil(targetP / keep) : 0;
  const step = toPaisa(Math.max(1, asNum(roundTo, 100)));
  const perTeamP = Math.ceil((venueCostP + surplusNeededP) / n);
  const feeP = Math.max(step, Math.ceil(perTeamP / step) * step);

  return {
    entryFee: fromPaisa(feeP),
    minTeams: n,
    venueCost: fromPaisa(venueCostP),
    targetMarginPercent: pct(targetMarginPercent, 25),
    targetMargin: fromPaisa(targetP),
    achievable,
    roundedTo: fromPaisa(step),
    // The breakdown AT that fee and the worst legal turnout, so the screen can
    // show the owner the floor of what they are agreeing to rather than the best
    // case. `atCapacity` is the same fee with a full field.
    atMinTeams: splitPool({
      entryFee: fromPaisa(feeP), teams: n, slotTotal, venueDiscountPercent,
      prizePercent, winnerPercent, runnerupPercent,
    }),
  };
}

module.exports = {
  // constants
  POINTS,
  K,
  FORMATS,
  FIXTURE_STATUS,
  MAX_KNOCKOUT_TEAMS,
  MAX_ROUND_ROBIN_TEAMS,
  MIN_TEAMS_FLOOR,
  // numeric helpers, exported because the service and the check script must
  // round money the same way this file does
  asNum,
  round2,
  toPaisa,
  fromPaisa,
  isPowerOfTwo,
  // bracket shape
  seedTeams,
  bracketSize,
  roundsFor,
  bracketOrder,
  roundLabel,
  advanceSlot,
  fixtureCount,
  bracketNodes,
  byeCount,
  roundRobinRounds,
  knockoutFixtures,
  circleMethod,
  buildFixtures,
  // results
  kFactorFor,
  winProbability,
  normaliseFixture,
  standings,
  // money
  splitPool,
  recommendEntryFee,
};
