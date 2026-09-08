// Password recovery, and the only screen in the app that holds two forms in one route.
//
// `_step` (:19) switches the body between a phone step and a new-password step, both
// inside the same `Form` and the same `Scaffold`. That shape is what the tests below
// are mostly about, because the transition between the two is not a navigation and
// leaves no route to assert on.
//
// Three contracts are pinned.
//
// The first is that the step only advances on a verified code. :88 pushes `/otp` and
// *awaits its result*, and :89 advances only when that result `is String` — the
// Firebase uid the OTP screen pops. A dismissed OTP screen returns null, and the
// screen must stay on step 0 rather than let a caller reset a password for a phone
// number they never proved they hold. The harness's route table renders `/otp` as a
// placeholder, so these tests pop it themselves with the value the real screen would
// return.
//
// The second is that the phone number reaches step 1 unchanged. The reset request
// at :151 sends `_phone.text.trim()` again, from the same controller the first step
// filled — the number the OTP was sent to and the number whose password changes have
// to be one value, and nothing on screen shows the second one.
//
// The third is the password policy at :122. Three separate messages, in a fixed
// order, because "invalid password" tells a user nothing about which rule they broke.
// The confirm field is checked against the controller rather than a captured value
// (:142), so it is asserted after the first field changes as well.
//
// `AuthProvider.resetPassword` is exercised for real here. Unlike `login` it neither
// writes a token to the device nor opens a socket (lib/providers/auth_provider.dart:174),
// so its whole path is safe in a widget test — which is what makes the pinned defect
// at the end of this file assertable rather than theoretical.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/auth/forgot_password_screen.dart';
import 'package:sportlynk/widgets/password_strength_bar.dart';

import '../screen_harness.dart';

/// A 200 whose envelope says the send failed, which is how the backend answers a
/// number that is not registered.
FakeResponse sendRefused(String message) =>
    FakeResponse(200, jsonEncode({'success': false, 'message': message}));

Future<void> submitPhone(
  WidgetTester tester, {
  String phone = '03001234567',
}) async {
  await tester.enterText(find.byType(TextFormField).first, phone);
  await tester.tap(find.widgetWithText(ElevatedButton, 'Send OTP'));
  await tester.pump();
  await settleData(tester);
  await tester.pump(const Duration(milliseconds: 400));
}

