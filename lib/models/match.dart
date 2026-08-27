library;

import 'reco.dart';
import 'team.dart' show asNum;

/// Wire models for the match lifecycle (S2 Wave C).
///
/// These mirror `matchCore.shapeMatch` on the backend one field at a time. The
/// server already computes everything viewer-relative — who "my" team is, whether
/// the slot has started, whether a team is ranked — so nothing here re-derives a
/// rule that exists in SQL. When the two disagree the server wins, which is only
/// true if the client never invents its own copy of the logic.
///
/// Every numeric read goes through [asNum] because Postgres hands back DECIMAL
/// columns as strings, and `1000` arriving as `"1000"` would silently become a
/// null int and render as an empty rating.

int _int(dynamic v, [int fallback = 0]) => asNum(v, fallback).round();
int? _intOrNull(dynamic v) => v == null ? null : asNum(v, 0).round();
double? _dblOrNull(dynamic v) => v == null ? null : asNum(v, 0).toDouble();
bool _bool(dynamic v) => v == true;
String? _str(dynamic v) {
  final s = v?.toString();
  return (s == null || s.isEmpty) ? null : s;
}

DateTime? _date(dynamic v) => v == null ? null : DateTime.tryParse('$v')?.toLocal();

/// The eight states a match can hold. Kept as a plain string plus predicates
/// rather than an enum: an unknown state from a newer backend must render as
/// *something* instead of throwing, and the string is what the API speaks.
class MatchStatus {
  MatchStatus._();
  static const String challengeSent = 'challenge_sent';
  static const String accepted = 'accepted';
  static const String awaitingResults = 'awaiting_results';
  static const String awaitingOwner = 'awaiting_owner';
  static const String completed = 'completed';
  static const String rejected = 'rejected';
  static const String expired = 'expired';
  static const String disputed = 'disputed';
}

/// A team as it appears on one side of a match, with its ladder standing.
class MatchSide {
  final String id;
  final String name;
  final String? logoUrl;
  final String? city;

  /// The raw rating. Always a real number — the *base* (1000) for a new team.
  final int elo;

  /// FR2.6 — false until the team has a verified match. Use [ratingLabel], not
  /// [elo], for anything the user reads.
  final bool ranked;

  /// [elo] when [ranked], otherwise null.
  final int? displayElo;

  final int played;
  final int wins;
  final int losses;
  final int draws;

  /// ER2.3 — the team's rating is frozen platform-wide for dispute abuse.
  final bool eloFrozen;

  /// The points this side gained or lost on THIS match. Null until verified.
  final int? eloDelta;

  /// FR5.5 — the roster's average trust score, banded by the server so every
  /// screen draws the same badge. Only present on the pairing endpoints.
  final int? trustScore;
  final String? trustBand;
  final String? trustLabel;
  final int? memberCount;

  const MatchSide({
    required this.id,
    required this.name,
    this.logoUrl,
    this.city,
    required this.elo,
    required this.ranked,
    this.displayElo,
    required this.played,
    required this.wins,
    required this.losses,
    required this.draws,
    required this.eloFrozen,
    this.eloDelta,
    this.trustScore,
    this.trustBand,
    this.trustLabel,
    this.memberCount,
  });

  factory MatchSide.fromJson(Map<String, dynamic> j) => MatchSide(
        id: '${j['id']}',
        name: '${j['name'] ?? 'Team'}',
        logoUrl: _str(j['logoUrl']),
        city: _str(j['city']),
        elo: _int(j['elo'], 1000),
        ranked: _bool(j['ranked']),
        displayElo: _intOrNull(j['displayElo']),
        played: _int(j['played']),
        wins: _int(j['wins']),
        losses: _int(j['losses']),
        draws: _int(j['draws']),
        eloFrozen: _bool(j['eloFrozen']),
        eloDelta: _intOrNull(j['eloDelta']),
        trustScore: _intOrNull(j['trustScore']),
        trustBand: _str(j['trustBand']),
        trustLabel: _str(j['trustLabel']),
        memberCount: _intOrNull(j['memberCount']),
      );

