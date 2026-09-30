// Password recovery, and the only screen in the app that holds two forms in one route.
//
// `_step` switches the body between a phone step and a code-and-password step, both
// inside the same `Form` and the same `Scaffold`. That shape is what the tests below
// are mostly about, because the transition between the two is not a navigation and
// leaves no route to assert on: the step advances when the server accepts the phone
// and issues a reset code, not when a second screen pops a result.
//
// Three contracts are pinned.
//
// The first is that the step only advances on a code the server actually sent. A
// refused or unreachable send leaves the user on the phone step rather than on a code
// field that can never be satisfied, and the reset request carries the six-digit code
// the SMS delivered — the server's own proof the caller holds the number. This is the
// security fix: the earlier design trusted a client-supplied uid and let anyone reset
// any account by phone number, so no test here may reintroduce a trusted client value.
//
// The second is that the phone number reaches the reset request unchanged. Both the
// send and the reset read `_phone.text.trim()` from the same controller the first step
// filled — the number the code was sent to and the number whose password changes have
// to be one value, and nothing on screen shows the second one.
//
// The third is the password policy. Three separate messages, in a fixed order, because
// "invalid password" tells a user nothing about which rule they broke. The confirm
// field is checked against the controller rather than a captured value, so it is
// asserted after the first field changes as well.
//
// `AuthProvider.resetPassword` is exercised for real here. Unlike `login` it neither
// writes a token to the device nor opens a socket, so its whole path is safe in a
// widget test — which is what lets the last group assert that the server's reason for a
// refusal (an expired code, a password the server rejected) reaches the user rather
// than being flattened to a generic sentence.

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

/// Enters a phone number and taps Send Code. A successful send advances to the code
/// step; a refused or dropped one leaves the screen on the phone step.
Future<void> submitPhone(
  WidgetTester tester, {
  String phone = '03001234567',
}) async {
  await tester.enterText(find.byType(TextFormField).first, phone);
  await tester.tap(find.widgetWithText(ElevatedButton, 'Send Code'));
  await tester.pump();
  await settleData(tester);
  await tester.pump(const Duration(milliseconds: 400));
}

/// Walks the phone step with a successful send so a test can start on the code step,
/// where the code and the new password are entered.
Future<RouteLog> reachCodeStep(
  WidgetTester tester,
  FakeApi api, {
  String phone = '03001234567',
}) async {
  api.ok('/auth/forgot-password/send-otp', <String, Object?>{'sent': true});
  final log = await pumpScreen(tester, const ForgotPasswordScreen());
  await submitPhone(tester, phone: phone);
  return log;
}

