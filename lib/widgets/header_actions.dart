import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../constants/colors.dart';

/// The two live actions in a home-screen header: chat, and (from Wave C) the
/// notification bell.
///
/// Why a widget and not two copies of a container
/// The player header is a dark gradient and the owner header is a dark
/// SliverAppBar, so the same glass-on-dark treatment is needed in two files that
/// otherwise share nothing. More importantly the badge is the fiddly part — an
/// unread count has to cap, has to shrink to a dot when it is only a hint, and
/// has to sit outside the tap target without stealing it — and a second copy of
/// that would drift the moment one of them is tweaked.
///
/// [badge] is a count, not a boolean: `0` renders nothing at all, so a caller can
/// pass the number straight from the server without an `if` around the widget.
class HeaderIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final int badge;
  final String? tooltip;

  /// Where "99+" starts. A three-digit badge does not fit and does not inform:
  /// past a hundred the only fact that matters is "a lot".
  static const int _cap = 99;

  const HeaderIconButton({
    required this.icon,
    this.onTap,
    this.badge = 0,
    this.tooltip,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final button = Stack(
      clipBehavior: Clip.none,
      children: [
        // The 36×36 box is the tap target — 36 is the smallest square that still
        // clears the 32-logical-pixel floor a thumb needs on this header.
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
          ),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
        if (badge > 0)
          Positioned(
            right: -3,
            top: -3,
            child: IgnorePointer(
              // The badge overhangs the box, so without this it would eat taps
              // at the corner — the corner people aim for when they can
              // see a number there.
              child: Container(
                constraints: const BoxConstraints(minWidth: 18),
                padding: const EdgeInsets.symmetric(horizontal: 4.5, vertical: 1.5),
                decoration: BoxDecoration(
                  color: AppColors.error,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.primary, width: 1.5),
                ),
                child: Text(
                  badge > _cap ? '$_cap+' : '$badge',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9.5,
                    height: 1.15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ),
      ],
    );

    final tappable = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: button,
    );

    return tooltip == null ? tappable : Tooltip(message: tooltip!, child: tappable);
  }
}

/// The wordmark, on its own. Replaces the logo tile + brand text that used to sit
/// at the top-left of the player header: two elements saying the same thing, one
/// of which was an asset that fell back to a letter in a green square when it
/// failed to load.
class BrandWordmark extends StatelessWidget {
  final double fontSize;
  const BrandWordmark({this.fontSize = 19, super.key});

  @override
  Widget build(BuildContext context) {
    return RichText(
      text: TextSpan(children: [
        TextSpan(
          text: 'Sport',
          style: GoogleFonts.poppins(
            color: Colors.white,
            fontSize: fontSize,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.2,
          ),
        ),
        TextSpan(
          text: 'Lynk',
          style: GoogleFonts.poppins(
            color: AppColors.accent,
            fontSize: fontSize,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.2,
          ),
        ),
      ]),
    );
  }
}
