library;

import 'match.dart' show MatchBooking;
import 'team.dart' show asNum, Team;

/// Wire models for the tournament module (SRS Module 6, S.7 Wave A).
///
/// These mirror `tournamentService`'s shapers one field at a time — `shapeTournament`,
/// `shapeFixture`, `shapeRegistration`, `standings`, `economicsOf`, `viewerContext` —
/// and derive nothing the server already decided. The server computes capacity,
/// eligibility, the Elo win probability and every rupee of the money waterfall inside
/// a locked transaction; a second copy of that arithmetic here would only give the two
/// halves a way to disagree about who is in and what they are owed.
///
/// Every numeric read goes through [asNum] because Postgres hands back decimal
/// columns as strings: an entry fee arriving as `"2000.00"` would silently become
/// null and render as a free tournament.
///
/// The one thing this file does derive is presentation — `capacityFraction`,
/// `countdown`, `perPlayer` — because those are pixels, not policy.

int _int(dynamic v, [int fallback = 0]) => asNum(v, fallback).round();
int? _intOrNull(dynamic v) => v == null ? null : asNum(v, 0).round();
double _dbl(dynamic v, [double fallback = 0]) => asNum(v, fallback).toDouble();
double? _dblOrNull(dynamic v) => v == null ? null : asNum(v, 0).toDouble();
bool _bool(dynamic v) => v == true;

String? _str(dynamic v) {
  final s = v?.toString();
  return (s == null || s.isEmpty) ? null : s;
}

DateTime? _date(dynamic v) => v == null ? null : DateTime.tryParse('$v')?.toLocal();

