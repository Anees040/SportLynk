import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/offline_cache.dart';
import '../services/realtime_service.dart';
import '../services/push_service.dart';

class AuthProvider extends ChangeNotifier {
  final AuthService _authService = AuthService();

  User? _currentUser;
  String? _token;
  bool _isLoading = false;
  String? _errorMessage;
  bool _isPendingOwner = false;
  String? _ownerRejectionReason;

  User? get currentUser => _currentUser;
  User? get user => _currentUser;
  String? get token => _token;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  bool get isAuthenticated => _currentUser != null && _token != null;
  String get userRole => _currentUser?.role ?? '';
  bool get isPendingOwner => _isPendingOwner;
  String? get ownerRejectionReason => _ownerRejectionReason;

  /// Bind the just-established session to the two singletons that outlive any
  /// one screen: the REST client (so calls carry the JWT without threading it)
  /// and the realtime socket (so team + chat events start flowing immediately,
  /// even before a chat screen is opened). Safe to call with a null/empty token.
  void _bindSession() {
    ApiClient.authToken = _token;
    // The offline cache is keyed by user, so the owner has to be bound before any
    // screen reads or writes one. Binding it here rather than in each screen is
    // what guarantees a cached list can never be read back under another account.
    OfflineCache.userId = _currentUser?.id;
    if (_token != null && _token!.isNotEmpty) {
      RealtimeService().ensureConnected(_token!);
    }
  }

  /// Where the last signed-in user's full profile is kept between launches.
  ///
  /// Distinct from the JWT, which carries only enough to route (id, role) and, on
  /// this backend, no usable name — which is why the app opened to "Welcome
  /// Player" and waited on a slow server for the real one. The profile saved here
  /// is restored in [loadUser] so the name and avatar are on screen from the first
  /// frame, online or offline, and the background refresh only updates them.
  static const String _userCacheKey = 'cached_user_v1';

