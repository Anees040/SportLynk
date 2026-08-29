/**
 * evidence.js — the receipt writer shared by the two Scout check scripts.
 *
 * WHY THIS EXISTS
 * ---------------
 * `check_assistant.js` and `check_assistant_http.js` both print several hundred
 * assertions to a terminal and then exit. That is the right output for the person
 * running them and the wrong output for everyone else: a supervisor reading the
 * report months later has no terminal, and "it printed PASS 280/280 on my machine"
 * is a claim, not evidence.
 *
 * So both scripts accept `--evidence` and, when given it, write what they just
 * proved into `doc/scout_evidence.md` — every assertion under its section, the
 * transcript of the real turns, and the provenance needed to REGENERATE the same
 * document: the git commit, the model version the classifier was serving, the
 * spec fingerprints on both sides of the language boundary, and the one command
 * that produced it.
 *
 * Two scripts, one file, no clobbering: each owns a delimited block keyed by name,
 * so re-running either replaces only its own block and leaves the other's alone.
 * Running both gives the complete pack; running one gives an honestly partial one
 * that says so in its own header.
 *
 * WHAT IT DELIBERATELY DOES NOT RECORD
 * ------------------------------------
 * No credentials, and not even the `apiKeyFingerprint` that `/health` publishes —
 * the fingerprint is safe by construction, but this file is committed and the key
 * behind it is still awaiting rotation, so there is no reason to put a hash of it
 * in git. Connection details stay in `.env`. Nothing a user typed is recorded that
 * the script did not itself send.
 */
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const REPO = path.join(__dirname, '..', '..', '..', '..');
const DEFAULT_OUT = path.join(REPO, 'doc', 'scout_evidence.md');

/**
 * `--evidence` or `--evidence=some/other/path.md`, off unless asked for.
 *
 * `fallback` is the pack's own destination, so a script that owns a separate file
 * gets it from a bare `--evidence` and nobody has to type a path to obtain the
 * document the docs promise. An explicit `=path` still wins.
 */
function parseFlag(argv = process.argv.slice(2), fallback = DEFAULT_OUT) {
  const hit = argv.find((a) => a === '--evidence' || a.startsWith('--evidence='));
  if (!hit) return { on: false, out: fallback };
  const eq = hit.indexOf('=');
  return { on: true, out: eq === -1 ? fallback : path.resolve(hit.slice(eq + 1)) };
}

/** The commit this evidence was produced from, and whether the tree was dirty. */
function gitInfo() {
  const run = (args) => execFileSync('git', args, { cwd: REPO, encoding: 'utf8' }).trim();
  try {
    const commit = run(['rev-parse', '--short', 'HEAD']);
    const subject = run(['log', '-1', '--pretty=%s']);
    const dirty = run(['status', '--porcelain']).split('\n').filter(Boolean).length;
    return { commit, subject, dirty };
  } catch {
    return { commit: 'unknown (git not available)', subject: '', dirty: null };
  }
}

/** Asia/Karachi wall clock, so the stamp matches the timezone every slot uses. */
function stamps() {
  const now = new Date();
  return {
    iso: now.toISOString(),
    pkt: new Intl.DateTimeFormat('en-CA', {
      timeZone: 'Asia/Karachi', dateStyle: 'medium', timeStyle: 'medium', hour12: false,
    }).format(now),
  };
}

/**
 * Fence a value so a stray pipe or newline cannot break the markdown table.
 *
 * The pipe becomes `&#124;` rather than a backslash escape: a backslash in a JS string
 * written by a shell heredoc is one round of escaping away from being eaten, and this
 * one silently was -- the first generated pack had five-column rows. An HTML entity
 * renders as a pipe and has no escaping to lose.
 */
const cell = (v) => (v === null || v === undefined ? '—'
  : String(v).replace(/\r?\n/g, ' ').replace(/\|/g, '&#124;').trim());

const MARK = (key, side, prefix = 'scout-evidence') => `<!-- ${prefix}:${key} ${side} -->`;

const HEADER = `# Scout — the evidence pack

**This file is generated. Do not edit it by hand.** Every line below was written by a
verification script that had just asserted it against the running system, and each block
records the commit, the model version and the command that produced it. To regenerate:

\`\`\`
cd backend && npm run evidence      # both blocks, in order

# or one at a time:
node src/scripts/check_assistant.js      --evidence   # the service layer, in one rolled-back transaction
node src/scripts/check_assistant_http.js --evidence   # the same assistant over real Express, with real JWTs
\`\`\`

Each script owns one block and rewrites only its own, so the two can be run in either
order, or separately. A block absent from this file was not run — it is not a pass.
`;

/**
 * A recorder. Off by default and cheap when off: every method is a no-op, so the
 * calls can sit in the harness permanently without a flag check at each site.
 */