Map<String, dynamic> _map(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

List<Map<String, dynamic>> _rows(dynamic v) => (v as List? ?? const [])
    .whereType<Map>()
    .map((x) => Map<String, dynamic>.from(x))
    .toList();

/// The four states a tournament holds. Plain strings rather than an enum, for the
/// same reason [MatchStatus] is: an unknown state from a newer backend must render
/// as *something* instead of throwing, and the string is what the API speaks.
class TournamentStatus {
  TournamentStatus._();
  static const String open = 'open';
  static const String active = 'active';
  static const String completed = 'completed';
  static const String cancelled = 'cancelled';
}

class TournamentFormat {
  TournamentFormat._();
  static const String knockout = 'knockout';
  static const String roundRobin = 'round_robin';

  static String label(String? raw) =>
      raw == roundRobin ? 'Round robin' : 'Knockout';
}

class FixtureStatus {
  FixtureStatus._();
  static const String upcoming = 'upcoming';
  static const String played = 'played';
  static const String walkover = 'walkover';
  static const String cancelled = 'cancelled';
}

/// An entry's five states. `registered` means the fee is held and the organiser has
/// not decided; `accepted` is the post-payment, in-the-field state. The wording in
/// the UI must keep those apart — see [EntryStatus.label].
class EntryStatus {
  EntryStatus._();
  static const String registered = 'registered';
  static const String accepted = 'accepted';
  static const String rejected = 'rejected';
  static const String withdrawn = 'withdrawn';
  static const String eliminated = 'eliminated';

  static String label(String? raw) => const {
        registered: 'Awaiting approval',
        accepted: 'Confirmed',
        rejected: 'Rejected',
        withdrawn: 'Withdrawn',
        eliminated: 'Knocked out',
      }[raw] ??
      (raw ?? '');
}

/// The venue a tournament is played at, as `shapeTournament.venue`.
class TournamentVenue {
  final String? id;
  final String? name;
  final String? city;
  final String? address;
  final String? sportType;
  final double? rating;
  final double? pricePerHour;

  const TournamentVenue({
    this.id,
    this.name,
    this.city,
    this.address,
    this.sportType,
    this.rating,
    this.pricePerHour,
  });

  factory TournamentVenue.fromJson(Map<String, dynamic> j) => TournamentVenue(
        id: _str(j['id']),
        name: _str(j['name']),
        city: _str(j['city']),
        address: _str(j['address']),
        sportType: _str(j['sportType']),
        rating: _dblOrNull(j['rating']),
        pricePerHour: _dblOrNull(j['pricePerHour']),
      );

  static const TournamentVenue unknown = TournamentVenue();

  String get display => name ?? 'The venue';
  String get where => [name, city].whereType<String>().join(' · ');
}

/// FR — the tournament record that 019 put on `teams`, and the reason there is no
/// second ELO ladder: "12 played · 8 W · 2 titles" is a concrete achievement, where
/// a separate tournament rating would be a second abstract number nobody can place.
class TeamRecord {
  final int played;
  final int wins;
  final int finals;
  final int titles;

  const TeamRecord({
    this.played = 0,
    this.wins = 0,
    this.finals = 0,
    this.titles = 0,
  });

  factory TeamRecord.fromJson(Map<String, dynamic> j) => TeamRecord(
        played: _int(j['played']),
        wins: _int(j['wins']),
        finals: _int(j['finals']),
        titles: _int(j['titles']),
      );

  static const TeamRecord none = TeamRecord();

  bool get isEmpty => played == 0 && titles == 0 && finals == 0;

  /// The line the team card prints. Empty when the squad has never entered one —
  /// "0 played · 0 W" on every card would be noise on most of them.
  String get line {
    if (isEmpty) return '';
    final parts = <String>['$played played', '$wins W'];
    if (finals > 0) parts.add('$finals ${finals == 1 ? 'final' : 'finals'}');
    if (titles > 0) parts.add('$titles ${titles == 1 ? 'title' : 'titles'} 🏆');
    return parts.join(' · ');
  }
}

/// The same four counters as they arrive on a `teams` row, where they keep the
/// column names migration 019 gave them rather than the tournament payload's
/// shorter keys.
///
/// An extension, and on this side of the import, so that the S.2 team model does
/// not have to learn about the tournament module to carry four integers: the
/// dependency runs tournament → team, never back.
extension TeamTournamentRecord on Team {
  TeamRecord get tournamentRecord => TeamRecord(
        played: tournamentPlayed,
        wins: tournamentWins,
        finals: finalsReached,
        titles: titles,
      );
}

/// My team's entry, as `mine().playing[].myEntry`. Only present on that endpoint —
/// the browse list has no viewer, and the detail payload carries the fuller
/// [Registration] under `viewer.myRegistration`.
class MyEntry {
  final String teamId;
  final String teamName;
  final String status;
  final int? seed;
  final double paidAmount;
  final int? eliminatedRound;
  final bool isCaptain;

  const MyEntry({
    required this.teamId,
    required this.teamName,
    required this.status,
    this.seed,
    this.paidAmount = 0,
    this.eliminatedRound,
    this.isCaptain = false,
  });

  factory MyEntry.fromJson(Map<String, dynamic> j) => MyEntry(
        teamId: '${j['teamId']}',
        teamName: '${j['teamName'] ?? 'My team'}',
        status: '${j['status'] ?? ''}',
        seed: _intOrNull(j['seed']),
        paidAmount: _dbl(j['paidAmount']),
        eliminatedRound: _intOrNull(j['eliminatedRound']),
        isCaptain: _bool(j['isCaptain']),
      );

  String get label => EntryStatus.label(status);
  bool get isHolding =>
      status == EntryStatus.registered || status == EntryStatus.accepted;

  /// Only a captain can withdraw or be paid, so the screen must not offer either
  /// to a squad member who can nevertheless see the bracket.
  bool get canWithdraw => isCaptain && isHolding;
}

/// One tournament, exactly as `shapeTournament` sends it, plus the three fields the
/// browse list adds (`secondsToDeadline`, `isFull`, `organiserName`) and the one
/// `mine()` adds (`myEntry`). All four are nullable so a single class covers all
/// three endpoints instead of three near-identical ones.
class Tournament {
  final String id;
  final String name;
  final String? description;
  final String sport;
  final String format;
  final String status;
  final String? ownerId;
  final String? ownerName;
  final String? ownerPhone;
  final TournamentVenue venue;

  final double entryFee;
  final int maxTeams;
  final int minTeams;
  final bool requiresApproval;

  /// Entries that hold a place: registered + accepted. This is the number capacity
  /// is measured against, not `teamsAccepted` — a fee is frozen the moment a captain
  /// registers, so the spot is gone before the organiser approves it.
  final int teamsRegistered;
  final int teamsAccepted;
  final int teamsPending;
  final int spotsLeft;

  final DateTime? registrationDeadline;
  final String? startDate;
  final int? rounds;
  final int slotMinutes;

  /// The server's answer to "is registration open" — status, deadline and capacity
  /// in one boolean, computed against the server's clock. The phone's clock is not
  /// trusted for this; the countdown is cosmetic, this is the gate.
  final bool registrationOpen;

  final int prizePercent;
  final int winnerPercent;
  final int runnerupPercent;
  final int venueDiscountPercent;

  final String? winnerTeam;
  final String? winnerName;
  final String? runnerUpTeam;
  final String? runnerUpName;

  /// Zero until the bracket is drawn; from then on these are the settled figures the
  /// ledger moved, not a projection. The projection lives in [Economics].
  final double pool;
  final double venueCost;
  final double prize;
  final double ownerEarning;

  final DateTime? fixturesGeneratedAt;
  final DateTime? activatedAt;
  final DateTime? completedAt;
  final DateTime? cancelledAt;
  final String? cancelReason;
  final DateTime? createdAt;

  // Browse-only
  final int? secondsToDeadline;
  final bool? fullFlag;
  final String? organiserName;

  // Mine()-only
  final MyEntry? myEntry;

  /// `mine().organising[]` carries the money block inline so the owner's list can
  /// show earnings without a detail call per row.
  final Economics? economics;

  const Tournament({
    required this.id,
    required this.name,
    this.description,
    required this.sport,
    required this.format,
    required this.status,
    this.ownerId,
    this.ownerName,
    this.ownerPhone,
    this.venue = TournamentVenue.unknown,
    required this.entryFee,
    required this.maxTeams,
    required this.minTeams,
    this.requiresApproval = false,
    this.teamsRegistered = 0,
    this.teamsAccepted = 0,
    this.teamsPending = 0,
    this.spotsLeft = 0,
    this.registrationDeadline,
    this.startDate,
    this.rounds,
    this.slotMinutes = 60,
    this.registrationOpen = false,
    this.prizePercent = 60,
    this.winnerPercent = 70,
    this.runnerupPercent = 30,
    this.venueDiscountPercent = 0,
    this.winnerTeam,
    this.winnerName,
    this.runnerUpTeam,
    this.runnerUpName,
    this.pool = 0,
    this.venueCost = 0,
    this.prize = 0,
    this.ownerEarning = 0,
    this.fixturesGeneratedAt,
    this.activatedAt,
    this.completedAt,
    this.cancelledAt,
    this.cancelReason,
    this.createdAt,
    this.secondsToDeadline,
    this.fullFlag,
    this.organiserName,
    this.myEntry,
    this.economics,
  });

  /// One factory for all three endpoints. The browse row is a strict subset of
  /// `shapeTournament` with the same key names, so the only special case is
  /// `registrationOpen`, which browse omits: there it is assembled from the fields
  /// browse *does* send — all three server-computed — rather than invented here.
  factory Tournament.fromJson(Map<String, dynamic> j) {
    final status = '${j['status'] ?? TournamentStatus.open}';
    final full = j['isFull'] == null ? null : _bool(j['isFull']);
    final seconds = _intOrNull(j['secondsToDeadline']);
    final open = j.containsKey('registrationOpen')
        ? _bool(j['registrationOpen'])
        : status == TournamentStatus.open &&
            full != true &&
            (seconds == null || seconds > 0);

    return Tournament(
      id: '${j['id']}',
      name: '${j['name'] ?? 'Tournament'}',
      description: _str(j['description']),
      sport: '${j['sport'] ?? ''}',
      format: '${j['format'] ?? TournamentFormat.knockout}',
      status: status,
      ownerId: _str(j['ownerId']),
      ownerName: _str(j['ownerName']),
      ownerPhone: _str(j['ownerPhone']),
      venue: TournamentVenue.fromJson(_map(j['venue'])),
      entryFee: _dbl(j['entryFee']),
      maxTeams: _int(j['maxTeams'], 8),
      minTeams: _int(j['minTeams'], 4),
      requiresApproval: _bool(j['requiresApproval']),
      teamsRegistered: _int(j['teamsRegistered']),
      teamsAccepted: _int(j['teamsAccepted']),
      teamsPending: _int(j['teamsPending']),
      spotsLeft: _int(j['spotsLeft']),
      registrationDeadline: _date(j['registrationDeadline']),
      startDate: _str(j['startDate']),
      rounds: _intOrNull(j['rounds']),
      slotMinutes: _int(j['slotMinutes'], 60),
      registrationOpen: open,
      prizePercent: _int(j['prizePercent'], 60),
      winnerPercent: _int(j['winnerPercent'], 70),
      runnerupPercent: _int(j['runnerupPercent'], 30),
      venueDiscountPercent: _int(j['venueDiscountPercent']),
      winnerTeam: _str(j['winnerTeam']),
      winnerName: _str(j['winnerName']),
      runnerUpTeam: _str(j['runnerUpTeam']),
      runnerUpName: _str(j['runnerUpName']),
      pool: _dbl(j['pool']),
      venueCost: _dbl(j['venueCost']),
      prize: _dbl(j['prize']),
      ownerEarning: _dbl(j['ownerEarning']),
      fixturesGeneratedAt: _date(j['fixturesGeneratedAt']),
      activatedAt: _date(j['activatedAt']),
      completedAt: _date(j['completedAt']),
      cancelledAt: _date(j['cancelledAt']),
      cancelReason: _str(j['cancelReason']),
      createdAt: _date(j['createdAt']),
      secondsToDeadline: seconds,
      fullFlag: full,
      organiserName: _str(j['organiserName']) ?? _str(j['ownerName']),
      myEntry: j['myEntry'] is Map ? MyEntry.fromJson(_map(j['myEntry'])) : null,
      economics: j['economics'] is Map ? Economics.fromJson(_map(j['economics'])) : null,
    );
  }

  // Presentation, and only presentation

  bool get isFull => fullFlag ?? (spotsLeft <= 0);
  bool get isOpen => status == TournamentStatus.open;
  bool get isActive => status == TournamentStatus.active;
  bool get isCompleted => status == TournamentStatus.completed;
  bool get isCancelled => status == TournamentStatus.cancelled;
  bool get hasBracket => fixturesGeneratedAt != null;

  String get formatLabel => TournamentFormat.label(format);

  String get statusLabel => const {
        TournamentStatus.open: 'Registration open',
        TournamentStatus.active: 'In progress',
        TournamentStatus.completed: 'Finished',
        TournamentStatus.cancelled: 'Cancelled',
      }[status] ??
      status;

  /// 0…1 for the capacity bar. Measured against holding entries, so the bar fills
  /// the instant a fee is frozen rather than when the organiser gets round to
  /// approving — which is also when the spot became unavailable.
  double get capacityFraction {
    if (maxTeams <= 0) return 0;
    final f = teamsRegistered / maxTeams;
    return f < 0 ? 0 : (f > 1 ? 1 : f);
  }

  String get capacityLabel => '$teamsRegistered / $maxTeams teams';

  String get spotsLabel {
    if (isFull) return 'Full';
    if (spotsLeft == 1) return 'Last spot';
    return '$spotsLeft spots left';
  }

  /// How long registration has left. Prefers the server's `secondsToDeadline`
  /// (computed against the server's clock) and falls back to the deadline stamp on
  /// the detail payload, which does not carry the countdown.
  Duration? get timeLeft {
    if (secondsToDeadline != null) return Duration(seconds: secondsToDeadline!);
    final d = registrationDeadline;
    if (d == null) return null;
    final ms = d.difference(DateTime.now()).inMilliseconds;
    return Duration(milliseconds: ms < 0 ? 0 : ms);
  }

  /// "Closes in 2d 4h" · "Closes in 45m" · "Registration closed". Deliberately
  /// coarse above a day: a to-the-second countdown on a three-day deadline is
  /// motion for its own sake.
  String get countdown {
    final left = timeLeft;
    if (left == null) return isOpen ? 'Deadline not set' : statusLabel;
    if (left.inSeconds <= 0) return 'Registration closed';
    if (left.inDays >= 1) {
      final h = left.inHours % 24;
      return 'Closes in ${left.inDays}d${h > 0 ? ' ${h}h' : ''}';
    }
    if (left.inHours >= 1) {
      final m = left.inMinutes % 60;
      return 'Closes in ${left.inHours}h${m > 0 ? ' ${m}m' : ''}';
    }
    if (left.inMinutes >= 1) return 'Closes in ${left.inMinutes}m';
    return 'Closing now';
  }

  /// The line that makes an entry fee comprehensible: one fee, split across a
  /// squad. A captain reading "PKR 4,000" and a captain reading "≈ PKR 571 each"
  /// are looking at the same number and reaching opposite conclusions.
  double perPlayer(int squad) => squad <= 0 ? entryFee : entryFee / squad;

  bool get hasPrize => prize > 0;
  bool get hasChampion => winnerTeam != null;
}

/// One fixture, as `shapeFixture`. `teamB == null` on a bye; both null on a TBD
/// slot the bracket is holding for a winner who has not been decided yet — the
/// bracket UI must render that as a placeholder, not skip it, or the shape of the
/// draw disappears.
class Fixture {
  final String id;
  final int round;
  final int position;
  final String? label;
  final bool isBye;
  final String status;

  final String? teamA;
  final String? teamAName;
  final String? teamALogo;
  final int? teamAElo;
  final String? teamB;
  final String? teamBName;
  final String? teamBLogo;
  final int? teamBElo;

  final int? scoreA;
  final int? scoreB;
  final String? winner;
  final String? scoreline;
  final String? matchId;

  final String? slotId;
  final String? slotDate;
  final String? startTime;
  final String? endTime;
  final double? slotPrice;
  final DateTime? scheduledAt;
  final DateTime? playedAt;

  final int? nextRound;
  final int? nextPosition;

  /// The Elo formula — `1 / (1 + 10^((Rb-Ra)/400))` — computed server-side on read,
  /// so a rating that moved between the draw and kickoff is reflected. Labelled in
  /// the UI as the Elo formula and never as "ML", because it is arithmetic with no
  /// model in it. Null once the fixture has been played: after the fact the
  /// scoreline is the truth and a probability beside it reads like an excuse.
  final double? winProbabilityA;
  final double? winProbabilityB;

  const Fixture({
    required this.id,
    required this.round,
    required this.position,
    this.label,
    this.isBye = false,
    required this.status,
    this.teamA,
    this.teamAName,
    this.teamALogo,
    this.teamAElo,
    this.teamB,
    this.teamBName,
    this.teamBLogo,
    this.teamBElo,
    this.scoreA,
    this.scoreB,
    this.winner,
    this.scoreline,
    this.matchId,
    this.slotId,
    this.slotDate,
    this.startTime,
    this.endTime,
    this.slotPrice,
    this.scheduledAt,
    this.playedAt,
    this.nextRound,
    this.nextPosition,
    this.winProbabilityA,
    this.winProbabilityB,
  });

  factory Fixture.fromJson(Map<String, dynamic> j) => Fixture(
        id: '${j['id']}',
        round: _int(j['round'], 1),
        position: _int(j['position']),
        label: _str(j['label']),
        isBye: _bool(j['isBye']),
        status: '${j['status'] ?? FixtureStatus.upcoming}',
        teamA: _str(j['teamA']),
        teamAName: _str(j['teamAName']),
        teamALogo: _str(j['teamALogo']),
        teamAElo: _intOrNull(j['teamAElo']),
        teamB: _str(j['teamB']),
        teamBName: _str(j['teamBName']),
        teamBLogo: _str(j['teamBLogo']),
        teamBElo: _intOrNull(j['teamBElo']),
        scoreA: _intOrNull(j['scoreA']),
        scoreB: _intOrNull(j['scoreB']),
        winner: _str(j['winner']),
        scoreline: _str(j['scoreline']),
        matchId: _str(j['matchId']),
        slotId: _str(j['slotId']),
        slotDate: _str(j['slotDate']),
        startTime: _str(j['startTime']),
        endTime: _str(j['endTime']),
        slotPrice: _dblOrNull(j['slotPrice']),
        scheduledAt: _date(j['scheduledAt']),
        playedAt: _date(j['playedAt']),
        nextRound: _intOrNull(j['nextRound']),
        nextPosition: _intOrNull(j['nextPosition']),
        winProbabilityA: _dblOrNull(j['winProbabilityA']),
        winProbabilityB: _dblOrNull(j['winProbabilityB']),
      );

  bool get isUpcoming => status == FixtureStatus.upcoming;
  bool get isPlayed => status == FixtureStatus.played;
  bool get isWalkover => status == FixtureStatus.walkover;
  bool get isSettled => isPlayed || isWalkover;

  /// A slot the draw is holding for a winner nobody has decided yet. Rendered as a
  /// placeholder rather than skipped — the shape of the bracket is the information.
  bool get isTbd => teamA == null && teamB == null && !isBye;

  /// Both sides known, so it can be played or scored. A bye and a TBD are
  /// both "not playable", for opposite reasons.
  bool get isPlayable => teamA != null && teamB != null;

  String get nameA => teamAName ?? 'TBD';
  String get nameB => isBye ? 'Bye' : (teamBName ?? 'TBD');

  bool get aWon => winner != null && winner == teamA;
  bool get bWon => winner != null && winner == teamB;

  /// `18:00:00` on `2026-03-14` → "14 Mar · 6:00 PM". The time is the venue's wall
  /// clock, not a timestamp, so it is formatted as-is — reusing the one formatter in
  /// [MatchBooking] rather than a second copy that could drift from it.
  String get when {
    final t = MatchBooking.prettyTime(startTime);
    final d = slotDate;
    if (d == null) return t;
    final parsed = DateTime.tryParse(d);
    final day = parsed == null
        ? d
        : '${parsed.day} ${const [
            'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
            'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
          ][parsed.month - 1]}';
    return t.isEmpty ? day : '$day · $t';
  }

  /// The Elo probability as a percentage string for the favoured side, or null when
  /// there is nothing to say (played, bye, or a rating missing).
  String? get favouriteLine {
    final a = winProbabilityA;
    final b = winProbabilityB;
    if (a == null || b == null || !isPlayable) return null;
    final pct = ((a >= b ? a : b) * 100).round();
    final who = a >= b ? nameA : nameB;
    if (pct <= 55) return 'Even match · $pct%';
    return '$who favoured · $pct%';
  }
}

