// PhoneField: the Pakistani mobile number, the verification badge, and the dev-mode
// shortcut that currently stands in for OTP.
//
// The validator is the part with real rules in it, and all four of its refusals are
// sentences a user acts on: a missing number, a wrong length, a number that is not a
// mobile at all, and a mobile on a network prefix this list does not carry. Each is
// pinned to its own case, because collapsing them into one "invalid number" message is
// the regression that would make the field unusable without changing its behaviour.
//
// Length is enforced twice, deliberately, and the two places do different work. The
// formatters drop non-digits and stop at eleven characters as they are typed, so the
// user cannot produce a wrong-length value by hand; the validator re-checks it because
// a controller can be filled programmatically — from a saved profile, or from a
// registration form restoring its draft — and that path never passes through a
// formatter. Both are asserted.
//
// [AppConfig.devMode] is a compile-time constant and is currently `true`, so `_sendOtp`
// takes the dev branch and the OTP route is unreachable from a test: no navigation
// happens, no code is entered, and the field reports [AppConfig.devFirebaseUid] as a
// verified phone. That is asserted as it stands, together with the flag itself — when
// the flag is turned off for a release build this file fails, and the failure is the
// reminder that the real OTP path has no test yet.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/constants/app_config.dart';
import 'package:sportlynk/widgets/phone_field.dart';

import 'widget_harness.dart';

void main() {
  late TextEditingController controller;
  late GlobalKey<FormState> formKey;
  late List<String> verified;
  late int edits;

  setUp(() {
    controller = TextEditingController();
    formKey = GlobalKey<FormState>();
    verified = <String>[];
    edits = 0;
  });

  tearDown(() => controller.dispose());

  Future<RouteLog> pumpField(WidgetTester tester,
          {bool isVerified = false, double textScale = 1.0}) =>
      pumpApp(
        tester,
        Scaffold(
          body: Form(
            key: formKey,
            child: PhoneField(
              controller: controller,
              isVerified: isVerified,
              onVerified: verified.add,
              onEdit: () => edits++,
            ),
          ),
        ),
        textScale: textScale,
      );
  /// Runs the field's own validator through the form and returns the sentence the
  /// decoration ended up carrying. `TextFormField` copies its own `errorText` onto the
  /// `TextField` it builds, so this reads the message the user sees rather than
  /// scraping the text in the tree.
  Future<String?> validate(WidgetTester tester, String value) async {
    controller.text = value;
    formKey.currentState!.validate();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    return tester.widget<TextField>(find.byType(TextField)).decoration!.errorText;
  }

  group('the field itself', () {
    testWidgets('it asks for an eleven-digit mobile on the phone keypad',
        (tester) async {
      await pumpField(tester);
      expect(find.text('Phone Number *'), findsOneWidget);
      expect(find.text('03XXXXXXXXX'), findsOneWidget);
      expect(find.byIcon(Icons.phone_android), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).keyboardType,
          TextInputType.phone);
    });

    // The formatters are the first of the two length checks: a user cannot type a
    // letter, a dash, or a twelfth digit into this field.
    testWidgets('typing is reduced to at most eleven digits', (tester) async {
      await pumpField(tester);
      await tester.enterText(find.byType(TextField), '0300-1234567abc');
      expect(controller.text, '03001234567');

      await tester.enterText(find.byType(TextField), '030012345678999');
      expect(controller.text, '03001234567');
    });
  });

  group('what the validator refuses', () {
    testWidgets('an empty field names the field rather than the rule',
        (tester) async {
      await pumpField(tester);
      expect(await validate(tester, ''), 'Phone number is required');
      expect(await validate(tester, '   '), 'Phone number is required');
    });

    // Reachable only from a programmatic fill: the formatter makes it unreachable by
    // hand, and a saved profile is not filtered by one.
    testWidgets('a short or long number is counted, not guessed', (tester) async {
      await pumpField(tester);
      expect(await validate(tester, '0300123456'), 'Must be exactly 11 digits');
      expect(await validate(tester, '030012345678'), 'Must be exactly 11 digits');
    });

    testWidgets('a landline is told which prefix a mobile has', (tester) async {
      await pumpField(tester);
      expect(await validate(tester, '04212345678'), 'Must start with 03');
    });

    // 030 to 036 are the networks in service. An 037 number is the right length and
    // starts correctly, so the message has to carry the whole shape.
    testWidgets('an unissued network prefix gets the full form', (tester) async {
      await pumpField(tester);
      expect(await validate(tester, '03701234567'),
          'Enter valid Pakistani mobile number (03XX-XXXXXXX)');
    });

    testWidgets('every network in service is accepted', (tester) async {
      await pumpField(tester);
      for (final prefix in ['030', '031', '032', '033', '034', '035', '036']) {
        expect(await validate(tester, '${prefix}01234567'), isNull,
            reason: 'the $prefix networks are in service');
      }
    });

    // A number restored with the spacing a user would write is still eleven digits.
    testWidgets('whitespace does not count towards the length', (tester) async {
      await pumpField(tester);
      expect(await validate(tester, '0300 123 4567'), isNull);
    });
  });

  group('once the number is verified', () {
    testWidgets('the badge replaces the button and locks the field',
        (tester) async {
      await pumpField(tester, isVerified: true);
      expect(find.text('Verified'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.text('Verify'), findsNothing);
      expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
    });

    // The pencil is the only way back to an editable field, and the form behind it
    // has to hear about that: a registration that kept the old verified uid while the
    // user typed a different number would submit one person's phone under another's
    // verification.
    testWidgets('the pencil unlocks the field and tells the form', (tester) async {
      await pumpField(tester, isVerified: true);
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pump();
      expect(edits, 1);
      expect(find.text('Verified'), findsNothing);
      expect(find.text('Verify'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isFalse);
    });

    // The parent owns the truth once it has a uid, so a rebuild with a new flag has to
    // move the badge; without `didUpdateWidget` the field would keep its first answer.
    testWidgets('a parent that flips the flag is followed', (tester) async {
      await pumpField(tester);
      expect(find.text('Verified'), findsNothing);

      await pumpField(tester, isVerified: true);
      expect(find.text('Verified'), findsOneWidget);
    });
  });

  group('the verify button', () {
    // Pinned as the build behaves. While the flag is on there is no OTP screen, no
    // code, and no navigation: the field simply declares itself verified as a fixed
    // identity. When this expectation fails the flag has been turned off, and the
    // real OTP path — validate, push /otp, accept the returned uid — needs its tests.
    testWidgets('dev mode reports a fixed identity instead of sending a code',
        (tester) async {
      expect(AppConfig.devMode, isTrue,
          reason: 'the OTP path is untested; write it when the flag goes off');
      final log = await pumpField(tester);
      await tester.tap(find.text('Verify'));
      await tester.pump();
      expect(verified, [AppConfig.devFirebaseUid]);
      expect(log.isEmpty, isTrue, reason: 'dev mode must not open /otp');
      expect(find.text('Verified'), findsOneWidget);
    });

    testWidgets('the button is a thumb-sized target beside the field',
        (tester) async {
      await pumpField(tester);
      final button = find.widgetWithText(ElevatedButton, 'Verify');
      expect(sizeOf(tester, button).height, 54);
      expectTapTarget(tester, button);
    });

    testWidgets('the row survives a doubled text scale', (tester) async {
      await pumpField(tester, textScale: 2.0);
      expect(find.text('Verify'), findsOneWidget);
      expectNoOverflow(tester);
    });
  });
}
