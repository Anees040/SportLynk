import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../../constants/colors.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/sport_text_field.dart';
import '../../widgets/custom_button.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _idCtrl = TextEditingController();
  final _pwCtrl = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() { _idCtrl.dispose(); _pwCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SingleChildScrollView(
        child: Column(
          children: [
            // ─── Dark gradient header ───
            Container(
              width: double.infinity,
              padding: EdgeInsets.only(
                top: MediaQuery.of(context).padding.top + 8,
                bottom: 40,
              ),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF0A1F13), Color(0xFF166534)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.vertical(bottom: Radius.circular(32)),
              ),
              child: Column(children: [
                // Back button
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back, color: AppColors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
                const SizedBox(height: 8),
                // Logo
                Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: AppColors.accent.withValues(alpha: 0.2), blurRadius: 16, spreadRadius: 2)],
                  ),
                  child: CircleAvatar(
                    radius: 36,
                    backgroundColor: AppColors.white,
                    backgroundImage: const AssetImage('assets/images/logo.png'),
                  ),
                ),
                const SizedBox(height: 12),
                Text('Welcome Back', style: GoogleFonts.poppins(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.white)),
                const SizedBox(height: 4),
                Text('Sign in to continue', style: GoogleFonts.poppins(fontSize: 13, color: AppColors.white.withValues(alpha: 0.7))),
              ]),
            ),

            // ─── White card (overlaps header by 20px) ───
            Transform.translate(
              offset: const Offset(0, -20),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 20),
                padding: const EdgeInsets.fromLTRB(24, 28, 24, 28),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 24, offset: const Offset(0, 8)),
                  ],
                ),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Sign In', style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                      const SizedBox(height: 4),
                      Text('Enter your credentials', style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary)),
                      const SizedBox(height: 24),

                      // Phone or Email
                      SportTextField(
                        label: 'Phone or Email',
                        hint: '03XXXXXXXXX or email@domain.com',
                        prefixIcon: Icons.phone_android,
                        controller: _idCtrl,
                        keyboardType: TextInputType.emailAddress,
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) return 'Required';
                          final val = v.trim();
                          if (val.contains('@')) {
                            if (!RegExp(r'^[\w.]+@[\w]+\.\w+$').hasMatch(val)) return 'Invalid email';
                          } else {
                            if (!RegExp(r'^03[0-9]{9}$').hasMatch(val)) return 'Enter valid phone (03XXXXXXXXX)';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),

                      // Password
                      SportTextField(
                        label: 'Password',
                        hint: 'Your password',
                        prefixIcon: Icons.lock_outline,
                        controller: _pwCtrl,
                        obscure: _obscure,
                        suffix: IconButton(
                          icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility, color: const Color(0xFF64748B), size: 20),
                          onPressed: () => setState(() => _obscure = !_obscure),
                        ),
                        validator: (v) => v == null || v.isEmpty ? 'Required' : null,
                      ),

                      // Forgot Password
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => Navigator.pushNamed(context, '/forgot-password'),
                          child: Text('Forgot Password?', style: GoogleFonts.poppins(fontSize: 13, color: AppColors.accent, fontWeight: FontWeight.w500)),
                        ),
                      ),
                      const SizedBox(height: 12),

                      // Login button
                      Consumer<AuthProvider>(builder: (context, auth, _) {
                        return CustomButton(
                          text: 'Log In',
                          isLoading: auth.isLoading,
                          onPressed: () async {
                            if (!_formKey.currentState!.validate()) return;
                            final ok = await auth.login(_idCtrl.text.trim(), _pwCtrl.text);
                            if (!context.mounted) return;
                            if (!ok) {
                              if (auth.isPendingOwner) {
                                Navigator.pushNamedAndRemoveUntil(context, '/owner-pending', (r) => false);
                              } else {
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                  content: Text(auth.errorMessage ?? 'Login failed', style: GoogleFonts.poppins()),
                                  backgroundColor: AppColors.error, behavior: SnackBarBehavior.floating,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                ));
                              }
                              return;
                            }
                            final route = auth.currentUser?.role == 'owner' ? '/owner-home' : '/player-home';
                            Navigator.pushNamedAndRemoveUntil(context, route, (r) => false);
                          },
                        );
                      }),
                      const SizedBox(height: 24),

                      // Sign Up
                      Center(
                        child: RichText(text: TextSpan(style: GoogleFonts.poppins(fontSize: 13), children: [
                          TextSpan(text: "Don't have an account? ", style: TextStyle(color: AppColors.textSecondary)),
                          TextSpan(text: 'Sign Up', style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.w700),
                            recognizer: TapGestureRecognizer()..onTap = () => Navigator.pushNamed(context, '/welcome')),
                        ])),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
