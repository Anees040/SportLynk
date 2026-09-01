/**
 * Match preview generator (FR5.10)  —  S.2 Wave C
 *
 * Template NLG v1. Every sentence is assembled from real features already in the
 * database — both ratings, the gap between them, last-5 form, win rates, and the
 * competitiveness score — and nothing here invents a fact it was not given.
 *
 * Why this is not an LLM call
 * doc/claude.md is explicit that the committee requires genuinely trained ML and
 * that no external AI API may be called. A template generator over real features
 * is the honest thing to ship at this stage: it is deterministic, it is auditable
 * sentence by sentence, and it cannot hallucinate a scoreline that never
 * happened. S.6 may optionally route this text through the LLM garnish flag for
 * fluency, but the facts will still be produced here.
 *
 * Why the UI label is "Preview" and not "AI PREDICTION"
 * This text does not predict a result; it summarises a rating gap and recent
 * form. Calling it a prediction would overclaim, so PREVIEW_LABEL is exported
 * from this module and the screens render that constant rather than their own
 * wording — a label that lives in one place cannot drift into a claim the
 * generator does not support.
 *
 * Why it is pure (no database import)
 * Same reason as utils/elo.js: importing the pool connects at module load, which
 * would make this untestable without a live database. The route fetches the
 * features and passes them in.
 *
 * Why it is deterministic
 * Variety comes from hashing a caller-supplied seed (the match id), not from
 * Math.random(). The same match therefore always reads the same way — a preview
 * that reworded itself on every pull-to-refresh would look broken, and it could
 * not be stored as the snapshot that matches.preview_text is meant to be.
 */

/** The only label any screen may put above this text. */
const PREVIEW_LABEL = 'Preview';

/** Form is read over this many most-recent completed matches. */
const FORM_WINDOW = 5;

/** Below this many completed matches, a form sentence is noise, not signal. */
const MIN_MATCHES_FOR_FORM = 2;

// Small pure helpers

function num(v, fallback = 0) {
  const n = typeof v === 'number' ? v : Number.parseFloat(String(v));
  return Number.isFinite(n) ? n : fallback;
}

/** FNV-1a. Stable across runs and platforms, which Math.random() is not. */
function hash(str) {
  let h = 2166136261;
  const s = String(str);
  for (let i = 0; i < s.length; i += 1) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}

/** Deterministic choice from a list, seeded by the match id. */
function pick(options, seed) {
  if (!options.length) return '';
  return options[hash(seed) % options.length];
}

/**
 * A team's short name for mid-sentence use: "Lahore Lions FC" → "Lahore Lions".
 * Trailing club suffixes read badly in the middle of a sentence ("Lions FC won 3
 * of their last 5") but are needed on first mention, so both forms exist.
 */
function shortName(name) {
  const n = String(name || 'This team').trim();
  const trimmed = n.replace(/\s+(FC|CC|XI|United|Club)$/i, '').trim();
  return trimmed.length >= 3 ? trimmed : n;
}

/**
 * Turn completed-match rows into a form string, most recent first.
 * Rows need `winner_team`, `challenger_team`, `opponent_team`; a NULL winner is
 * a draw, which is why the column is nullable in the first place.
 */
function formFromMatches(rows, teamId) {
  const me = String(teamId);
  return (rows || [])
    .filter((r) => String(r.challenger_team) === me || String(r.opponent_team) === me)
    .slice(0, FORM_WINDOW)
    .map((r) => {
      if (r.winner_team === null || r.winner_team === undefined) return 'D';
      return String(r.winner_team) === me ? 'W' : 'L';
    })
    .join('');
}

/** Counts from a form string like "WWLDW". */
function formTally(form) {
  const f = String(form || '').toUpperCase();
  const count = (ch) => (f.match(new RegExp(ch, 'g')) || []).length;
  return { played: f.length, wins: count('W'), losses: count('L'), draws: count('D') };
}

/** Length of the current unbeaten / winning / losing run at the front of `form`. */
function streak(form) {
  const f = String(form || '').toUpperCase();
  if (!f) return { kind: null, length: 0 };
  const kind = f[0];
  let n = 1;
  while (n < f.length && f[n] === kind) n += 1;
  return { kind, length: n };
}

function winRate(team) {
  const w = num(team.wins);
  const played = w + num(team.losses) + num(team.draws);
  return played === 0 ? null : Math.round((w / played) * 100);
}

function isRanked(team) {
  return num(team.wins) + num(team.losses) + num(team.draws) >= 1;
}

// Sentence 1: who is favoured, and by how much

/**
 * The framing sentence. `gap` bands are deliberately coarse — the ELO curve is
 * logistic, so a 30-point gap genuinely is "level" (a 54% expectation) and
 * describing it as an edge would mislead.
 */
