import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/assistant.dart';

/// Scout's visual language, in two brightnesses.
///
/// Why this is no longer one dark green surface
/// The previous version was a single deep-green canvas, chosen so that "I am
/// talking to the assistant" was legible before a word was read. It achieved that
/// and cost more than it bought: the brand green pushed every one of the twelve
/// card types into a narrow band of dark surfaces, and the screen read as heavy
/// next to the rest of a light utility app. The replacement is the neutral
/// two-brightness palette a conversation UI wants — white or near-black canvas,
/// one grey for the user's own words, a hairline for structure — with the green
/// spent only where it means something: the send control, the avatar, and the
/// accents inside a card.
///
/// Why a class of instances rather than statics
/// A `static const Color` cannot vary with brightness, which is the whole
/// requirement. Every token therefore lives on an instance, and [of] resolves the
/// right one from the surrounding [Theme]. The assistant screen wraps its subtree
/// in `ScoutTheme.data(brightness)`, so a sheet, a dialog and a `TextField` under
/// it all resolve the same palette; a widget used outside that wrapper — the home
/// screen's FAB — resolves against the app's own light theme, which is correct.
///
/// Accessibility is a constraint here, not a review step
/// Every foreground below was checked against the surface it sits on. The rule
/// that shaped the accent split: `#22C55E` reads well as a glyph on near-black
/// (10.6:1) but carries white text at only 2.3:1, so it is never a fill. A filled
/// green control uses [accentFill]/[accentFillDim] instead, which hold white at
/// 5.0:1, and those two are deliberately identical in both brightnesses — a
/// button that means "send" should not change weight when the sun goes down.
@immutable
class ScoutTheme {
  const ScoutTheme._({
    required this.isDark,
    required this.canvas,
    required this.card,
    required this.bubble,
    required this.userBubble,
    required this.line,
    required this.lineSoft,
    required this.ink,
    required this.inkSoft,
    required this.inkFaint,
    required this.accent,
    required this.money,
    required this.danger,
    required this.good,
  });

  /// Which palette this is. Read by the two members whose values are not a
  /// straight token lookup, [sourceTone] and [data].
  final bool isDark;

  // Canvas and surfaces

  /// The page. Flat — the old top-of-screen glow is gone, because a gradient
  /// behind a scrolling transcript moves against the text and a chat canvas has
  /// nothing to gain from being interesting.
  final Color canvas;

  /// A card inside a turn. One step off the canvas, held together by [line].
  final Color card;

  /// An inset surface on the canvas: the composer field and the typing indicator.
  /// Scout's own answers are bare text and use no fill at all.
  final Color bubble;

  /// The user's own words. A neutral, not the brand green — which is what removes
  /// the contrast problem the old gradient bubble had to work around.
  final Color userBubble;

  final Color line;
  final Color lineSoft;

  // Ink

  /// Primary text. 19.4:1 on light, 16.4:1 on dark.
  final Color ink;

  /// Secondary text. 6.6:1 on light, 8.9:1 on dark.
  final Color inkSoft;

  /// Metadata. 4.5:1 on light, 4.7:1 on dark — the floor, and the reason it is
  /// not any lighter.
  final Color inkFaint;

  // Accents

  /// Green as a glyph, a border or a label. Never a fill under white text; see
  /// [accentFill].
  final Color accent;

  /// Money. Reserved for the confirm card and deposit figures, so "this costs
  /// something" has a colour that appears nowhere decorative.
  final Color money;

  final Color danger;
  final Color good;

  /// The green a white glyph may sit on, and its gradient partner. Fixed across
  /// both brightnesses: these are fills, so they are read against their own
  /// contents rather than against the page.
  static const Color accentFill = Color(0xFF15803D);
  static const Color accentFillDim = Color(0xFF0F6B33);

  /// What sits on [accentFill]. 5.0:1.
  static const Color onAccentFill = Colors.white;

  /// The transient-message surface, and what sits on it. Dark in both
  /// brightnesses, because a snackbar is an overlay on top of the page rather
  /// than part of it.
  ///
  /// Named rather than left inline in [data]: the assistant screen's own toast is
  /// built by the `ScaffoldMessenger` above the screen's [Theme] and therefore has
  /// to state the two colours that [data] would otherwise have applied for it.
  static const Color toastSurface = Color(0xFF2A2A2A);
  static const Color onToastSurface = Color(0xFFECECEC);

