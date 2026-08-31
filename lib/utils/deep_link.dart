import 'dart:convert';

import 'package:flutter/material.dart';

/// The one place a notification's `deepLink` becomes a screen.
///
/// WHY THE ROUTE IS NOT DECIDED HERE
/// Every link arrives from the server as `{route, args}`, computed by
/// `utils/notificationTypes.js`. This file navigates; it does not choose. That split
/// is what makes `check_notifications.js` able to assert -- against `lib/main.dart`,
/// at check time, in CI rather than on a user's phone -- that every route the
/// registry can emit actually exists. A client that mapped `type` to a route itself
/// would put that decision beyond the reach of any check on the server side, which
/// is precisely how a notification whose tap does nothing ships unnoticed.
///
/// WHY A NAVIGATOR KEY AND NOT A BuildContext
/// Three of the four entry points have no context to hand. `onMessageOpenedApp`
/// fires from a platform channel, `getInitialMessage` resolves before the first
/// frame, and the background isolate has no widget tree at all. A single global key
/// installed on `MaterialApp` is the only handle that is valid in all of them.
class DeepLink {
  DeepLink._();

  /// Installed by `SportLynkApp` on its `MaterialApp`.
  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  /// A link that arrived before there was anywhere to send it.
  ///
  /// The cold-start case is the whole reason this exists: a tray tap on a KILLED app
  /// launches the process, and `getInitialMessage()` resolves while `AuthProvider` is
  /// still reading the token out of storage. Pushing then lands on the splash screen
  /// and is thrown away by the first `pushNamedAndRemoveUntil` the auth flow does.
  /// So it is parked here and replayed by [replayPending] once a home screen is up.
  static Map<String, dynamic>? _pending;

  static bool get hasPending => _pending != null;

  /// Routes this app can be sent to by a notification.
  ///
  /// Kept as a set rather than trusted blindly because `deep_link` is a jsonb column
  /// written by whatever server version was live at the time. A row written months
  /// ago by a build whose route has since been renamed must degrade to "opens the
  /// notification list", not to a black screen with an unhandled-route exception --
  /// which is what `Navigator.pushNamed` does to an unknown name in release mode.
  static const Set<String> knownRoutes = {
    '/assistant',
    '/booking-detail',
    '/chat-thread',
    '/chats',
    '/match-center',
    '/notifications',
    '/owner-bookings',
    '/owner-verify-matches',
    '/team-roster',
    '/tournament-detail',
    '/wallet',
  };

  /// Normalise whatever shape the link arrived in.
  ///
  /// It comes three ways and they are not the same. The feed row and the socket frame
  /// both give a real `{route, args}` map. An FCM data block cannot: data payloads are
  /// string-to-string, so `pushService` sends `route` as a plain string and `args`
  /// JSON-encoded, and `PushService._linkOf` reassembles the pair before it gets here.
  /// Callers should not each have to know that, so this accepts a map, a JSON string,
  /// or a map whose `args` is itself still a JSON string.
  static Map<String, dynamic>? parse(dynamic link) {
    if (link == null) return null;
    Map<String, dynamic>? m;
    if (link is Map) {
      m = Map<String, dynamic>.from(link);
    } else if (link is String && link.trim().startsWith('{')) {
      try {
        final decoded = jsonDecode(link);
        if (decoded is Map) m = Map<String, dynamic>.from(decoded);
      } catch (_) {
        // A malformed data payload is not worth a crash on a notification tap.
        return null;
      }
    }
    if (m == null) return null;
    final route = m['route']?.toString();
    if (route == null || !route.startsWith('/')) return null;
    return {'route': route, 'args': _args(m['args'])};
  }

  /// `args` arrives as a real map from the feed and the socket, and as a JSON STRING
  /// from an FCM data block (see `pushService.strData`: data payloads are
  /// string-to-string, so the map is encoded on the way out). Anything else -- a
  /// missing key, a malformed string -- is an empty map, because a route that ignores
  /// its arguments must still open.
  static Map<String, dynamic> _args(dynamic raw) {
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is String && raw.trim().startsWith('{')) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {
        return <String, dynamic>{};
      }
    }
    return <String, dynamic>{};
  }

  /// Send the user there now, if there is a navigator to send them through.
  ///
  /// Returns false when the link could not be used, which the caller treats as "open
  /// the notification list instead". Silence is not an option: a tap that produces
  /// nothing at all is the single most common way a notification system is judged
  /// broken.
  static bool open(dynamic link) {
    final parsed = parse(link);
    if (parsed == null) return false;
    final route = parsed['route'] as String;
    final args = parsed['args'] as Map<String, dynamic>;
    final nav = navigatorKey.currentState;
    if (nav == null) {
      _pending = parsed;
      return true;
    }
    if (!knownRoutes.contains(route)) {
      nav.pushNamed('/notifications');
      return true;
    }
    // `arguments` is always a map, never null, even for a route that ignores it: the
    // route builders in main.dart cast it non-null, and a null there is a crash on a
    // screen the user reached by tapping a notification.
    nav.pushNamed(route, arguments: args);
    return true;
  }

  /// Hold a link until a home screen exists. Used by the cold-start path, where the
  /// tap happened before the app had a widget tree.
  static void park(dynamic link) {
    final parsed = parse(link);
    if (parsed != null) _pending = parsed;
  }

  /// Called from a home screen's first frame, after `AuthProvider` has resolved.
  ///
  /// The pending link is cleared BEFORE the push, not after. A route that throws
  /// while building would otherwise re-fire on the next home screen build and the app
  /// would be stuck bouncing off the same broken screen forever.
  static void replayPending() {
    final p = _pending;
    if (p == null) return;
    _pending = null;
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    final route = p['route'] as String;
    final args = p['args'] as Map<String, dynamic>;
    nav.pushNamed(
      knownRoutes.contains(route) ? route : '/notifications',
      arguments: args,
    );
  }

  /// Drop a parked link on logout: it was addressed to the previous session, and
  /// replaying it under a new account would either bounce off AuthGuard or -- worse
  /// -- open a screen keyed to somebody else's booking id.
  static void clear() => _pending = null;
}
