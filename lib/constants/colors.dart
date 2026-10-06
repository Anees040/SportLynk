import 'package:flutter/material.dart';

class AppColors {
  AppColors._();

  // A friendly forest green (Tailwind green-800). White text on it clears WCAG AA
  // (~5.5:1). The previous 0xFF0A1F13 was so dark it read as black on headers and
  // primary buttons; this keeps the brand green legible as a large surface colour.
  static const Color primary = Color(0xFF166534);
  // The deep forest of the logo's own field. Sampled from the logo PNG's border
  // ring (the pixels that abut the splash background), whose mean is #0E3621; the
  // earlier #0F3723 was a shade lighter than the field it sat against. It is the
  // one startup surface: native splash, the Dart splash, the Get Started header
  // and the login header all sit on it, so the logo's baked-in square blends in
  // and the four greens the auth flow used to show read as one. The logo field is
  // a vignette rather than a flat colour, so a faint edge can remain at the
  // darkest (bottom) side; only a transparent-field logo removes it entirely.
  static const Color primaryDark = Color(0xFF0E3621);
  static const Color accent = Color(0xFF22C55E);
  static const Color accentLight = Color(0xFFDCFCE7);
  static const Color background = Color(0xFFF8FAFC);
  static const Color cardBg = Color(0xFFFFFFFF);
  static const Color inputFill = Color(0xFFF1F5F9);
  static const Color textPrimary = Color(0xFF111827);
  static const Color textSecondary = Color(0xFF6B7280);
  static const Color error = Color(0xFFDC2626);
  static const Color warning = Color(0xFFF59E0B);
  // Legible text/icon tone for use on a pale [warning]-tinted surface, where the
  // bright amber itself fails contrast.
  static const Color warningText = Color(0xFF92600A);
  static const Color disabled = Color(0xFFD1D5DB);
  static const Color border = Color(0xFFE5E7EB);
  static const Color divider = Color(0xFFE5E7EB);
  static const Color success = Color(0xFF16A34A);
  static const Color white = Color(0xFFFFFFFF);

  /// The tone for a sport the app does not sell as its own category — football and
  /// futsal read as [accent], cricket as [warning]. A third hue so a sport chip is
  /// never mistaken for one of those two.
  static const Color sportOther = Color(0xFF3B82F6);

  /// The scrim under text laid over a venue photo. A photo is arbitrary, so the
  /// badges and the name need their own ground rather than relying on the image
  /// being dark where the text happens to fall.
  static const Color photoScrim = Color(0x8A000000);

  // Team-chat surfaces. The thread sits on a warm neutral rather than the app's
  // near-white background: against white, the pale "mine" bubble lost its
  // right-aligned reading and looked centred. On this ground a light-green
  // "mine" and a white "theirs" both stand out — the WhatsApp convention users
  // expect. [chatPattern] is the faint doodle tint painted over [chatBackground]
  // by the default background preset.
  static const Color chatBackground = Color(0xFFEDE7DE);
  static const Color chatBubbleMine = Color(0xFFD7F4C4);
  static const Color chatBubbleOther = Color(0xFFFFFFFF);
  static const Color chatPattern = Color(0x0F0E3621);

  // Alternate chat-background presets (Issue 5). Each is a flat ground; a preset
  // may additionally paint a pattern over it, tinted with [chatPattern] (or
  // [chatPatternStrong] for the denser art styles, which need a little more
  // presence to read as design rather than dirt).
  static const Color chatBgMint = Color(0xFFE3F0E4);
  static const Color chatBgSlate = Color(0xFFE6E9EE);
  static const Color chatBgPlain = Color(0xFFF4F1EC);
  static const Color chatBgSand = Color(0xFFF3EADB);
  static const Color chatBgDusk = Color(0xFFE8E6F2);
  static const Color chatBgRose = Color(0xFFF6E9EA);
  static const Color chatBgTeal = Color(0xFFDEEDEC);
  static const Color chatBgGold = Color(0xFFF6EEDC);
  static const Color chatPatternStrong = Color(0x1A0E3621);

  /// The wash over a selected chat row. Translucent, so it reads over the pale
  /// "mine" bubble, the white "theirs" bubble and the patterned ground alike —
  /// a solid tint only showed up against one of the three. Deliberately stronger
  /// than [accentLight], which marks the row a tapped quote jumped to, so
  /// "selected" and "jumped to" are never mistaken for each other.
  static const Color chatSelection = Color(0x3D166534);
}
