/// play_request.dart — the two shapes behind matchmaking (module 8c).
///
/// [PlayRequest] is one row of the request inbox, incoming or outgoing; the server
/// resolves the OTHER party into `other*` so the same card renders on both tabs
/// without the client knowing which side it is on. [DiscoverPlayer] is one row of
/// the "find players" list — every field a real account column, never a default
/// invented when a value is missing (an unfilled profile shows no sports and no
/// trust, not a fabricated 100).
///
/// Numbers go through [asNum] for the same reason every other model does: Postgres
/// hands `numeric` back as a string and a raw `as num` on "42" throws.
library;

import 'team.dart' show asNum;

/// The lifecycle of a request. `pending` is the only state that can be acted on;
/// the rest are terminal and drive whether a row shows buttons or just an outcome.
enum PlayRequestStatus {
  pending,
  accepted,
  declined,
  cancelled,
  expired,
  unknown;

  static PlayRequestStatus parse(String? raw) => switch (raw) {
        'pending' => PlayRequestStatus.pending,
        'accepted' => PlayRequestStatus.accepted,
        'declined' => PlayRequestStatus.declined,
        'cancelled' => PlayRequestStatus.cancelled,
        'expired' => PlayRequestStatus.expired,
        _ => PlayRequestStatus.unknown,
      };

  bool get isPending => this == PlayRequestStatus.pending;

  /// The word shown on a decided row. `pending` has none — that row shows actions.
  String get label => switch (this) {
        PlayRequestStatus.pending => 'Pending',
        PlayRequestStatus.accepted => 'Accepted',
        PlayRequestStatus.declined => 'Declined',
        PlayRequestStatus.cancelled => 'Cancelled',
        PlayRequestStatus.expired => 'Expired',
        PlayRequestStatus.unknown => '',
      };
}

/// One request in the inbox.
class PlayRequest {
  final String id;
  final String? sport;
  final String? message;
  final PlayRequestStatus status;

  /// The 1:1 room an accepted request opened. Null until accepted; on an incoming
  /// accepted row it is the channel to open, on an outgoing one it is where the
  /// requester lands when the acceptance notification is tapped.
  final String? channelId;

  final DateTime? createdAt;
  final DateTime? decidedAt;
  final DateTime? expiresAt;

  /// The other party as this side sees them: the requester on an incoming row, the
  /// target on an outgoing one.
  final String? otherUserId;
  final String? otherName;
  final String? otherAvatar;
  final num? trustScore;

  const PlayRequest({
    required this.id,
    required this.status,
    this.sport,
    this.message,
    this.channelId,
    this.createdAt,
    this.decidedAt,
    this.expiresAt,
    this.otherUserId,
    this.otherName,
    this.otherAvatar,
    this.trustScore,
  });

  bool get isPending => status.isPending;
  String get displayName => (otherName == null || otherName!.trim().isEmpty) ? 'A player' : otherName!;

  factory PlayRequest.fromJson(Map<String, dynamic> j) => PlayRequest(
        id: '${j['id']}',
        status: PlayRequestStatus.parse(j['status'] as String?),
        sport: j['sport'] as String?,
        message: j['message'] as String?,
        channelId: j['channelId'] == null ? null : '${j['channelId']}',
        createdAt: _date(j['createdAt']),
        decidedAt: _date(j['decidedAt']),
        expiresAt: _date(j['expiresAt']),
        otherUserId: j['otherUserId'] == null ? null : '${j['otherUserId']}',
        otherName: j['otherName'] as String?,
        otherAvatar: j['otherAvatar'] as String?,
        trustScore: j['trustScore'] == null ? null : asNum(j['trustScore']),
      );
}

/// One candidate on the "find players" list.
class DiscoverPlayer {
  final String userId;
  final String name;
  final String? avatarUrl;
  final List<String> sports;
  final num? trustScore;
  final int bookings30d;
  final bool playsSport;

  /// True when this user already has a pending request from the viewer, so the row
  /// shows "Requested" (disabled) rather than letting a duplicate ask hit the 409.
  final bool pendingRequest;

  const DiscoverPlayer({
    required this.userId,
    required this.name,
    this.avatarUrl,
    this.sports = const [],
    this.trustScore,
    this.bookings30d = 0,
    this.playsSport = false,
    this.pendingRequest = false,
  });

  factory DiscoverPlayer.fromJson(Map<String, dynamic> j) => DiscoverPlayer(
        userId: '${j['userId']}',
        name: '${j['name'] ?? 'Player'}',
        avatarUrl: j['avatarUrl'] as String?,
        sports: (j['sports'] as List? ?? []).map((s) => '$s').toList(),
        trustScore: j['trustScore'] == null ? null : asNum(j['trustScore']),
        bookings30d: asNum(j['bookings30d']).toInt(),
        playsSport: j['playsSport'] == true,
        pendingRequest: j['pendingRequest'] == true,
      );
}

DateTime? _date(dynamic v) {
  if (v == null) return null;
  return DateTime.tryParse('$v')?.toLocal();
}