  /// What to print where a rating goes. "Unranked" is the honest answer for a
  /// team with no verified match — showing 1000 would imply a record it has not
  /// played yet (FR2.6).
  String get ratingLabel => ranked ? '$elo' : 'Unranked';

  String get record => 'W $wins · L $losses · D $draws';

  /// Win rate over played matches, 0 when it has never played.
  double get winRate => played == 0 ? 0 : wins / played;
}

/// The booking a match is played on. Never invented client-side — a match exists
/// only because a confirmed booking backs it (FR5.11).
class MatchBooking {
  final String id;
  final DateTime? slotDate;
  final String? startTime;
  final String? endTime;
  final String? status;
  final String? venueId;
  final String? venueName;
  final String? venueCity;

  const MatchBooking({
    required this.id,
    this.slotDate,
    this.startTime,
    this.endTime,
    this.status,
    this.venueId,
    this.venueName,
    this.venueCity,
  });

  factory MatchBooking.fromJson(Map<String, dynamic> j) => MatchBooking(
        id: '${j['id']}',
        slotDate: _date(j['slotDate']),
        startTime: _str(j['startTime']),
        endTime: _str(j['endTime']),
        status: _str(j['status']),
        venueId: _str(j['venueId']),
        venueName: _str(j['venueName']),
        venueCity: _str(j['venueCity']),
      );

  /// `20:00:00` → `8:00 PM`. Times arrive as the venue's local wall-clock string
  /// and are NOT timestamps, so they are formatted as-is rather than converted:
  /// a 20:00 slot is 20:00 at that pitch regardless of the phone's timezone.
  static String prettyTime(String? raw) {
    if (raw == null || raw.isEmpty) return '';
    final parts = raw.split(':');
    final h = int.tryParse(parts.first) ?? 0;
    final m = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
    final suffix = h < 12 ? 'AM' : 'PM';
    final h12 = h % 12 == 0 ? 12 : h % 12;
    return '$h12:${m.toString().padLeft(2, '0')} $suffix';
  }

  String get timeRange {
    final a = prettyTime(startTime);
    final b = prettyTime(endTime);
    if (a.isEmpty) return '';
    return b.isEmpty ? a : '$a – $b';
  }

  /// The kickoff as a real instant, for countdowns and "has it started" checks.
  DateTime? get startsAt {
    final d = slotDate;
    if (d == null) return null;
    final parts = (startTime ?? '00:00').split(':');
    return DateTime(
      d.year,
      d.month,
      d.day,
      int.tryParse(parts.first) ?? 0,
      parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0,
    );
  }
}

/// A match in any of its eight states.
class MatchModel {
  final String id;
  final String status;
  final String? sport;
  final MatchSide challenger;
  final MatchSide opponent;

  /// FR5.4 — 5..100, or null while either side is unranked.
  final int? competitiveness;

  /// FR5.10 — the generated preview sentence, and the label it must be shown
  /// under. The label ships from the server so no screen can call this a
  /// prediction.
  final String? previewText;
  final String previewLabel;

  final DateTime? challengeExpiresAt;
  final String? winnerTeam;
  final bool isDraw;
  final int? scoreChallenger;
  final int? scoreOpponent;
  final bool eloApplied;
  final bool resultsLocked;

  /// How many of the two captains have submitted (0, 1 or 2).
  final int resultsIn;

  final DateTime? respondedAt;
  final DateTime? verifiedAt;
  final DateTime? createdAt;

  /// Server-computed: the slot's kickoff has passed, so a result may be
  /// submitted. Enforced server-side too — this only decides whether to *offer*
  /// the button.
  final bool slotStarted;

  final MatchBooking? booking;

  /// Which side is the viewer's, and which seat they sit in. Null for a viewer
  /// who is only the venue owner.
  final String? myTeamId;
  final bool iAmChallenger;
  final bool iAmVenueOwner;

  /// ER2.1 — my team has already used its one submission. Distinct from
  /// `resultsIn == 1`, which cannot say *whose* result is in.
  final bool iSubmitted;

  /// Set by the list endpoint when a `challenge_sent` row is already past its
  /// deadline but the sweep has not run yet — so History shows "Expired"
  /// instead of a challenge that can never be answered.
  final String? effectiveStatus;

