// The first screen a new install shows, and the only place the two registration paths
// are offered. It has no state and no network, so what is pinned here is the set of
// exits and the copy that distinguishes them.
//
// The two roles are separate flows all the way to separate tables — an owner submits
// documents and waits for approval, a player is signed in immediately — and the choice
// is made here and nowhere else. A regression that pointed both buttons at the same
// route would still look right on screen, so both routes are asserted by name.
//
// The third exit is a tap target inside a paragraph: 'Log In' is a `TextSpan` with a
// `TapGestureRecognizer` (:162), not a button, so it has no ink response, no minimum
// size, and no semantics of its own. It is asserted by tapping a computed offset
// inside the trailing span, and its cost is recorded at the end of the file.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/auth/welcome_screen.dart';

import '../screen_harness.dart';

/// Taps the trailing span of a `RichText`, which is where a recogniser attached to the
/// last `TextSpan` can actually be hit — the centre of the paragraph falls inside the
/// leading span and fires nothing.
Future<void> tapTrailingSpan(WidgetTester tester, Finder finder) async {
  final box = tester.getRect(finder);
  await tester.tapAt(Offset(box.right - 12, box.center.dy));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    api.install();
  });

  group('what the screen offers', () {
    testWidgets('the brand and the promise are shown', (tester) async {
      await pumpScreen(tester, const WelcomeScreen());

      expect(find.text('SportLynk', findRichText: true), findsOneWidget);
      expect(find.text('Book. Play. Compete.'), findsOneWidget);
    });

    testWidgets('both registration paths are offered', (tester) async {
      // The two roles are separate flows to separate tables, and this is the only
      // screen that lets a user pick one.
      await pumpScreen(tester, const WelcomeScreen());

      expect(find.textContaining('I am a Player'), findsOneWidget);
      expect(find.textContaining('I own a Venue'), findsOneWidget);
    });

    testWidgets('returning users are given a way in', (tester) async {
      await pumpScreen(tester, const WelcomeScreen());

      expect(
          find.text('Already have an account? Log In', findRichText: true),
          findsOneWidget);
    });

    testWidgets('the owner path is visually secondary', (tester) async {
      // Most installs are players; the outlined variant is what keeps the owner path
      // from competing with the primary one.
      await pumpScreen(tester, const WelcomeScreen());

      expect(find.byType(ElevatedButton), findsOneWidget);
      expect(find.byType(OutlinedButton), findsOneWidget);
    });

    testWidgets('nothing is fetched', (tester) async {
      // The screen a cold install opens must not depend on the API being reachable.
      await pumpScreen(tester, const WelcomeScreen());
      await settleData(tester);

      expect(api.requests, isEmpty);
    });

    testWidgets('there is no back affordance', (tester) async {
      // It is the root; a back arrow here would lead nowhere.
      await pumpScreen(tester, const WelcomeScreen());

      expect(find.byType(AppBar), findsNothing);
      expect(find.byIcon(Icons.arrow_back), findsNothing);
    });
  });

  group('where the exits lead', () {
    testWidgets('the player button opens player registration', (tester) async {
      final log = await pumpScreen(tester, const WelcomeScreen());

      await tester.tap(find.textContaining('I am a Player'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(log.sawRoute('/register/player'), isTrue);
    });

    testWidgets('the owner button opens owner registration', (tester) async {
      // Distinct from the player route: the owner form collects a CNIC and ground
      // documents and ends on the pending screen rather than signed in.
      final log = await pumpScreen(tester, const WelcomeScreen());

      await tester.tap(find.textContaining('I own a Venue'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(log.sawRoute('/register/owner'), isTrue);
      expect(log.sawRoute('/register/player'), isFalse);
    });

    testWidgets('the log in link opens the login screen', (tester) async {
      final log = await pumpScreen(tester, const WelcomeScreen());

      await tapTrailingSpan(
        tester,
        find.text('Already have an account? Log In', findRichText: true),
      );

      expect(log.sawRoute('/login'), isTrue);
    });

    testWidgets('nothing is pushed before a tap', (tester) async {
      final log = await pumpScreen(tester, const WelcomeScreen());
      await settleData(tester);

      expect(log.isEmpty, isTrue);
    });

    testWidgets('the sentence around the link is not itself a link',
        (tester) async {
      // The recogniser is attached to the trailing span only (:162). A tap on the
      // leading half must do nothing, or the paragraph becomes an accidental button.
      final log = await pumpScreen(tester, const WelcomeScreen());

      final box = tester.getRect(
          find.text('Already have an account? Log In', findRichText: true));
      await tester.tapAt(Offset(box.left + 8, box.center.dy));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(log.isEmpty, isTrue);
    });
  });

  group('reach and scale', () {
    testWidgets('both buttons are tall enough to hit', (tester) async {
      await pumpScreen(tester, const WelcomeScreen());

      expectTapTarget(tester, find.byType(ElevatedButton));
      expectTapTarget(tester, find.byType(OutlinedButton));
    });

    testWidgets('it does not clip at a doubled text scale', (tester) async {
      // The bottom sheet is a `SingleChildScrollView` (:105) precisely so the larger
      // type has somewhere to go.
      await pumpScreen(tester, const WelcomeScreen(), textScale: 2.0);

      expectNoOverflow(tester);
    });

    testWidgets('every exit is still reachable at a doubled text scale',
        (tester) async {
      await pumpScreen(tester, const WelcomeScreen(), textScale: 2.0);

      expect(find.textContaining('I am a Player'), findsOneWidget);
      expect(find.textContaining('I own a Venue'), findsOneWidget);
    });

    testWidgets('it lays out on a short screen', (tester) async {
      // The dark half is a flexed fraction rather than a fixed height, so a small
      // phone gets a smaller hero instead of an overflow.
      await pumpScreen(tester, const WelcomeScreen(),
          size: const Size(360, 640));

      expect(find.text('Get Started'), findsOneWidget);
      expectNoOverflow(tester);
    });

    // Pinned as it behaves, not as it should.
    // lib/screens/auth/welcome_screen.dart:156 makes 'Log In' a `TextSpan` with a
    // `TapGestureRecognizer`, which gives it no minimum tap area, no ink response and
    // no semantics node a screen reader can announce as a button — the two buttons
    // above it have all three. The fix is a `TextButton` beside the sentence; this
    // test should then be an `expectTapTarget`.
    testWidgets('the log in link is not a button', (tester) async {
      await pumpScreen(tester, const WelcomeScreen());

      expect(find.widgetWithText(TextButton, 'Log In'), findsNothing);
      expect(find.widgetWithText(InkWell, 'Log In'), findsNothing);
    });
  });
}