/// One round of the draw, as `groupRounds` sends it. The bracket screen scrolls
/// these horizontally, one column per round.
class BracketRound {
  final int round;
  final String label;
  final int total;
  final int played;
  final String? date;
  final List<Fixture> fixtures;

  const BracketRound({
    required this.round,
    required this.label,
    this.total = 0,
    this.played = 0,
    this.date,
    this.fixtures = const [],
  });

  factory BracketRound.fromJson(Map<String, dynamic> j) => BracketRound(
        round: _int(j['round'], 1),
        label: '${j['label'] ?? 'Round'}',
        total: _int(j['total']),
        played: _int(j['played']),
        date: _str(j['date']),
        fixtures: _rows(j['fixtures']).map(Fixture.fromJson).toList(),
      );

  bool get isComplete => total > 0 && played >= total;
  String get progress => '$played / $total played';
}

/// The shape of the draw. `generated: false` means the deadline has not passed yet
/// and the bracket does not exist — the screen shows the entered teams and the
/// countdown instead of an empty grid.
class Bracket {
  final String format;
  final int rounds;
  final int? size;
  final int byes;
  final int total;
  final int played;
  final bool generated;
  final List<BracketRound> roundsList;

  const Bracket({
    this.format = TournamentFormat.knockout,
    this.rounds = 0,
    this.size,
    this.byes = 0,
    this.total = 0,
    this.played = 0,
    this.generated = false,
    this.roundsList = const [],
  });

