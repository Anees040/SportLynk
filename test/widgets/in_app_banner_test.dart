// InAppBanner: the foreground half of push delivery.
//
// FCM draws nothing while the app is in front, so this overlay is the only thing a
// user sees when a notification arrives while they are looking at the app. It is a
// static entry point called from a socket frame and from `onMessage`, which is to say
// from code with no `BuildContext`, and that shape is what most of the assertions
// below are about: it reaches the screen through `DeepLink.navigatorKey`, so a test
// has to install that key on its own `MaterialApp` rather than use the shared harness.
//
// Three behaviours are worth more than the drawing. It must return quietly when there
// is no overlay — the call site is asynchronous, and a frame arriving during a route
// transition or after a logout must not throw from a Timer callback. It must refuse an
// empty frame, because a malformed payload otherwise puts an empty dark card over the
// screen with no way to know what it was for. And every exit — the four-second timer,
// the close button, a swipe, a tap that navigates — has to cancel the timer and remove
// the entry, since a leaked `OverlayEntry` survives the route under it.
//
// The tap is the reason the banner exists rather than a badge: it carries the same
// `{route, args}` link the tray tap does, and an unknown route degrades to the
// notification list instead of an unhandled-route exception. Both are pinned.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sportlynk/constants/app_theme.dart';
import 'package:sportlynk/utils/deep_link.dart';
import 'package:sportlynk/widgets/in_app_banner.dart';

import 'widget_harness.dart';

/// The banner's own key, which is also the only handle a test has on the card: the
/// widget behind it is private.
final Finder _banner = find.byKey(const ValueKey('inAppBanner'));

/// A host app carrying the navigator key the banner reaches for, plus a route table so
/// a deep link's destination is observable.
Future<RouteLog> _pumpHost(WidgetTester tester) async {
  GoogleFonts.config.allowRuntimeFetching = false;
  final log = RouteLog();
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.light,
    navigatorKey: DeepLink.navigatorKey,
    onGenerateRoute: log.onGenerateRoute,
    home: const Scaffold(body: Center(child: Text('a screen'))),
  ));
  return log;
}

