import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/app_notification.dart';
import '../services/notification_service.dart';
import '../services/realtime_service.dart';

/// The notification feed, the unread badge, and the socket subscription that keeps
/// both honest.
///
/// Why this is A Provider and the CHAT badge is not
/// The chat badge lives in each home screen's State because it is one integer read
/// from one endpoint. The bell is not: the count on the header, the list behind it,
/// the filter chips and the foreground banner are four views of the same rows, and
/// three of them can be on screen at once. A single ChangeNotifier is what keeps a
/// swipe-to-dismiss in the list from leaving a stale number in the header.
///
/// Why the count is re-read and not incremented
/// `notification:new` could just do `_unread++`, and that would be wrong within a
/// day: the server decides what counts (dismissed rows out, a collapsed row counted
/// once no matter how many messages it represents), and a second copy of that rule
/// here is how a badge starts disagreeing with the list it links to. So the socket
/// frame is a TRIGGER, not data -- it debounces a re-read of `/summary`. The
/// exception is the optimistic paths below, where the user's own tap is the source
/// of truth and waiting for a round trip would feel broken.
class NotificationProvider extends ChangeNotifier {
  final NotificationService _svc = NotificationService();

  String? _token;
  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _debounce;
  bool _disposed = false;

  final List<AppNotification> _items = <AppNotification>[];
  NotificationSummary _summary = NotificationSummary.empty;

  bool _loading = false;
  bool _loadingMore = false;
  String? _cursor;
  bool _hasMore = false;
  String? _category;
  bool _unreadOnly = false;
  String? _error;

  /// The last frame the socket delivered, for the foreground banner. Consumed by
  /// whoever shows it -- kept here rather than pushed through a second stream so a
  /// screen that rebuilds does not miss one that arrived mid-frame.
  Map<String, dynamic>? _lastFrame;

  List<AppNotification> get items => List.unmodifiable(_items);
  int get unread => _summary.unread;
  Map<String, int> get byCategory => _summary.byCategory;
  bool get pushConfigured => _summary.pushConfigured;
  bool get isLoading => _loading;
  bool get isLoadingMore => _loadingMore;
  bool get hasMore => _hasMore;
  String? get category => _category;
  bool get unreadOnly => _unreadOnly;
  String? get error => _error;
  Map<String, dynamic>? get lastFrame => _lastFrame;

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  /// Bind to a signed-in session. Idempotent for the same token, so calling it from
  /// every home screen's `initState` costs one subscription, not three.
  ///
  /// The socket is opened here rather than inside the notifications screen: a badge
  /// that only moves while the list is already on screen is not a badge.
  void attach(String? token) {
    if (token == null || token.isEmpty) {
      detach();
      return;
    }
    if (_token == token && _sub != null) return;
    _token = token;
    _sub?.cancel();
    RealtimeService().ensureConnected(token);
    _sub = RealtimeService().notifications.listen(_onFrame);
    refreshSummary();
  }

  /// Drop the session's state on logout. The badge must not survive into the next
  /// user's session, and neither must the rows behind it.
  void detach() {
    _sub?.cancel();
    _sub = null;
    _debounce?.cancel();
    _debounce = null;
    _token = null;
    _items.clear();
    _summary = NotificationSummary.empty;
    _cursor = null;
    _hasMore = false;
    _lastFrame = null;
    notifyListeners();
  }

