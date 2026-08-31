import '../constants/api_constants.dart';
import '../models/app_notification.dart';
import 'api_service.dart';

/// One page of the feed, plus the opaque cursor that continues it.
class NotificationPage {
  final List<AppNotification> items;
  final bool hasMore;

  /// Passed back to the server VERBATIM. It is a `"<createdAt>~<id>"` pair today
  /// and must be free to become something else without a client release, so
  /// nothing on this side parses it or builds one.
  final String? nextCursor;

  const NotificationPage({
    required this.items,
    required this.hasMore,
    required this.nextCursor,
  });

  static const NotificationPage empty =
      NotificationPage(items: <AppNotification>[], hasMore: false, nextCursor: null);
}

/// The notification preferences form, in one object.
///
/// `categories` and `unmutable` come from the server rather than a const list here:
/// they are derived from `notificationTypes.js`, so a category added in the next
/// wave appears in the settings screen with no client change, and `system` is named
/// as unmutable by the same authority that enforces it in `pushJob`.
class NotificationPrefs {
  final bool muteAll;
  final Map<String, bool> push;
  final Map<String, bool> inApp;
  final bool quietEnabled;
  final String quietStart;
  final String quietEnd;
  final List<String> categories;
  final List<String> unmutable;

  const NotificationPrefs({
    required this.muteAll,
    required this.push,
    required this.inApp,
    required this.quietEnabled,
    required this.quietStart,
    required this.quietEnd,
    required this.categories,
    required this.unmutable,
  });

  static Map<String, bool> _flags(dynamic v) {
    final out = <String, bool>{};
    if (v is Map) {
      v.forEach((k, val) => out[k.toString()] = val != false);
    }
    return out;
  }

  factory NotificationPrefs.fromJson(Map<String, dynamic> j) {
    final p = j['prefs'] is Map ? Map<String, dynamic>.from(j['prefs'] as Map) : <String, dynamic>{};
    final q = p['quietHours'] is Map ? Map<String, dynamic>.from(p['quietHours'] as Map) : <String, dynamic>{};
    return NotificationPrefs(
      muteAll: p['muteAll'] == true,
      push: _flags(p['push']),
      inApp: _flags(p['inApp']),
      quietEnabled: q['enabled'] == true,
      quietStart: (q['start'] ?? '22:00').toString(),
      quietEnd: (q['end'] ?? '07:00').toString(),
      categories: (j['categories'] as List? ?? const []).map((e) => e.toString()).toList(),
      unmutable: (j['unmutable'] as List? ?? const []).map((e) => e.toString()).toList(),
    );
  }

  /// Only the three keys the server reads. `categories`/`unmutable` are
  /// server-owned facts and are never echoed back at it.
  Map<String, dynamic> toBody() => {
        'muteAll': muteAll,
        'push': push,
        'inApp': inApp,
        'quietHours': {'enabled': quietEnabled, 'start': quietStart, 'end': quietEnd},
      };

  NotificationPrefs copyWith({
    bool? muteAll,
    Map<String, bool>? push,
    Map<String, bool>? inApp,
    bool? quietEnabled,
    String? quietStart,
    String? quietEnd,
  }) =>
      NotificationPrefs(
        muteAll: muteAll ?? this.muteAll,
        push: push ?? this.push,
        inApp: inApp ?? this.inApp,
        quietEnabled: quietEnabled ?? this.quietEnabled,
        quietStart: quietStart ?? this.quietStart,
        quietEnd: quietEnd ?? this.quietEnd,
        categories: categories,
        unmutable: unmutable,
      );
}

/// REST for the notification feed. The LIVE half is `RealtimeService.notifications`
/// (a `notification:new` frame per drained outbox row) and `PushService` (the tray).
///
/// Every read returns a safe empty value on failure rather than throwing. A bell
/// that shows nothing is a small wrong; a bell that crashes the home screen because
/// the network blipped is a large one, and the caller has no better recovery than
/// showing zero anyway.
class NotificationService {
  final ApiClient _api = ApiClient();

  Future<NotificationPage> list(
    String token, {
    String? cursor,
    String? category,
    bool unreadOnly = false,
    int limit = 25,
  }) async {
    final params = <String, String>{'limit': '$limit'};
    if (cursor != null && cursor.isNotEmpty) params['cursor'] = cursor;
    if (category != null && category.isNotEmpty) params['category'] = category;
    if (unreadOnly) params['unreadOnly'] = 'true';
    final r = await _api.get(ApiConstants.notifications, token: token, queryParams: params);
    if (r['success'] != true || r['data'] is! Map) return NotificationPage.empty;
    final d = Map<String, dynamic>.from(r['data'] as Map);
    return NotificationPage(
      items: (d['items'] as List? ?? const [])
          .whereType<Map>()
          .map((m) => AppNotification.fromJson(Map<String, dynamic>.from(m)))
          .toList(),
      hasMore: d['hasMore'] == true,
      nextCursor: d['nextCursor']?.toString(),
    );
  }

