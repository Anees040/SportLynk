/**
 * disputeService.js — S.7 Wave D · FR10.6 / FR10.7. The queue, the case file, and
 * the ruling.
 *
 * Why a service and not SQL in the route
 * A ruling is the single most consequential write an admin can make: it moves two
 * ratings, can advance a bracket, closes a dispute, notifies four captains and
 * leaves an audit row — all of which must be one transaction or none of it. The
 * route's job is `BEGIN`, the HTTP shape and `emitAfterCommit`; everything that
 * has to be atomic lives here, in one function, where it can be read end to end.
 *
 * The rule this file obeys: the same path as `POST /api/matches/:id/verify`
 * `mc.lockMatch` → scoreline → `elo` inside the transaction → status/verified_by
 * → `tournaments.advanceAfterMatch` unconditionally → `mc.fanOut` → COMMIT →
 * `mc.emitAfterCommit`. Not a parallel implementation: a second way to finish a
 * match is a second way to get it wrong, and the two would drift the first time
 * either was touched.
 *
 * WHERE it DEPARTS from the PLAN, and why
 * The plan says a ruling should "refuse if `elo_applied` is already true". It
 * cannot: `POST /api/matches/:id/dispute` deliberately accepts a dispute against
 * an already-verified match and defers it here, saying the rating "stands until an
 * admin resolves it (S.7)". Refusing would make that entire class of dispute
 * unrulable and leave `matches.winner_team` permanently contradicting `teams.elo`.
 * The operative word in that comment is silently — it objects to an unexplained
 * reversal, not to an audited one. So an already-rated match is corrected through
 * `elo.correctResult`, which writes `admin_reversal` + `admin_ruling` rows and
 * leaves the ledger readable as: rated, undone, re-rated.
 *
 * That correction needs the two labels from `migrations/021_dispute_ruling_labels.sql`.
 * Until it is applied, `elo.supportsCorrection` is false and only that one branch
 * refuses — with a message naming the migration, rather than a 23514 from inside a
 * half-finished transaction. Every other ruling works today.
 */
const elo = require('../utils/elo');
const mc = require('../utils/matchCore');
const chat = require('../utils/chatCore');
const settings = require('../utils/globalSettings');
const tournaments = require('./tournamentService');
const adminAudit = require('../utils/adminAudit');

/** The five things an admin can decide. */
const ACTION = Object.freeze({
  CHALLENGER: 'rule_challenger',
  OPPONENT: 'rule_opponent',
  DRAW: 'rule_draw',
  CUSTOM: 'rule_custom',
  DISMISS: 'dismiss',
});

/** action → `disputes.ruling`, whose CHECK accepts exactly these five. */
const RULING = Object.freeze({
  [ACTION.CHALLENGER]: 'challenger',
  [ACTION.OPPONENT]: 'opponent',
  [ACTION.DRAW]: 'draw',
  [ACTION.CUSTOM]: 'custom',
  [ACTION.DISMISS]: 'dismissed',
});

const PAGE_MAX = 50;
const RE_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Uniform refusal, shaped so a route can `return bad(res, r.status, r.message)`. */
const fail = (status, message, code = null) => ({ ok: false, status, message, code });

/** pg returns decimal/BIGINT as strings; a rating that arrives as "1032" is a bug. */
function n(v, d = 0) {
  const x = typeof v === 'number' ? v : Number.parseFloat(String(v));
  return Number.isFinite(x) ? x : d;
}

function intOrNull(v) {
  if (v === null || v === undefined || v === '') return null;
  const x = Number.parseInt(String(v), 10);
  return Number.isFinite(x) ? x : null;
}

/**
 * How much rating this dispute is holding hostage — the triage number.
 *
 * The interesting quantity is not the delta of the recorded outcome but the
 * biggest movement still in play, so a 1200 vs 900 upset (where the favourite
 * stands to lose ~29 at K=32) outranks an even match (16) in the queue. Computed
 * from the pure `elo.rate` at the live K, so it is the same arithmetic the ruling
 * itself will run, and it costs no query.
 */
function severityFor({ ratingChallenger, ratingOpponent, kFactor }) {
  const win = elo.rate({ ratingChallenger, ratingOpponent, scoreChallenger: 1, kFactor });
  const loss = elo.rate({ ratingChallenger, ratingOpponent, scoreChallenger: 0, kFactor });
  return Math.max(Math.abs(win.challenger.delta), Math.abs(loss.challenger.delta));
}

// The queue

/**
 * Every column both the queue and the case file need about a dispute. One string,
 * used by both, so a field added for the detail screen cannot go missing from the
 * list screen (or worse, be shaped differently by two near-identical SELECTs).
 */