  factory Bracket.fromJson(Map<String, dynamic> j) => Bracket(
        format: '${j['format'] ?? TournamentFormat.knockout}',
        rounds: _int(j['rounds']),
        size: _intOrNull(j['size']),
        byes: _int(j['byes']),
        total: _int(j['total']),
        played: _int(j['played']),
        generated: _bool(j['generated']),
        roundsList: _rows(j['roundsList']).map(BracketRound.fromJson).toList(),
      );

  static const Bracket empty = Bracket();

  bool get isKnockout => format == TournamentFormat.knockout;
  bool get hasByes => byes > 0;
  double get progress => total == 0 ? 0 : played / total;
}

/// One row of the table (SRS FE-7 — "refresh live standings"). Computed for both
/// formats: a knockout has no league table, but it does have "who beat whom and how
/// far did they get", and the same derivation answers that.
class Standing {
  final String teamId;
  final String name;
  final int elo;
  final int? seed;
  final int played;
  final int wins;
  final int draws;
  final int losses;
  final int goalsFor;
  final int goalsAgainst;
  final int goalDiff;
  final int points;
  final int position;

  const Standing({
    required this.teamId,
    required this.name,
    this.elo = 1000,
    this.seed,
    this.played = 0,
    this.wins = 0,
    this.draws = 0,
    this.losses = 0,
    this.goalsFor = 0,
    this.goalsAgainst = 0,
    this.goalDiff = 0,
    this.points = 0,
    this.position = 0,
  });

  factory Standing.fromJson(Map<String, dynamic> j) => Standing(
        teamId: '${j['teamId']}',
        name: '${j['name'] ?? 'Team'}',
        elo: _int(j['elo'], 1000),
        seed: _intOrNull(j['seed']),
        played: _int(j['played']),
        wins: _int(j['wins']),
        draws: _int(j['draws']),
        losses: _int(j['losses']),
        goalsFor: _int(j['goalsFor']),
        goalsAgainst: _int(j['goalsAgainst']),
        goalDiff: _int(j['goalDiff']),
        points: _int(j['points']),
        position: _int(j['position']),
      );

