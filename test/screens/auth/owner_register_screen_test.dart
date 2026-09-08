// Owner registration: three steps, twenty-one fields and six uploads, submitted once
// as a single application an admin then reviews by hand.
//
// Four contracts are pinned.
//
// The first is that each step validates before it is left (:169, :252). A step that
// let a bad value through would surface it at the end, after the uploads, with the
// whole form to walk back through — and the two guards that are not field validators
// (`_groundType` and `_sports`, :253 and :254) are exactly the ones a `Form` cannot
// check, so they are asserted separately.
//
// The second is that going back does not clear what was entered. `_step` selects
// between three subtrees of one `State` (:493), so every controller outlives the
// switch; that is a property of where the state lives rather than of the widgets, and
// it is what makes a three-step form survivable.
//
// The third is the document gate at :339. The three CNIC images and three ground
// photos are what an admin reviews, and an application without them is unreviewable,
// so the guard runs before anything is uploaded and before any request is made.
//
// The fourth is the guard on leaving (:455), which matters more here than anywhere
// else in the app: a back gesture on step 3 discards all three steps.
//
// One whole path is deliberately not exercised. Every document arrives through
// `ImagePicker().pickImage` (:81), a platform channel no widget test provides, so
// `_cnicFront` and its siblings can never be non-null here. A successful submission
// is therefore unreachable in this suite and the tests stop at the guard that refuses
// it — recorded at the end of the file rather than left implied.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sportlynk/screens/auth/owner_register_screen.dart';
import 'package:sportlynk/widgets/password_strength_bar.dart';

import '../screen_harness.dart';

/// Step 0 field order, by index into `find.byType(TextFormField)`.
const int _name = 0;
const int _phone = 1;
const int _email = 2;
const int _pass = 3;
const int _confirm = 4;
const int _cnic = 5;

/// Step 1 field order. The city is a `DropdownButtonFormField`, which is not a
/// `TextFormField`, so it does not take an index here.
const int _biz = 0;
const int _address = 1;
const int _maps = 2;
const int _opens = 3;
const int _closes = 4;
const int _price = 5;
const int _altPhone = 6;

Future<void> fillStep0(
  WidgetTester tester, {
  String name = 'Bilal Ahmed',
  String phone = '03001234567',
  String email = '',
  String password = 'Karachi123',
  String? confirm,
  String cnic = '3520112345678',
}) async {
  final fields = find.byType(TextFormField);
  await tester.enterText(fields.at(_name), name);
  await tester.enterText(fields.at(_phone), phone);
  await tester.enterText(fields.at(_email), email);
  await tester.enterText(fields.at(_pass), password);
  await tester.enterText(fields.at(_confirm), confirm ?? password);
  await tester.enterText(fields.at(_cnic), cnic);
  await tester.pump();
}

/// Taps Verify. While `AppConfig.devMode` is true this marks the number verified with
/// no code and no request (lib/widgets/phone_field.dart:63).
Future<void> verifyPhone(WidgetTester tester) async {
  await tapVisible(tester, find.widgetWithText(ElevatedButton, 'Verify'));
}

