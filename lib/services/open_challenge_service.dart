import '../constants/api_constants.dart';
import '../models/open_challenge.dart';
import 'api_service.dart';

/// Client for the Live Challenge Feed (item 9). Reads return typed cards; writes
/// return the raw `{success, message, data}` map so the screen can surface the
/// backend's own sentence (e.g. "Another team just claimed this slot.").
class OpenChallengeService {
  final ApiClient _api = ApiClient();

  /// The public board. **null means the request failed** (so the screen can show an
  /// error with retry); an empty list means the board is genuinely empty — the two
  /// need different states, the same distinction TeamService.rankings draws.
  Future<List<OpenChallenge>?> board(String token, {String? sport}) async {
    final r = await _api.get(
      ApiConstants.openChallenges,
      token: token,
      queryParams: (sport != null && sport.isNotEmpty) ? {'sport': sport} : null,
    );
    if (r['success'] != true) return null;
    final data = r['data'];
    final list = (data is Map ? data['challenges'] : null) as List? ?? const [];
    return list
        .whereType<Map>()
        .map((e) => OpenChallenge.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// Post one of the caller's confirmed bookings to the board on behalf of [teamId].
  Future<Map<String, dynamic>> post(
    String token, {
    required String teamId,
    required String bookingId,
  }) =>
      _api.post(
        ApiConstants.openChallenges,
        {'teamId': teamId, 'bookingId': bookingId},
        token: token,
      );

  /// Claim an open card for [teamId] — locks the match and opens the prep room.
  Future<Map<String, dynamic>> claim(
    String token, {
    required String openId,
    required String teamId,
  }) =>
      _api.post(
        ApiConstants.openChallengeClaim(openId),
        {'teamId': teamId},
        token: token,
      );

  /// Withdraw an open card the caller's team posted.
  Future<Map<String, dynamic>> cancel(String token, String openId) =>
      _api.delete(ApiConstants.openChallenge(openId), token: token);
}
