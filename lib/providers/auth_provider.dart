import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
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
    if (_token != null && _token!.isNotEmpty) {
      RealtimeService().ensureConnected(_token!);
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

  Future<bool> resetPassword(String phone, String newPassword, String firebaseUid) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final response = await _authService.forgotPasswordReset(
        phone: phone, newPassword: newPassword, firebaseUid: firebaseUid,
      );
      _isLoading = false;
      notifyListeners();
      return response['success'] == true;
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

    try {
      _token = await _authService.getToken();
      if (_token != null && _token!.isNotEmpty) {
        _currentUser = await _authService.getMe(_token!);
        if (_currentUser == null) {
          _token = null;
          await _authService.clearToken();
        }
      }
    } catch (e) {
      _token = null;
      _currentUser = null;
      await _authService.clearToken();
    }

    _bindSession();
    _isLoading = false;
    notifyListeners();
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
    // Revoke THIS phone's push token before the session token is thrown away --
    // `DELETE /notifications/devices` needs it to authenticate, and after this
    // method there is nothing left to send. Fire and forget: a logout must not wait
    // on the network, and the server also revokes on its own the first time FCM
    // reports the token dead.
    //
    // Why it matters that it happens at all: `user_devices.fcm_token` is UNIQUE on
    // the TOKEN, so the row MOVES to whoever registers it next. On a shared or
    // handed-over phone, a token left registered keeps delivering the previous
    // user's notifications until someone else logs in -- a privacy leak, not a
    // bookkeeping detail.
    final leaving = _token;
    if (leaving != null && leaving.isNotEmpty) PushService().unregister(leaving);
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
    notifyListeners();
  }
}
