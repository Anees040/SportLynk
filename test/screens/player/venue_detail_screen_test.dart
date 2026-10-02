// The venue detail and booking screen: a hero gallery, an "about" block, a reviews
// summary, and the date/slot grid a player books from. Two independent loads run on
// mount. The venue and its slots come from a direct `GET /venues/:id?date=…`
// (`_load`), and the review aggregates come separately from
// `ReviewService.venueReviews` (`_loadReviews`) — kept apart on purpose so a reviews
// failure never blanks the slots the player came to book.
//
// Two properties shape the tests. First, `_load` distinguishes a reachable "this
// venue is gone" (a 404, which still renders "Venue not found") from a load that
// failed for any other reason — a 500, or a dropped connection — which renders the
// mandated error-with-retry rather than being swallowed into "Venue not found" or
// an empty grid. Both are asserted below. Second, the slot grid re-reads itself on
// a 30-second `Timer.periodic`, which never completes: `pumpAndSettle` would hang
// and the timer is pending at teardown unless the screen is disposed. So every test
// here drives time with explicit pumps and ends by unmounting the screen
// (`pumpWidget(SizedBox.shrink())`), which runs `dispose` and cancels the timer.
//
// Mount note: `_load` reads `AuthProvider.token` (banged) and `_loadReviews` reads
// the cached token; `FakeAuth` supplies both. The fake keys on the path, so
// `/venues/v-1` answers the venue GET and `/venues/v-1/reviews` the aggregates,
// while the `?date=` query the grid varies is recorded but ignored for matching. The
// gallery fixture is left without photos so no `Image.network` reaches out.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/player/venue_detail_screen.dart';

import '../screen_harness.dart';

/// The venue GET, its reviews aggregate, and a slot's lock endpoint, path-keyed.
const String kVenue = '/venues/v-1';
const String kReviews = '/venues/v-1/reviews';
const String kAvailability = '/venues/v-1/availability';
const String kLock = '/slots/s-1/lock';

/// The screen's own date key format (YYYY-MM-DD), for availability fixtures.
String dateKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// One slot in the shape `_load` reads off `data.slots`. `status` drives the grid
/// cell: 'available' is selectable and priced, anything else is struck through and
/// labelled. `start_time` is rendered through `_to12Hour`, so '18:00:00' is "6:00 PM".
Map<String, dynamic> slot({
  String id = 's-1',
  String start = '18:00:00',
  String status = 'available',
  num price = 2000,
}) => {
  'id': id,
  'start_time': start,
  'end_time': '19:00:00',
  'status': status,
  'price': price,
};

/// The venue document `_load` reads from `data`. `price_per_hour` drives the "about"
/// card figure; it is deliberately distinct from the slot price so each "PKR …"
/// finder is unambiguous. No `venue_photos`/`image_url`, so the hero draws its
/// gradient placeholder rather than reaching the network.
Map<String, dynamic> venue({
  String name = 'Green Turf Arena',
  num pricePerHour = 2500,
  String sport = 'football',
  List<Map<String, dynamic>> slots = const [],
}) => {
  'id': 'v-1',
  'name': name,
  'price_per_hour': pricePerHour,
  'sport_type': sport,
  'address': '123 Main Street, Lahore',
  'city': 'Lahore',
  'ground_type': 'grass',
  'operating_hours_from': '06:00',
  'operating_hours_to': '23:00',
  'rating': '4.5',
  'total_reviews': 10,
  'slots': slots,
};

/// The venue-wide review payload `VenueReviews.fromJson` reads. Aggregates only —
/// the preview list is left empty so no `ReviewCard`/avatar work is needed here.
Map<String, dynamic> reviewsPage({int total = 2, String? avg = '4.5'}) => {
  'venueId': 'v-1',
  'page': 1,
  'limit': 20,
  'total': total,
  'avgStars': avg,
  'sentimentDistribution': const {'positive': 1, 'neutral': 1, 'negative': 0},
  'starCounts': const {'5': 1, '4': 1, '3': 0, '2': 0, '1': 0},
  'reviews': const [],
};

Future<RouteLog> pumpVenue(
  WidgetTester tester,
  FakeApi api, {
  double textScale = 1.0,
}) {
  return pumpScreen(
    tester,
    const VenueDetailScreen(venueId: 'v-1'),
    auth: FakeAuth(
      role: 'player',
      id: 'u-1',
      name: 'Bilal Ahmed',
      token: 'test-token',
    ),
    textScale: textScale,
  );
}

