import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'dart:io';
import '../../services/cloudinary_service.dart';
import '../../constants/colors.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/sport_text_field.dart';
import '../../widgets/password_strength_bar.dart';
import '../../widgets/custom_button.dart';
import '../../widgets/phone_field.dart';
import '../../utils/snackbar_util.dart';

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

  Future<void> _pickAvatar() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
    );
    if (picked != null) setState(() => _avatarFile = picked);
  }

  Widget _buildPickedImage(
    XFile file, {
    double? width,
    double? height,
    BoxFit fit = BoxFit.cover,
  }) {
    if (kIsWeb) {
      return Image.network(file.path, width: width, height: height, fit: fit);
    }
    return Image.file(File(file.path), width: width, height: height, fit: fit);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldPop = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(
              'Discard Registration?',
              style: GoogleFonts.poppins(fontWeight: FontWeight.bold),
            ),
            content: Text(
              'Any information you entered will be lost. Are you sure you want to go back?',
              style: GoogleFonts.poppins(),
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(
                  'Keep Editing',
                  style: GoogleFonts.poppins(
                    color: AppColors.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.error,
                  foregroundColor: Colors.white,
                  elevation: 0,
                ),
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(
                  'Discard',
                  style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        );
        if (shouldPop == true && context.mounted) {
          Navigator.pop(context, result);
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          title: Text(
            'Create Player Account',
            style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
          ),
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
                  // Avatar
                  Center(
                    child: GestureDetector(
                      onTap: _pickAvatar,
                      child: Stack(
                        children: [
                          CircleAvatar(
                            radius: 48,
                            backgroundColor: AppColors.accentLight,
                            child: _avatarFile != null
                                ? ClipOval(
                                    child: _buildPickedImage(
                                      _avatarFile!,
                                      width: 96,
                                      height: 96,
                                    ),
                                  )
                                : const Icon(
                                    Icons.person,
                                    size: 48,
                                    color: AppColors.accent,
                                  ),
                          ),
                          Positioned(
                            bottom: 0,
                            right: 0,
                            child: CircleAvatar(
                              radius: 16,
                              backgroundColor: AppColors.accent,
                              child: const Icon(
                                Icons.camera_alt,
                                size: 16,
                                color: AppColors.white,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Center(
                    child: Text(
                      'Add Photo (optional)',
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Player chip
                  Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.accentLight,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.sports_soccer,
                            color: AppColors.accent,
                            size: 16,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Player Account',
                            style: GoogleFonts.poppins(
                              fontSize: 13,
                              color: AppColors.accent,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Full Name
                  SportTextField(
                    label: 'Full Name *',
                    hint: 'Enter your full name',
                    prefixIcon: Icons.person_outline,
                    controller: _name,
                    validator: _validateName,
                  ),
                  const SizedBox(height: 16),

                  PhoneField(
                    controller: _phone,
                    isVerified: _phoneVerified,
                    onVerified: (uid) => setState(() {
                      _phoneVerified = true;
                      _firebaseUid = uid;
                    }),
                    onEdit: () => setState(() {
                      _phoneVerified = false;
                      _firebaseUid = null;
                      _phone.clear();
                    }),
                  ),
                  const SizedBox(height: 16),

                  // Email
                  SportTextField(
                    label: 'Email (optional)',
                    hint: 'email@example.com',
                    prefixIcon: Icons.mail_outline,
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    validator: _validateEmail,
                  ),
                  const SizedBox(height: 16),

                  // Password
                  SportTextField(
                    label: 'Password *',
                    hint: 'Min 8 characters',
                    prefixIcon: Icons.lock_outline,
                    controller: _pass,
                    obscure: _obscurePass,
                    suffix: IconButton(
                      icon: Icon(
                        _obscurePass ? Icons.visibility_off : Icons.visibility,
                        color: AppColors.textSecondary,
                        size: 20,
                      ),
                      onPressed: () =>
                          setState(() => _obscurePass = !_obscurePass),
                    ),
                    validator: _validatePassword,
                  ),
                  const SizedBox(height: 8),
                  PasswordStrengthBar(password: _passwordText),
                  const SizedBox(height: 16),

                  // Confirm Password with real-time match
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
                            _obscureConfirm
                                ? Icons.visibility_off
                                : Icons.visibility,
                            color: AppColors.textSecondary,
                            size: 20,
                          ),
                          onPressed: () => setState(
                            () => _obscureConfirm = !_obscureConfirm,
                          ),
                        ),
                      ],
                    ),
                    validator: _validateConfirmPassword,
                  ),
                  const SizedBox(height: 32),

                  // Create Account
                  Consumer<AuthProvider>(
                    builder: (context, auth, _) {
                      return CustomButton(
                        text: 'Create Account',
                        isLoading: auth.isLoading,
                        onPressed: () async {
                          if (!_formKey.currentState!.validate()) return;
                          if (!_phoneVerified) {
                            SnackbarUtil.showError(context, 'Please verify your phone number first');
                            return;
                          }

                          auth.setLoading(true);

                          String? avatarUrl;
                          if (_avatarFile != null) {
                            final cloudinary = CloudinaryService();
                            avatarUrl = await cloudinary.uploadImage(
                              _avatarFile!.path,
                              folder: 'avatars',
                            );
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
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                content: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const SizedBox(height: 8),
                                    const CircleAvatar(
                                      radius: 36,
                                      backgroundColor: AppColors.accentLight,
                                      child: Icon(
                                        Icons.check_circle,
                                        color: AppColors.accent,
                                        size: 40,
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                    Text(
                                      'Account Created!',
                                      style: GoogleFonts.poppins(
                                        fontSize: 20,
                                        fontWeight: FontWeight.bold,
                                        color: AppColors.textPrimary,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      'Welcome to SportLynk. Your player account is ready.',
                                      textAlign: TextAlign.center,
                                      style: GoogleFonts.poppins(
                                        fontSize: 13,
                                        color: AppColors.textSecondary,
                                      ),
                                    ),
                                    const SizedBox(height: 24),
                                    SizedBox(
                                      width: double.infinity,
                                      child: ElevatedButton(
                                        onPressed: () {
                                          Navigator.of(ctx).pop();
                                          Navigator.pushNamedAndRemoveUntil(
                                            context,
                                            '/login',
                                            (r) => false,
                                          );
                                        },
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: AppColors.accent,
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              28,
                                            ),
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 14,
                                          ),
                                        ),
                                        child: Text(
                                          'Start Booking',
                                          style: GoogleFonts.poppins(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          } else {
                            SnackbarUtil.showError(context, auth.errorMessage ?? 'Registration failed');
                          }
                        },
                      );
                    },
                  ),
                  const SizedBox(height: 20),

                  // Login link
                  Center(
                    child: RichText(
                      text: TextSpan(
                        style: GoogleFonts.poppins(fontSize: 13),
                        children: [
                          TextSpan(
                            text: 'Already have account? ',
                            style: TextStyle(color: AppColors.textSecondary),
                          ),
                          TextSpan(
                            text: 'Log In',
                            style: TextStyle(
                              color: AppColors.accent,
                              fontWeight: FontWeight.w700,
                            ),
                            recognizer: TapGestureRecognizer()
                              ..onTap = () =>
                                  Navigator.pushNamed(context, '/login'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
