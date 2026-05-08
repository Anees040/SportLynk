import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../../constants/colors.dart';
import '../../services/auth_service.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/sport_text_field.dart';
import '../../widgets/password_strength_bar.dart';
import '../../widgets/custom_button.dart';

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});
  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  int _step = 0; // 0=phone, 1=new password
  final _phoneCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  final AuthService _authService = AuthService();
  bool _loading = false;
  bool _obscure1 = true, _obscure2 = true;
  String? _firebaseUid;
  String _pwText = '';

  @override
  void initState() {
    super.initState();
    _passCtrl.addListener(() => setState(() => _pwText = _passCtrl.text));
  }

  @override
  void dispose() { _phoneCtrl.dispose(); _passCtrl.dispose(); _confirmCtrl.dispose(); super.dispose(); }

  Future<void> _sendOtp() async {
    final phone = _phoneCtrl.text.trim();
    if (phone.isEmpty || !RegExp(r'^03\d{9}$').hasMatch(phone)) {
      _snack('Enter valid phone (03XXXXXXXXX)'); return;
    }
    setState(() => _loading = true);
    try {
      final auth = context.read<AuthProvider>();
      final ok = await auth.sendForgotPasswordOtp(phone);
      if (!mounted) return;
      if (ok) {
        final uid = await Navigator.pushNamed(context, '/otp', arguments: phone);
        if (uid != null && uid is String) {
          await _authService.verifyPhone(
            phone: phone,
            firebaseUid: uid,
            purpose: 'password_reset',
          );
          setState(() { _firebaseUid = uid; _step = 1; });
        }
      } else {
        _snack(auth.errorMessage ?? 'Failed');
      }
    } catch (e) {
      _snack('Connection error');
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _resetPassword() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      final auth = context.read<AuthProvider>();
      final ok = await auth.resetPassword(
        phone: _phoneCtrl.text.trim(),
        newPassword: _passCtrl.text,
        firebaseUid: _firebaseUid ?? '',
      );
      if (!mounted) return;
      if (ok) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Password changed!', style: GoogleFonts.poppins()),
          backgroundColor: AppColors.success, behavior: SnackBarBehavior.floating,
        ));
        Navigator.pop(context);
      } else {
        _snack(auth.errorMessage ?? 'Failed');
      }
    } catch (e) {
      _snack('Connection error');
    }
    if (mounted) setState(() => _loading = false);
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: GoogleFonts.poppins()), backgroundColor: AppColors.error,
      behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: Text('Forgot Password', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)), backgroundColor: AppColors.primary, foregroundColor: AppColors.white, elevation: 0),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: _step == 0 ? _buildPhoneStep() : _buildResetStep(),
        ),
      ),
    );
  }

  Widget _buildPhoneStep() {
    return Column(
      children: [
        Container(padding: const EdgeInsets.all(20), decoration: BoxDecoration(color: AppColors.accentLight, shape: BoxShape.circle), child: const Icon(Icons.lock_reset, size: 52, color: AppColors.accent)),
        const SizedBox(height: 24),
        Text('Reset Password', style: GoogleFonts.poppins(fontSize: 24, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
        const SizedBox(height: 8),
        Text('Enter your registered phone number', style: GoogleFonts.poppins(fontSize: 14, color: AppColors.textSecondary)),
        const SizedBox(height: 32),
        SportTextField(hint: 'Phone Number', prefixIcon: Icons.phone_android, controller: _phoneCtrl, keyboardType: TextInputType.phone),
        const SizedBox(height: 24),
        CustomButton(text: 'Send OTP', isLoading: _loading, onPressed: _sendOtp),
      ],
    );
  }

  Widget _buildResetStep() {
    return Form(
      key: _formKey,
      child: Column(
        children: [
          const Icon(Icons.check_circle, size: 52, color: AppColors.accent),
          const SizedBox(height: 16),
          Text('Phone Verified', style: GoogleFonts.poppins(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          Text('Enter your new password', style: GoogleFonts.poppins(fontSize: 14, color: AppColors.textSecondary)),
          const SizedBox(height: 32),
          SportTextField(hint: 'New Password', prefixIcon: Icons.lock_outline, controller: _passCtrl, obscure: _obscure1,
            validator: (v) { if (v == null || v.length < 8) return 'Min 8 characters'; return null; },
            suffix: IconButton(icon: Icon(_obscure1 ? Icons.visibility_off : Icons.visibility, size: 20, color: AppColors.textSecondary), onPressed: () => setState(() => _obscure1 = !_obscure1))),
          PasswordStrengthBar(password: _pwText),
          const SizedBox(height: 16),
          SportTextField(hint: 'Confirm Password', prefixIcon: Icons.lock_outline, controller: _confirmCtrl, obscure: _obscure2,
            validator: (v) { if (v != _passCtrl.text) return 'Passwords do not match'; return null; },
            suffix: IconButton(icon: Icon(_obscure2 ? Icons.visibility_off : Icons.visibility, size: 20, color: AppColors.textSecondary), onPressed: () => setState(() => _obscure2 = !_obscure2))),
          const SizedBox(height: 32),
          CustomButton(text: 'Reset Password', isLoading: _loading, onPressed: _resetPassword),
        ],
      ),
    );
  }
}
