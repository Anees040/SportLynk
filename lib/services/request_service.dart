import '../constants/api_constants.dart';
import '../models/play_request.dart';
import 'api_service.dart';

/// REST calls for matchmaking (module 8c) — the honest "find players, ask them to
/// play, manage the asks" surface. A thin wrapper over [ApiClient]: it maps the
/// `{success, data}` envelope into models and never throws. The read methods return
/// `null` when the call did not land (a cold network, a server error) and a list —
/// possibly empty — when it did, so a screen can tell "nobody to show" apart from
/// "could not load" and render a retry for the second rather than a false "none".
/// The one side effect worth naming — an accepted request opening a 1:1 chat —
/// happens server-side; [respond] returns the channel id so the caller can jump in.
class RequestService {
  final ApiClient _api = ApiClient();

  /// Players the signed-in user could ask to play. [sport] softly ranks matches to
  /// the top rather than filtering; the list is honest real accounts either way.
  /// Null means the request did not land, distinct from an empty list of players.
  Future<List<DiscoverPlayer>?> discover(String token, {String? sport, int limit = 40}) async {
    final params = <String, String>{'limit': '$limit'};
    if (sport != null && sport.trim().isNotEmpty) params['sport'] = sport.trim();
    final r = await _api.get(ApiConstants.requestsDiscover, token: token, queryParams: params);
    if (r['success'] != true) return null;
    return (r['data'] as List? ?? [])
        .whereType<Map>()
        .map((m) => DiscoverPlayer.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// Requests addressed to me. [status] filters to one lifecycle state; omit for all.
  /// Null means the request did not land, distinct from an empty inbox.
  Future<List<PlayRequest>?> incoming(String token, {String? status}) =>
      _list(ApiConstants.requestsIncoming, token, status);

  /// Requests I have sent — where a decline shows up, since declines are silent.
  /// Null means the request did not land, distinct from an empty list.
  Future<List<PlayRequest>?> outgoing(String token, {String? status}) =>
      _list(ApiConstants.requestsOutgoing, token, status);

  Future<List<PlayRequest>?> _list(String path, String token, String? status) async {
    final params = <String, String>{};
    if (status != null && status.isNotEmpty) params['status'] = status;
    final r = await _api.get(path, token: token, queryParams: params);
    if (r['success'] != true) return null;
    return (r['data'] as List? ?? [])
        .whereType<Map>()
        .map((m) => PlayRequest.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// Ask a player to play. Returns the raw envelope so the caller can surface the
  /// server's own message on the expected failures (409 duplicate, 404 gone).
  Future<Map<String, dynamic>> create(
    String token, {
    required String targetUserId,
    String? sport,
    String? message,
  }) =>
      _api.post(ApiConstants.requests, {
        'targetUserId': targetUserId,
        'sport': ?sport,
        'message': ?message,
      }, token: token);

  /// Accept or decline a request addressed to me. On accept the server opens the
  /// 1:1 room and the envelope's `data.channelId` is where to land.
  Future<Map<String, dynamic>> respond(String token, String id, {required bool accept}) =>
      _api.post(ApiConstants.requestRespond(id), {
        'action': accept ? 'accept' : 'decline',
      }, token: token);

  /// Withdraw one of my own pending requests.
  Future<Map<String, dynamic>> cancel(String token, String id) =>
      _api.post(ApiConstants.requestCancel(id), const {}, token: token);
}
