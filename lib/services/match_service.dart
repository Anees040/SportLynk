import '../constants/api_constants.dart';
import '../models/match.dart';
import 'api_service.dart';

/// Thin, never-throwing wrapper over the matches API.
///
/// Same split as [TeamService]: reads that feed a list return typed models, and
/// mutations return the raw `{success, message, data}` map so the calling screen
/// can surface the backend's own sentence. That matters more here than anywhere
/// else in the app — this API's failures are *rules*, not faults. "That slot
/// already has a match on it", "the slot has not started yet", "results are
/// locked" are all sentences a captain needs to read verbatim, and a generic
/// "Something went wrong" would leave them with no idea what to do next.
///
/// Nothing here decides authority. Every gate — captain-only, owner-only, inside
/// the dispute window, slot has started — is enforced server-side inside a locked
/// transaction. The flags these methods return (`canChallenge`, `slotStarted`)
/// exist to avoid *offering* an action that would be refused, not to permit one.
class MatchService {
  final ApiClient _api = ApiClient();

  // Reads

  /// FR5.3 – FR5.5. Candidate opponents for [teamId], closest rating first, each
  /// with its competitiveness score and trust badge.
  ///
  /// Returns [OpponentList.empty] rather than throwing, so a 403 (not the caller's team)
  /// renders as an empty list with `canChallenge: false` instead of a crash.
  Future<OpponentList> opponents(String token, String teamId, {String? q}) async {
    final r = await _api.get(
      ApiConstants.matchOpponents,
      token: token,
      queryParams: {
        'teamId': teamId,
        if (q != null && q.trim().isNotEmpty) 'q': q.trim(),
      },
    );
    if (r['success'] != true || r['data'] is! Map) return OpponentList.empty;
    return OpponentList.fromJson(Map<String, dynamic>.from(r['data'] as Map));
  }

  /// FR5.10 — the head-to-head, competitiveness and generated preview sentence
  /// for a pairing that does not exist yet. Returned raw-wrapped so the challenge
  /// screen can show *why* a pairing was refused (different sports, private team)
  /// instead of an empty card.
  Future<Map<String, dynamic>> previewRaw(
    String token, {
    required String challengerTeam,
    required String opponentTeam,
  }) =>
      _api.get(
        ApiConstants.matchPreview,
        token: token,
        queryParams: {'challengerTeam': challengerTeam, 'opponentTeam': opponentTeam},
      );

  Future<MatchPreview?> preview(
    String token, {
    required String challengerTeam,
    required String opponentTeam,
  }) async {
    final r = await previewRaw(
      token,
      challengerTeam: challengerTeam,
      opponentTeam: opponentTeam,
    );
    if (r['success'] != true || r['data'] is! Map) return null;
    return MatchPreview.fromJson(Map<String, dynamic>.from(r['data'] as Map));
  }

  /// FR5.11 — my confirmed, future bookings that no live match is already using.
  /// A challenge must be pinned to one of these; there is no "pick a venue and
  /// hope" path, because the pitch has to be booked.
  Future<List<LinkableBooking>> linkableBookings(String token, String teamId) async {
    final r = await _api.get(
      ApiConstants.matchLinkableBookings,
      token: token,
      queryParams: {'teamId': teamId},
    );
    if (r['success'] != true) return const [];
    return (r['data'] as List? ?? const [])
        .whereType<Map>()
        .map((x) => LinkableBooking.fromJson(Map<String, dynamic>.from(x)))
        .toList();
  }

  /// FR5.16 — the Match Center, already bucketed into challenges / upcoming /
  /// history by the server.
  Future<MatchCenterData> center(String token, String teamId) async {
    final r = await _api.get(
      ApiConstants.matches,
      token: token,
      queryParams: {'team_id': teamId},
    );
    if (r['success'] != true || r['data'] is! Map) return MatchCenterData.empty;
    return MatchCenterData.fromJson(Map<String, dynamic>.from(r['data'] as Map));
  }

  /// One match in full. Submissions are attached only when the viewer is allowed
  /// to see them — the venue owner always, a team only once both are in.
  Future<MatchModel?> detail(String token, String id) async {
    final r = await _api.get(ApiConstants.match(id), token: token);
    if (r['success'] != true || r['data'] is! Map) return null;
    return MatchModel.fromJson(Map<String, dynamic>.from(r['data'] as Map));
  }

  /// ER2.2 — the owner's verification queue: `awaiting_owner` matches on venues
  /// this account owns, each with both captains' submissions.
  Future<List<MatchModel>> ownerPending(String token) async {
    final r = await _api.get(ApiConstants.matchOwnerPending, token: token);
    if (r['success'] != true) return const [];
    return (r['data'] as List? ?? const [])
        .whereType<Map>()
        .map((x) => MatchModel.fromJson(Map<String, dynamic>.from(x)))
        .toList();
  }

  // Mutations

  /// FR5.8 – FR5.12. The server re-reads captaincy, sport, booking ownership and
  /// slot availability inside its transaction, so a stale screen produces a
  /// readable 4xx rather than a bad match.
  Future<Map<String, dynamic>> challenge(
    String token, {
    required String challengerTeam,
    required String opponentTeam,
    required String bookingId,
  }) =>
      _api.post(ApiConstants.matchChallenge, {
        'challengerTeam': challengerTeam,
        'opponentTeam': opponentTeam,
        'bookingId': bookingId,
      }, token: token);

  /// FE-4 — the opponent captain accepts or rejects. `action` ∈ {accept, reject}.
  Future<Map<String, dynamic>> respond(String token, String id, String action) =>
      _api.patch(ApiConstants.matchRespond(id), {'action': action}, token: token);

  /// ER2.1 — a captain's one and only submission for this match.
  ///
  /// Scores are always challenger-first, absolute, regardless of which side the
  /// caller is on; the dialog relabels them for the viewer but sends them in the
  /// match's own order so both submissions are directly comparable. `winnerTeam`
  /// is sent as a confirmation of what the scores already say — the server
  /// derives the winner itself and rejects a disagreement.
  Future<Map<String, dynamic>> submitResult(
    String token,
    String id, {
    required int scoreChallenger,
    required int scoreOpponent,
    String? winnerTeam,
  }) =>
      _api.post(ApiConstants.matchResult(id), {
        'scoreChallenger': scoreChallenger,
        'scoreOpponent': scoreOpponent,
        'winnerTeam': ?winnerTeam,
      }, token: token);

  /// ER2.2 — the venue owner confirms what happened on their pitch, which is what
  /// runs the ELO exchange. There is no score parameter: the owner verifies the
  /// two captains' agreed result or leaves it alone, they do not overrule it.
  Future<Map<String, dynamic>> verify(String token, String id) =>
      _api.patch(ApiConstants.matchVerify(id), const {}, token: token);

  /// FR5.17 — flag a result inside the 24h window. The reason is required and has
  /// a minimum length: an admin has to be able to act on it.
  Future<Map<String, dynamic>> dispute(String token, String id, String reason) =>
      _api.post(ApiConstants.matchDispute(id), {'reason': reason}, token: token);
}
