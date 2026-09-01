import '../constants/api_constants.dart';
import '../models/reco.dart';
import '../models/team.dart';
import '../models/team_stats.dart';
import 'api_service.dart';

/// Thin, never-throwing wrapper over the teams API. Reads that feed a list return
/// typed models; mutations return the raw `{success, message, data}` map so the
/// calling screen can surface the backend's own sentence on failure.
class TeamService {
  final ApiClient _api = ApiClient();

  List<Team> _teams(Map<String, dynamic> r) => r['success'] == true
      ? (r['data'] as List? ?? [])
          .whereType<Map>()
          .map((x) => Team.fromJson(Map<String, dynamic>.from(x)))
          .toList()
      : <Team>[];

  // Reads
  Future<List<Team>> mine(String token) async =>
      _teams(await _api.get(ApiConstants.myTeams, token: token));

  /// The leaderboard (FR5.13).
  ///
  /// Wave D changed this endpoint's shape from a bare array to an object, because
  /// the city chips have to come from the same query as the rows — a second call
  /// would let the two disagree, and chips that lead to empty screens read as a
  /// broken feature. So this returns [RankingsPage], not `List<Team>`.
  ///
  /// **null means the request failed**, and an empty [RankingsPage] means the
  /// board is genuinely empty. Those need different sentences on screen: "could
  /// not load" invites a retry, "no ranked teams yet" invites a challenge. An
  /// empty page for both would show the wrong one every time the server is down.
  Future<RankingsPage?> rankings(String token, {String? sport, String? city}) async {
    final params = <String, String>{};
    if (sport != null && sport.isNotEmpty) params['sport'] = sport;
    if (city != null && city.trim().isNotEmpty) params['city'] = city.trim();
    final r = await _api.get(ApiConstants.teamRankings, token: token, queryParams: params);
    if (r['success'] != true) return null;
    final data = r['data'];
    return RankingsPage.fromJson(data is Map ? Map<String, dynamic>.from(data) : const {});
  }

  Future<List<Team>> discover(String token, {String? q, String? sport}) async {
    final params = <String, String>{};
    if (q != null && q.trim().isNotEmpty) params['q'] = q.trim();
    if (sport != null && sport.isNotEmpty) params['sport'] = sport;
    return _teams(await _api.get(ApiConstants.teamDiscover, token: token, queryParams: params));
  }

  /// Full profile: `{...team, role, channelId, roster, stats, eloHistory}`.
  /// Returned raw so the screen can distinguish a 403 (private, not a member)
  /// from a network error, and so Wave D's `stats`/`eloHistory` blocks can be
  /// parsed by their own models rather than squeezed into [Team].
  Future<Map<String, dynamic>> detail(String token, String id) =>
      _api.get(ApiConstants.team(id), token: token);

  /// Suggested players for a team's roster (FR2.8) — admin-only on the server.
  ///
  /// **null means the request failed** (offer a retry); an empty [SuggestedPlayers]
  /// means the pool was genuinely empty (nobody near this team to suggest yet).
  /// The rail shows a different sentence for each, so the two must stay apart —
  /// the same reasoning as [rankings] above.
  Future<SuggestedPlayers?> suggestedPlayers(String token, String id) async {
    final r = await _api.get(ApiConstants.teamSuggestedPlayers(id), token: token);
    if (r['success'] != true) return null;
    final data = r['data'];
    return SuggestedPlayers.fromJson(data is Map ? Map<String, dynamic>.from(data) : const {});
  }

  // Create / edit
  Future<Map<String, dynamic>> create(
    String token, {
    required String name,
    required String sport,
    required bool isPublic,
    String? bio,
    String? logo,
  }) =>
      _api.post(ApiConstants.teams, {
        'name': name,
        'sport': sport,
        'visibility': isPublic ? 'public' : 'private',
        'bio': ?bio,
        'logo': ?logo,
      }, token: token);

  Future<Map<String, dynamic>> update(
    String token,
    String id, {
    String? bio,
    bool? isPublic,
    String? city,
    String? logo,
  }) =>
      _api.patch(ApiConstants.team(id), {
        'bio': ?bio,
        if (isPublic != null) 'visibility': isPublic ? 'public' : 'private',
        'city': ?city,
        'logo': ?logo,
      }, token: token);

  // Invites
  /// Mint a fresh 48h invite link. The raw token is returned exactly once.
  ///
  /// [note] rides along on the server's `req.body.note` — the roster rail names
  /// the player the link was minted for, so the invite list reads as "for Ayaan"
  /// rather than an anonymous link. There is no per-user invite in the schema;
  /// this is still a single-use link the captain sends themselves.
  Future<Map<String, dynamic>> invite(String token, String id, {String? note}) =>
      _api.post(ApiConstants.teamInvites(id), {
        'note': ?note,
      }, token: token);

  Future<Map<String, dynamic>> invitesList(String token, String id) =>
      _api.get(ApiConstants.teamInvites(id), token: token);

  Future<Map<String, dynamic>> revokeInvite(String token, String id, String inviteId) =>
      _api.delete(ApiConstants.teamInvite(id, inviteId), token: token);

  /// Public peek at where a link leads, before committing to join.
  Future<Map<String, dynamic>> previewInvite(String token, String inviteToken) =>
      _api.get(ApiConstants.teamInvitePreview(inviteToken), token: token);

  Future<Map<String, dynamic>> joinByToken(String token, String inviteToken) =>
      _api.post(ApiConstants.teamJoin(inviteToken), {}, token: token);

  // Join requests (public teams)
  Future<Map<String, dynamic>> joinRequest(String token, String id, {String? message}) =>
      _api.post(ApiConstants.teamJoinRequest(id), {
        if (message != null && message.isNotEmpty) 'message': message,
      }, token: token);

  Future<Map<String, dynamic>> requests(String token, String id) =>
      _api.get(ApiConstants.teamRequests(id), token: token);

  Future<Map<String, dynamic>> decideRequest(
          String token, String id, String requestId, String action) =>
      _api.patch(ApiConstants.teamRequest(id, requestId), {'action': action}, token: token);

  // Membership
  /// action ∈ {remove, captain, vice_captain, member}
  Future<Map<String, dynamic>> memberAction(
          String token, String teamId, String userId, String action) =>
      _api.patch(ApiConstants.teamMember(teamId, userId), {'action': action}, token: token);

  Future<Map<String, dynamic>> leave(String token, String id) =>
      _api.delete(ApiConstants.leaveTeam(id), token: token);
}
