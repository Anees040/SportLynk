import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../constants/colors.dart';

/// A horizontally swipeable host for a role home shell's bottom-navigation tabs.
///
/// Replaces the [IndexedStack] the shells used, so a tab can be reached by
/// dragging between pages the way a messaging app's main screens are, not only by
/// tapping the bar. Three behaviours are fixed here so the player and owner shells
/// share one feel:
///
/// - every page is kept alive once first built, so a tab that was scrolled and
///   loaded keeps its position and its data across a swipe, as it did under the
///   stack. Pages are built on first view rather than all at startup, which is
///   strictly cheaper than the stack and why a shell must tolerate a tab's state
///   being absent until it has been shown once;
/// - the ends do not rubber-band. Dragging past the first or last tab leaves a
///   [GlowingOverscrollIndicator]'s semicircle on that edge — the signal that
///   there is no further tab that way. The glow is forced because the framework
///   default is now the stretch effect, and the semicircle is the intended look;
/// - pages snap one tab at a time under [PageScrollPhysics], over
///   [ClampingScrollPhysics] so the overscroll the glow draws is actually
///   reported on every platform rather than absorbed by a bounce.
class SwipePageView extends StatelessWidget {
  const SwipePageView({
    super.key,
    required this.controller,
    required this.onPageChanged,
    required this.children,
  });

  /// Drives the pages and reports the fractional position a navigation bar reads
  /// to slide its indicator with the drag.
  final PageController controller;

  /// Called with the settled tab index whenever the page changes, by drag or by
  /// an animated jump. The single place a shell learns its tab moved.
  final ValueChanged<int> onPageChanged;

  /// One widget per tab, in bar order. Each is wrapped for keep-alive here.
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return PageView(
      controller: controller,
      onPageChanged: onPageChanged,
      // Set on the PageView rather than through a wrapping ScrollConfiguration so
      // the forced glow and the pointer set apply to the horizontal swipe alone;
      // the vertical lists inside each tab keep the framework's own overscroll.
      scrollBehavior: const _EdgeGlowBehavior(),
      physics: const PageScrollPhysics(parent: ClampingScrollPhysics()),
      children: [
        for (final child in children) _KeepAlive(child: child),
      ],
    );
  }
}

/// The controller's fractional page — 1.5 while a drag sits halfway between tabs
/// 1 and 2 — for a navigation bar to interpolate its indicator against. Falls back
/// to [fallback] before the view has laid out, when the controller carries no
/// position to report, so the bar draws the correct resting tab on the first frame.
double swipePage(PageController controller, int fallback) {
  if (!controller.hasClients || controller.positions.length != 1) {
    return fallback.toDouble();
  }
  return controller.page ?? fallback.toDouble();
}

/// Forces the semicircular overscroll glow in place of the framework's stretch,
/// tinted the brand accent, on whichever edge a page is dragged past, and accepts
/// a drag from any pointer so the swipe works under a mouse in a desktop browser as
/// well as a finger on a phone.
class _EdgeGlowBehavior extends ScrollBehavior {
  const _EdgeGlowBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => PointerDeviceKind.values.toSet();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return GlowingOverscrollIndicator(
      axisDirection: details.direction,
      color: AppColors.accent,
      child: child,
    );
  }
}

/// Holds a page's element subtree alive once built, so a swipe away and back does
/// not discard a tab's scroll offset and loaded data. [PageView] wraps its children
/// in an [AutomaticKeepAlive], which this registers with.
class _KeepAlive extends StatefulWidget {
  const _KeepAlive({required this.child});

  final Widget child;

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