void main() {
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    api.install();
    api.ok(kVenue, venue(slots: [slot()]));
    api.ok(kReviews, reviewsPage());
    // The rail asks for per-date availability on open, and selecting a slot takes a
    // background hold — stub both so neither 404s into the behaviour under test.
    api.ok(kAvailability, const {'venueId': 'v-1', 'days': 14, 'byDate': []});
    api.ok(kLock, const {'slotId': 's-1', 'expiresInSeconds': 300});
  });

  group('the venue as it loads', () {
    testWidgets('a loader stands while the venue is in flight', (tester) async {
      api.ok(
        kVenue,
        venue(slots: [slot()]),
        delay: const Duration(milliseconds: 300),
      );
      await pumpVenue(tester, api);

      expectLoading(tester);

      await settleData(tester, step: const Duration(milliseconds: 400));
      expect(find.text('Green Turf Arena'), findsOneWidget);

      await tester.pumpWidget(
        const SizedBox.shrink(),
      ); // cancel the refresh timer
    });

    testWidgets('a loaded venue shows its name, price and booking sections', (
      tester,
    ) async {
      await pumpVenue(tester, api);
      await settleData(tester);

      expect(find.text('Green Turf Arena'), findsOneWidget);
      expect(find.text('PKR 2500'), findsOneWidget); // price per hour
      expect(find.text('Select Date'), findsOneWidget);

      await tester.ensureVisible(
        find.text('Available Slots', skipOffstage: false),
      );
      await tester.pump();
      expect(find.text('Available Slots'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the reviews summary reports the venue-wide count', (
      tester,
    ) async {
      await pumpVenue(tester, api);
      await settleData(tester);

      expect(find.text('Player Reviews'), findsOneWidget);
      expect(find.text('2 reviews'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a failed venue load offers a retry, not a dead end', (
      tester,
    ) async {
      // A 500 is a reachability failure, not a missing venue. Swallowing it into
      // "Venue not found" (or an empty grid) tells the player a venue the backend
      // is serving fine does not exist; the error-with-retry state is mandated for
      // exactly this case.
      api.fail(kVenue, 'boom');
      await pumpVenue(tester, api);
      await settleData(tester);

      expect(find.text('Venue not found'), findsNothing);
      expect(find.text('Could not load'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Retry'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a dropped connection also offers a retry', (tester) async {
      api.offline(kVenue);
      await pumpVenue(tester, api);
      await settleData(tester);

      expect(find.widgetWithText(OutlinedButton, 'Retry'), findsOneWidget);
      expect(find.text('Venue not found'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a genuine 404 still reads as the venue being gone', (
      tester,
    ) async {
      // The one failure a retry cannot fix. It keeps the plain not-found view,
      // with no retry, because re-asking for a venue that is gone is a dead end.
      api.fail(kVenue, 'not found', status: 404);
      await pumpVenue(tester, api);
      await settleData(tester);

      expect(find.text('Venue not found'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Retry'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('tapping retry re-runs the load and recovers', (tester) async {
      api.fail(kVenue, 'boom');
      await pumpVenue(tester, api);
      await settleData(tester);
      expect(find.widgetWithText(OutlinedButton, 'Retry'), findsOneWidget);

      // The second attempt succeeds: FakeApi.on replaces the fixture by path.
      api.ok(kVenue, venue(slots: [slot()]));
      await tapVisible(tester, find.widgetWithText(OutlinedButton, 'Retry'));
      await settleData(tester);

      expect(find.text('Green Turf Arena'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Retry'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('the slot grid', () {
    testWidgets('available and taken slots render by their status', (
      tester,
    ) async {
      api.ok(
        kVenue,
        venue(
          slots: [
            slot(id: 's-1', start: '18:00:00', status: 'available'),
            slot(id: 's-2', start: '19:00:00', status: 'booked'),
          ],
        ),
      );
      await pumpVenue(tester, api);
      await settleData(tester);

      await tester.ensureVisible(find.text('6:00 PM', skipOffstage: false));
      await tester.pump();
      expect(find.text('6:00 PM'), findsOneWidget); // available slot time
      expect(find.text('BOOKED'), findsOneWidget); // the taken slot's label
      expect(find.text('Held'), findsOneWidget); // the legend key

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a date with no slots shows the empty state', (tester) async {
      api.ok(kVenue, venue(slots: const []));
      await pumpVenue(tester, api);
      await settleData(tester);

      await tester.ensureVisible(
        find.text('No slots available', skipOffstage: false),
      );
      await tester.pump();
      expect(find.text('No slots available'), findsOneWidget);
      expect(find.text('Try selecting a different date'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('selecting a slot is instant — Book Now lights up before the hold resolves', (
      tester,
    ) async {
      api.ok(kVenue, venue(slots: [slot(id: 's-1', start: '18:00:00')]));
      await pumpVenue(tester, api);
      await settleData(tester);

      await tester.ensureVisible(find.text('6:00 PM', skipOffstage: false));
      await tester.pump();
      await tester.tap(find.text('6:00 PM'));
      // A single frame — no network settle. The optimistic selection must have
      // enabled Book Now without waiting on the background lock round-trip.
      await tester.pump();
      final book = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Book Now'),
      );
      expect(book.onPressed, isNotNull);

      await settleData(tester); // let the background hold complete
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('the date rail', () {
    testWidgets('switching dates keeps the page, never blanking to a loader', (
      tester,
    ) async {
      await pumpVenue(tester, api);
      await settleData(tester);
      expect(find.text('Green Turf Arena'), findsOneWidget);

      // Tapping another date must not replace the whole screen with the first-load
      // loader — the gallery, name and rail stay while only the grid refreshes.
      final tomorrow = DateTime.now().add(const Duration(days: 1));
      await tester.tap(find.text('${tomorrow.day}').first);
      await tester.pump(); // one frame, before the fetch could resolve
      expect(find.text('Green Turf Arena'), findsOneWidget);

      await settleData(tester);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a date chip shows how many slots that day has free', (
      tester,
    ) async {
      final today = DateTime.now();
      api.ok(kAvailability, {
        'venueId': 'v-1',
        'days': 14,
        'byDate': [
          {'date': dateKey(today), 'free': 3},
        ],
      });
      await pumpVenue(tester, api);
      await settleData(tester);

      expect(find.text('3 left'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('the booking bar', () {
    testWidgets('withholds Book Now until a slot is chosen', (tester) async {
      await pumpVenue(tester, api);
      await settleData(tester);

      // Nothing selected yet: the bar states the prompt and the button is inert.
      expect(find.text('Select a slot'), findsOneWidget);
      final book = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Book Now'),
      );
      expect(book.onPressed, isNull);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('reach and scale', () {
    testWidgets('a doubled text scale keeps the venue name present', (
      tester,
    ) async {
      ignoreOverflow();
      await pumpVenue(tester, api, textScale: 2.0);
      await settleData(tester);

      expect(find.text('Green Turf Arena'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