const QUEUE_SELECT = `SELECT d.id, d.match_id, d.raised_by_team, d.reason, d.status, d.created_at,
            d.severity_elo, d.ruling, d.resolution_notes, d.resolved_at,
            d.ruled_score_challenger, d.ruled_score_opponent,
            m.status AS match_status, m.elo_applied, m.winner_team, m.sport,
            m.score_challenger, m.score_opponent, m.tournament_id,
            m.challenger_team, m.opponent_team, m.booking_id,
            ct.name AS ct_name, ct.logo_url AS ct_logo, ct.elo AS ct_elo,
            ct.elo_frozen AS ct_frozen,
            ot.name AS ot_name, ot.logo_url AS ot_logo, ot.elo AS ot_elo,
            ot.elo_frozen AS ot_frozen,
            rt.name AS raiser_name,
            rc.name AS raiser_captain,
            tr.name AS tournament_name,
            (SELECT count(*)::int FROM match_results mr WHERE mr.match_id = m.id) AS results_in,
            (SELECT count(*)::int FROM disputes d2
              WHERE d2.match_id = d.match_id AND d2.status = 'open') AS open_on_match,
            ru.name AS resolved_by_name
       FROM disputes d
       JOIN matches m  ON m.id = d.match_id
       JOIN teams   ct ON ct.id = m.challenger_team
       JOIN teams   ot ON ot.id = m.opponent_team
       LEFT JOIN teams rt ON rt.id = d.raised_by_team
       LEFT JOIN users rc ON rc.id = rt.captain_id
       LEFT JOIN users ru ON ru.id = d.resolved_by
       LEFT JOIN tournaments tr ON tr.id = m.tournament_id
`;

/**
 * GET-side: the disputes an admin has to work through.
 *
 * Ordered severity-first, then oldest-first, which is what `idx_disputes_queue
 * (severity_elo DESC NULLS LAST, created_at) WHERE status = 'open'` was created
 * for. `severity_elo` is stamped when the dispute is raised, so the order is
 * stable while an admin pages through it; the live recomputation below is only
 * used to fill in a row raised before that stamp existed.
 *
 * `raised_by_team` is a TEAM, not a user — the table records which side filed,
 * and that is deliberate (a captaincy can change before an admin looks at it). So
 * the queue names the team and, separately, whoever captains it now.
 */
async function queue(db, { status = 'open', cursor = '', limit = 25 } = {}) {
  const lim = Math.min(Math.max(intOrNull(limit) || 25, 1), PAGE_MAX);
  const wanted = ['open', 'resolved', 'dismissed', 'all'].includes(status) ? status : 'open';

  const params = [];
  const where = [];
  if (wanted !== 'all') {
    params.push(wanted);
    where.push(`d.status = $${params.length}`);
  }
  // Cursor is `<severity>~<created_at>~<id>`. The sort mixes DESC and ASC, so a
  // row-value comparison cannot express it; the explicit or form can.
  if (String(cursor || '').includes('~')) {
    const [sev, ts, id] = String(cursor).split('~');
    if (RE_UUID.test(id || '')) {
      params.push(intOrNull(sev) ?? -1, ts, id);
      const p = params.length;
      where.push(`(COALESCE(d.severity_elo, -1) < $${p - 2}::int
                   OR (COALESCE(d.severity_elo, -1) = $${p - 2}::int
                       AND (d.created_at, d.id) > ($${p - 1}::timestamptz, $${p}::uuid)))`);
    }
  }
  params.push(lim + 1);

  const { rows } = await db.query(
    `${QUEUE_SELECT}
      ${where.length ? `WHERE ${where.join(' AND ')}` : ''}
      ORDER BY COALESCE(d.severity_elo, -1) DESC, d.created_at ASC, d.id ASC
      LIMIT $${params.length}`,
    params,
  );

  const { kFactor } = await settings.elo({ client: db });
  const page = rows.slice(0, lim);
  const items = page.map((r) => shapeQueueRow(r, kFactor));
  const last = page[page.length - 1];
  return {
    ok: true,
    items,
    nextCursor: rows.length > lim && last
      ? `${n(last.severity_elo, -1)}~${new Date(last.created_at).toISOString()}~${last.id}`
      : null,
  };
}

