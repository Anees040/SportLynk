// The full reviews list for one venue: a spinner on mount, then one page from
// `/venues/:id/reviews` carrying both the rows and the venue-wide aggregates
// (average, star histogram, sentiment split). Paging appends as the list is scrolled.
//
// This screen has no error state, and that is a property of the service, not an
// oversight worth working around: `ReviewService.venueReviews` returns
// `VenueReviews.empty` on any failure ("never a throw", review_service.dart:73), and
// `ApiClient` itself never throws — a 500, a timeout and a dead socket all decode to
// `{success:false}`. So `_load` cannot fail, and a server error is indistinguishable
// from a venue nobody has reviewed. That is pinned below rather than asserted away.
//
// Mount note: the load reads `AuthProvider.token`; FakeAuth supplies it, so the page
// is actually requested. The fake keys on the path `/venues/v-1/reviews`; the
// `page`/`limit` query is recorded but ignored for matching.

import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/player/venue_reviews_screen.dart';

import '../screen_harness.dart';

/// The reviews endpoint for the fixture venue, as `ApiConstants.venueReviews('v-1')`
/// resolves under the path-keyed fake.
const String kReviews = '/venues/v-1/reviews';

/// One review row, in the camelCase shape `Review.fromJson` reads.
Map<String, dynamic> review({
  String id = 'r-1',
  int stars = 5,
  String text = 'Great turf, well maintained.',
  String name = 'Ahmed K.',
  String? sentiment = 'positive',
}) => {
  'id': id,
  'stars': stars,
  'text': text,
  'reviewerName': name,
  'reviewType': null,
  'sentimentLabel': sentiment,
  'createdAt': '2026-09-10T10:00:00.000Z',
};

/// The venue-wide payload `VenueReviews.fromJson` reads. `avgStars` arrives as a
/// String from Postgres NUMERIC, which `asNumOrNull` coerces; pass null for a venue
/// with no reviews.
Map<String, dynamic> venuePage({
  int total = 2,
  String? avg = '4.5',
  List<Map<String, dynamic>> reviews = const [],
}) => {
  'venueId': 'v-1',
  'page': 1,
  'limit': 20,
  'total': total,
  'avgStars': avg,
  'sentimentDistribution': const {'positive': 1, 'neutral': 1, 'negative': 0},
  'starCounts': const {'5': 1, '4': 1, '3': 0, '2': 0, '1': 0},
  'reviews': reviews,
};

Future<RouteLog> pumpReviews(
  WidgetTester tester,
  FakeApi api, {
  double textScale = 1.0,
}) {
  return pumpScreen(
    tester,
    const VenueReviewsScreen(venueId: 'v-1', venueName: 'Green Turf Arena'),
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
    api.ok(
      kReviews,
      venuePage(
        reviews: [
          review(),
          review(id: 'r-2', stars: 4, text: 'Decent pitch.', name: 'Sara M.'),
        ],
      ),
    );
  });

  group('the list as it loads', () {
    testWidgets('a spinner stands while the first load is in flight', (
      tester,
    ) async {
      api.ok(
        kReviews,
        venuePage(reviews: [review()]),
        delay: const Duration(milliseconds: 300),
      );
      await pumpReviews(tester, api);

      expectLoading(tester);

      await settleData(tester, step: const Duration(milliseconds: 400));
      expect(find.text('Great turf, well maintained.'), findsOneWidget);
    });

    testWidgets('a loaded page shows the aggregates and a review', (
      tester,
    ) async {
      await pumpReviews(tester, api);
      await settleData(tester);

      expect(find.text('4.5'), findsOneWidget); // headline average
      expect(find.text('2 reviews'), findsOneWidget);
      expect(find.text('Sentiment of written reviews'), findsOneWidget);
      expect(find.text('Great turf, well maintained.'), findsOneWidget);
      expect(
        find.textContaining('Green Turf Arena'),
        findsWidgets,
      ); // app-bar title
    });

    testWidgets('an unreviewed venue shows the be-the-first empty state', (
      tester,
    ) async {
      api.ok(kReviews, venuePage(total: 0, avg: null, reviews: const []));
      await pumpReviews(tester, api);
      await settleData(tester);

      expect(find.textContaining('No reviews yet'), findsOneWidget);
    });

    testWidgets('a failed load reads as the empty state, not an error', (
      tester,
    ) async {
      // Defect, pinned: neither the service nor ApiClient throws, and there is no
      // error/retry state — a 500 collapses to `VenueReviews.empty`, so a server
      // failure looks identical to a venue with no reviews.
      api.fail(kReviews, 'boom');
      await pumpReviews(tester, api);
      await settleData(tester);

      expect(find.textContaining('No reviews yet'), findsOneWidget);
    });
  });

  group('reach and scale', () {
    testWidgets('a doubled text scale keeps a review present', (tester) async {
      ignoreOverflow();
      await pumpReviews(tester, api, textScale: 2.0);
      await settleData(tester);

      expect(find.text('Great turf, well maintained.'), findsOneWidget);
    });
  });
}