function recorder({
  key, title, subtitle = '', command, argv,
  out = DEFAULT_OUT, header = HEADER, markPrefix = 'scout-evidence',
} = {}) {
  const flag = parseFlag(argv, out);
  const rec = {
    on: flag.on,
    out: flag.out,
    key,
    markPrefix,
    lines: [],       // the assertion ledger, in the order the run made them
    meta: [],        // provenance rows: [label, value]
    facts: [],       // headline numbers a reader should not have to hunt for
    turns: [],       // the conversation, as sent and as answered
    current: null,
  };
  if (!flag.on) {
    const noop = () => rec;
    return Object.assign(rec, {
      section: noop, pass: noop, fail: noop, skip: noop,
      note: noop, addMeta: noop, addFact: noop, turn: noop,
      write: async () => null,
    });
  }
  Object.assign(rec, {
    section(name) { rec.current = name; rec.lines.push({ kind: 'section', name }); return rec; },
    pass(label) { rec.lines.push({ kind: 'pass', label }); return rec; },
    fail(label, detail) { rec.lines.push({ kind: 'fail', label, detail }); return rec; },
    skip(label, why) { rec.lines.push({ kind: 'skip', label, why }); return rec; },
    note(text) { rec.lines.push({ kind: 'note', text }); return rec; },
    addMeta(label, value) { rec.meta.push([label, value]); return rec; },
    addFact(label, value) { rec.facts.push([label, value]); return rec; },
    turn(t) { rec.turns.push(t); return rec; },
    write: (totals) => write(rec, { key, title, subtitle, command, totals, header }),
  });
  return rec;
}

/** Render one recorder's block: provenance, headline facts, the ledger, the turns. */
function render(rec, { title, subtitle, command, totals }) {
  const g = gitInfo();
  const s = stamps();
  const t = totals || {};
  const total = (t.passed || 0) + (t.failed || 0);
  const verdict = t.failed ? `**FAIL ${t.passed}/${total}**` : `**PASS ${t.passed}/${total}**`;
  const out = [];
  out.push(`## ${title}`, '');
  if (subtitle) out.push(subtitle, '');
  out.push(`${verdict}${t.skipped ? ` · ${t.skipped} skipped` : ' · 0 skipped'}`
    + ` · produced ${s.pkt} PKT (${s.iso})`, '');
  out.push('| provenance | value |', '|---|---|');
  out.push(`| command | \`${cell(command)}\` |`);
  out.push(`| commit | \`${cell(g.commit)}\`${g.subject ? ` — ${cell(g.subject)}` : ''}`
    + `${g.dirty ? ` · **${g.dirty} uncommitted path(s) in the tree**` : ''} |`);
  out.push(`| node | ${cell(process.version)} on ${cell(process.platform)} |`);
  for (const [k, v] of rec.meta) out.push(`| ${cell(k)} | ${cell(v)} |`);
  out.push('');
  if (rec.facts.length) {
    out.push('### What this run establishes', '');
    for (const [k, v] of rec.facts) out.push(`- **${k}** — ${v}`);
    out.push('');
  }
  out.push('### Every assertion, in the order it was made');
  for (const l of rec.lines) {
    if (l.kind === 'section') { out.push('', `**${l.name}**`, ''); continue; }
    if (l.kind === 'pass') { out.push(`- ✓ ${l.label}`); continue; }
    if (l.kind === 'fail') { out.push(`- ✗ **${l.label}**${l.detail ? ` → ${l.detail}` : ''}`); continue; }
    if (l.kind === 'skip') { out.push(`- ~ ${l.label} — *skipped: ${l.why}*`); continue; }
    if (l.kind === 'note') out.push(`  > ${l.text}`);
  }
  out.push('');
  if (rec.turns.length) {
    out.push(`### The ${rec.turns.length} turn${rec.turns.length === 1 ? '' : 's'} this run actually drove`, '');
    out.push('| said to Scout | intent | conf | source | what Scout said back |', '|---|---|---|---|---|');
    for (const x of rec.turns) {
      out.push(`| ${cell(x.said)} | ${cell(x.intent || 'chip')} | ${cell(x.conf)} `
        + `| ${cell(x.source)} | ${cell(x.said_back)} |`);
    }
    out.push('');
  }
  return out.join('\n');
}

/**
 * Upsert the block, idempotently.
 *
 * The markers are HTML comments, so they are invisible in a rendered view and
 * unambiguous to find. A block that is already there is REPLACED between its own
 * markers; a new one is appended. The header is written only when the file does not
 * exist yet, so a hand-added note above the blocks would survive — though the file
 * says not to add one.
 */
function write(rec, opts) {
  const body = render(rec, opts);
  const block = `${MARK(rec.key, 'BEGIN', rec.markPrefix)}\n\n${body}\n${MARK(rec.key, 'END', rec.markPrefix)}\n`;
  let doc = '';
  try {
    doc = fs.readFileSync(rec.out, 'utf8');
  } catch {
    doc = `${opts.header || HEADER}\n`;
  }
  const b = MARK(rec.key, 'BEGIN', rec.markPrefix);
  const e = MARK(rec.key, 'END', rec.markPrefix);
  const i = doc.indexOf(b);
  const j = doc.indexOf(e);
  if (i !== -1 && j > i) {
    doc = doc.slice(0, i) + block + doc.slice(j + e.length + 1);
  } else {
    doc = `${doc.replace(/\s*$/, '')}\n\n${block}`;
  }
  fs.mkdirSync(path.dirname(rec.out), { recursive: true });
  fs.writeFileSync(rec.out, doc, 'utf8');
  return { path: rec.out, bytes: Buffer.byteLength(doc, 'utf8'), lines: doc.split('\n').length };
}

module.exports = { recorder, parseFlag, DEFAULT_OUT };