/** One queue row, camelCased, with the numbers already numbers. */
function shapeQueueRow(r, kFactor) {
  const cElo = Math.round(n(r.ct_elo, 1000));
  const oElo = Math.round(n(r.ot_elo, 1000));
  const severity = r.severity_elo === null || r.severity_elo === undefined
    ? severityFor({ ratingChallenger: cElo, ratingOpponent: oElo, kFactor })
    : intOrNull(r.severity_elo);
  const raisedBy = String(r.raised_by_team || '');
  return {
    id: r.id,
    matchId: r.match_id,
    status: r.status,
    reason: r.reason || null,
    createdAt: r.created_at,
    ageHours: Math.max(0, Math.round((Date.now() - new Date(r.created_at).getTime()) / 36e5)),
    severityElo: severity,
    // Both teams disputed the same match: worth showing, because a ruling closes
    // both and the admin should not go looking for the second one afterwards.
    bothSidesDisputed: intOrNull(r.open_on_match) > 1,
    ruling: r.ruling || null,
    resolutionNotes: r.resolution_notes || null,
    resolvedAt: r.resolved_at || null,
    resolvedByName: r.resolved_by_name || null,
    ruledScore: r.ruled_score_challenger === null ? null : {
      challenger: intOrNull(r.ruled_score_challenger),
      opponent: intOrNull(r.ruled_score_opponent),
    },
    match: {
      status: r.match_status,
      sport: r.sport,
      eloApplied: r.elo_applied === true,
      resultsIn: intOrNull(r.results_in) || 0,
      scoreline: mc.scoreline(r.score_challenger, r.score_opponent),
      winnerTeam: r.winner_team || null,
      tournamentId: r.tournament_id || null,
      tournamentName: r.tournament_name || null,
      isFixture: Boolean(r.tournament_id),
    },
    challenger: {
      id: r.challenger_team, name: r.ct_name, logoUrl: r.ct_logo,
      elo: cElo, frozen: r.ct_frozen === true,
      raisedThis: raisedBy === String(r.challenger_team),
    },
    opponent: {
      id: r.opponent_team, name: r.ot_name, logoUrl: r.ot_logo,
      elo: oElo, frozen: r.ot_frozen === true,
      raisedThis: raisedBy === String(r.opponent_team),
    },
    raisedBy: {
      teamId: r.raised_by_team || null,
      teamName: r.raiser_name || null,
      captainName: r.raiser_captain || null,
    },
  };
}

// The case file — FR10.6

/**
 * Everything an admin needs to rule without leaving the screen.
 *
 * FR10.6 asks for the two submissions, the evidence and the chat log. The
 * expensive-looking part — the captain-channel archive — is a plain indexed read
 * of `chat_messages` for the one channel Wave B creates per match, which is the
 * reason Wave B was sequenced before Wave D: without it this requirement has no
 * data to satisfy it.
 *
 * Read-only, and deliberately on the pool rather than in a transaction: nothing
 * here writes, and holding a transaction open while an admin reads is how an
 * idle-in-transaction lock ends up sitting on a match row.
 */