  String get record => 'W $wins · D $draws · L $losses';
  String get goals => '$goalsFor : $goalsAgainst';
  String get diff => goalDiff > 0 ? '+$goalDiff' : '$goalDiff';
}

/// One entered team, as `shapeRegistration`. Withdrawn and rejected rows reach only
/// the organiser — the public list is who holds a spot.
class Registration {
  final String registrationId;
  final String teamId;
  final String teamName;
  final String? logoUrl;
  final String? city;
  final int elo;
  final String? captainId;
  final String? captainName;
  final String status;
  final int? seed;
  final double paidAmount;
  final DateTime? registeredAt;
  final DateTime? approvedAt;
  final DateTime? withdrawnAt;
  final int? eliminatedRound;
  final TeamRecord record;

  const Registration({
    required this.registrationId,
    required this.teamId,
    required this.teamName,
    this.logoUrl,
    this.city,
    this.elo = 1000,
    this.captainId,
    this.captainName,
    required this.status,
    this.seed,
    this.paidAmount = 0,
    this.registeredAt,
    this.approvedAt,
    this.withdrawnAt,
    this.eliminatedRound,
    this.record = TeamRecord.none,
  });

  factory Registration.fromJson(Map<String, dynamic> j) => Registration(
        registrationId: '${j['registrationId']}',
        teamId: '${j['teamId']}',
        teamName: '${j['teamName'] ?? 'Team'}',
        logoUrl: _str(j['logoUrl']),
        city: _str(j['city']),
        elo: _int(j['elo'], 1000),
        captainId: _str(j['captainId']),
        captainName: _str(j['captainName']),
        status: '${j['status'] ?? ''}',
        seed: _intOrNull(j['seed']),
        paidAmount: _dbl(j['paidAmount']),
        registeredAt: _date(j['registeredAt']),
        approvedAt: _date(j['approvedAt']),
        withdrawnAt: _date(j['withdrawnAt']),
        eliminatedRound: _intOrNull(j['eliminatedRound']),
        record: TeamRecord.fromJson(_map(j['record'])),
      );

  String get label => EntryStatus.label(status);
  bool get isPending => status == EntryStatus.registered;
  bool get isAccepted => status == EntryStatus.accepted;
  bool get isOut =>
      status == EntryStatus.withdrawn || status == EntryStatus.rejected;
  bool get holdsASpot => isPending || isAccepted || status == EntryStatus.eliminated;
  String get seedLabel => seed == null ? '' : 'Seed $seed';
}

/// The money waterfall, in one of two modes, and it says which.
///
/// The venue's inventory cost is recovered first and the prize comes out of what is
/// left — not a percentage of the pool — because the venue cost is fixed while the
/// pool is variable. A flat commission on a half-full tournament would pay an owner
/// less than selling the same hours at the counter, which would invert the entire
/// point of the feature:
///
/// ```
/// pool    = entryFee x teams
/// surplus = pool - venueCost            (venueCost = slotTotal less the discount)
/// prize   = surplus x prizePercent      (winner / runner-up split)
/// owner   = venueCost + (surplus - prize)
/// ```
///
/// [settled] `true` means fixtures exist and these are the figures the ledger moved.
/// `false` means no slots have been chosen yet, so it is a projection at list price
/// — the owner's create screen gets the real quote from `POST /tournaments/preview`,
/// which prices actual slots.
///
/// Nothing here is recomputed on the phone. [identityOk] is the server's own proof
/// that `pool == venueCost + prize + margin` to the paisa, carried in the payload so
/// the client can display a discrepancy rather than hide one.
class Economics {
  final bool settled;
  final int teams;
  final double entryFee;
  final double pool;
  final double venueCost;
  final double prize;
  final int prizePercent;
  final int winnerPercent;
  final int runnerupPercent;
  final double winnerShare;
  final double runnerupShare;
  final double margin;
  final double ownerEarning;
  final bool underwater;

  /// Projection-only, and null once settled.
  final double? slotTotal;
  final int? venueDiscountPercent;
  final double? venueDiscount;
  final double? surplus;
  final double? retailValue;
  final double? uplift;
  final double? upliftPercent;
  final bool? identityOk;
  final int? projectedFor;
  final int? hours;
  final double? listPrice;

  const Economics({
    this.settled = false,
    this.teams = 0,
    this.entryFee = 0,
    this.pool = 0,
    this.venueCost = 0,
    this.prize = 0,
    this.prizePercent = 60,
    this.winnerPercent = 70,
    this.runnerupPercent = 30,
    this.winnerShare = 0,
    this.runnerupShare = 0,
    this.margin = 0,
    this.ownerEarning = 0,
    this.underwater = false,
    this.slotTotal,
    this.venueDiscountPercent,
    this.venueDiscount,
    this.surplus,
    this.retailValue,
    this.uplift,
    this.upliftPercent,
    this.identityOk,
    this.projectedFor,
    this.hours,
    this.listPrice,
  });

  factory Economics.fromJson(Map<String, dynamic> j) => Economics(
        settled: _bool(j['settled']),
        teams: _int(j['teams']),
        entryFee: _dbl(j['entryFee']),
        pool: _dbl(j['pool']),
        venueCost: _dbl(j['venueCost']),
        prize: _dbl(j['prize']),
        prizePercent: _int(j['prizePercent'], 60),
        winnerPercent: _int(j['winnerPercent'], 70),
        runnerupPercent: _int(j['runnerupPercent'], 30),
        winnerShare: _dbl(j['winnerShare']),
        runnerupShare: _dbl(j['runnerupShare']),
        margin: _dbl(j['margin']),
        ownerEarning: _dbl(j['ownerEarning']),
        underwater: _bool(j['underwater']),
        slotTotal: _dblOrNull(j['slotTotal']),
        venueDiscountPercent: _intOrNull(j['venueDiscountPercent']),
        venueDiscount: _dblOrNull(j['venueDiscount']),
        surplus: _dblOrNull(j['surplus']),
        retailValue: _dblOrNull(j['retailValue']),
        uplift: _dblOrNull(j['uplift']),
        upliftPercent: _dblOrNull(j['upliftPercent']),
        identityOk: j['identityOk'] == null ? null : _bool(j['identityOk']),
        projectedFor: _intOrNull(j['projectedFor']),
        hours: _intOrNull(j['hours']),
        listPrice: _dblOrNull(j['listPrice']),
      );