/// Pops the placeholder `/otp` route with [uid], which is what the real OTP screen
/// returns once Firebase has verified the code.
Future<void> finishOtp(WidgetTester tester, Object? uid) async {
  tester.firstState<NavigatorState>(find.byType(Navigator)).pop(uid);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Walks the whole first step so a test can start on the password step.
Future<RouteLog> reachPasswordStep(
  WidgetTester tester,
  FakeApi api, {
  String phone = '03001234567',
  Object? uid = 'firebase-uid-1',
}) async {
  api.ok('/auth/forgot-password/send-otp', <String, Object?>{'sent': true});
  final log = await pumpScreen(tester, const ForgotPasswordScreen());
  await submitPhone(tester, phone: phone);
  await finishOtp(tester, uid);
  return log;
}

Future<void> submitNewPassword(
  WidgetTester tester, {
  String password = 'Karachi123',
  String? confirm,
}) async {
  await tester.enterText(find.byType(TextFormField).at(0), password);
  await tester.enterText(find.byType(TextFormField).at(1), confirm ?? password);
  await tester.pump();
  await tester.tap(find.widgetWithText(ElevatedButton, 'Reset Password'));
  await tester.pump();
  await settleData(tester);
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    api.install();
  });

  group('the phone step', () {
    testWidgets('it opens asking for the registered number', (tester) async {
      await pumpScreen(tester, const ForgotPasswordScreen());

      expect(find.text('Forgot Password'), findsOneWidget);
      expect(find.text('Reset Password'), findsOneWidget);
      expect(find.text('Enter your registered phone number'), findsOneWidget);
      expect(find.byIcon(Icons.lock_reset), findsOneWidget);
    });

    testWidgets('the accepted format is shown', (tester) async {
      await pumpScreen(tester, const ForgotPasswordScreen());

      expect(find.text('Phone Number'), findsOneWidget);
      expect(find.text('03XXXXXXXXX'), findsOneWidget);
    });

    testWidgets('the password step is not reachable yet', (tester) async {
      // Both steps live in one `Form`; only one of them may be built at a time or
      // the second field's validator would run against an unfilled controller.
      await pumpScreen(tester, const ForgotPasswordScreen());

      expect(find.text('Create New Password'), findsNothing);
      expect(find.byType(PasswordStrengthBar), findsNothing);
      expect(find.byType(TextFormField), findsOneWidget);
    });

    testWidgets('nothing is fetched before a submission', (tester) async {
      await pumpScreen(tester, const ForgotPasswordScreen());
      await settleData(tester);

      expect(api.requests, isEmpty);
    });

    testWidgets('an empty number is refused without a request', (tester) async {
      await pumpScreen(tester, const ForgotPasswordScreen());

      await tester.tap(find.widgetWithText(ElevatedButton, 'Send OTP'));
      await tester.pump();

      expect(find.text('Enter valid phone (03XXXXXXXXX)'), findsOneWidget);
      expect(api.requests, isEmpty);
    });

    testWidgets('a malformed number is refused without a request',
        (tester) async {
      // An OTP sent to a wrong number is a message the user never receives and a
      // wait they cannot explain.
      await pumpScreen(tester, const ForgotPasswordScreen());
      await submitPhone(tester, phone: '0300123');

      expect(find.text('Enter valid phone (03XXXXXXXXX)'), findsOneWidget);
      expect(api.requests, isEmpty);
    });

    testWidgets('an email is refused here', (tester) async {
      // Unlike the login screen this step takes a phone number only, because the
      // reset is carried by SMS.
      await pumpScreen(tester, const ForgotPasswordScreen());
      await submitPhone(tester, phone: 'bilal@example.com');

      expect(find.text('Enter valid phone (03XXXXXXXXX)'), findsOneWidget);
      expect(api.requests, isEmpty);
    });

    testWidgets('the number is posted trimmed', (tester) async {
      api.ok('/auth/forgot-password/send-otp', <String, Object?>{'sent': true});

      await pumpScreen(tester, const ForgotPasswordScreen());
      await submitPhone(tester, phone: '  03001234567  ');

      final request = api.to('/auth/forgot-password/send-otp').single;
      expect(request.method, 'POST');
      expect(jsonDecode(request.body!), <String, Object?>{
        'phone': '03001234567',
      });
    });

    testWidgets('the button shows progress while the send is out',
        (tester) async {
      api.ok('/auth/forgot-password/send-otp', <String, Object?>{'sent': true},
          delay: const Duration(milliseconds: 400));

      await pumpScreen(tester, const ForgotPasswordScreen());
      await tester.enterText(find.byType(TextFormField).first, '03001234567');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Send OTP'));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Send OTP'), findsNothing);

      await settleData(tester);
      await tester.pump(const Duration(milliseconds: 400));
      await finishOtp(tester, null);
    });

    testWidgets('a second tap cannot send twice', (tester) async {
      api.ok('/auth/forgot-password/send-otp', <String, Object?>{'sent': true},
          delay: const Duration(milliseconds: 400));

      await pumpScreen(tester, const ForgotPasswordScreen());
      await tester.enterText(find.byType(TextFormField).first, '03001234567');
      await tester.tap(find.byType(ElevatedButton));
      await tester.pump();
      await tester.tap(find.byType(ElevatedButton), warnIfMissed: false);
      await tester.pump();

      expect(api.countTo('/auth/forgot-password/send-otp'), 1);

      await settleData(tester);
      await tester.pump(const Duration(milliseconds: 400));
      await finishOtp(tester, null);
    });
  });

  group('when the number cannot be sent to', () {
    testWidgets("the server's reason is shown", (tester) async {
      api.on('/auth/forgot-password/send-otp',
          sendRefused('No account uses that number.'));

      await pumpScreen(tester, const ForgotPasswordScreen());
      await submitPhone(tester);

      expect(find.text('No account uses that number.'), findsOneWidget);
    });

    testWidgets('the OTP screen is not opened', (tester) async {
      // The wait on :88 is what advances the step; opening it for a number that
      // was never sent to would strand the user on a code that cannot arrive.
      api.on('/auth/forgot-password/send-otp',
          sendRefused('No account uses that number.'));

      final log = await pumpScreen(tester, const ForgotPasswordScreen());
      await submitPhone(tester);

      expect(log.sawRoute('/otp'), isFalse);
      expect(find.text('Create New Password'), findsNothing);
    });

    testWidgets('the number is left in the field', (tester) async {
      api.on('/auth/forgot-password/send-otp',
          sendRefused('No account uses that number.'));

      await pumpScreen(tester, const ForgotPasswordScreen());
      await submitPhone(tester);

      expect(find.text('03001234567'), findsOneWidget);
    });

    testWidgets('a dropped connection is reported rather than swallowed',
        (tester) async {
      api.offline('/auth/forgot-password/send-otp');

      final log = await pumpScreen(tester, const ForgotPasswordScreen());
      await submitPhone(tester);

      expect(find.byType(SnackBar), findsOneWidget);
      expect(log.sawRoute('/otp'), isFalse);
    });

    testWidgets('a server error is reported rather than swallowed',
        (tester) async {
      api.fail('/auth/forgot-password/send-otp', 'Something broke.',
          status: 500);

      final log = await pumpScreen(tester, const ForgotPasswordScreen());
      await submitPhone(tester);

      expect(find.text('Something broke.'), findsOneWidget);
      expect(log.sawRoute('/otp'), isFalse);
    });

    testWidgets('the spinner is cleared so the send can be retried',
        (tester) async {
      // :83 clears `_loading` before the branch, which is what leaves the button
      // pressable after a refusal.
      api.on('/auth/forgot-password/send-otp',
          sendRefused('No account uses that number.'));

      await pumpScreen(tester, const ForgotPasswordScreen());
      await submitPhone(tester);

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Send OTP'), findsOneWidget);
    });

    // Pinned as it behaves, not as it should.
    // lib/screens/auth/forgot_password_screen.dart:85 falls back to 'Phone not found'
    // when the body carries no message, but `ApiClient._decode`
    // (lib/services/api_service.dart:219) fills `message` from the status code
    // whenever `success` is not true — so the fallback is unreachable and a 200 with
    // no message shows the generic sentence below instead of the specific one the
    // screen intended. The fix is to drop the dead fallback or to answer with a real
    // message on the server.
    testWidgets('a refusal with no message shows the generic sentence',
        (tester) async {
      api.on('/auth/forgot-password/send-otp',
          FakeResponse(200, jsonEncode({'success': false})));

      await pumpScreen(tester, const ForgotPasswordScreen());
      await submitPhone(tester);

      expect(find.text('Unexpected response from the server.'), findsOneWidget);
      expect(find.text('Phone not found'), findsNothing);
    });
  });

  group('handing off to the OTP screen', () {
    testWidgets('it is opened once the send succeeds', (tester) async {
      api.ok('/auth/forgot-password/send-otp', <String, Object?>{'sent': true});

      final log = await pumpScreen(tester, const ForgotPasswordScreen());
      await submitPhone(tester);

      expect(log.sawRoute('/otp'), isTrue);

      await finishOtp(tester, null);
    });

    testWidgets('it is handed the number the OTP was sent to', (tester) async {
      // `OtpScreen` sends nothing unless it is given a non-empty string
      // (lib/screens/auth/otp_screen.dart:47), so a push with the wrong argument
      // fails on the next screen rather than this one.
      api.ok('/auth/forgot-password/send-otp', <String, Object?>{'sent': true});

      final log = await pumpScreen(tester, const ForgotPasswordScreen());
      await submitPhone(tester, phone: '  03009998877  ');

      expect(log.argumentsFor('/otp'), '03009998877');

      await finishOtp(tester, null);
    });

    testWidgets('a verified code advances to the password step', (tester) async {
      await reachPasswordStep(tester, api);

      expect(find.text('Create New Password'), findsOneWidget);
      expect(find.byIcon(Icons.lock_open), findsOneWidget);
    });

    testWidgets('a dismissed OTP screen does not advance', (tester) async {
      // :89 — without a uid there is nothing to prove the number was held, and the
      // reset endpoint would refuse it anyway.
      await reachPasswordStep(tester, api, uid: null);

      expect(find.text('Create New Password'), findsNothing);
      expect(find.text('Enter your registered phone number'), findsOneWidget);
    });

    testWidgets('a non-string result does not advance', (tester) async {
      await reachPasswordStep(tester, api, uid: false);

      expect(find.text('Create New Password'), findsNothing);
    });

    testWidgets('the phone step can be retried after a dismissal',
        (tester) async {
      await reachPasswordStep(tester, api, uid: null);
      await submitPhone(tester);

      expect(api.countTo('/auth/forgot-password/send-otp'), 2);

      await finishOtp(tester, null);
    });
  });

  group('the password step', () {
    testWidgets('both fields are asked for', (tester) async {
      await reachPasswordStep(tester, api);

      expect(find.text('New Password *'), findsOneWidget);
      expect(find.text('Confirm Password *'), findsOneWidget);
      expect(find.byType(TextFormField), findsNWidgets(2));
    });

    testWidgets('the phone step is gone', (tester) async {
      await reachPasswordStep(tester, api);

      expect(find.text('Phone Number'), findsNothing);
      expect(find.text('Send OTP'), findsNothing);
    });

    testWidgets('both passwords are hidden until asked for', (tester) async {
      await reachPasswordStep(tester, api);

      expect(find.byIcon(Icons.visibility_off), findsNWidgets(2));
    });

    testWidgets('each field reveals independently', (tester) async {
      // Two separate flags (:24): revealing the confirmation to check a typo must
      // not also expose the password above it.
      await reachPasswordStep(tester, api);

      await tester.tap(find.byIcon(Icons.visibility_off).first);
      await tester.pump();

      expect(find.byIcon(Icons.visibility), findsOneWidget);
      expect(find.byIcon(Icons.visibility_off), findsOneWidget);
    });

    testWidgets('a short password is refused with the length rule',
        (tester) async {
      await reachPasswordStep(tester, api);
      await submitNewPassword(tester, password: 'Abc1');

      expect(find.text('Min 8 characters').last, findsOneWidget);
      expect(api.to('/auth/forgot-password/reset'), isEmpty);
    });

    testWidgets('a long lowercase password is refused with the case rule',
        (tester) async {
      // The rules are reported one at a time in a fixed order (:123), so a user
      // fixing them does not have to guess which one is next.
      await reachPasswordStep(tester, api);
      await submitNewPassword(tester, password: 'karachi123');

      expect(find.text('Add uppercase letter').last, findsOneWidget);
      expect(find.text('Min 8 characters'), findsNothing);
      expect(api.to('/auth/forgot-password/reset'), isEmpty);
    });

    testWidgets('a password with no digit is refused with the digit rule',
        (tester) async {
      await reachPasswordStep(tester, api);
      await submitNewPassword(tester, password: 'KarachiCity');

      expect(find.text('Add a number'), findsOneWidget);
      expect(api.to('/auth/forgot-password/reset'), isEmpty);
    });

    testWidgets('a mismatched confirmation is refused', (tester) async {
      await reachPasswordStep(tester, api);
      await submitNewPassword(tester,
          password: 'Karachi123', confirm: 'Karachi124');

      expect(find.text('Passwords do not match'), findsOneWidget);
      expect(api.to('/auth/forgot-password/reset'), isEmpty);
    });

    testWidgets('an empty confirmation is refused', (tester) async {
      await reachPasswordStep(tester, api);
      await submitNewPassword(tester, password: 'Karachi123', confirm: '');

      expect(find.text('Passwords do not match'), findsOneWidget);
      expect(api.to('/auth/forgot-password/reset'), isEmpty);
    });
  });

  group('the strength meter', () {
    testWidgets('it says nothing until something is typed', (tester) async {
      await reachPasswordStep(tester, api);

      expect(find.byType(PasswordStrengthBar), findsOneWidget);
      expect(find.text('Weak'), findsNothing);
      expect(find.text('8+ chars'), findsNothing);
    });

    testWidgets('a one-rule password reads as weak', (tester) async {
      await reachPasswordStep(tester, api);

      await tester.enterText(find.byType(TextFormField).at(0), 'abc');
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Weak'), findsOneWidget);
    });

    testWidgets('a long lowercase password reads as fair', (tester) async {
      await reachPasswordStep(tester, api);

      await tester.enterText(find.byType(TextFormField).at(0), 'abcdefgh');
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Fair'), findsOneWidget);
    });

    testWidgets('a password that passes the policy reads as good',
        (tester) async {
      // The meter and the validator are separate rules, and this is the pair that
      // matters: the weakest password the form will accept must not read as strong.
      await reachPasswordStep(tester, api);

      await tester.enterText(find.byType(TextFormField).at(0), 'Karachi123');
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Good'), findsOneWidget);
      expect(find.text('Strong'), findsNothing);
    });

    testWidgets('a long password with a symbol reads as strong',
        (tester) async {
      await reachPasswordStep(tester, api);

      await tester.enterText(find.byType(TextFormField).at(0), 'Karachi123!abc');
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Strong'), findsOneWidget);
    });

    testWidgets('every rule is listed once typing starts', (tester) async {
      // The list is the only place the policy is stated in full; the validator
      // reveals one rule at a time and only after a submission.
      await reachPasswordStep(tester, api);

      await tester.enterText(find.byType(TextFormField).at(0), 'K');
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('8+ chars'), findsOneWidget);
      expect(find.text('A-Z'), findsOneWidget);
      expect(find.text('a-z'), findsOneWidget);
      expect(find.text('0-9'), findsOneWidget);
      expect(find.text('!@#'), findsOneWidget);
      expect(find.text('12+ chars'), findsOneWidget);
    });

    testWidgets('it tracks the field rather than the submission', (tester) async {
      await reachPasswordStep(tester, api);

      await tester.enterText(find.byType(TextFormField).at(0), 'abc');
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Weak'), findsOneWidget);

      await tester.enterText(find.byType(TextFormField).at(0), 'Karachi123!abc');
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Weak'), findsNothing);
      expect(find.text('Strong'), findsOneWidget);
    });

    testWidgets('it is not shown on the phone step', (tester) async {
      await pumpScreen(tester, const ForgotPasswordScreen());

      expect(find.byType(PasswordStrengthBar), findsNothing);
    });
  });

  group('resetting', () {
    testWidgets('the number, the password and the uid are posted',
        (tester) async {
      // The uid is the OTP screen's only output and the server's only evidence the
      // number was held; a reset that posted without it would be an open door.
      await reachPasswordStep(tester, api, phone: '  03009998877  ');
      api.ok('/auth/forgot-password/reset', <String, Object?>{'reset': true});
      await submitNewPassword(tester, password: 'Karachi123');

      final request = api.to('/auth/forgot-password/reset').single;
      expect(request.method, 'POST');
      expect(jsonDecode(request.body!), <String, Object?>{
        'phone': '03009998877',
        'newPassword': 'Karachi123',
        'firebaseUid': 'firebase-uid-1',
      });
    });

    testWidgets('the password is posted untrimmed', (tester) async {
      // :151 trims the phone number and not the password, which is correct: a space
      // the user chose is part of the secret.
      await reachPasswordStep(tester, api);
      api.ok('/auth/forgot-password/reset', <String, Object?>{'reset': true});
      await submitNewPassword(tester, password: ' Karachi123 ');

      final sent =
          jsonDecode(api.to('/auth/forgot-password/reset').single.body!) as Map;
      expect(sent['newPassword'], ' Karachi123 ');
    });

    testWidgets('the button shows progress while the reset is out',
        (tester) async {
      await reachPasswordStep(tester, api);
      api.ok('/auth/forgot-password/reset', <String, Object?>{'reset': true},
          delay: const Duration(milliseconds: 400));

      await tester.enterText(find.byType(TextFormField).at(0), 'Karachi123');
      await tester.enterText(find.byType(TextFormField).at(1), 'Karachi123');
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Reset Password'));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await settleData(tester);
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('success is confirmed and the session starts over',
        (tester) async {
      // The old password is gone and no token was issued, so the only sensible
      // destination is the login screen — and :155 removes everything behind it so
      // the two-step form cannot be walked back into.
      final log = await reachPasswordStep(tester, api);
      api.ok('/auth/forgot-password/reset', <String, Object?>{'reset': true});
      await submitNewPassword(tester);

      expect(find.text('Password changed successfully!'), findsOneWidget);
      expect(log.sawRoute('/login'), isTrue);
    });

    testWidgets('a refusal keeps the form where it is', (tester) async {
      final log = await reachPasswordStep(tester, api);
      api.fail('/auth/forgot-password/reset', 'That code has expired.',
          status: 400);
      await submitNewPassword(tester);

      expect(log.sawRoute('/login'), isFalse);
      expect(find.text('Create New Password'), findsOneWidget);
    });

    testWidgets('a dropped connection does not report success', (tester) async {
      final log = await reachPasswordStep(tester, api);
      api.offline('/auth/forgot-password/reset');
      await submitNewPassword(tester);

      expect(find.text('Password changed successfully!'), findsNothing);
      expect(log.sawRoute('/login'), isFalse);
    });

    // Pinned as it behaves, not as it should.
    // lib/providers/auth_provider.dart:174 returns `response['success'] == true`
    // without copying `response['message']` into `_errorMessage`, so
    // forgot_password_screen.dart:157 falls back to 'Reset failed' and the server's
    // actual reason — an expired code, a password the server rejected — is dropped
    // on the floor. The fix is to set `_errorMessage` on the failure branch of
    // `resetPassword`, the way `login` already does.
    testWidgets("the server's reason is replaced by a generic failure",
        (tester) async {
      await reachPasswordStep(tester, api);
      api.fail('/auth/forgot-password/reset', 'That code has expired.',
          status: 400);
      await submitNewPassword(tester);

      expect(find.text('Reset failed'), findsOneWidget);
      expect(find.text('That code has expired.'), findsNothing);
    });
  });

  group('reach and scale', () {
    testWidgets('the send button is large enough to hit', (tester) async {
      await pumpScreen(tester, const ForgotPasswordScreen());

      expectTapTarget(tester, find.byType(ElevatedButton));
    });

    testWidgets('the reset button is large enough to hit', (tester) async {
      await reachPasswordStep(tester, api);

      expectTapTarget(tester, find.byType(ElevatedButton));
    });

    testWidgets('the phone step does not clip at a doubled text scale',
        (tester) async {
      await pumpScreen(tester, const ForgotPasswordScreen(), textScale: 2.0);

      expectNoOverflow(tester);
    });

    testWidgets('the phone step lays out on a short screen', (tester) async {
      await pumpScreen(tester, const ForgotPasswordScreen(),
          size: const Size(360, 640));

      expect(find.text('Reset Password'), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('the password step is still usable at a doubled text scale',
        (tester) async {
      api.ok('/auth/forgot-password/send-otp', <String, Object?>{'sent': true});

      await pumpScreen(tester, const ForgotPasswordScreen(), textScale: 2.0);
      await submitPhone(tester);
      await finishOtp(tester, 'firebase-uid-1');

      expect(find.text('New Password *'), findsOneWidget);
      expect(find.byType(TextFormField), findsNWidgets(2));
    });
  });
}