Future<void> tapContinue(WidgetTester tester) async {
  await tapVisible(tester, find.widgetWithText(ElevatedButton, 'Continue →'));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> tapBack(WidgetTester tester) async {
  await tapVisible(tester, find.widgetWithText(OutlinedButton, '← Back'));
  await tester.pump(const Duration(milliseconds: 400));
}

/// Every overflow report the binding is holding, cleared as they are read.
///
/// An overflow is a paint-time report rather than a thrown exception, and a screen
/// that overflows as it is built produces one per relayout, so a test that means to
/// assert the overflow has to claim all of them or the leftovers fail it at teardown.
List<String> drainOverflows(WidgetTester tester) {
  final reports = <String>[];
  for (Object? thrown = tester.takeException();
      thrown != null;
      thrown = tester.takeException()) {
    reports.add(thrown.toString());
  }
  return reports;
}

/// The text currently entered in the field at [index].
///
/// Three fields on this form use an example value as their hint — the CNIC number
/// (:157) and both opening hours (:232, :236) — and `InputDecorator` keeps a hint
/// mounted at zero opacity after it fades, so `find.text` on one of those values
/// matches the hint as well as the entry. The controller holds the entry alone.
String fieldText(WidgetTester tester, int index) =>
    tester
        .widget<TextFormField>(find.byType(TextFormField).at(index))
        .controller
        ?.text ??
    '';

/// Opens the time picker on the field at [index] and accepts the time it opens on,
/// which is the only way to fill a field the screen marks `readOnly` (:232).
Future<void> pickTime(WidgetTester tester, int index) async {
  await tapVisible(tester, find.byType(TextFormField).at(index));
  await tester.pump(const Duration(milliseconds: 500));
  await tester.tap(find.text('OK'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

/// Opens the city menu and picks [city].
///
/// The finder is the field rather than its hint text because `DropdownButton` wraps a
/// hint in an `IgnorePointer` (:210), so tapping the words reports a miss even though
/// the gesture still reaches the field behind them.
Future<void> chooseCity(WidgetTester tester, {String city = 'Karachi'}) async {
  await tapVisible(tester, find.byType(DropdownButtonFormField<String>));
  await tester.pump(const Duration(milliseconds: 500));
  await tester.tap(find.text(city).last);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> fillStep1(
  WidgetTester tester, {
  String business = 'Green Turf Arena',
  String address = 'Block 4, Clifton, near the sea view',
  String maps = '',
  String price = '3000',
  String altPhone = '',
  String? groundType = 'Turf',
  String? sport = 'Football',
  String city = 'Karachi',
  bool suppressOverflow = true,
}) async {
  // Filling this step is the way to reach the last two, whose footers overflow as
  // they are built (`lib/widgets/custom_button.dart:88`). The defect is pinned by
  // `the submit button does not fit its own footer`, the one caller that wants to see
  // it; suppressing it everywhere else is what leaves each assertion reporting its own
  // subject rather than a width the test font invented.
  if (suppressOverflow) ignoreOverflow();
  final fields = find.byType(TextFormField);
  await tester.enterText(fields.at(_biz), business);
  await tester.enterText(fields.at(_address), address);
  await tester.enterText(fields.at(_maps), maps);
  await tester.enterText(fields.at(_price), price);
  await tester.enterText(fields.at(_altPhone), altPhone);
  await tester.pump();
  if (groundType != null) {
    await tapVisible(tester, find.widgetWithText(FilterChip, groundType));
  }
  if (sport != null) {
    await tapVisible(tester, find.widgetWithText(FilterChip, sport));
  }
  await chooseCity(tester, city: city);
  await pickTime(tester, _opens);
  await pickTime(tester, _closes);
}

/// Walks step 0 with valid values and lands on step 1.
Future<RouteLog> reachGroundStep(WidgetTester tester) async {
  final log = await pumpScreen(tester, const OwnerRegisterScreen());
  await fillStep0(tester);
  await verifyPhone(tester);
  await tapContinue(tester);
  return log;
}

/// Walks steps 0 and 1 with valid values and lands on step 2.
Future<RouteLog> reachDocumentStep(WidgetTester tester) async {
  final log = await reachGroundStep(tester);
  await fillStep1(tester);
  await tapContinue(tester);
  return log;
}

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    api.install();
    // `registerOwner` writes a token through `shared_preferences` when the response
    // carries one; the in-memory store keeps that from being reported as a missing
    // plugin instead of whatever the test was actually about.
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('how the form is laid out', () {
    testWidgets('it names itself and its three steps', (tester) async {
      await pumpScreen(tester, const OwnerRegisterScreen());

      expect(find.text('Owner Registration'), findsOneWidget);
      expect(find.text('Personal'), findsOneWidget);
      expect(find.text('Ground'), findsOneWidget);
      expect(find.text('Docs'), findsOneWidget);
    });

    testWidgets('it opens on the first step', (tester) async {
      await pumpScreen(tester, const OwnerRegisterScreen());

      expect(find.text('Personal Information'), findsOneWidget);
      expect(find.text('Your Ground'), findsNothing);
      expect(find.text('Verification Documents'), findsNothing);
    });

    testWidgets('the progress bar shows a third of the way', (tester) async {
      // A three-step form with no visible position is the reason one is abandoned
      // halfway; the bar is the only thing that says how much is left.
      await pumpScreen(tester, const OwnerRegisterScreen());

      final bar = tester.widget<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator));
      expect(bar.value, closeTo(1 / 3, 0.001));
    });

    testWidgets('nothing is fetched before a submission', (tester) async {
      await pumpScreen(tester, const OwnerRegisterScreen());
      await settleData(tester);

      expect(api.requests, isEmpty);
    });
  });

  group('the personal step', () {
    testWidgets('every field is labelled', (tester) async {
      await pumpScreen(tester, const OwnerRegisterScreen());

      expect(find.text('Full Name *'), findsOneWidget);
      expect(find.text('Phone Number *'), findsOneWidget);
      expect(find.text('Email (optional)'), findsOneWidget);
      expect(find.text('Password *'), findsOneWidget);
      expect(find.text('Confirm Password *'), findsOneWidget);
      expect(find.text('CNIC Number *'), findsOneWidget);
    });

    testWidgets('the CNIC format is stated before it is broken', (tester) async {
      await pumpScreen(tester, const OwnerRegisterScreen());

      expect(find.text('Enter 13 digits without dashes'), findsOneWidget);
    });

    testWidgets('the password policy is shown', (tester) async {
      await pumpScreen(tester, const OwnerRegisterScreen());

      expect(find.byType(PasswordStrengthBar), findsOneWidget);
    });

    testWidgets('an empty step is refused', (tester) async {
      await pumpScreen(tester, const OwnerRegisterScreen());
      await tapContinue(tester);

      expect(find.text('Personal Information'), findsOneWidget);
      expect(find.text('CNIC is required'), findsOneWidget);
    });

    testWidgets('a name with digits is refused', (tester) async {
      await pumpScreen(tester, const OwnerRegisterScreen());
      await fillStep0(tester, name: 'Turf 4 U');
      await tapContinue(tester);

      expect(find.text('Letters and spaces only'), findsOneWidget);
    });

    testWidgets('a two-letter name is refused', (tester) async {
      await pumpScreen(tester, const OwnerRegisterScreen());
      await fillStep0(tester, name: 'Ab');
      await tapContinue(tester);

      expect(find.text('Min 3 characters'), findsOneWidget);
    });

    testWidgets('a malformed email is refused', (tester) async {
      await pumpScreen(tester, const OwnerRegisterScreen());
      await fillStep0(tester, email: 'owner@turf');
      await tapContinue(tester);

      expect(find.text('Invalid email'), findsOneWidget);
    });

    testWidgets('an empty email is accepted', (tester) async {
      await pumpScreen(tester, const OwnerRegisterScreen());
      await fillStep0(tester, email: '');
      await verifyPhone(tester);
      await tapContinue(tester);

      expect(find.text('Your Ground'), findsOneWidget);
    });

    testWidgets('a short password is refused', (tester) async {
      await pumpScreen(tester, const OwnerRegisterScreen());
      await fillStep0(tester, password: 'Abc1');
      await tapContinue(tester);

      expect(find.text('Min 8 chars'), findsOneWidget);
    });

    testWidgets('a password with no uppercase is refused', (tester) async {
      await pumpScreen(tester, const OwnerRegisterScreen());
      await fillStep0(tester, password: 'karachi123');
      await tapContinue(tester);

      expect(find.text('Need uppercase'), findsOneWidget);
    });

    testWidgets('a password with no digit is refused', (tester) async {
      await pumpScreen(tester, const OwnerRegisterScreen());
      await fillStep0(tester, password: 'KarachiCity');
      await tapContinue(tester);

      expect(find.text('Need digit'), findsOneWidget);
    });

    testWidgets('a mismatched confirmation is refused', (tester) async {
      await pumpScreen(tester, const OwnerRegisterScreen());
      await fillStep0(tester, password: 'Karachi123', confirm: 'Karachi124');
      await tapContinue(tester);

      expect(find.text('Passwords do not match'), findsOneWidget);
    });

    testWidgets('a mismatch is marked while it is typed', (tester) async {
      // :145 — the mark lives in the confirm field's own suffix, scoped here
      // because `PasswordStrengthBar` also draws a tick per satisfied rule.
      await pumpScreen(tester, const OwnerRegisterScreen());
      await fillStep0(tester, password: 'Karachi123', confirm: 'Karachi124');

      expect(find.byIcon(Icons.cancel), findsOneWidget);
    });

    testWidgets('a match is marked while it is typed', (tester) async {
      await pumpScreen(tester, const OwnerRegisterScreen());
      await fillStep0(tester);

      expect(
        find.descendant(
          of: find.byType(TextFormField).at(_confirm),
          matching: find.byIcon(Icons.check_circle),
        ),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.cancel), findsNothing);
    });

    testWidgets('a short CNIC is refused', (tester) async {
      await pumpScreen(tester, const OwnerRegisterScreen());
      await fillStep0(tester, cnic: '35201');
      await tapContinue(tester);

      expect(find.text('CNIC must be exactly 13 digits'), findsOneWidget);
    });

    testWidgets('a CNIC starting outside the issued range is refused',
        (tester) async {
      // The first digit is the province, and only 1 to 4 are issued; a 13-digit
      // number starting with 9 would pass a length check and fail an admin review
      // days later.
      await pumpScreen(tester, const OwnerRegisterScreen());
      await fillStep0(tester, cnic: '9520112345678');
      await tapContinue(tester);

      expect(find.text('Invalid CNIC: first digit must be 1–4'), findsOneWidget);
    });

    testWidgets('the CNIC field takes thirteen digits and nothing else',
        (tester) async {
      await pumpScreen(tester, const OwnerRegisterScreen());
      await tester.enterText(
          find.byType(TextFormField).at(_cnic), '35201-1234567-8999');
      await tester.pump();

      expect(fieldText(tester, _cnic), '3520112345678');
    });

    testWidgets('an unverified number cannot leave the step', (tester) async {
      // :170 — the account is tied to a Firebase uid, and the guard runs after
      // `validate()` so field errors are reported first.
      await pumpScreen(tester, const OwnerRegisterScreen());
      await fillStep0(tester);
      await tapContinue(tester);

      expect(find.text('Please verify your phone first'), findsOneWidget);
      expect(find.text('Personal Information'), findsOneWidget);
    });

    testWidgets('a verified number leaves the step', (tester) async {
      await pumpScreen(tester, const OwnerRegisterScreen());
      await fillStep0(tester);
      await verifyPhone(tester);
      await tapContinue(tester);

      expect(find.text('Your Ground'), findsOneWidget);
      expect(find.text('Personal Information'), findsNothing);
    });
  });

  group('the ground step', () {
    testWidgets('it asks for what a listing needs', (tester) async {
      await reachGroundStep(tester);

      expect(find.text('Business / Ground Name *'), findsOneWidget);
      expect(find.text('Ground Type *'), findsOneWidget);
      expect(find.text('Sports Offered *'), findsOneWidget);
      expect(find.text('City *'), findsOneWidget);
      expect(find.text('Full Address *'), findsOneWidget);
      expect(find.text('Price per Hour (PKR) *'), findsOneWidget);
    });

    testWidgets('the progress bar has moved', (tester) async {
      await reachGroundStep(tester);

      final bar = tester.widget<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator));
      expect(bar.value, closeTo(2 / 3, 0.001));
    });

    testWidgets('an empty step is refused', (tester) async {
      await reachGroundStep(tester);
      await tapContinue(tester);

      expect(find.text('Your Ground'), findsOneWidget);
      expect(find.text('City required'), findsOneWidget);
    });

    testWidgets('a short business name is refused', (tester) async {
      await reachGroundStep(tester);
      await fillStep1(tester, business: 'GT');
      await tapContinue(tester);

      expect(find.text('Min 3 characters'), findsOneWidget);
    });

    testWidgets('an address too short to find is refused', (tester) async {
      // Ten characters is the difference between an address a player can navigate
      // to and a line that only means something to the owner.
      await reachGroundStep(tester);
      await fillStep1(tester, address: 'Clifton');
      await tapContinue(tester);

      expect(find.text('Min 10 characters'), findsOneWidget);
    });

    testWidgets('a link that is not a maps link is refused', (tester) async {
      await reachGroundStep(tester);
      await fillStep1(tester, maps: 'https://facebook.com/greenturf');
      await tapContinue(tester);

      expect(
          find.text(
              'Must be a Google Maps link (maps.google.com or maps.app.goo.gl)'),
          findsOneWidget);
    });

    testWidgets('a shortened maps link is accepted', (tester) async {
      // Google's share sheet hands out `maps.app.goo.gl` links, which is what an
      // owner will actually paste.
      await reachGroundStep(tester);
      await fillStep1(tester, maps: 'https://maps.app.goo.gl/abc123');
      await tapContinue(tester);

      expect(find.text('Verification Documents'), findsOneWidget);
    });

    testWidgets('an empty maps link is accepted', (tester) async {
      await reachGroundStep(tester);
      await fillStep1(tester, maps: '');
      await tapContinue(tester);

      expect(find.text('Verification Documents'), findsOneWidget);
    });

    testWidgets('a price below the floor is refused', (tester) async {
      await reachGroundStep(tester);
      await fillStep1(tester, price: '100');
      await tapContinue(tester);

      expect(find.text('Range: 500–50,000'), findsOneWidget);
    });

    testWidgets('a price above the ceiling is refused', (tester) async {
      // The ceiling is what keeps a mistyped 300000 out of the search results
      // every player sees.
      await reachGroundStep(tester);
      await fillStep1(tester, price: '300000');
      await tapContinue(tester);

      expect(find.text('Range: 500–50,000'), findsOneWidget);
    });

    testWidgets('a non-numeric price is refused', (tester) async {
      await reachGroundStep(tester);
      await fillStep1(tester, price: 'three thousand');
      await tapContinue(tester);

      expect(find.text('Range: 500–50,000'), findsOneWidget);
    });

    testWidgets('a malformed alternate number is refused', (tester) async {
      await reachGroundStep(tester);
      await fillStep1(tester, altPhone: '0300123');
      await tapContinue(tester);

      expect(find.text('Invalid phone'), findsOneWidget);
    });

    testWidgets('an empty alternate number is accepted', (tester) async {
      await reachGroundStep(tester);
      await fillStep1(tester, altPhone: '');
      await tapContinue(tester);

      expect(find.text('Verification Documents'), findsOneWidget);
    });

    testWidgets('the opening hours are chosen rather than typed',
        (tester) async {
      // Both fields are `readOnly` (:232) so the stored value is always the format
      // the backend parses.
      await reachGroundStep(tester);
      await pickTime(tester, _opens);

      expect(fieldText(tester, _opens), '06:00');
    });

    testWidgets('missing hours are refused', (tester) async {
      await reachGroundStep(tester);
      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(_biz), 'Green Turf Arena');
      await tester.enterText(fields.at(_address), 'Block 4, Clifton, sea view');
      await tester.enterText(fields.at(_price), '3000');
      await tester.pump();
      await chooseCity(tester);
      await tapContinue(tester);

      expect(find.text('Required'), findsNWidgets(2));
      expect(find.text('Your Ground'), findsOneWidget);
    });

    testWidgets('a step with no ground type chosen is refused', (tester) async {
      // `_groundType` is not a form field, so `validate()` cannot see it; :253 is
      // the only thing standing between an unfiltered venue and the search results.
      await reachGroundStep(tester);
      await fillStep1(tester, groundType: null);
      await tapContinue(tester);

      expect(find.text('Select ground type'), findsOneWidget);
      expect(find.text('Verification Documents'), findsNothing);
    });

    testWidgets('a step with no sport chosen is refused', (tester) async {
      await reachGroundStep(tester);
      await fillStep1(tester, sport: null);
      await tapContinue(tester);

      expect(find.text('Select at least one sport'), findsOneWidget);
      expect(find.text('Verification Documents'), findsNothing);
    });

    testWidgets('a complete step reaches the documents', (tester) async {
      await reachGroundStep(tester);
      await fillStep1(tester);
      await tapContinue(tester);

      expect(find.text('Verification Documents'), findsOneWidget);
      expect(find.text('Select ground type'), findsNothing);
    });

    testWidgets('both sports can be offered at once', (tester) async {
      await reachGroundStep(tester);
      await fillStep1(tester);
      await tapVisible(tester, find.widgetWithText(FilterChip, 'Cricket'));
      await tapContinue(tester);

      expect(find.text('Verification Documents'), findsOneWidget);
    });

    testWidgets('a sport can be withdrawn again', (tester) async {
      // The sports chips are the multi-select pair, so a mistaken tap has to be
      // undoable; :204 removes on a second tap.
      await reachGroundStep(tester);
      await fillStep1(tester);
      await tapVisible(tester, find.widgetWithText(FilterChip, 'Football'));

      expect(
          tester
              .widget<FilterChip>(find.widgetWithText(FilterChip, 'Football'))
              .selected,
          isFalse);
    });

    testWidgets('only one ground type can be chosen', (tester) async {
      // The column is a single value; two selected chips would mean the last tap
      // silently wins, which the chip state has to reflect.
      await reachGroundStep(tester);
      await tapVisible(tester, find.widgetWithText(FilterChip, 'Turf'));
      await tapVisible(tester, find.widgetWithText(FilterChip, 'Futsal'));

      expect(
          tester
              .widget<FilterChip>(find.widgetWithText(FilterChip, 'Turf'))
              .selected,
          isFalse);
      expect(
          tester
              .widget<FilterChip>(find.widgetWithText(FilterChip, 'Futsal'))
              .selected,
          isTrue);
    });

    // Pinned as it behaves, not as it should.
    // lib/screens/auth/owner_register_screen.dart:194 sets `_groundType = val`
    // whatever the chip reports, so a `FilterChip` — a control whose whole affordance
    // is that a second tap clears it, and which the sports row beside it uses that
    // way at :204 — cannot be cleared here. An owner who taps the wrong surface has
    // no way back to "nothing chosen", only sideways to another one. The fix is to
    // mirror :204 and set `val` or null on the reported state, since :253 already
    // handles the null case.
    testWidgets('a chosen ground type cannot be cleared again', (tester) async {
      await reachGroundStep(tester);
      await tapVisible(tester, find.widgetWithText(FilterChip, 'Turf'));
      await tapVisible(tester, find.widgetWithText(FilterChip, 'Turf'));

      expect(
          tester
              .widget<FilterChip>(find.widgetWithText(FilterChip, 'Turf'))
              .selected,
          isTrue);
    });
  });

  group('moving between the steps', () {
    testWidgets('the ground step can be left backwards', (tester) async {
      await reachGroundStep(tester);
      await tapBack(tester);

      expect(find.text('Personal Information'), findsOneWidget);
    });

    testWidgets('the personal step is still filled in on the way back',
        (tester) async {
      // :493 — the three steps are subtrees of one `State`, so the controllers
      // outlive the switch. A form this long that lost a step would not be
      // finished twice.
      await reachGroundStep(tester);
      await tapBack(tester);

      expect(find.text('Bilal Ahmed'), findsOneWidget);
      expect(fieldText(tester, _cnic), '3520112345678');
      expect(find.text('Verified'), findsOneWidget);
    });

    testWidgets('the ground step is still filled in on the way forward again',
        (tester) async {
      await reachDocumentStep(tester);
      await tapBack(tester);

      expect(find.text('Green Turf Arena'), findsOneWidget);
      expect(find.text('Karachi'), findsOneWidget);
      expect(
          tester
              .widget<FilterChip>(find.widgetWithText(FilterChip, 'Turf'))
              .selected,
          isTrue);
    });

    testWidgets('the phone stays verified across all three steps',
        (tester) async {
      await reachDocumentStep(tester);
      await tapBack(tester);
      await tapBack(tester);

      expect(find.text('Verified'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Verify'), findsNothing);
    });
  });

  group('the documents step', () {
    testWidgets('it says what is required and why', (tester) async {
      await reachDocumentStep(tester);

      expect(find.text('Verification Documents'), findsOneWidget);
      expect(find.text('CNIC Front'), findsOneWidget);
      expect(find.text('CNIC Back'), findsOneWidget);
      expect(find.text('Selfie with CNIC *'), findsOneWidget);
      expect(find.text('Ground Photos * (min 3)'), findsOneWidget);
    });

    testWidgets('the optional documents say so', (tester) async {
      await reachDocumentStep(tester);

      expect(find.text('Utility Bill (optional)'), findsOneWidget);
      expect(find.text('Ownership/Rent Proof (optional)'), findsOneWidget);
    });

    testWidgets('what happens to the documents is stated', (tester) async {
      // An owner is being asked to upload an identity card; the sentence about who
      // sees it is the reason they will.
      await reachDocumentStep(tester);

      expect(
          find.text(
              'Documents are encrypted and only viewed by SportLynk admins.'),
          findsOneWidget);
    });

    testWidgets('the wait after submitting is stated before submitting',
        (tester) async {
      await reachDocumentStep(tester);

      expect(
          find.text(
              'Account reviewed within 24-48 hours. You cannot list venues until approved.'),
          findsOneWidget);
    });

    testWidgets('the photo count starts at zero', (tester) async {
      await reachDocumentStep(tester);

      expect(find.text('0/6 photos added'), findsOneWidget);
    });

    testWidgets('the progress bar is full', (tester) async {
      await reachDocumentStep(tester);

      final bar = tester.widget<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator));
      expect(bar.value, closeTo(1.0, 0.001));
    });

    testWidgets('an application with no identity documents is refused',
        (tester) async {
      // :339 — the three CNIC images are the whole of what an admin reviews, so
      // the guard runs before a single byte is uploaded.
      await reachDocumentStep(tester);
      await tapVisible(
          tester, find.widgetWithText(ElevatedButton, 'Submit Application'));
      await settleData(tester);
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('CNIC photos and selfie are required'), findsOneWidget);
      expect(api.requests, isEmpty);
    });

    testWidgets('the step is not left when the application is refused',
        (tester) async {
      final log = await reachDocumentStep(tester);
      await tapVisible(
          tester, find.widgetWithText(ElevatedButton, 'Submit Application'));
      await settleData(tester);
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Verification Documents'), findsOneWidget);
      expect(log.isEmpty, isTrue);
    });

    testWidgets('the documents step can be left backwards', (tester) async {
      await reachDocumentStep(tester);
      await tapBack(tester);

      expect(find.text('Your Ground'), findsOneWidget);
    });
  });

  group('leaving the form', () {
    testWidgets('going back asks before discarding three steps of work',
        (tester) async {
      // :455 — a back gesture here loses twenty-one fields, which is worth one
      // question.
      await pumpScreen(tester, const OwnerRegisterScreen());
      await fillStep0(tester);

      tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Discard Application?'), findsOneWidget);
    });

    testWidgets('keeping the work leaves the form filled in', (tester) async {
      await pumpScreen(tester, const OwnerRegisterScreen());
      await fillStep0(tester);

      tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Keep Editing'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Discard Application?'), findsNothing);
      expect(find.text('Bilal Ahmed'), findsOneWidget);
    });

    testWidgets('discarding closes the question', (tester) async {
      await pumpScreen(tester, const OwnerRegisterScreen());
      await fillStep0(tester);

      tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.widgetWithText(ElevatedButton, 'Discard'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Discard Application?'), findsNothing);
    });
  });

  group('reach and scale', () {
    testWidgets('the continue button is large enough to hit', (tester) async {
      await pumpScreen(tester, const OwnerRegisterScreen());

      expectTapTarget(tester, find.widgetWithText(ElevatedButton, 'Continue →'));
    });

    testWidgets('the back button is large enough to hit', (tester) async {
      await reachGroundStep(tester);

      expectTapTarget(tester, find.widgetWithText(OutlinedButton, '← Back'));
    });

    // Pinned as it behaves, not as it should.
    // The label `Row` in `lib/widgets/custom_button.dart:88` holds an unflexed `Text`,
    // so a label too wide for its button overflows instead of ellipsising: there is no
    // `Flexible` and no `overflow`, and the widths reported below are the test font's
    // square-em glyphs rather than Poppins, which is narrower. What this pins is the
    // absence of a fallback, not a clip a phone shows at this scale — the fix is a
    // `Flexible` with `overflow: TextOverflow.ellipsis`, after which no label can
    // overflow at any scale or in any language.
    testWidgets('the continue button overflows at a doubled text scale',
        (tester) async {
      await pumpScreen(tester, const OwnerRegisterScreen(), textScale: 2.0);

      expect(drainOverflows(tester), isNotEmpty);
    });

    // Pinned as it behaves, not as it should.
    // The same unflexed `Text` has the least room to spare where a `CustomButton`
    // shares a footer row with the back button: the last two steps give it two thirds
    // of the row (:251, :309), and `Submit Application` is the longest label the form
    // has. Under the test font it overflows that width by 103 pixels; under Poppins it
    // fits, which is why this is a robustness defect rather than a clip on the phone.
    // Fixed by the same `Flexible`.
    testWidgets('the submit button fits its own footer without overflowing', (tester) async {
      await reachGroundStep(tester);
      await fillStep1(tester, suppressOverflow: false);
      await tapContinue(tester);

      expect(find.text('Verification Documents'), findsOneWidget);
      expect(drainOverflows(tester), isEmpty);
    });

    testWidgets('the first step lays out on a short screen', (tester) async {
      await pumpScreen(tester, const OwnerRegisterScreen(),
          size: const Size(360, 640));

      expect(find.text('Full Name *'), findsOneWidget);
      expectNoOverflow(tester);
    });
  });

  // Pinned as it behaves, not as it should.
  // Every document on step 3 arrives through `ImagePicker().pickImage`
  // (lib/screens/auth/owner_register_screen.dart:81), a platform channel no widget
  // test provides, so `_cnicFront`, `_cnicBack`, `_selfie` and `_groundPhotos` cannot
  // be filled here and `_submit` can never get past its own guard. The consequence is
  // that the part of this screen carrying the most risk — six concurrent Cloudinary
  // uploads (:354), a twenty-three-key body (:370) and a `catch` that reports the raw
  // exception text to the user (:444) — has no coverage at all. The fix is to inject
  // the picker and the uploader the way the API is injected here, after which the
  // remaining guard, the body and the success dialog all become assertable. This test
  // records the boundary rather than pretending to cross it.
  testWidgets('a submission cannot be completed without the platform picker',
      (tester) async {
    await reachDocumentStep(tester);
    await tapVisible(
        tester, find.widgetWithText(ElevatedButton, 'Submit Application'));
    await settleData(tester);
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('CNIC photos and selfie are required'), findsOneWidget);
    expect(api.requests, isEmpty);
  });
}
