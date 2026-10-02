import 'dart:math';

import '../constants/api_constants.dart';
import '../models/assistant.dart';
import 'api_service.dart';

/// Raised by [AssistantService.threads] when the chat list could not be read.
///
/// Every other method here answers a failure with a value, because every other method
/// has a value that can carry one: a turn degrades to a renderable reply, a vote to
/// false. A list has no such value — returning `[]` for "the request failed" is
/// indistinguishable from "this account has no chats", which is how a server error came
/// to be displayed as an empty history with no way to retry it. The distinction has to
/// leave this method somehow, and an exception is the only channel a `List` return has.
class ScoutUnavailable implements Exception {
  final String message;

  const ScoutUnavailable(this.message);

  @override
  String toString() => message;
}

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
/// [ApiClient] turns a socket failure into `{success: false, message}` and never
/// throws, so a failed turn still yields a [ScoutTurn] with a renderable reply and a
/// dropped connection draws a bubble rather than an exception. [threads] is the one
/// exception to that, and [ScoutUnavailable] says why.
class AssistantService {
  final ApiClient _api = ApiClient();

  static final Random _rng = Random();

  /// A per-message idempotency key. Held by the caller across retries.
  static String newClientId() {
    final n = _rng.nextInt(1 << 32).toRadixString(36);
    return '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}$n';
  }

  /// One turn. Give [text] for a typed message, or [action] (+[args]) for a chip.
  ///
  /// [newSession] marks the first turn of a chat the user deliberately started. It
  /// exists because an absent `session_id` means "the newest chat, or a new one" on
  /// the server: without the flag, a new conversation is appended to the thread the
  /// user just left, and every chat they start collapses into one row of history.
  Future<ScoutTurn> send(
    String token, {
    String? text,
    String? action,
    Map<String, dynamic>? args,
    String? threadId,
    bool newSession = false,
    required String clientId,
  }) async {
    final r = await _api.post(
      ApiConstants.assistantMessage,
      {
        if (text != null && text.trim().isNotEmpty) 'text': text.trim(),
        if (action != null && action.isNotEmpty) 'action': action,
        if (args != null && args.isNotEmpty) 'args': args,
        if (threadId != null && threadId.isNotEmpty) 'session_id': threadId,
        if (newSession) 'new_session': true,
        'client_id': clientId,
      },
      token: token,
    );
    return ScoutTurn.fromEnvelope(r);
  }

  /// The chat drawer. Newest first, archived chats only when asked for.
  ///
  /// The default matches the server's own per-user thread cap (50), so a user sitting
  /// at that cap sees every chat they have rather than the newest 30 of them.
  ///
  /// Throws [ScoutUnavailable] if the read failed, so the caller can tell an outage
  /// from an account with no chats. A well-formed answer holding no threads is an
  /// empty list, not an error.
  Future<List<ScoutThread>> threads(
    String token, {
    bool includeArchived = false,
    int limit = 50,
  }) async {
    final r = await _api.get(
      ApiConstants.assistantThreads,
      token: token,
      queryParams: {
        if (includeArchived) 'archived': '1',
        'limit': '$limit',
      },
    );
    if (r['success'] != true) {
      final said = r['message'];
      throw ScoutUnavailable(
        said is String && said.trim().isNotEmpty
            ? said.trim()
            : 'Could not load your chats.',
      );
    }
    if (r['data'] is! Map) return const [];
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

  /// Whether the intent classifier is loaded and answering.
  ///
  /// True when the question could not be asked. A failed probe means the API
  /// itself is unreachable, and the next turn will say so far more plainly than a
  /// banner about a Python service on another port — so the absence of an answer
  /// is never read as an outage of the model.
  Future<bool> nluReady(String token) async {
    final r = await _api.get(ApiConstants.assistantHealth, token: token);
    if (r['success'] != true || r['data'] is! Map) return true;
    final data = Map<String, dynamic>.from(r['data'] as Map);
    final nlu = data['nlu'];
    return nlu is! Map || nlu['ready'] != false;
  }
}
