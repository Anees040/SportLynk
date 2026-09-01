import 'dart:async';
import 'dart:io' show Platform;

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../utils/deep_link.dart';
import '../widgets/in_app_banner.dart';
import 'notification_service.dart';

/// The top-level background handler.
///
/// It must be a top-level (or static) function annotated `@pragma('vm:entry-point')`:
/// a message arriving while the app is killed spins up a separate Dart isolate with no
/// widget tree, no providers and no access to anything this app's `main()` set up, and
/// the AOT compiler would otherwise tree-shake an entry point nothing calls.
///
/// It deliberately does almost nothing. FCM itself draws the tray banner (pushService
/// sends a `notification` block), so there is nothing to render here; the deep link is
/// read from the tap, not from this isolate, because this isolate is gone by then.
/// Doing real work here -- a network call, a database write -- is how a background
/// handler becomes a source of crashes nobody can reproduce.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  if (kDebugMode) {
    debugPrint('[push] background message ${message.messageId}');
  }
}

/// The client half of push: permission, the device token, and the four ways a
/// notification can reach a running app.
///
/// What this does not do
/// It does not decide whether to push, when to push, or whether a category is muted.
/// All of that is server-side in `jobs/pushJob.js`, checked against
/// `users.notification_prefs` and quiet hours before FCM is ever called -- because a
/// preference the client honours is a suggestion, not a preference. This class
/// registers a token and routes taps.
///
/// Shipping dormant
/// The server no-ops cleanly with no `FIREBASE_SERVICE_ACCOUNT`, so nothing here ever
/// receives a message on a dev machine. Everything else still works: the outbox is
/// drained, `notification:new` is emitted, the badge moves and the banner shows,
/// driven by the socket rather than by FCM. Adding the key later switches on the tray
/// with no client change at all.
class PushService {
  static final PushService _instance = PushService._();
  factory PushService() => _instance;
  PushService._();

  final NotificationService _api = NotificationService();

  String? _token;
  String? _sessionToken;
  bool _wired = false;
  StreamSubscription<RemoteMessage>? _onMessage;
  StreamSubscription<RemoteMessage>? _onOpened;
  StreamSubscription<String>? _onRefresh;

  /// The FCM registration token for this install, once it is known.
  String? get deviceToken => _token;

  /// True once permission was granted and a token exists -- the two halves the user
  /// can independently break, and the pair the prefs screen reports on.
  bool get isReady => _token != null;