  static const Economics empty = Economics();

  bool get isProjection => !settled;
  bool get hasPrize => prize > 0;

  /// True when the pool did not cover the venue's hours. The prize is then zero and
  /// the owner takes the whole pool — money is never taken from the owner — and the
  /// screen has to say so out loud rather than showing a silent "PKR 0 prize".
  bool get isUnderwater => underwater || (pool > 0 && prize <= 0);

  /// The one line that is the whole argument for the feature, from real numbers:
  /// "You earn PKR 21,200 — PKR 7,200 more than selling these 7 hours (+51%)".
  /// Null when there is no retail comparison to make.
  String? upliftLine(String Function(num) money) {
    final retail = retailValue;
    final up = uplift;
    if (retail == null || up == null || retail <= 0) return null;
    final pct = upliftPercent;
    final sign = up >= 0 ? 'more than' : 'less than';
    final suffix = pct == null ? '' : ' (${up >= 0 ? '+' : ''}${pct.round()}%)';
    return 'You earn ${money(ownerEarning)} — ${money(up.abs())} $sign '
        'selling these hours at ${money(retail)}$suffix';
  }

  /// What a squad of [squad] pays each. The number a captain decides on.
  double perPlayer(int squad) => squad <= 0 ? entryFee : entryFee / squad;
}

/// One of my squads that is eligible to enter, as `viewer.eligibleTeams` — right
/// sport, captained by me, not already entered. The server filters this; the picker
/// only draws it.
class EligibleTeam {
  final String id;
  final String name;
  final String? logoUrl;
  final int elo;

  const EligibleTeam({
    required this.id,
    required this.name,
    this.logoUrl,
    this.elo = 1000,
  });

  factory EligibleTeam.fromJson(Map<String, dynamic> j) => EligibleTeam(
        id: '${j['id']}',
        name: '${j['name'] ?? 'Team'}',
        logoUrl: _str(j['logoUrl']),
        elo: _int(j['elo'], 1000),
      );
}

/// The "can I press this" block. Every flag here exists to avoid offering an action
/// the server would refuse — never to permit one. Authority is enforced server-side
/// inside a locked transaction, so a stale `canRegister: true` costs a readable error
/// message, not an unauthorised entry.
class TournamentViewer {
  final bool isOwner;
  final bool isCaptain;
  final String? myTeamId;
  final String? myTeamName;
  final Registration? myRegistration;
  final List<EligibleTeam> eligibleTeams;
  final double? walletBalance;
  final bool? canAfford;
  final bool canRegister;

  const TournamentViewer({
    this.isOwner = false,
    this.isCaptain = false,
    this.myTeamId,
    this.myTeamName,
    this.myRegistration,
    this.eligibleTeams = const [],
    this.walletBalance,
    this.canAfford,
    this.canRegister = false,
  });

  factory TournamentViewer.fromJson(Map<String, dynamic> j) {
    final team = _map(j['myTeam']);
    return TournamentViewer(
      isOwner: _bool(j['isOwner']),
      isCaptain: _bool(j['isCaptain']),
      myTeamId: _str(team['id']),
      myTeamName: _str(team['name']),
      myRegistration: j['myRegistration'] is Map
          ? Registration.fromJson(_map(j['myRegistration']))
          : null,
      eligibleTeams: _rows(j['eligibleTeams']).map(EligibleTeam.fromJson).toList(),
      walletBalance: _dblOrNull(j['walletBalance']),
      canAfford: j['canAfford'] == null ? null : _bool(j['canAfford']),
      canRegister: _bool(j['canRegister']),
    );
  }

  static const TournamentViewer none = TournamentViewer();

  bool get isEntered => myRegistration != null;

  /// A captain can withdraw before the draw; a squad member never can.
  bool get canWithdraw {
    final r = myRegistration;
    return r != null && (r.isPending || r.isAccepted);
  }
}

/// The organiser's view of their own tournament — null for everybody else, which is
/// how the detail screen knows whether to draw the management panel at all.
///
/// [canGenerate] tests the same two conditions `generateFixtures` will, so the
/// button is not offered before it can work.
class OrganiserView {
  final int pendingApprovals;
  final bool canGenerate;
  final bool canCancel;
  final bool deadlinePassed;
  final int unsettledFixtures;

  const OrganiserView({
    this.pendingApprovals = 0,
    this.canGenerate = false,
    this.canCancel = false,
    this.deadlinePassed = false,
    this.unsettledFixtures = 0,
  });

  factory OrganiserView.fromJson(Map<String, dynamic> j) => OrganiserView(
        pendingApprovals: _int(j['pendingApprovals']),
        canGenerate: _bool(j['canGenerate']),
        canCancel: _bool(j['canCancel']),
        deadlinePassed: _bool(j['deadlinePassed']),
        unsettledFixtures: _int(j['unsettledFixtures']),
      );

  bool get hasWork => pendingApprovals > 0 || canGenerate || unsettledFixtures > 0;
}

/// Entry counts, as `detail().counts`. [holding] is the capacity number — registered
/// plus accepted — because a frozen fee has already taken the spot.
class TournamentCounts {
  final int holding;
  final int accepted;
  final int pending;
  final int withdrawn;
  final int rejected;

  const TournamentCounts({
    this.holding = 0,
    this.accepted = 0,
    this.pending = 0,
    this.withdrawn = 0,
    this.rejected = 0,
  });

  factory TournamentCounts.fromJson(Map<String, dynamic> j) => TournamentCounts(
        holding: _int(j['holding']),
        accepted: _int(j['accepted']),
        pending: _int(j['pending']),
        withdrawn: _int(j['withdrawn']),
        rejected: _int(j['rejected']),
      );

  static const TournamentCounts zero = TournamentCounts();
}

/// `GET /api/tournaments/:id` — one payload behind four screens: the browse card's
/// detail, the bracket, the standings table and the organiser's management panel.
/// They are all the same tournament, and a second endpoint would only be a second
/// chance for them to disagree about how many teams are in.
class TournamentDetail {
  final Tournament? tournament;
  final List<Registration> teams;
  final TournamentCounts counts;
  final Bracket bracket;
  final List<Fixture> fixtures;
  final List<Standing> standings;
  final Economics economics;
  final TournamentViewer viewer;
  final OrganiserView? organiser;

  const TournamentDetail({
    this.tournament,
    this.teams = const [],
    this.counts = TournamentCounts.zero,
    this.bracket = Bracket.empty,
    this.fixtures = const [],
    this.standings = const [],
    this.economics = Economics.empty,
    this.viewer = TournamentViewer.none,
    this.organiser,
  });

