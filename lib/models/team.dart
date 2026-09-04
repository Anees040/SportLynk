/// Team + roster models.
///
/// Postgres returns decimal/BIGINT columns as *strings* over JSON, so every
/// numeric field is parsed through [asNum] rather than a raw cast — a plain
/// `as num` on "1000" throws. This is the one rule that keeps the whole teams
/// layer from crashing on perfectly valid backend responses.
library;

/// Coerce anything the API returns into a number: real numbers pass through,
/// numeric strings ("1240", "12") are parsed, everything else falls back.
num asNum(dynamic value, [num fallback = 0]) {
  if (value is num) return value;
  return num.tryParse('$value') ?? fallback;
}

/// One row of a team's roster. `role` is the TEAM role (captain / vice_captain /
/// member) — distinct from the chat channel's admin/member role.
class TeamMember {
  final String id;
  final String name;
  final String role;
  final String? avatarUrl;
  final num elo;
  final num trustScore;
  final DateTime? joinedAt;
  final DateTime? lastSeenAt;

  TeamMember({
    required this.id,
    required this.name,
    required this.role,
    this.avatarUrl,
    this.elo = 0,
    this.trustScore = 0,
    this.joinedAt,
    this.lastSeenAt,
  });

  bool get isCaptain => role == 'captain';
  bool get isViceCaptain => role == 'vice_captain';
  bool get isAdmin => isCaptain || isViceCaptain;

  factory TeamMember.fromJson(Map<String, dynamic> json) => TeamMember(
        id: '${json['id'] ?? json['user_id']}',
        name: '${json['name'] ?? 'Player'}',
        role: '${json['role'] ?? 'member'}',
        avatarUrl: json['avatar_url'] as String?,
        elo: asNum(json['player_elo']),
        trustScore: asNum(json['trust_score']),
        joinedAt: _parseDate(json['joined_at']),
        lastSeenAt: _parseDate(json['last_seen_at']),
      );
}

class Team {
  final String id, name, sport, visibility;
  final String? bio, logoUrl, city;
  final num elo, wins, losses, draws;
  final String? role;
  final String? channelId;
  final String? captainId;
  final num memberCount;
  final DateTime? createdAt;
  final List<TeamMember> roster;

  /// The four tournament counters migration 019 put on the `teams` row.
  ///
  /// They are counted achievements, not a second rating: the squad plays on one
  /// ELO ladder and a tournament match simply moves it harder (a higher K). Read
  /// them as a [TeamRecord] through the `tournamentRecord` extension in
  /// models/tournament.dart, which is where the wording lives.
  final int tournamentPlayed, tournamentWins, finalsReached, titles;

  Team({
    required this.id,
    required this.name,
    required this.sport,
    required this.visibility,
    this.bio,
    this.logoUrl,
    this.city,
    this.elo = 1000,
    this.wins = 0,
    this.losses = 0,
    this.draws = 0,
    this.role,
    this.channelId,
    this.captainId,
    this.memberCount = 0,
    this.createdAt,
    this.roster = const [],
    this.tournamentPlayed = 0,
    this.tournamentWins = 0,
    this.finalsReached = 0,
    this.titles = 0,
  });

  bool get isPublic => visibility == 'public';
  bool get amCaptain => role == 'captain';
  bool get amAdmin => role == 'captain' || role == 'vice_captain';

  /// Total games with a result — used for a win-rate that reads 0% (not NaN)
  /// before a team has played.
  num get played => wins + losses + draws;
  int get winRate => played == 0 ? 0 : ((wins / played) * 100).round();

  factory Team.fromJson(Map<String, dynamic> j) => Team(
        id: '${j['id']}',
        name: '${j['name'] ?? 'Team'}',
        sport: '${j['sport'] ?? ''}',
        visibility: '${j['visibility'] ?? 'public'}',
        bio: j['bio'] as String?,
        logoUrl: j['logo_url'] as String?,
        city: j['city'] as String?,
        elo: asNum(j['elo'], 1000),
        wins: asNum(j['wins']),
        losses: asNum(j['losses']),
        draws: asNum(j['draws']),
        role: j['role'] as String?,
        // GET /mine sends `channel_id`; POST / and GET /:id send `channelId`.
        channelId: (j['channelId'] ?? j['channel_id'])?.toString(),
        captainId: j['captain_id']?.toString(),
        memberCount: asNum(j['member_count']),
        createdAt: _parseDate(j['created_at']),
        roster: (j['roster'] as List? ?? [])
            .whereType<Map>()
            .map((x) => TeamMember.fromJson(Map<String, dynamic>.from(x)))
            .toList(),
        tournamentPlayed: asNum(j['tournament_played']).round(),
        tournamentWins: asNum(j['tournament_wins']).round(),
        finalsReached: asNum(j['finals_reached']).round(),
        titles: asNum(j['titles']).round(),
      );
}

DateTime? _parseDate(dynamic v) {
  if (v == null) return null;
  return DateTime.tryParse('$v')?.toLocal();
}
