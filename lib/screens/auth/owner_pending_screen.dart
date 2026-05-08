import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../constants/colors.dart';

class OwnerPendingScreen extends StatefulWidget {
  const OwnerPendingScreen({super.key});
  @override
  State<OwnerPendingScreen> createState() => _OwnerPendingScreenState();
}

class _OwnerPendingScreenState extends State<OwnerPendingScreen> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 2));
    _anim = Tween<double>(begin: 0.0, end: 1.0).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
    _ctrl.repeat(reverse: true);
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                RotationTransition(
                  turns: _anim,
                  child: Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(color: AppColors.accentLight, shape: BoxShape.circle),
                    child: const Icon(Icons.pending_actions, size: 72, color: AppColors.accent),
                  ),
                ),
                const SizedBox(height: 24),
                Text('Application Submitted!', style: GoogleFonts.poppins(fontSize: 24, fontWeight: FontWeight.w700, color: AppColors.textPrimary), textAlign: TextAlign.center),
                const SizedBox(height: 12),
                Text("Our team will review your documents within 24-48 hours.\nYou'll receive an SMS notification once approved.", style: GoogleFonts.poppins(fontSize: 14, color: AppColors.textSecondary, height: 1.5), textAlign: TextAlign.center),
                const SizedBox(height: 32),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.accentLight)),
                  child: Column(children: [
                    _statusRow(Icons.check_circle, 'Identity verification (CNIC)', true),
                    const SizedBox(height: 12),
                    _statusRow(Icons.check_circle, 'Ground details submitted', true),
                    const SizedBox(height: 12),
                    _statusRow(Icons.check_circle, 'Photos received', true),
                    const SizedBox(height: 12),
                    _statusRow(Icons.hourglass_top, 'Admin review (in progress)', false),
                    const SizedBox(height: 12),
                    _statusRow(Icons.hourglass_top, 'Account activation', false),
                  ]),
                ),
                const SizedBox(height: 40),
                TextButton(
                  onPressed: () => Navigator.pushNamedAndRemoveUntil(context, '/welcome', (r) => false),
                  child: Text('Back to Home', style: GoogleFonts.poppins(fontSize: 15, color: AppColors.accent, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _statusRow(IconData icon, String text, bool done) {
    return Row(children: [
      Icon(icon, size: 20, color: done ? AppColors.accent : AppColors.warning),
      const SizedBox(width: 12),
      Expanded(child: Text(text, style: GoogleFonts.poppins(fontSize: 13, color: done ? AppColors.textPrimary : AppColors.textSecondary, fontWeight: done ? FontWeight.w500 : FontWeight.w400))),
    ]);
  }
}
