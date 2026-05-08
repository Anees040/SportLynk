import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import '../../constants/colors.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/sport_text_field.dart';
import '../../widgets/phone_field.dart';
import '../../widgets/password_strength_bar.dart';
import '../../widgets/custom_button.dart';

class PlayerRegisterScreen extends StatefulWidget {
  const PlayerRegisterScreen({super.key});

  @override
  State<PlayerRegisterScreen> createState() => _PlayerRegisterScreenState();
}

class _PlayerRegisterScreenState extends State<PlayerRegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmPasswordCtrl = TextEditingController();

  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  bool _phoneVerified = false;
  String? _firebaseUid;
  XFile? _avatarFile;
  String _passwordText = '';

  @override
  void initState() {
    super.initState();
    _passwordCtrl.addListener(() {
      setState(() => _passwordText = _passwordCtrl.text);
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmPasswordCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final picker = ImagePicker();
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Select Photo', style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 16),
              ListTile(
                leading: const Icon(Icons.camera_alt, color: AppColors.accent),
                title: Text('Camera', style: GoogleFonts.poppins()),
                onTap: () => Navigator.pop(ctx, ImageSource.camera),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library, color: AppColors.accent),
                title: Text('Gallery', style: GoogleFonts.poppins()),
                onTap: () => Navigator.pop(ctx, ImageSource.gallery),
              ),
            ],
          ),
        ),
      ),
    );
    if (source == null) return;
    final picked = await picker.pickImage(source: source, maxWidth: 512, maxHeight: 512, imageQuality: 80);
    if (picked != null) {
      setState(() => _avatarFile = picked);
    }
  }

  String? _validateName(String? v) {
    if (v == null || v.trim().isEmpty) return 'Name is required';
    if (v.trim().length < 3) return 'Name must be at least 3 characters';
    if (v.trim().length > 50) return 'Name must be under 50 characters';
    if (!RegExp(r'^[a-zA-Z\s]+$').hasMatch(v.trim())) return 'Name can only contain letters and spaces';
    return null;
  }

  String? _validateEmail(String? v) {
    if (v == null || v.trim().isEmpty) return null;
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(v.trim())) return 'Invalid email format';
    return null;
  }

  String? _validatePassword(String? v) {
    if (v == null || v.isEmpty) return 'Password is required';
    if (v.length < 8) return 'Min 8 characters';
    if (!v.contains(RegExp(r'[A-Z]'))) return 'Must contain uppercase letter';
    if (!v.contains(RegExp(r'[a-z]'))) return 'Must contain lowercase letter';
    if (!v.contains(RegExp(r'[0-9]'))) return 'Must contain a number';
    if (!v.contains(RegExp(r'[!@#$%^&*(),.?":{}|<>]'))) return 'Must contain special character';
    return null;
  }

  String? _validateConfirmPassword(String? v) {
    if (v == null || v.isEmpty) return 'Please confirm password';
    if (v != _passwordCtrl.text) return 'Passwords do not match';
    return null;
  }

  Future<void> _handleRegister() async {
    if (!_formKey.currentState!.validate()) return;

    if (!_phoneVerified || _firebaseUid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Please verify your phone number first', style: GoogleFonts.poppins()),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
      return;
    }

    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final success = await authProvider.registerPlayer(
      name: _nameCtrl.text.trim(),
      phone: _phoneCtrl.text.trim(),
      password: _passwordCtrl.text,
      email: _emailCtrl.text.trim().isNotEmpty ? _emailCtrl.text.trim() : null,
      firebaseUid: _firebaseUid!,
      avatarUrl: _avatarFile?.path,
    );

    if (!mounted) return;

    if (success) {
      Navigator.pushNamedAndRemoveUntil(context, '/player-home', (r) => false);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(authProvider.errorMessage ?? 'Registration failed', style: GoogleFonts.poppins()),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Create Account', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.white,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Avatar
              Center(
                child: GestureDetector(
                  onTap: _pickAvatar,
                  child: Column(
                    children: [
                      Stack(
                        children: [
                          CircleAvatar(
                            radius: 48,
                            backgroundColor: AppColors.accentLight,
                            backgroundImage: _avatarFile != null ? FileImage(File(_avatarFile!.path)) : null,
                            child: _avatarFile == null
                                ? const Icon(Icons.person, size: 48, color: AppColors.accent)
                                : null,
                          ),
                          Positioned(
                            bottom: 0,
                            right: 0,
                            child: CircleAvatar(
                              radius: 16,
                              backgroundColor: AppColors.accent,
                              child: const Icon(Icons.camera_alt, size: 16, color: AppColors.white),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Add Photo (optional)',
                        style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              // Player chip
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.accentLight,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.sports_soccer, size: 16, color: AppColors.accent),
                      const SizedBox(width: 6),
                      Text('Player Account', style: GoogleFonts.poppins(fontSize: 13, color: AppColors.accent, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              SportTextField(
                hint: 'Full Name *',
                prefixIcon: Icons.person_outline,
                controller: _nameCtrl,
                validator: _validateName,
              ),
              const SizedBox(height: 16),
              PhoneField(
                controller: _phoneCtrl,
                isVerified: _phoneVerified,
                onVerified: (uid) {
                  setState(() {
                    _phoneVerified = true;
                    _firebaseUid = uid;
                  });
                },
              ),
              const SizedBox(height: 16),
              SportTextField(
                hint: 'Email (optional)',
                prefixIcon: Icons.mail_outline,
                controller: _emailCtrl,
                keyboardType: TextInputType.emailAddress,
                validator: _validateEmail,
              ),
              const SizedBox(height: 16),
              SportTextField(
                hint: 'Password *',
                prefixIcon: Icons.lock_outline,
                controller: _passwordCtrl,
                obscure: _obscurePassword,
                validator: _validatePassword,
                suffix: IconButton(
                  icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility, color: AppColors.textSecondary, size: 20),
                  onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
              PasswordStrengthBar(password: _passwordText),
              const SizedBox(height: 16),
              SportTextField(
                hint: 'Confirm Password *',
                prefixIcon: Icons.lock_outline,
                controller: _confirmPasswordCtrl,
                obscure: _obscureConfirm,
                validator: _validateConfirmPassword,
                suffix: IconButton(
                  icon: Icon(_obscureConfirm ? Icons.visibility_off : Icons.visibility, color: AppColors.textSecondary, size: 20),
                  onPressed: () => setState(() => _obscureConfirm = !_obscureConfirm),
                ),
              ),
              const SizedBox(height: 32),
              Consumer<AuthProvider>(
                builder: (context, auth, _) {
                  return Tooltip(
                    message: _phoneVerified ? '' : 'Verify phone first',
                    child: CustomButton(
                      text: 'Create Account',
                      isLoading: auth.isLoading,
                      onPressed: _phoneVerified ? _handleRegister : null,
                    ),
                  );
                },
              ),
              const SizedBox(height: 16),
              Center(
                child: TextButton(
                  onPressed: () => Navigator.pushNamed(context, '/login'),
                  child: RichText(
                    text: TextSpan(
                      style: GoogleFonts.poppins(fontSize: 14),
                      children: [
                        TextSpan(text: 'Already have account? ', style: TextStyle(color: AppColors.textSecondary)),
                        TextSpan(text: 'Login', style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
