import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'dart:io';
import '../../constants/app_config.dart';
import '../../services/cloudinary_service.dart';
import '../../constants/colors.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/sport_text_field.dart';
import '../../widgets/password_strength_bar.dart';
import '../../widgets/custom_button.dart';

class PlayerRegisterScreen extends StatefulWidget {
  const PlayerRegisterScreen({super.key});
  @override
  State<PlayerRegisterScreen> createState() => _PlayerRegisterScreenState();
}

class _PlayerRegisterScreenState extends State<PlayerRegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _pass = TextEditingController();
  final _confirmPass = TextEditingController();

  bool _obscurePass = true;
  bool _obscureConfirm = true;
  bool _phoneVerified = false;
  String? _firebaseUid;
  XFile? _avatarFile;
  String _passwordText = '';

  @override
  void initState() {
    super.initState();
    _pass.addListener(() => setState(() => _passwordText = _pass.text));
    _confirmPass.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _email.dispose();
    _pass.dispose();
    _confirmPass.dispose();
    super.dispose();
  }

  String? _validateName(String? v) {
    if (v == null || v.trim().isEmpty) return 'Name is required';
    if (v.trim().length < 3) return 'Name must be at least 3 characters';
    if (v.trim().length > 50) return 'Name too long';
    if (!RegExp(r'^[a-zA-Z\s]+$').hasMatch(v.trim())) {
      return 'Name can only contain letters and spaces';
    }
    return null;
  }

  String? _validatePhone(String? v) {
    if (v == null || v.isEmpty) return 'Phone required';
    if (!RegExp(r'^03[0-9]{9}$').hasMatch(v)) {
      return 'Enter valid Pakistani phone (03XXXXXXXXX)';
    }
    return null;
  }

  String? _validateEmail(String? v) {
    if (v == null || v.trim().isEmpty) return null;
    if (!RegExp(r'^[\w.]+@[\w]+\.\w+$').hasMatch(v.trim())) {
      return 'Invalid email format';
    }
    return null;
  }

  String? _validatePassword(String? v) {
    if (v == null || v.isEmpty) return 'Password required';
    if (v.length < 8) return 'Min 8 characters';
    if (!v.contains(RegExp(r'[A-Z]'))) return 'Add uppercase letter';
    if (!v.contains(RegExp(r'[0-9]'))) return 'Add a number';
    return null;
  }

  String? _validateConfirmPassword(String? v) {
    if (v == null || v.isEmpty) return 'Please confirm password';
    if (v != _pass.text) return 'Passwords do not match';
    return null;
  }

  Future<void> _triggerOtp() async {
    if (AppConfig.devMode) {
      setState(() {
        _phoneVerified = true;
        _firebaseUid = AppConfig.devFirebaseUid;
      });
      return;
    }
    final err = _validatePhone(_phone.text);
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(err, style: GoogleFonts.poppins()),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
      return;
    }
    final result =
        await Navigator.pushNamed(context, '/otp', arguments: _phone.text);
    if (result != null && result is String) {
      setState(() {
        _phoneVerified = true;
        _firebaseUid = result;
      });
    }
  }

  Future<void> _pickAvatar() async {
    final picked =
        await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 80);
    if (picked != null) setState(() => _avatarFile = picked);
  }

  Widget _buildPickedImage(XFile file,
      {double? width, double? height, BoxFit fit = BoxFit.cover}) {
    if (kIsWeb) {
      return Image.network(file.path, width: width, height: height, fit: fit);
    }
    return Image.file(File(file.path), width: width, height: height, fit: fit);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Create Player Account',
            style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.white,
        centerTitle: true,
        elevation: 0,
      ),
      body: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ─── Avatar ───
              Center(
                child: GestureDetector(
                  onTap: _pickAvatar,
                  child: Stack(children: [
                    CircleAvatar(
                      radius: 48,
                      backgroundColor: AppColors.accentLight,
                      child: _avatarFile != null
                          ? ClipOval(
                              child: _buildPickedImage(_avatarFile!,
                                  width: 96, height: 96))
                          : const Icon(Icons.person,
                              size: 48, color: AppColors.accent),
                    ),
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: CircleAvatar(
                        radius: 16,
                        backgroundColor: AppColors.accent,
                        child: const Icon(Icons.camera_alt,
                            size: 16, color: AppColors.white),
                      ),
                    ),
                  ]),
                ),
              ),
              const SizedBox(height: 6),
              Center(
                  child: Text('Add Photo (optional)',
                      style: GoogleFonts.poppins(
                          fontSize: 12, color: AppColors.textSecondary))),
              const SizedBox(height: 20),

              // ─── Player chip ───
              Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                      color: AppColors.accentLight,
                      borderRadius: BorderRadius.circular(20)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.sports_soccer,
                        color: AppColors.accent, size: 16),
                    const SizedBox(width: 6),
                    Text('Player Account',
                        style: GoogleFonts.poppins(
                            fontSize: 13,
                            color: AppColors.accent,
                            fontWeight: FontWeight.w700)),
                  ]),
                ),
              ),
              const SizedBox(height: 24),

              // ─── Full Name ───
              SportTextField(
                  label: 'Full Name *',
                  hint: 'Enter your full name',
                  prefixIcon: Icons.person_outline,
                  controller: _name,
                  validator: _validateName),
              const SizedBox(height: 16),

              // ─── Phone + Verify ───
              Text('Phone Number *',
                  style: GoogleFonts.poppins(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary)),
              const SizedBox(height: 6),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: TextFormField(
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    enabled: !_phoneVerified,
                    validator: _validatePhone,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(11),
                    ],
                    style: GoogleFonts.poppins(
                        fontSize: 14, color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      hintText: '03XXXXXXXXX',
                      hintStyle: GoogleFonts.poppins(
                          fontSize: 14, color: const Color(0xFF94A3B8)),
                      prefixIcon: const Icon(Icons.phone_android,
                          color: Color(0xFF64748B), size: 20),
                      filled: true,
                      fillColor: _phoneVerified
                          ? const Color(0xFFE2E8F0)
                          : Colors.white,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 16),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(
                              color: Color(0xFFCBD5E1), width: 1.2)),
                      enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(
                              color: Color(0xFFCBD5E1), width: 1.2)),
                      focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(
                              color: AppColors.accent, width: 1.5)),
                      errorBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(
                              color: AppColors.error, width: 1.5)),
                      disabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none),
                      errorStyle: GoogleFonts.poppins(
                          fontSize: 12, color: AppColors.error),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (!_phoneVerified)
                  SizedBox(
                    height: 56,
                    child: ElevatedButton(
                      onPressed: _triggerOtp,
                      style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          foregroundColor: AppColors.white,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                          elevation: 0,
                          padding:
                              const EdgeInsets.symmetric(horizontal: 16)),
                      child: Text('Verify',
                          style: GoogleFonts.poppins(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                    ),
                  )
                else
                  Row(children: [
                    Container(padding: const EdgeInsets.all(8), 
                      decoration: BoxDecoration(color:AppColors.accentLight, borderRadius:BorderRadius.circular(10)),
                      child: Row(children: [
                        const Icon(Icons.check_circle, color:AppColors.accent, size:18),
                        const SizedBox(width:4),
                        Text('Verified', style:GoogleFonts.poppins(
                          color:AppColors.accent, fontSize:12, fontWeight:FontWeight.w600)),
                      ])),
                    const SizedBox(width:4),
                    GestureDetector(
                      onTap: () => setState(() {
                        _phoneVerified = false;
                        _firebaseUid = null;
                        _phone.clear();
                      }),
                      child: Text('Edit', style:GoogleFonts.poppins(
                        color:AppColors.textSecondary, fontSize:12,
                        decoration:TextDecoration.underline)),
                    ),
                  ]),
              ]),
              const SizedBox(height: 16),

              // ─── Email ───
              SportTextField(
                  label: 'Email (optional)',
                  hint: 'email@example.com',
                  prefixIcon: Icons.mail_outline,
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  validator: _validateEmail),
              const SizedBox(height: 16),

              // ─── Password ───
              SportTextField(
                label: 'Password *',
                hint: 'Min 8 characters',
                prefixIcon: Icons.lock_outline,
                controller: _pass,
                obscure: _obscurePass,
                suffix: IconButton(
                    icon: Icon(
                        _obscurePass
                            ? Icons.visibility_off
                            : Icons.visibility,
                        color: AppColors.textSecondary,
                        size: 20),
                    onPressed: () =>
                        setState(() => _obscurePass = !_obscurePass)),
                validator: _validatePassword,
              ),
              const SizedBox(height: 8),
              PasswordStrengthBar(password: _passwordText),
              const SizedBox(height: 16),

              // ─── Confirm Password with real-time match ───
              SportTextField(
                label: 'Confirm Password *',
                hint: 'Re-enter password',
                prefixIcon: Icons.lock_outline,
                controller: _confirmPass,
                obscure: _obscureConfirm,
                suffix: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_confirmPass.text.isNotEmpty)
                      Icon(
                        _confirmPass.text == _pass.text
                            ? Icons.check_circle
                            : Icons.cancel,
                        color: _confirmPass.text == _pass.text
                            ? const Color(0xFF22C55E)
                            : const Color(0xFFDC2626),
                        size: 20,
                      ),
                    IconButton(
                      icon: Icon(
                        _obscureConfirm ? Icons.visibility_off : Icons.visibility,
                        color: AppColors.textSecondary,
                        size: 20,
                      ),
                      onPressed: () => setState(() => _obscureConfirm = !_obscureConfirm),
                    ),
                  ],
                ),
                validator: _validateConfirmPassword,
              ),
              const SizedBox(height: 32),

              // ─── Create Account ───
              Consumer<AuthProvider>(builder: (context, auth, _) {
                return CustomButton(
                  text: 'Create Account',
                  isLoading: auth.isLoading,
                  onPressed: () async {
                          if (!_formKey.currentState!.validate()) return;
                          if (!_phoneVerified) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text('Please verify your phone number first',
                                  style: GoogleFonts.poppins()),
                              backgroundColor: AppColors.warning,
                              behavior: SnackBarBehavior.floating,
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                            ));
                            return;
                          }

                          auth.setLoading(true);

                          String? avatarUrl;
                          if (_avatarFile != null) {
                            final cloudinary = CloudinaryService();
                            avatarUrl = await cloudinary.uploadImage(_avatarFile!.path, folder: 'avatars');
                          }

                          final ok = await auth.registerPlayer(
                            name: _name.text.trim(),
                            phone: _phone.text.trim(),
                            password: _pass.text,
                            email: _email.text.trim().isEmpty
                                ? null
                                : _email.text.trim(),
                            firebaseUid: _firebaseUid!,
                            avatarUrl: avatarUrl,
                          );
                          if (!context.mounted) return;
                          if (ok) {
                            // Show success dialog
                            await showDialog(
                              context: context,
                              barrierDismissible: false,
                              builder: (ctx) => AlertDialog(
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                content: Column(mainAxisSize: MainAxisSize.min, children: [
                                  const SizedBox(height: 8),
                                  const CircleAvatar(
                                    radius: 36,
                                    backgroundColor: AppColors.accentLight,
                                    child: Icon(Icons.check_circle, color: AppColors.accent, size: 40),
                                  ),
                                  const SizedBox(height: 16),
                                  Text('Account Created!',
                                    style: GoogleFonts.poppins(
                                      fontSize: 20, fontWeight: FontWeight.bold,
                                      color: AppColors.textPrimary)),
                                  const SizedBox(height: 8),
                                  Text('Welcome to SportLynk. Your player account is ready.',
                                    textAlign: TextAlign.center,
                                    style: GoogleFonts.poppins(
                                      fontSize: 13, color: AppColors.textSecondary)),
                                  const SizedBox(height: 24),
                                  SizedBox(width: double.infinity,
                                    child: ElevatedButton(
                                      onPressed: () {
                                        Navigator.of(ctx).pop();
                                        Navigator.pushNamedAndRemoveUntil(
                                          context, '/login', (r) => false);
                                      },
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: AppColors.accent,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(28)),
                                        padding: const EdgeInsets.symmetric(vertical: 14)),
                                      child: Text('Start Booking',
                                        style: GoogleFonts.poppins(
                                          color: Colors.white, fontWeight: FontWeight.w600)),
                                    )),
                                ]),
                              ),
                            );
                          } else {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(
                                  auth.errorMessage ?? 'Registration failed',
                                  style: GoogleFonts.poppins()),
                              backgroundColor: AppColors.error,
                              behavior: SnackBarBehavior.floating,
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                            ));
                          }
                        },
                );
              }),
              const SizedBox(height: 20),

              // ─── Login link ───
              Center(
                child: RichText(
                  text: TextSpan(
                      style: GoogleFonts.poppins(fontSize: 13),
                      children: [
                        TextSpan(
                            text: 'Already have account? ',
                            style:
                                TextStyle(color: AppColors.textSecondary)),
                        TextSpan(
                          text: 'Log In',
                          style: TextStyle(
                              color: AppColors.accent,
                              fontWeight: FontWeight.w700),
                          recognizer: TapGestureRecognizer()
                            ..onTap =
                                () => Navigator.pushNamed(context, '/login'),
                        ),
                      ]),
                ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
        ),
      ),
    );
  }
}
