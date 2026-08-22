import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../constants/colors.dart';

class SnackbarUtil {
  static void showSuccess(BuildContext context, String message) =>
      _show(context, message, Icons.check_circle, AppColors.success, 3);

  static void showError(BuildContext context, String message) =>
      _show(context, message, Icons.error_outline, AppColors.error, 4);

  /// Neutral, informational tone — used for "coming soon" / status notices that
  /// are neither a success nor a failure.
  static void showInfo(BuildContext context, String message) =>
      _show(context, message, Icons.info_outline, AppColors.primary, 3);

  static void _show(BuildContext context, String message, IconData icon,
      Color color, int seconds) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: GoogleFonts.poppins(color: Colors.white, fontSize: 13),
              ),
            ),
          ],
        ),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(16),
        duration: Duration(seconds: seconds),
      ),
    );
  }
}
