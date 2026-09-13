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

Future<RouteLog> pumpProfile(WidgetTester tester, {double textScale = 1.0}) {
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

      await tester.tap(find.text('Log Out'));
      await tester.pumpAndSettle();

      expect(find.text('Log Out?'), findsOneWidget);
      expect(find.text("Don't ask me again"), findsOneWidget);
    });

    testWidgets('staying dismisses the dialog and navigates nowhere', (
      tester,
    ) async {
      final log = await pumpProfile(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Log Out'));
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

      await tester.tap(find.text('Change Password'));
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

      await tester.tap(find.text('Edit Profile'));
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
    testWidgets('a doubled text scale keeps the identity present', (
      tester,
    ) async {
      ignoreOverflow();
      await pumpProfile(tester, textScale: 2.0);
      await tester.pumpAndSettle();

      expect(find.text('Owner'), findsOneWidget);
    });
  });
}