  /// Wire the message streams once per process.
  ///
  /// Called from `main()` before `runApp`, and specifically before any await that
  /// could let the first frame render: `getInitialMessage()` must be read before
  /// something else consumes it, and the cold-start link has to be parked while there
  /// is still no navigator to push it through.
  ///
  /// Wrapped whole in a try/catch. A phone without Google Play Services, an emulator
  /// image without it, or a Firebase project misconfiguration must degrade to "no
  /// push" -- never to an app that will not start. That is the same discipline as
  /// `mlClient.isConfigured()` on the server.
  Future<void> init() async {
    if (_wired) return;
    _wired = true;
    try {
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

      // A tray tap on a killed app. Resolves before the first frame, so it is parked
      // rather than pushed -- `DeepLink.replayPending()` fires it once a home screen
      // is mounted and AuthProvider has resolved. Without this, the single most
      // impressive case in a demo (locked phone -> tap -> booking detail) silently
      // lands on the home screen instead.
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) {
        DeepLink.park(_linkOf(initial));
      }

      // Foreground. FCM shows nothing at all while the app is open, so this is where
      // the in-app banner comes from.
      _onMessage = FirebaseMessaging.onMessage.listen((m) {
        if (!allowsBanner(m.data['category']?.toString())) return;
        InAppBanner.show({
          'title': m.notification?.title ?? m.data['title'] ?? '',
          'body': m.notification?.body ?? m.data['body'] ?? '',
          'deepLink': _linkOf(m),
        });
      });

      // A tray tap while the app was merely backgrounded -- the navigator exists, so
      // this one goes straight through.
      _onOpened = FirebaseMessaging.onMessageOpenedApp.listen((m) {
        if (!DeepLink.open(_linkOf(m))) {
          DeepLink.navigatorKey.currentState?.pushNamed('/notifications');
        }
      });
    } catch (e) {
      debugPrint('[push] init skipped: $e');
    }
  }

  // The `inApp` preference
  //
  // Why this is a separate switch from `push`
  // They are genuinely different wishes. `push` is "buzz my phone when I am not
  // looking" and is enforced in `jobs/pushJob.js` before FCM is called, so a muted
  // category never reaches this process at all. `inApp` is "do not cover my screen
  // while I am using the app", and the only place that can be honoured is here --
  // which is exactly what `notificationFeed.js` says of it: honoured by the Flutter
  // side, for the foreground banner only.
  //
  // It can never suppress the row or the badge. Muting is about interruption, not
  // about hiding what happened, and a chat message that was silently dropped from
  // the feed because of a banner setting would be a lost message.
  Map<String, bool> _inApp = const <String, bool>{};

  /// May a foreground banner be drawn for this category? An absent key means yes --
  /// the same "absent = on" rule the server applies, so a category added in a later
  /// wave is not silently muted on an old build.
  bool allowsBanner(String? category) {
    if (category == null || category.isEmpty) return true;
    if (category == 'system') return true; // unmutable, as on the server
    return _inApp[category] != false;
  }

  /// Called by the settings screen with the server's echo, so a toggle takes effect
  /// on the very next message instead of after a restart.
  void applyPrefs(NotificationPrefs p) {
    _inApp = Map<String, bool>.unmodifiable(p.inApp);
  }

  /// One best-effort GET at register time, so the setting is honoured for a user who
  /// has not opened the settings screen this session. A failure leaves every category
  /// allowed, which is the safe direction: a banner too many, never a message lost.
  Future<void> _loadPrefs(String sessionToken) async {
    try {
      final p = await _api.prefs(sessionToken);
      if (p != null) applyPrefs(p);
    } catch (_) {/* prefs are advisory here; never block registration on them */}
  }

  /// Rebuild `{route, args}` out of an FCM data block.
  ///
  /// FCM data payloads are string-to-string and cannot carry a nested object, so
  /// `pushService.strData` flattens the link into two keys: `route` as a plain string
  /// and `args` JSON-encoded. It also drops empty values, so a route with no arguments
  /// arrives with no `args` key at all rather than with `"{}"` -- which is why the
  /// fallback here is an empty map and not a null that `DeepLink.parse` would reject.
  static Map<String, dynamic>? _linkOf(RemoteMessage m) {
    final route = m.data['route'];
    if (route == null || route.toString().isEmpty) return null;
    return {'route': route, 'args': m.data['args'] ?? <String, dynamic>{}};
  }

  /// Ask for permission and register the token against the signed-in user.
  ///
  /// Called after login and on every app start with a live session. Idempotent for the
  /// same (session, device token) pair, so calling it from three home screens costs one
  /// request.
  ///
  /// Android 13 (API 33) needs this call
  /// `POST_NOTIFICATIONS` became a runtime permission in Android 13, and
  /// `requestPermission()` is what raises the system dialog. Skip it and the token
  /// registers, the server sends, FCM accepts, and nothing ever appears -- with no
  /// error anywhere to explain why. On Android 12 and below it resolves as granted
  /// immediately.
  Future<void> registerFor(String sessionToken) async {
    if (sessionToken.isEmpty) return;
    try {
      final settings = await FirebaseMessaging.instance.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        debugPrint('[push] permission denied — in-app notifications still work');
        return;
      }

      final fcm = await FirebaseMessaging.instance.getToken();
      if (fcm == null || fcm.isEmpty) return;

      // Nothing changed: same user, same token, already registered.
      if (_token == fcm && _sessionToken == sessionToken) return;
      _token = fcm;
      _sessionToken = sessionToken;
      await _send(sessionToken, fcm);
      // Fire and forget: the banner gate is advisory and must not delay a login.
      _loadPrefs(sessionToken);

      // FCM rotates tokens without warning -- on a reinstall, a restore to a new
      // phone, or when Google decides to. A rotation the server never hears about is
      // indistinguishable from a working token until a send fails, so the refresh
      // stream is subscribed for the life of the process.
      _onRefresh?.cancel();
      _onRefresh = FirebaseMessaging.instance.onTokenRefresh.listen((t) {
        _token = t;
        final s = _sessionToken;
        if (s != null && t.isNotEmpty) _send(s, t);
      });
    } catch (e) {
      debugPrint('[push] register skipped: $e');
    }
  }

  Future<void> _send(String sessionToken, String fcm) async {
    try {
      await _api.registerDevice(
        sessionToken,
        fcmToken: fcm,
        platform: _platform(),
        label: _label(),
      );
    } catch (e) {
      // A failed registration is not a failed login. The user still gets every
      // in-app notification over the socket; only the tray is affected, and the next
      // app start retries.
      debugPrint('[push] device registration failed: $e');
    }
  }

  /// Revoke this device on logout, not every device: the same account on a second
  /// phone must keep receiving. `notification_service.revokeDevice` sends the token,
  /// and the route only clears the legacy `users.fcm_token` column when no token is
  /// given.
  Future<void> unregister(String sessionToken) async {
    final fcm = _token;
    _onRefresh?.cancel();
    _onRefresh = null;
    _sessionToken = null;
    if (fcm == null || sessionToken.isEmpty) return;
    try {
      await _api.revokeDevice(sessionToken, fcm);
    } catch (e) {
      debugPrint('[push] revoke failed: $e');
    }
  }

  static String? _platform() {
    if (kIsWeb) return 'web';
    try {
      if (Platform.isAndroid) return 'android';
      if (Platform.isIOS) return 'ios';
    } catch (_) {
      return null;
    }
    return null;
  }

  static String? _label() {
    if (kIsWeb) return 'Web';
    try {
      return Platform.operatingSystemVersion.split('(').first.trim();
    } catch (_) {
      return null;
    }
  }

  /// Only for a full teardown; the streams are otherwise process-lived.
  void dispose() {
    _onMessage?.cancel();
    _onOpened?.cancel();
    _onRefresh?.cancel();
  }
}
