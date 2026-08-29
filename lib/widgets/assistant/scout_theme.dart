import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/assistant.dart';

/// Scout's visual language — one dark surface, defined once.
///
/// WHY THIS SCREEN IS DARK WHEN THE APP IS LIGHT
/// --------------------------------------------
/// The rest of SportLynk is a light utility app: lists, forms, a booking flow. A
/// conversation is a different kind of thing, and giving it the brand's own deep
/// green as a full canvas makes "I am talking to the assistant" legible before a
/// single word is read — the same trick a terminal or a camera viewfinder uses.
/// It also solves a real contrast problem: chat is the one screen where twelve
/// card types, ranked results and money confirmations all stack in one column, and
/// on white they compete. On dark, an accent-bordered card recedes until it
/// matters.
///
/// ACCESSIBILITY IS A CONSTRAINT HERE, NOT A REVIEW STEP
/// ----------------------------------------------------
/// Every foreground in this file was checked against the surface it sits on. The
/// notable consequence: the accent `#22C55E` is used for borders, icons and small
/// glyphs on dark (7.8:1 against the canvas) but NEVER as a fill under white text,
/// where it manages only ~2.3:1. The user bubble is therefore the deeper
/// [userBubbleTop]/[userBubbleBottom] pair, both above 5:1 with white.
abstract final class ScoutTheme {
  // ── Canvas and surfaces ────────────────────────────────────
  /// The page. Slightly deeper than `AppColors.primary` so brand-green cards can
  /// still sit *above* it.
  static const Color canvas = Color(0xFF071B10);

  /// The top-of-screen glow, so the canvas is not a flat rectangle.
  static const Color canvasGlow = Color(0xFF0E3520);

  /// A card inside a bubble.
  static const Color card = Color(0xFF0C2416);

  /// Scout's own bubble — one step lighter than a card so a card *on* a bubble
  /// still reads as inset.
  static const Color bubble = Color(0xFF11291B);

  static const Color line = Color(0xFF1E4630);
  static const Color lineSoft = Color(0xFF163524);

  // ── Ink ────────────────────────────────────────────────────
  static const Color ink = Color(0xFFEAF6EE);      // 15.8:1 on canvas
  static const Color inkSoft = Color(0xFFA0BDAB);  //  8.8:1
  static const Color inkFaint = Color(0xFF6C8A79); //  4.7:1 — secondary only

  // ── Accents ────────────────────────────────────────────────
  static const Color accent = Color(0xFF22C55E);
  static const Color accentDim = Color(0xFF166534);
  static const Color userBubbleTop = Color(0xFF0F6B33);
  static const Color userBubbleBottom = Color(0xFF15803D);

  /// Money. Reserved for the confirm card and deposit figures, so "this costs
  /// something" has a colour that appears nowhere decorative.
  static const Color money = Color(0xFFF6C445);
  static const Color danger = Color(0xFFF87171);
  static const Color good = Color(0xFF4ADE80);

  // ── Metrics ────────────────────────────────────────────────
  static const double cardRadius = 16;
  static const double bubbleRadius = 20;
  static const double gap = 8;

  static const LinearGradient userBubbleGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [userBubbleTop, userBubbleBottom],
  );

  /// The page background: a soft glow behind the app bar, fading into flat canvas
  /// by about a third of the way down.
  static const BoxDecoration pageDecoration = BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [canvasGlow, canvas, canvas],
      stops: [0, 0.34, 1],
    ),
  );

  /// The shared card shell. [tint] recolours the border and adds a faint wash of
  /// the same hue — used by the confirm card (money) and nothing else by default.
  static BoxDecoration cardDecoration({Color? tint}) => BoxDecoration(
        color: tint == null ? card : Color.alphaBlend(tint.withValues(alpha: 0.07), card),
        borderRadius: BorderRadius.circular(cardRadius),
        border: Border.all(color: tint?.withValues(alpha: 0.45) ?? line),
      );

  /// The `ThemeData` the whole assistant screen is wrapped in, so a `TextField`,
  /// a `BottomSheet` and a `Dialog` inside it inherit the dark surface instead of
  /// each carrying its own overrides.
  static ThemeData data() {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: canvas,
      colorScheme: base.colorScheme.copyWith(
        primary: accent,
        onPrimary: Colors.white,
        secondary: accent,
        surface: card,
        onSurface: ink,
        error: danger,
      ),
      textTheme: GoogleFonts.poppinsTextTheme(base.textTheme).apply(
        bodyColor: ink,
        displayColor: ink,
      ),
      dividerColor: lineSoft,
      iconTheme: const IconThemeData(color: inkSoft),
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: accent,
        selectionColor: Color(0x5522C55E),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Color(0xFF0C2416),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: Color(0xFF0C2416),
        surfaceTintColor: Colors.transparent,
      ),
      snackBarTheme: base.snackBarTheme.copyWith(
        backgroundColor: const Color(0xFF13301F),
        contentTextStyle: const TextStyle(color: ink),
      ),
    );
  }

  /// The colour and glyph for a provenance pill. Six sources, six distinguishable
  /// hues — the point of showing provenance at all is that two of them are never
  /// mistaken for each other at a glance.
  static ({Color color, IconData icon}) sourceTone(ScoutSource source) {
    switch (source) {
      case ScoutSource.live:
        return (color: const Color(0xFF38BDF8), icon: Icons.bolt_rounded);
      case ScoutSource.policy:
        return (color: const Color(0xFFFBBF24), icon: Icons.gavel_rounded);
      case ScoutSource.model:
        return (color: const Color(0xFFC084FC), icon: Icons.auto_awesome_rounded);
      case ScoutSource.kb:
        return (color: const Color(0xFF60A5FA), icon: Icons.storefront_rounded);
      case ScoutSource.menu:
        return (color: const Color(0xFF94A3B8), icon: Icons.apps_rounded);
      case ScoutSource.escalated:
        return (color: const Color(0xFFFB923C), icon: Icons.forward_to_inbox_rounded);
      case ScoutSource.unknown:
        return (color: inkFaint, icon: Icons.help_outline_rounded);
    }
  }

  /// Match-percentage bands, dark-tuned. The thresholds (80/55/30) are the same
  /// ones `CompetitivenessTone` uses elsewhere in the app on purpose: a 62% must
  /// not mean "competitive" on one screen and "uphill" on another.
  static ({Color color, String label}) pctTone(int? pct) {
    if (pct == null) return (color: inkFaint, label: 'Unranked');
    if (pct >= 80) return (color: good, label: 'Great fit');
    if (pct >= 55) return (color: accent, label: 'Good fit');
    if (pct >= 30) return (color: money, label: 'Fair fit');
    return (color: danger, label: 'Weak fit');
  }
}
