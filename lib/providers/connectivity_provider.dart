import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/realtime_service.dart';

/// Whether the app can currently reach the server, as one app-wide value.
///
/// WHY THE SOCKET IS THE SIGNAL
/// The question a screen actually needs answered is "can I reach the API", not
/// "does this phone have a network interface". A platform connectivity plugin
/// answers the second: it reports a healthy Wi-Fi association on a captive portal,
/// on a network that blocks the backend, and while Render's free tier is asleep —
/// all of which are offline as far as this app is concerned. `RealtimeService`
/// already holds a persistent Socket.IO connection to the same origin as the REST
/// API and already publishes its transitions, so it answers the right question and
/// costs no new dependency.
///
/// Its two limits are stated rather than hidden. The socket only connects once a
/// session is bound, so this reports offline before login — which is harmless,
/// because every pre-login screen needs the network anyway and says so through
/// `ApiClient`'s own message. And a socket can drop while HTTP still works, so
/// [markReachable] lets a successful request correct the state rather than leaving
/// a banner up over data that just loaded.
///
/// WHY THE WORDING IS NOT "No internet"
/// This cannot distinguish a phone in a lift from a server that is restarting, and
/// a banner that names the wrong cause sends the user to re-check a working
/// router. The copy says what is observable — the app is not connected and is
/// showing saved data — which is true in both cases.
class ConnectivityProvider extends ChangeNotifier {
  ConnectivityProvider({RealtimeService? realtime})
      : _realtime = realtime ?? RealtimeService() {
    _online = _realtime.isConnected;
    _sub = _realtime.connection.listen(_onTransition);
  }

  final RealtimeService _realtime;
  StreamSubscription<bool>? _sub;

  bool _online = false;

  /// True while the server is believed reachable. Screens read this to decide
  /// whether to show the offline strip, never to decide whether to attempt a
  /// request: an attempt that fails is how this value gets corrected.
  bool get isOnline => _online;

  bool get isOffline => !_online;

  void _onTransition(bool up) {
    if (up) {
      _set(true);
    } else {
      _set(false);
    }
  }

  /// Called by a screen whose request just succeeded.
  ///
  /// The socket and the REST transport can disagree — a dropped WebSocket on a
  /// network that still passes HTTP is common on mobile — and when they do, the
  /// request that actually returned data is the more trustworthy witness. Without
  /// this the user would read "showing saved data" underneath a list that had
  /// refreshed a moment earlier.
  void markReachable() => _set(true);

  /// Called by a screen whose request failed with a transport error.
  ///
  /// Deliberately not called for an HTTP error status: a 403 or a 422 proves the
  /// server answered, and treating a rejected request as an outage would blame the
  /// network for a bug.
  void markUnreachable() => _set(false);

  void _set(bool value) {
    if (_online == value) return;
    _online = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
