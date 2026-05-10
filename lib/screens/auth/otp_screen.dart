import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../constants/colors.dart';
import '../../services/firebase_otp_service.dart';
import '../../widgets/custom_button.dart';
import '../../utils/snackbar_util.dart';

class OtpScreen extends StatefulWidget {
  const OtpScreen({super.key});
  @override
  State<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends State<OtpScreen> {
  final FirebaseOtpService _otp = FirebaseOtpService();
  final List<TextEditingController> _ctrls =
      List.generate(6, (_) => TextEditingController());
  final List<FocusNode> _foci = List.generate(6, (_) => FocusNode());

  bool _loading = false;
  bool _sending = true;
  int _countdown = 60;
  Timer? _timer;
  String _phone = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is String && args.isNotEmpty && _phone.isEmpty) {
      _phone = args;
      _sendOtp();
      _startTimer();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final c in _ctrls) { c.dispose(); }
    for (final f in _foci) { f.dispose(); }
    super.dispose();
  }

  void _startTimer() {
    _countdown = 60;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_countdown <= 0) { t.cancel(); } else {
        if (mounted) setState(() => _countdown--);
      }
    });
  }

  Future<void> _sendOtp() async {
    setState(() => _sending = true);
    await _otp.sendOtp(
      phone: _phone,
      onCodeSent: (vid) {
        if (!mounted) return;
        setState(() => _sending = false);
        _foci[0].requestFocus();
      },
      onError: (e) {
        if (!mounted) return;
        setState(() => _sending = false);
        String userMessage;
        if (e.contains('billing-not-enabled')) {
          userMessage = 'SMS service not configured yet.\n'
              'For testing: add test numbers in Firebase Console:\n'
              'Authentication → Phone → Phone numbers for testing';
        } else if (e.contains('invalid-phone-number')) {
          userMessage = 'Invalid phone number format. Use 03XXXXXXXXX';
        } else if (e.contains('too-many-requests')) {
          userMessage = 'Too many attempts. Please wait 1 hour.';
        } else if (e.contains('network-request-failed')) {
          userMessage = 'No internet connection. Check WiFi/mobile data.';
        } else {
          userMessage = 'OTP failed: $e';
        }
        SnackbarUtil.showError(context, userMessage);
      },
      onAutoVerified: (uid) { if (mounted) Navigator.pop(context, uid); },
    );
  }

  Future<void> _verifyOtp() async {
    final code = _ctrls.map((c) => c.text).join();
    if (code.length != 6) {
      SnackbarUtil.showError(context, 'Enter all 6 digits');
      return;
    }
    setState(() => _loading = true);
    final uid = await _otp.verifyOtp(code);
    if (!mounted) return;
    setState(() => _loading = false);
    if (uid != null) {
      Navigator.pop(context, uid);
    } else {
      SnackbarUtil.showError(context, 'Invalid or expired code. Try again.');
      for (final c in _ctrls) { c.clear(); }
      _foci[0].requestFocus();
    }
  }

  String _maskedPhone() {
    if (_phone.length < 7) return _phone;
    return '+92-XXX-XXXX${_phone.substring(7)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Verify Phone', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
        backgroundColor: AppColors.primary, foregroundColor: AppColors.white, elevation: 0,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: const BoxDecoration(color: AppColors.accentLight, shape: BoxShape.circle),
              child: const Icon(Icons.sms_outlined, size: 52, color: AppColors.accent),
            ),
            const SizedBox(height: 24),
            Text('Enter OTP', style: GoogleFonts.poppins(fontSize: 24, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
            const SizedBox(height: 8),
            Text('Code sent to ${_maskedPhone()}', style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary)),
            const SizedBox(height: 36),
            if (_sending)
              Column(children: [
                const CircularProgressIndicator(color: AppColors.accent),
                const SizedBox(height: 16),
                Text('Sending verification code...', style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary)),
              ])
            else
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(6, (i) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  child: SizedBox(width: 48, height: 58, child: TextFormField(
                    controller: _ctrls[i], focusNode: _foci[i],
                    textAlign: TextAlign.center, keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(1)],
                    decoration: InputDecoration(
                      counterText: '', filled: true, fillColor: AppColors.inputFill,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.border)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.border)),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.accent, width: 2)),
                    ),
                    style: GoogleFonts.poppins(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                    onChanged: (v) {
                      if (v.isNotEmpty && i < 5) _foci[i + 1].requestFocus();
                      if (v.isNotEmpty && i == 5) _verifyOtp();
                      if (v.isEmpty && i > 0) _foci[i - 1].requestFocus();
                    },
                  )),
                )),
              ),
            const SizedBox(height: 32),
            if (!_sending) CustomButton(text: 'Verify Code', isLoading: _loading, onPressed: _loading ? null : _verifyOtp),
            const SizedBox(height: 20),
            if (_countdown > 0)
              Text('Resend code in 0:${_countdown.toString().padLeft(2, '0')}', style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary))
            else
              TextButton(
                onPressed: () { for (final c in _ctrls) { c.clear(); } _startTimer(); _sendOtp(); },
                child: Text('Resend OTP', style: GoogleFonts.poppins(fontSize: 14, color: AppColors.accent, fontWeight: FontWeight.w600)),
              ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Change Phone Number', style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary)),
            ),
          ]),
        ),
      ),
    );
  }
}
