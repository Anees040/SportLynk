import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../constants/colors.dart';
import '../../services/firebase_otp_service.dart';
import '../../widgets/custom_button.dart';

class OtpScreen extends StatefulWidget {
  const OtpScreen({super.key});

  @override
  State<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends State<OtpScreen> with SingleTickerProviderStateMixin {
  final List<TextEditingController> _controllers = List.generate(6, (_) => TextEditingController());
  final List<FocusNode> _focusNodes = List.generate(6, (_) => FocusNode());
  final _otpService = FirebaseOtpService();

  bool _isLoading = false;
  bool _isSending = true;
  int _countdown = 45;
  Timer? _timer;
  String _phone = '';
  late AnimationController _iconAnimCtrl;
  late Animation<double> _iconAnimation;

  @override
  void initState() {
    super.initState();
    _iconAnimCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));
    _iconAnimation = Tween<double>(begin: 0.9, end: 1.1).animate(
      CurvedAnimation(parent: _iconAnimCtrl, curve: Curves.easeInOut),
    );
    _iconAnimCtrl.repeat(reverse: true);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is String && args.isNotEmpty && _phone.isEmpty) {
      _phone = args;
      _sendOtp();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _iconAnimCtrl.dispose();
    for (final c in _controllers) {
      c.dispose();
    }
    for (final f in _focusNodes) {
      f.dispose();
    }
    super.dispose();
  }

  void _startCountdown() {
    _countdown = 45;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_countdown <= 0) {
        t.cancel();
      } else {
        setState(() => _countdown--);
      }
    });
  }

  Future<void> _sendOtp() async {
    setState(() => _isSending = true);
    await _otpService.sendOtp(
      phone: _phone,
      onCodeSent: (vid) {
        if (mounted) {
          setState(() => _isSending = false);
          _startCountdown();
          _focusNodes[0].requestFocus();
        }
      },
      onError: (err) {
        if (mounted) {
          setState(() => _isSending = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(err, style: GoogleFonts.poppins()),
              backgroundColor: AppColors.error,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      },
      onAutoVerified: (uid) {
        if (mounted) Navigator.pop(context, uid);
      },
    );
  }

  String _maskedPhone() {
    if (_phone.length < 7) return _phone;
    final e164 = _otpService.toE164(_phone);
    return '${e164.substring(0, 4)}-XXX-${e164.substring(e164.length - 4)}';
  }

  void _onDigitChanged(int index, String value) {
    if (value.length == 1 && index < 5) {
      _focusNodes[index + 1].requestFocus();
    }
    if (value.isEmpty && index > 0) {
      _focusNodes[index - 1].requestFocus();
    }
    final code = _controllers.map((c) => c.text).join();
    if (code.length == 6) {
      _verifyOtp();
    }
  }

  Future<void> _verifyOtp() async {
    final code = _controllers.map((c) => c.text).join();
    if (code.length != 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Enter all 6 digits', style: GoogleFonts.poppins()),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() => _isLoading = true);
    final uid = await _otpService.verifyOtp(code);
    if (!mounted) return;
    setState(() => _isLoading = false);

    if (uid != null) {
      Navigator.pop(context, uid);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Invalid or expired code', style: GoogleFonts.poppins()),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
      // Clear fields
      for (final c in _controllers) {
        c.clear();
      }
      _focusNodes[0].requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Verify Phone', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.white,
        elevation: 0,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Animated icon
              ScaleTransition(
                scale: _iconAnimation,
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: AppColors.accentLight,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.sms, size: 52, color: AppColors.accent),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Enter OTP',
                style: GoogleFonts.poppins(fontSize: 24, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
              ),
              const SizedBox(height: 8),
              Text(
                'Code sent to ${_maskedPhone()}',
                style: GoogleFonts.poppins(fontSize: 14, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 32),
              // OTP boxes
              if (_isSending)
                const CircularProgressIndicator(color: AppColors.accent)
              else
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(6, (i) {
                    return Container(
                      width: 48,
                      height: 56,
                      margin: EdgeInsets.only(left: i == 0 ? 0 : 8),
                      child: TextFormField(
                        controller: _controllers[i],
                        focusNode: _focusNodes[i],
                        textAlign: TextAlign.center,
                        keyboardType: TextInputType.number,
                        maxLength: 1,
                        onChanged: (v) => _onDigitChanged(i, v),
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        style: GoogleFonts.poppins(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                        decoration: InputDecoration(
                          counterText: '',
                          filled: true,
                          fillColor: AppColors.inputFill,
                          contentPadding: const EdgeInsets.symmetric(vertical: 14),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              const SizedBox(height: 32),
              CustomButton(
                text: 'Verify Code',
                isLoading: _isLoading,
                onPressed: _verifyOtp,
              ),
              const SizedBox(height: 16),
              // Countdown / resend
              if (_countdown > 0)
                Text(
                  'Resend code in 0:${_countdown.toString().padLeft(2, '0')}',
                  style: GoogleFonts.poppins(fontSize: 14, color: AppColors.textSecondary),
                )
              else
                TextButton(
                  onPressed: _sendOtp,
                  child: Text(
                    'Resend OTP',
                    style: GoogleFonts.poppins(fontSize: 14, color: AppColors.accent, fontWeight: FontWeight.w600),
                  ),
                ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  'Change Phone Number',
                  style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