async function caseFile(db, disputeId) {
  if (!RE_UUID.test(String(disputeId || ''))) return fail(400, 'Invalid dispute id.');

  const head = await db.query(`${QUEUE_SELECT} WHERE d.id = $1`, [disputeId]);
  if (!head.rows.length) return fail(404, 'Dispute not found.');
  const { kFactor } = await settings.elo({ client: db });
  const row = head.rows[0];
  const shaped = shapeQueueRow(row, kFactor);
  const matchId = row.match_id;
  const teamIds = [row.challenger_team, row.opponent_team];

  // The two submissions, side by side
  // `UNIQUE (match_id, submitted_by_team)` guarantees at most one per team, so
  // "side by side" is a real two-column layout and not a list that might have
  // three entries. Where they disagree is the whole dispute, so it is computed
  // here rather than left to the client to diff.
  const subs = await db.query(
    `SELECT mr.submitted_by_team, mr.winner_team, mr.score_challenger,
            mr.score_opponent, mr.created_at, t.name AS team_name,
            u.name AS captain_name
       FROM match_results mr
       LEFT JOIN teams t ON t.id = mr.submitted_by_team
       LEFT JOIN users u ON u.id = t.captain_id
      WHERE mr.match_id = $1`,
    [matchId],
  );
  const subFor = (teamId) => {
    const s = subs.rows.find((x) => String(x.submitted_by_team) === String(teamId));
    if (!s) return null;
    return {
      teamId: s.submitted_by_team,
      teamName: s.team_name || null,
      captainName: s.captain_name || null,
      submittedAt: s.created_at,
      scoreChallenger: intOrNull(s.score_challenger),
      scoreOpponent: intOrNull(s.score_opponent),
      winnerTeam: s.winner_team || null,
      scoreline: mc.scoreline(s.score_challenger, s.score_opponent),
    };
  };
  const subC = subFor(row.challenger_team);
  const subO = subFor(row.opponent_team);
  const agree = Boolean(subC && subO
    && subC.scoreChallenger === subO.scoreChallenger
    && subC.scoreOpponent === subO.scoreOpponent);

  // Both rosters, with the trust score that is the other half of the story
  // `trust_score` lives on `player_profiles`, not on `users` — and the join has to be
  // a left one, because a profile row is created lazily by `recomputeTrust` on the
  // first booking or review. A captain who has never been rated has no row at all,
  // and an INNER join would silently drop that whole side of the roster out of the
  // case file: the admin would rule on a four-a-side with three players listed.
  const roster = await db.query(
    `SELECT tm.team_id, tm.role, u.id AS user_id, u.name, u.avatar_url,
            pp.trust_score, u.is_active
       FROM team_members tm
       JOIN users u ON u.id = tm.user_id
       LEFT JOIN player_profiles pp ON pp.user_id = u.id
      WHERE tm.team_id = ANY($1::uuid[])
      ORDER BY tm.team_id,
               CASE tm.role WHEN 'captain' THEN 0 WHEN 'vice_captain' THEN 1 ELSE 2 END,
               lower(u.name)`,
    [teamIds.map(String)],
  );
  const rosterFor = (teamId) => roster.rows
    .filter((r) => String(r.team_id) === String(teamId))
    .map((r) => ({
      userId: r.user_id,
      name: r.name,
      avatarUrl: r.avatar_url || null,
      role: r.role,
      trustScore: r.trust_score === null ? null : n(r.trust_score),
      suspended: r.is_active === false,
    }));

  // The booking: when, where, and what the owner recorded
  // `checked_in_at` is stamped by the QR scan, so its presence is the strongest
  // evidence in the file that the match was played at all — an admin ruling on a
  // match nobody checked in to is ruling on a match that may not have happened.
  const bk = !row.booking_id ? { rows: [] } : await db.query(
    `SELECT b.id, b.slot_date, b.start_time, b.end_time, b.status,
            b.checked_in_at, b.no_show_at, b.total_amount, b.deposit_amount,
            b.cancellation_reason, b.qr_code IS NOT NULL AS had_qr,
            v.id AS venue_id, v.name AS venue_name, v.city AS venue_city,
            vo.id AS owner_id, vo.name AS owner_name, vo.phone AS owner_phone
       FROM bookings b
       JOIN venues v ON v.id = b.venue_id
       LEFT JOIN users vo ON vo.id = v.owner_id
      WHERE b.id = $1`,
    [row.booking_id],
  );
  const b0 = bk.rows[0] || null;

  // The captain-channel archive (FR10.6)
  // Capped and oldest-first: an admin reads an argument forwards. Tombstones are
  // included as such — "this message was deleted" is itself evidence, and hiding
  // it would let a captain edit the record an admin is about to rule on.
  const chanId = await chat.captainChannelId(db, matchId).catch(() => null);
  let archive = [];
  if (chanId) {
    const msgs = await db.query(
      `SELECT cm.id, cm.sender_id, cm.body, cm.kind, cm.is_system, cm.created_at,
              cm.deleted_at, cm.media_url, cm.media_mime, u.name AS sender_name,
              tm.team_id
         FROM chat_messages cm
         LEFT JOIN users u ON u.id = cm.sender_id
         LEFT JOIN LATERAL (
           SELECT tm2.team_id FROM team_members tm2
            WHERE tm2.user_id = cm.sender_id AND tm2.team_id = ANY($2::uuid[])
            LIMIT 1
         ) tm ON TRUE
        WHERE cm.channel_id = $1
        ORDER BY cm.created_at ASC
        LIMIT 400`,
      [chanId, teamIds.map(String)],
    );
    archive = msgs.rows.map((m2) => ({
      id: m2.id,
      senderId: m2.sender_id || null,
      senderName: m2.is_system ? null : (m2.sender_name || null),
      // Which side said it. The room holds both teams, and "who is arguing what"
      // is unreadable without it.
      teamId: m2.team_id || null,
      system: m2.is_system === true,
      kind: m2.kind || 'text',
      body: m2.deleted_at ? null : (m2.body || null),
      deleted: Boolean(m2.deleted_at),
      hasMedia: Boolean(m2.media_url),
      mediaMime: m2.media_mime || null,
      createdAt: m2.created_at,
    }));
  }

  // What was already applied, if anything
  // The admin has to know whether they are rating a match or correcting one, and
  // whether a correction is even possible on this database yet.
  const hist = await db.query(
    `SELECT eh.team_id, eh.elo_before, eh.elo_after, eh.elo_delta, eh.k_factor,
            eh.reason, eh.created_at, t.name AS team_name
       FROM elo_history eh
       LEFT JOIN teams t ON t.id = eh.team_id
      WHERE eh.match_id = $1
      ORDER BY eh.created_at ASC`,
    [matchId],
  );
  const correctable = await elo.supportsCorrection(db).catch(() => false);

  const others = await db.query(
    `SELECT d.id, d.raised_by_team, d.status, d.reason, d.created_at, t.name AS team_name
       FROM disputes d LEFT JOIN teams t ON t.id = d.raised_by_team
      WHERE d.match_id = $1 AND d.id <> $2
      ORDER BY d.created_at`,
    [matchId, disputeId],
  );

  return {
    ok: true,
    dispute: shaped,
    submissions: { challenger: subC, opponent: subO, agree, count: subs.rows.length },
    rosters: {
      challenger: rosterFor(row.challenger_team),
      opponent: rosterFor(row.opponent_team),
    },
    booking: b0 ? {
      id: b0.id,
      slotDate: b0.slot_date,
      startTime: b0.start_time,
      endTime: b0.end_time,
      status: b0.status,
      checkedInAt: b0.checked_in_at || null,
      noShowAt: b0.no_show_at || null,
      hadQr: b0.had_qr === true,
      totalAmount: n(b0.total_amount),
      depositAmount: n(b0.deposit_amount),
      cancellationReason: b0.cancellation_reason || null,
      venue: { id: b0.venue_id, name: b0.venue_name, city: b0.venue_city },
      owner: { id: b0.owner_id, name: b0.owner_name, phone: b0.owner_phone },
    } : null,
    chat: { channelId: chanId, messages: archive, truncated: archive.length >= 400 },
    eloHistory: hist.rows.map((h) => ({
      teamId: h.team_id,
      teamName: h.team_name || null,
      before: intOrNull(h.elo_before),
      after: intOrNull(h.elo_after),
      delta: intOrNull(h.elo_delta),
      kFactor: n(h.k_factor),
      reason: h.reason,
      createdAt: h.created_at,
    })),
    // What the UI should offer. A ruling that flips an already-rated match needs
    // migration 021; saying so here means the button can be disabled with a real
    // explanation instead of failing on submit.
    capabilities: {
      needsCorrection: row.elo_applied === true,
      correctionAvailable: correctable === true,
      correctionBlockedBy: correctable ? null : 'migrations/021_dispute_ruling_labels.sql',
      canRule: shaped.status === 'open',
    },
    otherDisputes: others.rows.map((o) => ({
      id: o.id, teamId: o.raised_by_team, teamName: o.team_name || null,
      status: o.status, reason: o.reason || null, createdAt: o.created_at,
    })),
  };
}

