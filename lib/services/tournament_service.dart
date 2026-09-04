import '../constants/api_constants.dart';
import '../models/tournament.dart';
import 'api_service.dart';

/// Thin, never-throwing wrapper over the tournaments API (SRS Module 6).
///
/// Same split as [MatchService]: reads return typed models and fall back to an empty
/// one rather than throwing, while every mutation returns the raw
/// `{success, message, data}` map so the calling screen can surface the backend's own
/// sentence.
///
/// That split matters more here than anywhere else in the app, because this API's
/// failures are rules and not faults. "Knockout needs a power of two: 2, 4, 8, 16 or
/// 32", "the last spot went while you were deciding", "you are PKR 1,200 short",
/// "round 2 needs 4 hours and the venue has 3" are all sentences somebody has to read
/// verbatim to know what to do next; a generic "Something went wrong" would leave an
/// owner staring at a Create button with no idea why it refused.
///
/// Nothing here decides authority or money. Owner-only, captain-only, before the
/// deadline, enough balance, the whole entry-fee waterfall — all of it is enforced
/// server-side inside a locked transaction. The flags these methods surface
/// (`canRegister`, `canGenerate`) exist to avoid offering an action that would be
/// refused, never to permit one.
class TournamentService {
  final ApiClient _api = ApiClient();

  // Reads

  /// SRS FE-2 — browse open tournaments, filtered by sport, city and start date.
  ///
  /// `openOnly` defaults to true on the server, so the default call is "what can I
  /// still enter". Pass `openOnly: false` with a `status` to see finished ones.
  Future<List<Tournament>> browse(
    String token, {
    String? sport,
    String? city,
    String? startFrom,
    String? status,
    String? q,
    String? venueId,
    String? ownerId,
    bool? openOnly,
    int? limit,
  }) async {
    final r = await _api.get(
      ApiConstants.tournaments,
      token: token,
      queryParams: {
        if (sport != null && sport.isNotEmpty) 'sport': sport,
        if (city != null && city.trim().isNotEmpty) 'city': city.trim(),
        if (startFrom != null && startFrom.isNotEmpty) 'startFrom': startFrom,
        if (status != null && status.isNotEmpty) 'status': status,
        if (q != null && q.trim().isNotEmpty) 'q': q.trim(),
        if (venueId != null && venueId.isNotEmpty) 'venueId': venueId,
        if (ownerId != null && ownerId.isNotEmpty) 'ownerId': ownerId,
        if (openOnly != null) 'openOnly': '$openOnly',
        if (limit != null) 'limit': '$limit',
      },
    );
    if (r['success'] != true || r['data'] is! Map) return const [];
    final rows = (r['data'] as Map)['tournaments'];
    return (rows as List? ?? const [])
        .whereType<Map>()
        .map((x) => Tournament.fromJson(Map<String, dynamic>.from(x)))
        .toList();
  }

  /// SRS FE-8 — one tournament: overview, bracket, standings, entered teams, the
  /// money block, and (for the organiser only) the management view.
  ///
  /// Returns [TournamentDetail.empty] on any failure, so a deleted id renders as
  /// "not found" rather than a crash. Use [detailRaw] when the screen needs to print
  /// the reason.
  Future<TournamentDetail> detail(String token, String id) async {
    final r = await detailRaw(token, id);
    if (r['success'] != true || r['data'] is! Map) return TournamentDetail.empty;
    return TournamentDetail.fromJson(Map<String, dynamic>.from(r['data'] as Map));
  }

  Future<Map<String, dynamic>> detailRaw(String token, String id) =>
      _api.get(ApiConstants.tournament(id), token: token);

  /// Both roles in one call — the cups I am running and the cups my squads are in.
  Future<MyTournaments> mine(String token, {int? limit}) async {
    final r = await _api.get(
      ApiConstants.myTournaments,
      token: token,
      queryParams: {if (limit != null) 'limit': '$limit'},
    );
    if (r['success'] != true || r['data'] is! Map) return MyTournaments.empty;
    return MyTournaments.fromJson(Map<String, dynamic>.from(r['data'] as Map));
  }

  // Owner: the economics quote (SRS FE-1)

