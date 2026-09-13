// Owners can inspect and report venue reviews, but moderation remains an admin
// action. A failed read currently returns the service's empty sentinel, which is
// pinned below as a known missing error state.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/owner/owner_venue_reviews_screen.dart';

import '../screen_harness.dart';

const String kReviews = '/venues/v-1/reviews';
const String kFlag = '/reviews/r-1/flag';

Map<String, dynamic> reviewPage({int total = 1}) => {
  'venueId': 'v-1',
  'page': 1,
  'limit': 20,
  'total': total,
  'avgStars': total == 0 ? null : 4.5,
  'starCounts': {'5': 1, '4': 0, '3': 0, '2': 0, '1': 0},
  'sentimentDistribution': {'positive': 1, 'neutral': 0, 'negative': 0},
  'reviews': total == 0
      ? const []
      : [
          {
            'id': 'r-1',
            'stars': 5,
            'reviewerName': 'Ali Raza',
            'text': 'Excellent turf and lights.',
            'sentimentLabel': 'positive',
            'createdAt': '2026-09-12T12:00:00Z',
          },
        ],
};

Future<void> settleReviews(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 120));
  await tester.pump(const Duration(milliseconds: 120));
}

Future<RouteLog> pumpReviews(
  WidgetTester tester,
  FakeApi api, {
  double textScale = 1.0,
}) {
  return pumpScreen(
    tester,
    const OwnerVenueReviewsScreen(
      venueId: 'v-1',
      venueName: 'Green Turf Arena',
    ),
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
    api = FakeApi()..install();
    api.ok(kReviews, reviewPage());
  });

  group('the review feed', () {
    testWidgets('shows a spinner while the first page is loading', (
      tester,
    ) async {
      api.ok(kReviews, reviewPage(), delay: const Duration(milliseconds: 300));
      await pumpReviews(tester, api);
      expectLoading(tester);

      await tester.pump(const Duration(milliseconds: 400));
      await settleReviews(tester);
      expect(find.text('Ali Raza'), findsOneWidget);
    });

    testWidgets('renders the aggregate, reviewer and written review', (
      tester,
    ) async {
      await pumpReviews(tester, api);
      await settleReviews(tester);

      expect(find.text('Green Turf Arena · Reviews'), findsOneWidget);
      expect(find.text('4.5'), findsOneWidget);
      expect(find.text('1 review'), findsOneWidget);
      expect(find.text('Ali Raza'), findsOneWidget);
      expect(find.text('Excellent turf and lights.'), findsOneWidget);
      expect(find.byTooltip('Report this review'), findsOneWidget);
    });

    testWidgets('an empty venue shows the designed empty state', (
      tester,
    ) async {
      api.ok(kReviews, reviewPage(total: 0));
      await pumpReviews(tester, api);
      await settleReviews(tester);

      expect(find.textContaining('No reviews yet.'), findsOneWidget);
    });

    testWidgets('a failed read reads as no reviews, not an error', (
      tester,
    ) async {
      // Defect, pinned: ReviewService.venueReviews returns VenueReviews.empty on
      // failure, so the owner sees the same copy as a genuinely new venue.
      api.fail(kReviews, 'boom');
      await pumpReviews(tester, api);
      await settleReviews(tester);

      expect(find.textContaining('No reviews yet.'), findsOneWidget);
    });
  });

  testWidgets('reporting a review posts the selected reason', (tester) async {
    api.on(
      kFlag,
      FakeResponse(
        200,
        jsonEncode({'success': true, 'message': 'Reported.', 'data': {}}),
      ),
    );
    await pumpReviews(tester, api);
    await settleReviews(tester);

    await tester.tap(find.byTooltip('Report this review'));
    await tester.pumpAndSettle();
    expect(find.text('Report this review'), findsOneWidget);

    await tester.tap(find.text('Spam or fake review'));
    await tester.tap(find.widgetWithText(ElevatedButton, 'Report Review'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(api.countTo(kFlag), 1);
    final body = jsonDecode(api.to(kFlag).single.body!) as Map;
    expect(body['reason'], 'Spam or fake review');
    expect(find.text('Reported to moderators for review.'), findsOneWidget);
  });

  testWidgets('a doubled text scale keeps the review visible', (tester) async {
    ignoreOverflow();
    await pumpReviews(tester, api, textScale: 2.0);
    await settleReviews(tester);
    expect(find.text('Ali Raza'), findsOneWidget);
  });
}