  factory TournamentDetail.fromJson(Map<String, dynamic> j) => TournamentDetail(
        tournament: j['tournament'] is Map
            ? Tournament.fromJson(_map(j['tournament']))
            : null,
        teams: _rows(j['teams']).map(Registration.fromJson).toList(),
        counts: TournamentCounts.fromJson(_map(j['counts'])),
        bracket: Bracket.fromJson(_map(j['bracket'])),
        fixtures: _rows(j['fixtures']).map(Fixture.fromJson).toList(),
        standings: _rows(j['standings']).map(Standing.fromJson).toList(),
        economics: Economics.fromJson(_map(j['economics'])),
        viewer: TournamentViewer.fromJson(_map(j['viewer'])),
        organiser: j['organiser'] is Map
            ? OrganiserView.fromJson(_map(j['organiser']))
            : null,
      );

  static const TournamentDetail empty = TournamentDetail();

  bool get isEmpty => tournament == null;

  /// The public list — who holds a spot. Withdrawn and rejected rows reach only
  /// the organiser, and showing them to everybody would misreport the field.
  List<Registration> get field => teams.where((t) => t.holdsASpot).toList();

  /// My team's next fixture, for the "you play Saturday at 6" line.
  Fixture? nextFixtureFor(String? teamId) {
    if (teamId == null) return null;
    for (final f in fixtures) {
      if (!f.isUpcoming || !f.isPlayable) continue;
      if (f.teamA == teamId || f.teamB == teamId) return f;
    }
    return null;
  }
}

/// `GET /api/tournaments/mine` — both roles in one call, because a user can be an
/// organiser and a player at the same time and the phone has one "My tournaments"
/// tab. `playing` follows TEAM membership, not captaincy: only a captain can enter
/// or be paid, but every member plays and expects to find it here.
class MyTournaments {
  final List<Tournament> organising;
  final List<Tournament> playing;

  const MyTournaments({this.organising = const [], this.playing = const []});

  factory MyTournaments.fromJson(Map<String, dynamic> j) => MyTournaments(
        organising: _rows(j['organising']).map(Tournament.fromJson).toList(),
        playing: _rows(j['playing']).map(Tournament.fromJson).toList(),
      );

  static const MyTournaments empty = MyTournaments();

  bool get isEmpty => organising.isEmpty && playing.isEmpty;
  int get total => organising.length + playing.length;

  /// Tournaments needing the organiser's attention — approvals waiting, a bracket
  /// ready to draw, results to enter. Drives the badge on the owner's home tile.
  int get organiserTodo => organising
      .where((t) => t.isOpen && (t.teamsPending > 0 || t.isFull))
      .length;
}

/// One round's placement in a preview plan, as `preview().capacity.rounds[]`.
/// `pick` is which hour the scheduler chose — `'off_peak'` for early rounds,
/// `'peak'` for the final — which is the visible half of the demand-aware
/// scheduler's decision.
class PreviewRound {
  final int round;
  final String label;
  final String? pick;
  final String? date;
  final int count;
  final int total;
  final bool spansDays;

  const PreviewRound({
    required this.round,
    required this.label,
    this.pick,
    this.date,
    this.count = 0,
    this.total = 0,
    this.spansDays = false,
  });

  factory PreviewRound.fromJson(Map<String, dynamic> j) => PreviewRound(
        round: _int(j['round'], 1),
        label: '${j['label'] ?? 'Round'}',
        pick: _str(j['pick']),
        date: _str(j['date']),
        count: _int(j['count']),
        total: _int(j['total']),
        spansDays: _bool(j['spansDays']),
      );

  /// "Off-peak" is the interesting word on this screen: it is what makes the venue
  /// cost — and therefore the entry fee — lower, while leaving the owner's sellable
  /// peak hours alone.
  String get pickLabel => const {
        'off_peak': 'Off-peak',
        'peak': 'Peak',
        'any': 'Any hour',
      }[pick] ??
      (pick ?? '');
}

/// Why a plan does not fit, as `alloc.shortfall`: the round that ran out of hours,
/// how many it needed, how many the venue had.
class ScheduleShortfall {
  final int round;
  final int need;
  final int available;

  const ScheduleShortfall({this.round = 0, this.need = 0, this.available = 0});

  factory ScheduleShortfall.fromJson(Map<String, dynamic> j) => ScheduleShortfall(
        round: _int(j['round']),
        need: _int(j['need']),
        available: _int(j['available']),
      );

  String get line => 'Round $round needs $need hours, $available open';
}

/// One end of the preview: what happens at a full field (`capacity`) and at the
/// worst legal turnout (`minimum`). Both are quoted, because a fee that only works
/// with a full field is a fee that loses money the first time six teams turn up
/// instead of eight.
class PreviewPlan {
  final bool schedulable;
  final String? code;
  final String? message;
  final ScheduleShortfall? shortfall;
  final int teams;
  final int fixtures;
  final int byes;
  final int hoursNeeded;
  final int hoursAvailable;

  /// The real sum of the chosen slots' prices — null when the plan does not fit, in
  /// which case [estimatedCost] carries the list-price estimate instead.
  final double? slotTotal;
  final double? estimatedCost;

  final DateTime? firstAt;
  final DateTime? lastAt;
  final String? startDate;
  final String? endDate;
  final List<PreviewRound> rounds;

  const PreviewPlan({
    this.schedulable = false,
    this.code,
    this.message,
    this.shortfall,
    this.teams = 0,
    this.fixtures = 0,
    this.byes = 0,
    this.hoursNeeded = 0,
    this.hoursAvailable = 0,
    this.slotTotal,
    this.estimatedCost,
    this.firstAt,
    this.lastAt,
    this.startDate,
    this.endDate,
    this.rounds = const [],
  });

  factory PreviewPlan.fromJson(Map<String, dynamic> j) => PreviewPlan(
        schedulable: _bool(j['schedulable']),
        code: _str(j['code']),
        message: _str(j['message']),
        shortfall: j['shortfall'] is Map
            ? ScheduleShortfall.fromJson(_map(j['shortfall']))
            : null,
        teams: _int(j['teams']),
        fixtures: _int(j['fixtures']),
        byes: _int(j['byes']),
        hoursNeeded: _int(j['hoursNeeded']),
        hoursAvailable: _int(j['hoursAvailable']),
        slotTotal: _dblOrNull(j['slotTotal']),
        estimatedCost: _dblOrNull(j['estimatedCost']),
        firstAt: _date(j['firstAt']),
        lastAt: _date(j['lastAt']),
        startDate: _str(j['startDate']),
        endDate: _str(j['endDate']),
        rounds: _rows(j['rounds']).map(PreviewRound.fromJson).toList(),
      );

