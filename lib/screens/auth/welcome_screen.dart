import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../constants/colors.dart';
import '../../widgets/custom_button.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark, // iOS
      ),
      child: Scaffold(
        backgroundColor: AppColors.primaryDark,
        // One gradient behind the whole screen. The white sheet draws over its
        // lower part, and the sheet's rounded top corners reveal a continuation
        // of the same gradient rather than a flat colour that fails to match it.
        // That mismatch was the dark-green slivers beside the curves, worst on
        // the right where the diagonal has already reached `primary`.
        body: Container(
          width: double.infinity,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.primaryDark, AppColors.primary],
            ),
          ),
          child: Column(
            children: [
              // Top 55 % — brand, transparent over the gradient.
              Expanded(
                flex: 55,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(height: 64 + topPadding),
                      // Logo — uses actual logo.png
                      Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.accent.withValues(alpha: 0.25),
                              blurRadius: 28,
                              spreadRadius: 6,
                            ),
                          ],
                        ),
                        child: CircleAvatar(
                          radius: 72,
                          backgroundColor: AppColors.white,
                          backgroundImage:
                              const AssetImage('assets/images/logo.png'),
                        ),
                      ),
                      const SizedBox(height: 20),
                      // Brand name
                      RichText(
                        text: TextSpan(
                          children: [
                            TextSpan(
                              text: 'Sport',
                              style: GoogleFonts.poppins(
                                fontSize: 36,
                                fontWeight: FontWeight.w700,
                                color: AppColors.white,
                              ),
                            ),
                            TextSpan(
                              text: 'Lynk',
                              style: GoogleFonts.poppins(
                                fontSize: 36,
                                fontWeight: FontWeight.w700,
                                color: AppColors.accent,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Book. Play. Compete.',
                        style: GoogleFonts.poppins(
                          fontSize: 15,
                          color: AppColors.white.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Bottom 45 % white sheet
              Expanded(
                flex: 45,
                child: Container(
                  width: double.infinity,
                  decoration: const BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(32),
                    ),
                  ),
                  child: ScrollConfiguration(
                    behavior: ScrollConfiguration.of(context)
                        .copyWith(scrollbars: false),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 32, 24, 48),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Get Started',
                            style: GoogleFonts.poppins(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            "Join Pakistan's #1 sports venue community",
                            style: GoogleFonts.poppins(
                              fontSize: 13,
                              color: AppColors.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 32),

                          // Player button
                          CustomButton(
                            text: '🏃  I am a Player',
                            onPressed: () => Navigator.pushNamed(
                                context, '/register/player'),
                          ),
                          const SizedBox(height: 14),

                          // Owner button (outlined)
                          CustomButton(
                            text: '🏟️  I own a Venue',
                            variant: 'outlined',
                            onPressed: () => Navigator.pushNamed(
                                context, '/register/owner'),
                          ),
                          const SizedBox(height: 28),
                          // Login link
                          Center(
                            child: RichText(
                              text: TextSpan(
                                style: GoogleFonts.poppins(fontSize: 12),
                                children: [
                                  TextSpan(
                                    text: 'Already have an account? ',
                                    style: TextStyle(
                                        color: AppColors.textSecondary),
                                  ),
                                  TextSpan(
                                    text: 'Log In',
                                    style: TextStyle(
                                      color: AppColors.accent,
                                      fontWeight: FontWeight.w700,
                                    ),
                                    recognizer: TapGestureRecognizer()
                                      ..onTap = () => Navigator.pushNamed(
                                          context, '/login'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
