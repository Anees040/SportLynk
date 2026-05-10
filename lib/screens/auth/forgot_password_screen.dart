import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../../constants/colors.dart';
import '../../providers/auth_provider.dart';
import '../../services/auth_service.dart';
import '../../widgets/sport_text_field.dart';
import '../../widgets/password_strength_bar.dart';
import '../../widgets/custom_button.dart';
import '../../utils/snackbar_util.dart';

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});
  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  int _step = 0;
  final _formKey = GlobalKey<FormState>();
  final _phone = TextEditingController();
  final _newPass = TextEditingController();
  final _confirmPass = TextEditingController();
  bool _obscureNew = true, _obscureConfirm = true;
  String? _firebaseUid;
  bool _loading = false;
  String _pwText = '';

  @override
  void initState() {
    super.initState();
    _newPass.addListener(() => setState(() => _pwText = _newPass.text));
  }

  @override
  void dispose() {
    _phone.dispose();
    _newPass.dispose();
    _confirmPass.dispose();
    super.dispose();
  }

  void _snack(String msg, {Color bg = AppColors.error}) {
    if (bg == AppColors.error || bg == AppColors.warning) {
      SnackbarUtil.showError(context, msg);
    } else {
      SnackbarUtil.showSuccess(context, msg);
    }
  }

  // Step 0: Send OTP
  Widget _buildStep0() {
    return Column(children: [
      Container(
        padding: const EdgeInsets.all(20),
        decoration: const BoxDecoration(color: AppColors.accentLight, shape: BoxShape.circle),
        child: const Icon(Icons.lock_reset, size: 72, color: AppColors.accent),
      ),
      const SizedBox(height: 20),
      Text('Reset Password', style: GoogleFonts.poppins(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.textPrimary), textAlign: TextAlign.center),
      const SizedBox(height: 8),
      Text('Enter your registered phone number', style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary), textAlign: TextAlign.center),
      const SizedBox(height: 32),
      SportTextField(
        label: 'Phone Number',
        hint: '03XXXXXXXXX',
        prefixIcon: Icons.phone_android,
        controller: _phone,
        keyboardType: TextInputType.phone,
        validator: (v) => v == null || !RegExp(r'^03[0-9]{9}$').hasMatch(v.trim()) ? 'Enter valid phone (03XXXXXXXXX)' : null,
      ),
      const SizedBox(height: 24),
      CustomButton(
        text: 'Send OTP',
        isLoading: _loading,
        onPressed: () async {
          if (!_formKey.currentState!.validate()) return;
          setState(() => _loading = true);
          try {
            final authService = AuthService();
            final resp = await authService.forgotPasswordSendOtp(_phone.text.trim());
            if (!mounted) return;
            setState(() => _loading = false);
            if (resp['success'] != true) {
              _snack(resp['message'] ?? 'Phone not found');
              return;
            }
            final uid = await Navigator.pushNamed(context, '/otp', arguments: _phone.text.trim());
            if (uid != null && uid is String) {
              _firebaseUid = uid;
              setState(() => _step = 1);
            }
          } catch (e) {
            if (mounted) { setState(() => _loading = false); _snack('Network error'); }
          }
        },
      ),
    ]);
  }

  // Step 1: New password
  Widget _buildStep1() {
    return Column(children: [
      Container(
        padding: const EdgeInsets.all(20),
        decoration: const BoxDecoration(color: AppColors.accentLight, shape: BoxShape.circle),
        child: const Icon(Icons.lock_open, size: 72, color: AppColors.accent),
      ),
      const SizedBox(height: 20),
      Text('Create New Password', style: GoogleFonts.poppins(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.textPrimary), textAlign: TextAlign.center),
      const SizedBox(height: 32),
      SportTextField(
        label: 'New Password *',
        hint: 'Min 8 characters',
        prefixIcon: Icons.lock_outline,
        controller: _newPass,
        obscure: _obscureNew,
        suffix: IconButton(
          icon: Icon(_obscureNew ? Icons.visibility_off : Icons.visibility, size: 20, color: const Color(0xFF64748B)),
          onPressed: () => setState(() => _obscureNew = !_obscureNew),
        ),
        validator: (v) {
          if (v == null || v.length < 8) return 'Min 8 characters';
          if (!v.contains(RegExp(r'[A-Z]'))) return 'Add uppercase letter';
          if (!v.contains(RegExp(r'[0-9]'))) return 'Add a number';
          return null;
        },
      ),
      const SizedBox(height: 8),
      PasswordStrengthBar(password: _pwText),
      const SizedBox(height: 16),
      SportTextField(
        label: 'Confirm Password *',
        hint: 'Re-enter password',
        prefixIcon: Icons.lock_outline,
        controller: _confirmPass,
        obscure: _obscureConfirm,
        suffix: IconButton(
          icon: Icon(_obscureConfirm ? Icons.visibility_off : Icons.visibility, size: 20, color: const Color(0xFF64748B)),
          onPressed: () => setState(() => _obscureConfirm = !_obscureConfirm),
        ),
        validator: (v) => v != _newPass.text ? 'Passwords do not match' : null,
      ),
      const SizedBox(height: 32),
      Consumer<AuthProvider>(builder: (context, auth, _) {
        return CustomButton(
          text: 'Reset Password',
          isLoading: auth.isLoading,
          onPressed: () async {
            if (!_formKey.currentState!.validate()) return;
            final ok = await auth.resetPassword(_phone.text.trim(), _newPass.text, _firebaseUid!);
            if (!context.mounted) return;
            if (ok) {
              _snack('Password changed successfully!', bg: AppColors.accent);
              Navigator.pushNamedAndRemoveUntil(context, '/login', (r) => false);
            } else {
              _snack(auth.errorMessage ?? 'Reset failed');
            }
          },
        );
      }),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Forgot Password', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.white,
        elevation: 0,
      ),
      body: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(children: [
            const SizedBox(height: 40),
            _step == 0 ? _buildStep0() : _buildStep1(),
            const SizedBox(height: 40),
          ]),
        ),
        ),
      ),
    );
  }
}
