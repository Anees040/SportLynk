// Player registration: the longest form in the app and the only one that creates an
// account a user is signed straight into.
//
// Four contracts are pinned.
//
// The first is the validation set. Six of the seven messages this form can produce are
// asserted individually, because the rules are not interchangeable — a name rule that
// silently accepted digits, or a password rule that accepted seven characters, would
// be refused by the backend instead, and the user would see a 400 with no field named.
//
// The second is that an unverified phone number cannot be submitted (:368). The
// backend ties the account to a Firebase uid, and `_firebaseUid!` at :391 is a bang:
// without the guard above it this screen would throw a null-check error rather than
// explain what is missing. The guard runs *after* `validate()`, so a form that is
// otherwise empty reports its field errors first — which is the order asserted here.
//
// The third is what reaches the wire. `AuthService.registerPlayer`
// (lib/services/auth_service.dart:20) omits `email` and `avatarUrl` from the body
// rather than sending null, so the optional fields are asserted by absence.
//
// The fourth is the guard on leaving (:109). Every field is lost on a back gesture,
// so `canPop: false` turns the gesture into a question. It is invisible in the
// rendered output and is asserted by asking the navigator to pop.
//
// Two paths are deliberately not exercised. The avatar picker reaches
// `ImagePicker().pickImage` (:88), a platform channel no widget test provides, so the
// photo is never chosen here and `avatarUrl` is only ever asserted absent. And a
// *successful* `registerPlayer` writes a token to the device and opens the realtime
// socket (lib/providers/auth_provider.dart:106), so the success dialog is reached
// through a provider whose `registerPlayer` answers on its own, while every failure
// test uses the real one because its failure path touches neither.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sportlynk/screens/auth/player_register_screen.dart';
import 'package:sportlynk/widgets/password_strength_bar.dart';

import '../screen_harness.dart';

/// A session whose `registerPlayer` answers without touching the device or the
/// socket, so the success dialog can be asserted on its own.
class _CreatingAuth extends FakeAuth {
  _CreatingAuth({this.succeeds = true});

  final bool succeeds;

  /// The arguments the screen passed, for the tests that assert them.
  Map<String, Object?>? received;

  @override
  Future<bool> registerPlayer({
    required String name,
    required String phone,
    required String password,
    String? email,
    required String firebaseUid,
    String? avatarUrl,
  }) async {
    received = <String, Object?>{
      'name': name,
      'phone': phone,
      'password': password,
      'email': email,
      'firebaseUid': firebaseUid,
      'avatarUrl': avatarUrl,
    };
    return succeeds;
  }
}

Future<void> fillForm(
  WidgetTester tester, {
  String name = 'Bilal Ahmed',
  String phone = '03001234567',
  String email = '',
  String password = 'Karachi123',
  String? confirm,
}) async {
  final fields = find.byType(TextFormField);
  await tester.enterText(fields.at(0), name);
  await tester.enterText(fields.at(1), phone);
  await tester.enterText(fields.at(2), email);
  await tester.enterText(fields.at(3), password);
  await tester.enterText(fields.at(4), confirm ?? password);
  await tester.pump();
}

/// Taps Verify. While `AppConfig.devMode` is true this marks the number verified
/// with no code and no request (lib/widgets/phone_field.dart:63).
Future<void> verifyPhone(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(ElevatedButton, 'Verify'));
  await tester.pump();
}

