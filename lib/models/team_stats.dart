/// Ranking, stats and ELO-history models — S2 Wave D.
///
/// These parse `GET /api/teams/rankings` and the `stats` / `eloHistory` blocks
/// that `GET /api/teams/:id` gained in Wave D.
///
/// Key detail: these fields are snake_case, and that is deliberate. routes/
/// teams.js returns columns straight out of SQL (`logo_url`, `member_count`),
/// while routes/matches.js hand-shapes camelCase (`logoUrl`, `displayElo`). Both
/// conventions are live in this app. Parsing the wrong one silently yields null
/// or 0 — no exception, no warning, just a screen full of zeroes — so each model
/// reads exactly the casing its own endpoint emits.
library;

import 'team.dart' show asNum;

/// FR2.6 in one place on the client: `displayElo` is null until a team has a
/// verified match, and no screen may substitute the 1000 seed for it.
mixin RatingDisplay {
  bool get ranked;
  int? get displayElo;

  /// "1,240" or "Unranked" — the only string a screen should print for a rating.
  String get eloLabel => ranked && displayElo != null ? _thousands(displayElo!) : 'Unranked';
}

String _thousands(int v) => v.toString().replaceAllMapped(
    RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');

/// One row of the leaderboard.
class RankedTeam with RatingDisplay {
  final String id, name, sport;
  final String? logoUrl, city, captainId;
  final int memberCount;
  final int wins, losses, draws, played;
  final int rank;

  /// Places gained since 7 days ago. Positive = climbed, negative = fell,
  /// 0 = held. **null means the team was not on the board then** ("NEW") — it is
  /// not the same as 0, and a screen that treats it as 0 invents a history.
  final int? movement;

  @override
  final bool ranked;
  @override
  final int? displayElo;

  final bool eloFrozen;

  /// Whether the signed-in viewer is a member of this team (FR5.13 highlight).
  /// Computed by the server, which is the only side that knows the viewer.
  final bool isMine;

  const RankedTeam({
    required this.id,
    required this.name,
    required this.sport,
    required this.rank,
    this.logoUrl,
    this.city,
    this.captainId,
    this.memberCount = 0,
    this.wins = 0,
    this.losses = 0,
    this.draws = 0,
    this.played = 0,
    this.movement,
    this.ranked = false,
    this.displayElo,
    this.eloFrozen = false,
    this.isMine = false,
  });

  int get winRate => played == 0 ? 0 : ((wins / played) * 100).round();

  bool get isNewEntry => movement == null;
  bool get climbed => (movement ?? 0) > 0;
  bool get fell => (movement ?? 0) < 0;

  factory RankedTeam.fromJson(Map<String, dynamic> j) => RankedTeam(
        id: '${j['id']}',
        name: '${j['name'] ?? 'Team'}',
        sport: '${j['sport'] ?? ''}',
        rank: asNum(j['rank']).toInt(),
        logoUrl: j['logo_url'] as String?,
        city: j['city'] as String?,
        captainId: j['captain_id']?.toString(),
        memberCount: asNum(j['member_count']).toInt(),
        wins: asNum(j['wins']).toInt(),
        losses: asNum(j['losses']).toInt(),
        draws: asNum(j['draws']).toInt(),
        played: asNum(j['played']).toInt(),
        // Straight through, because null carries meaning here.
        movement: j['movement'] == null ? null : asNum(j['movement']).toInt(),
        ranked: j['ranked'] == true,
        displayElo: j['display_elo'] == null ? null : asNum(j['display_elo']).toInt(),
        eloFrozen: j['elo_frozen'] == true,
        isMine: j['is_mine'] == true,
      );
}

/// A city chip: the city plus how many ranked teams it holds.
class CityCount {
  final String city;
  final int teams;
  const CityCount(this.city, this.teams);

  factory CityCount.fromJson(Map<String, dynamic> j) =>
      CityCount('${j['city'] ?? ''}', asNum(j['teams']).toInt());
}

/// The whole `GET /teams/rankings` payload. It is an object rather than a bare
/// list because the chips must come from the same query as the rows.
class RankingsPage {
  final List<RankedTeam> teams;
  final List<CityCount> cities;
  final String? sport, city;
  final int rankedMinMatches;
  final int movementWindowDays;

  const RankingsPage({
    this.teams = const [],
    this.cities = const [],
    this.sport,
    this.city,
    this.rankedMinMatches = 1,
    this.movementWindowDays = 7,
  });

  bool get isEmpty => teams.isEmpty;

  factory RankingsPage.fromJson(Map<String, dynamic> j) => RankingsPage(
        teams: (j['teams'] as List? ?? [])
            .whereType<Map>()
            .map((x) => RankedTeam.fromJson(Map<String, dynamic>.from(x)))
            .toList(),
        cities: (j['cities'] as List? ?? [])
            .whereType<Map>()
            .map((x) => CityCount.fromJson(Map<String, dynamic>.from(x)))
            .toList(),
        sport: j['sport'] as String?,
        city: j['city'] as String?,
        rankedMinMatches: asNum(j['rankedMinMatches'], 1).toInt(),
        movementWindowDays: asNum(j['movementWindowDays'], 7).toInt(),
      );
}

/// The team profile's stat snapshot (FR5.15) plus the two S.5 recommender
/// features (last-5 form string, 30-day activity count).
class TeamStats with RatingDisplay {
  final int wins, losses, draws, played, winRate;
  @override
  final bool ranked;
  @override
  final int? displayElo;
  final bool eloFrozen;

  /// Newest-first run of W/L/D over the last 5 completed matches, e.g. "WWLDW".
  /// '' before a team has completed one — never null.
  final String form;

  final int activity30d;
  final int activityWindowDays;
  final int rankedMinMatches;

  const TeamStats({
    this.wins = 0,
    this.losses = 0,
    this.draws = 0,
    this.played = 0,
    this.winRate = 0,
    this.ranked = false,
    this.displayElo,
    this.eloFrozen = false,
    this.form = '',
    this.activity30d = 0,
    this.activityWindowDays = 30,
    this.rankedMinMatches = 1,
  });

  /// Oldest-to-newest, which is how a form row reads left to right.
  List<String> get formSequence => form.split('').reversed.toList();

  factory TeamStats.fromJson(Map<String, dynamic> j) => TeamStats(
        wins: asNum(j['wins']).toInt(),
        losses: asNum(j['losses']).toInt(),
        draws: asNum(j['draws']).toInt(),
        played: asNum(j['played']).toInt(),
        winRate: asNum(j['win_rate']).toInt(),
        ranked: j['ranked'] == true,
        displayElo: j['display_elo'] == null ? null : asNum(j['display_elo']).toInt(),
        eloFrozen: j['elo_frozen'] == true,
        form: '${j['form'] ?? ''}',
        activity30d: asNum(j['activity_30d']).toInt(),
        activityWindowDays: asNum(j['activity_window_days'], 30).toInt(),
        rankedMinMatches: asNum(j['ranked_min_matches'], 1).toInt(),
      );
}

/// One point on the ELO chart and one row of the match history (FR5.14/FR5.16).
class EloPoint {
  final String matchId;
  final DateTime? at;
  final String status;

  /// FR5.14's two dot styles: [verified] draws a solid green dot, [disputed] a
  /// hollow red one.
  final bool verified, disputed;

  /// Whether any rating moved. A verified match can still be unrated
  /// when the team's rating is frozen (ER2.3) — that is not a dispute, and the
  /// UI must not label it as one.
  final bool rated;

  final String? opponentId, opponentName, opponentLogo;
  final int myScore, theirScore;

  /// 'win' | 'loss' | 'draw' | 'disputed'
  final String result;

  final int? eloBefore, eloAfter, eloDelta;

  /// Where the dot sits on the y-axis. The server carries the last known rating
  /// forward across unrated matches, so this is never null in a parsed series.
  final int eloAt;

  const EloPoint({
    required this.matchId,
    required this.eloAt,
    this.at,
    this.status = '',
    this.verified = false,
    this.disputed = false,
    this.rated = false,
    this.opponentId,
    this.opponentName,
    this.opponentLogo,
    this.myScore = 0,
    this.theirScore = 0,
    this.result = 'draw',
    this.eloBefore,
    this.eloAfter,
    this.eloDelta,
  });

  bool get isWin => result == 'win';
  bool get isLoss => result == 'loss';
  bool get isDraw => result == 'draw';

  /// "Won 2–1" / "Lost 0–3" / "Drew 1–1" / "Disputed 2–1" — FR5.16's phrasing,
  /// with a real en dash between the scores.
  String get headline {
    final score = '$myScore–$theirScore';
    return switch (result) {
      'win' => 'Won $score',
      'loss' => 'Lost $score',
      'disputed' => 'Disputed $score',
      _ => 'Drew $score',
    };
  }

  /// "+18" / "-14" / null when nothing moved. Never "+0": a frozen or disputed
  /// match has no delta to show, and printing +0 would imply a rated draw.
  String? get deltaLabel {
    final d = eloDelta;
    if (!rated || d == null || d == 0) return null;
    return d > 0 ? '+$d' : '$d';
  }

  factory EloPoint.fromJson(Map<String, dynamic> j) => EloPoint(
        matchId: '${j['match_id']}',
        eloAt: asNum(j['elo_at']).toInt(),
        at: j['at'] == null ? null : DateTime.tryParse('${j['at']}')?.toLocal(),
        status: '${j['status'] ?? ''}',
        verified: j['verified'] == true,
        disputed: j['disputed'] == true,
        rated: j['rated'] == true,
        opponentId: j['opponent_id']?.toString(),
        opponentName: j['opponent_name'] as String?,
        opponentLogo: j['opponent_logo'] as String?,
        myScore: asNum(j['my_score']).toInt(),
        theirScore: asNum(j['their_score']).toInt(),
        result: '${j['result'] ?? 'draw'}',
        eloBefore: j['elo_before'] == null ? null : asNum(j['elo_before']).toInt(),
        eloAfter: j['elo_after'] == null ? null : asNum(j['elo_after']).toInt(),
        eloDelta: j['elo_delta'] == null ? null : asNum(j['elo_delta']).toInt(),
      );

  static List<EloPoint> listFrom(dynamic raw) => (raw as List? ?? [])
      .whereType<Map>()
      .map((x) => EloPoint.fromJson(Map<String, dynamic>.from(x)))
      .toList();
}
