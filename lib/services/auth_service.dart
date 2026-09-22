import 'package:shared_preferences/shared_preferences.dart';
import '../constants/api_constants.dart';
import '../models/user.dart';
import 'api_service.dart';

class AuthService {
  final ApiService _api = ApiService();

  static const String _tokenKey = 'jwt_token';

  Future<Map<String, dynamic>> registerPlayer({
    required String name,
    required String phone,
    required String password,
    String? email,
    required String firebaseUid,
    String? avatarUrl,
  }) async {
    final body = <String, dynamic>{
      'name': name,
      'phone': phone,
      'password': password,
      'firebaseUid': firebaseUid,
    };
    if (email != null && email.isNotEmpty) body['email'] = email;
    if (avatarUrl != null) body['avatarUrl'] = avatarUrl;
    return _api.post(ApiConstants.registerPlayer, body);
  }

  Future<Map<String, dynamic>> registerOwner(Map<String, dynamic> data) async {
    return _api.post(ApiConstants.registerOwner, data);
  }

  Future<Map<String, dynamic>> login({
    required String identifier,
    required String password,
  }) async {
    return _api.post(ApiConstants.login, {
      'identifier': identifier,
      'password': password,
    });
  }

  Future<Map<String, dynamic>> forgotPasswordSendOtp(String phone) async {
    return _api.post(ApiConstants.forgotPasswordSendOtp, {'phone': phone});
  }

  Future<Map<String, dynamic>> forgotPasswordReset({
    required String phone,
    required String newPassword,
    required String firebaseUid,
  }) async {
    return _api.post(ApiConstants.forgotPasswordReset, {
      'phone': phone,
      'newPassword': newPassword,
      'firebaseUid': firebaseUid,
    });
  }

  Future<void> saveToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
  }

  Future<String?> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_tokenKey);
  }

  Future<void> clearToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
  }

  Future<User?> getMe(String token) async {
    final response = await _api.get(ApiConstants.me, token: token);
    if (response['success'] == true && response['data'] != null) {
      final userData = response['data']['user'] as Map<String, dynamic>;
      return User.fromJson(userData);
    }
    return null;
  }

  /// A session refresh that distinguishes the two failures a bare [getMe] cannot:
  /// a real 401 (the token is expired or revoked — the session must end) from an
  /// unreachable server (offline or slow — the saved session should survive).
  ///
  /// Returns `{ user, expired }`: `user` is non-null only on a clean 200;
  /// `expired` is true only for an explicit 401. A network failure yields
  /// `{ user: null, expired: false }`, which the caller reads as "keep what we
  /// have" rather than "log out".
  Future<({User? user, bool expired})> refreshMe(String token) async {
    final response = await _api.get(ApiConstants.me, token: token);
    if (response['success'] == true && response['data'] != null) {
      return (
        user: User.fromJson(response['data']['user'] as Map<String, dynamic>),
        expired: false,
      );
    }
    return (user: null, expired: response['statusCode'] == 401);
  }
}