  /// `POST /tournaments/preview` — what this tournament would earn, before it exists.
  ///
  /// A POST that writes nothing. The quote depends on the whole draft configuration —
  /// format, both team counts, the four percentages, the slot length and the deadline —
  /// and a dozen fields in a query string would be worse than POSTing a read.
  ///
  /// This is the endpoint that stops an owner guessing a fee that loses them money: it
  /// prices the real slots the fixtures would take, quotes both a full field and the
  /// worst legal turnout, and recommends a fee that survives the latter.
  Future<Map<String, dynamic>> previewRaw(
    String token, {
    required String venueId,
    String? name,
    String? description,
    String? format,
    int? maxTeams,
    int? minTeams,
    num? entryFee,
    int? prizePercent,
    int? winnerPercent,
    int? runnerupPercent,
    int? venueDiscountPercent,
    int? slotMinutes,
    int? targetMarginPercent,
    int? roundGapDays,
    int? roundRestMinutes,
    String? registrationDeadline,
    String? startDate,
    bool? useModel,
  }) =>
      _api.post(
        ApiConstants.tournamentPreview,
        {
          'venueId': venueId,
          'name': ?name,
          'description': ?description,
          'format': ?format,
          'maxTeams': ?maxTeams,
          'minTeams': ?minTeams,
          'entryFee': ?entryFee,
          'prizePercent': ?prizePercent,
          'winnerPercent': ?winnerPercent,
          'runnerupPercent': ?runnerupPercent,
          'venueDiscountPercent': ?venueDiscountPercent,
          'slotMinutes': ?slotMinutes,
          'targetMarginPercent': ?targetMarginPercent,
          'roundGapDays': ?roundGapDays,
          'roundRestMinutes': ?roundRestMinutes,
          'registrationDeadline': ?registrationDeadline,
          'startDate': ?startDate,
          'useModel': ?useModel,
        },
        token: token,
      );

  /// The typed quote. Returns null on failure so the create screen can fall back to
  /// [previewRaw]'s `message` — a refused preview is usually a validation sentence the
  /// owner needs to read ("Knockout needs a power of two"), not an empty card.
  Future<TournamentPreview?> preview(
    String token, {
    required String venueId,
    String? name,
    String? format,
    int? maxTeams,
    int? minTeams,
    num? entryFee,
    int? prizePercent,
    int? winnerPercent,
    int? runnerupPercent,
    int? venueDiscountPercent,
    int? slotMinutes,
    int? targetMarginPercent,
    String? registrationDeadline,
    String? startDate,
    bool? useModel,
  }) async {
    final r = await previewRaw(
      token,
      venueId: venueId,
      name: name,
      format: format,
      maxTeams: maxTeams,
      minTeams: minTeams,
      entryFee: entryFee,
      prizePercent: prizePercent,
      winnerPercent: winnerPercent,
      runnerupPercent: runnerupPercent,
      venueDiscountPercent: venueDiscountPercent,
      slotMinutes: slotMinutes,
      targetMarginPercent: targetMarginPercent,
      registrationDeadline: registrationDeadline,
      startDate: startDate,
      useModel: useModel,
    );
    if (r['success'] != true || r['data'] is! Map) return null;
    return TournamentPreview.fromJson(Map<String, dynamic>.from(r['data'] as Map));
  }

  // Owner: create and run (FE-1, FE-5, FE-6, FE-7)

  /// `POST /tournaments` — post a tournament at one of my own venues.
  ///
  /// The venue's ownership is re-checked server-side, so a venue id belonging to
  /// somebody else is a 404 and not a tournament. Raw-wrapped because every refusal is
  /// a validation sentence the owner has to read.
  Future<Map<String, dynamic>> create(
    String token, {
    required String venueId,
    required String name,
    required num entryFee,
    required int maxTeams,
    required String registrationDeadline,
    String? description,
    String? sport,
    String? format,
    int? minTeams,
    int? prizePercent,
    int? winnerPercent,
    int? runnerupPercent,
    int? venueDiscountPercent,
    int? slotMinutes,
    String? startDate,
    bool? requiresApproval,
  }) =>
      _api.post(
        ApiConstants.tournaments,
        {
          'venueId': venueId,
          'name': name,
          'entryFee': entryFee,
          'maxTeams': maxTeams,
          'registrationDeadline': registrationDeadline,
          if (description != null && description.trim().isNotEmpty)
            'description': description.trim(),
          if (sport != null && sport.isNotEmpty) 'sport': sport,
          'format': ?format,
          'minTeams': ?minTeams,
          'prizePercent': ?prizePercent,
          'winnerPercent': ?winnerPercent,
          'runnerupPercent': ?runnerupPercent,
          'venueDiscountPercent': ?venueDiscountPercent,
          'slotMinutes': ?slotMinutes,
          if (startDate != null && startDate.isNotEmpty) 'startDate': startDate,
          'requiresApproval': ?requiresApproval,
        },
        token: token,
      );