  /// Populated by `GET /matches/:id` and the owner queue: what each captain
  /// submitted. Hidden from a team until BOTH are in, so neither can copy.
  final List<MatchSubmission> submissions;

  const MatchModel({
    required this.id,
    required this.status,
    this.sport,
    required this.challenger,
    required this.opponent,
    this.competitiveness,
    this.previewText,
    this.previewLabel = 'Preview',
    this.challengeExpiresAt,
    this.winnerTeam,
    required this.isDraw,
    this.scoreChallenger,
    this.scoreOpponent,
    required this.eloApplied,
    required this.resultsLocked,
    required this.resultsIn,
    this.respondedAt,
    this.verifiedAt,
    this.createdAt,
    required this.slotStarted,
    this.booking,
    this.myTeamId,
    required this.iAmChallenger,
    required this.iAmVenueOwner,
    this.iSubmitted = false,
    this.effectiveStatus,
    this.submissions = const [],
  });

  factory MatchModel.fromJson(Map<String, dynamic> j) {
    final ch = Map<String, dynamic>.from(j['challenger'] as Map? ?? const {});
    final op = Map<String, dynamic>.from(j['opponent'] as Map? ?? const {});
    final bk = j['booking'];
    return MatchModel(
      id: '${j['id']}',
      status: '${j['status'] ?? MatchStatus.challengeSent}',
      sport: _str(j['sport']),
      challenger: MatchSide.fromJson(ch),
      opponent: MatchSide.fromJson(op),
      competitiveness: _intOrNull(j['competitiveness']),
      previewText: _str(j['previewText']),
      previewLabel: '${j['previewLabel'] ?? 'Preview'}',
      challengeExpiresAt: _date(j['challengeExpiresAt']),
      winnerTeam: _str(j['winnerTeam']),
      isDraw: _bool(j['isDraw']),
      scoreChallenger: _intOrNull(j['scoreChallenger']),
      scoreOpponent: _intOrNull(j['scoreOpponent']),
      eloApplied: _bool(j['eloApplied']),
      resultsLocked: _bool(j['resultsLocked']),
      resultsIn: _int(j['resultsIn']),
      respondedAt: _date(j['respondedAt']),
      verifiedAt: _date(j['verifiedAt']),
      createdAt: _date(j['createdAt']),
      slotStarted: _bool(j['slotStarted']),
      booking: bk is Map ? MatchBooking.fromJson(Map<String, dynamic>.from(bk)) : null,
      myTeamId: _str(j['myTeamId']),
      iAmChallenger: _bool(j['iAmChallenger']),
      iAmVenueOwner: _bool(j['iAmVenueOwner']),
      iSubmitted: _bool(j['iSubmitted']),
      effectiveStatus: _str(j['effectiveStatus']),
      submissions: (j['submissions'] as List? ?? const [])
          .whereType<Map>()
          .map((x) => MatchSubmission.fromJson(Map<String, dynamic>.from(x)))
          .toList(),
    );
  }

  /// The state to render. Prefers the server's `effectiveStatus` so a challenge
  /// that has timed out but not yet been swept never looks answerable.
  String get shownStatus => effectiveStatus ?? status;

  // ── State predicates ────────────────────────────────────────
  bool get isPending => shownStatus == MatchStatus.challengeSent;
  bool get isAccepted =>
      shownStatus == MatchStatus.accepted || shownStatus == MatchStatus.awaitingResults;
  bool get isAwaitingOwner => shownStatus == MatchStatus.awaitingOwner;
  bool get isCompleted => shownStatus == MatchStatus.completed;
  bool get isDisputed => shownStatus == MatchStatus.disputed;
  bool get isDead =>
      shownStatus == MatchStatus.rejected || shownStatus == MatchStatus.expired;

  /// My side and theirs, from the viewer's seat. Falls back to challenger-vs-
  /// opponent for a venue owner, who has no side.
  MatchSide get myTeam => iAmChallenger ? challenger : opponent;
  MatchSide get theirTeam => iAmChallenger ? opponent : challenger;