function framingSentence({ favourite, underdog, gap, seed, bothRanked }) {
  const fav = String(favourite.name || 'The challenger');
  const dog = String(underdog.name || 'the opponent');

  if (!bothRanked) {
    // FR2.6 — with a placeholder rating on at least one side, any "favourite"
    // claim would be derived from a number nobody earned.
    const unranked = [];
    if (!isRanked(favourite)) unranked.push(fav);
    if (!isRanked(underdog)) unranked.push(dog);
    if (unranked.length === 2) {
      return `${fav} and ${dog} are both still Unranked, so this is a first rated match for each of them.`;
    }
    const ranked = isRanked(favourite) ? favourite : underdog;
    return `${unranked[0]} is still Unranked, so there is no rating to compare against `
      + `${shortName(ranked.name)}'s ${Math.round(num(ranked.elo))} yet.`;
  }

  const fe = Math.round(num(favourite.elo));
  const de = Math.round(num(underdog.elo));

  if (gap < 25) {
    return pick([
      `${fav} (${fe}) and ${dog} (${de}) go in separated by just ${gap} rating point${gap === 1 ? '' : 's'} — about as level as this gets.`,
      `Nothing between them on paper: ${fav} (${fe}) versus ${dog} (${de}), a ${gap}-point gap.`,
    ], seed);
  }
  if (gap < 75) {
    return pick([
      `${fav} (${fe}) enters as slight favorites over ${dog} (${de}).`,
      `${fav} (${fe}) holds a narrow ${gap}-point edge over ${dog} (${de}).`,
    ], seed);
  }
  if (gap < 175) {
    return pick([
      `${fav} (${fe}) starts as favorites against ${dog} (${de}).`,
      `On rating, ${fav} (${fe}) is the stronger side by ${gap} points over ${dog} (${de}).`,
    ], seed);
  }
  return pick([
    `${fav} (${fe}) enters as clear favorites against ${dog} (${de}), ${gap} rating points below them.`,
    `${fav} (${fe}) is a substantial ${gap} points clear of ${dog} (${de}).`,
  ], seed);
}

// Sentence 2: recent form

/**
 * Pick the side whose form is most worth mentioning, and say it. Preference goes
 * to the underdog in good form or the favourite in bad form, because those are
 * the two cases where recent results argue against the rating gap — a preview
 * that only ever confirms the ratings adds nothing a player cannot already see.
 */
function formSentence({ favourite, underdog, seed }) {
  const fTally = formTally(favourite.form);
  const uTally = formTally(underdog.form);

  const candidates = [];
  if (uTally.played >= MIN_MATCHES_FOR_FORM) {
    candidates.push({ team: underdog, tally: uTally, interest: uTally.wins * 2 });
  }
  if (fTally.played >= MIN_MATCHES_FOR_FORM) {
    candidates.push({ team: favourite, tally: fTally, interest: fTally.losses * 2 });
  }
  if (!candidates.length) return '';

  candidates.sort((a, b) => b.interest - a.interest);
  const chosen = candidates[0].interest > 0 ? candidates[0] : candidates[candidates.length - 1];
  const name = shortName(chosen.team.name);
  const { wins, played } = chosen.tally;
  const run = streak(chosen.team.form);

  // A run of three or more is the more informative fact when there is one.
  if (run.length >= 3 && run.kind === 'W') {
    return `${name} arrives on a ${run.length}-match winning run.`;
  }
  if (run.length >= 3 && run.kind === 'L') {
    return `${name} has lost their last ${run.length}.`;
  }

  const rate = winRate(chosen.team);
  const rateClause = rate === null ? '' : ` (${rate}% overall)`;
  return `${name} won ${wins} of their last ${played}${rateClause}.`;
}

// Sentence 3: the closer

function closingSentence({ competitiveness, favourite, underdog, seed }) {
  if (competitiveness === null || competitiveness === undefined) {
    return 'Competitiveness is rated once both teams have a verified result.';
  }
  const c = num(competitiveness);
  const dog = shortName(underdog.name);
  const fav = shortName(favourite.name);

  let phrase;
  if (c >= 85) {
    phrase = pick(['expect a close contest', 'this one should go down to the wire'], seed);
  } else if (c >= 60) {
    phrase = pick(['a competitive fixture on paper', `${dog} has enough to make this awkward`], seed);
  } else if (c >= 35) {
    phrase = `${fav} will be expected to control this`;
  } else {
    phrase = `a tall order for ${dog}`;
  }
  return `${phrase.charAt(0).toUpperCase()}${phrase.slice(1)} — competitiveness ${Math.round(c)}%.`;
}

// The one public entry point

/**
 * Build the 2–3 sentence preview.
 *
 * @param {object} p
 * @param {{name:string, elo:number, wins:number, losses:number, draws:number, form?:string}} p.challenger
 * @param {{name:string, elo:number, wins:number, losses:number, draws:number, form?:string}} p.opponent
 * @param {number|null} p.competitiveness  5..100, or null when either side is Unranked
 * @param {string} p.seed  stable per match (use the match id) — drives template choice
 * @returns {string} plain text, safe to store in matches.preview_text
 */
function buildPreview({ challenger, opponent, competitiveness = null, seed = '' }) {
  const a = challenger || {};
  const b = opponent || {};
  const bothRanked = isRanked(a) && isRanked(b);

  // Whoever is rated higher leads the sentence. Ties break on the challenger,
  // so the text is stable rather than depending on object key order.
  const aElo = num(a.elo);
  const bElo = num(b.elo);
  const favourite = bElo > aElo ? b : a;
  const underdog = favourite === a ? b : a;
  const gap = Math.abs(Math.round(aElo) - Math.round(bElo));

  const sentences = [
    framingSentence({ favourite, underdog, gap, seed, bothRanked }),
    formSentence({ favourite, underdog, seed }),
    closingSentence({ competitiveness, favourite, underdog, seed }),
  ].filter((s) => s && s.trim().length);

  return sentences.join(' ');
}

module.exports = {
  PREVIEW_LABEL,
  FORM_WINDOW,
  MIN_MATCHES_FOR_FORM,
  buildPreview,
  formFromMatches,
  formTally,
  streak,
  shortName,
};
