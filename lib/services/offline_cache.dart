import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// One cached payload and the moment it was written.
///
/// The timestamp is the point of the whole class. A cached list rendered without
/// one is indistinguishable from live data, so a booking the owner cancelled an
/// hour ago would still read "Confirmed" with nothing to warn the user. Every
/// screen that draws from the cache is expected to surface [at] — directly, or by
/// showing the offline banner that explains why the data is not moving.
class CachedEntry {
  const CachedEntry(this.data, this.at);

  /// The decoded payload, exactly as it was handed to [OfflineCache.write] — a
  /// `List` or a `Map`, never the transport envelope around it.
  final Object? data;

  /// When this entry was written, in local time.
  final DateTime at;

  Duration get age => DateTime.now().difference(at);

  /// Convenience for the common case of a cached list of rows.
  List<Map<String, dynamic>> asRows() {
    final raw = data;
    if (raw is! List) return const [];
    return raw.whereType<Map>().map(Map<String, dynamic>.from).toList();
  }

  /// Convenience for the common case of a cached object.
  Map<String, dynamic>? asMap() {
    final raw = data;
    return raw is Map ? Map<String, dynamic>.from(raw) : null;
  }
}

/// A per-user, timestamped read-through cache for screens that would otherwise
/// have nothing to draw when the server is unreachable.
///
/// WHY THIS EXISTS
/// Every list in this app was server-first: it asked, and on failure it showed a
/// spinner that never resolved or an empty state that claimed the user owned
/// nothing. The second is the worse bug — a failed request presented as "No
/// upcoming bookings" is not a blank screen, it is wrong information. Caching the
/// last good response turns both into the behaviour a messaging app has had for a
/// decade: the data the user has already seen stays on screen, and only the parts
/// that genuinely need the network say so.
///
/// WHY IT IS KEYED BY USER
/// Two accounts share a phone during testing, and a booking list cached under a
/// bare key would be read back by whoever logs in next. The user id is part of
/// every key and [clearForUser] runs on logout, so one account's rows can never
/// surface under another's session. A null [userId] disables the cache entirely
/// rather than falling back to a shared key — before login there is no owner for
/// the data, so there is nothing legitimate to store.
///
/// WHY SharedPreferences AND NOT A DATABASE
/// `chat_controller` already caches a page of messages per channel this way and it
/// works; adding sqflite or Hive for a handful of small JSON documents would be a
/// new dependency for no capability this needs. The payloads here are one screen's
/// worth of rows, not a synchronised replica.
///
/// WHAT IT IS NOT
/// It is not an offline write path. A cached read is safe because the user has
/// already seen it; a queued *write* is only safe when it cannot fail on arrival.
/// That is true of a chat message and false of a booking, which competes for a
/// slot, moves money through escrow and is priced at the moment it is made. Writes
/// stay online and say so at the point of action.
class OfflineCache {
  OfflineCache._();

  /// Bumped when a stored shape changes incompatibly. An old prefix is simply
  /// never read again, so a format change degrades to a cache miss instead of a
  /// decode error on every screen.
  static const String _prefix = 'oc1';

  /// Set at login beside `ApiClient.authToken`, cleared on logout. Static for the
  /// same reason the token is: threading it through every screen would add a
  /// parameter to every call site to say something the session already knows.
  static String? userId;

  static String? _keyFor(String name) {
    final id = userId;
    if (id == null || id.isEmpty) return null;
    return '$_prefix:$id:$name';
  }

  /// The last good payload for [name], or null when absent, unreadable, or no user
  /// is bound.
  ///
  /// Never throws. A corrupt or shape-changed entry reads as a miss, because the
  /// cache is an optimisation and the network response is the source of truth —
  /// the one thing it must not do is take a screen down on its way past.
  static Future<CachedEntry?> read(String name) async {
    final key = _keyFor(name);
    if (key == null) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final at = DateTime.tryParse(decoded['at'] as String? ?? '');
      if (at == null) return null;
      return CachedEntry(decoded['data'], at.toLocal());
    } catch (_) {
      return null;
    }
  }

  /// Store [data] as the newest good payload for [name]. Silently does nothing
  /// when no user is bound or the payload will not encode.
  static Future<void> write(String name, Object? data) async {
    final key = _keyFor(name);
    if (key == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, jsonEncode({
        'at': DateTime.now().toIso8601String(),
        'data': data,
      }));
    } catch (e) {
      // A payload holding something jsonEncode cannot represent is a programming
      // error at the call site, not a runtime condition to recover from; it is
      // reported in debug and dropped in release rather than failing the load that
      // just succeeded.
      assert(false, 'OfflineCache.write($name) failed to encode: $e');
    }
  }

  /// Drop every entry belonging to the bound user. Called from logout, before the
  /// id is cleared, so the next account starts with an empty cache.
  static Future<void> clearForUser() async {
    final id = userId;
    if (id == null || id.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final mine = '$_prefix:$id:';
      for (final key in prefs.getKeys().where((k) => k.startsWith(mine)).toList()) {
        await prefs.remove(key);
      }
    } catch (_) {
      // Best effort. A key left behind is unreachable anyway once `userId` moves
      // on, and failing a logout over it would be the worse outcome.
    }
  }

  /// Names used across the app, declared here so a typo is a compile error and a
  /// reader can see what is cached without grepping for string literals.
  static const String playerHome = 'player_home';
  static const String myBookings = 'my_bookings';
  static const String myTeams = 'my_teams';
  static const String wallet = 'wallet';
  static const String venues = 'venues';
  static const String notifications = 'notifications';
  static const String chatInbox = 'chat_inbox';
  static const String playerProfile = 'player_profile';
  static const String ownerHome = 'owner_home';
  static const String ownerVenues = 'owner_venues';
  static const String ownerBookingRequests = 'owner_booking_requests';
}

/// How a cache age should be described to a user.
///
/// Kept beside the cache rather than in a screen so every surface words staleness
/// the same way; "Updated 5 min ago" in one place and "5m" in another reads as two
/// different features.
String describeCacheAge(DateTime at) {
  final d = DateTime.now().difference(at);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} ${d.inHours == 1 ? 'hour' : 'hours'} ago';
  return '${d.inDays} ${d.inDays == 1 ? 'day' : 'days'} ago';
}
