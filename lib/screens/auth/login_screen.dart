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
    final size = MediaQuery.of(context).size;
    
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC), // Very light cool gray background
      body: SingleChildScrollView(
        child: Stack(
          children: [
            // ─── Theme Color Header ───
            Container(
              height: size.height * 0.35,
              width: double.infinity,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [AppColors.primary, Color(0xFF166534)], // Dark to slightly lighter green
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
            ),
            
            // ─── Back Button ───
            Positioned(
              top: MediaQuery.of(context).padding.top + 10,
              left: 16,
              child: IconButton(
                icon: const Icon(Icons.arrow_back_ios, color: Colors.white, size: 22),
                onPressed: () => Navigator.pop(context),
              ),
            ),

            // ─── Main Content ───
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0),
                child: Column(
                  children: [
                    SizedBox(height: size.height * 0.08), // Spacing from top
                    
                    // ─── Welcome Text (over dark background) ───
                    Text(
                      'Welcome Back!',
                      style: GoogleFonts.poppins(
                        fontSize: 32,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Sign in to your account to continue',
                      style: GoogleFonts.poppins(
                        fontSize: 15,
                        color: Colors.white.withValues(alpha: 0.85),
                      ),
                    ),
                    const SizedBox(height: 40),

                    // ─── Card with Logo Overlap ───
                    Stack(
                      clipBehavior: Clip.none,
                      alignment: Alignment.topCenter,
                      children: [
                        // White Form Card
                        Container(
                          margin: const EdgeInsets.only(top: 50), // Make room for logo
                          padding: const EdgeInsets.fromLTRB(24, 70, 24, 32), // Top padding for logo
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(24),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.08),
                                blurRadius: 32,
                                offset: const Offset(0, 12),
                              ),
                            ],
                          ),
                          child: Form(
                            key: _formKey,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // Phone or Email
                                SportTextField(
                                  label: 'Phone or Email',
                                  hint: '03XXXXXXXXX or email',
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
                                const SizedBox(height: 20),

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
                                    style: TextButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(vertical: 12),
                                      minimumSize: Size.zero,
                                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    ),
                                    child: Text(
                                      'Forgot Password?',
                                      style: GoogleFonts.poppins(
                                        fontSize: 13,
                                        color: AppColors.accent,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 32),

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
                              ],
                            ),
                          ),
                        ),
                        
                        // Overlapping Large Logo
                        Positioned(
                          top: 0,
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.1),
                                  blurRadius: 20,
                                  spreadRadius: 2,
                                  offset: const Offset(0, 8),
                                ),
                              ],
                            ),
                            child: const CircleAvatar(
                              radius: 56, // Much larger logo
                              backgroundColor: Colors.white,
                              backgroundImage: AssetImage('assets/images/logo.png'),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 32),

                    // ─── Sign Up ───
                    RichText(
                      text: TextSpan(
                        style: GoogleFonts.poppins(fontSize: 14),
                        children: [
                          const TextSpan(text: "Don't have an account? ", style: TextStyle(color: AppColors.textSecondary)),
                          TextSpan(
                            text: 'Sign Up',
                            style: const TextStyle(color: AppColors.accent, fontWeight: FontWeight.bold),
                            recognizer: TapGestureRecognizer()..onTap = () => Navigator.pushNamed(context, '/welcome'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
