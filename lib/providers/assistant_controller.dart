import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/assistant.dart';
import '../services/assistant_service.dart';

/// Owns the live state of one Scout conversation.
///
/// Instantiated by the assistant screen and disposed with it, the same shape
/// [ChatController] uses for a person-to-person chat — a global provider would keep a
/// stale transcript alive after logout, and Scout's history is per-user by JWT.
///
/// Three rules shape everything below.
///
/// 1. **A typed sentence is never lost.** The user bubble is appended before the POST
///    leaves, and a failure marks it `failed` rather than removing it. Retry re-sends
///    the same `client_id`, which is what makes a retried booking one booking: the
///    server's idempotency key is that id, so the second attempt returns the first
///    attempt's answer instead of charging a wallet twice.
///
/// 2. **One turn at a time.** [busy] gates the composer, the chips and every card
///    button. Scout's dialog has server-side state — a slot-filling turn expects the
///    next message to be the answer to its question — so two turns racing can commit
///    a confirm against the wrong pending action. The lock is UX, and it is also
///    correctness.
///
/// 3. **The server owns the FSM.** [fsm] is mirrored from each reply, never computed
///    here. The screen reads it to change one word in the composer hint; if it drifted
///    from the server's own state the hint would lie about what typing does next.
class AssistantController extends ChangeNotifier {
  AssistantController({required this.token, this.initialThreadId});

  final String token;
  final String? initialThreadId;

  final AssistantService _svc = AssistantService();

  final List<ScoutMessage> _messages = [];
  List<ScoutCapability> _capabilities = const [];

  String? _threadId;
  String? _title;
  ScoutFsm _fsm = ScoutFsm.idle;

  bool _booting = true;
  bool _busy = false;
  bool _loadingOlder = false;
  bool _hasMore = false;
  String? _cursor;
  String? _notice;
  bool _disposed = false;

  /// Set the first time this conversation changes the user's bookings, and never
  /// unset. A cancellation counts: it moves the same row the Bookings tab renders.
  ///
  /// A booking made here is that row, not a copy of it, so the tab needs a re-read and
  /// nothing else — no second write, no local mirror to keep in step. The screen hands
  /// this flag back when it pops, which is the whole mechanism behind "shows instantly
  /// in My Bookings", and the reason that claim is cheap to make.
  bool _bookingsChanged = false;

  // What the screen reads
  List<ScoutMessage> get messages => List.unmodifiable(_messages);
  List<ScoutCapability> get capabilities => _capabilities;
  String? get threadId => _threadId;
  String? get title => _title;
  ScoutFsm get fsm => _fsm;
  bool get booting => _booting;
  bool get busy => _busy;
  bool get loadingOlder => _loadingOlder;
  bool get hasMore => _hasMore;
  String? get notice => _notice;
  bool get bookingsChanged => _bookingsChanged;
  bool get isEmpty => _messages.isEmpty;