  /// SRS FE-5 — approve · reject · remove one entered team.
  ///
  /// `decision` is `'approve'`, `'reject'` or `'remove'`. A reject or a remove refunds
  /// the held fee in the same transaction, so this is a money endpoint even though it
  /// looks like a list edit — which is why the caller must show the response sentence.
  Future<Map<String, dynamic>> decide(
    String token,
    String tournamentId,
    String teamId, {
    required String decision,
    String? reason,
  }) =>
      _api.patch(
        ApiConstants.tournamentTeam(tournamentId, teamId),
        {
          'decision': decision,
          if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
        },
        token: token,
      );

  /// SRS FE-6 — draw the bracket now, rather than waiting for the deadline job.
  ///
  /// `useModel: false` forces the chronological path. That flag is how the demo proves
  /// the scheduler's provenance stamp means something: the same tournament, generated
  /// both ways, reports `meta.scheduling.source` as `'model'` and `'chronological'`.
  ///
  /// This is the biggest money move in the module — every held fee is released, the
  /// venue cost and margin go to the owner, and the prize is frozen — so it is behind
  /// a confirmation in the UI and the response is shown verbatim.
  Future<Map<String, dynamic>> generate(
    String token,
    String tournamentId, {
    bool useModel = true,
  }) =>
      _api.post(
        ApiConstants.tournamentGenerate(tournamentId),
        {'useModel': useModel},
        token: token,
      );

  /// SRS FE-7 — the organiser types the score straight onto a fixture.
  ///
  /// The second of the two doors into one settle function: the other is a captain
  /// submitting through the normal match flow and the owner verifying it. Both run the
  /// same ELO application and the same bracket advance, and both are idempotent.
  Future<Map<String, dynamic>> enterResult(
    String token,
    String tournamentId,
    String fixtureId, {
    required int scoreA,
    required int scoreB,
  }) =>
      _api.patch(
        ApiConstants.tournamentFixtureResult(tournamentId, fixtureId),
        {'scoreA': scoreA, 'scoreB': scoreB},
        token: token,
      );

  /// A team did not turn up. Deliberately not a 3-0: a walkover means no game was
  /// played, so the fixture's K-factor is 0 and nobody's rating moves. Recording it as
  /// a scoreline would hand the other side free rating points for a match that never
  /// happened.
  Future<Map<String, dynamic>> walkover(
    String token,
    String tournamentId,
    String fixtureId, {
    required String winnerTeamId,
    String? reason,
  }) =>
      _api.post(
        ApiConstants.tournamentFixtureWalkover(tournamentId, fixtureId),
        {
          'winnerTeamId': winnerTeamId,
          if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
        },
        token: token,
      );

  /// Call it off and refund every held entry fee.
  Future<Map<String, dynamic>> cancel(
    String token,
    String tournamentId, {
    String? reason,
  }) =>
      _api.post(
        ApiConstants.tournamentCancel(tournamentId),
        {if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim()},
        token: token,
      );

  // Captain: entry and withdrawal (SRS FE-3)

  /// `POST /tournaments/:id/register` — enter a team and freeze the entry fee.
  ///
  /// The team comes from the body but the authority does not: the service reads
  /// `teams.captain_id` inside the locked transaction, so sending somebody else's team
  /// id is a 403 and not an entry. The fee moves `balance -> frozen`, which is why the
  /// UI puts a confirmation in front of this and prints the response verbatim — "you
  /// are PKR 1,200 short" and "the last spot went" are both answers a captain needs to
  /// read, not swallow.
  Future<Map<String, dynamic>> register(
    String token,
    String tournamentId, {
    required String teamId,
  }) =>
      _api.post(
        ApiConstants.tournamentRegister(tournamentId),
        {'teamId': teamId},
        token: token,
      );

  /// Pull out before the deadline for a full refund. After the bracket is drawn there
  /// is nothing to refund — the fee has already paid for the venue's hours — and the
  /// server refuses with that sentence.
  Future<Map<String, dynamic>> withdraw(
    String token,
    String tournamentId, {
    required String teamId,
  }) =>
      _api.delete(
        ApiConstants.tournamentRegister(tournamentId),
        body: {'teamId': teamId},
        token: token,
      );
}