  static const PreviewPlan unknown = PreviewPlan();

  /// The cost figure to print: the real slot total when the plan fits, the estimate
  /// when it does not.
  double? get cost => slotTotal ?? estimatedCost;

  bool get hasByes => byes > 0;
  String get hoursLine => '$hoursNeeded hours needed · $hoursAvailable open';
}

/// The fee the create screen fills in for the owner, worked backwards from the
/// margin they want rather than guessed:
///
/// ```
/// surplus needed = targetMargin / (1 - prizePercent/100)
/// fee            = (venueCost + surplus needed) / minTeams,  rounded up
/// ```
///
/// Divided by `minTeams`, not `maxTeams`: the fee has to survive the worst legal
/// turnout, and a full field then earns more than the target.
/// [achievable] is false when `prizePercent` is 100 — there is no margin to solve
/// for, and the recommendation can only cover cost.
class RecommendedFee {
  final double entryFee;
  final int minTeams;
  final double venueCost;
  final int targetMarginPercent;
  final double targetMargin;
  final bool achievable;
  final double roundedTo;

  /// The breakdown at that fee and the worst legal turnout — the floor of what the
  /// owner is agreeing to, not the best case.
  final Economics atMinTeams;

  const RecommendedFee({
    this.entryFee = 0,
    this.minTeams = 4,
    this.venueCost = 0,
    this.targetMarginPercent = 25,
    this.targetMargin = 0,
    this.achievable = true,
    this.roundedTo = 100,
    this.atMinTeams = Economics.empty,
  });

  factory RecommendedFee.fromJson(Map<String, dynamic> j) => RecommendedFee(
        entryFee: _dbl(j['entryFee']),
        minTeams: _int(j['minTeams'], 4),
        venueCost: _dbl(j['venueCost']),
        targetMarginPercent: _int(j['targetMarginPercent'], 25),
        targetMargin: _dbl(j['targetMargin']),
        achievable: _bool(j['achievable']),
        roundedTo: _dbl(j['roundedTo'], 100),
        atMinTeams: Economics.fromJson(_map(j['atMinTeams'])),
      );

  static const RecommendedFee none = RecommendedFee();
}

/// Which scheduler ran, echoed verbatim from `tournamentScheduler`.
///
/// `source: 'model'` only when the released demand model scored the candidate hours;
/// anything else — ml-service down, breaker open, past the forecast horizon, no base
/// price — is `'chronological'`, and [reason] says which. The demo checks this stamp
/// rather than asserting the AI ran.
class SchedulingMeta {
  final String source;
  final String? modelVersion;
  final String? reason;
  final double? coverage;
  final int candidates;
  final bool cached;
  final List<PreviewRound> picks;

  const SchedulingMeta({
    this.source = 'chronological',
    this.modelVersion,
    this.reason,
    this.coverage,
    this.candidates = 0,
    this.cached = false,
    this.picks = const [],
  });

  factory SchedulingMeta.fromJson(Map<String, dynamic> j) => SchedulingMeta(
        source: '${j['source'] ?? 'chronological'}',
        modelVersion: _str(j['modelVersion']),
        reason: _str(j['reason']),
        coverage: _dblOrNull(j['coverage']),
        candidates: _int(j['candidates']),
        cached: _bool(j['cached']),
        picks: _rows(j['picks']).map(PreviewRound.fromJson).toList(),
      );

  static const SchedulingMeta none = SchedulingMeta();

  bool get fromModel => source == 'model';

  /// What the owner is told. Honest in both directions — claiming the model placed
  /// the fixtures when it did not would be the one lie this block exists to prevent.
  String get label => fromModel
      ? 'Placed in the venue\'s quietest hours by the demand model'
      : 'Placed in date order${reason == null ? '' : ' — $reason'}';
}

/// `POST /api/tournaments/preview` — the economics quote before the tournament
/// exists (SRS FE-1, done properly). This is the mechanism that stops an owner from
/// guessing a fee that loses them money: it prices real slots at the real venue,
/// quotes the full field and the worst legal turnout, and recommends a fee.
class TournamentPreview {
  final TournamentVenue venue;

  /// The validated draft configuration echoed back, kept raw: the create screen
  /// typed it and does not need to read it back, but the evidence binder does.
  final Map<String, dynamic> config;

  final PreviewPlan capacity;
  final PreviewPlan minimum;
  final Economics atCapacity;
  final Economics atMinimum;
  final RecommendedFee recommended;
  final int candidateHours;
  final SchedulingMeta scheduling;

  const TournamentPreview({
    this.venue = TournamentVenue.unknown,
    this.config = const {},
    this.capacity = PreviewPlan.unknown,
    this.minimum = PreviewPlan.unknown,
    this.atCapacity = Economics.empty,
    this.atMinimum = Economics.empty,
    this.recommended = RecommendedFee.none,
    this.candidateHours = 0,
    this.scheduling = SchedulingMeta.none,
  });

  factory TournamentPreview.fromJson(Map<String, dynamic> j) {
    final econ = _map(j['economics']);
    return TournamentPreview(
      venue: TournamentVenue.fromJson(_map(j['venue'])),
      config: _map(j['config']),
      capacity: PreviewPlan.fromJson(_map(j['capacity'])),
      minimum: PreviewPlan.fromJson(_map(j['minimum'])),
      atCapacity: Economics.fromJson(_map(econ['atCapacity'])),
      atMinimum: Economics.fromJson(_map(econ['atMinimum'])),
      recommended: RecommendedFee.fromJson(_map(j['recommended'])),
      candidateHours: _int(j['candidateHours']),
      scheduling: SchedulingMeta.fromJson(_map(_map(j['meta'])['scheduling'])),
    );
  }

  static const TournamentPreview empty = TournamentPreview();

  /// The tournament cannot run at all unless the venue has the hours for the worst
  /// legal turnout. That is the blocking condition, not the full field.
  bool get canRun => minimum.schedulable;

  /// The sentence that blocks the Create button, or null when nothing does.
  String? get blocker {
    if (candidateHours == 0) {
      return 'This venue has no open slots in the scheduling window — add slots first';
    }
    if (!minimum.schedulable) {
      return minimum.message ??
          'Not enough open hours at this venue for ${minimum.teams} teams';
    }
    return null;
  }

  /// True when the full field would not fit but the minimum would: the tournament can
  /// run, though not at the size the owner typed.
  bool get cappedByHours => minimum.schedulable && !capacity.schedulable;
}
