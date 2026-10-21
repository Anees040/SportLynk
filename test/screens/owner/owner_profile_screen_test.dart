// The owner's profile: unusual among these screens in that it fetches nothing on
// mount. Identity is read straight off `AuthProvider` (`FakeAuth` supplies it) and
// the only initState work is a `SharedPreferences` read for the "don't ask me again"
// logout preference — which is why `setMockInitialValues` is set below and no
// `FakeApi` is installed. The network only appears on submit (avatar upload, change
// password, edit profile), which these tests reach the sheets of but do not submit,
// so no override is needed.
//
// Because nothing animates forever here, `pumpAndSettle` is safe — the exception to
// the rule the other screen tests follow.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sportlynk/screens/owner/owner_profile_screen.dart';

import '../screen_harness.dart';

Future<RouteLog> pumpProfile(
  WidgetTester tester, {
  double textScale = 1.0,
  Size size = const Size(430, 915),
}) {
  return pumpScreen(
    tester,
    const OwnerProfileScreen(),
    auth: FakeAuth(
      role: 'owner',
      id: 'o-1',
      name: 'Owner',
      token: 'owner-token',
    ),
    textScale: textScale,
    size: size,
  );
}

void main() {
  setUp(() {
    // `_loadPrefs` calls SharedPreferences.getInstance in initState; without a mock
    // store that throws a MissingPluginException before the first paint.
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('the profile as it renders', () {
    testWidgets('shows the owner identity and role badge', (tester) async {
      await pumpProfile(tester);
      await tester.pumpAndSettle();

      expect(find.text('Owner'), findsOneWidget);
      expect(find.text('bilal@example.com'), findsOneWidget);
      expect(find.text('VENUE OWNER'), findsOneWidget);
      expect(find.byTooltip('Edit your profile'), findsNothing);
    });

    testWidgets('shows the phone, verified status and role info cards', (
      tester,
    ) async {
      await pumpProfile(tester);
      await tester.pumpAndSettle();

      expect(find.text('+923001234567'), findsOneWidget);
      expect(find.text('Verified & Active ✓'), findsOneWidget);
      expect(find.text('Venue Owner'), findsOneWidget);
    });

    testWidgets('offers the four account actions', (tester) async {
      await pumpProfile(tester);
      await tester.pumpAndSettle();

      expect(find.text('Change Password'), findsOneWidget);
      expect(find.text('Edit Profile'), findsOneWidget);
      expect(find.text('Help & Support'), findsOneWidget);
      expect(find.text('Log Out'), findsOneWidget);
    });
  });

  group('logging out', () {
    testWidgets('the log-out tile raises a confirm dialog', (tester) async {
      await pumpProfile(tester);
      await tester.pumpAndSettle();

      await tapVisible(tester, find.text('Log Out'));
      await tester.pumpAndSettle();

      expect(find.text('Log Out?'), findsOneWidget);
      expect(find.text("Don't ask me again"), findsOneWidget);
    });

    testWidgets('staying dismisses the dialog and navigates nowhere', (
      tester,
    ) async {
      final log = await pumpProfile(tester);
      await tester.pumpAndSettle();

      await tapVisible(tester, find.text('Log Out'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Stay'));
      await tester.pumpAndSettle();

      expect(find.text('Log Out?'), findsNothing);
      expect(log.sawRoute('/welcome'), isFalse);
    });
  });

  group('editing', () {
    testWidgets('the change-password tile opens its sheet', (tester) async {
      await pumpProfile(tester);
      await tester.pumpAndSettle();

      await tapVisible(tester, find.text('Change Password'));
      await tester.pumpAndSettle();

      // The sheet's submit button is unique to it, unlike its title which repeats
      // the tile label behind it.
      expect(
        find.widgetWithText(ElevatedButton, 'Update Password'),
        findsOneWidget,
      );
    });

    testWidgets('the edit-profile tile opens its sheet prefilled', (
      tester,
    ) async {
      await pumpProfile(tester);
      await tester.pumpAndSettle();

      await tapVisible(tester, find.text('Edit Profile'));
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(ElevatedButton, 'Save Changes'),
        findsOneWidget,
      );
      // The edit sheet seeds its fields from AuthProvider.
      expect(find.text('Owner'), findsWidgets);
    });
  });

  group('reach and scale', () {
    testWidgets('dragging down does not move the profile under the header', (
      tester,
    ) async {
      await pumpProfile(tester);
      await tester.pumpAndSettle();
      final identity = tester.getTopLeft(find.text('Owner'));
      final header = tester.getTopLeft(find.text('Profile'));
      await tester.drag(find.text('Owner'), const Offset(0, 280));
      await tester.pumpAndSettle();

      expect(tester.getTopLeft(find.text('Owner')), identity);
      expect(tester.getTopLeft(find.text('Profile')), header);
      expect(find.byType(StretchingOverscrollIndicator), findsNothing);
      expectNoOverflow(tester);
    });

    for (final layout in [
      (const Size(320, 568), 1.0),
      (const Size(390, 844), 1.0),
      (const Size(844, 390), 1.0),
      (const Size(768, 1024), 1.0),
      (const Size(320, 568), 2.0),
      (const Size(430, 915), 2.0),
    ]) {
      testWidgets(
        'identity and editing fit ${layout.$1} at ${layout.$2} text scale',
        (tester) async {
          await pumpProfile(tester, size: layout.$1, textScale: layout.$2);
          await tester.pumpAndSettle();

          expect(find.text('Owner'), findsOneWidget);
          await tapVisible(tester, find.text('Edit Profile'));
          await tester.pumpAndSettle();
          expect(
            find.widgetWithText(ElevatedButton, 'Save Changes'),
            findsOneWidget,
          );
          expectNoOverflow(tester);
        },
      );
    }
  });
}
