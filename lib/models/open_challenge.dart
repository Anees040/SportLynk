/// A card on the Live Challenge Feed (item 9): a confirmed booking a captain has
/// offered to any opponent. Parsed from `GET /api/open-challenges`.
///
/// pg sends BIGINT/NUMERIC columns as strings, so every number is read through
/// [_num] rather than a raw cast — the same rule the teams layer follows.
library;

num _num(dynamic v, [num fallback = 0]) {
  if (v is num) return v;
  return num.tryParse('$v') ?? fallback;
}

DateTime? _date(dynamic v) {
  if (v == null) return null;
  return DateTime.tryParse('$v')?.toLocal();
}

/// The posting team as the board shows it — enough to judge a pairing without a
/// second request. No invented rating: unranked teams simply read as their record.
class OpenChallengeTeam {
  final String id;
  final String name;
  final String? logoUrl;
  final String? city;
  final int elo;
  final int wins;
  final int losses;
  final int draws;

  const OpenChallengeTeam({
    required this.id,
    required this.name,
    this.logoUrl,
    this.city,
    this.elo = 1000,
    this.wins = 0,
    this.losses = 0,
    this.draws = 0,
  });

  int get played => wins + losses + draws;
  String get record => 'W$wins · L$losses · D$draws';

  factory OpenChallengeTeam.fromJson(Map<String, dynamic> j) => OpenChallengeTeam(
        id: '${j['id']}',
        name: '${j['name'] ?? 'Team'}',
        logoUrl: j['logoUrl'] as String?,
        city: j['city'] as String?,
        elo: _num(j['elo'], 1000).round(),
        wins: _num(j['wins']).round(),
        losses: _num(j['losses']).round(),
        draws: _num(j['draws']).round(),
      );
}

/// Where and when the match would be played — the poster's confirmed booking.
class OpenChallengeBooking {
  final String id;
  final String? slotDate;
  final String? startTime;
  final String? endTime;
  final String? venueName;
  final String? venueCity;

  const OpenChallengeBooking({
    required this.id,
    this.slotDate,
    this.startTime,
    this.endTime,
    this.venueName,
    this.venueCity,
  });

  factory OpenChallengeBooking.fromJson(Map<String, dynamic> j) => OpenChallengeBooking(
        id: '${j['id']}',
        slotDate: j['slotDate']?.toString(),
        startTime: j['startTime']?.toString(),
        endTime: j['endTime']?.toString(),
        venueName: j['venueName']?.toString(),
        venueCity: j['venueCity']?.toString(),
      );
}

class OpenChallenge {
  final String id;
  final String sport;
  final DateTime? expiresAt;
  final DateTime? createdAt;

  /// True when one of the viewer's own teams posted this card — the board hides the
  /// Accept button for it (a team cannot play itself) and offers Withdraw instead.
  final bool mine;

  final OpenChallengeTeam team;
  final OpenChallengeBooking booking;

  const OpenChallenge({
    required this.id,
    required this.sport,
    required this.team,
    required this.booking,
    this.expiresAt,
    this.createdAt,
    this.mine = false,
  });

  factory OpenChallenge.fromJson(Map<String, dynamic> j) => OpenChallenge(
        id: '${j['id']}',
        sport: '${j['sport'] ?? ''}',
        expiresAt: _date(j['expiresAt']),
        createdAt: _date(j['createdAt']),
        mine: j['mine'] == true,
        team: OpenChallengeTeam.fromJson(
            Map<String, dynamic>.from(j['team'] as Map? ?? const {})),
        booking: OpenChallengeBooking.fromJson(
            Map<String, dynamic>.from(j['booking'] as Map? ?? const {})),
      );
}