  int? get myScore => iAmChallenger ? scoreChallenger : scoreOpponent;
  int? get theirScore => iAmChallenger ? scoreOpponent : scoreChallenger;

  /// The viewer's rating change on this match, signed.
  int? get myDelta => iAmChallenger ? challenger.eloDelta : opponent.eloDelta;

  /// FR5.4 — null means "not comparable yet", which the UI must say out loud
  /// rather than drawing a 0% bar.
  bool get hasCompetitiveness => competitiveness != null;

  /// `3 – 1`, or null while there is no agreed score.
  String? get scoreline => (scoreChallenger == null || scoreOpponent == null)
      ? null
      : '$scoreChallenger – $scoreOpponent';

  /// Did my team win? Null for a draw or an unfinished match.
  bool? get iWon {
    if (!isCompleted) return null;
    if (isDraw) return null;
    final w = winnerTeam;
    final me = myTeamId;
    if (w == null || me == null) return null;
    return w == me;
  }

  /// How long is left to answer a challenge. Negative once it has lapsed.
  Duration? get timeToExpiry => challengeExpiresAt?.difference(DateTime.now());

  /// FR5.17 — the 24h window is a *server* rule; this only decides whether to
  /// offer the flag. `hours` comes from the list payload so the policy lives in
  /// `global_settings`, not in the app bundle.
  bool canDispute(int hours) {
    if (isAwaitingOwner) return true;
    if (!isCompleted) return false;
    final v = verifiedAt;
    if (v == null) return false;
    return DateTime.now().difference(v).inMinutes < hours * 60;
  }

  /// Whether this viewer should be offered the result dialog. A submission is
  /// one-shot (ER2.1), so having already used it disqualifies just as firmly as
  /// the slot not having started.
  bool get canSubmitResult =>
      isAccepted && slotStarted && myTeamId != null && !iSubmitted;

  /// Both captains submitted and they agreed — my side is done and the venue owner
  /// is the one holding it up.
  bool get waitingOnOwner => isAwaitingOwner;

  /// I have submitted and the other captain has not.
  bool get waitingOnOpponent => isAccepted && iSubmitted;
}

/// One captain's submitted scoreline. Two of these decide a match.
class MatchSubmission {
  final String teamId;
  final String? teamName;
  final String? submittedBy;
  final String? submittedByName;
  final int? scoreChallenger;
  final int? scoreOpponent;
  final String? winnerTeam;
  final DateTime? submittedAt;

  const MatchSubmission({
    required this.teamId,
    this.teamName,
    this.submittedBy,
    this.submittedByName,
    this.scoreChallenger,
    this.scoreOpponent,
    this.winnerTeam,
    this.submittedAt,
  });

  factory MatchSubmission.fromJson(Map<String, dynamic> j) => MatchSubmission(
        teamId: '${j['teamId'] ?? j['submittedByTeam'] ?? ''}',
        teamName: _str(j['teamName']),
        submittedBy: _str(j['submittedBy']),
        submittedByName: _str(j['submittedByName']),
        scoreChallenger: _intOrNull(j['scoreChallenger']),
        scoreOpponent: _intOrNull(j['scoreOpponent']),
        winnerTeam: _str(j['winnerTeam']),
        submittedAt: _date(j['submittedAt']),
      );

  String get scoreline => '${scoreChallenger ?? '–'} – ${scoreOpponent ?? '–'}';
}

/// A candidate opponent from `GET /matches/opponents` — a team plus everything
/// that only exists *because of the pairing*: the rating gap, the
/// competitiveness score, and the trust badge (FR5.3 – FR5.5).
///
/// S.5 Wave B added the breakdown fields. [competitiveness] is unchanged in
/// meaning and still obeys FR5.4 (null while either team is unranked), but its
/// VALUE now comes from the three-component scorer when that service answered,
/// and from the v1 rating-gap formula when it did not. Which one produced it is
/// `OpponentList.ranking.available` — the row itself deliberately does not carry a
/// per-row flag, because the whole list is ordered by one engine or the other.
class OpponentCandidate {
  final MatchSide team;
  final int eloGap;

