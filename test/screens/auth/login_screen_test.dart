// The only screen that turns credentials into a session, and the only one that has to
// tell three different roles apart before it knows where to send them.
//
// Four contracts are pinned.
//
// The first is the identifier field accepting either a phone number or an email in one
// box (:118). The backend's `/auth/login` takes one `identifier` and decides for
// itself, so the client's only job is to reject input that can be neither — and to
// reject it before spending a request. The two regexes are asserted through the
// messages they produce, because a validator that silently passed everything would look
// identical until the server refused it.
//
// The second is the role fan-out at :186. A successful login lands on one of three
// different roots, `pushNamedAndRemoveUntil` in each case so the login screen cannot be
// reached backwards from a signed-in session. Nothing on screen reveals which branch
// ran, so the destination is asserted by route name.
//
// The third is the pending-owner branch at :177. An owner whose application is still
// under review gets a *failed* login carrying `status: 'pending'`, and the screen turns
// that one failure into a route rather than a message — the distinction between "wrong
// password" and "not approved yet" is the difference between retrying and waiting. The
// extra top-level key survives because `ApiClient._decode` (lib/services/api_service.dart:216)
// preserves the body's own fields, which is why these fixtures are raw rather than
// built with `FakeResponse.fail`.
//
// The fourth is that the session's own success path is not exercised here.
// `AuthProvider.login` saves the token to the device and opens the realtime socket
// (:60), neither of which belongs in a widget test; those tests override `login` and
// assert the screen's decision, while the failure tests use the real provider because
// its failure path touches neither.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sportlynk/screens/auth/login_screen.dart';

import '../screen_harness.dart';

/// A session whose `login` answers without touching the device or the socket, so the
/// screen's routing decision can be asserted on its own.
class _RoutingAuth extends FakeAuth {
  _RoutingAuth({super.role});

  @override
  Future<bool> login(String identifier, String password) async => true;
}

/// A raw failure body carrying the extra top-level key the pending-owner branch reads.
FakeResponse pendingOwner(String message) => FakeResponse(
      403,
      jsonEncode({'success': false, 'message': message, 'status': 'pending'}),
    );

