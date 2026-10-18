import '../constants/api_constants.dart';
import '../models/open_challenge.dart';
import 'api_service.dart';

/// Client for the Live Challenge Feed (item 9). Reads return typed cards; writes
/// return the raw `{success, message, data}` map so the screen can surface the
/// backend's own sentence (e.g. "Another team just claimed this slot.").
class OpenChallengeService {
  final ApiClient _api = ApiClient();

  /// The public board.
  ///
  /// Returns the whole envelope rather than a bare list, because a caller has three
  /// states to tell apart and a list cannot express them: loaded (a list, possibly
  /// empty), unavailable (503 — migration 041 not applied), and failed (any other
  /// refusal, carrying the server's own sentence). Collapsing a refusal into `null`
  /// is what made every failure read as "check your connection", including the ones
  /// that had nothing to do with the network.
  Future<({bool ok, int status, String? message, List<OpenChallenge> cards})> board(
    String token, {
    String? sport,
  }) async {
    final r = await _api.get(
      ApiConstants.openChallenges,
      token: token,
      queryParams: (sport != null && sport.isNotEmpty) ? {'sport': sport} : null,
    );
    final status = (r['statusCode'] as num?)?.toInt() ?? 0;
    if (r['success'] != true) {
      return (
        ok: false,
        status: status,
        message: r['message']?.toString(),
        cards: const <OpenChallenge>[],
      );
    }
    final data = r['data'];
    final list = (data is Map ? data['challenges'] : null) as List? ?? const [];
    return (
      ok: true,
      status: status,
      message: null,
      cards: list
          .whereType<Map>()
          .map((e) => OpenChallenge.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
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