  /// Inside the ±400 preferred band (FR5.3). On the fallback path the list is
  /// ordered by |gap|, so every in-band team precedes every out-of-band one and
  /// this marks the boundary. On the ranked path the order is by match quality, so
  /// this is only a per-row marker and no longer a divider.
  final bool withinBand;

  /// FR5.4 — 5..100, null while either team is unranked.
  final int? competitiveness;

  /// The scorer's overall percentage. Null on the fallback path, and null is not
  /// zero: it means no score was computed, so none is shown.
  final int? matchPct;

  /// The same figure before the percent band, kept for the breakdown footer.
  final double? rankScore;

  /// Component key → 0..1, or null for a block that had no input. Null map on
  /// the fallback path.
  final Map<String, double?>? components;

  /// Short server-written phrases naming the blocks that carried this match.
  final List<String> reasons;

  /// Terminal matches in the activity window — the raw count behind the activity
  /// component, so the expander can show evidence and not just a bar.
  final int matchesLast30d;

  const OpponentCandidate({
    required this.team,
    required this.eloGap,
    required this.withinBand,
    this.competitiveness,
    this.matchPct,
    this.rankScore,
    this.components,
    this.reasons = const [],
    this.matchesLast30d = 0,
  });

  factory OpponentCandidate.fromJson(Map<String, dynamic> j) => OpponentCandidate(
        team: MatchSide.fromJson(j),
        eloGap: _int(j['eloGap']),
        withinBand: _bool(j['withinBand']),
        competitiveness: _intOrNull(j['competitiveness']),
        matchPct: _intOrNull(j['matchPct']),
        rankScore: _dblOrNull(j['rankScore']),
        components: RankingInfo.componentsFrom(j['components']),
        reasons: (j['reasons'] as List? ?? const [])
            .map((e) => '$e'.trim())
            .where((s) => s.isNotEmpty)
            .toList(),
        matchesLast30d: _int(j['matchesLast30d']),
      );

  /// Whether there is anything to open a "Why this match?" row onto.
  bool get hasBreakdown => components != null && components!.isNotEmpty;
}

/// The whole opponent-picker payload: the candidates plus who I am in this.
class OpponentList {
  final MatchSide? myTeam;
  final String? myRole;
  final bool canChallenge;
  final int preferredBand;

  /// S.5 Wave B — which engine ordered this list and scored its rows. The screen
  /// reads `available` before drawing any percentage, and `fallbackNote` when it
  /// is false.
  final RankingInfo ranking;

  final List<OpponentCandidate> opponents;

  const OpponentList({
    this.myTeam,
    this.myRole,
    required this.canChallenge,
    required this.preferredBand,
    this.ranking = RankingInfo.none,
    required this.opponents,
  });

  factory OpponentList.fromJson(Map<String, dynamic> j) {
    final mt = j['myTeam'];
    final rk = j['ranking'];
    return OpponentList(
      myTeam: mt is Map ? MatchSide.fromJson(Map<String, dynamic>.from(mt)) : null,
      myRole: _str(j['myRole']),
      canChallenge: _bool(j['canChallenge']),
      preferredBand: _int(j['preferredBand'], 400),
      ranking: rk is Map
          ? RankingInfo.fromJson(Map<String, dynamic>.from(rk))
          : RankingInfo.none,
      opponents: (j['opponents'] as List? ?? const [])
          .whereType<Map>()
          .map((x) => OpponentCandidate.fromJson(Map<String, dynamic>.from(x)))
          .toList(),
    );
  }

  static const OpponentList empty = OpponentList(
    canChallenge: false,
    preferredBand: 400,
    opponents: [],
  );
}

/// `GET /matches/preview` — both sides, the competitiveness, and the sentence.
class MatchPreview {
  final MatchSide challenger;
  final MatchSide opponent;
  final int? competitiveness;
  final String previewText;
  final String previewLabel;
  final int eloGap;
  final bool withinPreferredBand;

  const MatchPreview({
    required this.challenger,
    required this.opponent,
    this.competitiveness,
    required this.previewText,
    required this.previewLabel,
    required this.eloGap,
    required this.withinPreferredBand,
  });