Future<void> fillAndSubmit(
  WidgetTester tester, {
  String identifier = '03001234567',
  String password = 'Karachi123',
}) async {
  await tester.enterText(find.byType(TextFormField).at(0), identifier);
  await tester.enterText(find.byType(TextFormField).at(1), password);
  await tester.tap(find.widgetWithText(ElevatedButton, 'Log In'));
  await tester.pump();
  await settleData(tester);
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    api.install();
    // `AuthProvider` writes the token through `shared_preferences`, whose platform
    // channel no widget test provides. The in-memory store keeps a real failure in the
    // login path from being reported as a missing plugin.
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('what the form asks for', () {
    testWidgets('one field takes either a phone number or an email',
        (tester) async {
      await pumpScreen(tester, const LoginScreen());

      expect(find.text('Phone or Email'), findsOneWidget);
      expect(find.text('Password'), findsOneWidget);
    });

    testWidgets('the hint says which formats are accepted', (tester) async {
      // Without it the field is a guess: the phone format is local and unguessable.
      await pumpScreen(tester, const LoginScreen());

      expect(find.text('03XXXXXXXXX or email'), findsOneWidget);
    });

    testWidgets('the password is hidden until asked for', (tester) async {
      await pumpScreen(tester, const LoginScreen());

      expect(find.byIcon(Icons.visibility_off), findsOneWidget);
      expect(find.byIcon(Icons.visibility), findsNothing);
    });

    testWidgets('the password can be revealed', (tester) async {
      // A hidden field and an unguessable format together are why a login fails twice
      // before a user checks what they typed.
      await pumpScreen(tester, const LoginScreen());

      await tester.tap(find.byIcon(Icons.visibility_off));
      await tester.pump();

      expect(find.byIcon(Icons.visibility), findsOneWidget);
    });

    testWidgets('both recovery paths are offered', (tester) async {
      await pumpScreen(tester, const LoginScreen());

      expect(find.text('Forgot Password?'), findsOneWidget);
      expect(find.text("Don't have an account? Sign Up", findRichText: true),
          findsOneWidget);
    });

    testWidgets('nothing is fetched before a submission', (tester) async {
      await pumpScreen(tester, const LoginScreen());
      await settleData(tester);

      expect(api.requests, isEmpty);
    });
  });

  group('what the form refuses to send', () {
    testWidgets('an empty form is refused without a request', (tester) async {
      await pumpScreen(tester, const LoginScreen());

      await tester.tap(find.widgetWithText(ElevatedButton, 'Log In'));
      await tester.pump();

      expect(find.text('Required'), findsNWidgets(2));
      expect(api.to('/auth/login'), isEmpty);
    });

    testWidgets('a malformed phone number is refused', (tester) async {
      // The server would answer 401 for this, which reads as a wrong password rather
      // than a mistyped number.
      await pumpScreen(tester, const LoginScreen());
      await fillAndSubmit(tester, identifier: '0300123');

      expect(find.text('Enter valid phone (03XXXXXXXXX)'), findsOneWidget);
      expect(api.to('/auth/login'), isEmpty);
    });

    testWidgets('a landline-style number is refused', (tester) async {
      await pumpScreen(tester, const LoginScreen());
      await fillAndSubmit(tester, identifier: '04212345678');

      expect(find.text('Enter valid phone (03XXXXXXXXX)'), findsOneWidget);
    });

    testWidgets('a malformed email is refused', (tester) async {
      // The presence of an `@` is what switches the validator; everything after that
      // has to hold up on its own.
      await pumpScreen(tester, const LoginScreen());
      await fillAndSubmit(tester, identifier: 'bilal@example');

      expect(find.text('Invalid email'), findsOneWidget);
      expect(api.to('/auth/login'), isEmpty);
    });

    testWidgets('a valid email is accepted', (tester) async {
      api.on('/auth/login', FakeResponse.fail('Invalid credentials.', status: 401));

      await pumpScreen(tester, const LoginScreen());
      await fillAndSubmit(tester, identifier: 'bilal@example.com');

      expect(find.text('Invalid email'), findsNothing);
      expect(api.to('/auth/login'), hasLength(1));
    });

    testWidgets('a missing password is refused even with a valid identifier',
        (tester) async {
      await pumpScreen(tester, const LoginScreen());

      await tester.enterText(find.byType(TextFormField).at(0), '03001234567');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Log In'));
      await tester.pump();

      expect(find.text('Required'), findsOneWidget);
      expect(api.to('/auth/login'), isEmpty);
    });

    testWidgets('surrounding whitespace is trimmed off the identifier',
        (tester) async {
      // A pasted phone number routinely carries a trailing space, and the server
      // matches the column exactly.
      api.on('/auth/login', FakeResponse.fail('Invalid credentials.', status: 401));

      await pumpScreen(tester, const LoginScreen());
      await fillAndSubmit(tester, identifier: '  03001234567  ');

      final sent = jsonDecode(api.to('/auth/login').single.body!) as Map;
      expect(sent['identifier'], '03001234567');
    });
  });

  group('submitting', () {
    testWidgets('the identifier and password are posted', (tester) async {
      api.on('/auth/login', FakeResponse.fail('Invalid credentials.', status: 401));

      await pumpScreen(tester, const LoginScreen());
      await fillAndSubmit(tester, password: 'Karachi123');

      final request = api.to('/auth/login').single;
      expect(request.method, 'POST');
      final sent = jsonDecode(request.body!) as Map;
      expect(sent['identifier'], '03001234567');
      expect(sent['password'], 'Karachi123');
    });

    testWidgets('the password is not trimmed', (tester) async {
      // A trailing space in a password is a character the user chose; trimming it
      // would lock them out of an account they can still type correctly.
      api.on('/auth/login', FakeResponse.fail('Invalid credentials.', status: 401));

      await pumpScreen(tester, const LoginScreen());
      await fillAndSubmit(tester, password: ' Karachi123 ');

      final sent = jsonDecode(api.to('/auth/login').single.body!) as Map;
      expect(sent['password'], ' Karachi123 ');
    });

    testWidgets('the button shows progress while the request is out',
        (tester) async {
      api.on('/auth/login',
          FakeResponse.fail('Invalid credentials.',
              status: 401, delay: const Duration(milliseconds: 400)));

      await pumpScreen(tester, const LoginScreen());
      await tester.enterText(find.byType(TextFormField).at(0), '03001234567');
      await tester.enterText(find.byType(TextFormField).at(1), 'Karachi123');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Log In'));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Log In'), findsNothing);

      await settleData(tester);
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('the button cannot be pressed twice while it is working',
        (tester) async {
      // `isLoading` disables the button through `CustomButton` (:69), which is what
      // keeps a double tap from posting two logins.
      api.on('/auth/login',
          FakeResponse.fail('Invalid credentials.',
              status: 401, delay: const Duration(milliseconds: 400)));

      await pumpScreen(tester, const LoginScreen());
      await tester.enterText(find.byType(TextFormField).at(0), '03001234567');
      await tester.enterText(find.byType(TextFormField).at(1), 'Karachi123');
      await tester.tap(find.byType(ElevatedButton));
      await tester.pump();
      await tester.tap(find.byType(ElevatedButton), warnIfMissed: false);
      await tester.pump();

      expect(api.to('/auth/login'), hasLength(1));

      await settleData(tester);
      await tester.pump(const Duration(milliseconds: 400));
    });
  });

  group('when the credentials are refused', () {
    testWidgets("the server's reason is shown", (tester) async {
      api.on('/auth/login',
          FakeResponse.fail('Invalid phone or password.', status: 401));

      await pumpScreen(tester, const LoginScreen());
      await fillAndSubmit(tester);

      expect(find.text('Invalid phone or password.'), findsOneWidget);
    });

    testWidgets('the form is left filled in', (tester) async {
      // Retyping both fields after one wrong character is the difference between one
      // more attempt and giving up.
      api.on('/auth/login',
          FakeResponse.fail('Invalid phone or password.', status: 401));

      await pumpScreen(tester, const LoginScreen());
      await fillAndSubmit(tester);

      expect(find.text('03001234567'), findsOneWidget);
    });

    testWidgets('a dropped connection is reported rather than swallowed',
        (tester) async {
      // The exact symptom of a phone with no route to the API: it must not look like
      // a rejected password.
      api.offline('/auth/login');

      await pumpScreen(tester, const LoginScreen());
      await fillAndSubmit(tester);

      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text('Invalid phone or password.'), findsNothing);
    });

    testWidgets('nothing is navigated away from', (tester) async {
      final log = await pumpScreen(tester, const LoginScreen());
      api.on('/auth/login', FakeResponse.fail('Invalid credentials.', status: 401));

      await fillAndSubmit(tester);

      expect(log.isEmpty, isTrue);
    });
  });

  group('when the account is an owner awaiting approval', () {
    testWidgets('the pending screen is shown instead of an error', (tester) async {
      // :177 — "not approved yet" is not a credentials problem, and a snackbar here
      // would send the owner back to retype a password that was correct.
      api.on('/auth/login', pendingOwner('Your application is under review.'));

      final log = await pumpScreen(tester, const LoginScreen());
      await fillAndSubmit(tester);

      expect(log.sawRoute('/owner-pending'), isTrue);
    });

    testWidgets('no error message is shown as well', (tester) async {
      api.on('/auth/login', pendingOwner('Your application is under review.'));

      await pumpScreen(tester, const LoginScreen());
      await fillAndSubmit(tester);

      expect(find.text('Your application is under review.'), findsNothing);
    });

    testWidgets('an ordinary rejection does not reach the pending screen',
        (tester) async {
      // The branch turns on the extra `status` key, not on the status code, so a
      // plain 403 must stay a message.
      api.on('/auth/login',
          FakeResponse.fail('You do not have permission to do that.',
              status: 403));

      final log = await pumpScreen(tester, const LoginScreen());
      await fillAndSubmit(tester);

      expect(log.sawRoute('/owner-pending'), isFalse);
      expect(find.text('You do not have permission to do that.'), findsOneWidget);
    });
  });

  group('where a successful login lands', () {
    testWidgets('a player goes to the player home', (tester) async {
      final log = await pumpScreen(tester, const LoginScreen(),
          auth: _RoutingAuth(role: 'player'));
      await fillAndSubmit(tester);

      expect(log.sawRoute('/player-home'), isTrue);
    });

    testWidgets('an owner goes to the owner home', (tester) async {
      final log = await pumpScreen(tester, const LoginScreen(),
          auth: _RoutingAuth(role: 'owner'));
      await fillAndSubmit(tester);

      expect(log.sawRoute('/owner-home'), isTrue);
      expect(log.sawRoute('/player-home'), isFalse);
    });

    testWidgets('an admin goes to the admin console', (tester) async {
      // The console is the reason this branch exists: an admin signed into the player
      // home has no route to the dispute queue.
      final log = await pumpScreen(tester, const LoginScreen(),
          auth: _RoutingAuth(role: 'admin'));
      await fillAndSubmit(tester);

      expect(log.sawRoute('/admin-home'), isTrue);
      expect(log.sawRoute('/player-home'), isFalse);
    });

    // Pinned as it behaves, not as it should.
    // lib/screens/auth/login_screen.dart:186 names `admin` and `owner` and sends
    // everything else to the player home, the same silent fallthrough as
    // lib/screens/auth_wrapper.dart:86. A role the client does not know about lands on
    // a screen built for players. The fix is to route the three known roles explicitly
    // and to state a failure for anything else.
    testWidgets('an unknown role silently goes to the player home',
        (tester) async {
      final log = await pumpScreen(tester, const LoginScreen(),
          auth: _RoutingAuth(role: 'referee'));
      await fillAndSubmit(tester);

      expect(log.sawRoute('/player-home'), isTrue);
    });
  });

  group('the other ways out', () {
    testWidgets('forgot password opens the reset flow', (tester) async {
      final log = await pumpScreen(tester, const LoginScreen());

      await tester.tap(find.text('Forgot Password?'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(log.sawRoute('/forgot-password'), isTrue);
    });

    testWidgets('sign up returns to the role choice', (tester) async {
      // Registration is per-role and this screen does not know which one the user is,
      // so it can only send them back to pick.
      final log = await pumpScreen(tester, const LoginScreen());

      final box = tester.getRect(
          find.text("Don't have an account? Sign Up", findRichText: true));
      await tester.tapAt(Offset(box.right - 12, box.center.dy));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(log.sawRoute('/welcome'), isTrue);
    });

    testWidgets('there is a way back', (tester) async {
      await pumpScreen(tester, const LoginScreen());

      expect(find.byIcon(Icons.arrow_back_ios), findsOneWidget);
    });
  });

  group('reach and scale', () {
    testWidgets('the submit button is large enough to hit', (tester) async {
      await pumpScreen(tester, const LoginScreen());

      expectTapTarget(tester, find.byType(ElevatedButton));
    });

    // Pinned as it behaves, not as it should.
    // lib/screens/auth/login_screen.dart:152 sets `minimumSize: Size.zero` and
    // `tapTargetSize: MaterialTapTargetSize.shrinkWrap` on the forgot-password button,
    // which drops it below the 48-pixel floor the project sets. It was presumably done
    // to tuck the link under the field; the fix is to keep the default target and take
    // the space, after which this should be an `expectTapTarget`.
    testWidgets('the forgot password link is under the tap-target floor',
        (tester) async {
      await pumpScreen(tester, const LoginScreen());

      final size = tester.getSize(
          find.widgetWithText(TextButton, 'Forgot Password?'));
      expect(size.height, lessThan(48));
    });

    testWidgets('it does not clip at a doubled text scale', (tester) async {
      await pumpScreen(tester, const LoginScreen(), textScale: 2.0);

      expectNoOverflow(tester);
    });

    testWidgets('the form is still usable at a doubled text scale',
        (tester) async {
      await pumpScreen(tester, const LoginScreen(), textScale: 2.0);

      expect(find.text('Phone or Email'), findsOneWidget);
      expect(find.byType(TextFormField), findsNWidgets(2));
    });
  });
}