  /// The screen the last reply pointed at, if it pointed at one. `app_help` answers
  /// carry `meta.screen`, and offering the jump is the client's half of that action.
  String? get suggestedScreen {
    for (final m in _messages.reversed) {
      if (!m.isScout) continue;
      return m.reply?.targetScreen;
    }
    return null;
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  // Boot

  /// Open the conversation the user was last in, or start a blank one.
  ///
  /// A blank one is genuinely blank: no thread row is created until the first message,
  /// because the backend caps threads per user and opening the screen is not a decision
  /// to start a chat. The first POST with no `session_id` creates the thread and
  /// returns its id.
  Future<void> start() async {
    _booting = true;
    _emit();
    try {
      final wanted = initialThreadId;
      if (wanted != null && wanted.isNotEmpty) {
        await _load(wanted);
      } else {
        final list = await _svc.threads(token);
        final open = list.where((t) => !t.archived).toList();
        if (open.isNotEmpty) await _load(open.first.id);
      }
    } catch (_) {
      _notice = 'Could not load your earlier chats. You can still start a new one.';
    }
    _booting = false;
    _emit();
    unawaited(_fetchCapabilities());
  }

  Future<void> _load(String id) async {
    final page = await _svc.history(token, id);
    _threadId = id;
    _title = page.title;
    _fsm = page.fsm;
    _messages
      ..clear()
      ..addAll(page.messages);
    _hasMore = page.hasMore;
    _cursor = page.cursor;
  }

  Future<void> _fetchCapabilities() async {
    try {
      final caps = await _svc.capabilities(token);
      if (caps.isNotEmpty) {
        _capabilities = caps;
        _emit();
      }
    } catch (_) {
      // The menu card and the abstain reply both carry the same list, so a failure
      // here costs the help sheet and nothing else. Not worth a banner.
    }
  }

  /// One page older, appended at the front.
  ///
  /// The cursor is opaque and points at the next older page, so paging never
  /// re-reads or skips a row even when two messages share a timestamp — the server
  /// sorts by `(created_at, is_assistant, id)` precisely so this can be true.
  Future<void> loadOlder() async {
    final id = _threadId;
    final cursor = _cursor;
    if (id == null || cursor == null || _loadingOlder || !_hasMore) return;
    _loadingOlder = true;
    _emit();
    try {
      final page = await _svc.history(token, id, before: cursor);
      _messages.insertAll(0, page.messages);
      _hasMore = page.hasMore;
      _cursor = page.cursor;
    } catch (_) {
      _notice = 'Could not load older messages.';
    }
    _loadingOlder = false;
    _emit();
  }

  // Sending

  /// A typed sentence. This is the only path that reaches the intent classifier.
  Future<void> sendText(String text) {
    final t = text.trim();
    if (t.isEmpty || _busy) return Future<void>.value();
    return _turn(text: t);
  }

  /// A tapped chip. Posts `{action, args, text: <label>}`, so the server executes the
  /// action directly and model #4 never sees it — which is both why a chip cannot be
  /// misunderstood and why chip traffic does not flatter the model's measured accuracy.
  Future<void> sendChip(ScoutChip chip) {
    if (_busy) return Future<void>.value();
    if (chip.action == 'retry_last') return retryLast();
    return _turn(text: chip.label, action: chip.action, args: chip.args);
  }

  /// Re-send the newest failed message. Same `client_id`, so a booking that actually
  /// went through before the connection dropped returns its original answer rather
  /// than charging the wallet a second time.
  Future<void> retryLast() {
    for (var i = _messages.length - 1; i >= 0; i--) {
      final m = _messages[i];
      if (!m.isScout && m.delivery == ScoutDelivery.failed) return retry(m);
    }
    return Future<void>.value();
  }

  Future<void> retry(ScoutMessage failed) {
    final cid = failed.clientId;
    if (_busy || failed.isScout || cid == null) return Future<void>.value();
    // Drop any offline bubble that followed it; the retry will produce a real answer.
    while (_messages.isNotEmpty && _messages.last.isScout && _messages.last.isLocal) {
      _messages.removeLast();
    }
    // A failed chip has to be retried as that chip, not as its label typed out —
    // otherwise a retry would route a button press through the classifier and could
    // land on a different action than the one the user pressed.
    final was = _inFlight[cid];
    return _turn(
      text: failed.text,
      action: was?.action,
      args: was?.args,
      resend: failed,
    );
  }

  Future<void> _turn({
    required String text,
    String? action,
    Map<String, dynamic>? args,
    ScoutMessage? resend,
  }) async {
    final clientId = resend?.clientId ?? AssistantService.newClientId();
    final local = (resend ?? ScoutMessage.user(text, clientId: clientId))
        .copyWith(delivery: ScoutDelivery.sending);
    final at = _indexOf(local.id);
    if (at >= 0) {
      _messages[at] = local;
    } else {
      _messages.add(local);
    }

    _inFlight[clientId] = (action: action, args: args);
    _busy = true;
    _notice = null;
    _emit();

    final turn = await _svc.send(
      token,
      text: text,
      action: action,
      args: args,
      threadId: _threadId,
      clientId: clientId,
    );

    final i = _indexOf(local.id);
    if (i >= 0) {
      _messages[i] = local.copyWith(
        delivery: turn.ok ? ScoutDelivery.sent : ScoutDelivery.failed,
      );
    }

    if (turn.ok) _inFlight.remove(clientId);
    if (turn.threadId.isNotEmpty) _threadId = turn.threadId;
    _fsm = turn.fsm;

    // A 500 still carries a reply, and the server deliberately did not persist it —
    // so it is shown, and it disappears on reload, which is the honest behaviour for
    // a turn whose transaction rolled back.
    _messages.add(ScoutMessage.scout(turn.reply, id: turn.messageId, nlu: turn.nlu));

    if (turn.reply.actionOk == true &&
        (turn.reply.action == 'book_venue' || turn.reply.action == 'cancel_booking')) {
      _bookingsChanged = true;
    }
    if (!turn.ok && turn.message != null && turn.reply.text.isEmpty) {
      _notice = turn.message;
    }

    _busy = false;
    _emit();
  }

  int _indexOf(String id) => _messages.indexWhere((m) => m.id == id);

  /// `client_id` → what was sent, kept only until the turn succeeds. It is
  /// what lets a retry repeat a chip press faithfully.
  final Map<String, ({String? action, Map<String, dynamic>? args})> _inFlight = {};

  // Threads

  /// Start a fresh conversation.
  ///
  /// Nothing is created server-side here. A thread row appears when the first message
  /// is sent, so tapping "new chat" and then changing course does not consume one of the
  /// user's capped thread slots — and the empty state is a real empty state.
  void newChat() {
    if (_busy) return;
    _messages.clear();
    _threadId = null;
    _title = null;
    _fsm = ScoutFsm.idle;
    _hasMore = false;
    _cursor = null;
    _notice = null;
    _inFlight.clear();
    _emit();
  }

  Future<void> openThread(String id) async {
    if (_busy || id == _threadId) return;
    _booting = true;
    _emit();
    try {
      await _load(id);
    } catch (_) {
      _notice = 'Could not open that chat.';
    }
    _booting = false;
    _emit();
  }

  Future<List<ScoutThread>> listThreads({bool includeArchived = false}) =>
      _svc.threads(token, includeArchived: includeArchived);

  Future<bool> renameThread(String id, String title) async {
    final r = await _svc.updateThread(token, id, title: title);
    final ok = r['success'] == true;
    if (ok && id == _threadId) {
      _title = title;
      _emit();
    }
    return ok;
  }

  Future<bool> archiveThread(String id, {bool archived = true}) async {
    final r = await _svc.updateThread(token, id, archived: archived);
    final ok = r['success'] == true;
    if (ok && archived && id == _threadId) newChat();
    return ok;
  }

  Future<bool> deleteThread(String id) async {
    final r = await _svc.deleteThread(token, id);
    final ok = r['success'] == true;
    if (ok && id == _threadId) newChat();
    return ok;
  }

  // Feedback

  /// Rate one of Scout's answers, optimistically.
  ///
  /// These votes are the only quality signal that comes from real use rather than from
  /// the held-out exam. Optimistic because a thumb that waits on a round trip stops
  /// being a reflex, and reverted on failure because a rating that silently did not
  /// save is worse than one that visibly failed.
  ///
  /// Only 1 and -1 exist. The endpoint upserts on `(message_id, user_id)`, so changing
  /// a vote works and un-voting is not a thing the server can be asked for.
  Future<void> vote(ScoutMessage msg, int value) async {
    if (!msg.canVote || (value != 1 && value != -1)) return;
    final i = _indexOf(msg.id);
    if (i < 0) return;
    final before = _messages[i].vote;
    _messages[i] = _messages[i].copyWith(vote: value);
    _emit();

    final ok = await _svc.vote(token, msg.id, value);
    if (!ok) {
      final j = _indexOf(msg.id);
      if (j >= 0) _messages[j] = _messages[j].copyWith(vote: before);
      _notice = 'Could not save that rating.';
      _emit();
    }
  }

  void dismissNotice() {
    if (_notice == null) return;
    _notice = null;
    _emit();
  }
}