Future<void> submit(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(ElevatedButton, 'Create Account'));
  await tester.pump();
  await settleData(tester);
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    api.install();
    // The real `registerPlayer` writes a token through `shared_preferences` on
    // success; the in-memory store keeps that from being reported as a missing
    // plugin instead of whatever the test was actually about.
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('what the form asks for', () {
    testWidgets('it names the account it is about to create', (tester) async {
      await pumpScreen(tester, const PlayerRegisterScreen());

      expect(find.text('Create Player Account'), findsOneWidget);
      expect(find.text('Player Account'), findsOneWidget);
    });

    testWidgets('every field is labelled', (tester) async {
      await pumpScreen(tester, const PlayerRegisterScreen());

      expect(find.text('Full Name *'), findsOneWidget);
      expect(find.text('Phone Number *'), findsOneWidget);
      expect(find.text('Email (optional)'), findsOneWidget);
      expect(find.text('Password *'), findsOneWidget);
      expect(find.text('Confirm Password *'), findsOneWidget);
    });

    testWidgets('the optional fields say so', (tester) async {
      // A required-looking optional field is the reason a registration is abandoned
      // halfway; both of these are genuinely optional on the backend.
      await pumpScreen(tester, const PlayerRegisterScreen());

      expect(find.text('Add Photo (optional)'), findsOneWidget);
      expect(find.text('Email (optional)'), findsOneWidget);
    });

    testWidgets('the password policy is shown before it is broken',
        (tester) async {
      await pumpScreen(tester, const PlayerRegisterScreen());

      expect(find.byType(PasswordStrengthBar), findsOneWidget);
    });

    testWidgets('returning users are offered the login screen', (tester) async {
      await pumpScreen(tester, const PlayerRegisterScreen());

      expect(find.text('Already have account? Log In', findRichText: true),
          findsOneWidget);
    });

    testWidgets('nothing is fetched before a submission', (tester) async {
      await pumpScreen(tester, const PlayerRegisterScreen());
      await settleData(tester);

      expect(api.requests, isEmpty);
    });
  });

  group('the name rule', () {
    testWidgets('a missing name is refused', (tester) async {
      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester, name: '');
      await submit(tester);

      expect(find.text('Name is required'), findsOneWidget);
      expect(api.requests, isEmpty);
    });

    testWidgets('a two-letter name is refused', (tester) async {
      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester, name: 'Ab');
      await submit(tester);

      expect(find.text('Name must be at least 3 characters'), findsOneWidget);
    });

    testWidgets('a name with digits is refused', (tester) async {
      // The column is a display name, and a digit in it is nearly always a phone
      // number typed into the wrong field.
      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester, name: 'Bilal 123');
      await submit(tester);

      expect(find.text('Name can only contain letters and spaces'),
          findsOneWidget);
    });

    testWidgets('an overlong name is refused', (tester) async {
      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester, name: 'a' * 51);
      await submit(tester);

      expect(find.text('Name too long'), findsOneWidget);
    });

    testWidgets('an ordinary name passes', (tester) async {
      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester, name: 'Bilal Ahmed');
      await submit(tester);

      expect(find.text('Name is required'), findsNothing);
      expect(find.text('Name can only contain letters and spaces'), findsNothing);
    });
  });

  group('the phone rule', () {
    testWidgets('a missing number is refused', (tester) async {
      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester, phone: '');
      await submit(tester);

      expect(find.text('Phone number is required'), findsOneWidget);
    });

    testWidgets('a short number is refused', (tester) async {
      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester, phone: '0300123');
      await submit(tester);

      expect(find.text('Must be exactly 11 digits'), findsOneWidget);
    });

    testWidgets('a landline-style number is refused', (tester) async {
      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester, phone: '04212345678');
      await submit(tester);

      expect(find.text('Must start with 03'), findsOneWidget);
    });

    testWidgets('an unissued mobile prefix is refused', (tester) async {
      // Only 030 to 036 are issued; 037 would pass a length check and then fail at
      // the SMS gateway, which is a worse place to find out.
      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester, phone: '03712345678');
      await submit(tester);

      expect(find.text('Enter valid Pakistani mobile number (03XX-XXXXXXX)'),
          findsOneWidget);
    });

    testWidgets('the field takes digits only', (tester) async {
      // `FilteringTextInputFormatter.digitsOnly` (lib/widgets/phone_field.dart:101)
      // is what keeps a pasted '+92 300' out of a column the backend matches exactly.
      await pumpScreen(tester, const PlayerRegisterScreen());
      await tester.enterText(find.byType(TextFormField).at(1), '+92 300abc1234');
      await tester.pump();

      expect(find.text('923001234'), findsOneWidget);
    });

    testWidgets('the field stops at eleven digits', (tester) async {
      await pumpScreen(tester, const PlayerRegisterScreen());
      await tester.enterText(find.byType(TextFormField).at(1), '030012345678999');
      await tester.pump();

      expect(find.text('03001234567'), findsOneWidget);
    });
  });

  group('the email rule', () {
    testWidgets('an empty email is accepted', (tester) async {
      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester, email: '');
      await submit(tester);

      expect(find.text('Invalid email format'), findsNothing);
    });

    testWidgets('a malformed email is refused', (tester) async {
      // Optional does not mean unchecked: a typo here is the address a password
      // reset would go to.
      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester, email: 'bilal@example');
      await submit(tester);

      expect(find.text('Invalid email format'), findsOneWidget);
    });

    testWidgets('a well-formed email is accepted', (tester) async {
      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester, email: 'bilal@example.com');
      await submit(tester);

      expect(find.text('Invalid email format'), findsNothing);
    });
  });

  group('the password rules', () {
    testWidgets('a missing password is refused', (tester) async {
      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester, password: '', confirm: '');
      await submit(tester);

      expect(find.text('Password required'), findsOneWidget);
    });

    testWidgets('a short password is refused', (tester) async {
      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester, password: 'Abc1');
      await submit(tester);

      expect(find.text('Min 8 characters'), findsOneWidget);
    });

    testWidgets('a lowercase-only password is refused', (tester) async {
      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester, password: 'karachi123');
      await submit(tester);

      expect(find.text('Add uppercase letter'), findsOneWidget);
    });

    testWidgets('a password with no digit is refused', (tester) async {
      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester, password: 'KarachiCity');
      await submit(tester);

      expect(find.text('Add a number'), findsOneWidget);
    });

    testWidgets('an unconfirmed password is refused', (tester) async {
      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester, password: 'Karachi123', confirm: '');
      await submit(tester);

      expect(find.text('Please confirm password'), findsOneWidget);
    });

    testWidgets('a mismatched confirmation is refused', (tester) async {
      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester, password: 'Karachi123', confirm: 'Karachi124');
      await submit(tester);

      expect(find.text('Passwords do not match'), findsOneWidget);
    });

    testWidgets('the strength meter tracks the field', (tester) async {
      await pumpScreen(tester, const PlayerRegisterScreen());
      await tester.enterText(find.byType(TextFormField).at(3), 'abc');
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Weak'), findsOneWidget);
    });

    testWidgets('both passwords are hidden until asked for', (tester) async {
      await pumpScreen(tester, const PlayerRegisterScreen());

      expect(find.byIcon(Icons.visibility_off), findsNWidgets(2));
    });

    testWidgets('each password reveals independently', (tester) async {
      await pumpScreen(tester, const PlayerRegisterScreen());

      await tester.tap(find.byIcon(Icons.visibility_off).first);
      await tester.pump();

      expect(find.byIcon(Icons.visibility), findsOneWidget);
      expect(find.byIcon(Icons.visibility_off), findsOneWidget);
    });
  });

  group('the live confirmation mark', () {
    /// The mark lives in the confirm field's own `suffixIcon`
    /// (lib/widgets/sport_text_field.dart:87). It is scoped to that field because
    /// `PasswordStrengthBar` also draws `Icons.check_circle`, once per satisfied
    /// rule.
    Finder markOn(IconData icon) => find.descendant(
          of: find.byType(TextFormField).at(4),
          matching: find.byIcon(icon),
        );

    testWidgets('it says nothing until the confirmation is typed',
        (tester) async {
      await pumpScreen(tester, const PlayerRegisterScreen());

      expect(find.byIcon(Icons.check_circle), findsNothing);
      expect(find.byIcon(Icons.cancel), findsNothing);
    });

    testWidgets('a match is marked as it is typed', (tester) async {
      // :335 — the point of the mark is that a mismatch is visible before the
      // submission rather than after it.
      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester);

      expect(markOn(Icons.check_circle), findsOneWidget);
      expect(find.byIcon(Icons.cancel), findsNothing);
    });

    testWidgets('a mismatch is marked as it is typed', (tester) async {
      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester, password: 'Karachi123', confirm: 'Karachi124');

      expect(find.byIcon(Icons.cancel), findsOneWidget);
      expect(markOn(Icons.check_circle), findsNothing);
    });
  });

  group('verifying the phone number', () {
    testWidgets('an unverified number cannot be submitted', (tester) async {
      // :368 — `_firebaseUid!` on the next line is a bang, so without this guard the
      // screen would throw instead of naming what is missing.
      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester);
      await submit(tester);

      expect(find.text('Please verify your phone number first'), findsOneWidget);
      expect(api.requests, isEmpty);
    });

    testWidgets('field errors are reported before the verification is asked for',
        (tester) async {
      // `validate()` runs first (:367), so an empty form is not told to verify a
      // number it has not been given.
      await pumpScreen(tester, const PlayerRegisterScreen());
      await submit(tester);

      expect(find.text('Name is required'), findsOneWidget);
      expect(find.text('Please verify your phone number first'), findsNothing);
    });

    testWidgets('verifying marks the number and hides the button',
        (tester) async {
      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester);
      await verifyPhone(tester);

      expect(find.text('Verified'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Verify'), findsNothing);
    });

    testWidgets('a verified number can no longer be typed into',
        (tester) async {
      // Read-only after verification is what keeps the uid and the number from
      // drifting apart between the check and the submission.
      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester);
      await verifyPhone(tester);

      final field = tester.widget<TextFormField>(find.byType(TextFormField).at(1));
      expect(field.controller?.text, '03001234567');
      expect(
        tester.widget<EditableText>(find.byType(EditableText).at(1)).readOnly,
        isTrue,
      );
    });

    testWidgets('editing the number clears the verification', (tester) async {
      // lib/widgets/phone_field.dart:136 — the uid belongs to the old number, so
      // both the flag and the field are dropped together.
      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester);
      await verifyPhone(tester);

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pump();

      expect(find.text('Verified'), findsNothing);
      expect(find.widgetWithText(ElevatedButton, 'Verify'), findsOneWidget);
      expect(find.text('03001234567'), findsNothing);
    });

    testWidgets('a cleared number must be verified again before submitting',
        (tester) async {
      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester);
      await verifyPhone(tester);
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pump();
      await tester.enterText(find.byType(TextFormField).at(1), '03009998877');
      await tester.pump();
      await submit(tester);

      expect(find.text('Please verify your phone number first'), findsOneWidget);
      expect(api.requests, isEmpty);
    });

    // Pinned as it behaves, not as it should.
    // lib/constants/app_config.dart:5 leaves `devMode` true, and
    // lib/widgets/phone_field.dart:63 returns `devFirebaseUid` as a verified phone
    // without sending a code, without opening the OTP screen and without even
    // running the number through its own validator. Every account created on this
    // build therefore shares one Firebase identity. It must be false in any build
    // that leaves the machine; this test records the shortcut rather than the OTP
    // path, which cannot be reached while the flag is set.
    testWidgets('verification currently costs no code and no request',
        (tester) async {
      final log = await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester);
      await verifyPhone(tester);

      expect(find.text('Verified'), findsOneWidget);
      expect(log.sawRoute('/otp'), isFalse);
      expect(api.requests, isEmpty);
    });
  });

  group('what reaches the wire', () {
    testWidgets('the account is posted to the player endpoint', (tester) async {
      api.fail('/auth/register/player', 'That number is already registered.',
          status: 409);

      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester);
      await verifyPhone(tester);
      await submit(tester);

      final request = api.to('/auth/register/player').single;
      expect(request.method, 'POST');
    });

    testWidgets('the name and number are trimmed and the password is not',
        (tester) async {
      api.fail('/auth/register/player', 'That number is already registered.',
          status: 409);

      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester,
          name: '  Bilal Ahmed  ', password: ' Karachi123 ');
      await verifyPhone(tester);
      await submit(tester);

      final sent =
          jsonDecode(api.to('/auth/register/player').single.body!) as Map;
      expect(sent['name'], 'Bilal Ahmed');
      expect(sent['phone'], '03001234567');
      expect(sent['password'], ' Karachi123 ');
    });

    testWidgets('the verified uid is what identifies the phone', (tester) async {
      api.fail('/auth/register/player', 'That number is already registered.',
          status: 409);

      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester);
      await verifyPhone(tester);
      await submit(tester);

      final sent =
          jsonDecode(api.to('/auth/register/player').single.body!) as Map;
      expect(sent['firebaseUid'], 'DEV_MODE_UID_12345');
    });

    testWidgets('an omitted email is left out of the body', (tester) async {
      // lib/services/auth_service.dart:25 omits the key rather than sending null,
      // because the column is unique and a null would collide on the second signup.
      api.fail('/auth/register/player', 'That number is already registered.',
          status: 409);

      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester, email: '');
      await verifyPhone(tester);
      await submit(tester);

      final sent =
          jsonDecode(api.to('/auth/register/player').single.body!) as Map;
      expect(sent.containsKey('email'), isFalse);
    });

    testWidgets('a given email is included', (tester) async {
      api.fail('/auth/register/player', 'That number is already registered.',
          status: 409);

      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester, email: '  bilal@example.com  ');
      await verifyPhone(tester);
      await submit(tester);

      final sent =
          jsonDecode(api.to('/auth/register/player').single.body!) as Map;
      expect(sent['email'], 'bilal@example.com');
    });

    testWidgets('no avatar is claimed when no photo was chosen', (tester) async {
      api.fail('/auth/register/player', 'That number is already registered.',
          status: 409);

      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester);
      await verifyPhone(tester);
      await submit(tester);

      final sent =
          jsonDecode(api.to('/auth/register/player').single.body!) as Map;
      expect(sent.containsKey('avatarUrl'), isFalse);
    });

    testWidgets('the button shows progress while the request is out',
        (tester) async {
      api.fail('/auth/register/player', 'That number is already registered.',
          status: 409, delay: const Duration(milliseconds: 400));

      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester);
      await verifyPhone(tester);
      await tester.tap(find.widgetWithText(ElevatedButton, 'Create Account'));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Create Account'), findsNothing);

      await settleData(tester);
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('a second tap cannot create two accounts', (tester) async {
      api.fail('/auth/register/player', 'That number is already registered.',
          status: 409, delay: const Duration(milliseconds: 400));

      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester);
      await verifyPhone(tester);
      await tester.tap(find.widgetWithText(ElevatedButton, 'Create Account'));
      await tester.pump();
      await tester.tap(find.byType(ElevatedButton), warnIfMissed: false);
      await tester.pump();

      expect(api.countTo('/auth/register/player'), 1);

      await settleData(tester);
      await tester.pump(const Duration(milliseconds: 400));
    });
  });

  group('when the account cannot be created', () {
    testWidgets("the server's reason is shown", (tester) async {
      // A duplicate number is the common failure, and it is the one message a user
      // can act on.
      api.fail('/auth/register/player', 'That number is already registered.',
          status: 409);

      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester);
      await verifyPhone(tester);
      await submit(tester);

      expect(find.text('That number is already registered.'), findsOneWidget);
      expect(find.text('Account Created!'), findsNothing);
    });

    testWidgets('the form is left filled in', (tester) async {
      api.fail('/auth/register/player', 'That number is already registered.',
          status: 409);

      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester);
      await verifyPhone(tester);
      await submit(tester);

      expect(find.text('Bilal Ahmed'), findsOneWidget);
      expect(find.text('Verified'), findsOneWidget);
    });

    testWidgets('a dropped connection is reported rather than swallowed',
        (tester) async {
      api.offline('/auth/register/player');

      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester);
      await verifyPhone(tester);
      await submit(tester);

      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text('Account Created!'), findsNothing);
    });

    testWidgets('the button becomes pressable again', (tester) async {
      api.fail('/auth/register/player', 'That number is already registered.',
          status: 409);

      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester);
      await verifyPhone(tester);
      await submit(tester);

      expect(find.text('Create Account'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('nothing is navigated away from', (tester) async {
      api.fail('/auth/register/player', 'That number is already registered.',
          status: 409);

      final log = await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester);
      await verifyPhone(tester);
      await submit(tester);

      expect(log.isEmpty, isTrue);
    });
  });

  group('when the account is created', () {
    testWidgets('the success is stated rather than implied', (tester) async {
      await pumpScreen(tester, const PlayerRegisterScreen(),
          auth: _CreatingAuth());
      await fillForm(tester);
      await verifyPhone(tester);
      await submit(tester);

      expect(find.text('Account Created!'), findsOneWidget);
      expect(find.text('Welcome to SportLynk. Your player account is ready.'),
          findsOneWidget);
    });

    testWidgets('the dialog cannot be dismissed by tapping outside it',
        (tester) async {
      // `barrierDismissible: false` (:399): the account exists and the only way on
      // is the button, so a stray tap must not leave the user on a dead form.
      await pumpScreen(tester, const PlayerRegisterScreen(),
          auth: _CreatingAuth());
      await fillForm(tester);
      await verifyPhone(tester);
      await submit(tester);

      await tester.tapAt(const Offset(10, 10));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Account Created!'), findsOneWidget);
    });

    testWidgets('the only way on is the login screen', (tester) async {
      // :441 removes the form behind it, so the account cannot be submitted twice
      // by going back.
      final log = await pumpScreen(tester, const PlayerRegisterScreen(),
          auth: _CreatingAuth());
      await fillForm(tester);
      await verifyPhone(tester);
      await submit(tester);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Start Booking'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(log.sawRoute('/login'), isTrue);
    });

    testWidgets('the trimmed values are what was registered', (tester) async {
      final auth = _CreatingAuth();
      await pumpScreen(tester, const PlayerRegisterScreen(), auth: auth);
      await fillForm(tester,
          name: '  Bilal Ahmed  ', email: '  bilal@example.com  ');
      await verifyPhone(tester);
      await submit(tester);

      expect(auth.received, <String, Object?>{
        'name': 'Bilal Ahmed',
        'phone': '03001234567',
        'password': 'Karachi123',
        'email': 'bilal@example.com',
        'firebaseUid': 'DEV_MODE_UID_12345',
        'avatarUrl': null,
      });
    });

    testWidgets('an empty email is passed as absent rather than blank',
        (tester) async {
      final auth = _CreatingAuth();
      await pumpScreen(tester, const PlayerRegisterScreen(), auth: auth);
      await fillForm(tester, email: '');
      await verifyPhone(tester);
      await submit(tester);

      expect(auth.received!['email'], isNull);
    });

    testWidgets('a refusal shows no dialog', (tester) async {
      await pumpScreen(tester, const PlayerRegisterScreen(),
          auth: _CreatingAuth(succeeds: false));
      await fillForm(tester);
      await verifyPhone(tester);
      await submit(tester);

      expect(find.text('Account Created!'), findsNothing);
      expect(find.text('Registration failed'), findsOneWidget);
    });
  });

  group('leaving the form', () {
    testWidgets('going back asks before discarding the work', (tester) async {
      // :109 — every field is lost on a pop, and a form this long is worth one
      // question.
      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester);

      tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Discard Registration?'), findsOneWidget);
      expect(
          find.text(
              'Any information you entered will be lost. Are you sure you want to go back?'),
          findsOneWidget);
    });

    testWidgets('keeping the work leaves the form filled in', (tester) async {
      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester);

      tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Keep Editing'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Discard Registration?'), findsNothing);
      expect(find.text('Bilal Ahmed'), findsOneWidget);
    });

    testWidgets('discarding closes the question', (tester) async {
      await pumpScreen(tester, const PlayerRegisterScreen());
      await fillForm(tester);

      tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.widgetWithText(ElevatedButton, 'Discard'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Discard Registration?'), findsNothing);
    });

    testWidgets('the login link opens the login screen', (tester) async {
      final log = await pumpScreen(tester, const PlayerRegisterScreen());

      final box = tester.getRect(
          find.text('Already have account? Log In', findRichText: true));
      await tester.tapAt(Offset(box.right - 12, box.center.dy));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(log.sawRoute('/login'), isTrue);
    });
  });

  group('reach and scale', () {
    testWidgets('the submit button is large enough to hit', (tester) async {
      await pumpScreen(tester, const PlayerRegisterScreen());

      expectTapTarget(
          tester, find.widgetWithText(ElevatedButton, 'Create Account'));
    });

    testWidgets('the verify button is large enough to hit', (tester) async {
      await pumpScreen(tester, const PlayerRegisterScreen());

      expectTapTarget(tester, find.widgetWithText(ElevatedButton, 'Verify'));
    });

    testWidgets('it does not clip at a doubled text scale', (tester) async {
      await pumpScreen(tester, const PlayerRegisterScreen(), textScale: 2.0);

      expectNoOverflow(tester);
    });

    testWidgets('every field is still there at a doubled text scale',
        (tester) async {
      await pumpScreen(tester, const PlayerRegisterScreen(), textScale: 2.0);

      expect(find.byType(TextFormField), findsNWidgets(5));
    });

    testWidgets('it lays out on a short screen', (tester) async {
      await pumpScreen(tester, const PlayerRegisterScreen(),
          size: const Size(360, 640));

      expect(find.text('Full Name *'), findsOneWidget);
      expectNoOverflow(tester);
    });
  });
}