  void _onFrame(Map<String, dynamic> frame) {
    _lastFrame = frame;
    // A batch -- a generated bracket alerts every captain, a settled match alerts
    // both -- arrives as several frames within a second or two. One re-read after
    // the burst, not one per frame.
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 900), () {
      refreshSummary();
      // Only refresh the list if the user is looking at it. Rebuilding a list nobody
      // has open is a wasted request on a metered connection, and the screen reloads
      // on open anyway.
      if (_items.isNotEmpty) refresh();
    });
    notifyListeners();
  }

  /// Cheap: one row of counts. Called on attach, on every socket burst, and when a
  /// screen that changed something comes back into view.
  Future<void> refreshSummary() async {
    final t = _token;
    if (t == null) return;
    _summary = await _svc.summary(t);
    notifyListeners();
  }

  /// Change the filter and reload. Passing the same category twice clears it, which
  /// is what a chip row is expected to do when the selected chip is tapped.
  Future<void> setCategory(String? c) async {
    _category = (_category == c) ? null : c;
    await refresh();
  }

  Future<void> setUnreadOnly(bool v) async {
    if (_unreadOnly == v) return;
    _unreadOnly = v;
    await refresh();
  }

  /// Page one, replacing whatever is held. The cursor is reset here and only here.
  Future<void> refresh() async {
    final t = _token;
    if (t == null) return;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final page = await _svc.list(
        t,
        category: _category,
        unreadOnly: _unreadOnly,
      );
      _items
        ..clear()
        ..addAll(page.items);
      _cursor = page.nextCursor;
      _hasMore = page.hasMore;
      _summary = await _svc.summary(t);
    } catch (e) {
      _error = 'Could not load notifications';
      if (kDebugMode) debugPrint('[notif] refresh failed: $e');
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// The next page. Guarded against re-entry because a fast scroll fires the
  /// threshold callback several times before the first response lands, and two pages
  /// requested from the same cursor arrive as visible duplicates.
  Future<void> loadMore() async {
    final t = _token;
    if (t == null || _loadingMore || !_hasMore || _cursor == null) return;
    _loadingMore = true;
    notifyListeners();
    try {
      final page = await _svc.list(
        t,
        cursor: _cursor,
        category: _category,
        unreadOnly: _unreadOnly,
      );
      // Belt and braces over the server's own total ordering on (created_at, id):
      // if a row somehow repeats, it must not render twice.
      final seen = _items.map((i) => i.id).toSet();
      _items.addAll(page.items.where((i) => !seen.contains(i.id)));
      _cursor = page.nextCursor;
      _hasMore = page.hasMore;
    } catch (e) {
      if (kDebugMode) debugPrint('[notif] loadMore failed: $e');
    } finally {
      _loadingMore = false;
      notifyListeners();
    }
  }

  // Optimistic writes
  //
  // These three move the UI first and reconcile after. That is the right trade for a
  // tap the user made: the row is already under their thumb, the server is the
  // authority on the count (which is re-read from /summary once the call returns), and
  // a 200 ms wait before a dot disappears reads as a broken app. A failure is
  // reconciled by the same /summary read, so the worst case is a dot that comes back.

  /// Mark one row read. No-op when it already is -- an idempotent PATCH would be
  /// harmless, but a request per tap on an already-read row is not.
  Future<void> markRead(AppNotification n) async {
    final t = _token;
    if (t == null || n.isRead) return;
    n.isRead = true;
    _summary = NotificationSummary(
      unread: unread > 0 ? unread - 1 : 0,
      byCategory: _decrement(n.category),
      pushConfigured: _summary.pushConfigured,
    );
    notifyListeners();
    await _svc.markRead(t, n.id);
    await refreshSummary();
  }

  Future<void> markUnread(AppNotification n) async {
    final t = _token;
    if (t == null || !n.isRead) return;
    n.isRead = false;
    notifyListeners();
    await _svc.markUnread(t, n.id);
    await refreshSummary();
  }

  Future<void> markAllRead() async {
    final t = _token;
    if (t == null) return;
    for (final n in _items) {
      n.isRead = true;
    }
    notifyListeners();
    // Scoped to the current filter, so "mark all read" inside the Wallet chip does
    // not silently clear the tournament alerts the user has not looked at.
    await _svc.readAll(t, category: _category);
    await refresh();
  }

  /// Dismiss, not delete. The row leaves the feed and the badge; it stays on disk
  /// with `dismissed_at` set, which is what keeps "you were marked a no-show" from
  /// being erasable evidence and what lets support answer "I never got told".
  Future<void> dismiss(AppNotification n) async {
    final t = _token;
    if (t == null) return;
    _items.removeWhere((i) => i.id == n.id);
    if (!n.isRead) {
      _summary = NotificationSummary(
        unread: unread > 0 ? unread - 1 : 0,
        byCategory: _decrement(n.category),
        pushConfigured: _summary.pushConfigured,
      );
    }
    notifyListeners();
    await _svc.dismiss(t, n.id);
    await refreshSummary();
  }

  /// Hard-delete the read rows. The server keeps unread rows and anything younger
  /// than an hour regardless, so this cannot erase what just arrived.
  Future<void> clearRead() async {
    final t = _token;
    if (t == null) return;
    await _svc.clearRead(t, category: _category);
    await refresh();
  }

  Map<String, int> _decrement(String category) {
    final m = Map<String, int>.from(_summary.byCategory);
    final v = m[category] ?? 0;
    m[category] = v > 0 ? v - 1 : 0;
    return m;
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _debounce?.cancel();
    super.dispose();
  }
}
