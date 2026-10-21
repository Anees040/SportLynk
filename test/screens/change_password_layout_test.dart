import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/owner/owner_profile_screen.dart';
import 'package:sportlynk/screens/player/player_profile_screen.dart';

import 'screen_harness.dart';

void main() {
  for (final owner in [false, true]) {
    final role = owner ? 'owner' : 'player';
    for (final layout in [
      (size: const Size(360, 800), keyboard: 340.0, scale: 1.0),
      (size: const Size(320, 568), keyboard: 280.0, scale: 1.0),
      (size: const Size(844, 390), keyboard: 190.0, scale: 1.0),
      (size: const Size(390, 844), keyboard: 340.0, scale: 1.5),
    ]) {
      testWidgets('$role password errors remain usable at ${layout.size}, '
          '${layout.scale} text scale with keyboard', (tester) async {
        final api = FakeApi()..install();
        api.ok('/users/me/player', {
          'name': 'Bilal Ahmed',
          'email': 'bilal@example.com',
          'elo_rating': 1200,
          'trust_score': 92,
          'sport_preferences': ['Football'],
        });
        await pumpScreen(
          tester,
          owner ? const OwnerProfileScreen() : const PlayerProfileScreen(),
          auth: FakeAuth(role: role, token: 'test-token'),
        );
        await settleData(tester);
        await tapVisible(tester, find.text('Change Password'));
        await tester.pumpAndSettle();

        // Apply device metrics to the whole app, including the modal route.
        tester.view.physicalSize = layout.size;
        tester.platformDispatcher.textScaleFactorTestValue = layout.scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpAndSettle();

        final fields = find.descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(TextField),
        );
        final submit = find.widgetWithText(
          ElevatedButton,
          owner ? 'Update Password' : 'Change Password',
        );
        await tester.enterText(fields.at(0), 'CurrentPassword1');
        await tester.enterText(fields.at(1), 'PasswordWithoutNumbers');
        await tester.enterText(fields.at(2), 'PasswordWithoutNumbers');
        await tester.pumpAndSettle();
        await tapVisible(tester, submit);
        await tester.pumpAndSettle();
        const error = 'Password must contain at least one number.';
        expect(find.text(error), findsOneWidget);
        expectNoOverflow(tester);

        // Reopening the keyboard while an error is present caused the overflow.
        await tapVisible(tester, fields.at(2));
        tester.view.viewInsets = FakeViewPadding(bottom: layout.keyboard);
        await tester.pumpAndSettle();
        expectNoOverflow(tester);
        expect(find.text(error), findsOneWidget);

        final keyboardTop = layout.size.height - layout.keyboard;
        for (final target in [
          fields.at(0),
          find.text(error),
          fields.at(2),
          submit,
        ]) {
          await tester.ensureVisible(target);
          await tester.pumpAndSettle();
          final bounds = tester.getRect(target);
          expect(bounds.top, greaterThanOrEqualTo(0));
          expect(bounds.bottom, lessThanOrEqualTo(keyboardTop));
          expect(target.hitTestable(), findsOneWidget);
        }

        // Validation can also insert a new error while the keyboard stays up.
        await tester.enterText(fields.at(1), 'lowercasepassword');
        await tester.enterText(fields.at(2), 'lowercasepassword');
        await tester.pumpAndSettle();
        expect(find.text(error), findsNothing);
        await tapVisible(tester, submit);
        await tester.pumpAndSettle();
        expect(
          find.text('Password must contain at least one uppercase letter.'),
          findsOneWidget,
        );
        expectNoOverflow(tester);

        tester.view.viewInsets = const FakeViewPadding();
        await tester.pumpAndSettle();
        await tester.ensureVisible(submit);
        await tester.pumpAndSettle();
        expect(submit.hitTestable(), findsOneWidget);
        expectNoOverflow(tester);
      });
    }
  }
}
