// The owner's venue list: one GET on mount, four states, and an Add-Venue route
// out. Two things this screen does NOT have are pinned below rather than asserted
// away — there is no error-with-retry (a failed or non-200 load leaves the list
// empty, indistinguishable from a genuinely empty account) and the load reads the
// token with a non-null assertion, so the harness's default token is what lets it
// run at all.
//
// Mount note: the screen calls top-level `http.get` directly (owner_my_venues_screen
// .dart:33), which the FakeApi intercepts by path. Photos are left empty in the
// fixtures so the card renders its sport placeholder instead of reaching the network
// for an Image.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/owner/owner_my_venues_screen.dart';

import '../screen_harness.dart';

/// The list endpoint, as `${ApiConstants.baseUrl}/owner/venues` resolves under the
/// path-keyed fake.
const String kVenues = '/owner/venues';

/// One venue row, in the shape `_venueCard` reads. `venue_photos` is empty so the
/// card draws its placeholder rather than an `Image.network`.
Map<String, dynamic> venue({
  String name = 'Green Turf Arena',
  String sport = 'football',
  String city = 'Lahore',
  String address = 'Gulberg III',
  bool active = true,
  num pending = 3,
  num todays = 5,
  num rating = 4.5,
  num price = 2000,
}) => {
  'name': name,
  'sport_type': sport,
  'city': city,
  'address': address,
  'is_active': active,
  'pending_bookings': pending,
  'todays_bookings': todays,
  'rating': rating,
  'price_per_hour': price,
  'operating_hours_from': '06:00',
  'operating_hours_to': '23:00',
  'venue_photos': const [],
};

Future<RouteLog> pumpVenues(
  WidgetTester tester,
  FakeApi api, {
  double textScale = 1.0,
}) {
  return pumpScreen(
    tester,
    const OwnerMyVenuesScreen(),
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
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    api.install();
    api.ok(kVenues, [venue()]);
  });

  group('the list as it loads', () {
    testWidgets('a spinner stands while the first load is in flight', (
      tester,
    ) async {
      api.ok(kVenues, [venue()], delay: const Duration(milliseconds: 300));
      await pumpVenues(tester, api);

      expectLoading(tester);

      await settleData(tester, step: const Duration(milliseconds: 400));
      expect(find.text('Green Turf Arena'), findsOneWidget);
    });

    testWidgets('a loaded venue shows its name, sport and price', (
      tester,
    ) async {
      await pumpVenues(tester, api);
      await settleData(tester);

      expect(find.text('Green Turf Arena'), findsOneWidget);
      expect(find.text('FOOTBALL'), findsOneWidget);
      expect(find.text('PKR 2000/hr'), findsOneWidget);
    });

    testWidgets('an empty account shows the register-a-venue prompt', (
      tester,
    ) async {
      api.ok(kVenues, const []);
      await pumpVenues(tester, api);
      await settleData(tester);

      expect(find.text('No venues yet'), findsOneWidget);
      expect(find.text('Register a Venue'), findsOneWidget);
    });

    testWidgets('a failed load with no cache shows an error with a retry', (
      tester,
    ) async {
      // Fixed: a non-200 or thrown load now surfaces an error-with-retry instead of
      // the "No venues yet" prompt an owner with venues would read as data loss.
      api.fail(kVenues, 'boom');
      await pumpVenues(tester, api);
      await settleData(tester);

      expect(find.text('No venues yet'), findsNothing);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('boom'), findsOneWidget);
    });

    testWidgets('an inactive venue is marked pending rather than by sport', (
      tester,
    ) async {
      api.ok(kVenues, [venue(active: false)]);
      await pumpVenues(tester, api);
      await settleData(tester);

      expect(find.text('PENDING'), findsOneWidget);
      expect(find.text('FOOTBALL'), findsNothing);
    });
  });

  group('actions and reach', () {
    testWidgets('a saved description survives reopening and a price-only edit', (
      tester,
    ) async {
      const updatePath = '/owner/venues/v-1';
      const savedDescription = 'New floodlights and changing rooms';
      final row = {
        ...venue(),
        'id': 'v-1',
        'description': 'Original description',
      };
      api.ok(kVenues, [row]);
      api.fail('$updatePath/discounts', 'Discounts unavailable');
      api.fail('$updatePath/forecast', 'Forecast unavailable');
      api.ok(updatePath, null);
      await pumpVenues(tester, api);
      await settleData(tester);

      Future<void> openManagement() async {
        await tester.tap(find.text('Green Turf Arena'));
        await tester.pumpAndSettle();
      }

      Future<void> saveChanges() async {
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump(const Duration(milliseconds: 200));
        final save = find.widgetWithText(ElevatedButton, 'Save Changes');
        await tester.ensureVisible(save);
        await tester.pumpAndSettle();
        await tester.tap(save);
        await tester.pumpAndSettle();
        // Let the success snackbar close before the next edit.
        await tester.pump(const Duration(seconds: 7));
        await tester.pumpAndSettle();
      }

      await openManagement();
      await tester.enterText(find.byType(TextFormField).first, savedDescription);
      // The subsequent list fetch supplies the server's saved venue.
      api.ok(kVenues, [{...row, 'description': savedDescription}]);
      await saveChanges();
      expect(jsonDecode(api.to(updatePath).single.body!)['description'],
        savedDescription);
      expect(api.countTo(kVenues), 2);

      await openManagement();
      expect(tester.widget<TextFormField>(find.byType(TextFormField).first)
        .controller!.text, savedDescription);
      await tester.enterText(find.byType(TextFormField).at(1), '2800');
      await saveChanges();
      final secondSave = jsonDecode(api.to(updatePath).last.body!) as Map;
      expect(secondSave['description'], savedDescription);
      expect(secondSave['price_per_hour'], 2800);
      expect(api.to(updatePath), hasLength(2));
      expect(api.countTo(kVenues), 3);
    });

    testWidgets('the refresh control reloads the list', (tester) async {
      await pumpVenues(tester, api);
      await settleData(tester);
      expect(api.countTo(kVenues), 1, reason: 'one load on mount');

      await tester.tap(find.byIcon(Icons.refresh));
      await settleData(tester);

      expect(api.countTo(kVenues), 2, reason: 'the refresh control re-fetches');
    });

    testWidgets('the add-venue affordance is offered', (tester) async {
      await pumpVenues(tester, api);
      await settleData(tester);

      // The FAB is the always-present route to registration; the empty state adds a
      // second button, but the list state must still offer one.
      expect(
        find.widgetWithText(FloatingActionButton, 'Add Venue'),
        findsOneWidget,
      );
    });

    testWidgets('a doubled text scale keeps a venue present', (tester) async {
      ignoreOverflow();
      await pumpVenues(tester, api, textScale: 2.0);
      await settleData(tester);

      expect(find.text('Green Turf Arena'), findsOneWidget);
    });
  });
}
