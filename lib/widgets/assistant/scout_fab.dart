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
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_c.value);
        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.extended ? 18 : 999),
            boxShadow: [
              BoxShadow(
                color: ScoutTheme.accent.withValues(alpha: 0.16 + 0.16 * t),
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
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(widget.extended ? 18 : 999),
            child: Container(
              padding: widget.extended
                  ? const EdgeInsets.symmetric(horizontal: 16, vertical: 13)
                  : const EdgeInsets.all(15),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [ScoutTheme.canvasGlow, ScoutTheme.accentDim],
                ),
                borderRadius: BorderRadius.circular(widget.extended ? 18 : 999),
                border: Border.all(color: ScoutTheme.accent.withValues(alpha: 0.45)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.auto_awesome_rounded, color: Color(0xFFEAF6EE), size: 22),
                  if (widget.extended) ...[
                    const SizedBox(width: 8),
                    const Text(
                      'Ask Scout',
                      style: TextStyle(
                        color: Color(0xFFEAF6EE),
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The same entry point as a banner, for the Home tab's quick actions.
///
/// It is dark on a white screen on purpose: it previews the surface it opens, and it
/// is the one element on Home that is not another white card, which is what stops a
/// brand-new capability from being invisible among four tiles that were already there.
class ScoutAskBanner extends StatelessWidget {
  final VoidCallback onTap;

  const ScoutAskBanner({required this.onTap, super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [ScoutTheme.canvasGlow, ScoutTheme.canvas],
            ),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: ScoutTheme.accent.withValues(alpha: 0.30)),
            boxShadow: [
              BoxShadow(
                color: ScoutTheme.canvas.withValues(alpha: 0.22),
                blurRadius: 14,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: ScoutTheme.accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(13),
                  border: Border.all(color: ScoutTheme.accent.withValues(alpha: 0.35)),
                ),
                child: const Icon(
                  Icons.auto_awesome_rounded,
                  color: ScoutTheme.accent,
                  size: 21,
                ),
              ),
              const SizedBox(width: 13),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Ask Scout',
                      style: TextStyle(
                        color: ScoutTheme.ink,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Book a ground, find players, check your wallet — just say it.',
                      style: TextStyle(
                        color: ScoutTheme.inkSoft,
                        fontSize: 11,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              const Icon(Icons.arrow_forward_rounded, color: ScoutTheme.accent, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}
