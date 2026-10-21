import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/admin/admin_overview_data_screen.dart';

import '../screen_harness.dart';

void main() {
  late FakeApi api;
  const endpoint = '/admin/venues/active';
  const screen = AdminOverviewDataScreen(data: AdminOverviewData.venues);
  late FakeAuth auth;

  setUp(() {
    api = FakeApi()..install();
    auth = FakeAuth(role: 'admin', isSuperAdmin: true);
  });

  testWidgets('failed initial reads show retry and recover to an empty list', (
    tester,
  ) async {
    api.fail(endpoint, 'Please try again.');
    await pumpScreen(tester, screen, auth: auth);
    await settleData(tester);
    expect(find.text('Please try again.'), findsOneWidget);
    expect(find.text('No records to show.'), findsNothing);
    api.ok(endpoint, {'items': [], 'nextCursor': null});
    await tester.tap(find.text('Retry'));
    await settleData(tester);
    expect(find.text('No records to show.'), findsOneWidget);
  });

  testWidgets(
    'pagination retries retain existing data and use the same cursor',
    (tester) async {
      api.ok(endpoint, {
        'items': [
          {'id': 'v-1', 'name': 'First Ground'},
        ],
        'nextCursor': 'next-page',
      });
      await pumpScreen(tester, screen, auth: auth);
      await settleData(tester);
      api.fail(endpoint, 'Connection interrupted.');
      await tester.tap(find.text('Load more'));
      await settleData(tester);
      expect(find.text('First Ground'), findsOneWidget);
      expect(find.text('Connection interrupted.'), findsOneWidget);
      api.ok(endpoint, {
        'items': [
          {'id': 'v-2', 'name': 'Second Ground'},
        ],
        'nextCursor': null,
      });
      await tester.tap(find.text('Retry'));
      await settleData(tester);
      expect(api.to(endpoint).last.param('cursor'), 'next-page');
      expect(find.text('First Ground'), findsOneWidget);
      expect(find.text('Second Ground'), findsOneWidget);
      expect(find.text('Load more'), findsNothing);
    },
  );

  testWidgets('a failed refresh retries the first page', (tester) async {
    api.ok(endpoint, {
      'items': [
        {'id': 'v-1', 'name': 'Original Ground'},
      ],
      'nextCursor': 'next-page',
    });
    await pumpScreen(tester, screen, auth: auth);
    await settleData(tester);
    api.fail(endpoint, 'Try refreshing again.');
    await tester.tap(find.byTooltip('Refresh'));
    await settleData(tester);
    api.ok(endpoint, {
      'items': [
        {'id': 'v-2', 'name': 'Updated Ground'},
      ],
      'nextCursor': null,
    });
    await tester.tap(find.text('Retry'));
    await settleData(tester);
    expect(api.to(endpoint).last.param('cursor'), isNull);
    expect(find.text('Original Ground'), findsNothing);
    expect(find.text('Updated Ground'), findsOneWidget);
  });

  testWidgets('direct navigation still checks permissions before fetching', (
    tester,
  ) async {
    await pumpScreen(tester, screen, auth: FakeAuth(role: 'admin'));
    await settleData(tester);
    expect(api.countTo(endpoint), 0);
    expect(
      find.text('You do not have permission to view these records.'),
      findsOneWidget,
    );
  });

  testWidgets('booking details wrap on a narrow screen with large text', (
    tester,
  ) async {
    api.ok('/admin/bookings/active', {
      'items': [
        {
          'id': 'b-1',
          'venue_name': 'Champions International Sports Ground',
          'player_name': 'Ayesha Khan',
          'slot_date': '2026-10-21',
          'start_time': '18:00:00',
          'end_time': '19:00:00',
          'status': 'checked_in',
          'total_amount': '2500',
        },
      ],
      'nextCursor': null,
    });
    await pumpScreen(
      tester,
      const AdminOverviewDataScreen(data: AdminOverviewData.bookings),
      auth: auth,
      size: const Size(280, 653),
      textScale: 2,
    );
    await settleData(tester);
    expect(find.text('PKR 2,500'), findsOneWidget);
    expect(find.text('Status: checked in'), findsOneWidget);
    expectNoOverflow(tester);
  });
}
