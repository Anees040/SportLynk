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

    testWidgets('a failed load reads as the empty state, not an error', (
      tester,
    ) async {
      // Defect, pinned rather than fixed: a non-200 or thrown load leaves `_venues`
      // empty and only debugPrints, so a server failure is indistinguishable from an
      // owner with no venues. There is no error-with-retry state here.
      api.fail(kVenues, 'boom');
      await pumpVenues(tester, api);
      await settleData(tester);

      expect(find.text('No venues yet'), findsOneWidget);
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
