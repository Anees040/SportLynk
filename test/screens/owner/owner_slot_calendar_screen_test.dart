// The slot calendar chains an owner-venue read into a date-scoped slot read. The
// fake matches by path, while the tests still inspect the visible status labels and
// the exact mutation paths the screen builds.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sportlynk/screens/owner/owner_slot_calendar_screen.dart';

import '../screen_harness.dart';

const String kVenues = '/owner/venues';
const String kSlots = '/owner/slots';

Map<String, dynamic> venue() => {'id': 'v-1', 'name': 'Green Turf Arena'};

String today() {
  // Keep the fixture in the future regardless of the wall clock when the suite runs.
  // The calendar is intentionally date-scoped, but the fake ignores query strings;
  // using tomorrow lets the row exercise the available/blockable branch all day.
  final d = DateTime.now().add(const Duration(days: 1));
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

Map<String, dynamic> slot({String status = 'available'}) => {
  'id': 's-1',
  'slot_date': today(),
  'start_time': '18:00:00',
  'end_time': '19:00:00',
  'status': status,
  'effective_status': status,
};

Future<void> settleCalendar(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<RouteLog> pumpCalendar(
  WidgetTester tester,
  FakeApi api, {
  double textScale = 1.0,
}) {
  return pumpScreen(
    tester,
    const OwnerSlotCalendarScreen(),
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
    api.ok(kVenues, [venue()]);
    api.ok(kSlots, [slot()]);
  });

  group('the calendar as it loads', () {
    testWidgets('shows a spinner while venues and slots are chained', (
      tester,
    ) async {
      api.ok(kVenues, [venue()], delay: const Duration(milliseconds: 250));
      await pumpCalendar(tester, api);
      expectLoading(tester);

      await settleCalendar(tester);
      expect(find.text('Green Turf Arena'), findsOneWidget);
      expect(find.text('18:00 – 19:00'), findsOneWidget);
    });

    testWidgets('renders an available slot and the selected date', (
      tester,
    ) async {
      await pumpCalendar(tester, api);
      await settleCalendar(tester);

      expect(find.text('SELECTED'), findsOneWidget);
      expect(find.text('AVAILABLE'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    });

    testWidgets('an empty day says there are no slots', (tester) async {
      api.ok(kSlots, const []);
      await pumpCalendar(tester, api);
      await settleCalendar(tester);

      expect(find.text('No slots for this date'), findsOneWidget);
    });

    testWidgets('a failed slot read reads as the empty day, not an error', (
      tester,
    ) async {
      // Defect, pinned: both direct HTTP loaders catch failures and replace the
      // slot list with [], so the screen has no distinct error or retry state.
      api.fail(kSlots, 'boom');
      await pumpCalendar(tester, api);
      await settleCalendar(tester);

      expect(find.text('No slots for this date'), findsOneWidget);
    });
  });

  group('slot actions', () {
    testWidgets('blocking a free slot uses the per-slot PATCH path', (
      tester,
    ) async {
      api.on(
        '/owner/slots/s-1/block',
        FakeResponse(
          200,
          jsonEncode({'success': true, 'message': 'Slot blocked.', 'data': {}}),
        ),
      );
      await pumpCalendar(tester, api);
      await settleCalendar(tester);

      await tester.tap(find.byIcon(Icons.lock_outline));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(api.countTo('/owner/slots/s-1/block'), 1);
    });

    testWidgets('the generate action posts to the generation endpoint', (
      tester,
    ) async {
      api.on(
        '/owner/slots/generate',
        FakeResponse(
          200,
          jsonEncode({'success': true, 'message': 'Generated.', 'data': {}}),
        ),
      );
      await pumpCalendar(tester, api);
      await settleCalendar(tester);

      await tester.tap(find.byTooltip('Generate Slots for 7 Days'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(api.countTo('/owner/slots/generate'), 1);
    });
  });

  testWidgets('a doubled text scale keeps the slot visible', (tester) async {
    ignoreOverflow();
    await pumpCalendar(tester, api, textScale: 2.0);
    await settleCalendar(tester);
    expect(find.text('AVAILABLE'), findsOneWidget);
  });
}
