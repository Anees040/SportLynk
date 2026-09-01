/**
 * The grey pills in the middle of a group chat.
 *
 * "Ali added Sara", "Sara left", "Ali is now an admin" — WhatsApp writes these
 * into the thread itself rather than hiding them in a settings log, and that is
 * the single biggest reason a group chat feels trustworthy: every membership
 * change is visible to everyone, in order, forever. A team where the captain can
 * quietly remove someone is a team that argues about what happened.
 *
 * Why a separate file
 * Two different callers need these: routes/teams.js (roster changes) and
 * routes/chat.js (group name/icon changes). Keeping the sentences here means
 * "removed" is worded identically no matter which endpoint caused it.
 *
 * Why the sentence is stored, not just the event
 * `body` holds a complete third-person sentence, so anything that only knows how
 * to show text — a push notification, the chat-list preview, an older build of
 * the app — renders something correct with zero logic. `system_meta` carries the
 * same facts structured, so the app can bold the names and substitute "You" for
 * the viewer, the way WhatsApp does. Neither is derivable from the other cheaply,
 * and the duplication is a few dozen bytes on a row that is written once.
 */

const ROLE_TEXT = {
  captain: 'captain',
  vice_captain: 'vice captain',
  member: 'member',
};

/**
 * event → sentence. `a` is the actor's name, `t` the target's, `v` a free value
 * (a new group name, a visibility). Every branch must produce a non-empty
 * string: chk_chat_messages_payload requires a body for kind='system'.
 */
function sentenceFor(event, { a = 'Someone', t = 'someone', v = null, role = null, d = null } = {}) {
  switch (event) {
    case 'group_created':
      return `${a} created the group`;
    case 'member_added':
      return `${a} added ${t}`;
    case 'member_joined_link':
      return `${t} joined using an invite link`;
    case 'member_joined_request':
      return `${a} approved ${t}'s request to join`;
    case 'member_removed':
      return `${a} removed ${t}`;
    case 'member_left':
      return `${t} left the team`;
    case 'role_promoted':
      return `${a} made ${t} ${ROLE_TEXT[role] || 'an admin'}`;
    case 'role_demoted':
      return `${a} removed ${t} as ${ROLE_TEXT[role] || 'admin'}`;
    case 'captain_transferred':
      return `${a} handed the captaincy to ${t}`;
    case 'title_changed':
      return v ? `${a} changed the team name to "${v}"` : `${a} changed the team name`;
    case 'icon_changed':
      return `${a} changed the team photo`;
    case 'bio_changed':
      return `${a} changed the team description`;
    case 'visibility_changed':
      return `${a} made the team ${v === 'private' ? 'private' : 'public'}`;

    // Match lifecycle (S.2 Wave C)
    // These pills are posted into both teams' chats, so `v` is always the other
    // TEAM from the perspective of the channel being written to. The two
    // asymmetric moments (who sent, who received) get their own event rather
    // than one sentence bent to fit both, because "you challenged them" and
    // "they challenged you" are genuinely different facts to the reader.
    case 'match_challenge_sent':
      return `${a} challenged ${v || 'another team'} to a match`;
    case 'match_challenge_received':
      return `${v || 'Another team'} challenged your team to a match`;
    case 'match_accepted':
      return `The match against ${v || 'the other team'} is confirmed`;
    case 'match_rejected':
      return `The match against ${v || 'the other team'} was declined`;
    case 'match_expired':
      return `The challenge against ${v || 'the other team'} expired`;
    // S.7 Wave D. A challenge unwound by a suspension is not an expiry and must
    // not read as one -- nobody failed to reply. The wording names SportLynk as
    // the actor without naming which side was suspended, because a ban is between
    // the platform and that account.
    case 'match_cancelled_admin':
      return `The match against ${v || 'the other team'} was cancelled by SportLynk`;
    case 'match_result_submitted':
      return `${a} submitted the result for the match against ${v || 'the other team'}`;
    case 'match_awaiting_owner':
      return `Both results are in for the match against ${v || 'the other team'} — the venue owner will verify it`;
    case 'match_verified':
      return d
        ? `Match against ${v || 'the other team'} verified — ${d}`
        : `The match against ${v || 'the other team'} has been verified`;
    case 'match_disputed':
      return `The result against ${v || 'the other team'} is disputed and under review`;
    // S.7 Wave D. The per-team half of a ruling. `match_ruled` below is the neutral
    // sentence for the shared captain room; this one names the opponent, because in
    // a team's own chat "the other team" is not a fact anybody has to guess at.
    case 'match_ruled_team':
      return d
        ? `SportLynk ruled on the match against ${v || 'the other team'} — ${d}`
        : `SportLynk ruled on the match against ${v || 'the other team'}`;


    // Booking rooms (S.7 Wave B)
    // The opening pill does double duty: it tells the player why a thread they
    // did not create just appeared, and it gives the room a last_message_preview
    // so the chat list has something to show before anybody types.
    case 'booking_confirmed':
      return 'Booking confirmed — chat with the venue here';
    case 'booking_cancelled':
      return v ? `This booking was cancelled (${v})` : 'This booking was cancelled';
    case 'booking_no_show':
      return 'The venue marked this booking as a no-show';

    // The coordination room (S.7 Wave B, FR8.5)
    // Neutral wording, every one of them. A captain room holds both teams, so
    // the per-team sentences above ("you challenged them") would be wrong for
    // half the readers. These say what happened without taking a side, which is
    // also what makes the archive readable to an admin ruling a dispute (FR10.6).
    case 'match_coordinate':
      return 'Challenge accepted — coordinate here';
    case 'match_result_in':
      return t && t !== 'someone'
        ? `${t} submitted a result for this match`
        : 'A result has been submitted for this match';
    case 'match_both_results_in':
      return 'Both results are in — the venue owner will verify the match';
    case 'match_settled':
      return d ? `Result verified — ${d}` : 'The result has been verified';
    case 'match_under_review':
      return 'The result is disputed and under review by SportLynk';
    case 'match_ruled':
      return d ? `SportLynk ruled on this match — ${d}` : 'SportLynk has ruled on this match';

    default:
      // Never throw on an unknown event — a missing case must not be able to
      // roll back the membership change that is the real work of the request.
      return `${a} updated the team`;
  }
}

/**
 * Build the row payload for a system message. Deliberately does not touch the
 * database: chatCore.postSystemMessage does the insert, so there is exactly one
 * code path that writes to chat_messages and bumps the channel's last-message
 * columns.
 */
function buildSystemMessage(event, {
  actorId = null, actorName = null,
  targetId = null, targetName = null,
  value = null, role = null,
  matchId = null, detail = null,
} = {}) {
  const body = sentenceFor(event, {
    a: actorName || 'Someone',
    t: targetName || 'someone',
    v: value,
    role,
    d: detail,
  });
  return {
    body,
    meta: {
      event,
      actorId,
      actorName: actorName || null,
      targetId,
      targetName: targetName || null,
      value: value === undefined ? null : value,
      role: role || null,
      // Present only on match pills, so tapping one can open the match itself.
      matchId: matchId || null,
      detail: detail || null,
    },
  };
}

module.exports = { sentenceFor, buildSystemMessage, ROLE_TEXT };