// The RULING — FR10.7

/**
 * Rule on a dispute. Runs inside the caller's transaction and returns everything
 * the route needs to emit after commit.
 *
 * What the five ACTIONS mean
 * `rule_challenger` / `rule_opponent` adopt that TEAM'S own submission — the two
 * rows the case file shows side by side. That is a ruling about whose account of
 * the match is true, not about who wins: adopting the challenger's submission can
 * perfectly well record a draw, or even a challenger loss, because a captain can
 * submit a loss. `rule_draw` needs an equal scoreline (from the body, or from a
 * submission that is itself drawn) and never invents 0–0. `rule_custom` takes both
 * scores. `dismiss` changes no result at all and hands the match back to whoever
 * was supposed to finish it.
 *
 * A NOTE is mandatory. This is the one write in the app where a human overrides
 * two other humans, and `admin_audit.note` + `disputes.resolution_notes` are what
 * make that answerable six months later. It is also quoted to both captains, so
 * "why did my rating change?" has an answer that is not "an admin did something".
 */
async function rule(client, {
  disputeId, adminId, action,
  scoreChallenger = null, scoreOpponent = null, note = null,
}) {
  if (!RE_UUID.test(String(disputeId || ''))) return fail(400, 'Invalid dispute id.');
  if (!RE_UUID.test(String(adminId || ''))) return fail(401, 'Unauthorized.');
  if (!Object.values(ACTION).includes(action)) {
    return fail(400, `action must be one of ${Object.values(ACTION).join(', ')}.`);
  }
  // Capped here, once, so every later use is the stored text -- the audit note,
  // the pill detail and the push body must not be able to disagree.
  const ruleNote = String(note || '').trim().slice(0, 1000);
  if (ruleNote.length < 3) {
    return fail(400, 'A ruling needs a note explaining it — the teams are told what it says.');
  }

  // ── Lock the dispute, then the match. Always in that order: a second admin
  // ruling on the same dispute must queue behind this one, not race it.
  const dq = await client.query(
    `SELECT id, match_id, raised_by_team, status, reason, severity_elo
       FROM disputes WHERE id = $1 FOR UPDATE`,
    [disputeId],
  );
  if (!dq.rows.length) return fail(404, 'Dispute not found.');
  const d = dq.rows[0];
  if (d.status !== 'open') return fail(409, `This dispute is already ${d.status}.`);

  const m = await mc.lockMatch(client, d.match_id);
  if (!m) return fail(409, 'The match behind this dispute no longer exists.');

  // The ruled scoreline
  const rs = await client.query(
    `SELECT submitted_by_team, winner_team, score_challenger, score_opponent
       FROM match_results WHERE match_id = $1`,
    [d.match_id],
  );
  const subOf = (teamId) => rs.rows.find(
    (x) => String(x.submitted_by_team) === String(teamId),
  ) || null;

  let sc = null;
  let so = null;
  if (action !== ACTION.DISMISS) {
    if (action === ACTION.CHALLENGER || action === ACTION.OPPONENT) {
      const side = action === ACTION.CHALLENGER ? m.challenger_team : m.opponent_team;
      const s = subOf(side);
      if (!s) {
        return fail(409, 'That team never submitted a result, so there is nothing to '
          + 'adopt. Rule a custom scoreline instead.');
      }
      sc = intOrNull(s.score_challenger);
      so = intOrNull(s.score_opponent);
      if (sc === null || so === null) return fail(409, 'That submission has no scoreline.');
    } else if (action === ACTION.DRAW) {
      const bc = intOrNull(scoreChallenger);
      const bo = intOrNull(scoreOpponent);
      if (bc !== null && bo !== null) {
        if (bc !== bo) return fail(400, 'A drawn ruling needs an equal scoreline.');
        sc = bc; so = bo;
      } else {
        // Never invent 0–0: a fabricated scoreline in the record is worse than
        // asking the admin for the one they mean.
        const drawn = rs.rows.find((x) => intOrNull(x.score_challenger) !== null
          && intOrNull(x.score_challenger) === intOrNull(x.score_opponent));
        if (!drawn) {
          return fail(400, 'Neither team submitted a draw, so send the drawn scoreline '
            + 'you are ruling (equal scoreChallenger and scoreOpponent).');
        }
        sc = intOrNull(drawn.score_challenger);
        so = sc;
      }
    } else {
      sc = intOrNull(scoreChallenger);
      so = intOrNull(scoreOpponent);
      if (sc === null || so === null) {
        return fail(400, 'A custom ruling needs both scoreChallenger and scoreOpponent.');
      }
      if (sc < 0 || so < 0 || sc > 200 || so > 200) {
        return fail(400, 'Scores must be between 0 and 200.');
      }
    }
  }

  // Derived, never taken from the submission's own `winner_team`: one arithmetic
  // rule for who won means the row can never say 2–1 to a team that lost.
  const ruledWinner = action === ACTION.DISMISS ? m.winner_team
    : (sc > so ? m.challenger_team : (so > sc ? m.opponent_team : null));

  // Every open dispute on this match is settled by this one ruling
  // Both teams can file (`ux_disputes_match_team` allows one each). Ruling settles
  // the MATCH, so leaving the other side's dispute open would leave both ratings
  // frozen by a question that has already been answered.
  const closing = await client.query(
    `SELECT id, raised_by_team FROM disputes
      WHERE match_id = $1 AND status = 'open' ORDER BY created_at FOR UPDATE`,
    [d.match_id],
  );
  const closingIds = closing.rows.map((r) => r.id);

  // Unfreeze, before any rating moves
  // ER2.3's freeze notification promises "Ratings will not change until an admin
  // reviews your disputes". Reviewing them is what just happened, so a team with
  // no other open dispute is released — and released before the exchange, or a
  // team that was right about the scoreline would still gain nothing.
  //
  // Sorted by id for the same reason `elo.lockBothTeams` sorts: two rulings on
  // matches that share a team must take their row locks in the same order.
  const teamIds = [String(m.challenger_team), String(m.opponent_team)];
  const unfroze = [];
  const frozenNow = new Map();
  // Ratings as they stand before the exchange — which is exactly what severity
  // means (what was at stake when the dispute was filed), and `lockMatch` does not
  // join teams, so this pass is where they are read.
  const eloOf = new Map();
  for (const teamId of [...teamIds].sort()) {
    const { rows: tf } = await client.query(
      `SELECT t.elo_frozen, t.elo,
              (SELECT count(*)::int FROM disputes dd
                WHERE dd.raised_by_team = t.id AND dd.status = 'open'
                  AND dd.match_id <> $2) AS others
         FROM teams t WHERE t.id = $1`,
      [teamId, d.match_id],
    );
    const row = tf[0] || {};
    eloOf.set(teamId, row.elo);
    let stillFrozen = row.elo_frozen === true;
    if (stillFrozen && intOrNull(row.others) === 0) {
      await client.query(
        `UPDATE teams SET elo_frozen = FALSE, elo_frozen_reason = NULL, elo_frozen_at = NULL
          WHERE id = $1`,
        [teamId],
      );
      stillFrozen = false;
      unfroze.push(teamId);
    }
    frozenNow.set(teamId, stillFrozen);
  }

  // Was the previous application a FROZEN one?
  // `elo.applyResult` writes a `frozen_no_change` history row and returns
  // `frozen: true` when either team was frozen — the match is recorded as rated,
  // but no points moved. If the freeze is now lifted (which the pass above may
  // just have done), the honest thing is to re-rate even when the ruling agrees
  // with what both teams submitted: the exchange never happened.
  const nowFrozen = frozenNow.get(teamIds[0]) || frozenNow.get(teamIds[1]);
  let appliedFrozen = false;
  if (m.elo_applied) {
    const { rows: fr } = await client.query(
      `SELECT 1 FROM elo_history WHERE match_id = $1 AND reason = $2 LIMIT 1`,
      [d.match_id, elo.REASON.FROZEN],
    );
    appliedFrozen = fr.length > 0;
  }

  // K comes from the same two sources as the verify path
  // Live settings, overridden by the tournament's own K for a fixture. Read
  // through `settings.elo({ client })` so an admin who changed k_factor a minute
  // ago rules at the new value without a restart (FR10.11).
  const { base, kFactor } = await settings.elo({ client });
  const tctx = m.booking_id ? null : await tournaments.matchContext(client, d.match_id);
  const k = tctx && Number.isFinite(tctx.kFactor) ? tctx.kFactor : kFactor;

  const winnerChanged = String(m.winner_team || '') !== String(ruledWinner || '');
  let exchange = null;
  let eloMode = 'none';

  if (action !== ACTION.DISMISS) {
    if (!m.elo_applied) {
      // The ordinary case, and the one that needs no migration: the owner never
      // verified, so this is the first rating for the match and the plain
      // `applyResult` used by every other code path applies.
      exchange = await elo.applyResult(client, {
        matchId: d.match_id,
        challengerTeam: m.challenger_team,
        opponentTeam: m.opponent_team,
        winnerTeam: ruledWinner,
        base,
        kFactor: k,
      });
      eloMode = 'applied';
    } else if (winnerChanged || (appliedFrozen && !nowFrozen)) {
      // The hard case the plan did not anticipate. Points are already banked
      // against an outcome an admin has just overturned. Refusing here would
      // leave `matches.winner_team` permanently contradicting `teams.elo`, so
      // instead the earlier exchange is reversed against the current rating and
      // the ruled one applied — two audited `elo_history` rows each, never an
      // UPDATE over history.
      if (!(await elo.supportsCorrection(client))) {
        return fail(409,
          'This match is already rated, so overturning it needs the correction '
          + 'labels from migrations/021_dispute_ruling_labels.sql. Run '
          + '`node run_migration_021.js`, then rule again.',
          'correction_unavailable');
      }
      exchange = await elo.correctResult(client, {
        matchId: d.match_id,
        challengerTeam: m.challenger_team,
        opponentTeam: m.opponent_team,
        previousWinnerTeam: m.winner_team,
        winnerTeam: ruledWinner,
        base,
        kFactor: k,
      });
      eloMode = 'corrected';
    } else {
      // Already rated, and the ruling agrees with the rating. Moving anything
      // here would be a double-apply — the one mistake nobody can detect after
      // the fact — so the ruling is recorded and the ladder is left alone.
      eloMode = 'unchanged';
    }
  }

  // The match row
  // A ruling is a verification by SportLynk: same columns, same latch, so every
  // reader downstream (match centre, team stats, the recommender's features) sees
  // one shape whether an owner or an admin settled it. `verified_by` is the admin,
  // which is also how the case file later shows who ruled.
  if (action === ACTION.DISMISS) {
    // Nothing is overturned: the submissions stand. A match that was never rated
    // goes back to the owner's queue; one already rated stays completed, because
    // the rating is the thing that made it final.
    await client.query(
      `UPDATE matches SET status = $2, updated_at = now() WHERE id = $1`,
      [d.match_id, m.elo_applied ? mc.STATUS.COMPLETED : mc.STATUS.AWAITING_OWNER],
    );
  } else {
    await client.query(
      `UPDATE matches
          SET score_challenger = $2, score_opponent = $3, winner_team = $4,
              status = $5, verified_by = $6, verified_at = now(),
              elo_applied = TRUE, updated_at = now()
        WHERE id = $1`,
      [d.match_id, sc, so, ruledWinner, mc.STATUS.COMPLETED, adminId],
    );
  }

  // The bracket
  // Unconditional, exactly as in the verify path: a friendly answers
  // `not_tournament` and touches nothing. `already_settled` is the honest answer
  // for a fixture whose winner already advanced — this ruling does not rewrite a
  // bracket that has moved on, and the caller is told so rather than being left to
  // assume it did.
  let advance = { ok: true, code: 'skipped', data: {} };
  if (action !== ACTION.DISMISS) {
    advance = await tournaments.advanceAfterMatch(client, d.match_id);
    if (!advance.ok) {
      return fail(advance.status || 409,
        advance.message || 'The ruling could not be applied to the bracket.',
        advance.code || 'bracket');
    }
  }

  // The dispute rows
  // `severity_elo` is stamped here too, not only at raise time, so a row filed
  // before that column existed still records what was at stake when it was ruled.
  const ruling = RULING[action];
  const sev = severityFor({
    ratingChallenger: n(eloOf.get(teamIds[0]), base),
    ratingOpponent: n(eloOf.get(teamIds[1]), base),
    kFactor: k,
  });
  await client.query(
    `UPDATE disputes
        SET status = $2, ruling = $3, resolution_notes = $4, resolved_by = $5,
            resolved_at = now(), ruled_score_challenger = $6, ruled_score_opponent = $7,
            severity_elo = COALESCE(severity_elo, $8)
      WHERE id = ANY($1::uuid[])`,
    [closingIds, action === ACTION.DISMISS ? 'dismissed' : 'resolved', ruling,
      ruleNote, adminId, action === ACTION.DISMISS ? null : sc,
      action === ACTION.DISMISS ? null : so, sev],
  );

  // Telling everyone, in the room where they argued about it
  // Two audiences, two wordings. Each team's own chat gets a sentence naming the
  // opponent ("...against the Titans"); the captain room — which holds both teams —
  // gets one neutral sentence, because a per-team wording there would tell half the
  // readers the opposite of what happened.
  const features = await mc.teamFeatures(client, [m.challenger_team, m.opponent_team]);
  const cName = features.get(String(m.challenger_team))?.name || 'the challenger';
  const oName = features.get(String(m.opponent_team))?.name || 'the opponent';

  const line = action === ACTION.DISMISS
    ? mc.scoreline(m.score_challenger, m.score_opponent)
    : mc.scoreline(sc, so);
  const neutral = action === ACTION.DISMISS
    ? 'the original result stands'
    : `${cName} ${line} ${oName}`;

  const wordFor = (teamId) => {
    if (action === ACTION.DISMISS) return null;
    if (ruledWinner === null) return 'draw';
    return String(ruledWinner) === String(teamId) ? 'win' : 'loss';
  };
  const sideOf = (teamId) => {
    if (!exchange) return null;
    return String(teamId) === String(m.challenger_team)
      ? exchange.challenger : exchange.opponent;
  };
  // What the captain is owed: the ruled line, whether it went their way,
  // and what it did to their rating — including the two honest non-answers
  // ("frozen", "no change") rather than a silent omission.
  const detailFor = (teamId) => {
    if (action === ACTION.DISMISS) return 'dispute dismissed, the original result stands';
    const head = `${line} (${wordFor(teamId)})`;
    const side = sideOf(teamId);
    if (eloMode === 'unchanged') return `${head} — rating already applied, no change`;
    if (!side) return head;
    if (exchange.frozen) return `${head} — rating frozen, no change`;
    return `${head}, ${mc.signed(side.delta)} ELO → ${side.after}`;
  };

  const sides = [m.challenger_team, m.opponent_team].map((teamId) => ({
    teamId,
    otherTeamName: String(teamId) === String(m.challenger_team) ? oName : cName,
    event: 'match_ruled_team',
    detail: detailFor(teamId),
    // Captains only. A ruling is a captain's problem to explain to their squad,
    // and notifying eleven people about a scoreline they cannot contest is the
    // fastest way to teach them to mute the app.
    notify: {
      type: 'dispute_resolved',
      title: action === ACTION.DISMISS ? 'Dispute dismissed' : 'Dispute resolved',
      body: `${detailFor(teamId)}. SportLynk: ${ruleNote}`,
      extra: { disputeId, ruling },
    },
  }));

  const { pills, memberIds } = await mc.fanOut(client, {
    matchId: d.match_id,
    sides,
    coord: { event: 'match_ruled', detail: neutral },
  });

  // The audit row
  // `before` is the match as it was found, `after` what this ruling made of it —
  // enough to answer "who overturned this, and what did they overturn?" from SQL
  // alone, which is the whole point of the table. Never throws (see adminAudit).
  await adminAudit.audit(client, {
    adminId,
    action: action === ACTION.DISMISS
      ? adminAudit.ACTIONS.DISPUTE_DISMISS : adminAudit.ACTIONS.DISPUTE_RULE,
    entityType: 'dispute',
    entityId: disputeId,
    before: {
      matchId: d.match_id,
      status: m.status,
      scoreChallenger: intOrNull(m.score_challenger),
      scoreOpponent: intOrNull(m.score_opponent),
      winnerTeam: m.winner_team,
      eloApplied: m.elo_applied === true,
      disputeStatus: d.status,
      // Both submissions verbatim. If a later ruling is questioned, the trail has
      // to hold what the teams claimed, not only what the admin chose.
      submissions: rs.rows.map((x) => ({
        teamId: x.submitted_by_team,
        scoreChallenger: intOrNull(x.score_challenger),
        scoreOpponent: intOrNull(x.score_opponent),
      })),
    },
    after: {
      action,
      ruling,
      scoreChallenger: action === ACTION.DISMISS ? intOrNull(m.score_challenger) : sc,
      scoreOpponent: action === ACTION.DISMISS ? intOrNull(m.score_opponent) : so,
      winnerTeam: ruledWinner,
      eloMode,
      severityElo: sev,
      challengerDelta: exchange ? exchange.challenger.delta : 0,
      opponentDelta: exchange ? exchange.opponent.delta : 0,
      frozen: exchange ? exchange.frozen === true : null,
      unfroze,
      bracket: advance.code || null,
      closedDisputes: closingIds.length,
    },
    note: ruleNote,
  });

  return {
    ok: true,
    disputeId,
    matchId: d.match_id,
    action,
    ruling,
    scoreline: { challenger: action === ACTION.DISMISS ? intOrNull(m.score_challenger) : sc,
      opponent: action === ACTION.DISMISS ? intOrNull(m.score_opponent) : so },
    winnerTeam: ruledWinner,
    status: action === ACTION.DISMISS
      ? (m.elo_applied ? mc.STATUS.COMPLETED : mc.STATUS.AWAITING_OWNER)
      : mc.STATUS.COMPLETED,
    eloMode,
    exchange,
    severityElo: sev,
    unfroze,
    closed: closingIds.length,
    // `already_settled` here means the bracket had moved past this fixture before
    // the ruling landed: the rating is corrected, the bracket is not rewritten.
    // Surfaced rather than hidden so the route can say so out loud.
    bracket: advance.code || null,
    advanced: !!(advance.data && advance.data.advanced),
    // For the route to hand to `mc.emitAfterCommit` after it commits.
    pills,
    memberIds,
  };
}

module.exports = { queue, caseFile, rule, severityFor, ACTION, RULING, PAGE_MAX };
