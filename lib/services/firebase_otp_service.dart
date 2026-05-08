import 'dart:math';

/// Mock Firebase OTP Service for demo/development.
/// Replace with real Firebase implementation by:
/// 1. Configuring Firebase project (see RUN_GUIDE.md)
/// 2. Uncommenting the firebase_auth import and real implementation
/// 3. Setting _useMock = false
class FirebaseOtpService {
  static final FirebaseOtpService _instance = FirebaseOtpService._internal();
  factory FirebaseOtpService() => _instance;
  FirebaseOtpService._internal();

  // Set to false when real Firebase is configured
  static const bool _useMock = true;

  String? _verificationId;

  /// Send OTP to Pakistani phone number
  /// Phone must be in local format: 03001234567
  Future<void> sendOtp({
    required String phone,
    required Function(String verificationId) onCodeSent,
    required Function(String error) onError,
    required Function(String firebaseUid) onAutoVerified,
  }) async {
    if (_useMock) {
      // Mock: simulate a 2-second delay then send code
      await Future.delayed(const Duration(seconds: 2));
      _verificationId = 'mock_verification_${DateTime.now().millisecondsSinceEpoch}';
      onCodeSent(_verificationId!);
      return;
    }

    // Real Firebase implementation (uncomment when configured):
    // import 'package:firebase_auth/firebase_auth.dart';
    // final auth = FirebaseAuth.instance;
    // String e164Phone = _toE164(phone);
    // await auth.verifyPhoneNumber(
    //   phoneNumber: e164Phone,
    //   verificationCompleted: (PhoneAuthCredential credential) async {
    //     UserCredential result = await auth.signInWithCredential(credential);
    //     onAutoVerified(result.user?.uid ?? '');
    //   },
    //   verificationFailed: (FirebaseAuthException e) {
    //     onError(e.message ?? 'Verification failed');
    //   },
    //   codeSent: (String verificationId, int? resendToken) {
    //     _verificationId = verificationId;
    //     onCodeSent(verificationId);
    //   },
    //   codeAutoRetrievalTimeout: (String verificationId) {
    //     _verificationId = verificationId;
    //   },
    //   timeout: const Duration(seconds: 60),
    // );
  }

  /// Verify OTP entered by user
  /// Returns Firebase UID on success, null on failure
  Future<String?> verifyOtp(String smsCode) async {
    if (_useMock) {
      // Mock: accept any 6-digit code, return a mock UID
      await Future.delayed(const Duration(seconds: 1));
      if (smsCode.length == 6 && RegExp(r'^\d{6}$').hasMatch(smsCode)) {
        return 'mock_uid_${Random().nextInt(999999)}';
      }
      return null;
    }

    // Real Firebase implementation:
    // if (_verificationId == null) return null;
    // try {
    //   PhoneAuthCredential credential = PhoneAuthProvider.credential(
    //     verificationId: _verificationId!,
    //     smsCode: smsCode,
    //   );
    //   UserCredential result = await FirebaseAuth.instance.signInWithCredential(credential);
    //   return result.user?.uid;
    // } catch (e) {
    //   return null;
    // }
    return null;
  }

  /// Convert Pakistani 03001234567 to E.164 format +923001234567
  String toE164(String phone) {
    String cleaned = phone.replaceAll(RegExp(r'[\s\-()]'), '');
    if (cleaned.startsWith('0')) {
      return '+92${cleaned.substring(1)}';
    }
    if (cleaned.startsWith('92')) {
      return '+$cleaned';
    }
    return cleaned;
  }
}
