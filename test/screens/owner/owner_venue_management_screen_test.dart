// Venue management keeps the editable form usable while the independent demand
// forecast loads. The tests cover both paths and the PATCH body used to save the
// owner-controlled fields.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/owner/owner_venue_management_screen.dart';

import '../screen_harness.dart';

const String kForecast = '/owner/venues/v-1/forecast';
const String kUpdate = '/owner/venues/v-1';
const String kReviews = '/venues/v-1/reviews';

Map<String, dynamic> venue() => {
  'id': 'v-1',
  'name': 'Green Turf Arena',
  'description': 'Floodlights and changing rooms',
  'price_per_hour': 2000,
};

Map<String, dynamic> forecast() => {
  'source': 'heuristic',
  'available': true,
  'points': [
    {
      'ts': '2026-09-13T18:00:00+05:00',
      'slotDate': '2026-09-13',
      'hour': 18,
      'bookProbability': 0.72,
      'level': 'high',
    },
  ],
  'levels': {'high': 0.6, 'low': 0.2, 'baseRate': 0.3},
};

Finder field(String label) {
  final index = label == 'Venue Description & Amenities' ? 0 : 1;
  return find.byType(TextFormField).at(index);
}

Future<void> settleManagement(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 120));
  await tester.pump(const Duration(milliseconds: 120));
}

Future<RouteLog> pumpManagement(
  WidgetTester tester,
  FakeApi api, {
  double textScale = 1.0,
}) {
  return pumpScreen(
    tester,
    OwnerVenueManagementScreen(venue: venue()),
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
    api.ok(kForecast, forecast());
    api.ok(kReviews, {'venueId': 'v-1', 'total': 0, 'reviews': const []});
  });

  group('the forecast and form', () {
    testWidgets('shows the forecast spinner while the read is in flight', (
      tester,
    ) async {
      api.ok(kForecast, forecast(), delay: const Duration(milliseconds: 300));
      await pumpManagement(tester, api);
      expectLoading(tester);

      await tester.pump(const Duration(milliseconds: 400));
      await settleManagement(tester);
      expect(find.text('Demand — next 72 hours'), findsOneWidget);
    });

    testWidgets('renders the forecast beside the editable price', (
      tester,
    ) async {
      await pumpManagement(tester, api);
      await settleManagement(tester);

      expect(find.text('Manage Green Turf Arena'), findsOneWidget);
      expect(find.text('Demand — next 72 hours'), findsOneWidget);
      expect(find.textContaining('Busiest:'), findsOneWidget);
      expect(find.text('Save Changes'), findsOneWidget);
      expect(find.text('2000'), findsOneWidget);
    });

    testWidgets('a failed forecast keeps the form and offers a retry', (
      tester,
    ) async {
      api.fail(kForecast, 'forecast offline');
      await pumpManagement(tester, api);
      await settleManagement(tester);

      expect(find.text('Could not load the forecast.'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.text('Save Changes'), findsOneWidget);
    });
  });

  group('saving and navigation', () {
    testWidgets('saving sends the editable fields to the venue PATCH', (
      tester,
    ) async {
      api.on(
        kUpdate,
        FakeResponse(
          200,
          jsonEncode({'success': true, 'message': 'Updated.', 'data': {}}),
        ),
      );
      await pumpManagement(tester, api);
      await settleManagement(tester);

      await tester.enterText(
        field('Venue Description & Amenities'),
        'New floodlights',
      );
      await tester.enterText(field('Price Per Hour'), '2500');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Save Changes'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(api.countTo(kUpdate), 1);
      final body = jsonDecode(api.to(kUpdate).single.body!) as Map;
      expect(body['description'], 'New floodlights');
      expect(body['price_per_hour'], 2500);
    });

    testWidgets('the reviews action opens the venue review screen', (
      tester,
    ) async {
      await pumpManagement(tester, api);
      await settleManagement(tester);

      await tester.tap(find.byTooltip('Reviews'));
      await tester.pump();
      await settleManagement(tester);

      expect(find.text('Green Turf Arena · Reviews'), findsOneWidget);
      expect(find.textContaining('No reviews yet.'), findsOneWidget);
    });
  });

  testWidgets('a doubled text scale keeps the management title present', (
    tester,
  ) async {
    ignoreOverflow();
    await pumpManagement(tester, api, textScale: 2.0);
    await settleManagement(tester);
    expect(find.text('Manage Green Turf Arena'), findsOneWidget);
  });
}
