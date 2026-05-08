import 'package:flutter/foundation.dart';
import '../models/user.dart';
import '../services/auth_service.dart';

class AuthProvider extends ChangeNotifier {
  final AuthService _authService = AuthService();

  User? _currentUser;
  String? _token;
  bool _isLoading = false;
  String? _errorMessage;
  bool _isPendingOwner = false;
  String? _ownerRejectionReason;

  User? get currentUser => _currentUser;
  String? get token => _token;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  bool get isAuthenticated => _currentUser != null && _token != null;
  String get userRole => _currentUser?.role ?? '';
  bool get isPendingOwner => _isPendingOwner;
  String? get ownerRejectionReason => _ownerRejectionReason;

  Future<bool> login(String identifier, String password) async {
    _isLoading = true;
    _errorMessage = null;
    _isPendingOwner = false;
    _ownerRejectionReason = null;
    notifyListeners();

    try {
      final response = await _authService.login(
        identifier: identifier,
        password: password,
      );

      if (response['success'] == true) {
        final data = response['data'] as Map<String, dynamic>;
        _token = data['token'] as String;
        _currentUser = User.fromJson(data['user'] as Map<String, dynamic>);
        await _authService.saveToken(_token!);
        _isPendingOwner = false;
        _ownerRejectionReason = null;
        _isLoading = false;
        notifyListeners();
        return true;
      } else {
        final status = response['status'] as String?;
        if (status == 'pending') {
          _isPendingOwner = true;
        }
        if (status == 'rejected') {
          _ownerRejectionReason = response['message'] as String?;
        }
        _errorMessage = response['message'] as String? ?? 'Login failed';
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
    _isPendingOwner = false;
    _ownerRejectionReason = null;
    notifyListeners();

    try {
      final response = await _authService.registerPlayer(
        name: name,
        phone: phone,
        password: password,
        email: email,
        firebaseUid: firebaseUid,
        avatarUrl: avatarUrl,
      );

      if (response['success'] == true) {
        final data = response['data'] as Map<String, dynamic>;
        _token = data['token'] as String;
        _currentUser = User.fromJson(data['user'] as Map<String, dynamic>);
        await _authService.saveToken(_token!);
        _isPendingOwner = false;
        _ownerRejectionReason = null;
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
    _isPendingOwner = false;
    _ownerRejectionReason = null;
    notifyListeners();

    try {
      final response = await _authService.registerOwner(data);
      if (response['success'] == true) {
        final data = response['data'] as Map<String, dynamic>;
        _token = data['token'] as String;
        _currentUser = User.fromJson(data['user'] as Map<String, dynamic>);
        await _authService.saveToken(_token!);
        _isPendingOwner = (data['status'] as String?) == 'pending';
        _ownerRejectionReason = null;
        _isLoading = false;
        notifyListeners();
        return true;
      }

      _errorMessage = response['message'] as String? ?? 'Registration failed';
      _isLoading = false;
      notifyListeners();
      return false;
    } catch (e) {
      _errorMessage = e.toString();
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<bool> sendForgotPasswordOtp(String phone) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final response = await _authService.forgotPasswordSendOtp(phone);
      if (response['success'] == true) {
        _isLoading = false;
        notifyListeners();
        return true;
      }
      _errorMessage = response['message'] as String? ?? 'Failed to send OTP';
      _isLoading = false;
      notifyListeners();
      return false;
    } catch (e) {
      _errorMessage = e.toString();
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<bool> resetPassword({
    required String phone,
    required String newPassword,
    required String firebaseUid,
  }) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final response = await _authService.forgotPasswordReset(
        phone: phone,
        newPassword: newPassword,
        firebaseUid: firebaseUid,
      );
      if (response['success'] == true) {
        _isLoading = false;
        notifyListeners();
        return true;
      }
      _errorMessage = response['message'] as String? ?? 'Failed to reset password';
      _isLoading = false;
      notifyListeners();
      return false;
    } catch (e) {
      _errorMessage = e.toString();
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<void> loadUser() async {
    _isLoading = true;
    _errorMessage = null;
    _isPendingOwner = false;
    _ownerRejectionReason = null;
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
    }

    _isLoading = false;
    notifyListeners();
  }

  void logout() {
    _currentUser = null;
    _token = null;
    _errorMessage = null;
    _isPendingOwner = false;
    _ownerRejectionReason = null;
    _authService.clearToken();
    notifyListeners();
  }
}