  Future<NotificationSummary> summary(String token) async {
    final r = await _api.get(ApiConstants.notificationSummary, token: token);
    if (r['success'] != true || r['data'] is! Map) return NotificationSummary.empty;
    return NotificationSummary.fromJson(Map<String, dynamic>.from(r['data'] as Map));
  }

  Future<Map<String, dynamic>> markRead(String token, String id) =>
      _api.patch(ApiConstants.notificationRead(id), const {}, token: token);

  Future<Map<String, dynamic>> markUnread(String token, String id) =>
      _api.patch(ApiConstants.notificationUnread(id), const {}, token: token);

  /// `category` null = everything. The server scopes both forms to the caller, so
  /// there is no id to get wrong here.
  Future<Map<String, dynamic>> readAll(String token, {String? category}) =>
      _api.post(ApiConstants.notificationReadAll, {
        if (category != null && category.isNotEmpty) 'category': category,
      }, token: token);

  /// Dismiss, NOT delete: the row stays on disk with `dismissed_at` set, out of the
  /// feed and out of the badge. That is what makes a swipe recoverable by support
  /// and what keeps "you were marked a no-show" from being erasable evidence.
  Future<Map<String, dynamic>> dismiss(String token, String id) =>
      _api.delete(ApiConstants.notification(id), token: token);

  /// "Clear read" -- the only hard delete offered, and bounded server-side: unread
  /// rows survive and so do rows younger than an hour, so a tap right after a batch
  /// lands cannot erase what just arrived.
  ///
  /// The category rides in the QUERY STRING because that is where the route reads it
  /// (`req.query.category`); ApiClient.delete has no queryParams argument, so it is
  /// appended here rather than silently sent in a body the server never opens.
  Future<Map<String, dynamic>> clearRead(String token, {String? category}) {
    final q = (category == null || category.isEmpty)
        ? ''
        : '?category=${Uri.encodeQueryComponent(category)}';
    return _api.delete('${ApiConstants.notifications}$q', token: token);
  }

  Future<NotificationPrefs?> prefs(String token) async {
    final r = await _api.get(ApiConstants.notificationPrefs, token: token);
    if (r['success'] != true || r['data'] is! Map) return null;
    return NotificationPrefs.fromJson(Map<String, dynamic>.from(r['data'] as Map));
  }

  /// The response is what was actually KEPT after the server re-normalised it, so
  /// the screen renders the echo rather than its own optimistic copy -- an unknown
  /// category or a malformed "25:99" is dropped server-side, and showing the user
  /// their rejected input back as if it stuck is the failure this avoids.
  Future<NotificationPrefs?> savePrefs(String token, NotificationPrefs p) async {
    final r = await _api.put(ApiConstants.notificationPrefs, p.toBody(), token: token);
    if (r['success'] != true || r['data'] is! Map) return null;
    return NotificationPrefs.fromJson(Map<String, dynamic>.from(r['data'] as Map));
  }

  /// Register or refresh this device's FCM token. Called on login, on every
  /// `onTokenRefresh` and on app start -- FCM rotates tokens without warning, so
  /// "register once at signup" leaves a dead token that looks alive until a send
  /// fails.
  Future<Map<String, dynamic>> registerDevice(
    String token, {
    required String fcmToken,
    String? platform,
    String? appVersion,
    String? label,
  }) =>
      _api.post(ApiConstants.notificationDevices, {
        'token': fcmToken,
        'platform': ?platform,
        'appVersion': ?appVersion,
        'label': ?label,
      }, token: token);

  /// Revoke on logout, so the next person to use this phone does not get the last
  /// person's pushes.
  Future<Map<String, dynamic>> revokeDevice(String token, String fcmToken) =>
      _api.delete(ApiConstants.notificationDevices, body: {'token': fcmToken}, token: token);

  /// Dev-only, and only ever to yourself -- the demo lever for showing push work
  /// without waiting for a real booking. The route accepts no userId at all, so it
  /// cannot be turned into a way to buzz somebody else's phone, and it is refused
  /// outright in production.
  Future<Map<String, dynamic>> sendTest(String token, {String? title, String? body}) =>
      _api.post(ApiConstants.notificationTest, {
        'title': ?title,
        'body': ?body,
      }, token: token);
}
