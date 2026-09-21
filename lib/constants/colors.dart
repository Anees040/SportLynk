import 'package:flutter/material.dart';

class AppColors {
  AppColors._();

  // A friendly forest green (Tailwind green-800). White text on it clears WCAG AA
  // (~5.5:1). The previous 0xFF0A1F13 was so dark it read as black on headers and
  // primary buttons; this keeps the brand green legible as a large surface colour.
  static const Color primary = Color(0xFF166534);
  // The deep forest of the logo's own field (#0F3723). It is the one startup
  // surface: native splash, the Dart splash, the Get Started header and the login
  // header all sit on it, so the logo's baked-in square blends in without a seam
  // and the four greens the auth flow used to show read as one.
  static const Color primaryDark = Color(0xFF0F3723);
  static const Color accent = Color(0xFF22C55E);
  static const Color accentLight = Color(0xFFDCFCE7);
  static const Color background = Color(0xFFF8FAFC);
  static const Color cardBg = Color(0xFFFFFFFF);
  static const Color inputFill = Color(0xFFF1F5F9);
  static const Color textPrimary = Color(0xFF111827);
  static const Color textSecondary = Color(0xFF6B7280);
  static const Color error = Color(0xFFDC2626);
  static const Color warning = Color(0xFFF59E0B);
  static const Color disabled = Color(0xFFD1D5DB);
  static const Color border = Color(0xFFE5E7EB);
  static const Color divider = Color(0xFFE5E7EB);
  static const Color success = Color(0xFF16A34A);
  static const Color white = Color(0xFFFFFFFF);
}
