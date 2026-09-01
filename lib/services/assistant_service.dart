import 'dart:math';

import '../constants/api_constants.dart';
import '../models/assistant.dart';
import 'api_service.dart';

/// Every call Scout's chat screen makes, and nothing else.
///
/// One endpoint for two input modes
/// [send] is used for both a typed sentence and a tapped chip, because the
/// backend deliberately has one `POST /message`. Passing [action] makes the turn a
/// chip press — the server skips the classifier entirely and executes the action —
/// while passing only [text] runs the intent model. The screen therefore has no
/// branch for "is this a button or a sentence"; the body shape says it.
///
/// Why [clientId] is not optional
/// A booking turn moves money. On a flaky connection the app cannot tell "the
/// request never arrived" from "the reply never came back", and a retry of the
/// second case would book twice. `client_id` makes the write idempotent: the
/// server recognises the repeat and returns the original turn. Callers must reuse
/// the same id when retrying, which is why generating it is [newClientId]'s job
/// and not this method's.
///
/// Like every other service here, nothing throws. [ApiClient] turns a socket
/// failure into `{success: false, message}`, and a failed turn still yields a
/// [ScoutTurn] with a renderable reply, so a dropped connection draws a bubble
/// rather than an exception.
class AssistantService {
  final ApiClient _api = ApiClient();

  static final Random _rng = Random();

  /// A per-message idempotency key. Held by the caller across retries.
  static String newClientId() {
    final n = _rng.nextInt(1 << 32).toRadixString(36);
    return '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}$n';
  }

  /// One turn. Give [text] for a typed message, or [action] (+[args]) for a chip.
  Future<ScoutTurn> send(
    String token, {
    String? text,
    String? action,
    Map<String, dynamic>? args,
    String? threadId,
    required String clientId,
  }) async {
    final r = await _api.post(
      ApiConstants.assistantMessage,
      {
        if (text != null && text.trim().isNotEmpty) 'text': text.trim(),
        if (action != null && action.isNotEmpty) 'action': action,
        if (args != null && args.isNotEmpty) 'args': args,
        if (threadId != null && threadId.isNotEmpty) 'session_id': threadId,
        'client_id': clientId,
      },
      token: token,
    );
    return ScoutTurn.fromEnvelope(r);
  }

  /// The chat drawer. Newest first, archived chats only when asked for.
  Future<List<ScoutThread>> threads(
    String token, {
    bool includeArchived = false,
    int limit = 30,
  }) async {
    final r = await _api.get(
      ApiConstants.assistantThreads,
      token: token,
      queryParams: {
        if (includeArchived) 'archived': '1',
        'limit': '$limit',
      },
    );
    if (r['success'] != true || r['data'] is! Map) return const [];
    final data = Map<String, dynamic>.from(r['data'] as Map);
    final rows = data['threads'];
    if (rows is! List) return const [];
    return rows
        .whereType<Map>()
        .map((m) => ScoutThread.fromJson(Map<String, dynamic>.from(m)))
        .where((t) => t.id.isNotEmpty)
        .toList();
  }

  /// "New chat". Returned raw: hitting the per-user thread cap is a 409 whose
  /// sentence ("You have too many chats — archive one") is the actual instruction,
  /// and a generic failure toast would hide it.
  Future<Map<String, dynamic>> createThread(String token, {String? title}) => _api.post(
        ApiConstants.assistantThreads,
        {if (title != null && title.trim().isNotEmpty) 'title': title.trim()},
        token: token,
      );

  /// One page of transcript, oldest-first within the page. [before] is the opaque
  /// cursor from the previous page — never an offset.
  Future<ScoutHistoryPage> history(
    String token,
    String threadId, {
    int limit = 40,
    String? before,
  }) async {
    final r = await _api.get(
      ApiConstants.assistantThreadMessages(threadId),
      token: token,
      queryParams: {
        'limit': '$limit',
        if (before != null && before.isNotEmpty) 'before': before,
      },
    );
    if (r['success'] != true || r['data'] is! Map) return ScoutHistoryPage.empty;
    return ScoutHistoryPage.fromJson(Map<String, dynamic>.from(r['data'] as Map));
  }

  /// Rename and/or archive. Both keys in one body is legal server-side.
  Future<Map<String, dynamic>> updateThread(
    String token,
    String threadId, {
    String? title,
    bool? archived,
  }) =>
      _api.patch(
        ApiConstants.assistantThread(threadId),
        {
          'title': ?title,
          'archived': ?archived,
        },
        token: token,
      );

  Future<Map<String, dynamic>> deleteThread(String token, String threadId) =>
      _api.delete(ApiConstants.assistantThread(threadId), token: token);

  /// Thumbs up or down on one Scout message. `vote` is 1 or -1; sending the same
  /// vote twice is harmless (the row is keyed by message and user).
  Future<bool> vote(String token, String messageId, int vote, {String? reason}) async {
    final r = await _api.post(
      ApiConstants.assistantFeedback(messageId),
      {
        'vote': vote >= 0 ? 1 : -1,
        if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
      },
      token: token,
    );
    return r['success'] == true;
  }

  /// What Scout can do, straight from the backend's own table — so the help sheet
  /// can never advertise an ability the server does not have.
  Future<List<ScoutCapability>> capabilities(String token) async {
    final r = await _api.get(ApiConstants.assistantCapabilities, token: token);
    if (r['success'] != true || r['data'] is! Map) return const [];
    final data = Map<String, dynamic>.from(r['data'] as Map);
    return ScoutCapability.listFrom(data['capabilities']);
  }
}
