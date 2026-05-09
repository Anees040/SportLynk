import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

// NOTE: Firebase Phone Auth ONLY works on Android/iOS.
// Run with: flutter run (on emulator or real device)
// Do NOT use: flutter run -d chrome (web does not support phone OTP)
// For testing without real SMS: add test numbers in Firebase Console:
// Authentication → Phone → "Phone numbers for testing"
// Add: +923001234567 with code: 123456

/// Firebase OTP Service — uses real Firebase Phone Auth.
/// Works on both Web (signInWithPhoneNumber) and Mobile (verifyPhoneNumber).
class FirebaseOtpService {
  static final FirebaseOtpService _instance = FirebaseOtpService._internal();
  factory FirebaseOtpService() => _instance;
  FirebaseOtpService._internal();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  String? _verificationId;
  ConfirmationResult? _confirmationResult; // Web only

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

  /// Send OTP to Pakistani phone number.
  /// Phone must be in local format: 03001234567
  Future<void> sendOtp({
    required String phone,
    required Function(String verificationId) onCodeSent,
    required Function(String error) onError,
    required Function(String firebaseUid) onAutoVerified,
  }) async {
    final e164Phone = toE164(phone);

    try {
      if (kIsWeb) {
        // ── Web flow: signInWithPhoneNumber ──
        _confirmationResult = await _auth.signInWithPhoneNumber(e164Phone);
        onCodeSent('web_verification');
      } else {
        // ── Mobile flow: verifyPhoneNumber ──
        await _auth.verifyPhoneNumber(
          phoneNumber: e164Phone,
          verificationCompleted: (PhoneAuthCredential credential) async {
            // Android auto-verification
            try {
              final result = await _auth.signInWithCredential(credential);
              onAutoVerified(result.user?.uid ?? '');
            } catch (e) {
              onError('Auto-verification failed: $e');
            }
          },
          verificationFailed: (FirebaseAuthException e) {
            onError(e.message ?? 'Phone verification failed');
          },
          codeSent: (String verificationId, int? resendToken) {
            _verificationId = verificationId;
            onCodeSent(verificationId);
          },
          codeAutoRetrievalTimeout: (String verificationId) {
            _verificationId = verificationId;
          },
          timeout: const Duration(seconds: 60),
        );
      }
    } catch (e) {
      String errorMsg = e.toString();
      // Provide user-friendly error messages
      if (errorMsg.contains('too-many-requests')) {
        errorMsg = 'Too many attempts. Please try again later.';
      } else if (errorMsg.contains('invalid-phone-number')) {
        errorMsg = 'Invalid phone number format.';
      } else if (errorMsg.contains('quota-exceeded')) {
        errorMsg = 'SMS quota exceeded. Please try again later.';
      } else if (errorMsg.contains('network-request-failed')) {
        errorMsg = 'Network error. Check your internet connection.';
      }
      onError(errorMsg);
    }
  }

  /// Verify OTP entered by user.
  /// Returns Firebase UID on success, null on failure.
  Future<String?> verifyOtp(String smsCode) async {
    try {
      if (kIsWeb) {
        // Web: use ConfirmationResult
        if (_confirmationResult == null) return null;
        final result = await _confirmationResult!.confirm(smsCode);
        return result.user?.uid;
      } else {
        // Mobile: use verificationId + credential
        if (_verificationId == null) return null;
        final credential = PhoneAuthProvider.credential(
          verificationId: _verificationId!,
          smsCode: smsCode,
        );
        final result = await _auth.signInWithCredential(credential);
        return result.user?.uid;
      }
    } catch (e) {
      return null;
    }
  }
}
