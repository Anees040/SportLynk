/// public_profile.dart — another player's profile as the viewer is allowed to see it.
///
/// The server decides visibility, so this model trusts the payload's `isPublic` flag
/// rather than re-deriving it: a private profile simply arrives with its detail fields
/// absent, and [isDetailVisible] is what the screen branches on. Nothing is invented
/// when a value is missing — a null trust stays null (rendered "not rated yet"), an
/// absent sports list is empty, and a private profile exposes no teams at all.
///
/// Numbers go through [asNum] like every other model, because Postgres hands `numeric`
/// back as a string.
library;

import 'team.dart' show asNum;

/// One team the player belongs to, with that team's record — the honest answer to
/// "who do they play with", shown only on a public profile.
class ProfileTeam {
  final String id;
  final String name;
  final String sport;
  final String? logoUrl;
  final String? role;
  final int? elo;
  final int wins;
  final int losses;
  final int draws;

  const ProfileTeam({
    required this.id,
    required this.name,
    required this.sport,
    this.logoUrl,
    this.role,
    this.elo,
    this.wins = 0,
    this.losses = 0,
    this.draws = 0,
  });

  int get played => wins + losses + draws;
  String get record => played == 0 ? 'No matches yet' : '${wins}W · ${losses}L · ${draws}D';

  factory ProfileTeam.fromJson(Map<String, dynamic> j) => ProfileTeam(
        id: '${j['id']}',
        name: '${j['name'] ?? 'Team'}',
        sport: '${j['sport'] ?? ''}',
        logoUrl: j['logoUrl'] as String?,
        role: j['role'] as String?,
        elo: j['elo'] == null ? null : asNum(j['elo']).round(),
        wins: asNum(j['wins']).toInt(),
        losses: asNum(j['losses']).toInt(),
        draws: asNum(j['draws']).toInt(),
      );
}

/// A player's public-facing profile.
class PublicProfile {
  // The header, present whether the profile is public or private.
  final String id;
  final String name;
  final String? avatarUrl;
  final bool isPublic;
  final bool isSelf;
  final num? trustScore;
  final int eloRating;
  final DateTime? memberSince;

  // The detail, present only when the profile is public or the viewer is its owner.
  // Null/empty here means "withheld" — the screen checks [isDetailVisible] first.
  final String? bio;
  final List<String> sports;
  final int? bookings30d;
  final List<ProfileTeam> teams;

  const PublicProfile({
    required this.id,
    required this.name,
    required this.isPublic,
    required this.isSelf,
    required this.eloRating,
    this.avatarUrl,
    this.trustScore,
    this.memberSince,
    this.bio,
    this.sports = const [],
    this.bookings30d,
    this.teams = const [],
  });

  /// True when the full detail is shown — a public profile, or the owner's own.
  bool get isDetailVisible => isPublic || isSelf;

  factory PublicProfile.fromJson(Map<String, dynamic> j) => PublicProfile(
        id: '${j['id']}',
        name: '${j['name'] ?? 'Player'}',
        avatarUrl: j['avatarUrl'] as String?,
        isPublic: j['isPublic'] == true,
        isSelf: j['isSelf'] == true,
        trustScore: j['trustScore'] == null ? null : asNum(j['trustScore']),
        eloRating: j['eloRating'] == null ? 1000 : asNum(j['eloRating']).round(),
        memberSince: _date(j['memberSince']),
        bio: j['bio'] as String?,
        sports: (j['sports'] as List? ?? const []).map((s) => '$s').toList(),
        bookings30d: j['bookings30d'] == null ? null : asNum(j['bookings30d']).toInt(),
        teams: (j['teams'] as List? ?? const [])
            .whereType<Map>()
            .map((m) => ProfileTeam.fromJson(Map<String, dynamic>.from(m)))
            .toList(),
      );
}

DateTime? _date(dynamic v) {
  if (v == null) return null;
  return DateTime.tryParse('$v')?.toLocal();
}
