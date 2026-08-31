import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../constants/colors.dart';
import '../utils/deep_link.dart';

/// The foreground half of push delivery.
///
/// WHY THIS EXISTS INSTEAD OF flutter_local_notifications
/// On Android, FCM draws the tray banner itself when the app is backgrounded or
/// killed -- `pushService` sends a `notification` block alongside the `data` block
/// precisely so a killed app still buzzes. What FCM will NOT do is show anything
/// while the app is in the foreground: `onMessage` fires and no system notification
/// appears. That single case is the only thing a local-notifications plugin would
/// have added, and a system tray banner is the wrong artefact for it anyway -- the
/// user is looking straight at the app. An in-app banner is both better UX and one
/// less plugin, one less Java-8 desugaring requirement in the Gradle config, and one
/// less thing that can break a release build.
///
/// It is an `OverlayEntry` rather than a `SnackBar` because a SnackBar belongs to the
/// nearest Scaffold: it would be clipped by a bottom navigation bar, replaced by the
/// next "Booking confirmed" toast a screen happens to show, and unavailable at all
/// from a route without a Scaffold. The overlay sits above every route.
class InAppBanner {
  InAppBanner._();

  static OverlayEntry? _entry;
  static Timer? _timer;

  /// Show a notification frame as a banner. Safe to call with no overlay mounted
  /// (during a route transition, say) -- it returns quietly rather than throwing on
  /// a path that is only ever reached asynchronously.
  ///
  /// [frame] is either a socket `notification:new` payload or an FCM `data` block;
  /// both carry `title`, `body` and `deepLink`, so one reader serves both.
  static void show(Map<String, dynamic> frame) {
    final nav = DeepLink.navigatorKey.currentState;
    final overlay = nav?.overlay;
    if (overlay == null) return;

    final title = (frame['title'] ?? '').toString();
    final body = (frame['body'] ?? '').toString();
    if (title.isEmpty && body.isEmpty) return;
    final link = frame['deepLink'];

    dismiss();

    final entry = OverlayEntry(
      builder: (context) => _BannerCard(
        title: title,
        body: body,
        onTap: () {
          dismiss();
          if (link != null) DeepLink.open(link);
        },
        onClose: dismiss,
      ),
    );
    _entry = entry;
    overlay.insert(entry);
    // Four seconds: long enough to read two lines, short enough that a burst of
    // notifications does not queue up in front of what the user is doing.
    _timer = Timer(const Duration(seconds: 4), dismiss);
  }

  static void dismiss() {
    _timer?.cancel();
    _timer = null;
    _entry?.remove();
    _entry = null;
  }
}

class _BannerCard extends StatefulWidget {
  final String title;
  final String body;
  final VoidCallback onTap;
  final VoidCallback onClose;

  const _BannerCard({
    required this.title,
    required this.body,
    required this.onTap,
    required this.onClose,
  });

  @override
  State<_BannerCard> createState() => _BannerCardState();
}

class _BannerCardState extends State<_BannerCard> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    duration: const Duration(milliseconds: 260),
    vsync: this,
  );

  @override
  void initState() {
    super.initState();
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Positioned(
      top: top + 8,
      left: 12,
      right: 12,
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, -1.2), end: Offset.zero)
            .animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic)),
        child: Material(
          color: Colors.transparent,
          child: Dismissible(
            // Swipe up to dismiss, which is where a thumb goes for a banner at the
            // top of the screen.
            key: const ValueKey('inAppBanner'),
            direction: DismissDirection.up,
            onDismissed: (_) => widget.onClose(),
            child: InkWell(
              onTap: widget.onTap,
              borderRadius: BorderRadius.circular(14),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: const Icon(Icons.notifications_active,
                          color: Colors.white, size: 18),
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (widget.title.isNotEmpty)
                            Text(
                              widget.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.poppins(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          if (widget.body.isNotEmpty)
                            Text(
                              widget.body,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.poppins(
                                color: Colors.white.withValues(alpha: 0.85),
                                fontSize: 11.5,
                                height: 1.3,
                              ),
                            ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: widget.onClose,
                      icon: const Icon(Icons.close, color: Colors.white70, size: 18),
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(),
                      padding: EdgeInsets.zero,
                      tooltip: 'Dismiss',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