/// Shows a frame and lets the entry animation finish.
Future<void> _show(WidgetTester tester, Map<String, dynamic> frame) async {
  InAppBanner.show(frame);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  // A standing entry outlives the test that made it and takes the next test's overlay
  // with it, and its four-second timer is reported as a leak the moment the tree is
  // disposed — so every test above ends by dismissing, and this is the belt.
  tearDown(InAppBanner.dismiss);

  group('when there is nowhere to draw', () {
    // Reached on every logout and every route transition, from a Timer callback with
    // no context. Throwing here would be an unhandled asynchronous error.
    testWidgets('a frame arriving with no overlay is dropped', (tester) async {
      InAppBanner.show({'title': 'Booking confirmed', 'body': 'Arena One, 6 pm'});
      final log = await _pumpHost(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(_banner, findsNothing);
      expect(find.text('Booking confirmed'), findsNothing);
      expect(log.isEmpty, isTrue);
    });
  });

  group('what is worth showing', () {
    testWidgets('a title and a body are drawn with the bell', (tester) async {
      await _pumpHost(tester);
      await _show(tester, {'title': 'Booking confirmed', 'body': 'Arena One, 6 pm'});
      expect(_banner, findsOneWidget);
      expect(find.text('Booking confirmed'), findsOneWidget);
      expect(find.text('Arena One, 6 pm'), findsOneWidget);
      expect(find.byIcon(Icons.notifications_active), findsOneWidget);
      expect(find.byTooltip('Dismiss'), findsOneWidget);
      InAppBanner.dismiss();
    });

    // A malformed payload must not put a blank card over the screen.
    testWidgets('a frame with no words in it is refused', (tester) async {
      await _pumpHost(tester);
      await _show(tester, <String, dynamic>{});
      expect(_banner, findsNothing);

      await _show(tester, {'title': '', 'body': ''});
      expect(_banner, findsNothing);
    });

    testWidgets('either half alone is enough', (tester) async {
      await _pumpHost(tester);
      await _show(tester, {'title': 'Match starts in an hour'});
      expect(find.text('Match starts in an hour'), findsOneWidget);

      await _show(tester, {'body': 'Your opponent withdrew'});
      expect(find.text('Your opponent withdrew'), findsOneWidget);
      expect(_banner, findsOneWidget);
      InAppBanner.dismiss();
    });

    // A burst of frames must not stack: `show` dismisses the standing entry first.
    testWidgets('a second frame replaces the first', (tester) async {
      await _pumpHost(tester);
      await _show(tester, {'title': 'First'});
      await _show(tester, {'title': 'Second'});
      expect(find.text('First'), findsNothing);
      expect(find.text('Second'), findsOneWidget);
      expect(_banner, findsOneWidget);
      InAppBanner.dismiss();
    });

    testWidgets('it slides down from above the screen edge', (tester) async {
      await _pumpHost(tester);
      InAppBanner.show({'title': 'Booking confirmed'});
      await tester.pump();
      expect(tester.getTopLeft(_banner).dy, lessThan(0));

      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getTopLeft(_banner).dy, 8);
      InAppBanner.dismiss();
    });
  });

  // Four ways out, and all four have to cancel the timer as well as remove the entry:
  // a cancelled banner whose timer still fires would dismiss whatever replaced it.
  group('how it goes away', () {
    testWidgets('it gives itself four seconds', (tester) async {
      await _pumpHost(tester);
      await _show(tester, {'title': 'Booking confirmed'});
      await tester.pump(const Duration(seconds: 3));
      expect(_banner, findsOneWidget, reason: 'three seconds is not long enough to go');

      await tester.pump(const Duration(seconds: 2));
      expect(_banner, findsNothing);
    });

    testWidgets('the close button takes it away at once', (tester) async {
      await _pumpHost(tester);
      await _show(tester, {'title': 'Booking confirmed'});
      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pump();
      expect(_banner, findsNothing);
    });

    // Up, not sideways: a banner at the top of the screen is dismissed towards the
    // edge it came from, and the horizontal directions belong to the page underneath.
    testWidgets('a swipe upwards dismisses it', (tester) async {
      await _pumpHost(tester);
      await _show(tester, {'title': 'Booking confirmed'});
      await tester.drag(_banner, const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(_banner, findsNothing);
    });

    testWidgets('a sideways swipe leaves it alone', (tester) async {
      await _pumpHost(tester);
      await _show(tester, {'title': 'Booking confirmed'});
      await tester.drag(_banner, const Offset(400, 0));
      await tester.pump(const Duration(milliseconds: 300));
      expect(_banner, findsOneWidget);
      InAppBanner.dismiss();
    });
  });

  // The tap is the point of the banner: it carries the same `{route, args}` link as a
  // tray tap, so the two paths cannot disagree about where a notification leads.
  group('where a tap leads', () {
    testWidgets('a link opens its route and closes the banner', (tester) async {
      final log = await _pumpHost(tester);
      await _show(tester, {
        'title': 'Payment received',
        'body': 'PKR 2,500 credited',
        'deepLink': {'route': '/wallet', 'args': <String, dynamic>{}},
      });
      await tester.tap(find.text('Payment received'));
      await tester.pumpAndSettle();
      expect(log.pushed, ['/wallet']);
      expect(_banner, findsNothing);
    });

    // A row written by an older server version can name a route this build no longer
    // has. The feed is the honest fallback; an unhandled route is a black screen.
    testWidgets('a route this build does not know falls back to the feed',
        (tester) async {
      final log = await _pumpHost(tester);
      await _show(tester, {
        'title': 'Something happened',
        'deepLink': {'route': '/renamed-last-spring', 'args': <String, dynamic>{}},
      });
      await tester.tap(find.text('Something happened'));
      await tester.pumpAndSettle();
      expect(log.pushed, ['/notifications']);
    });

    testWidgets('a frame with no link just closes', (tester) async {
      final log = await _pumpHost(tester);
      await _show(tester, {'title': 'Booking confirmed'});
      await tester.tap(find.text('Booking confirmed'));
      await tester.pumpAndSettle();
      expect(log.isEmpty, isTrue);
      expect(_banner, findsNothing);
    });
  });
}