  /// Persist the full profile, or clear it when passed null. Best effort: a missed
  /// write only costs a slower next open, never a failed sign-in.
  Future<void> _cacheUser(User? u) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (u == null) {
        await prefs.remove(_userCacheKey);
      } else {
        await prefs.setString(_userCacheKey, jsonEncode(u.toJson()));
      }
    } catch (_) {
      // A profile that will not round-trip is a programming error at the model,
      // not a runtime condition to fail a login over.
    }
  }

  /// The profile saved by the last session, or null when absent or unreadable. A
  /// corrupt entry reads as a miss so a bad cache can never block startup.
  Future<User?> _restoreCachedUser() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_userCacheKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return User.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }

  void setLoading(bool val) {
    _isLoading = val;
    notifyListeners();
  }

  Future<bool> login(String identifier, String password) async {
    _isLoading = true;
    _errorMessage = null;
    _isPendingOwner = false;
    notifyListeners();

    try {
      final response = await _authService.login(identifier: identifier, password: password);

      if (response['success'] == true) {
        final data = response['data'] as Map<String, dynamic>;
        _token = data['token'] as String;
        _currentUser = User.fromJson(data['user'] as Map<String, dynamic>);
        await _authService.saveToken(_token!);
        await _cacheUser(_currentUser);
        _bindSession();
        _isLoading = false;
        notifyListeners();
        return true;
      } else {
        _errorMessage = response['message'] as String? ?? 'Login failed';
        if (response['status'] == 'pending') {
          _isPendingOwner = true;
        }
        if (response['status'] == 'rejected') {
          _ownerRejectionReason = _errorMessage;
        }
        _isLoading = false;
        notifyListeners();
        return false;
      }
    } catch (e) {
      _errorMessage = e.toString();
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<bool> registerPlayer({
    required String name,
    required String phone,
    required String password,
    String? email,
    required String firebaseUid,
    String? avatarUrl,
  }) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final response = await _authService.registerPlayer(
        name: name, phone: phone, password: password,
        email: email, firebaseUid: firebaseUid, avatarUrl: avatarUrl,
      );

      if (response['success'] == true) {
        final data = response['data'] as Map<String, dynamic>;
        _token = data['token'] as String;
        _currentUser = User.fromJson(data['user'] as Map<String, dynamic>);
        await _authService.saveToken(_token!);
        await _cacheUser(_currentUser);
        _bindSession();
        _isLoading = false;
        notifyListeners();
        return true;
      } else {
        _errorMessage = response['message'] as String? ?? 'Registration failed';
        _isLoading = false;
        notifyListeners();
        return false;
      }
    } catch (e) {
      _errorMessage = e.toString();
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<bool> registerOwner(Map<String, dynamic> data) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final response = await _authService.registerOwner(data);

      if (response['success'] == true) {
        _isPendingOwner = true;
        if (response['data'] != null) {
          final d = response['data'] as Map<String, dynamic>;
          if (d['token'] != null) {
            _token = d['token'] as String;
            await _authService.saveToken(_token!);
            _bindSession();
          }
          if (d['user'] != null) {
            _currentUser = User.fromJson(d['user'] as Map<String, dynamic>);
            await _cacheUser(_currentUser);
          }
        }
        _isLoading = false;
        notifyListeners();
        return true;
      } else {
        _errorMessage = response['message'] as String? ?? 'Registration failed';
        _isLoading = false;
        notifyListeners();
        return false;
      }
    } catch (e) {
      _errorMessage = e.toString();
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<bool> resetPassword(String phone, String code, String newPassword) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final response = await _authService.forgotPasswordReset(
        phone: phone, code: code, newPassword: newPassword,
      );
      final ok = response['success'] == true;
      // Surface the server's reason on failure, the way login does. Without this an
      // expired code or a password the server rejected is dropped and the screen can
      // only show a generic 'Reset failed'.
      if (!ok) {
        _errorMessage = response['message'] as String? ?? 'Reset failed';
      }
      _isLoading = false;
      notifyListeners();
      return ok;
    } catch (e) {
      _errorMessage = e.toString();
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<void> loadUser() async {
    _isLoading = true;
    notifyListeners();

    _token = await _authService.getToken();
    if (_token == null || _token!.isEmpty) {
      _token = null;
      _currentUser = null;
      _isLoading = false;
      notifyListeners();
      return;
    }

    // Prefer the full profile saved from the last session: it carries the real
    // name and avatar, which the token's payload does not, so the app opens
    // showing who the user is instead of "Welcome Player" waiting on a slow or
    // sleeping server. The token's minimal identity is the fallback for a first
    // launch with nothing cached yet.
    _currentUser = await _restoreCachedUser() ?? _userFromToken(_token!);

    if (_currentUser != null) {
      // Everything the wrapper needs to route is in hand. Bind the session and
      // leave the splash now, then refresh the full profile without holding the
      // first frame: a cold, slow, or unreachable server used to keep the user on
      // the splash for the whole request timeout, which is the "it takes ten
      // seconds to open" symptom this avoids.
      _bindSession();
      _isLoading = false;
      notifyListeners();
      unawaited(_refreshProfile());
      return;
    }

    // The token would not decode, so there is nothing trustworthy to show without
    // the network: wait for the refresh to establish identity (or fail).
    final result = await _authService.refreshMe(_token!);
    if (result.expired || result.user == null) {
      _token = null;
      _currentUser = null;
      await _authService.clearToken();
      await _cacheUser(null);
    } else {
      _currentUser = result.user;
      await _cacheUser(_currentUser);
    }

    _bindSession();
    _isLoading = false;
    notifyListeners();
  }

  /// Refreshes the full profile after the app has already left the splash on the
  /// identity decoded from the token. A refresh distinguishes an expired token
  /// (log out) from an unreachable server (stay logged in on the cached identity):
  /// only an explicit 401 ends the session; offline or slow keeps the user in,
  /// which is what a phone with no signal expects.
  Future<void> _refreshProfile() async {
    final token = _token;
    if (token == null) return;
    final result = await _authService.refreshMe(token);
    if (result.expired) {
      _token = null;
      _currentUser = null;
      await _authService.clearToken();
      // An expired token ends the session as surely as a logout, so the cached
      // screens and the cached identity go with it rather than waiting for whoever
      // logs in next.
      await OfflineCache.clearForUser();
      OfflineCache.userId = null;
      await _cacheUser(null);
      ApiClient.authToken = null;
      RealtimeService().disconnect();
    } else if (result.user != null) {
      _currentUser = result.user;
      // The authority on the profile has answered; refresh the saved copy so the
      // next launch opens on a name or avatar changed on another device.
      await _cacheUser(_currentUser);
    }
    notifyListeners();
  }

  /// The minimal identity carried inside the JWT payload, or null if it cannot be
  /// decoded. Enough to route to the correct home screen before any network call.
  User? _userFromToken(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return null;
      final payload = json.decode(
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
      return User(
        id: payload['id'].toString(),
        name: payload['name'] ?? 'Player',
        role: payload['role'] ?? '',
        phone: payload['phone'],
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> tryAutoLogin() async {
    _isLoading = true;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    final savedToken = prefs.getString('jwt_token');
    if (savedToken == null || savedToken.isEmpty) {
      _isLoading = false;
      notifyListeners();
      return;
    }

    try {
      // Try to get full user data from API first
      _token = savedToken;
      _currentUser = await _authService.getMe(savedToken);
      if (_currentUser == null) {
        _token = null;
        await _authService.clearToken();
      }
    } catch (_) {
      // Fallback: decode JWT for minimal user info
      try {
        final parts = savedToken.split('.');
        if (parts.length == 3) {
          final payload = json.decode(
            utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
          _token = savedToken;
          _currentUser = User(
            id: payload['id'].toString(),
            name: payload['name'] ?? 'Player',
            role: payload['role'] ?? '',
            phone: payload['phone'],
          );
        }
      } catch (_) {
        _token = null;
        _currentUser = null;
        await _authService.clearToken();
      }
    }

    _bindSession();
    _isLoading = false;
    notifyListeners();
  }

  void logout() {
    // Revoke this phone's push token before the session token is thrown away --
    // `DELETE /notifications/devices` needs it to authenticate, and after this
    // method there is nothing left to send. Fire and forget: a logout must not wait
    // on the network, and the server also revokes on its own the first time FCM
    // reports the token dead.
    //
    // Why it matters that it happens at all: `user_devices.fcm_token` is UNIQUE on
    // the TOKEN, so the row moves to whoever registers it next. On a shared or
    // handed-over phone, a token left registered keeps delivering the previous
    // user's notifications until someone else logs in -- a privacy leak, not a
    // bookkeeping detail.
    final leaving = _token;
    if (leaving != null && leaving.isNotEmpty) PushService().unregister(leaving);
    // Drop this account's cached screens before the owner id is cleared.
    // `clearForUser` captures the id synchronously, so the assignment below cannot
    // race it. Fire and forget for the same reason the push revoke is: a logout
    // must not wait on disk any more than it waits on the network.
    unawaited(OfflineCache.clearForUser());
    OfflineCache.userId = null;
    unawaited(_cacheUser(null));
    _currentUser = null;
    _token = null;
    _errorMessage = null;
    _isPendingOwner = false;
    _ownerRejectionReason = null;
    _authService.clearToken();
    ApiClient.authToken = null;
    RealtimeService().disconnect();
    notifyListeners();
  }
  void updateLocalUser(Map<String, dynamic> data) {
    if (_currentUser == null) return;
    _currentUser = _currentUser!.copyWith(
      name: data['name'],
      email: data['email'],
      avatarUrl: data['avatarUrl'] ?? data['avatar_url'],
    );
    // Keep the saved copy in step with an in-app edit, so a changed name or avatar
    // is what the next launch opens on rather than the pre-edit profile.
    unawaited(_cacheUser(_currentUser));
    notifyListeners();
  }
}
