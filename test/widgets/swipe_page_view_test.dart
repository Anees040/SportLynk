// SwipePageView is the body the player and owner home shells swapped their
// IndexedStack for, so the three behaviours the shells depend on are pinned here
// rather than only through the two shell tests: a drag turns the page and reports
// the new tab, a page keeps its state across a swipe away and back, and the ends
// draw the semicircular glow rather than the framework's stretch.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/widgets/swipe_page_view.dart';

import 'widget_harness.dart';

void main() {
  group('SwipePageView', () {
    testWidgets('a horizontal drag turns the page and reports the new index', (
      tester,
    ) async {
      useDeviceSurface(tester);
      int? reported;
      final controller = PageController();
      addTearDown(controller.dispose);

      await pumpApp(
        tester,
        Scaffold(
          body: SwipePageView(
            controller: controller,
            onPageChanged: (i) => reported = i,
            children: const [
              Center(child: Text('Alpha')),
              Center(child: Text('Bravo')),
              Center(child: Text('Charlie')),
            ],
          ),
        ),
      );

      expect(find.text('Alpha'), findsOneWidget);

      await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
      await tester.pumpAndSettle();

      expect(reported, 1);
      expect(find.text('Bravo'), findsOneWidget);
    });

    testWidgets('a controller jump switches instantly and reports the index', (
      tester,
    ) async {
      // The nav bar tap path is a jumpToPage (instant, no slide); it still has to
      // fire onPageChanged or the shell would never learn its tab moved.
      useDeviceSurface(tester);
      int? reported;
      final controller = PageController();
      addTearDown(controller.dispose);

      await pumpApp(
        tester,
        Scaffold(
          body: SwipePageView(
            controller: controller,
            onPageChanged: (i) => reported = i,
            children: const [
              Center(child: Text('Alpha')),
              Center(child: Text('Bravo')),
              Center(child: Text('Charlie')),
            ],
          ),
        ),
      );

      controller.jumpToPage(2);
      await tester.pump();

      expect(reported, 2);
      expect(find.text('Charlie'), findsOneWidget);
    });

    testWidgets('a page keeps its state after a swipe away and back', (
      tester,
    ) async {
      useDeviceSurface(tester);
      final controller = PageController();
      addTearDown(controller.dispose);

      await pumpApp(
        tester,
        Scaffold(
          body: SwipePageView(
            controller: controller,
            onPageChanged: (_) {},
            children: const [
              _Counter(),
              Center(child: Text('P1')),
              Center(child: Text('P2')),
            ],
          ),
        ),
      );

      // Advance the first page's own state, then leave it two tabs behind — far
      // enough that an unkept page would be disposed — and return.
      await tester.tap(find.text('bump'));
      await tester.pump();
      expect(find.text('count: 1'), findsOneWidget);

      for (final dx in const [-300.0, -300.0, 300.0, 300.0]) {
        await tester.fling(find.byType(PageView), Offset(dx, 0), 1000);
        await tester.pumpAndSettle();
      }

      // Reset to 0 would mean the page was rebuilt from scratch; 1 means its State
      // survived the swipe, which is what the shells rely on for tab state.
      expect(find.text('count: 1'), findsOneWidget);
    });

    testWidgets('the ends draw the glow, not the stretch', (tester) async {
      useDeviceSurface(tester);
      final controller = PageController();
      addTearDown(controller.dispose);

      await pumpApp(
        tester,
        Scaffold(
          body: SwipePageView(
            controller: controller,
            onPageChanged: (_) {},
            children: const [
              Center(child: Text('Alpha')),
              Center(child: Text('Bravo')),
            ],
          ),
        ),
      );

      expect(find.byType(GlowingOverscrollIndicator), findsOneWidget);
      expect(find.byType(StretchingOverscrollIndicator), findsNothing);
    });
  });
}

/// A page with mutable state of its own, so a test can tell a kept-alive page from
/// one rebuilt on return: the count only moves on a tap and never resets itself.
class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int _n = 0;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('count: $_n'),
          ElevatedButton(
            onPressed: () => setState(() => _n++),
            child: const Text('bump'),
          ),
        ],
      ),
    );
  }
}
