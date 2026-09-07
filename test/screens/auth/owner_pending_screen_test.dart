// Where an owner lands after submitting a venue application, and the one screen in the
// app whose whole job is to stop a user from acting.
//
// Two contracts are pinned. The first is that it cannot be dismissed backwards
// (:10): the form behind it has already been posted, and letting a swipe return to it
// would invite a second application for the same ground. `canPop: false` is invisible
// in the rendered output, so it is asserted on the widget.
//
// The second is that the two remaining steps are shown as not done. The screen exists
// because approval is a human review that takes a day or two, and an owner who cannot
// see where the delay is will read the wait as a broken app.
//
// The checklist itself is static — five hardcoded rows, three of them ticked, no
// request — which is recorded at the end of the file rather than asserted as correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/auth/owner_pending_screen.dart';

import '../screen_harness.dart';

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    api.install();
  });

  group('what the owner is told', () {
    testWidgets('the submission is confirmed', (tester) async {
      await pumpScreen(tester, const OwnerPendingScreen());

      expect(find.text('Application Submitted!'), findsOneWidget);
      expect(find.byIcon(Icons.pending_actions), findsOneWidget);
    });

    testWidgets('the wait is given a length and an end', (tester) async {
      // An open-ended wait with no stated channel is the reason this screen exists;
      // both halves of that sentence are the contract.
      await pumpScreen(tester, const OwnerPendingScreen());

      expect(find.textContaining('24-48 hours'), findsOneWidget);
      expect(find.textContaining('SMS notification'), findsOneWidget);
    });

    testWidgets('the finished steps are shown as finished', (tester) async {
      await pumpScreen(tester, const OwnerPendingScreen());

      expect(find.text('Identity verification (CNIC)'), findsOneWidget);
      expect(find.text('Ground details submitted'), findsOneWidget);
      expect(find.text('Photos received'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsNWidgets(3));
    });

    testWidgets('the outstanding steps are shown as outstanding', (tester) async {
      // The distinction is the whole information content of the checklist: three
      // ticks and two waits tell the owner the delay is not theirs to fix.
      await pumpScreen(tester, const OwnerPendingScreen());

      expect(find.text('Admin review'), findsOneWidget);
      expect(find.text('Account activation'), findsOneWidget);
      expect(find.byIcon(Icons.hourglass_top), findsOneWidget);
      expect(find.byIcon(Icons.lock_clock), findsOneWidget);
    });

    testWidgets('no failure or empty state is possible', (tester) async {
      // Nothing is fetched, so the screen cannot be reached in a state that says
      // less than this. That is deliberate for a terminal screen.
      await pumpScreen(tester, const OwnerPendingScreen());
      await settleData(tester);

      expect(api.requests, isEmpty);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  group('what the owner can do', () {
    testWidgets('the only exit is forward to the welcome screen', (tester) async {
      final log = await pumpScreen(tester, const OwnerPendingScreen());

      await tester.tap(find.textContaining('Back to Home'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(log.sawRoute('/welcome'), isTrue);
    });

    testWidgets('going back cannot return to the form', (tester) async {
      // :10 — the application has already been posted; a swipe back into the form
      // would invite a duplicate submission for the same ground.
      await pumpScreen(tester, const OwnerPendingScreen());

      final scope = tester.widget<PopScope<Object?>>(
          find.byType(PopScope<Object?>));
      expect(scope.canPop, isFalse);
    });

    testWidgets('the exit is large enough to hit', (tester) async {
      await pumpScreen(tester, const OwnerPendingScreen());

      expectTapTarget(tester, find.byType(TextButton));
    });

    testWidgets('there is exactly one action', (tester) async {
      // A screen whose purpose is to make the owner wait must not offer a second
      // button that looks like it could speed that up.
      await pumpScreen(tester, const OwnerPendingScreen());

      expect(find.byType(TextButton), findsOneWidget);
      expect(find.byType(ElevatedButton), findsNothing);
    });
  });

  group('at a doubled text scale', () {
    testWidgets('it does not clip', (tester) async {
      // Every row is `Expanded` inside its `Row` (:110) and the page is a
      // `SingleChildScrollView` (:16), which together are what make the larger type
      // fit.
      await pumpScreen(tester, const OwnerPendingScreen(), textScale: 2.0);

      expectNoOverflow(tester);
    });

    testWidgets('all five steps are still readable', (tester) async {
      await pumpScreen(tester, const OwnerPendingScreen(), textScale: 2.0);

      expect(find.text('Admin review'), findsOneWidget);
      expect(find.text('Account activation'), findsOneWidget);
    });

    testWidgets('it lays out on a short screen', (tester) async {
      await pumpScreen(tester, const OwnerPendingScreen(),
          size: const Size(360, 640));

      expect(find.text('Application Submitted!'), findsOneWidget);
      expectNoOverflow(tester);
    });
  });

  // Pinned as it behaves, not as it should.
  // lib/screens/auth/owner_pending_screen.dart:61 hardcodes all five rows, so the
  // three ticks are asserted rather than read: an application that was accepted
  // without photos still says "Photos received", and an application an admin has
  // already started reviewing still says the review has not begun. The state exists on
  // the server — the admin console reads it through the registrations endpoints — so
  // the fix is to fetch this owner's application and drive the rows from it, with the
  // four states that then become possible. This test records that no request is made.
  testWidgets('the checklist is asserted rather than read', (tester) async {
    await pumpScreen(tester, const OwnerPendingScreen());
    await settleData(tester);

    expect(api.requests, isEmpty);
    expect(find.byIcon(Icons.check_circle), findsNWidgets(3));
  });
}
