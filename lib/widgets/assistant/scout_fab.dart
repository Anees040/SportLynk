import 'package:flutter/material.dart';

import 'scout_theme.dart';

/// The way into Scout from anywhere in the player app.
///
/// A floating button rather than a sixth tab, and that is a considered choice: the
/// bottom bar already carries five destinations at 10px labels, and a sixth would
/// shrink every existing one to buy a place for a feature nobody has used yet. A FAB
/// also says the right thing about what Scout is — an assistant that follows the
/// user across screens, not a section of the app to navigate to and come back from.
///
/// The halo breathes on a 2.4s cycle. Slow enough to read as "alive" rather than
/// "notification", and it is decoration only: the icon, the colour and the tooltip all
/// stand on their own with animations disabled.
class ScoutFab extends StatefulWidget {
  final VoidCallback onTap;
  final bool extended;

  const ScoutFab({required this.onTap, this.extended = false, super.key});

  @override
  State<ScoutFab> createState() => _ScoutFabState();
}

class _ScoutFabState extends State<ScoutFab> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(18);
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_c.value);
        return Container(
          decoration: BoxDecoration(
            borderRadius: radius,
            boxShadow: [
              BoxShadow(
                color: ScoutTheme.accentFill.withValues(alpha: 0.20 + 0.18 * t),
                blurRadius: 14 + 10 * t,
                spreadRadius: 1 + 2 * t,
              ),
            ],
          ),
          child: child,
        );
      },
      child: Semantics(
        button: true,
        label: 'Ask Scout, the SportLynk assistant',
        child: Material(
          color: Colors.transparent,
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onTap,
            child: widget.extended ? _extended() : _mascot(56, 18),
          ),
        ),
      ),
    );
  }

  /// The collapsed FAB: the mascot tile itself is the button face, so Scout's
  /// identity is the control rather than a generic sparkle on a green pill.
  Widget _mascot(double d, double radius) => Container(
        width: d,
        height: d,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: ScoutTheme.accentFill,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: Image.asset(
          ScoutTheme.mascotAsset,
          fit: BoxFit.cover,
          // Decorative: the control carries its own label, so the mascot is not
          // announced as a separate image to a screen reader.
          excludeFromSemantics: true,
        ),
      );

  /// The extended pill keeps the brand gradient behind the mascot and label, for
  /// the callers that ask for a labelled entry point rather than a bare tile.
  Widget _extended() => Container(
        padding: const EdgeInsets.fromLTRB(9, 8, 16, 8),
        decoration: BoxDecoration(
          gradient: ScoutTheme.accentGradient,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _mascot(34, 11),
            const SizedBox(width: 9),
            const Text(
              'Ask Scout',
              style: TextStyle(
                color: ScoutTheme.onAccentFill,
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      );
}

/// The same entry point as a banner, for the Home tab's quick actions.
///
/// It carries the only green on an otherwise white screen, which is what stops a
/// new capability from disappearing among four tiles that were already there. It
/// no longer previews the assistant's surface by being dark: Scout follows the
/// system brightness now, so there is no one surface to preview, and a dark card
/// on a light Home would be a promise about the next screen that the phone's own
/// setting decides.
class ScoutAskBanner extends StatelessWidget {
  final VoidCallback onTap;

  const ScoutAskBanner({required this.onTap, super.key});

  @override
  Widget build(BuildContext context) {
    final t = ScoutTheme.of(context);
    return Semantics(
      button: true,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            color: ScoutTheme.accentFill.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: t.accent.withValues(alpha: 0.30)),
            boxShadow: [
              BoxShadow(
                color: ScoutTheme.accentFill.withValues(alpha: 0.10),
                blurRadius: 14,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: t.accent.withValues(alpha: 0.35)),
                ),
                child: Image.asset(
          ScoutTheme.mascotAsset,
          fit: BoxFit.cover,
          // Decorative: the control carries its own label, so the mascot is not
          // announced as a separate image to a screen reader.
          excludeFromSemantics: true,
        ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Ask Scout',
                      style: TextStyle(
                        color: t.ink,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Book a ground, find players, check your wallet — just say it.',
                      style: TextStyle(
                        color: t.inkSoft,
                        fontSize: 11,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Icon(Icons.arrow_forward_rounded, color: t.accent, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}
