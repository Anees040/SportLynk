/// The shapes the four admin surfaces answer with.
///
/// Every field here is server-decided, and that is the point of the file.
/// `severityElo` is computed with the live K-factor by `utils/elo.js`, the ruling
/// buttons are enabled by a server `capabilities` block, and the settings form is
/// built from whatever `GET /api/admin/settings` sends. Nothing about admin policy
/// is duplicated in Dart, because a second copy of a rule is a rule that drifts —
/// and an admin screen that disagrees with the backend about what is allowed is
/// worse than no screen: it offers a button that fails on submit.
///
/// Timestamps arrive as ISO-8601 UTC (the golden rule) and are parsed with
/// [DateTime.tryParse] + `.toLocal()` at the point of display, never here.
library;

int _int(dynamic v, [int d = 0]) =>
    v is int ? v : (v is num ? v.toInt() : int.tryParse('$v') ?? d);

double _num(dynamic v, [double d = 0]) =>
    v is num ? v.toDouble() : double.tryParse('$v') ?? d;

String? _str(dynamic v) {
  if (v == null) return null;
  final s = '$v'.trim();
  return s.isEmpty ? null : s;
}

DateTime? _date(dynamic v) => v == null ? null : DateTime.tryParse('$v');

Map<String, dynamic> _map(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

List<Map<String, dynamic>> _rows(dynamic v) => (v as List? ?? const [])
    .whereType<Map>()
    .map((m) => Map<String, dynamic>.from(m))
    .toList();

// Disputes — the queue row

/// One side of a disputed match, as the queue and the case file both carry it.
class DisputeTeam {
  final String id;
  final String name;
  final String? logoUrl;
  final int elo;

  /// The rating is held still while the dispute is open (ER2.3). A frozen team's
  /// ruling moves no points, so the screen has to say so before the admin rules.
  final bool frozen;

  /// This side is the one that raised the dispute being looked at.
  final bool raisedThis;

  const DisputeTeam({
    required this.id,
    required this.name,
    this.logoUrl,
    this.elo = 1000,
    this.frozen = false,
    this.raisedThis = false,
  });

  factory DisputeTeam.fromJson(Map<String, dynamic> j) => DisputeTeam(
        id: '${j['id'] ?? ''}',
        name: _str(j['name']) ?? 'Unknown team',
        logoUrl: _str(j['logoUrl']),
        elo: _int(j['elo'], 1000),
        frozen: j['frozen'] == true,
        raisedThis: j['raisedThis'] == true,
      );
}

/// The match under dispute, summarised.
class DisputeMatchInfo {
  final String status;
  final String? sport;
  final bool eloApplied;

  /// How many of the two captains have submitted a scoreline. 0, 1 or 2 — and 1
  /// is the interesting case, because there is nothing to compare against.
  final int resultsIn;

  final String? scoreline;
  final String? winnerTeam;
  final String? tournamentId;
  final String? tournamentName;
  final bool isFixture;

  const DisputeMatchInfo({
    required this.status,
    this.sport,
    this.eloApplied = false,
    this.resultsIn = 0,
    this.scoreline,
    this.winnerTeam,
    this.tournamentId,
    this.tournamentName,
    this.isFixture = false,
  });

  factory DisputeMatchInfo.fromJson(Map<String, dynamic> j) => DisputeMatchInfo(
        status: _str(j['status']) ?? 'unknown',
        sport: _str(j['sport']),
        eloApplied: j['eloApplied'] == true,
        resultsIn: _int(j['resultsIn']),
        scoreline: _str(j['scoreline']),
        winnerTeam: _str(j['winnerTeam']),
        tournamentId: _str(j['tournamentId']),
        tournamentName: _str(j['tournamentName']),
        isFixture: j['isFixture'] == true,
      );
}

/// A row of `GET /api/admin/disputes`.
class DisputeRow {
  final String id;
  final String matchId;
  final String status;
  final String? reason;
  final DateTime? createdAt;

  /// Server-computed age. Not derived from [createdAt] on the phone, because the
  /// queue is sorted by it server-side and a device clock that is an hour out
  /// would show a different order from the one it is reading.
  final int ageHours;

  /// The rating at stake if this is ruled — `elo.rate()` at the live K.
  /// This is the triage number: 32 points of a title decider outrank a week-old
  /// friendly, which is why the queue leads with it.
  final int severityElo;

  /// Both captains filed. One ruling closes both, so the admin should not go
  /// hunting for the second row afterwards.
  final bool bothSidesDisputed;

  final String? ruling;
  final String? resolutionNotes;
  final DateTime? resolvedAt;
  final String? resolvedByName;
  final int? ruledScoreChallenger;
  final int? ruledScoreOpponent;

  final DisputeMatchInfo match;
  final DisputeTeam challenger;
  final DisputeTeam opponent;
  final String? raisedByTeamName;
  final String? raisedByCaptainName;

  const DisputeRow({
    required this.id,
    required this.matchId,
    required this.status,
    required this.match,
    required this.challenger,
    required this.opponent,
    this.reason,
    this.createdAt,
    this.ageHours = 0,
    this.severityElo = 0,
    this.bothSidesDisputed = false,
    this.ruling,
    this.resolutionNotes,
    this.resolvedAt,
    this.resolvedByName,
    this.ruledScoreChallenger,
    this.ruledScoreOpponent,
    this.raisedByTeamName,
    this.raisedByCaptainName,
  });

  factory DisputeRow.fromJson(Map<String, dynamic> j) {
    final ruled = _map(j['ruledScore']);
    final raised = _map(j['raisedBy']);
    return DisputeRow(
      id: '${j['id'] ?? ''}',
      matchId: '${j['matchId'] ?? ''}',
      status: _str(j['status']) ?? 'open',
      reason: _str(j['reason']),
      createdAt: _date(j['createdAt']),
      ageHours: _int(j['ageHours']),
      severityElo: _int(j['severityElo']),
      bothSidesDisputed: j['bothSidesDisputed'] == true,
      ruling: _str(j['ruling']),
      resolutionNotes: _str(j['resolutionNotes']),
      resolvedAt: _date(j['resolvedAt']),
      resolvedByName: _str(j['resolvedByName']),
      ruledScoreChallenger:
          j['ruledScore'] == null ? null : _int(ruled['challenger']),
      ruledScoreOpponent:
          j['ruledScore'] == null ? null : _int(ruled['opponent']),
      match: DisputeMatchInfo.fromJson(_map(j['match'])),
      challenger: DisputeTeam.fromJson(_map(j['challenger'])),
      opponent: DisputeTeam.fromJson(_map(j['opponent'])),
      raisedByTeamName: _str(raised['teamName']),
      raisedByCaptainName: _str(raised['captainName']),
    );
  }

  bool get isOpen => status == 'open';

  /// "3 h" / "2 d 4 h" — an age an admin can triage on at a glance.
  String get ageLabel {
    if (ageHours < 1) return 'just now';
    if (ageHours < 24) return '${ageHours}h';
    final d = ageHours ~/ 24;
    final h = ageHours % 24;
    return h == 0 ? '${d}d' : '${d}d ${h}h';
  }
}

// Disputes — the case file (FR10.6)

/// One captain's submitted scoreline. Null on a side that never filed — which is
/// itself evidence, and the reason this is nullable rather than defaulted to 0–0.
class DisputeSubmission {
  final String teamId;
  final String? teamName;
  final String? captainName;
  final DateTime? submittedAt;
  final int? scoreChallenger;
  final int? scoreOpponent;
  final String? winnerTeam;
  final String? scoreline;

  const DisputeSubmission({
    required this.teamId,
    this.teamName,
    this.captainName,
    this.submittedAt,
    this.scoreChallenger,
    this.scoreOpponent,
    this.winnerTeam,
    this.scoreline,
  });

  factory DisputeSubmission.fromJson(Map<String, dynamic> j) =>
      DisputeSubmission(
        teamId: '${j['teamId'] ?? ''}',
        teamName: _str(j['teamName']),
        captainName: _str(j['captainName']),
        submittedAt: _date(j['submittedAt']),
        scoreChallenger:
            j['scoreChallenger'] == null ? null : _int(j['scoreChallenger']),
        scoreOpponent:
            j['scoreOpponent'] == null ? null : _int(j['scoreOpponent']),
        winnerTeam: _str(j['winnerTeam']),
        scoreline: _str(j['scoreline']),
      );
}

/// A roster line, with the trust score that is the other half of the story.
class RosterMember {
  final String userId;
  final String name;
  final String? avatarUrl;
  final String role;

  /// From `player_profiles`, left-joined server-side: null means "never rated",
  /// which is different from 0 and must not render as a bad score.
  final double? trustScore;

  final bool suspended;

  const RosterMember({
    required this.userId,
    required this.name,
    required this.role,
    this.avatarUrl,
    this.trustScore,
    this.suspended = false,
  });

  factory RosterMember.fromJson(Map<String, dynamic> j) => RosterMember(
        userId: '${j['userId'] ?? ''}',
        name: _str(j['name']) ?? 'Unknown',
        role: _str(j['role']) ?? 'member',
        avatarUrl: _str(j['avatarUrl']),
        trustScore: j['trustScore'] == null ? null : _num(j['trustScore']),
        suspended: j['suspended'] == true,
      );

  bool get isCaptain => role == 'captain';
  bool get isViceCaptain => role == 'vice_captain';
}

/// The booking the match was played on, and what the owner saw.
class CaseBooking {
  final String id;
  final String? slotDate;
  final String? startTime;
  final String? endTime;
  final String status;

  /// Stamped by the QR scan. Its presence is the strongest evidence in the file
  /// that the match happened at all.
  final DateTime? checkedInAt;

  final DateTime? noShowAt;
  final bool hadQr;
  final double totalAmount;
  final double depositAmount;
  final String? cancellationReason;
  final String? venueName;
  final String? venueCity;
  final String? ownerName;
  final String? ownerPhone;

  const CaseBooking({
    required this.id,
    required this.status,
    this.slotDate,
    this.startTime,
    this.endTime,
    this.checkedInAt,
    this.noShowAt,
    this.hadQr = false,
    this.totalAmount = 0,
    this.depositAmount = 0,
    this.cancellationReason,
    this.venueName,
    this.venueCity,
    this.ownerName,
    this.ownerPhone,
  });

  factory CaseBooking.fromJson(Map<String, dynamic> j) {
    final v = _map(j['venue']);
    final o = _map(j['owner']);
    return CaseBooking(
      id: '${j['id'] ?? ''}',
      status: _str(j['status']) ?? 'unknown',
      slotDate: _str(j['slotDate'])?.split('T').first,
      startTime: _str(j['startTime']),
      endTime: _str(j['endTime']),
      checkedInAt: _date(j['checkedInAt']),
      noShowAt: _date(j['noShowAt']),
      hadQr: j['hadQr'] == true,
      totalAmount: _num(j['totalAmount']),
      depositAmount: _num(j['depositAmount']),
      cancellationReason: _str(j['cancellationReason']),
      venueName: _str(v['name']),
      venueCity: _str(v['city']),
      ownerName: _str(o['name']),
      ownerPhone: _str(o['phone']),
    );
  }
}

/// One line of the captain-channel archive (FR10.6). `body` is null on a tombstone
/// — a deleted message still counts as evidence that something was said and then
/// withdrawn, so the row survives with `deleted: true` instead of vanishing.
class ArchiveMessage {
  final String id;
  final String? senderId;
  final String? senderName;

  /// Which side said it. Null for a system pill, or for a sender who is on
  /// neither roster (an admin, or someone who has since left).
  final String? teamId;

  final bool system;
  final String kind;
  final String? body;
  final bool deleted;
  final bool hasMedia;
  final String? mediaMime;
  final DateTime? createdAt;

  const ArchiveMessage({
    required this.id,
    this.senderId,
    this.senderName,
    this.teamId,
    this.system = false,
    this.kind = 'text',
    this.body,
    this.deleted = false,
    this.hasMedia = false,
    this.mediaMime,
    this.createdAt,
  });

  factory ArchiveMessage.fromJson(Map<String, dynamic> j) => ArchiveMessage(
        id: '${j['id'] ?? ''}',
        senderId: _str(j['senderId']),
        senderName: _str(j['senderName']),
        teamId: _str(j['teamId']),
        system: j['system'] == true,
        kind: _str(j['kind']) ?? 'text',
        body: _str(j['body']),
        deleted: j['deleted'] == true,
        hasMedia: j['hasMedia'] == true,
        mediaMime: _str(j['mediaMime']),
        createdAt: _date(j['createdAt']),
      );
}

/// A rating movement already on the record for this match. Present only when the
/// match was rated before the dispute — which is exactly when a ruling has to
/// correct rather than apply.
class EloHistoryEntry {
  final String teamId;
  final String? teamName;
  final int? before;
  final int? after;
  final int? delta;
  final double kFactor;
  final String? reason;
  final DateTime? createdAt;

  const EloHistoryEntry({
    required this.teamId,
    this.teamName,
    this.before,
    this.after,
    this.delta,
    this.kFactor = 0,
    this.reason,
    this.createdAt,
  });

  factory EloHistoryEntry.fromJson(Map<String, dynamic> j) => EloHistoryEntry(
        teamId: '${j['teamId'] ?? ''}',
        teamName: _str(j['teamName']),
        before: j['before'] == null ? null : _int(j['before']),
        after: j['after'] == null ? null : _int(j['after']),
        delta: j['delta'] == null ? null : _int(j['delta']),
        kFactor: _num(j['kFactor']),
        reason: _str(j['reason']),
        createdAt: _date(j['createdAt']),
      );
}

/// What the server says this screen may offer. The buttons are enabled from this
/// and never from client-side reasoning about the match: an overturn of an
/// already-rated match needs a migration, and `correctionBlockedBy` names the file
/// so the screen can explain a disabled button instead of failing on submit.
class DisputeCapabilities {
  final bool needsCorrection;
  final bool correctionAvailable;
  final String? correctionBlockedBy;
  final bool canRule;

  const DisputeCapabilities({
    this.needsCorrection = false,
    this.correctionAvailable = false,
    this.correctionBlockedBy,
    this.canRule = false,
  });

  factory DisputeCapabilities.fromJson(Map<String, dynamic> j) =>
      DisputeCapabilities(
        needsCorrection: j['needsCorrection'] == true,
        correctionAvailable: j['correctionAvailable'] == true,
        correctionBlockedBy: _str(j['correctionBlockedBy']),
        canRule: j['canRule'] == true,
      );

  /// A ruling that changes the result is offerable only when the database can
  /// carry the correction. `dismiss` is always available while the case is open.
  bool get canChangeResult =>
      canRule && (!needsCorrection || correctionAvailable);
}

/// A sibling dispute on the same match, as the case file lists it. Deliberately
/// not a [DisputeRow]: the server sends five keys here, and parsing it as a queue
/// row would fabricate a zero severity and an empty match block.
class RelatedDispute {
  final String id;
  final String? teamId;
  final String? teamName;
  final String status;
  final String? reason;
  final DateTime? createdAt;

  const RelatedDispute({
    required this.id,
    required this.status,
    this.teamId,
    this.teamName,
    this.reason,
    this.createdAt,
  });

  factory RelatedDispute.fromJson(Map<String, dynamic> j) => RelatedDispute(
        id: '${j['id'] ?? ''}',
        status: _str(j['status']) ?? 'open',
        teamId: _str(j['teamId']),
        teamName: _str(j['teamName']),
        reason: _str(j['reason']),
        createdAt: _date(j['createdAt']),
      );
}

/// The whole case file for one dispute: `GET /api/admin/disputes/:id`.
class DisputeCase {
  final DisputeRow dispute;
  final DisputeSubmission? challengerSubmission;
  final DisputeSubmission? opponentSubmission;

  /// True when both captains filed the same scoreline. A dispute over an agreed
  /// result is a different case from a dispute over two conflicting ones, and the
  /// admin should see which at a glance.
  final bool submissionsAgree;

  final int submissionCount;
  final List<RosterMember> challengerRoster;
  final List<RosterMember> opponentRoster;
  final CaseBooking? booking;
  final String? chatChannelId;
  final List<ArchiveMessage> chat;
  final bool chatTruncated;
  final List<EloHistoryEntry> eloHistory;
  final DisputeCapabilities capabilities;

  /// Other disputes on the same match. One ruling closes them all, so the screen
  /// says so rather than letting the admin open each one in turn.
  final List<RelatedDispute> otherDisputes;

  const DisputeCase({
    required this.dispute,
    required this.capabilities,
    this.challengerSubmission,
    this.opponentSubmission,
    this.submissionsAgree = false,
    this.submissionCount = 0,
    this.challengerRoster = const [],
    this.opponentRoster = const [],
    this.booking,
    this.chatChannelId,
    this.chat = const [],
    this.chatTruncated = false,
    this.eloHistory = const [],
    this.otherDisputes = const [],
  });

  factory DisputeCase.fromJson(Map<String, dynamic> j) {
    final subs = _map(j['submissions']);
    final rosters = _map(j['rosters']);
    final chat = _map(j['chat']);
    final b = j['booking'];
    return DisputeCase(
      dispute: DisputeRow.fromJson(_map(j['dispute'])),
      capabilities: DisputeCapabilities.fromJson(_map(j['capabilities'])),
      challengerSubmission: subs['challenger'] is Map
          ? DisputeSubmission.fromJson(_map(subs['challenger']))
          : null,
      opponentSubmission: subs['opponent'] is Map
          ? DisputeSubmission.fromJson(_map(subs['opponent']))
          : null,
      submissionsAgree: subs['agree'] == true,
      submissionCount: _int(subs['count']),
      challengerRoster:
          _rows(rosters['challenger']).map(RosterMember.fromJson).toList(),
      opponentRoster:
          _rows(rosters['opponent']).map(RosterMember.fromJson).toList(),
      booking: b is Map ? CaseBooking.fromJson(_map(b)) : null,
      chatChannelId: _str(chat['channelId']),
      chat: _rows(chat['messages']).map(ArchiveMessage.fromJson).toList(),
      chatTruncated: chat['truncated'] == true,
      eloHistory: _rows(j['eloHistory']).map(EloHistoryEntry.fromJson).toList(),
      otherDisputes:
          _rows(j['otherDisputes']).map(RelatedDispute.fromJson).toList(),
    );
  }

  /// The scoreline `rule_draw` would adopt without a body, if one exists: a
  /// submission that is itself drawn. The server never invents 0-0, so the screen
  /// must not offer "rule a draw" as if it were free.
  bool get hasDrawnSubmission {
    for (final s in [challengerSubmission, opponentSubmission]) {
      if (s?.scoreChallenger != null &&
          s!.scoreChallenger == s.scoreOpponent) {
        return true;
      }
    }
    return false;
  }
}

// Users — search, suspend, reinstate (FR10.8)

/// A row of `GET /api/admin/users`. `suspended` is derived server-side from
/// `users.is_active`; there is no second column for it, and the client must not
/// invent one — one fact, one source.
class AdminUserRow {
  final String id;
  final String name;
  final String? email;
  final String? phone;
  final String role;
  final String? avatarUrl;
  final bool suspended;
  final DateTime? suspendedAt;
  final String? suspendedReason;
  final String? suspendedByName;
  final DateTime? createdAt;
  final int bookings;
  final int venues;
  final double walletBalance;

  /// Money already committed to bookings. Shown next to the balance because
  /// suspending an account with frozen funds refunds them, and the admin should
  /// see the number before they do it.
  final double walletFrozen;

  const AdminUserRow({
    required this.id,
    required this.name,
    required this.role,
    this.email,
    this.phone,
    this.avatarUrl,
    this.suspended = false,
    this.suspendedAt,
    this.suspendedReason,
    this.suspendedByName,
    this.createdAt,
    this.bookings = 0,
    this.venues = 0,
    this.walletBalance = 0,
    this.walletFrozen = 0,
  });

  factory AdminUserRow.fromJson(Map<String, dynamic> j) {
    final c = _map(j['counts']);
    final w = _map(j['wallet']);
    return AdminUserRow(
      id: '${j['id'] ?? ''}',
      name: _str(j['name']) ?? 'Unknown',
      role: _str(j['role']) ?? 'player',
      email: _str(j['email']),
      phone: _str(j['phone']),
      avatarUrl: _str(j['avatarUrl']),
      suspended: j['suspended'] == true,
      suspendedAt: _date(j['suspendedAt']),
      suspendedReason: _str(j['suspendedReason']),
      suspendedByName: _str(j['suspendedByName']),
      createdAt: _date(j['createdAt']),
      bookings: _int(c['bookings']),
      venues: _int(c['venues']),
      walletBalance: _num(w['balance']),
      walletFrozen: _num(w['frozen']),
    );
  }
}

/// What a suspension unwound. Rendered as a receipt after the action,
/// because "suspended" alone hides the part that matters: money moved, and some
/// things deliberately did not move.
class SuspensionCascade {
  final List<String> challengesExpired;
  final List<CascadeBooking> bookingsCancelled;

  /// Bookings left in place — a committed match sits on them, and cancelling one
  /// would strand the other team. The server reports the reason per row.
  final List<CascadeSkip> bookingsLeftAlone;

  final List<CascadeTournament> tournamentsWithdrawn;
  final List<CascadeTournament> tournamentsLeftAlone;
  final List<CascadeVenue> venuesDeactivated;
  final int requestsRejected;

  /// An owner's already-confirmed bookings: counted, never cancelled. That is a
  /// refund decision with a counterparty and belongs to a human.
  final int confirmedBookingsLeftAlone;

  final double refundedTotal;

  const SuspensionCascade({
    this.challengesExpired = const [],
    this.bookingsCancelled = const [],
    this.bookingsLeftAlone = const [],
    this.tournamentsWithdrawn = const [],
    this.tournamentsLeftAlone = const [],
    this.venuesDeactivated = const [],
    this.requestsRejected = 0,
    this.confirmedBookingsLeftAlone = 0,
    this.refundedTotal = 0,
  });

  factory SuspensionCascade.fromJson(Map<String, dynamic> j) =>
      SuspensionCascade(
        challengesExpired:
            (j['challengesExpired'] as List? ?? const []).map((e) => '$e').toList(),
        bookingsCancelled:
            _rows(j['bookingsCancelled']).map(CascadeBooking.fromJson).toList(),
        bookingsLeftAlone:
            _rows(j['bookingsLeftAlone']).map(CascadeSkip.fromJson).toList(),
        tournamentsWithdrawn: _rows(j['tournamentsWithdrawn'])
            .map(CascadeTournament.fromJson)
            .toList(),
        tournamentsLeftAlone: _rows(j['tournamentsLeftAlone'])
            .map(CascadeTournament.fromJson)
            .toList(),
        venuesDeactivated:
            _rows(j['venuesDeactivated']).map(CascadeVenue.fromJson).toList(),
        requestsRejected: _int(j['requestsRejected']),
        confirmedBookingsLeftAlone: _int(j['confirmedBookingsLeftAlone']),
        refundedTotal: _num(j['refundedTotal']),
      );

  bool get isEmpty =>
      challengesExpired.isEmpty &&
      bookingsCancelled.isEmpty &&
      bookingsLeftAlone.isEmpty &&
      tournamentsWithdrawn.isEmpty &&
      tournamentsLeftAlone.isEmpty &&
      venuesDeactivated.isEmpty &&
      requestsRejected == 0 &&
      confirmedBookingsLeftAlone == 0;
}

class CascadeBooking {
  final String bookingId;
  final String? venueName;
  final double refunded;
  final double penalty;
  final bool late;

  const CascadeBooking({
    required this.bookingId,
    this.venueName,
    this.refunded = 0,
    this.penalty = 0,
    this.late = false,
  });

  factory CascadeBooking.fromJson(Map<String, dynamic> j) => CascadeBooking(
        bookingId: '${j['bookingId'] ?? ''}',
        venueName: _str(j['venueName']),
        refunded: _num(j['refunded']),
        penalty: _num(j['penalty']),
        late: j['late'] == true,
      );
}

class CascadeSkip {
  final String bookingId;
  final String? venueName;
  final String? slotDate;
  final String reason;

  const CascadeSkip({
    required this.bookingId,
    required this.reason,
    this.venueName,
    this.slotDate,
  });

  factory CascadeSkip.fromJson(Map<String, dynamic> j) => CascadeSkip(
        bookingId: '${j['bookingId'] ?? ''}',
        reason: _str(j['reason']) ?? 'could not be cancelled',
        venueName: _str(j['venueName']),
        slotDate: _str(j['slotDate'])?.split('T').first,
      );
}

class CascadeTournament {
  final String tournamentId;
  final String? name;
  final String? reason;

  const CascadeTournament({required this.tournamentId, this.name, this.reason});

  factory CascadeTournament.fromJson(Map<String, dynamic> j) =>
      CascadeTournament(
        tournamentId: '${j['tournamentId'] ?? ''}',
        name: _str(j['name']),
        reason: _str(j['reason']),
      );
}

class CascadeVenue {
  final String id;
  final String? name;

  const CascadeVenue({required this.id, this.name});

  factory CascadeVenue.fromJson(Map<String, dynamic> j) =>
      CascadeVenue(id: '${j['id'] ?? ''}', name: _str(j['name']));
}

/// The receipt from suspend/reinstate. `cascade` is present only on a suspension.
class SuspensionResult {
  final String userId;
  final String? name;
  final String? role;
  final bool suspended;
  final String? reason;
  final SuspensionCascade? cascade;

  /// Venues brought back on a reinstatement. Bookings do not come back — a
  /// cancelled booking was refunded and its slot may already be someone else's.
  final int venuesRestored;

  final String message;

  const SuspensionResult({
    required this.userId,
    required this.suspended,
    this.name,
    this.role,
    this.reason,
    this.cascade,
    this.venuesRestored = 0,
    this.message = '',
  });

  factory SuspensionResult.fromJson(Map<String, dynamic> j, String message) =>
      SuspensionResult(
        userId: '${j['userId'] ?? ''}',
        suspended: j['suspended'] == true,
        name: _str(j['name']),
        role: _str(j['role']),
        reason: _str(j['reason']),
        cascade: j['cascade'] is Map
            ? SuspensionCascade.fromJson(_map(j['cascade']))
            : null,
        venuesRestored: _int(j['venuesRestored']),
        message: message,
      );
}

// Global settings (FR10.9–10.11)

/// One writable platform setting, exactly as `GET /api/admin/settings` describes
/// it. There is no Dart copy of the catalogue: label, bounds, step, unit and type
/// all arrive from `utils/settingsCatalog.js`, so a field added on the server
/// appears here with no app release, and the screen can never offer a value the
/// server would reject.
class SettingsField {
  final String key;
  final String label;
  final String? description;

  /// `int` · `number` · `bool` · `text` · `sports`. Anything unrecognised is
  /// rendered read-only rather than guessed at.
  final String type;

  final String? unit;
  final num? step;
  final num? min;
  final num? max;
  final int? maxLen;

  /// The other field this one is bounded against — commission and deposit cannot
  /// together exceed 100 %. The screen validates the pair before it submits, using
  /// the same rule the server enforces.
  final String? pairsWith;

  /// Effective value: what the next booking will use. `num`, `bool`,
  /// `String`, or `Map<String, bool>` for a `sports` field.
  final dynamic value;

  final dynamic defaultValue;
  final bool isOverridden;
  final bool restartRequired;

  const SettingsField({
    required this.key,
    required this.label,
    required this.type,
    this.description,
    this.unit,
    this.step,
    this.min,
    this.max,
    this.maxLen,
    this.pairsWith,
    this.value,
    this.defaultValue,
    this.isOverridden = false,
    this.restartRequired = false,
  });

  factory SettingsField.fromJson(Map<String, dynamic> j) => SettingsField(
        key: '${j['key'] ?? ''}',
        label: _str(j['label']) ?? '${j['key'] ?? ''}',
        type: _str(j['type']) ?? 'text',
        description: _str(j['description']),
        unit: _str(j['unit']),
        step: j['step'] is num ? j['step'] as num : null,
        min: j['min'] is num ? j['min'] as num : null,
        max: j['max'] is num ? j['max'] as num : null,
        maxLen: j['maxLen'] == null ? null : _int(j['maxLen']),
        pairsWith: _str(j['pairsWith']),
        value: j['value'],
        defaultValue: j['default'],
        isOverridden: j['isOverridden'] == true,
        restartRequired: j['restartRequired'] == true,
      );

  bool get isNumeric => type == 'int' || type == 'number';
  bool get isBool => type == 'bool';
  bool get isSports => type == 'sports';

  /// The sports map, or an empty map for any other field type.
  Map<String, bool> get sports {
    if (!isSports || value is! Map) return const {};
    return {
      for (final e in (value as Map).entries) '${e.key}': e.value == true,
    };
  }

  /// "5" / "2.5" / "on" — one cell of the save-diff confirmation.
  String display(dynamic v) {
    if (v == null) return '—';
    if (v is bool) return v ? 'on' : 'off';
    if (v is Map) {
      final on = v.entries.where((e) => e.value == true).map((e) => '${e.key}');
      return on.isEmpty ? 'none enabled' : on.join(', ');
    }
    if (v is num) {
      final s = v.toStringAsFixed(v == v.roundToDouble() ? 0 : 2);
      return unit == null ? s : '$s$unit';
    }
    return '$v';
  }

  String get valueLabel => display(value);
  String get defaultLabel => display(defaultValue);
}

/// A section of the settings screen, in server order.
class SettingsSection {
  final String key;
  final String label;
  final String? hint;
  final List<SettingsField> fields;

  const SettingsSection({
    required this.key,
    required this.label,
    this.hint,
    this.fields = const [],
  });

  factory SettingsSection.fromJson(Map<String, dynamic> j) => SettingsSection(
        key: '${j['key'] ?? ''}',
        label: _str(j['label']) ?? '${j['key'] ?? ''}',
        hint: _str(j['hint']),
        fields: _rows(j['fields']).map(SettingsField.fromJson).toList(),
      );
}

/// The whole settings payload. `overrides` is the list of keys that differ from
/// the documented default — computed server-side by comparing VALUES, not by
/// looking for a row, because the seed migration wrote every row with its default
/// already in it.
class SettingsCatalog {
  final List<SettingsSection> sections;
  final List<String> overrides;
  final bool appliesImmediately;
  final int cacheTtlSeconds;

  const SettingsCatalog({
    this.sections = const [],
    this.overrides = const [],
    this.appliesImmediately = true,
    this.cacheTtlSeconds = 60,
  });

  static const empty = SettingsCatalog();

  factory SettingsCatalog.fromJson(Map<String, dynamic> j) => SettingsCatalog(
        sections: _rows(j['sections']).map(SettingsSection.fromJson).toList(),
        overrides:
            (j['overrides'] as List? ?? const []).map((e) => '$e').toList(),
        appliesImmediately: j['appliesImmediately'] != false,
        cacheTtlSeconds: _int(j['cacheTtlSeconds'], 60),
      );

  SettingsField? field(String key) {
    for (final s in sections) {
      for (final f in s.fields) {
        if (f.key == key) return f;
      }
    }
    return null;
  }
}

/// One line of a save's `changed` array: what moved, from what, to what.
class SettingsChange {
  final String key;
  final String label;
  final dynamic from;
  final dynamic to;

  const SettingsChange({
    required this.key,
    required this.label,
    this.from,
    this.to,
  });

  factory SettingsChange.fromJson(Map<String, dynamic> j) => SettingsChange(
        key: '${j['key'] ?? ''}',
        label: _str(j['label']) ?? '${j['key'] ?? ''}',
        from: j['from'],
        to: j['to'],
      );
}