  static const LinearGradient accentGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [accentFill, accentFillDim],
  );

  // Metrics

  static const double cardRadius = 16;
  static const double bubbleRadius = 20;
  static const double gap = 8;

  static const ScoutTheme light = ScoutTheme._(
    isDark: false,
    canvas: Color(0xFFFFFFFF),
    card: Color(0xFFF9F9F9),
    bubble: Color(0xFFF7F7F7),
    userBubble: Color(0xFFF4F4F4),
    line: Color(0xFFECECEC),
    lineSoft: Color(0xFFF2F2F2),
    ink: Color(0xFF0D0D0D),
    inkSoft: Color(0xFF5D5D5D),
    inkFaint: Color(0xFF767676),
    accent: Color(0xFF15803D),
    money: Color(0xFFA16207),
    danger: Color(0xFFDC2626),
    good: Color(0xFF047857),
  );

  static const ScoutTheme dark = ScoutTheme._(
    isDark: true,
    canvas: Color(0xFF0D0D0D),
    card: Color(0xFF1A1A1A),
    bubble: Color(0xFF1A1A1A),
    userBubble: Color(0xFF303030),
    line: Color(0xFF2A2A2A),
    lineSoft: Color(0xFF212121),
    ink: Color(0xFFECECEC),
    inkSoft: Color(0xFFAFAFAF),
    inkFaint: Color(0xFF7D7D7D),
    accent: Color(0xFF22C55E),
    money: Color(0xFFF6C445),
    danger: Color(0xFFF87171),
    good: Color(0xFF4ADE80),
  );

  /// The palette for the surrounding [Theme].
  ///
  /// Brightness rather than a registered `ThemeExtension`: the palette has exactly
  /// two values and nothing overrides it per-subtree, so the extension's `lerp`
  /// and `copyWith` would be two members no caller could use. A widget built
  /// outside the assistant's own `Theme` resolves against the app theme, which is
  /// light — the correct answer for the home screen's entry points.
  static ScoutTheme of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;

  /// The shared card shell. [tint] recolours the border and adds a faint wash of
  /// the same hue — used by the confirm card (money) and nothing else by default.
  BoxDecoration cardDecoration({Color? tint}) => BoxDecoration(
        color: tint == null
            ? card
            : Color.alphaBlend(tint.withValues(alpha: isDark ? 0.07 : 0.05), card),
        borderRadius: BorderRadius.circular(cardRadius),
        border: Border.all(color: tint?.withValues(alpha: 0.45) ?? line),
      );

  /// The `ThemeData` the whole assistant screen is wrapped in, so a `TextField`,
  /// a `BottomSheet` and a `Dialog` inside it inherit the same surface instead of
  /// each carrying its own overrides.
  ///
  /// The caller passes the system brightness, which is the only place the choice
  /// is made: the rest of SportLynk has one light theme, and the assistant follows
  /// the phone.
  static ThemeData data(Brightness brightness) {
    final t = brightness == Brightness.dark ? dark : light;
    final base = ThemeData(brightness: brightness, useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: t.canvas,
      colorScheme: base.colorScheme.copyWith(
        primary: t.accent,
        onPrimary: onAccentFill,
        secondary: t.accent,
        surface: t.card,
        onSurface: t.ink,
        error: t.danger,
      ),
      textTheme: GoogleFonts.poppinsTextTheme(base.textTheme).apply(
        bodyColor: t.ink,
        displayColor: t.ink,
      ),
      dividerColor: t.lineSoft,
      iconTheme: IconThemeData(color: t.inkSoft),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: t.accent,
        selectionColor: t.accent.withValues(alpha: 0.28),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: t.card,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: t.card,
        surfaceTintColor: Colors.transparent,
      ),
      snackBarTheme: base.snackBarTheme.copyWith(
        backgroundColor: toastSurface,
        contentTextStyle: const TextStyle(color: onToastSurface),
      ),
    );
  }

  /// The colour and glyph for a provenance pill. Six sources, six distinguishable
  /// hues — the point of showing provenance at all is that two of them are never
  /// mistaken for each other at a glance.
  ///
  /// Light mode uses the 700-weight of each hue rather than the 400: the dark set
  /// was tuned against a near-black canvas and none of it clears 4.5:1 on white.
  ({Color color, IconData icon}) sourceTone(ScoutSource source) {
    switch (source) {
      case ScoutSource.live:
        return (
          color: isDark ? const Color(0xFF38BDF8) : const Color(0xFF0369A1),
          icon: Icons.bolt_rounded,
        );
      case ScoutSource.policy:
        return (
          color: isDark ? const Color(0xFFFBBF24) : const Color(0xFFA16207),
          icon: Icons.gavel_rounded,
        );
      case ScoutSource.model:
        return (
          color: isDark ? const Color(0xFFC084FC) : const Color(0xFF7E22CE),
          icon: Icons.auto_awesome_rounded,
        );
      case ScoutSource.kb:
        return (
          color: isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8),
          icon: Icons.storefront_rounded,
        );
      case ScoutSource.menu:
        return (
          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
          icon: Icons.apps_rounded,
        );
      case ScoutSource.escalated:
        return (
          color: isDark ? const Color(0xFFFB923C) : const Color(0xFFC2410C),
          icon: Icons.forward_to_inbox_rounded,
        );
      case ScoutSource.unknown:
        return (color: inkFaint, icon: Icons.help_outline_rounded);
    }
  }

  /// Match-percentage bands. The thresholds (80/55/30) are the same ones
  /// `CompetitivenessTone` uses elsewhere in the app on purpose: a 62% must not
  /// mean "competitive" on one screen and "uphill" on another.
  ({Color color, String label}) pctTone(int? pct) {
    if (pct == null) return (color: inkFaint, label: 'Unranked');
    if (pct >= 80) return (color: good, label: 'Great fit');
    if (pct >= 55) return (color: accent, label: 'Good fit');
    if (pct >= 30) return (color: money, label: 'Fair fit');
    return (color: danger, label: 'Weak fit');
  }
}