/// Fills the code step and taps Reset Password. The three fields are, in order, the
/// verification code, the new password, and its confirmation.
Future<void> submitReset(
  WidgetTester tester, {
  String code = '123456',
  String password = 'Karachi123',
  String? confirm,
}) async {
  // The success snackbar from the send step floats over the bottom of the form on the
  // code step; left up, it sits over the Reset Password button and swallows the tap.
  // Let its timer run out and its exit finish so the button beneath is hittable.
  await tester.pump(const Duration(seconds: 3));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.enterText(find.byType(TextFormField).at(0), code);
  await tester.enterText(find.byType(TextFormField).at(1), password);
  await tester.enterText(find.byType(TextFormField).at(2), confirm ?? password);
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

    testWidgets('the code step is not reachable yet', (tester) async {
      // Both steps live in one `Form`; only one of them is built at a time, so the
      // code and password validators never run against unfilled controllers.
      await pumpScreen(tester, const ForgotPasswordScreen());

      expect(find.text('Verify & Reset'), findsNothing);
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

      await tester.tap(find.widgetWithText(ElevatedButton, 'Send Code'));
      await tester.pump();

      expect(find.text('Enter valid phone (03XXXXXXXXX)'), findsOneWidget);
      expect(api.requests, isEmpty);
    });

    testWidgets('a malformed number is refused without a request',
        (tester) async {
      // A code sent to a wrong number is a message the user never receives and a
      // wait they cannot explain.
      await pumpScreen(tester, const ForgotPasswordScreen());
      await submitPhone(tester, phone: '0300123');

      expect(find.text('Enter valid phone (03XXXXXXXXX)'), findsOneWidget);
      expect(api.requests, isEmpty);
    });

    testWidgets('an email is refused here', (tester) async {
      // Unlike the login screen this step takes a phone number only, because the
      // reset is carried by SMS and an optional email cannot receive the code.
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
      await tester.tap(find.widgetWithText(ElevatedButton, 'Send Code'));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Send Code'), findsNothing);

      await settleData(tester);
      await tester.pump(const Duration(milliseconds: 400));
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

    testWidgets('the code step is not opened', (tester) async {
      // Advancing for a number that was never sent to would strand the user on a
      // code field that no SMS can satisfy.
      api.on('/auth/forgot-password/send-otp',
          sendRefused('No account uses that number.'));

      await pumpScreen(tester, const ForgotPasswordScreen());
      await submitPhone(tester);

      expect(find.text('Verify & Reset'), findsNothing);
      expect(find.text('Enter your registered phone number'), findsOneWidget);
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

      await pumpScreen(tester, const ForgotPasswordScreen());
      await submitPhone(tester);

      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text('Enter your registered phone number'), findsOneWidget);
    });

    testWidgets('a server error is reported rather than swallowed',
        (tester) async {
      api.fail('/auth/forgot-password/send-otp', 'Something broke.',
          status: 500);

      await pumpScreen(tester, const ForgotPasswordScreen());
      await submitPhone(tester);

      expect(find.text('Something broke.'), findsOneWidget);
      expect(find.text('Verify & Reset'), findsNothing);
    });

    testWidgets('the spinner is cleared so the send can be retried',
        (tester) async {
      // `_sendCode` clears `_loading` before the failure branch, which is what
      // leaves the button pressable after a refusal.
      api.on('/auth/forgot-password/send-otp',
          sendRefused('No account uses that number.'));

      await pumpScreen(tester, const ForgotPasswordScreen());
      await submitPhone(tester);

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Send Code'), findsOneWidget);
    });

    // Pinned as it behaves, not as it should.
    // `_sendCode` falls back to 'Could not send the code. Please try again.' when the
    // body carries no message, but `ApiClient._decode` fills `message` from the status
    // code whenever `success` is not true — so the fallback is unreachable and a 200
    // with no message shows the generic sentence below. The real backend always
    // answers with a reason, so this is only reached by a malformed response; the fix,
    // if wanted, is to drop the dead fallback rather than to add a guard here.
    testWidgets('a refusal with no message shows the generic sentence',
        (tester) async {
      api.on('/auth/forgot-password/send-otp',
          FakeResponse(200, jsonEncode({'success': false})));

      await pumpScreen(tester, const ForgotPasswordScreen());
      await submitPhone(tester);

      expect(find.text('Unexpected response from the server.'), findsOneWidget);
      expect(find.text('Could not send the code. Please try again.'),
          findsNothing);
    });
  });

  group('reaching the code step', () {
    testWidgets('a successful send reveals the code step', (tester) async {
      await reachCodeStep(tester, api);

      expect(find.text('Verify & Reset'), findsOneWidget);
      expect(find.text('Verification Code *'), findsOneWidget);
      expect(find.byIcon(Icons.lock_open), findsOneWidget);
    });

    testWidgets('a successful send tells the user the code is on its way',
        (tester) async {
      await reachCodeStep(tester, api);

      expect(find.text('A verification code has been sent to your phone.'),
          findsOneWidget);
    });

    testWidgets('the phone step can be retried after a failed send',
        (tester) async {
      api.on('/auth/forgot-password/send-otp',
          sendRefused('No account uses that number.'));
      await pumpScreen(tester, const ForgotPasswordScreen());
      await submitPhone(tester);

      expect(find.text('Verify & Reset'), findsNothing);

      api.ok('/auth/forgot-password/send-otp', <String, Object?>{'sent': true});
      await submitPhone(tester);

      expect(api.countTo('/auth/forgot-password/send-otp'), 2);
      expect(find.text('Verify & Reset'), findsOneWidget);
    });
  });

  group('the code step', () {
    testWidgets('all three fields are asked for', (tester) async {
      await reachCodeStep(tester, api);

      expect(find.text('Verification Code *'), findsOneWidget);
      expect(find.text('New Password *'), findsOneWidget);
      expect(find.text('Confirm Password *'), findsOneWidget);
      expect(find.byType(TextFormField), findsNWidgets(3));
    });

    testWidgets('the phone step is gone', (tester) async {
      await reachCodeStep(tester, api);

      expect(find.text('Phone Number'), findsNothing);
      expect(find.text('Send Code'), findsNothing);
    });

    testWidgets('both passwords are hidden until asked for', (tester) async {
      // Only the two password fields carry a reveal toggle; the code is not a secret.
      await reachCodeStep(tester, api);

      expect(find.byIcon(Icons.visibility_off), findsNWidgets(2));
    });

    testWidgets('each password field reveals independently', (tester) async {
      // Two separate flags: revealing the confirmation to check a typo must not also
      // expose the password above it.
      await reachCodeStep(tester, api);

      await tester.tap(find.byIcon(Icons.visibility_off).first);
      await tester.pump();

      expect(find.byIcon(Icons.visibility), findsOneWidget);
      expect(find.byIcon(Icons.visibility_off), findsOneWidget);
    });

    testWidgets('an empty code is refused without a reset request',
        (tester) async {
      // The code is the server's only proof the caller holds the number; a reset
      // must not be attempted without one. The field's hint and its validator carry
      // the same sentence, so a refused empty field shows it twice — the placeholder
      // and the error beneath it — which is also how the refusal is told apart from a
      // tap that never landed.
      await reachCodeStep(tester, api);
      await submitReset(tester, code: '');

      expect(find.text('Enter the 6-digit code'), findsNWidgets(2));
      expect(api.to('/auth/forgot-password/reset'), isEmpty);
    });

    testWidgets('a code shorter than six digits is refused without a request',
        (tester) async {
      // Six digits exactly; the placeholder and the validator share the sentence, so
      // the refused field carries it twice.
      await reachCodeStep(tester, api);
      await submitReset(tester, code: '123');

      expect(find.text('Enter the 6-digit code'), findsNWidgets(2));
      expect(api.to('/auth/forgot-password/reset'), isEmpty);
    });

    testWidgets('a short password is refused with the length rule',
        (tester) async {
      await reachCodeStep(tester, api);
      await submitReset(tester, password: 'Abc1');

      expect(find.text('Min 8 characters').last, findsOneWidget);
      expect(api.to('/auth/forgot-password/reset'), isEmpty);
    });

    testWidgets('a long lowercase password is refused with the case rule',
        (tester) async {
      // The rules are reported one at a time in a fixed order, so a user fixing them
      // does not have to guess which one is next.
      await reachCodeStep(tester, api);
      await submitReset(tester, password: 'karachi123');

      expect(find.text('Add uppercase letter').last, findsOneWidget);
      expect(find.text('Min 8 characters'), findsNothing);
      expect(api.to('/auth/forgot-password/reset'), isEmpty);
    });

    testWidgets('a password with no digit is refused with the digit rule',
        (tester) async {
      await reachCodeStep(tester, api);
      await submitReset(tester, password: 'KarachiCity');

      expect(find.text('Add a number'), findsOneWidget);
      expect(api.to('/auth/forgot-password/reset'), isEmpty);
    });

    testWidgets('a mismatched confirmation is refused', (tester) async {
      await reachCodeStep(tester, api);
      await submitReset(tester, password: 'Karachi123', confirm: 'Karachi124');

      expect(find.text('Passwords do not match'), findsOneWidget);
      expect(api.to('/auth/forgot-password/reset'), isEmpty);
    });

    testWidgets('an empty confirmation is refused', (tester) async {
      await reachCodeStep(tester, api);
      await submitReset(tester, password: 'Karachi123', confirm: '');

      expect(find.text('Passwords do not match'), findsOneWidget);
      expect(api.to('/auth/forgot-password/reset'), isEmpty);
    });
  });

  group('resending the code', () {
    testWidgets('the code can be resent without leaving the step',
        (tester) async {
      await reachCodeStep(tester, api);

      await tester.tap(find.text('Resend code'));
      await tester.pump();
      await settleData(tester);
      await tester.pump(const Duration(milliseconds: 400));

      expect(api.countTo('/auth/forgot-password/send-otp'), 2);
      expect(find.text('Verify & Reset'), findsOneWidget);
    });

    testWidgets('resending does not require the code field to be filled',
        (tester) async {
      // Resend reuses the send path without validating the form, so a user who has
      // not yet typed a code can still ask for a fresh one: the send fires a second
      // time and no reset is attempted. The code field's hint reads the same as its
      // validator error, so the send count and the absent reset are what distinguish a
      // resend from a submission here.
      await reachCodeStep(tester, api);

      await tester.tap(find.text('Resend code'));
      await tester.pump();
      await settleData(tester);
      await tester.pump(const Duration(milliseconds: 400));

      expect(api.countTo('/auth/forgot-password/send-otp'), 2);
      expect(api.to('/auth/forgot-password/reset'), isEmpty);
    });
  });

  group('the strength meter', () {
    testWidgets('it says nothing until something is typed', (tester) async {
      await reachCodeStep(tester, api);

      expect(find.byType(PasswordStrengthBar), findsOneWidget);
      expect(find.text('Weak'), findsNothing);
      expect(find.text('8+ chars'), findsNothing);
    });

    testWidgets('a one-rule password reads as weak', (tester) async {
      await reachCodeStep(tester, api);

      await tester.enterText(find.byType(TextFormField).at(1), 'abc');
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Weak'), findsOneWidget);
    });

    testWidgets('a long lowercase password reads as fair', (tester) async {
      await reachCodeStep(tester, api);

      await tester.enterText(find.byType(TextFormField).at(1), 'abcdefgh');
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Fair'), findsOneWidget);
    });

    testWidgets('a password that passes the policy reads as good',
        (tester) async {
      // The meter and the validator are separate rules, and this is the pair that
      // matters: the weakest password the form will accept must not read as strong.
      await reachCodeStep(tester, api);

      await tester.enterText(find.byType(TextFormField).at(1), 'Karachi123');
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Good'), findsOneWidget);
      expect(find.text('Strong'), findsNothing);
    });

    testWidgets('a long password with a symbol reads as strong',
        (tester) async {
      await reachCodeStep(tester, api);

      await tester.enterText(
          find.byType(TextFormField).at(1), 'Karachi123!abc');
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Strong'), findsOneWidget);
    });

    testWidgets('every rule is listed once typing starts', (tester) async {
      // The list is the only place the policy is stated in full; the validator
      // reveals one rule at a time and only after a submission.
      await reachCodeStep(tester, api);

      await tester.enterText(find.byType(TextFormField).at(1), 'K');
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('8+ chars'), findsOneWidget);
      expect(find.text('A-Z'), findsOneWidget);
      expect(find.text('a-z'), findsOneWidget);
      expect(find.text('0-9'), findsOneWidget);
      expect(find.text('!@#'), findsOneWidget);
      expect(find.text('12+ chars'), findsOneWidget);
    });

    testWidgets('it tracks the field rather than the submission',
        (tester) async {
      await reachCodeStep(tester, api);

      await tester.enterText(find.byType(TextFormField).at(1), 'abc');
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Weak'), findsOneWidget);

      await tester.enterText(
          find.byType(TextFormField).at(1), 'Karachi123!abc');
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
    testWidgets('the number, the code and the password are posted',
        (tester) async {
      // The code is the server's evidence the number was held; there is no client
      // uid in this body, which is the vulnerability that was closed.
      await reachCodeStep(tester, api, phone: '  03009998877  ');
      api.ok('/auth/forgot-password/reset', <String, Object?>{'reset': true});
      await submitReset(tester, code: '123456', password: 'Karachi123');

      final request = api.to('/auth/forgot-password/reset').single;
      expect(request.method, 'POST');
      expect(jsonDecode(request.body!), <String, Object?>{
        'phone': '03009998877',
        'code': '123456',
        'newPassword': 'Karachi123',
      });
    });

    testWidgets('the password is posted untrimmed', (tester) async {
      // The reset trims the phone number and not the password: a space the user
      // chose is part of the secret.
      await reachCodeStep(tester, api);
      api.ok('/auth/forgot-password/reset', <String, Object?>{'reset': true});
      await submitReset(tester, password: ' Karachi123 ');

      final sent =
          jsonDecode(api.to('/auth/forgot-password/reset').single.body!) as Map;
      expect(sent['newPassword'], ' Karachi123 ');
    });

    testWidgets('the button shows progress while the reset is out',
        (tester) async {
      await reachCodeStep(tester, api);
      api.ok('/auth/forgot-password/reset', <String, Object?>{'reset': true},
          delay: const Duration(milliseconds: 400));

      // Clear the send-step snackbar first, as `submitReset` does, so the tap lands.
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(find.byType(TextFormField).at(0), '123456');
      await tester.enterText(find.byType(TextFormField).at(1), 'Karachi123');
      await tester.enterText(find.byType(TextFormField).at(2), 'Karachi123');
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
      // destination is the login screen, and the reset removes everything behind it
      // so the two-step form cannot be walked back into.
      final log = await reachCodeStep(tester, api);
      api.ok('/auth/forgot-password/reset', <String, Object?>{'reset': true});
      await submitReset(tester);

      expect(find.text('Password changed successfully!'), findsOneWidget);
      expect(log.sawRoute('/login'), isTrue);
    });

    testWidgets('a refusal keeps the form where it is', (tester) async {
      final log = await reachCodeStep(tester, api);
      api.fail('/auth/forgot-password/reset', 'That code has expired.',
          status: 400);
      await submitReset(tester);

      expect(log.sawRoute('/login'), isFalse);
      expect(find.text('Verify & Reset'), findsOneWidget);
    });

    testWidgets('a dropped connection does not report success', (tester) async {
      final log = await reachCodeStep(tester, api);
      api.offline('/auth/forgot-password/reset');
      await submitReset(tester);

      expect(find.text('Password changed successfully!'), findsNothing);
      expect(log.sawRoute('/login'), isFalse);
    });

    testWidgets("the server's reason reaches the user", (tester) async {
      // `AuthProvider.resetPassword` copies `response['message']` into `errorMessage`
      // on failure, the way `login` does, so an expired code or a password the server
      // rejected is shown rather than flattened to a generic 'Reset failed'. This is
      // the defect the earlier version of this screen pinned as unfixed.
      await reachCodeStep(tester, api);
      api.fail('/auth/forgot-password/reset', 'That code has expired.',
          status: 400);
      await submitReset(tester);

      expect(find.text('That code has expired.'), findsOneWidget);
      expect(find.text('Reset failed'), findsNothing);
    });
  });

  group('reach and scale', () {
    testWidgets('the send button meets the minimum tap target', (tester) async {
      api.ok('/auth/forgot-password/send-otp', <String, Object?>{'sent': true});
      await pumpScreen(tester, const ForgotPasswordScreen());
      expectTapTarget(tester, find.byType(ElevatedButton));
    });

    testWidgets('the reset button meets the minimum tap target',
        (tester) async {
      await reachCodeStep(tester, api);
      expectTapTarget(tester, find.byType(ElevatedButton));
    });

    testWidgets('the phone step does not clip at a doubled text scale',
        (tester) async {
      api.ok('/auth/forgot-password/send-otp', <String, Object?>{'sent': true});
      await pumpScreen(tester, const ForgotPasswordScreen(), textScale: 2.0);
      expectNoOverflow(tester);
    });

    testWidgets('the phone step lays out on a small screen', (tester) async {
      api.ok('/auth/forgot-password/send-otp', <String, Object?>{'sent': true});
      await pumpScreen(tester, const ForgotPasswordScreen(),
          size: const Size(360, 640));
      expect(find.text('Reset Password'), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('the code step is usable at a doubled text scale',
        (tester) async {
      api.ok('/auth/forgot-password/send-otp', <String, Object?>{'sent': true});
      await pumpScreen(tester, const ForgotPasswordScreen(), textScale: 2.0);
      await submitPhone(tester);
      expect(find.text('New Password *'), findsOneWidget);
      expect(find.byType(TextFormField), findsNWidgets(3));
    });
  });
}