  factory MatchPreview.fromJson(Map<String, dynamic> j) => MatchPreview(
        challenger: MatchSide.fromJson(
            Map<String, dynamic>.from(j['challenger'] as Map? ?? const {})),
        opponent: MatchSide.fromJson(
            Map<String, dynamic>.from(j['opponent'] as Map? ?? const {})),
        competitiveness: _intOrNull(j['competitiveness']),
        previewText: '${j['previewText'] ?? ''}',
        previewLabel: '${j['previewLabel'] ?? 'Preview'}',
        eloGap: _int(j['eloGap']),
        withinPreferredBand: _bool(j['withinPreferredBand']),
      );
}

/// A confirmed future booking a challenge can be pinned to (FR5.11).
class LinkableBooking {
  final String id;
  final DateTime? slotDate;
  final String? startTime;
  final String? endTime;
  final String? venueId;
  final String? venueName;
  final String? venueCity;
  final String? sportType;
  final num? totalAmount;

  const LinkableBooking({
    required this.id,
    this.slotDate,
    this.startTime,
    this.endTime,
    this.venueId,
    this.venueName,
    this.venueCity,
    this.sportType,
    this.totalAmount,
  });

  factory LinkableBooking.fromJson(Map<String, dynamic> j) => LinkableBooking(
        id: '${j['id']}',
        slotDate: _date(j['slotDate'] ?? j['slot_date']),
        startTime: _str(j['startTime'] ?? j['start_time']),
        endTime: _str(j['endTime'] ?? j['end_time']),
        venueId: _str(j['venueId'] ?? j['venue_id']),
        venueName: _str(j['venueName'] ?? j['venue_name']),
        venueCity: _str(j['venueCity'] ?? j['venue_city']),
        sportType: _str(j['sportType'] ?? j['sport_type']),
        totalAmount: j['totalAmount'] == null && j['total_amount'] == null
            ? null
            : asNum(j['totalAmount'] ?? j['total_amount']),
      );

  String get timeRange {
    final a = MatchBooking.prettyTime(startTime);
    final b = MatchBooking.prettyTime(endTime);
    if (a.isEmpty) return '';
    return b.isEmpty ? a : '$a – $b';
  }

  /// `Sat, 23 Aug`. Written out rather than pulling in a date package for one
  /// label.
  String get prettyDate {
    final d = slotDate;
    if (d == null) return '';
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${days[d.weekday - 1]}, ${d.day} ${months[d.month - 1]}';
  }
}

/// `GET /matches?team_id=` — the Match Center, already bucketed by the server.
class MatchCenterData {
  final String teamId;
  final String? myRole;
  final List<MatchModel> incoming;
  final List<MatchModel> outgoing;
  final List<MatchModel> upcoming;
  final List<MatchModel> history;

  /// FR5.17 — the dispute window, straight from `global_settings`.
  final int disputeWindowHours;

  const MatchCenterData({
    required this.teamId,
    this.myRole,
    required this.incoming,
    required this.outgoing,
    required this.upcoming,
    required this.history,
    required this.disputeWindowHours,
  });

  static List<MatchModel> _list(dynamic v) => (v as List? ?? const [])
      .whereType<Map>()
      .map((x) => MatchModel.fromJson(Map<String, dynamic>.from(x)))
      .toList();

  factory MatchCenterData.fromJson(Map<String, dynamic> j) {
    final ch = Map<String, dynamic>.from(j['challenges'] as Map? ?? const {});
    return MatchCenterData(
      teamId: '${j['teamId'] ?? ''}',
      myRole: _str(j['myRole']),
      incoming: _list(ch['incoming']),
      outgoing: _list(ch['outgoing']),
      upcoming: _list(j['upcoming']),
      history: _list(j['history']),
      disputeWindowHours: _int(j['disputeWindowHours'], 24),
    );
  }

  static const MatchCenterData empty = MatchCenterData(
    teamId: '',
    incoming: [],
    outgoing: [],
    upcoming: [],
    history: [],
    disputeWindowHours: 24,
  );

  bool get amCaptain => myRole == 'captain';
  int get pendingCount => incoming.length;
  bool get isEmpty =>
      incoming.isEmpty && outgoing.isEmpty && upcoming.isEmpty && history.isEmpty;
}
