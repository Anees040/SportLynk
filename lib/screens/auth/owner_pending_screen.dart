import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../constants/colors.dart';

class OwnerPendingScreen extends StatelessWidget {
  const OwnerPendingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: const BoxDecoration(
                      color: AppColors.accentLight,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.pending_actions,
                        size: 88, color: AppColors.accent),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Application Submitted!',
                    style: GoogleFonts.poppins(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    "Our team will review your documents within 24-48 hours.\nYou'll receive an SMS notification once approved.",
                    style: GoogleFonts.poppins(
                      fontSize: 14,
                      color: AppColors.textSecondary,
                      height: 1.5,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: AppColors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Column(
                      children: [
                        _statusRow(Icons.check_circle,
                            'Identity verification (CNIC)', true),
                        const SizedBox(height: 12),
                        _statusRow(Icons.check_circle,
                            'Ground details submitted', true),
                        const SizedBox(height: 12),
                        _statusRow(
                            Icons.check_circle, 'Photos received', true),
                        const SizedBox(height: 12),
                        _statusRow(
                            Icons.hourglass_top, 'Admin review', false),
                        const SizedBox(height: 12),
                        _statusRow(
                            Icons.lock_clock, 'Account activation', false),
                      ],
                    ),
                  ),
                  const SizedBox(height: 40),
                  TextButton(
                    onPressed: () => Navigator.pushNamedAndRemoveUntil(
                        context, '/welcome', (r) => false),
                    style: TextButton.styleFrom(
                        foregroundColor: AppColors.accent),
                    child: Text(
                      'Back to Home →',
                      style: GoogleFonts.poppins(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static Widget _statusRow(IconData icon, String text, bool done) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon,
              size: 20,
              color: done ? AppColors.accent : AppColors.disabled),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.poppins(
                fontSize: 13,
                color: done
                    ? AppColors.textPrimary
                    : AppColors.textSecondary,
                fontWeight: done ? FontWeight.w500 : FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
